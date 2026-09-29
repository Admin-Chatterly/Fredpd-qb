-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_intel server/access.lua (pure): VisRecords for sources, missions, reports and links, evaluated with the
-- real shared/canview.lua over the seeded default rules (canView fixtures), plus notice and paging helpers.
-- Run: lua5.4 tests/lua/run.lua intel_access
local helper = require('helper')
local CanView = require('shared.canview')
local Access = dofile('./resources/[fredpd]/fredpd_intel/server/access.lua')

local RULES = helper.readJson('packages/types/test/fixtures/canView.fixtures.json').rules

local function viewer(cid, tier, grants)
    table.sort(grants)
    return { citizenid = cid, tier = tier, units = {}, grants = { grants = grants, denied = {}, tier = tier, units = {} } }
end

local SPAN = viewer('SPA00001', 2, { 'perm:intel.command', 'perm:intel.read' })
local HANDLER = viewer('HAN00002', 2, { 'perm:intel.handler', 'perm:intel.read' })
local IGV = viewer('IGV00003', 0, { 'mdt_page:intel' })
local UTR = viewer('UTR00004', 1, { 'perm:intel.read' })
local ANALYST = viewer('ANA00005', 2, { 'perm:intel.read' })

local function eval(v, record) return CanView.evaluate(v, record, RULES) end

local tests = {}

tests['min / visible / rank'] = function(t)
    t.eq(Access.min('full', 'notice'), 'notice')
    t.eq(Access.min('masked', 'full'), 'masked')
    t.eq(Access.min('full', 'bogus'), 'none')
    t.eq(Access.visible('masked'), true)
    t.eq(Access.visible('notice'), false)
end

tests['source records: identity cap and level cap'] = function(t)
    local s = Access.sourceRecord({ id = 1, level = 2, status = 'open', unit = 'span', handler = 'HAN00002' })
    t.eq(s, { type = 'intel_source', id = 1, level = 2, status = 'open', unit = 'span', handlerCitizenid = 'HAN00002' })
    t.eq(eval(HANDLER, s), 'full')
    t.eq(eval(SPAN, s), 'full')
    t.eq(eval(ANALYST, s), 'masked')
    t.eq(eval(UTR, s), 'notice', 'intel.read below the level: kontaktnotis')
    t.eq(eval(IGV, s), 'none')
    -- the handler who lost intel.handler keeps only the masked view
    t.eq(eval(viewer('HAN00002', 2, { 'perm:intel.read' }), s), 'masked')
end

tests['mission records: members and lead are assignees'] = function(t)
    local m = { id = 4, level = 2, status = 'open', unit = 'span', lead = 'SPA00001' }
    local members = { { citizenid = 'UTR00004' }, { citizenid = 'SPA00001' } }
    local r = Access.missionRecord(m, members)
    t.eq(r.assignees, { 'SPA00001', 'UTR00004' })
    t.eq(r.ownerCitizenid, 'SPA00001')
    t.eq(eval(UTR, r), 'full')
    t.eq(eval(IGV, r), 'notice')
    t.eq(eval(ANALYST, r), 'notice', 'missions are strict: intel.read alone is a kontaktnotis')
    t.eq(eval(SPAN, Access.missionRecord(m, {})), 'full')
end

tests['report records: author, mission members; level cap for intel.read'] = function(t)
    local m = { id = 4, level = 2, status = 'open', unit = 'span', lead = 'SPA00001' }
    local rep = { id = 9, level = 2, status = 'open', author = 'SPA00001', missionId = 4 }
    local r = Access.reportRecord(rep, m, { { citizenid = 'UTR00004' } })
    t.eq(r.assignees, { 'SPA00001', 'UTR00004' })
    t.eq(r.unit, 'span')
    t.eq(eval(UTR, r), 'full')
    t.eq(eval(IGV, r), 'none')
    local standalone = Access.reportRecord({ id = 10, level = 2, status = 'open', author = 'SPA00001' })
    t.eq(standalone.assignees, {})
    t.eq(eval(UTR, standalone), 'notice')
    t.eq(eval(ANALYST, standalone), 'full')
end

tests['link records inherit max(level, report level) and the report owner'] = function(t)
    local link = { id = 3, level = 0, createdBy = 'ANA00005', report = { id = 9, level = 2, status = 'open',
        author = 'SPA00001' } }
    t.eq(Access.linkLevel(link), 2)
    local r = Access.linkRecord(link)
    t.eq(r.level, 2)
    t.eq(r.ownerCitizenid, 'SPA00001')
    t.eq(r.assignees, { 'ANA00005' })
    t.eq(eval(UTR, r), 'notice')
    t.eq(eval(ANALYST, r), 'full')
    local bare = Access.linkRecord({ id = 4, level = 1, createdBy = 'ANA00005' })
    t.eq(bare, { type = 'intel_report', id = 4, level = 1, status = 'open', ownerCitizenid = 'ANA00005',
        assignees = { 'ANA00005' } })
    t.eq(eval(UTR, bare), 'full')
    t.eq(eval(IGV, bare), 'none')
    local withMission = Access.linkRecord({ id = 5, level = 1, createdBy = 'SPA00001',
        report = { id = 9, level = 1, status = 'closed', author = 'SPA00001' },
        mission = { id = 4, lead = 'SPA00001', unit = 'span' } }, { { citizenid = 'UTR00004' } })
    t.eq(withMission.assignees, { 'SPA00001', 'UTR00004' })
    t.eq(withMission.status, 'closed')
    t.eq(withMission.unit, 'span')
    t.eq(Access.linkLevel({ level = 7 }), 2, 'bad levels are the strictest')
end

tests['officer refs, notices (contact only), dedup, paging'] = function(t)
    local officers = { SPA00001 = { displayName = 'Sara S.', callsign = 'SPA-01', unit = 'span' } }
    t.eq(Access.officerRef('SPA00001', officers),
        { citizenid = 'SPA00001', displayName = 'Sara S.', callsign = 'SPA-01', unit = 'span' })
    t.eq(Access.officerRef('NOPE', officers), nil)
    t.eq(Access.memberRef('NOPE', officers), { citizenid = 'NOPE', displayName = 'NOPE' })
    t.eq(Access.notice('SPA00001', officers, nil), { visibility = 'notice', contact = { displayName = 'Sara S.', unit = 'span' } })
    t.eq(Access.notice('SPA00001', officers, 'narko'), { visibility = 'notice', contact = { displayName = 'Sara S.', unit = 'narko' } })
    t.eq(Access.notice('NOPE', officers), { visibility = 'notice', contact = {} })
    local a = Access.notice('SPA00001', officers)
    t.eq(#Access.uniqueNotices({ a, Access.notice('SPA00001', officers), Access.notice('NOPE', officers) }), 2)
    local list = {}
    for i = 1, 120 do list[i] = i end
    local p3, total = Access.page(list, 3, 50)
    t.eq(total, 120)
    t.eq(#p3, 20)
    t.eq(p3[1], 101)
    t.eq(#Access.page(list, 4, 50), 0)
end

return tests
