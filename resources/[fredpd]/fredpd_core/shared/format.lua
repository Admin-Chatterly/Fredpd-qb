-- SPDX-License-Identifier: GPL-3.0-only
-- Identifier formats, search-type detection and date/time/currency formatting (docs/contracts.md §C4).
-- Lua port of packages/types/src/format.ts; both run packages/types/test/fixtures/format.fixtures.json.
--
-- API (formats argument optional everywhere; defaults to the table given to M.load):
--   M.load(tbl)                          validate + compile config/formats.json, make it active; returns it
--   M.formatId(template, ctx, formats)   ctx = { seq?, n?, unit?, case?, date? }  ->  'K-123-26'
--   M.templateToRegex(name, formats)     anchored pattern string for caseNumber/reportNumber/evidenceTag/callsign
--   M.detectSearchType(query, formats)   -> { type = 'plate'|'caseNumber'|'personId'|'name', normalized = '...' }
--   M.formatDate(iso), M.formatTime(iso), M.formatCurrency(amount)
--
-- Errors are raised (level 0) as "<code>: <detail>" with code one of unknown_placeholder, missing_value,
-- invalid_value, invalid_template, invalid_regex, invalid_config, not_loaded. Callers can recover the code
-- with err:match('^([%w_]+):').
--
-- Time zones: Lua has no tz database, so the port knows a few zones that follow the EU rule (DST from 01:00 UTC
-- on the last Sunday of March to 01:00 UTC on the last Sunday of October) and computes everything from the UTC
-- epoch with integer arithmetic. It never calls os.date/os.time, so the machine's TZ cannot leak in.
-- The EU rule is applied to every year, so the two ports agree only for instants from 1996-01-01T00:00Z on.
-- Earlier instants can differ by an hour for whole seasons (Sweden had no DST 1950-1979; London kept UTC+1 all
-- year 1968-71; 1980-95 switched back in late September) and Helsinki before 1921 by local-mean-time minutes.
-- Date-only strings ('1975-07-01', e.g. dates of birth) still render the same date in both ports, because every
-- supported zone's offset is between 0 and +3 h; pass dates of birth that way, never as a time of day.
-- Instants outside 1900-01-01..9999-12-31 UTC raise invalid_value (both ports).
--
-- Compiled formats are cached by table identity: a formats table (the one passed in, and the normalised one
-- M.load/M.get return) is treated as immutable once used. Build a new table instead of mutating one.

local M = {}

-- ox_lib `require` resolves '@fredpd_core.shared.regex' from any resource; plain Lua tests use package.path.
local function loadRegex()
    local ok, mod = pcall(require, '@fredpd_core.shared.regex')
    if ok and type(mod) == 'table' then return mod end
    return require('shared.regex')
end
local Regex = loadRegex()

--- Zones the Lua port can convert to: base UTC offset in minutes and whether the EU DST rule applies.
--- Keep in sync with SUPPORTED_TIME_ZONES in format.ts.
local TIME_ZONES = {
    ['Europe/Stockholm'] = { base = 60, eu = true },
    ['Europe/Oslo'] = { base = 60, eu = true },
    ['Europe/Copenhagen'] = { base = 60, eu = true },
    ['Europe/Berlin'] = { base = 60, eu = true },
    ['Europe/Helsinki'] = { base = 120, eu = true },
    ['Europe/London'] = { base = 0, eu = true },
    ['UTC'] = { base = 0, eu = false },
}

local FORMAT_NAMES = { 'callsign', 'caseNumber', 'reportNumber', 'evidenceTag' }
local PLACEHOLDERS = { seq = true, n = true, yy = true, yyyy = true, unit = true, case = true }
local COUNTERS = { seq = true, n = true } -- placeholders that accept a :width
local MAX_WIDTH = 20
local MAX_SAFE_INTEGER = 9007199254740991 -- 2^53 - 1, same limit as JS Number.MAX_SAFE_INTEGER

local function fail(code, detail)
    error(('%s: %s'):format(code, detail), 0)
