-- SPDX-License-Identifier: GPL-3.0-only
-- Tests for fredpd_core/shared/time.lua (docs/contracts.md §C7, §C12): the DATE_FORMAT select fragment, DATETIME
-- text <-> ISO-8601 UTC, and nowIso. The fragment is also run against MariaDB (session +02:00) when it is reachable.
-- Run alone: lua5.4 tests/lua/run.lua time_test
local Time = require('shared.time')
local shim = require('mysql_shim')

local tests = {}

local function expectError(fn, needle)
    local ok, err = pcall(fn)
    if ok then error('expected an error containing ' .. needle, 2) end
    if not tostring(err):find(needle, 1, true) then
        error(('expected error containing %q, got %q'):format(needle, tostring(err)), 2)
    end
end

tests['isoSelect builds the DATE_FORMAT fragment'] = function(t)
    t.eq(Time.isoSelect('created_at'), "DATE_FORMAT(created_at, '%Y-%m-%dT%H:%i:%sZ') AS created_at")
    t.eq(Time.isoSelect('b.created_at'), "DATE_FORMAT(b.created_at, '%Y-%m-%dT%H:%i:%sZ') AS created_at",
        'alias defaults to the column without its table prefix')
    t.eq(Time.isoSelect('b.resolved_at', 'resolvedAt'), "DATE_FORMAT(b.resolved_at, '%Y-%m-%dT%H:%i:%sZ') AS resolvedAt")
    t.eq(Time.isoSelect('_x9', 'y'), "DATE_FORMAT(_x9, '%Y-%m-%dT%H:%i:%sZ') AS y")
    t.ok(not Time.isoSelect('created_at'):find('?', 1, true), 'no ? (oxmysql would bind it)')
end

tests['isoSelect rejects anything that is not an identifier'] = function(t)
    for _, bad in ipairs({ 'created_at; DROP TABLE x', 'Created_at', '1col', 'a.b.c', 'a.', '.a', 'a..b', 'a b',
        "a'", 'NOW()', '', ('a'):rep(129) }) do
        expectError(function() Time.isoSelect(bad) end, 'isoSelect: invalid column')
    end
    expectError(function() Time.isoSelect(nil) end, 'isoSelect: invalid column')
    expectError(function() Time.isoSelect(42) end, 'isoSelect: invalid column')
    for _, bad in ipairs({ 'a.b', 'x y', 'x;--', '9a', '', ('a'):rep(65) }) do
        expectError(function() Time.isoSelect('created_at', bad) end, 'isoSelect: invalid alias')
    end
    expectError(function() Time.isoSelect('created_at', 7) end, 'isoSelect: invalid alias')
    t.ok(true)
end

tests['toIsoUtc normalises DATETIME text and ISO strings'] = function(t)
    t.eq(Time.toIsoUtc(nil), nil)
    t.eq(Time.toIsoUtc('2026-09-29 12:00:00'), '2026-09-29T12:00:00Z')
    t.eq(Time.toIsoUtc('2026-09-29T12:00:00Z'), '2026-09-29T12:00:00Z', 'already ISO')
    t.eq(Time.toIsoUtc('2026-09-29T12:00:00'), '2026-09-29T12:00:00Z', 'no zone = UTC')
    t.eq(Time.toIsoUtc('2026-09-29T12:00:00.123Z'), '2026-09-29T12:00:00.123Z', 'fraction kept')
    t.eq(Time.toIsoUtc('2026-09-29 12:00:00.500000'), '2026-09-29T12:00:00.500000Z')
    t.eq(Time.toIsoUtc('2026-09-29T12:00:00+02:00'), '2026-09-29T10:00:00Z', 'offset converted')
    t.eq(Time.toIsoUtc('2026-03-01T00:30:00+0100'), '2026-02-28T23:30:00Z', 'across a month end')
    t.eq(Time.toIsoUtc('2024-03-01T00:30:00+01:00'), '2024-02-29T23:30:00Z', 'leap day')
    t.eq(Time.toIsoUtc('2026-12-31T23:30:00-01:00'), '2027-01-01T00:30:00Z', 'across a year end')
    t.eq(Time.toIsoUtc('0000-00-00 00:00:00'), nil, 'MariaDB zero date has no instant')
end

tests['toIsoUtc rejects numbers and garbage with an explanation'] = function(t)
    expectError(function() Time.toIsoUtc(1790683200000) end, 'epoch milliseconds')
    expectError(function() Time.toIsoUtc(1790683200000) end, "Time.isoSelect('<col>')")
    expectError(function() Time.toIsoUtc(true) end, 'expected a string or nil, got boolean')
    expectError(function() Time.toIsoUtc({}) end, 'expected a string or nil, got table')
    expectError(function() Time.toIsoUtc('2026-09-29') end, 'not a YYYY-MM-DD HH:MM:SS timestamp')
    expectError(function() Time.toIsoUtc('29/09/2026 12:00') end, 'not a YYYY-MM-DD HH:MM:SS timestamp')
    expectError(function() Time.toIsoUtc('2026-02-29 12:00:00') end, 'out of range')
    expectError(function() Time.toIsoUtc('2026-09-29 24:00:00') end, 'out of range')
    expectError(function() Time.toIsoUtc('2026-09-29T12:00:00 CEST') end, 'unknown time zone suffix')
    expectError(function() Time.toIsoUtc('2026-09-29T12:00:00+25:00') end, 'bad UTC offset')
    t.ok(true)
