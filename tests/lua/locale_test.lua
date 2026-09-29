-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_core/shared/locale.lua: {placeholder} substitution, the ox_lib wrapper, and that every L('key') used by
-- fredpd_core / fredpd_devtools exists in locales/sv.json + en.json or in locales/pending/core.json.
-- Run: lua5.4 tests/lua/run.lua locale_test
local Locale = require('shared.locale')
local helper = require('helper')

local tests = {}

--- Run fn with globals replaced, restoring them afterwards (also on error).
local function withGlobals(values, fn)
    local saved = {}
    for k, v in pairs(values) do
        saved[k] = { rawget(_G, k) }
        rawset(_G, k, v)
    end
    local ok, err = pcall(fn)
    for k, v in pairs(saved) do rawset(_G, k, v[1]) end
    if not ok then error(err, 0) end
end

--- A fresh copy of the module (its init flag is per instance).
local function fresh()
    package.loaded['shared.locale'] = nil
    local mod = require('shared.locale')
    package.loaded['shared.locale'] = Locale
    return mod
end

tests['substitute fills named placeholders'] = function(t)
    t.eq(Locale.substitute('Du är i tjänst som {callsign}.', { callsign = 'IGV-07' }), 'Du är i tjänst som IGV-07.')
    t.eq(Locale.substitute('{a}-{b}-{a}', { a = 1, b = 'x' }), '1-x-1')
end

tests['substitute keeps a placeholder without a value'] = function(t)
    t.eq(Locale.substitute('Hej {name}, {missing}', { name = 'Åsa' }), 'Hej Åsa, {missing}')
    t.eq(Locale.substitute('{obj}', { obj = {} }), '{obj}')
    t.eq(Locale.substitute('{f}', { f = print }), '{f}')
end

tests['substitute inserts values literally (% and pattern characters)'] = function(t)
    t.eq(Locale.substitute('Rabatt {p}', { p = '50%' }), 'Rabatt 50%')
    t.eq(Locale.substitute('{x}', { x = '%1 %% (.-)' }), '%1 %% (.-)')
    t.eq(Locale.substitute('100% säker {x}', { x = 'ja' }), '100% säker ja')
end

tests['substitute prints integral floats without .0'] = function(t)
    t.eq(Locale.substitute('{n} st', { n = 5.0 }), '5 st')
    t.eq(Locale.substitute('{n}', { n = 2.5 }), '2.5')
    t.eq(Locale.substitute('{n}', { n = -3 }), '-3')
    t.eq(Locale.substitute('{b}', { b = false }), 'false')
end

tests['substitute ignores non-placeholder braces and handles bad input'] = function(t)
    t.eq(Locale.substitute('{} {1a} { x }', { x = 'y' }), '{} {1a} { x }')
    t.eq(Locale.substitute('text', nil), 'text')
    t.eq(Locale.substitute(nil, { a = 1 }), '')
end

tests['L without ox_lib returns the key (with substitution)'] = function(t)
    withGlobals({ locale = false, lib = false }, function()
        local L = fresh()
        t.eq(L.L('some.key'), 'some.key')
        t.eq(L.raw('x.y'), 'x.y')
    end)
end

tests['L calls locale(key) with the key only, then substitutes'] = function(t)
    local calls = {}
    local dict = { ['officer.dutyStarted'] = 'Du är i tjänst som {callsign}.', ['p.pct'] = '100% {x}' }
    withGlobals({
        locale = function(...)
            calls[#calls + 1] = select('#', ...)
            local key = ...
            return dict[key] or key
        end,
    }, function()
        local L = fresh()
        t.eq(L.L('officer.dutyStarted', { callsign = 'IGV-07' }), 'Du är i tjänst som IGV-07.')
        t.eq(L.L('p.pct', { x = 'säker' }), '100% säker')
        t.eq(L.L('unknown.key'), 'unknown.key')
    end)
    t.eq(calls, { 1, 1, 1 })
end

tests['L survives a locale() that raises'] = function(t)
    withGlobals({ locale = function() error('boom') end }, function()
        t.eq(fresh().L('a.b'), 'a.b')
    end)
end

tests['init loads ox_lib locale when the manifest did not'] = function(t)
    local loaded = 0
    local fakeLib = setmetatable({}, {
        __index = function(tbl, name)
            if name ~= 'locale' then return nil end
            -- ox_lib: indexing lib.locale loads the module, which defines the global locale().
            rawset(_G, 'locale', function(key) return key == 'a.b' and 'Hej {n}' or key end)
            local fn = function() loaded = loaded + 1 end
            rawset(tbl, 'locale', fn)
            return fn
        end,
    })
    withGlobals({ lib = fakeLib, locale = false }, function()
        rawset(_G, 'locale', nil)
        local L = fresh()
        t.eq(L.L('a.b', { n = 1 }), 'Hej 1')
        t.eq(L.L('a.b', { n = 2 }), 'Hej 2')
    end)
    t.eq(loaded, 1)
end

--- Every literal L('key' ...) / Locale.L('key' ...) in the given Lua files.
local function keysUsed(files)
    local keys = {}
    for _, path in ipairs(files) do
        local src = helper.readFile(path)
        for key in src:gmatch("[%.%s%(=,]L%(%s*'([%w_%.]+)'") do keys[key] = path end
    end
    return keys
end

tests['every L() key used by fredpd_core and fredpd_devtools exists in both languages'] = function(t)
    local sv = helper.readJson('locales/sv.json')
    local en = helper.readJson('locales/en.json')
    local pendingFile = io.open('locales/pending/core.json', 'r')
    local pending = {}
    if pendingFile then
        pending = json.decode(pendingFile:read('a'))
        pendingFile:close()
    end
    local p = io.popen("ls 'resources/[fredpd]/fredpd_core/server/'*.lua 'resources/[fredpd]/fredpd_devtools/server/'*.lua")
    local files = {}
    for line in p:lines() do files[#files + 1] = line end
    p:close()
    t.ok(#files >= 8, 'found only ' .. #files .. ' files')
    local keys = keysUsed(files)
    local n = 0
    for key, path in pairs(keys) do
        n = n + 1
        local inMain = sv[key] ~= nil and en[key] ~= nil
        local inPending = type(pending[key]) == 'table' and pending[key].sv and pending[key].en
        t.ok(inMain or inPending, ('%s (used in %s) is missing from locales'):format(key, path))
    end
    t.ok(n >= 20, 'expected at least 20 keys, found ' .. n)
end

return tests
