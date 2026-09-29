-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_core/server/officers.lua pure parts: primary unit, lowest free callsign, row mapping, the /officer push,
-- and isOnDuty / getCitizenId over a stubbed qbx_core. Callsign allocation against MariaDB is in core_db_test.lua.
-- Run: lua5.4 tests/lua/run.lua core_officers_test
local Officers = require('server.officers')
local Core = require('server.core')
local helper = require('helper')

local tests = {}

local ORDER = { 'ledning', 'span', 'utredning', 'tekniker', 'igv' }
local TEMPLATE = helper.readJson('config/formats.json').callsign

tests['primaryUnit follows units.json order, not grant order'] = function(t)
    t.eq(Officers.primaryUnit({ 'igv', 'span' }, ORDER), 'span')
    t.eq(Officers.primaryUnit({ 'igv' }, ORDER), 'igv')
    t.eq(Officers.primaryUnit({ 'custom', 'tekniker' }, ORDER), 'tekniker')
    t.eq(Officers.primaryUnit({ 'custom' }, ORDER), 'custom', 'unknown unit when nothing else')
    t.eq(Officers.primaryUnit({}, ORDER), nil)
    t.eq(Officers.primaryUnit(nil, ORDER), nil)
end

tests['nextCallsign picks the lowest free number (default template {{unit}}-{{n:2}})'] = function(t)
    t.eq(TEMPLATE, '{{unit}}-{{n:2}}')
    t.eq(Officers.nextCallsign(TEMPLATE, 'IGV', {}), 'IGV-01')
    t.eq(Officers.nextCallsign(TEMPLATE, 'IGV', { ['IGV-01'] = true, ['IGV-02'] = true }), 'IGV-03')
    t.eq(Officers.nextCallsign(TEMPLATE, 'IGV', { ['IGV-01'] = true, ['IGV-03'] = true }), 'IGV-02', 'fills gaps')
    t.eq(Officers.nextCallsign(TEMPLATE, 'SPAN', { ['IGV-01'] = true }), 'SPAN-01')
    local taken = {}
    for i = 1, 99 do taken[('IGV-%02d'):format(i)] = true end
    t.eq(Officers.nextCallsign(TEMPLATE, 'IGV', taken), 'IGV-100', 'width is a minimum')
    local _, n = Officers.nextCallsign('{{unit}}{{n}}', 'LED', { LED1 = true })
    t.eq(n, 2)
end

tests['nextCallsign raises for a template the generator cannot fill'] = function(t)
    local ok, err = pcall(Officers.nextCallsign, 'K-{{seq}}', 'IGV', {})
    t.ok(not ok)
    t.ok(tostring(err):find('missing_value', 1, true), tostring(err))
    ok = pcall(Officers.nextCallsign, TEMPLATE, 'igv', {})
    t.ok(not ok, 'lower-case prefix is invalid for {{unit}}')
end

tests['rowToOfficer maps DB columns'] = function(t)
    t.eq(Officers.rowToOfficer({ citizenid = 'C1', discord_id = 1001, display_name = 'Anna B.', callsign = 'IGV-07',
        unit = 'igv' }), { citizenid = 'C1', discordId = '1001', displayName = 'Anna B.', callsign = 'IGV-07', unit = 'igv' })
    t.eq(Officers.rowToOfficer(nil), nil)
    t.eq(Officers.rowToOfficer({}), nil)
end

--- Stub qbx_core through Core.getPlayerData.
local function withPlayers(players, fn)
    local saved = Core.getPlayerData
    Core.getPlayerData = function(src) return players[tonumber(src)] end
    local ok, err = pcall(fn)
    Core.getPlayerData = saved
    if not ok then error(err, 0) end
end

tests['isOnDuty needs job.type leo and onduty'] = function(t)
    withPlayers({
        [1] = { citizenid = 'A', job = { type = 'leo', onduty = true } },
        [2] = { citizenid = 'B', job = { type = 'leo', onduty = false } },
        [3] = { citizenid = 'C', job = { type = 'ems', onduty = true } },
        [4] = { citizenid = 'D' },
    }, function()
        t.eq(Officers.isOnDuty(1), true)
        t.eq(Officers.isOnDuty(2), false)
        t.eq(Officers.isOnDuty(3), false)
        t.eq(Officers.isOnDuty(4), false)
        t.eq(Officers.isOnDuty(5), false)
        t.eq(Officers.getCitizenId(3), 'C')
        t.eq(Officers.getCitizenId(5), nil)
    end)
