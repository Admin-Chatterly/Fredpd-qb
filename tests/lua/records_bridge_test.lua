-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_records on the fredpd_core framework bridge (docs/contracts.md §C17, docs/modules/records.md "Framework
-- bridge"): a smoke matrix that runs the framework-dependent paths on BOTH stacks, whatever FREDPD_RECORDS_STACK
-- selects for the other records suites — qb (qb-core mock) and qbx (qbx_core mock), both reached through the real
-- server/bridge.lua — plus a static check that no fredpd_records file calls qb-core/qbx_core/ox_*/Renewed-Banking.
local H = require('records_env_test')
local helper = require('helper')

local tests = {}

local STACKS = { 'qb', 'qbx' }

local function Ch(mods) return mods['server.charges'] end
local function Cs(mods) return mods['server.cases'] end
local function R(mods) return mods['server.reports'] end

--- RP501 online as server id 7, next to officer 1.
local function suspectOnline(env)
    env.players[7] = { cid = 'RP501', tier = 0, units = {}, grants = {} }
    env.coords[1] = { 100, 100, 30 }
    env.coords[7] = { 101, 101, 30 }
end

for _, stack in ipairs(STACKS) do
    tests[('bridge %s 01 issueFine takes and refunds bank money through the bridge'):format(stack)] = function(t)
        H.with(t, function(_, env, mods)
            t.eq(env.Bridge.chosen('framework'), stack == 'qbx' and 'qbx_core' or 'qb-core')
            H.fewPeople()
            suspectOnline(env)
            env.bank.RP501 = 8000
            local speeding = { { code = 'TRF-010' } }
            local res = Ch(mods).issueFine(1, { citizenid = 'RP501', lines = speeding })
            t.eq(res.ok, true, json.encode(res))
            t.eq(env.bank.RP501, 6000, 'debited')
            local call = env.moneyCalls[#env.moneyCalls]
            t.eq({ call[1], call[2], call[3], call[4], call[5] }, { 'RemoveMoney', 7, 'bank', 2000, 'police-fine' })
            env.gameTimer = env.gameTimer + 5000
            env.onTransaction = function() error('simulated', 0) end
            local ok, err = pcall(Ch(mods).issueFine, 1, { citizenid = 'RP501', lines = speeding })
            env.onTransaction = nil
            t.ok(not ok and tostring(err):find('fine refunded', 1, true) ~= nil, tostring(err))
            t.eq(env.bank.RP501, 6000, 'refunded')
            t.eq(#env.bridgeLogs.warn + #env.bridgeLogs.error, 0, 'no bridge warnings')
        end, { stack = stack })
    end

    tests[('bridge %s 02 online lookups: jail target and assign notification'):format(stack)] = function(t)
        H.with(t, function(_, env, mods)
            H.fewPeople()
            suspectOnline(env)
            local c = Cs(mods).createCase(1, { title = 'Rån i butik' }).data
            local rep = R(mods).createReport(1, { caseId = c.id, title = 'Rapport' }).data
            env.jailResult = true
            local res = Ch(mods).applyCharges(1, { reportId = rep.id, citizenid = 'RP501', lines = { { code = 'BRB-005' } } })
            t.eq(res.ok, true)
            t.eq(#env.jails, 1, 'prison adapter called')
            t.eq(env.jails[1].target, 7, 'server id from bridge getPlayerByCitizenId')
            env.players[7].online = false
            Ch(mods).applyCharges(1, { reportId = rep.id, citizenid = 'RP501', lines = { { code = 'BRB-005' } } })
            t.eq(#env.jails, 1, 'offline (not loaded in the framework) -> nobody jailed')
            env.notifies = {}
            t.eq(Cs(mods).assignCase(1, { id = c.id, citizenid = 'REC10002' }).ok, true)
            t.eq(#env.notifies, 1)
            t.eq(env.notifies[1].target, 2, 'assignee found online through the bridge')
        end, { stack = stack })
    end

    tests[('bridge %s 03 framework stopped: target offline, one bridge warning, no error'):format(stack)] = function(t)
        H.with(t, function(_, env, mods)
            H.fewPeople()
            suspectOnline(env)
            env.bank.RP501 = 8000
            env.resources[stack == 'qbx' and 'qbx_core' or 'qb-core'] = 'stopped'
            for _ = 1, 2 do
                env.gameTimer = env.gameTimer + 5000
                t.eq(Ch(mods).issueFine(1, { citizenid = 'RP501', lines = { { code = 'TRF-010' } } }),
                    { ok = false, error = 'not_found', reason = 'target_offline' })
            end
            t.eq(env.bank.RP501, 8000)
            t.eq(#env.moneyCalls, 0)
            t.eq(#env.bridgeLogs.warn, 1, 'one warning: ' .. table.concat(env.bridgeLogs.warn, ' | '))
            t.eq(#env.bridgeLogs.error, 0)
        end, { stack = stack })
    end
end

--- Code of a Lua file without comments (line comments and --[[ ]] blocks) and string contents kept.
local function code(text)
    text = text:gsub('%-%-%[(=*)%[.-%]%1%]', '')
    local out = {}
    for line in (text .. '\n'):gmatch('(.-)\n') do out[#out + 1] = (line:gsub('%-%-.*$', '')) end
    return table.concat(out, '\n')
end

tests['bridge static: no direct framework/inventory/target/doorlock/banking calls in fredpd_records'] = function(t)
    local root = H.ROOT
    local files = {}
    local p = io.popen("find '" .. root .. "' -name '*.lua' -not -path '*/test/*'")
    for line in p:lines() do files[#files + 1] = line end
    p:close()
    t.ok(#files >= 13, 'lua files found (' .. #files .. ')')
    local banned = { 'qbx_core', 'qb%-core', 'QBCore', 'QBX', 'ox_inventory', 'ox_target', 'ox_doorlock', 'qb%-inventory',
        'qb%-target', 'qb%-doorlock', 'Renewed', 'Functions%.', 'PlayerData', '@qbx_core' }
    for _, file in ipairs(files) do
        local src = code(helper.readFile(file))
        for _, pat in ipairs(banned) do
            t.ok(not src:find(pat), ('%s: %s outside comments'):format(file, pat))
        end
    end
    local js = helper.readFile(root .. 'server/random.js')
    t.ok(not js:find('qbx') and not js:find('QBCore') and not js:find('ox_'), 'random.js')
end

return tests
