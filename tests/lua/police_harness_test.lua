-- SPDX-License-Identifier: GPL-3.0-only
-- qbx_police (resource qbx_policejob) patches: shared harness + patch checks (docs/modules/police.md).
--
-- Used two ways:
--  * `require('police_harness_test')` from the other tests/lua/police_*_test.lua files returns the harness H (a
--    module require passes its name as `...`);
--  * run.lua's `dofile` (no `...`) returns this file's own suite: the patches apply in order to the pinned commit,
--    every patched Lua file compiles, config/police.json matches the built-in defaults.
--
-- H.tree() exports the pinned commit (deps.lock.json) from resources/[upstream]/qbx_policejob with `git archive`
-- into a temporary directory, applies patches/qbx_policejob.*.patch in name order with `git apply`, reads the Lua,
-- JSON and JS files into memory and deletes the directory. When the checkout or the commit is missing (fetch-deps not
-- run) every police test is skipped with one notice, unless FREDPD_REQUIRE_UPSTREAM=1 (then the first police test
-- fails instead: CI sets it after `node scripts/fetch-deps.mjs --only qbx_policejob`, docs/modules/police.md).
-- H.server(opts) / H.client(file, opts) run the patched files in an isolated _ENV with FiveM, ox_lib, qbx_core,
-- oxmysql, ox_inventory, fredpd_core and fredpd_bolo mocked. cfxlua syntax in upstream files (`a += 1`, backtick
-- hashes, `?.`) is rewritten to plain Lua 5.4 first (H.decfx; line numbers are kept). Run: lua5.4 tests/lua/run.lua police_
local helper = require('helper')

local H = {}

H.UPSTREAM = './resources/[upstream]/qbx_policejob'
H.PATCH_GLOB = 'patches/qbx_policejob.*.patch'

local function shq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function run(cmd)
    local p = io.popen(cmd .. ' 2>&1')
    local out = p:read('a')
    local ok = p:close()
    return ok == true, out
end

