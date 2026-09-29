-- SPDX-License-Identifier: GPL-3.0-only
-- garage adapter "qb-garages": qbcore-framework/qb-garages@f22a09f (GPL-3.0; docs/modules/adapters-qb.md).
-- qb-garages fires no server event on park or take-out, so patches/qb-garages.10-fredpd-events.patch adds two
-- server-only events at its server-authoritative points:
--   fredpd:garage:parked(citizenid, plate, garage|nil, src)    qb-garages server.lua canDeposit callback (:160-177),
--       after its ownership check, when state 1 is written; garage only when it is a configured Config.Garages key
--   fredpd:garage:takenOut(citizenid, plate, garage|nil, src)  qb-garages server.lua spawnvehicle callback
--       (:125-149), after the owned-vehicle lookup and the server-side CreateVehicleServerSetter; garage = the
--       player_vehicles.garage column (the client does not name it there)
-- They are TriggerEvent (server-local) and handled with AddEventHandler, never RegisterNetEvent, so no client can
-- fire them; a player source is ignored as a second guard. The actor comes from the framework bridge
-- (getPlayerByCitizenId), never from the event alone.
-- Each event goes to (1) the callbacks registered with onParked/onTakenOut, cb(plate, src, garageName), and (2)
-- fredpd_bolo: an active efterlysning for the plate (exports.fredpd_bolo:checkPlate, memory only, never waits) fires
-- TriggerEvent('fredpd:boloHit', bolo, { source = 'garage', plate, coords, garage, action }); fredpd_bolo raises the
-- larm with its 60 s per-plate cooldown (docs/modules/bolo.md). Every foreign call is pcall'd.
-- When qb-garages is not started the loader logs one warning and onParked/onTakenOut stay no-ops.

local M = {}

M.RESOURCE = 'qb-garages'
M.BOLO = 'fredpd_bolo'
M.EVENTS = { parked = 'fredpd:garage:parked', takenOut = 'fredpd:garage:takenOut' }
M.PLATE_MAX = 16
M.GARAGE_MAX = 64
M.MAX_LISTENERS = 16

local listeners = { parked = {}, takenOut = {} }
local installed = false
local log = nil

