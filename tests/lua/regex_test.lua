-- SPDX-License-Identifier: GPL-3.0-only
-- shared/regex.lua: direct engine tests plus the `regex` section of format.fixtures.json, whose expectations are
-- also asserted against native JS RegExp by packages/types/test/format.test.ts.
-- Run: lua5.4 tests/lua/run.lua regex_test

local helper = require('helper')
local Regex = require('shared.regex')

local fixtures = helper.readJson('packages/types/test/fixtures/format.fixtures.json')

--- Assert pattern matches every string in yes and none in no.
local function check(t, pattern, yes, no)
    local re = Regex.compile(pattern)
    for _, s in ipairs(yes) do t.ok(re:test(s), ('/%s/ should match %q'):format(pattern, s)) end
    for _, s in ipairs(no) do t.ok(not re:test(s), ('/%s/ should not match %q'):format(pattern, s)) end
end

local function compileError(pattern)
    local ok, err = pcall(Regex.compile, pattern)
    if ok then return nil end
    return err
end

local suite = {}

suite['anchors'] = function(t)
    check(t, '^abc', { 'abc', 'abcd' }, { 'xabc', 'ab' })
    check(t, 'abc$', { 'abc', 'xabc' }, { 'abcx' })
    check(t, '^abc$', { 'abc' }, { 'abcc', 'aabc', '' })
    check(t, 'b', { 'abc', 'b' }, { 'ac', '' }) -- unanchored search, like RegExp.test
    check(t, 'a^b', {}, { 'ab', 'a^b' }) -- ^ is an assertion, not a literal
end

suite['dot'] = function(t)
    check(t, '^.$', { 'a', ' ', '.' }, { '', 'ab', '\n', '\r' })
    check(t, '^a\\.b$', { 'a.b' }, { 'axb' })
end

suite['classes and ranges'] = function(t)
    check(t, '^[a-c]$', { 'a', 'b', 'c' }, { 'd', 'A', '' })
    check(t, '^[A-Za-z_]+$', { 'Anna_B' }, { 'Anna B', 'Anna-B' })
    check(t, '^[-a]$', { '-', 'a' }, { 'b' })
    check(t, '^[a-]$', { '-', 'a' }, { 'b' })
    check(t, '^[\\s\\d]+$', { ' 1\t2' }, { '1a' })
    check(t, '^[.]$', { '.' }, { 'a' }) -- metacharacters are literal inside a class
end

suite['negated class'] = function(t)
    check(t, '^[^a-c]$', { 'd', '1', '-' }, { 'a', 'c', '' })
    check(t, '^[^\\d]+$', { 'abc' }, { 'a1c' })
    check(t, '^[^^]$', { 'a' }, { '^' })
end

suite['shorthand classes'] = function(t)
    check(t, '^\\d+$', { '0123456789' }, { '12a', '' })
    check(t, '^\\D+$', { 'abc' }, { 'a1' })
    check(t, '^\\s+$', { ' \t\n\r\f\v' }, { ' a ' })
    check(t, '^\\S+$', { 'abc' }, { 'a c' })
    check(t, '^\\w+$', { 'Az09_' }, { 'a-b' })
    check(t, '^\\W+$', { '-+ ' }, { '-a' })
end

suite['quantifiers ? * +'] = function(t)
    check(t, '^ab?c$', { 'ac', 'abc' }, { 'abbc' })
    check(t, '^ab*c$', { 'ac', 'abc', 'abbbbc' }, { 'adc' })
    check(t, '^ab+c$', { 'abc', 'abbc' }, { 'ac' })
    -- greedy with backtracking: a* must give back one 'a' for the final a
    check(t, '^a*a$', { 'a', 'aaaa' }, { '', 'b' })
    check(t, '^\\d+\\d{2}$', { '123', '12345' }, { '12' })
end

suite['bounded quantifiers {n} {n,} {n,m}'] = function(t)
    check(t, '^a{3}$', { 'aaa' }, { 'aa', 'aaaa' })
    check(t, '^a{2,}$', { 'aa', 'aaaaaa' }, { 'a' })
    check(t, '^a{2,4}$', { 'aa', 'aaa', 'aaaa' }, { 'a', 'aaaaa' })
    check(t, '^a{0,1}b$', { 'b', 'ab' }, { 'aab' })
    check(t, '^[A-Z]{3}\\s?\\d{2}[A-Z0-9]$', { 'ABC 12D', 'ABC123' }, { 'ABC  12D', 'AB123' })
end

suite['escapes of punctuation and controls'] = function(t)
    check(t, '^\\(\\)\\[\\]\\{\\}\\|\\*\\+\\?\\^\\$\\\\\\/\\-$', { '()[]{}|*+?^$\\/-' }, { '()' })
    check(t, '^a\\tb$', { 'a\tb' }, { 'a b' })
    check(t, 'a]b}', { 'a]b}' }, { 'ab' }) -- bare ] and } are literals, as in JS
end

suite['compile errors for unsupported syntax'] = function(t)
    local cases = {
        '(a)', 'a|b', '(?:a)', '(?=a)', '\\1', '\\b', '\\B', '\\p{L}', '\\x41', '\\u0041', '\\0',
        'a*?', 'a+?', 'a??', 'a{2}?', 'a**', '*a', '+a', '?a', '^*', '$+', '{2}', 'a{', 'a{,2}', 'a{2,1}',
        '[a', '[z-a]', '[\\b]', 'abc\\', '[ö]', 'ö+', '\\ö', 'a{5000}',
    }
    for _, p in ipairs(cases) do
        local err = compileError(p)
        t.ok(err ~= nil, ('/%s/ should not compile'):format(p))
        t.ok(err:find('^invalid_regex: ') ~= nil, ('/%s/: %s'):format(p, tostring(err)))
    end
end

suite['non-ASCII literals outside classes match byte-wise'] = function(t)
    check(t, '^Kärr-\\d+$', { 'Kärr-12' }, { 'Karr-12' })
end

suite['compiled matcher exposes its source and rejects non-strings'] = function(t)
    local re = Regex.compile('^\\d$')
    t.eq(re.source, '^\\d$')
    t.ok(not pcall(re.test, re, 5))
    t.ok(not pcall(Regex.compile, 5))
end

suite['memoised backtracking stays polynomial'] = function(t)
    -- Without memoisation this is ~C(308, 8) paths; with it, a few hundred thousand steps.
    local re = Regex.compile('^\\d*\\d*\\d*\\d*\\d*\\d*\\d*\\d*x$')
    local started = os.clock()
    t.ok(not re:test(('1'):rep(300) .. 'y'))
    t.ok(re:test(('1'):rep(300) .. 'x'))
    t.ok(os.clock() - started < 2, 'took too long')
end

for i, r in ipairs(fixtures.regex) do
    suite[('fixture %02d /%s/'):format(i, r.pattern)] = function(t)
        if r.error then
            local err = compileError(r.pattern)
            t.ok(err ~= nil and err:find('^invalid_regex: ') ~= nil, 'expected invalid_regex, got ' .. tostring(err))
            return
        end
        check(t, r.pattern, r.yes or {}, r.no or {})
    end
end

return suite
