-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_core/server/mirror.lua pure mapping: charinfo -> fredpd_persons row, personnummer derivation, plates.
-- The database paths (backfill, refreshPlate, dev seeding) are in core_db_test.lua.
-- Run: lua5.4 tests/lua/run.lua core_mirror_test
local Mirror = require('server.mirror')
local Format = require('shared.format')
local helper = require('helper')

local tests = {}

tests['personRow from qbx charinfo (table and JSON text)'] = function(t)
    local charinfo = { firstname = ' Anna ', lastname = 'Berg', birthdate = '1994-03-12', gender = 1, phone = '0701234567' }
    local row = Mirror.personRow('FPD10001', charinfo, { license = 'license:abc' })
    t.eq(row.citizenid, 'FPD10001')
    t.eq(row.firstname, 'Anna')
    t.eq(row.lastname, 'Berg')
    t.eq(row.birthdate, '1994-03-12')
    t.eq(row.gender, 1)
    t.eq(row.phone, '0701234567')
    t.eq(row.license, 'license:abc')
    t.ok(row.personnummer:match('^19940312%-%d%d%d%d$'), row.personnummer)
    t.eq(Mirror.personRow('FPD10001', json.encode(charinfo), { license = 'license:abc' }), row, 'JSON text')
end

tests['personRow tolerates missing or broken charinfo'] = function(t)
    local row = Mirror.personRow('X1', '{broken', {})
    t.eq(row, { citizenid = 'X1', firstname = '', lastname = '' })
    t.eq(Mirror.personRow('X2', nil, { phone = 12345 }).phone, '12345', 'players.phone_number fallback')
    t.eq(Mirror.personRow('', {}), nil)
    t.eq(Mirror.personRow(nil, {}), nil)
    t.eq(Mirror.personRow(('x'):rep(51), {}), nil)
end

tests['clean trims and cuts on UTF-8 boundaries'] = function(t)
    t.eq(Mirror.clean('  Åsa  ', 64), 'Åsa')
    t.eq(Mirror.clean('Åäöåäö', 3), 'Åäö')
    t.eq(Mirror.clean('   ', 10), nil)
    t.eq(Mirror.clean('bad\255byte', 64), 'bad?byte')
    t.eq(Mirror.clean(7, 10), '7')
    t.eq(Mirror.clean({}, 10), nil)
end

tests['parseBirthdate formats'] = function(t)
    t.eq(Mirror.parseBirthdate('1994-03-12'), '1994-03-12')
    t.eq(Mirror.parseBirthdate('1994-3-2'), '1994-03-02')
    t.eq(Mirror.parseBirthdate('1994-03-12T00:00:00Z'), '1994-03-12')
    t.eq(Mirror.parseBirthdate('1994/03/12'), '1994-03-12')
    t.eq(Mirror.parseBirthdate('12/03/1994'), '1994-03-12')
    t.eq(Mirror.parseBirthdate('12.03.1994'), '1994-03-12')
    t.eq(Mirror.parseBirthdate('2000-02-29'), '2000-02-29')
    t.eq(Mirror.parseBirthdate('1900-02-29'), nil, 'not a leap year')
    t.eq(Mirror.parseBirthdate('1994-13-01'), nil)
    t.eq(Mirror.parseBirthdate('1994-04-31'), nil)
    t.eq(Mirror.parseBirthdate('yesterday'), nil)
    t.eq(Mirror.parseBirthdate(19940312), nil)
end

tests['parseGender'] = function(t)
    t.eq(Mirror.parseGender(0), 0)
    t.eq(Mirror.parseGender('1'), 1)
    t.eq(Mirror.parseGender(1.0), 1)
    t.eq(Mirror.parseGender('Male'), 0)
    t.eq(Mirror.parseGender('kvinna'), 1)
    t.eq(Mirror.parseGender(2), nil)
    t.eq(Mirror.parseGender(nil), nil)
end

tests['luhn control digit (known Swedish test numbers)'] = function(t)
    -- 811218-9876 and 640823-3234 are standard valid examples.
    t.eq(Mirror.luhn('811218987'), 6)
    t.eq(Mirror.luhn('640823323'), 4)
end

tests['derived personnummer: stable, valid, gender parity, searchable'] = function(t)
    local a = Mirror.personnummer('FPD10001', '1994-03-12', 1)
    t.eq(Mirror.personnummer('FPD10001', '1994-03-12', 1), a, 'stable')
    t.ok(a:match('^19940312%-%d%d%d%d$'), a)
    local digits = a:gsub('%D', '')
    t.eq(tonumber(digits:sub(-1)), Mirror.luhn(digits:sub(3, 11)), 'control digit')
    t.eq(tonumber(digits:sub(11, 11)) % 2, 0, 'even third digit for women')
    for i = 1, 50 do
        local m = Mirror.personnummer('CID' .. i, '1980-01-01', 0)
        t.eq(tonumber(m:sub(-2, -2)) % 2, 1, 'odd third digit for men: ' .. m)
    end
    -- The stored value is what detectSearchType makes of a typed personnummer.
    local formats = helper.readJson('config/formats.json')
    t.eq(Format.detectSearchType(digits, formats), { type = 'personId', normalized = a })
    t.eq(Mirror.personnummer('X', nil, 0), nil, 'no birthdate, no number')
end

