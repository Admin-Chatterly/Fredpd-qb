-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_intel server logic (IMPLEMENTATION.md §5.8, docs/contracts.md §C15, docs/modules/intel.md).
--
-- Every INTEL_ACTIONS handler (packages/types/src/intel.ts) is an export with the §C12 convention
-- (src, input) -> { ok = true, data } | { ok = false, error }. Order in every handler (§4.6): the src must be a
-- connected player → grant from INTEL_ACTIONS → on duty → input validated again (shared/input.lua; any server
-- resource can call an export) → rate limit (writes, graph) → work. The actor's citizenid always comes from
-- fredpd_core (qbx_core), never from input: a source's handler, a report's author, a mission's lead and a link's
-- creator are the caller.
--
-- Visibility: every record goes through fredpd_core's canView (server/access.lua builds the VisRecords). 'none' is
-- answered not_found exactly like a missing id (no existence leak, §C14/§C15); 'notice' gives only the contact
-- { displayName, unit } of the owner/lead. Reads of a source's real identity are audited intel.source.identity and
-- every read of a Hemlig (level 2) report body is audited intel.report.read (§5.8 acceptance). Every write is
-- audited (§0 rule 5).
--
-- Also exported (IMPLEMENTATION.md §4.3): addSource, addReport, addLink, getGraph(entityId, viewerSrc) and
-- getPersonNotices(src, citizenid) for fredpd_records' person page.

local Input = require 'shared.input'
local Store = require 'server.store'
local Access = require 'server.access'

local M = {}

M.PAGE_SIZE = 50
M.GRAPH_NODE_CAP = 150   -- packages/types/src/intel.ts GRAPH_NODE_CAP
M.GRAPH_LINK_SCAN = 2000 -- links one BFS level considers (newest first); more -> truncated
M.LIST_SCAN = Store.SCAN_CAP

M.GRANT = {
    read = { 'perm', 'intel.read' },
    handler = { 'perm', 'intel.handler' },
    command = { 'perm', 'intel.command' },
    page = { 'mdt_page', 'intel' },
}

-- Per-player cooldowns on top of the fredpd_mdt dispatcher's (§C12 step 4), for exports called directly.
M.cfg = {
    writeCooldownMs = 500,
    graphCooldownMs = 250,
}

function M.configure(cfg)
    for k, v in pairs(cfg or {}) do M.cfg[k] = v end
end

---------------------------------------------------------------------------------------------------------------
-- Small helpers

local function ok(data) return { ok = true, data = data } end
local function fail(code) return { ok = false, error = code } end

function M.log(level, fmt, ...)
    local msg = select('#', ...) > 0 and fmt:format(...) or tostring(fmt)
    local printer = type(lib) == 'table' and type(lib.print) == 'table' and lib.print[level]
    if printer then printer(msg) else print(('[fredpd_intel] %s: %s'):format(level, msg)) end
end

local function core() return exports.fredpd_core end

local function hasGrant(src, grant)
    local okCall, allowed = pcall(function() return core():hasGrant(src, grant[1], grant[2]) end)
    return okCall and allowed == true
end

local function audit(src, action, targetType, id, meta)
    local okCall, err = pcall(function() core():audit(src or 0, action, targetType, id, meta) end)
    if not okCall then M.log('error', 'audit %s failed: %s', action, tostring(err)) end
end

--- canView results for a list of VisRecords (one viewer lookup). A failure fails closed ('none').
local function views(src, records)
    if #records == 0 then return {} end
    local okCall, out = pcall(function() return core():canViewMany(src, records) end)
    if not okCall or type(out) ~= 'table' then
        M.log('error', 'canViewMany failed: %s', tostring(out))
        out = {}
    end
    local res = {}
    for i = 1, #records do res[i] = Access.RANK[out[i]] and out[i] or 'none' end
    return res
end

local lastCall = {} -- [src] = { [bucket] = GetGameTimer() }

local function limited(src, bucket)
    local ms = tonumber(M.cfg[bucket .. 'CooldownMs']) or 0
    if ms <= 0 then return false end
    local now = GetGameTimer()
    local per = lastCall[src]
    if not per then
        per = {}
        lastCall[src] = per
    end
    local last = per[bucket]
    if last and now - last < ms then return true end
    per[bucket] = now
    return false
end

--- playerDropped: forget the player's cooldowns.
function M.forget(src)
    local id = math.tointeger(tonumber(src))
    if id then lastCall[id] = nil end
end

--- The acting officer: a connected player (src >= 1) with `grant` (nil = no grant, only duty), on duty, with a
--- character. Returns { src, citizenid, tier, command } or nil, 'unauthorized'.
function M.actor(src, grant)
    src = math.tointeger(tonumber(src))
    if not src or src < 1 then return nil, 'unauthorized' end
    if grant and not hasGrant(src, grant) then return nil, 'unauthorized' end
    local okDuty, onDuty = pcall(function() return core():isOnDuty(src) end)
    if not okDuty or onDuty ~= true then return nil, 'unauthorized' end
    local okCid, cid = pcall(function() return core():getCitizenId(src) end)
    cid = okCid and Input.citizenId(cid) or nil
    if not cid then return nil, 'unauthorized' end
    local okTier, tier = pcall(function() return core():getTier(src) end)
    tier = okTier and math.tointeger(tonumber(tier)) or 0
    return { src = src, citizenid = cid, tier = tier, command = hasGrant(src, M.GRANT.command) }
end

--- The actor's primary unit (first of getUnits, ordered by fredpd_core), or nil.
local function primaryUnit(src)
    local okCall, units = pcall(function() return core():getUnits(src) end)
    if okCall and type(units) == 'table' then return Input.unitCode(units[1]) end
    return nil
