-- SPDX-License-Identifier: GPL-3.0-only
-- Assertion helpers for tests/lua/*_test.lua. `t` in each test is this module.
local M = {}

local function dump(v, depth)
    depth = depth or 0
    if type(v) ~= 'table' then return type(v) == 'string' and ('%q'):format(v) or tostring(v) end
    if depth > 4 then return '{...}' end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. '=' .. dump(v[k], depth + 1) end
    return '{' .. table.concat(parts, ', ') .. '}'
end
M.dump = dump

local function deepEqual(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for k, v in pairs(a) do if not deepEqual(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
M.deepEqual = deepEqual

function M.eq(actual, expected, msg)
    if not deepEqual(actual, expected) then
        error(('%sexpected %s, got %s'):format(msg and (msg .. ': ') or '', dump(expected), dump(actual)), 2)
    end
end

function M.ok(cond, msg)
    if not cond then error(msg or 'expected truthy value', 2) end
end

--- Read and decode a JSON file relative to the repo root.
function M.readJson(path)
    local f = io.open(path, 'r')
    -- locales/pending/*.json are merged into sv/en and then deleted; a missing pending file means "no pending keys".
    if not f and path:match('^locales/pending/') then return {} end
    assert(f, 'cannot open ' .. path)
    local s = f:read('a')
    f:close()
    return json.decode(s)
end

--- Read a file relative to the repo root.
function M.readFile(path)
    local f = assert(io.open(path, 'r'), 'cannot open ' .. path)
    local s = f:read('a')
    f:close()
    return s
end

return M
