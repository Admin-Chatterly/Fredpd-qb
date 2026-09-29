-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_alerts / fredpd_alert_units access (db/migrations/005_dispatch.sql). All functions await oxmysql, so call
-- them from a thread (event handlers, callbacks, SetTimeout callbacks and export calls all run in one).
--
-- Status transitions are single conditional statements, so two officers (or an officer and Ledning) acting at the
-- same moment can never produce an impossible state; the result is read from affectedRows. Every UPDATE here changes
-- the row it matches (status and/or updated_at), so the count is the same with and without mysql2's
-- CLIENT_FOUND_ROWS (oxmysql), and INSERT IGNORE / DELETE counts are unaffected by it (docs/modules/core.md).
--
-- Times: written with UTC_TIMESTAMP(), read with Time.isoSelect (ISO-8601 UTC strings, never oxmysql's host-local
-- epoch numbers; docs/contracts.md §C7, §C12). The isoSelect fragments contain '%': the SQL below is built by
-- concatenation only, never through string.format.

local Time = require '@fredpd_core.shared.time'

local M = {}

M.PAGE_SIZE = 50 -- PAGE_SIZE in packages/types/src/mdt.ts

M.ALERT_SELECT = 'SELECT a.id, a.code, a.title, a.description, a.coords, a.street, a.priority, a.source, a.status, '
    .. 'a.closed_by, ' .. Time.isoSelect('a.created_at', 'created_at') .. ', '
    .. Time.isoSelect('a.closed_at', 'closed_at') .. ', '
    .. 'co.display_name AS closed_by_name, co.callsign AS closed_by_callsign, co.unit AS closed_by_unit '
    .. 'FROM fredpd_alerts a LEFT JOIN fredpd_officers co ON co.citizenid = a.closed_by WHERE a.id IN '

-- Officers on the alerts, in the order they took it. The callsign column is the snapshot taken with the alert; the
-- officer's current callsign wins when the officer row exists.
M.UNITS_SELECT = 'SELECT u.alert_id, u.citizenid, u.callsign AS snap_callsign, o.display_name, o.callsign, o.unit '
    .. 'FROM fredpd_alert_units u LEFT JOIN fredpd_officers o ON o.citizenid = u.citizenid WHERE u.alert_id IN '

M.INSERT_SQL = 'INSERT INTO fredpd_alerts (code, title, description, coords, street, priority, source, meta, status, '
    .. "created_at, updated_at) VALUES (%s, 'open', UTC_TIMESTAMP(), UTC_TIMESTAMP())"

-- Claim for the keybind: only the first taker flips open -> assigned.
M.CLAIM_SQL = "UPDATE fredpd_alerts SET status = 'assigned', updated_at = UTC_TIMESTAMP() "
    .. "WHERE id = ? AND status = 'open'"

-- Join an alert that is not closed; 0 rows = already on it, or the alert is closed/missing.
M.ADD_UNIT_SQL = 'INSERT IGNORE INTO fredpd_alert_units (alert_id, citizenid, callsign, created_at) '
    .. "SELECT id, ?, %s, UTC_TIMESTAMP() FROM fredpd_alerts WHERE id = ? AND status IN ('open', 'assigned')"

M.MARK_ASSIGNED_SQL = M.CLAIM_SQL

-- Leaving a closed alert would rewrite history: the join keeps closed alerts out.
M.REMOVE_UNIT_SQL = 'DELETE u FROM fredpd_alert_units u JOIN fredpd_alerts a ON a.id = u.alert_id '
    .. "WHERE u.alert_id = ? AND u.citizenid = ? AND a.status <> 'closed'"

-- assigned -> open only when nobody is left (checked in the same statement, so a concurrent take wins).
M.REOPEN_SQL = "UPDATE fredpd_alerts a SET a.status = 'open', a.updated_at = UTC_TIMESTAMP() "
    .. "WHERE a.id = ? AND a.status = 'assigned' "
    .. 'AND NOT EXISTS (SELECT 1 FROM fredpd_alert_units u WHERE u.alert_id = a.id)'

M.CLOSE_SQL = "UPDATE fredpd_alerts SET status = 'closed', closed_by = ?, closed_at = UTC_TIMESTAMP(), "
    .. "updated_at = UTC_TIMESTAMP() WHERE id = ? AND status IN ('open', 'assigned')"

