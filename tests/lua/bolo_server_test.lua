-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_bolo server against a real MariaDB (tests/lua/mysql_shim.lua runs the migrations and fakes oxmysql), with
-- FiveM mocked: exports (fredpd_core grants/duty/officers/tier/units, canView with the real shared/canview.lua and
-- the seeded rules, audit through the real fredpd_core audit module, refreshPlate through the real mirror module;
-- fredpd_mdt push; fredpd_dispatch createAlert), entity natives, events, lib.callback.
-- Covers create / resolve / list / expiry (lazy deactivation, at rebuild, never a hit) / audit rows / hit cooldown
-- / plate normalisation / canView shaping and SQL filtering / plateCheck deriving the plate from the entity /
-- resolveOnImpound / getBolosFor / main.lua wiring / UTC, and writes the golden JSON files checked against
-- packages/types/src/mdt.ts by resources/[fredpd]/fredpd_bolo/test/contract.test.ts.
-- Database fredpd_test_bolo_lua (reset once per run); every session at time_zone '+02:00' (§C7: nothing may depend
-- on it). Skips with a notice when MariaDB is unreachable.
-- Run: lua5.4 tests/lua/run.lua bolo_server
local shim = require('mysql_shim')
local helper = require('helper')

local DB = 'fredpd_test_bolo_lua'
local BOLO = './resources/[fredpd]/fredpd_bolo/'
local GOLDEN = BOLO .. 'test/golden/'
local MODULES = { 'shared.input', 'server.store', 'server.cache', 'server.visibility', 'server.fanout',
    'server.service' }
local ISO = '^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$'

local tests = {}

---------------------------------------------------------------------------------------------------------------
-- Environment

package.preload['@fredpd_core.shared.time'] = package.preload['@fredpd_core.shared.time']
    or function() return require('shared.time') end
package.preload['@fredpd_core.shared.locale'] = package.preload['@fredpd_core.shared.locale']
    or function() return require('shared.locale') end

--- sv.json + pending/bolo.json (sv).
local SV = (function()
    local dict = helper.readJson('locales/sv.json')
    for k, v in pairs(helper.readJson('locales/pending/bolo.json')) do
        if type(v) == 'table' and v.sv then dict[k] = v.sv end
    end
    return dict
end)()

local ALL = { ['mdt_page:search'] = true, ['mdt_page:bolos'] = true, ['perm:bolo.create'] = true,
    ['perm:bolo.resolve'] = true }

