-- SPDX-License-Identifier: GPL-3.0-only
-- Test double for oxmysql's `MySQL` global plus FiveM's LoadResourceFile / GetCurrentResourceName, so that
-- fredpd_core/server/db.lua's M.migrate() runs for real against MariaDB outside FiveM.
--
-- Every call runs the `mariadb` (or `mysql`) command-line client once through io.popen with --xml output. It is
-- slow (one process per query) and only as faithful as tests need:
--   * values come back as strings, except that integer / decimal looking strings become numbers and NULL is nil
--     (so a VARCHAR holding '007' reads back as 7);
--   * `?` placeholders (array params) and `@name` / `:name` placeholders (map params) are substituted client-side;
--   * transaction.await runs all queries in one session between START TRANSACTION and COMMIT; the client stops at
--     the first error and the server rolls the transaction back when the session ends;
--   * like oxmysql, sessions keep the server's default time zone. Set M.sessionTimeZone (e.g. '+02:00') to
--     simulate a server whose default is not UTC.
-- Connection: host/port/user/password from env FREDPD_TEST_DB_URL (docs/contracts.md §C7 default), database from
-- M.database (default fredpd_test_db_lua). LoadResourceFile(resource, 'migrations/...') serves db/migrations and
-- db/seed with generated index.json files, like scripts/build.mjs lays them out in the resource.
--
-- Also a CLI used by packages/types/test/migrations.test.ts (run from the repo root):
--   lua5.4 tests/lua/mysql_shim.lua migrate <database> [--reset] [--stub] [--no-seed]   -> last line: RESULT <json>
--                                   [--migrations-dir=<dir>]   (instead of db/migrations; an error goes to stderr, exit 1)
--   lua5.4 tests/lua/mysql_shim.lua split <file.sql> ...                                -> one JSON object
--   lua5.4 tests/lua/mysql_shim.lua consts                                              -> db.lua SQL constants
--   lua5.4 tests/lua/mysql_shim.lua tzproblem '<json array of TIME_ZONE_SQL rows>'      -> db.timeZoneProblem each
local M = {}

local IS_WINDOWS = package.config:sub(1, 1) == '\\'

M.resourceName = 'fredpd_core'
M.database = 'fredpd_test_db_lua'
M.migrationsDir = 'db/migrations'
M.seedDir = 'db/seed'
M.stubFile = 'db/dev/qbx_stub.sql'
M.sessionTimeZone = nil -- nil: the server default, as oxmysql
M.lastError = nil

--- Parse mysql://user:pass@host:port/db (password and port optional).
function M.parseUrl(url)
    local user, rest = url:match('^mysql://([^:@/]+)(.*)$')
    if not user then error('bad database URL: ' .. url) end
    local pass = rest:match('^:([^@]*)@') or ''
    local hostPart = rest:match('@([^/?]+)') or '127.0.0.1'
    local host, port = hostPart:match('^([^:]+):?(%d*)$')
    return { user = user, password = pass, host = host or '127.0.0.1', port = tonumber(port) or 3306 }
end

M.conn = M.parseUrl(os.getenv('FREDPD_TEST_DB_URL') or 'mysql://fredpd:fredpd@127.0.0.1:3306/fredpd_test')

