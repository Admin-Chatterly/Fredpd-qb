-- SPDX-License-Identifier: GPL-3.0-only
-- qbx_police patch 40 'sv-locale' (task 4.3): the patched locales/sv.json translates every key of locales/en.json
-- with the same %s/%d placeholders in the same order (ox_lib locale() runs string.format), follows the FredPD
-- writing rules (docs/glossary.md), and ox_lib picks it with `setr ox:locale sv`. Also: every locale key the
-- FredPD hunks use exists, and every fredpd_audit action they write has a label in locales/pending/police.json.
-- Run: lua5.4 tests/lua/run.lua police_locale
local H = require('police_harness_test')
local helper = require('helper')

local tests = {}

local function flatten(tbl, prefix, out)
    out = out or {}
    for k, v in pairs(tbl) do
        local key = prefix and (prefix .. '.' .. k) or k
        if type(v) == 'table' then flatten(v, key, out) else out[key] = v end
    end
    return out
end

local function locales(tr)
    return flatten(json.decode(tr.files['locales/en.json'])), flatten(json.decode(tr.files['locales/sv.json']))
end

local function placeholders(s)
    local out = {}
    for p in s:gmatch('%%[sd]') do out[#out + 1] = p end
    return out
end

tests['sv.json translates every en.json key with the same placeholders'] = function(t)
    H.withTree(function(tr)
        local en, sv = locales(tr)
        local count = 0
        for key, text in pairs(en) do
            count = count + 1
            t.ok(type(sv[key]) == 'string' and sv[key] ~= '', 'missing sv: ' .. key)
            t.eq(placeholders(sv[key]), placeholders(text), key)
        end
        for key in pairs(sv) do t.ok(en[key] ~= nil, 'sv key not in en: ' .. key) end
        t.ok(count >= 200, 'en keys: ' .. count)
    end)
end

tests['sv.json follows the glossary writing rules'] = function(t)
    H.withTree(function(tr)
        local en, sv = locales(tr)
        local banned = { 'polisman', 'arrester', 'bolo', 'patronhylsa', 'bevisväska', 'rang' }
        for key, text in pairs(sv) do
            t.ok(not text:find('$', 1, true), key .. ': amounts in kr, never $')
            t.ok(not text:find('!', 1, true), key .. ': no exclamation marks')
            t.ok(not text:find('%.%.'), key .. ': ellipsis is …')
            t.ok(text == text:match('^%s*(.-)%s*$') or key == 'info.camera_id', key .. ': no outer whitespace')
            local lower = text:lower()
            for _, word in ipairs(banned) do t.ok(not lower:find(word, 1, true), key .. ': avoid ' .. word) end
            t.ok(text ~= en[key] or text:find('^%[') or not text:find('%a%a%a'), key .. ': still English')
        end
        t.eq(sv['error.on_duty_police_only'], 'Endast för polis i tjänst')
        t.eq(sv['fredpd.no_permission'], 'Du har inte behörighet att göra det här')
        t.eq(sv['info.fine_title'], 'Utfärda ordningsbot')
    end)
end

tests['ox_lib selects sv.json with setr ox:locale sv (locale module, files, 18 languages kept)'] = function(t)
    H.withTree(function(tr)
        local manifest = tr.files['fxmanifest.lua']
        t.ok(manifest:find("ox_lib 'locale'", 1, true), "fxmanifest: ox_lib 'locale' (loads locales/<ox:locale>.json)")
        t.ok(manifest:find("'locales/*.json'", 1, true), 'fxmanifest ships locales/*.json to clients')
        local n = 0
        for path in pairs(tr.files) do if path:match('^locales/[%w%-]+%.json$') then n = n + 1 end end
        t.eq(n, 18)
    end)
end

tests['every locale key used by the FredPD hunks exists in en.json'] = function(t)
    H.withTree(function(tr)
        local en = locales(tr)
        local used = {}
        local sources = { tr.files['fredpd/server.lua'], tr.files['fredpd/client.lua'], tr.files['fredpd/bolo.lua'],
            tr.files['server/main.lua'], tr.files['server/commands.lua'], tr.files['client/job.lua'],
            tr.files['client/heli.lua'], tr.files['client/camera.lua'] }
        for _, src in ipairs(sources) do
            for key in src:gmatch("locale%('([%w_%.]+)'") do used[key] = true end
            for key in src:gmatch("'(fredpd%.[%w_]+)'") do used[key] = true end
            for key in src:gmatch("= '(error%.[%w_]+)'") do used[key] = true end
        end
        t.ok(used['fredpd.no_permission'] and used['fredpd.armory_taken'] and used['fredpd.garage_empty'])
        t.ok(used['fredpd.bolo_radar'] and used['menu.impound_engine'] and used['hud.heli_model']
            and used['hud.camera_connected'] and used['menu.locker_stash'], 'patch 30/40 keys are scanned')
        for key in pairs(used) do
            if key ~= 'fredpd.server' and key ~= 'fredpd.bolo' then t.ok(en[key], 'missing en key ' .. key) end
        end
    end)
end

tests['player-facing English outside the locale files goes through locale() (menus, stashes, NUI)'] = function(t)
    H.withTree(function(tr)
        local job, main, js = tr.files['client/job.lua'], tr.files['server/main.lua'], tr.files['html/script.js']
        t.ok(js, 'html/script.js read')
        t.ok(not job:find("label = 'Engine'", 1, true) and not job:find("label = 'Fuel'", 1, true), 'impound menu')
        t.ok(job:find("locale('menu.impound_engine')", 1, true) and job:find("locale('menu.impound_fuel')", 1, true))
        t.ok(not main:find("'Police Trash'", 1, true) and not main:find("'Police Locker'", 1, true), 'stash labels')
        t.ok(main:find("locale('menu.trash_stash')", 1, true) and main:find("locale('menu.locker_stash')", 1, true))
        -- Every label a client message sends is a key of the NUI's Labels table, and every Labels key is sent.
        local jsKeys = {}
        local block = js:match('const Labels = (%b{})')
        t.ok(block, 'html/script.js defines Labels')
        local first, last = js:find('const Labels = ', 1, true)
        local outside = first and (js:sub(1, first - 1) .. js:sub(last + #(block or '') + 1)) or js
        -- (the Vue data defaults, e.g. connectLabel: "CONNECTED", are never shown: OpenCameras sets them first)
        for _, literal in ipairs({ 'MODEL: ', 'PLATE: ', 'KM/U', 'Fingerprint ID', 'No result', '= "CONNECTED"',
            '= "CONNECTION FAILED"', '= "ERROR' }) do
            t.ok(not outside:find(literal, 1, true), 'html/script.js still shows ' .. literal .. ' (outside Labels)')
        end
        for key in (block or ''):gmatch('([%a]+):') do jsKeys[key] = true end
        local sent = {}
        for _, path in ipairs({ 'client/job.lua', 'client/heli.lua', 'client/camera.lua' }) do
            for body in tr.files[path]:gmatch('labels = (%b{})') do
                for key, localeKey in body:gmatch("([%a]+) = locale%('([%w_%.]+)'%)") do
                    t.ok(jsKeys[key], path .. ': label ' .. key .. ' unknown to html/script.js')
                    sent[key] = localeKey
                end
            end
        end
        for key in pairs(jsKeys) do t.ok(sent[key], 'Labels.' .. key .. ' is never sent') end
        t.ok(js:find('setLabels(event.data.labels)', 1, true), 'the message listener applies labels')
        local en, sv = locales(tr)
        t.eq(sv['hud.heli_model'], 'Modell')
        t.eq(sv['menu.impound_engine'], 'Motor')
        t.ok(en['hud.fingerprint_id'] and sv['hud.fingerprint_id'] ~= en['hud.fingerprint_id'])
    end)
end

tests['every fredpd_audit action written by the patches has a label in locales/sv.json + en.json (or pending)'] = function(t)
    H.withTree(function(tr)
        local pending = helper.readJson('locales/pending/police.json')
        local sv, en = helper.readJson('locales/sv.json'), helper.readJson('locales/en.json')
        local actions = {}
        for _, path in ipairs({ 'fredpd/server.lua', 'server/main.lua' }) do
            for action in tr.files[path]:gmatch("audit%([^,]+, '([%w_%.]+)'") do actions[action] = true end
        end
        local names = {}
        for action in pairs(actions) do names[#names + 1] = action end
        table.sort(names)
        t.eq(names, { 'police.armory', 'police.fine', 'police.impound', 'police.jail' })
        for _, action in ipairs(names) do
            local key = 'audit.action.' .. action
            local label = pending[key] or (sv[key] and en[key] and { sv = sv[key], en = en[key] })
            t.ok(label and label.sv ~= '' and label.en ~= '', 'label for ' .. action)
        end
    end)
end

return tests
