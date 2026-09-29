-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_records person page, vehicle page and "my cases" (tasks 2.4/2.5/2.7 server side) against a real MariaDB:
-- PersonSummary / VehicleSummary / CaseRef shapes for full, masked (with and without title), notice (contact from
-- fredpd_officers, after the visible refs) and none (omitted); charge records only for cases whose content the viewer
-- may see; BOLO lists and flags; housing address; plate-check history (newest 20, hits on hidden BOLOs, missing
-- table); audit once per lookup, not_found included; failure paths; golden JSON.
-- Harness: tests/lua/records_env_test.lua. Run: lua5.4 tests/lua/run.lua records_
local H = require('records_env_test')

local tests = {}

--- The person-page world. Case ids 1..9 in insertion order; viewer 1 (IGV, REC10001) sees:
---   7 masked without title (override), 6 none (override), 5 notice (no owner: unit only), 4 full (owner),
---   1 notice (Olle, utredning), 3 notice (closed level 1 > tier 0), 2 masked with title (closed level 0),
---   8 full (owner, record only), 9 notice (closed level 2 > tier 0, record only).
--- Records 1..8: 1 case 4, 2 case 1 (empty snapshot title), 3 no case, 4 revoked, 5 case 8, 6 case 9, 7 RP002,
--- 8 case 7 (masked at level 1).
local function seedWorld(env)
    H.persons({
        { 'RP001', 'Anna', 'Andersson', '1990-05-17', '19900517-1234', 1, '070-123 45 67' },
        { 'RP002', 'Bo', 'Ek', nil, nil, nil, nil },
    })
    H.vehicles({ { 'ABC123', 'RP001', 'sultan' }, { 'XYZ98A', 'RP001', nil } })
    local P = function(role) return { 'person', 'RP001', role } end
    H.case({ 'K-1-26', 'Rån mot värdetransport', 'open', 0, 'utredning', 'REC10002', '2026-09-01 10:00:00',
        subjects = { P('suspect'), { 'vehicle', 'ABC123', 'other' } } })
    H.case({ 'K-2-26', 'Stöld av moped', 'closed', 0, 'utredning', 'REC10002', '2026-09-02 10:00:00',
        subjects = { P('witness') } })
    H.case({ 'K-3-26', 'Grovt narkotikabrott', 'closed', 1, 'utredning', 'REC10002', '2026-09-03 10:00:00',
        subjects = { P('victim') } })
    H.case({ 'K-4-26', 'Misshandel på Grove Street', 'open', 0, 'igv', 'REC10001', '2026-09-04 10:00:00',
        assignees = { 'REC10001' }, subjects = { P('suspect'), { 'vehicle', 'ABC123', 'suspect' } } })
    H.case({ 'K-5-26', 'Spaningsärende', 'open', 2, 'ledning', nil, '2026-09-05 10:00:00',
        assignees = { 'REC10003' }, subjects = { P('other') } })
    H.case({ 'K-6-26', 'Dolt ärende', 'open', 0, 'utredning', 'REC10002', '2026-09-06 10:00:00',
        subjects = { P('suspect') } })
    H.case({ 'K-7-26', 'Bedrägeri', 'open', 1, 'utredning', 'REC10002', '2026-09-07 10:00:00',
        subjects = { P('other') } })
    H.case({ 'K-8-26', 'Olovlig körning', 'closed', 0, 'igv', 'REC10001', '2026-08-01 10:00:00' })
    H.case({ 'K-9-26', 'Hemlig utredning', 'closed', 2, 'ledning', 'REC10003', '2026-08-02 10:00:00' })
    env.visOverride['case:6'] = 'none'
    env.visOverride['case:7'] = 'masked'
    H.insert('fredpd_records', { 'citizenid', 'case_id', 'charge_code', 'title_sv', 'class', 'fine', 'jail_min',
        'status', 'issued_by', 'created_at' }, {
        { 'RP001', 4, 'BRB-005', 'Misshandel', 'fängelse', 3000, 0, 'issued', 'REC10001', '2026-09-04 12:00:00' },
        { 'RP001', 1, 'BRB-004', '', 'bot', 1500, 0, 'paid', 'REC10002', '2026-09-03 12:00:00' },
        { 'RP001', nil, 'BRB-001', 'Mord', 'fängelse', 0, 60, 'served', 'REC10002', '2026-09-02 12:00:00' },
        { 'RP001', 4, 'BRB-003', 'Dråp', 'fängelse', 0, 30, 'revoked', 'REC10002', '2026-09-05 12:00:00' },
        { 'RP001', 8, 'BRB-005', 'Misshandel', 'bot', 2000, 0, 'issued', 'REC10001', '2026-08-01 12:00:00' },
        { 'RP001', 9, 'BRB-005', 'Misshandel', 'bot', 2500, 0, 'issued', 'REC10003', '2026-07-01 12:00:00' },
        { 'RP002', nil, 'BRB-005', 'Misshandel', 'bot', 1, 0, 'issued', 'REC10001', '2026-07-01 12:00:00' },
        { 'RP001', 7, 'BRB-005', 'Misshandel', 'bot', 500, 0, 'issued', 'REC10002', '2026-06-01 12:00:00' },
    })
    env.bolos.lists['person:RP001'] = { H.bolo(3, 'person') }
    env.bolos.lists['vehicle:ABC123'] = { H.bolo(7, 'vehicle') }
    env.bolos.plates.ABC123 = H.bolo(7, 'vehicle')
    env.addresses.RP001 = { { propertyId = 12, label = 'Grove Street 12' }, { 13, 'Vinewood Hills 3' } }
