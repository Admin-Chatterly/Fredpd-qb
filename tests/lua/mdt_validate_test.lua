-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_mdt/shared/validate.lua (the Lua mirror of the tablet action input shapes, docs/contracts.md §C12 step 2)
-- against packages/types/test/fixtures/mdt-inputs.fixtures.json, the same file resources/[fredpd]/fredpd_mdt/test/
-- validate.test.ts runs through the zod schemas: every valid sample must give zod's cleaned value, every invalid
-- sample must be refused, and the action set must match the fixtures (which the vitest side matches against
-- MDT_ACTIONS + DISPATCH_ACTIONS + EVIDENCE_ACTIONS).
-- Run: lua5.4 tests/lua/run.lua mdt_validate
local helper = require('helper')

local V = dofile('./resources/[fredpd]/fredpd_mdt/shared/validate.lua')
local FIX = helper.readJson('packages/types/test/fixtures/mdt-inputs.fixtures.json')

local tests = {}

local function keys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out)
    return out
end

tests['fixtures: every valid sample gives the cleaned value zod gives'] = function(t)
    local n = 0
    for _, shape in ipairs(keys(FIX.shapes)) do
        t.ok(V.SHAPES[shape], 'validate.lua has shape ' .. shape)
        for i, sample in ipairs(FIX.shapes[shape].valid) do
            local out, field = V.check(shape, sample.input)
            if out == nil then
                error(('%s valid[%d] refused (field %s): %s'):format(shape, i, tostring(field), helper.dump(sample.input)), 0)
            end
            t.eq(out, sample.output, ('%s valid[%d]'):format(shape, i))
            n = n + 1
        end
    end
    t.ok(n >= 40, 'at least 40 valid samples, got ' .. n)
end

tests['fixtures: every invalid sample is refused'] = function(t)
    local n = 0
    for _, shape in ipairs(keys(FIX.shapes)) do
        for i, sample in ipairs(FIX.shapes[shape].invalid) do
            local out, field = V.check(shape, sample.input)
            if out ~= nil then
                error(('%s invalid[%d] (%s) accepted: %s'):format(shape, i, sample.why, helper.dump(out)), 0)
            end
            t.ok(type(field) == 'string', 'a refusal names the field')
            n = n + 1
        end
    end
    t.ok(n >= 60, 'at least 60 invalid samples, got ' .. n)
end

