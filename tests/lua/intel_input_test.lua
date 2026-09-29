-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_intel shared/input.lua: the Lua mirror of the INTEL_ACTIONS input schemas (packages/types/src/intel.ts).
-- Run: lua5.4 tests/lua/run.lua intel_input
package.path = './resources/[fredpd]/fredpd_intel/?.lua;' .. package.path
package.loaded['shared.input'] = nil
local Input = dofile('./resources/[fredpd]/fredpd_intel/shared/input.lua')
local V = Input.validate

local tests = {}

tests['primitives: jsTrim, int, id, line, text, citizenId, plate'] = function(t)
    t.eq(Input.jsTrim('\u{00A0} a b \u{3000}\t'), 'a b')
    t.eq(Input.jsTrim('   '), '')
    t.eq(Input.int(1.0, 0, 2), 1)
    t.eq(Input.int(1.5), nil)
    t.eq(Input.int(0 / 0), nil)
    t.eq(Input.int('1'), nil)
    t.eq(Input.id(0), nil)
    t.eq(Input.id(2 ^ 53), nil)
    t.eq(Input.id(7), 7)
    t.eq(Input.line('  ab  ', 2, 4), 'ab')
    t.eq(Input.line('a\nb', 1, 10), nil, 'control characters refused in one-line fields')
    t.eq(Input.line('\xff\xfe', 0, 10), nil, 'invalid UTF-8')
    t.eq(Input.line('åäö', 3, 3), 'åäö', 'code points, not bytes')
    t.eq(Input.text(' a\r\nb\1c ', 1, 10), 'a\nb c')
    t.eq(Input.citizenId('ABC_12-3'), 'ABC_12-3')
    t.eq(Input.citizenId("A'; DROP"), nil)
    t.eq(Input.citizenId(('x'):rep(51)), nil)
    t.eq(Input.plate(' ab 123 '), 'AB123')
    t.eq(Input.plate('AB%'), nil)
    t.eq(Input.plate(('A'):rep(17)), nil)
end

tests['likePrefix escapes %, _ and the escape character itself'] = function(t)
    t.eq(Input.likePrefix('Sven'), 'Sven%')
    t.eq(Input.likePrefix('50%_off!'), '50!%!_off!!%')
    t.eq(Input.likePrefix("a' OR 1=1 --"), "a' OR 1=1 --%", 'quotes stay data (bound as a parameter)')
end

tests['createSource: defaults, trimming, unknown keys dropped (handler never taken from input)'] = function(t)
    local out = V.createSource({ codename = '  Falken ', handler = 'EVIL0001', handlerCitizenid = 'EVIL0001' })
    t.eq(out, { codename = 'Falken', reliability = 'C', level = 2 })
    t.eq(select(2, V.createSource({ codename = 'F' })), 'codename')
    t.eq(select(2, V.createSource({ codename = 'Falk', reliability = 'E' })), 'reliability')
    t.eq(select(2, V.createSource({ codename = 'Falk', level = 3 })), 'level')
    t.eq(select(2, V.createSource({ codename = 'Falk', realCitizenid = 'bad id' })), 'realCitizenid')
    t.eq(V.createSource({ codename = 'Falk', notes = '   ', realCitizenid = 'SUS00001', level = 1 }),
        { codename = 'Falk', reliability = 'C', realCitizenid = 'SUS00001', level = 1 })
    t.eq(select(2, V.createSource('x')), 'input')
end

tests['updateSource: empty notes clear them'] = function(t)
    t.eq(V.updateSource({ id = 3, notes = ' ' }), { id = 3, clearNotes = true })
    t.eq(V.updateSource({ id = 3, status = 'closed', reliability = 'A', notes = 'x' }),
        { id = 3, status = 'closed', reliability = 'A', notes = 'x' })
    t.eq(select(2, V.updateSource({ id = 3, status = 'gone' })), 'status')
    t.eq(select(2, V.updateSource({ id = -1 })), 'id')
end

tests['reports: body length, default level 1, list page default'] = function(t)
    t.eq(V.createIntelReport({ body = ' abc ' }), { body = 'abc', level = 1 })
    t.eq(select(2, V.createIntelReport({ body = 'ab' })), 'body')
    t.eq(select(2, V.createIntelReport({ body = ('x'):rep(50001) })), 'body')
    t.eq(select(2, V.createIntelReport({ body = 'abc', missionId = 0 })), 'missionId')
    t.eq(V.listIntelReports(nil), { page = 1 })
    t.eq(V.listIntelReports({ missionId = 4, page = 2 }), { missionId = 4, page = 2 })
    t.eq(select(2, V.listIntelReports({ page = 10001 })), 'page')
end

tests['entities: search query, ensureEntity, addLink union, graph depth'] = function(t)
    t.eq(V.searchEntities({ query = ' Sv ' }), { query = 'Sv' })
    t.eq(select(2, V.searchEntities({ query = 'S' })), 'query')
    t.eq(select(2, V.searchEntities({ query = 'Sven', type = 'boat' })), 'type')
    t.eq(V.ensureEntity({ type = 'location', label = ' Grove St ', ref = '' }), { type = 'location', label = 'Grove St' })
    t.eq(select(2, V.ensureEntity({ type = 'person', label = '' })), 'label')
    t.eq(V.addLink({ fromId = 1, to = { id = 2 }, type = 'owns' }),
        { fromId = 1, to = { id = 2 }, type = 'owns', confidence = 50, level = 1 })
    t.eq(V.addLink({ fromId = 1, to = { type = 'group', label = 'Ballas' }, type = 'member_of', confidence = 90,
        level = 2, reportId = 5 }),
        { fromId = 1, to = { type = 'group', label = 'Ballas' }, type = 'member_of', confidence = 90, level = 2,
            reportId = 5 })
    t.eq(select(2, V.addLink({ fromId = 1, to = { id = 0 }, type = 'owns' })), 'to')
    t.eq(select(2, V.addLink({ fromId = 1, to = { id = 2 }, type = 'owns', confidence = 101 })), 'confidence')
    t.eq(V.getGraph({ entityId = 4 }), { entityId = 4, depth = 1 })
    t.eq(select(2, V.getGraph({ entityId = 4, depth = 3 })), 'depth')
end

tests['missions: create defaults, unit shape, member input'] = function(t)
    t.eq(V.createMission({ title = ' Hemlig ' }), { title = 'Hemlig', level = 2 })
    t.eq(V.createMission({ title = 'Hemlig', unit = 'span', description = ' ' }), { title = 'Hemlig', level = 2, unit = 'span' })
    t.eq(select(2, V.createMission({ title = 'Hemlig', unit = 'sp an' })), 'unit')
    t.eq(V.addMissionMember({ id = 1, citizenid = 'UTR00004', role = ' spanare ' }),
        { id = 1, citizenid = 'UTR00004', role = 'spanare' })
    t.eq(select(2, V.addMissionMember({ id = 1, citizenid = 'x y' })), 'citizenid')
end

tests['entityRef normalises keyed refs'] = function(t)
    t.eq(Input.entityRef('person', 'SUS00001'), 'SUS00001')
    t.eq(Input.entityRef('person', 'SUS 1'), nil)
    t.eq(Input.entityRef('vehicle', 'abc 123'), 'ABC123')
    t.eq(Input.entityRef('case', 'K-123-26'), 'K-123-26')
    t.eq(Input.entityRef('case', "K'1"), nil)
    t.eq(Input.entityRef('location', 'free text'), 'free text')
    t.eq(Input.KEYED.location, nil)
end

return tests
