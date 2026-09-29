-- SPDX-License-Identifier: GPL-3.0-only
-- qb-policejob patch 30 'bolo-hooks': ANPR radar passes consult exports.fredpd_bolo:checkPlate (pcall) and fire
-- fredpd:boloHit { source = 'radar' } once per plate, radar and cooldown; qb-policejob's own alert covers the hit
-- while fredpd_dispatch is down; a successful impound calls exports.fredpd_bolo:resolveOnImpound.
-- Run: lua5.4 tests/lua/run.lua qbpolice_bolo
local H = require('qbpolice_harness_test')

local tests = {}

local VEH = 77

local function sent(env, name)
    local out = {}
    for _, e in ipairs(env.clientEvents) do if e.name == name then out[#out + 1] = e end end
    return out
end

local function hits(env)
    local out = {}
    for _, e in ipairs(env.events) do if e.name == 'fredpd:boloHit' then out[#out + 1] = e end end
    return out
end

--- Civilian 4 drives VEH (plate 'ABC 123') past radar `radar`.
local function server(opts, radar)
    opts = opts or {}
    opts.players = opts.players or H.cast()
    local env = H.server(opts)
    local ped = 1004
    env.pedVehicle[ped] = VEH
    env.driver[VEH] = ped
    env.plates[VEH] = 'ABC 123 '
    local r = env.G.Config.Radars[radar or 1]
    H.at(env, 4, r.x, r.y, r.z)
    return env
end

local function pass(env, radar, plate, street)
    env.fire('police:server:FlaggedPlateTriggered', 4, radar or 1, plate or 'ABC 123 ', street or 'Vespucci Blvd')
end

tests['radar: an active efterlysning fires fredpd:boloHit once with the context; no qb alert'] = function(t)
    H.withTree(function()
        local env = server()
        env.bolos.ABC123 = { id = 7, plate = 'ABC123' }
        pass(env)
        local h = hits(env)
        t.eq(#h, 1)
        t.eq(h[1].args[1], { id = 7, plate = 'ABC123' })
        local r = env.G.Config.Radars[1]
        t.eq(h[1].args[2], { source = 'radar', plate = 'ABC123', radar = 1, street = 'Vespucci Blvd',
            coords = { x = r.x, y = r.y, z = r.z } })
        t.eq(#sent(env, 'police:client:policeAlert'), 0, 'fredpd_bolo raises the larm through fredpd_dispatch')
        env.tick(1500)
        pass(env)
        t.eq(#hits(env), 1, 'cooldown: once per plate and radar')
        env.tick(60000)
        pass(env)
        t.eq(#hits(env), 2, 'after radar.cooldownSeconds')
    end)
end

tests['radar: another radar within the cooldown is a new hit'] = function(t)
    H.withTree(function()
        local env = server()
        env.bolos.ABC123 = { id = 7 }
        pass(env, 1)
        local r = env.G.Config.Radars[2]
        H.at(env, 4, r.x, r.y, r.z)
        env.tick(1500)
        pass(env, 2)
        t.eq(#hits(env), 2)
        t.eq(hits(env)[2].args[2].radar, 2)
    end)
end

tests['radar: fredpd_dispatch down -> the hit raises the qb alert to on-duty police instead'] = function(t)
    H.withTree(function()
        local env = server({ resources = { fredpd_dispatch = 'stopped' } })
        env.bolos.ABC123 = { id = 7 }
        pass(env)
        t.eq(#hits(env), 1, 'the event still fires')
        local alerts = sent(env, 'police:client:policeAlert')
        local targets = {}
        for _, a in ipairs(alerts) do targets[#targets + 1] = a.target end
        table.sort(targets)
        t.eq(targets, { 1, 2, 3 }, 'qb on-duty police job (upstream recipients)')
        t.eq(alerts[1].args[2], env.G.Lang:t('fredpd.bolo_radar', { plate = 'ABC123', street = 'Vespucci Blvd', radar = 1 }))
        env.clear()
        env.tick(1500)
        pass(env)
        t.eq(#sent(env, 'police:client:policeAlert'), 0, 'cooling down and not flagged: nothing')
    end)
end

tests['radar: a /flagplate flag without efterlysning raises the upstream alert; nothing flagged -> nothing'] =
    function(t)
        H.withTree(function()
            local env = server()
            pass(env)
            t.eq(#sent(env, 'police:client:policeAlert') + #hits(env), 0, 'neither wanted nor flagged')
            env.command('flagplate', 1, { 'abc123', 'stulen' })
            env.tick(1500)
            pass(env, 1, 'ABC123')
            local alerts = sent(env, 'police:client:policeAlert')
            t.eq(#alerts, 3)
            t.eq(alerts[1].args[2], env.G.Lang:t('info.flagged_vehicle_radar', { plate = 'ABC 123' }), 'plate as on the vehicle (upstream)')
            t.eq(alerts[1].args[1], env.G.Config.Radars[1], 'the radar position from config.lua')
        end)
    end

tests['radar: forged or impossible passes are ignored before any lookup'] = function(t)
    H.withTree(function()
        local env = server()
        env.bolos.ABC123 = { id = 7 }
        pass(env, 1, 'XYZ999')
        env.tick(1500)
        pass(env, 99)
        env.tick(1500)
        pass(env, 2)
        env.tick(1500)
        env.driver[VEH] = 1002
        pass(env)
        env.tick(1500)
        env.driver[VEH] = 1004
        env.pedVehicle[1004] = nil
        pass(env)
        t.eq(env.boloChecks, nil, 'wrong plate, unknown radar, far away, passenger, on foot: no checkPlate')
        env.pedVehicle[1004] = VEH
        env.tick(1500)
        pass(env)
        pass(env)
        t.eq(env.boloChecks, 1, 'second report within 1 s dropped')
    end)
end

tests['radar: fredpd_bolo stopped or failing -> no boloHit and no error; flags still alert'] = function(t)
    H.withTree(function()
        for _, mode in ipairs({ 'stopped', 'throws' }) do
            local env = server(mode == 'stopped' and { resources = { fredpd_bolo = 'stopped' } } or nil)
            env.bolos.ABC123 = { id = 7 }
            env.boloThrows = mode == 'throws'
            env.command('flagplate', 1, { 'abc123', 'x' })
            pass(env, 1, 'ABC123')
            t.eq(#hits(env), 0, mode)
            t.eq(#sent(env, 'police:client:policeAlert'), 3, mode .. ': flag alert')
        end
    end)
end

tests['radar: fredpd_core stopped -> no efterlysning lookup; the /flagplate alert works as upstream'] = function(t)
    H.withTree(function()
        local env = server({ resources = { fredpd_core = 'stopped' } })
        env.bolos.ABC123 = { id = 7 }
        env.command('flagplate', 2, { 'abc123', 'x' })
        pass(env, 1, 'ABC123')
        t.eq(env.boloChecks, nil)
        t.eq(#hits(env), 0)
        t.eq(#sent(env, 'police:client:policeAlert'), 3)
    end)
end

tests['radar: police:server:IsPlateFlagged answers on-duty officers only while FredPD runs'] = function(t)
    H.withTree(function()
        local env = server()
        env.command('flagplate', 1, { 'abc123', 'x' })
        t.eq(env.call('police:server:IsPlateFlagged', 2, 'ABC123'), true)
        t.eq(env.call('police:server:IsPlateFlagged', 4, 'ABC123'), false, 'the driver cannot ask')
        env.bolos.XYZ999 = { id = 1 }
        t.eq(env.call('police:server:IsPlateFlagged', 2, 'XYZ999'), false, 'never answers from efterlysningar')
        env.resources.fredpd_core = 'stopped'
        t.eq(env.call('police:server:IsPlateFlagged', 4, 'ABC123'), true, 'fredpd_core stopped: upstream')
    end)
end

tests['impound: success calls resolveOnImpound(normalised plate, src) once; refused impound resolves nothing'] =
    function(t)
        H.withTree(function()
            local env = server()
            env.fire('police:server:Impound', 2, 'abc 123', true, 0, 1000, 1000, 50)
            t.eq(env.resolved, {}, 'no impound grant')
            env.fire('police:server:Impound', 1, 'abc 123', true, 0, 1000, 1000, 50)
            t.eq(env.resolved, { { plate = 'ABC123', src = 1 } })
            env.tick()
            env.fire('police:server:Impound', 1, 'XYZ 999', false, 100, 1000, 1000, 50)
            t.eq(#env.resolved, 2, '/depot resolves too')
        end)
    end

tests['impound: fredpd_bolo stopped or failing never blocks the impound'] = function(t)
    H.withTree(function()
        local env = server({ resources = { fredpd_bolo = 'stopped' } })
        env.fire('police:server:Impound', 1, 'ABC123', true, 0, 1000, 1000, 50)
        t.eq(#env.resolved, 0)
        t.eq(env.audits[1].action, 'police.impound', 'impound still audited')
        local broken = server()
        broken.impl.fredpd_bolo.resolveOnImpound = function() error('db down', 0) end
        broken.fire('police:server:Impound', 1, 'ABC123', true, 0, 1000, 1000, 50)
        t.eq(broken.audits[1].action, 'police.impound')
    end)
end

tests['client anpr: every pass is reported with its radar index and street, without IsPlateFlagged'] = function(t)
    H.withTree(function()
        local env = H.client({ 'client/anpr.lua' }, {}, function(e)
            local r = { x = 544.43, y = -373.24, z = 33.14 }
            e.coords[1001] = H.vec(r.x, r.y, r.z)
            e.pedVehicle[1001] = VEH
            e.driver[VEH] = 1001
            e.plates[VEH] = 'ABC123'
        end)
        t.eq(#env.threads, 1, 'Config.EnableRadars (upstream default true)')
        env.waitHook = function() error('stop', 0) end
        pcall(env.threads[1])
        local reported = {}
        for _, e in ipairs(env.serverEvents) do reported[#reported + 1] = e end
        t.eq(#reported, 1)
        t.eq({ reported[1].name, reported[1].args[1], reported[1].args[2], reported[1].args[3] },
            { 'police:server:FlaggedPlateTriggered', 2, 'ABC123', 'Vespucci Blvd | Legion Sq' })
    end)
end

tests['plate normalisation matches FredPD (docs/contracts.md C4: upper case, no whitespace)'] = function(t)
    H.withTree(function()
        local env = server()
        local n = env.Bolo.normalizePlate
        t.eq(n(' abc 123 '), 'ABC123')
        t.eq(n(''), nil)
        t.eq(n('ÅÄÖ'), nil)
        t.eq(n(('A'):rep(17)), nil)
        t.eq(env.Bolo.cleanStreet('a\nb'), 'a b')
        t.eq(utf8.len(env.Bolo.cleanStreet(('å'):rep(150))), 100)
    end)
end

return tests
