-- SPDX-License-Identifier: GPL-3.0-only
-- Doorlock bridge (docs/contracts.md §C17): qb-doorlock (through patches/qb-doorlock.10-fredpd-bridge.patch, applied
-- to a copy of the pinned commit and its server.lua run with mocks) and ox_doorlock (mock shaped like server/main.lua),
-- getDoor / setLocked / fredpd:bridge:doorChanged, the unpatched qb-doorlock degradation, and both client listDoors.
-- Run: lua5.4 tests/lua/run.lua bridge_doorlock
local H = require('bridge_harness_test')
local helper = require('helper')
local PH = require('police_harness_test') -- decfx (cfxlua compound assignment -> Lua 5.4, test loading only)

local tests = {}

local QB = { framework = 'qb-core', inventory = 'qb-inventory', target = 'qb-target', doorlock = 'qb-doorlock' }
local OX = { framework = 'qbx_core', inventory = 'ox_inventory', target = 'ox_target', doorlock = 'ox_doorlock' }
local UPSTREAM = './resources/[upstream]/qb-doorlock'
local PATCH = 'patches/qb-doorlock.10-fredpd-bridge.patch'

--- cfxlua -> Lua 5.4 for loading in tests: the harness's line rewrite plus inline `x += n` (server.lua:29).
local function decfx(src)
    return PH.decfx((src:gsub('([%w_]+)%s*%+=%s*([%w_]+)', '%1 = %1 + %2')))
end

local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function run(cmd)
    local p = io.popen(cmd .. ' 2>&1')
    local out = p:read('a')
    local ok = p:close()
    return ok == true, out
end

--- server.lua of the pinned qb-doorlock with the FredPD patch applied (cached per run); nil + reason when the
--- checkout or the patch is not usable.
local patched = nil
local function patchedServer()
    if patched then return patched.src, patched.reason end
    patched = {}
    local commit = helper.readJson('deps.lock.json').resources['qb-doorlock'].commit
    if not run(('git -C %s cat-file -e %s^{commit}'):format(shq(UPSTREAM), commit)) then
        patched.reason = 'qb-doorlock checkout missing (scripts/fetch-deps.sh)'
        return nil, patched.reason
    end
    local dir = os.tmpname()
    os.remove(dir)
    run('mkdir -p ' .. shq(dir))
    local ok, out = run(('git -C %s archive %s | tar -x -C %s && git -C %s init -q && git -C %s apply %s'):format(
        shq(UPSTREAM), commit, shq(dir), shq(dir), shq(dir), shq(io.popen('pwd'):read('l') .. '/' .. PATCH)))
    if ok then
        local f = assert(io.open(dir .. '/server.lua', 'rb'))
        patched.src = f:read('a')
        f:close()
        patched.reverse = run(('git -C %s apply --reverse --check %s'):format(shq(dir),
            shq(io.popen('pwd'):read('l') .. '/' .. PATCH)))
    else
        patched.reason = PATCH .. ' does not apply: ' .. out
    end
    run('rm -rf ' .. shq(dir))
    return patched.src, patched.reason
end

