-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_forensics server logic (IMPLEMENTATION.md §5.7, docs/contracts.md §C16, docs/modules/forensics.md).
--
--   collect   ox_inventory createItem hook on the evidences items: a new item without a uid gets `item_uid`
--             (+ collected_by/collected_at) in its metadata; registerDelayMs later (evidences has written its own
--             metadata by then) the fredpd_evidence row is created with the 'collect' entry, the item name and the
--             evidence identity, but only if the item really is where it was created.
--   give      an item that already has a uid (ox_inventory's give = AddItem on the recipient with the item's own
--             metadata, then RemoveItem on the giver) keeps it; once it is really there, a hand-over to a person is
--             a 'transfer' (actor = the recipient), an arrival in a locker a 'handin' / 'return'.
--   hand-in   ox_inventory swapItems hook filtered to the evidence lockers: the hook itself only returns true; the
--             work runs in ox_inventory's post-hook event (fired ~50 ms after a move that really happened) and
--             appends handin / checkout / return / transfer.
--   analyse   evidences:evidenceItemAnalysed(playerId, item, inventory): only when `inventory` is the analyst's own
--             or a container in it; store the whitelisted result, append 'analyse', offer "Koppla till ärende" to the
--             analyst (client dialog → callback fredpd:forensics:link).
--   link      tag = formatId(evidenceTag, { case, n }) in one transaction with the case row locked; audited
--             evidence.link, server event fredpd:evidenceLinked(caseId, evidenceId), tablet push topic 'case'.
--
-- Uid registry (docs/deps-verification.md Decision 5.2): every event for a uid is checked against the row's type,
-- item name and evidence identity first seen for it; a mismatch changes nothing and is audited evidence.mismatch.
-- A well-formed uid without a row is only trusted when this server minted it (in-memory `minted`); any other one
-- came from client-writable metadata (evidences:syncEvidence → atItem) and is re-stamped like a legacy item, with
-- no collector (audited evidence.mismatch, why = 'unknown_uid'). Item metadata collected_by/collected_at are never
-- read back.
--
-- Tablet exports (§C12 convention: { ok = true, data } | { ok = false, error, reason? }): listEvidence, getEvidence,
-- linkEvidence; listCaseEvidence for fredpd_records' case page. Output = EvidenceItemSchema
-- (packages/types/src/evidence.ts), shaped by canView with record type 'evidence'; a person match in `result` only
-- reaches a viewer whose view of the linked case is 'full' (unlinked: lab unit, evidence.link or records.admin).

local Evidence = require 'shared.evidence'
local Store = require 'server.store'

local M = {}

M.LINK_PERM = 'evidence.link'
M.PAGE_GRANT = { 'mdt_page', 'evidence' }
M.LINK_GRANT = { 'perm', M.LINK_PERM }
M.ADMIN_GRANT = { 'perm', 'records.admin' }
M.ISO = '^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$'

-- Set by M.configure (server/main.lua) from config.lua; defaults keep the module usable in tests.
M.cfg = {
    items = Evidence.DEFAULT_ITEMS,
    containerItems = { evidence_box = true },
    lockerPatterns = { '^evidence_', '^evidence%-%d+$' },
    lockerGrant = { 'mdt_page', 'evidence' },
    labs = {},
    labUnit = 'tekniker',
    linkCooldownMs = 2000,
    registerDelayMs = 250,
    mintedCap = 2000,             -- minted uids kept in memory before expired ones are pruned (on the next mint)
    mintedTtlMs = 6 * 3600 * 1000, -- how long a minted uid without a row stays trusted
    -- The inventory fredpd_core's bridge selected (bridgeInfo().inventory), set by server/main.lua when evidence is
    -- on. ox_inventory's hooks, slots and metadata have no bridge equivalent (§C17: hooks are ox-only), so this module
    -- reaches ox_inventory itself, but only through M.inventory(), which refuses unless it is the selected one.
    inventory = nil,
}
-- { tag = function(caseNumber, n) -> string, isCaseNumber = function(v) -> boolean } (shared/format.lua); nil when
-- fredpd_core's formats.json is missing or rejected, which disables linking ('unavailable').
M.format = nil

local counter = 0
local lastLink = {} -- [src] = GetGameTimer() of the last link attempt (dialog callback)
local arrivals = {} -- [uid .. '@' .. holder] = true while an arrival check is scheduled (one per AddItem burst)
-- Uids this server minted whose row may not exist yet: [uid] = { cid, at, via, t }. The only source of a collector
-- for a row created after the fact (registration missed the item, or its insert failed); dropped once the row exists.
local minted, mintedCount = {}, 0

function M.configure(cfg, format)
    for k, v in pairs(cfg or {}) do M.cfg[k] = v end
    if format then M.format = format end
end

---------------------------------------------------------------------------------------------------------------
-- Small helpers

local function ok(data) return { ok = true, data = data } end
local function fail(code, reason) return { ok = false, error = code, reason = reason } end

function M.log(level, fmt, ...)
    local msg = select('#', ...) > 0 and fmt:format(...) or tostring(fmt)
    local printer = type(lib) == 'table' and type(lib.print) == 'table' and lib.print[level]
    if printer then printer(msg) else print(('[fredpd_forensics] %s: %s'):format(level, msg)) end
end

local function core() return exports.fredpd_core end

--- exports.ox_inventory when fredpd_core's bridge selected ox_inventory; raises otherwise (every caller is in a
--- pcall, so on any other inventory the call is a logged no-op, never a call into a resource that is not selected).
function M.inventory()
    if M.cfg.inventory ~= 'ox_inventory' then
        error(('ox_inventory is not the selected inventory (%s)'):format(tostring(M.cfg.inventory)), 0)
    end
    return exports.ox_inventory
end
local oxInventory = M.inventory

local function citizenOf(src)
    if not src or src < 1 then return nil end
    local okCall, cid = pcall(function() return core():getCitizenId(src) end)
    return okCall and Evidence.citizenid(cid) or nil
end

