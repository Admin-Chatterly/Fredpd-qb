-- SPDX-License-Identifier: GPL-3.0-only
-- Where alert changes go (docs/contracts.md §C13): lib.notify toasts to on-duty officers holding mdt_page:alerts,
-- tablet pushes through fredpd_mdt (open tablets only), and the signed POST /internal/events to fredpd_service for
-- the portal. None of them may block or break the action that caused them: every call is pcall'd, the service
-- request is asynchronous (callback), and repeated failures are logged at most once a minute each.

local M = {}

M.LOG_INTERVAL_MS = 60000
M.ALERTS_GRANT = { 'mdt_page', 'alerts' }

local lastLog = {} -- [key] = GetGameTimer() of the last message, so a down service cannot flood the console
local suppressed = {}

local function now()
    return GetGameTimer()
end

--- Log through ox_lib's lib.print (levels via convar ox:printlevel:fredpd_dispatch) or print.
function M.log(level, fmt, ...)
    local msg = select('#', ...) > 0 and fmt:format(...) or tostring(fmt)
    local printer = type(lib) == 'table' and type(lib.print) == 'table' and lib.print[level]
    if printer then printer(msg) else print(('[fredpd_dispatch] %s: %s'):format(level, msg)) end
end

--- Log at most once per LOG_INTERVAL_MS per key (with the number of messages swallowed in between).
function M.logThrottled(key, level, fmt, ...)
    local t = now()
    if lastLog[key] and t - lastLog[key] < M.LOG_INTERVAL_MS then
        suppressed[key] = (suppressed[key] or 0) + 1
        return
    end
    lastLog[key] = t
    local extra = suppressed[key] and (' (%d similar suppressed)'):format(suppressed[key]) or ''
    suppressed[key] = nil
    M.log(level, fmt .. extra, ...)
end

---------------------------------------------------------------------------------------------------------------
-- fredpd_core checks (exports; the core owns grants and duty, §C9)

--- hasGrant(src, 'mdt_page', 'alerts') and on duty. Grant first: it is an in-memory lookup, while isOnDuty asks
--- qbx_core for the player, so civilians cost one table lookup each.
function M.isAlertOfficer(src)
    local core = exports.fredpd_core
    return core:hasGrant(src, M.ALERTS_GRANT[1], M.ALERTS_GRANT[2]) == true and core:isOnDuty(src) == true
end

--- Online player ids (integers).
function M.players()
    local out = {}
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        if src then out[#out + 1] = src end
    end
    return out
end

---------------------------------------------------------------------------------------------------------------
-- Toast (AlertToast = { id, code, title, street, priority }) to every on-duty officer with mdt_page:alerts,
-- tablet open or not. Returns the number of recipients.

function M.toast(toast)
    local n = 0
    for _, src in ipairs(M.players()) do
        local ok, allowed = pcall(M.isAlertOfficer, src)
        if ok and allowed then
            TriggerClientEvent('fredpd:client:alertToast', src, toast)
            n = n + 1
        elseif not ok then
            M.logThrottled('toast-check', 'error', 'toast check failed for %s: %s', src, tostring(allowed))
        end
    end
    return n
end

---------------------------------------------------------------------------------------------------------------
-- Tablet push (topics 'alerts' and 'units') through fredpd_mdt, which sends only to open tablets (§4.7).

function M.push(topic, payload)
    if GetResourceState('fredpd_mdt') ~= 'started' then return false end
    local ok, err = pcall(function() exports.fredpd_mdt:pushToOpenTablets(topic, payload) end)
    if not ok then
        M.logThrottled('push', 'warn', 'fredpd_mdt:pushToOpenTablets(%s) failed: %s', topic, tostring(err))
    end
    return ok
end

---------------------------------------------------------------------------------------------------------------
-- Service: POST /internal/events { type, payload } (§C6, DispatchInternalEvent), signed by fredpd_core.

function M.postInternal(eventType, payload)
    local ok, err = pcall(function()
        exports.fredpd_core:signedFetch('POST', '/internal/events', { type = eventType, payload = payload },
            function(status, body)
                status = tonumber(status) or 0
                if status < 200 or status >= 300 then
                    M.logThrottled('service', 'warn', 'POST /internal/events (%s) -> %d %s', eventType, status,
                        tostring(body):sub(1, 200))
                end
            end)
    end)
    if not ok then
        M.logThrottled('service-export', 'error', 'fredpd_core:signedFetch unavailable: %s', tostring(err))
    end
    return ok
end

return M
