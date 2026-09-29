-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_core/server/core.lua pure helpers: rate limits, SQL binding, config parsing, identifiers.
-- Run: lua5.4 tests/lua/run.lua core_helpers_test
local Core = require('server.core')

local tests = {}

tests['rateLimit allows once per window per player and action'] = function(t)
    local src = 'rl-1'
    t.eq(Core.rateLimit(src, 'lookup', 1000, 10000), true)
    t.eq(Core.rateLimit(src, 'lookup', 1000, 10500), false)
    t.eq(Core.rateLimit(src, 'lookup', 1000, 10999), false)
    t.eq(Core.rateLimit(src, 'lookup', 1000, 11000), true, 'window measured from the last allowed call')
    t.eq(Core.rateLimit(src, 'other', 1000, 11001), true, 'actions are independent')
    t.eq(Core.rateLimit('rl-2', 'lookup', 1000, 11001), true, 'players are independent')
end

tests['a refused call does not extend the window'] = function(t)
    local src = 'rl-3'
    t.eq(Core.rateLimit(src, 'a', 100, 0), true)
    t.eq(Core.rateLimit(src, 'a', 100, 99), false)
    t.eq(Core.rateLimit(src, 'a', 100, 100), true)
end

tests['clearRateLimits forgets a player'] = function(t)
    t.eq(Core.rateLimit(7, 'x', 5000, 1), true)
    t.eq(Core.rateLimit(7, 'x', 5000, 2), false)
    Core.clearRateLimits(7)
    t.eq(Core.rateLimit(7, 'x', 5000, 3), true)
end

tests['now() uses GetGameTimer when present'] = function(t)
    local saved = rawget(_G, 'GetGameTimer')
    rawset(_G, 'GetGameTimer', function() return 424242 end)
    local v = Core.now()
    rawset(_G, 'GetGameTimer', saved)
    t.eq(v, 424242)
    t.ok(math.type(Core.now()) == 'integer')
end

tests['bindRow turns nil into NULL and compacts the params'] = function(t)
    local marks, params = Core.bindRow({ 'a', nil, 3, nil }, 4)
    t.eq(marks, '?, NULL, ?, NULL')
    t.eq(params, { 'a', 3 })
    marks, params = Core.bindRow({}, 2)
    t.eq(marks, 'NULL, NULL')
    t.eq(params, {})
    local shared = { 'x' }
    Core.bindRow({ false, 0 }, 2, shared)
    t.eq(shared, { 'x', false, 0 }, 'false and 0 are values, not NULL')
end

tests['buildInsert: multi-row upsert with NULLs'] = function(t)
    local sql, params = Core.buildInsert('t', { 'id', 'a', 'b' }, {
        { id = 1, a = 'x' },
        { id = 2, b = 'y' },
    }, { 'a', 'b' })
    t.eq(sql, 'INSERT INTO t (id, a, b) VALUES (?, ?, NULL), (?, NULL, ?) ON DUPLICATE KEY UPDATE a = VALUES(a), b = VALUES(b)')
    t.eq(params, { 1, 'x', 2, 'y' })
end

tests['buildInsert: INSERT IGNORE without update columns'] = function(t)
    local sql, params = Core.buildInsert('t', { 'id' }, { { id = 'DEV1' } })
    t.eq(sql, 'INSERT IGNORE INTO t (id) VALUES (?)')
    t.eq(params, { 'DEV1' })
end

tests['discordIdFromIdentifier'] = function(t)
    t.eq(Core.discordIdFromIdentifier('discord:123456789012345678'), '123456789012345678')
    t.eq(Core.discordIdFromIdentifier('discord:'), nil)
    t.eq(Core.discordIdFromIdentifier('license:abc'), nil)
    t.eq(Core.discordIdFromIdentifier('discord:12a'), nil)
    t.eq(Core.discordIdFromIdentifier('discord:' .. ('1'):rep(21)), nil)
    t.eq(Core.discordIdFromIdentifier(nil), nil)
end

tests['unitIndex keeps config order and ignores bad entries'] = function(t)
    local byCode, order = Core.unitIndex({ units = {
        { code = 'ledning', callsign = 'LED' }, { callsign = 'X' }, { code = 'igv', callsign = 'IGV' },
        { code = 'igv', callsign = 'DUP' },
    } })
    t.eq(order, { 'ledning', 'igv' })
    t.eq(byCode.igv.callsign, 'IGV')
    local b2, o2 = Core.unitIndex(nil)
    t.eq(b2, {})
    t.eq(o2, {})
end

tests['unitIndex of the real config/units.json'] = function(t)
    local helper = require('helper')
    local byCode, order = Core.unitIndex(helper.readJson('config/units.json'))
    t.eq(order, { 'ledning', 'span', 'utredning', 'tekniker', 'igv' })
    t.eq(byCode.igv.callsign, 'IGV')
end

tests['readJsonFile: missing, invalid, valid'] = function(t)
    local files = { ['config/a.json'] = '{"x":1}', ['config/bad.json'] = '{nope' }
    local loader = function(resource, path)
        t.eq(resource, 'fredpd_core')
        return files[path]
    end
    local v = Core.readJsonFile('config/a.json', loader)
    t.eq(v, { x = 1 })
    local none, err = Core.readJsonFile('config/missing.json', loader)
    t.eq(none, nil)
    t.ok(err:find('missing'), err)
    local bad, err2 = Core.readJsonFile('config/bad.json', loader)
    t.eq(bad, nil)
    t.ok(err2:find('not valid JSON'), err2)
end

tests['decode tolerates empty and invalid text'] = function(t)
    t.eq(Core.decode('{"a":[1]}'), { a = { 1 } })
    t.eq(Core.decode(''), nil)
    t.eq(Core.decode(nil), nil)
    t.eq(Core.decode('not json'), nil)
end

tests['fetch resolves through the signedFetch export and decodes JSON'] = function(t)
    local saved = { exports = rawget(_G, 'exports'), promise = rawget(_G, 'promise'), Citizen = rawget(_G, 'Citizen'),
        GetCurrentResourceName = rawget(_G, 'GetCurrentResourceName') }
    local seen
    rawset(_G, 'GetCurrentResourceName', function() return 'fredpd_core' end)
    rawset(_G, 'exports', { fredpd_core = {
        signedFetch = function(_self, method, path, body, cb)
            seen = { method, path, body }
            cb(200, '{"member":true}')
        end,
    } })
    -- Minimal promise / Citizen.Await (the callback above resolves synchronously).
    rawset(_G, 'promise', { new = function()
        local p = {}
        function p:resolve(v) self.value = v end
        return p
    end })
    rawset(_G, 'Citizen', { Await = function(p) return p.value end })
    local ok, status, body = pcall(Core.fetch, 'GET', '/internal/grants/1', nil)
    for k, v in pairs(saved) do rawset(_G, k, v) end
    t.ok(ok, tostring(status))
    t.eq(status, 200)
    t.eq(body, { member = true })
    t.eq(seen, { 'GET', '/internal/grants/1', nil })
end

return tests
