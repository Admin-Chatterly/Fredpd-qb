-- SPDX-License-Identifier: GPL-3.0-only
-- qbx_police patch 10 'grants' (patches/qbx_policejob.10-grants.patch): IsLeoAndOnDuty and the commands / net
-- events built on it ask fredpd_core (isOnDuty + the action's grant from config/police.json); with fredpd_core
-- stopped the upstream qbx job/duty/grade checks apply unchanged. Loads the PATCHED upstream server files with
-- FiveM mocked (tests/lua/police_harness_test.lua). Run: lua5.4 tests/lua/run.lua police_grants
local H = require('police_harness_test')

local tests = {}

local function server(opts)
    opts = opts or {}
    opts.players = opts.players or H.cast()
    return H.server(opts)
end

local function isLeo(env, src, minGrade, action)
    return env.G.IsLeoAndOnDuty(env.players[src], minGrade, action)
end

tests['IsLeoAndOnDuty: on duty = fredpd_core isOnDuty, grant-gated actions need their grant'] = function(t)
    H.withTree(function()
        local env = server()
        t.eq(isLeo(env, 1), true, 'officer on duty')
        t.eq(isLeo(env, 2), true, 'duty-only: no grant needed')
        t.eq(isLeo(env, 3), false, 'qbx says on duty, FredPD says off duty')
        t.eq(isLeo(env, 4), false, 'civilian')
        t.eq(isLeo(env, 1, nil, 'impound'), true)
        t.eq(isLeo(env, 2, nil, 'impound'), false, 'no perm:police.impound')
        t.eq(isLeo(env, 3, nil, 'impound'), false, 'grant but off duty')
        t.eq(isLeo(env, 2, nil, 'cuff'), true, 'cuff stays duty-only')
        t.eq(isLeo(env, 2, nil, 'spikestrip'), true)
    end)
end

tests['IsLeoAndOnDuty: a qbx minimum grade is replaced by the mapped grant; unmapped fails closed'] = function(t)
    H.withTree(function()
        local env = server()
        t.eq(isLeo(env, 2, 2, 'license'), false, 'grade 4 without perm:police.license')
        t.eq(isLeo(env, 1, 2, 'license'), true, 'grade 0 with perm:police.license')
        t.eq(isLeo(env, 2, 3), false, 'a minimum grade without a mapped action is refused')
        t.eq(isLeo(env, 2, nil, 'no_such_action'), false)
        local warned = false
        for _, l in ipairs(env.logs) do if l.msg:find('no_such_action', 1, true) then warned = true end end
        t.ok(warned, 'unmapped action warned about')
    end)
end

tests['IsLeoAndOnDuty: fredpd_core stopped -> upstream qbx job, duty and grade'] = function(t)
    H.withTree(function()
        local env = server({ resources = { fredpd_core = 'stopped' } })
        t.eq(isLeo(env, 1, nil, 'impound'), true, 'leo on duty, grants ignored')
        t.eq(isLeo(env, 2, nil, 'impound'), true)
        t.eq(isLeo(env, 3), true, 'qbx on duty')
        t.ok(not isLeo(env, 4), 'civilian')
        t.eq(isLeo(env, 7, 2, 'license'), false, 'grade 1 < 2')
        t.eq(isLeo(env, 12, 2, 'license'), true, 'grade 2 >= 2')
        env.spec(2).job.onduty = false
        env.players[2].PlayerData.job.onduty = false
        t.ok(not isLeo(env, 2), 'qbx off duty')
        t.eq(#env.audits, 0)
    end)
end

tests['IsLeoAndOnDuty: fredpd_core started but its export fails -> refused, not upstream'] = function(t)
    H.withTree(function()
        local env = server()
        env.impl.fredpd_core.isOnDuty = nil -- 'No such export' while fredpd_core reports started
        t.eq(isLeo(env, 1), false)
        t.eq(isLeo(env, 1, nil, 'impound'), false)
    end)
end

tests['commands: /impound and /depot need perm:police.impound (message says why)'] = function(t)
    H.withTree(function()
        local env = server()
        env.command('impound', 2)
        t.eq(#env.named(env.clientEvents, 'police:client:ImpoundVehicle'), 0)
        t.eq(env.lastNotify(2).msg, 'fredpd.no_permission')
        env.command('depot', 3, { price = 100 })
        t.eq(env.lastNotify(3).msg, 'error.on_duty_police_only', 'FredPD off duty')
        env.command('impound', 1)
        env.command('depot', 1, { price = 250 })
        local ev = env.named(env.clientEvents, 'police:client:ImpoundVehicle')
        t.eq(#ev, 2)
        t.eq(ev[1].target, 1)
        t.eq(ev[1].args[1], true)
        t.eq(ev[2].args[2], 250)
    end)
end

tests['commands: fredpd_core stopped -> upstream (any on-duty leo may impound)'] = function(t)
    H.withTree(function()
        local env = server({ resources = { fredpd_core = 'stopped' } })
        env.command('impound', 2)
        t.eq(#env.named(env.clientEvents, 'police:client:ImpoundVehicle'), 1)
        env.command('impound', 4)
        t.eq(env.lastNotify(4).msg, 'error.on_duty_police_only')
        env.command('grantlicense', 7, { id = 4, license = 'weapon' })
        t.eq(env.lastNotify(7).msg, 'error.rank_license', 'upstream rank message (grade 1 < licenseRank 2)')
    end)
end

tests['commands: jail, fine, license and plate flags map to their perms; cuff/escort stay duty-only'] = function(t)
    H.withTree(function()
        local env = server()
        local cases = {
            { 'jail', {}, 'police:client:JailPlayer' },
            { 'fine', {}, nil },
            { 'flagplate', { plate = 'abc123', reason = 'x' }, nil },
        }
        for _, c in ipairs(cases) do
            env.clear()
            env.command(c[1], 2, c[2])
            t.eq(env.lastNotify(2).msg, 'fredpd.no_permission', c[1] .. ' without grant')
            if c[3] then t.eq(#env.named(env.clientEvents, c[3]), 0) end
        end
        env.clear()
        env.command('grantlicense', 2, { id = 4, license = 'weapon' })
        t.eq(env.lastNotify(2).msg, 'fredpd.no_permission', 'grade 4 is not enough without perm:police.license')
        t.eq(env.players[4].PlayerData.metadata.licences.weapon, nil)
        env.command('grantlicense', 1, { id = 4, license = 'weapon' })
        t.eq(env.players[4].PlayerData.metadata.licences.weapon, true, 'grade 0 with the grant')
        env.clear()
        env.command('jail', 1)
        t.eq(#env.named(env.clientEvents, 'police:client:JailPlayer'), 1)
        env.command('flagplate', 1, { plate = 'abc123', reason = 'stulen' })
        t.eq(env.G.Plates.ABC123.isflagged, true)
        env.command('unflagplate', 2, { plate = 'abc123' })
        t.eq(env.G.Plates.ABC123.isflagged, true, 'unflag needs perm:bolo.resolve')
        env.command('cuff', 2)
        env.command('sc', 2)
        t.eq(#env.named(env.clientEvents, 'police:client:CuffPlayer'), 1, 'cuff: duty only')
        t.eq(#env.named(env.clientEvents, 'police:client:CuffPlayerSoft'), 1)
        env.command('cuff', 3)
        t.eq(#env.named(env.clientEvents, 'police:client:CuffPlayer'), 1, 'FredPD off duty cannot cuff')
    end)
end

tests['net Impound: needs perm:police.impound; success deletes, updates the row and audits'] = function(t)
    H.withTree(function()
        local env = server()
        env.netEntities[55] = 5500
        env.plates[5500] = 'ABC 123'
        env.owned['ABC 123'] = true
        env.fire('police:server:Impound', 2, 'ABC 123', true, 0, 900, 900, 50, 55)
        t.eq(#env.deleted, 0, 'no grant: nothing happens')
        env.fire('police:server:Impound', 1, 'ABC 123', true, 0, 900, 900, 50, 55)
        t.eq(env.deleted, { 5500 })
        local update = env.sql[#env.sql].sql
        t.ok(update:find('state = 2', 1, true), 'ImpoundForever: ' .. update)
        t.eq(env.audits[1].action, 'police.impound')
        t.eq(env.audits[1].targetType, 'vehicle')
        t.eq(env.audits[1].targetId, 'ABC123', 'normalised plate')
        t.eq(env.audits[1].meta, { full = true, price = 0, owned = true })
    end)
end

tests['net IssueFine: perm:charges.fine required; money only moves when allowed; audited'] = function(t)
    H.withTree(function()
        local env = server()
        env.fire('police:server:IssueFine', 2, 4, 'Fortkörning', 1500, '')
        t.eq(#env.money, 0)
        t.eq(env.lastNotify(2).msg, 'fredpd.no_permission')
        env.fire('police:server:IssueFine', 3, 4, 'Fortkörning', 1500, '')
        t.eq(env.lastNotify(3).msg, 'error.on_duty_police_only')
        env.fire('police:server:IssueFine', 1, 4, 'Fortkörning', 1500, '')
        t.eq(env.money[1], { src = 4, op = 'remove', kind = 'bank', amount = 1500, reason = 'police-fine' })
        t.eq(env.audits[1].action, 'police.fine')
        t.eq(env.audits[1].targetId, 'CIV00004')
        t.eq(env.audits[1].meta, { amount = 1500, offence = 'Fortkörning' })
    end)
end

tests['net BillPlayer: bill grant, whole positive amount (also with fredpd_core stopped)'] = function(t)
    H.withTree(function()
        local env = server()
        env.fire('police:server:BillPlayer', 2, 4, 500)
        t.eq(#env.money, 0, 'no perm:charges.fine')
        env.fire('police:server:BillPlayer', 1, 4, -500)
        env.fire('police:server:BillPlayer', 1, 4, 12.5)
        env.fire('police:server:BillPlayer', 1, 4, 'x')
        t.eq(#env.money, 0, 'negative, fractional and non-numeric amounts are refused')
        env.fire('police:server:BillPlayer', 1, 4, 500)
        t.eq(env.money[1].amount, 500)
        t.eq(env.audits[1].meta, { amount = 500, via = 'bill' })

        local up = server({ resources = { fredpd_core = 'stopped' } })
        up.fire('police:server:BillPlayer', 2, 4, 300)
        t.eq(up.money[1].amount, 300, 'upstream: any leo may bill')
        up.fire('police:server:BillPlayer', 4, 2, 300)
        t.eq(#up.money, 1, 'upstream: a civilian may not')
        up.fire('police:server:BillPlayer', 2, 4, -300)
        t.eq(#up.money, 1, 'negative bill refused in both modes')
    end)
end

tests['net JailPlayer: perm:police.jail; whole positive time; audited'] = function(t)
    H.withTree(function()
        local env = server()
        env.fire('police:server:JailPlayer', 2, 4, 10)
        t.eq(env.players[4].PlayerData.metadata.injail, nil)
        env.fire('police:server:JailPlayer', 1, 4, -10)
        t.eq(env.players[4].PlayerData.metadata.injail, nil)
        env.fire('police:server:JailPlayer', 1, 4, 10)
        t.eq(env.players[4].PlayerData.metadata.injail, 10)
        t.eq(#env.named(env.clientEvents, 'police:client:SendToJail'), 1, 'no prison resource: client event')
        t.eq(env.audits[1].action, 'police.jail')
        t.eq(env.audits[1].meta, { minutes = 10 })
    end)
end

tests['net SeizeCash / SetTracker: only an on-duty officer (were open to any client)'] = function(t)
    H.withTree(function()
        local env = server()
        env.fire('police:server:SeizeCash', 4, 2)
        t.eq(#env.money, 0, 'civilian cannot seize')
        env.fire('police:server:SeizeCash', 3, 4)
        t.eq(#env.money, 0, 'FredPD off duty cannot seize')
        env.fire('police:server:SeizeCash', 2, 4)
        t.eq(env.money[1].op, 'remove')
        env.fire('police:server:SetTracker', 4, 2)
        t.eq(env.players[2].PlayerData.metadata.tracker, nil)
        env.fire('police:server:SetTracker', 2, 4)
        t.eq(env.players[4].PlayerData.metadata.tracker, true)
    end)
end

tests['net UpdateCurrentCops: counts every on-duty officer of the source-keyed player map'] = function(t)
    H.withTree(function()
        local env = server()
        env.fire('police:server:UpdateCurrentCops', 1)
        local ev = env.named(env.clientEvents, 'police:SetCopCount')
        t.eq(#ev, 1)
        t.eq(ev[1].args[1], 4, 'players 1, 2, 7 and 12 (3 is off duty in FredPD, 4 is a civilian)')
    end)
end

tests['net TakeOutImpound: impound grant needed while fredpd_core runs'] = function(t)
    H.withTree(function()
        local env = server()
        local spot = H.vec(436.68, -1007.42, 27.32)
        env.coords[1001], env.coords[1002] = spot, spot
        env.fire('police:server:TakeOutImpound', 2, 'ABC 123', 1)
        t.eq(#env.sql, 0)
        env.fire('police:server:TakeOutImpound', 1, 'ABC 123', 1)
        t.ok(env.sql[1].sql:find('state = 0', 1, true))
        env.fire('police:server:TakeOutImpound', 1, 'ABC 123', 99)
        t.eq(#env.sql, 1, 'unknown impound lot is ignored (was an error)')
    end)
end

tests['callback police:GetImpoundedVehicles: the rows (owners, plates) only for the impound grant'] = function(t)
    H.withTree(function()
        local env = server()
        env.call('police:GetImpoundedVehicles', 2)
        env.call('police:GetImpoundedVehicles', 4)
        t.eq(#env.sql, 0)
        env.call('police:GetImpoundedVehicles', 1)
        t.eq(#env.sql, 1)
        t.ok(env.sql[1].sql:find('state = 2', 1, true))
        local up = server({ resources = { fredpd_core = 'stopped' } })
        up.call('police:GetImpoundedVehicles', 4)
        t.eq(#up.sql, 1, 'upstream: unchecked')
    end)
end

tests['net events: one call per officer and interval after the grant check (bill, jail, fine, impound, ...)'] =
    function(t)
        H.withTree(function()
            local env = server()
            env.fire('police:server:BillPlayer', 2, 4, 500) -- refused by the grant check: no rate-limit slot used
            env.fire('police:server:BillPlayer', 1, 4, 500)
            env.fire('police:server:BillPlayer', 1, 4, 500)
            t.eq(#env.money, 1, 'BillPlayer: one per 2 s (was an instant bank drain)')
            env.now = env.now + 2000
            env.fire('police:server:BillPlayer', 1, 4, 500)
            t.eq(#env.money, 2, 'allowed again after 2 s')

            env.clear()
            env.fire('police:server:IssueFine', 1, 4, 'Fortkörning', 100, '')
            env.fire('police:server:IssueFine', 1, 4, 'Fortkörning', 100, '')
            t.eq(#env.money, 1, 'IssueFine: one per 2 s')
            t.eq(env.lastNotify(1).msg, 'fredpd.try_again')

            env.clear()
            env.fire('police:server:JailPlayer', 1, 4, 10)
            env.fire('police:server:JailPlayer', 1, 4, 10)
            t.eq(#env.named(env.clientEvents, 'police:client:SendToJail'), 1, 'JailPlayer: one per 2 s')

            env.clear()
            env.fire('police:server:SeizeCash', 2, 4)
            env.players[4].PlayerData.money.cash = 50
            env.fire('police:server:SeizeCash', 2, 4)
            t.eq(#env.money, 1, 'SeizeCash: one per second')

            env.clear()
            env.fire('police:server:SetTracker', 2, 4)
            env.fire('police:server:SetTracker', 2, 4)
            t.eq(env.players[4].PlayerData.metadata.tracker, true, 'SetTracker: the second toggle is dropped')

            env.clear()
            env.netEntities[55], env.netEntities[56] = 5500, 5600
            env.plates[5500], env.plates[5600] = 'ABC 123', 'XYZ 999'
            env.fire('police:server:Impound', 1, 'ABC 123', true, 0, 900, 900, 50, 55)
            env.fire('police:server:Impound', 1, 'XYZ 999', true, 0, 900, 900, 50, 56)
            t.eq(env.deleted, { 5500 }, 'Impound: one per second')
            env.now = env.now + 1000
            env.fire('police:server:Impound', 1, 'XYZ 999', true, 0, 900, 900, 50, 56)
            t.eq(env.deleted, { 5500, 5600 }, 'the second vehicle a second later')

            env.clear()
            local spot = H.vec(436.68, -1007.42, 27.32)
            env.coords[1001] = spot
            env.fire('police:server:TakeOutImpound', 1, 'ABC 123', 1)
            env.fire('police:server:TakeOutImpound', 1, 'XYZ 999', 1)
            t.eq(#env.sql, 1, 'TakeOutImpound: one per second')
            env.now = env.now + 1000
            env.fire('police:server:TakeOutImpound', 1, 'XYZ 999', 1)
            t.eq(#env.sql, 2)
        end)
    end

---------------------------------------------------------------------------------------------------------------
-- Escort (server/main.lua police:server:EscortPlayer)

local function escortCast()
    local cast = H.cast()
    cast[20] = { cid = 'EMS00020', job = { name = 'ambulance', type = 'ems', onduty = true, grade = 0 } }
    return cast
end

local function escorted(env)
    return #env.named(env.clientEvents, 'police:client:GetEscorted')
end

tests['net EscortPlayer: the leo bypass needs an on-duty officer while fredpd_core runs; EMS unchanged'] = function(t)
    H.withTree(function()
        local env = server({ players = escortCast() })
        env.fire('police:server:EscortPlayer', 3, 4)
        t.eq(escorted(env), 0, 'qbx leo but FredPD off duty cannot drag an uncuffed player')
        t.eq(env.lastNotify(3).msg, 'error.not_cuffed_dead')
        env.fire('police:server:EscortPlayer', 4, 7)
        t.eq(escorted(env), 0, 'civilian')
        env.fire('police:server:EscortPlayer', 2, 4)
        t.eq(escorted(env), 1, 'on-duty officer (duty only, no grant)')
        env.fire('police:server:EscortPlayer', 20, 4)
        t.eq(escorted(env), 2, 'EMS keep their bypass')
        env.players[4].PlayerData.metadata.ishandcuffed = true
        env.fire('police:server:EscortPlayer', 3, 4)
        t.eq(escorted(env), 3, 'anyone may escort a cuffed player (upstream)')

        local up = server({ players = escortCast(), resources = { fredpd_core = 'stopped' } })
        up.players[3].PlayerData.job.onduty = false
        up.fire('police:server:EscortPlayer', 3, 4)
        t.eq(escorted(up), 1, 'fredpd_core stopped: upstream, any leo (even off duty)')
        up.fire('police:server:EscortPlayer', 4, 7)
        t.eq(escorted(up), 1, 'upstream: a civilian may not')
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Objects and spike strips (server/objects.lua)

local SPOT = H.vec(430.0, -980.0, 30.0)
local CONE = 'prop_roadcone02a' -- config/shared.lua objects.cone.model (a hash in FiveM; the test rewrite keeps names)

local function objectsEnv(opts)
    local env = server(opts)
    local nextEntity = 9000
    env.created = {}
    env.G.CreateObject = function(model, x, y, z)
        nextEntity = nextEntity + 1
        env.created[#env.created + 1] = { model = model, entity = nextEntity }
        env.netEntities[nextEntity - 8000] = nextEntity
        env.coords[nextEntity] = H.vec(x, y, z)
        return nextEntity
    end
    env.G.SetEntityHeading = function() end
    env.G.FreezeEntityPosition = function() end
    env.G.NetworkGetNetworkIdFromEntity = function(entity) return entity - 8000 end
    for _, fn in ipairs(env.handlers.onResourceStart) do fn('qbx_policejob') end
    for src in pairs(env.players) do env.coords[1000 + src] = SPOT end
    return env
end

local function spawnObject(env, src, model, coords)
    env.now = env.now + 500
    return env.call('police:server:spawnObject', src, model or CONE, coords or SPOT, 90.0)
end

local function spawnSpike(env, src, coords)
    env.now = env.now + 500
    return env.call('police:server:spawnSpikeStrip', src, coords or SPOT, 90.0)
end

tests['objects: spawnObject / spawnSpikeStrip need an on-duty officer (were open to any client)'] = function(t)
    H.withTree(function()
        local env = objectsEnv()
        t.eq({ spawnObject(env, 4) }, { nil, 'error.on_duty_police_only' }, 'civilian')
        t.eq({ spawnSpike(env, 4) }, { nil, 'error.on_duty_police_only' })
        t.eq({ spawnObject(env, 3) }, { nil, 'error.on_duty_police_only' }, 'FredPD off duty')
        t.eq({ spawnSpike(env, 3) }, { nil, 'error.on_duty_police_only' })
        t.eq(#env.created, 0)
        t.eq(spawnObject(env, 2), 1001, 'on-duty officer: duty only, no grant needed')
        t.eq(spawnSpike(env, 2), 1002)
        t.eq(#env.G.GlobalState.policeObjects, 1)
        t.eq(#env.G.GlobalState.spikeStrips, 1)

        env.policeConfig = json.encode({ actions = { object = 'perm:police.objects' } })
        env.FredPD.resetConfig()
        t.eq({ spawnObject(env, 2) }, { nil, 'fredpd.no_permission' }, 'a configured grant is enforced')
    end)
end

tests['objects: only config/shared.lua models, next to the officer, one call per 500 ms, spike cap'] = function(t)
    H.withTree(function()
        local env = objectsEnv()
        t.eq({ spawnObject(env, 2, 'prop_bank_vault') }, { nil, 'error.canceled' }, 'any other model is refused')
        t.eq({ spawnObject(env, 2, CONE, H.vec(0, 0, 0)) }, { nil, 'error.canceled' }, 'far from the officer')
        t.eq({ spawnObject(env, 2, CONE, 'x') }, { nil, 'error.canceled' }, 'not coords')
        t.eq({ env.call('police:server:spawnObject', 2, CONE, SPOT, 'x') }, { nil, 'error.canceled' }, 'heading')
        t.eq(#env.created, 0)
        t.ok(spawnObject(env, 2))
        t.eq({ env.call('police:server:spawnObject', 2, CONE, SPOT, 0.0) }, { nil, 'fredpd.try_again' },
            'second call within 500 ms')
        t.eq(#env.created, 1)
        for _ = 1, 4 do t.ok(spawnSpike(env, 7)) end
        t.ok(spawnSpike(env, 7), 'fifth spike strip (maxSpikes 5)')
        t.eq({ spawnSpike(env, 7) }, { nil, 'error.no_spikestripe' }, 'no sixth (upstream allowed maxSpikes + 1)')
    end)
end

tests['objects: removing needs an on-duty officer near the object and a valid index'] = function(t)
    H.withTree(function()
        local env = objectsEnv()
        spawnObject(env, 2)
        spawnObject(env, 2)
        spawnSpike(env, 2)
        env.now = env.now + 500
        env.fire('police:server:despawnObject', 4, 1)
        env.fire('police:server:despawnObject', 3, 1)
        for _, index in ipairs({ 0, 3, -1, 1.5, 'x', 1e300 }) do env.fire('police:server:despawnObject', 2, index) end
        t.eq(#env.deleted, 0, 'civilian, FredPD off duty and invalid indexes do nothing')
        env.coords[1002] = H.vec(0, 0, 0)
        env.fire('police:server:despawnObject', 2, 1)
        t.eq(#env.deleted, 0, 'too far from the object')
        env.coords[1002] = SPOT
        env.fire('police:server:despawnObject', 2, 1)
        t.eq(env.deleted, { 9001 })
        t.eq(#env.G.GlobalState.policeObjects, 1)
        env.fire('police:server:despawnSpikeStrip', 4, 1)
        env.fire('police:server:despawnSpikeStrip', 2, 2)
        t.eq(#env.deleted, 1)
        env.now = env.now + 500
        env.fire('police:server:despawnSpikeStrip', 2, 1)
        t.eq(env.deleted, { 9001, 9003 })
        t.eq(#env.G.GlobalState.spikeStrips, 0)
    end)
end

tests['objects: fredpd_core stopped -> the upstream leo duty check decides'] = function(t)
    H.withTree(function()
        local env = objectsEnv({ resources = { fredpd_core = 'stopped' } })
        t.ok(spawnObject(env, 3), 'qbx leo on duty (FredPD duty not asked)')
        t.ok(spawnSpike(env, 2))
        t.eq({ spawnObject(env, 4) }, { nil, 'error.on_duty_police_only' }, 'civilian')
        env.players[7].PlayerData.job.onduty = false
        t.eq({ spawnSpike(env, 7) }, { nil, 'error.on_duty_police_only' }, 'qbx leo off duty')
        env.fire('police:server:despawnObject', 4, 1)
        t.eq(#env.deleted, 0)
        env.fire('police:server:despawnObject', 3, 1)
        t.eq(#env.deleted, 1)
    end)
end

--- H.cast() plus a lawyer (20), a tow driver (21) and a judge (22).
local function payCast()
    local cast = H.cast()
    cast[20] = { cid = 'LAW00020', job = { name = 'lawyer', type = 'none', onduty = true, grade = 0 } }
    cast[21] = { cid = 'TOW00021', job = { name = 'tow', type = 'none', onduty = true, grade = 0 } }
    cast[22] = { cid = 'JUD00022', job = { name = 'judge', type = 'none', onduty = true, grade = 0 } }
    return cast
end

local function paid(env, target, reason)
    local n = 0
    for _, m in ipairs(env.money) do
        if m.src == target and m.op == 'add' and m.reason == reason then n = n + 1 end
    end
    return n
end

tests['commands: /paylawyer needs FredPD duty (judges as upstream), /paytow too; one payment per 2 s'] = function(t)
    H.withTree(function()
        local env = server({ players = payCast() })
        env.command('paylawyer', 3, { id = 20 })
        t.eq(paid(env, 20, 'police-lawyer-paid'), 0, 'qbx leo but FredPD off duty')
        t.eq(env.lastNotify(3).msg, 'error.on_duty_police_only')
        env.command('paylawyer', 4, { id = 20 })
        t.eq(paid(env, 20, 'police-lawyer-paid'), 0, 'civilian')
        for _ = 1, 5 do env.command('paylawyer', 2, { id = 20 }) end
        t.eq(paid(env, 20, 'police-lawyer-paid'), 1, 'on duty (duty-only action): 5 calls in one tick pay once')
        t.eq(env.lastNotify(2).msg, 'fredpd.try_again')
        env.now = env.now + 2000
        env.command('paylawyer', 2, { id = 20 })
        t.eq(paid(env, 20, 'police-lawyer-paid'), 2, 'after 2 s')
        env.command('paylawyer', 22, { id = 20 })
        t.eq(paid(env, 20, 'police-lawyer-paid'), 3, 'judge (no FredPD duty needed, upstream)')
        env.command('paylawyer', 22, { id = 20 })
        t.eq(paid(env, 20, 'police-lawyer-paid'), 3, 'judge rate-limited too')

        for _ = 1, 5 do env.command('paytow', 2, { id = 21 }) end
        t.eq(paid(env, 21, 'police-tow-paid'), 1, '/paytow: 5 calls in one tick pay once')
        env.command('paytow', 3, { id = 21 })
        t.eq(paid(env, 21, 'police-tow-paid'), 1, '/paytow: FredPD off duty')
        t.eq(env.lastNotify(3).msg, 'error.on_duty_police_only')
    end)
end

tests['commands: /paylawyer maps to a configurable grant; fredpd_core stopped -> any leo (upstream)'] = function(t)
    H.withTree(function()
        local env = server({ players = payCast() })
        env.policeConfig = json.encode({ actions = { paylawyer = 'perm:police.pay' } })
        env.FredPD.resetConfig()
        env.command('paylawyer', 2, { id = 20 })
        t.eq(paid(env, 20, 'police-lawyer-paid'), 0, 'on duty without perm:police.pay')
        t.eq(env.lastNotify(2).msg, 'fredpd.no_permission')
        env.spec(1).grants['perm:police.pay'] = true
        env.command('paylawyer', 1, { id = 20 })
        t.eq(paid(env, 20, 'police-lawyer-paid'), 1)

        local stopped = server({ players = payCast(), resources = { fredpd_core = 'stopped' } })
        stopped.command('paylawyer', 3, { id = 20 })
        t.eq(paid(stopped, 20, 'police-lawyer-paid'), 1, 'qbx leo (duty not checked upstream)')
        stopped.command('paylawyer', 4, { id = 20 })
        t.eq(paid(stopped, 20, 'police-lawyer-paid'), 1, 'civilian refused')
        t.eq(stopped.lastNotify(4).msg, 'error.on_duty_police_only')
        stopped.command('paylawyer', 3, { id = 20 })
        t.eq(paid(stopped, 20, 'police-lawyer-paid'), 1, 'rate limit applies in both modes')
    end)
end

tests['isPoliceForcePresent counts players of the source-keyed map'] = function(t)
    H.withTree(function()
        local env = server({ players = { [9] = { job = { type = 'leo', onduty = false, grade = 3 } } } })
        t.eq(env.call('qbx_police:server:isPoliceForcePresent', 1), true)
    end)
end

return tests
