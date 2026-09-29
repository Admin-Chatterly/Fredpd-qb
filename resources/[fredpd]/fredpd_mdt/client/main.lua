-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_mdt client: opens and closes the tablet NUI (IMPLEMENTATION.md §5.2, §8.3; docs/modules/mdt.md).
--
-- open(mode): lib.callback 'fredpd:mdt:open' (the server checks item, grant, duty, serial) -> NUI focus + the
-- `open` message (docs/modules/ui.md) -> in item mode the tablet prop in the right hand with the tablet animation.
-- close(): focus released, `close` message, prop deleted, animation stopped, server told (fredpd:mdt:closed).
--
-- Focus-trap safety (§8.3): the tablet closes on the NUI `close` callback (Esc and the close button), on the
-- server's fredpd:client:forceClose (also sent on logout, fredpd:bridge:playerUnloaded), on death (gameEventTriggered
-- CEventNetworkEntityDamage, baseevents, the `isDead` player state), when leaving the vehicle it was opened in as a
-- terminal (lib.onCache('vehicle')) and when this resource stops.
--
-- Framework, inventory and target go through fredpd_core's bridge only (docs/contracts.md §C17): FredBridge.* from
-- '@fredpd_core/bridge/client.lua' (loaded before this file). The tablet item opens two ways, both validated by the
-- server's Open.open: ox_inventory's client.export (exports.fredpd_mdt:open -> 'fredpd:mdt:open' callback) and, where
-- the inventory reports the use on the server (qb-inventory), the server's fredpd:client:openTablet with the result.
-- The death handlers exist only while the tablet is open; nothing runs while it is closed.
--
-- NUI actions: one RegisterNUICallback per tablet action (shared/validate.lua ACTIONS) forwarding
-- { action, input } to lib.callback 'fredpd:mdt:action'; the server answers the data or { error }.

local L = require('@fredpd_core.shared.locale').L
local Validate = require 'shared.validate'
local Config = require 'config'

local M = {}

M.TARGET_OPTION = 'fredpd_mdt:terminal'

local state = {
    open = false,
    opening = false,
    mode = nil,    -- 'item' | 'terminal'
    vehicle = nil, -- terminal: the vehicle it was opened in
    prop = nil,
    gen = 0,       -- bumped on every open/close; an old prop load that finishes late is dropped
    handlers = nil,
}

local function notify(kind, text)
    lib.notify({ type = kind, description = text })
end

--- Client hint only (the server decides): job of type leo and on duty (FredBridge.framework.getJob, qb-core or
--- qbx_core).
function M.isOfficerOnDuty()
    local fw = type(FredBridge) == 'table' and FredBridge.framework or nil
    local job = fw and fw.getJob() or nil
    return type(job) == 'table' and job.onduty == true and job.type == 'leo'
end

function M.isOpen()
    return state.open
end

--- The NUI bundle is present (scripts/build.mjs copies it). Without it nothing could answer Esc, so the tablet must
--- never take focus: that would trap the player.
local uiPresent = nil
function M.hasUi()
    if uiPresent == nil then
        uiPresent = LoadResourceFile(GetCurrentResourceName(), 'web/build/index.html') ~= nil
        if not uiPresent then print('[fredpd_mdt] web/build/index.html is missing: run the build (scripts/build.mjs)') end
    end
    return uiPresent
end

function M.isDead()
    local ped = cache.ped
    if ped and IsEntityDead(ped) then return true end
    local bag = type(LocalPlayer) == 'table' and LocalPlayer.state or nil
    return bag ~= nil and bag.isDead == true
end

---------------------------------------------------------------------------------------------------------------
-- Prop and animation (item mode only; §4.7: attach on open, detach on close, anim dict released after use)

