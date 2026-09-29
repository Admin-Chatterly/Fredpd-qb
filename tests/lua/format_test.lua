-- SPDX-License-Identifier: GPL-3.0-only
-- shared/format.lua against packages/types/test/fixtures/format.fixtures.json (the same file Vitest runs),
-- plus Lua-only checks (M.load, not_loaded, DST sweep). Run: lua5.4 tests/lua/run.lua format_test

local helper = require('helper')
local Format = require('shared.format')
local Regex = require('shared.regex')

local fixtures = helper.readJson('packages/types/test/fixtures/format.fixtures.json')

--- Base formats shallow-merged with a case's overrides (same rule as the TS suite).
local function merged(over)
    local f = {}
    for k, v in pairs(fixtures.formats) do f[k] = v end
    for k, v in pairs(over or {}) do f[k] = v end
    return f
end

local function errorCode(err)
    return type(err) == 'string' and err:match('^([%w_]+): ') or nil
end

local function run(c)
    local formats = merged(c.formats)
    local fn = c.fn
    if fn == 'formatId' then
        -- Not `c.ctx or {}`: a fixture ctx of false must reach formatId unchanged (TS uses `c.ctx ?? {}`).
        local ctx = c.ctx
        if ctx == nil then ctx = {} end
        return Format.formatId(c.template or fixtures.formats[c.format], ctx, formats)
    elseif fn == 'templateToRegex' then
        return Format.templateToRegex(c.format, formats)
    elseif fn == 'detectSearchType' then
        return Format.detectSearchType(c.query, formats)
    elseif fn == 'formatDate' then
        return Format.formatDate(c.input, formats)
    elseif fn == 'formatTime' then
        return Format.formatTime(c.input, formats)
    elseif fn == 'formatCurrency' then
        return Format.formatCurrency(c.input, formats)
    elseif fn == 'load' then
        -- Validate without touching the active formats (M.load itself is covered below).
        Format.templateToRegex('caseNumber', formats)
        return nil
    end
    error('unknown fixture fn ' .. tostring(fn))
end

local suite = {}

for i, c in ipairs(fixtures.cases) do
    suite[('fixture %03d %s'):format(i, c.name)] = function(t)
        local ok, res = pcall(run, c)
        if c.error then
            t.ok(not ok, ('expected error %s, got %s'):format(c.error, helper.dump(res)))
            t.eq(errorCode(res), c.error, 'error code of ' .. tostring(res))
            return
        end
        t.ok(ok, tostring(res))
        if c.expected ~= nil then t.eq(res, c.expected) end
        if c.fn == 'templateToRegex' then
            local re = Regex.compile(res)
            for _, s in ipairs(c.matches or {}) do t.ok(re:test(s), res .. ' should match ' .. s) end
            for _, s in ipairs(c.rejects or {}) do t.ok(not re:test(s), res .. ' should reject ' .. s) end
        end
    end
end

