-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_forensics server against a real MariaDB (tests/lua/mysql_shim.lua runs the migrations and fakes oxmysql),
-- with FiveM mocked: fredpd_core (grants from GrantSets, canView = shared/canview.lua over the seeded rules, audit =
-- the real fredpd_core audit writer), an in-memory ox_inventory that runs registered hooks exactly like
-- ox_inventory modules/hooks/server.lua (filters, `false` blocks, post-hook events), evidences' collect / setAnalysed
-- steps, players, events, timers, lib.callback. Covers main.lua wiring, collect (createItem hook), the swapItems hook
-- (never blocks, custody in the post-hook event), analysis upsert + result whitelist + person match, the §5.7 story,
-- link authorization, tag numbering incl. a concurrent link, visibility shaping, chain cap, containers, UTC, and
-- writes the golden JSON checked by resources/[fredpd]/fredpd_forensics/test/contract.test.ts.
-- Database fredpd_test_forensics_lua (reset once per run); every session at time_zone '+02:00' (§C7).
-- Framework bridge (docs/contracts.md §C17): the fredpd_core mock's bridgeInfo is the REAL server/bridge.lua, loaded
-- with ox_inventory + ox_target (evidences needs them) and the framework of FREDPD_FORENSICS_STACK: qb (default,
-- qb-core mock) or qbx (qbx_core mock); the real fredpd_core audit resolves the actor through it.
-- tests/lua/forensics_bridge_test.lua reuses this environment (require returns H) for the qb/ox matrix.
-- Run: lua5.4 tests/lua/run.lua forensics_server   (FREDPD_FORENSICS_STACK=qbx for the Qbox framework)
local shim = require('mysql_shim')
local helper = require('helper')

local DB = 'fredpd_test_forensics_lua'
local FORENSICS = './resources/[fredpd]/fredpd_forensics/'
local GOLDEN = FORENSICS .. 'test/golden/'
local MODULES = { 'config', 'shared.evidence', 'server.store', 'server.service', 'server.main' }
local ISO = '^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$'
local LOCKER = 'evidence_locker_mrpd'
local FP1 = 'A1B2C3D4E5F60718'
local FP2 = 'FFEEDDCCBBAA0099'

local tests = {}

local STACK = os.getenv('FREDPD_FORENSICS_STACK') == 'qbx' and 'qbx' or 'qb'

--- Bridge config per stack name: the framework of the stack with the ox pair evidences needs; 'qb-only' is the
--- plain QBCore server (qb-inventory + qb-target: evidence off).
local BRIDGE_CFG = {
    qb = { framework = 'qb-core', inventory = 'ox_inventory', target = 'ox_target' },
    qbx = { framework = 'qbx_core', inventory = 'ox_inventory', target = 'ox_target' },
    ['qb-only'] = { framework = 'qb-core', inventory = 'qb-inventory', target = 'qb-target' },
}

---------------------------------------------------------------------------------------------------------------
-- Environment

for _, name in ipairs({ 'time', 'locale', 'format', 'regex', 'grants' }) do
    package.preload['@fredpd_core.shared.' .. name] = function() return require('shared.' .. name) end
end

local SV = (function()
    local dict = helper.readJson('locales/sv.json')
    local f = io.open('locales/pending/forensics.json', 'r')
    if f then
        for k, v in pairs(json.decode(f:read('a'))) do
            if type(v) == 'table' and v.sv then dict[k] = v.sv end
        end
        f:close()
    end
    return dict
end)()

local function deepcopy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = deepcopy(x) end
    return out
end

