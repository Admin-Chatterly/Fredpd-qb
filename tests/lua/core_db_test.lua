-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_core runtime against a real MariaDB (through tests/lua/mysql_shim.lua, which runs server/db.lua's
-- migrations and fakes oxmysql): search-mirror backfill/refresh/seed (task 1.4), grant cache round trip, identities,
-- visibility rules from the seed, audit archive, units sync and callsign allocation (task 1.7b).
-- Uses its own database fredpd_test_core_lua (reset once per run, with db/dev/qbx_stub.sql). Every session runs at
-- time_zone '+02:00' (a Stockholm-summer server): FredPD stores UTC whatever the zone (docs/contracts.md §C7), so
-- nothing here may depend on it. Skips with a notice when MariaDB is unreachable.
-- Run: lua5.4 tests/lua/run.lua core_db_test
local shim = require('mysql_shim')
local helper = require('helper')
local Core = require('server.core')
local Perms = require('server.perms')
local Mirror = require('server.mirror')
local Audit = require('server.audit')
local ServerCanView = require('server.canview')
local Officers = require('server.officers')
local Format = require('shared.format')

local DB = 'fredpd_test_core_lua'
local tests = {}

local prepared = nil -- nil: not tried, true: ready, false: unavailable
local notified = false

--- Install the shim (and stubs for natives these modules touch) for fn; restores all globals afterwards.
local function withDb(t, fn)
    local ok, reason = shim.available()
    if not ok then
        if not notified then
            print(('SKIP core_db_test: MariaDB unreachable (%s)'):format((reason or ''):gsub('%s+$', '')))
            notified = true
        end
        return
    end
    local names = { 'MySQL', 'LoadResourceFile', 'GetCurrentResourceName', 'CreateThread', 'TriggerEvent',
        'TriggerClientEvent', 'GetPlayerName' }
    local saved = {}
    for _, n in ipairs(names) do saved[n] = { rawget(_G, n) } end
    shim.install({ database = DB, sessionTimeZone = '+02:00' })
    -- oxmysql runs mysql2 with CLIENT_FOUND_ROWS, the mariadb CLI behind the shim does not. Emulate it where the
    -- number differs: an INSERT ... ON DUPLICATE KEY UPDATE that matched a row and left it unchanged reports at
    -- least 1, not 0 (exact for one row). UPDATE counts differ too (matched vs changed), but the modules only read
    -- UPDATE counts whose WHERE clause excludes unchanged rows, where both agree.
    local rawUpdate = MySQL.update.await
    local function foundRowsUpdate(sql, params)
        local n = rawUpdate(sql, params)
        if n == 0 and sql:find('ON DUPLICATE KEY UPDATE', 1, true) then return 1 end
        return n
    end
    MySQL.update = setmetatable({ await = foundRowsUpdate }, { __call = function(_, sql, params, cb)
        if type(params) == 'function' then params, cb = nil, params end
        local r = foundRowsUpdate(sql, params)
        if cb then cb(r) end
        return r
    end })
    rawset(_G, 'CreateThread', function(f) f() end)
    rawset(_G, 'TriggerEvent', function() end)
    rawset(_G, 'TriggerClientEvent', function() end)
    rawset(_G, 'GetPlayerName', function() return 'FiveM Name' end)
    local okRun, err = pcall(function()
        if prepared == nil then
            prepared = false
            shim.resetDatabase(DB, true)
            require('server.db').migrate({ log = function() end })
            prepared = true
        end
        if prepared then fn(t) end
    end)
    for n, v in pairs(saved) do rawset(_G, n, v[1]) end
    shim.sessionTimeZone = nil
    if not okRun then error(err, 0) end
end

--- Seconds between a UTC DATETIME column value (selected by `sql`) and UTC_TIMESTAMP(), absolute.
local function utcSkew(sql, params)
    return MySQL.scalar.await('SELECT ABS(TIMESTAMPDIFF(SECOND, (' .. sql .. '), UTC_TIMESTAMP()))', params)
end

local function q(sql, params) return MySQL.query.await(sql, params) end
local function scalar(sql, params) return MySQL.scalar.await(sql, params) end

---------------------------------------------------------------------------------------------------------------
-- Mirror (task 1.4)

