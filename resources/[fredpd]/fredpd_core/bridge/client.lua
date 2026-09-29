-- SPDX-License-Identifier: GPL-3.0-only
-- FredPD framework bridge, client side (docs/contracts.md §C17, docs/modules/bridge.md). Other resources load it with
--   client_scripts { '@fredpd_core/bridge/client.lua', ... }
-- and use the global FredBridge:
--   FredBridge.target.addGlobalVehicle(opts) / addModel(models, opts) / addBoxZone(name, box, opts) /
--     addEntity(netIds, opts) -> handle | nil;  FredBridge.target.remove(handle)
--     opts: one option or a list of { name, label, icon?, distance?, canInteract?(entity, distance, coords),
--     onSelect({ entity, coords, distance }) };  box = { coords = vec3, size = vec3, rotation?, debug? }
--   FredBridge.doorlock.listDoors() -> { { id, name, locked, coords }, ... } (awaits on ox_doorlock: call in a thread)
--   FredBridge.doorlock.onDoorChanged(cb(id, locked))
--   FredBridge.target.impl / .resource / .available(), same for doorlock.
-- It runs inside the calling resource, so target callbacks stay local to it (no export round trip per frame). The
-- implementation is the one fredpd_core's server chose (replicated convars fredpd_bridge_target / _doorlock, set by
-- server/bridge.lua); without them 'auto' (first started, ox first). The implementation files are read from
-- fredpd_core with LoadResourceFile (listed under `files` in its fxmanifest).

local RESOURCE = 'fredpd_core'
local CONVARS = { target = 'fredpd_bridge_target', doorlock = 'fredpd_bridge_doorlock' }

local function loadModule(path)
    local src = LoadResourceFile(RESOURCE, path)
    if type(src) ~= 'string' or src == '' then error(('fredpd bridge: %s/%s is missing'):format(RESOURCE, path), 0) end
    local chunk, err = load(src, ('@@%s/%s'):format(RESOURCE, path), 't')
    if not chunk then error(err, 0) end
    return chunk()
end

local Select = loadModule('bridge/select.lua')
local Options = loadModule('bridge/target/options.lua')

local warned = {}
local function warnOnce(key, fmt, ...)
    if warned[key] then return end
    warned[key] = true
    print(('^3[fredpd bridge] ' .. fmt .. '^0'):format(...))
end

local function stateOf(resource) return GetResourceState(resource) end

local function pick(kind)
    local configured = type(GetConvar) == 'function' and GetConvar(CONVARS[kind], 'auto') or 'auto'
    return Select.resolve(kind, configured, stateOf)
end

--- The facade of a client kind: implementation chosen and loaded, plus a guarded caller (resource down -> nil with
--- one warning; error -> nil, logged).
local function build(kind)
    local name = pick(kind)
    local mod = loadModule(Select.file(kind, name))
    local obj = mod.client({ options = Options })
    local facade = { impl = name, resource = mod.resource }

    function facade.available() return stateOf(mod.resource) == 'started' end

    local function call(method, ...)
        local st = stateOf(mod.resource)
        if st ~= 'started' then
            warnOnce(kind .. ':' .. st, '%s bridge "%s": resource %s is %s; %s ignored', kind, name, mod.resource, st, method)
            return nil
        end
        local ok, res = pcall(obj[method], ...)
        if not ok then
            print(('^1[fredpd bridge] %s.%s failed: %s^0'):format(name, method, tostring(res)))
            return nil
        end
        return res
    end
    return facade, call, obj
end

FredBridge = FredBridge or {}

do
    local target, call = build('target')

    --- Add through the implementation; the handle remembers which implementation made it.
    local function add(method, ...)
        local handle = call(method, ...)
        if type(handle) == 'table' then handle.impl = target.impl end
        return handle
    end

    function target.addGlobalVehicle(opts)
        return add('addGlobalVehicle', Options.list(opts, nil))
    end

    function target.addModel(models, opts)
        if type(models) ~= 'table' then models = { models } end
        return add('addModel', models, Options.list(opts, nil))
    end

    function target.addBoxZone(name, box, opts)
        if type(name) ~= 'string' or type(box) ~= 'table' or not box.coords or not box.size then
            error('addBoxZone(name, { coords, size, rotation? }, opts)', 2)
        end
        return add('addBoxZone', name, box, Options.list(opts, nil))
    end

    function target.addEntity(netIds, opts)
        if type(netIds) ~= 'table' then netIds = { netIds } end
        return add('addEntity', netIds, Options.list(opts, nil))
    end

    function target.remove(handle)
        if type(handle) ~= 'table' or handle.impl ~= target.impl then return false end
        return call('remove', handle) == true
    end

    FredBridge.target = target
end

do
    local doorlock, call, obj = build('doorlock')

    --- { { id, name, locked, coords }, ... }; {} while the doorlock resource is down.
    function doorlock.listDoors()
        return call('listDoors') or {}
    end

    --- Registers the upstream client event even while the resource is down (it may start later).
    function doorlock.onDoorChanged(cb)
        if type(cb) ~= 'function' then error('onDoorChanged(cb)', 2) end
        obj.onDoorChanged(cb)
    end

    FredBridge.doorlock = doorlock
end

return FredBridge
