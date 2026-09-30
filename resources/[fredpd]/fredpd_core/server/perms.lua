-- SPDX-License-Identifier: GPL-3.0-only
-- Grant cache and permission exports (IMPLEMENTATION.md §4.1, docs/contracts.md §C2, §C9).
--
-- Grants follow the Discord user, not the character (§8.5). On playerJoining the set is fetched from fredpd_service
-- (GET /internal/grants/:discordId) and kept in `Cache[src]`, a server-only table: never a statebag, never read by
-- other resources directly (they use the exports). If the service is unreachable the last row of
-- fredpd_grant_cache is used and a warning is logged. The service pushes changes through POST /grants (http.js ->
-- applyGrants), which also refreshes fredpd_grant_cache and tells the player's client.
--
-- Sets only move forward in time: a set (fetched, pushed or read from the cache) whose computedAt is older than the
-- one already held for that player is ignored, and the fredpd_grant_cache upsert keeps the newer row. So a push
-- that was resolved before an admin's revocation but arrives after the recompute that revocation triggered cannot
-- bring the revoked grants back. Loads are coalesced per player (one fetch in flight, at most one queued after it).
--
-- fredpd_grant_cache and fredpd_identities are system-maintained caches, not records: they are not audited per row
-- (the service audits the permission change itself as perms.update).

local Grants = require 'shared.grants'
local Time = require 'shared.time'
local Core = require 'server.core'

local M = {}

local Cache = {}     -- [src] = GrantSet (treated as immutable; exports hand out copies)
local DiscordOf = {} -- [src] = Discord id string
local Loading = {}   -- [src] = token of the load in flight; cleared when it ends or by playerDropped
local Again = {}     -- [src] = { notify } when another load was asked for while one was in flight (runs after it)
local Served = {}    -- [src] = client copy last built for fredpd:getMyGrants; dropped whenever Cache[src] changes

local MAX_LIST = 2000
local GRANT_PATTERN = '^[%l_]+:%S+$'
local UNIT_PATTERN = '^[%w_%-]+$'

-- computed_at is the set's computedAt as a UTC DATETIME; %s is '?' or UTC_TIMESTAMP() (see M.cacheUpsert). Times are
-- UTC whatever the MariaDB time zone is (docs/contracts.md §C7): never the session clock. A row only moves forward:
-- an older set leaves it alone; within one second (DATETIME has no fraction) the last write wins. Same rule as the
-- service's writeGrantCache; the result does not depend on the order MariaDB applies the two assignments.
M.CACHE_UPSERT_SQL = 'INSERT INTO fredpd_grant_cache (discord_id, grants, computed_at) VALUES (?, ?, %s) '
    .. 'ON DUPLICATE KEY UPDATE grants = IF(VALUES(computed_at) >= computed_at, VALUES(grants), grants), '
    .. 'computed_at = GREATEST(computed_at, VALUES(computed_at))'
M.CACHE_SELECT_SQL = 'SELECT grants FROM fredpd_grant_cache WHERE discord_id = ?'
M.IDENTITY_SEEN_SQL = 'INSERT INTO fredpd_identities (discord_id, last_seen) VALUES (?, UTC_TIMESTAMP()) '
    .. 'ON DUPLICATE KEY UPDATE last_seen = VALUES(last_seen)'
-- %s = placeholders for (discord_id, license, last_citizenid); license may be NULL (Core.bindRow).
M.IDENTITY_CHARACTER_SQL = 'INSERT INTO fredpd_identities (discord_id, license, last_citizenid, last_seen) '
    .. 'VALUES (%s, UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE license = COALESCE(VALUES(license), license), '
    .. 'last_citizenid = VALUES(last_citizenid), last_seen = VALUES(last_seen)'
