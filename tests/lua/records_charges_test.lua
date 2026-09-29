-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_records Phase 5: Brottskatalog and sanctions (server/charges.lua): catalogue read, applyCharges totals and
-- snapshots, subject auto-add, prison adapter, issueFine class/distance/bucket/funds/billing checks; golden files.
local H = require('records_env_test')

local tests = {}

local function Ch(mods) return mods['server.charges'] end
local function Cs(mods) return mods['server.cases'] end
local function R(mods) return mods['server.reports'] end

--- Case owned by 1 (IGV) with one report; people seeded.
local function setup(env, mods)
    H.fewPeople()
    local c = Cs(mods).createCase(1, { title = 'Bråk utanför krogen' }).data
    local rep = R(mods).createReport(1, { caseId = c.id, title = 'Rapport bråk' }).data
    env.pushes, env.events, env.audits = {}, {}, {}
    return c, rep
end

tests['charges 01 listCharges: active catalogue, query on code/title/law, class filter'] = function(t)
    H.with(t, function(_, _env, mods)
        local all = Ch(mods).listCharges(1, {}).data.items
        t.ok(#all >= 100, 'seeded catalogue (' .. #all .. ')')
        local q = Ch(mods).listCharges(1, { query = 'misshandel' }).data.items
        t.ok(#q >= 3, 'title query')
        for _, ch in ipairs(q) do t.ok(ch.title:lower():find('misshandel', 1, true) ~= nil, ch.title) end
        t.eq(Ch(mods).listCharges(1, { query = 'BRB-004' }).data.items[1].title, 'Ringa misshandel', 'code query')
        local fines = Ch(mods).listCharges(1, { class = 'ordningsbot' }).data.items
        for _, ch in ipairs(fines) do t.eq(ch.class, 'ordningsbot') end
        H.run("UPDATE fredpd_charges SET active = 0 WHERE code = 'BRB-004';")
        t.eq(#Ch(mods).listCharges(1, { query = 'BRB-004' }).data.items, 0, 'retired charge hidden')
        H.run("UPDATE fredpd_charges SET active = 1 WHERE code = 'BRB-004';")
        t.eq(Ch(mods).listCharges(1, { class = 'böter' }), { ok = false, error = 'validation' })
        t.eq(Ch(mods).listCharges(1, { query = ('x'):rep(65) }), { ok = false, error = 'validation' })
        t.eq(Ch(mods).listCharges(4, {}), { ok = false, error = 'unauthorized' }, 'no tablet grant')
        t.eq(#Ch(mods).listCharges(1, { query = '100%_' }).data.items, 0, 'LIKE wildcards escaped')
        H.golden(t, 'charges.list', Ch(mods).listCharges(1, { query = 'Hastighetsöverträdelse 1' }).data)
    end)
end

tests['charges 02 applyCharges: snapshots, totals, subject added as suspect, audit and push'] = function(t)
    H.with(t, function(_, env, mods)
        local c, rep = setup(env, mods)
        local res = Ch(mods).applyCharges(1, { reportId = rep.id, citizenid = 'RP502', note = '  Erkänner  ',
            lines = { { code = 'BRB-005', quantity = 2 }, { code = 'BRB-004' }, { code = 'BRB-046', quantity = 1 } } })
        t.eq(res.ok, true)
        local d = res.data
        t.eq(#d.records, 3)
        t.eq(d.records[1].code, 'BRB-005')
        t.eq(d.records[1].quantity, 2)
        t.eq(d.records[1].fine, 10000, 'fine x quantity')
        t.eq(d.records[1].jailMinutes, 20, 'jail x quantity')
        t.eq(d.records[1].class, 'fängelse')
        t.eq(d.records[1].personName, 'Omar Nilsson')
        t.eq(d.records[1].status, 'issued')
        t.eq(d.totals, { fine = 10000 + 4000 + 1500, jailMinutes = 20 })
        local subject = MySQL.single.await("SELECT role FROM fredpd_case_subjects WHERE case_id = ? AND subject_id = 'RP502'", { c.id })
        t.eq(subject.role, 'suspect', 'added as suspect')
        t.eq(MySQL.scalar.await('SELECT note FROM fredpd_records WHERE id = ?', { d.records[1].id }), 'Erkänner')
        -- snapshots survive catalogue edits
        H.run("UPDATE fredpd_charges SET fine = 99999, title_sv = 'Ändrad' WHERE code = 'BRB-004';")
        local detail = R(mods).getReport(1, { id = rep.id }).data
        t.eq(detail.charges[2].fine, 4000)
        t.eq(detail.charges[2].title, 'Ringa misshandel')
        H.run("UPDATE fredpd_charges SET fine = 4000, title_sv = 'Ringa misshandel' WHERE code = 'BRB-004';")
        local a = env.named('charges.apply')[1]
        t.eq(a.targetType, 'report')
        t.eq(a.meta.codes, { 'BRB-005', 'BRB-004', 'BRB-046' })
        t.eq(a.meta.subjectAdded, true)
        t.eq(#env.pushes, 1)
        -- a subject with a role keeps it
        Cs(mods).addCaseSubject(1, { id = c.id, type = 'person', citizenid = 'RP503', role = 'victim' })
        Ch(mods).applyCharges(1, { reportId = rep.id, citizenid = 'RP503', lines = { { code = 'BRB-046' } } })
        t.eq(MySQL.scalar.await("SELECT role FROM fredpd_case_subjects WHERE case_id = ? AND subject_id = 'RP503'", { c.id }), 'victim')
        H.run("UPDATE fredpd_records SET created_at = '2026-09-06 12:00:00', updated_at = '2026-09-06 12:00:00';")
        H.golden(t, 'charges.applied', res.data)
    end)
end

tests['charges 03 applyCharges refusals: validation, unknown code, person, editability'] = function(t)
    H.with(t, function(_, env, mods)
        local c, rep = setup(env, mods)
        local function apply(src, input) return Ch(mods).applyCharges(src, input) end
        t.eq(apply(1, { reportId = rep.id, citizenid = 'RP502', lines = {} }), { ok = false, error = 'validation' })
        t.eq(apply(1, { reportId = rep.id, citizenid = 'RP502', lines = { { code = 'BRB-004', quantity = 21 } } }),
            { ok = false, error = 'validation' })
        t.eq(apply(1, { reportId = rep.id, citizenid = 'RP502', lines = { { code = '' } } }), { ok = false, error = 'validation' })
        local many = {}
        for i = 1, 31 do many[i] = { code = 'BRB-004' } end
        t.eq(apply(1, { reportId = rep.id, citizenid = 'RP502', lines = many }), { ok = false, error = 'validation' })
        t.eq(apply(1, { reportId = rep.id, citizenid = 'RP502', lines = { { code = 'NOPE-1' } } }),
            { ok = false, error = 'validation', reason = 'unknown_charge' })
        t.eq(apply(1, { reportId = rep.id, citizenid = 'NOBODY', lines = { { code = 'BRB-004' } } }),
            { ok = false, error = 'not_found', reason = 'person' })
        t.eq(apply(6, { reportId = rep.id, citizenid = 'RP502', lines = { { code = 'BRB-004' } } }), { ok = false, error = 'unauthorized' },
            'unit member who is no author/lead')
        t.eq(apply(2, { reportId = rep.id, citizenid = 'RP502', lines = { { code = 'BRB-004' } } }),
            { ok = false, error = 'unauthorized', reason = 'notice' }, 'kontaktnotis viewer')
        env.players[6].grants = { 'mdt_page:cases' }
        t.eq(apply(6, { reportId = rep.id, citizenid = 'RP502', lines = { { code = 'BRB-004' } } }), { ok = false, error = 'unauthorized' },
            'no charges.apply grant')
        Cs(mods).closeCase(1, { id = c.id, resolution = 'Avslutat' })
        t.eq(apply(1, { reportId = rep.id, citizenid = 'RP502', lines = { { code = 'BRB-004' } } }),
            { ok = false, error = 'validation', reason = 'case_closed' })
        t.eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM fredpd_records')), 0, 'nothing written')
    end)
end

tests['charges 04 applyCharges sends prison time to the adapter only for a person in custody (<= 5 m)'] = function(t)
    H.with(t, function(_, env, mods)
        local _, rep = setup(env, mods)
        env.players[7] = { cid = 'RP502', tier = 0, units = {}, grants = {} }
        env.coords[1] = { 0, 0, 0 }
        env.coords[7] = { 30, 0, 0 }
        Ch(mods).applyCharges(1, { reportId = rep.id, citizenid = 'RP502', lines = { { code = 'BRB-005' } } })
        t.eq(#env.jails, 0, 'far away: nobody jailed')
        t.eq(env.named('charges.apply')[1].meta.jailed, nil)
        env.coords[7] = { 3, 0, 0 }
        Ch(mods).applyCharges(1, { reportId = rep.id, citizenid = 'RP502', lines = { { code = 'BRB-005', quantity = 3 } } })
        t.eq(#env.jails, 1)
        t.eq(env.jails[1].target, 7)
        t.eq(env.jails[1].minutes, 30)
        t.eq(env.jails[1].charges, { { code = 'BRB-005', label = 'Misshandel' } })
        t.eq(env.named('charges.apply')[2].meta.jailed, false, 'adapter "none" returns false; recorded')
        env.jailResult = true
        Ch(mods).applyCharges(1, { reportId = rep.id, citizenid = 'RP502', lines = { { code = 'BRB-006' } } })
        t.eq(env.named('charges.apply')[3].meta.jailed, true)
        Ch(mods).applyCharges(1, { reportId = rep.id, citizenid = 'RP502', lines = { { code = 'BRB-004' } } })
        t.eq(#env.jails, 2, 'no jail time -> adapter not called')
    end)
end

tests['charges 05 issueFine: ordningsbot only, online, same bucket, within 5 m, funds, billing and records'] = function(t)
    H.with(t, function(_, env, mods)
        H.fewPeople()
        local function fine(src, input)
            env.gameTimer = env.gameTimer + 5000 -- past the per-officer cooldown
            return Ch(mods).issueFine(src, input)
        end
        local speeding = { { code = 'TRF-010' }, { code = 'BRB-046', quantity = 2 } } -- 2000 + 2 x 1500
        t.eq(fine(1, { citizenid = 'RP501', lines = { { code = 'BRB-004' } } }), { ok = false, error = 'validation', reason = 'not_ordningsbot' })
        t.eq(fine(1, { citizenid = 'RP501', lines = { { code = 'BRB-005' } } }), { ok = false, error = 'validation', reason = 'not_ordningsbot' })
        t.eq(fine(1, { citizenid = 'RP501', lines = speeding }), { ok = false, error = 'not_found', reason = 'target_offline' })
        env.players[7] = { cid = 'RP501', tier = 0, units = {}, grants = {} }
        env.coords[1] = { 100, 100, 30 }
        env.coords[7] = { 104, 103, 30 } -- 5.0 m
        env.buckets[7] = 3
        t.eq(fine(1, { citizenid = 'RP501', lines = speeding }), { ok = false, error = 'validation', reason = 'target_too_far' },
            'other routing bucket')
        env.buckets[7] = 0
        env.coords[7] = { 104, 103.1, 30 }
        t.eq(fine(1, { citizenid = 'RP501', lines = speeding }), { ok = false, error = 'validation', reason = 'target_too_far' }, '> 5 m')
        env.coords[7] = { 104, 103, 30 }
        env.bank.RP501 = 4999
        t.eq(fine(1, { citizenid = 'RP501', lines = speeding }), { ok = false, error = 'validation', reason = 'insufficient_funds' })
        t.eq(env.bank.RP501, 4999)
        t.eq(fine(6, { citizenid = 'RP501', lines = speeding }), { ok = false, error = 'unauthorized' }, 'no charges.fine grant')
        t.eq(fine(1, { citizenid = 'REC10001', lines = speeding }), { ok = false, error = 'validation', reason = 'self' })
        env.bank.RP501 = 10000
        local ok = fine(1, { citizenid = 'RP501', lines = speeding })
        t.eq(ok.ok, true)
        t.eq(ok.data.totals, { fine = 5000, jailMinutes = 0 })
        t.eq(#ok.data.records, 2)
        t.eq(ok.data.records[1].status, 'paid')
        t.eq(env.bank.RP501, 5000, 'bank debited')
        t.eq(env.deposits, { { account = 'police', amount = 5000 } }, 'society credited')
        t.eq(env.notifies[#env.notifies].target, 7)
        t.ok(env.notifies[#env.notifies].data.description:find('charge.ordningsbot.received', 1, true) == 1, 'target notified via L()')
        t.ok(env.notifies[#env.notifies].data.description:find('5 000 kr', 1, true) ~= nil, 'amount formatted')
        local audit = env.named('fine.issue')[1]
        t.eq(audit.targetType, 'person')
        t.eq(audit.meta.amount, 5000)
        t.eq(tonumber(MySQL.scalar.await("SELECT COUNT(*) FROM fredpd_records WHERE citizenid = 'RP501' AND status = 'paid' "
            .. 'AND report_id IS NULL')), 2)
        -- cooldown: a second fine straight away is rate limited
        t.eq(Ch(mods).issueFine(1, { citizenid = 'RP501', lines = speeding }), { ok = false, error = 'rate_limited' })
        -- a failed society deposit refunds the player
        env.depositFails = true
        t.eq(fine(1, { citizenid = 'RP501', lines = speeding }), { ok = false, error = 'validation', reason = 'payment_failed' })
        t.eq(env.bank.RP501, 5000, 'refunded')
        env.depositFails = false
        -- linked to a case the officer can see in full: audited on the case (timeline) and pushed
        local c = Cs(mods).createCase(1, { title = 'Ordningsstörning' }).data
        local withCase = fine(1, { citizenid = 'RP501', caseId = c.id, lines = { { code = 'BRB-046' } } })
        t.eq(withCase.ok, true)
        t.eq(env.named('fine.issue')[2].targetType, 'case')
        t.eq(tonumber(MySQL.scalar.await('SELECT case_id FROM fredpd_records WHERE id = ?', { withCase.data.records[1].id })), c.id)
        local hidden = Cs(mods).createCase(2, { title = 'Annans ärende' }).data
        t.eq(fine(1, { citizenid = 'RP501', caseId = hidden.id, lines = { { code = 'BRB-046' } } }), { ok = false, error = 'unauthorized' })
    end)
end

return tests
