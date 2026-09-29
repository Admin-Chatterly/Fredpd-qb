-- SPDX-License-Identifier: GPL-3.0-only
-- Target bridge (client, docs/contracts.md §C17): option normalisation, the qb-target and ox_target implementations
-- against mocks shaped like their registration APIs, remove handles, and bridge/client.lua itself (loaded the way
-- other resources include '@fredpd_core/bridge/client.lua': implementation from the replicated convar, 'auto'
-- without it, one warning while the resource is down). Run: lua5.4 tests/lua/run.lua bridge_target
local H = require('bridge_harness_test')
local Options = require('bridge.target.options')

local tests = {}

local CORE = './resources/[fredpd]/fredpd_core/'

local function opt(extra)
    local o = { name = 'fredpd:frisk', label = 'Visitera', icon = 'fa-solid fa-hand', distance = 2.0 }
    for k, v in pairs(extra or {}) do o[k] = v end
    return o
end

tests['options: one option or a list, validated, distance default, keys, max distance, selection'] = function(t)
    local sel = function() end
    local list = Options.list(opt({ onSelect = sel, extra = 'dropped' }), 3.0)
    t.eq(#list, 1)
    t.eq(list[1].name, 'fredpd:frisk')
    t.eq(list[1].distance, 2.0)
    t.eq(list[1].onSelect, sel)
    t.eq(list[1].extra, nil, 'only the normalised keys')
    local two = Options.list({ opt(), { name = 'b', label = 'B', icon = 5 } }, 3.0)
    t.eq(two[2].distance, 3.0, 'default distance')
    t.eq(two[2].icon, nil, 'non-string icon dropped')
    t.eq({ Options.keys(two) }, { { 'fredpd:frisk', 'b' }, { 'Visitera', 'B' } })
    t.eq(Options.maxDistance(two), 3.0)
    t.eq(Options.maxDistance(Options.list({ name = 'x', label = 'X' }, nil)), nil)
    t.eq(Options.selection(5, 'c', 1.5), { entity = 5, coords = 'c', distance = 1.5 })
    t.eq(select(2, Options.one({ label = 'x' })), 'option without name')
    t.eq(select(2, Options.one({ name = 'x' })), 'option x without label')
    t.eq(select(2, Options.one({ name = 'x', label = 'X', onSelect = 'event' })), 'option x: onSelect is not a function')
    t.ok(not pcall(Options.list, 'x'), 'not a table')
    t.ok(not pcall(Options.list, { opt(), { name = 'bad' } }), 'first bad option raises')
end

--- qb-target mock (a3ea78b2 registration.lua): records calls; options are stored by label (SetOptions :5-14).
local function qbTarget(calls)
    local function rec(name) return function(_, ...) calls[#calls + 1] = { name, ... } end end
    return { AddGlobalVehicle = rec('AddGlobalVehicle'), RemoveGlobalVehicle = rec('RemoveGlobalVehicle'),
        AddTargetModel = rec('AddTargetModel'), RemoveTargetModel = rec('RemoveTargetModel'),
        AddBoxZone = rec('AddBoxZone'), RemoveZone = rec('RemoveZone'),
        AddTargetEntity = rec('AddTargetEntity'), RemoveTargetEntity = rec('RemoveTargetEntity') }
end

--- ox_target mock (abe153aa client/api.lua).
local function oxTarget(calls)
    local function rec(name, ret) return function(_, ...) calls[#calls + 1] = { name, ... } return ret end end
    return { addGlobalVehicle = rec('addGlobalVehicle'), removeGlobalVehicle = rec('removeGlobalVehicle'),
        addModel = rec('addModel'), removeModel = rec('removeModel'), addBoxZone = rec('addBoxZone', 17),
        removeZone = rec('removeZone'), addEntity = rec('addEntity'), removeEntity = rec('removeEntity') }
end

local function withGlobals(globals, fn)
    local saved = {}
    for k, v in pairs(globals) do saved[k] = { rawget(_G, k) }; rawset(_G, k, v) end
    local ok, err = pcall(fn)
    for k, v in pairs(saved) do rawset(_G, k, v[1]) end
    if not ok then error(err, 0) end
end

tests['qb-target: { options, distance }, canInteract(entity, distance), action(entity) -> onSelect, removal by label'] = function(t)
    local calls, selected, asked = {}, {}, {}
    withGlobals({
        exports = H.exports({ ['qb-target'] = qbTarget(calls) }, {}),
        GetEntityCoords = function(e) return { x = e, y = 0, z = 0 } end,
        NetworkDoesNetworkIdExist = function(id) return id ~= 404 end,
        NetworkGetEntityFromNetworkId = function(id) return id + 1000 end,
    }, function()
        local qb = require('bridge.target.qb_target').client({ options = Options })
        local list = Options.list({
            opt({ canInteract = function(e, d, c) asked[#asked + 1] = { e, d, c } return e == 7 end,
                onSelect = function(s) selected[#selected + 1] = s end }),
            { name = 'fredpd:cuff', label = 'Handfängsel', distance = 1.5 },
        }, nil)
        local h = qb.addGlobalVehicle(list)
        local call = calls[1]
        t.eq(call[1], 'AddGlobalVehicle')
        local params = call[2]
        t.eq(params.distance, 2.0, 'the call distance = largest option distance (qb caps each option by it)')
        t.eq(#params.options, 2)
        t.eq(params.options[1].label, 'Visitera')
        t.eq(params.options[1].name, nil, 'qb-target keys by label')
        t.eq(params.options[2].distance, 1.5)
        t.eq(params.options[1].canInteract(7, 1.2, { some = 'data' }), true)
        t.eq(params.options[1].canInteract(8, 1.2), false)
        t.eq(asked[1], { 7, 1.2, nil }, 'qb-target passes (entity, distance, data): coords nil')
        t.eq(params.options[2].canInteract, nil)
        params.options[1].action(7)
        t.eq(selected, { { entity = 7, coords = { x = 7, y = 0, z = 0 } } })
        params.options[2].action(7) -- no onSelect: nothing happens
        t.eq(h, { kind = 'globalVehicle', labels = { 'Visitera', 'Handfängsel' } })
        t.eq(qb.remove(h), true)
        t.eq(calls[2], { 'RemoveGlobalVehicle', { 'Visitera', 'Handfängsel' } })

        local hm = qb.addModel({ 'prop_a' }, list)
        t.eq(calls[3][1], 'AddTargetModel')
        t.eq(calls[3][2], { 'prop_a' })
        qb.remove(hm)
        t.eq(calls[4], { 'RemoveTargetModel', { 'prop_a' }, { 'Visitera', 'Handfängsel' } })

        local hz = qb.addBoxZone('fredpd:armory', { coords = { x = 1, y = 2, z = 10 }, size = { x = 2, y = 4, z = 3 },
            rotation = 90, debug = true }, list)
        t.eq(calls[5][1], 'AddBoxZone')
        t.eq(calls[5][2], 'fredpd:armory')
        t.eq(calls[5][4], 4, 'length = size.y')
        t.eq(calls[5][5], 2, 'width = size.x')
        t.eq(calls[5][6], { name = 'fredpd:armory', heading = 90, minZ = 8.5, maxZ = 11.5, debugPoly = true })
        qb.remove(hz)
        t.eq(calls[6], { 'RemoveZone', 'fredpd:armory' })

        local he = qb.addEntity({ 5, 404 }, list)
        t.eq(calls[7][1], 'AddTargetEntity')
        t.eq(calls[7][2], { 1005 }, 'network ids -> entities; unknown ids skipped')
        qb.remove(he)
        t.eq(calls[8], { 'RemoveTargetEntity', { 1005 }, { 'Visitera', 'Handfängsel' } })
        t.eq(qb.remove({ kind = 'weird' }), false)
    end)
end

tests['ox_target: options keep name, canInteract(entity, distance, coords), onSelect(response) normalised'] = function(t)
    local calls, selected = {}, {}
    withGlobals({ exports = H.exports({ ox_target = oxTarget(calls) }, {}) }, function()
        local ox = require('bridge.target.ox_target').client({ options = Options })
        local list = Options.list(opt({ canInteract = function(e, d, c) return c ~= nil and e > 0 and d < 3 end,
            onSelect = function(s) selected[#selected + 1] = s end }), nil)
        local h = ox.addGlobalVehicle(list)
        local o = calls[1][2][1]
        t.eq(o.name, 'fredpd:frisk')
        t.eq(o.label, 'Visitera')
        t.eq(o.distance, 2.0)
        t.eq(o.canInteract(4, 1.0, 'coords', 'name', 'bone'), true)
        t.eq(o.canInteract(4, 1.0, nil), false)
        o.onSelect({ entity = 4, coords = 'c', distance = 1.1, zone = 3 })
        t.eq(selected, { { entity = 4, coords = 'c', distance = 1.1 } })
        ox.remove(h)
        t.eq(calls[2], { 'removeGlobalVehicle', { 'fredpd:frisk' } })
        local hz = ox.addBoxZone('z', { coords = 'v', size = 's' }, list)
        t.eq(calls[3][2].name, 'z')
        t.eq(calls[3][2].rotation, 0.0)
        t.eq(hz.id, 17)
        ox.remove(hz)
        t.eq(calls[4], { 'removeZone', 17, true })
        local he = ox.addEntity({ 9 }, list)
        ox.remove(he)
        t.eq(calls[6], { 'removeEntity', { 9 }, { 'fredpd:frisk' } })
        local hm = ox.addModel({ 'm' }, list)
        ox.remove(hm)
        t.eq(calls[8], { 'removeModel', { 'm' }, { 'fredpd:frisk' } })
    end)
end

--- Load bridge/client.lua as a resource including '@fredpd_core/bridge/client.lua' would.
local function loadClient(t, convars, states, resources, printed, net)
    local globals = {
        LoadResourceFile = function(res, path)
            t.eq(res, 'fredpd_core')
            local f = io.open(CORE .. path, 'rb')
            if not f then return nil end
            local s = f:read('a')
            f:close()
            return s
        end,
        GetConvar = function(name, default) return convars[name] or default end,
        GetResourceState = function(res) return states[res] or 'missing' end,
        exports = H.exports(resources, {}),
        print = function(msg) printed[#printed + 1] = msg end,
        FredBridge = false,
        RegisterNetEvent = function(name, fn) if net then net[name] = fn end end,
    }
    return globals
end

tests['bridge/client.lua: implementation from the replicated convar, auto without it, handles tied to the impl'] = function(t)
    local calls, printed = {}, {}
    local states = { ['qb-target'] = 'started', ox_target = 'started', ['qb-doorlock'] = 'started' }
    local g = loadClient(t, { fredpd_bridge_target = 'qb-target', fredpd_bridge_doorlock = 'qb-doorlock' }, states,
        { ['qb-target'] = qbTarget(calls), ['qb-doorlock'] = { GetDoorList = function() return {} end } }, printed)
    g.FredBridge = nil
    withGlobals(g, function()
        local FB = dofile(CORE .. 'bridge/client.lua')
        t.eq(FB, FredBridge)
        t.eq(FB.target.impl, 'qb-target', 'convar wins over auto (ox_target also runs)')
        t.eq(FB.doorlock.impl, 'qb-doorlock')
        t.eq(FB.target.available(), true)
        local h = FB.target.addModel('prop_x', opt())
        t.eq(calls[1][2], { 'prop_x' }, 'a single model is wrapped')
        t.eq(h.impl, 'qb-target')
        t.eq(FB.target.remove(h), true)
        t.eq(FB.target.remove({ kind = 'model', impl = 'ox_target' }), false, 'foreign handle')
        t.ok(not pcall(FB.target.addBoxZone, 'z', {}, opt()), 'box needs coords and size')
        t.ok(not pcall(FB.target.addGlobalVehicle, { name = 'x' }), 'invalid option raises')
        t.eq(FB.doorlock.listDoors(), {})
    end)

    local g2 = loadClient(t, {}, { ['qb-target'] = 'started', ox_target = 'started', ox_doorlock = 'missing' },
        { ox_target = oxTarget(calls) }, printed)
    g2.FredBridge = nil
    withGlobals(g2, function()
        local FB = dofile(CORE .. 'bridge/client.lua')
        t.eq(FB.target.impl, 'ox_target', 'auto: ox preferred')
        t.eq(FB.doorlock.impl, 'qb-doorlock', 'auto: nothing installed -> qb default')
    end)
end

tests['bridge/client.lua: target resource down -> nil with ONE warning, nothing registered'] = function(t)
    local calls, printed = {}, {}
    local g = loadClient(t, { fredpd_bridge_target = 'qb-target' }, { ['qb-target'] = 'stopped' },
        { ['qb-target'] = qbTarget(calls) }, printed)
    g.FredBridge = nil
    withGlobals(g, function()
        local FB = dofile(CORE .. 'bridge/client.lua')
        t.eq(FB.target.addGlobalVehicle(opt()), nil)
        t.eq(FB.target.addModel('m', opt()), nil)
        t.eq(#calls, 0)
        local n = 0
        for _, line in ipairs(printed) do if line:find('resource qb-target is stopped', 1, true) then n = n + 1 end end
        t.eq(n, 1, table.concat(printed, '\n'))
        t.eq(FB.target.available(), false)
    end)
end

tests['bridge/client.lua framework.getJob: fetched once from GetPlayerData, kept current by the client events'] = function(t)
    local printed, net, fetches = {}, {}, 0
    local pd = { citizenid = 'QB1', job = { name = 'police', type = 'leo', onduty = false, grade = { name = 'Officer', level = 1 } } }
    local g = loadClient(t, { fredpd_bridge_framework = 'qb-core' }, { ['qb-core'] = 'started' },
        { ['qb-core'] = { GetPlayerData = function() fetches = fetches + 1 return pd end } }, printed, net)
    g.FredBridge = nil
    withGlobals(g, function()
        local FB = dofile(CORE .. 'bridge/client.lua')
        t.eq(FB.framework.impl, 'qb-core')
        local job = FB.framework.getJob()
        t.eq(job.type, 'leo')
        t.eq(job.onduty, false)
        t.eq(job.grade, 1)
        job.onduty = true
        t.eq(FB.framework.getJob().onduty, false, 'a copy is returned')
        FB.framework.getJob()
        t.eq(fetches, 1, 'cached (canInteract runs often)')
        net['QBCore:Client:SetDuty'](true)
        t.eq(FB.framework.getJob().onduty, true)
        net['QBCore:Client:OnJobUpdate']({ name = 'ambulance', type = 'ems', onduty = true, grade = { level = 0 } })
        t.eq(FB.framework.getJob().type, 'ems')
        net['QBCore:Player:SetPlayerData']({ citizenid = 'QB1', job = { name = 'police', type = 'leo', onduty = true } })
        t.eq(FB.framework.getJob().name, 'police')
        net['QBCore:Client:OnPlayerUnload']()
        t.eq(FB.framework.getJob(), nil, 'logged out')
        net['QBCore:Client:OnPlayerLoaded']()
        t.eq(FB.framework.getJob().name, 'police', 'refetched after load')
        t.eq(fetches, 2)
    end)
    local g2 = loadClient(t, {}, {}, {}, printed, {})
    g2.FredBridge = nil
    withGlobals(g2, function()
        local FB = dofile(CORE .. 'bridge/client.lua')
        t.eq(FB.framework.impl, 'qb-core', 'auto, nothing installed -> qb default')
        t.eq(FB.framework.getJob(), nil, 'framework down -> nil, no error')
    end)
end

return tests
