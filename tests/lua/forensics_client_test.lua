-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_forensics client/main.lua with ox_lib, ox_target, evidences and natives mocked: lab zone (Analysera option
-- only inside, local laptop prop), locker target, "Koppla till ärende" offers (dialog at once, or waiting while the
-- evidences laptop holds NUI focus), error texts, cleanup. The REAL fredpd_core bridge/client.lua is loaded first (as
-- the fxmanifest's '@fredpd_core/bridge/client.lua' is), so the targets go through FredBridge.target over the ox_target
-- mock; tests 08-10 cover the bridge switch (qb-target stack: nothing registered; enable event; late ox start).
-- Run: lua5.4 tests/lua/run.lua forensics_client
local helper = require('helper')

local FORENSICS = './resources/[fredpd]/fredpd_forensics/'
local CORE = './resources/[fredpd]/fredpd_core/'
local MODULES = { 'config', 'client.main' }
local GLOBALS = { 'lib', 'exports', 'GetHashKey', 'IsNuiFocused', 'GetResourceState', 'RegisterNetEvent',
    'AddEventHandler', 'CreateThread', 'GetCurrentResourceName', 'locale', 'vec3', 'vec4', 'CreateObject',
    'SetEntityHeading', 'FreezeEntityPosition', 'SetModelAsNoLongerNeeded', 'PlayEntityAnim', 'DoesEntityExist',
    'DeleteEntity', 'FredBridge', 'GetConvar', 'LoadResourceFile', 'print' }

package.preload['@fredpd_core.shared.locale'] = function() return require('shared.locale') end

local SV = (function()
    local dict = helper.readJson('locales/sv.json')
    for k, v in pairs(helper.readJson('locales/pending/forensics.json')) do
        if type(v) == 'table' and v.sv then dict[k] = v.sv end
    end
    return dict
end)()

local tests = {}

--- opts = { stack = 'ox' (default) | 'qb', convar = 'on' (default) | 'off' }
local function makeEnv(opts)
    opts = opts or {}
    local qb = opts.stack == 'qb'
    local env = {
        zones = {}, models = {}, removed = {}, boxes = {}, notifies = {}, dialogs = {}, awaits = {}, contexts = {},
        shown = {}, netEvents = {}, handlers = {}, objects = {}, deleted = {}, opened = {}, stashes = {},
        focused = false, dialogAnswer = { 'K-123-26' }, awaitAnswer = { ok = true, tag = 'B-K-123-26-001',
            caseNumber = 'K-123-26' }, openLaptopResult = true, resources = { evidences = 'started' },
        nextEntity = 500, printed = {}, qbTarget = {},
        convars = { fredpd_bridge_target = qb and 'qb-target' or 'ox_target', fredpd_bridge_framework = 'qb-core',
            fredpd_bridge_doorlock = qb and 'qb-doorlock' or 'ox_doorlock', fredpd_forensics_evidence = opts.convar or 'on' },
    }
    if qb then
        env.resources['qb-target'], env.resources['qb-inventory'] = 'started', 'started'
    else
        env.resources.ox_target = 'started'
        if opts.oxInventory ~= false then env.resources.ox_inventory = 'started' end
    end
    env.globals = {
        GetHashKey = function(name) return 'hash:' .. name end,
        GetConvar = function(name, default) return env.convars[name] or default end,
        print = function(line) env.printed[#env.printed + 1] = line end,
        LoadResourceFile = function(res, path) -- bridge/client.lua reads its implementation files from fredpd_core
            if res ~= 'fredpd_core' then return nil end
            local f = io.open(CORE .. path, 'rb')
            if not f then return nil end
            local text = f:read('a')
            f:close()
            return text
        end,
        IsNuiFocused = function() return env.focused end,
        GetResourceState = function(name) return env.resources[name] or 'missing' end,
        RegisterNetEvent = function(name, fn) env.netEvents[name] = fn end,
        AddEventHandler = function(name, fn) env.handlers[name] = fn end,
        CreateThread = function(fn) fn() end,
        GetCurrentResourceName = function() return 'fredpd_forensics' end,
        locale = function(key) return SV[key] or key end,
        vec3 = function(x, y, z) return { x = x, y = y, z = z } end,
        vec4 = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end,
        CreateObject = function(model, x, y, z, networked)
            env.nextEntity = env.nextEntity + 1
            env.objects[env.nextEntity] = { model = model, x = x, y = y, z = z, networked = networked }
            return env.nextEntity
        end,
        SetEntityHeading = function(e, h) env.objects[e].heading = h end,
        FreezeEntityPosition = function(e, f) env.objects[e].frozen = f end,
        SetModelAsNoLongerNeeded = function() end,
        PlayEntityAnim = function(e) env.objects[e].anim = true end,
        DoesEntityExist = function(e) return env.objects[e] ~= nil end,
        DeleteEntity = function(e)
            env.objects[e] = nil
            env.deleted[#env.deleted + 1] = e
        end,
        exports = {
            -- ox_target client/api.lua:235-272 (addModel/removeModel take lists), :54-61 (addBoxZone -> id)
            ox_target = {
                addModel = function(_, models, options)
                    for _, model in ipairs(models) do
                        for _, o in ipairs(options) do env.models[#env.models + 1] = { model = model, option = o } end
                    end
                end,
                removeModel = function(_, models, names)
                    for _, model in ipairs(models) do
                        for _, name in ipairs(names) do
                            env.removed[#env.removed + 1] = { model = model, name = name }
                            for i = #env.models, 1, -1 do
                                if env.models[i].model == model and env.models[i].option.name == name then
                                    table.remove(env.models, i)
                                end
                            end
                        end
                    end
                end,
                addBoxZone = function(_, zone)
                    env.boxes[#env.boxes + 1] = zone
                    return #env.boxes
                end,
            },
            ['qb-target'] = setmetatable({}, { __index = function(_, k)
                return function(...) env.qbTarget[#env.qbTarget + 1] = { k, ... } end
            end }),
            evidences = {
                openLaptop = function(_, entity)
                    env.opened[#env.opened + 1] = entity
                    if env.openLaptopResult == 'error' then error('No such export openLaptop in resource evidences') end
                    return env.openLaptopResult
                end,
            },
            ox_inventory = {
                openInventory = function(_, kind, id) env.stashes[#env.stashes + 1] = { kind, id } end,
            },
        },
        lib = {
            zones = { box = function(z) env.zones[#env.zones + 1] = z; return z end },
            notify = function(n) env.notifies[#env.notifies + 1] = n end,
            inputDialog = function(title, rows)
                env.dialogs[#env.dialogs + 1] = { title = title, rows = rows }
                return env.dialogAnswer
            end,
            callback = {
                await = function(name, _, data)
                    env.awaits[#env.awaits + 1] = { name = name, data = data }
                    return env.awaitAnswer
                end,
            },
            registerContext = function(c) env.contexts[#env.contexts + 1] = c end,
            showContext = function(id) env.shown[#env.shown + 1] = id end,
            requestModel = function(m) return m end,
            requestAnimDict = function(d) return d end,
        },
    }

    function env.option(name)
        for _, m in ipairs(env.models) do
            if m.option.name == name then return m.option, m.model end
        end
    end

    function env.lastNotify() return env.notifies[#env.notifies] end
    return env
end

local function withClient(t, fn, opts)
    local saved = {}
    for _, n in ipairs(GLOBALS) do saved[n] = { rawget(_G, n) } end
    local env = makeEnv(opts)
    for k, v in pairs(env.globals) do rawset(_G, k, v) end
    rawset(_G, 'FredBridge', nil)
    for _, name in ipairs(MODULES) do package.loaded[name] = nil end
    local savedPath = package.path
    package.path = FORENSICS .. '?.lua;' .. package.path
    local ok, err = pcall(function()
        env.FB = dofile(CORE .. 'bridge/client.lua') -- fxmanifest: '@fredpd_core/bridge/client.lua' first
        local client = require('client.main')
        package.path = savedPath
        fn(t, env, client)
    end)
    package.path = savedPath
    for _, name in ipairs(MODULES) do package.loaded[name] = nil end
    for n, v in pairs(saved) do rawset(_G, n, v[1]) end
    if not ok then error(err, 0) end
end

tests['01 start: lab zone, locker target, the waiting-offer laptop option and the net event'] = function(t)
    withClient(t, function(_, env)
        t.eq(#env.zones, 1)
        t.eq(env.zones[1].coords, { x = 474.6, y = -990.4, z = 26.3 })
        t.eq(env.zones[1].size, { x = 6.0, y = 5.0, z = 3.0 })
        t.eq(env.option('fredpd_forensics:analyse'), nil, 'Analysera only inside the lab')
        t.eq(#env.boxes, 1)
        local locker = env.boxes[1].options[1]
        t.eq(locker.label, 'Öppna bevisförrådet')
        locker.onSelect()
        t.eq(env.stashes, { { 'stash', 'evidence_locker_mrpd' } })
        local link, model = env.option('fredpd_forensics:link')
        t.eq(model, 'hash:p_laptop_02_s')
        t.eq(link.label, 'Koppla till ärende')
        t.eq(link.canInteract(), false, 'no offer waiting')
        t.ok(env.netEvents['fredpd:forensics:client:offerLink'])
    end)
end

tests['02 lab: entering adds Analysera + a local laptop, which opens evidences; leaving removes both'] = function(t)
    withClient(t, function(_, env)
        local zone = env.zones[1]
        zone.onEnter()
        local analyse, model = env.option('fredpd_forensics:analyse')
        t.eq(model, 'hash:p_laptop_02_s')
        t.eq(analyse.label, 'Analysera')
        local entity = next(env.objects)
        local obj = env.objects[entity]
        t.eq({ obj.x, obj.y, obj.z, obj.heading, obj.frozen, obj.networked }, { 474.9, -990.1, 27.25, 180.0, true, false })
        analyse.onSelect({ entity = entity })
        t.eq(env.opened, { entity })
        t.eq(#env.notifies, 0)
        env.openLaptopResult = 'error' -- evidences without patches/evidences.20-fredpd-integration.patch
        analyse.onSelect({ entity = entity })
        t.eq(env.lastNotify().description, 'Öppna laptopen med dess eget alternativ, ”Använd laptop”.')
        env.resources.evidences = 'stopped'
        analyse.onSelect({ entity = entity })
        t.eq(env.lastNotify().description, 'Bevislaptopen är inte tillgänglig just nu.')
        zone.onExit()
        t.eq(env.option('fredpd_forensics:analyse'), nil)
        t.eq(env.removed[1], { model = 'hash:p_laptop_02_s', name = 'fredpd_forensics:analyse' }, 'removed by name')
        t.eq(env.objects[entity], nil, 'prop deleted')
        -- re-entering does not add the option twice
        zone.onEnter()
        zone.onEnter()
        local n = 0
        for _, m in ipairs(env.models) do
            if m.option.name == 'fredpd_forensics:analyse' then n = n + 1 end
        end
        t.eq(n, 1)
    end)
end

tests['03 offer without NUI focus: dialog at once, callback, success text, offer cleared'] = function(t)
    withClient(t, function(_, env, client)
        env.netEvents['fredpd:forensics:client:offerLink']({ id = 7, type = 'fingerprint', example = 'K-123-26' })
        t.eq(#env.dialogs, 1)
        t.eq(env.dialogs[1].title, 'Koppla till ärende')
        local row = env.dialogs[1].rows[1]
        t.eq({ row.type, row.label, row.placeholder, row.required }, { 'input', 'Ärendenummer', 'K-123-26', true })
        t.eq(row.description, 'Fingeravtryck #7. Ange ärendenumret som beviset ska kopplas till.')
        t.eq(env.awaits, { { name = 'fredpd:forensics:link', data = { id = 7, caseNumber = 'K-123-26' } } })
        t.eq(env.lastNotify(), { type = 'success', description = 'Bevis B-K-123-26-001 är kopplat till ärende K-123-26.' })
        t.eq(client.pending[7], nil)
    end)
end

tests['04 offer while the laptop has focus: waits as a laptop option; cancel keeps it'] = function(t)
    withClient(t, function(_, env, client)
        env.focused = true
        env.netEvents['fredpd:forensics:client:offerLink']({ id = 8, type = 'casing' })
        t.eq(#env.dialogs, 0)
        t.eq(env.lastNotify().description, 'Beviset är analyserat. Stäng laptopen och välj Koppla till ärende på den.')
        local link = env.option('fredpd_forensics:link')
        t.eq(link.canInteract(), true)
        env.focused = false
        env.dialogAnswer = nil -- cancelled
        link.onSelect()
        t.eq(#env.dialogs, 1)
        t.eq(#env.awaits, 0)
        t.ok(client.pending[8], 'still waiting')
        env.dialogAnswer = { 'K-123-26' }
        link.onSelect()
        t.eq(#env.awaits, 1)
        t.eq(client.pending[8], nil)
        t.eq(link.canInteract(), false)
    end)
end

tests['05 several offers: a menu picks one, newest first'] = function(t)
    withClient(t, function(_, env)
        env.focused = true
        env.netEvents['fredpd:forensics:client:offerLink']({ id = 3, type = 'fingerprint' })
        env.netEvents['fredpd:forensics:client:offerLink']({ id = 4, type = 'dna' })
        env.focused = false
        env.option('fredpd_forensics:link').onSelect()
        t.eq(#env.contexts, 1)
        t.eq(env.shown, { 'fredpd_forensics_offers' })
        local opts = env.contexts[1].options
        t.eq({ opts[1].title, opts[2].title }, { 'DNA #4', 'Fingeravtryck #3' })
        opts[2].onSelect()
        t.eq(env.awaits[1].data.id, 3)
    end)
end

tests['06 error texts; already linked and missing evidence drop the offer, a wrong case keeps it'] = function(t)
    withClient(t, function(_, env, client)
        local cases = {
            { { ok = false, error = 'validation', reason = 'case_number' }, 'Ogiltigt ärendenummer. Exempel: K-123-26', true },
            { { ok = false, error = 'not_found', reason = 'case' }, 'Ärendet hittades inte.', true },
            { { ok = false, error = 'unauthorized', reason = 'case' },
                'Du har inte full åtkomst till ärendet och kan inte koppla bevis till det.', true },
            { { ok = false, error = 'validation', reason = 'case_closed' },
                'Ärendet är avslutat. Bevis kan bara kopplas till öppna ärenden.', true },
            { { ok = false, error = 'unauthorized', reason = 'off_duty' }, 'Du är inte i tjänst.', true },
            { { ok = false, error = 'rate_limited' }, SV['errors.rateLimited'], true },
            { { ok = false, error = 'unavailable' }, SV['errors.serviceUnavailable'], true },
            { nil, SV['errors.serviceUnavailable'], true }, -- no answer from the server
            { { ok = false, error = 'validation', reason = 'already_linked' }, 'Beviset är redan kopplat till ett ärende.',
                false },
            { { ok = false, error = 'not_found', reason = 'evidence' }, 'Beviset hittades inte.', false },
        }
        for i, c in ipairs(cases) do
            env.notifies = {}
            env.awaitAnswer = c[1]
            env.netEvents['fredpd:forensics:client:offerLink']({ id = 100 + i, type = 'fingerprint', example = 'K-123-26' })
            t.eq(env.lastNotify(), { type = 'error', description = c[2] }, 'case ' .. i)
            t.eq(client.pending[100 + i] ~= nil, c[3], 'pending after case ' .. i)
        end
    end)
end

tests['07 malformed offers are ignored; resource stop deletes the lab laptop'] = function(t)
    withClient(t, function(_, env, client)
        for _, bad in ipairs({ nil, 'x', { id = 'x' }, { id = 0 }, { id = 1.5 } }) do
            env.netEvents['fredpd:forensics:client:offerLink'](bad)
        end
        t.eq(next(client.pending), nil)
        t.eq(#env.dialogs, 0)
        env.zones[1].onEnter()
        local entity = next(env.objects)
        env.handlers.onResourceStop('other_resource')
        t.ok(env.objects[entity], 'other resource: kept')
        env.handlers.onResourceStop('fredpd_forensics')
        t.eq(env.objects[entity], nil)
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Framework bridge (docs/contracts.md §C17)

local function registered(env)
    return #env.zones + #env.boxes + #env.models + #env.qbTarget
end

tests['08 bridge qb stack (qb-target, qb-inventory): nothing is registered, not even with the server on'] = function(t)
    withClient(t, function(_, env, client)
        t.eq(env.FB.target.impl, 'qb-target')
        t.eq(client.active, false)
        t.eq(registered(env), 0, 'no zone, box or target option')
        t.eq(env.netEvents['fredpd:forensics:client:offerLink'], nil, 'no offer handler')
        env.netEvents['fredpd:forensics:client:enable']() -- even a (forged) enable changes nothing here
        env.handlers.onClientResourceStart('ox_inventory')
        t.eq(client.active, false)
        t.eq(registered(env), 0)
    end, { stack = 'qb' })
end

tests['09 bridge ox stack, server off at join: idle until the enable event, then everything once'] = function(t)
    withClient(t, function(_, env, client)
        t.eq(env.FB.target.impl, 'ox_target')
        t.eq(client.active, false)
        t.eq(registered(env), 0)
        env.netEvents['fredpd:forensics:client:enable']()
        t.eq(client.active, true)
        t.eq({ #env.zones, #env.boxes, #env.models }, { 1, 1, 1 })
        t.eq(env.boxes[1].name, 'fredpd_forensics:locker:evidence_locker_mrpd')
        t.eq(env.boxes[1].options[1].label, 'Öppna bevisförrådet')
        t.ok(env.netEvents['fredpd:forensics:client:offerLink'])
        env.netEvents['fredpd:forensics:client:enable']()
        t.eq({ #env.zones, #env.boxes, #env.models }, { 1, 1, 1 }, 'not twice')
    end, { convar = 'off' })
end

tests['10 bridge ox stack: ox_inventory starting on the client after this resource activates it'] = function(t)
    withClient(t, function(_, env, client)
        t.eq(client.active, false, 'ox_inventory missing at start')
        t.eq(registered(env), 0)
        env.handlers.onClientResourceStart('ox_target') -- still no ox_inventory
        t.eq(client.active, false)
        env.resources.ox_inventory = 'started'
        env.handlers.onClientResourceStart('ox_inventory')
        t.eq(client.active, true)
        t.eq({ #env.zones, #env.boxes, #env.models }, { 1, 1, 1 })
    end, { oxInventory = false })
end

return tests
