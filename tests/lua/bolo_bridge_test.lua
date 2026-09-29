-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_bolo on fredpd_core's §C17 bridge (docs/modules/bolo.md "Framework bridge"):
--  * static: no qb-core/qbx_core/ox_*/qb-* name outside comments in the resource's Lua, fxmanifest dependencies are
--    only ox_lib, oxmysql, fredpd_core, and '@fredpd_core/bridge/client.lua' is the first client script;
--  * smoke matrix: selected main-suite tests re-run on BOTH stacks (qb = qb-core + qb-target, ox = qbx_core +
--    ox_target) through the real fredpd_core bridge (server) and bridge/client.lua (client). The full suites run on
--    one stack each: `lua5.4 tests/lua/run.lua bolo_` (qb) and `FREDPD_STACK=ox lua5.4 tests/lua/run.lua bolo_`.
local Stack = require('dispatch_stack_test')
local Client = require('bolo_client_test')
local Server = require('bolo_server_test')

local ROOT = './resources/[fredpd]/fredpd_bolo/'

local tests = {}

tests['static: no direct framework/inventory/target/doorlock access; manifest on the bridge'] = function(t)
    local files = { 'client/main.lua', 'server/main.lua', 'server/service.lua', 'server/fanout.lua',
        'server/cache.lua', 'server/store.lua', 'server/visibility.lua', 'shared/input.lua', 'shared/view.lua',
        'fxmanifest.lua' }
    for _, file in ipairs(files) do
        local src = Stack.code(ROOT .. file)
        for _, pattern in ipairs(Stack.BANNED) do
            t.eq(src:find(pattern), nil, ('%s uses %s outside comments'):format(file, pattern))
        end
    end
    local manifest = Stack.code(ROOT .. 'fxmanifest.lua')
    t.eq(Stack.manifestList(manifest, 'dependencies'), { 'ox_lib', 'oxmysql', 'fredpd_core' })
    t.eq(Stack.manifestList(manifest, 'client_scripts'), { '@fredpd_core/bridge/client.lua', 'client/main.lua' })
end

local CLIENT_SMOKE = {
    'option: added once at start, Swedish label, whole vehicle, 3 m; police on duty only',
    'check: only the network id goes to the server; hit menu first, red, sound; clear without sound',
    'lifecycle: removed on stop, re-added when the target resource restarts',
}
local SERVER_SMOKE = {
    '02 createBolo (vehicle): row, Bolo shape, cache, audit, push, server event, UTC',
    '14 targetCheck: plate read from the entity, grant/duty/1 s/entity/distance checks',
    '16 resolveOnImpound: resolves with the Swedish note, audits via impound, never raises',
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