end

--- A record level the actor may set: at most their tier, unless they hold intel.command (as §C14 for cases).
local function levelAllowed(actor, level)
    return actor.command or level <= actor.tier
end

--- Wrap an action: actor (grant + duty) → validate → rate limit → fn(actor, input) under pcall ('unavailable').
local function action(name, grant, bucket, fn)
    local validate = Input.validate[name]
    return function(src, input)
        local actor, err = M.actor(src, grant)
        if not actor then return fail(err) end
        local clean = validate(input)
        if not clean then return fail('validation') end
        if bucket and limited(actor.src, bucket) then return fail('rate_limited') end
        local okRun, result = pcall(fn, actor, clean)
        if not okRun then
            M.log('error', '%s failed: %s', name, tostring(result))
            return fail('unavailable')
        end
        return result
    end
end

local function officersFor(cids)
    return Store.officers(cids)
end

---------------------------------------------------------------------------------------------------------------
-- Visibility of rows (batched)

--- Mission views: missions (list) + members map -> views[]
local function missionViews(src, missions, members)
    local records = {}
    for i, m in ipairs(missions) do records[i] = Access.missionRecord(m, members[m.id]) end
    return views(src, records)
end

--- Report views, capped by the view of the report's mission. `missions` = { [id] = mission }, members by mission.
--- Returns views[], missionView[] (nil for standalone reports).
local function reportViews(src, reports, missions, members)
    local records, index = {}, {}
    for i, r in ipairs(reports) do
        local m = r.missionId and missions[r.missionId] or nil
        records[#records + 1] = Access.reportRecord(r, m, m and members[m.id])
        index[i] = { #records }
        if m then
            records[#records + 1] = Access.missionRecord(m, members[m.id])
            index[i][2] = #records
        end
    end
    local vs = views(src, records)
    local out, mviews = {}, {}
    for i = 1, #reports do
        local v = vs[index[i][1]]
        if index[i][2] then
            mviews[i] = vs[index[i][2]]
            v = Access.min(v, mviews[i])
        end
        out[i] = v
    end
    return out, mviews
end

--- The missions and members behind a set of reports: missions map, members map.
local function reportContext(reports)
    local ids = {}
    for _, r in ipairs(reports) do
        if r.missionId then ids[#ids + 1] = r.missionId end
    end
    local missions = Store.missionsByIds(ids)
    return missions, Store.members(ids)
end

--- Link views (store links with report/mission parts joined): views[] with the mission cap applied.
local function linkViews(src, links)
    local missionIds = {}
    for _, l in ipairs(links) do
        if l.mission then missionIds[#missionIds + 1] = l.mission.id end
    end
    local members = Store.members(missionIds)
    local records, index = {}, {}
    for i, l in ipairs(links) do
        local ms = l.mission and members[l.mission.id] or nil
        records[#records + 1] = Access.linkRecord(l, ms)
        index[i] = { #records }
        if l.mission then
            records[#records + 1] = Access.missionRecord(l.mission, ms)
            index[i][2] = #records
        end
    end
    local vs = views(src, records)
    local out = {}
    for i = 1, #links do
        local v = vs[index[i][1]]
        if index[i][2] then v = Access.min(v, vs[index[i][2]]) end
        out[i] = v
    end
    return out
end

--- Case entities the viewer may not know about: { [entityId] = true } for every 'case' entity in `entities` (a list
--- or an id map) whose fredpd_cases row is gone or whose case view is not visible ('none' or 'notice': a case
--- kontaktnotis never carries the case number, as in fredpd_records' caserefs). Two queries + one canViewMany, and
--- none at all without case entities.
local function hiddenCases(actor, entities)
    local list = {}
    for _, e in pairs(entities) do
        if e and e.type == 'case' then list[#list + 1] = e end
    end
    local hidden = {}
    if #list == 0 then return hidden end
    local numbers = {}
    for i, e in ipairs(list) do numbers[i] = e.ref end
    local cases = Store.casesByNumbers(numbers)
    local records, keys = {}, {}
    for num, c in pairs(cases) do
        records[#records + 1] = Access.caseRecord(c)
        keys[#keys + 1] = num
    end
    local caseView = {}
    for i, v in ipairs(views(actor.src, records)) do caseView[keys[i]] = v end
    for _, e in ipairs(list) do
        if not e.ref or not Access.visible(caseView[e.ref]) then hidden[e.id] = true end
    end
    return hidden
end

--- Links whose other end is a hidden case count as hidden: sets lviews[i] = 'none' in place (one entity query for
--- the ends of the visible links, plus hiddenCases).
local function hideCaseLinks(actor, links, lviews)
    local ends = {}
    for i, l in ipairs(links) do
        if Access.visible(lviews[i]) then
            ends[#ends + 1] = l.fromId
            ends[#ends + 1] = l.toId
        end
    end
    if #ends == 0 then return end
    local hidden = hiddenCases(actor, Store.entitiesByIds(ends))
    if next(hidden) == nil then return end
    for i, l in ipairs(links) do
        if hidden[l.fromId] or hidden[l.toId] then lviews[i] = 'none' end
    end
end

---------------------------------------------------------------------------------------------------------------
-- Wire shapes

local function entityOut(e)
    if not e then return nil end
    return { id = e.id, type = e.type, ref = e.ref, label = e.label }
end

--- LinkSchema. `entities` = { [id] = entity }; masked links carry no creator and no report id.
local function linkOut(l, view, entities, officers)
    local full = view == 'full'
    return {
        id = l.id,
        from = entityOut(entities[l.fromId]),
        to = entityOut(entities[l.toId]),
        type = l.type,
        confidence = l.confidence,
        level = Access.linkLevel(l),
        reportId = full and l.reportId or nil,
        createdBy = full and Access.officerRef(l.createdBy, officers) or nil,
        createdAt = l.createdAt,
    }
end

--- Visible links shaped (entities and officers loaded in one query each). links/linkViews aligned.
local function shapeLinks(links, lviews)
    local shown, ends, cids = {}, {}, {}
    for i, l in ipairs(links) do
        if Access.visible(lviews[i]) then
            shown[#shown + 1] = { link = l, view = lviews[i] }
            ends[#ends + 1] = l.fromId
            ends[#ends + 1] = l.toId
            cids[#cids + 1] = l.createdBy
        end
    end
    if #shown == 0 then return {} end
    local entities = Store.entitiesByIds(ends)
    local officers = officersFor(cids)
    local out = {}
    for i, s in ipairs(shown) do out[i] = linkOut(s.link, s.view, entities, officers) end
    return out
end

local function mayReadIdentity(actor, s)
    return actor.command or (s.handler == actor.citizenid and hasGrant(actor.src, M.GRANT.handler))
end

--- SourceSchema. withIdentity: include realIdentity (only for the handler with intel.handler or intel.command;
--- audited intel.source.identity with `via`).
local function sourceOut(actor, s, view, officers, withIdentity, via)
    if view == 'notice' then return Access.notice(s.handler, officers, s.unit) end
    if view == 'masked' then
        return {
            visibility = 'masked', id = s.id, codename = s.codename, reliability = s.reliability, status = s.status,
            level = s.level,
        }
    end
    local out = {
        visibility = 'full', id = s.id, codename = s.codename, reliability = s.reliability, status = s.status,
        level = s.level, unit = s.unit, notes = s.notes, handler = Access.officerRef(s.handler, officers),
    }
    if withIdentity and s.realCitizenid and mayReadIdentity(actor, s) then
        local names = Store.personNames({ s.realCitizenid })
        local name = names[s.realCitizenid]
        out.realIdentity = { citizenid = s.realCitizenid, name = (name and name ~= '') and name or s.realCitizenid }
        audit(actor.src, 'intel.source.identity', 'intel_source', s.id, { via = via })
    end
    return out
end

--- IntelReportSchema for reports whose views are known. ctx = { missions, members, missionViews = {[id]=view} }.
--- Level-2 bodies are audited intel.report.read (`via` in meta) unless `noReadAudit` (the author's own create).
local function reportsOut(actor, reports, rviews, mviews, missions, via, noReadAudit)
    -- sources (for { id, codename }), officers, links: one query each for the whole batch
    local sourceIds, cids, fullIds = {}, {}, {}
    for i, r in ipairs(reports) do
        local m = r.missionId and missions[r.missionId] or nil
        if rviews[i] == 'notice' then
            cids[#cids + 1] = m and m.lead or r.author
        elseif Access.visible(rviews[i]) then
            cids[#cids + 1] = r.author
            if r.sourceId then sourceIds[#sourceIds + 1] = r.sourceId end
            fullIds[#fullIds + 1] = r.id
        end
    end
    local officers = officersFor(cids)
    local sources = Store.sourcesByIds(sourceIds)
    local sourceList, sourceKeys = {}, {}
    for id, s in pairs(sources) do
        sourceList[#sourceList + 1] = Access.sourceRecord(s)
        sourceKeys[#sourceKeys + 1] = id
    end
    local sviews = {}
    for i, v in ipairs(views(actor.src, sourceList)) do sviews[sourceKeys[i]] = v end
    local links = Store.linksOfReports(fullIds)
    local lviews = linkViews(actor.src, links)
    hideCaseLinks(actor, links, lviews)
    local byReport = {}
    do
        local visibleLinks, visibleViews = {}, {}
        for i, l in ipairs(links) do
            if Access.visible(lviews[i]) then
                visibleLinks[#visibleLinks + 1] = l
                visibleViews[#visibleViews + 1] = lviews[i]
            end
        end
        local shaped = shapeLinks(visibleLinks, visibleViews)
        for i, l in ipairs(visibleLinks) do
            byReport[l.reportId] = byReport[l.reportId] or {}
            table.insert(byReport[l.reportId], shaped[i])
        end
    end

    local out = {}
    for i, r in ipairs(reports) do
        local view = rviews[i]
        local m = r.missionId and missions[r.missionId] or nil
        if view == 'notice' then
            out[i] = m and Access.notice(m.lead, officers, m.unit) or Access.notice(r.author, officers, nil)
        elseif Access.visible(view) then
            local s = r.sourceId and sources[r.sourceId] or nil
            local showSource = s and view == 'full' and Access.visible(sviews[s.id])
            out[i] = {
                visibility = 'full',
                id = r.id,
                source = showSource and { id = s.id, codename = s.codename } or nil,
                mission = (m and mviews[i] == 'full') and { id = m.id, title = m.title } or nil,
                author = Access.officerRef(r.author, officers),
                body = r.body or '',
                reliability = r.reliability,
                level = r.level,
                status = r.status,
                createdAt = r.createdAt,
                links = byReport[r.id] or {},
            }
            if r.level >= 2 and not noReadAudit then
                audit(actor.src, 'intel.report.read', 'intel_report', r.id, { via = via })
            end
        end
    end
    return out
end

--- MissionSchema for missions with known views; members = { [id] = list }.
local function missionsOut(actor, missions, mviews, members)
    local cids, fullIds = {}, {}
    for i, m in ipairs(missions) do
        cids[#cids + 1] = m.lead
        if Access.visible(mviews[i]) then
            fullIds[#fullIds + 1] = m.id
            for _, mem in ipairs(members[m.id] or {}) do cids[#cids + 1] = mem.citizenid end
        end
    end
    local officers = officersFor(cids)
    -- reports of the visible missions (meta only), filtered by the viewer's report view
    local reports = Store.reportsOfMissions(fullIds)
    local byId = {}
    for _, m in ipairs(missions) do byId[m.id] = m end
    local rviews = reportViews(actor.src, reports, byId, members)
    local reportsBy = {}
    for i, r in ipairs(reports) do
        if Access.visible(rviews[i]) then
            reportsBy[r.missionId] = reportsBy[r.missionId] or {}
            table.insert(reportsBy[r.missionId], { id = r.id, level = r.level, createdAt = r.createdAt })
        end
    end
    local out = {}
    for i, m in ipairs(missions) do
        if mviews[i] == 'notice' then
            out[i] = Access.notice(m.lead, officers, m.unit)
        elseif Access.visible(mviews[i]) then
            local list = {}
            for _, mem in ipairs(members[m.id] or {}) do
                local ref = Access.memberRef(mem.citizenid, officers)
                ref.role = mem.role
                list[#list + 1] = ref
            end
            out[i] = {
                visibility = 'full', id = m.id, title = m.title, description = m.description, unit = m.unit,
                status = m.status, level = m.level, lead = Access.officerRef(m.lead, officers), members = list,
                reports = reportsBy[m.id] or {},
            }
        end
    end
    return out
end

--- One mission for `actor`: shaped, view, members. nil when missing.
local function loadMission(actor, id)
    local m = Store.missionById(id)
    if not m then return nil end
    local members = Store.members({ m.id })
    local view = missionViews(actor.src, { m }, members)[1]
    return m, view, members
end

local function missionResult(actor, m, view, members)
    if not Access.RANK[view] or view == 'none' then return fail('not_found') end
    return ok(missionsOut(actor, { m }, { view }, members)[1])
end

---------------------------------------------------------------------------------------------------------------
-- Sources

local function sourceView(actor, s)
    return views(actor.src, { Access.sourceRecord(s) })[1]
end

M.listSources = action('listSources', M.GRANT.read, nil, function(actor, input)
    local rows = Store.sourcesNewest(M.LIST_SCAN)
    local records = {}
    for i, s in ipairs(rows) do records[i] = Access.sourceRecord(s) end
    local vs = views(actor.src, records)
    local visible = {}
    for i, s in ipairs(rows) do
        if vs[i] ~= 'none' then visible[#visible + 1] = { s = s, v = vs[i] } end
    end
    local pageRows, total = Access.page(visible, input.page, M.PAGE_SIZE)
    local cids = {}
    for _, e in ipairs(pageRows) do cids[#cids + 1] = e.s.handler end
    local officers = officersFor(cids)
    local items = {}
    -- Lists never carry a real identity (getSource does, audited): realIdentity stays null here.
    for i, e in ipairs(pageRows) do items[i] = sourceOut(actor, e.s, e.v, officers, false) end
    return ok({ items = items, total = total, page = input.page })
end)

M.getSource = action('getSource', M.GRANT.read, nil, function(actor, input)
    local s = Store.sourceById(input.id)
    if not s then return fail('not_found') end
    local view = sourceView(actor, s)
    if view == 'none' then return fail('not_found') end
    return ok(sourceOut(actor, s, view, officersFor({ s.handler }), true, 'get'))
end)

M.createSource = action('createSource', M.GRANT.handler, 'write', function(actor, input)
    if not levelAllowed(actor, input.level) then return fail('validation') end
    if input.realCitizenid and not Store.personNames({ input.realCitizenid })[input.realCitizenid] then
        return fail('validation')
    end
    local id = Store.insertSource({
        codename = input.codename,
        handler = actor.citizenid, -- never from input
        reliability = input.reliability,
        notes = input.notes,
        realCitizenid = input.realCitizenid,
        level = input.level,
        unit = primaryUnit(actor.src),
    })
    if not id then return fail('validation') end -- codename taken (uq_codename)
    audit(actor.src, 'intel.source.create', 'intel_source', id,
        { codename = input.codename, level = input.level, identity = input.realCitizenid ~= nil })
    local s = Store.sourceById(id)
    return ok(sourceOut(actor, s, sourceView(actor, s), officersFor({ s.handler }), true, 'create'))
end)

M.updateSource = action('updateSource', M.GRANT.handler, 'write', function(actor, input)
    local s = Store.sourceById(input.id)
    if not s then return fail('not_found') end
    local view = sourceView(actor, s)
    if view == 'none' then return fail('not_found') end
    if not (actor.command or s.handler == actor.citizenid) then return fail('unauthorized') end
    local changed = Store.updateSource(s.id, input)
    if changed and #changed > 0 then
        audit(actor.src, 'intel.source.update', 'intel_source', s.id, {
            fields = changed, status = input.status, reliability = input.reliability,
        })
    end
    s = Store.sourceById(s.id)
    return ok(sourceOut(actor, s, sourceView(actor, s), officersFor({ s.handler }), true, 'update'))
end)

---------------------------------------------------------------------------------------------------------------
-- Intel reports

M.listIntelReports = action('listIntelReports', M.GRANT.read, nil, function(actor, input)
    local empty = ok({ items = {}, total = 0, page = input.page })
    -- A filter is itself a question about the filtered record: the source must be visible (full/masked) and the
    -- mission visible, else grouping reports by source (or counting a secret insats's reports) would reveal what
    -- the source/mission views hide. 'none' is not_found; 'notice' an empty page.
    if input.sourceId then
        local s = Store.sourceById(input.sourceId)
        if not s then return fail('not_found') end
        local sview = sourceView(actor, s)
        if sview == 'none' then return fail('not_found') end
        if not Access.visible(sview) then return empty end
    end
    if input.missionId then
        local m, mview = loadMission(actor, input.missionId)
        if not m or mview == 'none' then return fail('not_found') end
        if not Access.visible(mview) then return empty end
    end
    local rows = Store.reportsNewest({ sourceId = input.sourceId, missionId = input.missionId }, M.LIST_SCAN)
    local missions, members = reportContext(rows)
    local rviews, mviews = reportViews(actor.src, rows, missions, members)
    -- Notice-only reports collapse to one entry per contact (a mission's lead + unit, a standalone report's author):
    -- a kontaktnotis says "ask them", never how many reports there are or when they were filed.
    local visible, noticeSeen = {}, {}
    for i, r in ipairs(rows) do
        local v = rviews[i]
        if input.sourceId and v ~= 'full' then
            -- skip: only a full report shows its `source`, so only those may be matched by the source filter
        elseif v == 'notice' then
            local m = r.missionId and missions[r.missionId] or nil
            local key = m and ('m\0' .. tostring(m.lead) .. '\0' .. tostring(m.unit)) or ('a\0' .. tostring(r.author))
            if not noticeSeen[key] then
                noticeSeen[key] = true
                visible[#visible + 1] = i
            end
        elseif v ~= 'none' then
            visible[#visible + 1] = i
        end
    end
    local pageIdx, total = Access.page(visible, input.page, M.PAGE_SIZE)
    -- bodies only for the page (the scan reads metadata)
    local ids = {}
    for k, i in ipairs(pageIdx) do ids[k] = rows[i].id end
    local bodies = Store.reportsByIds(ids)
    local reports, pv, pm = {}, {}, {}
    for k, i in ipairs(pageIdx) do
        reports[k] = bodies[rows[i].id] or rows[i]
        pv[k] = rviews[i]
        pm[k] = mviews[i]
    end
    return ok({ items = reportsOut(actor, reports, pv, pm, missions, 'list'), total = total, page = input.page })
end)

--- One report for the actor: report (with body), view, mission view, missions map, members map; nil when missing.
local function loadReport(actor, id)
    local r = Store.reportById(id)
    if not r then return nil end
    local missions, members = reportContext({ r })
    local vs, mvs = reportViews(actor.src, { r }, missions, members)
    return r, vs[1], mvs[1], missions, members
end

M.getIntelReport = action('getIntelReport', M.GRANT.read, nil, function(actor, input)
    local r, view, mview, missions = loadReport(actor, input.id)
    if not r or view == 'none' then return fail('not_found') end
    return ok(reportsOut(actor, { r }, { view }, { mview }, missions, 'get')[1])
end)

M.createIntelReport = action('createIntelReport', M.GRANT.read, 'write', function(actor, input)
    if not levelAllowed(actor, input.level) then return fail('validation') end
    if input.sourceId then
        local s = Store.sourceById(input.sourceId)
        if not s or sourceView(actor, s) == 'none' then return fail('not_found') end
        -- Only the source's handler (or intel.command) files reports on it.
        if not (actor.command or s.handler == actor.citizenid) then return fail('unauthorized') end
        if s.status ~= 'open' then return fail('validation') end
    end
    if input.missionId then
        local m, mview = loadMission(actor, input.missionId)
        if not m or mview == 'none' then return fail('not_found') end
        if mview ~= 'full' then return fail('unauthorized') end
        if m.status ~= 'open' then return fail('validation') end
    end
    local id = Store.insertReport({
        sourceId = input.sourceId, missionId = input.missionId, author = actor.citizenid, body = input.body,
        reliability = input.reliability, level = input.level,
    })
    audit(actor.src, 'intel.report.create', 'intel_report', id,
        { level = input.level, sourceId = input.sourceId, missionId = input.missionId })
    local r, view, mview, missions = loadReport(actor, id)
    return ok(reportsOut(actor, { r }, { view }, { mview }, missions, 'create', true)[1])
end)

---------------------------------------------------------------------------------------------------------------
-- Entities

local function truncate(s, max)
    if utf8.len(s) and utf8.len(s) > max then return s:sub(1, (utf8.offset(s, max + 1) or (#s + 1)) - 1) end
    return s
end

--- For a keyed entity (person, vehicle, case): the normalised ref and the server-derived label, or nil and an
--- error code ('validation' = malformed ref, 'not_found' = no such record).
function M.keyedRef(actor, entityType, ref)
    local norm = Input.entityRef(entityType, ref)
    if not norm then return nil, nil, 'validation' end
    if entityType == 'person' then
        local name = Store.personNames({ norm })[norm]
        if not name then return nil, nil, 'not_found' end
        return norm, truncate(name ~= '' and name or norm, 128)
    elseif entityType == 'vehicle' then
        local v = Store.vehicle(norm)
        if not v then return nil, nil, 'not_found' end
        return v.plate, truncate(v.model and (v.plate .. ' (' .. v.model .. ')') or v.plate, 128)
    end
    -- case: must exist and be visible (full/masked) to the actor; a 'notice' view answers not_found exactly like a
    -- missing case, so a case number cannot be probed (label = case number only, never the title)
    local c = Store.caseByNumber(norm)
    if not c then return nil, nil, 'not_found' end
    local view = views(actor.src, { Access.caseRecord(c) })[1]
    if not Access.visible(view) then return nil, nil, 'not_found' end
    return c.caseNumber, c.caseNumber
end

--- Find or create the entity for a validated EnsureEntityInput. Returns entity or nil, error code.
function M.resolveEntity(actor, spec)
    local ref, label = spec.ref, spec.label
    if Input.KEYED[spec.type] then
        local err
        ref, label, err = M.keyedRef(actor, spec.type, spec.ref)
        if not ref then return nil, err end
    end
    local e, created = Store.ensureEntity(spec.type, ref, label, actor.citizenid)
    if not e then return nil, 'unavailable' end
    if created then
        audit(actor.src, 'intel.entity.create', 'intel_entity', e.id, { type = e.type, ref = e.ref })
    elseif Input.KEYED[spec.type] then
        if e.label ~= label then
            if Store.relabel(e.id, label) then
                audit(actor.src, 'intel.entity.relabel', 'intel_entity', e.id, { from = e.label, to = label })
            end
            e.label = label
        end
        -- ensuring an existing person/vehicle is a lookup by citizenid/plate returning the name/model (§4.5)
        if e.type == 'person' or e.type == 'vehicle' then
            audit(actor.src, 'intel.entity.view', 'intel_entity', e.id, { type = e.type, ref = e.ref, via = 'ensure' })
        end
    end
    return e
end

M.searchEntities = action('searchEntities', M.GRANT.page, nil, function(actor, input)
    -- over-fetch so hidden case entities (case view 'none') do not shrink the page much
    local rows = Store.searchEntities(Input.likePrefix(input.query), input.type, Store.SEARCH_LIMIT * 2)
    local hidden = hiddenCases(actor, rows)
    local items, looked = {}, {}
    for _, e in ipairs(rows) do
        if #items >= Store.SEARCH_LIMIT then break end
        if not hidden[e.id] then
            items[#items + 1] = entityOut(e)
            if e.type == 'person' or e.type == 'vehicle' then looked[#looked + 1] = e.id end
        end
    end
    -- a name/plate prefix returning citizenids/plates is a person/vehicle lookup (§4.5): one audit row per call
    if #looked > 0 then
        audit(actor.src, 'intel.entity.search', 'intel_entity', nil,
            { query = input.query, type = input.type, entityIds = looked })
    end
    return ok({ items = items })
end)

M.ensureEntity = action('ensureEntity', M.GRANT.read, 'write', function(actor, input)
    local e, err = M.resolveEntity(actor, input)
    if not e then return fail(err) end
    return ok(entityOut(e))
end)

--- Kontaktnotiser for an entity: missions touching it (link -> report -> mission) and standalone reports touching
--- it that the viewer only sees as 'notice'. Deduplicated by contact.
local function entityNotices(actor, entityId)
    local missions = Store.missionsTouching(entityId, Store.NOTICE_CAP)
    local mids = {}
    for i, m in ipairs(missions) do mids[i] = m.id end
    local members = Store.members(mids)
    local mv = missionViews(actor.src, missions, members)
    local reports = Store.standaloneReportsTouching(entityId, Store.NOTICE_CAP)
    local rv = reportViews(actor.src, reports, {}, {})
    local cids, pending = {}, {}
    for i, m in ipairs(missions) do
        if mv[i] == 'notice' then
            cids[#cids + 1] = m.lead
            pending[#pending + 1] = { cid = m.lead, unit = m.unit }
        end
    end
    for i, r in ipairs(reports) do
        if rv[i] == 'notice' then
            cids[#cids + 1] = r.author
            pending[#pending + 1] = { cid = r.author }
        end
    end
    if #pending == 0 then return {} end
    local officers = officersFor(cids)
    local out = {}
    for i, p in ipairs(pending) do out[i] = Access.notice(p.cid, officers, p.unit) end
    return Access.uniqueNotices(out)
end

M.getEntity = action('getEntity', M.GRANT.page, nil, function(actor, input)
    local e = Store.entityById(input.id)
    if not e or hiddenCases(actor, { e })[e.id] then return fail('not_found') end
    local links, capped = Store.linksTouching({ e.id }, Store.SCAN_CAP)
    local lviews = linkViews(actor.src, links)
    hideCaseLinks(actor, links, lviews)
    local shown = shapeLinks(links, lviews)
    local total = capped and Store.countLinksTouching(e.id) or #links
    -- Reports behind the VISIBLE links only: a hidden link must not be tied to a report (hiddenLinks is a bare
    -- count). Each report is then listed when the viewer may read it.
    local reports, seen = {}, {}
    for i, l in ipairs(links) do
        if Access.visible(lviews[i]) and l.report and not seen[l.report.id] then
            seen[l.report.id] = true
            reports[#reports + 1] = l.report
        end
    end
    local missions, members = reportContext(reports)
    local rviews = reportViews(actor.src, reports, missions, members)
    local visibleReports, cids = {}, {}
    for i, r in ipairs(reports) do
        if Access.visible(rviews[i]) then
            visibleReports[#visibleReports + 1] = r
            cids[#cids + 1] = r.author
        end
    end
    local officers = officersFor(cids)
    local reportItems = {}
    for i, r in ipairs(visibleReports) do
        reportItems[i] = { id = r.id, level = r.level, createdAt = r.createdAt,
            author = Access.officerRef(r.author, officers) }
    end
    if e.type == 'person' or e.type == 'vehicle' then
        audit(actor.src, 'intel.entity.view', 'intel_entity', e.id, { type = e.type, ref = e.ref })
    end
    return ok({
        entity = entityOut(e),
        links = shown,
        hiddenLinks = math.max(0, total - #shown),
        reports = reportItems,
        notices = entityNotices(actor, e.id),
    })
end)

--- For fredpd_records' person page: kontaktnotiser for missions / intel touching `citizenid` that src sees only as
--- 'notice'. Needs an on-duty officer (no intel grant: that is the point of a kontaktnotis). Returns an array (empty
--- on any error, unknown person or nothing to report).
function M.getPersonNotices(src, citizenid)
    local actor = M.actor(src, nil)
    local cid = Input.citizenId(citizenid)
    if not actor or not cid then return {} end
    local okRun, result = pcall(function()
        local e = Store.findEntity('person', cid)
        if not e then return {} end
        return entityNotices(actor, e.id)
    end)
    if not okRun then
        M.log('error', 'getPersonNotices failed: %s', tostring(result))
        return {}
    end
    return result
end

M.addLink = action('addLink', M.GRANT.read, 'write', function(actor, input)
    if not levelAllowed(actor, input.level) then return fail('validation') end
    -- Read-only checks first: nothing (not even a new 'to' entity) is written by a call that ends in an error.
    local from = Store.entityById(input.fromId)
    -- A hidden 'from' answers exactly like a missing one, before 'to' is even looked at: no later check
    -- (e.g. keyedRef's 'validation' for a malformed 'to') can reveal that the id exists.
    if not from or hiddenCases(actor, { from })[from.id] then return fail('not_found') end
    local to
    if input.to.id then
        to = Store.entityById(input.to.id)
        if not to or hiddenCases(actor, { to })[to.id] then return fail('not_found') end
    else
        local ref, label = input.to.ref, input.to.label
        if Input.KEYED[input.to.type] then
            local err
            ref, label, err = M.keyedRef(actor, input.to.type, input.to.ref)
            if not ref then return fail(err) end
        end
        to = Store.findEntity(input.to.type, ref, label) -- nil: created below, once every check has passed
    end
    local hidden = hiddenCases(actor, { from, to })
    if hidden[from.id] or (to and hidden[to.id]) then return fail('not_found') end
    if to and from.id == to.id then return fail('validation') end
    -- The would-be link, decided before anything is written: a call that ends 'unauthorized' writes nothing.
    local candidate = { createdBy = actor.citizenid, level = input.level }
    if input.reportId then
        local r, view, _, missions = loadReport(actor, input.reportId)
        if not r or view == 'none' then return fail('not_found') end
        if not Access.visible(view) then return fail('unauthorized') end
        candidate.report = { id = r.id, author = r.author, level = r.level, status = r.status,
            missionId = r.missionId, sourceId = r.sourceId }
        local m = r.missionId and missions[r.missionId] or nil
        if m then
            candidate.mission = { id = m.id, title = m.title, level = m.level, status = m.status, unit = m.unit,
                lead = m.lead }
        end
    end
    if not Access.visible(linkViews(actor.src, { candidate })[1]) then return fail('unauthorized') end
    if not to then
        local err
        to, err = M.resolveEntity(actor, input.to)
        if not to then return fail(err) end
        if from.id == to.id then return fail('validation') end
    end
    -- An identical stored link comes back when the actor may see it; otherwise the actor's own one is stored.
    local existing = Store.findSameLink(from.id, to.id, input.type, input.reportId)
    if existing then
        local link = Store.linkById(existing)
        local view = link and linkViews(actor.src, { link })[1]
        if link and Access.visible(view) then return ok(shapeLinks({ link }, { view })[1]) end
    end
    local id = Store.insertLink({
        fromId = from.id, toId = to.id, type = input.type, confidence = input.confidence,
        reportId = input.reportId, createdBy = actor.citizenid, level = input.level,
    })
    audit(actor.src, 'intel.link.create', 'intel_link', id, {
        fromId = from.id, toId = to.id, type = input.type, level = input.level, reportId = input.reportId,
    })
    local link = Store.linkById(id)
    local view = linkViews(actor.src, { link })[1]
    -- The candidate check above makes this 'visible'; masked is the floor (full/masked are both shown).
    if not Access.visible(view) then view = 'masked' end
    return ok(shapeLinks({ link }, { view })[1])
end)

---------------------------------------------------------------------------------------------------------------
-- Graph

--- BFS from the root over the links the viewer may see, to `depth` (1 or 2), at most GRAPH_NODE_CAP nodes. Per
--- level: one link query for the whole frontier (+ one members query for the canView records, one canViewMany) and
--- one entity query for the new ends (case entities the viewer may not know about, case view 'none', are dropped
--- with their links: + two case queries and one canViewMany, only when case entities are reached). Newest links
--- first, so the cap keeps the most recent neighbours. nil when the root is missing or a hidden case.
function M.buildGraph(actor, rootId, depth)
    local root = Store.entityById(rootId)
    if not root or hiddenCases(actor, { root })[root.id] then return nil end
    local entities = { [root.id] = root }
    local inGraph, order = { [root.id] = true }, { root.id }
    local edges, edgeSeen = {}, {}
    local truncated = false
    local frontier = { root.id }
    for _ = 1, depth do
        if #frontier == 0 then break end
        local links, capped = Store.linksTouching(frontier, M.GRAPH_LINK_SCAN)
        if capped then truncated = true end
        local lviews = linkViews(actor.src, links)
        -- entities of the new ends (one query), minus hidden cases
        local newIds = {}
        for i, l in ipairs(links) do
            if Access.visible(lviews[i]) then
                if not entities[l.fromId] then newIds[#newIds + 1] = l.fromId end
                if not entities[l.toId] then newIds[#newIds + 1] = l.toId end
            end
        end
        local loaded = Store.entitiesByIds(newIds)
        local hidden = hiddenCases(actor, loaded)
        for id, e in pairs(loaded) do
            if not hidden[id] then entities[id] = e end
        end
        local nextFrontier = {}
        for i, l in ipairs(links) do
            if Access.visible(lviews[i]) and not edgeSeen[l.id] and entities[l.fromId] and entities[l.toId] then
                for _, id in ipairs({ l.fromId, l.toId }) do
                    if not inGraph[id] then
                        if #order < M.GRAPH_NODE_CAP then
                            inGraph[id] = true
                            order[#order + 1] = id
                            nextFrontier[#nextFrontier + 1] = id
                        else
                            truncated = true
                        end
                    end
                end
                if inGraph[l.fromId] and inGraph[l.toId] then
                    edgeSeen[l.id] = true
                    edges[#edges + 1] = { id = l.id, from = l.fromId, to = l.toId, type = l.type,
                        confidence = l.confidence }
                end
            end
        end
        frontier = nextFrontier
    end
    local nodes = {}
    for _, id in ipairs(order) do
        local e = entities[id]
        nodes[#nodes + 1] = { id = e.id, type = e.type, ref = e.ref, label = e.label, root = e.id == root.id }
    end
    return { nodes = nodes, edges = edges, truncated = truncated }
end

local getGraphAction = action('getGraph', M.GRANT.read, 'graph', function(actor, input)
    local graph = M.buildGraph(actor, input.entityId, input.depth)
    if not graph then return fail('not_found') end
    return ok(graph)
end)

--- getGraph(src, { entityId, depth }) (§C12), or the §4.3 form getGraph(entityId, viewerSrc) (depth 1).
function M.getGraph(a, b)
    if type(b) ~= 'table' and b ~= nil and type(a) == 'number' then
        return getGraphAction(b, { entityId = a, depth = 1 })
    end
    return getGraphAction(a, b)
end

---------------------------------------------------------------------------------------------------------------
-- Missions

M.listMissions = action('listMissions', M.GRANT.page, nil, function(actor, input)
    local rows = Store.missionsNewest(M.LIST_SCAN)
    local ids = {}
    for i, m in ipairs(rows) do ids[i] = m.id end
    local members = Store.members(ids)
    local mv = missionViews(actor.src, rows, members)
    local visible = {}
    for i, m in ipairs(rows) do
        if mv[i] ~= 'none' then visible[#visible + 1] = { m = m, v = mv[i] } end
    end
    local pageRows, total = Access.page(visible, input.page, M.PAGE_SIZE)
    local ms, vs = {}, {}
    for i, e in ipairs(pageRows) do
        ms[i] = e.m
        vs[i] = e.v
    end
    return ok({ items = missionsOut(actor, ms, vs, members), total = total, page = input.page })
end)

M.getMission = action('getMission', M.GRANT.page, nil, function(actor, input)
    local m, view, members = loadMission(actor, input.id)
    if not m then return fail('not_found') end
    return missionResult(actor, m, view, members)
end)

M.createMission = action('createMission', M.GRANT.command, 'write', function(actor, input)
    if not levelAllowed(actor, input.level) then return fail('validation') end
    local unit = input.unit or primaryUnit(actor.src)
    local id = Store.insertMission({
        title = input.title, description = input.description, unit = unit, level = input.level,
        lead = actor.citizenid, -- never from input
    })
    audit(actor.src, 'mission.create', 'mission', id, { title = input.title, level = input.level, unit = unit })
    local m, view, members = loadMission(actor, id)
    return missionResult(actor, m, view, members)
end)

--- Mission write guard: exists and visible (else not_found), lead or intel.command (else unauthorized).
local function missionForWrite(actor, id)
    local m, view, members = loadMission(actor, id)
    if not m or view == 'none' then return nil, 'not_found' end
    if not (actor.command or m.lead == actor.citizenid) then return nil, 'unauthorized' end
    return m, view, members
end

M.addMissionMember = action('addMissionMember', M.GRANT.read, 'write', function(actor, input)
    local m, err = missionForWrite(actor, input.id)
    if not m then return fail(err) end
    if m.status ~= 'open' then return fail('validation') end
    if not Store.officerExists(input.citizenid) then return fail('validation') end
    local result = Store.addMember(m.id, input.citizenid, input.role, actor.citizenid)
    if result == 'added' then
        audit(actor.src, 'mission.member.add', 'mission', m.id, { citizenid = input.citizenid, role = input.role })
    elseif result == 'role' then
        audit(actor.src, 'mission.member.role', 'mission', m.id, { citizenid = input.citizenid, role = input.role })
    end
    local view, members
    m, view, members = loadMission(actor, m.id)
    return missionResult(actor, m, view, members)
end)

M.closeMission = action('closeMission', M.GRANT.read, 'write', function(actor, input)
    local m, err = missionForWrite(actor, input.id)
    if not m then return fail(err) end
    if Store.closeMission(m.id) then
        audit(actor.src, 'mission.close', 'mission', m.id, { title = m.title })
    end
    local view, members
    m, view, members = loadMission(actor, m.id)
    return missionResult(actor, m, view, members)
end)

---------------------------------------------------------------------------------------------------------------

--- INTEL_ACTIONS export table (name -> handler).
M.ACTIONS = {
    listSources = M.listSources,
    getSource = M.getSource,
    createSource = M.createSource,
    updateSource = M.updateSource,
    listIntelReports = M.listIntelReports,
    getIntelReport = M.getIntelReport,
    createIntelReport = M.createIntelReport,
    searchEntities = M.searchEntities,
    ensureEntity = M.ensureEntity,
    getEntity = M.getEntity,
    addLink = M.addLink,
    getGraph = M.getGraph,
    listMissions = M.listMissions,
    getMission = M.getMission,
    createMission = M.createMission,
    addMissionMember = M.addMissionMember,
    closeMission = M.closeMission,
}

return M
