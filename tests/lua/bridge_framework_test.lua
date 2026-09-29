-- SPDX-License-Identifier: GPL-3.0-only
-- Framework bridge (docs/contracts.md §C17): the qb-core and qbx_core implementations against mocks shaped like the
-- pinned sources (tests/lua/bridge_harness_test.lua), the normalised player, removeMoney, and the normalised server
-- events fredpd:bridge:playerLoaded / playerUnloaded / jobChanged / dutyChanged. Run: lua5.4 tests/lua/run.lua bridge_framework
local H = require('bridge_harness_test')
local Normalize = require('bridge.framework.normalize')

local tests = {}

local QB = { framework = 'qb-core', inventory = 'qb-inventory', target = 'qb-target', doorlock = 'qb-doorlock' }
local QBX = { framework = 'qbx_core', inventory = 'ox_inventory', target = 'ox_target', doorlock = 'ox_doorlock' }

local function qbEnv(players, extra)
    local calls = {}
    local core = H.qbCore(players, calls)
    local opts = { cfg = QB, states = { ['qb-core'] = 'started' }, resources = { ['qb-core'] = core } }
    for k, v in pairs(extra or {}) do opts[k] = v end
    return opts, calls
end

local function qbxEnv(players)
    local calls = {}
    return { cfg = QBX, states = { qbx_core = 'started' }, resources = { qbx_core = H.qbxCore(players, calls) } }, calls
end

tests['normalize: job, name, player, money'] = function(t)
    t.eq(Normalize.job({ name = 'police', label = 'LE', type = 'leo', onduty = true, isboss = true,
        grade = { name = 'Chief', level = 4 } }),
        { name = 'police', label = 'LE', type = 'leo', grade = 4, gradeName = 'Chief', onduty = true, isboss = true })
    t.eq(Normalize.job({ name = 'unemployed', grade = '0' }).grade, 0, 'numeric string grade')
    t.eq(Normalize.job({ name = 'x', grade = { level = '2', isboss = true } }).isboss, true)
    t.eq(Normalize.job({ onduty = 1 }).onduty, false, 'only true is on duty')
    t.eq(Normalize.job(nil), nil)
    t.eq(Normalize.name({ firstname = ' Anna', lastname = 'Berg ' }), 'Anna Berg')
    t.eq(Normalize.name({}), nil)
    local p = Normalize.player(H.playerData(3, 'ABC123'))
    t.eq(p.source, 3)
    t.eq(p.citizenid, 'ABC123')
    t.eq(p.license, 'license:abc123')
    t.eq(p.name, 'Anna Berg')
    t.eq(p.job.type, 'leo')
    t.eq(p.job.grade, 1)
    t.eq(p.charinfo.birthdate, '1990-01-01')
    t.eq(p.money, nil, 'only the contract fields')
    t.eq(Normalize.player({ source = 1 }), nil, 'no citizenid')
    t.eq(Normalize.player({ citizenid = 'X', job = 'bad' }).job.onduty, false, 'broken job -> empty job')
    t.eq({ Normalize.money('Bank', 150.4) }, { 'bank', 150 })
    t.eq(Normalize.money('bank', 0), nil)
    t.eq(Normalize.money('bank', -5), nil)
    t.eq(Normalize.money('bank', 0 / 0), nil)
    t.eq(Normalize.money('bank; DROP', 5), nil)
    t.eq(Normalize.money(nil, 5), nil)
end

tests['qb-core: getPlayer / getPlayerByCitizenId / getPlayers through GetCoreObject({ Functions })'] = function(t)
    local players = { [1] = H.playerData(1, 'QB1'), [7] = H.playerData(7, 'QB7', { name = 'unemployed', type = 'none',
        onduty = false, grade = { name = 'Freelancer', level = 0 } }) }
    local opts, calls = qbEnv(players)
    H.with(opts, function(env)
        local B = env.Bridge
        t.eq(B.chosen('framework'), 'qb-core')
        local p = B.getPlayer(1)
        t.eq(p.citizenid, 'QB1')
        t.eq(p.job, { name = 'police', label = 'Law Enforcement', type = 'leo', grade = 1, gradeName = 'Officer',
            onduty = true, isboss = false })
        t.eq(B.getPlayer('7').job.type, 'none', 'string source')
        t.eq(B.getPlayer(2), nil)
        t.eq(B.getPlayer(0), nil)
        t.eq(B.getPlayer('abc'), nil)
        t.eq(B.getPlayerByCitizenId('QB7'), 7)
        t.eq(B.getPlayerByCitizenId('NOPE'), nil)
        t.eq(B.getPlayerByCitizenId(''), nil)
        t.eq(B.getPlayers(), { 1, 7 })
        t.eq(calls[1], { 'GetCoreObject', { 'Functions' } }, 'filtered core object')
        local n = 0
        for _, c in ipairs(calls) do if c[1] == 'GetCoreObject' then n = n + 1 end end
        t.eq(n, 1, 'core object cached')
        -- qb-core restarts: the cached function references are dropped and fetched again.
        env.fire('onResourceStart', '', 'qb-core')
        B.getPlayer(1)
        n = 0
        for _, c in ipairs(calls) do if c[1] == 'GetCoreObject' then n = n + 1 end end
        t.eq(n, 2)
        -- Core.getPlayerData (perms, audit, canview, officers, mirror) goes through the bridge.
        local Core = require('server.core')
        t.eq(Core.getPlayerData(1).citizenid, 'QB1')
        t.eq(Core.getPlayerData(99), nil)
    end)
