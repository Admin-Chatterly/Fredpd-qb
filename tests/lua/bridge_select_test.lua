-- SPDX-License-Identifier: GPL-3.0-only
-- Bridge selection (fredpd_core/bridge/select.lua, docs/contracts.md §C17): configured value, 'auto' (first started,
-- ox first), unknown values, nothing installed. Run: lua5.4 tests/lua/run.lua bridge_select
local Select = require('bridge.select')
local helper = require('helper')

local tests = {}

local function states(map)
    return function(resource) return map[resource] or 'missing' end
end

tests['configured implementation wins, whatever runs'] = function(t)
    t.eq({ Select.resolve('framework', 'qb-core', states({ qbx_core = 'started' })) }, { 'qb-core' })
    t.eq({ Select.resolve('inventory', 'ox_inventory', states({})) }, { 'ox_inventory' }, 'missing is reported later')
    t.eq({ Select.resolve('target', 'qb-target', states({ ox_target = 'started', ['qb-target'] = 'started' })) },
        { 'qb-target' })
    t.eq({ Select.resolve('doorlock', 'ox_doorlock', states({ ['qb-doorlock'] = 'started' })) }, { 'ox_doorlock' })
end

tests['auto: first started, ox preferred when both run'] = function(t)
    local both = states({ qbx_core = 'started', ['qb-core'] = 'started', ox_inventory = 'started',
        ['qb-inventory'] = 'started', ox_target = 'started', ['qb-target'] = 'started', ox_doorlock = 'started',
        ['qb-doorlock'] = 'started' })
    for _, kind in ipairs(Select.KINDS) do
        t.eq(Select.resolve(kind, 'auto', both), Select.IMPLS[kind][1], kind)
    end
    local qbOnly = states({ ['qb-core'] = 'started', ['qb-inventory'] = 'started', ['qb-target'] = 'started',
        ['qb-doorlock'] = 'started', ox_target = 'stopped' })
    t.eq(Select.resolve('framework', 'auto', qbOnly), 'qb-core')
    t.eq(Select.resolve('inventory', nil, qbOnly), 'qb-inventory', 'nil = auto')
    t.eq(Select.resolve('target', '', qbOnly), 'qb-target', 'empty = auto; a started one beats a stopped ox')
end

tests['auto: nothing started -> starting, then installed, then the qb default'] = function(t)
    t.eq({ Select.resolve('target', 'auto', states({ ['qb-target'] = 'starting', ox_target = 'stopped' })) },
        { 'qb-target' })
    t.eq({ Select.resolve('target', 'auto', states({ ['qb-target'] = 'stopped', ox_target = 'stopped' })) },
        { 'ox_target', 'not_started' })
    t.eq({ Select.resolve('doorlock', 'auto', states({ ['qb-doorlock'] = 'stopped' })) }, { 'qb-doorlock', 'not_started' })
    t.eq({ Select.resolve('framework', 'auto', states({})) }, { 'qb-core', 'none_installed' })
    t.eq({ Select.resolve('inventory', 'auto', states({})) }, { 'qb-inventory', 'none_installed' })
end

tests['unknown configured value falls back to auto and says so'] = function(t)
    t.eq({ Select.resolve('inventory', 'qs-inventory', states({ ox_inventory = 'started' })) }, { 'ox_inventory', 'unknown' })
    t.eq({ Select.resolve('framework', 'es_extended', states({})) }, { 'qb-core', 'unknown' })
    t.eq({ Select.resolve('housing', 'auto', states({})) }, { nil, 'unknown_kind' })
end

tests['module names and files'] = function(t)
    t.eq(Select.moduleName('target', 'qb-target'), 'bridge.target.qb_target')
    t.eq(Select.file('doorlock', 'ox_doorlock'), 'bridge/doorlock/ox_doorlock.lua')
    for _, kind in ipairs(Select.KINDS) do
        for _, impl in ipairs(Select.IMPLS[kind]) do
            local f = io.open('resources/[fredpd]/fredpd_core/' .. Select.file(kind, impl), 'r')
            t.ok(f ~= nil, 'implementation file for ' .. impl)
            if f then f:close() end
        end
        t.ok(Select.isImpl(kind, Select.DEFAULT[kind]), 'default of ' .. kind)
    end
end

tests['config/integrations.json selects the qb stack (target server)'] = function(t)
    local cfg = helper.readJson('config/integrations.json')
    for _, kind in ipairs(Select.KINDS) do
        t.ok(cfg[kind] == 'auto' or Select.isImpl(kind, cfg[kind]), kind .. ' = ' .. tostring(cfg[kind]))
    end
    t.eq(cfg.framework, 'qb-core')
    t.eq(cfg.inventory, 'qb-inventory')
end

return tests
