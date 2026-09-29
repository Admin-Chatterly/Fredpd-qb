-- SPDX-License-Identifier: GPL-3.0-only
-- Framework bridge selection (docs/contracts.md §C17, docs/modules/bridge.md). Pure: the resource state lookup is
-- passed in, so the same code picks the server implementations (server/bridge.lua, GetResourceState on FXServer)
-- and the client ones (bridge/client.lua), and runs in tests without FiveM.

local M = {}

M.KINDS = { 'framework', 'inventory', 'target', 'doorlock' }

--- Implementations per kind, in 'auto' preference order (ox/Qbox first, §C17 "ox wins when both run").
--- The implementation name is also the resource it talks to.
M.IMPLS = {
    framework = { 'qbx_core', 'qb-core' },
    inventory = { 'ox_inventory', 'qb-inventory' },
    target = { 'ox_target', 'qb-target' },
    doorlock = { 'ox_doorlock', 'qb-doorlock' },
}

--- Used when 'auto' finds neither resource installed (the target server runs the qb scripts, §C17).
M.DEFAULT = {
    framework = 'qb-core',
    inventory = 'qb-inventory',
    target = 'qb-target',
    doorlock = 'qb-doorlock',
}

--- Module file of an implementation: ('target', 'qb-target') -> 'bridge/target/qb_target.lua'.
function M.file(kind, impl)
    return ('bridge/%s/%s.lua'):format(kind, (impl:gsub('%-', '_')))
end

--- ox_lib/`require` module name of an implementation: ('target', 'qb-target') -> 'bridge.target.qb_target'.
function M.moduleName(kind, impl)
    return ('bridge.%s.%s'):format(kind, (impl:gsub('%-', '_')))
end

--- Accept the common spelling variants in config/integrations.json: case, '-' vs '_' ('ox-target', 'QB_Target').
--- Returns the canonical implementation name, or nil when it is not an implementation of that kind.
function M.canonical(kind, name)
    if type(name) ~= 'string' then return nil end
    local key = name:lower():gsub('[%-_%s]', '')
    for _, impl in ipairs(M.IMPLS[kind] or {}) do
        if impl:gsub('[%-_]', '') == key then return impl end
    end
    return nil
end

function M.isImpl(kind, name)
    for _, impl in ipairs(M.IMPLS[kind] or {}) do
        if impl == name then return true end
    end
    return false
end

--- Pick the implementation of a kind.
--- configured: the config value ('auto', an implementation name, nil/'' = 'auto', anything else = unknown -> 'auto').
--- stateOf(resource) -> 'started' | 'starting' | 'stopped' | 'stopping' | 'uninitialized' | 'missing' | ...
--- @return string|nil impl
--- @return string|nil note nil | 'unknown' (configured value is not an implementation; auto used)
---                       | 'not_started' (auto: installed but not running yet) | 'none_installed' (auto: default used)
function M.resolve(kind, configured, stateOf)
    local list = M.IMPLS[kind]
    if not list then return nil, 'unknown_kind' end
    local note = nil
    if configured ~= nil and configured ~= '' and configured ~= 'auto' then
        local impl = M.canonical(kind, configured)
        if impl then return impl, nil end
        note = 'unknown'
    end
    for _, name in ipairs(list) do
        if stateOf(name) == 'started' then return name, note end
    end
    for _, name in ipairs(list) do
        if stateOf(name) == 'starting' then return name, note end
    end
    -- Nothing runs yet: the first installed one (ox first). Decided once at fredpd_core start, so 'auto' needs the
    -- upstream resources ensured before fredpd_core; server/bridge.lua warns once if the other one runs later.
    for _, name in ipairs(list) do
        if stateOf(name) ~= 'missing' then return name, note or 'not_started' end
    end
    return M.DEFAULT[kind], note or 'none_installed'
end

return M
