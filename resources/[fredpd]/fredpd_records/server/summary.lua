-- SPDX-License-Identifier: GPL-3.0-only
-- Person page, vehicle page and "my cases" (tasks 2.4/2.5 server side, Hem 2.7; PersonSummary, VehicleSummary,
-- HomeOutput.myCases in packages/types/src/mdt.ts, §C12). Read only: case writes arrive in Phase 5.
-- Every person/vehicle lookup is audited once (lookup.person / lookup.vehicle, §4.5), a not_found one too (meta
-- found = false), so probing for citizenids or plates leaves a trace. Case references are shaped by canView
-- (server/caserefs.lua). A charge record tied to a case is listed only when that case's content is visible to the
-- viewer (full, or masked at a level <= tier): a kontaktnotis or hidden case reveals nothing through the record list.
-- A plate check's `hit` is true only when the viewer may see the BOLO that caused it (canView on fredpd_bolos).

local C = require 'server.common'
local Refs = require 'server.caserefs'
local Search = require 'server.search'
local Time = require '@fredpd_core.shared.time'

local M = {}

M.MAX_VEHICLES = 50
M.MAX_CASES = 50
M.MAX_RECORDS = 100
M.MAX_CHECKS = 20
M.MAX_HOME = 10

local GENDERS = { [0] = 'male', [1] = 'female' }

local CASE_ORDER = " ORDER BY (c.status = 'open') DESC, c.updated_at DESC, c.id DESC"

local SUBJECT_CASES_SQL = 'SELECT ' .. Refs.CASE_COLS .. ', s.role FROM fredpd_case_subjects s '
    .. 'JOIN fredpd_cases c ON c.id = s.case_id WHERE s.subject_type = ? AND s.subject_id = ?' .. CASE_ORDER
    .. ' LIMIT ' .. ('%d'):format(M.MAX_CASES)

--- Cases linked to a person/vehicle, with assignees, most relevant first. `role` overrides the stored role.
local function subjectCases(subjectType, subjectId, role)
    local rows = MySQL.query.await(SUBJECT_CASES_SQL, { subjectType, subjectId })
    if type(rows) ~= 'table' then error('fredpd_case_subjects query failed', 0) end
    return Refs.fromRows(rows, role)
end

local function must(rows, what)
    if type(rows) ~= 'table' then error(what .. ' query failed', 0) end
    return rows
end

---------------------------------------------------------------------------------------------------------------
-- Person

local PERSON_SQL = "SELECT citizenid, firstname, lastname, DATE_FORMAT(birthdate, '%Y-%m-%d') AS birthdate, "
    .. 'personnummer, gender, phone FROM fredpd_persons WHERE citizenid = ?'

local RECORDS_SQL = 'SELECT r.id, r.charge_code, COALESCE(NULLIF(r.title_sv, \'\'), ch.title_sv, r.charge_code) AS title, '
    .. 'r.fine, r.jail_min, ' .. Time.isoSelect('r.created_at', 'createdAt') .. ', r.case_id '
    .. 'FROM fredpd_records r LEFT JOIN fredpd_charges ch ON ch.code = r.charge_code '
    .. "WHERE r.citizenid = ? AND r.status <> 'revoked' ORDER BY r.created_at DESC, r.id DESC LIMIT "
    .. ('%d'):format(M.MAX_RECORDS)

--- fredpd_persons.gender (qbx charinfo: 0 man, 1 kvinna) -> PersonSchema gender.
function M.gender(v)
    return GENDERS[C.int(v)] or 'unknown'
end

