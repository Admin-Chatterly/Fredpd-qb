-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_mdt/client/main.lua with FiveM/ox_lib mocked: open (server callback -> NUI focus + `open` message -> prop on
-- bone 28422 with the tablet animation, model and dict released), refusals as Swedish notifications with nothing
-- opened, every close path of IMPLEMENTATION.md §8.3 (NUI close, forceClose, death, vehicle exit for the terminal,
-- server-driven logout, resource stop), death handlers only while open, the vehicle terminal (a FredBridge.target
-- option), the server-side item use (fredpd:client:openTablet, qb-inventory), pushes only while open, and one NUI
-- callback per tablet action forwarding { action, input } to the dispatcher. The REAL fredpd_core bridge/client.lua is
-- loaded first (as '@fredpd_core/bridge/client.lua' is), over qb-core + qb-target or qbx_core + ox_target mocks
-- (H.STACK, FREDPD_MDT_STACK; tests/lua/mdt_bridge_test.lua runs a smoke set on both).
-- Run: lua5.4 tests/lua/run.lua mdt_client
local H = dofile('./resources/[fredpd]/fredpd_mdt/test/harness.lua')

local CORE = './resources/[fredpd]/fredpd_core/'

local GLOBALS = { 'lib', 'cache', 'FredBridge', 'GetConvar', 'LocalPlayer', 'SetNuiFocus', 'SendNUIMessage', 'RegisterNUICallback',
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

--- The terminal option as registered with the stack's target resource, driven the way that resource drives it
--- (qb-target: canInteract(entity, distance, data), action(entity); ox_target: canInteract(entity, distance, coords),
--- onSelect(data)).
local function terminalOption(env)
    local reg = env.targets[#env.targets]
    local o = reg and reg.options[1]
    if not o then return nil end
    return {
        raw = o, label = o.label, name = o.name, distance = reg.distance or o.distance,
        canInteract = function(entity) return o.canInteract(entity, 1.0, nil) end,
        select = function(entity)
            if o.action then return o.action(entity) end
            return o.onSelect({ entity = entity, coords = { x = 1.0, y = 2.0, z = 3.0 }, distance = 1.0 })
        end,
    }
end

local function withClient(fn, stack)
    stack = stack or H.STACK
    local saved = {}
    for _, n in ipairs(GLOBALS) do saved[n] = { rawget(_G, n) } end
    local env = { log = {}, nui = {}, focus = {}, nuiCallbacks = {}, net = {}, handlers = {}, removed = 0, bags = {},
        server = {}, notifies = {}, calls = {}, objects = {}, deleted = {}, released = {}, dicts = {}, anims = {},
        stopped = 0, targets = {}, targetRemoved = 0, onCache = {}, seats = {}, exported = {}, printed = {},
        stack = stack, states = {},
        pd = { citizenid = 'MDT10001', job = { name = 'police', label = 'Polis', type = 'leo', onduty = true,
            grade = { name = 'Assistent', level = 1 } } } }
    local cfg = H.STACKS[stack].cfg
    env.targetResource = cfg.target
    local convars = { fredpd_bridge_framework = cfg.framework, fredpd_bridge_target = cfg.target,
        fredpd_bridge_doorlock = cfg.doorlock }
    local playerData = { GetPlayerData = function() return H.copy(env.pd) end }
    local upstream = {}
    if stack == 'qb' then
        -- qb-target a3ea78b2 registration.lua: AddTargetModel(models, { options, distance }), removal by label.
        upstream['qb-target'] = {
            AddTargetModel = function(_, models, params)
                env.targets[#env.targets + 1] = { models = models, options = params.options, distance = params.distance }
            end,
            RemoveTargetModel = function(_, _, labels) env.targetRemoved = env.targetRemoved + 1; env.removedName = labels[1] end,
        }
        upstream['qb-core'] = playerData
        upstream['qb-doorlock'] = { GetDoorList = function() return {} end }
    else
        upstream.ox_target = {
            addModel = function(_, models, options) env.targets[#env.targets + 1] = { models = models, options = options } end,
            removeModel = function(_, _, names) env.targetRemoved = env.targetRemoved + 1; env.removedName = names[1] end,
        }
        upstream.qbx_core = playerData
    end
    env.reply = function(name) if name == 'fredpd:mdt:open' then return H.copy(PAYLOAD) end return { ok = 'x' } end
    local function log(what) env.log[#env.log + 1] = what end
    local globals = {
        cache = { ped = 501, vehicle = false, serverId = 7 },
        FredBridge = nil,
        GetConvar = function(name, default) return convars[name] or default end,
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
        GetResourceState = function(res) return env.states[res] or 'started' end,
        exports = setmetatable(upstream, { __call = function(_, name, f) env.exported[name] = f end }),
        GetCurrentResourceName = function() return 'fredpd_mdt' end,
        LoadResourceFile = function(res, path)
            if res == 'fredpd_mdt' and path == 'web/build/index.html' and not env.noUi then return '<html></html>' end
            if res == 'fredpd_core' then -- bridge/client.lua reads its implementation files from fredpd_core
                local f = io.open(CORE .. path, 'rb')
                if not f then return nil end
                local text = f:read('a')
                f:close()
                return text
            end
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
        -- fxmanifest client_scripts: '@fredpd_core/bridge/client.lua' first, then client/main.lua.
        env.FB = dofile(CORE .. 'bridge/client.lua')
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
        t.eq(M.isOpen(), false, 'isDead player state')
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

tests['6 vehicle terminal: FredBridge.target option, no prop, closes on leaving the vehicle'] = function(t)
    withClient(function(env, M)
        local target = env.targets[1]
        t.ok(target, env.targetResource .. ' addModel at start (through FredBridge.target)')
        t.ok(#target.models >= 5, 'police models from config')
        local option = terminalOption(env)
        if env.stack == 'ox' then t.eq(option.name, 'fredpd_mdt:terminal') end -- qb-target keys options by label
        t.eq(option.label, 'Använd fordonsdatorn')
        t.eq(option.distance, 2.5)
        t.eq(option.canInteract(4242), false, 'not seated in it')
        cache.vehicle = 4242
        env.seats[-1] = 501
        t.eq(option.canInteract(4242), true, 'driver')
        env.seats[-1], env.seats[1] = 0, 501
        t.eq(option.canInteract(4242), false, 'back seat')
        env.seats[1], env.seats[0] = 0, 501
        t.eq(option.canInteract(4242), true, 'front passenger')
        env.net['QBCore:Client:SetDuty'](false) -- kept current by bridge/client.lua (both frameworks fire it)
        t.eq(option.canInteract(4242), false, 'off duty')
        env.net['QBCore:Client:SetDuty'](true)
        t.eq(option.canInteract(4242), true, 'on duty again')

        env.inVehicle = true
        option.select(4242)
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
        option.select(4242)
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
        -- Phase 3/5 topics go through the same generic forwarder, payload untouched.
        local payloads = {
            alerts = { type = 'updated', alert = { id = 4, status = 'assigned' } },
            units = { units = { { citizenid = 'MDT10001', onDuty = true, alertId = 4 } } },
            case = { type = 'updated', id = 12 },
        }
        for _, topic in ipairs({ 'alerts', 'units', 'case' }) do
            env.net['fredpd:client:push'](topic, payloads[topic])
            t.eq(env.nui[#env.nui], { action = 'push', topic = topic, payload = payloads[topic] }, topic)
        end
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
        -- Phase 3/4/5/5b actions are registered from the same list and forwarded the same way.
        for _, name in ipairs({ 'takeAlert', 'linkEvidence', 'createCase', 'saveReportDraft', 'issueFine', 'addLink',
            'getGraph', 'closeMission' }) do
            t.ok(env.nuiCallbacks[name], 'NUI callback ' .. name)
            env.nuiCallbacks[name]({ id = 1 }, function(v) answer = v end)
            t.eq(env.calls[#env.calls].req, { action = name, input = { id = 1 } }, name)
        end
        t.eq(#V.actionNames(), 52, 'MDT 11 + DISPATCH 5 + EVIDENCE 3 + RECORDS 16 + INTEL 17')
        env.reply = function() return nil end
        env.nuiCallbacks.listBolos({}, function(v) answer = v end)
        t.eq(answer, { error = 'unavailable' })
        env.reply = function() error('timeout', 0) end
        env.nuiCallbacks.getHome({}, function(v) answer = v end)
        t.eq(answer, { error = 'unavailable' })
    end)
end

tests['9 resource stop, server-driven logout and target resource restarts'] = function(t)
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
        t.eq(env.removedName, env.stack == 'ox' and 'fredpd_mdt:terminal' or 'Använd fordonsdatorn',
            'removed by name (ox_target) / label (qb-target)')
        -- The target resource restarted: the option is added again (once).
        for _, h in ipairs(env.handlers) do
            if h.name == 'onClientResourceStart' then h.fn(env.targetResource) end
        end
        t.eq(#env.targets, 2)
        for _, h in ipairs(env.handlers) do
            if h.name == 'onClientResourceStart' then h.fn('some_other_resource') end
        end
        t.eq(#env.targets, 2, 'other resources do not re-add')
        useItem(env)
        -- Logout: the server (fredpd:bridge:playerUnloaded) sends forceClose; the client listens to no framework event.
        env.net['QBCore:Client:OnPlayerUnload']() -- only bridge/client.lua's job hint listens to this
        t.eq(M.isOpen(), true, 'no framework unload handler in fredpd_mdt')
        env.net['fredpd:client:forceClose'](nil)
        t.eq(M.isOpen(), false, 'logout closes')
        -- Closed already: forceClose must not touch focus (another NUI, e.g. multicharacter, may hold it).
        local focusCalls = #env.focus
        env.net['fredpd:client:forceClose'](nil)
        env.net['fredpd:client:forceClose']('tablet.revoked')
        t.eq(#env.focus, focusCalls, 'no focus release while closed')
        t.eq(#env.server, 0, 'server-driven closes send nothing back')
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

tests['12 server-side item use (qb-inventory): fredpd:client:openTablet shows the server\'s answer, same as the callback'] = function(t)
    withClient(function(env, M)
        env.net['fredpd:client:openTablet'](H.copy(PAYLOAD))
        t.eq(#env.calls, 0, 'no second server round trip: the server already checked')
        t.eq(M.isOpen(), true)
        t.eq(env.nui[1], { action = 'open', grants = PAYLOAD.grants, unit = 'igv', me = PAYLOAD.me })
        t.ok(env.attached, 'prop in item mode')
        -- A second use while open is ignored (the server session stays).
        env.net['fredpd:client:openTablet'](H.copy(PAYLOAD))
        t.eq(#env.nui, 1)
        t.eq(#env.server, 0)
        M.close(true)
        -- Refusal from the server: Swedish notification, nothing opens.
        env.net['fredpd:client:openTablet']({ error = 'tablet.revoked' })
        t.eq(M.isOpen(), false)
        t.eq(env.notifies[#env.notifies], { type = 'error', description = 'Surfplattan är spärrad. Kontakta ledningen.' })
        env.net['fredpd:client:openTablet']('junk')
        t.eq(M.isOpen(), false)
        -- Dead by the time the answer arrives: not shown, the server's session is released.
        local before = #env.server
        env.dead = true
        env.net['fredpd:client:openTablet'](H.copy(PAYLOAD))
        t.eq(M.isOpen(), false)
        t.eq(env.server[before + 1], { name = 'fredpd:mdt:closed', args = {} })
    end)
    withClient(function(env, M)
        env.noUi = true
        env.net['fredpd:client:openTablet'](H.copy(PAYLOAD))
        t.eq(M.isOpen(), false)
        t.eq(#env.focus, 0, 'never focus without a page')
        t.eq(env.server, { { name = 'fredpd:mdt:closed', args = {} } })
        t.eq(env.notifies[1], { type = 'error', description = 'Du kan inte använda surfplattan just nu.' })
    end)
end

tests['13 target resource down at start: no terminal, no error; added once it starts'] = function(t)
    withClient(function(env, M)
        t.eq(#env.targets, 1)
        env.states[env.targetResource] = 'stopped'
        for _, h in ipairs(env.handlers) do
            if h.name == 'onClientResourceStop' then h.fn(env.targetResource) end
        end
        t.eq(M.addTerminal(), false, 'down: nothing added, no raise')
        env.states[env.targetResource] = 'started'
        for _, h in ipairs(env.handlers) do
            if h.name == 'onClientResourceStart' then h.fn(env.targetResource) end
        end
        t.eq(#env.targets, 2)
        t.eq(M.addTerminal(), false, 'already added: not twice')
        t.eq(#env.targets, 2)
    end)
end

tests['14 server-side item answer while another open is in flight: refusal shown, success kept for a refused open'] = function(t)
    withClient(function(env, M)
        -- Refusal arriving mid-flight is shown; the in-flight open still wins.
        env.onAwait = function() env.net['fredpd:client:openTablet']({ error = 'tablet.notOnDuty' }) end
        useItem(env)
        t.eq(env.notifies[1], { type = 'error', description = H.SV['tablet.notOnDuty'] })
        t.eq(M.isOpen(), true)
        t.eq(#env.nui, 1)
        M.close(true)
        -- Success arriving mid-flight while the in-flight open succeeds: the in-flight one is shown, once.
        env.onAwait = function() env.net['fredpd:client:openTablet'](H.copy(PAYLOAD)) end
        local nuiBefore, serverBefore = #env.nui, #env.server
        useItem(env)
        t.eq(M.isOpen(), true)
        t.eq(#env.nui, nuiBefore + 1)
        t.eq(#env.server, serverBefore, 'the server session is left alone')
        M.close(true)
        -- Success arriving mid-flight while the in-flight open is refused: the server-side item session is shown.
        env.reply = function() return { error = 'errors.rateLimited' } end
        nuiBefore = #env.nui
        useItem(env)
        t.eq(M.isOpen(), true)
        t.eq(env.nui[#env.nui], { action = 'open', grants = PAYLOAD.grants, unit = 'igv', me = PAYLOAD.me })
        t.eq(#env.nui, nuiBefore + 1)
        M.close(true)
        env.onAwait = nil
        -- Nothing queued is left over for a later refused open.
        useItem(env)
        t.eq(M.isOpen(), false)
    end)
end

if ... == 'mdt_client_test' then return { withClient = withClient, terminalOption = terminalOption, tests = tests } end
return tests
