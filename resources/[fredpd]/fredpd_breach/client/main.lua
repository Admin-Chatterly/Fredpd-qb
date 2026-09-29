-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_breach client (IMPLEMENTATION.md §5.6, docs/modules/breach.md). Doorlock and target go through fredpd_core's
-- bridge (FredBridge, '@fredpd_core/bridge/client.lua'; qb-doorlock/ox_doorlock, qb-target/ox_target,
-- docs/contracts.md §C17). Event-driven only:
--   * the door list comes from FredBridge.doorlock.listDoors() at start, when the doorlock resource (re)starts and
--     after the character loads (the server sends fredpd:breach:client:character; qb-doorlock fills its client list
--     only then), and is kept current by FredBridge.doorlock.onDoorChanged; a change for an unknown door (one made
--     in game) re-reads the list once;
--   * one target box zone per door with the option "Forcera dörr", only while the player holds grant tool:ram
--     (civilians get no zones at all). canInteract shows it for a locked door (hints only: the server re-checks
--     grant, duty, pd_ram, the door and the distance);
--   * selecting it: server callback fredpd:breach:start → lib.progressBar (4 s, anim + ram prop attached only while
--     the bar runs) → fredpd:breach:finish with the one-time token.

local L = require('@fredpd_core.shared.locale').L
local Grants = require '@fredpd_core.shared.grants'
local Config = require 'config'

local M = {}

M.OPTION = 'fredpd_breach:ram'
M.ZONE_PREFIX = 'fredpd_breach:door:'

--- Zone name of a door; the id type is part of it so qb-doorlock keys 1 and '1' never share a zone.
function M.zoneName(doorId)
    return M.ZONE_PREFIX .. type(doorId) .. ':' .. tostring(doorId)
end
M.doors = {}       -- [doorId] = { name, locked, coords } (FredBridge.doorlock.listDoors)
M.zones = {}       -- [doorId] = FredBridge.target handle
M.grants = nil     -- client copy of the GrantSet (fredpd:getMyGrants / fredpd:client:grantsChanged)
local busy = false
local listing, listAgain = false, false

local function notify(kind, text)
    lib.notify({ type = kind, description = text })
end

--- Player text for a server error.
function M.errorText(res)
    local e, r = type(res) == 'table' and res.error or nil, type(res) == 'table' and res.reason or nil
    if e == 'unauthorized' and r == 'off_duty' then return L('errors.notOnDuty') end
    if e == 'unauthorized' then return L('breach.noGrant') end
    if e == 'rate_limited' and r == 'cooldown' then return L('breach.cooldown') end
    if e == 'rate_limited' then return L('errors.rateLimited') end
    if e == 'validation' and r == 'no_item' then return L('breach.noItem') end
    if e == 'validation' and r == 'not_locked' then return L('breach.notLocked') end
    if e == 'validation' and r == 'too_far' then return L('breach.tooFar') end
    if (e == 'not_found' and r == 'door') or (e == 'validation' and r == 'denied') then return L('breach.notSupported') end
    if e == 'expired' or (e == 'not_found' and r == 'token') or r == 'too_early' then return L('breach.expired') end
    return L('errors.unknown')
end

---------------------------------------------------------------------------------------------------------------
-- Hints for canInteract (never trusted by the server)

function M.hasGrantHint()
    local g = Config.grant or { 'tool', 'ram' }
    return M.grants ~= nil and Grants.has(M.grants, g[1], g[2]) == true
end

function M.canInteract(doorId)
    if busy then return false end
    local door = M.doors[doorId]
    if not door or door.locked ~= true then return false end
    return M.hasGrantHint()
end

---------------------------------------------------------------------------------------------------------------
-- Target zones (one per door, grant holders only)

function M.addZone(doorId)
    if M.zones[doorId] then return end
    local door = M.doors[doorId]
    if not door or door.coords == nil then return end
    M.zones[doorId] = FredBridge.target.addBoxZone(M.zoneName(doorId), {
        coords = door.coords,
        size = Config.doorZoneSize or vec3(1.6, 1.6, 2.6),
    }, {
        name = M.OPTION,
        label = L('breach.target'),
        icon = 'fa-solid fa-door-open',
        distance = Config.targetDistance or 2.0,
        canInteract = function() return M.canInteract(doorId) end,
        onSelect = function() CreateThread(function() M.breach(doorId) end) end,
    })
end

function M.removeZones()
    local zones = M.zones
    M.zones = {}
    for _, handle in pairs(zones) do pcall(FredBridge.target.remove, handle) end
end

