-- SPDX-License-Identifier: GPL-3.0-only
-- Input checks for fredpd_bolo (pure Lua 5.4, no FiveM). Mirrors the zod shapes in packages/types/src/mdt.ts
-- (BoloCreateInputSchema, BoloResolveInputSchema, BoloListInputSchema, PlateSchema, CitizenIdSchema). The fredpd_mdt
-- dispatcher validates tablet input already (§C12); the exports validate again because any resource can call them.
-- Every function returns the cleaned value, or nil and the name of the offending field.
-- Tested by tests/lua/bolo_input_test.lua.

local M = {}

M.REASON_MIN = 3
M.REASON_MAX = 500
M.NOTE_MAX = 500
M.PLATE_MAX = 16
M.HOURS_MAX = 720
M.PAGE_MAX = 10000
M.KINDS = { person = true, vehicle = true }

--- Trim ASCII whitespace; nil for non-strings.
local function trim(v)
    if type(v) ~= 'string' then return nil end
    return (v:gsub('^%s+', ''):gsub('%s+$', ''))
end
M.trim = trim

--- Integer value of a number (1 and 1.0 alike), nil otherwise.
local function int(v)
    if type(v) ~= 'number' or v ~= v then return nil end
    return math.tointeger(v)
end
M.int = int

--- Plate as FredPD stores it (fredpd_vehicles_idx.plate, detectSearchType §C4): whitespace removed, upper case.
--- Only letters, digits and '-' remain valid (GTA plates; the same rule as the qbx_police bridge), at most 16.
--- @return string|nil
function M.normalizePlate(plate)
    if type(plate) ~= 'string' then return nil end
    local p = plate:gsub('%s+', ''):upper()
    if p == '' or #p > M.PLATE_MAX or not p:find('^[%w%-]+$') then return nil end
    return p
end

--- qbx citizenid (CitizenIdSchema: [A-Za-z0-9_-]{1,50}).
function M.citizenId(v)
    if type(v) ~= 'string' or #v < 1 or #v > 50 or not v:find('^[%w_%-]+$') then return nil end
    return v
end

--- Free text: trimmed, valid UTF-8, control characters other than newline/tab turned into spaces, length in
--- characters between min and max. @return string|nil
function M.text(v, min, max)
    v = trim(v)
    if not v or not utf8.len(v) then return nil end
    v = v:gsub('\r\n', '\n'):gsub('[\0-\8\11-\31\127]', ' ')
    local n = utf8.len(v)
    if n < min or n > max then return nil end
    return v
end

--- BoloCreateInput -> { kind, citizenid?, plate? (normalised), reason, level, expiresInHours? } or nil, field.
function M.validateCreate(input)
    if type(input) ~= 'table' then return nil, 'input' end
    local kind = input.kind
    if type(kind) ~= 'string' or not M.KINDS[kind] then return nil, 'kind' end
    local out = { kind = kind }
    if kind == 'person' then
        if input.plate ~= nil then return nil, 'plate' end
        out.citizenid = M.citizenId(input.citizenid)
        if not out.citizenid then return nil, 'citizenid' end
    else
        if input.citizenid ~= nil then return nil, 'citizenid' end
        local raw = trim(input.plate)
        if not raw or #raw < 1 or #raw > M.PLATE_MAX then return nil, 'plate' end
        out.plate = M.normalizePlate(raw)
        if not out.plate then return nil, 'plate' end
    end
    out.reason = M.text(input.reason, M.REASON_MIN, M.REASON_MAX)
    if not out.reason then return nil, 'reason' end
    if input.level == nil then
        out.level = 0
    else
        out.level = int(input.level)
        if not out.level or out.level < 0 or out.level > 2 then return nil, 'level' end
    end
    if input.expiresInHours ~= nil then
        out.expiresInHours = int(input.expiresInHours)
        if not out.expiresInHours or out.expiresInHours < 1 or out.expiresInHours > M.HOURS_MAX then
            return nil, 'expiresInHours'
        end
    end
    return out
end

--- BoloResolveInput -> { id, note (nil when empty) } or nil, field.
function M.validateResolve(input)
    if type(input) ~= 'table' then return nil, 'input' end
    local id = int(input.id)
    if not id or id < 1 then return nil, 'id' end
    local note = nil
    if input.note ~= nil then
        if type(input.note) ~= 'string' then return nil, 'note' end
        local t = trim(input.note)
        if t ~= '' then
            note = M.text(t, 1, M.NOTE_MAX)
            if not note then return nil, 'note' end
        end
    end
    return { id = id, note = note }
end

--- BoloListInput -> { active (default true), page (default 1) } or nil, field.
function M.validateList(input)
    if input == nil then input = {} end
    if type(input) ~= 'table' then return nil, 'input' end
    local active = input.active
    if active == nil then active = true end
    if type(active) ~= 'boolean' then return nil, 'active' end
    local page = 1
    if input.page ~= nil then
        page = int(input.page)
        if not page or page < 1 or page > M.PAGE_MAX then return nil, 'page' end
    end
    return { active = active, page = page }
end

--- { plate } (checkPlate action) -> normalised plate or nil, field.
function M.validatePlateInput(input)
    if type(input) ~= 'table' then return nil, 'input' end
    local raw = trim(input.plate)
    if not raw or #raw < 1 or #raw > M.PLATE_MAX then return nil, 'plate' end
    local plate = M.normalizePlate(raw)
    if not plate then return nil, 'plate' end
    return plate
end

return M