local function hasGrant(src, grant)
    local okCall, allowed = pcall(function() return core():hasGrant(src, grant[1], grant[2]) end)
    return okCall and allowed == true
end

local function audit(src, action, id, meta)
    local okCall, err = pcall(function() core():audit(src or 0, action, 'evidence', id, meta) end)
    if not okCall then M.log('error', 'audit %s failed: %s', action, tostring(err)) end
end

--- Run a DB step; a failure is logged and becomes false (never an error thrown into an event or a caller).
local function db(label, fn, ...)
    local okCall, a, b = pcall(fn, ...)
    if not okCall then
        M.log('error', '%s failed: %s', label, tostring(a))
        return false
    end
    return true, a, b
end

function M.newUid()
    counter = (counter + 1) & 0xFFFF
    return Evidence.newUid(os.time(), counter, math.random(0, 0xFFFF))
end

--- Lab id when the player stands in a configured lab box (server-side ped position, OneSync), else nil.
local function labOf(src)
    if not src or src < 1 or #(M.cfg.labs or {}) == 0 then return nil end
    local okCall, pos = pcall(function() return GetEntityCoords(GetPlayerPed(src)) end)
    if not okCall or not pos then return nil end
    return Evidence.labAt(pos, M.cfg.labs)
end

local function crimeSceneOf(metadata)
    local information = type(metadata) == 'table' and type(metadata.information) == 'table' and metadata.information
    return information and Evidence.cleanString(information.crimeScene, 100) or nil
end

---------------------------------------------------------------------------------------------------------------
-- The acting officer for the tablet exports: a connected player with the grant (nil = no grant needed, e.g. the
-- case page, where canView of the case decides), on duty, with a character.

function M.actor(src, grant)
    src = tonumber(src)
    if not src or src < 1 or not math.tointeger(src) then return nil, 'unauthorized' end
    src = math.tointeger(src)
    if grant and not hasGrant(src, grant) then return nil, 'unauthorized' end
    local okDuty, onDuty = pcall(function() return core():isOnDuty(src) end)
    if not okDuty or onDuty ~= true then return nil, 'unauthorized', 'off_duty' end
    local cid = citizenOf(src)
    if not cid then return nil, 'unauthorized' end
    return { src = src, citizenid = cid }
end

---------------------------------------------------------------------------------------------------------------
-- Rows by item uid (collect / arrival / first sighting) and the uid registry

--- Log + audit an item that does not fit the evidence stored for its uid (forged or copied uid, tampered evidence;
--- docs/deps-verification.md §3, Decision 5.2): nothing is written to the row. Returns false, 'mismatch'.
local function mismatch(src, row, item, why)
    M.log('warn', 'evidence #%s: item %s does not match the stored evidence (%s); ignored', tostring(row.id),
        tostring(item and item.name), why)
    audit(src, 'evidence.mismatch', row.id, { item = item and item.name, why = why })
    return false, 'mismatch'
end

--- Uid registry check (Decision 5.2): the item must have the row's type, and the item name and evidence identity
--- first seen for its uid. A row without name / identity yet (created before migration 011, or before evidences
--- wrote the evidence into the item) gets them now; the re-read catches a concurrent first sighting. Returns true,
--- or false and 'mismatch' (audited) / false (DB error).
local function fits(src, row, item, info, md)
    if row.type ~= info.type then return mismatch(src, row, item, 'type') end
    local ident = Evidence.identity(info, md)
    if (row.itemName == nil and item.name ~= nil) or (row.ident == nil and ident ~= nil) then
        if not db('evidence identity', Store.recordIdentity, row.id, item.name, ident) then return false end
        local okLoad, again = db('evidence byId', Store.byId, row.id)
        if not okLoad or not again then return false end
        row.itemName, row.ident = again.itemName, again.ident
    end
    if row.itemName ~= nil and row.itemName ~= item.name then return mismatch(src, row, item, 'item') end
    if row.ident ~= nil and row.ident ~= ident then return mismatch(src, row, item, 'evidence') end
    return true
end

--- The evidence item with `uid` in inventory `holder`, or nil.
local function findItem(holder, name, uid)
    if holder == nil then return nil end
    local okFind, slots = pcall(function()
        return oxInventory():GetSlotsWithItem(holder, name, { item_uid = uid })
    end)
    if okFind and type(slots) == 'table' and type(slots[1]) == 'table' then return slots[1] end
    return nil
end

--- Remember a uid this server minted (collect, or a re-stamp) until its row exists. Expired entries (uids that never
--- landed: a failed AddItem, the first of AddItem's two Items.Metadata calls) are pruned on a later mint.
local function remember(uid, cid, at, via)
    if mintedCount >= (M.cfg.mintedCap or 2000) then
        local now, ttl = GetGameTimer(), M.cfg.mintedTtlMs or 21600000
        for k, m in pairs(minted) do
            if now - m.t > ttl then
                minted[k] = nil
                mintedCount = mintedCount - 1
            end
        end
    end
    if not minted[uid] then mintedCount = mintedCount + 1 end
    minted[uid] = { cid = cid, at = at, via = via, t = GetGameTimer() }
end

local function forgetMinted(uid)
    if minted[uid] then
        minted[uid] = nil
        mintedCount = mintedCount - 1
    end
end

--- Whether this server minted `uid` and has no row for it yet (tests, logs).
function M.isMinted(uid) return minted[uid] ~= nil end

--- Stamp a fresh uid on the item in `holder` / `holderSlot`: an item without one (collected before fredpd_forensics
--- ran), or one carrying `oldUid`, a uid this server never minted. Client-writable collected_by / collected_at are
--- dropped; the collect time is evidences' createdAt (client-asserted). Returns uid, metadata, or nil (unknown place,
--- the slot holds something else, SetMetadata failed). When the slot already carries another uid (a concurrent
--- sighting stamped it, or `item` is a stale copy) that uid is returned; the caller only uses it when it has a row
--- or this server minted it.
local function restamp(item, info, holder, holderSlot, oldUid)
    if holder == nil or math.type(holderSlot) ~= 'integer' then
        M.log('warn', 'evidence item %s without a known item_uid in an unknown place; not tracked', tostring(item.name))
        return nil
    end
    local okSlot, slot = pcall(function() return oxInventory():GetSlot(holder, holderSlot) end)
    if not okSlot or type(slot) ~= 'table' or slot.name ~= item.name then return nil end
    local current = type(slot.metadata) == 'table' and slot.metadata or {}
    local present = Evidence.isUid(current.item_uid) and current.item_uid or nil
    if present and present ~= oldUid then return present, current end
    local ev = type(current[info.key]) == 'table' and current[info.key] or {}
    local uid = M.newUid()
    current.item_uid, current.collected_by, current.collected_at = uid, nil, nil
    local okSet, err = pcall(function() oxInventory():SetMetadata(holder, holderSlot, current) end)
    if not okSet then
        M.log('error', 'could not stamp item_uid on %s: %s', tostring(item.name), tostring(err))
        return nil
    end
    remember(uid, nil, Evidence.isoFromEpoch(ev.createdAt), oldUid and 'unknown_uid' or 'first_seen')
    return uid, current
