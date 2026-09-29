-- SPDX-License-Identifier: GPL-3.0-only
-- Cases (task 5.1; docs/contracts.md §C14, CaseDetailSchema / RECORDS_ACTIONS in packages/types/src/records.ts).
-- Exports: listCases, getCase, createCase, updateCase, assignCase, unassignCase, addCaseSubject, closeCase.
--
-- Access (fine rules on top of the dispatcher's grant, §C14):
--   read        canView (§C3): none -> not_found (existence never leaks), notice -> the kontaktnotis only;
--   editor      case owner, lead assignee or perm records.admin: update, assign, unassign, close;
--   contributor editor or any assignee: add subjects (reports: see server/reports.lua).
-- Level rules: never above the actor's tier; lowering needs records.admin; closing keeps the level.
-- Numbering: case_number = formatId(formats.caseNumber, { seq, date }) with seq from fredpd_sequences ('case', year in
-- Europe/Stockholm) allocated by one atomic statement (INSERT … ON DUPLICATE KEY UPDATE value = LAST_INSERT_ID(value + 1),
-- as fredpd_core/server/db.lua NEXT_SEQ_SQL). oxmysql's transaction.await is a fixed batch (docs/deps-verification.md
-- §10), so the number is allocated first and the insert follows; a failed insert leaves a gap, never a duplicate
-- (uq_case_number would reject one and the insert retries with the next number).
-- Every write is audited through exports.fredpd_core:audit (meta.label = the short, safe TimelineEntry.detail), pushed
-- (topic 'case', ids only) to the open tablets of the case's owner/assignees and announced with
-- TriggerEvent('fredpd:caseUpdated', id).

local C = require 'server.common'
local Refs = require 'server.caserefs'
local Search = require 'server.search'
local Time = require '@fredpd_core.shared.time'
local Format = require '@fredpd_core.shared.format'

local M = {}

M.PAGE_SIZE = 50
M.LIST_SCAN = 500      -- candidate rows read for one list request (visibility is applied in Lua)
M.TIMELINE_MAX = 100
M.NUMBER_ATTEMPTS = 3

M.NEXT_SEQ_SQL = 'INSERT INTO fredpd_sequences (seq_type, year, value) VALUES (?, ?, LAST_INSERT_ID(1)) '
    .. 'ON DUPLICATE KEY UPDATE value = LAST_INSERT_ID(value + 1), updated_at = UTC_TIMESTAMP()'

M.CASE_SQL = 'SELECT c.id, c.case_number, c.title, c.summary, c.status, c.level, c.unit, c.owner_citizenid, '
    .. Time.isoSelect('c.created_at', 'createdAt') .. ', ' .. Time.isoSelect('c.closed_at', 'closedAt')
    .. ' FROM fredpd_cases c WHERE c.id = ?'

M.ASSIGNEES_SQL = "SELECT citizenid, role FROM fredpd_case_assignees WHERE case_id = ? "
    .. "ORDER BY (role = 'lead') DESC, created_at, citizenid"

M.SUBJECTS_SQL = 'SELECT s.subject_type, s.subject_id, s.role, p.firstname, p.lastname, v.model '
    .. 'FROM fredpd_case_subjects s '
    .. "LEFT JOIN fredpd_persons p ON s.subject_type = 'person' AND p.citizenid = s.subject_id "
    .. "LEFT JOIN fredpd_vehicles_idx v ON s.subject_type = 'vehicle' AND v.plate = s.subject_id "
    .. 'WHERE s.case_id = ? ORDER BY s.created_at, s.subject_type, s.subject_id'

M.REPORT_REFS_SQL = 'SELECT id, report_number, title, level, author_citizenid, '
    .. Time.isoSelect('created_at', 'createdAt') .. ' FROM fredpd_reports WHERE case_id = ? ORDER BY n'

-- Audit rows that are views, not changes, never reach the timeline.
local TIMELINE_EXCLUDE = " AND a.action NOT LIKE 'lookup.%' AND a.action NOT IN ('search', 'share.view', 'report.read')"

local SUBJECT_ROLES = { 'suspect', 'victim', 'witness', 'other' }

---------------------------------------------------------------------------------------------------------------
-- Loading

