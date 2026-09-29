-- SPDX-License-Identifier: GPL-3.0-only
-- Audit log (IMPLEMENTATION.md §4.5). Every FredPD write and every person/vehicle lookup ends up here through
-- exports.fredpd_core:audit(src, action, targetType, targetId, meta). The actor is resolved on the server: citizenid
-- from qbx_core, Discord id from the player's identifiers. src 0 (or nil) is the system.
--
-- Retention: rows older than 90 days move to fredpd_audit_archive with the ACE-restricted console/chat command
-- `fredpd_audit_archive [days]`, run by hand once a month (no timer).

local Core = require 'server.core'
local Perms = require 'server.perms'
local Locale = require 'shared.locale'
local Time = require 'shared.time'

local M = {}

M.MAX_META_BYTES = 16 * 1024
M.DEFAULT_ARCHIVE_DAYS = 90
M.ARCHIVE_BATCH = 5000
M.INSERT_SQL = 'INSERT INTO fredpd_audit (actor_citizenid, actor_discord, action, target_type, target_id, meta) '
    .. 'VALUES (%s)'

local ACTION_PATTERN = '^[%w_][%w_%.%-:]*$'

local function optionalString(v, max, what)
    if v == nil then return nil end
    if type(v) == 'number' then v = math.tointeger(v) and ('%d'):format(v) or tostring(v) end
    if type(v) ~= 'string' then error(('%s must be a string'):format(what), 0) end
    if v == '' then return nil end
    if #v > max then error(('%s longer than %d bytes'):format(what, max), 0) end
    return v
end

