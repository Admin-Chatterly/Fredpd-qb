-- SPDX-License-Identifier: GPL-3.0-only
-- Input checks for fredpd_intel (pure Lua 5.4, no FiveM). Mirrors the zod input shapes of INTEL_ACTIONS in
-- packages/types/src/intel.ts (docs/contracts.md §C15). The fredpd_mdt dispatcher validates tablet input first
-- (§C12 step 2); every export validates again because any server resource can call it.
--
-- zod semantics kept: `trim` removes what JS String.prototype.trim removes, string min/max count code points
-- (utf8.len, zod >= 4.6), ints are integral numbers (1 and 1.0 alike) in the safe range, defaults are filled,
-- unknown keys are dropped, AddLinkInput.to is a union tried in order ({ id } first, then EnsureEntityInput).
-- Deliberately stricter (docs/modules/intel.md): invalid UTF-8 and strings over MAX_BYTES are refused; single-line
-- fields (codename, label, ref, link type, title, role, query, unit) refuse control characters; multi-line text
-- (notes, body, description) turns CR LF into LF and other control characters (except tab/newline) into spaces. A
-- JSON null arrives in Lua as an absent field, so `notes: null` cannot clear notes: an empty (after trim) notes
-- string clears them instead.
--
-- Every validator returns the cleaned table, or nil and the name of the first offending field.
-- Tested by tests/lua/intel_input_test.lua.

local M = {}

M.MAX_SAFE_INTEGER = 9007199254740991
M.MAX_BYTES = 262144 -- 50 000 code points of body text can take up to 200 000 bytes
M.PAGE_MAX = 10000
M.RELIABILITY = { A = true, B = true, C = true, D = true }
M.ENTITY_TYPES = { person = true, vehicle = true, location = true, group = true, case = true }
M.STATUS = { open = true, closed = true }
M.PLATE_MAX = 16
M.CASE_NUMBER_MAX = 32 -- fredpd_cases.case_number VARCHAR(32)

---------------------------------------------------------------------------------------------------------------
-- Primitives

-- Code points removed by String.prototype.trim (ECMAScript WhiteSpace + LineTerminator).
local WS = {
    [0x09] = true, [0x0A] = true, [0x0B] = true, [0x0C] = true, [0x0D] = true, [0x20] = true, [0xA0] = true,
    [0x1680] = true, [0x2028] = true, [0x2029] = true, [0x202F] = true, [0x205F] = true, [0x3000] = true,
    [0xFEFF] = true,
}
for cp = 0x2000, 0x200A do WS[cp] = true end

