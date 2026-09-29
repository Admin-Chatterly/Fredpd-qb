-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_mdt server entry (IMPLEMENTATION.md §5.2, docs/contracts.md §C12, docs/modules/mdt.md). Registers the two
-- callbacks, the close event, the exports and the /surfplatta command at start; no threads, timers or loops.
--
-- Exports: isTabletOpen(src) -> boolean, pushToOpenTablets(topic, payload[, filter]) -> n, pushTo(src, topic,
-- payload) -> boolean, closeTablet(src[, reasonKey]) -> boolean.

local L = require('@fredpd_core.shared.locale').L
local C = require 'server.common'
local Open = require 'server.open'
local Dispatch = require 'server.dispatch'
local Tablets = require 'server.tablets'
local Config = require 'config'

C.L = L

---------------------------------------------------------------------------------------------------------------
-- Callbacks (ox_lib; `source` is the calling player, never an argument)

lib.callback.register('fredpd:mdt:open', function(source, req)
    return Open.open(source, req)
end)

lib.callback.register('fredpd:mdt:action', function(source, req)
    return Dispatch.handle(source, req)
end)

-- The NUI was closed on the client (Esc, close button, death, vehicle exit, resource stop). No arguments: it can
-- only ever clear the sender's own session. Not rate limited: idempotent, O(1), and a dropped close would leave a
-- stale session behind.
RegisterNetEvent('fredpd:mdt:closed', function()
    Open.markClosed(source)
end)

---------------------------------------------------------------------------------------------------------------
-- Exports

exports('isTabletOpen', Open.isOpen)
exports('pushToOpenTablets', Open.pushToOpenTablets)
exports('pushTo', Open.pushTo)
exports('closeTablet', function(src, reasonKey)
    if reasonKey ~= nil and (type(reasonKey) ~= 'string' or not reasonKey:find('^[%w_.]+$')) then reasonKey = nil end
    return Open.forceClose(src, reasonKey)
end)

---------------------------------------------------------------------------------------------------------------
-- Server-side reasons to close (AddEventHandler only: none of these may be triggered by a client)

local function fromServer()
    local n = tonumber(source)
    return not n or n <= 0
end

-- fredpd_core fires this after every grant cache change (docs/modules/core.md).
AddEventHandler('fredpd:grantsChanged', function(src)
    if fromServer() then Open.onGrantsChanged(src) end
end)

-- qbx_core (docs/deps-verification.md §5): duty toggles and job changes.
AddEventHandler('QBCore:Server:SetDuty', function(src, onDuty)
    if fromServer() and not onDuty then Open.onDutyChanged(src) end
end)
AddEventHandler('QBCore:Server:OnJobUpdate', function(src)
    if fromServer() then Open.onDutyChanged(src) end
end)
AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
    if fromServer() then Open.markClosed(src) end
end)

AddEventHandler('playerDropped', function()
    Open.onDropped(source)
end)

---------------------------------------------------------------------------------------------------------------
-- /surfplatta <server id>: Ledning issues a tablet (perm tablets.manage, checked via fredpd_core; the console may
-- always issue, for the very first tablet).

local function reply(src, kind, text)
    if src == 0 then
        print(('[fredpd_mdt] %s'):format(text))
    else
        TriggerClientEvent('ox_lib:notify', src, { type = kind, description = text })
    end
end

lib.addCommand('surfplatta', {
    help = L('tablet.issue'),
    params = { { name = 'target', type = 'playerId', help = L('tablet.issueTarget') } },
}, function(source, args)
    local src = tonumber(source) or 0
    if src > 0 then
        if not C.hasGrant(src, 'perm', 'tablets.manage') then return reply(src, 'error', L('errors.unauthorized')) end
        if not C.allow(src, 'issue', Config.limits.issue) then return reply(src, 'error', L('errors.rateLimited')) end
    end
    CreateThread(function()
        local ok, key, vars = Tablets.issue(src, args.target)
        reply(src, ok and 'success' or 'error', L(key, vars))
    end)
end)