end

------------------------------------------------------------------------------------------------------------
-- Templates
------------------------------------------------------------------------------------------------------------

--- Split a template into literal and placeholder tokens. Raises unknown_placeholder / invalid_template.
local function parseTemplate(template)
    if type(template) ~= 'string' then fail('invalid_template', 'template must be a string') end
    local tokens = {}
    local function literal(text)
        if text == '' then return end
        if text:find('{{', 1, true) or text:find('}}', 1, true) then
            fail('invalid_template', ('unbalanced braces in "%s"'):format(template))
        end
        tokens[#tokens + 1] = { literal = text }
    end
    local pos = 1
    for s, inner, e in template:gmatch('(){{([^{}]*)}}()') do
        literal(template:sub(pos, s - 1))
        local name, width = inner:match('^(%l+):(%d+)$')
        if not name then name = inner:match('^(%l+)$') end
        if not name or not PLACEHOLDERS[name] or (width and not COUNTERS[name]) then
            fail('unknown_placeholder', ('{{%s}} in "%s"'):format(inner, template))
        end
        local w
        if width then
            w = tonumber(width)
            if w < 1 or w > MAX_WIDTH then
                fail('invalid_template', ('width must be 1..%d in {{%s}}'):format(MAX_WIDTH, inner))
            end
        end
        tokens[#tokens + 1] = { name = name, width = w }
        pos = e
    end
    literal(template:sub(pos))
    return tokens
end

local REGEX_SPECIAL = {} -- same set as the TS escape: . * + ? ^ $ { } ( ) | [ ] \
for c in ('.*+?^${}()|[]\\'):gmatch('.') do REGEX_SPECIAL[c] = true end

local function escapeRegex(text)
    return (text:gsub('.', function(c) return REGEX_SPECIAL[c] and ('\\' .. c) or c end))
end

--- Regex body (no anchors) for a template; caseBody is the caseNumber body used for {{case}}.
local function templateBody(tokens, caseBody)
    local out = {}
    for _, tok in ipairs(tokens) do
        local part
        if tok.literal then
            part = escapeRegex(tok.literal)
        elseif tok.name == 'seq' or tok.name == 'n' then
            part = tok.width and ('\\d{' .. tok.width .. ',}') or '\\d+'
        elseif tok.name == 'yy' then
            part = '\\d{2}'
        elseif tok.name == 'yyyy' then
            part = '\\d{4}'
        elseif tok.name == 'unit' then
            part = '[A-Z]+'
        else -- case
            if not caseBody then fail('invalid_template', 'caseNumber cannot contain {{case}}') end
            part = caseBody
        end
        out[#out + 1] = part
    end
    return table.concat(out)
end

------------------------------------------------------------------------------------------------------------
-- Dates (pure arithmetic on the UTC epoch)
------------------------------------------------------------------------------------------------------------

-- Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's days_from_civil; `//` floors).
local function daysFromCivil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = y // 400
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = (153 * mp + 2) // 5 + d - 1
    local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468
end

local function civilFromDays(z)
    z = z + 719468
    local era = z // 146097
    local doe = z - era * 146097
    local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    local mp = (5 * doy + 2) // 153
    local d = doy - (153 * mp + 2) // 5 + 1
    local m = mp < 10 and mp + 3 or mp - 9
    if m <= 2 then y = y + 1 end
    return y, m, d
end

local function isLeap(y) return y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0) end
local MONTH_DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
local function daysInMonth(y, m)
    if m == 2 and isLeap(y) then return 29 end
    return MONTH_DAYS[m]
end

--- Day number of the last Sunday of month m in year y.
local function lastSunday(y, m)
    local last = (m == 12 and daysFromCivil(y + 1, 1, 1) or daysFromCivil(y, m + 1, 1)) - 1
    local weekday = (last + 4) % 7 -- 1970-01-01 was a Thursday; 0 = Sunday
    return last - weekday
end

--- UTC offset in minutes for zone info at UTC epoch second t.
local function offsetMinutes(zone, t)
    if not zone.eu then return zone.base end
    local y = civilFromDays(t // 86400)
    local dstStart = lastSunday(y, 3) * 86400 + 3600
    local dstEnd = lastSunday(y, 10) * 86400 + 3600
    if t >= dstStart and t < dstEnd then return zone.base + 60 end
    return zone.base
end

-- Accepted instants, same bounds as format.ts: 1900-01-01T00:00:00Z .. 9999-12-31T23:59:59Z. Beyond them JS Intl
-- throws or uses local mean time, and huge epoch values would overflow the integer arithmetic here.
local MIN_EPOCH_SECONDS = daysFromCivil(1900, 1, 1) * 86400
local MAX_EPOCH_SECONDS = daysFromCivil(10000, 1, 1) * 86400 - 1

local function inRange(t, what)
    if not (t >= MIN_EPOCH_SECONDS and t <= MAX_EPOCH_SECONDS) then
        fail('invalid_value', what .. ' is outside 1900-01-01..9999-12-31 UTC')
    end
    return t
end

--- Parse an ISO-8601 string (Z / ±HH:MM / ±HHMM offset; none = UTC; date-only = UTC midnight) or epoch
--- milliseconds into UTC epoch seconds (floored, integer, within 1900..9999). Raises invalid_value / missing_value.
local function toEpochSeconds(value, what)
    if value == nil then fail('missing_value', 'no value for ' .. what) end
    if type(value) == 'number' then
        if value ~= value or value == math.huge or value == -math.huge then
            fail('invalid_value', what .. ' is not a finite number')
        end
        -- math.floor returns an integer whenever the result fits, which the range check guarantees.
        return inRange(math.floor(value / 1000), what)
    end
    if type(value) ~= 'string' then fail('invalid_value', what .. ' must be an ISO string or epoch ms') end

    local y, mo, d, rest = value:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)(.*)$')
    local h, mi, s, offset = 0, 0, 0, 0
    local bad = y == nil
    if not bad and rest ~= '' then
        local hs, mis, tail = rest:match('^[T ](%d%d):(%d%d)(.*)$')
        if not hs then
            bad = true
        else
            h, mi = tonumber(hs), tonumber(mis)
            local ss, tail2 = tail:match('^:(%d%d)(.*)$')
            if ss then
                s, tail = tonumber(ss), tail2
                local _, tail3 = tail:match('^%.(%d+)(.*)$') -- fraction ignored: seconds are floored anyway
                if tail3 then tail = tail3 end
            end
            if tail ~= '' and tail ~= 'Z' then
                local sign, oh, om = tail:match('^([+-])(%d%d):?(%d%d)$')
                if not sign or tonumber(oh) > 23 or tonumber(om) > 59 then
                    bad = true
                else
                    offset = (tonumber(oh) * 60 + tonumber(om)) * (sign == '-' and -1 or 1)
                end
            end
        end
    end
    if not bad then
        y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
        bad = mo < 1 or mo > 12 or d < 1 or d > daysInMonth(y, mo) or h > 23 or mi > 59 or s > 59
    end
    if bad then fail('invalid_value', ('%s is not a valid ISO-8601 date: %s'):format(what, value)) end
    return inRange(daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s - offset * 60, what)
end

--- Wall-clock parts of UTC epoch second t in the zone.
local function zonedParts(t, zone)
    local wall = t + offsetMinutes(zone, t) * 60
    local days = wall // 86400
    local secs = wall - days * 86400
    local y, m, d = civilFromDays(days)
    return { year = y, month = m, day = d, hour = secs // 3600, minute = secs % 3600 // 60, second = secs % 60 }
end

local DATE_TOKENS = { 'YYYY', 'YY', 'MM', 'DD', 'HH', 'mm', 'ss' }

local function pad2(v) return ('%02d'):format(v) end

local function renderTokens(pattern, p)
    local values = {
        YYYY = ('%04d'):format(p.year), YY = pad2(p.year % 100), MM = pad2(p.month), DD = pad2(p.day),
        HH = pad2(p.hour), mm = pad2(p.minute), ss = pad2(p.second),
    }
    local out = {}
    local i, n = 1, #pattern
    while i <= n do
        local hit
        for _, tok in ipairs(DATE_TOKENS) do
            if pattern:sub(i, i + #tok - 1) == tok then
                hit = tok
                break
            end
        end
        if hit then
            out[#out + 1] = values[hit]
            i = i + #hit
        else
            out[#out + 1] = pattern:sub(i, i)
            i = i + 1
        end
    end
    return table.concat(out)
end

------------------------------------------------------------------------------------------------------------
-- Config validation and compiled cache
------------------------------------------------------------------------------------------------------------

local compiledCache = setmetatable({}, { __mode = 'k' }) -- formats table -> compiled entry
local active -- compiled entry of the last M.load

local function configError(field, detail)
    fail('invalid_config', ('%s: %s'):format(field, detail))
end

--- Run fn(...) and turn any error into invalid_config for `field`.
local function checked(field, fn, ...)
    local ok, res = pcall(fn, ...)
    if not ok then configError(field, tostring(res)) end
    return res
end

local function compile(tbl)
    if type(tbl) ~= 'table' then fail('invalid_config', 'formats must be a table') end
    local f = {}
    local tokens = {}
    for _, name in ipairs(FORMAT_NAMES) do
        local v = tbl[name]
        if type(v) ~= 'string' or v == '' then configError(name, 'expected a non-empty string') end
        f[name] = v
        tokens[name] = checked(name, parseTemplate, v)
    end
    for _, name in ipairs({ 'plate', 'personId', 'date', 'time', 'tz' }) do
        local v = tbl[name]
        if type(v) ~= 'string' or v == '' then configError(name, 'expected a non-empty string') end
        f[name] = v
    end
    local zone = TIME_ZONES[f.tz]
    if not zone then configError('tz', 'unsupported time zone ' .. f.tz) end

    local cur = tbl.currency
    if type(cur) ~= 'table' then configError('currency', 'expected an object') end
    local decimals = cur.decimals
    if math.type(decimals) == 'float' and decimals == math.floor(decimals) then decimals = math.tointeger(decimals) end
    if math.type(decimals) ~= 'integer' or decimals < 0 or decimals > 6 then
        configError('currency.decimals', 'expected an integer 0..6')
    end
    if type(cur.symbol) ~= 'string' then configError('currency.symbol', 'expected a string') end
    if type(cur.thousandsSeparator) ~= 'string' then configError('currency.thousandsSeparator', 'expected a string') end
    local decimalSeparator = cur.decimalSeparator
    if decimalSeparator == nil then decimalSeparator = ',' end
    if type(decimalSeparator) ~= 'string' then configError('currency.decimalSeparator', 'expected a string') end
    if cur.position ~= 'prefix' and cur.position ~= 'suffix' then
        configError('currency.position', 'expected "prefix" or "suffix"')
    end
    f.currency = {
        symbol = cur.symbol, decimals = decimals, thousandsSeparator = cur.thousandsSeparator,
        decimalSeparator = decimalSeparator, position = cur.position,
    }

    -- Regex fields are compiled once here (IMPLEMENTATION.md §4.8).
    local caseBody = checked('caseNumber', templateBody, tokens.caseNumber, nil)
    local patterns = {}
    for _, name in ipairs(FORMAT_NAMES) do
        patterns[name] = '^' .. checked(name, templateBody, tokens[name], caseBody) .. '$'
        checked(name, Regex.compile, patterns[name])
    end
    local entry = {
        formats = f,
        zone = zone,
        patterns = patterns,
        plate = checked('plate', Regex.compile, f.plate),
        personId = checked('personId', Regex.compile, f.personId),
        caseNumber = Regex.compile(patterns.caseNumber),
    }
    compiledCache[tbl] = entry
    compiledCache[f] = entry
    return entry
end

--- Compiled entry for an explicit formats table, or the active one.
local function resolve(formats)
    if formats == nil then
        if not active then fail('not_loaded', 'call Format.load(formats) first') end
        return active
    end
    return compiledCache[formats] or compile(formats)
end

--- Validate and compile a decoded config/formats.json and make it the default for every function.
--- Returns the normalised formats table (currency.decimalSeparator defaulted to ',').
function M.load(tbl)
    active = compile(tbl)
    return active.formats
end

--- The active normalised formats table, or nil before M.load.
function M.get()
    return active and active.formats or nil
end

------------------------------------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------------------------------------

--- Counter value (integer >= 0, or a string of digits) as a decimal string.
local function counterString(v, name)
    if v == nil then fail('missing_value', ('no value for {{%s}}'):format(name)) end
    if type(v) == 'string' then
        if not v:match('^%d+$') then fail('invalid_value', ('{{%s}} must be a non-negative integer'):format(name)) end
        return v
    end
    if type(v) == 'number' then
        local iv = math.tointeger(v)
        if iv and iv >= 0 and iv <= MAX_SAFE_INTEGER then return ('%d'):format(iv) end
    end
    fail('invalid_value', ('{{%s}} must be a non-negative integer'):format(name))
end

--- Fill a template. ctx = { seq?, n?, unit?, case?, date? } (date: ISO string or epoch ms; yy/yyyy come from
--- it in the configured zone). Unknown placeholder or missing value raises.
function M.formatId(template, ctx, formats)
    local tokens = parseTemplate(template)
    -- nil means "no values"; any other non-table (5, false, 'x') is rejected, same as the TS port. Not `ctx or {}`:
    -- that would turn false into {} while TS rejects it.
    if ctx == nil then
        ctx = {}
    elseif type(ctx) ~= 'table' then
        fail('invalid_value', 'ctx must be an object (table)')
    end
    local parts -- zoned date parts, computed once on first {{yy}}/{{yyyy}}
    local out = {}
    for _, tok in ipairs(tokens) do
        local name = tok.name
        local s
        if tok.literal then
            s = tok.literal
        elseif name == 'seq' or name == 'n' then
            s = counterString(ctx[name], name)
            if tok.width and #s < tok.width then s = ('0'):rep(tok.width - #s) .. s end
        elseif name == 'unit' then
            local v = ctx.unit
            if v == nil or v == '' then fail('missing_value', 'no value for {{unit}}') end
            if type(v) ~= 'string' or not v:match('^%u+$') then
                fail('invalid_value', '{{unit}} must be upper-case letters A-Z (the unit callsign prefix)')
            end
            s = v
        elseif name == 'case' then
            local v = ctx.case
            if v == nil or v == '' then fail('missing_value', 'no value for {{case}}') end
            if type(v) ~= 'string' then fail('invalid_value', '{{case}} must be a string') end
            s = v
        else -- yy / yyyy
            if not parts then
                local t = toEpochSeconds(ctx.date, 'date')
                parts = zonedParts(t, resolve(formats).zone)
            end
            s = name == 'yyyy' and ('%04d'):format(parts.year) or pad2(parts.year % 100)
        end
        out[#out + 1] = s
    end
    return table.concat(out)
end

--- Anchored pattern string for one of callsign, caseNumber, reportNumber, evidenceTag.
function M.templateToRegex(name, formats)
    local c = resolve(formats)
    local p = c.patterns[name]
    if not p then fail('invalid_value', ('unknown format name %s'):format(tostring(name))) end
    return p
end

local WS = '[ \t\n\r\f\v]'

-- UTF-8 of the non-ASCII characters JavaScript's \s matches (Zs, U+2028/U+2029, U+FEFF), as Lua patterns.
-- Same set as UNICODE_SPACES in format.ts; each lead byte only occurs as a lead byte, so no false hits mid-sequence.
local UNICODE_SPACES = {
    '\xC2\xA0', -- U+00A0 no-break space
    '\xE1\x9A\x80', -- U+1680 ogham space mark
    '\xE2\x80[\x80-\x8A\xA8\xA9\xAF]', -- U+2000..U+200A, U+2028, U+2029, U+202F
    '\xE2\x81\x9F', -- U+205F medium mathematical space
    '\xE3\x80\x80', -- U+3000 ideographic space
    '\xEF\xBB\xBF', -- U+FEFF zero-width no-break space (BOM)
}

--- Classify a search query. Unicode spaces are folded to ' ', then the query is trimmed.
--- Order: caseNumber (as typed, then upper-cased), personId, plate, name.
function M.detectSearchType(query, formats)
    if type(query) ~= 'string' then fail('invalid_value', 'query must be a string') end
    local c = resolve(formats)
    local q = query
    for _, pat in ipairs(UNICODE_SPACES) do q = q:gsub(pat, ' ') end
    q = q:gsub('^' .. WS .. '+', ''):gsub(WS .. '+$', '')
    local upper = q:gsub('%l', string.upper) -- ASCII only, same as the TS port
    if c.caseNumber:test(q) then return { type = 'caseNumber', normalized = q } end
    if c.caseNumber:test(upper) then return { type = 'caseNumber', normalized = upper } end
    if c.personId:test(q) then
        local digits = q:gsub('%D', '')
        if #digits > 4 then digits = digits:sub(1, -5) .. '-' .. digits:sub(-4) end
        return { type = 'personId', normalized = digits }
    end
    if c.plate:test(upper) then return { type = 'plate', normalized = (upper:gsub(WS, '')) } end
    return { type = 'name', normalized = (q:gsub(WS .. '+', ' ')) }
end

--- Date of an instant (ISO string or epoch ms) in the configured zone, rendered with formats.date.
function M.formatDate(iso, formats)
    local c = resolve(formats)
    return renderTokens(c.formats.date, zonedParts(toEpochSeconds(iso, 'date'), c.zone))
end

--- Time of an instant (ISO string or epoch ms) in the configured zone, rendered with formats.time.
function M.formatTime(iso, formats)
    local c = resolve(formats)
    return renderTokens(c.formats.time, zonedParts(toEpochSeconds(iso, 'time'), c.zone))
end

local function groupThousands(digits, sep)
    local len = #digits
    local first = len % 3
    if first == 0 then first = 3 end
    local groups = { digits:sub(1, first) }
    for i = first + 1, len, 3 do groups[#groups + 1] = digits:sub(i, i + 2) end
    return table.concat(groups, sep)
end

--- Money per formats.currency: rounded half away from zero to `decimals`, grouped thousands, symbol placed
--- as suffix ("1 234 kr") or prefix ("€1 234"). Negative amounts get a leading '-'.
function M.formatCurrency(amount, formats)
    local c = resolve(formats)
    if type(amount) ~= 'number' or amount ~= amount or amount == math.huge or amount == -math.huge then
        fail('invalid_value', 'amount must be a finite number')
    end
    local cur = c.formats.currency
    local factor = math.tointeger(10 ^ cur.decimals)
    -- Float arithmetic like the TS port: with an integer amount, abs(math.mininteger) and amount * factor would
    -- wrap around silently instead of tripping the range check.
    local scaled = math.floor(math.abs(amount + 0.0) * factor + 0.5)
    if math.type(scaled) ~= 'integer' or scaled > MAX_SAFE_INTEGER then fail('invalid_value', 'amount too large') end
    local s = groupThousands(('%d'):format(scaled // factor), cur.thousandsSeparator)
    if cur.decimals > 0 then
        s = s .. cur.decimalSeparator .. ('%0' .. cur.decimals .. 'd'):format(scaled % factor)
    end
    if cur.symbol ~= '' then
        s = cur.position == 'suffix' and (s .. ' ' .. cur.symbol) or (cur.symbol .. s)
    end
    if amount < 0 and scaled > 0 then s = '-' .. s end
    return s
end

M.TIME_ZONES = TIME_ZONES

return M