end

tests['toDatetime gives the UTC DATETIME text and never raises'] = function(t)
    t.eq(Time.toDatetime('2026-09-29T12:00:00.000Z'), '2026-09-29 12:00:00')
    t.eq(Time.toDatetime('2026-09-29T12:00:00+02:00'), '2026-09-29 10:00:00')
    t.eq(Time.toDatetime('2026-09-29 12:00:00'), '2026-09-29 12:00:00')
    for _, bad in ipairs({ 'not iso', '2026-13-01T00:00:00Z', '0000-00-00 00:00:00', '' }) do
        local v, why = Time.toDatetime(bad)
        t.eq(v, nil, bad)
        t.ok(type(why) == 'string', 'reason for ' .. bad)
    end
    t.eq(Time.toDatetime(nil), nil)
    t.eq(Time.toDatetime(1790683200), nil)
end

tests['toEpoch gives UTC unix seconds'] = function(t)
    t.eq(Time.toEpoch('2026-09-29T12:00:00Z'), 1790683200)
    t.eq(Time.toEpoch('2026-09-29 12:00:00'), 1790683200)
    t.eq(Time.toEpoch('2026-09-29T14:00:00.9+02:00'), 1790683200)
    t.eq(Time.toEpoch('1970-01-01T00:00:00Z'), 0)
    t.eq(Time.toEpoch('1969-12-31T23:59:59Z'), -1)
    t.eq(Time.toEpoch('2000-02-29T00:00:00Z'), 951782400)
    t.eq(Time.toEpoch('0000-00-00 00:00:00'), nil)
    t.eq(Time.toEpoch('yesterday'), nil)
    t.eq(Time.toEpoch(1790683200), nil)
    t.eq(Time.toEpoch(Time.nowIso(1790683200)), 1790683200)
end

tests['toEpochMs keeps milliseconds for ordering within a second'] = function(t)
    t.eq(Time.toEpochMs('2026-09-29T12:00:00Z'), 1790683200000)
    t.eq(Time.toEpochMs('2026-09-29T12:00:00.123Z'), 1790683200123)
    t.eq(Time.toEpochMs('2026-09-29T12:00:00.5Z'), 1790683200500)
    t.eq(Time.toEpochMs('2026-09-29T12:00:00.123456Z'), 1790683200123, 'fraction cut to ms')
    t.eq(Time.toEpochMs('2026-09-29T14:00:00.250+02:00'), 1790683200250)
    t.ok(Time.toEpochMs('2026-09-29T12:00:00.100Z') < Time.toEpochMs('2026-09-29T12:00:00.900Z'))
    t.eq(Time.toEpochMs('garbage'), nil)
    t.eq(Time.toEpochMs(42), nil)
end

tests['nowIso formats in UTC'] = function(t)
    t.eq(Time.nowIso(1790683200), '2026-09-29T12:00:00Z')
    t.eq(Time.nowIso(0), '1970-01-01T00:00:00Z')
    local now = Time.nowIso()
    t.ok(now:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$'), now)
    t.eq(Time.toIsoUtc(now), now)
end

tests['round trip through MariaDB with a +02:00 session'] = function(t)
    local ok = shim.available()
    if not ok then
        print('SKIP time_test database test: MariaDB unreachable')
        return
    end
    local saved = shim.sessionTimeZone
    shim.sessionTimeZone = '+02:00'
    local okRun, err = pcall(function()
        local okq, out, stderr = shim.run(
            "SELECT @@session.time_zone AS tz, " .. Time.isoSelect('x.v', 'v') .. ", "
            .. Time.isoSelect('x.n', 'n') .. ', ' .. Time.isoSelect('x.u', 'u') .. ' FROM (SELECT '
            .. "CAST('2026-09-29 12:00:00' AS DATETIME) AS v, CAST(NULL AS DATETIME) AS n, UTC_TIMESTAMP() AS u) x")
        t.ok(okq, stderr)
        local row = shim.parseXml(out)[1].rows[1]
        t.eq(row.tz, '+02:00')
        t.eq(row.v, '2026-09-29T12:00:00Z', 'DATETIME text is read as stored, whatever the session zone')
        t.eq(row.n, nil, 'NULL stays NULL')
        local lag = os.time() - Time.toEpoch(row.u)
        t.ok(math.abs(lag) <= 60, ('UTC_TIMESTAMP() read back as ISO is the current UTC time (off by %d s)'):format(lag))
    end)
    shim.sessionTimeZone = saved
    if not okRun then error(err, 0) end
end

return tests
