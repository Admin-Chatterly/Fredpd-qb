-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_mdt on fredpd_core's §C17 bridge (docs/modules/mdt.md "Bridge"), as a matrix over both stacks:
--   qb = qb-core + qb-inventory + qb-target, ox = qbx_core + ox_inventory + ox_target.
-- Static: no direct framework/inventory/target call and no such fxmanifest dependency in fredpd_mdt. Server: the
-- real server/bridge.lua over the stack's inventory mock (qb `info` vs ox `metadata` normalised; the tablet serial is
-- read from either), the tablet item use on both paths (qb: registerUsable -> qb-core usable item; ox: client.export
-- -> callback, and fredpd_core.useItem) ending in the same Open.open, bridge add() for issuing. Client: the terminal
-- through FredBridge.target and the job hint through FredBridge.framework.getJob on both stacks.
-- The full suites run on one stack each: `lua5.4 tests/lua/run.lua mdt_` (qb, default) and
-- `FREDPD_MDT_STACK=ox lua5.4 tests/lua/run.lua mdt_`.
local helper = require('helper')
local H = dofile('./resources/[fredpd]/fredpd_mdt/test/harness.lua')
local Client = require('mdt_client_test')

local ROOT = './resources/[fredpd]/fredpd_mdt/'
local STACKS = { 'qb', 'ox' }

local tests = {}