end

--- The fredpd_evidence row for an evidence item seen somewhere (hand-in, analysis, arrival). A uid this server minted
--- without a row yet (registration missed the item, or its insert failed) gets its row now, collector and time from
--- the mint. An item without a uid (collected before fredpd_forensics ran) or with a uid this server never minted
--- (forged through client metadata, or minted before a restart and never registered) gets a fresh uid where it lies
--- (`holder` + `holderSlot` needed) and a row whose 'collect' entry has no actor. Returns the row, or nil and
--- 'mismatch' (the item does not fit its uid, or an unknown uid that could not be re-stamped; audited) / nil
--- (unknown holder, DB error).
function M.ensureRow(item, info, holder, holderSlot, src)
    local md = type(item.metadata) == 'table' and item.metadata or {}
    local uid = Evidence.isUid(md.item_uid) and md.item_uid or nil
    local unknown -- a well-formed uid with no row that this server did not mint
    local okLoad, row
    if uid then
        okLoad, row = db('evidence byUid', Store.byUid, uid)
        if not okLoad then return nil end
        if not row and not minted[uid] then unknown = uid end
    end
    if not uid or unknown then
        local fresh
        fresh, md = restamp(item, info, holder, holderSlot, uid)
        if not fresh then
            if not unknown then return nil end
            M.log('warn', 'evidence item %s carries unknown item_uid %s and could not be re-stamped; ignored',
                tostring(item.name), unknown)
            audit(src, 'evidence.mismatch', nil, { item = item.name, why = 'unknown_uid', uid = unknown })
            return nil, 'mismatch'
        end
        uid = fresh
        okLoad, row = db('evidence byUid', Store.byUid, uid)
        if not okLoad then return nil end
    end
    if not row then
        local m = minted[uid]
        if not m then return nil end
        local okIns, created = db('evidence insert', Store.insert, {
            uid = uid, type = info.type, itemName = item.name, ident = Evidence.identity(info, md),
            collectedBy = m.cid, collectedAt = m.at, location = crimeSceneOf(md),
        })
        if not okIns then return nil end
        okLoad, row = db('evidence byUid', Store.byUid, uid)
        if not okLoad or not row then return nil end
        forgetMinted(uid)
        if created then
            audit(0, 'evidence.collect', row.id, { uid = uid, item = item.name, collectedBy = row.collectedBy,
                via = m.via })
            if unknown then
                M.log('warn', 'evidence #%s: item %s carried unknown item_uid %s; re-stamped as %s', tostring(row.id),
                    tostring(item.name), unknown, uid)
                audit(src, 'evidence.mismatch', row.id, { item = item.name, why = 'unknown_uid', uid = unknown })
            end
        end
    end
    local fit, why = fits(src, row, item, info, md)
    if not fit then return nil, why end
    return row
end

---------------------------------------------------------------------------------------------------------------
-- Collect and arrival: createItem hook (synchronous, must stay cheap) + delayed registration

--- ox_inventory createItem hook body (no SQL here). A new evidence item gets a fresh item_uid (+ collected_by,
--- collected_at) and its row follows registerDelayMs later (M.register). An item created with a uid already in its
--- metadata is an existing evidence item on the move: ox_inventory's give runs AddItem on the recipient with the
--- item's own metadata, then RemoveItem on the giver (modules/inventory/server.lua:2529-2553, the createItem hook
--- runs inside AddItem's Items.Metadata, :1147-1174 and modules/items/server.lua:224-234). It keeps its uid and
--- the arrival is checked registerDelayMs later (M.arrive). Returns the new metadata, or nil (metadata unchanged:
--- not evidence, or a kept uid).
function M.mint(payload)
    if type(payload) ~= 'table' or type(payload.item) ~= 'table' then return nil end
    local name = payload.item.name
    local info = Evidence.itemInfo(name, M.cfg.items)
    if not info then return nil end
    local md = type(payload.metadata) == 'table' and payload.metadata or {}
    local holder = payload.inventoryId
    local src = type(holder) == 'number' and math.tointeger(holder) or nil -- player inventories are server ids
    if Evidence.isUid(md.item_uid) then
        M.scheduleArrival(md.item_uid, name, holder, src)
        return nil
    end
    local uid = M.newUid()
    local cid = citizenOf(src)
    md.item_uid = uid
    md.collected_by = cid -- informational only: never read back (client metadata can overwrite it)
    md.collected_at = os.date('!%Y-%m-%dT%H:%M:%SZ')
    remember(uid, cid, md.collected_at, 'late')
    SetTimeout(M.cfg.registerDelayMs or 250, function()
        local okRun, err = pcall(M.register, uid, name, holder, src, cid)
        if not okRun then M.log('error', 'evidence register failed: %s', tostring(err)) end
    end)
    return md
end