-- A license belongs to the Discord account that last played it (license is not unique: discord_id is the key). Before
-- the license is recorded for Discord user D, every other Discord user loses it (a relinked Discord, a shared PC, a
-- handed-over account), so the portal no longer lists its characters for them, and their portal sessions drop the
-- character they picked from it. Same transaction as IDENTITY_CHARACTER_SQL. Params: (license, discord_id).
M.IDENTITY_SESSIONS_UNLINK_SQL = 'UPDATE fredpd_sessions SET citizenid = NULL WHERE citizenid IS NOT NULL AND discord_id IN '
    .. '(SELECT discord_id FROM fredpd_identities WHERE license = ? AND discord_id <> ?)'
M.IDENTITY_UNLINK_SQL = 'UPDATE fredpd_identities SET license = NULL WHERE license = ? AND discord_id <> ?'

---------------------------------------------------------------------------------------------------------------
-- Pure helpers (tests/lua/core_perms_test.lua)

--- Copy of a list of strings that all match `pattern` (and are at most maxLen bytes); nil if anything is off,
--- including a JSON object where a list is expected.
local function stringList(list, pattern, maxLen)
    if type(list) ~= 'table' then return nil end
    local n = #list
    if n > MAX_LIST or (n == 0 and next(list) ~= nil) then return nil end
    local out = {}
    for i = 1, n do
        local v = list[i]
        if type(v) ~= 'string' or #v > maxLen or not v:match(pattern) then return nil end
        out[i] = v
    end
    return out
end

--- Validate and normalise a GrantSet (§C2) from the service, a push or the DB cache. Returns a fresh table, or
--- nil and the name of the offending field. `rank` that is not a table (JSON null sentinel) counts as no rank;
--- a missing computedAt is stamped now.
--- @param set any
--- @return table|nil, string|nil
function M.validateSet(set)
    if type(set) ~= 'table' then return nil, 'set' end
    local grants = stringList(set.grants, GRANT_PATTERN, 128)
    if not grants then return nil, 'grants' end
    local denied = stringList(set.denied, GRANT_PATTERN, 128)
    if not denied then return nil, 'denied' end
    local tier = math.tointeger(tonumber(set.tier))
    if not tier or tier < 0 or tier > 2 then return nil, 'tier' end
    local units = stringList(set.units, UNIT_PATTERN, 32)
    if not units then return nil, 'units' end
    local rank = nil
    if type(set.rank) == 'table' then
        local roleId, key = set.rank.roleId, set.rank.key
        if type(roleId) ~= 'string' or type(key) ~= 'string' or #roleId > 20 or #key > 64 then return nil, 'rank' end
        rank = { roleId = roleId, key = key }
    end
    local computedAt = set.computedAt
    if type(computedAt) ~= 'string' or #computedAt > 40 then computedAt = Grants.empty().computedAt end
    return { grants = grants, denied = denied, tier = tier, units = units, rank = rank, computedAt = computedAt }
end

--- Deep copy (what exports and clients get).
function M.copySet(set)
    set = set or Grants.empty()
    local function copy(list)
        local out = {}
        for i = 1, #(list or {}) do out[i] = list[i] end
        return out
    end
    return {
        grants = copy(set.grants), denied = copy(set.denied), tier = set.tier or 0, units = copy(set.units),
        rank = set.rank and { roleId = set.rank.roleId, key = set.rank.key } or nil, computedAt = set.computedAt,
    }
end

--- The §C2 wire JSON with real arrays (an empty Lua table would otherwise encode as {} with some json libraries).
--- @param set table a validated GrantSet
--- @return string
function M.encodeSet(set)
    local function list(l)
        local parts = {}
        for i, v in ipairs(l) do parts[i] = json.encode(v) end
        return '[' .. table.concat(parts, ',') .. ']'
    end
    local rank = 'null'
    if set.rank then
        rank = ('{"roleId":%s,"key":%s}'):format(json.encode(set.rank.roleId), json.encode(set.rank.key))
    end
    return ('{"grants":%s,"denied":%s,"tier":%d,"units":%s,"rank":%s,"computedAt":%s}'):format(
        list(set.grants), list(set.denied), set.tier, list(set.units), rank, json.encode(set.computedAt))
