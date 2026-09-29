-- SPDX-License-Identifier: GPL-3.0-only
-- The tablet action dispatcher (docs/contracts.md §C12): NUI fetchNui(action, input) -> client NUI callback ->
-- lib.callback 'fredpd:mdt:action' { action, input } -> here, in exactly this order:
--   1. the tablet must be open for src (Open[src]), except `close`            -> { error = 'unauthorized' }
--   2. unknown action / input not matching the shape (shared/validate.lua)     -> { error = 'validation' }
--   3. the action's grant (exports.fredpd_core:hasGrant)                       -> { error = 'unauthorized' }
--      on duty for every action except `close`                                 -> { error = 'unauthorized', reason = 'off_duty' }
--   4. rate limit per src per action (lookup 500 ms, write 2 s, read 250 ms)   -> { error = 'rate_limited' }
--   5. route: the owning resource's export (src, input) or a local handler; { ok, data } is unwrapped to data,
--      { ok = false, error } to { error } (an unknown code or a raise -> 'unavailable').
-- The action table merges MDT_ACTIONS (mdt.ts), DISPATCH_ACTIONS (dispatch.ts, §C13) and EVIDENCE_ACTIONS
-- (evidence.ts, §C16); their grant columns are checked against packages/types by the fixtures (mdt_dispatch_test).

local C = require 'server.common'
local Open = require 'server.open'
local Home = require 'server.home'
local Tablets = require 'server.tablets'
local Validate = require 'shared.validate'
local Config = require 'config'

local M = {}

local SEARCH = { 'mdt_page', 'search' }
local ALERTS = { 'mdt_page', 'alerts' }
local EVIDENCE = { 'mdt_page', 'evidence' }

--- name -> { grant = { type, key } | nil, limit = 'lookup'|'write'|'read'|nil, route = { resource, export } |
--- handler = function(src, input) -> { ok, data | error } }. Every name must also be a Validate.ACTIONS key.
M.ACTIONS = {
    -- MDT_ACTIONS
    close = { grant = nil, limit = nil, handler = function(src)
        Open.markClosed(src)
        return C.ok({ ok = true })
    end },
    getHome = { grant = nil, limit = 'read', handler = function(src) return Home.get(src) end },
    search = { grant = SEARCH, limit = 'lookup', route = { 'fredpd_records', 'search' } },
    getPerson = { grant = SEARCH, limit = 'lookup', route = { 'fredpd_records', 'getPersonSummary' } },
    getVehicle = { grant = SEARCH, limit = 'lookup', route = { 'fredpd_records', 'getVehicleSummary' } },
    checkPlate = { grant = SEARCH, limit = 'lookup', route = { 'fredpd_bolo', 'plateCheck' } },
    listBolos = { grant = { 'mdt_page', 'bolos' }, limit = 'read', route = { 'fredpd_bolo', 'listBolos' } },
    createBolo = { grant = { 'perm', 'bolo.create' }, limit = 'write', route = { 'fredpd_bolo', 'createBolo' } },
    resolveBolo = { grant = { 'perm', 'bolo.resolve' }, limit = 'write', route = { 'fredpd_bolo', 'resolveBolo' } },
    listTablets = { grant = { 'perm', 'tablets.manage' }, limit = 'read', handler = Tablets.list },
    setTabletRevoked = { grant = { 'perm', 'tablets.manage' }, limit = 'write', handler = Tablets.setRevoked },
    -- DISPATCH_ACTIONS (§C13)
    listAlerts = { grant = ALERTS, limit = 'read', route = { 'fredpd_dispatch', 'listAlerts' } },
    takeAlert = { grant = ALERTS, limit = 'write', route = { 'fredpd_dispatch', 'takeAlert' } },
    leaveAlert = { grant = ALERTS, limit = 'write', route = { 'fredpd_dispatch', 'leaveAlert' } },
    closeAlert = { grant = ALERTS, limit = 'write', route = { 'fredpd_dispatch', 'closeAlert' } },
    getUnits = { grant = ALERTS, limit = 'read', route = { 'fredpd_dispatch', 'getUnits' } },
    -- EVIDENCE_ACTIONS (§C16)
    listEvidence = { grant = EVIDENCE, limit = 'read', route = { 'fredpd_forensics', 'listEvidence' } },
    getEvidence = { grant = EVIDENCE, limit = 'read', route = { 'fredpd_forensics', 'getEvidence' } },
    linkEvidence = { grant = { 'perm', 'evidence.link' }, limit = 'write', route = { 'fredpd_forensics', 'linkEvidence' } },
}

local REASON_PATTERN = '^[%a_]+$'

local function err(code, reason)
    return { error = code, reason = reason }
end

--- { ok = true, data } -> data; { ok = false, error, reason? } -> { error, reason? }.
function M.unwrap(res)
    if type(res) ~= 'table' or type(res.ok) ~= 'boolean' then return err('unavailable') end
    if res.ok then
        if res.data == nil then return err('unavailable') end
        return res.data
    end
    local code = C.ERROR_CODES[res.error] and res.error or 'unavailable'
    local reason = type(res.reason) == 'string' and #res.reason <= 32 and res.reason:find(REASON_PATTERN) and res.reason
        or nil
    return err(code, reason)
end

local function route(name, def, src, input)
    if def.handler then
        local ok, res = pcall(def.handler, src, input)
        if not ok then
            C.logThrottled('handler:' .. name, 'error', 'action %s failed: %s', name, tostring(res))
            return err('unavailable')
        end
        return M.unwrap(res)
    end
    return M.unwrap(C.callExport(def.route[1], def.route[2], src, input))
end

--- lib.callback 'fredpd:mdt:action' handler. req = { action = string, input = table }.
function M.handle(src, req)
    src = C.playerSrc(src)
    if not src then return err('unauthorized') end
    local action = type(req) == 'table' and req.action or nil
    local isClose = action == 'close'

    -- 1. open tablet (close is exempt so a stale client can always end its session)
    if not isClose and not Open.isOpen(src) then return err('unauthorized') end
    -- A terminal session is only valid while seated in the police vehicle (cheap, no DB): a client that suppressed
    -- its close event on leaving the car is closed here.
    if not isClose then
        local session = Open.session(src)
        if session and session.mode == 'terminal' and not Open.inTerminalVehicle(src) then
            Open.forceClose(src, 'tablet.unavailable')
            return err('unauthorized')
        end
    end

    -- 2. known action, valid input
    local def = type(action) == 'string' and rawget(M.ACTIONS, action) or nil
    if not def or not Validate.isAction(action) then return err('validation') end
    local input = Validate.validate(action, req.input)
    if input == nil then return err('validation') end

    -- 3. grant, then duty
    if def.grant and not C.hasGrant(src, def.grant[1], def.grant[2]) then return err('unauthorized') end
    if not isClose and not C.isOnDuty(src) then return err('unauthorized', 'off_duty') end

    -- 4. rate limit (per src per action)
    if def.limit and not C.allow(src, 'action:' .. action, Config.limits[def.limit]) then
        return err('rate_limited')
    end

    -- 5. route
    return route(action, def, src, input)
end

return M