--- JS-compatible trim of a valid UTF-8 string.
function M.jsTrim(s)
    local first, last
    for pos, cp in utf8.codes(s) do
        if not WS[cp] then
            first = first or pos
            last = pos
        end
    end
    if not first then return '' end
    local after = utf8.offset(s, 2, last) or (#s + 1)
    return s:sub(first, after - 1)
end

--- Integer value of a number (1 and 1.0 alike) within [min, max], else nil.
function M.int(v, min, max)
    if type(v) ~= 'number' or v ~= v then return nil end
    local i = math.tointeger(v)
    if not i or i > M.MAX_SAFE_INTEGER or i < -M.MAX_SAFE_INTEGER then return nil end
    if (min and i < min) or (max and i > max) then return nil end
    return i
end

--- Positive id (z.number().int().positive()).
function M.id(v)
    return M.int(v, 1, M.MAX_SAFE_INTEGER)
end

--- One-line text: valid UTF-8, trimmed (unless opts.noTrim), no control characters, min..max code points.
function M.line(v, min, max, noTrim)
    if type(v) ~= 'string' or #v > M.MAX_BYTES or not utf8.len(v) then return nil end
    if not noTrim then v = M.jsTrim(v) end
    if v:find('[%z\1-\31\127]') then return nil end
    local n = utf8.len(v)
    if n < (min or 0) or (max and n > max) then return nil end
    return v
end

--- Multi-line text: valid UTF-8, trimmed, CR LF -> LF, control characters other than tab/newline -> space,
--- min..max code points (counted after trimming, as zod does).
function M.text(v, min, max)
    if type(v) ~= 'string' or #v > M.MAX_BYTES or not utf8.len(v) then return nil end
    v = M.jsTrim(v)
    local n = utf8.len(v)
    if n < (min or 0) or (max and n > max) then return nil end
    v = v:gsub('\r\n', '\n'):gsub('[%z\1-\8\11-\31\127]', ' ')
    return v
end

--- LevelSchema (0 | 1 | 2) with a default for an absent value.
function M.level(v, default)
    if v == nil then return default end
    return M.int(v, 0, 2)
end

--- PageSchema: int 1..10000, default 1.
function M.page(v)
    if v == nil then return 1 end
    return M.int(v, 1, M.PAGE_MAX)
end

--- CitizenIdSchema: [A-Za-z0-9_-]{1,50}.
function M.citizenId(v)
    if type(v) ~= 'string' or #v < 1 or #v > 50 or not v:find('^[%w_%-]+$') then return nil end
    return v
end

--- Plate as FredPD stores it (fredpd_vehicles_idx.plate): whitespace removed, upper case, [A-Z0-9-], 1..16.
function M.plate(v)
    if type(v) ~= 'string' then return nil end
    local p = v:gsub('%s+', ''):upper()
    if p == '' or #p > M.PLATE_MAX or not p:find('^[%w%-]+$') then return nil end
    return p
end

--- Unit code (config/units.json codes): letters, digits, '_' and '-', 1..32.
function M.unitCode(v)
    if type(v) ~= 'string' or #v < 1 or #v > 32 or not v:find('^[%w_%-]+$') then return nil end
    return v
end

local function enum(v, set)
    if type(v) ~= 'string' or not set[v] then return nil end
    return v
end

local function isTable(v) return type(v) == 'table' end

--- LIKE pattern for a prefix search: the query with `!`, `%` and `_` escaped for `LIKE ? ESCAPE '!'`, plus '%'.
--- '!' is used instead of a backslash so the pattern means the same with or without NO_BACKSLASH_ESCAPES.
function M.likePrefix(query)
    return (query:gsub('[!%%_]', '!%0')) .. '%'
end

---------------------------------------------------------------------------------------------------------------
-- Action inputs (INTEL_ACTIONS)

M.validate = {}

--- { page } (listSources, listMissions).
function M.validate.page(input)
    if input == nil then input = {} end
    if not isTable(input) then return nil, 'input' end
    local page = M.page(input.page)
    if not page then return nil, 'page' end
    return { page = page }
end
M.validate.listSources = M.validate.page
M.validate.listMissions = M.validate.page

--- { id } (getSource, getIntelReport, getEntity, getMission, closeMission).
function M.validate.id(input)
    if not isTable(input) then return nil, 'input' end
    local id = M.id(input.id)
    if not id then return nil, 'id' end
    return { id = id }
end
M.validate.getSource = M.validate.id
M.validate.getIntelReport = M.validate.id
M.validate.getEntity = M.validate.id
M.validate.getMission = M.validate.id
M.validate.closeMission = M.validate.id

--- SourceCreateInputSchema.
function M.validate.createSource(input)
    if not isTable(input) then return nil, 'input' end
    local out = {}
    out.codename = M.line(input.codename, 2, 64)
    if not out.codename then return nil, 'codename' end
    if input.reliability == nil then
        out.reliability = 'C'
    else
        out.reliability = enum(input.reliability, M.RELIABILITY)
        if not out.reliability then return nil, 'reliability' end
    end
    if input.notes ~= nil then
        out.notes = M.text(input.notes, 0, 5000)
        if not out.notes then return nil, 'notes' end
        if out.notes == '' then out.notes = nil end
    end
    if input.realCitizenid ~= nil then
        out.realCitizenid = M.citizenId(input.realCitizenid)
        if not out.realCitizenid then return nil, 'realCitizenid' end
    end
    out.level = M.level(input.level, 2)
    if not out.level then return nil, 'level' end
    return out
end

--- SourceUpdateInputSchema. `notes` = '' (after trim) clears the notes (clearNotes = true).
function M.validate.updateSource(input)
    if not isTable(input) then return nil, 'input' end
    local out = { id = M.id(input.id) }
    if not out.id then return nil, 'id' end
    if input.reliability ~= nil then
        out.reliability = enum(input.reliability, M.RELIABILITY)
        if not out.reliability then return nil, 'reliability' end
    end
    if input.status ~= nil then
        out.status = enum(input.status, M.STATUS)
        if not out.status then return nil, 'status' end
    end
    if input.notes ~= nil then
        local notes = M.text(input.notes, 0, 5000)
        if not notes then return nil, 'notes' end
        if notes == '' then out.clearNotes = true else out.notes = notes end
    end
    return out
end

--- IntelReportCreateInputSchema.
function M.validate.createIntelReport(input)
    if not isTable(input) then return nil, 'input' end
    local out = {}
    if input.sourceId ~= nil then
        out.sourceId = M.id(input.sourceId)
        if not out.sourceId then return nil, 'sourceId' end
    end
    if input.missionId ~= nil then
        out.missionId = M.id(input.missionId)
        if not out.missionId then return nil, 'missionId' end
    end
    out.body = M.text(input.body, 3, 50000)
    if not out.body then return nil, 'body' end
    if input.reliability ~= nil then
        out.reliability = enum(input.reliability, M.RELIABILITY)
        if not out.reliability then return nil, 'reliability' end
    end
    out.level = M.level(input.level, 1)
    if not out.level then return nil, 'level' end
    return out
end

--- IntelReportListInputSchema.
function M.validate.listIntelReports(input)
    if input == nil then input = {} end
    if not isTable(input) then return nil, 'input' end
    local out = {}
    if input.sourceId ~= nil then
        out.sourceId = M.id(input.sourceId)
        if not out.sourceId then return nil, 'sourceId' end
    end
    if input.missionId ~= nil then
        out.missionId = M.id(input.missionId)
        if not out.missionId then return nil, 'missionId' end
    end
    out.page = M.page(input.page)
    if not out.page then return nil, 'page' end
    return out
end

--- searchEntities: { query: trim 2..64, type?: EntityType }.
function M.validate.searchEntities(input)
    if not isTable(input) then return nil, 'input' end
    local out = { query = M.line(input.query, 2, 64) }
    if not out.query then return nil, 'query' end
    if input.type ~= nil then
        out.type = enum(input.type, M.ENTITY_TYPES)
        if not out.type then return nil, 'type' end
    end
    return out
end

--- EnsureEntityInputSchema: { type, ref?: trim max 64, label: trim 1..128 }. An empty ref counts as absent.
function M.validate.ensureEntity(input)
    if not isTable(input) then return nil, 'input' end
    local out = { type = enum(input.type, M.ENTITY_TYPES) }
    if not out.type then return nil, 'type' end
    if input.ref ~= nil then
        local ref = M.line(input.ref, 0, 64)
        if not ref then return nil, 'ref' end
        if ref ~= '' then out.ref = ref end
    end
    out.label = M.line(input.label, 1, 128)
    if not out.label then return nil, 'label' end
    return out
end

--- AddLinkInputSchema. `to` is { id } or an EnsureEntityInput (the union is tried in that order, like zod).
function M.validate.addLink(input)
    if not isTable(input) then return nil, 'input' end
    local out = { fromId = M.id(input.fromId) }
    if not out.fromId then return nil, 'fromId' end
    local to = input.to
    if not isTable(to) then return nil, 'to' end
    local toId = M.id(to.id)
    if toId then
        out.to = { id = toId }
    else
        local ensure = M.validate.ensureEntity(to)
        if not ensure then return nil, 'to' end
        out.to = ensure
    end
    out.type = M.line(input.type, 2, 32)
    if not out.type then return nil, 'type' end
    if input.confidence == nil then
        out.confidence = 50
    else
        out.confidence = M.int(input.confidence, 0, 100)
        if not out.confidence then return nil, 'confidence' end
    end
    if input.reportId ~= nil then
        out.reportId = M.id(input.reportId)
        if not out.reportId then return nil, 'reportId' end
    end
    out.level = M.level(input.level, 1)
    if not out.level then return nil, 'level' end
    return out
end

--- GraphInputSchema: { entityId, depth: 1 | 2 = 1 }.
function M.validate.getGraph(input)
    if not isTable(input) then return nil, 'input' end
    local out = { entityId = M.id(input.entityId) }
    if not out.entityId then return nil, 'entityId' end
    if input.depth == nil then
        out.depth = 1
    else
        out.depth = M.int(input.depth, 1, 2)
        if not out.depth then return nil, 'depth' end
    end
    return out
end

--- MissionCreateInputSchema. `unit` is not trimmed (zod has no trim there) and must look like a unit code.
function M.validate.createMission(input)
    if not isTable(input) then return nil, 'input' end
    local out = { title = M.line(input.title, 3, 160) }
    if not out.title then return nil, 'title' end
    if input.description ~= nil then
        out.description = M.text(input.description, 0, 20000)
        if not out.description then return nil, 'description' end
        if out.description == '' then out.description = nil end
    end
    out.level = M.level(input.level, 2)
    if not out.level then return nil, 'level' end
    if input.unit ~= nil then
        out.unit = M.unitCode(M.line(input.unit, 1, 32, true))
        if not out.unit then return nil, 'unit' end
    end
    return out
end

--- MissionMemberInputSchema: { id, citizenid, role?: trim max 32 } (an empty role counts as absent).
function M.validate.addMissionMember(input)
    if not isTable(input) then return nil, 'input' end
    local out = { id = M.id(input.id) }
    if not out.id then return nil, 'id' end
    out.citizenid = M.citizenId(input.citizenid)
    if not out.citizenid then return nil, 'citizenid' end
    if input.role ~= nil then
        local role = M.line(input.role, 0, 32)
        if not role then return nil, 'role' end
        if role ~= '' then out.role = role end
    end
    return out
end

--- Entity ref for a keyed type, normalised: person -> citizenid, vehicle -> plate (upper, no spaces), case ->
--- a case-number-shaped string (the stored ref is then the number exactly as fredpd_cases has it).
--- location/group keep their free-text ref (or nil). Returns ref or nil (invalid).
function M.entityRef(entityType, ref)
    if entityType == 'person' then return M.citizenId(ref) end
    if entityType == 'vehicle' then return M.plate(ref) end
    if entityType == 'case' then
        if type(ref) ~= 'string' or #ref < 1 or #ref > M.CASE_NUMBER_MAX or not ref:find('^[%w%-/_%.]+$') then
            return nil
        end
        return ref
    end
    return ref
end

--- Keyed entity types: the ref must point at a real record and the label is derived on the server.
M.KEYED = { person = true, vehicle = true, case = true }

return M