local function removeProp()
    local prop = state.prop
    state.prop = nil
    if prop and DoesEntityExist(prop) then
        DetachEntity(prop, true, false)
        DeleteEntity(prop)
    end
    local ped = cache.ped
    if ped and IsEntityPlayingAnim(ped, Config.anim.dict, Config.anim.clip, 3) then
        StopAnimTask(ped, Config.anim.dict, Config.anim.clip, 1.0)
    end
end

local function attachProp(gen)
    local ped = cache.ped
    if not ped or IsPedInAnyVehicle(ped, false) then return end
    local dict = lib.requestAnimDict(Config.anim.dict)
    local model = lib.requestModel(Config.prop.model)
    if gen ~= state.gen or not state.open then
        -- Closed while streaming: release and stop.
        if model then SetModelAsNoLongerNeeded(model) end
        if dict then RemoveAnimDict(dict) end
        return
    end
    local coords = GetEntityCoords(ped)
    local prop = CreateObject(model, coords.x, coords.y, coords.z + 0.2, Config.prop.networked, true, false)
    SetModelAsNoLongerNeeded(model)
    local o, r = Config.prop.offset, Config.prop.rotation
    AttachEntityToEntity(prop, ped, GetPedBoneIndex(ped, Config.prop.bone), o[1], o[2], o[3], r[1], r[2], r[3],
        true, true, false, true, 1, true)
    state.prop = prop
    TaskPlayAnim(ped, dict, Config.anim.clip, 3.0, 3.0, -1, Config.anim.flag, 0, false, false, false)
    RemoveAnimDict(dict)
end

---------------------------------------------------------------------------------------------------------------
-- Death handlers, installed while open

local function onDamage(name, args)
    if name ~= 'CEventNetworkEntityDamage' or type(args) ~= 'table' then return end
    local ped = cache.ped
    if args[1] == ped and (IsEntityDead(ped) or IsPedFatallyInjured(ped)) then M.close(true) end
end

local function onDied()
    M.close(true)
end

local function installHandlers()
    if state.handlers then return end
    local h = {
        AddEventHandler('gameEventTriggered', onDamage),
        AddEventHandler('baseevents:onPlayerDied', onDied),
        AddEventHandler('baseevents:onPlayerKilled', onDied),
    }
    local bag = nil
    if cache.serverId then
        bag = AddStateBagChangeHandler('isDead', ('player:%d'):format(cache.serverId), function(_, _, value)
            if value then M.close(true) end
        end)
    end
    state.handlers = { events = h, bag = bag }
end

local function removeHandlers()
    local h = state.handlers
    state.handlers = nil
    if not h then return end
    for _, data in ipairs(h.events) do RemoveEventHandler(data) end
    if h.bag then RemoveStateBagChangeHandler(h.bag) end
end

---------------------------------------------------------------------------------------------------------------
-- Open / close

--- Show the server's answer to an open (MdtOpenPayload or { error }). Shared by the callback path (M.open) and the
--- server-side item use (fredpd:client:openTablet). A success whose tablet cannot be shown any more tells the server.
--- @return boolean opened
function M.present(mode, res, vehicle)
    if type(res) ~= 'table' then
        notify('error', L('tablet.unavailable'))
        return false
    end
    if res.error then
        notify('error', L(type(res.error) == 'string' and res.error or 'tablet.unavailable'))
        return false
    end
    if M.isDead() or (mode == 'terminal' and cache.vehicle ~= vehicle) then
        -- Died, or left the vehicle, while the server was checking: the server already marked it open.
        TriggerServerEvent('fredpd:mdt:closed')
        return false
    end

    state.open, state.mode = true, mode
    state.vehicle = mode == 'terminal' and vehicle or nil
    state.gen = state.gen + 1
    installHandlers()
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'open', grants = res.grants, unit = res.unit, me = res.me })
    -- The prop comes after the first paint: streaming the model must not delay the page.
    if mode == 'item' then
        local okProp, err = pcall(attachProp, state.gen)
        if not okProp then
            -- lib.requestModel/requestAnimDict raise after their timeout; the tablet works without the prop.
            print(('[fredpd_mdt] tablet prop/animation failed: %s'):format(tostring(err)))
        end
    end
    return true