end

tests['setIdentity: validation and in-memory update of known officers'] = function(t)
    local savedTrigger = rawget(_G, 'TriggerEvent')
    local events = {}
    rawset(_G, 'TriggerEvent', function(name, cid) events[#events + 1] = { name, cid } end)
    local savedMySQL = rawget(_G, 'MySQL')
    rawset(_G, 'MySQL', { query = { await = function()
        return { { citizenid = 'OFF1', discord_id = '5001', display_name = 'Old', callsign = 'IGV-01', unit = 'igv' },
            { citizenid = 'OFF2', discord_id = '5001', display_name = 'Old', unit = 'span' },
            { citizenid = 'OFF3', discord_id = '5002', display_name = 'Other' } }
    end } })
    local ok, err = pcall(function()
        t.eq(Officers.loadAll(), true)
        t.eq(Officers.setIdentity('5001', 'Anna B.', 'https://cdn/a.png'), 2)
        t.eq(Officers.setIdentity('5003', 'Nobody', nil), 0, 'not loaded yet: remembered for later')
        t.eq(Officers.setIdentity('x', 'A', nil), false)
        t.eq(Officers.setIdentity('5001', '', nil), false)
        t.eq(Officers.setIdentity('5001', ('x'):rep(101), nil), false)
        -- Characters, not bytes (VARCHAR(100) utf8mb4): 26 emoji = 104 bytes is fine, 101 characters is not.
        local cop = '\u{1F46E}'
        t.eq(Officers.setIdentity('5002', cop:rep(26), nil), 1)
        t.eq(Officers.setIdentity('5002', ('ö'):rep(100), nil), 1)
        t.eq(Officers.setIdentity('5002', cop:rep(101), nil), false)
        t.eq(Officers.setIdentity('5002', 'bad \xff utf8', nil), false)
        t.eq(Officers.setIdentity('5002', 'Other', nil), 1)
        withPlayers({ [9] = { citizenid = 'OFF1', job = { type = 'leo', onduty = true } },
            [10] = { citizenid = 'NOPE' } }, function()
            local o = Officers.getOfficer(9)
            t.eq(o.displayName, 'Anna B.')
            t.eq(o.avatarUrl, 'https://cdn/a.png')
            t.eq(o.callsign, 'IGV-01')
            o.callsign = 'changed'
            t.eq(Officers.getOfficer(9).callsign, 'IGV-01', 'getOfficer returns a copy')
            t.eq(Officers.getOfficer(10), nil)
        end)
    end)
    rawset(_G, 'TriggerEvent', savedTrigger)
    rawset(_G, 'MySQL', savedMySQL)
    if not ok then error(err, 0) end
    t.eq(#events, 5)
    t.eq(events[1][1], 'fredpd:officerChanged')
end

tests['clampName cuts at a character boundary and rejects invalid UTF-8'] = function(t)
    t.eq(Officers.clampName('Anna'), 'Anna')
    t.eq(Officers.clampName(('ö'):rep(120)), ('ö'):rep(100))
    t.eq(Officers.clampName('ÅÄÖ', 2), 'ÅÄ')
    t.eq(Officers.clampName(''), nil)
    t.eq(Officers.clampName('\xff\xfe'), nil)
    t.eq(Officers.clampName(nil), nil)
end

--- Run fn with globals and module fields replaced; everything is restored afterwards.
local function patched(globals, fields, fn)
    local savedG, savedF = {}, {}
    for k, v in pairs(globals) do savedG[k] = rawget(_G, k); rawset(_G, k, v) end
    for _, f in ipairs(fields) do savedF[#savedF + 1] = { f[1], f[2], f[1][f[2]] }; f[1][f[2]] = f[3] end
    local ok, err = pcall(fn)
    for k in pairs(globals) do rawset(_G, k, savedG[k]) end
    for _, f in ipairs(savedF) do f[1][f[2]] = f[3] end
    if not ok then error(err, 0) end
end

tests['getOfficer takes the rank from the live grant set once it is loaded'] = function(t)
    local Perms = require('server.perms')
    local sets = {}
    patched({ MySQL = { query = { await = function()
        return { { citizenid = 'R1', discord_id = '6001', display_name = 'Rut', rank_role_id = '111' } }
    end } } }, {
        { Perms, 'rawSet', function(src) return sets[src] end },
        { Core, 'getPlayerData', function() return { citizenid = 'R1', job = { type = 'leo' } } end },
    }, function()
        Officers.loadAll()
        t.eq(Officers.getOfficer(1).rankRoleId, '111', 'grants not loaded yet: stored value')
        sets[1] = { rank = { roleId = '222', key = 'inspektor' } }
        local o = Officers.getOfficer(1)
        t.eq(o.rankRoleId, '222')
        t.eq(o.rankKey, 'inspektor')
        sets[1] = { rank = nil }
        o = Officers.getOfficer(1)
        t.eq(o.rankRoleId, nil, 'rank role removed on Discord')
        t.eq(o.rankKey, nil)
    end)
end

--- A fredpd_officers table in memory whose MySQL.update.await answers like oxmysql (mysql2 with CLIENT_FOUND_ROWS):
--- INSERT IGNORE -> 1 inserted / 0 duplicate; UPDATE -> rows *matched* by the WHERE clause, changed or not; any
--- INSERT ... ON DUPLICATE KEY UPDATE -> 1 for an insert AND for a matched unchanged row (so creation cannot be
--- told from it; the test also asserts the module no longer uses that shape for creation).
local function foundRowsTable()
    local rows, sqls = {}, {}
    local db = { rows = rows, sqls = sqls }
    db.update = function(sql, p)
        sqls[#sqls + 1] = sql
        if sql:find('ON DUPLICATE KEY UPDATE', 1, true) then
            if rows[p[1]] then return 1 end -- matched and left unchanged: still 1 under FOUND_ROWS
            rows[p[1]] = { citizenid = p[1], discord_id = p[2], display_name = p[3] }
            return 1
        elseif sql:find('^INSERT IGNORE') then
            if rows[p[1]] then return 0 end
            rows[p[1]] = { citizenid = p[1], discord_id = p[2], display_name = p[3] }
            return 1
        elseif sql:find('SET discord_id', 1, true) then
            local r = rows[p[2]]
            if r and r.discord_id ~= p[3] then r.discord_id = p[1]; return 1 end
            return 0
        end
        error('unexpected SQL in test: ' .. sql)
    end
    db.single = function(_, p) return rows[p[1]] end
    return db
end

tests['ensureRow audits a newly created roster row once (FOUND_ROWS semantics)'] = function(t)
    local Perms = require('server.perms')
    local Audit = require('server.audit')
    local db, written, discord = foundRowsTable(), {}, '7001'
    patched({
        MySQL = { update = { await = db.update }, single = { await = db.single } },
        GetPlayerName = function() return ('Å'):rep(150) end,
    }, {
        { Perms, 'getDiscordId', function() return discord end },
        { Audit, 'write', function(e) written[#written + 1] = e; return true end },
    }, function()
        local pd = { citizenid = 'NEW1', job = { type = 'leo' } }
        t.eq(Officers.ensureRow(3, pd).citizenid, 'NEW1')
        t.eq(#written, 1)
        t.eq(written[1].action, 'officer.create')
        t.eq(written[1].targetId, 'NEW1')
        t.eq(written[1].meta.via, 'load')
        t.eq(written[1].actorCitizenid, nil, 'system actor')
        t.eq(db.rows.NEW1.display_name, ('Å'):rep(100), 'FiveM name clamped to 100 characters')
        for _ = 1, 3 do Officers.ensureRow(3, pd) end
        t.eq(#written, 1, 'reloading an existing officer is not a new roster row')
        for _, sql in ipairs(db.sqls) do
            t.ok(not sql:find('ON DUPLICATE KEY', 1, true), 'creation never inferred from an upsert: ' .. sql)
        end
        discord = '7002'
        t.eq(Officers.ensureRow(3, pd).discordId, '7002')
        t.eq(#written, 2)
        t.eq(written[2].action, 'officer.relink')
        t.eq(written[2].meta.discordId, '7002')
        Officers.ensureRow(3, pd)
        t.eq(#written, 2, 'unchanged Discord account: no relink row')
        t.eq(Officers.ensureRow(3, { citizenid = 'CIV', job = { type = 'civ' } }), nil)
        t.eq(Officers.ensureRow(3, { citizenid = ('X'):rep(51), job = { type = 'leo' } }), nil, 'too long for the key')
    end)
end

return tests
