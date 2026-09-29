-- SPDX-License-Identifier: GPL-3.0-only
-- Masked exports for "Begär ut allmän handling" (task 5.6) and share links (task 5.5).
--
-- Release (IMPLEMENTATION.md §5.3): canView (§C3, shared/canview.lua with the rules from fredpd_visibility_rules) for
-- a public viewer — no character, tier 0, no units, no grants — decides whether a case/report can be released at all
-- (with the default rules: a closed case at level 0 is 'masked', an open one only a kontaktnotis, i.e. withheld).
-- The content then carries only text at level 0 (Standard): the case title/summary when the case is level 0 and the
-- title/body of level-0 reports the public viewer may see. Source fields are never exported: no officers (authors,
-- owner, assignees), no subjects/persons, no charges, no evidence, no intel. Begränsad (1) and Hemlig (2) text cannot
-- reach the export because nothing above level 0 is ever read into it.
-- Share links: the same shape, cut at the link's max_level (its creator's tier when it was made).

local C = require 'server.common'
local Cases = require 'server.cases'
local Reports = require 'server.reports'
local Time = require '@fredpd_core.shared.time'
local CanView = require '@fredpd_core.shared.canview'

local M = {}

M.RULES_SQL = 'SELECT id, record_type, level, record_status, viewer_condition, condition_value, result, priority, '
    .. 'enabled FROM fredpd_visibility_rules WHERE enabled = 1'

M.REPORTS_SQL = 'SELECT id, report_number, title, body, level, author_citizenid, '
    .. Time.isoSelect('created_at', 'createdAt') .. ' FROM fredpd_reports WHERE case_id = ? ORDER BY n'

local rules = nil

--- VisibilityRule list (camelCase, as fredpd_core/server/canview.lua rowToRule), loaded once; reset on
--- fredpd:rulesChanged (server/main.lua).
function M.rules()
    if rules then return rules end
    local rows = MySQL.query.await(M.RULES_SQL)
    if type(rows) ~= 'table' then error('fredpd_visibility_rules query failed', 0) end
    local list = {}
    for i, row in ipairs(rows) do
        list[i] = {
            id = tonumber(row.id) or 0, recordType = row.record_type, level = tonumber(row.level),
            recordStatus = row.record_status, viewerCondition = row.viewer_condition,
            conditionValue = type(row.condition_value) == 'string' and row.condition_value or nil,
            result = row.result, priority = tonumber(row.priority) or 0, enabled = true,
        }
    end
    rules = list
    return rules
end

function M.resetRules() rules = nil end

--- The public viewer of a release decision.
function M.publicViewer()
    return { citizenid = nil, tier = 0, units = {}, grants = { grants = {}, denied = {}, tier = 0, units = {} } }
end

local function visible(v) return v == 'full' or v == 'masked' end

--- Reports of a case (full rows).
local function reportsOf(caseId)
    local rows = MySQL.query.await(M.REPORTS_SQL, { caseId })
    if type(rows) ~= 'table' then error('fredpd_reports query failed', 0) end
    local out = {}
    for _, r in ipairs(rows) do
        local id = C.int(r.id)
        if id then
            out[#out + 1] = { id = id, number = C.str(r.report_number) or '', title = C.str(r.title) or '',
                body = C.str(r.body) or '', level = C.level(r.level), author = C.str(r.author_citizenid),
                createdAt = Time.toIsoUtc(C.str(r.createdAt)) }
        end
    end
    return out
end

--- Case content cut at maxLevel; `keep(report)` filters further. nil when the case itself is above maxLevel.
function M.caseContent(c, maxLevel, keep)
    if c.level > maxLevel then return nil end
    local reports = {}
    for _, r in ipairs(reportsOf(c.id)) do
        if r.level <= maxLevel and (not keep or keep(r)) then
            reports[#reports + 1] = { reportNumber = r.number, title = r.title, body = r.body, createdAt = r.createdAt }
        end
    end
    return { type = 'case', caseNumber = c.caseNumber, status = c.status, title = c.title, summary = c.summary,
        createdAt = c.createdAt, closedAt = c.closedAt, reports = reports }
end

--- Single report content cut at maxLevel (nil when above it).
function M.reportContent(c, r, maxLevel)
    if r.level > maxLevel or c.level > maxLevel then return nil end
    return { type = 'report', caseNumber = c.caseNumber, reportNumber = r.number, title = r.title, body = r.body,
        createdAt = r.createdAt }
end

--- Released content for a public viewer, or nil when nothing may be released. targetType 'case' | 'report'.
function M.release(targetType, targetId)
    local viewer, list = M.publicViewer(), M.rules()
    local id = C.int(targetId)
    if not id then return nil end
    if targetType == 'case' then
        local c = Cases.load(id)
        if not c then return nil end
        if not visible(CanView.evaluate(viewer, Cases.visRecordOf(c), list)) then return nil end
        return M.caseContent(c, 0, function(r)
            return visible(CanView.evaluate(viewer, Cases.reportVisRecord(c, r), list))
        end)
    elseif targetType == 'report' then
        local r = Reports.load(id)
        local c = r and Cases.load(r.caseId) or nil
        if not c then return nil end
        if not visible(CanView.evaluate(viewer, Cases.visRecordOf(c), list)) then return nil end
        if not visible(CanView.evaluate(viewer, Cases.reportVisRecord(c, r), list)) then return nil end
        return M.reportContent(c, r, 0)
    end
    return nil
end

return M
