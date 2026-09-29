-- SPDX-License-Identifier: GPL-3.0-only
-- Pure helpers for fredpd_forensics (docs/modules/forensics.md, docs/contracts.md §C16): evidence item mapping,
-- item uids, the whitelisted analysis result, custody actions for inventory moves, input validation mirroring
-- packages/types/src/evidence.ts, and a point-in-box test for the lab zones. Plain Lua 5.4, no FiveM natives, so
-- tests/lua/forensics_shared_test.lua runs it outside the game.

local M = {}

M.PAGE_SIZE = 50 -- PAGE_SIZE in packages/types/src/mdt.ts
M.MAX_PAGE = 10000
M.CHAIN_CAP = 200 -- custody entries kept per evidence row (the first, 'collect', is never dropped)
M.UID_PATTERN = '^EV%x+$'
M.UID_LENGTH = 18

--- EvidenceTypeSchema (evidence.ts).
M.TYPES = {
    fingerprint = true, dna = true, blood = true, casing = true, projectile = true, toolmark = true, fiber = true,
    photo = true, other = true,
}

--- CustodyActionSchema (evidence.ts).
M.ACTIONS = { collect = true, handin = true, analyse = true, link = true, checkout = true, ['return'] = true,
    transfer = true }

--- evidences' collected items (noobsystems/evidences common/evidence_types.lua `collectedItem`) -> FredPD type and
--- the metadata key evidences writes the evidence under (`superClassName`, server/evidences/classes/*.lua).
M.DEFAULT_ITEMS = {
    collected_fingerprint = { type = 'fingerprint', key = 'fingerprint' },
    collected_blood = { type = 'blood', key = 'dna' },
    collected_saliva = { type = 'dna', key = 'dna' },
    collected_casing = { type = 'casing', key = 'ballistics' },
    collected_bullet = { type = 'projectile', key = 'ballistics' },
    collected_magazine = { type = 'other', key = 'ballistics' },
    collected_gunshot_residue = { type = 'other', key = 'ballistics' },
}

--- Ballistics evidence kinds evidences writes into metadata.ballistics.type.
local BALLISTIC_KINDS = { casing = true, bullet = true, magazine = true, gunshot_residue = true }

---------------------------------------------------------------------------------------------------------------
-- Strings

--- Untrusted text -> trimmed string of at most `max` characters (UTF-8 code points), control characters replaced by
--- spaces, invalid UTF-8 dropped; nil for anything that is not a non-empty string (numbers are stringified).
function M.cleanString(v, max)
    if type(v) == 'number' then v = tostring(v) end
    if type(v) ~= 'string' then return nil end
    v = v:sub(1, (max or 200) * 4)
    if not utf8.len(v) then
        local out, i = {}, 1
        for _ = 1, #v do
            if i > #v then break end
            if utf8.len(v, i, i) then
                local cp = utf8.codepoint(v, i)
                local size = cp < 0x80 and 1 or cp < 0x800 and 2 or cp < 0x10000 and 3 or 4
                out[#out + 1] = v:sub(i, i + size - 1)
                i = i + size
            else
                i = i + 1
            end
        end
        v = table.concat(out)
    end
    v = v:gsub('[%c]', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if v == '' then return nil end
    local n = utf8.len(v)
    if n and n > (max or 200) then
        v = v:sub(1, utf8.offset(v, (max or 200) + 1) - 1):gsub('%s+$', '')
    end
    return v
end

--- An evidences identifier (fingerprint FFFF…, DNA ATGC…, weapon serial): 1–32 characters of [A-Za-z0-9-].
function M.identifier(v)
    if type(v) ~= 'string' or #v < 1 or #v > 32 or not v:match('^[%w%-]+$') then return nil end
    return v
end

--- A qbx citizenid as stored in FredPD tables (VARCHAR(50)).
function M.citizenid(v)
    if type(v) ~= 'string' or #v < 1 or #v > 50 or not v:match('^[%w_%-]+$') then return nil end
    return v
end

---------------------------------------------------------------------------------------------------------------
-- Items and uids

--- { type, key } for an ox_inventory item name, or nil when it is not an evidence item.
function M.itemInfo(name, items)
    if type(name) ~= 'string' then return nil end
    local info = (items or M.DEFAULT_ITEMS)[name]
    if type(info) ~= 'table' or not M.TYPES[info.type] or type(info.key) ~= 'string' then return nil end
    return info
end

--- ox_inventory hook itemFilter ({ [name] = true }) for the evidence items plus extra names (containers).
function M.itemFilter(items, extra)
    local out = {}
    for name in pairs(items or M.DEFAULT_ITEMS) do out[name] = true end
    for name in pairs(extra or {}) do out[name] = true end
    return out
end

--- New item uid: 'EV' + 8 hex digits of the epoch second + 4 of a per-boot counter + 4 random (18 characters).
function M.newUid(epoch, counter, random)
    return ('EV%08X%04X%04X'):format(math.tointeger(epoch or 0) & 0xFFFFFFFF, math.tointeger(counter or 0) & 0xFFFF,
        math.tointeger(random or 0) & 0xFFFF)
end

function M.isUid(v)
    return type(v) == 'string' and #v == M.UID_LENGTH and v:match(M.UID_PATTERN) ~= nil
end

--- ISO-8601 UTC for an epoch in seconds (evidences stamps metadata[key].createdAt with the server's os.time()).
--- Only plausible instants (2020..2100) are accepted; anything else is nil.
function M.isoFromEpoch(sec)
    sec = tonumber(sec)
    if not sec or sec ~= sec or sec < 1577836800 or sec > 4102444800 then return nil end
    return os.date('!%Y-%m-%dT%H:%M:%SZ', math.floor(sec))
end

--- A wire timestamp we wrote ourselves into item metadata ('YYYY-MM-DDTHH:MM:SSZ'), else nil.
function M.isoOrNil(v)
    if type(v) ~= 'string' or not v:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$') then return nil end
    return v
end

---------------------------------------------------------------------------------------------------------------
-- Analysis result (EvidenceItemSchema.result): a whitelist of what evidences put into the item metadata.

--- The evidence identity evidences stored on the item: { identifier, serial, weaponType, kind } (all optional).
function M.evidenceOf(info, metadata)
    local md = type(metadata) == 'table' and metadata or {}
    local ev = type(md[info.key]) == 'table' and md[info.key] or {}
    if info.key == 'ballistics' then
        local kind = type(ev.type) == 'string' and BALLISTIC_KINDS[ev.type] and ev.type or nil
        return {
            serial = M.identifier(ev.serial),
            weaponType = M.cleanString(ev.weaponType, 64),
            kind = kind,
            analysed = ev.analysed == true,
        }
    end
    return { identifier = M.identifier(ev.owner), analysed = ev.analysed == true }
end

--- Result JSON stored in fredpd_evidence.result. `match` = { citizenid, name } from the registers or nil.
function M.buildResult(info, metadata, match)
    local md = type(metadata) == 'table' and metadata or {}
    local ev = M.evidenceOf(info, md)
    local information = type(md.information) == 'table' and md.information or {}
    local r = {}
    if info.key == 'fingerprint' then
        r.fingerprint = ev.identifier
    elseif info.key == 'dna' then
        r.dna = ev.identifier
    else
        r.serial = ev.serial
        r.weaponType = ev.weaponType
        r.kind = ev.kind
    end
    -- Collected by evidences' client (street name, local clock, free text): shown as reported, not verified.
    r.crimeScene = M.cleanString(information.crimeScene, 100)
    r.collectionTime = M.cleanString(information.collectionTime, 32)
    r.note = M.cleanString(information.additionalData, 200)
    if type(match) == 'table' and M.citizenid(match.citizenid) then
        r.match = { citizenid = match.citizenid, name = M.cleanString(match.name, 100) or match.citizenid }
    end
    return r
end

--- Evidence identity for fredpd_evidence.ident (db/migrations/011_evidence.sql): 'fingerprint:<string>',
--- 'dna:<string>' or 'ballistics:<owner>|<serial>|<weapon type>|<kind>'; nil while the item carries no evidence
--- (before evidences' atItem wrote it). Recorded the first time FredPD sees the uid and compared on every later event.
function M.identity(info, metadata)
    local md = type(metadata) == 'table' and metadata or {}
    local ev = md[info.key]
    if type(ev) ~= 'table' then return nil end
    if info.key == 'ballistics' then
        local e = M.evidenceOf(info, md)
        local owner = M.identifier(ev.owner)
        if not owner and not e.serial then return nil end
        return ('ballistics:%s|%s|%s|%s'):format(owner or '', e.serial or '', e.weaponType or '', e.kind or '')
    end
    local id = M.identifier(ev.owner)
    return id and (info.key .. ':' .. id) or nil
end

--- Same evidence? Compares a stored result with the evidence now on the item (fingerprint/DNA string, or the
--- ballistics serial + weapon type + kind). Used to refuse an item carrying another evidence's uid.
function M.sameEvidence(info, result, metadata)
    if type(result) ~= 'table' then return true end
    local ev = M.evidenceOf(info, metadata)
    if info.key == 'fingerprint' then return result.fingerprint == ev.identifier end
    if info.key == 'dna' then return result.dna == ev.identifier end
    return result.serial == ev.serial and result.weaponType == ev.weaponType and result.kind == ev.kind
end

--- The result as a viewer may see it: without `match` unless the person match is visible to them.
function M.visibleResult(result, showMatch)
    if type(result) ~= 'table' then return nil end
    local out = {}
    for k, v in pairs(result) do
        if k ~= 'match' or showMatch then out[k] = v end
    end
    return out
end

---------------------------------------------------------------------------------------------------------------
-- Custody

--- Whether an inventory id is an evidence locker (ox_inventory ids are numbers for players, strings otherwise).
function M.isLocker(inv, patterns)
    if inv == nil then return false end
    inv = tostring(inv)
    for _, p in ipairs(patterns or {}) do
        if inv:match(p) then return true end
    end
    return false
end

--- A 'transfer' entry between lockers (location = a locker id) as opposed to a hand-over to a person or another
--- inventory (location nil or not a locker). Without `patterns` every transfer counts as a locker one.
local function lockerTransfer(e, patterns)
    return e.action == 'transfer' and (patterns == nil or M.isLocker(e.location, patterns))
end

--- The last custody action among the locker ones (handin, checkout, return, locker-to-locker transfer) in a decoded
--- chain. A hand-over between people (transfer without a locker location) is skipped, so evidence checked out,
--- handed to a colleague and put back is still a 'return'.
function M.lastLockerAction(chain, patterns)
    if type(chain) ~= 'table' then return nil end
    for i = #chain, 1, -1 do
        local e = type(chain[i]) == 'table' and chain[i] or {}
        local a = e.action
        if a == 'handin' or a == 'checkout' or a == 'return' or lockerTransfer(e, patterns) then return a end
    end
    return nil
end

--- Who or what holds the evidence according to the chain: { actor = citizenid } after collect / checkout / a
--- hand-over to a person, { location = inventory id } after handin / return / a transfer to a locker or another
--- inventory, nil when unknown (e.g. a legacy collect without actor). analyse and link change nothing.
function M.currentHolder(chain)
    if type(chain) ~= 'table' then return nil end
    for i = #chain, 1, -1 do
        local e = type(chain[i]) == 'table' and chain[i] or {}
        local a = e.action
        if a == 'collect' or a == 'checkout' then
            return type(e.actor) == 'string' and { actor = e.actor } or nil
        elseif a == 'handin' or a == 'return' then
            return type(e.location) == 'string' and { location = e.location } or nil
        elseif a == 'transfer' then
            if type(e.location) == 'string' then return { location = e.location } end
            return type(e.actor) == 'string' and { actor = e.actor } or nil
        end
    end
    return nil
end

--- Custody action for an item moved from `from` to `to`, or nil when the move is not a custody event:
--- into a locker = handin (return after a checkout), out of a locker = checkout, locker to another locker =
--- transfer, anything inside one inventory or between non-lockers = nil.
function M.moveAction(from, to, patterns, lastAction)
    if from == nil or to == nil or tostring(from) == tostring(to) then return nil end
    local fromLocker, toLocker = M.isLocker(from, patterns), M.isLocker(to, patterns)
    if fromLocker and toLocker then return 'transfer', tostring(to) end
    if toLocker then return lastAction == 'checkout' and 'return' or 'handin', tostring(to) end
    if fromLocker then return 'checkout', tostring(from) end
    return nil
end

---------------------------------------------------------------------------------------------------------------
-- Input validation (Lua mirror of EvidenceListInputSchema / { id } / EvidenceLinkInputSchema)

local function posInt(v, max)
    if type(v) ~= 'number' or v ~= v then return nil end
    local i = math.tointeger(v)
    if not i or i < 1 or i > (max or 2147483647) then return nil end
    return i
end
M.posInt = posInt

--- { caseId?, unlinked, page } or nil, field.
function M.listInput(input)
    if input == nil then input = {} end
    if type(input) ~= 'table' then return nil, 'input' end
    local out = { unlinked = false, page = 1 }
    if input.caseId ~= nil then
        out.caseId = posInt(input.caseId)
        if not out.caseId then return nil, 'caseId' end
    end
    if input.unlinked ~= nil then
        if type(input.unlinked) ~= 'boolean' then return nil, 'unlinked' end
        out.unlinked = input.unlinked
    end
    if input.page ~= nil then
        out.page = posInt(input.page, M.MAX_PAGE)
        if not out.page then return nil, 'page' end
    end
    return out
end

--- id or nil.
function M.idInput(input)
    if type(input) ~= 'table' then return nil end
    return posInt(input.id)
end

--- { id, caseId } or nil, field.
function M.linkInput(input)
    if type(input) ~= 'table' then return nil, 'input' end
    local id = posInt(input.id)
    if not id then return nil, 'id' end
    local caseId = posInt(input.caseId)
    if not caseId then return nil, 'caseId' end
    return { id = id, caseId = caseId }
end

--- Case number typed in the dialog: trimmed, upper case, inner spaces removed, 3–32 characters, checked against
--- the anchored caseNumber pattern (shared/format.lua templateToRegex) by `matches(normalized)`.
function M.caseNumberInput(v, matches)
    if type(v) ~= 'string' then return nil end
    v = v:gsub('%s+', ''):upper()
    if #v < 3 or #v > 32 or not v:match('^[%w%-/]+$') then return nil end
    if matches and not matches(v) then return nil end
    return v
end

---------------------------------------------------------------------------------------------------------------
-- Lab zones: is a point inside an (optionally rotated, degrees around z) box { coords, size, rotation }?

function M.inBox(point, box)
    if type(point) ~= 'table' and type(point) ~= 'userdata' then return false end
    if type(box) ~= 'table' or not box.coords or not box.size then return false end
    local px, py, pz = tonumber(point.x), tonumber(point.y), tonumber(point.z)
    if not px or not py or not pz then return false end
    local dx, dy, dz = px - box.coords.x, py - box.coords.y, pz - box.coords.z
    local r = math.rad(-(tonumber(box.rotation) or 0))
    local lx = dx * math.cos(r) - dy * math.sin(r)
    local ly = dx * math.sin(r) + dy * math.cos(r)
    return math.abs(lx) <= box.size.x / 2 and math.abs(ly) <= box.size.y / 2 and math.abs(dz) <= box.size.z / 2
end

--- Id of the lab containing `point`, or nil.
function M.labAt(point, labs)
    for _, lab in ipairs(labs or {}) do
        if M.inBox(point, lab) then return lab.id end
    end
    return nil
end

return M
