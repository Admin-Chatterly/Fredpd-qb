-- SPDX-License-Identifier: GPL-3.0-only
-- getHome (HomeOutput, packages/types/src/mdt.ts; task 2.7 data): one callback composing fredpd_core (me, units,
-- duty), fredpd_bolo (listBolos: active count + the 10 newest, canView applied there) and fredpd_records
-- (getHomeCases, countMyOpenCases). A missing or failing source degrades to 0 / [] (logged) instead of failing the
-- whole page; only an unknown character is an error.

local C = require 'server.common'
local Open = require 'server.open'

local M = {}

M.MAX_ITEMS = 10
M.VARIANTS = { igv = true, span = true, utredning = true, tekniker = true, ledning = true }
M.DEFAULT_VARIANT = 'igv'

local homeByUnit = nil -- [unit code] = home variant, from fredpd_core/config/units.json

--- config/units.json (copied into fredpd_core by the build) -> { [code] = home }. Read once.
function M.homeByUnit()
    if homeByUnit then return homeByUnit end
    homeByUnit = {}
    local ok, parsed = pcall(function()
        local raw = LoadResourceFile('fredpd_core', 'config/units.json')
        return raw and json.decode(raw) or nil
    end)
    if ok and type(parsed) == 'table' and type(parsed.units) == 'table' then
        for _, u in ipairs(parsed.units) do
            if type(u) == 'table' and type(u.code) == 'string' and M.VARIANTS[u.home] then homeByUnit[u.code] = u.home end
        end
    else
        C.logThrottled('units', 'warn', 'fredpd_core config/units.json not readable; Hem uses the %s variant',
            M.DEFAULT_VARIANT)
    end
    return homeByUnit
end

function M.resetCache()
    homeByUnit = nil
end

--- Hem variant for a primary unit code (nil = no unit grant).
function M.variantFor(unit)
    return (unit and M.homeByUnit()[unit]) or M.DEFAULT_VARIANT
end

local function firstN(list, n)
    local out = {}
    if type(list) ~= 'table' then return out end
    for i = 1, math.min(#list, n) do out[i] = list[i] end
    return out
end

local function nonNegInt(v)
    local n = math.tointeger(tonumber(v))
    if not n or n < 0 then return 0 end
    return n
end

local function officerRef(officer)
    if type(officer) ~= 'table' or type(officer.citizenid) ~= 'string' then return nil end
    return {
        citizenid = officer.citizenid,
        displayName = type(officer.displayName) == 'string' and officer.displayName or officer.citizenid,
        callsign = type(officer.callsign) == 'string' and officer.callsign or nil,
        unit = type(officer.unit) == 'string' and officer.unit or nil,
    }
end

--- On-duty officers online: count, and (for the Ledning roster) their OfficerRefs sorted by callsign, then name.
function M.onDuty(withRoster)
    local count, roster = 0, {}
    local players = GetPlayers() or {}
    for _, id in ipairs(players) do
        local src = C.playerSrc(id)
        if src and C.isOnDuty(src) then
            count = count + 1
            if withRoster then
                local ok, officer = C.core('getOfficer', src)
                local ref = ok and officerRef(officer) or nil
                if ref then
                    ref.onDuty = true
                    roster[#roster + 1] = ref
                end
            end
        end
    end
    table.sort(roster, function(a, b)
        local ca, cb = a.callsign or '\255', b.callsign or '\255'
        if ca ~= cb then return ca < cb end
        if a.displayName ~= b.displayName then return a.displayName < b.displayName end
        return a.citizenid < b.citizenid
    end)
    return count, roster
end

--- Tablet action getHome(src) -> { ok, data = HomeOutput } | { ok = false, error }.
function M.get(src)
    src = C.playerSrc(src)
    if not src then return C.fail('unauthorized') end
    local citizenid = C.citizenId(src)
    if not citizenid then return C.fail('unauthorized') end

    local me = Open.me(src, citizenid)
    local okUnits, units = C.core('getUnits', src)
    local unit = okUnits and type(units) == 'table' and units[1] or nil
    local variant = M.variantFor(type(unit) == 'string' and unit or nil)

    local activeBolos, recentBolos = 0, {}
    local bolos = C.callExport('fredpd_bolo', 'listBolos', src, { active = true, page = 1 })
    if bolos.ok and type(bolos.data) == 'table' then
        activeBolos = nonNegInt(bolos.data.total)
        recentBolos = firstN(bolos.data.items, M.MAX_ITEMS)
    end

    local myCases = {}
    local cases = C.callExport('fredpd_records', 'getHomeCases', src, { limit = M.MAX_ITEMS })
    if cases.ok then myCases = firstN(cases.data, M.MAX_ITEMS) end

    local myOpenCases = 0
    local count = C.callExport('fredpd_records', 'countMyOpenCases', src, nil)
    if count.ok then myOpenCases = nonNegInt(count.data) end

    local onDuty, roster = M.onDuty(variant == 'ledning')

    return C.ok({
        me = me,
        variant = variant,
        counts = { activeBolos = activeBolos, myOpenCases = myOpenCases, onDuty = onDuty },
        recentBolos = recentBolos,
        myCases = myCases,
        roster = roster,
    })
end

return M
