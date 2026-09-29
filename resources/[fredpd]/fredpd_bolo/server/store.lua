-- SPDX-License-Identifier: GPL-3.0-only
-- SQL for fredpd_bolos (db/migrations/004_bolo.sql, 010_plate_checks.sql) and the registry lookups behind a plate
-- check (fredpd_vehicles_idx / fredpd_persons, the fredpd_core mirrors). The awaiting functions must run in a thread
-- (event handlers, callbacks and export calls run in one); expire() and insertCheck() never wait.
--
-- Times: written with UTC_TIMESTAMP(), read with Time.isoSelect (ISO-8601 UTC strings, never oxmysql's host-local
-- epoch numbers; docs/contracts.md §C7, §C12). The isoSelect fragments contain '%': SQL that includes them is built
-- by concatenation only, never through string.format.
--
-- An entry (the loader's output, also what the in-memory cache holds) is the wire Bolo (mdt.ts BoloSchema) plus the
-- fields visibility needs, which never go on the wire: unit, issuedByCid, flagActive (the `active` column) and
-- expiresEpoch (unix seconds of expires_at). Visibility.wire() copies the schema fields out.

local Time = require '@fredpd_core.shared.time'

local M = {}

M.PAGE_SIZE = 50 -- PAGE_SIZE in packages/types/src/mdt.ts
M.SUBJECT_LIMIT = 20 -- BOLOs per person/vehicle page

--- Locale function for subject labels; server/main.lua sets it to fredpd_core's L.
M.L = function(key) return key end

-- A BOLO is active iff active = 1 AND (expires_at IS NULL OR expires_at > UTC_TIMESTAMP()).
M.LIVE_SQL = '(b.active = 1 AND (b.expires_at IS NULL OR b.expires_at > UTC_TIMESTAMP()))'

M.SELECT = 'SELECT b.id, b.kind, b.citizenid, b.plate, b.reason, b.level, b.unit, b.issued_by, b.active, '
    .. 'b.resolved_by, b.resolve_note, '
    .. Time.isoSelect('b.created_at', 'created_at') .. ', '
    .. Time.isoSelect('b.expires_at', 'expires_at') .. ', '
    .. Time.isoSelect('b.resolved_at', 'resolved_at') .. ', '
    .. 'p.firstname, p.lastname, v.model, '
    .. 'io.display_name AS issued_name, io.callsign AS issued_callsign, io.unit AS issued_unit, '
    .. 'ro.display_name AS resolved_name, ro.callsign AS resolved_callsign, ro.unit AS resolved_unit '
    .. 'FROM fredpd_bolos b '
    .. "LEFT JOIN fredpd_persons p ON b.kind = 'person' AND p.citizenid = b.citizenid "
    .. "LEFT JOIN fredpd_vehicles_idx v ON b.kind = 'vehicle' AND v.plate = b.plate "
    .. 'LEFT JOIN fredpd_officers io ON io.citizenid = b.issued_by '
    .. 'LEFT JOIN fredpd_officers ro ON ro.citizenid = b.resolved_by '

-- Resolve only a BOLO that is still active by the definition above (%s: bindRow marks for resolved_by, note).
M.RESOLVE_SQL = 'UPDATE fredpd_bolos b SET b.active = 0, b.resolved_by = %s, b.resolved_at = UTC_TIMESTAMP(), '
    .. 'b.resolve_note = %s, b.updated_at = UTC_TIMESTAMP() WHERE b.id = ? AND ' .. M.LIVE_SQL

-- Lazy expiry (no timers): the caller decided from expires_at and the FXServer clock that the BOLO has run out; the
-- row is only deactivated when the database clock agrees (a host clock running ahead must not end a BOLO early).
M.EXPIRE_SQL = 'UPDATE fredpd_bolos SET active = 0, updated_at = UTC_TIMESTAMP() '
    .. 'WHERE id = ? AND active = 1 AND expires_at IS NOT NULL AND expires_at <= UTC_TIMESTAMP()'

M.VEHICLE_SQL = 'SELECT v.plate, v.citizenid, v.model, p.firstname, p.lastname FROM fredpd_vehicles_idx v '
    .. 'LEFT JOIN fredpd_persons p ON p.citizenid = v.citizenid WHERE v.plate = ?'

M.PERSON_SQL = 'SELECT citizenid, firstname, lastname FROM fredpd_persons WHERE citizenid = ?'

M.CHECK_SQL = 'INSERT INTO fredpd_plate_checks (plate, officer_citizenid, hit, bolo_id, source, created_at) '
    .. 'VALUES (%s, UTC_TIMESTAMP())'

---------------------------------------------------------------------------------------------------------------
-- Helpers

--- '?, ?, ?' for n values.
local function marks(n)
    return ('?'):rep(n, ', ')
end
M.marks = marks

--- Placeholders for values that may be nil: a nil becomes a literal NULL (a Lua array with holes does not reach
--- oxmysql as an array; same rule as fredpd_core Core.bindRow).
local function bindRow(values, n, params)
    params = params or {}
    local out = {}
    for i = 1, n do
        if values[i] == nil then
            out[i] = 'NULL'
        else
            out[i] = '?'
            params[#params + 1] = values[i]
        end
    end
    return table.concat(out, ', '), params
end
M.bindRow = bindRow

local function str(v)
    if v == nil or type(v) == 'userdata' then return nil end -- userdata: a JSON null from some drivers
    local s = tostring(v)
    if s == '' then return nil end
    return s
end
M.str = str

local function num(v)
    return tonumber(v)
end

--- TINYINT(1): oxmysql gives a boolean, the test shim a number.
local function truthy(v)
    return v == true or tonumber(v) == 1
end

--- OfficerRef (mdt.ts): Discord display name + callsign from fredpd_officers (§4.9); an officer without a row is
--- shown by the citizenid (never a character name).
local function officerRef(citizenid, displayName, callsign, unit)
    local cid = str(citizenid)
    if not cid then return nil end
    callsign = str(callsign)
    return { citizenid = cid, displayName = str(displayName) or callsign or cid, callsign = callsign, unit = str(unit) }
end
M.officerRef = officerRef

--- Subject label: person name (mirror) or plate + model; the citizenid / bare plate when the mirror has no row,
--- common.unknown ("Okänt") when there is neither.
function M.subject(kind, citizenid, plate, firstname, lastname, model)
    if kind == 'person' then
        local name = ((str(firstname) or '') .. ' ' .. (str(lastname) or '')):gsub('^%s+', ''):gsub('%s+$', '')
        if name ~= '' then return name end
        return citizenid or M.L('common.unknown')
    end
    if plate and str(model) then return M.L('bolo.subject.vehicle', { plate = plate, model = str(model) }) end
    return plate or M.L('common.unknown')
end

--- One fredpd_bolos row (M.SELECT) -> entry.
function M.rowToEntry(row)
    local kind = str(row.kind)
    local citizenid, plate = str(row.citizenid), str(row.plate)
    local expiresAt = Time.toIsoUtc(str(row.expires_at))
    return {
        id = math.tointeger(num(row.id)),
        kind = kind,
        citizenid = citizenid,
        plate = plate,
        subject = M.subject(kind, citizenid, plate, row.firstname, row.lastname, row.model),
        reason = str(row.reason) or '',
        level = math.tointeger(num(row.level)) or 0,
        issuedBy = officerRef(row.issued_by, row.issued_name, row.issued_callsign, row.issued_unit),
        createdAt = Time.toIsoUtc(str(row.created_at)),
        expiresAt = expiresAt,
        resolvedBy = officerRef(row.resolved_by, row.resolved_name, row.resolved_callsign, row.resolved_unit),
        resolvedAt = Time.toIsoUtc(str(row.resolved_at)),
        resolveNote = str(row.resolve_note),
        -- not on the wire
        unit = str(row.unit),
        issuedByCid = str(row.issued_by),
        flagActive = truthy(row.active),
        expiresEpoch = expiresAt and Time.toEpoch(expiresAt) or nil,
    }
end

local function rowsToEntries(rows)
    local out = {}
    for _, row in ipairs(rows or {}) do
        local e = M.rowToEntry(row)
        if e.id then out[#out + 1] = e end
    end
    return out
end

---------------------------------------------------------------------------------------------------------------
-- Loaders (await)

--- Entries for ids, in the order given (missing ids skipped).
function M.loadIds(ids)
    if #ids == 0 then return {} end
    local byId = {}
    for _, e in ipairs(rowsToEntries(MySQL.query.await(M.SELECT .. 'WHERE b.id IN (' .. marks(#ids) .. ')', ids))) do
        byId[e.id] = e
    end
    local out = {}
    for _, id in ipairs(ids) do
        if byId[id] then out[#out + 1] = byId[id] end
    end
    return out
end

--- @return table|nil entry
function M.loadOne(id)
    return M.loadIds({ id })[1]
end

--- Every row with active = 1 (expired ones included: the cache expires them). Rebuild source.
function M.loadActive()
    return rowsToEntries(MySQL.query.await(M.SELECT .. 'WHERE b.active = 1 ORDER BY b.id'))
end

--- BOLOs of one person (kind 'person', citizenid) or vehicle (kind 'vehicle', normalised plate): flagged-active
--- first, then newest, at most SUBJECT_LIMIT. Uses idx_citizen_active / idx_plate_active.
function M.forSubject(kind, key)
    local col = kind == 'person' and 'b.citizenid' or 'b.plate'
    return rowsToEntries(MySQL.query.await(M.SELECT .. "WHERE b.kind = ? AND " .. col .. ' = ? '
        .. 'ORDER BY b.active DESC, b.id DESC LIMIT ' .. ('%d'):format(M.SUBJECT_LIMIT), { kind, key }))
end

--- One page of ids (newest first) and the total, for rows matching `where` (a trusted fragment with `params`).
--- @return integer[] ids, integer total
function M.page(where, params, page)
    local from = 'FROM fredpd_bolos b' .. (where and where ~= '' and (' WHERE ' .. where) or '')
    local total = math.tointeger(num(MySQL.scalar.await('SELECT COUNT(*) ' .. from, params))) or 0
    local offset = (page - 1) * M.PAGE_SIZE -- page is a validated integer 1..10000
    local rows = MySQL.query.await('SELECT b.id ' .. from .. ' ORDER BY b.id DESC LIMIT '
        .. ('%d OFFSET %d'):format(M.PAGE_SIZE, offset), params) or {}
    local ids = {}
    for _, row in ipairs(rows) do ids[#ids + 1] = math.tointeger(num(row.id)) end
    return ids, total
end

--- Registry row for a normalised plate: { plate, model?, owner = { citizenid, name }? } or nil.
function M.vehicle(plate)
    local row = MySQL.single.await(M.VEHICLE_SQL, { plate })
    if not row then return nil end
    local cid = str(row.citizenid)
    local owner = nil
    if cid then
        local name = ((str(row.firstname) or '') .. ' ' .. (str(row.lastname) or '')):gsub('^%s+', ''):gsub('%s+$', '')
        owner = { citizenid = cid, name = name ~= '' and name or M.L('common.unknown') }
    end
    return { plate = str(row.plate) or plate, model = str(row.model), owner = owner }
end

--- Mirror row of a person: { citizenid, name } or nil.
function M.person(citizenid)
    local row = MySQL.single.await(M.PERSON_SQL, { citizenid })
    if not row then return nil end
    return { citizenid = str(row.citizenid) or citizenid, name = M.subject('person', citizenid, nil, row.firstname,
        row.lastname) }
end

---------------------------------------------------------------------------------------------------------------
-- Writes

--- Insert a validated BoloCreateInput for `actor` ({ citizenid, unit? }). Returns the new id, or nil when an
--- active BOLO for the same subject exists (the service checks its in-memory map first; the NOT EXISTS guard closes
--- the race with a second writer). expiresInHours is a validated integer 1..720, written as a literal.
function M.insert(input, actor)
    local params = { input.kind }
    local cidMark = bindRow({ input.citizenid }, 1, params)
    local plateMark = bindRow({ input.plate }, 1, params)
    params[#params + 1] = input.reason
    params[#params + 1] = input.level
    local unitMark = bindRow({ actor.unit }, 1, params)
    params[#params + 1] = actor.citizenid
    local expires = input.expiresInHours
        and ('UTC_TIMESTAMP() + INTERVAL %d HOUR'):format(input.expiresInHours) or 'NULL'
    -- NOT EXISTS subject
    params[#params + 1] = input.kind
    local same
    if input.kind == 'person' then
        same = 'x.citizenid = ?'
        params[#params + 1] = input.citizenid
    else
        same = 'x.plate = ?'
        params[#params + 1] = input.plate
    end
    -- column order: kind, citizenid, plate, reason, level, unit, issued_by, expires_at
    local sql = 'INSERT INTO fredpd_bolos (kind, citizenid, plate, reason, level, unit, issued_by, expires_at, '
        .. 'active, created_at, updated_at) SELECT ?, ' .. cidMark .. ', ' .. plateMark .. ', ?, ?, ' .. unitMark
        .. ', ?, ' .. expires .. ', 1, UTC_TIMESTAMP(), UTC_TIMESTAMP() FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM '
        .. 'fredpd_bolos x WHERE x.kind = ? AND ' .. same .. ' AND x.active = 1 AND (x.expires_at IS NULL OR '
        .. 'x.expires_at > UTC_TIMESTAMP()))'
    local id = math.tointeger(num(MySQL.insert.await(sql, params)))
    if not id or id < 1 then return nil end
    return id
end

--- Resolve an active BOLO. @return boolean resolved (false: missing, already resolved or expired)
function M.resolve(id, citizenid, note)
    local params = {}
    local byMark = bindRow({ citizenid }, 1, params)
    local noteMark = bindRow({ note }, 1, params)
    params[#params + 1] = id
    return (num(MySQL.update.await(M.RESOLVE_SQL:format(byMark, noteMark), params)) or 0) > 0
end

--- Deactivate an expired BOLO without waiting; cb(affectedRows) runs when the update is done (0: resolved or expired
--- elsewhere, or not yet expired by the database clock).
function M.expire(id, cb)
    MySQL.update(M.EXPIRE_SQL, { id }, function(affected)
        if cb then cb(num(affected) or 0) end
    end)
end

--- Record a plate check without waiting. row = { plate, officer?, hit, boloId?, source }.
function M.insertCheck(row, cb)
    local placeholders, params = bindRow({ row.plate, row.officer, row.hit and 1 or 0, row.boloId, row.source }, 5)
    MySQL.insert(M.CHECK_SQL:format(placeholders), params, function(id)
        if cb then cb(id) end
    end)
end

return M
