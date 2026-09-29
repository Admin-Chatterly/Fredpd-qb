-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_intel server against a real MariaDB (tests/lua/mysql_shim.lua runs the migrations and fakes oxmysql), with
-- FiveM mocked: fredpd_core (grants from GrantSets, canView = shared/canview.lua over the seeded default rules,
-- audit = the real fredpd_core audit writer), players, exports, events, timers.
-- Covers main.lua wiring, the §5.8 acceptance story end to end (Span creates a Hemlig mission; IGV gets only a
-- kontaktnotis via getEntity and getPersonNotices; Utredning assigned sees everything; an audit row for every read of
-- a Hemlig report), the source identity matrix, not_found for 'none', graph cap/truncation with 200 generated
-- entities, depth 2 and hidden links, entity ref validation and server-derived labels, SQL injection / wildcards in
-- search, handler/lead/author never taken from input, mission rules, rate limits, UTC timestamps, and writes the
-- golden JSON checked by resources/[fredpd]/fredpd_intel/test/contract.test.ts.
-- Database fredpd_test_intel_lua (reset once per run); every session at time_zone '+02:00' (§C7).
-- Run: lua5.4 tests/lua/run.lua intel_server
local shim = require('mysql_shim')
local helper = require('helper')

local DB = 'fredpd_test_intel_lua'
local INTEL = './resources/[fredpd]/fredpd_intel/'
local GOLDEN = INTEL .. 'test/golden/'
local MODULES = { 'shared.input', 'server.store', 'server.access', 'server.service', 'server.main' }
local ISO = '^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$'

local tests = {}

for _, name in ipairs({ 'time', 'locale', 'grants' }) do
    package.preload['@fredpd_core.shared.' .. name] = function() return require('shared.' .. name) end
end

