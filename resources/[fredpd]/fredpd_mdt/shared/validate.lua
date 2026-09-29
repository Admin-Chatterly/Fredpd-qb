-- SPDX-License-Identifier: GPL-3.0-only
-- Lua mirror of the tablet action input shapes (docs/contracts.md §C12 step 2): packages/types/src/mdt.ts
-- (MDT_ACTIONS, TabletIssueInputSchema), dispatch.ts (DISPATCH_ACTIONS, §C13) and evidence.ts (EVIDENCE_ACTIONS,
-- §C16). Pure Lua 5.4, no FiveM; loaded by the server dispatcher (server/dispatch.lua) and, for the action names
-- only, by client/main.lua. Table-driven: SHAPES describes each zod object, ACTIONS maps an action to its shape.
--
-- Semantics follow zod 4 so both sides accept and reject the same input and produce the same cleaned value
-- (checked against packages/types/test/fixtures/mdt-inputs.fixtures.json by tests/lua/mdt_validate_test.lua and by
-- resources/[fredpd]/fredpd_mdt/test/validate.test.ts):
--   * `trim` removes exactly what JS String.prototype.trim removes (ASCII + Unicode white space, U+FEFF);
--   * string min/max count Unicode code points (zod >= 4.6 measures strings in code points, not UTF-16 units:
--     an emoji counts 1), i.e. utf8.len;
--   * ints are numbers with an integral value (1 and 1.0 alike) in the safe-integer range (|n| <= 2^53 - 1);
--   * absent fields take their default; unknown keys are dropped (strict shapes reject them);
--   * refine (BoloCreateInput): person -> citizenid and no plate, vehicle -> plate and no citizenid.
-- Deliberate differences (documented in docs/modules/mdt.md): invalid UTF-8 (JS strings cannot hold it) and strings
-- longer than MAX_BYTES bytes are rejected; a JSON null arrives in Lua as an absent field (so an optional field sent
-- as null is accepted as absent, where zod rejects it); an empty JSON array is indistinguishable from {} in Lua.

local M = {}

M.MAX_SAFE_INTEGER = 9007199254740991
M.MAX_BYTES = 65536 -- hard cap per string before any work (no tablet field comes close)

---------------------------------------------------------------------------------------------------------------
-- Strings

-- Code points removed by String.prototype.trim (ECMAScript WhiteSpace + LineTerminator).
local WS = {
    [0x09] = true, [0x0A] = true, [0x0B] = true, [0x0C] = true, [0x0D] = true, [0x20] = true, [0xA0] = true,
    [0x1680] = true, [0x2028] = true, [0x2029] = true, [0x202F] = true, [0x205F] = true, [0x3000] = true,
    [0xFEFF] = true,
}
for cp = 0x2000, 0x200A do WS[cp] = true end

--- JS-compatible trim of a valid UTF-8 string.
--- @param s string
--- @return string
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

--- Length in Unicode code points (zod 4.6 string min/max) of a valid UTF-8 string.
--- @param s string
--- @return integer
function M.length(s)
    return utf8.len(s)
end

---------------------------------------------------------------------------------------------------------------
-- Field kinds. Each check returns the cleaned value or nil.

local CHECKS = {}

function CHECKS.string(f, v)
    if type(v) ~= 'string' or #v > M.MAX_BYTES or not utf8.len(v) then return nil end
    if f.trim then v = M.jsTrim(v) end
    local n = M.length(v)
    if (f.min and n < f.min) or (f.max and n > f.max) then return nil end
    if f.pattern and not v:find(f.pattern) then return nil end
    return v
end

function CHECKS.int(f, v)
    if type(v) ~= 'number' then return nil end
    local i = math.tointeger(v)
    if not i or i > M.MAX_SAFE_INTEGER or i < -M.MAX_SAFE_INTEGER then return nil end
    if (f.min and i < f.min) or (f.max and i > f.max) then return nil end
    return i