tests['01 backfill fills both mirrors from players / player_vehicles in batches'] = function(t)
    withDb(t, function()
        local savedBatch = Mirror.BATCH
        Mirror.BATCH = 2 -- 3 stub players -> 2 keyset pages
        local ok, result = pcall(Mirror.backfill, 0)
        Mirror.BATCH = savedBatch
        t.ok(ok, tostring(result))
        t.eq(result, { persons = 3, vehicles = 2 })
        local anna = q('SELECT * FROM fredpd_persons WHERE citizenid = ?', { 'FPD10001' })[1]
        t.eq(anna.firstname, 'Anna')
        t.eq(anna.lastname, 'Berg')
        t.eq(anna.birthdate, '1994-03-12')
        t.eq(anna.gender, 1)
        t.eq(anna.phone, 701234567, 'shim reads digit strings as numbers')
        t.eq(anna.personnummer, Mirror.personnummer('FPD10001', '1994-03-12', 1))
        t.eq(anna.license, 'license:0000000000000000000000000000000000000001')
        local sara = q('SELECT firstname, lastname FROM fredpd_persons WHERE citizenid = ?', { 'FPD10003' })[1]
        t.eq(sara.lastname, 'Öberg')
        local car = q('SELECT * FROM fredpd_vehicles_idx WHERE plate = ?', { 'ABC12D' })[1]
        t.eq(car.citizenid, 'FPD10002')
        t.eq(car.model, 'sultan')
        -- audit row for the run
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_audit WHERE action = 'mirror.backfill'"), 1)
    end)
end

