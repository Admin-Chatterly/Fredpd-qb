-- SPDX-License-Identifier: GPL-3.0-only
-- Portal mode (docs/modules/portal-api.md): fredpd_core's portal actors (server/virtual.lua with the REAL perms,
-- officers, audit and core modules: grants from the Discord id's set, citizenid, duty, audit meta.via = 'portal',
-- reuse, idle release, internal export) and fredpd_mdt's server/portal.lua over the mdt test harness (allowed list vs
-- dispatch.lua's classes, world actions refused, duty not required, no open tablet, grants, validation, rate limits,
-- routing/unwrap, viewShare, request/export wiring).
-- Run: lua5.4 tests/lua/run.lua mdt_portal
local H = dofile('./resources/[fredpd]/fredpd_mdt/test/harness.lua')

local tests = {}

local SET = {
    grants = { 'mdt_page:search', 'mdt_page:cases', 'perm:bolo.create', 'unit:span' },
    denied = { 'perm:bolo.create' }, tier = 1, units = { 'span' }, rank = nil, computedAt = '2026-09-29T10:00:00Z',
}

local function copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end

---------------------------------------------------------------------------------------------------------------
-- Part A: fredpd_core portal actors (real modules)

--- fredpd_officers rows seen by withCore: citizenid -> discord_id.
local OFFICERS = {
    PRT00001 = '900000000000000101', PRT00002 = '900000000000000102', PRT00003 = '900000000000000103',
    PRT00004 = '900000000000000103', PRT00005 = '900000000000000105', PRT00006 = '900000000000000106',
    PRT00007 = '900000000000000107', PRT00008 = '900000000000000108', PRT00009 = '900000000000000109',
}