end

function CHECKS.bool(_, v)
    if type(v) ~= 'boolean' then return nil end
    return v
end

function CHECKS.enum(f, v)
    if type(v) ~= 'string' or not f.set[v] then return nil end
    return v
end

--- z.union of z.literal numbers (LevelSchema).
function CHECKS.literal(f, v)
    if type(v) ~= 'number' then return nil end
    local i = math.tointeger(v)
    if i == nil or not f.set[i] then return nil end
    return i
end

---------------------------------------------------------------------------------------------------------------
-- Field constructors (opts: optional = true, default = value)

local function field(kind, props, opts)
    local f = { kind = kind }
    for k, v in pairs(props or {}) do f[k] = v end
    for k, v in pairs(opts or {}) do f[k] = v end
    return f
end

local function str(props, opts) return field('string', props, opts) end
local function int(props, opts) return field('int', props, opts) end
local function bool(opts) return field('bool', nil, opts) end

local function enum(values, opts)
    local set = {}
    for _, v in ipairs(values) do set[v] = true end
    return field('enum', { set = set, values = values }, opts)
end

local function literal(values, opts)
    local set = {}
    for _, v in ipairs(values) do set[v] = true end
    return field('literal', { set = set, values = values }, opts)
end

local function with(base, opts)
    local f = {}
    for k, v in pairs(base) do f[k] = v end
    for k, v in pairs(opts) do f[k] = v end
    return f
end

--- An object shape. `fields` is an ordered list of { name, fieldSpec } (the first failing field is reported).
local function object(fields, opts)
    opts = opts or {}
    local byName = {}
    for _, pair in ipairs(fields) do byName[pair[1]] = pair[2] end
    return { fields = fields, byName = byName, strict = opts.strict == true, refine = opts.refine,
        refineField = opts.refineField }
end

-- Shared pieces (mdt.ts / actions.ts)
local PAGE = int({ min = 1, max = 10000 }, { default = 1 })                   -- PageSchema
local PLATE = str({ trim = true, min = 1, max = 16 })                          -- PlateSchema
local CITIZEN_ID = str({ min = 1, max = 50, pattern = '^[A-Za-z0-9_%-]+$' })   -- CitizenIdSchema
local LEVEL = literal({ 0, 1, 2 })                                             -- LevelSchema
local POSITIVE_ID = int({ min = 1 })                                           -- z.number().int().positive()

local function boloRefine(v)
    if v.kind == 'person' then return v.citizenid ~= nil and v.plate == nil end
    return v.plate ~= nil and v.citizenid == nil
end

M.SHAPES = {
    Empty = object({}, { strict = true }),
    SearchInput = object({
        { 'query', str({ trim = true, min = 2, max = 64 }) },
        { 'type', enum({ 'auto', 'person', 'vehicle', 'case' }, { default = 'auto' }) },
        { 'page', PAGE },
    }),
    CitizenInput = object({ { 'citizenid', CITIZEN_ID } }),
    PlateInput = object({ { 'plate', PLATE } }),
    BoloListInput = object({ { 'active', bool({ default = true }) }, { 'page', PAGE } }),
    BoloCreateInput = object({
        { 'kind', enum({ 'person', 'vehicle' }) },
        { 'citizenid', with(CITIZEN_ID, { optional = true }) },
        { 'plate', with(PLATE, { optional = true }) },
        { 'reason', str({ trim = true, min = 3, max = 500 }) },
        { 'level', with(LEVEL, { default = 0 }) },
        { 'expiresInHours', int({ min = 1, max = 720 }, { optional = true }) },
    }, { refine = boloRefine, refineField = 'kind' }),
    BoloResolveInput = object({
        { 'id', POSITIVE_ID },
        { 'note', str({ trim = true, max = 500 }, { default = '' }) },
    }),
    TabletListInput = object({ { 'page', PAGE } }),
    TabletRevokeInput = object({ { 'serial', str({ min = 1, max = 32 }) }, { 'revoked', bool() } }),
    TabletIssueInput = object({ { 'targetServerId', POSITIVE_ID } }),
    AlertListInput = object({
        { 'filter', enum({ 'open', 'mine', 'all' }, { default = 'open' }) },
        { 'page', PAGE },
    }),
    AlertIdInput = object({ { 'id', POSITIVE_ID } }),
    EvidenceListInput = object({
        { 'caseId', with(POSITIVE_ID, { optional = true }) },
        { 'unlinked', bool({ default = false }) },
        { 'page', PAGE },
    }),
    EvidenceIdInput = object({ { 'id', POSITIVE_ID } }),
    EvidenceLinkInput = object({ { 'id', POSITIVE_ID }, { 'caseId', POSITIVE_ID } }),
}

