-- SPDX-License-Identifier: GPL-3.0-only
-- qbx_police patch 20 'fredpd-replacements' (patches/qbx_policejob.20-fredpd-replacements.patch): the built-in
-- evidence (server net events evidence:server:*, the evidence commands, client/evidence.lua with its per-frame
-- loops) and the stormram trunk item are off unless `setr fredpd_police_legacy true`; police:server:UpdateCurrentCops
-- (inside the evidence block upstream) stays. Run: lua5.4 tests/lua/run.lua police_evidence
local H = require('police_harness_test')

local tests = {}

local EVIDENCE_EVENTS = {
    'evidence:server:UpdateStatus', 'evidence:server:CreateBloodDrop', 'evidence:server:CreateFingerDrop',
    'evidence:server:ClearBlooddrops', 'evidence:server:AddBlooddropToInventory',
    'evidence:server:AddFingerprintToInventory', 'evidence:server:CreateCasing', 'evidence:server:ClearCasings',
    'evidence:server:AddCasingToInventory',
}
local EVIDENCE_COMMANDS = { 'clearcasings', 'clearblood', 'takedna' }

tests['server: no evidence:server:* net event and no evidence command by default'] = function(t)
    H.withTree(function()
        local env = H.server({ players = H.cast() })
        for _, name in ipairs(EVIDENCE_EVENTS) do t.eq(env.net[name], nil, name) end
        for _, name in ipairs(EVIDENCE_COMMANDS) do t.eq(env.commands[name], nil, '/' .. name) end
        t.ok(env.net['police:server:UpdateCurrentCops'], 'UpdateCurrentCops still registered')
        t.ok(env.net['police:server:showFingerprint'], 'fingerprint scanner (not scene evidence) kept')
        t.ok(env.commands.cuff and env.commands.jail and env.commands.fine, 'other commands kept')
    end)
end

tests['server: fredpd_police_legacy=true registers all nine evidence events and the three commands'] = function(t)
    H.withTree(function()
        local env = H.server({ players = H.cast(), convars = { fredpd_police_legacy = 'true' } })
        for _, name in ipairs(EVIDENCE_EVENTS) do t.ok(env.net[name], name) end
        for _, name in ipairs(EVIDENCE_COMMANDS) do t.ok(env.commands[name], '/' .. name) end
        env.fire('evidence:server:UpdateStatus', 4, { weedsmell = { text = 'Luktar cannabis', time = 100 } })
        t.eq(env.call('police:GetPlayerStatus', 1, 4), { 'Luktar cannabis' })
    end)
end

tests['server: police:GetPlayerStatus answers {} for a player without a status (was a next(nil) error)'] = function(t)
    H.withTree(function()
        local env = H.server({ players = H.cast() })
        t.eq(env.call('police:GetPlayerStatus', 1, 4), {})
    end)
end

tests['client: evidence.lua registers nothing and starts no loop unless legacy'] = function(t)
    H.withTree(function()
        local env = H.client('client/evidence.lua')
        t.eq(next(env.net), nil)
        t.eq(#env.threads, 0)
        local legacy = H.client('client/evidence.lua', { convars = { fredpd_police_legacy = 'true' } })
        t.ok(legacy.net['evidence:client:SetStatus'] and legacy.net['evidence:client:AddCasing'])
        t.eq(#legacy.threads, 4, 'the upstream status/shooting/draw/discover loops')
    end)
end

local function carItemNames(env)
    local out = {}
    for _, item in ipairs(env.G.require('config.client').carItems) do out[#out + 1] = item.name end
    return out
end

tests['stormram: the police_stormram trunk item is gone unless legacy; it is the only stormram code'] = function(t)
    H.withTree(function(tr)
        t.eq(carItemNames(H.env()), { 'heavyarmor', 'empty_evidence_bag' })
        t.eq(carItemNames(H.env({ convars = { fredpd_police_legacy = 'true' } })),
            { 'heavyarmor', 'empty_evidence_bag', 'police_stormram' })
        local users = {}
        for path, src in pairs(tr.files) do
            if path:match('%.lua$') and src:lower():find('stormram', 1, true) then users[#users + 1] = path end
        end
        t.eq(users, { 'config/client.lua' })
        for path, src in pairs(tr.files) do
            if path:match('%.lua$') then
                t.ok(not src:find('carItems', 1, true) or path == 'config/client.lua', path .. ' reads carItems')
            end
        end
    end)
end

return tests