tests['fixtures: the action set and each action shape match validate.lua'] = function(t)
    t.eq(V.actionNames(), keys(FIX.actions), 'same action names')
    for name, def in pairs(FIX.actions) do
        t.eq(V.ACTIONS[name], def.shape, 'shape of ' .. name)
        local s = FIX.shapes[def.shape]
        t.ok(s and #s.valid >= 1 and #s.invalid >= 1, name .. ' has valid and invalid samples')
    end
    for name in pairs(V.SHAPES) do
        t.ok(FIX.shapes[name], 'every Lua shape has fixtures: ' .. name)
    end
end

tests['validate: unknown actions and non-string names are refused as "action"'] = function(t)
    for _, name in ipairs({ 'nope', '', 'Search', '__index', 'toString' }) do
        local out, field = V.validate(name, {})
        t.eq(out, nil, name)
        t.eq(field, 'action', name)
    end
    t.eq(select(2, V.validate(nil, {})), 'action')
    t.eq(select(2, V.validate(5, {})), 'action')
    t.eq(select(2, V.validate({}, {})), 'action')
    t.eq(V.validate('getHome', {}), {})
end

tests['validate: nil input and non-table input are refused'] = function(t)
    t.eq(select(2, V.validate('getHome', nil)), 'input')
    t.eq(select(2, V.validate('search', 'ab')), 'input')
    t.eq(select(2, V.validate('search', { 'ab' })), 'input', 'a non-empty array is not an object')
end

tests['jsTrim removes exactly the JS white space set'] = function(t)
    local ws = { '\t', '\n', '\v', '\f', '\r', ' ', '\u{A0}', '\u{1680}', '\u{2000}', '\u{2005}', '\u{200A}',
        '\u{2028}', '\u{2029}', '\u{202F}', '\u{205F}', '\u{3000}', '\u{FEFF}' }
    for _, w in ipairs(ws) do
        t.eq(V.jsTrim(w .. 'å' .. w .. 'ö' .. w), 'å' .. w .. 'ö', ('U+%04X'):format(utf8.codepoint(w)))
    end
    for _, keep in ipairs({ '\u{200B}', '\u{85}', '\u{180E}', '\0' }) do
        t.eq(V.jsTrim(keep .. 'x' .. keep), keep .. 'x' .. keep, ('U+%04X is kept'):format(utf8.codepoint(keep)))
    end
    t.eq(V.jsTrim(''), '')
    t.eq(V.jsTrim(' \u{3000} '), '')
    t.eq(V.jsTrim('😀'), '😀')
end

tests['strings: lengths are code points; invalid UTF-8 and oversized strings are refused'] = function(t)
    t.eq(V.length('Öberg😀'), 6)
    t.eq(V.check('PlateInput', { plate = ('Å'):rep(16) }), { plate = ('Å'):rep(16) }, '16 two-byte characters fit')
    t.eq(V.check('PlateInput', { plate = ('Å'):rep(17) }), nil)
    t.eq(V.check('PlateInput', { plate = 'AB\255C' }), nil, 'invalid UTF-8')
    t.eq(V.check('PlateInput', { plate = '\u{D800}' }), nil, 'a surrogate encoded in UTF-8 is invalid')
    t.eq(V.check('SearchInput', { query = (' '):rep(V.MAX_BYTES) .. 'ab' }), nil, 'over MAX_BYTES before trimming')
    t.eq(V.check('SearchInput', { query = (' '):rep(1000) .. 'ab' }).query, 'ab')
end

tests['ints: floats with integral values are accepted, NaN/inf/huge refused'] = function(t)
    t.eq(V.check('AlertIdInput', { id = 3.0 }), { id = 3 })
    t.eq(math.type(V.check('AlertIdInput', { id = 3.0 }).id), 'integer')
    t.eq(V.check('AlertIdInput', { id = 0 / 0 }), nil)
    t.eq(V.check('AlertIdInput', { id = math.huge }), nil)
    t.eq(V.check('AlertIdInput', { id = 2 ^ 53 }), nil)
    t.eq(V.check('AlertIdInput', { id = 2 ^ 53 - 1 }), { id = 9007199254740991 })
    t.eq(V.check('BoloCreateInput', { kind = 'person', citizenid = 'ABC', reason = 'Rån', level = 2.0 }).level, 2)
end

tests['defaults are fresh copies and unknown keys are dropped (strict shapes refuse them)'] = function(t)
    local a = V.check('BoloListInput', {})
    a.page = 99
    t.eq(V.check('BoloListInput', {}), { active = true, page = 1 })
    t.eq(V.check('BoloListInput', { junk = { deep = true }, [5] = 1 }), { active = true, page = 1 })
    t.eq(select(2, V.check('Empty', { [7] = true })), '7')
    t.eq(select(2, V.check('Empty', { extra = false })), 'extra')
end

tests['BoloCreateInput refine reports the kind field'] = function(t)
    local out, field = V.check('BoloCreateInput', { kind = 'vehicle', citizenid = 'ABC', plate = 'X', reason = 'Rån' })
    t.eq(out, nil)
    t.eq(field, 'kind')
    out, field = V.check('BoloCreateInput', { kind = 'vehicle', reason = 'Rån' })
    t.eq(field, 'kind')
    t.eq(V.check('BoloCreateInput', { kind = 'vehicle', plate = ' abc 12d ', reason = ' Rån ' }),
        { kind = 'vehicle', plate = 'abc 12d', reason = 'Rån', level = 0 })
end

return tests
