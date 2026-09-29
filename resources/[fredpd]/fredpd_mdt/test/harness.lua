-- SPDX-License-Identifier: GPL-3.0-only
-- Test harness for tests/lua/mdt_*_test.lua (plain Lua 5.4, run from the repo root by tests/lua/run.lua): loads fresh
-- copies of the fredpd_mdt server modules and builds a mocked FiveM world — players with grants/duty/officers
-- (fredpd_core exports), an ox_inventory, the routed resources (fredpd_records, fredpd_bolo, fredpd_dispatch,
-- fredpd_forensics), client events, net/local event handlers, lib.callback / lib.addCommand capture and a clock.
-- MySQL is left to the caller (a small in-memory double here, or tests/lua/mysql_shim.lua for the DB tests).
local H = {}

H.ROOT = './resources/[fredpd]/fredpd_mdt/'
H.GOLDEN = H.ROOT .. 'test/golden/'
H.MODULES = { 'config', 'shared.validate', 'server.common', 'server.open', 'server.home', 'server.tablets',
    'server.dispatch' }
H.GLOBALS = { 'exports', 'GetGameTimer', 'TriggerClientEvent', 'TriggerEvent', 'GetResourceState', 'GetPlayers',
    'GetPlayerPed', 'GetVehiclePedIsIn', 'GetEntityModel', 'GetPedInVehicleSeat', 'joaat', 'GetPlayerName',
    'GetPlayerIdentifierByType', 'LoadResourceFile', 'MySQL', 'lib', 'locale', 'source', 'CreateThread',
    'AddEventHandler', 'RegisterNetEvent', 'GetCurrentResourceName' }

package.preload['@fredpd_core.shared.time'] = package.preload['@fredpd_core.shared.time']
    or function() return require('shared.time') end
package.preload['@fredpd_core.shared.locale'] = package.preload['@fredpd_core.shared.locale']
    or function() return require('shared.locale') end

local helper = require('helper')

--- sv.json + the pending files fredpd_mdt uses (sv texts).
H.SV = (function()
    local dict = helper.readJson('locales/sv.json')
    for _, file in ipairs({ 'locales/pending/core.json', 'locales/pending/mdt.json' }) do
        for k, v in pairs(helper.readJson(file)) do
            if type(v) == 'table' and v.sv then dict[k] = v.sv end
        end
    end
    return dict
end)()

---------------------------------------------------------------------------------------------------------------
-- Modules

function H.forget()
    for _, name in ipairs(H.MODULES) do package.loaded[name] = nil end
end

--- Fresh copies of the fredpd_mdt modules (module state: sessions, limiter, caches). Returns { [name] = module }.
function H.load()
    H.forget()
    local savedPath = package.path
    package.path = H.ROOT .. '?.lua;' .. package.path
    local ok, mods = pcall(function()
        local out = {}
        for _, name in ipairs(H.MODULES) do out[name] = require(name) end
        return out
    end)
    package.path = savedPath
    if not ok then error(mods, 0) end
    mods['server.common'].L = require('shared.locale').L
    return mods
end

--- dofile a fredpd_mdt script (server/main.lua, client/main.lua) with the module path in place.
function H.run(file)
    local savedPath = package.path
    package.path = H.ROOT .. '?.lua;' .. package.path
    local ok, res = pcall(dofile, H.ROOT .. file)
    package.path = savedPath
    if not ok then error(res, 0) end
    return res
end

---------------------------------------------------------------------------------------------------------------
-- World

local function copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end
H.copy = copy

