-- SPDX-License-Identifier: GPL-3.0-only
-- UTC timestamps between MariaDB, Lua and the wire (docs/contracts.md §C7, §C12). Pure; tests/lua/time_test.lua.
--
-- FredPD stores every DATETIME as UTC (defaults `(UTC_TIMESTAMP())`, writes `UTC_TIMESTAMP()`), whatever the MariaDB
-- server or session time zone is. Reading them back through oxmysql needs care: oxmysql turns a DATETIME into epoch
-- milliseconds by reading the wall time in the FXServer host's LOCAL zone, so a UTC value read on a Stockholm host
-- comes back one or two hours off. Select DATETIME columns as strings instead:
--
--   local Time = require 'shared.time'            -- another resource: require '@fredpd_core.shared.time'
--   local SQL = 'SELECT id, ' .. Time.isoSelect('b.created_at', 'createdAt') .. ' FROM fredpd_bolos b WHERE id = ?'
--   -- row.createdAt == '2026-09-29T12:00:00Z' (ISO-8601 UTC, the IsoUtcSchema wire format)
--
-- The fragment contains `%` characters: concatenate it, never pass the finished SQL through string.format.
-- To bind a wire timestamp into a DATETIME parameter use M.toDatetime(iso); for "now" write UTC_TIMESTAMP() in SQL.

local M = {}

-- Column: `name` or `alias.name`, lower case (FredPD column names). Alias: one identifier, camelCase allowed.
local COLUMN_PATTERNS = { '^[a-z_][a-z0-9_]*$', '^[a-z_][a-z0-9_]*%.[a-z_][a-z0-9_]*$' }
local ALIAS_PATTERN = '^[A-Za-z_][A-Za-z0-9_]*$'

local function validColumn(col)
    if type(col) ~= 'string' or #col > 128 then return false end
    for _, p in ipairs(COLUMN_PATTERNS) do
        if col:match(p) then return true end
    end
    return false
end

--- `DATE_FORMAT(<col>, '%Y-%m-%dT%H:%i:%sZ') AS <alias>`: a SELECT fragment that reads a UTC DATETIME column as an
--- ISO-8601 UTC string (NULL stays NULL). `alias` defaults to the column name without a table prefix. Both are
--- validated (identifiers only, so nothing can be injected); anything else raises an error.
--- @param col string e.g. 'created_at' or 'b.created_at'
--- @param alias string|nil e.g. 'createdAt'
--- @return string
function M.isoSelect(col, alias)
    if not validColumn(col) then
        error(('isoSelect: invalid column %q (expected name or table.name, [a-z0-9_])'):format(tostring(col)), 2)
    end
    if alias == nil then alias = col:match('([^.]+)$') end
    if type(alias) ~= 'string' or #alias > 64 or not alias:match(ALIAS_PATTERN) then
        error(('isoSelect: invalid alias %q (expected one identifier, [A-Za-z0-9_])'):format(tostring(alias)), 2)
    end
    return ("DATE_FORMAT(%s, '%%Y-%%m-%%dT%%H:%%i:%%sZ') AS %s"):format(col, alias)
end

---------------------------------------------------------------------------------------------------------------
-- Parsing (proleptic Gregorian, integer arithmetic; no os.date/os.time, so the host's zone cannot leak in)

-- Days since 1970-01-01 (H. Hinnant's days_from_civil; Lua's // floors).
local function daysFromCivil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = y // 400
    local yoe = y - era * 400
    local doy = (153 * (m > 2 and m - 3 or m + 9) + 2) // 5 + d - 1
    local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468
end

local function civilFromDays(z)
    z = z + 719468
    local era = z // 146097
    local doe = z - era * 146097
    local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    local mp = (5 * doy + 2) // 153
    local d = doy - (153 * mp + 2) // 5 + 1
    local m = mp < 10 and mp + 3 or mp - 9
    return yoe + era * 400 + (m <= 2 and 1 or 0), m, d
end

local function daysInMonth(y, m)
    if m == 2 then return (y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)) and 29 or 28 end
    return (m == 4 or m == 6 or m == 9 or m == 11) and 30 or 31
end

--- Parse 'YYYY-MM-DD HH:MM:SS' / 'YYYY-MM-DDTHH:MM:SS' with an optional fraction and an optional zone
--- ('Z', '+HH:MM', '+HHMM', '-…'; none = UTC, as MariaDB DATETIME text is UTC in FredPD). Returns the UTC parts
--- { y, m, d, h, mi, s, frac }, false for MariaDB's zero date, or nil and a reason.
local function parse(v)
    local y, mo, d, h, mi, s, rest = v:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)(.*)$')
    if not y then return nil, 'not a YYYY-MM-DD HH:MM:SS timestamp' end
    local frac, zone = rest:match('^(%.%d+)(.*)$')
    if not frac then frac, zone = '', rest end
    local offset
    if zone == '' or zone == 'Z' then
        offset = 0
    else
        local sign, oh, om = zone:match('^([%+%-])(%d%d):?(%d%d)$')
        if not sign then return nil, ('unknown time zone suffix %q'):format(zone) end
        oh, om = tonumber(oh), tonumber(om)
        if oh > 23 or om > 59 then return nil, ('bad UTC offset %q'):format(zone) end
        offset = (sign == '-' and -1 or 1) * (oh * 60 + om)
    end
    y, mo, d, h, mi, s = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s)
    if y == 0 and mo == 0 and d == 0 then return false end -- MariaDB zero date: no instant
    if mo < 1 or mo > 12 or d < 1 or d > daysInMonth(y, mo) or h > 23 or mi > 59 or s > 59 then
        return nil, 'date or time out of range'
    end
    if offset ~= 0 then
        local t = daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s - offset * 60
        local days = t // 86400
        local secs = t - days * 86400
        y, mo, d = civilFromDays(days)
        h, mi, s = secs // 3600, secs % 3600 // 60, secs % 60
    end
    return { y = y, m = mo, d = d, h = h, mi = mi, s = s, frac = frac }
