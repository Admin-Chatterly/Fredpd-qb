-- SPDX-License-Identifier: GPL-3.0-only
-- Grant resolution (docs/contracts.md §C2). Lua port of packages/types/src/grants.ts with identical
-- semantics; both run packages/types/test/fixtures/grants.fixtures.json. Change the two together.
--
-- Input is JSON-decoded or DB data: arrays are sequences, JSON null / SQL NULL is nil, and a
-- TINYINT `deleted` may arrive as 0/1 instead of a boolean. Pure: no natives, safe at load time.

local M = {}

local GRANT_TYPES = {
    weapon = true, vehicle = true, armory = true, tool = true,
    mdt_page = true, intel_tier = true, unit = true, perm = true,
}
M.TYPES = { 'weapon', 'vehicle', 'armory', 'tool', 'mdt_page', 'intel_tier', 'unit', 'perm' }

local RANK_PREFIX = 'rank:'

--- Grant keys are ASCII identifiers: letters, digits and _ . : * -, 1..64 bytes (grants.ts GRANT_KEY_PATTERN).
--- Explicit ranges instead of %w, which follows the C locale.
local function validKey(key)
    return type(key) == 'string' and #key <= 64 and key:find('^[A-Za-z0-9_%.:%*%-]+$') ~= nil
end

--- Byte-wise string order. Lua's `<` on strings uses strcoll (locale dependent); this matches the TS
--- port's code-unit order for the ASCII keys used in practice.
local function byteLess(a, b)
    if a == b then return false end
    local la, lb = #a, #b
    for i = 1, (la < lb) and la or lb do
        local ca, cb = a:byte(i), b:byte(i)
        if ca ~= cb then return ca < cb end
    end
    return la < lb
end
M.byteLess = byteLess

local function truthy(v)
    return v == true or v == 1 or v == '1'
end

