-- SPDX-License-Identifier: GPL-3.0-only
-- Target bridge (client): ox_target (docs/contracts.md §C17; the calls FredPD made directly before the bridge).
-- Verified against ox_target abe153aa (v1.18.1, deps.lock.json), client/api.lua (every api.* is exported, :6-11):
--   addGlobalVehicle(options) / removeGlobalVehicle(names)        :195-205 (options keyed by resource + name, :115-176)
--   addModel(models, options) / removeModel(models, names)        :235-272
--   addBoxZone({ name, coords, size, rotation, debug, options }) -> id / removeZone(id)   :54-61, :88-113
--   addEntity(netIds, options) / removeEntity(netIds, names)      :278-318 (network ids)
-- Option shape: { name, label, icon, distance, canInteract(entity, distance, coords, name, bone) (client/main.lua:120-121),
--   onSelect(response) with response.entity/coords/distance (client/main.lua:378-400, 437-438) }.

local M = { kind = 'target', name = 'ox_target', resource = 'ox_target' }

--- ctx = { options = bridge/target/options.lua }
function M.client(ctx)
    local Options = ctx.options
    local impl = {}
    local ox = function() return exports.ox_target end

    local function convert(list)
        local out = {}
        for i, o in ipairs(list) do
            local can, select = o.canInteract, o.onSelect
            out[i] = {
                name = o.name,
                label = o.label,
                icon = o.icon,
                distance = o.distance,
                canInteract = can and function(entity, distance, coords)
                    return can(entity, distance, coords) and true or false
                end or nil,
                onSelect = select and function(data)
                    data = type(data) == 'table' and data or {}
                    select(Options.selection(data.entity, data.coords, data.distance))
                end or nil,
            }
        end
        return out
    end
    impl.convert = convert

    function impl.addGlobalVehicle(list)
        ox():addGlobalVehicle(convert(list))
        return { kind = 'globalVehicle', names = (Options.keys(list)) }
    end

    function impl.addModel(models, list)
        ox():addModel(models, convert(list))
        return { kind = 'model', models = models, names = (Options.keys(list)) }
    end

    --- box = { coords = vec3, size = vec3, rotation = number?, debug = boolean? }
    function impl.addBoxZone(name, box, list)
        local id = ox():addBoxZone({
            name = name, coords = box.coords, size = box.size, rotation = box.rotation or 0.0,
            debug = box.debug == true, options = convert(list),
        })
        return { kind = 'zone', id = id, name = name }
    end

    function impl.addEntity(netIds, list)
        ox():addEntity(netIds, convert(list))
        return { kind = 'entity', netIds = netIds, names = (Options.keys(list)) }
    end

    function impl.remove(handle)
        if handle.kind == 'globalVehicle' then
            ox():removeGlobalVehicle(handle.names)
        elseif handle.kind == 'model' then
            ox():removeModel(handle.models, handle.names)
        elseif handle.kind == 'zone' then
            ox():removeZone(handle.id or handle.name, true)
        elseif handle.kind == 'entity' then
            ox():removeEntity(handle.netIds, handle.names)
        else
            return false
        end
        return true
    end

    return impl
end

return M
