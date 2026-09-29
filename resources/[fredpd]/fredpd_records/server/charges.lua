-- SPDX-License-Identifier: GPL-3.0-only
-- Brottskatalog and sanctions (tasks 5.3 server, 5.4 catalogue read; §C14, ChargeSchema / ApplyCharges* /
-- IssueFineInputSchema in packages/types/src/records.ts).
-- Exports: listCharges, applyCharges, issueFine.
--
-- applyCharges: the report must be editable (server/reports.lua); the person must exist in fredpd_persons and is added
-- to the case as 'suspect' when not already a subject (same transaction as the record rows). title/class/fine/jail are
-- copied from the active catalogue row (fine and jail_min are totals for the quantity), so history never changes
-- with the catalogue. When the lines carry prison time and the person is online within JAIL_RANGE of the officer
-- (i.e. in custody), the sentence goes to the prison adapter: exports.fredpd_core:getAdapter('prison').jail(src,
-- minutes, charges). The shipped default adapter is 'none', which logs and returns false; the result is audited.
-- issueFine ("Utfärda ordningsbot"): only class 'ordningsbot'; the target must be online, in the officer's routing
-- bucket and within FINE_RANGE (5 m, measured on the server); the money is taken the way qbx_police's
-- police:server:IssueFine does it (qbx_policejob server/main.lua:596-657; its net event cannot be triggered from the
-- server with the officer as source): Player.Functions.RemoveMoney('bank', total, 'police-fine'), then Renewed-Banking
-- addAccountMoney('police', total) when that resource runs (a failed deposit refunds and fails the call). Rows are
-- stored as 'paid' after the money moved; if storing fails the money is refunded.

local C = require 'server.common'
local Cases = require 'server.cases'
local Reports = require 'server.reports'
local Search = require 'server.search'
local Format = require '@fredpd_core.shared.format'

local M = {}

M.FINE_RANGE = 5.0
M.JAIL_RANGE = 5.0
M.LIST_MAX = 500
M.FINE_COOLDOWN_MS = 2000
M.SOCIETY_ACCOUNT = 'police'
M.BANKING = 'Renewed-Banking'

local CLASSES = { 'ordningsbot', 'bot', 'fängelse' }

M.CATALOGUE_SQL = 'SELECT code, category, title_sv, law_ref, class, fine, jail_min FROM fredpd_charges WHERE active = 1'

---------------------------------------------------------------------------------------------------------------
-- Catalogue

local function toCharge(row)
    local code, class = C.str(row.code), C.str(row.class)
    if not code or not C.enum(class, CLASSES, nil) then return nil end
    return { code = code, category = C.str(row.category) or 'other', title = C.str(row.title_sv) or code,
        lawRef = C.str(row.law_ref) or '', class = class, fine = C.nonNeg(row.fine), jailMinutes = C.nonNeg(row.jail_min) }
end

local function likeContains(s)
    return '%' .. s:gsub('[\\%%_]', '\\%0') .. '%'
end

