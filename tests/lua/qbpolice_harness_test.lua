-- SPDX-License-Identifier: GPL-3.0-only
-- qb-policejob + qb-core item patches: shared harness + patch checks (docs/modules/police-qb.md).
--
-- Used two ways (the same approach as tests/lua/police_harness_test.lua for qbx_policejob):
--  * `require('qbpolice_harness_test')` from the other tests/lua/qbpolice_*_test.lua files returns the harness H;
--  * run.lua's `dofile` (no `...`) returns this file's own suite: the patches apply in order to the pinned commits,
--    reverse-apply one by one on the patched tree, every patched Lua file compiles, config/police.json's qbPolicejob
--    section matches the built-in defaults, the qb-core items have the right shape.
--
-- H.tree(resource, glob) exports the pinned commit (deps.lock.json) of resources/[upstream]/<resource> with
-- `git archive` into a temporary directory, applies the patches in name order with `git apply`, reads the Lua, JSON,
-- JS and HTML files into memory and deletes the directory. Missing checkout or commit: every qbpolice test is skipped
-- with one notice, unless FREDPD_REQUIRE_UPSTREAM=1 (then it fails). H.server(opts) / H.client(files, opts) run the
-- patched files in an isolated _ENV with FiveM, qb-core (real shared/locale.lua at its pin), qb-inventory, oxmysql,
-- fredpd_core and fredpd_bolo mocked. cfxlua syntax (`+=`, backtick hashes, `?.`) is rewritten for loading only.
local helper = require('helper')

local H = {}

H.POLICE = 'qb-policejob'
H.CORE = 'qb-core'

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
-- Patched trees

local TREE_KEY = '__fredpd_qbpolice_tree_'

--- { ok, reason, files = { [path] = content }, applied = { names }, reverse = { [name] = bool },
---   luac = { [path] = true | message }, commit }
function H.tree(resource)
    resource = resource or H.POLICE
    local key = TREE_KEY .. resource
    if package.loaded[key] then return package.loaded[key] end
    local tree = { ok = false, files = {}, applied = {}, luac = {}, reverse = {} }
    package.loaded[key] = tree
    local upstream = './resources/[upstream]/' .. resource
    local lock = helper.readJson('deps.lock.json').resources[resource]
    tree.commit = lock.commit
    if not run(('git -C %s cat-file -e %s^{commit}'):format(shq(upstream), lock.commit)) then
        tree.reason = ('%s does not have commit %s (run node scripts/fetch-deps.mjs --only %s)')
            :format(upstream, lock.commit:sub(1, 10), resource)
        return tree
    end
    local dir = os.tmpname()
    os.remove(dir)
    if not run('mkdir -p ' .. shq(dir)) then
        tree.reason = 'cannot create a temporary directory (POSIX shell, git and tar needed)'
        return tree
    end
    local function cleanup() run('rm -rf ' .. shq(dir)) end
    local ok, out = run(('git -C %s archive %s | tar -x -C %s'):format(shq(upstream), lock.commit, shq(dir)))
    if not ok then
        cleanup()
        tree.reason = 'git archive failed: ' .. out
        return tree
    end
    run(('git -C %s init -q'):format(shq(dir)))
    local patches = lines(('ls patches/%s.*.patch'):format(resource))
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
    for _, patch in ipairs(patches) do
        tree.reverse[patch:match('[^/]+$')] =
            run(('git -C %s apply --reverse --check %s'):format(shq(dir), shq(cwd .. '/' .. patch)))
    end
    local luac = nil
    for _, bin in ipairs({ 'luac5.4', 'luac54', 'luac' }) do
        if run(bin .. ' -v') then luac = bin break end
    end
    local find = 'cd %s && find . -type f \\( -name "*.lua" -o -name "*.json" -o -name "*.js" -o -name "*.html" \\) | sort'
    for _, path in ipairs(lines(find:format(shq(dir)))) do
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
    tree.nodeCheck = nil
    if tree.files['html/script.js'] and run('node -v') then
        tree.nodeCheck = run(('node --check %s'):format(shq(dir .. '/html/script.js')))
    end
    cleanup()
    tree.ok = true
    return tree
