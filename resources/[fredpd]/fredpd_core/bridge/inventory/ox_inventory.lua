-- SPDX-License-Identifier: GPL-3.0-only
-- Inventory bridge: ox_inventory (docs/contracts.md §C17; the calls FredPD made directly before the bridge). Verified
-- against ox_inventory 952c128f (v2.47.9, deps.lock.json):
--   count     exports.ox_inventory:GetItemCount(inv, item, metadata?) -> number     modules/inventory/server.lua:2322-2341
--   find      exports.ox_inventory:GetSlotsWithItem(inv, item, metadata?) -> slots[] (partial metadata match)  :2272-2295
--   add       exports.ox_inventory:AddItem(inv, item, count, metadata, slot?) -> success, response        :1126-1242
--   remove    exports.ox_inventory:RemoveItem(inv, item, count, metadata?, slot?) -> success, response    :1336-1445
--   usable    the item definition's `server = { export = 'fredpd_core.useItem' }`: ox_inventory builds
--             item.cb = exports.fredpd_core:useItem(event, item, inventory, slot, data) (modules/items/shared.lua:1-5,
--             49-50) and calls it with 'usingItem' before consuming (server.lua:484; false cancels) and 'usedItem'
--             after (server.lua:573). server/bridge.lua dispatches 'usingItem' to the registered fn.
--   hooks     true (exports.ox_inventory:registerHook, modules/hooks/server.lua:118).

local M = { kind = 'inventory', name = 'ox_inventory', resource = 'ox_inventory' }

--- The ox item definitions of registerUsable items must carry this (patches/ox_inventory.*.patch).
M.USE_EXPORT = 'fredpd_core.useItem'

function M.server()
    local impl = { hooks = true }

    function impl.reset() end

    function impl.count(src, item)
        return math.tointeger(tonumber(exports.ox_inventory:GetItemCount(src, item))) or 0
    end

    function impl.find(src, item, filter)
        local out = {}
        local slots = exports.ox_inventory:GetSlotsWithItem(src, item, type(filter) == 'table' and next(filter) and filter or nil)
        for _, s in pairs(slots or {}) do
            if type(s) == 'table' and tonumber(s.slot) then
                out[#out + 1] = { slot = tonumber(s.slot), metadata = type(s.metadata) == 'table' and s.metadata or {} }
            end
        end
        table.sort(out, function(a, b) return a.slot < b.slot end)
        return out
    end

    function impl.add(src, item, count, metadata)
        local ok = exports.ox_inventory:AddItem(src, item, count, metadata)
        return ok == true
    end

    function impl.remove(src, item, count, slot)
        local ok = exports.ox_inventory:RemoveItem(src, item, count, nil, slot)
        return ok == true
    end

    --- Nothing to register in ox_inventory: its item definition points at fredpd_core's useItem export, which
    --- server/bridge.lua routes to the registered fn.
    function impl.registerUsable(_item, _dispatch)
        return true
    end

    --- Translate ox_inventory's item callback (event, item, inventory, slot) for server/bridge.lua. Returns src, itemName,
    --- slot, metadata, or nil when the event is not the one FredPD acts on or the inventory is not a player's.
    function impl.fromUseExport(event, item, inventory, slot)
        if event ~= 'usingItem' then return nil end
        if type(item) ~= 'table' or type(item.name) ~= 'string' or type(inventory) ~= 'table' then return nil end
        local src = tonumber(inventory.id)
        slot = tonumber(slot)
        if not src or src <= 0 or not slot then return nil end
        local slotData = type(inventory.items) == 'table' and inventory.items[slot] or nil
        if type(slotData) ~= 'table' or slotData.name ~= item.name then return nil end
        return src, item.name, slot, type(slotData.metadata) == 'table' and slotData.metadata or {}
    end

    return impl
end

return M
