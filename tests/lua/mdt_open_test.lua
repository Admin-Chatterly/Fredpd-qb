-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_mdt/server/open.lua: the open flow (item in the inventory, any mdt_page grant, on duty, serial registered
-- and not revoked, owner rule, vehicle terminal), each refusal as a locale key that has a Swedish text; the
-- MdtOpenPayload; sessions (close event, drop, forced closes on lost grants/duty); pushes only to open tablets
-- (duty, topic grant, filter). Mocks: fredpd_mdt/test/harness.lua (in-memory tablet rows).
-- Run: lua5.4 tests/lua/run.lua mdt_open
local helper = require('helper')
local H = dofile('./resources/[fredpd]/fredpd_mdt/test/harness.lua')

local tests = {}

local function refused(t, env, mods, src, req, key)
    local res = mods['server.open'].open(src, req or { mode = 'item' })
    t.eq(res, { error = key }, 'player ' .. src)
    t.ok(H.SV[key] and H.SV[key] ~= key and H.SV[key]:find('%a'), key .. ' has a Swedish text: ' .. tostring(H.SV[key]))
    t.eq(mods['server.open'].isOpen(src), false)
    env.now = env.now + 1000 -- past the open rate limit
end

tests['1 refusals: no item, no grant, off duty, unregistered, revoked -> locale key, nothing opens'] = function(t)
    H.with(function(env, mods)
        refused(t, env, mods, 5, nil, 'tablet.noItem')
        refused(t, env, mods, 4, nil, 'tablet.noGrant')      -- civilian holding a tablet
        refused(t, env, mods, 3, nil, 'tablet.notOnDuty')
        refused(t, env, mods, 6, nil, 'tablet.revoked')
        refused(t, env, mods, 7, nil, 'tablet.unregistered') -- tablet without serial (e.g. /giveitem)
        env.tablets['SP-AAAA-0001'] = nil
        refused(t, env, mods, 1, nil, 'tablet.unregistered') -- serial not in fredpd_tablets
        t.eq(#env.sent(nil, 'fredpd:client:forceClose'), 0)
        t.eq(mods['server.open'].openSources(), {})
    end)
end

tests['2 refusal order: grant before duty; cheap checks before the database'] = function(t)
    H.with(function(env, mods)
        env.players[4].duty = false
        refused(t, env, mods, 4, nil, 'tablet.noGrant')
        env.players[5].duty = false
        refused(t, env, mods, 5, nil, 'tablet.noItem')
        t.eq(#env.queries, 0, 'no DB query for refusals before the serial check')
        env.players[3].duty = true
        env.tablets['SP-AAAA-0003'].revoked = true -- oxmysql returns TINYINT(1) as a boolean
        refused(t, env, mods, 3, nil, 'tablet.revoked')
        t.eq(#env.queries, 1)
    end)
end

tests['3 success: MdtOpenPayload (grants copy, primary unit, me) and the session'] = function(t)
    H.with(function(env, mods)
        local Open = mods['server.open']
        local res = Open.open(2, { mode = 'item', slot = 1 })
        t.eq(res.unit, 'ledning', 'first unit in units.json order (fredpd_core orders them)')
        t.eq(res.me, { citizenid = 'MDT10002', displayName = 'Eva L.', callsign = 'LED-01' })
        t.eq(res.grants.tier, 2)
        t.ok(#res.grants.grants >= 5 and res.grants.denied, 'grant set copy')
        t.eq(res.error, nil)
        t.eq(Open.isOpen(2), true)
        t.eq(Open.session(2).serial, 'SP-AAAA-0002')
        t.eq(Open.session(2).mode, 'item')
        t.eq(Open.isOpen('2'), true, 'string ids work')
        helper.eq(Open.isOpen(nil), false)
        H.writeGolden('open.payload', res)
    end)
end

tests['4 serial: the reported slot is used when it holds a pd_tablet, else the first tablet slot'] = function(t)
    H.with(function(env, mods)
        local Open = mods['server.open']
        -- Player 1 holds two tablets: slot 3 (registered) and slot 9 (revoked).
        table.insert(env.players[1].items, { slot = 9, name = 'pd_tablet', count = 1, metadata = { serial = 'SP-AAAA-0006' } })
        t.eq(Open.open(1, { mode = 'item', slot = 9 }), { error = 'tablet.revoked' }, 'the used tablet is revoked')
        env.now = env.now + 1000
        H.openTablet(mods, 1, { mode = 'item', slot = 3 })
        t.eq(Open.session(1).serial, 'SP-AAAA-0001')
        Open.markClosed(1)
        env.now = env.now + 1000
        -- A slot that is not a tablet (or no slot at all) -> the first tablet slot.
        table.insert(env.players[1].items, { slot = 12, name = 'water', count = 1, metadata = { serial = 'SP-FAKE' } })
        H.openTablet(mods, 1, { mode = 'item', slot = 12 })
        t.eq(Open.session(1).serial, 'SP-AAAA-0001')
        Open.markClosed(1)
        env.now = env.now + 1000
        H.openTablet(mods, 1, { mode = 'item', slot = 'x' })
        t.eq(Open.session(1).serial, 'SP-AAAA-0001')
    end)
end

tests['5 requireOwner: another character\'s tablet is refused only when configured'] = function(t)
    H.with(function(env, mods)
        local Open = mods['server.open']
        -- Tablet SP-AAAA-0004 is registered to MDT10001; give it to player 5.
        env.players[5].items = { { slot = 1, name = 'pd_tablet', count = 1, metadata = { serial = 'SP-AAAA-0004' } } }
        H.openTablet(mods, 5)
        Open.markClosed(5)
        env.now = env.now + 1000
        mods.config.requireOwner = true
        t.eq(Open.open(5, { mode = 'item' }), { error = 'tablet.notOwner' })
        t.ok(H.SV['tablet.notOwner'], 'Swedish text')
    end)
end

tests['6 failures of ox_inventory, the database or fredpd_core fail closed'] = function(t)
    H.with(function(env, mods)
        local Open = mods['server.open']
        env.inventoryDown = true
        t.eq(Open.open(1, { mode = 'item' }), { error = 'tablet.unavailable' })
        env.inventoryDown, env.now = false, env.now + 1000
        env.dbDown = true
        t.eq(Open.open(1, { mode = 'item' }), { error = 'tablet.unavailable' })
        env.dbDown, env.now = false, env.now + 1000
        env.coreDown = true
        t.eq(Open.open(1, { mode = 'item' }), { error = 'tablet.noGrant' })
        env.coreDown, env.now = false, env.now + 1000
        t.eq(Open.isOpen(1), false)
        H.openTablet(mods, 1)
    end)
end

tests['7 open is rate limited per player (750 ms)'] = function(t)
    H.with(function(env, mods)
        local Open = mods['server.open']
        H.openTablet(mods, 1)
        Open.markClosed(1)
        t.eq(Open.open(1, { mode = 'item' }), { error = 'errors.rateLimited' })
        H.openTablet(mods, 2)
        env.now = env.now + 750
        H.openTablet(mods, 1)
    end)
end

tests['8 vehicle terminal: seated in a listed police model (driver/front), no item needed'] = function(t)
    H.with(function(env, mods)
        local Open = mods['server.open']
        t.eq(Open.open(5, { mode = 'terminal' }), { error = 'tablet.unavailable' }, 'not in a vehicle')
        env.now = env.now + 1000
        env.seat(5, 7001, 'police3', 1) -- back seat
        t.eq(Open.open(5, { mode = 'terminal' }), { error = 'tablet.unavailable' }, 'back seat')
        env.now = env.now + 1000
        env.vehicles = {}
        env.seat(5, 7002, 'sultan', -1)
        t.eq(Open.open(5, { mode = 'terminal' }), { error = 'tablet.unavailable' }, 'not a police model')
        env.now = env.now + 1000
        env.vehicles = {}
        env.seat(5, 7003, 'police3', 0)
        local res = H.openTablet(mods, 5, { mode = 'terminal' })
        t.eq(res.unit, 'span')
        t.eq(Open.session(5).mode, 'terminal')
        t.eq(Open.session(5).serial, nil)
        -- Grant and duty still apply in the terminal.
        env.seat(3, 7003, 'police3', -1)
        t.eq(Open.open(3, { mode = 'terminal' }), { error = 'tablet.notOnDuty' })
        -- requireItem: the terminal then also needs a registered tablet.
        Open.markClosed(5)
        env.now = env.now + 1000
        mods.config.terminal.requireItem = true
        t.eq(Open.open(5, { mode = 'terminal' }), { error = 'tablet.noItem' })
        env.now = env.now + 1000
        mods.config.terminal.enabled = false
        t.eq(Open.open(5, { mode = 'terminal' }), { error = 'tablet.unavailable' }, 'terminal disabled')
    end)
end

tests['8b terminal models: signed and unsigned hashes of the same model match'] = function(t)
    H.with(function(env, mods)
        joaat = function(name) return name == 'police3' and -100 or 12345 end -- luacheck: ignore (restored by H.with)
        env.vehicles[7003] = { model = (-100) & 0xFFFFFFFF, seats = { [-1] = 1005 } }
        H.openTablet(mods, 5, { mode = 'terminal' })
    end)
end

tests['9 me: no officer row -> neutral placeholder (never the character name); bad unit -> none'] = function(t)
    H.with(function(env, mods)
        local Open = mods['server.open']
        env.players[7].items[1].metadata.serial = 'SP-AAAA-0007'
        env.tablets['SP-AAAA-0007'] = { revoked = 0, owner_citizenid = 'MDT10007' }
        local res = H.openTablet(mods, 7)
        t.eq(res.me, { citizenid = 'MDT10007', displayName = 'Polis utan namn (…1007)' })
        t.eq(res.unit, 'tekniker')
        Open.markClosed(7)
        env.now = env.now + 1000
        env.players[7].units = { 'bad unit!' }
        t.eq(H.openTablet(mods, 7).unit, nil)
    end)
end

tests['10 sessions: close only clears its own; drop clears session and limits; forced closes'] = function(t)
    H.with(function(env, mods)
        local Open = mods['server.open']
        H.openTablet(mods, 1)
        H.openTablet(mods, 2)
        t.eq(Open.markClosed(1), true)
        t.eq(Open.markClosed(1), false)
        t.eq(Open.isOpen(2), true)
        Open.onDropped(2)
        t.eq(Open.isOpen(2), false)
        H.openTablet(mods, 2) -- limiter forgotten on drop: no rate limit right after
        -- Lost grants: still one mdt_page -> stays open; none -> forced closed with the reason.
        env.players[2].grants = { ['mdt_page:bolos'] = true }
        Open.onGrantsChanged(2)
        t.eq(Open.isOpen(2), true)
        env.players[2].grants = { ['perm:tablets.manage'] = true }
        Open.onGrantsChanged(2)
        t.eq(Open.isOpen(2), false)
        t.eq(env.sent(2, 'fredpd:client:forceClose')[1].args, { 'tablet.noGrant' })
        -- Duty off -> closed.
        env.now = env.now + 1000
        H.openTablet(mods, 1)
        Open.onDutyChanged(1)
        t.eq(Open.isOpen(1), true, 'still on duty')
        env.players[1].duty = false
        Open.onDutyChanged(1)
        t.eq(Open.isOpen(1), false)
        t.eq(env.sent(1, 'fredpd:client:forceClose')[1].args, { 'tablet.notOnDuty' })
        -- closeBySerial reaches every open tablet with that serial only.
        env.players[1].duty = true
        env.now = env.now + 1000
        H.openTablet(mods, 1)
        env.players[5].items = { { slot = 1, name = 'pd_tablet', count = 1, metadata = { serial = 'SP-AAAA-0001' } } }
        H.openTablet(mods, 5)
        env.players[2].grants = { ['mdt_page:*'] = true }
        env.now = env.now + 1000
        H.openTablet(mods, 2)
        t.eq(Open.closeBySerial('SP-AAAA-0001', 'tablet.revoked'), 2)
        t.eq(Open.openSources(), { 2 })
    end)
end

tests['11 main.lua events: grants/duty/job changes close, client-fired copies are ignored'] = function(t)
    H.with(function(env, mods)
        H.run('server/main.lua')
        local open = env.callbacks['fredpd:mdt:open']
        open(1, { mode = 'item' })
        env.players[1].grants = {}
        env.fire('fredpd:grantsChanged', 12, 1) -- as if a client managed to trigger it: ignored
        t.eq(env.exported.isTabletOpen(1), true)
        env.fire('fredpd:grantsChanged', '', 1)
        t.eq(env.exported.isTabletOpen(1), false)
        env.players[1].grants = { ['mdt_page:search'] = true }
        env.now = env.now + 1000
        open(1, { mode = 'item' })
        env.fire('QBCore:Server:SetDuty', '', 1, true)
        t.eq(env.exported.isTabletOpen(1), true)
        env.players[1].duty = false
        env.fire('QBCore:Server:SetDuty', '', 1, false)
        t.eq(env.exported.isTabletOpen(1), false)
        env.players[1].duty = true
        env.now = env.now + 1000
        open(1, { mode = 'item' })
        env.players[1].duty = false
        env.fire('QBCore:Server:OnJobUpdate', '', 1, { name = 'unemployed' })
        t.eq(env.exported.isTabletOpen(1), false)
        env.players[1].duty = true
        env.now = env.now + 1000
        open(1, { mode = 'item' })
        env.fire('QBCore:Server:OnPlayerUnload', '', 1)
        t.eq(env.exported.isTabletOpen(1), false, 'logout')
    end)
end

tests['12 pushes: only open tablets, on duty, with the topic grant and the filter; grants never broadcast'] = function(t)
    H.with(function(env, mods)
        local Open = mods['server.open']
        H.openTablet(mods, 1)
        H.openTablet(mods, 2)
        env.players[5].items = { { slot = 1, name = 'pd_tablet', count = 1, metadata = { serial = 'SP-AAAA-0004' } } }
        H.openTablet(mods, 5)
        env.players[5].grants['mdt_page:alerts'] = nil -- player 5 lost the alerts page
        -- 3 is on duty only in this test's second half; 6 never opened.
        env.client = {}
        t.eq(Open.pushToOpenTablets('bolo', { type = 'created', id = 4 }), 3)
        local got = {}
        for _, e in ipairs(env.sent(nil, 'fredpd:client:push')) do got[#got + 1] = e.src end
        t.eq(got, { 1, 2, 5 })
        t.eq(env.sent(1, 'fredpd:client:push')[1].args, { 'bolo', { type = 'created', id = 4 } })

        env.client = {}
        t.eq(Open.pushToOpenTablets('alerts', { type = 'closed', id = 9 }), 2, 'alerts need mdt_page:alerts')
        t.eq(#env.sent(5, 'fredpd:client:push'), 0)

        env.client = {}
        env.players[2].duty = false
        t.eq(Open.pushToOpenTablets('units', { units = {} }), 1, 'off duty holders get no live pushes')
        env.players[2].duty = true

        env.client = {}
        t.eq(Open.pushToOpenTablets('case', { type = 'evidenceLinked', caseId = 1, evidenceId = 2 },
            function(src) return src == 2 end), 1, 'filter')
        t.eq(Open.pushToOpenTablets('case', {}, function() error('bad filter', 0) end), 0, 'a raising filter excludes')
        t.eq(Open.pushToOpenTablets('case', {}, function() return 1 end), 0, 'only true passes')
        t.eq(Open.pushToOpenTablets('grants', {}), 0, 'grants is per player')
        t.eq(Open.pushToOpenTablets('nope', {}), 0)
        t.eq(Open.pushToOpenTablets(nil, {}), 0)

        env.client = {}
        t.eq(Open.pushTo(1, 'grants', { grants = {} }), true)
        t.eq(Open.pushTo(6, 'bolo', {}), false, 'not open')
        t.eq(Open.pushTo(1, 'nope', {}), false)
        t.eq(#env.sent(nil, 'fredpd:client:push'), 1)
    end)
end

return tests