local function lines(cmd)
    local out = {}
    local p = io.popen(cmd .. ' 2>/dev/null')
    if p then
        for line in p:lines() do out[#out + 1] = line end
        p:close()
    end
    return out
end

---------------------------------------------------------------------------------------------------------------
-- cfxlua -> Lua 5.4 (test loading only; the patched upstream files keep cfxlua, FiveM runs them)

function H.decfx(src)
    src = src:gsub('`([%w_]+)`', '"%1"')
    src = src:gsub('%?%.', '.'):gsub('%?%[', '[')
    local out = {}
    for line in (src .. '\n'):gmatch('(.-)\n') do
        local indent, target, op, rhs = line:match('^(%s*)([%w_%.%[%]]+)%s*([%+%-%*/%%%^]+)=%s*(.-)%s*$')
        if indent and not line:match('^%s*%-%-') then
            line = ('%s%s = %s %s (%s)'):format(indent, target, target, op, rhs)
        end
        out[#out + 1] = line
    end
    if out[#out] == '' then out[#out] = nil end
    return table.concat(out, '\n')
end

---------------------------------------------------------------------------------------------------------------
-- Patched tree

-- Shared between the `require`d harness and run.lua's `dofile` of this file: build the tree once per run.
local TREE_KEY = '__fredpd_police_tree'

--- { ok, reason, files = { [path] = content }, applied = { names }, luac = { [path] = true | message }, commit }
function H.tree()
    if package.loaded[TREE_KEY] then return package.loaded[TREE_KEY] end
    local tree = { ok = false, files = {}, applied = {}, luac = {} }
    package.loaded[TREE_KEY] = tree
    local lock = helper.readJson('deps.lock.json').resources.qbx_policejob
    tree.commit = lock.commit
    local okRev = run(('git -C %s cat-file -e %s^{commit}'):format(shq(H.UPSTREAM), lock.commit))
    if not okRev then
        tree.reason = ('%s does not have commit %s (run node scripts/fetch-deps.mjs --only qbx_policejob)')
            :format(H.UPSTREAM, lock.commit:sub(1, 10))
        return tree
    end
    local dir = os.tmpname()
    os.remove(dir)
    if not run('mkdir -p ' .. shq(dir)) then
        tree.reason = 'cannot create a temporary directory (POSIX shell, git and tar needed)'
        return tree
    end
    local function cleanup() run('rm -rf ' .. shq(dir)) end
    local ok, out = run(('git -C %s archive %s | tar -x -C %s'):format(shq(H.UPSTREAM), lock.commit, shq(dir)))
    if not ok then
        cleanup()
        tree.reason = 'git archive failed: ' .. out
        return tree
    end
    -- A throwaway repository so that `git apply` resolves paths against dir (not an enclosing repository).
    run(('git -C %s init -q'):format(shq(dir)))
    local patches = lines('ls ' .. H.PATCH_GLOB)
    table.sort(patches)
    local cwd = lines('pwd')[1]
    for _, patch in ipairs(patches) do
        local okApply, msg = run(('git -C %s apply %s'):format(shq(dir), shq(cwd .. '/' .. patch)))
        if not okApply then
            cleanup()
            tree.reason = ('%s does not apply: %s'):format(patch, msg)
            tree.applyError = tree.reason
            return tree
        end
        tree.applied[#tree.applied + 1] = patch:match('[^/]+$')
    end
    -- scripts/apply-patches.mjs skips a patch whose reverse applies; on the fully patched tree each patch must still
    -- reverse-apply on its own, or a second apply-patches run fails ("does not apply cleanly").
    tree.reverse = {}
    for _, patch in ipairs(patches) do
        tree.reverse[patch:match('[^/]+$')] =
            run(('git -C %s apply --reverse --check %s'):format(shq(dir), shq(cwd .. '/' .. patch)))
    end
    local luac = nil
    for _, bin in ipairs({ 'luac5.4', 'luac54', 'luac' }) do
        if run(bin .. ' -v') then luac = bin break end
    end
    for _, path in ipairs(lines(('cd %s && find . -type f \\( -name "*.lua" -o -name "*.json" -o -name "*.js" \\) | sort')
        :format(shq(dir)))) do
        local rel = path:gsub('^%./', '')
        local f = assert(io.open(dir .. '/' .. rel, 'rb'))
        tree.files[rel] = f:read('a')
        f:close()
        if luac and rel:match('%.lua$') then
            local okC, msg = run(('%s -p %s'):format(luac, shq(dir .. '/' .. rel)))
            tree.luac[rel] = okC or msg
        end
    end
    tree.luacBin = luac
    cleanup()
    tree.ok = true
    return tree
end

local skipped = false

--- Calls fn(tree) when the patched tree is available, else prints one skip notice (or fails when
--- FREDPD_REQUIRE_UPSTREAM=1, so that a CI run without the upstream checkout cannot pass silently).
function H.withTree(fn)
    local tr = H.tree()
    if not tr.ok then
        if tr.applyError then error(tr.applyError, 0) end
        if os.getenv('FREDPD_REQUIRE_UPSTREAM') == '1' then
            error('FREDPD_REQUIRE_UPSTREAM=1 but ' .. tostring(tr.reason), 0)
        end
        if not skipped then
            print('SKIP police tests: ' .. tostring(tr.reason))
            skipped = true
        end
        return
    end
    return fn(tr)
end

---------------------------------------------------------------------------------------------------------------
-- Mocks

local Vec = {}
Vec.__index = Vec
Vec.__sub = function(a, b) return H.vec(a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)) end
Vec.__add = function(a, b) return H.vec(a.x + b.x, a.y + b.y, (a.z or 0) + (b.z or 0)) end
Vec.__len = function(a) return math.sqrt(a.x ^ 2 + a.y ^ 2 + (a.z or 0) ^ 2) end

function H.vec(x, y, z, w)
    return setmetatable({ x = x, y = y, z = z, w = w }, Vec)
end

--- A qbx Player object backed by a plain spec table.
--- spec = { cid, job = { type, onduty, grade }, fredpdDuty = bool|nil, grants = { ['type:key'] = true } }
local function makePlayer(env, src, spec)
    spec.cid = spec.cid or ('CID' .. src)
    spec.job = spec.job or { name = 'police', type = 'leo', onduty = true, grade = 0 }
    spec.grants = spec.grants or {}
    spec.metadata = spec.metadata or { callsign = 'IGV-0' .. src, licences = { driver = true } }
    spec.money = spec.money or { cash = 100, bank = 5000 }
    local pd = {
        source = src,
        citizenid = spec.cid,
        job = { name = spec.job.name or 'police', type = spec.job.type, onduty = spec.job.onduty,
            grade = { level = spec.job.grade or 0 } },
        metadata = spec.metadata,
        charinfo = { firstname = 'Test', lastname = 'Person' .. src, gender = 0 },
        money = spec.money,
    }
    local player = { PlayerData = pd, spec = spec }
    player.Functions = {
        GetItemByName = function(name) return (spec.items or {})[name] and { name = name } or nil end,
        RemoveMoney = function(kind, amount, reason)
            env.money[#env.money + 1] = { src = src, op = 'remove', kind = kind, amount = amount, reason = reason }
            if (pd.money[kind] or 0) < amount then return false end
            pd.money[kind] = pd.money[kind] - amount
            return true
        end,
        AddMoney = function(kind, amount, reason)
            env.money[#env.money + 1] = { src = src, op = 'add', kind = kind, amount = amount, reason = reason }
            pd.money[kind] = (pd.money[kind] or 0) + amount
            return true
        end,
        SetMetaData = function(key, value) pd.metadata[key] = value end,
        AddItem = function(name, count) env.qbxItems[#env.qbxItems + 1] = { src = src, name = name, count = count } return true end,
        RemoveItem = function() return true end,
    }
    return player
end

--- The mocked world. opts = { players = { [src] = spec }, resources = { name = state }, convars = {}, config = bool }
function H.env(opts)
    opts = opts or {}
    local tr = H.tree()
    local env = {
        now = 100000, net = {}, handlers = {}, callbacks = {}, commands = {}, clientEvents = {}, events = {},
        notifies = {}, logs = {}, audits = {}, sql = {}, addItems = {}, hooks = {}, money = {}, qbxItems = {},
        spawned = {}, deleted = {}, resolved = {}, serverEvents = {}, contexts = {}, zones = {}, threads = {},
        modules = {}, bolos = {}, coords = {}, pedVehicle = {}, driver = {}, plates = {}, netEntities = {},
        convars = opts.convars or {}, canCarry = true, owned = {}, impounded = {}, carried = {},
        resources = { fredpd_core = 'started', fredpd_bolo = 'started', fredpd_dispatch = 'started',
            ox_inventory = 'started', ox_target = 'started', qbx_core = 'started' },
    }
    for k, v in pairs(opts.resources or {}) do env.resources[k] = v end
    -- qbx_core's qb-core bridge is not mocked
    if env.convars['qbx:enablebridge'] == nil then env.convars['qbx:enablebridge'] = 'false' end
    env.players = {}
    for src, spec in pairs(opts.players or {}) do env.players[src] = makePlayer(env, src, spec) end

    local function player(src) return env.players[tonumber(src)] end
    function env.spec(src) return env.players[src].spec end

    local impl = {}
    impl.fredpd_core = {
        isOnDuty = function(src)
            local p = player(src)
            if not p then return false end
            if p.spec.fredpdDuty ~= nil then return p.spec.fredpdDuty end
            return p.PlayerData.job.type == 'leo' and p.PlayerData.job.onduty == true
        end,
        hasGrant = function(src, grantType, key)
            local p = player(src)
            if not p then return false end
            local g = p.spec.grants
            local denied = p.spec.denied or {}
            if denied[grantType .. ':' .. key] or denied[grantType .. ':*'] then return false end
            return g[grantType .. ':' .. key] == true or g[grantType .. ':*'] == true
        end,
        getCitizenId = function(src) local p = player(src) return p and p.PlayerData.citizenid or nil end,
        audit = function(src, action, targetType, targetId, meta)
            env.audits[#env.audits + 1] = { src = src, action = action, targetType = targetType,
                targetId = targetId, meta = meta }
        end,
    }
    impl.fredpd_bolo = {
        checkPlate = function(plate)
            if env.boloThrows then error('fredpd_bolo exploded', 0) end
            env.boloChecks = (env.boloChecks or 0) + 1
            return env.bolos[plate]
        end,
        resolveOnImpound = function(plate, src)
            env.resolved[#env.resolved + 1] = { plate = plate, src = src }
            return true
        end,
    }
    local ITEMS = {
        WEAPON_PISTOL = 'Pistol', WEAPON_STUNGUN = 'Taser', WEAPON_NIGHTSTICK = 'Batong', WEAPON_FLASHLIGHT = 'Ficklampa',
        WEAPON_CARBINERIFLE = 'Karbin', ['ammo-9'] = '9 mm', ['ammo-rifle'] = 'Gevärsammunition', handcuffs = 'Handfängsel',
    }
    impl.ox_inventory = {
        Items = function(name) return ITEMS[name] and { name = name, label = ITEMS[name] } or nil end,
        CanCarryItem = function() return env.canCarry end,
        AddItem = function(src, name, count, metadata)
            env.addItems[#env.addItems + 1] = { src = src, name = name, count = count, metadata = metadata }
            return true
        end,
        RemoveItem = function() return true end,
        registerHook = function(event, fn, options)
            env.hooks[#env.hooks + 1] = { event = event, fn = fn, options = options }
            return 'qbx_policejob:' .. event .. ':' .. #env.hooks
        end,
        RegisterStash = function() end,
        ClearInventory = function() end,
        GetCurrentWeapon = function() return { metadata = {} } end,
        Search = function() return 1 end,
        GetItemCount = function(src, name)
            env.itemCountCalls = (env.itemCountCalls or 0) + 1
            return (env.carried[src] or {})[name] or 0
        end,
    }
    impl.qbx_core = {
        GetPlayer = function(src) return player(src) end,
        GetQBPlayers = function() return env.players end,
        GetPlayerByCitizenId = function(cid)
            for _, p in pairs(env.players) do if p.PlayerData.citizenid == cid then return p end end
        end,
        Notify = function(a, b, c)
            if type(a) == 'number' then
                env.notifies[#env.notifies + 1] = { src = a, msg = b, kind = c }
            else
                env.notifies[#env.notifies + 1] = { msg = a, kind = b }
            end
        end,
        CreateUseableItem = function() end,
        GetJobs = function() return {} end,
        GetDutyCountType = function() return 0 end,
        GetVehiclesByName = function() return {} end,
        GetWeapons = function() return {} end,
    }
    impl['Renewed-Banking'] = { addAccountMoney = function() return true end }
    impl.qbx_vehiclekeys = { GiveKeys = function() end }
    impl.ox_target = {
        addBoxZone = function(z) env.zones[#env.zones + 1] = z return #env.zones end,
        removeZone = function(id) env.zones[id] = false end,
    }
    env.impl = impl

    local exports = setmetatable({}, {
        __index = function(_, resource)
            return setmetatable({}, {
                __index = function(_, fn)
                    return function(_, ...)
                        local state = env.resources[resource]
                        local res = impl[resource]
                        if (state ~= nil and state ~= 'started') or not res or not res[fn] then
                            error(('No such export %s in resource %s'):format(fn, resource), 2)
                        end
                        return res[fn](...)
                    end
                end,
            })
        end,
        __call = function() end,
    })

    local function record(list) return function(...) list[#list + 1] = table.pack(...) end end

    local lib = {
        callback = setmetatable({
            register = function(name, fn) env.callbacks[name] = fn end,
            await = function(name, _, ...)
                env.serverEvents[#env.serverEvents + 1] = { name = 'callback:' .. name, args = table.pack(...) }
                local handler = env.clientCallbacks and env.clientCallbacks[name]
                if handler then return handler(...) end
                return nil
            end,
        }, {
            __call = function(_, name, _, cb, ...)
                env.serverEvents[#env.serverEvents + 1] = { name = 'callback:' .. name, args = table.pack(...) }
                local handler = env.clientCallbacks and env.clientCallbacks[name]
                if handler then cb(handler(...)) end
            end,
        }),
        addCommand = function(name, options, fn) env.commands[name] = { options = options, fn = fn } end,
        print = setmetatable({}, { __index = function(_, level)
            return function(...) env.logs[#env.logs + 1] = { level = level, msg = table.concat({ ... }, ' ') } end
        end }),
        string = { random = function(pattern) return (pattern:gsub('.', '1')) end },
        getNearbyPlayers = function() return {} end,
        logger = function() end,
        points = { new = function(p) env.points = env.points or {} env.points[#env.points + 1] = p return p end },
        zones = { box = function(z) env.zones[#env.zones + 1] = z return z end },
        registerContext = function(ctx) env.contexts[#env.contexts + 1] = ctx end,
        showContext = function(id) env.shownContext = id end,
        showTextUI = function() end,
        hideTextUI = function() end,
        inputDialog = function() return nil end,
        progressCircle = function() return true end,
        addKeybind = function() return {} end,
        waitFor = function(fn) return fn() end,
    }

    local G = {}
    env.G = G
    setmetatable(G, { __index = _G })
    local globals = {
        exports = exports,
        lib = lib,
        qbx = {
            getVehiclePlate = function(veh) return env.plates[veh] end,
            spawnVehicle = function(params)
                env.spawned[#env.spawned + 1] = params
                return 77, 7700
            end,
            string = { trim = function(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end },
            math = { round = function(n) return math.floor(n + 0.5) end },
        },
        QBX = { PlayerData = { job = { type = 'leo', onduty = true, grade = { level = 0 } }, metadata = {}, charinfo = {} } },
        cache = { ped = 1, playerId = 1, seat = -1 },
        MySQL = {
            scalar = { await = function(sql, params)
                env.sql[#env.sql + 1] = { sql = sql, params = params }
                if sql:find('count%(%*%)') then return env.owned[params[1]] and 1 or 0 end
                if sql:find('state = 2') then return env.impounded[params[1]] end
                return nil
            end },
            query = setmetatable({ await = function(sql, params)
                env.sql[#env.sql + 1] = { sql = sql, params = params }
                return {}
            end }, { __call = function(_, sql, params) env.sql[#env.sql + 1] = { sql = sql, params = params } end }),
            update = setmetatable({ await = function(sql, params)
                env.sql[#env.sql + 1] = { sql = sql, params = params }
                return 1
            end }, { __call = function(_, sql, params) env.sql[#env.sql + 1] = { sql = sql, params = params } end }),
        },
        GlobalState = {},
        LocalPlayer = { state = { isLoggedIn = true } },
        Player = function() return { state = {} } end,
        Entity = function() return { state = {} } end,
        GetResourceState = function(name) return env.resources[name] or 'missing' end,
        GetConvar = function(name, default) return env.convars[name] or default end,
        GetGameTimer = function() return env.now end,
        GetInvokingResource = function() return nil end,
        GetCurrentResourceName = function() return 'qbx_policejob' end,
        LoadResourceFile = function(resource, path)
            if resource == 'fredpd_core' and path == 'config/police.json' and env.policeConfig then
                return env.policeConfig
            end
            return nil
        end,
        RegisterNetEvent = function(name, fn) if fn then env.net[name] = fn end end,
        RegisterServerEvent = function(name, fn) if fn then env.net[name] = fn end end,
        AddEventHandler = function(name, fn)
            env.handlers[name] = env.handlers[name] or {}
            table.insert(env.handlers[name], fn)
        end,
        TriggerClientEvent = function(name, target, ...)
            env.clientEvents[#env.clientEvents + 1] = { name = name, target = target, args = table.pack(...) }
        end,
        TriggerEvent = function(name, ...) env.events[#env.events + 1] = { name = name, args = table.pack(...) } end,
        TriggerServerEvent = function(name, ...)
            env.serverEvents[#env.serverEvents + 1] = { name = name, args = table.pack(...) }
        end,
        CreateThread = function(fn) env.threads[#env.threads + 1] = fn end,
        SetTimeout = function() end,
        Wait = function() end,
        GetPlayerPed = function(src) return env.players[tonumber(src)] and 1000 + tonumber(src) or 0 end,
        GetEntityCoords = function(entity) return env.coords[entity] or H.vec(0, 0, 0) end,
        GetEntityHeading = function() return 0.0 end,
        GetVehiclePedIsIn = function(ped) return env.pedVehicle[ped] or 0 end,
        GetPedInVehicleSeat = function(veh, seat) return seat == -1 and env.driver[veh] or 0 end,
        NetworkGetEntityFromNetworkId = function(netId) return env.netEntities[netId] or 0 end,
        DoesEntityExist = function(entity) return entity ~= nil and entity ~= 0 end,
        DeleteEntity = function(entity) env.deleted[#env.deleted + 1] = entity end,
        SetVehicleNumberPlateText = function() end,
        GetPlayerRoutingBucket = function() return 0 end,
        GetVehicleClass = function() return env.vehicleClass or 0 end,
        GetEntitySpeed = function() return env.speed or 10.0 end,
        GetStreetNameAtCoord = function() return 11, 22 end,
        GetStreetNameFromHashKey = function(hash) return hash == 11 and 'Vespucci Blvd' or '' end,
        GetPlayerServerId = function(id) return id end,
        vec3 = H.vec, vec4 = H.vec, vector3 = H.vec, vector4 = H.vec,
        locale = function(key, ...)
            local n = select('#', ...)
            if n == 0 then return key end
            local parts = { key }
            for i = 1, n do parts[#parts + 1] = tostring((select(i, ...))) end
            return table.concat(parts, '|')
        end,
    }
    for k, v in pairs(globals) do G[k] = v end
    G._G = G

    G.require = function(name)
        if env.modules[name] ~= nil then return env.modules[name] end
        local path = name:gsub('%.', '/') .. '.lua'
        local src = tr.files[path]
        if not src then error('module not found: ' .. name, 2) end
        local fn = assert(load(H.decfx(src), '@' .. path, 't', G))
        local result = fn()
        env.modules[name] = result == nil and true or result
        return env.modules[name]
    end

    --- Run one of the patched files in this environment.
    function env.load(path)
        local src = assert(tr.files[path], 'no file ' .. path)
        local fn = assert(load(H.decfx(src), '@' .. path, 't', G))
        return fn()
    end

    --- Fire a net event as FiveM does (global `source` = src for the call).
    function env.fire(name, src, ...)
        local fn = assert(env.net[name], 'net event not registered: ' .. name)
        G.source = src
        local ok, err = pcall(fn, ...)
        G.source = nil
        if not ok then error(err, 0) end
    end

    --- Call a lib callback as a client would: returns its results.
    function env.call(name, src, ...)
        local fn = assert(env.callbacks[name], 'callback not registered: ' .. name)
        return fn(src, ...)
    end

    --- Run a lib.addCommand command as src.
    function env.command(name, src, args)
        local cmd = assert(env.commands[name], 'command not registered: ' .. name)
        return cmd.fn(src, args or {}, '')
    end

    function env.named(list, name)
        local out = {}
        for _, e in ipairs(list) do if e.name == name then out[#out + 1] = e end end
        return out
    end

    function env.lastNotify(src)
        for i = #env.notifies, 1, -1 do
            if src == nil or env.notifies[i].src == src then return env.notifies[i] end
        end
        return nil
    end

    function env.clear()
        env.clientEvents, env.events, env.notifies, env.audits, env.sql = {}, {}, {}, {}, {}
        env.addItems, env.spawned, env.deleted, env.resolved, env.money, env.serverEvents = {}, {}, {}, {}, {}, {}
    end

    return env
end

--- Load the patched server side (fxmanifest order: server/*.lua sorted; fredpd/*.lua via require).
function H.server(opts)
    local env = H.env(opts)
    for _, file in ipairs({ 'server/commands.lua', 'server/main.lua', 'server/objects.lua', 'server/storage.lua' }) do
        env.load(file)
    end
    env.FredPD = env.modules['fredpd.server']
    env.Bolo = env.modules['fredpd.bolo']
    return env
end

--- Load one patched client file (after an optional setup(env)).
function H.client(file, opts, setup)
    local env = H.env(opts)
    if setup then setup(env) end
    env.result = env.load(file)
    return env
end

--- Standard cast: 1 officer with every grant used below, 2 officer without grants, 3 FredPD off duty (qbx says on
--- duty), 4 civilian, 7 and 12 on-duty officers (sparse ids, no player 5..6 or 8..11).
function H.cast()
    return {
        [1] = { cid = 'OFF00001', grants = {
            ['perm:police.impound'] = true, ['perm:police.jail'] = true, ['perm:charges.fine'] = true,
            ['perm:police.license'] = true, ['perm:bolo.create'] = true, ['perm:bolo.resolve'] = true,
            ['armory:mrpd'] = true, ['weapon:weapon_pistol'] = true, ['armory:ammo-9'] = true,
            ['vehicle:police'] = true, ['vehicle:police3'] = true, ['vehicle:polmav'] = true,
        }, job = { type = 'leo', onduty = true, grade = 0 } },
        [2] = { cid = 'OFF00002', job = { type = 'leo', onduty = true, grade = 4 } },
        [3] = { cid = 'OFF00003', fredpdDuty = false, grants = { ['perm:police.impound'] = true, ['armory:mrpd'] = true,
            ['weapon:weapon_pistol'] = true }, job = { type = 'leo', onduty = true, grade = 4 } },
        [4] = { cid = 'CIV00004', job = { name = 'unemployed', type = 'none', onduty = false, grade = 0 } },
        [7] = { cid = 'OFF00007', job = { type = 'leo', onduty = true, grade = 1 } },
        [12] = { cid = 'OFF00012', job = { type = 'leo', onduty = true, grade = 2 } },
    }
end

---------------------------------------------------------------------------------------------------------------
-- This file's own suite

local tests = {}

tests['patches: all qbx_policejob patches apply in name order to the pinned commit'] = function(t)
    H.withTree(function(tr)
        t.eq(tr.applied, { 'qbx_policejob.10-grants.patch', 'qbx_policejob.20-fredpd-replacements.patch',
            'qbx_policejob.30-bolo-hooks.patch', 'qbx_policejob.40-sv-locale.patch' })
        t.ok(tr.files['fredpd/server.lua'] and tr.files['fredpd/bolo.lua'] and tr.files['fredpd/client.lua'],
            'the patches add fredpd/server.lua, fredpd/bolo.lua and fredpd/client.lua')
        t.ok(tr.files['fxmanifest.lua']:find("'fredpd/client.lua'", 1, true), 'fxmanifest lists fredpd/client.lua')
    end)
end

tests['patches: a second apply-patches run sees every patch as already applied (no overlapping hunks)'] = function(t)
    H.withTree(function(tr)
        for _, name in ipairs(tr.applied) do t.eq(tr.reverse[name], true, name .. ' reverse-applies on the patched tree') end
    end)
end

tests['patches: FredPD files are plain Lua 5.4 (luac -p) with the SPDX header'] = function(t)
    H.withTree(function(tr)
        for _, path in ipairs({ 'fredpd/server.lua', 'fredpd/bolo.lua', 'fredpd/client.lua' }) do
            local src = tr.files[path]
            t.ok(src:find('^%-%- SPDX%-License%-Identifier: GPL%-3%.0%-only\n'), path .. ' SPDX header')
            local fn, err = load(src, '@' .. path, 't', {})
            t.ok(fn, path .. ' compiles as Lua 5.4: ' .. tostring(err))
            if tr.luacBin then t.eq(tr.luac[path], true, path .. ' luac -p') end
            t.ok(not src:find('while%s+true'), path .. ' has no polling loop')
        end
    end)
end

tests['patches: every patched upstream Lua file compiles (luac -p, or after the cfxlua rewrite)'] = function(t)
    H.withTree(function(tr)
        local cfx = {}
        local count = 0
        for path, src in pairs(tr.files) do
            if path:match('%.lua$') then
                count = count + 1
                local fn, err = load(H.decfx(src), '@' .. path, 't', {})
                t.ok(fn, path .. ': ' .. tostring(err))
                if tr.luacBin and tr.luac[path] ~= true then cfx[#cfx + 1] = path end
            end
        end
        t.ok(count >= 20, 'lua files found: ' .. count)
        table.sort(cfx)
        if tr.luacBin then
            -- luac5.4 rejects these upstream files for cfxlua syntax only (`+=`/`-=`, backtick hashes, `?.`)
            t.eq(cfx, { 'client/evidence.lua', 'client/heli.lua', 'client/interactions.lua', 'client/job.lua',
                'client/main.lua', 'client/tracker.lua', 'config/shared.lua', 'server/main.lua', 'server/objects.lua' })
        end
    end)
end

tests['config: config/police.json equals the built-in defaults of fredpd/server.lua'] = function(t)
    H.withTree(function()
        local env = H.server({ players = H.cast() })
        local FredPD = env.FredPD
        local decoded = helper.readJson('config/police.json')
        local function strip(v)
            if type(v) ~= 'table' then return v end
            local out = {}
            for k, x in pairs(v) do
                if not (type(k) == 'string' and k:sub(1, 1) == '$') then out[k] = strip(x) end
            end
            return out
        end
        local built = FredPD.buildConfig(decoded)
        t.eq(built, FredPD.buildConfig(nil), 'config/police.json changes nothing against the defaults')
        t.eq(strip(decoded).actions, FredPD.DEFAULTS.actions)
        t.eq(strip(decoded).armories, FredPD.DEFAULTS.armories)
        t.eq(strip(decoded).oxShops, FredPD.DEFAULTS.oxShops)
        for action, spec in pairs(FredPD.DEFAULTS.actions) do
            t.ok(spec == 'duty' or FredPD.parseGrant(spec), action .. ' has a valid grant')
        end
    end)
end

tests['config: invalid entries are dropped (unmapped action is refused), $comment keys ignored'] = function(t)
    H.withTree(function()
        local env = H.server({ players = H.cast() })
        local cfg = env.FredPD.buildConfig({
            actions = { impound = 'nonsense', jail = 'perm:bad key', cuff = 'duty', ['$comment'] = 'x' },
            oxShops = { ['$comment'] = 'x', Shop = 'mrpd' },
            armories = { ['bad id!'] = { coords = { 1, 2, 3 }, items = {} }, nocoords = { items = {} } },
            radar = { cooldownSeconds = -5, maxDistance = 20 },
        })
        t.eq(cfg.actions.impound, nil)
        t.eq(cfg.actions.jail, nil)
        t.eq(cfg.actions.cuff, 'duty')
        t.eq(cfg.actions['$comment'], nil)
        t.eq(cfg.oxShops, { Shop = 'mrpd' })
        t.eq(cfg.armories, {})
        t.eq(cfg.radar, { cooldownSeconds = 60, maxDistance = 20 })
    end)
end

tests['config: LoadResourceFile(fredpd_core, config/police.json) overrides the defaults'] = function(t)
    H.withTree(function()
        local env = H.server({ players = H.cast() })
        env.policeConfig = json.encode({ actions = { cuff = 'perm:police.cuff' } })
        env.FredPD.resetConfig()
        t.eq(env.FredPD.grantFor('cuff'), { 'perm', 'police.cuff' })
        t.eq(env.FredPD.grantFor('impound'), { 'perm', 'police.impound' }, 'other actions keep their default')
        env.policeConfig = '{not json'
        env.FredPD.resetConfig()
        t.eq(env.FredPD.grantFor('cuff'), false, 'invalid JSON -> defaults')
        t.ok(#env.logs >= 1, 'invalid JSON is warned about')
    end)
end

if ... then return H end
return tests
