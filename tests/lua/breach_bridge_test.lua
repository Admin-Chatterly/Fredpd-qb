-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_breach on fredpd_core's §C17 bridge (docs/modules/breach.md "Framework bridge"):
--  * static: no qb-core/qbx_core/ox_*/qb-* name outside comments in the resource's Lua (evidences stays: it is used
--    only while fredpd_core's hasFeature('evidence') is on), fxmanifest dependencies only ox_lib and fredpd_core,
--    '@fredpd_core/bridge/client.lua' the first client script;
--  * smoke matrix: selected main-suite tests re-run on BOTH stacks (qb = qb-inventory + patched qb-doorlock +
--    qb-target, ox = ox_inventory + ox_doorlock + ox_target) through the real fredpd_core bridge (server) and
--    bridge/client.lua (client). The full suites run on one stack each: `lua5.4 tests/lua/run.lua breach_` (qb) and
--    `FREDPD_STACK=ox lua5.4 tests/lua/run.lua breach_`.
local Stack = require('dispatch_stack_test')
local Client = require('breach_client_test')
local Server = require('breach_server_test')

local ROOT = './resources/[fredpd]/fredpd_breach/'

local tests = {}

tests['static: no direct framework/inventory/target/doorlock access; manifest on the bridge'] = function(t)
    for _, file in ipairs({ 'client/main.lua', 'server/main.lua', 'server/breach.lua', 'server/scene.lua',
        'config.lua', 'config/scene_evidence.lua', 'fxmanifest.lua' }) do
        local src = Stack.code(ROOT .. file)
        for _, pattern in ipairs(Stack.BANNED) do
            t.eq(src:find(pattern), nil, ('%s uses %s outside comments'):format(file, pattern))
        end
        t.eq(src:find('Entity%('), nil, file .. ': no doorlock statebag (ox_doorlock-only)')
    end
    local manifest = Stack.code(ROOT .. 'fxmanifest.lua')
    t.eq(Stack.manifestList(manifest, 'dependencies'), { 'ox_lib', 'fredpd_core' })
    t.eq(Stack.manifestList(manifest, 'client_scripts'), { '@fredpd_core/bridge/client.lua', 'client/main.lua' })
end

local CLIENT_SMOKE = {
    'one zone per door with "Forcera dörr", added once at start for a grant holder',
    "door states follow the doorlock's client event (FredBridge.doorlock.onDoorChanged)",
    'breach flow: start → progress bar with prop and anim → finish → success',
    'character load (server event) re-reads grants and, after the delay, the door list; logout drops zones',
}
local SERVER_SMOKE = {
    'success: start → 4 s → finish unlocks through the bridge setLocked and audits breach.door',
    'a missing pd_ram item logs exactly one warning and nobody can breach',
    'start: no pd_ram → validation no_item',
    'start: door already unlocked → validation not_locked',
    'inventory or doorlock resource not running → unavailable (bridge fallbacks never read as no_item)',
    'qb-doorlock string door ids (Config.DoorList keys) breach, deny and audit like numbers',
}

for _, stack in ipairs(Stack.STACKS) do
    for _, name in ipairs(CLIENT_SMOKE) do
        tests[('%s smoke (client): %s'):format(stack, name)] = function(t)
            assert(Client[name], 'no client test ' .. name)
            Stack.on(stack, Client[name], t)
        end
    end
    for _, name in ipairs(SERVER_SMOKE) do
        tests[('%s smoke (server): %s'):format(stack, name)] = function(t)
            assert(Server[name], 'no server test ' .. name)
            Stack.on(stack, Server[name], t)
        end
    end
end

return tests
