-- SPDX-License-Identifier: GPL-3.0-only
-- Record visibility (docs/contracts.md §C3). Lua port of packages/types/src/canView.ts with identical
-- semantics; both run packages/types/test/fixtures/canView.fixtures.json. Change the two together.
-- The server wrapper (fredpd_core/server/canview.lua) loads the rules and builds the viewer.
--
-- Input is JSON-decoded or DB data: arrays are sequences, JSON null / SQL NULL is nil (rule.level nil =
-- any level), and TINYINT `enabled` may arrive as 0/1. Optional strings are type-checked, so a json.null
-- style sentinel behaves like nil. Pure: no natives, safe at load time.

-- ox_lib resolves a bare module name against the *calling* resource, so when another resource loads this
-- file via '@fredpd_core.shared.canview', 'shared.grants' could bind to that resource's own file. Use the
-- qualified name first (valid in every resource, fredpd_core included); the bare name is only for
-- tests/lua, where plain Lua's package.path cannot resolve '@fredpd_core.…'.
local okGrants, Grants = pcall(require, '@fredpd_core.shared.grants')
if not okGrants then Grants = require('shared.grants') end

local M = {}

--- Ascending: none < notice (kontaktnotis) < masked < full.
M.RESULTS = { 'none', 'notice', 'masked', 'full' }
local RANK = { none = 0, notice = 1, masked = 2, full = 3 }

--- @param result string
--- @return integer rank, or -1 for an unknown result
function M.rank(result)
    return RANK[result] or -1
end

--- The lower of `result` and `max` ("at most max"). An unknown result ranks below 'none' and is returned
--- unchanged; evaluate never produces one because rules with an unknown result are skipped.
function M.cap(result, max)
    if M.rank(result) > M.rank(max) then return max end
    return result
end

local function contains(list, value)
    if type(list) ~= 'table' then return false end
    for i = 1, #list do
        if list[i] == value then return true end
    end
    return false
end

--- nil or '' citizenid is "no identity" and never matches an owner, assignee or handler.
local function identity(viewer)
    local cid = viewer.citizenid
    if type(cid) ~= 'string' or cid == '' then return nil end
    return cid
end

local function isAssigned(viewer, record)
    local me = identity(viewer)
    return me ~= nil and (record.ownerCitizenid == me or contains(record.assignees, me))
end

local function isHandler(viewer, record)
    local me = identity(viewer)
    return me ~= nil and record.handlerCitizenid == me
end

--- Record level 0..2; anything else (nil, out of range, a string) counts as 2 (fail closed). Same as TS levelOf.
local function recordLevel(record)
    local level = record.level
    if level == 0 or level == 1 or level == 2 then return level end
    return 2
end

--- Viewer tier 0..2; anything else counts as 0. Same as TS tierOf.
local function viewerTier(viewer)
    local tier = viewer.tier
    if tier == 0 or tier == 1 or tier == 2 then return tier end
    return 0
end

--- The rule's conditionValue, or nil for NULL (or a json.null-style sentinel). '' is kept as '' (literal §C3).
local function conditionValue(rule)
    local v = rule.conditionValue
    if type(v) ~= 'string' then return nil end
    return v
end

local function enabled(rule)
    return rule.enabled == true or rule.enabled == 1 or rule.enabled == '1'
end

--- Does the rule apply to this record (enabled, type, level, status)?
function M.ruleApplies(rule, record)
    if not enabled(rule) or RANK[rule.result] == nil then return false end
    if rule.recordType ~= '*' and rule.recordType ~= record.type then return false end
    -- NULL level = any. tonumber() also maps a JSON-null sentinel (if a json library uses one) to "any".
    local level = tonumber(rule.level)
    if level ~= nil and level ~= recordLevel(record) then return false end
    return rule.recordStatus == 'any' or rule.recordStatus == record.status
end

--- Does the rule's viewer condition hold? Unknown conditions never hold.
function M.conditionHolds(rule, viewer, record)
    local cond = rule.viewerCondition
    if cond == 'any' then
        return true
    elseif cond == 'assigned' then
        return isAssigned(viewer, record)
    elseif cond == 'handler' then
        return isHandler(viewer, record)
    elseif cond == 'unit' then
        -- Only NULL falls back to record.unit; '' names no unit and never matches.
        local unit = conditionValue(rule)
        if unit == nil then unit = record.unit end
        return type(unit) == 'string' and contains(viewer.units, unit)
    elseif cond == 'tier_gte' then
        return viewerTier(viewer) >= recordLevel(record)
    elseif cond == 'perm' then
        -- A key-less perm rule (NULL or '') never matches, not even for perm:* (fail closed).
        local perm = conditionValue(rule)
        return perm ~= nil and perm ~= '' and Grants.has(viewer.grants, 'perm', perm)
    end
    return false
end

--- Hard caps, applied after the rules and not overridable by config (§C3):
--- 1. intel_source: 'full' only for (handler with perm intel.handler) or perm intel.command, else at most 'masked'.
--- 2. level > tier, viewer not assigned/owner/handler and without perm intel.command -> at most 'notice'.
function M.applyCaps(viewer, record, result)
    local command = Grants.has(viewer.grants, 'perm', 'intel.command')
    local handler = isHandler(viewer, record)
    local out = result
    if record.type == 'intel_source' and not command
        and not (handler and Grants.has(viewer.grants, 'perm', 'intel.handler')) then
        out = M.cap(out, 'masked')
    end
    if recordLevel(record) > viewerTier(viewer) and not command and not handler and not isAssigned(viewer, record) then
        out = M.cap(out, 'notice')
    end
    return out
end

--- canView(viewer, record, rules): enabled rules matching the record's type/level/status, by priority desc
--- then id asc; the first rule whose viewer condition holds gives the result (no match -> 'none'), then the
--- hard caps apply.
--- @param viewer table { citizenid, tier, units, grants }
--- @param record table VisRecord
--- @param rules table sequence of VisibilityRule
--- @return string 'full'|'masked'|'notice'|'none'
function M.evaluate(viewer, record, rules)
    viewer = viewer or {}
    local candidates = {}
    for _, rule in ipairs(rules or {}) do
        if M.ruleApplies(rule, record) then candidates[#candidates + 1] = rule end
    end
    table.sort(candidates, function(a, b)
        local pa, pb = tonumber(a.priority) or 0, tonumber(b.priority) or 0
        if pa ~= pb then return pa > pb end
        return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
    end)
    local result = 'none'
    for _, rule in ipairs(candidates) do
        if M.conditionHolds(rule, viewer, record) then
            result = rule.result
            break
        end
    end
    return M.applyCaps(viewer, record, result)
end

return M
