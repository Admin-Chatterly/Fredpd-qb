-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_devtools pure modules: the /fredpd_selftest runner over the real shared fixtures (what FXServer will
-- print), the /fredpd_seed generator, and the /fredpd_fakeunits SetTimeout chain (ends at its deadline).
-- Run: lua5.4 tests/lua/run.lua core_devtools_test
local helper = require('helper')
local Grants = require('shared.grants')
local CanView = require('shared.canview')
local Format = require('shared.format')
local Regex = require('shared.regex')
local Time = require('shared.time')
local Mirror = require('server.mirror')

local DEVTOOLS = 'resources/[fredpd]/fredpd_devtools/server/'
local Selftest = dofile(DEVTOOLS .. 'selftest.lua')
local Seed = dofile(DEVTOOLS .. 'seed.lua')
local FakeUnits = dofile(DEVTOOLS .. 'fakeunits.lua')

local FIXTURES = 'packages/types/test/fixtures/'

local tests = {}

local function fixtures()
    return {
        grants = helper.readJson(FIXTURES .. 'grants.fixtures.json'),
        canView = helper.readJson(FIXTURES .. 'canView.fixtures.json'),
        format = helper.readJson(FIXTURES .. 'format.fixtures.json'),
    }
end

local MODS = { Grants = Grants, CanView = CanView, Format = Format, Regex = Regex }

