-- SPDX-License-Identifier: GPL-3.0-only
-- Reports (task 5.1 server / 5.3 server; §C14, ReportDetailSchema in packages/types/src/records.ts).
-- Exports: getReport, createReport, saveReport, saveReportDraft, listReportTemplates.
--
-- Visibility: record type 'report' (the report's own level, the case's status/unit/owner, the case assignees plus the
-- author). none -> not_found; notice -> unauthorized/notice (ReportDetail has no kontaktnotis shape).
-- Create: canView 'full' on an open case (owner, assignees, the owning unit, records.admin), level <= tier.
-- Edit (saveReport, drafts, charges): author, case owner, case lead or records.admin; case open; report level <= tier.
-- Numbering: n = MAX(n) + 1 per case; the insert runs in one oxmysql batch transaction that first locks the case row
-- (SELECT … FOR UPDATE) and inserts only while the case is open. oxmysql batches cannot carry a value from one
-- statement to the next (docs/deps-verification.md §10), so n is read before the batch; a concurrent report that took
-- the same n makes the batch fail on uq_case_n / uq_report_number and it is retried with a fresh n.
-- Body: markdown-lite stored as given (the NUI renders it as text); control characters other than LF/TAB are
-- stripped, CRLF normalised, at most 100 000 code points. Drafts (fredpd_report_drafts) are not audited (§C7).

local C = require 'server.common'
local Cases = require 'server.cases'
local Refs = require 'server.caserefs'
local Search = require 'server.search'
local Time = require '@fredpd_core.shared.time'
local Format = require '@fredpd_core.shared.format'

local M = {}

M.BODY_MAX = 100000
M.INSERT_ATTEMPTS = 5

M.REPORT_SQL = 'SELECT r.id, r.case_id, r.n, r.report_number, r.title, r.body, r.level, r.author_citizenid, '
    .. Time.isoSelect('r.created_at', 'createdAt') .. ', ' .. Time.isoSelect('r.updated_at', 'updatedAt')
    .. ' FROM fredpd_reports r WHERE r.id = ?'

M.CHARGES_SQL = 'SELECT rec.id, rec.citizenid, p.firstname, p.lastname, rec.charge_code, rec.title_sv, rec.class, '
    .. 'rec.quantity, rec.fine, rec.jail_min, rec.status FROM fredpd_records rec '
    .. 'LEFT JOIN fredpd_persons p ON p.citizenid = rec.citizenid WHERE rec.report_id = ? ORDER BY rec.id'

M.NEXT_N_SQL = 'SELECT COALESCE(MAX(n), 0) + 1 FROM fredpd_reports WHERE case_id = ?'
M.LOCK_CASE_SQL = 'SELECT id FROM fredpd_cases WHERE id = ? FOR UPDATE'

local CLASSES = { ordningsbot = true, bot = true, ['fängelse'] = true }
local STATUSES = { issued = true, paid = true, served = true, revoked = true }

---------------------------------------------------------------------------------------------------------------
-- Loading and access

--- Report row -> table, or nil.
function M.load(id)
    local row = MySQL.single.await(M.REPORT_SQL, { id })
    if not row then return nil end
    local rid = C.int(row.id)
    local caseId = C.int(row.case_id)
    if not rid or not caseId then return nil end
    return {
        id = rid, caseId = caseId, n = C.int(row.n), number = C.str(row.report_number) or '',
        title = C.str(row.title) or '', body = C.str(row.body) or '', level = C.level(row.level),
        author = C.str(row.author_citizenid),
        createdAt = Time.toIsoUtc(C.str(row.createdAt)), updatedAt = Time.toIsoUtc(C.str(row.updatedAt)),
    }
end

--- Whether src may edit the report (author, case owner/lead, records.admin; case open; level <= tier).
function M.editable(src, cid, c, r, tier)
    if c.status ~= 'open' or r.level > tier then return false end
    if r.author == cid then return true end
    return Cases.rolesOf(src, cid, c).editor
end

--- Load report + case and the viewer's visibility. Returns r, c, vis or nil, failure (none/missing -> not_found).
function M.loadVisible(src, id)
    local r = M.load(id)
    if not r then return nil, C.fail('not_found') end
    local c = Cases.load(r.caseId)
    if not c then return nil, C.fail('not_found') end
    local vis = Cases.canViewMany(src, { Cases.reportVisRecord(c, r) })[1]
    if vis == 'none' then return nil, C.fail('not_found') end
    return r, c, vis
end

--- Report + case for an edit. Returns r, c, tier or nil, failure.
function M.forEdit(src, cid, id)
    local r, c, vis = M.loadVisible(src, id)
    if not r then return nil, c end
    local tier = C.tier(src)
    if vis == 'notice' then return nil, C.failWith('unauthorized', 'notice') end
    if not M.editable(src, cid, c, r, tier) then
        if c.status ~= 'open' then return nil, C.failWith('validation', 'case_closed') end
        return nil, C.fail('unauthorized')
    end
    return r, c, tier
end

