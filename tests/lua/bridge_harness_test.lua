-- SPDX-License-Identifier: GPL-3.0-only
-- Framework bridge test harness (docs/modules/bridge.md). Used two ways, like police_harness_test.lua:
--  * `require('bridge_harness_test')` from the other tests/lua/bridge_*_test.lua files returns the harness H;
--  * run.lua's `dofile` (no `...`) returns this file's own small suite (the harness mocks behave like the sources).
-- H.with(opts, fn) installs FiveM globals (exports, AddEventHandler, TriggerEvent, GetResourceState, SetTimeout,
-- SetConvarReplicated, GetInvokingResource, source), loads server/bridge.lua with opts.cfg and calls fn(env); globals
-- are restored afterwards. Upstream mocks follow the pinned sources (cited per mock).
local H = {}

local GLOBALS = { 'exports', 'AddEventHandler', 'RegisterNetEvent', 'TriggerEvent', 'GetResourceState', 'SetTimeout',
    'SetConvarReplicated', 'GetInvokingResource', 'GetCurrentResourceName', 'source', 'GetGameTimer', 'lib' }

--- exports mock: callable (exports(name, fn) registers an export of the resource under test) and indexable
--- (exports.res:fn(...) calls resources[res].fn(self, ...); an unknown export raises FiveM's message).
function H.exports(resources, exported)
    local function proxy(res)
        return setmetatable({}, { __index = function(_, k)
            local impl = resources[res]
            if impl and impl[k] ~= nil then return impl[k] end
            return function() error(('No such export %s in resource %s'):format(k, res), 2) end
        end })
    end
    return setmetatable({}, {
        __call = function(_, name, fn) exported[name] = fn end,
        __index = function(_, res) return proxy(res) end,
    })
end

--- PlayerData as qb-core builds it (server/player.lua:66-91 job, shared/jobs.lua:14-26 police, charinfo) and as
--- qbx_core does (server/player.lua:217-231, 699-711): the fields FredPD reads are identical.
function H.playerData(src, cid, job, extra)
    local pd = {
        source = src, citizenid = cid, license = 'license:' .. cid:lower(), name = 'account' .. src,
        charinfo = { firstname = 'Anna', lastname = 'Berg', birthdate = '1990-01-01', gender = 1, phone = '0701' },
        job = job or { name = 'police', label = 'Law Enforcement', type = 'leo', onduty = true, isboss = false,
            grade = { name = 'Officer', level = 1 } },
        money = { cash = 100, bank = 1000, crypto = 0 },
    }
    for k, v in pairs(extra or {}) do pd[k] = v end
    return pd
end

--- qb-core mock. players: src -> PlayerData. RemoveMoney follows server/player.lua:209-243 with config.lua:11-12
--- (cash/crypto never below 0, bank not below -5000). GetCoreObject honours filters (shared/main.lua:7-18).
function H.qbCore(players, calls)
    calls = calls or {}
    local function player(pd)
        return {
            PlayerData = pd, Offline = false,
            Functions = {
                -- server/player.lua:185-207: false for an unknown account, else added.
                AddMoney = function(moneytype, amount, reason)
                    calls[#calls + 1] = { 'AddMoney', pd.source, moneytype, amount, reason }
                    moneytype = moneytype:lower()
                    if not pd.money[moneytype] then return false end
                    pd.money[moneytype] = pd.money[moneytype] + amount
                    return true
                end,
                RemoveMoney = function(moneytype, amount, reason)
                    calls[#calls + 1] = { 'RemoveMoney', pd.source, moneytype, amount, reason }
                    moneytype = moneytype:lower()
                    amount = tonumber(amount)
                    if not amount or amount < 0 then return nil end
                    if not pd.money[moneytype] then return false end
                    if (moneytype == 'cash' or moneytype == 'crypto') and pd.money[moneytype] - amount < 0 then return false end
                    if pd.money[moneytype] - amount < -5000 then return false end
                    pd.money[moneytype] = pd.money[moneytype] - amount
                    return true
                end,
            },
        }
    end
    local Functions = {
        GetPlayer = function(source)
            local pd = players[tonumber(source)]
            return pd and player(pd) or nil
        end,
        GetPlayerByCitizenId = function(citizenid)
            for _, pd in pairs(players) do if pd.citizenid == citizenid then return player(pd) end end
            return nil
        end,
        GetPlayers = function()
            local ids = {}
            for src in pairs(players) do ids[#ids + 1] = src end
            return ids
        end,
    }
    local usable = {}
    local res = {
        GetCoreObject = function(_, filters)
            calls[#calls + 1] = { 'GetCoreObject', filters }
            local full = { Functions = Functions, Shared = { Items = {} }, Players = players }
            if not filters then return full end
            local out = {}
            for _, key in ipairs(filters) do out[key] = full[key] end
            return out
        end,
        -- server/functions.lua:491-510 (exported by the loop :735-739): stores { func, resource }.
        CreateUseableItem = function(_, item, data)
            calls[#calls + 1] = { 'CreateUseableItem', item }
            usable[item] = { func = data, resource = GetInvokingResource and GetInvokingResource() or nil }
        end,
    }
    return res, usable
end

--- qbx_core mock (server/functions.lua:86-147, server/player.lua:1371-1423: cash never below 0).
function H.qbxCore(players, calls)
    calls = calls or {}
    local function player(pd) return { PlayerData = pd, Functions = {} } end
    return {
        GetPlayer = function(_, source)
            local pd = players[tonumber(source)]
            return pd and player(pd) or nil
        end,
        GetPlayerByCitizenId = function(_, citizenid)
            for _, pd in pairs(players) do if pd.citizenid == citizenid then return player(pd) end end
            return nil
        end,
        GetQBPlayers = function()
            local out = {}
            for src, pd in pairs(players) do out[src] = player(pd) end
            return out
        end,
        AddMoney = function(_, identifier, moneyType, amount, reason)
            calls[#calls + 1] = { 'AddMoney', identifier, moneyType, amount, reason }
            local pd = players[tonumber(identifier)]
            if not pd or not pd.money[moneyType] then return false end
            pd.money[moneyType] = pd.money[moneyType] + amount
            return true
        end,
        RemoveMoney = function(_, identifier, moneyType, amount, reason)
            calls[#calls + 1] = { 'RemoveMoney', identifier, moneyType, amount, reason }
            local pd = players[tonumber(identifier)]
            if not pd or not pd.money[moneyType] then return false end
            if moneyType == 'cash' and pd.money[moneyType] - amount < 0 then return false end
            pd.money[moneyType] = pd.money[moneyType] - amount
            return true
        end,
    }
end

--- Install globals, load the bridge, run fn(env), restore. opts = { cfg, states = { res = state }, resources =
--- { res = export table }, invoker = 'resource' }.
function H.with(opts, fn)
    local saved = {}
    for _, name in ipairs(GLOBALS) do saved[name] = rawget(_G, name) end
    local env = {
        handlers = {}, emitted = {}, exported = {}, convars = {}, deferred = {}, now = 0,
        logs = { info = {}, warn = {}, error = {}, debug = {} },
        states = opts.states or {}, resources = opts.resources or {},
    }
    local function logger(level)
        return function(fmt, ...)
            local msg = select('#', ...) > 0 and fmt:format(...) or tostring(fmt)
            env.logs[level][#env.logs[level] + 1] = msg
        end
    end
    env.log = { info = logger('info'), warn = logger('warn'), error = logger('error'), debug = logger('debug') }

    rawset(_G, 'exports', H.exports(env.resources, env.exported))
    rawset(_G, 'AddEventHandler', function(name, cb)
        env.handlers[name] = env.handlers[name] or {}
        table.insert(env.handlers[name], cb)
    end)
    rawset(_G, 'RegisterNetEvent', function(name, cb)
        env.net = env.net or {}
        env.net[name] = cb
    end)
    rawset(_G, 'TriggerEvent', function(name, ...)
        env.emitted[#env.emitted + 1] = { name = name, args = table.pack(...) }
    end)
    rawset(_G, 'GetResourceState', function(res) return env.states[res] or 'missing' end)
    rawset(_G, 'SetTimeout', function(ms, cb) env.deferred[#env.deferred + 1] = { ms = ms, cb = cb } end)
    rawset(_G, 'SetConvarReplicated', function(name, value) env.convars[name] = value end)
    rawset(_G, 'GetInvokingResource', function() return env.invoker end)
    rawset(_G, 'GetCurrentResourceName', function() return 'fredpd_core' end)
    rawset(_G, 'GetGameTimer', function() return env.now end)
    rawset(_G, 'lib', opts.lib)
    env.invoker = opts.invoker

    --- Fire an upstream event with `source` set (FiveM sets it per event; '' for server-local ones).
    function env.fire(name, src, ...)
        rawset(_G, 'source', src or '')
        for _, cb in ipairs(env.handlers[name] or {}) do cb(...) end
    end

    --- Emitted events with this name, as arg lists.
    function env.events(name)
        local out = {}
        for _, e in ipairs(env.emitted) do
            if e.name == name then out[#out + 1] = { table.unpack(e.args, 1, e.args.n) } end
        end
        return out
    end

    local Bridge = require('server.bridge')
    env.Bridge = Bridge
    local ok, err = pcall(function()
        Bridge.load(opts.cfg or {}, {
            log = env.log,
            stateOf = function(res) return env.states[res] or 'missing' end,
            defer = function(ms, cb) env.deferred[#env.deferred + 1] = { ms = ms, cb = cb } end,
        })
        if opts.register ~= false then Bridge.register() end
        fn(env)
    end)
    for _, name in ipairs(GLOBALS) do rawset(_G, name, saved[name]) end
    H.reset()
    if not ok then error(err, 0) end
    return env
end

--- For other server tests that run the real fredpd_core audit/perms over a qbx_core mock: load the bridge with the
--- qbx_core framework, quiet, resource states from stateOf (default: qbx_core started). Returns the bridge module.
function H.useQbx(stateOf)
    local quiet = function() end
    local Bridge = require('server.bridge')
    Bridge.load({ framework = 'qbx_core' }, {
        stateOf = stateOf or function(name) return name == 'qbx_core' and 'started' or 'missing' end,
        log = { info = quiet, warn = quiet, error = quiet, debug = quiet }, defer = quiet,
    })
    return Bridge
end

--- Leave the bridge with nothing running, so later test files never inherit this file's mocks by accident.
function H.reset()
    H.useQbx(function() return 'missing' end)
end

--- Count log lines of a level that contain `text`.
function H.count(list, text)
    local n = 0
    for _, line in ipairs(list) do
        if line:find(text, 1, true) then n = n + 1 end
    end
    return n
end

if ... == 'bridge_harness_test' then return H end

-- Own suite: the harness mocks keep the upstream semantics the bridge relies on.
local tests = {}

tests['qb-core mock: RemoveMoney refuses cash below 0 and bank below the minus limit'] = function(t)
    local pd = H.playerData(1, 'QB1')
    local core = H.qbCore({ [1] = pd })
    local fns = core.GetCoreObject(nil, { 'Functions' }).Functions
    local p = fns.GetPlayer(1)
    t.eq(p.Functions.RemoveMoney('cash', 101, 'x'), false)
    t.eq(p.Functions.RemoveMoney('bank', 6000, 'x'), true)
    t.eq(p.Functions.RemoveMoney('bank', 1, 'x'), false, 'below -5000')
    t.eq(p.Functions.RemoveMoney('bank', -1, 'x'), nil)
    t.eq(core.GetCoreObject(nil, { 'Functions' }).Players, nil, 'filters honoured')
end

tests['exports mock: unknown export raises the FiveM message'] = function(t)
    local ex = H.exports({ a = { f = function(_, x) return x end } }, {})
    t.eq(ex.a:f(3), 3)
    local ok, err = pcall(function() return ex.a:g() end)
    t.ok(not ok and tostring(err):find('No such export g in resource a', 1, true), tostring(err))
end

return tests
