-- SPDX-License-Identifier: GPL-3.0-only
-- Grants: shared fixtures (same file as packages/types/test/grants.test.ts) plus Lua-only input quirks
-- (0/1 TINYINTs, nil/null fields, JSON round trip).
local Grants = require('shared.grants')
local helper = require('helper')

local FIXTURES = 'packages/types/test/fixtures/grants.fixtures.json'
local fixtures = helper.readJson(FIXTURES)
local NOW = 1790683200 -- 2026-09-29T12:00:00Z
local ISO = '^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$'

local tests = {}

local function inputOf(c)
    return {
        memberRoleIds = c.memberRoleIds,
        roles = c.roles or fixtures.roles,
        grants = c.grants,
        unitOrder = c.unitOrder or fixtures.unitOrder,
    }
end

local function reversed(list)
    local out = {}
    for i = #list, 1, -1 do out[#out + 1] = list[i] end
    return out
end

local function withoutTime(set)
    local copy = {}
    for k, v in pairs(set) do copy[k] = v end
    copy.computedAt = nil
    return copy
end

tests['fixtures: at least 20 cases'] = function(t)
    t.ok(#fixtures.cases >= 20, 'only ' .. #fixtures.cases .. ' cases')
end

for i, c in ipairs(fixtures.cases) do
    tests[('fixture %02d: %s'):format(i, c.name)] = function(t)
        local result = Grants.resolve(inputOf(c), NOW)
        t.eq(result.computedAt, '2026-09-29T12:00:00Z', 'computedAt')
        t.eq(withoutTime(result), c.expected)
        for _, check in ipairs(c.checks or {}) do
            t.eq(Grants.has(result, check.type, check.key), check.expected, ('has %s:%s'):format(check.type, check.key))
        end
        -- Order of the DB rows must not matter.
        local input = inputOf(c)
        input.roles, input.grants = reversed(input.roles), reversed(input.grants)
        t.eq(withoutTime(Grants.resolve(input, NOW)), c.expected, 'reversed input')
    end
end

-- Rows the TS schema rejects (DB/JSON callers): ignored exactly as in grants.ts.
for i, c in ipairs(fixtures.unvalidatedCases) do
    tests[('unvalidated %02d: %s'):format(i, c.name)] = function(t)
        local result = Grants.resolve(inputOf(c), NOW)
        t.eq(withoutTime(result), c.expected)
        for _, check in ipairs(c.checks or {}) do
            t.eq(Grants.has(result, check.type, check.key), check.expected, ('has %s:%s'):format(check.type, check.key))
        end
    end
end

tests['empty() is an empty set with an ISO timestamp'] = function(t)
    local set = Grants.empty()
    t.ok(set.computedAt:match(ISO), 'computedAt ' .. set.computedAt)
    t.eq(withoutTime(set), { grants = {}, denied = {}, tier = 0, units = {}, rank = nil })
    t.eq(Grants.has(set, 'weapon', 'pistol'), false)
end

tests['resolve(nil) and resolve({}) give an empty set'] = function(t)
    t.eq(withoutTime(Grants.resolve(nil)), withoutTime(Grants.empty()))
    t.eq(withoutTime(Grants.resolve({})), withoutTime(Grants.empty()))
    t.ok(Grants.resolve({}).computedAt:match(ISO), 'computedAt')
end

tests['has() tolerates missing set, lists and key'] = function(t)
    t.eq(Grants.has(nil, 'perm', 'intel.read'), false)
    t.eq(Grants.has({}, 'perm', 'intel.read'), false)
    t.eq(Grants.has({ grants = { 'perm:intel.read' } }, 'perm', 'intel.read'), true) -- denied missing
    t.eq(Grants.has({ grants = { 'perm:*' } }, 'perm', nil), false)
    t.eq(Grants.has({ grants = { 'intel_tier:2' }, denied = {} }, 'intel_tier', 2), true) -- numeric key
end

tests['DB TINYINT deleted: 1 is deleted, 0 is not (0 is truthy in Lua)'] = function(t)
    local input = {
        memberRoleIds = { 'a', 'b' },
        roles = {
            { discordRoleId = 'a', name = 'A', position = 1, deleted = 0 },
            { discordRoleId = 'b', name = 'B', position = 2, deleted = 1 },
        },
        grants = {
            { discordRoleId = 'a', grantType = 'weapon', grantKey = 'pistol', effect = 'allow' },
            { discordRoleId = 'b', grantType = 'weapon', grantKey = 'rifle', effect = 'allow' },
        },
    }
    t.eq(Grants.resolve(input).grants, { 'weapon:pistol' })
end

tests['rows with unknown type/effect, empty or missing key are ignored'] = function(t)
    local input = {
        memberRoleIds = { 'a' },
        roles = { { discordRoleId = 'a', name = 'A', position = 1, deleted = false } },
        grants = {
            { discordRoleId = 'a', grantType = 'spell', grantKey = 'fireball', effect = 'allow' },
            { discordRoleId = 'a', grantType = 'weapon', grantKey = 'pistol', effect = 'maybe' },
            { discordRoleId = 'a', grantType = 'weapon', grantKey = '', effect = 'deny' },
            { discordRoleId = 'a', grantType = 'weapon', effect = 'deny' },
            { discordRoleId = 'a', grantType = 'weapon', grantKey = 'smg', effect = 'allow' },
        },
    }
    local set = Grants.resolve(input)
    t.eq(set.grants, { 'weapon:smg' })
    t.eq(set.denied, {})
end

tests['JSON round trip: rank null decodes to nil, empty lists stay arrays'] = function(t)
    local set = Grants.resolve({ memberRoleIds = {}, roles = {}, grants = {}, unitOrder = {} }, NOW)
    local encoded = json.encode(set)
    t.ok(encoded:find('"grants":[]', 1, true), 'grants encoded as array: ' .. encoded)
    t.eq(json.decode(encoded), set)
    local ranked = Grants.resolve(inputOf(fixtures.cases[#fixtures.cases]), NOW)
    t.eq(json.decode(json.encode(ranked)), ranked)
end

tests['tier is an integer (encodes as 2, not 2.0)'] = function(t)
    local set = Grants.resolve({
        memberRoleIds = { 'a' },
        roles = { { discordRoleId = 'a', name = 'A', position = 1, deleted = false } },
        grants = { { discordRoleId = 'a', grantType = 'intel_tier', grantKey = '99999999999999999999', effect = 'allow' } },
    })
    t.eq(math.type(set.tier), 'integer')
    t.eq(set.tier, 2)
end

tests['byteLess orders bytewise, independent of locale'] = function(t)
    t.eq(Grants.byteLess('B', 'a'), true)
    t.eq(Grants.byteLess('a', 'ab'), true)
    t.eq(Grants.byteLess('ab', 'a'), false)
    t.eq(Grants.byteLess('x', 'x'), false)
end

return tests
