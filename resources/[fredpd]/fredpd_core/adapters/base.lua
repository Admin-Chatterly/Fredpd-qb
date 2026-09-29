-- SPDX-License-Identifier: GPL-3.0-only
-- Adapter interfaces for third-party integrations (IMPLEMENTATION.md §9, task 0.6). See adapters/README.md.
-- One adapter per kind is active, chosen by config/integrations.json. An adapter is built with M.define: methods it
-- does not implement, and every method while its resource is not started, fall back to the kind's no-op, so callers
-- never need to know which script (if any) is installed.

local Core = require 'server.core'

local M = {}

M.KINDS = { 'housing', 'garage', 'prison' }

--- A configured resource that is not running yet when fredpd_core starts may simply be ensured later in
--- server.cfg. It is checked again once, this long after fredpd_core's start, before warning.
M.DEFERRED_CHECK_MS = 15000

--- One-shot timer (never a loop). Outside FiveM (tests) there is no SetTimeout: the loader passes its own.
local function defaultDefer(ms, fn)
    if type(SetTimeout) == 'function' then SetTimeout(ms, fn) end
end

--- The interface of each kind with its no-op behaviour. Keep adapters/README.md in step.
M.INTERFACES = {
    housing = {
        --- ox_doorlock door ids of a property, or nil when unknown.
        getDoorForProperty = function(_propertyId) return nil end,
        --- Unlock a property's entrance for a breach; true when it was unlocked.
        unlock = function(_propertyId, _src) return false end,
        --- Addresses of a citizen for the person page: { { propertyId, label }, ... }.
        getAddresses = function(_citizenid) return {} end,
    },
    garage = {
        --- Register cb(plate, src, garageName) for "vehicle parked"; true when the hook is installed.
        onParked = function(_cb) return false end,
        --- Register cb(plate, src, garageName) for "vehicle taken out"; true when the hook is installed.
        onTakenOut = function(_cb) return false end,
    },
    prison = {
        --- Jail a player; charges = { { code, label }, ... }. true when the prison script accepted it.
        jail = function(_src, _minutes, _charges) return false end,
    },
}

--- Build an adapter.
--- spec = { kind, name, resource = 'resource name' | nil, stub = boolean, task = 'N.N' | nil, methods = { ... } }
--- @return table adapter { kind, name, resource, stub, state(), available(), init(log), <interface methods> }
function M.define(spec)
    local defaults = M.INTERFACES[spec.kind]
    assert(defaults, 'unknown adapter kind ' .. tostring(spec.kind))
    local methods = spec.methods or {}
    local log = Core -- anything with warn/error/debug(fmt, ...); the loader may pass its own
    local warned = false

    local adapter = { kind = spec.kind, name = spec.name, resource = spec.resource, stub = spec.stub == true }

    --- GetResourceState of the backing resource ('started' for adapters without one).
    function adapter.state()
        if not spec.resource then return 'started' end
        return GetResourceState(spec.resource)
    end

    function adapter.available()
        return adapter.state() == 'started'
    end

    --- The ONE warning about the backing resource (whichever check sees it first).
    local function warnUnavailable(state)
        if warned then return end
        warned = true
        log.warn('%s adapter "%s": resource %s is %s; %s integration is disabled (no-op)',
            spec.kind, spec.name, spec.resource, tostring(state), spec.kind)
    end

    local function runningOrComing(state)
        return state == 'started' or state == 'starting'
    end

    --- Called once by the loader while fredpd_core starts. A resource that is not installed ('missing') is reported
    --- at once. One that exists but is not running may be ensured after fredpd_core, so it is looked at again once
    --- after M.DEFERRED_CHECK_MS; a call made while it is still down reports it too.
    --- @param logger table|nil { warn, error, debug }
    --- @param defer function|nil (ms, fn) one-shot timer, default SetTimeout
    function adapter.init(logger, defer)
        log = logger or log
        if spec.resource and not warned then
            local state = adapter.state()
            if state == 'missing' then
                warnUnavailable(state)
            elseif not runningOrComing(state) then
                (defer or defaultDefer)(M.DEFERRED_CHECK_MS, function()
                    local later = adapter.state()
                    if not runningOrComing(later) then warnUnavailable(later) end
                end)
            end
        end
        if adapter.stub then
            log.debug('%s adapter "%s" is a stub until task %s; its calls are no-ops', spec.kind, spec.name,
                tostring(spec.task))
        end
    end

    for name, fallback in pairs(defaults) do
        local impl = methods[name]
        adapter[name] = function(...)
            if impl then
                local state = adapter.state()
                if state == 'started' then
                    local ok, a, b = pcall(impl, ...)
                    if ok then return a, b end
                    log.error('%s adapter "%s".%s failed: %s', spec.kind, spec.name, name, tostring(a))
                else
                    warnUnavailable(state)
                end
            end
            return fallback(...)
        end
    end
    return adapter
end

return M
