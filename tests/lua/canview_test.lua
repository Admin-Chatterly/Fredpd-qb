-- SPDX-License-Identifier: GPL-3.0-only
-- canView: shared fixtures (same file as packages/types/test/canView.test.ts) plus Lua-only input quirks
-- (JSON null -> nil, 0/1 TINYINT enabled, missing fields).
local CanView = require('shared.canview')
local Grants = require('shared.grants')
local helper = require('helper')

local fixtures = helper.readJson('packages/types/test/fixtures/canView.fixtures.json')

--- Builds a viewer for the Lua-only tests below from a partial one (fixture viewers are already complete).
local function viewerOf(v)
    local grants = Grants.empty()
    grants.grants = v.grants.grants or {}
    grants.denied = v.grants.denied or {}
    return { citizenid = v.citizenid, tier = v.tier, units = v.units, grants = grants }
end

local tests = {}

tests['fixtures: at least 24 cases, 37 seed rules, sentinel 999 highest'] = function(t)
    t.ok(#fixtures.cases >= 24, 'only ' .. #fixtures.cases .. ' cases')
    t.eq(#fixtures.rules, 37, 'rule count')
    local maxId = 0
    for _, r in ipairs(fixtures.rules) do if r.id > maxId then maxId = r.id end end
    t.eq(maxId, 999, 'highest seeded id')
end

tests['fixtures: every viewer carries a complete GrantSet mirroring tier/units'] = function(t)
    local all = {}
    for _, c in ipairs(fixtures.cases) do all[#all + 1] = c end
    for _, c in ipairs(fixtures.engineCases) do all[#all + 1] = c end
    for _, c in ipairs(all) do
        local g = c.viewer.grants
        t.ok(type(g.grants) == 'table' and type(g.denied) == 'table', c.name .. ': grants/denied')
        t.eq(g.tier, c.viewer.tier, c.name .. ': grants.tier')
        t.eq(g.units, c.viewer.units, c.name .. ': grants.units')
        t.eq(g.rank, nil, c.name .. ': rank (JSON null)')
        t.ok(type(g.computedAt) == 'string', c.name .. ': computedAt')
    end
end

-- Fixture viewers are used exactly as decoded from JSON.
for i, c in ipairs(fixtures.cases) do
    tests[('fixture %02d: %s'):format(i, c.name)] = function(t)
        t.eq(CanView.evaluate(c.viewer, c.record, fixtures.rules), c.expected)
    end
end

for i, c in ipairs(fixtures.engineCases) do
    tests[('engine %02d: %s'):format(i, c.name)] = function(t)
        t.eq(CanView.evaluate(c.viewer, c.record, c.rules), c.expected)
    end
end

-- Input the schemas reject (as decoded: JSON null -> nil); must fail closed exactly like the TS port.
for i, c in ipairs(fixtures.unvalidatedCases) do
    tests[('unvalidated %02d: %s'):format(i, c.name)] = function(t)
        t.eq(CanView.evaluate(c.viewer, c.record, c.rules), c.expected)
    end
end

tests['rank orders none < notice < masked < full'] = function(t)
    for i, result in ipairs(CanView.RESULTS) do t.eq(CanView.rank(result), i - 1, result) end
    t.eq(CanView.rank('bogus'), -1)
end

tests['cap keeps the lower of result and cap'] = function(t)
    t.eq(CanView.cap('full', 'masked'), 'masked')
    t.eq(CanView.cap('masked', 'notice'), 'notice')
    t.eq(CanView.cap('notice', 'masked'), 'notice')
    t.eq(CanView.cap('none', 'full'), 'none')
end

tests['does not reorder the caller rules table'] = function(t)
    local own = {}
    for i = #fixtures.rules, 1, -1 do own[#own + 1] = fixtures.rules[i] end
    local before = {}
    for i, r in ipairs(own) do before[i] = r.id end
    local c = fixtures.cases[1]
    CanView.evaluate(c.viewer, c.record, own)
    for i, r in ipairs(own) do t.eq(r.id, before[i], 'index ' .. i) end
end

-- DB rows via oxmysql: enabled may be 0/1, level NULL arrives as nil.
tests['enabled as TINYINT: 1 applies, 0 is skipped'] = function(t)
    local viewer = viewerOf({ citizenid = 'X', tier = 0, units = {}, grants = { grants = {}, denied = {} } })
    local record = { type = 'case', id = 1, level = 0, status = 'open' }
    local rule = { id = 1, recordType = '*', recordStatus = 'any', viewerCondition = 'any', result = 'full', priority = 1 }
    rule.enabled = 1
    t.eq(CanView.evaluate(viewer, record, { rule }), 'full')
    rule.enabled = 0
    t.eq(CanView.evaluate(viewer, record, { rule }), 'none')
end

tests['unknown condition or result never grants'] = function(t)
    local viewer = viewerOf({ citizenid = 'X', tier = 2, units = {}, grants = { grants = {}, denied = {} } })
    local record = { type = 'case', id = 1, level = 0, status = 'open' }
    local base = { id = 1, recordType = '*', recordStatus = 'any', priority = 1, enabled = true }
    local badCond = setmetatable({ viewerCondition = 'friend', result = 'full' }, { __index = base })
    local badResult = setmetatable({ viewerCondition = 'any', result = 'everything' }, { __index = base })
    t.eq(CanView.evaluate(viewer, record, { badCond }), 'none')
    t.eq(CanView.evaluate(viewer, record, { badResult }), 'none')
end

tests['missing viewer fields fail closed'] = function(t)
    local rules = { { id = 1, recordType = '*', recordStatus = 'any', viewerCondition = 'tier_gte', result = 'full',
        priority = 1, enabled = true } }
    t.eq(CanView.evaluate({}, { type = 'poi', id = 1, level = 0, status = 'open' }, rules), 'full')
    t.eq(CanView.evaluate({}, { type = 'poi', id = 1, level = 1, status = 'open' }, rules), 'none')
    t.eq(CanView.evaluate(nil, { type = 'poi', id = 1, level = 1, status = 'open' }, nil), 'none')
end

tests['missing record level is treated as the highest level'] = function(t)
    local viewer = viewerOf({ citizenid = 'X', tier = 1, units = {}, grants = { grants = {}, denied = {} } })
    local rules = { { id = 1, recordType = '*', recordStatus = 'any', viewerCondition = 'any', result = 'full',
        priority = 1, enabled = true } }
    t.eq(CanView.evaluate(viewer, { type = 'poi', id = 1, status = 'open' }, rules), 'notice')
end

tests['json.null-style sentinels behave like nil'] = function(t)
    local null = setmetatable({}, { __name = 'json.null' })
    local viewer = viewerOf({ citizenid = 'X', tier = 0, units = { 'igv' }, grants = { grants = {}, denied = {} } })
    local anyLevel = { id = 1, recordType = '*', level = null, recordStatus = 'any', viewerCondition = 'unit',
        conditionValue = null, result = 'full', priority = 1, enabled = true }
    t.eq(CanView.evaluate(viewer, { type = 'case', id = 1, level = 1, status = 'open', unit = 'igv' }, { anyLevel }),
        'notice') -- rule matched (level any, unit from record), then the level cap
    t.eq(CanView.evaluate(viewer, { type = 'case', id = 1, level = 0, status = 'open', unit = null }, { anyLevel }),
        'none')
end

tests['empty-string citizenid is no identity'] = function(t)
    local viewer = viewerOf({ citizenid = '', tier = 0, units = {}, grants = { grants = {}, denied = {} } })
    local rules = { { id = 1, recordType = '*', recordStatus = 'any', viewerCondition = 'assigned', result = 'full',
        priority = 1, enabled = true } }
    t.eq(CanView.evaluate(viewer, { type = 'case', id = 1, level = 0, status = 'open', ownerCitizenid = '' }, rules),
        'none')
end

return tests
