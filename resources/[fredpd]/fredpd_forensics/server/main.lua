-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_forensics server entry (IMPLEMENTATION.md §5.7, docs/contracts.md §C16, docs/modules/forensics.md).
-- Registers exports, the evidences event, the "Koppla till ärende" callback, the evidence lockers (ox_inventory
-- stashes) and the three ox_inventory hooks. Nothing runs while idle: every path starts from an event, a hook, a
-- callback or an export call.
--
-- Framework bridge (docs/contracts.md §C17): evidences needs ox_inventory + ox_target, so everything above is wired
-- only while exports.fredpd_core:bridgeInfo().evidence is true (and the selected inventory is ox_inventory). Otherwise
-- (e.g. qb-inventory / qb-target) the resource stays idle: no hooks, stashes, events or callbacks, ONE warning, and
-- the tablet exports answer { ok = false, error = 'unavailable', reason = 'evidence_off' }. It looks again when
-- evidences (or ox_inventory) starts later. ox_inventory itself is only reached through Service.inventory().

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
            Service.inventory():RegisterStash(locker.id, L(locker.labelKey or 'evidence.locker'), locker.slots or 200,
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
        return Service.inventory():registerHook('createItem', function(payload)
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
        return Service.inventory():registerHook('swapItems', function()
            return true
        end, {
            inventoryFilter = Service.cfg.lockerPatterns,
            itemFilter = Evidence.itemFilter(items, Service.cfg.containerItems),
        })
    end)
    -- openInventory: evidence lockers need FredPD's grant + duty on top of the stash's ox_inventory `groups` check
    -- (ox_inventory server.lua:260 groups, 288-290 hook: returning false stops the open). In-memory checks only.
    local okOpen, openId = pcall(function()
        return Service.inventory():registerHook('openInventory', function(payload)
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

M.RECHECK_MS = 1000 -- after evidences / ox_inventory / ox_target starts, look at the bridge again once (it reports 'started')
M.CONVAR = 'fredpd_forensics_evidence' -- replicated 'on' | 'off': client/main.lua registers its targets only when 'on'
M.ENABLE_EVENT = 'fredpd:forensics:client:enable' -- tells joined clients that evidence turned on

local function replicate(value)
    if type(SetConvarReplicated) == 'function' then SetConvarReplicated(M.CONVAR, value) end
end

--- The answer of every tablet export while evidence is off (a fresh table: callers may keep or change it).
function M.unavailable()
    return { ok = false, error = 'unavailable', reason = 'evidence_off' }
end

local state = { active = false, warned = false, info = nil }

--- Whether the resource is wired (evidence on). Tests, logs.
function M.isActive() return state.active end

--- fredpd_core's bridge report { framework, inventory, target, doorlock, hooks, evidence }, or nil when fredpd_core
--- does not answer.
function M.bridgeInfo()
    local okInfo, info = pcall(function() return exports.fredpd_core:bridgeInfo() end)
    if okInfo and type(info) == 'table' then return info end
    return nil
end

--- Evidence on = the bridge says so (ox_inventory + ox_target selected and evidences started) and the selected
--- inventory is ox_inventory (the hooks below are ox_inventory's).
function M.evidenceOn(info)
    return type(info) == 'table' and info.evidence == true and info.inventory == 'ox_inventory'
end

--- Tablet exports: registered once at start, answering 'unavailable' until the resource is wired.
local function gated(name)
    return function(...)
        if not state.active then return M.unavailable() end
        return Service[name](...)
    end
end

--- Wire everything (once). Only called when M.evidenceOn(info).
function M.activate(info)
    if state.active then return true end
    state.active, state.info = true, info
    Service.configure({
        labs = Config.labs,
        lockerPatterns = Config.lockerPatterns,
        lockerGrant = Config.lockerGrant,
        containerItems = Config.containerItems,
        labUnit = Config.labUnit,
        linkCooldownMs = Config.linkCooldownMs,
        registerDelayMs = Config.registerDelayMs,
        inventory = info.inventory,
    }, loadFormats())

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

    if GetResourceState('ox_inventory') == 'started' then
        M.registerStashes()
        M.registerHooks()
    else
        Service.log('warn', 'ox_inventory is not started; evidence hooks wait for it')
    end
    replicate('on')
    TriggerClientEvent(M.ENABLE_EVENT, -1)
    Service.log('info', 'evidence on (bridge: inventory=%s, target=%s)', tostring(info.inventory),
        tostring(info.target))
    return true
end

--- Look at the bridge; wire when evidence is on, else stay idle with ONE warning (per resource start).
function M.check()
    if state.active then return true end
    local info = M.bridgeInfo()
    if M.evidenceOn(info) then return M.activate(info) end
    if not state.warned then
        state.warned = true
        info = info or {}
        Service.log('warn', 'evidence is not available (bridge: inventory=%s, target=%s, evidences %s): '
            .. 'fredpd_forensics stays idle and the tablet\'s Bevis page shows "not available"; it needs '
            .. 'ox_inventory + ox_target + evidences', tostring(info.inventory), tostring(info.target),
            GetResourceState('evidences'))
    end
    return false
end

function M.start()
    -- Tablet actions (EVIDENCE_ACTIONS; the fredpd_mdt dispatcher routes to these, §C12 convention).
    exports('listEvidence', gated('list'))
    exports('getEvidence', gated('get'))
    exports('linkEvidence', gated('linkEvidence'))
    -- Case page (fredpd_records getCase): the case's evidence for anyone on duty who can see the case.
    exports('listCaseEvidence', gated('listCase'))

    -- ox_inventory restarting drops every hook and stash (wired only); evidences, ox_inventory or ox_target starting
    -- after this resource can turn evidence on: one look at the bridge RECHECK_MS later (a one-shot timer, no polling).
    AddEventHandler('onResourceStart', function(resource)
        if resource == 'ox_inventory' and state.active then
            M.registerStashes()
            M.registerHooks()
        elseif not state.active and (resource == 'evidences' or resource == 'ox_inventory'
            or resource == 'ox_target') then
            SetTimeout(M.RECHECK_MS, M.check)
        end
    end)

    replicate('off')
    M.check()
end

M.start()

return M
