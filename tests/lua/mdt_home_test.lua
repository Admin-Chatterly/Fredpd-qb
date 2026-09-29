-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_mdt/server/home.lua (getHome, HomeOutput): the variant from config/units.json `home` of the primary unit,
-- counts and lists from fredpd_bolo (listBolos) and fredpd_records (getHomeCases, countMyOpenCases), the on-duty
-- count and the Ledning-only roster from fredpd_core; failing or stopped sources degrade to 0 / [].
-- Writes golden/home.*.json for resources/[fredpd]/fredpd_mdt/test/contract.test.ts.
-- Run: lua5.4 tests/lua/run.lua mdt_home
local H = dofile('./resources/[fredpd]/fredpd_mdt/test/harness.lua')

local tests = {}

local function bolo(id)
    return { id = id, kind = 'vehicle', plate = ('ABC%02dD'):format(id), subject = ('ABC%02dD · sultan'):format(id),
        reason = 'Rån', level = 0, createdAt = '2026-09-29T08:00:00Z', active = true,
        issuedBy = { citizenid = 'MDT10001', displayName = 'Anna B.', callsign = 'IGV-07', unit = 'igv' } }
end

local CASE = { visibility = 'full', id = 12, caseNumber = 'K-12-26', title = 'Rån mot värdetransport',
    status = 'open', level = 0 }

local function replies(env, nBolos)
    local items = {}
    for i = 1, nBolos do items[i] = bolo(i) end
    env.replies['fredpd_bolo:listBolos'] = function(_, input)
        assert(input.active == true and input.page == 1, 'active BOLOs, page 1')
        return { ok = true, data = { items = items, total = nBolos + 30, page = 1 } }
    end
    env.replies['fredpd_records:getHomeCases'] = function(_, input)
        assert(input.limit == 10, 'limit 10')
        return { ok = true, data = { CASE, { visibility = 'notice', contact = { displayName = 'Eva L.', unit = 'ledning' } } } }
    end
    env.replies['fredpd_records:countMyOpenCases'] = { ok = true, data = 3 }
end

tests['1 IGV: variant igv, counts, at most 10 recent BOLOs, my cases, no roster'] = function(t)
    H.with(function(env, mods)
        replies(env, 14)
        local res = mods['server.home'].get(1)
        t.eq(res.ok, true)
        local d = res.data
        t.eq(d.me, { citizenid = 'MDT10001', displayName = 'Anna B.', callsign = 'IGV-07', unit = 'igv' })
        t.eq(d.variant, 'igv')
        -- on duty: players 1, 2, 5, 6, 7 (3 is off duty, 4 a civilian)
        t.eq(d.counts, { activeBolos = 44, myOpenCases = 3, onDuty = 5 })
        t.eq(#d.recentBolos, 10)
        t.eq(d.recentBolos[1].id, 1)
        t.eq(#d.myCases, 2)
        t.eq(d.roster, {})
        H.writeGolden('home.igv', d)
    end)
end

tests['2 Ledning: variant ledning with the on-duty roster (OfficerRef + onDuty), sorted by callsign'] = function(t)
    H.with(function(env, mods)
        replies(env, 2)
        local d = mods['server.home'].get(2).data
        t.eq(d.variant, 'ledning')
        local callsigns = {}
        for i, r in ipairs(d.roster) do
            callsigns[i] = r.callsign
            t.eq(r.onDuty, true)
        end
        -- player 7 has no officer row: counted, not listed; player 3 is off duty
        t.eq(callsigns, { 'IGV-07', 'IGV-11', 'LED-01', 'SPAN-02' })
        t.eq(d.roster[1], { citizenid = 'MDT10001', displayName = 'Anna B.', callsign = 'IGV-07', unit = 'igv', onDuty = true })
        t.eq(d.counts.onDuty, 5)
        H.writeGolden('home.ledning', d)
    end)
end

tests['3 variants follow units.json home; no unit or unknown unit -> igv'] = function(t)
    H.with(function(env, mods)
        local Home = mods['server.home']
        t.eq(Home.get(5).data.variant, 'span')
        t.eq(Home.get(7).data.variant, 'tekniker')
        env.players[1].units = {}
        t.eq(Home.get(1).data.variant, 'igv')
        env.players[1].units = { 'hundenhet' }
        t.eq(Home.get(1).data.variant, 'igv')
        -- A custom mapping in units.json is honoured; an invalid home is ignored.
        env.units = '{"units":[{"code":"hundenhet","home":"span"},{"code":"igv","home":"nope"}]}'
        Home.resetCache()
        t.eq(Home.get(1).data.variant, 'span')
        env.players[1].units = { 'igv' }
        t.eq(Home.get(1).data.variant, 'igv')
        -- units.json missing: default and a warning.
        env.units = false
        Home.resetCache()
        t.eq(Home.get(5).data.variant, 'igv')
    end)
end

tests['4 sources down or failing: zeros and empty lists, never an error'] = function(t)
    H.with(function(env, mods)
        env.resources.fredpd_bolo = 'stopped'
        env.replies['fredpd_records:getHomeCases'] = function() error('db down', 0) end
        env.replies['fredpd_records:countMyOpenCases'] = { ok = false, error = 'unavailable' }
        local res = mods['server.home'].get(1)
        t.eq(res.ok, true)
        t.eq(res.data.counts, { activeBolos = 0, myOpenCases = 0, onDuty = 5 })
        t.eq(res.data.recentBolos, {})
        t.eq(res.data.myCases, {})
        -- listBolos refusing (no mdt_page:bolos) -> 0 too.
        env.resources.fredpd_bolo = 'started'
        env.replies['fredpd_bolo:listBolos'] = { ok = false, error = 'unauthorized' }
        env.replies['fredpd_records:countMyOpenCases'] = { ok = true, data = -4 }
        res = mods['server.home'].get(1)
        t.eq(res.data.counts.activeBolos, 0)
        t.eq(res.data.counts.myOpenCases, 0, 'negative counts clamp to 0')
    end)
end

tests['5 me without an officer row: placeholder name; no character: unauthorized'] = function(t)
    H.with(function(env, mods)
        local Home = mods['server.home']
        t.eq(Home.get(7).data.me, { citizenid = 'MDT10007', displayName = 'Polis utan namn (…1007)' })
        env.players[7].cid = nil
        t.eq(Home.get(7), { ok = false, error = 'unauthorized' })
        t.eq(Home.get(0), { ok = false, error = 'unauthorized' })
    end)
end

return tests
