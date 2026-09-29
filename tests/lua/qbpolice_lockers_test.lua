-- SPDX-License-Identifier: GPL-3.0-only
-- qb-policejob patch 10 'grants', review fix: the personal stash, the trash and the evidence lockers
-- (qb-policejob:server:stash / :trash / :evidence, upstream server/main.lua:116-146) go through FredPD duty/grants
-- while fredpd_core runs, are rate limited, and the evidence locker name is built by the server (no forged
-- identifiers). Also: xt-prison sentence set server-side, and the start-up note when fredpd_core is not started.
-- Run: lua5.4 tests/lua/run.lua qbpolice_lockers
local H = require('qbpolice_harness_test')

local tests = {}

local function server(opts)
    opts = opts or {}
    opts.players = opts.players or H.cast()
    return H.server(opts)
end

--- Record qb-inventory OpenInventory calls.
local function recordOpens(env)
    env.opens = {}
    env.impl['qb-inventory'].OpenInventory = function(src, id, data)
        env.opens[#env.opens + 1] = { src = src, id = id, data = data }
    end
end

local function evidenceRoom(env)
    local room = env.G.Config.Locations['evidence'][1]
    return room.x, room.y, room.z
end

local function text(env, key, subs)
    return env.G.Lang:t(key, subs)
end

tests['lockers: stash and trash need FredPD duty while fredpd_core runs; refusal says why'] = function(t)
    H.withTree(function()
        local env = server()
        recordOpens(env)
        env.fire('qb-policejob:server:stash', 1)
        t.eq(env.opens[1], { src = 1, id = 'policestash_OFF00001' }, 'on-duty officer opens own stash')
        env.fire('qb-policejob:server:trash', 1)
        t.eq(env.opens[2].id, 'policetrash')
        env.fire('qb-policejob:server:stash', 3)
        env.fire('qb-policejob:server:trash', 3)
        t.eq(#env.opens, 2, 'qb leo but FredPD off duty: refused')
        t.eq(env.lastNotify(3).msg, text(env, 'error.on_duty_police_only'))
        env.fire('qb-policejob:server:stash', 4)
        t.eq(#env.opens, 2, 'civilian refused')
    end)
end

tests['lockers: an action mapped to a grant refuses an ungranted officer'] = function(t)
    H.withTree(function()
        local env = server()
        recordOpens(env)
        local actions = env.FredPD.config().actions
        actions.stash, actions.trash, actions.evidencelocker = 'perm:police.impound', 'perm:police.impound',
            'perm:police.impound'
        local x, y, z = evidenceRoom(env)
        H.at(env, 2, x, y, z)
        env.fire('qb-policejob:server:stash', 2)
        env.fire('qb-policejob:server:trash', 2)
        env.fire('qb-policejob:server:evidence', 2, 1, 1)
        t.eq(#env.opens, 0, 'officer 2 has no perm:police.impound')
        t.eq(env.lastNotify(2).msg, text(env, 'fredpd.no_permission'))
        H.at(env, 1, x, y, z)
        env.fire('qb-policejob:server:evidence', 1, 1, 1)
        t.eq(#env.opens, 1, 'granted officer opens')
    end)
end

tests['lockers: evidence drawer name is built by the server; forged identifiers and bad input refused'] =
    function(t)
        H.withTree(function(tr)
            local env = server()
            recordOpens(env)
            local x, y, z = evidenceRoom(env)
            H.at(env, 1, x, y, z)
            for _, args in ipairs({
                { 'policestash_OFF00002' }, { '1 | Drawer 1' }, { 1, 'x' }, { 1, 0 }, { 1, -3 }, { 1, 2.5 },
                { 99, 1 }, { 1, 100001 }, { nil, 1 }, { 1, nil },
            }) do
                env.fire('qb-policejob:server:evidence', 1, args[1], args[2])
                env.tick(1500)
            end
            t.eq(#env.opens, 0, 'every forged or invalid request is refused')
            env.fire('qb-policejob:server:evidence', 1, 1, 7)
            t.eq(env.opens[1].id, text(env, 'info.current_evidence', { value = 1, value2 = 7 }),
                'same name as the upstream client built, so drawers keep their contents')
            t.eq(env.opens[1].data, { maxweight = 4000000, slots = 500 })
            env.fire('qb-policejob:server:evidence', 1, 1, 8)
            t.eq(#env.opens, 1, 'rate limited (1 per s)')
            env.tick(1500)
            H.at(env, 1, x + 20, y, z)
            env.fire('qb-policejob:server:evidence', 1, 1, 8)
            t.eq(#env.opens, 1, 'too far from the evidence room')
            env.tick(1500)
            H.at(env, 3, x, y, z)
            env.fire('qb-policejob:server:evidence', 3, 1, 8)
            t.eq(#env.opens, 1, 'FredPD off duty refused')
            local client = tr.files['client/job.lua']
            t.ok(client:find("TriggerServerEvent('qb-policejob:server:evidence', currentEvidence, tonumber(drawer.slot))",
                1, true), 'patched client sends the room index and drawer number')
            t.ok(not client:find("Lang:t('info.current_evidence'", 1, true), 'client no longer builds the name')
        end)
    end

tests['lockers: fredpd_core stopped -> upstream (any leo job, on duty or not); civilians refused'] = function(t)
    H.withTree(function()
        local env = server({ resources = { fredpd_core = 'stopped' } })
        recordOpens(env)
        env.fire('qb-policejob:server:stash', 5)
        t.eq(env.opens[1], { src = 5, id = 'policestash_OFF00005' }, 'qb leo off duty: upstream allows')
        env.fire('qb-policejob:server:trash', 4)
        local x, y, z = evidenceRoom(env)
        H.at(env, 4, x, y, z)
        env.fire('qb-policejob:server:evidence', 4, 1, 1)
        t.eq(#env.opens, 1, 'civilian refused')
        H.at(env, 5, x, y, z)
        env.fire('qb-policejob:server:evidence', 5, 1, 2)
        t.eq(env.opens[2].id, text(env, 'info.current_evidence', { value = 1, value2 = 2 }))
        env.tick()
        env.fire('qb-policejob:server:evidence', 5, 'policestash_OFF00001')
        t.eq(#env.opens, 2, 'forged identifier refused without FredPD too')
    end)
end

tests['jail: with xt-prison the sentence is set server-side (SetJailTime) before the client enters'] = function(t)
    H.withTree(function()
        local env = server({ resources = { ['xt-prison'] = 'started' } })
        local calls = {}
        env.impl['xt-prison'] = { SetJailTime = function(src, minutes)
            calls[#calls + 1] = { src = src, minutes = minutes, sent = #env.clientEvents }
            return true
        end }
        env.fire('police:server:fredpdJailPlayer', 1, 4, 5)
        t.eq(#calls, 1)
        t.eq({ calls[1].src, calls[1].minutes }, { 4, 5 })
        local jailed
        for i, e in ipairs(env.clientEvents) do
            if e.name == 'police:client:SendToJail' then jailed = i end
        end
        t.ok(jailed and jailed > calls[1].sent, 'SetJailTime before police:client:SendToJail')
        env.tick()
        env.fire('police:server:fredpdJailPlayer', 2, 4, 5)
        t.eq(#calls, 1, 'no jail grant: no sentence')
    end)
end

tests['jail: without xt-prison SetJailTime is not called'] = function(t)
    H.withTree(function()
        local env = server()
        local called = false
        env.impl['xt-prison'] = { SetJailTime = function() called = true end }
        env.fire('police:server:fredpdJailPlayer', 1, 4, 5)
        t.eq(called, false)
    end)
end

tests['startup: one console note when fredpd_core is not started, none when it is'] = function(t)
    H.withTree(function()
        local function noted(env)
            local n = 0
            for _, line in ipairs(env.logs) do
                if line:find('fredpd_core is not started', 1, true) then n = n + 1 end
            end
            return n
        end
        t.eq(noted(server({ resources = { fredpd_core = 'stopped' } })), 1)
        t.eq(noted(server()), 0)
    end)
end

return tests
