-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_records server helpers: the { ok, data | error } result convention (docs/contracts.md §C12), value
-- coercion for oxmysql rows, defensive input checks (the exports can be called by any server resource, not only
-- the fredpd_mdt dispatcher that already validated the input), logging, and pcall-guarded calls into fredpd_core,
-- fredpd_bolo and the housing adapter. Nothing here yields except the calls it forwards.

local M = {}

M.CORE = 'fredpd_core'
M.BOLO = 'fredpd_bolo'

---------------------------------------------------------------------------------------------------------------
-- Results

function M.ok(data) return { ok = true, data = data } end
function M.fail(code) return { ok = false, error = code } end

---------------------------------------------------------------------------------------------------------------
-- Values from oxmysql rows

--- A string column: strings as they are, integers formatted without a fraction (the test shim turns digit-only
--- strings into numbers; oxmysql does not), anything else nil.
function M.str(v)
    local t = type(v)
    if t == 'string' then return v end
    if t == 'number' then
        local i = math.tointeger(v)
        return i and ('%d'):format(i) or tostring(v)
    end
    return nil
end

--- An integer (number or digit string) or nil.
function M.int(v)
    local n = tonumber(v)
    if not n then return nil end
    return math.tointeger(n)
end

--- A non-negative integer, else 0.
function M.nonNeg(v)
    local n = M.int(v)
    if not n or n < 0 then return 0 end
    return n
end

--- TINYINT(1) / boolean -> boolean.
function M.bool(v)
    return v == true or tonumber(v) == 1
end

--- '?, ?, ?' for n parameters.
function M.marks(n)
    return ('?, '):rep(n):sub(1, -3)
end

--- 'Förnamn Efternamn' (trimmed), or nil when both are empty.
function M.fullName(first, last)
    local name = ((M.str(first) or '') .. ' ' .. (M.str(last) or '')):gsub('^%s+', ''):gsub('%s+$', '')
    if name == '' then return nil end
    return name
end

--- `s` cut to at most `max` bytes at a UTF-8 character boundary (audit target ids are limited in bytes).
function M.cutBytes(s, max)
    if #s <= max then return s end
    local cut = s:sub(1, max)
    -- drop a trailing partial sequence: continuation bytes, then the lead byte that started it
    local i = #cut
    while i > 0 and cut:byte(i) >= 0x80 and cut:byte(i) < 0xC0 do i = i - 1 end
    if i > 0 and cut:byte(i) >= 0xC0 then
        local lead = cut:byte(i)
        local need = lead >= 0xF0 and 4 or lead >= 0xE0 and 3 or 2
        if #cut - i + 1 < need then cut = cut:sub(1, i - 1) end
    end
    return cut
end

--- Case level 0..2; anything unreadable counts as 2 (the most restrictive) so it can never widen visibility.
function M.level(v)
    local n = M.int(v)
    if n == 0 or n == 1 or n == 2 then return n end
    return 2
end

---------------------------------------------------------------------------------------------------------------
-- Input checks (mirror the zod shapes in packages/types/src/mdt.ts)

local ASCII_SPACE = '[ \t\n\r\f\v]'

--- Trimmed string when `v` is a string of valid UTF-8 without control characters whose length (code points) is
--- within [min, max]; else nil.
function M.text(v, min, max)
    -- sanity bound before any work (zod trims first, so surrounding blanks may exceed `max`)
    if type(v) ~= 'string' or #v > 4096 then return nil end
    local s = v:gsub('^' .. ASCII_SPACE .. '+', ''):gsub(ASCII_SPACE .. '+$', '')
    if #s > max * 4 then return nil end
    if s:find('[\0-\31\127]') then return nil end
    local n = utf8.len(s)
    if not n or n < min or n > max then return nil end
    return s
end

--- CitizenIdSchema: ^[A-Za-z0-9_-]{1,50}$.
function M.citizenid(v)
    if type(v) ~= 'string' or #v < 1 or #v > 50 or not v:match('^[%w_%-]+$') then return nil end
    return v
