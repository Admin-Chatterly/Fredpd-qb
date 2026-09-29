-- SPDX-License-Identifier: GPL-3.0-only
-- qb-policejob patch 10 'grants' (docs/modules/police-qb.md): duty and permissions come from fredpd_core
-- (isOnDuty / hasGrant) while it runs, qb-policejob's own job checks otherwise; money commands and net events are
-- validated and rate limited in both modes; jail is routed past xt-prison's compat handler.
-- Run: lua5.4 tests/lua/run.lua qbpolice_grants
local H = require('qbpolice_harness_test')

local tests = {}

local function server(opts)
    opts = opts or {}
    opts.players = opts.players or H.cast()
    return H.server(opts)
end

local function text(env, key, subs)
    return env.G.Lang:t(key, subs)
end

local function sent(env, name, target)
    local out = {}
    for _, e in ipairs(env.clientEvents) do
        if e.name == name and (target == nil or e.target == target) then out[#out + 1] = e end
    end
    return out
end

local function audits(env, action)
    local out = {}
    for _, a in ipairs(env.audits) do if a.action == action then out[#out + 1] = a end end
    return out
end

tests['check: FredPD duty + grant decide while fredpd_core runs; unmapped action and export error fail closed'] =
    function(t)
        H.withTree(function()
            local env = server()
            local F = env.FredPD
            t.eq(F.check(1, 'impound'), true)
            t.eq({ F.check(2, 'impound') }, { false, 'no_grant' }, 'qb grade 4, no FredPD grant')
            t.eq({ F.check(3, 'cuff') }, { false, 'off_duty' }, 'qb on duty but FredPD off duty')
            t.eq(F.check(2, 'cuff'), true, "'duty' actions need only FredPD duty")
            t.eq({ F.check(1, 'nonsense') }, { false, 'no_grant' }, 'unmapped action is refused')
            t.eq(F.allowed(4, 'cuff', true), false, 'upstream answer ignored while FredPD runs')
            env.impl.fredpd_core.isOnDuty = function() error('boom', 0) end
            t.eq({ F.check(1, 'cuff') }, { false, 'off_duty' }, 'export error = refused, not upstream')
        end)
    end

tests['check: fredpd_core stopped -> nil and every gate uses the upstream qb-core condition'] = function(t)
    H.withTree(function()
        local env = server({ resources = { fredpd_core = 'stopped' } })
        local F = env.FredPD
        t.eq(F.check(1, 'impound'), nil)
        t.eq(F.allowed(2, 'impound', true), true)
        t.eq(F.allowed(1, 'impound', false), false)
        t.eq(F.evidenceReplaced(), false)
    end)
end

tests['commands: /impound and /depot need perm:police.impound; the message says why'] = function(t)
    H.withTree(function()
        local env = server()
        env.command('impound', 1)
        t.eq(#sent(env, 'police:client:ImpoundVehicle', 1), 1, 'granted officer')
        env.command('depot', 2, { '250' })
        t.eq(#sent(env, 'police:client:ImpoundVehicle', 2), 0, 'no grant')
        t.eq(env.lastNotify(2).msg, text(env, 'fredpd.no_permission'))
        env.command('impound', 3)
        t.eq(#sent(env, 'police:client:ImpoundVehicle', 3), 0, 'FredPD off duty')
        t.eq(env.lastNotify(3).msg, text(env, 'error.on_duty_police_only'))
        env.command('impound', 4)
        t.eq(#sent(env, 'police:client:ImpoundVehicle', 4), 0, 'civilian')
    end)
end

tests['commands: fredpd_core stopped -> upstream (any on-duty leo, grade for licences)'] = function(t)
    H.withTree(function()
        local env = server({ resources = { fredpd_core = 'stopped' } })
        env.command('impound', 2)
        env.command('impound', 3)
        env.command('impound', 5)
        t.eq(#sent(env, 'police:client:ImpoundVehicle', 2), 1)
        t.eq(#sent(env, 'police:client:ImpoundVehicle', 3), 1, 'qb on duty is enough without FredPD')
        t.eq(#sent(env, 'police:client:ImpoundVehicle', 5), 0, 'qb off duty')
        env.command('grantlicense', 2, { '4', 'weapon' })
        t.eq(env.players[4].PlayerData.metadata.licences.weapon, true, 'grade 4 >= LicenseRank 2')
        env.command('grantlicense', 1, { '4', 'driver' })
        t.eq(env.lastNotify(1).msg, text(env, 'error.rank_license'), 'grade 0 < LicenseRank')
    end)
end

tests['commands: licence, jail, cuff, plate flags map to their grants'] = function(t)
    H.withTree(function()
        local env = server()
        env.command('grantlicense', 2, { '4', 'weapon' })
        t.eq(env.players[4].PlayerData.metadata.licences.weapon, false, 'grade 4 without perm:police.license')
        t.eq(env.lastNotify(2).msg, text(env, 'fredpd.no_permission'))
        env.command('grantlicense', 1, { '4', 'weapon' })
        t.eq(env.players[4].PlayerData.metadata.licences.weapon, true, 'perm:police.license at grade 0')
        env.command('jail', 2)
        env.command('jail', 1)
        t.eq(#sent(env, 'police:client:JailPlayer', 2), 0)
        t.eq(#sent(env, 'police:client:JailPlayer', 1), 1)
        env.command('cuff', 2)
        env.command('cuff', 3)
        t.eq(#sent(env, 'police:client:CuffPlayer', 2), 1, 'cuff is duty only')
        t.eq(#sent(env, 'police:client:CuffPlayer', 3), 0)
        env.command('flagplate', 2, { 'abc123', 'stulen' })
        env.command('plateinfo', 2, { 'abc123' })
        t.eq(env.lastNotify(2).msg, text(env, 'error.vehicle_not_flag'), 'plateinfo is duty only; nothing flagged')
        env.command('flagplate', 1, { 'abc123', 'stulen' })
        env.command('plateinfo', 2, { 'abc123' })
        t.ok(env.lastNotify(2).msg:find('ABC123', 1, true), 'flagged by the granted officer')
    end)
end

tests['commands: /unjail needs the jail grant and a real target (-1 would free everyone); audited'] = function(t)
    H.withTree(function()
        local env = server()
        env.command('unjail', 2, { '4' })
        t.eq(#sent(env, 'prison:client:UnjailPerson'), 0)
        env.command('unjail', 1, { '-1' })
        env.command('unjail', 1, { '99' })
        t.eq(#sent(env, 'prison:client:UnjailPerson'), 0, 'unknown or broadcast target')
        env.command('unjail', 1, { '4' })
        t.eq(#sent(env, 'prison:client:UnjailPerson', 4), 1)
        t.eq(audits(env, 'police.unjail')[1].targetId, 'CIV00004')
    end)
end

tests['net JailPlayer: perm:police.jail, whole months >= 1, 1 per 2 s, audited'] = function(t)
    H.withTree(function()
        local env = server()
        env.fire('police:server:fredpdJailPlayer', 2, 4, 10)
        t.eq(#sent(env, 'police:client:SendToJail'), 0, 'no grant')
        env.fire('police:server:fredpdJailPlayer', 1, 4, 0)
        env.fire('police:server:fredpdJailPlayer', 1, 4, 2.5)
        t.eq(#sent(env, 'police:client:SendToJail'), 0, 'invalid time')
        env.fire('police:server:fredpdJailPlayer', 1, 4, 12)
        t.eq(#sent(env, 'police:client:SendToJail', 4), 1)
        t.eq(env.players[4].PlayerData.metadata.injail, 12)
        t.eq(audits(env, 'police.jail')[1].meta, { minutes = 12 })
        env.fire('police:server:fredpdJailPlayer', 1, 4, 12)
        t.eq(#sent(env, 'police:client:SendToJail', 4), 1, 'rate limited')
        env.tick()
        env.fire('police:server:JailPlayer', 1, 4, 5)
        t.eq(#sent(env, 'police:client:SendToJail', 4), 2, 'legacy name still works without xt-prison')
    end)
end

tests['net JailPlayer: with xt-prison started only the FredPD event jails (xt-prison serves the old name)'] =
    function(t)
        H.withTree(function(tr)
            local env = server({ resources = { ['xt-prison'] = 'started' } })
            env.fire('police:server:JailPlayer', 1, 4, 5)
            t.eq(#sent(env, 'police:client:SendToJail'), 0, 'left to xt-prison compat handler')
            env.fire('police:server:fredpdJailPlayer', 1, 4, 5)
            t.eq(#sent(env, 'police:client:SendToJail', 4), 1, 'enters the prison once via prison:client:Enter')
            local client = tr.files['client/interactions.lua']
            t.ok(client:find("TriggerServerEvent('police:server:fredpdJailPlayer'", 1, true), 'client sends new name')
            t.ok(not client:find("TriggerServerEvent('police:server:JailPlayer'", 1, true), 'not the old name')
        end)
    end

tests['net BillPlayer: bill grant, whole amount 1..maxFine, 1 per 2 s (hardening also without FredPD)'] =
    function(t)
        H.withTree(function()
            local env = server()
            env.fire('police:server:BillPlayer', 2, 4, 500)
            t.eq(#env.money, 0, 'no grant')
            for _, bad in ipairs({ -500, 0, 2.5, 100001, 'x' }) do env.fire('police:server:BillPlayer', 1, 4, bad) end
            t.eq(#env.money, 0, 'invalid amounts')
            env.fire('police:server:BillPlayer', 1, 4, 500)
            t.eq(env.money[1], { src = 4, op = 'remove', kind = 'bank', amount = 500, reason = 'paid-bills' })
            t.eq(env.banking[1].amount, 500)
            t.eq(audits(env, 'police.fine')[1].meta, { amount = 500, via = 'bill' })
            env.fire('police:server:BillPlayer', 1, 4, 500)
            t.eq(#env.money, 1, 'rate limited')
            local off = server({ resources = { fredpd_core = 'stopped' } })
            off.fire('police:server:BillPlayer', 2, 4, -500)
            t.eq(#off.money, 0, 'negative bill refused without FredPD too')
            off.fire('police:server:BillPlayer', 2, 4, 50)
            t.eq(#off.money, 1, 'upstream: any leo')
        end)
    end

tests['command /fine: perm:charges.fine, maxFine, 1 per 2 s with a message; audited'] = function(t)
    H.withTree(function()
        local env = server()
        env.command('fine', 2, { '4', '200' })
        t.eq(#env.money, 0)
        t.eq(env.lastNotify(2).msg, text(env, 'fredpd.no_permission'))
        env.command('fine', 1, { '4', '200000' })
        t.eq(#env.money, 0)
        t.eq(env.lastNotify(1).msg, text(env, 'fredpd.amount_too_high', { max = 100000 }))
        env.tick()
        env.command('fine', 1, { '4', '200' })
        t.eq(env.money[1].amount, 200)
        t.eq(audits(env, 'police.fine')[1].meta, { amount = 200 })
        env.command('fine', 1, { '4', '200' })
        t.eq(#env.money, 1)
        t.eq(env.lastNotify(1).msg, text(env, 'fredpd.try_again'))
    end)
end

tests['commands /paylawyer and /paytow: FredPD duty (judge as upstream), 1 payment per 2 s'] = function(t)
    H.withTree(function()
        local env = server()
        env.command('paylawyer', 3, { '7' })
        t.eq(#env.money, 0, 'FredPD off duty')
        env.command('paylawyer', 6, { '7' })
        t.eq(#env.money, 1, 'judge job keeps its right')
        env.command('paylawyer', 2, { '7' })
        t.eq(#env.money, 2, "on-duty officer ('duty' mapping)")
        env.command('paylawyer', 2, { '7' })
        t.eq(#env.money, 2, 'rate limited')
        t.eq(env.lastNotify(2).msg, text(env, 'fredpd.try_again'))
        env.command('paytow', 3, { '8' })
        env.command('paytow', 2, { '8' })
        env.command('paytow', 2, { '8' })
        t.eq(#env.money, 3, 'paytow: one payment, off duty refused, second rate limited')
    end)
end

tests['net SeizeCash / SetTracker / SeizeDriverLicense: only an on-duty officer (were open to anyone)'] =
    function(t)
        H.withTree(function()
            local env = server()
            env.fire('police:server:SeizeCash', 4, 7)
            env.fire('police:server:SetTracker', 4, 7)
            env.fire('police:server:SeizeDriverLicense', 4, 7)
            t.eq(#env.money, 0)
            t.eq(env.players[7].PlayerData.metadata.tracker, nil)
            t.eq(env.players[7].PlayerData.metadata.licences.driver, true)
            env.fire('police:server:SeizeCash', 2, 7)
            env.fire('police:server:SetTracker', 2, 7)
            t.eq(env.money[1].kind, 'cash')
            t.eq(env.players[7].PlayerData.metadata.tracker, true)
        end)
    end

tests['net Impound / TakeOutImpound / GetImpoundedVehicles: impound grant, validation, audit'] = function(t)
    H.withTree(function()
        local env = server()
        env.fire('police:server:Impound', 2, 'ABC123', true, 0, 1000, 1000, 50)
        t.eq(#env.sql, 0, 'no grant: no database write')
        env.fire('police:server:Impound', 1, 'ABC123', false, -1, 1000, 1000, 50)
        t.eq(#env.audits, 0, 'negative price')
        env.tick()
        env.fire('police:server:Impound', 1, 'abc 123', true, 0, 1000, 1000, 50)
        local a = audits(env, 'police.impound')[1]
        t.eq({ a.targetId, a.meta.full }, { 'ABC123', true })
        t.eq(env.call('police:GetImpoundedVehicles', 2), {}, 'rows only for the impound grant')
        env.clear()
        env.fire('police:server:TakeOutImpound', 1, 'ABC123', 99)
        t.eq(#env.sql, 0, 'unknown lot')
        local lot = env.G.Config.Locations.impound[1]
        H.at(env, 1, lot.x, lot.y, lot.z)
        env.fire('police:server:TakeOutImpound', 1, 'ABC123', 1)
        t.ok(env.sql[1] and env.sql[1].sql:find('AND state = %?') and env.sql[1].params[3] == 2,
            'only an impounded row is released')
    end)
end

tests['objects: spawn/delete/sync need an on-duty officer, a known type and a sane spike list'] = function(t)
    H.withTree(function()
        local env = server()
        env.fire('police:server:spawnObject', 4, 'cone')
        env.fire('police:server:spawnObject', 2, 'nuke')
        t.eq(#sent(env, 'police:client:spawnObject'), 0)
        env.fire('police:server:spawnObject', 2, 'cone')
        local spawned = sent(env, 'police:client:spawnObject', 2)[1]
        t.ok(spawned, 'officer places a cone')
        env.fire('police:server:deleteObject', 4, spawned.args[1])
        t.eq(#sent(env, 'police:client:removeObject'), 0, 'civilian cannot remove')
        env.tick()
        env.fire('police:server:deleteObject', 2, spawned.args[1])
        t.eq(#sent(env, 'police:client:removeObject'), 1)
        local spikes = {}
        for i = 1, 6 do spikes[i] = { coords = H.vec(1, 2, 3), netid = i, object = i } end
        env.tick()
        env.fire('police:server:SyncSpikes', 2, spikes)
        t.eq(#sent(env, 'police:client:SyncSpikes'), 0, 'more than Config.MaxSpikes')
        spikes[6] = nil
        env.fire('police:server:SyncSpikes', 4, spikes)
        t.eq(#sent(env, 'police:client:SyncSpikes'), 0, 'civilian')
        env.tick()
        env.fire('police:server:SyncSpikes', 2, spikes)
        t.eq(#sent(env, 'police:client:SyncSpikes'), 1)
    end)
end

tests['net SearchPlayer / CuffPlayer / EscortPlayer: FredPD duty replaces the leo bypass'] = function(t)
    H.withTree(function()
        local env = server()
        env.closest, env.closestDistance = 7, 1.0
        env.fire('police:server:CuffPlayer', 3, 7, false)
        t.eq(#sent(env, 'police:client:GetCuffed'), 0, 'FredPD off duty, no handcuffs item')
        env.spec(3).items.handcuffs = 1
        env.fire('police:server:CuffPlayer', 3, 7, false)
        t.eq(#sent(env, 'police:client:GetCuffed'), 1, 'the handcuffs item works for anyone (upstream design)')
        env.fire('police:server:EscortPlayer', 3, 7)
        t.eq(#sent(env, 'police:client:GetEscorted'), 0)
        env.fire('police:server:EscortPlayer', 2, 7)
        t.eq(#sent(env, 'police:client:GetEscorted'), 1)
    end)
end

tests['rate limit: per player and key, forgotten on playerDropped'] = function(t)
    H.withTree(function()
        local env = server()
        local F = env.FredPD
        t.eq(F.rateLimit(1, 'k', 1000), true)
        t.eq(F.rateLimit(1, 'k', 1000), false)
        t.eq(F.rateLimit(2, 'k', 1000), true, 'other player')
        t.eq(F.rateLimit(1, 'j', 1000), true, 'other key')
        env.G.source = 1
        env.emit('playerDropped')
        env.G.source = nil
        t.eq(F.rateLimit(1, 'k', 1000), true, 'forgotten')
    end)
end

return tests
