-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_records test harness (docs/modules/records.md), used two ways:
--  * `require('records_env_test')` from tests/lua/records_*_test.lua returns the harness H (a module require passes
--    its name as `...`);
--  * run.lua's `dofile` (no `...`) returns this file's own small suite (harness self-checks).
-- H.with(t, fn) runs fn(t, env, mods) against a real MariaDB (tests/lua/mysql_shim.lua runs the migrations into
-- fredpd_test_records_lua, reset once per run, every session at time_zone '+02:00') with FiveM mocked:
-- exports.fredpd_core (hasGrant, getTier, getCitizenId, canView/canViewMany evaluated by shared/canview.lua with the
-- seeded default rules, audit capture, refreshPlate = the real mirror code, getAdapter housing), exports.fredpd_bolo
-- (checkPlate, checkPerson, hasVisibleBolo, getBolosFor), GetResourceState, LoadResourceFile (config/formats.json), lib.print.
-- Skips with one notice when MariaDB is unreachable.
-- Golden files (test/golden/*.json, parsed by contract.test.ts) are compared, not written: a difference fails the
-- test. FREDPD_UPDATE_GOLDEN=1 rewrites them instead.
local shim = require('mysql_shim')
local helper = require('helper')

local H = {}

H.DB = 'fredpd_test_records_lua'
H.ROOT = './resources/[fredpd]/fredpd_records/'
H.GOLDEN = H.ROOT .. 'test/golden/'
H.MODULES = { 'server.common', 'server.caserefs', 'server.search', 'server.lookupflag', 'server.summary', 'server.cases',
    'server.reports', 'server.charges', 'server.export', 'server.poi', 'server.shares', 'server.releases' }
H.ISO = '^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$'

-- ox_lib `require '@fredpd_core.shared.x'` -> fredpd_core/shared/x.lua (package.path already has fredpd_core).
package.preload['@fredpd_core.shared.format'] = function() return require('shared.format') end
package.preload['@fredpd_core.shared.time'] = function() return require('shared.time') end
package.preload['@fredpd_core.shared.canview'] = function() return require('shared.canview') end
package.preload['@fredpd_core.shared.sha256'] = function() return require('shared.sha256') end

-- Viewers. 1 IGV patrol (tier 0), 2 Utredning investigator (tier 1), 3 Ledning with records.admin (tier 2),
-- 4 civilian (no grants), 5 officer grants but no character loaded (no citizenid).
-- Phase 5: 1-3 are on duty and hold mdt_page:cases; 1 also charges.fine/charges.apply (patrol), 2 cases.create and
-- charges.apply, 3 everything. `duty` false = off duty. 6 is a second IGV patrol (tier 0) for authorization matrices.
local function defaultPlayers()
    return {
        [1] = { cid = 'REC10001', tier = 0, units = { 'igv' }, duty = true, grants = { 'mdt_page:search', 'unit:igv',
            'mdt_page:cases', 'perm:charges.fine', 'perm:charges.apply', 'perm:cases.create' } },
        [2] = { cid = 'REC10002', tier = 1, units = { 'utredning' }, duty = true,
            grants = { 'intel_tier:1', 'mdt_page:search', 'unit:utredning', 'mdt_page:cases', 'perm:cases.create',
                'perm:charges.apply' } },
        [3] = { cid = 'REC10003', tier = 2, units = { 'ledning' }, duty = true,
            grants = { 'intel_tier:2', 'mdt_page:search', 'perm:records.admin', 'unit:ledning', 'mdt_page:cases',
                'perm:cases.create', 'perm:charges.apply', 'perm:charges.fine' } },
        [4] = { cid = 'CIV40004', tier = 0, units = {}, grants = {} },
        [5] = { cid = nil, tier = 0, units = {}, duty = true, grants = { 'mdt_page:search' } },
        [6] = { cid = 'REC10006', tier = 0, units = { 'igv' }, duty = true, grants = { 'mdt_page:search', 'unit:igv',
            'mdt_page:cases', 'perm:charges.apply' } },
    }
end

H.OFFICERS = {
    { 'REC10001', '100000000000000001', 'Anna Patrull', 'IGV-07', 'igv' },
    { 'REC10002', '100000000000000002', 'Olle Utredare', 'UTR-02', 'utredning' },
    { 'REC10003', '100000000000000003', 'Lena Ledning', 'LED-01', 'ledning' },
    { 'REC10006', '100000000000000006', 'Pelle Patrull', 'IGV-08', 'igv' },
}

-- fredpd_plate_checks is created by fredpd_bolo's 010 migration (§C12). While fredpd_core/migrations/index.json does
-- not list it yet, the harness runs db/migrations/010_plate_checks.sql itself; this copy of its CREATE TABLE is only
-- the last resort when neither file is in the checkout (keep it identical to 010).
H.PLATE_CHECKS_MIGRATION = 'db/migrations/010_plate_checks.sql'
H.PLATE_CHECKS_DDL = [[CREATE TABLE IF NOT EXISTS fredpd_plate_checks (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  plate VARCHAR(16) NOT NULL,
  officer_citizenid VARCHAR(50) NULL,
  hit TINYINT(1) NOT NULL DEFAULT 0,
  bolo_id INT UNSIGNED NULL,
  source VARCHAR(16) NOT NULL DEFAULT 'tablet',
  created_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (id),
  KEY idx_plate_created (plate, created_at),
  KEY idx_officer_created (officer_citizenid, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci]]

local GLOBALS = { 'MySQL', 'LoadResourceFile', 'GetCurrentResourceName', 'exports', 'GetResourceState', 'lib',
    'source', 'CreateThread', 'TriggerEvent', 'TriggerClientEvent', 'GetPlayerPed', 'GetEntityCoords',
    'GetPlayerRoutingBucket', 'GetPlayers', 'GetInvokingResource', 'AddEventHandler', 'GetGameTimer' }

local prepared = nil -- nil: not tried, true: ready, false: failed
local notified = false
H.rules = nil

local function contains(list, v)
    for _, x in ipairs(list or {}) do if x == v then return true end end
    return false
end

--- Fresh copies of the fredpd_records modules (module state: warnings, cached formats/FULLTEXT settings).
function H.freshModules()
    for _, name in ipairs(H.MODULES) do package.loaded[name] = nil end
    local savedPath = package.path
    package.path = H.ROOT .. '?.lua;' .. package.path
    local ok, mods = pcall(function()
        local out = {}
        for _, name in ipairs(H.MODULES) do out[name] = require(name) end
        return out
    end)
    package.path = savedPath
    -- leave nothing behind for other suites that use the same module names
    for _, name in ipairs(H.MODULES) do package.loaded[name] = nil end
    if not ok then error(mods, 0) end
    return mods
end

--- Run server/main.lua (exports registration) with the modules of `mods`.
function H.loadMain(mods)
    for name, m in pairs(mods) do package.loaded[name] = m end
    local ok, res = pcall(dofile, H.ROOT .. 'server/main.lua')
    for name in pairs(mods) do package.loaded[name] = nil end
    if not ok then error(res, 0) end
    return res
end

---------------------------------------------------------------------------------------------------------------
-- Mocked world

function H.makeEnv()
    local CanView = require('shared.canview')
    local Mirror = require('server.mirror')
    local env = {
        players = defaultPlayers(), audits = {}, logs = {}, exported = {}, sql = {},
        calls = { canView = 0, canViewMany = 0, checkPlate = 0, checkPerson = 0, hasVisibleBolo = 0, getBolosFor = 0, refreshPlate = 0,
            getAdapter = 0 },
        resources = { fredpd_core = 'started', fredpd_bolo = 'started' },
        bolos = { plates = {}, persons = {}, lists = {} },
        visOverride = {}, addresses = {}, failMany = false, boloThrows = false, adapterThrows = false,
        -- Phase 5 world: auditDb = also insert audit rows into fredpd_audit (timeline, obehörig sökning);
        -- coords/buckets per src, bank balances per citizenid, captured notifications/pushes/events/jails.
        auditDb = false, coords = {}, buckets = {}, bank = {}, notifies = {}, pushes = {}, events = {}, jails = {},
        evidence = {}, intelNotices = nil, tokens = 0, tokenFails = false, jailResult = false, bankingStarted = true,
        depositFails = false, invoking = nil, gameTimer = 0,
    }

    local function player(src) return env.players[tonumber(src)] end

    function env.viewer(src)
        local p = player(src) or { tier = 0, units = {}, grants = {} }
        return { citizenid = p.cid, tier = p.tier, units = p.units, grants = { grants = p.grants, denied = {} } }
    end

    function env.evaluate(src, rec)
        local o = env.visOverride[tostring(rec.type) .. ':' .. tostring(rec.id)]
        if o then return o end
        return CanView.evaluate(env.viewer(src), rec, H.rules)
    end

    function env.named(action)
        local out = {}
        for _, a in ipairs(env.audits) do if a.action == action then out[#out + 1] = a end end
        return out
    end

    function env.logged(level, needle)
        local n = 0
        for _, l in ipairs(env.logs) do
            if (not level or l.level == level) and (not needle or l.msg:find(needle, 1, true)) then n = n + 1 end
        end
        return n
    end

    local core = {
        hasGrant = function(_, src, t, k)
            local p = player(src)
            return p ~= nil and contains(p.grants, t .. ':' .. tostring(k))
        end,
        getTier = function(_, src) local p = player(src); return p and p.tier or 0 end,
        getCitizenId = function(_, src) local p = player(src); return p and p.cid or nil end,
        canView = function(_, src, rec)
            env.calls.canView = env.calls.canView + 1
            return env.evaluate(src, rec)
        end,
        canViewMany = function(_, src, recs)
            env.calls.canViewMany = env.calls.canViewMany + 1
            if env.failMany then error('No such export canViewMany in resource fredpd_core', 0) end
            local out = {}
            for i, rec in ipairs(recs) do out[i] = env.evaluate(src, rec) end
            return out
        end,
        audit = function(_, src, action, targetType, targetId, meta)
            env.audits[#env.audits + 1] = { src = src, action = action, targetType = targetType, targetId = targetId,
                meta = meta }
            if env.auditDb then
                local p = player(src)
                local okRun, _, err = shim.run(shim.bind('INSERT INTO fredpd_audit (actor_citizenid, action, target_type, '
                    .. 'target_id, meta) VALUES (?, ?, ?, ?, ?);', { p and p.cid or nil, action, targetType,
                        targetId ~= nil and tostring(targetId) or nil, meta and json.encode(meta) or nil }), H.DB)
                if not okRun then error('audit insert failed: ' .. tostring(err), 0) end
            end
            return true
        end,
        refreshPlate = function(_, plate)
            env.calls.refreshPlate = env.calls.refreshPlate + 1
            return Mirror.refreshPlate(plate)
        end,
        getUnits = function(_, src) local p = player(src); return p and p.units or {} end,
        isOnDuty = function(_, src) local p = player(src); return p ~= nil and p.duty == true end,
        L = function(_, key, vars) return key .. (vars and (' ' .. json.encode(vars)) or '') end,
        getAdapter = function(_, kind)
            env.calls.getAdapter = env.calls.getAdapter + 1
            if kind == 'prison' then
                return { kind = 'prison', jail = setmetatable({}, { __call = function(_, target, minutes, charges)
                    env.jails[#env.jails + 1] = { target = target, minutes = minutes, charges = charges }
                    return env.jailResult
                end }) }
            end
            if kind ~= 'housing' then return nil end
            -- Functions in a table returned across resources arrive as msgpack function references: tables with a
            -- __call metamethod (citizenfx scheduler.lua funcref_mt), never plain Lua functions.
            return {
                kind = 'housing',
                getAddresses = setmetatable({ __cfx_functionReference = 'fredpd_core:1' }, {
                    __call = function(_, cid)
                        if env.adapterThrows then error('ps-housing export missing', 0) end
                        return env.addresses[cid] or {}
                    end,
                }),
            }
        end,
    }

    local bolo = {
        checkPlate = function(_, plate)
            env.calls.checkPlate = env.calls.checkPlate + 1
            if env.boloThrows then error('No such export checkPlate in resource fredpd_bolo', 0) end
            return env.bolos.plates[plate]
        end,
        checkPerson = function(_, cid)
            env.calls.checkPerson = env.calls.checkPerson + 1
            if env.boloThrows then error('No such export checkPerson in resource fredpd_bolo', 0) end
            return env.bolos.persons[cid]
        end,
        -- An explicit env.bolos.lists entry wins; otherwise the live BOLO of the check maps, filtered with canView
        -- the way fredpd_bolo's Visibility.record does (unit, issuer as owner).
        -- As fredpd_bolo's hasVisibleBolo: the live BOLO of the check maps, canView on it (unit, issuer as owner).
        hasVisibleBolo = function(_, src, kind, id)
            env.calls.hasVisibleBolo = env.calls.hasVisibleBolo + 1
            if env.boloThrows then error('No such export hasVisibleBolo in resource fredpd_bolo', 0) end
            local b = (kind == 'person' and env.bolos.persons or env.bolos.plates)[id]
            if type(b) ~= 'table' or b.active == false then return false end
            local rec = { type = 'bolo', id = b.id, level = b.level or 0, status = 'open', unit = b.unit,
                ownerCitizenid = type(b.issuedBy) == 'table' and b.issuedBy.citizenid or nil }
            return env.evaluate(src, rec) ~= 'none'
        end,
        getBolosFor = function(_, src, kind, id)
            env.calls.getBolosFor = env.calls.getBolosFor + 1
            if env.boloThrows then error('No such export getBolosFor in resource fredpd_bolo', 0) end
            local list = env.bolos.lists[kind .. ':' .. id]
            if type(list) == 'function' then return list(src) end
            if list then return list end
            local b = (kind == 'person' and env.bolos.persons or env.bolos.plates)[id]
            if type(b) ~= 'table' then return {} end
            local rec = { type = 'bolo', id = b.id, level = b.level or 0, status = b.active == false and 'closed' or 'open',
                unit = b.unit, ownerCitizenid = type(b.issuedBy) == 'table' and b.issuedBy.citizenid or nil }
            if env.evaluate(src, rec) == 'none' then return {} end
            return { b }
        end,
    }

    local shimLoad = LoadResourceFile
    local formatsText = helper.readFile('config/formats.json')

    local function byCid(cid)
        for src, p in pairs(env.players) do
            if p.cid == cid and p.online ~= false then return src, p end
        end
        return nil
    end
    local function qbxPlayer(src, p)
        return { PlayerData = { source = src, citizenid = p.cid }, Functions = {
            RemoveMoney = function(account, amount)
                assert(account == 'bank')
                local have = env.bank[p.cid] or 0
                if have < amount then return false end
                env.bank[p.cid] = have - amount
                return true
            end,
            AddMoney = function(account, amount)
                assert(account == 'bank')
                env.bank[p.cid] = (env.bank[p.cid] or 0) + amount
                return true
            end,
        } }
    end
    local qbx = {
        GetPlayerByCitizenId = function(_, cid)
            local src, p = byCid(cid)
            return src and qbxPlayer(src, p) or nil
        end,
        GetPlayer = function(_, src)
            local p = player(src)
            if not p or not p.cid or p.online == false then return nil end
            return qbxPlayer(tonumber(src), p)
        end,
    }
    local records = {
        -- CSPRNG stand-in for server/random.js: 32 bytes from /dev/urandom, base64url.
        randomToken = function(_, n)
            if env.tokenFails then error('No such export randomToken in resource fredpd_records', 0) end
            env.tokens = env.tokens + 1
            local f = assert(io.open('/dev/urandom', 'rb'))
            local bytes = f:read(n or 32)
            f:close()
            local alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'
            local bits, out = {}, {}
            for i = 1, #bytes do
                local b = bytes:byte(i)
                for k = 7, 0, -1 do bits[#bits + 1] = (b >> k) & 1 end
            end
            for i = 1, #bits, 6 do
                local v = 0
                for k = 0, 5 do v = v * 2 + (bits[i + k] or 0) end
                out[#out + 1] = alphabet:sub(v + 1, v + 1)
            end
            return table.concat(out)
        end,
    }
    local mdt = {
        pushToOpenTablets = function(_, topic, payload, filter)
            local targets = {}
            for src in pairs(env.players) do
                if filter == nil or filter(src) then targets[#targets + 1] = src end
            end
            table.sort(targets)
            env.pushes[#env.pushes + 1] = { topic = topic, payload = payload, targets = targets }
            return #targets
        end,
    }
    local forensics = {
        listCaseEvidence = function(_, _src, input)
            return { ok = true, data = { items = env.evidence[input.caseId] or {}, total = 0, page = 1 } }
        end,
    }
    local intel = {
        getPersonNotices = function(_, _src, _cid) return env.intelNotices or {} end,
    }
    local banking = {
        addAccountMoney = function(_, account, amount)
            env.deposits = env.deposits or {}
            if env.depositFails then return false end
            env.deposits[#env.deposits + 1] = { account = account, amount = amount }
            return true
        end,
    }
    env.resources.fredpd_mdt = 'started'
    env.resources.fredpd_forensics = 'started'
    env.resources['Renewed-Banking'] = 'started'

    env.globals = {
        exports = setmetatable({ fredpd_core = core, fredpd_bolo = bolo, qbx_core = qbx, fredpd_records = records,
            fredpd_mdt = mdt, fredpd_forensics = forensics, fredpd_intel = intel, ['Renewed-Banking'] = banking }, {
            __call = function(_, name, fn) env.exported[name] = fn end,
        }),
        GetResourceState = function(name) return env.resources[name] or 'missing' end,
        LoadResourceFile = function(res, path)
            if res == 'fredpd_core' and path == 'config/integrations.json' then
                return env.integrationsText or helper.readFile('config/integrations.json')
            end
            if res == 'fredpd_core' and path == 'config/formats.json' then
                if env.formatsText ~= nil then return env.formatsText or nil end
                return formatsText
            end
            return shimLoad(res, path)
        end,
        CreateThread = function(fn) fn() end,
        TriggerEvent = function(name, ...) env.events[#env.events + 1] = { name = name, args = { ... } } end,
        TriggerClientEvent = function(name, target, data)
            if name == 'ox_lib:notify' then env.notifies[#env.notifies + 1] = { target = target, data = data } end
        end,
        GetPlayerPed = function(src) return env.players[tonumber(src)] and (tonumber(src) + 1000) or 0 end,
        GetEntityCoords = function(ped)
            local c = env.coords[ped - 1000] or { x = 0.0, y = 0.0, z = 0.0 }
            return { x = c.x or c[1], y = c.y or c[2], z = c.z or c[3] }
        end,
        GetPlayerRoutingBucket = function(src) return env.buckets[tonumber(src)] or 0 end,
        GetPlayers = function()
            local list = {}
            for src in pairs(env.players) do list[#list + 1] = tostring(src) end
            table.sort(list)
            return list
        end,
        GetInvokingResource = function() return env.invoking end,
        AddEventHandler = function() end,
        GetGameTimer = function() return env.gameTimer end,
        lib = {
            print = setmetatable({}, { __index = function(_, level)
                return function(msg) env.logs[#env.logs + 1] = { level = level, msg = msg } end
            end }),
        },
    }
    return env
end

--- Record every SQL statement the modules send (after the shim is installed).
local function captureSql(env)
    for _, kind in ipairs({ 'query', 'single', 'scalar', 'insert', 'update' }) do
        local api = MySQL[kind]
        local raw = api.await
        local function wrapped(sql, params)
            env.sql[#env.sql + 1] = { kind = kind, sql = sql, params = params }
            if env.failSql and sql:find(env.failSql, 1, true) then error('simulated database failure', 0) end
            return raw(sql, params)
        end
        MySQL[kind] = setmetatable({ await = wrapped }, { __call = function(_, sql, params, cb)
            if type(params) == 'function' then params, cb = nil, params end
            local r = wrapped(sql, params)
            if cb then cb(r) end
            return r
        end })
    end
    local rawTx = MySQL.transaction.await
    local function tx(queries, params)
        for _, q in ipairs(queries) do
            env.sql[#env.sql + 1] = { kind = 'transaction', sql = type(q) == 'string' and q or (q.query or q[1]),
                params = type(q) == 'table' and (q.values or q[2]) or params }
        end
        if env.onTransaction then env.onTransaction(queries) end
        return rawTx(queries, params)
    end
    MySQL.transaction = setmetatable({ await = tx }, { __call = function(_, queries, params, cb)
        local r = tx(queries, params)
        if cb then cb(r) end
        return r
    end })
    -- env.yield: every statement yields first (coroutine interleaving = two pool connections, see records_cases_test)
    for _, kind in ipairs({ 'query', 'single', 'scalar', 'insert', 'update', 'transaction' }) do
        local api = MySQL[kind]
        local inner = api.await
        local function yielding(sql, params)
            if env.yield and coroutine.isyieldable() then coroutine.yield(kind) end
            return inner(sql, params)
        end
        MySQL[kind] = setmetatable({ await = yielding }, getmetatable(api))
        getmetatable(MySQL[kind]).__call = function(_, sql, params, cb)
            if type(params) == 'function' then params, cb = nil, params end
            local r = yielding(sql, params)
            if cb then cb(r) end
            return r
        end
    end
end

---------------------------------------------------------------------------------------------------------------
-- Database

local function run(sql)
    local ok, out, err = shim.run(sql, H.DB)
    if not ok then error(err ~= '' and err or out, 0) end
    return out
end
H.run = run

--- Clean slate for the tables this module reads (schema stays); officers re-seeded; AUTO_INCREMENTs reset so
--- ids in golden files are stable.
function H.resetData()
    local parts = {
        'DELETE FROM fredpd_records', 'DELETE FROM fredpd_report_drafts', 'DELETE FROM fredpd_reports',
        'DELETE FROM fredpd_case_subjects', 'DELETE FROM fredpd_case_assignees',
        'DELETE FROM fredpd_cases', 'DELETE FROM fredpd_persons', 'DELETE FROM fredpd_vehicles_idx',
        'DELETE FROM fredpd_officers', 'DELETE FROM fredpd_plate_checks', 'DELETE FROM fredpd_audit',
        'DELETE FROM fredpd_bolos', 'DELETE FROM fredpd_poi', 'DELETE FROM fredpd_shares',
        'DELETE FROM fredpd_release_requests', "DELETE FROM fredpd_sequences WHERE seq_type = 'case'",
        'ALTER TABLE fredpd_cases AUTO_INCREMENT = 1', 'ALTER TABLE fredpd_records AUTO_INCREMENT = 1',
        'ALTER TABLE fredpd_plate_checks AUTO_INCREMENT = 1', 'ALTER TABLE fredpd_bolos AUTO_INCREMENT = 1',
        'ALTER TABLE fredpd_reports AUTO_INCREMENT = 1', 'ALTER TABLE fredpd_poi AUTO_INCREMENT = 1',
        'ALTER TABLE fredpd_shares AUTO_INCREMENT = 1', 'ALTER TABLE fredpd_release_requests AUTO_INCREMENT = 1',
    }
    for _, o in ipairs(H.OFFICERS) do
        parts[#parts + 1] = shim.bind('INSERT INTO fredpd_officers (citizenid, discord_id, display_name, callsign, unit) '
            .. 'VALUES (?, ?, ?, ?, ?)', o)
    end
    run(table.concat(parts, ';\n') .. ';')
end

--- Multi-row INSERT in one client call. rows = arrays aligned with cols (nil -> NULL; the first column must be
--- set, since the shim binds positionally only when params[1] is not nil).
function H.insert(tbl, cols, rows)
    if #rows == 0 then return end
    local tuples = {}
    for i, r in ipairs(rows) do
        assert(r[1] ~= nil, 'first column must not be nil')
        tuples[i] = shim.bind('(' .. ('?, '):rep(#cols):sub(1, -3) .. ')', r)
    end
    run(('INSERT INTO %s (%s) VALUES %s;'):format(tbl, table.concat(cols, ', '), table.concat(tuples, ',\n')))
end

--- Persons: { citizenid, firstname, lastname, birthdate, personnummer, gender, phone }.
function H.persons(rows)
    H.insert('fredpd_persons', { 'citizenid', 'firstname', 'lastname', 'birthdate', 'personnummer', 'gender', 'phone' },
        rows)
end

--- Vehicles: { plate, citizenid, model }.
function H.vehicles(rows)
    H.insert('fredpd_vehicles_idx', { 'plate', 'citizenid', 'model' }, rows)
end

--- Case: { case_number, title, status, level, unit, owner, updated_at, assignees = { cid... },
---         subjects = { { 'person'|'vehicle', id, role } } }. Returns its id.
function H.case(c)
    H.insert('fredpd_cases', { 'case_number', 'title', 'status', 'level', 'unit', 'owner_citizenid', 'updated_at' },
        { { c[1], c[2], c[3], c[4], c[5], c[6], c[7] or '2026-09-01 10:00:00' } })
    local id = tonumber(MySQL.scalar.await('SELECT id FROM fredpd_cases WHERE case_number = ?', { c[1] }))
    for _, cid in ipairs(c.assignees or {}) do
        H.insert('fredpd_case_assignees', { 'case_id', 'citizenid' }, { { id, cid } })
    end
    for _, s in ipairs(c.subjects or {}) do
        H.insert('fredpd_case_subjects', { 'case_id', 'subject_type', 'subject_id', 'role' }, { { id, s[1], s[2], s[3] or 'other' } })
    end
    return id
end

--- Report row with fixed times: { case_id, n, report_number, title, body, level, author, created_at }. Returns its id.
function H.report(r)
    H.insert('fredpd_reports', { 'case_id', 'n', 'report_number', 'title', 'body', 'level', 'author_citizenid',
        'created_at', 'updated_at' }, { { r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8] or '2026-09-02 09:00:00',
        r[8] or '2026-09-02 09:00:00' } })
    return tonumber(MySQL.scalar.await('SELECT id FROM fredpd_reports WHERE report_number = ?', { r[3] }))
end

--- Audit row with a fixed time: { actor, action, target_type, target_id, meta table, created_at }.
function H.auditRow(a)
    H.insert('fredpd_audit', { 'actor_citizenid', 'action', 'target_type', 'target_id', 'meta', 'created_at' },
        { { a[1], a[2], a[3], a[4], a[5] and json.encode(a[5]) or nil, a[6] } })
end

--- A few people for Phase 5 tests (RP501 Sara Svensson, RP502 Omar Nilsson, RP503 Eva Ek, RP504 Ali Berg).
function H.fewPeople()
    H.persons({
        { 'RP501', 'Sara', 'Svensson', '1990-01-01', '19900101-1234', 1, '0701234567' },
        { 'RP502', 'Omar', 'Nilsson', '1985-05-05', '19850505-5678', 0, '0707654321' },
        { 'RP503', 'Eva', 'Ek', '1970-07-07', '19700707-7777', 1, '0700000000' },
        { 'RP504', 'Ali', 'Berg', '2000-02-02', '20000202-2222', 0, '0701111111' },
    })
    H.vehicles({ { 'ABC123', 'RP501', 'sultan' } })
end

--- Run fn inside coroutines that yield before every SQL statement, alternating (round robin) until all finish:
--- a faithful model of two oxmysql pool connections (every shim statement is its own client session).
--- Returns the results in order.
function H.interleave(env, fns)
    env.yield = true
    local cos, results, done = {}, {}, 0
    for i, fn in ipairs(fns) do cos[i] = coroutine.create(fn) end
    local alive = #cos
    local guard = 0
    while done < alive do
        guard = guard + 1
        assert(guard < 10000, 'interleave did not finish')
        for i, co in ipairs(cos) do
            if coroutine.status(co) == 'suspended' then
                local ok, res = coroutine.resume(co)
                if not ok then env.yield = false error(res, 0) end
                if coroutine.status(co) == 'dead' then
                    results[i] = res
                    done = done + 1
                end
            end
        end
    end
    env.yield = false
    return results
end

--- The 200-person seed: 20 last names x 10 first names, RP001..RP200, deterministic birthdates/personnummer.
H.LAST = { 'Andersson', 'Berg', 'Bergström', 'Berglund', 'Bernhardsson', 'Öberg', 'Johansson', 'Karlsson',
    'Nilsson', 'Eriksson', 'Larsson', 'Olsson', 'Persson', 'Svensson', 'Gustafsson', 'Pettersson', 'Lindberg', 'Ek',
    'Li', 'De Geer' }
H.FIRST = { 'Anna', 'Bo', 'Berit', 'Erik', 'Lars', 'Karin', 'Maria', 'Johan', 'Will', 'Sara' }

function H.seedPeople()
    local rows, people = {}, {}
    local i = 0
    for _, last in ipairs(H.LAST) do
        for _, first in ipairs(H.FIRST) do
            i = i + 1
            local cid = ('RP%03d'):format(i)
            local year, month, day = 1960 + i % 40, i % 12 + 1, i % 28 + 1
            local birthdate = ('%04d-%02d-%02d'):format(year, month, day)
            local pnr = ('%04d%02d%02d-%04d'):format(year, month, day, i)
            rows[i] = { cid, first, last, birthdate, pnr, i % 2, ('070%07d'):format(i) }
            people[i] = { citizenid = cid, firstname = first, lastname = last, birthdate = birthdate, personnummer = pnr }
        end
    end
    H.persons(rows)
    return people
end

---------------------------------------------------------------------------------------------------------------
-- Runner

--- Run fn(t, env, mods) with MariaDB + mocks installed; restores every global afterwards.
function H.with(t, fn)
    local ok, reason = shim.available()
    if not ok then
        if not notified then
            print(('SKIP records tests: MariaDB unreachable (%s)'):format((reason or ''):gsub('%s+$', '')))
            notified = true
        end
        return
    end
    local saved = {}
    for _, n in ipairs(GLOBALS) do saved[n] = { rawget(_G, n) } end
    local savedDatabase, savedResource = shim.database, shim.resourceName
    local okRun, err = pcall(function()
        shim.install({ database = H.DB, sessionTimeZone = '+02:00' })
        shim.resourceName = 'fredpd_core'
        if prepared == nil then
            prepared = false
            shim.resetDatabase(H.DB, true)
            require('server.db').migrate({ log = function() end, resource = 'fredpd_core' })
            local okFile, migration = pcall(helper.readFile, H.PLATE_CHECKS_MIGRATION)
            run((okFile and migration ~= '') and migration or (H.PLATE_CHECKS_DDL .. ';'))
            local ServerCanView = require('server.canview')
            local rules = {}
            for i, row in ipairs(MySQL.query.await(ServerCanView.RULES_SQL)) do rules[i] = ServerCanView.rowToRule(row) end
            H.rules = rules
            prepared = true
        end
        if not prepared then return end
        local env = H.makeEnv()
        for k, v in pairs(env.globals) do rawset(_G, k, v) end
        rawset(_G, 'source', nil)
        captureSql(env)
        H.resetData()
        fn(t, env, H.freshModules())
    end)
    for n, v in pairs(saved) do rawset(_G, n, v[1]) end
    shim.sessionTimeZone = nil
    shim.database, shim.resourceName = savedDatabase, savedResource
    if not okRun then error(err, 0) end
end

---------------------------------------------------------------------------------------------------------------
-- Shapes (mirror of CaseRefSchema / SearchHit in packages/types/src/mdt.ts; the zod check is contract.test.ts)

--- Sorted keys of a table.
function H.keys(tbl)
    local out = {}
    for k in pairs(tbl) do out[#out + 1] = k end
    table.sort(out)
    return out
end

--- Assert that a CaseRef has exactly the keys its visibility allows (nil fields are absent in Lua).
function H.checkRef(t, ref)
    t.ok(type(ref) == 'table', 'CaseRef is a table')
    local allowed
    if ref.visibility == 'full' then
        allowed = { caseNumber = 'string', id = 'number', level = 'number', role = 'string?', status = 'string',
            title = 'string', visibility = 'string' }
    elseif ref.visibility == 'masked' then
        allowed = { caseNumber = 'string', id = 'number', level = 'number', role = 'string?', status = 'string',
            title = 'string?', visibility = 'string' }
    elseif ref.visibility == 'notice' then
        allowed = { contact = 'table', visibility = 'string' }
        for k, v in pairs(ref.contact) do
            t.ok(k == 'displayName' or k == 'unit', 'notice contact key ' .. tostring(k))
            t.eq(type(v), 'string', 'notice contact ' .. k)
        end
    else
        error('unexpected visibility ' .. tostring(ref.visibility))
    end
    for k, v in pairs(ref) do
        local want = allowed[k]
        t.ok(want ~= nil, ('%s CaseRef must not carry %s'):format(ref.visibility, k))
        t.eq(type(v), (want:gsub('%?$', '')), 'type of ' .. k)
    end
    for k, want in pairs(allowed) do
        if not want:find('?', 1, true) then t.ok(ref[k] ~= nil, ('%s CaseRef lacks %s'):format(ref.visibility, k)) end
    end
    if ref.level ~= nil then t.ok(ref.level == 0 or ref.level == 1 or ref.level == 2, 'level 0..2') end
    if ref.status ~= nil then t.ok(ref.status == 'open' or ref.status == 'closed', 'status') end
end

---------------------------------------------------------------------------------------------------------------
-- Golden files for resources/[fredpd]/fredpd_records/test/contract.test.ts

--- Canonical JSON: sorted keys, empty table = [] (FiveM msgpack sends an empty Lua table as an array), integers
--- without a fraction; nil fields are absent, exactly as they reach JS from Lua.
local function canonical(v, indent)
    indent = indent or ''
    local t = type(v)
    if t == 'nil' then return 'null' end
    if t == 'boolean' then return tostring(v) end
    if t == 'number' then
        if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return ('%d'):format(v) end
        return ('%.17g'):format(v)
    end
    if t == 'string' then return json.encode(v) end
    local inner = indent .. '  '
    if next(v) == nil then return '[]' end
    if v[1] ~= nil then
        local parts = {}
        for i = 1, #v do parts[i] = inner .. canonical(v[i], inner) end
        return '[\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. ']'
    end
    local parts = {}
    for _, k in ipairs(H.keys(v)) do parts[#parts + 1] = inner .. json.encode(k) .. ': ' .. canonical(v[k], inner) end
    return '{\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. '}'
end
H.canonical = canonical

--- Compare `value` with test/golden/<name>.json (canonical JSON). A missing or different file fails the test, so a
--- shape change can never reach disk during a green run (pnpm test runs Vitest before the Lua suites); with
--- FREDPD_UPDATE_GOLDEN=1 the file is rewritten instead. Returns true when written.
function H.golden(t, name, value)
    local text = canonical(value) .. '\n'
    local path = H.GOLDEN .. name .. '.json'
    local f = io.open(path, 'rb')
    local old = f and f:read('a')
    if f then f:close() end
    if old == text then return false end
    if os.getenv('FREDPD_UPDATE_GOLDEN') ~= '1' then
        t.ok(false, ('golden %s %s; review the change and rerun with FREDPD_UPDATE_GOLDEN=1 to rewrite it\n%s')
            :format(path, old and 'differs' or 'is missing', text))
    end
    os.execute("mkdir -p '" .. H.GOLDEN .. "'")
    local out = assert(io.open(path, 'wb'))
    out:write(text)
    out:close()
    print('records tests: wrote ' .. path)
    return true
end

--- A Bolo (BoloSchema) as fredpd_bolo's getBolosFor would return it.
function H.bolo(id, kind, overrides)
    local b = {
        id = id, kind = kind, subject = kind == 'person' and 'Anna Andersson' or 'ABC123 (sultan)',
        reason = 'Efterlyst för rån', level = 0,
        issuedBy = { citizenid = 'REC10002', displayName = 'Olle Utredare', callsign = 'UTR-02', unit = 'utredning' },
        createdAt = '2026-09-20T08:15:00Z', active = true,
    }
    if kind == 'person' then b.citizenid = 'RP001' else b.plate = 'ABC123' end
    for k, v in pairs(overrides or {}) do
        if v == false and k ~= 'active' then b[k] = nil else b[k] = v end
    end
    return b
end

---------------------------------------------------------------------------------------------------------------
-- Own suite (dofile by run.lua)

local tests = {}

tests['harness: canonical JSON sorts keys, keeps [] and drops nil'] = function(t)
    t.eq(canonical({ b = 1, a = { 2, 3 }, c = {}, d = nil }), '{\n  "a": [\n    2,\n    3\n  ],\n  "b": 1,\n  "c": []\n}')
end

tests['harness: the mocked canView uses the seeded default rules'] = function(t)
    H.with(t, function(_, env)
        t.ok(#H.rules >= 10, 'rules loaded from visibility_rules_default.sql')
        local open = { type = 'case', id = 1, level = 0, status = 'open', unit = 'utredning', assignees = {},
            ownerCitizenid = 'REC10002' }
        t.eq(env.evaluate(1, open), 'notice', 'IGV, not assigned, open case')
        t.eq(env.evaluate(2, open), 'full', 'owner')
        t.eq(env.evaluate(3, open), 'full', 'records.admin')
        open.status = 'closed'
        t.eq(env.evaluate(1, open), 'masked', 'closed, tier 0 >= level 0')
    end)
end

if ... then return H end
return tests
