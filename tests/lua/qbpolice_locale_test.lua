-- SPDX-License-Identifier: GPL-3.0-only
-- qb-policejob patch 40 'sv-locale': locales/sv.lua translates every key of locales/en.lua with the same %{name}
-- placeholders, follows docs/glossary.md, and qb-core's Locale picks it with `setr qb_locale sv` (the pattern of the
-- other qb-policejob locale files). Every Lang:t key the patches use exists; every audit action has a label.
-- Run: lua5.4 tests/lua/run.lua qbpolice_locale
local H = require('qbpolice_harness_test')
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

--- The Translations table of a qb-policejob locale file (Locale:new captured; qb_locale = lang).
local function phrases(tr, path, lang)
    local captured
    local G = setmetatable({
        GetConvar = function(_, default) return lang or default end,
        Locale = { new = function(_, opts) captured = opts.phrases return {} end },
    }, { __index = _G })
    assert(load(tr.files[path], '@' .. path, 't', G))()
    assert(captured, path .. ' did not call Locale:new for ' .. tostring(lang))
    return flatten(captured)
end

local function placeholders(s)
    local out = {}
    for p in s:gmatch('%%{([%w_]+)}') do out[#out + 1] = p end
    table.sort(out)
    return out
end

tests['sv.lua translates every en.lua key with the same %{placeholders}'] = function(t)
    H.withTree(function(tr)
        local en, sv = phrases(tr, 'locales/en.lua'), phrases(tr, 'locales/sv.lua', 'sv')
        local count = 0
        for key, text in pairs(en) do
            count = count + 1
            t.ok(type(sv[key]) == 'string' and sv[key] ~= '', 'missing sv: ' .. key)
            if sv[key] then t.eq(placeholders(sv[key]), placeholders(text), key) end
        end
        for key in pairs(sv) do t.ok(en[key] ~= nil, 'sv key not in en: ' .. key) end
        t.ok(count >= 200, 'en keys: ' .. count)
    end)
end

tests['sv.lua follows the glossary writing rules'] = function(t)
    H.withTree(function(tr)
        local en, sv = phrases(tr, 'locales/en.lua'), phrases(tr, 'locales/sv.lua', 'sv')
        local banned = { 'polisman', 'arrester', 'bolo', 'patronhylsa', 'bevisväska', 'tabletten', 'paddan' }
        for key, text in pairs(sv) do
            t.ok(not text:find('$', 1, true), key .. ': amounts in kr, never $')
            t.ok(not text:find('!', 1, true), key .. ': no exclamation marks')
            t.ok(not text:find('%.%.'), key .. ': ellipsis is …')
            local lower = text:lower()
            for _, word in ipairs(banned) do t.ok(not lower:find(word, 1, true), key .. ': avoid ' .. word) end
            t.ok(text ~= en[key] or not text:find('%a%a%a') or key == 'hud.heli_speed' or key == 'info.police_plate', key .. ': still English')
        end
        t.eq(sv['error.on_duty_police_only'], 'Endast för polis i tjänst')
        t.eq(sv['fredpd.no_permission'], 'Du har inte behörighet att göra det här')
        t.eq(sv['target.open_armory'], 'Öppna vapenförrådet')
        t.ok(utf8.len(sv['info.police_plate']) <= 4, 'plate prefix at most 4 characters (upstream comment)')
    end)
end

tests['qb-core Locale selects sv.lua with setr qb_locale sv; other languages fall back to en'] = function(t)
    H.withTree(function(tr)
        local manifest = tr.files['fxmanifest.lua']
        t.ok(manifest:find("'@qb-core/shared/locale.lua'", 1, true) and manifest:find("'locales/*.lua'", 1, true))
        local sv = tr.files['locales/sv.lua']
        t.ok(sv:find("GetConvar('qb_locale', 'en') == 'sv'", 1, true), 'same selection as locales/de.lua')
        local env = H.server({ players = H.cast(), convars = { qb_locale = 'sv' } })
        t.eq(env.G.Lang:t('fredpd.no_permission'), 'Du har inte behörighet att göra det här')
        t.eq(env.G.Lang:t('info.police_plate'), phrases(tr, 'locales/sv.lua', 'sv')['info.police_plate'])
        local de = H.server({ players = H.cast(), convars = { qb_locale = 'de' } })
        t.eq(de.G.Lang:t('fredpd.no_permission'), 'You are not authorised to do that', 'de falls back to en')
        local en = H.server({ players = H.cast() })
        t.eq(en.G.Lang:t('fredpd.armory_count', { count = 2 }), 'Quantity: 2')
    end)
end

tests['every Lang:t key used by the patched files exists in en.lua'] = function(t)
    H.withTree(function(tr)
        local en = phrases(tr, 'locales/en.lua')
        local used, n = {}, 0
        for path, src in pairs(tr.files) do
            if path:match('%.lua$') and not path:match('^locales/') then
                for key in src:gmatch("Lang:t%('([%w_%.]+)'") do used[key] = true end
                for key in src:gmatch("'(fredpd%.[%w_]+)'") do used[key] = true end
                for key in src:gmatch("= '(error%.[%w_]+)'") do used[key] = true end
            end
        end
        for key in pairs(used) do
            n = n + 1
            t.ok(en[key], 'missing en key ' .. key)
        end
        t.ok(used['fredpd.armory_taken'] and used['fredpd.bolo_radar'] and used['hud.heli_model'], 'FredPD keys scanned')
        t.ok(n > 150, 'keys used: ' .. n)
    end)
end

tests['hard-coded English in the NUI and the evidence drawer goes through the locale'] = function(t)
    H.withTree(function(tr)
        local job, js = tr.files['client/job.lua'], tr.files['html/script.js']
        t.ok(not job:find("submitText = 'open'", 1, true) and job:find("Lang:t('info.open')", 1, true))
        local block = js:match('const Labels = (%b{})')
        t.ok(block, 'html/script.js defines Labels')
        local jsKeys, sent = {}, {}
        for key in block:gmatch('([%a_]+):') do jsKeys[key] = true end
        for _, path in ipairs({ 'client/job.lua', 'client/heli.lua', 'client/camera.lua' }) do
            for body in tr.files[path]:gmatch('labels = (%b{})') do
                for key in body:gmatch("([%a_]+) = Lang:t%('hud%.[%w_]+'%)") do
                    t.ok(jsKeys[key], path .. ': label ' .. key .. ' unknown to html/script.js')
                    sent[key] = true
                end
            end
        end
        for key in pairs(jsKeys) do t.ok(sent[key], 'Labels.' .. key .. ' is never sent') end
    end)
end

tests['every fredpd_audit action written by the patches has a sv + en label (locales or pending)'] = function(t)
    H.withTree(function(tr)
        local pending = helper.readJson('locales/pending/police-qb.json')
        local sv, en = helper.readJson('locales/sv.json'), helper.readJson('locales/en.json')
        local actions = {}
        for path, src in pairs(tr.files) do
            if path:match('%.lua$') then
                for action in src:gmatch("audit%([^,]+, '([%w_%.]+)'") do actions[action] = true end
            end
        end
        t.ok(actions['police.armory'] and actions['police.impound'] and actions['police.jail']
            and actions['police.fine'] and actions['police.unjail'], 'audit actions found')
        for action in pairs(actions) do
            local key = 'audit.action.' .. action
            local p = pending[key]
            t.ok((sv[key] and en[key]) or (p and p.sv and p.en), 'label for ' .. key)
        end
    end)
end

return tests
