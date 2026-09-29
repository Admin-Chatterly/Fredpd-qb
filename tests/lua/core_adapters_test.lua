-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_core adapters (task 0.6): loader selection from integrations.json, aliases, unknown names, one warning per
-- missing resource, no-op fallbacks, and implemented methods only running while their resource is started.
-- Run: lua5.4 tests/lua/run.lua core_adapters_test
local Loader = require('adapters.loader')
local Base = require('adapters.base')
local helper = require('helper')

local tests = {}

--- A logger that records messages.
local function recorder()
    local log = { warns = {}, errors = {}, debugs = {} }
    log.warn = function(fmt, ...) log.warns[#log.warns + 1] = fmt:format(...) end
    log.error = function(fmt, ...) log.errors[#log.errors + 1] = fmt:format(...) end
    log.debug = function(fmt, ...) log.debugs[#log.debugs + 1] = fmt:format(...) end
    return log
end

--- Run fn with GetResourceState answering from `states` (default 'missing').
local function withStates(states, fn)
    local saved = rawget(_G, 'GetResourceState')
    rawset(_G, 'GetResourceState', function(name) return states[name] or 'missing' end)
    local ok, err = pcall(fn)
    rawset(_G, 'GetResourceState', saved)
    if not ok then error(err, 0) end
end

--- Fresh adapter modules (each define() keeps its own "warned" flag).
local function freshRequire(name)
    package.loaded[name] = nil
    return require(name)
end

tests['every kind has a none adapter and every stub file loads'] = function(t)
    for _, kind in ipairs(Base.KINDS) do
        local none = require(Loader.moduleName(kind, 'none'))
        t.eq(none.kind, kind)
        t.eq(none.name, 'none')
    end
    for _, spec in ipairs({ { 'housing', 'ps-housing' }, { 'housing', 'qbx_properties' }, { 'housing', 'ox_doorlock-only' },
        { 'garage', 'qbx_garages' }, { 'prison', 'qbx_prison' }, { 'prison', 'qbx_police-jail' } }) do
        local a = require(Loader.moduleName(spec[1], spec[2]))
        t.eq(a.kind, spec[1])
        t.eq(a.name, spec[2])
        t.eq(a.stub, true)
        t.ok(type(a.resource) == 'string')
    end
end

tests['moduleName maps dashes to underscores'] = function(t)
    t.eq(Loader.moduleName('housing', 'ps-housing'), 'adapters.housing.ps_housing')
    t.eq(Loader.moduleName('housing', 'ox_doorlock-only'), 'adapters.housing.ox_doorlock_only')
end

tests['the default config loads its adapters; missing resources warn once each'] = function(t)
    local cfg = helper.readJson('config/integrations.json')
    local log = recorder()
    withStates({ qbx_garages = 'started' }, function()
        local active = Loader.load(cfg, { log = log, require = freshRequire })
        t.eq(active.housing.name, 'ps-housing')
        t.eq(active.garage.name, 'qbx_garages')
        t.eq(active.prison.name, 'qbx_prison')
        -- init again (e.g. a second load): still one warning per adapter
        active.housing.init(log)
        active.prison.init(log)
    end)
    t.eq(#log.warns, 2, table.concat(log.warns, ' | '))
    t.ok(log.warns[1]:find('ps-housing', 1, true))
    t.ok(log.warns[2]:find('qbx_prison', 1, true))
    t.eq(#log.debugs, 5, 'stub notices are debug level')
end

tests['a starting resource does not warn'] = function(t)
    local log = recorder()
    withStates({ ['ps-housing'] = 'starting', qbx_garages = 'started', qbx_prison = 'started' }, function()
        Loader.load(helper.readJson('config/integrations.json'), { log = log, require = freshRequire })
    end)
    t.eq(#log.warns, 0)
end

tests['a resource ensured after fredpd_core is checked again later, not warned about at once'] = function(t)
    local log = recorder()
    local timers = {}
    local defer = function(ms, fn) timers[#timers + 1] = { ms = ms, fn = fn } end
    local states = { ['ps-housing'] = 'stopped', qbx_garages = 'uninitialized', qbx_prison = 'stopped' }
    withStates(states, function()
        Loader.load(helper.readJson('config/integrations.json'), { log = log, require = freshRequire, defer = defer })
        t.eq(#log.warns, 0, 'no warning while fredpd_core is still starting')
        t.eq(#timers, 3)
        t.eq(timers[1].ms, Base.DEFERRED_CHECK_MS)
        -- Later in server.cfg: ps-housing and qbx_garages start, qbx_prison never does.
        states['ps-housing'], states.qbx_garages = 'started', 'started'
        for _, timer in ipairs(timers) do timer.fn() end
    end)
    t.eq(#log.warns, 1, table.concat(log.warns, ' | '))
    t.ok(log.warns[1]:find('qbx_prison is stopped', 1, true), log.warns[1])
end

tests['a call while the resource is down reports it once (shared with the deferred check)'] = function(t)
    local log = recorder()
    local timers = {}
    local adapter = Base.define({ kind = 'housing', name = 'late', resource = 'late_housing', methods = {
        unlock = function() return true end,
    } })
    local states = { late_housing = 'stopped' }
    withStates(states, function()
        adapter.init(log, function(_, fn) timers[#timers + 1] = fn end)
        t.eq(adapter.unlock('p1', 1), false)
        t.eq(adapter.unlock('p1', 1), false)
        timers[1]()
        t.eq(#log.warns, 1)
        states.late_housing = 'started'
        t.eq(adapter.unlock('p1', 1), true)
    end)
    t.eq(#log.warns, 1)
end

tests['missing, unknown and unsafe names fall back to none with a warning'] = function(t)
    local log = recorder()
    withStates({}, function()
        local active = Loader.load({ housing = 'nope', garage = '../../server/core', prison = 42 },
            { log = log, require = freshRequire })
        t.eq(active.housing.name, 'none')
        t.eq(active.garage.name, 'none')
        t.eq(active.prison.name, 'none', 'non-string value means none, silently')
    end)
    t.eq(#log.warns, 2)
    local all = Loader.load(nil, { log = recorder(), require = freshRequire })
    t.eq(all.housing.name, 'none')
end

tests['alias qbx_police -> qbx_police-jail'] = function(t)
    withStates({ qbx_policejob = 'started' }, function()
        local active = Loader.load({ prison = 'qbx_police' }, { log = recorder(), require = freshRequire })
        t.eq(active.prison.name, 'qbx_police-jail')
        t.eq(Loader.get('prison').name, 'qbx_police-jail')
    end)
end

tests['no-op fallbacks per kind'] = function(t)
    withStates({}, function()
        local active = Loader.load({ housing = 'ps-housing', garage = 'qbx_garages', prison = 'qbx_prison' },
            { log = recorder(), require = freshRequire })
        t.eq(active.housing.getDoorForProperty('p1'), nil)
        t.eq(active.housing.unlock('p1', 1), false)
        t.eq(active.housing.getAddresses('C1'), {})
        t.eq(active.garage.onParked(function() end), false)
        t.eq(active.garage.onTakenOut(function() end), false)
        t.eq(active.prison.jail(1, 10, {}), false)
        t.eq(active.housing.available(), false)
    end)
    t.eq(Loader.get('unknown-kind'), nil)
end

tests['implemented methods run only while the resource is started; errors fall back'] = function(t)
    local calls = 0
    local log = recorder()
    local adapter = Base.define({ kind = 'prison', name = 'test', resource = 'test_prison', methods = {
        jail = function(src, minutes)
            calls = calls + 1
            if minutes < 0 then error('negative') end
            return src == 1
        end,
    } })
    local states = { test_prison = 'stopped' }
    withStates(states, function()
        adapter.init(log)
        t.eq(adapter.jail(1, 5, {}), false, 'stopped: no-op')
        states.test_prison = 'started'
        t.eq(adapter.jail(1, 5, {}), true)
        t.eq(adapter.jail(2, 5, {}), false)
        t.eq(adapter.jail(1, -1, {}), false, 'error -> no-op')
        t.eq(adapter.getDoorForProperty, nil, 'prison adapters have no housing methods')
    end)
    t.eq(calls, 3)
    t.eq(#log.warns, 1)
    t.eq(#log.errors, 1)
end

tests['register exports getAdapter'] = function(t)
    local saved = rawget(_G, 'exports')
    local exported = {}
    rawset(_G, 'exports', function(name, f) exported[name] = f end)
    Loader.register()
    rawset(_G, 'exports', saved)
    t.eq(exported.getAdapter, Loader.get)
end

return tests
