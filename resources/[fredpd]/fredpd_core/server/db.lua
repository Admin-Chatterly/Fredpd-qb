-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_core database module: the canonical migration runner (docs/contracts.md §C7) and thin oxmysql helpers.
--
-- Load with ox_lib require from fredpd_core server code: `local db = require 'server.db'`. It needs oxmysql's
-- `@oxmysql/lib/MySQL.lua` among the resource's server_scripts, and `migrations/` (copied from db/migrations and
-- db/seed with index.json files by scripts/build.mjs). Nothing touches FiveM natives or MySQL at load time, so the
-- pure parts (normalize, checksum, splitStatements, sortNames) run under plain Lua 5.4 in tests/lua/db_test.lua,
-- and tests/lua/mysql_shim.lua lets M.migrate() run against a real MariaDB outside FiveM.
--
-- The same algorithm is implemented by scripts/migrate.mjs (mysql2); packages/types/test/migrations.test.ts checks
-- that both produce identical fredpd_migrations rows and schemas. Keep the two in step.
--
-- Usage on start (one-shot, not a loop; MySQL.ready runs its callback in a thread so .await works):
--   MySQL.ready(function()
--       local ok, err = pcall(db.migrate)
--       if not ok then error(('database migration failed: %s'):format(err)) end
--   end)
--
-- The query helpers are raw access. Writes to fredpd_* tables from gameplay code must go through the fredpd_core
-- helpers that also write fredpd_audit (CLAUDE.md), not straight through these.

local sha256
do
    -- ox_lib resolves a bare module name against the *calling* resource; fall back to the explicit path when
    -- another resource loads this file.
    local ok, mod = pcall(require, 'shared.sha256')
    sha256 = ok and mod or require('@fredpd_core.shared.sha256')
end

local M = {}