--- AppliedCharge rows of a report.
function M.chargesOf(reportId)
    local rows = MySQL.query.await(M.CHARGES_SQL, { reportId })
    if type(rows) ~= 'table' then error('fredpd_records query failed', 0) end
    return M.toApplied(rows)
end

--- fredpd_records rows (+ firstname/lastname) -> AppliedCharge[].
function M.toApplied(rows)
    local out = {}
    for _, row in ipairs(rows) do
        local id, cid = C.int(row.id), C.citizenid(C.str(row.citizenid))
        local class, status = C.str(row.class), C.str(row.status)
        if id and cid and CLASSES[class] and STATUSES[status] then
            out[#out + 1] = {
                id = id, citizenid = cid, personName = C.fullName(row.firstname, row.lastname) or cid,
                code = C.str(row.charge_code) or '', title = C.str(row.title_sv) or '', class = class,
                quantity = math.max(1, C.nonNeg(row.quantity)), fine = C.nonNeg(row.fine),
                jailMinutes = C.nonNeg(row.jail_min), status = status,
            }
        end
    end
    return out
end

--- ReportDetail.
function M.detail(src, cid, r, c)
    local authors = Refs.officers({ r.author })
    return {
        id = r.id, reportNumber = r.number, caseId = c.id, caseNumber = c.caseNumber, title = r.title, body = r.body,
        level = r.level, author = Cases.officerRef(r.author, authors, false), createdAt = r.createdAt,
        updatedAt = r.updatedAt, charges = M.chargesOf(r.id), editable = M.editable(src, cid, c, r, C.tier(src)),
    }
end

---------------------------------------------------------------------------------------------------------------
-- Exports

--- export getReport(src, { id }) -> ReportDetail
function M.getReport(src, input)
    local actor
    src, actor = C.gate(src, 'mdt_page', 'cases')
    if not src then return actor end
    local id = type(input) == 'table' and C.id(input.id) or nil
    if not id then return C.fail('validation') end
    local r, c, vis = M.loadVisible(src, id)
    if not r then return c end
    if vis == 'notice' then return C.failWith('unauthorized', 'notice') end
    if vis == 'masked' and r.level > C.tier(src) then return C.failWith('unauthorized', 'notice') end
    return C.ok(M.detail(src, actor, r, c))
end

--- Template body for createReport: active, offered to every unit or to one of the actor's units. nil = not usable.
local function templateBody(src, templateId)
    local row = MySQL.single.await('SELECT body, unit FROM fredpd_report_templates WHERE id = ? AND active = 1', { templateId })
    if not row then return nil end
    local unit = C.str(row.unit)
    if unit then
        local ok = false
        for _, u in ipairs(C.units(src)) do if u == unit then ok = true end end
        if not ok then return nil end
    end
    return C.body(C.str(row.body) or '', M.BODY_MAX, true)
end

