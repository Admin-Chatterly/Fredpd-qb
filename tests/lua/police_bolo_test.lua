-- SPDX-License-Identifier: GPL-3.0-only
-- qbx_police patch 30 'bolo-hooks' (patches/qbx_policejob.30-bolo-hooks.patch): ANPR radar passes (task 3.3) are
-- validated server-side and an active FredPD efterlysning (exports.fredpd_bolo:checkPlate) fires
-- fredpd:boloHit(bolo, context) once per plate and radar per cooldown; /flagplate flags keep the qbx alert (now to
-- every on-duty officer); impound calls exports.fredpd_bolo:resolveOnImpound(plate, src) (IMPLEMENTATION.md §5.4).
-- Run: lua5.4 tests/lua/run.lua police_bolo
local H = require('police_harness_test')

local tests = {}

local RADAR3 = H.vec(1623.0114746094, 1068.9924316406, 80.903594970703)
local CAR = 4400
local BOLO = { id = 7, kind = 'vehicle', plate = 'ABC123', reason = 'Rån', level = 0, active = true }

--- Player 4 (civilian) drives CAR with plate 'ABC 123' past radar #3.
local function server(opts)
    opts = opts or {}
    opts.players = opts.players or H.cast()
    local env = H.server(opts)
    env.pedVehicle[1004] = CAR
    env.driver[CAR] = 1004
    env.plates[CAR] = 'ABC 123'
    env.coords[1004] = RADAR3 + H.vec(12, 5, 0)
    return env
end

local function pass(env, src, radar, plate, street)
    env.now = env.now + 1000
    env.fire('police:server:FlaggedPlateTriggered', src or 4, radar or 3, plate or 'ABC 123', street or 'Vespucci Blvd')
end

