-- SPDX-License-Identifier: GPL-3.0-only
-- qb adapters (docs/modules/adapters-qb.md): garage "qb-garages" (+ patches/qb-garages.10-fredpd-events.patch,
-- applied to the pinned commit and run with a mocked qb-core/oxmysql) and prison "xt-prison" (its export and ox_lib
-- callbacks mocked; the names are checked against the xt-prison checkout when one is present), adapter selection from
-- an integrations config, one warning when the resource is not started.
-- Run: lua5.4 tests/lua/run.lua adapters_qb
local Loader = require('adapters.loader')
local helper = require('helper')
local H = require('qbpolice_harness_test')

local tests = {}

local function recorder()
    local log = { warns = {}, errors = {}, debugs = {} }
    log.warn = function(fmt, ...) log.warns[#log.warns + 1] = fmt:format(...) end
    log.error = function(fmt, ...) log.errors[#log.errors + 1] = fmt:format(...) end
    log.debug = function(fmt, ...) log.debugs[#log.debugs + 1] = fmt:format(...) end
    return log
end

local function fresh(name)
    package.loaded[name] = nil
    return require(name)
end

local GLOBALS = { 'GetResourceState', 'exports', 'AddEventHandler', 'TriggerEvent', 'TriggerClientEvent', 'Player',
    'GetPlayerPed', 'GetEntityCoords', 'source' }

--- Run fn(world) with FiveM globals mocked; restored afterwards.
--- world = { states = {}, players = { [src] = citizenid }, jail = { [src] = minutes }, bolos = { [plate] = bolo },
---           setJail = fn(src, minutes) -> result (default: sets world.jail, true), checkPlateError = msg }
local function with(world, fn)
    local saved = {}
    for _, k in ipairs(GLOBALS) do saved[k] = rawget(_G, k) end
    world.states = world.states or {}
    world.players = world.players or {}
    world.jail = world.jail or {}
    world.handlers, world.fired, world.client, world.setJailCalls = {}, {}, {}, {}
    rawset(_G, 'GetResourceState', function(name) return world.states[name] or 'missing' end)
    rawset(_G, 'AddEventHandler', function(name, fn2)
        world.handlers[name] = world.handlers[name] or {}
        table.insert(world.handlers[name], fn2)
    end)
    rawset(_G, 'TriggerEvent', function(name, ...) world.fired[#world.fired + 1] = { name, ... } end)
    rawset(_G, 'TriggerClientEvent', function(name, target, data)
        world.client[#world.client + 1] = { name, target, data }
    end)
    rawset(_G, 'Player', function(src) return { state = { jailTime = world.jail[src] } } end)
    rawset(_G, 'GetPlayerPed', function(src) return world.players[src] and (1000 + src) or 0 end)
    rawset(_G, 'GetEntityCoords', function(ped) return { x = ped, y = 2, z = 3 } end)
    local resources = {
        fredpd_bolo = {
            checkPlate = function(_, plate)
                if world.checkPlateError then error(world.checkPlateError) end
                return (world.bolos or {})[plate]
            end,
        },
        ['xt-prison'] = {
            SetJailTime = function(_, src, minutes)
                world.setJailCalls[#world.setJailCalls + 1] = { src, minutes }
                if world.setJail then return world.setJail(src, minutes) end
                world.jail[src] = minutes
                return true
            end,
        },
    }
    rawset(_G, 'exports', setmetatable({}, { __index = function(_, k) return resources[k] end }))
    world.bridge = {
        getPlayer = function(src)
            local cid = world.players[src]
            return cid and { source = src, citizenid = cid } or nil
        end,
        getPlayerByCitizenId = function(cid)
            for src, c in pairs(world.players) do if c == cid then return src end end
            return nil
        end,
    }
    world.callbacks = {}
    world.lib = { callback = function(event, target, cb, ...)
        world.callbacks[#world.callbacks + 1] = { event = event, target = target, cb = cb, args = { ... } }
    end }
    local ok, err = pcall(fn, world)
    for _, k in ipairs(GLOBALS) do rawset(_G, k, saved[k]) end
    if not ok then error(err, 0) end
end

--- Fire a registered server event as the given source ('' = server).
local function emit(world, name, src, ...)
    for _, h in ipairs(world.handlers[name] or {}) do
        rawset(_G, 'source', src)
        h(...)
    end
    rawset(_G, 'source', nil)
end

local function garage(world)
    local a = fresh('adapters.garage.qb_garages')
    a.impl.reset()
    a.impl.bridge = world.bridge
    return a
end

local function prison(world)
    local a = fresh('adapters.prison.xt_prison')
    a.impl.bridge = world.bridge
    a.impl.lib = world.lib
    return a
end

local function boloHits(world)
    local out = {}
    for _, f in ipairs(world.fired) do if f[1] == 'fredpd:boloHit' then out[#out + 1] = f end end
    return out
end

---------------------------------------------------------------------------------------------------------------
-- Selection

tests['config selects qb-garages and xt-prison; not started -> one warning each, calls are no-ops'] = function(t)
    with({}, function(w)
        local log = recorder()
        local active = Loader.load({ housing = 'none', garage = 'qb-garages', prison = 'xt-prison' },
            { log = log, require = fresh, defer = function() end })
        t.eq(active.garage.name, 'qb-garages')
        t.eq(active.prison.name, 'xt-prison')
        t.eq(active.garage.stub, false)
        t.eq(active.prison.stub, false)
        t.eq(#log.warns, 2, 'one warning per missing resource: ' .. helper.dump(log.warns))
        t.ok(log.warns[1]:find('qb-garages', 1, true) and log.warns[2]:find('xt-prison', 1, true))
        t.eq(active.garage.onParked(function() end), false)
        t.eq(active.garage.onTakenOut(function() end), false)
        t.eq(active.prison.jail(1, 10, {}), false)
        t.eq(#log.warns, 2, 'calls while missing add no warning')
        t.eq(#w.setJailCalls, 0)
        t.eq(#w.callbacks, 0)
    end)
end

tests['the shipped config names only adapters that exist'] = function(t)
    local cfg = helper.readJson('config/integrations.json')
    for _, kind in ipairs({ 'garage', 'prison' }) do
        local ok = pcall(require, Loader.moduleName(kind, cfg[kind]))
        t.ok(ok, kind .. ' adapter ' .. tostring(cfg[kind]) .. ' exists')
    end
end

---------------------------------------------------------------------------------------------------------------
-- Garage adapter

tests['qb-garages: selected -> handlers installed; park/take-out reach listeners with plate, src, garage'] = function(t)
    with({ states = { ['qb-garages'] = 'started' }, players = { [7] = 'CID7' } }, function(w)
        local a = garage(w)
        a.init(recorder())
        t.ok(w.handlers['fredpd:garage:parked'] and w.handlers['fredpd:garage:takenOut'], 'handlers on init')
        a.init(recorder())
        t.eq(#w.handlers['fredpd:garage:parked'], 1, 'installed once')
        local parked, taken = {}, {}
        t.eq(a.onParked(function(...) parked[#parked + 1] = { ... } end), true)
        t.eq(a.onTakenOut(function(...) taken[#taken + 1] = { ... } end), true)
        emit(w, 'fredpd:garage:parked', '', 'CID7', ' ab 12cd ', 'pillboxgarage', 7)
        emit(w, 'fredpd:garage:takenOut', '', 'CID7', 'AB12CD', nil, 7)
        t.eq(parked, { { 'AB12CD', 7, 'pillboxgarage' } })
        t.eq(taken, { { 'AB12CD', 7 } })
    end)
end

tests['qb-garages: a player source, a bad plate or a wrong src never reaches listeners as given'] = function(t)
    with({ states = { ['qb-garages'] = 'started' }, players = { [7] = 'CID7', [8] = 'CID8' } }, function(w)
        local a = garage(w)
        a.init(recorder())
        local got = {}
        a.onParked(function(...) got[#got + 1] = { ... } end)
        emit(w, 'fredpd:garage:parked', 7, 'CID7', 'AB12CD', 'x', 7)          -- from a client
        emit(w, 'fredpd:garage:parked', '', 'CID7', 'AB!12', 'x', 7)          -- invalid plate
        emit(w, 'fredpd:garage:parked', '', 'CID7', ('A'):rep(17), 'x', 7)    -- too long
        emit(w, 'fredpd:garage:parked', '', 'CID7', { 'AB' }, 'x', 7)         -- not a string
        t.eq(#got, 0)
        -- src 8 is not CID7: the actor is looked up by citizenid; a control character drops the garage
        emit(w, 'fredpd:garage:parked', '', 'CID7', 'AB12CD', 'bad\ngarage', 8)
        t.eq(got, { { 'AB12CD', 7 } })
        -- offline owner: src nil
        emit(w, 'fredpd:garage:parked', '', 'CID9', 'XY1', 'a', 9)
        t.eq({ got[2][1], got[2][2], got[2][3] }, { 'XY1', nil, 'a' })
    end)
end

tests['qb-garages: a wanted plate fires fredpd:boloHit with source garage; checkPlate errors are caught'] = function(t)
    local bolo = { id = 5, plate = 'AB12CD' }
    with({ states = { ['qb-garages'] = 'started', fredpd_bolo = 'started' }, players = { [7] = 'CID7' },
        bolos = { AB12CD = bolo } }, function(w)
        local a = garage(w)
        local log = recorder()
        a.init(log)
        emit(w, 'fredpd:garage:parked', '', 'CID7', 'ab12cd', 'motelgarage', 7)
        emit(w, 'fredpd:garage:takenOut', '', 'CID7', 'ZZZ999', 'motelgarage', 7)
        local hits = boloHits(w)
        t.eq(#hits, 1, 'only the wanted plate')
        t.eq(hits[1][2], bolo)
        t.eq(hits[1][3], { source = 'garage', plate = 'AB12CD', garage = 'motelgarage', action = 'parked',
            coords = { x = 1007, y = 2, z = 3 } })
        w.checkPlateError = 'boom'
        emit(w, 'fredpd:garage:takenOut', '', 'CID7', 'AB12CD', nil, 7)
        t.eq(#boloHits(w), 1)
        t.eq(#log.warns, 1)
        t.ok(log.warns[1]:find('checkPlate failed', 1, true))
        -- fredpd_bolo stopped: no relay, no error
        w.checkPlateError = nil
        w.states.fredpd_bolo = 'stopped'
        emit(w, 'fredpd:garage:takenOut', '', 'CID7', 'AB12CD', nil, 7)
        t.eq(#boloHits(w), 1)
    end)
end

tests['qb-garages: a failing listener is logged and does not stop the others or the relay'] = function(t)
    with({ states = { ['qb-garages'] = 'started', fredpd_bolo = 'started' }, players = { [3] = 'C3' },
        bolos = { P1 = { id = 1 } } }, function(w)
        local a = garage(w)
        local log = recorder()
        a.init(log)
        local seen = 0
        a.onParked(function() error('listener broke') end)
        a.onParked(function() seen = seen + 1 end)
        t.eq(a.onParked('not a function'), false)
        emit(w, 'fredpd:garage:parked', '', 'C3', 'P1', nil, 3)
        t.eq(seen, 1)
        t.eq(#log.errors, 1)
        t.eq(#boloHits(w), 1)
    end)
end

tests['qb-garages: a callable table (cross-resource funcref) is accepted, the same cb only once'] = function(t)
    with({ states = { ['qb-garages'] = 'started' }, players = { [3] = 'C3' } }, function(w)
        local a = garage(w)
        a.init(recorder())
        local n = 0
        local ref = setmetatable({}, { __call = function() n = n + 1 end })
        t.eq(a.onTakenOut(ref), true)
        t.eq(a.onTakenOut(ref), true)
        emit(w, 'fredpd:garage:takenOut', '', 'C3', 'P1', nil, 3)
        t.eq(n, 1)
    end)
end

---------------------------------------------------------------------------------------------------------------
-- qb-garages patch (pinned commit + patches/qb-garages.*.patch, run with mocks)

--- Load the patched server.lua; returns env with callbacks and the fired events.
local function loadGarages(tree, rows)
    local env = { callbacks = {}, fired = {}, updates = {} }
    local players = { [7] = { PlayerData = { citizenid = 'CID7', license = 'l7' } } }
    local QBCore = { Functions = { CreateCallback = function(name, fn) env.callbacks[name] = fn end } }
    local exportsMock = setmetatable({
        ['qb-core'] = {
            GetCoreObject = function() return QBCore end,
            GetShared = function() return {} end,
            GetPlayer = function(_, src) return players[src] end,
        },
    }, { __call = function() end })
    local G = setmetatable({
        exports = exportsMock,
        Config = { Garages = { pillboxgarage = { label = 'Pillbox' } }, AutoRespawn = false },
        AddEventHandler = function() end,
        RegisterNetEvent = function() end,
        TriggerEvent = function(name, ...) env.fired[#env.fired + 1] = { name, ... } end,
        TriggerClientEvent = function() end,
        GetHashKey = function() return 123 end,
        CreateVehicleServerSetter = function() return 55 end,
        NetworkGetNetworkIdFromEntity = function() return 99 end,
        SetVehicleNumberPlateText = function() end,
        DoesEntityExist = function() return false end,
        json = json,
        MySQL = {
            single = { await = function(_, p) return rows.single(p) end },
            scalar = { await = function(_, p) return rows.scalar(p) end },
            update = function(sql, p) env.updates[#env.updates + 1] = { sql, p } end,
        },
    }, { __index = _G })
    local chunk = assert(load(H.decfx(tree.files['server.lua']), '@qb-garages/server.lua', 't', G))
    chunk()
    return env
end

tests['qb-garages patch: applies to the pin, reverse-applies, compiles; events at the server points'] = function(t)
    local tree = H.tree('qb-garages')
    if not tree.ok then
        if tree.applyError or os.getenv('FREDPD_REQUIRE_UPSTREAM') == '1' then error(tostring(tree.reason), 0) end
        print('SKIP qb-garages patch test: ' .. tostring(tree.reason))
        return
    end
    t.eq(tree.applied, { 'qb-garages.10-fredpd-events.patch' })
    t.eq(tree.reverse['qb-garages.10-fredpd-events.patch'], true)
    if tree.luacBin then t.eq(tree.luac['server.lua'], true) end

    local owned = { AB12CD = { citizenid = 'CID7', vehicle = 'sultan', mods = '{}', garage = 'pillboxgarage' } }
    local env = loadGarages(tree, {
        single = function(p) local r = owned[p[1]]; return r and r.citizenid == p[2] and r or nil end,
        scalar = function(p) return owned[p[1]] and owned[p[1]].citizenid or nil end,
    })
    local answers = {}
    local cb = function(...) answers[#answers + 1] = { ... } end
    -- park: owned + configured garage
    env.callbacks['qb-garages:server:canDeposit'](7, cb, 'AB12CD', 'public', 'pillboxgarage', 1)
    t.eq(env.fired, { { 'fredpd:garage:parked', 'CID7', 'AB12CD', 'pillboxgarage', 7 } })
    -- park: client-chosen unknown garage -> garage nil
    env.callbacks['qb-garages:server:canDeposit'](7, cb, 'AB12CD', 'public', 'nowhere', 1)
    t.eq(env.fired[2], { 'fredpd:garage:parked', 'CID7', 'AB12CD', nil, 7 })
    -- park: not owned / wrong state -> no event
    env.callbacks['qb-garages:server:canDeposit'](7, cb, 'OTHER1', 'public', 'pillboxgarage', 1)
    env.callbacks['qb-garages:server:canDeposit'](7, cb, 'AB12CD', 'public', 'pillboxgarage', 0)
    t.eq(#env.fired, 2)
    t.eq(answers, { { true }, { true }, { false }, { false } })
    -- take out: owned -> event with the stored garage; not owned -> nothing
    env.callbacks['qb-garages:server:spawnvehicle'](7, cb, 'AB12CD', 'sultan', { x = 1, y = 2, z = 3, w = 0 })
    t.eq(env.fired[3], { 'fredpd:garage:takenOut', 'CID7', 'AB12CD', 'pillboxgarage', 7 })
    env.callbacks['qb-garages:server:spawnvehicle'](7, cb, 'OTHER1', 'sultan', { x = 1, y = 2, z = 3, w = 0 })
    t.eq(#env.fired, 3)
end

---------------------------------------------------------------------------------------------------------------
-- Prison adapter

tests['xt-prison: not jailed -> enterJail client callback, sent without waiting'] = function(t)
    with({ states = { ['xt-prison'] = 'started' }, players = { [4] = 'C4' } }, function(w)
        local a = prison(w)
        local log = recorder()
        a.init(log)
        t.eq(a.jail(4, 30, { { code = 'BrB 3:1', label = 'Stöld' } }), true)
        t.eq(#w.callbacks, 1)
        t.eq({ w.callbacks[1].event, w.callbacks[1].target, w.callbacks[1].args }, { 'xt-prison:client:enterJail', 4, { 30 } })
        t.eq(#w.setJailCalls, 0, 'xt-prison sets the time itself when the client enters')
        w.callbacks[1].cb(true)
        t.eq(#log.warns, 0)
        w.callbacks[1].cb(false)
        t.eq(#log.warns, 1, 'an unconfirmed entry is logged')
        t.eq(a.jail('4', 5.0, nil), true, 'numeric strings / integral floats are accepted')
    end)
end

tests['xt-prison: already jailed -> SetJailTime + notice; 0 releases; 0 when free does nothing'] = function(t)
    with({ states = { ['xt-prison'] = 'started' }, players = { [4] = 'C4', [5] = 'C5' }, jail = { [4] = 12 } },
        function(w)
            local a = prison(w)
            a.init(recorder())
            t.eq(a.jail(4, 40, {}), true)
            t.eq(w.setJailCalls, { { 4, 40 } })
            t.eq(#w.callbacks, 0)
            t.eq(w.client[1][1], 'ox_lib:notify')
            t.eq(w.client[1][2], 4)
            t.eq(a.jail(4, 0, {}), true)
            t.eq(w.setJailCalls[2], { 4, 0 })
            t.eq({ w.callbacks[1].event, w.callbacks[1].target, w.callbacks[1].args },
                { 'xt-prison:client:exitJail', 4, { true } })
            t.eq(a.jail(5, 0, {}), true)
            t.eq(#w.setJailCalls, 2)
            t.eq(#w.callbacks, 1)
        end)
end

tests['xt-prison: invalid input, offline player and a refused SetJailTime are false'] = function(t)
    with({ states = { ['xt-prison'] = 'started' }, players = { [4] = 'C4' }, jail = { [4] = 3 } }, function(w)
        local a = prison(w)
        local log = recorder()
        a.init(log)
        for _, args in ipairs({ { 4, -1 }, { 4, 2.5 }, { 4, 'x' }, { 4, 100000 }, { 0, 5 }, { nil, 5 }, { 9, 5 } }) do
            t.eq(a.jail(args[1], args[2], {}), false, helper.dump(args))
        end
        t.eq(#w.setJailCalls, 0)
        w.setJail = function() return false end
        t.eq(a.jail(4, 10, {}), false)
        t.eq(a.jail(4, 0, {}), false)
        t.eq(#w.callbacks, 0, 'no release callback when the time was not cleared')
        w.setJail = function() error('xt-prison broke') end
        t.eq(a.jail(4, 10, {}), false)
        t.eq(#log.errors, 1, 'the base logs the raised error')
    end)
end

tests['xt-prison: stopped after start -> no-op with one warning'] = function(t)
    with({ states = { ['xt-prison'] = 'started' }, players = { [4] = 'C4' } }, function(w)
        local a = prison(w)
        local log = recorder()
        a.init(log)
        w.states['xt-prison'] = 'stopped'
        t.eq(a.jail(4, 10, {}), false)
        t.eq(a.jail(4, 10, {}), false)
        t.eq(#log.warns, 1)
        t.eq(#w.callbacks, 0)
    end)
end

tests['xt-prison: the names used exist in the xt-prison checkout (qb bridge included)'] = function(t)
    -- xt-prison is REFERENCE in deps.lock.json (no licence, not fetched): point FREDPD_XT_PRISON at a checkout of
    -- xT-Development/xt-prison@85fd705 to run this check.
    local root = os.getenv('FREDPD_XT_PRISON') or './resources/[upstream]/xt-prison'
    local f = io.open(root .. '/bridge/server/qb.lua', 'r')
    if not f then
        print('SKIP xt-prison name check: no checkout at ' .. root .. ' (set FREDPD_XT_PRISON)')
        return
    end
    local qb = f:read('a')
    f:close()
    local function read(p) local h = assert(io.open(root .. '/' .. p, 'r')); local s = h:read('a'); h:close(); return s end
    t.ok(qb:find("exports('SetJailTime', setJailTime)", 1, true), 'qb bridge exports SetJailTime')
    t.ok(qb:find("GetResourceState('qb-core') ~= 'started'", 1, true), 'qb bridge is gated on qb-core')
    t.ok(read('bridge/server/qbx.lua'):find("exports('SetJailTime'", 1, true), 'qbx bridge exports SetJailTime')
    local cl = read('client/cl_main.lua')
    t.ok(cl:find("lib.callback.register('xt-prison:client:enterJail'", 1, true))
    t.ok(cl:find("lib.callback.register('xt-prison:client:exitJail'", 1, true))
end

tests['pending locale keys exist in sv and en'] = function(t)
    local pending = helper.readJson('locales/pending/adapters-qb.json')
    for _, key in ipairs({ 'prison.notify.released', 'prison.notify.timeChanged' }) do
        local merged = helper.readJson('locales/sv.json')[key]
        local entry = pending[key]
        t.ok(merged or (entry and entry.sv and entry.en), key)
    end
end

return tests