local function must(v, what)
    if v == nil then error(what .. ' query failed', 0) end
    return v
end

--- Case with assignees (list + { [cid] = role }), or nil.
function M.load(id)
    local row = MySQL.single.await(M.CASE_SQL, { id })
    if not row then return nil end
    local c = Refs.rowToCase(row)
    if not c then return nil end
    c.summary = C.str(row.summary)
    c.createdAt = Time.toIsoUtc(C.str(row.createdAt))
    c.closedAt = row.closedAt and Time.toIsoUtc(C.str(row.closedAt)) or nil
    local rows = must(MySQL.query.await(M.ASSIGNEES_SQL, { id }), 'fredpd_case_assignees')
    c.assignees, c.roles, c.assigneeRows = {}, {}, {}
    for _, r in ipairs(rows) do
        local cid = C.str(r.citizenid)
        if cid then
            c.assignees[#c.assignees + 1] = cid
            c.roles[cid] = r.role == 'lead' and 'lead' or 'member'
            c.assigneeRows[#c.assigneeRows + 1] = { citizenid = cid, role = c.roles[cid] }
        end
    end
    return c
end

--- canView of one case for src ('none' on anything unexpected).
function M.visibility(src, c)
    return Refs.visibility(src, { c })[1] or 'none'
end

--- VisRecord (§C3) of a loaded case.
M.visRecordOf = Refs.visRecord

--- Actor roles on a case.
function M.rolesOf(src, cid, c)
    local admin = C.perm(src, 'records.admin')
    local owner = c.owner ~= nil and c.owner == cid
    local lead = c.roles[cid] == 'lead'
    local assignee = c.roles[cid] ~= nil
    return { admin = admin, owner = owner, lead = lead, assignee = assignee,
        editor = admin or owner or lead, contributor = admin or owner or assignee }
end

--- Load a case for a write: not_found when missing or hidden (canView none), unauthorized when `need` ('editor' |
--- 'contributor' | 'full') is not met, validation/case_closed when `open` and the case is closed.
--- Returns c, vis, roles or nil, failure.
function M.forWrite(src, cid, id, need, open)
    local c = M.load(id)
    if not c then return nil, C.fail('not_found') end
    local vis = M.visibility(src, c)
    if vis == 'none' then return nil, C.fail('not_found') end
    local roles = M.rolesOf(src, cid, c)
    local allowed
    if need == 'editor' then allowed = roles.editor
    elseif need == 'contributor' then allowed = roles.contributor
    else allowed = vis == 'full' end
    if not allowed then return nil, C.fail('unauthorized') end
    if open and c.status ~= 'open' then return nil, C.failWith('validation', 'case_closed') end
    return c, vis, roles
end

---------------------------------------------------------------------------------------------------------------
-- Shaping

--- OfficerRef from an officers map (caserefs.officers); nil when unknown. `fallback` = use the citizenid as name.
function M.officerRef(cid, officers, fallback)
    if not cid then return nil end
    local o = officers[cid]
    local name = o and o.displayName or (fallback and cid or nil)
    if not name then return nil end
    return { citizenid = cid, displayName = name, callsign = o and o.callsign or nil, unit = o and o.unit or nil }
end

--- Subject label: person name (citizenid when not mirrored) or plate (+ model).
local function subjectsOf(caseId)
    local rows = must(MySQL.query.await(M.SUBJECTS_SQL, { caseId }), 'fredpd_case_subjects')
    local out = {}
    for _, r in ipairs(rows) do
        local id = C.str(r.subject_id)
        local role = C.enum(r.role, SUBJECT_ROLES, 'other') or 'other'
        if id and r.subject_type == 'person' then
            out[#out + 1] = { type = 'person', citizenid = id, label = C.fullName(r.firstname, r.lastname) or id, role = role }
        elseif id and r.subject_type == 'vehicle' then
            local model = C.str(r.model)
            out[#out + 1] = { type = 'vehicle', plate = id, label = model and (id .. ' (' .. model .. ')') or id, role = role }
        end
    end
    return out
end
M.subjectsOf = subjectsOf

--- VisRecord of a report (§C3): the report's own level, the case's status/unit/owner, the case assignees plus the
--- author (so an author always reads their own report).
function M.reportVisRecord(c, r)
    local assignees = {}
    for _, a in ipairs(c.assignees or {}) do assignees[#assignees + 1] = a end
    if r.author then assignees[#assignees + 1] = r.author end
    return { type = 'report', id = r.id, level = r.level, status = c.status, unit = c.unit,
        assignees = assignees, ownerCitizenid = c.owner }
end

--- canViewMany for a list of VisRecords ('none' on failure; one warning).
function M.canViewMany(src, records)
    if #records == 0 then return {} end
    local ok, results = C.core('canViewMany', src, records)
    local out = {}
    if not ok or type(results) ~= 'table' then
        C.warnOnce('canViewMany:records', ('exports.fredpd_core:canViewMany failed (%s)'):format(tostring(results)))
        for i = 1, #records do out[i] = 'none' end
        return out
    end
    for i = 1, #records do out[i] = Refs.RESULTS[results[i]] and results[i] or 'none' end
    return out
end

--- Report rows of a case -> { id, number, title, level, author, createdAt }.
function M.reportRows(caseId)
    local rows = must(MySQL.query.await(M.REPORT_REFS_SQL, { caseId }), 'fredpd_reports')
    local out = {}
    for _, r in ipairs(rows) do
        local id = C.int(r.id)
        if id then
            out[#out + 1] = { id = id, number = C.str(r.report_number) or '', title = C.str(r.title) or '',
                level = C.level(r.level), author = C.str(r.author_citizenid), createdAt = Time.toIsoUtc(C.str(r.createdAt)) }
        end
    end
    return out
end

--- Evidence of the case from fredpd_forensics (listCaseEvidence, which applies its own canView; listEvidence as the
--- fallback). [] while fredpd_forensics is stopped or failing.
function M.evidenceOf(src, caseId)
    if GetResourceState('fredpd_forensics') ~= 'started' then return {} end
    local res
    for _, name in ipairs({ 'listCaseEvidence', 'listEvidence' }) do
        local ok, r = pcall(function() return exports.fredpd_forensics[name](exports.fredpd_forensics, src, { caseId = caseId }) end)
        if ok and type(r) == 'table' then res = r break end
        C.warnOnce('forensics:' .. name, ('exports.fredpd_forensics:%s failed: %s'):format(name, tostring(r)))
    end
    if type(res) ~= 'table' or res.ok ~= true or type(res.data) ~= 'table' or type(res.data.items) ~= 'table' then return {} end
    local out = {}
    for _, e in ipairs(res.data.items) do
        local id = type(e) == 'table' and C.int(e.id) or nil
        local tag = id and C.str(e.tag) or nil
        if id and tag and type(e.type) == 'string' then
            out[#out + 1] = { id = id, tag = tag, type = e.type, collectedAt = C.str(e.collectedAt) }
        end
    end
    return out
end

--- Timeline: audit rows of the case, its reports and its evidence, newest first, at most TIMELINE_MAX.
function M.timeline(caseId, reportIds, evidenceIds)
    local where = { "(a.target_type = 'case' AND a.target_id = ?)" }
    local params = { tostring(caseId) }
    if #reportIds > 0 then
        where[#where + 1] = "(a.target_type = 'report' AND a.target_id IN (" .. C.marks(#reportIds) .. '))'
        for _, id in ipairs(reportIds) do params[#params + 1] = tostring(id) end
    end
    if #evidenceIds > 0 then
        where[#where + 1] = "(a.target_type = 'evidence' AND a.target_id IN (" .. C.marks(#evidenceIds) .. '))'
        for _, id in ipairs(evidenceIds) do params[#params + 1] = tostring(id) end
    end
    local sql = "SELECT a.action, a.actor_citizenid, COALESCE(JSON_VALUE(a.meta, '$.label'), JSON_VALUE(a.meta, '$.tag')) "
        .. 'AS label, ' .. Time.isoSelect('a.created_at', 'at') .. ' FROM fredpd_audit a WHERE ('
        .. table.concat(where, ' OR ') .. ')' .. TIMELINE_EXCLUDE
        .. ' ORDER BY a.created_at DESC, a.id DESC LIMIT ' .. ('%d'):format(M.TIMELINE_MAX)
    local rows = must(MySQL.query.await(sql, params), 'fredpd_audit timeline')
    local actors = {}
    for _, r in ipairs(rows) do actors[#actors + 1] = C.str(r.actor_citizenid) end
    local officers = Refs.officers(actors)
    local out = {}
    for _, r in ipairs(rows) do
        local at, action = C.str(r.at), C.str(r.action)
        if at and action then
            local label = C.str(r.label)
            out[#out + 1] = {
                at = Time.toIsoUtc(at), action = action,
                actor = M.officerRef(C.str(r.actor_citizenid), officers, false),
                detail = label and C.text(label, 1, 160) or nil,
            }
        end
    end
    return out
end

--- CaseDetail (§C14) for a loaded case and its visibility ('none' must be handled by the caller).
function M.detail(src, c, vis)
    local wanted = { c.owner }
    for _, a in ipairs(c.assignees) do wanted[#wanted + 1] = a end
    local officers = Refs.officers(wanted)
    if vis == 'notice' then
        local o = c.owner and officers[c.owner] or nil
        return { visibility = 'notice', contact = { displayName = o and o.displayName or nil, unit = (o and o.unit) or c.unit } }
    end
    local tier = C.tier(src)
    local content = vis == 'full' or c.level <= tier
    local assignees = {}
    for _, a in ipairs(c.assigneeRows) do
        local ref = M.officerRef(a.citizenid, officers, true)
        ref.role = a.role
        assignees[#assignees + 1] = ref
    end

    local reportRows = M.reportRows(c.id)
    local recs = {}
    for i, r in ipairs(reportRows) do recs[i] = M.reportVisRecord(c, r) end
    local rvis = M.canViewMany(src, recs)
    local authorIds, reportIds = {}, {}
    for i, r in ipairs(reportRows) do
        authorIds[i] = r.author
        reportIds[i] = r.id
    end
    local authors = Refs.officers(authorIds)
    local reports = {}
    for i, r in ipairs(reportRows) do
        local v = rvis[i]
        if v ~= 'none' then
            local titleOk = v == 'full' or (v == 'masked' and r.level <= tier)
            reports[#reports + 1] = { id = r.id, reportNumber = r.number, title = titleOk and r.title or nil, level = r.level,
                author = M.officerRef(r.author, authors, false), createdAt = r.createdAt }
        end
    end

    local evidence = M.evidenceOf(src, c.id)
    local evidenceIds = {}
    for i, e in ipairs(evidence) do evidenceIds[i] = e.id end
    return {
        visibility = vis,
        id = c.id, caseNumber = c.caseNumber, status = c.status, level = c.level, unit = c.unit,
        owner = M.officerRef(c.owner, officers, false),
        assignees = assignees,
        createdAt = c.createdAt, closedAt = c.closedAt,
        title = content and c.title or nil,
        summary = content and c.summary or nil,
        subjects = content and subjectsOf(c.id) or {},
        reports = reports,
        evidence = evidence,
        timeline = content and M.timeline(c.id, reportIds, evidenceIds) or {},
    }
end

--- Detail of case `id` for src after a write (the writer always sees at least what it just changed).
function M.detailOf(src, id)
    local c = M.load(id)
    if not c then return C.fail('not_found') end
    local vis = M.visibility(src, c)
    if vis == 'none' then return C.fail('not_found') end
    return C.ok(M.detail(src, c, vis))
end

---------------------------------------------------------------------------------------------------------------
-- Notifications

--- Push topic 'case' (ids only) to the open tablets of the case's owner and assignees (+ `extra` citizenids), and fire
--- the §4.3 server event.
function M.announce(c, extra)
    local members = {}
    if c.owner then members[c.owner] = true end
    for _, a in ipairs(c.assignees or {}) do members[a] = true end
    for _, cid in ipairs(extra or {}) do members[cid] = true end
    C.push('case', { type = 'caseUpdated', caseId = c.id }, function(target)
        local cid = C.actor(target)
        return cid ~= nil and members[cid] == true
    end)
    TriggerEvent('fredpd:caseUpdated', c.id)
end

---------------------------------------------------------------------------------------------------------------
-- Reads

--- export getCase(src, { id }) -> CaseDetail
function M.getCase(src, input)
    local actor
    src, actor = C.gate(src, 'mdt_page', 'cases')
    if not src then return actor end
    local id = type(input) == 'table' and C.id(input.id) or nil
    if not id then return C.fail('validation') end
    return M.detailOf(src, id)
end

local LIST_FILTERS = { 'mine', 'unit', 'open', 'closed', 'all' }
local CASE_ORDER = " ORDER BY (c.status = 'open') DESC, c.updated_at DESC, c.id DESC"

--- LIKE pattern for a user string (%, _ and \ escaped).
local function likeContains(s)
    return '%' .. s:gsub('[\\%%_]', '\\%0') .. '%'
end

--- export listCases(src, { filter, query?, page }) -> { items: CaseRef[], total, page }
--- Candidates (at most LIST_SCAN, most relevant first) are read by filter/query, shaped by canView and only full/masked
--- refs are listed: kontaktnotiser belong on person/vehicle pages, and counting them would tell how many cases a unit
--- holds. A title match on a masked case whose title the viewer may not see is dropped (the match would leak it).
function M.listCases(src, input)
    local actor
    src, actor = C.gate(src, 'mdt_page', 'cases')
    if not src then return actor end
    if input ~= nil and type(input) ~= 'table' then return C.fail('validation') end
    input = input or {}
    local filter = C.enum(input.filter, LIST_FILTERS, 'mine')
    local query = input.query ~= nil and C.text(input.query, 0, 64) or nil
    local page = C.optInt(input.page, 1, 10000, 1)
    if not filter or (input.query ~= nil and not query) or not page then return C.fail('validation') end

    local where, params = {}, {}
    local from = ' FROM fredpd_cases c'
    if filter == 'mine' then
        from = from .. ' JOIN (SELECT id AS case_id FROM fredpd_cases WHERE owner_citizenid = ? '
            .. 'UNION SELECT case_id FROM fredpd_case_assignees WHERE citizenid = ?) m ON m.case_id = c.id'
        params[#params + 1], params[#params + 2] = actor, actor
    elseif filter == 'unit' then
        local units = C.units(src)
        if #units == 0 then return C.ok({ items = {}, total = 0, page = page }) end
        where[#where + 1] = 'c.unit IN (' .. C.marks(#units) .. ')'
        for _, u in ipairs(units) do params[#params + 1] = u end
    elseif filter == 'open' or filter == 'closed' then
        where[#where + 1] = 'c.status = ?'
        params[#params + 1] = filter
    end
    local q = query and query ~= '' and query or nil
    if q then
        where[#where + 1] = '(c.case_number LIKE ? OR c.title LIKE ?)'
        params[#params + 1] = likeContains(q:upper())
        params[#params + 1] = likeContains(q)
    end
    local sql = 'SELECT ' .. Refs.CASE_COLS .. from .. (#where > 0 and (' WHERE ' .. table.concat(where, ' AND ')) or '')
        .. CASE_ORDER .. ' LIMIT ' .. ('%d'):format(M.LIST_SCAN)
    local rows = must(MySQL.query.await(sql, params), 'case list')
    local cases = Refs.fromRows(rows)
    local refs = Refs.evaluate(src, cases)
    local items = {}
    local needle = q and q:upper() or nil
    for _, ref in ipairs(refs) do
        if ref.visibility ~= 'notice' then
            local keep = true
            if needle and ref.title == nil then keep = ref.caseNumber:upper():find(needle, 1, true) ~= nil end
            if keep then items[#items + 1] = ref end
        end
    end
    local total = #items
    local first = (page - 1) * M.PAGE_SIZE + 1
    local pageItems = {}
    for i = first, math.min(total, first + M.PAGE_SIZE - 1) do pageItems[#pageItems + 1] = items[i] end
    return C.ok({ items = pageItems, total = total, page = page })
end

---------------------------------------------------------------------------------------------------------------
-- Writes

--- Next value of a fredpd_sequences counter (atomic; the insert id of NEXT_SEQ_SQL is the allocated value).
function M.nextSeq(seqType, year)
    local id = MySQL.insert.await(M.NEXT_SEQ_SQL, { seqType, year })
    local n = C.int(id)
    if not n or n < 1 then error(('nextSeq(%s, %d): no insert id'):format(seqType, year), 0) end
    return n
end

--- Stockholm calendar year of an ISO timestamp (formats.json tz), via the shared formatter.
function M.yearOf(iso)
    return math.tointeger(tonumber(Format.formatId('{{yyyy}}', { date = iso })))
end

--- '?' or NULL for an optional value (params appended in order).
local function opt(v, params)
    if v == nil then return 'NULL' end
    params[#params + 1] = v
    return '?'
end
M.opt = opt

--- Insert a case with a freshly numbered case_number. Returns id, caseNumber.
function M.insertNumbered(fields)
    local template = Format.get().caseNumber
    local now = Time.nowIso()
    local year = M.yearOf(now)
    for _ = 1, M.NUMBER_ATTEMPTS do
        local seq = M.nextSeq('case', year)
        local number = Format.formatId(template, { seq = seq, date = now })
        local params = { number, fields.title }
        local sql = 'INSERT INTO fredpd_cases (case_number, title, summary, status, level, unit, owner_citizenid, created_by, '
            .. 'updated_at, created_at) VALUES (?, ?, ' .. opt(fields.summary, params) .. ", 'open', ?, "
        params[#params + 1] = fields.level
        sql = sql .. opt(fields.unit, params) .. ', ?, ?, UTC_TIMESTAMP(), UTC_TIMESTAMP())'
        params[#params + 1] = fields.owner
        params[#params + 1] = fields.owner
        local ok, id = pcall(MySQL.insert.await, sql, params)
        id = ok and C.int(id) or nil
        if id and id > 0 then return id, number end
        -- a duplicate number (e.g. a hand-made row) moves on to the next sequence value; anything else is fatal
        local taken = MySQL.scalar.await('SELECT id FROM fredpd_cases WHERE case_number = ?', { number })
        if not taken and not (not ok and C.isDuplicate(id)) then
            error(('case insert failed: %s'):format(tostring(id)), 0)
        end
        C.warn(('case number %s already taken; allocating the next one'):format(number))
    end
    error('no free case number after retries', 0)
end

--- export createCase(src, CaseCreateInput) -> CaseDetail
function M.createCase(src, input)
    local actor
    src, actor = C.gate(src, 'perm', 'cases.create')
    if not src then return actor end
    if type(input) ~= 'table' then return C.fail('validation') end
    local title = C.text(input.title, 3, 160)
    local summary = nil
    if input.summary ~= nil then
        summary = type(input.summary) == 'string' and C.body(C.trim(input.summary), 20000, true) or nil
        if summary == nil then return C.fail('validation') end
        if summary == '' then summary = nil end
    end
    local level = C.optLevel(input.level, 0)
    local unit = C.optText(input.unit, 1, 32)
    if not title or level == false or unit == false then return C.fail('validation') end
    if level > C.tier(src) then return C.failWith('unauthorized', 'level_above_tier') end
    local units = C.units(src)
    if unit then
        local mine = false
        for _, u in ipairs(units) do if u == unit then mine = true end end
        if not mine and not C.perm(src, 'records.admin') then return C.failWith('unauthorized', 'unit') end
    else
        unit = units[1]
    end
    if not Search.loadFormats() then return C.fail('unavailable') end

    local id, number = M.insertNumbered({ title = title, summary = summary, level = level, unit = unit, owner = actor })
    C.auditWrite(src, 'case.create', 'case', id, { label = number, level = level, unit = unit })
    M.announce({ id = id, owner = actor, assignees = {} })
    return M.detailOf(src, id)
end

--- export updateCase(src, CaseUpdateInput) -> CaseDetail. summary '' clears it (JSON null cannot cross into Lua).
function M.updateCase(src, input)
    local actor
    src, actor = C.gate(src, 'mdt_page', 'cases')
    if not src then return actor end
    if type(input) ~= 'table' then return C.fail('validation') end
    local id = C.id(input.id)
    local title = C.optText(input.title, 3, 160)
    local summary = nil
    if input.summary ~= nil then
        if type(input.summary) ~= 'string' then return C.fail('validation') end
        summary = C.body(C.trim(input.summary), 20000, true)
        if summary == nil then return C.fail('validation') end
    end
    local level = C.optLevel(input.level, nil)
    if not id or title == false or level == false then return C.fail('validation') end

    local c, fail = M.forWrite(src, actor, id, 'editor', true)
    if not c then return fail end
    if level ~= nil and level ~= c.level then
        if level > C.tier(src) then return C.failWith('unauthorized', 'level_above_tier') end
        if level < c.level and not C.perm(src, 'records.admin') then return C.failWith('unauthorized', 'lowering_needs_admin') end
    end

    local changed, sets, params = {}, {}, {}
    if title and title ~= c.title then
        changed[#changed + 1] = 'title'
        sets[#sets + 1] = 'title = ?'
        params[#params + 1] = title
    end
    if summary ~= nil and summary ~= (c.summary or '') then
        changed[#changed + 1] = 'summary'
        sets[#sets + 1] = 'summary = ' .. opt(summary ~= '' and summary or nil, params)
    end
    if level ~= nil and level ~= c.level then
        changed[#changed + 1] = 'level'
        sets[#sets + 1] = 'level = ?'
        params[#params + 1] = level
    end
    if #changed == 0 then return C.ok(M.detail(src, c, M.visibility(src, c))) end
    params[#params + 1] = id
    local n = MySQL.update.await('UPDATE fredpd_cases SET ' .. table.concat(sets, ', ')
        .. ", updated_at = UTC_TIMESTAMP() WHERE id = ? AND status = 'open'", params)
    if (C.int(n) or 0) < 1 then return C.failWith('validation', 'case_closed') end
    C.auditWrite(src, 'case.update', 'case', id, { label = c.caseNumber, changed = changed,
        levelFrom = level ~= nil and c.level or nil, levelTo = level })
    M.announce(c)
    return M.detailOf(src, id)
end

--- Known officer? (fredpd_officers row)
local function officerExists(cid)
    return MySQL.scalar.await('SELECT citizenid FROM fredpd_officers WHERE citizenid = ?', { cid }) ~= nil
end

--- export assignCase(src, { id, citizenid, role = 'member' }) -> CaseDetail
function M.assignCase(src, input)
    local actor
    src, actor = C.gate(src, 'mdt_page', 'cases')
    if not src then return actor end
    if type(input) ~= 'table' then return C.fail('validation') end
    local id, cid = C.id(input.id), C.citizenid(input.citizenid)
    local role = C.enum(input.role, { 'lead', 'member' }, 'member')
    if not id or not cid or not role then return C.fail('validation') end
    local c, fail = M.forWrite(src, actor, id, 'editor', true)
    if not c then return fail end
    if not officerExists(cid) then return C.failWith('validation', 'unknown_officer') end
    if c.roles[cid] == role then return C.ok(M.detail(src, c, M.visibility(src, c))) end
    MySQL.query.await('INSERT INTO fredpd_case_assignees (case_id, citizenid, role, added_by) VALUES (?, ?, ?, ?) '
        .. 'ON DUPLICATE KEY UPDATE role = VALUES(role)', { id, cid, role, actor })
    MySQL.update.await('UPDATE fredpd_cases SET updated_at = UTC_TIMESTAMP() WHERE id = ?', { id })
    local name = Refs.officers({ cid })[cid]
    C.auditWrite(src, 'case.assign', 'case', id, { label = name and name.displayName or cid, citizenid = cid, role = role })
    M.announce(c, { cid })
    local target = C.onlineSrc(cid)
    if target and target ~= src then C.notify(target, 'inform', 'case.assignedToYou', { number = c.caseNumber }) end
    return M.detailOf(src, id)
end

--- export unassignCase(src, { id, citizenid }) -> CaseDetail
function M.unassignCase(src, input)
    local actor
    src, actor = C.gate(src, 'mdt_page', 'cases')
    if not src then return actor end
    if type(input) ~= 'table' then return C.fail('validation') end
    local id, cid = C.id(input.id), C.citizenid(input.citizenid)
    if not id or not cid then return C.fail('validation') end
    local c, fail = M.forWrite(src, actor, id, 'editor', true)
    if not c then return fail end
    if not c.roles[cid] then return C.failWith('validation', 'not_assigned') end
    MySQL.update.await('DELETE FROM fredpd_case_assignees WHERE case_id = ? AND citizenid = ?', { id, cid })
    MySQL.update.await('UPDATE fredpd_cases SET updated_at = UTC_TIMESTAMP() WHERE id = ?', { id })
    local name = Refs.officers({ cid })[cid]
    C.auditWrite(src, 'case.unassign', 'case', id, { label = name and name.displayName or cid, citizenid = cid })
    M.announce(c, { cid })
    return M.detailOf(src, id)
end

--- export addCaseSubject(src, CaseSubjectInput) -> CaseDetail. Person must be in fredpd_persons, a plate in
--- fredpd_vehicles_idx (refreshed from player_vehicles on a miss). Re-adding updates the role.
function M.addCaseSubject(src, input)
    local actor
    src, actor = C.gate(src, 'mdt_page', 'cases')
    if not src then return actor end
    if type(input) ~= 'table' then return C.fail('validation') end
    local id = C.id(input.id)
    local kind = C.enum(input.type, { 'person', 'vehicle' }, nil)
    local role = C.enum(input.role, SUBJECT_ROLES, 'other')
    if not id or not kind or not role then return C.fail('validation') end
    local subjectId, label
    if kind == 'person' then
        if input.plate ~= nil then return C.fail('validation') end
        subjectId = C.citizenid(input.citizenid)
    else
        if input.citizenid ~= nil then return C.fail('validation') end
        subjectId = C.plate(input.plate)
    end
    if not subjectId then return C.fail('validation') end

    local c, fail = M.forWrite(src, actor, id, 'contributor', true)
    if not c then return fail end
    if kind == 'person' then
        local p = MySQL.single.await('SELECT firstname, lastname FROM fredpd_persons WHERE citizenid = ?', { subjectId })
        if not p then return C.failWith('not_found', 'person') end
        label = C.fullName(p.firstname, p.lastname) or subjectId
    else
        local v = Search.vehicleRow(subjectId)
        if not v then return C.failWith('not_found', 'vehicle') end
        label = subjectId
    end
    MySQL.query.await('INSERT INTO fredpd_case_subjects (case_id, subject_type, subject_id, role, added_by) VALUES (?, ?, ?, ?, ?) '
        .. 'ON DUPLICATE KEY UPDATE role = VALUES(role)', { id, kind, subjectId, role, actor })
    MySQL.update.await('UPDATE fredpd_cases SET updated_at = UTC_TIMESTAMP() WHERE id = ?', { id })
    C.auditWrite(src, 'case.subject', 'case', id, { label = label, type = kind, subject = subjectId, role = role })
    M.announce(c)
    return M.detailOf(src, id)
end

--- export closeCase(src, { id, resolution }) -> CaseDetail. The level stays (sekretess after close, §8.7).
function M.closeCase(src, input)
    local actor
    src, actor = C.gate(src, 'mdt_page', 'cases')
    if not src then return actor end
    if type(input) ~= 'table' then return C.fail('validation') end
    local id = C.id(input.id)
    local resolution = type(input.resolution) == 'string'
        and C.body(C.trim(input.resolution), 2000, false) or nil
    if not id or not resolution or utf8.len(resolution) < 3 then return C.fail('validation') end
    local c, fail = M.forWrite(src, actor, id, 'editor', true)
    if not c then return fail end
    local n = MySQL.update.await("UPDATE fredpd_cases SET status = 'closed', closed_by = ?, closed_at = UTC_TIMESTAMP(), "
        .. "resolution = ?, updated_at = UTC_TIMESTAMP() WHERE id = ? AND status = 'open'", { actor, resolution, id })
    if (C.int(n) or 0) < 1 then return C.failWith('validation', 'case_closed') end
    C.auditWrite(src, 'case.close', 'case', id, { label = c.caseNumber, level = c.level })
    M.announce(c)
    return M.detailOf(src, id)
end

return M
