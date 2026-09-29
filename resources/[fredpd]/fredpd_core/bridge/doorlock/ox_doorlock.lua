-- SPDX-License-Identifier: GPL-3.0-only
-- Doorlock bridge: ox_doorlock (docs/contracts.md §C17; the calls FredPD made directly before the bridge). Verified
-- against ox_doorlock 7d72ff77 (v1.22.1, deps.lock.json):
--   server  exports.ox_doorlock:getDoor(id) -> { id, name, state (0|1), coords, ... } | false   server/main.lua:53-68
--           exports.ox_doorlock:setDoorState(id, 0|1) -> boolean   server/main.lua:275-314 (an export call has no
--           `source`, so ox_doorlock does not check authorisation: FredPD's caller must have done it)
--           event ox_doorlock:stateChanged(source|nil, doorId, locked, usedItem)   server/main.lua:293, 298
--   client  lib.callback 'ox_doorlock:getDoors' -> doors (id -> door), sounds   server/main.lua:316-320 (client/main.lua:37)
--           net event ox_doorlock:setState(id, state, source, data)            client/main.lua:117

local M = { kind = 'doorlock', name = 'ox_doorlock', resource = 'ox_doorlock' }

local function normalise(door)
    if type(door) ~= 'table' or door.id == nil then return nil end
    return { id = door.id, name = door.name, locked = door.state == 1, coords = door.coords }
end
M.normalise = normalise

function M.server()
    local impl = {}

    function impl.reset() end

    function impl.getDoor(id)
        return normalise(exports.ox_doorlock:getDoor(id))
    end

    function impl.setLocked(id, locked, _src)
        return exports.ox_doorlock:setDoorState(id, locked and 1 or 0) == true
    end

    --- h = { changed(id, locked) }
    function impl.bind(h)
        AddEventHandler('ox_doorlock:stateChanged', function(_source, doorId, locked)
            h.changed(doorId, locked == true)
        end)
    end

    return impl
end

function M.client()
    local impl = {}

    --- Array of { id, name, locked, coords }. Awaits a server callback: call it from a thread.
    function impl.listDoors()
        local doors = lib.callback.await('ox_doorlock:getDoors', false)
        local out = {}
        for _, door in pairs(type(doors) == 'table' and doors or {}) do
            local d = normalise(door)
            if d then out[#out + 1] = d end
        end
        table.sort(out, function(a, b) return tostring(a.id) < tostring(b.id) end)
        return out
    end

    --- cb(id, locked) on every door change ox_doorlock broadcasts.
    function impl.onDoorChanged(cb)
        RegisterNetEvent('ox_doorlock:setState', function(id, state)
            cb(id, state == 1)
        end)
    end

    return impl
end

return M
