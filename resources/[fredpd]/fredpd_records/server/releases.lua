-- SPDX-License-Identifier: GPL-3.0-only
-- "Begär ut allmän handling" (task 5.6 server; IMPLEMENTATION.md §5.3, fredpd_release_requests in 003 + channel in 013).
-- Exports:
--   createReleaseRequest(src, { description, reference? })      any player (station target zone; also lib.callback
--                                                                 'fredpd:records:releaseRequest'); 1 per 60 s
--   createReleaseRequestPortal({ discordId, name, description, reference? })   service -> fredpd_core bridge only
--   listReleaseRequests(src, { status?, page })                  perm records.admin
--   decideReleaseRequest(src, { id, decision, note?, targetType?, targetId? })  perm records.admin
-- A decision 'approved' or 'partial' stores the masked export (server/export.lua: canView for a tier-0 public viewer,
-- only level-0 text, no source fields) as JSON in released_body; nothing releasable -> validation/nothing_releasable.
-- The requester never learns anything about the target before the decision (reference is stored, not echoed).
-- Shapes (no TS schema yet; docs/modules/records.md "Release requests"):
--   ReleaseRequest = { id, status, channel|null, requesterName|null, requesterCitizenid|null, description,
--                      target: { type, id, label|null } | null, createdAt, decidedAt|null, decidedBy: OfficerRef|null,
--                      decisionNote|null, released: ReleasedContent|null }

local C = require 'server.common'
local Cases = require 'server.cases'
local Refs = require 'server.caserefs'
local Export = require 'server.export'
local Time = require '@fredpd_core.shared.time'

local M = {}

M.PAGE_SIZE = 50
M.CREATE_COOLDOWN_MS = 60000
M.STATUSES = { 'pending', 'approved', 'partial', 'denied' }
M.DECISIONS = { 'approved', 'partial', 'denied' }
M.PORTAL_CALLERS = { fredpd_core = true, fredpd_records = true }

M.SELECT = 'SELECT r.id, r.requester_citizenid, r.requester_name, r.channel, r.target_type, r.target_id, r.description, '
    .. 'r.status, r.decided_by, r.decision_note, r.released_body, ' .. Time.isoSelect('r.created_at', 'createdAt') .. ', '
    .. Time.isoSelect('r.decided_at', 'decidedAt') .. ', c.case_number, rep.report_number FROM fredpd_release_requests r '
    .. "LEFT JOIN fredpd_cases c ON r.target_type = 'case' AND c.id = r.target_id "
    .. "LEFT JOIN fredpd_reports rep ON r.target_type = 'report' AND rep.id = r.target_id "

--- A case or report number -> 'case'|'report', id (nil when it matches neither).
function M.resolveReference(ref)
    if not ref or ref == '' then return nil end
    local up = ref:upper():gsub('%s', '')
    local caseId = C.int(MySQL.scalar.await('SELECT id FROM fredpd_cases WHERE case_number = ?', { up }))
    if caseId then return 'case', caseId end
    local reportId = C.int(MySQL.scalar.await('SELECT id FROM fredpd_reports WHERE report_number = ?', { up }))
    if reportId then return 'report', reportId end
    return nil
end

local function toRequest(row, officers)
    local released = nil
    if row.released_body then
        local ok, decoded = pcall(json.decode, C.str(row.released_body) or '')
        released = ok and type(decoded) == 'table' and decoded or nil
    end
    local ttype = C.str(row.target_type)
    local target = nil
    if ttype and C.str(row.target_id) then
        target = { type = ttype, id = C.str(row.target_id),
            label = ttype == 'case' and C.str(row.case_number) or ttype == 'report' and C.str(row.report_number) or nil }
    end
    return {
        id = C.int(row.id), status = C.enum(row.status, M.STATUSES, 'pending') or 'pending', channel = C.str(row.channel),
        requesterName = C.str(row.requester_name), requesterCitizenid = C.str(row.requester_citizenid),
        description = C.str(row.description) or '', target = target, createdAt = Time.toIsoUtc(C.str(row.createdAt)),
        decidedAt = row.decidedAt and Time.toIsoUtc(C.str(row.decidedAt)) or nil,
        decidedBy = Cases.officerRef(C.str(row.decided_by), officers, false),
        decisionNote = C.str(row.decision_note), released = released,
    }