tests['radar: an active efterlysning fires fredpd:boloHit once with the context, no qbx alert'] = function(t)
    H.withTree(function()
        local env = server()
        env.bolos.ABC123 = BOLO
        pass(env)
        local hits = env.named(env.events, 'fredpd:boloHit')
        t.eq(#hits, 1)
        t.eq(hits[1].args[1], BOLO)
        t.eq(hits[1].args[2], { source = 'radar', plate = 'ABC123', coords = { x = 1635.01, y = 1073.99, z = 80.9 },
            street = 'Vespucci Blvd', radar = 3 })
        t.eq(#env.named(env.clientEvents, 'police:client:policeAlert'), 0, 'fredpd_bolo raises the larm')
        pass(env)
        t.eq(#env.named(env.events, 'fredpd:boloHit'), 1, 'cooldown: same plate and radar')
        env.now = env.now + 60000
        pass(env)
        t.eq(#env.named(env.events, 'fredpd:boloHit'), 2, 'after radar.cooldownSeconds')
    end)
end

tests['radar: fredpd_dispatch not running -> the efterlysning hit raises the qbx alert instead (once per cooldown)'] =
    function(t)
        H.withTree(function()
            local env = server({ resources = { fredpd_dispatch = 'stopped' } })
            env.bolos.ABC123 = BOLO
            env.G.Plates['ABC 123'] = { isflagged = true, reason = 'x' }
            pass(env)
            t.eq(#env.named(env.events, 'fredpd:boloHit'), 1, 'fredpd_bolo still records the hit')
            local alerts = env.named(env.clientEvents, 'police:client:policeAlert')
            t.eq(#alerts, 4, 'every on-duty officer (1, 2, 7, 12)')
            local phone = env.named(env.clientEvents, 'qb-phone:client:addPoliceAlert')
            t.eq(#phone, 4)
            t.eq(phone[1].args[1].description, 'fredpd.bolo_radar|ABC 123|Vespucci Blvd|3', 'efterlysning text')
            env.clear()
            pass(env)
            t.eq(#env.named(env.events, 'fredpd:boloHit'), 0, 'cooldown')
            phone = env.named(env.clientEvents, 'qb-phone:client:addPoliceAlert')
            t.eq(#phone, 4, 'cooling down: the /flagplate flag alerts as upstream')
            t.eq(phone[1].args[1].description, 'info.plate_triggered|ABC 123|Vespucci Blvd|3')
            env.G.Plates['ABC 123'] = nil
            env.clear()
            pass(env)
            t.eq(#env.clientEvents, 0, 'cooling down and not flagged: nothing')
            env.now = env.now + 60000
            pass(env)
            t.eq(#env.named(env.events, 'fredpd:boloHit'), 1)
            t.eq(#env.named(env.clientEvents, 'police:client:policeAlert'), 4, 'after the cooldown: alert again')
        end)
    end

tests['radar: fredpd_dispatch running -> fredpd_bolo alerts; a flagged plate with an efterlysning gets no qbx alert'] =
    function(t)
        H.withTree(function()
            local env = server()
            env.bolos.ABC123 = BOLO
            env.G.Plates['ABC 123'] = { isflagged = true, reason = 'x' }
            pass(env)
            pass(env)
            t.eq(#env.named(env.events, 'fredpd:boloHit'), 1)
            t.eq(#env.clientEvents, 0, 'no double larm')
        end)
    end

tests['radar: another radar within the cooldown is a new hit'] = function(t)
    H.withTree(function()
        local env = server()
        env.bolos.ABC123 = BOLO
        pass(env)
        env.coords[1004] = H.vec(-623.44421386719, -823.08361816406, 25.25704574585)
        pass(env, 4, 1)
        local hits = env.named(env.events, 'fredpd:boloHit')
        t.eq(#hits, 2)
        t.eq(hits[2].args[2].radar, 1)
    end)
end

tests['radar: forged or impossible passes are ignored before any lookup'] = function(t)
    H.withTree(function()
        local env = server()
        env.bolos.ABC123 = BOLO
        pass(env, 4, 3, 'XYZ 999') -- plate is not the vehicle's
        pass(env, 4, 99) -- no such radar
        pass(env, 4, 'x')
        pass(env, 4, 1) -- far from radar #1
        env.driver[CAR] = 1007
        pass(env) -- passenger, not the driver
        env.driver[CAR] = 1004
        env.pedVehicle[1004] = nil
        pass(env) -- on foot
        pass(env, 2) -- player 2 is not in the car
        t.eq(env.boloChecks, nil, 'fredpd_bolo was never asked')
        t.eq(#env.events, 0)
        t.eq(#env.clientEvents, 0)
        env.pedVehicle[1004] = CAR
        env.fire('police:server:FlaggedPlateTriggered', 4, 3, 'ABC 123', 'x')
        env.fire('police:server:FlaggedPlateTriggered', 4, 3, 'ABC 123', 'x')
        t.eq(#env.named(env.events, 'fredpd:boloHit'), 1, 'one report per second per client')
    end)
end

tests['radar: a /flagplate flag without efterlysning alerts every on-duty officer (sparse ids)'] = function(t)
    H.withTree(function()
        local env = server()
        env.G.Plates['ABC 123'] = { isflagged = true, reason = 'x' }
        pass(env)
        local targets = {}
        for _, e in ipairs(env.named(env.clientEvents, 'police:client:policeAlert')) do targets[#targets + 1] = e.target end
        table.sort(targets)
        t.eq(targets, { 1, 2, 7, 12 }, '3 is off duty in FredPD, 4 is a civilian')
        local phone = env.named(env.clientEvents, 'qb-phone:client:addPoliceAlert')[1]
        t.eq(phone.args[1].description, 'info.plate_triggered|ABC 123|Vespucci Blvd|3')
        t.eq(#env.named(env.events, 'fredpd:boloHit'), 0)
        t.eq(env.boloChecks, 1)
    end)
end

tests['radar: nothing flagged -> nothing happens'] = function(t)
    H.withTree(function()
        local env = server()
        pass(env)
        t.eq(#env.events, 0)
        t.eq(#env.clientEvents, 0)
    end)
end

tests['radar: fredpd_bolo stopped or failing -> no boloHit, no error; flags still alert'] = function(t)
    H.withTree(function()
        local env = server({ resources = { fredpd_bolo = 'stopped' } })
        env.bolos.ABC123 = BOLO
        pass(env)
        t.eq(#env.events, 0)
        t.eq(env.boloChecks, nil)
        local failing = server()
        failing.bolos.ABC123 = BOLO
        failing.boloThrows = true
        failing.G.Plates['ABC 123'] = { isflagged = true }
        pass(failing)
        t.eq(#failing.named(failing.events, 'fredpd:boloHit'), 0)
        t.eq(#failing.named(failing.clientEvents, 'police:client:policeAlert'), 4, 'falls back to the flag')
        local warned = false
        for _, l in ipairs(failing.logs) do if l.msg:find('checkPlate', 1, true) then warned = true end end
        t.ok(warned, 'export failure logged')
    end)
end

tests['radar: fredpd_core stopped -> no efterlysning lookup; /flagplate alert by qbx duty (upstream)'] = function(t)
    H.withTree(function()
        local env = server({ resources = { fredpd_core = 'stopped' } })
        env.bolos.ABC123 = BOLO
        env.G.Plates['ABC 123'] = { isflagged = true }
        pass(env)
        t.eq(env.boloChecks, nil)
        t.eq(#env.named(env.clientEvents, 'police:client:policeAlert'), 5, 'players 1, 2, 3, 7, 12 by qbx duty')
    end)
end

tests['radar: police:server:isPlateFlagged answers on-duty officers only, never from efterlysningar'] = function(t)
    H.withTree(function()
        local env = server()
        env.bolos.ABC123 = BOLO
        t.ok(not env.call('police:server:isPlateFlagged', 1, 'ABC123'), 'an efterlysning is not a /flagplate flag')
        env.G.Plates.ABC123 = { isflagged = true }
        t.eq(env.call('police:server:isPlateFlagged', 1, 'ABC123'), true, 'officer on duty: /flagplate flag')
        t.eq(env.call('police:server:isPlateFlagged', 4, 'ABC123'), false, 'a driver/civilian learns nothing')
        t.eq(env.call('police:server:isPlateFlagged', 3, 'ABC123'), false, 'FredPD off duty learns nothing')

        local up = server({ resources = { fredpd_core = 'stopped' } })
        up.G.Plates.ABC123 = { isflagged = true }
        t.eq(up.call('police:server:isPlateFlagged', 4, 'ABC123'), true, 'fredpd_core stopped: upstream (anyone)')
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Impound

local function impoundEnv(opts)
    local env = server(opts)
    env.netEntities[55] = 5500
    env.plates[5500] = 'abc 123'
    env.owned['abc 123'] = true
    return env
end

tests['impound: success calls fredpd_bolo resolveOnImpound(normalised plate, src) once'] = function(t)
    H.withTree(function()
        local env = impoundEnv()
        env.fire('police:server:Impound', 1, 'abc 123', false, 250, 900, 900, 50, 55)
        t.eq(env.resolved, { { plate = 'ABC123', src = 1 } })
        t.eq(env.deleted, { 5500 })
    end)
end

tests['impound: refused impound resolves nothing; stopped or failing fredpd_bolo does not block impound'] = function(t)
    H.withTree(function()
        local env = impoundEnv()
        env.fire('police:server:Impound', 2, 'abc 123', false, 250, 900, 900, 50, 55)
        t.eq(env.resolved, {})
        local stopped = impoundEnv({ resources = { fredpd_bolo = 'stopped' } })
        stopped.fire('police:server:Impound', 1, 'abc 123', true, 0, 900, 900, 50, 55)
        t.eq(stopped.resolved, {})
        t.eq(stopped.deleted, { 5500 })
        local failing = impoundEnv()
        failing.impl.fredpd_bolo.resolveOnImpound = function() error('db down', 0) end
        failing.fire('police:server:Impound', 1, 'abc 123', true, 0, 900, 900, 50, 55)
        t.eq(failing.deleted, { 5500 })
        t.eq(failing.audits[1].action, 'police.impound')
        local core = impoundEnv({ resources = { fredpd_core = 'stopped' } })
        core.fire('police:server:Impound', 2, 'abc 123', true, 0, 900, 900, 50, 55)
        t.eq(core.deleted, { 5500 }, 'upstream: any on-duty leo')
        t.eq(core.resolved, {}, 'no FredPD, no resolve')
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Client ANPR

tests['client anpr: every pass is reported with its own radar index, without asking isPlateFlagged'] = function(t)
    H.withTree(function()
        local env = H.client('client/anpr.lua', {}, function(e)
            e.G.require('config.client').radars.enableRadars = true
        end)
        t.eq(#env.threads, 1)
        env.threads[1]()
        t.eq(#env.points, 11)
        env.G.cache.vehicle = CAR
        env.plates[CAR] = 'ABC 123'
        env.points[3]:onEnter()
        local reports = env.named(env.serverEvents, 'police:server:FlaggedPlateTriggered')
        t.eq(#reports, 1)
        t.eq({ reports[1].args[1], reports[1].args[2], reports[1].args[3] }, { 3, 'ABC 123', 'Vespucci Blvd' })
        t.eq(#env.named(env.serverEvents, 'callback:police:server:isPlateFlagged'), 0)
        env.G.cache.seat = 0
        env.points[5]:onEnter()
        t.eq(#env.named(env.serverEvents, 'police:server:FlaggedPlateTriggered'), 1, 'passengers do not report')
    end)
end

tests['client anpr: radars stay off by default (config/client.lua enableRadars = false)'] = function(t)
    H.withTree(function()
        local env = H.client('client/anpr.lua')
        t.eq(#env.threads, 0)
    end)
end

tests['plate normalisation matches FredPD (upper case, no whitespace)'] = function(t)
    H.withTree(function()
        local env = server()
        t.eq(env.Bolo.normalizePlate(' abc 12d '), 'ABC12D')
        t.eq(env.Bolo.normalizePlate('LSPD1234'), 'LSPD1234')
        t.eq(env.Bolo.normalizePlate(''), nil)
        t.eq(env.Bolo.normalizePlate('ABC;DROP'), nil)
        t.eq(env.Bolo.normalizePlate(12), nil)
        t.eq(env.Bolo.cleanStreet('Señora Fwy\n| x'), 'Señora Fwy | x')
        t.eq(#env.Bolo.cleanStreet(string.rep('å', 150)), 200, '100 characters, cut on a character boundary')
        t.eq(env.Bolo.cleanStreet('\255bad'), nil)
    end)
end

return tests
