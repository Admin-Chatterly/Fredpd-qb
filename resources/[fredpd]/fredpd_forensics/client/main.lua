-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_forensics client (IMPLEMENTATION.md §5.7, docs/modules/forensics.md). Event- and zone-driven only:
--   * station lab: lib.zones.box per config lab; entering adds the laptop option "Analysera" (ox_target, on the
--     evidences laptop model) and spawns a local laptop prop, leaving removes both. "Analysera" opens evidences' own
--     laptop UI (export openLaptop from patches/evidences.20-fredpd-integration.patch); no analysis logic here.
--   * evidence lockers: one ox_target box per configured stash, added once at start, opening the ox_inventory stash.
--   * "Koppla till ärende": the server offers it after an analysis (fredpd:forensics:client:offerLink). The dialog
--     (lib.inputDialog) opens at once unless evidences' laptop holds NUI focus; then the offer waits as the laptop
--     option "Koppla till ärende" (a second NUI focus on top of the laptop would leave the player stuck in it).

local L = require('@fredpd_core.shared.locale').L
local Config = require 'config'

local M = {}

M.LAPTOP_MODEL = 'p_laptop_02_s' -- evidences' laptop (client/dui/laptops/sync.lua:9)
M.ANALYSE_OPTION = 'fredpd_forensics:analyse'
M.LINK_OPTION = 'fredpd_forensics:link'
M.LOCKER_OPTION = 'fredpd_forensics:locker'
M.OFFERS_MENU = 'fredpd_forensics_offers'

M.pending = {}   -- [evidenceId] = { id, type, example } offers not linked yet (this session only)
M.inside = {}    -- [labId] = true while the player is in that lab box
M.props = {}     -- [labId] = local laptop entity
local busy = false

local function laptopHash()
    return GetHashKey(M.LAPTOP_MODEL)
end

local function notify(kind, text)
    lib.notify({ type = kind, description = text })
end

--- 'Fingeravtryck' for an EvidenceType (evidence.type.<type>), 'Övrigt' for anything unknown.
function M.typeLabel(t)
    local key = 'evidence.type.' .. tostring(t)
    local text = L(key)
    if text == key or text == nil then return L('evidence.type.other') end
    return text
end

--- Player text for a failed link (server error code + reason).
function M.errorText(res, offer)
    local e, r = type(res) == 'table' and res.error or nil, type(res) == 'table' and res.reason or nil
    if e == 'unauthorized' and r == 'off_duty' then return L('errors.notOnDuty') end
    if e == 'unauthorized' and r == 'case' then return L('evidence.link.caseNoAccess') end
    if e == 'unauthorized' then return L('errors.unauthorized') end
    if e == 'not_found' and r == 'case' then return L('evidence.link.caseNotFound') end
    if e == 'not_found' then return L('evidence.link.evidenceNotFound') end
    if e == 'validation' and r == 'case_number' then
        return L('errors.field.invalidCaseNumber', { example = offer and offer.example or '' })
    end
    if e == 'validation' and r == 'already_linked' then return L('evidence.link.alreadyLinked') end
    if e == 'validation' and r == 'case_closed' then return L('evidence.link.caseClosed') end
    if e == 'rate_limited' then return L('errors.rateLimited') end
    if e == 'unavailable' then return L('errors.serviceUnavailable') end
    return L('errors.unknown')
end

---------------------------------------------------------------------------------------------------------------
-- "Koppla till ärende"

--- Dialog for one offer (awaits: call from a thread). Returns the server answer or nil when cancelled.
function M.openLinkDialog(offer)
    if busy or type(offer) ~= 'table' then return nil end
    busy = true
    local okRun, res = pcall(function()
        local input = lib.inputDialog(L('evidence.link.action'), {
            {
                type = 'input',
                label = L('evidence.link.caseNumber'),
                description = L('evidence.link.dialogHint', { type = M.typeLabel(offer.type), id = offer.id }),
                placeholder = offer.example,
                required = true,
                min = 3,
                max = 32,
                icon = 'folder-open',
            },
        })
        if type(input) ~= 'table' or type(input[1]) ~= 'string' then return 'cancelled' end
        return lib.callback.await('fredpd:forensics:link', false, { id = offer.id, caseNumber = input[1] })
            or { ok = false, error = 'unavailable' }
    end)
    busy = false
    if not okRun then
        notify('error', L('errors.unknown'))
        return nil
    end
    if res == 'cancelled' then return nil end
    if type(res) == 'table' and res.ok then
        M.pending[offer.id] = nil
        notify('success', L('evidence.link.success', { tag = res.tag, number = res.caseNumber }))
    else
        if type(res) == 'table' and (res.reason == 'already_linked' or (res.error == 'not_found'
            and res.reason ~= 'case')) then
            M.pending[offer.id] = nil
        end
        notify('error', M.errorText(res, offer))
    end
    return res
end

