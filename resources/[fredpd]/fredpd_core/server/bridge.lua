-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_core framework bridge, server side (docs/contracts.md §C17, docs/modules/bridge.md). FredPD resources never
-- call qb-core/qbx_core, qb-inventory/ox_inventory or qb-doorlock/ox_doorlock directly: they call the exports
-- registered here, and listen to the normalised server events
--   fredpd:bridge:playerLoaded(src)  fredpd:bridge:playerUnloaded(src)  fredpd:bridge:jobChanged(src)
--   fredpd:bridge:dutyChanged(src, onduty)  fredpd:bridge:doorChanged(id, locked)
-- (server-local: TriggerEvent, consumers use AddEventHandler; never RegisterNetEvent, so no client can fake them).
-- The implementation per kind comes from config/integrations.json (bridge/select.lua; 'auto' = first started, ox
-- first). A configured resource that is not running makes its calls no-ops with ONE warning, never an error.
-- The target kind is client-only (bridge/client.lua); the server only replicates the choice to clients.

local Core = require 'server.core'
local Select = require 'bridge.select'
local Normalize = require 'bridge.framework.normalize'

local M = {}

M.DEFERRED_CHECK_MS = 15000
M.ERROR_LOG_MS = 60000

M.EVENTS = {
    playerLoaded = 'fredpd:bridge:playerLoaded',
    playerUnloaded = 'fredpd:bridge:playerUnloaded',
    jobChanged = 'fredpd:bridge:jobChanged',
    dutyChanged = 'fredpd:bridge:dutyChanged',
    doorChanged = 'fredpd:bridge:doorChanged',
}

--- Replicated convars telling bridge/client.lua (in every resource) which client implementation to use (framework:
--- only for the client job hint FredBridge.framework.getJob, docs/modules/bridge.md).
M.CONVARS = { framework = 'fredpd_bridge_framework', target = 'fredpd_bridge_target', doorlock = 'fredpd_bridge_doorlock' }

--- What a call answers while its resource is down (or the call failed).
local FALLBACK = {
    getPlayer = function() return nil end,
    getPlayerByCitizenId = function() return nil end,
    getPlayers = function() return {} end,
    removeMoney = function() return false end,
    addMoney = function() return false end,
    count = function() return 0 end,
    find = function() return {} end,
    add = function() return false end,
    remove = function() return false end,
    registerUsable = function() return false end,
    getDoor = function() return nil end,
    setLocked = function() return false end,
}

local S -- runtime state, (re)built by M.load
local log = Core
local stateOf = function(resource) return GetResourceState(resource) end
local function defaultDefer(ms, fn) if type(SetTimeout) == 'function' then SetTimeout(ms, fn) end end
local defer = defaultDefer

local function fresh()
    return {
        chosen = {},      -- kind -> implementation name
        notes = {},       -- kind -> Select.resolve note
        modules = {},     -- kind -> implementation module
        impls = {},       -- kind -> server implementation object (framework, inventory, doorlock)
        warned = {},      -- one-time warnings
        errorAt = {},     -- 'kind.method' -> last error log time
        known = {},       -- src -> { name, type, grade, onduty } (last job seen, for job/duty change detection)
        usable = {},      -- item -> fn(src, slot, metadata)
        updated = {},     -- internal listeners fn(src, player) for any PlayerData change
    }
end
S = fresh()

local function warnOnce(key, fmt, ...)
    if S.warned[key] then return end
    S.warned[key] = true
    log.warn(fmt, ...)
end

local function running(st) return st == 'started' or st == 'starting' end

--- The ONE warning about a kind's resource (whichever check sees it first).
local function warnUnavailable(kind, resource, st)
    warnOnce('resource:' .. kind .. ':' .. resource, '%s bridge "%s": resource %s is %s; its calls are no-ops until it runs',
        kind, S.chosen[kind], resource, tostring(st))
end

