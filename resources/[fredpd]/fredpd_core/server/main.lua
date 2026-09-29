-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_core server entry point. Every other server module is loaded here with ox_lib `require`, in this order:
-- config -> framework bridge -> exports/events/commands (perms, canview, audit, mirror, officers, adapters) -> once
-- oxmysql is ready:
-- migrations (server/db.lua), then the DB-backed state (visibility rules, officers, units, online players).
-- Exports are registered synchronously so other resources can call them as soon as fredpd_core has started; until
-- the grants of a player are loaded every permission check fails closed.

local Locale = require 'shared.locale'
local Format = require 'shared.format'
local Core = require 'server.core'
local Db = require 'server.db'
local Perms = require 'server.perms'
local CanView = require 'server.canview'
local Audit = require 'server.audit'
local Mirror = require 'server.mirror'
local Officers = require 'server.officers'
local Adapters = require 'adapters.loader'
local Bridge = require 'server.bridge'

---------------------------------------------------------------------------------------------------------------
-- 1. Config files (copied into config/ by scripts/build.mjs). A broken file is logged, never fatal.

local function loadConfig()
    local formats, err = Core.readJsonFile('config/formats.json')
    if formats then
        local ok, e = pcall(Format.load, formats)
        if ok then
            Core.config.formats = Format.get()
        else
            Core.error('config/formats.json rejected: %s', tostring(e))
        end
    else
        Core.error('%s', err)
    end

    local units, uerr = Core.readJsonFile('config/units.json')
    if not units then Core.error('%s', uerr) end
    Core.config.units = units
    Core.config.unitsByCode, Core.config.unitOrder = Core.unitIndex(units)

    local integrations, ierr = Core.readJsonFile('config/integrations.json')
    if not integrations then Core.warn('%s; every adapter is "none"', ierr) end
    Core.config.integrations = integrations or {}
end

loadConfig()

-- Framework/inventory/target/doorlock implementations (config/integrations.json, docs/contracts.md §C17). Loaded before
-- anything asks for a player; logs one capability line and one warning per missing resource.
Bridge.load(Core.config.integrations)

---------------------------------------------------------------------------------------------------------------
-- 2. Exports, events and commands

Locale.init()
exports('L', function(key, vars) return Locale.L(key, vars) end)

Bridge.register()
Bridge.primeOnline()
Perms.register()
CanView.register()
Audit.register()
Mirror.register()
Officers.register()
Adapters.register()
Adapters.load(Core.config.integrations)

---------------------------------------------------------------------------------------------------------------
-- 3. Database. MySQL.ready runs its callback once, in a thread, when oxmysql is connected.

MySQL.ready(function()
    local ok, result = pcall(Db.migrate)
    if not ok then
        Core.error('database migration failed; FredPD tables may be missing or outdated: %s', tostring(result))
    end

    CanView.loadRules()
    Officers.loadAll()
    local okUnits, unitsErr = pcall(Officers.syncUnits, Core.config.units)
    if not okUnits then Core.error('fredpd_units sync failed: %s', tostring(unitsErr)) end

    -- Players already online (resource restart): grants, mirror row, officer row/callsign.
    Perms.loadOnline()
    Mirror.syncOnline()
    for _, src in ipairs(Core.players()) do Core.async('officer on start', Officers.onCharacter, src) end

    Core.info('fredpd_core ready')
end)
