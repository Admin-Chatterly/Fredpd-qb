-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_dispatch/shared/alert_input.lua (pure): createAlert validation (AlertCreateInputSchema mirror), ps-dispatch
-- normalisation incl. hostile data, tablet action inputs and the sliding-window limiter.
-- Run: lua5.4 tests/lua/run.lua dispatch_input
local DISPATCH = './resources/[fredpd]/fredpd_dispatch/'

local function load()
    local chunk = assert(loadfile(DISPATCH .. 'shared/alert_input.lua'))
    return chunk()
end
local Input = load()

local tests = {}

--- L stand-in: key + vars, so tests can see which label was used.
local function L(key, vars)
    return key .. '(' .. (vars and (vars.value or vars.radius) or '') .. ')'
end

--- A stored ps-dispatch Shooting() call; `false` in overrides removes a field.
local function shooting(overrides)
    local d = {
        message = 'Shots Fired', codeName = 'shooting', code = '10-11', icon = 'fas fa-gun', priority = 2,
        coords = { x = 215.3, y = -920.1, z = 30.7 }, street = 'Vespucci Blvd, Legion Square', gender = 'Male',
        weapon = 'Pistol', weaponClass = 'pistol', weaponTier = 1, jobs = { 'leo' }, id = 17, units = {},
        responses = {}, count = 1, listed = true, time = 1790000000000,
    }
    for k, v in pairs(overrides or {}) do
        if v == false then d[k] = nil else d[k] = v end
    end
    return d
end

---------------------------------------------------------------------------------------------------------------
-- Text cleaning

tests['cleanText trims, removes control characters and keeps newlines only when multi-line'] = function(t)
    t.eq(Input.cleanText('  hej  '), 'hej')
    t.eq(Input.cleanText('a\0b\7c\27d'), 'abcd')
    t.eq(Input.cleanText('rad1\r\nrad2\ttab', 100, false), 'rad1  rad2 tab')
    t.eq(Input.cleanText('rad1\r\nrad2\rrad3', 100, true), 'rad1\nrad2\nrad3')
    t.eq(Input.cleanText('   '), nil)
    t.eq(Input.cleanText(''), nil)
    t.eq(Input.cleanText(nil), nil)
    t.eq(Input.cleanText({}), nil)
    t.eq(Input.cleanText(911, 16), '911')
    t.eq(Input.cleanText(10.0, 16), '10')
    t.eq(Input.cleanText(0 / 0, 16), nil)
end

tests['cleanText drops invalid UTF-8 and counts characters, not bytes'] = function(t)
    local s, n = Input.cleanText('Åsa \255\254Öberg \192')
    t.eq(s, 'Åsa Öberg')
    t.eq(n, 9)
    local _, m = Input.cleanText('ÅÄÖåäö')
    t.eq(m, 6)
    t.eq(Input.cleanText('\237\160\128x'), 'x', 'a UTF-16 surrogate is not valid UTF-8')
end

