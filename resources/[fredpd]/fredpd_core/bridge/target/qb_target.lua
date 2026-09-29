-- SPDX-License-Identifier: GPL-3.0-only
-- Target bridge (client): qb-target (docs/contracts.md §C17). Verified against qb-target a3ea78b2 (v5.5.0,
-- deps.lock.json), registration.lua:
--   AddGlobalVehicle({ options, distance }) / RemoveGlobalVehicle(labels)   :250-252, :283-285 (Types[2], :239-277)
--   AddTargetModel(models, { options, distance }) / RemoveTargetModel(models, labels)   :186-235
--   AddBoxZone(name, center, length, width, zoneOptions, { options, distance }) / RemoveZone(name)   :29-38, :74-80
--   AddTargetEntity(entities, { options, distance }) / RemoveTargetEntity(entities, labels)   :133-182 (entity
--     handles; a networked entity is stored under its network id, :136-137)
-- Options are stored BY LABEL (SetOptions :5-14: tbl[v.label] = v; v.distance capped by the call's distance, default
-- Config.MaxDistance 7.0, config.lua:8), so removal is by label and two options with one label on one target collide.
-- Option shape: { label, icon, canInteract(entity, distance, data) (client.lua:48-60), action(entity) (client.lua:505-506:
-- called with the entity only, from a new thread after the NUI closes, :490-525) }. Job/item checks of qb-target
-- (job, item, citizenid, ...) are not used: FredPD's canInteract and the server decide.
-- Box zones go through PolyZone's BoxZone:Create(center, length, width, options) (PolyZone is qb-target's
-- dependency, fxmanifest.lua:12-16, 30, not fetched): length = size.y, width = size.x, heading = rotation,
-- minZ/maxZ = coords.z -/+ size.z / 2. UNVERIFIED against PolyZone's source (docs/modules/bridge.md).

local M = { kind = 'target', name = 'qb-target', resource = 'qb-target' }

function M.client(ctx)
    local Options = ctx.options
    local impl = {}
    local qb = function() return exports['qb-target'] end

    local function convert(list)
        local out = {}
        for i, o in ipairs(list) do
            local can, select = o.canInteract, o.onSelect
            out[i] = {
                label = o.label,
                icon = o.icon,
                distance = o.distance,
                canInteract = can and function(entity, distance)
                    return can(entity, distance, nil) and true or false
                end or nil,
                action = function(entity)
                    if not select then return end
                    local coords = entity and entity ~= 0 and GetEntityCoords(entity) or nil
                    select(Options.selection(entity, coords, nil))
                end,
            }
        end
        return out
    end
    impl.convert = convert

    local function params(list)
        return { options = convert(list), distance = Options.maxDistance(list) }
    end

    function impl.addGlobalVehicle(list)
        qb():AddGlobalVehicle(params(list))
        local _, labels = Options.keys(list)
        return { kind = 'globalVehicle', labels = labels }
    end

    function impl.addModel(models, list)
        qb():AddTargetModel(models, params(list))
        local _, labels = Options.keys(list)
        return { kind = 'model', models = models, labels = labels }
    end

    function impl.addBoxZone(name, box, list)
        local c, s = box.coords, box.size
        local height = s.z or 2.0
        qb():AddBoxZone(name, c, s.y, s.x, {
            name = name,
            heading = box.rotation or 0.0,
            minZ = c.z - height / 2,
            maxZ = c.z + height / 2,
            debugPoly = box.debug == true,
        }, params(list))
        return { kind = 'zone', name = name }
    end

    --- Network ids -> entity handles (qb-target takes entities). Ids whose entity does not exist here are skipped.
    --- Resolved once per call: an entity streamed in later never gets the options, and remove() misses entities no
    --- longer local (ox_target keeps netIds). Documented limitation, docs/modules/bridge.md (no polling, §0).
    local function entitiesOf(netIds)
        local out = {}
        for _, netId in ipairs(type(netIds) == 'table' and netIds or { netIds }) do
            if NetworkDoesNetworkIdExist(netId) then
                local entity = NetworkGetEntityFromNetworkId(netId)
                if entity and entity ~= 0 then out[#out + 1] = entity end
            end
        end
        return out
    end

    function impl.addEntity(netIds, list)
        local entities = entitiesOf(netIds)
        if #entities > 0 then qb():AddTargetEntity(entities, params(list)) end
        local _, labels = Options.keys(list)
        return { kind = 'entity', netIds = netIds, labels = labels }
    end

    function impl.remove(handle)
        if handle.kind == 'globalVehicle' then
            qb():RemoveGlobalVehicle(handle.labels)
        elseif handle.kind == 'model' then
            qb():RemoveTargetModel(handle.models, handle.labels)
        elseif handle.kind == 'zone' then
            qb():RemoveZone(handle.name)
        elseif handle.kind == 'entity' then
            local entities = entitiesOf(handle.netIds)
            if #entities > 0 then qb():RemoveTargetEntity(entities, handle.labels) end
        else
            return false
        end
        return true
    end

    return impl
end

return M