--- Create the row for a freshly minted uid once the item is where it was created (evidences' collect: AddItem,
--- then atItem in the same tick, so the crime scene and the evidence identity are known by now). The row records
--- the item name and that identity (Decision 5.2). No item with the uid there = no row: the AddItem failed, ran
--- Items.Metadata twice (the first uid never lands), the uid was overwritten before registration, or the item moved
--- on within registerDelayMs; the uid stays in `minted`, so a later sighting still creates the row with this
--- collector.
function M.register(uid, name, holder, src, cid)
    local info = Evidence.itemInfo(name, M.cfg.items)
    if not info then return false end
    local item = findItem(holder, name, uid)
    if not item then
        M.log('info', 'evidence item %s (%s) is not in inventory %s; not registered', tostring(name), uid,
            tostring(holder))
        return false
    end
    local md = type(item.metadata) == 'table' and item.metadata or {}
    local okIns, created = db('evidence insert', Store.insert, {
        uid = uid, type = info.type, itemName = name, ident = Evidence.identity(info, md), collectedBy = cid,
        location = crimeSceneOf(md),
    })
    if not okIns then return false end
    forgetMinted(uid)
    if created then
        local _, row = db('evidence byUid', Store.byUid, uid)
        audit(src, 'evidence.collect', row and row.id, { uid = uid, item = name })
    end
    return created
end

--- Check the arrival of an item that kept its uid, registerDelayMs from now, once per uid and inventory however
--- often AddItem ran Items.Metadata for it.
function M.scheduleArrival(uid, name, holder, src)
    if holder == nil then return end
    local key = uid .. '@' .. tostring(holder)
    if arrivals[key] then return end
    arrivals[key] = true
    SetTimeout(M.cfg.registerDelayMs or 250, function()
        arrivals[key] = nil
        local okRun, err = pcall(M.arrive, uid, name, holder, src)
        if not okRun then M.log('error', 'evidence arrival failed: %s', tostring(err)) end
    end)
end

--- An existing evidence item arrived in `holder` through AddItem (a give, or another resource moving it). Nothing
--- happens when it is not there (the AddItem failed, or ox_inventory undid the give) or when the chain already has
--- it there. A person receiving it = 'transfer' (actor = the recipient, no location); a locker = 'handin' ('return'
--- after a checkout, 'transfer' from another locker); any other inventory = 'transfer' with that inventory as
--- location. Returns the action or nil.
function M.arrive(uid, name, holder, src)
    local info = Evidence.itemInfo(name, M.cfg.items)
    if not info then return nil end
    local item = findItem(holder, name, uid)
    if not item then return nil end
    local row = M.ensureRow(item, info, holder, math.tointeger(item.slot), src)
    if not row then return nil end
    local cid = citizenOf(src)
    local patterns = M.cfg.lockerPatterns
    local now = Evidence.currentHolder(row.chain) or {}
    local action, location
    if src == nil then
        location = tostring(holder)
        if now.location == location then return nil end
        if not Evidence.isLocker(holder, patterns) then
            action = 'transfer'
        elseif now.location and Evidence.isLocker(now.location, patterns) then
            action = 'transfer'
        else
            action = Evidence.lastLockerAction(row.chain, patterns) == 'checkout' and 'return' or 'handin'
        end
    else
        if cid ~= nil and now.actor == cid then return nil end
        action = 'transfer'
    end
    if not db('evidence append', Store.append, row.id, { actor = cid, action = action, location = location }) then
        return nil
    end
    audit(src, 'evidence.' .. action, row.id, { to = tostring(holder), via = 'additem' })
    return action
end

---------------------------------------------------------------------------------------------------------------
-- Hand-in / checkout / return / transfer: swapItems post-hook event

