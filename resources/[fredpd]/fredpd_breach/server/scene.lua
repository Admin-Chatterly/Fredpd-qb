-- SPDX-License-Identifier: GPL-3.0-only
-- Scene evidence (IMPLEMENTATION.md §5.6, docs/contracts.md §C16, docs/modules/breach.md).
--
-- exports.fredpd_breach:sceneEvidence(kind, coords, suspectSrc) is called by crime scripts on the server (exports
-- are never reachable from a client). It validates the kind against config/scene_evidence.lua, the coords (finite,
-- inside config.mapBounds) and the suspect (a connected player), applies a per-location cooldown (same kind within
-- config.sceneRadius during config.sceneCooldownMs), and spawns each
-- rolled entry with exports.evidences:syncEvidence(type, suspectSrc, 'atCoords', vector3, meta)
-- (evidences server/evidences/api.lua:50-60, classes/evidence.lua:224-245). The suspect's server id is resolved to
-- the fingerprint / DNA key by evidences itself (api.lua:34-37). Every spawn is audited 'breach.scene'.
--
-- Returns (§C12 shape): { ok = true, data = { spawned = { type, ... } } } | { ok = false, error, reason }.

local M = {}

--- Evidence types evidences can spawn (evidences server/evidences/api.lua:7-15).
M.EVIDENCES_TYPES = {
    fingerprint = true, blood = true, saliva = true, magazine = true, casing = true, bullet = true,
    gunshot_residue = true,
}

--- SceneKind (packages/types/src/evidence.ts SceneKindSchema).
M.SCENE_KINDS = { burglary = true, shooting = true, assault = true, robbery = true, vehicle_theft = true }

M.cfg = {
    sceneCooldownMs = 60000,
    sceneRadius = 5.0,
    sceneSpacing = 0.25,
    mapBounds = { minX = -4500.0, maxX = 4500.0, minY = -4500.0, maxY = 8500.0, minZ = -200.0, maxZ = 1500.0 },
}
M.table = {}        -- validated scene table: [kind] = { { type, chance }, ... } (only spawnable entries)

local recent = {}   -- [kind] = { { x, y, z, at }, ... } accepted scenes still in their cooldown
local warnedOnce = {}

function M.log(level, fmt, ...)
    local msg = select('#', ...) > 0 and fmt:format(...) or tostring(fmt)
    local printer = type(lib) == 'table' and type(lib.print) == 'table' and lib.print[level]
    if printer then printer(msg) else print(('[fredpd_breach] %s: %s'):format(level, msg)) end
end

local function warnOnce(key, fmt, ...)
    if warnedOnce[key] then return end
    warnedOnce[key] = true
    M.log('warn', fmt, ...)
end

local function now()
    return GetGameTimer()
end

