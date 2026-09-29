// SPDX-License-Identifier: GPL-3.0-only
// The Phase 3–5b dev mocks (src/mock/sections.ts) answer every DISPATCH/EVIDENCE/RECORDS/INTEL action with data that
// parses with the action's zod output schema, as built and as Lua sends it (nulls removed, restored by normalizeWire),
// for several units and tiers; together with src/mock/handlers.ts they cover every tablet action.
import { describe, expect, it } from 'vitest';
import { TABLET_ACTIONS, TABLET_ACTION_NAMES } from '../src/api/actions';
import { normalizeWire, toLuaWire } from '../src/api/wire';
import { createMockDb } from '../src/mock/data';
import { createMockHandlers } from '../src/mock/handlers';
import { SECTION_ACTIONS, createSectionMocks, parseChargesSeed } from '../src/mock/sections';
import type { SectionActionName } from '../src/mock/sections';
import chargesSeed from '../../../db/seed/charges_sv.sql?raw';
import { FIXED_NOW, ME } from './helpers';

function setup(unit: string | null = 'igv', tier: 0 | 1 | 2 = 1) {
  const db = createMockDb({ me: ME, tier, unit, now: () => FIXED_NOW });
  return { db, handlers: createSectionMocks(db) };
}

/** Representative inputs per action (several where the answer shape varies: full / masked / notice). */
const INPUTS: { [A in SectionActionName]: unknown[] } = {
  listAlerts: [{ filter: 'open', page: 1 }, { filter: 'mine', page: 1 }, { filter: 'all', page: 1 }],
  takeAlert: [{ id: 306 }],
  leaveAlert: [{ id: 304 }],
  closeAlert: [{ id: 304 }],
  getUnits: [{}],
  listEvidence: [{ unlinked: true, page: 1 }, { unlinked: false, page: 1 }, { caseId: 1042, page: 1 }],
  getEvidence: [{ id: 41 }, { id: 57 }, { id: 59 }],
  linkEvidence: [{ id: 57, caseId: 1042 }],
  listCases: [{ filter: 'mine', page: 1 }, { filter: 'all', page: 1 }, { filter: 'closed', page: 1 }, { filter: 'all', query: 'rån', page: 1 }],
  getCase: [{ id: 1042 }, { id: 988 }, { id: 1077 }, { id: 1120 }],
  createCase: [{ title: 'Inbrott i villa, Rockford Hills', level: 0 }],
  updateCase: [{ id: 1042, title: 'Grovt rån mot värdetransport', summary: '' }],
  assignCase: [{ id: 1042, citizenid: 'OFF00003', role: 'member' }],
  unassignCase: [{ id: 1042, citizenid: 'OFF00005' }],
  addCaseSubject: [{ id: 1101, type: 'person', citizenid: 'FPD00003', role: 'witness' }, { id: 1101, type: 'vehicle', plate: 'GHJ55B' }],
  closeCase: [{ id: 1101, resolution: 'Gärningspersonen lagförd.' }],
  getReport: [{ id: 811 }, { id: 820 }],
  createReport: [{ caseId: 1042, title: 'Förhör med vittne', templateId: 1 }],
  saveReport: [{ id: 820, title: 'Anmälan: misshandel', body: '# Ny text', level: 0 }],
  saveReportDraft: [{ reportId: 820, body: 'utkast' }],
  listReportTemplates: [{}],
  listCharges: [{}, { query: 'rån' }, { class: 'ordningsbot' }],
  applyCharges: [{ reportId: 820, citizenid: 'FPD00002', lines: [{ code: 'BRB-005', quantity: 2 }] }],
  issueFine: [{ citizenid: 'FPD00002', lines: [{ code: ordningsbotCode(), quantity: 1 }] }],
  listSources: [{ page: 1 }],
  getSource: [{ id: 11 }, { id: 12 }, { id: 13 }],
  createSource: [{ codename: 'Hägern', reliability: 'B', level: 1 }],
  updateSource: [{ id: 11, notes: '' }],
  listIntelReports: [{ page: 1 }, { missionId: 21, page: 1 }, { sourceId: 11, page: 1 }],
  getIntelReport: [{ id: 31 }, { id: 33 }],
  createIntelReport: [{ body: 'Ny uppgift om Vagos.', missionId: 21, level: 1 }],
  searchEntities: [{ query: 'Er' }, { query: 'Vagos', type: 'group' }],
  ensureEntity: [{ type: 'location', label: 'Paleto Bay bensinstation' }],
  getEntity: [{ id: 1 }, { id: 7 }, { id: 8 }],
  addLink: [{ fromId: 1, to: { id: 5 }, type: 'associate' }, { fromId: 1, to: { type: 'group', label: 'Lost MC' }, type: 'member_of', level: 0 }],
  getGraph: [{ entityId: 1, depth: 1 }, { entityId: 1, depth: 2 }, { entityId: 8, depth: 1 }],
  listMissions: [{ page: 1 }],
  getMission: [{ id: 21 }, { id: 22 }],
  createMission: [{ title: 'Insats Björk', level: 1 }],
  addMissionMember: [{ id: 21, citizenid: 'OFF00003', role: 'Spanare' }],
  closeMission: [{ id: 21 }],
};

