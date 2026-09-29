-- SPDX-License-Identifier: GPL-3.0-only
-- SQL for fredpd_intel (db/migrations/007_intel.sql) plus the read-only lookups it needs: officer names
-- (fredpd_officers), person names and vehicles (fredpd_persons / fredpd_vehicles_idx mirrors, never
-- players.charinfo) and case numbers (fredpd_cases). Every function awaits oxmysql: call it from a thread (exports,
-- callbacks and event handlers run in one).
--
-- Times: writes use UTC_TIMESTAMP(); DATETIME columns are read through Time.isoSelect (docs/contracts.md §C7, §C12).
-- Nothing here decides visibility: rows go to server/access.lua, which asks fredpd_core's canViewMany.
-- Row tables use camelCase keys; SQL NULL becomes nil.

local Time = require '@fredpd_core.shared.time'

local M = {}

M.SCAN_CAP = 500        -- newest rows a list considers before canView filtering (docs/modules/intel.md "Lists")
M.SEARCH_LIMIT = 25     -- searchEntities
M.NOTICE_CAP = 200      -- missions / standalone reports considered for the kontaktnotis of one entity

local function marks(n) return ('?'):rep(n, ', ') end
M.marks = marks

local function str(v)
    if v == nil or type(v) == 'userdata' or type(v) == 'table' then return nil end
    return tostring(v)
end

local function int(v)
    return math.tointeger(tonumber(v))
end

