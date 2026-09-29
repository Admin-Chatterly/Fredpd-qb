-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_tablets (db/migrations/008_tablets.sql): issuing, the Ledning list "Surfplattor" and revocation
-- (IMPLEMENTATION.md §5.2, docs/contracts.md §C12). Every write is audited through fredpd_core (tablet.issue,
-- tablet.revoke, tablet.reinstate). Timestamps are written with UTC_TIMESTAMP() and read with Time.isoSelect (§C7).
--
--   issue(actorSrc, targetSrc)          /surfplatta <id>: row + inventory item (bridge add) with metadata { serial, owner }
--   list(src, { page })                 action listTablets     -> TabletListOutput
--   setRevoked(src, { serial, revoked }) action setTabletRevoked -> Tablet; revoking force-closes that tablet

local C = require 'server.common'
local Open = require 'server.open'
local Config = require 'config'
local Validate = require 'shared.validate'
local Time = require '@fredpd_core.shared.time'

local M = {}

M.SERIAL_ATTEMPTS = 5

---------------------------------------------------------------------------------------------------------------
-- Serials

--- A random serial such as 'SP-7KQ2-M9XD' (config serial). Uniqueness is the primary key's job (see issue()).
function M.newSerial(random)
    random = random or math.random
    local cfg = Config.serial
    local groups = {}
    for g = 1, cfg.groups do
        local chars = {}
        for i = 1, cfg.groupLength do
            local k = random(1, #cfg.alphabet)
            chars[i] = cfg.alphabet:sub(k, k)
        end
        groups[g] = table.concat(chars)
    end
    return cfg.prefix .. '-' .. table.concat(groups, '-')
end

---------------------------------------------------------------------------------------------------------------
-- SQL

-- No nil in parameter arrays (a Lua array with a nil hole does not reach oxmysql intact): the console variant
-- writes the NULL issuer in SQL.
M.INSERT_SQL = 'INSERT IGNORE INTO fredpd_tablets (serial, owner_citizenid, issued_by, issued_at) '
    .. 'VALUES (?, ?, ?, UTC_TIMESTAMP())'
M.INSERT_CONSOLE_SQL = 'INSERT IGNORE INTO fredpd_tablets (serial, owner_citizenid, issued_by, issued_at) '
    .. 'VALUES (?, ?, NULL, UTC_TIMESTAMP())'
M.DELETE_SQL = 'DELETE FROM fredpd_tablets WHERE serial = ? AND revoked = 0'

local SELECT_COLS = 'SELECT t.serial, t.owner_citizenid AS ownerCitizenid, o.display_name AS ownerName, t.revoked, '
    .. 't.issued_by AS issuedByCid, ib.display_name AS issuedByName, ib.callsign AS issuedByCallsign, '
    .. 'ib.unit AS issuedByUnit, ' .. Time.isoSelect('t.issued_at', 'issuedAt')
    .. ' FROM fredpd_tablets t'
    .. ' LEFT JOIN fredpd_officers o ON o.citizenid = t.owner_citizenid'
    .. ' LEFT JOIN fredpd_officers ib ON ib.citizenid = t.issued_by'

M.LIST_SQL = SELECT_COLS .. ' ORDER BY t.issued_at DESC, t.serial ASC LIMIT ? OFFSET ?'
M.COUNT_SQL = 'SELECT COUNT(*) FROM fredpd_tablets'
M.GET_SQL = SELECT_COLS .. ' WHERE t.serial = ?'
M.REVOKE_SQL = 'UPDATE fredpd_tablets SET revoked = 1, revoked_by = ?, revoked_at = UTC_TIMESTAMP() WHERE serial = ?'
M.REINSTATE_SQL = 'UPDATE fredpd_tablets SET revoked = 0, revoked_by = NULL, revoked_at = NULL WHERE serial = ?'

local function truthy(v)
    return v == true or v == 1 or v == '1'
end

local function str(v)
    if v == nil then return nil end
    return tostring(v) -- the test shim reads digit-only text as numbers; oxmysql returns VARCHAR as strings
end

--- DB row -> Tablet (mdt.ts TabletSchema). Nullable fields that are nil are absent on the wire (Lua has no null).
function M.wire(row)
    local owner = nil
    if row.ownerCitizenid ~= nil then
        local cid = str(row.ownerCitizenid)
        owner = { citizenid = cid, name = str(row.ownerName) or cid }
    end
    local issuedBy = nil
    if row.issuedByCid ~= nil then
        local cid = str(row.issuedByCid)
        issuedBy = { citizenid = cid, displayName = str(row.issuedByName) or cid, callsign = str(row.issuedByCallsign),
            unit = str(row.issuedByUnit) }
    end
    return {
        serial = str(row.serial),
        owner = owner,
        revoked = truthy(row.revoked),
        issuedBy = issuedBy,
        issuedAt = Time.toIsoUtc(row.issuedAt) or row.issuedAt,
    }
end

local function getRow(serial)
    return MySQL.single.await(M.GET_SQL, { serial })
end

---------------------------------------------------------------------------------------------------------------
-- Issue (/surfplatta)

--- Name for the messages: the officer's Discord display name (§4.9), else the citizenid (never the character name).
local function officerName(src, citizenid)
    local ok, officer = C.core('getOfficer', src)
    if ok and type(officer) == 'table' and type(officer.displayName) == 'string' and officer.displayName ~= '' then
        return officer.displayName
    end
    return citizenid
end

--- Issue a tablet to `targetSrc`. actorSrc 0 = console. Call from a thread (DB await).
--- @return boolean ok, string localeKey, table|nil vars, string|nil serial
function M.issue(actorSrc, targetSrc)
    local input = Validate.check('TabletIssueInput', { targetServerId = targetSrc })
    local target = input and C.playerSrc(input.targetServerId)
    if not target or not GetPlayerName(tostring(target)) then return false, 'errors.notFound' end
    local owner = C.citizenId(target)
    if not owner then return false, 'tablet.issueNoCharacter' end
    local issuedBy = nil
    if actorSrc ~= 0 then
        issuedBy = C.citizenId(actorSrc)
        if not issuedBy then return false, 'errors.unauthorized' end
    end
    -- No CanCarryItem in the bridge (§C17): a full inventory shows up as add() == false below, after the row insert,
    -- which is then rolled back. A stopped inventory is refused here, before anything is written.
    if not C.inventoryUp() then return false, 'tablet.unavailable' end

    local serial = nil
    for _ = 1, M.SERIAL_ATTEMPTS do
        local candidate = M.newSerial()
        local ok, affected
        if issuedBy then
            ok, affected = pcall(MySQL.update.await, M.INSERT_SQL, { candidate, owner, issuedBy })
        else
            ok, affected = pcall(MySQL.update.await, M.INSERT_CONSOLE_SQL, { candidate, owner })
        end
        if not ok then
            C.log('error', 'tablet insert failed: %s', tostring(affected))
            return false, 'tablet.issueFailed'
        end
        if tonumber(affected) == 1 then
            serial = candidate
            break
        end
    end
    if not serial then
        C.log('error', 'no free tablet serial after %d attempts', M.SERIAL_ATTEMPTS)
        return false, 'tablet.issueFailed'
    end

    local metadata = { serial = serial, owner = owner, description = C.L('tablet.itemSerial', { serial = serial }) }
    if not C.addItem(target, Config.item, 1, metadata) then
        -- Never issued: remove the row again so the list does not show a tablet nobody holds. The bridge cannot say
        -- why (full inventory, pd_tablet missing from the inventory's items, inventory stopped meanwhile).
        pcall(MySQL.update.await, M.DELETE_SQL, { serial })
        -- Item patches: patches/qb-core.10-fredpd-items.patch, patches/ox_inventory.10-fredpd-items.patch.
        C.logThrottled('issue:add', 'warn', 'could not add %s to player %d (inventory full, or the item is missing from '
            .. 'the inventory\'s item list: apply the FredPD item patch)', Config.item, target)
        return false, 'tablet.issueNotAdded'
    end

    C.audit(actorSrc, 'tablet.issue', 'tablet', serial, { owner = owner, target = target })
    TriggerClientEvent('ox_lib:notify', target, { type = 'success', description = C.L('tablet.received', { serial = serial }) })
    return true, 'tablet.issued', { serial = serial, name = officerName(target, owner) }, serial
end

---------------------------------------------------------------------------------------------------------------
-- Actions (called by the dispatcher after its grant/duty/rate checks; input already validated there)

--- listTablets -> { ok, data = TabletListOutput }
function M.list(src, input)
    local page = math.tointeger(input and input.page) or 1
    local size = Config.pageSize
    local rows = MySQL.query.await(M.LIST_SQL, { size, (page - 1) * size })
    local total = MySQL.scalar.await(M.COUNT_SQL)
    if type(rows) ~= 'table' or total == nil then error('tablet list query failed', 0) end
    local items = {}
    for i, row in ipairs(rows) do items[i] = M.wire(row) end
    return C.ok({ items = items, total = math.tointeger(tonumber(total)) or 0, page = page })
end

--- setTabletRevoked -> { ok, data = Tablet } | not_found. Revoking closes an open tablet with that serial at once.
function M.setRevoked(src, input)
    local serial, revoked = input.serial, input.revoked == true
    local row = getRow(serial)
    if type(row) ~= 'table' then return C.fail('not_found') end
    local was = truthy(row.revoked)
    if was ~= revoked then
        local actor = C.citizenId(src)
        if not actor then return C.fail('unauthorized') end
        if revoked then
            MySQL.update.await(M.REVOKE_SQL, { actor, serial })
        else
            MySQL.update.await(M.REINSTATE_SQL, { serial })
        end
        C.audit(src, revoked and 'tablet.revoke' or 'tablet.reinstate', 'tablet', serial,
            { owner = row.ownerCitizenid and str(row.ownerCitizenid) or nil })
        row = getRow(serial) or row
    end
    if revoked then Open.closeBySerial(serial, 'tablet.revoked') end
    return C.ok(M.wire(row))
end

return M