--- Offers, newest first.
function M.offers()
    local list = {}
    for _, offer in pairs(M.pending) do list[#list + 1] = offer end
    table.sort(list, function(a, b) return a.id > b.id end)
    return list
end

--- Laptop option "Koppla till ärende": one offer -> dialog, several -> pick one first.
function M.chooseOffer()
    local list = M.offers()
    if #list == 0 then return end
    if #list == 1 then return M.openLinkDialog(list[1]) end
    local options = {}
    for i, offer in ipairs(list) do
        options[i] = {
            title = L('evidence.link.offerLabel', { type = M.typeLabel(offer.type), id = offer.id }),
            icon = 'link',
            onSelect = function()
                CreateThread(function() M.openLinkDialog(offer) end)
            end,
        }
    end
    lib.registerContext({ id = M.OFFERS_MENU, title = L('evidence.link.action'), options = options })
    lib.showContext(M.OFFERS_MENU)
end

function M.onOffer(offer)
    if type(offer) ~= 'table' or math.type(offer.id) ~= 'integer' or offer.id < 1 then return end
    local entry = {
        id = offer.id,
        type = type(offer.type) == 'string' and offer.type or 'other',
        example = type(offer.example) == 'string' and offer.example or nil,
    }
    M.pending[entry.id] = entry
    if IsNuiFocused() then
        notify('inform', L('evidence.link.pending'))
        return
    end
    CreateThread(function() M.openLinkDialog(entry) end)
end

---------------------------------------------------------------------------------------------------------------
-- Lab zones

--- "Analysera": evidences' laptop UI on this laptop entity.
function M.openLaptop(entity)
    if GetResourceState('evidences') ~= 'started' then
        notify('error', L('evidence.laptop.unavailable'))
        return false
    end
    local okCall, opened = pcall(function() return exports.evidences:openLaptop(entity) end)
    if not okCall or opened ~= true then
        notify('inform', L('evidence.laptop.useOwnOption'))
        return false
    end
    return true
end

local function analyseOption()
    return {
        name = M.ANALYSE_OPTION,
        label = L('evidence.analyse'),
        icon = 'fa-solid fa-microscope',
        distance = 2.0,
        onSelect = function(data)
            M.openLaptop(type(data) == 'table' and data.entity or nil)
        end,
    }
end

local function anyInside()
    return next(M.inside) ~= nil
end

--- Local (not networked) laptop for the lab's bench; evidences' own laptop option works on it too.
function M.spawnLaptop(lab)
    if not lab.laptop or M.props[lab.id] then return end
    local model = laptopHash()
    lib.requestModel(model)
    if not M.inside[lab.id] or M.props[lab.id] then return end -- left the lab while the model loaded
    local p = lab.laptop
    local entity = CreateObject(model, p.x, p.y, p.z, false, false, false)
    SetEntityHeading(entity, p.w or 0.0)
    FreezeEntityPosition(entity, true)
    SetModelAsNoLongerNeeded(model)
    lib.requestAnimDict('switch@franklin@on_laptop')
    -- keep the lid closed like evidences' own placed laptops (client/dui/laptops/sync.lua:31-33)
    PlayEntityAnim(entity, '001927_01_fras_v2_4_on_laptop_exit_laptop', 'switch@franklin@on_laptop', 1.0, false, true,
        false, 1.0)
    M.props[lab.id] = entity
end

function M.removeLaptop(labId)
    local entity = M.props[labId]
    M.props[labId] = nil
    if entity and DoesEntityExist(entity) then DeleteEntity(entity) end
end

function M.enterLab(lab)
    local first = not anyInside()
    M.inside[lab.id] = true
    if first then exports.ox_target:addModel(laptopHash(), { analyseOption() }) end
    CreateThread(function() M.spawnLaptop(lab) end)
end

function M.exitLab(lab)
    M.inside[lab.id] = nil
    M.removeLaptop(lab.id)
    if not anyInside() then exports.ox_target:removeModel(laptopHash(), M.ANALYSE_OPTION) end
end

---------------------------------------------------------------------------------------------------------------
-- Start

function M.start()
    for _, lab in ipairs(Config.labs or {}) do
        lib.zones.box({
            name = 'fredpd_forensics:lab:' .. lab.id,
            coords = lab.coords,
            size = lab.size,
            rotation = lab.rotation or 0.0,
            onEnter = function() M.enterLab(lab) end,
            onExit = function() M.exitLab(lab) end,
        })
    end

    for _, locker in ipairs(Config.lockers or {}) do
        if locker.coords then
            exports.ox_target:addBoxZone({
                name = 'fredpd_forensics:locker:' .. locker.id,
                coords = locker.coords,
                size = locker.size,
                rotation = locker.rotation or 0.0,
                options = {
                    {
                        name = M.LOCKER_OPTION,
                        label = L('evidence.action.openLocker'),
                        icon = 'fa-solid fa-box-archive',
                        distance = 2.0,
                        onSelect = function()
                            exports.ox_inventory:openInventory('stash', locker.id)
                        end,
                    },
                },
            })
        end
    end

    -- Pending "Koppla till ärende" offers, on any evidences laptop (only while an offer waits).
    exports.ox_target:addModel(laptopHash(), {
        {
            name = M.LINK_OPTION,
            label = L('evidence.link.action'),
            icon = 'fa-solid fa-link',
            distance = 2.0,
            canInteract = function() return next(M.pending) ~= nil end,
            onSelect = function()
                CreateThread(M.chooseOffer)
            end,
        },
    })

    RegisterNetEvent('fredpd:forensics:client:offerLink', M.onOffer)

    AddEventHandler('onResourceStop', function(resource)
        if resource ~= GetCurrentResourceName() then return end
        for labId in pairs(M.props) do M.removeLaptop(labId) end
    end)
end

M.start()

return M