local function set(list)
    local out = {}
    for _, k in ipairs(list) do out[#out + 1] = k end
    table.sort(out)
    return out
end

-- 1 Tekniker (assigned to case 1 and 4), 2 Utredare (owner of case 1), 3 IGV without evidence.link, 4 off duty,
-- 5 Spaning with evidence.link (case 1 = kontaktnotis), 6 civilian, 7 records.admin, 8 Utredare tier 0 (closed case
-- 2 = masked), 9 Utredare without mdt_page:evidence (case page only).
local function defaultPlayers()
    return {
        [1] = { cid = 'FOR10001', duty = true, tier = 1, units = { 'tekniker' },
            grants = set({ 'mdt_page:evidence', 'perm:evidence.link', 'unit:tekniker' }) },
        [2] = { cid = 'FOR10002', duty = true, tier = 1, units = { 'utredning' },
            grants = set({ 'mdt_page:evidence', 'perm:evidence.link', 'unit:utredning' }) },
        [3] = { cid = 'FOR10003', duty = true, tier = 0, units = { 'igv' }, grants = set({ 'mdt_page:evidence', 'unit:igv' }) },
        [4] = { cid = 'FOR10004', duty = false, tier = 1, units = { 'tekniker' },
            grants = set({ 'mdt_page:evidence', 'perm:evidence.link', 'unit:tekniker' }) },
        [5] = { cid = 'FOR10005', duty = true, tier = 0, units = { 'span' },
            grants = set({ 'mdt_page:evidence', 'perm:evidence.link', 'unit:span' }) },
        [6] = { cid = 'CIV60006', duty = false, tier = 0, units = {}, grants = {} },
        [7] = { cid = 'FOR10007', duty = true, tier = 2, units = { 'ledning' },
            grants = set({ 'mdt_page:evidence', 'perm:records.admin', 'unit:ledning' }) },
        [8] = { cid = 'FOR10008', duty = true, tier = 0, units = { 'utredning' },
            grants = set({ 'mdt_page:evidence', 'unit:utredning' }) },
        [9] = { cid = 'FOR10009', duty = true, tier = 0, units = { 'utredning' }, grants = set({ 'unit:utredning' }) },
    }
end

local OFFICERS = {
    { 'FOR10001', '100000000000000001', 'Tove T.', 'TEK-01', 'tekniker' },
    { 'FOR10002', '100000000000000002', 'Ulf U.', 'UTR-02', 'utredning' },
    { 'FOR10003', '100000000000000003', 'Ida I.', 'IGV-03', 'igv' },
}

-- id, number, title, status, level, unit, owner
local CASES = {
    { 1, 'K-123-26', 'Inbrott Vinewood', 'open', 0, 'utredning', 'FOR10002' },
    { 2, 'K-124-26', 'Stöld Del Perro', 'closed', 0, 'utredning', 'FOR10002' },
    { 3, 'K-125-26', 'Spaningsärende', 'open', 2, 'span', 'FOR10099' },
    { 4, 'K-7-26', 'Skadegörelse', 'open', 0, 'tekniker', 'FOR10001' },
}
local ASSIGNEES = { { 1, 'FOR10002', 'lead' }, { 1, 'FOR10001', 'member' }, { 2, 'FOR10001', 'member' },
    { 4, 'FOR10001', 'lead' } }

local LAB_POS = { x = 474.6, y = -990.4, z = 26.3 }

local prepared, notified = nil, false

local GLOBALS = { 'MySQL', 'LoadResourceFile', 'GetCurrentResourceName', 'exports', 'GetPlayers', 'GetPlayerName',
    'GetGameTimer', 'SetTimeout', 'CreateThread', 'TriggerEvent', 'TriggerClientEvent', 'GetResourceState',
    'AddEventHandler', 'lib', 'GetEntityCoords', 'GetPlayerPed', 'GetPlayerIdentifierByType', 'source', 'locale',
    'vec3', 'vec4', 'SetConvarReplicated' }

local function clearModules()
    for _, name in ipairs(MODULES) do package.loaded[name] = nil end
end

--- Load fredpd_forensics' server/main.lua (which starts the resource against the mocks) with fresh module state.
local function loadResource()
    clearModules()
    local saved = package.path
    package.path = FORENSICS .. '?.lua;' .. package.path
    local ok, main = pcall(require, 'server.main')
    local mods = {
        main = main,
        service = package.loaded['server.service'],
        store = package.loaded['server.store'],
        evidence = package.loaded['shared.evidence'],
        config = package.loaded['config'],
    }
    package.path = saved
    if not ok then error(main, 0) end
    return mods
end

local function makeEnv(opts)
    opts = opts or {}
    local Audit = require('server.audit')
    local CanView = require('shared.canview')
    local Grants = require('shared.grants')
    local CoreCanView = require('server.canview')
    local rules = {}
    for _, row in ipairs(MySQL.query.await(CoreCanView.RULES_SQL)) do rules[#rules + 1] = CoreCanView.rowToRule(row) end

    local env = {
        now = 100000, timers = {}, players = defaultPlayers(), events = {}, clientEvents = {}, pushes = {},
        audits = {}, handlers = {}, exported = {}, callbacks = {}, logs = {}, hooks = {}, stashes = {},
        inv = {}, positions = {}, sqlCalls = 0, uidSeq = 0, rules = rules,
        resources = { fredpd_mdt = 'started', ox_inventory = 'started', evidences = 'started', fredpd_core = 'started',
            ox_target = 'started', ['qb-core'] = 'started', qbx_core = 'started' },
        oxAccess = {}, -- every exports.ox_inventory:<fn> looked up, in order
        convars = {},
    }
    for k, v in pairs(opts.resources or {}) do env.resources[k] = v ~= false and v or nil end

    local function player(src) return env.players[tonumber(src)] end
    local function setOf(p)
        return { grants = p.grants, denied = {}, tier = p.tier, units = p.units, rank = nil }
    end
    local function viewer(src)
        local p = player(src)
        if not p then return { citizenid = nil, tier = 0, units = {}, grants = Grants.empty(0) } end
        return { citizenid = p.cid, tier = p.tier, units = p.units, grants = setOf(p) }
    end

    local core = {
        hasGrant = function(_, src, t, k)
            local p = player(src)
            return p ~= nil and Grants.has(setOf(p), t, k)
        end,
        isOnDuty = function(_, src) local p = player(src); return p ~= nil and p.duty == true end,
        getCitizenId = function(_, src) local p = player(src); return p and p.cid or nil end,
        getTier = function(_, src) local p = player(src); return p and p.tier or 0 end,
        getUnits = function(_, src) local p = player(src); return p and deepcopy(p.units) or {} end,
        canView = function(_, src, record) return CanView.evaluate(viewer(src), record, rules) end,
        canViewMany = function(_, src, records)
            local out = {}
            for i, r in ipairs(records) do out[i] = CanView.evaluate(viewer(src), r, rules) end
            return out
        end,
        bridgeInfo = function() return require('server.bridge').info() end,
        audit = function(_, src, action, targetType, targetId, meta)
            env.audits[#env.audits + 1] = { src = src, action = action, targetType = targetType, targetId = targetId,
                meta = meta }
            return Audit.audit(src, action, targetType, targetId, meta)
        end,
    }
    local mdt = {
        pushToOpenTablets = function(_, topic, payload)
            env.pushes[#env.pushes + 1] = { topic = topic, payload = payload }
        end,
    }
    local qbx = {
        GetPlayer = function(_, src)
            local p = player(src)
            return p and { PlayerData = { citizenid = p.cid, source = tonumber(src) } } or nil
        end,
    }
    -- qb-core (shared/main.lua:7-18 GetCoreObject, server/functions.lua:46-52 GetPlayer), what the qb bridge reads.
    local qbcore = {
        GetCoreObject = function()
            return { Functions = {
                GetPlayer = function(src)
                    local p = player(src)
                    return p and { PlayerData = { citizenid = p.cid, source = tonumber(src) }, Functions = {} } or nil
                end,
            } }
        end,
    }

    ----------------------------------------------------------------------------------------------------------
    -- ox_inventory (in memory): inventories[id][slot] = { name, slot, count, metadata }; hooks as upstream

    local function slots(id)
        env.inv[id] = env.inv[id] or {}
        return env.inv[id]
    end

    local function itemFilterOk(filter, item, second)
        local name = type(item) == 'table' and item.name or item
        if not name or not filter[name] then
            if type(second) ~= 'table' or not filter[second.name] then return false end
        end
        return true
    end

    local function inventoryFilterOk(filter, a, b)
        for _, p in ipairs(filter) do
            if a:match(p) or (b and b:match(p)) then return true end
        end
        return false
    end

    --- ox_inventory TriggerEventHooks: returns ok (false = blocked), the invoked hook ids, the createItem result.
    function env.runHooks(event, payload)
        local ids, result = {}, nil
        local from = payload.fromInventory and tostring(payload.fromInventory) or payload.inventoryId
            and tostring(payload.inventoryId)
        local to = payload.toInventory and tostring(payload.toInventory)
        for _, hook in ipairs(env.hooks) do
            if hook.event == event then
                local o = hook.options or {}
                local skip = (o.itemFilter and not itemFilterOk(o.itemFilter, payload.fromSlot or payload.item,
                    payload.toSlot)) or (o.inventoryFilter and not inventoryFilterOk(o.inventoryFilter, from, to))
                if not skip then
                    ids[#ids + 1] = hook.id
                    local okCall, response = pcall(hook.fn, payload)
                    if event == 'createItem' then
                        if okCall and type(response) == 'table' then payload.metadata = response end
                        result = payload.metadata
                    elseif response == false then
                        return false, ids
                    end
                end
            end
        end
        return true, ids, result
    end

    --- Post-hook events: TriggerEvent(hookId, success, payload), 50 ms later (modules/hooks/server.lua:34-54).
    function env.postHooks(ids, success, payload)
        local copy = deepcopy(payload)
        SetTimeout(50, function()
            for _, id in ipairs(ids) do env.fire(id, '', success, copy) end
        end)
    end

    --- AddItem(inv, name, 1, metadata) through Items.Metadata's createItem hook (on a clone of `metadata`, like
    --- ox_inventory modules/inventory/server.lua:1147-1174). `metadataCalls` = 2: AddItem ran Items.Metadata twice
    --- (a given slot that did not fit); only the last result lands. Returns the slot.
    function env.addItem(invId, name, metadata, resource, metadataCalls)
        local payload, ids, result
        for _ = 1, metadataCalls or 1 do
            payload = { inventoryId = invId, metadata = deepcopy(metadata or {}), item = { name = name }, count = 1,
                resource = resource or 'evidences' }
            local _
            _, ids, result = env.runHooks('createItem', payload)
            env.postHooks(ids, true, payload)
        end
        local inv = slots(invId)
        local slot = 1
        while inv[slot] do slot = slot + 1 end
        inv[slot] = { name = name, slot = slot, count = 1, metadata = result or payload.metadata }
        return slot
    end

    --- ox_inventory giveItem (modules/inventory/server.lua:2491-2556): swapItems hooks (action 'give'), AddItem on
    --- the recipient with the item's own metadata, RemoveItem on the giver; `undo` = RemoveItem failed, so the added
    --- item is removed again. Returns ok, the recipient's slot.
    function env.give(from, slot, to, undo)
        local data = slots(from)[slot]
        local payload = { source = from, fromInventory = from, fromType = 'player', toInventory = to,
            toType = 'player', count = 1, action = 'give', fromSlot = deepcopy(data) }
        local okHooks, ids = env.runHooks('swapItems', payload)
        if not okHooks then return false end
        local toSlot = env.addItem(to, data.name, data.metadata, 'ox_inventory')
        if undo then
            slots(to)[toSlot] = nil
            env.postHooks(ids, false, payload)
            return false
        end
        slots(from)[slot] = nil
        env.postHooks(ids, true, payload)
        return true, toSlot
    end

    --- evidences collect (server/evidences/actions.lua:61-75): AddItem, then atItem copies the client metadata and
    --- sets metadata[key] = { owner, createdAt }.
    function env.collect(src, name, key, owner, extra)
        local slot = env.addItem(src, name)
        local md = env.inv[src][slot].metadata
        local clientMeta = {
            createdAt = 1790000000,
            information = { collectionTime = '29.09.2026 12:02', crimeScene = 'Vespucci Blvd', additionalData = 'på marken' },
            ballistics = {},
        }
        for k, v in pairs(extra or {}) do clientMeta[k] = v end
        for k, v in pairs(clientMeta) do md[k] = v end
        md[key] = md[key] or {}
        md[key].owner = owner
        md[key].createdAt = 1790000000
        return slot
    end

    --- ox_inventory swapItems (move to an empty slot, or swap with the item there). Returns ok, blocked.
    function env.move(src, fromInv, fromSlot, toInv, toSlot, fail)
        local item = slots(fromInv)[fromSlot]
        local target = slots(toInv)[toSlot]
        local payload = {
            source = src, fromInventory = fromInv, fromSlot = deepcopy(item),
            fromType = type(fromInv) == 'number' and 'player' or 'stash',
            toInventory = toInv, toSlot = target and deepcopy(target) or toSlot,
            toType = type(toInv) == 'number' and 'player' or 'stash', count = 1,
            action = target and 'swap' or 'move',
        }
        local okHooks, ids = env.runHooks('swapItems', payload)
        if not okHooks then return false, true end
        if fail then
            env.postHooks(ids, false, payload)
            return false
        end
        slots(fromInv)[fromSlot] = target and deepcopy(target) or nil
        if target then slots(fromInv)[fromSlot].slot = fromSlot end
        slots(toInv)[toSlot] = deepcopy(item)
        slots(toInv)[toSlot].slot = toSlot
        env.postHooks(ids, true, payload)
        return true
    end

    --- evidences setAnalysed (server/dui/callbacks.lua:184-211, patched): mark analysed, then the event.
    function env.analyse(src, invId, slot, key, information, noInventoryArg)
        local item = slots(invId)[slot]
        item.metadata[key].analysed = true
        item.metadata.information = item.metadata.information or {}
        item.metadata.information[key] = item.metadata[key].owner
        for k, v in pairs(information or {}) do item.metadata.information[k] = v end
        env.fire('evidences:evidenceItemAnalysed', '', src, deepcopy(item), not noInventoryArg and invId or nil)
    end

    local inventory = {
        registerHook = function(_, event, fn, options)
            local id = ('fredpd_forensics:%s:%d'):format(event, #env.hooks + 1)
            env.hooks[#env.hooks + 1] = { event = event, fn = fn, options = options, id = id }
            return id
        end,
        RegisterStash = function(_, ...) env.stashes[#env.stashes + 1] = { ... } end,
        GetSlot = function(_, invId, slot) return deepcopy(slots(invId)[slot]) end,
        SetMetadata = function(_, invId, slot, md)
            local item = slots(invId)[slot]
            if item then item.metadata = deepcopy(md) end
        end,
        GetSlotsWithItem = function(_, invId, name, md)
            local out = {}
            for _, item in pairs(slots(invId)) do
                local match = item.name == name
                for k, v in pairs(md or {}) do
                    if not item.metadata or item.metadata[k] ~= v then match = false end
                end
                if match then out[#out + 1] = deepcopy(item) end
            end
            return out
        end,
        GetContainerFromSlot = function(_, invId, slot)
            local item = slots(invId)[slot]
            env.loadedContainer = item and item.metadata and item.metadata.container
        end,
        GetInventoryItems = function(_, invId) return deepcopy(env.inv[invId]) end,
    }

    ----------------------------------------------------------------------------------------------------------
    -- Timers, events, globals

    function env.advance(ms)
        local target = env.now + ms
        for _ = 1, 1000 do
            table.sort(env.timers, function(a, b) return a.at < b.at end)
            local nextTimer = env.timers[1]
            if not nextTimer or nextTimer.at > target then break end
            table.remove(env.timers, 1)
            env.now = nextTimer.at
            nextTimer.fn()
        end
        env.now = target
    end

    function env.fire(name, eventSource, ...)
        local saved = rawget(_G, 'source')
        rawset(_G, 'source', eventSource)
        for _, fn in ipairs(env.handlers[name] or {}) do fn(...) end
        rawset(_G, 'source', saved)
    end

    function env.clear()
        env.events, env.clientEvents, env.pushes, env.audits, env.logs = {}, {}, {}, {}, {}
    end

    function env.eventsNamed(name, list)
        local out = {}
        for _, e in ipairs(list or env.events) do
            if e.name == name then out[#out + 1] = e end
        end
        return out
    end

    function env.auditActions()
        local out = {}
        for _, a in ipairs(env.audits) do out[#out + 1] = a.action end
        return out
    end

    local formatsJson = helper.readFile('config/formats.json')
    local shimLoad = LoadResourceFile

    env.globals = {
        exports = setmetatable({ fredpd_core = core, fredpd_mdt = mdt, qbx_core = qbx, ['qb-core'] = qbcore,
            ox_inventory = setmetatable({}, { __index = function(_, k)
                env.oxAccess[#env.oxAccess + 1] = k
                return inventory[k]
            end }) }, {
            __call = function(_, name, fn) env.exported[name] = fn end,
        }),
        LoadResourceFile = function(resource, path)
            if resource == 'fredpd_core' and path == 'config/formats.json' then
                if env.noFormats then return nil end
                return formatsJson
            end
            return shimLoad(resource, path)
        end,
        GetPlayers = function()
            local ids = {}
            for src in pairs(env.players) do ids[#ids + 1] = tostring(src) end
            table.sort(ids)
            return ids
        end,
        GetPlayerName = function(src) local p = player(src); return p and ('acct_' .. p.cid) or nil end,
        GetPlayerIdentifierByType = function(src) return ('discord:%d'):format(900000000000000000 + tonumber(src)) end,
        GetGameTimer = function() return env.now end,
        SetTimeout = function(ms, fn) env.timers[#env.timers + 1] = { at = env.now + ms, fn = fn } end,
        CreateThread = function(fn) fn() end,
        TriggerEvent = function(name, ...) env.events[#env.events + 1] = { name = name, args = { ... } } end,
        TriggerClientEvent = function(name, target, ...)
            env.clientEvents[#env.clientEvents + 1] = { name = name, target = target, args = { ... } }
        end,
        GetResourceState = function(name) return env.resources[name] or 'missing' end,
        SetConvarReplicated = function(name, value) env.convars[name] = value end,
        AddEventHandler = function(name, fn)
            env.handlers[name] = env.handlers[name] or {}
            table.insert(env.handlers[name], fn)
        end,
        GetPlayerPed = function(src) return 1000 + tonumber(src) end,
        GetEntityCoords = function(ped) return env.positions[ped - 1000] or { x = 0.0, y = 0.0, z = 0.0 } end,
        locale = function(key) return SV[key] or key end,
        vec3 = function(x, y, z) return { x = x, y = y, z = z } end,
        vec4 = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end,
        lib = {
            callback = { register = function(name, fn) env.callbacks[name] = fn end },
            print = setmetatable({}, { __index = function(_, level)
                return function(msg) env.logs[#env.logs + 1] = { level = level, msg = msg } end
            end }),
        },
    }

    --- Deterministic uids: EV + 16 hex of a counter.
    function env.useFixedUids(mods)
        mods.service.newUid = function()
            env.uidSeq = env.uidSeq + 1
            return ('EV%016X'):format(env.uidSeq)
        end
    end

    -- The real fredpd_core bridge (docs/contracts.md §C17): audit resolves the actor through it and the core mock's
    -- bridgeInfo reports it; resource states are env.resources, live.
    env.stack = opts.stack or STACK
    local quiet = function() end
    env.bridgeCfg = BRIDGE_CFG[env.stack] or opts.bridge
    require('server.bridge').load(env.bridgeCfg, {
        stateOf = function(name) return env.resources[name] or 'missing' end,
        log = { info = quiet, warn = quiet, error = quiet, debug = quiet }, defer = quiet,
    })
    return env
end

--- Run fn(t, env, mods) with MariaDB + mocks installed; restores every global afterwards.
--- opts = { stack = 'qb' | 'qbx' | 'qb-only' (default FREDPD_FORENSICS_STACK), resources = { name = state | false } }.
local function withEnv(t, fn, opts)
    local ok, reason = shim.available()
    if not ok then
        if not notified then
            print(('SKIP forensics_server_test: MariaDB unreachable (%s)'):format((reason or ''):gsub('%s+$', '')))
            notified = true
        end
        return
    end
    local saved = {}
    for _, n in ipairs(GLOBALS) do saved[n] = { rawget(_G, n) } end
    local savedDatabase, savedResource = shim.database, shim.resourceName
    local okRun, err = pcall(function()
        shim.install({ database = DB, sessionTimeZone = '+02:00' })
        shim.resourceName = 'fredpd_core'
        if prepared == nil then
            prepared = false
            shim.resetDatabase(DB, true)
            require('server.db').migrate({ log = function() end, resource = 'fredpd_core' })
            -- evidences' registers (linked_biometrics.lua:10-28, firearms.lua:10-24), trimmed to the columns read.
            MySQL.query.await('CREATE TABLE linked_fingerprint (fingerprint VARCHAR(16) PRIMARY KEY, '
                .. 'identifier VARCHAR(500) NOT NULL UNIQUE)')
            MySQL.query.await('CREATE TABLE linked_dna (dna VARCHAR(16) PRIMARY KEY, identifier VARCHAR(500) NOT NULL UNIQUE)')
            MySQL.query.await('CREATE TABLE firearms_registry (serial VARCHAR(15) NOT NULL PRIMARY KEY, '
                .. 'identifier VARCHAR(500) NOT NULL)')
            prepared = true
        end
        if not prepared then return end
        -- Clean slate per test (the schema stays).
        MySQL.query.await('DELETE FROM fredpd_evidence')
        MySQL.query.await('ALTER TABLE fredpd_evidence AUTO_INCREMENT = 1')
        MySQL.query.await('DELETE FROM fredpd_case_assignees')
        MySQL.query.await('DELETE FROM fredpd_cases')
        MySQL.query.await("DELETE FROM fredpd_audit WHERE action LIKE 'evidence.%'")
        MySQL.query.await('DELETE FROM linked_fingerprint')
        MySQL.query.await('DELETE FROM linked_dna')
        MySQL.query.await('DELETE FROM firearms_registry')
        for _, r in ipairs(OFFICERS) do
            MySQL.query.await('INSERT IGNORE INTO fredpd_officers (citizenid, discord_id, display_name, callsign, unit) '
                .. 'VALUES (?, ?, ?, ?, ?)', r)
        end
        MySQL.query.await("INSERT IGNORE INTO fredpd_persons (citizenid, firstname, lastname) VALUES "
            .. "('SUS00001', 'Sven', 'Svensson')")
        for _, c in ipairs(CASES) do
            MySQL.query.await('INSERT INTO fredpd_cases (id, case_number, title, status, level, unit, owner_citizenid) '
                .. 'VALUES (?, ?, ?, ?, ?, ?, ?)', c)
        end
        for _, a in ipairs(ASSIGNEES) do
            MySQL.query.await('INSERT INTO fredpd_case_assignees (case_id, citizenid, role) VALUES (?, ?, ?)', a)
        end
        MySQL.query.await("INSERT INTO linked_fingerprint (fingerprint, identifier) VALUES (?, 'SUS00001')", { FP1 })
        MySQL.query.await("INSERT INTO firearms_registry (serial, identifier) VALUES ('SER123456', 'SUS00001')")
        local env = makeEnv(opts)
        for k, v in pairs(env.globals) do rawset(_G, k, v) end
        rawset(_G, 'source', nil)
        local mods = loadResource()
        env.useFixedUids(mods)
        fn(t, env, mods)
    end)
    for n, v in pairs(saved) do rawset(_G, n, v[1]) end
    clearModules()
    require('bridge_harness_test').reset()
    shim.sessionTimeZone = nil
    shim.database, shim.resourceName = savedDatabase, savedResource
    if not okRun then error(err, 0) end
end

local function scalar(sql, params) return MySQL.scalar.await(sql, params) end

local function chainActions(row)
    local out = {}
    for _, e in ipairs(row and row.chain or {}) do out[#out + 1] = e.action end
    return out
end

local function hookOf(env, event)
    for _, h in ipairs(env.hooks) do
        if h.event == event then return h end
    end
end

--- Collect a fingerprint as src at slot; register it (advance past registerDelayMs). Returns slot, row.
local function collectFingerprint(env, mods, src, owner)
    local slot = env.collect(src, 'collected_fingerprint', 'fingerprint', owner or FP1)
    env.advance(300)
    local uid = env.inv[src][slot].metadata.item_uid
    return slot, mods.store.byUid(uid)
end

local function link(env, src, id, caseNumber)
    env.now = env.now + 5000 -- past the dialog rate limit
    return env.callbacks['fredpd:forensics:link'](src, { id = id, caseNumber = caseNumber })
end

---------------------------------------------------------------------------------------------------------------
-- Wiring

tests['01 main: exports, events, callback, stashes, hooks and formats are registered'] = function(t)
    withEnv(t, function(_, env, mods)
        t.eq(set({ 'listEvidence', 'getEvidence', 'linkEvidence', 'listCaseEvidence' }), (function()
            local names = {}
            for name in pairs(env.exported) do names[#names + 1] = name end
            return set(names)
        end)())
        t.ok(env.handlers['evidences:evidenceItemAnalysed'], 'evidences event')
        t.ok(env.handlers['playerDropped'] and env.handlers['onResourceStart'], 'lifecycle handlers')
        t.ok(env.callbacks['fredpd:forensics:link'], 'dialog callback')
        t.eq(#env.stashes, 1)
        t.eq(env.stashes[1][1], LOCKER)
        t.eq(env.stashes[1][2], 'Bevisförråd')
        t.eq(env.stashes[1][6], { police = 0 })
        local create, swap, open = hookOf(env, 'createItem'), hookOf(env, 'swapItems'), hookOf(env, 'openInventory')
        t.ok(create and swap and open, 'three hooks')
        t.eq(open.options, { inventoryFilter = { '^evidence_', '^evidence%-%d+$' } })
        t.eq(create.options.itemFilter.collected_fingerprint, true)
        t.eq(create.options.itemFilter.evidence_box, nil, 'containers get no uid')
        t.eq(swap.options.inventoryFilter, { '^evidence_', '^evidence%-%d+$' })
        t.eq(swap.options.itemFilter.evidence_box, true)
        t.eq(swap.options.itemFilter.collected_casing, true)
        t.ok(env.handlers[swap.id], 'post-hook event handler for ' .. swap.id)
        t.eq(mods.service.format.tag('K-123-26', 1), 'B-K-123-26-001')
        t.eq(mods.service.format.isCaseNumber('K-123-26'), true)
        t.eq(mods.service.format.isCaseNumber('K123'), false)
        t.eq(mods.service.format.example, 'K-123-26')
        -- ox_inventory restarting drops every hook: they come back, the post-hook handler is not doubled
        env.hooks = {}
        env.fire('onResourceStart', '', 'ox_inventory')
        t.eq(#env.hooks, 3)
        t.eq(#env.handlers[swap.id], 1)
        t.eq(#env.stashes, 2)
    end)
end

tests['02 collect: the createItem hook mints item_uid on new items only; the row follows once the item is there'] =
function(t)
    withEnv(t, function(_, env, mods)
        local hook = hookOf(env, 'createItem')
        t.eq(hook.fn({ inventoryId = 1, metadata = {}, item = { name = 'water' }, count = 1 }), nil, 'not evidence')
        local md = hook.fn({ inventoryId = 1, metadata = { x = 1 }, item = { name = 'collected_casing' }, count = 1 })
        t.ok(mods.evidence.isUid(md.item_uid), 'minted')
        t.eq(md.x, 1)
        t.eq(md.collected_by, 'FOR10001')
        t.ok(md.collected_at:match(ISO))
        -- an item that already has a uid is an existing one on the move: metadata unchanged (nil)
        t.eq(hook.fn({ inventoryId = 1, metadata = { item_uid = 'EV00000000000000FF' },
            item = { name = 'collected_casing' }, count = 1 }), nil, 'a uid passed in is kept')
        env.advance(300) -- neither item was put anywhere: no row, no audit (no phantom evidence)
        t.eq(scalar('SELECT COUNT(*) FROM fredpd_evidence'), 0)
        t.eq(env.auditActions(), {})

        local slot, row = collectFingerprint(env, mods, 1)
        local item = env.inv[1][slot]
        t.ok(mods.evidence.isUid(item.metadata.item_uid))
        t.eq(item.metadata.fingerprint.owner, FP1, 'evidences metadata written after the hook')
        t.ok(row, 'row registered')
        t.eq(row.type, 'fingerprint')
        t.eq({ row.itemName, row.ident }, { 'collected_fingerprint', 'fingerprint:' .. FP1 }, 'uid registry')
        t.eq(row.collectedBy, 'FOR10001')
        t.ok(row.collectedAt:match(ISO))
        t.eq(#row.chain, 1)
        local e = row.chain[1]
        t.eq({ e.action, e.actor, e.location }, { 'collect', 'FOR10001', 'Vespucci Blvd' })
        t.ok(e.at:match(ISO))
        -- UTC although the session runs at +02:00
        local diff = scalar("SELECT ABS(TIMESTAMPDIFF(SECOND, ?, UTC_TIMESTAMP()))", { e.at:gsub('T', ' '):gsub('Z', '') })
        t.ok(tonumber(diff) < 60, 'collect time is UTC (diff ' .. tostring(diff) .. ' s)')
        t.eq(row.collectedAt:sub(1, 16), e.at:sub(1, 16))
        t.eq(row.result, nil)
        t.eq(row.caseId, nil)

        -- AddItem running Items.Metadata twice (a given slot that did not fit): the first uid never lands, one row
        local s2 = env.addItem(1, 'collected_bullet', nil, 'evidences', 2)
        env.advance(300)
        local landed = env.inv[1][s2].metadata.item_uid
        t.ok(mods.store.byUid(landed), 'the landed uid has its row')
        t.eq(scalar('SELECT COUNT(*) FROM fredpd_evidence'), 2)
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_audit WHERE action = 'evidence.collect'"), 2)
    end)
end

tests['03 swapItems hook: always returns true, never touches the database, ignores failed moves'] = function(t)
    withEnv(t, function(_, env, mods)
        local hook = hookOf(env, 'swapItems')
        local calls = 0
        local real = MySQL
        rawset(_G, 'MySQL', setmetatable({}, { __index = function(_, k)
            calls = calls + 1
            return real[k]
        end }))
        for _, payload in ipairs({ nil, 'x', {}, { fromSlot = 'x' },
            { source = 1, fromInventory = 1, toInventory = LOCKER, fromSlot = { name = 'collected_fingerprint' },
                toSlot = 3, action = 'move' } }) do
            t.eq(hook.fn(payload), true)
        end
        rawset(_G, 'MySQL', real)
        t.eq(calls, 0, 'no SQL inside the hook')

        local slot = collectFingerprint(env, mods, 1)
        env.clear()
        t.eq(env.move(1, 1, slot, LOCKER, 1, true), false)
        env.advance(100)
        local row = mods.store.byUid(env.inv[1][slot].metadata.item_uid)
        t.eq(chainActions(row), { 'collect' }, 'a failed move (post-hook success = false) is not a hand-in')
        -- non-evidence and non-locker moves never reach the hook (filters as ox_inventory applies them)
        env.inv[1][9] = { name = 'water', slot = 9, count = 1, metadata = {} }
        local okHooks, ids = env.runHooks('swapItems', { source = 1, fromInventory = 1, toInventory = LOCKER,
            fromSlot = env.inv[1][9], toSlot = 2 })
        t.eq({ okHooks, #ids }, { true, 0 })
        okHooks, ids = env.runHooks('swapItems', { source = 1, fromInventory = 1, toInventory = 2,
            fromSlot = env.inv[1][slot], toSlot = 2 })
        t.eq({ okHooks, #ids }, { true, 0 })
    end)
end

---------------------------------------------------------------------------------------------------------------
-- The §5.7 story

tests['04 §5.7: collect -> analyse (lab) -> Koppla till ärende -> hand-in = 4 chain entries on the case'] = function(t)
    withEnv(t, function(_, env, mods)
        local S = mods.service
        env.positions[1] = LAB_POS
        local slot, row = collectFingerprint(env, mods, 1)
        env.clear()
        env.analyse(1, 1, slot, 'fingerprint')
        local offers = {}
        for _, e in ipairs(env.clientEvents) do
            if e.name == 'fredpd:forensics:client:offerLink' then offers[#offers + 1] = e end
        end
        t.eq(#offers, 1)
        t.eq(offers[1].target, 1)
        t.eq(offers[1].args[1], { id = row.id, type = 'fingerprint', example = 'K-123-26' })
        local analysed = mods.store.byId(row.id)
        t.eq(analysed.result.fingerprint, FP1)
        t.eq(analysed.result.match, { citizenid = 'SUS00001', name = 'Sven Svensson' })
        t.eq(analysed.result.crimeScene, 'Vespucci Blvd')
        t.ok(analysed.result.analysedAt:match(ISO))
        t.eq(analysed.chain[2].location, 'mrpd_lab')
        t.eq(analysed.chain[2].actor, 'FOR10001')

        local res = link(env, 1, row.id, ' k-123-26 ')
        t.eq(res, { ok = true, tag = 'B-K-123-26-001', caseNumber = 'K-123-26' })
        t.eq(#env.eventsNamed('fredpd:evidenceLinked'), 1)
        t.eq(env.eventsNamed('fredpd:evidenceLinked')[1].args, { 1, row.id })
        t.eq(env.pushes, { { topic = 'case', payload = { type = 'evidenceLinked', caseId = 1, evidenceId = row.id } } })

        t.ok(env.move(1, 1, slot, LOCKER, 4))
        env.advance(100)
        local out = S.get(2, { id = row.id }) -- the case owner opens it from the case page
        t.ok(out.ok, tostring(out.error))
        local item = out.data
        t.eq(#item.chain, 4)
        t.eq(chainActions(item), { 'collect', 'analyse', 'link', 'handin' })
        t.eq(item.chain[4].location, LOCKER)
        t.eq(item.chain[3].note, 'K-123-26')
        t.eq(item.chain[1].actor, { citizenid = 'FOR10001', displayName = 'Tove T.', callsign = 'TEK-01',
            unit = 'tekniker' })
        t.eq(item.tag, 'B-K-123-26-001')
        t.eq({ item.caseId, item.caseNumber }, { 1, 'K-123-26' })
        t.eq(item.result.match, { citizenid = 'SUS00001', name = 'Sven Svensson' }, 'owner of the case: full')
        local list = S.list(2, { caseId = 1 })
        t.eq(list.data.total, 1)
        t.eq(list.data.items[1].id, row.id)
        local actions = {}
        for _, a in ipairs(env.audits) do actions[#actions + 1] = a.action end
        t.eq(actions, { 'evidence.analyse', 'evidence.link', 'evidence.handin' })
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_audit WHERE target_type = 'evidence' AND target_id = ?",
            { tostring(row.id) }), 4)
        local meta = json.decode(scalar("SELECT meta FROM fredpd_audit WHERE action = 'evidence.link'"))
        t.eq(meta, { caseId = 1, caseNumber = 'K-123-26', tag = 'B-K-123-26-001', n = 1, via = 'dialog' })
    end)
end

tests['05 hand-in first: handin -> checkout -> analyse -> link -> return; transfer; ox evidence-<n> lockers'] = function(t)
    withEnv(t, function(_, env, mods)
        local slot, row = collectFingerprint(env, mods, 3) -- IGV officer at the scene
        t.eq(row.collectedBy, 'FOR10003')
        t.ok(env.move(3, 3, slot, LOCKER, 1))
        env.advance(100)
        t.ok(env.move(1, LOCKER, 1, 1, 5)) -- Tekniker takes it out
        env.advance(100)
        env.clear()
        env.analyse(1, 1, 5, 'fingerprint')
        t.eq(#env.eventsNamed('fredpd:forensics:client:offerLink', env.clientEvents), 1)
        t.eq(link(env, 1, row.id, 'K-123-26').ok, true)
        t.ok(env.move(1, 1, 5, 'evidence-3', 2)) -- ox_inventory's own police evidence locker
        env.advance(100)
        t.ok(env.move(1, 'evidence-3', 2, LOCKER, 7))
        env.advance(100)
        t.ok(env.move(1, LOCKER, 7, LOCKER, 8)) -- inside one locker: not custody
        env.advance(100)
        local after = mods.store.byId(row.id)
        t.eq(chainActions(after), { 'collect', 'handin', 'checkout', 'analyse', 'link', 'return', 'transfer' })
        t.eq(after.chain[2].actor, 'FOR10003')
        t.eq(after.chain[3].location, LOCKER)
        t.eq(after.chain[6].location, 'evidence-3')
        t.eq(after.chain[7].location, LOCKER)
        -- a swap moves both items: the one in the target slot goes the other way
        local slot2, row2 = collectFingerprint(env, mods, 1, FP2)
        t.ok(env.move(1, 1, slot2, LOCKER, 8)) -- slot 8 holds the first evidence
        env.advance(100)
        t.eq(chainActions(mods.store.byId(row2.id)), { 'collect', 'handin' })
        t.eq(chainActions(mods.store.byId(row.id)), { 'collect', 'handin', 'checkout', 'analyse', 'link', 'return',
            'transfer', 'checkout' })
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Analysis event

tests['06 analysed event: repeat, a copied uid on an analysed row, type mismatch, not analysed, bad player'] =
function(t)
    withEnv(t, function(_, env, mods)
        local S = mods.service
        local slot, row = collectFingerprint(env, mods, 1)
        env.analyse(1, 1, slot, 'fingerprint')
        env.clear()
        env.analyse(1, 1, slot, 'fingerprint') -- evidences re-fires
        t.eq(#mods.store.byId(row.id).chain, 2, 'repeat: no second analyse entry')
        t.eq(#env.clientEvents, 0, 'repeat: no second offer')

        local uid = env.inv[1][slot].metadata.item_uid
        -- A forged item: another fingerprint carrying the same uid
        local forged = { name = 'collected_fingerprint', slot = 9, count = 1, metadata = {
            item_uid = uid, fingerprint = { owner = FP2, analysed = true } } }
        t.eq(S.onAnalysed(1, forged, 1), 'mismatch')
        t.eq(mods.store.byId(row.id).result.fingerprint, FP1, 'stored result kept')
        -- the same uid on a casing (type mismatch)
        local casing = { name = 'collected_casing', slot = 9, count = 1, metadata = {
            item_uid = uid, ballistics = { serial = 'X1', analysed = true } } }
        t.eq(S.onAnalysed(1, casing, 1), 'mismatch')
        t.eq(#env.eventsNamed('evidence.mismatch', (function()
            local out = {}
            for _, a in ipairs(env.audits) do out[#out + 1] = { name = a.action } end
            return out
        end)()), 2)
        -- not analysed, unknown item, no player
        local slot2 = env.collect(1, 'collected_fingerprint', 'fingerprint', FP2)
        env.advance(300)
        t.eq(S.onAnalysed(1, deepcopy(env.inv[1][slot2]), 1), nil)
        t.eq(S.onAnalysed(1, { name = 'water', slot = 1, metadata = {} }, 1), nil)
        t.eq(S.onAnalysed(0, deepcopy(env.inv[1][slot]), 1), nil)
        t.eq(S.onAnalysed(nil, 'x', 1), nil)
        t.eq(mods.store.byUid(env.inv[1][slot2].metadata.item_uid).result, nil)
        -- no FredPD grant: analysis is recorded, no offer
        local slot3 = env.collect(3, 'collected_fingerprint', 'fingerprint', FP2)
        env.advance(300)
        env.clear()
        env.analyse(3, 3, slot3, 'fingerprint')
        t.eq(#env.clientEvents, 0)
        t.ok(mods.store.byUid(env.inv[3][slot3].metadata.item_uid).result, 'analysed')
        t.eq(mods.store.byUid(env.inv[3][slot3].metadata.item_uid).result.match, nil, 'FP2 is in no register')
    end)
end

tests['07 ballistics result + registered firearm; legacy items get a uid where they lie'] = function(t)
    withEnv(t, function(_, env, mods)
        local slot = env.collect(1, 'collected_casing', 'ballistics', 'SER123456', {
            ballistics = { serial = 'SER123456', weaponType = 'Pistol', type = 'casing', imperfections = 'SER123456',
                weaponImage = 'x.png' } })
        env.advance(300)
        env.analyse(1, 1, slot, 'ballistics', { weaponType = 'Pistol' })
        local row = mods.store.byUid(env.inv[1][slot].metadata.item_uid)
        t.eq(row.type, 'casing')
        t.eq(row.result.serial, 'SER123456')
        t.eq(row.result.weaponType, 'Pistol')
        t.eq(row.result.kind, 'casing')
        t.eq(row.result.match, { citizenid = 'SUS00001', name = 'Sven Svensson' })
        t.eq(row.result.imperfections, nil, 'not whitelisted')

        -- An item collected before fredpd_forensics ran: no uid, evidences metadata only.
        env.inv[1][20] = { name = 'collected_fingerprint', slot = 20, count = 1, metadata = {
            fingerprint = { owner = FP2, createdAt = 1790000000, analysed = true },
            information = { crimeScene = 'Grove Street' } } }
        t.eq(mods.service.onAnalysed(1, deepcopy(env.inv[1][20]), nil), nil, 'unpatched evidences: unknown place')
        t.eq(scalar('SELECT COUNT(*) FROM fredpd_evidence'), 1)
        t.eq(mods.service.onAnalysed(1, deepcopy(env.inv[1][20]), 1), 'analysed')
        local uid = env.inv[1][20].metadata.item_uid
        t.ok(mods.evidence.isUid(uid), 'uid stamped on the item')
        local legacy = mods.store.byUid(uid)
        t.eq(chainActions(legacy), { 'collect', 'analyse' })
        t.eq(legacy.chain[1].at, '2026-09-21T14:13:20Z', 'collect time from evidences createdAt')
        t.eq(legacy.chain[1].location, 'Grove Street')
        t.eq(legacy.chain[1].actor, nil)
        t.eq(legacy.collectedBy, nil)
        t.eq(legacy.collectedAt, '2026-09-21T14:13:20Z')
        t.eq({ legacy.itemName, legacy.ident }, { 'collected_fingerprint', 'fingerprint:' .. FP2 })
        t.eq(row.ident, 'ballistics:SER123456|SER123456|Pistol|casing')
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Link

tests['08 link authorization matrix (dialog callback)'] = function(t)
    withEnv(t, function(_, env, mods)
        local slot, row = collectFingerprint(env, mods, 1)
        env.analyse(1, 1, slot, 'fingerprint')
        local id = row.id
        local cases = {
            { 6, id, 'K-123-26', { ok = false, error = 'unauthorized' }, 'civilian' },
            { 3, id, 'K-123-26', { ok = false, error = 'unauthorized' }, 'no perm evidence.link' },
            { 4, id, 'K-123-26', { ok = false, error = 'unauthorized', reason = 'off_duty' }, 'off duty' },
            { 1, id, 'hej', { ok = false, error = 'validation', reason = 'case_number' }, 'bad case number' },
            { 1, 'x', 'K-123-26', { ok = false, error = 'validation', reason = 'id' }, 'bad id' },
            { 1, id, 'K-999-26', { ok = false, error = 'not_found', reason = 'case' }, 'unknown case' },
            { 1, 9999, 'K-123-26', { ok = false, error = 'not_found', reason = 'evidence' }, 'unknown evidence' },
            { 1, id, 'K-125-26', { ok = false, error = 'unauthorized', reason = 'case' }, 'case view notice' },
            { 5, id, 'K-123-26', { ok = false, error = 'unauthorized', reason = 'case' }, 'other unit: notice' },
            { 1, id, 'K-124-26', { ok = false, error = 'validation', reason = 'case_closed' }, 'closed case' },
            { 1, id, 'K-123-26', { ok = true, tag = 'B-K-123-26-001', caseNumber = 'K-123-26' }, 'assigned Tekniker' },
            { 2, id, 'K-123-26', { ok = false, error = 'validation', reason = 'already_linked' }, 'already linked' },
        }
        for _, c in ipairs(cases) do
            t.eq(link(env, c[1], c[2], c[3]), c[4], c[5])
        end
        -- rate limit: a second attempt within 2 s
        env.now = env.now + 5000
        local cb = env.callbacks['fredpd:forensics:link']
        cb(2, { id = id, caseNumber = 'K-123-26' })
        t.eq(cb(2, { id = id, caseNumber = 'K-123-26' }), { ok = false, error = 'rate_limited' })
        -- playerDropped clears the limiter
        env.fire('playerDropped', 2)
        t.eq(cb(2, { id = id, caseNumber = 'K-123-26' }).reason, 'already_linked')
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_audit WHERE action = 'evidence.link'"), 1)
        -- records.admin sees every case in full but still needs perm evidence.link to link
        local slot2, row2 = collectFingerprint(env, mods, 1, FP2)
        env.analyse(1, 1, slot2, 'fingerprint')
        t.eq(link(env, 7, row2.id, 'K-123-26'), { ok = false, error = 'unauthorized' })
        -- evidence not analysed by me and not visible: Spaning holder of evidence.link sees the unlinked queue
        t.eq(link(env, 5, row2.id, 'K-7-26'), { ok = false, error = 'unauthorized', reason = 'case' })
    end)
end

tests['09 tags: numbered per case, and a concurrent link that took n makes the loser retry once'] = function(t)
    withEnv(t, function(_, env, mods)
        local ids = {}
        for i = 1, 4 do
            local slot, row = collectFingerprint(env, mods, 1, ('%016X'):format(i))
            env.analyse(1, 1, slot, 'fingerprint')
            ids[i] = row.id
        end
        t.eq(link(env, 1, ids[1], 'K-123-26').tag, 'B-K-123-26-001')
        t.eq(link(env, 1, ids[2], 'K-7-26').tag, 'B-K-7-26-001', 'per case')
        -- Evidence 3: another server thread links evidence 4 to K-123-26 with n = 2 between our MAX(n) read and our
        -- transaction. Ours then fails on uq_case_n (rolled back), and the retry takes n = 3.
        local store = mods.store
        local realNext = store.nextN
        local raced = false
        store.nextN = function(caseId)
            local n = realNext(caseId)
            if not raced then
                raced = true
                t.ok(store.link(ids[4], caseId, n, 'B-K-123-26-00' .. n, 0, { actor = 'FOR10002', action = 'link',
                    note = 'K-123-26' }), 'competing link committed')
            end
            return n
        end
        env.clear()
        local res = link(env, 1, ids[3], 'K-123-26')
        store.nextN = realNext
        t.eq(res, { ok = true, tag = 'B-K-123-26-003', caseNumber = 'K-123-26' })
        t.eq(scalar('SELECT tag FROM fredpd_evidence WHERE id = ?', { ids[4] }), 'B-K-123-26-002')
        t.eq(scalar('SELECT n FROM fredpd_evidence WHERE id = ?', { ids[3] }), 3)
        t.eq(env.auditActions(), { 'evidence.link' }, 'one audit row for the retried link')
        t.eq(#mods.store.byId(ids[3]).chain, 3, 'the rolled-back attempt left no link entry')
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_evidence WHERE case_id = 1"), 3)
        -- both attempts fail (the case vanished): unavailable, nothing linked
        local slot5, row5 = collectFingerprint(env, mods, 1, ('%016X'):format(5))
        env.analyse(1, 1, slot5, 'fingerprint')
        store.link = function() return false end
        t.eq(link(env, 1, row5.id, 'K-7-26'), { ok = false, error = 'unavailable' })
    end)
end

tests['10 tablet exports: linkEvidence, getEvidence, listEvidence re-check grant, duty and input'] = function(t)
    withEnv(t, function(_, env, mods)
        local S = mods.service
        local slot, row = collectFingerprint(env, mods, 1)
        env.analyse(1, 1, slot, 'fingerprint')
        t.eq(S.linkEvidence(3, { id = row.id, caseId = 1 }), { ok = false, error = 'unauthorized' })
        t.eq(S.linkEvidence(4, { id = row.id, caseId = 1 }), { ok = false, error = 'unauthorized', reason = 'off_duty' })
        t.eq(S.linkEvidence(1, { id = row.id }), { ok = false, error = 'validation' })
        t.eq(S.linkEvidence(1, { id = row.id, caseId = 99 }), { ok = false, error = 'not_found', reason = 'case' })
        local out = S.linkEvidence(2, { id = row.id, caseId = 1 }) -- the case owner, from the Bevis page
        t.ok(out.ok, tostring(out.error))
        t.eq(out.data.tag, 'B-K-123-26-001')
        t.eq(json.decode(scalar("SELECT meta FROM fredpd_audit WHERE action = 'evidence.link'")).via, 'tablet')
        t.eq(S.get(6, { id = row.id }), { ok = false, error = 'unauthorized' })
        t.eq(S.get(1, { id = 'x' }), { ok = false, error = 'validation' })
        t.eq(S.get(1, { id = 9999 }), { ok = false, error = 'not_found' })
        t.eq(S.list(1, { page = 0 }), { ok = false, error = 'validation' })
        t.eq(S.list(4, {}), { ok = false, error = 'unauthorized', reason = 'off_duty' })
        t.eq(S.list(1, nil).ok, true, 'no input = defaults')
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Visibility

tests['11 visibility: person match only with a full view of the case; masked/notice/unlinked rules'] = function(t)
    withEnv(t, function(_, env, mods)
        local S = mods.service
        -- A: linked to open case 1; B: linked to closed case 2; C: unlinked, analysed; D: collected only
        local rows = {}
        for i, owner in ipairs({ FP1, FP1, FP1, FP2 }) do
            local slot, row = collectFingerprint(env, mods, 1, owner)
            if i <= 3 then env.analyse(1, 1, slot, 'fingerprint') end
            rows[i] = row
        end
        t.eq(link(env, 1, rows[1].id, 'K-123-26').ok, true)
        -- close case 2 after linking (links need an open case)
        MySQL.query.await("UPDATE fredpd_cases SET status = 'open' WHERE id = 2")
        t.eq(link(env, 1, rows[2].id, 'K-124-26').ok, true)
        MySQL.query.await("UPDATE fredpd_cases SET status = 'closed' WHERE id = 2")

        -- Utredare tier 0, unit utredning, not assigned: case 1 open unit -> full; case 2 closed -> masked
        local a = S.get(8, { id = rows[1].id })
        t.eq(a.data.result.match, { citizenid = 'SUS00001', name = 'Sven Svensson' })
        local b = S.get(8, { id = rows[2].id })
        t.ok(b.ok, 'masked is visible')
        t.eq(b.data.result.match, nil, 'masked: no person match')
        t.eq(b.data.result.fingerprint, FP1)
        -- IGV: case 1 = kontaktnotis -> not visible at all; unlinked -> not visible
        t.eq(S.get(3, { id = rows[1].id }), { ok = false, error = 'not_found' })
        t.eq(S.get(3, { id = rows[3].id }), { ok = false, error = 'not_found' })
        -- Spaning with evidence.link: unlinked queue in full (tier 0 >= level 0), case 1 not
        local c = S.get(5, { id = rows[3].id })
        t.eq(c.data.result.match, { citizenid = 'SUS00001', name = 'Sven Svensson' })
        t.eq(S.get(5, { id = rows[1].id }), { ok = false, error = 'not_found' })
        -- Tekniker (unit) sees the unlinked queue; the collector sees what they collected
        t.eq(S.list(1, { unlinked = true }).data.total, 1)
        t.eq(S.list(1, { unlinked = true }).data.items[1].id, rows[3].id)
        t.eq(S.list(3, { unlinked = true }).data, { items = {}, total = 0, page = 1 })
        t.ok(S.get(1, { id = rows[4].id }).ok, 'collector')
        -- records.admin: everything, in full
        local all = S.list(7, {})
        t.eq(all.data.total, 4)
        for _, item in ipairs(all.data.items) do
            if item.result then t.ok(item.result.match, 'admin sees matches') end
        end
        -- per-case list for a masked viewer, and paging
        t.eq(S.list(8, { caseId = 2 }).data.items[1].result.match, nil)
        t.eq(S.list(7, { page = 2 }).data, { items = {}, total = 4, page = 2 })
        -- a Hemlig evidence row above the viewer's tier on an unlinked item: evidence.link does not lift it
        MySQL.query.await('UPDATE fredpd_evidence SET level = 2 WHERE id = ?', { rows[3].id })
        t.eq(S.get(5, { id = rows[3].id }), { ok = false, error = 'not_found' })
    end)
end

tests['12 chain cap: 200 entries kept, collect first, newest last'] = function(t)
    withEnv(t, function(_, env, mods)
        local _, row = collectFingerprint(env, mods, 1)
        for i = 1, 204 do
            mods.store.append(row.id, { actor = 'FOR10001', action = i % 2 == 0 and 'handin' or 'checkout',
                location = LOCKER, note = tostring(i) })
        end
        local after = mods.store.byId(row.id)
        t.eq(#after.chain, 200)
        t.eq(after.chain[1].action, 'collect')
        t.eq(after.chain[200].note, '204')
        t.eq(after.chain[2].note, '6')
    end)
end

tests['13 evidence_box: every evidence item inside gets the hand-in, noted with the box label'] = function(t)
    withEnv(t, function(_, env, mods)
        local s1, r1 = collectFingerprint(env, mods, 1, FP1)
        local s2, r2 = collectFingerprint(env, mods, 1, FP2)
        local box = 'ABC1790000000'
        env.inv[box] = { [1] = deepcopy(env.inv[1][s1]), [2] = deepcopy(env.inv[1][s2]) }
        env.inv[box][1].slot, env.inv[box][2].slot = 1, 2
        env.inv[box][3] = { name = 'water', slot = 3, count = 1, metadata = {} }
        env.inv[1][s1], env.inv[1][s2] = nil, nil
        env.inv[1][10] = { name = 'evidence_box', slot = 10, count = 1, metadata = { container = box, label = 'Låda 7' } }
        t.ok(env.move(1, 1, 10, LOCKER, 3))
        env.advance(100)
        t.eq(env.loadedContainer, box, 'container loaded through GetContainerFromSlot')
        for _, r in ipairs({ r1, r2 }) do
            local after = mods.store.byId(r.id)
            t.eq(chainActions(after), { 'collect', 'handin' })
            t.eq(after.chain[2].note, 'Låda 7')
            t.eq(after.chain[2].location, LOCKER)
        end
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Golden files for the TypeScript contract test

local function keys(tbl)
    local out = {}
    for k in pairs(tbl) do out[#out + 1] = k end
    table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
    return out
end

--- Canonical JSON: sorted keys, empty table = [] (as FiveM msgpack/json sends an empty Lua table), nil = absent.
local function canonical(v, indent)
    indent = indent or ''
    local ty = type(v)
    if ty == 'nil' then return 'null' end
    if ty == 'boolean' then return tostring(v) end
    if ty == 'number' then
        if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return ('%d'):format(v) end
        return ('%.17g'):format(v)
    end
    if ty == 'string' then return json.encode(v) end
    local inner = indent .. '  '
    if next(v) == nil then return '[]' end
    if v[1] ~= nil then
        local parts = {}
        for i = 1, #v do parts[i] = inner .. canonical(v[i], inner) end
        return '[\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. ']'
    end
    local parts = {}
    for _, k in ipairs(keys(v)) do parts[#parts + 1] = inner .. json.encode(k) .. ': ' .. canonical(v[k], inner) end
    return '{\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. '}'
end

local function writeGolden(name, value)
    local text = canonical(value) .. '\n'
    local path = GOLDEN .. name .. '.json'
    local f = io.open(path, 'rb')
    local old = f and f:read('a')
    if f then f:close() end
    if old == text then return false end
    os.execute("mkdir -p '" .. GOLDEN .. "'")
    local out = assert(io.open(path, 'wb'))
    out:write(text)
    out:close()
    print('forensics_server_test: wrote ' .. path)
    return true
end

--- Fixed timestamps for stable files: every ISO string becomes 2026-09-29T10:MM:00Z in order of appearance.
local function stable(v, counter)
    counter = counter or { n = 0 }
    if type(v) == 'string' and v:match(ISO) then
        counter.n = counter.n + 1
        return ('2026-09-29T10:%02d:00Z'):format(counter.n)
    end
    if type(v) ~= 'table' then return v end
    local out = {}
    for _, k in ipairs(keys(v)) do out[k] = stable(v[k], counter) end
    return out
end

tests['14 golden: EvidenceItem (full / masked / unlinked / ballistics), list outputs, offer, push'] = function(t)
    withEnv(t, function(_, env, mods)
        local S = mods.service
        env.positions[1] = LAB_POS
        local slot, row = collectFingerprint(env, mods, 1)
        env.analyse(1, 1, slot, 'fingerprint')
        env.clear()
        t.eq(link(env, 1, row.id, 'K-123-26').ok, true)
        writeGolden('push.case', env.pushes[1].payload)
        t.ok(env.move(1, 1, slot, LOCKER, 1))
        env.advance(100)
        writeGolden('evidence.full', stable(S.get(2, { id = row.id }).data))
        writeGolden('list.case', stable(S.list(2, { caseId = 1 }).data))
        writeGolden('list.empty', S.list(2, { caseId = 3 }).data)

        local slot2, row2 = collectFingerprint(env, mods, 1, FP1) -- same person: the masked file shows the strip
        env.clear()
        env.analyse(1, 1, slot2, 'fingerprint')
        writeGolden('offer', env.clientEvents[1].args[1])
        writeGolden('evidence.unlinked', stable(S.get(1, { id = row2.id }).data))
        MySQL.query.await("UPDATE fredpd_cases SET status = 'open' WHERE id = 2")
        t.eq(link(env, 1, row2.id, 'K-124-26').ok, true)
        MySQL.query.await("UPDATE fredpd_cases SET status = 'closed' WHERE id = 2")
        writeGolden('evidence.masked', stable(S.get(8, { id = row2.id }).data))

        local slot3 = env.collect(3, 'collected_bullet', 'ballistics', 'SER123456', { ballistics = {
            serial = 'SER123456', weaponType = 'Pistol', type = 'bullet' } })
        env.advance(300)
        local uid3 = env.inv[3][slot3].metadata.item_uid
        writeGolden('evidence.collected', stable(S.get(3, { id = mods.store.byUid(uid3).id }).data))
        env.analyse(3, 3, slot3, 'ballistics', { weaponType = 'Pistol' })
        writeGolden('evidence.ballistics', stable(S.get(7, { id = mods.store.byUid(uid3).id }).data))
        t.ok(io.open(GOLDEN .. 'evidence.full.json', 'r'), 'golden files exist')
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Static checks over the module source

local function sourceFiles()
    local files = {}
    local p = io.popen("ls '" .. FORENSICS .. "server/'*.lua '" .. FORENSICS .. "shared/'*.lua '" .. FORENSICS
        .. "client/'*.lua '" .. FORENSICS .. "config.lua'")
    for line in p:lines() do files[#files + 1] = line end
    p:close()
    return files
end

tests['15 SQL uses UTC_TIMESTAMP() only and reads DATETIME columns through isoSelect'] = function(t)
    local files = sourceFiles()
    t.ok(#files >= 6, 'found ' .. #files .. ' files')
    for _, path in ipairs(files) do
        local src = helper.readFile(path)
        t.ok(not src:find('NOW()', 1, true), path .. ': NOW()')
        t.ok(not src:find('CURRENT_TIMESTAMP', 1, true), path .. ': CURRENT_TIMESTAMP')
        t.ok(not src:find('UNIX_TIMESTAMP', 1, true), path .. ': UNIX_TIMESTAMP')
        t.ok(src:find('SPDX-License-Identifier: GPL-3.0-only', 1, true), path .. ': SPDX header')
    end
    local store = helper.readFile(FORENSICS .. 'server/store.lua')
    t.ok(not store:find('e%.collected_at,'), 'collected_at is never selected bare')
    t.ok(store:find("isoSelect('e.collected_at'", 1, true))
end

tests['16 every L() key used by fredpd_forensics exists in sv/en or locales/pending/forensics.json'] = function(t)
    local sv = helper.readJson('locales/sv.json')
    local en = helper.readJson('locales/en.json')
    local pending = helper.readJson('locales/pending/forensics.json')
    local n = 0
    for _, path in ipairs(sourceFiles()) do
        local src = helper.readFile(path)
        for key in src:gmatch("[%.%s%(=,]L%(%s*'([%w_%.]+)'") do
            n = n + 1
            local inMain = sv[key] ~= nil and en[key] ~= nil
            local inPending = type(pending[key]) == 'table' and pending[key].sv and pending[key].en
            t.ok(inMain or inPending, ('%s (used in %s) is missing from locales'):format(key, path))
        end
        for key in src:gmatch("labelKey = '([%w_%.]+)'") do
            t.ok(sv[key] or pending[key], key .. ' (config labelKey) missing')
        end
    end
    t.ok(n >= 20, 'expected at least 20 L() calls, found ' .. n)
    -- audit.action.<action> for every evidence action written
    for _, action in ipairs({ 'collect', 'handin', 'checkout', 'return', 'transfer', 'analyse', 'link', 'mismatch' }) do
        local key = 'audit.action.evidence.' .. action
        t.ok(sv[key] or pending[key], key .. ' missing')
    end
end

---------------------------------------------------------------------------------------------------------------
-- Review fixes: give path, uid registry, lockers, formats, case page export, unlinked person matches

local SUS = { citizenid = 'SUS00001', name = 'Sven Svensson' }

tests['17 give: a handed-over item keeps its uid and record; the recipient gets a transfer entry'] = function(t)
    withEnv(t, function(_, env, mods)
        local slot, row = collectFingerprint(env, mods, 3) -- IGV officer at the scene
        local uid = env.inv[3][slot].metadata.item_uid
        env.clear()
        local okGive, slot1 = env.give(3, slot, 1) -- to the Tekniker
        t.ok(okGive)
        t.eq(env.inv[1][slot1].metadata.item_uid, uid, 'uid kept')
        t.eq(env.inv[1][slot1].metadata.collected_by, 'FOR10003', 'collector kept')
        env.advance(300)
        t.eq(scalar('SELECT COUNT(*) FROM fredpd_evidence'), 1, 'one record')
        local after = mods.store.byId(row.id)
        t.eq(chainActions(after), { 'collect', 'transfer' })
        t.eq({ after.chain[2].actor, after.chain[2].location }, { 'FOR10001', nil })
        t.eq(after.collectedBy, 'FOR10003')
        t.eq(env.auditActions(), { 'evidence.transfer' })
        -- analysis and link reach the same row
        env.analyse(1, 1, slot1, 'fingerprint')
        t.eq(link(env, 1, row.id, 'K-123-26').tag, 'B-K-123-26-001')
        t.eq(chainActions(mods.store.byId(row.id)), { 'collect', 'transfer', 'analyse', 'link' })
        t.eq(scalar('SELECT COUNT(*) FROM fredpd_evidence'), 1)
        -- a give ox_inventory undoes (RemoveItem on the giver failed): no entry
        env.clear()
        t.eq(env.give(1, slot1, 2, true), false)
        env.advance(300)
        t.eq(#mods.store.byId(row.id).chain, 4)
        t.eq(env.auditActions(), {})
        -- re-added where the chain already has it: no entry
        local md = deepcopy(env.inv[1][slot1].metadata)
        env.inv[1][slot1] = nil
        local s2 = env.addItem(1, 'collected_fingerprint', md, 'some_script')
        env.advance(300)
        t.eq(#mods.store.byId(row.id).chain, 4)
        -- moved to player 2 by AddItem running Items.Metadata twice: one entry
        md = deepcopy(env.inv[1][s2].metadata)
        env.inv[1][s2] = nil
        local s3 = env.addItem(2, 'collected_fingerprint', md, 'ox_inventory', 2)
        env.advance(300)
        local chain = mods.store.byId(row.id).chain
        t.eq(#chain, 5)
        t.eq({ chain[5].action, chain[5].actor }, { 'transfer', 'FOR10002' })
        -- 2 hands it in and checks it out, gives it to 1, and 1 puts it back: still a 'return'
        t.ok(env.move(2, 2, s3, LOCKER, 1))
        env.advance(100)
        t.ok(env.move(2, LOCKER, 1, 2, 6))
        env.advance(100)
        local _, s4 = env.give(2, 6, 1)
        env.advance(300)
        t.ok(env.move(1, 1, s4, LOCKER, 2))
        env.advance(100)
        t.eq(chainActions(mods.store.byId(row.id)), { 'collect', 'transfer', 'analyse', 'link', 'transfer', 'handin',
            'checkout', 'transfer', 'return' })
        -- a resource adding it straight to another locker: locker -> locker = transfer, with the locker as location
        md = deepcopy(env.inv[LOCKER][2].metadata)
        env.inv[LOCKER][2] = nil
        env.addItem('evidence-4', 'collected_fingerprint', md, 'some_script')
        env.advance(300)
        chain = mods.store.byId(row.id).chain
        t.eq({ chain[10].action, chain[10].actor, chain[10].location }, { 'transfer', nil, 'evidence-4' })
        t.eq(scalar('SELECT COUNT(*) FROM fredpd_evidence'), 1)
    end)
end

tests['18 uid registry: tampered evidence, a copied uid, another item name, a row from before 011'] = function(t)
    withEnv(t, function(_, env, mods)
        local S = mods.service
        -- R2: collected as FP2, rewritten to FP1 (evidences:syncEvidence atItem) before the analysis
        local slotA, rowA = collectFingerprint(env, mods, 1, FP2)
        t.eq({ rowA.itemName, rowA.ident }, { 'collected_fingerprint', 'fingerprint:' .. FP2 })
        env.inv[1][slotA].metadata.fingerprint.owner = FP1
        env.clear()
        env.analyse(1, 1, slotA, 'fingerprint')
        t.eq(mods.store.byId(rowA.id).result, nil, 'tampered evidence is not analysed into the row')
        t.eq(env.auditActions(), { 'evidence.mismatch' })
        t.eq(env.audits[1].meta.why, 'evidence')
        t.eq(#env.clientEvents, 0, 'no link offer')
        t.ok(env.move(1, 1, slotA, LOCKER, 1)) -- its hand-in is refused too
        env.advance(100)
        t.eq(chainActions(mods.store.byId(rowA.id)), { 'collect' })

        -- R3: item B carries unanalysed item C's uid
        local slotC, rowC = collectFingerprint(env, mods, 1, FP1)
        local slotB = collectFingerprint(env, mods, 1, FP2)
        env.inv[1][slotB].metadata.item_uid = rowC.itemUid
        local forged = deepcopy(env.inv[1][slotB])
        forged.metadata.fingerprint.analysed = true
        t.eq(S.onAnalysed(1, forged, 1), 'mismatch')
        t.eq(mods.store.byId(rowC.id).result, nil, 'row C untouched')
        env.analyse(1, 1, slotC, 'fingerprint')
        t.eq(mods.store.byId(rowC.id).result.fingerprint, FP1, 'the real item C still analyses')
        t.eq(mods.store.byId(rowC.id).result.match, SUS)

        -- same type ('other'), another item name: a gunshot residue item carrying a magazine's uid and evidence
        local slotM = env.collect(1, 'collected_magazine', 'ballistics', 'SER123456', { ballistics = {
            serial = 'SER123456', weaponType = 'Pistol', type = 'magazine' } })
        env.advance(300)
        local md = deepcopy(env.inv[1][slotM].metadata)
        md.ballistics.analysed = true
        env.clear()
        t.eq(S.onAnalysed(1, { name = 'collected_gunshot_residue', slot = 30, count = 1, metadata = md }, 1), 'mismatch')
        t.eq(env.audits[1].meta.why, 'item')

        -- a row from before migration 011 (no item_name / ident) gets both at its first sighting, then keeps them
        MySQL.query.await("INSERT INTO fredpd_evidence (item_uid, type, collected_by, chain) VALUES "
            .. "('EV00000000000000AA', 'fingerprint', 'FOR10003', JSON_ARRAY(JSON_OBJECT('at', '2026-09-20T10:00:00Z', "
            .. "'actor', 'FOR10003', 'action', 'collect')))")
        env.inv[1][40] = { name = 'collected_fingerprint', slot = 40, count = 1, metadata = {
            item_uid = 'EV00000000000000AA', fingerprint = { owner = FP2 } } }
        t.ok(env.move(1, 1, 40, LOCKER, 9))
        env.advance(100)
        local old = mods.store.byUid('EV00000000000000AA')
        t.eq({ old.itemName, old.ident }, { 'collected_fingerprint', 'fingerprint:' .. FP2 })
        t.eq(chainActions(old), { 'collect', 'handin' })
        env.inv[LOCKER][9].metadata.fingerprint.owner = FP1
        t.ok(env.move(1, LOCKER, 9, 1, 41))
        env.advance(100)
        t.eq(chainActions(mods.store.byUid('EV00000000000000AA')), { 'collect', 'handin' },
            'checkout of the tampered item refused')
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_audit WHERE action = 'evidence.mismatch'"), 5)
    end)
end

tests['19 evidence lockers: opening needs the FredPD grant and duty (openInventory hook)'] = function(t)
    withEnv(t, function(_, env, mods)
        local function open(src, inv)
            local okHooks, ids = env.runHooks('openInventory', { source = src, inventoryId = inv, inventoryType = 'stash' })
            return { okHooks, #ids }
        end
        t.eq(open(3, LOCKER), { true, 1 }, 'IGV on duty with mdt_page:evidence')
        t.eq(open(1, 'evidence-3'), { true, 1 }, 'ox_inventory police locker')
        env.clear()
        t.eq(open(4, LOCKER), { false, 1 }, 'off duty')
        t.eq(open(6, LOCKER), { false, 1 }, 'civilian with the police job but no grants')
        t.eq(open(9, 'evidence-3'), { false, 1 }, 'no mdt_page:evidence')
        t.eq(open(nil, LOCKER), { false, 1 }, 'no player')
        t.eq(open(6, 'trunkABC123'), { true, 0 }, 'other inventories: hook not invoked')
        t.eq(#env.clientEvents, 3)
        t.eq(env.clientEvents[1].name, 'ox_lib:notify')
        t.eq(env.clientEvents[1].target, 4)
        t.eq(env.clientEvents[1].args[1], { type = 'error',
            description = 'Bevisförrådet kräver att du är i tjänst och har behörighet till Bevis.' })
        mods.service.cfg.lockerGrant = false
        t.eq(open(6, LOCKER), { true, 1 }, 'lockerGrant = false: groups only')
    end)
end

tests['20 formats.json missing: linking answers unavailable, no link offer'] = function(t)
    withEnv(t, function(_, env)
        env.hooks, env.handlers, env.callbacks, env.exported = {}, {}, {}, {}
        env.noFormats = true
        local mods = loadResource()
        env.useFixedUids(mods)
        t.eq(mods.service.format, nil)
        local logged = false
        for _, l in ipairs(env.logs) do
            if l.level == 'error' and l.msg:find('linking is disabled', 1, true) then logged = true end
        end
        t.ok(logged, 'logged')
        local slot, row = collectFingerprint(env, mods, 1)
        env.clear()
        env.analyse(1, 1, slot, 'fingerprint')
        t.ok(mods.store.byId(row.id).result, 'the analysis is still recorded')
        t.eq(#env.eventsNamed('fredpd:forensics:client:offerLink', env.clientEvents), 0, 'no offer')
        t.eq(link(env, 1, row.id, 'K-123-26'), { ok = false, error = 'unavailable' })
        t.eq(mods.service.linkEvidence(1, { id = row.id, caseId = 1 }), { ok = false, error = 'unavailable' })
        t.eq(mods.service.linkEvidence(6, { id = row.id, caseId = 1 }), { ok = false, error = 'unauthorized' })
        t.eq(mods.service.linkCore({ src = 1, citizenid = 'FOR10001' }, row.id, nil, 'test'),
            { ok = false, error = 'unavailable' })
        t.eq(mods.store.byId(row.id).caseId, nil)
    end)
end

tests['21 case page export listCaseEvidence; unlinked person match only for lab / evidence.link / admin'] = function(t)
    withEnv(t, function(_, env, mods)
        local S = mods.service
        local slot3, row = collectFingerprint(env, mods, 3) -- IGV collects, hands it to the Tekniker
        local _, slot1 = env.give(3, slot3, 1)
        env.advance(300)
        env.analyse(1, 1, slot1, 'fingerprint')
        local byCollector = S.get(3, { id = row.id })
        t.ok(byCollector.ok, 'the collector sees the evidence')
        t.eq(byCollector.data.result.fingerprint, FP1)
        t.eq(byCollector.data.result.match, nil, 'but not the person match')
        writeGolden('evidence.collector', stable(byCollector.data))
        t.eq(S.get(1, { id = row.id }).data.result.match, SUS, 'lab unit + evidence.link')
        t.eq(S.get(7, { id = row.id }).data.result.match, SUS, 'records.admin')
        t.eq(S.get(5, { id = row.id }).data.result.match, SUS, 'evidence.link (Spaning)')
        env.players[1].grants = set({ 'mdt_page:evidence', 'unit:tekniker' })
        t.eq(S.get(1, { id = row.id }).data.result.match, SUS, 'lab unit alone')
        env.players[1].grants = defaultPlayers()[1].grants
        t.eq(link(env, 1, row.id, 'K-123-26').ok, true)

        -- player 9 sees case 1 (open, unit utredning) but has no mdt_page:evidence
        t.eq(S.list(9, { caseId = 1 }), { ok = false, error = 'unauthorized' })
        local page = env.exported.listCaseEvidence(9, { caseId = 1 }) -- the export (gated) answers as S.listCase
        t.eq(page, S.listCase(9, { caseId = 1 }))
        t.ok(page.ok, tostring(page.error))
        t.eq(page.data.total, 1)
        t.eq(page.data.items[1].tag, 'B-K-123-26-001')
        t.eq(page.data.items[1].result.match, SUS)
        t.eq(chainActions(page.data.items[1]), { 'collect', 'transfer', 'analyse', 'link' })
        writeGolden('list.caseExport', stable(page.data))
        t.eq(S.listCase(3, { caseId = 1 }).data, { items = {}, total = 0, page = 1 }, 'case = kontaktnotis: no rows')
        t.eq(S.listCase(6, { caseId = 1 }), { ok = false, error = 'unauthorized', reason = 'off_duty' }, 'civilian')
        t.eq(S.listCase(4, { caseId = 1 }), { ok = false, error = 'unauthorized', reason = 'off_duty' })
        t.eq(S.listCase(9, { caseId = 99 }), { ok = false, error = 'not_found' })
        t.eq(S.listCase(9, {}), { ok = false, error = 'validation' })
        t.eq(S.listCase(9, { caseId = 1, unlinked = true }), { ok = false, error = 'validation' })
    end)
end

---------------------------------------------------------------------------------------------------------------
-- Review 2 fixes: unknown uids, the level of linked evidence, the analyst must hold the item

tests['22 unknown uid: a forged uid + collector is re-stamped without collector; a minted uid registers late'] =
function(t)
    withEnv(t, function(_, env, mods)
        local S = mods.service
        -- X1: IGV officer 3 collects; client metadata (evidences:syncEvidence -> atItem) then carries a fresh uid and
        -- a forged collector / collect time
        local slot, row = collectFingerprint(env, mods, 3)
        local md = env.inv[3][slot].metadata
        md.item_uid, md.collected_by, md.collected_at = 'EV0000000000000BAD', 'FOR10002', '2020-01-01T00:00:00Z'
        env.clear()
        t.ok(env.move(3, 3, slot, LOCKER, 1))
        env.advance(100)
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_evidence WHERE item_uid = 'EV0000000000000BAD'"), 0, 'forged uid')
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_evidence WHERE collected_by = 'FOR10002'"), 0, 'forged collector')
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_evidence WHERE JSON_SEARCH(chain, 'one', 'FOR10002') IS NOT NULL"), 0)
        local stamped = env.inv[LOCKER][1].metadata
        t.ok(mods.evidence.isUid(stamped.item_uid) and stamped.item_uid ~= 'EV0000000000000BAD', 're-stamped')
        t.eq({ stamped.collected_by, stamped.collected_at }, { nil, nil }, 'client collector fields dropped')
        local fresh = mods.store.byUid(stamped.item_uid)
        t.eq(chainActions(fresh), { 'collect', 'handin' })
        t.eq({ fresh.collectedBy, fresh.chain[1].actor }, { nil, nil })
        t.eq(fresh.collectedAt, '2026-09-21T14:13:20Z', "evidences' createdAt, not the forged 2020 time")
        t.eq(fresh.chain[2].actor, 'FOR10003')
        t.eq(S.records(fresh, {}).assignees, {}, 'the forged collector is no handler')
        t.eq(env.auditActions(), { 'evidence.collect', 'evidence.mismatch', 'evidence.handin' })
        t.eq(env.audits[2].meta, { item = 'collected_fingerprint', why = 'unknown_uid', uid = 'EV0000000000000BAD' })
        t.eq(env.audits[2].targetId, fresh.id)
        t.eq(chainActions(mods.store.byId(row.id)), { 'collect' }, 'the real row is untouched')
        -- the same on an item lying in the locker (rewritten remotely): its checkout re-stamps it again
        env.inv[LOCKER][1].metadata.item_uid = 'EV0000000000000BAE'
        env.inv[LOCKER][1].metadata.collected_by = 'FOR10002'
        t.ok(env.move(1, LOCKER, 1, 1, 3))
        env.advance(100)
        local again = mods.store.byUid(env.inv[1][3].metadata.item_uid)
        t.eq(chainActions(again), { 'collect', 'checkout' })
        t.eq(again.collectedBy, nil)
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_evidence WHERE collected_by = 'FOR10002'"), 0)
        -- unknown uid where it cannot be re-stamped (unpatched evidences: no inventory): nothing written, audited
        env.clear()
        local forged = { name = 'collected_fingerprint', slot = 7, count = 1, metadata = {
            item_uid = 'EV0000000000000BAF', collected_by = 'FOR10002', fingerprint = { owner = FP2, analysed = true } } }
        t.eq(S.onAnalysed(1, forged, nil), 'mismatch')
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_evidence WHERE item_uid = 'EV0000000000000BAF'"), 0)
        t.eq(env.auditActions(), { 'evidence.mismatch' })
        t.eq({ env.audits[1].targetId, env.audits[1].meta.why }, { nil, 'unknown_uid' })

        -- a uid this server minted whose registration failed: the row follows at the next sighting, with the
        -- collector from the mint (not from the item)
        local realInsert = mods.store.insert
        mods.store.insert = function() error('db down', 0) end
        local slot2 = env.collect(1, 'collected_fingerprint', 'fingerprint', FP2)
        env.advance(300)
        mods.store.insert = realInsert
        local uid2 = env.inv[1][slot2].metadata.item_uid
        t.eq(mods.store.byUid(uid2), nil, 'registration failed')
        t.ok(S.isMinted(uid2))
        env.inv[1][slot2].metadata.collected_by = 'FOR10002' -- ignored: the mint knows the collector
        env.clear()
        t.ok(env.move(1, 1, slot2, LOCKER, 2))
        env.advance(100)
        local late = mods.store.byUid(uid2)
        t.eq({ late.collectedBy, late.chain[1].actor }, { 'FOR10001', 'FOR10001' })
        t.eq(chainActions(late), { 'collect', 'handin' })
        t.eq(env.auditActions(), { 'evidence.collect', 'evidence.handin' })
        t.eq(env.audits[1].meta.via, 'late')
        t.eq(S.isMinted(uid2), false, 'forgotten once the row exists')
        t.eq(env.inv[LOCKER][2].metadata.item_uid, uid2, 'uid kept')
        -- registered normally: nothing stays in memory
        local slot3 = env.collect(1, 'collected_fingerprint', 'fingerprint', FP1)
        t.ok(S.isMinted(env.inv[1][slot3].metadata.item_uid))
        env.advance(300)
        t.eq(S.isMinted(env.inv[1][slot3].metadata.item_uid), false)
    end)
end

tests['23 linked evidence follows its case: a raised case level hides it, never more visible than the case'] =
function(t)
    withEnv(t, function(_, env, mods)
        local S = mods.service
        local slot, row = collectFingerprint(env, mods, 1)
        env.analyse(1, 1, slot, 'fingerprint')
        t.eq(link(env, 1, row.id, 'K-123-26').ok, true)
        t.eq(S.get(8, { id = row.id }).data.result.match, SUS, 'before: unit utredning sees the open case in full')
        t.eq(S.listCase(9, { caseId = 1 }).data.total, 1)
        -- X3: the case is raised to Hemlig after the link (§C14 allows raising)
        MySQL.query.await('UPDATE fredpd_cases SET level = 2 WHERE id = 1')
        t.eq(scalar('SELECT level FROM fredpd_evidence WHERE id = ?', { row.id }), 0, 'stored level unchanged')
        t.eq(S.get(8, { id = row.id }), { ok = false, error = 'not_found' }, 'tier 0, not assigned: kontaktnotis')
        t.eq(S.list(8, { caseId = 1 }).data, { items = {}, total = 0, page = 1 })
        t.eq(S.listCase(8, { caseId = 1 }).data, { items = {}, total = 0, page = 1 })
        t.eq(S.listCase(9, { caseId = 1 }).data, { items = {}, total = 0, page = 1 })
        local owner = S.get(2, { id = row.id }) -- the case owner (assigned: no tier cap)
        t.eq(owner.data.level, 2, 'output level = the case level')
        t.eq(owner.data.result.match, SUS)
        t.eq(S.listCase(2, { caseId = 1 }).data.items[1].level, 2)
        t.eq(S.get(7, { id = row.id }).data.level, 2, 'records.admin')
        -- a rule that would show every evidence row in full: still capped at the case view (IGV: kontaktnotis)
        env.rules[#env.rules + 1] = { id = 1000, recordType = 'evidence', level = nil, recordStatus = 'any',
            viewerCondition = 'any', result = 'full', priority = 1000, enabled = true }
        MySQL.query.await('UPDATE fredpd_cases SET level = 0 WHERE id = 1')
        t.eq(S.get(3, { id = row.id }), { ok = false, error = 'not_found' })
        t.eq(S.list(3, { caseId = 1 }).data.total, 0)
        t.eq(S.get(8, { id = row.id }).data.result.match, SUS, 'case view full: unchanged')
    end)
end

tests['24 analysis only by the holder (own inventory or a container in it); crime scene from the collect entry'] =
function(t)
    withEnv(t, function(_, env, mods)
        local S = mods.service
        -- X4: player 2 "analyses" an item lying in the locker (evidences' getItem accepts any stash id)
        local slot, row = collectFingerprint(env, mods, 1)
        t.ok(env.move(1, 1, slot, LOCKER, 3))
        env.advance(100)
        env.clear()
        env.analyse(2, LOCKER, 3, 'fingerprint', { crimeScene = 'FORGED', additionalData = 'planted note' })
        local after = mods.store.byId(row.id)
        t.eq(after.result, nil, 'not recorded')
        t.eq(chainActions(after), { 'collect', 'handin' })
        t.eq(env.auditActions(), { 'evidence.mismatch' })
        t.eq(env.audits[1].targetId, row.id)
        t.eq(env.audits[1].meta, { item = 'collected_fingerprint', why = 'not_holder', inventory = LOCKER })
        t.eq(#env.clientEvents, 0, 'no link offer')
        -- another player's inventory
        local slotB, rowB = collectFingerprint(env, mods, 1, FP2)
        local itemB = deepcopy(env.inv[1][slotB])
        itemB.metadata.fingerprint.analysed = true
        t.eq(S.onAnalysed(2, itemB, 1), 'mismatch')
        t.eq(mods.store.byId(rowB.id).result, nil)
        -- a container: only when it is in the analyst's own inventory
        local box = 'BOX1790000000'
        env.inv[box] = { [1] = deepcopy(env.inv[1][slotB]) }
        env.inv[box][1].slot = 1
        env.inv[1][slotB] = nil
        env.inv[1][10] = { name = 'evidence_box', slot = 10, count = 1, metadata = { container = box, label = 'Låda 1' } }
        t.eq(S.heldBy(2, box), false)
        t.eq(S.heldBy(1, box), true)
        t.eq(S.heldBy(1, 'evidence_locker_mrpd'), false)
        t.eq(S.heldBy(1, '1'), false, 'a numeric string is no player inventory')
        env.clear()
        env.analyse(2, box, 1, 'fingerprint')
        t.eq(mods.store.byId(rowB.id).result, nil, 'box held by player 1')
        env.analyse(1, box, 1, 'fingerprint')
        local boxed = mods.store.byId(rowB.id)
        t.eq(boxed.result.fingerprint, FP2)
        t.eq(boxed.chain[#boxed.chain].actor, 'FOR10001')
        t.eq(env.auditActions(), { 'evidence.mismatch', 'evidence.analyse' })
        -- the holder analyses the first item: the result keeps the crime scene registered at collect
        t.ok(env.move(1, LOCKER, 3, 1, 5))
        env.advance(100)
        env.analyse(1, 1, 5, 'fingerprint', { crimeScene = 'FORGED' })
        local analysed = mods.store.byId(row.id)
        t.eq(analysed.result.fingerprint, FP1)
        t.eq(analysed.result.crimeScene, 'Vespucci Blvd', 'not the analysis payload')
        t.eq(chainActions(analysed), { 'collect', 'handin', 'checkout', 'analyse' })
    end)
end

if ... == 'forensics_server_test' then
    return { withEnv = withEnv, loadResource = loadResource, collectFingerprint = collectFingerprint, link = link,
        hookOf = hookOf, set = set, LOCKER = LOCKER, FP1 = FP1, SV = SV }
end

return tests
