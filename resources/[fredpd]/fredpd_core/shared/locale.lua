-- SPDX-License-Identifier: GPL-3.0-only
-- L(key, vars): player-facing text (docs/contracts.md §C8). Wraps ox_lib's `locale()` and substitutes named
-- `{placeholders}` itself: ox_lib's own `locale(key, ...)` runs string.format, which breaks on '%' and cannot do
-- named placeholders, so `locale` is always called with the key alone.
--
-- Usage in any FredPD resource (needs '@ox_lib/init.lua' and ideally `ox_lib 'locale'` in its fxmanifest, plus the
-- locales/*.json the build copies in):
--   local L = require('@fredpd_core.shared.locale').L      -- from another resource
--   local L = require('shared.locale').L                   -- inside fredpd_core
--   L('officer.dutyStarted', { callsign = 'IGV-07' })      --> 'Du är i tjänst som IGV-07.'
-- The pure part (M.substitute) is tested outside FiveM by tests/lua/locale_test.lua.

local M = {}

--- Text for one value: integral floats print without '.0' (JSON numbers often arrive as floats).
local function display(v)
    local t = type(v)
    if t == 'string' then return v end
    if t == 'number' then
        if math.type(v) == 'float' and v == math.floor(v) and v > -2 ^ 53 and v < 2 ^ 53 then
            return ('%d'):format(math.tointeger(v))
        end
        return tostring(v)
    end
    if t == 'boolean' then return tostring(v) end
    return nil -- tables, functions, nil: keep the placeholder visible instead of printing 'table: 0x...'
end

--- Replace `{name}` with vars[name]. Names follow the locale rules ({camelCase}); a placeholder without a usable
--- value is left as-is so a missing variable shows up in the text rather than raising in the middle of a handler.
--- Replacement text is inserted literally (no pattern or format interpretation of '%').
--- @param text string
--- @param vars table|nil
--- @return string
function M.substitute(text, vars)
    if type(text) ~= 'string' then return '' end
    if type(vars) ~= 'table' then return text end
    return (text:gsub('{([%a_][%w_]*)}', function(name)
        return display(vars[name])
    end))
end

local initialised = false

--- Make sure ox_lib's locale dictionary is loaded. With `ox_lib 'locale'` in the fxmanifest it already is; otherwise
--- the first L() call loads it (ox_lib reads locales/<ox:locale>.json with en.json as fallback).
function M.init()
    if initialised then return end
    initialised = true
    if type(locale) ~= 'function' and type(lib) == 'table' then
        local loader = lib.locale -- indexing lib loads the module, which defines the global `locale`
        if type(loader) == 'function' then loader() end
    end
end

--- Raw text for a key (the key itself when unknown or outside FiveM).
--- @param key string
--- @return string
function M.raw(key)
    M.init()
    if type(locale) == 'function' then
        local ok, text = pcall(locale, key)
        if ok and type(text) == 'string' then return text end
    end
    return key
end

--- Localised text with `{name}` placeholders filled from vars.
--- @param key string
--- @param vars table|nil
--- @return string
function M.L(key, vars)
    return M.substitute(M.raw(key), vars)
end

return M