--- Tablet action -> input shape name. Every key is an action the dispatcher knows; the client registers one NUI
--- callback per key.
M.ACTIONS = {
    -- MDT_ACTIONS (mdt.ts)
    close = 'Empty',
    getHome = 'Empty',
    search = 'SearchInput',
    getPerson = 'CitizenInput',
    getVehicle = 'PlateInput',
    checkPlate = 'PlateInput',
    listBolos = 'BoloListInput',
    createBolo = 'BoloCreateInput',
    resolveBolo = 'BoloResolveInput',
    listTablets = 'TabletListInput',
    setTabletRevoked = 'TabletRevokeInput',
    -- DISPATCH_ACTIONS (dispatch.ts, §C13)
    listAlerts = 'AlertListInput',
    takeAlert = 'AlertIdInput',
    leaveAlert = 'AlertIdInput',
    closeAlert = 'AlertIdInput',
    getUnits = 'Empty',
    -- EVIDENCE_ACTIONS (evidence.ts, §C16)
    listEvidence = 'EvidenceListInput',
    getEvidence = 'EvidenceIdInput',
    linkEvidence = 'EvidenceLinkInput',
}

---------------------------------------------------------------------------------------------------------------
-- Validation

local function copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end

--- Validate `input` against a shape (a SHAPES entry or its name).
--- @return table|nil cleaned, string|nil field the first offending field ('input' for the object itself)
function M.check(shape, input)
    if type(shape) == 'string' then shape = M.SHAPES[shape] end
    if type(shape) ~= 'table' then return nil, 'shape' end
    -- zod objects reject arrays; a Lua table with [1] set is a non-empty array (an empty one looks like {}).
    if type(input) ~= 'table' or rawget(input, 1) ~= nil then return nil, 'input' end
    local out = {}
    for _, pair in ipairs(shape.fields) do
        local name, f = pair[1], pair[2]
        local v = rawget(input, name)
        if v == nil then
            if f.default ~= nil then
                out[name] = copy(f.default)
            elseif not f.optional then
                return nil, name
            end
        else
            local cleaned = CHECKS[f.kind](f, v)
            if cleaned == nil then return nil, name end
            out[name] = cleaned
        end
    end
    if shape.strict then
        for k in pairs(input) do
            if type(k) ~= 'string' or not shape.byName[k] then return nil, tostring(k) end
        end
    end
    if shape.refine and not shape.refine(out) then return nil, shape.refineField or 'input' end
    return out
end

--- Is `action` a known tablet action?
function M.isAction(action)
    return type(action) == 'string' and rawget(M.ACTIONS, action) ~= nil
end

--- Validate the input of a tablet action.
--- @return table|nil cleaned, string|nil field ('action' for an unknown action)
function M.validate(action, input)
    if not M.isAction(action) then return nil, 'action' end
    return M.check(M.ACTIONS[action], input)
end

--- Sorted list of action names (client NUI callbacks, docs, tests).
function M.actionNames()
    local names = {}
    for name in pairs(M.ACTIONS) do names[#names + 1] = name end
    table.sort(names)
    return names
end

return M
