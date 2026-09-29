-- SPDX-License-Identifier: GPL-3.0-only
-- Share links (task 5.5 server; IMPLEMENTATION.md §4.6, fredpd_shares in 003 + max_level in 013).
-- Exports: createShare(src, { targetType, targetId, expiresInHours }), revokeShare(src, { id }), viewShare(token).
--
-- Token: 32 bytes from a CSPRNG (Node crypto.randomBytes through this resource's JS export randomToken,
-- server/random.js), base64url without padding (43 characters). Only the token's SHA-256 hex is stored; the token
-- itself is returned once, to the creator, and is never logged or audited. Expiry is mandatory (1-168 hours).
-- Creating needs canView 'full' on the target (poi | case | report). The link shows at most max_level = the creator's
-- tier at creation (not what an assignment let them see) and never officers, subjects, charges or evidence
-- (server/export.lua). Every view is counted (view_count, last_viewed_at) and audited 'share.view'.
-- viewShare is for the service's GET /share/:token (via the fredpd_core HTTP bridge; integration request): callable
-- only from fredpd_core, fredpd_mdt (portal route), this resource or the console.

local C = require 'server.common'
local Cases = require 'server.cases'
local Reports = require 'server.reports'
local Poi = require 'server.poi'
local Export = require 'server.export'
local Time = require '@fredpd_core.shared.time'
local Sha256 = require '@fredpd_core.shared.sha256'

local M = {}

M.TOKEN_PATTERN = '^[%w_%-]+$'
M.TOKEN_LENGTH = 43
M.MAX_HOURS = 168
M.TARGETS = { 'poi', 'case', 'report' }
-- fredpd_mdt: its portal route (server/portal.lua) serves GET /share/:token for the service (docs/modules/portal-api.md).
M.VIEW_CALLERS = { fredpd_core = true, fredpd_records = true, fredpd_mdt = true }

--- A fresh token from the JS CSPRNG, or nil (never a fallback to math.random).
function M.randomToken()
    local ok, token = pcall(function() return exports.fredpd_records:randomToken(32) end)
    if not ok or type(token) ~= 'string' or #token ~= M.TOKEN_LENGTH or not token:match(M.TOKEN_PATTERN) then
        C.warnOnce('randomToken', ('randomToken unavailable (%s); share links cannot be created'):format(tostring(token)))
        return nil
    end
    return token
end

function M.hash(token)
    return Sha256.hex(token)
end

--- Resolve and check a share target for src. Returns { type, id (string), level, label, caseId? } or nil, failure.
local function target(src, actor, targetType, rawId)
    if targetType == 'poi' then
        local cid = C.citizenid(rawId)
        if not cid then return nil, C.fail('validation') end
        local p = Poi.load(cid)
        if not p then return nil, C.fail('not_found') end
        local vis = Poi.visibility(src, p)
        if vis == 'none' then return nil, C.fail('not_found') end
        if vis ~= 'full' then return nil, C.fail('unauthorized') end
        return { type = 'poi', id = cid, level = p.level, label = cid }
    end
    local id = C.id(rawId)
    if not id then return nil, C.fail('validation') end
    if targetType == 'case' then
        local c, fail = Cases.forWrite(src, actor, id, 'full', false)
        if not c then return nil, fail end
        return { type = 'case', id = tostring(id), level = c.level, label = c.caseNumber }
    end
    local r, c, vis = Reports.loadVisible(src, id)
    if not r then return nil, c end
    if vis ~= 'full' then return nil, C.fail('unauthorized') end
    return { type = 'report', id = tostring(id), level = r.level, label = r.number }
end

--- export createShare(src, { targetType, targetId, expiresInHours }) -> { id, token, path, expiresAt, maxLevel }
function M.createShare(src, input)
    local actor
    src, actor = C.gate(src, nil)
    if not src then return actor end
    if type(input) ~= 'table' then return C.fail('validation') end
    local targetType = C.enum(input.targetType, M.TARGETS, nil)
    local hours = C.optInt(input.expiresInHours, 1, M.MAX_HOURS, nil)
    if not targetType or not hours then return C.fail('validation') end
    local t, fail = target(src, actor, targetType, input.targetId)
    if not t then return fail end
    if not C.rateLimit(src, 'createShare', 2000) then return C.fail('rate_limited') end
    local token = M.randomToken()
    if not token then return C.fail('unavailable') end
    local maxLevel = C.tier(src)
    local id = C.int(MySQL.insert.await('INSERT INTO fredpd_shares (token_hash, target_type, target_id, max_level, created_by, '
        .. 'expires_at) VALUES (?, ?, ?, ?, ?, UTC_TIMESTAMP() + INTERVAL ? HOUR)',
        { M.hash(token), t.type, t.id, maxLevel, actor, hours }))
    if not id then error('fredpd_shares insert failed', 0) end
    local expiresAt = MySQL.scalar.await("SELECT DATE_FORMAT(expires_at, '%Y-%m-%dT%H:%i:%sZ') FROM fredpd_shares WHERE id = ?", { id })
    C.auditWrite(src, 'share.create', t.type, t.id, { label = t.label, shareId = id, expiresInHours = hours, maxLevel = maxLevel })
    return C.ok({ id = id, token = token, path = '/share/' .. token, expiresAt = Time.toIsoUtc(C.str(expiresAt)),
        maxLevel = maxLevel })
