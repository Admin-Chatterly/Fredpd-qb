-- SPDX-License-Identifier: GPL-3.0-only
-- housing adapter "ox_doorlock-only" (task 6.2, docs/modules/breach.md "Housing adapter"): for housing scripts
-- whose doors are plain ox_doorlock doors and that offer no API of their own. The property → door mapping comes
-- from adapters/housing/ox_doorlock_only.json (server-side LoadResourceFile, read once on first use):
--
--   { "properties": { "<propertyId>": { "doors": [12, "my_house_front"], "label": "Grove Street 12" } } }
--
-- A door is an ox_doorlock id (number) or door name (string, resolved with exports.ox_doorlock:getDoorFromName,
-- ox_doorlock server/main.lua:80-86). A property id that is not in the file but is a number is taken as an
-- ox_doorlock door id itself (exports.ox_doorlock:getDoor, :53-68). Unlocking uses
-- exports.ox_doorlock:setDoorState(id, 0) (:275-314). No ownership data exists, so getAddresses is always {}.
-- When ox_doorlock is not started every call is the housing no-op (adapters/base.lua; one warning).

local M = {}

M.FILE = 'adapters/housing/ox_doorlock_only.json'
M.MAX_DOORS = 16
M.mapping = nil -- [propertyId string] = { doors = { ... }, label = string|nil }

--- Load the mapping (decoded JSON table; nil = read M.FILE from fredpd_core). Bad entries are dropped.
function M.load(decoded)
    if decoded == nil then
        local raw = LoadResourceFile(GetCurrentResourceName(), M.FILE)
        local ok, data = pcall(json.decode, raw or '')
        decoded = ok and data or nil
    end
    local out = {}
    local props = type(decoded) == 'table' and decoded.properties or nil
    for pid, entry in pairs(type(props) == 'table' and props or {}) do
        local doors = {}
        for _, d in ipairs(type(entry) == 'table' and type(entry.doors) == 'table' and entry.doors or {}) do
            if (type(d) == 'number' and math.tointeger(d)) or (type(d) == 'string' and #d > 0 and #d <= 64) then
                if #doors < M.MAX_DOORS then doors[#doors + 1] = d end
            end
        end
        if #doors > 0 then
            out[tostring(pid)] = { doors = doors, label = type(entry.label) == 'string' and entry.label or nil }
        end
    end
    M.mapping = out
    return out
end

local function mapping()
    return M.mapping or M.load()
end

local function resolve(d)
    local door
    if type(d) == 'string' then
        door = exports.ox_doorlock:getDoorFromName(d)
    else
        door = exports.ox_doorlock:getDoor(d)
    end
    return type(door) == 'table' and math.tointeger(tonumber(door.id)) or nil
end

function M.getDoorForProperty(propertyId)
    if propertyId == nil then return nil end
    local entry = mapping()[tostring(propertyId)]
    local ids = {}
    if entry then
        for _, d in ipairs(entry.doors) do
            local id = resolve(d)
            if id then ids[#ids + 1] = id end
        end
    else
        local n = math.tointeger(tonumber(propertyId))
        local id = n and n > 0 and resolve(n) or nil
        if id then ids[1] = id end
    end
    return #ids > 0 and ids or nil
end

function M.unlock(propertyId, _src)
    local ids = M.getDoorForProperty(propertyId)
    if not ids then return false end
    local any = false
    for _, doorId in ipairs(ids) do
        if exports.ox_doorlock:setDoorState(doorId, 0) == true then any = true end
    end
    return any
end

local adapter = require('adapters.base').define({
    kind = 'housing',
    name = 'ox_doorlock-only',
    resource = 'ox_doorlock',
    methods = {
        getDoorForProperty = M.getDoorForProperty,
        unlock = M.unlock,
    },
})

--- Convenience: the first address label, or nil (always nil here: no ownership data).
function adapter.getAddress(citizenid)
    local list = adapter.getAddresses(citizenid)
    return type(list) == 'table' and list[1] and list[1].label or nil
end

adapter.impl = M
return adapter
