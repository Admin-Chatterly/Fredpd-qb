-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_core shared server helpers: service calls through the JS bridge, per-player rate limits, config files,
-- player data access and logging. Loaded with `require 'server.core'`; nothing touches FiveM at load time, so the
-- pure parts (rateLimit with an injected clock, readJsonFile with an injected loader) are tested outside FiveM.

local M = {}

M.RESOURCE = 'fredpd_core'

--- This resource's name (M.RESOURCE outside FiveM).
function M.resource()
    if type(GetCurrentResourceName) == 'function' then return GetCurrentResourceName() end
    return M.RESOURCE
end

---------------------------------------------------------------------------------------------------------------
-- Logging: ox_lib's lib.print (levels via convar ox:printlevel:fredpd_core), plain print outside FiveM.

local function emit(level, fmt, ...)
    local msg = select('#', ...) > 0 and fmt:format(...) or tostring(fmt)
    local printer = type(lib) == 'table' and lib.print and lib.print[level]
    if printer then
        printer(msg)
    else
        print(('[fredpd_core] %s: %s'):format(level, msg))
    end
end

function M.info(fmt, ...) emit('info', fmt, ...) end
function M.warn(fmt, ...) emit('warn', fmt, ...) end
function M.error(fmt, ...) emit('error', fmt, ...) end
function M.debug(fmt, ...) emit('debug', fmt, ...) end

---------------------------------------------------------------------------------------------------------------
-- One-shot async work (never a loop): runs fn in its own thread so it may await oxmysql / Core.fetch.

