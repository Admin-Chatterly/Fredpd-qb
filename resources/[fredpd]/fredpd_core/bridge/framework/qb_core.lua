-- SPDX-License-Identifier: GPL-3.0-only
-- Framework bridge: qb-core (docs/contracts.md §C17). Verified against qb-core 9b3cddcc (deps.lock.json):
--   core object     exports['qb-core']:GetCoreObject(filters)        shared/main.lua:7-18 (filters: only 'Functions')
--   players         QBCore.Functions.GetPlayer(src)                    server/functions.lua:46-52
--                   QBCore.Functions.GetPlayerByCitizenId(cid)         server/functions.lua:57-59
--                   QBCore.Functions.GetPlayers() -> ids               server/functions.lua:115-121
--   money           Player.Functions.RemoveMoney(type, amount, reason) server/player.lua:209-243 (true | false | nil;
--                   refuses cash/crypto below 0 and bank below Config.Money.MinusLimit, config.lua:11-12)
--   events (server-local TriggerEvent, never net):
--     QBCore:Server:PlayerLoaded(Player)          server/player.lua:458 (CreatePlayer; Players[src] already set)
--     QBCore:Server:OnPlayerUnload(src)           server/player.lua:351 (Logout), server/events.lua:17 (playerDropped)
--     QBCore:Server:OnJobUpdate(src, job)         server/events.lua:200-208 (re-fired from OnPlayerUpdated 'job'/'all';
--                                                 SetJob player.lua:88 and SetJobDuty player.lua:137-142 both land here)
--     QBCore:Server:SetDuty(src, onduty)          server/events.lua:189 (only the ToggleDuty net event, 177-191)
--     QBCore:Server:OnPlayerUpdated(src, key, v)  server/player.lua:55-62 (every UpdateClient: money, metadata, ...)
-- Not used: QBCore:Server:OnPlayerLoaded is a client-fired net event (server/events.lua:193-197).

local Normalize = require 'bridge.framework.normalize'

local M = { kind = 'framework', name = 'qb-core', resource = 'qb-core' }

--- OnPlayerUpdated keys that never change what FredPD mirrors (charinfo, citizenid, license, job): skipped so a
--- money or hunger tick costs nothing.
M.UPDATE_SKIP = { money = true, metadata = true, items = true, position = true }

function M.server()
    local impl = {}
    local core = nil

    --- QBCore with only its Functions (a filtered GetCoreObject copies far less across the export boundary).
    local function functions()
        if not core then
            local obj = exports['qb-core']:GetCoreObject({ 'Functions' })
            if type(obj) ~= 'table' or type(obj.Functions) ~= 'table' then error('qb-core GetCoreObject returned no Functions', 0) end
            core = obj
        end
        return core.Functions
    end

    --- Forget the cached core object (qb-core restarted: its function references are dead).
    function impl.reset() core = nil end

    local function rawPlayer(src)
        src = tonumber(src)
        if not src or src <= 0 then return nil end
        local player = functions().GetPlayer(src)
        if type(player) == 'table' and type(player.PlayerData) == 'table' then return player end
        return nil
    end

    function impl.getPlayer(src)
        local player = rawPlayer(src)
        return player and Normalize.player(player.PlayerData) or nil
    end

    function impl.getPlayerByCitizenId(citizenid)
        if type(citizenid) ~= 'string' or citizenid == '' then return nil end
        local player = functions().GetPlayerByCitizenId(citizenid)
        if type(player) ~= 'table' or type(player.PlayerData) ~= 'table' then return nil end
        return tonumber(player.PlayerData.source)
    end

    function impl.getPlayers()
        local out = {}
        for _, id in pairs(functions().GetPlayers() or {}) do
            local src = tonumber(id)
            if src then out[#out + 1] = src end
        end
        table.sort(out)
        return out
    end

    function impl.removeMoney(src, account, amount, reason)
        local player = rawPlayer(src)
        if not player or type(player.Functions) ~= 'table' or not player.Functions.RemoveMoney then return false end
        return player.Functions.RemoveMoney(account, amount, reason) == true
    end

    --- Register the upstream event handlers; h = { loaded(src, player), unloaded(src), job(src, job), duty(src, onduty),
    --- updated(src, player|nil) } (server/bridge.lua).
    function impl.bind(h)
        AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
            local pd = type(player) == 'table' and player.PlayerData or nil
            if type(pd) ~= 'table' then return end
            h.loaded(tonumber(pd.source), Normalize.player(pd))
        end)
        AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
            h.unloaded(tonumber(src))
        end)
        AddEventHandler('QBCore:Server:OnJobUpdate', function(src, job)
            h.job(tonumber(src), Normalize.job(job))
        end)
        AddEventHandler('QBCore:Server:SetDuty', function(src, onduty)
            h.duty(tonumber(src), onduty == true)
        end)
        AddEventHandler('QBCore:Server:OnPlayerUpdated', function(src, key)
            if M.UPDATE_SKIP[key] then return end
            h.updated(tonumber(src), nil)
        end)
    end

    return impl
end

return M
