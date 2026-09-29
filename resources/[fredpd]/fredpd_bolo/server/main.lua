-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_bolo server entry (IMPLEMENTATION.md §5.4, docs/contracts.md §C12, docs/modules/bolo.md). Exports, the
-- ox_target callback and the server events are registered synchronously at start; the active-BOLO cache is loaded
-- once oxmysql is ready and after every change (no timers, no loops).

local L = require('@fredpd_core.shared.locale').L
local Store = require 'server.store'
local Visibility = require 'server.visibility'
local Fanout = require 'server.fanout'
local Service = require 'server.service'

Store.L, Visibility.L, Fanout.L, Service.L = L, L, L, L

---------------------------------------------------------------------------------------------------------------
-- Exports. Tablet actions (§C12 convention { ok, data | error }): listBolos, createBolo, resolveBolo, plateCheck.
-- Lookups (§4.3): checkPlate(plate) -> Bolo|nil, checkPerson(citizenid) -> Bolo|nil, getBolosFor(src, kind, id)
-- -> Bolo[], hasVisibleBolo(src, kind, id) -> boolean. Impound (§5.4 item 4): resolveOnImpound(plate, src) -> boolean.

exports('listBolos', Service.listBolos)
exports('createBolo', Service.createBolo)
exports('resolveBolo', Service.resolveBolo)
exports('plateCheck', Service.plateCheck)
exports('checkPlate', Service.checkPlate)
exports('checkPerson', Service.checkPerson)
exports('getBolosFor', Service.getBolosFor)
exports('hasVisibleBolo', Service.hasVisibleBolo)
exports('resolveOnImpound', Service.resolveOnImpound)

---------------------------------------------------------------------------------------------------------------
-- ox_target "Kontrollera registreringsskylt": the client sends the vehicle's network id only; the server checks
-- grant mdt_page:search, duty, 1/s, the entity and the distance, and reads the plate from the entity itself.

lib.callback.register('fredpd:bolo:plateCheck', function(source, netId)
    return Service.targetCheck(source, netId)
end)

---------------------------------------------------------------------------------------------------------------
-- Server-only events (AddEventHandler, never RegisterNetEvent: FXServer drops a client's TriggerServerEvent of them
-- as "not safe for net"; the source check is a second guard).

local function fromServer()
    local n = tonumber(source)
    return not n or n <= 0
end

-- fredpd:boloHit(bolo, context): fired by this resource (plate checks) and by the qbx_police ANPR bridge
-- (patches/qbx_policejob.30-bolo-hooks.patch, context.source = 'radar'); later the garage bridge (task 3.4).
-- Raises the alert (fredpd_dispatch.createAlert) with the 60 s per-plate cooldown.
AddEventHandler('fredpd:boloHit', function(bolo, ctx)
    if not fromServer() then return end
    Service.onHit(bolo, ctx)
end)

-- Impound hook, event form of resolveOnImpound for resources that prefer an event over the export:
-- TriggerEvent('fredpd:bolo:vehicleImpounded', plate, officerSrc). Not used by anything yet (the qbx_police patch
-- calls the export); documented in docs/modules/bolo.md.
AddEventHandler('fredpd:bolo:vehicleImpounded', function(plate, officerSrc)
    if not fromServer() then return end
    Service.resolveOnImpound(plate, officerSrc)
end)

AddEventHandler('playerDropped', function()
    Service.forget(source)
end)

MySQL.ready(function()
    Service.scheduleRebuild()
end)

---------------------------------------------------------------------------------------------------------------
-- Dev only: /fredpd_testbolo [plate] [hours] (in-game test without the tablet UI). Registered only with
-- `set fredpd_dev true`, ACE-restricted. Issues a vehicle BOLO through createBolo as the caller (same grant, duty,
-- tier and register checks); without a plate argument it takes the plate of the vehicle the caller sits in.

if GetConvar('fredpd_dev', 'false') == 'true' then
    lib.addCommand('fredpd_testbolo', {
        help = L('dev.command.testbolo'),
        params = {
            { name = 'plate', type = 'string', help = L('bolo.field.plate'), optional = true },
            { name = 'hours', type = 'number', help = L('bolo.field.duration'), optional = true },
        },
        restricted = 'group.admin',
    }, function(source, args)
        local src = tonumber(source) or 0
        if src < 1 then return end
        local plate = args.plate
        if not plate then
            local vehicle = GetVehiclePedIsIn(GetPlayerPed(tostring(src)), false)
            plate = vehicle and vehicle ~= 0 and GetVehicleNumberPlateText(vehicle) or ''
        end
        CreateThread(function()
            local res = Service.createBolo(src, { kind = 'vehicle', plate = plate, reason = L('dev.testbolo.reason'),
                expiresInHours = math.tointeger(tonumber(args.hours)) })
            local text
            if res.ok then
                text = L('bolo.create.success')
            elseif res.reason == 'duplicate' then
                text = L('bolo.create.duplicate', { subject = plate })
            elseif res.error == 'not_found' then
                text = L('bolo.checkPlate.unregistered', { plate = plate })
            elseif res.error == 'unauthorized' and res.reason == 'off_duty' then
                text = L('errors.notOnDuty')
            elseif res.error == 'unauthorized' then
                text = L('errors.unauthorized')
            else
                text = L('errors.validation')
            end
            TriggerClientEvent('ox_lib:notify', src, { type = res.ok and 'success' or 'error', description = text })
        end)
    end)
end
