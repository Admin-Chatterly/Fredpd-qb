-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_mdt/server/tablets.lua against a real MariaDB (tests/lua/mysql_shim.lua runs the migrations and fakes
-- oxmysql; every session at time_zone '+02:00', §C7): /surfplatta issuing (row + ox_inventory metadata + audit,
-- serial collisions, rollback when AddItem fails, refusals), listTablets (TabletListOutput, paging, OfficerRefs, ISO
-- UTC), setTabletRevoked (audit, force-close of the open tablet, reinstating) and the open flow reading the rows.
-- Writes the golden files checked by resources/[fredpd]/fredpd_mdt/test/contract.test.ts.
-- Database fredpd_test_mdt_lua (reset once per run). Skips with a notice when MariaDB is unreachable.
-- Run: lua5.4 tests/lua/run.lua mdt_tablets
local shim = require('mysql_shim')
local helper = require('helper')
local H = dofile('./resources/[fredpd]/fredpd_mdt/test/harness.lua')

local DB = 'fredpd_test_mdt_lua'
local SERIAL = '^SP%-[A-HJ-NP-Z2-9][A-HJ-NP-Z2-9][A-HJ-NP-Z2-9][A-HJ-NP-Z2-9]%-[A-HJ-NP-Z2-9][A-HJ-NP-Z2-9]'
    .. '[A-HJ-NP-Z2-9][A-HJ-NP-Z2-9]$'
local ISO = '^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$'

local tests = {}
local prepared = nil
local notified = false

local OFFICERS = {
    { 'MDT10001', '100000000000000001', 'Anna B.', 'IGV-07', 'igv' },
    { 'MDT10002', '100000000000000002', 'Eva L.', 'LED-01', 'ledning' },
    { 'MDT10005', '100000000000000005', 'Cia D.', 'SPAN-02', 'span' },
}

local function q(sql, params) return MySQL.query.await(sql, params) end
local function scalar(sql, params) return MySQL.scalar.await(sql, params) end

--- Run fn(t, env, mods) with MariaDB + mocks installed.
local function withDb(t, fn)
    local ok, reason = shim.available()
    if not ok then
        if not notified then
            print(('SKIP mdt_tablets_test: MariaDB unreachable (%s)'):format((reason or ''):gsub('%s+$', '')))
            notified = true
        end
        return
    end
    local savedDatabase, savedResource = shim.database, shim.resourceName
    local okRun, err = pcall(H.with, { mysql = false, before = function(env)
        shim.install({ database = DB, sessionTimeZone = '+02:00' })
        shim.resourceName = 'fredpd_core'
        if prepared == nil then
            prepared = false
            shim.resetDatabase(DB, true)
            require('server.db').migrate({ log = function() end, resource = 'fredpd_core' })
            prepared = true
        end
        assert(prepared, 'database not prepared')
        q('DELETE FROM fredpd_tablets')
        q("DELETE FROM fredpd_audit WHERE action LIKE 'tablet.%'")
        for _, r in ipairs(OFFICERS) do
            q('INSERT IGNORE INTO fredpd_officers (citizenid, discord_id, display_name, callsign, unit) VALUES (?, ?, ?, ?, ?)', r)
        end
        -- The registered tablets of the harness players.
        q("INSERT INTO fredpd_tablets (serial, owner_citizenid, issued_by, issued_at) VALUES "
            .. "('SP-AAAA-0001', 'MDT10001', 'MDT10002', '2026-09-28 08:00:00'), "
            .. "('SP-AAAA-0002', 'MDT10002', NULL, '2026-09-28 07:00:00')")
        -- Audit rows through fredpd_core's writer (actor = the player's citizenid, 0 = system).
        local Audit = require('server.audit')
        env.auditImpl = function(src, action, targetType, targetId, meta)
            local p = env.players[tonumber(src)]
            return Audit.write({ actorCitizenid = p and p.cid or nil, action = action, targetType = targetType,
                targetId = targetId, meta = meta })
        end
        env.players[9] = { cid = nil, duty = false, grants = {}, units = {}, items = {} } -- connected, no character
    end }, function(env, mods)
        fn(t, env, mods)
    end)
    shim.sessionTimeZone = nil
    shim.database, shim.resourceName = savedDatabase, savedResource
    if not okRun then error(err, 0) end
end

local function auditRows(action)
    return q("SELECT actor_citizenid, target_type, target_id, meta FROM fredpd_audit WHERE action = ? ORDER BY id",
        { action })