end

local NUMBER_ERROR = 'toIsoUtc: got the number %s; oxmysql turns a DATETIME into epoch milliseconds read in the '
    .. "FXServer host's local zone, which is wrong for FredPD's UTC values. Select the column with "
    .. "Time.isoSelect('<col>') (DATE_FORMAT to an ISO string) instead"

--- Normalise a DATETIME text ('YYYY-MM-DD HH:MM:SS', as MariaDB prints UTC values) or an ISO-8601 string (with
--- Z, an offset, or no zone = UTC) to 'YYYY-MM-DDTHH:MM:SSZ' (a fraction is kept). nil -> nil, and MariaDB's zero
--- date '0000-00-00 00:00:00' -> nil. Numbers are rejected with an error: an epoch from oxmysql is already off by
--- the host's UTC offset (see NUMBER_ERROR). Anything else unparseable raises too.
--- @param v string|nil
--- @return string|nil
function M.toIsoUtc(v)
    if v == nil then return nil end
    if type(v) == 'number' then error(NUMBER_ERROR:format(tostring(v)), 2) end
    if type(v) ~= 'string' then error(('toIsoUtc: expected a string or nil, got %s'):format(type(v)), 2) end
    local p, why = parse(v)
    if p == false then return nil end
    if not p then error(('toIsoUtc: %q is %s'):format(v, why), 2) end
    return ('%04d-%02d-%02dT%02d:%02d:%02d%sZ'):format(p.y, p.m, p.d, p.h, p.mi, p.s, p.frac)
end

--- An ISO-8601 timestamp (Z or an offset) or a 'YYYY-MM-DD HH:MM:SS' UTC text -> 'YYYY-MM-DD HH:MM:SS' in UTC, the
--- value to bind into a DATETIME parameter (fraction dropped). Never raises: nil and a reason for anything else
--- (use it on input from outside, e.g. a GrantSet's computedAt).
--- @param v any
--- @return string|nil, string|nil
function M.toDatetime(v)
    if type(v) ~= 'string' then return nil, 'not a string' end
    local p, why = parse(v)
    if not p then return nil, why or 'zero date' end
    return ('%04d-%02d-%02d %02d:%02d:%02d'):format(p.y, p.m, p.d, p.h, p.mi, p.s)
end

--- Unix seconds (UTC) of an ISO-8601 timestamp or a 'YYYY-MM-DD HH:MM:SS' UTC text (fraction dropped), e.g. to
--- compare an expires_at with os.time(). Never raises: nil and a reason for anything else.
--- @param v any
--- @return integer|nil, string|nil
function M.toEpoch(v)
    if type(v) ~= 'string' then return nil, 'not a string' end
    local p, why = parse(v)
    if not p then return nil, why or 'zero date' end
    return daysFromCivil(p.y, p.m, p.d) * 86400 + p.h * 3600 + p.mi * 60 + p.s
end

--- Current time as 'YYYY-MM-DDTHH:MM:SSZ'. `now` (unix seconds) is for tests; os.time() is zone-independent and
--- os.date('!…') formats in UTC.
--- @param now integer|nil
--- @return string
function M.nowIso(now)
    return os.date('!%Y-%m-%dT%H:%M:%SZ', now or os.time()) --[[@as string]]
end

return M
