-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_mdt/server/dispatch.lua: the §C12 order (closed tablet -> unauthorized; unknown action / bad input ->
-- validation; missing grant -> unauthorized; off duty -> unauthorized + reason; rate limit -> rate_limited), routing
-- to the owning resource's export with the cleaned input and unwrapping { ok, data | error }, local handlers
-- (getHome, listTablets, setTabletRevoked, close), the server/main.lua wiring (callbacks, close event, drop), and the
-- Phase 3/4/5/5b merges (DISPATCH/EVIDENCE/RECORDS/INTEL_ACTIONS: route, grant, limit class, unavailable paths).
-- FiveM, fredpd_core, ox_inventory and the routed resources are mocked (fredpd_mdt/test/harness.lua).
-- Run: lua5.4 tests/lua/run.lua mdt_dispatch
local helper = require('helper')
local H = dofile('./resources/[fredpd]/fredpd_mdt/test/harness.lua')
local FIX = helper.readJson('packages/types/test/fixtures/mdt-inputs.fixtures.json')

local tests = {}

--- A valid input for every action (first valid fixture sample of its shape).
local function sampleInput(action)
    local shape = FIX.actions[action].shape
    return H.copy(FIX.shapes[shape].valid[1].input)
end

local function valid(action)
    local input = sampleInput(action)
    -- Samples that need more than the first fixture (createBolo: a complete vehicle BOLO).
    if action == 'createBolo' then input = { kind = 'vehicle', plate = 'ABC 12D', reason = 'Rån mot bank' } end
    return input
end

