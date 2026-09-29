-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_breach client (task 6.1) with FiveM and ox_lib mocked and fredpd_core's REAL bridge/client.lua over the
-- target / doorlock / framework client mocks of the selected stack (FREDPD_STACK, tests/lua/dispatch_stack_test.lua:
-- qb-target + qb-doorlock by default, ox_target + ox_doorlock with FREDPD_STACK=ox): the door list from
-- FredBridge.doorlock.listDoors (at start, after a doorlock restart, after the character loads) kept current by
-- FredBridge.doorlock.onDoorChanged, one box zone per door with "Forcera dörr" only while the player holds grant
-- tool:ram, canInteract hints (door locked + grant; the server checks pd_ram), the start → progress → finish flow
-- (prop + anim only inside lib.progressBar, anim fallback), and every error code has Swedish text.
-- breach_bridge_test.lua runs a smoke matrix over both stacks.
-- Run: lua5.4 tests/lua/run.lua breach_client
local helper = require('helper')
local Stack = require('dispatch_stack_test')

local tests = {}

local BREACH = './resources/[fredpd]/fredpd_breach/'
local MODULES = { 'config', 'client.main' }
local GLOBALS = { 'lib', 'exports', 'AddEventHandler', 'CreateThread', 'GetCurrentResourceName', 'SetTimeout',
    'locale', 'vec3', 'DoesAnimDictExist', 'GetAnimDuration', 'RemoveAnimDict' }
