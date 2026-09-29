-- SPDX-License-Identifier: GPL-3.0-only
-- Doorlock bridge: qb-doorlock (docs/contracts.md §C17). Verified against qb-doorlock 4a8e911d (deps.lock.json).
-- Door ids are the keys of its Config.DoorList (numbers for the list entries in config.lua:57ff, strings for
-- `Config.DoorList['name'] = …` in configs/*.lua and doors made in game, server.lua:185-289).
--   server  qb-doorlock has NO server export and NO server-side event for a state change: the state lives in its
--           Config.DoorList, changed only by the net event qb-doorlock:server:updateState (server.lua:140-183), which
--           broadcasts qb-doorlock:client:setState to clients. patches/qb-doorlock.10-fredpd-bridge.patch adds
--             exports['qb-doorlock']:getDoor(id) -> { id, name, locked, coords } | nil
--             exports['qb-doorlock']:setDoorState(id, locked, src?) -> boolean (no authorisation: the caller checks)
--             TriggerEvent('qb-doorlock:server:doorChanged', id, locked, playerId)  (every change, autoLock too)
--           Without the patch getDoor is nil and setLocked false (one warning, server/bridge.lua).
--   client  exports['qb-doorlock']:GetDoorList() -> Config.DoorList (id -> door)   client.lua:930-932 (filled on
--           QBCore:Client:OnPlayerLoaded, client.lua:344-350)
--           net event qb-doorlock:client:setState(serverId, doorID, state, src, sounds, anim)   client.lua:362

local M = { kind = 'doorlock', name = 'qb-doorlock', resource = 'qb-doorlock' }

M.PATCH = 'patches/qb-doorlock.10-fredpd-bridge.patch'

--- Coordinates of a qb-doorlock door: single door objCoords, double door the first door's, else textCoords.
function M.coordsOf(door)
    if type(door) ~= 'table' then return nil end
    if door.objCoords then return door.objCoords end
    if type(door.doors) == 'table' and type(door.doors[1]) == 'table' and door.doors[1].objCoords then
        return door.doors[1].objCoords
    end
    return door.textCoords
end

--- A Config.DoorList entry -> { id, name, locked, coords }.
function M.normalise(id, door)
    if type(door) ~= 'table' or id == nil then return nil end
    return { id = id, name = door.doorLabel, locked = door.locked == true, coords = M.coordsOf(door) }
end

--- True when the error of an export call says the export does not exist (the patch is not applied).
function M.isMissingExport(err)
    return tostring(err):find('No such export', 1, true) ~= nil
end

function M.server()
    local impl = { patched = nil } -- nil = not known yet, then true/false after the first call

    function impl.reset() impl.patched = nil end

    --- Call a patched export; (false, 'unpatched') when the export does not exist.
    local function call(name, ...)
        local args = table.pack(...)
        local ok, a = pcall(function() return exports['qb-doorlock'][name](exports['qb-doorlock'], table.unpack(args, 1, args.n)) end)
        if ok then
            impl.patched = true
            return true, a
        end
        if M.isMissingExport(a) then
            impl.patched = false
            return false, 'unpatched'
        end
        error(a, 0)
    end

    function impl.getDoor(id)
        local ok, door = call('getDoor', id)
        if not ok then return nil, door end
        if type(door) ~= 'table' or door.id == nil then return nil end
        return { id = door.id, name = door.name, locked = door.locked == true, coords = door.coords }
    end

    function impl.setLocked(id, locked, src)
        local ok, result = call('setDoorState', id, locked == true, tonumber(src))
        if not ok then return false, result end
        return result == true
    end

    function impl.bind(h)
        AddEventHandler('qb-doorlock:server:doorChanged', function(doorId, locked)
            h.changed(doorId, locked == true)
        end)
    end

    return impl
end

function M.client()
    local impl = {}

    function impl.listDoors()
        local list = exports['qb-doorlock']:GetDoorList()
        local out = {}
        for id, door in pairs(type(list) == 'table' and list or {}) do
            local d = M.normalise(id, door)
            if d then out[#out + 1] = d end
        end
        table.sort(out, function(a, b) return tostring(a.id) < tostring(b.id) end)
        return out
    end

    function impl.onDoorChanged(cb)
        RegisterNetEvent('qb-doorlock:client:setState', function(_serverId, doorID, state)
            cb(doorID, state == true)
        end)
    end

    return impl
end

return M