M.NEWEST_OPEN_SQL = "SELECT id FROM fredpd_alerts WHERE status = 'open' ORDER BY id DESC LIMIT 1"

M.STATE_SQL = 'SELECT a.status, (SELECT COUNT(*) FROM fredpd_alert_units u WHERE u.alert_id = a.id '
    .. 'AND u.citizenid = ?) AS mine FROM fredpd_alerts a WHERE a.id = ?'

---------------------------------------------------------------------------------------------------------------
-- Helpers

--- '?, ?, ?' for n values.
local function marks(n)
    return ('?'):rep(n, ', ')
end

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
    return tostring(v)
end

local function num(v)
    return tonumber(v)
end

--- The coords column comes back as JSON text (MariaDB JSON = LONGTEXT) or, from a driver that parses JSON, as a
--- table. Anything that is not three finite numbers is treated as no position.
local function decodeCoords(v)
    if type(v) == 'string' then
        local ok, decoded = pcall(json.decode, v)
        v = ok and decoded or nil
    end
    if type(v) ~= 'table' then return nil end
    local x, y, z = tonumber(v.x), tonumber(v.y), tonumber(v.z)
    if not x or not y or not z or x ~= x or y ~= y or z ~= z then return nil end
    return { x = x, y = y, z = z }
end

--- OfficerRef (mdt.ts): Discord display name + callsign from fredpd_officers (§4.9); an officer without a row is
--- shown by the callsign snapshot or, failing that, the citizenid (never a character name).
local function officerRef(citizenid, displayName, callsign, unit)
    local cid = str(citizenid)
    if not cid then return nil end
    callsign = str(callsign)
    return {
        citizenid = cid,
        displayName = str(displayName) or callsign or cid,
        callsign = callsign,
        unit = str(unit),
    }
end

local function rowToAlert(row)
    return {
        id = math.tointeger(num(row.id)),
        code = str(row.code),
        title = str(row.title),
        description = str(row.description),
        coords = decodeCoords(row.coords),
        street = str(row.street),
        priority = math.tointeger(num(row.priority)) or 2,
        source = str(row.source),
        status = str(row.status),
        createdAt = Time.toIsoUtc(str(row.created_at)),
        units = {},
        closedBy = row.closed_by ~= nil and officerRef(row.closed_by, row.closed_by_name, row.closed_by_callsign,
            row.closed_by_unit) or nil,
        closedAt = Time.toIsoUtc(str(row.closed_at)),
    }
end

---------------------------------------------------------------------------------------------------------------
-- The single loader: Alert objects (dispatch.ts AlertSchema) for a list of ids, in the order given.