end

--- Open the tablet. mode 'item' (ox_inventory client.export; slot = { slot, metadata }) or 'terminal' (vehicle =
--- entity). Awaits the server; call from a thread. @return boolean opened
function M.open(mode, slot, vehicle)
    if state.open or state.opening then return false end
    if IsPauseMenuActive() or M.isDead() then return false end
    if not M.hasUi() then
        notify('error', L('tablet.unavailable'))
        return false
    end
    mode = mode == 'terminal' and 'terminal' or 'item'
    local req = { mode = mode }
    if mode == 'item' and type(slot) == 'table' then req.slot = math.tointeger(tonumber(slot.slot)) end

    state.opening = true
    local okCall, res = pcall(lib.callback.await, 'fredpd:mdt:open', false, req)
    state.opening = false
    if not okCall then res = nil end
    local queued = state.queuedItem
    state.queuedItem = nil
    local shown = M.present(mode, res, vehicle)
    -- A server-side item open (qb) arrived while this one was in flight. The server refused this one (no session was
    -- written for it), so the item session it already opened is the valid one: show it.
    if not shown and queued and type(res) == 'table' and res.error then return M.presentServerItem(queued) end
    return shown
end

--- Close the tablet. notifyServer = false when the server already closed it (forceClose). @return boolean was open
--- Focus is only released when this resource holds it, so logout/forceClose never steals focus from another NUI
--- (e.g. the character selector). The NUI 'close' callback, the F8 command and resource stop release it always.
function M.close(notifyServer)
    if not state.open then return false end
    SetNuiFocus(false, false)
    state.open, state.mode, state.vehicle = false, nil, nil
    state.gen = state.gen + 1
    removeHandlers()
    SendNUIMessage({ action = 'close' })
    removeProp()
    if notifyServer then TriggerServerEvent('fredpd:mdt:closed') end
    return true
end

---------------------------------------------------------------------------------------------------------------
-- Tablet item. ox_inventory: client.export = 'fredpd_mdt.open' -> exports.fredpd_mdt:open(data, slot) -> the server
-- callback. qb-inventory (or any inventory that reports the use on the server): the server already ran the same
-- checks for the slot the inventory named and marked the session open; `res` is its answer.

exports('open', function(_, slot)
    CreateThread(function() M.open('item', slot) end)
end)

--- Show the server's answer to a server-side item use. @return boolean opened
function M.presentServerItem(res)
    if not res.error and (IsPauseMenuActive() or not M.hasUi()) then
        -- Opened on the server but nothing can be shown here: never take focus without a page (no trap).
        TriggerServerEvent('fredpd:mdt:closed')
        if not M.hasUi() then notify('error', L('tablet.unavailable')) end
        return false
    end
    return M.present('item', res)
end

RegisterNetEvent('fredpd:client:openTablet', function(res)
    if type(res) ~= 'table' then return end
    if state.open then return end -- already showing it (Open[src] holds one session per player; it stays valid)
    if state.opening then
        -- Another open (terminal / client export) is in flight. A refusal is still shown; a success is kept and
        -- shown only if the in-flight open is refused (see M.open). If the in-flight open succeeds, the server
        -- session is whichever open the server finished last (one Open[src] per player) and the tablet shows the
        -- in-flight one; both are re-checked per action, so the session is left alone on purpose.
        if res.error then
            notify('error', L(type(res.error) == 'string' and res.error or 'tablet.unavailable'))
        else
            state.queuedItem = res
        end
        return
    end
    M.presentServerItem(res)
end)
exports('close', function() return M.close(true) end)
exports('isOpen', M.isOpen)

---------------------------------------------------------------------------------------------------------------
-- NUI callbacks