end

tests['1 issue: row, item metadata, audit, notification; the tablet then opens'] = function(t)
    withDb(t, function(_, env, mods)
        local Tablets, Open = mods['server.tablets'], mods['server.open']
        local ok, key, vars, serial = Tablets.issue(2, 5)
        t.eq(ok, true, tostring(key))
        t.eq(key, 'tablet.issued')
        t.ok(serial:find(SERIAL), 'serial format ' .. serial)
        t.eq(vars, { serial = serial, name = 'Cia D.' })
        t.eq(require('shared.locale').L(key, vars), ('Surfplatta %s är registrerad på Cia D..'):format(serial),
            'sv text (the name keeps its own dot)')

        local row = q('SELECT owner_citizenid, issued_by, revoked, revoked_by, '
            .. 'TIMESTAMPDIFF(SECOND, issued_at, UTC_TIMESTAMP()) AS age FROM fredpd_tablets WHERE serial = ?', { serial })[1]
        t.eq(row.owner_citizenid, 'MDT10005')
        t.eq(row.issued_by, 'MDT10002')
        t.eq(row.revoked, 0)
        t.ok(row.age >= 0 and row.age < 60, 'issued_at is UTC (session +02:00): age ' .. tostring(row.age))

        local add = env.callsTo('ox_inventory', 'AddItem')[1]
        t.eq(add.src, 5)
        t.eq(add.input, { item = 'pd_tablet', count = 1,
            metadata = { serial = serial, owner = 'MDT10005', description = 'Serienummer: ' .. serial } })

        local audits = auditRows('tablet.issue')
        t.eq(#audits, 1)
        t.eq(audits[1].actor_citizenid, 'MDT10002')
        t.eq(audits[1].target_type, 'tablet')
        t.eq(audits[1].target_id, serial)
        t.eq(json.decode(audits[1].meta), { owner = 'MDT10005', target = 5 })

        local note = env.sent(5, 'ox_lib:notify')[1]
        t.eq(note.args[1], { type = 'success', description = ('Du har fått surfplatta %s.'):format(serial) })

        -- End to end: player 5 now opens with that tablet (real row lookup).
        local res = Open.open(5, { mode = 'item', slot = env.players[5].items[1].slot })
        t.eq(res.error, nil, helper.dump(res))
        t.eq(Open.session(5).serial, serial)
    end)
end

tests['2 issue refusals: unknown target, no character, cannot carry, AddItem failure rolls back'] = function(t)
    withDb(t, function(_, env, mods)
        local Tablets = mods['server.tablets']
        t.eq({ Tablets.issue(2, 77) }, { false, 'errors.notFound' })
        t.eq({ Tablets.issue(2, 0) }, { false, 'errors.notFound' })
        t.eq({ Tablets.issue(2, 'abc') }, { false, 'errors.notFound' })
        t.eq({ Tablets.issue(2, 9) }, { false, 'tablet.issueNoCharacter' })
        env.players[5].full = true
        t.eq({ Tablets.issue(2, 5) }, { false, 'tablet.issueCannotCarry' })
        env.players[5].full = nil
        env.addItemFails = true
        t.eq({ Tablets.issue(2, 5) }, { false, 'tablet.issueFailed' })
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_tablets WHERE owner_citizenid = 'MDT10005'"), 0, 'row removed again')
        t.eq(#auditRows('tablet.issue'), 0, 'nothing audited')
        for _, key in ipairs({ 'tablet.issueNoCharacter', 'tablet.issueCannotCarry', 'tablet.issueFailed' }) do
            t.ok(H.SV[key], key .. ' has a Swedish text')
        end
    end)
end

tests['3 issue: serial collisions are retried; five in a row give up'] = function(t)
    withDb(t, function(env_, env, mods)
        local Tablets = mods['server.tablets']
        local original = Tablets.newSerial
        local queue = { 'SP-AAAA-0001', 'SP-AAAA-0002', 'SP-BBBB-2222' }
        Tablets.newSerial = function() return table.remove(queue, 1) end
        local ok, _, _, serial = Tablets.issue(2, 5)
        t.eq(ok, true)
        t.eq(serial, 'SP-BBBB-2222', 'two taken serials skipped')
        t.eq(scalar("SELECT owner_citizenid FROM fredpd_tablets WHERE serial = 'SP-AAAA-0001'"), 'MDT10001',
            'an existing tablet is never overwritten')
        Tablets.newSerial = function() return 'SP-AAAA-0001' end
        t.eq({ Tablets.issue(2, 5) }, { false, 'tablet.issueFailed' })
        t.eq(#env.callsTo('ox_inventory', 'AddItem'), 1, 'no item for the failed attempt')
        Tablets.newSerial = original
        -- The generator itself: prefix, groups, alphabet without I, O, 0, 1.
        for _ = 1, 200 do t.ok(Tablets.newSerial():find(SERIAL), 'format') end
        local seen = {}
        for _ = 1, 200 do seen[Tablets.newSerial()] = true end
        local n = 0
        for _ in pairs(seen) do n = n + 1 end
        t.ok(n > 195, 'serials vary')
    end)
end

tests['4 console issue: no issued_by, system audit actor'] = function(t)
    withDb(t, function(_, _, mods)
        local ok, _, _, serial = mods['server.tablets'].issue(0, 1)
        t.eq(ok, true)
        t.eq(scalar('SELECT issued_by FROM fredpd_tablets WHERE serial = ?', { serial }), nil)
        t.eq(auditRows('tablet.issue')[1].actor_citizenid, nil)
    end)
end

tests['5 /surfplatta: perm tablets.manage via fredpd_core, rate limited; console allowed'] = function(t)
    withDb(t, function(_, env)
        H.run('server/main.lua')
        local cmd = env.commands.surfplatta
        t.ok(cmd, 'command registered')
        t.eq(cmd.def.restricted, nil, 'not an ACE command: the grant decides')
        t.eq(cmd.def.params[1].type, 'playerId')
        t.eq(cmd.def.help, 'Registrera surfplatta')
        cmd.fn(1, { target = 5 }) -- IGV without tablets.manage
        t.eq(env.sent(1, 'ox_lib:notify')[1].args[1],
            { type = 'error', description = 'Du har inte behörighet att göra det här.' })
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_tablets WHERE owner_citizenid = 'MDT10005'"), 0)
        cmd.fn(2, { target = 5 })
        t.eq(env.sent(2, 'ox_lib:notify')[1].args[1].type, 'success')
        t.ok(env.sent(2, 'ox_lib:notify')[1].args[1].description:find('^Surfplatta SP%-.+ är registrerad på Cia D%.%.$'))
        cmd.fn(2, { target = 5 })
        t.eq(env.sent(2, 'ox_lib:notify')[2].args[1],
            { type = 'error', description = 'För många förfrågningar. Vänta en stund och försök igen.' })
        t.eq(scalar("SELECT COUNT(*) FROM fredpd_tablets WHERE owner_citizenid = 'MDT10005'"), 1)
        -- Console: printed, no grant needed.
        local printed = {}
        local savedPrint = print
        print = function(s) printed[#printed + 1] = s end -- luacheck: ignore
        local okCall, err = pcall(cmd.fn, 0, { target = 1 })
        print = savedPrint -- luacheck: ignore
        if not okCall then error(err, 0) end
        t.ok(printed[1] and printed[1]:find('är registrerad på Anna B%.'), tostring(printed[1]))
    end)
end

tests['6 listTablets: TabletListOutput with owners, OfficerRef issuers, ISO UTC, pages of 50'] = function(t)
    withDb(t, function(_, env, mods)
        local D = mods['server.dispatch']
        H.openTablet(mods, 2)
        local res = D.handle(2, { action = 'listTablets', input = {} })
        t.eq(res.total, 2)
        t.eq(res.page, 1)
        t.eq(res.items[1], {
            serial = 'SP-AAAA-0001', revoked = false, issuedAt = '2026-09-28T08:00:00Z',
            owner = { citizenid = 'MDT10001', name = 'Anna B.' },
            issuedBy = { citizenid = 'MDT10002', displayName = 'Eva L.', callsign = 'LED-01', unit = 'ledning' },
        })
        t.eq(res.items[2].issuedBy, nil, 'console-issued: no issuer')
        t.eq(res.items[2].issuedAt, '2026-09-28T07:00:00Z', 'UTC as stored, whatever the session zone')
        H.writeGolden('tablets.list', res)
        -- An owner without an officer row shows the citizenid, never a character name.
        q("INSERT INTO fredpd_tablets (serial, owner_citizenid, issued_at) VALUES ('SP-CIV0-0001', 'CIV40004', "
            .. "'2026-09-29 06:00:00')")
        -- 55 more rows: page 2 holds the oldest 8 (50 per page).
        local values = {}
        for i = 1, 55 do
            values[i] = ("('SP-PAGE-%04d', 'MDT10001', '2026-01-01 00:%02d:00')"):format(i, i)
        end
        q('INSERT INTO fredpd_tablets (serial, owner_citizenid, issued_at) VALUES ' .. table.concat(values, ', '))
        env.now = env.now + 1000
        local first = D.handle(2, { action = 'listTablets', input = {} })
        t.eq(first.total, 58)
        t.eq(#first.items, 50)
        t.eq(first.items[1].serial, 'SP-CIV0-0001')
        t.eq(first.items[1].owner, { citizenid = 'CIV40004', name = 'CIV40004' })
        env.now = env.now + 1000
        local second = D.handle(2, { action = 'listTablets', input = { page = 2 } })
        t.eq(#second.items, 8)
        t.eq(second.page, 2)
        t.eq(second.items[8].serial, 'SP-PAGE-0001')
        for _, item in ipairs(second.items) do t.ok(item.issuedAt:find(ISO), item.issuedAt) end
        env.now = env.now + 1000
        t.eq(D.handle(2, { action = 'listTablets', input = { page = 9 } }).items, {})
        -- Needs perm tablets.manage.
        H.openTablet(mods, 1)
        t.eq(D.handle(1, { action = 'listTablets', input = {} }), { error = 'unauthorized' })
    end)
end

tests['7 setTabletRevoked: audit, force-close of the open tablet, refused afterwards; reinstate'] = function(t)
    withDb(t, function(_, env, mods)
        local D, Open = mods['server.dispatch'], mods['server.open']
        H.openTablet(mods, 1) -- uses SP-AAAA-0001
        H.openTablet(mods, 2)
        env.client = {}
        local res = D.handle(2, { action = 'setTabletRevoked', input = { serial = 'SP-AAAA-0001', revoked = true } })
        t.eq(res.revoked, true)
        t.eq(res.serial, 'SP-AAAA-0001')
        H.writeGolden('tablet.revoked', res)
        local row = q('SELECT revoked, revoked_by, TIMESTAMPDIFF(SECOND, revoked_at, UTC_TIMESTAMP()) AS age '
            .. "FROM fredpd_tablets WHERE serial = 'SP-AAAA-0001'")[1]
        t.eq(row.revoked, 1)
        t.eq(row.revoked_by, 'MDT10002')
        t.ok(row.age >= 0 and row.age < 60, 'revoked_at UTC')
        local audits = auditRows('tablet.revoke')
        t.eq(#audits, 1)
        t.eq(audits[1].actor_citizenid, 'MDT10002')
        t.eq(audits[1].target_id, 'SP-AAAA-0001')
        t.eq(json.decode(audits[1].meta), { owner = 'MDT10001' })
        -- The holder's tablet closed at once, with the Swedish reason on the client.
        t.eq(Open.isOpen(1), false)
        t.eq(env.sent(1, 'fredpd:client:forceClose')[1].args, { 'tablet.revoked' })
        t.eq(Open.isOpen(2), true, 'the revoker keeps theirs')
        env.now = env.now + 1000
        t.eq(Open.open(1, { mode = 'item' }), { error = 'tablet.revoked' })
        -- Revoking again: no second audit row.
        env.now = env.now + 3000
        D.handle(2, { action = 'setTabletRevoked', input = { serial = 'SP-AAAA-0001', revoked = true } })
        t.eq(#auditRows('tablet.revoke'), 1)
        -- Reinstate.
        env.now = env.now + 3000
        res = D.handle(2, { action = 'setTabletRevoked', input = { serial = 'SP-AAAA-0001', revoked = false } })
        t.eq(res.revoked, false)
        t.eq(q("SELECT revoked, revoked_by, revoked_at FROM fredpd_tablets WHERE serial = 'SP-AAAA-0001'")[1],
            { revoked = 0 })
        t.eq(#auditRows('tablet.reinstate'), 1)
        env.now = env.now + 1000
        H.openTablet(mods, 1)
        -- Unknown serial.
        env.now = env.now + 3000
        t.eq(D.handle(2, { action = 'setTabletRevoked', input = { serial = 'SP-NONE-0000', revoked = true } }),
            { error = 'not_found' }, helper.dump(env.logs))
    end)
end

return tests
