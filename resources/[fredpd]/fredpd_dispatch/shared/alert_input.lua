-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_dispatch input handling (docs/contracts.md §C13, packages/types/src/dispatch.ts). Pure Lua 5.4: no FiveM
-- natives, no MySQL, so tests/lua/dispatch_input_test.lua runs it as it is.
--
--   M.validateCreate(data)          Lua mirror of AlertCreateInputSchema (createAlert export): strict, rejects
--                                   over-long text instead of cutting it (like zod .max).
--   M.fromPsDispatch(data, L)       ps-dispatch call table (client-reported, untrusted) -> AlertCreateInput:
--                                   caps every string, validates coords (offset alerts: the displayed position),
--                                   clamps priority, whitelists meta.
--   M.alertId / M.listInput         AlertIdInputSchema / AlertListInputSchema mirrors for the tablet actions.
--   M.newLimiter(max, windowMs)     sliding-window rate limiter (no timers; pruned on use).
--
-- Text is counted in characters (UTF-8 code points), like the utf8mb4 VARCHAR columns. Control characters are
-- removed (newlines kept only where a field is multi-line) and invalid UTF-8 bytes are dropped, so a hostile string
-- can never make the INSERT fail. Work is bounded: a string is cut to a few bytes per allowed character before it
-- is scanned, and no input table is ever iterated with pairs() except a createAlert meta table (capped).

local M = {}

M.LIMITS = { code = 16, title = 160, description = 1000, street = 128, source = 32 }
M.COORD_LIMIT = 10000.0          -- |x|, |y|, |z| (the GTA V map fits well inside)
M.PRIORITY_DEFAULT = 2           -- 1 = hög, 2 = normal, 3 = låg (AlertPrioritySchema)
M.MAX_ID = 4294967295            -- fredpd_alerts.id INT UNSIGNED
M.MAX_PAGE = 10000               -- PageSchema
M.META_MAX_KEYS = 32
M.META_KEY_CHARS = 32
M.META_STRING_CHARS = 256
M.PS_META_STRING_CHARS = 64
M.PS_INFO_CHARS = 600            -- ps-dispatch `information` (911 text) inside the description
M.PS_SOURCE = 'ps-dispatch'

-- Job names/types whose ps-dispatch calls become FredPD alerts (ps-dispatch `jobs = { 'leo' }`); EMS-only calls
-- (311, injured person …) are not police alerts.
M.POLICE_JOBS = { leo = true, police = true }

-- ps-dispatch fields kept in fredpd_alerts.meta (never sent to clients; the wire Alert has no meta). The reporting
-- player's identity is deliberately not stored: for most presets the reporter is the suspect (Shooting(), …).
local PS_META_STRINGS = {
    'codeName', 'icon', 'gender', 'weapon', 'weaponClass', 'vehicle', 'plate', 'color', 'class', 'name', 'number',
    'callsign', 'camId',
}
local PS_META_NUMBERS = { 'weaponTier', 'doors', 'heading', 'hotspot', 'mapRadius' }
local PS_META_BOOLEANS = { 'automaticGunFire', 'automaticGunfire' }

---------------------------------------------------------------------------------------------------------------
-- Text

local function isFiniteNumber(v)
    return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end
M.isFiniteNumber = isFiniteNumber

--- Whitespace trimmed from both ends in linear time (a `^%s*(.-)%s*$` match backtracks quadratically on long
--- whitespace runs); nil when nothing is left.
function M.trim(s)
    local first = s:find('%S')
    if not first then return nil end
    local last = #s - s:reverse():find('%S') + 1
    return s:sub(first, last)
end

