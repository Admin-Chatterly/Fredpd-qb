-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_core client: exports over the client bridge (bridge/client.lua, loaded before this file by the fxmanifest)
-- for resources that prefer an export to including '@fredpd_core/bridge/client.lua'. Target options are NOT exported
-- here: their callbacks would cross a resource boundary on every aim; include the shared file for targets instead.
--   exports.fredpd_core:clientBridgeInfo() -> { target, doorlock }
--   exports.fredpd_core:listDoors(cb)       cb({ { id, name, locked, coords }, ... }) from a thread of fredpd_core
--                                            (the ox_doorlock list is a server callback; an export must not yield)

exports('clientBridgeInfo', function()
    return { target = FredBridge.target.impl, doorlock = FredBridge.doorlock.impl }
end)

exports('listDoors', function(cb)
    if type(cb) ~= 'function' and type(cb) ~= 'table' then return false end
    CreateThread(function()
        local ok, doors = pcall(FredBridge.doorlock.listDoors)
        cb(ok and doors or {})
    end)
    return true
end)
