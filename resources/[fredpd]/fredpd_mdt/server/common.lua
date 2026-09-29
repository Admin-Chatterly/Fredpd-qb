-- SPDX-License-Identifier: GPL-3.0-only
-- Shared helpers for the fredpd_mdt server modules: player ids, the per-player rate limiter, pcall-guarded calls into
-- fredpd_core and other resources, and throttled logging. No FiveM calls at load time (tests/lua/mdt_*_test.lua load
-- the modules outside the game).

local M = {}

M.LOG_INTERVAL_MS = 60000

--- Locale function; server/main.lua sets it to fredpd_core's L (the key itself until then).
M.L = function(key) return key end

function M.now()
    return GetGameTimer()
end

--- A connected player's server id as an integer (> 0), else nil. Accepts '12' (FiveM passes some ids as strings).
function M.playerSrc(src)
    local n = math.tointeger(tonumber(src))
    if not n or n < 1 then return nil end
    return n
end

---------------------------------------------------------------------------------------------------------------
-- Logging

local lastLog, suppressed = {}, {}

function M.log(level, fmt, ...)
    local msg = select('#', ...) > 0 and fmt:format(...) or tostring(fmt)
    local printer = type(lib) == 'table' and type(lib.print) == 'table' and lib.print[level]
    if printer then printer(msg) else print(('[fredpd_mdt] %s: %s'):format(level, msg)) end
end

--- Log at most once per LOG_INTERVAL_MS per key (with the number of messages swallowed in between).
function M.logThrottled(key, level, fmt, ...)
    local t = M.now()
    if lastLog[key] and t - lastLog[key] < M.LOG_INTERVAL_MS then
        suppressed[key] = (suppressed[key] or 0) + 1
        return
    end
    lastLog[key] = t
    local extra = suppressed[key] and (' (%d similar suppressed)'):format(suppressed[key]) or ''
    suppressed[key] = nil
    M.log(level, fmt .. extra, ...)
end

---------------------------------------------------------------------------------------------------------------
-- Rate limiter: one timestamp per player and key. Cleared on playerDropped (M.forget).

local limits = {}

--- true (and the window restarted) when `src` may run `key` now, at most once per `ms`.
function M.allow(src, key, ms)
    local t = M.now()
    local mine = limits[src]
    if not mine then
        mine = {}
        limits[src] = mine
    end
    local last = mine[key]
    if last and t - last < ms then return false end
    mine[key] = t
    return true
end

function M.forget(src)
    limits[src] = nil
end

function M.resetLimits()
    limits = {}
end

---------------------------------------------------------------------------------------------------------------
-- fredpd_core (every call pcall'd: a stopped or restarting core must fail closed, not raise in a handler)

--- exports.fredpd_core:<fn>(...) -> ok, result (ok = false when the call raised).
function M.core(fn, ...)
    local args = table.pack(...)
    local ok, res = pcall(function()
        local core = exports.fredpd_core
        return core[fn](core, table.unpack(args, 1, args.n))
    end)
    if not ok then
        M.logThrottled('core:' .. fn, 'error', 'fredpd_core:%s failed: %s', fn, tostring(res))
        return false, nil
    end
    return true, res
end

function M.hasGrant(src, grantType, key)
    local ok, res = M.core('hasGrant', src, grantType, key)
    return ok and res == true
end

function M.isOnDuty(src)
    local ok, res = M.core('isOnDuty', src)
    return ok and res == true
end

function M.citizenId(src)
    local ok, res = M.core('getCitizenId', src)
    if ok and type(res) == 'string' and res ~= '' then return res end
    return nil
end

---------------------------------------------------------------------------------------------------------------
-- Inventory, through fredpd_core's bridge (docs/contracts.md §C17: qb-inventory or ox_inventory; the bridge
-- normalises qb `info` and ox `metadata` to `metadata`). Never a direct inventory call from this resource.

--- Number of `item` the player holds, or nil when fredpd_core raised.
function M.itemCount(src, item)
    local ok, n = M.core('count', src, item)
    if not ok then return nil end
    return math.tointeger(tonumber(n)) or 0
end

--- { { slot, metadata }, ... } sorted by slot, or nil when fredpd_core raised.
function M.findItems(src, item)
    local ok, list = M.core('find', src, item)
    if not ok then return nil end
    return type(list) == 'table' and list or {}
end

--- Give an item (metadata = ox metadata / qb info). true when added. The bridge has no CanCarryItem: a full
--- inventory, an item unknown to the inventory or a stopped inventory all answer false here.
function M.addItem(src, item, count, metadata)
    local ok, added = M.core('add', src, item, count, metadata)
    return ok and added == true
end

--- Is the inventory resource the bridge selected running? Tells "no item" from "inventory down" (the bridge answers
--- count 0 / add false for both). Only reads fredpd_core's selection and the resource state.
function M.inventoryUp()
    local ok, info = M.core('bridgeInfo')
    local name = ok and type(info) == 'table' and info.inventory or nil
    return type(name) == 'string' and GetResourceState(name) == 'started'
end

--- Every `mdt_page` key (packages/types/src/mdtPages.ts MDT_PAGE_KEYS). The tablet opens with at least one.
M.MDT_PAGE_KEYS = { 'search', 'alerts', 'bolos', 'cases', 'evidence', 'intel', 'charges', 'roster', 'command' }

--- Does the player hold any mdt_page grant (wildcard and deny rules applied by fredpd_core)?
function M.anyMdtGrant(src)
    for _, key in ipairs(M.MDT_PAGE_KEYS) do
        if M.hasGrant(src, 'mdt_page', key) then return true end
    end
    return false
end

--- Audit through fredpd_core (actor resolved there from src; 0 = system/console). Never raises.
function M.audit(src, action, targetType, targetId, meta)
    local ok = M.core('audit', src, action, targetType, targetId, meta)
    return ok
end

---------------------------------------------------------------------------------------------------------------
-- Another resource's tablet export (§C12 convention: { ok = true, data } | { ok = false, error, reason? })

M.ERROR_CODES = { unauthorized = true, not_found = true, validation = true, rate_limited = true, unavailable = true }

function M.fail(code, reason)
    return { ok = false, error = code, reason = reason }
end

function M.ok(data)
    return { ok = true, data = data }
end

--- Call exports[resource][fn](src, input) when the resource is started. A raise, a missing resource or a malformed
--- answer becomes { ok = false, error = 'unavailable' } (logged, throttled).
function M.callExport(resource, fn, src, input)
    if GetResourceState(resource) ~= 'started' then
        M.logThrottled('down:' .. resource, 'warn', '%s is not started; %s answered unavailable', resource, fn)
        return M.fail('unavailable')
    end
    local ok, res = pcall(function()
        local res = exports[resource]
        return res[fn](res, src, input)
    end)
    if not ok then
        M.logThrottled('export:' .. resource .. ':' .. fn, 'error', '%s:%s failed: %s', resource, fn, tostring(res))
        return M.fail('unavailable')
    end
    if type(res) ~= 'table' or type(res.ok) ~= 'boolean' then
        M.logThrottled('shape:' .. resource .. ':' .. fn, 'error', '%s:%s returned no { ok } result', resource, fn)
        return M.fail('unavailable')
    end
    return res
end

return M
