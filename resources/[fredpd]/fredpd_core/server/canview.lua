-- SPDX-License-Identifier: GPL-3.0-only
-- Server wrapper for record visibility (docs/contracts.md §C3). The rules live in fredpd_visibility_rules; they are
-- loaded after the migrations and again whenever a server-side `fredpd:rulesChanged` event fires (server/http.js emits
-- it for the signed `POST /fredpd_core/rules` the service sends after a rule edit, §C6). The evaluation
-- itself is shared/canview.lua (same fixtures as the TS port). The viewer is always built on the server: citizenid
-- from qbx_core, tier/units/grants from the grant cache. No rules loaded -> every record is 'none' (fail closed).

local CanView = require 'shared.canview'
local Core = require 'server.core'
local Perms = require 'server.perms'

local M = {}

local rules = {}
-- Every load takes a ticket. Two rule edits in quick succession start two loads whose queries may finish out of
-- order; a load that finishes after a newer one was applied is discarded, so older rules never win.
local loadTicket, appliedTicket = 0, 0

M.RULES_SQL = 'SELECT id, record_type, level, record_status, viewer_condition, condition_value, result, priority, '
    .. 'enabled FROM fredpd_visibility_rules'

--- fredpd_visibility_rules row (snake_case, TINYINTs, NULLs as nil) -> VisibilityRule (§C3, camelCase).
function M.rowToRule(row)
    local enabled = row.enabled
    return {
        id = tonumber(row.id) or 0,
        recordType = row.record_type,
        level = tonumber(row.level), -- NULL = any level
        recordStatus = row.record_status,
        viewerCondition = row.viewer_condition,
        conditionValue = type(row.condition_value) == 'string' and row.condition_value or nil,
        result = row.result,
        priority = tonumber(row.priority) or 0,
        enabled = enabled == true or tonumber(enabled) == 1,
    }
end

--- Replace the active rule list (tests and loadRules).
function M.setRules(list)
    rules = list or {}
end

function M.getRules()
    return rules
end

--- Load the rules from the database (awaits). Keeps the previous rules if the query fails, and discards the result
--- of a load that a newer load has already overtaken (returns true: the rules in use are newer).
function M.loadRules()
    loadTicket = loadTicket + 1
    local ticket = loadTicket
    local ok, rows = pcall(MySQL.query.await, M.RULES_SQL)
    if not ok or type(rows) ~= 'table' then
        Core.error('could not load fredpd_visibility_rules: %s', tostring(rows))
        return false
    end
    if ticket < appliedTicket then
        Core.info('discarded an overtaken visibility rules load')
        return true
    end
    local list = {}
    for i, row in ipairs(rows) do list[i] = M.rowToRule(row) end
    appliedTicket = ticket
    rules = list
    Core.info('loaded %d visibility rules', #list)
    return true
end

--- The viewer for a player, built entirely server-side.
function M.viewerOf(src)
    local pd = Core.getPlayerData(src)
    local set = Perms.rawSet(src)
    return {
        citizenid = pd and pd.citizenid or nil,
        tier = set and set.tier or 0,
        units = set and set.units or {},
        grants = set,
    }
end

local function evaluate(viewer, record)
    if type(record) ~= 'table' or type(record.type) ~= 'string' then return 'none' end
    return CanView.evaluate(viewer, record, rules)
end

--- 'full' | 'masked' | 'notice' | 'none' for one record.
function M.canView(src, record)
    return evaluate(M.viewerOf(tonumber(src)), record)
end

--- Results for a list of records (one viewer lookup for the whole page).
function M.canViewMany(src, records)
    local viewer = M.viewerOf(tonumber(src))
    local out = {}
    for i, record in ipairs(type(records) == 'table' and records or {}) do out[i] = evaluate(viewer, record) end
    return out
end

function M.register()
    exports('canView', M.canView)
    exports('canViewMany', M.canViewMany)

    -- Server-only: registered with AddEventHandler (not RegisterNetEvent), so FXServer drops a client's
    -- TriggerServerEvent of it ("not safe for net"). The source check is a second guard in case a player id ever
    -- reaches here: a server-local emit (http.js, another resource's TriggerEvent) arrives with source '' (nil after
    -- tonumber), a net event with the player's id (> 0).
    AddEventHandler('fredpd:rulesChanged', function()
        local src = tonumber(source)
        if src and src > 0 then
            Core.warn('ignored fredpd:rulesChanged from player %d', src)
            return
        end
        Core.async('visibility rules reload', M.loadRules)
    end)
end

return M