--- 'auto' picked an installed-but-not-running resource (nothing of the pair ran yet) and the OTHER one runs now: the
--- selection stays for this session (implementations bind upstream events at load), so say exactly what to change.
local function warnAutoMispick(kind, resource, st, other)
    warnOnce('resource:' .. kind .. ':' .. resource, '%s bridge: "auto" picked %s before any %s resource ran, but %s is '
        .. 'running and %s is %s; set %s = "%s" in config/integrations.json or ensure it before fredpd_core, then '
        .. 'restart fredpd_core', kind, resource, kind, other, resource, tostring(st), kind, other)
end

--- An implementation of kind other than the chosen one that is started now, or nil.
local function otherStarted(kind)
    for _, name in ipairs(Select.IMPLS[kind] or {}) do
        if name ~= S.chosen[kind] and stateOf(name) == 'started' then return name end
    end
    return nil
end

---------------------------------------------------------------------------------------------------------------
-- Loading

--- Select and load the implementations. cfg = decoded integrations.json.
--- opts (tests) = { stateOf = fn(resource), require = fn(name), log = { info, warn, error, debug }, defer = fn(ms, cb) }
--- @return table chosen kind -> implementation name
function M.load(cfg, opts)
    opts = opts or {}
    S = fresh()
    log = opts.log or Core
    stateOf = opts.stateOf or function(resource) return GetResourceState(resource) end
    defer = opts.defer or defaultDefer
    local req = opts.require or require
    for _, kind in ipairs(Select.KINDS) do
        local configured = type(cfg) == 'table' and cfg[kind] or nil
        local name, note = Select.resolve(kind, configured, stateOf)
        S.chosen[kind], S.notes[kind] = name, note
        if note == 'unknown' then
            warnOnce('config:' .. kind, 'unknown %s bridge "%s" in config/integrations.json; using "%s" (auto)', kind,
                tostring(configured), name)
        end
        local mod = req(Select.moduleName(kind, name))
        S.modules[kind] = mod
        if type(mod.server) == 'function' then S.impls[kind] = mod.server() end
        M.checkResource(kind)
    end
    M.replicate()
    log.info('%s', M.report())
    M.checkEvidence()
    return S.chosen
end

--- Start-up availability check of a kind's resource: 'missing' warns at once; installed but not running is looked at
--- again once after M.DEFERRED_CHECK_MS (it may be ensured after fredpd_core). One warning either way.
function M.checkResource(kind)
    local mod = S.modules[kind]
    if not mod or not mod.resource then return end
    local resource = mod.resource
    local st = stateOf(resource)
    if st == 'missing' then
        warnUnavailable(kind, resource, st)
    elseif not running(st) then
        defer(M.DEFERRED_CHECK_MS, function()
            local later = stateOf(resource)
            if running(later) then return end
            local other = S.notes[kind] == 'not_started' and otherStarted(kind) or nil
            if other then
                warnAutoMispick(kind, resource, later, other)
            else
                warnUnavailable(kind, resource, later)
            end
        end)
    end
end

local function oxEvidencePair()
    return S.chosen.inventory == 'ox_inventory' and S.chosen.target == 'ox_target'
end

--- Start-up evidence check (one warning at most). The inventory/target choice rules evidence out -> warn at once (only
--- when evidences is installed at all). The ox pair is chosen but evidences is not running yet (ensured after
--- fredpd_core) -> look again once after M.DEFERRED_CHECK_MS and warn only if it is still down.
function M.checkEvidence()
    local st = stateOf('evidences')
    if st == 'missing' then return end
    if not oxEvidencePair() then
        warnOnce('feature:evidence', 'evidences needs ox_inventory + ox_target (bridge: %s + %s): fredpd_forensics stays '
            .. 'idle and the police job keeps its own evidence', S.chosen.inventory, S.chosen.target)
        return
    end
    if st == 'started' then return end
    defer(M.DEFERRED_CHECK_MS, function()
        local later = stateOf('evidences')
        if later ~= 'started' then
            warnOnce('feature:evidence', 'evidences is %s (ox_inventory + ox_target are selected): fredpd_forensics '
                .. 'stays idle until evidences starts', tostring(later))
        end
    end)