--- The item moves one swapItems payload describes: the dragged item from -> to, and on a swap also the item that
--- was in the target slot, to -> from. `destSlot` = where the item is now.
function M.movesOf(payload)
    local moves = {}
    local from, to = payload.fromInventory, payload.toInventory
    if from == nil or to == nil or tostring(from) == tostring(to) then return moves end
    local fromSlot, toSlot = payload.fromSlot, payload.toSlot
    if type(fromSlot) == 'table' then
        local dest = type(toSlot) == 'table' and toSlot.slot or toSlot
        moves[#moves + 1] = { item = fromSlot, from = from, to = to, destSlot = math.tointeger(tonumber(dest)) }
    end
    if payload.action == 'swap' and type(toSlot) == 'table' and type(fromSlot) == 'table' then
        moves[#moves + 1] = { item = toSlot, from = to, to = from, destSlot = math.tointeger(tonumber(fromSlot.slot)) }
    end
    return moves
end

--- Append the custody entry for one evidence item moved between inventories. Returns the action or nil.
local function recordItemMove(src, cid, item, from, to, holder, holderSlot, note)
    local info = Evidence.itemInfo(item.name, M.cfg.items)
    if not info or not Evidence.moveAction(from, to, M.cfg.lockerPatterns, nil) then return nil end
    local row = M.ensureRow(item, info, holder, holderSlot, src)
    if not row then return nil end
    local action, location = Evidence.moveAction(from, to, M.cfg.lockerPatterns,
        Evidence.lastLockerAction(row.chain, M.cfg.lockerPatterns))
    if not db('evidence append', Store.append, row.id, { actor = cid, action = action, location = location,
        note = note }) then
        return nil
    end
    audit(src, 'evidence.' .. action, row.id, { location = location, from = tostring(from), to = tostring(to) })
    return action
end

--- A container item (evidence_box) handed in or out: every evidence item inside gets the entry, noted with the
--- box label. ox_inventory loads the container on GetContainerFromSlot.
local function recordContainerMove(src, cid, mv)
    local md = type(mv.item.metadata) == 'table' and mv.item.metadata or {}
    local container = md.container
    if type(container) ~= 'string' or not mv.destSlot then return 0 end
    if not Evidence.moveAction(mv.from, mv.to, M.cfg.lockerPatterns, nil) then return 0 end
    local okItems, items = pcall(function()
        oxInventory():GetContainerFromSlot(mv.to, mv.destSlot)
        return oxInventory():GetInventoryItems(container)
    end)
    if not okItems or type(items) ~= 'table' then return 0 end
    local note = Evidence.cleanString(md.label, 64)
    local n = 0
    for _, it in pairs(items) do
        if type(it) == 'table' and recordItemMove(src, cid, it, mv.from, mv.to, container, math.tointeger(it.slot),
            note) then
            n = n + 1
        end
    end
    return n
end

--- Post-hook event of the swapItems hook: (success, payload). Nothing happens for a move that did not complete.
function M.onSwap(success, payload)
    if success ~= true or type(payload) ~= 'table' then return 0 end
    local src = math.tointeger(tonumber(payload.source))
    local cid = citizenOf(src)
    local n = 0
    for _, mv in ipairs(M.movesOf(payload)) do
        if type(mv.item) == 'table' then
            if M.cfg.containerItems[mv.item.name] then
                n = n + recordContainerMove(src, cid, mv)
            elseif recordItemMove(src, cid, mv.item, mv.from, mv.to, mv.to, mv.destSlot, nil) then
                n = n + 1
            end
        end
    end
    return n
end

---------------------------------------------------------------------------------------------------------------
-- Analyse: evidences:evidenceItemAnalysed(playerId, item, inventory)

--- Person (or registered firearm owner) the evidences registers give for the evidence, or nil.
function M.matchFor(info, metadata)
    local ev = Evidence.evidenceOf(info, metadata)
    local citizenid
    if info.key == 'fingerprint' or info.key == 'dna' then
        citizenid = ev.identifier and Store.registerMatch(info.key, ev.identifier)
    else
        citizenid = ev.serial and Store.registerMatch('serial', ev.serial)
    end
    citizenid = Evidence.citizenid(citizenid)
    if not citizenid then return nil end
    local okName, name = db('person name', Store.personName, citizenid)
    return { citizenid = citizenid, name = okName and name or citizenid }
end

--- Whether evidences' setAnalysed target `inventory` is the analyst's own inventory or a container inside it: the
--- only inventories evidences' laptop lists (getItemsMatchingFilter, server/dui/callbacks.lua:25-81). Its getItem
--- (:150-159) accepts any stash id, so a modified client can analyse an item in a locker from anywhere.
function M.heldBy(src, inventory)
    if type(inventory) == 'number' then return math.tointeger(inventory) == src end
    if type(inventory) ~= 'string' then return false end
    local okItems, items = pcall(function() return oxInventory():GetInventoryItems(src) end)
    if not okItems or type(items) ~= 'table' then return false end
    for _, it in pairs(items) do
        if type(it) == 'table' and type(it.metadata) == 'table' and it.metadata.container == inventory then
            return true
        end
    end
    return false
end

--- Crime scene of the 'collect' entry (recorded at registration from the collector's metadata): the result keeps
--- it rather than the analysis-time metadata, which setAnalysed's `information` (client data) can overwrite.
local function registeredCrimeScene(row)
    local first = type(row.chain) == 'table' and row.chain[1]
    if type(first) == 'table' and first.action == 'collect' and type(first.location) == 'string' then
        return first.location
    end
    return nil
end

--- Returns 'analysed' | 'repeat' | 'mismatch' | nil (ignored) — the value is for tests and logs. `inventory` (added
--- by evidences.20) must be the analyst's inventory or a container in it; without it (unpatched evidences) the
--- holder cannot be checked.
function M.onAnalysed(playerId, item, inventory)
    local src = math.tointeger(tonumber(playerId))
    if not src or src < 1 or type(item) ~= 'table' then return nil end
    local info = Evidence.itemInfo(item.name, M.cfg.items)
    if not info then return nil end
    local md = type(item.metadata) == 'table' and item.metadata or {}
    if not Evidence.evidenceOf(info, md).analysed then return nil end
    if inventory ~= nil and not M.heldBy(src, inventory) then
        local known
        if Evidence.isUid(md.item_uid) then
            local okLoad, found = db('evidence byUid', Store.byUid, md.item_uid)
            known = okLoad and found or nil
        end
        M.log('warn', 'player %d analysed %s in inventory %s, which they do not hold; ignored', src,
            tostring(item.name), tostring(inventory))
        audit(src, 'evidence.mismatch', known and known.id, { item = item.name, why = 'not_holder',
            inventory = tostring(inventory) })
        return 'mismatch'
    end
    local row, why = M.ensureRow(item, info, inventory, math.tointeger(item.slot), src)
    if not row then return why end
    if row.result then
        if not Evidence.sameEvidence(info, row.result, md) then
            mismatch(src, row, item, 'evidence')
            return 'mismatch'
        end
        return 'repeat' -- evidences re-fires on every ballistics view; the first analysis is the one recorded
    end

    local okMatch, match = pcall(M.matchFor, info, md)
    if not okMatch then match = nil end
    local result = Evidence.buildResult(info, md, match)
    result.crimeScene = registeredCrimeScene(row)
    local cid = citizenOf(src)
    local location = labOf(src)
    local okSet, analysed = db('evidence analyse', Store.setAnalysed, row.id, result,
        { actor = cid, action = 'analyse', location = location })
    if not okSet or not analysed then return 'repeat' end
    audit(src, 'evidence.analyse', row.id, { type = row.type, location = location, match = match ~= nil })

    if not row.caseId and M.format and hasGrant(src, M.LINK_GRANT) then
        local okDuty, onDuty = pcall(function() return core():isOnDuty(src) end)
        if okDuty and onDuty == true then
            TriggerClientEvent('fredpd:forensics:client:offerLink', src, { id = row.id, type = row.type,
                example = M.format.example })
        end
    end
    return 'analysed'
end

---------------------------------------------------------------------------------------------------------------
-- Visibility and output shape

--- Citizenids that handled unlinked evidence (collector and analysts): canView `assigned` for them.
local function handlersOf(row)
    local out, seen = {}, {}
    local function add(cid)
        if type(cid) == 'string' and not seen[cid] then
            seen[cid] = true
            out[#out + 1] = cid
        end
    end
    add(row.collectedBy)
    for _, e in ipairs(row.chain or {}) do
        if type(e) == 'table' and (e.action == 'collect' or e.action == 'analyse') then add(e.actor) end
    end
    return out
end

--- Level of an evidence row as shown and checked: linked evidence is at least at its case's current level (the link
--- stores GREATEST(level, case level) once, but a case can be raised later, §C14).
function M.levelOf(row)
    if row.caseId then return math.max(row.level or 0, row.caseLevel or 0) end
    return row.level or 0
end

local VIEW_RANK = { none = 0, notice = 1, masked = 2, full = 3 }

--- VisRecords (§C3) for one evidence row: the evidence itself and, when linked, its case. Linked evidence takes the
--- case's status, unit, assignees and owner, and the higher of its own and the case's level; unlinked evidence
--- belongs to the lab unit (config labUnit) and its handlers.
function M.records(row, assignees)
    if row.caseId then
        local a = assignees[row.caseId] or {}
        local base = { status = row.caseStatus == 'closed' and 'closed' or 'open', unit = row.caseUnit,
            assignees = a, ownerCitizenid = row.caseOwner }
        local ev = { type = 'evidence', id = row.id, level = M.levelOf(row) }
        local cs = { type = 'case', id = row.caseId, level = row.caseLevel or 0 }
        for k, v in pairs(base) do ev[k], cs[k] = v, v end
        return ev, cs
    end
    return { type = 'evidence', id = row.id, level = row.level, status = 'open', unit = M.cfg.labUnit,
        assignees = handlersOf(row) }, nil
end

--- Whether `src` is a member of the lab unit (config labUnit) according to fredpd_core's getUnits.
local function inLabUnit(src)
    local okUnits, units = pcall(function() return core():getUnits(src) end)
    if not okUnits or type(units) ~= 'table' then return false end
    for _, u in pairs(units) do
        if u == M.cfg.labUnit then return true end
    end
    return false
end

--- Per row: { view = evidence view, showMatch = boolean } for `actor`, with one canViewMany call. Linked evidence is
--- never more visible than its case (view capped at the case view). The person match of linked evidence needs a
--- full view of the evidence and of its case; of unlinked evidence a full view plus one of: the lab unit, perm
--- evidence.link (up to the holder's tier), perm records.admin. A collector or analyst who sees their unlinked
--- evidence through `assigned` gets it without the match.
function M.views(actor, rows)
    local caseIds = {}
    for _, row in ipairs(rows) do
        if row.caseId then caseIds[#caseIds + 1] = row.caseId end
    end
    local assignees = #caseIds > 0 and Store.assignees(caseIds) or {}
    local records, index = {}, {}
    for i, row in ipairs(rows) do
        local ev, cs = M.records(row, assignees)
        records[#records + 1] = ev
        index[i] = { ev = #records }
        if cs then
            records[#records + 1] = cs
            index[i].cs = #records
        end
    end
    local results = #records > 0 and core():canViewMany(actor.src, records) or {}
    local linkPerm = hasGrant(actor.src, M.LINK_GRANT)
    local tier = 0
    if linkPerm then
        local okTier, t = pcall(function() return core():getTier(actor.src) end)
        tier = okTier and tonumber(t) or 0
    end
    local labMember, admin -- looked up once, only when an unlinked row needs them
    local out = {}
    for i, row in ipairs(rows) do
        local view = results[index[i].ev] or 'none'
        local showMatch
        if row.caseId then
            local caseView = results[index[i].cs] or 'none'
            if (VIEW_RANK[caseView] or 0) < (VIEW_RANK[view] or 0) then view = caseView end
            showMatch = view == 'full' and caseView == 'full'
        else
            -- perm evidence.link works the unlinked queue: full view of unlinked evidence up to the holder's tier.
            local linkOk = linkPerm and row.level <= tier
            if view ~= 'full' and linkOk then view = 'full' end
            if view == 'full' and not linkOk then
                if labMember == nil then
                    labMember = inLabUnit(actor.src)
                    admin = hasGrant(actor.src, M.ADMIN_GRANT)
                end
                showMatch = labMember or admin
            else
                showMatch = view == 'full'
            end
        end
        out[i] = { view = view, showMatch = showMatch == true }
    end
    return out
end

--- OfficerRef (mdt.ts): Discord display name + callsign from fredpd_officers (§4.9); an officer without a row is
--- shown by citizenid (never a character name).
local function officerRef(cid, officers)
    if type(cid) ~= 'string' then return nil end
    local o = officers[cid]
    return {
        citizenid = cid,
        displayName = (o and o.displayName) or (o and o.callsign) or cid,
        callsign = o and o.callsign or nil,
        unit = o and o.unit or nil,
    }
end

--- EvidenceItemSchema for rows the viewer may see ('full' or 'masked'); others are left out.
function M.shape(rows, views)
    local cids, seen = {}, {}
    local function want(cid)
        if type(cid) == 'string' and not seen[cid] then
            seen[cid] = true
            cids[#cids + 1] = cid
        end
    end
    for i, row in ipairs(rows) do
        if views[i].view == 'full' or views[i].view == 'masked' then
            want(row.collectedBy)
            for _, e in ipairs(row.chain) do
                if type(e) == 'table' then want(e.actor) end
            end
        end
    end
    local officers = #cids > 0 and Store.officers(cids) or {}
    local items = {}
    for i, row in ipairs(rows) do
        local v = views[i]
        if (v.view == 'full' or v.view == 'masked') and Evidence.TYPES[row.type] then
            local chain = {}
            for _, e in ipairs(row.chain) do
                if type(e) == 'table' and Evidence.ACTIONS[e.action] and type(e.at) == 'string'
                    and e.at:match(M.ISO) then
                    chain[#chain + 1] = {
                        at = e.at,
                        actor = officerRef(e.actor, officers),
                        action = e.action,
                        location = type(e.location) == 'string' and e.location or nil,
                        note = type(e.note) == 'string' and e.note or nil,
                    }
                end
            end
            items[#items + 1] = {
                id = row.id,
                tag = row.tag,
                type = row.type,
                caseId = row.caseId,
                caseNumber = row.caseNumber,
                level = M.levelOf(row),
                result = Evidence.visibleResult(row.result, v.showMatch),
                collectedBy = officerRef(row.collectedBy, officers),
                collectedAt = row.collectedAt,
                chain = chain,
            }
        end
    end
    return items
end

--- One row as the actor sees it: item or nil (not visible).
local function visibleItem(actor, row)
    local views = M.views(actor, { row })
    return M.shape({ row }, views)[1], views[1]
end

---------------------------------------------------------------------------------------------------------------
-- Tablet exports

--- The canView result of `actor` for a case row (fredpd_records' fredpd_cases + assignees), or nil on an error.
local function caseViewOf(actor, kase)
    local okAssignees, assignees = db('case assignees', Store.assignees, { kase.id })
    if not okAssignees then return nil end
    local okView, caseView = pcall(function()
        return core():canView(actor.src, {
            type = 'case', id = kase.id, level = kase.level, status = kase.status == 'closed' and 'closed' or 'open',
            unit = kase.unit, assignees = assignees[kase.id] or {}, ownerCitizenid = kase.owner,
        })
    end)
    if not okView then
        M.log('error', 'canView(case) failed: %s', tostring(caseView))
        return nil
    end
    return caseView
end

--- Rows -> { ok, data = { items, total, page } } as `actor` sees them (views, shape, one page).
local function listPage(actor, rows, pageNo)
    local okViews, views = pcall(M.views, actor, rows)
    if not okViews then
        M.log('error', 'evidence visibility failed: %s', tostring(views))
        return fail('unavailable')
    end
    local okShape, items = pcall(M.shape, rows, views)
    if not okShape then
        M.log('error', 'evidence shape failed: %s', tostring(items))
        return fail('unavailable')
    end
    local page = {}
    local first = (pageNo - 1) * Evidence.PAGE_SIZE + 1
    for i = first, math.min(#items, first + Evidence.PAGE_SIZE - 1) do page[#page + 1] = items[i] end
    return ok({ items = page, total = #items, page = pageNo })
end

--- export listEvidence(src, { caseId?, unlinked?, page? }) -> { items, total, page }.
--- caseId: the case's evidence by number; unlinked: the analysed, unlinked queue (newest first); neither: the newest
--- evidence the viewer may see (the Store.LIST_CAP newest rows are considered).
function M.list(src, input)
    local actor, code, reason = M.actor(src, M.PAGE_GRANT)
    if not actor then return fail(code, reason) end
    local q = Evidence.listInput(input)
    if not q then return fail('validation') end
    local okRows, rows
    if q.caseId then
        okRows, rows = db('evidence byCase', Store.byCase, q.caseId)
    elseif q.unlinked then
        okRows, rows = db('evidence unlinked', Store.unlinked)
    else
        okRows, rows = db('evidence recent', Store.recent)
    end
    if not okRows then return fail('unavailable') end
    return listPage(actor, rows, q.page)
end

--- export listCaseEvidence(src, { caseId, page? }) -> { items, total, page } (same shape as listEvidence): the
--- evidence of one case for its case page (fredpd_records getCase). No mdt_page:evidence needed: on duty, and a view
--- of the case other than 'none' (else not_found). A kontaktnotis ('notice') lists nothing; with 'full' / 'masked'
--- every row is shaped for the viewer like listEvidence does.
function M.listCase(src, input)
    local actor, code, reason = M.actor(src, nil)
    if not actor then return fail(code, reason) end
    local q = Evidence.listInput(input)
    if not q or not q.caseId or q.unlinked then return fail('validation') end
    local okCase, kase = db('case byId', Store.caseById, q.caseId)
    if not okCase then return fail('unavailable') end
    if not kase then return fail('not_found') end
    local caseView = caseViewOf(actor, kase)
    if not caseView then return fail('unavailable') end
    if caseView == 'none' then return fail('not_found') end
    if caseView ~= 'full' and caseView ~= 'masked' then return ok({ items = {}, total = 0, page = q.page }) end
    local okRows, rows = db('evidence byCase', Store.byCase, kase.id)
    if not okRows then return fail('unavailable') end
    return listPage(actor, rows, q.page)
end

--- export getEvidence(src, { id }) -> EvidenceItem; not visible = not_found (existence does not leak).
function M.get(src, input)
    local actor, code, reason = M.actor(src, M.PAGE_GRANT)
    if not actor then return fail(code, reason) end
    local id = Evidence.idInput(input)
    if not id then return fail('validation') end
    local okRow, row = db('evidence byId', Store.byId, id)
    if not okRow then return fail('unavailable') end
    if not row then return fail('not_found') end
    local okItem, item = pcall(visibleItem, actor, row)
    if not okItem then
        M.log('error', 'evidence visibility failed: %s', tostring(item))
        return fail('unavailable')
    end
    if not item then return fail('not_found') end
    return ok(item)
end

---------------------------------------------------------------------------------------------------------------
-- Link

local function analysedBy(row, cid)
    for _, e in ipairs(row.chain or {}) do
        if type(e) == 'table' and e.action == 'analyse' and e.actor == cid then return true end
    end
    return false
end

local function pushCase(caseId, evidenceId)
    if GetResourceState('fredpd_mdt') ~= 'started' then return end
    local okPush, err = pcall(function()
        exports.fredpd_mdt:pushToOpenTablets('case', { type = 'evidenceLinked', caseId = caseId, evidenceId = evidenceId })
    end)
    if not okPush then M.log('warn', 'fredpd_mdt:pushToOpenTablets(case) failed: %s', tostring(err)) end
end

--- Shared by the dialog callback and the tablet export: the actor holds evidence.link and is on duty (checked by the
--- caller); `kase` is the case row (or nil). Returns { ok, data = { item, tag, caseNumber } } | fail.
function M.linkCore(actor, id, kase, via)
    if not M.format then return fail('unavailable') end
    local okRow, row = db('evidence byId', Store.byId, id)
    if not okRow then return fail('unavailable') end
    if not row then return fail('not_found', 'evidence') end
    local okItem, item, view = pcall(visibleItem, actor, row)
    if not okItem then
        M.log('error', 'evidence visibility failed: %s', tostring(item))
        return fail('unavailable')
    end
    if not (view and view.view == 'full') and not analysedBy(row, actor.citizenid) then
        return fail('not_found', 'evidence')
    end
    if row.caseId then return fail('validation', 'already_linked') end
    if not kase then return fail('not_found', 'case') end

    local caseView = caseViewOf(actor, kase)
    if not caseView then return fail('unavailable') end
    if caseView == 'none' then return fail('not_found', 'case') end
    if caseView ~= 'full' then return fail('unauthorized', 'case') end
    if kase.status ~= 'open' then return fail('validation', 'case_closed') end

    -- n = MAX(n) + 1 for the case, tag from formats.json evidenceTag; the transaction locks the case row, and the
    -- (case_id, n) / tag unique keys turn a concurrent link that took the same n into a rollback: retry once.
    local linked
    for _ = 1, 2 do
        local okN, n = db('evidence nextN', Store.nextN, kase.id)
        if not okN then return fail('unavailable') end
        local okTag, tag = pcall(M.format.tag, kase.caseNumber, n)
        if not okTag then
            M.log('error', 'evidenceTag format failed: %s', tostring(tag))
            return fail('unavailable')
        end
        local okTx = db('evidence link', Store.link, id, kase.id, n, tag, kase.level,
            { actor = actor.citizenid, action = 'link', note = kase.caseNumber })
        if not okTx then return fail('unavailable') end
        local okBack, after = db('evidence byId', Store.byId, id)
        if not okBack or not after then return fail('unavailable') end
        if after.caseId == kase.id then
            linked = { row = after, mine = after.n == n }
            break
        elseif after.caseId then
            return fail('validation', 'already_linked')
        end
    end
    if not linked then return fail('unavailable') end

    local row2 = linked.row
    if linked.mine then
        audit(actor.src, 'evidence.link', id, { caseId = kase.id, caseNumber = kase.caseNumber, tag = row2.tag,
            n = row2.n, via = via })
        TriggerEvent('fredpd:evidenceLinked', kase.id, id)
        pushCase(kase.id, id)
    end
    local okShaped, shaped = pcall(visibleItem, actor, row2)
    return ok({ item = okShaped and shaped or nil, tag = row2.tag, caseNumber = kase.caseNumber })
end

--- export linkEvidence(src, { id, caseId }) -> EvidenceItem (tablet).
function M.linkEvidence(src, input)
    local actor, code, reason = M.actor(src, M.LINK_GRANT)
    if not actor then return fail(code, reason) end
    if not M.format then return fail('unavailable') end -- formats.json missing: linking is disabled
    local q = Evidence.linkInput(input)
    if not q then return fail('validation') end
    local okCase, kase = db('case byId', Store.caseById, q.caseId)
    if not okCase then return fail('unavailable') end
    local result = M.linkCore(actor, q.id, kase, 'tablet')
    if not result.ok then return result end
    if not result.data.item then return fail('not_found') end
    return ok(result.data.item)
end

--- lib.callback 'fredpd:forensics:link' (dialog after an analysis): { id, caseNumber } ->
--- { ok = true, tag, caseNumber } | { ok = false, error, reason? }. Grant, duty, rate limit, input, then linkCore.
function M.linkFromDialog(src, data, now)
    local actor, code, reason = M.actor(src, M.LINK_GRANT)
    if not actor then return { ok = false, error = code, reason = reason } end
    if not M.format then return { ok = false, error = 'unavailable' } end -- formats.json missing: linking is disabled
    now = now or GetGameTimer()
    local last = lastLink[actor.src]
    if last and now - last < (M.cfg.linkCooldownMs or 2000) then return { ok = false, error = 'rate_limited' } end
    lastLink[actor.src] = now
    local id = Evidence.idInput(data)
    if not id then return { ok = false, error = 'validation', reason = 'id' } end
    local caseNumber = type(data) == 'table' and Evidence.caseNumberInput(data.caseNumber, M.format.isCaseNumber)
        or nil
    if not caseNumber then return { ok = false, error = 'validation', reason = 'case_number' } end
    local okCase, kase = db('case byNumber', Store.caseByNumber, caseNumber)
    if not okCase then return { ok = false, error = 'unavailable' } end
    local result = M.linkCore(actor, id, kase, 'dialog')
    if not result.ok then return { ok = false, error = result.error, reason = result.reason } end
    return { ok = true, tag = result.data.tag, caseNumber = result.data.caseNumber }
end

function M.forget(src)
    lastLink[tonumber(src) or -1] = nil
end

---------------------------------------------------------------------------------------------------------------
-- Evidence lockers: ox_inventory openInventory hook (synchronous, in-memory checks only)

--- Whether the player in an openInventory payload may open an evidence locker: on duty and holding
--- cfg.lockerGrant (default mdt_page:evidence), on top of the stash's own ox_inventory `groups` check, which knows
--- neither duty nor FredPD grants. cfg.lockerGrant = false turns the check off (groups only).
function M.mayOpenLocker(payload)
    if M.cfg.lockerGrant == false then return true end
    local src = type(payload) == 'table' and math.tointeger(tonumber(payload.source)) or nil
    if not src or src < 1 then return false end
    if not hasGrant(src, M.cfg.lockerGrant or M.PAGE_GRANT) then return false end
    local okDuty, onDuty = pcall(function() return core():isOnDuty(src) end)
    return okDuty and onDuty == true
end

return M