--- Run the patched server.lua in its own _ENV. Returns up = { exports = name -> fn, net = name -> fn, client = {},
--- local = {}, timers = {} }. onLocal(name, ...) receives its server-local TriggerEvent calls.
local function loadQbDoorlock(doorList, onLocal)
    local src, reason = patchedServer()
    if not src then return nil, reason end
    local up = { exports = {}, net = {}, client = {}, localEvents = {}, timers = {} }
    local Config = { DoorList = doorList, DoorStates = {}, EnableSounds = true, PersistentDoorStates = false,
        Warnings = false, Consumables = {} }
    local env = setmetatable({
        Config = Config,
        Lang = { t = function(_, key) return key end },
        exports = setmetatable({}, {
            __call = function(_, name, fn) up.exports[name] = fn end,
            __index = function(_, res)
                if res == 'qb-core' then
                    return {
                        GetCoreObject = function() return { Functions = { CreateCallback = function() end },
                            Commands = { Add = function() end } } end,
                        GetPlayer = function(_, id) return { PlayerData = { source = id, name = 'p', license = 'l' } } end,
                    }
                end
                error('unexpected export resource ' .. tostring(res))
            end,
        }),
        RegisterNetEvent = function(name, fn) up.net[name] = fn end,
        AddEventHandler = function() end,
        TriggerClientEvent = function(name, target, ...) up.client[#up.client + 1] = { name, target, ... } end,
        TriggerEvent = function(name, ...)
            up.localEvents[#up.localEvents + 1] = { name, ... }
            if onLocal then onLocal(name, ...) end
        end,
        SetTimeout = function(ms, fn) up.timers[#up.timers + 1] = { ms = ms, fn = fn } end,
        GetCurrentResourceName = function() return 'qb-doorlock' end,
    }, { __index = _G })
    local chunk = assert(load(decfx(src), '@qb-doorlock/server.lua', 't', env))
    chunk()
    up.Config = Config
    return up
end

local function doors()
    return {
        [1] = { doorLabel = 'Mission Row front', locked = true, objCoords = { x = 1, y = 2, z = 3 }, authorizedJobs = { police = 0 } },
        ['mrpd-cells'] = { doorLabel = 'Cells', locked = false, doors = { { objCoords = { x = 4, y = 5, z = 6 } }, {} },
            autoLock = 5000 },
        [3] = { doorLabel = 'Garage', locked = false, textCoords = { x = 7, y = 8, z = 9 } },
    }
end

--- H.with options for the qb stack wired to the patched qb-doorlock.
local function qbWithPatched(t)
    local env0 = nil
    local up, reason = loadQbDoorlock(doors(), function(name, ...)
        if env0 then env0.fire(name, '', ...) end
    end)
    if not up then
        print('SKIP bridge_doorlock_test (qb-doorlock): ' .. tostring(reason))
        return nil
    end
    local res = {}
    for name, fn in pairs(up.exports) do res[name] = function(_, ...) return fn(...) end end
    return {
        cfg = QB, states = { ['qb-doorlock'] = 'started' }, resources = { ['qb-doorlock'] = res },
    }, up, function(env) env0 = env end
end

tests['patch applies to the pinned qb-doorlock, reverse-applies, and compiles'] = function(t)
    local src, reason = patchedServer()
    if not src then print('SKIP: ' .. tostring(reason)) return end
    t.ok(patched.reverse, 'reverse-applies on the patched tree (apply-patches idempotence)')
    t.ok(load(decfx(src), '@server.lua', 't') ~= nil, 'compiles')
    t.ok(src:find("exports('getDoor'", 1, true) and src:find("exports('setDoorState'", 1, true), 'exports added')
end

tests['qb-doorlock (patched): getDoor normalises config keys, coords of single/double/text doors'] = function(t)
    local opts, _, bind = qbWithPatched(t)
    if not opts then return end
    H.with(opts, function(env)
        bind(env)
        local B = env.Bridge
        t.eq(B.getDoor(1), { id = 1, name = 'Mission Row front', locked = true, coords = { x = 1, y = 2, z = 3 } })
        t.eq(B.getDoor('mrpd-cells'), { id = 'mrpd-cells', name = 'Cells', locked = false, coords = { x = 4, y = 5, z = 6 } })
        t.eq(B.getDoor(3).coords, { x = 7, y = 8, z = 9 })
        t.eq(B.getDoor(99), nil)
        t.eq(B.getDoor({}), nil, 'invalid id')
        t.eq(B.getDoor(''), nil)
    end)
end

tests['qb-doorlock (patched): setLocked changes state, tells clients, emits doorChanged; autoLock too'] = function(t)
    local opts, up, bind = qbWithPatched(t)
    if not opts then return end
    H.with(opts, function(env)
        bind(env)
        local B = env.Bridge
        t.eq(B.setLocked(1, false, 4), true)
        t.eq(up.Config.DoorList[1].locked, false)
        t.eq(up.client[#up.client], { 'qb-doorlock:client:setState', -1, 4, 1, false, false, true, false })
        t.eq(env.events(B.EVENTS.doorChanged), { { 1, false } })
        t.eq(B.setLocked('mrpd-cells', false), true)
        t.eq(#up.timers, 1, 'autoLock scheduled by qb-doorlock')
        up.timers[1].fn()
        t.eq(up.Config.DoorList['mrpd-cells'].locked, true)
        t.eq(env.events(B.EVENTS.doorChanged), { { 1, false }, { 'mrpd-cells', false }, { 'mrpd-cells', true } })
        t.eq(B.setLocked(99, true), false, 'unknown door')
        t.eq(B.setLocked(1, 'yes'), false, 'locked must be boolean')

        -- A player's own toggle (qb-doorlock's net event, unchanged behaviour) also reaches the bridge event.
        rawset(_G, 'source', 7)
        up.net['qb-doorlock:server:updateState'](3, true, false, false, true, true, true)
        t.eq(up.Config.DoorList[3].locked, true)
        t.eq(env.events(B.EVENTS.doorChanged)[4], { 3, true })
    end)
end

tests['qb-doorlock without the patch: getDoor nil, setLocked false, ONE warning, report says unpatched'] = function(t)
    H.with({ cfg = QB, states = { ['qb-doorlock'] = 'started' }, resources = { ['qb-doorlock'] = {} } }, function(env)
        local B = env.Bridge
        t.eq(B.getDoor(1), nil)
        t.eq(B.setLocked(1, true), false)
        t.eq(B.getDoor(2), nil)
        t.eq(H.count(env.logs.warn, 'qb-doorlock has no FredPD exports'), 1)
        t.eq(#env.logs.error, 0, 'a missing export is not an error')
        t.ok(B.report():find('doorlock=qb-doorlock (unpatched!)', 1, true), B.report())
    end)
end

--- ox_doorlock mock (7d72ff77 server/main.lua): getDoor(id) :53-68 -> door with state 0|1 or false; setDoorState(id,
--- state) :275-314 fires ox_doorlock:stateChanged(source|nil, id, locked) :293/298.
local function oxDoorlock(list, fire)
    return {
        getDoor = function(_, id) return list[id] or false end,
        setDoorState = function(_, id, state)
            local door = list[id]
            if not door or (state ~= 0 and state ~= 1) then return false end
            door.state = state
            fire('ox_doorlock:stateChanged', nil, id, state == 1)
            return true
        end,
    }
end

tests['ox_doorlock: getDoor / setLocked(state 0|1) / stateChanged -> doorChanged'] = function(t)
    local list = { [12] = { id = 12, name = 'mrpd_front', state = 1, coords = { x = 1, y = 2, z = 3 }, maxDistance = 2 } }
    local env0
    H.with({ cfg = OX, states = { ox_doorlock = 'started' }, resources = { ox_doorlock = oxDoorlock(list, function(n, ...)
        env0.fire(n, '', ...)
    end) } }, function(env)
        env0 = env
        local B = env.Bridge
        t.eq(B.getDoor(12), { id = 12, name = 'mrpd_front', locked = true, coords = { x = 1, y = 2, z = 3 } })
        t.eq(B.getDoor(13), nil, 'false -> nil')
        t.eq(B.setLocked(12, false, 3), true)
        t.eq(list[12].state, 0)
        t.eq(env.events(B.EVENTS.doorChanged), { { 12, false } })
        env.fire('ox_doorlock:stateChanged', '', 5, 12, true, 'lockpick') -- (source, doorId, locked, usedItem)
        t.eq(env.events(B.EVENTS.doorChanged)[2], { 12, true })
    end)
end

tests['doorlock resource missing: ONE warning at start, calls are no-ops'] = function(t)
    H.with({ cfg = OX, states = {} }, function(env)
        t.eq(env.Bridge.getDoor(1), nil)
        t.eq(env.Bridge.setLocked(1, true), false)
        t.eq(H.count(env.logs.warn, 'resource ox_doorlock is missing'), 1, table.concat(env.logs.warn, '\n'))
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Client side (implementation modules directly; bridge/client.lua itself is covered in bridge_target_test.lua)

tests['client listDoors: qb-doorlock GetDoorList (config keys as ids) and ox_doorlock getDoors callback'] = function(t)
    local saved = { exports = rawget(_G, 'exports'), lib = rawget(_G, 'lib'), RegisterNetEvent = rawget(_G, 'RegisterNetEvent') }
    local net = {}
    local ok, err = pcall(function()
        rawset(_G, 'exports', H.exports({ ['qb-doorlock'] = { GetDoorList = function() return doors() end } }, {}))
        rawset(_G, 'RegisterNetEvent', function(name, fn) net[name] = fn end)
        local qb = require('bridge.doorlock.qb_doorlock').client()
        local list = qb.listDoors()
        t.eq(#list, 3)
        t.eq(list[1], { id = 1, name = 'Mission Row front', locked = true, coords = { x = 1, y = 2, z = 3 } })
        t.eq(list[3].id, 'mrpd-cells', 'sorted by tostring(id)')
        local changes = {}
        qb.onDoorChanged(function(id, locked) changes[#changes + 1] = { id, locked } end)
        -- qb-doorlock client.lua:362 setState(serverId, doorID, state, src, sounds, anim)
        net['qb-doorlock:client:setState'](4, 'mrpd-cells', true, false, true, true)
        t.eq(changes, { { 'mrpd-cells', true } })

        rawset(_G, 'lib', { callback = { await = function(name)
            t.eq(name, 'ox_doorlock:getDoors')
            return { [2] = { id = 2, name = 'b', state = 0, coords = 'c2' }, [1] = { id = 1, name = 'a', state = 1 } }, {}
        end } })
        local ox = require('bridge.doorlock.ox_doorlock').client()
        t.eq(ox.listDoors(), { { id = 1, name = 'a', locked = true }, { id = 2, name = 'b', locked = false, coords = 'c2' } })
        ox.onDoorChanged(function(id, locked) changes[#changes + 1] = { id, locked } end)
        net['ox_doorlock:setState'](2, 1, nil, {})
        t.eq(changes[2], { 2, true })
    end)
    for k, v in pairs(saved) do rawset(_G, k, v) end
    if not ok then error(err, 0) end
end

return tests
