-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_breach client (IMPLEMENTATION.md §5.6, docs/modules/breach.md). Event-driven only:
--   * the ox_doorlock door list comes once from ox_doorlock's own callback 'ox_doorlock:getDoors' (the way
--     ox_doorlock's client gets it, ox_doorlock client/main.lua:37) and is kept current by the same client events
--     ox_doorlock listens to ('ox_doorlock:setState' 117, 'ox_doorlock:editDoorlock' 195);
--   * one global ox_target object option "Forcera dörr", added once at start. ox_doorlock tags the door entities it
--     manages with the local statebag key doorId (client/main.lua:61, 101); canInteract reads it and shows the
--     option only for a locked door while the player carries pd_ram and holds grant tool:ram (hints only: the
--     server re-checks everything);
--   * selecting it: server callback fredpd:breach:start → lib.progressBar (4 s, anim + ram prop attached only while
--     the bar runs) → fredpd:breach:finish with the one-time token.

local L = require('@fredpd_core.shared.locale').L
local Grants = require '@fredpd_core.shared.grants'
local Config = require 'config'

local M = {}

M.OPTION = 'fredpd_breach:ram'
M.doors = {}       -- [doorId] = state (1 locked, 0 unlocked)
M.grants = nil     -- client copy of the GrantSet (fredpd:getMyGrants / fredpd:client:grantsChanged)
local busy = false

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

function M.hasItemHint()
    local okCall, count = pcall(function() return exports.ox_inventory:GetItemCount(Config.ramItem) end)
    return okCall and (tonumber(count) or 0) > 0
end

--- Door id ox_doorlock tagged this entity with, or nil.
function M.doorIdOf(entity)
    if not entity or entity == 0 then return nil end
    local okCall, id = pcall(function() return Entity(entity).state.doorId end)
    return okCall and math.tointeger(tonumber(id)) or nil
end

function M.canInteract(entity)
    if busy then return false end
    local id = M.doorIdOf(entity)
    if not id or M.doors[id] ~= 1 then return false end
    return M.hasGrantHint() and M.hasItemHint()
end

---------------------------------------------------------------------------------------------------------------
-- Door list (ox_doorlock)

function M.setDoors(data)
    M.doors = {}
    for id, door in pairs(type(data) == 'table' and data or {}) do
        local key = math.tointeger(tonumber(type(door) == 'table' and door.id or id))
        if key and type(door) == 'table' then M.doors[key] = door.state end
    end
end

RegisterNetEvent('ox_doorlock:setState', function(id, state, _source, data)
    id = math.tointeger(tonumber(id))
    if not id then return end
    if type(data) == 'table' and data.state ~= nil and state == nil then state = data.state end
    M.doors[id] = state
end)

RegisterNetEvent('ox_doorlock:editDoorlock', function(id, data)
    id = math.tointeger(tonumber(id))
    if not id then return end
    if type(data) == 'table' then M.doors[id] = data.state or 0 else M.doors[id] = nil end
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

function M.breach(entity)
    if busy then return end
    local doorId = M.doorIdOf(entity)
    if not doorId then return end
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
        M.doors[doorId] = 0
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
end

RegisterNetEvent('fredpd:client:grantsChanged', function(set)
    if type(set) == 'table' then M.grants = set end
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    refreshGrants()
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    M.grants = nil
end)

function M.start()
    exports.ox_target:addGlobalObject({
        {
            name = M.OPTION,
            label = L('breach.target'),
            icon = 'fa-solid fa-door-open',
            distance = Config.targetDistance or 2.0,
            canInteract = function(entity) return M.canInteract(entity) end,
            onSelect = function(data)
                local entity = type(data) == 'table' and data.entity or nil
                CreateThread(function() M.breach(entity) end)
            end,
        },
    })
    lib.callback('ox_doorlock:getDoors', false, function(data)
        M.setDoors(data)
    end)
    CreateThread(refreshGrants)
end

AddEventHandler('onClientResourceStart', function(resource)
    -- ox_doorlock restarted: it re-sends nothing on its own, so ask for the list again.
    if resource == 'ox_doorlock' then
        lib.callback('ox_doorlock:getDoors', false, function(data) M.setDoors(data) end)
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        pcall(function() exports.ox_target:removeGlobalObject(M.OPTION) end)
    end
end)

M.start()

return M
