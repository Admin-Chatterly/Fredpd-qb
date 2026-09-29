-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_forensics shared/evidence.lua (pure): item mapping, uids, result whitelist, same-evidence check, custody
-- actions, uid registry identity, chain holder, input validation (mirror of packages/types/src/evidence.ts), lab boxes.
-- Run: lua5.4 tests/lua/run.lua forensics_shared
local FORENSICS = './resources/[fredpd]/fredpd_forensics/'

local function load()
    package.loaded['shared.evidence'] = nil
    local saved = package.path
    package.path = FORENSICS .. '?.lua;' .. package.path
    local ok, mod = pcall(require, 'shared.evidence')
    package.path = saved
    package.loaded['shared.evidence'] = nil -- fredpd_core has shared/* too: never leave ours cached
    if not ok then error(mod, 0) end
    return mod
end

local E = load()
local tests = {}

tests['01 item map: every evidences collected item, types in EvidenceTypeSchema'] = function(t)
    local names = { 'collected_fingerprint', 'collected_blood', 'collected_saliva', 'collected_casing',
        'collected_bullet', 'collected_magazine', 'collected_gunshot_residue' }
    for _, n in ipairs(names) do
        local info = E.itemInfo(n)
        t.ok(info, n)
        t.ok(E.TYPES[info.type], n .. ' type')
    end
    t.eq(E.itemInfo('collected_fingerprint'), { type = 'fingerprint', key = 'fingerprint' })
    t.eq(E.itemInfo('collected_blood').key, 'dna')
    t.eq(E.itemInfo('collected_bullet').type, 'projectile')
    t.eq(E.itemInfo('water'), nil)
    t.eq(E.itemInfo(nil), nil)
    t.eq(E.itemInfo('x', { x = { type = 'nonsense', key = 'k' } }), nil, 'unknown type rejected')
    local filter = E.itemFilter(nil, { evidence_box = true })
    t.eq(filter.collected_casing, true)
    t.eq(filter.evidence_box, true)
    t.eq(filter.forensic_kit, nil)
end

tests['02 uids: fixed shape, unique per counter, validated'] = function(t)
    local a = E.newUid(1790000000, 1, 0xBEEF)
    local b = E.newUid(1790000000, 2, 0xBEEF)
    t.eq(#a, 18)
    t.ok(a ~= b)
    t.eq(a, 'EV6AB13B800001BEEF')
    t.ok(E.isUid(a))
    t.ok(not E.isUid('EV123'), 'short')
    t.ok(not E.isUid('XX6AB13B800001BEEF'), 'prefix')
    t.ok(not E.isUid(12), 'number')
    t.ok(not E.isUid("EV6AB13B80000'BEEF"), 'quote')
end

tests['03 strings: control characters, length in characters, invalid UTF-8, identifiers'] = function(t)
    t.eq(E.cleanString('  Vespucci\nBlvd  ', 100), 'Vespucci Blvd')
    t.eq(E.cleanString(('å'):rep(10), 4), 'åååå')
    t.eq(E.cleanString('a\255b', 10), 'ab')
    t.eq(E.cleanString('', 10), nil)
    t.eq(E.cleanString({}, 10), nil)
    t.eq(E.cleanString(12, 10), '12')
    t.eq(E.identifier('A1B2C3D4E5F60718'), 'A1B2C3D4E5F60718')
    t.eq(E.identifier('ATGC-12'), 'ATGC-12')
    t.eq(E.identifier("x' OR 1"), nil)
    t.eq(E.identifier(('A'):rep(33)), nil)
    t.eq(E.citizenid('ABC12345'), 'ABC12345')
    t.eq(E.citizenid('a b'), nil)
    t.eq(E.isoFromEpoch(1790000000), '2026-09-21T14:13:20Z')
    t.eq(E.isoFromEpoch(12), nil)
    t.eq(E.isoOrNil('2026-09-29T12:00:00Z'), '2026-09-29T12:00:00Z')
    t.eq(E.isoOrNil('2026-09-29 12:00:00'), nil)
end

local FINGER = E.itemInfo('collected_fingerprint')
local CASING = E.itemInfo('collected_casing')

local function fpMeta(owner, extra)
    local md = {
        item_uid = 'EV6AB13B800001BEEF',
        fingerprint = { owner = owner or 'A1B2C3D4E5F60718', createdAt = 1790000000, analysed = true },
        information = { crimeScene = 'Vespucci Blvd', collectionTime = '29.09.2026 14:02', additionalData = 'På dörren',
            fingerprint = owner or 'A1B2C3D4E5F60718' },
        ballistics = {},
        description = 'x',
    }
    for k, v in pairs(extra or {}) do md[k] = v end
    return md
end

tests['04 result: whitelist only, match only as { citizenid, name }'] = function(t)
    local md = fpMeta(nil, { imageurl = 'https://evil', label = 'x', ['__proto__'] = 1 })
    md.information.injected = '<img>'
    local r = E.buildResult(FINGER, md, { citizenid = 'SUS00001', name = 'Sven Svensson', extra = true })
    t.eq(r, { fingerprint = 'A1B2C3D4E5F60718', crimeScene = 'Vespucci Blvd', collectionTime = '29.09.2026 14:02',
        note = 'På dörren', match = { citizenid = 'SUS00001', name = 'Sven Svensson' } })
    local casing = {
        ballistics = { owner = 'SERIAL123', serial = 'SERIAL123', weaponType = 'Pistol', type = 'casing',
            imperfections = 'SECRET', analysed = true, weaponImage = 'x.png' },
    }
    t.eq(E.buildResult(CASING, casing, nil), { serial = 'SERIAL123', weaponType = 'Pistol', kind = 'casing' })
    casing.ballistics.serial = nil
    casing.ballistics.type = 'rocket'
    t.eq(E.buildResult(CASING, casing, nil), { weaponType = 'Pistol' }, 'scratched serial and unknown kind dropped')
    t.eq(E.buildResult(FINGER, {}, { citizenid = 'bad id' }), {}, 'bad match citizenid dropped')
end

tests['05 same evidence: identifier / ballistics tuple; masked result drops only match'] = function(t)
    local stored = E.buildResult(FINGER, fpMeta(), nil)
    t.ok(E.sameEvidence(FINGER, stored, fpMeta()))
    t.ok(not E.sameEvidence(FINGER, stored, fpMeta('FFFFFFFFFFFFFFFF')))
    t.ok(E.sameEvidence(FINGER, nil, fpMeta('FFFFFFFFFFFFFFFF')), 'nothing stored yet')
    local b = { ballistics = { serial = 'S1', weaponType = 'Pistol', type = 'casing' } }
    local sb = E.buildResult(CASING, b, nil)
    t.ok(E.sameEvidence(CASING, sb, b))
    t.ok(not E.sameEvidence(CASING, sb, { ballistics = { serial = 'S2', weaponType = 'Pistol', type = 'casing' } }))
    local full = { fingerprint = 'A', match = { citizenid = 'X', name = 'Y' }, analysedAt = '2026-09-29T12:00:00Z' }
    t.eq(E.visibleResult(full, true), full)
    t.eq(E.visibleResult(full, false), { fingerprint = 'A', analysedAt = '2026-09-29T12:00:00Z' })
    t.eq(E.visibleResult(nil, true), nil)
end

tests['06 custody: hand-in, checkout, return, transfer, ignored moves'] = function(t)
    local P = { '^evidence_', '^evidence%-%d+$' }
    t.eq({ E.moveAction(1, 'evidence_locker_mrpd', P, nil) }, { 'handin', 'evidence_locker_mrpd' })
    t.eq({ E.moveAction(1, 'evidence-3', P, 'handin') }, { 'handin', 'evidence-3' })
    t.eq({ E.moveAction('evidence_locker_mrpd', 2, P, 'handin') }, { 'checkout', 'evidence_locker_mrpd' })
    t.eq({ E.moveAction(2, 'evidence_locker_mrpd', P, 'checkout') }, { 'return', 'evidence_locker_mrpd' })
    t.eq({ E.moveAction('evidence_locker_mrpd', 'evidence-7', P, 'handin') }, { 'transfer', 'evidence-7' })
    t.eq(E.moveAction('evidence_locker_mrpd', 'evidence_locker_mrpd', P, nil), nil, 'inside one locker')
    t.eq(E.moveAction(1, 2, P, nil), nil, 'player to player')
    t.eq(E.moveAction(1, 'ABC1790000000', P, nil), nil, 'into an evidence_box container')
    t.eq(E.moveAction(1, 'evidence-x', P, nil), nil, 'not an ox policeevidence id')
    t.eq(E.lastLockerAction({ { action = 'collect' }, { action = 'handin' }, { action = 'analyse' } }), 'handin')
    t.eq(E.lastLockerAction({ { action = 'collect' } }), nil)
    -- a hand-over between people (transfer without a locker location) is not a locker action
    local handedOver = { { action = 'collect' }, { action = 'handin', location = 'evidence_locker_mrpd' },
        { action = 'checkout', location = 'evidence_locker_mrpd' }, { action = 'transfer', actor = 'B' } }
    t.eq(E.lastLockerAction(handedOver, P), 'checkout')
    t.eq(E.lastLockerAction(handedOver), 'transfer', 'without patterns every transfer counts')
    t.eq(E.lastLockerAction({ { action = 'transfer', location = 'evidence-3' } }, P), 'transfer')
end

tests['09 uid registry identity and the chain holder'] = function(t)
    t.eq(E.identity(FINGER, fpMeta()), 'fingerprint:' .. fpMeta().fingerprint.owner)
    t.eq(E.identity(E.itemInfo('collected_saliva'), { dna = { owner = 'ATGC-1' } }), 'dna:ATGC-1')
    t.eq(E.identity(FINGER, {}), nil, 'no evidence written yet')
    t.eq(E.identity(FINGER, { fingerprint = { owner = 'bad owner!' } }), nil)
    t.eq(E.identity(CASING, { ballistics = { owner = 'S1', serial = 'S1', weaponType = 'Pistol', type = 'casing',
        imperfections = 'x' } }), 'ballistics:S1|S1|Pistol|casing')
    t.eq(E.identity(CASING, { ballistics = { owner = 'SCR4TCH' } }), 'ballistics:SCR4TCH|||', 'scratched serial')
    t.eq(E.identity(CASING, { ballistics = {} }), nil)
    t.eq(E.currentHolder({ { action = 'collect', actor = 'A' } }), { actor = 'A' })
    t.eq(E.currentHolder({ { action = 'collect', actor = 'A' }, { action = 'handin', actor = 'A',
        location = 'evidence_locker_mrpd' }, { action = 'analyse', actor = 'T' } }), { location = 'evidence_locker_mrpd' })
    t.eq(E.currentHolder({ { action = 'collect' }, { action = 'transfer', actor = 'B' }, { action = 'link' } }),
        { actor = 'B' })
    t.eq(E.currentHolder({ { action = 'collect', actor = 'A' }, { action = 'transfer', location = 'evidence-4' } }),
        { location = 'evidence-4' })
    t.eq(E.currentHolder({ { action = 'collect' } }), nil, 'legacy collect without actor')
    t.eq(E.currentHolder(nil), nil)
end

tests['07 inputs mirror evidence.ts: list defaults, positive ints, link, case number'] = function(t)
    t.eq(E.listInput(nil), { unlinked = false, page = 1 })
    t.eq(E.listInput({ caseId = 4, page = 2 }), { caseId = 4, unlinked = false, page = 2 })
    t.eq(E.listInput({ unlinked = true }), { unlinked = true, page = 1 })
    t.eq({ E.listInput({ caseId = 0 }) }, { nil, 'caseId' })
    t.eq({ E.listInput({ caseId = 1.5 }) }, { nil, 'caseId' })
    t.eq({ E.listInput({ unlinked = 'yes' }) }, { nil, 'unlinked' })
    t.eq({ E.listInput({ page = 10001 }) }, { nil, 'page' })
    t.eq({ E.listInput('x') }, { nil, 'input' })
    t.eq(E.idInput({ id = 7 }), 7)
    t.eq(E.idInput({ id = -1 }), nil)
    t.eq(E.idInput({ id = '7' }), nil)
    t.eq(E.linkInput({ id = 1, caseId = 2 }), { id = 1, caseId = 2 })
    t.eq({ E.linkInput({ id = 1 }) }, { nil, 'caseId' })
    local isCase = function(v) return v:match('^K%-%d+%-%d%d$') ~= nil end
    t.eq(E.caseNumberInput(' k-123-26 ', isCase), 'K-123-26')
    t.eq(E.caseNumberInput('K -123- 26', isCase), 'K-123-26', 'stray spaces removed')
    t.eq(E.caseNumberInput('K 123-26', isCase), nil, 'K123-26 does not match the pattern')
    t.eq(E.caseNumberInput('K-123-26', isCase), 'K-123-26')
    t.eq(E.caseNumberInput('K-12', isCase), nil)
    t.eq(E.caseNumberInput("K-1'; DROP", isCase), nil)
    t.eq(E.caseNumberInput(123, isCase), nil)
end

tests['08 lab boxes: rotated box containment and lab lookup'] = function(t)
    local lab = { id = 'lab', coords = { x = 10, y = 20, z = 30 }, size = { x = 4, y = 2, z = 3 }, rotation = 90 }
    t.ok(E.inBox({ x = 10, y = 21.9, z = 30 }, lab), 'rotated: 4 m along y')
    t.ok(not E.inBox({ x = 11.5, y = 20, z = 30 }, lab), 'rotated: 2 m along x')
    t.ok(not E.inBox({ x = 10, y = 20, z = 32 }, lab), 'height')
    t.eq(E.labAt({ x = 10, y = 20, z = 30 }, { lab }), 'lab')
    t.eq(E.labAt({ x = 0, y = 0, z = 0 }, { lab }), nil)
    t.eq(E.inBox(nil, lab), false)
end

return tests
