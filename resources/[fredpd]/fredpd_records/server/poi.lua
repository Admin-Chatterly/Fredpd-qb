-- SPDX-License-Identifier: GPL-3.0-only
-- POI sheet (task 5.5 server; IMPLEMENTATION.md §5.3, fredpd_poi in 003_records.sql). One sheet per person (the
-- oldest row wins if more exist). Exports: getPoi(src, { citizenid }), updatePoi(src, PoiUpdateInput).
-- Shapes (no TS schema yet; proposed in docs/modules/records.md "POI"):
--   PoiView  = { citizenid, name, poi: PoiSheet | null }
--   PoiSheet = { visibility: 'full' | 'masked', id, level, status, unit, owner: OfficerRef|null, summary|null,
--                warnings: string[], photoUrl|null, updatedAt, updatedBy: OfficerRef|null, editable }
--            | { visibility: 'notice', contact: { displayName, unit } }
-- canView record type 'poi' (§C3; default rules: records.admin/owner/unit/tier_gte full, else kontaktnotis).
-- Edit: canView full and (owner, a member of the sheet's unit or records.admin), level <= tier; lowering needs
-- records.admin. The first update creates the sheet (owner = actor, unit = actor's primary unit).

local C = require 'server.common'
local Refs = require 'server.caserefs'
local Cases = require 'server.cases'
local Time = require '@fredpd_core.shared.time'

local M = {}

M.WARNINGS = { 'armed', 'violent', 'flight_risk', 'gang' }
M.MAX_WARNINGS = 8
M.SUMMARY_MAX = 20000

M.POI_SQL = 'SELECT id, citizenid, level, status, unit, owner_citizenid, summary, warnings, photo_url, updated_by, '
    .. Time.isoSelect('updated_at', 'updatedAt') .. ' FROM fredpd_poi WHERE citizenid = ? ORDER BY id LIMIT 1'

local function decodeWarnings(v)
    local list = v
    if type(v) == 'string' then
        local ok, decoded = pcall(json.decode, v)
        list = ok and decoded or nil
    end
    local out = {}
    if type(list) ~= 'table' then return out end
    for _, w in ipairs(list) do
        if C.enum(w, M.WARNINGS, nil) then out[#out + 1] = w end
    end
    return out
end

--- fredpd_poi row -> table, or nil.
function M.load(citizenid)
    local row = MySQL.single.await(M.POI_SQL, { citizenid })
    if not row or not C.int(row.id) then return nil end
    return {
        id = C.int(row.id), citizenid = C.str(row.citizenid), level = C.level(row.level),
        status = row.status == 'closed' and 'closed' or 'open', unit = C.str(row.unit), owner = C.str(row.owner_citizenid),
        summary = C.str(row.summary), warnings = decodeWarnings(row.warnings), photoUrl = C.str(row.photo_url),
        updatedBy = C.str(row.updated_by), updatedAt = Time.toIsoUtc(C.str(row.updatedAt)),
    }
end

function M.visRecord(p)
    return { type = 'poi', id = p.id, level = p.level, status = p.status, unit = p.unit, assignees = {},
        ownerCitizenid = p.owner }
end

function M.visibility(src, p)
    return Cases.canViewMany(src, { M.visRecord(p) })[1] or 'none'
end

--- May src edit this sheet (given its visibility)?
function M.editable(src, cid, p, vis, tier)
    if vis ~= 'full' or p.level > tier then return false end
    if p.owner == cid or C.perm(src, 'records.admin') then return true end
    for _, u in ipairs(C.units(src)) do if p.unit and u == p.unit then return true end end
    return false
end

--- PoiSheet for a viewer (nil for 'none').
function M.sheet(src, cid, p, vis)
    local officers = Refs.officers({ p.owner, p.updatedBy })
    if vis == 'notice' then
        local o = p.owner and officers[p.owner] or nil
        return { visibility = 'notice', contact = { displayName = o and o.displayName or nil, unit = (o and o.unit) or p.unit } }
    end
    if vis ~= 'full' and vis ~= 'masked' then return nil end
    local tier = C.tier(src)
    local content = vis == 'full' or p.level <= tier
    return {
        visibility = vis, id = p.id, level = p.level, status = p.status, unit = p.unit,
        owner = Cases.officerRef(p.owner, officers, false),
        summary = content and p.summary or nil,
        warnings = content and p.warnings or {},
        photoUrl = content and p.photoUrl or nil,
        updatedAt = p.updatedAt, updatedBy = Cases.officerRef(p.updatedBy, officers, false),
        editable = M.editable(src, cid, p, vis, tier),
    }
end

local function personOf(citizenid)
    return MySQL.single.await('SELECT citizenid, firstname, lastname FROM fredpd_persons WHERE citizenid = ?', { citizenid })
end

--- export getPoi(src, { citizenid }) -> PoiView
function M.getPoi(src, input)
    local actor
    src, actor = C.gate(src, 'mdt_page', 'search')
    if not src then return actor end
    local cid = type(input) == 'table' and C.citizenid(input.citizenid) or nil
    if not cid then return C.fail('validation') end
    local person = personOf(cid)
    if not person then return C.fail('not_found') end
    local p = M.load(cid)
    local sheet = nil
    if p then sheet = M.sheet(src, actor, p, M.visibility(src, p)) end
    return C.ok({ citizenid = cid, name = C.fullName(person.firstname, person.lastname) or cid, poi = sheet })
end

--- Validate the warnings list (known keys, deduplicated, at most MAX_WARNINGS). nil = invalid.
function M.warningsInput(v)
    if type(v) ~= 'table' then return nil end
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    if n ~= #v or n > M.MAX_WARNINGS then return nil end
    local out, seen = {}, {}
    for _, w in ipairs(v) do
        if not C.enum(w, M.WARNINGS, nil) then return nil end
        if not seen[w] then
            seen[w] = true
            out[#out + 1] = w
        end
    end
    return out
end

--- photo URL: https URL or a service upload path, <= 255 characters, no spaces/quotes. nil = invalid.
function M.photoInput(v)
    if type(v) ~= 'string' or #v > 255 then return nil end
    if v == '' then return '' end
    if v:match('^https://[%w%.%-]+[%w%./_%-%%%?=&]*$') or v:match('^/uploads/[%w%-_%.]+$') then return v end
    return nil
end

--- export updatePoi(src, { citizenid, summary?, warnings?, level?, status?, photoUrl? }) -> PoiView
function M.updatePoi(src, input)
    local actor
    src, actor = C.gate(src, 'mdt_page', 'search')
    if not src then return actor end
    if type(input) ~= 'table' then return C.fail('validation') end
    local cid = C.citizenid(input.citizenid)
    local summary = nil
    if input.summary ~= nil then
        summary = type(input.summary) == 'string' and C.body(C.trim(input.summary), M.SUMMARY_MAX, true) or nil
        if summary == nil then return C.fail('validation') end
    end
    local warnings = input.warnings ~= nil and M.warningsInput(input.warnings) or nil
    local level = C.optLevel(input.level, nil)
    local status = C.enum(input.status, { 'open', 'closed' }, nil)
    local photo = input.photoUrl ~= nil and M.photoInput(input.photoUrl) or nil
    if not cid or (input.warnings ~= nil and not warnings) or level == false or status == false
        or (input.photoUrl ~= nil and not photo) then
        return C.fail('validation')
    end
    if not personOf(cid) then return C.fail('not_found') end
    local tier = C.tier(src)
    local p = M.load(cid)

    if not p then
        level = level or 0
        if level > tier then return C.failWith('unauthorized', 'level_above_tier') end
        local unit = C.units(src)[1]
        local params = { cid, level, status or 'open' }
        local sql = 'INSERT INTO fredpd_poi (citizenid, level, status, unit, owner_citizenid, summary, warnings, photo_url, '
            .. 'updated_by, updated_at) VALUES (?, ?, ?, ' .. Cases.opt(unit, params) .. ', ?, '
        params[#params + 1] = actor
        sql = sql .. Cases.opt(summary ~= '' and summary or nil, params) .. ', ' .. Cases.opt(json.encode(warnings or {}), params)
            .. ', ' .. Cases.opt(photo ~= '' and photo or nil, params) .. ', ?, UTC_TIMESTAMP())'
        params[#params + 1] = actor
        local id = C.int(MySQL.insert.await(sql, params))
        if not id then error('fredpd_poi insert failed', 0) end
        C.auditWrite(src, 'poi.create', 'poi', id, { label = cid, level = level })
        return M.getPoi(src, { citizenid = cid })
    end

    local vis = M.visibility(src, p)
    if vis == 'none' then return C.fail('not_found') end
    if not M.editable(src, actor, p, vis, tier) then return C.fail('unauthorized') end
    if level ~= nil and level ~= p.level then
        if level > tier then return C.failWith('unauthorized', 'level_above_tier') end
        if level < p.level and not C.perm(src, 'records.admin') then return C.failWith('unauthorized', 'lowering_needs_admin') end
    end
    local sets, params, changed = {}, {}, {}
    if summary ~= nil then sets[#sets + 1] = 'summary = ' .. Cases.opt(summary ~= '' and summary or nil, params); changed[#changed + 1] = 'summary' end
    if warnings then sets[#sets + 1] = 'warnings = ?'; params[#params + 1] = json.encode(warnings); changed[#changed + 1] = 'warnings' end
    if level ~= nil then sets[#sets + 1] = 'level = ?'; params[#params + 1] = level; changed[#changed + 1] = 'level' end
    if status then sets[#sets + 1] = 'status = ?'; params[#params + 1] = status; changed[#changed + 1] = 'status' end
    if photo ~= nil then sets[#sets + 1] = 'photo_url = ' .. Cases.opt(photo ~= '' and photo or nil, params); changed[#changed + 1] = 'photo' end
    if #sets == 0 then return M.getPoi(src, { citizenid = cid }) end
    params[#params + 1] = actor
    params[#params + 1] = p.id
    MySQL.update.await('UPDATE fredpd_poi SET ' .. table.concat(sets, ', ') .. ', updated_by = ?, updated_at = UTC_TIMESTAMP() '
        .. 'WHERE id = ?', params)
    C.auditWrite(src, 'poi.update', 'poi', p.id, { label = cid, changed = changed, level = level })
    return M.getPoi(src, { citizenid = cid })
end

return M