end

local skipped = false

--- Calls fn(policeTree, coreTree) when both patched trees are available, else prints one skip notice (or fails when
--- FREDPD_REQUIRE_UPSTREAM=1).
function H.withTree(fn)
    local police, core = H.tree(H.POLICE), H.tree(H.CORE)
    for _, tr in ipairs({ police, core }) do
        if not tr.ok then
            if tr.applyError then error(tr.applyError, 0) end
            if os.getenv('FREDPD_REQUIRE_UPSTREAM') == '1' then
                error('FREDPD_REQUIRE_UPSTREAM=1 but ' .. tostring(tr.reason), 0)
            end
            if not skipped then
                print('SKIP qbpolice tests: ' .. tostring(tr.reason))
                skipped = true
            end
            return
        end
    end
    return fn(police, core)
end

---------------------------------------------------------------------------------------------------------------
-- Mocks

local Vec = {}
Vec.__index = Vec
Vec.__sub = function(a, b) return H.vec(a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)) end
Vec.__add = function(a, b) return H.vec(a.x + b.x, a.y + b.y, (a.z or 0) + (b.z or 0)) end
Vec.__mul = function(a, b)
    if type(a) == 'number' then a, b = b, a end
    return H.vec(a.x * b, a.y * b, (a.z or 0) * b)
end
Vec.__len = function(a) return math.sqrt(a.x ^ 2 + a.y ^ 2 + (a.z or 0) ^ 2) end

function H.vec(x, y, z, w)
    return setmetatable({ x = x, y = y, z = z, w = w }, Vec)
end

--- A qb-core Player object backed by a plain spec table.
--- spec = { cid, job = { name, type, onduty, grade }, fredpdDuty = bool|nil, grants = { ['type:key'] = true },
---          items = { [name] = count } }
local function makePlayer(env, src, spec)
    spec.cid = spec.cid or ('CID' .. src)
    spec.job = spec.job or { name = 'police', type = 'leo', onduty = true, grade = 0 }
    spec.grants = spec.grants or {}
    spec.items = spec.items or {}
    spec.metadata = spec.metadata or { callsign = 'IGV-0' .. src, licences = { driver = true, weapon = false } }
    spec.money = spec.money or { cash = 100, bank = 5000 }
    local pd = {
        source = src,
        citizenid = spec.cid,
        job = { name = spec.job.name or 'police', type = spec.job.type, onduty = spec.job.onduty,
            grade = { level = spec.job.grade or 0 } },
        metadata = spec.metadata,
        charinfo = { firstname = 'Test', lastname = 'Person' .. src },
        money = spec.money,
    }
    local player = { PlayerData = pd, spec = spec }
    local fns = {
        GetItemByName = function(name) return (spec.items[name] or 0) > 0 and { name = name } or nil end,
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
    }
    player.Functions = fns
    for k, v in pairs(fns) do player[k] = v end -- qb-core also exposes them on the player object
    return player
end

--- Items the mocked qb-core knows (GetShared('Items')); names as in qb-core shared/items.lua.
H.ITEMS = {}
for name, label in pairs({
    weapon_pistol = 'Walther P99', weapon_stungun = 'Taser', weapon_nightstick = 'Nightstick',
    weapon_flashlight = 'Flashlight', weapon_carbinerifle = 'Carbine Rifle', pistol_ammo = 'Pistol ammo',
    rifle_ammo = 'Rifle ammo', handcuffs = 'Handcuffs', moneybag = 'Money Bag', empty_evidence_bag = 'Empty Evidence Bag',
    filled_evidence_bag = 'Evidence Bag', police_stormram = 'Stormram',
}) do
    H.ITEMS[name] = { name = name, label = label, type = name:find('^weapon_') and 'weapon' or 'item' }
end