suite['fixture file has at least 20 cases'] = function(t)
    t.ok(#fixtures.cases >= 20, 'only ' .. #fixtures.cases .. ' cases')
end

suite['not_loaded before M.load when no formats are passed'] = function(t)
    package.loaded['shared.format'] = nil
    local fresh = require('shared.format')
    package.loaded['shared.format'] = Format
    local ok, err = pcall(fresh.formatCurrency, 5)
    t.ok(not ok)
    t.eq(errorCode(err), 'not_loaded')
    t.eq(fresh.get(), nil)
    -- A template without yy/yyyy needs no formats at all.
    t.eq(fresh.formatId('{{unit}}-{{n:2}}', { unit = 'IGV', n = 7 }), 'IGV-07')
end

suite['M.load(config/formats.json) sets the defaults'] = function(t)
    package.loaded['shared.format'] = nil
    local fresh = require('shared.format')
    package.loaded['shared.format'] = Format
    local loaded = fresh.load(helper.readJson('config/formats.json'))
    t.eq(loaded.currency.decimalSeparator, ',')
    t.eq(loaded['$comment'], nil)
    t.eq(fresh.get(), loaded)
    t.eq(fresh.formatCurrency(1234567), '1 234 567 kr')
    t.eq(fresh.formatId(loaded.caseNumber, { seq = 123, date = '2026-05-01T10:00:00Z' }), 'K-123-26')
    t.eq(fresh.detectSearchType('abc 12d'), { type = 'plate', normalized = 'ABC12D' })
    t.eq(fresh.formatDate('2026-06-30T22:30:00Z'), '2026-07-01')
    t.eq(fresh.templateToRegex('evidenceTag'), '^B-K-\\d+-\\d{2}-\\d{3,}$')
end

suite['M.load rejects an invalid config and keeps the previous one'] = function(t)
    package.loaded['shared.format'] = nil
    local fresh = require('shared.format')
    package.loaded['shared.format'] = Format
    fresh.load(merged())
    local ok, err = pcall(fresh.load, merged({ plate = 'a|b' }))
    t.ok(not ok)
    t.eq(errorCode(err), 'invalid_config')
    t.eq(fresh.formatTime('2026-01-15T12:00:00Z'), '13:00')
end

suite['formatted ids round-trip through their own templateToRegex'] = function(t)
    local f = merged()
    local date = '2026-09-29T12:00:00Z'
    local case = Format.formatId(f.caseNumber, { seq = 4711, date = date }, f)
    local ids = {
        caseNumber = case,
        reportNumber = Format.formatId(f.reportNumber, { case = case, n = 12 }, f),
        evidenceTag = Format.formatId(f.evidenceTag, { case = case, n = 5 }, f),
        callsign = Format.formatId(f.callsign, { unit = 'UTR', n = 3 }, f),
    }
    for name, id in pairs(ids) do
        t.ok(Regex.compile(Format.templateToRegex(name, f)):test(id), name .. ' ' .. id)
    end
end

suite['formatId rejects a ctx that is not a table, including false (TS rejects it too)'] = function(t)
    local f = merged()
    t.eq(Format.formatId('ABC', nil, f), 'ABC')
    for _, bad in ipairs({ false, true, 5, 'IGV', function() end }) do
        local ok, err = pcall(Format.formatId, 'ABC', bad, f)
        t.ok(not ok, tostring(bad))
        t.eq(errorCode(err), 'invalid_value', tostring(err))
    end
end

suite['errors carry the code without a Lua position prefix'] = function(t)
    local ok, err = pcall(Format.formatId, 'X-{{foo}}', {}, merged())
    t.ok(not ok)
    t.ok(err:find('^unknown_placeholder: ') ~= nil, err)
end

suite['formatCurrency rejects integers that would wrap around'] = function(t)
    local two = merged({ currency = { symbol = 'kr', decimals = 2, thousandsSeparator = ' ', position = 'suffix' } })
    for _, f in ipairs({ merged(), two }) do
        for _, v in ipairs({ math.mininteger, math.maxinteger, 100000000000000000, -100000000000000000 }) do
            local ok, err = pcall(Format.formatCurrency, v, f)
            t.ok(not ok, ('%d should be rejected, got %s'):format(v, tostring(err)))
            t.eq(errorCode(err), 'invalid_value', tostring(err))
        end
    end
    -- Integer and float inputs give the same text.
    t.eq(Format.formatCurrency(1234567, two), '1 234 567,00 kr')
    t.eq(Format.formatCurrency(1234567.0, two), '1 234 567,00 kr')
end

suite['out-of-range instants raise invalid_value instead of a Lua error'] = function(t)
    local f = merged()
    for _, v in ipairs({ 1e300, -1e300, math.maxinteger, math.mininteger, 8640000000001000 }) do
        local ok, err = pcall(Format.formatDate, v, f)
        t.ok(not ok, tostring(v))
        t.eq(errorCode(err), 'invalid_value', tostring(err))
    end
end

suite['detectSearchType folds every non-ASCII JS whitespace character'] = function(t)
    local f = merged()
    local spaces = { 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF }
    for cp = 0x2000, 0x200A do spaces[#spaces + 1] = cp end
    for _, cp in ipairs(spaces) do
        local sp = utf8.char(cp)
        t.eq(Format.detectSearchType(sp .. 'abc' .. sp .. '12d' .. sp, f), { type = 'plate', normalized = 'ABC12D' },
            ('U+%04X'):format(cp))
    end
    -- Neighbours of the folded ranges stay as they are.
    t.eq(Format.detectSearchType('a' .. utf8.char(0x200B) .. 'b', f).normalized, 'a' .. utf8.char(0x200B) .. 'b')
    t.eq(Format.detectSearchType('a' .. utf8.char(0x2027) .. 'b', f).normalized, 'a' .. utf8.char(0x2027) .. 'b')
end

--- Day of week (0 = Sunday) by Zeller's congruence, independent of the module's day arithmetic.
local function weekday(y, m, d)
    if m < 3 then
        m = m + 12
        y = y - 1
    end
    local k, j = y % 100, y // 100
    local h = (d + (13 * (m + 1)) // 5 + k + k // 4 + j // 4 + 5 * j) % 7 -- 0 = Saturday
    return (h + 6) % 7
end

suite['EU DST switch lands on the last Sunday at 01:00 UTC for 1996-2060'] = function(t)
    local f = merged()
    for y = 1996, 2060 do
        for _, spec in ipairs({ { 3, '01:59', '03:00' }, { 10, '02:59', '02:00' } }) do
            local m, before, after = spec[1], spec[2], spec[3]
            local d = 31 - weekday(y, m, 31) -- March and October both have 31 days
            local stamp = ('%04d-%02d-%02dT'):format(y, m, d)
            t.eq(Format.formatTime(stamp .. '00:59:00Z', f), before, stamp .. '00:59Z')
            t.eq(Format.formatTime(stamp .. '01:00:00Z', f), after, stamp .. '01:00Z')
            -- One week earlier the same UTC time is not a switch.
            local prev = ('%04d-%02d-%02dT01:00:00Z'):format(y, m, d - 7)
            t.eq(Format.formatTime(prev, f), m == 3 and '02:00' or '03:00', prev)
        end
    end
end

return suite
