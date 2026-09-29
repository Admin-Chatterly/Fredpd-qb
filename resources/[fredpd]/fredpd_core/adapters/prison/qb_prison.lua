-- SPDX-License-Identifier: GPL-3.0-only
-- prison adapter "qb-prison": qbcore-framework/qb-prison@4ac6a67 (GPL-3.0). It is a qb-core resource, so this
-- adapter talks to qb-core directly (like qb-prison itself does); it only runs when config selects it.
--
-- jail(src, minutes, charges), server side only, the same path qb-policejob's police:server:JailPlayer takes
-- (qb-policejob server/interactions.lua:145-150 -> client/main.lua:211-217):
--   minutes > 0 -> Player.Functions.SetMetaData('injail', minutes) + criminalrecord, then the qb-prison client event
--                  'prison:client:Enter'(minutes) (qb-prison client/main.lua:174) which confines the player
--   minutes == 0 -> SetMetaData('injail', 0) + 'prison:client:UnjailPerson' (client/main.lua:251; qb-policejob's
--                  /unjail sends the same event, server/commands.lua:141)
-- qb-prison's own 'prison:server:SetJailStatus' (server/main.lua:6-19) trusts the client with the remaining time;
-- FredPD's record (fredpd_records) stays the authority. charges are not sent: qb-prison has no field for them.
-- Not started -> the base no-op (false) and ONE warning (adapters/base.lua).

local M = {}

M.RESOURCE = 'qb-prison'
M.ENTER = 'prison:client:Enter'
M.LEAVE = 'prison:client:UnjailPerson'
M.MAX_MINUTES = 99999

--- Whole number >= 0 and <= MAX_MINUTES, or nil.
function M.minutes(v)
    local n = math.tointeger(tonumber(v))
    if not n or n < 0 or n > M.MAX_MINUTES then return nil end
    return n
end

--- qb-core player object (tests replace M.getPlayer).
function M.getPlayer(src)
    local ok, player = pcall(function() return exports['qb-core']:GetPlayer(src) end)
    return ok and player or nil
end

function M.jail(src, minutes, _charges)
    src = math.tointeger(tonumber(src))
    minutes = M.minutes(minutes)
    if not src or src <= 0 or not minutes then return false end
    local player = M.getPlayer(src)
    if type(player) ~= 'table' or type(player.Functions) ~= 'table' then return false end
    local ok = pcall(player.Functions.SetMetaData, 'injail', minutes)
    if not ok then return false end
    if minutes == 0 then
        TriggerClientEvent(M.LEAVE, src)
        return true
    end
    local date = os.date('*t')
    if date.day == 31 then date.day = 30 end -- qb-policejob does the same (interactions.lua:140-143)
    pcall(player.Functions.SetMetaData, 'criminalrecord', { hasRecord = true, date = date })
    TriggerClientEvent(M.ENTER, src, minutes)
    return true
end

local adapter = require('adapters.base').define({
    kind = 'prison',
    name = 'qb-prison',
    resource = M.RESOURCE,
    methods = { jail = M.jail },
})

adapter.impl = M
return adapter