end

--- Tell clients which target/doorlock implementation to use (read by bridge/client.lua with GetConvar).
function M.replicate()
    if type(SetConvarReplicated) ~= 'function' then return end
    for kind, convar in pairs(M.CONVARS) do
        if S.chosen[kind] then SetConvarReplicated(convar, S.chosen[kind]) end
    end
end

--- Implementation name per kind (after M.load).
function M.chosen(kind) return S.chosen[kind] end

--- Capability report: one line.
function M.report()
    local inv = S.impls.inventory
    local door = S.impls.doorlock
    local patched = ''
    if S.chosen.doorlock == 'qb-doorlock' then
        patched = door and door.patched == false and ' (unpatched!)' or ' (needs its FredPD patch)'
    end
    return ('bridge: framework=%s, inventory=%s (hooks: %s), target=%s, doorlock=%s%s; evidence: %s'):format(
        tostring(S.chosen.framework), tostring(S.chosen.inventory), inv and inv.hooks and 'yes' or 'no',
        tostring(S.chosen.target), tostring(S.chosen.doorlock), patched,
        M.evidenceText())
end

--- Evidence part of the report: on | pending (ox pair chosen, evidences installed but not started yet) | off.
function M.evidenceText()
    if M.hasFeature('evidence') then return 'on' end
    local st = stateOf('evidences')
    if oxEvidencePair() and st ~= 'missing' then
        return ('pending (evidences is %s; on once it starts)'):format(tostring(st))
    end
    return 'off (needs ox_inventory + ox_target + evidences)'
end

--- Degradation switches (§C17). 'evidence' = inventory ox_inventory + target ox_target + evidences started;
--- 'inventoryHooks' = the inventory implementation has ox-style hooks (chain-of-custody hand-in).
function M.hasFeature(name)
    if name == 'evidence' then
        return S.chosen.inventory == 'ox_inventory' and S.chosen.target == 'ox_target'
            and stateOf('evidences') == 'started'
    elseif name == 'inventoryHooks' then
        return S.impls.inventory ~= nil and S.impls.inventory.hooks == true
    end
    return false
end

--- Copy of the selection for other resources: { framework, inventory, target, doorlock, hooks, evidence }.
function M.info()
    return {
        framework = S.chosen.framework, inventory = S.chosen.inventory, target = S.chosen.target,
        doorlock = S.chosen.doorlock, hooks = M.hasFeature('inventoryHooks'), evidence = M.hasFeature('evidence'),
    }
end

---------------------------------------------------------------------------------------------------------------
-- Guarded calls

local function now()
    return Core.now()
end

--- Call impl[method] of a kind when its resource runs; the FALLBACK value otherwise (one warning) or on error.
function M.call(kind, method, ...)
    local impl, mod = S.impls[kind], S.modules[kind]
    local fallback = FALLBACK[method] or function() return nil end
    if not impl or type(impl[method]) ~= 'function' then return fallback() end
    local resource = (mod.REQUIRES and mod.REQUIRES[method]) or mod.resource
    local st = stateOf(resource)
    if st ~= 'started' then
        warnUnavailable(kind, resource, st)
        return fallback()
    end
    local ok, a, b = pcall(impl[method], ...)
    if ok then return a, b end
    local key = kind .. '.' .. method
    local t = now()
    if not S.errorAt[key] or t - S.errorAt[key] >= M.ERROR_LOG_MS then
        S.errorAt[key] = t
        log.error('%s bridge "%s".%s failed: %s', kind, tostring(S.chosen[kind]), method, tostring(a))
    end
    return fallback()
end

