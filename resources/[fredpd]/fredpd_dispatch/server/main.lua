-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_dispatch server entry (IMPLEMENTATION.md §5.5, docs/contracts.md §C13, docs/modules/dispatch.md).
-- Exports and events are registered synchronously at start; database work happens in event/callback/export
-- threads and one-shot SetTimeout callbacks (no loops).

local L = require('@fredpd_core.shared.locale').L
local Service = require 'server.alert_service'
local Roster = require 'server.unit_roster'
local Bridge = require 'server.ps_bridge'
local Fanout = require 'server.fanout'
local Input = require 'shared.alert_input'

Bridge.L = L

---------------------------------------------------------------------------------------------------------------
-- Exports (§C13). The src-taking ones return { ok, data | error } (§C12) for the fredpd_mdt dispatcher.

exports('createAlert', Service.create)
exports('listAlerts', Service.list)
exports('assignSelf', function(src, input) return Service.assignSelf(src, input, 'tablet') end)
exports('takeAlert', function(src, input) return Service.assignSelf(src, input, 'tablet') end) -- DISPATCH_ACTIONS name
exports('leaveAlert', Service.leave)
exports('closeAlert', Service.close)
exports('getUnits', Service.getUnits)
exports('takeNewest', Service.takeNewest)

---------------------------------------------------------------------------------------------------------------
-- ps-dispatch bridge (server-only event; see server/ps_bridge.lua)

AddEventHandler('fredpd:dispatch:incoming', function(data, reporter)
    Bridge.handle(source, data, reporter)
end)

---------------------------------------------------------------------------------------------------------------
-- Keybind "Ta larm": grant -> rate limit (1/s) -> duty -> take. Returns the Alert or { error, reason? }.

local keyLimiter = Input.newLimiter(1, 1000)

lib.callback.register('fredpd:dispatch:takeNewest', function(source)
    local src = tonumber(source)
    if not src or src < 1 then return { error = 'unauthorized' } end
    if exports.fredpd_core:hasGrant(src, 'mdt_page', 'alerts') ~= true then return { error = 'unauthorized' } end
    if not keyLimiter.allow(src, GetGameTimer()) then return { error = 'rate_limited' } end
    local result = Service.takeNewest(src)
    if result.ok then return result.data end
    return { error = result.error, reason = result.reason }
end)

---------------------------------------------------------------------------------------------------------------
-- Units roster: every event that can change who is on duty, their name/callsign or their alert. The framework
-- events come normalised from fredpd_core's bridge (docs/contracts.md §C17: qb-core or qbx_core), all server-local
-- (AddEventHandler; no client can fire them). Each only schedules a rebuild.

for _, name in ipairs({
    'fredpd:bridge:dutyChanged',      -- (src, onduty)   duty toggled (SetDuty / SetJobDuty)
    'fredpd:bridge:jobChanged',       -- (src)           job name/type/grade changed
    'fredpd:bridge:playerLoaded',     -- (src)           character loaded (duty restored from the saved job)
    'fredpd:bridge:playerUnloaded',   -- (src)           /logout or disconnect
    'fredpd:officerChanged',          -- (citizenid)     fredpd_core: Discord name push or new callsign
}) do
    AddEventHandler(name, function() Roster.schedule() end)
end

AddEventHandler('playerDropped', function()
    local src = source
    Bridge.forget(src)
    keyLimiter.clear(tonumber(src))
    Roster.schedule()
end)

-- fredpd_devtools /fredpd_fakeunits (dev only): fake on-duty units for load tests; nil ends the run.
AddEventHandler('fredpd:devtools:fakeUnits', function(units)
    local n = tonumber(source)
    if n and n > 0 then return end -- server-only
    Roster.setFake(units)
end)

MySQL.ready(function()
    Roster.schedule()
end)

---------------------------------------------------------------------------------------------------------------
-- Dev only: /fredpd_testalert (§5.5 acceptance helper). Registered only with `set fredpd_dev true`, ACE-restricted.
-- ps-dispatch's presets are CLIENT exports, so with ps-dispatch running the caller's client is asked to run
-- exports['ps-dispatch']:Shooting() (the full ps-dispatch -> patch -> bridge path); from the console, or without
-- ps-dispatch, a fake shooting is created directly with createAlert.

if GetConvar('fredpd_dev', 'false') == 'true' then
    -- Legion Square, for console use.
    local CONSOLE_COORDS = { x = 195.17, y = -933.77, z = 30.69 }

    lib.addCommand('fredpd_testalert', {
        help = L('dev.command.testalert'),
        restricted = 'group.admin',
    }, function(source)
        local src = tonumber(source) or 0
        if src > 0 and GetResourceState('ps-dispatch') == 'started' then
            TriggerClientEvent('fredpd:dispatch:client:testShooting', src)
            TriggerClientEvent('ox_lib:notify', src, { type = 'inform', description = L('dev.testalert.sent') })
            return
        end
        local coords = CONSOLE_COORDS
        if src > 0 then
            local c = GetEntityCoords(GetPlayerPed(tostring(src)))
            coords = { x = c.x, y = c.y, z = c.z }
        end
        CreateThread(function()
            local alert, err = Service.create({
                code = '10-11', title = L('dev.testalert.title'), coords = coords, priority = 2, source = 'devtools',
            })
            if src > 0 then
                TriggerClientEvent('ox_lib:notify', src, alert
                    and { type = 'inform', description = L('dev.testalert.sent') }
                    or { type = 'error', description = L('errors.unknown') })
            end
            Fanout.log(alert and 'info' or 'error', 'fredpd_testalert: %s', alert and ('alert #' .. alert.id)
                or tostring(err))
        end)
    end)
end
