-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_breach server entry (IMPLEMENTATION.md §5.6, docs/contracts.md §C16, docs/modules/breach.md).
-- Registers the two breach callbacks, the sceneEvidence export and playerDropped. Nothing runs while idle.

local Config = require 'config'
local SceneTable = require 'config.scene_evidence'
local Breach = require 'server.breach'
local Scene = require 'server.scene'

local M = {}

local function guarded(name, fn)
    return function(...)
        local okRun, result = pcall(fn, ...)
        if okRun and type(result) == 'table' then return result end
        Breach.log('error', '%s failed: %s', name, tostring(result))
        return { ok = false, error = 'unavailable' }
    end
end

function M.start()
    Scene.configure({
        sceneCooldownMs = Config.sceneCooldownMs,
        sceneRadius = Config.sceneRadius,
        sceneSpacing = Config.sceneSpacing,
        mapBounds = Config.mapBounds,
    }, SceneTable)
    Breach.scene = Scene
    Breach.configure({
        ramItem = Config.ramItem,
        grant = Config.grant,
        progressMs = Config.progressMs,
        finishSlackMs = Config.finishSlackMs,
        tokenTtlMs = Config.tokenTtlMs,
        startRateMs = Config.startRateMs,
        cooldownMs = Config.cooldownMs,
        finishRateMs = Config.finishRateMs,
        denyDoors = Config.denyDoors,
        maxDistance = Config.maxDistance,
        breachEvidence = Config.breachEvidence,
    })
    Breach.checkItem()

    -- §4.6 order inside Breach.start / Breach.finish: local src = source → grant → duty → rate limit → work.
    -- The client's door id and token are hints; the door, its state and the distance are read on the server.
    lib.callback.register('fredpd:breach:start', function(source, doorId)
        local src = source
        return guarded('fredpd:breach:start', Breach.start)(src, doorId)
    end)
    lib.callback.register('fredpd:breach:finish', function(source, token)
        local src = source
        return guarded('fredpd:breach:finish', Breach.finish)(src, token)
    end)

    -- Server-only (an export cannot be called from a client): crime scripts leave evidence at a scene.
    exports('sceneEvidence', function(kind, coords, suspectSrc)
        return guarded('sceneEvidence', Scene.sceneEvidence)(kind, coords, suspectSrc)
    end)

    AddEventHandler('playerDropped', function()
        Breach.forget(source)
    end)
end

M.start()

return M