--- export listCharges(src, { query?, class? }) -> { items: Charge[] } (active catalogue; code, title or law ref match).
function M.listCharges(src, input)
    local actor
    src, actor = C.gate(src, nil)
    if not src then return actor end
    if input ~= nil and type(input) ~= 'table' then return C.fail('validation') end
    input = input or {}
    local query = input.query ~= nil and C.text(input.query, 0, 64) or nil
    local class = C.enum(input.class, CLASSES, nil)
    if (input.query ~= nil and not query) or class == false then return C.fail('validation') end
    local sql, params = M.CATALOGUE_SQL, {}
    if class then
        sql = sql .. ' AND class = ?'
        params[#params + 1] = class
    end
    if query and query ~= '' then
        sql = sql .. ' AND (code LIKE ? OR title_sv LIKE ? OR law_ref LIKE ?)'
        local like = likeContains(query)
        params[#params + 1], params[#params + 2], params[#params + 3] = like, like, like
    end
    local rows = MySQL.query.await(sql .. ' ORDER BY category, code LIMIT ' .. ('%d'):format(M.LIST_MAX), params)
    if type(rows) ~= 'table' then error('fredpd_charges query failed', 0) end
    local items = {}
    for _, row in ipairs(rows) do
        local ch = toCharge(row)
        if ch then items[#items + 1] = ch end
    end
    return C.ok({ items = items })
end

--- Validate ChargeLine[] (1..max lines; code 1-16 chars, quantity 1-20, default 1). Returns lines or nil.
function M.lines(v, max)
    if type(v) ~= 'table' or #v < 1 or #v > max then return nil end
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    if n ~= #v then return nil end
    local out = {}
    for i, line in ipairs(v) do
        if type(line) ~= 'table' or type(line.code) ~= 'string' then return nil end
        local len = utf8.len(line.code)
        if not len or len < 1 or len > 16 then return nil end
        local q = C.optInt(line.quantity, 1, 20, 1)
        if not q then return nil end
        out[i] = { code = line.code, quantity = q }
    end
    return out
end

--- Catalogue rows for the lines' codes: { [code] = Charge } (active only).
function M.catalogue(lines)
    local codes, seen = {}, {}
    for _, l in ipairs(lines) do
        if not seen[l.code] then
            seen[l.code] = true
            codes[#codes + 1] = l.code
        end
    end
    local rows = MySQL.query.await(M.CATALOGUE_SQL .. ' AND code IN (' .. C.marks(#codes) .. ')', codes)
    if type(rows) ~= 'table' then error('fredpd_charges query failed', 0) end
    local out = {}
    for _, row in ipairs(rows) do
        local ch = toCharge(row)
        if ch then out[ch.code] = ch end
    end
    return out
end

--- Lines priced from the catalogue: { code, title, class, quantity, fine = total, jail = total }. nil, code when a code
--- is unknown/retired.
function M.price(lines, catalogue)
    local out = {}
    for i, l in ipairs(lines) do
        local ch = catalogue[l.code]
        if not ch then return nil, l.code end
        out[i] = { code = ch.code, title = ch.title, class = ch.class, quantity = l.quantity,
            fine = ch.fine * l.quantity, jail = ch.jailMinutes * l.quantity }
    end
    return out
end

--- { fine, jailMinutes } over AppliedCharge rows that are not revoked.
function M.totals(records)
    local fine, jail = 0, 0
    for _, r in ipairs(records) do
        if r.status ~= 'revoked' then
            fine = fine + r.fine
            jail = jail + r.jailMinutes
        end
    end
    return { fine = fine, jailMinutes = jail }
end

---------------------------------------------------------------------------------------------------------------
-- World checks (server natives; mocked in tests)

--- Distance in metres between two players' peds, or nil when either has no ped or they are in different buckets.
function M.distance(a, b)
    local pa, pb = GetPlayerPed(a), GetPlayerPed(b)
    if not pa or pa == 0 or not pb or pb == 0 then return nil end
    if GetPlayerRoutingBucket(a) ~= GetPlayerRoutingBucket(b) then return nil end
    local ca, cb = GetEntityCoords(pa), GetEntityCoords(pb)
    if not ca or not cb then return nil end
    local dx, dy, dz = ca.x - cb.x, ca.y - cb.y, ca.z - cb.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Prison adapter jail(target, minutes, charges) -> boolean (false: no adapter / not accepted / error).
function M.jail(target, minutes, priced)
    local ok, adapter = C.core('getAdapter', 'prison')
    if not ok or type(adapter) ~= 'table' or not C.callable(adapter.jail) then
        C.warnOnce('prison', 'prison adapter unavailable; sentence recorded but nobody jailed')
        return false
    end
    local list = {}
    for i, p in ipairs(priced) do list[i] = { code = p.code, label = p.title } end
    local okJail, res = pcall(adapter.jail, target, minutes, list)
    if not okJail then
        C.warnOnce('prison:error', ('prison adapter jail failed: %s'):format(tostring(res)))
        return false
    end
    return res == true
end

---------------------------------------------------------------------------------------------------------------
-- applyCharges

--- Read back rows inserted after `afterId` for a report/person or a fine batch.
local function recordsAfter(where, params)
    local rows = MySQL.query.await('SELECT rec.id, rec.citizenid, p.firstname, p.lastname, rec.charge_code, rec.title_sv, '
        .. 'rec.class, rec.quantity, rec.fine, rec.jail_min, rec.status FROM fredpd_records rec '
        .. 'LEFT JOIN fredpd_persons p ON p.citizenid = rec.citizenid WHERE ' .. where .. ' ORDER BY rec.id', params)
    if type(rows) ~= 'table' then error('fredpd_records query failed', 0) end
    return Reports.toApplied(rows)
end

--- INSERT for one priced line (status and note as given).
local function recordInsert(cid, caseId, reportId, p, status, actor, note)
    local params = { cid }
    local sql = 'INSERT INTO fredpd_records (citizenid, case_id, report_id, charge_code, title_sv, class, quantity, fine, '
        .. 'jail_min, status, issued_by, note, updated_at) VALUES (?, ' .. Cases.opt(caseId, params) .. ', '
        .. Cases.opt(reportId, params) .. ', ?, ?, ?, ?, ?, ?, ?, ?, '
    for _, v in ipairs({ p.code, p.title, p.class, p.quantity, p.fine, p.jail, status, actor }) do params[#params + 1] = v end
    sql = sql .. Cases.opt(note, params) .. ', UTC_TIMESTAMP())'
    return { query = sql, values = params }
end

local function maxRecordId()
    return C.int(MySQL.scalar.await('SELECT COALESCE(MAX(id), 0) FROM fredpd_records')) or 0
end

--- export applyCharges(src, ApplyChargesInput) -> { records, totals }
function M.applyCharges(src, input)
    local actor
    src, actor = C.gate(src, 'perm', 'charges.apply')
    if not src then return actor end
    if type(input) ~= 'table' then return C.fail('validation') end
    local reportId = C.id(input.reportId)
    local cid = C.citizenid(input.citizenid)
    local lines = M.lines(input.lines, 30)
    local note = C.optText(input.note, 0, 255)
    if not reportId or not cid or not lines or note == false then return C.fail('validation') end
    if note == '' then note = nil end

    local r, c = Reports.forEdit(src, actor, reportId)
    if not r then return c end
    local person = MySQL.single.await('SELECT firstname, lastname FROM fredpd_persons WHERE citizenid = ?', { cid })
    if not person then return C.failWith('not_found', 'person') end
    local priced = M.price(lines, M.catalogue(lines))
    if not priced then return C.failWith('validation', 'unknown_charge') end

    local queries = {}
    local subject = MySQL.scalar.await("SELECT role FROM fredpd_case_subjects WHERE case_id = ? AND subject_type = 'person' "
        .. 'AND subject_id = ?', { c.id, cid })
    if not subject then
        queries[#queries + 1] = { query = 'INSERT IGNORE INTO fredpd_case_subjects (case_id, subject_type, subject_id, role, added_by) '
            .. "VALUES (?, 'person', ?, 'suspect', ?)", values = { c.id, cid, actor } }
    end
    for _, p in ipairs(priced) do queries[#queries + 1] = recordInsert(cid, c.id, r.id, p, 'issued', actor, note) end
    local before = maxRecordId()
    if not MySQL.transaction.await(queries) then error('applyCharges transaction failed', 0) end
    local records = recordsAfter('rec.report_id = ? AND rec.citizenid = ? AND rec.id > ?', { r.id, cid, before })
    local totals = M.totals(records)

    local jailed = nil
    if totals.jailMinutes > 0 then
        local target = C.onlineSrc(cid)
        local d = target and target ~= src and M.distance(src, target) or nil
        if d and d <= M.JAIL_RANGE then jailed = M.jail(target, totals.jailMinutes, priced) end
    end
    local codes = {}
    for i, p in ipairs(priced) do codes[i] = p.code end
    C.auditWrite(src, 'charges.apply', 'report', r.id, { label = r.number, caseId = c.id, citizenid = cid, codes = codes,
        fine = totals.fine, jailMinutes = totals.jailMinutes, subjectAdded = subject == nil or nil, jailed = jailed })
    Cases.announce(c)
    return C.ok({ records = records, totals = totals })
end

---------------------------------------------------------------------------------------------------------------
-- issueFine

--- Take `amount` from the target's bank and credit the society account (as qbx_police IssueFine). Returns true, or
--- false, reason ('insufficient_funds' | 'payment_failed').
function M.bill(targetPlayer, amount)
    local funcs = targetPlayer.Functions
    if type(funcs) ~= 'table' or not funcs.RemoveMoney then return false, 'payment_failed' end
    if not funcs.RemoveMoney('bank', amount, 'police-fine') then return false, 'insufficient_funds' end
    if GetResourceState(M.BANKING) == 'started' then
        local ok, deposited = pcall(function() return exports[M.BANKING]:addAccountMoney(M.SOCIETY_ACCOUNT, amount) end)
        if not ok or not deposited then
            funcs.AddMoney('bank', amount, 'police-fine-refund')
            return false, 'payment_failed'
        end
    else
        C.warnOnce('banking', ('%s is not started; fines are taken from the player but credited nowhere'):format(M.BANKING))
    end
    return true
end

--- export issueFine(src, { citizenid, lines, caseId? }) -> { records, totals }
function M.issueFine(src, input)
    local actor
    src, actor = C.gate(src, 'perm', 'charges.fine')
    if not src then return actor end
    if type(input) ~= 'table' then return C.fail('validation') end
    local cid = C.citizenid(input.citizenid)
    local lines = M.lines(input.lines, 10)
    local caseId = input.caseId ~= nil and C.id(input.caseId) or nil
    if not cid or not lines or (input.caseId ~= nil and not caseId) then return C.fail('validation') end
    if cid == actor then return C.failWith('validation', 'self') end

    local priced = M.price(lines, M.catalogue(lines))
    if not priced then return C.failWith('validation', 'unknown_charge') end
    for _, p in ipairs(priced) do
        if p.class ~= 'ordningsbot' then return C.failWith('validation', 'not_ordningsbot') end
    end
    local c = nil
    if caseId then
        local fail
        c, fail = Cases.forWrite(src, actor, caseId, 'full', true)
        if not c then return fail end
    end
    local target = C.onlineSrc(cid)
    if not target then return C.failWith('not_found', 'target_offline') end
    if target == src then return C.failWith('validation', 'self') end
    local d = M.distance(src, target)
    if not d or d > M.FINE_RANGE then return C.failWith('validation', 'target_too_far') end
    local player = C.qbxPlayer(target)
    if not player then return C.failWith('not_found', 'target_offline') end
    if not C.rateLimit(src, 'issueFine', M.FINE_COOLDOWN_MS) then return C.fail('rate_limited') end
    if not Search.loadFormats() then return C.fail('unavailable') end

    local total = 0
    for _, p in ipairs(priced) do total = total + p.fine end
    if total < 1 then return C.failWith('validation', 'zero_fine') end
    local paid, why = M.bill(player, total)
    if not paid then return C.failWith('validation', why) end

    local queries = {}
    for _, p in ipairs(priced) do queries[#queries + 1] = recordInsert(cid, c and c.id or nil, nil, p, 'paid', actor, nil) end
    local before = maxRecordId()
    local okTx, stored = pcall(MySQL.transaction.await, queries)
    if not okTx or not stored then
        pcall(player.Functions.AddMoney, 'bank', total, 'police-fine-refund')
        error(('issueFine: storing the records failed (%s); fine refunded'):format(tostring(stored)), 0)
    end
    local records = recordsAfter("rec.citizenid = ? AND rec.issued_by = ? AND rec.report_id IS NULL AND rec.status = 'paid' "
        .. 'AND rec.id > ?', { cid, actor, before })
    local codes = {}
    for i, p in ipairs(priced) do codes[i] = p.code end
    local amount = Format.formatCurrency(total)
    C.auditWrite(src, 'fine.issue', c and 'case' or 'person', c and c.id or cid, { label = amount, citizenid = cid,
        codes = codes, amount = total, caseId = c and c.id or nil })
    C.notify(target, 'inform', 'charge.ordningsbot.received', { amount = amount })
    if c then Cases.announce(c) end
    return C.ok({ records = records, totals = M.totals(records) })
end

return M