end

tests['qb-core: removeMoney validates and follows qb-core rules'] = function(t)
    local players = { [1] = H.playerData(1, 'QB1') }
    local opts, calls = qbEnv(players)
    H.with(opts, function(env)
        local B = env.Bridge
        t.eq(B.removeMoney(1, 'bank', 250, 'Böter K-1-26'), true)
        t.eq(players[1].money.bank, 750)
        t.eq(calls[#calls], { 'RemoveMoney', 1, 'bank', 250, 'Böter K-1-26' })
        t.eq(B.removeMoney(1, 'cash', 500, 'x'), false, 'cash never below 0')
        t.eq(B.removeMoney(1, 'bank', 5751, 'x'), false, 'minus limit')
        t.eq(B.removeMoney(1, 'bank', -5, 'x'), false)
        t.eq(B.removeMoney(1, 'bank', 'many', 'x'), false)
        t.eq(B.removeMoney(2, 'bank', 5, 'x'), false, 'offline')
        t.eq(B.removeMoney(1, 'bank', 10.6), true, 'rounded, default reason')
        t.eq(calls[#calls], { 'RemoveMoney', 1, 'bank', 11, 'fredpd' })
    end)
end

tests['qbx_core: same interface over exports.qbx_core'] = function(t)
    local players = { [4] = H.playerData(4, 'QBX4'), [2] = H.playerData(2, 'QBX2') }
    local opts, calls = qbxEnv(players)
    H.with(opts, function(env)
        local B = env.Bridge
        t.eq(B.chosen('framework'), 'qbx_core')
        t.eq(B.getPlayer(4).citizenid, 'QBX4')
        t.eq(B.getPlayerByCitizenId('QBX2'), 2)
        t.eq(B.getPlayers(), { 2, 4 })
        t.eq(B.removeMoney(4, 'bank', 100, 'fine'), true)
        t.eq(calls[#calls], { 'RemoveMoney', 4, 'bank', 100, 'fine' })
        t.eq(players[4].money.bank, 900)
        t.eq(B.removeMoney(4, 'cash', 1000, 'fine'), false)
    end)
end

tests['framework resource down: calls are no-ops with ONE warning'] = function(t)
    local opts = qbEnv({ [1] = H.playerData(1, 'QB1') })
    opts.states = {}
    local env = H.with(opts, function(env)
        local B = env.Bridge
        for _ = 1, 3 do
            t.eq(B.getPlayer(1), nil)
            t.eq(B.getPlayers(), {})
            t.eq(B.removeMoney(1, 'bank', 5, 'x'), false)
        end
    end)
    t.eq(H.count(env.logs.warn, 'framework bridge "qb-core": resource qb-core is missing'), 1, table.concat(env.logs.warn, '\n'))
end

tests['framework resource installed but not started yet: one deferred check, one warning if still down'] = function(t)
    local opts = qbEnv({})
    opts.states = { ['qb-core'] = 'stopped' }
    H.with(opts, function(env)
        t.eq(H.count(env.logs.warn, 'qb-core'), 0, 'no warning at start')
        local deferred
        for _, d in ipairs(env.deferred) do if d.ms == env.Bridge.DEFERRED_CHECK_MS then deferred = d end end
        t.ok(deferred, 'one deferred check')
        env.states['qb-core'] = 'started'
        deferred.cb()
        t.eq(H.count(env.logs.warn, 'qb-core'), 0, 'started in time')
    end)
    opts.states = { ['qb-core'] = 'stopped' }
    H.with(opts, function(env)
        for _, d in ipairs(env.deferred) do d.cb() end
        t.eq(H.count(env.logs.warn, 'resource qb-core is stopped'), 1)
        env.Bridge.getPlayer(1)
        t.eq(H.count(env.logs.warn, 'resource qb-core'), 1, 'still one warning')
    end)
end

tests['qb-core events -> normalised fredpd:bridge:* events (server-local, deduplicated)'] = function(t)
    local players = { [5] = H.playerData(5, 'QB5') }
    H.with(qbEnv(players), function(env)
        local B = env.Bridge
        t.eq(env.net, nil, 'no net event registered')
        local names = {}
        for name in pairs(env.handlers) do names[#names + 1] = name end
        table.sort(names)
        t.eq(names, { 'QBCore:Server:OnJobUpdate', 'QBCore:Server:OnPlayerUnload', 'QBCore:Server:OnPlayerUpdated',
            'QBCore:Server:PlayerLoaded', 'QBCore:Server:SetDuty', 'onResourceStart', 'playerDropped',
            'qb-doorlock:server:doorChanged' })
        -- Character load (qb-core server/player.lua:458): the Player object.
        env.fire('QBCore:Server:PlayerLoaded', '', { PlayerData = players[5] })
        t.eq(env.events(B.EVENTS.playerLoaded), { { 5 } })
        -- CreatePlayer then calls UpdateClient() -> OnPlayerUpdated 'all' -> OnJobUpdate with the same job: nothing.
        env.fire('QBCore:Server:OnJobUpdate', '', 5, players[5].job)
        t.eq(#env.events(B.EVENTS.jobChanged), 0)
        -- ToggleDuty (server/events.lua:177-191): SetJobDuty -> OnJobUpdate(onduty false), then SetDuty(false).
        local offDuty = {}
        for k, v in pairs(players[5].job) do offDuty[k] = v end
        offDuty.onduty = false
        env.fire('QBCore:Server:OnJobUpdate', '', 5, offDuty)
        env.fire('QBCore:Server:SetDuty', '', 5, false)
        t.eq(env.events(B.EVENTS.dutyChanged), { { 5, false } }, 'one dutyChanged for one toggle')
        t.eq(#env.events(B.EVENTS.jobChanged), 0, 'duty is not a job change')
        env.fire('QBCore:Server:SetDuty', '', 5, true)
        t.eq(env.events(B.EVENTS.dutyChanged), { { 5, false }, { 5, true } })
        -- Promotion: grade changes -> jobChanged.
        local promoted = {}
        for k, v in pairs(players[5].job) do promoted[k] = v end
        promoted.grade = { name = 'Sergeant', level = 2 }
        env.fire('QBCore:Server:OnJobUpdate', '', 5, promoted)
        t.eq(env.events(B.EVENTS.jobChanged), { { 5 } })
        -- Disconnect: qb-core fires OnPlayerUnload inside its playerDropped handler; FiveM also delivers playerDropped
        -- to fredpd_core. Either order: one playerUnloaded.
        env.fire('QBCore:Server:OnPlayerUnload', '', 5)
        env.fire('playerDropped', 5, 'quit')
        t.eq(env.events(B.EVENTS.playerUnloaded), { { 5 } })
        -- Unknown player duty/job events do not crash and still report.
        env.fire('QBCore:Server:SetDuty', '', 'x', true)
        t.eq(#env.events(B.EVENTS.dutyChanged), 2)
    end)
end

tests['qb-core OnPlayerUpdated: money/metadata ticks skipped, charinfo changes reach the update listener'] = function(t)
    local players = { [5] = H.playerData(5, 'QB5') }
    H.with(qbEnv(players), function(env)
        local seen = {}
        env.Bridge.onPlayerUpdated(function(src, player) seen[#seen + 1] = { src, player.citizenid } end)
        env.fire('QBCore:Server:OnPlayerUpdated', '', 5, 'money', {})
        env.fire('QBCore:Server:OnPlayerUpdated', '', 5, 'metadata', {})
        t.eq(#seen, 0)
        env.fire('QBCore:Server:OnPlayerUpdated', '', 5, 'charinfo', {})
        env.fire('QBCore:Server:OnPlayerUpdated', '', 5, 'all', players[5])
        t.eq(seen, { { 5, 'QB5' }, { 5, 'QB5' } })
        env.fire('QBCore:Server:OnPlayerUpdated', '', 6, 'charinfo', {})
        t.eq(#seen, 2, 'offline player: no listener call')
    end)
end

tests['qbx_core events: SetDuty alone gives dutyChanged; SetPlayerData feeds the listener without a fetch'] = function(t)
    local players = { [3] = H.playerData(3, 'QBX3') }
    H.with(qbxEnv(players), function(env)
        local B = env.Bridge
        local seen = {}
        B.onPlayerUpdated(function(src, player) seen[#seen + 1] = { src, player.name } end)
        env.fire('QBCore:Server:PlayerLoaded', '', { PlayerData = players[3] })
        env.fire('QBCore:Server:SetDuty', '', 3, false) -- qbx_core server/player.lua:205
        t.eq(env.events(B.EVENTS.dutyChanged), { { 3, false } })
        env.fire('QBCore:Player:SetPlayerData', '', players[3]) -- server/player.lua:1153
        t.eq(seen, { { 3, 'Anna Berg' } })
        -- Job definition change for every holder (server/player.lua:1026) with an unchanged job: nothing.
        local job = {}
        for k, v in pairs(players[3].job) do job[k] = v end
        job.onduty = false
        env.fire('QBCore:Server:OnJobUpdate', '', 3, job)
        t.eq(#env.events(B.EVENTS.jobChanged), 0)
        -- New job (SetPlayerPrimaryJob, :266).
        env.fire('QBCore:Server:OnJobUpdate', '', 3, { name = 'ambulance', type = 'ems', onduty = false,
            grade = { level = 0 } })
        t.eq(env.events(B.EVENTS.jobChanged), { { 3 } })
        -- Logout (:750) then the disconnect: one unload.
        env.fire('QBCore:Server:OnPlayerUnload', '', 3)
        env.fire('playerDropped', 3)
        t.eq(env.events(B.EVENTS.playerUnloaded), { { 3 } })
    end)
end

tests['primeOnline: a restart of fredpd_core still detects the next duty change and unload'] = function(t)
    local players = { [8] = H.playerData(8, 'QB8') }
    H.with(qbEnv(players), function(env)
        local B = env.Bridge
        B.primeOnline()
        env.fire('QBCore:Server:SetDuty', '', 8, true)
        t.eq(#env.events(B.EVENTS.dutyChanged), 0, 'already on duty')
        env.fire('playerDropped', 8)
        t.eq(env.events(B.EVENTS.playerUnloaded), { { 8 } })
    end)
end

tests['exports registered on fredpd_core (contract names) and the capability report line'] = function(t)
    H.with(qbEnv({}), function(env)
        for _, name in ipairs({ 'getPlayer', 'getPlayerByCitizenId', 'getPlayers', 'removeMoney', 'count', 'find', 'add',
            'remove', 'registerUsable', 'getDoor', 'setLocked', 'hasFeature', 'bridgeInfo', 'useItem' }) do
            t.ok(type(env.exported[name]) == 'function', 'export ' .. name)
        end
        t.eq(#env.logs.info, 1, 'one info line')
        t.eq(env.logs.info[1], 'bridge: framework=qb-core, inventory=qb-inventory (hooks: no), target=qb-target, '
            .. 'doorlock=qb-doorlock (needs its FredPD patch); evidence: off (needs ox_inventory + ox_target + evidences)')
        t.eq(env.convars, { fredpd_bridge_target = 'qb-target', fredpd_bridge_doorlock = 'qb-doorlock' })
        t.eq(env.exported.bridgeInfo(), { framework = 'qb-core', inventory = 'qb-inventory', target = 'qb-target',
            doorlock = 'qb-doorlock', hooks = false, evidence = false })
    end)
end

tests['auto selection in the server bridge: ox/Qbox preferred when both run, qb when only qb runs'] = function(t)
    local auto = { framework = 'auto', inventory = 'auto', target = 'auto', doorlock = 'auto' }
    local env = H.with({ cfg = auto, states = { qbx_core = 'started', ['qb-core'] = 'started', ox_inventory = 'started',
        ['qb-inventory'] = 'started', ox_target = 'started', ox_doorlock = 'started', evidences = 'started' },
        resources = { qbx_core = H.qbxCore({}) } }, function(env)
        t.eq(env.Bridge.info(), { framework = 'qbx_core', inventory = 'ox_inventory', target = 'ox_target',
            doorlock = 'ox_doorlock', hooks = true, evidence = true })
        t.eq(env.Bridge.hasFeature('evidence'), true)
        env.states.evidences = 'stopped'
        t.eq(env.Bridge.hasFeature('evidence'), false, 'evidences must run')
        t.eq(env.Bridge.hasFeature('nope'), false)
    end)
    t.eq(#env.logs.warn, 0, table.concat(env.logs.warn, '\n'))
    H.with({ cfg = auto, states = { ['qb-core'] = 'started', ['qb-inventory'] = 'started', ['qb-target'] = 'started',
        ['qb-doorlock'] = 'started', evidences = 'started' } }, function(e)
        t.eq(e.Bridge.info().framework, 'qb-core')
        t.eq(e.Bridge.info().target, 'qb-target')
        t.eq(e.Bridge.hasFeature('evidence'), false)
        t.eq(H.count(e.logs.warn, 'evidences needs ox_inventory + ox_target'), 1, 'one degradation warning')
    end)
    H.with({ cfg = { framework = 'esx' }, states = {} }, function(e)
        t.eq(H.count(e.logs.warn, 'unknown framework bridge "esx"'), 1)
        t.eq(e.Bridge.chosen('framework'), 'qb-core')
    end)
end

return tests
