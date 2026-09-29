-- SPDX-License-Identifier: GPL-3.0-only
-- Officer identity on the FXServer side (IMPLEMENTATION.md §4.9, task 1.7b). The displayed name of an officer comes
-- from Discord, never from the character: the bot upserts display_name/avatar in fredpd_officers and pushes changes
-- to POST /officer (http.js -> setOfficerIdentity), which updates the in-memory copy here within the same tick.
--
-- This module also
--   * creates the fredpd_officers row of a police character the first time it loads (the bot cannot know the
--     citizenid), without touching the Discord-owned columns of an existing row;
--   * generates the callsign on first duty: formats.json `callsign` with {{unit}} = the units.json callsign prefix of
--     the officer's primary unit (first unit grant in units.json order) and {{n}} = the lowest free number in that
--     unit. uq_unit_callsign makes a concurrent allocation fail, which is retried;
--   * mirrors config/units.json into fredpd_units at start.

local Format = require 'shared.format'
local Locale = require 'shared.locale'
local Core = require 'server.core'
local Perms = require 'server.perms'
local Audit = require 'server.audit'

local M = {}

M.MAX_NAME_CHARS = 100 -- fredpd_officers.display_name VARCHAR(100) utf8mb4 counts characters, not bytes

local ByCitizen = {} -- [citizenid] = officer (see rowToOfficer)
local Names = {}     -- [discordId] = { displayName, avatarUrl } from /officer pushes (newer than the DB)
local Pending = {}   -- [citizenid] = true while a callsign allocation runs

M.MAX_ATTEMPTS = 5
M.MAX_CITIZENID = 50 -- fredpd_officers.citizenid VARCHAR(50); INSERT IGNORE would truncate a longer key silently
M.SELECT_SQL = 'SELECT citizenid, discord_id, display_name, avatar_url, callsign, unit, rank_role_id FROM fredpd_officers'
-- Creation is detected with INSERT IGNORE, never from the affectedRows of INSERT ... ON DUPLICATE KEY UPDATE:
-- oxmysql runs mysql2 with CLIENT_FOUND_ROWS, so an upsert that matches an unchanged row also reports 1.
-- INSERT IGNORE reports 1 only for an inserted row and 0 for a duplicate, with or without FOUND_ROWS.
M.INSERT_ROW_SQL = 'INSERT IGNORE INTO fredpd_officers (citizenid, discord_id, display_name) VALUES (?, ?, ?)'
-- The condition makes affectedRows mean "changed" under FOUND_ROWS too (discord_id is NOT NULL).
M.RELINK_SQL = 'UPDATE fredpd_officers SET discord_id = ? WHERE citizenid = ? AND discord_id <> ?'
-- Runs after INSERT_ROW_SQL, so the row exists. An existing callsign is never overwritten (callsign IS NULL). If the
-- candidate was taken meanwhile, uq_unit_callsign makes the UPDATE fail and ensureCallsign retries with a fresh list;
-- the result is read back with loadOne, so affectedRows is not needed here either.
M.CALLSIGN_SQL = 'UPDATE fredpd_officers SET unit = ?, callsign = ? WHERE citizenid = ? AND callsign IS NULL'

---------------------------------------------------------------------------------------------------------------
-- Pure helpers (tests/lua/core_officers_test.lua)

function M.rowToOfficer(row)
    if type(row) ~= 'table' or row.citizenid == nil then return nil end
    local function str(v) return (v ~= nil and type(v) ~= 'userdata') and tostring(v) or nil end
    return {
        citizenid = tostring(row.citizenid),
        discordId = str(row.discord_id),
        displayName = str(row.display_name),
        avatarUrl = str(row.avatar_url),
        callsign = str(row.callsign),
        unit = str(row.unit),
        rankRoleId = str(row.rank_role_id),
    }
end

--- Primary unit: the held unit that comes first in units.json order (unknown codes last, as held).
--- @param held string[] unit codes from the grant set
--- @param order string[] unit codes in units.json order
function M.primaryUnit(held, order)
    local index = {}
    for i, code in ipairs(order or {}) do
        if index[code] == nil then index[code] = i end
    end
    local best, bestIndex = nil, math.huge
    for _, code in ipairs(held or {}) do
        local i = index[code] or math.huge
        if best == nil or i < bestIndex then best, bestIndex = code, i end
    end
    return best