-- 1 IGV tier 0 (all bolo grants), 2 SPAN tier 1, 3 off duty, 4 civilian, 5 Ledning records.admin tier 2,
-- 6 IGV tier 0 with search/bolos only (no officer row), 7 Utredning tier 1.
local function defaultPlayers()
    local function copy(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end
    local ledning = copy(ALL)
    ledning['perm:records.admin'] = true
    return {
        [1] = { cid = 'BOL10001', duty = true, grants = copy(ALL), tier = 0, units = { 'igv' },
            officer = { citizenid = 'BOL10001', displayName = 'Anna B.', callsign = 'IGV-07', unit = 'igv' } },
        [2] = { cid = 'BOL10002', duty = true, grants = copy(ALL), tier = 1, units = { 'span' },
            officer = { citizenid = 'BOL10002', displayName = 'Bo C.', callsign = 'SPAN-02', unit = 'span' } },
        [3] = { cid = 'BOL10003', duty = false, grants = copy(ALL), tier = 0, units = { 'igv' } },
        [4] = { cid = 'CIV40004', duty = false, grants = {}, tier = 0, units = {} },
        [5] = { cid = 'BOL10005', duty = true, grants = ledning, tier = 2, units = { 'ledning' },
            officer = { citizenid = 'BOL10005', displayName = 'Eva L.', callsign = 'LED-01', unit = 'ledning' } },
        [6] = { cid = 'BOL10006', duty = true, grants = { ['mdt_page:search'] = true, ['mdt_page:bolos'] = true },
            tier = 0, units = { 'igv' } },
        [7] = { cid = 'BOL10007', duty = true, grants = copy(ALL), tier = 1, units = { 'utredning' },
            officer = { citizenid = 'BOL10007', displayName = 'Cia D.', callsign = 'UTR-03', unit = 'utredning' } },
    }
end

local OFFICER_ROWS = {
    { 'BOL10001', '100000000000000001', 'Anna B.', 'IGV-07', 'igv' },
    { 'BOL10002', '100000000000000002', 'Bo C.', 'SPAN-02', 'span' },
    { 'BOL10005', '100000000000000005', 'Eva L.', 'LED-01', 'ledning' },
    { 'BOL10007', '100000000000000007', 'Cia D.', 'UTR-03', 'utredning' },
}

local prepared = nil
local notified = false

local GLOBALS = { 'MySQL', 'LoadResourceFile', 'GetCurrentResourceName', 'exports', 'GetPlayers', 'GetGameTimer',
    'CreateThread', 'TriggerEvent', 'TriggerClientEvent', 'GetResourceState', 'AddEventHandler', 'lib',
    'GetPlayerIdentifierByType', 'GetPlayerPed', 'GetEntityCoords', 'NetworkGetEntityFromNetworkId',
    'DoesEntityExist', 'GetEntityType', 'GetVehicleNumberPlateText', 'GetVehiclePedIsIn', 'GetConvar', 'source',
    'locale' }

--- Fresh copies of the fredpd_bolo modules (module state: cache, cooldowns, limiter).
local function freshModules()
    for _, name in ipairs(MODULES) do package.loaded[name] = nil end
    local savedPath = package.path
    package.path = BOLO .. '?.lua;' .. package.path
    local ok, mods = pcall(function()
        local out = {}
        for _, name in ipairs(MODULES) do out[name] = require(name) end
        return out
    end)
    package.path = savedPath
    if not ok then error(mods, 0) end
    local L = require('shared.locale').L
    mods['server.store'].L, mods['server.visibility'].L, mods['server.fanout'].L, mods['server.service'].L = L, L, L, L
    return mods
end

local function forgetModules()
    for _, name in ipairs(MODULES) do package.loaded[name] = nil end
end

--- Build the mocked FiveM world.
local function makeEnv()
    local Audit = require('server.audit')
    local Mirror = require('server.mirror')
    local CanViewShared = require('shared.canview')
    local CanViewServer = require('server.canview')
    local env = {
        now = 100000, players = defaultPlayers(), events = {}, pushes = {}, audits = {}, alerts = {}, handlers = {},
        exported = {}, callbacks = {}, logs = {}, entities = {}, peds = {}, notifies = {}, inVehicle = {}, convars = {},
        commands = {},
        resources = { fredpd_mdt = 'started', fredpd_dispatch = 'started', fredpd_core = 'started' },
        pushFails = false, alertFails = false,
    }
    env.rules = {}
    for i, row in ipairs(MySQL.query.await(CanViewServer.RULES_SQL)) do env.rules[i] = CanViewServer.rowToRule(row) end

    function env.named(name)
        local out = {}
        for _, e in ipairs(env.events) do
            if e.name == name then out[#out + 1] = e end
        end
        return out
    end

    function env.clear()
        env.events, env.pushes, env.audits, env.alerts, env.logs = {}, {}, {}, {}, {}
    end

    --- Replace one rule's result (by id) for a test.
    function env.setRule(id, result)
        for _, r in ipairs(env.rules) do
            if r.id == id then r.result = result end
        end
    end

    local function player(src) return env.players[tonumber(src)] end

    local function viewerOf(src)
        local p = player(src)
        if not p then return { citizenid = nil, tier = 0, units = {}, grants = nil } end
        local list = {}
        for k, v in pairs(p.grants) do if v then list[#list + 1] = k end end
        table.sort(list)
        return { citizenid = p.cid, tier = p.tier, units = p.units,
            grants = { grants = list, denied = {}, tier = p.tier, units = p.units } }
    end

    local core = {
        hasGrant = function(_, src, t, k) local p = player(src); return p ~= nil and p.grants[t .. ':' .. k] == true end,
        isOnDuty = function(_, src) local p = player(src); return p ~= nil and p.duty == true end,
        getCitizenId = function(_, src) local p = player(src); return p and p.cid or nil end,
        getOfficer = function(_, src) local p = player(src); return p and p.officer or nil end,
        getUnits = function(_, src) local p = player(src); return p and p.units or {} end,
        getTier = function(_, src) local p = player(src); return p and p.tier or 0 end,
        canView = function(_, src, record) return CanViewShared.evaluate(viewerOf(src), record, env.rules) end,
        canViewMany = function(_, src, records)
            env.canViewCalls = (env.canViewCalls or 0) + 1
            local viewer, out = viewerOf(src), {}
            for i, r in ipairs(records) do out[i] = CanViewShared.evaluate(viewer, r, env.rules) end
            return out
        end,
        audit = function(_, src, action, targetType, targetId, meta)
            env.audits[#env.audits + 1] = { src = src, action = action, targetType = targetType, targetId = targetId,
                meta = meta }
            return Audit.audit(src, action, targetType, targetId, meta)
        end,
        refreshPlate = function(_, plate)
            env.refreshed = (env.refreshed or 0) + 1
            return Mirror.refreshPlate(plate)
        end,
    }
    local mdt = {
        pushToOpenTablets = function(_, topic, payload)
            if env.pushFails then error('No such export pushToOpenTablets in resource fredpd_mdt', 0) end
            env.pushes[#env.pushes + 1] = { topic = topic, payload = payload }
        end,
    }
    local dispatch = {
        createAlert = function(_, input)
            if env.alertFails then error('dispatch down', 0) end
            if env.alertRefuses then return nil, 'validation' end
            env.alerts[#env.alerts + 1] = input
            return { id = #env.alerts }
        end,
    }
    local qbx = {
        GetPlayer = function(_, src)
            local p = player(src)
            return p and { PlayerData = { citizenid = p.cid, source = tonumber(src) } } or nil
        end,
    }

    env.globals = {
        exports = setmetatable({ fredpd_core = core, fredpd_mdt = mdt, fredpd_dispatch = dispatch, qbx_core = qbx }, {
            __call = function(_, name, fn) env.exported[name] = fn end,
        }),
        GetPlayers = function()
            local ids = {}
            for src in pairs(env.players) do ids[#ids + 1] = tostring(src) end
            table.sort(ids)
            return ids
        end,
        GetPlayerIdentifierByType = function(src) return ('discord:%d'):format(900000000000000000 + tonumber(src)) end,
        GetGameTimer = function() return env.now end,
        CreateThread = function(fn) fn() end,
        TriggerEvent = function(name, ...)
            env.events[#env.events + 1] = { name = name, args = { ... } }
            -- local events reach this resource's own handlers too (FiveM)
            for _, fn in ipairs(env.handlers[name] or {}) do fn(...) end
        end,
        TriggerClientEvent = function(name, target, ...)
            if name ~= 'ox_lib:notify' then error('fredpd_bolo sends no client events but notifications', 0) end
            env.notifies[#env.notifies + 1] = { target = target, data = ... }
        end,
        GetVehiclePedIsIn = function(ped) return env.inVehicle[ped] or 0 end,
        GetConvar = function(name, default) return env.convars[name] or default end,
        GetResourceState = function(name) return env.resources[name] or 'missing' end,
        AddEventHandler = function(name, fn)
            env.handlers[name] = env.handlers[name] or {}
            table.insert(env.handlers[name], fn)
        end,
        GetPlayerPed = function(src) return 1000 + tonumber(src) end,
        GetEntityCoords = function(entity)
            local e = env.peds[entity] or env.entities[entity]
            return e and e.coords or { x = 0.0, y = 0.0, z = 0.0 }
        end,
        NetworkGetEntityFromNetworkId = function(netId)
            for entity, e in pairs(env.entities) do
                if e.netId == netId then return entity end
            end
            return 0
        end,
        DoesEntityExist = function(entity) return env.entities[entity] ~= nil end,
        GetEntityType = function(entity) local e = env.entities[entity]; return e and e.type or 0 end,
        GetVehicleNumberPlateText = function(entity) local e = env.entities[entity]; return e and e.plate or nil end,
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

    -- Player 1 stands next to vehicle 5001 (plate ' abc 12d ', netId 77).
    env.peds[1001] = { coords = { x = 100.0, y = 200.0, z = 30.0 } }
    env.peds[1002] = { coords = { x = 100.0, y = 204.0, z = 30.0 } }
    env.entities[5001] = { netId = 77, type = 2, plate = ' abc 12d ', coords = { x = 101.5, y = 201.25, z = 30.0 } }
    env.entities[5002] = { netId = 78, type = 1, coords = { x = 100.0, y = 201.0, z = 30.0 } } -- a ped
    env.entities[5003] = { netId = 79, type = 2, plate = 'ZZZ 99Z', coords = { x = 300.0, y = 200.0, z = 30.0 } }
    env.entities[5004] = { netId = 80, type = 2, plate = '        ', coords = { x = 101.0, y = 200.0, z = 30.0 } }
    return env
end

--- Run fn(t, env, mods) with MariaDB + mocks installed; restores every global afterwards.
local function withEnv(t, fn)
    local ok, reason = shim.available()
    if not ok then
        if not notified then
            print(('SKIP bolo_server_test: MariaDB unreachable (%s)'):format((reason or ''):gsub('%s+$', '')))
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
        -- Clean slate per test (the schema stays).
        MySQL.query.await('DELETE FROM fredpd_bolos')
        MySQL.query.await('DELETE FROM fredpd_plate_checks')
        MySQL.query.await("DELETE FROM fredpd_audit WHERE action LIKE 'bolo.%'")
        MySQL.query.await('DELETE FROM fredpd_vehicles_idx')
        for _, r in ipairs(OFFICER_ROWS) do
            MySQL.query.await('INSERT IGNORE INTO fredpd_officers (citizenid, discord_id, display_name, callsign, unit) '
                .. 'VALUES (?, ?, ?, ?, ?)', r)
        end
        MySQL.query.await('INSERT IGNORE INTO fredpd_persons (citizenid, firstname, lastname) VALUES '
            .. "('FPD10001', 'Anna', 'Berg'), ('FPD10002', 'Erik', 'Lindqvist'), ('FPD10003', 'Sara', 'Öberg')")
        MySQL.query.await("INSERT INTO fredpd_vehicles_idx (plate, citizenid, model) VALUES ('ABC12D', 'FPD10002', "
            .. "'sultan'), ('QRS45T', NULL, 'blista')")
        local env = makeEnv()
        for k, v in pairs(env.globals) do rawset(_G, k, v) end
        rawset(_G, 'source', nil)
        local mods = freshModules()
        mods['server.cache'].reset()
        fn(t, env, mods)
    end)
    forgetModules()
    for n, v in pairs(saved) do rawset(_G, n, v[1]) end
    shim.sessionTimeZone = nil
    shim.database, shim.resourceName = savedDatabase, savedResource
    if not okRun then error(err, 0) end
end

local function scalar(sql, params) return MySQL.scalar.await(sql, params) end
local function q(sql, params) return MySQL.query.await(sql, params) end

local function keys(tbl)
    local out = {}
    for k in pairs(tbl) do out[#out + 1] = k end
    table.sort(out)
    return out
end

local function vehicleInput(extra)
    local input = { kind = 'vehicle', plate = 'abc 12d', reason = 'Rån mot värdetransport' }
    for k, v in pairs(extra or {}) do input[k] = v end
    return input
end

--- Create a BOLO as `src` and return its data (asserts success).
local function create(t, Service, src, input)
    local res = Service.createBolo(src, input)
    t.eq(res.ok, true, 'createBolo: ' .. helper.dump(res))
    return res.data
end

---------------------------------------------------------------------------------------------------------------
-- Migration

tests['01 migration: fredpd_plate_checks and the wider resolve_note'] = function(t)
    withEnv(t, function()
        local cols = {}
        for _, r in ipairs(q("SELECT column_name AS c, data_type AS d, column_default AS def FROM "
            .. "information_schema.columns WHERE table_schema = DATABASE() AND table_name = 'fredpd_plate_checks' "
            .. 'ORDER BY ordinal_position')) do
            cols[#cols + 1] = r.c
            if r.c == 'created_at' then t.eq(tostring(r.def):lower(), 'utc_timestamp()') end
        end
        t.eq(cols, { 'id', 'plate', 'officer_citizenid', 'hit', 'bolo_id', 'source', 'created_at' })
        t.eq(scalar("SELECT GROUP_CONCAT(column_name ORDER BY seq_in_index) FROM information_schema.statistics "
            .. "WHERE table_schema = DATABASE() AND table_name = 'fredpd_plate_checks' AND index_name = "
            .. "'idx_plate_created'"), 'plate,created_at')
        t.eq(scalar("SELECT CONCAT(table_collation, '/', engine) FROM information_schema.tables WHERE table_schema = "
            .. "DATABASE() AND table_name = 'fredpd_plate_checks'"), 'utf8mb4_swedish_ci/InnoDB')
        t.eq(scalar("SELECT character_maximum_length FROM information_schema.columns WHERE table_schema = DATABASE() "
            .. "AND table_name = 'fredpd_bolos' AND column_name = 'resolve_note'"), 500)
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Create

tests['02 createBolo (vehicle): row, Bolo shape, cache, audit, push, server event, UTC'] = function(t)
    withEnv(t, function(_, env, mods)
        local Service = mods['server.service']
        local bolo = create(t, Service, 1, vehicleInput())
        t.ok(math.type(bolo.id) == 'integer' and bolo.id > 0)
        t.eq(bolo.kind, 'vehicle')
        t.eq(bolo.plate, 'ABC12D', 'normalised')
        t.eq(bolo.citizenid, nil)
        t.eq(bolo.subject, 'ABC12D · sultan')
        t.eq(bolo.reason, 'Rån mot värdetransport')
        t.eq(bolo.level, 0)
        t.eq(bolo.active, true)
        t.eq(bolo.issuedBy, { citizenid = 'BOL10001', displayName = 'Anna B.', callsign = 'IGV-07', unit = 'igv' })
        t.ok(bolo.createdAt:match(ISO), bolo.createdAt)
        t.eq(bolo.expiresAt, nil)
        t.eq(keys(bolo), { 'active', 'createdAt', 'id', 'issuedBy', 'kind', 'level', 'plate', 'reason', 'subject' })

        local row = q('SELECT kind, plate, citizenid, level, unit, issued_by, active, '
            .. 'TIMESTAMPDIFF(SECOND, created_at, UTC_TIMESTAMP()) AS age, '
            .. 'TIMESTAMPDIFF(SECOND, updated_at, UTC_TIMESTAMP()) AS uage FROM fredpd_bolos WHERE id = ?', { bolo.id })[1]
        t.eq(row.plate, 'ABC12D')
        t.eq(row.unit, 'igv')
        t.eq(row.issued_by, 'BOL10001')
        t.eq(row.active, 1)
        t.ok(math.abs(row.age) < 60 and math.abs(row.uage) < 60, 'created_at/updated_at are UTC (session is +02:00)')

        t.eq(Service.checkPlate('ABC 12D').id, bolo.id, 'in-memory lookup, any spelling')
        t.eq(Service.checkPlate('abc12d').active, true)
        t.eq(Service.checkPerson('FPD10002'), nil)

        t.eq(#env.audits, 1)
        t.eq(env.audits[1].action, 'bolo.create')
        t.eq(env.audits[1].targetType, 'bolo')
        t.eq(env.audits[1].meta, { kind = 'vehicle', plate = 'ABC12D', level = 0 })
        local audit = q("SELECT actor_citizenid, target_type, target_id FROM fredpd_audit WHERE action = 'bolo.create'")
        t.eq(audit, { { actor_citizenid = 'BOL10001', target_type = 'bolo', target_id = bolo.id } })

        t.eq(env.pushes, { { topic = 'bolo', payload = { type = 'created', id = bolo.id } } })
        local changed = env.named('fredpd:boloChanged')
        t.eq(#changed, 1)
        t.eq(changed[1].args[1].id, bolo.id)
        t.eq(changed[1].args[1].reason, 'Rån mot värdetransport', 'server event carries the full Bolo')
        t.eq(changed[1].args[2], 'created')
        t.eq(changed[1].args[1].unit, nil, 'internal fields stay off the wire')
    end)
end

tests['03 createBolo (person, expiry): expiresAt from the database clock, checkPerson'] = function(t)
    withEnv(t, function(_, _, mods)
        local Service, Time = mods['server.service'], require('shared.time')
        local bolo = create(t, Service, 2, { kind = 'person', citizenid = 'FPD10002', reason = 'Misstänkt för rån',
            level = 1, expiresInHours = 2 })
        t.eq(bolo.subject, 'Erik Lindqvist')
        t.eq(bolo.citizenid, 'FPD10002')
        t.eq(bolo.plate, nil)
        t.eq(bolo.level, 1)
        t.ok(bolo.expiresAt:match(ISO))
        local delta = Time.toEpoch(bolo.expiresAt) - Time.toEpoch(bolo.createdAt)
        t.eq(delta, 7200, 'expires 2 h after creation (both UTC)')
        t.ok(math.abs(Time.toEpoch(bolo.expiresAt) - os.time() - 7200) < 60, 'UTC, not the +02:00 session')
        t.eq(Service.checkPerson('FPD10002').id, bolo.id)
        t.eq(Service.checkPerson('FPD99999'), nil)
        t.eq(Service.checkPerson("x' OR 1"), nil)
        t.eq(scalar('SELECT unit FROM fredpd_bolos WHERE id = ?', { bolo.id }), 'span')
    end)
end

tests['04 createBolo: actor, validation, subject must exist, duplicates, level above tier'] = function(t)
    withEnv(t, function(_, env, mods)
        local Service = mods['server.service']
        t.eq(Service.createBolo(4, vehicleInput()), { ok = false, error = 'unauthorized' }, 'civilian')
        t.eq(Service.createBolo(3, vehicleInput()), { ok = false, error = 'unauthorized', reason = 'off_duty' })
        t.eq(Service.createBolo(6, vehicleInput()), { ok = false, error = 'unauthorized' }, 'no perm:bolo.create')
        t.eq(Service.createBolo(0, vehicleInput()), { ok = false, error = 'unauthorized' }, 'console')
        t.eq(Service.createBolo('1; DROP', vehicleInput()), { ok = false, error = 'unauthorized' })
        t.eq(Service.createBolo(1, vehicleInput({ reason = 'ab' })), { ok = false, error = 'validation',
            reason = 'reason' })
        t.eq(Service.createBolo(1, vehicleInput({ citizenid = 'FPD10002' })).reason, 'citizenid')
        t.eq(Service.createBolo(1, 'x').error, 'validation')

        t.eq(Service.createBolo(1, vehicleInput({ plate = 'NOP 00X' })), { ok = false, error = 'not_found' },
            'plate not in the register')
        t.eq(Service.createBolo(1, { kind = 'person', citizenid = 'NOPE1', reason = 'xyz' }),
            { ok = false, error = 'not_found' })

        -- tier 0 officer cannot issue a Begränsad BOLO; the tier 1 SPAN officer can
        t.eq(Service.createBolo(1, vehicleInput({ level = 1 })), { ok = false, error = 'unauthorized',
            reason = 'level' })

        -- a plate only in player_vehicles ('KLM 34E') is refreshed into the mirror first
        local klm = create(t, Service, 1, vehicleInput({ plate = 'klm34e' }))
        t.eq(klm.subject, 'KLM34E · blista')
        t.eq(env.refreshed, 2, 'NOP00X (miss) and KLM34E (found)')

        local first = create(t, Service, 2, vehicleInput({ level = 1 }))
        t.eq(Service.createBolo(1, vehicleInput({ plate = 'ABC12D' })), { ok = false, error = 'validation',
            reason = 'duplicate' })
        -- the SQL guard alone (cache emptied) also refuses a second active BOLO
        mods['server.cache'].remove(first.id)
        t.eq(Service.createBolo(1, vehicleInput()), { ok = false, error = 'validation', reason = 'duplicate' })
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_bolos WHERE plate = 'ABC12D'"), 1)
        t.eq(#env.named('fredpd:boloChanged'), 2)
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Resolve

tests['05 resolveBolo: row, audit, push, event, cache; second resolve not_found'] = function(t)
    withEnv(t, function(_, env, mods)
        local Service = mods['server.service']
        local bolo = create(t, Service, 1, vehicleInput())
        env.clear()
        local note = ('å'):rep(500)
        local res = Service.resolveBolo(1, { id = bolo.id, note = note })
        t.eq(res.ok, true, helper.dump(res))
        local r = res.data
        t.eq(r.active, false)
        t.eq(r.resolveNote, note, '500 characters fit (010 widened the column)')
        t.eq(r.resolvedBy, { citizenid = 'BOL10001', displayName = 'Anna B.', callsign = 'IGV-07', unit = 'igv' })
        t.ok(r.resolvedAt:match(ISO))
        t.eq(Service.checkPlate('ABC12D'), nil)

        local row = q('SELECT active, resolved_by, TIMESTAMPDIFF(SECOND, resolved_at, UTC_TIMESTAMP()) AS age '
            .. 'FROM fredpd_bolos WHERE id = ?', { bolo.id })[1]
        t.eq(row.active, 0)
        t.eq(row.resolved_by, 'BOL10001')
        t.ok(math.abs(row.age) < 60, 'resolved_at is UTC')

        t.eq(#env.audits, 1)
        t.eq(env.audits[1].action, 'bolo.resolve')
        t.eq(env.audits[1].meta, { via = 'tablet', kind = 'vehicle', plate = 'ABC12D' })
        t.eq(env.pushes, { { topic = 'bolo', payload = { type = 'resolved', id = bolo.id } } })
        t.eq(env.named('fredpd:boloChanged')[1].args[2], 'resolved')
        t.eq(env.named('fredpd:boloChanged')[1].args[1].active, false)

        t.eq(Service.resolveBolo(1, { id = bolo.id }), { ok = false, error = 'not_found' })
        t.eq(Service.resolveBolo(1, { id = 999999 }), { ok = false, error = 'not_found' })
        t.eq(Service.resolveBolo(1, { id = -1 }), { ok = false, error = 'validation', reason = 'id' })
        t.eq(Service.resolveBolo(6, { id = bolo.id }), { ok = false, error = 'unauthorized' }, 'no perm')

        -- a new BOLO on the same plate is possible again
        local again = create(t, Service, 1, vehicleInput())
        t.ok(again.id > bolo.id)
        -- empty note -> NULL
        t.eq(Service.resolveBolo(1, { id = again.id, note = '  ' }).data.resolveNote, nil)
        t.eq(scalar('SELECT resolve_note IS NULL FROM fredpd_bolos WHERE id = ?', { again.id }), 1)
    end)
end

tests['06 resolveBolo: a kontaktnotis viewer is refused, the issuer, unit and records.admin may'] = function(t)
    withEnv(t, function(_, _, mods)
        local Service = mods['server.service']
        local span = create(t, Service, 2, vehicleInput({ level = 1 }))
        t.eq(Service.resolveBolo(1, { id = span.id }), { ok = false, error = 'unauthorized' }, 'IGV tier 0: notice')
        t.eq(Service.resolveBolo(5, { id = span.id }).ok, true, 'Ledning (records.admin)')

        local person = create(t, Service, 2, { kind = 'person', citizenid = 'FPD10003', reason = 'Vittne', level = 1 })
        t.eq(Service.resolveBolo(7, { id = person.id }).ok, true, 'Utredning tier 1: tier_gte')
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Lists and visibility

tests['07 listBolos (active): newest first, canView shaping, paging, grant'] = function(t)
    withEnv(t, function(_, _, mods)
        local Service = mods['server.service']
        local a = create(t, Service, 1, vehicleInput())
        local b = create(t, Service, 2, { kind = 'person', citizenid = 'FPD10003', reason = 'Hot mot tjänsteman',
            level = 1 })
        local c = create(t, Service, 1, { kind = 'person', citizenid = 'FPD10001', reason = 'Saknad person' })
        Service.resolveBolo(1, { id = c.id })

        local list = Service.listBolos(1, { active = true })
        t.eq(list.ok, true)
        t.eq(list.data.total, 2)
        t.eq(list.data.page, 1)
        t.eq(list.data.items[1].id, b.id)
        t.eq(list.data.items[2].id, a.id)
        -- IGV tier 0 sees the SPAN level 1 BOLO as a kontaktnotis
        local notice = list.data.items[1]
        t.eq(notice.reason, 'Det finns uppgifter som rör Sara Öberg. Kontakta Bo C. (SPAN-02).')
        t.eq(notice.issuedBy, nil)
        t.eq(notice.expiresAt, nil)
        t.eq(notice.subject, 'Sara Öberg')
        t.eq(notice.level, 1)
        t.eq(keys(notice), { 'active', 'citizenid', 'createdAt', 'id', 'kind', 'level', 'reason', 'subject' })
        -- a Hemlig (level 2) BOLO's kontaktnotis carries the fixed notice level, never a level-2 marker
        local Visibility = mods['server.visibility']
        local hemlig = Visibility.shape({ id = 9, kind = 'vehicle', plate = 'HEM11T', subject = 'HEM11T · kuruma',
            reason = 'Hemlig spaning', level = 2, createdAt = '2026-09-29T10:20:00Z', unit = 'span',
            issuedBy = { citizenid = 'FPD10009', displayName = 'Eva L.', callsign = 'LED-01' } }, 'notice', true)
        t.eq(hemlig.level, Visibility.NOTICE_LEVEL)
        t.eq(hemlig.level, 1)
        for k, v in pairs(hemlig) do t.ok(v ~= 2, 'no level-2 value in ' .. k) end
        t.eq(tostring(hemlig.reason):find('Hemlig', 1, true), nil, 'no level name or real reason')
        -- the issuer, the unit colleague and a tier 1 officer see it in full
        t.eq(Service.listBolos(2, {}).data.items[1].reason, 'Hot mot tjänsteman')
        t.eq(Service.listBolos(7, {}).data.items[1].reason, 'Hot mot tjänsteman')

        t.eq(Service.listBolos(1, { active = true, page = 2 }).data, { items = {}, total = 2, page = 2 })
        t.eq(Service.listBolos(4, {}), { ok = false, error = 'unauthorized' })
        t.eq(Service.listBolos(1, { page = 0 }), { ok = false, error = 'validation', reason = 'page' })
    end)
end

tests['08 listBolos (all): history with resolved ones; hidden BOLOs filtered in SQL (total too)'] = function(t)
    withEnv(t, function(_, env, mods)
        local Service, Visibility = mods['server.service'], mods['server.visibility']
        local a = create(t, Service, 1, vehicleInput())
        local b = create(t, Service, 2, { kind = 'person', citizenid = 'FPD10003', reason = 'Hot', level = 1 })
        local c = create(t, Service, 1, { kind = 'person', citizenid = 'FPD10001', reason = 'Saknad' })
        Service.resolveBolo(1, { id = c.id })

        t.eq(Visibility.filterSql(1), '', 'default rules: nothing to filter')
        local all = Service.listBolos(1, { active = false })
        t.eq(all.data.total, 3)
        t.eq({ all.data.items[1].id, all.data.items[2].id, all.data.items[3].id }, { c.id, b.id, a.id })
        t.eq(all.data.items[1].active, false)
        t.eq(all.data.items[1].resolvedBy.displayName, 'Anna B.')
        t.eq(all.data.items[2].issuedBy, nil, 'still a notice for IGV')

        -- A stricter configuration: the fallback rule hides everything the viewer is not entitled to.
        env.setRule(55, 'none')
        local where = Visibility.filterSql(1)
        t.ok(where ~= '' and where ~= '0 = 1', where)
        local hidden = Service.listBolos(1, { active = false })
        t.eq(hidden.data.total, 2, 'the hidden BOLO is not counted')
        t.eq({ hidden.data.items[1].id, hidden.data.items[2].id }, { c.id, a.id })
        t.eq(Service.listBolos(1, { active = true }).data.total, 1)
        -- the issuer (assigned) and Ledning still see it
        t.eq(Service.listBolos(2, { active = false }).data.total, 3)
        t.eq(Service.listBolos(5, { active = false }).data.total, 3)
        -- and it cannot be resolved by someone who cannot see it
        t.eq(Service.resolveBolo(1, { id = b.id }), { ok = false, error = 'not_found' })

        -- masked (configured for tier_gte): no issuer/resolver/note. Only a viewer whose tier covers the level can
        -- get it; above the tier the canView cap turns masked into a kontaktnotis.
        env.setRule(55, 'notice')
        env.setRule(54, 'masked')
        local masked = Service.listBolos(7, { active = true }).data.items[1]
        t.eq(masked.id, b.id)
        t.eq(masked.reason, 'Hot')
        t.eq(masked.issuedBy, nil)
        t.eq(masked.subject, 'Sara Öberg')
        t.eq(Service.resolveBolo(7, { id = b.id }).ok, true, 'masked viewers may resolve')

        -- a viewer who may see nothing at all
        for _, r in ipairs(env.rules) do r.enabled = false end
        t.eq(Visibility.filterSql(1), '0 = 1')
        t.eq(Service.listBolos(1, { active = false }).data, { items = {}, total = 0, page = 1 })
    end)
end

tests['09 getBolosFor: person and vehicle pages, history, canView, grant'] = function(t)
    withEnv(t, function(_, env, mods)
        local Service = mods['server.service']
        local old = create(t, Service, 1, vehicleInput({ reason = 'Gammal' }))
        Service.resolveBolo(1, { id = old.id })
        local cur = create(t, Service, 1, vehicleInput())
        local p = create(t, Service, 2, { kind = 'person', citizenid = 'FPD10003', reason = 'Hot', level = 1 })

        local v = Service.getBolosFor(1, 'vehicle', 'abc 12d')
        t.eq(#v, 2)
        t.eq(v[1].id, cur.id, 'live first')
        t.eq(v[2].id, old.id)
        t.eq(v[2].active, false)
        local person = Service.getBolosFor(1, 'person', 'FPD10003')
        t.eq(#person, 1)
        t.eq(person[1].id, p.id)
        t.eq(person[1].issuedBy, nil, 'kontaktnotis for IGV tier 0')
        t.eq(Service.getBolosFor(2, 'person', 'FPD10003')[1].reason, 'Hot')

        env.setRule(55, 'none')
        t.eq(Service.getBolosFor(1, 'person', 'FPD10003'), {})
        t.eq(Service.getBolosFor(4, 'vehicle', 'ABC12D'), {}, 'no grant')
        t.eq(Service.getBolosFor(1, 'boat', 'ABC12D'), {})
        t.eq(Service.getBolosFor(1, 'person', "' OR 1 = 1 --"), {})
        t.eq(Service.getBolosFor(nil, 'vehicle', 'ABC12D'), {})
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Expiry

tests['10 expiry: lazy deactivation on lookup (UPDATE + bolo.expire audit + push), never a hit'] = function(t)
    withEnv(t, function(_, env, mods)
        local Service, Cache = mods['server.service'], mods['server.cache']
        local bolo = create(t, Service, 1, vehicleInput({ expiresInHours = 1 }))
        t.ok(Service.checkPlate('ABC12D'), 'active before expiry')
        env.clear()
        -- an hour later by both clocks: the database's (expires_at now in the past) and FXServer's (os.time)
        q('UPDATE fredpd_bolos SET expires_at = UTC_TIMESTAMP() - INTERVAL 1 SECOND WHERE id = ?', { bolo.id })
        Cache.clock = function() return os.time() + 3601 end
        t.eq(Service.checkPlate('ABC12D'), nil, 'expired: no hit')
        t.eq(scalar('SELECT active FROM fredpd_bolos WHERE id = ?', { bolo.id }), 0)
        t.eq(#env.audits, 1)
        t.eq(env.audits[1].action, 'bolo.expire')
        t.eq(env.audits[1].src, 0, 'system')
        t.eq(q("SELECT actor_citizenid FROM fredpd_audit WHERE action = 'bolo.expire'")[1].actor_citizenid, nil)
        t.eq(env.pushes, { { topic = 'bolo', payload = { type = 'expired', id = bolo.id } } })
        t.eq(env.named('fredpd:boloChanged')[1].args[2], 'expired')
        t.eq(Service.checkPlate('ABC12D'), nil)
        t.eq(#env.audits, 1, 'expired once')

        -- a plate check on the expired BOLO: no hit, no event, hit = 0
        env.clear()
        local res = Service.plateCheck(1, { plate = 'ABC12D' })
        t.eq(res.data.bolo, nil)
        t.eq(#env.named('fredpd:boloHit'), 0)
        t.eq(#env.alerts, 0)
        t.eq(scalar("SELECT hit FROM fredpd_plate_checks WHERE plate = 'ABC12D'"), 0)
        -- listBolos (active) does not show it, history shows it inactive
        t.eq(Service.listBolos(1, {}).data.total, 0)
        t.eq(Service.listBolos(1, { active = false }).data.items[1].active, false)
        -- and a new BOLO on the plate is allowed
        t.ok(Service.createBolo(1, vehicleInput()).ok)
    end)
end

tests['10b expiry: an FXServer clock ahead of the database never deactivates early, and does not loop'] = function(t)
    withEnv(t, function(_, env, mods)
        local Service, Cache = mods['server.service'], mods['server.cache']
        local bolo = create(t, Service, 1, vehicleInput({ expiresInHours = 1 }))
        env.clear()
        local updates = 0
        local update = MySQL.update
        MySQL.update = setmetatable({ await = update.await }, { __call = function(_, ...)
            updates = updates + 1
            return update(...)
        end })
        -- this host's clock says the hour is over; the database (expires_at in 1 h) does not
        Cache.clock = function() return os.time() + 3601 end
        t.eq(Service.checkPlate('ABC12D'), nil, 'no hit by the host clock')
        t.eq(updates, 1, 'one refused UPDATE')
        t.eq(scalar('SELECT active FROM fredpd_bolos WHERE id = ?', { bolo.id }), 1, 'not deactivated early')
        t.eq(#env.audits, 0, 'no bolo.expire')
        t.eq(env.pushes, {})
        t.eq(#env.named('fredpd:boloChanged'), 0)
        -- a later rebuild meets it again: one more refused UPDATE, no loop
        Service.scheduleRebuild()
        t.eq(updates, 2)
        t.eq(Service.checkPlate('ABC12D'), nil)
        t.eq(#env.audits, 0)
        -- once the database clock agrees, the next rebuild deactivates it (once)
        q('UPDATE fredpd_bolos SET expires_at = UTC_TIMESTAMP() - INTERVAL 1 SECOND WHERE id = ?', { bolo.id })
        Service.scheduleRebuild()
        t.eq(scalar('SELECT active FROM fredpd_bolos WHERE id = ?', { bolo.id }), 0)
        t.eq(#env.audits, 1)
        t.eq(env.audits[1].action, 'bolo.expire')
        t.eq(env.pushes, { { topic = 'bolo', payload = { type = 'expired', id = bolo.id } } })
        MySQL.update = update
    end)
end

tests['11 expiry: rows that ran out while the server was down are deactivated by the start-up rebuild'] = function(t)
    withEnv(t, function(_, env, mods)
        local Service, Cache = mods['server.service'], mods['server.cache']
        q("INSERT INTO fredpd_bolos (kind, plate, reason, level, issued_by, expires_at, active) VALUES "
            .. "('vehicle', 'ABC12D', 'Gammal', 0, 'BOL10001', UTC_TIMESTAMP() - INTERVAL 5 MINUTE, 1), "
            .. "('vehicle', 'QRS45T', 'Aktuell', 0, 'BOL10001', UTC_TIMESTAMP() + INTERVAL 5 MINUTE, 1)")
        Service.scheduleRebuild()
        t.eq(Cache.ready, true)
        t.eq(Service.checkPlate('ABC12D'), nil)
        t.eq(Service.checkPlate('QRS45T').reason, 'Aktuell')
        t.eq(scalar("SELECT active FROM fredpd_bolos WHERE plate = 'ABC12D'"), 0)
        t.eq(#env.audits, 1)
        t.eq(env.audits[1].action, 'bolo.expire')
        -- also through the SQL-side definition: listBolos(active) agrees
        t.eq(Service.listBolos(1, {}).data.total, 1)
    end)
end

tests['12 cache: a rebuild that started before a write is discarded; lookups never wait'] = function(t)
    withEnv(t, function(_, _, mods)
        local Cache = mods['server.cache']
        local e = { id = 1, kind = 'vehicle', plate = 'ABC12D', flagActive = true }
        local gen = Cache.gen
        Cache.put(e)
        t.eq(Cache.replaceAll({}, gen), false, 'overtaken by the put')
        t.eq(Cache.getByPlate('ABC12D'), e)
        t.eq(Cache.replaceAll({}, Cache.gen), true)
        t.eq(Cache.getByPlate('ABC12D'), nil)
        -- not live -> never indexed
        Cache.put({ id = 2, kind = 'person', citizenid = 'X', flagActive = false })
        t.eq(Cache.getByCitizen('X'), nil)

        -- checkPlate does no query (MySQL removed)
        local Service = mods['server.service']
        Cache.put({ id = 3, kind = 'vehicle', plate = 'QRS45T', flagActive = true, subject = 'QRS45T', reason = 'x',
            level = 0, createdAt = '2026-09-29T10:00:00Z' })
        local saved = MySQL
        MySQL = nil
        local ok, bolo = pcall(Service.checkPlate, 'qrs 45t')
        MySQL = saved
        t.ok(ok, tostring(bolo))
        t.eq(bolo.id, 3)
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Plate checks

tests['13 plateCheck (tablet): registry, bolo, plate_checks row, bolo.check audit, fredpd:boloHit'] = function(t)
    withEnv(t, function(_, env, mods)
        local Service = mods['server.service']
        local bolo = create(t, Service, 1, vehicleInput())
        env.clear()
        local res = Service.plateCheck(2, { plate = ' abc 12d ' })
        t.eq(res.ok, true)
        local r = res.data
        t.eq(r.plate, 'ABC12D')
        t.eq(r.model, 'sultan')
        t.eq(r.owner, { citizenid = 'FPD10002', name = 'Erik Lindqvist' })
        t.eq(r.bolo.id, bolo.id)
        t.eq(r.bolo.reason, 'Rån mot värdetransport')
        t.ok(r.checkedAt:match(ISO))
        local row = q('SELECT plate, officer_citizenid, hit, bolo_id, source, '
            .. 'TIMESTAMPDIFF(SECOND, created_at, UTC_TIMESTAMP()) AS age FROM fredpd_plate_checks')[1]
        t.eq({ row.plate, row.officer_citizenid, row.hit, row.bolo_id, row.source },
            { 'ABC12D', 'BOL10002', 1, bolo.id, 'tablet' })
        t.ok(math.abs(row.age) < 60, 'UTC')
        t.eq(env.audits[1].action, 'bolo.check')
        t.eq(env.audits[1].targetType, 'vehicle')
        t.eq(env.audits[1].targetId, 'ABC12D')
        t.eq(env.audits[1].meta, { hit = true, boloId = bolo.id, via = 'tablet' })
        local hits = env.named('fredpd:boloHit')
        t.eq(#hits, 1)
        t.eq(hits[1].args[1].id, bolo.id)
        t.eq(hits[1].args[2], { source = 'plate_check', plate = 'ABC12D', officer = 'BOL10002' })

        -- no hit / unregistered / owner-less
        local clear = Service.plateCheck(2, { plate = 'QRS45T' }).data
        t.eq(clear.bolo, nil)
        t.eq(clear.owner, nil)
        t.eq(clear.model, 'blista')
        local unknown = Service.plateCheck(2, { plate = 'ZZZ99Z' }).data
        t.eq(unknown.model, nil)
        t.eq(unknown.owner, nil)
        t.eq(scalar('SELECT COUNT(*) FROM fredpd_plate_checks WHERE hit = 0'), 2)
        t.eq(#env.named('fredpd:boloHit'), 1)

        t.eq(Service.plateCheck(4, { plate = 'ABC12D' }), { ok = false, error = 'unauthorized' })
        t.eq(Service.plateCheck(3, { plate = 'ABC12D' }), { ok = false, error = 'unauthorized', reason = 'off_duty' })
        t.eq(Service.plateCheck(2, { plate = "A'B" }), { ok = false, error = 'validation', reason = 'plate' })
    end)
end

tests['14 targetCheck: plate read from the entity, grant/duty/1 s/entity/distance checks'] = function(t)
    withEnv(t, function(_, env, mods)
        local Service = mods['server.service']
        MySQL.ready = function() end
        local savedPath = package.path
        package.path = BOLO .. '?.lua;' .. package.path
        local okMain, errMain = pcall(dofile, BOLO .. 'server/main.lua')
        package.path = savedPath
        t.ok(okMain, tostring(errMain))
        Service = package.loaded['server.service']
        local cb = env.callbacks['fredpd:bolo:plateCheck']
        t.ok(cb, 'lib.callback registered')

        local bolo = create(t, Service, 2, vehicleInput())
        env.clear()
        -- The client can only name a network id; a plate string it adds is ignored.
        local r = cb(1, 77, 'QRS45T')
        t.eq(r.plate, 'ABC12D', 'from GetVehicleNumberPlateText of the entity, normalised')
        t.eq(r.bolo.id, bolo.id)
        t.eq(r.owner.name, 'Erik Lindqvist')
        local hit = env.named('fredpd:boloHit')[1]
        t.eq(hit.args[2], { source = 'plate_check', plate = 'ABC12D', officer = 'BOL10001',
            coords = { x = 101.5, y = 201.25, z = 30.0 } })
        t.eq(scalar("SELECT source FROM fredpd_plate_checks WHERE officer_citizenid = 'BOL10001'"), 'target')
        t.eq(#env.alerts, 1, 'the hit raised one alert')

        t.eq(cb(1, 77), { error = 'rate_limited' }, 'second check within 1 s')
        env.now = env.now + 1000
        t.eq(cb(1, 77).plate, 'ABC12D')
        env.now = env.now + 1000
        t.eq(cb(1, 9999), { error = 'not_found' }, 'no such network id')
        env.now = env.now + 1000
        t.eq(cb(1, 78), { error = 'not_found' }, 'a ped, not a vehicle')
        env.now = env.now + 1000
        t.eq(cb(1, 79), { error = 'validation', reason = 'too_far' })
        env.now = env.now + 1000
        t.eq(cb(1, 80), { error = 'not_found', reason = 'no_plate' })
        env.now = env.now + 1000
        t.eq(cb(1, 'x'), { error = 'validation' })
        t.eq(cb(4, 77), { error = 'unauthorized' }, 'civilian')
        t.eq(cb(3, 77), { error = 'unauthorized', reason = 'off_duty' })
        t.eq(cb(0, 77), { error = 'unauthorized' })
        -- player 2 stands 4 m away: within reach
        t.eq(cb(2, 77).plate, 'ABC12D')
        -- the limiter is per player and forgotten on playerDropped
        env.fire('playerDropped', 2)
        t.eq(cb(2, 77).plate, 'ABC12D')
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Hits

tests['15 hit fan-out: one alert per plate per 60 s, radar row, kontaktnotis for level > 0'] = function(t)
    withEnv(t, function(_, env, mods)
        local Service, Fanout = mods['server.service'], mods['server.fanout']
        MySQL.ready = function() end
        local savedPath = package.path
        package.path = BOLO .. '?.lua;' .. package.path
        assert(pcall(dofile, BOLO .. 'server/main.lua'))
        package.path = savedPath
        Service = package.loaded['server.service']
        Fanout = package.loaded['server.fanout']

        local bolo = create(t, Service, 1, vehicleInput())
        env.clear()
        local ctx = { source = 'radar', plate = 'ABC12D', coords = { x = 1635.01, y = 1073.99, z = 80.9 },
            street = 'Vespucci Blvd | Legion Sq', radar = 3 }
        env.fire('fredpd:boloHit', '', Service.checkPlate('ABC12D'), ctx)
        t.eq(#env.alerts, 1)
        t.eq(env.alerts[1], {
            code = 'Efterlyst',
            title = 'Efterlyst fordon: ABC12D',
            description = 'ABC12D är efterlyst: Rån mot värdetransport\nKälla: ANPR-kamera',
            coords = { x = 1635.01, y = 1073.99, z = 80.9 },
            street = 'Vespucci Blvd | Legion Sq',
            priority = 2,
            source = 'bolo',
            meta = { boloId = bolo.id, hit = 'radar', plate = 'ABC12D', radar = 3 },
        })
        local row = q('SELECT officer_citizenid, hit, bolo_id, source FROM fredpd_plate_checks')[1]
        t.eq({ row.officer_citizenid, row.hit, row.bolo_id, row.source }, { nil, 1, bolo.id, 'radar' })

        -- cooldown per plate, whatever the source
        env.now = env.now + 30000
        env.fire('fredpd:boloHit', '', Service.checkPlate('ABC12D'), { source = 'radar', radar = 1 })
        Service.plateCheck(2, { plate = 'ABC12D' })
        t.eq(#env.alerts, 1, 'within 60 s')
        env.now = env.now + 30000
        env.fire('fredpd:boloHit', '', Service.checkPlate('ABC12D'), { source = 'radar', radar = 1 })
        t.eq(#env.alerts, 2, 'after 60 s')
        t.eq(env.alerts[2].coords, nil)
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_plate_checks WHERE source = 'radar'"), 3, 'every radar hit recorded')

        -- untrusted payloads: player source, unknown or inactive id
        env.now = env.now + 60000
        env.fire('fredpd:boloHit', 4, { id = bolo.id }, { source = 'radar' })
        env.fire('fredpd:boloHit', '', { id = 999 }, { source = 'radar' })
        env.fire('fredpd:boloHit', '', 'x', nil)
        t.eq(#env.alerts, 2)

        -- level 1: the alert carries the kontaktnotis, not the reason
        local secret = create(t, Service, 2, { kind = 'person', citizenid = 'FPD10003', reason = 'Hemlig uppgift',
            level = 1 })
        env.fire('fredpd:boloHit', '', Service.checkPerson('FPD10003'), { source = 'garage', street = 'Pillbox\n' })
        local a = env.alerts[#env.alerts]
        t.eq(a.title, 'Efterlyst person: Sara Öberg')
        t.eq(a.description, 'Sara Öberg är efterlyst: Det finns uppgifter som rör Sara Öberg. Kontakta Bo C. (SPAN-02).'
            .. '\nKälla: Garage')
        t.eq(a.street, 'Pillbox')
        t.ok(not a.description:find('Hemlig uppgift', 1, true))
        t.eq(a.meta.boloId, secret.id)

        -- fredpd_dispatch stopped or failing: no error, logged
        env.now = env.now + 60000
        env.resources.fredpd_dispatch = 'stopped'
        env.fire('fredpd:boloHit', '', { id = bolo.id }, { source = 'radar' })
        t.eq(#env.alerts, 3)
        env.resources.fredpd_dispatch = 'started'
        env.alertFails = true
        env.fire('fredpd:boloHit', '', { id = bolo.id }, { source = 'radar' })
        local logged = false
        for _, l in ipairs(env.logs) do if l.msg:find('createAlert', 1, true) then logged = true end end
        t.ok(logged, 'failure logged')
        t.eq(Fanout.HIT_COOLDOWN_MS, 60000)
        -- the failed alert gave the cooldown back: the next hit (same second) retries
        env.alertFails = false
        env.fire('fredpd:boloHit', '', { id = bolo.id }, { source = 'radar' })
        t.eq(#env.alerts, 4, 'retried after the failure')
        -- createAlert refusing (nil, 'validation') also gives it back
        env.now = env.now + 60000
        env.alertRefuses = true
        env.fire('fredpd:boloHit', '', { id = bolo.id }, { source = 'radar' })
        t.eq(#env.alerts, 4)
        env.alertRefuses = false
        env.fire('fredpd:boloHit', '', { id = bolo.id }, { source = 'radar' })
        t.eq(#env.alerts, 5)
        env.fire('fredpd:boloHit', '', { id = bolo.id }, { source = 'radar' })
        t.eq(#env.alerts, 5, 'cooling down again after the success')
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Impound

tests['16 resolveOnImpound: resolves with the Swedish note, audits via impound, never raises'] = function(t)
    withEnv(t, function(_, env, mods)
        local Service = mods['server.service']
        MySQL.ready = function() end
        local savedPath = package.path
        package.path = BOLO .. '?.lua;' .. package.path
        assert(pcall(dofile, BOLO .. 'server/main.lua'))
        package.path = savedPath
        Service = package.loaded['server.service']

        local bolo = create(t, Service, 1, vehicleInput())
        env.clear()
        t.eq(env.exported.resolveOnImpound('abc 12d', 2), true)
        local row = q('SELECT active, resolved_by, resolve_note FROM fredpd_bolos WHERE id = ?', { bolo.id })[1]
        t.eq({ row.active, row.resolved_by, row.resolve_note },
            { 0, 'BOL10002', 'Återkallad automatiskt: fordonet bärgades.' })
        t.eq(env.audits[1].action, 'bolo.resolve')
        t.eq(env.audits[1].meta.via, 'impound')
        t.eq(env.pushes[1].payload, { type = 'resolved', id = bolo.id })

        t.eq(env.exported.resolveOnImpound('ABC12D', 2), false, 'nothing active any more')
        t.eq(env.exported.resolveOnImpound(nil, 2), false)
        t.eq(env.exported.resolveOnImpound({}, 'x'), false)
        t.eq(env.exported.resolveOnImpound('QRS45T'), false)

        -- event form (server only), system actor
        local again = create(t, Service, 1, vehicleInput())
        env.fire('fredpd:bolo:vehicleImpounded', 3, 'ABC12D', 1)
        t.eq(Service.checkPlate('ABC12D').id, again.id, 'player-sourced event ignored')
        env.fire('fredpd:bolo:vehicleImpounded', '', 'ABC12D', nil)
        t.eq(Service.checkPlate('ABC12D'), nil)
        t.eq(scalar('SELECT resolved_by IS NULL FROM fredpd_bolos WHERE id = ?', { again.id }), 1)
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Wiring, pushes, locale, source rules

tests['17 main: exports, callback, server-only events, start-up rebuild'] = function(t)
    withEnv(t, function(_, env)
        local readyCb
        MySQL.ready = function(cb) readyCb = cb end
        local savedPath = package.path
        package.path = BOLO .. '?.lua;' .. package.path
        assert(pcall(dofile, BOLO .. 'server/main.lua'))
        package.path = savedPath
        t.eq(keys(env.exported), { 'checkPerson', 'checkPlate', 'createBolo', 'getBolosFor', 'hasVisibleBolo',
            'listBolos', 'plateCheck', 'resolveBolo', 'resolveOnImpound' })
        t.eq(keys(env.callbacks), { 'fredpd:bolo:plateCheck' })
        t.eq(keys(env.handlers), { 'fredpd:bolo:vehicleImpounded', 'fredpd:boloHit', 'playerDropped' })
        t.eq(env.commands, {}, 'dev command only with fredpd_dev')
        q("INSERT INTO fredpd_bolos (kind, plate, reason, level, issued_by, active) VALUES "
            .. "('vehicle', 'ABC12D', 'Från förra starten', 0, 'BOL10001', 1)")
        t.eq(env.exported.checkPlate('ABC12D'), nil, 'not loaded before oxmysql is ready')
        readyCb()
        t.eq(env.exported.checkPlate('ABC12D').reason, 'Från förra starten')
        -- an export result crosses msgpack: no functions or cycles
        local list = env.exported.listBolos(1, {})
        t.eq(list.data.total, 1)
        t.ok(json.encode(list), 'JSON-encodable')
    end)
end

tests['17b dev command /fredpd_testbolo: fredpd_dev only, admin ACE, createBolo as the caller'] = function(t)
    withEnv(t, function(_, env)
        env.convars.fredpd_dev = 'true'
        MySQL.ready = function() end
        local savedPath = package.path
        package.path = BOLO .. '?.lua;' .. package.path
        assert(pcall(dofile, BOLO .. 'server/main.lua'))
        package.path = savedPath
        local cmd = env.commands.fredpd_testbolo
        t.ok(cmd, 'registered with fredpd_dev')
        t.eq(cmd.opts.restricted, 'group.admin')
        env.inVehicle[1001] = 5001
        cmd.fn(1, {})
        t.eq(env.notifies[1], { target = 1, data = { type = 'success', description = 'Efterlysningen är utfärdad.' } })
        t.eq(env.exported.checkPlate('ABC12D').reason, 'Testefterlysning')
        cmd.fn(1, { plate = 'ABC12D' })
        t.eq(env.notifies[2].data.description, 'Det finns redan en aktiv efterlysning på ABC12D.')
        cmd.fn(1, { plate = 'NOP00X' })
        t.eq(env.notifies[3].data.description, 'NOP00X: fordonet finns inte i registret.')
        cmd.fn(4, { plate = 'QRS45T' })
        t.eq(env.notifies[4].data.description, 'Du har inte behörighet att göra det här.')
        cmd.fn(2, { plate = 'QRS45T', hours = 2 })
        t.eq(env.exported.checkPlate('QRS45T').expiresAt ~= nil, true)
        cmd.fn(0, { plate = 'QRS45T' })
        t.eq(#env.notifies, 5, 'console: nothing')
    end)
end

tests['18 pushes fail softly; fredpd_mdt not started means no push at all'] = function(t)
    withEnv(t, function(_, env, mods)
        local Service = mods['server.service']
        env.pushFails = true
        t.eq(Service.createBolo(1, vehicleInput()).ok, true)
        t.ok(#env.logs >= 1)
        env.pushFails = false
        env.resources.fredpd_mdt = 'stopped'
        env.clear()
        t.eq(Service.createBolo(1, { kind = 'person', citizenid = 'FPD10001', reason = 'xyz' }).ok, true)
        t.eq(env.pushes, {})
        t.eq(#env.named('fredpd:boloChanged'), 1, 'server event still fired')
    end)
end

--- Every literal L('key' ...) / M.L('key' ...) in the given Lua source.
local function localeKeys(src)
    local out = {}
    for key in src:gmatch("[%w_%.]*L%(%s*'([%w_%.]+)'%s*[,%)]") do out[key] = true end
    return out
end

tests['19 locale: every key fredpd_bolo uses exists in sv/en or locales/pending/bolo.json'] = function(t)
    local en = helper.readJson('locales/en.json')
    local sv = helper.readJson('locales/sv.json')
    local pending = helper.readJson('locales/pending/bolo.json')
    local missing = {}
    local p = io.popen("find '" .. BOLO .. "' -name '*.lua'")
    local files = 0
    for file in p:lines() do
        files = files + 1
        for key in pairs(localeKeys(helper.readFile(file))) do
            local inPending = type(pending[key]) == 'table' and pending[key].sv and pending[key].en
            if not ((sv[key] and en[key]) or inPending) then missing[#missing + 1] = file .. ': ' .. key end
        end
    end
    p:close()
    t.ok(files >= 8, 'found the sources')
    table.sort(missing)
    t.eq(missing, {})
    -- keys built at runtime
    for _, key in ipairs({ 'bolo.hit.source.check', 'bolo.hit.source.radar', 'bolo.hit.source.garage',
        'bolo.hit.source.impound', 'unit.igv', 'unit.span', 'visibility.notice.text', 'visibility.notice.textCommand' }) do
        t.ok(sv[key] and en[key], key)
    end
    -- pending keys are new (not already in sv/en)
    for key in pairs(pending) do
        if key:sub(1, 1) ~= '$' then t.eq(sv[key], nil, key .. ' already exists') end
    end
end

tests['20 sources: SPDX header, no session clock, no polling, no client-trusted plate'] = function(t)
    local p = io.popen("find '" .. BOLO .. "' -name '*.lua' -o -name '*.ts' | sort")
    for file in p:lines() do
        local src = helper.readFile(file)
        t.eq(src:find('SPDX-License-Identifier: GPL-3.0-only', 1, true), 4, file)
        local code = src:gsub('%-%-[^\n]*', '')
        t.ok(not code:find('NOW%(%)') and not code:find('CURRENT_TIMESTAMP'), file .. ': session clock')
        t.ok(not code:find('while%s+true') and not code:find('Citizen%.CreateThread'), file .. ': polling')
        t.ok(not code:find('RegisterNetEvent'), file .. ': no net events (callbacks only)')
    end
    p:close()
    local migration = helper.readFile('db/migrations/010_plate_checks.sql')
    t.ok(migration:find('DEFAULT %(UTC_TIMESTAMP%(%)%)'))
    t.ok(not migration:find('?', 1, true), 'no ? (oxmysql would bind it)')
end

tests['22 failures: DB errors give unavailable (never a false "no BOLO"); a stale cache entry is dropped'] = function(t)
    withEnv(t, function(_, env, mods)
        local Service, Cache = mods['server.service'], mods['server.cache']
        local bolo = create(t, Service, 1, vehicleInput())
        -- resolved elsewhere (another writer): the resolve answers not_found and the cache is rebuilt
        q('UPDATE fredpd_bolos SET active = 0 WHERE id = ?', { bolo.id })
        t.ok(Service.checkPlate('ABC12D'), 'still cached')
        t.eq(Service.resolveBolo(1, { id = bolo.id }), { ok = false, error = 'not_found' })
        t.eq(Service.checkPlate('ABC12D'), nil, 'rebuilt')

        -- the active list cannot be loaded: plate checks and lists fail instead of saying "no BOLO"
        Cache.reset()
        local query = MySQL.query
        MySQL.query = setmetatable({ await = function() error('Lost connection to server', 0) end }, {
            __call = function() error('Lost connection to server', 0) end })
        t.eq(Service.plateCheck(1, { plate = 'ABC12D' }), { ok = false, error = 'unavailable' })
        t.eq(Service.listBolos(1, {}), { ok = false, error = 'unavailable' })
        t.eq(Service.getBolosFor(1, 'vehicle', 'ABC12D'), {})
        t.eq(Service.checkPlate('ABC12D'), nil)
        MySQL.query = query
        local logged = false
        for _, l in ipairs(env.logs) do if l.msg:find('Lost connection', 1, true) then logged = true end end
        t.ok(logged, 'logged')
        -- back again
        t.eq(Service.plateCheck(1, { plate = 'ABC12D' }).ok, true)
        t.eq(Cache.ready, true)
    end)
end

tests['22b stale in-flight flags: an await that never resumes blocks a subject / rebuilds for STALE_FLAG_MS only'] =
    function(t)
    withEnv(t, function(_, env, mods)
        local Service, Store = mods['server.service'], mods['server.store']
        -- MySQL.*.await that never resumes (deps-verification §10): the insert yields and is never resumed
        local insert = Store.insert
        Store.insert = function() coroutine.yield() end
        local hung = coroutine.create(function() return Service.createBolo(1, vehicleInput()) end)
        t.eq(coroutine.resume(hung), true)
        t.eq(coroutine.status(hung), 'suspended', 'insert in flight')
        Store.insert = insert
        t.eq(Service.createBolo(1, vehicleInput()), { ok = false, error = 'validation', reason = 'duplicate' })
        env.now = env.now + Service.STALE_FLAG_MS + 1
        t.eq(Service.createBolo(1, vehicleInput()).ok, true, 'released after STALE_FLAG_MS')

        -- the same for the rebuild flag
        local rebuild, calls = Service.rebuild, 0
        Service.rebuild = function()
            calls = calls + 1
            coroutine.yield()
        end
        local stuck = coroutine.create(function() Service.scheduleRebuild() end)
        coroutine.resume(stuck)
        t.eq(calls, 1)
        Service.scheduleRebuild()
        t.eq(calls, 1, 'still held: marked dirty only')
        env.now = env.now + Service.STALE_FLAG_MS + 1
        Service.rebuild = function() calls = calls + 1; return true end
        Service.scheduleRebuild()
        t.eq(calls, 2, 'stale flag released')
        Service.rebuild = rebuild
    end)
end

tests['22c alert code: from the locale only, trimmed and cut to 16; missing key = no alert'] = function(t)
    withEnv(t, function(_, env, mods)
        local Fanout = mods['server.fanout']
        local L = Fanout.L
        t.eq(Fanout.alertCode(), SV['bolo.hit.alertCode'])
        Fanout.L = function(key) return key end
        t.eq(Fanout.alertCode(), nil)
        env.resources.fredpd_dispatch = 'started'
        local entry = { id = 1, kind = 'vehicle', plate = 'ABC12D', subject = 'ABC12D', reason = 'x', level = 0 }
        t.eq(Fanout.hitAlert(entry, { source = 'plate_check' }, 'x'), false)
        t.eq(#env.alerts, 0)
        Fanout.L = function() return '  Efterlyst fordon i Stockholm ' end
        local code = Fanout.alertCode()
        t.eq(code, 'Efterlyst fordon')
        t.ok(utf8.len(code) <= Fanout.HIT_CODE_MAX)
        Fanout.L = L
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Golden files for resources/[fredpd]/fredpd_bolo/test/contract.test.ts

local function canonical(v, indent)
    indent = indent or ''
    local inner = indent .. '  '
    if type(v) ~= 'table' then return json.encode(v) end
    if next(v) == nil then return '[]' end
    if #v > 0 then
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
    print('bolo_server_test: wrote ' .. path)
    return true
end

tests['21 golden: Bolo / list / plate check / push / alert input JSON for contract.test.ts'] = function(t)
    withEnv(t, function(_, env, mods)
        local Service = mods['server.service']
        q('ALTER TABLE fredpd_bolos AUTO_INCREMENT = 1')
        local v = create(t, Service, 1, vehicleInput())
        local createdPush = env.pushes[1]
        t.eq(createdPush and createdPush.topic, 'bolo')
        local p = create(t, Service, 2, { kind = 'person', citizenid = 'FPD10003', reason = 'Hot mot tjänsteman',
            level = 1, expiresInHours = 48 })
        local r = create(t, Service, 1, { kind = 'person', citizenid = 'FPD10001', reason = 'Saknad sedan i går' })
        Service.resolveBolo(1, { id = r.id, note = 'Hittad välbehållen vid Pillbox.' })
        -- deterministic timestamps (UTC); the cache is rebuilt from them
        q("UPDATE fredpd_bolos SET created_at = '2026-09-29 10:00:00' WHERE id = ?", { v.id })
        q("UPDATE fredpd_bolos SET created_at = '2026-09-29 10:10:00', expires_at = '2026-10-01 10:10:00' WHERE id = ?",
            { p.id })
        q("UPDATE fredpd_bolos SET created_at = '2026-09-29 09:00:00', resolved_at = '2026-09-29 10:30:00' WHERE id = ?",
            { r.id })
        mods['server.cache'].clock = function() return 1790000000 end -- 2026-09-21: before every expiry above
        Service.rebuild()

        local full = Service.listBolos(2, { active = true }).data
        writeGolden('list.active', full)
        writeGolden('bolo.full', full.items[2])
        writeGolden('bolo.person', full.items[1])
        local igv = Service.listBolos(1, { active = true }).data
        writeGolden('bolo.notice', igv.items[1])
        writeGolden('list.all', Service.listBolos(1, { active = false }).data)
        writeGolden('bolo.resolved', Service.listBolos(1, { active = false }).data.items[1])
        writeGolden('list.empty', Service.listBolos(1, { active = true, page = 5 }).data)
        env.setRule(54, 'masked')
        writeGolden('bolo.masked', Service.listBolos(7, { active = true }).data.items[1])
        env.setRule(54, 'full')

        local function stable(res)
            t.ok(res.checkedAt:match(ISO))
            res.checkedAt = '2026-09-29T10:05:00Z'
            return res
        end
        env.clear()
        writeGolden('plateCheck.hit', stable(Service.plateCheck(2, { plate = 'ABC12D' }).data))
        local hit = env.named('fredpd:boloHit')[1]
        Service.onHit(hit.args[1], { source = 'plate_check', coords = { x = 101.5, y = 201.25, z = 30.0 } })
        writeGolden('alert-input.hit', env.alerts[1])
        writeGolden('push.created', createdPush.payload)
        writeGolden('plateCheck.clear', stable(Service.plateCheck(2, { plate = 'QRS45T' }).data))
        writeGolden('plateCheck.unregistered', stable(Service.plateCheck(2, { plate = 'ZZZ99Z' }).data))
        q("INSERT INTO fredpd_vehicles_idx (plate, citizenid, model) VALUES ('HEM11T', 'FPD10001', 'kuruma')")
        local secret = create(t, Service, 5, vehicleInput({ plate = 'HEM11T', level = 2 }))
        q("UPDATE fredpd_bolos SET created_at = '2026-09-29 10:20:00' WHERE id = ?", { secret.id })
        Service.rebuild()
        writeGolden('plateCheck.notice', stable(Service.plateCheck(1, { plate = 'HEM11T' }).data))
        t.ok(io.open(GOLDEN .. 'plateCheck.notice.json', 'r'), 'golden files exist')
    end)
end

return tests
