-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_breach client (task 6.1) with FiveM mocked: the ox_target option is added once at start (no per-frame
-- work outside canInteract), canInteract hints (door tagged by ox_doorlock + locked, pd_ram, grant tool:ram), the
-- door list from 'ox_doorlock:getDoors' kept current by ox_doorlock's own client events, the start → progress →
-- finish flow (prop + anim only inside lib.progressBar, anim fallback), and every error code has Swedish text.
-- Run: lua5.4 tests/lua/run.lua breach_client
local helper = require('helper')

local tests = {}

local BREACH = './resources/[fredpd]/fredpd_breach/'
local MODULES = { 'config', 'client.main' }
local GLOBALS = { 'lib', 'exports', 'RegisterNetEvent', 'AddEventHandler', 'CreateThread', 'GetCurrentResourceName',
    'locale', 'vec3', 'Entity', 'DoesAnimDictExist', 'GetAnimDuration', 'RemoveAnimDict' }

package.preload['@fredpd_core.shared.locale'] = function() return require('shared.locale') end
package.preload['@fredpd_core.shared.grants'] = function() return require('shared.grants') end

local SV = (function()
    local dict = helper.readJson('locales/sv.json')
    for k, v in pairs(helper.readJson('locales/pending/breach.json')) do dict[k] = v.sv end
    return dict
end)()

