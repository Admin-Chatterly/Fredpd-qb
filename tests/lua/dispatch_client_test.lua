-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_dispatch/client/main.lua with FiveM/ox_lib mocked: the alert toast (lib.notify id per alert, 8 s, Swedish
-- text with code/title/street and the key hint, frontend sound) and the "Ta larm" keybind (client-side 750 ms
-- debounce, one callback per press, waypoint, Swedish result notifications, silence for civilians).
-- Run: lua5.4 tests/lua/run.lua dispatch_client
local helper = require('helper')

local CLIENT = './resources/[fredpd]/fredpd_dispatch/client/main.lua'
package.preload['@fredpd_core.shared.locale'] = package.preload['@fredpd_core.shared.locale']
    or function() return require('shared.locale') end

local SV = (function()
    local dict = helper.readJson('locales/sv.json')
    for k, v in pairs(helper.readJson('locales/pending/dispatch.json')) do
        if type(v) == 'table' and v.sv then dict[k] = v.sv end
    end
    return dict
end)()

local GLOBALS = { 'RegisterNetEvent', 'lib', 'PlaySoundFrontend', 'SetNewWaypoint', 'GetGameTimer', 'CreateThread',
    'GetResourceState', 'exports', 'locale' }

--- Load the client script into a mocked world; returns the env.
local function withClient(fn)
    local saved = {}
    for _, n in ipairs(GLOBALS) do saved[n] = { rawget(_G, n) } end
    local env = { now = 50000, net = {}, notifies = {}, sounds = {}, waypoints = {}, calls = {}, keybinds = {},
        reply = nil, shooting = 0, psState = 'started' }
    local globals = {
        RegisterNetEvent = function(name, handler) env.net[name] = handler end,
        PlaySoundFrontend = function(id, name, set, p) env.sounds[#env.sounds + 1] = { id, name, set, p } end,
        SetNewWaypoint = function(x, y) env.waypoints[#env.waypoints + 1] = { x, y } end,
        GetGameTimer = function() return env.now end,
        CreateThread = function(f) f() end,
        GetResourceState = function() return env.psState end,
        exports = { ['ps-dispatch'] = { Shooting = function() env.shooting = env.shooting + 1 end } },
        locale = function(key) return SV[key] or key end,
        lib = {
            notify = function(data) env.notifies[#env.notifies + 1] = data end,
            addKeybind = function(data)
                env.keybinds[data.name] = data
                data.getCurrentKey = function() return env.key or 'G' end
                return data
            end,
            callback = {
                await = function(name, delay, ...)
                    env.calls[#env.calls + 1] = { name = name, delay = delay, n = select('#', ...) }
                    if type(env.reply) == 'function' then return env.reply() end
                    return env.reply
                end,
            },
        },
    }
    for k, v in pairs(globals) do rawset(_G, k, v) end
    local ok, err = pcall(function()
        dofile(CLIENT)
        fn(env)
    end)
    for n, v in pairs(saved) do rawset(_G, n, v[1]) end
    if not ok then error(err, 0) end
end

local tests = {}

tests['toast: lib.notify with one id per alert, Swedish text, 8 s, and a frontend sound'] = function(t)
    withClient(function(env)
        local toast = env.net['fredpd:client:alertToast']
        t.ok(toast, 'net event registered')
        toast({ id = 12, code = '10-11', title = 'Skottlossning', street = 'Strawberry Ave', priority = 2 })
        local n = env.notifies[1]
        t.eq(n.id, 'fredpd_alert_12')
        t.eq(n.title, 'Nytt larm')
        -- '-' is markdown-escaped (renders as '-').
        t.eq(n.description, '10\\-11 Skottlossning · Strawberry Ave  \nTryck G för att ta larmet')
        t.eq(n.duration, 8000)
        t.eq(n.iconColor, '#3e8ed0')
        t.ok(n.style and n.style.borderLeft:find('#3e8ed0', 1, true), 'custom style')
        t.eq(env.sounds[1], { -1, 'Event_Message_Purple', 'GTAO_FM_Events_Soundset', true })

        env.key = 'H'
        toast({ id = 13, code = '10-99', title = 'Officer i nöd', priority = 1 })
        t.eq(env.notifies[2].description, '10\\-99 Officer i nöd  \nTryck H för att ta larmet', 'no street, rebound key')
        t.eq(env.notifies[2].iconColor, '#e5484d')
        t.eq(env.sounds[2][2], 'TIMER_STOP', 'priority 1 sound')

        toast({ id = 12, code = '10-11', title = 'Skottlossning', street = 'Strawberry Ave', priority = 2 })
        t.eq(env.notifies[3].id, env.notifies[1].id, 'a repeat for the same alert replaces the toast (same id)')
    end)
end

tests['toast: malformed payloads are ignored or defaulted'] = function(t)
    withClient(function(env)
        local toast = env.net['fredpd:client:alertToast']
        toast(nil)
        toast('x')
        toast({ id = 'abc' })
        toast({ id = -1 })
        t.eq(#env.notifies, 0)
        t.eq(#env.sounds, 0)
        toast({ id = 5, code = 1011, title = ('x'):rep(500), priority = 99 })
        t.eq(env.notifies[1].iconColor, '#3e8ed0', 'unknown priority -> normal')
        t.ok(#env.notifies[1].description < 260, 'title capped')
    end)
end

tests['toast: markdown in alert data is escaped (ox_lib renders the description as markdown)'] = function(t)
    withClient(function(env)
        local toast = env.net['fredpd:client:alertToast']
        toast({ id = 9, code = '# X', title = '![x](https://e.vil/a.png)', street = '[a](b)', priority = 2 })
        local d = env.notifies[1].description
        t.eq(d, '\\# X \\!\\[x\\]\\(https\\:\\/\\/e\\.vil\\/a\\.png\\) · \\[a\\]\\(b\\)  \nTryck G för att ta larmet')
        -- No unescaped markdown syntax survives: every '[', '(', '!', '#' is preceded by a backslash.
        local body = d:match('^(.-)  \n')
        t.eq(body:gsub('\\%p', ''):find('[%[%]%(%)!#]'), nil, 'nothing left to build an image, link or heading')
        env.key = '*'
        toast({ id = 10, code = 'A', title = '`x` **y** _z_ <img src=x>', street = 'Gata\n## Rubrik\r\0', priority = 3 })
        t.eq(env.notifies[2].description,
            'A \\`x\\` \\*\\*y\\*\\* \\_z\\_ \\<img src\\=x\\> · Gata \\#\\# Rubrik    \nTryck \\* för att ta larmet',
            'control characters become spaces; key name escaped too')
    end)
end

tests['toast: text is cut by characters on a character boundary; invalid UTF-8 is dropped'] = function(t)
    withClient(function(env)
        local toast = env.net['fredpd:client:alertToast']
        local function body(n) return env.notifies[n].description:match('^(.-)  \n') end
        -- 200 two-byte characters: the old byte cut (160 bytes) kept 80; the server allows 160 characters.
        toast({ id = 1, code = 'A', title = ('å'):rep(200), street = ('ö'):rep(130), priority = 2 })
        t.eq(body(1), 'A ' .. ('å'):rep(160) .. ' · ' .. ('ö'):rep(128))
        t.ok(utf8.len(env.notifies[1].description), 'valid UTF-8')
        -- An odd byte limit would have split a character: 161 bytes of 'Ä…' + ASCII.
        toast({ id = 2, code = 'B', title = 'x' .. ('Ä'):rep(200), priority = 2 })
        t.eq(env.notifies[2].description, 'B x' .. ('Ä'):rep(159) .. '  \nTryck G för att ta larmet')
        -- Invalid bytes (stray continuation, truncated sequence, 0xFF) are dropped, the rest kept.
        toast({ id = 3, code = 'C', title = 'a\128b\255c\195', street = ('é'):rep(100) .. '\255' .. ('é'):rep(100),
            priority = 2 })
        t.eq(body(3), 'C abc · ' .. ('é'):rep(128))
        for i = 1, 3 do t.ok(utf8.len(env.notifies[i].description), 'toast ' .. i .. ' is valid UTF-8') end
    end)
end

tests['keybind: registered as fredpd_take_alert on G with the Swedish label'] = function(t)
    withClient(function(env)
        local kb = env.keybinds.fredpd_take_alert
        t.ok(kb)
        t.eq(kb.defaultKey, 'G')
        t.eq(kb.description, 'Ta larm')
    end)
end

tests['keybind: takes the alert, sets the waypoint, ignores presses within 750 ms'] = function(t)
    withClient(function(env)
        local kb = env.keybinds.fredpd_take_alert
        env.reply = { id = 7, status = 'assigned', coords = { x = 215.5, y = -920.25, z = 30.75 }, units = {} }
        kb:onPressed()
        t.eq(#env.calls, 1)
        t.eq(env.calls[1].name, 'fredpd:dispatch:takeNewest')
        t.eq(env.calls[1].n, 0, 'nothing but the press is sent; the server decides')
        t.eq(env.waypoints, { { 215.5, -920.25 } })
        t.eq(env.notifies[1].type, 'success')
        t.eq(env.notifies[1].description, SV['alert.assignedSelf'])
        env.now = env.now + 749
        kb:onPressed()
        t.eq(#env.calls, 1, 'debounced')
        env.now = env.now + 1
        env.reply = { id = 8, status = 'assigned', units = {} }
        kb:onPressed()
        t.eq(#env.calls, 2)
        t.eq(#env.waypoints, 1, 'no coords, no waypoint')
        t.eq(env.notifies[2].description, SV['alert.assignedSelfNoWaypoint'])
    end)
end

tests['keybind: server errors map to Swedish notifications; civilians and rate limits stay silent'] = function(t)
    withClient(function(env)
        local kb = env.keybinds.fredpd_take_alert
        local function press(reply)
            env.now = env.now + 1000
            env.reply = reply
            local before = #env.notifies
            kb:onPressed()
            return env.notifies[before + 1]
        end
        t.eq(press({ error = 'not_found' }).description, 'Inga öppna larm.')
        t.eq(press({ error = 'unauthorized', reason = 'off_duty' }).description, 'Du är inte i tjänst.')
        t.eq(press({ error = 'unavailable' }).description, SV['errors.serviceUnavailable'])
        t.eq(press({ error = 'unauthorized' }), nil, 'no grant: silent (G is pressed by everyone)')
        t.eq(press({ error = 'rate_limited' }), nil)
        t.eq(press(nil).description, SV['errors.unknown'], 'callback failed')
        t.eq(press(function() error('timeout') end).description, SV['errors.unknown'])
        t.eq(#env.waypoints, 0)
        t.eq(#env.sounds, 0)
    end)
end

tests['keybind: a request in flight blocks further presses for at most 5 s'] = function(t)
    withClient(function(env)
        local kb = env.keybinds.fredpd_take_alert
        local pending = true
        local threads = {}
        -- A thread that does not finish: the reply never comes back.
        rawset(_G, 'CreateThread', function(f) threads[#threads + 1] = coroutine.create(f) end)
        env.reply = function()
            if pending then coroutine.yield() end
            return { error = 'not_found' }
        end
        kb:onPressed()
        coroutine.resume(threads[1])
        t.eq(#env.calls, 1)
        env.now = env.now + 1000
        kb:onPressed()
        t.eq(#threads, 1, 'still in flight: ignored')
        env.now = env.now + 4000
        kb:onPressed()
        t.eq(#threads, 2, 'after 5 s the key works again')
        pending = false
        coroutine.resume(threads[2])
        t.eq(env.notifies[#env.notifies].description, 'Inga öppna larm.')
    end)
end

tests['keybind: a late reply to an older request does not unlock a newer one still in flight'] = function(t)
    withClient(function(env)
        local kb = env.keybinds.fredpd_take_alert
        local threads = {}
        rawset(_G, 'CreateThread', function(f) threads[#threads + 1] = coroutine.create(f) end)
        env.reply = function()
            coroutine.yield()
            return { error = 'not_found' }
        end
        kb:onPressed()
        coroutine.resume(threads[1]) -- request 1 waits for its reply
        env.now = env.now + 5000
        kb:onPressed()
        coroutine.resume(threads[2]) -- request 1's window is over: request 2 is sent and waits
        t.eq(#threads, 2)
        coroutine.resume(threads[1]) -- late reply to request 1
        t.eq(env.notifies[#env.notifies].description, 'Inga öppna larm.', 'the late result is still shown')
        env.now = env.now + 1000
        kb:onPressed()
        t.eq(#threads, 2, 'request 2 is still in flight: the key stays locked')
        coroutine.resume(threads[2])
        env.now = env.now + 1000
        kb:onPressed()
        t.eq(#threads, 3, 'request 2 answered: the key works again')
    end)
end

tests['dev: testShooting runs ps-dispatch Shooting() only when ps-dispatch is started'] = function(t)
    withClient(function(env)
        local ev = env.net['fredpd:dispatch:client:testShooting']
        ev()
        t.eq(env.shooting, 1)
        env.psState = 'stopped'
        ev()
        t.eq(env.shooting, 1)
    end)
end

return tests
