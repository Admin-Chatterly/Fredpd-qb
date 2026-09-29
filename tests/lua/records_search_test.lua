-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_records search export (task 2.3 server side) against a real MariaDB: input validation and grant re-check,
-- FULLTEXT name search on 200 seeded persons (expected hits, order, pagination, EXPLAIN key and ANALYZE time
-- < 20 ms), word-start REGEXP fallback for short/stopword terms, hostile query strings, personnummer, plates (incl. the
-- refreshPlate miss path), case numbers shaped by canView, BOLO flags, one audit row per search, golden JSON.
-- Harness: tests/lua/records_env_test.lua. Run: lua5.4 tests/lua/run.lua records_
local H = require('records_env_test')

local tests = {}

local function search(mods, src, input)
    return mods['server.search'].search(src, input)
end

--- citizenids of person hits.
local function cids(hits)
    local out = {}
    for i, h in ipairs(hits) do out[i] = h.citizenid end
    return out
end

--- Expected hit ids for a LIKE-based reference query (independent of the FULLTEXT path), in the export's order.
local function reference(where, params)
    local out = {}
    for i, r in ipairs(MySQL.query.await('SELECT citizenid FROM fredpd_persons p WHERE ' .. where
        .. ' ORDER BY p.lastname, p.firstname, p.citizenid', params)) do
        out[i] = tostring(r.citizenid)
    end
    return out
end

