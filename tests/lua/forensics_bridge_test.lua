-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_forensics on the fredpd_core framework bridge (docs/contracts.md §C17, docs/modules/forensics.md
-- "Framework bridge"). Reuses the forensics_server_test environment (MariaDB + mocks, the REAL server/bridge.lua
-- behind the fredpd_core mock's bridgeInfo) and runs:
--   * the plain QBCore stack (qb-core + qb-inventory + qb-target): idle, nothing registered, ONE warning, the tablet
--     exports answer 'unavailable', ox_inventory never touched, also after evidences starts;
--   * the ox pair with evidences started late: idle, then wired by the onResourceStart re-check;
--   * a smoke matrix on qb-core + ox and qbx_core + ox: collect, register, link, audit actor through the bridge;
--   * a static check: no fredpd_forensics file calls qb-core/qbx_core/ox_target/ox_doorlock, ox_inventory only
--     through the two gated places, fxmanifest without ox_*/framework dependencies.
-- Run: lua5.4 tests/lua/run.lua forensics_bridge
local S = require('forensics_server_test')
local helper = require('helper')

local FORENSICS = './resources/[fredpd]/fredpd_forensics/'
local UNAVAILABLE = { ok = false, error = 'unavailable', reason = 'evidence_off' }

local tests = {}

local function names(tbl)
    local out = {}
    for k in pairs(tbl) do out[#out + 1] = k end
    table.sort(out)
    return out
end

local function warnings(env, text)
    local n = 0
    for _, l in ipairs(env.logs) do
        if l.level == 'warn' and l.msg:find(text, 1, true) then n = n + 1 end
    end
    return n
end

local function exportsAnswerUnavailable(t, env)
    t.eq(env.exported.listEvidence(1, {}), UNAVAILABLE)
    t.eq(env.exported.getEvidence(1, { id = 1 }), UNAVAILABLE)
    t.eq(env.exported.linkEvidence(1, { id = 1, caseNumber = 'K-123-26' }), UNAVAILABLE)
    t.eq(env.exported.listCaseEvidence(1, { caseId = 1 }), UNAVAILABLE)
end

tests['bridge 01 qb stack (qb-core + qb-inventory + qb-target): idle, one warning, exports unavailable'] = function(t)
    S.withEnv(t, function(_, env, mods)
        t.eq(require('server.bridge').info().evidence, false)
        t.eq(mods.main.isActive(), false)
        t.eq(names(env.exported), { 'getEvidence', 'linkEvidence', 'listCaseEvidence', 'listEvidence' })
        t.eq(#env.hooks, 0, 'no ox_inventory hook')
        t.eq(#env.stashes, 0, 'no stash')
        t.eq(env.callbacks['fredpd:forensics:link'], nil, 'no callback')
        t.eq(env.handlers['evidences:evidenceItemAnalysed'], nil, 'no evidences handler')
        t.eq(env.handlers['playerDropped'], nil)
        t.eq(env.oxAccess, {}, 'ox_inventory never touched')
        t.eq(env.convars.fredpd_forensics_evidence, 'off')
        t.eq(#env.clientEvents, 0)
        t.eq(warnings(env, 'evidence is not available'), 1)
        t.ok(env.logs[1].msg:find('inventory=qb-inventory, target=qb-target', 1, true), env.logs[1].msg)
        exportsAnswerUnavailable(t, env)
        t.ok(env.exported.listEvidence(1, {}) ~= env.exported.listEvidence(1, {}), 'fresh table per answer')
        -- evidences starting later changes nothing on the qb pair: one re-check, no second warning
        env.fire('onResourceStart', '', 'evidences')
        env.advance(mods.main.RECHECK_MS)
        t.eq(mods.main.isActive(), false)
        t.eq(warnings(env, 'evidence is not available'), 1, 'still ONE warning')
        t.eq(#env.hooks, 0)
        t.eq(env.oxAccess, {})
        local errors = 0
        for _, l in ipairs(env.logs) do if l.level == 'error' then errors = errors + 1 end end
        t.eq(errors, 0, 'never an error')
    end, { stack = 'qb-only', resources = { ox_inventory = false, ox_target = false, ['qb-inventory'] = 'started',
        ['qb-target'] = 'started' } })
end

tests['bridge 02 ox pair, evidences started after fredpd_forensics: idle, then wired by the re-check'] = function(t)
    S.withEnv(t, function(_, env, mods)
        t.eq(mods.main.isActive(), false)
        t.eq(#env.hooks, 0)
        t.eq(warnings(env, 'evidence is not available'), 1)
        exportsAnswerUnavailable(t, env)
        env.fire('onResourceStart', '', 'other_resource')
        t.eq(#env.timers, 0, 'no re-check for unrelated resources')
        env.resources.evidences = 'started'
        env.fire('onResourceStart', '', 'evidences')
        env.advance(mods.main.RECHECK_MS)
        t.eq(mods.main.isActive(), true)
        t.eq(#env.hooks, 3)
        t.eq(#env.stashes, 1)
        t.ok(env.callbacks['fredpd:forensics:link'])
        t.ok(env.handlers['evidences:evidenceItemAnalysed'])
        t.eq(env.convars.fredpd_forensics_evidence, 'on')
        t.eq(#env.eventsNamed('fredpd:forensics:client:enable', env.clientEvents), 1)
        t.eq(env.clientEvents[#env.clientEvents].target, -1)
        local res = env.exported.listEvidence(1, {})
        t.eq(res.ok, true, json.encode(res))
        -- a second evidences start (restart) does not wire twice
        env.fire('onResourceStart', '', 'evidences')
        env.advance(mods.main.RECHECK_MS)
        t.eq(#env.hooks, 3)
        t.eq(warnings(env, 'evidence is not available'), 1)
    end, { resources = { evidences = 'stopped' } })
end

for _, stack in ipairs({ 'qb', 'qbx' }) do
    tests[('bridge 03 %s framework + ox pair: collect, link and audit actor through the bridge'):format(stack)] = function(t)
        S.withEnv(t, function(_, env, mods)
            local Bridge = require('server.bridge')
            t.eq(Bridge.chosen('framework'), stack == 'qbx' and 'qbx_core' or 'qb-core')
            t.eq(Bridge.info().evidence, true)
            t.eq(mods.main.isActive(), true)
            t.eq(mods.service.cfg.inventory, 'ox_inventory')
            t.eq(env.convars.fredpd_forensics_evidence, 'on')
            local _, row = S.collectFingerprint(env, mods, 1)
            t.ok(row, 'registered')
            local res = S.link(env, 1, row.id, 'K-123-26')
            t.eq(res.ok, true, json.encode(res))
            t.eq(res.tag, 'B-K-123-26-001')
            local actor = MySQL.scalar.await("SELECT actor_citizenid FROM fredpd_audit WHERE action = 'evidence.link' "
                .. 'ORDER BY id DESC LIMIT 1')
            t.eq(actor, 'FOR10001', 'actor from ' .. Bridge.chosen('framework'))
            t.eq(warnings(env, 'evidence is not available'), 0)
        end, { stack = stack })
    end
end

tests['bridge 02b ox pair: an ox_target start also schedules the one-shot re-check'] = function(t)
    -- The bridge's evidence verdict follows the configured ox pair and evidences' state, not whether ox_target runs,
    -- so this only matters if evidences came up without its own start event reaching us; the re-check is one timer.
    S.withEnv(t, function(_, env, mods)
        t.eq(mods.main.isActive(), false)
        t.eq(warnings(env, 'evidence is not available'), 1)
        env.resources.evidences = 'started'
        env.fire('onResourceStart', '', 'ox_target')
        t.eq(#env.timers, 1, 'one one-shot re-check')
        env.advance(mods.main.RECHECK_MS)
        t.eq(mods.main.isActive(), true)
        t.eq(#env.hooks, 3)
        t.eq(warnings(env, 'evidence is not available'), 1)
    end, { resources = { evidences = 'stopped' } })
end

tests['bridge 04 Service.inventory refuses anything but the selected ox_inventory'] = function(t)
    S.withEnv(t, function(_, env, mods)
        local Service = mods.service
        t.eq(Service.cfg.inventory, nil, 'idle: never configured')
        local ok, err = pcall(Service.inventory)
        t.ok(not ok and tostring(err):find('not the selected inventory', 1, true), tostring(err))
        t.eq(Service.heldBy(1, 'ABC123'), false, 'a gated call is a quiet false')
        t.eq(env.oxAccess, {})
    end, { stack = 'qb-only', resources = { ox_inventory = false, ox_target = false } })
end

tests['bridge 05 static: no framework/target/doorlock calls, ox_inventory only in the gated places'] = function(t)
    local files = {}
    local p = io.popen("find '" .. FORENSICS .. "' -name '*.lua' | sort")
    for line in p:lines() do files[#files + 1] = line end
    p:close()
    t.ok(#files >= 6, 'found the Lua files')
    local oxUses = {}
    for _, file in ipairs(files) do
        local text = helper.readFile(file)
        local code = text:gsub('%-%-[^\n]*', '') -- comments may name upstream resources
        for _, bad in ipairs({ "exports%['qb%-core'%]", 'exports%.qbx_core', "exports%['qbx_core'%]", 'QBCore',
            'QBX%.', 'exports%.ox_target', "exports%['qb%-target'%]", 'exports%.ox_doorlock', "exports%['qb%-doorlock'%]",
            "exports%['qb%-inventory'%]", '@qbx_core' }) do
            t.eq(code:find(bad), nil, file .. ' uses ' .. bad)
        end
        for _ in code:gmatch('exports%.ox_inventory') do oxUses[#oxUses + 1] = file:match('[^/]+/[^/]+$') end
    end
    table.sort(oxUses)
    t.eq(oxUses, { 'client/main.lua', 'server/service.lua' }, 'Service.inventory() and the client locker open only')
    local manifest = helper.readFile(FORENSICS .. 'fxmanifest.lua'):gsub('%-%-[^\n]*', '')
    local deps = manifest:match('dependencies%s*(%b{})')
    for _, bad in ipairs({ 'ox_inventory', 'ox_target', 'qbx_core', 'qb%-core' }) do
        t.eq(deps:find(bad), nil, 'fxmanifest dependency ' .. bad)
    end
    t.ok(manifest:find("'@fredpd_core/bridge/client.lua'", 1, true), 'client includes the bridge')
end

return tests
