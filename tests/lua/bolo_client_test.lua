-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_bolo/client/main.lua with FiveM and ox_lib mocked and fredpd_core's REAL bridge/client.lua over the target
-- and framework mocks of the selected stack (FREDPD_STACK, tests/lua/dispatch_stack_test.lua: qb-target + qb-core
-- by default, ox_target + qbx_core with FREDPD_STACK=ox): the global vehicle option is added once (and again after a
-- target resource restart) and removed on stop, canInteract is police + on duty (FredBridge.framework.getJob),
-- onSelect sends only the network id, the result is a context menu (hit first, red, with a sound), errors are
-- Swedish notifications, and one check runs at a time. bolo_bridge_test.lua runs a smoke matrix over both stacks.
-- Run: lua5.4 tests/lua/run.lua bolo_client
local helper = require('helper')
local Stack = require('dispatch_stack_test')

local BOLO = './resources/[fredpd]/fredpd_bolo/'
local CLIENT = BOLO .. 'client/main.lua'
package.preload['@fredpd_core.shared.locale'] = package.preload['@fredpd_core.shared.locale']
    or function() return require('shared.locale') end
package.preload['@fredpd_core.shared.format'] = package.preload['@fredpd_core.shared.format']
    or function() return require('shared.format') end

local SV = (function()
    local dict = helper.readJson('locales/sv.json')
    for k, v in pairs(helper.readJson('locales/pending/bolo.json')) do
        if type(v) == 'table' and v.sv then dict[k] = v.sv end
    end
    return dict
end)()

local GLOBALS = { 'lib', 'exports', 'GetResourceState', 'AddEventHandler', 'CreateThread', 'DoesEntityExist',
    'NetworkGetEntityIsNetworked', 'NetworkGetNetworkIdFromEntity', 'PlaySoundFrontend', 'GetCurrentResourceName',
    'LoadResourceFile', 'locale', 'GetGameTimer' }