--- Default players. 1 IGV officer with a registered tablet, 2 Ledning (tablets.manage) with a tablet, 3 off duty,
--- 4 civilian with a tablet but no grants, 5 officer without a tablet, 6 IGV officer with a revoked tablet,
--- 7 officer without a fredpd_officers row, holding a tablet without serial.
function H.players()
    local igv = { ['mdt_page:search'] = true, ['mdt_page:bolos'] = true, ['mdt_page:alerts'] = true,
        ['perm:bolo.create'] = true, ['perm:bolo.resolve'] = true }
    local ledning = copy(igv)
    ledning['mdt_page:*'] = true
    ledning['perm:tablets.manage'] = true
    ledning['perm:evidence.link'] = true
    return {
        [1] = { cid = 'MDT10001', duty = true, grants = copy(igv), units = { 'igv' }, tier = 0,
            officer = { citizenid = 'MDT10001', displayName = 'Anna B.', callsign = 'IGV-07', unit = 'igv' },
            items = { { slot = 3, name = 'pd_tablet', count = 1, metadata = { serial = 'SP-AAAA-0001', owner = 'MDT10001' } } } },
        [2] = { cid = 'MDT10002', duty = true, grants = ledning, units = { 'ledning', 'igv' }, tier = 2,
            officer = { citizenid = 'MDT10002', displayName = 'Eva L.', callsign = 'LED-01', unit = 'ledning' },
            items = { { slot = 1, name = 'pd_tablet', count = 1, metadata = { serial = 'SP-AAAA-0002', owner = 'MDT10002' } } } },
        [3] = { cid = 'MDT10003', duty = false, grants = copy(igv), units = { 'igv' }, tier = 0,
            officer = { citizenid = 'MDT10003', displayName = 'Bo C.', callsign = 'IGV-03', unit = 'igv' },
            items = { { slot = 1, name = 'pd_tablet', count = 1, metadata = { serial = 'SP-AAAA-0003' } } } },
        [4] = { cid = 'CIV40004', duty = false, grants = {}, units = {}, tier = 0,
            items = { { slot = 2, name = 'pd_tablet', count = 1, metadata = { serial = 'SP-AAAA-0004' } } } },
        [5] = { cid = 'MDT10005', duty = true, grants = copy(igv), units = { 'span' }, tier = 1,
            officer = { citizenid = 'MDT10005', displayName = 'Cia D.', callsign = 'SPAN-02', unit = 'span' },
            items = {} },
        [6] = { cid = 'MDT10006', duty = true, grants = copy(igv), units = { 'igv' }, tier = 0,
            officer = { citizenid = 'MDT10006', displayName = 'Dan E.', callsign = 'IGV-11', unit = 'igv' },
            items = { { slot = 1, name = 'pd_tablet', count = 1, metadata = { serial = 'SP-AAAA-0006' } } } },
        [7] = { cid = 'MDT10007', duty = true, grants = copy(igv), units = { 'tekniker' }, tier = 0,
            items = { { slot = 1, name = 'pd_tablet', count = 1, metadata = {} } } },
    }
end

--- Tablet rows for the in-memory MySQL double: serial -> { revoked, owner_citizenid }.
function H.tabletRows()
    return {
        ['SP-AAAA-0001'] = { revoked = 0, owner_citizenid = 'MDT10001' },
        ['SP-AAAA-0002'] = { revoked = 0, owner_citizenid = 'MDT10002' },
        ['SP-AAAA-0003'] = { revoked = 0, owner_citizenid = 'MDT10003' },
        ['SP-AAAA-0004'] = { revoked = 0, owner_citizenid = 'MDT10001' },
        ['SP-AAAA-0006'] = { revoked = 1, owner_citizenid = 'MDT10006' },
    }
end

