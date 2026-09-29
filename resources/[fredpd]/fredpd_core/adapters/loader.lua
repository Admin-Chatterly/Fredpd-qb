-- SPDX-License-Identifier: GPL-3.0-only
-- Picks the active adapter per kind from config/integrations.json (IMPLEMENTATION.md §9) and exposes
-- exports.fredpd_core:getAdapter(kind). Config value "ps-housing" loads adapters/housing/ps_housing.lua (dashes
-- become underscores); a missing or unknown value falls back to "none" with one warning.

local Base = require 'adapters.base'
local Core = require 'server.core'

local M = {}

--- Older config spellings -> adapter name. (The former prison alias qbx_police -> qbx_police-jail is gone: qbx_police
--- has no jail of its own, docs/deps-verification.md §2; "qbx_police" is now an unknown name and falls back to none.)
M.ALIASES = {}

local active = {}

--- Module path of an adapter: ('housing', 'ps-housing') -> 'adapters.housing.ps_housing'.
function M.moduleName(kind, name)
    return ('adapters.%s.%s'):format(kind, (name:gsub('%-', '_')))
end

--- Load the configured adapters. cfg = decoded integrations.json (nil = all "none").
--- opts = { require = fn, log = { warn, error, debug }, defer = fn(ms, cb) } for tests.
--- @return table active adapters by kind
function M.load(cfg, opts)
    opts = opts or {}
    local req = opts.require or require
    local log = opts.log or Core
    local loaded = {}
    for _, kind in ipairs(Base.KINDS) do
        local name = type(cfg) == 'table' and cfg[kind] or nil
        if type(name) ~= 'string' or name == '' then name = 'none' end
        name = (M.ALIASES[kind] or {})[name] or name
        local adapter = nil
        if name:match('^[%w_%-]+$') then -- no dots or slashes: the name cannot leave adapters/<kind>/
            local ok, mod = pcall(req, M.moduleName(kind, name))
            if ok and type(mod) == 'table' and mod.kind == kind then adapter = mod end
        end
        if not adapter then
            log.warn('unknown %s adapter "%s" in config/integrations.json; using "none"', kind, name)
            adapter = req(M.moduleName(kind, 'none'))
        end
        adapter.init(log, opts.defer)
        loaded[kind] = adapter
    end
    active = loaded
    return loaded
end

--- The active adapter of a kind (the kind's "none" before M.load or for an unknown kind's caller mistakes).
function M.get(kind)
    if active[kind] then return active[kind] end
    if Base.INTERFACES[kind] then return require(M.moduleName(kind, 'none')) end
    return nil
end

function M.register()
    -- Other resources: local housing = exports.fredpd_core:getAdapter('housing'); housing.unlock(propertyId, src)
    -- (call with a dot: the methods take no self).
    exports('getAdapter', M.get)
end

return M