--- Clean a text value: numbers become strings (integral floats without '.0'), anything else that is not a string
--- is nil. Control characters are removed (`multiline`: '\n' kept, '\r\n'/'\r' become '\n', tabs become spaces),
--- invalid UTF-8 bytes dropped, whitespace trimmed. Returns the text and its length in characters, or nil when
--- nothing is left. Only the first `budget` characters' worth of bytes is looked at (bounded work).
--- @param v any
--- @param budget integer characters to keep at most before trimming (the caller checks/cuts the final length)
--- @param multiline boolean|nil
--- @return string|nil, integer|nil
function M.cleanText(v, budget, multiline)
    if type(v) == 'number' then
        if not isFiniteNumber(v) then return nil end
        v = (math.type(v) == 'float' and v == math.floor(v) and math.abs(v) < 2 ^ 53) and ('%d'):format(v)
            or tostring(v)
    end
    if type(v) ~= 'string' then return nil end
    budget = budget or 4096
    -- A UTF-8 character is at most 4 bytes; + a little slack so trimming whitespace still leaves `budget` chars.
    local maxBytes = budget * 4 + 64
    if #v > maxBytes then v = v:sub(1, maxBytes) end
    if multiline then
        v = v:gsub('\r\n?', '\n'):gsub('\t', ' '):gsub('[\0-\8\11-\31\127]', '')
    else
        v = v:gsub('[\t\r\n]', ' '):gsub('[\0-\31\127]', '')
    end
    -- Keep only well-formed UTF-8 sequences (utf8.charpattern finds the candidates, utf8.len validates each).
    if not utf8.len(v) then
        local out = {}
        for ch in v:gmatch(utf8.charpattern) do
            if utf8.len(ch) == 1 then out[#out + 1] = ch end
        end
        v = table.concat(out)
    end
    v = M.trim(v)
    if not v then return nil end
    return v, utf8.len(v)
end

--- First `max` characters of a valid UTF-8 string (never splits a character), trailing whitespace trimmed.
function M.cutChars(s, max)
    local cut = utf8.offset(s, max + 1)
    if cut then s = M.trim(s:sub(1, cut - 1)) end
    return s
end

--- cleanText + cut to `max` characters (lenient: for untrusted generator data).
function M.capText(v, max, multiline)
    local s = M.cleanText(v, max, multiline)
    if not s then return nil end
    return M.cutChars(s, max)
end

--- cleanText + reject when longer than `max` (strict: mirrors zod .trim().max()). Returns ok, value|nil.
local function strictText(v, max, multiline)
    if v == nil then return true, nil end
    if type(v) ~= 'string' then return false end
    local s, n = M.cleanText(v, max + 1, multiline)
    if not s then return true, nil end
    if n > max then return false end
    return true, s
end

---------------------------------------------------------------------------------------------------------------
-- Coords, priority

--- { x, y, z } from a vector3/vector4 or a table with finite numbers within ±COORD_LIMIT; nil otherwise.
function M.coords(v)
    local t = type(v)
    if t ~= 'table' and t ~= 'vector3' and t ~= 'vector4' then return nil end
    local x, y, z = v.x, v.y, v.z
    local function bad(n) return not isFiniteNumber(n) or n > M.COORD_LIMIT or n < -M.COORD_LIMIT end
    if bad(x) or bad(y) or bad(z) then return nil end
    return { x = x + 0.0, y = y + 0.0, z = z + 0.0 }
end

--- Priority clamped to 1..3 (ps-dispatch's critical 0 -> 1, 99 -> 3); anything unusable -> PRIORITY_DEFAULT.
function M.clampPriority(v)
    if type(v) == 'string' then v = tonumber(v) end
    if not isFiniteNumber(v) then return M.PRIORITY_DEFAULT end
    v = math.floor(v + 0.5)
    if v < 1 then return 1 end
    if v > 3 then return 3 end
    return math.tointeger(v)
end

---------------------------------------------------------------------------------------------------------------
-- createAlert input (AlertCreateInputSchema)

--- Shallow copy of a meta table with safe values only: string keys (≤ META_KEY_CHARS), strings (capped), finite
--- numbers, booleans; at most META_MAX_KEYS entries (sorted by key, so the choice is deterministic).
local function sanitizeMeta(meta)
    local keys = {}
    for k in pairs(meta) do
        if type(k) == 'string' and #k <= M.META_KEY_CHARS * 4 then keys[#keys + 1] = k end
        if #keys > M.META_MAX_KEYS * 4 then break end -- bounded, even for a huge table
    end
    table.sort(keys)
    local out, n = {}, 0
    for _, k in ipairs(keys) do
        local key = M.capText(k, M.META_KEY_CHARS)
        local v = meta[k]
        local value
        if type(v) == 'string' then
            value = M.capText(v, M.META_STRING_CHARS, true)
        elseif isFiniteNumber(v) or type(v) == 'boolean' then
            value = v
        end
        if key and value ~= nil and out[key] == nil then
            out[key] = value
            n = n + 1
            if n >= M.META_MAX_KEYS then break end
        end
    end
    return n > 0 and out or nil
end
M.sanitizeMeta = sanitizeMeta

--- Validate createAlert(data). Returns the normalised input
--- { code, title, description?, coords?, street?, priority, source, meta? } or nil and the name of the bad field.
--- `message` is accepted as an alias for a missing `title` (fredpd_devtools' /fredpd_fakeunits sends `message`).
--- @param data table
--- @return table|nil, string|nil
function M.validateCreate(data)
    if type(data) ~= 'table' then return nil, 'input' end
    local out = {}
    local ok, v

    ok, v = strictText(data.code, M.LIMITS.code)
    if not ok or not v then return nil, 'code' end
    out.code = v

    local title = data.title
    if title == nil then title = data.message end
    ok, v = strictText(title, M.LIMITS.title)
    if not ok or not v then return nil, 'title' end
    out.title = v

    ok, v = strictText(data.description, M.LIMITS.description, true)
    if not ok then return nil, 'description' end
    out.description = v

    if data.coords ~= nil then
        out.coords = M.coords(data.coords)
        if not out.coords then return nil, 'coords' end
    end

    ok, v = strictText(data.street, M.LIMITS.street)
    if not ok then return nil, 'street' end
    out.street = v

    if data.priority == nil then
        out.priority = M.PRIORITY_DEFAULT
    else
        local p = type(data.priority) == 'number' and math.tointeger(data.priority)
        if not p or p < 1 or p > 3 then return nil, 'priority' end
        out.priority = p
    end

    ok, v = strictText(data.source, M.LIMITS.source)
    if not ok or not v then return nil, 'source' end
    out.source = v

    if data.meta ~= nil then
        if type(data.meta) ~= 'table' then return nil, 'meta' end
        out.meta = sanitizeMeta(data.meta)
    end
    return out
end

---------------------------------------------------------------------------------------------------------------
-- ps-dispatch bridge

--- True when the call targets police: `jobs` (job types or names) contains one of `police` (a set; default
--- POLICE_JOBS). A call without a usable `jobs` list is ps-dispatch's default audience, which is { 'leo' }.
function M.isPoliceCall(data, police)
    police = police or M.POLICE_JOBS
    if type(data) ~= 'table' then return false end
    local jobs = data.jobs
    if jobs == nil then return true end
    if type(jobs) == 'string' then return police[jobs] == true end
    if type(jobs) ~= 'table' then return false end
    for i = 1, math.min(#jobs, 16) do -- bounded: a hostile list cannot make this loop long
        if type(jobs[i]) == 'string' and police[jobs[i]] then return true end
    end
    return false
end

--- Search radius of an approximate ps-dispatch position (`mapRadius`), whole metres ≥ 1; nil when unusable.
function M.psRadius(v)
    if not isFiniteNumber(v) or v <= 0 or v > M.COORD_LIMIT then return nil end
    return math.max(1, math.floor(v + 0.5))
end

--- Description built from the call's free text and details (Swedish labels through L):
--- information, "Ungefärlig plats (inom N m)" for an offset position, then "Fordon: model · plate · colour",
--- "Vapen: …", "Inringare: name · number".
local function psDescription(data, L, approximate)
    local lines = {}
    local info = M.capText(data.information, M.PS_INFO_CHARS, true)
    if info then lines[#lines + 1] = info end
    local radius = approximate and M.psRadius(data.mapRadius)
    if radius then lines[#lines + 1] = L('alert.detail.area', { radius = radius }) end
    local function line(key, fields)
        local parts = {}
        for _, f in ipairs(fields) do
            local s = M.capText(data[f], M.PS_META_STRING_CHARS)
            if s then parts[#parts + 1] = s end
        end
        if #parts > 0 then lines[#lines + 1] = L(key, { value = table.concat(parts, ' · ') }) end
    end
    line('alert.detail.vehicle', { 'vehicle', 'plate', 'color' })
    line('alert.detail.weapon', { 'weapon' })
    line('alert.detail.caller', { 'name', 'number' })
    if #lines == 0 then return nil end
    return M.capText(table.concat(lines, '\n'), M.LIMITS.description, true)
end

local function psMeta(data, exact)
    local meta, n = {}, 0
    local function put(k, v) meta[k] = v; n = n + 1 end
    local id = type(data.id) == 'number' and math.tointeger(data.id)
    if id and id > 0 then put('psId', id) end
    if exact then -- true position of an offset alert: kept server-side (meta is never on the wire)
        put('exactX', exact.x); put('exactY', exact.y); put('exactZ', exact.z)
    end
    for _, k in ipairs(PS_META_STRINGS) do
        local s = M.capText(data[k], M.PS_META_STRING_CHARS)
        if s then put(k, s) end
    end
    for _, k in ipairs(PS_META_NUMBERS) do
        local v = data[k]
        if isFiniteNumber(v) and math.abs(v) < 1e9 then put(k, v) end
    end
    for _, k in ipairs(PS_META_BOOLEANS) do
        if type(data[k]) == 'boolean' then put(k, data[k]) end
    end
    return n > 0 and meta or nil
end

--- Normalise a ps-dispatch call (its `ps-dispatch:server:notify` data after storing: message, code, codeName,
--- coords, displayCoords, mapRadius, street, priority, information, vehicle, …) into an AlertCreateInput. Lenient
--- where ps-dispatch data is merely odd (long text is cut, priority clamped, missing street/description allowed),
--- strict where it cannot be real (no title, no code, coords/displayCoords present but not finite/in range -> nil).
--- `L` builds the description labels.
---
--- Offset alerts (Config.Blips[codeName].offset: shooting, vehicleshots, fight, vehicletheft, carjack, explosion,
--- houserobbery, susactivity, suspicioushandoff) keep ps-dispatch's rule that officers only get an approximate
--- position: the alert's coords (waypoint, tablet) are `displayCoords`, the description says "within mapRadius m",
--- and the true coords go to meta (exactX/Y/Z; never sent to clients). docs/modules/dispatch.md, Design decisions.
--- @param data table
--- @param L function(key, vars) -> string
--- @return table|nil input, string|nil reason
function M.fromPsDispatch(data, L)
    if type(data) ~= 'table' then return nil, 'input' end
    local title = M.capText(data.message, M.LIMITS.title)
    if not title then return nil, 'title' end
    local code = M.capText(data.code, M.LIMITS.code) or M.capText(data.codeName, M.LIMITS.code)
    if not code then return nil, 'code' end
    local coords, exact = nil, nil
    if data.coords ~= nil then
        coords = M.coords(data.coords)
        if not coords then return nil, 'coords' end
    end
    local approximate = data.displayCoords ~= nil
    if approximate then
        local shown = M.coords(data.displayCoords)
        if not shown then return nil, 'coords' end
        exact, coords = coords, shown
    end
    local input = {
        code = code,
        title = title,
        description = psDescription(data, L or function(key) return key end, approximate),
        coords = coords,
        street = M.capText(data.street, M.LIMITS.street),
        priority = M.clampPriority(data.priority),
        source = M.PS_SOURCE,
        meta = psMeta(data, exact),
    }
    return M.validateCreate(input) -- always passes; keeps the two paths identical
end

---------------------------------------------------------------------------------------------------------------
-- Tablet action inputs

--- Positive integer id (fredpd_alerts.id) from a number (JSON floats allowed when integral); nil otherwise.
function M.id(v)
    if type(v) ~= 'number' or v ~= v then return nil end
    local i = math.tointeger(v)
    if not i or i < 1 or i > M.MAX_ID then return nil end
    return i
end

--- AlertIdInputSchema: { id }.
function M.alertId(input)
    if type(input) ~= 'table' then return nil end
    return M.id(input.id)
end

local FILTERS = { open = true, mine = true, all = true }

--- AlertListInputSchema: { filter = 'open'|'mine'|'all' (default 'open'), page = 1..10000 (default 1) }.
--- nil input = defaults. Returns the normalised table or nil.
function M.listInput(input)
    if input == nil then input = {} end
    if type(input) ~= 'table' then return nil end
    local filter = input.filter
    if filter == nil then filter = 'open' end
    if not FILTERS[filter] then return nil end
    local page = input.page
    if page == nil then page = 1 end
    page = type(page) == 'number' and math.tointeger(page) or nil
    if not page or page < 1 or page > M.MAX_PAGE then return nil end
    return { filter = filter, page = page }
end

---------------------------------------------------------------------------------------------------------------
-- Rate limiting

--- Sliding window: at most `max` allowed calls per `windowMs` per key. Refused calls are not counted. State is a
--- few timestamps per key, pruned on every call; clear(key) forgets a key (playerDropped).
function M.newLimiter(max, windowMs)
    local buckets = {}
    local limiter = {}
    function limiter.allow(key, now)
        local bucket = buckets[key] or {}
        local cutoff = now - windowMs
        local kept = {}
        for i = 1, #bucket do
            if bucket[i] > cutoff then kept[#kept + 1] = bucket[i] end
        end
        if #kept >= max then
            buckets[key] = kept
            return false
        end
        kept[#kept + 1] = now
        buckets[key] = kept
        return true
    end
    function limiter.clear(key) buckets[key] = nil end
    return limiter
end

return M
