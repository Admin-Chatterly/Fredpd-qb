-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_bolo client: the target option "Kontrollera registreringsskylt" on every vehicle (IMPLEMENTATION.md §5.4
-- hit source 1), through fredpd_core's bridge (FredBridge.target, '@fredpd_core/bridge/client.lua'; qb-target or
-- ox_target, docs/contracts.md §C17). Added once when the resource (or the target resource) starts, removed on stop;
-- no threads, no polling.
-- canInteract (police job, on duty; FredBridge.framework.getJob, a hint) only hides the option from others: the
-- server checks grant mdt_page:search, duty and 1/s again, and reads the plate from the vehicle entity itself (the
-- client sends only the network id).
-- The result is an ox_lib context menu (shared/view.lua), the hit highlighted in red.

local L = require('@fredpd_core.shared.locale').L
local View = require 'shared.view'

local M = {}

M.OPTION = 'fredpd_bolo:checkPlate'
M.DISTANCE = 3.0
M.HIT_SOUND = { 'TIMER_STOP', 'HUD_MINI_GAME_SOUNDSET' }
M.BUSY_STALE_MS = 15000 -- a check whose callback never answers stops blocking the option after this (no timer)

local busySince = nil -- GetGameTimer() of the check in flight

local function notify(kind, text)
    lib.notify({ type = kind, title = L('bolo.checkPlate.title'), description = text })
end

--- Client hint only (the server decides): a job of type leo (or named police) and on duty. The bridge keeps the job
--- current from the framework's client events (qb-core and qbx_core fire the same ones).
function M.canInteract()
    local job = FredBridge.framework.getJob()
    if type(job) ~= 'table' or job.onduty ~= true then return false end
    return job.type == 'leo' or job.name == 'police'
end

local formatter = nil -- fredpd_core shared/format.lua with config/formats.json, loaded on the first hit; false = n/a

--- Date + time of an ISO UTC string in the configured format and zone (Europe/Stockholm), nil when unavailable.
local function formatDate(iso)
    if formatter == nil then
        formatter = false
        local okLoad, Format = pcall(require, '@fredpd_core.shared.format')
        local raw = okLoad and type(Format) == 'table' and LoadResourceFile('fredpd_core', 'config/formats.json')
        if raw and pcall(function() Format.load(json.decode(raw)) end) then formatter = Format end
    end
    if not formatter then return nil end
    local okDate, date = pcall(formatter.formatDate, iso)
    local okTime, time = pcall(formatter.formatTime, iso)
    if okDate and okTime then return date .. ' ' .. time end
    return nil
end

--- Ask the server about the targeted vehicle and show the result (awaits; runs in its own thread).
function M.check(entity)
    if busySince and GetGameTimer() - busySince < M.BUSY_STALE_MS then return end
    if not entity or entity == 0 or not DoesEntityExist(entity) or not NetworkGetEntityIsNetworked(entity) then
        notify('error', L('errors.notFound'))
        return
    end
    local mine = GetGameTimer()
    busySince = mine
    local okCall, res = pcall(lib.callback.await, 'fredpd:bolo:plateCheck', false, NetworkGetNetworkIdFromEntity(entity))
    if busySince == mine then busySince = nil end
    if not okCall or type(res) ~= 'table' then
        notify('error', L('errors.unknown'))
        return
    end
    if res.error then
        notify('error', View.errorText(res, L))
        return
    end
    lib.registerContext(View.menu(res, L, formatDate))
    lib.showContext(View.MENU_ID)
    if type(res.bolo) == 'table' then PlaySoundFrontend(-1, M.HIT_SOUND[1], M.HIT_SOUND[2], true) end
end

local handle = nil -- FredBridge.target handle of the global vehicle option

function M.addOption()
    if handle then return true end
    if not FredBridge.target.available() then return false end
    handle = FredBridge.target.addGlobalVehicle({
        name = M.OPTION,
        icon = 'fa-solid fa-magnifying-glass',
        label = L('bolo.checkPlate.target'),
        distance = M.DISTANCE,
        canInteract = function() return M.canInteract() end,
        onSelect = function(data)
            local entity = type(data) == 'table' and data.entity or data
            CreateThread(function() M.check(entity) end)
        end,
    })
    return handle ~= nil
end

function M.removeOption()
    if not handle then return end
    local h = handle
    handle = nil
    pcall(FredBridge.target.remove, h)
end

M.addOption()

-- The target resource (re)started after this resource: its option lists start empty, add ours again.
AddEventHandler('onClientResourceStart', function(resource)
    if resource == FredBridge.target.resource then
        handle = nil
        M.addOption()
    end
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        M.removeOption()
        if lib.getOpenContextMenu and lib.getOpenContextMenu() == View.MENU_ID then lib.hideContext(false) end
    elseif resource == FredBridge.target.resource then
        handle = nil
    end
end)

return M