--- Logger (fredpd_core's Core, or the one the loader passed to init).
local function logger()
    if log then return log end
    local ok, Core = pcall(require, 'server.core')
    log = ok and Core or { warn = print, error = print, debug = function() end }
    return log
end

--- Framework bridge (server/bridge.lua); tests replace M.bridge.
function M.getBridge()
    if M.bridge then return M.bridge end
    local ok, Bridge = pcall(require, 'server.bridge')
    return ok and Bridge or nil
end

--- A function, or a msgpack function reference (a table with __call) from another resource.
local function callable(fn)
    if type(fn) == 'function' then return true end
    local mt = type(fn) == 'table' and getmetatable(fn) or nil
    return type(mt) == 'table' and mt.__call ~= nil
end

--- Plate as fredpd_bolo stores it: whitespace removed, upper case, [A-Z0-9-], at most 16; nil otherwise.
function M.normalizePlate(plate)
    if type(plate) ~= 'string' then return nil end
    local p = plate:gsub('%s', ''):upper()
    if p == '' or #p > M.PLATE_MAX or p:find('[^A-Z0-9%-]') then return nil end
    return p
end

--- Garage key from qb-garages' Config.Garages (display only): printable, at most 64 characters; nil otherwise.
function M.cleanGarage(garage)
    if type(garage) ~= 'string' or garage == '' or #garage > M.GARAGE_MAX or garage:find('[%c]') then return nil end
    return garage
end

--- The acting player: the source qb-garages passed when it belongs to that citizenid, else the bridge's lookup.
function M.resolveSource(citizenid, src)
    local bridge = M.getBridge()
    if not bridge or type(citizenid) ~= 'string' or citizenid == '' then return nil end
    src = math.tointeger(tonumber(src))
    if src and src > 0 then
        local okP, player = pcall(bridge.getPlayer, src)
        if okP and type(player) == 'table' and player.citizenid == citizenid then return src end
    end
    local okC, bySrc = pcall(bridge.getPlayerByCitizenId, citizenid)
    bySrc = okC and math.tointeger(tonumber(bySrc)) or nil
    if bySrc and bySrc > 0 then return bySrc end
    return nil
end

--- Server-side coordinates of the player (the garage lot for a park or a take-out), or nil.
local function coordsOf(src)
    if not src or type(GetPlayerPed) ~= 'function' or type(GetEntityCoords) ~= 'function' then return nil end
    local ok, c = pcall(function()
        local ped = GetPlayerPed(src)
        if not ped or ped == 0 then return nil end
        return GetEntityCoords(ped)
    end)
    if not ok or not c then return nil end
    return { x = c.x, y = c.y, z = c.z }
end

--- fredpd_bolo relay: fire fredpd:boloHit for an active efterlysning. true when a hit was fired.
function M.relayBolo(action, plate, src, garage)
    if GetResourceState(M.BOLO) ~= 'started' then return false end
    local ok, bolo = pcall(function() return exports[M.BOLO]:checkPlate(plate) end)
    if not ok then
        logger().warn('garage adapter "qb-garages": fredpd_bolo checkPlate failed: %s', tostring(bolo))
        return false
    end
    if type(bolo) ~= 'table' then return false end
    TriggerEvent('fredpd:boloHit', bolo, {
        source = 'garage', plate = plate, coords = coordsOf(src), garage = garage, action = action,
    })
    return true
end

--- Handle one fredpd:garage:* event (kind 'parked' | 'takenOut'). Called with the event's `source`.
function M.handle(kind, eventSource, citizenid, plate, garage, src)
    local n = tonumber(eventSource)
    if n and n > 0 then return false end -- only qb-garages' server code (TriggerEvent) may fire these
    local normalized = M.normalizePlate(plate)
    if not normalized then return false end
    local actor = M.resolveSource(citizenid, src)
    local garageName = M.cleanGarage(garage)
    for _, cb in ipairs(listeners[kind]) do
        local okCb, err = pcall(cb, normalized, actor, garageName)
        if not okCb then
            logger().error('garage adapter "qb-garages": %s listener failed: %s', kind, tostring(err))
        end
    end
    M.relayBolo(kind, normalized, actor, garageName)
    return true
end

--- Register the two event handlers once (when the adapter is selected; never at require time).
function M.install()
    if installed or type(AddEventHandler) ~= 'function' then return installed end
    installed = true
    AddEventHandler(M.EVENTS.parked, function(citizenid, plate, garage, src)
        M.handle('parked', source, citizenid, plate, garage, src)
    end)
    AddEventHandler(M.EVENTS.takenOut, function(citizenid, plate, garage, src)
        M.handle('takenOut', source, citizenid, plate, garage, src)
    end)
    return true
end

local function subscribe(kind, cb)
    if not callable(cb) then return false end
    local list = listeners[kind]
    for _, existing in ipairs(list) do if existing == cb then return true end end
    if #list >= M.MAX_LISTENERS then
        logger().warn('garage adapter "qb-garages": more than %d %s listeners; ignored', M.MAX_LISTENERS, kind)
        return false
    end
    list[#list + 1] = cb
    M.install()
    return true
end

function M.onParked(cb) return subscribe('parked', cb) end
function M.onTakenOut(cb) return subscribe('takenOut', cb) end

--- Tests: forget listeners and the install flag.
function M.reset()
    listeners = { parked = {}, takenOut = {} }
    installed = false
    log = nil
end

local adapter = require('adapters.base').define({
    kind = 'garage',
    name = 'qb-garages',
    resource = M.RESOURCE,
    methods = {
        onParked = M.onParked,
        onTakenOut = M.onTakenOut,
    },
})

-- Selected by the loader: install the event handlers so the fredpd_bolo relay works without any subscriber.
local baseInit = adapter.init
function adapter.init(logArg, defer)
    baseInit(logArg, defer)
    log = logArg or log
    M.install()
end

adapter.impl = M
return adapter