local function slice(list, from, to)
    local out = {}
    for i = from, math.min(to, #list) do out[#out + 1] = list[i] end
    return out
end

--- The last SQL sent through MySQL.query that contains `needle`.
local function lastSql(env, needle)
    for i = #env.sql, 1, -1 do
        if env.sql[i].sql:find(needle, 1, true) then return env.sql[i] end
    end
    return nil
end

---------------------------------------------------------------------------------------------------------------
-- Validation and access

tests['01 invalid input is validation; missing grant, bad src and civilians are unauthorized'] = function(t)
    H.with(t, function(_, env, mods)
        local bad = {
            nil, 'Berg', {}, { query = 5 }, { query = 'B' }, { query = ('x'):rep(65) }, { query = '  B  ' },
            { query = 'Berg', type = 'phone' }, { query = 'Berg', type = 5 }, { query = 'Berg', page = 0 },
            { query = 'Berg', page = 10001 }, { query = 'Berg', page = 1.5 }, { query = 'Berg', page = '2' },
            { query = 'Ber\0g' }, { query = 'Ber\ng' }, { query = 'Ber\255g' },
        }
        for i = 1, 16 do
            t.eq(search(mods, 1, bad[i]), { ok = false, error = 'validation' }, 'input #' .. i)
        end
        t.eq(search(mods, 4, { query = 'Berg' }), { ok = false, error = 'unauthorized' }, 'civilian')
        t.eq(search(mods, 0, { query = 'Berg' }), { ok = false, error = 'unauthorized' }, 'src 0')
        t.eq(search(mods, 'x', { query = 'Berg' }), { ok = false, error = 'unauthorized' }, 'src not a number')
        t.eq(search(mods, -3, { query = 'Berg' }), { ok = false, error = 'unauthorized' })
        t.eq(#env.audits, 0, 'rejected searches are not audited')
        local okRes = search(mods, 1, { query = ('ö'):rep(64) })
        t.eq(okRes.ok, true, '64 characters of 2 bytes each are within the limit')
        local target = env.named('search')[1].targetId
        t.ok(#target <= 64 and utf8.len(target) == 32, 'audit target id cut to 64 bytes at a character boundary')
        t.eq(search(mods, 1, { query = (' '):rep(300) .. 'Berg' .. (' '):rep(300) }).ok, true, 'trimmed before the length check')
        t.eq(search(mods, 1, { query = '  Berg  ' }).data.normalized, 'Berg', 'trimmed')
    end)
end

tests['02 formats.json missing -> unavailable, logged once'] = function(t)
    H.with(t, function(_, env, mods)
        env.formatsText = false
        t.eq(search(mods, 1, { query = 'Berg' }), { ok = false, error = 'unavailable' })
        t.eq(search(mods, 1, { query = 'Berg' }), { ok = false, error = 'unavailable' })
        t.eq(env.logged('warn', 'formats.json'), 1)
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Names (FULLTEXT)

tests['03 200 persons: "Ber" finds every word starting with ber, sorted, paginated 50, via ft_name < 20 ms'] = function(t)
    H.with(t, function(_, env, mods)
        local people = H.seedPeople()
        t.eq(#people, 200)
        -- expected from the seed itself: a first or last name starting with "ber" (Öberg/Lindberg do not)
        local expected = 0
        for _, p in ipairs(people) do
            if p.firstname:lower():sub(1, 3) == 'ber' or p.lastname:lower():sub(1, 3) == 'ber' then
                expected = expected + 1
            end
        end
        t.eq(expected, 56, '4 last names x 10 + Berit x 16 other last names')
        local order = reference("p.firstname LIKE 'Ber%' OR p.lastname LIKE 'Ber%'")
        t.eq(#order, 56)

        local r1 = search(mods, 1, { query = 'Ber' })
        local sent = lastSql(env, 'MATCH')
        t.eq(r1.ok, true)
        t.eq(r1.data.detected, 'name')
        t.eq(r1.data.normalized, 'Ber')
        t.eq(r1.data.total, 56)
        t.eq(r1.data.page, 1)
        t.eq(#r1.data.hits, 50)
        t.eq(cids(r1.data.hits), slice(order, 1, 50), 'page 1 order: lastname, firstname, citizenid')
        local r2 = search(mods, 1, { query = 'Ber', page = 2 })
        t.eq(cids(r2.data.hits), slice(order, 51, 56), 'page 2')
        t.eq(r2.data.total, 56)
        local r3 = search(mods, 1, { query = 'ber', page = 3 })
        t.eq(r3.data.hits, {}, 'past the end')
        t.eq(r3.data.total, 56, 'total still reported (COUNT fallback)')

        -- hit shape
        local h = r1.data.hits[1]
        t.eq(H.keys(h), { 'birthdate', 'bolo', 'citizenid', 'kind', 'name', 'personnummer' })
        t.eq(h.kind, 'person')
        t.ok(h.birthdate:match('^%d%d%d%d%-%d%d%-%d%d$'), 'birthdate YYYY-MM-DD')
        t.ok(h.personnummer:match('^%d%d%d%d%d%d%d%d%-%d%d%d%d$'), 'personnummer')
        t.eq(h.bolo, false)

        -- the statement actually sent: FULLTEXT on ft_name, never players/charinfo
        t.ok(sent, 'a MATCH query was sent')
        t.eq(sent.params[1], '+Ber*')
        for _, s in ipairs(env.sql) do t.ok(not s.sql:find('charinfo', 1, true) and not s.sql:find(' players', 1, true),
            'never players.charinfo: ' .. s.sql) end
        local explain = MySQL.query.await('EXPLAIN ' .. sent.sql, sent.params)
        local key
        for _, row in ipairs(explain) do if row.table == 'p' then key = row.key end end
        t.eq(key, 'ft_name', 'EXPLAIN uses the FULLTEXT index')
        -- server-side execution time of that exact statement (best of 3 ANALYZE runs; the CLI start-up is not counted)
        local shim = require('mysql_shim')
        local best = math.huge
        for _ = 1, 3 do
            local out = H.run('ANALYZE FORMAT=JSON ' .. shim.bind(sent.sql, sent.params) .. ';')
            local doc = json.decode(shim.parseXml(out)[1].rows[1].ANALYZE)
            best = math.min(best, doc.query_block.r_total_time_ms)
        end
        t.ok(best < 20, ('query time %.3f ms must be < 20 ms'):format(best))
        if os.getenv('FREDPD_TEST_VERBOSE') then print(('records: "Ber" FULLTEXT query %.3f ms'):format(best)) end
        -- one audit row per search, with what was asked and which records were shown
        local audits = env.named('search')
        t.eq(#audits, 3)
        t.eq(audits[1].targetType, 'name')
        t.eq(audits[1].targetId, 'Ber')
        t.eq(audits[1].meta.query, 'Ber')
        t.eq(audits[1].meta.total, 56)
        t.eq(#audits[1].meta.hits, 50)
        t.eq(#env.named('lookup.person'), 0, 'a search is not a lookup')
    end)
end

tests['04 several terms, short terms and stopwords (REGEXP fallback), Swedish letters'] = function(t)
    H.with(t, function(_, env, mods)
        H.seedPeople()
        local function names(q)
            local r = search(mods, 1, { query = q })
            t.eq(r.ok, true, q)
            local out = {}
            for i, h in ipairs(r.data.hits) do out[i] = h.name end
            return out, r.data.total
        end
        t.eq(names('Anna Berg'), { 'Anna Berg', 'Anna Berglund', 'Anna Bergström' }, 'both terms required')
        t.eq(names('berg anna'), { 'Anna Berg', 'Anna Berglund', 'Anna Bergström' }, 'order and case do not matter')
        local _, bo = names('Bo')
        t.eq(bo, 20, '"Bo" (< min token size) found through REGEXP')
        t.eq(names('Bo Berg'), { 'Bo Berg', 'Bo Berglund', 'Bo Bergström' }, 'REGEXP and FULLTEXT combined')
        local _, will = names('Will')
        t.eq(will, 20, 'stopword "will" through REGEXP')
        local _, wil = names('Wil')
        t.eq(wil, 20, 'prefix of a stopword through REGEXP')
        t.eq(({ names('De Geer') })[2], 10, 'stopword "de" + "geer"')
        local _, li = names('Li')
        t.eq(li, 20, '"Li" matches Li and Lindberg (prefix)')
        local oberg, n = names('Öberg')
        t.eq(n, 10)
        for _, name in ipairs(oberg) do t.ok(name:find('Öberg', 1, true), 'Öberg only, not Berg: ' .. name) end
        t.eq(({ names('Berg-Anna') })[1], { 'Anna Berg', 'Anna Berglund', 'Anna Bergström' }, 'hyphen splits terms')
        local sent = lastSql(env, 'MATCH')
        t.eq(sent.params[1], '+Berg* +Anna*')
        -- short/stopword terms are a bound word-start REGEXP on the whole name, never interpolated
        names('Bo')
        local re = lastSql(env, 'REGEXP')
        t.eq(re.params, { '(^|[^[:alnum:]])Bo' })
        t.ok(not re.sql:find('Bo', 1, true), 'term only as a parameter')
        t.eq(({ names('bo') })[2], 20, 'REGEXP is case-insensitive under the _ci collation')
    end)
end

tests['04b word-start REGEXP: inside hyphenated/multi-word names, letters beyond ASCII, not mid-word'] = function(t)
    H.with(t, function(_, env, mods)
        H.persons({
            { 'RP901', 'Anna-Li', 'Ek', nil, nil, 1, nil },
            { 'RP902', 'Carlos', 'de la Cruz', nil, nil, 0, nil },
            { 'RP903', 'Åsa', 'Öst', nil, nil, 1, nil },
            { 'RP904', 'Olivia', 'Kalix', nil, nil, 1, nil },
        })
        local function ids(q)
            local r = search(mods, 1, { query = q })
            t.eq(r.ok, true, q)
            return cids(r.data.hits)
        end
        t.eq(ids('Li'), { 'RP901' }, 'second part of a hyphenated first name; not Olivia/Kalix (mid-word)')
        t.eq(ids('la'), { 'RP902' }, 'stopword inside a multi-word last name')
        t.eq(ids('ås'), { 'RP903' }, 'lower-case Swedish letter matches Å')
        t.eq(ids('Ös'), { 'RP903' })
        t.eq(ids('Li Ek'), { 'RP901' }, 'two short terms, both required')
        t.eq(ids('Cruz la'), { 'RP902' }, 'FULLTEXT term + REGEXP filter')
        t.eq(ids('ix'), {}, 'no mid-word match')
    end)
end

tests['05 hostile query strings are data: no error, no extra rows, no boolean operators reach MATCH'] = function(t)
    H.with(t, function(_, env, mods)
        H.seedPeople()
        local berg = search(mods, 1, { query = 'Berg Anna' }).data
        local cases = {
            { "'; DROP TABLE fredpd_persons; --", 0 },
            { "Berg' OR '1'='1", nil },
            { '+Berg* -Anna', 'same' },
            { '"Berg Anna"', 'same' },
            { 'Berg*)(~<>@ Anna', 'same' },
            { 'Berg @3', 0 },
            { '%_%', 0 },
            { '%%', 0 },
            { '\\\\', 0 },
            { "Berg) UNION SELECT citizenid FROM players --", 0 },
            { 'Berg; SELECT SLEEP(5)', 0 },
            { '@@version', 0 },
            { 'Anna´Berg', 'same' },
            { 'Anna’Berg', 'same' },
            { 'Anna\u{200B}Berg', 'same' },
            { '**', 0 },
            { '--', 0 },
            { '?? ?', 0 },
            { "\\' OR 1=1 #", 0 },
        }
        for _, c in ipairs(cases) do
            local q, want = c[1], c[2]
            local r = search(mods, 1, { query = q })
            t.eq(r.ok, true, 'ok for ' .. q)
            if want == 'same' then
                t.eq(cids(r.data.hits), cids(berg.hits), 'operators stripped: ' .. q)
            elseif want then
                t.eq(r.data.total, want, 'total for ' .. q)
            end
            for _, h in ipairs(r.data.hits) do t.ok(h.citizenid:match('^RP%d%d%d$'), 'only seeded persons') end
        end
        -- every FULLTEXT argument is '+term*' groups of letters/digits only
        for _, s in ipairs(env.sql) do
            if s.sql:find('AGAINST', 1, true) then
                local arg = s.params[1]
                for group in arg:gmatch('%S+') do
                    t.ok(group:match('^%+[^%s%+%-%*<>()~"@\']+%*$'), 'clean term group: ' .. group)
                end
            end
        end
        t.eq(tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM fredpd_persons')), 200, 'table intact')
        t.eq(#env.named('search'), #cases + 1, 'every search audited once')
    end)
end

tests['06 terms(): word splitting and caps'] = function(t)
    H.with(t, function(_, _, mods)
        local S = mods['server.search']
        t.eq(S.terms('Anna-Karin  O\'Brien'), { 'Anna', 'Karin', 'O', 'Brien' })
        t.eq(S.terms('Åsa Ärlig Östen'), { 'Åsa', 'Ärlig', 'Östen' })
        t.eq(S.terms('a b c d e f g h'), { 'a', 'b', 'c', 'd', 'e', 'f' }, 'at most 6 terms')
        t.eq(#S.terms(('x'):rep(40))[1], 32, 'terms cut to 32 characters')
        t.eq(S.terms('×÷«»–—“”'), {})
        t.eq(S.terms('Ber\255g'), { 'Ber', 'g' }, 'invalid UTF-8 bytes separate words')
        t.eq(S.wordStartPattern('Bo'), '(^|[^[:alnum:]])Bo')
        t.eq(S.wordStartPattern('Åsa'), '(^|[^[:alnum:]])Åsa', 'letters beyond ASCII stay literal')
        t.eq(S.wordStartPattern('a.b*'), '(^|[^[:alnum:]])a\\.b\\*', 'regex characters escaped (defence in depth)')
        local C = mods['server.common']
        t.eq(C.cutBytes('abc', 64), 'abc')
        t.eq(C.cutBytes(('ö'):rep(40), 64), ('ö'):rep(32))
        t.eq(C.cutBytes('a' .. ('ö'):rep(40), 64), 'a' .. ('ö'):rep(31), 'no half character')
        t.eq(C.cutBytes(('€'):rep(30), 64), ('€'):rep(21), '3-byte characters')
        local st = { minToken = 3, stopwords = true }
        t.eq(S.needsLike('Bo', st), true)
        t.eq(S.needsLike('Ber', st), false)
        t.eq(S.needsLike('the', st), true)
        t.eq(S.needsLike('Wil', st), true)
        t.eq(S.needsLike('Theodor', st), false)
        t.eq(S.needsLike('Wil', { minToken = 3, stopwords = false }), false, 'stopwords off')
        t.eq(S.needsLike('Bo', { minToken = 2, stopwords = false }), false, 'min token size 2')
        t.eq(S.ftSettings(), { minToken = 3, stopwords = true }, 'read from the server (MariaDB default)')
        t.eq(S.personnummerCandidates('900101-1234'), { '900101-1234', '19900101-1234', '20900101-1234' })
        t.eq(S.personnummerCandidates('19900101-1234'), { '19900101-1234', '900101-1234' })
    end)
end

---------------------------------------------------------------------------------------------------------------
-- personnummer, plates, case numbers

tests['07 personnummer: 12 and 10 digits, with and without dash'] = function(t)
    H.with(t, function(_, env, mods)
        local people = H.seedPeople()
        local p = people[5]
        local digits = p.personnummer:gsub('%-', '')
        for _, q in ipairs({ digits, p.personnummer, digits:sub(3), p.personnummer:sub(3) }) do
            local r = search(mods, 1, { query = q })
            t.eq(r.data.detected, 'personId', q)
            t.eq(cids(r.data.hits), { p.citizenid }, q)
            t.eq(r.data.total, 1)
        end
        t.eq(search(mods, 1, { query = '19000101-0000' }).data.total, 0)
        t.ok(lastSql(env, 'personnummer IN'), 'indexed IN lookup')
        local explain = MySQL.query.await('EXPLAIN ' .. lastSql(env, 'personnummer IN').sql,
            lastSql(env, 'personnummer IN').params)
        t.eq(explain[1].key, 'idx_personnummer')
    end)
end

tests['08 plates: exact hit with owner and BOLO flag; a miss refreshes from player_vehicles once'] = function(t)
    H.with(t, function(_, env, mods)
        H.persons({ { 'RP005', 'Maria', 'Nilsson', '1990-01-01', nil, 1, nil } })
        H.vehicles({ { 'ABC123', 'RP005', 'sultan' }, { 'XYZ98A', nil, 'blista' } })
        env.bolos.plates.ABC123 = H.bolo(7, 'vehicle')
        local r = search(mods, 1, { query = 'abc 123' })
        t.eq(r.data.detected, 'plate')
        t.eq(r.data.normalized, 'ABC123')
        t.eq(r.data.total, 1)
        t.eq(r.data.hits, { { kind = 'vehicle', plate = 'ABC123', model = 'sultan', ownerName = 'Maria Nilsson',
            ownerCitizenid = 'RP005', bolo = true } })
        t.eq(env.calls.refreshPlate, 0, 'a hit needs no refresh')
        t.eq(search(mods, 1, { query = 'XYZ 98A' }).data.hits[1], { kind = 'vehicle', plate = 'XYZ98A',
            model = 'blista', bolo = false }, 'no owner: ownerName/ownerCitizenid absent (null)')
        t.eq(search(mods, 1, { query = 'ABC123', page = 2 }).data, { detected = 'plate', normalized = 'ABC123',
            hits = {}, total = 1, page = 2 })

        -- KLM 34E is only in player_vehicles (qbx stub): the miss asks fredpd_core:refreshPlate, which mirrors it
        local miss = search(mods, 1, { query = 'klm34e' })
        t.eq(env.calls.refreshPlate, 1)
        t.eq(miss.data.hits, { { kind = 'vehicle', plate = 'KLM34E', model = 'blista', ownerCitizenid = 'FPD10003',
            bolo = false } }, 'owner without a mirror row: no name')
        t.eq(search(mods, 1, { query = 'QQQ 99Z' }).data.total, 0)
        t.eq(env.calls.refreshPlate, 2, 'unknown plate: one refresh attempt')
        -- explicit vehicle type accepts non-Swedish plates
        H.vehicles({ { '12GTA345', nil, 'adder' } })
        local gta = search(mods, 1, { query = '12gta345', type = 'vehicle' })
        t.eq(gta.data.detected, 'plate')
        t.eq(gta.data.hits[1].plate, '12GTA345')
        t.eq(search(mods, 1, { query = '12gta345' }).data.detected, 'name', 'auto: not a Swedish plate')
        H.golden(t, 'search.plate', r.data)
    end)
end

tests['09 case numbers: full / masked / notice / none shaped by canView'] = function(t)
    H.with(t, function(_, env, mods)
        H.case({ 'K-1-26', 'Rån mot värdetransport', 'open', 0, 'utredning', 'REC10002' })
        H.case({ 'K-2-26', 'Stöld av moped', 'closed', 0, 'utredning', 'REC10002' })
        H.case({ 'K-3-26', 'Grov narkotikabrott', 'closed', 1, 'utredning', 'REC10002' })
        H.case({ 'K-4-26', 'Spaningsärende', 'open', 2, 'ledning', nil, nil, assignees = { 'REC10003' } })
        H.case({ 'K-5-26', 'Dolt ärende', 'open', 0, 'utredning', 'REC10002' })
        env.visOverride['case:5'] = 'none'

        local notice = search(mods, 1, { query = 'K-1-26' })
        t.eq(notice.data.detected, 'caseNumber')
        t.eq(notice.data.hits, { { kind = 'case', case = { visibility = 'notice',
            contact = { displayName = 'Olle Utredare', unit = 'utredning' } } } })
        H.checkRef(t, notice.data.hits[1].case)
        local full = search(mods, 2, { query = 'k-1-26' })
        t.eq(full.data.normalized, 'K-1-26')
        t.eq(full.data.hits[1].case, { visibility = 'full', id = 1, caseNumber = 'K-1-26',
            title = 'Rån mot värdetransport', status = 'open', level = 0 })
        H.checkRef(t, full.data.hits[1].case)
        local masked = search(mods, 1, { query = 'K-2-26' }).data.hits[1].case
        t.eq(masked, { visibility = 'masked', id = 2, caseNumber = 'K-2-26', title = 'Stöld av moped',
            status = 'closed', level = 0 })
        t.eq(search(mods, 1, { query = 'K-3-26' }).data.hits[1].case.visibility, 'notice',
            'closed level 1 above tier 0: kontaktnotis (hard cap)')
        local noOwner = search(mods, 1, { query = 'K-4-26' }).data.hits[1].case
        t.eq(noOwner, { visibility = 'notice', contact = { unit = 'ledning' } }, 'no owner: unit only')
        local none = search(mods, 1, { query = 'K-5-26' })
        t.eq(none.data.hits, {}, "'none' is omitted entirely")
        t.eq(none.data.total, 0, 'and not counted')
        t.eq(search(mods, 1, { query = 'K-99-26' }).data.total, 0)
        t.eq(search(mods, 1, { query = 'k-1-26', type = 'case' }).data.hits[1].case.visibility, 'notice')
        t.eq(env.named('search')[1].meta.hits, { 'notice' }, 'the audit does not name the hidden case either')
        H.golden(t, 'search.case-notice', notice.data)
        H.golden(t, 'search.case-full', full.data)
    end)
end

tests['10 BOLO flags: person hits, level above the viewer, fredpd_bolo stopped or failing'] = function(t)
    H.with(t, function(_, env, mods)
        H.seedPeople()
        local anna = search(mods, 1, { query = 'Anna Berg' }).data
        local flagged = {}
        for _, h in ipairs(anna.hits) do flagged[h.citizenid] = h.bolo end
        -- RP011 = Anna Berg (last name #2, first name #1)
        env.bolos.persons.RP011 = H.bolo(4, 'person', { citizenid = 'RP011' })
        local again = search(mods, 1, { query = 'Anna Berg' }).data
        t.eq(again.hits[1].citizenid, 'RP011')
        t.eq(again.hits[1].bolo, true)
        t.eq(again.hits[2].bolo, false)
        t.eq(flagged.RP011, false, 'no BOLO before')
        -- a level-2 BOLO the viewer may not see: canView 'none' hides the flag
        env.bolos.persons.RP011 = H.bolo(4, 'person', { citizenid = 'RP011', level = 2 })
        env.visOverride['bolo:4'] = 'none'
        t.eq(search(mods, 1, { query = 'Anna Berg' }).data.hits[1].bolo, false)
        env.visOverride['bolo:4'] = 'notice'
        t.eq(search(mods, 1, { query = 'Anna Berg' }).data.hits[1].bolo, true, 'kontaktnotis still flags')
        env.bolos.persons.RP011 = H.bolo(4, 'person', { citizenid = 'RP011', active = false })
        t.eq(search(mods, 1, { query = 'Anna Berg' }).data.hits[1].bolo, false, 'inactive')
        -- fredpd_bolo stopped: no export calls at all, flags false
        env.bolos.persons.RP011 = H.bolo(4, 'person', { citizenid = 'RP011' })
        env.resources.fredpd_bolo = 'stopped'
        local before = env.calls.checkPerson
        local stopped = search(mods, 1, { query = 'Anna Berg' })
        t.eq(stopped.ok, true)
        t.eq(stopped.data.hits[1].bolo, false)
        t.eq(env.calls.checkPerson, before, 'no calls into a stopped resource')
        -- started but the export raises: flags false, one warning
        env.resources.fredpd_bolo = 'started'
        env.boloThrows = true
        t.eq(search(mods, 1, { query = 'Anna Berg' }).data.hits[1].bolo, false)
        search(mods, 1, { query = 'Anna Berg' })
        t.eq(env.logged('warn', 'fredpd_bolo'), 1, 'warned once')
        env.boloThrows = false
        H.golden(t, 'search.name', again)
    end)
end

tests['11 explicit types and golden empty result'] = function(t)
    H.with(t, function(_, _, mods)
        local people = H.seedPeople()
        local p = search(mods, 1, { query = 'Karin', type = 'person' }).data
        t.eq(p.detected, 'name')
        t.eq(p.total, 20)
        local byPnr = search(mods, 1, { query = people[1].personnummer, type = 'person' }).data
        t.eq(byPnr.detected, 'personId')
        t.eq(byPnr.total, 1)
        H.golden(t, 'search.person-id', byPnr)
        local v = search(mods, 1, { query = 'Karin', type = 'vehicle' }).data
        t.eq(v, { detected = 'plate', normalized = 'KARIN', hits = {}, total = 0, page = 1 })
        local c = search(mods, 1, { query = 'Karin', type = 'case' }).data
        t.eq(c, { detected = 'caseNumber', normalized = 'KARIN', hits = {}, total = 0, page = 1 })
        local empty = search(mods, 1, { query = '%_%' }).data
        t.eq(empty, { detected = 'name', normalized = '%_%', hits = {}, total = 0, page = 1 })
        H.golden(t, 'search.empty', empty)
    end)
end

tests['12 main.lua: exports registered; a database failure is unavailable, logged'] = function(t)
    H.with(t, function(_, env, mods)
        local main = H.loadMain(mods)
        t.eq(H.keys(env.exported), { 'countMyOpenCases', 'getHomeCases', 'getPersonSummary', 'getVehicleSummary',
            'search' })
        H.seedPeople()
        local ok = env.exported.search(1, { query = 'Berg' })
        t.eq(ok.ok, true)
        env.failSql = 'MATCH'
        t.eq(env.exported.search(1, { query = 'Berg' }), { ok = false, error = 'unavailable' })
        t.eq(env.logged('error', 'search failed'), 1)
        env.failSql = nil
        local bad = main.guarded('x', function() return 'not a result' end)
        t.eq(bad(1, {}), { ok = false, error = 'unavailable' })
    end)
end

return tests