tests['capText cuts at a character boundary and bounds the work on huge strings'] = function(t)
    t.eq(Input.capText(('å'):rep(200), 160), ('å'):rep(160))
    t.eq(utf8.len(Input.capText(('å'):rep(200), 160)), 160)
    t.eq(Input.capText('abc def', 4), 'abc', 'trailing space after the cut is trimmed')
    local huge = ('x'):rep(1024 * 1024)
    local started = os.clock()
    local s = Input.capText(huge, 160)
    t.eq(#s, 160)
    local spaces = (' '):rep(200000) .. 'x' .. (' '):rep(200000)
    t.eq(Input.capText(spaces, 1000), nil, 'only the first ~4 KB are looked at: all whitespace')
    t.ok(os.clock() - started < 1, 'capping a 1 MB string must be cheap')
end

---------------------------------------------------------------------------------------------------------------
-- Coords, priority

tests['coords accepts vector-like tables with finite numbers within ±10000'] = function(t)
    t.eq(Input.coords({ x = 1, y = -2.5, z = 30 }), { x = 1.0, y = -2.5, z = 30.0 })
    t.eq(Input.coords({ x = 10000, y = -10000, z = 0 }), { x = 10000.0, y = -10000.0, z = 0.0 })
    t.eq(Input.coords({ x = 10000.5, y = 0, z = 0 }), nil)
    t.eq(Input.coords({ x = 0 / 0, y = 0, z = 0 }), nil, 'NaN')
    t.eq(Input.coords({ x = math.huge, y = 0, z = 0 }), nil, 'inf')
    t.eq(Input.coords({ x = '1', y = 0, z = 0 }), nil, 'strings are not coordinates')
    t.eq(Input.coords({ x = 1, y = 2 }), nil, 'z missing')
    t.eq(Input.coords('1,2,3'), nil)
    t.eq(Input.coords(nil), nil)
end

tests['clampPriority clamps to 1..3 and defaults to 2'] = function(t)
    t.eq(Input.clampPriority(1), 1)
    t.eq(Input.clampPriority(0), 1, "ps-dispatch's critical tier")
    t.eq(Input.clampPriority(-5), 1)
    t.eq(Input.clampPriority(99), 3)
    t.eq(Input.clampPriority(2.4), 2)
    t.eq(Input.clampPriority('3'), 3)
    t.eq(Input.clampPriority(0 / 0), 2)
    t.eq(Input.clampPriority(nil), 2)
    t.eq(Input.clampPriority({}), 2)
    t.eq(math.type(Input.clampPriority(3.0)), 'integer')
end

---------------------------------------------------------------------------------------------------------------
-- validateCreate (createAlert export)

tests['validateCreate accepts a full AlertCreateInput and trims text'] = function(t)
    local v = Input.validateCreate({
        code = ' 10-11 ', title = ' Skottlossning ', description = 'rad1\nrad2', coords = { x = 1, y = 2, z = 3 },
        street = 'Vespucci Blvd', priority = 1, source = 'bolo', meta = { plate = 'ABC12D', hit = true, n = 2 },
    })
    t.eq(v, {
        code = '10-11', title = 'Skottlossning', description = 'rad1\nrad2', coords = { x = 1.0, y = 2.0, z = 3.0 },
        street = 'Vespucci Blvd', priority = 1, source = 'bolo', meta = { plate = 'ABC12D', hit = true, n = 2 },
    })
end

tests['validateCreate applies defaults and the message alias'] = function(t)
    local v = Input.validateCreate({ code = 'dev', message = 'Testlarm', source = 'fredpd_devtools' })
    t.eq(v, { code = 'dev', title = 'Testlarm', priority = 2, source = 'fredpd_devtools' })
    local w = Input.validateCreate({ code = 'x', title = 'T', message = 'ignored', source = 's' })
    t.eq(w.title, 'T', 'title wins over message')
end

tests['validateCreate rejects what zod rejects'] = function(t)
    local base = { code = '10-11', title = 'T', source = 'bolo' }
    local function with(k, v)
        local d = {}
        for key, val in pairs(base) do d[key] = val end
        d[k] = v
        return d
    end
    local cases = {
        { with('code', nil), 'code' }, { with('code', '   '), 'code' }, { with('code', ('x'):rep(17)), 'code' },
        { with('code', 1011), 'code' }, { with('title', nil), 'title' }, { with('title', ('t'):rep(161)), 'title' },
        { with('description', ('d'):rep(1001)), 'description' }, { with('street', ('s'):rep(129)), 'street' },
        { with('priority', 0), 'priority' }, { with('priority', 4), 'priority' }, { with('priority', 1.5), 'priority' },
        { with('priority', '1'), 'priority' }, { with('source', nil), 'source' }, { with('source', ('s'):rep(33)), 'source' },
        { with('coords', { x = 0 / 0, y = 0, z = 0 }), 'coords' }, { with('coords', { x = 1, y = 2, z = 20000 }), 'coords' },
        { with('meta', 'x'), 'meta' },
    }
    for i, c in ipairs(cases) do
        local v, field = Input.validateCreate(c[1])
        t.eq(v, nil, 'case ' .. i)
        t.eq(field, c[2], 'case ' .. i)
    end
    t.eq(select(2, Input.validateCreate('x')), 'input')
    t.ok(Input.validateCreate(with('title', ('å'):rep(160))), '160 characters (320 bytes) is fine')
    t.ok(Input.validateCreate(with('priority', 3.0)), 'an integral float priority is fine (JSON)')
end

tests['sanitizeMeta keeps only safe, bounded entries'] = function(t)
    local meta = { ok = 'v', n = 1.5, b = false, nan = 0 / 0, tbl = { 1 }, fn = print, [1] = 'array', long = ('x'):rep(300) }
    local out = Input.sanitizeMeta(meta)
    t.eq(out.ok, 'v')
    t.eq(out.n, 1.5)
    t.eq(out.b, false)
    t.eq(out.nan, nil)
    t.eq(out.tbl, nil)
    t.eq(out.fn, nil)
    t.eq(out[1], nil)
    t.eq(utf8.len(out.long), 256)
    local many = {}
    for i = 1, 1000 do many[('k%04d'):format(i)] = i end
    local capped = Input.sanitizeMeta(many)
    local n = 0
    for _ in pairs(capped) do n = n + 1 end
    t.eq(n, Input.META_MAX_KEYS)
    t.eq(Input.sanitizeMeta({}), nil)
end

---------------------------------------------------------------------------------------------------------------
-- ps-dispatch normalisation

tests['fromPsDispatch maps a Shooting() call to AlertCreateInput'] = function(t)
    local v = Input.fromPsDispatch(shooting(), L)
    t.eq(v.code, '10-11')
    t.eq(v.title, 'Shots Fired')
    t.eq(v.coords, { x = 215.3, y = -920.1, z = 30.7 })
    t.eq(v.street, 'Vespucci Blvd, Legion Square')
    t.eq(v.priority, 2)
    t.eq(v.source, 'ps-dispatch')
    t.eq(v.description, 'alert.detail.weapon(Pistol)')
    t.eq(v.meta, { psId = 17, codeName = 'shooting', icon = 'fas fa-gun', gender = 'Male', weapon = 'Pistol',
        weaponClass = 'pistol', weaponTier = 1 })
end

tests['fromPsDispatch builds the description from information, vehicle and caller'] = function(t)
    local v = Input.fromPsDispatch(shooting({
        information = 'Misstänkt flyr till fots\nmot gränden', vehicle = 'Sultan RS', plate = 'PS 12345',
        color = 'Metallic Red', weapon = false, name = 'John Doe', number = '555-0173', automaticGunFire = true,
    }), L)
    t.eq(v.description, 'Misstänkt flyr till fots\nmot gränden\nalert.detail.vehicle(Sultan RS · PS 12345 · Metallic Red)'
        .. '\nalert.detail.caller(John Doe · 555-0173)')
    t.eq(v.meta.automaticGunFire, true)
    t.eq(v.meta.plate, 'PS 12345')
end

tests['fromPsDispatch: hostile data is capped, clamped or rejected'] = function(t)
    local huge = ('A'):rep(2 * 1024 * 1024)
    local v = Input.fromPsDispatch(shooting({ message = huge, street = huge, information = huge, code = huge,
        weapon = huge, priority = 99 }), L)
    t.eq(utf8.len(v.title), 160)
    t.eq(utf8.len(v.street), 128)
    t.eq(utf8.len(v.code), 16)
    t.ok(utf8.len(v.description) <= 1000)
    t.eq(v.priority, 3, 'priority 99 -> 3')
    t.eq(utf8.len(v.meta.weapon), 64)

    t.eq(select(2, Input.fromPsDispatch(shooting({ coords = { x = 0 / 0, y = 1, z = 1 } }), L)), 'coords', 'NaN')
    t.eq(select(2, Input.fromPsDispatch(shooting({ coords = { x = 1e308, y = 1, z = 1 } }), L)), 'coords')
    t.eq(select(2, Input.fromPsDispatch(shooting({ coords = 'here' }), L)), 'coords')
    t.eq(select(2, Input.fromPsDispatch(shooting({ message = false }), L)), 'title')
    t.eq(select(2, Input.fromPsDispatch(shooting({ message = { 'x' } }), L)), 'title')
    t.eq(select(2, Input.fromPsDispatch(shooting({ message = '\0\1\2' }), L)), 'title')
    t.eq(select(2, Input.fromPsDispatch(shooting({ code = false, codeName = false }), L)), 'code')
    t.eq(Input.fromPsDispatch(shooting({ code = false }), L).code, 'shooting', 'codeName when code is missing')
    t.eq(Input.fromPsDispatch(shooting({ code = 911 }), L).code, '911', 'numeric code')
    t.eq(select(2, Input.fromPsDispatch('x', L)), 'input')
    t.eq(select(2, Input.fromPsDispatch(nil, L)), 'input')

    local sparse = Input.fromPsDispatch({ message = 'Bråk', code = '10-10' }, L)
    t.eq(sparse, { code = '10-10', title = 'Bråk', priority = 2, source = 'ps-dispatch' }, 'missing fields allowed')
    local odd = Input.fromPsDispatch(shooting({ priority = 'high', street = 42, id = -3, weaponTier = 0 / 0,
        heading = 1e12, automaticGunFire = 'yes' }), L)
    t.eq(odd.priority, 2)
    t.eq(odd.street, '42')
    t.eq(odd.meta.psId, nil)
    t.eq(odd.meta.weaponTier, nil)
    t.eq(odd.meta.heading, nil)
    t.eq(odd.meta.automaticGunFire, nil)
end

tests['fromPsDispatch never copies unlisted fields (units, jobs, coords, time …) into meta'] = function(t)
    local v = Input.fromPsDispatch(shooting({ secret = 'x', citizenid = 'ABC',
        displayCoords = { x = 1, y = 2, z = 3 } }), L)
    for _, k in ipairs({ 'units', 'jobs', 'coords', 'time', 'responses', 'listed', 'count', 'secret', 'citizenid',
        'displayCoords', 'id', 'message' }) do
        t.eq(v.meta[k], nil, k)
    end
end

tests['fromPsDispatch: offset alerts keep the approximate position; the true one goes to meta only'] = function(t)
    local v = Input.fromPsDispatch(shooting({ displayCoords = { x = 260, y = -900.5, z = 30.7 }, mapRadius = 110.0 }), L)
    t.eq(v.coords, { x = 260.0, y = -900.5, z = 30.7 }, 'displayCoords: what ps-dispatch shows officers')
    t.eq({ v.meta.exactX, v.meta.exactY, v.meta.exactZ }, { 215.3, -920.1, 30.7 })
    t.eq(v.meta.mapRadius, 110.0)
    t.eq(v.description, 'alert.detail.area(110)\nalert.detail.weapon(Pistol)', 'search radius in the description')

    local info = Input.fromPsDispatch(shooting({ displayCoords = { x = 1, y = 2, z = 3 }, mapRadius = 59.6,
        information = 'Två skott' }), L)
    t.eq(info.description, 'Två skott\nalert.detail.area(60)\nalert.detail.weapon(Pistol)')

    local noRadius = Input.fromPsDispatch(shooting({ displayCoords = { x = 1, y = 2, z = 3 } }), L)
    t.eq(noRadius.coords, { x = 1.0, y = 2.0, z = 3.0 })
    t.eq(noRadius.description, 'alert.detail.weapon(Pistol)', 'no usable radius: no area line')
    for _, r in ipairs({ 0 / 0, 1 / 0, -5, 0, 1e6, '110', true }) do
        t.eq(Input.fromPsDispatch(shooting({ displayCoords = { x = 1, y = 2, z = 3 }, mapRadius = r }), L).description,
            'alert.detail.weapon(Pistol)', 'mapRadius ' .. tostring(r))
    end
    t.eq(Input.psRadius(0.2), 1)
    t.eq(math.type(Input.psRadius(75.0)), 'integer')

    t.eq(select(2, Input.fromPsDispatch(shooting({ displayCoords = { x = 1 } }), L)), 'coords', 'incomplete')
    t.eq(select(2, Input.fromPsDispatch(shooting({ displayCoords = { x = 0 / 0, y = 0, z = 0 } }), L)), 'coords')
    t.eq(select(2, Input.fromPsDispatch(shooting({ displayCoords = { x = 20000, y = 0, z = 0 } }), L)), 'coords')
    t.eq(select(2, Input.fromPsDispatch(shooting({ displayCoords = 'here' }), L)), 'coords')

    local exact = Input.fromPsDispatch(shooting({ mapRadius = 15.0 }), L)
    t.eq(exact.coords, { x = 215.3, y = -920.1, z = 30.7 }, 'no displayCoords: the reported position')
    t.eq(exact.meta.exactX, nil)
    t.eq(exact.description, 'alert.detail.weapon(Pistol)', 'exact position: no area line')
end

tests['isPoliceCall accepts leo/police calls and drops EMS-only ones'] = function(t)
    t.eq(Input.isPoliceCall({ jobs = { 'leo' } }), true)
    t.eq(Input.isPoliceCall({ jobs = { 'ems', 'police' } }), true)
    t.eq(Input.isPoliceCall({ jobs = { 'ems' } }), false)
    t.eq(Input.isPoliceCall({ jobs = 'leo' }), true)
    t.eq(Input.isPoliceCall({ jobs = 5 }), false)
    t.eq(Input.isPoliceCall({}), true, "ps-dispatch's default audience is leo")
    t.eq(Input.isPoliceCall(nil), false)
    local long = {}
    for i = 1, 100 do long[i] = 'ems' end
    long[100] = 'leo'
    t.eq(Input.isPoliceCall({ jobs = long }), false, 'only the first 16 entries are looked at')
end

---------------------------------------------------------------------------------------------------------------
-- Tablet inputs, limiter

tests['alertId and listInput mirror AlertIdInputSchema / AlertListInputSchema'] = function(t)
    t.eq(Input.alertId({ id = 5 }), 5)
    t.eq(Input.alertId({ id = 5.0 }), 5)
    t.eq(Input.alertId({ id = 5.5 }), nil)
    t.eq(Input.alertId({ id = 0 }), nil)
    t.eq(Input.alertId({ id = -1 }), nil)
    t.eq(Input.alertId({ id = '5' }), nil)
    t.eq(Input.alertId({ id = 4294967296 }), nil)
    t.eq(Input.alertId({ id = 0 / 0 }), nil)
    t.eq(Input.alertId(nil), nil)
    t.eq(Input.listInput(nil), { filter = 'open', page = 1 })
    t.eq(Input.listInput({}), { filter = 'open', page = 1 })
    t.eq(Input.listInput({ filter = 'mine', page = 3 }), { filter = 'mine', page = 3 })
    t.eq(Input.listInput({ filter = 'all', page = 2.0 }), { filter = 'all', page = 2 })
    t.eq(Input.listInput({ filter = 'closed' }), nil)
    t.eq(Input.listInput({ page = 0 }), nil)
    t.eq(Input.listInput({ page = 10001 }), nil)
    t.eq(Input.listInput({ page = '1' }), nil)
    t.eq(Input.listInput('open'), nil)
end

tests['newLimiter is a sliding window per key; refused calls do not count'] = function(t)
    local lim = Input.newLimiter(5, 30000)
    for i = 1, 5 do t.eq(lim.allow(7, i * 1000), true, 'call ' .. i) end
    t.eq(lim.allow(7, 6000), false, '6th within 30 s')
    t.eq(lim.allow(8, 6000), true, 'other key unaffected')
    t.eq(lim.allow(7, 30999), false, 'first call still inside the window')
    t.eq(lim.allow(7, 31001), true, 'first call left the window')
    t.eq(lim.allow(7, 31002), false)
    lim.clear(7)
    t.eq(lim.allow(7, 31003), true, 'cleared')
    local one = Input.newLimiter(1, 1000)
    t.eq(one.allow('a', 0), true)
    t.eq(one.allow('a', 999), false)
    t.eq(one.allow('a', 1000), true)
end

return tests
