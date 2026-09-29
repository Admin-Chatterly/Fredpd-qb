-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_dispatch client (IMPLEMENTATION.md §5.5, docs/contracts.md §C13): the alert toast (lib.notify + a stock
-- GTA frontend sound, no NUI of our own) and the "Ta larm" keybind. Nothing runs while idle: both are event-driven.

local L = require('@fredpd_core.shared.locale').L

local KEY_DEBOUNCE_MS = 750  -- presses closer together than this are ignored before anything is sent
local TOAST_MS = 8000
local TOAST_POSITION = 'top-right'

-- Stock sounds (GTA V frontend sound sets); priority 1 = hög.
local SOUNDS = {
    [1] = { name = 'TIMER_STOP', set = 'HUD_MINI_GAME_SOUNDSET' },
    [2] = { name = 'Event_Message_Purple', set = 'GTAO_FM_Events_Soundset' },
    [3] = { name = 'Event_Message_Purple', set = 'GTAO_FM_Events_Soundset' },
}

-- Accent per priority (FredPD theme: dark, flat, one accent; red only for hög).
local STYLES = {
    [1] = { icon = 'triangle-exclamation', color = '#e5484d' },
    [2] = { icon = 'tower-broadcast', color = '#3e8ed0' },
    [3] = { icon = 'circle-info', color = '#8b8d98' },
}

local takeKeybind -- set below; its current binding is shown in the toast hint

