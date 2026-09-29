-- SPDX-License-Identifier: GPL-3.0-only
-- Visibility plumbing for fredpd_intel (pure Lua 5.4, no FiveM, no SQL): turns stored rows (server/store.lua shapes)
-- into canView VisRecords (docs/contracts.md §C3, §C15) and builds the small wire pieces every shape shares
-- (OfficerRef, kontaktnotis). The decision itself is always fredpd_core's canView/canViewMany; this module only
-- decides WHAT is asked and how two answers combine.
--
--   intel_source  handlerCitizenid = handler, level, unit, status
--   mission       ownerCitizenid = lead, assignees = members + lead, level, unit, status
--   intel_report  ownerCitizenid = author; mission-bound: assignees = mission members + lead, unit = mission unit.
--                 A mission-bound report is also capped by the viewer's view of its mission (min of the two), so a
--                 Hemlig insats's reports stay with its members and intel.command (docs/modules/intel.md).
--   link          asked as an intel_report record: level = max(link level, report level), status/owner from the
--                 report (the link's creator when there is none), assignees = the link's creator + the mission's
--                 members/lead; capped by the mission view like its report. Visible = full or masked.
--
-- Tested by tests/lua/intel_access_test.lua.

local M = {}

M.RANK = { none = 0, notice = 1, masked = 2, full = 3 }

--- The lower of two canView results (unknown values count as 'none').
function M.min(a, b)
    local ra, rb = M.RANK[a] or 0, M.RANK[b] or 0
    if ra <= rb then return M.RANK[a] and a or 'none' end
    return M.RANK[b] and b or 'none'
end

function M.visible(view)
    return view == 'full' or view == 'masked'
end

local function level(v)
    local l = math.tointeger(tonumber(v))
    if not l or l < 0 then return 2 end -- unknown level: treat as the strictest
    if l > 2 then return 2 end
    return l
end

local function status(v)
    return v == 'closed' and 'closed' or 'open'
end

--- Citizenids of a mission's members plus its lead, deduplicated, in order.
--- @param mission table { lead }
--- @param members table|nil { { citizenid, role }, ... }
function M.missionAssignees(mission, members)
    local out, seen = {}, {}
    local function add(cid)
        if type(cid) == 'string' and cid ~= '' and not seen[cid] then
            seen[cid] = true
            out[#out + 1] = cid
        end
    end
    add(mission and mission.lead)
    for _, m in ipairs(members or {}) do add(m.citizenid) end
    return out
end

function M.sourceRecord(s)
    return {
        type = 'intel_source', id = s.id, level = level(s.level), status = status(s.status), unit = s.unit,
        handlerCitizenid = s.handler,
    }
end

function M.missionRecord(m, members)
    return {
        type = 'mission', id = m.id, level = level(m.level), status = status(m.status), unit = m.unit,
        ownerCitizenid = m.lead, assignees = M.missionAssignees(m, members),
    }
end

--- @param r table report { id, level, status, author, missionId }
--- @param mission table|nil the report's mission (when mission-bound)
--- @param members table|nil that mission's members
function M.reportRecord(r, mission, members)
    return {
        type = 'intel_report', id = r.id, level = level(r.level), status = status(r.status),
        ownerCitizenid = r.author,
        unit = mission and mission.unit or nil,
        assignees = mission and M.missionAssignees(mission, members) or {},
    }
end

--- Effective level of a link: max(link level, report level).
function M.linkLevel(link)
    local l = level(link.level)
    if link.report then l = math.max(l, level(link.report.level)) end
    return l
end

--- @param link table store link (rowToLink: report/mission parts joined)
--- @param members table|nil members of link.mission
function M.linkRecord(link, members)
    local assignees = {}
    if type(link.createdBy) == 'string' then assignees[1] = link.createdBy end
    if link.mission then
        for _, cid in ipairs(M.missionAssignees(link.mission, members)) do
            if cid ~= link.createdBy then assignees[#assignees + 1] = cid end
        end
    end
    local report = link.report
    return {
        type = 'intel_report', id = link.id, level = M.linkLevel(link),
        status = report and status(report.status) or 'open',
        ownerCitizenid = report and report.author or link.createdBy,
        unit = link.mission and link.mission.unit or nil,
        assignees = assignees,
    }
end

--- OfficerRef (packages/types/src/mdt.ts) for a citizenid, or nil when there is no fredpd_officers row.
--- @param officers table { [citizenid] = { displayName, callsign, unit } }
function M.officerRef(cid, officers)
    local o = cid and officers and officers[cid]
    if not o or type(o.displayName) ~= 'string' then return nil end
    return { citizenid = cid, displayName = o.displayName, callsign = o.callsign, unit = o.unit }
end

--- Like officerRef, but never nil for a citizenid (mission members: the display name falls back to the citizenid).
function M.memberRef(cid, officers)
    local ref = M.officerRef(cid, officers)
    if ref then return ref end
    return { citizenid = cid, displayName = cid }
end

--- Kontaktnotis: the record exists, contact the owner/lead. Only { displayName, unit } of that officer (§C15);
--- unit = the record's unit, else the officer's primary unit.
function M.notice(cid, officers, unit)
    local o = cid and officers and officers[cid] or nil
    return {
        visibility = 'notice',
        contact = { displayName = o and o.displayName or nil, unit = unit or (o and o.unit) or nil },
    }
end

--- Deduplicate notices by contact (two missions of one lead and unit say nothing more than one).
function M.uniqueNotices(list)
    local out, seen = {}, {}
    for _, n in ipairs(list) do
        local key = tostring(n.contact.displayName) .. '\0' .. tostring(n.contact.unit)
        if not seen[key] then
            seen[key] = true
            out[#out + 1] = n
        end
    end
    return out
end

--- Page `list` (1-based page, size): slice, total.
function M.page(list, page, size)
    local out = {}
    local first = (page - 1) * size + 1
    for i = first, math.min(#list, first + size - 1) do out[#out + 1] = list[i] end
    return out, #list
end

return M
