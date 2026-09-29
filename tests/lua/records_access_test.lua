-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_records Phase 5: POI sheets, share links (token hashing, expiry, view logging, max level), release requests
-- (masked export: no Begränsad/Hemlig text, §5.3 acceptance), obehörig sökning, intel notices on the person page.
local H = require('records_env_test')
local Sha256 = require('shared.sha256')

local tests = {}

local function Cs(mods) return mods['server.cases'] end
local function R(mods) return mods['server.reports'] end
local function P(mods) return mods['server.poi'] end
local function S(mods) return mods['server.shares'] end
local function Rel(mods) return mods['server.releases'] end

tests['access 01 POI: create, canView shapes, edit rights, level rules'] = function(t)
    H.with(t, function(_, _env, mods)
        H.fewPeople()
        local empty = P(mods).getPoi(1, { citizenid = 'RP502' })
        t.eq(empty, { ok = true, data = { citizenid = 'RP502', name = 'Omar Nilsson' } }, 'no sheet yet (poi absent = null)')
        t.eq(P(mods).getPoi(1, { citizenid = 'NOBODY' }), { ok = false, error = 'not_found' })
        local created = P(mods).updatePoi(2, { citizenid = 'RP502', summary = 'Känd för rån', warnings = { 'armed', 'armed', 'gang' },
            level = 1 }).data
        t.eq(created.poi.visibility, 'full')
        t.eq(created.poi.warnings, { 'armed', 'gang' })
        t.eq(created.poi.unit, 'utredning')
        t.eq(created.poi.owner.displayName, 'Olle Utredare')
        t.eq(created.poi.editable, true)
        -- tier 0 IGV: level 1 sheet, not owner/unit -> kontaktnotis
        local igv = P(mods).getPoi(1, { citizenid = 'RP502' }).data.poi
        t.eq(igv, { visibility = 'notice', contact = { displayName = 'Olle Utredare', unit = 'utredning' } })
        H.golden(t, 'poi.notice', P(mods).getPoi(1, { citizenid = 'RP502' }).data)
        t.eq(P(mods).updatePoi(1, { citizenid = 'RP502', summary = 'x' }), { ok = false, error = 'unauthorized' })
        t.eq(P(mods).updatePoi(2, { citizenid = 'RP502', level = 2 }), { ok = false, error = 'unauthorized', reason = 'level_above_tier' })
        t.eq(P(mods).updatePoi(2, { citizenid = 'RP502', level = 0 }), { ok = false, error = 'unauthorized', reason = 'lowering_needs_admin' })
        t.eq(P(mods).updatePoi(3, { citizenid = 'RP502', level = 0 }).data.poi.level, 0, 'admin lowers')
        -- level 0: tier_gte -> full for everyone; not editable for another unit
        local open = P(mods).getPoi(1, { citizenid = 'RP502' }).data.poi
        t.eq(open.visibility, 'full')
        t.eq(open.editable, false)
        t.eq(P(mods).updatePoi(2, { citizenid = 'RP502', warnings = { 'bomb' } }), { ok = false, error = 'validation' })
        t.eq(P(mods).updatePoi(2, { citizenid = 'RP502', photoUrl = 'javascript:alert(1)' }), { ok = false, error = 'validation' })
        t.eq(P(mods).updatePoi(2, { citizenid = 'RP502', photoUrl = '/uploads/abc-123.webp' }).data.poi.photoUrl, '/uploads/abc-123.webp')
        t.eq(#_env.named('poi.create'), 1)
        t.eq(#_env.named('poi.update'), 2)
        H.run("UPDATE fredpd_poi SET updated_at = '2026-09-10 10:00:00';")
        H.golden(t, 'poi.full', P(mods).getPoi(2, { citizenid = 'RP502' }).data)
    end)
end

tests['access 02 shares: 32-byte token, only its sha256 stored, mandatory expiry, every view logged'] = function(t)
    H.with(t, function(_, env, mods)
        local c = Cs(mods).createCase(2, { title = 'Delat ärende', summary = 'Sammanfattning' }).data
        R(mods).createReport(2, { caseId = c.id, title = 'Öppen rapport' })
        R(mods).createReport(2, { caseId = c.id, title = 'Begränsad rapport', level = 1 })
        t.eq(S(mods).createShare(2, { targetType = 'case', targetId = c.id }), { ok = false, error = 'validation' }, 'expiry mandatory')
        t.eq(S(mods).createShare(2, { targetType = 'case', targetId = c.id, expiresInHours = 0 }), { ok = false, error = 'validation' })
        t.eq(S(mods).createShare(2, { targetType = 'case', targetId = c.id, expiresInHours = 169 }), { ok = false, error = 'validation' })
        t.eq(S(mods).createShare(2, { targetType = 'bolo', targetId = c.id, expiresInHours = 1 }), { ok = false, error = 'validation' })
        t.eq(S(mods).createShare(1, { targetType = 'case', targetId = c.id, expiresInHours = 1 }), { ok = false, error = 'unauthorized' },
            'kontaktnotis viewer cannot share')
        local res = S(mods).createShare(2, { targetType = 'case', targetId = c.id, expiresInHours = 24 })
        t.eq(res.ok, true)
        local token = res.data.token
        t.eq(#token, 43, '32 bytes base64url')
        t.ok(token:match('^[%w_%-]+$') ~= nil, 'base64url alphabet')
        t.eq(res.data.path, '/share/' .. token)
        t.eq(res.data.maxLevel, 1)
        local row = MySQL.single.await('SELECT token_hash, TIMESTAMPDIFF(MINUTE, UTC_TIMESTAMP(), expires_at) AS mins, max_level '
            .. 'FROM fredpd_shares WHERE id = ?', { res.data.id })
        t.eq(row.token_hash, Sha256.hex(token), 'sha256 hex stored')
        t.ok(tonumber(row.mins) >= 1438 and tonumber(row.mins) <= 1440, 'expires in 24 h (UTC)')
        t.eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM fredpd_shares WHERE token_hash = ?', { token })), 0,
            'token itself never stored')
        local audit = env.named('share.create')[1]
        t.ok(not json.encode(audit.meta):find(token, 1, true), 'token not audited')
        t.eq(audit.targetType, 'case')
        local second = S(mods).createShare(3, { targetType = 'case', targetId = c.id, expiresInHours = 1 }).data.token
        t.ok(second ~= token, 'fresh token per share')

        local view = S(mods).viewShare(token)
        t.eq(view.ok, true)
        t.eq(view.data.targetType, 'case')
        t.eq(view.data.content.title, 'Delat ärende')
        t.eq(#view.data.content.reports, 2, 'creator tier 1: both reports')
        S(mods).viewShare(token)
        t.eq(tonumber(MySQL.scalar.await('SELECT view_count FROM fredpd_shares WHERE id = ?', { res.data.id })), 2)
        t.eq(#env.named('share.view'), 2, 'every view audited')
        t.eq(S(mods).viewShare(token:sub(1, 42) .. (token:sub(43) == 'A' and 'B' or 'A')), { ok = false, error = 'not_found' })
        t.eq(S(mods).viewShare('short'), { ok = false, error = 'not_found' })
        env.invoking = 'some_other_resource'
        t.eq(S(mods).viewShare(token), { ok = false, error = 'unauthorized' })
        env.invoking = 'fredpd_core'
        t.eq(S(mods).viewShare(token).ok, true)
        H.run(('UPDATE fredpd_shares SET expires_at = UTC_TIMESTAMP() - INTERVAL 1 SECOND WHERE id = %d;'):format(res.data.id))
        t.eq(S(mods).viewShare(token), { ok = false, error = 'not_found' }, 'expired')
        t.eq(S(mods).revokeShare(1, { id = res.data.id + 1 }), { ok = false, error = 'not_found' }, 'not the creator')
        t.eq(S(mods).revokeShare(3, { id = res.data.id + 1 }).ok, true)
        t.eq(S(mods).viewShare(second), { ok = false, error = 'not_found' }, 'revoked')
        env.tokenFails = true
        env.gameTimer = 1e6
        t.eq(S(mods).createShare(2, { targetType = 'case', targetId = c.id, expiresInHours = 1 }), { ok = false, error = 'unavailable' },
            'no CSPRNG -> no share (never math.random)')
    end)
end

tests['access 03 shares never show more than the creator tier (assignment does not travel)'] = function(t)
    H.with(t, function(_, env, mods)
        H.fewPeople()
        local c = Cs(mods).createCase(3, { title = 'Hemligt ärende', level = 1 }).data
        Cs(mods).assignCase(3, { id = c.id, citizenid = 'REC10001' })
        t.eq(Cs(mods).getCase(1, { id = c.id }).data.visibility, 'full', 'assigned tier 0 reads it')
        local share = S(mods).createShare(1, { targetType = 'case', targetId = c.id, expiresInHours = 2 }).data
        t.eq(share.maxLevel, 0)
        local view = S(mods).viewShare(share.token).data
        t.eq(view.content, nil, 'level-1 case withheld from a max-level-0 link')
        -- POI share
        P(mods).updatePoi(2, { citizenid = 'RP501', summary = 'Farlig', warnings = { 'violent' } })
        local poiShare = S(mods).createShare(2, { targetType = 'poi', targetId = 'RP501', expiresInHours = 168 }).data
        local poiView = S(mods).viewShare(poiShare.token).data
        t.eq(poiView.content.name, 'Sara Svensson')
        t.eq(poiView.content.warnings, { 'violent' })
        t.eq(poiView.content.type, 'poi')
        env.gameTimer = 1e6
        t.eq(S(mods).createShare(2, { targetType = 'poi', targetId = 'RP504', expiresInHours = 1 }), { ok = false, error = 'not_found' })
    end)
end

--- Closed level-0 case with a level-0, a level-1 and a level-2 report carrying marker texts.
local function releasable(env, mods)
    H.fewPeople()
    local c = Cs(mods).createCase(3, { title = 'Skadegörelse på skola', summary = 'Klotter på fasaden' }).data
    Cs(mods).addCaseSubject(3, { id = c.id, type = 'person', citizenid = 'RP502', role = 'suspect' })
    local r0 = R(mods).createReport(3, { caseId = c.id, title = 'Anmälan skadegörelse' }).data
    R(mods).saveReport(3, { id = r0.id, title = 'Anmälan skadegörelse', body = 'OFFENTLIG_TEXT om klotter', level = 0 })
    local r1 = R(mods).createReport(3, { caseId = c.id, title = 'BEGRANSAD_TITEL', level = 1 }).data
    R(mods).saveReport(3, { id = r1.id, title = 'BEGRANSAD_TITEL', body = 'BEGRANSAD_TEXT uppgiftslämnare', level = 1 })
    local r2 = R(mods).createReport(3, { caseId = c.id, title = 'HEMLIG_TITEL', level = 2 }).data
    R(mods).saveReport(3, { id = r2.id, title = 'HEMLIG_TITEL', body = 'HEMLIG_TEXT källa', level = 2 })
    Cs(mods).closeCase(3, { id = c.id, resolution = 'Avslutat utan misstänkt' })
    env.gameTimer = env.gameTimer + 120000
    return c, r0, r1, r2
end

tests['access 04 §5.3 acceptance: a released case carries no Begränsad/Hemlig text and no source fields'] = function(t)
    H.with(t, function(_, env, mods)
        local c = releasable(env, mods)
        -- station request by a civilian (player 4 has a character but no grants)
        local req = Rel(mods).createReleaseRequest(4, { description = 'Jag vill ta del av ärendet om klottret', reference = c.caseNumber:lower() })
        t.eq(req.ok, true)
        t.eq(env.notifies[#env.notifies].data.description, 'release.submitted', 'requester told via L()')
        t.eq(env.pushes[#env.pushes].targets, { 3 }, 'queue pushed to records.admin only')
        t.eq(Rel(mods).createReleaseRequest(4, { description = 'Igen direkt' }), { ok = false, error = 'rate_limited' })
        t.eq(Rel(mods).decideReleaseRequest(2, { id = req.data.id, decision = 'approved' }), { ok = false, error = 'unauthorized' })
        local decided = Rel(mods).decideReleaseRequest(3, { id = req.data.id, decision = 'partial', note = 'Maskerat enligt OSL' })
        t.eq(decided.ok, true)
        local d = decided.data
        t.eq(d.status, 'partial')
        t.eq(d.target, { type = 'case', id = tostring(c.id), label = c.caseNumber })
        t.eq(d.decidedBy.displayName, 'Lena Ledning')
        local stored = MySQL.scalar.await('SELECT released_body FROM fredpd_release_requests WHERE id = ?', { req.data.id })
        t.ok(stored:find('OFFENTLIG_TEXT', 1, true) ~= nil, 'level-0 text released')
        for _, secret in ipairs({ 'BEGRANSAD', 'HEMLIG', 'uppgiftslämnare', 'källa' }) do
            t.ok(stored:find(secret, 1, true) == nil, 'no ' .. secret .. ' in the release')
        end
        for _, field in ipairs({ 'REC100', 'RP502', 'Omar', 'author', 'subjects', 'evidence', 'Avslutat utan misstänkt' }) do
            t.ok(stored:find(field, 1, true) == nil, 'no source field ' .. field)
        end
        t.eq(#d.released.reports, 1)
        t.eq(d.released.title, 'Skadegörelse på skola')
        t.eq(Rel(mods).decideReleaseRequest(3, { id = req.data.id, decision = 'denied' }),
            { ok = false, error = 'validation', reason = 'already_decided' })
        t.eq(#env.named('release.create'), 1)
        t.eq(#env.named('release.decide'), 1)
        H.run("UPDATE fredpd_release_requests SET created_at = '2026-09-11 10:00:00', decided_at = '2026-09-11 12:00:00';")
        -- fixed numbers and times for the golden file (case numbers carry the current year)
        H.run("UPDATE fredpd_cases SET case_number = 'K-1-26', created_at = '2026-09-01 10:00:00', "
            .. "closed_at = '2026-09-02 10:00:00';")
        H.run("UPDATE fredpd_reports SET report_number = CONCAT('K-1-26/', n);")
        local again = Rel(mods).load(req.data.id)
        again.released = mods['server.export'].release('case', c.id)
        again.released.reports[1].createdAt = '2026-09-01T11:00:00Z'
        H.golden(t, 'release.decided', again)
    end)
end

tests['access 05 release: open, Begränsad and unknown targets are not releasable; single reports; portal path'] = function(t)
    H.with(t, function(_, env, mods)
        local c, r0, r1 = releasable(env, mods)
        local E = mods['server.export']
        t.eq(E.release('report', r1.id), nil, 'level-1 report withheld')
        t.eq(E.release('report', r0.id).body, 'OFFENTLIG_TEXT om klotter')
        local open = Cs(mods).createCase(3, { title = 'Pågående förundersökning' }).data
        t.eq(E.release('case', open.id), nil, 'open case: public viewer gets only a kontaktnotis')
        local restricted = Cs(mods).createCase(3, { title = 'Begränsat', level = 1 }).data
        Cs(mods).closeCase(3, { id = restricted.id, resolution = 'Avslutat' })
        t.eq(E.release('case', restricted.id), nil, 'closed level-1 case withheld')
        t.eq(E.release('case', 99999), nil)
        env.invoking = 'fredpd_core'
        local portal = Rel(mods).createReleaseRequestPortal({ discordId = '123456789012345678', name = 'Kalle Anka',
            description = 'Begär ut beslut', reference = 'okänt' })
        t.eq(portal.ok, true)
        t.eq(Rel(mods).decideReleaseRequest(3, { id = portal.data.id, decision = 'approved' }),
            { ok = false, error = 'validation', reason = 'no_target' })
        t.eq(Rel(mods).decideReleaseRequest(3, { id = portal.data.id, decision = 'approved', targetType = 'case', targetId = open.id }),
            { ok = false, error = 'validation', reason = 'nothing_releasable' })
        local ok = Rel(mods).decideReleaseRequest(3, { id = portal.data.id, decision = 'approved', targetType = 'report', targetId = r0.id })
        t.eq(ok.data.status, 'approved')
        t.eq(ok.data.released.reportNumber, r0.reportNumber)
        t.eq(ok.data.channel, 'portal')
        env.invoking = 'evil_resource'
        t.eq(Rel(mods).createReleaseRequestPortal({ discordId = '1', name = 'X', description = 'abc' }), { ok = false, error = 'unauthorized' })
        env.invoking = nil
        t.eq(Rel(mods).createReleaseRequestPortal({ discordId = 'abc', description = 'abc' }), { ok = false, error = 'validation' })
        local denied = Rel(mods).createReleaseRequest(1, { description = 'Något annat' })
        t.eq(Rel(mods).decideReleaseRequest(3, { id = denied.data.id, decision = 'denied', note = 'Sekretess' }).data.status, 'denied')
        local list = Rel(mods).listReleaseRequests(3, {}).data
        t.eq(list.total, 2)
        t.eq(Rel(mods).listReleaseRequests(3, { status = 'pending' }).data.total, 0)
        t.eq(Rel(mods).listReleaseRequests(1, {}), { ok = false, error = 'unauthorized' })
        t.eq(Rel(mods).createReleaseRequest(5, { description = 'Utan karaktär' }), { ok = false, error = 'unauthorized' })
        t.eq(Rel(mods).createReleaseRequest(2, { description = 'x' }), { ok = false, error = 'validation' })
        _ = c
    end)
end

tests['access 06 obehörig sökning: unlinked lookups reach the threshold -> lookup.flag + Ledning told once'] = function(t)
    H.with(t, function(_, env, mods)
        env.auditDb = true
        H.fewPeople()
        local Summary = mods['server.summary']
        -- RP501 is a subject of a case 1 owns: linked, never counted
        local c = Cs(mods).createCase(1, { title = 'Eget ärende' }).data
        Cs(mods).addCaseSubject(1, { id = c.id, type = 'person', citizenid = 'RP501' })
        env.notifies, env.pushes = {}, {}
        Summary.person(1, { citizenid = 'RP501' })
        Summary.person(1, { citizenid = 'RP502' })
        Summary.person(1, { citizenid = 'RP502' }) -- same person again: still one
        t.eq(#env.named('lookup.flag'), 0, 'two unlinked persons < 3')
        Summary.person(1, { citizenid = 'RP503' })
        t.eq(#env.named('lookup.flag'), 0, 'still two')
        Summary.person(1, { citizenid = 'RP504' })
        local flags = env.named('lookup.flag')
        t.eq(#flags, 1, 'third unlinked person flags')
        t.eq(flags[1].targetType, 'officer')
        t.eq(flags[1].targetId, 'REC10001')
        t.eq(flags[1].meta.count, 3)
        t.eq(flags[1].meta.persons, { 'RP502', 'RP503', 'RP504' })
        t.eq(#env.notifies, 1, 'one Ledning notification')
        t.eq(env.notifies[1].target, 3)
        t.ok(env.notifies[1].data.description:find('audit.flag.unauthorizedSearchNotify', 1, true) == 1)
        t.ok(env.notifies[1].data.description:find('Anna Patrull', 1, true) ~= nil)
        local pushed = env.pushes[#env.pushes]
        t.eq(pushed.payload.type, 'lookupFlag')
        t.eq(pushed.targets, { 3 })
        Summary.person(1, { citizenid = 'RP502' })
        t.eq(#env.named('lookup.flag'), 1, 'flagged once per window')
        -- a missing person counts too (probing), threshold from config
        env.integrationsText = '{"unauthorizedLookupThreshold": 1}'
        mods['server.common'].resetConfig()
        mods['server.lookupflag'].reset()
        Summary.person(6, { citizenid = 'NOPE0001' })
        t.eq(#env.named('lookup.flag'), 2, 'threshold 1 from integrations.json')
        t.eq(env.named('lookup.flag')[2].targetId, 'REC10006')
    end)
end

tests['access 07 person page merges intel kontaktnotiser (dedup by contact, no leak of order)'] = function(t)
    H.with(t, function(_, env, mods)
        H.fewPeople()
        H.case({ 'K-5-26', 'Spaningsärende', 'open', 0, 'span', 'REC10002', nil, subjects = { { 'person', 'RP502', 'suspect' } } })
        env.resources.fredpd_intel = 'started'
        env.intelNotices = {
            { visibility = 'notice', contact = { displayName = 'Olle Utredare', unit = 'utredning' } },
            { visibility = 'notice', contact = { displayName = 'Sara S.', unit = 'span' } },
            { visibility = 'notice', contact = { displayName = 5 } },
            { visibility = 'full', id = 1 },
        }
        local cases = mods['server.summary'].person(1, { citizenid = 'RP502' }).data.cases
        t.eq(cases, {
            { visibility = 'notice', contact = { displayName = 'Sara S.', unit = 'span' } },
            { visibility = 'notice', contact = { displayName = 'Olle Utredare', unit = 'utredning' } },
        }, 'duplicate contact dropped, notices sorted by contact')
        env.intelNotices = { ok = true, data = { { visibility = 'notice', contact = { unit = 'span' } } } }
        t.eq(#mods['server.summary'].person(1, { citizenid = 'RP502' }).data.cases, 2, '{ ok, data } form accepted')
        env.resources.fredpd_intel = 'stopped'
        t.eq(#mods['server.summary'].person(1, { citizenid = 'RP502' }).data.cases, 1, 'intel stopped')
    end)
end

return tests
