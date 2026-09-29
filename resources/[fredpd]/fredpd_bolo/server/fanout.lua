-- SPDX-License-Identifier: GPL-3.0-only
-- Where BOLO changes and hits go. None of it may block or break the action that caused it: every export call is
-- pcall'd and repeated failures are logged at most once a minute each.
--
--   change  tablet push topic 'bolo' { type = 'created'|'resolved'|'expired', id } through
--           exports.fredpd_mdt:pushToOpenTablets (ids only: each tablet refetches listBolos, which applies canView per
--           viewer, so no Begränsad/Hemlig text is broadcast), and the server event
--           fredpd:boloChanged(bolo, change) with the full wire Bolo for other resources.
--   hit     alert (larm) through exports.fredpd_dispatch:createAlert, at most once per plate (vehicle BOLO) or
--           citizenid (person BOLO) per HIT_COOLDOWN_MS. Alerts reach every on-duty officer, so the text is what the
--           least-privileged viewer may see (Visibility.publicReason: the kontaktnotis for Begränsad/Hemlig) and a
--           BOLO hidden from that viewer raises none. The cooldown is taken before the call (no second alert while
--           it is in flight) and given back when createAlert fails, so the next hit retries.

local M = {}

M.LOG_INTERVAL_MS = 60000
M.HIT_COOLDOWN_MS = 60000 -- IMPLEMENTATION.md §5.4 "cooldown 60 s per plate"
M.HIT_MEMORY = 256 -- cooldown keys kept before old ones are pruned (no timer)
M.HIT_PRIORITY = 2 -- alert priority: normal
M.HIT_CODE_MAX = 16 -- AlertCreateInputSchema.code (dispatch.ts)
M.HIT_CODE_FALLBACK = 'BOLO' -- a radio-style code like fredpd_dispatch's '10-11', used only if the locale value
-- (bolo.hit.alertCode, "Efterlyst") is missing (pending locale not merged) or does not fit

--- Locale function; server/main.lua sets it to fredpd_core's L.
M.L = function(key) return key end

local lastLog, suppressed = {}, {}
local hitAt, hitCount = {}, 0

local function now()
    return GetGameTimer()
end

--- Log through ox_lib's lib.print (levels via convar ox:printlevel:fredpd_bolo) or print.
function M.log(level, fmt, ...)
    local msg = select('#', ...) > 0 and fmt:format(...) or tostring(fmt)
    local printer = type(lib) == 'table' and type(lib.print) == 'table' and lib.print[level]
    if printer then printer(msg) else print(('[fredpd_bolo] %s: %s'):format(level, msg)) end
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
-- Audit (fredpd_core; the actor is resolved there from src, 0 = system)

function M.audit(src, action, targetType, targetId, meta)
    local ok, err = pcall(function() exports.fredpd_core:audit(src, action, targetType, targetId, meta) end)
    if not ok then M.logThrottled('audit', 'error', 'audit %s %s failed: %s', action, tostring(targetId), tostring(err)) end
    return ok
end

---------------------------------------------------------------------------------------------------------------
-- Tablet push + server event

function M.push(topic, payload)
    if GetResourceState('fredpd_mdt') ~= 'started' then return false end
    local ok, err = pcall(function() exports.fredpd_mdt:pushToOpenTablets(topic, payload) end)
    if not ok then
        M.logThrottled('push', 'warn', 'fredpd_mdt:pushToOpenTablets(%s) failed: %s', topic, tostring(err))
    end
    return ok
end

--- A BOLO was created, resolved or expired. bolo = full wire Bolo.
function M.changed(bolo, change)
    M.push('bolo', { type = change, id = bolo.id })
    TriggerEvent('fredpd:boloChanged', bolo, change)
end

---------------------------------------------------------------------------------------------------------------
-- Hit fan-out

local SOURCE_LABELS = {
    plate_check = 'bolo.hit.source.check',
    radar = 'bolo.hit.source.radar',
    garage = 'bolo.hit.source.garage',
    impound = 'bolo.hit.source.impound',
}

--- Label key for a hit source ('Skyltkontroll', 'ANPR-kamera', …).
function M.sourceLabel(source)
    return M.L(SOURCE_LABELS[source] or 'bolo.hit.source.check')
end

--- Cooldown key of a BOLO: its plate, or 'person:<citizenid>'.
function M.hitKey(entry)
    if entry.kind == 'vehicle' and entry.plate then return entry.plate end
    return 'person:' .. tostring(entry.citizenid or entry.id)
end

--- Forget cooldowns older than the window once the memory is full.
local function prune(t)
    if hitCount < M.HIT_MEMORY then return end
    hitCount = 0
    for key, at in pairs(hitAt) do
        if t - at >= M.HIT_COOLDOWN_MS then hitAt[key] = nil else hitCount = hitCount + 1 end
    end
