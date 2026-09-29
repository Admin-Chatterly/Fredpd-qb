-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_bolo pure modules: shared/input.lua (the Lua mirror of BoloCreateInput / BoloResolveInput / BoloListInput /
-- PlateSchema / CitizenIdSchema in packages/types/src/mdt.ts, plate normalisation consistent with detectSearchType)
-- and shared/view.lua (the plate-check context menu, markdown escaping, error texts). No database.
-- Run: lua5.4 tests/lua/run.lua bolo_input
local helper = require('helper')

local BOLO = './resources/[fredpd]/fredpd_bolo/'

local function load(name)
    local savedPath = package.path
    package.path = BOLO .. '?.lua;' .. package.path
    package.loaded[name] = nil
    local ok, mod = pcall(require, name)
    package.loaded[name] = nil
    package.path = savedPath
    if not ok then error(mod, 0) end
    return mod
end

local Input = load('shared.input')
local View = load('shared.view')

--- sv.json + pending/bolo.json (sv) with {placeholder} substitution, like fredpd_core's L().
local SV = (function()
    local dict = helper.readJson('locales/sv.json')
    for k, v in pairs(helper.readJson('locales/pending/bolo.json')) do
        if type(v) == 'table' and v.sv then dict[k] = v.sv end
    end
    return dict
end)()
local Locale = require('shared.locale')
local function L(key, vars) return Locale.substitute(SV[key] or key, vars) end

local tests = {}

tests['normalizePlate: upper case, whitespace removed, like fredpd_vehicles_idx and detectSearchType'] = function(t)
    t.eq(Input.normalizePlate('abc 12d'), 'ABC12D')
    t.eq(Input.normalizePlate('  ABC  12D '), 'ABC12D')
    t.eq(Input.normalizePlate('abc\t12d'), 'ABC12D')
    t.eq(Input.normalizePlate('46EEK572'), '46EEK572')
    t.eq(Input.normalizePlate('AB-123'), 'AB-123')
    t.eq(Input.normalizePlate(''), nil)
    t.eq(Input.normalizePlate('   '), nil)
    t.eq(Input.normalizePlate('ABCDEFGHIJKLMNOPQ'), nil, '17 characters')
    t.eq(Input.normalizePlate("ABC'1"), nil, 'quote')
    t.eq(Input.normalizePlate('ÅBC123'), nil, 'non-ASCII')
    t.eq(Input.normalizePlate(123), nil)
    t.eq(Input.normalizePlate(nil), nil)

    -- Same result as fredpd_core's search-type detection for a Swedish plate query.
    local Format = require('shared.format')
    local formats = helper.readJson('config/formats.json')
    for _, q in ipairs({ 'abc 12d', 'ABC12D', ' Abc 12D ' }) do
        local d = Format.detectSearchType(q, formats)
        t.eq(d.type, 'plate', q)
        t.eq(Input.normalizePlate(q), d.normalized, q)
    end
end

tests['citizenId mirrors CitizenIdSchema'] = function(t)
    t.eq(Input.citizenId('FPD10002'), 'FPD10002')
    t.eq(Input.citizenId('a_b-9'), 'a_b-9')
    t.eq(Input.citizenId(''), nil)
    t.eq(Input.citizenId(('A'):rep(51)), nil)
    t.eq(Input.citizenId('FPD 1'), nil)
    t.eq(Input.citizenId("x' OR 1=1"), nil)
    t.eq(Input.citizenId(5), nil)
end