end

--- A display name cut to at most `max` characters (UTF-8 aware, never splits a character). nil when `name` is not
--- a non-empty valid UTF-8 string.
function M.clampName(name, max)
    if type(name) ~= 'string' or name == '' or not utf8.len(name) then return nil end
    local cut = utf8.offset(name, (max or M.MAX_NAME_CHARS) + 1)
    return cut and name:sub(1, cut - 1) or name
end

--- Lowest free callsign: formatId(template, { unit = prefix, n = 1, 2, ... }) not in `taken` (a set of strings).
--- Raises the format error (e.g. a template needing {{seq}}) so a misconfiguration is visible.
--- @return string callsign, integer n
function M.nextCallsign(template, prefix, taken)
    local count = 0
    for _ in pairs(taken) do count = count + 1 end
    for n = 1, count + 1 do
        local callsign = Format.formatId(template, { unit = prefix, n = n })
        if not taken[callsign] then return callsign, n end
    end
    error('no free callsign', 0) -- unreachable: count + 1 candidates cannot all be taken
end

---------------------------------------------------------------------------------------------------------------
-- Player access

local function isLeo(pd)
    return type(pd) == 'table' and type(pd.job) == 'table' and pd.job.type == 'leo'
end

function M.getCitizenId(src)
    local pd = Core.getPlayerData(src)
    return pd and pd.citizenid or nil
end

--- qbx: job.type == 'leo' and job.onduty.
function M.isOnDuty(src)
    local pd = Core.getPlayerData(src)
    return isLeo(pd) and pd.job.onduty == true
end

--- Name to show for an officer: the latest Discord push, else the stored display_name.
local function resolved(officer)
    local pushed = officer.discordId and Names[officer.discordId]
    local out = {}
    for k, v in pairs(officer) do out[k] = v end
    if pushed then
        out.displayName = pushed.displayName
        out.avatarUrl = pushed.avatarUrl
    end
    return out
end

--- Officer record of the player's current character, or nil when the character is not a known officer.
--- { citizenid, discordId, displayName, avatarUrl, callsign, unit, rankRoleId, rankKey }
--- The rank comes from the player's live grant set (a rank change arrives with the next /grants push); the stored
--- rank_role_id is only used until the grants have loaded.
function M.getOfficer(src)
    local cid = M.getCitizenId(src)
    local officer = cid and ByCitizen[cid]
    if not officer then return nil end
    local out = resolved(officer)
    local set = Perms.rawSet(src)
    if set then
        out.rankRoleId = set.rank and set.rank.roleId or nil
        out.rankKey = set.rank and set.rank.key or nil
    end
    return out
end

---------------------------------------------------------------------------------------------------------------
-- Database (await; call from a thread)

function M.loadAll()
    local ok, rows = pcall(MySQL.query.await, M.SELECT_SQL)
    if not ok or type(rows) ~= 'table' then
        Core.error('could not load fredpd_officers: %s', tostring(rows))
        return false
    end
    local fresh = {}
    for _, row in ipairs(rows) do
        local o = M.rowToOfficer(row)
        if o then fresh[o.citizenid] = o end
    end
    ByCitizen = fresh
    return true
end

function M.loadOne(citizenid)
    local row = MySQL.single.await(M.SELECT_SQL .. ' WHERE citizenid = ?', { citizenid })
    local o = M.rowToOfficer(row)
    ByCitizen[citizenid] = o
    return o
end

--- A display name for a new row (display_name is NOT NULL): the Discord push if we have one, else the FiveM
--- player name (the account name, not the character name) until the bot fills in the real one.
local function placeholderName(src, discordId)
    local pushed = Names[discordId]
    if pushed then return pushed.displayName end
    return M.clampName(GetPlayerName(tostring(src))) or discordId
end