end

--- PlateSchema (trimmed, 1-16) normalised like fredpd_vehicles_idx.plate and detectSearchType: whitespace removed,
--- upper case. nil when it does not fit.
function M.plate(v)
    local s = M.text(v, 1, 16)
    if not s then return nil end
    local p = s:gsub('%s', ''):upper()
    if p == '' or #p > 16 then return nil end
    return p
end

--- Optional integer in [min, max]; `default` when nil. Returns false for anything else (floats, strings, range).
function M.optInt(v, min, max, default)
    if v == nil then return default end
    if type(v) ~= 'number' then return false end
    local i = math.tointeger(v)
    if not i or i < min or i > max then return false end
    return i
end

--- Player server id (positive integer) or nil.
function M.playerSrc(src)
    local n = M.int(src)
    if n and n > 0 then return n end
    return nil
end

---------------------------------------------------------------------------------------------------------------
-- Logging (console only; nothing here is player-facing)

local warned = {}

local function out(level, msg)
    msg = 'fredpd_records: ' .. msg
    if type(lib) == 'table' and type(lib.print) == 'table' and lib.print[level] then
        lib.print[level](msg)
    else
        print(('[%s] %s'):format(level, msg))
    end
end

function M.warn(msg) out('warn', msg) end
function M.error(msg) out('error', msg) end

--- One warning per key for the lifetime of the resource.
function M.warnOnce(key, msg)
    if warned[key] then return end
    warned[key] = true
    out('warn', msg)
end

--- Tests only: forget which warnings were logged.
function M.resetWarnings()
    warned = {}
end

---------------------------------------------------------------------------------------------------------------
-- Other resources. `exports.res:fn(...)` is `exports.res.fn(exports.res, ...)`; every call is pcall-guarded, since
-- a stopped resource raises "No such export".

local function call(resource, name, ...)
    local proxy = exports[resource]
    return proxy[name](proxy, ...)
end

--- pcall(exports.fredpd_core:<name>(...)) -> ok, result.
function M.core(name, ...)
    return pcall(call, M.CORE, name, ...)
end

--- fredpd_core:<name>(...) or nil (logged once per export) when the call fails.
function M.coreOr(name, ...)
    local ok, res = M.core(name, ...)
    if not ok then
        M.warnOnce('core:' .. name, ('exports.fredpd_core:%s failed: %s'):format(name, tostring(res)))
        return nil
    end
    return res
end

--- Whether fredpd_bolo is running (checked once per request by the callers, not per hit).
function M.boloRunning()
    return GetResourceState(M.BOLO) == 'started'
end

--- pcall(exports.fredpd_bolo:<name>(...)) -> ok, result. false while fredpd_bolo is not started.
function M.bolo(name, ...)
    if not M.boloRunning() then return false, 'fredpd_bolo is not started' end
    return pcall(call, M.BOLO, name, ...)
end