tests['02 backfill is idempotent and the FULLTEXT name search finds the mirror rows'] = function(t)
    withDb(t, function()
        t.eq(Mirror.backfill(0), { persons = 3, vehicles = 2 })
        t.eq(scalar('SELECT COUNT(*) FROM fredpd_persons'), 3)
        t.eq(scalar('SELECT COUNT(*) FROM fredpd_vehicles_idx'), 2)
        local hits = q("SELECT citizenid FROM fredpd_persons WHERE MATCH (firstname, lastname) AGAINST ('Lindqvist' IN BOOLEAN MODE)")
        t.eq(#hits, 1)
        t.eq(hits[1].citizenid, 'FPD10002')
        local byPnr = q('SELECT citizenid FROM fredpd_persons WHERE personnummer = ?',
            { Mirror.personnummer('FPD10003', '2001-07-30', 1) })
        t.eq(byPnr[1].citizenid, 'FPD10003')
    end)
end

tests['03 refreshPlate re-reads one plate after a miss'] = function(t)
    withDb(t, function()
        q("DELETE FROM fredpd_vehicles_idx WHERE plate = 'KLM34E'")
        local row = Mirror.refreshPlate('klm 34e')
        t.eq(row, { plate = 'KLM34E', citizenid = 'FPD10003', model = 'blista' })
        t.eq(scalar("SELECT citizenid FROM fredpd_vehicles_idx WHERE plate = 'KLM34E'"), 'FPD10003')
        t.eq(Mirror.refreshPlate('ZZZ99Z'), nil)
        t.eq(Mirror.refreshPlate(''), nil)
    end)
end

tests['04 syncPlayerData writes only when a mirrored field changed'] = function(t)
    withDb(t, function()
        local pd = { citizenid = 'FPD10001', license = 'license:1', charinfo = { firstname = 'Anna', lastname = 'Bergström',
            birthdate = '1994-03-12', gender = 1, phone = '0701234567' }, money = { cash = 1 } }
        t.eq(Mirror.syncPlayerData(pd), true)
        t.eq(scalar("SELECT lastname FROM fredpd_persons WHERE citizenid = 'FPD10001'"), 'Bergström')
        pd.money.cash = 999
        t.eq(Mirror.syncPlayerData(pd), false, 'money changes are not mirrored')
        pd.charinfo.phone = '0709999999'
        t.eq(Mirror.syncPlayerData(pd), true)
        t.eq(Mirror.syncPlayerData({ citizenid = 'NEW1', charinfo = '{"firstname":"Ny","lastname":"Person"}' }), true)
        t.eq(scalar("SELECT firstname FROM fredpd_persons WHERE citizenid = 'NEW1'"), 'Ny')
    end)
end

tests['05 dev seeding: DEV rows only, never overwrites'] = function(t)
    withDb(t, function()
        local persons = { { citizenid = 'DEV00001', firstname = 'Test', lastname = 'Testsson', birthdate = '1990-01-01',
            gender = 0, phone = '0700000000' } }
        local vehicles = { { plate = 'DEV 01A', citizenid = 'DEV00001', model = 'asea' },
            { plate = 'ABC12D', citizenid = 'DEV00001', model = 'hijack' } }
        t.eq(Mirror.insertDevRows(0, persons, vehicles), { persons = 1, vehicles = 1 })
        t.eq(scalar("SELECT citizenid FROM fredpd_vehicles_idx WHERE plate = 'ABC12D'"), 'FPD10002', 'real row kept')
        t.eq(Mirror.insertDevRows(0, persons, {}), { persons = 0, vehicles = 0 }, 'second run inserts nothing')
        t.ok(not pcall(Mirror.insertDevRows, 0, { { citizenid = 'FPD10001', firstname = 'X' } }, {}))
        t.ok(not pcall(Mirror.insertDevRows, 0, {}, { { plate = 'AAA11A', citizenid = 'FPD10001' } }))
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_audit WHERE action = 'mirror.seed'"), 2)
    end)
end

tests['06 seed at scale: 200 generated persons, FULLTEXT lookup is indexed'] = function(t)
    withDb(t, function()
        local Seed = dofile('resources/[fredpd]/fredpd_devtools/server/seed.lua')
        math.randomseed(7)
        local persons, vehicles = Seed.generate(200, 100)
        local result = Mirror.insertDevRows(0, persons, vehicles)
        t.eq(result.persons, 200)
        local plan = q("EXPLAIN SELECT citizenid FROM fredpd_persons WHERE MATCH (firstname, lastname) "
            .. "AGAINST ('Andersson' IN BOOLEAN MODE)")
        t.eq(plan[1].key, 'ft_name')
        t.eq(plan[1].type, 'fulltext')
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Grant cache and identities

tests['07 grant cache round trip through the JSON column'] = function(t)
    withDb(t, function()
        local set = Perms.validateSet({ grants = { 'weapon:*', 'unit:igv' }, denied = { 'weapon:rifle' }, tier = 1,
            units = { 'igv' }, rank = { roleId = '222', key = 'inspektor' }, computedAt = '2026-09-29T12:00:00.000Z' })
        Perms.writeCache('9001', set)
        t.eq(Perms.readCache('9001'), set)
        t.eq(scalar("SELECT DATE_FORMAT(computed_at, '%Y-%m-%d %H:%i:%s') FROM fredpd_grant_cache WHERE discord_id = '9001'"),
            '2026-09-29 12:00:00')
        local empty = Perms.validateSet({ grants = {}, denied = {}, tier = 0, units = {}, computedAt = 'not iso' })
        Perms.writeCache('9001', empty)
        t.ok(utcSkew("SELECT computed_at FROM fredpd_grant_cache WHERE discord_id = '9001'") <= 60,
            'no usable computedAt: UTC_TIMESTAMP()')
        t.eq(Perms.readCache('9001').grants, {})
        t.eq(scalar("SELECT JSON_TYPE(JSON_EXTRACT(grants, '$.grants')) FROM fredpd_grant_cache WHERE discord_id = '9001'"),
            'ARRAY')
        t.eq(Perms.readCache('404'), nil)
    end)
end

tests['08 identities: last_seen on join, character + license on load (NULL license kept)'] = function(t)
    withDb(t, function()
        q(Perms.IDENTITY_SEEN_SQL, { '9100' })
        local savedId = Perms.getDiscordId
        Perms.getDiscordId = function() return '9100' end
        Perms.recordCharacter(5, { citizenid = 'FPD10001', license = 'license2:abc' })
        Perms.recordCharacter(5, { citizenid = 'FPD10003' })
        Perms.getDiscordId = savedId
        local row = q("SELECT license, last_citizenid, last_seen FROM fredpd_identities WHERE discord_id = '9100'")[1]
        t.eq(row.last_citizenid, 'FPD10003')
        t.eq(row.license, 'license2:abc', 'a missing license does not erase the known one')
        t.ok(row.last_seen ~= nil)
        t.ok(utcSkew("SELECT last_seen FROM fredpd_identities WHERE discord_id = '9100'") <= 60, 'last_seen is UTC')
        t.ok(utcSkew("SELECT created_at FROM fredpd_identities WHERE discord_id = '9100'") <= 60, 'created_at is UTC')
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Visibility rules from the seed

tests['09 loadRules reads the seeded rules and matches the fixtures'] = function(t)
    withDb(t, function()
        t.eq(ServerCanView.loadRules(), true)
        local fixtures = helper.readJson('packages/types/test/fixtures/canView.fixtures.json')
        t.eq(#ServerCanView.getRules(), #fixtures.rules)
        local byId = {}
        for _, r in ipairs(ServerCanView.getRules()) do byId[r.id] = r end
        for _, expected in ipairs(fixtures.rules) do
            t.eq(byId[expected.id], expected, 'rule ' .. expected.id)
        end
        ServerCanView.setRules({})
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Audit archive

tests['10 archiveOlderThan moves old rows in batches and keeps recent ones'] = function(t)
    withDb(t, function()
        q('DELETE FROM fredpd_audit')
        for i = 1, 5 do
            q("INSERT INTO fredpd_audit (actor_citizenid, action, target_type, target_id, created_at) VALUES "
                .. "(?, 'lookup.person', 'person', ?, UTC_TIMESTAMP() - INTERVAL ? DAY)", { 'OLD', 'T' .. i, 100 + i })
        end
        q("INSERT INTO fredpd_audit (actor_citizenid, action, created_at) VALUES ('NEW', 'lookup.person', UTC_TIMESTAMP() - INTERVAL 89 DAY)")
        -- 30 minutes inside the window: a cutoff taken from the +02:00 session clock (NOW()) would move it.
        q("INSERT INTO fredpd_audit (actor_citizenid, action, created_at) VALUES ('EDGE', 'lookup.person', "
            .. 'UTC_TIMESTAMP() - INTERVAL 90 DAY + INTERVAL 30 MINUTE)')
        q("INSERT INTO fredpd_audit (actor_citizenid, action) VALUES ('NOW', 'lookup.person')")
        t.ok(utcSkew("SELECT created_at FROM fredpd_audit WHERE actor_citizenid = 'NOW'") <= 60, 'created_at default is UTC')
        local moved = Audit.archiveOlderThan(90, 2)
        t.eq(moved, 5)
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_audit_archive WHERE actor_citizenid = 'OLD'"), 5)
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_audit WHERE actor_citizenid = 'OLD'"), 0)
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_audit WHERE actor_citizenid IN ('NEW', 'EDGE', 'NOW')"), 3)
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_audit WHERE action = 'audit.archive'"), 1)
        t.ok(utcSkew("SELECT MAX(archived_at) FROM fredpd_audit_archive") <= 60, 'archived_at default is UTC')
        local meta = json.decode(scalar("SELECT meta FROM fredpd_audit WHERE action = 'audit.archive'"))
        t.ok(meta.cutoff:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$'), 'cutoff in the audit meta is ISO UTC: ' .. meta.cutoff)
        t.eq(Audit.archiveOlderThan(90), 0, 'nothing left to move')
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Units and callsigns (task 1.7b)

tests['11 syncUnits mirrors config/units.json and deactivates removed units'] = function(t)
    withDb(t, function()
        local units = helper.readJson('config/units.json')
        t.eq(Officers.syncUnits(units), 5)
        t.eq(scalar('SELECT COUNT(*) FROM fredpd_units WHERE active = 1'), 5)
        t.eq(scalar("SELECT callsign_prefix FROM fredpd_units WHERE code = 'igv'"), 'IGV')
        t.eq(scalar("SELECT sort_order FROM fredpd_units WHERE code = 'span'"), 2)
        local fewer = { units = { units.units[5], units.units[1] } }
        t.eq(Officers.syncUnits(fewer), 2)
        t.eq(scalar("SELECT active FROM fredpd_units WHERE code = 'span'"), 0)
        t.eq(scalar("SELECT sort_order FROM fredpd_units WHERE code = 'igv'"), 1)
        Officers.syncUnits(units)
    end)
end

tests['12 first duty assigns the lowest free callsign per unit'] = function(t)
    withDb(t, function()
        Format.load(helper.readJson('config/formats.json'))
        local units = helper.readJson('config/units.json')
        local byCode, order = Core.unitIndex(units)
        local players = {
            [1] = { citizenid = 'FPD10001', discord = '5001', units = { 'igv' } },
            [2] = { citizenid = 'FPD10002', discord = '5002', units = { 'igv', 'span' } }, -- primary: span
            [3] = { citizenid = 'FPD10003', discord = '5003', units = { 'igv' } },
            [4] = { citizenid = 'COP4', discord = '5004', units = { 'igv' } },
            [5] = { citizenid = 'COP5', discord = '5005', units = {} },
            [6] = { citizenid = 'CIV6', discord = '5006', units = { 'igv' }, job = 'unemployed' },
        }
        local saved = { pd = Core.getPlayerData, notify = Core.notify, units = Perms.getUnits, id = Perms.getDiscordId,
            byCode = Core.config.unitsByCode, order = Core.config.unitOrder, warn = Core.warn }
        local notices = {}
        Core.getPlayerData = function(src)
            local p = players[src]
            return p and { citizenid = p.citizenid, job = { type = p.job and 'none' or 'leo', onduty = true } } or nil
        end
        Core.notify = function(src, data) notices[#notices + 1] = { src, data.description } end
        Perms.getUnits = function(src) return players[src].units end
        Perms.getDiscordId = function(src) return players[src].discord end
        Core.config.unitsByCode, Core.config.unitOrder = byCode, order
        Core.warn = function() end
        local ok, err = pcall(function()
            q('DELETE FROM fredpd_officers')
            t.eq(Officers.ensureCallsign(1), 'IGV-01')
            t.eq(Officers.ensureCallsign(2), 'SPAN-01')
            t.eq(Officers.ensureCallsign(3), 'IGV-02')
            t.eq(Officers.ensureCallsign(1), 'IGV-01', 'an existing callsign is kept')
            -- Ledning clears officer 3's callsign: the gap is reused.
            q("UPDATE fredpd_officers SET callsign = NULL WHERE citizenid = 'FPD10003'")
            t.eq(Officers.ensureCallsign(4), 'IGV-02')
            local cs, why = Officers.ensureCallsign(5)
            t.eq(cs, nil)
            t.eq(why, 'no_unit')
            cs, why = Officers.ensureCallsign(6)
            t.eq(why, 'not_police')
            t.eq(scalar("SELECT display_name FROM fredpd_officers WHERE citizenid = 'FPD10001'"), 'FiveM Name')
            t.eq(scalar("SELECT unit FROM fredpd_officers WHERE citizenid = 'FPD10002'"), 'span')
            t.eq(scalar("SELECT COUNT(*) FROM fredpd_audit WHERE action = 'officer.callsign'"), 4)
            t.eq(scalar("SELECT COUNT(*) FROM fredpd_audit WHERE action = 'officer.create'"), 4,
                'each new roster row audited once (FPD10003 was only updated the second time)')
            t.eq(#notices, 4)
            -- A row created by the bot (no callsign yet) keeps its Discord name.
            q("INSERT INTO fredpd_officers (citizenid, discord_id, display_name) VALUES ('FPD10003', '5003', 'Sara Ö.') "
                .. "ON DUPLICATE KEY UPDATE display_name = VALUES(display_name)")
            Officers.loadAll()
            t.eq(Officers.ensureCallsign(3), 'IGV-03')
            t.eq(scalar("SELECT display_name FROM fredpd_officers WHERE citizenid = 'FPD10003'"), 'Sara Ö.')
        end)
        Core.getPlayerData, Core.notify, Perms.getUnits, Perms.getDiscordId = saved.pd, saved.notify, saved.units, saved.id
        Core.config.unitsByCode, Core.config.unitOrder, Core.warn = saved.byCode, saved.order, saved.warn
        if not ok then error(err, 0) end
    end)
end

tests['13 a concurrent allocation of the same number is retried (unique unit+callsign)'] = function(t)
    withDb(t, function()
        -- Simulate another server instance taking IGV-04 between our SELECT and INSERT: nextCallsign is wrapped
        -- so the first candidate is stolen right before we write it.
        local units = helper.readJson('config/units.json')
        local byCode, order = Core.unitIndex(units)
        local saved = { pd = Core.getPlayerData, notify = Core.notify, units = Perms.getUnits, id = Perms.getDiscordId,
            byCode = Core.config.unitsByCode, order = Core.config.unitOrder, next = Officers.nextCallsign }
        Core.getPlayerData = function() return { citizenid = 'RACE1', job = { type = 'leo', onduty = true } } end
        Core.notify = function() end
        Perms.getUnits = function() return { 'igv' } end
        Perms.getDiscordId = function() return '5999' end
        Core.config.unitsByCode, Core.config.unitOrder = byCode, order
        local stolen = false
        Officers.nextCallsign = function(...)
            local cs, n = saved.next(...)
            if not stolen then
                stolen = true
                q("INSERT INTO fredpd_officers (citizenid, discord_id, display_name, callsign, unit) VALUES "
                    .. "('THIEF', '5998', 'Other', ?, 'igv')", { cs })
            end
            return cs, n
        end
        local ok, err = pcall(function()
            local expectedThief = saved.next('{{unit}}-{{n:2}}', 'IGV', (function()
                local taken = {}
                for _, r in ipairs(q("SELECT callsign FROM fredpd_officers WHERE unit = 'igv' AND callsign IS NOT NULL")) do
                    taken[r.callsign] = true
                end
                return taken
            end)())
            local cs = Officers.ensureCallsign(77)
            t.eq(scalar("SELECT callsign FROM fredpd_officers WHERE citizenid = 'THIEF'"), expectedThief)
            t.ok(cs ~= nil and cs ~= expectedThief, 'got a different callsign: ' .. tostring(cs))
        end)
        Core.getPlayerData, Core.notify, Perms.getUnits, Perms.getDiscordId = saved.pd, saved.notify, saved.units, saved.id
        Core.config.unitsByCode, Core.config.unitOrder, Officers.nextCallsign = saved.byCode, saved.order, saved.next
        if not ok then error(err, 0) end
    end)
end

tests['14 ensureRow creates and audits a roster row once, and audits a Discord relink'] = function(t)
    withDb(t, function()
        local savedId = Perms.getDiscordId
        local discord = '6101'
        Perms.getDiscordId = function() return discord end
        local ok, err = pcall(function()
            t.eq(MySQL.update.await("INSERT INTO fredpd_officers (citizenid, discord_id, display_name) VALUES "
                .. "('ROW0', '6100', 'x') ON DUPLICATE KEY UPDATE discord_id = VALUES(discord_id)"), 1)
            t.eq(MySQL.update.await("INSERT INTO fredpd_officers (citizenid, discord_id, display_name) VALUES "
                .. "('ROW0', '6100', 'x') ON DUPLICATE KEY UPDATE discord_id = VALUES(discord_id)"), 1,
                'FOUND_ROWS emulation: an unchanged upsert reports 1 like oxmysql')
            local pd = { citizenid = 'ROW1', job = { type = 'leo', onduty = false } }
            for _ = 1, 3 do t.eq(Officers.ensureRow(1, pd).citizenid, 'ROW1') end
            t.eq(scalar("SELECT COUNT(*) FROM fredpd_audit WHERE action = 'officer.create' AND target_id = 'ROW1'"), 1)
            t.eq(scalar("SELECT display_name FROM fredpd_officers WHERE citizenid = 'ROW1'"), 'FiveM Name')
            q("UPDATE fredpd_officers SET display_name = 'Bo Ek' WHERE citizenid = 'ROW1'") -- the bot's name
            discord = '6102'
            t.eq(Officers.ensureRow(1, pd).discordId, '6102')
            Officers.ensureRow(1, pd)
            t.eq(scalar("SELECT COUNT(*) FROM fredpd_audit WHERE action = 'officer.relink' AND target_id = 'ROW1'"), 1)
            t.eq(scalar("SELECT display_name FROM fredpd_officers WHERE citizenid = 'ROW1'"), 'Bo Ek',
                'Discord-owned name untouched')
            t.eq(scalar("SELECT COUNT(*) FROM fredpd_audit WHERE action = 'officer.create' AND target_id = 'ROW1'"), 1)
        end)
        Perms.getDiscordId = savedId
        q("DELETE FROM fredpd_officers WHERE citizenid IN ('ROW0', 'ROW1')")
        if not ok then error(err, 0) end
    end)
end

---------------------------------------------------------------------------------------------------------------
-- updated_at: no ON UPDATE clause (UTC, docs/contracts.md §C7); the writers set it, and only on a real change

tests['15 mirror upserts move updated_at only for changed rows'] = function(t)
    withDb(t, function()
        local old = '2000-01-01 00:00:00'
        q('UPDATE fredpd_persons SET updated_at = ?', { old })
        q('UPDATE fredpd_vehicles_idx SET updated_at = ?', { old })
        local anna = Mirror.personRow('FPD10001', { firstname = 'Anna', lastname = 'Berg', birthdate = '1994-03-12', gender = 1 })
        local erik = q('SELECT * FROM fredpd_persons WHERE citizenid = ?', { 'FPD10002' })[1]
        local same = {}
        for _, col in ipairs(Mirror.PERSON_COLUMNS) do same[col] = erik[col] end
        same.phone = same.phone and tostring(same.phone):gsub('^', '0') or nil -- the shim read '07…' as a number
        t.eq(Mirror.upsertPersons({ anna, same }), 2)
        t.ok(utcSkew("SELECT updated_at FROM fredpd_persons WHERE citizenid = 'FPD10001'") <= 60, 'changed row: UTC now')
        t.eq(scalar("SELECT DATE_FORMAT(updated_at, '%Y') FROM fredpd_persons WHERE citizenid = 'FPD10002'"), 2000,
            'unchanged row keeps its updated_at')
        -- A change of letter case only is a change (byte comparison, not the _ci collation).
        anna.lastname = 'BERG'
        q("UPDATE fredpd_persons SET updated_at = ? WHERE citizenid = 'FPD10001'", { old })
        Mirror.upsertPersons({ anna })
        t.ok(utcSkew("SELECT updated_at FROM fredpd_persons WHERE citizenid = 'FPD10001'") <= 60, 'case change counts')

        Mirror.upsertVehicles({ { plate = 'ABC12D', citizenid = 'FPD10002', model = 'sultan' },
            { plate = 'KLM34E', citizenid = 'FPD10001', model = 'blista' } })
        t.eq(scalar("SELECT DATE_FORMAT(updated_at, '%Y') FROM fredpd_vehicles_idx WHERE plate = 'ABC12D'"), 2000)
        t.ok(utcSkew("SELECT updated_at FROM fredpd_vehicles_idx WHERE plate = 'KLM34E'") <= 60, 'new owner: UTC now')
        Mirror.backfill(0) -- restore the stub's values for later tests
    end)
end

tests['16 units, officers and callsigns set updated_at in UTC'] = function(t)
    withDb(t, function()
        local old = '2000-01-01 00:00:00'
        local units = helper.readJson('config/units.json')
        Officers.syncUnits(units)
        q('UPDATE fredpd_units SET updated_at = ?', { old })
        Officers.syncUnits(units)
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_units WHERE updated_at > ?", { old }), 0, 'unchanged config: nothing moves')
        Officers.syncUnits({ units = { units.units[1] } })
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_units WHERE updated_at > ?", { old }), 4, 'four units deactivated')
        t.eq(scalar("SELECT DATE_FORMAT(updated_at, '%Y') FROM fredpd_units WHERE code = ?", { units.units[1].code }), 2000)
        Officers.syncUnits({ units = { units.units[1] } })
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_units WHERE updated_at > ?", { old }), 4, 'already inactive: untouched')
        Officers.syncUnits(units)

        local savedId = Perms.getDiscordId
        Perms.getDiscordId = function() return '7102' end
        local ok, err = pcall(function()
            q("INSERT INTO fredpd_officers (citizenid, discord_id, display_name, updated_at) VALUES ('UTC1', '7101', 'x', ?)",
                { old })
            t.ok(utcSkew("SELECT created_at FROM fredpd_officers WHERE citizenid = 'UTC1'") <= 60, 'created_at default')
            Officers.ensureRow(1, { citizenid = 'UTC1', job = { type = 'leo', onduty = false } })
            t.ok(utcSkew("SELECT updated_at FROM fredpd_officers WHERE citizenid = 'UTC1'") <= 60, 'relink sets updated_at')
            q("UPDATE fredpd_officers SET updated_at = ? WHERE citizenid = 'UTC1'", { old })
            Officers.ensureRow(1, { citizenid = 'UTC1', job = { type = 'leo', onduty = false } })
            t.eq(scalar("SELECT DATE_FORMAT(updated_at, '%Y') FROM fredpd_officers WHERE citizenid = 'UTC1'"), 2000,
                'no relink needed: untouched')
            MySQL.update.await(Officers.CALLSIGN_SQL, { 'igv', 'IGV-99', 'UTC1' })
            t.ok(utcSkew("SELECT updated_at FROM fredpd_officers WHERE citizenid = 'UTC1'") <= 60, 'callsign sets updated_at')
        end)
        Perms.getDiscordId = savedId
        q("DELETE FROM fredpd_officers WHERE citizenid = 'UTC1'")
        if not ok then error(err, 0) end
    end)
end

return tests
