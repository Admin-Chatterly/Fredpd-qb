-- SPDX-License-Identifier: GPL-3.0-only
-- Inventory bridge: qb-inventory (docs/contracts.md §C17). Verified against qb-inventory dc3d07fc (deps.lock.json):
--   count     exports['qb-inventory']:GetItemCount(src, item) -> number|nil     server/functions.lua:357-376
--   find      exports['qb-inventory']:GetItemsByName(src, item) -> items[]      server/functions.lua:319-333
--             item = { name, amount, info, slot, ... }: metadata is `info`      (AddItem pendingItem, :736-750)
--   add       exports['qb-inventory']:AddItem(id, item, amount, slot, info, reason) -> boolean   :711-802
--   remove    exports['qb-inventory']:RemoveItem(id, item, amount, slot, reason) -> boolean      :812-899
--   usable    exports['qb-core']:CreateUseableItem(item, fn)  (qb-core server/functions.lua:491-510, exported by the
--             loop at :735-739). qb-inventory calls fn(source, item) with the server-side slot item
--             (qb-inventory server/main.lua:244-256 GetItemBySlot -> server/functions.lua:226-235 UseItem).
--             qb-core drops the registration when fredpd_core stops (server/events.lua:23-29, keyed by
--             GetInvokingResource()); server/bridge.lua re-registers when qb-core restarts.
--   hooks     false. (qb-inventory at this pin does have AddHook/AddListener, server/functions.lua:905-971, with an
--             'ItemMoved' event; §C17 defines the `hooks` capability as ox registerHook('swapItems') only. See
--             docs/modules/bridge.md, open question 2.)

local M = { kind = 'inventory', name = 'qb-inventory', resource = 'qb-inventory' }

--- Methods that need another resource than M.resource (server/bridge.lua checks its state instead).
M.REQUIRES = { registerUsable = 'qb-core' }

M.REASON = 'fredpd'

local function matches(info, filter)
    if type(filter) ~= 'table' then return true end
    if type(info) ~= 'table' then return next(filter) == nil end
    for k, v in pairs(filter) do
        if info[k] ~= v then return false end
    end
    return true
end

function M.server()
    local impl = { hooks = false }
    local inv = function() return exports['qb-inventory'] end

    function impl.reset() end

    function impl.count(src, item)
        return math.tointeger(tonumber(inv():GetItemCount(src, item))) or 0
    end

    function impl.find(src, item, filter)
        local out = {}
        for _, it in pairs(inv():GetItemsByName(src, item) or {}) do
            if type(it) == 'table' and tonumber(it.slot) and matches(it.info, filter) then
                out[#out + 1] = { slot = tonumber(it.slot), metadata = type(it.info) == 'table' and it.info or {} }
            end
        end
        table.sort(out, function(a, b) return a.slot < b.slot end)
        return out
    end

    function impl.add(src, item, count, metadata)
        return inv():AddItem(src, item, count, nil, metadata, M.REASON) == true
    end

    function impl.remove(src, item, count, slot)
        return inv():RemoveItem(src, item, count, slot, M.REASON) == true
    end

    --- FredPD's items, added at runtime through qb-core's AddItem export (qb-core server/exports.lua:111-128), so the
    --- server's own qb-core/shared/items.lua never has to be patched or replaced. Idempotent ('item_exists' is fine);
    --- re-run whenever usable items are (re)applied, e.g. after qb-core restarts and forgets runtime items.
    function impl.ensureItems()
        local okL, Locale = pcall(require, 'shared.locale')
        local label = function(key, fallback)
            local text = okL and Locale.L(key) or nil
            return (type(text) == 'string' and text ~= key) and text or fallback
        end
        local defs = {
            pd_tablet = { name = 'pd_tablet', label = label('tablet.itemLabel', 'pd_tablet'), weight = 800, type = 'item',
                image = 'tablet.png', unique = true, useable = true, shouldClose = true, description = '' },
            pd_ram = { name = 'pd_ram', label = label('breach.itemLabel', 'pd_ram'), weight = 9000, type = 'item',
                image = 'police_stormram.png', unique = true, useable = false, shouldClose = true, description = '' },
        }
        for name, def in pairs(defs) do
            pcall(function() exports['qb-core']:AddItem(name, def) end)
        end
        return true
    end

    --- dispatch(src, itemName, slot, metadata) is server/bridge.lua's single handler (it looks up the latest fn).
    function impl.registerUsable(item, dispatch)
        impl.ensureItems()
        exports['qb-core']:CreateUseableItem(item, function(source, itemData)
            local data = type(itemData) == 'table' and itemData or {}
            return dispatch(tonumber(source), item, tonumber(data.slot), type(data.info) == 'table' and data.info or {})
        end)
        return true
    end

    return impl
end

return M
