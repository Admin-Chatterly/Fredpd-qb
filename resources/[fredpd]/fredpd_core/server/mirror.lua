-- SPDX-License-Identifier: GPL-3.0-only
-- Search mirror tables (IMPLEMENTATION.md §4.2, task 1.4): fredpd_persons and fredpd_vehicles_idx, so searches never
-- read players.charinfo (JSON, unindexable). Filled by:
--   * qbx_core character events (names VERIFY, see docs/modules/core.md): one upsert per character when a mirrored
--     field actually changed (an in-memory fingerprint skips the frequent SetPlayerData calls for money etc.);
--   * M.backfill(): one pass over players / player_vehicles in batches of 500 (the only place charinfo is read in
--     bulk), started from fredpd_devtools' /fredpd_backfill through the backfillMirror export;
--   * M.refreshPlate(plate): a lookup miss re-reads that one plate from player_vehicles.
-- The mirrors are derived caches of qbx data, so a row change is not audited; backfill and dev seeding write one
-- audit row per run.

local Core = require 'server.core'
local Audit = require 'server.audit'
local Perms = require 'server.perms'

local M = {}

M.BATCH = 500
M.DEV_PREFIX = 'DEV'
M.PERSON_COLUMNS = { 'citizenid', 'firstname', 'lastname', 'birthdate', 'personnummer', 'gender', 'phone', 'license' }
M.PERSON_UPDATE = { 'firstname', 'lastname', 'birthdate', 'personnummer', 'gender', 'phone', 'license' }
M.VEHICLE_COLUMNS = { 'plate', 'citizenid', 'model' }
M.VEHICLE_UPDATE = { 'citizenid', 'model' }

local Synced = {} -- [citizenid] = fingerprint of the last row written this session

---------------------------------------------------------------------------------------------------------------
-- Pure mapping (tests/lua/core_mirror_test.lua)

--- Trimmed string cut to `max` characters (UTF-8 aware); nil when empty or not a string/number.
function M.clean(v, max)
    if type(v) == 'number' then v = math.tointeger(v) and ('%d'):format(v) or tostring(v) end
    if type(v) ~= 'string' then return nil end
    v = v:gsub('^%s+', ''):gsub('%s+$', '')
    if v == '' then return nil end
    if not utf8.len(v) then v = v:gsub('[\128-\255]', '?') end -- invalid UTF-8 would fail a strict INSERT
    if utf8.len(v) > max then v = v:sub(1, utf8.offset(v, max + 1) - 1) end
    return v
end

local function validDate(y, m, d)
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if not (y and m and d) or y < 1850 or y > 2200 or m < 1 or m > 12 or d < 1 then return nil end
    local dim = { 31, (y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)) and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    if d > dim[m] then return nil end
    return ('%04d-%02d-%02d'):format(y, m, d)
end

--- charinfo.birthdate -> 'YYYY-MM-DD'. Accepts ISO (qbx default, optionally with a time part), YYYY/MM/DD and the
--- European DD-MM-YYYY / DD/MM/YYYY / DD.MM.YYYY. Anything else -> nil.
function M.parseBirthdate(v)
    if type(v) ~= 'string' then return nil end
    local y, m, d = v:match('^(%d%d%d%d)[-/](%d%d?)[-/](%d%d?)')
    if y then return validDate(y, m, d) end
    d, m, y = v:match('^(%d%d?)[-/.](%d%d?)[-/.](%d%d%d%d)$')
    if y then return validDate(y, m, d) end
    return nil
end

--- qbx charinfo.gender (0 man, 1 kvinna; some scripts store strings) -> 0 | 1 | nil.
function M.parseGender(v)
    local n = tonumber(v)
    if n == 0 or n == 1 then return math.tointeger(n) end
    if type(v) == 'string' then
        local s = v:lower()
        if s == 'male' or s == 'man' or s == 'm' then return 0 end
        if s == 'female' or s == 'kvinna' or s == 'woman' or s == 'f' or s == 'k' then return 1 end
    end
    return nil
end

--- Swedish control digit (Luhn over the 9 digits YYMMDDNNN).
function M.luhn(digits)
    local sum = 0
    for i = 1, #digits do
        local n = tonumber(digits:sub(i, i)) * (i % 2 == 1 and 2 or 1)
        sum = sum + (n > 9 and n - 9 or n)
    end
    return (10 - sum % 10) % 10
