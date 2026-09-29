-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_mdt/client/main.lua with FiveM/ox_lib mocked: open (server callback -> NUI focus + `open` message -> prop on
-- bone 28422 with the tablet animation, model and dict released), refusals as Swedish notifications with nothing
-- opened, every close path of IMPLEMENTATION.md §8.3 (NUI close, forceClose, death, vehicle exit for the terminal,
-- logout, resource stop), death handlers only while open, the vehicle terminal (ox_target option), pushes only while
-- open, and one NUI callback per tablet action forwarding { action, input } to the dispatcher.
-- Run: lua5.4 tests/lua/run.lua mdt_client
local H = dofile('./resources/[fredpd]/fredpd_mdt/test/harness.lua')

local GLOBALS = { 'lib', 'cache', 'QBX', 'LocalPlayer', 'SetNuiFocus', 'SendNUIMessage', 'RegisterNUICallback',
    'RegisterNetEvent', 'AddEventHandler', 'RemoveEventHandler', 'AddStateBagChangeHandler',
    'RemoveStateBagChangeHandler', 'TriggerServerEvent', 'CreateThread', 'IsPauseMenuActive', 'IsEntityDead',
    'IsPedFatallyInjured', 'IsPedInAnyVehicle', 'DoesEntityExist', 'DetachEntity', 'DeleteEntity', 'IsEntityPlayingAnim',
    'StopAnimTask', 'GetEntityCoords', 'CreateObject', 'SetModelAsNoLongerNeeded', 'RemoveAnimDict',
    'AttachEntityToEntity', 'GetPedBoneIndex', 'TaskPlayAnim', 'GetPedInVehicleSeat', 'GetResourceState', 'exports',
    'GetCurrentResourceName', 'locale', 'print', 'LoadResourceFile', 'RegisterCommand' }

local PAYLOAD = {
    grants = { grants = { 'mdt_page:search' }, denied = {}, tier = 0, units = { 'igv' }, computedAt = '2026-09-29T08:00:00Z' },
    unit = 'igv',
    me = { citizenid = 'MDT10001', displayName = 'Anna B.', callsign = 'IGV-07' },
}

