-- SPDX-License-Identifier: GPL-3.0-only
-- Housing adapters (task 6.2, docs/modules/breach.md "Housing adapter"): ps-housing (doors from its getMainDoor
-- export, unlock through ox_doorlock, addresses from its `properties` table — the SQL runs against MariaDB when it
-- is reachable, database fredpd_test_breach_housing), ox_doorlock-only (property → door mapping only; no numeric
-- fallback), the no-op + one warning when the backing resource is not started, and getAddress on every housing adapter.
-- Run: lua5.4 tests/lua/run.lua housing_adapter
local Base = require('adapters.base')
local shim = require('mysql_shim')

local tests = {}

local DB = 'fredpd_test_breach_housing'

local function recorder()
    local log = { warns = {}, errors = {}, debugs = {} }
    log.warn = function(fmt, ...) log.warns[#log.warns + 1] = fmt:format(...) end
    log.error = function(fmt, ...) log.errors[#log.errors + 1] = fmt:format(...) end
    log.debug = function(fmt, ...) log.debugs[#log.debugs + 1] = fmt:format(...) end
    return log
end

local function fresh(name)
    package.loaded[name] = nil
    return require(name)
end

--- Run fn with mocked GetResourceState, exports and MySQL; globals restored afterwards.
--- world = { states = {}, psDoors = { [propertyId] = { [i] = doorId } }, doors = { [id] = { id, name } },
---           rows = { ... } (MySQL.query.await result) }
local function with(world, fn)
    local saved = { GetResourceState = rawget(_G, 'GetResourceState'), exports = rawget(_G, 'exports'),
        MySQL = rawget(_G, 'MySQL'), LoadResourceFile = rawget(_G, 'LoadResourceFile'),
        GetCurrentResourceName = rawget(_G, 'GetCurrentResourceName') }
    world.setStates, world.queries, world.mainDoorCalls = {}, {}, {}
    rawset(_G, 'GetResourceState', function(name) return (world.states or {})[name] or 'missing' end)
    local resources = {
        ['ps-housing'] = {
            getMainDoor = function(_, propertyId, index, isShell)
                world.mainDoorCalls[#world.mainDoorCalls + 1] = { propertyId, index, isShell }
                local list = (world.psDoors or {})[propertyId]
                local id = list and list[index]
                if not id then return nil end
                return { id = id, name = ('ps_mloproperty%s_%s'):format(propertyId, index), state = 1 }
            end,
        },
        ox_doorlock = {
            getDoor = function(_, id) return (world.doors or {})[id] or false end,
            getDoorFromName = function(_, name)
                for _, d in pairs(world.doors or {}) do if d.name == name then return d end end
                return nil
            end,
            setDoorState = function(_, id, state)
                world.setStates[#world.setStates + 1] = { id, state }
                return true
            end,
        },
    }
    rawset(_G, 'exports', setmetatable({}, { __index = function(_, k) return resources[k] end }))
    if not world.realDb then
        rawset(_G, 'MySQL', { query = { await = function(sql, params)
            world.queries[#world.queries + 1] = { sql = sql, params = params }
            return world.rows or {}
        end } })
    end
    local ok, err = pcall(fn)
    for k, v in pairs(saved) do rawset(_G, k, v) end
    if not ok then error(err, 0) end
end

---------------------------------------------------------------------------------------------------------------
-- ps-housing

tests['ps-housing: not started → every call is the no-op, one warning'] = function(t)
    with({ states = {} }, function()
        local a = fresh('adapters.housing.ps_housing')
        local log = recorder()
        a.init(log)
        t.eq(a.stub, false)
        t.eq(a.getDoorForProperty(5), nil)
        t.eq(a.unlock(5, 1), false)
        t.eq(a.getAddresses('ABC12345'), {})
        t.eq(a.getAddress('ABC12345'), nil)
        t.eq(#log.warns, 1, table.concat(log.warns, ' | '))
        t.ok(log.warns[1]:find('ps-housing', 1, true))
    end)
end

tests['ps-housing: MLO doors come from getMainDoor 1..n until the first missing one'] = function(t)
    local world = { states = { ['ps-housing'] = 'started' }, psDoors = { [7] = { 101, 102 } } }
    with(world, function()
        local a = fresh('adapters.housing.ps_housing')
        t.eq(a.getDoorForProperty(7), { 101, 102 })
        t.eq(a.getDoorForProperty('7'), { 101, 102 }, 'string ids from ps-housing')
        t.eq(world.mainDoorCalls[1], { 7, 1, false })
        t.eq(#world.mainDoorCalls, 6, '3 calls per lookup: 1, 2, then the missing 3')
        t.eq(a.getDoorForProperty(8), nil, 'shell property: no ox_doorlock door')
        t.eq(a.getDoorForProperty('x'), nil)
        t.eq(a.getDoorForProperty(-1), nil)
    end)
end

tests['ps-housing: unlock sets every door of the property to 0; a shell cannot be unlocked'] = function(t)
    local world = { states = { ['ps-housing'] = 'started' }, psDoors = { [7] = { 101, 102 } } }
    with(world, function()
        local a = fresh('adapters.housing.ps_housing')
        t.eq(a.unlock(7, 1), true)
        t.eq(world.setStates, { { 101, 0 }, { 102, 0 } })
        t.eq(a.unlock(8, 1), false)
        t.eq(#world.setStates, 2)
    end)
end

tests['ps-housing: addresses from the properties table, label "<street or apartment> <id>"'] = function(t)
    local world = { states = { ['ps-housing'] = 'started' }, rows = {
        { property_id = 3, street = 'Grove Street', apartment = nil },
        { property_id = 9, street = nil, apartment = 'Alta Street' },
        { property_id = 11 },
    } }
    with(world, function()
        local a = fresh('adapters.housing.ps_housing')
        t.eq(a.getAddresses('ABC12345'), {
            { propertyId = '3', label = 'Grove Street 3' },
            { propertyId = '9', label = 'Alta Street 9' },
            { propertyId = '11', label = '11' },
        })
        t.eq(world.queries[1].params, { 'ABC12345' })
        t.ok(world.queries[1].sql:find('FROM properties WHERE owner_citizenid = ?', 1, true))
        t.eq(a.getAddress('ABC12345'), 'Grove Street 3')
        -- bad citizenids never reach the database
        for _, bad in ipairs({ '', "x' OR 1=1", 42, ('A'):rep(51) }) do t.eq(a.getAddresses(bad), {}) end
        t.eq(#world.queries, 2)
        world.rows = {}
        t.eq(a.getAddress('NOHOME01'), nil)
    end)
end

tests['ps-housing: getAddresses SQL against MariaDB (skipped when unreachable)'] = function(t)
    local okDb, reason = shim.available()
    if not okDb then
        print('  [skip] MariaDB unreachable: ' .. tostring(reason))
        return
    end
    local savedMySQL, savedLRF, savedGCRN = rawget(_G, 'MySQL'), rawget(_G, 'LoadResourceFile'),
        rawget(_G, 'GetCurrentResourceName')
    shim.resetDatabase(DB, false)
    local ok, err = shim.run([[
CREATE TABLE properties (
  property_id INT(11) NOT NULL AUTO_INCREMENT, owner_citizenid VARCHAR(50) NULL, street VARCHAR(100) NULL,
  region VARCHAR(100) NULL, shell VARCHAR(50) NOT NULL, apartment VARCHAR(50) NULL DEFAULT NULL,
  door_data JSON NULL DEFAULT NULL, PRIMARY KEY (property_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
INSERT INTO properties (property_id, owner_citizenid, street, shell, apartment) VALUES
  (4, 'HOUSE001', 'Grove Street', 'mlo', NULL), (2, 'HOUSE001', NULL, 'shell_1', 'Alta Street'),
  (5, 'OTHER002', 'Vinewood Blvd', 'mlo', NULL);
]], DB)
    t.ok(ok, err)
    shim.install({ database = DB })
    local world = { states = { ['ps-housing'] = 'started' }, realDb = true }
    local okRun, runErr = pcall(with, world, function()
        local a = fresh('adapters.housing.ps_housing')
        t.eq(a.getAddresses('HOUSE001'), {
            { propertyId = '2', label = 'Alta Street 2' },
            { propertyId = '4', label = 'Grove Street 4' },
        })
        t.eq(a.getAddresses('NOBODY01'), {})
    end)
    rawset(_G, 'MySQL', savedMySQL)
    rawset(_G, 'LoadResourceFile', savedLRF)
    rawset(_G, 'GetCurrentResourceName', savedGCRN)
    if not okRun then error(runErr, 0) end
end

---------------------------------------------------------------------------------------------------------------
-- ox_doorlock-only

local DOORS = {
    [12] = { id = 12, name = 'grove_front', state = 1 },
    [13] = { id = 13, name = 'grove_back', state = 1 },
    [40] = { id = 40, name = 'loose_door', state = 1 },
}

tests['ox_doorlock-only: mapping by id and by door name; unmapped (even numeric) → nil'] = function(t)
    local world = { states = { ox_doorlock = 'started' }, doors = DOORS }
    with(world, function()
        local a = fresh('adapters.housing.ox_doorlock_only')
        a.impl.load({ properties = {
            grove = { doors = { 12, 'grove_back', 'missing_door' }, label = 'Grove Street 1' },
            bad = { doors = { {}, true } },
            ['7'] = { doors = { 40 } },
        } })
        t.eq(a.getDoorForProperty('grove'), { 12, 13 })
        t.eq(a.getDoorForProperty(7), { 40 }, 'mapped numeric id uses the mapping')
        t.eq(a.getDoorForProperty(12), nil, 'unmapped numeric id is not taken as a door id')
        t.eq(a.unlock(12, 1), false)
        t.eq(a.getDoorForProperty(99), nil)
        t.eq(a.getDoorForProperty('bad'), nil, 'entries without valid doors are dropped')
        t.eq(a.getDoorForProperty('nope'), nil)
        t.eq(world.setStates, {}, 'nothing unlocked for unmapped ids')
        t.eq(a.unlock('grove', 1), true)
        t.eq(world.setStates, { { 12, 0 }, { 13, 0 } })
        t.eq(a.unlock('nope', 1), false)
        t.eq(a.getAddresses('ABC12345'), {}, 'no ownership data')
        t.eq(a.getAddress('ABC12345'), nil)
    end)
end

tests['ox_doorlock-only: the shipped mapping file loads (empty) and ox_doorlock stopped → no-op'] = function(t)
    local f = assert(io.open('resources/[fredpd]/fredpd_core/adapters/housing/ox_doorlock_only.json', 'r'))
    local decoded = json.decode(f:read('a'))
    f:close()
    with({ states = { ox_doorlock = 'stopped' }, doors = DOORS }, function()
        local a = fresh('adapters.housing.ox_doorlock_only')
        t.eq(a.impl.load(decoded), {})
        local log = recorder()
        a.init(log, function() end)
        t.eq(a.getDoorForProperty(12), nil)
        t.eq(a.unlock(12, 1), false)
        t.eq(#log.warns, 1)
    end)
end

tests['every housing adapter has getAddress and the interface methods'] = function(t)
    with({ states = {} }, function()
        for _, name in ipairs({ 'none', 'ps_housing', 'ox_doorlock_only', 'qbx_properties' }) do
            local a = fresh('adapters.housing.' .. name)
            t.eq(a.kind, 'housing', name)
            for method in pairs(Base.INTERFACES.housing) do t.ok(type(a[method]) == 'function', name .. '.' .. method) end
            t.ok(type(a.getAddress) == 'function', name .. '.getAddress')
            a.init(recorder(), function() end)
            t.eq(a.getAddress('ABC12345'), nil, name)
        end
    end)
end

return tests
