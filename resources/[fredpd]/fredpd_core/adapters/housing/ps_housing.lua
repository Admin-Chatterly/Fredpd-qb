-- SPDX-License-Identifier: GPL-3.0-only
-- housing adapter "ps-housing": Project Sloth ps-housing (task 6.2, docs/modules/breach.md "Housing adapter").
-- Verified against Project-Sloth/ps-housing@eaba693 (not pinned; CC BY-NC-SA 4.0, so only its exports and its DB
-- table are used, never its code):
--   * exports['ps-housing']:getMainDoor(propertyId, doorIndex, isShell) (server/server.lua:174-188): for an MLO
--     property the ox_doorlock door named ps_mloproperty<propertyId>_<doorIndex> (exports.ox_doorlock:
--     getDoorFromName, a getDoor-shaped table with `id`), or nil; doorIndex runs 1..door_data.count
--     (server/sv_property.lua:677-683). Shell properties have no ox_doorlock door (their entrance is a ps-housing
--     zone), so they have no door ids here and cannot be unlocked from another resource.
--   * the `properties` table (README - INSTALL INSTRUCTIONS/QBOX/properties.sql): property_id, owner_citizenid,
--     street, apartment, shell. ps-housing labels a property "<street or apartment> <property_id>"
--     (server/sv_property.lua:648), and so does getAddresses.
-- Unlocking uses exports.ox_doorlock:setDoorState(id, 0) (ox_doorlock server/main.lua:275-314, verified API).
-- When ps-housing is not started every call is the housing no-op (adapters/base.lua; one warning).

local M = {}

M.MAX_DOORS = 8          -- an MLO property's doors are probed 1..MAX_DOORS until the first missing one
M.MAX_ADDRESSES = 10
M.CITIZENID = '^[%w]+$'

--- ox_doorlock door ids of an MLO property, or nil (shell property, unknown id).
function M.getDoorForProperty(propertyId)
    local id = math.tointeger(tonumber(propertyId))
    if not id or id < 1 then return nil end
    local ids = {}
    for i = 1, M.MAX_DOORS do
        local door = exports['ps-housing']:getMainDoor(id, i, false)
        if type(door) ~= 'table' or math.tointeger(tonumber(door.id)) == nil then break end
        ids[#ids + 1] = math.tointeger(tonumber(door.id))
    end
    return #ids > 0 and ids or nil
end

--- Unlock every ox_doorlock door of the property. The caller (fredpd_breach) has done the grant/duty checks.
function M.unlock(propertyId, _src)
    local ids = M.getDoorForProperty(propertyId)
    if not ids then return false end
    local any = false
    for _, doorId in ipairs(ids) do
        if exports.ox_doorlock:setDoorState(doorId, 0) == true then any = true end
    end
    return any
end

--- { { propertyId, label }, ... } of the properties a citizen owns (fredpd_records person page).
function M.getAddresses(citizenid)
    if type(citizenid) ~= 'string' or #citizenid > 50 or not citizenid:match(M.CITIZENID) then return {} end
    local rows = MySQL.query.await(
        'SELECT property_id, street, apartment FROM properties WHERE owner_citizenid = ? ORDER BY property_id LIMIT '
            .. M.MAX_ADDRESSES, { citizenid }) or {}
    local out = {}
    for _, r in ipairs(rows) do
        local place = r.street or r.apartment
        local pid = tostring(r.property_id)
        out[#out + 1] = { propertyId = pid, label = place and (('%s %s'):format(place, pid)) or pid }
    end
    return out
end

local adapter = require('adapters.base').define({
    kind = 'housing',
    name = 'ps-housing',
    resource = 'ps-housing',
    methods = {
        getDoorForProperty = M.getDoorForProperty,
        unlock = M.unlock,
        getAddresses = M.getAddresses,
    },
})

--- Convenience for callers that want one line of text: the first address label, or nil.
function adapter.getAddress(citizenid)
    local list = adapter.getAddresses(citizenid)
    return type(list) == 'table' and list[1] and list[1].label or nil
end

adapter.impl = M
return adapter