tests['validateCreate: kinds, exclusive subject, reason 3..500, level 0..2 default 0, hours 1..720'] = function(t)
    t.eq(Input.validateCreate({ kind = 'vehicle', plate = 'abc 12d', reason = '  Rån mot butik  ' }),
        { kind = 'vehicle', plate = 'ABC12D', reason = 'Rån mot butik', level = 0 })
    t.eq(Input.validateCreate({ kind = 'person', citizenid = 'FPD10002', reason = 'Efterlyst', level = 2,
        expiresInHours = 720.0 }),
        { kind = 'person', citizenid = 'FPD10002', reason = 'Efterlyst', level = 2, expiresInHours = 720 })
    local function field(input)
        local v, f = Input.validateCreate(input)
        t.eq(v, nil)
        return f
    end
    t.eq(field(nil), 'input')
    t.eq(field({ kind = 'boat', plate = 'ABC12D', reason = 'xyz' }), 'kind')
    t.eq(field({ kind = 'vehicle', reason = 'xyz' }), 'plate')
    t.eq(field({ kind = 'vehicle', plate = 'ABC12D', citizenid = 'FPD1', reason = 'xyz' }), 'citizenid')
    t.eq(field({ kind = 'person', plate = 'ABC12D', citizenid = 'FPD1', reason = 'xyz' }), 'plate')
    t.eq(field({ kind = 'person', reason = 'xyz' }), 'citizenid')
    t.eq(field({ kind = 'vehicle', plate = '', reason = 'xyz' }), 'plate')
    t.eq(field({ kind = 'vehicle', plate = ('A'):rep(17), reason = 'xyz' }), 'plate')
    t.eq(field({ kind = 'vehicle', plate = 'ABC12D', reason = '  ab ' }), 'reason')
    t.eq(field({ kind = 'vehicle', plate = 'ABC12D', reason = ('å'):rep(501) }), 'reason')
    t.eq(field({ kind = 'vehicle', plate = 'ABC12D', reason = 'abc\255' }), 'reason', 'invalid UTF-8')
    t.eq(field({ kind = 'vehicle', plate = 'ABC12D', reason = 'xyz', level = 3 }), 'level')
    t.eq(field({ kind = 'vehicle', plate = 'ABC12D', reason = 'xyz', level = 1.5 }), 'level')
    t.eq(field({ kind = 'vehicle', plate = 'ABC12D', reason = 'xyz', level = '1' }), 'level')
    t.eq(field({ kind = 'vehicle', plate = 'ABC12D', reason = 'xyz', expiresInHours = 0 }), 'expiresInHours')
    t.eq(field({ kind = 'vehicle', plate = 'ABC12D', reason = 'xyz', expiresInHours = 721 }), 'expiresInHours')
    -- 500 characters (not bytes) is the limit; control characters become spaces, newlines stay.
    t.ok(Input.validateCreate({ kind = 'vehicle', plate = 'ABC12D', reason = ('å'):rep(500) }))
    t.eq(Input.validateCreate({ kind = 'vehicle', plate = 'ABC12D', reason = 'rad 1\r\nrad\0 2' }).reason,
        'rad 1\nrad  2')
end

tests['validateResolve and validateList mirror their schemas (defaults included)'] = function(t)
    t.eq(Input.validateResolve({ id = 4 }), { id = 4 })
    t.eq(Input.validateResolve({ id = 4.0, note = '  Gripen vid Legion  ' }), { id = 4, note = 'Gripen vid Legion' })
    t.eq(Input.validateResolve({ id = 4, note = '   ' }), { id = 4 })
    t.eq(select(2, Input.validateResolve({ id = 0 })), 'id')
    t.eq(select(2, Input.validateResolve({ id = '4' })), 'id')
    t.eq(select(2, Input.validateResolve({ id = 4, note = ('x'):rep(501) })), 'note')
    t.eq(select(2, Input.validateResolve({ id = 4, note = 5 })), 'note')
    t.ok(Input.validateResolve({ id = 4, note = ('x'):rep(500) }))

    t.eq(Input.validateList(nil), { active = true, page = 1 })
    t.eq(Input.validateList({}), { active = true, page = 1 })
    t.eq(Input.validateList({ active = false, page = 3 }), { active = false, page = 3 })
    t.eq(select(2, Input.validateList({ active = 'yes' })), 'active')
    t.eq(select(2, Input.validateList({ page = 0 })), 'page')
    t.eq(select(2, Input.validateList({ page = 10001 })), 'page')

    t.eq(Input.validatePlateInput({ plate = ' abc 12d ' }), 'ABC12D')
    t.eq(select(2, Input.validatePlateInput({ plate = '' })), 'plate')
    t.eq(select(2, Input.validatePlateInput({})), 'plate')
end

tests['view.escape: markdown punctuation escaped, control characters removed'] = function(t)
    t.eq(View.escape('ABC 12D'), 'ABC 12D')
    t.eq(View.escape('[x](http://a)'), '\\[x\\]\\(http\\:\\/\\/a\\)')
    t.eq(View.escape('![img](u) **b** _i_ # h'), '\\!\\[img\\]\\(u\\) \\*\\*b\\*\\* \\_i\\_ \\# h')
    t.eq(View.escape('rad\nny'), 'rad ny')
    t.eq(View.escape(nil), '')
end