end

--- export revokeShare(src, { id }): the creator or records.admin. -> { id, revoked = true }
function M.revokeShare(src, input)
    local actor
    src, actor = C.gate(src, nil)
    if not src then return actor end
    local id = type(input) == 'table' and C.id(input.id) or nil
    if not id then return C.fail('validation') end
    local row = MySQL.single.await('SELECT id, created_by, target_type, target_id FROM fredpd_shares WHERE id = ?', { id })
    if not row then return C.fail('not_found') end
    if C.str(row.created_by) ~= actor and not C.perm(src, 'records.admin') then return C.fail('not_found') end
    MySQL.update.await('UPDATE fredpd_shares SET revoked_at = UTC_TIMESTAMP() WHERE id = ? AND revoked_at IS NULL', { id })
    C.auditWrite(src, 'share.revoke', C.str(row.target_type), C.str(row.target_id), { label = ('%d'):format(id), shareId = id })
    return C.ok({ id = id, revoked = true })
end

--- Content of a share at its max_level (nil = withheld now, e.g. the level was raised after the link was made).
function M.content(targetType, targetId, maxLevel)
    if targetType == 'poi' then
        local p = Poi.load(targetId)
        if not p or p.level > maxLevel then return nil end
        local person = MySQL.single.await('SELECT firstname, lastname FROM fredpd_persons WHERE citizenid = ?', { targetId })
        return { type = 'poi', name = person and C.fullName(person.firstname, person.lastname) or targetId, level = p.level,
            status = p.status, summary = p.summary, warnings = p.warnings, photoUrl = p.photoUrl, updatedAt = p.updatedAt }
    end
    local id = C.int(targetId)
    if not id then return nil end
    if targetType == 'case' then
        local c = Cases.load(id)
        return c and Export.caseContent(c, maxLevel) or nil
    elseif targetType == 'report' then
        local r = Reports.load(id)
        local c = r and Cases.load(r.caseId) or nil
        return c and Export.reportContent(c, r, maxLevel) or nil
    end
    return nil
end

--- export viewShare(token) -> { ok, data = { targetType, expiresAt, content | nil } } | not_found (unknown, expired,
--- revoked). Counted and audited on every successful view.
function M.viewShare(token)
    local caller = GetInvokingResource and GetInvokingResource() or nil
    if caller and caller ~= '' and not M.VIEW_CALLERS[caller] then
        C.warnOnce('viewShare:' .. caller, ('viewShare refused for resource %s'):format(caller))
        return C.fail('unauthorized')
    end
    if type(token) ~= 'string' or #token ~= M.TOKEN_LENGTH or not token:match(M.TOKEN_PATTERN) then return C.fail('not_found') end
    local row = MySQL.single.await('SELECT id, target_type, target_id, max_level, '
        .. Time.isoSelect('expires_at', 'expiresAt') .. ' FROM fredpd_shares WHERE token_hash = ? AND revoked_at IS NULL '
        .. 'AND expires_at > UTC_TIMESTAMP()', { M.hash(token) })
    if not row then return C.fail('not_found') end
    local id = C.int(row.id)
    MySQL.update.await('UPDATE fredpd_shares SET view_count = view_count + 1, last_viewed_at = UTC_TIMESTAMP() WHERE id = ?', { id })
    local targetType, targetId = C.str(row.target_type), C.str(row.target_id)
    -- an unreadable max_level counts as 0 (C.level's "unknown = 2" would widen it)
    local maxLevel = C.int(row.max_level)
    if maxLevel ~= 1 and maxLevel ~= 2 then maxLevel = 0 end
    C.auditWrite(0, 'share.view', targetType, targetId, { shareId = id })
    return C.ok({ targetType = targetType, expiresAt = Time.toIsoUtc(C.str(row.expiresAt)),
        content = M.content(targetType, targetId, maxLevel) })
end

return M