--- Keys of a set table as a byte-sorted sequence.
local function sortedKeys(set)
    local out = {}
    for k in pairs(set) do out[#out + 1] = k end
    table.sort(out, byteLess)
    return out
end

local function contains(list, value)
    if type(list) ~= 'table' then return false end
    for i = 1, #list do
        if list[i] == value then return true end
    end
    return false
end

--- `(grants ∋ type:key or grants ∋ type:*) and not (denied ∋ type:key or denied ∋ type:*)`.
--- A missing set (or key) grants nothing.
--- @param set table|nil GrantSet (only .grants and .denied are read)
--- @param grantType string
--- @param key string
--- @return boolean
function M.has(set, grantType, key)
    if type(set) ~= 'table' or type(grantType) ~= 'string' or key == nil then return false end
    local exact = grantType .. ':' .. tostring(key)
    local wildcard = grantType .. ':*'
    if not contains(set.grants, exact) and not contains(set.grants, wildcard) then return false end
    return not contains(set.denied, exact) and not contains(set.denied, wildcard)
end

--- ISO-8601 UTC timestamp. FiveM client Lua may lack os.date; grants are only computed server-side, so
--- the client (which only calls M.has) never needs a real timestamp.
local function isoNow(now)
    if not (os and os.date) then return '1970-01-01T00:00:00Z' end
    return os.date('!%Y-%m-%dT%H:%M:%SZ', now) --[[@as string]]
end

--- An empty GrantSet. `rank` is nil (JSON null).
--- @param now integer|nil unix seconds for computedAt (default: current time)
function M.empty(now)
    return { grants = {}, denied = {}, tier = 0, units = {}, rank = nil, computedAt = isoNow(now) }
end

--- Parses an intel_tier key: integers are clamped to 0..2; anything else (including '*') gives nil.
local function parseTier(key)
    if not key:match('^%-?%d+$') then return nil end
    local n = tonumber(key)
    if n >= 2 then return 2 elseif n <= 0 then return 0 end
    return 1
end

--- Resolves a member's grants from their Discord roles. See grants.ts `resolveGrants` for the rules.
--- @param input table { memberRoleIds, roles, grants, unitOrder } (camelCase, as in §C2)
--- @param now integer|nil unix seconds for computedAt (default: current time)
--- @return table GrantSet
function M.resolve(input, now)
    input = input or {}

    local member = {}
    for _, id in ipairs(input.memberRoleIds or {}) do member[id] = true end

    -- Held roles: exist in the roles table, not deleted, and the member has them.
    local held = {}
    for _, role in ipairs(input.roles or {}) do
        local id = role.discordRoleId
        if id ~= nil and member[id] and not truthy(role.deleted) then
            held[id] = tonumber(role.position) or 0
        end
    end

    -- Rows with an unknown type or effect, or a key outside the grant key charset, are ignored (as in TS),
    -- so the result always passes GrantSetSchema.
    local rows = {}
    for _, row in ipairs(input.grants or {}) do
        if held[row.discordRoleId] ~= nil and GRANT_TYPES[row.grantType]
            and (row.effect == 'allow' or row.effect == 'deny') and validKey(row.grantKey) then
            rows[#rows + 1] = row
        end
    end

    -- deniedTiers: tier values of denied intel_tier keys, so a deny cannot be bypassed by another spelling
    -- of the same tier ('deny intel_tier:2' also drops 'allow intel_tier:5' and 'allow intel_tier:02').
    local denied, deniedTiers = {}, {}
    for _, row in ipairs(rows) do
        if row.effect == 'deny' then
            denied[row.grantType .. ':' .. row.grantKey] = true
            if row.grantType == 'intel_tier' then
                local t = parseTier(row.grantKey)
                if t ~= nil then deniedTiers[t] = true end
            end
        end
    end

    local function rowDenied(row, grant)
        if denied[grant] or denied[row.grantType .. ':*'] then return true end
        if row.grantType ~= 'intel_tier' then return false end
        local t = parseTier(row.grantKey)
        return t ~= nil and deniedTiers[t] == true
    end

    local allowed, units = {}, {}
    local tier, rank = 0, nil
    for _, row in ipairs(rows) do
        local grant = row.grantType .. ':' .. row.grantKey
        -- Deny wins: exact deny, the type's wildcard deny, or (intel_tier) a deny of the same tier value.
        if row.effect == 'allow' and not rowDenied(row, grant) then
            allowed[grant] = true
            local key = row.grantKey
            if row.grantType == 'intel_tier' then
                local t = parseTier(key)
                if t ~= nil and t > tier then tier = t end
            elseif row.grantType == 'unit' then
                if key ~= '*' then units[key] = true end
            elseif row.grantType == 'perm' and key:sub(1, #RANK_PREFIX) == RANK_PREFIX then
                local rankKey = key:sub(#RANK_PREFIX + 1)
                if rankKey ~= '' and rankKey ~= '*' then
                    local position, roleId = held[row.discordRoleId], row.discordRoleId
                    if rank == nil or position > rank.position
                        or (position == rank.position and (byteLess(roleId, rank.roleId)
                            or (roleId == rank.roleId and byteLess(rankKey, rank.key)))) then
                        rank = { position = position, roleId = roleId, key = rankKey }
                    end
                end
            end
        end
    end

    -- Units: configured order first (first occurrence counts), unknown units after, byte order.
    local order = {}
    for i, unit in ipairs(input.unitOrder or {}) do
        if order[unit] == nil then order[unit] = i end
    end
    local unitList = sortedKeys(units)
    table.sort(unitList, function(a, b)
        local ia, ib = order[a], order[b]
        if ia and ib then return ia < ib end
        if ia then return true end
        if ib then return false end
        return byteLess(a, b)
    end)

    return {
        grants = sortedKeys(allowed),
        denied = sortedKeys(denied),
        tier = tier,
        units = unitList,
        rank = rank and { roleId = rank.roleId, key = rank.key } or nil,
        computedAt = isoNow(now),
    }
end

return M
