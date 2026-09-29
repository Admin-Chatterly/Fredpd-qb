-- SPDX-License-Identifier: GPL-3.0-only
-- In-memory active BOLOs (IMPLEMENTATION.md §5.4): activeByPlate, activeByCitizen and byId, so checkPlate /
-- checkPerson never wait for the database (qbx_police calls checkPlate inside a net event). Pure Lua: the service
-- wires the database side (rebuild source, lazy expiry) through M.onExpire.
--
-- Rebuilt from the database on start and after every create / resolve / expiry. A write also updates the maps at once
-- (so the next lookup sees it) and bumps M.gen; a rebuild whose query started before a write is discarded
-- (replaceAll returns false) and the write's own rebuild wins.
--
-- Expiry without timers: an entry is live iff flagActive and (no expiresEpoch or expiresEpoch > now), now = os.time()
-- (unix seconds, zone-independent, compared with expires_at read as UTC). A lookup that meets an expired entry drops
-- it and calls M.onExpire(entry) once (the service then runs the UPDATE and writes the bolo.expire audit row).

local M = {}

M.byId, M.byPlate, M.byCitizen = {}, {}, {}
M.gen = 0
M.ready = false

--- Clock in unix seconds (tests replace it).
M.clock = function() return os.time() end

--- Called once per entry that a lookup or rebuild found expired. Set by the service.
M.onExpire = nil

function M.isLive(entry, now)
    if type(entry) ~= 'table' or not entry.flagActive then return false end
    return entry.expiresEpoch == nil or entry.expiresEpoch > (now or M.clock())
end

local function index(entry)
    M.byId[entry.id] = entry
    if entry.kind == 'vehicle' and entry.plate then M.byPlate[entry.plate] = entry end
    if entry.kind == 'person' and entry.citizenid then M.byCitizen[entry.citizenid] = entry end
end

local function unindex(entry)
    if M.byId[entry.id] == entry then M.byId[entry.id] = nil end
    if entry.plate and M.byPlate[entry.plate] == entry then M.byPlate[entry.plate] = nil end
    if entry.citizenid and M.byCitizen[entry.citizenid] == entry then M.byCitizen[entry.citizenid] = nil end
end

local function expired(entry)
    if M.onExpire then M.onExpire(entry) end
end

--- Add (or replace) an entry after a write. Entries that are not live are only removed.
function M.put(entry)
    M.gen = M.gen + 1
    local old = M.byId[entry.id]
    if old then unindex(old) end
    if M.isLive(entry) then index(entry) end
end

--- Remove an entry after a write (resolve).
function M.remove(id)
    local entry = M.byId[id]
    M.gen = M.gen + 1
    if entry then unindex(entry) end
end

--- Replace everything with a rebuild's rows (active = 1, expired ones included). Refused (false) when a write
--- happened since the rebuild's query started (gen changed).
--- @param entries table[]
--- @param startGen integer M.gen when the query started
--- @return boolean applied
function M.replaceAll(entries, startGen)
    if startGen ~= M.gen then return false end
    M.byId, M.byPlate, M.byCitizen = {}, {}, {}
    local now = M.clock()
    local stale = {}
    for _, entry in ipairs(entries) do
        if M.isLive(entry, now) then index(entry) else stale[#stale + 1] = entry end
    end
    M.ready = true
    for _, entry in ipairs(stale) do expired(entry) end
    return true
end

--- The entry if still live; an expired one is dropped (and reported once through onExpire).
local function live(entry)
    if not entry then return nil end
    if M.isLive(entry) then return entry end
    M.gen = M.gen + 1
    unindex(entry)
    expired(entry)
    return nil
end

function M.getByPlate(plate)
    return plate and live(M.byPlate[plate]) or nil
end

function M.getByCitizen(citizenid)
    return citizenid and live(M.byCitizen[citizenid]) or nil
end

function M.getById(id)
    return id and live(M.byId[id]) or nil
end

--- Every live entry, newest (highest id) first.
function M.all()
    local ids = {}
    for id in pairs(M.byId) do ids[#ids + 1] = id end
    local out = {}
    for _, id in ipairs(ids) do
        local e = live(M.byId[id])
        if e then out[#out + 1] = e end
    end
    table.sort(out, function(a, b) return a.id > b.id end)
    return out
end

--- Forget everything (tests, resource restart).
function M.reset()
    M.byId, M.byPlate, M.byCitizen = {}, {}, {}
    M.gen = 0
    M.ready = false
end

return M
