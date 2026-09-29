-- SPDX-License-Identifier: GPL-3.0-only
-- On-duty roster (UnitsPush = { units: UnitStatus[] }, dispatch.ts). Rebuilt from the online players whenever
-- something that changes it happens (duty, job, character load/logout, drop, officer name/callsign, a take/leave/
-- close, fredpd_devtools fake units), then pushed to open tablets (topic 'units') and to the service
-- (unitsChanged). Rebuilds are debounced with SetTimeout, not a loop: the first change waits MIN_DELAY_MS so a
-- burst is coalesced, and pushes are at least INTERVAL_MS apart. Nothing runs while nothing changes.

local Store = require 'server.alert_store'
local Fanout = require 'server.fanout'

local M = {}

M.INTERVAL_MS = 2000
M.MIN_DELAY_MS = 250
M.MAX_FAKE = 200
local CITIZENID_PATTERN = '^[%w_%-]+$' -- CitizenIdSchema: [A-Za-z0-9_-]{1,50}

local roster = nil   -- last built UnitStatus[] (nil until the first build)
local fake = nil     -- fredpd_devtools fake units as UnitStatus[] (nil when no run is active)
local pending = false
local lastPush = nil -- GetGameTimer() of the last rebuild
local lastPrint = nil -- fingerprint of the last pushed roster (an unchanged roster is not pushed again)

local function str(v, max)
    if type(v) ~= 'string' or v == '' then return nil end
    return v:sub(1, max)
end

--- Order: unit, then callsign (officers without one last), then name.
local function compare(a, b)
    local ua, ub = a.unit or '~', b.unit or '~'
    if ua ~= ub then return ua < ub end
    local ca, cb = a.callsign or '~', b.callsign or '~'
    if ca ~= cb then return ca < cb end
    if a.displayName ~= b.displayName then return a.displayName < b.displayName end
    return a.citizenid < b.citizenid
end

--- UnitStatus for an on-duty player, or nil (not on duty / no character).
local function unitOf(src)
    local core = exports.fredpd_core
    if core:isOnDuty(src) ~= true then return nil end
    local officer = core:getOfficer(src)
    local cid = officer and officer.citizenid or core:getCitizenId(src)
    if type(cid) ~= 'string' then return nil end
    return {
        citizenid = cid,
        -- §4.9: Discord name from fredpd_officers; until the row exists, the FiveM account name (never the
        -- character name), as fredpd_core does for a new officer row.
        displayName = officer and officer.displayName or GetPlayerName(tostring(src)) or cid,
        callsign = officer and officer.callsign or nil,
        unit = officer and officer.unit or nil,
        onDuty = true,
        alertId = nil,
    }
end

--- Build the roster now (awaits one query for the officers' current alerts).
--- @return table[] UnitStatus[]
function M.build()
    local units, cids = {}, {}
    for _, src in ipairs(Fanout.players()) do
        local ok, unit = pcall(unitOf, src)
        if ok and unit then
            units[#units + 1] = unit
            cids[#cids + 1] = unit.citizenid
        elseif not ok then
            Fanout.logThrottled('roster', 'error', 'roster entry for %s failed: %s', src, tostring(unit))
        end
    end
    local alertOf = Store.assignments(cids)
    for _, unit in ipairs(units) do unit.alertId = alertOf[unit.citizenid] end
    for _, unit in ipairs(fake or {}) do units[#units + 1] = unit end
    table.sort(units, compare)
    return units
end

--- Deterministic text of a roster (field order fixed; JSON key order is not).
function M.fingerprint(units)
    local parts = {}
    for i, u in ipairs(units) do
        parts[i] = table.concat({ u.citizenid, u.displayName or '', u.callsign or '', u.unit or '',
            tostring(u.alertId or '') }, '\31')
    end
    return table.concat(parts, '\30')
end

local function rebuild()
    pending = false
    lastPush = GetGameTimer()
    local ok, units = pcall(M.build)
    if not ok then
        Fanout.log('error', 'units roster rebuild failed: %s', tostring(units))
        return
    end
    roster = units
    -- Most triggers (a civilian's character load, a callsign push for someone off duty) change nothing.
    local fp = M.fingerprint(units)
    if fp == lastPrint then return end
    lastPrint = fp
    local payload = { units = units }
    Fanout.push('units', payload)
    Fanout.postInternal('unitsChanged', payload)
end

--- Something changed: rebuild + push once, soon (≥ MIN_DELAY_MS) but never sooner than INTERVAL_MS after the
--- previous push. Calls while one is pending are coalesced into it.
function M.schedule()
    if pending then return end
    pending = true
    local wait = M.MIN_DELAY_MS
    if lastPush then wait = math.max(wait, lastPush + M.INTERVAL_MS - GetGameTimer()) end
    SetTimeout(wait, rebuild)
end

--- Current roster (built on first use). Awaits when nothing was built yet.
function M.current()
    if not roster then roster = M.build() end
    return roster
end

--- fredpd_devtools `fredpd:devtools:fakeUnits(units|nil)`: fake on-duty units for load tests (§5.10), shown with
--- the real ones. Entries are { id, unit, callsign, … }; anything malformed is skipped, at most MAX_FAKE.
function M.setFake(list)
    if type(list) ~= 'table' then
        fake = nil
    else
        local out = {}
        for i = 1, math.min(#list, M.MAX_FAKE) do
            local u = list[i]
            local id = type(u) == 'table' and str(u.id, 50)
            if id and id:match(CITIZENID_PATTERN) then
                local callsign = str(u.callsign, 16)
                out[#out + 1] = {
                    citizenid = id, displayName = callsign or id, callsign = callsign, unit = str(u.unit, 32),
                    onDuty = true, alertId = nil,
                }
            end
        end
        fake = #out > 0 and out or nil
    end
    M.schedule()
end

--- Tests: forget all state.
function M._reset()
    roster, fake, pending, lastPush, lastPrint = nil, nil, false, nil, nil
end

return M