--- Keep only entries evidences can spawn; unknown kinds and unsupported types warn once.
--- @return table validated table
function M.validateTable(raw)
    local out = {}
    for kind, entries in pairs(type(raw) == 'table' and raw or {}) do
        if not M.SCENE_KINDS[kind] then
            warnOnce('kind:' .. tostring(kind), 'config/scene_evidence.lua: "%s" is not a SceneKind; ignored',
                tostring(kind))
        elseif type(entries) == 'table' then
            local list = {}
            for i, e in ipairs(entries) do
                local chance = type(e) == 'table' and tonumber(e.chance) or nil
                if type(e) ~= 'table' or type(e.type) ~= 'string' then
                    warnOnce(('entry:%s:%d'):format(kind, i), 'config/scene_evidence.lua: %s[%d] has no type; ignored',
                        kind, i)
                elseif not M.EVIDENCES_TYPES[e.type] then
                    warnOnce('type:' .. e.type, 'config/scene_evidence.lua: evidences has no "%s" evidence; '
                        .. 'those entries are skipped', e.type)
                else
                    list[#list + 1] = { type = e.type, chance = math.max(0, math.min(100, chance or 100)) }
                end
            end
            out[kind] = list
        end
    end
    return out
end

function M.configure(cfg, sceneTable)
    for k, v in pairs(cfg or {}) do
        if M.cfg[k] ~= nil or k == 'mapBounds' then M.cfg[k] = v end
    end
    M.table = M.validateTable(sceneTable)
end

local function finite(n)
    return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge
end

--- { x, y, z } from a vector3 or a table, or nil when not three finite numbers inside the map bounds.
function M.readCoords(c)
    local t = type(c)
    if t ~= 'table' and t ~= 'userdata' and t ~= 'vector3' then return nil end
    local ok, x, y, z = pcall(function() return c.x, c.y, c.z end)
    if not ok or not finite(x) or not finite(y) or not finite(z) then return nil end
    local b = M.cfg.mapBounds
    if x < b.minX or x > b.maxX or y < b.minY or y > b.maxY or z < b.minZ or z > b.maxZ then return nil end
    return { x = x, y = y, z = z }
end

--- A connected player's server id, or nil.
function M.connected(src)
    src = math.tointeger(tonumber(src))
    if not src or src < 1 then return nil end
    local ok, exists = pcall(DoesPlayerExist, src)
    if not ok or not exists then return nil end
    return src
end

--- true when a scene of this kind was accepted within sceneRadius of p less than sceneCooldownMs ago.
function M.onCooldown(kind, p, t)
    for _, r in ipairs(recent[kind] or {}) do
        local dx, dy, dz = r.x - p.x, r.y - p.y, r.z - p.z
        if t - r.at < M.cfg.sceneCooldownMs and dx * dx + dy * dy + dz * dz <= M.cfg.sceneRadius ^ 2 then
            return true
        end
    end
    return false
end

function M.citizenOf(src)
    local ok, cid = pcall(function() return exports.fredpd_core:getCitizenId(src) end)
    return ok and type(cid) == 'string' and cid or nil
end

local function round2(n) return math.floor(n * 100 + 0.5) / 100 end

local function vec(x, y, z)
    if type(vector3) == 'function' then return vector3(x, y, z) end
    return { x = x, y = y, z = z }
end

--- Spawn entries at p (piece i shifted by (i-1) * sceneSpacing along x). The suspect/owner is a server id.
--- @return string[] spawned types
function M.spawnEntries(entries, p, owner, meta)
    local spawned = {}
    local piece = 0
    for _, e in ipairs(entries) do
        if M.EVIDENCES_TYPES[e.type] and math.random(1, 100) <= (e.chance or 100) then
            local pos = vec(p.x + piece * M.cfg.sceneSpacing, p.y, p.z)
            piece = piece + 1
            local ok, err = pcall(function()
                exports.evidences:syncEvidence(e.type, owner, 'atCoords', pos, meta)
            end)
            if ok then
                spawned[#spawned + 1] = e.type
            else
                M.log('error', 'evidences:syncEvidence(%s, atCoords) failed: %s', e.type, tostring(err))
            end
        end
    end
    return spawned
end

--- fredpd_core's bridge feature 'evidence' (docs/contracts.md §C17): evidences started on the ox inventory + ox
--- target stack. On the qb stack (evidences needs both ox resources) scene evidence stays off: one warning, then
--- 'unavailable' answers.
function M.evidencesStarted()
    local ok, on = pcall(function() return exports.fredpd_core:hasFeature('evidence') end)
    if ok and on == true and GetResourceState('evidences') == 'started' then return true end
    warnOnce('evidences', 'scene evidence is disabled: fredpd_core reports the evidence feature off (evidences '
        .. 'started, on the ox inventory + target stack, is needed)')
    return false
end

local function audit(src, action, targetType, targetId, meta)
    local ok, err = pcall(function() exports.fredpd_core:audit(src, action, targetType, targetId, meta) end)
    if not ok then M.log('error', 'audit %s failed: %s', action, tostring(err)) end
end

local function fail(code, reason) return { ok = false, error = code, reason = reason } end

--- The export. kind: SceneKind; coords: vector3 or { x, y, z }; suspectSrc: server id of the suspect.
function M.sceneEvidence(kind, coords, suspectSrc)
    if type(kind) ~= 'string' or not M.table[kind] then return fail('validation', 'kind') end
    local p = M.readCoords(coords)
    if not p then return fail('validation', 'coords') end
    local suspect = M.connected(suspectSrc)
    if not suspect then return fail('validation', 'suspect') end
    if not M.evidencesStarted() then return fail('unavailable', 'evidences') end

    local t = now()
    M.prune()
    if M.onCooldown(kind, p, t) then return fail('rate_limited', 'cooldown') end
    recent[kind] = recent[kind] or {}
    table.insert(recent[kind], { x = p.x, y = p.y, z = p.z, at = t })

    local spawned = M.spawnEntries(M.table[kind], p, suspect, { scene = kind })
    local invoker = type(GetInvokingResource) == 'function' and GetInvokingResource() or nil
    audit(0, 'breach.scene', 'scene', kind, {
        kind = kind,
        coords = { x = round2(p.x), y = round2(p.y), z = round2(p.z) },
        suspect = suspect,
        suspectCitizenid = M.citizenOf(suspect),
        spawned = spawned,
        by = invoker,
    })
    return { ok = true, data = { spawned = spawned } }
end

--- Forget cooldowns older than the cooldown (called on each scene; the table stays small without a timer).
function M.prune()
    local t = now()
    for kind, list in pairs(recent) do
        for i = #list, 1, -1 do
            if t - list[i].at >= M.cfg.sceneCooldownMs then table.remove(list, i) end
        end
        if #list == 0 then recent[kind] = nil end
    end
end

function M.reset()
    recent = {}
    warnedOnce = {}
end

return M
