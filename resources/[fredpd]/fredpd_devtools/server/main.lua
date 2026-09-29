-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_devtools: development commands (IMPLEMENTATION.md §5.10). DEV ONLY: never `ensure` this resource on the
-- production server. Every command is ACE-restricted to group.admin through ox_lib (lib.addCommand `restricted`) and
-- also works from the server console. Database writes go through fredpd_core exports, which audit them.
--   /fredpd_selftest            grants + canView + format fixtures in game (fixtures/ is copied by scripts/build.mjs)
--   /fredpd_backfill            rebuild fredpd_persons / fredpd_vehicles_idx from players / player_vehicles
--   /fredpd_seed [n]            n fake persons (citizenid DEV#####) with vehicles, default 200
--   /fredpd_fakeunits [n] [s]   n fake units + a test alert every 5 s for s seconds (n = 0 stops), default 20 / 60

local L = require('@fredpd_core.shared.locale').L
local Grants = require '@fredpd_core.shared.grants'
local CanView = require '@fredpd_core.shared.canview'
local Format = require '@fredpd_core.shared.format'
local Regex = require '@fredpd_core.shared.regex'
local Selftest = require 'server.selftest'
local Seed = require 'server.seed'
local FakeUnits = require 'server.fakeunits'

local RESOURCE = GetCurrentResourceName()
local ADMIN = 'group.admin'

--- Console print for src 0, ox_lib notification (and a console line) for a player.
local function reply(src, kind, text)
    print(('[fredpd_devtools] %s'):format(text))
    if src > 0 then TriggerClientEvent('ox_lib:notify', src, { type = kind, description = text }) end
end

local function readFixture(name)
    local raw = LoadResourceFile(RESOURCE, 'fixtures/' .. name)
    if not raw then return nil end
    local ok, decoded = pcall(json.decode, raw)
    return ok and decoded or nil
end

lib.addCommand('fredpd_selftest', { help = L('dev.command.selftest'), restricted = ADMIN }, function(source)
    local src = tonumber(source) or 0
    local fixtures = {}
    for key, file in pairs({ grants = 'grants.fixtures.json', canView = 'canView.fixtures.json',
        format = 'format.fixtures.json' }) do
        fixtures[key] = readFixture(file)
        if not fixtures[key] then
            reply(src, 'error', L('dev.selftest.missingFixtures', { file = file }))
            return
        end
    end
    local result = Selftest.run(fixtures, { Grants = Grants, CanView = CanView, Format = Format, Regex = Regex })
    for _, s in ipairs(result.suites) do
        print(('[fredpd_selftest] %s: %d/%d'):format(s.name, s.passed, s.total))
        for _, failure in ipairs(s.failures) do print('[fredpd_selftest]   FAIL ' .. failure) end
    end
    reply(src, result.failed == 0 and 'success' or 'error',
        L('dev.selftest.result', { passed = result.passed, total = result.total, failed = result.failed }))
end)

lib.addCommand('fredpd_backfill', { help = L('dev.command.backfill'), restricted = ADMIN }, function(source)
    local src = tonumber(source) or 0
    reply(src, 'inform', L('dev.backfill.started'))
    CreateThread(function() -- one-shot; the export awaits the database
        local ok, result = pcall(function() return exports.fredpd_core:backfillMirror(src) end)
        if ok and type(result) == 'table' then
            reply(src, 'success', L('dev.backfill.done', { persons = result.persons, vehicles = result.vehicles }))
        else
            print(('[fredpd_devtools] backfill failed: %s'):format(tostring(result)))
            reply(src, 'error', L('dev.backfill.failed'))
        end
    end)
end)

lib.addCommand('fredpd_seed', {
    help = L('dev.command.seed'),
    params = { { name = 'count', type = 'number', help = L('dev.param.count'), optional = true } },
    restricted = ADMIN,
}, function(source, args)
    local src = tonumber(source) or 0
    local n = math.max(1, math.min(5000, math.tointeger(tonumber(args.count)) or 200))
    CreateThread(function() -- one-shot
        local ok, result = pcall(function()
            local last = MySQL.scalar.await("SELECT COALESCE(MAX(CAST(SUBSTRING(citizenid, 4) AS UNSIGNED)), 0) "
                .. "FROM fredpd_persons WHERE citizenid LIKE 'DEV%'")
            local persons, vehicles = Seed.generate(n, (tonumber(last) or 0) + 1)
            return exports.fredpd_core:seedDevRows(src, persons, vehicles)
        end)
        if ok and type(result) == 'table' then
            reply(src, 'success', L('dev.seed.done', { persons = result.persons, vehicles = result.vehicles }))
        else
            print(('[fredpd_devtools] seed failed: %s'):format(tostring(result)))
            reply(src, 'error', L('dev.seed.failed'))
        end
    end)
end)

--- config/units.json of fredpd_core (for fake callsigns).
local function unitConfig()
    local raw = LoadResourceFile('fredpd_core', 'config/units.json')
    local ok, decoded = pcall(json.decode, raw or '')
    return ok and type(decoded) == 'table' and decoded.units or nil
end

lib.addCommand('fredpd_fakeunits', {
    help = L('dev.command.fakeunits'),
    params = {
        { name = 'count', type = 'number', help = L('dev.param.count'), optional = true },
        { name = 'seconds', type = 'number', help = L('dev.param.seconds'), optional = true },
    },
    restricted = ADMIN,
}, function(source, args)
    local src = tonumber(source) or 0
    local n = math.tointeger(tonumber(args.count)) or 20
    if n <= 0 then
        if not FakeUnits.stop('stopped') then reply(src, 'inform', L('dev.fakeunits.stopped')) end
        return
    end
    local _, used, seconds = FakeUnits.start(n, math.tointeger(tonumber(args.seconds)) or 60, {
        setTimeout = SetTimeout,
        now = GetGameTimer,
        units = unitConfig(),
        -- Listeners (fredpd_dispatch roster, load tests) get a snapshot per tick and nil when the run ends.
        emit = function(units) TriggerEvent('fredpd:devtools:fakeUnits', units) end,
        -- UNVERIFIED: fredpd_dispatch:createAlert's data shape is defined by task 3.1; skipped when not started.
        alert = function(unit)
            if GetResourceState('fredpd_dispatch') ~= 'started' then return end
            pcall(function()
                exports.fredpd_dispatch:createAlert({
                    code = 'dev', source = RESOURCE, message = L('dev.fakeunits.alert', { callsign = unit.callsign }),
                    coords = vector3(unit.coords.x, unit.coords.y, unit.coords.z),
                })
            end)
        end,
        onEnd = function() reply(src, 'inform', L('dev.fakeunits.stopped')) end,
    })
    reply(src, 'inform', L('dev.fakeunits.started', { count = used, seconds = seconds }))
end)

AddEventHandler('onResourceStop', function(name)
    if name == RESOURCE then FakeUnits.stop('stopped') end
end)