end

--- '2026-09-29T12:00:00.000Z' -> '2026-09-29 12:00:00' (UTC DATETIME; an offset such as +02:00 is converted);
--- nil for anything that is not an ISO-8601 timestamp.
function M.isoToDatetime(iso)
    if type(iso) ~= 'string' or not iso:find('T', 1, true) then return nil end
    return (Time.toDatetime(iso))
end

--- computedAt of a set as epoch milliseconds, or nil when it is not a timestamp.
function M.stampOf(set)
    return type(set) == 'table' and (Time.toEpochMs(set.computedAt)) or nil
end

--- True unless `incoming` is provably older than `current` (a set without a readable computedAt is never older).
function M.isNotOlder(incoming, current)
    if current == nil then return true end
    local a, b = M.stampOf(incoming), M.stampOf(current)
    if a == nil or b == nil then return true end
    return a >= b
end

---------------------------------------------------------------------------------------------------------------
-- Cache

--- Player ids (integers) currently mapped to a Discord id.
local function sourcesOf(discordId)
    local out = {}
    for src, id in pairs(DiscordOf) do
        if id == discordId then out[#out + 1] = src end
    end
    return out
end

local function store(src, set, notify)
    Cache[src] = set
    Served[src] = nil
    if notify and not Core.isVirtual(src) then
        TriggerClientEvent('fredpd:client:grantsChanged', src, M.copySet(set))
    end
    -- Server-side hook for other FredPD resources (for example to close pages the player lost access to).
    TriggerEvent('fredpd:grantsChanged', src)
end

--- store() unless the player already holds a newer set. Returns true when stored.
local function storeIfNewer(src, set, notify)
    if not M.isNotOlder(set, Cache[src]) then return false end
    store(src, set, notify)
    return true
end

--- SQL and parameters for the fredpd_grant_cache upsert (UTC_TIMESTAMP() when computedAt is not an ISO string).
function M.cacheUpsert(discordId, set)
    local computed = M.isoToDatetime(set.computedAt)
    local params = { discordId, M.encodeSet(set) }
    if computed then params[3] = computed end
    return M.CACHE_UPSERT_SQL:format(computed and '?' or 'UTC_TIMESTAMP()'), params
end

--- Upsert fredpd_grant_cache (awaits; call from a thread).
function M.writeCache(discordId, set)
    local sql, params = M.cacheUpsert(discordId, set)
    local ok, err = pcall(MySQL.update.await, sql, params)
    if not ok then Core.error('fredpd_grant_cache write for %s failed: %s', discordId, tostring(err)) end
end

--- Last cached GrantSet of a Discord user (awaits), or nil.
function M.readCache(discordId)
    local ok, raw = pcall(MySQL.scalar.await, M.CACHE_SELECT_SQL, { discordId })
    if not ok then
        Core.error('fredpd_grant_cache read for %s failed: %s', discordId, tostring(raw))
        return nil
    end
    local decoded = type(raw) == 'table' and raw or Core.decode(raw)
    return (M.validateSet(decoded))
end

--- One load (see M.load). `token` identifies it in Loading[src].
local function loadOnce(src, notify, token)
    local discordId = Core.discordIdOf(src)
    if not discordId then
        DiscordOf[src] = nil
        store(src, Grants.empty(), notify)
        Core.warn('player %d has no Discord identifier: no FredPD grants', src)
        return false
    end
    DiscordOf[src] = discordId

    local status, body = Core.fetch('GET', '/internal/grants/' .. discordId)
    -- Dropped while waiting (a reconnecting player may even have the same id with a new load): keep out.
    if Loading[src] ~= token then return false end

    local set = status == 200 and type(body) == 'table' and M.validateSet(body.grants) or nil
    if set then
        storeIfNewer(src, set, notify)
        M.writeCache(discordId, set)
        return true
    end

    Core.warn('grants for player %d (discord %s) unavailable from fredpd_service (HTTP %d); using fredpd_grant_cache',
        src, discordId, status)
    local cached = M.readCache(discordId)
    if Loading[src] ~= token then return false end
    if cached then
        storeIfNewer(src, cached, notify)
    elseif Cache[src] == nil then
        Core.warn('no cached grants for discord %s: empty grant set', discordId)
        store(src, Grants.empty(), notify)
    else
        Core.warn('no cached grants for discord %s: keeping the grants player %d already has', discordId, src)
    end
    return false
end

--- Fetch the player's grants from the service (fallback: fredpd_grant_cache, then an empty set). Awaits; run it in
--- a thread. Returns true when the service answered. A set older than the one the player holds is ignored.
--- While a load for the player is in flight, another request only queues one more load after it (so a burst of
--- /recompute calls costs at most one extra fetch per player, and a change committed during the first fetch is
--- still picked up by the second).
--- @param src integer
--- @param notify boolean push fredpd:client:grantsChanged to the player
function M.load(src, notify)
    src = tonumber(src)
    if not src then return false end
    if Loading[src] then
        Again[src] = { notify = (Again[src] ~= nil and Again[src].notify) or notify == true }
        return false
    end
    local token = {}
    Loading[src] = token
    local ok, result = pcall(loadOnce, src, notify, token)
    local owner = Loading[src] == token
    local again = nil
    if owner then
        Loading[src] = nil
        again, Again[src] = Again[src], nil
    end
    if again then Core.async('grant reload', M.load, src, again.notify) end
    if not ok then error(result, 0) end
    return result
end

--- Push from the service (POST /grants via http.js). Synchronous: updates every online player of that Discord user
--- that does not already hold a newer set and returns how many; the DB write runs in its own thread (and keeps the
--- newer row too). Returns false for invalid input.
--- @param discordId string
--- @param grants table GrantSet
--- @return integer|false
function M.applyGrants(discordId, grants)
    if type(discordId) ~= 'string' or not discordId:match('^%d+$') or #discordId > 20 then
        Core.warn('applyGrants: invalid discord id %s', tostring(discordId))
        return false
    end
    local set, field = M.validateSet(grants)
    if not set then
        Core.warn('applyGrants(%s): invalid GrantSet (%s)', discordId, field)
        return false
    end
    -- A fetch still in flight is not cancelled: whichever of the two sets is newer (computedAt) stays.
    local applied = 0
    for _, src in ipairs(sourcesOf(discordId)) do
        if storeIfNewer(src, set, true) then
            applied = applied + 1
        else
            Core.warn('applyGrants(%s): ignored a set computed at %s, older than the one player %d has (%s)',
                discordId, tostring(set.computedAt), src, tostring(Cache[src].computedAt))
        end
    end
    Core.async('grant cache write', M.writeCache, discordId, set)
    return applied
end

--- Re-fetch grants for the given Discord ids (nil = every online player). Returns how many loads were started.
--- @param discordIds string[]|nil
--- @return integer
function M.recompute(discordIds)
    local wanted = nil
    if type(discordIds) == 'table' then
        wanted = {}
        for _, id in ipairs(discordIds) do
            if type(id) == 'string' then wanted[id] = true end
        end
    end
    local n = 0
    for _, src in ipairs(Core.players()) do
        local id = DiscordOf[src] or Core.discordIdOf(src)
        if id and (wanted == nil or wanted[id]) then
            n = n + 1
            Core.async('grant recompute', M.load, src, true)
        end
    end
    return n
end

---------------------------------------------------------------------------------------------------------------
-- Read access (exports hand out copies; the raw accessors are for fredpd_core modules only)

--- The cached set itself (do not modify). Internal to fredpd_core.
function M.rawSet(src)
    return Cache[tonumber(src)]
end

function M.hasGrant(src, grantType, key)
    return Grants.has(Cache[tonumber(src)], grantType, key)
end

function M.getGrants(src)
    return M.copySet(Cache[tonumber(src)])
end

function M.getTier(src)
    local set = Cache[tonumber(src)]
    return set and set.tier or 0
end

function M.getUnits(src)
    return M.copySet(Cache[tonumber(src)]).units
end

--- Discord id of an online player (cached after join).
function M.getDiscordId(src)
    src = tonumber(src)
    if not src then return nil end
    return DiscordOf[src] or Core.discordIdOf(src)
end

--- Portal actors (server/virtual.lua): the set the service resolved for this portal request, held like a player's
--- so every export above answers for the actor. A /grants push for the same Discord user also updates it (sourcesOf).
function M.setVirtual(src, discordId, set)
    Cache[src], DiscordOf[src], Served[src] = set, discordId, nil
end

function M.clearVirtual(src)
    Cache[src], DiscordOf[src], Loading[src], Again[src], Served[src] = nil, nil, nil, nil, nil
end

---------------------------------------------------------------------------------------------------------------
-- fredpd_identities (Discord user <-> game account), fire-and-forget from event handlers

--- Record which character a Discord user is playing (called when a character loads).
function M.recordCharacter(src, playerData)
    local discordId = M.getDiscordId(src)
    if not discordId or type(playerData) ~= 'table' or type(playerData.citizenid) ~= 'string' then return end
    local license = type(playerData.license) == 'string' and playerData.license or nil
    local marks, params = Core.bindRow({ discordId, license, playerData.citizenid }, 3)
    local upsert = M.IDENTITY_CHARACTER_SQL:format(marks)
    Core.async('identity write', function()
        if not license then
            MySQL.update.await(upsert, params)
            return
        end
        local ok = MySQL.transaction.await({
            { query = M.IDENTITY_SESSIONS_UNLINK_SQL, values = { license, discordId } },
            { query = M.IDENTITY_UNLINK_SQL, values = { license, discordId } },
            { query = upsert, values = params },
        })
        if not ok then error('identity transaction failed', 0) end
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Wiring

--- Load grants for players already online (resource restart).
function M.loadOnline()
    for _, src in ipairs(Core.players()) do
        Core.async('grant load', M.load, src, true)
    end
end

function M.register()
    exports('hasGrant', M.hasGrant)
    exports('getGrants', M.getGrants)
    exports('getTier', M.getTier)
    exports('getUnits', M.getUnits)
    -- Only for server/http.js (POST /grants, /recompute): refused for every other resource (Core.internalExport).
    -- fredpd_devtools' /fredpd_devgrant may call it on a dev server only (set fredpd_dev true), never in production.
    Core.internalExport('applyGrants', M.applyGrants,
        type(GetConvar) == 'function' and GetConvar('fredpd_dev', 'false') == 'true' and { 'fredpd_devtools' } or nil)
    Core.internalExport('recomputeGrants', M.recompute)

    AddEventHandler('playerJoining', function()
        local src = tonumber(source)
        if not src then return end
        Core.async('grant load', M.load, src, false)
        local discordId = Core.discordIdOf(src)
        if discordId then
            Core.async('identity write', function() MySQL.update.await(M.IDENTITY_SEEN_SQL, { discordId }) end)
        end
    end)

    AddEventHandler('playerDropped', function()
        local src = tonumber(source)
        if not src then return end
        Cache[src], DiscordOf[src], Loading[src], Again[src], Served[src] = nil, nil, nil, nil, nil
        Core.clearRateLimits(src)
    end)

    -- Client copy for building menus only (the server re-checks every action). The player's own grants need no
    -- grant check. A rate-limited call is still answered, with the copy built last time (never nil: the NUI would
    -- read nil as "no grants" when it asks twice on open); only an allowed call builds a fresh copy, and a grant
    -- change drops the memo, so a spamming client cannot make the server copy anything.
    lib.callback.register('fredpd:getMyGrants', function(source)
        local src = tonumber(source)
        if not src then return M.copySet(nil) end
        if Core.rateLimit(src, 'getMyGrants', 250) or not Served[src] then
            Served[src] = M.copySet(Cache[src])
        end
        return Served[src]
    end)
end

return M