end

local function loadRequest(id)
    local row = MySQL.single.await(M.SELECT .. 'WHERE r.id = ?', { id })
    if not row then return nil end
    return toRequest(row, Refs.officers({ C.str(row.decided_by) }))
end
M.load = loadRequest

--- Tell Ledning (open tablets with records.admin) that the release queue changed.
local function pushQueue(id)
    C.push(C.TOPIC_LEDNING, { type = 'releaseRequest', id = id }, function(target) return C.perm(target, 'records.admin') end)
end

--- Shared insert. Returns the new id.
local function insert(fields)
    local ttype, tid = M.resolveReference(fields.reference)
    local params = {}
    local sql = 'INSERT INTO fredpd_release_requests (requester_citizenid, requester_discord, requester_name, channel, '
        .. 'target_type, target_id, description, updated_at) VALUES (' .. Cases.opt(fields.citizenid, params) .. ', '
        .. Cases.opt(fields.discordId, params) .. ', ' .. Cases.opt(fields.name, params) .. ', ?, '
    params[#params + 1] = fields.channel
    sql = sql .. Cases.opt(ttype, params) .. ', ' .. Cases.opt(tid and tostring(tid) or nil, params) .. ', ?, UTC_TIMESTAMP())'
    params[#params + 1] = fields.description
    local id = C.int(MySQL.insert.await(sql, params))
    if not id then error('fredpd_release_requests insert failed', 0) end
    return id
end

local function requestInput(input)
    if type(input) ~= 'table' then return nil end
    local description = type(input.description) == 'string' and C.body(C.trim(input.description), 2000, false) or nil
    local reference = C.optText(input.reference, 0, 48)
    if not description or utf8.len(description) < 3 or reference == false then return nil end
    return description, reference
end

--- export createReleaseRequest(src, { description, reference? }) -> { id }. Any player with a character.
function M.createReleaseRequest(src, input)
    src = C.playerSrc(src)
    if not src then return C.fail('unauthorized') end
    local cid = C.actor(src)
    if not cid then return C.fail('unauthorized') end
    local description, reference = requestInput(input)
    if not description then return C.fail('validation') end
    if not C.rateLimit(src, 'releaseRequest', M.CREATE_COOLDOWN_MS) then return C.fail('rate_limited') end
    local person = MySQL.single.await('SELECT firstname, lastname FROM fredpd_persons WHERE citizenid = ?', { cid })
    local id = insert({ citizenid = cid, name = person and C.fullName(person.firstname, person.lastname) or nil,
        channel = 'station', description = description, reference = reference })
    C.auditWrite(src, 'release.create', 'release', id, { channel = 'station' })
    pushQueue(id)
    C.notify(src, 'success', 'release.submitted')
    return C.ok({ id = id })
end

--- export createReleaseRequestPortal({ discordId, name, description, reference? }) -> { id }. Only the fredpd_core
--- HTTP bridge (service) or this resource may call it; the Discord id comes from the service's session.
function M.createReleaseRequestPortal(input)
    local caller = GetInvokingResource and GetInvokingResource() or nil
    if caller and caller ~= '' and not M.PORTAL_CALLERS[caller] then return C.fail('unauthorized') end
    local description, reference = requestInput(input)
    local discordId = type(input) == 'table' and type(input.discordId) == 'string' and input.discordId:match('^%d+$')
        and #input.discordId <= 20 and input.discordId or nil
    local name = type(input) == 'table' and C.optText(input.name, 1, 100) or nil
    if not description or not discordId or name == false then return C.fail('validation') end
    local id = insert({ discordId = discordId, name = name, channel = 'portal', description = description, reference = reference })
    C.auditWrite(0, 'release.create', 'release', id, { channel = 'portal', discordId = discordId })
    pushQueue(id)
    return C.ok({ id = id })
end

--- export listReleaseRequests(src, { status?, page }) -> { items, total, page } (newest first; pending first).
function M.listReleaseRequests(src, input)
    local actor
    src, actor = C.gate(src, 'perm', 'records.admin')
    if not src then return actor end
    if input ~= nil and type(input) ~= 'table' then return C.fail('validation') end
    input = input or {}
    local status = C.enum(input.status, M.STATUSES, nil)
    local page = C.optInt(input.page, 1, 10000, 1)
    if status == false or not page then return C.fail('validation') end
    local where, params = '', {}
    if status then
        where = 'WHERE r.status = ? '
        params[1] = status
    end
    local total = C.nonNeg(MySQL.scalar.await('SELECT COUNT(*) FROM fredpd_release_requests r ' .. where, params))
    local rows = MySQL.query.await(M.SELECT .. where .. "ORDER BY (r.status = 'pending') DESC, r.created_at DESC, r.id DESC "
        .. ('LIMIT %d OFFSET %d'):format(M.PAGE_SIZE, (page - 1) * M.PAGE_SIZE), params)
    if type(rows) ~= 'table' then error('fredpd_release_requests query failed', 0) end
    local ids = {}
    for _, row in ipairs(rows) do ids[#ids + 1] = C.str(row.decided_by) end
    local officers = Refs.officers(ids)
    local items = {}
    for _, row in ipairs(rows) do items[#items + 1] = toRequest(row, officers) end
    return C.ok({ items = items, total = total, page = page })
end

--- export decideReleaseRequest(src, { id, decision, note?, targetType?, targetId? }) -> ReleaseRequest
function M.decideReleaseRequest(src, input)
    local actor
    src, actor = C.gate(src, 'perm', 'records.admin')
    if not src then return actor end
    if type(input) ~= 'table' then return C.fail('validation') end
    local id = C.id(input.id)
    local decision = C.enum(input.decision, M.DECISIONS, nil)
    local note = nil
    if input.note ~= nil then
        note = type(input.note) == 'string' and C.body(C.trim(input.note), 2000, true) or nil
        if note == nil then return C.fail('validation') end
        if note == '' then note = nil end
    end
    local ttype = C.enum(input.targetType, { 'case', 'report' }, nil)
    local tid = input.targetId ~= nil and C.id(input.targetId) or nil
    if not id or not decision or ttype == false or (input.targetId ~= nil and not tid) or ((ttype == nil) ~= (tid == nil)) then
        return C.fail('validation')
    end
    local req = loadRequest(id)
    if not req then return C.fail('not_found') end
    if req.status ~= 'pending' then return C.failWith('validation', 'already_decided') end
    if not ttype and req.target then
        ttype, tid = req.target.type, C.int(req.target.id)
    end

    local body = nil
    if decision ~= 'denied' then
        if not ttype or not tid then return C.failWith('validation', 'no_target') end
        local content = Export.release(ttype, tid)
        if not content then return C.failWith('validation', 'nothing_releasable') end
        body = json.encode(content)
    end
    local params = { decision, actor }
    local sql = 'UPDATE fredpd_release_requests SET status = ?, decided_by = ?, decided_at = UTC_TIMESTAMP(), decision_note = '
        .. Cases.opt(note, params) .. ', released_body = ' .. Cases.opt(body, params) .. ', target_type = '
        .. Cases.opt(ttype, params) .. ', target_id = ' .. Cases.opt(tid and tostring(tid) or nil, params)
        .. ", updated_at = UTC_TIMESTAMP() WHERE id = ? AND status = 'pending'"
    params[#params + 1] = id
    local n = C.int(MySQL.update.await(sql, params)) or 0
    if n < 1 then return C.failWith('validation', 'already_decided') end
    C.auditWrite(src, 'release.decide', 'release', id, { label = decision, decision = decision, targetType = ttype,
        targetId = tid })
    local requester = req.requesterCitizenid and C.onlineSrc(req.requesterCitizenid) or nil
    if requester then C.notify(requester, 'inform', 'release.notify.decided', { status = C.L('release.status.' .. decision) }) end
    pushQueue(id)
    return C.ok(loadRequest(id))
end

return M