for _, g in ipairs(Stack.CLIENT_GLOBALS) do GLOBALS[#GLOBALS + 1] = g end

package.preload['@fredpd_core.shared.locale'] = function() return require('shared.locale') end
package.preload['@fredpd_core.shared.grants'] = function() return require('shared.grants') end

local SV = (function()
    local dict = helper.readJson('locales/sv.json')
    for k, v in pairs(helper.readJson('locales/pending/breach.json')) do dict[k] = v.sv end
    return dict
end)()

local function vec(x, y, z) return { x = x, y = y, z = z } end

--- opts = { stack, anims, grants (false = none), doorlockState }.
local function setup(opts)
    opts = opts or {}
    local stack = opts.stack or Stack.current()
    local rec = Stack.client(stack, {
        job = { name = 'police', type = 'leo', onduty = true, grade = { level = 1 } },
        doors = { [12] = { name = 'mrpd_cells', locked = true, coords = vec(100, 200, 30) },
            [13] = { name = 'mrpd_front', locked = false, coords = vec(110, 200, 30) } },
        states = { [Stack.IMPL[stack].doorlock] = opts.doorlockState },
    })
    local env = {
        saved = {}, rec = rec, stack = stack, impl = Stack.IMPL[stack], handlers = {}, notifies = {}, progress = {},
        awaits = {}, timers = {},
        grants = { grants = { 'tool:ram' }, denied = {}, tier = 0, units = {} },
        anims = opts.anims or { missheistfbi3b_ig7 = { lift_fibagent_loop = 3.0 } },
        progressResult = true,
        answers = {},
    }
    if opts.grants == false then env.grants = nil end
    for _, g in ipairs(GLOBALS) do env.saved[g] = rawget(_G, g) end
    _G.lib = {
        notify = function(n) env.notifies[#env.notifies + 1] = n end,
        callback = {
            await = function(name, _, ...)
                if name == 'ox_doorlock:getDoors' then return rec.oxDoors() end -- ox_doorlock server/main.lua:316
                env.awaits[#env.awaits + 1] = { name, ... }
                if name == 'fredpd:getMyGrants' then return env.grants end
                return env.answers[name]
            end,
        },
        progressBar = function(data)
            env.progress[#env.progress + 1] = data
            return env.progressResult
        end,
        requestAnimDict = function(dict) return dict end,
    }
    _G.exports = setmetatable({}, { __index = function(_, res)
        return rec.resources[res] or setmetatable({}, { __index = function(_, k)
            return function() error(('No such export %s in resource %s'):format(k, res), 2) end
        end })
    end })
    _G.AddEventHandler = function(name, fn) env.handlers[name] = fn end
    _G.CreateThread = function(fn) fn() end
    _G.SetTimeout = function(ms, fn) env.timers[#env.timers + 1] = { ms = ms, fn = fn } end
    _G.GetCurrentResourceName = function() return 'fredpd_breach' end
    _G.locale = function(key) return SV[key] or key end
    _G.vec3 = vec
    _G.DoesAnimDictExist = function(dict) return env.anims[dict] ~= nil end
    _G.GetAnimDuration = function(dict, clip) return (env.anims[dict] or {})[clip] or 0 end
    _G.RemoveAnimDict = function() end

    for _, name in ipairs(MODULES) do package.loaded[name] = nil end
    local savedPath = package.path
    package.path = BREACH .. '?.lua;' .. package.path
    local ok, mod = pcall(function()
        Stack.loadClientBridge(rec) -- client_scripts: '@fredpd_core/bridge/client.lua' first
        return require('client.main')
    end)
    package.path = savedPath
    for _, name in ipairs(MODULES) do package.loaded[name] = nil end
    if not ok then
        for _, g in ipairs(GLOBALS) do rawset(_G, g, env.saved[g]) end
        error(mod, 0)
    end
    env.M = mod
    --- The "Forcera dörr" option of a door's zone (normalised view), or nil.
    function env.option(doorId)
        local zone = rec.zones['fredpd_breach:door:' .. type(doorId) .. ':' .. tostring(doorId)]
        return zone and zone.options[1] or nil
    end
    function env.zoneCount()
        local n = 0
        for _ in pairs(rec.zones) do n = n + 1 end
        return n
    end
    return env
end

local function case(opts, fn)
    return function(t)
        local env = setup(opts)
        local ok, err = pcall(fn, t, env)
        for _, g in ipairs(GLOBALS) do rawset(_G, g, env.saved[g]) end
        if not ok then error(err, 0) end
    end
end

tests['zone names carry the id type, so qb-doorlock keys 1 and "1" never share a zone'] = case(nil, function(t, env)
    t.eq(env.M.zoneName(1), 'fredpd_breach:door:number:1')
    t.eq(env.M.zoneName('1'), 'fredpd_breach:door:string:1')
    t.ok(env.M.zoneName(1) ~= env.M.zoneName('1'))
end)

tests['one zone per door with "Forcera dörr", added once at start for a grant holder'] = case(nil, function(t, env)
    t.eq(env.zoneCount(), 2)
    local o = env.option(12)
    t.ok(o, 'zone of door 12')
    if env.stack == 'ox' then t.eq(o.name, 'fredpd_breach:ram') end
    t.eq(o.label, 'Forcera dörr')
    t.eq(o.distance, 2.0)
    local zone = env.rec.zones['fredpd_breach:door:number:12']
    if env.stack == 'qb' then
        t.eq({ zone.length, zone.width }, { 1.6, 1.6 }, 'qb-target box zone (PolyZone length/width)')
        t.eq(zone.opts.minZ, 30 - 1.3)
    else
        t.eq(zone.size, vec(1.6, 1.6, 2.6))
    end
    t.eq(zone.coords, vec(100, 200, 30), "centred on the doorlock's door coords")
    t.eq(#env.rec.adds, 2, 'nothing added again')
end)

tests['no grant tool:ram → no zones at all; zones appear when the grant arrives and go when it goes'] = case(
    { grants = false }, function(t, env)
        t.eq(env.zoneCount(), 0)
        env.rec.fireNet('fredpd:client:grantsChanged', { grants = { 'tool:*' }, denied = {} })
        t.eq(env.zoneCount(), 2, 'wildcard grant')
        env.rec.fireNet('fredpd:client:grantsChanged', { grants = { 'tool:ram' }, denied = { 'tool:ram' } })
        t.eq(env.zoneCount(), 0, 'denied grant')
        t.eq(#env.rec.removes, 2)
    end)

tests['canInteract: locked door + grant (hints only)'] = case(nil, function(t, env)
    t.eq(env.option(12).canInteract(0), true)
    t.eq(env.option(13).canInteract(0), false, 'unlocked door')
    env.rec.fireNet('fredpd:client:grantsChanged', { grants = { 'tool:ram', 'mdt_page:alerts' }, denied = {} })
    t.eq(env.option(12).canInteract(0), true)
end)

tests["door states follow the doorlock's client event (FredBridge.doorlock.onDoorChanged)"] = case(nil, function(t, env)
    env.rec.doorChanged(12, false)
    t.eq(env.option(12).canInteract(0), false)
    env.rec.doorChanged(13, true)
    t.eq(env.option(13).canInteract(0), true)
    -- a door made in game after the list was read: its first change re-reads the list once
    env.rec.doors[14] = { name = 'new', locked = true, coords = vec(1, 2, 3) }
    env.rec.doorChanged(14, true)
    t.ok(env.option(14), 'zone for the new door')
    t.eq(env.option(14).canInteract(0), true)
end)

tests['character load (server event) re-reads grants and, after the delay, the door list; logout drops zones'] = case(
    nil, function(t, env)
        env.rec.fireNet('fredpd:breach:client:character', false)
        t.eq(env.zoneCount(), 0)
        t.eq(env.option(12), nil)
        env.rec.doors[15] = { name = 'late', locked = true, coords = vec(5, 5, 5) }
        local asked = #env.awaits
        env.rec.fireNet('fredpd:breach:client:character', true)
        t.eq(env.awaits[asked + 1], { 'fredpd:getMyGrants' })
        t.eq(#env.timers, 1)
        t.eq(env.timers[1].ms, 2000)
        env.timers[1].fn()
        t.eq(env.zoneCount(), 3)
        t.ok(env.option(15))
    end)

tests['resource lifecycle: doorlock restart re-reads doors; target restart re-adds zones; own stop removes them'] = case(
    nil, function(t, env)
        env.rec.doors[16] = { name = 'x', locked = true, coords = vec(0, 0, 0) }
        env.handlers.onClientResourceStart(env.impl.doorlock)
        t.ok(env.option(16), 'new door after a doorlock restart')
        local adds = #env.rec.adds
        env.handlers.onClientResourceStop(env.impl.target)
        env.handlers.onClientResourceStart(env.impl.target)
        t.eq(#env.rec.adds, adds + 3, 'zones added again after a target restart')
        env.handlers.onClientResourceStop('fredpd_breach')
        t.eq(env.zoneCount(), 0)
    end)

tests['doorlock not running at start: no doors, no error; they come when it starts'] = case(
    { doorlockState = 'stopped' }, function(t, env)
        t.eq(env.zoneCount(), 0)
        env.rec.states[env.impl.doorlock] = 'started'
        env.handlers.onClientResourceStart(env.impl.doorlock)
        t.eq(env.zoneCount(), 2)
    end)

tests['breach flow: start → progress bar with prop and anim → finish → success'] = case(nil, function(t, env)
    env.answers['fredpd:breach:start'] = { ok = true, data = { token = ('a'):rep(32), doorId = 12, durationMs = 4000 } }
    env.answers['fredpd:breach:finish'] = { ok = true, data = { doorId = 12, evidence = {} } }
    env.option(12).select(0)
    t.eq(env.awaits[#env.awaits - 1], { 'fredpd:breach:start', 12 })
    t.eq(env.awaits[#env.awaits], { 'fredpd:breach:finish', ('a'):rep(32) })
    local p = env.progress[1]
    t.eq(p.duration, 4000)
    t.eq(p.label, 'Forcerar dörren…')
    t.eq(p.prop.model, 'prop_tool_shovel')
    t.eq(p.anim, { dict = 'missheistfbi3b_ig7', clip = 'lift_fibagent_loop', flag = 49 })
    t.eq(env.notifies[#env.notifies].type, 'success')
    t.eq(env.option(12).canInteract(0), false, 'door now open')
end)

tests['breach flow: a qb-doorlock string door id goes to the server as is'] = case(nil, function(t, env)
    env.rec.doors['mrpd-cells-1'] = { name = 'Cell 1', locked = true, coords = vec(3, 3, 3) }
    env.handlers.onClientResourceStart(env.impl.doorlock)
    env.answers['fredpd:breach:start'] = { ok = false, error = 'validation', reason = 'no_item' }
    env.option('mrpd-cells-1').select(0)
    t.eq(env.awaits[#env.awaits], { 'fredpd:breach:start', 'mrpd-cells-1' })
    t.eq(env.notifies[1].description, SV['breach.noItem'])
end)

tests['anim: falls back when the §5.6 clip is missing, none when no candidate exists'] = case(
    { anims = { ['melee@large_wpn@streamed_core'] = { ground_attack_on_spot = 1.2 } } }, function(t, env)
        t.eq(env.M.pickAnim(), { dict = 'melee@large_wpn@streamed_core', clip = 'ground_attack_on_spot', flag = 49 })
        env.anims['melee@large_wpn@streamed_core'] = nil
        t.eq(env.M.pickAnim(), nil)
    end)

tests['breach flow: server refusal and cancel show text; nothing else happens'] = case(nil, function(t, env)
    env.answers['fredpd:breach:start'] = { ok = false, error = 'validation', reason = 'too_far' }
    env.option(12).select(0)
    t.eq(#env.progress, 0)
    t.eq(env.notifies[1].description, SV['breach.tooFar'])
    env.answers['fredpd:breach:start'] = { ok = true, data = { token = ('b'):rep(32), doorId = 12, durationMs = 4000 } }
    env.progressResult = false
    env.option(12).select(0)
    t.eq(env.notifies[2].description, SV['breach.cancelled'])
    for _, a in ipairs(env.awaits) do t.ok(a[1] ~= 'fredpd:breach:finish', 'no finish after cancel') end
end)

tests['every server error code has a text'] = case(nil, function(t, env)
    local codes = {
        { 'unauthorized', 'grant' }, { 'unauthorized', 'off_duty' }, { 'rate_limited', 'rate' },
        { 'rate_limited', 'cooldown' }, { 'validation', 'no_item' }, { 'validation', 'not_locked' },
        { 'validation', 'too_far' }, { 'validation', 'too_early' }, { 'not_found', 'door' },
        { 'not_found', 'token' }, { 'expired', 'token' }, { 'unavailable', 'doorlock' },
        { 'validation', 'denied' },
    }
    for _, c in ipairs(codes) do
        local text = env.M.errorText({ error = c[1], reason = c[2] })
        t.ok(type(text) == 'string' and text ~= '' and not text:find('^[%w]+%.[%w.]+$'), c[1] .. '/' .. c[2] .. ' = ' .. tostring(text))
    end
    t.ok(env.M.errorText(nil) ~= 'errors.unknown')
    t.eq(env.M.errorText({ error = 'validation', reason = 'denied' }), SV['breach.notSupported'])
end)

return tests