--- @param label string used in the error log
--- @param fn function
function M.async(label, fn, ...)
    local args = table.pack(...)
    CreateThread(function()
        local ok, err = pcall(fn, table.unpack(args, 1, args.n))
        if not ok then M.error('%s failed: %s', label, tostring(err)) end
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Internal exports. Some exports exist only for server/http.js (this resource's own JS runtime) or for
-- fredpd_devtools: applyGrants, recomputeGrants, setOfficerIdentity, backfillMirror, seedDevRows. As plain exports
-- any server resource could call them (e.g. applyGrants(id, { grants = { 'perm:*' } }) to escalate a player), so
-- they refuse every other invoking resource.

local refusedCallers = {} -- ['export|resource'] = true once the refusal was logged

--- True when the current export call may run: no invoking resource (console, same runtime), this resource
--- (http.js calls through exports[resource], so the invoker is fredpd_core itself) or a name in `allowed`.
--- @param exportName string for the log line
--- @param allowed string[]|nil other resources allowed to call it
--- @return boolean
function M.callerAllowed(exportName, allowed)
    local caller = type(GetInvokingResource) == 'function' and GetInvokingResource() or nil
    if caller == nil or caller == '' or caller == M.resource() then return true end
    for _, name in ipairs(allowed or {}) do
        if caller == name then return true end
    end
    local key = exportName .. '|' .. tostring(caller)
    if not refusedCallers[key] then
        refusedCallers[key] = true
        M.warn('export %s is internal to fredpd_core; call from resource %s refused', exportName, tostring(caller))
    end
    return false
end

--- Register an internal export: callers outside `allowed` (and fredpd_core) get false and fn does not run.
--- @param name string
--- @param fn function
--- @param allowed string[]|nil
function M.internalExport(name, fn, allowed)
    exports(name, function(...)
        if not M.callerAllowed(name, allowed) then return false end
        return fn(...)
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Service calls (docs/contracts.md §C6): Core.fetch wraps the JS export signedFetch in a promise.

--- Decode a JSON body; nil when empty or not JSON.
function M.decode(text)
    if type(text) ~= 'string' or text == '' then return nil end
    local ok, value = pcall(json.decode, text)
    if ok then return value end
    return nil
end

--- Signed request to fredpd_service. Must run inside a thread (Citizen.Await). The JS side always answers within
--- its 3 s timeout, so this never hangs.
--- @param method string 'GET'|'POST'|...
--- @param path string '/internal/...'
--- @param body table|nil JSON body (ignored for GET)
--- @return integer status 0 when there was no HTTP response (bridge disabled, timeout, network error)
--- @return any decoded JSON body or nil
function M.fetch(method, path, body)
    local p = promise.new()
    local ok, err = pcall(function()
        exports[M.resource()]:signedFetch(method, path, body, function(status, text)
            p:resolve({ status, text })
        end)
    end)
    if not ok then
        M.error('signedFetch export unavailable: %s', tostring(err))
        return 0, nil
    end
    local result = Citizen.Await(p)
    return tonumber(result[1]) or 0, M.decode(result[2])
end

---------------------------------------------------------------------------------------------------------------
-- Rate limits: one timestamp per (player, action). No threads; entries are dropped on playerDropped.

local buckets = {}

--- Monotonic milliseconds. GetGameTimer() on FXServer; os.clock() is CPU time on Linux, so it is only the
--- fallback outside FiveM (tests pass `now` explicitly).
function M.now()
    if type(GetGameTimer) == 'function' then return GetGameTimer() end
    return math.floor(os.clock() * 1000)
end

--- Allow an action at most once per `ms` per player. Returns true when allowed (and records it), false when the
--- call comes too soon. A refused call does not extend the window.
--- @param src integer|string player id
--- @param action string
--- @param ms integer
--- @param now integer|nil current time in ms (default M.now())
--- @return boolean
function M.rateLimit(src, action, ms, now)
    now = now or M.now()
    local key = tostring(src)
    local bucket = buckets[key]
    if not bucket then
        bucket = {}
        buckets[key] = bucket
    end
    local last = bucket[action]
    if last and now - last < ms then return false end
    bucket[action] = now
    return true
end

--- Forget a player's rate-limit state (called on playerDropped).
function M.clearRateLimits(src)
    buckets[tostring(src)] = nil
end

---------------------------------------------------------------------------------------------------------------
-- SQL helpers

--- Placeholders and parameters for one row of `n` values where some may be nil. A Lua array with nil holes does
--- not survive the msgpack trip to oxmysql as an array, so a nil value becomes a literal NULL in the SQL and is
--- left out of the parameter list.
--- @param values table values[1..n], nil allowed
--- @param n integer
--- @param params table|nil list to append to (default a new one)
--- @return string placeholders e.g. '?, NULL, ?'
--- @return table params
function M.bindRow(values, n, params)
    params = params or {}
    local marks = {}
    for i = 1, n do
        local v = values[i]
        if v == nil then
            marks[i] = 'NULL'
        else
            marks[i] = '?'
            params[#params + 1] = v
        end
    end
    return table.concat(marks, ', '), params
end

--- Multi-row `INSERT ... ON DUPLICATE KEY UPDATE` (or INSERT IGNORE when `update` is nil) over `rows` (tables keyed
--- by column name). Returns sql, params.
---
--- `touch` names the table's updated_at column. FredPD tables have no ON UPDATE clause (UTC, docs/contracts.md §C7),
--- so the upsert sets it itself, and like ON UPDATE only when an `update` column really changes (byte comparison):
--- the assignment comes first, while the columns still hold their old values (MariaDB assigns left to right).
--- A new row gets the column default, (UTC_TIMESTAMP()).
--- @param tbl string table name (trusted)
--- @param columns string[] column names (trusted)
--- @param rows table[]
--- @param update string[]|nil columns to overwrite on a duplicate key; nil = INSERT IGNORE
--- @param touch string|nil updated_at column to maintain on a duplicate key (trusted)
function M.buildInsert(tbl, columns, rows, update, touch)
    local params, tuples = {}, {}
    for r, row in ipairs(rows) do
        local values = {}
        for i, col in ipairs(columns) do values[i] = row[col] end
        local marks = M.bindRow(values, #columns, params)
        tuples[r] = '(' .. marks .. ')'
    end
    local head = update and 'INSERT INTO' or 'INSERT IGNORE INTO'
    local sql = ('%s %s (%s) VALUES %s'):format(head, tbl, table.concat(columns, ', '), table.concat(tuples, ', '))
    if update and #update > 0 then
        local sets, same = {}, {}
        for i, col in ipairs(update) do
            same[i] = ('BINARY %s <=> BINARY VALUES(%s)'):format(col, col)
        end
        if touch then
            sets[1] = ('%s = IF(%s, %s, UTC_TIMESTAMP())'):format(touch, table.concat(same, ' AND '), touch)
        end
        for _, col in ipairs(update) do sets[#sets + 1] = ('%s = VALUES(%s)'):format(col, col) end
        sql = sql .. ' ON DUPLICATE KEY UPDATE ' .. table.concat(sets, ', ')
    end
    return sql, params
end

---------------------------------------------------------------------------------------------------------------
-- Config files (config/*.json, copied from the repo's config/ by scripts/build.mjs)

--- Read and decode a JSON file of this resource. Returns nil and an error string when missing or invalid.
--- @param path string e.g. 'config/formats.json'
--- @param loader function|nil (resource, path) -> string|nil, default LoadResourceFile
function M.readJsonFile(path, loader)
    loader = loader or LoadResourceFile
    local resource = type(GetCurrentResourceName) == 'function' and GetCurrentResourceName() or M.RESOURCE
    local raw = loader(resource, path)
    if not raw or raw == '' then return nil, ('%s is missing (run scripts/build.mjs)'):format(path) end
    local ok, value = pcall(json.decode, raw)
    if not ok or type(value) ~= 'table' then return nil, ('%s is not valid JSON'):format(path) end
    return value
end

M.config = { formats = nil, units = nil, integrations = nil }

--- Unit code -> config entry and the ordered list of codes (config/units.json).
function M.unitIndex(units)
    local byCode, order = {}, {}
    for _, u in ipairs(type(units) == 'table' and units.units or {}) do
        if type(u) == 'table' and type(u.code) == 'string' and byCode[u.code] == nil then
            byCode[u.code] = u
            order[#order + 1] = u.code
        end
    end
    return byCode, order
end

---------------------------------------------------------------------------------------------------------------
-- Players, through the framework bridge (server/bridge.lua, docs/contracts.md §C17: qb-core or qbx_core). Always
-- asks the framework, so the actor is never taken from a stale cache or from the client.

--- Normalised player of an online player ({ source, citizenid, license, name, job = { name, type, grade, onduty,
--- ... }, charinfo }), or nil.
function M.getPlayerData(src)
    src = tonumber(src)
    if not src or src <= 0 then return nil end
    local ok, player = pcall(function() return require('server.bridge').getPlayer(src) end)
    if ok and type(player) == 'table' then return player end
    return nil
end

--- 'discord:123' -> '123'; nil for anything that is not a Discord snowflake.
function M.discordIdFromIdentifier(identifier)
    if type(identifier) ~= 'string' then return nil end
    local id = identifier:match('^discord:(%d+)$')
    if id and #id <= 20 then return id end
    return nil
end

--- Discord id of an online player (nil if they have no Discord identifier).
function M.discordIdOf(src)
    if not tonumber(src) or tonumber(src) <= 0 then return nil end
    return M.discordIdFromIdentifier(GetPlayerIdentifierByType(tostring(src), 'discord'))
end

--- Online player ids as integers.
function M.players()
    local out = {}
    for _, id in ipairs(GetPlayers()) do out[#out + 1] = tonumber(id) end
    return out
end

--- ox_lib notify from the server.
function M.notify(src, data)
    if tonumber(src) and tonumber(src) > 0 then TriggerClientEvent('ox_lib:notify', src, data) end
end

return M
