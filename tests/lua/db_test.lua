-- SPDX-License-Identifier: GPL-3.0-only
-- Tests for fredpd_core/shared/sha256.lua and fredpd_core/server/db.lua (docs/contracts.md §C7).
-- Pure parts always run; the migration tests run M.migrate() for real through tests/lua/mysql_shim.lua against
-- the database fredpd_test_db_lua and pass with a printed notice when MariaDB is unreachable.
-- Run alone: lua5.4 tests/lua/run.lua db_test
local sha256 = require('shared.sha256')
local db = require('server.db')
local shim = require('mysql_shim')

local LUA_DB = 'fredpd_test_db_lua'
local MIGRATION_DIR = 'db/migrations'
local SEED_DIR = 'db/seed'

local function listMigrations()
    return db.sortNames(shim.listSql(MIGRATION_DIR, db.MIGRATION_PATTERN), db.MIGRATION_PATTERN)
end

local function listSeeds()
    return db.sortNames(shim.listSql(SEED_DIR, db.SEED_PATTERN), db.SEED_PATTERN)
end

local function expectError(fn, needle)
    local ok, err = pcall(fn)
    if ok then error('expected an error containing ' .. needle, 2) end
    if not tostring(err):find(needle, 1, true) then
        error(('expected error containing %q, got %q'):format(needle, tostring(err)), 2)
    end
    return tostring(err)
end

--- Run fn with the shim's globals installed, restoring the previous globals afterwards. Returns false (and prints
--- a notice once) when the database is unreachable.
local notified = false
local function withDb(fn, t)
    local ok, reason = shim.available()
    if not ok then
        if not notified then
            print(('SKIP db_test database tests: MariaDB unreachable (%s)'):format((reason or ''):gsub('%s+$', '')))
            notified = true
        end
        return false
    end
    local saved = { MySQL, LoadResourceFile, GetCurrentResourceName }
    shim.install({ database = LUA_DB })
    local okc, err = pcall(fn, t)
    MySQL, LoadResourceFile, GetCurrentResourceName = saved[1], saved[2], saved[3]
    shim.sessionTimeZone = nil
    if not okc then error(err, 0) end
    return true
end

local function quiet() end

