-- SPDX-License-Identifier: GPL-3.0-only
-- Inventory bridge (docs/contracts.md §C17): the qb-inventory and ox_inventory implementations against mocks shaped
-- like the pinned sources, argument validation, registerUsable on both (qb-core CreateUseableItem / ox item export
-- fredpd_core.useItem), the hooks capability, and the resource-down degradation. Run: lua5.4 tests/lua/run.lua bridge_inventory
local H = require('bridge_harness_test')

local tests = {}

local QB = { framework = 'qb-core', inventory = 'qb-inventory', target = 'qb-target', doorlock = 'qb-doorlock' }
local OX = { framework = 'qbx_core', inventory = 'ox_inventory', target = 'ox_target', doorlock = 'ox_doorlock' }

--- qb-inventory mock (qb-inventory dc3d07fc server/functions.lua): items per player are slot -> { name, amount, info,
--- slot, type } (AddItem's pendingItem :736-750). GetItemCount :357-376 (nil without a player), GetItemsByName
--- :319-333 (nil without a player), AddItem(identifier, item, amount, slot, info, reason) :711-802, RemoveItem(identifier,
--- item, amount, slot, reason) :812-899.
local function qbInventory(inv, calls)
    return {
        GetItemCount = function(_, src, item)
            calls[#calls + 1] = { 'GetItemCount', src, item }
            local items = inv[src]
            if not items then return nil end
            local n = 0
            for _, it in pairs(items) do if it.name == item then n = n + it.amount end end
            return n
        end,
        GetItemsByName = function(_, src, item)
            calls[#calls + 1] = { 'GetItemsByName', src, item }
            local items = inv[src]
            if not items then return nil end
            local out = {}
            for _, it in pairs(items) do if it.name == item then out[#out + 1] = it end end
            return out
        end,
        AddItem = function(_, identifier, item, amount, slot, info, reason)
            calls[#calls + 1] = { 'AddItem', identifier, item, amount, slot, info, reason }
            local items = inv[identifier]
            if not items then return false end
            local s = slot or (#items + 1)
            items[s] = { name = item, amount = amount, info = info or {}, slot = s, type = 'item' }
            return true
        end,
        RemoveItem = function(_, identifier, item, amount, slot, reason)
            calls[#calls + 1] = { 'RemoveItem', identifier, item, amount, slot, reason }
            local items = inv[identifier]
            local it = items and slot and items[slot]
            if not it or it.name ~= item or it.amount < amount then return false end
            it.amount = it.amount - amount
            if it.amount == 0 then items[slot] = nil end
            return true
        end,
    }
end

--- ox_inventory mock (952c128f modules/inventory/server.lua): GetItemCount(inv, item, metadata?) :2322-2341,
--- GetSlotsWithItem(inv, item, metadata?) :2272-2295 (partial metadata match), AddItem(inv, item, count, metadata,
--- slot?) -> success, response :1126-1242, RemoveItem(inv, item, count, metadata?, slot?) :1336-1445.
local function oxInventory(inv, calls)
    local function partial(meta, filter)
        if not filter then return true end
        for k, v in pairs(filter) do if (meta or {})[k] ~= v then return false end end
        return true
    end
    return {
        GetItemCount = function(_, src, item, metadata)
            calls[#calls + 1] = { 'GetItemCount', src, item, metadata }
            local n = 0
            for _, it in pairs(inv[src] or {}) do
                if it.name == item and partial(it.metadata, metadata) then n = n + it.count end
            end
            return n
        end,
        GetSlotsWithItem = function(_, src, item, metadata)
            calls[#calls + 1] = { 'GetSlotsWithItem', src, item, metadata }
            local out = {}
            for _, it in pairs(inv[src] or {}) do
                if it.name == item and partial(it.metadata, metadata) then out[#out + 1] = it end
            end
            return out
        end,
        AddItem = function(_, src, item, count, metadata, slot)
            calls[#calls + 1] = { 'AddItem', src, item, count, metadata, slot }
            if not inv[src] then return false, 'invalid_inventory' end
            local s = #inv[src] + 1
            inv[src][s] = { name = item, count = count, metadata = metadata or {}, slot = s }
            return true, inv[src][s]
        end,
        RemoveItem = function(_, src, item, count, metadata, slot)
            calls[#calls + 1] = { 'RemoveItem', src, item, count, metadata, slot }
            local it = inv[src] and inv[src][slot]
            if not it or it.name ~= item or it.count < count then return false, 'not_enough_items' end
            it.count = it.count - count
            return true
        end,
    }
end

local function qbEnv(inv, calls, extra)
    local core, usable = H.qbCore({}, calls)
    local opts = { cfg = QB, states = { ['qb-core'] = 'started', ['qb-inventory'] = 'started' },
        resources = { ['qb-core'] = core, ['qb-inventory'] = qbInventory(inv, calls) } }
    for k, v in pairs(extra or {}) do opts[k] = v end
    return opts, usable
end

tests['qb-inventory: count / find (info = metadata, filter) / add (info, reason) / remove (slot)'] = function(t)
    local inv = { [3] = {
        [1] = { name = 'pd_tablet', amount = 1, info = { serial = 'T-1', owner = 'A' }, slot = 1, type = 'item' },
        [4] = { name = 'pd_tablet', amount = 1, info = { serial = 'T-2', owner = 'B' }, slot = 4, type = 'item' },
        [2] = { name = 'bandage', amount = 5, info = {}, slot = 2, type = 'item' },
    } }
    local calls = {}
    H.with((qbEnv(inv, calls)), function(env)
        local B = env.Bridge
        t.eq(B.count(3, 'pd_tablet'), 2)
        t.eq(B.count(3, 'bandage'), 5)
        t.eq(B.count(9, 'bandage'), 0, 'GetItemCount nil (no player) -> 0')
        t.eq(B.find(3, 'pd_tablet'), { { slot = 1, metadata = { serial = 'T-1', owner = 'A' } },
            { slot = 4, metadata = { serial = 'T-2', owner = 'B' } } }, 'sorted by slot')
        t.eq(B.find(3, 'pd_tablet', { serial = 'T-2' }), { { slot = 4, metadata = { serial = 'T-2', owner = 'B' } } })
        t.eq(B.find(3, 'pd_tablet', { serial = 'nope' }), {})
        t.eq(B.find(9, 'pd_tablet'), {}, 'GetItemsByName nil -> {}')
        t.eq(B.add(3, 'pd_tablet', 1, { serial = 'T-3' }), true)
        t.eq(calls[#calls], { 'AddItem', 3, 'pd_tablet', 1, nil, { serial = 'T-3' }, 'fredpd' },
            'info is the 5th argument, slot nil (first free)')
        t.eq(B.remove(3, 'bandage', 2, 2), true)
        t.eq(calls[#calls], { 'RemoveItem', 3, 'bandage', 2, 2, 'fredpd' })
        t.eq(inv[3][2].amount, 3)
        t.eq(B.remove(3, 'bandage', 99, 2), false, 'upstream refusal passes through')
        t.eq(B.hasFeature('inventoryHooks'), false, 'qb-inventory: no ox hooks')
    end)
end

tests['inventory arguments are validated before any upstream call'] = function(t)
    local calls = {}
    H.with((qbEnv({ [1] = {} }, calls)), function(env)
        local B = env.Bridge
        local before = #calls
        t.eq(B.count(0, 'x'), 0)
        t.eq(B.count(1.5, 'x'), 0)
        t.eq(B.count(1, 'bad item'), 0)
        t.eq(B.count(1, ('x'):rep(65)), 0)
        t.eq(B.find(1, 'x', 'notatable'), {})
        t.eq(B.add(1, 'x', 0), false)
        t.eq(B.add(1, 'x', 1.5), false)
        t.eq(B.add(1, 'x', 2000000), false)
        t.eq(B.add(1, 'x', 1, 'meta'), false)
        t.eq(B.remove(-1, 'x', 1), false)
        t.eq(#calls, before, 'nothing reached qb-inventory')
    end)
end

tests['qb-inventory registerUsable: qb-core CreateUseableItem, fn(src, slot, info), re-applied when qb-core restarts'] = function(t)
    local calls = {}
    local opts, usable = qbEnv({ [1] = {} }, calls, { invoker = 'fredpd_core' })
    H.with(opts, function(env)
        local B = env.Bridge
        local got = {}
        t.eq(B.registerUsable('pd_tablet', function(src, slot, meta) got[#got + 1] = { src, slot, meta } end), true)
        t.ok(usable.pd_tablet ~= nil, 'registered in qb-core UsableItems')
        t.eq(usable.pd_tablet.resource, 'fredpd_core', 'owned by fredpd_core (qb-core drops it on our stop)')
        -- qb-inventory UseItem (server/functions.lua:226-235): func(source, item) with the server-side slot item.
        usable.pd_tablet.func(1, { name = 'pd_tablet', amount = 1, slot = 6, info = { serial = 'T-9' }, type = 'item' })
        t.eq(got, { { 1, 6, { serial = 'T-9' } } })
        usable.pd_tablet.func(1, { name = 'pd_tablet', slot = 7 })
        t.eq(got[2], { 1, 7, {} }, 'missing info -> {}')

        -- a failing fn is contained
        B.registerUsable('boom', function() error('kaboom') end)
        usable.boom.func(1, { name = 'boom', slot = 1, info = {} })
        t.eq(H.count(env.logs.error, 'usable item boom failed'), 1, 'logged, not raised into qb-inventory')

        t.eq(B.registerUsable('bad item', function() end), false)
        t.eq(B.registerUsable('x', 'notfn'), false)

        -- qb-core restarts: its UsableItems table is new; the bridge re-registers every remembered item.
        for k in pairs(usable) do usable[k] = nil end
        env.fire('onResourceStart', '', 'qb-core')
        t.ok(usable.pd_tablet ~= nil and usable.boom ~= nil, 're-registered')
    end)
end

tests['qb-inventory registerUsable while qb-core is down: remembered, one warning, applied on its start'] = function(t)
    local calls = {}
    local opts, usable = qbEnv({}, calls)
    opts.states = { ['qb-inventory'] = 'started', ['qb-core'] = 'stopped' }
    H.with(opts, function(env)
        t.eq(env.Bridge.registerUsable('pd_tablet', function() end), true)
        env.Bridge.registerUsable('pd_ram', function() end)
        t.eq(usable.pd_tablet, nil)
        t.eq(H.count(env.logs.warn, 'resource qb-core is stopped'), 1, table.concat(env.logs.warn, '\n'))
        env.states['qb-core'] = 'started'
        env.fire('onResourceStart', '', 'qb-core')
        t.ok(usable.pd_tablet ~= nil and usable.pd_ram ~= nil)
    end)
end

tests['ox_inventory: count / find (partial metadata) / add / remove(slot); hooks capability'] = function(t)
    local inv = { [5] = {
        [1] = { name = 'pd_tablet', count = 1, metadata = { serial = 'T-1' }, slot = 1 },
        [3] = { name = 'pd_tablet', count = 1, metadata = { serial = 'T-2' }, slot = 3 },
    } }
    local calls = {}
    H.with({ cfg = OX, states = { ox_inventory = 'started' }, resources = { ox_inventory = oxInventory(inv, calls) } },
        function(env)
            local B = env.Bridge
            t.eq(B.count(5, 'pd_tablet'), 2)
            t.eq(calls[#calls], { 'GetItemCount', 5, 'pd_tablet', nil })
            t.eq(B.find(5, 'pd_tablet', { serial = 'T-2' }), { { slot = 3, metadata = { serial = 'T-2' } } })
            t.eq(calls[#calls], { 'GetSlotsWithItem', 5, 'pd_tablet', { serial = 'T-2' } })
            B.find(5, 'pd_tablet', {})
            t.eq(calls[#calls], { 'GetSlotsWithItem', 5, 'pd_tablet', nil }, 'empty filter -> no metadata argument')
            t.eq(#B.find(5, 'pd_tablet'), 2)
            t.eq(B.add(5, 'pd_tablet', 1, { serial = 'T-3' }), true)
            t.eq(calls[#calls], { 'AddItem', 5, 'pd_tablet', 1, { serial = 'T-3' }, nil })
            t.eq(B.add(99, 'pd_tablet', 1), false, '(false, reason) -> false')
            t.eq(B.remove(5, 'pd_tablet', 1, 3), true)
            t.eq(calls[#calls], { 'RemoveItem', 5, 'pd_tablet', 1, nil, 3 })
            t.eq(B.hasFeature('inventoryHooks'), true)
            t.eq(B.info().hooks, true)
        end)
end

tests['ox_inventory registerUsable: item export fredpd_core.useItem, only from ox_inventory, usingItem only'] = function(t)
    local inv = { [5] = {} }
    H.with({ cfg = OX, states = { ox_inventory = 'started' }, resources = { ox_inventory = oxInventory(inv, {}) } },
        function(env)
            local B = env.Bridge
            local got = {}
            t.eq(B.registerUsable('pd_tablet', function(src, slot, meta)
                got[#got + 1] = { src, slot, meta }
                if meta.serial == 'REVOKED' then return false end
            end), true)
            local useItem = env.exported.useItem
            local inventory = { id = 5, type = 'player', items = {
                [2] = { name = 'pd_tablet', slot = 2, count = 1, metadata = { serial = 'T-1' } },
                [4] = { name = 'pd_tablet', slot = 4, count = 1, metadata = { serial = 'REVOKED' } },
            } }
            -- ox_inventory builds item.cb = exports.fredpd_core:useItem(event, item, inventory, slot, data)
            -- (modules/items/shared.lua:1-5, 49-50) and calls it with 'usingItem' (server.lua:484), then 'usedItem'.
            env.invoker = 'ox_inventory'
            t.eq(useItem('usingItem', { name = 'pd_tablet' }, inventory, 2), nil, 'nil = go on')
            t.eq(got, { { 5, 2, { serial = 'T-1' } } }, 'metadata from the server-side slot')
            t.eq(useItem('usingItem', { name = 'pd_tablet' }, inventory, 4), false, 'false cancels the use')
            t.eq(useItem('usedItem', { name = 'pd_tablet' }, inventory, 2), nil)
            t.eq(#got, 2, 'usedItem ignored')
            t.eq(useItem('usingItem', { name = 'pd_ram' }, inventory, 2), nil, 'slot holds another item')
            t.eq(useItem('usingItem', { name = 'pd_tablet' }, { id = 'glovebox:ABC', items = inventory.items }, 2), nil,
                'not a player inventory')
            t.eq(#got, 2)
            env.invoker = 'some_cheat'
            t.eq(useItem('usingItem', { name = 'pd_tablet' }, inventory, 2), false, 'other callers refused')
            t.eq(#got, 2)
        end)
end

tests['inventory resource down: count 0 / find {} / add false with ONE warning; upstream error logged, rate limited'] = function(t)
    local calls = {}
    local opts = qbEnv({ [1] = {} }, calls)
    opts.states['qb-inventory'] = 'stopped'
    H.with(opts, function(env)
        local B = env.Bridge
        t.eq(B.count(1, 'x'), 0)
        t.eq(B.find(1, 'x'), {})
        t.eq(B.add(1, 'x', 1), false)
        t.eq(B.remove(1, 'x', 1), false)
        t.eq(H.count(env.logs.warn, 'resource qb-inventory is stopped'), 1)
        t.eq(#calls, 0)
        env.states['qb-inventory'] = 'started'
        env.resources['qb-inventory'].GetItemCount = function() error('boom') end
        t.eq(B.count(1, 'x'), 0)
        t.eq(B.count(1, 'x'), 0)
        t.eq(H.count(env.logs.error, 'inventory bridge "qb-inventory".count failed'), 1, 'rate limited')
        env.now = B.ERROR_LOG_MS
        B.count(1, 'x')
        t.eq(H.count(env.logs.error, '.count failed'), 2)
    end)
end

return tests
