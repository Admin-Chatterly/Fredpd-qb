-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_bolo client: the ox_target option "Kontrollera registreringsskylt" on every vehicle (IMPLEMENTATION.md §5.4
-- hit source 1). Added once when the resource (or ox_target) starts, removed on stop; no threads, no polling.
-- canInteract (police job, on duty) only hides the option from others: the server checks grant mdt_page:search, duty
-- and 1/s again, and reads the plate from the vehicle entity itself (the client sends only the network id).
-- The result is an ox_lib context menu (shared/view.lua), the hit highlighted in red.

local L = require('@fredpd_core.shared.locale').L
local View = require 'shared.view'

local M = {}

M.OPTION = 'fredpd_bolo:checkPlate'
M.DISTANCE = 3.0
M.HIT_SOUND = { 'TIMER_STOP', 'HUD_MINI_GAME_SOUNDSET' }

local busy = false
local added = false

local function notify(kind, text)
    lib.notify({ type = kind, title = L('bolo.checkPlate.title'), description = text })
end

--- Client hint only (the server decides): qbx job of type leo (or named police) and on duty.
function M.canInteract()
    local pd = type(QBX) == 'table' and QBX.PlayerData or nil
    local job = type(pd) == 'table' and pd.job or nil
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
    if busy then return end
    if not entity or entity == 0 or not DoesEntityExist(entity) or not NetworkGetEntityIsNetworked(entity) then
        notify('error', L('errors.notFound'))
        return
    end
    busy = true
    local okCall, res = pcall(lib.callback.await, 'fredpd:bolo:plateCheck', false, NetworkGetNetworkIdFromEntity(entity))
    busy = false
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

function M.addOption()
    if GetResourceState('ox_target') ~= 'started' then return false end
    exports.ox_target:addGlobalVehicle({
        {
            name = M.OPTION,
            icon = 'fa-solid fa-magnifying-glass',
            label = L('bolo.checkPlate.target'),
            distance = M.DISTANCE,
            canInteract = function() return M.canInteract() end,
            onSelect = function(data)
                local entity = type(data) == 'table' and data.entity or data
                CreateThread(function() M.check(entity) end)
            end,
        },
    })
    added = true
    return true
end

function M.removeOption()
    if not added then return end
    added = false
    pcall(function() exports.ox_target:removeGlobalVehicle(M.OPTION) end)
end

M.addOption()

-- ox_target (re)started after this resource: its option lists start empty, add ours again.
AddEventHandler('onClientResourceStart', function(resource)
    if resource == 'ox_target' then M.addOption() end
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        M.removeOption()
        if lib.getOpenContextMenu and lib.getOpenContextMenu() == View.MENU_ID then lib.hideContext(false) end
    elseif resource == 'ox_target' then
        added = false
    end
end)

return M