--- Create the character's fredpd_officers row if it has none. A new row is a roster record and is audited once
--- (system actor: the character did not ask for it). Returns true when this call inserted the row.
local function insertRow(src, cid, discordId, via)
    local affected = MySQL.update.await(M.INSERT_ROW_SQL, { cid, discordId, placeholderName(src, discordId) })
    if tonumber(affected) ~= 1 then return false end
    Audit.write({ action = 'officer.create', targetType = 'officer', targetId = cid,
        meta = { discordId = discordId, auto = true, via = via } })
    return true
end

local function validCitizenId(cid)
    return type(cid) == 'string' and cid ~= '' and #cid <= M.MAX_CITIZENID
end

--- Called when a police character loads: make sure it has a fredpd_officers row, and that the row points at the
--- Discord account the player is using now (the Discord-owned name columns are left alone).
function M.ensureRow(src, pd)
    if not isLeo(pd) or not validCitizenId(pd.citizenid) then return nil end
    local cid = pd.citizenid
    local discordId = Perms.getDiscordId(src)
    if not discordId then return nil end
    if not insertRow(src, cid, discordId, 'load') then
        local changed = MySQL.update.await(M.RELINK_SQL, { discordId, cid, discordId })
        if tonumber(changed) == 1 then
            Audit.write({ action = 'officer.relink', targetType = 'officer', targetId = cid,
                meta = { discordId = discordId, auto = true } })
        end
    end
    return M.loadOne(cid)
end

--- Give the player's police character a callsign if it has none (first duty). Returns the callsign, or nil and a
--- reason: not_police | no_discord | no_unit | unknown_unit | no_template | busy | failed.
function M.ensureCallsign(src)
    local pd = Core.getPlayerData(src)
    if not isLeo(pd) or not validCitizenId(pd.citizenid) then return nil, 'not_police' end
    local cid = pd.citizenid
    local officer = ByCitizen[cid] or M.loadOne(cid)
    if officer and officer.callsign then return officer.callsign end
    if Pending[cid] then return nil, 'busy' end

    local discordId = Perms.getDiscordId(src)
    if not discordId then return nil, 'no_discord' end
    local unit = M.primaryUnit(Perms.getUnits(src), Core.config.unitOrder)
    if not unit then
        Core.warn('player %d (%s) has no unit grant: no callsign', src, cid)
        return nil, 'no_unit'
    end
    local unitCfg = Core.config.unitsByCode and Core.config.unitsByCode[unit]
    local prefix = unitCfg and unitCfg.callsign
    if type(prefix) ~= 'string' then
        Core.warn('unit %s has no callsign prefix in config/units.json', unit)
        return nil, 'unknown_unit'
    end
    local formats = Format.get()
    local template = formats and formats.callsign
    if type(template) ~= 'string' then return nil, 'no_template' end

    local function allocate()
        local lastErr = nil
        for _ = 1, M.MAX_ATTEMPTS do
            local taken = {}
            for _, r in ipairs(MySQL.query.await(
                'SELECT callsign FROM fredpd_officers WHERE unit = ? AND callsign IS NOT NULL', { unit }) or {}) do
                taken[tostring(r.callsign)] = true
            end
            local candidate = M.nextCallsign(template, prefix, taken) -- a template error is final
            -- Inside the loop so a row deleted meanwhile is recreated (and audited as new) instead of failing.
            insertRow(src, cid, discordId, 'duty')
            local ok, err = pcall(MySQL.update.await, M.CALLSIGN_SQL, { unit, candidate, cid })
            if ok then
                local row = M.loadOne(cid)
                if row and row.callsign then return row.callsign end
            else
                lastErr = err -- most likely uq_unit_callsign: someone else took it; recompute
            end
        end
        error(lastErr or 'no attempt succeeded', 0)
    end

    Pending[cid] = true
    local ok, callsign = pcall(allocate)
    Pending[cid] = nil

    if not ok then
        Core.error('callsign allocation for %s failed: %s', cid, tostring(callsign))
        return nil, 'failed'
    end
    Audit.write({ action = 'officer.callsign', targetType = 'officer', targetId = cid,
        meta = { callsign = callsign, unit = unit, auto = true } })
    Core.notify(src, { type = 'inform', description = Locale.L('officer.callsignAssigned', { callsign = callsign }) })
    TriggerEvent('fredpd:officerChanged', cid)
    return callsign