local function withClient(fn)
    local saved = {}
    for _, n in ipairs(GLOBALS) do saved[n] = { rawget(_G, n) } end
    local env = { log = {}, nui = {}, focus = {}, nuiCallbacks = {}, net = {}, handlers = {}, removed = 0, bags = {},
        server = {}, notifies = {}, calls = {}, objects = {}, deleted = {}, released = {}, dicts = {}, anims = {},
        stopped = 0, targets = {}, targetRemoved = 0, onCache = {}, seats = {}, exported = {}, printed = {} }
    env.reply = function(name) if name == 'fredpd:mdt:open' then return H.copy(PAYLOAD) end return { ok = 'x' } end
    local function log(what) env.log[#env.log + 1] = what end
    local globals = {
        cache = { ped = 501, vehicle = false, serverId = 7 },
        QBX = { PlayerData = { job = { type = 'leo', onduty = true } } },
        LocalPlayer = { state = {} },
        SetNuiFocus = function(a, b) env.focus[#env.focus + 1] = { a, b }; log('focus:' .. tostring(a)) end,
        SendNUIMessage = function(msg) env.nui[#env.nui + 1] = msg; log('nui:' .. msg.action) end,
        RegisterNUICallback = function(name, cb) env.nuiCallbacks[name] = cb end,
        RegisterNetEvent = function(name, cb) env.net[name] = cb end,
        AddEventHandler = function(name, cb)
            local h = { name = name, fn = cb }
            env.handlers[#env.handlers + 1] = h
            return h
        end,
        RemoveEventHandler = function(h)
            for i, x in ipairs(env.handlers) do
                if x == h then table.remove(env.handlers, i); env.removed = env.removed + 1; return end
            end
        end,
        AddStateBagChangeHandler = function(key, bag, cb)
            local cookie = #env.bags + 1
            env.bags[cookie] = { key = key, bag = bag, fn = cb }
            return cookie
        end,
        RemoveStateBagChangeHandler = function(cookie) env.bags[cookie] = nil end,
        TriggerServerEvent = function(name, ...) env.server[#env.server + 1] = { name = name, args = { ... } } end,
        CreateThread = function(f) f() end,
        IsPauseMenuActive = function() return env.pause == true end,
        IsEntityDead = function() return env.dead == true end,
        IsPedFatallyInjured = function() return false end,
        IsPedInAnyVehicle = function() return env.inVehicle == true end,
        DoesEntityExist = function(e) return env.objects[e] ~= nil and not env.deleted[e] end,
        DetachEntity = function(e) log('detach:' .. tostring(e)) end,
        DeleteEntity = function(e) env.deleted[e] = true; log('delete:' .. tostring(e)) end,
        IsEntityPlayingAnim = function(_, dict, clip) return env.anims[#env.anims] ~= nil and env.stopped == 0
            and env.anims[#env.anims].dict == dict and env.anims[#env.anims].clip == clip end,
        StopAnimTask = function() env.stopped = env.stopped + 1; log('stopAnim') end,
        GetEntityCoords = function() return { x = 1.0, y = 2.0, z = 3.0 } end,
        CreateObject = function(model, x, y, z, networked, mission, door)
            local id = 9000 + #env.log
            env.objects[id] = { model = model, coords = { x, y, z }, networked = networked, mission = mission, door = door }
            log('create:' .. tostring(model))
            return id
        end,
        SetModelAsNoLongerNeeded = function(model) env.released[#env.released + 1] = model; log('releaseModel') end,
        RemoveAnimDict = function(dict) env.dicts[#env.dicts + 1] = dict; log('releaseDict') end,
        AttachEntityToEntity = function(e, ped, bone, ox, oy, oz, rx, ry, rz)
            env.attached = { entity = e, ped = ped, bone = bone, offset = { ox, oy, oz }, rotation = { rx, ry, rz } }
        end,
        GetPedBoneIndex = function(_, bone) return 100000 + bone end,
        TaskPlayAnim = function(ped, dict, clip, _, _, duration, flag)
            env.anims[#env.anims + 1] = { ped = ped, dict = dict, clip = clip, duration = duration, flag = flag }
            env.stopped = 0
            log('anim')
        end,
        GetPedInVehicleSeat = function(_, seat) return env.seats[seat] or 0 end,
        GetResourceState = function() return 'started' end,
        exports = setmetatable({
            ox_target = {
                addModel = function(_, models, options) env.targets[#env.targets + 1] = { models = models, options = options } end,
                removeModel = function(_, _, name) env.targetRemoved = env.targetRemoved + 1; env.removedName = name end,
            },
        }, { __call = function(_, name, f) env.exported[name] = f end }),
        GetCurrentResourceName = function() return 'fredpd_mdt' end,
        LoadResourceFile = function(res, path)
            if res == 'fredpd_mdt' and path == 'web/build/index.html' and not env.noUi then return '<html></html>' end
            return nil
        end,
        RegisterCommand = function(name, cb, restricted) env.commands = env.commands or {}; env.commands[name] = { cb, restricted } end,
        locale = function(key) return H.SV[key] or key end,
        print = function(s) env.printed[#env.printed + 1] = s end,
        lib = {
            notify = function(data) env.notifies[#env.notifies + 1] = data end,
            callback = {
                await = function(name, delay, req)
                    env.calls[#env.calls + 1] = { name = name, delay = delay, req = req }
                    if env.onAwait then env.onAwait(name, req) end
                    return env.reply(name, req)
                end,
            },
            requestAnimDict = function(dict) log('loadDict'); return dict end,
            requestModel = function(model)
                log('loadModel')
                if env.onModel then env.onModel() end
                return 'hash:' .. model
            end,
            onCache = function(key, cb) env.onCache[key] = cb end,
        },
    }
    for k, v in pairs(globals) do rawset(_G, k, v) end
    local ok, err = pcall(function()
        H.forget()
        env.M = H.run('client/main.lua')
        fn(env, env.M)
    end)
    H.forget()
    for n, v in pairs(saved) do rawset(_G, n, v[1]) end
    if not ok then error(err, 0) end
end

local function handlerNames(env)
    local out = {}
    for _, h in ipairs(env.handlers) do out[#out + 1] = h.name end
    table.sort(out)
    return out
end

local function useItem(env, slot)
    env.exported.open({ name = 'pd_tablet' }, slot or { name = 'pd_tablet', slot = 3, metadata = { serial = 'SP-AAAA-0001' } })
end

local tests = {}

tests['1 item use: server check, NUI focus + open message, then prop on bone 28422 with the tablet anim'] = function(t)
    withClient(function(env, M)
        t.ok(env.exported.open, 'ox_inventory client.export fredpd_mdt.open')
        useItem(env)
        t.eq(env.calls[1], { name = 'fredpd:mdt:open', delay = false, req = { mode = 'item', slot = 3 } })
        t.eq(M.isOpen(), true)
        t.eq(env.focus[1], { true, true })
        t.eq(env.nui[1], { action = 'open', grants = PAYLOAD.grants, unit = 'igv', me = PAYLOAD.me })
        -- NUI first, the prop after (streaming must not delay the first paint).
        t.eq({ env.log[1], env.log[2] }, { 'focus:true', 'nui:open' })
        local obj = env.attached and env.objects[env.attached.entity]
        t.ok(obj, 'prop created and attached')
        t.eq(obj.model, 'hash:prop_cs_tablet')
        t.eq(obj.networked, true)
        t.eq(env.attached.ped, 501)
        t.eq(env.attached.bone, 100000 + 28422)
        t.eq(env.attached.offset, { 0.0, -0.03, 0.0 })
        t.eq(env.anims[1], { ped = 501, dict = 'amb@code_human_in_bus_passenger_idles@female@tablet@base', clip = 'base',
            duration = -1, flag = 49 })
        t.eq(env.released, { 'hash:prop_cs_tablet' }, 'SetModelAsNoLongerNeeded')
        t.eq(env.dicts, { 'amb@code_human_in_bus_passenger_idles@female@tablet@base' }, 'anim dict released')
        -- A second use while open does nothing.
        useItem(env)
        t.eq(#env.calls, 1)
    end)
end

tests['2 refusals: Swedish notification, no focus, no NUI, no prop'] = function(t)
    local cases = {
        { reply = { error = 'tablet.noGrant' }, text = 'Du har inte behörighet att använda surfplattan.' },
        { reply = { error = 'tablet.noItem' }, text = 'Du har ingen surfplatta.' },
        { reply = { error = 'tablet.revoked' }, text = 'Surfplattan är spärrad. Kontakta ledningen.' },
        { reply = { error = 'tablet.notOnDuty' }, text = 'Du måste vara i tjänst för att använda surfplattan.' },
        { reply = { error = 'tablet.unregistered' }, text = 'Surfplattan är inte registrerad. Kontakta ledningen.' },
        { reply = nil, text = 'Du kan inte använda surfplattan just nu.' },
        { raise = true, text = 'Du kan inte använda surfplattan just nu.' },
    }
    for _, c in ipairs(cases) do
        withClient(function(env, M)
            env.reply = function()
                if c.raise then error('callback timed out', 0) end
                return c.reply
            end
            useItem(env)
            t.eq(M.isOpen(), false)
            t.eq(env.notifies[1], { type = 'error', description = c.text })
            t.eq(#env.focus, 0)
            t.eq(#env.nui, 0)
            t.eq(next(env.objects), nil)
            t.eq(handlerNames(env), { 'onClientResourceStart', 'onClientResourceStop' }, 'no death handlers')
        end)
    end
end

tests['3 NUI close (Esc/close button): focus released, prop deleted, anim stopped, server told'] = function(t)
    withClient(function(env, M)
        useItem(env)
        local prop = env.attached.entity
        local answered
        env.nuiCallbacks.close({}, function(v) answered = v end)
        t.eq(answered, { ok = true })
        t.eq(M.isOpen(), false)
        t.eq(env.focus[#env.focus], { false, false })
        t.eq(env.nui[#env.nui], { action = 'close' })
        t.eq(env.deleted[prop], true)
        t.eq(env.stopped, 1)
        t.eq(env.server, { { name = 'fredpd:mdt:closed', args = {} } })
        -- Closing again (a stale Esc) still releases focus but sends nothing new.
        env.nuiCallbacks.close({}, function() end)
        t.eq(env.focus[#env.focus], { false, false })
        t.eq(#env.server, 1)
    end)
end

tests['4 forceClose from the server: closed without telling the server back, reason shown in Swedish'] = function(t)
    withClient(function(env, M)
        useItem(env)
        env.net['fredpd:client:forceClose']('tablet.revoked')
        t.eq(M.isOpen(), false)
        t.eq(env.focus[#env.focus], { false, false })
        t.eq(#env.server, 0)
        t.eq(env.notifies[1], { type = 'error', description = 'Surfplattan är spärrad. Kontakta ledningen.' })
        env.net['fredpd:client:forceClose']('tablet.revoked')
        t.eq(#env.notifies, 1, 'not open: no second notification')
        useItem(env)
        env.net['fredpd:client:forceClose']('bad key!')
        t.eq(M.isOpen(), false)
        t.eq(#env.notifies, 1, 'odd key not shown')
    end)
end

tests['5 death closes; death handlers exist only while the tablet is open'] = function(t)
    withClient(function(env, M)
        t.eq(handlerNames(env), { 'onClientResourceStart', 'onClientResourceStop' })
        t.eq(next(env.bags), nil)
        useItem(env)
        t.eq(handlerNames(env), { 'baseevents:onPlayerDied', 'baseevents:onPlayerKilled', 'gameEventTriggered',
            'onClientResourceStart', 'onClientResourceStop' })
        local bag = env.bags[1]
        t.eq({ bag.key, bag.bag }, { 'isDead', 'player:7' })
        local function damage(victim)
            for _, h in ipairs(env.handlers) do
                if h.name == 'gameEventTriggered' then h.fn('CEventNetworkEntityDamage', { victim, 0, 0, 0, 0, 1 }) end
            end
        end
        damage(999)
        t.eq(M.isOpen(), true, 'someone else hurt')
        damage(501)
        t.eq(M.isOpen(), true, 'hurt, alive')
        env.dead = true
        damage(501)
        t.eq(M.isOpen(), false, 'dead')
        t.eq(env.server[1].name, 'fredpd:mdt:closed')
        t.eq(handlerNames(env), { 'onClientResourceStart', 'onClientResourceStop' }, 'handlers removed')
        t.eq(next(env.bags), nil, 'state bag handler removed')
        -- Dead players cannot open it.
        useItem(env)
        t.eq(M.isOpen(), false)
        env.dead = false
        env.LocalPlayer = nil
        LocalPlayer.state.isDead = true
        useItem(env)
        t.eq(M.isOpen(), false, 'qbx isDead state')
        LocalPlayer.state.isDead = nil
        -- The qbx isDead state bag and baseevents close too.
        useItem(env)
        env.bags[#env.bags].fn('player:7', 'isDead', true)
        t.eq(M.isOpen(), false)
        useItem(env)
        for _, h in ipairs(env.handlers) do
            if h.name == 'baseevents:onPlayerDied' then h.fn() break end
        end
        t.eq(M.isOpen(), false)
    end)
end

tests['6 vehicle terminal: ox_target option, no prop, closes on leaving the vehicle'] = function(t)
    withClient(function(env, M)
        local target = env.targets[1]
        t.ok(target, 'ox_target addModel at start')
        t.ok(#target.models >= 5, 'police models from config')
        local option = target.options[1]
        t.eq(option.name, 'fredpd_mdt:terminal')
        t.eq(option.label, 'Använd fordonsdatorn')
        t.eq(option.canInteract(4242), false, 'not seated in it')
        cache.vehicle = 4242
        env.seats[-1] = 501
        t.eq(option.canInteract(4242), true, 'driver')
        env.seats[-1], env.seats[1] = 0, 501
        t.eq(option.canInteract(4242), false, 'back seat')
        env.seats[1], env.seats[0] = 0, 501
        t.eq(option.canInteract(4242), true, 'front passenger')
        QBX.PlayerData.job.onduty = false
        t.eq(option.canInteract(4242), false, 'off duty')
        QBX.PlayerData.job.onduty = true

        env.inVehicle = true
        option.onSelect({ entity = 4242 })
        t.eq(env.calls[1].req, { mode = 'terminal' })
        t.eq(M.isOpen(), true)
        t.eq(next(env.objects), nil, 'no prop in the terminal')
        t.eq(#env.anims, 0)
        t.eq(option.canInteract(4242), false, 'hidden while open')
        env.onCache.vehicle(4242)
        t.eq(M.isOpen(), true, 'same vehicle')
        env.onCache.vehicle(false)
        t.eq(M.isOpen(), false, 'left the vehicle')
        t.eq(env.server[#env.server].name, 'fredpd:mdt:closed')
        -- An item-mode tablet is not closed by vehicle changes.
        env.inVehicle = false
        useItem(env)
        env.onCache.vehicle(777)
        t.eq(M.isOpen(), true)
        M.close(true)
        -- Left the vehicle while the server was checking: not opened, server told.
        cache.vehicle = 4242
        env.onAwait = function() cache.vehicle = false end
        local before = #env.server
        option.onSelect({ entity = 4242 })
        t.eq(M.isOpen(), false)
        t.eq(env.server[before + 1].name, 'fredpd:mdt:closed')
    end)
end

tests['7 pushes and grant updates reach the NUI only while open'] = function(t)
    withClient(function(env)
        env.net['fredpd:client:push']('bolo', { type = 'created', id = 1 })
        env.net['fredpd:client:grantsChanged']({ grants = {} })
        t.eq(#env.nui, 0)
        useItem(env)
        env.net['fredpd:client:push']('bolo', { type = 'created', id = 1 })
        t.eq(env.nui[#env.nui], { action = 'push', topic = 'bolo', payload = { type = 'created', id = 1 } })
        env.net['fredpd:client:grantsChanged']({ grants = { 'mdt_page:bolos' } })
        t.eq(env.nui[#env.nui], { action = 'push', topic = 'grants', payload = { grants = { 'mdt_page:bolos' } } })
        env.net['fredpd:client:push'](5, {})
        env.net['fredpd:client:grantsChanged']('x')
        t.eq(#env.nui, 3, 'malformed ignored')
    end)
end

tests['8 one NUI callback per action, forwarding { action, input }; nothing is sent while closed'] = function(t)
    withClient(function(env)
        local V = dofile('./resources/[fredpd]/fredpd_mdt/shared/validate.lua')
        for _, name in ipairs(V.actionNames()) do t.ok(env.nuiCallbacks[name], 'NUI callback ' .. name) end
        local answer
        env.nuiCallbacks.search({ query = 'Anna' }, function(v) answer = v end)
        t.eq(answer, { error = 'unauthorized' }, 'closed')
        t.eq(#env.calls, 0)
        useItem(env)
        env.reply = function(name, req)
            if name == 'fredpd:mdt:action' then return { hits = {}, echo = req } end
        end
        env.nuiCallbacks.search({ query = 'Anna' }, function(v) answer = v end)
        t.eq(env.calls[#env.calls], { name = 'fredpd:mdt:action', delay = false,
            req = { action = 'search', input = { query = 'Anna' } } })
        t.eq(answer, { hits = {}, echo = { action = 'search', input = { query = 'Anna' } } })
        env.reply = function() return nil end
        env.nuiCallbacks.listBolos({}, function(v) answer = v end)
        t.eq(answer, { error = 'unavailable' })
        env.reply = function() error('timeout', 0) end
        env.nuiCallbacks.getHome({}, function(v) answer = v end)
        t.eq(answer, { error = 'unavailable' })
    end)
end

tests['9 resource stop, logout and ox_target restarts'] = function(t)
    withClient(function(env, M)
        useItem(env)
        local prop = env.attached.entity
        for _, h in ipairs(env.handlers) do
            if h.name == 'onClientResourceStop' then h.fn('fredpd_mdt') end
        end
        t.eq(M.isOpen(), false)
        t.eq(env.focus[#env.focus], { false, false })
        t.eq(env.deleted[prop], true)
        t.eq(env.targetRemoved, 1)
        t.eq(env.removedName, 'fredpd_mdt:terminal')
        -- ox_target restarted: the option is added again.
        for _, h in ipairs(env.handlers) do
            if h.name == 'onClientResourceStart' then h.fn('ox_target') end
        end
        t.eq(#env.targets, 2)
        useItem(env)
        env.net['QBCore:Client:OnPlayerUnload']()
        t.eq(M.isOpen(), false, 'logout closes')
        -- Closed already: logout/forceClose must not touch focus (another NUI, e.g. multicharacter, may hold it).
        local focusCalls = #env.focus
        env.net['QBCore:Client:OnPlayerUnload']()
        env.net['fredpd:client:forceClose']('tablet.revoked')
        t.eq(#env.focus, focusCalls, 'no focus release while closed')
        t.eq(#env.server, 1, 'only the first logout told the server')
    end)
end

tests['11 no NUI bundle: never takes focus (no trap); F8 escape hatch closes'] = function(t)
    withClient(function(env, M)
        env.noUi = true
        useItem(env)
        t.eq(M.isOpen(), false)
        t.eq(#env.calls, 0, 'server not even asked')
        t.eq(#env.focus, 0)
        t.eq(env.notifies[1], { type = 'error', description = 'Du kan inte använda surfplattan just nu.' })
        t.ok(env.printed[1]:find('web/build/index.html is missing', 1, true))
    end)
    withClient(function(env, M)
        useItem(env)
        t.eq(env.commands.fredpd_mdt_close[2], false)
        env.commands.fredpd_mdt_close[1]()
        t.eq(M.isOpen(), false)
        t.eq(env.focus[#env.focus], { false, false })
    end)
end

tests['10 prop: closed while streaming releases the model; a failed load still opens the tablet'] = function(t)
    withClient(function(env, M)
        env.onModel = function() M.close(true) end
        useItem(env)
        t.eq(M.isOpen(), false)
        t.eq(next(env.objects), nil, 'no object created')
        t.eq(env.released, { 'hash:prop_cs_tablet' })
        t.eq(#env.dicts, 1)
        env.onModel = function() error('failed to load model prop_cs_tablet', 0) end
        useItem(env)
        t.eq(M.isOpen(), true, 'tablet usable without the prop')
        t.ok(env.printed[1]:find('failed to load model', 1, true), 'logged')
        M.close(true)
        -- Using the item inside a vehicle opens without the prop.
        env.onModel = nil
        env.inVehicle = true
        useItem(env)
        t.eq(M.isOpen(), true)
        t.eq(next(env.objects), nil)
        -- Pause menu open: nothing happens.
        M.close(true)
        env.pause = true
        local before = #env.calls
        useItem(env)
        t.eq(#env.calls, before)
    end)
end

return tests