tests['selftest: UTC time suite (pure checks, and the oxmysql probe when given)'] = function(t)
    local now = os.time()
    local mods = { Grants = Grants, CanView = CanView, Format = Format, Regex = Regex, Time = Time }
    local good = Selftest.run(fixtures(), mods, { tz = '+02:00', utc = Time.nowIso(now) })
    t.eq(#good.suites, 4)
    t.eq(good.suites[4].name, 'time')
    t.eq(good.suites[4].failures, {})
    t.eq(good.suites[4].total, 4)
    t.eq(Selftest.run(fixtures(), mods).suites[4].total, 3, 'no probe outside FiveM')

    local epoch = Selftest.time(Time, { tz = 'SYSTEM', utc = 1790683200000 }, now)
    t.ok(epoch.failures[1]:find('expected an ISO string from isoSelect, got number', 1, true), epoch.failures[1])
    local skewed = Selftest.time(Time, { tz = 'SYSTEM', utc = Time.nowIso(now - 7200) }, now)
    t.ok(skewed.failures[1]:find('7200 s off the FXServer UTC clock', 1, true), skewed.failures[1])
end

tests['selftest: every shared fixture passes in the in-game runner'] = function(t)
    local result = Selftest.run(fixtures(), MODS)
    local failures = {}
    for _, s in ipairs(result.suites) do
        for _, f in ipairs(s.failures) do failures[#failures + 1] = s.name .. ': ' .. f end
    end
    t.eq(failures, {})
    t.eq(result.failed, 0)
    t.ok(result.suites[1].total >= 20, 'grants cases: ' .. result.suites[1].total)
    t.ok(result.suites[2].total >= 20, 'canView cases: ' .. result.suites[2].total)
    t.ok(result.suites[3].total >= 15, 'format cases: ' .. result.suites[3].total)
    print(('    selftest: grants %d/%d, canView %d/%d, format %d/%d'):format(
        result.suites[1].passed, result.suites[1].total, result.suites[2].passed, result.suites[2].total,
        result.suites[3].passed, result.suites[3].total))
end

tests['selftest reports failures instead of raising'] = function(t)
    local f = fixtures()
    f.grants.cases[1].expected = { grants = { 'nope:x' } }
    f.canView.cases[1].expected = 'full'
    f.format.cases[1].expected = 'WRONG'
    local broken = { Grants = Grants, CanView = CanView, Format = { formatId = function() error('boom') end,
        templateToRegex = Format.templateToRegex, detectSearchType = Format.detectSearchType,
        formatDate = Format.formatDate, formatTime = Format.formatTime, formatCurrency = Format.formatCurrency } }
    local result = Selftest.run(f, broken)
    t.ok(result.failed >= 3, 'failed ' .. result.failed)
    t.eq(result.total, result.passed + result.failed)
    t.ok(result.suites[1].failures[1]:find('expected', 1, true), result.suites[1].failures[1])
end

tests['selftest strips JSON-null sentinels like FiveM json may produce'] = function(t)
    local sentinel = io.stdout -- any userdata
    local stripped = Selftest.stripNulls({ a = 1, b = sentinel, c = { d = sentinel, e = { 1, 2 } } })
    t.eq(stripped, { a = 1, c = { e = { 1, 2 } } })
end

tests['seed: DEV citizenids, valid rows for the mirror, plates in the configured format'] = function(t)
    math.randomseed(42)
    local persons, vehicles = Seed.generate(200, 17)
    t.eq(#persons, 200)
    t.eq(persons[1].citizenid, 'DEV00017')
    t.eq(persons[200].citizenid, 'DEV00216')
    local formats = helper.readJson('config/formats.json')
    local plateRe = Regex.compile(formats.plate)
    local ids = {}
    for _, p in ipairs(persons) do
        t.ok(not ids[p.citizenid], 'unique ' .. p.citizenid)
        ids[p.citizenid] = true
        local row = Mirror.personRow(p.citizenid, p)
        t.ok(row.birthdate ~= nil, 'birthdate ' .. tostring(p.birthdate))
        t.ok(row.personnummer ~= nil)
        t.ok(row.firstname ~= '' and row.lastname ~= '')
        t.ok(#p.phone == 10, p.phone)
    end
    t.ok(#vehicles > 100 and #vehicles < 300, 'vehicles ' .. #vehicles)
    for _, v in ipairs(vehicles) do
        t.ok(plateRe:test(v.plate), 'plate ' .. v.plate)
        t.ok(not v.plate:find('[IQV]', 1), 'no I/Q/V in ' .. v.plate)
        t.ok(ids[v.citizenid], 'owner exists')
    end
end

tests['seed with an injected random source is deterministic'] = function(t)
    local function rng()
        local state = 1
        return function(a, b)
            state = (state * 1103515245 + 12345) % 2147483648
            return a + state % (b - a + 1)
        end
    end
    local p1, v1 = Seed.generate(5, 1, rng())
    local p2, v2 = Seed.generate(5, 1, rng())
    t.eq(p1, p2)
    t.eq(v1, v2)
end

--- A fake scheduler: setTimeout queues, advance() runs due callbacks in time order.
local function scheduler()
    local s = { now = 0, queue = {}, emits = {}, alerts = {}, ended = nil }
    function s.setTimeout(ms, fn) s.queue[#s.queue + 1] = { at = s.now + ms, fn = fn } end
    function s.advance(ms)
        local target = s.now + ms
        for _ = 1, 10000 do -- bounded test loop
            table.sort(s.queue, function(a, b) return a.at < b.at end)
            local nextJob = s.queue[1]
            if not nextJob or nextJob.at > target then break end
            table.remove(s.queue, 1)
            s.now = nextJob.at
            nextJob.fn()
        end
        s.now = target
    end
    s.deps = {
        setTimeout = s.setTimeout,
        now = function() return s.now end,
        units = helper.readJson('config/units.json').units,
        emit = function(units) s.emits[#s.emits + 1] = units and #units or 'ended' end,
        alert = function(unit, tick) s.alerts[#s.alerts + 1] = { unit.callsign, tick } end,
        onEnd = function(reason, ticks) s.ended = { reason, ticks } end,
    }
    return s
end

tests['fakeunits: ticks every 5 s and stops by itself at the deadline'] = function(t)
    local s = scheduler()
    local _, n, seconds = FakeUnits.start(20, 30, s.deps)
    t.eq(n, 20)
    t.eq(seconds, 30)
    t.eq(FakeUnits.running(), true)
    s.advance(60000)
    t.eq(FakeUnits.running(), false)
    t.eq(#s.alerts, 5, 'ticks at 5..25 s; the 30 s tick sees the deadline')
    t.eq(s.ended, { 'deadline', 5 })
    t.eq(#s.queue, 0, 'no timeout left behind')
    t.eq(s.emits[#s.emits], 'ended')
    t.ok(s.alerts[1][1]:match('^LED%-9%d$'), s.alerts[1][1])
end

tests['fakeunits: stop() ends the chain; restarting replaces the old run'] = function(t)
    local s = scheduler()
    FakeUnits.start(3, 600, s.deps)
    s.advance(10000)
    t.eq(#s.alerts, 2)
    t.eq(FakeUnits.stop('stopped'), true)
    t.eq(s.ended[1], 'stopped')
    s.advance(60000)
    t.eq(#s.alerts, 2, 'no ticks after stop')
    t.eq(FakeUnits.stop(), false)

    local s2 = scheduler()
    FakeUnits.start(2, 600, s2.deps)
    local s3 = scheduler()
    FakeUnits.start(2, 600, s3.deps)
    t.eq(s2.ended[1], 'replaced')
    s2.advance(20000)
    t.eq(#s2.alerts, 0, 'the replaced chain does nothing')
    FakeUnits.stop()
end

tests['fakeunits clamps count and duration'] = function(t)
    local s = scheduler()
    local _, n, seconds = FakeUnits.start(10000, 999999, s.deps)
    t.eq(n, FakeUnits.MAX_UNITS)
    t.eq(seconds, FakeUnits.MAX_SECONDS)
    FakeUnits.stop()
    local _, n2, s2 = FakeUnits.start(0, nil, scheduler().deps)
    t.eq(n2, 1)
    t.eq(s2, 60)
    FakeUnits.stop()
end

return tests
