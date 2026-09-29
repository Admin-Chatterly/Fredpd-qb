-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_breach server (task 6.1, IMPLEMENTATION.md §5.6, docs/contracts.md §C16) with FiveM mocked: fredpd_core
-- (grants, duty, audit, citizenid), ox_inventory (GetItemCount, Items), ox_doorlock (getDoor, setDoorState),
-- evidences (syncEvidence), ped positions, the game timer, lib.callback and exports. Loads server/main.lua so the
-- callbacks and the export are the ones the resource registers.
-- Covers: breach start/finish checks (grant, duty, item, door exists/locked, distance, rate limit, cooldown), token
-- rules (expiry, reuse, another player's token, too early, replaced by a new start, dropped player), success →
-- setDoorState(id, 0) + audit breach.door; sceneEvidence validation (kind, coords, bounds, suspect), per-location
-- cooldown, evidences call arguments and spacing, unsupported types skipped, audit breach.scene.
-- Run: lua5.4 tests/lua/run.lua breach_server
local tests = {}

local BREACH = './resources/[fredpd]/fredpd_breach/'
local MODULES = { 'config', 'config.scene_evidence', 'server.breach', 'server.scene', 'server.main' }
local GLOBALS = { 'exports', 'lib', 'GetGameTimer', 'GetEntityCoords', 'GetPlayerPed', 'DoesPlayerExist',
    'GetResourceState', 'AddEventHandler', 'vec3', 'vector3', 'GetInvokingResource', 'source' }

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
            [12] = { id = 12, name = 'mrpd_cells', state = 1, coords = DOOR_POS },
            [13] = { id = 13, name = 'open_door', state = 0, coords = DOOR_POS },
        },
        itemKnown = opts.itemKnown ~= false,
        evidencesState = opts.evidencesState or 'started',
        callbacks = {}, handlers = {}, exported = {}, audits = {}, setStates = {}, sync = {}, logs = {},
        setStateResult = true,
    }
    env.saved = {}
    for _, g in ipairs(GLOBALS) do env.saved[g] = rawget(_G, g) end

    local resources = {
        fredpd_core = {
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
        },
        ox_inventory = {
            GetItemCount = function(_, src, name)
                local p = env.players[src]
                if name ~= 'pd_ram' or not p or not env.itemKnown then return 0 end
                return p.ram
            end,
            Items = function(_, name)
                if name == 'pd_ram' and env.itemKnown then return { name = 'pd_ram', label = 'Dörrkross' } end
                return nil
            end,
        },
        ox_doorlock = {
            getDoor = function(_, id)
                local d = env.doors[id]
                if not d then return false end
                return { id = d.id, name = d.name, state = d.state, coords = d.coords }
            end,
            setDoorState = function(_, id, state)
                env.setStates[#env.setStates + 1] = { id = id, state = state }
                if env.setStateResult and env.doors[id] then env.doors[id].state = state end
                return env.setStateResult
            end,
        },
        evidences = {
            syncEvidence = function(_, evidenceType, owner, fun, coords, meta)
                env.sync[#env.sync + 1] = { type = evidenceType, owner = owner, fun = fun, coords = coords, meta = meta }
            end,
        },
    }
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
    _G.GetResourceState = function(name)
        if name == 'evidences' then return env.evidencesState end
        return 'started'
    end
    _G.AddEventHandler = function(name, fn) env.handlers[name] = fn end
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

tests['success: start → 4 s → finish unlocks with setDoorState(id, 0) and audits breach.door'] = case(nil,
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
        t.eq(#env.audits, 1)
        t.eq(env.audits[1], { src = 1, action = 'breach.door', targetType = 'door', targetId = 12,
            meta = { doorId = 12, name = 'mrpd_cells', coords = { x = 100.0, y = 200.0, z = 30.0 } } })
    end)

tests['door id from the client may be a numeric string; the server reads the door itself'] = case(nil,
    function(t, env)
        local r = start(env, 1, '12')
        t.ok(r.ok)
        t.eq(r.data.doorId, 12)
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
    for _, bad in ipairs({ 'x', -1, 0, 1.5, 2000000 }) do
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
    t.ok(finish(env, 1, r2.data.token).ok)
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

tests['finish: ox_doorlock refusing the change → unavailable, no audit'] = case(nil, function(t, env)
    env.setStateResult = false
    local r = start(env, 1, 12)
    env.now = env.now + 4000
    t.eq(finish(env, 1, r.data.token), { ok = false, error = 'unavailable', reason = 'doorlock' })
    t.eq(#env.audits, 0)
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

tests['breachEvidence (optional) spawns at the door with the officer as owner'] = case(nil, function(t, env)
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

tests['scene: burglary spawns a fingerprint atCoords with the suspect as owner; toolmark is skipped'] = case(nil,
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

tests['scene: several pieces are spaced so evidences keeps each one'] = case(nil, function(t, env)
    env.scene.configure({}, { robbery = { { type = 'fingerprint', chance = 100 }, { type = 'blood', chance = 100 } } })
    local r = scene(env, 'robbery', SCENE_POS, 1)
    t.eq(r.data.spawned, { 'fingerprint', 'blood' })
    t.eq(env.sync[1].coords, vec(250.0, -1000.0, 29.0))
    t.eq(env.sync[2].coords, vec(250.25, -1000.0, 29.0))
    t.eq(env.sync[2].type, 'blood')
end)

tests['scene: chance rolls decide per entry'] = case(nil, function(t, env)
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

tests['scene: the same place and kind has a cooldown; another place or kind does not'] = case(nil, function(t, env)
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

tests['scene: shooting spawns nothing (evidences makes casings itself) but is accepted'] = case(nil, function(t, env)
    t.eq(scene(env, 'shooting', SCENE_POS, 1), { ok = true, data = { spawned = {} } })
    t.eq(#env.sync, 0)
end)

tests['scene: evidences not started → unavailable with one warning'] = case({ evidencesState = 'stopped' },
    function(t, env)
        t.eq(scene(env, 'burglary', SCENE_POS, 1), { ok = false, error = 'unavailable', reason = 'evidences' })
        env.now = env.now + 100000
        t.eq(scene(env, 'burglary', SCENE_POS, 1).error, 'unavailable')
        local n = 0
        for _, l in ipairs(env.logs) do if l:find('evidences is not started', 1, true) then n = n + 1 end end
        t.eq(n, 1)
        t.eq(#env.sync, 0)
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