end

--- 32-bit FNV-1a, a cheap stable hash for deriving the birth number.
local function fnv1a(s)
    local h = 2166136261
    for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) & 0xffffffff end
    return h
end

--- Personnummer stored as 'YYYYMMDD-NNNC' (digits, dash before the last four; 002_index.sql).
--- qbx characters have none, so unless charinfo carries one (charinfo.personnummer, 10 or 12 digits) it is derived
--- from the birthdate and the citizenid: a stable birth number whose third digit is odd for men and even for women,
--- plus a valid control digit. Two characters born the same day collide with probability ~1/1000.
--- @return string|nil
function M.personnummer(citizenid, birthdate, gender, explicit)
    if type(explicit) == 'string' or type(explicit) == 'number' then
        local digits = tostring(explicit):gsub('%D', '')
        if #digits == 10 or #digits == 12 then return digits:sub(1, -5) .. '-' .. digits:sub(-4) end
    end
    if type(birthdate) ~= 'string' or type(citizenid) ~= 'string' then return nil end
    local ymd = birthdate:gsub('-', '')
    if not ymd:match('^%d%d%d%d%d%d%d%d$') then return nil end
    local n = fnv1a(citizenid) % 1000
    if gender == 0 and n % 2 == 0 then n = n + 1 end
    if gender == 1 and n % 2 == 1 then n = n - 1 end
    local nnn = ('%03d'):format(n)
    return ymd .. '-' .. nnn .. M.luhn(ymd:sub(3) .. nnn)
end

--- fredpd_persons row from a citizenid and charinfo (table, or the JSON text of players.charinfo).
--- extra = { license?, phone? } (phone falls back to players.phone_number). nil if the citizenid is unusable.
function M.personRow(citizenid, charinfo, extra)
    if type(citizenid) ~= 'string' or citizenid == '' or #citizenid > 50 then return nil end
    if type(charinfo) == 'string' then
        local ok, decoded = pcall(json.decode, charinfo)
        charinfo = ok and decoded or nil
    end
    if type(charinfo) ~= 'table' then charinfo = {} end
    extra = extra or {}
    local birthdate = M.parseBirthdate(charinfo.birthdate)
    local gender = M.parseGender(charinfo.gender)
    return {
        citizenid = citizenid,
        firstname = M.clean(charinfo.firstname, 64) or '',
        lastname = M.clean(charinfo.lastname, 64) or '',
        birthdate = birthdate,
        personnummer = M.personnummer(citizenid, birthdate, gender, charinfo.personnummer),
        gender = gender,
        phone = M.clean(charinfo.phone, 20) or M.clean(extra.phone, 20),
        license = M.clean(extra.license, 64),
    }
end

--- Plate as stored in fredpd_vehicles_idx: ASCII upper case, all whitespace removed (same as detectSearchType).
function M.normalizePlate(plate)
    if type(plate) ~= 'string' then return nil end
    local p = plate:gsub('%s', ''):upper()
    if p == '' or #p > 16 then return nil end
    return p
end

--- The normalised plate and the spellings player_vehicles may hold it under ('ABC12D', 'ABC 12D').
function M.plateCandidates(plate)
    local p = M.normalizePlate(plate)
    if not p then return nil end
    local list = { p }
    if #p == 6 then list[2] = p:sub(1, 3) .. ' ' .. p:sub(4) end
    return p, list
end

function M.vehicleRow(plate, citizenid, model)
    local p = M.normalizePlate(plate)
    if not p then return nil end
    return {
        plate = p,
        citizenid = type(citizenid) == 'string' and citizenid ~= '' and citizenid:sub(1, 50) or nil,
        model = M.clean(model, 64),
    }
end

local FIELD_SEP = '\31'
function M.fingerprint(row)
    local parts = {}
    for i, col in ipairs(M.PERSON_COLUMNS) do parts[i] = tostring(row[col]) end
    return table.concat(parts, FIELD_SEP)
end

---------------------------------------------------------------------------------------------------------------
-- Writes (await; call from a thread)