--- Insert a report with the next n of its case (see the header). Returns id, number, or nil, 'case_closed'.
function M.insertNumbered(c, fields)
    local template = Format.get().reportNumber
    for _ = 1, M.INSERT_ATTEMPTS do
        local n = C.int(MySQL.scalar.await(M.NEXT_N_SQL, { c.id })) or 1
        local number = Format.formatId(template, { case = c.caseNumber, n = n })
        local params = { c.id, n, number, fields.title, fields.body }
        local sql = 'INSERT INTO fredpd_reports (case_id, n, report_number, title, body, template_id, level, author_citizenid, '
            .. 'updated_by, updated_at, created_at) SELECT ?, ?, ?, ?, ?, ' .. Cases.opt(fields.templateId, params)
            .. ", ?, ?, ?, UTC_TIMESTAMP(), UTC_TIMESTAMP() FROM fredpd_cases WHERE id = ? AND status = 'open'"
        params[#params + 1] = fields.level
        params[#params + 1] = fields.author
        params[#params + 1] = fields.author
        params[#params + 1] = c.id
        local ok = MySQL.transaction.await({
            { query = M.LOCK_CASE_SQL, values = { c.id } },
            { query = sql, values = params },
        })
        if ok then
            local id = C.int(MySQL.scalar.await('SELECT id FROM fredpd_reports WHERE report_number = ?', { number }))
            if id then return id, number end
            return nil, 'case_closed'
        end
    end
    error('report insert failed after retries', 0)
end

--- export createReport(src, { caseId, title, templateId?, level = 0 }) -> ReportDetail
function M.createReport(src, input)
    local actor
    src, actor = C.gate(src, 'mdt_page', 'cases')
    if not src then return actor end
    if type(input) ~= 'table' then return C.fail('validation') end
    local caseId = C.id(input.caseId)
    local title = C.text(input.title, 3, 160)
    local templateId = input.templateId ~= nil and C.id(input.templateId) or nil
    local level = C.optLevel(input.level, 0)
    if not caseId or not title or (input.templateId ~= nil and not templateId) or level == false then
        return C.fail('validation')
    end
    local c, fail = Cases.forWrite(src, actor, caseId, 'full', true)
    if not c then return fail end
    if level > C.tier(src) then return C.failWith('unauthorized', 'level_above_tier') end
    local body = ''
    if templateId then
        body = templateBody(src, templateId)
        if not body then return C.failWith('validation', 'template') end
    end
    if not Search.loadFormats() then return C.fail('unavailable') end

    local id, number = M.insertNumbered(c, { title = title, body = body, templateId = templateId, level = level, author = actor })
    if not id then return C.failWith('validation', number) end
    C.auditWrite(src, 'report.create', 'report', id, { label = number, caseId = c.id, level = level })
    Cases.announce(c)
    local r = M.load(id)
    return C.ok(M.detail(src, actor, r, c))
end

--- export saveReport(src, { id, title, body, level }) -> ReportDetail. Clears the actor's draft of the report.
function M.saveReport(src, input)
    local actor
    src, actor = C.gate(src, 'mdt_page', 'cases')
    if not src then return actor end
    if type(input) ~= 'table' then return C.fail('validation') end
    local id = C.id(input.id)
    local title = C.text(input.title, 3, 160)
    local body = C.body(input.body, M.BODY_MAX, true)
    local level = C.optLevel(input.level, nil)
    if not id or not title or not body or level == nil or level == false then return C.fail('validation') end
    local r, c, tier = M.forEdit(src, actor, id)
    if not r then return c end
    if level ~= r.level then
        if level > tier then return C.failWith('unauthorized', 'level_above_tier') end
        if level < r.level and not C.perm(src, 'records.admin') then return C.failWith('unauthorized', 'lowering_needs_admin') end
    end
    local n = MySQL.update.await('UPDATE fredpd_reports r JOIN fredpd_cases c ON c.id = r.case_id SET r.title = ?, r.body = ?, '
        .. "r.level = ?, r.updated_by = ?, r.updated_at = UTC_TIMESTAMP() WHERE r.id = ? AND c.status = 'open'",
        { title, body, level, actor, id })
    if (C.int(n) or 0) < 1 then return C.failWith('validation', 'case_closed') end
    MySQL.update.await('DELETE FROM fredpd_report_drafts WHERE author_citizenid = ? AND report_id = ?', { actor, id })
    C.auditWrite(src, 'report.save', 'report', id, { label = r.number, caseId = c.id, level = level,
        levelFrom = level ~= r.level and r.level or nil, chars = utf8.len(body) })
    Cases.announce(c)
    return C.ok(M.detail(src, actor, M.load(id), c))
end

--- export saveReportDraft(src, { reportId, title?, body }) -> { savedAt }. Upsert of the actor's draft; not audited.
function M.saveReportDraft(src, input)
    local actor
    src, actor = C.gate(src, 'mdt_page', 'cases')
    if not src then return actor end
    if type(input) ~= 'table' then return C.fail('validation') end
    local id = C.id(input.reportId)
    local title = nil
    if input.title ~= nil then
        title = C.body(input.title, 160, true)
        if not title or title:find('\n', 1, true) then return C.fail('validation') end
    end
    local body = C.body(input.body, M.BODY_MAX, true)
    if not id or not body then return C.fail('validation') end
    local r, c = M.forEdit(src, actor, id)
    if not r then return c end
    local params = { actor, id, c.id }
    local sql = 'INSERT INTO fredpd_report_drafts (author_citizenid, report_id, case_id, title, body, updated_at) VALUES (?, ?, ?, '
        .. Cases.opt(title, params) .. ', ?, UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE title = VALUES(title), '
        .. 'body = VALUES(body), updated_at = UTC_TIMESTAMP()'
    params[#params + 1] = body
    MySQL.query.await(sql, params)
    local savedAt = MySQL.scalar.await('SELECT DATE_FORMAT(updated_at, \'%Y-%m-%dT%H:%i:%sZ\') FROM fredpd_report_drafts '
        .. 'WHERE author_citizenid = ? AND report_id = ?', { actor, id })
    return C.ok({ savedAt = Time.toIsoUtc(C.str(savedAt)) or Time.nowIso() })
end

--- export listReportTemplates(src, {}) -> { items: ReportTemplate[] }: active, for every unit or one of the actor's.
function M.listReportTemplates(src, input)
    local actor
    src, actor = C.gate(src, 'mdt_page', 'cases')
    if not src then return actor end
    if input ~= nil and (type(input) ~= 'table' or next(input) ~= nil) then return C.fail('validation') end
    local units = C.units(src)
    local params, unitSql = {}, ''
    if #units > 0 then
        unitSql = ' OR unit IN (' .. C.marks(#units) .. ')'
        for _, u in ipairs(units) do params[#params + 1] = u end
    end
    local rows = MySQL.query.await('SELECT id, name, unit, body FROM fredpd_report_templates WHERE active = 1 AND (unit IS NULL'
        .. unitSql .. ') ORDER BY (unit IS NOT NULL), name, id', params)
    if type(rows) ~= 'table' then error('fredpd_report_templates query failed', 0) end
    local items = {}
    for _, row in ipairs(rows) do
        local id = C.int(row.id)
        if id then items[#items + 1] = { id = id, name = C.str(row.name) or '', unit = C.str(row.unit), body = C.str(row.body) or '' } end
    end
    return C.ok({ items = items })
end

return M
