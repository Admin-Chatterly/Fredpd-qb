-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_evidence access (db/migrations/006_evidence.sql, 011_evidence.sql) plus the read-only lookups
-- fredpd_forensics needs: cases/assignees (fredpd_records' tables), officer names (fredpd_officers), person names
-- (fredpd_persons mirror) and the evidences registers (linked_fingerprint, linked_dna, firearms_registry;
-- noobsystems/evidences server/biometrics/linked_biometrics.lua:10-28, server/firearms/firearms.lua:10-24). Every
-- function awaits oxmysql: call it from a thread (event handlers, callbacks, SetTimeout callbacks and export calls
-- run in one).
--
-- The custody chain is a JSON array appended in SQL (JSON_ARRAY_APPEND in one UPDATE), so two appends to one row
-- never lose each other. It is capped at CHAIN_CAP entries: when full, the oldest entry after the first ('collect')
-- is dropped. Entry times come from the database clock: DATE_FORMAT(UTC_TIMESTAMP(), …) (docs/contracts.md §C7).
-- DATETIME columns are read through Time.isoSelect. The SQL is built by concatenation (the fragments contain '%').

local Time = require '@fredpd_core.shared.time'
local Evidence = require 'shared.evidence'

local M = {}

M.CHAIN_CAP = Evidence.CHAIN_CAP
M.NOW_ISO = "DATE_FORMAT(UTC_TIMESTAMP(), '%Y-%m-%dT%H:%i:%sZ')"
M.LIST_CAP = 500      -- rows scanned for the unlinked queue and the unfiltered list (newest first)
M.CASE_CAP = 1000     -- evidence rows read for one case

M.SELECT = 'SELECT e.id, e.item_uid, e.item_name, e.ident, e.type, e.case_id, e.n, e.tag, e.level, e.result, '
    .. 'e.collected_by, '
    .. Time.isoSelect('e.collected_at', 'collected_at') .. ', e.chain, c.case_number, c.status AS case_status, '
    .. 'c.unit AS case_unit, c.owner_citizenid AS case_owner, c.level AS case_level '
    .. 'FROM fredpd_evidence e LEFT JOIN fredpd_cases c ON c.id = e.case_id '

M.NEXT_N_SQL = 'SELECT COALESCE(MAX(n), 0) + 1 FROM fredpd_evidence WHERE case_id = ?'
M.CASE_COLS = 'SELECT id, case_number, status, level, unit, owner_citizenid FROM fredpd_cases '
M.LOCK_CASE_SQL = 'SELECT id FROM fredpd_cases WHERE id = ? FOR UPDATE'

---------------------------------------------------------------------------------------------------------------
-- Helpers

--- '?' for a value (appended to params) or a literal NULL for nil: a Lua array with nil holes does not reach
--- oxmysql as an array (same rule as fredpd_core Core.bindRow).
local function val(v, params)
    if v == nil then return 'NULL' end
    params[#params + 1] = v
    return '?'
end

--- JSON_OBJECT for one custody entry; `at` = ISO string or nil (database clock). Params appended in SQL order.
local function entrySql(e, params)
    local at = e.at and val(e.at, params) or M.NOW_ISO
    return "JSON_OBJECT('at', " .. at .. ", 'actor', " .. val(e.actor, params) .. ", 'action', "
        .. val(e.action, params) .. ", 'location', " .. val(e.location, params) .. ", 'note', "
        .. val(e.note, params) .. ')'
end
M.entrySql = entrySql

--- chain = chain + entry, keeping at most CHAIN_CAP entries (drops index 1 when full; index 0 is 'collect').
local function appendSql(e, params)
    params[#params + 1] = M.CHAIN_CAP
    return "chain = JSON_ARRAY_APPEND(IF(JSON_LENGTH(chain) >= ?, JSON_REMOVE(chain, '$[1]'), chain), '$', "
        .. entrySql(e, params) .. ')'
end

local function marks(n)
    return ('?'):rep(n, ', ')
end

local function str(v)
    if v == nil or type(v) == 'userdata' then return nil end
    return tostring(v)
end

local function decodeJson(v)
    if type(v) == 'table' then return v end
    if type(v) ~= 'string' or v == '' then return nil end
    local ok, decoded = pcall(json.decode, v)
    return ok and decoded or nil
end
M.decodeJson = decodeJson

--- fredpd_evidence (+ case) row -> plain table with decoded JSON; nil for no row.
function M.rowToEvidence(row)
    if type(row) ~= 'table' or row.id == nil then return nil end
    local chain = decodeJson(row.chain)
    return {
        id = math.tointeger(tonumber(row.id)),
        itemUid = str(row.item_uid),
        itemName = str(row.item_name),
        ident = str(row.ident),
        type = str(row.type),
        caseId = math.tointeger(tonumber(row.case_id)),
        n = math.tointeger(tonumber(row.n)),
        tag = str(row.tag),
        level = math.tointeger(tonumber(row.level)) or 0,
        result = decodeJson(row.result),
        collectedBy = str(row.collected_by),
        collectedAt = Time.toIsoUtc(str(row.collected_at)),
        chain = type(chain) == 'table' and chain or {},
        caseNumber = str(row.case_number),
        caseStatus = str(row.case_status),
        caseUnit = str(row.case_unit),
        caseOwner = str(row.case_owner),
        caseLevel = math.tointeger(tonumber(row.case_level)),
    }
end

local function rows(sql, params)
    local out = {}
    for i, row in ipairs(MySQL.query.await(sql, params) or {}) do out[i] = M.rowToEvidence(row) end
    return out
end

---------------------------------------------------------------------------------------------------------------
-- Writes

--- Create the row for a new item uid with its 'collect' entry. `r` = { uid, type, itemName?, ident?,
--- collectedBy?, collectedAt? (ISO; nil = now), location?, note? }. Returns true when this call created it
--- (INSERT IGNORE: false = it existed).
function M.insert(r)
    local params = { r.uid, r.type }
    local sql = 'INSERT IGNORE INTO fredpd_evidence (item_uid, type, item_name, ident, level, collected_by, '
        .. 'collected_at, chain, updated_at, created_at) VALUES (?, ?, ' .. val(r.itemName, params) .. ', '
        .. val(r.ident, params) .. ', 0, ' .. val(r.collectedBy, params) .. ', '
    if r.collectedAt then
        sql = sql .. val(Time.toDatetime(r.collectedAt), params) .. ', '
    else
        sql = sql .. 'UTC_TIMESTAMP(), '
    end
    sql = sql .. 'JSON_ARRAY(' .. entrySql({ at = r.collectedAt, actor = r.collectedBy, action = 'collect',
        location = r.location, note = r.note }, params) .. '), UTC_TIMESTAMP(), UTC_TIMESTAMP())'
    return (tonumber(MySQL.update.await(sql, params)) or 0) > 0
end

--- First sighting of the item behind a row created without it (before migration 011, or before evidences wrote the
--- evidence into the item): fill item_name / ident where still NULL, never overwrite. The caller re-reads the row
--- and compares, so a concurrent first sighting with other values is caught.
function M.recordIdentity(id, itemName, ident)
    local params = {}
    local sql = 'UPDATE fredpd_evidence SET item_name = COALESCE(item_name, ' .. val(itemName, params)
        .. '), ident = COALESCE(ident, ' .. val(ident, params)
        .. ') WHERE id = ? AND (item_name IS NULL OR ident IS NULL)'
    params[#params + 1] = id
    return (tonumber(MySQL.update.await(sql, params)) or 0) > 0
end

--- Append one custody entry { actor?, action, location?, note? } to evidence `id`. Returns true when a row changed.
function M.append(id, e)
    local params = {}
    local sql = 'UPDATE fredpd_evidence SET ' .. appendSql(e, params) .. ', updated_at = UTC_TIMESTAMP() WHERE id = ?'
    params[#params + 1] = id
    return (tonumber(MySQL.update.await(sql, params)) or 0) > 0
end

--- First analysis: store the result (plus `analysedAt`, database clock) and append 'analyse' in one statement, only
--- while result IS NULL. Returns true when this call analysed it (false = already analysed, e.g. concurrently).
function M.setAnalysed(id, result, e)
    -- An empty Lua table encodes as '[]'; the result is always a JSON object.
    local params = { (type(result) == 'table' and next(result) ~= nil) and json.encode(result) or '{}' }
    local sql = "UPDATE fredpd_evidence SET result = JSON_SET(?, '$.analysedAt', " .. M.NOW_ISO .. '), '
        .. appendSql(e, params)
        .. ', updated_at = UTC_TIMESTAMP() WHERE id = ? AND result IS NULL'
    params[#params + 1] = id
    return (tonumber(MySQL.update.await(sql, params)) or 0) > 0
end

--- Next per-case counter (MAX(n) + 1). Read before the link transaction; the (case_id, n) unique key catches a
--- concurrent link that took the same n, and the caller retries once with a fresh value.
function M.nextN(caseId)
    return math.tointeger(tonumber(MySQL.scalar.await(M.NEXT_N_SQL, { caseId }))) or 1
end

--- Link in one transaction: lock the case row (SELECT … FOR UPDATE), then set case_id, n, tag, level (never
--- lowered) and append the 'link' entry while the evidence is still unlinked. Returns the transaction's boolean
--- (false = rolled back, e.g. duplicate (case_id, n) or tag). A committed transaction whose UPDATE matched nothing
--- (linked elsewhere meanwhile) is detected by the caller's read-back.
function M.link(id, caseId, n, tag, caseLevel, e)
    local params = { caseId, n, tag, caseLevel or 0 }
    local sql = 'UPDATE fredpd_evidence SET case_id = ?, n = ?, tag = ?, level = GREATEST(level, ?), '
        .. appendSql(e, params) .. ', updated_at = UTC_TIMESTAMP() WHERE id = ? AND case_id IS NULL'
    params[#params + 1] = id
    return MySQL.transaction.await({
        { query = M.LOCK_CASE_SQL, values = { caseId } },
        { query = sql, values = params },
    }) == true
end

---------------------------------------------------------------------------------------------------------------
-- Evidence reads

function M.byId(id)
    return M.rowToEvidence(MySQL.single.await(M.SELECT .. 'WHERE e.id = ?', { id }))
end

function M.byUid(uid)
    return M.rowToEvidence(MySQL.single.await(M.SELECT .. 'WHERE e.item_uid = ?', { uid }))
end

function M.byCase(caseId)
    return rows(M.SELECT .. 'WHERE e.case_id = ? ORDER BY e.n, e.id LIMIT ' .. M.CASE_CAP, { caseId })
end

--- Analysed evidence not linked to a case yet (the Tekniker work queue), newest first.
function M.unlinked()
    return rows(M.SELECT .. 'WHERE e.case_id IS NULL AND e.result IS NOT NULL ORDER BY e.id DESC LIMIT ' .. M.LIST_CAP)
end

function M.recent()
    return rows(M.SELECT .. 'ORDER BY e.id DESC LIMIT ' .. M.LIST_CAP)
end

---------------------------------------------------------------------------------------------------------------
-- Cases (fredpd_records' tables, read only)

local function rowToCase(row)
    if type(row) ~= 'table' or row.id == nil then return nil end
    return {
        id = math.tointeger(tonumber(row.id)),
        caseNumber = str(row.case_number),
        status = str(row.status),
        level = math.tointeger(tonumber(row.level)) or 0,
        unit = str(row.unit),
        owner = str(row.owner_citizenid),
    }
end

function M.caseById(id)
    return rowToCase(MySQL.single.await(M.CASE_COLS .. 'WHERE id = ?', { id }))
end

function M.caseByNumber(caseNumber)
    return rowToCase(MySQL.single.await(M.CASE_COLS .. 'WHERE case_number = ?', { caseNumber }))
end

--- { [caseId] = { citizenid, … } } for a list of case ids.
function M.assignees(caseIds)
    local out, ids, seen = {}, {}, {}
    for _, id in ipairs(caseIds or {}) do
        if id and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
            out[id] = {}
        end
    end
    if #ids == 0 then return out end
    local list = MySQL.query.await('SELECT case_id, citizenid FROM fredpd_case_assignees WHERE case_id IN ('
        .. marks(#ids) .. ') ORDER BY case_id, citizenid', ids) or {}
    for _, row in ipairs(list) do
        local id = math.tointeger(tonumber(row.case_id))
        if id and out[id] then out[id][#out[id] + 1] = str(row.citizenid) end
    end
    return out
end

---------------------------------------------------------------------------------------------------------------
-- Names

--- { [citizenid] = { displayName, callsign, unit } } from fredpd_officers.
function M.officers(citizenids)
    local ids, seen, out = {}, {}, {}
    for _, cid in ipairs(citizenids or {}) do
        if type(cid) == 'string' and not seen[cid] then
            seen[cid] = true
            ids[#ids + 1] = cid
        end
    end
    if #ids == 0 then return out end
    local list = MySQL.query.await('SELECT citizenid, display_name, callsign, unit FROM fredpd_officers '
        .. 'WHERE citizenid IN (' .. marks(#ids) .. ')', ids) or {}
    for _, row in ipairs(list) do
        out[str(row.citizenid)] = { displayName = str(row.display_name), callsign = str(row.callsign),
            unit = str(row.unit) }
    end
    return out
end

--- 'Förnamn Efternamn' from the fredpd_persons mirror (never players.charinfo), or nil.
function M.personName(citizenid)
    local row = MySQL.single.await('SELECT firstname, lastname FROM fredpd_persons WHERE citizenid = ?', { citizenid })
    if type(row) ~= 'table' then return nil end
    local name = ((str(row.firstname) or '') .. ' ' .. (str(row.lastname) or '')):gsub('^%s+', ''):gsub('%s+$', '')
    return name ~= '' and name or nil
end

---------------------------------------------------------------------------------------------------------------
-- evidences registers (what the laptop's analysis compares against). A missing table (evidences not installed,
-- firearms registry disabled) is not an error: no match.

M.REGISTER_SQL = {
    fingerprint = 'SELECT identifier FROM linked_fingerprint WHERE fingerprint = ?',
    dna = 'SELECT identifier FROM linked_dna WHERE dna = ?',
    serial = 'SELECT identifier FROM firearms_registry WHERE serial = ?',
}

--- citizenid registered for a fingerprint / DNA string / weapon serial, or nil.
function M.registerMatch(kind, value)
    local sql = M.REGISTER_SQL[kind]
    if not sql or type(value) ~= 'string' then return nil end
    local ok, id = pcall(MySQL.scalar.await, sql, { value })
    if not ok then return nil end
    return str(id)
end

return M