local function set(list)
    local out = {}
    for _, k in ipairs(list) do out[#out + 1] = k end
    table.sort(out)
    return out
end

local function deepcopy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = deepcopy(x) end
    return out
end

-- 1 Span chef (intel.command), 2 källhanterare (intel.handler), 3 IGV (mdt_page:intel only), 4 Utredning (intel.read,
-- tier 1), 5 Span analyst (intel.read, tier 2), 6 another handler, 7 off duty, 8 civilian, 9 IGV without the intel
-- page (person page only), 10 = player 2's character after losing intel.handler.
local function defaultPlayers()
    return {
        [1] = { cid = 'SPA00001', duty = true, tier = 2, units = { 'span' },
            grants = set({ 'mdt_page:intel', 'perm:intel.read', 'perm:intel.command', 'unit:span' }) },
        [2] = { cid = 'HAN00002', duty = true, tier = 2, units = { 'span' },
            grants = set({ 'mdt_page:intel', 'perm:intel.read', 'perm:intel.handler', 'unit:span' }) },
        [3] = { cid = 'IGV00003', duty = true, tier = 0, units = { 'igv' }, grants = set({ 'mdt_page:intel', 'unit:igv' }) },
        [4] = { cid = 'UTR00004', duty = true, tier = 1, units = { 'utredning' },
            grants = set({ 'mdt_page:intel', 'perm:intel.read', 'unit:utredning' }) },
        [5] = { cid = 'ANA00005', duty = true, tier = 2, units = { 'span' },
            grants = set({ 'mdt_page:intel', 'perm:intel.read', 'unit:span' }) },
        [6] = { cid = 'HAN00006', duty = true, tier = 2, units = { 'span' },
            grants = set({ 'mdt_page:intel', 'perm:intel.read', 'perm:intel.handler', 'unit:span' }) },
        [7] = { cid = 'SPA00007', duty = false, tier = 2, units = { 'span' },
            grants = set({ 'mdt_page:intel', 'perm:intel.read', 'perm:intel.command', 'perm:intel.handler' }) },
        [8] = { cid = 'CIV60008', duty = false, tier = 0, units = {}, grants = {} },
        [9] = { cid = 'IGV00009', duty = true, tier = 0, units = { 'igv' }, grants = set({ 'unit:igv' }) },
        [10] = { cid = 'HAN00002', duty = true, tier = 2, units = { 'span' },
            grants = set({ 'mdt_page:intel', 'perm:intel.read', 'unit:span' }) },
    }
end

local OFFICERS = {
    { 'SPA00001', '100000000000000001', 'Sara S.', 'SPA-01', 'span' },
    { 'HAN00002', '100000000000000002', 'Hans H.', 'SPA-02', 'span' },
    { 'IGV00003', '100000000000000003', 'Ida I.', 'IGV-03', 'igv' },
    { 'UTR00004', '100000000000000004', 'Ulla U.', 'UTR-04', 'utredning' },
    { 'ANA00005', '100000000000000005', 'Anna A.', 'SPA-05', 'span' },
    { 'HAN00006', '100000000000000006', 'Harald H.', 'SPA-06', 'span' },
}

local prepared, notified = nil, false

local GLOBALS = { 'MySQL', 'LoadResourceFile', 'GetCurrentResourceName', 'exports', 'GetGameTimer', 'SetTimeout',
    'CreateThread', 'TriggerEvent', 'TriggerClientEvent', 'AddEventHandler', 'lib', 'GetPlayerIdentifierByType',
    'source', 'locale' }

local function clearModules()
    for _, name in ipairs(MODULES) do package.loaded[name] = nil end
end

local function loadResource()
    clearModules()
    local savedMain = package.loaded['server.main']
    package.loaded['server.main'] = nil
    local saved = package.path
    package.path = INTEL .. '?.lua;' .. package.path
    local ok, main = pcall(require, 'server.main')
    local mods = {
        main = main,
        service = package.loaded['server.service'],
        store = package.loaded['server.store'],
        access = package.loaded['server.access'],
        input = package.loaded['shared.input'],
    }
    package.path = saved
    package.loaded['server.main'] = savedMain
    if not ok then error(main, 0) end
    return mods
end

local function makeEnv()
    local Audit = require('server.audit')
    local CanView = require('shared.canview')
    local Grants = require('shared.grants')
    local CoreCanView = require('server.canview')
    local rules = {}
    for _, row in ipairs(MySQL.query.await(CoreCanView.RULES_SQL)) do rules[#rules + 1] = CoreCanView.rowToRule(row) end

    local env = { now = 100000, players = defaultPlayers(), audits = {}, handlers = {}, exported = {}, logs = {},
        rules = rules, sqlCalls = 0, canViewCalls = 0 }

    local function player(src) return env.players[tonumber(src)] end
    local function setOf(p) return { grants = p.grants, denied = {}, tier = p.tier, units = p.units, rank = nil } end
    local function viewer(src)
        local p = player(src)
        if not p then return { citizenid = nil, tier = 0, units = {}, grants = Grants.empty() } end
        return { citizenid = p.cid, tier = p.tier, units = p.units, grants = setOf(p) }
    end

    local core = {
        hasGrant = function(_, src, t, k)
            local p = player(src)
            return p ~= nil and Grants.has(setOf(p), t, k)
        end,
        isOnDuty = function(_, src) local p = player(src); return p ~= nil and p.duty == true end,
        getCitizenId = function(_, src) local p = player(src); return p and p.cid or nil end,
        getTier = function(_, src) local p = player(src); return p and p.tier or 0 end,
        getUnits = function(_, src) local p = player(src); return p and deepcopy(p.units) or {} end,
        canView = function(_, src, record) return CanView.evaluate(viewer(src), record, env.rules) end,
        canViewMany = function(_, src, records)
            env.canViewCalls = env.canViewCalls + 1
            local out = {}
            for i, r in ipairs(records) do out[i] = CanView.evaluate(viewer(src), r, env.rules) end
            return out
        end,
        audit = function(_, src, action, targetType, targetId, meta)
            env.audits[#env.audits + 1] = { src = src, action = action, targetType = targetType, targetId = targetId,
                meta = meta }
            return Audit.audit(src, action, targetType, targetId, meta)
        end,
    }
    local qbx = {
        GetPlayer = function(_, src)
            local p = player(src)
            return p and { PlayerData = { citizenid = p.cid, source = tonumber(src) } } or nil
        end,
    }

    function env.clear() env.audits, env.logs = {}, {} end
    function env.auditActions()
        local out = {}
        for _, a in ipairs(env.audits) do out[#out + 1] = a.action end
        return out
    end
    function env.auditsNamed(name)
        local out = {}
        for _, a in ipairs(env.audits) do
            if a.action == name then out[#out + 1] = a end
        end
        return out
    end
    function env.fire(name, eventSource, ...)
        local saved = rawget(_G, 'source')
        rawset(_G, 'source', eventSource)
        for _, fn in ipairs(env.handlers[name] or {}) do fn(...) end
        rawset(_G, 'source', saved)
    end

    env.globals = {
        exports = setmetatable({ fredpd_core = core, qbx_core = qbx }, {
            __call = function(_, name, fn) env.exported[name] = fn end,
        }),
        GetGameTimer = function() return env.now end,
        SetTimeout = function(_, fn) fn() end,
        CreateThread = function(fn) fn() end,
        TriggerEvent = function() end,
        TriggerClientEvent = function() end,
        AddEventHandler = function(name, fn)
            env.handlers[name] = env.handlers[name] or {}
            table.insert(env.handlers[name], fn)
        end,
        GetPlayerIdentifierByType = function(src) return ('discord:%d'):format(900000000000000000 + tonumber(src)) end,
        locale = function(key) return key end,
        lib = {
            print = setmetatable({}, { __index = function(_, level)
                return function(msg) env.logs[#env.logs + 1] = { level = level, msg = msg } end
            end }),
        },
    }
    return env
end

--- Count every MySQL call (graph query budget).
local function countSql(env)
    for _, name in ipairs({ 'query', 'scalar', 'single', 'insert', 'update' }) do
        local api = MySQL[name]
        local inner = api.await
        MySQL[name] = setmetatable({ await = function(...)
            env.sqlCalls = env.sqlCalls + 1
            return inner(...)
        end }, getmetatable(api))
    end
end

local function withEnv(t, fn)
    local ok, reason = shim.available()
    if not ok then
        if not notified then
            print(('SKIP intel_server_test: MariaDB unreachable (%s)'):format((reason or ''):gsub('%s+$', '')))
            notified = true
        end
        return
    end
    local saved = {}
    for _, n in ipairs(GLOBALS) do saved[n] = { rawget(_G, n) } end
    local savedDatabase, savedResource = shim.database, shim.resourceName
    local okRun, err = pcall(function()
        shim.install({ database = DB, sessionTimeZone = '+02:00' })
        shim.resourceName = 'fredpd_core'
        if prepared == nil then
            prepared = false
            shim.resetDatabase(DB, true)
            require('server.db').migrate({ log = function() end, resource = 'fredpd_core' })
            for _, r in ipairs(OFFICERS) do
                MySQL.query.await('INSERT INTO fredpd_officers (citizenid, discord_id, display_name, callsign, unit) '
                    .. 'VALUES (?, ?, ?, ?, ?)', r)
            end
            MySQL.query.await("INSERT INTO fredpd_persons (citizenid, firstname, lastname) VALUES "
                .. "('SUS00001', 'Sven', 'Svensson'), ('INF00001', 'Ingvar', 'Informant'), ('SUS00002', 'Åsa', 'Öberg')")
            MySQL.query.await("INSERT INTO fredpd_vehicles_idx (plate, citizenid, model) VALUES ('ABC123', 'SUS00001', "
                .. "'sultan'), ('NOMODEL1', NULL, NULL)")
            MySQL.query.await("INSERT INTO fredpd_cases (id, case_number, title, status, level, unit, owner_citizenid) "
                .. "VALUES (1, 'K-123-26', 'Hemlig titel', 'open', 0, 'utredning', 'UTR00004')")
            prepared = true
        end
        if not prepared then return end
        for _, tbl in ipairs({ 'fredpd_intel_links', 'fredpd_intel_entities', 'fredpd_intel_reports',
            'fredpd_mission_members', 'fredpd_missions', 'fredpd_intel_sources' }) do
            MySQL.query.await('DELETE FROM ' .. tbl)
            if tbl ~= 'fredpd_mission_members' then MySQL.query.await('ALTER TABLE ' .. tbl .. ' AUTO_INCREMENT = 1') end
        end
        MySQL.query.await("DELETE FROM fredpd_audit WHERE action LIKE 'intel.%' OR action LIKE 'mission.%'")
        local env = makeEnv()
        for k, v in pairs(env.globals) do rawset(_G, k, v) end
        rawset(_G, 'source', nil)
        local mods = loadResource()
        mods.service.configure({ writeCooldownMs = 0, graphCooldownMs = 0 })
        fn(t, env, mods)
    end)
    for n, v in pairs(saved) do rawset(_G, n, v[1]) end
    clearModules()
    shim.sessionTimeZone = nil
    shim.database, shim.resourceName = savedDatabase, savedResource
    if not okRun then error(err, 0) end
end

local function scalar(sql, params) return MySQL.scalar.await(sql, params) end

local function data(res, t, msg)
    t.ok(type(res) == 'table' and res.ok == true, (msg or 'expected ok') .. ': ' .. helper.dump(res))
    return res.data
end

local function err(res) return type(res) == 'table' and res.ok == false and res.error or helper.dump(res) end

--- The §5.8 setup: Span chef creates a Hemlig mission, a person entity, a Hemlig report in the mission and a link
--- from the person to a location on that report. Returns ids.
local function hemlig(t, S)
    local mission = data(S.createMission(1, { title = 'Operation Nattugla', description = 'Hemlig spaning',
        level = 2 }), t, 'createMission')
    local person = data(S.ensureEntity(1, { type = 'person', ref = 'SUS00001', label = 'fel namn från klienten' }), t)
    local report = data(S.createIntelReport(1, { missionId = mission.id, body = 'Sven ses vid Grove Street varje kväll.',
        level = 2, reliability = 'B' }), t, 'createIntelReport')
    local link = data(S.addLink(1, { fromId = person.id, to = { type = 'location', label = 'Grove Street' },
        type = 'seen_at', confidence = 80, level = 2, reportId = report.id }), t, 'addLink')
    return { mission = mission, person = person, report = report, link = link }
end

---------------------------------------------------------------------------------------------------------------
-- Wiring

tests['01 main: every INTEL_ACTIONS export, the §4.3 names and getPersonNotices are registered'] = function(t)
    withEnv(t, function(_, env, mods)
        local names = {}
        for name in pairs(env.exported) do names[#names + 1] = name end
        t.eq(set(names), set({ 'listSources', 'getSource', 'createSource', 'updateSource', 'listIntelReports',
            'getIntelReport', 'createIntelReport', 'searchEntities', 'ensureEntity', 'getEntity', 'addLink', 'getGraph',
            'listMissions', 'getMission', 'createMission', 'addMissionMember', 'closeMission', 'addSource', 'addReport',
            'getPersonNotices' }))
        t.eq(env.exported.addSource, mods.service.createSource)
        t.eq(env.exported.addReport, mods.service.createIntelReport)
        t.ok(env.handlers.playerDropped, 'playerDropped handler')
    end)
end

tests['02 grants, duty and validation come first (unauthorized / validation, nothing written)'] = function(t)
    withEnv(t, function(_, _, mods)
        local S = mods.service
        t.eq(err(S.createMission(5, { title = 'Försök' })), 'unauthorized', 'intel.command needed')
        t.eq(err(S.createMission(7, { title = 'Ledig' })), 'unauthorized', 'off duty')
        t.eq(err(S.createMission(8, { title = 'Civil' })), 'unauthorized')
        t.eq(err(S.createMission(0, { title = 'Konsol' })), 'unauthorized', 'src 0 is not a player')
        t.eq(err(S.createMission('1; DROP', { title = 'x' })), 'unauthorized')
        t.eq(err(S.createMission(1, { title = 'x' })), 'validation')
        t.eq(err(S.createSource(5, { codename = 'Falken' })), 'unauthorized', 'intel.handler needed')
        t.eq(err(S.getSource(3, { id = 1 })), 'unauthorized', 'IGV lacks intel.read')
        t.eq(err(S.searchEntities(9, { query = 'Sven' })), 'unauthorized', 'mdt_page:intel needed')
        t.eq(err(S.getEntity(1, { id = 'x' })), 'validation')
        t.eq(err(S.getGraph(1, { entityId = 1, depth = 3 })), 'validation')
        t.eq(scalar('SELECT COUNT(*) FROM fredpd_missions'), 0)
    end)
end

---------------------------------------------------------------------------------------------------------------
-- §5.8 acceptance

tests['03 §5.8 story: Hemlig mission -> IGV kontaktnotis only, Utredning assigned full, audited Hemlig reads'] =
function(t)
    withEnv(t, function(_, env, mods)
        local S = mods.service
        local h = hemlig(t, S)
        t.eq(h.mission.visibility, 'full')
        t.eq(h.mission.lead.displayName, 'Sara S.')
        t.eq(h.mission.unit, 'span', "lead's primary unit when none is given")
        t.eq(h.person.label, 'Sven Svensson', 'person label derived server-side')
        t.eq(h.report.visibility, 'full')
        t.eq(h.report.mission, { id = h.mission.id, title = 'Operation Nattugla' })
        t.eq(h.link.level, 2)
        t.eq(h.link.to.label, 'Grove Street')
        t.eq(#env.auditsNamed('intel.report.read'), 0, 'the author creating a report is not a read')

        -- IGV searching the subject: finds the entity, sees no link, no report, only the kontaktnotis
        local found = data(S.searchEntities(3, { query = 'Sven' }), t)
        t.eq(#found.items, 1)
        t.eq(found.items[1].id, h.person.id)
        local igv = data(S.getEntity(3, { id = h.person.id }), t)
        t.eq(igv.links, {})
        t.eq(igv.hiddenLinks, 1)
        t.eq(igv.reports, {})
        t.eq(igv.notices, { { visibility = 'notice', contact = { displayName = 'Sara S.', unit = 'span' } } })
        t.eq(data(S.getMission(3, { id = h.mission.id }), t),
            { visibility = 'notice', contact = { displayName = 'Sara S.', unit = 'span' } })
        -- the person page (fredpd_records): same notice, also for an IGV without the intel page
        t.eq(S.getPersonNotices(3, 'SUS00001'), igv.notices)
        t.eq(S.getPersonNotices(9, 'SUS00001'), igv.notices)
        t.eq(S.getPersonNotices(8, 'SUS00001'), {}, 'off duty civilian: nothing')
        t.eq(S.getPersonNotices(3, 'INF00001'), {}, 'no intel on this person')
        t.eq(S.getPersonNotices(3, "x' OR 1=1"), {})

        -- Utredning before assignment: intel.read, tier 1 -> kontaktnotis, never the body
        local before = data(S.getIntelReport(4, { id = h.report.id }), t)
        t.eq(before, { visibility = 'notice', contact = { displayName = 'Sara S.', unit = 'span' } })
        t.eq(data(S.getEntity(4, { id = h.person.id }), t).hiddenLinks, 1)
        -- a Span analyst with intel.read and tier 2 but outside the mission: the mission cap keeps it a notice
        t.eq(data(S.getIntelReport(5, { id = h.report.id }), t).visibility, 'notice')
        t.eq(#env.auditsNamed('intel.report.read'), 0)

        -- Utredning assigned -> full, every read of the Hemlig report audited
        local mission = data(S.addMissionMember(1, { id = h.mission.id, citizenid = 'UTR00004', role = 'utredare' }), t)
        t.eq(mission.members, { { citizenid = 'UTR00004', displayName = 'Ulla U.', callsign = 'UTR-04',
            unit = 'utredning', role = 'utredare' } })
        t.eq(data(S.getMission(4, { id = h.mission.id }), t).visibility, 'full')
        local full = data(S.getIntelReport(4, { id = h.report.id }), t)
        t.eq(full.visibility, 'full')
        t.eq(full.body, 'Sven ses vid Grove Street varje kväll.')
        t.eq(full.author.displayName, 'Sara S.')
        t.eq(#full.links, 1)
        t.eq(full.links[1].id, h.link.id)
        data(S.getIntelReport(4, { id = h.report.id }), t)
        data(S.getIntelReport(1, { id = h.report.id }), t)
        local list = data(S.listIntelReports(4, { missionId = h.mission.id }), t)
        t.eq(list.total, 1)
        t.eq(list.items[1].body, full.body)
        local reads = env.auditsNamed('intel.report.read')
        t.eq(#reads, 4, 'two gets by Utredning, one by the lead, one list')
        t.eq(reads[4].meta, { via = 'list' })
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_audit WHERE action = 'intel.report.read' AND target_type = "
            .. "'intel_report' AND target_id = ?", { tostring(h.report.id) }), 4, 'rows in fredpd_audit')
        t.eq(scalar("SELECT actor_citizenid FROM fredpd_audit WHERE action = 'intel.report.read' ORDER BY id LIMIT 1"),
            'UTR00004')

        local utr = data(S.getEntity(4, { id = h.person.id }), t)
        t.eq(#utr.links, 1)
        t.eq(utr.hiddenLinks, 0)
        t.eq(utr.notices, {})
        t.eq(#utr.reports, 1)
        t.eq(utr.reports[1].author.citizenid, 'SPA00001')
        t.eq(S.getPersonNotices(4, 'SUS00001'), {}, 'full view: no notice')
        -- the IGV still sees only the notice
        t.eq(data(S.getEntity(3, { id = h.person.id }), t).notices, igv.notices)

        -- audit trail of the writes
        local actions = set(env.auditActions())
        for _, a in ipairs({ 'mission.create', 'intel.entity.create', 'intel.report.create', 'intel.link.create',
            'mission.member.add', 'intel.entity.view' }) do
            local found2 = false
            for _, x in ipairs(actions) do if x == a then found2 = true end end
            t.ok(found2, 'audited ' .. a)
        end
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Sources

tests['04 sources: identity only for handler+intel.handler or intel.command, each read audited'] = function(t)
    withEnv(t, function(_, env, mods)
        local S = mods.service
        local src = data(S.createSource(2, { codename = 'Falken', reliability = 'B', notes = 'Träffas vid hamnen',
            realCitizenid = 'INF00001', handler = 'SPA00001', handlerCitizenid = 'SPA00001' }), t)
        t.eq(src.visibility, 'full')
        t.eq(src.handler.citizenid, 'HAN00002', 'handler is the caller, never input')
        t.eq(scalar('SELECT handler_citizenid FROM fredpd_intel_sources WHERE id = ?', { src.id }), 'HAN00002')
        t.eq(src.realIdentity, { citizenid = 'INF00001', name = 'Ingvar Informant' })
        t.eq(src.unit, 'span')
        env.clear()

        local handler = data(S.getSource(2, { id = src.id }), t)
        t.eq(handler.realIdentity.citizenid, 'INF00001')
        local command = data(S.getSource(1, { id = src.id }), t)
        t.eq(command.visibility, 'full')
        t.eq(command.realIdentity.citizenid, 'INF00001')
        t.eq(#env.auditsNamed('intel.source.identity'), 2)
        t.eq(env.auditsNamed('intel.source.identity')[1].meta, { via = 'get' })

        local other = data(S.getSource(6, { id = src.id }), t)
        t.eq(other, { visibility = 'masked', id = src.id, codename = 'Falken', reliability = 'B', status = 'open',
            level = 2 }, 'another handler: masked')
        t.eq(data(S.getSource(5, { id = src.id }), t).visibility, 'masked', 'intel.read: masked')
        t.eq(data(S.getSource(10, { id = src.id }), t).visibility, 'masked', 'the handler without intel.handler')
        local utr = data(S.getSource(4, { id = src.id }), t)
        t.eq(utr, { visibility = 'notice', contact = { displayName = 'Hans H.', unit = 'span' } }, 'tier 1: notice')
        t.eq(#env.auditsNamed('intel.source.identity'), 2, 'no identity, no audit')

        -- lists never carry an identity
        local list = data(S.listSources(2, {}), t)
        t.eq(list.total, 1)
        t.eq(list.items[1].visibility, 'full')
        t.eq(list.items[1].realIdentity, nil)
        t.eq(#env.auditsNamed('intel.source.identity'), 2)

        -- update: handler or command only; others unauthorized
        t.eq(err(S.updateSource(6, { id = src.id, status = 'closed' })), 'unauthorized')
        local upd = data(S.updateSource(2, { id = src.id, reliability = 'A', notes = ' ' }), t)
        t.eq(upd.reliability, 'A')
        t.eq(upd.notes, nil)
        t.eq(env.auditsNamed('intel.source.update')[1].meta.fields, { 'reliability', 'notes' })
        t.eq(err(S.updateSource(1, { id = src.id, status = 'closed' })), 'unauthorized',
            'INTEL_ACTIONS: updateSource needs perm intel.handler, intel.command alone is not enough')
        data(S.updateSource(2, { id = src.id, status = 'closed' }), t)
        t.eq(scalar('SELECT status FROM fredpd_intel_sources WHERE id = ?', { src.id }), 'closed')

        -- codename unique, identity must be a known person, level above tier refused
        t.eq(err(S.createSource(2, { codename = 'Falken' })), 'validation')
        t.eq(err(S.createSource(6, { codename = 'Örnen', realCitizenid = 'NOBODY01' })), 'validation')
        env.players[6].tier = 1
        t.eq(err(S.createSource(6, { codename = 'Örnen', level = 2 })), 'validation')
        t.eq(data(S.createSource(6, { codename = 'Örnen', level = 1 }), t).realIdentity, nil)
    end)
end

tests['05 none is not_found, exactly like a missing id'] = function(t)
    withEnv(t, function(_, env, mods)
        local S = mods.service
        local src = data(S.createSource(2, { codename = 'Uven' }), t)
        -- switch off the intel.read masked rule: an analyst now gets 'none'
        for _, r in ipairs(env.rules) do
            if r.id == 82 then r.enabled = false end
        end
        t.eq(err(S.getSource(5, { id = src.id })), 'not_found')
        t.eq(err(S.getSource(5, { id = 999 })), 'not_found')
        t.eq(data(S.listSources(5, {}), t), { items = {}, total = 0, page = 1 })
        -- reports: a report nobody but the author may see
        for _, r in ipairs(env.rules) do
            if r.id == 72 then r.enabled = false end
        end
        local rep = data(S.createIntelReport(5, { body = 'Egen anteckning', level = 0 }), t)
        t.eq(err(S.getIntelReport(4, { id = rep.id })), 'not_found')
        t.eq(err(S.getIntelReport(4, { id = rep.id + 100 })), 'not_found')
        t.eq(data(S.getIntelReport(5, { id = rep.id }), t).visibility, 'full')
        t.eq(err(S.updateSource(6, { id = src.id + 100 })), 'not_found')
        -- missions: without the notice fallback rule a non-member gets not_found, also for writes
        local m = data(S.createMission(1, { title = 'Tyst insats' }), t)
        for _, r in ipairs(env.rules) do
            if r.id == 62 then r.enabled = false end
        end
        t.eq(err(S.getMission(4, { id = m.id })), 'not_found')
        t.eq(err(S.addMissionMember(4, { id = m.id, citizenid = 'UTR00004' })), 'not_found')
        t.eq(data(S.listMissions(4, {}), t).total, 0)
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Entities

tests['06 entities: refs validated, labels derived server-side, (type, ref) dedup'] = function(t)
    withEnv(t, function(_, env, mods)
        local S = mods.service
        t.eq(err(S.ensureEntity(5, { type = 'person', ref = 'NOBODY01', label = 'Hittepå' })), 'not_found')
        t.eq(err(S.ensureEntity(5, { type = 'person', label = 'Utan ref' })), 'validation')
        t.eq(err(S.ensureEntity(5, { type = 'person', ref = 'bad ref', label = 'x' })), 'validation')
        t.eq(err(S.ensureEntity(5, { type = 'vehicle', ref = 'ZZZ999', label = 'x' })), 'not_found')
        t.eq(err(S.ensureEntity(5, { type = 'case', ref = 'K-999-26', label = 'x' })), 'not_found')
        local veh = data(S.ensureEntity(5, { type = 'vehicle', ref = 'abc 123', label = 'Min bil' }), t)
        t.eq(veh, { id = veh.id, type = 'vehicle', ref = 'ABC123', label = 'ABC123 (sultan)' })
        t.eq(data(S.ensureEntity(5, { type = 'vehicle', ref = 'NOMODEL1', label = 'x' }), t).label, 'NOMODEL1')
        -- player 5 (Span) only has the default 'notice' view of the Utredning case: answered like a missing case
        t.eq(err(S.ensureEntity(5, { type = 'case', ref = 'K-123-26', label = 'x' })), 'not_found')
        local case = data(S.ensureEntity(4, { type = 'case', ref = 'K-123-26', label = 'x' }), t)
        t.eq(case.label, 'K-123-26', 'case number only, never the title')
        local p1 = data(S.ensureEntity(5, { type = 'person', ref = 'SUS00002', label = 'x' }), t)
        t.eq(p1.label, 'Åsa Öberg')
        local p2 = data(S.ensureEntity(4, { type = 'person', ref = 'SUS00002', label = 'annat' }), t)
        t.eq(p2.id, p1.id, 'dedup on (type, ref)')
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_intel_entities WHERE type = 'person'"), 1)
        -- a renamed person is relabelled (audited) on the next ensure
        MySQL.query.await("UPDATE fredpd_persons SET lastname = 'Berg' WHERE citizenid = 'SUS00002'")
        env.clear()
        t.eq(data(S.ensureEntity(5, { type = 'person', ref = 'SUS00002', label = 'x' }), t).label, 'Åsa Berg')
        t.eq(env.auditActions(), { 'intel.entity.relabel', 'intel.entity.view' }, 'relabel + the lookup itself')
        env.clear()
        data(S.ensureEntity(4, { type = 'person', ref = 'SUS00002', label = 'x' }), t)
        data(S.ensureEntity(4, { type = 'vehicle', ref = 'ABC123', label = 'x' }), t)
        t.eq(env.auditActions(), { 'intel.entity.view', 'intel.entity.view' },
            'every ensure of an existing person/vehicle is an audited lookup (§4.5)')
        t.eq(env.audits[1].meta, { type = 'person', ref = 'SUS00002', via = 'ensure' })
        MySQL.query.await("UPDATE fredpd_persons SET lastname = 'Öberg' WHERE citizenid = 'SUS00002'")
        -- keyless: label from input, dedup by label
        local loc = data(S.ensureEntity(5, { type = 'location', label = 'Grove Street' }), t)
        t.eq(data(S.ensureEntity(4, { type = 'location', label = 'Grove Street' }), t).id, loc.id)
        t.eq(scalar('SELECT created_by FROM fredpd_intel_entities WHERE id = ?', { loc.id }), 'ANA00005')
    end)
end

tests['07 search: prefix only, wildcards and quotes are data, limit 25'] = function(t)
    withEnv(t, function(_, _, mods)
        local S = mods.service
        for _, label in ipairs({ '100% Gang', '100X Gang', 'a_b grupp', 'axb grupp', "O'Brien crew" }) do
            data(S.ensureEntity(5, { type = 'group', label = label }), t)
        end
        local function labels(q, ty)
            local out = {}
            for _, e in ipairs(data(S.searchEntities(3, { query = q, type = ty }), t).items) do out[#out + 1] = e.label end
            return out
        end
        t.eq(labels('100%'), { '100% Gang' })
        t.eq(labels('a_'), { 'a_b grupp' })
        t.eq(labels("O'B"), { "O'Brien crew" })
        t.eq(labels("x' OR '1'='1"), {})
        t.eq(labels('%%'), {})
        t.eq(labels('Gang'), {}, 'prefix, not substring')
        t.eq(labels('100', 'person'), {}, 'type filter')
        t.eq(#labels('10', 'group'), 2)
        t.eq(scalar('SELECT COUNT(*) FROM fredpd_intel_entities'), 5, 'table intact')
        local values = {}
        for i = 1, 30 do values[#values + 1] = ("('location', NULL, 'Plats %02d')"):format(i) end
        MySQL.query.await('INSERT INTO fredpd_intel_entities (type, ref, label) VALUES ' .. table.concat(values, ', '))
        t.eq(#labels('Plats'), 25)
    end)
end

tests['08 links: 3-click flow, same ends refused, report must be visible, level capped by tier'] = function(t)
    withEnv(t, function(_, env, mods)
        local S = mods.service
        local p = data(S.ensureEntity(4, { type = 'person', ref = 'SUS00001', label = 'x' }), t)
        local link = data(S.addLink(4, { fromId = p.id, to = { type = 'vehicle', ref = 'ABC123', label = 'x' },
            type = 'owns' }), t)
        t.eq(link.from.id, p.id)
        t.eq(link.to.label, 'ABC123 (sultan)')
        t.eq(link.confidence, 50)
        t.eq(link.level, 1)
        t.eq(link.createdBy.citizenid, 'UTR00004')
        t.ok(link.createdAt:match(ISO), 'ISO UTC')
        -- UTC although the session runs at +02:00
        local utc = scalar("SELECT TIMESTAMPDIFF(MINUTE, created_at, UTC_TIMESTAMP()) FROM fredpd_intel_links "
            .. 'WHERE id = ?', { link.id })
        t.ok(math.abs(utc) < 5, 'created_at is UTC: ' .. tostring(utc))
        -- same link again: the stored one comes back, no second row
        local again = data(S.addLink(4, { fromId = p.id, to = { id = link.to.id }, type = 'owns' }), t)
        t.eq(again.id, link.id)
        t.eq(scalar('SELECT COUNT(*) FROM fredpd_intel_links'), 1)
        t.eq(err(S.addLink(4, { fromId = p.id, to = { id = p.id }, type = 'owns' })), 'validation')
        t.eq(err(S.addLink(4, { fromId = 999, to = { id = p.id }, type = 'owns' })), 'not_found')
        t.eq(err(S.addLink(4, { fromId = p.id, to = { id = 999 }, type = 'owns' })), 'not_found')
        t.eq(err(S.addLink(4, { fromId = p.id, to = { id = link.to.id }, type = 'owns', level = 2 })), 'validation',
            'tier 1 cannot write level 2')
        local h = hemlig(t, S)
        t.eq(err(S.addLink(4, { fromId = p.id, to = { id = link.to.id }, type = 'uses', reportId = h.report.id })),
            'unauthorized', 'a report seen only as a notice')
        t.eq(err(S.addLink(4, { fromId = p.id, to = { id = link.to.id }, type = 'uses', reportId = 999 })), 'not_found')
        t.eq(scalar('SELECT created_by FROM fredpd_intel_links WHERE id = ?', { link.id }), 'UTR00004')
        -- IGV cannot see the Utredning link either (no intel.read)
        t.eq(data(S.getEntity(3, { id = p.id }), t).hiddenLinks, 2)
        t.ok(#env.auditsNamed('intel.link.create') >= 2)
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Graph

--- Root + n entities linked to it (level 0, standalone, by ANA00005), inserted in two statements. Returns root id.
local function star(n)
    local values = { "('person', 'SUS00001', 'Sven Svensson')" }
    for i = 1, n do values[#values + 1] = ("('location', 'L%03d', 'Plats %03d')"):format(i, i) end
    MySQL.query.await('INSERT INTO fredpd_intel_entities (type, ref, label) VALUES ' .. table.concat(values, ', '))
    local root = scalar("SELECT id FROM fredpd_intel_entities WHERE type = 'person' AND ref = 'SUS00001'")
    local links = {}
    for i = 1, n do
        links[#links + 1] = ("(%d, %d, 'seen_at', 50, 'ANA00005', 0)"):format(root, root + i)
    end
    MySQL.query.await('INSERT INTO fredpd_intel_links (from_id, to_id, type, confidence, created_by, level) VALUES '
        .. table.concat(links, ', '))
    return root
end

tests['09 graph: 200 neighbours capped at 150 nodes, truncated, root flagged, few queries'] = function(t)
    withEnv(t, function(_, env, mods)
        local S = mods.service
        local root = star(200)
        countSql(env)
        env.sqlCalls, env.canViewCalls = 0, 0
        local g = data(S.getGraph(5, { entityId = root }), t)
        t.eq(#g.nodes, 150)
        t.eq(g.truncated, true)
        t.eq(g.nodes[1].id, root)
        t.eq(g.nodes[1].root, true)
        local roots = 0
        for _, n in ipairs(g.nodes) do if n.root then roots = roots + 1 end end
        t.eq(roots, 1)
        t.eq(#g.edges, 149, 'edges only between included nodes')
        t.eq(g.edges[1].id, 200, 'newest links first')
        t.ok(env.sqlCalls <= 4, 'queries for depth 1: ' .. env.sqlCalls)
        t.ok(env.canViewCalls <= 2, 'canViewMany calls: ' .. env.canViewCalls)
        -- depth 2 over a capped graph stays capped (no second level work beyond one query)
        env.sqlCalls = 0
        local g2 = data(S.getGraph(5, { entityId = root, depth = 2 }), t)
        t.eq(#g2.nodes, 150)
        t.eq(g2.truncated, true)
        t.ok(env.sqlCalls <= 7, 'queries for depth 2: ' .. env.sqlCalls)
        -- IGV-level viewers: no intel.read -> unauthorized; §4.3 form getGraph(entityId, viewerSrc)
        t.eq(err(S.getGraph(3, { entityId = root })), 'unauthorized')
        local g3 = data(S.getGraph(root, 5), t)
        t.eq(#g3.nodes, 150)
        t.eq(err(S.getGraph(5, { entityId = 99999 })), 'not_found')
        -- a small star is complete
    end)
end

tests['10 graph: depth 2 walks visible links only; hidden links never become nodes or edges'] = function(t)
    withEnv(t, function(_, _, mods)
        local S = mods.service
        local function ent(label) return data(S.ensureEntity(1, { type = 'group', label = label }), t).id end
        local a, b, c, d, e = ent('A-gruppen'), ent('B-gruppen'), ent('C-gruppen'), ent('D-gruppen'), ent('E-gruppen')
        data(S.addLink(4, { fromId = a, to = { id = b }, type = 'associate' }), t)
        data(S.addLink(4, { fromId = c, to = { id = b }, type = 'associate' }), t) -- reached backwards (to -> from)
        data(S.addLink(1, { fromId = b, to = { id = d }, type = 'associate', level = 2 }), t) -- Hemlig, Span only
        data(S.addLink(4, { fromId = c, to = { id = e }, type = 'associate' }), t) -- depth 3
        local function ids(g)
            local out = {}
            for _, n in ipairs(g.nodes) do out[#out + 1] = n.id end
            table.sort(out)
            return out
        end
        local g1 = data(S.getGraph(4, { entityId = a, depth = 1 }), t)
        t.eq(ids(g1), { a, b })
        t.eq(g1.truncated, false)
        local g2 = data(S.getGraph(4, { entityId = a, depth = 2 }), t)
        t.eq(ids(g2), { a, b, c }, 'D is behind a Hemlig link, E is depth 3')
        t.eq(#g2.edges, 2)
        local span = data(S.getGraph(1, { entityId = a, depth = 2 }), t)
        t.eq(ids(span), { a, b, c, d }, 'intel.command sees the Hemlig link')
        local detail = data(S.getEntity(4, { id = b }), t)
        t.eq(#detail.links, 2)
        t.eq(detail.hiddenLinks, 1)
        for _, l in ipairs(detail.links) do t.ok(l.to.id ~= d and l.from.id ~= d, 'no detail of the hidden link') end
        t.ok(detail.links[1].id > detail.links[2].id, 'newest first')
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Missions and reports

tests['11 missions: lead from the caller, members must be officers, lead/command only, close is final'] = function(t)
    withEnv(t, function(_, env, mods)
        local S = mods.service
        local m = data(S.createMission(1, { title = 'Insats Ek', unit = 'narko', level = 1, lead = 'UTR00004' }), t)
        t.eq(m.lead.citizenid, 'SPA00001')
        t.eq(m.unit, 'narko')
        t.eq(err(S.addMissionMember(4, { id = m.id, citizenid = 'UTR00004' })), 'unauthorized', 'not lead')
        t.eq(err(S.addMissionMember(1, { id = m.id, citizenid = 'NOBODY01' })), 'validation', 'not an officer')
        t.eq(err(S.addMissionMember(1, { id = 999, citizenid = 'UTR00004' })), 'not_found')
        data(S.addMissionMember(1, { id = m.id, citizenid = 'ANA00005' }), t)
        env.clear()
        data(S.addMissionMember(1, { id = m.id, citizenid = 'ANA00005' }), t)
        t.eq(env.auditActions(), {}, 'no change, no audit')
        data(S.addMissionMember(1, { id = m.id, citizenid = 'ANA00005', role = 'spanare' }), t)
        t.eq(env.auditActions(), { 'mission.member.role' })
        -- a member (not lead) cannot add or close
        t.eq(err(S.closeMission(5, { id = m.id })), 'unauthorized')
        -- member files a report in the mission; a non-member cannot
        local rep = data(S.createIntelReport(5, { missionId = m.id, body = 'Observation', level = 1 }), t)
        t.eq(rep.mission.title, 'Insats Ek')
        t.eq(err(S.createIntelReport(4, { missionId = m.id, body = 'Försök' })), 'unauthorized')
        t.eq(err(S.createIntelReport(4, { missionId = 999, body = 'Försök' })), 'not_found')
        local got = data(S.getMission(5, { id = m.id }), t)
        t.eq(got.reports, { { id = rep.id, level = 1, createdAt = rep.createdAt } })
        t.eq(got.members[1].role, 'spanare')
        env.clear()
        local closed = data(S.closeMission(1, { id = m.id }), t)
        t.eq(closed.status, 'closed')
        data(S.closeMission(1, { id = m.id }), t)
        t.eq(env.auditActions(), { 'mission.close' }, 'second close is a no-op')
        t.eq(err(S.addMissionMember(1, { id = m.id, citizenid = 'UTR00004' })), 'validation', 'closed')
        t.eq(err(S.createIntelReport(5, { missionId = m.id, body = 'Sent' })), 'validation', 'closed')
        local list = data(S.listMissions(3, {}), t)
        t.eq(list.total, 1)
        t.eq(list.items[1], { visibility = 'notice', contact = { displayName = 'Sara S.', unit = 'narko' } })
    end)
end

tests['12 reports: author from the caller, source reports only by its handler, level above tier refused'] = function(t)
    withEnv(t, function(_, _, mods)
        local S = mods.service
        local src = data(S.createSource(2, { codename = 'Kråkan', level = 2 }), t)
        local rep = data(S.createIntelReport(2, { sourceId = src.id, body = 'Källan säger...', level = 2,
            author = 'SPA00001' }), t)
        t.eq(rep.author.citizenid, 'HAN00002')
        t.eq(rep.source, { id = src.id, codename = 'Kråkan' })
        t.eq(err(S.createIntelReport(5, { sourceId = src.id, body = 'Inte min källa' })), 'unauthorized')
        t.eq(err(S.createIntelReport(5, { sourceId = 999, body = 'Ingen källa' })), 'not_found')
        t.eq(err(S.createIntelReport(4, { body = 'För hemligt', level = 2 })), 'validation')
        -- a standalone Hemlig report: intel.read tier 2 reads it (audited), tier 1 gets the author's notice
        local analyst = data(S.getIntelReport(5, { id = rep.id }), t)
        t.eq(analyst.visibility, 'full')
        t.eq(analyst.source, { id = src.id, codename = 'Kråkan' }, 'codename is not identifying (masked source)')
        t.eq(data(S.getIntelReport(4, { id = rep.id }), t),
            { visibility = 'notice', contact = { displayName = 'Hans H.', unit = 'span' } })
        local list = data(S.listIntelReports(4, {}), t)
        t.eq(list.total, 1)
        t.eq(list.items[1].visibility, 'notice')
        t.eq(data(S.listIntelReports(4, { sourceId = src.id, page = 2 }), t), { items = {}, total = 0, page = 2 },
            'source seen only as a notice: the filter matches nothing')
    end)
end

tests['13 rate limits on writes and the graph; playerDropped forgets them'] = function(t)
    withEnv(t, function(_, env, mods)
        local S = mods.service
        S.configure({ writeCooldownMs = 500, graphCooldownMs = 250 })
        data(S.ensureEntity(5, { type = 'group', label = 'Gäng 1' }), t)
        t.eq(err(S.ensureEntity(5, { type = 'group', label = 'Gäng 2' })), 'rate_limited')
        data(S.ensureEntity(4, { type = 'group', label = 'Gäng 3' }), t) -- per player
        env.now = env.now + 500
        local g = data(S.ensureEntity(5, { type = 'group', label = 'Gäng 2' }), t)
        data(S.getGraph(5, { entityId = g.id }), t)
        t.eq(err(S.getGraph(5, { entityId = g.id })), 'rate_limited')
        data(S.searchEntities(5, { query = 'Gäng' }), t) -- reads: the dispatcher limits them
        env.fire('playerDropped', 5)
        data(S.getGraph(5, { entityId = g.id }), t)
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Review fixes (leaks through filters, hidden links, counts, failed writes, case numbers)

tests['15 listIntelReports: the sourceId filter never attributes reports to a source the viewer cannot see'] =
function(t)
    withEnv(t, function(_, _, mods)
        local S = mods.service
        local src = data(S.createSource(2, { codename = 'Svalan', level = 2 }), t)
        local rep = data(S.createIntelReport(2, { sourceId = src.id, body = 'Tips om lager', level = 1 }), t)
        local other = data(S.createIntelReport(4, { body = 'Annat', level = 0 }), t)
        -- Utredning: the source is only a notice, the report is full but without its source
        t.eq(data(S.getSource(4, { id = src.id }), t).visibility, 'notice')
        local got = data(S.getIntelReport(4, { id = rep.id }), t)
        t.eq(got.visibility, 'full')
        t.eq(got.source, nil)
        t.eq(data(S.listIntelReports(4, { sourceId = src.id }), t), { items = {}, total = 0, page = 1 },
            'no grouping of reports by a hidden source')
        t.eq(err(S.listIntelReports(4, { sourceId = src.id + 100 })), 'not_found')
        -- an analyst (source masked, report full) may filter; the answer shows the source anyway
        local list = data(S.listIntelReports(5, { sourceId = src.id }), t)
        t.eq(list.total, 1)
        t.eq(list.items[1].id, rep.id)
        t.eq(list.items[1].source, { id = src.id, codename = 'Svalan' })
        t.ok(other.id, 'unfiltered report exists')
        t.eq(data(S.listIntelReports(4, {}), t).total, 2, 'unfiltered list unchanged')
    end)
end

tests['16 getEntity: a report behind a hidden link is not listed'] = function(t)
    withEnv(t, function(_, env, mods)
        local S = mods.service
        env.players[11] = { cid = 'UTR00011', duty = true, tier = 1, units = { 'utredning' },
            grants = set({ 'mdt_page:intel', 'perm:intel.read', 'unit:utredning' }) }
        local p = data(S.ensureEntity(4, { type = 'person', ref = 'SUS00001', label = 'x' }), t)
        local rep = data(S.createIntelReport(4, { body = 'Öppen iakttagelse', level = 0 }), t)
        t.eq(data(S.getIntelReport(11, { id = rep.id }), t).visibility, 'full', 'the report itself is readable')
        data(S.addLink(1, { fromId = p.id, to = { type = 'group', label = 'Hemliga gruppen' }, type = 'member_of',
            level = 2, reportId = rep.id }), t)
        local view = data(S.getEntity(11, { id = p.id }), t)
        t.eq(view.links, {})
        t.eq(view.hiddenLinks, 1)
        t.eq(view.reports, {}, 'the hidden link is not tied to a report')
        local cmd = data(S.getEntity(1, { id = p.id }), t)
        t.eq(#cmd.reports, 1)
        t.eq(cmd.reports[1].id, rep.id)
    end)
end

tests['17 listIntelReports: a secret mission is one kontaktnotis, never a per-report count'] = function(t)
    withEnv(t, function(_, _, mods)
        local S = mods.service
        local m = data(S.createMission(1, { title = 'Insats Gran', level = 2 }), t)
        data(S.createIntelReport(1, { missionId = m.id, body = 'Rapport 1', level = 2 }), t)
        data(S.createIntelReport(1, { missionId = m.id, body = 'Rapport 2', level = 2 }), t)
        local list = data(S.listIntelReports(5, {}), t)
        t.eq(list, { items = { { visibility = 'notice', contact = { displayName = 'Sara S.', unit = 'span' } } },
            total = 1, page = 1 })
        t.eq(data(S.listIntelReports(5, { missionId = m.id }), t), { items = {}, total = 0, page = 1 },
            'mission seen only as a notice: its reports are not counted')
        t.eq(err(S.listIntelReports(5, { missionId = m.id + 100 })), 'not_found')
        t.eq(data(S.listIntelReports(1, { missionId = m.id }), t).total, 2, 'the lead sees both')
    end)
end

tests['18 addLink: an unauthorized result writes nothing'] = function(t)
    withEnv(t, function(_, env, mods)
        local S = mods.service
        local a = data(S.ensureEntity(4, { type = 'group', label = 'Grupp A' }), t)
        local b = data(S.ensureEntity(4, { type = 'group', label = 'Grupp B' }), t)
        for _, r in ipairs(env.rules) do
            if r.id == 71 or r.id == 72 then r.enabled = false end
        end
        env.clear()
        t.eq(err(S.addLink(4, { fromId = a.id, to = { id = b.id }, type = 'associate' })), 'unauthorized')
        t.eq(scalar('SELECT COUNT(*) FROM fredpd_intel_links'), 0, 'no row left behind')
        t.eq(env.auditsNamed('intel.link.create'), {}, 'no audit of a write that did not happen')
        -- a new 'to' entity is created only after every check has passed: none here
        t.eq(err(S.addLink(4, { fromId = a.id, to = { type = 'group', label = 'Grupp C' }, type = 'associate' })),
            'unauthorized')
        t.eq(scalar('SELECT COUNT(*) FROM fredpd_intel_links'), 0)
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_intel_entities WHERE label = 'Grupp C'"), 0, 'no entity written')
        t.eq(env.auditsNamed('intel.entity.create'), {}, 'no entity audit either')
        -- a missing report is not_found and writes nothing either
        t.eq(err(S.addLink(4, { fromId = a.id, to = { type = 'group', label = 'Grupp D' }, type = 'associate',
            reportId = 999 })), 'not_found')
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_intel_entities WHERE label = 'Grupp D'"), 0)
    end)
end

tests['19 case entities: hidden unless the case view is full/masked (default rules: notice hides it too)'] =
function(t)
    withEnv(t, function(_, env, mods)
        local S = mods.service
        MySQL.query.await("DELETE FROM fredpd_cases WHERE id = 2")
        MySQL.query.await("INSERT INTO fredpd_cases (id, case_number, title, status, level, unit, owner_citizenid) "
            .. "VALUES (2, 'K-124-26', 'Stängt hemligt', 'closed', 2, 'utredning', 'UTR00004')")
        local okRun, e = pcall(function()
            -- Default rules stay on: rule 14 + hard cap 2 give the IGV a 'notice' view of the Hemlig case, which
            -- must hide the case entity exactly like 'none' (a case notice never carries the case number).
            local rule14
            for _, r in ipairs(env.rules) do
                if r.id == 14 then rule14 = r end
            end
            t.ok(rule14 and rule14.enabled ~= false, 'rule 14 (case notice for everyone) is on')
            local case = data(S.ensureEntity(4, { type = 'case', ref = 'K-124-26', label = 'x' }), t, 'owner ensures')
            -- player 12: intel.read, tier 0, not on the case
            env.players[12] = { cid = 'IGV00012', duty = true, tier = 0, units = { 'igv' },
                grants = set({ 'mdt_page:intel', 'perm:intel.read', 'unit:igv' }) }
            local cv = exports.fredpd_core:canViewMany(12, { { type = 'case', id = 2, level = 2, unit = 'utredning',
                ownerCitizenid = 'UTR00004', status = 'closed', assignees = {} } })
            t.eq(cv[1], 'notice', 'the IGV has a case kontaktnotis, not none')
            t.eq(err(S.ensureEntity(12, { type = 'case', ref = 'K-124-26', label = 'x' })), 'not_found',
                'no existence probe: same answer as a missing case')
            t.eq(err(S.ensureEntity(12, { type = 'case', ref = 'K-999-26', label = 'x' })), 'not_found')
            local p = data(S.ensureEntity(4, { type = 'person', ref = 'SUS00001', label = 'x' }), t)
            local link = data(S.addLink(4, { fromId = p.id, to = { id = case.id }, type = 'associate', level = 0 }), t)
            t.eq(data(S.searchEntities(4, { query = 'K-124' }), t).items[1].id, case.id)
            t.eq(data(S.searchEntities(3, { query = 'K-124' }), t).items, {}, 'case number not revealed by search')
            t.eq(data(S.searchEntities(12, { query = 'K-' }), t).items, {}, 'nor by a bare prefix')
            t.eq(err(S.getEntity(3, { id = case.id })), 'not_found', 'exactly like a missing id')
            t.eq(data(S.getEntity(4, { id = case.id }), t).entity.label, 'K-124-26')
            -- player 12: the level-0 link is visible by the rules, but its case end is hidden
            local pv = data(S.getEntity(12, { id = p.id }), t)
            t.eq(pv.links, {})
            t.eq(pv.hiddenLinks, 1)
            local g = data(S.getGraph(12, { entityId = p.id }), t)
            t.eq(#g.nodes, 1, 'only the root')
            t.eq(g.edges, {})
            t.eq(err(S.getGraph(12, { entityId = case.id })), 'not_found')
            t.eq(err(S.addLink(12, { fromId = p.id, to = { id = case.id }, type = 'uses', level = 0 })), 'not_found')
            t.eq(err(S.addLink(12, { fromId = p.id, to = { type = 'case', ref = 'K-124-26', label = 'x' },
                type = 'uses', level = 0 })), 'not_found')
            t.eq(err(S.addLink(12, { fromId = case.id, to = { id = case.id }, type = 'uses', level = 0 })), 'not_found',
                'from = to on a hidden case: not_found, like a missing id (no validation leak)')
            t.eq(err(S.addLink(12, { fromId = case.id, to = { type = 'person', ref = 'bad!', label = 'x' },
                type = 'uses', level = 0 })), 'not_found', 'hidden from + malformed to: not_found (no existence leak)')
            t.eq(err(S.addLink(12, { fromId = 99999, to = { type = 'person', ref = 'bad!', label = 'x' },
                type = 'uses', level = 0 })), 'not_found', 'missing from + malformed to: same answer')
            t.eq(err(S.addLink(12, { fromId = 99999, to = { id = 99999 }, type = 'uses', level = 0 })), 'not_found')
            local g4 = data(S.getGraph(4, { entityId = p.id }), t)
            t.eq(#g4.nodes, 2)
            t.eq(g4.edges[1].id, link.id)
        end)
        MySQL.query.await("DELETE FROM fredpd_cases WHERE id = 2")
        if not okRun then error(e, 0) end
    end)
end

tests['20 searchEntities: person/vehicle results are an audited lookup, one row per call'] = function(t)
    withEnv(t, function(_, env, mods)
        local S = mods.service
        local p = data(S.ensureEntity(4, { type = 'person', ref = 'SUS00001', label = 'x' }), t)
        data(S.ensureEntity(4, { type = 'group', label = 'Svartklubben' }), t)
        env.clear()
        t.eq(#data(S.searchEntities(3, { query = 'Sv' }), t).items, 2)
        local rows = env.auditsNamed('intel.entity.search')
        t.eq(#rows, 1, 'one audit row per call')
        t.eq(rows[1].meta.entityIds, { p.id })
        t.eq(rows[1].meta.query, 'Sv')
        env.clear()
        data(S.searchEntities(3, { query = 'Svart' }), t)
        t.eq(env.auditActions(), {}, 'no person/vehicle returned: no lookup to audit')
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Golden JSON (resources/[fredpd]/fredpd_intel/test/contract.test.ts)

local function keys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
    return out
end

--- Canonical JSON: sorted keys, empty table = [] (as FiveM msgpack/json sends an empty Lua table), nil = absent.
local function canonical(v, indent)
    indent = indent or ''
    local ty = type(v)
    if ty == 'nil' then return 'null' end
    if ty == 'boolean' then return tostring(v) end
    if ty == 'number' then
        if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return ('%d'):format(v) end
        return ('%.17g'):format(v)
    end
    if ty == 'string' then return json.encode(v) end
    local inner = indent .. '  '
    if next(v) == nil then return '[]' end
    if v[1] ~= nil then
        local parts = {}
        for i = 1, #v do parts[i] = inner .. canonical(v[i], inner) end
        return '[\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. ']'
    end
    local parts = {}
    for _, k in ipairs(keys(v)) do parts[#parts + 1] = inner .. json.encode(k) .. ': ' .. canonical(v[k], inner) end
    return '{\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. '}'
end

local function writeGolden(name, value)
    local text = canonical(value) .. '\n'
    local path = GOLDEN .. name .. '.json'
    local f = io.open(path, 'rb')
    local old = f and f:read('a')
    if f then f:close() end
    if old == text then return false end
    os.execute("mkdir -p '" .. GOLDEN .. "'")
    local out = assert(io.open(path, 'wb'))
    out:write(text)
    out:close()
    print('intel_server_test: wrote ' .. path)
    return true
end

--- Fixed timestamps for stable files: every ISO string becomes 2026-09-29T10:MM:00Z in order of appearance.
local function stable(v, counter)
    counter = counter or { n = 0 }
    if type(v) == 'string' and v:match(ISO) then
        counter.n = counter.n + 1
        return ('2026-09-29T10:%02d:00Z'):format(counter.n)
    end
    if type(v) ~= 'table' then return v end
    local out = {}
    for _, k in ipairs(keys(v)) do out[k] = stable(v[k], counter) end
    return out
end

tests['14 golden: sources, reports, entities, links, graph, missions, person notices'] = function(t)
    withEnv(t, function(_, _, mods)
        local S = mods.service
        local h = hemlig(t, S)
        data(S.addMissionMember(1, { id = h.mission.id, citizenid = 'UTR00004', role = 'utredare' }), t)
        local src = data(S.createSource(2, { codename = 'Falken', reliability = 'B', notes = 'Hamnen',
            realCitizenid = 'INF00001' }), t)
        local veh = data(S.addLink(4, { fromId = h.person.id, to = { type = 'vehicle', ref = 'ABC123', label = 'x' },
            type = 'owns', confidence = 90 }), t)
        local grp = data(S.addLink(4, { fromId = veh.to.id, to = { type = 'group', label = 'Ballas' },
            type = 'member_of' }), t)
        t.ok(grp.id, 'second-level link')

        writeGolden('source.full', stable(data(S.getSource(2, { id = src.id }), t)))
        writeGolden('source.masked', stable(data(S.getSource(5, { id = src.id }), t)))
        writeGolden('source.notice', stable(data(S.getSource(4, { id = src.id }), t)))
        writeGolden('sources.list', stable(data(S.listSources(2, {}), t)))
        writeGolden('report.full', stable(data(S.getIntelReport(4, { id = h.report.id }), t)))
        writeGolden('report.notice', stable(data(S.getIntelReport(5, { id = h.report.id }), t)))
        writeGolden('reports.list', stable(data(S.listIntelReports(4, {}), t)))
        writeGolden('entity.full', stable(data(S.getEntity(4, { id = h.person.id }), t)))
        writeGolden('entity.notice', stable(data(S.getEntity(3, { id = h.person.id }), t)))
        writeGolden('entities.search', stable(data(S.searchEntities(3, { query = 'Sv' }), t)))
        writeGolden('entity.ensure', stable(data(S.ensureEntity(4, { type = 'case', ref = 'K-123-26', label = 'x' }), t)))
        writeGolden('link', stable(veh))
        writeGolden('graph.depth2', stable(data(S.getGraph(4, { entityId = h.person.id, depth = 2 }), t)))
        writeGolden('mission.full', stable(data(S.getMission(4, { id = h.mission.id }), t)))
        writeGolden('mission.notice', stable(data(S.getMission(3, { id = h.mission.id }), t)))
        writeGolden('missions.list', stable(data(S.listMissions(1, {}), t)))
        writeGolden('personNotices', stable(S.getPersonNotices(3, 'SUS00001')))
        t.ok(io.open(GOLDEN .. 'graph.depth2.json', 'r'), 'golden files exist')
    end)
end

return tests
