-- SPDX-License-Identifier: GPL-3.0-only
-- BOLO visibility (docs/contracts.md §C3, record type 'bolo'). canView runs in fredpd_core (exports canView /
-- canViewMany; the viewer is built there from the server-side grant cache). This module turns an entry into the
-- wire Bolo (mdt.ts BoloSchema) the viewer may see:
--
--   full    everything.
--   masked  everything except who issued / resolved it and the resolve note (the "source" fields). The default
--           rules never give masked for a BOLO; a configured rule may.
--   notice  kontaktnotis: subject (kind, citizenid/plate, subject label) and a reason that reads "Det finns
--           uppgifter som rör {subject}. Kontakta {owner}." (visibility.notice.text); issuedBy, expiresAt and the
--           resolve fields are left out. BoloSchema requires id, level, createdAt and active, so those stay too; the
--           level of a kontaktnotis is more than the task allows (CaseRefSchema's notice has no id or level) and is
--           not shown by this module's own UI (shared/view.lua). BoloSchema has no visibility field, so the NUI
--           cannot tell a notice from a full BOLO except by its content (docs/modules/bolo.md, open questions 1-2).
--   none    hidden (list/getBolosFor drop it; resolve answers not_found).
--
-- Default rules (db/seed/visibility_rules_default.sql 50-55): records.admin, level 0, the issuer (assigned =
-- ownerCitizenid), the BOLO's unit and tier >= level see it in full; everyone else gets the kontaktnotis.
--
-- Lists: the history list (active = false) is paginated in SQL, so rows the viewer may not see at all must be
-- filtered there, not after the LIMIT (the total would leak their count). A BOLO's result depends only on its level,
-- status (open = live), whether the viewer issued it and whether its unit is one of the viewer's units, so
-- filterSql() evaluates those <= 24 combinations for the viewer (one canViewMany call) and turns the visible ones
-- into a WHERE clause. With the default rules every combination is visible and there is no clause at all.

local Store = require 'server.store'

local M = {}

--- Locale function; server/main.lua sets it to fredpd_core's L.
M.L = function(key) return key end

M.WIRE_FIELDS = { 'id', 'kind', 'citizenid', 'plate', 'subject', 'reason', 'level', 'issuedBy', 'createdAt',
    'expiresAt', 'active', 'resolvedBy', 'resolvedAt', 'resolveNote' }

local function copyRef(ref)
    if type(ref) ~= 'table' then return nil end
    return { citizenid = ref.citizenid, displayName = ref.displayName, callsign = ref.callsign, unit = ref.unit }
end

--- The full wire Bolo of an entry. `live` (boolean) overrides the computed active flag.
function M.wire(entry, live)
    return {
        id = entry.id,
        kind = entry.kind,
        citizenid = entry.citizenid,
        plate = entry.plate,
        subject = entry.subject,
        reason = entry.reason,
        level = entry.level,
        issuedBy = copyRef(entry.issuedBy),
        createdAt = entry.createdAt,
        expiresAt = entry.expiresAt,
        active = live == true,
        resolvedBy = copyRef(entry.resolvedBy),
        resolvedAt = entry.resolvedAt,
        resolveNote = entry.resolveNote,
    }
end

--- VisRecord (§C3) of an entry.
function M.record(entry, live)
    return {
        type = 'bolo',
        id = entry.id,
        level = entry.level,
        status = live and 'open' or 'closed',
        unit = entry.unit,
        ownerCitizenid = entry.issuedByCid,
    }
end

--- Whom to contact for a kontaktnotis: "IGV-07 · Anna B." (bolo.notice.owner), the display name, or the unit label.
function M.contact(entry)
    local ref = entry.issuedBy
    if ref and ref.displayName then
        if ref.callsign and ref.callsign ~= ref.displayName then
            return M.L('bolo.notice.owner', { callsign = ref.callsign, name = ref.displayName })
        end
        return ref.displayName
    end
    if entry.unit then return M.L('unit.' .. entry.unit) end
    return nil
end

--- Kontaktnotis text for an entry.
function M.noticeText(entry)
    local owner = M.contact(entry)
    if owner then return M.L('visibility.notice.text', { subject = entry.subject, owner = owner }) end
    return M.L('visibility.notice.textCommand', { subject = entry.subject })
end

--- Wire Bolo for a canView result, nil for 'none' (or an unknown result: fail closed).
function M.shape(entry, result, live)
    if result == 'full' then return M.wire(entry, live) end
    if result == 'masked' then
        local b = M.wire(entry, live)
        b.issuedBy, b.resolvedBy, b.resolveNote = nil, nil, nil
        return b
    end
    if result == 'notice' then
        return {
            id = entry.id,
            kind = entry.kind,
            citizenid = entry.citizenid,
            plate = entry.plate,
            subject = entry.subject,
            reason = M.noticeText(entry),
            level = entry.level,
            createdAt = entry.createdAt,
            active = live == true,
        }
    end
    return nil
end

--- canView viewer for broadcast text: src 0 is no player, so fredpd_core builds the least-privileged viewer (no
--- citizenid, tier 0, no units, no grants).
M.BASELINE_VIEWER = 0

--- Text for a BOLO hit that every on-duty officer sees (alert description; the alert is not filtered per viewer),
--- from canView for the least-privileged viewer: the reason for full/masked (with the default rules: level 0), the
--- kontaktnotis for notice (Begränsad/Hemlig), nil for none (or no answer): then no alert may be raised at all.
--- @return string|nil
function M.publicReason(entry)
    local result = M.resultFor(M.BASELINE_VIEWER, entry, true)
    if result == 'full' or result == 'masked' then return entry.reason end
    if result == 'notice' then return M.noticeText(entry) end
    return nil
end

---------------------------------------------------------------------------------------------------------------
-- canView through fredpd_core (fail closed: no answer = 'none')

--- canView results for a list of VisRecords, one export call.
function M.canViewMany(src, records)
    if #records == 0 then return {} end
    local ok, results = pcall(function() return exports.fredpd_core:canViewMany(src, records) end)
    if not ok or type(results) ~= 'table' then return {} end
    return results
end

--- Shape entries for viewer `src`. liveOf(entry) -> boolean. Entries the viewer may not see are dropped.
--- @return table[] bolos, table[] kept entries (same order)
function M.shapeMany(src, entries, liveOf)
    local records, lives = {}, {}
    for i, entry in ipairs(entries) do
        lives[i] = liveOf(entry)
        records[i] = M.record(entry, lives[i])
    end
    local results = M.canViewMany(src, records)
    local out, kept = {}, {}
    for i, entry in ipairs(entries) do
        local b = M.shape(entry, results[i], lives[i])
        if b then
            out[#out + 1] = b
            kept[#kept + 1] = entry
        end
    end
    return out, kept
end

--- canView result for one entry.
function M.resultFor(src, entry, live)
    return M.canViewMany(src, { M.record(entry, live) })[1] or 'none'
end

---------------------------------------------------------------------------------------------------------------
-- SQL filter for paginated lists

--- WHERE fragment (over alias b) keeping exactly the BOLOs viewer `src` may see at all, plus its parameters.
--- '' = no restriction; '0 = 1' = nothing visible.
--- @return string where, table params
function M.filterSql(src)
    local okCid, citizenid = pcall(function() return exports.fredpd_core:getCitizenId(src) end)
    local okUnits, units = pcall(function() return exports.fredpd_core:getUnits(src) end)
    citizenid = okCid and type(citizenid) == 'string' and citizenid ~= '' and citizenid or nil
    local unitList = {}
    for _, u in ipairs(okUnits and type(units) == 'table' and units or {}) do
        if type(u) == 'string' and u ~= '' then unitList[#unitList + 1] = u end
    end

    local owns = citizenid and { true, false } or { false }
    local inUnits = #unitList > 0 and { true, false } or { false }
    local combos, records = {}, {}
    for level = 0, 2 do
        for _, status in ipairs({ 'open', 'closed' }) do
            for _, own in ipairs(owns) do
                for _, inUnit in ipairs(inUnits) do
                    combos[#combos + 1] = { level = level, status = status, own = own, inUnit = inUnit }
                    records[#records + 1] = { type = 'bolo', id = 0, level = level, status = status,
                        unit = inUnit and unitList[1] or nil, ownerCitizenid = own and citizenid or nil }
                end
            end
        end
    end
    local results = M.canViewMany(src, records)

    local visibleByLevel, allVisible, anyVisible = {}, true, false
    for i, c in ipairs(combos) do
        local visible = results[i] == 'full' or results[i] == 'masked' or results[i] == 'notice'
        c.visible = visible
        allVisible = allVisible and visible
        anyVisible = anyVisible or visible
        local lv = visibleByLevel[c.level] or { all = true, list = {} }
        visibleByLevel[c.level] = lv
        lv.all = lv.all and visible
        if visible then lv.list[#lv.list + 1] = c end
    end
    if allVisible then return '', {} end
    if not anyVisible then return '0 = 1', {} end

    local params, parts = {}, {}
    local unitMarks = Store.marks(#unitList)
    for level = 0, 2 do
        local lv = visibleByLevel[level]
        if lv.all then
            parts[#parts + 1] = ('b.level = %d'):format(level)
        else
            for _, c in ipairs(lv.list) do
                local terms = { ('b.level = %d'):format(level) }
                terms[#terms + 1] = c.status == 'open' and Store.LIVE_SQL or ('NOT ' .. Store.LIVE_SQL)
                if citizenid then
                    terms[#terms + 1] = c.own and 'b.issued_by = ?' or 'b.issued_by <> ?'
                    params[#params + 1] = citizenid
                end
                if #unitList > 0 then
                    terms[#terms + 1] = c.inUnit and ('b.unit IN (' .. unitMarks .. ')')
                        or ('(b.unit IS NULL OR b.unit NOT IN (' .. unitMarks .. '))')
                    for _, u in ipairs(unitList) do params[#params + 1] = u end
                end
                parts[#parts + 1] = '(' .. table.concat(terms, ' AND ') .. ')'
            end
        end
    end
    return '(' .. table.concat(parts, ' OR ') .. ')', params
end

return M