--- The mocked world. opts = { players = { [src] = spec }, resources = { name = state }, convars = {} }
function H.env(opts)
    opts = opts or {}
    local tr, core = H.tree(H.POLICE), H.tree(H.CORE)
    local env = {
        now = 100000, net = {}, handlers = {}, callbacks = {}, commands = {}, clientEvents = {}, events = {},
        logs = {}, audits = {}, sql = {}, addItems = {}, hooks = {}, money = {}, spawned = {}, resolved = {},
        serverEvents = {}, threads = {}, bolos = {}, coords = {}, pedVehicle = {}, driver = {}, plates = {},
        dropped = {}, banking = {}, features = {}, canAdd = true, impounded = {}, owned = {}, useable = {},
        menus = {}, headers = {}, notifies = {}, targetZones = {}, boxZones = {}, inputs = {},
        convars = opts.convars or {},
        resources = { fredpd_core = 'started', fredpd_bolo = 'started', fredpd_dispatch = 'started',
            ['qb-core'] = 'started', ['qb-inventory'] = 'started', ['qb-target'] = 'started' },
    }
    for k, v in pairs(opts.resources or {}) do env.resources[k] = v end
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
            return g[grantType .. ':' .. key] == true or g[grantType .. ':*'] == true
        end,
        audit = function(src, action, targetType, targetId, meta)
            env.audits[#env.audits + 1] = { src = src, action = action, targetType = targetType,
                targetId = targetId, meta = meta }
        end,
        hasFeature = function(name)
            if env.noHasFeature then error('No such export hasFeature in resource fredpd_core', 0) end
            return env.features[name] == true
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
    impl['qb-inventory'] = {
        GetItemCount = function(src, name) return (player(src) and player(src).spec.items[name]) or 0 end,
        CanAddItem = function() return env.canAdd end,
        AddItem = function(src, name, count, slot, info, reason)
            env.addItems[#env.addItems + 1] = { src = src, name = name, count = count, slot = slot, info = info,
                reason = reason }
            local p = player(src)
            if p then p.spec.items[name] = (p.spec.items[name] or 0) + count end
            return true
        end,
        RemoveItem = function(src, name, count)
            local p = player(src)
            if not p or (p.spec.items[name] or 0) < (count or 1) then return false end
            p.spec.items[name] = p.spec.items[name] - (count or 1)
            return true
        end,
        AddHook = function(kind, fn)
            env.hooks[#env.hooks + 1] = { kind = kind, fn = fn }
            return #env.hooks
        end,
        OpenInventory = function() end,
        OpenInventoryById = function() end,
    }
    impl['qb-banking'] = {
        AddMoney = function(account, amount, reason)
            env.banking[#env.banking + 1] = { account = account, amount = amount, reason = reason }
        end,
    }
    impl['qb-menu'] = {
        openMenu = function(menu) env.menus[#env.menus + 1] = menu end,
        showHeader = function(menu) env.headers[#env.headers + 1] = menu end,
        closeMenu = function() end,
    }
    impl['qb-target'] = {
        AddCircleZone = function(name, center, radius, zoneOpts, targetOpts)
            env.targetZones[name] = { center = center, radius = radius, options = targetOpts }
        end,
        RemoveZone = function(name) env.targetZones[name] = nil end,
    }
    impl['qb-input'] = { ShowInput = function(dialog) env.inputs[#env.inputs + 1] = dialog return env.inputAnswer end }
    impl.LegacyFuel = { SetFuel = function() end, GetFuel = function() return 50 end }

    local QBCore = {
        Functions = {
            CreateCallback = function(name, fn) env.callbacks[name] = fn end,
            CreateUseableItem = function(name, fn) env.useable[name] = fn end,
            GetQBPlayers = function() return env.players end,
            GetPlayer = function(src) return player(src) end,
            GetPlayerByCitizenId = function(cid)
                for _, p in pairs(env.players) do if p.PlayerData.citizenid == cid then return p end end
            end,
            GetClosestPlayer = function() return env.closest or -1, env.closestDistance or 99 end,
            SpawnVehicle = function(src, model, coords, warp)
                env.spawned[#env.spawned + 1] = { src = src, model = model, coords = coords, warp = warp }
                return 500 + #env.spawned
            end,
            -- client side
            TriggerCallback = function(name, cb, ...)
                env.serverEvents[#env.serverEvents + 1] = { name = 'callback:' .. name, args = table.pack(...) }
                local handler = env.clientCallbacks and env.clientCallbacks[name]
                if handler then cb(handler(...)) end
            end,
            Notify = function(msg, kind) env.notifies[#env.notifies + 1] = { msg = msg, kind = kind } end,
            GetPlayerData = function(cb)
                local data = env.playerData or { job = { type = 'leo', onduty = true, grade = { level = 0 } },
                    metadata = {}, charinfo = {} }
                if cb then return cb(data) end
                return data
            end,
            GetPlate = function(veh) return env.plates[veh] end,
            GetClosestVehicle = function() return 0 end,
            DeleteVehicle = function() end,
            SetVehicleProperties = function() end,
            GetPlayersFromCoords = function() return {} end,
            Progressbar = function() end,
        },
        Commands = { Add = function(name, _, _, _, fn) env.commands[name] = fn end },
    }
    env.QBCore = QBCore
    impl['qb-core'] = {
        GetCoreObject = function() return QBCore end,
        GetShared = function(kind) if kind == 'Items' then return H.ITEMS end return {} end,
        GetPlayer = function(src) return player(src) end,
        DrawText = function() end,
        HideText = function() end,
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

    local function zone(kind)
        return { Create = function(_, ...)
            local z = { kind = kind, args = table.pack(...) }
            function z:onPlayerInOut(fn) self.inOut = fn end
            function z:destroy() self.destroyed = true end
            env.boxZones[#env.boxZones + 1] = z
            return z
        end }
    end

    local G = {}
    env.G = G
    setmetatable(G, { __index = _G })
    local globals = {
        exports = exports,
        json = json,
        MySQL = {
            scalar = { await = function(sql, params)
                env.sql[#env.sql + 1] = { sql = sql, params = params }
                if sql:find('state = 2') then return env.impounded[params[1]] end
                if sql:find('SELECT plate FROM player_vehicles') then return env.owned[params[1]] end
                return nil
            end },
            query = setmetatable({ await = function(sql, params)
                env.sql[#env.sql + 1] = { sql = sql, params = params }
                return {}
            end }, { __call = function(_, sql, params, cb)
                env.sql[#env.sql + 1] = { sql = sql, params = params }
                if cb then cb(env.queryResult or {}) end
            end }),
            update = setmetatable({ await = function(sql, params)
                env.sql[#env.sql + 1] = { sql = sql, params = params }
                return 1
            end }, { __call = function(_, sql, params) env.sql[#env.sql + 1] = { sql = sql, params = params } end }),
            Async = { insert = function(sql, params) env.sql[#env.sql + 1] = { sql = sql, params = params } end },
        },
        LocalPlayer = { state = { isLoggedIn = true } },
        Player = function() return { state = {} } end,
        GetResourceState = function(name) return env.resources[name] or 'missing' end,
        GetConvar = function(name, default) return env.convars[name] or default end,
        GetGameTimer = function() return env.now end,
        GetInvokingResource = function() return nil end,
        GetCurrentResourceName = function() return 'qb-policejob' end,
        LoadResourceFile = function(resource, path)
            if resource == 'fredpd_core' and path == 'config/police.json' then return env.policeConfig end
            return nil
        end,
        RegisterNetEvent = function(name, fn) if fn then env.net[name] = fn end end,
        AddEventHandler = function(name, fn)
            env.handlers[name] = env.handlers[name] or {}
            table.insert(env.handlers[name], fn)
        end,
        RegisterNUICallback = function() end,
        RegisterCommand = function() end,
        TriggerClientEvent = function(name, target, ...)
            local args = table.pack(...)
            env.clientEvents[#env.clientEvents + 1] = { name = name, target = target, args = args }
            if name == 'QBCore:Notify' then
                env.notifies[#env.notifies + 1] = { src = target, msg = args[1], kind = args[2] }
            end
        end,
        TriggerEvent = function(name, ...) env.events[#env.events + 1] = { name = name, args = table.pack(...) } end,
        TriggerServerEvent = function(name, ...)
            env.serverEvents[#env.serverEvents + 1] = { name = name, args = table.pack(...) }
        end,
        SendNUIMessage = function(msg) env.nui = env.nui or {} env.nui[#env.nui + 1] = msg end,
        CreateThread = function(fn) env.threads[#env.threads + 1] = fn end,
        SetTimeout = function() end,
        Wait = function() if env.waitHook then env.waitHook() end end,
        DropPlayer = function(src, reason) env.dropped[#env.dropped + 1] = { src = src, reason = reason } end,
        GetPlayerPed = function(src) return env.players[tonumber(src)] and 1000 + tonumber(src) or 0 end,
        PlayerPedId = function() return 1001 end,
        PlayerId = function() return 1 end,
        GetEntityCoords = function(entity) return env.coords[entity] or H.vec(0, 0, 0) end,
        GetEntityHeading = function() return 0.0 end,
        GetVehiclePedIsIn = function(ped) return env.pedVehicle[ped] or 0 end,
        GetPedInVehicleSeat = function(veh, seat) return seat == -1 and env.driver[veh] or 0 end,
        GetVehicleNumberPlateText = function(veh) return env.plates[veh] end,
        GetVehicleClass = function() return env.vehicleClass or 0 end,
        IsPedInAnyVehicle = function() return env.inVehicle ~= false end,
        DoesEntityExist = function(entity) return entity ~= nil and entity ~= 0 end,
        NetworkGetNetworkIdFromEntity = function(entity) return entity + 10000 end,
        NetToVeh = function(netId) return netId - 10000 end,
        SetVehicleNumberPlateText = function(veh, plate) env.setPlates = env.setPlates or {} env.setPlates[veh] = plate end,
        GetStreetNameAtCoord = function() return 11, 22 end,
        GetStreetNameFromHashKey = function(hash)
            return ({ [11] = 'Vespucci Blvd', [22] = 'Legion Sq' })[hash] or ''
        end,
        GetPlayerServerId = function(id) return id end,
        vector3 = H.vec, vector4 = H.vec, vec3 = H.vec,
        BoxZone = zone('box'),
        ComboZone = zone('combo'),
        PolyZone = zone('poly'),
        Citizen = { CreateThread = function(fn) env.threads[#env.threads + 1] = fn end },
        print = function(...)
            local parts = {}
            for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
            env.logs[#env.logs + 1] = table.concat(parts, ' ')
        end,
    }
    for k, v in pairs(globals) do G[k] = v end
    G._G = G
    -- client/main.lua sets these globals; the client tests load only some files
    G.PlayerJob = { type = 'leo', onduty = true, name = 'police', grade = { level = 0 } }
    G.QBCore = QBCore

    --- Run one of the patched files (from the qb-policejob tree, or 'qb-core:<path>') in this environment.
    function env.load(path)
        local src
        if path:sub(1, 8) == 'qb-core:' then src = core.files[path:sub(9)] else src = tr.files[path] end
        assert(src, 'no file ' .. path)
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

    --- Fire an AddEventHandler event (e.g. onServerResourceStart).
    function env.emit(name, ...)
        for _, fn in ipairs(env.handlers[name] or {}) do fn(...) end
    end

    --- Call a QBCore server callback as a client would: returns what it passes to cb.
    function env.call(name, src, ...)
        local fn = assert(env.callbacks[name], 'callback not registered: ' .. name)
        local result
        fn(src, function(...) result = table.pack(...) end, ...)
        assert(result, 'callback ' .. name .. ' did not answer')
        return table.unpack(result, 1, result.n)
    end

    --- Run a QBCore command as src.
    function env.command(name, src, args)
        local cmd = assert(env.commands[name], 'command not registered: ' .. name)
        G.source = src
        local ok, err = pcall(cmd, src, args or {}, '')
        G.source = nil
        if not ok then error(err, 0) end
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
        env.addItems, env.spawned, env.resolved, env.money, env.serverEvents = {}, {}, {}, {}, {}
        env.banking, env.dropped, env.menus = {}, {}, {}
    end

    --- Advance the mocked GetGameTimer (rate limits).
    function env.tick(ms) env.now = env.now + (ms or 5000) end

    return env
end

--- The shared scripts as fxmanifest.lua lists them: config.lua, @qb-core/shared/locale.lua, locales/en.lua, then the
--- other locales (glob order: alphabetical; en.lua again is a no-op because of `Lang = Lang or`).
function H.shared(env)
    env.load('config.lua')
    env.load('qb-core:shared/locale.lua')
    env.load('locales/en.lua')
    local names = {}
    for path in pairs(H.tree(H.POLICE).files) do
        if path:match('^locales/[%w%-]+%.lua$') then names[#names + 1] = path end
    end
    table.sort(names)
    for _, path in ipairs(names) do env.load(path) end
end

--- Load the patched server side in fxmanifest order (server/main.lua, fredpd/server.lua, fredpd/server_*.lua, ...).
function H.server(opts)
    local env = H.env(opts)
    H.shared(env)
    local files = { 'server/main.lua', 'fredpd/server.lua' }
    local extra = {}
    for path in pairs(H.tree(H.POLICE).files) do
        if path:match('^fredpd/server_[%w_]+%.lua$') then extra[#extra + 1] = path end
    end
    table.sort(extra)
    for _, path in ipairs(extra) do files[#files + 1] = path end
    for _, path in ipairs({ 'server/commands.lua', 'server/interactions.lua', 'server/evidence.lua',
        'server/objects.lua', 'server/vehicle.lua' }) do
        files[#files + 1] = path
    end
    for _, path in ipairs(files) do env.load(path) end
    env.FredPD = env.G.FredPD
    env.Bolo = env.G.FredPDBolo
    return env
end

--- Load client files after the shared scripts (and an optional setup(env) before them).
function H.client(files, opts, setup)
    local env = H.env(opts)
    if setup then setup(env) end
    H.shared(env)
    for _, path in ipairs(files) do env.load(path) end
    return env
end

--- Standard cast: 1 officer with every grant used below, 2 officer without grants (qb grade 4), 3 FredPD off duty
--- (qb says on duty), 4 civilian, 5 qb leo off duty, 6 judge, 7 lawyer, 8 tow driver.
function H.cast()
    return {
        [1] = { cid = 'OFF00001', grants = {
            ['perm:police.impound'] = true, ['perm:police.jail'] = true, ['perm:charges.fine'] = true,
            ['perm:police.license'] = true, ['perm:bolo.create'] = true, ['perm:bolo.resolve'] = true,
            ['armory:mrpd'] = true, ['weapon:weapon_pistol'] = true, ['armory:pistol_ammo'] = true,
            ['vehicle:police'] = true, ['vehicle:police3'] = true, ['vehicle:polmav'] = true,
        }, job = { type = 'leo', onduty = true, grade = 0 } },
        [2] = { cid = 'OFF00002', job = { type = 'leo', onduty = true, grade = 4 } },
        [3] = { cid = 'OFF00003', fredpdDuty = false, grants = { ['perm:police.impound'] = true, ['armory:mrpd'] = true,
            ['weapon:weapon_pistol'] = true, ['vehicle:police'] = true }, job = { type = 'leo', onduty = true, grade = 4 } },
        [4] = { cid = 'CIV00004', job = { name = 'unemployed', type = 'none', onduty = false, grade = 0 } },
        [5] = { cid = 'OFF00005', job = { type = 'leo', onduty = false, grade = 4 } },
        [6] = { cid = 'JUD00006', job = { name = 'judge', type = 'none', onduty = true, grade = 0 } },
        [7] = { cid = 'LAW00007', job = { name = 'lawyer', type = 'none', onduty = true, grade = 0 } },
        [8] = { cid = 'TOW00008', job = { name = 'tow', type = 'none', onduty = true, grade = 0 } },
    }
end

--- Put a player at a position (GetEntityCoords of its ped).
function H.at(env, src, x, y, z)
    env.coords[1000 + src] = H.vec(x, y, z)
end

---------------------------------------------------------------------------------------------------------------
-- This file's own suite

local tests = {}

tests['patches: qb-policejob patches apply in name order to the pinned commit'] = function(t)
    H.withTree(function(tr, core)
        t.eq(tr.applied, { 'qb-policejob.10-grants.patch', 'qb-policejob.20-fredpd-replacements.patch',
            'qb-policejob.30-bolo-hooks.patch', 'qb-policejob.40-sv-locale.patch' })
        t.eq(core.applied, { 'qb-core.10-fredpd-items.patch' })
        for _, path in ipairs({ 'fredpd/server.lua', 'fredpd/server_bolo.lua', 'fredpd/client.lua', 'locales/sv.lua' }) do
            t.ok(tr.files[path], 'the patches add ' .. path)
        end
        local manifest = tr.files['fxmanifest.lua']
        local main = manifest:find("'server/main.lua'", 1, true)
        local fred = manifest:find("'fredpd/server.lua'", 1, true)
        local glob = manifest:find("'fredpd/server_*.lua'", 1, true)
        local commands = manifest:find("'server/commands.lua'", 1, true)
        t.ok(main and fred and glob and commands and main < fred and fred < glob and glob < commands,
            'fxmanifest loads fredpd/server.lua right after server/main.lua, then fredpd/server_*.lua')
        t.ok(manifest:find("'fredpd/client.lua'", 1, true), 'fxmanifest lists fredpd/client.lua')
        t.ok(manifest:find("'locales/*.lua'", 1, true), 'locales/sv.lua is picked up by the upstream glob')
    end)
end

tests['patches: a second apply-patches run sees every patch as already applied (no overlapping hunks)'] = function(t)
    H.withTree(function(tr, core)
        for _, name in ipairs(tr.applied) do t.eq(tr.reverse[name], true, name .. ' reverse-applies on the patched tree') end
        for _, name in ipairs(core.applied) do t.eq(core.reverse[name], true, name .. ' reverse-applies') end
    end)
end

tests['patches: FredPD files are plain Lua 5.4 (luac -p) with the SPDX header and no polling loop'] = function(t)
    H.withTree(function(tr)
        for _, path in ipairs({ 'fredpd/server.lua', 'fredpd/server_bolo.lua', 'fredpd/client.lua', 'locales/sv.lua' }) do
            local src = tr.files[path]
            t.ok(src:find('^%-%- SPDX%-License%-Identifier: GPL%-3%.0%-only\n'), path .. ' SPDX header')
            local fn, err = load(src, '@' .. path, 't', {})
            t.ok(fn, path .. ' compiles as Lua 5.4: ' .. tostring(err))
            if tr.luacBin then t.eq(tr.luac[path], true, path .. ' luac -p') end
            t.ok(not src:find('while%s+true'), path .. ' has no polling loop')
            t.ok(not src:find('SetInterval') and not src:find('Citizen%.CreateThread'), path .. ' no timers')
        end
    end)
end

tests['patches: every patched Lua file compiles (luac -p, or after the cfxlua rewrite); script.js parses'] = function(t)
    H.withTree(function(tr, core)
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
        t.ok(count >= 30, 'lua files found: ' .. count)
        table.sort(cfx)
        if tr.luacBin then
            -- luac5.4 rejects these files for upstream cfxlua syntax only (`+=`, backtick hashes, `?.`)
            t.eq(cfx, { 'client/evidence.lua', 'client/interactions.lua', 'client/objects.lua', 'config.lua',
                'server/main.lua' })
            t.eq(core.luac['shared/items.lua'], true, 'qb-core shared/items.lua luac -p')
        end
        if tr.nodeCheck ~= nil then t.eq(tr.nodeCheck, true, 'node --check html/script.js') end
    end)
end

tests['config: config/police.json qbPolicejob section equals the built-in defaults of fredpd/server.lua'] = function(t)
    H.withTree(function()
        local env = H.server({ players = H.cast() })
        local FredPD = env.FredPD
        local decoded = helper.readJson('config/police.json')
        t.eq(FredPD.buildConfig(decoded), FredPD.buildConfig(nil), 'config/police.json changes nothing against the defaults')
        for action, spec in pairs(FredPD.DEFAULTS.actions) do
            t.ok(spec == 'duty' or FredPD.parseGrant(spec), action .. ' has a valid grant')
        end
        -- the shared actions are the qbx ones; the qb-only actions live in the qbPolicejob section
        for action, spec in pairs(decoded.actions) do
            if action:sub(1, 1) ~= '$' then t.eq(FredPD.DEFAULTS.actions[action], spec, 'shared action ' .. action) end
        end
        for _, item in ipairs(decoded.qbPolicejob.armories.mrpd.items) do
            t.ok(item.name == item.name:lower(), 'qb item names are lower case: ' .. item.name)
        end
    end)
end

tests['config: invalid entries are dropped, qbPolicejob overrides, $comment keys ignored'] = function(t)
    H.withTree(function()
        local env = H.server({ players = H.cast() })
        local cfg = env.FredPD.buildConfig({
            actions = { impound = 'nonsense', cuff = 'duty', ['$comment'] = 'x' },
            radar = { cooldownSeconds = -5, maxDistance = 20 },
            qbPolicejob = {
                actions = { jail = 'perm:bad key', search = 'perm:police.search' },
                qbShops = { ['$comment'] = 'x', policearmory = 'mrpd' },
                armories = { ['bad id!'] = { coords = { 1, 2, 3 }, items = {} }, nocoords = { items = {} } },
                maxFine = 0,
            },
        })
        t.eq(cfg.actions.impound, nil)
        t.eq(cfg.actions.jail, nil)
        t.eq(cfg.actions.cuff, 'duty')
        t.eq(cfg.actions.search, 'perm:police.search')
        t.eq(cfg.actions['$comment'], nil)
        t.eq(cfg.qbShops, { policearmory = 'mrpd' })
        t.eq(cfg.armories, {})
        t.eq(cfg.radar, { cooldownSeconds = 60, maxDistance = 20 })
        t.eq(cfg.maxFine, 100000, 'maxFine below 1 keeps the default')
        env.policeConfig = '{not json'
        env.FredPD.resetConfig()
        t.eq(env.FredPD.grantFor('impound'), { 'perm', 'police.impound' }, 'invalid JSON -> defaults')
        t.ok(#env.logs >= 1, 'invalid entries and JSON are warned about')
    end)
end

tests['items: qb-core pd_tablet and pd_ram have the qb-core item shape'] = function(t)
    H.withTree(function(_, core)
        local G = setmetatable({ QBCore = { Shared = {} } }, { __index = _G })
        assert(load(core.files['shared/items.lua'], '@shared/items.lua', 't', G))()
        local items = G.QBCore.Shared.Items
        local tablet, ram, cuffs = items.pd_tablet, items.pd_ram, items.handcuffs
        t.ok(tablet and ram, 'pd_tablet and pd_ram exist')
        for key in pairs(cuffs) do
            t.ok(tablet[key] ~= nil, 'pd_tablet has ' .. key)
            t.ok(ram[key] ~= nil, 'pd_ram has ' .. key)
        end
        t.eq({ tablet.name, tablet.type, tablet.unique, tablet.useable, tablet.shouldClose },
            { 'pd_tablet', 'item', true, true, true })
        t.eq({ ram.name, ram.type, ram.unique, ram.useable }, { 'pd_ram', 'item', true, false })
        t.eq(tablet.label, 'Surfplatta')
        t.eq(ram.label, 'Murbräcka', 'docs/glossary.md §10')
        t.ok(type(tablet.weight) == 'number' and type(ram.weight) == 'number', 'weights are numbers')
        t.ok(not tablet.description:find('!') and not ram.description:find('!'), 'no exclamation marks')
        -- the images exist in qb-inventory at its pin (optional images: reuse)
        local invLock = helper.readJson('deps.lock.json').resources['qb-inventory']
        for _, image in ipairs({ tablet.image, ram.image }) do
            local p = io.popen(("git -C './resources/[upstream]/qb-inventory' cat-file -e %s:html/images/%s 2>&1 && echo yes")
                :format(invLock.commit, image))
            local out = p and p:read('a') or ''
            if p then p:close() end
            if out:find('does not exist', 1, true) or out:find('Not a valid', 1, true) then
                error('qb-inventory has no html/images/' .. image)
            end
        end
    end)
end

if ... then return H end
return tests
