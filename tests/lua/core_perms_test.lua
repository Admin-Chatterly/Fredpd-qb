-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_core/server/perms.lua: GrantSet validation/encoding, and the runtime paths (service fetch, cache
-- fallback, push, races, exports, playerDropped, getMyGrants) with FiveM globals stubbed.
-- Run: lua5.4 tests/lua/run.lua core_perms_test
local Perms = require('server.perms')
local Core = require('server.core')
local Grants = require('shared.grants')

local tests = {}

local SET = {
    grants = { 'mdt_page:search', 'unit:igv', 'weapon:*' }, denied = { 'weapon:rifle' }, tier = 1, units = { 'igv' },
    rank = { roleId = '222', key = 'inspektor' }, computedAt = '2026-09-29T12:00:00.000Z',
}

---------------------------------------------------------------------------------------------------------------
-- Stub environment

--- Installs FiveM stubs and Core overrides for the duration of fn; returns the recorder.
local function withRuntime(opts, fn)
    local rec = { clientEvents = {}, serverEvents = {}, sql = {}, exports = {}, handlers = {}, callbacks = {}, warns = {} }
    local globals = {
        CreateThread = function(f) f() end,
        TriggerClientEvent = function(name, src, payload) rec.clientEvents[#rec.clientEvents + 1] = { name, src, payload } end,
        TriggerEvent = function(name, ...) rec.serverEvents[#rec.serverEvents + 1] = { name, ... } end,
        AddEventHandler = function(name, h) rec.handlers[name] = h end,
        exports = function(name, f) rec.exports[name] = f end,
        lib = { callback = { register = function(name, f) rec.callbacks[name] = f end } },
        GetPlayers = function() return opts.players or {} end,
        MySQL = {
            update = { await = function(sql, params) rec.sql[#rec.sql + 1] = { sql, params }; return 1 end },
            scalar = { await = function(sql, params)
                rec.sql[#rec.sql + 1] = { sql, params }
                if opts.scalarError then error('db down') end
                return opts.cacheRow
            end },
        },
        GetGameTimer = function() return rec.time or 0 end,
    }
    local savedGlobals = {}
    for k, v in pairs(globals) do
        savedGlobals[k] = { rawget(_G, k) }
        rawset(_G, k, v)
    end
    local savedCore = { fetch = Core.fetch, discordIdOf = Core.discordIdOf, warn = Core.warn, error = Core.error }
    Core.fetch = opts.fetch or function() return 0, nil end
    Core.discordIdOf = function(src) return (opts.discord or {})[src] end
    Core.warn = function(fmt, ...) rec.warns[#rec.warns + 1] = fmt:format(...) end
    Core.error = Core.warn
    local ok, err = pcall(fn, rec)
    for k, v in pairs(savedGlobals) do rawset(_G, k, v[1]) end
    for k, v in pairs(savedCore) do Core[k] = v end
    if not ok then error(err, 0) end
    return rec
end

local function copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end

---------------------------------------------------------------------------------------------------------------
-- Pure

tests['validateSet accepts a GrantSet and returns a fresh copy'] = function(t)
    local input = copy(SET)
    local set = Perms.validateSet(input)
    t.eq(set, SET)
    set.grants[1] = 'changed'
    t.eq(input.grants[1], 'mdt_page:search', 'input not aliased')
end

tests['validateSet: rank null/sentinel and missing computedAt'] = function(t)
    local input = copy(SET)
    input.rank = setmetatable({}, { __name = 'null' }) -- a table rank without fields is invalid
    t.eq(Perms.validateSet(input), nil)
    input.rank = nil
    input.computedAt = nil
    local set = Perms.validateSet(input)
    t.eq(set.rank, nil)
    t.ok(set.computedAt:match('^%d%d%d%d%-%d%d%-%d%dT'), set.computedAt)
    input.rank = io.stdout -- userdata, like a json.null sentinel
    t.ok(Perms.validateSet(input) ~= nil)
end

tests['validateSet: tier as JSON float, empty lists'] = function(t)
    local set = Perms.validateSet({ grants = {}, denied = {}, tier = 2.0, units = {} })
    t.eq(set.tier, 2)
    t.eq(math.type(set.tier), 'integer')
end

tests['validateSet rejects bad shapes'] = function(t)
    local bad = {
        { 'set', 'not a table' },
        { 'grants', { grants = 'x', denied = {}, tier = 0, units = {} } },
        { 'grants', { grants = { 'nocolon' }, denied = {}, tier = 0, units = {} } },
        { 'grants', { grants = { 'weapon: pistol' }, denied = {}, tier = 0, units = {} } },
        { 'grants', { grants = { a = 'weapon:x' }, denied = {}, tier = 0, units = {} } },
        { 'grants', { denied = {}, tier = 0, units = {} } },
        { 'denied', { grants = {}, denied = { 5 }, tier = 0, units = {} } },
        { 'tier', { grants = {}, denied = {}, tier = 3, units = {} } },
        { 'tier', { grants = {}, denied = {}, tier = 1.5, units = {} } },
        { 'tier', { grants = {}, denied = {}, units = {} } },
        { 'units', { grants = {}, denied = {}, tier = 0, units = { 'ig v' } } },
        { 'rank', { grants = {}, denied = {}, tier = 0, units = {}, rank = { roleId = 1, key = 'x' } } },
    }
    for _, case in ipairs(bad) do
        local set, field = Perms.validateSet(case[2])
        t.eq(set, nil, case[1])
        t.eq(field, case[1])
    end
    local long = {}
    for i = 1, 2001 do long[i] = 'weapon:x' .. i end
    t.eq(Perms.validateSet({ grants = long, denied = {}, tier = 0, units = {} }), nil, 'list too long')
end

tests['encodeSet produces the wire JSON with real arrays'] = function(t)
    local set = Perms.validateSet({ grants = {}, denied = {}, tier = 0, units = {}, computedAt = '2026-01-01T00:00:00Z' })
    t.eq(Perms.encodeSet(set), '{"grants":[],"denied":[],"tier":0,"units":[],"rank":null,"computedAt":"2026-01-01T00:00:00Z"}')
    local full = Perms.validateSet(copy(SET))
    local decoded = json.decode(Perms.encodeSet(full))
    t.eq(Perms.validateSet(decoded), full, 'round trip')
    t.ok(Perms.encodeSet(full):find('"rank":{"roleId":"222","key":"inspektor"}', 1, true))
end

tests['encodeSet escapes strings'] = function(t)
    local set = Perms.validateSet({ grants = { 'perm:a"b' }, denied = {}, tier = 0, units = {}, computedAt = 'x' })
    t.eq(json.decode(Perms.encodeSet(set)).grants, { 'perm:a"b' })
end

tests['isoToDatetime and cacheUpsert'] = function(t)
    t.eq(Perms.isoToDatetime('2026-09-29T12:00:00.000Z'), '2026-09-29 12:00:00')
    t.eq(Perms.isoToDatetime('2026-09-29T12:00:00Z'), '2026-09-29 12:00:00')
    t.eq(Perms.isoToDatetime('2026-09-29T12:00:00+02:00'), '2026-09-29 10:00:00', 'an offset is converted to UTC')
    t.eq(Perms.isoToDatetime('1970-01-01'), nil)
    t.eq(Perms.isoToDatetime('2026-09-29 12:00:00'), nil, 'computedAt must be ISO (with a T)')
    t.eq(Perms.isoToDatetime(nil), nil)
    local set = Perms.validateSet(copy(SET))
    local sql, params = Perms.cacheUpsert('42', set)
    t.ok(sql:find('VALUES (?, ?, ?)', 1, true), sql)
    t.eq(params[1], '42')
    t.eq(params[3], '2026-09-29 12:00:00')
    set.computedAt = 'garbage'
    sql, params = Perms.cacheUpsert('42', set)
    t.ok(sql:find('VALUES (?, ?, UTC_TIMESTAMP())', 1, true), sql)
    t.eq(#params, 2)
end

tests['copySet of nil is an empty set'] = function(t)
    local set = Perms.copySet(nil)
    t.eq(set.grants, {})
    t.eq(set.tier, 0)
    t.eq(set.rank, nil)
end

---------------------------------------------------------------------------------------------------------------
-- Runtime with stubs

tests['load: service answers -> cache, DB write, client push'] = function(t)
    local rec = withRuntime({
        discord = { [101] = '9001' },
        fetch = function(method, path)
            t.eq(method, 'GET')
            t.eq(path, '/internal/grants/9001')
            return 200, { discordId = '9001', member = true, grants = copy(SET) }
        end,
    }, function()
        t.eq(Perms.load(101, true), true)
    end)
    t.eq(Perms.hasGrant(101, 'weapon', 'pistol'), true)
    t.eq(Perms.hasGrant(101, 'weapon', 'rifle'), false, 'deny wins')
    t.eq(Perms.hasGrant('101', 'mdt_page', 'search'), true, 'string src')
    t.eq(Perms.getTier(101), 1)
    t.eq(Perms.getUnits(101), { 'igv' })
    t.eq(Perms.getDiscordId(101), '9001')
    t.eq(#rec.clientEvents, 1)
    t.eq(rec.clientEvents[1][1], 'fredpd:client:grantsChanged')
    t.eq(rec.clientEvents[1][3], SET)
    t.eq(rec.serverEvents[1], { 'fredpd:grantsChanged', 101 })
    t.ok(rec.sql[1][1]:find('fredpd_grant_cache', 1, true))
    t.eq(json.decode(rec.sql[1][2][2]), SET)
end

tests['getGrants returns a copy that cannot change the cache'] = function(t)
    withRuntime({ discord = { [102] = '9002' }, fetch = function() return 200, { grants = copy(SET) } end }, function()
        Perms.load(102, false)
    end)
    local g = Perms.getGrants(102)
    g.grants[#g.grants + 1] = 'perm:intel.command'
    g.denied = {}
    t.eq(Perms.hasGrant(102, 'perm', 'intel.command'), false)
    t.eq(Perms.hasGrant(102, 'weapon', 'rifle'), false)
end

tests['load: service down -> fredpd_grant_cache row + warning'] = function(t)
    local cached = Perms.encodeSet(Perms.validateSet({ grants = { 'unit:span' }, denied = {}, tier = 2, units = { 'span' } }))
    local rec = withRuntime({ discord = { [103] = '9003' }, cacheRow = cached, fetch = function() return 0, { error = 'timeout' } end },
        function()
            t.eq(Perms.load(103, true), false)
        end)
    t.eq(Perms.getTier(103), 2)
    t.eq(Perms.hasGrant(103, 'unit', 'span'), true)
    t.ok(rec.warns[1]:find('unavailable', 1, true), rec.warns[1])
    t.eq(rec.clientEvents[1][1], 'fredpd:client:grantsChanged')
end

tests['load: service down and no cache -> empty set (fail closed)'] = function(t)
    local rec = withRuntime({ discord = { [104] = '9004' }, cacheRow = nil, fetch = function() return 503, nil end }, function()
        Perms.load(104, false)
    end)
    t.eq(Perms.getGrants(104).grants, {})
    t.eq(#rec.warns, 2)
end

tests['load: invalid set from the service falls back to the cache'] = function(t)
    withRuntime({ discord = { [105] = '9005' }, cacheRow = nil, fetch = function() return 200, { grants = { tier = 9 } } end },
        function() Perms.load(105, false) end)
    t.eq(Perms.getTier(105), 0)
end

tests['load: DB error on the fallback path still ends with an empty set'] = function(t)
    withRuntime({ discord = { [106] = '9006' }, scalarError = true, fetch = function() return 0, nil end }, function()
        Perms.load(106, false)
    end)
    t.eq(Perms.getGrants(106).grants, {})
end

tests['load: player without Discord gets an empty set'] = function(t)
    local rec = withRuntime({ discord = {}, fetch = function() error('must not fetch') end }, function()
        t.eq(Perms.load(107, false), false)
    end)
    t.eq(Perms.getGrants(107).grants, {})
    t.ok(rec.warns[1]:find('no Discord', 1, true))
end

tests['a push during an in-flight fetch wins over the older fetch result'] = function(t)
    local pushed = Perms.validateSet({ grants = { 'perm:intel.command' }, denied = {}, tier = 2, units = {} })
    withRuntime({
        discord = { [108] = '9008' },
        fetch = function()
            -- The service pushes while our GET is still on the wire.
            t.eq(Perms.applyGrants('9008', pushed), 1)
            return 200, { grants = copy(SET) }
        end,
    }, function()
        t.eq(Perms.load(108, true), false)
    end)
    t.eq(Perms.hasGrant(108, 'perm', 'intel.command'), true)
    t.eq(Perms.getTier(108), 2)
end

tests['applyGrants updates every online player of that Discord user'] = function(t)
    local rec = withRuntime({ discord = { [110] = '9010', [111] = '9010', [112] = '9099' },
        fetch = function() return 200, { grants = { grants = {}, denied = {}, tier = 0, units = {} } } end }, function(r)
            Perms.load(110, false)
            Perms.load(111, false)
            Perms.load(112, false)
            r.clientEvents = {}
            t.eq(Perms.applyGrants('9010', copy(SET)), 2)
        end)
    t.eq(Perms.getTier(110), 1)
    t.eq(Perms.getTier(111), 1)
    t.eq(Perms.getTier(112), 0)
    t.eq(#rec.clientEvents, 2)
    local last = rec.sql[#rec.sql]
    t.ok(last[1]:find('fredpd_grant_cache', 1, true))
    t.eq(last[2][1], '9010')
end

tests['applyGrants for an offline user still refreshes the cache row'] = function(t)
    local rec = withRuntime({}, function()
        t.eq(Perms.applyGrants('777', copy(SET)), 0)
    end)
    t.eq(rec.sql[1][2][1], '777')
end

tests['applyGrants rejects bad input'] = function(t)
    local rec = withRuntime({}, function()
        t.eq(Perms.applyGrants('abc', copy(SET)), false)
        t.eq(Perms.applyGrants(123, copy(SET)), false)
        t.eq(Perms.applyGrants('1', { grants = {} }), false)
    end)
    t.eq(#rec.sql, 0)
    t.eq(#rec.warns, 3)
end

tests['recompute: selected ids or everyone, returns the count'] = function(t)
    local fetched = {}
    withRuntime({ players = { '120', '121', '122' }, discord = { [120] = '9020', [121] = '9021', [122] = '9022' },
        fetch = function(_, path)
            fetched[#fetched + 1] = path
            return 200, { grants = copy(SET) }
        end }, function()
            t.eq(Perms.recompute({ '9021', 'nope' }), 1)
            t.eq(Perms.recompute(nil), 3)
            t.eq(Perms.recompute({}), 0)
        end)
    t.eq(fetched[1], '/internal/grants/9021')
    t.eq(#fetched, 4)
end

tests['register: exports, playerDropped cleanup, getMyGrants with rate limit'] = function(t)
    local rec = withRuntime({ discord = { [130] = '9030' }, fetch = function() return 200, { grants = copy(SET) } end },
        function(r)
            Perms.register()
            for _, name in ipairs({ 'hasGrant', 'getGrants', 'getTier', 'getUnits', 'applyGrants', 'recomputeGrants' }) do
                t.eq(type(r.exports[name]), 'function', name)
            end
            -- playerJoining loads grants (source is the new player id).
            rawset(_G, 'source', 130)
            r.handlers.playerJoining()
            t.eq(Perms.hasGrant(130, 'unit', 'igv'), true)
            local cb = r.callbacks['fredpd:getMyGrants']
            r.time = 1000
            t.eq(cb(130), SET)
            r.time = 1100
            t.eq(cb(130), SET, 'rate limited: the last copy again, never nil')
            -- A push inside the window drops the memo: the limited caller still sees the new set.
            local changed = copy(SET)
            changed.tier = 2
            Perms.applyGrants('9030', changed)
            r.time = 1150
            t.eq(cb(130).tier, 2)
            r.time = 1400
            t.eq(cb(130).tier, 2)
            r.handlers.playerDropped()
            rawset(_G, 'source', nil)
            t.eq(Perms.hasGrant(130, 'unit', 'igv'), false)
            t.eq(Perms.getTier(130), 0)
            t.eq(cb(999), Perms.copySet(Grants.empty()), 'unknown player gets an empty set')
        end)
    local seen = false
    for _, q in ipairs(rec.sql) do
        if q[1]:find('fredpd_identities', 1, true) and q[1]:find('last_seen', 1, true) then seen = true end
    end
    t.ok(seen, 'last_seen written on join')
end

return tests
