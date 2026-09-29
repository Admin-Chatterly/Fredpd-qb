-- SPDX-License-Identifier: GPL-3.0-only
-- Framework bridge: qbx_core (docs/contracts.md §C17; the calls FredPD made directly before the bridge). Verified
-- against qbx_core f0553b6c (deps.lock.json, docs/deps-verification.md §5):
--   players   exports.qbx_core:GetPlayer(src)              server/functions.lua:86-94
--             exports.qbx_core:GetPlayerByCitizenId(cid)   server/functions.lua:98-110
--             exports.qbx_core:GetQBPlayers() -> { [src] = Player }   server/functions.lua:143-147
--   money     exports.qbx_core:RemoveMoney(src, type, amount, reason) -> boolean   server/player.lua:1371-1423
--   events (server-local TriggerEvent):
--     QBCore:Server:PlayerLoaded(Player)      server/player.lua:979
--     QBCore:Server:OnPlayerUnload(src)       server/player.lua:750 (Logout only; a disconnect is playerDropped)
--     QBCore:Server:OnJobUpdate(src, job)     server/player.lua:266, :1026 (job definition changed, every holder)
--     QBCore:Server:SetDuty(src, onduty)      server/player.lua:205 (SetJobDuty; ToggleDuty server/events.lua:239-250)
--     QBCore:Player:SetPlayerData(PlayerData) server/player.lua:1153 (every UpdatePlayerData: money, metadata, ...)

local Normalize = require 'bridge.framework.normalize'

local M = { kind = 'framework', name = 'qbx_core', resource = 'qbx_core' }

function M.server()
    local impl = {}

    function impl.reset() end

    local function rawPlayer(src)
        src = tonumber(src)
        if not src or src <= 0 then return nil end
        local player = exports.qbx_core:GetPlayer(src)
        if type(player) == 'table' and type(player.PlayerData) == 'table' then return player end
        return nil
    end

    function impl.getPlayer(src)
        local player = rawPlayer(src)
        return player and Normalize.player(player.PlayerData) or nil
    end

    function impl.getPlayerByCitizenId(citizenid)
        if type(citizenid) ~= 'string' or citizenid == '' then return nil end
        local player = exports.qbx_core:GetPlayerByCitizenId(citizenid)
        if type(player) ~= 'table' or type(player.PlayerData) ~= 'table' then return nil end
        return tonumber(player.PlayerData.source)
    end

    --- Sources with a loaded character. GetQBPlayers copies every Player across the export boundary: used at start
    --- and by rare callers only.
    function impl.getPlayers()
        local out = {}
        for id in pairs(exports.qbx_core:GetQBPlayers() or {}) do
            local src = tonumber(id)
            if src then out[#out + 1] = src end
        end
        table.sort(out)
        return out
    end

    function impl.removeMoney(src, account, amount, reason)
        src = tonumber(src)
        if not src or src <= 0 then return false end
        return exports.qbx_core:RemoveMoney(src, account, amount, reason) == true
    end

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
        AddEventHandler('QBCore:Player:SetPlayerData', function(pd)
            if type(pd) ~= 'table' then return end
            h.updated(tonumber(pd.source), Normalize.player(pd))
        end)
    end

    return impl
end

return M