RegisterNUICallback('close', function(_, cb)
    -- Our own page asked: release focus even if the state says closed (never leave a focus trap).
    if not M.close(true) then SetNuiFocus(false, false) end
    cb({ ok = true })
end)

--- Forward one tablet action to the server dispatcher.
function M.forward(action, data)
    if not state.open then return { error = 'unauthorized' } end
    local okCall, res = pcall(lib.callback.await, 'fredpd:mdt:action', false, { action = action, input = data })
    if not okCall or type(res) ~= 'table' then return { error = 'unavailable' } end
    return res
end

for _, name in ipairs(Validate.actionNames()) do
    if name ~= 'close' then
        RegisterNUICallback(name, function(data, cb)
            cb(M.forward(name, data))
        end)
    end
end

---------------------------------------------------------------------------------------------------------------
-- Server -> tablet

RegisterNetEvent('fredpd:client:push', function(topic, payload)
    if state.open and type(topic) == 'string' then
        SendNUIMessage({ action = 'push', topic = topic, payload = payload })
    end
end)

-- fredpd_core pushes the player's new grant set; the open tablet rebuilds its menus (topic 'grants').
RegisterNetEvent('fredpd:client:grantsChanged', function(set)
    if state.open and type(set) == 'table' then
        SendNUIMessage({ action = 'push', topic = 'grants', payload = set })
    end
end)

RegisterNetEvent('fredpd:client:forceClose', function(reasonKey)
    local wasOpen = M.close(false)
    if wasOpen and type(reasonKey) == 'string' and reasonKey:find('^[%w_.]+$') then notify('error', L(reasonKey)) end
end)

-- Last-resort escape hatch, typed in the F8 console if the page ever fails to answer Esc.
RegisterCommand('fredpd_mdt_close', function()
    if not M.close(true) then SetNuiFocus(false, false) end
end, false)

-- Terminal: leaving the vehicle (or switching to another one) closes it.
lib.onCache('vehicle', function(vehicle)
    if state.open and state.mode == 'terminal' and vehicle ~= state.vehicle then M.close(true) end
end)

---------------------------------------------------------------------------------------------------------------
-- Vehicle terminal (a target option on the configured police models through FredBridge.target: qb-target or
-- ox_target; added once, again when the target resource restarts, removed on stop)

local targetHandle = nil

--- Client hint (the server checks model and seat again): seated in this vehicle, driver or front passenger.
function M.canUseTerminal(entity)
    if state.open or not M.isOfficerOnDuty() then return false end
    if not entity or entity == 0 or cache.vehicle ~= entity then return false end
    for _, seat in ipairs(Config.terminal.seats) do
        if GetPedInVehicleSeat(entity, seat) == cache.ped then return true end
    end
    return false
end

function M.addTerminal()
    if not Config.terminal.enabled or targetHandle or not FredBridge.target.available() then return false end
    targetHandle = FredBridge.target.addModel(Config.terminal.models, {
        name = M.TARGET_OPTION,
        icon = 'fa-solid fa-laptop',
        label = L('tablet.useTerminal'),
        distance = Config.terminal.distance,
        canInteract = function(entity) return M.canUseTerminal(entity) end,
        onSelect = function(data)
            local entity = type(data) == 'table' and data.entity or nil
            CreateThread(function() M.open('terminal', nil, entity) end)
        end,
    })
    return targetHandle ~= nil
end

function M.removeTerminal()
    local handle = targetHandle
    targetHandle = nil
    if handle then FredBridge.target.remove(handle) end
end

M.addTerminal()

AddEventHandler('onClientResourceStart', function(resource)
    if resource == FredBridge.target.resource then
        targetHandle = nil -- the restarted target resource forgot the option
        M.addTerminal()
    end
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        M.removeTerminal()
        M.close(false)
        SetNuiFocus(false, false)
    elseif resource == FredBridge.target.resource then
        targetHandle = nil
    end
end)

return M
