-- SPDX-License-Identifier: GPL-3.0-only
-- /fredpd_selftest runner: the shared fixtures (packages/types/test/fixtures/*.fixtures.json, copied into
-- fredpd_devtools/fixtures/ by scripts/build.mjs) run against fredpd_core's shared Lua modules inside FXServer, with
-- the same rules as tests/lua/{grants,canview,format,regex}_test.lua. Pure: the modules and decoded fixtures are
-- passed in, so tests/lua/core_selftest_test.lua runs it outside FiveM too.

local M = {}

M.NOW = 1790683200 -- fixed computedAt for grant resolution (2026-09-29T12:00:00Z)

--- Remove JSON-null sentinels (userdata or json.null) so decoded fixtures compare like the plain-Lua test harness.
local function stripNulls(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in pairs(v) do
        local isNull = type(x) == 'userdata' or (type(json) == 'table' and json.null ~= nil and x == json.null)
        if not isNull then out[k] = stripNulls(x) end
    end
    return out
end
M.stripNulls = stripNulls

local function deepEqual(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for k, v in pairs(a) do
        if not deepEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end
M.deepEqual = deepEqual

local function show(v)
    if type(v) ~= 'table' then return tostring(v) end
    local ok, s = pcall(json.encode, v)
    return ok and s or tostring(v)
end

local function suite(name)
    return { name = name, passed = 0, total = 0, failures = {} }
end

--- Run one check: fn returns true, or false/raises with a message.
local function check(s, label, fn)
    s.total = s.total + 1
    local ok, good, msg = pcall(fn)
    if ok and good then
        s.passed = s.passed + 1
    else
        s.failures[#s.failures + 1] = ('%s: %s'):format(label, ok and tostring(msg) or tostring(good))
    end
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

--- grants.fixtures.json against Grants.resolve / Grants.has (also with reversed DB row order).
function M.grants(fixtures, Grants)
    local s = suite('grants')
    fixtures = stripNulls(fixtures)
    for i, c in ipairs(fixtures.cases or {}) do
        check(s, ('%02d %s'):format(i, c.name), function()
            local input = {
                memberRoleIds = c.memberRoleIds, roles = c.roles or fixtures.roles, grants = c.grants,
                unitOrder = c.unitOrder or fixtures.unitOrder,
            }
            local result = withoutTime(Grants.resolve(input, M.NOW))
            if not deepEqual(result, c.expected) then
                return false, ('expected %s, got %s'):format(show(c.expected), show(result))
            end
            for _, chk in ipairs(c.checks or {}) do
                local got = Grants.has(result, chk.type, chk.key)
                if got ~= chk.expected then return false, ('has %s:%s = %s'):format(chk.type, chk.key, tostring(got)) end
            end
            input.roles, input.grants = reversed(input.roles), reversed(input.grants)
            if not deepEqual(withoutTime(Grants.resolve(input, M.NOW)), c.expected) then
                return false, 'differs with reversed input'
            end
            return true
        end)
    end
    return s
end

--- canView.fixtures.json (seed-rule cases and engine cases) against CanView.evaluate.
function M.canView(fixtures, CanView, Grants)
    local s = suite('canView')
    local function viewerOf(v)
        local set = Grants.empty(M.NOW)
        set.grants = v.grants and v.grants.grants or {}
        set.denied = v.grants and v.grants.denied or {}
        return { citizenid = v.citizenid, tier = v.tier, units = v.units, grants = set }
    end
    local function run(label, c, rules)
        check(s, label, function()
            local got = CanView.evaluate(viewerOf(c.viewer), c.record, rules)
            if got ~= c.expected then return false, ('expected %s, got %s'):format(c.expected, got) end
            return true
        end)
    end
    for i, c in ipairs(fixtures.cases or {}) do run(('%02d %s'):format(i, c.name), c, fixtures.rules) end
    for i, c in ipairs(fixtures.engineCases or {}) do run(('engine %02d %s'):format(i, c.name), c, c.rules) end
    return s
end

--- format.fixtures.json cases against Format; the regex section against Regex when given.
function M.format(fixtures, Format, Regex)
    local s = suite('format')
    fixtures = stripNulls(fixtures)
    local function merged(over)
        local f = {}
        for k, v in pairs(fixtures.formats) do f[k] = v end
        for k, v in pairs(over or {}) do f[k] = v end
        return f
    end
    local function run(c)
        local formats = merged(c.formats)
        local fn = c.fn
        if fn == 'formatId' then return Format.formatId(c.template or fixtures.formats[c.format], c.ctx or {}, formats) end
        if fn == 'templateToRegex' then return Format.templateToRegex(c.format, formats) end
        if fn == 'detectSearchType' then return Format.detectSearchType(c.query, formats) end
        if fn == 'formatDate' then return Format.formatDate(c.input, formats) end
        if fn == 'formatTime' then return Format.formatTime(c.input, formats) end
        if fn == 'formatCurrency' then return Format.formatCurrency(c.input, formats) end
        if fn == 'load' then
            Format.templateToRegex('caseNumber', formats)
            return nil
        end
        error('unknown fixture fn ' .. tostring(fn))
    end
    for i, c in ipairs(fixtures.cases or {}) do
        check(s, ('%03d %s'):format(i, c.name), function()
            local ok, res = pcall(run, c)
            if c.error then
                local code = not ok and type(res) == 'string' and res:match('^([%w_]+): ') or nil
                if code ~= c.error then return false, ('expected error %s, got %s'):format(c.error, show(res)) end
                return true
            end
            if not ok then return false, tostring(res) end
            if c.expected ~= nil and not deepEqual(res, c.expected) then
                return false, ('expected %s, got %s'):format(show(c.expected), show(res))
            end
            if c.fn == 'templateToRegex' and Regex then
                local re = Regex.compile(res)
                for _, str in ipairs(c.matches or {}) do
                    if not re:test(str) then return false, res .. ' should match ' .. str end
                end
                for _, str in ipairs(c.rejects or {}) do
                    if re:test(str) then return false, res .. ' should reject ' .. str end
                end
            end
            return true
        end)
    end
    if Regex then
        for i, r in ipairs(fixtures.regex or {}) do
            check(s, ('regex %02d %s'):format(i, r.pattern), function()
                local ok, re = pcall(Regex.compile, r.pattern)
                if r.error then return not ok, 'expected a compile error' end
                if not ok then return false, tostring(re) end
                for _, str in ipairs(r.yes or {}) do
                    if not re:test(str) then return false, 'should match ' .. show(str) end
                end
                for _, str in ipairs(r.no or {}) do
                    if re:test(str) then return false, 'should reject ' .. show(str) end
                end
                return true
            end)
        end
    end
    return s
end

--- Run every suite. fixtures = { grants, canView, format } (decoded JSON), mods = { Grants, CanView, Format, Regex }.
--- @return table { suites = { suite... }, passed, total, failed }
function M.run(fixtures, mods)
    local suites = {
        M.grants(fixtures.grants, mods.Grants),
        M.canView(fixtures.canView, mods.CanView, mods.Grants),
        M.format(fixtures.format, mods.Format, mods.Regex),
    }
    local passed, total = 0, 0
    for _, s in ipairs(suites) do
        passed, total = passed + s.passed, total + s.total
    end
    return { suites = suites, passed = passed, total = total, failed = total - passed }
end

return M
