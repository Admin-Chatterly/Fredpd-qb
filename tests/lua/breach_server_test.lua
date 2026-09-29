-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_breach server (task 6.1, IMPLEMENTATION.md §5.6, docs/contracts.md §C16) with FiveM mocked and
-- fredpd_core's REAL server bridge (docs/contracts.md §C17) over the inventory and doorlock mocks of the selected
-- stack (FREDPD_STACK, tests/lua/dispatch_stack_test.lua: qb-inventory + patched qb-doorlock by default,
-- ox_inventory + ox_doorlock with FREDPD_STACK=ox): fredpd_core grants/duty/audit/citizenid mocked, count / getDoor /
-- setLocked / bridgeInfo / hasFeature through the bridge, the item definition files (LoadResourceFile), evidences
-- (syncEvidence), ped positions, the game timer, lib.callback and exports. Loads server/main.lua so the callbacks
-- and the export are the ones the resource registers.
-- Covers: breach start/finish checks (grant, duty, item, door exists/locked, distance, rate limit, cooldown), token
-- rules (expiry, reuse, another player's token, too early, replaced by a new start, dropped player), success →
-- setLocked(id, false, src) + audit breach.door; qb-doorlock string door ids; sceneEvidence validation (kind, coords,
-- bounds, suspect), per-location cooldown, evidences call arguments and spacing, unsupported types skipped, audit
-- breach.scene (evidences exists only on the ox stack: those tests run on ox; on qb the export answers unavailable
-- with one warning). breach_bridge_test.lua runs a smoke matrix over both stacks.
-- Run: lua5.4 tests/lua/run.lua breach_server
local Stack = require('dispatch_stack_test')

local tests = {}

local BREACH = './resources/[fredpd]/fredpd_breach/'
local MODULES = { 'config', 'config.scene_evidence', 'server.breach', 'server.scene', 'server.main' }
local GLOBALS = { 'exports', 'lib', 'GetGameTimer', 'GetEntityCoords', 'GetPlayerPed', 'DoesPlayerExist',
    'GetResourceState', 'AddEventHandler', 'vec3', 'vector3', 'GetInvokingResource', 'source', 'LoadResourceFile',
    'TriggerClientEvent' }

local function vec(x, y, z) return { x = x, y = y, z = z } end

local DOOR_POS = vec(100.0, 200.0, 30.0)

--- Fresh world + fresh resource. Returns env with the registered callbacks/export and recorders.
local function setup(opts)
    opts = opts or {}
    local env = {
        now = 100000,
        players = {
            [1] = { cid = 'POL00001', grant = true, duty = true, ram = 1, pos = vec(101.0, 200.0, 30.0) },
            [2] = { cid = 'POL00002', grant = true, duty = true, ram = 1, pos = vec(100.5, 200.5, 30.0) },
            [3] = { cid = 'POL00003', grant = false, duty = true, ram = 1, pos = vec(100.0, 201.0, 30.0) },
            [4] = { cid = 'POL00004', grant = true, duty = false, ram = 1, pos = vec(100.0, 201.0, 30.0) },
            [5] = { cid = 'POL00005', grant = true, duty = true, ram = 0, pos = vec(100.0, 201.0, 30.0) },
            [6] = { cid = 'POL00006', grant = true, duty = true, ram = 1, pos = vec(110.0, 200.0, 30.0) },
            [7] = { cid = 'CIV00007', grant = false, duty = false, ram = 0, pos = vec(0.0, 0.0, 0.0) },
        },
        doors = {
            [12] = { id = 12, name = 'house_12_front', state = 1, coords = DOOR_POS },
            [13] = { id = 13, name = 'open_door', state = 0, coords = DOOR_POS },
        },
        itemKnown = opts.itemKnown ~= false,
        evidencesState = opts.evidencesState or 'started',
        callbacks = {}, handlers = {}, exported = {}, audits = {}, setStates = {}, setSources = {}, sync = {}, logs = {},
        clientEvents = {},
        setStateResult = true,
    }
    env.saved = {}
    for _, g in ipairs(GLOBALS) do env.saved[g] = rawget(_G, g) end

    env.stack = opts.stack or Stack.current()
    local impl = Stack.IMPL[env.stack]
    env.impl = impl
    local Bridge -- fredpd_core's real server bridge, loaded below
    local core = {
        hasGrant = function(_, src, t, k)
            local p = env.players[src]
            return p ~= nil and p.grant == true and t == 'tool' and k == 'ram'
        end,
        isOnDuty = function(_, src) local p = env.players[src]; return p ~= nil and p.duty == true end,
        audit = function(_, src, action, targetType, targetId, meta)
            env.audits[#env.audits + 1] = { src = src, action = action, targetType = targetType,
                targetId = targetId, meta = meta }
        end,
        getCitizenId = function(_, src) local p = env.players[src]; return p and p.cid end,
    }
    for k, fn in pairs(Stack.coreExports(setmetatable({}, { __index = function(_, m) return Bridge[m] end }))) do
        core[k] = fn
    end
    local function count(_, src, name)
        local p = env.players[src]
        if name ~= 'pd_ram' or not p or not env.itemKnown then return 0 end
        return p.ram
    end
    local function record(id, state, src)
        env.setStates[#env.setStates + 1] = { id = id, state = state }
        env.setSources[#env.setSources + 1] = src
        if env.setStateResult and env.doors[id] then env.doors[id].state = state end
        return env.setStateResult
    end
    local resources = {
        fredpd_core = core,
        evidences = {
            syncEvidence = function(_, evidenceType, owner, fun, coords, meta)
                env.sync[#env.sync + 1] = { type = evidenceType, owner = owner, fun = fun, coords = coords, meta = meta }
            end,
        },
    }
    if env.stack == 'qb' then
        -- qb-inventory server/functions.lua:357-376; patched qb-doorlock (patches/qb-doorlock.10-fredpd-bridge.patch).
        resources[impl.inventory] = { GetItemCount = count }
        resources[impl.doorlock] = {
            getDoor = function(_, id)
                local d = env.doors[id]
                if not d then return nil end
                return { id = d.id, name = d.name, locked = d.state == 1, coords = d.coords }
            end,
            setDoorState = function(_, id, locked, src) return record(id, locked and 1 or 0, src) end,
        }
    else
        -- ox_inventory modules/inventory/server.lua:2322-2341; ox_doorlock server/main.lua:53-68, 275-314.
        resources[impl.inventory] = { GetItemCount = count }
        resources[impl.doorlock] = {
            getDoor = function(_, id)
                local d = env.doors[id]
                if not d then return false end
                return { id = d.id, name = d.name, state = d.state, coords = d.coords }
            end,
            setDoorState = function(_, id, state) return record(id, state, nil) end,
        }
    end
    -- Item definition files (qb-core shared/items.lua, ox_inventory data/items.lua) as the FredPD patches leave them.
    local ITEM_FILES = {
        qb = { res = impl.framework, path = 'shared/items.lua',
            known = "    pd_ram = { name = 'pd_ram', label = 'Murbräcka', weight = 9000 },\n",
            other = "    weapon_pistol = { name = 'weapon_pistol', label = 'Pistol' },\n" },
        ox = { res = impl.inventory, path = 'data/items.lua',
            known = "\t['pd_ram'] = {\n\t\tlabel = 'Murbräcka',\n\t},\n",
            other = "\t['burger'] = {\n\t\tlabel = 'Burger',\n\t},\n" },
    }
    env.resources = resources
    _G.LoadResourceFile = function(res, path)
        local f = ITEM_FILES[env.stack]
        if res == f.res and path == f.path then return 'return {\n' .. (env.itemKnown and f.known or '') .. f.other .. '}' end
        return nil
    end
    _G.TriggerClientEvent = function(name, target, ...)
        env.clientEvents[#env.clientEvents + 1] = { name = name, target = target, args = { ... } }
    end
    _G.exports = setmetatable({}, {
        __index = function(_, name) return resources[name] end,
        __call = function(_, name, fn) env.exported[name] = fn end,
    })
    _G.lib = {
        callback = { register = function(name, fn) env.callbacks[name] = fn end },
        print = {
            warn = function(msg) env.logs[#env.logs + 1] = 'warn: ' .. msg end,
            error = function(msg) env.logs[#env.logs + 1] = 'error: ' .. msg end,
            info = function(msg) env.logs[#env.logs + 1] = 'info: ' .. msg end,
        },
    }
    _G.GetGameTimer = function() return env.now end
    _G.GetPlayerPed = function(src) return src + 1000 end
    _G.GetEntityCoords = function(ped)
        local p = env.players[ped - 1000]
        return p and p.pos or vec(0, 0, 0)
    end
    _G.DoesPlayerExist = function(src) return env.players[tonumber(src)] ~= nil end
    env.states = { evidences = env.evidencesState } -- live: a test may stop a resource
    _G.GetResourceState = function(name) return env.states[name] or 'started' end
    _G.AddEventHandler = function(name, fn) env.handlers[name] = fn end
    Bridge, env.bridgeLogs = Stack.load(env.stack, { states = env.states })
    _G.vec3 = vec
    _G.vector3 = vec
    _G.GetInvokingResource = function() return 'crime_script' end

    for _, name in ipairs(MODULES) do package.loaded[name] = nil end
    local savedPath = package.path
    package.path = BREACH .. '?.lua;' .. package.path
    local ok, err = pcall(require, 'server.main')
    env.breach = package.loaded['server.breach']
    env.scene = package.loaded['server.scene']
    package.path = savedPath
    for _, name in ipairs(MODULES) do package.loaded[name] = nil end
    if not ok then error(err, 0) end
    return env
end

local function teardown(env)
    for _, g in ipairs(GLOBALS) do rawset(_G, g, env.saved[g]) end
    Stack.reset()
end

--- Run fn(t, env) in a fresh environment; globals are restored even when it fails.
local function case(opts, fn)
    return function(t)
        local env = setup(opts)
        local ok, err = pcall(fn, t, env)
        teardown(env)
        if not ok then error(err, 0) end
    end
end

-- evidences (and so scene evidence) exists only on the ox stack (docs/contracts.md §C17 "Degradation").
local OX = { stack = 'ox' }

local function start(env, src, doorId) return env.callbacks['fredpd:breach:start'](src, doorId) end
local function finish(env, src, token) return env.callbacks['fredpd:breach:finish'](src, token) end

---------------------------------------------------------------------------------------------------------------
-- Wiring

tests['main registers both callbacks, the sceneEvidence export and playerDropped'] = case(nil, function(t, env)
    t.ok(type(env.callbacks['fredpd:breach:start']) == 'function')
    t.ok(type(env.callbacks['fredpd:breach:finish']) == 'function')
    t.ok(type(env.exported.sceneEvidence) == 'function')
    t.ok(type(env.handlers.playerDropped) == 'function')
end)

tests['a missing pd_ram item logs exactly one warning and nobody can breach'] = case({ itemKnown = false },
    function(t, env)
        local warns = 0
        for _, l in ipairs(env.logs) do if l:find('pd_ram', 1, true) then warns = warns + 1 end end
        t.eq(warns, 1, table.concat(env.logs, ' | '))
        local r = start(env, 1, 12)
        t.eq(r, { ok = false, error = 'validation', reason = 'no_item' })
        env.now = env.now + 5000
        start(env, 1, 12)
        warns = 0
        for _, l in ipairs(env.logs) do if l:find('pd_ram', 1, true) then warns = warns + 1 end end
        t.eq(warns, 1, 'still one warning')
    end)

---------------------------------------------------------------------------------------------------------------
-- Breach: success

tests['success: start → 4 s → finish unlocks through the bridge setLocked and audits breach.door'] = case(nil,
    function(t, env)
        local r = start(env, 1, 12)
        t.ok(r.ok, 'start ok')
        t.eq(r.data.doorId, 12)
        t.eq(r.data.durationMs, 4000)
        t.ok(type(r.data.token) == 'string' and #r.data.token == 32 and r.data.token:match('^%x+$'))
        t.eq(#env.setStates, 0, 'nothing unlocked at start')
        env.now = env.now + 4000
        local f = finish(env, 1, r.data.token)
        t.eq(f, { ok = true, data = { doorId = 12, evidence = {} } })
        t.eq(env.setStates, { { id = 12, state = 0 } })
        if env.stack == 'qb' then t.eq(env.setSources, { 1 }, 'qb-doorlock gets the officer (door animation)') end
        t.eq(#env.audits, 1)
        t.eq(env.audits[1], { src = 1, action = 'breach.door', targetType = 'door', targetId = 12,
            meta = { doorId = 12, name = 'house_12_front', coords = { x = 100.0, y = 200.0, z = 30.0 } } })
    end)

tests['door id from the client may be a numeric string; the server reads the door itself'] = case(nil,
    function(t, env)
        local r = start(env, 1, '12')
        t.ok(r.ok)
        t.eq(r.data.doorId, 12)
    end)

tests['qb-doorlock string door ids (Config.DoorList keys) breach, deny and audit like numbers'] = case(nil,
    function(t, env)
        env.doors['mrpd-cells-1'] = { id = 'mrpd-cells-1', name = 'Cell 1', state = 1, coords = DOOR_POS }
        local r = start(env, 1, 'mrpd-cells-1')
        t.ok(r.ok, 'start')
        t.eq(r.data.doorId, 'mrpd-cells-1')
        env.now = env.now + 4000
        t.eq(finish(env, 1, r.data.token).ok, true)
        t.eq(env.setStates, { { id = 'mrpd-cells-1', state = 0 } })
        t.eq(env.audits[1].targetId, 'mrpd-cells-1')
        env.doors['mrpd-cells-1'].state = 1
        env.breach.configure({ denyDoors = { 'mrpd-cells-1' } })
        env.now = env.now + 20000
        t.eq(start(env, 2, 'mrpd-cells-1'), { ok = false, error = 'validation', reason = 'denied' }, 'denied by id')
        env.breach.configure({ denyDoors = {} })
    end)

tests['qb-doorlock keys with Swedish letters are valid door ids; control chars / invalid UTF-8 are not'] = case(nil,
    function(t, env)
        t.eq(env.breach.doorId('häktet_1'), 'häktet_1')
        t.eq(env.breach.doorId('Förhörsrum 2'), 'Förhörsrum 2')
        t.eq(env.breach.doorId('a\tb'), nil, 'tab')
        t.eq(env.breach.doorId('a\0b'), nil, 'nul')
        t.eq(env.breach.doorId('\xff\xfe'), nil, 'invalid UTF-8')
        env.doors['häktet_1'] = { id = 'häktet_1', name = 'Häktet 1', state = 1, coords = DOOR_POS }
        local r = start(env, 1, 'häktet_1')
        t.ok(r.ok, 'start')
        t.eq(r.data.doorId, 'häktet_1')
    end)

---------------------------------------------------------------------------------------------------------------
-- Breach: start rejections

tests['start: no grant tool:ram → unauthorized'] = case(nil, function(t, env)
    t.eq(start(env, 3, 12), { ok = false, error = 'unauthorized', reason = 'grant' })
    t.eq(start(env, 7, 12), { ok = false, error = 'unauthorized', reason = 'grant' })
end)

tests['start: off duty → unauthorized off_duty'] = case(nil, function(t, env)
    t.eq(start(env, 4, 12), { ok = false, error = 'unauthorized', reason = 'off_duty' })
end)

tests['start: no pd_ram → validation no_item'] = case(nil, function(t, env)
    t.eq(start(env, 5, 12), { ok = false, error = 'validation', reason = 'no_item' })
end)

tests['start: unknown door → not_found; bad ids → validation'] = case(nil, function(t, env)
    t.eq(start(env, 1, 99), { ok = false, error = 'not_found', reason = 'door' })
    env.now = env.now + 1000
    t.eq(start(env, 1, 'x'), { ok = false, error = 'not_found', reason = 'door' }, 'a string key (qb-doorlock)')
    for _, bad in ipairs({ -1, 0, 1.5, 2000000, '', ('x'):rep(65), 'a\nb', {}, true }) do
        env.now = env.now + 1000
        t.eq(start(env, 1, bad), { ok = false, error = 'validation', reason = 'door' }, tostring(bad))
    end
    env.now = env.now + 1000
    t.eq(start(env, 1, nil), { ok = false, error = 'validation', reason = 'door' })
end)

tests['start: door already unlocked → validation not_locked'] = case(nil, function(t, env)
    t.eq(start(env, 1, 13), { ok = false, error = 'validation', reason = 'not_locked' })
end)

tests['start: more than 3.0 m from the door (server-side ped position) → validation too_far'] = case(nil,
    function(t, env)
        t.eq(start(env, 6, 12), { ok = false, error = 'validation', reason = 'too_far' })
        env.players[6].pos = vec(102.9, 200.0, 30.0)
        env.now = env.now + 1000
        t.ok(start(env, 6, 12).ok, '2.9 m is close enough')
    end)

tests['start: one attempt per second per player'] = case(nil, function(t, env)
    t.ok(start(env, 1, 12).ok)
    env.now = env.now + 500
    t.eq(start(env, 1, 12), { ok = false, error = 'rate_limited', reason = 'rate' })
    t.ok(start(env, 2, 12).ok, 'another player is not limited')
    env.now = env.now + 600
    t.ok(start(env, 1, 12).ok)
end)

tests['start: per-player cooldown after a successful breach'] = case(nil, function(t, env)
    local r = start(env, 1, 12)
    env.now = env.now + 4000
    t.ok(finish(env, 1, r.data.token).ok)
    env.doors[12].state = 1 -- relocked
    env.now = env.now + 2000
    t.eq(start(env, 1, 12), { ok = false, error = 'rate_limited', reason = 'cooldown' })
    env.now = env.now + 8000
    t.ok(start(env, 1, 12).ok, 'after 10 s')
end)

---------------------------------------------------------------------------------------------------------------
-- Breach: token rules

tests['finish: token expired after 8 s → expired, nothing unlocked'] = case(nil, function(t, env)
    local r = start(env, 1, 12)
    env.now = env.now + 8001
    t.eq(finish(env, 1, r.data.token), { ok = false, error = 'expired', reason = 'token' })
    t.eq(#env.setStates, 0)
    t.eq(#env.audits, 0)
end)

tests['finish: a token works once'] = case(nil, function(t, env)
    local r = start(env, 1, 12)
    env.now = env.now + 4000
    t.ok(finish(env, 1, r.data.token).ok)
    env.doors[12].state = 1
    env.now = env.now + 300
    t.eq(finish(env, 1, r.data.token), { ok = false, error = 'not_found', reason = 'token' })
    t.eq(#env.setStates, 1)
end)

tests["finish: another player's token is rejected and stays usable for its owner"] = case(nil, function(t, env)
    local r = start(env, 1, 12)
    env.now = env.now + 4000
    t.eq(finish(env, 2, r.data.token), { ok = false, error = 'not_found', reason = 'token' })
    t.eq(#env.setStates, 0)
    t.ok(finish(env, 1, r.data.token).ok)
end)

tests['finish: before the progress bar can have finished → too_early (token consumed)'] = case(nil,
    function(t, env)
        local r = start(env, 1, 12)
        env.now = env.now + 1000
        t.eq(finish(env, 1, r.data.token), { ok = false, error = 'validation', reason = 'too_early' })
        env.now = env.now + 3000
        t.eq(finish(env, 1, r.data.token), { ok = false, error = 'not_found', reason = 'token' })
        t.eq(#env.setStates, 0)
    end)

tests['finish: malformed tokens → validation'] = case(nil, function(t, env)
    for _, bad in ipairs({ 'abc', 42, ('z'):rep(32), ('a'):rep(33) }) do
        t.eq(finish(env, 1, bad), { ok = false, error = 'validation', reason = 'token' }, tostring(bad))
    end
    t.eq(finish(env, 1, nil), { ok = false, error = 'validation', reason = 'token' })
end)

tests['finish: a new start replaces the old token'] = case(nil, function(t, env)
    local r1 = start(env, 1, 12)
    env.now = env.now + 1000
    local r2 = start(env, 1, 12)
    t.ok(r1.data.token ~= r2.data.token)
    env.now = env.now + 4000
    t.eq(finish(env, 1, r1.data.token), { ok = false, error = 'not_found', reason = 'token' })
    env.now = env.now + 300
    t.ok(finish(env, 1, r2.data.token).ok)
end)

tests['finish: per-player rate limit (4/s) before the token lookup; the token is not consumed'] = case(nil,
    function(t, env)
        local r = start(env, 1, 12)
        env.now = env.now + 4000
        t.eq(finish(env, 1, ('0'):rep(32)), { ok = false, error = 'not_found', reason = 'token' })
        t.eq(finish(env, 1, r.data.token), { ok = false, error = 'rate_limited', reason = 'rate' })
        t.eq(finish(env, 2, ('1'):rep(32)), { ok = false, error = 'not_found', reason = 'token' },
            'another player is not limited')
        env.now = env.now + 250
        t.ok(finish(env, 1, r.data.token).ok, 'token still valid after the rate-limited attempt')
        t.eq(#env.setStates, 1)
    end)

tests['denyDoors default (config.lua): station, armory, evidence, vault and bank doors are denied (8.3 review)'] = case(nil,
    function(t, env)
        local denied = { 'mrpd armoury', 'mrpd cells main', 'community_mrpd 7', 'Fleeca Bank Vault', 'Evidence Locker',
            'Sandy Armory', 'pacific_bank_door' }
        for i, name in ipairs(denied) do
            env.doors[30 + i] = { id = 30 + i, name = name, state = 1, coords = DOOR_POS }
            env.now = env.now + 1000
            t.eq(start(env, 1, 30 + i), { ok = false, error = 'validation', reason = 'denied' }, name)
        end
        t.eq(#env.setStates, 0)
        env.now = env.now + 1000
        t.ok(start(env, 1, 12).ok, 'an ordinary door (house_12_front) can still be breached')
    end)

tests['denyDoors: listed ids, names and name patterns cannot be breached (start and finish)'] = case(nil,
    function(t, env)
        env.doors[20] = { id = 20, name = 'mrpd_armory', state = 1, coords = DOOR_POS }
        env.doors[21] = { id = 21, name = 'mrpd_evidence_2', state = 1, coords = DOOR_POS }
        env.breach.configure({ denyDoors = { 12, 'mrpd_armory', { pattern = '^mrpd_evidence' }, { pattern = '[' } } })
        for _, id in ipairs({ 12, 20, 21 }) do
            env.now = env.now + 1000
            t.eq(start(env, 1, id), { ok = false, error = 'validation', reason = 'denied' }, tostring(id))
        end
        t.eq(#env.setStates, 0)
        -- A door added to the list between start and finish is refused at finish too.
        env.breach.configure({ denyDoors = {} })
        env.doors[22] = { id = 22, name = 'house_front', state = 1, coords = DOOR_POS }
        env.now = env.now + 1000
        local r = start(env, 1, 22)
        t.ok(r.ok, 'unlisted door')
        env.breach.configure({ denyDoors = { 'house_front' } })
        env.now = env.now + 4000
        t.eq(finish(env, 1, r.data.token), { ok = false, error = 'validation', reason = 'denied' })
        t.eq(#env.setStates, 0)
        env.breach.configure({ denyDoors = {} })
    end)

tests['finish: re-checks grant, duty, item, lock state and distance'] = case(nil, function(t, env)
    local steps = {
        { function() env.players[1].grant = false end, { ok = false, error = 'unauthorized', reason = 'grant' } },
        { function() env.players[1].duty = false end, { ok = false, error = 'unauthorized', reason = 'off_duty' } },
        { function() env.players[1].ram = 0 end, { ok = false, error = 'validation', reason = 'no_item' } },
        { function() env.doors[12].state = 0 end, { ok = false, error = 'validation', reason = 'not_locked' } },
        { function() env.players[1].pos = vec(120.0, 200.0, 30.0) end,
            { ok = false, error = 'validation', reason = 'too_far' } },
    }
    for i, step in ipairs(steps) do
        env.players[1] = { cid = 'POL00001', grant = true, duty = true, ram = 1, pos = vec(101.0, 200.0, 30.0) }
        env.doors[12].state = 1
        env.now = env.now + 20000
        local r = start(env, 1, 12)
        t.ok(r.ok, 'start ' .. i)
        env.now = env.now + 4000
        step[1]()
        t.eq(finish(env, 1, r.data.token), step[2], 'step ' .. i)
    end
    t.eq(#env.setStates, 0)
    t.eq(#env.audits, 0)
end)

tests['finish: the doorlock refusing the change → unavailable, no audit'] = case(nil, function(t, env)
    env.setStateResult = false
    local r = start(env, 1, 12)
    env.now = env.now + 4000
    t.eq(finish(env, 1, r.data.token), { ok = false, error = 'unavailable', reason = 'doorlock' })
    t.eq(#env.audits, 0)
end)

tests['inventory or doorlock resource not running → unavailable (bridge fallbacks never read as no_item)'] = case(nil,
    function(t, env)
        env.states[env.impl.inventory] = 'stopped'
        t.eq(start(env, 1, 12), { ok = false, error = 'unavailable', reason = 'inventory' })
        env.states[env.impl.inventory] = nil
        env.states[env.impl.doorlock] = 'stopped'
        env.now = env.now + 1000
        t.eq(start(env, 1, 12), { ok = false, error = 'unavailable', reason = 'doorlock' })
        env.states[env.impl.doorlock] = nil
        env.now = env.now + 1000
        t.ok(start(env, 1, 12).ok, 'back')
    end)

tests['character load / logout (fredpd:bridge:*) tell only that client to re-read doors or drop its zones'] = case(nil,
    function(t, env)
        env.handlers['fredpd:bridge:playerLoaded'](3)
        env.handlers['fredpd:bridge:playerUnloaded'](4)
        env.handlers['fredpd:bridge:playerLoaded'](0)
        env.handlers['fredpd:bridge:playerLoaded']('x')
        t.eq(env.clientEvents, {
            { name = 'fredpd:breach:client:character', target = 3, args = { true } },
            { name = 'fredpd:breach:client:character', target = 4, args = { false } },
        })
    end)

tests['qb-doorlock without the FredPD patch: doors not found, ONE bridge warning, never an error'] = case(
    { stack = 'qb' }, function(t, env)
        env.resources[env.impl.doorlock] = setmetatable({}, { __index = function(_, k)
            return function() error(('No such export %s in resource qb-doorlock'):format(k), 2) end
        end })
        t.eq(start(env, 1, 12), { ok = false, error = 'not_found', reason = 'door' })
        env.now = env.now + 1000
        t.eq(start(env, 2, 12), { ok = false, error = 'not_found', reason = 'door' })
        t.eq(#env.setStates, 0)
        local n = 0
        for _, l in ipairs(env.bridgeLogs) do
            if l.level == 'warn' and l.msg:find('qb-doorlock has no FredPD exports', 1, true) then n = n + 1 end
        end
        t.eq(n, 1, 'one warning from the bridge')
    end)

tests['item guard: the definition is looked up in the selected stack\'s item file (bridgeInfo)'] = case(nil,
    function(t, env)
        t.eq(env.breach.definesItem("pd_ram = { name = 'pd_ram', label = 'x' }", 'pd_ram'), true, 'qb-core shape')
        t.eq(env.breach.definesItem("['pd_ram'] = {", 'pd_ram'), true, 'ox_inventory shape')
        t.eq(env.breach.definesItem("-- pd_ram: not used from the inventory", 'pd_ram'), false, 'a comment')
        t.eq(env.breach.definesItem("['pd_ramx'] = {", 'pd_ram'), false)
        local warned = 0
        for _, l in ipairs(env.logs) do if l:find('pd_ram', 1, true) then warned = warned + 1 end end
        t.eq(warned, 0, 'defined: no warning')
    end)

tests['playerDropped forgets the token'] = case(nil, function(t, env)
    local r = start(env, 1, 12)
    _G.source = 1
    env.handlers.playerDropped()
    _G.source = nil
    env.now = env.now + 4000
    t.eq(finish(env, 1, r.data.token), { ok = false, error = 'not_found', reason = 'token' })
end)

tests['an error inside a callback answers unavailable'] = case(nil, function(t, env)
    _G.exports = setmetatable({}, { __index = function() error('boom') end, __call = function() end })
    local r = start(env, 1, 12)
    t.eq(r.ok, false)
    t.ok(r.error == 'unauthorized' or r.error == 'unavailable')
end)

tests['breachEvidence (optional) spawns at the door with the officer as owner'] = case(OX, function(t, env)
    env.breach.configure({ breachEvidence = { { type = 'fingerprint', chance = 100 }, { type = 'toolmark' } } })
    local r = start(env, 1, 12)
    env.now = env.now + 4000
    local f = finish(env, 1, r.data.token)
    t.eq(f.data.evidence, { 'fingerprint' })
    t.eq(#env.sync, 1)
    t.eq(env.sync[1].type, 'fingerprint')
    t.eq(env.sync[1].owner, 1)
    t.eq(env.sync[1].fun, 'atCoords')
    t.eq(env.sync[1].coords, DOOR_POS)
    env.breach.configure({ breachEvidence = false })
end)

---------------------------------------------------------------------------------------------------------------
-- Scene evidence

local SCENE_POS = vec(250.0, -1000.0, 29.0)

local function scene(env, kind, coords, suspect) return env.exported.sceneEvidence(kind, coords, suspect) end

tests['scene: burglary spawns a fingerprint atCoords with the suspect as owner; toolmark is skipped'] = case(OX,
    function(t, env)
        local savedRandom = math.random
        math.random = function(a, b) return a end -- every chance roll succeeds
        local r = scene(env, 'burglary', SCENE_POS, 2)
        math.random = savedRandom
        t.eq(r, { ok = true, data = { spawned = { 'fingerprint' } } })
        t.eq(env.sync, { { type = 'fingerprint', owner = 2, fun = 'atCoords', coords = SCENE_POS,
            meta = { scene = 'burglary' } } })
        t.eq(#env.audits, 1)
        local a = env.audits[1]
        t.eq(a.src, 0)
        t.eq(a.action, 'breach.scene')
        t.eq(a.targetType, 'scene')
        t.eq(a.targetId, 'burglary')
        t.eq(a.meta, { kind = 'burglary', coords = { x = 250.0, y = -1000.0, z = 29.0 }, suspect = 2,
            suspectCitizenid = 'POL00002', spawned = { 'fingerprint' }, by = 'crime_script' })
        local warned = false
        for _, l in ipairs(env.logs) do if l:find('"toolmark"', 1, true) then warned = true end end
        t.ok(warned, 'one warning about toolmark')
    end)

tests['scene: several pieces are spaced so evidences keeps each one'] = case(OX, function(t, env)
    env.scene.configure({}, { robbery = { { type = 'fingerprint', chance = 100 }, { type = 'blood', chance = 100 } } })
    local r = scene(env, 'robbery', SCENE_POS, 1)
    t.eq(r.data.spawned, { 'fingerprint', 'blood' })
    t.eq(env.sync[1].coords, vec(250.0, -1000.0, 29.0))
    t.eq(env.sync[2].coords, vec(250.25, -1000.0, 29.0))
    t.eq(env.sync[2].type, 'blood')
end)

tests['scene: chance rolls decide per entry'] = case(OX, function(t, env)
    local savedRandom = math.random
    math.random = function() return 100 end -- only chance = 100 passes
    env.scene.configure({}, { robbery = { { type = 'fingerprint', chance = 99 }, { type = 'saliva', chance = 100 } } })
    local r = scene(env, 'robbery', SCENE_POS, 1)
    math.random = savedRandom
    t.eq(r.data.spawned, { 'saliva' })
    t.eq(#env.sync, 1)
end)

tests['scene: unknown kind, bad coords and a disconnected suspect are rejected'] = case(nil, function(t, env)
    t.eq(scene(env, 'arson', SCENE_POS, 1), { ok = false, error = 'validation', reason = 'kind' })
    t.eq(scene(env, 42, SCENE_POS, 1), { ok = false, error = 'validation', reason = 'kind' })
    local nan = 0 / 0
    for _, c in ipairs({ vec(nan, 0, 0), vec(math.huge, 0, 0), vec(1, 2, nil), vec(9000, 0, 0), vec(0, -9000, 0),
        vec(0, 0, 5000), 'here', 12 }) do
        t.eq(scene(env, 'burglary', c, 1), { ok = false, error = 'validation', reason = 'coords' })
    end
    t.eq(scene(env, 'burglary', nil, 1), { ok = false, error = 'validation', reason = 'coords' })
    for _, s in ipairs({ 99, 0, -1, 'x', 1.5 }) do
        t.eq(scene(env, 'burglary', SCENE_POS, s), { ok = false, error = 'validation', reason = 'suspect' }, tostring(s))
    end
    t.eq(#env.sync, 0)
    t.eq(#env.audits, 0)
end)

tests['scene: the same place and kind has a cooldown; another place or kind does not'] = case(OX, function(t, env)
    env.scene.configure({}, { burglary = { { type = 'fingerprint', chance = 100 } },
        robbery = { { type = 'fingerprint', chance = 100 } } })
    t.ok(scene(env, 'burglary', SCENE_POS, 1).ok)
    env.now = env.now + 1000
    t.eq(scene(env, 'burglary', vec(251.0, -1000.5, 29.0), 2), { ok = false, error = 'rate_limited', reason = 'cooldown' })
    t.ok(scene(env, 'robbery', SCENE_POS, 1).ok, 'another kind')
    t.ok(scene(env, 'burglary', vec(300.0, -1000.0, 29.0), 1).ok, 'another place')
    env.now = env.now + 60000
    t.ok(scene(env, 'burglary', SCENE_POS, 1).ok, 'after the cooldown')
    t.eq(#env.sync, 4)
end)

tests['scene: shooting spawns nothing (evidences makes casings itself) but is accepted'] = case(OX, function(t, env)
    t.eq(scene(env, 'shooting', SCENE_POS, 1), { ok = true, data = { spawned = {} } })
    t.eq(#env.sync, 0)
end)

local function sceneOff(t, env)
    t.eq(scene(env, 'burglary', SCENE_POS, 1), { ok = false, error = 'unavailable', reason = 'evidences' })
    env.now = env.now + 100000
    t.eq(scene(env, 'burglary', SCENE_POS, 1).error, 'unavailable')
    local n = 0
    for _, l in ipairs(env.logs) do if l:find('scene evidence is disabled', 1, true) then n = n + 1 end end
    t.eq(n, 1, table.concat(env.logs, ' | '))
    t.eq(#env.sync, 0)
end

tests['scene: evidences not started → unavailable with one warning'] = case({ stack = 'ox', evidencesState = 'stopped' },
    sceneOff)

tests['scene: qb stack (no evidence feature, even with evidences running) → unavailable with one warning'] =
    case({ stack = 'qb' }, function(t, env)
        t.eq(env.states.evidences, 'started')
        sceneOff(t, env)
        -- the breach itself still works; no door evidence either
        env.breach.configure({ breachEvidence = { { type = 'fingerprint', chance = 100 } } })
        local r = start(env, 1, 12)
        env.now = env.now + 4000
        t.eq(finish(env, 1, r.data.token).data.evidence, {})
        env.breach.configure({ breachEvidence = false })
    end)

tests['scene table: config keys are SceneKinds and every kind is present'] = case(nil, function(t, env)
    for kind in pairs(env.scene.SCENE_KINDS) do t.ok(env.scene.table[kind] ~= nil, kind) end
    local ts = io.open('packages/types/src/evidence.ts'):read('a')
    local enum = ts:match("SceneKindSchema = z%.enum%(%[(.-)%]%)")
    local n = 0
    for k in enum:gmatch("'([%w_]+)'") do
        n = n + 1
        t.ok(env.scene.SCENE_KINDS[k], k .. ' known to Lua')
    end
    local lua = 0
    for _ in pairs(env.scene.SCENE_KINDS) do lua = lua + 1 end
    t.eq(lua, n, 'same SceneKind set as packages/types')
end)

return tests