end

--- The start time (and the cooldown started) when a hit on this key may raise an alert now, else nil.
--- @return integer|nil
function M.takeCooldown(key)
    local t = now()
    local last = hitAt[key]
    if last and t - last < M.HIT_COOLDOWN_MS then return nil end
    prune(t)
    if not last then hitCount = hitCount + 1 end
    hitAt[key] = t
    return t
end

--- Give a cooldown back (the alert it was taken for failed), unless a later hit has taken it since.
function M.releaseCooldown(key, t)
    if hitAt[key] == t then hitAt[key] = nil end
end

function M.resetCooldowns()
    hitAt, hitCount = {}, 0
end

local function finite(n)
    return type(n) == 'number' and n == n and n > -1e6 and n < 1e6
end

--- { x, y, z } with three finite numbers, else nil.
function M.coords(c)
    if type(c) ~= 'table' and type(c) ~= 'vector3' then return nil end
    local ok, x, y, z = pcall(function() return c.x, c.y, c.z end)
    if not ok or not finite(x) or not finite(y) or not finite(z) then return nil end
    return { x = x, y = y, z = z }
end

--- Short display string from a hit context (street), control characters removed, at most 128 characters.
function M.street(s)
    if type(s) ~= 'string' or not utf8.len(s) then return nil end
    s = s:gsub('%c', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if s == '' then return nil end
    if utf8.len(s) > 128 then s = s:sub(1, utf8.offset(s, 129) - 1) end
    return s
end

--- Alert code: the locale's (bolo.hit.alertCode), or HIT_CODE_FALLBACK when that is missing or too long for
--- fredpd_dispatch (which would refuse the whole alert).
function M.alertCode()
    local key = 'bolo.hit.alertCode'
    local code = M.L(key)
    local n = type(code) == 'string' and utf8.len(code) or nil
    if code == key or not n or n < 1 or n > M.HIT_CODE_MAX or code:find('^%s') or code:find('%s$') then
        return M.HIT_CODE_FALLBACK
    end
    return code
end

--- AlertCreateInput (dispatch.ts) for a hit on `entry` (publicReason = Visibility.publicReason text).
function M.alertInput(entry, ctx, publicReason)
    local L = M.L
    local title, first
    if entry.kind == 'vehicle' then
        title = L('bolo.hit.alertTitle', { plate = entry.plate })
        first = L('bolo.hit.plate', { plate = entry.plate, reason = publicReason })
    else
        title = L('bolo.hit.alertTitlePerson', { name = entry.subject })
        first = L('bolo.hit.person', { name = entry.subject, reason = publicReason })
    end
    local description = first .. '\n' .. L('bolo.hit.via', { source = M.sourceLabel(ctx.source) })
    if utf8.len(title) and utf8.len(title) > 160 then title = title:sub(1, utf8.offset(title, 161) - 1) end
    if utf8.len(description) and utf8.len(description) > 1000 then
        description = description:sub(1, utf8.offset(description, 1001) - 1)
    end
    return {
        code = M.alertCode(),
        title = title,
        description = description,
        coords = M.coords(ctx.coords),
        street = M.street(ctx.street),
        priority = M.HIT_PRIORITY,
        source = 'bolo',
        meta = { boloId = entry.id, hit = ctx.source, plate = entry.plate, radar = ctx.radar },
    }
end

--- Raise the alert for a hit unless publicReason is nil (the BOLO is hidden from the least-privileged viewer), the
--- key is cooling down or fredpd_dispatch is not running. Never waits: the alert is created in a thread of its own;
--- a failed createAlert gives the cooldown back. @return boolean started
function M.hitAlert(entry, ctx, publicReason)
    if type(publicReason) ~= 'string' then
        M.logThrottled('hidden', 'info', 'BOLO hit #%d not alerted: canView hides it from other officers', entry.id)
        return false
    end
    if GetResourceState('fredpd_dispatch') ~= 'started' then
        M.logThrottled('dispatch', 'warn', 'BOLO hit #%d not alerted: fredpd_dispatch is not running', entry.id)
        return false
    end
    local key = M.hitKey(entry)
    local startedAt = M.takeCooldown(key)
    if not startedAt then return false end
    local input = M.alertInput(entry, ctx, publicReason)
    CreateThread(function()
        local ok, alert, err = pcall(function() return exports.fredpd_dispatch:createAlert(input) end)
        if not ok or not alert then
            M.releaseCooldown(key, startedAt)
            M.logThrottled('alert', 'error', 'createAlert for BOLO #%d failed: %s', entry.id,
                tostring(ok and err or alert))
        end
    end)
    return true
end

return M
