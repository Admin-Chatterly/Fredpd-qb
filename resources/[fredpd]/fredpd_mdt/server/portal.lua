-- SPDX-License-Identifier: GPL-3.0-only
-- Portal mode of the tablet action dispatcher (docs/modules/portal-api.md; IMPLEMENTATION.md §5.9, §7 task 7.1).
-- fredpd_service forwards POST /api/mdt/:action, HMAC-signed, to FXServer POST /fredpd_mdt/portal (server/http.js):
--   { requestId, discordId, citizenid, grants, action, input }  -> the same action table as the tablet (dispatch.lua)
--   { requestId, action = 'viewShare', input = { token } }     -> fredpd_records:viewShare (GET /share/:token)
-- The actor is a portal actor of fredpd_core (server/virtual.lua): a stand-in id whose grants are the set the service
-- resolved for the Discord id, whose citizenid is the character the service checked the user owns, and whose audit rows
-- carry meta.via = 'portal'. Differences from the tablet (dispatch.lua M.handle), in this order:
--   1. no open tablet and no terminal seat check (there is no player in the world);
--   2. unknown action / bad input -> validation; an action outside M.ALLOWED -> { error = 'unauthorized',
--      reason = 'portal' } (tablet/world actions: close, checkPlate, takeAlert, leaveAlert, closeAlert, issueFine,
--      setTabletRevoked, linkEvidence);
--   3. any mdt_page grant (the tablet's tablet.noGrant gate), then the action's grant as on the tablet; NO on-duty
--      requirement;
--   4. the same rate limit classes, per portal actor per action;
--   5. the same routes and { ok, data | error } unwrap.
-- Answers: { ok = true, data = <output> } or { ok = false, error = <MDT_ERROR_CODES>, reason? } (http.js sends it as
-- JSON with HTTP 200; a malformed request is HTTP 400).

local C = require 'server.common'
local Dispatch = require 'server.dispatch'
local Validate = require 'shared.validate'
local Config = require 'config'

local M = {}

--- Actions a portal user may run: every read (limit class read/lookup) and the fredpd_records / fredpd_intel /
--- fredpd_bolo writes, minus what needs a player in the world. apps/service/src/portal/actions.ts keeps the same list
--- (its test reads this table); tests/lua/mdt_portal_test.lua derives it from dispatch.lua's classes.
M.ALLOWED = {
    'getHome', 'search', 'getPerson', 'getVehicle', 'listBolos', 'createBolo', 'resolveBolo', 'listTablets',
    'listAlerts', 'getUnits', 'listEvidence', 'getEvidence',
    'listCases', 'getCase', 'createCase', 'updateCase', 'assignCase', 'unassignCase', 'addCaseSubject', 'closeCase',
    'getReport', 'createReport', 'saveReport', 'saveReportDraft', 'listReportTemplates', 'listCharges', 'applyCharges',
    'listSources', 'getSource', 'createSource', 'updateSource', 'listIntelReports', 'getIntelReport',
    'createIntelReport', 'searchEntities', 'ensureEntity', 'getEntity', 'addLink', 'getGraph', 'listMissions',
    'getMission', 'createMission', 'addMissionMember', 'closeMission',
}

--- Tablet/world actions: never from the portal, whatever the grant (the rule in M.ALLOWED's comment excludes them).
M.WORLD = { close = true, checkPlate = true, takeAlert = true, leaveAlert = true, issueFine = true }

local ALLOWED_SET = {}
for _, name in ipairs(M.ALLOWED) do ALLOWED_SET[name] = true end

function M.isAllowed(action)
    return ALLOWED_SET[action] == true
end

M.SHARE_ACTION = 'viewShare'
M.SHARE_TOKEN_PATTERN = '^[%w_%-]+$'
M.SHARE_TOKEN_LENGTH = 43
M.DISCORD_PATTERN = '^%d+$'
M.CITIZEN_PATTERN = '^[%w_%-]+$'
M.ACTION_PATTERN = '^%a%w*$'

local function fail(code, reason)
    return { ok = false, error = code, reason = reason }
end

--- An export's { ok, data | error, reason? } as the wire answer, with dispatch.lua's rules (unknown code, ok without
--- data or a malformed answer -> unavailable; reason only when it looks like one).
local function answer(res)
    if type(res) ~= 'table' then return fail('unavailable') end
    if res.ok == true and res.data ~= nil then return { ok = true, data = res.data } end
    local e = Dispatch.unwrap(res)
    if res.ok == false and type(e) == 'table' and type(e.error) == 'string' then return fail(e.error, e.reason) end
    return fail('unavailable')
end

--- Route one action for a portal actor (steps 2-5 above). `src` is the portal actor id.
function M.dispatch(src, action, input)
    local def = type(action) == 'string' and rawget(Dispatch.ACTIONS, action) or nil
    if not def or not Validate.isAction(action) then return fail('validation') end
    if not ALLOWED_SET[action] then return fail('unauthorized', 'portal') end
    local clean = Validate.validate(action, input)
    if clean == nil then return fail('validation') end

    -- The tablet's entry gate (open.lua tablet.noGrant): without any mdt_page grant there is no MDT, so actions
    -- without a grant of their own (getHome, listCharges) are refused too.
    if not C.anyMdtGrant(src) then return fail('unauthorized', 'no_grant') end
    if def.grant and not C.hasGrant(src, def.grant[1], def.grant[2]) then return fail('unauthorized') end

    if def.limit and not C.allow(src, 'action:' .. action, Config.limits[def.limit]) then
        return fail('rate_limited')
    end

    if def.handler then
        local ok, res = pcall(def.handler, src, clean)
        if not ok then
            C.logThrottled('portal:handler:' .. action, 'error', 'portal action %s failed: %s', action, tostring(res))
            return fail('unavailable')
        end
        return answer(res)
    end
    return answer((C.callExport(def.route[1], def.route[2], src, clean)))
end

--- GET /share/:token: fredpd_records:viewShare(token) (no actor; the records module counts and audits the view).
function M.viewShare(input)
    local token = type(input) == 'table' and input.token or nil
    if type(token) ~= 'string' or #token ~= M.SHARE_TOKEN_LENGTH or not token:match(M.SHARE_TOKEN_PATTERN) then
        return fail('not_found')
    end
    if GetResourceState('fredpd_records') ~= 'started' then return fail('unavailable') end
    local ok, res = pcall(function() return exports.fredpd_records:viewShare(token) end)
    if not ok then
        C.logThrottled('portal:viewShare', 'error', 'fredpd_records:viewShare failed: %s', tostring(res))
        return fail('unavailable')
    end
    return answer(res)
end

--- One portal request (the decoded body http.js verified). Returns HTTP status, answer table.
function M.handle(body)
    if type(body) ~= 'table' then return 400, { error = 'invalid_body', detail = 'body' } end
    local action = body.action
    if type(action) ~= 'string' or #action > 64 or not action:match(M.ACTION_PATTERN) then
        return 400, { error = 'invalid_body', detail = 'action' }
    end
    if action == M.SHARE_ACTION then return 200, M.viewShare(body.input) end

    local discordId, citizenid = body.discordId, body.citizenid
    if type(discordId) ~= 'string' or #discordId > 20 or not discordId:match(M.DISCORD_PATTERN) then
        return 400, { error = 'invalid_body', detail = 'discordId' }
    end
    if type(citizenid) ~= 'string' or #citizenid > 50 or not citizenid:match(M.CITIZEN_PATTERN) then
        return 400, { error = 'invalid_body', detail = 'citizenid' }
    end
    if type(body.grants) ~= 'table' then return 400, { error = 'invalid_body', detail = 'grants' } end

    local ok, src = C.core('portalActor', discordId, citizenid, body.grants)
    src = ok and C.playerSrc(src) or nil
    if not src then
        -- fredpd_core down (logged by C.core) or the set was refused (logged there).
        return 200, fail(ok and 'unauthorized' or 'unavailable')
    end
    local input = body.input
    if input == nil then input = {} end
    return 200, M.dispatch(src, action, input)
end

--- JSON text of an answer. Lua cannot tell [] from {}: the service restores the shape from the zod schema.
function M.encode(obj)
    local ok, text = pcall(json.encode, obj)
    if ok and type(text) == 'string' then return text end
    C.logThrottled('portal:encode', 'error', 'portal answer not encodable: %s', tostring(text))
    return nil
end

--- Export portalRequest(body, cb) for server/http.js (this resource only): runs M.handle in its own thread (the
--- routed exports await MySQL) and calls cb(status, jsonText) exactly once.
function M.request(body, cb)
    local caller = GetInvokingResource and GetInvokingResource() or nil
    if caller and caller ~= '' and caller ~= GetCurrentResourceName() then
        C.logThrottled('portal:caller:' .. tostring(caller), 'warn', 'portalRequest refused for resource %s', tostring(caller))
        return false
    end
    CreateThread(function()
        local okRun, status, res = pcall(M.handle, body)
        if not okRun then
            C.logThrottled('portal:handle', 'error', 'portal request failed: %s', tostring(status))
            status, res = 500, { error = 'internal' }
        end
        local text = M.encode(res)
        if not text then status, text = 500, '{"error":"internal"}' end
        local okCb, err = pcall(cb, status, text)
        if not okCb then C.logThrottled('portal:cb', 'error', 'portal reply failed: %s', tostring(err)) end
    end)
    return true
end

function M.register()
    exports('portalRequest', M.request)
    -- fredpd_core released an idle portal actor: drop its rate-limit state here too (server-local event only).
    AddEventHandler('fredpd:portalActorReleased', function(src)
        local n = tonumber(source)
        if n and n > 0 then return end
        src = C.playerSrc(src)
        if src then C.forget(src) end
    end)
end

return M
