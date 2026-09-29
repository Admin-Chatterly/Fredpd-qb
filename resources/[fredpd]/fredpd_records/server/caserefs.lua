-- SPDX-License-Identifier: GPL-3.0-only
-- Case references with visibility applied (docs/contracts.md §C3, CaseRefSchema in packages/types/src/mdt.ts).
-- Cases are read from fredpd_cases (+ fredpd_case_assignees for canView), evaluated for the viewer in one
-- canViewMany call, and shaped:
--   full   -> { visibility, id, caseNumber, title, status, level, role }
--   masked -> the same, title only when the case level <= viewer tier (else absent = null on the wire)
--   notice -> { visibility, contact = { displayName, unit } }: no id, number, title or level (kontaktnotis);
--             contact = the case owner's fredpd_officers display name and unit (case unit when the owner has none)
--   none   -> omitted entirely
-- Lua cannot carry null: a nullable field that is nil is absent on every Lua -> JS hop (as in fredpd_dispatch).

local C = require 'server.common'

local M = {}

M.CASE_COLS = 'c.id, c.case_number, c.title, c.status, c.level, c.unit, c.owner_citizenid'
M.RESULTS = { full = true, masked = true, notice = true, none = true }
M.ROLES = { suspect = true, victim = true, witness = true, vehicle = true, other = true }

--- fredpd_cases row (M.CASE_COLS, optionally `role`) -> internal case table, or nil for an unusable row.
function M.rowToCase(row, role)
    if type(row) ~= 'table' then return nil end
    local id = C.int(row.id)
    local status = row.status
    if not id or (status ~= 'open' and status ~= 'closed') then return nil end
    role = role or row.role
    return {
        id = id,
        caseNumber = C.str(row.case_number) or '',
        title = C.str(row.title) or '',
        status = status,
        level = C.level(row.level),
        unit = C.str(row.unit),
        owner = C.str(row.owner_citizenid),
        role = M.ROLES[role] and role or nil,
        assignees = {},
    }
end

--- Fill `assignees` of every case with one query.
function M.attachAssignees(cases)
    local ids, byId = {}, {}
    for _, c in ipairs(cases) do
        if not byId[c.id] then
            byId[c.id] = {}
            ids[#ids + 1] = c.id
        end
    end
    if #ids == 0 then return end
    local rows = MySQL.query.await('SELECT case_id, citizenid FROM fredpd_case_assignees WHERE case_id IN ('
        .. C.marks(#ids) .. ') ORDER BY case_id, citizenid', ids)
    if type(rows) ~= 'table' then error('fredpd_case_assignees query failed', 0) end
    for _, row in ipairs(rows) do
        local list = byId[C.int(row.case_id)]
        local cid = C.str(row.citizenid)
        if list and cid then list[#list + 1] = cid end
    end
    for _, c in ipairs(cases) do c.assignees = byId[c.id] end
end

--- VisRecord (§C3) of a case.
function M.visRecord(c)
    return {
        type = 'case', id = c.id, level = c.level, status = c.status, unit = c.unit,
        assignees = c.assignees or {}, ownerCitizenid = c.owner,
    }
end

--- canView results for a list of cases (same order), one canViewMany call; falls back to canView per case when
--- the batch export fails. Anything unexpected is 'none' (fail closed).
function M.visibility(src, cases)
    local records = {}
    for i, c in ipairs(cases) do records[i] = M.visRecord(c) end
    local out = {}
    if #records == 0 then return out end
    local ok, results = C.core('canViewMany', src, records)
    if not ok or type(results) ~= 'table' then
        C.warnOnce('canViewMany', ('exports.fredpd_core:canViewMany failed (%s); using canView per case')
            :format(tostring(results)))
        results = {}
        for i, rec in ipairs(records) do
            local okOne, res = C.core('canView', src, rec)
            results[i] = okOne and res or 'none'
        end
    end
    for i = 1, #records do
        local r = results[i]
        out[i] = M.RESULTS[r] and r or 'none'
    end
    return out
end

--- { [citizenid] = { displayName, callsign, unit } } from fredpd_officers.
function M.officers(citizenids)
    local ids, seen, out = {}, {}, {}
    for _, cid in ipairs(citizenids) do
        if cid and not seen[cid] then
            seen[cid] = true
            ids[#ids + 1] = cid
        end
    end
    if #ids == 0 then return out end
    local rows = MySQL.query.await('SELECT citizenid, display_name, callsign, unit FROM fredpd_officers '
        .. 'WHERE citizenid IN (' .. C.marks(#ids) .. ')', ids)
    if type(rows) ~= 'table' then error('fredpd_officers query failed', 0) end
    for _, row in ipairs(rows) do
        local cid = C.str(row.citizenid)
        if cid then
            out[cid] = { displayName = C.str(row.display_name), callsign = C.str(row.callsign), unit = C.str(row.unit) }
        end
    end
    return out
end

--- CaseRef for one case and its visibility (nil for 'none'). `officers` holds the notice contacts.
function M.toRef(c, vis, tier, officers)
    if vis == 'full' or vis == 'masked' then
        return {
            visibility = vis,
            id = c.id,
            caseNumber = c.caseNumber,
            title = (vis == 'full' or c.level <= tier) and c.title or nil,
            status = c.status,
            level = c.level,
            role = c.role,
        }
    end
    if vis == 'notice' then
        local o = c.owner and officers[c.owner] or nil
        return {
            visibility = 'notice',
            contact = { displayName = o and o.displayName or nil, unit = (o and o.unit) or c.unit },
        }
    end
    return nil
end

--- Visibility for `cases` (assignees must be attached) and the CaseRefs of the first `refCount` of them (default
--- all). Returns refs (list, 'none' omitted, input order kept) and vis (list aligned with `cases`). Extra cases
--- after refCount are only evaluated (e.g. the cases of charge records, whose number is shown only when visible).
function M.evaluate(src, cases, refCount)
    refCount = refCount or #cases
    local vis = M.visibility(src, cases)
    local owners, needTier = {}, false
    for i = 1, refCount do
        if vis[i] == 'notice' and cases[i].owner then owners[#owners + 1] = cases[i].owner end
        if vis[i] == 'masked' then needTier = true end
    end
    local officers = M.officers(owners)
    local tier = needTier and C.tier(src) or 0
    local refs = {}
    for i = 1, refCount do
        local ref = M.toRef(cases[i], vis[i], tier, officers)
        if ref then refs[#refs + 1] = ref end
    end
    return refs, vis
end

--- Cases by id (M.CASE_COLS rows), with assignees attached. Unknown ids are skipped.
function M.loadByIds(ids)
    if #ids == 0 then return {} end
    local rows = MySQL.query.await('SELECT ' .. M.CASE_COLS .. ' FROM fredpd_cases c WHERE c.id IN ('
        .. C.marks(#ids) .. ') ORDER BY c.id', ids)
    if type(rows) ~= 'table' then error('fredpd_cases query failed', 0) end
    local cases = {}
    for _, row in ipairs(rows) do
        local c = M.rowToCase(row)
        if c then cases[#cases + 1] = c end
    end
    M.attachAssignees(cases)
    return cases
end

--- Rows (M.CASE_COLS + optional role) -> cases with assignees; `role` overrides every row's role (e.g. 'vehicle').
function M.fromRows(rows, role)
    local cases = {}
    for _, row in ipairs(rows) do
        local c = M.rowToCase(row, role)
        if c then cases[#cases + 1] = c end
    end
    M.attachAssignees(cases)
    return cases
end

return M
