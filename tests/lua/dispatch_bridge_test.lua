-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_dispatch on fredpd_core's §C17 bridge (docs/modules/dispatch.md "Framework bridge"):
--  * static: no qb-core/qbx_core/ox_*/qb-* name outside comments in the resource's Lua (ps-dispatch is not a
--    framework: its client export Shooting() stays), fxmanifest dependencies only ox_lib, oxmysql, fredpd_core;
--  * smoke matrix: selected dispatch_server_test.lua tests re-run on BOTH stacks (qb-core / qbx_core) through the
--    real fredpd_core bridge: getPlayers for toasts and the roster, the framework's SetDuty -> fredpd:bridge:dutyChanged
--    -> roster rebuild, the audit actor. The full suites run on one stack each: `lua5.4 tests/lua/run.lua dispatch_`
--    (qb) and `FREDPD_STACK=ox lua5.4 tests/lua/run.lua dispatch_`;
--  * ps-dispatch on qb-core: the pinned ps-dispatch (deps.lock.json) with patches/ps-dispatch.*.patch applied in a
--    temporary copy; its server/main.lua runs with qb-core's GetCoreObject available (the branch a qb-core server
--    takes, ps-dispatch server/main.lua:6-7, 155-169) and a stored call fires fredpd:dispatch:incoming(data, src),
--    which shared/alert_input.lua turns into a valid createAlert input. Skipped with a notice when the upstream
--    checkout is missing (fails with FREDPD_REQUIRE_UPSTREAM=1).
local helper = require('helper')
local Stack = require('dispatch_stack_test')
local Server = require('dispatch_server_test')

local ROOT = './resources/[fredpd]/fredpd_dispatch/'
local UPSTREAM = './resources/[upstream]/ps-dispatch'

local tests = {}

tests['static: no direct framework/inventory/target/doorlock access; manifest on the bridge'] = function(t)
    local files = { 'client/main.lua', 'server/main.lua', 'server/alert_service.lua', 'server/alert_store.lua',
        'server/fanout.lua', 'server/ps_bridge.lua', 'server/unit_roster.lua', 'shared/alert_input.lua',
        'fxmanifest.lua' }
    for _, file in ipairs(files) do
        local src = Stack.code(ROOT .. file)
        for _, pattern in ipairs(Stack.BANNED) do
            t.eq(src:find(pattern), nil, ('%s uses %s outside comments'):format(file, pattern))
        end
        t.eq(src:find('GetPlayers%(%)'), nil, file .. ': player lists come from fredpd_core getPlayers')
    end
    local manifest = Stack.code(ROOT .. 'fxmanifest.lua')
    t.eq(Stack.manifestList(manifest, 'dependencies'), { 'ox_lib', 'oxmysql', 'fredpd_core' })
end

local SERVER_SMOKE = {
    '05 createAlert: round trip shape, UTC time, toast only to on-duty officers with the grant',
    '08 assignSelf: open -> assigned, second officer joins, repeat is idempotent, audited',
    '15 units: on-duty roster with current alert, debounced to one push per 2 s',
    '16 main: exports, server-only events and the roster triggers are registered',
}

for _, stack in ipairs(Stack.STACKS) do
    for _, name in ipairs(SERVER_SMOKE) do
        tests[('%s smoke (server): %s'):format(stack, name)] = function(t)
            assert(Server[name], 'no server test ' .. name)
            Stack.on(stack, Server[name], t)
        end
    end
end

---------------------------------------------------------------------------------------------------------------
-- ps-dispatch (qb-core branch) -> fredpd:dispatch:incoming

local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function run(cmd)
    local p = io.popen(cmd .. ' 2>&1')
    local out = p:read('a')
    local ok = p:close()
    return ok == true, out
end

local TREE_KEY = '__fredpd_psdispatch_tree'