--- nil-safe '?' binding: a Lua array with nil holes does not reach oxmysql as an array, so NULL is inlined.
local function val(v, params)
    if v == nil then return 'NULL' end
    params[#params + 1] = v
    return '?'
end

local function uniqueInts(list)
    local out, seen = {}, {}
    for _, v in ipairs(list or {}) do
        local i = int(v)
        if i and not seen[i] then
            seen[i] = true
            out[#out + 1] = i
        end
    end
    return out
end
M.uniqueInts = uniqueInts

local function uniqueStrings(list)
    local out, seen = {}, {}
    for _, v in ipairs(list or {}) do
        if type(v) == 'string' and v ~= '' and not seen[v] then
            seen[v] = true
            out[#out + 1] = v
        end
    end
    return out
end
M.uniqueStrings = uniqueStrings

local function query(sql, params)
    return MySQL.query.await(sql, params) or {}
end

---------------------------------------------------------------------------------------------------------------
-- Sources

M.SOURCE_COLS = 's.id, s.codename, s.handler_citizenid, s.reliability, s.status, s.notes, s.real_citizenid, '
    .. 's.level, s.unit, ' .. Time.isoSelect('s.created_at', 'created_at')

function M.rowToSource(r)
    if type(r) ~= 'table' or r.id == nil then return nil end
    return {
        id = int(r.id),
        codename = str(r.codename),
        handler = str(r.handler_citizenid),
        reliability = str(r.reliability),
        status = str(r.status),
        notes = str(r.notes),
        realCitizenid = str(r.real_citizenid),
        level = int(r.level) or 2,
        unit = str(r.unit),
        createdAt = Time.toIsoUtc(str(r.created_at)),
    }
end

function M.sourceById(id)
    return M.rowToSource(MySQL.single.await('SELECT ' .. M.SOURCE_COLS .. ' FROM fredpd_intel_sources s WHERE s.id = ?',
        { id }))
end

--- { [id] = source } for a list of ids.
function M.sourcesByIds(ids)
    ids = uniqueInts(ids)
    local out = {}
    if #ids == 0 then return out end
    for _, r in ipairs(query('SELECT ' .. M.SOURCE_COLS .. ' FROM fredpd_intel_sources s WHERE s.id IN ('
        .. marks(#ids) .. ')', ids)) do
        local s = M.rowToSource(r)
        out[s.id] = s
    end
    return out
end

--- Newest sources first (at most `cap`).
function M.sourcesNewest(cap)
    local out = {}
    for i, r in ipairs(query('SELECT ' .. M.SOURCE_COLS .. ' FROM fredpd_intel_sources s ORDER BY s.id DESC LIMIT '
        .. math.tointeger(cap or M.SCAN_CAP))) do
        out[i] = M.rowToSource(r)
    end
    return out
end

--- Insert a source. r = { codename, handler, reliability, notes?, realCitizenid?, level, unit? }.
--- Returns the new id, or nil when the codename is taken (INSERT IGNORE on uq_codename; affectedRows decides, not
--- insertId, so mysql2's CLIENT_FOUND_ROWS and pooled LAST_INSERT_ID values cannot mislead it).
function M.insertSource(r)
    local params = { r.codename, r.handler, r.reliability }
    local sql = 'INSERT IGNORE INTO fredpd_intel_sources (codename, handler_citizenid, reliability, status, notes, '
        .. 'real_citizenid, level, unit, updated_at, created_at) VALUES (?, ?, ?, \'open\', '
        .. val(r.notes, params) .. ', ' .. val(r.realCitizenid, params) .. ', ' .. val(r.level, params) .. ', '
        .. val(r.unit, params) .. ', UTC_TIMESTAMP(), UTC_TIMESTAMP())'
    local affected = MySQL.update.await(sql, params)
    if (tonumber(affected) or 0) < 1 then return nil end
    return int(MySQL.scalar.await('SELECT id FROM fredpd_intel_sources WHERE codename = ?', { r.codename }))
end

--- Update the given fields (reliability, status, notes, clearNotes). Returns the list of changed field names
--- (compared in SQL with <=>, so an unchanged value is not reported).
function M.updateSource(id, f)
    local current = M.sourceById(id)
    if not current then return nil end
    local sets, params, changed = {}, {}, {}
    if f.reliability and f.reliability ~= current.reliability then
        sets[#sets + 1] = 'reliability = ?'
        params[#params + 1] = f.reliability
        changed[#changed + 1] = 'reliability'
    end
    if f.status and f.status ~= current.status then
        sets[#sets + 1] = 'status = ?'
        params[#params + 1] = f.status
        changed[#changed + 1] = 'status'
    end
    if f.clearNotes and current.notes ~= nil then
        sets[#sets + 1] = 'notes = NULL'
        changed[#changed + 1] = 'notes'
    elseif f.notes and f.notes ~= current.notes then
        sets[#sets + 1] = 'notes = ?'
        params[#params + 1] = f.notes
        changed[#changed + 1] = 'notes'
    end
    if #sets == 0 then return changed end
    params[#params + 1] = id
    MySQL.update.await('UPDATE fredpd_intel_sources SET ' .. table.concat(sets, ', ')
        .. ', updated_at = UTC_TIMESTAMP() WHERE id = ?', params)
    return changed
end

---------------------------------------------------------------------------------------------------------------
-- Missions and members

M.MISSION_COLS = 'm.id, m.title, m.description, m.unit, m.status, m.level, m.lead_citizenid, '
    .. Time.isoSelect('m.created_at', 'created_at')

function M.rowToMission(r)
    if type(r) ~= 'table' or r.id == nil then return nil end
    return {
        id = int(r.id),
        title = str(r.title),
        description = str(r.description),
        unit = str(r.unit),
        status = str(r.status),
        level = int(r.level) or 2,
        lead = str(r.lead_citizenid),
        createdAt = Time.toIsoUtc(str(r.created_at)),
    }
end

function M.missionById(id)
    return M.rowToMission(MySQL.single.await('SELECT ' .. M.MISSION_COLS .. ' FROM fredpd_missions m WHERE m.id = ?',
        { id }))
end

function M.missionsByIds(ids)
    ids = uniqueInts(ids)
    local out = {}
    if #ids == 0 then return out end
    for _, r in ipairs(query('SELECT ' .. M.MISSION_COLS .. ' FROM fredpd_missions m WHERE m.id IN (' .. marks(#ids)
        .. ')', ids)) do
        local m = M.rowToMission(r)
        out[m.id] = m
    end
    return out
end

function M.missionsNewest(cap)
    local out = {}
    for i, r in ipairs(query('SELECT ' .. M.MISSION_COLS .. ' FROM fredpd_missions m ORDER BY m.id DESC LIMIT '
        .. math.tointeger(cap or M.SCAN_CAP))) do
        out[i] = M.rowToMission(r)
    end
    return out
end

--- r = { title, description?, unit?, level, lead } -> id.
function M.insertMission(r)
    local params = { r.title }
    local sql = 'INSERT INTO fredpd_missions (title, description, unit, status, level, lead_citizenid, updated_at, '
        .. 'created_at) VALUES (?, ' .. val(r.description, params) .. ', ' .. val(r.unit, params) .. ", 'open', "
        .. val(r.level, params) .. ', ' .. val(r.lead, params) .. ', UTC_TIMESTAMP(), UTC_TIMESTAMP())'
    return int(MySQL.insert.await(sql, params))
end

--- open -> closed; true when this call closed it (the WHERE makes a second close a no-op with 0 rows).
function M.closeMission(id)
    local affected = MySQL.update.await("UPDATE fredpd_missions SET status = 'closed', updated_at = UTC_TIMESTAMP() "
        .. "WHERE id = ? AND status = 'open'", { id })
    return (tonumber(affected) or 0) > 0
end

--- { [missionId] = { { citizenid, role }, ... } } (every mission id gets a list, possibly empty).
function M.members(missionIds)
    missionIds = uniqueInts(missionIds)
    local out = {}
    for _, id in ipairs(missionIds) do out[id] = {} end
    if #missionIds == 0 then return out end
    for _, r in ipairs(query('SELECT mission_id, citizenid, role FROM fredpd_mission_members WHERE mission_id IN ('
        .. marks(#missionIds) .. ') ORDER BY mission_id, created_at, citizenid', missionIds)) do
        local list = out[int(r.mission_id)]
        if list then list[#list + 1] = { citizenid = str(r.citizenid), role = str(r.role) } end
    end
    return out
end

--- Add a member (or change the role of an existing one). Returns 'added', 'role' (role changed) or 'same'.
function M.addMember(missionId, citizenid, role, addedBy)
    local params = { missionId, citizenid }
    local added = MySQL.update.await('INSERT IGNORE INTO fredpd_mission_members (mission_id, citizenid, role, added_by, '
        .. 'created_at) VALUES (?, ?, ' .. val(role, params) .. ', ' .. val(addedBy, params) .. ', UTC_TIMESTAMP())',
        params)
    if (tonumber(added) or 0) > 0 then return 'added' end
    if role == nil then return 'same' end
    -- `NOT (role <=> ?)` matches only a real change, so affectedRows means "changed" with or without FOUND_ROWS.
    local changed = MySQL.update.await('UPDATE fredpd_mission_members SET role = ? WHERE mission_id = ? AND '
        .. 'citizenid = ? AND NOT (role <=> ?)', { role, missionId, citizenid, role })
    return (tonumber(changed) or 0) > 0 and 'role' or 'same'
end

---------------------------------------------------------------------------------------------------------------
-- Intel reports

M.REPORT_META_COLS = 'r.id, r.source_id, r.mission_id, r.author, r.reliability, r.level, r.status, '
    .. Time.isoSelect('r.created_at', 'created_at')
M.REPORT_COLS = M.REPORT_META_COLS .. ', r.body'

function M.rowToReport(r)
    if type(r) ~= 'table' or r.id == nil then return nil end
    return {
        id = int(r.id),
        sourceId = int(r.source_id),
        missionId = int(r.mission_id),
        author = str(r.author),
        body = str(r.body),
        reliability = str(r.reliability),
        level = int(r.level) or 2,
        status = str(r.status) or 'open',
        createdAt = Time.toIsoUtc(str(r.created_at)),
    }
end

function M.reportById(id)
    return M.rowToReport(MySQL.single.await('SELECT ' .. M.REPORT_COLS .. ' FROM fredpd_intel_reports r WHERE r.id = ?',
        { id }))
end

--- { [id] = report } with bodies.
function M.reportsByIds(ids)
    ids = uniqueInts(ids)
    local out = {}
    if #ids == 0 then return out end
    for _, r in ipairs(query('SELECT ' .. M.REPORT_COLS .. ' FROM fredpd_intel_reports r WHERE r.id IN ('
        .. marks(#ids) .. ')', ids)) do
        local rep = M.rowToReport(r)
        out[rep.id] = rep
    end
    return out
end

--- Newest reports first, without bodies; filter = { sourceId?, missionId? }.
function M.reportsNewest(filter, cap)
    local where, params = {}, {}
    if filter and filter.sourceId then
        where[#where + 1] = 'r.source_id = ?'
        params[#params + 1] = filter.sourceId
    end
    if filter and filter.missionId then
        where[#where + 1] = 'r.mission_id = ?'
        params[#params + 1] = filter.missionId
    end
    local sql = 'SELECT ' .. M.REPORT_META_COLS .. ' FROM fredpd_intel_reports r'
        .. (#where > 0 and (' WHERE ' .. table.concat(where, ' AND ')) or '')
        .. ' ORDER BY r.id DESC LIMIT ' .. math.tointeger(cap or M.SCAN_CAP)
    local out = {}
    for i, r in ipairs(query(sql, params)) do out[i] = M.rowToReport(r) end
    return out
end

--- Reports (without bodies) of the given missions, newest first.
function M.reportsOfMissions(missionIds)
    missionIds = uniqueInts(missionIds)
    local out = {}
    if #missionIds == 0 then return out end
    for i, r in ipairs(query('SELECT ' .. M.REPORT_META_COLS .. ' FROM fredpd_intel_reports r WHERE r.mission_id IN ('
        .. marks(#missionIds) .. ') ORDER BY r.id DESC LIMIT 1000', missionIds)) do
        out[i] = M.rowToReport(r)
    end
    return out
end

--- r = { sourceId?, missionId?, author, body, reliability?, level } -> id.
function M.insertReport(r)
    local params = {}
    local sql = 'INSERT INTO fredpd_intel_reports (source_id, mission_id, author, body, reliability, level, status, '
        .. 'updated_at, created_at) VALUES (' .. val(r.sourceId, params) .. ', ' .. val(r.missionId, params) .. ', '
        .. val(r.author, params) .. ', ' .. val(r.body, params) .. ', ' .. val(r.reliability, params) .. ', '
        .. val(r.level, params) .. ", 'open', UTC_TIMESTAMP(), UTC_TIMESTAMP())"
    return int(MySQL.insert.await(sql, params))
end

---------------------------------------------------------------------------------------------------------------
-- Entities

M.ENTITY_COLS = 'e.id, e.type, e.ref, e.label'

function M.rowToEntity(r)
    if type(r) ~= 'table' or r.id == nil then return nil end
    return { id = int(r.id), type = str(r.type), ref = str(r.ref), label = str(r.label) or '' }
end

function M.entityById(id)
    return M.rowToEntity(MySQL.single.await('SELECT ' .. M.ENTITY_COLS .. ' FROM fredpd_intel_entities e WHERE e.id = ?',
        { id }))
end

--- { [id] = entity } — one query for a whole BFS frontier.
function M.entitiesByIds(ids)
    ids = uniqueInts(ids)
    local out = {}
    if #ids == 0 then return out end
    for _, r in ipairs(query('SELECT ' .. M.ENTITY_COLS .. ' FROM fredpd_intel_entities e WHERE e.id IN ('
        .. marks(#ids) .. ')', ids)) do
        local e = M.rowToEntity(r)
        out[e.id] = e
    end
    return out
end

--- The entity for (type, ref); ref nil = a keyless location/group identified by its label.
function M.findEntity(entityType, ref, label)
    if ref ~= nil then
        return M.rowToEntity(MySQL.single.await('SELECT ' .. M.ENTITY_COLS .. ' FROM fredpd_intel_entities e '
            .. 'WHERE e.type = ? AND e.ref = ?', { entityType, ref }))
    end
    return M.rowToEntity(MySQL.single.await('SELECT ' .. M.ENTITY_COLS .. ' FROM fredpd_intel_entities e '
        .. 'WHERE e.type = ? AND e.ref IS NULL AND e.label = ? ORDER BY e.id LIMIT 1', { entityType, label }))
end

--- Create or find the entity. Keyed rows (ref set) dedup on uq_type_ref with INSERT IGNORE (affectedRows 1 =
--- created); keyless rows are looked up by label first (a concurrent twin is possible and harmless).
--- Returns entity, created (boolean).
function M.ensureEntity(entityType, ref, label, createdBy)
    if ref == nil then
        local existing = M.findEntity(entityType, nil, label)
        if existing then return existing, false end
        local id = int(MySQL.insert.await('INSERT INTO fredpd_intel_entities (type, ref, label, created_by, updated_at, '
            .. 'created_at) VALUES (?, NULL, ?, ?, UTC_TIMESTAMP(), UTC_TIMESTAMP())', { entityType, label, createdBy }))
        return M.entityById(id), true
    end
    local affected = MySQL.update.await('INSERT IGNORE INTO fredpd_intel_entities (type, ref, label, created_by, '
        .. 'updated_at, created_at) VALUES (?, ?, ?, ?, UTC_TIMESTAMP(), UTC_TIMESTAMP())',
        { entityType, ref, label, createdBy })
    return M.findEntity(entityType, ref), (tonumber(affected) or 0) > 0
end

--- Keep a keyed entity's derived label current (person renamed, vehicle model known). True when it changed.
function M.relabel(id, label)
    local affected = MySQL.update.await('UPDATE fredpd_intel_entities SET label = ?, updated_at = UTC_TIMESTAMP() '
        .. 'WHERE id = ? AND label <> ?', { label, id, label })
    return (tonumber(affected) or 0) > 0
end

--- Prefix search on label (idx_label): `likePattern` is already escaped for ESCAPE '!' (shared/input.lua).
function M.searchEntities(likePattern, entityType, limit)
    local params = { likePattern }
    local sql = 'SELECT ' .. M.ENTITY_COLS .. " FROM fredpd_intel_entities e WHERE e.label LIKE ? ESCAPE '!'"
    if entityType then
        sql = sql .. ' AND e.type = ?'
        params[#params + 1] = entityType
    end
    sql = sql .. ' ORDER BY e.label, e.id LIMIT ' .. math.tointeger(limit or M.SEARCH_LIMIT)
    local out = {}
    for i, r in ipairs(query(sql, params)) do out[i] = M.rowToEntity(r) end
    return out
end

---------------------------------------------------------------------------------------------------------------
-- Links (with the report and mission columns canView needs, joined in the same query)

M.LINK_COLS = 'l.id, l.from_id, l.to_id, l.type, l.confidence, l.report_id, l.created_by, l.level, '
    .. Time.isoSelect('l.created_at', 'created_at') .. ', '
    .. 'r.author AS r_author, r.level AS r_level, r.status AS r_status, r.mission_id AS r_mission, '
    .. 'r.source_id AS r_source, ' .. Time.isoSelect('r.created_at', 'r_created_at') .. ', '
    .. 'm.title AS m_title, m.level AS m_level, m.status AS m_status, m.unit AS m_unit, m.lead_citizenid AS m_lead'
M.LINK_FROM = ' FROM fredpd_intel_links l LEFT JOIN fredpd_intel_reports r ON r.id = l.report_id '
    .. 'LEFT JOIN fredpd_missions m ON m.id = r.mission_id '

--- Link row -> { id, fromId, toId, type, confidence, level, createdBy, createdAt, report = {…}|nil,
--- mission = {…}|nil }. The report/mission parts carry only what visibility and the wire need (no body).
function M.rowToLink(r)
    if type(r) ~= 'table' or r.id == nil then return nil end
    local link = {
        id = int(r.id),
        fromId = int(r.from_id),
        toId = int(r.to_id),
        type = str(r.type),
        confidence = int(r.confidence) or 0,
        reportId = int(r.report_id),
        createdBy = str(r.created_by),
        level = int(r.level) or 2,
        createdAt = Time.toIsoUtc(str(r.created_at)),
    }
    if link.reportId and r.r_author ~= nil then
        link.report = {
            id = link.reportId,
            author = str(r.r_author),
            level = int(r.r_level) or 2,
            status = str(r.r_status) or 'open',
            missionId = int(r.r_mission),
            sourceId = int(r.r_source),
            createdAt = Time.toIsoUtc(str(r.r_created_at)),
        }
        if link.report.missionId and r.m_status ~= nil then
            link.mission = {
                id = link.report.missionId,
                title = str(r.m_title),
                level = int(r.m_level) or 2,
                status = str(r.m_status),
                unit = str(r.m_unit),
                lead = str(r.m_lead),
            }
        end
    end
    return link
end

--- Links touching any of `ids` (either end), newest first, at most `cap`. One UNION query (idx_from_to for the
--- from side, idx_to for the to side; UNION drops the duplicate of a link with both ends in the set).
--- Returns links, capped (true when more than `cap` exist).
function M.linksTouching(ids, cap)
    ids = uniqueInts(ids)
    cap = math.tointeger(cap or M.SCAN_CAP)
    if #ids == 0 then return {}, false end
    local m = marks(#ids)
    local params = {}
    for _, id in ipairs(ids) do params[#params + 1] = id end
    for _, id in ipairs(ids) do params[#params + 1] = id end
    local sql = 'SELECT * FROM (SELECT ' .. M.LINK_COLS .. M.LINK_FROM .. 'WHERE l.from_id IN (' .. m .. ') UNION '
        .. 'SELECT ' .. M.LINK_COLS .. M.LINK_FROM .. 'WHERE l.to_id IN (' .. m .. ')) x ORDER BY x.id DESC LIMIT '
        .. (cap + 1)
    local out = {}
    for _, r in ipairs(query(sql, params)) do out[#out + 1] = M.rowToLink(r) end
    local capped = #out > cap
    if capped then out[#out] = nil end
    return out, capped
end

function M.countLinksTouching(id)
    return int(MySQL.scalar.await('SELECT COUNT(*) FROM fredpd_intel_links WHERE from_id = ? OR to_id = ?',
        { id, id })) or 0
end

--- Links of the given reports (report pages), newest first.
function M.linksOfReports(reportIds)
    reportIds = uniqueInts(reportIds)
    if #reportIds == 0 then return {} end
    local out = {}
    for _, r in ipairs(query('SELECT ' .. M.LINK_COLS .. M.LINK_FROM .. 'WHERE l.report_id IN (' .. marks(#reportIds)
        .. ') ORDER BY l.id DESC LIMIT 1000', reportIds)) do
        out[#out + 1] = M.rowToLink(r)
    end
    return out
end

function M.linkById(id)
    return M.rowToLink(MySQL.single.await('SELECT ' .. M.LINK_COLS .. M.LINK_FROM .. 'WHERE l.id = ?', { id }))
end

--- An identical link (same ends, type and report) already stored, or nil.
function M.findSameLink(fromId, toId, linkType, reportId)
    local params = { fromId, toId, linkType }
    local sql = 'SELECT id FROM fredpd_intel_links WHERE from_id = ? AND to_id = ? AND type = ? AND report_id '
    if reportId then
        sql = sql .. '= ?'
        params[#params + 1] = reportId
    else
        sql = sql .. 'IS NULL'
    end
    return int(MySQL.scalar.await(sql .. ' ORDER BY id LIMIT 1', params))
end

--- r = { fromId, toId, type, confidence, reportId?, createdBy, level } -> id.
function M.insertLink(r)
    local params = { r.fromId, r.toId, r.type, r.confidence }
    local sql = 'INSERT INTO fredpd_intel_links (from_id, to_id, type, confidence, report_id, created_by, level, '
        .. 'created_at) VALUES (?, ?, ?, ?, ' .. val(r.reportId, params) .. ', ' .. val(r.createdBy, params) .. ', '
        .. val(r.level, params) .. ', UTC_TIMESTAMP())'
    return int(MySQL.insert.await(sql, params))
end

--- Missions reached through links touching the entity (report -> mission), newest first. Complete (not limited
--- to the links a list shows), so every mission behind a hidden link can still give its kontaktnotis.
function M.missionsTouching(entityId, cap)
    local out = {}
    for i, r in ipairs(query('SELECT ' .. M.MISSION_COLS .. ' FROM fredpd_missions m WHERE m.id IN (SELECT r.mission_id '
        .. 'FROM fredpd_intel_links l JOIN fredpd_intel_reports r ON r.id = l.report_id WHERE (l.from_id = ? OR '
        .. 'l.to_id = ?) AND r.mission_id IS NOT NULL) ORDER BY m.id DESC LIMIT ' .. math.tointeger(cap or M.NOTICE_CAP),
        { entityId, entityId })) do
        out[i] = M.rowToMission(r)
    end
    return out
end

--- Reports outside missions reached through links touching the entity (no bodies), newest first.
function M.standaloneReportsTouching(entityId, cap)
    local out = {}
    for i, r in ipairs(query('SELECT ' .. M.REPORT_META_COLS .. ' FROM fredpd_intel_reports r WHERE r.mission_id IS NULL '
        .. 'AND r.id IN (SELECT l.report_id FROM fredpd_intel_links l WHERE (l.from_id = ? OR l.to_id = ?) AND '
        .. 'l.report_id IS NOT NULL) ORDER BY r.id DESC LIMIT ' .. math.tointeger(cap or M.NOTICE_CAP),
        { entityId, entityId })) do
        out[i] = M.rowToReport(r)
    end
    return out
end

---------------------------------------------------------------------------------------------------------------
-- Names and referenced records (read-only)

--- { [citizenid] = { displayName, callsign, unit } } from fredpd_officers (Discord names, §4.9).
function M.officers(citizenids)
    local ids = uniqueStrings(citizenids)
    local out = {}
    if #ids == 0 then return out end
    for _, r in ipairs(query('SELECT citizenid, display_name, callsign, unit FROM fredpd_officers WHERE citizenid IN ('
        .. marks(#ids) .. ')', ids)) do
        out[str(r.citizenid)] = { displayName = str(r.display_name), callsign = str(r.callsign), unit = str(r.unit) }
    end
    return out
end

function M.officerExists(citizenid)
    return MySQL.scalar.await('SELECT 1 FROM fredpd_officers WHERE citizenid = ?', { citizenid }) ~= nil
end

--- { [citizenid] = 'Förnamn Efternamn' } from the fredpd_persons mirror (never players.charinfo).
function M.personNames(citizenids)
    local ids = uniqueStrings(citizenids)
    local out = {}
    if #ids == 0 then return out end
    for _, r in ipairs(query('SELECT citizenid, firstname, lastname FROM fredpd_persons WHERE citizenid IN ('
        .. marks(#ids) .. ')', ids)) do
        local name = ((str(r.firstname) or '') .. ' ' .. (str(r.lastname) or '')):gsub('^%s+', ''):gsub('%s+$', '')
        out[str(r.citizenid)] = name
    end
    return out
end

--- fredpd_vehicles_idx row for a normalised plate: { plate, model } or nil.
function M.vehicle(plate)
    local r = MySQL.single.await('SELECT plate, model FROM fredpd_vehicles_idx WHERE plate = ?', { plate })
    if type(r) ~= 'table' or r.plate == nil then return nil end
    return { plate = str(r.plate), model = str(r.model) }
end

local CASE_COLS = 'SELECT id, case_number, status, level, unit, owner_citizenid FROM fredpd_cases '

local function rowToCase(r)
    if type(r) ~= 'table' or r.id == nil then return nil end
    return {
        id = int(r.id),
        caseNumber = str(r.case_number),
        status = str(r.status),
        level = int(r.level) or 2,
        unit = str(r.unit),
        owner = str(r.owner_citizenid),
        assignees = {},
    }
end

--- { [caseNumber] = case } for the given case numbers (the VisRecord fields canView needs, plus assignees): one
--- query for the cases, one for their assignees. Unknown numbers are absent.
function M.casesByNumbers(numbers)
    numbers = uniqueStrings(numbers)
    local out = {}
    if #numbers == 0 then return out end
    local byId, ids = {}, {}
    for _, r in ipairs(query(CASE_COLS .. 'WHERE case_number IN (' .. marks(#numbers) .. ')', numbers)) do
        local c = rowToCase(r)
        if c and c.caseNumber then
            out[c.caseNumber] = c
            byId[c.id] = c
            ids[#ids + 1] = c.id
        end
    end
    if #ids == 0 then return out end
    for _, a in ipairs(query('SELECT case_id, citizenid FROM fredpd_case_assignees WHERE case_id IN (' .. marks(#ids)
        .. ')', ids)) do
        local c = byId[int(a.case_id)]
        if c then c.assignees[#c.assignees + 1] = str(a.citizenid) end
    end
    return out
end

--- fredpd_cases row by case number, or nil.
function M.caseByNumber(caseNumber)
    return M.casesByNumbers({ caseNumber })[caseNumber]
end

return M
