-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_core/server/canview.lua (server wrapper): DB row mapping, the viewer built from the grant cache and
-- qbx_core, fail-closed behaviour, and the fredpd:rulesChanged guard. The shared fixtures run through the wrapper
-- with the rules as DB rows would deliver them. Loading the real seed rules from MariaDB is in core_db_test.lua.
-- Run: lua5.4 tests/lua/run.lua core_canview_test
local ServerCanView = require('server.canview')
local Perms = require('server.perms')
local Core = require('server.core')
local Grants = require('shared.grants')
local helper = require('helper')

local fixtures = helper.readJson('packages/types/test/fixtures/canView.fixtures.json')

local tests = {}

--- A fixture rule as a fredpd_visibility_rules row from oxmysql (snake_case, TINYINT, NULL -> nil).
local function asRow(rule)
    return {
        id = rule.id, record_type = rule.recordType, level = rule.level, record_status = rule.recordStatus,
        viewer_condition = rule.viewerCondition, condition_value = rule.conditionValue, result = rule.result,
        priority = rule.priority, enabled = rule.enabled and 1 or 0,
    }
end

--- Run fn with the viewer of player 1 stubbed from a fixture viewer.
local function asPlayer(viewer, fn)
    local savedPd, savedRaw = Core.getPlayerData, Perms.rawSet
    local set = Grants.empty()
    set.grants = viewer.grants.grants or {}
    set.denied = viewer.grants.denied or {}
    set.tier = viewer.tier
    set.units = viewer.units
    Core.getPlayerData = function(src) return src == 1 and { citizenid = viewer.citizenid } or nil end
    Perms.rawSet = function(src) return src == 1 and set or nil end
    local ok, err = pcall(fn)
    Core.getPlayerData, Perms.rawSet = savedPd, savedRaw
    if not ok then error(err, 0) end
end

tests['rowToRule maps snake_case, TINYINT and NULL'] = function(t)
    t.eq(ServerCanView.rowToRule({ id = 3, record_type = 'case', level = nil, record_status = 'open',
        viewer_condition = 'unit', condition_value = nil, result = 'full', priority = 80, enabled = 1 }), {
        id = 3, recordType = 'case', recordStatus = 'open', viewerCondition = 'unit', result = 'full', priority = 80,
        enabled = true,
    })
    local r = ServerCanView.rowToRule({ id = '4', record_type = '*', level = '1', record_status = 'any',
        viewer_condition = 'perm', condition_value = 'records.admin', result = 'masked', priority = '5', enabled = 0 })
    t.eq(r.id, 4)
    t.eq(r.level, 1)
    t.eq(r.priority, 5)
    t.eq(r.enabled, false)
    t.eq(r.conditionValue, 'records.admin')
end

tests['shared fixtures through the wrapper (rules as DB rows)'] = function(t)
    local rules = {}
    for i, rule in ipairs(fixtures.rules) do rules[i] = ServerCanView.rowToRule(asRow(rule)) end
    ServerCanView.setRules(rules)
    for _, c in ipairs(fixtures.cases) do
        asPlayer(c.viewer, function()
            t.eq(ServerCanView.canView(1, c.record), c.expected, c.name)
        end)
    end
end

tests['canViewMany evaluates a page with one viewer lookup'] = function(t)
    local rules = {}
    for i, rule in ipairs(fixtures.rules) do rules[i] = ServerCanView.rowToRule(asRow(rule)) end
    ServerCanView.setRules(rules)
    local c1, c2 = fixtures.cases[1], fixtures.cases[2]
    local lookups = 0
    asPlayer(c1.viewer, function()
        local inner = Core.getPlayerData
        Core.getPlayerData = function(src)
            lookups = lookups + 1
            return inner(src)
        end
        local expected2 = (function()
            -- c2 evaluated as c1's viewer via the single-record API
            return ServerCanView.canView(1, c2.record)
        end)()
        lookups = 0
        t.eq(ServerCanView.canViewMany(1, { c1.record, c2.record, 'junk' }), { c1.expected, expected2, 'none' })
        Core.getPlayerData = inner
    end)
    t.eq(lookups, 1)
end

tests['fail closed: no rules, bad record, unknown player'] = function(t)
    ServerCanView.setRules({})
    local c = fixtures.cases[1]
    asPlayer(c.viewer, function()
        t.eq(ServerCanView.canView(1, c.record), 'none', 'no rules loaded')
        ServerCanView.setRules({ ServerCanView.rowToRule({ id = 1, record_type = '*', record_status = 'any',
            viewer_condition = 'any', result = 'full', priority = 1, enabled = 1 }) })
        t.eq(ServerCanView.canView(1, nil), 'none')
        t.eq(ServerCanView.canView(1, { id = 1 }), 'none', 'record without type')
        -- Player 2 has no grants and no character; a level-2 record is capped to notice.
        t.eq(ServerCanView.canView(2, { type = 'case', id = 1, level = 2, status = 'open' }), 'notice')
        t.eq(ServerCanView.canView(2, { type = 'case', id = 1, level = 0, status = 'open' }), 'full')
    end)
    ServerCanView.setRules({})
end

tests['fredpd:rulesChanged reloads for the server and ignores players'] = function(t)
    local handlers, exported, reloads, warns = {}, {}, 0, {}
    local saved = { AddEventHandler = rawget(_G, 'AddEventHandler'), exports = rawget(_G, 'exports'),
        CreateThread = rawget(_G, 'CreateThread'), source = rawget(_G, 'source') }
    local savedLoad, savedWarn = ServerCanView.loadRules, Core.warn
    rawset(_G, 'AddEventHandler', function(name, h) handlers[name] = h end)
    rawset(_G, 'exports', function(name, f) exported[name] = f end)
    rawset(_G, 'CreateThread', function(f) f() end)
    ServerCanView.loadRules = function() reloads = reloads + 1 end
    Core.warn = function(fmt, ...) warns[#warns + 1] = fmt:format(...) end
    local ok, err = pcall(function()
        ServerCanView.register()
        t.eq(type(exported.canView), 'function')
        t.eq(type(exported.canViewMany), 'function')
        rawset(_G, 'source', '')
        handlers['fredpd:rulesChanged']()
        rawset(_G, 'source', nil)
        handlers['fredpd:rulesChanged']()
        rawset(_G, 'source', 12)
        handlers['fredpd:rulesChanged']()
    end)
    for k, v in pairs(saved) do rawset(_G, k, v) end
    ServerCanView.loadRules, Core.warn = savedLoad, savedWarn
    if not ok then error(err, 0) end
    t.eq(reloads, 2)
    t.eq(#warns, 1)
end

return tests