tests['explicit charinfo.personnummer wins when it is 10 or 12 digits'] = function(t)
    t.eq(Mirror.personnummer('X', '1994-03-12', 1, '19940312-1234'), '19940312-1234')
    t.eq(Mirror.personnummer('X', '1994-03-12', 1, '9403121234'), '940312-1234')
    t.ok(Mirror.personnummer('X', '1994-03-12', 1, '12-34') ~= '12-34', 'garbage is ignored')
end

tests['plates are normalised like detectSearchType'] = function(t)
    t.eq(Mirror.normalizePlate(' abc 12d '), 'ABC12D')
    t.eq(Mirror.normalizePlate('ABC\t12D'), 'ABC12D')
    t.eq(Mirror.normalizePlate(''), nil)
    t.eq(Mirror.normalizePlate(('A'):rep(17)), nil)
    local formats = helper.readJson('config/formats.json')
    t.eq(Format.detectSearchType('abc 12d', formats).normalized, Mirror.normalizePlate('abc 12d'))
    local n, list = Mirror.plateCandidates('abc12d')
    t.eq(n, 'ABC12D')
    t.eq(list, { 'ABC12D', 'ABC 12D' })
    local _, gta = Mirror.plateCandidates('46EEK572')
    t.eq(gta, { '46EEK572' })
end

tests['vehicleRow'] = function(t)
    t.eq(Mirror.vehicleRow('ABC 12D', 'FPD1', 'sultan'), { plate = 'ABC12D', citizenid = 'FPD1', model = 'sultan' })
    t.eq(Mirror.vehicleRow('ABC 12D', '', nil), { plate = 'ABC12D' })
    t.eq(Mirror.vehicleRow(nil, 'x', 'y'), nil)
end

tests['fingerprint changes only with mirrored fields'] = function(t)
    local a = Mirror.personRow('F1', { firstname = 'A', lastname = 'B', birthdate = '1990-01-01', gender = 0 }, {})
    local b = Mirror.personRow('F1', { firstname = 'A', lastname = 'B', birthdate = '1990-01-01', gender = 0, cash = 5 }, {})
    t.eq(Mirror.fingerprint(a), Mirror.fingerprint(b))
    local c = Mirror.personRow('F1', { firstname = 'A', lastname = 'C', birthdate = '1990-01-01', gender = 0 }, {})
    t.ok(Mirror.fingerprint(a) ~= Mirror.fingerprint(c))
end

tests['SetPlayerData handler: fingerprint checked synchronously, a thread only for a real change'] = function(t)
    local Core = require('server.core')
    local handlers, started = {}, {}
    local saved = { add = rawget(_G, 'AddEventHandler'), exports = rawget(_G, 'exports'), mysql = rawget(_G, 'MySQL'),
        async = Core.async }
    rawset(_G, 'AddEventHandler', function(name, fn) handlers[name] = fn end)
    rawset(_G, 'exports', function() end)
    rawset(_G, 'MySQL', setmetatable({}, { __index = function() error('no DB access in the event handler', 0) end }))
    Core.async = function(label, fn, ...) started[#started + 1] = { label = label, fn = fn, args = { ... } } end
    local ok, err = pcall(function()
        Mirror.register()
        local fire = handlers['QBCore:Player:SetPlayerData']
        t.ok(fire ~= nil, 'handler registered')
        local charinfo = { firstname = 'Sam', lastname = 'Ek', birthdate = '1990-01-01', gender = 0 }
        fire({ citizenid = 'SPD1', charinfo = charinfo, money = { cash = 1 } })
        t.eq(#started, 1, 'first sight of the character is written')
        for cash = 2, 20 do fire({ citizenid = 'SPD1', charinfo = charinfo, money = { cash = cash } }) end
        t.eq(#started, 1, 'money ticks start no thread')
        fire({ citizenid = 'SPD1', charinfo = { firstname = 'Sam', lastname = 'Berg', birthdate = '1990-01-01' } })
        fire({ citizenid = 'SPD1', charinfo = { firstname = 'Sam', lastname = 'Berg', birthdate = '1990-01-01' } })
        t.eq(#started, 2, 'one write per real change')
        t.eq(started[2].fn, Mirror.writeClaimed)
        t.eq(started[2].args[1].lastname, 'Berg')
        fire(nil)
        fire({ charinfo = charinfo })
        t.eq(#started, 2)
    end)
    rawset(_G, 'AddEventHandler', saved.add)
    rawset(_G, 'exports', saved.exports)
    rawset(_G, 'MySQL', saved.mysql)
    Core.async = saved.async
    if not ok then error(err, 0) end
end

tests['writeClaimed failure forgets the fingerprint so the next event retries'] = function(t)
    local saved = Mirror.upsertPersons
    local calls = 0
    Mirror.upsertPersons = function() calls = calls + 1; error('db down', 0) end
    local Core = require('server.core')
    local savedErr = Core.error
    Core.error = function() end
    local ok, err = pcall(function()
        local pd = { citizenid = 'WCF1', charinfo = { firstname = 'A', lastname = 'B' } }
        local row = Mirror.claimRow(pd)
        t.ok(row ~= nil)
        t.eq(Mirror.claimRow(pd), nil, 'claimed')
        t.eq(Mirror.writeClaimed(row), false)
        t.ok(Mirror.claimRow(pd) ~= nil, 'claimable again after the failure')
    end)
    Mirror.upsertPersons, Core.error = saved, savedErr
    if not ok then error(err, 0) end
    t.eq(calls, 1)
end

return tests