end

local function person(mods, src, input) return mods['server.summary'].person(src, input) end
local function vehicle(mods, src, input) return mods['server.summary'].vehicle(src, input) end

---------------------------------------------------------------------------------------------------------------
-- Person

tests['01 person: validation, unauthorized, not_found (audited as a lookup)'] = function(t)
    H.with(t, function(_, env, mods)
        seedWorld(env)
        for i, input in ipairs({ 'RP001', {}, { citizenid = 5 }, { citizenid = 'RP 001' }, { citizenid = ('x'):rep(51) },
            { citizenid = "RP001'--" }, { citizenid = '' } }) do
            t.eq(person(mods, 1, input), { ok = false, error = 'validation' }, 'input #' .. i)
        end
        t.eq(person(mods, 1, nil), { ok = false, error = 'validation' })
        t.eq(person(mods, 4, { citizenid = 'RP001' }), { ok = false, error = 'unauthorized' }, 'no search grant')
        t.eq(person(mods, 0, { citizenid = 'RP001' }), { ok = false, error = 'unauthorized' })
        t.eq(#env.audits, 0, 'rejected calls are not lookups')
        t.eq(person(mods, 1, { citizenid = 'NOPE01' }), { ok = false, error = 'not_found' })
        t.eq(env.audits, { { src = 1, action = 'lookup.person', targetType = 'person', targetId = 'NOPE01',
            meta = { source = 'summary', found = false } } }, 'probing for a citizenid leaves a trace')
    end)
end

tests['02 person: full summary with every CaseRef variant, records and audit'] = function(t)
    H.with(t, function(_, env, mods)
        seedWorld(env)
        local r = person(mods, 1, { citizenid = 'RP001' })
        t.eq(r.ok, true)
        local d = r.data
        t.eq(H.keys(d), { 'address', 'bolos', 'cases', 'person', 'records', 'vehicles' })
        t.eq(d.person, { citizenid = 'RP001', firstname = 'Anna', lastname = 'Andersson', birthdate = '1990-05-17',
            personnummer = '19900517-1234', gender = 'female', phone = '070-123 45 67' })
        t.eq(d.vehicles, { { plate = 'ABC123', model = 'sultan', bolo = true }, { plate = 'XYZ98A', bolo = false } })
        t.eq(d.bolos, { H.bolo(3, 'person') })
        t.eq(d.address, 'Grove Street 12; Vinewood Hills 3')
        t.eq(d.cases, {
            { visibility = 'masked', id = 7, caseNumber = 'K-7-26', status = 'open', level = 1, role = 'other' },
            { visibility = 'full', id = 4, caseNumber = 'K-4-26', title = 'Misshandel på Grove Street', status = 'open',
                level = 0, role = 'suspect' },
            { visibility = 'masked', id = 2, caseNumber = 'K-2-26', title = 'Stöld av moped', status = 'closed',
                level = 0, role = 'witness' },
            { visibility = 'notice', contact = { unit = 'ledning' } },
            { visibility = 'notice', contact = { displayName = 'Olle Utredare', unit = 'utredning' } },
            { visibility = 'notice', contact = { displayName = 'Olle Utredare', unit = 'utredning' } },
        }, 'visible refs open first (newest first), then the notices by contact only; none omitted; masked title '
            .. 'only when level <= tier')
        for _, ref in ipairs(d.cases) do H.checkRef(t, ref) end
        t.eq(d.records, {
            { id = 1, chargeCode = 'BRB-005', title = 'Misshandel', fine = 3000, jailMinutes = 0,
                createdAt = '2026-09-04T12:00:00Z', caseNumber = 'K-4-26' },
            { id = 3, chargeCode = 'BRB-001', title = 'Mord', fine = 0, jailMinutes = 60,
                createdAt = '2026-09-02T12:00:00Z' },
            { id = 5, chargeCode = 'BRB-005', title = 'Misshandel', fine = 2000, jailMinutes = 0,
                createdAt = '2026-08-01T12:00:00Z', caseNumber = 'K-8-26' },
        }, 'revoked excluded; records of notice cases (1, level-2 case 9) and of a case masked above the tier (7) are '
            .. 'left out entirely; a record without a case is shown')
        -- UTC although every session runs at +02:00 (§C7)
        t.eq(MySQL.scalar.await("SELECT DATE_FORMAT(created_at, '%H') FROM fredpd_records WHERE id = 1"), 12)
        t.eq(env.calls.canViewMany, 1, 'one batch for subject cases and record cases')
        t.eq(env.calls.canView, 0)
        local audits = env.named('lookup.person')
        t.eq(#audits, 1)
        t.eq(audits[1].src, 1)
        t.eq(audits[1].targetType, 'person')
        t.eq(audits[1].targetId, 'RP001')
        t.eq(audits[1].meta, { source = 'summary', found = true })
        t.eq(#env.audits, 1, 'nothing else audited')
        H.golden(t, 'person.summary', d)
    end)
end

tests['03 person: minimal person, gender mapping, other viewers'] = function(t)
    H.with(t, function(_, env, mods)
        seedWorld(env)
        local d = person(mods, 1, { citizenid = 'RP002' }).data
        t.eq(d.person, { citizenid = 'RP002', firstname = 'Bo', lastname = 'Ek', gender = 'unknown' })
        t.eq(d.vehicles, {})
        t.eq(d.bolos, {})
        t.eq(d.cases, {})
        t.eq(#d.records, 1)
        t.eq(d.address, nil)
        H.golden(t, 'person.minimal', d)
        local S = mods['server.summary']
        t.eq({ S.gender(0), S.gender(1), S.gender(nil), S.gender(7), S.gender('1') }, { 'male', 'female', 'unknown',
            'unknown', 'female' })
        -- viewer 2 (Utredning, tier 1, owner of cases 1-3 and 6-7). Case 7 is forced to 'masked' for every viewer:
        -- tier 1 >= level 1, so its title is shown. Case 6 is none for everyone.
        local owner = person(mods, 2, { citizenid = 'RP001' }).data
        t.eq(owner.cases, {
            { visibility = 'masked', id = 7, caseNumber = 'K-7-26', title = 'Bedrägeri', status = 'open', level = 1,
                role = 'other' },
            { visibility = 'full', id = 1, caseNumber = 'K-1-26', title = 'Rån mot värdetransport', status = 'open',
                level = 0, role = 'suspect' },
            { visibility = 'full', id = 3, caseNumber = 'K-3-26', title = 'Grovt narkotikabrott', status = 'closed',
                level = 1, role = 'victim' },
            { visibility = 'full', id = 2, caseNumber = 'K-2-26', title = 'Stöld av moped', status = 'closed',
                level = 0, role = 'witness' },
            { visibility = 'notice', contact = { displayName = 'Anna Patrull', unit = 'igv' } },
            { visibility = 'notice', contact = { unit = 'ledning' } },
        }, 'visible first; notices by contact (igv before ledning), not by status or date')
        for _, ref in ipairs(owner.cases) do H.checkRef(t, ref) end
        local function recordIds(list)
            local out = {}
            for i, r in ipairs(list) do out[i] = { r.id, r.caseNumber } end
            return out
        end
        t.eq(recordIds(owner.records), { { 2, 'K-1-26' }, { 3 }, { 5, 'K-8-26' }, { 8, 'K-7-26' } },
            'own case 1 full, case 8 masked at level 0, case 7 masked at level 1 = tier; IGV case 4 (notice) and '
            .. 'level-2 case 9 (notice) hidden')
        t.eq(owner.records[1].title, 'Ringa misshandel', 'empty snapshot title falls back to the catalogue')
        -- records.admin sees every case in full (case 7 stays masked by its override, level 1 <= tier 2)
        local admin = person(mods, 3, { citizenid = 'RP001' }).data
        t.eq(recordIds(admin.records), { { 1, 'K-4-26' }, { 2, 'K-1-26' }, { 3 }, { 5, 'K-8-26' }, { 6, 'K-9-26' },
            { 8, 'K-7-26' } })
    end)
end

tests['04 person: dependencies failing or stopped degrade to empty values'] = function(t)
    H.with(t, function(_, env, mods)
        seedWorld(env)
        env.boloThrows = true
        env.adapterThrows = true
        env.failMany = true
        local d = person(mods, 1, { citizenid = 'RP001' }).data
        t.eq(d.bolos, {})
        t.eq(d.address, nil)
        t.eq(d.vehicles[1].bolo, false)
        t.eq(#d.cases, 6, 'canView per case when canViewMany fails')
        t.eq(env.calls.canView, 9, 'seven subject cases + two record cases')
        person(mods, 1, { citizenid = 'RP001' })
        t.eq(env.logged('warn', 'getBolosFor'), 1)
        t.eq(env.logged('warn', 'getAddresses'), 1)
        t.eq(env.logged('warn', 'canViewMany'), 1)
        -- stopped: no calls, no warnings
        env.boloThrows, env.adapterThrows, env.failMany = false, false, false
        env.resources.fredpd_bolo = 'stopped'
        local calls = env.calls.getBolosFor
        local s = person(mods, 1, { citizenid = 'RP001' }).data
        t.eq(s.bolos, {})
        t.eq(env.calls.getBolosFor, calls)
        -- getBolosFor answering { ok, data } is unwrapped; an error result is []
        env.resources.fredpd_bolo = 'started'
        env.bolos.lists['person:RP001'] = function() return { ok = true, data = { H.bolo(9, 'person') } } end
        t.eq(person(mods, 1, { citizenid = 'RP001' }).data.bolos[1].id, 9)
        env.bolos.lists['person:RP001'] = function() return { ok = false, error = 'unauthorized' } end
        t.eq(person(mods, 1, { citizenid = 'RP001' }).data.bolos, {})
        -- a database failure is an error for the export wrapper (main.lua turns it into 'unavailable')
        env.failSql = 'fredpd_records r'
        t.ok(not pcall(person, mods, 1, { citizenid = 'RP001' }), 'raises')
    end)
end

tests['05 CaseRef: masked title rule and notice contact fallbacks'] = function(t)
    H.with(t, function(_, _, mods)
        local Refs = mods['server.caserefs']
        local c = { id = 3, caseNumber = 'K-3-26', title = 'T', status = 'closed', level = 1, unit = 'span',
            owner = 'REC10002', role = 'victim' }
        t.eq(Refs.toRef(c, 'masked', 0, {}), { visibility = 'masked', id = 3, caseNumber = 'K-3-26', status = 'closed',
            level = 1, role = 'victim' })
        t.eq(Refs.toRef(c, 'masked', 1, {}).title, 'T')
        t.eq(Refs.toRef(c, 'full', 0, {}).title, 'T', 'full always has the title')
        t.eq(Refs.toRef(c, 'notice', 0, {}), { visibility = 'notice', contact = { unit = 'span' } }, 'no officer row')
        t.eq(Refs.toRef(c, 'notice', 0, { REC10002 = { displayName = 'Olle' } }),
            { visibility = 'notice', contact = { displayName = 'Olle', unit = 'span' } }, 'officer without unit')
        t.eq(Refs.toRef(c, 'none', 2, {}), nil)
        t.eq(Refs.rowToCase({ id = 1, status = 'weird' }), nil)
        t.eq(Refs.rowToCase({ id = 1, status = 'open', level = 9, role = 'boss' }).level, 2, 'bad level -> 2')
        t.eq(Refs.rowToCase({ id = 1, status = 'open', role = 'boss' }).role, nil, 'unknown role dropped')
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Vehicle

--- BOLOs behind the hits: 1 live level 0 (visible), 2 live level 2 in 'ledning' (overridden to none for viewer 1;
--- a kontaktnotis BOLO would still show the hit, as notice reveals existence),
--- 3 resolved level 0 (visible, closed). Checks 1..25 on ABC123 (minute = i); every 5th is a hit: 25 -> BOLO 1,
--- 20 -> BOLO 2 (hidden: reads as a plain check), 15 -> BOLO 3, 10 -> no bolo_id (unknown: no hit), 5 -> BOLO 1.
local function seedChecks()
    H.insert('fredpd_bolos', { 'kind', 'plate', 'reason', 'level', 'unit', 'issued_by', 'active' }, {
        { 'vehicle', 'ABC123', 'Efterlyst för rån', 0, 'utredning', 'REC10002', 1 },
        { 'vehicle', 'ABC123', 'Spaning', 2, 'ledning', 'REC10003', 1 },
        { 'vehicle', 'ABC123', 'Gammal', 0, 'igv', 'REC10001', 0 },
    })
    local hitBolo = { [25] = 1, [20] = 2, [15] = 3, [5] = 1 }
    local rows = {}
    for i = 1, 25 do
        rows[#rows + 1] = { 'ABC123', i % 2 == 0 and 'REC10001' or 'GHOST01', i % 5 == 0 and 1 or 0, hitBolo[i],
            ('2026-09-10 10:%02d:00'):format(i) }
    end
    rows[#rows + 1] = { 'XYZ98A', 'REC10001', 0, nil, '2026-09-11 10:00:00' }
    H.insert('fredpd_plate_checks', { 'plate', 'officer_citizenid', 'hit', 'bolo_id', 'created_at' }, rows)
end

tests['06 vehicle: owner, BOLOs, cases as role vehicle, 20 newest checks with OfficerRef'] = function(t)
    H.with(t, function(_, env, mods)
        seedWorld(env)
        seedChecks()
        env.visOverride['bolo:2'] = 'none'
        local r = vehicle(mods, 1, { plate = 'abc 123' })
        t.eq(r.ok, true)
        local d = r.data
        t.eq(H.keys(d), { 'bolos', 'cases', 'checks', 'owner', 'vehicle' })
        t.eq(d.vehicle, { plate = 'ABC123', model = 'sultan' })
        t.eq(d.owner, { citizenid = 'RP001', name = 'Anna Andersson' })
        t.eq(d.bolos, { H.bolo(7, 'vehicle') })
        t.eq(d.cases, {
            { visibility = 'full', id = 4, caseNumber = 'K-4-26', title = 'Misshandel på Grove Street', status = 'open',
                level = 0, role = 'vehicle' },
            { visibility = 'notice', contact = { displayName = 'Olle Utredare', unit = 'utredning' } },
        })
        for _, ref in ipairs(d.cases) do H.checkRef(t, ref) end
        t.eq(#d.checks, 20)
        t.eq(d.checks[1], { checkedAt = '2026-09-10T10:25:00Z', hit = true }, 'newest first; unknown officer -> null')
        t.eq(d.checks[2], { checkedAt = '2026-09-10T10:24:00Z', hit = false,
            officer = { citizenid = 'REC10001', displayName = 'Anna Patrull', callsign = 'IGV-07', unit = 'igv' } })
        t.eq(d.checks[20].checkedAt, '2026-09-10T10:06:00Z')
        local hits = {}
        for _, c in ipairs(d.checks) do if c.hit then hits[#hits + 1] = c.checkedAt:sub(15, 16) end end
        t.eq(hits, { '25', '15' }, 'hits on visible BOLOs only (20: hidden level-2 BOLO, 10: no bolo_id)')
        t.eq(env.calls.canViewMany >= 1, true)
        env.visOverride['bolo:2'] = nil
        local lead = vehicle(mods, 3, { plate = 'ABC123' }).data
        hits = {}
        for _, c in ipairs(lead.checks) do if c.hit then hits[#hits + 1] = c.checkedAt:sub(15, 16) end end
        t.eq(hits, { '25', '20', '15' }, 'without the override the level-2 BOLO hit shows')
        table.remove(env.audits)
        for _, c in ipairs(d.checks) do t.ok(c.checkedAt:match(H.ISO), 'ISO UTC') end
        local audits = env.named('lookup.vehicle')
        t.eq(#audits, 1)
        t.eq(audits[1].targetId, 'ABC123')
        t.eq(audits[1].meta, { source = 'summary', found = true, registered = true })
        H.golden(t, 'vehicle.summary', d)
    end)
end

tests['07 vehicle: unregistered with a BOLO, unknown plate, validation, refresh'] = function(t)
    H.with(t, function(_, env, mods)
        seedWorld(env)
        env.bolos.lists['vehicle:FAKE01'] = { H.bolo(8, 'vehicle', { plate = 'FAKE01' }) }
        local u = vehicle(mods, 1, { plate = 'FAKE01' })
        t.eq(u.ok, true)
        t.eq(u.data.vehicle, { plate = 'FAKE01' })
        t.eq(u.data.owner, nil)
        t.eq(u.data.cases, {})
        t.eq(u.data.checks, {})
        t.eq(env.calls.refreshPlate, 1, 'the miss asked fredpd_core to refresh')
        t.eq(env.named('lookup.vehicle')[1].meta.registered, false)
        H.golden(t, 'vehicle.unregistered', u.data)
        t.eq(vehicle(mods, 1, { plate = 'NOPE99' }), { ok = false, error = 'not_found' })
        local probes = env.named('lookup.vehicle')
        t.eq(#probes, 2, 'not_found is audited too (probing leaves a trace)')
        t.eq(probes[2].targetId, 'NOPE99')
        t.eq(probes[2].meta, { source = 'summary', found = false, registered = false })
        -- player_vehicles only (qbx stub): refreshed into the mirror and shown with its owner id
        local klm = vehicle(mods, 1, { plate = 'KLM 34E' })
        t.eq(klm.data.vehicle, { plate = 'KLM34E', model = 'blista' })
        t.eq(klm.data.owner, { citizenid = 'FPD10003', name = 'FPD10003' }, 'no mirror person row: id as name')
        for i, input in ipairs({ {}, { plate = '' }, { plate = '   ' }, { plate = ('A'):rep(17) }, { plate = 5 },
            { plate = 'AB\1C' } }) do
            t.eq(vehicle(mods, 1, input), { ok = false, error = 'validation' }, 'input #' .. i)
        end
        t.eq(vehicle(mods, 1, nil), { ok = false, error = 'validation' })
        t.eq(vehicle(mods, 4, { plate = 'ABC123' }), { ok = false, error = 'unauthorized' })
    end)
end

tests['08 vehicle: fredpd_plate_checks missing -> [] and one warning'] = function(t)
    H.with(t, function(_, env, mods)
        seedWorld(env)
        H.run('RENAME TABLE fredpd_plate_checks TO fredpd_plate_checks_moved;')
        local ok, err = pcall(function()
            local a = vehicle(mods, 1, { plate = 'ABC123' })
            local b = vehicle(mods, 1, { plate = 'ABC123' })
            t.eq(a.ok, true)
            t.eq(a.data.checks, {})
            t.eq(b.data.checks, {})
            t.eq(env.logged('warn', 'fredpd_plate_checks'), 1)
        end)
        H.run('RENAME TABLE fredpd_plate_checks_moved TO fredpd_plate_checks;')
        if not ok then error(err, 0) end
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Hem: my cases

local function seedHome(env)
    H.case({ 'K-11-26', 'Egen patrull', 'open', 0, 'igv', 'REC10001', '2026-09-01 10:00:00' })
    H.case({ 'K-12-26', 'Delad utredning', 'open', 1, 'utredning', 'REC10002', '2026-09-05 10:00:00',
        assignees = { 'REC10001', 'REC10002' } })
    H.case({ 'K-13-26', 'Avslutat', 'closed', 0, 'igv', 'REC10001', '2026-09-09 10:00:00',
        assignees = { 'REC10001' } })
    H.case({ 'K-14-26', 'Någon annans', 'open', 0, 'span', 'REC10002', '2026-09-10 10:00:00' })
    H.case({ 'K-15-26', 'Regel döljer', 'open', 2, 'ledning', 'REC10003', '2026-09-02 10:00:00',
        assignees = { 'REC10001' } })
    env.visOverride['case:5'] = 'none'
end

tests['09 home: owner or assignee, open first, limit, canView applied, count'] = function(t)
    H.with(t, function(_, env, mods)
        seedHome(env)
        local S = mods['server.summary']
        local r = S.homeCases(1, {})
        t.eq(r.ok, true)
        t.eq(r.data, {
            { visibility = 'full', id = 2, caseNumber = 'K-12-26', title = 'Delad utredning', status = 'open', level = 1 },
            { visibility = 'full', id = 1, caseNumber = 'K-11-26', title = 'Egen patrull', status = 'open', level = 0 },
            { visibility = 'full', id = 3, caseNumber = 'K-13-26', title = 'Avslutat', status = 'closed', level = 0 },
        }, 'K-14 is not mine, K-15 is none; each case once although owner and assignee')
        for _, ref in ipairs(r.data) do H.checkRef(t, ref) end
        t.eq(#S.homeCases(1, { limit = 1 }).data, 1)
        t.eq(#S.homeCases(1, nil).data, 3, 'input may be omitted')
        t.eq(S.homeCases(4, {}).data, {}, 'no cases')
        t.eq(S.homeCases(5, {}), { ok = false, error = 'unauthorized' }, 'no character loaded')
        t.eq(S.homeCases(0, {}), { ok = false, error = 'unauthorized' })
        for i, input in ipairs({ 'x', { limit = 0 }, { limit = 11 }, { limit = 2.5 }, { limit = '3' } }) do
            t.eq(S.homeCases(1, input), { ok = false, error = 'validation' }, 'input #' .. i)
        end
        t.eq(S.countMyOpenCases(1), { ok = true, data = 3 })
        t.eq(S.countMyOpenCases(2), { ok = true, data = 2 })
        t.eq(S.countMyOpenCases(5), { ok = false, error = 'unauthorized' })
        t.eq(#env.audits, 0, 'own cases are not lookups')
        H.golden(t, 'home.cases', r.data)
    end)
end

return tests