--- @param ids integer[]
--- @return table[] alerts (missing ids are skipped)
function M.load(ids)
    if #ids == 0 then return {} end
    local rows = MySQL.query.await(M.ALERT_SELECT .. '(' .. marks(#ids) .. ')', ids) or {}
    local byId = {}
    for _, row in ipairs(rows) do
        local alert = rowToAlert(row)
        if alert.id then byId[alert.id] = alert end
    end
    local units = MySQL.query.await(M.UNITS_SELECT .. '(' .. marks(#ids) .. ') ORDER BY u.created_at, u.citizenid',
        ids) or {}
    for _, u in ipairs(units) do
        local alert = byId[math.tointeger(num(u.alert_id))]
        if alert then
            local ref = officerRef(u.citizenid, u.display_name, u.callsign or u.snap_callsign, u.unit)
            if ref then alert.units[#alert.units + 1] = ref end
        end
    end
    local out = {}
    for _, id in ipairs(ids) do
        if byId[id] then out[#out + 1] = byId[id] end
    end
    return out
end

--- @return table|nil
function M.loadOne(id)
    return M.load({ id })[1]
end

---------------------------------------------------------------------------------------------------------------
-- Writes

--- Insert a validated AlertCreateInput (shared/alert_input.lua validateCreate). Returns the new id.
--- @param input table
--- @return integer|nil
function M.insert(input)
    local coords = input.coords and json.encode({ x = input.coords.x, y = input.coords.y, z = input.coords.z }) or nil
    local meta = input.meta and json.encode(input.meta) or nil
    local placeholders, params = bindRow({
        input.code, input.title, input.description, coords, input.street, input.priority, input.source, meta,
    }, 8)
    local id = MySQL.insert.await(M.INSERT_SQL:format(placeholders), params)
    return math.tointeger(num(id))
end

--- open -> assigned for the first taker only. @return boolean claimed
function M.claim(id)
    return (num(MySQL.update.await(M.CLAIM_SQL, { id })) or 0) > 0
end

--- Add an officer to a non-closed alert. @return integer rows inserted (0 = already on it, or closed/missing)
function M.addUnit(id, citizenid, callsign)
    local params = { citizenid }
    local callsignMark = bindRow({ callsign }, 1, params)
    params[#params + 1] = id
    return num(MySQL.update.await(M.ADD_UNIT_SQL:format(callsignMark), params)) or 0
end

--- open -> assigned after a join (no-op when already assigned). @return boolean changed
function M.markAssigned(id)
    return (num(MySQL.update.await(M.MARK_ASSIGNED_SQL, { id })) or 0) > 0
end

--- Remove an officer from a non-closed alert. @return integer rows deleted
function M.removeUnit(id, citizenid)
    return num(MySQL.update.await(M.REMOVE_UNIT_SQL, { id, citizenid })) or 0
end

--- assigned -> open when no unit is left. @return boolean reopened
function M.reopenIfEmpty(id)
    return (num(MySQL.update.await(M.REOPEN_SQL, { id })) or 0) > 0
end

--- open/assigned -> closed. @return boolean closed
function M.close(id, citizenid)
    return (num(MySQL.update.await(M.CLOSE_SQL, { citizenid, id })) or 0) > 0
end

---------------------------------------------------------------------------------------------------------------
-- Reads

--- Newest open alert id, or nil.
function M.newestOpenId()
    return math.tointeger(num(MySQL.scalar.await(M.NEWEST_OPEN_SQL)))
end

--- Status of an alert and whether `citizenid` is one of its units. @return string|nil status, boolean mine
function M.state(id, citizenid)
    local row = MySQL.single.await(M.STATE_SQL, { citizenid or '', id })
    if not row then return nil, false end
    return str(row.status), (num(row.mine) or 0) > 0
end

--- One page of alerts, newest first. filter: 'open' (open + assigned), 'mine' (not closed, `citizenid` on it),
--- 'all'. @return { items = Alert[], total = n, page = page }
function M.list(filter, citizenid, page)
    local from, params
    if filter == 'mine' then
        from = 'FROM fredpd_alerts a JOIN fredpd_alert_units u ON u.alert_id = a.id AND u.citizenid = ? '
            .. "WHERE a.status <> 'closed'"
        params = { citizenid }
    elseif filter == 'all' then
        from, params = 'FROM fredpd_alerts a', {}
    else
        from, params = "FROM fredpd_alerts a WHERE a.status IN ('open', 'assigned')", {}
    end
    local total = math.tointeger(num(MySQL.scalar.await('SELECT COUNT(*) ' .. from, params))) or 0
    -- page is a validated integer (1..10000); LIMIT/OFFSET are written as literals.
    local offset = (page - 1) * M.PAGE_SIZE
    local rows = MySQL.query.await(('SELECT a.id %s ORDER BY a.id DESC LIMIT %d OFFSET %d')
        :format(from, M.PAGE_SIZE, offset), params) or {}
    local ids = {}
    for _, row in ipairs(rows) do ids[#ids + 1] = math.tointeger(num(row.id)) end
    return { items = M.load(ids), total = total, page = page }
end

--- Newest non-closed alert per officer. @param citizenids string[] @return table<string, integer>
function M.assignments(citizenids)
    local out = {}
    if #citizenids == 0 then return out end
    local rows = MySQL.query.await('SELECT u.citizenid, MAX(u.alert_id) AS alert_id FROM fredpd_alert_units u '
        .. "JOIN fredpd_alerts a ON a.id = u.alert_id WHERE a.status <> 'closed' AND u.citizenid IN ("
        .. marks(#citizenids) .. ') GROUP BY u.citizenid', citizenids) or {}
    for _, row in ipairs(rows) do
        local cid = str(row.citizenid)
        if cid then out[cid] = math.tointeger(num(row.alert_id)) end
    end
    return out
end

return M
