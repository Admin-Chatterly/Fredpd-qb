-- SPDX-License-Identifier: GPL-3.0-only
-- qb-policejob patch 10 'grants': the FredPD armory (config/police.json qbPolicejob.armories), the optional
-- qb-inventory shop hooks (qbShops) and the police garage / helicopter / impound spawn, all decided server-side.
-- Run: lua5.4 tests/lua/run.lua qbpolice_armory
local H = require('qbpolice_harness_test')

local tests = {}

local ARMORY = { 462.23, -981.12, 30.68 }

local function server(opts)
    opts = opts or {}
    opts.players = opts.players or H.cast()
    local env = H.server(opts)
    for src in pairs(env.players) do H.at(env, src, ARMORY[1], ARMORY[2], ARMORY[3]) end
    return env
end

local function names(list)
    local out = {}
    for _, item in ipairs(list) do out[#out + 1] = item.name end
    table.sort(out)
    return out
end

local function keys(map)
    local out = {}
    for k in pairs(map) do out[#out + 1] = k end
    table.sort(out)
    return out
end

tests['armory: the list sent to the client holds only granted weapons and items'] = function(t)
    H.withTree(function()
        local env = server()
        local data = env.call('police:server:fredpdArmory', 1, 'mrpd')
        t.eq(data.id, 'mrpd')
        t.eq(data.label, 'Mission Row')
        t.eq(names(data.items), { 'pistol_ammo', 'weapon_pistol' })
        t.eq(data.items[1].label ~= nil, true)
        env.spec(1).grants['weapon:*'] = true
        env.tick()
        data = env.call('police:server:fredpdArmory', 1, 'mrpd')
        t.eq(#data.items, 6, 'weapon:* grants every weapon (5) + pistol_ammo')
    end)
end

tests['armory: an ungranted item is refused even when the client sends it; a granted take is handed out'] =
    function(t)
        H.withTree(function()
            local env = server()
            t.eq({ env.call('police:server:fredpdArmoryTake', 1, 'mrpd', 'weapon_carbinerifle') }, { nil, 'no_grant' })
            env.tick()
            t.eq({ env.call('police:server:fredpdArmoryTake', 1, 'mrpd', 'weapon_rpg') }, { nil, 'unavailable' },
                'not in the armory list')
            t.eq(#env.addItems, 0)
            env.tick()
            t.eq(env.call('police:server:fredpdArmoryTake', 1, 'mrpd', 'WEAPON_PISTOL'), true)
            t.eq({ env.addItems[1].name, env.addItems[1].count, env.addItems[1].src }, { 'weapon_pistol', 1, 1 })
            t.eq(env.audits[1].action, 'police.armory')
            t.eq(env.audits[1].meta, { armory = 'mrpd', count = 1 })
            t.eq({ env.call('police:server:fredpdArmoryTake', 1, 'mrpd', 'pistol_ammo') }, { nil, 'rate_limited' })
        end)
    end

tests['armory: max, off duty, no armory grant, too far, cannot carry, unknown armory'] = function(t)
    H.withTree(function()
        local env = server()
        env.spec(1).items.weapon_pistol = 1
        t.eq({ env.call('police:server:fredpdArmoryTake', 1, 'mrpd', 'weapon_pistol') }, { nil, 'limit' })
        env.tick()
        env.canAdd = false
        t.eq({ env.call('police:server:fredpdArmoryTake', 1, 'mrpd', 'pistol_ammo') }, { nil, 'full' })
        env.canAdd = true
        t.eq({ env.call('police:server:fredpdArmory', 3, 'mrpd') }, { nil, 'off_duty' }, 'FredPD off duty')
        t.eq({ env.call('police:server:fredpdArmory', 2, 'mrpd') }, { nil, 'no_grant' }, 'no armory:mrpd')
        t.eq({ env.call('police:server:fredpdArmory', 4, 'mrpd') }, { nil, 'off_duty' }, 'civilian')
        env.tick()
        t.eq({ env.call('police:server:fredpdArmory', 1, 'nowhere') }, { nil, 'unavailable' })
        env.tick()
        H.at(env, 1, 0, 0, 0)
        t.eq({ env.call('police:server:fredpdArmory', 1, 'mrpd') }, { nil, 'too_far' })
        t.eq(#env.addItems, 0)
    end)
end

tests['armory: fredpd_core stopped -> no FredPD armory and no zones (upstream has no armory)'] = function(t)
    H.withTree(function()
        local env = server({ resources = { fredpd_core = 'stopped' } })
        t.eq({ env.call('police:server:fredpdArmory', 1, 'mrpd') }, { nil, 'unavailable' })
        t.eq(env.call('police:server:fredpdArmories', 1), {})
        local on = server()
        t.eq(on.call('police:server:fredpdArmories', 1),
            { { id = 'mrpd', coords = { x = 462.23, y = -981.12, z = 30.68 }, radius = 1.5 } }, 'positions only')
    end)
end

tests['qb-inventory hooks: ShopOpened needs the armory grant, ItemBought the item grant; none while stopped'] =
    function(t)
        H.withTree(function()
            local cfg = json.encode({ qbPolicejob = { qbShops = { policearmory = 'mrpd' } } })
            local env = server()
            t.eq(#env.hooks, 0, 'no qbShops -> no hooks')
            env.policeConfig = cfg
            env.FredPD.resetConfig()
            env.emit('onServerResourceStart', 'qb-inventory')
            t.eq(#env.hooks, 2)
            local hook = env.hooks[1].fn
            t.eq(hook('policearmory', { source = 2 }), false, 'no armory grant')
            t.eq(hook('policearmory', { source = 3 }), false, 'FredPD off duty')
            t.eq(hook('policearmory', { source = 1 }), nil, 'granted: no opinion')
            t.eq(hook('policearmory', { toId = 1, item = { name = 'weapon_carbinerifle' } }), false, 'ungranted item')
            t.eq(hook('policearmory', { toId = 1, item = { name = 'weapon_pistol' } }), nil)
            t.eq(hook('normal', { source = 4 }), nil, 'other shops untouched')
            env.resources.fredpd_core = 'stopped'
            t.eq(hook('policearmory', { source = 4 }), nil, 'fredpd_core stopped: upstream shop rules')
            env.emit('onServerResourceStart', 'qb-inventory')
            t.eq(#env.hooks, 4, 're-registered after a qb-inventory restart')
        end)
    end

tests['garage: the vehicle list is filtered by vehicle grants (FredPD off duty: empty)'] = function(t)
    H.withTree(function()
        local env = server()
        t.eq(keys(env.call('police:server:fredpdGarageVehicles', 1)), { 'police', 'police3' })
        t.eq(env.call('police:server:fredpdGarageVehicles', 2), {}, 'no vehicle grants')
        t.eq(env.call('police:server:fredpdGarageVehicles', 3), {}, 'FredPD off duty')
    end)
end

tests['garage: fredpd_core stopped -> upstream AuthorizedVehicles for the qb grade, on-duty leo only'] = function(t)
    H.withTree(function()
        local env = server({ resources = { fredpd_core = 'stopped' } })
        t.eq(#keys(env.call('police:server:fredpdGarageVehicles', 2)), 8)
        t.eq(env.call('police:server:fredpdGarageVehicles', 5), {}, 'qb off duty')
        t.eq(env.call('police:server:fredpdGarageVehicles', 4), {}, 'civilian')
    end)
end

tests['spawn: ungranted, unknown or far-away requests are not spawned; granted ones get a police plate'] =
    function(t)
        H.withTree(function()
            local env = server()
            local spot = env.G.Config.Locations.vehicle[1]
            for src in pairs(env.players) do H.at(env, src, spot.x, spot.y, spot.z) end
            t.eq(env.call('police:server:fredpdSpawnVehicle', 2, 'garage', 'police', 1), nil, 'no grant')
            t.eq(env.call('police:server:fredpdSpawnVehicle', 1, 'garage', 'police2', 1), nil, 'model not granted')
            env.tick()
            t.eq(env.call('police:server:fredpdSpawnVehicle', 1, 'garage', 'adder', 1), nil, 'not a garage model')
            env.tick()
            t.eq(env.call('police:server:fredpdSpawnVehicle', 3, 'garage', 'police', 1), nil, 'FredPD off duty')
            t.eq(env.call('police:server:fredpdSpawnVehicle', 1, 'garage', 'police', 9), nil, 'unknown spot')
            env.tick()
            t.eq(env.call('police:server:fredpdSpawnVehicle', 1, 'garage', 'police', 2), nil, 'too far from spot 2')
            t.eq(#env.spawned, 0)
            env.tick()
            local netId, plate = env.call('police:server:fredpdSpawnVehicle', 1, 'garage', 'police', 1)
            t.ok(netId, 'spawned')
            t.eq(env.spawned[1].model, 'police')
            t.eq(env.spawned[1].coords, spot, 'coordinates from config.lua, not from the client')
            t.ok(plate:match('^' .. env.G.Lang:t('info.police_plate') .. '%d%d%d%d$'), plate)
            local heli = env.G.Config.Locations.helicopter[1]
            H.at(env, 1, heli.x, heli.y, heli.z)
            env.tick()
            local _, zulu = env.call('police:server:fredpdSpawnVehicle', 1, 'helicopter', 'POLMAV', nil)
            t.ok(zulu and zulu:match('^ZULU%d%d%d%d$'), 'helicopter at the nearest pad: ' .. tostring(zulu))
            H.at(env, 2, heli.x, heli.y, heli.z)
            t.eq(env.call('police:server:fredpdSpawnVehicle', 2, 'helicopter', 'POLMAV', 1), nil, 'no vehicle:polmav')
        end)
    end

tests['spawn: impound take-out needs the impound grant and an impounded row of that model'] = function(t)
    H.withTree(function()
        local env = server()
        local lot = env.G.Config.Locations.impound[1]
        for src in pairs(env.players) do H.at(env, src, lot.x, lot.y, lot.z) end
        env.impounded['ABC123'] = 'sultan'
        t.eq(env.call('police:server:fredpdSpawnVehicle', 2, 'impound', 'sultan', 1, 'ABC123'), nil, 'no grant')
        t.eq(env.call('police:server:fredpdSpawnVehicle', 1, 'impound', 'adder', 1, 'ABC123'), nil, 'wrong model')
        env.tick()
        t.eq(env.call('police:server:fredpdSpawnVehicle', 1, 'impound', 'sultan', 1, 'XYZ999'), nil, 'not impounded')
        env.tick()
        local netId, plate = env.call('police:server:fredpdSpawnVehicle', 1, 'impound', 'sultan', 1, 'ABC123')
        t.ok(netId)
        t.eq(plate, 'ABC123')
    end)
end

tests['spawn: fredpd_core stopped -> upstream grade list and qb duty decide'] = function(t)
    H.withTree(function()
        local env = server({ resources = { fredpd_core = 'stopped' } })
        local spot = env.G.Config.Locations.vehicle[1]
        for src in pairs(env.players) do H.at(env, src, spot.x, spot.y, spot.z) end
        t.ok(env.call('police:server:fredpdSpawnVehicle', 2, 'garage', 'sheriff2', 1), 'grade list')
        t.eq(env.call('police:server:fredpdSpawnVehicle', 5, 'garage', 'police', 1), nil, 'qb off duty')
        t.eq(env.call('police:server:fredpdSpawnVehicle', 4, 'garage', 'police', 1), nil, 'civilian')
    end)
end

tests['client: the garage menu and all spawns go through the FredPD callbacks'] = function(t)
    H.withTree(function(tr)
        local job = tr.files['client/job.lua']
        t.ok(not job:find('QBCore:Server:SpawnVehicle', 1, true), 'no unchecked qb-core spawn callback left')
        t.ok(not job:find('Config.AuthorizedVehicles', 1, true), 'the client no longer builds the list by grade')
        local _, spawns = job:gsub("'police:server:fredpdSpawnVehicle'", '')
        t.eq(spawns, 3, 'garage, impound, helicopter')
        t.ok(job:find("'police:server:fredpdGarageVehicles'", 1, true))
    end)
end

tests['client armory: zones from the server, menu from the filtered list, take goes to the server'] = function(t)
    H.withTree(function()
        local points = { { id = 'mrpd', coords = { x = 462.23, y = -981.12, z = 30.68 }, radius = 1.5 } }
        local items = { { name = 'weapon_pistol', label = 'Walther P99', count = 1 } }
        local function setup(env)
            env.clientCallbacks = {
                ['police:server:fredpdArmories'] = function() return points end,
                ['police:server:fredpdArmory'] = function(id) return { id = id, label = 'Mission Row', items = items } end,
                ['police:server:fredpdArmoryTake'] = function() return nil, 'limit' end,
            }
        end
        local env = H.client({ 'fredpd/client.lua' }, {}, setup)
        env.emit('onClientResourceStart', 'qb-policejob')
        t.eq(#env.boxZones, 1, 'PolyZone box without Config.UseTarget')
        env.boxZones[1].inOut(true)
        t.eq(env.headers[1][1].params.args, { id = 'mrpd' })
        env.fire('police:client:fredpdArmory', nil, { id = 'mrpd' })
        local menu = env.menus[1]
        t.eq(menu[2].header, 'Walther P99')
        t.eq(#menu, 3, 'header, one item, close')
        env.fire('police:client:fredpdArmoryTake', nil, menu[2].params.args)
        local last = env.serverEvents[#env.serverEvents]
        t.eq({ last.name, last.args[1], last.args[2] }, { 'callback:police:server:fredpdArmoryTake', 'mrpd', 'weapon_pistol' })
        t.eq(env.notifies[#env.notifies].msg, env.G.Lang:t('fredpd.armory_limit'))
        local target = H.client({ 'fredpd/client.lua' }, { convars = { UseTarget = 'true' } }, setup)
        target.emit('onClientResourceStart', 'qb-target')
        t.ok(target.targetZones.fredpd_armory_mrpd, 'qb-target zone with Config.UseTarget')
        t.eq(target.targetZones.fredpd_armory_mrpd.options.options[1].jobType, 'leo')
    end)
end

return tests