local function vehiclesOf(src, citizenid)
    local rows = must(MySQL.query.await('SELECT plate, model FROM fredpd_vehicles_idx WHERE citizenid = ? '
        .. 'ORDER BY plate LIMIT ' .. ('%d'):format(M.MAX_VEHICLES), { citizenid }), 'fredpd_vehicles_idx')
    local running = C.boloRunning()
    local out = {}
    for _, row in ipairs(rows) do
        local plate = C.str(row.plate)
        if plate then
            out[#out + 1] = { plate = plate, model = C.str(row.model), bolo = C.boloFlag(src, 'vehicle', plate, running) }
        end
    end
    return out
end

--- export getPersonSummary(src, { citizenid }) -> { ok, data = PersonSummary } | { ok = false, error }
function M.person(src, input)
    src = C.playerSrc(src)
    if not src then return C.fail('unauthorized') end
    local citizenid = type(input) == 'table' and C.citizenid(input.citizenid) or nil
    if not citizenid then return C.fail('validation') end
    if not C.hasGrant(src, 'mdt_page', 'search') then return C.fail('unauthorized') end

    local row = MySQL.single.await(PERSON_SQL, { citizenid })
    if not row then
        C.audit(src, 'lookup.person', 'person', citizenid, { source = 'summary', found = false })
        return C.fail('not_found')
    end
    local cid = C.str(row.citizenid) or citizenid
    local person = {
        citizenid = cid,
        firstname = C.str(row.firstname) or '',
        lastname = C.str(row.lastname) or '',
        birthdate = C.str(row.birthdate),
        personnummer = C.str(row.personnummer),
        gender = M.gender(row.gender),
        phone = C.str(row.phone),
    }

    -- Subject cases first (refs), then the cases of charge records not already among them (visibility only).
    local cases = subjectCases('person', cid)
    local refCount = #cases
    local recordRows = must(MySQL.query.await(RECORDS_SQL, { cid }), 'fredpd_records')
    local known, extra = {}, {}
    for _, c in ipairs(cases) do known[c.id] = true end
    for _, r in ipairs(recordRows) do
        local caseId = C.int(r.case_id)
        if caseId and not known[caseId] then
            known[caseId] = true
            extra[#extra + 1] = caseId
        end
    end
    for _, c in ipairs(Refs.loadByIds(extra)) do cases[#cases + 1] = c end
    local refs, vis, tier = Refs.evaluate(src, cases, refCount)

    -- case id -> its number when the case's content is visible; a record of any other case is left out entirely
    -- (a case the loader could not read, e.g. a bad status, is never in this map and so fails closed)
    local visibleNumber = {}
    for i, c in ipairs(cases) do
        if Refs.contentVisible(c, vis[i], tier) then visibleNumber[c.id] = c.caseNumber end
    end
    local records = {}
    for _, r in ipairs(recordRows) do
        local id = C.int(r.id)
        local caseId = C.int(r.case_id)
        if id and (not caseId or visibleNumber[caseId]) then
            records[#records + 1] = {
                id = id,
                chargeCode = C.str(r.charge_code) or '',
                title = C.str(r.title) or '',
                fine = C.nonNeg(r.fine),
                jailMinutes = C.nonNeg(r.jail_min),
                createdAt = Time.toIsoUtc(C.str(r.createdAt)),
                caseNumber = caseId and visibleNumber[caseId] or nil,
            }
        end
    end

    C.audit(src, 'lookup.person', 'person', cid, { source = 'summary', found = true })
    return C.ok({
        person = person,
        vehicles = vehiclesOf(src, cid),
        bolos = C.bolosFor(src, 'person', cid),
        cases = refs,
        records = records,
        address = C.address(cid),
    })
end

---------------------------------------------------------------------------------------------------------------
-- Vehicle

-- The BOLO behind a hit comes along (b.*) so its visibility can be checked; `live` mirrors fredpd_bolo's Store.LIVE_SQL
-- (canView status 'open' while the BOLO is live, 'closed' after it was resolved or expired).
local CHECKS_SQL = 'SELECT ' .. Time.isoSelect('k.created_at', 'checkedAt') .. ', k.officer_citizenid, k.hit, '
    .. 'k.bolo_id, o.display_name, o.callsign, o.unit, b.id AS b_id, b.level AS b_level, b.unit AS b_unit, '
    .. 'b.issued_by AS b_issued_by, (b.active = 1 AND (b.expires_at IS NULL OR b.expires_at > UTC_TIMESTAMP())) '
    .. 'AS b_live FROM fredpd_plate_checks k '
    .. 'LEFT JOIN fredpd_officers o ON o.citizenid = k.officer_citizenid '
    .. 'LEFT JOIN fredpd_bolos b ON b.id = k.bolo_id '
    .. 'WHERE k.plate = ? ORDER BY k.created_at DESC, k.id DESC LIMIT ' .. ('%d'):format(M.MAX_CHECKS)

--- { [bolo id] = true } for the BOLOs behind hit rows that the viewer may see at all (canView not 'none'; the VisRecord
--- is built as fredpd_bolo's Visibility.record builds it). One canViewMany call; failure = nothing visible.
local function visibleHitBolos(src, rows)
    local records, seen = {}, {}
    for _, row in ipairs(rows) do
        local id = C.int(row.b_id)
        if C.bool(row.hit) and id and not seen[id] then
            seen[id] = true
            records[#records + 1] = { type = 'bolo', id = id, level = C.level(row.b_level),
                status = C.bool(row.b_live) and 'open' or 'closed', unit = C.str(row.b_unit),
                ownerCitizenid = C.str(row.b_issued_by) }
        end
    end
    local visible = {}
    if #records == 0 then return visible end
    local ok, results = C.core('canViewMany', src, records)
    if not ok or type(results) ~= 'table' then
        C.warnOnce('canViewMany:bolo', ('exports.fredpd_core:canViewMany failed (%s); plate check hits hidden')
            :format(tostring(results)))
        return visible
    end
    for i, rec in ipairs(records) do
        local r = results[i]
        if r == 'full' or r == 'masked' or r == 'notice' then visible[rec.id] = true end
    end
    return visible
end

--- Last plate checks, newest first. fredpd_plate_checks comes from fredpd_bolo's migration (§C12 010); while it is
--- missing (or the query fails) the list is empty and the problem is logged once. `hit` is true only when the BOLO
--- behind it is known and visible to the viewer (a hit on a hidden BOLO reads as a plain check).
local function checksOf(src, plate)
    local ok, rows = pcall(MySQL.query.await, CHECKS_SQL, { plate })
    if not ok or type(rows) ~= 'table' then
        C.warnOnce('plate_checks', ('fredpd_plate_checks unavailable (%s); vehicle pages show no check history')
            :format(tostring(rows)))
        return {}
    end
    local visible = visibleHitBolos(src, rows)
    local out = {}
    for _, row in ipairs(rows) do
        local checkedAt = C.str(row.checkedAt)
        if checkedAt then
            local cid = C.citizenid(C.str(row.officer_citizenid))
            local name = C.str(row.display_name)
            local boloId = C.int(row.b_id)
            out[#out + 1] = {
                checkedAt = Time.toIsoUtc(checkedAt),
                officer = (cid and name) and { citizenid = cid, displayName = name, callsign = C.str(row.callsign),
                    unit = C.str(row.unit) } or nil,
                hit = C.bool(row.hit) and boloId ~= nil and visible[boloId] == true,
            }
        end
    end
    return out
end

--- export getVehicleSummary(src, { plate }) -> { ok, data = VehicleSummary } | { ok = false, error }
--- A plate that is neither registered (fredpd_vehicles_idx, refreshed from player_vehicles on a miss) nor has a
--- BOLO, a case or a check is not_found; an unregistered plate that has any of them gets a page without owner.
function M.vehicle(src, input)
    src = C.playerSrc(src)
    if not src then return C.fail('unauthorized') end
    local plate = type(input) == 'table' and C.plate(input.plate) or nil
    if not plate then return C.fail('validation') end
    if not C.hasGrant(src, 'mdt_page', 'search') then return C.fail('unauthorized') end

    local row = Search.vehicleRow(plate)
    local bolos = C.bolosFor(src, 'vehicle', plate)
    local refs = Refs.evaluate(src, subjectCases('vehicle', plate, 'vehicle'))
    local checks = checksOf(src, plate)
    if not row and #bolos == 0 and #refs == 0 and #checks == 0 then
        C.audit(src, 'lookup.vehicle', 'vehicle', plate, { source = 'summary', found = false, registered = false })
        return C.fail('not_found')
    end

    local owner = nil
    local ownerCid = row and C.citizenid(C.str(row.citizenid)) or nil
    if ownerCid then
        owner = { citizenid = ownerCid, name = C.fullName(row.firstname, row.lastname) or ownerCid }
    end

    C.audit(src, 'lookup.vehicle', 'vehicle', plate, { source = 'summary', found = true, registered = row ~= nil })
    return C.ok({
        vehicle = { plate = row and C.str(row.plate) or plate, model = row and C.str(row.model) or nil },
        owner = owner,
        bolos = bolos,
        cases = refs,
        checks = checks,
    })
end

---------------------------------------------------------------------------------------------------------------
-- Hem: my cases

local MY_CASES_FROM = ' FROM fredpd_cases c JOIN (SELECT id AS case_id FROM fredpd_cases WHERE owner_citizenid = ? '
    .. 'UNION SELECT case_id FROM fredpd_case_assignees WHERE citizenid = ?) m ON m.case_id = c.id'

--- The actor's citizenid, from fredpd_core (qbx_core), never from the input.
local function actor(src)
    local cid = C.coreOr('getCitizenId', src)
    return C.citizenid(C.str(cid))
end

--- export getHomeCases(src, { limit }) -> { ok, data = CaseRef[] } (owner or assignee, open first, limit 1-10).
function M.homeCases(src, input)
    src = C.playerSrc(src)
    if not src then return C.fail('unauthorized') end
    if not C.hasAnyPageGrant(src) then return C.fail('unauthorized') end
    if input ~= nil and type(input) ~= 'table' then return C.fail('validation') end
    local limit = C.optInt(input and input.limit, 1, M.MAX_HOME, M.MAX_HOME)
    if not limit then return C.fail('validation') end
    local cid = actor(src)
    if not cid then return C.fail('unauthorized') end

    local rows = must(MySQL.query.await('SELECT ' .. Refs.CASE_COLS .. MY_CASES_FROM .. CASE_ORDER .. ' LIMIT '
        .. ('%d'):format(limit), { cid, cid }), 'my cases')
    local refs = Refs.evaluate(src, Refs.fromRows(rows))
    return C.ok(refs)
end

--- export countMyOpenCases(src) -> { ok, data = n }: HomeOutput.counts.myOpenCases (owner or assignee, open).
function M.countMyOpenCases(src)
    src = C.playerSrc(src)
    if not src then return C.fail('unauthorized') end
    if not C.hasAnyPageGrant(src) then return C.fail('unauthorized') end
    local cid = actor(src)
    if not cid then return C.fail('unauthorized') end
    local n = MySQL.scalar.await("SELECT COUNT(*)" .. MY_CASES_FROM .. " WHERE c.status = 'open'", { cid, cid })
    if n == nil then error('my open cases count failed', 0) end
    return C.ok(C.nonNeg(n))
end

return M
