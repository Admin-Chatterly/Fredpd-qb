-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_bolo/client/main.lua with FiveM, ox_lib, ox_target and qbx mocked: the global vehicle option is added once
-- (and again after an ox_target restart) and removed on stop, canInteract is police + on duty, onSelect sends only
-- the network id, the result is a context menu (hit first, red, with a sound), errors are Swedish notifications,
-- and one check runs at a time.
-- Run: lua5.4 tests/lua/run.lua bolo_client
local helper = require('helper')

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

local GLOBALS = { 'lib', 'exports', 'QBX', 'GetResourceState', 'AddEventHandler', 'CreateThread', 'DoesEntityExist',
    'NetworkGetEntityIsNetworked', 'NetworkGetNetworkIdFromEntity', 'PlaySoundFrontend', 'GetCurrentResourceName',
    'LoadResourceFile', 'locale', 'GetGameTimer' }

local HIT = {
    plate = 'ABC12D', model = 'sultan', owner = { citizenid = 'FPD10002', name = 'Erik Lindqvist' },
    bolo = { id = 1, kind = 'vehicle', plate = 'ABC12D', subject = 'ABC12D · sultan', reason = 'Rån', level = 0,
        issuedBy = { citizenid = 'BOL10001', displayName = 'Anna B.', callsign = 'IGV-07', unit = 'igv' },
        createdAt = '2026-09-29T10:00:00Z', expiresAt = '2026-09-29T12:00:00Z', active = true },
    checkedAt = '2026-09-29T10:05:00Z',
}