local function validSrc(src)
    src = tonumber(src)
    if src and src > 0 and math.tointeger(src) then return math.tointeger(src) end
    return nil
end

local function validItem(item)
    return type(item) == 'string' and #item <= 64 and item:match('^[%w_%-%.]+$') ~= nil
end

local function validCount(count)
    count = math.tointeger(tonumber(count))
    if count and count >= 1 and count <= 1000000 then return count end
    return nil
end

local function callable(fn)
    if type(fn) == 'function' then return true end
    if type(fn) == 'table' then
        local mt = getmetatable(fn)
        return rawget(fn, '__cfx_functionReference') ~= nil or (type(mt) == 'table' and mt.__call ~= nil)
    end
    return false
end

---------------------------------------------------------------------------------------------------------------
-- framework

--- Normalised player { source, citizenid, license, name, job = { name, label, type, grade, gradeName, onduty,
--- isboss }, charinfo } or nil. Always asks the framework (never a cache), so the actor is never stale (§4.6).
function M.getPlayer(src)
    src = validSrc(src)
    if not src then return nil end
    return M.call('framework', 'getPlayer', src)
end

function M.getPlayerByCitizenId(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' or #citizenid > 64 then return nil end
    return M.call('framework', 'getPlayerByCitizenId', citizenid)
end

--- Sources with a loaded character.
function M.getPlayers()
    return M.call('framework', 'getPlayers')
end

--- Take money for a fine. account 'bank' | 'cash' | …; amount rounded to a whole number > 0. true when taken.
function M.removeMoney(src, account, amount, reason)
    src = validSrc(src)
    local acc, amt = Normalize.money(account, amount)
    if not src or not acc then return false end
    reason = type(reason) == 'string' and reason:sub(1, 200) or 'fredpd'
    return M.call('framework', 'removeMoney', src, acc, amt, reason) == true
end

--- Give money back (a refunded fine). Same validation as removeMoney. true when added. (Not in §C17's list: fredpd_records
--- refunds a fine whose DB write failed; docs/modules/bridge.md, open question 1.)
function M.addMoney(src, account, amount, reason)
    src = validSrc(src)
    local acc, amt = Normalize.money(account, amount)
    if not src or not acc then return false end
    reason = type(reason) == 'string' and reason:sub(1, 200) or 'fredpd'
    return M.call('framework', 'addMoney', src, acc, amt, reason) == true
end

--- Internal: fn(src, player) on every PlayerData change the framework reports (mirror). Not a server event: qbx fires
--- its source event on every money/hunger tick.
function M.onPlayerUpdated(fn)
    S.updated[#S.updated + 1] = fn
end

local function emit(name, ...)
    TriggerEvent(name, ...)
end

local function snapshot(job)
    if type(job) ~= 'table' then return nil end
    return { name = job.name, type = job.type, grade = job.grade, onduty = job.onduty == true }
end

local function jobOf(src)
    local player = M.getPlayer(src)
    return player and player.job or nil
end

--- Upstream event handlers (bound by the framework implementation, see impl.bind). Exposed for tests.
M.handlers = {}

function M.handlers.loaded(src, player)
    src = validSrc(src)
    if not src then return end
    S.known[src] = snapshot(player and player.job or jobOf(src)) or {}
    emit(M.EVENTS.playerLoaded, src)
end

function M.handlers.unloaded(src)
    src = validSrc(src)
    if not src or S.known[src] == nil then return end
    S.known[src] = nil
    emit(M.EVENTS.playerUnloaded, src)
end

--- A job update: jobChanged when name/type/grade differ from the last seen job (or none was seen), dutyChanged when
--- only duty differs. qb-core's SetJobDuty lands here (OnJobUpdate) before its SetDuty event; the later duplicate is
--- dropped by M.handlers.duty.
function M.handlers.job(src, job)
    src = validSrc(src)
    if not src then return end
    local new = snapshot(job or jobOf(src))
    if not new then return end
    local old = S.known[src]
    S.known[src] = new
    if not old or old.name ~= new.name or old.type ~= new.type or old.grade ~= new.grade then
        emit(M.EVENTS.jobChanged, src)
    end
    if old and old.onduty ~= nil and old.onduty ~= new.onduty then
        emit(M.EVENTS.dutyChanged, src, new.onduty)
    end
end

function M.handlers.duty(src, onduty)
    src = validSrc(src)
    if not src then return end
    onduty = onduty == true
    local known = S.known[src]
    if known and known.onduty == onduty then return end
    if known then
        known.onduty = onduty
    else
        known = snapshot(jobOf(src)) or {}
        known.onduty = onduty
        S.known[src] = known
    end
    emit(M.EVENTS.dutyChanged, src, onduty)
end

function M.handlers.updated(src, player)
    src = validSrc(src)
    if not src or #S.updated == 0 then return end
    player = player or M.getPlayer(src)
    if not player then return end
    for _, fn in ipairs(S.updated) do
        local ok, err = pcall(fn, src, player)
        if not ok then log.error('player update listener failed: %s', tostring(err)) end
    end
end

function M.handlers.changed(id, locked)
    if id == nil then return end
    emit(M.EVENTS.doorChanged, id, locked == true)
end

--- Players already online (fredpd_core restart): remember their jobs so the next change is detected and a later
--- unload is reported.
function M.primeOnline()
    for _, src in ipairs(M.getPlayers()) do
        if S.known[src] == nil then S.known[src] = snapshot(jobOf(src)) or {} end
    end
end

---------------------------------------------------------------------------------------------------------------
-- inventory

function M.count(src, item)
    src = validSrc(src)
    if not src or not validItem(item) then return 0 end
    return M.call('inventory', 'count', src, item)
end

--- { { slot, metadata }, ... } of an item in a player's inventory whose metadata contains every key/value of filter.
function M.find(src, item, filter)
    src = validSrc(src)
    if not src or not validItem(item) then return {} end
    if filter ~= nil and type(filter) ~= 'table' then return {} end
    return M.call('inventory', 'find', src, item, filter)
end

function M.add(src, item, count, metadata)
    src, count = validSrc(src), validCount(count)
    if not src or not count or not validItem(item) then return false end
    if metadata ~= nil and type(metadata) ~= 'table' then return false end
    return M.call('inventory', 'add', src, item, count, metadata) == true
end

function M.remove(src, item, count, slot)
    src, count = validSrc(src), validCount(count)
    if not src or not count or not validItem(item) then return false end
    slot = slot ~= nil and math.tointeger(tonumber(slot)) or nil
    return M.call('inventory', 'remove', src, item, count, slot) == true
end

--- Run the registered fn of an item for a use the inventory reported (qb: qb-core usable item; ox: useItem export).
--- The item data comes from the inventory resource, never from the client. Returns false when fn returned false.
function M.dispatchUse(src, item, slot, metadata)
    local fn = S.usable[item]
    src = validSrc(src)
    if not fn or not src then return nil end
    local ok, result = pcall(fn, src, slot, type(metadata) == 'table' and metadata or {})
    if not ok then
        log.error('usable item %s failed: %s', tostring(item), tostring(result))
        return nil
    end
    if result == false then return false end
    return nil
end

local function applyUsable(item)
    return M.call('inventory', 'registerUsable', item, M.dispatchUse)
end

--- registerUsable(item, fn(src, slot, metadata)). Remembered, so it is applied again when the inventory/framework
--- resource (re)starts. qb: qb-core CreateUseableItem; ox: the item definition's server.export =
--- 'fredpd_core.useItem' (bridge/inventory/ox_inventory.lua).
function M.registerUsable(item, fn)
    if not validItem(item) or not callable(fn) then return false end
    S.usable[item] = fn
    applyUsable(item)
    return true
end

--- ox_inventory item callback (export useItem; only ox_inventory may call it, see M.register).
function M.useItem(event, item, inventory, slot)
    local impl = S.impls.inventory
    if S.chosen.inventory ~= 'ox_inventory' or not impl or not impl.fromUseExport then return nil end
    local src, name, s, metadata = impl.fromUseExport(event, item, inventory, slot)
    if not src then return nil end
    return M.dispatchUse(src, name, s, metadata)
end

---------------------------------------------------------------------------------------------------------------
-- doorlock

local function validDoorId(id)
    return (type(id) == 'number' and id == id) or (type(id) == 'string' and id ~= '' and #id <= 128)
end

--- { id, name, locked, coords } or nil.
function M.getDoor(id)
    if not validDoorId(id) then return nil end
    local door, reason = M.call('doorlock', 'getDoor', id)
    if reason == 'unpatched' then M.warnUnpatched() end
    return door
end

--- Lock/unlock a door. No authorisation happens in the doorlock resource on this path: the caller checks grants,
--- duty and distance first. src (optional) is the player the change is attributed to.
function M.setLocked(id, locked, src)
    if not validDoorId(id) or type(locked) ~= 'boolean' then return false end
    local ok, reason = M.call('doorlock', 'setLocked', id, locked, validSrc(src))
    if reason == 'unpatched' then M.warnUnpatched() end
    return ok == true
end

function M.warnUnpatched()
    warnOnce('doorlock:unpatched', 'qb-doorlock has no FredPD exports (patches/qb-doorlock.10-fredpd-bridge.patch not '
        .. 'applied): door lookups and breach are disabled')
end

---------------------------------------------------------------------------------------------------------------
-- Wiring

--- Register exports and upstream event handlers. Call after M.load.
function M.register()
    exports('getPlayer', M.getPlayer)
    exports('getPlayerByCitizenId', M.getPlayerByCitizenId)
    exports('getPlayers', M.getPlayers)
    exports('removeMoney', M.removeMoney)
    exports('addMoney', M.addMoney)
    exports('count', M.count)
    exports('find', M.find)
    exports('add', M.add)
    exports('remove', M.remove)
    exports('registerUsable', M.registerUsable)
    exports('getDoor', M.getDoor)
    exports('setLocked', M.setLocked)
    exports('hasFeature', M.hasFeature)
    exports('bridgeInfo', M.info)
    -- ox_inventory's item callback (server.export = 'fredpd_core.useItem'): any other resource could fake a use.
    Core.internalExport('useItem', M.useItem, { 'ox_inventory' })

    local fw = S.impls.framework
    if fw then
        fw.bind({
            loaded = M.handlers.loaded, unloaded = M.handlers.unloaded, job = M.handlers.job,
            duty = M.handlers.duty, updated = M.handlers.updated,
        })
    end
    local door = S.impls.doorlock
    if door then door.bind({ changed = M.handlers.changed }) end

    -- A disconnect: qb-core also fires OnPlayerUnload (server/events.lua:17), qbx_core does not; either way once.
    AddEventHandler('playerDropped', function()
        M.handlers.unloaded(tonumber(source))
    end)

    -- An upstream resource (re)started after fredpd_core: drop cached handles, re-apply usable items, re-prime.
    AddEventHandler('onResourceStart', function(resource)
        for kind, mod in pairs(S.modules) do
            local impl = S.impls[kind]
            if impl and (mod.resource == resource or (mod.REQUIRES and M.requires(mod, resource))) then
                if impl.reset then impl.reset() end
                if kind == 'inventory' then
                    for item in pairs(S.usable) do applyUsable(item) end
                elseif kind == 'framework' then
                    M.primeOnline()
                end
            end
        end
    end)
end

--- True when a module needs `resource` for one of its methods.
function M.requires(mod, resource)
    for _, r in pairs(mod.REQUIRES or {}) do
        if r == resource then return true end
    end
    return false
end

return M
