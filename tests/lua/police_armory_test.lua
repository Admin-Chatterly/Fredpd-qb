-- SPDX-License-Identifier: GPL-3.0-only
-- qbx_police patch 10 'grants', armory and garage part: FredPD armories (config/police.json) send only granted
-- items and re-check every take server-side; the ox_inventory PoliceArmoury shop is guarded by openShop/buyItem
-- hooks; the police garage list is filtered by vehicle grants and qbx_policejob:server:spawnVehicle re-checks the
-- model. fredpd_core stopped -> upstream behaviour. Run: lua5.4 tests/lua/run.lua police_armory
local H = require('police_harness_test')

local tests = {}

local ARMORY = H.vec(462.23, -981.12, 30.68)

local function server(opts)
    opts = opts or {}
    opts.players = opts.players or H.cast()
    local env = H.server(opts)
    for src in pairs(env.players) do env.coords[1000 + src] = ARMORY end
    return env
end

local function names(items)
    local out = {}
    for _, item in ipairs(items) do out[#out + 1] = item.name end
    table.sort(out)
    return out
end

---------------------------------------------------------------------------------------------------------------
-- FredPD armory

tests['armory: the list sent to the client holds only granted weapons and items'] = function(t)
    H.withTree(function()
        local env = server()
        local data = env.call('qbx_policejob:server:fredpdArmory', 1, 'mrpd')
        t.eq(data.id, 'mrpd')
        t.eq(data.label, 'Mission Row')
        t.eq(names(data.items), { 'WEAPON_PISTOL', 'ammo-9' })
        t.eq(data.items[1], { name = 'WEAPON_PISTOL', label = 'Pistol', count = 1 })
        env.spec(1).grants['weapon:*'] = true
        env.now = env.now + 1000
        data = env.call('qbx_policejob:server:fredpdArmory', 1, 'mrpd')
        t.eq(names(data.items), { 'WEAPON_CARBINERIFLE', 'WEAPON_FLASHLIGHT', 'WEAPON_NIGHTSTICK', 'WEAPON_PISTOL',
            'WEAPON_STUNGUN', 'ammo-9' }, 'weapon:* grants every weapon, items still need armory:<item>')
        env.spec(1).denied = { ['weapon:weapon_carbinerifle'] = true }
        env.now = env.now + 1000
        data = env.call('qbx_policejob:server:fredpdArmory', 1, 'mrpd')
        t.eq(#data.items, 5, 'deny wins over the wildcard')
    end)
end

tests['armory: an ungranted item is refused even when the client sends it; granted take is handed out once'] = function(t)
    H.withTree(function()
        local env = server()
        local ok, err = env.call('qbx_policejob:server:fredpdArmoryTake', 1, 'mrpd', 'WEAPON_CARBINERIFLE')
        t.eq({ ok, err }, { nil, 'no_grant' })
        env.now = env.now + 1000
        ok, err = env.call('qbx_policejob:server:fredpdArmoryTake', 1, 'mrpd', 'WEAPON_RPG')
        t.eq({ ok, err }, { nil, 'unavailable' }, 'not in this armory')
        t.eq(#env.addItems, 0)
        env.now = env.now + 1000
        t.eq(env.call('qbx_policejob:server:fredpdArmoryTake', 1, 'mrpd', 'WEAPON_PISTOL'), true)
        t.eq(env.addItems, { { src = 1, name = 'WEAPON_PISTOL', count = 1, metadata = { serial = 'POL' } } })
        t.eq(env.audits[1].action, 'police.armory')
        t.eq(env.audits[1].targetId, 'weapon_pistol')
        t.eq(env.audits[1].meta, { armory = 'mrpd', count = 1 })
        ok, err = env.call('qbx_policejob:server:fredpdArmoryTake', 1, 'mrpd', 'WEAPON_PISTOL')
        t.eq(err, 'rate_limited', 'one take per second')
        env.now = env.now + 1000
        t.eq(env.call('qbx_policejob:server:fredpdArmoryTake', 1, 'mrpd', 'ammo-9'), true)
        t.eq(env.addItems[2].count, 50)
    end)
end

tests['armory: an item with max is refused while the officer already carries that many'] = function(t)
    H.withTree(function()
        local env = server()
        env.carried[1] = { WEAPON_PISTOL = 1, ['ammo-9'] = 149 }
        t.eq(select(2, env.call('qbx_policejob:server:fredpdArmoryTake', 1, 'mrpd', 'WEAPON_PISTOL')), 'limit',
            'max 1 pistol')
        env.now = env.now + 1000
        t.eq(env.call('qbx_policejob:server:fredpdArmoryTake', 1, 'mrpd', 'ammo-9'), true, '149 < max 150')
        env.carried[1]['ammo-9'] = 199
        env.now = env.now + 1000
        t.eq(select(2, env.call('qbx_policejob:server:fredpdArmoryTake', 1, 'mrpd', 'ammo-9')), 'limit')
        t.eq(#env.addItems, 1)
        t.eq(#env.audits, 1)
        env.policeConfig = json.encode({ armories = { mrpd = { coords = { 462.23, -981.12, 30.68 },
            items = { { name = 'WEAPON_PISTOL', count = 1 } } } } })
        env.FredPD.resetConfig()
        env.now = env.now + 1000
        t.eq(env.call('qbx_policejob:server:fredpdArmoryTake', 1, 'mrpd', 'WEAPON_PISTOL'), true, 'no max: no limit')
    end)
end

tests['armory: off duty, no armory grant, too far, cannot carry, unknown armory'] = function(t)
    H.withTree(function()
        local env = server()
        t.eq(select(2, env.call('qbx_policejob:server:fredpdArmory', 3, 'mrpd')), 'off_duty')
        t.eq(select(2, env.call('qbx_policejob:server:fredpdArmory', 2, 'mrpd')), 'no_grant')
        t.eq(select(2, env.call('qbx_policejob:server:fredpdArmory', 4, 'mrpd')), 'off_duty')
        t.eq(select(2, env.call('qbx_policejob:server:fredpdArmory', 7, 'nope')), 'unavailable')
        env.coords[1001] = H.vec(0, 0, 0)
        t.eq(select(2, env.call('qbx_policejob:server:fredpdArmoryTake', 1, 'mrpd', 'WEAPON_PISTOL')), 'too_far')
        env.coords[1001] = ARMORY
        env.canCarry = false
        env.now = env.now + 1000
        t.eq(select(2, env.call('qbx_policejob:server:fredpdArmoryTake', 1, 'mrpd', 'WEAPON_PISTOL')), 'full')
        t.eq(#env.addItems, 0)
        t.eq(#env.audits, 0)
    end)
end

tests['armory: fredpd_core stopped -> no FredPD armory (the ox_inventory shop keeps its own rules)'] = function(t)
    H.withTree(function()
        local env = server({ resources = { fredpd_core = 'stopped' } })
        t.eq(select(2, env.call('qbx_policejob:server:fredpdArmory', 1, 'mrpd')), 'unavailable')
        t.eq(select(2, env.call('qbx_policejob:server:fredpdArmoryTake', 2, 'mrpd', 'WEAPON_PISTOL')), 'unavailable')
        t.eq(env.call('qbx_policejob:server:fredpdArmories', 1), {})
        t.eq(#env.addItems, 0)
    end)
end

tests['armory: the client zones get positions only'] = function(t)
    H.withTree(function()
        local env = server()
        t.eq(env.call('qbx_policejob:server:fredpdArmories', 4),
            { { id = 'mrpd', coords = { x = 462.23, y = -981.12, z = 30.68 }, radius = 1.5 } })
    end)
end

---------------------------------------------------------------------------------------------------------------
-- ox_inventory PoliceArmoury hooks

local function hook(env, event)
    for _, h in ipairs(env.hooks) do if h.event == event then return h end end
end

tests['ox_inventory hooks: buyItem rejects ungranted items, openShop needs the armory grant'] = function(t)
    H.withTree(function()
        local env = server()
        local buy, open = hook(env, 'buyItem'), hook(env, 'openShop')
        t.ok(buy and open, 'both hooks registered at start')
        t.eq(buy.options, { typeFilter = { PoliceArmoury = true } })
        t.eq(buy.fn({ source = 1, shopType = 'PoliceArmoury', itemName = 'WEAPON_CARBINERIFLE', count = 1 }), false)
        t.eq(env.lastNotify(1).msg, 'fredpd.no_permission')
        t.eq(buy.fn({ source = 1, shopType = 'PoliceArmoury', itemName = 'WEAPON_PISTOL', count = 1 }), nil)
        t.eq(buy.fn({ source = 1, shopType = 'PoliceArmoury', itemName = 'ammo-rifle', count = 1 }), false)
        t.eq(buy.fn({ source = 3, shopType = 'PoliceArmoury', itemName = 'WEAPON_PISTOL', count = 1 }), false,
            'off duty')
        t.eq(open.fn({ source = 2, shopType = 'PoliceArmoury' }), false, 'no armory:mrpd')
        t.eq(open.fn({ source = 1, shopType = 'PoliceArmoury' }), nil)
        t.eq(open.fn({ source = 2, shopType = 'Medicine' }), nil, 'other shops untouched')
    end)
end

tests['ox_inventory hooks: no opinion while fredpd_core is stopped; re-registered when ox_inventory restarts'] = function(t)
    H.withTree(function()
        local env = server()
        env.resources.fredpd_core = 'stopped'
        t.eq(hook(env, 'buyItem').fn({ source = 4, shopType = 'PoliceArmoury', itemName = 'WEAPON_PISTOL' }), nil)
        t.eq(#env.hooks, 2)
        for _, fn in ipairs(env.handlers.onServerResourceStart) do fn('ox_inventory') end
        t.eq(#env.hooks, 4, 'registered again for the new ox_inventory instance')
        for _, fn in ipairs(env.handlers.onServerResourceStart) do fn('ox_target') end
        t.eq(#env.hooks, 4)
    end)
end

tests['ox_inventory hooks: not registered while ox_inventory is not started'] = function(t)
    H.withTree(function()
        local env = server({ resources = { ox_inventory = 'stopped' } })
        t.eq(#env.hooks, 0)
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Garage

local SPAWN = H.vec(452.0, -996.0, 26.0, 175.0)      -- config/shared.lua locations.vehicle[1]
local HELIPAD = H.vec(449.168, -981.325, 43.691)     -- config/shared.lua locations.helicopter[1]
local IMPOUND = H.vec(436.68, -1007.42, 27.32)        -- config/shared.lua locations.impound[1]

tests['garage: the vehicle list is filtered by vehicle grants (off duty: empty)'] = function(t)
    H.withTree(function()
        local env = server()
        t.eq(env.call('qbx_policejob:server:garageVehicles', 1), { police = 'Police Car 1', police3 = 'Police Car 3' })
        env.now = env.now + 1000
        t.eq(env.call('qbx_policejob:server:garageVehicles', 2), {})
        t.eq(env.call('qbx_policejob:server:garageVehicles', 3), {})
    end)
end

tests['garage: fredpd_core stopped -> upstream list for the qbx grade + whitelisted'] = function(t)
    H.withTree(function()
        local env = server({ resources = { fredpd_core = 'stopped' } })
        local list = env.call('qbx_policejob:server:garageVehicles', 2)
        local n = 0
        for _ in pairs(list) do n = n + 1 end
        t.eq(n, 8, 'authorizedVehicles[4]')
        t.eq(list.sheriff2, 'Sheriff Car 2')
        t.eq(env.call('qbx_policejob:server:garageVehicles', 4), {}, 'civilian grade 0 of job unemployed')
    end)
end

tests['spawn: ungranted or unknown models are not spawned; granted ones are'] = function(t)
    H.withTree(function()
        local env = server()
        env.coords[1001] = SPAWN
        t.eq(env.call('qbx_policejob:server:spawnVehicle', 1, 'police2', SPAWN, 'LSPD1111', true), nil)
        env.now = env.now + 2000
        t.eq(env.call('qbx_policejob:server:spawnVehicle', 1, 'adder', SPAWN, 'LSPD1111', true), nil,
            'not a garage vehicle')
        t.eq(#env.spawned, 0)
        env.now = env.now + 2000
        t.eq(env.call('qbx_policejob:server:spawnVehicle', 1, 'police3', SPAWN, 'LSPD1111', true), 77)
        t.eq(#env.spawned, 1)
        t.eq(env.spawned[1].model, 'police3')
        t.eq(env.call('qbx_policejob:server:spawnVehicle', 1, 'police3', SPAWN, 'LSPD1111', true), nil,
            'one spawn per 2 s')
        env.now = env.now + 2000
        env.coords[1001] = HELIPAD
        local heli = H.vec(HELIPAD.x + 1.5, HELIPAD.y - 1.5, HELIPAD.z, 87.0) -- the officer inside the 4 m zone
        t.eq(env.call('qbx_policejob:server:spawnVehicle', 1, 'polmav', heli, 'ZULU1111', true), 77, 'helicopter')
        env.coords[1001] = SPAWN
        env.now = env.now + 2000
        t.eq(env.call('qbx_policejob:server:spawnVehicle', 1, 'police3', H.vec(0, 0, 0), 'LSPD1111', true), nil,
            'spawn point far from the officer')
        env.now = env.now + 2000
        env.coords[1003] = SPAWN
        t.eq(env.call('qbx_policejob:server:spawnVehicle', 3, 'police', SPAWN, 'LSPD1111', true), nil, 'off duty')
        t.eq(#env.spawned, 2)
    end)
end

tests['spawn: impound take-out needs perm:police.impound and an impounded row of that model'] = function(t)
    H.withTree(function()
        local env = server()
        env.coords[1001], env.coords[1002] = IMPOUND, IMPOUND
        env.impounded['XYZ 999'] = 'sultan'
        t.eq(env.call('qbx_policejob:server:spawnVehicle', 1, 'adder', IMPOUND, 'XYZ 999', 42), nil, 'model mismatch')
        env.now = env.now + 2000
        t.eq(env.call('qbx_policejob:server:spawnVehicle', 2, 'sultan', IMPOUND, 'XYZ 999', 42), nil,
            'no impound grant')
        t.eq(env.call('qbx_policejob:server:spawnVehicle', 1, 'sultan', IMPOUND, 'XYZ 999', 42), 77)
        t.eq(#env.spawned, 1)
    end)
end

tests['spawn: only at the garage/helipad/impound location with a police plate (client coords are not trusted)'] =
    function(t)
        H.withTree(function()
            local env = server()
            local function spawn(model, coords, plate, giveKeys)
                env.coords[1001] = coords
                env.now = env.now + 2000
                return env.call('qbx_policejob:server:spawnVehicle', 1, model, coords, plate, giveKeys)
            end
            local street = H.vec(100.0, 200.0, 30.0, 0.0)
            t.eq(spawn('police3', street, 'LSPD1111', true), nil, 'granted car away from every garage')
            t.eq(spawn('polmav', street, 'ZULU1111', true), nil, 'helicopter away from the helipads')
            t.eq(spawn('polmav', SPAWN, 'ZULU1111', true), nil, 'helicopter at a car garage')
            t.eq(spawn('police3', HELIPAD, 'LSPD1111', true), nil, 'car at the helipad')
            t.eq(spawn('police3', SPAWN, 'ABC123', true), nil, 'a civilian plate (copy of an owned car)')
            t.eq(spawn('police3', SPAWN, 'LSPD11111', true), nil, 'longer than 8 characters')
            t.eq(spawn('police3', SPAWN, 'LSPD 111', true), nil, 'whitespace')
            t.eq(spawn('polmav', HELIPAD, 'LSPD1111', true), nil, 'helicopter needs a ZULU plate')
            env.impounded['XYZ 999'] = 'sultan'
            t.eq(spawn('sultan', street, 'XYZ 999', 42), nil, 'impound take-out away from the impound lot')
            t.eq(#env.spawned, 0)
            t.eq(spawn('police3', H.vec(463.0, -1015.0, 28.0, 87.0), 'LSPD1234', true), 77, 'garage 4')
            t.eq(spawn('polmav', H.vec(-475.43, 5988.353, 31.716, 31.34), 'ZULU1234', true), 77, 'Paleto helipad')
            t.eq(spawn('sultan', H.vec(-436.14, 5982.63, 31.34), 'XYZ 999', 42), 77, 'Paleto impound')
        end)
    end

tests['spawn: fredpd_core stopped -> upstream (no check)'] = function(t)
    H.withTree(function()
        local env = server({ resources = { fredpd_core = 'stopped' } })
        t.eq(env.call('qbx_policejob:server:spawnVehicle', 4, 'adder', H.vec(0, 0, 0), 'LSPD1111', true), 77)
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Clients

tests['client armory: zones from the server, menu from the filtered list, take goes to the server'] = function(t)
    H.withTree(function()
        local env = H.client('fredpd/client.lua', {}, function(e)
            e.clientCallbacks = {
                ['qbx_policejob:server:fredpdArmories'] = function()
                    return { { id = 'mrpd', coords = { x = 1, y = 2, z = 3 }, radius = 1.5 } }
                end,
                ['qbx_policejob:server:fredpdArmory'] = function(id)
                    return { id = id, label = 'Mission Row',
                        items = { { name = 'WEAPON_PISTOL', label = 'Pistol', count = 1 } } }
                end,
                ['qbx_policejob:server:fredpdArmoryTake'] = function() return nil, 'no_grant' end,
            }
        end)
        t.eq(#env.threads, 1, 'zones are loaded once in a one-shot thread')
        env.threads[1]()
        t.eq(#env.zones, 1)
        local option = env.zones[1].options[1]
        t.eq(option.name, 'fredpd_armory_mrpd')
        t.eq(option.label, 'menu.pol_armory')
        t.eq(option.canInteract(), true)
        env.G.QBX.PlayerData.job.onduty = false
        t.eq(option.canInteract(), false)
        option.onSelect()
        t.eq(env.shownContext, 'fredpd_armory')
        t.eq(env.contexts[1].title, 'fredpd.armory_title|Mission Row')
        t.eq(#env.contexts[1].options, 1)
        env.contexts[1].options[1].onSelect()
        local take = env.named(env.serverEvents, 'callback:qbx_policejob:server:fredpdArmoryTake')[1]
        t.eq({ take.args[1], take.args[2] }, { 'mrpd', 'WEAPON_PISTOL' })
        t.eq(env.notifies[#env.notifies].msg, 'fredpd.no_permission', 'server refusal shown')
        env.handlers.onClientResourceStart[1]('fredpd_core')
        env.threads[2]()
        t.eq(env.zones[1], false, 'old zone removed on reload')
        t.eq(#env.zones, 2)
    end)
end

tests['client garage: the menu comes from the server callback, not from the qbx grade'] = function(t)
    H.withTree(function(tr)
        local src = tr.files['client/job.lua']
        t.ok(src:find("lib.callback.await('qbx_policejob:server:garageVehicles', false)", 1, true))
        t.ok(not src:find('config.authorizedVehicles[QBX.PlayerData.job.grade.level]', 1, true))
    end)
end

return tests