--- Validate one entry and return the 6 column values in INSERT order (nil = NULL). Raises "<reason>" on bad
--- input. Meta larger than MAX_META_BYTES is replaced by a marker so one oversized call cannot bloat the table.
--- @param e table { actorCitizenid?, actorDiscord?, action, targetType?, targetId?, meta? }
--- @return table values
function M.buildRow(e)
    if type(e) ~= 'table' then error('entry must be a table', 0) end
    local action = e.action
    if type(action) ~= 'string' or #action == 0 or #action > 64 or not action:match(ACTION_PATTERN) then
        error(('invalid action %s'):format(tostring(action)), 0)
    end
    local actorDiscord = optionalString(e.actorDiscord, 20, 'actorDiscord')
    if actorDiscord and not actorDiscord:match('^%d+$') then error('actorDiscord must be a Discord id', 0) end
    local meta = nil
    if e.meta ~= nil then
        if type(e.meta) ~= 'table' then error('meta must be a table', 0) end
        local ok, encoded = pcall(json.encode, e.meta)
        if not ok then error('meta is not JSON-encodable', 0) end
        if #encoded > M.MAX_META_BYTES then
            encoded = json.encode({ truncated = true, bytes = #encoded })
        end
        meta = encoded
    end
    return {
        optionalString(e.actorCitizenid, 50, 'actorCitizenid'),
        actorDiscord,
        action,
        optionalString(e.targetType, 32, 'targetType'),
        optionalString(e.targetId, 64, 'targetId'),
        meta,
    }
end

--- Internal write with an explicit actor (fredpd_core modules; the system uses no actor). Non-blocking.
--- @return boolean queued
function M.write(entry)
    local ok, values = pcall(M.buildRow, entry)
    if not ok then
        Core.warn('audit entry rejected: %s', tostring(values))
        return false
    end
    local marks, params = Core.bindRow(values, 6)
    local action = values[3]
    MySQL.insert(M.INSERT_SQL:format(marks), params, function(id)
        if not id then Core.error('audit insert failed for %s', action) end
    end)
    return true
end

--- Actor of a player id: citizenid from qbx_core (never from the client), Discord id from the identifiers.
function M.actorOf(src)
    src = tonumber(src) or 0
    if src <= 0 then return nil, nil end
    local pd = Core.getPlayerData(src)
    return pd and pd.citizenid or nil, Perms.getDiscordId(src)
end

--- export audit(src, action, targetType, targetId, meta). src 0 = system.
function M.audit(src, action, targetType, targetId, meta)
    local citizenid, discordId = M.actorOf(src)
    return M.write({
        actorCitizenid = citizenid, actorDiscord = discordId, action = action,
        targetType = targetType, targetId = targetId, meta = meta,
    })
end

--- Move audit rows older than `days` to fredpd_audit_archive in batches (awaits; run it in a thread). Each batch is
--- one transaction (copy + delete of the same ids), against one fixed cutoff. Returns the number of rows moved.
--- @param days integer >= 1
--- @param batch integer|nil rows per transaction (default 5000)
--- @param src integer|nil who ran it (audit actor; nil/0 = system)
--- @return integer
function M.archiveOlderThan(days, batch, src)
    days = math.tointeger(tonumber(days))
    if not days or days < 1 then error('days must be a positive integer', 0) end
    batch = math.tointeger(batch) or M.ARCHIVE_BATCH
    -- created_at is UTC (DEFAULT (UTC_TIMESTAMP()), docs/contracts.md §C7), so the cutoff is too, whatever the
    -- session time zone is. Read as text: oxmysql would turn a DATETIME into host-local epoch milliseconds.
    local cutoff = MySQL.scalar.await(
        "SELECT DATE_FORMAT(UTC_TIMESTAMP() - INTERVAL ? DAY, '%Y-%m-%d %H:%i:%s')", { days })
    if type(cutoff) ~= 'string' then error('could not compute the cutoff', 0) end

    local moved = 0
    local limit = ('%d'):format(batch)
    -- Bounded: each pass moves up to `batch` rows; 10 000 passes covers 50 M rows.
    for _ = 1, 10000 do
        local hi = MySQL.scalar.await('SELECT MAX(id) FROM (SELECT id FROM fredpd_audit WHERE created_at < ? '
            .. 'ORDER BY id LIMIT ' .. limit .. ') AS batch', { cutoff })
        hi = tonumber(hi)
        if not hi then break end
        local n = tonumber(MySQL.scalar.await(
            'SELECT COUNT(*) FROM fredpd_audit WHERE id <= ? AND created_at < ?', { hi, cutoff })) or 0
        local ok = MySQL.transaction.await({
            {
                query = 'INSERT INTO fredpd_audit_archive (id, actor_citizenid, actor_discord, action, target_type, '
                    .. 'target_id, meta, created_at) SELECT id, actor_citizenid, actor_discord, action, target_type, '
                    .. 'target_id, meta, created_at FROM fredpd_audit WHERE id <= ? AND created_at < ?',
                values = { hi, cutoff },
            },
            { query = 'DELETE FROM fredpd_audit WHERE id <= ? AND created_at < ?', values = { hi, cutoff } },
        })
        if not ok then error(('archive transaction failed after %d rows'):format(moved), 0) end
        moved = moved + n
    end
    M.audit(src or 0, 'audit.archive', 'audit', nil, { days = days, moved = moved, cutoff = Time.toIsoUtc(cutoff) })
    return moved
end

--- Reply to a command caller: console print for src 0, ox_lib notify for a player.
local function reply(src, kind, text)
    if src and src > 0 then
        Core.notify(src, { type = kind, description = text })
    else
        print(text)
    end
end

function M.register()
    exports('audit', M.audit)

    local L = Locale.L
    lib.addCommand('fredpd_audit_archive', {
        help = L('core.command.auditArchive'),
        params = { { name = 'days', type = 'number', help = L('core.param.days'), optional = true } },
        restricted = 'group.admin',
    }, function(source, args)
        local src = tonumber(source) or 0
        local days = math.tointeger(tonumber(args.days)) or M.DEFAULT_ARCHIVE_DAYS
        if days < 1 then
            reply(src, 'error', L('core.auditArchive.invalidDays'))
            return
        end
        Core.async('audit archive', function()
            local ok, moved = pcall(M.archiveOlderThan, days, nil, src)
            if ok then
                Core.info('archived %d audit rows older than %d days', moved, days)
                reply(src, 'success', L('core.auditArchive.done', { count = moved, days = days }))
            else
                Core.error('audit archive failed: %s', tostring(moved))
                reply(src, 'error', L('core.auditArchive.failed'))
            end
        end)
    end)
end

return M