--- First `max` characters (UTF-8 code points, like the server's limits) of `v`, never cut inside a character;
--- invalid bytes are dropped. Looks at no more than 4 bytes per character (bounded work).
local function cutChars(v, max)
    if #v <= max then -- at most `max` characters; still must be valid UTF-8
        if utf8.len(v) then return v end
    else
        v = v:sub(1, max * 4)
        if utf8.len(v) then
            local stop = utf8.offset(v, max + 1)
            return stop and v:sub(1, stop - 1) or v
        end
    end
    local out, n, i, len = {}, 0, 1, #v
    for _ = 1, len do
        if i > len or n >= max then break end
        if utf8.len(v, i, i) then -- a valid character starts here; its size follows from its code point
            local cp = utf8.codepoint(v, i)
            local size = cp < 0x80 and 1 or cp < 0x800 and 2 or cp < 0x10000 and 3 or 4
            out[#out + 1] = v:sub(i, i + size - 1)
            n, i = n + 1, i + size
        else
            i = i + 1 -- drop one invalid byte
        end
    end
    return table.concat(out)
end

--- One untrusted value (alert data comes from ps-dispatch, i.e. from any client) made safe for lib.notify's
--- description, which ox_lib renders as markdown (react-markdown): control characters become spaces and every ASCII
--- punctuation character is backslash-escaped (CommonMark renders `\x` as a literal `x`), so no image, link,
--- heading, list, emphasis or code span can be built from it. Cut first (on a character boundary), then escape.
local function text(v, max)
    if type(v) == 'number' then v = tostring(v) end
    if type(v) ~= 'string' then return '' end
    v = cutChars(v, max):gsub('[\0-\31\127]', ' ')
    return (v:gsub('[\33-\47\58-\64\91-\96\123-\126]', '\\%0'))
end

---------------------------------------------------------------------------------------------------------------
-- Toast: server -> TriggerClientEvent('fredpd:client:alertToast', src, AlertToast), only to on-duty officers with
-- mdt_page:alerts. One notification id per alert, so a repeat for the same alert replaces the old one.

RegisterNetEvent('fredpd:client:alertToast', function(toast)
    if type(toast) ~= 'table' then return end
    local id = math.tointeger(tonumber(toast.id))
    if not id or id < 1 then return end
    local priority = math.tointeger(tonumber(toast.priority)) or 2
    if not STYLES[priority] then priority = 2 end
    local vars = { code = text(toast.code, 16), title = text(toast.title, 160), street = text(toast.street, 128) }
    local body = vars.street ~= '' and L('alert.toast.body', vars) or L('alert.toast.bodyNoStreet', vars)
    local key = takeKeybind and takeKeybind:getCurrentKey() or 'G'
    key = text(key, 32)
    if key == '' then key = 'G' end
    local style = STYLES[priority]

    lib.notify({
        id = ('fredpd_alert_%d'):format(id),
        title = L('alert.toast.title'),
        -- ox_lib renders the description as markdown: two trailing spaces make a line break.
        description = body .. '  \n' .. L('alert.toast.hint', { key = key }),
        duration = TOAST_MS,
        position = TOAST_POSITION,
        icon = style.icon,
        iconColor = style.color,
        style = {
            backgroundColor = '#141517',
            color = '#e9ecef',
            borderLeft = '4px solid ' .. style.color,
            borderRadius = '4px',
            fontSize = '15px',
        },
    })

    local sound = SOUNDS[priority]
    PlaySoundFrontend(-1, sound.name, sound.set, true)
end)

---------------------------------------------------------------------------------------------------------------
-- Keybind "Ta larm" (default G): the server takes the newest open alert for us; we set the waypoint.

local KEY_BUSY_MS = 5000 -- a lost reply (ox_lib's own timeout is 5 min) blocks the key for at most this long
local lastPress = nil
local busyUntil = nil   -- set while a request is in flight
local requestSeq = 0    -- token of the newest request: only its reply may release the lock

local function notify(kind, description)
    lib.notify({ type = kind, description = description, position = TOAST_POSITION })
end

--- Handle the callback result: an Alert, { error, reason? } or nil (callback failed).
local function onTakeResult(result)
    if type(result) ~= 'table' then
        notify('error', L('errors.unknown'))
        return
    end
    if result.error then
        if result.error == 'not_found' then
            notify('inform', L('alert.noOpen'))
        elseif result.error == 'unauthorized' and result.reason == 'off_duty' then
            notify('error', L('errors.notOnDuty'))
        elseif result.error == 'unavailable' then
            notify('error', L('errors.serviceUnavailable'))
        end
        -- unauthorized (no grant: civilians pressing G) and rate_limited stay silent.
        return
    end
    local c = result.coords
    if type(c) == 'table' and tonumber(c.x) and tonumber(c.y) then
        SetNewWaypoint(tonumber(c.x) + 0.0, tonumber(c.y) + 0.0)
        notify('success', L('alert.assignedSelf'))
    else
        notify('success', L('alert.assignedSelfNoWaypoint'))
    end
end

takeKeybind = lib.addKeybind({
    name = 'fredpd_take_alert',
    description = L('alert.keybind.take'),
    defaultKey = 'G',
    onPressed = function()
        -- Cheap on purpose: two comparisons, then one one-shot thread for the server round trip.
        local now = GetGameTimer()
        if (busyUntil and now < busyUntil) or (lastPress and now - lastPress < KEY_DEBOUNCE_MS) then return end
        lastPress = now
        busyUntil = now + KEY_BUSY_MS
        requestSeq = requestSeq + 1
        local token = requestSeq
        CreateThread(function()
            local ok, result = pcall(lib.callback.await, 'fredpd:dispatch:takeNewest', false)
            -- A late reply to an older request (after its 5 s window) must not unlock the key while a newer one is
            -- still pending; its result is still shown (the server did act on it).
            if token == requestSeq then busyUntil = nil end
            onTakeResult(ok and result or nil)
        end)
    end,
})

---------------------------------------------------------------------------------------------------------------
-- Dev (/fredpd_testalert, server-side gated by `fredpd_dev` + ACE): ps-dispatch's presets are client exports.

RegisterNetEvent('fredpd:dispatch:client:testShooting', function()
    if GetResourceState('ps-dispatch') ~= 'started' then return end
    exports['ps-dispatch']:Shooting()
end)