--- Lua source without comments (-- to end of line; FredPD code has no long strings containing '--').
local function code(path)
    local out = {}
    for line in helper.readFile(path):gmatch('[^\n]*') do
        out[#out + 1] = (line:gsub('%-%-.*$', ''))
    end
    return table.concat(out, '\n')
end

tests['static: no direct qb-core/qbx_core/ox_inventory/ox_target/qb-inventory/qb-target call or dependency'] = function(t)
    local files = { 'client/main.lua', 'server/main.lua', 'server/open.lua', 'server/home.lua', 'server/tablets.lua',
        'server/dispatch.lua', 'server/common.lua', 'shared/validate.lua', 'config.lua', 'fxmanifest.lua' }
    local banned = { 'ox_inventory', 'ox_target', 'ox_doorlock', 'qbx_core', 'qb%-core', 'qb%-inventory', 'qb%-target',
        'qb%-doorlock', 'QBCore', 'QBX', 'GetCoreObject', 'CanCarryItem' }
    for _, file in ipairs(files) do
        local src = code(ROOT .. file)
        for _, pattern in ipairs(banned) do
            t.eq(src:find(pattern), nil, ('%s uses %s outside comments'):format(file, pattern))
        end
    end
    local manifest = code(ROOT .. 'fxmanifest.lua')
    local deps = manifest:match('dependencies%s*(%b{})')
    local list = {}
    for name in deps:gmatch("'([^']+)'") do list[#list + 1] = name end
    t.eq(list, { 'ox_lib', 'oxmysql', 'fredpd_core' })
    local client = manifest:match('client_scripts%s*(%b{})')
    local scripts = {}
    for name in client:gmatch("'([^']+)'") do scripts[#scripts + 1] = name end
    t.eq(scripts, { '@fredpd_core/bridge/client.lua', 'client/main.lua' }, 'bridge client loaded first')
end

for _, stack in ipairs(STACKS) do
    tests[stack .. ': open reads the serial through the bridge find (qb info / ox metadata), used slot first'] = function(t)
        H.with({ stack = stack }, function(env, mods)
            local Open = mods['server.open']
            t.eq(env.Bridge.chosen('inventory'), stack == 'qb' and 'qb-inventory' or 'ox_inventory')
            table.insert(env.players[1].items, { slot = 9, name = 'pd_tablet', count = 1,
                metadata = { serial = 'SP-AAAA-0006' } })
            t.eq(Open.open(1, { mode = 'item', slot = 9 }), { error = 'tablet.revoked' }, 'the used (revoked) tablet')
            env.now = env.now + 1000
            H.openTablet(mods, 1, { mode = 'item' })
            t.eq(Open.session(1).serial, 'SP-AAAA-0001', 'first slot with a serial')
            Open.markClosed(1)
            env.now = env.now + 1000
            t.eq(Open.open(5, { mode = 'item' }), { error = 'tablet.noItem' })
            env.now = env.now + 1000
            env.resources[env.inventory] = 'stopped'
            t.eq(Open.open(1, { mode = 'item' }), { error = 'tablet.unavailable' })
            local warned = 0
            for _, l in ipairs(env.bridgeLogs) do
                if l.level == 'warn' and l.msg:find(env.inventory .. ' is stopped', 1, true) then warned = warned + 1 end
            end
            t.eq(warned, 1, 'the bridge warns once')
        end)
    end

    tests[stack .. ': issuing adds through the bridge; metadata lands in qb info / ox metadata; add false = not added'] = function(t)
        H.with({ stack = stack }, function(env, mods)
            local C = mods['server.common']
            t.eq(C.addItem(5, 'pd_tablet', 1, { serial = 'SP-CCCC-0005', owner = 'MDT10005' }), true)
            local add = env.callsTo('inventory', 'AddItem')[1]
            t.eq(add.impl, env.inventory)
            t.eq(add.input.metadata, { serial = 'SP-CCCC-0005', owner = 'MDT10005' })
            t.eq(C.findItems(5, 'pd_tablet')[1].metadata.serial, 'SP-CCCC-0005', 'read back normalised')
            t.eq(C.itemCount(5, 'pd_tablet'), 1)
            env.players[5].full = true
            t.eq(C.addItem(5, 'pd_tablet', 1, { serial = 'SP-CCCC-0006' }), false, 'no CanCarryItem: add answers false')
            t.eq(C.inventoryUp(), true)
            env.resources[env.inventory] = 'stopped'
            t.eq(C.inventoryUp(), false)
            t.eq(C.addItem(5, 'pd_tablet', 1, {}), false)
        end)
    end

    tests[stack .. ': tablet item use ends in the same server-validated Open.open on both paths'] = function(t)
        H.with({ stack = stack }, function(env, mods)
            H.run('server/main.lua')
            local Open = mods['server.open']
            if stack == 'qb' then
                -- fredpd_core registerUsable -> qb-core CreateUseableItem; qb-inventory calls it with its own slot item.
                local fn = env.usable.pd_tablet
                t.ok(fn, 'registered with qb-core through the bridge')
                fn(1, { name = 'pd_tablet', slot = 3, amount = 1, info = { serial = 'SP-AAAA-0001' } })
            else
                t.eq(env.usable.pd_tablet, nil, 'ox: nothing registered in the inventory (item definition decides)')
                -- ox_inventory's pd_tablet uses client.export -> the 'fredpd:mdt:open' callback ...
                local res = env.callbacks['fredpd:mdt:open'](1, { mode = 'item', slot = 3 })
                t.eq(res.error, nil, helper.dump(res))
                t.eq(Open.session(1).serial, 'SP-AAAA-0001')
                Open.markClosed(1)
                env.now = env.now + 1000
                -- ... and a server.export = 'fredpd_core.useItem' definition would reach the same flow.
                env.Bridge.useItem('usingItem', { name = 'pd_tablet' },
                    { id = 1, items = { [3] = { name = 'pd_tablet', metadata = { serial = 'SP-AAAA-0001' } } } }, 3)
            end
            local sent = env.sent(1, 'fredpd:client:openTablet')
            t.eq(#sent, 1)
            t.eq(sent[1].args[1].error, nil, helper.dump(sent[1].args[1]))
            t.eq(sent[1].args[1].me.citizenid, 'MDT10001')
            t.eq(Open.session(1).serial, 'SP-AAAA-0001')
            t.eq(Open.session(1).mode, 'item')
            -- A refusal travels the same way (off duty).
            env.now = env.now + 1000
            if stack == 'qb' then
                env.usable.pd_tablet(3, { name = 'pd_tablet', slot = 1, info = { serial = 'SP-AAAA-0003' } })
            else
                env.Bridge.useItem('usingItem', { name = 'pd_tablet' },
                    { id = 3, items = { [1] = { name = 'pd_tablet', metadata = { serial = 'SP-AAAA-0003' } } } }, 1)
            end
            t.eq(env.sent(3, 'fredpd:client:openTablet')[1].args[1], { error = 'tablet.notOnDuty' })
            t.eq(Open.isOpen(3), false)
        end)
    end

    tests[stack .. ': a tablet action is dispatched the same (validate + grant + route)'] = function(t)
        H.with({ stack = stack }, function(env, mods)
            H.openTablet(mods, 1)
            local res = mods['server.dispatch'].handle(1, { action = 'search', input = { query = 'Anna' } })
            t.eq(res, { routed = 'fredpd_records:search' })
            t.eq(mods['server.dispatch'].handle(1, { action = 'search', input = { query = 5 } }).error, 'validation')
        end)
    end

    tests[stack .. ': client terminal via FredBridge.target and duty hint via FredBridge.framework.getJob'] = function(t)
        Client.withClient(function(env, M)
            t.eq(env.FB.target.impl, stack == 'qb' and 'qb-target' or 'ox_target')
            t.eq(env.FB.framework.impl, stack == 'qb' and 'qb-core' or 'qbx_core')
            local option = Client.terminalOption(env)
            t.eq(option.label, 'Använd fordonsdatorn')
            cache.vehicle = 4242
            env.seats[-1] = 501
            t.eq(option.canInteract(4242), true)
            env.net['QBCore:Client:OnJobUpdate']({ name = 'ambulance', type = 'ems', onduty = true, grade = { level = 0 } })
            t.eq(option.canInteract(4242), false, 'not police')
            env.net['QBCore:Client:OnJobUpdate'](env.pd.job)
            option.select(4242)
            t.eq(env.calls[1].req, { mode = 'terminal' })
            t.eq(M.isOpen(), true)
        end, stack)
    end
end

return tests