tests['1 closed tablet: every action but close is unauthorized and nothing is routed'] = function(t)
    H.with(function(env, mods)
        local D = mods['server.dispatch']
        for _, action in ipairs(mods['shared.validate'].actionNames()) do
            local res = D.handle(1, { action = action, input = valid(action) })
            if action == 'close' then
                t.eq(res, { ok = true }, 'close needs no open tablet')
            else
                t.eq(res, { error = 'unauthorized' }, action)
            end
        end
        t.eq(#env.calls, 0, 'no export called')
        -- Unknown action and junk requests while closed: unauthorized too (the open check comes first).
        t.eq(D.handle(1, { action = 'nope', input = {} }), { error = 'unauthorized' })
        t.eq(D.handle(1, 'junk'), { error = 'unauthorized' })
        t.eq(D.handle(1, nil), { error = 'unauthorized' })
        t.eq(D.handle(0, { action = 'close', input = {} }), { error = 'unauthorized' }, 'not a player')
        t.eq(D.handle('abc', { action = 'close', input = {} }), { error = 'unauthorized' })
    end)
end

tests['2 open tablet: unknown actions and bad input are validation errors'] = function(t)
    H.with(function(env, mods)
        local D = mods['server.dispatch']
        H.openTablet(mods, 1)
        for _, req in ipairs({
            { action = 'nope', input = {} }, { action = 'Search', input = { query = 'ab' } }, { action = 5 }, {},
            { action = '__index', input = {} }, { input = {} },
        }) do
            t.eq(D.handle(1, req), { error = 'validation' }, helper.dump(req))
        end
        t.eq(D.handle(1, 'junk'), { error = 'validation' })
        t.eq(D.handle(1, { action = 'search', input = { query = 'a' } }), { error = 'validation' })
        t.eq(D.handle(1, { action = 'search' }), { error = 'validation' }, 'input missing')
        t.eq(D.handle(1, { action = 'getHome', input = { x = 1 } }), { error = 'validation' }, 'strict Empty')
        t.eq(D.handle(1, { action = 'createBolo', input = { kind = 'vehicle', citizenid = 'ABC', plate = 'X',
            reason = 'Rån' } }), { error = 'validation' }, 'refine')
        t.eq(#env.calls, 0)
    end)
end

tests['3 order: validation before grant, grant before duty, duty before rate limit'] = function(t)
    H.with(function(env, mods)
        local D = mods['server.dispatch']
        H.openTablet(mods, 1)
        -- No tablets.manage: bad input still reports validation (step 2 before 3).
        t.eq(D.handle(1, { action = 'setTabletRevoked', input = { serial = '' } }), { error = 'validation' })
        t.eq(D.handle(1, { action = 'setTabletRevoked', input = { serial = 'SP-1', revoked = true } }),
            { error = 'unauthorized' }, 'no grant')
        -- Grant missing and off duty: the grant answer (no reason).
        env.players[1].duty = false
        t.eq(D.handle(1, { action = 'listTablets', input = {} }), { error = 'unauthorized' })
        t.eq(D.handle(1, { action = 'search', input = { query = 'Anna' } }), { error = 'unauthorized', reason = 'off_duty' })
        -- Off-duty refusals do not consume the rate limit: back on duty, the same instant works.
        env.players[1].duty = true
        t.eq(D.handle(1, { action = 'search', input = { query = 'Anna' } }), { routed = 'fredpd_records:search' })
        t.eq(#env.callsTo('fredpd_records', 'search'), 1)
    end)
end

tests['4 grants: each action checks its grant column; wildcards work; close and getHome need none'] = function(t)
    H.with(function(env, mods)
        local D = mods['server.dispatch']
        H.openTablet(mods, 1)
        env.players[1].grants = { ['mdt_page:search'] = true } -- keeps the tablet usable, nothing else
        for name, def in pairs(FIX.actions) do
            if def.grant then
                env.now = env.now + 10000
                local res = D.handle(1, { action = name, input = valid(name) })
                local key = def.grant[1] .. ':' .. def.grant[2]
                if key == 'mdt_page:search' then
                    t.ok(res.error == nil, name .. ' allowed with ' .. key)
                else
                    t.eq(res, { error = 'unauthorized' }, name .. ' needs ' .. key)
                end
            end
        end
        env.now = env.now + 10000
        env.players[1].grants = { ['mdt_page:*'] = true, ['perm:*'] = true }
        for name in pairs(FIX.actions) do
            if name == 'close' then goto continue end -- would end the session; covered by test 9
            env.now = env.now + 10000
            local res = D.handle(1, { action = name, input = valid(name) })
            -- Past the grant check (the tablet handlers then hit the in-memory DB double, which knows no such SQL).
            t.ok(res.error == nil or res.error == 'unavailable', name .. ' allowed with wildcards: ' .. helper.dump(res))
            ::continue::
        end
    end)
end

tests['5 the Lua grant/route table mirrors the fixtures (= MDT/DISPATCH/EVIDENCE_ACTIONS)'] = function(t)
    H.with(function(_, mods)
        local D, V = mods['server.dispatch'], mods['shared.validate']
        local names = {}
        for name, def in pairs(D.ACTIONS) do
            names[#names + 1] = name
            local expected = FIX.actions[name] and FIX.actions[name].grant
            t.ok(FIX.actions[name], 'fixture for ' .. name)
            if expected == nil then
                t.eq(def.grant, nil, name .. ' has no grant')
            else
                t.eq(def.grant, expected, name .. ' grant')
            end
            t.ok(def.handler or def.route, name .. ' is routed')
            t.ok(name == 'close' or def.limit, name .. ' has a rate limit class')
        end
        table.sort(names)
        t.eq(names, V.actionNames(), 'dispatcher and validator know the same actions')
    end)
end

tests['6 rate limits: lookups 500 ms, writes 2 s, reads 500 ms, per player per action'] = function(t)
    H.with(function(env, mods)
        local D = mods['server.dispatch']
        H.openTablet(mods, 1)
        H.openTablet(mods, 2)
        local search = { action = 'search', input = { query = 'Anna' } }
        t.eq(D.handle(1, search).error, nil)
        env.now = env.now + 499
        t.eq(D.handle(1, search), { error = 'rate_limited' })
        t.eq(D.handle(2, search).error, nil, 'another player has their own window')
        t.eq(D.handle(1, { action = 'getVehicle', input = { plate = 'ABC12D' } }).error, nil, 'another action too')
        env.now = env.now + 1
        t.eq(D.handle(1, search).error, nil, '500 ms later')
        -- A refused (validation) call does not start a window.
        env.now = env.now + 10000
        t.eq(D.handle(1, { action = 'createBolo', input = { kind = 'x' } }), { error = 'validation' })
        local create = { action = 'createBolo', input = valid('createBolo') }
        t.eq(D.handle(1, create).error, nil)
        env.now = env.now + 1999
        t.eq(D.handle(1, create), { error = 'rate_limited' })
        env.now = env.now + 1
        t.eq(D.handle(1, create).error, nil)
        -- reads
        local list = { action = 'listBolos', input = {} }
        t.eq(D.handle(1, list).error, nil)
        env.now = env.now + 499
        t.eq(D.handle(1, list), { error = 'rate_limited' })
        env.now = env.now + 1
        t.eq(D.handle(1, list).error, nil)
        -- close is never limited
        t.eq(D.handle(1, { action = 'close', input = {} }), { ok = true })
        t.eq(D.handle(1, { action = 'close', input = {} }), { ok = true })
    end)
end

tests['7 routing: each action reaches its export with (src, cleaned input); data is unwrapped'] = function(t)
    local ROUTES = {
        search = { 'fredpd_records', 'search' }, getPerson = { 'fredpd_records', 'getPersonSummary' },
        getVehicle = { 'fredpd_records', 'getVehicleSummary' }, checkPlate = { 'fredpd_bolo', 'plateCheck' },
        listBolos = { 'fredpd_bolo', 'listBolos' }, createBolo = { 'fredpd_bolo', 'createBolo' },
        resolveBolo = { 'fredpd_bolo', 'resolveBolo' }, listAlerts = { 'fredpd_dispatch', 'listAlerts' },
        takeAlert = { 'fredpd_dispatch', 'assignSelf' }, leaveAlert = { 'fredpd_dispatch', 'leaveAlert' },
        closeAlert = { 'fredpd_dispatch', 'closeAlert' }, getUnits = { 'fredpd_dispatch', 'getUnits' },
        listEvidence = { 'fredpd_forensics', 'listEvidence' }, getEvidence = { 'fredpd_forensics', 'getEvidence' },
        linkEvidence = { 'fredpd_forensics', 'linkEvidence' },
    }
    H.with(function(env, mods)
        local D, V = mods['server.dispatch'], mods['shared.validate']
        H.openTablet(mods, 2) -- Ledning: every grant
        for action, route in pairs(ROUTES) do
            env.now = env.now + 10000
            local input = valid(action)
            input.extraKey = 'dropped'
            if FIX.actions[action].shape == 'Empty' then input.extraKey = nil end
            local res = D.handle(2, { action = action, input = input })
            t.eq(res, { routed = route[1] .. ':' .. route[2] }, action)
            local calls = env.callsTo(route[1], route[2])
            t.eq(#calls, 1, action .. ' called once')
            t.eq(calls[1].src, 2)
            t.eq(calls[1].input, (V.validate(action, input)), action .. ' gets the cleaned input')
            t.eq(calls[1].input.extraKey, nil)
        end
        -- Trimmed and defaulted on the way.
        env.now = env.now + 10000
        D.handle(2, { action = 'search', input = { query = '  Anna Berg  ' } })
        local last = env.callsTo('fredpd_records', 'search')
        t.eq(last[#last].input, { query = 'Anna Berg', type = 'auto', page = 1 })
    end)
end

tests['8 unwrap: error codes and reasons pass through; anything odd becomes unavailable'] = function(t)
    H.with(function(env, mods)
        local D = mods['server.dispatch']
        H.openTablet(mods, 1)
        local req = { action = 'getPerson', input = { citizenid = 'ABC123' } }
        local function call(reply)
            env.replies['fredpd_records:getPersonSummary'] = reply
            env.now = env.now + 1000
            return D.handle(1, req)
        end
        t.eq(call({ ok = false, error = 'not_found' }), { error = 'not_found' })
        t.eq(call({ ok = false, error = 'unauthorized', reason = 'off_duty' }), { error = 'unauthorized', reason = 'off_duty' })
        t.eq(call({ ok = false, error = 'validation', reason = 'bad reason!' }), { error = 'validation' }, 'odd reason dropped')
        t.eq(call({ ok = false, error = 'boom' }), { error = 'unavailable' }, 'unknown code')
        t.eq(call({ ok = true }), { error = 'unavailable' }, 'ok without data')
        t.eq(call('text'), { error = 'unavailable' })
        t.eq(call(function() error('db down', 0) end), { error = 'unavailable' })
        t.eq(call({ ok = true, data = { person = { citizenid = 'ABC123' } } }), { person = { citizenid = 'ABC123' } })
        -- A stopped resource answers unavailable without calling it.
        env.resources.fredpd_records = 'stopped'
        local before = #env.calls
        t.eq(call({ ok = true, data = {} }), { error = 'unavailable' })
        t.eq(#env.calls, before)
        local logged = false
        for _, l in ipairs(env.logs) do if l.msg:find('fredpd_records is not started', 1, true) then logged = true end end
        t.ok(logged, 'logged once')
    end)
end

tests['9 close: clears the session (open or not) and needs neither grant nor duty'] = function(t)
    H.with(function(env, mods)
        local D, Open = mods['server.dispatch'], mods['server.open']
        H.openTablet(mods, 1)
        env.players[1].grants = {}
        env.players[1].duty = false
        t.eq(D.handle(1, { action = 'close', input = {} }), { ok = true })
        t.eq(Open.isOpen(1), false)
        t.eq(D.handle(1, { action = 'search', input = { query = 'Anna' } }), { error = 'unauthorized' })
        t.eq(D.handle(1, { action = 'close', input = { junk = 1 } }), { error = 'validation' })
    end)
end

tests['10 local handlers: getHome needs no grant; a raising handler answers unavailable'] = function(t)
    H.with(function(env, mods)
        local D = mods['server.dispatch']
        H.openTablet(mods, 1)
        local home = D.handle(1, { action = 'getHome', input = {} })
        t.eq(home.me.displayName, 'Anna B.')
        t.eq(home.variant, 'igv')
        -- A handler that raises (e.g. the database) is caught.
        D.ACTIONS.getHome.handler = function() error('boom', 0) end
        env.now = env.now + 1000
        t.eq(D.handle(1, { action = 'getHome', input = {} }), { error = 'unavailable' })
    end)
end

tests['11 main.lua: callbacks, the close event (own session only), exports and playerDropped'] = function(t)
    H.with(function(env, mods)
        H.run('server/main.lua')
        t.ok(env.callbacks['fredpd:mdt:open'] and env.callbacks['fredpd:mdt:action'], 'callbacks registered')
        t.ok(env.net['fredpd:mdt:closed'], 'close is a net event')
        for _, name in ipairs({ 'isTabletOpen', 'pushToOpenTablets', 'pushTo', 'closeTablet' }) do
            t.ok(env.exported[name], 'export ' .. name)
        end
        -- main.lua required its own module instances; use them through the callbacks and exports.
        local payload = env.callbacks['fredpd:mdt:open'](1, { mode = 'item', slot = 3 })
        t.eq(payload.me, { citizenid = 'MDT10001', displayName = 'Anna B.', callsign = 'IGV-07' })
        env.callbacks['fredpd:mdt:open'](2, { mode = 'item' })
        t.eq(env.exported.isTabletOpen(1), true)
        t.eq(env.callbacks['fredpd:mdt:action'](1, { action = 'search', input = { query = 'Anna' } }),
            { routed = 'fredpd_records:search' })
        -- The close event takes no target: player 2 closing clears only player 2.
        env.fire('fredpd:mdt:closed', 2, 1)
        t.eq(env.exported.isTabletOpen(1), true, 'player 1 still open')
        t.eq(env.exported.isTabletOpen(2), false, 'player 2 closed')
        env.fire('playerDropped', 1)
        t.eq(env.exported.isTabletOpen(1), false, 'dropped')
        t.eq(env.callbacks['fredpd:mdt:action'](1, { action = 'search', input = { query = 'Anna' } }),
            { error = 'unauthorized' })
        -- closeTablet export: forces the client closed with a (sanitised) reason key.
        env.now = env.now + 1000
        env.callbacks['fredpd:mdt:open'](2, { mode = 'item' })
        env.client = {}
        t.eq(env.exported.closeTablet(2, 'tablet.revoked'), true)
        t.eq(env.sent(2, 'fredpd:client:forceClose')[1].args, { 'tablet.revoked' })
        env.now = env.now + 1000
        env.callbacks['fredpd:mdt:open'](2, { mode = 'item' })
        env.client = {}
        t.eq(env.exported.closeTablet(2, 'bad key!'), true)
        t.eq(env.sent(2, 'fredpd:client:forceClose')[1].args, {})
        t.eq(env.exported.closeTablet(2), false, 'already closed')
    end)
end

tests['12 terminal session: re-checked per action; leaving the vehicle force-closes it'] = function(t)
    H.with(function(env, mods)
        local D, Open = mods['server.dispatch'], mods['server.open']
        env.seat(2, 7003, 'police3', -1)
        H.openTablet(mods, 2, { mode = 'terminal' })
        t.eq(D.handle(2, { action = 'search', input = { query = 'Anna' } }), { routed = 'fredpd_records:search' })
        -- Client left the car but suppressed its close event.
        env.vehicles = {}
        env.client = {}
        env.now = env.now + 10000
        t.eq(D.handle(2, { action = 'search', input = { query = 'Anna' } }), { error = 'unauthorized' })
        t.eq(Open.isOpen(2), false)
        t.eq(env.sent(2, 'fredpd:client:forceClose')[1].args, { 'tablet.unavailable' })
        t.eq(#env.callsTo('fredpd_records', 'search'), 1, 'not routed after leaving')
        t.eq(D.handle(2, { action = 'close', input = {} }), { ok = true }, 'close still works')
        -- Item sessions are not tied to a vehicle.
        env.now = env.now + 10000
        H.openTablet(mods, 1)
        t.eq(D.handle(1, { action = 'search', input = { query = 'Anna' } }), { routed = 'fredpd_records:search' })
    end)
end

-- RECORDS_ACTIONS (§C14) and INTEL_ACTIONS (§C15): export = action name; limit class per action.
local PHASE5 = {
    fredpd_records = {
        listCases = 'read', getCase = 'read', createCase = 'write', updateCase = 'write', assignCase = 'write',
        unassignCase = 'write', addCaseSubject = 'write', closeCase = 'write', getReport = 'read',
        createReport = 'write', saveReport = 'write', saveReportDraft = 'draft', listReportTemplates = 'read',
        listCharges = 'read', applyCharges = 'write', issueFine = 'write',
    },
    fredpd_intel = {
        listSources = 'read', getSource = 'read', createSource = 'write', updateSource = 'write',
        listIntelReports = 'read', getIntelReport = 'read', createIntelReport = 'write', searchEntities = 'read',
        ensureEntity = 'write', getEntity = 'read', addLink = 'write', getGraph = 'read', listMissions = 'read',
        getMission = 'read', createMission = 'write', addMissionMember = 'write', closeMission = 'write',
    },
}

--- Every valid fixture sample of an action (so nested/union/array shapes are routed too).
local function allValid(action)
    local out = {}
    for _, s in ipairs(FIX.shapes[FIX.actions[action].shape].valid) do out[#out + 1] = H.copy(s.input) end
    return out
end

tests['13 RECORDS/INTEL actions: routed to the same-named export with (src, cleaned input) and their limit class'] = function(t)
    H.with(function(env, mods)
        local D, Config = mods['server.dispatch'], mods['config']
        H.openTablet(mods, 2)
        env.players[2].grants['perm:*'] = true
        local n = 0
        for res, actions in pairs(PHASE5) do
            for action, limit in pairs(actions) do
                t.eq(D.ACTIONS[action].route, { res, action }, action .. ' route')
                t.eq(D.ACTIONS[action].limit, limit, action .. ' limit class')
                for _, input in ipairs(allValid(action)) do
                    env.now = env.now + 10000
                    local before = #env.callsTo(res, action)
                    t.eq(D.handle(2, { action = action, input = input }), { routed = res .. ':' .. action }, action)
                    local calls = env.callsTo(res, action)
                    t.eq(#calls, before + 1, action .. ' called once')
                    t.eq(calls[#calls].src, 2)
                    t.eq(calls[#calls].input, FIX.shapes[FIX.actions[action].shape].valid[#calls].output,
                        action .. ' gets zod\'s cleaned value')
                    n = n + 1
                end
                -- A second call inside the window is limited; after it, allowed again.
                local input = allValid(action)[1]
                t.eq(D.handle(2, { action = action, input = input }), { error = 'rate_limited' }, action .. ' limited')
                env.now = env.now + Config.limits[limit] - 1
                t.eq(D.handle(2, { action = action, input = input }), { error = 'rate_limited' }, action .. ' still limited')
                env.now = env.now + 1
                t.eq(D.handle(2, { action = action, input = input }).error, nil, action .. ' window over')
            end
        end
        t.ok(n >= 60, 'routed every valid sample, got ' .. n)
        t.eq(Config.limits.read, 500)
        t.eq(Config.limits.write, 2000)
        t.eq(Config.limits.draft, 5000)
    end)
end

tests['14 RECORDS/INTEL grants: without its grant column an action is unauthorized and not routed'] = function(t)
    H.with(function(env, mods)
        local D = mods['server.dispatch']
        H.openTablet(mods, 2)
        local all = { ['mdt_page:search'] = true, ['mdt_page:cases'] = true, ['mdt_page:intel'] = true,
            ['perm:cases.create'] = true, ['perm:charges.apply'] = true, ['perm:charges.fine'] = true,
            ['perm:intel.read'] = true, ['perm:intel.handler'] = true, ['perm:intel.command'] = true }
        for res, actions in pairs(PHASE5) do
            for action in pairs(actions) do
                local grant = FIX.actions[action].grant
                env.players[2].grants = H.copy(all)
                env.now = env.now + 10000
                t.eq(D.handle(2, { action = action, input = allValid(action)[1] }), { routed = res .. ':' .. action },
                    action .. ' allowed')
                if grant then
                    env.players[2].grants[grant[1] .. ':' .. grant[2]] = nil
                    env.now = env.now + 10000
                    local before = #env.calls
                    t.eq(D.handle(2, { action = action, input = allValid(action)[1] }), { error = 'unauthorized' },
                        action .. ' needs ' .. grant[1] .. ':' .. grant[2])
                    t.eq(#env.calls, before, action .. ' not routed')
                end
            end
        end
        -- listCharges has no grant column but still needs duty.
        env.players[2].grants = { ['mdt_page:search'] = true }
        env.now = env.now + 10000
        t.eq(D.handle(2, { action = 'listCharges', input = {} }), { routed = 'fredpd_records:listCharges' })
        env.players[2].duty = false
        env.now = env.now + 10000
        t.eq(D.handle(2, { action = 'listCharges', input = {} }), { error = 'unauthorized', reason = 'off_duty' })
    end)
end

tests['15 unavailable: stopped resource, missing export, raising export, malformed answer'] = function(t)
    H.with(function(env, mods)
        local D = mods['server.dispatch']
        H.openTablet(mods, 2)
        env.players[2].grants['perm:*'] = true
        local function call(action, input)
            env.now = env.now + 10000
            return D.handle(2, { action = action, input = input })
        end
        for _, res in ipairs({ 'fredpd_records', 'fredpd_intel', 'fredpd_dispatch', 'fredpd_forensics' }) do
            env.resources[res] = 'stopped'
        end
        local before = #env.calls
        for _, action in ipairs({ 'createCase', 'getGraph', 'takeAlert', 'getEvidence', 'saveReportDraft' }) do
            t.eq(call(action, allValid(action)[1]), { error = 'unavailable' }, action .. ' stopped')
        end
        t.eq(#env.calls, before, 'a stopped resource is never called')
        env.resources.fredpd_records, env.resources.fredpd_intel = 'started', 'started'
        -- An export the resource does not (yet) provide: FiveM raises "No such export" -> unavailable.
        env.exports.fredpd_records.closeCase = nil
        env.exports.fredpd_intel.closeMission = nil
        t.eq(call('closeCase', { id = 1, resolution = 'Klar' }), { error = 'unavailable' }, 'missing records export')
        t.eq(call('closeMission', { id = 1 }), { error = 'unavailable' }, 'missing intel export')
        env.replies['fredpd_intel:addLink'] = function() error('deadlock', 0) end
        t.eq(call('addLink', allValid('addLink')[1]), { error = 'unavailable' }, 'raise')
        env.replies['fredpd_records:getCase'] = { data = {} }
        t.eq(call('getCase', { id = 1 }), { error = 'unavailable' }, 'no ok field')
        env.replies['fredpd_records:getCase'] = { ok = false, error = 'not_found' }
        t.eq(call('getCase', { id = 1 }), { error = 'not_found' }, 'codes pass through')
        local logged = {}
        for _, l in ipairs(env.logs) do logged[#logged + 1] = l.msg end
        local text = table.concat(logged, '\n')
        t.ok(text:find('fredpd_intel is not started', 1, true), 'stopped logged')
        t.ok(text:find('fredpd_records:closeCase failed', 1, true), 'missing export logged')
    end)
end

tests['16 nested inputs: union, array defaults and refines are cleaned before routing'] = function(t)
    H.with(function(env, mods)
        local D = mods['server.dispatch']
        H.openTablet(mods, 2)
        env.players[2].grants['perm:*'] = true
        local function last(res, fn)
            local c = env.callsTo(res, fn)
            return c[#c].input
        end
        env.now = env.now + 10000
        D.handle(2, { action = 'addLink', input = { fromId = 1, to = { id = 2, label = 'x', type = 'person' },
            type = ' känner ', extra = 1 } })
        t.eq(last('fredpd_intel', 'addLink'), { fromId = 1, to = { id = 2 }, type = 'känner', confidence = 50, level = 1 })
        env.now = env.now + 10000
        D.handle(2, { action = 'applyCharges', input = { reportId = 3, citizenid = 'ABC1',
            lines = { { code = 'BrB 8:1', junk = true }, { code = 'TF-2', quantity = 2 } } } })
        t.eq(last('fredpd_records', 'applyCharges'), { reportId = 3, citizenid = 'ABC1',
            lines = { { code = 'BrB 8:1', quantity = 1 }, { code = 'TF-2', quantity = 2 } } })
        env.now = env.now + 10000
        local before = #env.calls
        t.eq(D.handle(2, { action = 'addCaseSubject', input = { id = 1, type = 'person', plate = 'ABC' } }),
            { error = 'validation' }, 'refine')
        t.eq(D.handle(2, { action = 'applyCharges', input = { reportId = 3, citizenid = 'ABC1', lines = {} } }),
            { error = 'validation' }, 'empty lines')
        t.eq(D.handle(2, { action = 'addLink', input = { fromId = 1, to = {}, type = 'känner' } }),
            { error = 'validation' }, 'union: no option')
        t.eq(#env.calls, before)
    end)
end

tests['17 item session: a write after the tablet left the inventory force-closes the MDT (8.3 review)'] = function(t)
    H.with(function(env, mods)
        local D, Open = mods['server.dispatch'], mods['server.open']
        H.openTablet(mods, 1)
        local create = { action = 'createBolo', input = valid('createBolo') }
        t.eq(D.handle(1, create).error, nil, 'tablet held: routed')
        -- Another pd_tablet (other serial) does not count: the session's tablet is gone.
        env.players[1].items = { { slot = 4, name = 'pd_tablet', count = 1, metadata = { serial = 'SP-AAAA-0099' } } }
        env.now = env.now + 10000
        local search = { action = 'search', input = { query = 'Anna' } }
        t.eq(D.handle(1, search).error, nil, 'reads are not re-checked')
        local before = #env.callsTo('fredpd_bolo', 'createBolo')
        t.eq(D.handle(1, create), { error = 'unauthorized' })
        t.eq(Open.isOpen(1), false)
        t.eq(env.sent(1, 'fredpd:client:forceClose')[1].args, { 'tablet.noItem' })
        t.eq(#env.callsTo('fredpd_bolo', 'createBolo'), before, 'not routed')
        -- Inventory stopped: refused as unavailable, the session stays open.
        env.players[1].items = { { slot = 3, name = 'pd_tablet', count = 1, metadata = { serial = 'SP-AAAA-0001' } } }
        env.now = env.now + 10000
        H.openTablet(mods, 1)
        env.resources[env.inventory] = 'stopped'
        env.now = env.now + 10000
        t.eq(D.handle(1, create), { error = 'unavailable' })
        t.eq(Open.isOpen(1), true)
        env.resources[env.inventory] = 'started'
        env.now = env.now + 10000
        t.eq(D.handle(1, create).error, nil)
    end)
end

return tests
