-- SPDX-License-Identifier: GPL-3.0-only
-- qb-policejob patch 20 'fredpd-replacements': the built-in evidence is off ONLY while fredpd_core reports
-- hasFeature('evidence') (ox_inventory + ox_target + evidences, docs/contracts.md C17); on a qb-inventory server it
-- stays on. The police_stormram trunk item needs `setr fredpd_police_legacy true` (the ram is fredpd_breach's pd_ram).
-- Run: lua5.4 tests/lua/run.lua qbpolice_evidence
local H = require('qbpolice_harness_test')

local tests = {}

local function server(opts)
    opts = opts or {}
    opts.players = opts.players or H.cast()
    return H.server(opts)
end

local function sent(env, name)
    local out = {}
    for _, e in ipairs(env.clientEvents) do if e.name == name then out[#out + 1] = e end end
    return out
end

local function exercise(env)
    env.clear()
    env.fire('evidence:server:CreateCasing', 4, 'weapon_pistol', H.vec(1, 2, 3))
    env.fire('evidence:server:CreateBloodDrop', 4, 'CIV00004', 'A+', H.vec(1, 2, 3))
    env.command('clearcasings', 2)
    env.spec(2).items.empty_evidence_bag = 1
    env.fire('evidence:server:AddCasingToInventory', 2, 1, { label = 'Hylsa' })
    return {
        casing = #sent(env, 'evidence:client:AddCasing'),
        blood = #sent(env, 'evidence:client:AddBlooddrop'),
        clear = #sent(env, 'evidence:client:ClearCasingsInArea'),
        bag = #env.addItems,
        answer = env.call('police:server:fredpdEvidence', 2),
    }
end

tests['evidence stays ON without the FredPD evidence feature (qb-inventory server)'] = function(t)
    H.withTree(function()
        local env = server()
        t.eq(exercise(env), { casing = 1, blood = 1, clear = 1, bag = 1, answer = true })
    end)
end

tests['evidence is OFF while fredpd_core reports hasFeature(evidence)'] = function(t)
    H.withTree(function()
        local env = server()
        env.features.evidence = true
        t.eq(exercise(env), { casing = 0, blood = 0, clear = 0, bag = 0, answer = false })
        env.command('takedna', 2, { '4' })
        t.eq(#env.addItems, 0, '/takedna off too')
    end)
end

tests['evidence stays ON when fredpd_core is stopped or its hasFeature export fails'] = function(t)
    H.withTree(function()
        local env = server({ resources = { fredpd_core = 'stopped' } })
        env.features.evidence = true
        t.eq(exercise(env).casing, 1, 'fredpd_core stopped')
        local broken = server()
        broken.noHasFeature = true
        t.eq(exercise(broken), { casing = 1, blood = 1, clear = 1, bag = 1, answer = true }, 'export error')
    end)
end

tests['evidence: clients are told when evidences / fredpd_forensics / fredpd_core start or stop'] = function(t)
    H.withTree(function()
        local env = server()
        t.eq(env.call('police:server:fredpdEvidence', 1), true)
        env.clear()
        env.emit('onServerResourceStart', 'ox_lib')
        t.eq(#sent(env, 'police:client:fredpdEvidence'), 0, 'unrelated resource')
        env.features.evidence = true
        env.emit('onServerResourceStart', 'evidences')
        local ev = sent(env, 'police:client:fredpdEvidence')
        t.eq(#ev, 1)
        t.eq({ ev[1].target, ev[1].args[1] }, { -1, false })
        env.emit('onServerResourceStart', 'fredpd_forensics')
        t.eq(#sent(env, 'police:client:fredpdEvidence'), 1, 'no change, no broadcast')
        env.resources.fredpd_core = 'stopped'
        env.emit('onServerResourceStop', 'fredpd_core')
        ev = sent(env, 'police:client:fredpdEvidence')
        t.eq(ev[2].args[1], true, 'back on')
    end)
end

tests['client evidence: loops start only when the server says ON and end when it says OFF'] = function(t)
    H.withTree(function()
        local answer = true
        local function setup(env)
            env.clientCallbacks = { ['police:server:fredpdEvidence'] = function() return answer end }
        end
        local env = H.client({ 'client/evidence.lua' }, {}, setup)
        t.eq(#env.threads, 4, 'four upstream loops')
        env.fire('police:client:fredpdEvidence', nil, false)
        local waits = 0
        env.waitHook = function()
            waits = waits + 1
            if waits > 100 then error('loop did not stop', 0) end
        end
        for _, thread in ipairs(env.threads) do thread() end
        t.eq(waits, 0, 'every loop of the old generation ends before its first Wait')
        env.fire('police:client:fredpdEvidence', nil, true)
        t.eq(#env.threads, 8, 'restarted')
        env.fire('police:client:fredpdEvidence', nil, true)
        t.eq(#env.threads, 8, 'no second set of loops')
        answer = false
        local off = H.client({ 'client/evidence.lua' }, {}, setup)
        t.eq(#off.threads, 0, 'off from the start')
    end)
end

tests['stormram: the police_stormram trunk item is gone unless setr fredpd_police_legacy true'] = function(t)
    H.withTree(function(tr)
        local env = server()
        for _, item in pairs(env.G.Config.CarItems) do t.ok(item.name ~= 'police_stormram', 'no stormram') end
        t.eq(env.G.Config.CarItems[1].name, 'heavyarmor', 'the other trunk items stay')
        local legacy = server({ convars = { fredpd_police_legacy = 'true' } })
        t.eq(legacy.G.Config.CarItems[3].name, 'police_stormram')
        local code = 0
        for path, src in pairs(tr.files) do
            if path:match('%.lua$') and path ~= 'config.lua' and not path:match('^locales/') then
                if src:find('stormram', 1, true) then code = code + 1 end
            end
        end
        t.eq(code, 0, 'config.lua CarItems is the only stormram code in qb-policejob')
    end)
end

return tests
