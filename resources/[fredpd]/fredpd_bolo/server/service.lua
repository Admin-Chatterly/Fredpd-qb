-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_bolo behaviour behind the exports (docs/contracts.md §C12, IMPLEMENTATION.md §4.3, §5.4).
--
-- Tablet actions (fredpd_mdt dispatcher; return { ok = true, data } or { ok = false, error, reason? }):
--   listBolos(src, BoloListInput)      mdt_page:bolos     -> BoloListOutput (canView per BOLO)
--   createBolo(src, BoloCreateInput)   perm:bolo.create   -> Bolo
--   resolveBolo(src, BoloResolveInput) perm:bolo.resolve  -> Bolo
--   plateCheck(src, { plate })         mdt_page:search    -> PlateCheckResult (records the check, fires boloHit)
-- The dispatcher has already checked grant, duty and its rate limit; grant, duty and input are checked again here
-- (any resource can call an export).
-- Server lookups (no player, no canView; never wait): checkPlate(plate) -> Bolo|nil, checkPerson(citizenid) ->
-- Bolo|nil. For records: getBolosFor(src, kind, id) -> Bolo[] (canView-filtered), hasVisibleBolo(src, kind, id) ->
-- boolean (memory, canView on the cached entry). Impound: resolveOnImpound(plate, src) -> boolean. ox_target:
-- targetCheck(source, netId) behind lib.callback 'fredpd:bolo:plateCheck'.
--
-- Hits and canView 'none' (docs/modules/bolo.md "Hidden BOLOs"): the checking officer's result is shaped by their own
-- canView ('none' -> PlateCheckResult.bolo = nil); the check row, the bolo.check audit and fredpd:boloHit (server-side)
-- still record the hit. The broadcast alert carries only what the least-privileged viewer may see
-- (Visibility.publicReason) and is not raised at all when that is 'none'.
--
-- Error codes are MDT_ERROR_CODES; `reason` refines them: 'off_duty', 'level' (level above the actor's tier),
-- 'duplicate' (an active BOLO for that subject exists), 'too_far', 'no_plate'.

local Input = require 'shared.input'
local Store = require 'server.store'
local Cache = require 'server.cache'
local Visibility = require 'server.visibility'
local Fanout = require 'server.fanout'
local Time = require '@fredpd_core.shared.time'

local M = {}

M.TARGET_RATE_MS = 1000 -- ox_target plate check: 1 per second per player (server side)
M.TARGET_DISTANCE = 10.0 -- metres between the officer and the vehicle (ox_target option distance is 3)
M.REBUILD_ATTEMPTS = 5
-- In-flight flags (rebuild, create per subject) hold the GetGameTimer() they were set at. MySQL.*.await never resumes
-- when the pool cannot hand out a connection (docs/deps-verification.md §10), so a flag older than this is treated as
-- released on the next call (no timer): a DB outage cannot block rebuilds or a subject for good.
M.STALE_FLAG_MS = 30000

--- True while a flag set at `since` (GetGameTimer ms, or nil) is still held.
local function held(since)
    return since ~= nil and GetGameTimer() - since < M.STALE_FLAG_MS
end

--- Locale function; server/main.lua sets it to fredpd_core's L.
M.L = function(key) return key end

local function fail(code, reason)
    return { ok = false, error = code, reason = reason }
end

local function ok(data)
    return { ok = true, data = data }
end

local function liveOf(entry)
    return Cache.isLive(entry)
end

--- The acting officer: a connected player holding the grant, on duty, with a character.
--- @return table|nil { src, citizenid }, string|nil error, string|nil reason
function M.actor(src, grantType, grantKey)
    src = math.tointeger(tonumber(src))
    if not src or src < 1 then return nil, 'unauthorized' end
    local okCall, has, onDuty, citizenid = pcall(function()
        local core = exports.fredpd_core
        if core:hasGrant(src, grantType, grantKey) ~= true then return false end
        return true, core:isOnDuty(src) == true, core:getCitizenId(src)
    end)
    if not okCall then
        Fanout.logThrottled('core', 'error', 'fredpd_core unavailable: %s', tostring(has))
        return nil, 'unavailable'
    end
    if not has then return nil, 'unauthorized' end
    if not onDuty then return nil, 'unauthorized', 'off_duty' end
    if type(citizenid) ~= 'string' or citizenid == '' then return nil, 'unauthorized' end
    return { src = src, citizenid = citizenid }
end

---------------------------------------------------------------------------------------------------------------
-- Cache: rebuild and lazy expiry

local expiring = {} -- [id] = true while the expiry UPDATE is in flight

--- Deactivate an expired BOLO (never waits). The audit row, push and event follow only when this call changed the
--- row (a concurrent resolve or another expiry wins silently). The UPDATE also requires expires_at <= UTC_TIMESTAMP()
--- (Store.EXPIRE_SQL): when the FXServer clock runs ahead of the database it changes nothing, and nothing is rebuilt
--- either. The cache has already dropped the entry (no hits, by this host's clock); a rebuild would load the row
--- again, find it expired again and repeat the refused UPDATE until the database clock caught up. The row is
--- deactivated (and bolo.expire written) by the next rebuild, list or getBolosFor that meets it after that.
function M.expire(entry)
    if expiring[entry.id] then return end
    expiring[entry.id] = true
    local okCall, err = pcall(Store.expire, entry.id, function(affected)
        expiring[entry.id] = nil
        if affected > 0 then
            Fanout.audit(0, 'bolo.expire', 'bolo', entry.id, { expiresAt = entry.expiresAt })
            Fanout.changed(Visibility.wire(entry, false), 'expired')
            M.scheduleRebuild()
        end
    end)
    if not okCall then
        expiring[entry.id] = nil
        Fanout.logThrottled('expire', 'error', 'expiring BOLO #%d failed: %s', entry.id, tostring(err))
    end
end

Cache.onExpire = M.expire

--- Reload the active BOLOs (awaits). false when the query failed or a write overtook it.
function M.rebuild()
    local startGen = Cache.gen
    local okLoad, entries = pcall(Store.loadActive)
    if not okLoad then
        Fanout.logThrottled('rebuild', 'error', 'loading active BOLOs failed: %s', tostring(entries))
        return false
    end
    return Cache.replaceAll(entries, startGen)
end

local rebuildingSince, dirty = nil, false -- GetGameTimer() when the running rebuild started

--- Rebuild in a thread of its own; changes during a rebuild make it run again (bounded, no loop while idle).
function M.scheduleRebuild()
    if held(rebuildingSince) then
        dirty = true
        return
    end
    local mine = GetGameTimer()
    rebuildingSince = mine
    CreateThread(function()
        for _ = 1, M.REBUILD_ATTEMPTS do
            dirty = false
            local okRun, applied = pcall(M.rebuild)
            if okRun and applied and not dirty then break end
        end
        -- a stale run that finally resumes must not release a newer rebuild's flag
        if rebuildingSince == mine then rebuildingSince = nil end
    end)
end

--- Make sure the cache has been loaded once (awaits on the first call only).
local function ensureCache()
    if not Cache.ready then M.rebuild() end
    return Cache.ready
end

---------------------------------------------------------------------------------------------------------------
-- Server lookups (§4.3): never wait, full wire Bolo, nil when none is active

--- export checkPlate(plate) -> Bolo|nil. plate is normalised here too (upper case, no whitespace).
function M.checkPlate(plate)
    local entry = Cache.getByPlate(Input.normalizePlate(plate))
    return entry and Visibility.wire(entry, true) or nil
end

--- export checkPerson(citizenid) -> Bolo|nil. Case-insensitive, like the database collation.
function M.checkPerson(citizenid)
    local entry = Cache.getByCitizen(Input.citizenId(citizenid))
    return entry and Visibility.wire(entry, true) or nil
end

--- export hasVisibleBolo(src, kind, id) -> boolean: an active BOLO on the person ('person', citizenid) or vehicle
--- ('vehicle', plate, any spelling) that viewer src may know about (canView full, masked or notice, evaluated on the
--- cached entry, so the BOLO's unit and issuer count). For fredpd_records' search flags instead of rebuilding the
--- VisRecord from checkPlate/checkPerson. Memory only, never waits; needs mdt_page:search or mdt_page:bolos.
function M.hasVisibleBolo(src, kind, id)
    local okRun, visible = pcall(function()
        src = math.tointeger(tonumber(src))
        if not src or src < 1 then return false end
        local entry
        if kind == 'person' then
            entry = Cache.getByCitizen(Input.citizenId(id))
        elseif kind == 'vehicle' then
            entry = Cache.getByPlate(Input.normalizePlate(id))
        end
        if not entry then return false end
        local core = exports.fredpd_core
        if core:hasGrant(src, 'mdt_page', 'search') ~= true and core:hasGrant(src, 'mdt_page', 'bolos') ~= true then
            return false
        end
        local result = Visibility.resultFor(src, entry, true)
        return result == 'full' or result == 'masked' or result == 'notice'
    end)
    if not okRun then
        Fanout.logThrottled('visible', 'error', 'hasVisibleBolo failed: %s', tostring(visible))
        return false
    end
    return visible == true
end

---------------------------------------------------------------------------------------------------------------
-- listBolos

--- export listBolos(src, { active?, page? }) -> BoloListOutput. active = true: the live BOLOs (in memory);
--- active = false: all BOLOs, newest first (SQL, filtered to what the viewer may see).
function M.listBolos(src, input)
    local actor, code, reason = M.actor(src, 'mdt_page', 'bolos')
    if not actor then return fail(code, reason) end
    local q, field = Input.validateList(input)
    if not q then return fail('validation', field) end

    if q.active then
        if not ensureCache() then return fail('unavailable') end
        local bolos = Visibility.shapeMany(actor.src, Cache.all(), liveOf)
        local first = (q.page - 1) * Store.PAGE_SIZE + 1
        return ok({ items = table.move(bolos, first, first + Store.PAGE_SIZE - 1, 1, {}), total = #bolos,
            page = q.page })
    end

    local where, params = Visibility.filterSql(actor.src)
    local okPage, ids, total = pcall(Store.page, where, params, q.page)
    if not okPage then
        Fanout.logThrottled('list', 'error', 'listBolos failed: %s', tostring(ids))
        return fail('unavailable')
    end
    local okLoad, entries = pcall(Store.loadIds, ids)
    if not okLoad then
        Fanout.logThrottled('list', 'error', 'listBolos load failed: %s', tostring(entries))
        return fail('unavailable')
    end
    for _, entry in ipairs(entries) do
        if entry.flagActive and not Cache.isLive(entry) then M.expire(entry) end
    end
    local bolos = Visibility.shapeMany(actor.src, entries, liveOf)
    return ok({ items = bolos, total = total, page = q.page })
end

---------------------------------------------------------------------------------------------------------------
-- createBolo

local pending = {} -- [subject key] = GetGameTimer() while an insert for it is in flight (stale after STALE_FLAG_MS)

--- The actor's primary unit (fredpd_officers.unit, else the first unit grant) and intel tier.
local function actorProfile(src)
    local okCall, officer, units, tier = pcall(function()
        local core = exports.fredpd_core
        return core:getOfficer(src), core:getUnits(src), core:getTier(src)
    end)
    if not okCall then return nil, 0 end
    local unit = type(officer) == 'table' and type(officer.unit) == 'string' and officer.unit or nil
    if not unit and type(units) == 'table' and type(units[1]) == 'string' then unit = units[1] end
    return unit, math.tointeger(tonumber(tier)) or 0
end

--- Registry row for a plate, refreshing fredpd_vehicles_idx from player_vehicles on a miss. Raises on DB errors.
local function registryVehicle(plate)
    local vehicle = Store.vehicle(plate)
    if vehicle then return vehicle end
    local okRefresh, row = pcall(function() return exports.fredpd_core:refreshPlate(plate) end)
    if okRefresh and type(row) == 'table' then return Store.vehicle(plate) end
    return nil
end

--- export createBolo(src, BoloCreateInput) -> Bolo.
function M.createBolo(src, input)
    local actor, code, reason = M.actor(src, 'perm', 'bolo.create')
    if not actor then return fail(code, reason) end
    local q, field = Input.validateCreate(input)
    if not q then return fail('validation', field) end
    local unit, tier = actorProfile(actor.src)
    if q.level > tier then return fail('unauthorized', 'level') end

    local okFind, found = pcall(function()
        if q.kind == 'person' then return Store.person(q.citizenid) end
        return registryVehicle(q.plate)
    end)
    if not okFind then
        Fanout.logThrottled('create', 'error', 'createBolo lookup failed: %s', tostring(found))
        return fail('unavailable')
    end
    if not found then return fail('not_found') end
    -- The register matches case-insensitively (utf8mb4_swedish_ci); store the register's spelling so the
    -- in-memory map, the NOT EXISTS guard and checkPerson all see the same key.
    if q.kind == 'person' then q.citizenid = found.citizenid end

    if not ensureCache() then return fail('unavailable') end
    local key = q.kind == 'person' and ('person:' .. q.citizenid) or ('vehicle:' .. q.plate)
    local existing = q.kind == 'person' and Cache.getByCitizen(q.citizenid) or Cache.getByPlate(q.plate)
    if existing or held(pending[key]) then return fail('validation', 'duplicate') end

    local mine = GetGameTimer()
    pending[key] = mine
    local okInsert, id = pcall(Store.insert, q, { citizenid = actor.citizenid, unit = unit })
    if pending[key] == mine then pending[key] = nil end
    if not okInsert then
        Fanout.logThrottled('create', 'error', 'createBolo insert failed: %s', tostring(id))
        return fail('unavailable')
    end
    if not id then return fail('validation', 'duplicate') end

    local okLoad, entry = pcall(Store.loadOne, id)
    if not okLoad or not entry then
        M.scheduleRebuild()
        return fail('unavailable')
    end
    Cache.put(entry)
    Fanout.audit(actor.src, 'bolo.create', 'bolo', id, {
        kind = q.kind, citizenid = q.citizenid, plate = q.plate, level = q.level, expiresInHours = q.expiresInHours,
    })
    Fanout.changed(Visibility.wire(entry, true), 'created')
    M.scheduleRebuild()
    local result = Visibility.resultFor(actor.src, entry, true)
    return ok(Visibility.shape(entry, result, true) or Visibility.shape(entry, 'notice', true))
end

---------------------------------------------------------------------------------------------------------------
-- resolveBolo / resolveOnImpound

--- Resolve a live entry (awaits). Returns the reloaded entry, or nil and an error code.
function M.resolveEntry(entry, src, citizenid, note, via)
    local okResolve, resolved = pcall(Store.resolve, entry.id, citizenid, note)
    if not okResolve then
        Fanout.logThrottled('resolve', 'error', 'resolving BOLO #%d failed: %s', entry.id, tostring(resolved))
        return nil, 'unavailable'
    end
    if not resolved then
        M.scheduleRebuild() -- resolved or expired elsewhere: the cached entry is stale
        return nil, 'not_found'
    end
    Cache.remove(entry.id)
    Fanout.audit(src, 'bolo.resolve', 'bolo', entry.id, {
        via = via, kind = entry.kind, plate = entry.plate, citizenid = entry.citizenid,
    })
    local okLoad, fresh = pcall(Store.loadOne, entry.id)
    if not okLoad or not fresh then
        fresh = entry
        fresh.flagActive = false
    end
    Fanout.changed(Visibility.wire(fresh, false), 'resolved')
    M.scheduleRebuild()
    return fresh
end

--- export resolveBolo(src, { id, note? }) -> Bolo. The actor must see the BOLO (full or masked): a kontaktnotis
--- gives unauthorized, a hidden or inactive one not_found.
function M.resolveBolo(src, input)
    local actor, code, reason = M.actor(src, 'perm', 'bolo.resolve')
    if not actor then return fail(code, reason) end
    local q, field = Input.validateResolve(input)
    if not q then return fail('validation', field) end

    local entry = Cache.getById(q.id)
    if not entry then
        local okLoad, row = pcall(Store.loadOne, q.id)
        if not okLoad then return fail('unavailable') end
        if not row then return fail('not_found') end
        if not Cache.isLive(row) then
            if row.flagActive then M.expire(row) end
            return fail('not_found')
        end
        entry = row
    end
    local result = Visibility.resultFor(actor.src, entry, true)
    if result == 'notice' then return fail('unauthorized') end
    if result ~= 'full' and result ~= 'masked' then return fail('not_found') end

    local fresh, err = M.resolveEntry(entry, actor.src, actor.citizenid, q.note, 'tablet')
    if not fresh then return fail(err) end
    return ok(Visibility.shape(fresh, result, false))
end

--- export resolveOnImpound(plate, src) -> boolean: resolves the active vehicle BOLO on that plate with the note
--- "Återkallad automatiskt: fordonet bärgades." (audit bolo.resolve, meta.via = 'impound'). src = the impounding
--- officer (resolved_by; 0/nil = system). Called by the qbx_police patch after an impound; never raises.
function M.resolveOnImpound(plate, src)
    local okRun, result = pcall(function()
        local entry = Cache.getByPlate(Input.normalizePlate(plate))
        if not entry then return false end
        local actorSrc = math.tointeger(tonumber(src)) or 0
        local citizenid = nil
        if actorSrc > 0 then
            local okCid, cid = pcall(function() return exports.fredpd_core:getCitizenId(actorSrc) end)
            citizenid = okCid and type(cid) == 'string' and cid ~= '' and cid or nil
        end
        return M.resolveEntry(entry, actorSrc, citizenid, M.L('bolo.resolve.autoImpound'), 'impound') ~= nil
    end)
    if not okRun then
        Fanout.logThrottled('impound', 'error', 'resolveOnImpound failed: %s', tostring(result))
        return false
    end
    return result == true
end

---------------------------------------------------------------------------------------------------------------
-- getBolosFor (records: person / vehicle pages)

--- export getBolosFor(src, kind, id) -> Bolo[] (plain list, never nil): the subject's BOLOs (live first, newest
--- first, at most 20) as viewer src may see them. kind 'person' + citizenid or 'vehicle' + plate. Needs grant
--- mdt_page:search or mdt_page:bolos; anything else (bad input, DB error) gives an empty list.
function M.getBolosFor(src, kind, id)
    src = math.tointeger(tonumber(src))
    if not src or src < 1 then return {} end
    local okGrant, allowed = pcall(function()
        local core = exports.fredpd_core
        return core:hasGrant(src, 'mdt_page', 'search') == true or core:hasGrant(src, 'mdt_page', 'bolos') == true
    end)
    if not okGrant or not allowed then return {} end
    local key
    if kind == 'person' then key = Input.citizenId(id) elseif kind == 'vehicle' then key = Input.normalizePlate(id) end
    if not key then return {} end
    local okLoad, entries = pcall(Store.forSubject, kind, key)
    if not okLoad then
        Fanout.logThrottled('subject', 'error', 'getBolosFor failed: %s', tostring(entries))
        return {}
    end
    for _, entry in ipairs(entries) do
        if entry.flagActive and not Cache.isLive(entry) then M.expire(entry) end
    end
    table.sort(entries, function(a, b)
        local la, lb = Cache.isLive(a), Cache.isLive(b)
        if la ~= lb then return la end
        return a.id > b.id
    end)
    return (Visibility.shapeMany(src, entries, liveOf))
end

---------------------------------------------------------------------------------------------------------------
-- Plate checks

--- Check a normalised plate for `actor` ({ src, citizenid }). opts = { source = 'tablet'|'target', coords? }.
function M.checkVehicle(actor, plate, opts)
    local okFind, vehicle = pcall(registryVehicle, plate)
    if not okFind then
        Fanout.logThrottled('check', 'error', 'plate check lookup failed: %s', tostring(vehicle))
        return fail('unavailable')
    end
    -- Without the active list a check would wrongly answer "no BOLO".
    if not ensureCache() then return fail('unavailable') end
    local entry = Cache.getByPlate(plate)
    local bolo = nil
    if entry then bolo = Visibility.shape(entry, Visibility.resultFor(actor.src, entry, true), true) end

    local okCheck, err = pcall(Store.insertCheck, {
        plate = plate, officer = actor.citizenid, hit = entry ~= nil, boloId = entry and entry.id or nil,
        source = opts.source,
    })
    if not okCheck then Fanout.logThrottled('checkrow', 'error', 'plate check row failed: %s', tostring(err)) end
    Fanout.audit(actor.src, 'bolo.check', 'vehicle', plate, {
        hit = entry ~= nil, boloId = entry and entry.id or nil, via = opts.source,
    })
    if entry then
        TriggerEvent('fredpd:boloHit', Visibility.wire(entry, true), {
            source = 'plate_check', plate = plate, officer = actor.citizenid, coords = Fanout.coords(opts.coords),
        })
    end
    return ok({
        plate = plate,
        model = vehicle and vehicle.model or nil,
        owner = vehicle and vehicle.owner or nil,
        bolo = bolo,
        checkedAt = Time.nowIso(),
    })
end

--- export plateCheck(src, { plate }) -> PlateCheckResult (tablet action checkPlate).
function M.plateCheck(src, input)
    local actor, code, reason = M.actor(src, 'mdt_page', 'search')
    if not actor then return fail(code, reason) end
    local plate, field = Input.validatePlateInput(input)
    if not plate then return fail('validation', field) end
    return M.checkVehicle(actor, plate, { source = 'tablet' })
end

local lastTarget = {} -- [src] = GetGameTimer() of the last accepted ox_target check

--- Forget a player's rate-limit state (playerDropped).
function M.forget(src)
    local n = tonumber(src)
    if n then lastTarget[n] = nil end
end

local function xyz(v)
    if v == nil then return nil end
    local okRead, x, y, z = pcall(function() return v.x, v.y, v.z end)
    if not okRead or type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return nil end
    return x, y, z
end

--- lib.callback 'fredpd:bolo:plateCheck' (ox_target "Kontrollera registreringsskylt"). The client sends only the
--- vehicle's network id; the plate is read from the entity here. Order: grant mdt_page:search -> on duty -> 1/s ->
--- entity -> distance -> plate. Returns PlateCheckResult or { error, reason? }.
function M.targetCheck(source, netId)
    local src = math.tointeger(tonumber(source))
    if not src or src < 1 then return { error = 'unauthorized' } end
    local actor, code, reason = M.actor(src, 'mdt_page', 'search')
    if not actor then return { error = code, reason = reason } end
    local t = GetGameTimer()
    if lastTarget[src] and t - lastTarget[src] < M.TARGET_RATE_MS then return { error = 'rate_limited' } end
    lastTarget[src] = t

    netId = Input.int(netId)
    if not netId or netId < 0 then return { error = 'validation' } end
    local entity = NetworkGetEntityFromNetworkId(netId)
    if not entity or entity == 0 or not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then
        return { error = 'not_found' }
    end
    local px, py, pz = xyz(GetEntityCoords(GetPlayerPed(src)))
    local vx, vy, vz = xyz(GetEntityCoords(entity))
    if not px or not vx then return { error = 'not_found' } end
    local dx, dy, dz = px - vx, py - vy, pz - vz
    if dx * dx + dy * dy + dz * dz > M.TARGET_DISTANCE * M.TARGET_DISTANCE then
        return { error = 'validation', reason = 'too_far' }
    end
    local plate = Input.normalizePlate(GetVehicleNumberPlateText(entity))
    if not plate then return { error = 'not_found', reason = 'no_plate' } end

    local res = M.checkVehicle(actor, plate, { source = 'target', coords = { x = vx, y = vy, z = vz } })
    if res.ok then return res.data end
    return { error = res.error, reason = res.reason }
end

---------------------------------------------------------------------------------------------------------------
-- Hits (server event fredpd:boloHit from this resource, the qbx_police radar bridge, later the garage bridge)

--- fredpd:boloHit(bolo, ctx) handler body: the BOLO must be one of ours and still live (looked up by id; the payload
--- is not trusted). Radar hits also get a fredpd_plate_checks row (no officer). Then the alert, per-plate cooldown,
--- with the text the least-privileged on-duty officer may see; none at all when canView hides the BOLO from them.
function M.onHit(bolo, ctx)
    if type(bolo) ~= 'table' then return end
    local entry = Cache.getById(Input.int(bolo.id))
    if not entry then return end
    ctx = type(ctx) == 'table' and ctx or {}
    local source = type(ctx.source) == 'string' and ctx.source:sub(1, 32) or 'unknown'
    if source == 'radar' and entry.plate then
        local okCheck, err = pcall(Store.insertCheck, {
            plate = entry.plate, hit = true, boloId = entry.id, source = 'radar',
        })
        if not okCheck then Fanout.logThrottled('checkrow', 'error', 'radar check row failed: %s', tostring(err)) end
    end
    Fanout.hitAlert(entry, { source = source, coords = ctx.coords, street = ctx.street, radar = Input.int(ctx.radar) },
        Visibility.publicReason(entry))
end

return M
