-- SPDX-License-Identifier: GPL-3.0-only
-- Stack selection for the fredpd_bolo / fredpd_dispatch / fredpd_breach Lua tests (docs/contracts.md §C17,
-- docs/modules/bridge.md). Used two ways, like bridge_harness_test.lua:
--  * `require('dispatch_stack_test')` from bolo_*/dispatch_*/breach_* tests returns the helper S;
--  * run.lua's `dofile` returns this file's own small suite (the mocks answer like the upstream sources).
-- The main suites run on ONE stack, chosen by the environment variable FREDPD_STACK:
--   qb (default) = qb-core + qb-inventory + qb-target + qb-doorlock (patched)
--   ox           = qbx_core + ox_inventory + ox_target + ox_doorlock      (FREDPD_STACK=ox or qbx)
-- The *_bridge_test.lua files additionally run a smoke matrix over both stacks in every run.
-- The real fredpd_core server/bridge.lua is loaded over framework / inventory / doorlock mocks shaped like the
-- pinned upstream exports (cited in fredpd_core/bridge/**), so FredPD code is exercised through the bridge exactly as
-- on a server.
local S = {}

S.STACKS = { 'qb', 'ox' }

S.IMPL = {
    qb = { framework = 'qb-core', inventory = 'qb-inventory', target = 'qb-target', doorlock = 'qb-doorlock' },
    ox = { framework = 'qbx_core', inventory = 'ox_inventory', target = 'ox_target', doorlock = 'ox_doorlock' },
}

S.forced = nil -- set by S.on(stack, fn) for the smoke matrices

--- The stack selected for this run: 'qb' unless FREDPD_STACK is ox/qbx (or S.on forces one).
function S.current()
    if S.forced then return S.forced end
    local v = os.getenv('FREDPD_STACK')
    if v == 'ox' or v == 'qbx' then return 'ox' end
    return 'qb'
end

--- Run fn() with S.current() answering `stack` (a smoke matrix re-running main-suite tests on both stacks).
function S.on(stack, fn, ...)
    local saved = S.forced
    S.forced = stack
    local ok, err = pcall(fn, ...)
    S.forced = saved
    if not ok then error(err, 0) end
end

--- PlayerData (the fields FredPD reads; qb-core server/player.lua:66-91, qbx_core server/player.lua:217-231).
--- p = { cid, duty?, job?, name? } from a test's player table.
function S.playerData(src, p)
    return {
        source = src, citizenid = p.cid, license = 'license:' .. p.cid:lower(), name = p.name or ('acct' .. src),
        charinfo = { firstname = 'Test', lastname = 'Person', birthdate = '1990-01-01', gender = 0 },
        job = p.job or { name = 'police', label = 'Polis', type = 'leo', onduty = p.duty == true, isboss = false,
            grade = { name = 'Officer', level = 1 } },
        money = { cash = 0, bank = 0 },
    }
end

--- Framework mock over a live player table (read on every call, so tests may change it): lookup(src) -> p | nil,
--- list() -> srcs. Returns resource name, export table.
function S.framework(stack, lookup, list)
    local function pd(src)
        src = tonumber(src)
        local p = src and lookup(src) or nil
        if type(p) ~= 'table' or type(p.cid) ~= 'string' then return nil end
        return S.playerData(src, p)
    end
    local function byCid(cid)
        for _, src in ipairs(list()) do
            local d = pd(src)
            if d and d.citizenid == cid then return d end
        end
        return nil
    end
    if stack == 'qb' then
        -- qb-core shared/main.lua:7-18 GetCoreObject(filters); server/functions.lua:46-59, 115-121.
        local Functions = {
            GetPlayer = function(src) local d = pd(src); return d and { PlayerData = d, Functions = {} } or nil end,
            GetPlayerByCitizenId = function(cid) local d = byCid(cid); return d and { PlayerData = d } or nil end,
            GetPlayers = function()
                local out = {}
                for _, src in ipairs(list()) do if pd(src) then out[#out + 1] = src end end
                return out
            end,
        }
        return 'qb-core', { GetCoreObject = function() return { Functions = Functions } end }
    end
    -- qbx_core server/functions.lua:86-147.
    return 'qbx_core', {
        GetPlayer = function(_, src) local d = pd(src); return d and { PlayerData = d } or nil end,
        GetPlayerByCitizenId = function(_, cid) local d = byCid(cid); return d and { PlayerData = d } or nil end,
        GetQBPlayers = function()
            local out = {}
            for _, src in ipairs(list()) do
                local d = pd(src)
                if d then out[src] = { PlayerData = d } end
            end
            return out
        end,
    }
end

--- Inventory mock: count(src, item) -> integer. Returns resource name, export table.
function S.inventory(stack, count)
    if stack == 'qb' then
        -- qb-inventory server/functions.lua:357-376 (nil for an unknown player).
        return 'qb-inventory', { GetItemCount = function(_, src, item) return count(src, item) end }
    end
    -- ox_inventory modules/inventory/server.lua:2322-2341.
    return 'ox_inventory', { GetItemCount = function(_, src, item) return count(src, item) or 0 end }
end

--- Doorlock mock over doors = { [id] = { id, name, locked, coords } }; every change is recorded in changes as
--- { id, locked, src }. result() -> what the set call answers (true by default). Returns resource name, exports.
function S.doorlock(stack, doors, changes, result)
    result = result or function() return true end
    local function apply(id, locked, src)
        changes[#changes + 1] = { id = id, locked = locked, src = src }
        local ok = result()
        if ok and doors[id] then doors[id].locked = locked end
        return ok
    end
    if stack == 'qb' then
        -- patches/qb-doorlock.10-fredpd-bridge.patch: getDoor(id) -> { id, name, locked, coords } | nil,
        -- setDoorState(id, locked, src?) -> boolean.
        return 'qb-doorlock', {
            getDoor = function(_, id)
                local d = doors[id]
                return d and { id = d.id, name = d.name, locked = d.locked, coords = d.coords } or nil
            end,
            setDoorState = function(_, id, locked, src) return apply(id, locked == true, src) end,
        }
    end
    -- ox_doorlock server/main.lua:53-68 (false when unknown), :275-314 (state 0|1).
    return 'ox_doorlock', {
        getDoor = function(_, id)
            local d = doors[id]
            if not d then return false end
            return { id = d.id, name = d.name, state = d.locked and 1 or 0, coords = d.coords }
        end,
        setDoorState = function(_, id, state) return apply(id, state == 1, nil) end,
    }
end

local quietLog = function(logs, level)
    return function(fmt, ...)
        local msg = select('#', ...) > 0 and fmt:format(...) or tostring(fmt)
        logs[#logs + 1] = { level = level, msg = msg }
    end
end

--- Load fredpd_core's real server bridge for `stack`. opts = { states = { resource = state } (default: the stack's
--- four resources started), register = true (bind the upstream events with the CURRENT global AddEventHandler; the
--- bridge's own exports go to a sink), cfg = overrides }. Returns Bridge, logs.
function S.load(stack, opts)
    opts = opts or {}
    local impl = S.IMPL[stack]
    local cfg = {}
    for k, v in pairs(impl) do cfg[k] = v end
    for k, v in pairs(opts.cfg or {}) do cfg[k] = v end
    local running = {}
    for _, res in pairs(impl) do running[res] = 'started' end
    local states = opts.states or {}
    local logs = {}
    local Bridge = require('server.bridge')
    local savedConvar = rawget(_G, 'SetConvarReplicated')
    rawset(_G, 'SetConvarReplicated', nil)
    Bridge.load(cfg, {
        stateOf = function(res)
            if states[res] ~= nil then return states[res] end
            return running[res] or 'missing'
        end,
        log = { info = quietLog(logs, 'info'), warn = quietLog(logs, 'warn'), error = quietLog(logs, 'error'),
            debug = quietLog(logs, 'debug') },
        defer = function() end,
    })
    rawset(_G, 'SetConvarReplicated', savedConvar)
    if opts.register then
        local realExports = rawget(_G, 'exports')
        rawset(_G, 'exports', setmetatable({}, {
            __call = function() end,
            __index = function(_, k) return realExports[k] end,
        }))
        local ok, err = pcall(Bridge.register)
        rawset(_G, 'exports', realExports)
        if not ok then error(err, 0) end
    end
    return Bridge, logs
end

--- fredpd_core export table entries that forward to the loaded bridge (merge into a test's fredpd_core mock).
function S.coreExports(Bridge)
    return {
        getPlayer = function(_, src) return Bridge.getPlayer(src) end,
        getPlayers = function() return Bridge.getPlayers() end,
        count = function(_, src, item) return Bridge.count(src, item) end,
        getDoor = function(_, id) return Bridge.getDoor(id) end,
        setLocked = function(_, id, locked, src) return Bridge.setLocked(id, locked, src) end,
        hasFeature = function(_, name) return Bridge.hasFeature(name) end,
        bridgeInfo = function() return Bridge.info() end,
    }
end

--- Leave the bridge with nothing running (the next test file never inherits these mocks).
function S.reset()
    require('bridge_harness_test').reset()
end

--- Lua source without comments (-- to end of line).
function S.code(path)
    local f = assert(io.open(path, 'rb'))
    local src = f:read('a')
    f:close()
    local out = {}
    for line in src:gmatch('[^\n]*') do out[#out + 1] = (line:gsub('%-%-.*$', '')) end
    return table.concat(out, '\n')
end

--- Names FredPD resources must not use outside comments (direct framework / inventory / target / doorlock access).
S.BANNED = { 'ox_inventory', 'ox_target', 'ox_doorlock', 'qbx_core', 'qb%-core', 'qb%-inventory', 'qb%-target',
    'qb%-doorlock', 'QBCore', 'QBX', 'GetCoreObject' }

--- Items of a `key { 'a', 'b' }` block of an fxmanifest.
function S.manifestList(manifest, key)
    local block = manifest:match(key .. '%s*(%b{})')
    local out = {}
    for name in (block or ''):gmatch("'([^']+)'") do out[#out + 1] = name end
    return out
end

---------------------------------------------------------------------------------------------------------------
-- Client: fredpd_core/bridge/client.lua loaded the way '@fredpd_core/bridge/client.lua' is, over target /
-- framework / doorlock client mocks of the stack.

S.CORE = './resources/[fredpd]/fredpd_core/'

--- Globals + recorder for a client test. opts = { job = PlayerData.job | nil (nil = no character), doors =
--- { [id] = { name, locked, coords } }, states = { resource = state } (default: the stack's resources started) }.
--- rec.options(): the options added so far in one normalised view { kind, name?, label, distance, zone?,
--- canInteract(entity), select(entity) } whatever the target resource; rec.fireNet(name, ...) fires every net event
--- handler registered under name; rec.setDuty / setJob / unload / load drive the framework's client events;
--- rec.doorChanged(id, locked) fires the doorlock's own client event; rec.oxDoors() answers 'ox_doorlock:getDoors'.
function S.client(stack, opts)
    opts = opts or {}
    local impl = S.IMPL[stack]
    local rec = { stack = stack, adds = {}, removes = {}, zones = {}, net = {}, printed = {}, states = {},
        job = opts.job, doors = opts.doors or {}, zoneSeq = 0 }
    for _, res in pairs(impl) do rec.states[res] = 'started' end
    for k, v in pairs(opts.states or {}) do rec.states[k] = v end

    local function view(kind, o, zone)
        if stack == 'qb' then
            return { kind = kind, label = o.label, icon = o.icon, distance = o.distance, zone = zone, raw = o,
                canInteract = function(entity)
                    if not o.canInteract then return true end
                    return o.canInteract(entity, 1.0, {})
                end,
                select = function(entity) o.action(entity) end }
        end
        return { kind = kind, name = o.name, label = o.label, icon = o.icon, distance = o.distance, zone = zone,
            raw = o,
            canInteract = function(entity)
                if not o.canInteract then return true end
                return o.canInteract(entity, 1.0, { x = 0, y = 0, z = 0 })
            end,
            select = function(entity) o.onSelect({ entity = entity, coords = { x = 0, y = 0, z = 0 }, distance = 1.0 }) end }
    end

    local target
    if stack == 'qb' then
        -- qb-target registration.lua (AddGlobalVehicle / AddBoxZone(name, center, length, width, zoneOpts, params)).
        target = {
            AddGlobalVehicle = function(_, params)
                for _, o in ipairs(params.options) do rec.adds[#rec.adds + 1] = view('globalVehicle', o) end
            end,
            RemoveGlobalVehicle = function(_, labels) rec.removes[#rec.removes + 1] = { kind = 'globalVehicle', labels = labels } end,
            AddBoxZone = function(_, name, center, length, width, zoneOpts, params)
                rec.zones[name] = { name = name, coords = center, length = length, width = width, opts = zoneOpts,
                    options = {} }
                for _, o in ipairs(params.options) do
                    local v = view('zone', o, name)
                    table.insert(rec.zones[name].options, v)
                    rec.adds[#rec.adds + 1] = v
                end
            end,
            RemoveZone = function(_, name)
                rec.zones[name] = nil
                rec.removes[#rec.removes + 1] = { kind = 'zone', name = name }
            end,
        }
    else
        -- ox_target client/api.lua.
        target = {
            addGlobalVehicle = function(_, options)
                for _, o in ipairs(options) do rec.adds[#rec.adds + 1] = view('globalVehicle', o) end
            end,
            removeGlobalVehicle = function(_, names) rec.removes[#rec.removes + 1] = { kind = 'globalVehicle', labels = names } end,
            addBoxZone = function(_, data)
                rec.zoneSeq = rec.zoneSeq + 1
                rec.zones[data.name] = { name = data.name, id = rec.zoneSeq, coords = data.coords, size = data.size,
                    options = {} }
                for _, o in ipairs(data.options) do
                    local v = view('zone', o, data.name)
                    table.insert(rec.zones[data.name].options, v)
                    rec.adds[#rec.adds + 1] = v
                end
                return rec.zoneSeq
            end,
            removeZone = function(_, id)
                for name, z in pairs(rec.zones) do
                    if z.id == id then
                        rec.zones[name] = nil
                        rec.removes[#rec.removes + 1] = { kind = 'zone', name = name }
                    end
                end
            end,
        }
    end

    local framework = {
        GetPlayerData = function()
            if not rec.job then return {} end
            return { citizenid = 'CLI00001', job = rec.job }
        end,
    }

    local doorlock = nil
    if stack == 'qb' then
        -- qb-doorlock client.lua:930-932 GetDoorList -> Config.DoorList (id -> door).
        doorlock = { GetDoorList = function()
            local out = {}
            for id, d in pairs(rec.doors) do
                out[id] = { doorLabel = d.name, locked = d.locked, objCoords = d.coords }
            end
            return out
        end }
    end

    --- ox_doorlock server/main.lua:316-320 (callback 'ox_doorlock:getDoors'): doors with state 0|1.
    function rec.oxDoors()
        local out = {}
        for id, d in pairs(rec.doors) do out[#out + 1] = { id = id, name = d.name, state = d.locked and 1 or 0, coords = d.coords } end
        return out
    end

    function rec.fireNet(name, ...)
        for _, fn in ipairs(rec.net[name] or {}) do fn(...) end
    end
    -- qb-core / qbx_core client events (bridge/client.lua listens to both frameworks' shared names).
    function rec.setDuty(onduty)
        if rec.job then rec.job.onduty = onduty end
        rec.fireNet('QBCore:Client:SetDuty', onduty)
    end
    function rec.setJob(job) rec.job = job; rec.fireNet('QBCore:Client:OnJobUpdate', job) end
    function rec.unload() rec.job = nil; rec.fireNet('QBCore:Client:OnPlayerUnload') end
    function rec.load(job) rec.job = job; rec.fireNet('QBCore:Client:OnPlayerLoaded') end
    function rec.doorChanged(id, locked)
        if rec.doors[id] then rec.doors[id].locked = locked end
        if stack == 'qb' then
            rec.fireNet('qb-doorlock:client:setState', 0, id, locked, false, true, true) -- client.lua:362
        else
            rec.fireNet('ox_doorlock:setState', id, locked and 1 or 0, nil, nil) -- client/main.lua:117
        end
    end

    local resources = { [impl.target] = target, [impl.framework] = framework }
    if doorlock then resources[impl.doorlock] = doorlock end
    rec.resources = resources

    rec.globals = {
        LoadResourceFile = function(res, path)
            if res ~= 'fredpd_core' then return nil end
            local f = io.open(S.CORE .. path, 'rb')
            if not f then return nil end
            local s = f:read('a')
            f:close()
            return s
        end,
        GetConvar = function(name, default)
            local kind = name:match('^fredpd_bridge_(%a+)$')
            return kind and impl[kind] or default
        end,
        GetResourceState = function(res) return rec.states[res] or 'missing' end,
        RegisterNetEvent = function(name, fn)
            rec.net[name] = rec.net[name] or {}
            table.insert(rec.net[name], fn)
        end,
        GetEntityCoords = function() return { x = 0, y = 0, z = 0 } end,
        print = function(msg) rec.printed[#rec.printed + 1] = tostring(msg) end,
        FredBridge = false,
    }
    return rec
end

--- dofile fredpd_core/bridge/client.lua with rec.globals installed (the caller installs its own globals first,
--- including `exports` resolving rec.resources). Returns FredBridge.
function S.loadClientBridge(rec)
    for k, v in pairs(rec.globals) do rawset(_G, k, v) end
    rawset(_G, 'FredBridge', nil)
    return dofile(S.CORE .. 'bridge/client.lua')
end

S.CLIENT_GLOBALS = { 'LoadResourceFile', 'GetConvar', 'GetResourceState', 'RegisterNetEvent', 'GetEntityCoords',
    'print', 'FredBridge' }

if ... == 'dispatch_stack_test' then return S end

-- Own suite: the mocks answer like the upstream sources, through the real bridge, on both stacks.
local tests = {}

for _, stack in ipairs(S.STACKS) do
    tests[stack .. ': framework, inventory and doorlock mocks through the real bridge'] = function(t)
        local players = { [1] = { cid = 'STK00001', duty = true }, [2] = { cid = 'STK00002' } }
        local doors, changes = { [7] = { id = 7, name = 'cells', locked = true, coords = { x = 1, y = 2, z = 3 } } }, {}
        local ex = {}
        local fwName, fw = S.framework(stack, function(src) return players[src] end, function() return { 1, 2, 9 } end)
        local invName, inv = S.inventory(stack, function(src, item) return src == 1 and item == 'pd_ram' and 2 or 0 end)
        local doorName, door = S.doorlock(stack, doors, changes)
        ex[fwName], ex[invName], ex[doorName] = fw, inv, door
        local saved = rawget(_G, 'exports')
        rawset(_G, 'exports', setmetatable(ex, { __index = function(_, k)
            return setmetatable({}, { __index = function() error('No such export in ' .. k, 2) end })
        end }))
        local ok, err = pcall(function()
            local Bridge = S.load(stack)
            t.eq(Bridge.info().framework, S.IMPL[stack].framework)
            t.eq(Bridge.getPlayer(1).citizenid, 'STK00001')
            t.eq(Bridge.getPlayer(1).job.onduty, true)
            t.eq(Bridge.getPlayers(), { 1, 2 })
            t.eq(Bridge.count(1, 'pd_ram'), 2)
            t.eq(Bridge.count(2, 'pd_ram'), 0)
            t.eq(Bridge.getDoor(7).locked, true)
            t.eq(Bridge.getDoor(8), nil)
            t.eq(Bridge.setLocked(7, false, 1), true)
            t.eq(doors[7].locked, false)
            t.eq(changes[1].id, 7)
        end)
        rawset(_G, 'exports', saved)
        S.reset()
        if not ok then error(err, 0) end
    end
end

return tests
