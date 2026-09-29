-- SPDX-License-Identifier: GPL-3.0-only
-- Door breach (IMPLEMENTATION.md §5.6, docs/contracts.md §C16, docs/modules/breach.md).
--
--   start(src, doorId)   callback fredpd:breach:start. Grant tool:ram → on duty → rate limit (1/s) and the
--                        per-player cooldown after a breach → door id → pd_ram in the player's inventory
--                        (ox_inventory GetItemCount) → door exists and is locked (ox_doorlock getDoor) → the
--                        player's ped (server-side position) within maxDistance of the door. Returns a one-time
--                        token bound to src + door, valid from progressMs - finishSlackMs to tokenTtlMs after the
--                        start. A new start replaces the player's previous token.
--   finish(src, token)   callback fredpd:breach:finish. The token must belong to src (another player's token is
--                        rejected and left alone), be unused, not too early (the progress bar cannot be skipped)
--                        and not expired; the token is consumed. Grant, duty, item, door locked and distance are
--                        checked again, then exports.ox_doorlock:setDoorState(id, 0) (ox_doorlock
--                        server/main.lua:275-314: an export call runs with source nil, so ox_doorlock's own
--                        authorisation is skipped — FredPD's checks above are the authorisation), audit
--                        'breach.door' { doorId, name, coords }, optional door evidence (config.breachEvidence).
--
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
    cooldownMs = 10000,
    maxDistance = 3.0,
    breachEvidence = false,
}

-- Filled by server/main.lua: Scene module (spawnEntries, validateTable) for config.breachEvidence.
M.scene = nil
local doorEvidence = {}

local tokens = {}      -- [token] = { src, doorId, issuedAt, expiresAt }
local tokenOf = {}     -- [src] = token (one live token per player)
local lastStart = {}   -- [src] = time of the last start attempt that passed grant + duty
local lastBreach = {}  -- [src] = time of the last successful breach

local warnedItem = false

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

--- Warn once when ox_inventory does not know the ram item (the ox_inventory patch was not applied).
function M.checkItem()
    if warnedItem then return end
    local okCall, items = pcall(function() return exports.ox_inventory:Items(M.cfg.ramItem) end)
    if okCall and items == nil then
        warnedItem = true
        M.log('warn', 'ox_inventory has no item "%s" (patches/ox_inventory.30-breach-items.patch not applied?); '
            .. 'nobody can breach doors until it exists', M.cfg.ramItem)
    end
end

--- true / false, or nil when ox_inventory could not answer.
local function hasItem(src)
    local okCall, count = pcall(function() return exports.ox_inventory:GetItemCount(src, M.cfg.ramItem) end)
    if not okCall then return nil end
    return (tonumber(count) or 0) > 0
end

local function getDoor(doorId)
    local okCall, door = pcall(function() return exports.ox_doorlock:getDoor(doorId) end)
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

--- Shared checks for start and finish (after grant + duty): item, door exists and is locked, distance.
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
    if door.state ~= 1 and door.state ~= true then return nil, 'validation', 'not_locked' end
    local pos = pedCoords(src)
    if not pos or distance(pos, door.coords) > M.cfg.maxDistance then return nil, 'validation', 'too_far' end
    return door
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

    doorId = math.tointeger(tonumber(doorId))
    if not doorId or doorId < 1 or doorId > 1000000 then return fail('validation', 'door') end

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
    local entry = tokens[token]
    if not entry or entry.src ~= src then return fail('not_found', 'token') end
    -- One-time: consumed whatever happens next.
    tokens[token] = nil
    if tokenOf[src] == token then tokenOf[src] = nil end

    local t = now()
    if t > entry.expiresAt then return fail('expired', 'token') end
    if t - entry.issuedAt < M.cfg.progressMs - M.cfg.finishSlackMs then return fail('validation', 'too_early') end
    if not hasGrant(src) then return fail('unauthorized', 'grant') end
    if not onDuty(src) then return fail('unauthorized', 'off_duty') end

    local door, code, reason = checkDoor(src, entry.doorId)
    if not door then return fail(code, reason) end

    local okSet, result = pcall(function() return exports.ox_doorlock:setDoorState(entry.doorId, 0) end)
    if not okSet or result ~= true then
        M.log('error', 'ox_doorlock setDoorState(%d, 0) failed: %s', entry.doorId, tostring(result))
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
end

function M.reset()
    tokens, tokenOf, lastStart, lastBreach = {}, {}, {}, {}
    warnedItem = false
end

return M
