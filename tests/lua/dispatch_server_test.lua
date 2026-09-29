-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_dispatch server against a real MariaDB (tests/lua/mysql_shim.lua runs the migrations and fakes oxmysql),
-- with FiveM mocked: exports (fredpd_core grants/duty/officers/audit/signedFetch, fredpd_mdt push), players,
-- events, SetTimeout, lib.callback/addCommand. Covers the ps-dispatch bridge (hostile data, rate limit, player
-- source), createAlert round trip + fan-out, take/leave/close incl. races, takeNewest, listAlerts, the keybind
-- callback, the units roster debounce, main.lua wiring, UTC timestamps, audit rows, and writes the golden JSON
-- files checked against packages/types/src/dispatch.ts by resources/[fredpd]/fredpd_dispatch/test/contract.test.ts.
-- Database fredpd_test_dispatch_lua (reset once per run); every session at time_zone '+02:00' (§C7: nothing may
-- depend on it). Skips with a notice when MariaDB is unreachable.
-- Run: lua5.4 tests/lua/run.lua dispatch_server
local shim = require('mysql_shim')
local helper = require('helper')

local DB = 'fredpd_test_dispatch_lua'
local DISPATCH = './resources/[fredpd]/fredpd_dispatch/'
local GOLDEN = DISPATCH .. 'test/golden/'
local MODULES = { 'shared.alert_input', 'server.alert_store', 'server.fanout', 'server.unit_roster',
    'server.alert_service', 'server.ps_bridge' }
local ISO = '^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$'

local tests = {}

---------------------------------------------------------------------------------------------------------------
-- Environment

-- ox_lib `require '@fredpd_core.shared.x'` -> fredpd_core/shared/x.lua (package.path already has fredpd_core).
package.preload['@fredpd_core.shared.time'] = function() return require('shared.time') end
package.preload['@fredpd_core.shared.locale'] = function() return require('shared.locale') end

--- Locale dictionary: sv.json + pending/dispatch.json (sv), for L() through fredpd_core shared/locale.
local SV = (function()
    local dict = helper.readJson('locales/sv.json')
    local f = io.open('locales/pending/dispatch.json', 'r')
    if f then
        for k, v in pairs(json.decode(f:read('a'))) do
            if type(v) == 'table' and v.sv then dict[k] = v.sv end
        end
        f:close()
    end
    return dict
end)()

-- Officers: 1 IGV on duty with the grant, 2 on duty without mdt_page:alerts, 3 off duty with the grant,
-- 4 civilian, 5 Ledning (alerts.manage), 6 IGV on duty without a fredpd_officers row.
local function defaultPlayers()
    local alerts = { ['mdt_page:alerts'] = true }
    return {
        [1] = { cid = 'DSP10001', duty = true, grants = alerts, name = 'acct_anna',
            officer = { citizenid = 'DSP10001', displayName = 'Anna B.', callsign = 'IGV-07', unit = 'igv' } },
        [2] = { cid = 'DSP10002', duty = true, grants = {}, name = 'acct_bo',
            officer = { citizenid = 'DSP10002', displayName = 'Bo C.', callsign = 'SPAN-02', unit = 'span' } },
        [3] = { cid = 'DSP10003', duty = false, grants = alerts, name = 'acct_cia',
            officer = { citizenid = 'DSP10003', displayName = 'Cia D.', callsign = 'IGV-03', unit = 'igv' } },
        [4] = { cid = 'CIV40004', duty = false, grants = {}, name = 'acct_civ' },
        [5] = { cid = 'DSP10005', duty = true, grants = { ['mdt_page:alerts'] = true, ['perm:alerts.manage'] = true },
            name = 'acct_eva',
            officer = { citizenid = 'DSP10005', displayName = 'Eva L.', callsign = 'LED-01', unit = 'ledning' } },
        [6] = { cid = 'DSP10006', duty = true, grants = alerts, name = 'acct_fia' },
    }
end

local OFFICER_ROWS = {
    { 'DSP10001', '100000000000000001', 'Anna B.', 'IGV-07', 'igv' },
    { 'DSP10002', '100000000000000002', 'Bo C.', 'SPAN-02', 'span' },
    { 'DSP10003', '100000000000000003', 'Cia D.', 'IGV-03', 'igv' },
    { 'DSP10005', '100000000000000005', 'Eva L.', 'LED-01', 'ledning' },
}

local prepared = nil
local notified = false

local GLOBALS = { 'MySQL', 'LoadResourceFile', 'GetCurrentResourceName', 'exports', 'GetPlayers', 'GetPlayerName',
    'GetGameTimer', 'SetTimeout', 'CreateThread', 'TriggerEvent', 'TriggerClientEvent', 'GetResourceState',
    'AddEventHandler', 'lib', 'GetConvar', 'GetEntityCoords', 'GetPlayerPed', 'GetPlayerIdentifierByType',
    'source', 'locale' }

--- Fresh copies of the dispatch modules (module state: limiters, roster, debounce).
local function freshModules()
    for _, name in ipairs(MODULES) do package.loaded[name] = nil end
    local savedPath = package.path
    package.path = DISPATCH .. '?.lua;' .. package.path
    local ok, mods = pcall(function()
        local out = {}
        for _, name in ipairs(MODULES) do out[name] = require(name) end
        return out
    end)
    package.path = savedPath
    if not ok then error(mods, 0) end
    return mods
end