local function statements(sql)
    local out = {}
    for _, st in ipairs(db.splitStatements(sql)) do out[#out + 1] = st.sql end
    return out
end

local tests = {}

---------------------------------------------------------------------------------------------------------------
-- sha256 / checksum

tests['sha256 matches FIPS 180-4 vectors'] = function(t)
    t.eq(sha256.hex(''), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')
    t.eq(sha256.hex('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
    t.eq(sha256.hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1')
    -- 55/56/64 bytes: the padding edge cases
    t.eq(#sha256.digest(('a'):rep(55)), 32)
    t.eq(sha256.hex(('a'):rep(64)), 'ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb')
end

tests['sha256 of every migration equals sha256sum'] = function(t)
    local probe = io.popen('sha256sum --version 2>&1')
    local have = probe and (probe:read('a') or ''):find('sha256sum', 1, true) ~= nil
    if probe then probe:close() end
    if not have then
        print('SKIP db_test sha256sum comparison: no sha256sum on PATH (Node parity in migrations.test.ts still runs)')
        return
    end
    for _, name in ipairs(listMigrations()) do
        -- Hash the normalised bytes on both sides, so a CRLF (Windows) checkout compares like an LF one.
        local normalized = db.normalize(t.readFile(MIGRATION_DIR .. '/' .. name))
        local tmp = os.tmpname()
        local f = assert(io.open(tmp, 'wb'))
        f:write(normalized)
        f:close()
        local p = assert(io.popen("sha256sum '" .. tmp .. "'"))
        local expected = p:read('a'):match('^(%x+)')
        p:close()
        os.remove(tmp)
        t.eq(db.checksum(t.readFile(MIGRATION_DIR .. '/' .. name)), expected, name)
    end
end

tests['checksum ignores BOM and CRLF'] = function(t)
    t.eq(db.normalize('\239\187\191a\r\nb\r\n'), 'a\nb\n')
    t.eq(db.normalize('a\r\r\nb\rc'), 'a\r\nb\rc')
    t.eq(db.checksum('\239\187\191CREATE TABLE x (a INT);\r\n'), db.checksum('CREATE TABLE x (a INT);\n'))
    t.ok(db.checksum('a;\n') ~= db.checksum('a; \n'), 'other whitespace changes count')
end

---------------------------------------------------------------------------------------------------------------
-- splitStatements

tests['split: statements, lines and trailing whitespace'] = function(t)
    local r = db.splitStatements('-- header\nCREATE TABLE a (x INT);\n\nINSERT INTO a VALUES (1) ;  \nSELECT 1;')
    t.eq(#r, 3)
    t.eq(r[1], { sql = 'CREATE TABLE a (x INT)', line = 2 })
    t.eq(r[2], { sql = 'INSERT INTO a VALUES (1)', line = 4 })
    t.eq(r[3], { sql = 'SELECT 1', line = 5 })
end

tests['split: semicolons in quotes do not split'] = function(t)
    t.eq(statements("INSERT INTO t VALUES ('a;b', \"c;d\", 'it''s;', 'x\\';y');\nSELECT `we;ird`;"), {
        "INSERT INTO t VALUES ('a;b', \"c;d\", 'it''s;', 'x\\';y')",
        'SELECT `we;ird`',
    })
    local r = db.splitStatements("SELECT 'multi\nline;\nstring';\nSELECT 2;")
    t.eq(r[2].line, 4, 'lines inside strings are counted')
end

tests['split: comments'] = function(t)
    t.eq(statements('# hash; comment\n/* block ; comment\n*/ SELECT 1 /* inner ; */ -- tail;\n;\nSELECT 2;'), {
        'SELECT 1 /* inner ; */ -- tail;',
        'SELECT 2',
    })
    t.eq(statements('SELECT 1--1;'), { 'SELECT 1--1' }, '-- without a following space is not a comment')
    t.eq(statements('/*!40101 SET NAMES utf8mb4 */;'), { '/*!40101 SET NAMES utf8mb4 */' })
    t.eq(statements(';;\nSELECT 1;;'), { 'SELECT 1' }, 'empty statements are dropped')
    t.eq(#db.splitStatements('-- only a comment\n\n'), 0)
end

tests['split: CRLF and BOM give the same statements'] = function(t)
    local lf = 'CREATE TABLE a (\n  x INT\n);\nSELECT 1;\n'
    local crlf = '\239\187\191' .. lf:gsub('\n', '\r\n')
    t.eq(db.splitStatements(crlf), db.splitStatements(lf))
end

tests['split: @if-table-exists directive'] = function(t)
    local r = db.splitStatements('SELECT 1;\n-- @if-table-exists player_vehicles\nCREATE INDEX IF NOT EXISTS plate ON player_vehicles (plate);\nSELECT 2;')
    t.eq(r[1].ifTableExists, nil)
    t.eq(r[2], { sql = 'CREATE INDEX IF NOT EXISTS plate ON player_vehicles (plate)', ifTableExists = 'player_vehicles', line = 3 })
    t.eq(r[3].ifTableExists, nil, 'a directive applies to one statement only')
    t.eq(db.splitStatements('--   @if-table-exists  players  \nSELECT 1;')[1].ifTableExists, 'players')
    t.eq(db.splitStatements('-- not a @directive\nSELECT 1;')[1].ifTableExists, nil)
end

tests['split: malformed input raises with a line number'] = function(t)
    expectError(function() db.splitStatements('-- @if-table-exist players\nSELECT 1;') end,
        'line 1: unknown or malformed directive: -- @if-table-exist players')
    expectError(function() db.splitStatements('-- @if-table-exists\nSELECT 1;') end, 'malformed directive')
    expectError(function() db.splitStatements('-- @if-table-exists a b\nSELECT 1;') end, 'malformed directive')
    expectError(function() db.splitStatements('SELECT\n-- @if-table-exists a\n1;') end, 'line 2: directive inside a statement')
    expectError(function() db.splitStatements('-- @if-table-exists a\n-- @if-table-exists b\nSELECT 1;') end,
        'line 2: two directives before one statement')
    expectError(function() db.splitStatements('SELECT 1;\n-- @if-table-exists a\n') end,
        'line 2: directive not followed by a statement')
    expectError(function() db.splitStatements('-- @if-table-exists a\n;') end, 'directive not followed by a statement')
    expectError(function() db.splitStatements('SELECT 1;\n\nSELECT 2') end, 'line 3: statement not terminated by ;')
    expectError(function() db.splitStatements("SELECT 'abc;\n") end, "line 1: unterminated ' quote")
    expectError(function() db.splitStatements('SELECT 1;\n/* open') end, 'line 2: unterminated /* comment')
end

tests['split: every migration file parses; only 002 is conditional'] = function(t)
    local files = listMigrations()
    t.ok(#files >= 8, 'expected 001-008')
    for _, name in ipairs(files) do
        local list = db.splitStatements(t.readFile(MIGRATION_DIR .. '/' .. name))
        t.ok(#list > 0, name .. ' has statements')
        for _, st in ipairs(list) do
            if st.ifTableExists then
                t.eq(name, '002_index.sql', 'unexpected conditional statement')
                t.eq(st.ifTableExists, 'player_vehicles')
                t.eq(st.sql, 'CREATE INDEX IF NOT EXISTS plate ON player_vehicles (plate)')
            end
        end
    end
end

tests['migrations follow the table conventions'] = function(t)
    for _, name in ipairs(listMigrations()) do
        if tonumber(name:sub(1, 3)) <= 8 then -- 009+ belong to other modules
            for _, st in ipairs(db.splitStatements(t.readFile(MIGRATION_DIR .. '/' .. name))) do
                if st.sql:find('^CREATE TABLE') then
                    local tbl = st.sql:match('^CREATE TABLE IF NOT EXISTS ([%w_]+)')
                    t.ok(tbl, name .. ': CREATE TABLE without IF NOT EXISTS')
                    t.ok(tbl:find('^fredpd_'), tbl .. ': not a fredpd_ table')
                    t.ok(st.sql:find('ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci$'), tbl .. ': engine/charset')
                    t.ok(st.sql:find('\n  created_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),', 1, true), tbl .. ': created_at')
                end
            end
        end
    end
end

tests['migrations and seeds never use the session clock (docs/contracts.md §C7)'] = function(t)
    -- Every file, including other modules' (009+): times are UTC whatever the MariaDB time zone is.
    local files = {}
    for _, name in ipairs(listMigrations()) do files[#files + 1] = MIGRATION_DIR .. '/' .. name end
    for _, name in ipairs(listSeeds()) do files[#files + 1] = SEED_DIR .. '/' .. name end
    for _, path in ipairs(files) do
        for _, st in ipairs(db.splitStatements(t.readFile(path))) do
            local upper = st.sql:upper()
            for _, bad in ipairs({ 'CURRENT_TIMESTAMP', 'NOW()', 'LOCALTIME', 'SYSDATE(', 'CURDATE(', 'CURTIME(' }) do
                t.ok(not upper:find(bad, 1, true), ('%s line %d: uses %s (write UTC_TIMESTAMP())'):format(path, st.line, bad))
            end
            t.ok(not upper:find('ON UPDATE%s+UTC') and not upper:find('ON UPDATE%s+CURRENT'),
                ('%s line %d: ON UPDATE timestamp (writers set updated_at themselves)'):format(path, st.line))
            -- One spelling: the parenthesised expression default (MariaDB accepts both, MySQL 8 only this one).
            t.ok(not upper:find('DEFAULT%s+UTC_TIMESTAMP'), ('%s line %d: write DEFAULT (UTC_TIMESTAMP())'):format(path, st.line))
        end
    end
end

tests['no ? in migration or seed statements (oxmysql would bind it to NULL)'] = function(t)
    -- oxmysql pads every `?` with NULL even when a statement has no parameters, inside quotes and comments too.
    local files = {}
    for _, name in ipairs(listMigrations()) do files[#files + 1] = MIGRATION_DIR .. '/' .. name end
    for _, name in ipairs(listSeeds()) do files[#files + 1] = SEED_DIR .. '/' .. name end
    t.ok(#files >= 10, 'expected migrations and seeds')
    for _, path in ipairs(files) do
        for _, st in ipairs(db.splitStatements(t.readFile(path))) do
            t.ok(not st.sql:find('?', 1, true), ('%s line %d: statement contains ?'):format(path, st.line))
        end
    end
end

tests['MIGRATIONS_TABLE_DDL equals the statement in 001_core.sql'] = function(t)
    local first = db.splitStatements(t.readFile(MIGRATION_DIR .. '/001_core.sql'))[1]
    t.eq(first.sql, db.MIGRATIONS_TABLE_DDL)
end

tests['sortNames filters and sorts by bytes'] = function(t)
    t.eq(db.sortNames({ '010_b.sql', 'readme.md', '002_a.sql', '001_Z.sql', '001_a.sql', 'x.sql', 7 }, db.MIGRATION_PATTERN),
        { '001_Z.sql', '001_a.sql', '002_a.sql', '010_b.sql' })
    t.eq(db.sortNames({ 'b.sql', '.hidden.sql', 'a.sql' }, db.SEED_PATTERN), { 'a.sql', 'b.sql' })
end

---------------------------------------------------------------------------------------------------------------
-- migrate() without a database (fake MySQL), for the paths a real DB cannot easily reach

tests['migrate: missing migrations/index.json is a clear error'] = function()
    local saved = { MySQL, LoadResourceFile }
    MySQL = { query = { await = function() return {} end } }
    LoadResourceFile = function() return nil end
    local ok, err = pcall(db.migrate, { resource = 'fredpd_core', log = quiet })
    MySQL, LoadResourceFile = saved[1], saved[2]
    assert(not ok and tostring(err):find('migrations/index.json is missing', 1, true), tostring(err))
end

---------------------------------------------------------------------------------------------------------------
-- migrate() against MariaDB (fredpd_test_db_lua)

tests['db: a +02:00 session migrates and every default is UTC'] = function(t)
    withDb(function()
        shim.resetDatabase(LUA_DB, false)
        -- A server whose default zone is not UTC (Windows MariaDB: SYSTEM = Europe/Stockholm), as oxmysql sees it.
        shim.sessionTimeZone = '+02:00'
        t.eq(MySQL.scalar.await('SELECT @@session.time_zone'), '+02:00')
        t.eq(MySQL.scalar.await('SELECT TIMESTAMPDIFF(MINUTE, UTC_TIMESTAMP(), NOW())'), 120)
        local r = db.migrate({ log = quiet })
        t.eq(r.applied, listMigrations())
        -- applied_at/created_at of the bookkeeping rows and created_at of a seeded row are UTC, not session time.
        local skew = MySQL.single.await('SELECT MAX(ABS(TIMESTAMPDIFF(SECOND, applied_at, UTC_TIMESTAMP()))) AS applied, '
            .. 'MAX(ABS(TIMESTAMPDIFF(SECOND, created_at, UTC_TIMESTAMP()))) AS created FROM fredpd_migrations')
        t.ok(skew.applied <= 60 and skew.created <= 60, 'fredpd_migrations skew ' .. json.encode(skew))
        t.ok(MySQL.scalar.await('SELECT MAX(ABS(TIMESTAMPDIFF(SECOND, created_at, UTC_TIMESTAMP()))) FROM fredpd_charges')
            <= 60, 'seeded created_at is UTC')
        -- A seed re-apply refreshes applied_at in UTC too.
        MySQL.update.await("UPDATE fredpd_migrations SET checksum = REPEAT('0', 64), applied_at = '2000-01-01 00:00:00' "
            .. "WHERE id = 'seed/charges_sv.sql'")
        t.eq(db.migrate({ log = quiet }).seeded, { 'seed/charges_sv.sql' })
        t.ok(MySQL.scalar.await("SELECT ABS(TIMESTAMPDIFF(SECOND, applied_at, UTC_TIMESTAMP())) FROM fredpd_migrations "
            .. "WHERE id = 'seed/charges_sv.sql'") <= 60, 'seed applied_at is UTC')
    end, t)
end

tests['db: a migration recorded concurrently by another runner is tolerated'] = function(t)
    withDb(function()
        shim.resetDatabase(LUA_DB, false)
        db.migrate({ log = quiet, seed = false })
        local sum = db.checksum(t.readFile(MIGRATION_DIR .. '/008_tablets.sql'))
        -- Replay 008 while "another runner" records it between our read of fredpd_migrations and our insert.
        local function replayWith(otherChecksum)
            MySQL.update.await("DELETE FROM fredpd_migrations WHERE id = '008_tablets.sql'")
            local realQuery = MySQL.query.await
            MySQL.query.await = function(sql, params)
                if sql:find('^INSERT INTO fredpd_migrations') and params and params[1] == '008_tablets.sql' then
                    realQuery('INSERT INTO fredpd_migrations (id, checksum) VALUES (?, ?)', { '008_tablets.sql', otherChecksum })
                end
                return realQuery(sql, params)
            end
            local ok, res = pcall(db.migrate, { log = quiet, seed = false })
            MySQL.query.await = realQuery
            return ok, res
        end
        local ok, r = replayWith(sum)
        t.ok(ok, tostring(r))
        t.eq(r.applied, { '008_tablets.sql' })

        ok, r = replayWith(('b'):rep(64))
        t.ok(not ok and tostring(r):find('008_tablets.sql was recorded concurrently by another runner with checksum bbbbbbbbbbbb', 1, true),
            tostring(r))
    end, t)
end

tests['db: qbx tables join only with an explicit COLLATE (stub uses upstream collations)'] = function(t)
    withDb(function()
        shim.resetDatabase(LUA_DB, true)
        db.migrate({ log = quiet, seed = false })
        MySQL.insert.await('INSERT INTO fredpd_identities (discord_id, license) VALUES (?, ?)',
            { '111', 'license:0000000000000000000000000000000000000002' })
        -- The documented character list (docs/modules/db.md, "Joining qbx tables").
        local rows = MySQL.query.await('SELECT p.citizenid FROM fredpd_identities i JOIN players p '
            .. 'ON p.license = i.license COLLATE utf8mb4_unicode_ci WHERE i.discord_id = ? ORDER BY p.citizenid', { '111' })
        t.eq(rows, { { citizenid = 'FPD10002' }, { citizenid = 'FPD10003' } })
        -- COLLATE on the driving side keeps players.license usable (docs/modules/db.md says so; pin it here).
        local plan = MySQL.query.await('EXPLAIN SELECT p.citizenid FROM fredpd_identities i JOIN players p '
            .. 'ON p.license = i.license COLLATE utf8mb4_unicode_ci WHERE i.discord_id = ?', { '111' })
        local players
        for _, step in ipairs(plan) do
            if step.table == 'p' then players = step end
        end
        t.ok(players, 'EXPLAIN has a row for players')
        t.ok(players.type == 'ref' or players.type == 'range', 'players access type: ' .. tostring(players.type))
        t.eq(players.key, 'license')
        expectError(function()
            MySQL.query.await('SELECT p.citizenid FROM fredpd_identities i JOIN players p ON p.license = i.license')
        end, 'Illegal mix of collations')
    end, t)
end

tests['db: fresh database migrates, second run is a no-op'] = function(t)
    withDb(function()
        shim.resetDatabase(LUA_DB, false)
        local files, seeds = listMigrations(), {}
        -- Seeds of other modules may be added to db/seed; expect whatever is there.
        for k, name in ipairs(listSeeds()) do seeds[k] = db.SEED_ID_PREFIX .. name end
        t.ok(#seeds >= 1, 'expected at least charges_sv.sql')
        local r1 = db.migrate({ log = quiet })
        t.eq(r1.applied, files)
        t.eq(r1.seeded, seeds)
        t.eq(r1.skipped, { '002_index.sql#3' }, 'player_vehicles missing -> conditional index skipped')
        t.eq(MySQL.scalar.await('SELECT COUNT(*) FROM fredpd_migrations'), #files + #seeds)

        local r2 = db.migrate({ log = quiet })
        t.eq(r2, { applied = {}, seeded = {}, skipped = {} })
    end, t)
end

tests['db: @if-table-exists runs when the table exists'] = function(t)
    withDb(function()
        shim.resetDatabase(LUA_DB, true)
        local r = db.migrate({ log = quiet, seed = false })
        t.eq(r.skipped, {})
        t.eq(r.seeded, {})
        t.eq(MySQL.scalar.await(
            "SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = 'player_vehicles' AND index_name = 'plate'"), 1)
    end, t)
end

tests['db: seeds load the charge catalogue and default rules'] = function(t)
    withDb(function()
        shim.resetDatabase(LUA_DB, false)
        db.migrate({ log = quiet })
        local charges = MySQL.scalar.await('SELECT COUNT(*) FROM fredpd_charges')
        t.ok(charges >= 110, 'charges: ' .. tostring(charges))
        t.eq(MySQL.scalar.await('SELECT COUNT(DISTINCT code) FROM fredpd_charges'), charges)
        t.eq(MySQL.scalar.await("SELECT COUNT(*) FROM fredpd_charges WHERE class NOT IN ('ordningsbot','bot','fängelse')"), 0)
        t.ok(MySQL.scalar.await('SELECT COUNT(*) FROM fredpd_visibility_rules') > 0, 'visibility rules seeded')

        -- A changed seed is re-applied (idempotently), not an error; admin edits to `active` survive.
        MySQL.update.await("UPDATE fredpd_charges SET active = 0, fine = 1 WHERE code = 'BRB-001'")
        MySQL.update.await("UPDATE fredpd_charges SET updated_at = '2000-01-01 00:00:00'")
        MySQL.update.await("UPDATE fredpd_migrations SET checksum = REPEAT('0', 64) WHERE id = 'seed/charges_sv.sql'")
        local r = db.migrate({ log = quiet })
        t.eq(r.applied, {})
        t.eq(r.seeded, { 'seed/charges_sv.sql' })
        local row = MySQL.single.await("SELECT active, fine FROM fredpd_charges WHERE code = 'BRB-001'")
        t.eq(row, { active = 0, fine = 0 })
        t.eq(MySQL.scalar.await('SELECT COUNT(*) FROM fredpd_charges'), charges)
        -- updated_at moves only for the row whose values the seed changed (no ON UPDATE clause, §C7).
        t.eq(MySQL.scalar.await("SELECT COUNT(*) FROM fredpd_charges WHERE updated_at > '2000-01-01 00:00:00'"), 1)
        t.ok(MySQL.scalar.await("SELECT ABS(TIMESTAMPDIFF(SECOND, updated_at, UTC_TIMESTAMP())) FROM fredpd_charges "
            .. "WHERE code = 'BRB-001'") <= 60, 'changed row: updated_at = UTC now')
    end, t)
end

tests['db: checksum drift is an error and nothing runs'] = function(t)
    withDb(function()
        shim.resetDatabase(LUA_DB, false)
        db.migrate({ log = quiet, seed = false })
        MySQL.update.await("DROP TABLE fredpd_tablets")
        MySQL.update.await("DELETE FROM fredpd_migrations WHERE id = '008_tablets.sql'")
        MySQL.update.await("UPDATE fredpd_migrations SET checksum = REPEAT('a', 64) WHERE id = '003_records.sql'")
        local err = expectError(function() db.migrate({ log = quiet }) end, 'checksum mismatch')
        t.ok(err:find('003_records.sql', 1, true), err)
        t.eq(MySQL.scalar.await("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'fredpd_tablets'"), 0,
            'pending 008 must not run when an applied migration drifted')
        t.eq(MySQL.scalar.await("SELECT COUNT(*) FROM fredpd_migrations WHERE id LIKE 'seed/%'"), 0, 'no seeds either')
    end, t)
end

tests['db: a malformed migration fails with its file name and records nothing'] = function(t)
    withDb(function()
        shim.resetDatabase(LUA_DB, false)
        -- A migrations folder holding only a broken file (plain Lua cannot make a temp dir; mkdir through the shell).
        local dir = os.tmpname()
        os.remove(dir)
        local isWindows = package.config:sub(1, 1) == '\\'
        assert(os.execute((isWindows and 'mkdir "%s"' or "mkdir '%s'"):format(dir)), 'mkdir ' .. dir)
        local path = dir .. '/999_bad.sql'
        local f = assert(io.open(path, 'wb'))
        f:write('SELECT 1;\n-- @if-table-exist players\nSELECT 2;\n')
        f:close()
        local savedDir = shim.migrationsDir
        shim.migrationsDir = dir
        local ok, err = pcall(db.migrate, { log = quiet, seed = false })
        shim.migrationsDir = savedDir
        os.remove(path)
        os.remove(dir)
        t.ok(not ok, 'expected an error')
        t.eq(tostring(err), '999_bad.sql: line 2: unknown or malformed directive: -- @if-table-exist players')
        t.eq(MySQL.scalar.await('SELECT COUNT(*) FROM fredpd_migrations'), 0)
    end, t)
end

tests['db: nextSeq counts per type and year'] = function(t)
    withDb(function()
        shim.resetDatabase(LUA_DB, false)
        db.migrate({ log = quiet, seed = false })
        t.eq(db.nextSeq('caseNumber', 2026), 1)
        t.eq(db.nextSeq('caseNumber', 2026), 2)
        t.eq(db.nextSeq('caseNumber', 2027), 1)
        t.eq(db.nextSeq('caseNumber', 2026), 3)
        t.eq(db.nextSeq('other', 0), 1)
        t.eq(db.scalar('SELECT value FROM fredpd_sequences WHERE seq_type = ? AND year = ?', { 'caseNumber', 2026 }), 3)
        db.update("UPDATE fredpd_sequences SET updated_at = '2000-01-01 00:00:00'")
        t.eq(db.nextSeq('other', 0), 2)
        t.ok(db.scalar("SELECT ABS(TIMESTAMPDIFF(SECOND, updated_at, UTC_TIMESTAMP())) FROM fredpd_sequences "
            .. "WHERE seq_type = 'other'") <= 60, 'nextSeq sets updated_at in UTC')
    end, t)
end

tests['db: query helpers wrap oxmysql'] = function(t)
    withDb(function()
        shim.resetDatabase(LUA_DB, false)
        db.migrate({ log = quiet, seed = false })
        local id = db.insert('INSERT INTO fredpd_tablets (serial, owner_citizenid) VALUES (?, ?)', { 'T-1', 'ABC123' })
        t.eq(id, 0, 'no AUTO_INCREMENT column -> insert id 0')
        t.eq(db.update('UPDATE fredpd_tablets SET revoked = 1 WHERE serial = ?', { 'T-1' }), 1)
        t.eq(db.single('SELECT serial, revoked FROM fredpd_tablets WHERE serial = ?', { 'T-1' }), { serial = 'T-1', revoked = 1 })
        t.eq(#db.query('SELECT * FROM fredpd_tablets'), 1)
        t.eq(db.scalar("SELECT owner_citizenid FROM fredpd_tablets WHERE serial = 'T-1'"), 'ABC123')
        t.eq(db.transaction({ { query = 'INSERT INTO fredpd_tablets (serial) VALUES (?)', values = { 'T-2' } },
            { query = 'INSERT INTO fredpd_tablets (serial) VALUES (?)', values = { 'T-1' } } }), false, 'duplicate key rolls back')
        t.eq(db.scalar('SELECT COUNT(*) FROM fredpd_tablets'), 1)
    end, t)
end

return tests
