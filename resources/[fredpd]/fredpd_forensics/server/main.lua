-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_forensics server entry (IMPLEMENTATION.md §5.7, docs/contracts.md §C16, docs/modules/forensics.md).
-- Registers exports, the evidences event, the "Koppla till ärende" callback, the evidence lockers (ox_inventory
-- stashes) and the three ox_inventory hooks. Nothing runs while idle: every path starts from an event, a hook, a
-- callback or an export call.

local L = require('@fredpd_core.shared.locale').L
local Format = require '@fredpd_core.shared.format'
local Regex = require '@fredpd_core.shared.regex'
local Evidence = require 'shared.evidence'
local Service = require 'server.service'
local Config = require 'config'

local M = {}

---------------------------------------------------------------------------------------------------------------
-- Formats (config/formats.json of fredpd_core: evidenceTag, caseNumber)

--- { tag(caseNumber, n), isCaseNumber(v) } from a decoded formats.json, or nil and the error.
function M.formatFns(formats)
    local okLoad, err = pcall(Format.load, formats)
    if not okLoad then return nil, err end
    local active = Format.get()
    local caseRegex = Regex.compile(Format.templateToRegex('caseNumber'))
    return {
        tag = function(caseNumber, n) return Format.formatId(active.evidenceTag, { case = caseNumber, n = n }) end,
        isCaseNumber = function(v) return caseRegex:test(v) end,
        example = Format.formatId(active.caseNumber, { seq = 123, date = '2026-09-29T12:00:00Z' }),
    }
end

local function loadFormats()
    local raw = LoadResourceFile('fredpd_core', 'config/formats.json')
    local okJson, formats = pcall(json.decode, raw or '')
    if not okJson or type(formats) ~= 'table' then
        Service.log('error', 'fredpd_core/config/formats.json is missing (run scripts/build.mjs); linking is disabled')
        return nil
    end
    local fns, err = M.formatFns(formats)
    if not fns then Service.log('error', 'formats.json rejected: %s', tostring(err)) end
    return fns
end

---------------------------------------------------------------------------------------------------------------
-- ox_inventory: stashes and hooks (again after an ox_inventory restart, which drops every hook)

local hookIds = {}

function M.registerStashes()
    for _, locker in ipairs(Config.lockers or {}) do
        local okStash, err = pcall(function()
            exports.ox_inventory:RegisterStash(locker.id, L(locker.labelKey or 'evidence.locker'), locker.slots or 200,
                locker.maxWeight or 200000, nil, locker.groups, locker.coords)
        end)
        if not okStash then Service.log('error', 'RegisterStash %s failed: %s', locker.id, tostring(err)) end
    end
end

function M.registerHooks()
    local items = Service.cfg.items
    -- createItem: mint item_uid on every new evidence item, keep it on an existing one that moves (give); ox_inventory
    -- modules/hooks/server.lua:91-94 replaces the metadata with a returned table, nil leaves it as it is.
    local okCreate, createId = pcall(function()
        return exports.ox_inventory:registerHook('createItem', function(payload)
            local okMint, md = pcall(Service.mint, payload)
            if not okMint then
                Service.log('error', 'createItem hook failed: %s', tostring(md))
                return nil
            end
            return md
        end, { itemFilter = Evidence.itemFilter(items) })
    end)
    -- swapItems: never blocks (returns true); the custody work runs in the post-hook event ox_inventory fires with
    -- (success, payload) 50 ms after the move (modules/hooks/server.lua:34-54), in its own thread.
    local okSwap, swapId = pcall(function()
        return exports.ox_inventory:registerHook('swapItems', function()
            return true
        end, {
            inventoryFilter = Service.cfg.lockerPatterns,
            itemFilter = Evidence.itemFilter(items, Service.cfg.containerItems),
        })
    end)
    -- openInventory: evidence lockers need FredPD's grant + duty on top of the stash's ox_inventory `groups` check
    -- (ox_inventory server.lua:260 groups, 288-290 hook: returning false stops the open). In-memory checks only.
    local okOpen, openId = pcall(function()
        return exports.ox_inventory:registerHook('openInventory', function(payload)
            local okRun, allowed = pcall(Service.mayOpenLocker, payload)
            if okRun and allowed == true then return true end
            local src = type(payload) == 'table' and math.tointeger(tonumber(payload.source)) or nil
            if src and src > 0 then
                TriggerClientEvent('ox_lib:notify', src, { type = 'error', description = L('evidence.lockerDenied') })
            end
            return false
        end, { inventoryFilter = Service.cfg.lockerPatterns })
    end)
    if not okCreate or not okSwap or not okOpen then
        Service.log('error', 'ox_inventory hooks not registered: %s',
            tostring((not okCreate and createId) or (not okSwap and swapId) or openId))
        return false
    end
    if swapId and not hookIds[swapId] then
        hookIds[swapId] = true
        AddEventHandler(swapId, function(success, payload)
            CreateThread(function()
                local okRun, err = pcall(Service.onSwap, success, payload)
                if not okRun then Service.log('error', 'custody (swapItems) failed: %s', tostring(err)) end
            end)
        end)
    end
    return true
end

---------------------------------------------------------------------------------------------------------------
-- Wiring

function M.start()
    Service.configure({
        labs = Config.labs,
        lockerPatterns = Config.lockerPatterns,
        lockerGrant = Config.lockerGrant,
        containerItems = Config.containerItems,
        labUnit = Config.labUnit,
        linkCooldownMs = Config.linkCooldownMs,
        registerDelayMs = Config.registerDelayMs,
    }, loadFormats())

    -- Tablet actions (EVIDENCE_ACTIONS; the fredpd_mdt dispatcher routes to these, §C12 convention).
    exports('listEvidence', Service.list)
    exports('getEvidence', Service.get)
    exports('linkEvidence', Service.linkEvidence)
    -- Case page (fredpd_records getCase): the case's evidence for anyone on duty who can see the case.
    exports('listCaseEvidence', Service.listCase)

    -- evidences (patched: patches/evidences.20-fredpd-integration.patch adds the third argument). Server-only:
    -- AddEventHandler without RegisterNetEvent, so a client's TriggerServerEvent of this name never arrives here.
    AddEventHandler('evidences:evidenceItemAnalysed', function(playerId, item, inventory)
        CreateThread(function()
            local okRun, err = pcall(Service.onAnalysed, playerId, item, inventory)
            if not okRun then Service.log('error', 'evidenceItemAnalysed failed: %s', tostring(err)) end
        end)
    end)

    -- "Koppla till ärende" dialog (client/main.lua). Grant, duty, rate limit and input are checked in the service.
    lib.callback.register('fredpd:forensics:link', function(source, data)
        local src = source
        local okRun, result = pcall(Service.linkFromDialog, src, data)
        if not okRun then
            Service.log('error', 'fredpd:forensics:link failed: %s', tostring(result))
            return { ok = false, error = 'unavailable' }
        end
        return result
    end)

    AddEventHandler('playerDropped', function()
        Service.forget(source)
    end)

    AddEventHandler('onResourceStart', function(resource)
        if resource == 'ox_inventory' then
            M.registerStashes()
            M.registerHooks()
        end
    end)

    if GetResourceState('ox_inventory') == 'started' then
        M.registerStashes()
        M.registerHooks()
    else
        Service.log('warn', 'ox_inventory is not started; evidence hooks wait for it')
    end
end

M.start()

return M