--- Build the mocked FiveM world. Returns env (state + helpers).
local function makeEnv()
    local Audit = require('server.audit')
    local env = {
        now = 100000, timers = {}, players = defaultPlayers(), events = {}, clientEvents = {}, pushes = {},
        posts = {}, audits = {}, handlers = {}, exported = {}, callbacks = {}, commands = {}, logs = {},
        resources = { fredpd_mdt = 'started', ['ps-dispatch'] = 'started', fredpd_core = 'started' },
        convars = {}, pushFails = false,
    }

    function env.toasts()
        local out = {}
        for _, e in ipairs(env.clientEvents) do
            if e.name == 'fredpd:client:alertToast' then out[#out + 1] = e end
        end
        return out
    end

    function env.eventsNamed(name)
        local out = {}
        for _, e in ipairs(env.events) do
            if e.name == name then out[#out + 1] = e end
        end
        return out
    end

    function env.clear()
        env.events, env.clientEvents, env.pushes, env.posts, env.audits = {}, {}, {}, {}, {}
    end

    --- Advance the clock and run due SetTimeout callbacks in time order.
    function env.advance(ms)
        local target = env.now + ms
        for _ = 1, 1000 do
            table.sort(env.timers, function(a, b) return a.at < b.at end)
            local nextTimer = env.timers[1]
            if not nextTimer or nextTimer.at > target then break end
            table.remove(env.timers, 1)
            env.now = nextTimer.at
            nextTimer.fn()
        end
        env.now = target
    end

    local function player(src) return env.players[tonumber(src)] end

    local core = {
        hasGrant = function(_, src, t, k)
            local p = player(src)
            return p ~= nil and p.grants[t .. ':' .. k] == true
        end,
        isOnDuty = function(_, src) local p = player(src); return p ~= nil and p.duty == true end,
        getCitizenId = function(_, src) local p = player(src); return p and p.cid or nil end,
        getOfficer = function(_, src) local p = player(src); return p and p.officer or nil end,
        audit = function(_, src, action, targetType, targetId, meta)
            env.audits[#env.audits + 1] = { src = src, action = action, targetType = targetType, targetId = targetId,
                meta = meta }
            return Audit.audit(src, action, targetType, targetId, meta)
        end,
        signedFetch = function(_, method, path, body, cb)
            env.posts[#env.posts + 1] = { method = method, path = path, body = body }
            cb(200, '{"ok":true}')
        end,
    }
    local mdt = {
        pushToOpenTablets = function(_, topic, payload)
            if env.pushFails then error('No such export pushToOpenTablets in resource fredpd_mdt', 0) end
            env.pushes[#env.pushes + 1] = { topic = topic, payload = payload }
        end,
    }
    local qbx = {
        GetPlayer = function(_, src)
            local p = player(src)
            return p and { PlayerData = { citizenid = p.cid, source = tonumber(src) } } or nil
        end,
    }

    env.globals = {
        exports = setmetatable({ fredpd_core = core, fredpd_mdt = mdt, qbx_core = qbx }, {
            __call = function(_, name, fn) env.exported[name] = fn end,
        }),
        GetPlayers = function()
            local ids = {}
            for src in pairs(env.players) do ids[#ids + 1] = tostring(src) end
            table.sort(ids)
            return ids
        end,
        GetPlayerName = function(src) local p = player(src); return p and p.name or nil end,
        GetPlayerIdentifierByType = function(src) return ('discord:%d'):format(900000000000000000 + tonumber(src)) end,
        GetGameTimer = function() return env.now end,
        SetTimeout = function(ms, fn) env.timers[#env.timers + 1] = { at = env.now + ms, fn = fn } end,
        CreateThread = function(fn) fn() end,
        TriggerEvent = function(name, ...) env.events[#env.events + 1] = { name = name, args = { ... } } end,
        TriggerClientEvent = function(name, target, ...)
            env.clientEvents[#env.clientEvents + 1] = { name = name, target = target, args = { ... } }
        end,
        GetResourceState = function(name) return env.resources[name] or 'missing' end,
        AddEventHandler = function(name, fn)
            env.handlers[name] = env.handlers[name] or {}
            table.insert(env.handlers[name], fn)
        end,
        GetConvar = function(name, default) return env.convars[name] or default end,
        GetEntityCoords = function() return { x = 10.5, y = 20.25, z = 30.0 } end,
        GetPlayerPed = function(src) return 1000 + tonumber(src) end,
        locale = function(key) return SV[key] or key end,
        lib = {
            callback = { register = function(name, fn) env.callbacks[name] = fn end },
            addCommand = function(name, opts, fn) env.commands[name] = { opts = opts, fn = fn } end,
            print = setmetatable({}, { __index = function(_, level)
                return function(msg) env.logs[#env.logs + 1] = { level = level, msg = msg } end
            end }),
        },
    }

    --- Fire a server event handler as FiveM would (global `source` set for the call).
    function env.fire(name, eventSource, ...)
        local saved = rawget(_G, 'source')
        rawset(_G, 'source', eventSource)
        for _, fn in ipairs(env.handlers[name] or {}) do fn(...) end
        rawset(_G, 'source', saved)
    end

    return env
end

--- Run fn(t, env, mods) with MariaDB + mocks installed; restores every global afterwards.
local function withEnv(t, fn)
    local ok, reason = shim.available()
    if not ok then
        if not notified then
            print(('SKIP dispatch_server_test: MariaDB unreachable (%s)'):format((reason or ''):gsub('%s+$', '')))
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
            prepared = true
        end
        if not prepared then return end
        local env = makeEnv()
        for k, v in pairs(env.globals) do rawset(_G, k, v) end
        rawset(_G, 'source', nil)
        -- Clean slate per test (the schema stays).
        MySQL.query.await('DELETE FROM fredpd_alert_units')
        MySQL.query.await('DELETE FROM fredpd_alerts')
        MySQL.query.await("DELETE FROM fredpd_audit WHERE action LIKE 'alert.%'")
        for _, r in ipairs(OFFICER_ROWS) do
            MySQL.query.await('INSERT IGNORE INTO fredpd_officers (citizenid, discord_id, display_name, callsign, unit) '
                .. 'VALUES (?, ?, ?, ?, ?)', r)
        end
        fn(t, env, freshModules())
    end)
    for n, v in pairs(saved) do rawset(_G, n, v[1]) end
    shim.sessionTimeZone = nil
    shim.database, shim.resourceName = savedDatabase, savedResource
    if not okRun then error(err, 0) end
end

local function scalar(sql, params) return MySQL.scalar.await(sql, params) end
local function q(sql, params) return MySQL.query.await(sql, params) end

local function shooting(overrides)
    local d = {
        message = 'Shots Fired', codeName = 'shooting', code = '10-11', icon = 'fas fa-gun', priority = 2,
        coords = { x = 215.5, y = -920.25, z = 30.75 }, street = 'Vespucci Blvd, Legion Square', gender = 'Male',
        weapon = 'Pistol', weaponClass = 'pistol', weaponTier = 1, jobs = { 'leo' }, id = 17, units = {},
        responses = {}, count = 1, listed = true, time = 1790000000000,
    }
    for k, v in pairs(overrides or {}) do
        if v == false then d[k] = nil else d[k] = v end
    end
    return d
end

local function newAlert(mods, overrides)
    local data = { code = '10-11', title = 'Skottlossning', source = 'test', priority = 2,
        coords = { x = 1.5, y = 2.5, z = 3.5 }, street = 'Strawberry Ave' }
    for k, v in pairs(overrides or {}) do
        if v == false then data[k] = nil else data[k] = v end
    end
    local alert, err, field = mods['server.alert_service'].create(data)
    assert(alert, ('create failed: %s %s'):format(tostring(err), tostring(field)))
    return alert
end

--- Keys of a table, sorted.
local function keys(tbl)
    local out = {}
    for k in pairs(tbl) do out[#out + 1] = k end
    table.sort(out)
    return out
end

---------------------------------------------------------------------------------------------------------------
-- ps-dispatch bridge

tests['01 bridge: a player-triggered fredpd:dispatch:incoming is ignored'] = function(t)
    withEnv(t, function(_, env, mods)
        local Bridge = mods['server.ps_bridge']
        local alert, why = Bridge.handle(5, shooting(), 5)
        t.eq(alert, nil)
        t.eq(why, 'player_source')
        t.eq(Bridge.handle('7', shooting(), 7), nil)
        t.eq(scalar('SELECT COUNT(*) FROM fredpd_alerts'), 0)
        t.eq(#env.toasts(), 0)
        t.ok(Bridge.handle('', shooting(), 7), "server source '' is accepted")
        t.ok(Bridge.handle(nil, shooting(), 8), 'nil source is accepted')
        t.eq(scalar('SELECT COUNT(*) FROM fredpd_alerts'), 2)
    end)
end

tests['02 bridge: a Shooting() call is normalised and stored'] = function(t)
    withEnv(t, function(_, env, mods)
        mods['server.ps_bridge'].L = require('shared.locale').L
        local alert = mods['server.ps_bridge'].handle('', shooting({ information = 'Två skott' }), 7)
        t.ok(alert)
        t.eq(alert.code, '10-11')
        t.eq(alert.title, 'Shots Fired')
        t.eq(alert.coords, { x = 215.5, y = -920.25, z = 30.75 })
        t.eq(alert.street, 'Vespucci Blvd, Legion Square')
        t.eq(alert.priority, 2)
        t.eq(alert.source, 'ps-dispatch')
        t.eq(alert.status, 'open')
        t.eq(alert.description, 'Två skott\nVapen: Pistol')
        local meta = json.decode(scalar('SELECT meta FROM fredpd_alerts WHERE id = ?', { alert.id }))
        t.eq(meta, { psId = 17, codeName = 'shooting', icon = 'fas fa-gun', gender = 'Male', weapon = 'Pistol',
            weaponClass = 'pistol', weaponTier = 1 })
        t.eq(scalar("SELECT source FROM fredpd_alerts WHERE id = ?", { alert.id }), 'ps-dispatch')
    end)
end

tests['03 bridge: hostile data is capped, clamped or dropped before the database'] = function(t)
    withEnv(t, function(_, env, mods)
        local Bridge = mods['server.ps_bridge']
        local huge = ('Å'):rep(600000) -- 1.2 MB
        local a = Bridge.handle('', shooting({ message = huge, street = huge, information = huge, priority = 99 }), 11)
        t.ok(a, 'huge strings are cut, not fatal')
        t.eq(scalar('SELECT CHAR_LENGTH(title) FROM fredpd_alerts WHERE id = ?', { a.id }), 160)
        t.eq(scalar('SELECT CHAR_LENGTH(street) FROM fredpd_alerts WHERE id = ?', { a.id }), 128)
        t.ok(scalar('SELECT CHAR_LENGTH(description) FROM fredpd_alerts WHERE id = ?', { a.id }) <= 1000)
        t.eq(a.priority, 3, 'priority 99 -> 3')
        local b = Bridge.handle('', shooting({ message = 'Bad \255\254 UTF-8 \0 here', priority = 0 }), 12)
        t.eq(b.title, 'Bad  UTF-8  here')
        t.eq(b.priority, 1, 'critical 0 -> 1')
        t.eq(select(2, Bridge.handle('', shooting({ coords = { x = 0 / 0, y = 1, z = 2 } }), 13)), 'coords')
        t.eq(select(2, Bridge.handle('', shooting({ message = false }), 14)), 'title')
        t.eq(select(2, Bridge.handle('', shooting({ jobs = { 'ems' } }), 15)), 'not_police')
        t.eq(select(2, Bridge.handle('', 'not a table', 16)), 'not_police')
        local c = Bridge.handle('', { message = 'Bråk', code = '10-10' }, 17)
        t.eq(c.coords, nil)
        t.eq(c.street, nil)
        t.eq(c.description, nil)
        t.eq(c.priority, 2)
        t.eq(scalar('SELECT COUNT(*) FROM fredpd_alerts'), 3)
    end)
end

tests['04 bridge: 5 calls per 30 s per reporter; server calls share their own bucket'] = function(t)
    withEnv(t, function(_, env, mods)
        local Bridge = mods['server.ps_bridge']
        for i = 1, 5 do
            t.ok(Bridge.handle('', shooting({ id = i }), 21), 'call ' .. i)
            env.now = env.now + 1000
        end
        local none, why = Bridge.handle('', shooting(), 21)
        t.eq(none, nil)
        t.eq(why, 'rate_limited')
        t.ok(Bridge.handle('', shooting(), 22), 'another reporter is not affected')
        env.now = env.now + 25500 -- only the first call (30.5 s old) has left the window
        t.ok(Bridge.handle('', shooting(), 21), 'window moved on')
        t.eq(select(2, Bridge.handle('', shooting(), 21)), 'rate_limited')
        Bridge.forget(21)
        t.ok(Bridge.handle('', shooting(), 21), 'playerDropped clears the bucket')
        for i = 1, Bridge.SERVER_LIMIT.max do t.ok(Bridge.handle('', shooting(), nil), 'server ' .. i) end
        t.eq(select(2, Bridge.handle('', shooting(), 0)), 'rate_limited', 'reporter 0 = server bucket')
        t.eq(scalar('SELECT COUNT(*) FROM fredpd_alerts'), 8 + Bridge.SERVER_LIMIT.max)
    end)
end

tests['04b bridge: EMS-only calls do not use up the reporter\'s police budget'] = function(t)
    withEnv(t, function(_, env, mods)
        local Bridge = mods['server.ps_bridge']
        for i = 1, Bridge.PLAYER_LIMIT.max + 1 do
            t.eq(select(2, Bridge.handle('', shooting({ jobs = { 'ems' }, message = 'Injured person' }), 31)),
                'not_police', 'ems ' .. i)
        end
        t.ok(Bridge.handle('', shooting(), 31), 'a police call after 6 EMS calls from the same reporter is accepted')
        for i = 2, Bridge.PLAYER_LIMIT.max do t.ok(Bridge.handle('', shooting(), 31), 'police ' .. i) end
        t.eq(select(2, Bridge.handle('', shooting(), 31)), 'rate_limited', 'police calls still count')
        t.eq(scalar('SELECT COUNT(*) FROM fredpd_alerts'), Bridge.PLAYER_LIMIT.max)
    end)
end

tests['04c bridge: an offset alert gets the displayed position; the true one stays server-side'] = function(t)
    withEnv(t, function(_, env, mods)
        mods['server.ps_bridge'].L = require('shared.locale').L
        local alert = mods['server.ps_bridge'].handle('', shooting({
            displayCoords = { x = 290.5, y = -870.25, z = 30.75 }, mapRadius = 110.0 }), 7)
        t.ok(alert)
        t.eq(alert.coords, { x = 290.5, y = -870.25, z = 30.75 }, 'waypoint/tablet get the displayed position')
        t.eq(alert.description, 'Ungefärlig plats (inom 110 m)\nVapen: Pistol')
        local meta = json.decode(scalar('SELECT meta FROM fredpd_alerts WHERE id = ?', { alert.id }))
        t.ok(meta.exactX == 215.5 and meta.exactY == -920.25 and meta.exactZ == 30.75, 'true coords in meta')
        t.ok(meta.mapRadius == 110, 'mapRadius in meta')
        t.eq(scalar('SELECT JSON_EXTRACT(coords, \'$.x\') FROM fredpd_alerts WHERE id = ?', { alert.id }) + 0.0, 290.5)
        for _, e in ipairs(env.clientEvents) do
            t.ok(not json.encode(e.args):find('215.5', 1, true), 'the true x never reaches a client')
        end
        for _, p in ipairs(env.pushes) do t.ok(not json.encode(p):find('215.5', 1, true), 'nor a tablet push') end
        for _, p in ipairs(env.posts) do t.ok(not json.encode(p):find('215.5', 1, true), 'nor the service') end
    end)
end

---------------------------------------------------------------------------------------------------------------
-- createAlert

tests['05 createAlert: round trip shape, UTC time, toast only to on-duty officers with the grant'] = function(t)
    withEnv(t, function(_, env, mods)
        local alert = newAlert(mods, { description = 'Två personer', priority = 1 })
        t.eq(keys(alert), { 'code', 'coords', 'createdAt', 'description', 'id', 'priority', 'source', 'status',
            'street', 'title', 'units' })
        t.eq(math.type(alert.id), 'integer')
        t.eq(alert.units, {})
        t.eq(alert.closedBy, nil)
        t.eq(alert.closedAt, nil)
        t.ok(alert.createdAt:match(ISO), alert.createdAt)
        local skew = scalar("SELECT ABS(TIMESTAMPDIFF(SECOND, STR_TO_DATE(?, '%Y-%m-%dT%H:%i:%sZ'), UTC_TIMESTAMP()))",
            { alert.createdAt })
        t.ok(skew <= 60, 'createdAt is UTC although the session runs at +02:00 (skew ' .. tostring(skew) .. ' s)')
        t.eq(scalar('SELECT ABS(TIMESTAMPDIFF(SECOND, updated_at, UTC_TIMESTAMP())) <= 60 FROM fredpd_alerts WHERE id = ?',
            { alert.id }), 1)

        local toasts = env.toasts()
        local targets = {}
        for _, e in ipairs(toasts) do targets[#targets + 1] = e.target end
        table.sort(targets)
        t.eq(targets, { 1, 5, 6 }, 'on duty + mdt_page:alerts only (not 2: no grant, 3: off duty, 4: civilian)')
        t.eq(toasts[1].args[1], { id = alert.id, code = '10-11', title = 'Skottlossning', street = 'Strawberry Ave',
            priority = 1 })

        local created = env.eventsNamed('fredpd:alertCreated')
        t.eq(#created, 1)
        t.eq(created[1].args[1], alert)
        t.eq(#env.pushes, 1)
        t.eq(env.pushes[1], { topic = 'alerts', payload = { type = 'created', alert = alert } })
        t.eq(#env.clientEvents, #toasts, 'the only client events are toasts: tablet pushes go through fredpd_mdt only')
        t.eq(#env.posts, 1)
        t.eq(env.posts[1], { method = 'POST', path = '/internal/events', body = { type = 'alertCreated', payload = alert } })
        t.eq(#env.audits, 0, 'creation is not audited (§C13)')
    end)
end

tests['06 createAlert: invalid input returns validation and writes nothing'] = function(t)
    withEnv(t, function(_, env, mods)
        local Service = mods['server.alert_service']
        local cases = {
            { { code = '10-11', source = 'x' }, 'title' },
            { { code = '10-11', title = 'T', source = 'x', priority = 4 }, 'priority' },
            { { title = 'T', source = 'x' }, 'code' },
            { { code = '1', title = 'T', source = 'x', coords = { x = 0 / 0, y = 0, z = 0 } }, 'coords' },
            { 'nope', 'input' },
        }
        for i, c in ipairs(cases) do
            local alert, err, field = Service.create(c[1])
            t.eq(alert, nil, 'case ' .. i)
            t.eq(err, 'validation', 'case ' .. i)
            t.eq(field, c[2], 'case ' .. i)
        end
        t.eq(scalar('SELECT COUNT(*) FROM fredpd_alerts'), 0)
        t.eq(#env.toasts(), 0)
        t.eq(#env.posts, 0)
        -- fredpd_devtools sends `message` instead of `title`
        local dev = Service.create({ code = 'dev', source = 'fredpd_devtools', message = 'Testlarm IGV-91',
            coords = { x = 1, y = 2, z = 3 } })
        t.eq(dev.title, 'Testlarm IGV-91')
    end)
end

tests['07 createAlert: fredpd_mdt missing or failing never breaks the alert'] = function(t)
    withEnv(t, function(_, env, mods)
        env.resources.fredpd_mdt = 'missing'
        t.ok(newAlert(mods))
        t.eq(#env.pushes, 0)
        env.resources.fredpd_mdt = 'started'
        env.pushFails = true
        t.ok(newAlert(mods), 'pushToOpenTablets raising is caught')
        t.eq(#env.posts, 2, 'the service still gets both events')
        t.eq(#env.toasts(), 6)
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Take / leave / close

tests['08 assignSelf: open -> assigned, second officer joins, repeat is idempotent, audited'] = function(t)
    withEnv(t, function(_, env, mods)
        local Service = mods['server.alert_service']
        local alert = newAlert(mods)
        env.clear()
        local r = Service.assignSelf(1, { id = alert.id }, 'tablet')
        t.eq(r.ok, true)
        t.eq(r.data.status, 'assigned')
        t.eq(r.data.units, { { citizenid = 'DSP10001', displayName = 'Anna B.', callsign = 'IGV-07', unit = 'igv' } })
        t.eq(env.eventsNamed('fredpd:alertAssigned')[1].args, { alert.id, 1 })
        t.eq(env.pushes[1], { topic = 'alerts', payload = { type = 'updated', alert = r.data } })
        t.eq(env.posts[1].body, { type = 'alertAssigned', payload = r.data })
        t.eq(#env.timers, 1, 'units roster rebuild scheduled')

        local r6 = Service.assignSelf(6, { id = alert.id })
        t.eq(r6.ok, true)
        t.eq(r6.data.status, 'assigned')
        t.eq(#r6.data.units, 2)
        t.eq(r6.data.units[2], { citizenid = 'DSP10006', displayName = 'DSP10006', unit = nil, callsign = nil },
            'no fredpd_officers row: citizenid as name, never the character')

        local again = Service.assignSelf(1, { id = alert.id })
        t.eq(again.ok, true)
        t.eq(#again.data.units, 2)
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_alert_units WHERE alert_id = ?", { alert.id }), 2)
        local rows = q("SELECT actor_citizenid, action, target_type, target_id, meta FROM fredpd_audit "
            .. "WHERE action = 'alert.assign' ORDER BY id")
        t.eq(#rows, 2, 'the idempotent repeat is not audited again')
        t.eq(#env.clientEvents, 0, 'take: no client events (pushes only via pushToOpenTablets)')
        t.eq(rows[1].actor_citizenid, 'DSP10001')
        t.eq(rows[1].target_type, 'alert')
        t.eq(tostring(rows[1].target_id), tostring(alert.id))
        t.eq(json.decode(rows[1].meta), { via = 'tablet' })
        t.eq(scalar("SELECT callsign FROM fredpd_alert_units WHERE alert_id = ? AND citizenid = 'DSP10001'",
            { alert.id }), 'IGV-07', 'callsign snapshot')
    end)
end

tests['09 concurrent take: the claim has one winner, the loser gets the next open alert'] = function(t)
    withEnv(t, function(_, env, mods)
        local Service, Store = mods['server.alert_service'], mods['server.alert_store']
        local older = newAlert(mods, { title = 'Äldre' })
        local newer = newAlert(mods, { title = 'Nyare' })

        -- Store level: both see the same newest id, only one claim succeeds.
        local idA, idB = Store.newestOpenId(), Store.newestOpenId()
        t.eq(idA, newer.id)
        t.eq(idB, newer.id)
        t.eq(Store.claim(idA), true)
        t.eq(Store.claim(idB), false)
        t.eq(Store.reopenIfEmpty(idA), true, 'undo the bare claim')

        -- Service level, interleaved: officer 1 has read the newest id when officer 6 takes it completely.
        local realNewest = Store.newestOpenId
        local interleaved = false
        Store.newestOpenId = function()
            local id = realNewest()
            if not interleaved then
                interleaved = true
                local other = Service.takeNewest(6)
                t.eq(other.ok, true)
                t.eq(other.data.id, newer.id, 'officer 6 wins the newest alert')
            end
            return id
        end
        local r = Service.takeNewest(1)
        Store.newestOpenId = realNewest
        t.eq(r.ok, true)
        t.eq(r.data.id, older.id, 'officer 1 lost the claim and got the next open alert')
        t.eq(r.data.units[1].citizenid, 'DSP10001')
        t.eq(scalar('SELECT COUNT(*) FROM fredpd_alert_units WHERE alert_id = ?', { newer.id }), 1)
        t.eq(scalar("SELECT GROUP_CONCAT(status ORDER BY id) FROM fredpd_alerts"), 'assigned,assigned')
        local third = Service.takeNewest(5)
        t.eq(third, { ok = false, error = 'not_found' })

        -- Explicit takes of the same alert by two officers both succeed (joining is allowed).
        local shared = newAlert(mods)
        t.eq(Service.assignSelf(1, { id = shared.id }).ok, true)
        local second = Service.assignSelf(5, { id = shared.id })
        t.eq(second.ok, true)
        t.eq(#second.data.units, 2)
        t.eq(second.data.status, 'assigned')
    end)
end

tests['10 leave: last unit leaving reopens the alert; not on it -> not_found'] = function(t)
    withEnv(t, function(_, env, mods)
        local Service = mods['server.alert_service']
        local alert = newAlert(mods)
        Service.assignSelf(1, { id = alert.id })
        Service.assignSelf(6, { id = alert.id })
        env.clear()
        local r = Service.leave(1, { id = alert.id })
        t.eq(r.ok, true)
        t.eq(r.data.status, 'assigned', 'officer 6 is still on it')
        t.eq(#r.data.units, 1)
        t.eq(env.pushes[1].payload.type, 'updated')
        t.eq(env.posts[1].body.type, 'alertAssigned')
        local r2 = Service.leave(6, { id = alert.id })
        t.eq(r2.data.status, 'open', 'back to open')
        t.eq(r2.data.units, {})
        t.eq(Service.leave(6, { id = alert.id }), { ok = false, error = 'not_found' })
        t.eq(Service.leave(1, { id = 999999 }), { ok = false, error = 'not_found' })
        t.eq(#env.clientEvents, 0, 'leave: no client events (pushes only via pushToOpenTablets)')
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_audit WHERE action = 'alert.leave' AND target_id = ?",
            { tostring(alert.id) }), 2)
        t.eq(Service.takeNewest(5).data.id, alert.id, 'a reopened alert can be taken with the key again')
    end)
end

tests['10b races: a join or leave that loses to a close pushes no update; takeNewest keeps the alert assigned'] = function(t)
    withEnv(t, function(_, env, mods)
        local Service, Store = mods['server.alert_service'], mods['server.alert_store']

        -- Join commits, then officer 5 (alerts.manage) closes before the read-back.
        local alert = newAlert(mods)
        local realLoad = Store.loadOne
        local closeFirst = true
        Store.loadOne = function(id)
            if closeFirst then
                closeFirst = false
                t.eq(Service.close(5, { id = id }).ok, true)
            end
            return realLoad(id)
        end
        env.clear()
        t.eq(Service.assignSelf(1, { id = alert.id }), { ok = false, error = 'not_found' }, 'late joiner: closed')
        Store.loadOne = realLoad
        t.eq(env.pushes, { { topic = 'alerts', payload = { type = 'closed', id = alert.id } } },
            'only the close is pushed; no updated push brings the closed alert back')
        t.eq(#env.eventsNamed('fredpd:alertAssigned'), 0)
        for _, p in ipairs(env.posts) do t.ok(p.body.type ~= 'alertAssigned', 'no alertAssigned internal event') end
        t.eq(json.decode(scalar("SELECT meta FROM fredpd_audit WHERE action = 'alert.assign' AND target_id = ?",
            { tostring(alert.id) })), { via = 'tablet', closedMeanwhile = true }, 'the join happened: audited')

        -- Leave commits, then a close before the read-back: ok, but no updated push.
        local second = newAlert(mods)
        Service.assignSelf(1, { id = second.id })
        Service.assignSelf(6, { id = second.id })
        closeFirst = true
        Store.loadOne = function(id)
            if closeFirst then
                closeFirst = false
                t.eq(Service.close(6, { id = id }).ok, true)
            end
            return realLoad(id)
        end
        env.clear()
        local left = Service.leave(1, { id = second.id })
        Store.loadOne = realLoad
        t.eq(left.ok, true, 'the leave itself succeeded')
        t.eq(left.data.status, 'closed')
        t.eq(env.pushes, { { topic = 'alerts', payload = { type = 'closed', id = second.id } } })
        t.eq(#env.posts, 1)
        t.eq(env.posts[1].body.type, 'alertClosed')

        -- Keybind: between the claim and our addUnit, officer 6 joins from the tablet and leaves again (the leave
        -- reopens the alert while nobody is on it). takeNewest must still end with status 'assigned'.
        local third = newAlert(mods)
        local realAdd = Store.addUnit
        local interfere = true
        Store.addUnit = function(id, cid, callsign)
            if interfere and cid == 'DSP10001' then
                interfere = false
                Store.addUnit = realAdd
                t.eq(Service.assignSelf(6, { id = id }).ok, true)
                t.eq(Service.leave(6, { id = id }).data.status, 'open', 'the leave reopened the claimed alert')
            end
            return realAdd(id, cid, callsign)
        end
        local r = Service.takeNewest(1)
        Store.addUnit = realAdd
        t.eq(r.ok, true)
        t.eq(r.data.id, third.id)
        t.eq(r.data.status, 'assigned', 'marked assigned again after the join')
        t.eq(#r.data.units, 1)
        t.eq(scalar('SELECT status FROM fredpd_alerts WHERE id = ?', { third.id }), 'assigned')

        -- Keybind: joined, then closed before the read-back: the next open alert is taken instead.
        local older = newAlert(mods, { title = 'Äldre' })
        local newest = newAlert(mods, { title = 'Nyast' })
        closeFirst = true
        Store.loadOne = function(id)
            if closeFirst then
                closeFirst = false
                t.eq(id, newest.id)
                t.eq(Service.close(5, { id = id }).ok, true)
            end
            return realLoad(id)
        end
        local k = Service.takeNewest(1)
        Store.loadOne = realLoad
        t.eq(k.ok, true)
        t.eq(k.data.id, older.id, 'closed right after the join: the key takes the next open alert')
    end)
end

tests['11 close: assigned officer or alerts.manage only; closed is final'] = function(t)
    withEnv(t, function(_, env, mods)
        local Service = mods['server.alert_service']
        local alert = newAlert(mods)
        Service.assignSelf(6, { id = alert.id })
        env.clear()
        t.eq(Service.close(1, { id = alert.id }), { ok = false, error = 'unauthorized' }, 'not assigned, no perm')
        t.eq(scalar('SELECT status FROM fredpd_alerts WHERE id = ?', { alert.id }), 'assigned')
        t.eq(#env.pushes, 0)

        local r = Service.close(6, { id = alert.id })
        t.eq(r.ok, true)
        t.eq(r.data.status, 'closed')
        t.eq(r.data.closedBy, { citizenid = 'DSP10006', displayName = 'DSP10006' })
        t.ok(r.data.closedAt:match(ISO), tostring(r.data.closedAt))
        t.eq(scalar("SELECT ABS(TIMESTAMPDIFF(SECOND, closed_at, UTC_TIMESTAMP())) <= 60 FROM fredpd_alerts WHERE id = ?",
            { alert.id }), 1, 'closed_at is UTC')
        t.eq(env.pushes, { { topic = 'alerts', payload = { type = 'closed', id = alert.id } } })
        t.eq(env.posts[1].body, { type = 'alertClosed', payload = { id = alert.id } })
        t.eq(env.eventsNamed('fredpd:alertClosed')[1].args, { alert.id, 6 })
        t.eq(#r.data.units, 1, 'units stay as history')
        t.eq(#env.clientEvents, 0, 'close: no client events (pushes only via pushToOpenTablets)')

        t.eq(Service.close(6, { id = alert.id }), { ok = false, error = 'not_found' }, 'already closed')
        t.eq(Service.assignSelf(1, { id = alert.id }), { ok = false, error = 'not_found' }, 'cannot take a closed alert')
        t.eq(Service.leave(6, { id = alert.id }), { ok = false, error = 'not_found' }, 'cannot leave a closed alert')

        local other = newAlert(mods)
        local byManager = Service.close(5, { id = other.id })
        t.eq(byManager.ok, true, 'Ledning with alerts.manage closes an alert it is not on')
        t.eq(byManager.data.closedBy, { citizenid = 'DSP10005', displayName = 'Eva L.', callsign = 'LED-01',
            unit = 'ledning' })
        local audits = q("SELECT actor_citizenid, meta FROM fredpd_audit WHERE action = 'alert.close' ORDER BY id")
        t.eq(#audits, 2)
        t.eq(audits[1].actor_citizenid, 'DSP10006')
        t.eq(json.decode(audits[1].meta), { assigned = true })
        t.eq(json.decode(audits[2].meta), { assigned = false })
    end)
end

tests['12 takeNewest picks the newest open alert and skips assigned/closed ones'] = function(t)
    withEnv(t, function(_, env, mods)
        local Service = mods['server.alert_service']
        t.eq(Service.takeNewest(1), { ok = false, error = 'not_found' }, 'nothing open')
        local a = newAlert(mods, { title = 'A' })
        local b = newAlert(mods, { title = 'B' })
        local c = newAlert(mods, { title = 'C' })
        Service.close(5, { id = c.id })
        Service.assignSelf(5, { id = b.id })
        env.clear()
        local r = Service.takeNewest(1)
        t.eq(r.data.id, a.id, 'C is closed, B assigned: A is the newest open one')
        t.eq(r.data.status, 'assigned')
        t.eq(json.decode(scalar("SELECT meta FROM fredpd_audit WHERE action = 'alert.assign' AND actor_citizenid = "
            .. "'DSP10001'")), { via = 'keybind' })
        t.eq(Service.takeNewest(1), { ok = false, error = 'not_found' })
        t.eq(#env.clientEvents, 0, 'keybind take: no client events (the Alert goes back in the callback reply)')
        t.eq(#env.pushes, 1)
        t.eq(env.pushes[1].payload.type, 'updated')
    end)
end

tests['13 listAlerts: open / mine / all, paging, validation'] = function(t)
    withEnv(t, function(_, env, mods)
        local Service = mods['server.alert_service']
        local a = newAlert(mods, { title = 'A' })
        local b = newAlert(mods, { title = 'B' })
        local c = newAlert(mods, { title = 'C' })
        Service.assignSelf(1, { id = a.id })
        Service.close(5, { id = c.id })
        local open = Service.list(1, {})
        t.eq(open.ok, true)
        t.eq(open.data.total, 2)
        t.eq(open.data.page, 1)
        t.eq({ open.data.items[1].id, open.data.items[2].id }, { b.id, a.id }, 'newest first, closed excluded')
        local mine = Service.list(1, { filter = 'mine' })
        t.eq(mine.data.total, 1)
        t.eq(mine.data.items[1].id, a.id)
        t.eq(mine.data.items[1].units[1].callsign, 'IGV-07')
        local all = Service.list(5, { filter = 'all' })
        t.eq(all.data.total, 3)
        t.eq(all.data.items[1].status, 'closed')
        t.eq(all.data.items[1].closedBy.callsign, 'LED-01')
        local page2 = Service.list(5, { filter = 'all', page = 2 })
        t.eq(page2.data, { items = {}, total = 3, page = 2 })
        t.eq(Service.list(1, { filter = 'nope' }), { ok = false, error = 'validation' })
        t.eq(Service.list(1, { page = 0 }), { ok = false, error = 'validation' })
    end)
end

tests['14 every src-taking export re-checks grant, duty and input'] = function(t)
    withEnv(t, function(_, env, mods)
        local Service = mods['server.alert_service']
        local alert = newAlert(mods)
        local offDuty = { ok = false, error = 'unauthorized', reason = 'off_duty' }
        local denied = { ok = false, error = 'unauthorized' }
        for _, call in ipairs({
            function(src) return Service.assignSelf(src, { id = alert.id }) end,
            function(src) return Service.leave(src, { id = alert.id }) end,
            function(src) return Service.close(src, { id = alert.id }) end,
            function(src) return Service.list(src, {}) end,
            function(src) return Service.getUnits(src) end,
            function(src) return Service.takeNewest(src) end,
        }) do
            t.eq(call(2), denied, 'no mdt_page:alerts')
            t.eq(call(3), offDuty, 'off duty')
            t.eq(call(4), denied, 'civilian')
            t.eq(call(0), denied, 'console')
            t.eq(call(nil), denied)
            t.eq(call(1.5), denied)
            t.eq(call(99), denied, 'not connected')
        end
        t.eq(Service.assignSelf(1, { id = 'x' }), { ok = false, error = 'validation' })
        t.eq(Service.assignSelf(1, nil), { ok = false, error = 'validation' })
        t.eq(Service.close(1, { id = -1 }), { ok = false, error = 'validation' })
        t.eq(Service.assignSelf(1, { id = 424242 }), { ok = false, error = 'not_found' })
        t.eq(scalar('SELECT status FROM fredpd_alerts WHERE id = ?', { alert.id }), 'open')
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_audit WHERE action LIKE 'alert.%'"), 0)
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Units roster

tests['15 units: on-duty roster with current alert, debounced to one push per 2 s'] = function(t)
    withEnv(t, function(_, env, mods)
        local Service, Roster = mods['server.alert_service'], mods['server.unit_roster']
        local a = newAlert(mods)
        local b = newAlert(mods)
        Service.assignSelf(1, { id = a.id })
        Service.assignSelf(1, { id = b.id })
        Service.assignSelf(5, { id = a.id })
        Service.close(5, { id = b.id })
        env.clear()
        env.timers = {}
        Roster._reset()

        local units = Roster.build()
        local cids = {}
        for _, u in ipairs(units) do cids[#cids + 1] = u.citizenid end
        t.eq(cids, { 'DSP10001', 'DSP10005', 'DSP10002', 'DSP10006' }, 'on duty only, ordered by unit + callsign')
        t.eq(units[1], { citizenid = 'DSP10001', displayName = 'Anna B.', callsign = 'IGV-07', unit = 'igv',
            onDuty = true, alertId = a.id }, 'newest NON-closed alert (b is closed)')
        t.eq(units[2].alertId, a.id)
        t.eq(units[3].alertId, nil)
        t.eq(units[4], { citizenid = 'DSP10006', displayName = 'acct_fia', onDuty = true },
            'no officer row: FiveM account name until the bot fills it (§4.9)')

        Roster.schedule()
        Roster.schedule()
        Roster.schedule()
        t.eq(#env.timers, 1, 'coalesced')
        t.eq(env.timers[1].at - env.now, Roster.MIN_DELAY_MS)
        env.advance(Roster.MIN_DELAY_MS)
        t.eq(#env.pushes, 1)
        t.eq(env.pushes[1].topic, 'units')
        t.eq(env.pushes[1].payload, { units = units })
        t.eq(env.posts[1].body, { type = 'unitsChanged', payload = { units = units } })

        env.players[2].duty = false
        Roster.schedule()
        t.eq(env.timers[1].at - env.now, Roster.INTERVAL_MS, 'right after a push: wait the full interval')
        env.advance(Roster.INTERVAL_MS - 1)
        t.eq(#env.pushes, 1, 'not before 2 s')
        env.advance(1)
        t.eq(#env.pushes, 2)
        t.eq(#env.pushes[2].payload.units, 3, 'officer 2 went off duty')
        t.eq(Roster.current(), env.pushes[2].payload.units, 'getUnits serves the last build')
        env.advance(60000)
        t.eq(#env.pushes, 2, 'nothing runs while nothing changes')
        t.eq(#env.timers, 0)
        Roster.schedule() -- e.g. a civilian's character load: same roster
        env.advance(Roster.INTERVAL_MS)
        t.eq(#env.pushes, 2, 'an unchanged roster is not pushed again')
        t.eq(#env.posts, 2)

        -- fredpd_devtools fake units join the roster; malformed entries are skipped; nil ends the run.
        Roster.setFake({ { id = 'FAKE001', unit = 'igv', callsign = 'IGV-91' }, { id = 'bad id!' }, 'x',
            { id = 'FAKE002', unit = 'span', callsign = 'SPAN-92' } })
        env.advance(Roster.INTERVAL_MS)
        local withFake = env.pushes[3].payload.units
        t.eq(#withFake, 5)
        local fake = {}
        for _, u in ipairs(withFake) do
            if u.citizenid:match('^FAKE') then fake[#fake + 1] = u end
        end
        t.eq(fake[1], { citizenid = 'FAKE001', displayName = 'IGV-91', callsign = 'IGV-91', unit = 'igv', onDuty = true })
        Roster.setFake(nil)
        env.advance(Roster.INTERVAL_MS)
        t.eq(#env.pushes[4].payload.units, 3)

        local r = Service.getUnits(1)
        t.eq(r.ok, true)
        t.eq(r.data, { units = env.pushes[4].payload.units })
    end)
end

---------------------------------------------------------------------------------------------------------------
-- main.lua wiring: exports, events, keybind callback, dev command

--- dofile server/main.lua with the env installed (fresh modules first).
local function loadMain(env)
    local savedPath = package.path
    package.path = DISPATCH .. '?.lua;' .. package.path
    local ok, err = pcall(dofile, DISPATCH .. 'server/main.lua')
    package.path = savedPath
    if not ok then error(err, 0) end
    return {
        service = package.loaded['server.alert_service'],
        roster = package.loaded['server.unit_roster'],
        bridge = package.loaded['server.ps_bridge'],
    }
end

tests['16 main: exports, server-only events and the roster triggers are registered'] = function(t)
    withEnv(t, function(_, env)
        MySQL.ready = function() end -- the start-up rebuild is tested separately below
        loadMain(env)
        t.eq(keys(env.exported), { 'assignSelf', 'closeAlert', 'createAlert', 'getUnits', 'leaveAlert', 'listAlerts',
            'takeAlert', 'takeNewest' })
        for _, name in ipairs({ 'fredpd:dispatch:incoming', 'QBCore:Server:SetDuty', 'QBCore:Server:OnJobUpdate',
            'QBCore:Server:PlayerLoaded', 'QBCore:Server:OnPlayerUnload', 'qbx_core:server:playerLoggedOut',
            'fredpd:officerChanged', 'playerDropped', 'fredpd:devtools:fakeUnits' }) do
            t.ok(env.handlers[name], name)
        end
        t.eq(env.commands.fredpd_testalert, nil, 'dev command only with fredpd_dev')

        -- ps-dispatch path through the registered handler (L from fredpd_core: Swedish labels)
        env.fire('fredpd:dispatch:incoming', '', shooting(), 7)
        t.eq(scalar('SELECT description FROM fredpd_alerts'), 'Vapen: Pistol')
        env.fire('fredpd:dispatch:incoming', 3, shooting(), 3)
        t.eq(scalar('SELECT COUNT(*) FROM fredpd_alerts'), 1, 'player source ignored')

        -- exported functions are the service ones
        local created = env.exported.createAlert({ code = '1', title = 'T', source = 'bolo' })
        t.eq(created.source, 'bolo')
        t.eq(env.exported.takeAlert(1, { id = created.id }).data.status, 'assigned')
        t.eq(env.exported.leaveAlert(1, { id = created.id }).data.status, 'open')
        t.eq(env.exported.assignSelf(1, { id = created.id }).ok, true)
        t.eq(env.exported.closeAlert(1, { id = created.id }).data.status, 'closed')
        t.eq(env.exported.listAlerts(1, { filter = 'all' }).data.total, 2)

        -- duty change -> one debounced rebuild
        env.advance(5000) -- run the rebuild the takes above scheduled
        env.clear()
        env.players[2].duty = false
        env.fire('QBCore:Server:SetDuty', '', 2, false)
        env.fire('QBCore:Server:OnJobUpdate', '', 2, {})
        t.eq(#env.timers, 1)
        env.fire('fredpd:devtools:fakeUnits', 4, { { id = 'FAKE001', callsign = 'X' } })
        env.advance(5000)
        t.eq(#env.pushes, 1)
        local units = env.pushes[1].payload.units
        for _, u in ipairs(units) do
            t.ok(u.citizenid ~= 'FAKE001', 'fake units from a player source are ignored')
            t.ok(u.citizenid ~= 'DSP10002', 'officer 2 went off duty')
        end
    end)
end

tests['17 keybind callback: grant -> 1/s rate limit -> duty -> newest open alert'] = function(t)
    withEnv(t, function(_, env)
        MySQL.ready = function() end
        loadMain(env)
        local cb = env.callbacks['fredpd:dispatch:takeNewest']
        t.ok(cb, 'lib.callback registered')
        t.eq(cb(4), { error = 'unauthorized' }, 'civilian')
        t.eq(cb(2), { error = 'unauthorized' }, 'no grant')
        t.eq(cb(3), { error = 'unauthorized', reason = 'off_duty' })
        env.now = env.now + 1000
        t.eq(cb(1), { error = 'not_found' })
        env.now = env.now + 1000
        local older = env.exported.createAlert({ code = '10-11', title = 'A', source = 'test',
            coords = { x = 1, y = 2, z = 3 } })
        local newer = env.exported.createAlert({ code = '10-12', title = 'B', source = 'test' })
        local r = cb(1)
        t.eq(r.id, newer.id)
        t.eq(r.status, 'assigned')
        t.eq(r.units[1].callsign, 'IGV-07')
        t.eq(cb(1), { error = 'rate_limited' }, 'second press within 1 s')
        env.now = env.now + 999
        t.eq(cb(1), { error = 'rate_limited' })
        env.now = env.now + 1
        t.eq(cb(1).id, older.id, 'next newest open')
        env.fire('playerDropped', 1)
        t.eq(cb(1), { error = 'not_found' }, 'rate-limit state dropped with the player')
    end)
end

tests['18 main: start-up rebuild and the dev command (fredpd_dev + group.admin only)'] = function(t)
    withEnv(t, function(_, env)
        local readyCb
        MySQL.ready = function(cb) readyCb = cb end
        env.convars.fredpd_dev = 'true'
        loadMain(env)
        t.ok(readyCb, 'MySQL.ready used')
        readyCb()
        t.eq(#env.timers, 1, 'roster rebuild scheduled at start')

        local cmd = env.commands.fredpd_testalert
        t.ok(cmd, 'registered with fredpd_dev')
        t.eq(cmd.opts.restricted, 'group.admin')
        t.eq(cmd.opts.help, SV['dev.command.testalert'])
        cmd.fn(1)
        t.eq(env.clientEvents[1].name, 'fredpd:dispatch:client:testShooting')
        t.eq(env.clientEvents[1].target, 1)
        t.eq(scalar('SELECT COUNT(*) FROM fredpd_alerts'), 0, 'the client runs ps-dispatch Shooting()')

        env.resources['ps-dispatch'] = 'missing'
        cmd.fn(1)
        local row = q('SELECT code, title, source, priority, coords FROM fredpd_alerts')[1]
        t.eq(row.code, '10-11')
        t.eq(row.title, SV['dev.testalert.title'])
        t.eq(row.source, 'devtools')
        t.eq(json.decode(row.coords), { x = 10.5, y = 20.25, z = 30 })
        cmd.fn(0)
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_alerts WHERE source = 'devtools'"), 2, 'console: Legion Square')
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Golden files for the TypeScript contract test (deterministic: fixed ids, officers and timestamps)

--- Canonical JSON: sorted keys, empty table = [] (FiveM msgpack sends an empty Lua table as an array), integers
--- without a fraction. nil fields are absent, exactly as they reach JS/NUI from Lua (see docs/modules/dispatch.md).
local function canonical(v, indent)
    indent = indent or ''
    local t = type(v)
    if t == 'nil' then return 'null' end
    if t == 'boolean' then return tostring(v) end
    if t == 'number' then
        if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return ('%d'):format(v) end
        return ('%.17g'):format(v)
    end
    if t == 'string' then return json.encode(v) end
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
    print('dispatch_server_test: wrote ' .. path)
    return true
end

tests['19 golden: Alert / list / units / toast / push / internal-event JSON for contract.test.ts'] = function(t)
    withEnv(t, function(_, env, mods)
        local Service, Roster = mods['server.alert_service'], mods['server.alert_store']
        MySQL.query.await('ALTER TABLE fredpd_alerts AUTO_INCREMENT = 1')
        mods['server.ps_bridge'].L = require('shared.locale').L
        local open = mods['server.ps_bridge'].handle('', shooting({ information = 'Två skott mot Legion Square',
            vehicle = 'Sultan RS', plate = 'ABC 12D' }), 7)
        local bare = Service.create({ code = '10-80', title = 'Misstänkt aktivitet', source = 'devtools' })
        local taken = Service.create({ code = '10-31', title = 'Inbrott pågår', source = 'bolo', priority = 1,
            coords = { x = -1234.5, y = 987.25, z = 12 }, street = 'Mirror Park Blvd', description = 'Larm från butik' })
        Service.assignSelf(1, { id = taken.id })
        Service.assignSelf(6, { id = taken.id })
        local closing = Service.create({ code = '10-50', title = 'Trafikolycka', source = 'ps-dispatch', priority = 3 })
        Service.assignSelf(5, { id = closing.id })
        Service.close(5, { id = closing.id })
        t.eq({ open.id, bare.id, taken.id, closing.id }, { 1, 2, 3, 4 })
        MySQL.query.await("UPDATE fredpd_alerts SET created_at = '2026-09-29 10:00:00' + INTERVAL id MINUTE, "
            .. "closed_at = IF(closed_at IS NULL, NULL, '2026-09-29 10:30:00')")
        MySQL.query.await("UPDATE fredpd_alert_units SET created_at = '2026-09-29 10:10:00' + INTERVAL "
            .. "IF(citizenid = 'DSP10001', 0, 1) MINUTE")

        local alerts = Roster.load({ 1, 2, 3, 4 })
        t.eq(alerts[1].createdAt, '2026-09-29T10:01:00Z', 'UTC DATETIME read back verbatim (session at +02:00)')
        t.eq(alerts[4].closedAt, '2026-09-29T10:30:00Z')
        writeGolden('alert.open', alerts[1])
        writeGolden('alert.bare', alerts[2])
        writeGolden('alert.assigned', alerts[3])
        writeGolden('alert.closed', alerts[4])

        env.clear()
        local list = Service.list(1, { filter = 'all' })
        writeGolden('list.all', list.data)
        writeGolden('list.empty', Service.list(1, { filter = 'all', page = 9 }).data)

        mods['server.unit_roster'].setFake({ { id = 'FAKE001', unit = 'igv', callsign = 'IGV-91' } })
        env.advance(1000)
        writeGolden('units', env.pushes[#env.pushes].payload)
        writeGolden('internal.unitsChanged', env.posts[#env.posts].body)

        env.clear()
        local fresh = Service.create({ code = '10-11', title = 'Skottlossning', source = 'test', street = 'Strawberry Ave',
            coords = { x = 1, y = 2, z = 3 } })
        MySQL.query.await("UPDATE fredpd_alerts SET created_at = '2026-09-29 11:00:00' WHERE id = ?", { fresh.id })
        writeGolden('toast', env.toasts()[1].args[1])
        local toastNoStreet = Service.create({ code = '10-80', title = 'Utan gata', source = 'test' })
        t.eq(env.toasts()[#env.toasts()].args[1].street, nil)
        writeGolden('toast.nostreet', env.toasts()[#env.toasts()].args[1])
        t.ok(toastNoStreet)

        -- Pushes and service events as sent (timestamps of the fresh rows normalised for stable files).
        local function stable(v)
            if type(v) ~= 'table' then return v end
            local out = {}
            for k, x in pairs(v) do
                out[k] = (k == 'createdAt' or k == 'closedAt') and '2026-09-29T11:00:00Z' or stable(x)
            end
            return out
        end
        writeGolden('push.created', stable(env.pushes[1].payload))
        writeGolden('internal.alertCreated', stable(env.posts[1].body))
        env.clear()
        Service.assignSelf(1, { id = fresh.id })
        writeGolden('push.updated', stable(env.pushes[1].payload))
        writeGolden('internal.alertAssigned', stable(env.posts[1].body))
        env.clear()
        Service.close(1, { id = fresh.id })
        writeGolden('push.closed', env.pushes[1].payload)
        writeGolden('internal.alertClosed', env.posts[1].body)

        -- Normalised ps-dispatch input (AlertCreateInputSchema)
        local input = mods['shared.alert_input'].fromPsDispatch(shooting({ information = 'Två skott' }),
            require('shared.locale').L)
        writeGolden('create-input.ps-dispatch', input)
        t.ok(io.open(GOLDEN .. 'alert.assigned.json', 'r'), 'golden files exist')
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Static checks over the module source

local function sourceFiles()
    local files = {}
    local p = io.popen("ls '" .. DISPATCH .. "server/'*.lua '" .. DISPATCH .. "shared/'*.lua '" .. DISPATCH
        .. "client/'*.lua")
    for line in p:lines() do files[#files + 1] = line end
    p:close()
    return files
end

tests['20 SQL uses UTC_TIMESTAMP() only and reads DATETIME columns through isoSelect'] = function(t)
    local files = sourceFiles()
    t.ok(#files >= 7, 'found ' .. #files .. ' files')
    for _, path in ipairs(files) do
        local src = helper.readFile(path) -- SQL is written in upper case; Lua's own now() is not SQL
        t.ok(not src:find('NOW()', 1, true), path .. ': NOW()')
        t.ok(not src:find('CURRENT_TIMESTAMP', 1, true), path .. ': CURRENT_TIMESTAMP')
    end
    local store = helper.readFile(DISPATCH .. 'server/alert_store.lua')
    t.ok(not store:find('a%.created_at,'), 'created_at is never selected bare')
    t.ok(not store:find('a%.closed_at,'), 'closed_at is never selected bare')
end

tests['21 every L() key used by fredpd_dispatch exists in sv/en or locales/pending/dispatch.json'] = function(t)
    local sv = helper.readJson('locales/sv.json')
    local en = helper.readJson('locales/en.json')
    local pending = helper.readJson('locales/pending/dispatch.json')
    local n = 0
    for _, path in ipairs(sourceFiles()) do
        local src = helper.readFile(path)
        for key in src:gmatch("[%.%s%(=,]L%(%s*'([%w_%.]+)'") do
            n = n + 1
            local inMain = sv[key] ~= nil and en[key] ~= nil
            local inPending = type(pending[key]) == 'table' and pending[key].sv and pending[key].en
            t.ok(inMain or inPending, ('%s (used in %s) is missing from locales'):format(key, path))
        end
        for key in src:gmatch("line%('([%w_%.]+)'") do
            t.ok(pending[key] or sv[key], key .. ' (description label) missing')
        end
    end
    t.ok(n >= 12, 'expected at least 12 L() calls, found ' .. n)
end

return tests