--- exports.fredpd_bolo:getBolosFor(src, kind, id): the canView-filtered Bolo list for a person/vehicle page.
--- Accepts a plain array or a { ok, data } result; [] when fredpd_bolo is stopped or anything fails.
function M.bolosFor(src, kind, id)
    local ok, res = M.bolo('getBolosFor', src, kind, id)
    if not ok then
        if M.boloRunning() then
            M.warnOnce('bolo:list', ('exports.fredpd_bolo:getBolosFor failed: %s'):format(tostring(res)))
        end
        return {}
    end
    if type(res) == 'table' and res.ok ~= nil then res = res.ok == true and res.data or nil end
    if type(res) ~= 'table' then return {} end
    local list = {}
    for _, b in ipairs(res) do
        if type(b) == 'table' then list[#list + 1] = b end
    end
    return list
end

--- true when `bolo` (what fredpd_bolo's checkPlate/checkPerson returned: the live BOLO or nil) is one the viewer may
--- know about. The wire Bolo carries neither the BOLO's unit nor its issuer as fredpd_bolo's own VisRecord uses them,
--- so visibility is not rebuilt here: the flag is set only when that BOLO is also in getBolosFor(src, kind, id), which
--- fredpd_bolo filters with canView (any shape: full, masked or kontaktnotis). The flag and the page's BOLO list thus
--- always agree, under any rule set. Only hits that have a live BOLO pay for that call.
function M.boloVisible(src, kind, id, bolo)
    if type(bolo) ~= 'table' or bolo.active == false or bolo.active == 0 then return false end
    local boloId = M.int(bolo.id)
    if not boloId then return false end
    for _, b in ipairs(M.bolosFor(src, kind, id)) do
        if M.int(b.id) == boloId and b.active ~= false and b.active ~= 0 then return true end
    end
    return false
end

--- BOLO flag for a search hit / vehicle row: exports.fredpd_bolo:checkPlate(plate) or checkPerson(citizenid)
--- (memory only), then M.boloVisible. false when fredpd_bolo is stopped or a call fails. `running` =
--- M.boloRunning(), checked once by the caller.
function M.boloFlag(src, kind, id, running)
    if not running then return false end
    local ok, bolo = pcall(call, M.BOLO, kind == 'vehicle' and 'checkPlate' or 'checkPerson', id)
    if not ok then
        M.warnOnce('bolo:check', ('exports.fredpd_bolo check failed: %s'):format(tostring(bolo)))
        return false
    end
    return M.boloVisible(src, kind, id, bolo)
end

--- Audit a lookup (§4.5; basis for "obehörig sökning"). Fire-and-forget: a failed audit call is logged, never
--- turned into an error for the officer.
function M.audit(src, action, targetType, targetId, meta)
    local ok, err = M.core('audit', src, action, targetType, targetId, meta)
    if not ok then M.error(('audit %s failed: %s'):format(action, tostring(err))) end
end

--- Grant check through fredpd_core (fails closed).
function M.hasGrant(src, grantType, key)
    local ok, res = M.core('hasGrant', src, grantType, key)
    return ok and res == true
end

--- Viewer tier 0..2 (0 when unknown).
function M.tier(src)
    local ok, res = M.core('getTier', src)
    local n = ok and M.int(res) or nil
    if n == 1 or n == 2 then return n end
    return 0
end

---------------------------------------------------------------------------------------------------------------
-- Address from the housing adapter (IMPLEMENTATION.md §9; adapters/README.md: getAddresses(citizenid) ->
-- { { propertyId, label }, ... }, {} for the no-op adapter).

M.MAX_ADDRESSES = 3
M.MAX_ADDRESS_CHARS = 200

--- One display string (labels joined with '; ', at most 3, cut to 200 characters) or nil.
function M.address(citizenid)
    local ok, adapter = M.core('getAdapter', 'housing')
    if not ok or type(adapter) ~= 'table' or type(adapter.getAddresses) ~= 'function' then return nil end
    local okList, list = pcall(adapter.getAddresses, citizenid)
    if not okList then
        M.warnOnce('housing', ('housing adapter getAddresses failed: %s'):format(tostring(list)))
        return nil
    end
    if type(list) ~= 'table' then return nil end
    local labels = {}
    for _, entry in ipairs(list) do
        local label = type(entry) == 'table' and (M.str(entry.label) or M.str(entry[2])) or M.str(entry)
        if label then
            label = M.text(label, 1, M.MAX_ADDRESS_CHARS)
            if label then labels[#labels + 1] = label end
        end
        if #labels >= M.MAX_ADDRESSES then break end
    end
    if #labels == 0 then return nil end
    local text = table.concat(labels, '; ')
    if utf8.len(text) > M.MAX_ADDRESS_CHARS then text = text:sub(1, utf8.offset(text, M.MAX_ADDRESS_CHARS + 1) - 1) end
    return text
end

return M