-- Keep identical to MIGRATIONS_TABLE_DDL in scripts/migrate.mjs and to the statement in 001_core.sql.
M.MIGRATIONS_TABLE_DDL = [[CREATE TABLE IF NOT EXISTS fredpd_migrations (
  id VARCHAR(64) NOT NULL,
  checksum CHAR(64) NOT NULL,
  applied_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  created_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci]]

M.SEED_ID_PREFIX = 'seed/'
M.MIGRATION_PATTERN = '^%d%d%d_.+%.sql$'
M.SEED_PATTERN = '^[^.].*%.sql$'

--- Atomic {{seq}} allocation (fredpd_sequences, 001_core.sql). The statement's insert id is the new value:
--- LAST_INSERT_ID(expr) sets it both on first insert and on the duplicate-key update. updated_at is set here
--- because FredPD tables have no ON UPDATE clause (docs/contracts.md §C7: UTC_TIMESTAMP(), never the session clock).
M.NEXT_SEQ_SQL = 'INSERT INTO fredpd_sequences (seq_type, year, value) VALUES (?, ?, LAST_INSERT_ID(1)) '
    .. 'ON DUPLICATE KEY UPDATE value = LAST_INSERT_ID(value + 1), updated_at = UTC_TIMESTAMP()'

local TABLE_EXISTS_SQL =
    'SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ?'
-- Tolerant of a concurrent runner (the Lua runner cannot hold GET_LOCK across oxmysql's pool): a row that another
-- runner inserted meanwhile is kept and its checksum compared afterwards (recordMigration).
local RECORD_MIGRATION_SQL = 'INSERT INTO fredpd_migrations (id, checksum) VALUES (?, ?) ON DUPLICATE KEY UPDATE id = id'
local RECORDED_CHECKSUM_SQL = 'SELECT checksum FROM fredpd_migrations WHERE id = ?'
local RECORD_SEED_SQL = 'INSERT INTO fredpd_migrations (id, checksum) VALUES (?, ?) '
    .. 'ON DUPLICATE KEY UPDATE checksum = VALUES(checksum), applied_at = UTC_TIMESTAMP()'

---------------------------------------------------------------------------------------------------------------
-- Pure parts (mirrored in scripts/migrate.mjs)

-- ASCII whitespace, the same set the JS splitter uses: space \t \n \r \f \v.
local WS = { [32] = true, [9] = true, [10] = true, [13] = true, [12] = true, [11] = true }
local BYTE_NL, BYTE_DASH, BYTE_HASH, BYTE_SLASH, BYTE_STAR = 10, 45, 35, 47, 42
local BYTE_SEMI, BYTE_BANG, BYTE_M, BYTE_BACKSLASH = 59, 33, 77, 92
local BYTE_SQUOTE, BYTE_DQUOTE, BYTE_BACKTICK = 39, 34, 96

--- Drop a UTF-8 BOM and turn CRLF into LF (applied before hashing and splitting).
---@param content string
---@return string
function M.normalize(content)
    if content:sub(1, 3) == '\239\187\191' then content = content:sub(4) end
    return (content:gsub('\r\n', '\n'))
end

--- sha256 hex of the normalised content; equals checksum() in scripts/migrate.mjs.
---@param content string
---@return string
function M.checksum(content)
    return sha256.hex(M.normalize(content))
end

--- Byte-order comparison (Lua's `<` on strings follows the C locale's collation).
local function byteLess(a, b)
    local la, lb = #a, #b
    for k = 1, math.min(la, lb) do
        local x, y = a:byte(k), b:byte(k)
        if x ~= y then return x < y end
    end
    return la < lb
end

--- Copy of `names` filtered by a Lua pattern and sorted by byte order (as migrate.mjs sorts directory entries).
---@param names string[]
---@param pattern string
---@return string[]
function M.sortNames(names, pattern)
    local out = {}
    for _, name in ipairs(names) do
        if type(name) == 'string' and name:find(pattern) then out[#out + 1] = name end
    end
    table.sort(out, byteLess)
    return out
end

local function trimEnd(s)
    return (s:gsub('[ \t\n\r\f\v]+$', ''))
end

--- Split a migration/seed file into statements; same rules and error texts as splitStatements() in
--- scripts/migrate.mjs (see there). Returns { { sql = string, ifTableExists = string|nil, line = integer }, ... }.
--- Errors are raised as 'line N: message'.
---@param source string
---@return { sql: string, ifTableExists: string?, line: integer }[]
function M.splitStatements(source)
    local sql = M.normalize(source)
    local n = #sql
    local out = {}
    local i, line = 1, 1
    local start, startLine = nil, 0 -- start of the current statement, nil between statements
    local directive = nil           -- { table = name, line = n }

    local function fail(msg, at)
        error(('line %d: %s'):format(at, msg), 0)
    end
    -- Skip a block comment opened at i; returns the index after `*/`.
    local function skipBlock()
        local s, e = sql:find('*/', i + 2, true)
        if not s then fail('unterminated /* comment', line) end
        for _ in sql:sub(i, s - 1):gmatch('\n') do line = line + 1 end
        return e + 1
    end

    while i <= n do
        local c = sql:byte(i)
        local c2 = sql:byte(i + 1)
        if c == BYTE_NL then
            line = line + 1
            i = i + 1
        elseif WS[c] then
            i = i + 1
        elseif (c == BYTE_DASH and c2 == BYTE_DASH and (i + 2 > n or WS[sql:byte(i + 2)])) or c == BYTE_HASH then
            local e = sql:find('\n', i, true) or (n + 1)
            local text = sql:sub(i, e - 1)
            if c == BYTE_DASH and text:find('^%-%-[ \t]*@') then
                if start then fail('directive inside a statement', line) end
                if directive then fail('two directives before one statement', line) end
                local tbl = text:match('^%-%-[ \t]*@if%-table%-exists[ \t]+([A-Za-z0-9_$]+)[ \t]*$')
                if not tbl then fail(('unknown or malformed directive: %s'):format(trimEnd(text)), line) end
                directive = { table = tbl, line = line }
            end
            i = e -- the newline is counted by the loop
        elseif c == BYTE_SLASH and c2 == BYTE_STAR then
            local c3, c4 = sql:byte(i + 2), sql:byte(i + 3)
            local executable = c3 == BYTE_BANG or (c3 == BYTE_M and c4 == BYTE_BANG)
            if executable and not start then
                start, startLine = i, line
            end
            i = skipBlock()
        elseif c == BYTE_SEMI then
            if not start then
                -- empty statement (e.g. `;;`): nothing to run
                if directive then fail('directive not followed by a statement', directive.line) end
            else
                out[#out + 1] = {
                    sql = trimEnd(sql:sub(start, i - 1)),
                    ifTableExists = directive and directive.table or nil,
                    line = startLine,
                }
                start, directive = nil, nil
            end
            i = i + 1
        else
            if not start then
                start, startLine = i, line
            end
            if c == BYTE_SQUOTE or c == BYTE_DQUOTE or c == BYTE_BACKTICK then
                local quoteLine = line
                local j = i + 1
                local closed = false
                repeat
                    if j > n then fail(('unterminated %s quote'):format(string.char(c)), quoteLine) end
                    local d = sql:byte(j)
                    if d == BYTE_BACKSLASH and c ~= BYTE_BACKTICK then
                        if sql:byte(j + 1) == BYTE_NL then line = line + 1 end
                        j = j + 2
                    else
                        if d == BYTE_NL then line = line + 1 end
                        if d == c then
                            if sql:byte(j + 1) == c then
                                j = j + 2
                            else
                                closed = true
                            end
                        else
                            j = j + 1
                        end
                    end
                until closed
                i = j + 1
            else
                i = i + 1
            end
        end
    end
    if start then fail('statement not terminated by ;', startLine) end
    if directive then fail('directive not followed by a statement', directive.line) end
    return out
end

---------------------------------------------------------------------------------------------------------------
-- Thin oxmysql wrappers (must run inside a thread/coroutine, like every oxmysql .await call)

---@param sql string
---@param params table?
function M.query(sql, params) return MySQL.query.await(sql, params) end

---@param sql string
---@param params table?
function M.scalar(sql, params) return MySQL.scalar.await(sql, params) end

---@param sql string
---@param params table?
function M.single(sql, params) return MySQL.single.await(sql, params) end

--- Returns the insert id.
---@param sql string
---@param params table?
function M.insert(sql, params) return MySQL.insert.await(sql, params) end

--- Returns the number of affected rows.
---@param sql string
---@param params table?
function M.update(sql, params) return MySQL.update.await(sql, params) end

--- queries: { { query = sql, values = params? }, ... }; returns true when committed.
---@param queries table
---@param params table?
function M.transaction(queries, params) return MySQL.transaction.await(queries, params) end

--- Allocate the next {{seq}} value for (seqType, year): 1, 2, 3 ... per type per year.
---@param seqType string e.g. 'caseNumber'
---@param year integer Europe/Stockholm year, or 0 for a counter that never resets
---@return integer
function M.nextSeq(seqType, year)
    local id = MySQL.insert.await(M.NEXT_SEQ_SQL, { seqType, year })
    if type(id) ~= 'number' or id < 1 then error(('nextSeq(%s, %s): no insert id'):format(seqType, year), 2) end
    return math.tointeger(id) or id
end

---------------------------------------------------------------------------------------------------------------
-- Migration runner

local function tableExists(name)
    return (tonumber(MySQL.scalar.await(TABLE_EXISTS_SQL, { name })) or 0) > 0
end

--- Read `<dir>/index.json` from the resource and return its file names filtered by `pattern`, byte-sorted.
local function readIndex(resource, dir, pattern, required)
    local raw = LoadResourceFile(resource, dir .. '/index.json')
    if not raw then
        if required then
            error(('%s/index.json is missing from %s; run scripts/build.mjs to copy db/migrations'):format(dir, resource), 0)
        end
        return {}
    end
    local ok, list = pcall(json.decode, raw)
    if not ok or type(list) ~= 'table' then error(('%s/index.json is not a JSON array'):format(dir), 0) end
    return M.sortNames(list, pattern)
end

local function loadFile(resource, path)
    local raw = LoadResourceFile(resource, path)
    if not raw then error(('%s is listed in index.json but missing from %s'):format(path, resource), 0) end
    local text = M.normalize(raw)
    return text, sha256.hex(text)
end

--- Statements to run for a file: conditional ones whose table is missing are dropped (and logged).
local function runnable(id, text, log, skipped)
    local ok, statements = pcall(M.splitStatements, text)
    if not ok then error(('%s: %s'):format(id, statements), 0) end
    local out = {}
    for k, st in ipairs(statements) do
        if st.ifTableExists and not tableExists(st.ifTableExists) then
            log(('%s: skipped statement %d (line %d), table %s does not exist'):format(id, k, st.line, st.ifTableExists))
            skipped[#skipped + 1] = ('%s#%d'):format(id, k)
        else
            out[#out + 1] = { sql = st.sql, line = st.line, index = k }
        end
    end
    return out
end

--- Record an applied migration. If another runner recorded it meanwhile, its row stays and must carry the same
--- checksum (same text as recordMigration() in scripts/migrate.mjs).
local function recordMigration(f)
    MySQL.query.await(RECORD_MIGRATION_SQL, { f.id, f.checksum })
    local sum = tostring(MySQL.scalar.await(RECORDED_CHECKSUM_SQL, { f.id }))
    if sum ~= f.checksum then
        error(('%s was recorded concurrently by another runner with checksum %s…, file %s…'):format(f.id, sum:sub(1, 12),
            f.checksum:sub(1, 12)), 0)
    end
end

local function statementError(id, st, err)
    local head = (st.sql:match('^[^\n]*') or ''):sub(1, 80)
    return ('%s: statement %d (line %d) failed: %s\n  %s'):format(id, st.index, st.line, tostring(err), head)
end

--- Apply pending migrations, then (unless opts.seed == false) new or changed seeds.
--- Raises on any failure, including (checked before anything runs) a checksum mismatch for an applied migration.
--- Works in any MariaDB time zone: every timestamp default is (UTC_TIMESTAMP()) (docs/contracts.md §C7).
---@param opts { seed: boolean?, log: fun(msg: string)?, resource: string? }?
---@return { applied: string[], seeded: string[], skipped: string[] }
function M.migrate(opts)
    opts = opts or {}
    local log = opts.log or function(msg) print(('[fredpd_core:db] %s'):format(msg)) end
    local resource = opts.resource or GetCurrentResourceName()
    local result = { applied = {}, seeded = {}, skipped = {} }

    MySQL.query.await(M.MIGRATIONS_TABLE_DDL)
    local applied = {}
    for _, row in ipairs(MySQL.query.await('SELECT id, checksum FROM fredpd_migrations') or {}) do
        applied[tostring(row.id)] = tostring(row.checksum)
    end

    local files = {}
    for _, name in ipairs(readIndex(resource, 'migrations', M.MIGRATION_PATTERN, true)) do
        if #name > 64 then error(('migration file name longer than 64 characters: %s'):format(name), 0) end
        local text, sum = loadFile(resource, 'migrations/' .. name)
        files[#files + 1] = { id = name, text = text, checksum = sum }
    end

    -- Fail before touching anything if an applied migration was edited.
    local drift, known = {}, {}
    for _, f in ipairs(files) do
        known[f.id] = true
        local sum = applied[f.id]
        if sum and sum ~= f.checksum then
            drift[#drift + 1] = ('%s (applied %s…, file %s…)'):format(f.id, sum:sub(1, 12), f.checksum:sub(1, 12))
        end
    end
    if #drift > 0 then
        error(('checksum mismatch for applied migration(s): %s. Never edit an applied migration; restore it and '
            .. 'add a new NNN_*.sql instead.'):format(table.concat(drift, ', ')), 0)
    end
    for id in pairs(applied) do
        if id:sub(1, #M.SEED_ID_PREFIX) ~= M.SEED_ID_PREFIX and not known[id] then
            log(('warning: %s is applied but its file is missing'):format(id))
        end
    end

    for _, f in ipairs(files) do
        if not applied[f.id] then
            for _, st in ipairs(runnable(f.id, f.text, log, result.skipped)) do
                local ok, err = pcall(MySQL.query.await, st.sql)
                if not ok then error(statementError(f.id, st, err), 0) end
            end
            recordMigration(f)
            result.applied[#result.applied + 1] = f.id
            log(('applied %s'):format(f.id))
        end
    end

    if opts.seed ~= false then
        for _, name in ipairs(readIndex(resource, 'migrations/seed', M.SEED_PATTERN, false)) do
            local id = M.SEED_ID_PREFIX .. name
            local text, sum = loadFile(resource, 'migrations/seed/' .. name)
            if applied[id] ~= sum then
                -- One transaction: the seed's statements and its fredpd_migrations row commit together.
                local queries = {}
                for _, st in ipairs(runnable(id, text, log, result.skipped)) do
                    queries[#queries + 1] = { query = st.sql }
                end
                queries[#queries + 1] = { query = RECORD_SEED_SQL, values = { id, sum } }
                if not MySQL.transaction.await(queries) then
                    error(('%s: seed transaction failed and was rolled back (see the oxmysql error above)'):format(id), 0)
                end
                result.seeded[#result.seeded + 1] = id
                log(('seeded %s'):format(id))
            end
        end
    end

    if #result.applied == 0 and #result.seeded == 0 then log('up to date') end
    return result
end

return M