local function setup(opts)
    opts = opts or {}
    local env = {
        saved = {}, targets = {}, netEvents = {}, handlers = {}, notifies = {}, progress = {}, awaits = {},
        entities = { [500] = { doorId = 12 }, [501] = { doorId = 13 }, [502] = {} },
        ram = 1,
        grants = { grants = { 'tool:ram' }, denied = {}, tier = 0, units = {} },
        doors = { [12] = { id = 12, state = 1 }, [13] = { id = 13, state = 0 } },
        anims = opts.anims or { missheistfbi3b_ig7 = { lift_fibagent_loop = 3.0 } },
        progressResult = true,
        answers = {},
    }
    for _, g in ipairs(GLOBALS) do env.saved[g] = rawget(_G, g) end
    _G.lib = {
        notify = function(n) env.notifies[#env.notifies + 1] = n end,
        callback = setmetatable({
            await = function(name, _, ...)
                env.awaits[#env.awaits + 1] = { name, ... }
                if name == 'fredpd:getMyGrants' then return env.grants end
                return env.answers[name]
            end,
        }, { __call = function(_, name, _, cb)
            if name == 'ox_doorlock:getDoors' then cb(env.doors) end
        end }),
        progressBar = function(data)
            env.progress[#env.progress + 1] = data
            return env.progressResult
        end,
        requestAnimDict = function(dict) return dict end,
    }
    _G.exports = setmetatable({}, { __index = function(_, name)
        if name == 'ox_target' then
            return {
                addGlobalObject = function(_, options) env.targets[#env.targets + 1] = options end,
                removeGlobalObject = function() end,
            }
        elseif name == 'ox_inventory' then
            return { GetItemCount = function(_, item) return item == 'pd_ram' and env.ram or 0 end }
        end
    end })
    _G.RegisterNetEvent = function(name, fn) env.netEvents[name] = fn end
    _G.AddEventHandler = function(name, fn) env.handlers[name] = fn end
    _G.CreateThread = function(fn) fn() end
    _G.GetCurrentResourceName = function() return 'fredpd_breach' end
    _G.locale = function(key) return SV[key] or key end
    _G.vec3 = function(x, y, z) return { x = x, y = y, z = z } end
    _G.Entity = function(e) return { state = env.entities[e] or {} } end
    _G.DoesAnimDictExist = function(dict) return env.anims[dict] ~= nil end
    _G.GetAnimDuration = function(dict, clip) return (env.anims[dict] or {})[clip] or 0 end
    _G.RemoveAnimDict = function() end

    for _, name in ipairs(MODULES) do package.loaded[name] = nil end
    local savedPath = package.path
    package.path = BREACH .. '?.lua;' .. package.path
    local ok, mod = pcall(require, 'client.main')
    package.path = savedPath
    for _, name in ipairs(MODULES) do package.loaded[name] = nil end
    if not ok then
        for _, g in ipairs(GLOBALS) do rawset(_G, g, env.saved[g]) end
        error(mod, 0)
    end
    env.M = mod
    env.option = env.targets[1] and env.targets[1][1]
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

tests['one global object option "Forcera dörr", added once at start'] = case(nil, function(t, env)
    t.eq(#env.targets, 1)
    t.eq(#env.targets[1], 1)
    t.eq(env.option.name, 'fredpd_breach:ram')
    t.eq(env.option.label, 'Forcera dörr')
    t.ok(type(env.option.canInteract) == 'function' and type(env.option.onSelect) == 'function')
end)

tests['canInteract: locked ox_doorlock door + pd_ram + grant tool:ram'] = case(nil, function(t, env)
    t.eq(env.option.canInteract(500), true)
    t.eq(env.option.canInteract(501), false, 'unlocked door')
    t.eq(env.option.canInteract(502), false, 'not an ox_doorlock door')
    t.eq(env.option.canInteract(0), false)
    env.ram = 0
    t.eq(env.option.canInteract(500), false, 'no ram')
    env.ram = 1
    env.netEvents['fredpd:client:grantsChanged']({ grants = { 'tool:ram' }, denied = { 'tool:ram' } })
    t.eq(env.option.canInteract(500), false, 'denied grant')
    env.netEvents['fredpd:client:grantsChanged']({ grants = { 'tool:*' }, denied = {} })
    t.eq(env.option.canInteract(500), true, 'wildcard grant')
    env.netEvents['QBCore:Client:OnPlayerUnload']()
    t.eq(env.option.canInteract(500), false, 'no grants after logout')
end)

tests["door list follows ox_doorlock's client events"] = case(nil, function(t, env)
    env.netEvents['ox_doorlock:setState'](12, 0, 3)
    t.eq(env.option.canInteract(500), false)
    env.netEvents['ox_doorlock:setState'](13, 1)
    t.eq(env.option.canInteract(501), true)
    env.netEvents['ox_doorlock:editDoorlock'](13, nil)
    t.eq(env.option.canInteract(501), false, 'deleted door')
    env.netEvents['ox_doorlock:editDoorlock'](13, { id = 13, state = 1 })
    t.eq(env.option.canInteract(501), true, 'edited door')
end)

tests['breach flow: start → progress bar with prop and anim → finish → success'] = case(nil, function(t, env)
    env.answers['fredpd:breach:start'] = { ok = true, data = { token = ('a'):rep(32), doorId = 12, durationMs = 4000 } }
    env.answers['fredpd:breach:finish'] = { ok = true, data = { doorId = 12, evidence = {} } }
    env.option.onSelect({ entity = 500 })
    t.eq(env.awaits[#env.awaits - 1], { 'fredpd:breach:start', 12 })
    t.eq(env.awaits[#env.awaits], { 'fredpd:breach:finish', ('a'):rep(32) })
    local p = env.progress[1]
    t.eq(p.duration, 4000)
    t.eq(p.label, 'Forcerar dörren…')
    t.eq(p.prop.model, 'prop_tool_shovel')
    t.eq(p.anim, { dict = 'missheistfbi3b_ig7', clip = 'lift_fibagent_loop', flag = 49 })
    t.eq(env.notifies[#env.notifies].type, 'success')
    t.eq(env.option.canInteract(500), false, 'door now open')
end)

tests['anim: falls back when the §5.6 clip is missing, none when no candidate exists'] = case(
    { anims = { ['melee@large_wpn@streamed_core'] = { ground_attack_on_spot = 1.2 } } }, function(t, env)
        t.eq(env.M.pickAnim(), { dict = 'melee@large_wpn@streamed_core', clip = 'ground_attack_on_spot', flag = 49 })
        env.anims['melee@large_wpn@streamed_core'] = nil
        t.eq(env.M.pickAnim(), nil)
    end)

tests['breach flow: server refusal and cancel show text; nothing else happens'] = case(nil, function(t, env)
    env.answers['fredpd:breach:start'] = { ok = false, error = 'validation', reason = 'too_far' }
    env.option.onSelect({ entity = 500 })
    t.eq(#env.progress, 0)
    t.eq(env.notifies[1].description, SV['breach.tooFar'])
    env.answers['fredpd:breach:start'] = { ok = true, data = { token = ('b'):rep(32), doorId = 12, durationMs = 4000 } }
    env.progressResult = false
    env.option.onSelect({ entity = 500 })
    t.eq(env.notifies[2].description, SV['breach.cancelled'])
    for _, a in ipairs(env.awaits) do t.ok(a[1] ~= 'fredpd:breach:finish', 'no finish after cancel') end
end)

tests['every server error code has a text'] = case(nil, function(t, env)
    local codes = {
        { 'unauthorized', 'grant' }, { 'unauthorized', 'off_duty' }, { 'rate_limited', 'rate' },
        { 'rate_limited', 'cooldown' }, { 'validation', 'no_item' }, { 'validation', 'not_locked' },
        { 'validation', 'too_far' }, { 'validation', 'too_early' }, { 'not_found', 'door' },
        { 'not_found', 'token' }, { 'expired', 'token' }, { 'unavailable', 'doorlock' },
    }
    for _, c in ipairs(codes) do
        local text = env.M.errorText({ error = c[1], reason = c[2] })
        t.ok(type(text) == 'string' and text ~= '' and not text:find('^[%w]+%.[%w.]+$'), c[1] .. '/' .. c[2] .. ' = ' .. tostring(text))
    end
    t.ok(env.M.errorText(nil) ~= 'errors.unknown')
end)

return tests