function ordningsbotCode(): string {
  return parseChargesSeed(chargesSeed).find((c) => c.class === 'ordningsbot')?.code ?? 'missing';
}

describe('section mocks vs packages/types', () => {
  it('together with the Phase 2 mocks cover every tablet action, and inputs cover every section mock', () => {
    const db = createMockDb({ me: ME, tier: 1, unit: 'igv', now: () => FIXED_NOW });
    const all = [...Object.keys(createMockHandlers(db)), ...Object.keys(createSectionMocks(db))].sort();
    expect(all).toEqual([...TABLET_ACTION_NAMES].sort());
    expect(Object.keys(INPUTS).sort()).toEqual([...SECTION_ACTIONS].sort());
  });

  it('the catalogue is the real seed (db/seed/charges_sv.sql)', () => {
    const charges = parseChargesSeed(chargesSeed);
    expect(charges.length).toBeGreaterThan(100);
    expect(new Set(charges.map((c) => c.class))).toEqual(new Set(['ordningsbot', 'bot', 'fängelse']));
    expect(charges.find((c) => c.code === 'BRB-023')).toMatchObject({ title: 'Grovt rån', class: 'fängelse', fine: 20000, jailMinutes: 40 });
  });

  for (const action of SECTION_ACTIONS) {
    it(`${action}: every answer parses with the output schema, as built and after the Lua wire round trip`, () => {
      for (const [unit, tier] of [['igv', 1], ['span', 2], [null, 0]] as const) {
        const { handlers } = setup(unit, tier);
        const handler = handlers[action] as (input: unknown) => unknown;
        const schema = TABLET_ACTIONS[action].output;
        for (const input of INPUTS[action]) {
          const answer = handler(input);
          if (tier === 0 && typeof answer === 'object' && answer !== null && 'error' in answer) continue; // level > tier refusals
          expect(answer, `${action} ${JSON.stringify(input)} (${unit}, ${tier})`).not.toHaveProperty('error');
          const direct = schema.safeParse(answer);
          expect(direct.success, JSON.stringify(direct.error?.issues)).toBe(true);
          const viaLua = normalizeWire(schema, JSON.parse(JSON.stringify(toLuaWire(answer))));
          const parsed = schema.safeParse(viaLua);
          expect(parsed.success, JSON.stringify(parsed.error?.issues)).toBe(true);
          expect(viaLua).toEqual(answer);
        }
      }
    });
  }

  it('shapes follow canView: notice answers carry only the contact, masked sources no identity, lists no identity', () => {
    const { handlers } = setup();
    expect(handlers.getCase({ id: 1077 })).toEqual({ visibility: 'notice', contact: { displayName: 'Bo Carlsson', unit: 'span' } });
    const masked = handlers.getCase({ id: 988 }) as { visibility: string; title: unknown; summary: unknown };
    expect(masked).toMatchObject({ visibility: 'masked', title: null, summary: null });
    expect(Object.keys(handlers.getSource({ id: 12 }) as object).sort()).toEqual(['codename', 'id', 'level', 'reliability', 'status', 'visibility']);
    expect((handlers.getSource({ id: 11 }) as { realIdentity: unknown }).realIdentity).toEqual({ citizenid: 'FPD00005', name: 'Mohammed Hassan' });
    const listed = handlers.listSources({ page: 1 }) as { items: { visibility: string; realIdentity?: unknown }[] };
    expect(listed.items.filter((s) => s.visibility === 'full').every((s) => s.realIdentity === null)).toBe(true);
    expect(handlers.getIntelReport({ id: 33 })).toMatchObject({ visibility: 'notice' });
  });

  it('refusals: closed case writes, non-ordningsbot fines, linking twice, graph cap', () => {
    const { handlers } = setup();
    expect(handlers.assignCase({ id: 1120, citizenid: 'OFF00003' })).toEqual({ error: 'unauthorized' });
    expect(handlers.assignCase({ id: 1077, citizenid: 'OFF00003' })).toEqual({ error: 'not_found' });
    expect(handlers.issueFine({ citizenid: 'FPD00002', lines: [{ code: 'BRB-005' }] })).toEqual({ error: 'validation', reason: 'class' });
    expect(handlers.linkEvidence({ id: 41, caseId: 1042 })).toEqual({ error: 'validation', reason: 'already_linked' });
    expect(handlers.getReport({ id: 813 })).toEqual({ error: 'not_found' }); // level 2 > tier 1
    const graph = handlers.getGraph({ entityId: 8, depth: 1 }) as { nodes: unknown[]; truncated: boolean };
    expect(graph.nodes).toHaveLength(150);
    expect(graph.truncated).toBe(true);
  });
});