local function writeBatches(tbl, columns, rows, update)
    local written = 0
    for first = 1, #rows, M.BATCH do
        local chunk = table.move(rows, first, math.min(first + M.BATCH - 1, #rows), 1, {})
        local sql, params = Core.buildInsert(tbl, columns, chunk, update)
        local affected = MySQL.update.await(sql, params)
        written = written + (update and #chunk or (tonumber(affected) or 0))
    end
    return written
end

--- Upsert persons (rows from M.personRow). Returns the number of rows sent.
function M.upsertPersons(rows)
    return writeBatches('fredpd_persons', M.PERSON_COLUMNS, rows, M.PERSON_UPDATE)
end

--- Upsert vehicles (rows from M.vehicleRow). Returns the number of rows sent.
function M.upsertVehicles(rows)
    return writeBatches('fredpd_vehicles_idx', M.VEHICLE_COLUMNS, rows, M.VEHICLE_UPDATE)
end

local vehicleTable -- nil = unknown, true/false after the first check
function M.hasVehicleTable()
    if vehicleTable == nil then
        vehicleTable = (tonumber(MySQL.scalar.await('SELECT COUNT(*) FROM information_schema.tables '
            .. "WHERE table_schema = DATABASE() AND table_name = 'player_vehicles'")) or 0) > 0
    end
    return vehicleTable
end

--- Synchronous half of a sync (no DB, no thread): the fredpd_persons row to write when a mirrored field changed
--- since the last write, else nil. The fingerprint is recorded at once, so a burst of SetPlayerData events for one
--- change starts a single write.
function M.claimRow(pd)
    if type(pd) ~= 'table' then return nil end
    local row = M.personRow(pd.citizenid, pd.charinfo, { license = pd.license })
    if not row then return nil end
    local fp = M.fingerprint(row)
    if Synced[row.citizenid] == fp then return nil end
    Synced[row.citizenid] = fp
    return row
end

--- Write a row from M.claimRow (awaits). On failure the fingerprint is dropped so the next event tries again.
function M.writeClaimed(row)
    local ok, err = pcall(M.upsertPersons, { row })
    if not ok then
        Synced[row.citizenid] = nil
        Core.error('mirror upsert for %s failed: %s', row.citizenid, tostring(err))
        return false
    end
    return true
end

--- Mirror one character from qbx PlayerData if a mirrored field changed (awaits). Returns true when it wrote.
function M.syncPlayerData(pd)
    local row = M.claimRow(pd)
    if not row then return false end
    return M.writeClaimed(row)
end

--- Re-read one plate from player_vehicles into fredpd_vehicles_idx (after a lookup miss). Returns the row or nil.
function M.refreshPlate(plate)
    local normalized, candidates = M.plateCandidates(plate)
    if not normalized or not M.hasVehicleTable() then return nil end
    local marks = ('?, '):rep(#candidates):sub(1, -3)
    local found = MySQL.single.await('SELECT plate, citizenid, vehicle FROM player_vehicles WHERE plate IN ('
        .. marks .. ') LIMIT 1', candidates)
    if not found then return nil end
    local row = M.vehicleRow(found.plate, found.citizenid, found.vehicle)
    if row then M.upsertVehicles({ row }) end
    return row
end

--- Rebuild both mirrors from players / player_vehicles, 500 rows per query (keyset pagination). Returns
--- { persons = n, vehicles = n }. Writes one audit row (actor: the admin who ran it, or the system).
function M.backfill(src)
    local persons, vehicles = 0, 0
    local last = ''
    for _ = 1, 1000000 do -- bounded by the table size; each pass reads one batch
        local rows = MySQL.query.await('SELECT citizenid, license, charinfo, phone_number FROM players '
            .. 'WHERE citizenid > ? ORDER BY citizenid LIMIT ' .. M.BATCH, { last }) or {}
        if #rows == 0 then break end
        local out = {}
        for _, r in ipairs(rows) do
            local row = M.personRow(tostring(r.citizenid), r.charinfo, { license = r.license, phone = r.phone_number })
            if row then out[#out + 1] = row end
        end
        if #out > 0 then persons = persons + M.upsertPersons(out) end
        last = tostring(rows[#rows].citizenid)
        if #rows < M.BATCH then break end
    end
    Synced = {} -- fingerprints may no longer match what is stored

    if M.hasVehicleTable() then
        local lastId = 0
        for _ = 1, 1000000 do
            local rows = MySQL.query.await('SELECT id, plate, citizenid, vehicle FROM player_vehicles '
                .. 'WHERE id > ? ORDER BY id LIMIT ' .. M.BATCH, { lastId }) or {}
            if #rows == 0 then break end
            local out = {}
            for _, r in ipairs(rows) do
                local row = M.vehicleRow(r.plate, r.citizenid and tostring(r.citizenid), r.vehicle)
                if row then out[#out + 1] = row end
            end
            if #out > 0 then vehicles = vehicles + M.upsertVehicles(out) end
            lastId = tonumber(rows[#rows].id) or lastId
            if #rows < M.BATCH then break end
        end
    end

    Audit.audit(src or 0, 'mirror.backfill', 'mirror', nil, { persons = persons, vehicles = vehicles })
    return { persons = persons, vehicles = vehicles }
end

--- Insert fake persons/vehicles for development (fredpd_devtools /fredpd_seed). Every citizenid must start with
--- M.DEV_PREFIX; INSERT IGNORE never overwrites an existing row. Returns { persons = n, vehicles = n } inserted.
--- @param src integer admin who ran it (audit actor)
--- @param persons table[] { citizenid, firstname, lastname, birthdate, gender, phone }
--- @param vehicles table[] { plate, citizenid, model }
function M.insertDevRows(src, persons, vehicles)
    local prefix = '^' .. M.DEV_PREFIX
    local personRows, vehicleRows = {}, {}
    for _, p in ipairs(type(persons) == 'table' and persons or {}) do
        if type(p) ~= 'table' or type(p.citizenid) ~= 'string' or not p.citizenid:find(prefix) then
            error('dev persons need a citizenid starting with ' .. M.DEV_PREFIX, 0)
        end
        personRows[#personRows + 1] = M.personRow(p.citizenid, p)
    end
    for _, v in ipairs(type(vehicles) == 'table' and vehicles or {}) do
        if type(v) ~= 'table' or type(v.citizenid) ~= 'string' or not v.citizenid:find(prefix) then
            error('dev vehicles need a citizenid starting with ' .. M.DEV_PREFIX, 0)
        end
        local row = M.vehicleRow(v.plate, v.citizenid, v.model)
        if row then vehicleRows[#vehicleRows + 1] = row end
    end
    local result = {
        persons = writeBatches('fredpd_persons', M.PERSON_COLUMNS, personRows, nil),
        vehicles = writeBatches('fredpd_vehicles_idx', M.VEHICLE_COLUMNS, vehicleRows, nil),
    }
    Audit.audit(src or 0, 'mirror.seed', 'mirror', nil, result)
    return result
end

---------------------------------------------------------------------------------------------------------------
-- Wiring

--- Mirror a player's current character (from qbx_core) and record it in fredpd_identities. Awaits.
function M.syncSource(src)
    local pd = Core.getPlayerData(src)
    if not pd then return false end
    Perms.recordCharacter(src, pd)
    return M.syncPlayerData(pd)
end

--- Mirror everyone online (resource restart).
function M.syncOnline()
    for _, src in ipairs(Core.players()) do Core.async('mirror sync', M.syncSource, src) end
end

function M.register()
    exports('refreshPlate', M.refreshPlate)
    exports('backfillMirror', M.backfill)
    exports('seedDevRows', M.insertDevRows)

    -- VERIFY (docs/modules/core.md): qbx_core event names. Every handler is idempotent (upsert + fingerprint), so
    -- a name that fires twice costs nothing. Only AddEventHandler: none of these may be triggered by a client.
    -- (QBCore:Server:OnPlayerLoaded is deliberately not handled: in the QB ecosystem the client fires it with
    -- TriggerServerEvent, so a local handler would never run and only cause "not safe for net" console noise.
    -- QBCore:Server:PlayerLoaded, fired by qbx_core's login on the server, covers the load.)
    AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
        local pd = type(player) == 'table' and player.PlayerData or nil
        local src = pd and tonumber(pd.source)
        Core.async('mirror on load', function()
            if src then M.syncSource(src) elseif pd then M.syncPlayerData(pd) end
        end)
    end)
    -- Fires on every PlayerData change (money, hunger, metadata): the fingerprint check runs right here, and a
    -- thread is only started when a mirrored field really changed.
    AddEventHandler('QBCore:Player:SetPlayerData', function(pd)
        local row = M.claimRow(pd)
        if row then Core.async('mirror on update', M.writeClaimed, row) end
    end)
    -- Last chance to catch a charinfo change whose event we did not see.
    AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
        src = tonumber(src) or tonumber(source)
        if src and src > 0 then Core.async('mirror on unload', M.syncSource, src) end
    end)
end

return M
