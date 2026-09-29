-- SPDX-License-Identifier: GPL-3.0-only
-- prison adapter "xt-prison": xT-Development/xt-prison@85fd705 (= v1.4.9 apart from configs/client.lua). It has NO
-- LICENCE: FredPD only calls its export and ox_lib callbacks, never copies or patches it (docs/deps-verification.md
-- §2a, docs/modules/adapters-qb.md). Supported frameworks: qb-core through its bridge/server/qb.lua (active when
-- qb-core runs and qbx_core does not) and qbx_core through bridge/server/qbx.lua; both define the same
-- setJailTime / export SetJailTime(src, minutes) (qb.lua:30-46, qbx.lua:30-47).
--
-- jail(src, minutes, charges), server side only. FredPD's record (fredpd_records) is the authority; xt-prison only
-- confines, and it trusts the client with the countdown (§2a).
--   minutes > 0, not jailed yet  -> exports['xt-prison']:SetJailTime(src, minutes) FIRST (server-side state, injail
--                                   metadata and DB-on-drop no longer depend on the client answering), then the ox_lib
--                                   client callback 'xt-prison:client:enterJail'(minutes) (client/cl_main.lua:5-7; the
--                                   call xt-prison's own /jail makes, server/sv_commands.lua:96). enterPrison's
--                                   setJailStatus (server/sv_main.lua:150-158) then sees the same time and only
--                                   confines; a client that drops the callback is re-jailed on relog (initJailTime).
--   minutes > 0, already jailed  -> exports['xt-prison']:SetJailTime(src, minutes) (new time, like its /jail on a
--                                   jailed player, sv_commands.lua:80-85) + a notice to the prisoner
--   minutes == 0 (release)       -> SetJailTime(src, 0), then 'xt-prison:client:exitJail'(true) (the roster's
--                                   unjail, server/sv_roster.lua:14-22); not jailed -> true, nothing to do
-- The client callbacks are sent without waiting (lib.callback with a response handler): the caller (fredpd_records,
-- inside a tablet action) never blocks on the prisoner's screen fades; a refusal or error is logged. `true` therefore
-- means "handed to xt-prison". Not started -> the base no-op (false) and ONE warning (adapters/base.lua).
-- charges ({ { code, label } }) are not sent: xt-prison has no field for them.

local Locale = require 'shared.locale'

local M = {}

M.RESOURCE = 'xt-prison'
M.ENTER = 'xt-prison:client:enterJail'
M.EXIT = 'xt-prison:client:exitJail'
M.MAX_MINUTES = 99999 -- sanity cap; xt-prison keeps the time in an INT column (server/modules/db.lua)

local log = nil

local function logger()
    if log then return log end
    local ok, Core = pcall(require, 'server.core')
    log = ok and Core or { warn = print, error = print, debug = function() end }
    return log
end

function M.setLogger(l) log = l end

--- Framework bridge (server/bridge.lua); tests replace M.bridge.
function M.getBridge()
    if M.bridge then return M.bridge end
    local ok, Bridge = pcall(require, 'server.bridge')
    return ok and Bridge or nil
end

--- ox_lib's lib (global in fredpd_core); tests replace M.lib.
local function oxlib()
    return M.lib or rawget(_G, 'lib')
end

--- Whole number >= 0 and <= MAX_MINUTES, or nil.
function M.minutes(v)
    local n = math.tointeger(tonumber(v))
    if not n or n < 0 or n > M.MAX_MINUTES then return nil end
    return n
end

--- Current xt-prison time of a player (its replicated state bag `jailTime`), 0 when none.
function M.currentTime(src)
    local ok, t = pcall(function()
        local p = Player(src)
        return p and p.state and p.state.jailTime
    end)
    t = ok and tonumber(t) or 0
    return t > 0 and t or 0
end

--- Send an xt-prison client callback without waiting; the answer is only logged.
local function sendClient(event, src, arg, what)
    local l = oxlib()
    if type(l) ~= 'table' or l.callback == nil then error('ox_lib lib.callback is not available', 0) end
    l.callback(event, src, function(result)
        if result ~= true then
            logger().warn('prison adapter "xt-prison": %s for player %s was not confirmed (%s)', what, tostring(src),
                tostring(result))
        end
    end, arg)
    return true
end

local function notify(src, key, vars)
    if type(TriggerClientEvent) ~= 'function' then return end
    TriggerClientEvent('ox_lib:notify', src, { type = 'inform', description = Locale.L(key, vars) })
end

function M.jail(src, minutes, _charges)
    src = math.tointeger(tonumber(src))
    minutes = M.minutes(minutes)
    if not src or src <= 0 or not minutes then return false end
    local bridge = M.getBridge()
    local player = bridge and bridge.getPlayer(src) or nil
    if type(player) ~= 'table' then return false end -- offline or no character loaded
    local current = M.currentTime(src)
    if minutes == 0 then
        if current <= 0 then return true end
        if exports[M.RESOURCE]:SetJailTime(src, 0) ~= true then return false end
        sendClient(M.EXIT, src, true, 'release')
        notify(src, 'prison.notify.released')
        return true
    end
    if current > 0 then
        if exports[M.RESOURCE]:SetJailTime(src, minutes) ~= true then return false end
        notify(src, 'prison.notify.timeChanged', { count = minutes })
        return true
    end
    if exports[M.RESOURCE]:SetJailTime(src, minutes) ~= true then return false end
    return sendClient(M.ENTER, src, minutes, 'jail')
end

local adapter = require('adapters.base').define({
    kind = 'prison',
    name = 'xt-prison',
    resource = M.RESOURCE,
    methods = { jail = M.jail },
})

local baseInit = adapter.init
function adapter.init(logArg, defer)
    baseInit(logArg, defer)
    log = logArg or log
end

adapter.impl = M
return adapter
