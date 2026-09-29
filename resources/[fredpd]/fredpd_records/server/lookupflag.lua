-- SPDX-License-Identifier: GPL-3.0-only
-- Obehörig sökning (task 5.6; IMPLEMENTATION.md §4.5, §8.9). No timers: evaluated on each person lookup
-- (getPersonSummary, after its lookup.person audit).
--
-- Count = distinct persons the officer looked up (lookup.person audit rows) within the window that have no link to
-- the officer — i.e. the person is not a subject of any case the officer owns or is assigned to — plus the person of
-- the current lookup when it is unlinked. Distinct persons (not rows) because the audit insert of the current lookup
-- is asynchronous (fredpd_core Audit.write), so the current row may or may not be in the table yet; a set makes the
-- result the same either way. When the count reaches config/integrations.json unauthorizedLookupThreshold (default 3;
-- window unauthorizedLookupWindowMinutes, default 60) the officer is flagged once per window: audit 'lookup.flag'
-- (target 'officer', meta { count, windowMinutes, persons }), a 'ledning'-topic push { type = 'lookupFlag', officer, count } to open
-- tablets holding perm records.admin, and a notification to on-duty records.admin players (Ledning).

local C = require 'server.common'
local Refs = require 'server.caserefs'

local M = {}

M.DEFAULT_THRESHOLD = 3
M.DEFAULT_WINDOW_MINUTES = 60
M.MAX_PERSONS = 200

M.LINK_SQL = "SELECT 1 FROM fredpd_case_subjects s JOIN fredpd_cases c ON c.id = s.case_id WHERE s.subject_type = 'person' "
    .. 'AND s.subject_id = ? AND (c.owner_citizenid = ? OR EXISTS (SELECT 1 FROM fredpd_case_assignees ca '
    .. 'WHERE ca.case_id = c.id AND ca.citizenid = ?)) LIMIT 1'

M.RECENT_SQL = "SELECT DISTINCT a.target_id FROM fredpd_audit a WHERE a.actor_citizenid = ? AND a.action = 'lookup.person' "
    .. "AND a.target_type = 'person' AND a.created_at >= UTC_TIMESTAMP() - INTERVAL ? MINUTE AND NOT EXISTS ("
    .. "SELECT 1 FROM fredpd_case_subjects s JOIN fredpd_cases c ON c.id = s.case_id WHERE s.subject_type = 'person' "
    .. 'AND s.subject_id = a.target_id AND (c.owner_citizenid = ? OR EXISTS (SELECT 1 FROM fredpd_case_assignees ca '
    .. 'WHERE ca.case_id = c.id AND ca.citizenid = ?))) LIMIT ' .. ('%d'):format(M.MAX_PERSONS)

local lastFlag = {} -- [officer citizenid] = os.time() of the last flag (memory; one flag per window)

function M.reset() lastFlag = {} end

--- Threshold and window from config/integrations.json (integers >= 1, else the defaults).
function M.settings()
    local cfg = C.integrations()
    local threshold = C.int(cfg.unauthorizedLookupThreshold)
    local window = C.int(cfg.unauthorizedLookupWindowMinutes)
    return (threshold and threshold >= 1) and threshold or M.DEFAULT_THRESHOLD,
        (window and window >= 1 and window <= 10080) and window or M.DEFAULT_WINDOW_MINUTES
end

--- Is `citizenid` linked to the officer (subject of a case the officer owns or is assigned to)?
function M.linked(officer, citizenid)
    return MySQL.scalar.await(M.LINK_SQL, { citizenid, officer, officer }) ~= nil
end

--- Notify Ledning (on-duty players with perm records.admin) and push to their open tablets.
local function tellLedning(officer, count)
    local name = Refs.officers({ officer })[officer]
    local label = name and name.displayName or officer
    C.push(C.TOPIC_LEDNING, { type = 'lookupFlag', officer = officer, count = count }, function(target)
        return C.perm(target, 'records.admin')
    end)
    local players = type(GetPlayers) == 'function' and GetPlayers() or {}
    for _, p in ipairs(players) do
        local target = C.playerSrc(p)
        if target and C.perm(target, 'records.admin') and C.onDuty(target) then
            C.notify(target, 'warning', 'audit.flag.unauthorizedSearchNotify', { officer = label, count = count })
        end
    end
end

--- Evaluate after a person lookup by src (actor citizenid `officer`) of `citizenid`. Returns the count and whether it
--- flagged (for tests); never raises into the caller's result (the caller pcalls it).
function M.evaluate(src, officer, citizenid)
    if not officer or not citizenid then return 0, false end
    local threshold, window = M.settings()
    local persons, set = {}, {}
    local rows = MySQL.query.await(M.RECENT_SQL, { officer, window, officer, officer })
    if type(rows) ~= 'table' then error('lookup flag query failed', 0) end
    for _, row in ipairs(rows) do
        local cid = C.str(row.target_id)
        if cid and not set[cid] then
            set[cid] = true
            persons[#persons + 1] = cid
        end
    end
    if not set[citizenid] and not M.linked(officer, citizenid) then
        set[citizenid] = true
        persons[#persons + 1] = citizenid
    end
    local count = #persons
    if count < threshold then return count, false end
    local now = os.time()
    if lastFlag[officer] and now - lastFlag[officer] < window * 60 then return count, false end
    lastFlag[officer] = now
    table.sort(persons)
    local listed = {}
    for i = 1, math.min(#persons, 20) do listed[i] = persons[i] end
    C.auditWrite(src, 'lookup.flag', 'officer', officer, { label = ('%d'):format(count), count = count,
        windowMinutes = window, threshold = threshold, persons = listed })
    tellLedning(officer, count)
    return count, true
end

return M