--- Installs the FiveM globals the core modules touch while fn runs; returns the recorder.
local function withCore(opts, fn)
    if type(opts) == 'function' then opts, fn = {}, opts end
    local rec = { timers = {}, events = {}, client = {}, inserts = {}, exports = {}, now = 1000 }
    local globals = {
        GetGameTimer = function() return rec.now end,
        SetTimeout = function(ms, cb) rec.timers[#rec.timers + 1] = { at = rec.now + ms, cb = cb } end,
        TriggerEvent = function(name, ...) rec.events[#rec.events + 1] = { name = name, args = { ... } } end,
        TriggerClientEvent = function(name, src) rec.client[#rec.client + 1] = { name = name, src = src } end,
        GetInvokingResource = function() return rec.invoker end,
        GetCurrentResourceName = function() return 'fredpd_core' end,
        exports = function(name, f) rec.exports[name] = f end,
        CreateThread = function(f) f() end,
        MySQL = {
            insert = function(sql, params, cb)
                rec.inserts[#rec.inserts + 1] = { sql = sql, params = params }
                if cb then cb(#rec.inserts) end
            end,
            update = { await = function() return 1 end },
            query = { await = function() return rec.officerRows end },
        },
    }
    -- fredpd_officers rows (citizenid -> Discord id): a portal actor must be a police character of its Discord user
    rec.officerRows = {}
    for cid, discordId in pairs(opts.officers or OFFICERS) do
        rec.officerRows[#rec.officerRows + 1] = { citizenid = cid, discord_id = discordId, display_name = cid }
    end
    local saved = {}
    for k, v in pairs(globals) do
        saved[k] = { rawget(_G, k) }
        rawset(_G, k, v)
    end
    local Virtual = require('server.virtual')
    local Core = require('server.core')
    local Officers = require('server.officers')
    Officers.loadAll()
    local savedWarn = Core.warn
    Core.warn = function() end
    --- Run the timers due at rec.now (in order), like FiveM's SetTimeout.
    function rec.fireDue()
        local due = {}
        local keep = {}
        for _, t in ipairs(rec.timers) do
            if t.at <= rec.now then due[#due + 1] = t else keep[#keep + 1] = t end
        end
        rec.timers = keep
        for _, t in ipairs(due) do t.cb() end
        return #due
    end
    local ok, err = pcall(fn, rec, Virtual)
    -- never leak actors into other test files
    for src = Core.VIRTUAL_BASE, Core.VIRTUAL_BASE + 100000 do
        if not Core.virtualActor(src) and src > Core.VIRTUAL_BASE + 200 then break end
        Virtual.release(src)
    end
    rec.officerRows = {}
    Officers.loadAll() -- never leak officer rows either
    Core.warn = savedWarn
    for k, v in pairs(saved) do rawset(_G, k, v[1]) end
    if not ok then error(err, 0) end
    return rec
end

tests['core: a portal actor answers grants, tier, units and Discord id from the set for its Discord id'] = function(t)
    withCore(function(_, Virtual)
        local Core, Perms = require('server.core'), require('server.perms')
        local src = Virtual.begin('900000000000000101', 'PRT00001', copy(SET))
        t.ok(src and src >= Core.VIRTUAL_BASE, 'id above every player id')
        t.eq(Perms.hasGrant(src, 'mdt_page', 'search'), true)
        t.eq(Perms.hasGrant(src, 'mdt_page', 'intel'), false)
        t.eq(Perms.hasGrant(src, 'perm', 'bolo.create'), false, 'deny wins as for players')
        t.eq(Perms.getTier(src), 1)
        t.eq(Perms.getUnits(src), { 'span' })
        t.eq(Perms.getGrants(src).grants, SET.grants)
        t.eq(Perms.getDiscordId(src), '900000000000000101')
        t.ok(Core.isVirtual(src))
        t.ok(not Core.isVirtual(1), 'a player id is not virtual')
    end)
end

tests['core: citizenid is the given character, the portal counts as on duty, the framework bridge is not asked'] = function(t)
    withCore(function(_, Virtual)
        local Core, Officers, CanView = require('server.core'), require('server.officers'), require('server.canview')
        local src = Virtual.begin('900000000000000102', 'PRT00002', copy(SET))
        t.eq(Officers.getCitizenId(src), 'PRT00002')
        t.eq(Officers.isOnDuty(src), true)
        t.eq(Core.getPlayerData(src).virtual, true)
        local viewer = CanView.viewerOf(src)
        t.eq(viewer.citizenid, 'PRT00002')
        t.eq(viewer.tier, 1)
        t.eq(viewer.units, { 'span' })
        t.eq(require('server.bridge').getPlayer(src), nil, 'no framework player behind a portal actor')
    end)
end

tests['core: one id per (Discord id, citizenid), reused with refreshed grants (a revocation applies)'] = function(t)
    withCore(function(_, Virtual)
        local Perms = require('server.perms')
        local a = Virtual.begin('900000000000000103', 'PRT00003', copy(SET))
        local revoked = copy(SET)
        revoked.grants = { 'mdt_page:cases' }
        revoked.computedAt = '2026-09-29T09:00:00Z' -- older stamp: the service's live set still wins for actors
        local b = Virtual.begin('900000000000000103', 'PRT00003', revoked)
        t.eq(b, a, 'same actor')
        t.eq(Perms.hasGrant(a, 'mdt_page', 'search'), false, 'the new set replaced the old one')
        local other = Virtual.begin('900000000000000103', 'PRT00004', copy(SET))
        t.ok(other ~= a, 'another character is another actor')
        t.eq(select(2, Virtual.begin('900000000000000104', 'PRT00003', copy(SET))), 'not_officer',
            'another Discord user cannot act as this officer')
    end)
end

tests['core: bad Discord id, citizenid or GrantSet is refused'] = function(t)
    withCore(function(_, Virtual)
        local before = Virtual.count()
        local cases = {
            { 'abc', 'PRT00005', SET, 'discordId' },
            { ('1'):rep(21), 'PRT00005', SET, 'discordId' },
            { '900000000000000105', 'bad id', SET, 'citizenid' },
            { '900000000000000105', ('A'):rep(51), SET, 'citizenid' },
            { '900000000000000105', 'PRT00005', { grants = 'x' }, 'grants:grants' },
            { '900000000000000105', 'PRT00005', nil, 'grants:set' },
        }
        for i, c in ipairs(cases) do
            local src, reason = Virtual.begin(c[1], c[2], copy(c[3]))
            t.eq(src, nil, 'case ' .. i)
            t.eq(reason, c[4], 'case ' .. i)
        end
        t.eq(Virtual.count(), before, 'nothing allocated')
    end)
end

tests['core: a character without a fredpd_officers row of that Discord user is refused (8.3 review)'] = function(t)
    withCore(function(rec, Virtual)
        local before = Virtual.count()
        -- a civilian alt on the same license: no officer row at all
        local src, reason = Virtual.begin('900000000000000101', 'CIV00001', copy(SET))
        t.eq(src, nil)
        t.eq(reason, 'not_officer')
        -- an officer row relinked to another Discord account (the character is played from there now)
        src, reason = Virtual.begin('900000000000000199', 'PRT00001', copy(SET))
        t.eq(src, nil)
        t.eq(reason, 'not_officer')
        t.eq(Virtual.count(), before, 'nothing allocated')
        -- the export answers false
        Virtual.register()
        rec.invoker = 'fredpd_mdt'
        t.eq(rec.exports.portalActor('900000000000000101', 'CIV00001', copy(SET)), false)
    end)
end

tests['core: audit rows of a portal actor carry the character, the Discord id and meta.via = portal'] = function(t)
    withCore(function(rec, Virtual)
        local Audit = require('server.audit')
        local src = Virtual.begin('900000000000000106', 'PRT00006', copy(SET))
        local meta = { label = 'K-2026-0001' }
        t.ok(Audit.audit(src, 'case.create', 'case', 5, meta))
        local row = rec.inserts[#rec.inserts].params
        t.eq(row[1], 'PRT00006', 'actor_citizenid')
        t.eq(row[2], '900000000000000106', 'actor_discord')
        t.eq(row[3], 'case.create')
        t.eq(json.decode(row[#row]), { label = 'K-2026-0001', via = 'portal' })
        t.eq(meta, { label = 'K-2026-0001' }, 'caller meta not modified')
        Audit.audit(src, 'lookup.person', 'person', 'X1')
        t.eq(json.decode(rec.inserts[#rec.inserts].params[#rec.inserts[#rec.inserts].params]), { via = 'portal' })
        Audit.audit(0, 'system.thing', nil, nil, { a = 1 })
        t.eq(json.decode(rec.inserts[#rec.inserts].params[#rec.inserts[#rec.inserts].params]), { a = 1 }, 'system: no via')
    end)
end

tests['core: an idle actor is released by a one-shot timer; use re-arms it'] = function(t)
    withCore(function(rec, Virtual)
        local Perms, Officers, Core = require('server.perms'), require('server.officers'), require('server.core')
        local src = Virtual.begin('900000000000000107', 'PRT00007', copy(SET))
        t.eq(#rec.timers, 1, 'one timer')
        Virtual.begin('900000000000000107', 'PRT00007', copy(SET))
        t.eq(#rec.timers, 1, 'not re-armed while pending')
        rec.now = rec.now + Virtual.IDLE_MS - 1000
        Virtual.begin('900000000000000107', 'PRT00007', copy(SET)) -- used shortly before the timer fires
        rec.now = rec.now + 1000
        t.eq(rec.fireDue(), 1)
        t.ok(Core.isVirtual(src), 'still in use: kept')
        t.eq(#rec.timers, 1, 're-armed for the remainder')
        rec.now = rec.now + Virtual.IDLE_MS
        rec.fireDue()
        t.ok(not Core.isVirtual(src), 'released')
        t.eq(Perms.hasGrant(src, 'mdt_page', 'search'), false)
        t.eq(Officers.getCitizenId(src), nil)
        t.eq(rec.events[#rec.events].name, 'fredpd:portalActorReleased')
        t.eq(rec.events[#rec.events].args[1], src)
        t.ok(Virtual.begin('900000000000000107', 'PRT00007', copy(SET)) ~= src, 'a new id afterwards')
    end)
end

tests['core: a /grants push for the Discord id updates its portal actor without a client event'] = function(t)
    withCore(function(rec, Virtual)
        local Perms = require('server.perms')
        local src = Virtual.begin('900000000000000108', 'PRT00008', copy(SET))
        local newer = copy(SET)
        newer.grants = { 'mdt_page:intel' }
        newer.computedAt = '2026-09-29T11:00:00Z'
        t.eq(Perms.applyGrants('900000000000000108', newer), 1)
        t.eq(Perms.hasGrant(src, 'mdt_page', 'intel'), true)
        t.eq(#rec.client, 0, 'no TriggerClientEvent to a portal actor')
    end)
end

tests['core: export portalActor is internal (fredpd_mdt and fredpd_core only)'] = function(t)
    withCore(function(rec, Virtual)
        Virtual.register()
        local export = rec.exports.portalActor
        rec.invoker = 'fredpd_mdt'
        local src = export('900000000000000109', 'PRT00009', copy(SET))
        t.ok(type(src) == 'number' and src >= require('server.core').VIRTUAL_BASE)
        rec.invoker = 'some_other_resource'
        t.eq(export('900000000000000109', 'PRT00009', copy(SET)), false)
        rec.invoker = 'fredpd_mdt'
        t.eq(export('900000000000000109', 'bad id', copy(SET)), false, 'invalid input -> false')
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Part B: fredpd_mdt server/portal.lua over the harness

local DISCORD = '900000000000000201'
local VSRC = 1000000500

--- Grants of the portal user (list form, like the service's GrantSet).
local function grantSet(list, tier)
    return { grants = list, denied = {}, tier = tier or 0, units = { 'span' }, computedAt = '2026-09-29T10:00:00Z' }
end

local FULL = { 'mdt_page:*', 'perm:*' }

local function loadPortal()
    local saved = package.path
    package.path = H.ROOT .. '?.lua;' .. package.path
    package.loaded['server.portal'] = nil
    local ok, mod = pcall(require, 'server.portal')
    package.path = saved
    if not ok then error(mod, 0) end
    return mod
end

--- H.with plus a portalActor mock in the harness's fredpd_core: the actor becomes a "player" OFF duty with no
--- tablet, holding exactly the set's grants (the real fredpd_core behaviour is Part A).
local function withPortal(opts, fn)
    if type(opts) == 'function' then opts, fn = {}, opts end
    H.with(opts, function(env, mods)
        env.actors = {}
        env.exports.fredpd_core.portalActor = function(_, discordId, citizenid, set)
            if env.coreDown then error('fredpd_core is not running', 0) end
            if env.refuseActor then return false end
            local key = discordId .. '|' .. citizenid
            if not env.actors[key] then env.nextActor = (env.nextActor or VSRC) + 1 end
            local src = env.actors[key] or env.nextActor
            env.actors[key] = src
            local grants = {}
            for _, g in ipairs(set.grants or {}) do grants[g] = true end
            env.players[src] = { cid = citizenid, duty = false, grants = grants, units = set.units or {},
                tier = set.tier or 0, items = {} }
            env.lastActor = { src = src, discordId = discordId, citizenid = citizenid }
            return src
        end
        env.exports.fredpd_records.viewShare = function(_, token)
            env.calls[#env.calls + 1] = { res = 'fredpd_records', fn = 'viewShare', token = token, extra = _ }
            local reply = env.replies['fredpd_records:viewShare']
            if type(reply) == 'function' then return reply(token) end
            return reply or { ok = true, data = { targetType = 'poi', expiresAt = '2026-09-30T10:00:00Z' } }
        end
        local Portal = loadPortal()
        local ok, err = pcall(fn, env, mods, Portal)
        package.loaded['server.portal'] = nil
        if not ok then error(err, 0) end
    end)
end

local function req(action, input, grants, extra)
    local body = { requestId = ('a'):rep(32), discordId = DISCORD, citizenid = 'PRT20001',
        grants = grants or grantSet(FULL, 2), action = action, input = input }
    for k, v in pairs(extra or {}) do body[k] = v end
    return body
end

tests['portal: M.ALLOWED = reads (read/lookup) + records/intel/bolo writes, minus world actions'] = function(t)
    withPortal(function(_, mods, Portal)
        local Dispatch, Validate = mods['server.dispatch'], mods['shared.validate']
        local expected = {}
        for name, def in pairs(Dispatch.ACTIONS) do
            local read = def.limit == 'read' or def.limit == 'lookup'
            local res = def.route and def.route[1]
            local domainWrite = res == 'fredpd_records' or res == 'fredpd_intel' or res == 'fredpd_bolo'
            if (read or domainWrite) and not Portal.WORLD[name] then expected[#expected + 1] = name end
        end
        table.sort(expected)
        local allowed = copy(Portal.ALLOWED)
        table.sort(allowed)
        t.eq(allowed, expected)
        local refused = {}
        for name in pairs(Validate.ACTIONS) do
            if not Portal.isAllowed(name) then refused[#refused + 1] = name end
        end
        table.sort(refused)
        t.eq(refused, { 'checkPlate', 'close', 'closeAlert', 'issueFine', 'leaveAlert', 'linkEvidence',
            'setTabletRevoked', 'takeAlert' })
    end)
end

tests['portal: a read routes for the portal actor without an open tablet and without duty'] = function(t)
    withPortal(function(env, _, Portal)
        local status, res = Portal.handle(req('search', { query = '  Berg ' }))
        t.eq(status, 200)
        t.eq(res, { ok = true, data = { routed = 'fredpd_records:search' } })
        local call = env.callsTo('fredpd_records', 'search')[1]
        t.eq(call.src, env.lastActor.src, 'the portal actor, never a player id')
        t.eq(env.lastActor.citizenid, 'PRT20001')
        t.eq(env.lastActor.discordId, DISCORD)
        t.eq(call.input.query, 'Berg', 'input cleaned by validate.lua')
        t.eq(env.players[call.src].duty, false, 'the actor is off duty: the portal does not require duty')
        t.eq(#env.sent(nil, 'fredpd:client:forceClose'), 0)
    end)
end

tests['portal: tablet/world actions are refused with reason portal and never routed, whatever the grant'] = function(t)
    withPortal(function(env, _, Portal)
        local world = {
            { 'close', {} }, { 'checkPlate', { plate = 'ABC123' } }, { 'takeAlert', { id = 1 } },
            { 'leaveAlert', { id = 1 } }, { 'closeAlert', { id = 1 } },
            { 'issueFine', { citizenid = 'CIV1', lines = { { code = 'X1', quantity = 1 } } } },
            { 'setTabletRevoked', { serial = 'SP-AAAA-0001', revoked = true } }, { 'linkEvidence', { id = 1, caseId = 2 } },
        }
        for _, w in ipairs(world) do
            local status, res = Portal.handle(req(w[1], w[2]))
            t.eq(status, 200, w[1])
            t.eq(res, { ok = false, error = 'unauthorized', reason = 'portal' }, w[1])
        end
        t.eq(#env.callsTo('fredpd_bolo'), 0)
        t.eq(#env.callsTo('fredpd_dispatch'), 0)
        t.eq(#env.callsTo('fredpd_forensics'), 0)
        t.eq(#env.callsTo('fredpd_records', 'issueFine'), 0)
    end)
end

tests['portal: the action grant comes from the set for the Discord id'] = function(t)
    withPortal(function(env, _, Portal)
        local igv = grantSet({ 'mdt_page:search', 'mdt_page:bolos' })
        local _, res = Portal.handle(req('getSource', { id = 1 }, igv))
        t.eq(res, { ok = false, error = 'unauthorized' }, 'intel without perm:intel.read')
        _, res = Portal.handle(req('createBolo', { kind = 'vehicle', plate = 'ABC123', reason = 'Stulen bil', level = 0 }, igv))
        t.eq(res, { ok = false, error = 'unauthorized' })
        t.eq(#env.callsTo('fredpd_intel'), 0)
        t.eq(#env.callsTo('fredpd_bolo', 'createBolo'), 0)
        _, res = Portal.handle(req('listBolos', { page = 1 }, igv))
        t.eq(res.ok, true)
        local withIntel = grantSet({ 'mdt_page:intel', 'perm:intel.read' }, 1)
        _, res = Portal.handle(req('getSource', { id = 1 }, withIntel))
        t.eq(res, { ok = true, data = { routed = 'fredpd_intel:getSource' } })
    end)
end

tests['portal: no mdt_page grant at all (the tablet gate) refuses every action, getHome and listCharges included'] = function(t)
    withPortal(function(env, _, Portal)
        local civilian = grantSet({ 'perm:intel.read', 'perm:bolo.create' })
        for _, a in ipairs({ { 'getHome', {} }, { 'listCharges', {} }, { 'getSource', { id = 1 } }, { 'search', { query = 'Berg' } } }) do
            local status, res = Portal.handle(req(a[1], a[2], civilian))
            t.eq(status, 200, a[1])
            t.eq(res, { ok = false, error = 'unauthorized', reason = 'no_grant' }, a[1])
        end
        t.eq(#env.calls, 0, 'nothing routed')
        local _, res = Portal.handle(req('listCharges', {}, grantSet({ 'mdt_page:search' })))
        t.eq(res.ok, true, 'one mdt_page grant opens the grant-less actions')
    end)
end

tests['portal: writes of records, intel and bolo route with the cleaned input'] = function(t)
    withPortal(function(env, _, Portal)
        local _, res = Portal.handle(req('createCase', { title = '  Inbrott Vinewood  ', level = 0 }))
        t.eq(res, { ok = true, data = { routed = 'fredpd_records:createCase' } })
        t.eq(env.callsTo('fredpd_records', 'createCase')[1].input.title, 'Inbrott Vinewood')
        _, res = Portal.handle(req('resolveBolo', { id = 3 }))
        t.eq(res.ok, true)
        env.now = env.now + 5000
        _, res = Portal.handle(req('createMission', { title = 'Operation Ek', level = 2 }))
        t.eq(res.ok, true)
    end)
end

tests['portal: unknown action and bad input answer validation; malformed bodies are 400'] = function(t)
    withPortal(function(env, _, Portal)
        local _, res = Portal.handle(req('dropTables', {}))
        t.eq(res, { ok = false, error = 'validation' })
        _, res = Portal.handle(req('getCase', { id = 'x' }))
        t.eq(res, { ok = false, error = 'validation' })
        _, res = Portal.handle(req('getHome', { extra = 1 }))
        t.eq(res, { ok = false, error = 'validation' }, 'strict Empty')
        t.eq(#env.calls, 0)
        local bad = {
            { 'not a table', 'body' },
            { req(nil, {}), 'action' },
            { req('bad action!', {}), 'action' },
            { req('search', {}, nil, { discordId = 'abc' }), 'discordId' },
            { req('search', {}, nil, { citizenid = 'bad id' }), 'citizenid' },
            { req('search', {}, nil, { grants = 'x' }), 'grants' },
        }
        for i, b in ipairs(bad) do
            local status, out = Portal.handle(b[1])
            t.eq(status, 400, 'case ' .. i)
            t.eq(out, { error = 'invalid_body', detail = b[2] }, 'case ' .. i)
        end
    end)
end

tests['portal: missing input counts as {}; getHome runs for the actor'] = function(t)
    withPortal(function(env, _, Portal)
        env.replies['fredpd_bolo:listBolos'] = { ok = true, data = { items = {}, total = 0, page = 1 } }
        env.replies['fredpd_records:getHomeCases'] = { ok = true, data = {} }
        env.replies['fredpd_records:countMyOpenCases'] = { ok = true, data = 0 }
        local status, res = Portal.handle(req('getHome', nil))
        t.eq(status, 200)
        t.eq(res.ok, true, 'getHome answered')
    end)
end

tests['portal: rate limits are per portal actor and per action'] = function(t)
    withPortal(function(env, _, Portal)
        t.eq(select(2, Portal.handle(req('getCase', { id = 1 }))).ok, true)
        t.eq(select(2, Portal.handle(req('getCase', { id = 1 }))), { ok = false, error = 'rate_limited' })
        t.eq(select(2, Portal.handle(req('listCases', { page = 1 }))).ok, true, 'another action')
        t.eq(select(2, Portal.handle(req('getCase', { id = 1 }, nil, { citizenid = 'PRT20002' }))).ok, true,
            'another actor')
        env.now = env.now + 500
        t.eq(select(2, Portal.handle(req('getCase', { id = 1 }))).ok, true, 'after the window')
        t.eq(#env.callsTo('fredpd_records', 'getCase'), 3)
    end)
end

tests['portal: export answers are unwrapped like the tablet (errors, reasons, malformed, stopped)'] = function(t)
    withPortal(function(env, _, Portal)
        env.replies['fredpd_records:getCase'] = { ok = false, error = 'not_found' }
        t.eq(select(2, Portal.handle(req('getCase', { id = 1 }))), { ok = false, error = 'not_found' })
        env.now = env.now + 1000
        env.replies['fredpd_records:getCase'] = { ok = false, error = 'unauthorized', reason = 'not_lead' }
        t.eq(select(2, Portal.handle(req('getCase', { id = 1 }))), { ok = false, error = 'unauthorized', reason = 'not_lead' })
        env.now = env.now + 1000
        env.replies['fredpd_records:getCase'] = { ok = false, error = 'weird_code' }
        t.eq(select(2, Portal.handle(req('getCase', { id = 1 }))), { ok = false, error = 'unavailable' })
        env.now = env.now + 1000
        env.replies['fredpd_records:getCase'] = { ok = true }
        t.eq(select(2, Portal.handle(req('getCase', { id = 1 }))), { ok = false, error = 'unavailable' }, 'ok without data')
        env.now = env.now + 1000
        env.replies['fredpd_records:getCase'] = function() error('boom') end
        t.eq(select(2, Portal.handle(req('getCase', { id = 1 }))), { ok = false, error = 'unavailable' })
        env.now = env.now + 1000
        env.resources.fredpd_records = 'stopped'
        t.eq(select(2, Portal.handle(req('getCase', { id = 1 }))), { ok = false, error = 'unavailable' })
    end)
end

tests['portal: fredpd_core refusing or failing the actor answers unauthorized / unavailable'] = function(t)
    withPortal(function(env, _, Portal)
        env.refuseActor = true
        t.eq({ Portal.handle(req('search', { query = 'Berg' })) }, { 200, { ok = false, error = 'unauthorized' } })
        env.refuseActor, env.coreDown = false, true
        t.eq({ Portal.handle(req('search', { query = 'Berg' })) }, { 200, { ok = false, error = 'unavailable' } })
        t.eq(#env.calls, 0)
    end)
end

tests['portal: viewShare calls fredpd_records:viewShare(token) with no actor'] = function(t)
    withPortal(function(env, _, Portal)
        local token = ('Ab_-'):rep(10) .. 'xyz'
        local status, res = Portal.handle({ requestId = ('b'):rep(32), action = 'viewShare', input = { token = token } })
        t.eq(status, 200)
        t.eq(res, { ok = true, data = { targetType = 'poi', expiresAt = '2026-09-30T10:00:00Z' } })
        local call = env.callsTo('fredpd_records', 'viewShare')[1]
        t.eq(call.token, token)
        t.eq(env.lastActor, nil, 'no portal actor for a share view')
        for _, bad in ipairs({ 'short', token .. 'x', ('!'):rep(43) }) do
            t.eq(select(2, Portal.handle({ action = 'viewShare', input = { token = bad } })), { ok = false, error = 'not_found' })
        end
        t.eq(select(2, Portal.handle({ action = 'viewShare' })), { ok = false, error = 'not_found' })
        t.eq(#env.callsTo('fredpd_records', 'viewShare'), 1, 'bad tokens never reach fredpd_records')
        env.replies['fredpd_records:viewShare'] = { ok = false, error = 'not_found' }
        t.eq(select(2, Portal.handle({ action = 'viewShare', input = { token = token } })), { ok = false, error = 'not_found' })
        env.replies['fredpd_records:viewShare'] = function() error('db down') end
        t.eq(select(2, Portal.handle({ action = 'viewShare', input = { token = token } })), { ok = false, error = 'unavailable' })
        env.resources.fredpd_records = 'stopped'
        t.eq(select(2, Portal.handle({ action = 'viewShare', input = { token = token } })), { ok = false, error = 'unavailable' })
    end)
end

tests['portal: export portalRequest runs in a thread, answers JSON once, and is refused to other resources'] = function(t)
    local saved = rawget(_G, 'GetInvokingResource')
    local ok, err = pcall(withPortal, function(env, _, Portal)
        local invoker = 'fredpd_mdt'
        rawset(_G, 'GetInvokingResource', function() return invoker end)
        local answers = {}
        local cb = function(status, text) answers[#answers + 1] = { status, json.decode(text) } end
        t.eq(Portal.request(req('listCases', { page = 1 }), cb), true)
        t.eq(answers, { { 200, { ok = true, data = { routed = 'fredpd_records:listCases' } } } })
        t.eq(Portal.request('garbage', cb), true)
        t.eq(answers[2], { 400, { error = 'invalid_body', detail = 'body' } })
        invoker = 'some_other_resource'
        t.eq(Portal.request(req('listCases', { page = 1 }), cb), false)
        t.eq(#answers, 2, 'no answer, nothing run')
        invoker = nil
        env.replies['fredpd_records:listCases'] = { ok = true, data = { fn = function() end } }
        env.now = env.now + 1000
        Portal.request(req('listCases', { page = 1 }), cb)
        t.eq(answers[3], { 500, { error = 'internal' } }, 'an answer JSON cannot encode')
    end)
    rawset(_G, 'GetInvokingResource', saved)
    if not ok then error(err, 0) end
end

tests['portal: server/main.lua registers portalRequest; a released actor forgets its limits'] = function(t)
    withPortal(function(env, mods, Portal)
        H.run('server/main.lua')
        t.ok(env.exported.portalRequest, 'export portalRequest')
        local C = mods['server.common']
        -- main.lua loaded its own copy of server.portal; drive its handler through the event.
        t.ok(env.handlers['fredpd:portalActorReleased'], 'release handler')
        t.eq(C.allow(VSRC, 'action:getCase', 500), true)
        env.fire('fredpd:portalActorReleased', 5, VSRC)
        t.eq(C.allow(VSRC, 'action:getCase', 500), false, 'a player cannot trigger it')
        env.fire('fredpd:portalActorReleased', '', VSRC)
        t.eq(C.allow(VSRC, 'action:getCase', 500), true, 'forgotten')
        t.ok(Portal.isAllowed('search'))
    end)
end

return tests
