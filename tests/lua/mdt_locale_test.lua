-- SPDX-License-Identifier: GPL-3.0-only
-- Every player-facing key fredpd_mdt uses (L('…') calls and the 'tablet.*' / 'errors.*' / 'officer.*' keys the open
-- flow returns to the client) exists in Swedish and English: locales/*.json or the pending files this module relies
-- on (pending/mdt.json, pending/core.json until merged). Placeholders must match between the languages.
-- Run: lua5.4 tests/lua/run.lua mdt_locale
local helper = require('helper')

local ROOT = './resources/[fredpd]/fredpd_mdt/'
local FILES = { 'client/main.lua', 'server/main.lua', 'server/open.lua', 'server/home.lua', 'server/tablets.lua',
    'server/dispatch.lua', 'server/common.lua' }

local tests = {}

local function dictionaries()
    local sv, en = helper.readJson('locales/sv.json'), helper.readJson('locales/en.json')
    for _, file in ipairs({ 'locales/pending/core.json', 'locales/pending/mdt.json' }) do
        for k, v in pairs(helper.readJson(file)) do
            if type(v) == 'table' then sv[k], en[k] = v.sv, v.en end
        end
    end
    return sv, en
end

local function placeholders(text)
    local out = {}
    for name in text:gmatch('{([%a_][%w_]*)}') do out[#out + 1] = name end
    table.sort(out)
    return out
end

--- Keys used by the code: L('x.y'), C.L('x.y') and quoted 'tablet.*' / 'errors.*' / 'officer.*' literals.
local function usedKeys()
    local keys = {}
    for _, file in ipairs(FILES) do
        local src = helper.readFile(ROOT .. file)
        for key in src:gmatch("L%(%s*'([%w_.]+)'") do keys[key] = file end
        for _, prefix in ipairs({ 'tablet', 'errors', 'officer' }) do
            for key in src:gmatch("'(" .. prefix .. "%.[%w_.]+)'") do keys[key] = file end
        end
    end
    return keys
end

tests['every key fredpd_mdt shows exists in sv and en with the same placeholders'] = function(t)
    local sv, en = dictionaries()
    local n = 0
    for key, file in pairs(usedKeys()) do
        n = n + 1
        t.ok(type(sv[key]) == 'string' and sv[key] ~= '', ('%s (%s) missing in sv'):format(key, file))
        t.ok(type(en[key]) == 'string' and en[key] ~= '', ('%s (%s) missing in en'):format(key, file))
        t.eq(placeholders(sv[key]), placeholders(en[key]), key .. ' placeholders')
    end
    t.ok(n >= 15, 'found the keys (' .. n .. ')')
end

tests['pending/mdt.json adds only new keys and has both languages'] = function(t)
    local base = helper.readJson('locales/sv.json')
    for key, v in pairs(helper.readJson('locales/pending/mdt.json')) do
        if key:sub(1, 1) ~= '$' then
            t.eq(base[key], nil, key .. ' already in sv.json')
            t.ok(type(v) == 'table' and v.sv and v.en, key .. ' has sv and en')
        end
    end
end

return tests
