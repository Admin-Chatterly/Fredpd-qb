-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_records Phase 5: reports (server/reports.lua): per-case numbering under concurrency, edit rights, level rules,
-- body sanitising and length cap, drafts, templates, report visibility; golden files for test/contract.test.ts.
local H = require('records_env_test')

local tests = {}

local function R(mods) return mods['server.reports'] end
local function Cs(mods) return mods['server.cases'] end

local function newCase(env, mods, owner, input)
    local r = Cs(mods).createCase(owner, input or { title = 'Stöld ur bil' })
    assert(r.ok, 'case')
    env.pushes, env.events = {}, {}
    return r.data
end

tests['reports 01 createReport numbers per case, uses templates, audits and pushes'] = function(t)
    H.with(t, function(_, env, mods)
        local c = newCase(env, mods, 2)
        local a = R(mods).createReport(2, { caseId = c.id, title = 'Anmälan om stöld', templateId = 1 })
        t.eq(a.ok, true)
        t.eq(a.data.reportNumber, c.caseNumber .. '/1')
        t.eq(a.data.caseNumber, c.caseNumber)
        t.ok(a.data.body:find('^# Anmälan'), 'template body')
        t.eq(a.data.editable, true)
        t.eq(a.data.charges, {})
        t.eq(a.data.author.displayName, 'Olle Utredare')
        local b = R(mods).createReport(2, { caseId = c.id, title = 'PM om stöld', level = 1 }).data
        t.eq(b.reportNumber, c.caseNumber .. '/2')
        t.eq(b.body, '')
        t.eq(b.level, 1)
        local other = newCase(env, mods, 2, { title = 'Annat ärende' })
        t.eq(R(mods).createReport(2, { caseId = other.id, title = 'Första' }).data.reportNumber, other.caseNumber .. '/1',
            'n restarts per case')
        t.eq(#env.named('report.create'), 3)
        t.eq(env.named('report.create')[1].meta.label, c.caseNumber .. '/1')
        t.eq(env.pushes[#env.pushes].payload.caseId, other.id)
        t.eq(R(mods).createReport(2, { caseId = c.id, title = 'Mall saknas', templateId = 999 }),
            { ok = false, error = 'validation', reason = 'template' })
    end)
end

tests['reports 02 createReport: access, level and closed-case rules'] = function(t)
    H.with(t, function(_, env, mods)
        local c = newCase(env, mods, 2)
        t.eq(R(mods).createReport(1, { caseId = c.id, title = 'Försök' }), { ok = false, error = 'unauthorized' },
            'kontaktnotis viewer cannot write')
        t.eq(R(mods).createReport(2, { caseId = c.id, title = 'Hemlig', level = 2 }),
            { ok = false, error = 'unauthorized', reason = 'level_above_tier' })
        t.eq(R(mods).createReport(2, { caseId = 9999, title = 'Inget ärende' }), { ok = false, error = 'not_found' })
        t.eq(R(mods).createReport(2, { caseId = c.id, title = 'x' }), { ok = false, error = 'validation' })
        t.eq(R(mods).createReport(2, { caseId = c.id, title = 'Mall', templateId = 0 }), { ok = false, error = 'validation' })
        Cs(mods).closeCase(2, { id = c.id, resolution = 'Avslutat' })
        t.eq(R(mods).createReport(2, { caseId = c.id, title = 'För sent' }), { ok = false, error = 'validation', reason = 'case_closed' })
    end)
end

tests['reports 03 report n stays unique when two officers create at once (interleaved; one retries)'] = function(t)
    H.with(t, function(_, env, mods)
        local c = newCase(env, mods, 2)
        Cs(mods).assignCase(2, { id = c.id, citizenid = 'REC10003' })
        local failedTx = 0
        env.onTransaction = function() end
        local results = H.interleave(env, {
            function() return R(mods).createReport(2, { caseId = c.id, title = 'Rapport A' }) end,
            function() return R(mods).createReport(3, { caseId = c.id, title = 'Rapport B' }) end,
        })
        local numbers = {}
        for i, r in ipairs(results) do
            t.eq(r.ok, true, 'report ' .. i)
            numbers[#numbers + 1] = r.data.reportNumber
        end
        table.sort(numbers)
        t.eq(numbers, { c.caseNumber .. '/1', c.caseNumber .. '/2' })
        -- both read n = 1 before either inserted, so exactly one batch hit uq_case_n and was retried
        local nextN = 0
        for _, s in ipairs(env.sql) do
            if s.sql == R(mods).NEXT_N_SQL then nextN = nextN + 1 end
        end
        t.eq(nextN, 3, 'one retry')
        t.eq(failedTx, 0)
    end)
end

tests['reports 04 saveReport: editors, level rules, body sanitising and cap, draft cleared'] = function(t)
    H.with(t, function(_, env, mods)
        local c = newCase(env, mods, 1, { title = 'Trafikolycka' })
        Cs(mods).assignCase(1, { id = c.id, citizenid = 'REC10006' })
        local rep = R(mods).createReport(1, { caseId = c.id, title = 'Olycksrapport' }).data
        -- member 6 is no author and no lead: may read, may not edit
        local asMember = R(mods).getReport(6, { id = rep.id })
        t.eq(asMember.ok, true)
        t.eq(asMember.data.editable, false)
        t.eq(R(mods).saveReport(6, { id = rep.id, title = 'Ändrad', body = 'x', level = 0 }), { ok = false, error = 'unauthorized' })
        t.eq(R(mods).saveReportDraft(6, { reportId = rep.id, body = 'x' }), { ok = false, error = 'unauthorized' })
        -- the author saves; control characters stripped, CRLF normalised, markdown kept as text
        R(mods).saveReportDraft(1, { reportId = rep.id, title = 'Utkast', body = 'halvfärdig' })
        t.eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM fredpd_report_drafts WHERE report_id = ?', { rep.id })), 1)
        local body = '# Rubrik\r\n**Fet** <b>html</b>\1\2\27[31m\n- punkt\tflik'
        local saved = R(mods).saveReport(1, { id = rep.id, title = 'Olycksrapport v2', body = body, level = 0 })
        t.eq(saved.ok, true)
        t.eq(saved.data.body, '# Rubrik\n**Fet** <b>html</b>[31m\n- punkt\tflik')
        t.eq(saved.data.title, 'Olycksrapport v2')
        t.eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM fredpd_report_drafts WHERE report_id = ?', { rep.id })), 0,
            'draft cleared on save')
        t.eq(#env.named('report.save'), 1)
        -- cap: 100 000 code points pass, one more fails (å = 2 bytes)
        t.eq(R(mods).saveReport(1, { id = rep.id, title = 'Lång', body = ('å'):rep(100000), level = 0 }).ok, true)
        t.eq(R(mods).saveReport(1, { id = rep.id, title = 'Lång', body = ('å'):rep(100001), level = 0 }), { ok = false, error = 'validation' })
        t.eq(R(mods).saveReport(1, { id = rep.id, title = 'Ogiltig', body = '\255\254', level = 0 }), { ok = false, error = 'validation' })
        -- level: never above tier, lowering needs records.admin
        t.eq(R(mods).saveReport(1, { id = rep.id, title = 'Nivå', body = 'x', level = 1 }),
            { ok = false, error = 'unauthorized', reason = 'level_above_tier' })
        t.eq(R(mods).saveReport(3, { id = rep.id, title = 'Nivå', body = 'x', level = 2 }).data.level, 2, 'admin raises')
        t.eq(R(mods).getReport(1, { id = rep.id }).data.editable, false, 'author tier 0 can no longer edit a level-2 report')
        t.eq(R(mods).saveReport(1, { id = rep.id, title = 'Nivå', body = 'x', level = 2 }), { ok = false, error = 'unauthorized' })
        -- the lead of the case (not author) may edit
        Cs(mods).assignCase(1, { id = c.id, citizenid = 'REC10002', role = 'lead' })
        t.eq(R(mods).saveReport(3, { id = rep.id, title = 'Nivå', body = 'x', level = 1 }).ok, true, 'admin lowers')
        t.eq(R(mods).saveReport(2, { id = rep.id, title = 'Av ansvarig', body = 'y', level = 1 }).ok, true, 'lead edits')
        t.eq(R(mods).saveReport(2, { id = rep.id, title = 'Sänk', body = 'y', level = 0 }),
            { ok = false, error = 'unauthorized', reason = 'lowering_needs_admin' })
        Cs(mods).closeCase(1, { id = c.id, resolution = 'Klart' })
        t.eq(R(mods).saveReport(2, { id = rep.id, title = 'Efter', body = 'z', level = 1 }), { ok = false, error = 'validation', reason = 'case_closed' })
        t.eq(R(mods).saveReportDraft(2, { reportId = rep.id, body = 'z' }), { ok = false, error = 'validation', reason = 'case_closed' })
    end)
end

tests['reports 05 drafts upsert without audit and return savedAt'] = function(t)
    H.with(t, function(_, env, mods)
        local c = newCase(env, mods, 2)
        local rep = R(mods).createReport(2, { caseId = c.id, title = 'Förhör' }).data
        local before = #env.audits
        local a = R(mods).saveReportDraft(2, { reportId = rep.id, body = 'första' })
        t.eq(a.ok, true)
        t.ok(a.data.savedAt:match(H.ISO), 'savedAt ISO')
        R(mods).saveReportDraft(2, { reportId = rep.id, title = 'Titel', body = 'andra' })
        local row = MySQL.single.await('SELECT COUNT(*) AS n, MAX(body) AS body, MAX(title) AS title FROM fredpd_report_drafts')
        t.eq(tonumber(row.n), 1, 'one draft per author and report')
        t.eq(row.body, 'andra')
        t.eq(row.title, 'Titel')
        t.eq(#env.audits, before, 'drafts are not audited (§C7)')
        t.eq(R(mods).saveReportDraft(2, { reportId = rep.id, title = 'a\nb', body = 'x' }), { ok = false, error = 'validation' })
        t.eq(R(mods).saveReportDraft(2, { reportId = rep.id }), { ok = false, error = 'validation' })
    end)
end

tests['reports 06 visibility: hidden -> not_found, capped -> notice, case page hides the title'] = function(t)
    H.with(t, function(_, env, mods)
        local c = newCase(env, mods, 1, { title = 'Patrullärende' })
        Cs(mods).assignCase(1, { id = c.id, citizenid = 'REC10003' })
        local secret = R(mods).createReport(3, { caseId = c.id, title = 'Källuppgifter', level = 2 }).data
        -- 6: IGV unit member, tier 0, not assigned -> the unit rule gives full, cap 2 makes it a kontaktnotis
        t.eq(R(mods).getReport(6, { id = secret.id }), { ok = false, error = 'unauthorized', reason = 'notice' })
        local asUnit = Cs(mods).getCase(6, { id = c.id }).data
        t.eq(asUnit.reports[1].reportNumber, secret.reportNumber)
        t.eq(asUnit.reports[1].title, nil, 'title hidden on the case page')
        -- the owner (assigned) reads it in full
        t.eq(R(mods).getReport(1, { id = secret.id }).data.title, 'Källuppgifter')
        env.visOverride['report:' .. secret.id] = 'none'
        t.eq(R(mods).getReport(3, { id = secret.id }), { ok = false, error = 'not_found' })
        t.eq(#Cs(mods).getCase(3, { id = c.id }).data.reports, 0, 'hidden report not listed')
        t.eq(R(mods).getReport(3, { id = 424242 }), { ok = false, error = 'not_found' })
    end)
end

tests['reports 07 templates (unit filtered) and golden ReportDetail'] = function(t)
    H.with(t, function(_, env, mods)
        H.run("INSERT INTO fredpd_report_templates (name, unit, body) VALUES ('Spaningslogg', 'span', 'x'), "
            .. "('IGV-rapport', 'igv', '# IGV');")
        local list = R(mods).listReportTemplates(1, {}).data.items
        local names = {}
        for i, tpl in ipairs(list) do names[i] = tpl.name end
        t.eq(names, { 'Anmälan', 'Beslagsprotokoll', 'Förhör', 'PM', 'IGV-rapport' }, 'shared first, own unit, not span')
        t.eq(R(mods).listReportTemplates(1, { x = 1 }), { ok = false, error = 'validation' })
        t.eq(R(mods).listReportTemplates(4, {}), { ok = false, error = 'unauthorized' })
        local igv
        for _, tpl in ipairs(list) do if tpl.name == 'IGV-rapport' then igv = tpl.id end end
        t.eq(R(mods).createReport(2, { caseId = newCase(env, mods, 2).id, title = 'Fel enhet', templateId = igv }),
            { ok = false, error = 'validation', reason = 'template' })
        H.run("DELETE FROM fredpd_report_templates WHERE id > 99;")
        H.golden(t, 'templates.list', { items = { list[4] } })

        H.fewPeople()
        local id = H.case({ 'K-9-26', 'Rattfylleri', 'open', 0, 'igv', 'REC10001', '2026-09-01 10:00:00' })
        local rid = H.report({ id, 1, 'K-9-26/1', 'Rapport ringa misshandel', '# Händelse\n- Blåste 0,8 promille', 0, 'REC10001',
            '2026-09-05 20:00:00' })
        H.insert('fredpd_records', { 'citizenid', 'case_id', 'report_id', 'charge_code', 'title_sv', 'class', 'quantity',
            'fine', 'jail_min', 'status', 'issued_by' }, { { 'RP502', id, rid, 'BRB-004', 'Ringa misshandel', 'bot', 1, 6000, 0,
            'issued', 'REC10001' } })
        local detail = R(mods).getReport(1, { id = rid }).data
        t.eq(detail.charges[1].personName, 'Omar Nilsson')
        H.golden(t, 'report.detail', detail)
    end)
end

return tests