--- Zones follow the door list and the grant: every known door while the player holds tool:ram, none otherwise.
function M.syncZones()
    if not M.hasGrantHint() or not FredBridge.target.available() then
        M.removeZones()
        return
    end
    for id, handle in pairs(M.zones) do
        if not M.doors[id] then
            M.zones[id] = nil
            pcall(FredBridge.target.remove, handle)
        end
    end
    for id in pairs(M.doors) do M.addZone(id) end
end

---------------------------------------------------------------------------------------------------------------
-- Door list (FredBridge.doorlock)

--- list = { { id, name, locked, coords }, ... }
function M.setDoors(list)
    M.doors = {}
    for _, door in ipairs(type(list) == 'table' and list or {}) do
        if type(door) == 'table' and door.id ~= nil then
            M.doors[door.id] = { name = door.name, locked = door.locked == true, coords = door.coords }
        end
    end
    M.syncZones()
end

--- Read the door list in a thread (ox_doorlock answers through a server callback). Calls while one read runs are
--- folded into one more read after it.
function M.reloadDoors()
    if listing then
        listAgain = true
        return
    end
    listing = true
    CreateThread(function()
        repeat
            listAgain = false
            local okList, list = pcall(FredBridge.doorlock.listDoors)
            if okList then M.setDoors(list) end
        until not listAgain
        listing = false
    end)
end

FredBridge.doorlock.onDoorChanged(function(id, locked)
    local door = M.doors[id]
    if door then
        door.locked = locked == true
    else
        M.reloadDoors() -- a door created in game after the list was read
    end
end)

---------------------------------------------------------------------------------------------------------------
-- Breach

--- The first configured animation whose dict and clip exist here, or nil.
function M.pickAnim()
    for _, a in ipairs(Config.anims or {}) do
        if type(a.dict) == 'string' and DoesAnimDictExist(a.dict) then
            local okLoad = pcall(lib.requestAnimDict, a.dict, 2000)
            if okLoad and GetAnimDuration(a.dict, a.clip) > 0 then
                return { dict = a.dict, clip = a.clip, flag = a.flag or 49 }
            end
            RemoveAnimDict(a.dict)
        end
    end
    return nil
end

function M.breach(doorId)
    if busy or doorId == nil then return end
    busy = true
    local okStart, res = pcall(lib.callback.await, 'fredpd:breach:start', false, doorId)
    if not okStart or type(res) ~= 'table' or not res.ok then
        busy = false
        notify('error', M.errorText(okStart and res or nil))
        return
    end
    local anim = M.pickAnim()
    local done = lib.progressBar({
        duration = res.data.durationMs or Config.progressMs,
        label = L('breach.progress'),
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim = anim,
        prop = {
            model = Config.ramModel,
            bone = Config.ramBone,
            pos = Config.ramPos,
            rot = Config.ramRot,
        },
    })
    if anim then RemoveAnimDict(anim.dict) end
    if not done then
        busy = false
        notify('inform', L('breach.cancelled'))
        return
    end
    local okFinish, fin = pcall(lib.callback.await, 'fredpd:breach:finish', false, res.data.token)
    busy = false
    if okFinish and type(fin) == 'table' and fin.ok then
        if M.doors[doorId] then M.doors[doorId].locked = false end
        notify('success', L('breach.success'))
    else
        notify('error', M.errorText(okFinish and fin or nil))
    end
end

---------------------------------------------------------------------------------------------------------------
-- Start

local function refreshGrants()
    local okCall, set = pcall(lib.callback.await, 'fredpd:getMyGrants', false)
    if okCall and type(set) == 'table' then M.grants = set end
    M.syncZones()
end

RegisterNetEvent('fredpd:client:grantsChanged', function(set)
    if type(set) == 'table' then M.grants = set end
    M.syncZones()
end)

-- Sent by this resource's server on fredpd:bridge:playerLoaded / playerUnloaded (qb-core or qbx_core).
RegisterNetEvent('fredpd:breach:client:character', function(loaded)
    if loaded then
        CreateThread(refreshGrants)
        -- qb-doorlock fills its client door list from a server callback on the same load: read ours after it.
        SetTimeout(Config.doorReloadDelayMs or 2000, M.reloadDoors)
    else
        M.grants = nil
        M.removeZones()
    end
end)

function M.start()
    M.reloadDoors()
    CreateThread(refreshGrants)
end

AddEventHandler('onClientResourceStart', function(resource)
    if resource == FredBridge.doorlock.resource then
        M.reloadDoors() -- the doorlock resource restarted: it re-sends nothing on its own
    elseif resource == FredBridge.target.resource then
        M.zones = {} -- the target resource starts with empty lists
        M.syncZones()
    end
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        M.removeZones()
    elseif resource == FredBridge.target.resource then
        M.zones = {}
    end
end)

M.start()

return M