tests['view.menu: a hit is the first, red row; owner, model; clear and unregistered variants'] = function(t)
    local hit = View.menu({
        plate = 'ABC12D', model = 'sultan', owner = { citizenid = 'FPD10002', name = 'Erik Lindqvist' },
        bolo = { id = 3, kind = 'vehicle', plate = 'ABC12D', subject = 'ABC12D · sultan', reason = 'Rån [länk](x)',
            level = 1, issuedBy = { citizenid = 'BOL10002', displayName = 'Bo C.', callsign = 'SPAN-02' },
            expiresAt = '2026-09-29T12:00:00Z', active = true, createdAt = '2026-09-29T10:00:00Z' },
        checkedAt = '2026-09-29T10:05:00Z',
    }, L, function() return '2026-09-29 14:00' end)
    t.eq(hit.id, View.MENU_ID)
    t.eq(hit.title, 'Skyltkontroll: ABC12D')
    local first = hit.options[1]
    t.eq(first.title, 'Träff på efterlysning')
    t.eq(first.description, 'ABC12D är efterlyst: Rån \\[länk\\]\\(x\\)')
    t.eq(first.iconColor, View.HIT_COLOR)
    t.eq(first.colorScheme, 'red')
    t.eq(first.progress, 100)
    t.eq(first.readOnly, true)
    t.eq(first.metadata, {
        { label = 'Sekretessnivå', value = 'Begränsad' },
        { label = 'Utfärdad av', value = 'Bo C. (SPAN-02)' },
        { label = 'Gäller till', value = '2026-09-29 14:00' },
    })
    t.eq(hit.options[2].title, 'Ägare: Erik Lindqvist')
    t.eq(hit.options[3].title, 'Modell: sultan')

    -- a kontaktnotis (no issuedBy): the notice text, but not whether it is Begränsad or Hemlig
    local notice = View.menu({
        plate = 'HEM11T', bolo = { id = 4, kind = 'vehicle', plate = 'HEM11T', subject = 'HEM11T · kuruma',
            reason = 'Det finns uppgifter som rör HEM11T · kuruma. Kontakta Eva L. (LED-01).', level = 2,
            active = true, createdAt = '2026-09-29T10:20:00Z' },
        checkedAt = '2026-09-29T10:25:00Z',
    }, L, function() return '2026-09-29 14:00' end)
    t.eq(notice.options[1].title, 'Träff på efterlysning')
    t.eq(notice.options[1].colorScheme, 'red')
    t.eq(notice.options[1].metadata, nil, 'no level row')
    t.ok(notice.options[1].description:find('Kontakta Eva L', 1, true), notice.options[1].description)

    local clear = View.menu({ plate = 'KLM34E', owner = { citizenid = 'X', name = 'Sara *Öberg*' },
        checkedAt = '2026-09-29T10:05:00Z' }, L)
    t.eq(#clear.options, 2)
    t.eq(clear.options[1].title, 'KLM34E: ingen aktiv efterlysning.')
    t.eq(clear.options[1].iconColor, View.CLEAR_COLOR)
    t.eq(clear.options[2].title, 'Ägare: Sara \\*Öberg\\*')

    local unregistered = View.menu({ plate = 'ZZZ99Z', checkedAt = '2026-09-29T10:05:00Z' }, L)
    t.eq(unregistered.options[2].title, 'ZZZ99Z: fordonet finns inte i registret.')
end

tests['view.errorText: Swedish text per server error'] = function(t)
    t.eq(View.errorText({ error = 'unauthorized', reason = 'off_duty' }, L), 'Du är inte i tjänst.')
    t.eq(View.errorText({ error = 'unauthorized' }, L), 'Du har inte behörighet att göra det här.')
    t.eq(View.errorText({ error = 'rate_limited' }, L), 'För många förfrågningar. Vänta en stund och försök igen.')
    t.eq(View.errorText({ error = 'validation', reason = 'too_far' }, L), 'Du är för långt bort.')
    t.eq(View.errorText({ error = 'not_found', reason = 'no_plate' }, L), 'Fordonet saknar läsbar skylt.')
    t.eq(View.errorText({ error = 'not_found' }, L), 'Uppgiften hittades inte.')
    t.eq(View.errorText({ error = 'unavailable' }, L), 'Tjänsten är inte tillgänglig just nu. Försök igen om en stund.')
    t.eq(View.errorText({ error = 'validation' }, L), 'Något gick fel. Försök igen.')
end

return tests