--- { ok, reason, files = { [path] = content } } of the pinned ps-dispatch with its FredPD patches applied.
local function tree()
    if package.loaded[TREE_KEY] then return package.loaded[TREE_KEY] end
    local tr = { ok = false, files = {} }
    package.loaded[TREE_KEY] = tr
    local lock = helper.readJson('deps.lock.json').resources['ps-dispatch']
    if not run(('git -C %s cat-file -e %s^{commit}'):format(shq(UPSTREAM), lock.commit)) then
        tr.reason = ('%s does not have commit %s (run scripts/fetch-deps.sh)'):format(UPSTREAM, lock.commit:sub(1, 10))
        return tr
    end
    local dir = os.tmpname()
    os.remove(dir)
    run('mkdir -p ' .. shq(dir))
    local ok, out = run(('git -C %s archive %s | tar -x -C %s'):format(shq(UPSTREAM), lock.commit, shq(dir)))
    if ok then
        run(('git -C %s init -q'):format(shq(dir)))
        local cwd = io.popen('pwd'):read('l')
        local list = {}
        for name in io.popen('ls patches/ps-dispatch.*.patch'):lines() do list[#list + 1] = name end
        table.sort(list)
        for _, patch in ipairs(list) do
            local okApply, msg = run(('git -C %s apply %s'):format(shq(dir), shq(cwd .. '/' .. patch)))
            if not okApply then
                tr.applyError = ('%s does not apply: %s'):format(patch, msg)
                ok = false
                break
            end
        end
        if ok then
            for _, rel in ipairs({ 'server/main.lua', 'shared/config.lua' }) do
                local f = assert(io.open(dir .. '/' .. rel, 'rb'))
                tr.files[rel] = f:read('a')
                f:close()
            end
            tr.ok = true
        end
    else
        tr.reason = 'git archive failed: ' .. out
    end
    run('rm -rf ' .. shq(dir))
    return tr
end

local notified = false
local function withTree(t, fn)
    local tr = tree()
    if not tr.ok then
        if tr.applyError then error(tr.applyError, 0) end
        if os.getenv('FREDPD_REQUIRE_UPSTREAM') == '1' then error('FREDPD_REQUIRE_UPSTREAM=1 but ' .. tr.reason, 0) end
        if not notified then
            print('SKIP dispatch ps-dispatch check: ' .. tostring(tr.reason))
            notified = true
        end
        return
    end
    fn(t, tr)
end

--- Run the patched ps-dispatch server/main.lua (with shared/config.lua) in its own environment: qb-core exports
--- GetCoreObject (players = { [src] = job }), convars as given. Returns the environment's recorders.
local function psDispatch(tr, convars, players)
    local rec = { events = {}, client = {}, handlers = {}, threads = 0 }
    local function contains(list, v)
        for _, x in ipairs(list or {}) do if x == v then return true end end
        return false
    end
    local QBCore = { Functions = {
        -- qb-core server/functions.lua GetQBPlayers -> QBCore.Players (src -> Player).
        GetQBPlayers = function()
            local out = {}
            for src, job in pairs(players) do out[src] = { PlayerData = { source = src, job = job } } end
            return out
        end,
        GetPlayer = function(src)
            local job = players[src]
            return job and { PlayerData = { source = src, job = job } } or nil
        end,
    } }
    local env = setmetatable({
        Config = {},
        vector3 = function(x, y, z) return { x = x, y = y, z = z } end,
        exports = setmetatable({ ['qb-core'] = { GetCoreObject = function() rec.coreAsked = true return QBCore end } },
            { __call = function() end }),
        GetConvar = function(name, default) return convars[name] or default end,
        locale = function(key) return key end,
        lib = {
            callback = { register = function() end },
            addCommand = function(name) rec.commands = rec.commands or {}; rec.commands[name] = true end,
            table = { contains = contains },
        },
        RegisterServerEvent = function(name, fn) rec.handlers[name] = fn end,
        RegisterNetEvent = function(name, fn) rec.handlers[name] = fn end,
        AddEventHandler = function(name, fn) rec.handlers[name] = fn end,
        TriggerEvent = function(name, ...) rec.events[#rec.events + 1] = { name = name, args = { ... } } end,
        TriggerClientEvent = function(name, target, ...)
            rec.client[#rec.client + 1] = { name = name, target = target, args = { ... } }
        end,
        CreateThread = function() rec.threads = rec.threads + 1 end, -- the call sweep loop never runs here
        Wait = function() end,
    }, { __index = _G })
    for _, rel in ipairs({ 'shared/config.lua', 'server/main.lua' }) do
        local chunk = assert(load(tr.files[rel], '@ps-dispatch/' .. rel, 't', env))
        chunk()
    end
    --- Fire the net event ps-dispatch's client alerts send (client/alerts.lua: TriggerServerEvent).
    function rec.notify(src, data)
        env.source = src
        rec.handlers['ps-dispatch:server:notify'](data)
    end
    function rec.named(name)
        local out = {}
        for _, e in ipairs(rec.events) do if e.name == name then out[#out + 1] = e end end
        return out
    end
    return rec
end

--- A ps-dispatch Shooting() report as client/alerts.lua builds it.
local function shooting(x)
    return { message = 'Shots Fired', codeName = 'shooting', code = '10-11', icon = 'fas fa-gun', priority = 2,
        coords = { x = x or 215.5, y = -920.25, z = 30.75 }, street = 'Vespucci Blvd', gender = 'Male',
        weapon = 'Pistol', jobs = { 'leo' }, alertTime = nil }
end

tests['ps-dispatch (qb-core branch): the patches apply; a stored call fires fredpd:dispatch:incoming(data, src)'] = function(t)
    withTree(t, function(_, tr)
        local police = { name = 'police', type = 'leo', onduty = true }
        local rec = psDispatch(tr, {}, { [1] = police, [2] = { name = 'unemployed', type = 'none', onduty = true } })
        t.ok(rec.coreAsked, "ps-dispatch took qb-core's GetCoreObject (the qb-core branch)")
        rec.notify(7, shooting())
        local incoming = rec.named('fredpd:dispatch:incoming')
        t.eq(#incoming, 1)
        local data, reporter = incoming[1].args[1], incoming[1].args[2]
        t.eq(reporter, 7, 'the reporting player')
        t.eq(data.id, 1)
        t.eq(data.coords, { x = 215.5, y = -920.25, z = 30.75 }, 'true coords')
        t.eq(#rec.client, 0, 'ps-dispatch UI off by default: no popups for anyone')
        t.eq(rec.commands.dispatch, nil, '/dispatch not registered while the UI is off')

        -- what fredpd_dispatch's handler (server/ps_bridge.lua) makes of it
        package.loaded['shared.alert_input'] = nil
        local savedPath = package.path
        package.path = ROOT .. '?.lua;' .. package.path
        local Input = require('shared.alert_input')
        package.path = savedPath
        package.loaded['shared.alert_input'] = nil
        t.eq(Input.isPoliceCall(data), true)
        local input = Input.fromPsDispatch(data, function(k) return k end)
        t.ok(input, 'normalised')
        t.eq(input.code, '10-11')
        t.eq(input.source, 'ps-dispatch')

        -- a report merged into that call (same code, close by) is not a new call: nothing more is mirrored
        rec.notify(7, shooting(216.0))
        t.eq(#rec.named('fredpd:dispatch:incoming'), 1)
        rec.notify(7, { message = '', jobs = { 'leo' } })
        t.eq(#rec.named('fredpd:dispatch:incoming'), 1, 'invalid reports are dropped by ps-dispatch first')
    end)
end

tests['ps-dispatch (qb-core branch) with setr fredpd_psdispatch_ui true: job-filtered popups AND the mirror'] = function(t)
    withTree(t, function(_, tr)
        local rec = psDispatch(tr, { fredpd_psdispatch_ui = 'true' }, {
            [1] = { name = 'police', type = 'leo', onduty = true },
            [2] = { name = 'police', type = 'leo', onduty = false },
            [3] = { name = 'unemployed', type = 'none', onduty = true },
        })
        rec.notify(3, shooting())
        t.eq(#rec.named('fredpd:dispatch:incoming'), 1)
        local targets = {}
        for _, e in ipairs(rec.client) do
            if e.name == 'ps-dispatch:client:notify' then targets[#targets + 1] = e.target end
        end
        t.eq(targets, { 1 }, 'QBCore.Functions.GetQBPlayers filter: on-duty leo only')
        t.ok(rec.commands.dispatch, '/dispatch with the UI on')
    end)
end

return tests
