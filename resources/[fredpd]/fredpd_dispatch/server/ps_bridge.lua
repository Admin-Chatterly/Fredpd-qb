-- SPDX-License-Identifier: GPL-3.0-only
-- Inbound ps-dispatch calls. patches/ps-dispatch.10-fredpd-bridge.patch makes ps-dispatch fire, for every call it
-- stores, the server event `fredpd:dispatch:incoming(data, reporterSrc)` (docs/contracts.md §C13). The handler is
-- registered with AddEventHandler, so a client cannot trigger it; the data itself was still reported by a client
-- (ps-dispatch's alerts are client exports), so it is treated as hostile: per-reporter rate limit, police calls
-- only, every field capped or validated (shared/alert_input.lua fromPsDispatch), then createAlert.

local Input = require 'shared.alert_input'
local Service = require 'server.alert_service'
local Fanout = require 'server.fanout'

local M = {}

M.PLAYER_LIMIT = { max = 5, windowMs = 30000 }  -- §C13: 5 per 30 s per reporting player
M.SERVER_LIMIT = { max = 30, windowMs = 30000 } -- reporter nil/0: server-generated calls share one bucket

local players = Input.newLimiter(M.PLAYER_LIMIT.max, M.PLAYER_LIMIT.windowMs)
local server = Input.newLimiter(M.SERVER_LIMIT.max, M.SERVER_LIMIT.windowMs)

M.stats = { accepted = 0, rejected = 0 } -- for tests and a future /fredpd_selftest line

--- The event source of a server-local TriggerEvent is '' (FiveM); a positive number means a player sent it.
local function fromPlayer(src)
    local n = tonumber(src)
    return n ~= nil and n > 0
end

--- Handler body. `eventSource` is the global `source` at the time of the event. Returns the created Alert, or nil
--- and why it was dropped ('player_source', 'not_police', 'rate_limited', a field name, or a createAlert error).
--- Only police calls count toward the reporter's limit.
--- Awaits the insert (event handlers run in their own thread, so ps-dispatch is not held up).
function M.handle(eventSource, data, reporter)
    if fromPlayer(eventSource) then
        M.stats.rejected = M.stats.rejected + 1
        Fanout.logThrottled('incoming-player', 'warn',
            'fredpd:dispatch:incoming triggered with player source %s; ignored (server-only event)', tostring(eventSource))
        return nil, 'player_source'
    end
    -- Police filter first (cheap, bounded): EMS-only calls (/311, InjuriedPerson, EmsDown …) must not use up the
    -- reporter's budget, or a downed player's real 911 report could be dropped as rate limited.
    if not Input.isPoliceCall(data) then return nil, 'not_police' end
    local rep = tonumber(reporter)
    local now = GetGameTimer()
    local allowed
    if rep and rep > 0 and math.tointeger(rep) then
        allowed = players.allow(math.tointeger(rep), now)
    else
        allowed = server.allow('server', now)
    end
    if not allowed then
        M.stats.rejected = M.stats.rejected + 1
        Fanout.logThrottled('incoming-rate', 'info', 'ps-dispatch call from %s dropped (rate limit)', tostring(reporter))
        return nil, 'rate_limited'
    end
    local input, why = Input.fromPsDispatch(data, M.L)
    if not input then
        M.stats.rejected = M.stats.rejected + 1
        Fanout.logThrottled('incoming-invalid', 'info', 'ps-dispatch call from %s dropped (bad %s)',
            tostring(reporter), tostring(why))
        return nil, why
    end
    local alert, err = Service.create(input)
    if alert then M.stats.accepted = M.stats.accepted + 1 end
    return alert, err
end

--- Forget a player's bucket (playerDropped).
function M.forget(src)
    local n = math.tointeger(tonumber(src))
    if n then players.clear(n) end
end

--- L(key, vars) for the description labels; set by server/main.lua (fredpd_core shared/locale).
M.L = function(key) return key end

return M