end

--- config/units.json -> fredpd_units (codes missing from the config are deactivated, never deleted).
function M.syncUnits(unitsConfig)
    local rows, codes = {}, {}
    for i, u in ipairs(type(unitsConfig) == 'table' and unitsConfig.units or {}) do
        if type(u) == 'table' and type(u.code) == 'string' and type(u.callsign) == 'string' then
            rows[#rows + 1] = {
                code = u.code, callsign_prefix = u.callsign, label_key = u.labelKey or ('unit.' .. u.code),
                home = u.home, sort_order = i, active = 1,
            }
            codes[#codes + 1] = u.code
        end
    end
    if #rows == 0 then return 0 end
    local sql, params = Core.buildInsert('fredpd_units',
        { 'code', 'callsign_prefix', 'label_key', 'home', 'sort_order', 'active' }, rows,
        { 'callsign_prefix', 'label_key', 'home', 'sort_order', 'active' })
    MySQL.update.await(sql, params)
    MySQL.update.await('UPDATE fredpd_units SET active = 0 WHERE code NOT IN (' .. ('?, '):rep(#codes):sub(1, -3) .. ')',
        codes)
    return #rows
end

---------------------------------------------------------------------------------------------------------------
-- Push from the service (POST /officer). Synchronous: memory only (the bot writes the table).

--- @return integer|false number of known characters of that Discord user updated, false for invalid input
function M.setIdentity(discordId, displayName, avatarUrl)
    if type(discordId) ~= 'string' or not discordId:match('^%d+$') or #discordId > 20 then return false end
    -- Characters, like the column and http.js; utf8.len is nil for invalid UTF-8.
    local chars = type(displayName) == 'string' and utf8.len(displayName) or nil
    if not chars or chars == 0 or chars > M.MAX_NAME_CHARS then return false end
    if avatarUrl ~= nil and (type(avatarUrl) ~= 'string' or #avatarUrl > 255) then avatarUrl = nil end
    Names[discordId] = { displayName = displayName, avatarUrl = avatarUrl }
    local n = 0
    for cid, o in pairs(ByCitizen) do
        if o.discordId == discordId then
            o.displayName, o.avatarUrl = displayName, avatarUrl
            n = n + 1
            TriggerEvent('fredpd:officerChanged', cid)
        end
    end
    return n
end

---------------------------------------------------------------------------------------------------------------
-- Wiring

--- Character loaded: officer row, then a callsign if the character is already on duty.
function M.onCharacter(src)
    local pd = Core.getPlayerData(src)
    if not isLeo(pd) then return end
    M.ensureRow(src, pd)
    if pd.job.onduty == true then M.ensureCallsign(src) end
end

function M.register()
    exports('getOfficer', M.getOfficer)
    exports('isOnDuty', M.isOnDuty)
    exports('getCitizenId', M.getCitizenId)
    exports('setOfficerIdentity', M.setIdentity)
    -- For duty scripts that know better when duty starts; runs in a thread of its own and returns immediately.
    exports('ensureCallsign', function(src)
        src = tonumber(src)
        if src then Core.async('callsign', M.ensureCallsign, src) end
    end)

    -- VERIFY (docs/modules/core.md): qbx_core event names. AddEventHandler only (no client may trigger these).
    AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
        local src = type(player) == 'table' and type(player.PlayerData) == 'table' and tonumber(player.PlayerData.source)
        if src then Core.async('officer on load', M.onCharacter, src) end
    end)
    AddEventHandler('QBCore:Server:SetDuty', function(src, onDuty)
        src = tonumber(src)
        if src and onDuty then Core.async('callsign on duty', M.ensureCallsign, src) end
    end)
    AddEventHandler('QBCore:Server:OnJobUpdate', function(src, job)
        src = tonumber(src)
        if src and type(job) == 'table' and job.type == 'leo' then Core.async('officer on job', M.onCharacter, src) end
    end)
end

return M
