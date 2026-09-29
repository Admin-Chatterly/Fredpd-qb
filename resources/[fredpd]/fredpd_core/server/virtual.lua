-- SPDX-License-Identifier: GPL-3.0-only
-- Portal actors (docs/modules/portal-api.md, IMPLEMENTATION.md §5.9 task 7.1). A portal request runs fredpd_mdt's
-- action dispatcher for a Discord user acting as one of their characters, without a player in the world. The other
-- FredPD resources only know player ids: they ask fredpd_core for grants, citizenid, duty and audit by `src`. So the
-- portal user gets a stand-in id (>= Core.VIRTUAL_BASE, never a FiveM player id) for which
--   * hasGrant / getGrants / getTier / getUnits answer the GrantSet the service resolved for that Discord id (sent in
--     the HMAC-signed request, validated here like a /grants push);
--   * getCitizenId answers the character the service checked the user owns (and that has a fredpd_officers row of
--     that Discord user, checked again here); isOnDuty answers true (the portal has no
--     duty); getOfficer answers that character's officer row;
--   * audit rows carry the character, the Discord id and meta.via = 'portal';
--   * the framework bridge (getPlayer, inventory) answers nil/0, and natives find no ped: world actions cannot work
--     (fredpd_mdt refuses them before routing anyway).
-- One id per (Discord id, citizenid), reused while in use (rate limits keyed by src stay per user) and released after
-- IDLE_MS without a request by a one-shot SetTimeout (armed only while the actor exists; no polling).
--
-- Export (internal: fredpd_core itself and fredpd_mdt only): portalActor(discordId, citizenid, grants) -> src | false.

local Core = require 'server.core'
local Perms = require 'server.perms'
local Officers = require 'server.officers'

local M = {}

M.IDLE_MS = 10 * 60 * 1000
M.MAX_ACTORS = 5000
M.CALLERS = { 'fredpd_mdt' }

local ByKey = {}   -- ['<discordId>|<citizenid>'] = src
local LastUse = {} -- [src] = Core.now() of the last begin()
local Armed = {}   -- [src] = true while a release timer is pending
local count = 0
local nextId = Core.VIRTUAL_BASE

local DISCORD_PATTERN = '^%d+$'
local CITIZEN_PATTERN = '^[%w_%-]+$'

local function arm(src, delay)
    if Armed[src] then return end
    Armed[src] = true
    SetTimeout(delay, function()
        Armed[src] = nil
        local last = LastUse[src]
        if not last then return end
        local idle = Core.now() - last
        if idle >= M.IDLE_MS then
            M.release(src)
        else
            arm(src, M.IDLE_MS - idle)
        end
    end)
end

--- Forget a portal actor (idle timeout or tests).
function M.release(src)
    local actor = Core.virtualActor(src)
    if not actor then return false end
    ByKey[actor.discordId .. '|' .. actor.citizenid] = nil
    LastUse[src] = nil
    Core.setVirtualActor(src, nil)
    Perms.clearVirtual(src)
    Core.clearRateLimits(src)
    count = count - 1
    TriggerEvent('fredpd:portalActorReleased', src)
    return true
end

--- The actor id for a portal request, with its grants refreshed. nil and a reason ('discordId' | 'citizenid' |
--- 'grants:<field>' | 'not_officer' | 'full') for bad input. The character must be a police character of that
--- Discord user (a fredpd_officers row with its discord_id): the service checks the same, this is the FXServer's
--- own check (a civilian alt never acts as police).
--- @param discordId string
--- @param citizenid string character the service verified the user owns (fredpd_identities license)
--- @param grants table GrantSet the service resolved for discordId (§C2)
--- @return integer|nil, string|nil
function M.begin(discordId, citizenid, grants)
    if type(discordId) ~= 'string' or #discordId > 20 or not discordId:match(DISCORD_PATTERN) then
        return nil, 'discordId'
    end
    if type(citizenid) ~= 'string' or #citizenid > 50 or not citizenid:match(CITIZEN_PATTERN) then
        return nil, 'citizenid'
    end
    local set, field = Perms.validateSet(grants)
    if not set then return nil, 'grants:' .. tostring(field) end
    if not Officers.isOfficerOf(citizenid, discordId) then return nil, 'not_officer' end

    local key = discordId .. '|' .. citizenid
    local src = ByKey[key]
    if not src then
        if count >= M.MAX_ACTORS then return nil, 'full' end
        src = nextId
        nextId = nextId + 1
        ByKey[key] = src
        count = count + 1
        Core.setVirtualActor(src, {
            discordId = discordId,
            citizenid = citizenid,
            player = {
                source = src, citizenid = citizenid, license = nil, name = citizenid, virtual = true,
                job = { name = 'police', label = 'Polis', type = 'leo', grade = 0, onduty = true },
                charinfo = {},
            },
        })
    end
    Perms.setVirtual(src, discordId, set)
    LastUse[src] = Core.now()
    arm(src, M.IDLE_MS)
    return src
end

--- Tests only: number of live actors.
function M.count()
    return count
end

function M.register()
    Core.internalExport('portalActor', function(discordId, citizenid, grants)
        local src, reason = M.begin(discordId, citizenid, grants)
        if not src then
            Core.warn('portalActor refused (%s)', tostring(reason))
            return false
        end
        return src
    end, M.CALLERS)
end

return M
