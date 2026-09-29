-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_core/server/audit.lua: entry validation, actor resolution (server-side only) and the insert it queues.
-- The archive move against MariaDB is in core_db_test.lua.
-- Run: lua5.4 tests/lua/run.lua core_audit_test
local Audit = require('server.audit')
local Core = require('server.core')
local Perms = require('server.perms')

local tests = {}

tests['buildRow: full entry in column order'] = function(t)
    local row = Audit.buildRow({ actorCitizenid = 'ABC123', actorDiscord = '9001', action = 'lookup.person',
        targetType = 'person', targetId = 'XYZ789', meta = { query = 'Berg' } })
    t.eq(row, { 'ABC123', '9001', 'lookup.person', 'person', 'XYZ789', '{"query":"Berg"}' })
end

tests['buildRow: system entry, numeric target id, empty strings as NULL'] = function(t)
    local row = Audit.buildRow({ action = 'audit.archive', targetType = 'case', targetId = 42, actorCitizenid = '' })
    t.eq(row[1], nil)
    t.eq(row[2], nil)
    t.eq(row[5], '42')
    t.eq(row[6], nil)
end

tests['buildRow rejects bad input'] = function(t)
    local bad = {
        {},
        { action = '' },
        { action = ('a'):rep(65) },
        { action = 'has space' },
        { action = 'ok', actorDiscord = 'abc' },
        { action = 'ok', targetType = ('t'):rep(33) },
        { action = 'ok', targetId = ('1'):rep(65) },
        { action = 'ok', meta = 'string' },
        { action = 'ok', actorCitizenid = {} },
    }
    for i, e in ipairs(bad) do
        t.ok(not pcall(Audit.buildRow, e), 'case ' .. i)
    end
    t.ok(not pcall(Audit.buildRow, nil))
end

tests['buildRow replaces oversized meta by a marker'] = function(t)
    local row = Audit.buildRow({ action = 'x', meta = { blob = ('x'):rep(Audit.MAX_META_BYTES) } })
    local meta = json.decode(row[6])
    t.eq(meta.truncated, true)
    t.ok(meta.bytes > Audit.MAX_META_BYTES)
end

--- Stub MySQL.insert (callback form) and collect the queued inserts.
local function withInsert(fn)
    local inserts = {}
    local saved = rawget(_G, 'MySQL')
    rawset(_G, 'MySQL', { insert = function(sql, params, cb)
        inserts[#inserts + 1] = { sql = sql, params = params }
        cb(#inserts)
    end })
    local ok, err = pcall(fn, inserts)
    rawset(_G, 'MySQL', saved)
    if not ok then error(err, 0) end
    return inserts
end

tests['write binds NULLs into the SQL, not into the params'] = function(t)
    local inserts = withInsert(function()
        t.eq(Audit.write({ action = 'mirror.backfill', targetType = 'mirror', meta = { persons = 3 } }), true)
    end)
    t.eq(#inserts, 1)
    t.ok(inserts[1].sql:find('VALUES (NULL, NULL, ?, ?, NULL, ?)', 1, true), inserts[1].sql)
    t.eq(inserts[1].params, { 'mirror.backfill', 'mirror', '{"persons":3}' })
end

tests['write refuses an invalid entry without touching the DB'] = function(t)
    local savedWarn = Core.warn
    local warned = 0
    Core.warn = function() warned = warned + 1 end
    local inserts = withInsert(function()
        t.eq(Audit.write({ action = 'bad action' }), false)
    end)
    Core.warn = savedWarn
    t.eq(#inserts, 0)
    t.eq(warned, 1)
end

tests['audit(src, ...) takes the actor from qbx_core and the identifiers, never from arguments'] = function(t)
    local savedPd, savedDiscord = Core.getPlayerData, Perms.getDiscordId
    Core.getPlayerData = function(src) return src == 5 and { citizenid = 'REAL123' } or nil end
    Perms.getDiscordId = function(src) return src == 5 and '9005' or nil end
    local ok, err = pcall(function()
        local inserts = withInsert(function()
            Audit.audit(5, 'lookup.vehicle', 'vehicle', 'ABC12D', { citizenid = 'SPOOFED' })
            Audit.audit(0, 'system.thing')
            Audit.audit('5', 'lookup.person', 'person', 'X')
        end)
        t.eq(inserts[1].params, { 'REAL123', '9005', 'lookup.vehicle', 'vehicle', 'ABC12D', '{"citizenid":"SPOOFED"}' })
        t.ok(inserts[2].sql:find('VALUES (NULL, NULL, ?, NULL, NULL, NULL)', 1, true), inserts[2].sql)
        t.eq(inserts[3].params[1], 'REAL123', 'string src')
    end)
    Core.getPlayerData, Perms.getDiscordId = savedPd, savedDiscord
    if not ok then error(err, 0) end
end

tests['archiveOlderThan validates days before touching the DB'] = function(t)
    t.ok(not pcall(Audit.archiveOlderThan, 0))
    t.ok(not pcall(Audit.archiveOlderThan, -5))
    t.ok(not pcall(Audit.archiveOlderThan, 'x'))
end

return tests