for _, g in ipairs(Stack.CLIENT_GLOBALS) do GLOBALS[#GLOBALS + 1] = g end

local HIT = {
    plate = 'ABC12D', model = 'sultan', owner = { citizenid = 'FPD10002', name = 'Erik Lindqvist' },
    bolo = { id = 1, kind = 'vehicle', plate = 'ABC12D', subject = 'ABC12D · sultan', reason = 'Rån', level = 0,
        issuedBy = { citizenid = 'BOL10001', displayName = 'Anna B.', callsign = 'IGV-07', unit = 'igv' },
        createdAt = '2026-09-29T10:00:00Z', expiresAt = '2026-09-29T12:00:00Z', active = true },
    checkedAt = '2026-09-29T10:05:00Z',
}

local function policeJob() return { name = 'police', label = 'Polis', type = 'leo', onduty = true, grade = { level = 1 } } end

--- opts = { stack = 'qb'|'ox' (default FREDPD_STACK), targetState = state of the target resource at start }.
local function withClient(fn, opts)
    opts = opts or {}
    local stack = opts.stack or Stack.current()
    local rec = Stack.client(stack, { job = policeJob(),
        states = { [Stack.IMPL[stack].target] = opts.targetState or 'started' } })
    local saved = {}
    for _, n in ipairs(GLOBALS) do saved[n] = { rawget(_G, n) } end
    local env = { rec = rec, stack = stack, target = Stack.IMPL[stack].target, calls = {}, notifies = {},
        contexts = {}, shown = {}, sounds = {}, handlers = {}, reply = nil,
        entities = { [5001] = 77, [6000] = 90 }, localOnly = { [6000] = true }, now = 1000 }
    env.adds, env.removes = rec.adds, rec.removes
    local globals = {
        exports = setmetatable({}, { __index = function(_, res)
            return rec.resources[res] or setmetatable({}, { __index = function(_, k)
                return function() error(('No such export %s in resource %s'):format(k, res), 2) end
            end })
        end }),
        AddEventHandler = function(name, fn) env.handlers[name] = fn end,
        CreateThread = function(f) f() end,
        GetGameTimer = function() return env.now end,
        DoesEntityExist = function(e) return env.entities[e] ~= nil end,
        NetworkGetEntityIsNetworked = function(e) return env.entities[e] ~= nil and not env.localOnly[e] end,
        NetworkGetNetworkIdFromEntity = function(e) return env.entities[e] end,
        PlaySoundFrontend = function(...) env.sounds[#env.sounds + 1] = { ... } end,
        GetCurrentResourceName = function() return 'fredpd_bolo' end,
        locale = function(key) return SV[key] or key end,
        lib = {
            notify = function(data) env.notifies[#env.notifies + 1] = data end,
            registerContext = function(ctx) env.contexts[#env.contexts + 1] = ctx end,
            showContext = function(id) env.shown[#env.shown + 1] = id end,
            getOpenContextMenu = function() return env.open end,
            hideContext = function() env.hidden = true end,
            callback = {
                await = function(name, delay, ...)
                    env.calls[#env.calls + 1] = { name = name, delay = delay, args = { ... }, n = select('#', ...) }
                    if type(env.reply) == 'function' then return env.reply() end
                    return env.reply
                end,
            },
        },
    }
    for k, v in pairs(globals) do rawset(_G, k, v) end
    local savedPath = package.path
    package.path = BOLO .. '?.lua;' .. package.path
    package.loaded['shared.view'] = nil
    local ok, err = pcall(function()
        Stack.loadClientBridge(rec) -- client_scripts: '@fredpd_core/bridge/client.lua' first
        env.M = dofile(CLIENT)
        --- The global vehicle options added so far (normalised view, whatever the target resource).
        function env.option(i) return rec.adds[i or #rec.adds] end
        fn(env)
    end)
    package.loaded['shared.view'] = nil
    package.path = savedPath
    for n, v in pairs(saved) do rawset(_G, n, v[1]) end
    if not ok then error(err, 0) end
end

local tests = {}

tests['option: added once at start, Swedish label, whole vehicle, 3 m; police on duty only'] = function(t)
    withClient(function(env)
        t.eq(#env.adds, 1)
        local opt = env.option(1)
        t.eq(opt.kind, 'globalVehicle')
        if env.stack == 'ox' then t.eq(opt.name, 'fredpd_bolo:checkPlate') end
        t.eq(opt.label, 'Kontrollera registreringsskylt')
        t.eq(opt.distance, 3.0)
        t.eq(opt.raw.bones, nil)
        t.eq(opt.canInteract(5001), true)
        env.rec.setDuty(false)
        t.eq(opt.canInteract(5001), false, 'off duty')
        env.rec.setDuty(true)
        env.rec.setJob({ name = 'mechanic', type = 'civ', onduty = true, grade = { level = 0 } })
        t.eq(opt.canInteract(5001), false, 'not police')
        env.rec.setJob({ name = 'bcso', type = 'leo', onduty = true, grade = { level = 0 } })
        t.eq(opt.canInteract(5001), true, 'any leo job (sheriff)')
        env.rec.unload()
        t.eq(opt.canInteract(5001), false, 'no character')
    end)
end

tests['check: only the network id goes to the server; hit menu first, red, sound; clear without sound'] = function(t)
    withClient(function(env)
        local opt = env.option(1)
        env.reply = HIT
        opt.select(5001)
        t.eq(#env.calls, 1)
        t.eq(env.calls[1].name, 'fredpd:bolo:plateCheck')
        t.eq(env.calls[1].delay, false)
        t.eq(env.calls[1].n, 1, 'no plate string from the client')
        t.eq(env.calls[1].args[1], 77)
        local ctx = env.contexts[1]
        t.eq(ctx.id, 'fredpd_bolo_platecheck')
        t.eq(ctx.title, 'Skyltkontroll: ABC12D')
        t.eq(ctx.options[1].title, 'Träff på efterlysning')
        t.eq(ctx.options[1].iconColor, '#e03131')
        t.eq(ctx.options[1].metadata[3], { label = 'Gäller till', value = '2026-09-29 14:00' },
            'expiry in Europe/Stockholm via fredpd_core formats')
        t.eq(env.shown, { 'fredpd_bolo_platecheck' })
        t.eq(#env.sounds, 1)

        env.reply = { plate = 'QRS45T', model = 'blista', checkedAt = '2026-09-29T10:05:00Z' }
        opt.select(5001)
        t.eq(env.contexts[2].options[1].title, 'QRS45T: ingen aktiv efterlysning.')
        t.eq(#env.sounds, 1)
    end)
end

tests['check: errors become Swedish notifications; local entities are not sent'] = function(t)
    withClient(function(env)
        local opt = env.option(1)
        env.reply = { error = 'unauthorized', reason = 'off_duty' }
        opt.select(5001)
        t.eq(env.notifies[1], { type = 'error', title = 'Skyltkontroll', description = 'Du är inte i tjänst.' })
        env.reply = { error = 'not_found', reason = 'no_plate' }
        opt.select(5001)
        t.eq(env.notifies[2].description, 'Fordonet saknar läsbar skylt.')
        env.reply = nil
        opt.select(5001)
        t.eq(env.notifies[3].description, 'Något gick fel. Försök igen.', 'no answer')
        env.reply = function() error('callback timed out') end
        opt.select(5001)
        t.eq(env.notifies[4].description, 'Något gick fel. Försök igen.')

        local calls = #env.calls
        opt.select(6000) -- exists, but only on this client
        opt.select(6001) -- gone
        opt.select(0)
        t.eq(#env.calls, calls, 'nothing sent for a local or missing entity')
        t.eq(env.notifies[5].description, 'Uppgiften hittades inte.')
        t.eq(#env.notifies, 7)
        t.eq(#env.contexts, 0)
    end)
end

tests['check: one request at a time'] = function(t)
    withClient(function(env)
        local opt = env.option(1)
        env.reply = function()
            opt.select(5001) -- a second click while the first waits
            return HIT
        end
        opt.select(5001)
        t.eq(#env.calls, 1)
        t.eq(#env.contexts, 1)

        -- a callback that never answers blocks the option for BUSY_STALE_MS only
        env.reply = function() coroutine.yield() end
        local hung = coroutine.create(function() opt.select(5001) end)
        coroutine.resume(hung)
        t.eq(#env.calls, 2)
        env.reply = HIT
        opt.select(5001)
        t.eq(#env.calls, 2, 'still in flight')
        env.now = env.now + env.M.BUSY_STALE_MS
        opt.select(5001)
        t.eq(#env.calls, 3, 'stale busy flag released')
        t.eq(#env.contexts, 2)
    end)
end

tests['lifecycle: removed on stop, re-added when the target resource restarts'] = function(t)
    withClient(function(env)
        env.handlers.onClientResourceStop(env.target)
        env.handlers.onClientResourceStart(env.target)
        t.eq(#env.adds, 2, 're-added after a target restart')
        env.handlers.onClientResourceStart('something_else')
        t.eq(#env.adds, 2)
        env.open = 'fredpd_bolo_platecheck'
        env.handlers.onClientResourceStop('fredpd_bolo')
        t.eq(#env.removes, 1)
        t.eq(env.removes[1].kind, 'globalVehicle')
        t.eq(env.removes[1].labels, { env.stack == 'qb' and 'Kontrollera registreringsskylt' or 'fredpd_bolo:checkPlate' },
            'qb-target removes by label, ox_target by name')
        t.eq(env.hidden, true, 'an open result menu is closed')
        env.handlers.onClientResourceStop('fredpd_bolo')
        t.eq(#env.removes, 1, 'removed once')
    end)
end

tests['lifecycle: target resource not running at start -> added when it starts, no warning'] = function(t)
    withClient(function(env)
        t.eq(#env.adds, 0)
        t.eq(#env.rec.printed, 0, 'not started yet is not an error (the option waits for it)')
        env.rec.states[env.target] = 'started'
        env.handlers.onClientResourceStart(env.target)
        t.eq(#env.adds, 1)
        env.handlers.onClientResourceStop('fredpd_bolo')
        t.eq(#env.removes, 1)
    end, { targetState = 'missing' })
end

return tests
