-- SPDX-License-Identifier: GPL-3.0-only
-- Door breach (IMPLEMENTATION.md §5.6, docs/contracts.md §C16, docs/modules/breach.md). Inventory and doorlock go
-- through fredpd_core's bridge (docs/contracts.md §C17: qb-inventory/ox_inventory, qb-doorlock/ox_doorlock).
--
--   start(src, doorId)   callback fredpd:breach:start. Grant tool:ram → on duty → rate limit (1/s) and the
--                        per-player cooldown after a breach → door id → pd_ram in the player's inventory
--                        (exports.fredpd_core:count) → door exists, is not in config.denyDoors and is locked
--                        (exports.fredpd_core:getDoor) → the player's ped (server-side position) within maxDistance
--                        of the door. Returns a one-time token bound to src + door, valid from
--                        progressMs - finishSlackMs to tokenTtlMs after the start. A new start replaces the player's
--                        previous token.
--   finish(src, token)   callback fredpd:breach:finish. Per-src rate limit (finishRateMs) before the token lookup.
--                        The token must belong to src (another player's token is rejected and left alone), be
--                        unused, not too early (the progress bar cannot be skipped) and not expired; the token is
--                        consumed. Grant, duty, item, door locked and distance are checked again, then
--                        exports.fredpd_core:setLocked(id, false, src) (no authorisation happens in the doorlock
--                        resource on that path: FredPD's checks above are the authorisation), audit 'breach.door'
--                        { doorId, name, coords }, optional door evidence (config.breachEvidence).
--
-- Door ids: ox_doorlock ids are integers; qb-doorlock ids are its Config.DoorList keys (integers or strings).
-- Results (§C12 shape): { ok = true, data = ... } | { ok = false, error = <code>, reason = <why> }.
-- Codes: unauthorized (grant / off_duty), rate_limited (rate / cooldown), validation (door / no_item / not_locked /
-- too_far / too_early / token), not_found (door / token), expired, unavailable.

local M = {}

M.cfg = {
    ramItem = 'pd_ram',
    grant = { 'tool', 'ram' },
    progressMs = 4000,
    finishSlackMs = 500,
    tokenTtlMs = 8000,
    startRateMs = 1000,
    finishRateMs = 250,
    cooldownMs = 10000,
    maxDistance = 3.0,
    breachEvidence = false,
    denyDoors = {},
}

-- Filled by server/main.lua: Scene module (spawnEntries, validateTable) for config.breachEvidence.
M.scene = nil
local doorEvidence = {}

local tokens = {}      -- [token] = { src, doorId, issuedAt, expiresAt }
local tokenOf = {}     -- [src] = token (one live token per player)
local lastStart = {}   -- [src] = time of the last start attempt that passed grant + duty
local lastBreach = {}  -- [src] = time of the last successful breach
local lastFinish = {}  -- [src] = time of the last finish attempt (rate limit, before the token lookup)

local warnedItem = false
local itemFound = false

function M.log(level, fmt, ...)
    local msg = select('#', ...) > 0 and fmt:format(...) or tostring(fmt)
    local printer = type(lib) == 'table' and type(lib.print) == 'table' and lib.print[level]
    if printer then printer(msg) else print(('[fredpd_breach] %s: %s'):format(level, msg)) end
end

function M.configure(cfg)
    for k, v in pairs(cfg or {}) do
        if M.cfg[k] ~= nil then M.cfg[k] = v end
    end
    doorEvidence = {}
    if type(M.cfg.breachEvidence) == 'table' and M.scene then
        doorEvidence = M.scene.validateTable({ burglary = M.cfg.breachEvidence }).burglary or {}
    end
end

local function now() return GetGameTimer() end
local function ok(data) return { ok = true, data = data } end
local function fail(code, reason) return { ok = false, error = code, reason = reason } end
local function core() return exports.fredpd_core end

local function hasGrant(src)
    local g = M.cfg.grant
    local okCall, allowed = pcall(function() return core():hasGrant(src, g[1], g[2]) end)
    return okCall and allowed == true
end

local function onDuty(src)
    local okCall, duty = pcall(function() return core():isOnDuty(src) end)
    return okCall and duty == true
end

local function bridgeInfo()
    local okCall, info = pcall(function() return core():bridgeInfo() end)
    return okCall and type(info) == 'table' and info or {}
end

--- true when the bridge's resource of `kind` (inventory / doorlock) runs.
local function running(kind)
    local res = bridgeInfo()[kind]
    return type(res) == 'string' and GetResourceState(res) == 'started'
end

-- Where the selected stack defines items (bridge kind -> file): qb-inventory items live in the framework's
-- shared/items.lua (patches/qb-core.10-fredpd-items.patch), ox_inventory's in its data/items.lua
-- (patches/ox_inventory.30-breach-items.patch). A file that does not exist in that resource is skipped.
M.ITEM_FILES = { { kind = 'inventory', path = 'data/items.lua' }, { kind = 'framework', path = 'shared/items.lua' } }

local function escape(s) return (s:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]', '%%%0')) end

--- true when a definition file text defines `item` (qb `name = 'item'`, ox `['item'] =`).
function M.definesItem(text, item)
    local e = escape(item)
    return text:find('name%s*=%s*[\'"]' .. e .. '[\'"]') ~= nil
        or text:find('%[%s*[\'"]' .. e .. '[\'"]%s*%]%s*=') ~= nil
end

--- Warn once when no item definition file of the selected stack (bridgeInfo) defines the ram item (its FredPD
--- items patch was not applied). Nothing is said when no definition file can be read (nothing to judge).
function M.checkItem()
    if warnedItem or itemFound then return end
    local info = bridgeInfo()
    local read, where = false, {}
    for _, f in ipairs(M.ITEM_FILES) do
        local res = info[f.kind]
        if type(res) == 'string' then
            local okRead, text = pcall(LoadResourceFile, res, f.path)
            if okRead and type(text) == 'string' and text ~= '' then
                read = true
                if M.definesItem(text, M.cfg.ramItem) then
                    itemFound = true -- checked once: the files are not read again on every no_item
                    return
                end
                where[#where + 1] = res .. '/' .. f.path
            end
        end
    end
    if read then
        warnedItem = true
        M.log('warn', 'no item "%s" in %s (the FredPD items patch for this inventory is not applied, see '
            .. 'docs/modules/breach.md); nobody can breach doors until it exists', M.cfg.ramItem, table.concat(where, ', '))
    end
end

--- true / false, or nil when the inventory could not answer (its resource is not running).
local function hasItem(src)
    if not running('inventory') then return nil end
    local okCall, count = pcall(function() return core():count(src, M.cfg.ramItem) end)
    if not okCall then return nil end
    return (tonumber(count) or 0) > 0
end

--- { id, name, locked, coords } or nil, 'unavailable' | 'not_found'.
local function getDoor(doorId)
    if not running('doorlock') then return nil, 'unavailable' end
    local okCall, door = pcall(function() return core():getDoor(doorId) end)
    if not okCall then return nil, 'unavailable' end
    if type(door) ~= 'table' or door.coords == nil then return nil, 'not_found' end
    return door
end

local function pedCoords(src)
    local okCall, pos = pcall(function() return GetEntityCoords(GetPlayerPed(src)) end)
    if not okCall or pos == nil then return nil end
    return pos
end

local function distance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- true when config.denyDoors excludes the door: an entry is a door id (number, or a qb-doorlock string key), an
--- exact door name (string) or a Lua pattern on the name or on the lower-cased name ({ pattern = '^mrpd_' }).
function M.isDenied(doorId, name)
    for _, d in ipairs(type(M.cfg.denyDoors) == 'table' and M.cfg.denyDoors or {}) do
        if d == doorId then return true end
        if type(name) == 'string' then
            if type(d) == 'string' and d == name then return true end
            if type(d) == 'table' and type(d.pattern) == 'string' then
                local okMatch, hit = pcall(string.find, name, d.pattern)
                if okMatch and hit then return true end
                okMatch, hit = pcall(string.find, name:lower(), d.pattern)
                if okMatch and hit then return true end
            end
        end
    end
    return false
end

--- Shared checks for start and finish (after grant + duty): item, door exists, not denied, locked, distance.
--- @return table|nil door, string|nil code, string|nil reason
local function checkDoor(src, doorId)
    local item = hasItem(src)
    if item == nil then return nil, 'unavailable', 'inventory' end
    if not item then
        M.checkItem()
        return nil, 'validation', 'no_item'
    end
    local door, err = getDoor(doorId)
    if not door then
        if err == 'unavailable' then return nil, 'unavailable', 'doorlock' end
        return nil, 'not_found', 'door'
    end
    if M.isDenied(doorId, door.name) then return nil, 'validation', 'denied' end
    if door.locked ~= true then return nil, 'validation', 'not_locked' end
    local pos = pedCoords(src)
    if not pos or distance(pos, door.coords) > M.cfg.maxDistance then return nil, 'validation', 'too_far' end
    return door
end

--- The client's door id, validated: an integer 1..1e6 (also as a numeric string) or a qb-doorlock string key
--- (valid UTF-8 without control characters, e.g. 'häktet_1'; at most 64 bytes: the audit target id). nil when invalid.
function M.doorId(v)
    if type(v) == 'number' or (type(v) == 'string' and v:match('^%d+$')) then
        local n = math.tointeger(tonumber(v))
        if n and n >= 1 and n <= 1000000 then return n end
        return nil
    end
    if type(v) == 'string' and #v >= 1 and #v <= 64 and not v:find('%c') and utf8.len(v) then return v end
    return nil
end

function M.newToken()
    local parts = {}
    for i = 1, 4 do parts[i] = ('%08x'):format(math.random(0, 0x7FFFFFFF)) end
    return table.concat(parts)
end

local function dropToken(src)
    local t = tokenOf[src]
    if t then tokens[t] = nil end
    tokenOf[src] = nil
end

--- Remove expired tokens (called on every start; no timer).
function M.prune()
    local t = now()
    for token, e in pairs(tokens) do
        if t > e.expiresAt then
            tokens[token] = nil
            if tokenOf[e.src] == token then tokenOf[e.src] = nil end
        end
    end
end

function M.start(src, doorId)
    src = math.tointeger(tonumber(src))
    if not src or src < 1 then return fail('validation', 'source') end
    if not hasGrant(src) then return fail('unauthorized', 'grant') end
    if not onDuty(src) then return fail('unauthorized', 'off_duty') end
    local t = now()
    if lastStart[src] and t - lastStart[src] < M.cfg.startRateMs then return fail('rate_limited', 'rate') end
    lastStart[src] = t
    if lastBreach[src] and t - lastBreach[src] < M.cfg.cooldownMs then return fail('rate_limited', 'cooldown') end

    doorId = M.doorId(doorId)
    if doorId == nil then return fail('validation', 'door') end

    local door, code, reason = checkDoor(src, doorId)
    if not door then return fail(code, reason) end

    M.prune()
    dropToken(src)
    local token = M.newToken()
    while tokens[token] do token = M.newToken() end
    tokens[token] = { src = src, doorId = doorId, issuedAt = t, expiresAt = t + M.cfg.tokenTtlMs }
    tokenOf[src] = token
    return ok({ token = token, doorId = doorId, durationMs = M.cfg.progressMs })
end

local function round2(n) return math.floor(n * 100 + 0.5) / 100 end

function M.finish(src, token)
    src = math.tointeger(tonumber(src))
    if not src or src < 1 then return fail('validation', 'source') end
    if type(token) ~= 'string' or #token ~= 32 or not token:match('^%x+$') then return fail('validation', 'token') end
    local t = now()
    if lastFinish[src] and t - lastFinish[src] < M.cfg.finishRateMs then return fail('rate_limited', 'rate') end
    lastFinish[src] = t
    local entry = tokens[token]
    if not entry or entry.src ~= src then return fail('not_found', 'token') end
    -- One-time: consumed whatever happens next.
    tokens[token] = nil
    if tokenOf[src] == token then tokenOf[src] = nil end

    if t > entry.expiresAt then return fail('expired', 'token') end
    if t - entry.issuedAt < M.cfg.progressMs - M.cfg.finishSlackMs then return fail('validation', 'too_early') end
    if not hasGrant(src) then return fail('unauthorized', 'grant') end
    if not onDuty(src) then return fail('unauthorized', 'off_duty') end

    local door, code, reason = checkDoor(src, entry.doorId)
    if not door then return fail(code, reason) end

    -- src is passed so qb-doorlock plays its door animation for the breaching officer (docs/modules/bridge.md).
    local okSet, result = pcall(function() return core():setLocked(entry.doorId, false, src) end)
    if not okSet or result ~= true then
        M.log('error', 'unlocking door %s failed: %s', tostring(entry.doorId), tostring(result))
        return fail('unavailable', 'doorlock')
    end
    lastBreach[src] = t

    local c = door.coords
    local coords = { x = round2(c.x), y = round2(c.y), z = round2(c.z) }
    local okAudit, err = pcall(function()
        core():audit(src, 'breach.door', 'door', entry.doorId, { doorId = entry.doorId, name = door.name,
            coords = coords })
    end)
    if not okAudit then M.log('error', 'audit breach.door failed: %s', tostring(err)) end

    local spawned = {}
    if #doorEvidence > 0 and M.scene and M.scene.evidencesStarted() then
        spawned = M.scene.spawnEntries(doorEvidence, c, src, { scene = 'breach' })
    end
    return ok({ doorId = entry.doorId, evidence = spawned })
end

--- playerDropped: forget the player's token and timers.
function M.forget(src)
    src = math.tointeger(tonumber(src))
    if not src then return end
    dropToken(src)
    lastStart[src] = nil
    lastBreach[src] = nil
    lastFinish[src] = nil
end

function M.reset()
    tokens, tokenOf, lastStart, lastBreach, lastFinish = {}, {}, {}, {}, {}
    warnedItem, itemFound = false, false
end

return M