--- In-memory MySQL double answering only the open flow's tablet lookup.
function H.memoryMySQL(env)
    local function single(sql, params)
        env.queries[#env.queries + 1] = sql
        if env.onQuery then env.onQuery(sql, params) end
        if env.dbDown then error('Lost connection to MySQL server', 0) end
        if sql:find('FROM fredpd_tablets WHERE serial = ?', 1, true) then
            local row = env.tablets[params[1]]
            return row and copy(row) or nil
        end
        error('unexpected SQL in memory double: ' .. sql, 0)
    end
    return { single = setmetatable({ await = single }, { __call = function(_, ...) return single(...) end }),
        ready = function(cb) cb() end }
end

--- Build the mocked world. opts.mysql = false to leave MySQL alone (DB tests install the shim themselves).
function H.world(opts)
    opts = opts or {}
    local env = {
        now = 100000, players = H.players(), tablets = H.tabletRows(), queries = {}, client = {}, audits = {},
        calls = {}, handlers = {}, net = {}, callbacks = {}, commands = {}, exported = {}, logs = {}, events = {},
        replies = {}, resources = { fredpd_core = 'started', ox_inventory = 'started', fredpd_records = 'started',
            fredpd_bolo = 'started', fredpd_dispatch = 'started', fredpd_forensics = 'started' },
        vehicles = {}, units = nil,
    }

    local function player(src) return env.players[tonumber(src)] end

    local function has(p, t, k)
        if not p then return false end
        return p.grants[t .. ':' .. k] == true or p.grants[t .. ':*'] == true
    end

    local core = {
        hasGrant = function(_, src, t, k)
            if env.coreDown then error('fredpd_core is not running', 0) end
            return has(player(src), t, k)
        end,
        isOnDuty = function(_, src) local p = player(src); return p ~= nil and p.duty == true end,
        getCitizenId = function(_, src) local p = player(src); return p and p.cid or nil end,
        getOfficer = function(_, src) local p = player(src); return p and copy(p.officer) or nil end,
        getUnits = function(_, src) local p = player(src); return p and copy(p.units) or {} end,
        getGrants = function(_, src)
            local p = player(src)
            local list = {}
            for k, v in pairs(p and p.grants or {}) do if v then list[#list + 1] = k end end
            table.sort(list)
            return { grants = list, denied = {}, tier = p and p.tier or 0, units = p and copy(p.units) or {},
                computedAt = '2026-09-29T08:00:00Z' }
        end,
        audit = function(_, src, action, targetType, targetId, meta)
            env.audits[#env.audits + 1] = { src = src, action = action, targetType = targetType, targetId = targetId,
                meta = meta }
            if env.auditImpl then return env.auditImpl(src, action, targetType, targetId, meta) end
            return true
        end,
    }

    local function slotsOf(src)
        local p = player(src)
        return p and p.items or {}
    end
    local inventory = {
        GetItemCount = function(_, src, item)
            if env.inventoryDown then error('ox_inventory is not running', 0) end
            local n = 0
            for _, s in ipairs(slotsOf(src)) do if s.name == item then n = n + (s.count or 1) end end
            return n
        end,
        GetSlot = function(_, src, slot)
            for _, s in ipairs(slotsOf(src)) do if s.slot == slot then return copy(s) end end
            return nil
        end,
        Search = function(_, src, kind, item)
            assert(kind == 'slots', 'Search kind')
            local out = {}
            for _, s in ipairs(slotsOf(src)) do if s.name == item then out[#out + 1] = copy(s) end end
            return out
        end,
        CanCarryItem = function(_, src, item, count)
            env.calls[#env.calls + 1] = { res = 'ox_inventory', fn = 'CanCarryItem', src = src, input = { item, count } }
            local p = player(src)
            return p ~= nil and p.full ~= true
        end,
        AddItem = function(_, src, item, count, metadata)
            env.calls[#env.calls + 1] = { res = 'ox_inventory', fn = 'AddItem', src = src,
                input = { item = item, count = count, metadata = copy(metadata) } }
            if env.addItemFails then return false, 'inventory_full' end
            local p = player(src)
            local items = p.items
            items[#items + 1] = { slot = 40 + #items, name = item, count = count, metadata = copy(metadata) }
            return true
        end,
    }

    --- Routed resource: records the call; answers env.replies['res:fn'] (a table or a function) or echoes.
    local function routed(res, names)
        local t = {}
        for _, fn in ipairs(names) do
            t[fn] = function(_, src, input)
                env.calls[#env.calls + 1] = { res = res, fn = fn, src = src, input = input }
                local reply = env.replies[res .. ':' .. fn]
                if type(reply) == 'function' then return reply(src, input) end
                if reply ~= nil then return copy(reply) end
                return { ok = true, data = { routed = res .. ':' .. fn } }
            end
        end
        return t
    end

    env.exports = setmetatable({
        fredpd_core = core,
        ox_inventory = inventory,
        fredpd_records = routed('fredpd_records',
            { 'search', 'getPersonSummary', 'getVehicleSummary', 'getHomeCases', 'countMyOpenCases' }),
        fredpd_bolo = routed('fredpd_bolo', { 'listBolos', 'createBolo', 'resolveBolo', 'plateCheck' }),
        fredpd_dispatch = routed('fredpd_dispatch', { 'listAlerts', 'takeAlert', 'leaveAlert', 'closeAlert', 'getUnits' }),
        fredpd_forensics = routed('fredpd_forensics', { 'listEvidence', 'getEvidence', 'linkEvidence' }),
    }, { __call = function(_, name, fn) env.exported[name] = fn end })

    local unitsJson = helper.readFile('config/units.json')

    env.globals = {
        exports = env.exports,
        GetGameTimer = function() return env.now end,
        TriggerClientEvent = function(name, src, ...)
            env.client[#env.client + 1] = { name = name, src = src, args = { ... } }
        end,
        TriggerEvent = function(name, ...) env.events[#env.events + 1] = { name = name, args = { ... } } end,
        GetResourceState = function(name) return env.resources[name] or 'missing' end,
        GetPlayers = function()
            local ids = {}
            for src in pairs(env.players) do ids[#ids + 1] = tostring(src) end
            table.sort(ids)
            return ids
        end,
        GetPlayerName = function(src) local p = player(src); return p and ('Player' .. tostring(src)) or nil end,
        GetPlayerIdentifierByType = function(src, kind)
            if kind ~= 'discord' or not player(src) then return nil end
            return ('discord:%d'):format(900000000000001000 + tonumber(src))
        end,
        GetPlayerPed = function(src) return player(src) and (1000 + tonumber(src)) or 0 end,
        GetVehiclePedIsIn = function(ped)
            for entity, v in pairs(env.vehicles) do
                for _, occupant in pairs(v.seats) do if occupant == ped then return entity end end
            end
            return 0
        end,
        GetEntityModel = function(entity) local v = env.vehicles[entity]; return v and v.model or 0 end,
        GetPedInVehicleSeat = function(entity, seat) local v = env.vehicles[entity]; return v and v.seats[seat] or 0 end,
        joaat = function(name) return 'hash:' .. name:lower() end,
        LoadResourceFile = function(resource, path)
            if resource == 'fredpd_core' and path == 'config/units.json' then
                if env.units == false then return nil end -- file missing
                return env.units or unitsJson
            end
            return nil
        end,
        locale = function(key) return H.SV[key] or key end,
        CreateThread = function(fn) fn() end,
        AddEventHandler = function(name, fn)
            env.handlers[name] = env.handlers[name] or {}
            table.insert(env.handlers[name], fn)
        end,
        RegisterNetEvent = function(name, fn)
            env.net[name] = true
            env.handlers[name] = env.handlers[name] or {}
            table.insert(env.handlers[name], fn)
        end,
        GetCurrentResourceName = function() return 'fredpd_mdt' end,
        lib = {
            callback = { register = function(name, fn) env.callbacks[name] = fn end },
            addCommand = function(name, def, fn) env.commands[name] = { def = def, fn = fn } end,
            print = setmetatable({}, { __index = function(_, level)
                return function(msg) env.logs[#env.logs + 1] = { level = level, msg = msg } end
            end }),
        },
    }
    if opts.mysql ~= false then env.globals.MySQL = H.memoryMySQL(env) end

    --- Fire an event's handlers as FiveM would (global `source` set during the call).
    function env.fire(name, eventSource, ...)
        local saved = rawget(_G, 'source')
        rawset(_G, 'source', eventSource)
        local ok, err = pcall(function(...)
            for _, fn in ipairs(env.handlers[name] or {}) do fn(...) end
        end, ...)
        rawset(_G, 'source', saved)
        if not ok then error(err, 0) end
    end

    --- Client events sent to `src` (optionally by name).
    function env.sent(src, name)
        local out = {}
        for _, e in ipairs(env.client) do
            if (src == nil or e.src == src) and (name == nil or e.name == name) then out[#out + 1] = e end
        end
        return out
    end

    function env.callsTo(res, fn)
        local out = {}
        for _, c in ipairs(env.calls) do
            if c.res == res and (fn == nil or c.fn == fn) then out[#out + 1] = c end
        end
        return out
    end

    --- Seat `src` in a vehicle entity of `model` (seat -1 = driver).
    function env.seat(src, entity, model, seat)
        env.vehicles[entity] = env.vehicles[entity] or { model = 'hash:' .. model, seats = {} }
        env.vehicles[entity].seats[seat or -1] = 1000 + src
    end

    return env
end

--- Run fn(env, mods) with the world installed and fresh modules; every global is restored afterwards.
function H.with(opts, fn)
    if type(opts) == 'function' then opts, fn = {}, opts end
    local saved = {}
    for _, n in ipairs(H.GLOBALS) do saved[n] = { rawget(_G, n) } end
    local ok, err = pcall(function()
        local env = H.world(opts)
        for k, v in pairs(env.globals) do rawset(_G, k, v) end
        rawset(_G, 'source', nil)
        if opts.before then opts.before(env) end
        local mods = H.load()
        fn(env, mods)
    end)
    H.forget()
    for n, v in pairs(saved) do rawset(_G, n, v[1]) end
    if not ok then error(err, 0) end
end

--- Open a tablet for src through the real open flow (asserts success). Returns the payload.
function H.openTablet(mods, src, req)
    local res = mods['server.open'].open(src, req or { mode = 'item' })
    if type(res) ~= 'table' or res.error then
        error(('open(%s) failed: %s'):format(tostring(src), helper.dump(res)), 2)
    end
    return res
end

---------------------------------------------------------------------------------------------------------------
-- Golden JSON for test/contract.test.ts (rewritten only on change; empty tables are [] as in bolo's golden files)

local function sortedKeys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
    return out
end

function H.canonical(v, indent)
    indent = indent or ''
    local inner = indent .. '  '
    if type(v) ~= 'table' then return json.encode(v) end
    if next(v) == nil then return '[]' end
    if #v > 0 then
        local parts = {}
        for i = 1, #v do parts[i] = inner .. H.canonical(v[i], inner) end
        return '[\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. ']'
    end
    local parts = {}
    for _, k in ipairs(sortedKeys(v)) do parts[#parts + 1] = inner .. json.encode(k) .. ': ' .. H.canonical(v[k], inner) end
    return '{\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. '}'
end

function H.writeGolden(name, value)
    local text = H.canonical(value) .. '\n'
    local path = H.GOLDEN .. name .. '.json'
    local f = io.open(path, 'rb')
    local old = f and f:read('a')
    if f then f:close() end
    if old == text then return false end
    os.execute("mkdir -p '" .. H.GOLDEN .. "'")
    local out = assert(io.open(path, 'wb'))
    out:write(text)
    out:close()
    print('fredpd_mdt test: wrote ' .. path)
    return true
end

return H