local function withClient(fn, opts)
    opts = opts or {}
    local saved = {}
    for _, n in ipairs(GLOBALS) do saved[n] = { rawget(_G, n) } end
    local env = { adds = {}, removes = {}, calls = {}, notifies = {}, contexts = {}, shown = {}, sounds = {},
        handlers = {}, states = { ox_target = opts.oxTarget or 'started' }, reply = nil,
        entities = { [5001] = 77, [6000] = 90 }, localOnly = { [6000] = true },
        job = { name = 'police', type = 'leo', onduty = true }, now = 1000 }
    local globals = {
        exports = {
            ox_target = {
                addGlobalVehicle = function(_, options) env.adds[#env.adds + 1] = options end,
                removeGlobalVehicle = function(_, names) env.removes[#env.removes + 1] = names end,
            },
        },
        QBX = { PlayerData = { job = env.job } },
        GetResourceState = function(name) return env.states[name] or 'missing' end,
        AddEventHandler = function(name, fn) env.handlers[name] = fn end,
        CreateThread = function(f) f() end,
        GetGameTimer = function() return env.now end,
        DoesEntityExist = function(e) return env.entities[e] ~= nil end,
        NetworkGetEntityIsNetworked = function(e) return env.entities[e] ~= nil and not env.localOnly[e] end,
        NetworkGetNetworkIdFromEntity = function(e) return env.entities[e] end,
        PlaySoundFrontend = function(...) env.sounds[#env.sounds + 1] = { ... } end,
        GetCurrentResourceName = function() return 'fredpd_bolo' end,
        LoadResourceFile = function(res, path)
            if res == 'fredpd_core' and path == 'config/formats.json' then return helper.readFile('config/formats.json') end
            return nil
        end,
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
        env.M = dofile(CLIENT)
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
        local opt = env.adds[1][1]
        t.eq(#env.adds[1], 1)
        t.eq(opt.name, 'fredpd_bolo:checkPlate')
        t.eq(opt.label, 'Kontrollera registreringsskylt')
        t.eq(opt.distance, 3.0)
        t.eq(opt.bones, nil)
        t.eq(opt.canInteract(5001, 1.0), true)
        env.job.onduty = false
        t.eq(opt.canInteract(5001, 1.0), false, 'off duty')
        env.job.onduty = true
        env.job.type, env.job.name = 'civ', 'mechanic'
        t.eq(opt.canInteract(5001, 1.0), false, 'not police')
        env.job.type = 'leo'
        t.eq(opt.canInteract(5001, 1.0), true, 'any leo job (sheriff)')
        QBX.PlayerData = {}
        t.eq(opt.canInteract(5001, 1.0), false, 'no character')
    end)
end

tests['check: only the network id goes to the server; hit menu first, red, sound; clear without sound'] = function(t)
    withClient(function(env)
        local opt = env.adds[1][1]
        env.reply = HIT
        opt.onSelect({ entity = 5001, coords = { x = 1, y = 2, z = 3 }, distance = 1.2 })
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
        opt.onSelect({ entity = 5001 })
        t.eq(env.contexts[2].options[1].title, 'QRS45T: ingen aktiv efterlysning.')
        t.eq(#env.sounds, 1)
    end)
end

tests['check: errors become Swedish notifications; local entities are not sent'] = function(t)
    withClient(function(env)
        local opt = env.adds[1][1]
        env.reply = { error = 'unauthorized', reason = 'off_duty' }
        opt.onSelect({ entity = 5001 })
        t.eq(env.notifies[1], { type = 'error', title = 'Skyltkontroll', description = 'Du är inte i tjänst.' })
        env.reply = { error = 'not_found', reason = 'no_plate' }
        opt.onSelect({ entity = 5001 })
        t.eq(env.notifies[2].description, 'Fordonet saknar läsbar skylt.')
        env.reply = nil
        opt.onSelect({ entity = 5001 })
        t.eq(env.notifies[3].description, 'Något gick fel. Försök igen.', 'no answer')
        env.reply = function() error('callback timed out') end
        opt.onSelect({ entity = 5001 })
        t.eq(env.notifies[4].description, 'Något gick fel. Försök igen.')

        local calls = #env.calls
        opt.onSelect({ entity = 6000 }) -- exists, but only on this client
        opt.onSelect({ entity = 6001 }) -- gone
        opt.onSelect({ entity = 0 })
        t.eq(#env.calls, calls, 'nothing sent for a local or missing entity')
        t.eq(env.notifies[5].description, 'Uppgiften hittades inte.')
        t.eq(#env.notifies, 7)
        t.eq(#env.contexts, 0)
    end)
end

tests['check: one request at a time'] = function(t)
    withClient(function(env)
        local opt = env.adds[1][1]
        env.reply = function()
            opt.onSelect({ entity = 5001 }) -- a second click while the first waits
            return HIT
        end
        opt.onSelect({ entity = 5001 })
        t.eq(#env.calls, 1)
        t.eq(#env.contexts, 1)

        -- a callback that never answers blocks the option for BUSY_STALE_MS only
        env.reply = function() coroutine.yield() end
        local hung = coroutine.create(function() opt.onSelect({ entity = 5001 }) end)
        coroutine.resume(hung)
        t.eq(#env.calls, 2)
        env.reply = HIT
        opt.onSelect({ entity = 5001 })
        t.eq(#env.calls, 2, 'still in flight')
        env.now = env.now + env.M.BUSY_STALE_MS
        opt.onSelect({ entity = 5001 })
        t.eq(#env.calls, 3, 'stale busy flag released')
        t.eq(#env.contexts, 2)
    end)
end

tests['lifecycle: removed on stop, re-added when ox_target restarts'] = function(t)
    withClient(function(env)
        env.handlers.onClientResourceStop('ox_target')
        env.handlers.onClientResourceStart('ox_target')
        t.eq(#env.adds, 2, 're-added after an ox_target restart')
        env.handlers.onClientResourceStart('something_else')
        t.eq(#env.adds, 2)
        env.open = 'fredpd_bolo_platecheck'
        env.handlers.onClientResourceStop('fredpd_bolo')
        t.eq(env.removes, { 'fredpd_bolo:checkPlate' })
        t.eq(env.hidden, true, 'an open result menu is closed')
        env.handlers.onClientResourceStop('fredpd_bolo')
        t.eq(#env.removes, 1, 'removed once')
    end)
end

tests['lifecycle: ox_target not running at start -> added when it starts'] = function(t)
    withClient(function(env)
        t.eq(#env.adds, 0)
        env.states.ox_target = 'started'
        env.handlers.onClientResourceStart('ox_target')
        t.eq(#env.adds, 1)
        env.handlers.onClientResourceStop('fredpd_bolo')
        t.eq(env.removes, { 'fredpd_bolo:checkPlate' })
    end, { oxTarget = 'missing' })
end

return tests