local function shellQuote(s)
    s = tostring(s)
    if IS_WINDOWS then return '"' .. s:gsub('"', '\\"') .. '"' end
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function readFile(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

local function writeFile(path, content)
    local f = assert(io.open(path, 'wb'))
    f:write(content)
    f:close()
end

local clientBin
local function client()
    if clientBin == nil then
        clientBin = false
        for _, name in ipairs({ 'mariadb', 'mysql' }) do
            local p = io.popen(name .. ' --version 2>&1')
            local out = p and p:read('a') or ''
            if p then p:close() end
            if out:find('Ver', 1, true) then
                clientBin = name
                break
            end
        end
    end
    return clientBin
end

--- Run SQL text in one client session (`database` optional). Returns ok, stdout, stderr.
function M.run(sqlText, database)
    local bin = client()
    if not bin then return false, '', 'no mariadb/mysql client on PATH' end
    local tmpIn, tmpErr = os.tmpname(), os.tmpname()
    local prefix = ''
    if M.sessionTimeZone then
        assert(tostring(M.sessionTimeZone):match('^[%w%+%-:/_]+$'), 'bad sessionTimeZone')
        prefix = ("SET time_zone = '%s';\n"):format(M.sessionTimeZone)
    end
    writeFile(tmpIn, prefix .. sqlText .. '\n')
    local c = M.conn
    local parts = {
        bin, '--protocol=TCP', '--host=' .. shellQuote(c.host), '--port=' .. c.port, '--user=' .. shellQuote(c.user),
        '--password=' .. shellQuote(c.password), '--default-character-set=utf8mb4', '--xml',
    }
    if database then parts[#parts + 1] = shellQuote(database) end
    parts[#parts + 1] = '<' .. shellQuote(tmpIn)
    parts[#parts + 1] = '2>' .. shellQuote(tmpErr)
    local p = io.popen(table.concat(parts, ' '), 'r')
    local out = p:read('a')
    local ok = p:close()
    local err = readFile(tmpErr) or ''
    os.remove(tmpIn)
    os.remove(tmpErr)
    return ok == true, out, err
end

--- Whether the database server is reachable (cached). Returns ok, reason.
local availability
function M.available()
    if availability == nil then
        local ok, _, err = M.run('SELECT 1')
        availability = { ok = ok, reason = ok and nil or (err ~= '' and err or 'client failed') }
    end
    return availability.ok, availability.reason
end

---------------------------------------------------------------------------------------------------------------
-- Parameter binding and XML parsing

local function literal(v)
    local t = type(v)
    if v == nil then return 'NULL' end
    if t == 'boolean' then return v and '1' or '0' end
    if t == 'number' then
        if math.type(v) == 'integer' then return ('%d'):format(v) end
        return ('%.17g'):format(v)
    end
    if t == 'table' then v = json.encode(v) end
    local escaped = tostring(v):gsub('[\\\'"\0\n\r\26]', {
        ['\\'] = '\\\\', ["'"] = "\\'", ['"'] = '\\"', ['\0'] = '\\0', ['\n'] = '\\n', ['\r'] = '\\r', ['\26'] = '\\Z',
    })
    return "'" .. escaped .. "'"
end

--- Substitute placeholders outside quotes: `?` from an array, `@name` / `:name` from a map.
function M.bind(sql, params)
    if params == nil then return sql end
    local named = next(params) ~= nil and params[1] == nil
    local out, i, n, argIndex = {}, 1, #sql, 0
    repeat
        local c = sql:sub(i, i)
        if c == "'" or c == '"' or c == '`' then
            -- copy a quoted literal/identifier verbatim (placeholders inside it are not placeholders)
            local j = i + 1
            while j <= n do
                local d = sql:sub(j, j)
                if d == '\\' and c ~= '`' then
                    j = j + 2
                elseif d == c then
                    if sql:sub(j + 1, j + 1) ~= c then break end
                    j = j + 2
                else
                    j = j + 1
                end
            end
            out[#out + 1] = sql:sub(i, j)
            i = j + 1
        elseif c == '?' and not named then
            argIndex = argIndex + 1
            out[#out + 1] = literal(params[argIndex])
            i = i + 1
        elseif (c == '@' or c == ':') and named and sql:match('^[%a_]', i + 1) then
            local name = sql:match('^[%w_]+', i + 1)
            out[#out + 1] = literal(params[name])
            i = i + 1 + #name
        else
            out[#out + 1] = c
            i = i + 1
        end
    until i > n
    return table.concat(out)
end

local ENTITIES = { lt = '<', gt = '>', amp = '&', quot = '"', apos = "'" }
local function unescape(s)
    return (s:gsub('&(#?)([xX]?)(%w+);', function(hash, hex, body)
        if hash == '' then return ENTITIES[body] end
        local code = tonumber(body, hex ~= '' and 16 or 10)
        return code and utf8.char(code) or nil
    end))
end

local function convert(v)
    if #v <= 15 and v:match('^%-?%d+$') then return math.tointeger(tonumber(v)) end
    if #v <= 17 and v:match('^%-?%d+%.%d+$') then return tonumber(v) end
    return v
end

--- Parse `mariadb --xml` output into { { rows = { {col = value} }, columns = { names in order } }, ... }.
function M.parseXml(xml)
    local sets = {}
    for body in xml:gmatch('<resultset[^>]*>(.-)</resultset>') do
        local set = { rows = {}, columns = {} }
        for rowBody in body:gmatch('<row>(.-)</row>') do
            local row, pos = {}, 1
            local first = #set.rows == 0
            repeat
                local s, e, name, _, selfClose = rowBody:find('<field name="([^"]*)"([^>]-)(/?)>', pos)
                if s then
                    name = unescape(name)
                    if first then set.columns[#set.columns + 1] = name end
                    if selfClose == '/' then
                        pos = e + 1 -- NULL
                    else
                        local vs, ve = rowBody:find('</field>', e + 1, true)
                        row[name] = convert(unescape(rowBody:sub(e + 1, vs - 1)))
                        pos = ve + 1
                    end
                end
            until not s
            set.rows[#set.rows + 1] = row
        end
        sets[#sets + 1] = set
    end
    return sets
end

---------------------------------------------------------------------------------------------------------------
-- Fake oxmysql

local function stripSemi(sql)
    return (sql:gsub('[%s;]+$', ''))
end

--- Run one statement; returns its result set (or nil for statements without one) and { affectedRows, insertId }.
local function exec(sql, params)
    local text = stripSemi(M.bind(sql, params)) .. ';\nSELECT ROW_COUNT() AS affectedRows, LAST_INSERT_ID() AS insertId;'
    local ok, out, err = M.run(text, M.database)
    if not ok then
        M.lastError = err ~= '' and err or out
        error(M.lastError, 0)
    end
    local sets = M.parseXml(out)
    local meta = sets[#sets].rows[1]
    return sets[#sets - 1], { affectedRows = meta.affectedRows, insertId = meta.insertId }
end

local function query(sql, params)
    local set, meta = exec(sql, params)
    if set then return set.rows end
    return meta
end

local function scalar(sql, params)
    local set = exec(sql, params)
    local row = set and set.rows[1]
    return row and row[set.columns[1]] or nil
end

local function single(sql, params)
    local set = exec(sql, params)
    return set and set.rows[1] or nil
end

local function insert(sql, params)
    local _, meta = exec(sql, params)
    return meta.insertId
end

local function update(sql, params)
    local _, meta = exec(sql, params)
    return meta.affectedRows
end

local function transaction(queries, params)
    local parts = { 'START TRANSACTION' }
    for _, q in ipairs(queries) do
        local sql, values
        if type(q) == 'string' then
            sql, values = q, params
        else
            sql, values = q.query or q[1], q.values or q.parameters or q[2] or params
        end
        parts[#parts + 1] = stripSemi(M.bind(sql, values))
    end
    parts[#parts + 1] = 'COMMIT'
    local ok, out, err = M.run(table.concat(parts, ';\n') .. ';', M.database)
    if not ok then
        M.lastError = err ~= '' and err or out
        return false
    end
    return true
end

--- oxmysql style: MySQL.query.await(sql, params) and MySQL.query(sql, params, cb).
local function api(fn)
    return setmetatable({ await = fn }, {
        __call = function(_, sql, params, cb)
            if type(params) == 'function' then params, cb = nil, params end
            local r = fn(sql, params)
            if cb then cb(r) end
            return r
        end,
    })
end

---------------------------------------------------------------------------------------------------------------
-- Fake resource files

--- File names in `dir` matching a Lua pattern, sorted (ls / dir /b; plain Lua cannot list directories).
function M.listSql(dir, pattern)
    local names = {}
    local cmd = IS_WINDOWS and ('dir /b ' .. shellQuote(dir) .. ' 2>nul') or ('ls -1 ' .. shellQuote(dir) .. ' 2>/dev/null')
    local p = io.popen(cmd)
    if p then
        for line in p:lines() do
            if line:find(pattern) then names[#names + 1] = line end
        end
        p:close()
    end
    table.sort(names)
    return names
end

local function loadResourceFile(resource, path)
    if resource ~= M.resourceName then return nil end
    if path == 'migrations/index.json' then return json.encode(M.listSql(M.migrationsDir, '^%d%d%d_.+%.sql$')) end
    if path == 'migrations/seed/index.json' then return json.encode(M.listSql(M.seedDir, '%.sql$')) end
    local seedName = path:match('^migrations/seed/([^/]+)$')
    if seedName then return readFile(M.seedDir .. '/' .. seedName) end
    local name = path:match('^migrations/([^/]+)$')
    if name then return readFile(M.migrationsDir .. '/' .. name) end
    return nil
end

--- Install the globals. opts: { database?, migrationsDir?, seedDir?, sessionTimeZone? }.
function M.install(opts)
    opts = opts or {}
    M.database = opts.database or M.database
    M.sessionTimeZone = opts.sessionTimeZone
    M.migrationsDir = opts.migrationsDir or M.migrationsDir
    M.seedDir = opts.seedDir or M.seedDir
    MySQL = {
        query = api(query), scalar = api(scalar), single = api(single), insert = api(insert),
        update = api(update), transaction = api(transaction),
        ready = function(cb) cb() end,
    }
    LoadResourceFile = loadResourceFile
    GetCurrentResourceName = function() return M.resourceName end
    return M
end

--- Drop and recreate a database (utf8mb4_swedish_ci); with stub = true also load db/dev/qbx_stub.sql.
function M.resetDatabase(name, stub)
    assert(name:match('^[%w_]+$'), 'bad database name')
    local ok, out, err = M.run(('DROP DATABASE IF EXISTS `%s`;\nCREATE DATABASE `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_swedish_ci;')
        :format(name, name))
    if not ok then error(err ~= '' and err or out, 0) end
    if stub then
        ok, out, err = M.run(assert(readFile(M.stubFile), 'missing ' .. M.stubFile), name)
        if not ok then error(err ~= '' and err or out, 0) end
    end
end

---------------------------------------------------------------------------------------------------------------
-- CLI (only when this file is the main script)

local function cli(args)
    package.path = table.concat({
        './tests/lua/?.lua', './tests/lua/vendor/?.lua', './resources/[fredpd]/fredpd_core/?.lua', package.path,
    }, ';')
    json = require('json')
    local cmd = args[1]
    if cmd == 'consts' then
        local db = require('server.db')
        print(json.encode({ migrationsTableDdl = db.MIGRATIONS_TABLE_DDL, nextSeqSql = db.NEXT_SEQ_SQL,
            timeZoneSql = db.TIME_ZONE_SQL }))
        return 0
    elseif cmd == 'tzproblem' then
        local db = require('server.db')
        local out = {}
        for k, row in ipairs(json.decode(assert(args[2], 'usage: tzproblem <json array>'))) do
            out[k] = { problem = db.timeZoneProblem(row) }
        end
        print(json.encode(out))
        return 0
    elseif cmd == 'split' then
        local db = require('server.db')
        local result = {}
        for k = 2, #args do
            local content = assert(readFile(args[k]), 'cannot read ' .. args[k])
            local ok, statements = pcall(db.splitStatements, content)
            result[args[k]] = { checksum = db.checksum(content), statements = ok and statements or nil,
                error = not ok and tostring(statements) or nil }
        end
        print(json.encode(result))
        return 0
    elseif cmd == 'migrate' then
        local database = assert(args[2], 'usage: migrate <database> [--reset] [--stub] [--no-seed] [--migrations-dir=<dir>]')
        local flags, installOpts = {}, { database = database }
        for k = 3, #args do
            local dir = args[k]:match('^%-%-migrations%-dir=(.+)$')
            if dir then installOpts.migrationsDir = dir else flags[args[k]] = true end
        end
        local ok, reason = M.available()
        if not ok then
            io.stderr:write('database unreachable: ' .. tostring(reason) .. '\n')
            return 2
        end
        if flags['--reset'] then M.resetDatabase(database, flags['--stub']) end
        M.install(installOpts)
        local db = require('server.db')
        local okm, result = pcall(db.migrate, { seed = not flags['--no-seed'] })
        if not okm then
            io.stderr:write(tostring(result) .. '\n')
            return 1
        end
        print('RESULT ' .. json.encode(result))
        return 0
    end
    io.stderr:write('usage: lua5.4 tests/lua/mysql_shim.lua consts | tzproblem <json> | split <file>... | migrate <database> [--reset] [--stub] [--no-seed] [--migrations-dir=<dir>]\n')
    return 64
end

if arg and arg[0] and arg[0]:find('mysql_shim%.lua$') and ... ~= 'mysql_shim' then
    os.exit(cli({ ... }))
end

return M
