-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_records Phase 5: cases (server/cases.lua) against MariaDB with FiveM mocked (records_env_test.lua).
-- Numbering under concurrency, level rules, the authorization matrix, canView shapes (golden files for
-- test/contract.test.ts), timeline, list filters, the §5.3 acceptance story.
local H = require('records_env_test')
local shim = require('mysql_shim')

local tests = {}

local function cases(mods) return mods['server.cases'] end

local function create(mods, src, input)
    return cases(mods).createCase(src, input)
end

local NUMBER = '^K%-%d+%-%d%d$'

tests['cases 01 createCase numbers from fredpd_sequences, audits, pushes to the owner and fires fredpd:caseUpdated'] = function(t)
    H.with(t, function(_, env, mods)
        local a = create(mods, 2, { title = 'Inbrott i villa', summary = '  Fönster krossat  ', level = 1 })
        t.eq(a.ok, true, 'created')
        local d = a.data
        t.eq(d.visibility, 'full')
        t.ok(d.caseNumber:match(NUMBER), 'case number format ' .. tostring(d.caseNumber))
        t.eq(d.caseNumber:match('^K%-(%d+)%-'), '1', 'first seq')
        t.eq(d.title, 'Inbrott i villa')
        t.eq(d.summary, 'Fönster krossat', 'summary trimmed')
        t.eq(d.level, 1)
        t.eq(d.unit, 'utredning', 'primary unit by default')
        t.eq(d.owner, { citizenid = 'REC10002', displayName = 'Olle Utredare', callsign = 'UTR-02', unit = 'utredning' })
        t.eq(d.assignees, {})
        t.ok(d.createdAt:match(H.ISO), 'createdAt ISO UTC')
        local b = create(mods, 3, { title = 'Rån mot butik' }).data
        t.eq(b.caseNumber:match('^K%-(%d+)%-'), '2', 'second seq')
        t.eq(b.unit, 'ledning')
        local audits = env.named('case.create')
        t.eq(#audits, 2)
        t.eq(audits[1].targetType, 'case')
        t.eq(audits[1].targetId, tostring(d.id))
        t.eq(audits[1].meta.label, d.caseNumber)
        t.eq(env.pushes[1].topic, 'case')
        t.eq(env.pushes[1].payload, { type = 'caseUpdated', caseId = d.id })
        t.eq(env.pushes[1].targets, { 2 }, 'pushed only to the owner')
        t.eq(env.events[1].name, 'fredpd:caseUpdated')
        t.eq(env.events[1].args, { d.id })
        -- a hand-made row holding the next number is skipped, never duplicated
        local year = d.caseNumber:match('%-(%d%d)$')
        H.run(("INSERT INTO fredpd_cases (case_number, title, status, level) VALUES ('K-3-%s', 'x', 'open', 0);"):format(year))
        local c = create(mods, 3, { title = 'Nästa nummer' }).data
        t.eq(c.caseNumber, 'K-4-' .. year, 'taken number skipped')
        t.eq(env.logged('warn', 'already taken'), 1)
    end)
end

tests['cases 02 createCase validation and level/unit rules'] = function(t)
    H.with(t, function(_, _env, mods)
        t.eq(create(mods, 1, { title = 'ab' }), { ok = false, error = 'validation' }, 'title too short')
        t.eq(create(mods, 1, { title = 'Titel', level = 3 }), { ok = false, error = 'validation' }, 'level 3')
        t.eq(create(mods, 1, { title = 'Titel', level = 1.5 }), { ok = false, error = 'validation' }, 'float level')
        t.eq(create(mods, 1, { title = 'Titel', summary = 5 }), { ok = false, error = 'validation' }, 'summary type')
        t.eq(create(mods, 1, { title = ('x'):rep(161) }), { ok = false, error = 'validation' }, 'title too long')
        t.eq(create(mods, 1, { title = 'Titel', level = 1 }), { ok = false, error = 'unauthorized', reason = 'level_above_tier' })
        t.eq(create(mods, 1, { title = 'Titel', unit = 'span' }), { ok = false, error = 'unauthorized', reason = 'unit' })
        t.eq(create(mods, 3, { title = 'Titel', unit = 'span' }).data.unit, 'span', 'records.admin may pick any unit')
        t.eq(create(mods, 6, { title = 'Titel' }), { ok = false, error = 'unauthorized' }, 'no cases.create')
        t.eq(create(mods, 4, { title = 'Titel' }), { ok = false, error = 'unauthorized' }, 'civilian')
        t.eq(create(mods, 5, { title = 'Titel' }), { ok = false, error = 'unauthorized' }, 'no character')
        t.eq(create(mods, 'x', { title = 'Titel' }), { ok = false, error = 'unauthorized' }, 'bad src')
        _env.players[1].duty = false
        t.eq(create(mods, 1, { title = 'Titel' }), { ok = false, error = 'unauthorized', reason = 'off_duty' })
    end)
end

tests['cases 03 numbering stays unique under concurrent creates (interleaved coroutines = two connections)'] = function(t)
    H.with(t, function(_, env, mods)
        local results = H.interleave(env, {
            function() return create(mods, 2, { title = 'Parallell A' }) end,
            function() return create(mods, 3, { title = 'Parallell B' }) end,
            function() return create(mods, 2, { title = 'Parallell C' }) end,
        })
        local seen = {}
        for i, r in ipairs(results) do
            t.eq(r.ok, true, 'create ' .. i)
            t.ok(not seen[r.data.caseNumber], 'unique ' .. r.data.caseNumber)
            seen[r.data.caseNumber] = true
        end
        t.eq(tonumber(MySQL.scalar.await('SELECT COUNT(DISTINCT case_number) FROM fredpd_cases')), 3)
        t.eq(tonumber(MySQL.scalar.await("SELECT value FROM fredpd_sequences WHERE seq_type = 'case'")), 3)
    end)
end

tests['cases 04 NEXT_SEQ_SQL allocates unique values from parallel client processes'] = function(t)
    H.with(t, function(_, _env, mods)
        local sql = cases(mods).NEXT_SEQ_SQL:gsub('%?', "'conctest'", 1):gsub('%?', '2026', 1)
        local c = shim.conn
        local out = os.tmpname()
        local script = {}
        -- 6 clients x 8 allocations, all started at once; each prints the value its own session allocated
        for i = 1, 6 do
            local stmts = {}
            for _ = 1, 8 do stmts[#stmts + 1] = sql .. '; SELECT LAST_INSERT_ID();' end
            script[#script + 1] = ("(mariadb --protocol=TCP -h%s -P%d -u%s -p%s -N -B %s -e %q >> %s.%d 2>&1) &")
                :format(c.host, c.port, c.user, c.password, H.DB, table.concat(stmts, ' '), out, i)
        end
        script[#script + 1] = 'wait'
        os.execute(table.concat(script, '\n'))
        local values, seen, dup = {}, {}, false
        for i = 1, 6 do
            local f = io.open(out .. '.' .. i, 'rb')
            local text = f and f:read('a') or ''
            if f then f:close() end
            os.remove(out .. '.' .. i)
            for v in text:gmatch('%d+') do
                local n = tonumber(v)
                if seen[n] then dup = true end
                seen[n] = true
                values[#values + 1] = n
            end
        end
        os.remove(out)
        t.eq(#values, 48, '48 allocations')
        t.ok(not dup, 'no value handed out twice')
        table.sort(values)
        t.eq(values[1], 1)
        t.eq(values[48], 48, 'dense 1..48')
        H.run("DELETE FROM fredpd_sequences WHERE seq_type = 'conctest';")
    end)
end

local function seedCase(env, mods, owner, input)
    local r = create(mods, owner, input or { title = 'Grov stöld', summary = 'Sammanfattning' })
    assert(r.ok, 'seed case')
    env.pushes, env.events = {}, {}
    return r.data
end

tests['cases 05 authorization matrix: owner, lead, member, unit, other unit, records.admin'] = function(t)
    H.with(t, function(_, env, mods)
        local C = cases(mods)
        local d = seedCase(env, mods, 1) -- owner IGV Anna (unit igv)
        -- 6 (igv, unit member, not assigned) sees full via the unit rule but is no editor
        t.eq(C.getCase(6, { id = d.id }).data.visibility, 'full', 'unit member full')
        t.eq(C.updateCase(6, { id = d.id, title = 'Ändrad titel' }), { ok = false, error = 'unauthorized' }, 'unit member cannot edit')
        t.eq(C.addCaseSubject(6, { id = d.id, type = 'person', citizenid = 'RP501' }), { ok = false, error = 'unauthorized' },
            'unit member is no contributor')
        -- 2 (utredning) sees only a kontaktnotis and cannot write
        t.eq(C.getCase(2, { id = d.id }).data, { visibility = 'notice', contact = { displayName = 'Anna Patrull', unit = 'igv' } })
        t.eq(C.closeCase(2, { id = d.id, resolution = 'Klart här' }), { ok = false, error = 'unauthorized' })
        -- owner assigns 6 as member, 2 as lead
        H.fewPeople()
        t.eq(C.assignCase(1, { id = d.id, citizenid = 'REC10006' }).ok, true, 'owner assigns member')
        t.eq(C.assignCase(1, { id = d.id, citizenid = 'REC10002', role = 'lead' }).ok, true, 'owner assigns lead')
        t.eq(C.addCaseSubject(6, { id = d.id, type = 'person', citizenid = 'RP501', role = 'suspect' }).ok, true, 'member adds subject')
        t.eq(C.updateCase(6, { id = d.id, title = 'Ändrad titel' }), { ok = false, error = 'unauthorized' }, 'member cannot edit')
        t.eq(C.assignCase(6, { id = d.id, citizenid = 'REC10003' }), { ok = false, error = 'unauthorized' }, 'member cannot assign')
        local byLead = C.updateCase(2, { id = d.id, title = 'Lead ändrar' })
        t.eq(byLead.ok, true, 'lead edits')
        t.eq(byLead.data.title, 'Lead ändrar')
        t.eq(C.unassignCase(2, { id = d.id, citizenid = 'REC10006' }).ok, true, 'lead unassigns')
        t.eq(C.unassignCase(2, { id = d.id, citizenid = 'REC10006' }), { ok = false, error = 'validation', reason = 'not_assigned' })
        t.eq(C.assignCase(3, { id = d.id, citizenid = 'NOPE0001' }), { ok = false, error = 'validation', reason = 'unknown_officer' })
        t.eq(C.updateCase(3, { id = d.id, summary = '' }).data.summary, nil, 'admin clears summary')
        -- hidden/missing -> not_found, never unauthorized
        t.eq(C.getCase(1, { id = 9999 }), { ok = false, error = 'not_found' })
        env.visOverride['case:' .. d.id] = 'none'
        t.eq(C.getCase(3, { id = d.id }), { ok = false, error = 'not_found' }, 'canView none')
        t.eq(C.updateCase(3, { id = d.id, title = 'Dold' }), { ok = false, error = 'not_found' }, 'write to hidden case')
        env.visOverride['case:' .. d.id] = nil
        -- validation of ids and roles
        t.eq(C.getCase(1, { id = 0 }), { ok = false, error = 'validation' })
        t.eq(C.getCase(1, { id = 'x' }), { ok = false, error = 'validation' })
        t.eq(C.assignCase(1, { id = d.id, citizenid = 'REC10003', role = 'boss' }), { ok = false, error = 'validation' })
        t.eq(C.getCase(4, { id = d.id }), { ok = false, error = 'unauthorized' }, 'civilian')
        -- the assignee got a notification and a push; pushes go to members only
        t.ok(#env.notifies >= 1, 'assignee notified')
        t.eq(env.notifies[1].data.description:match('^case%.assignedToYou'), 'case.assignedToYou')
        for _, p in ipairs(env.pushes) do
            for _, target in ipairs(p.targets) do t.ok(target == 1 or target == 2 or target == 6, 'push target member') end
        end
    end)
end

tests['cases 06 level rules: never above tier, lowering needs records.admin, closing keeps the level'] = function(t)
    H.with(t, function(_, env, mods)
        local C = cases(mods)
        local d = seedCase(env, mods, 2, { title = 'Narkotikaärende', level = 1 })
        t.eq(C.updateCase(2, { id = d.id, level = 2 }), { ok = false, error = 'unauthorized', reason = 'level_above_tier' })
        t.eq(C.updateCase(2, { id = d.id, level = 0 }), { ok = false, error = 'unauthorized', reason = 'lowering_needs_admin' })
        t.eq(C.updateCase(3, { id = d.id, level = 2 }).data.level, 2, 'admin raises within tier')
        t.eq(C.updateCase(3, { id = d.id, level = 0 }).data.level, 0, 'admin lowers')
        t.eq(C.updateCase(2, { id = d.id, level = 1 }).data.level, 1, 'owner raises to own tier')
        local closed = C.closeCase(2, { id = d.id, resolution = '  Lagförd, överlämnad till åklagare  ' })
        t.eq(closed.ok, true)
        t.eq(closed.data.status, 'closed')
        t.eq(closed.data.level, 1, 'level kept after close')
        t.ok(closed.data.closedAt:match(H.ISO), 'closedAt')
        local row = MySQL.single.await('SELECT resolution, closed_by, level FROM fredpd_cases WHERE id = ?', { d.id })
        t.eq(row.resolution, 'Lagförd, överlämnad till åklagare')
        t.eq(row.closed_by, 'REC10002')
        t.eq(C.closeCase(2, { id = d.id, resolution = 'Igen' }), { ok = false, error = 'validation', reason = 'case_closed' })
        t.eq(C.updateCase(3, { id = d.id, title = 'Efter stängning' }), { ok = false, error = 'validation', reason = 'case_closed' })
        t.eq(C.closeCase(2, { id = d.id, resolution = 'ab' }), { ok = false, error = 'validation' }, 'resolution too short')
        local changes = env.named('case.update')
        t.eq(#changes, 3)
        t.eq(changes[1].meta.levelFrom, 1)
        t.eq(changes[1].meta.levelTo, 2)
        t.eq(#env.named('case.close'), 1)
        t.eq(env.named('case.close')[1].meta.level, 1)
    end)
end

tests['cases 07 §5.3 acceptance: assign -> IGV sees kontaktnotis only -> close -> IGV sees Standard parts'] = function(t)
    H.with(t, function(_, env, mods)
        local C = cases(mods)
        H.fewPeople()
        local d = seedCase(env, mods, 2, { title = 'Misshandel på torget', summary = 'Två inblandade' })
        C.assignCase(2, { id = d.id, citizenid = 'REC10003' })
        C.addCaseSubject(2, { id = d.id, type = 'person', citizenid = 'RP502', role = 'suspect' })
        local igvOpen = C.getCase(1, { id = d.id }).data
        t.eq(igvOpen.visibility, 'notice')
        t.eq(H.keys(igvOpen), { 'contact', 'visibility' }, 'notice carries nothing else')
        C.closeCase(2, { id = d.id, resolution = 'Utrett och avslutat' })
        local igvClosed = C.getCase(1, { id = d.id }).data
        t.eq(igvClosed.visibility, 'masked')
        t.eq(igvClosed.title, 'Misshandel på torget', 'Standard title visible')
        t.eq(igvClosed.subjects[1].label, 'Omar Nilsson')
        -- a level-1 case stays a kontaktnotis for tier 0 even after close
        local secret = seedCase(env, mods, 2, { title = 'Begränsat ärende', level = 1 })
        C.closeCase(2, { id = secret.id, resolution = 'Avslutat' })
        t.eq(C.getCase(1, { id = secret.id }).data.visibility, 'notice')
    end)
end

tests['cases 08 subjects: person/vehicle must exist, role update, closed case refused'] = function(t)
    H.with(t, function(_, env, mods)
        local C = cases(mods)
        H.fewPeople()
        local d = seedCase(env, mods, 2)
        t.eq(C.addCaseSubject(2, { id = d.id, type = 'person', citizenid = 'NOBODY1' }), { ok = false, error = 'not_found', reason = 'person' })
        t.eq(C.addCaseSubject(2, { id = d.id, type = 'vehicle', plate = 'ZZZ999' }), { ok = false, error = 'not_found', reason = 'vehicle' })
        t.eq(C.addCaseSubject(2, { id = d.id, type = 'person', plate = 'ABC123' }), { ok = false, error = 'validation' })
        t.eq(C.addCaseSubject(2, { id = d.id, type = 'vehicle', plate = 'abc 123', role = 'other' }).ok, true)
        C.addCaseSubject(2, { id = d.id, type = 'person', citizenid = 'RP501', role = 'witness' })
        local after = C.addCaseSubject(2, { id = d.id, type = 'person', citizenid = 'RP501', role = 'victim' }).data
        t.eq(#after.subjects, 2)
        local byType = {}
        for _, s in ipairs(after.subjects) do byType[s.type] = s end
        t.eq(byType.vehicle, { type = 'vehicle', plate = 'ABC123', label = 'ABC123 (sultan)', role = 'other' })
        t.eq(byType.person, { type = 'person', citizenid = 'RP501', label = 'Sara Svensson', role = 'victim' })
        C.closeCase(2, { id = d.id, resolution = 'Avslutat' })
        t.eq(C.addCaseSubject(2, { id = d.id, type = 'person', citizenid = 'RP503' }), { ok = false, error = 'validation', reason = 'case_closed' })
    end)
end

tests['cases 09 listCases: filters, query, notices never listed'] = function(t)
    H.with(t, function(_, env, mods)
        local C = cases(mods)
        local mine = seedCase(env, mods, 1, { title = 'Snatteri Ica' })
        local other = seedCase(env, mods, 2, { title = 'Utredning bedrägeri' })
        local secret = seedCase(env, mods, 3, { title = 'Hemlig spaning', level = 2 })
        C.assignCase(2, { id = other.id, citizenid = 'REC10006' })
        local function numbers(res)
            local out = {}
            for i, ref in ipairs(res.data.items) do out[i] = ref.caseNumber end
            table.sort(out)
            return out
        end
        t.eq(numbers(C.listCases(1, {})), { mine.caseNumber }, 'mine (default)')
        t.eq(numbers(C.listCases(6, { filter = 'mine' })), { other.caseNumber }, 'assigned counts as mine')
        t.eq(numbers(C.listCases(6, { filter = 'unit' })), { mine.caseNumber }, 'unit igv')
        t.eq(numbers(C.listCases(1, { filter = 'all' })), { mine.caseNumber }, 'all: notices dropped')
        t.eq(C.listCases(1, { filter = 'all' }).data.total, 1, 'total counts visible only')
        t.eq(#C.listCases(3, { filter = 'all' }).data.items, 3, 'records.admin sees all')
        t.eq(numbers(C.listCases(3, { filter = 'open', query = 'bedr' })), { other.caseNumber }, 'title query')
        t.eq(numbers(C.listCases(3, { filter = 'all', query = secret.caseNumber:lower() })), { secret.caseNumber }, 'number query')
        C.closeCase(3, { id = secret.id, resolution = 'Avslutad' })
        t.eq(numbers(C.listCases(3, { filter = 'closed' })), { secret.caseNumber })
        t.eq(C.listCases(1, { filter = 'nope' }), { ok = false, error = 'validation' })
        t.eq(C.listCases(1, { page = 0 }), { ok = false, error = 'validation' })
        local page2 = C.listCases(3, { filter = 'all', page = 2 }).data
        t.eq(page2.items, {})
        t.eq(page2.total, 3)
        for _, ref in ipairs(C.listCases(3, { filter = 'all' }).data.items) do H.checkRef(t, ref) end
    end)
end

tests['cases 10 golden CaseDetail full / masked / notice with reports, evidence and timeline'] = function(t)
    H.with(t, function(_, env, mods)
        local C = cases(mods)
        H.fewPeople()
        local id = H.case({ 'K-7-26', 'Rån på bensinstation', 'open', 0, 'utredning', 'REC10002', '2026-09-01 10:00:00',
            assignees = { 'REC10003' }, subjects = { { 'person', 'RP502', 'suspect' }, { 'vehicle', 'ABC123', 'other' } } })
        H.run(("UPDATE fredpd_cases SET summary = 'Beväpnat rån kl 02', created_at = '2026-09-01 08:00:00' WHERE id = %d;")
            :format(id))
        H.run(("UPDATE fredpd_case_assignees SET role = 'lead' WHERE case_id = %d;"):format(id))
        local r1 = H.report({ id, 1, 'K-7-26/1', 'Anmälan', 'Text', 0, 'REC10002', '2026-09-01 09:00:00' })
        local r2 = H.report({ id, 2, 'K-7-26/2', 'Spaningsrapport', 'Hemligt', 2, 'REC10003', '2026-09-02 09:00:00' })
        env.evidence[id] = { { id = 11, tag = 'B-K-7-26-001', type = 'casing', collectedAt = '2026-09-01T07:30:00Z' },
            { id = 12, type = 'dna' } }
        H.auditRow({ 'REC10002', 'case.create', 'case', tostring(id), { label = 'K-7-26' }, '2026-09-01 08:00:00' })
        H.auditRow({ 'REC10002', 'case.assign', 'case', tostring(id), { label = 'Lena Ledning' }, '2026-09-01 08:05:00' })
        H.auditRow({ 'REC10002', 'report.create', 'report', tostring(r1), { label = 'K-7-26/1' }, '2026-09-01 09:00:00' })
        H.auditRow({ 'REC10003', 'report.create', 'report', tostring(r2), { label = 'K-7-26/2' }, '2026-09-02 09:00:00' })
        H.auditRow({ 'REC10002', 'evidence.link', 'evidence', '11', { caseId = id, tag = 'B-K-7-26-001' }, '2026-09-02 10:00:00' })
        H.auditRow({ 'REC10001', 'lookup.person', 'person', 'RP502', { source = 'summary' }, '2026-09-02 11:00:00' })
        H.auditRow({ 'NOBODY99', 'case.update', 'case', tostring(id), { label = 'x\1y' }, '2026-09-02 12:00:00' })

        local full = C.getCase(2, { id = id }).data
        t.eq(full.visibility, 'full')
        t.eq(#full.timeline, 6, 'lookups excluded')
        t.eq(full.timeline[1].action, 'case.update', 'newest first')
        t.eq(full.timeline[1].actor, nil, 'unknown officer -> null')
        t.eq(full.timeline[1].detail, nil, 'unsafe label dropped')
        t.eq(full.timeline[2].detail, 'B-K-7-26-001', 'evidence tag')
        t.eq(#full.evidence, 1, 'untagged evidence skipped')
        -- the owner counts as assigned, so the level-2 report is not capped for them (§C3 cap 2)
        t.eq(full.reports[2].title, 'Spaningsrapport')
        t.eq(full.reports[1].title, 'Anmälan')
        H.golden(t, 'case.full', full)

        local notice = C.getCase(1, { id = id }).data
        t.eq(notice, { visibility = 'notice', contact = { displayName = 'Olle Utredare', unit = 'utredning' } })
        H.golden(t, 'case.notice', notice)

        H.run(("UPDATE fredpd_cases SET status = 'closed', closed_at = '2026-09-03 12:00:00' WHERE id = %d;"):format(id))
        local masked = C.getCase(1, { id = id }).data
        t.eq(masked.visibility, 'masked')
        t.eq(masked.title, 'Rån på bensinstation')
        t.eq(#masked.reports, 2)
        t.eq(masked.reports[2].title, nil, 'level-2 report title hidden in masked view')
        H.golden(t, 'case.masked', masked)
        local list = C.listCases(3, { filter = 'all' }).data
        H.golden(t, 'cases.list', list)
    end)
end

return tests
