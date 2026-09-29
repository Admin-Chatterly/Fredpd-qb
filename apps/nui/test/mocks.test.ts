// SPDX-License-Identifier: GPL-3.0-only
// The browser dev mocks answer every tablet action with data that parses with the action's zod output schema
// (packages/types/src/mdt.ts), both as built (nulls present) and as Lua sends it (nulls removed, then restored by
// normalizeWire), so `pnpm --filter @fredpd/nui dev` demos the same shapes the game delivers.
import { describe, expect, it } from 'vitest';
import { MDT_ACTIONS } from '@fredpd/types/mdt';
import type { MdtActionName } from '@fredpd/types/mdt';
import { normalizeWire, toLuaWire } from '../src/api/wire';
import { createMockDb } from '../src/mock/data';
import { createMockHandlers } from '../src/mock/handlers';
import { mockOpenPayload } from '../src/mock/dev';
import { FIXED_NOW, ME } from './helpers';

function setup(unit: string | null = 'igv', tier: 0 | 1 | 2 = 1) {
  const db = createMockDb({ me: ME, tier, unit, now: () => FIXED_NOW });
  return { db, handlers: createMockHandlers(db) };
}

/** Representative inputs per action (several per action where the answer shape varies). */
const INPUTS: { [A in MdtActionName]: unknown[] } = {
  close: [{}],
  getHome: [{}],
  search: [
    { query: 'Andersson', type: 'auto', page: 1 },
    { query: 'an', type: 'auto', page: 2 },
    { query: '19870412-5531', type: 'auto', page: 1 },
    { query: '870412-5531', type: 'person', page: 1 },
    { query: 'abc 12d', type: 'auto', page: 1 },
    { query: 'K-1042-26', type: 'auto', page: 1 },
    { query: 'K-988-26', type: 'case', page: 1 },
    { query: 'K-1077-26', type: 'auto', page: 1 },
    { query: 'zz', type: 'auto', page: 1 },
  ],
  getPerson: [{ citizenid: 'FPD00001' }, { citizenid: 'FPD00006' }, { citizenid: 'FPD00100' }],
  getVehicle: [{ plate: 'ABC12D' }, { plate: 'XYZ98A' }, { plate: 'KLM34F' }],
  checkPlate: [{ plate: 'ABC12D' }, { plate: 'gHJ 55b' }, { plate: 'NOP00X' }],
  listBolos: [{ active: true, page: 1 }, { active: false, page: 1 }],
  createBolo: [
    { kind: 'person', citizenid: 'FPD00002', reason: 'Misstänkt för misshandel.', level: 0, expiresInHours: 24 },
    { kind: 'vehicle', plate: 'GHJ55B', reason: 'Stulen i natt.', level: 1 },
  ],
  resolveBolo: [{ id: 1, note: 'Gripen.' }, { id: 2, note: '' }],
  listTablets: [{ page: 1 }],
  setTabletRevoked: [{ serial: 'PT-00013', revoked: true }, { serial: 'PT-00015', revoked: false }],
};

describe('dev mocks vs packages/types/src/mdt.ts', () => {
  it('has a mock for every action and inputs for every mock', () => {
    const { handlers } = setup();
    const actions = Object.keys(MDT_ACTIONS).sort();
    expect(Object.keys(handlers).sort()).toEqual(actions);
    expect(Object.keys(INPUTS).sort()).toEqual(actions);
  });

  for (const action of Object.keys(INPUTS) as MdtActionName[]) {
    it(`${action}: every answer parses with the output schema, as built and after the Lua wire round trip`, () => {
      for (const unit of ['igv', 'ledning', null]) {
        const { handlers } = setup(unit);
        const handler = handlers[action] as (input: unknown) => unknown;
        const schema = MDT_ACTIONS[action].output;
        for (const input of INPUTS[action]) {
          const answer = handler(input);
          expect(answer, `${action} ${JSON.stringify(input)}`).not.toHaveProperty('error');
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

  it('Ledning gets the roster; other variants an empty one', () => {
    const ledning = setup('ledning').handlers.getHome({}) as { variant: string; roster: unknown[] };
    expect(ledning.variant).toBe('ledning');
    expect(ledning.roster.length).toBeGreaterThan(0);
    const igv = setup('igv').handlers.getHome({}) as { variant: string; roster: unknown[] };
    expect(igv).toMatchObject({ variant: 'igv', roster: [] });
  });

  it('refuses like the server: validation, not_found, duplicate, level above tier, inactive', () => {
    const { handlers } = setup('igv', 0);
    expect(handlers.search({ query: 'x', type: 'auto', page: 1 })).toMatchObject({ error: 'validation' });
    expect(handlers.getPerson({ citizenid: 'NOPE' })).toEqual({ error: 'not_found' });
    expect(handlers.getVehicle({ plate: 'NOP00X' })).toEqual({ error: 'not_found' });
    expect(handlers.createBolo({ kind: 'person', citizenid: 'FPD00001', reason: 'Igen och igen' })).toEqual({ error: 'validation', reason: 'duplicate' });
    expect(handlers.createBolo({ kind: 'person', citizenid: 'FPD00002', reason: 'Hemlig sak', level: 1 })).toEqual({ error: 'unauthorized', reason: 'level' });
    expect(handlers.createBolo({ kind: 'person', citizenid: 'NOPE', reason: 'Finns inte' })).toEqual({ error: 'not_found' });
    expect(handlers.createBolo({ kind: 'person', plate: 'ABC12D', reason: 'Fel form' })).toMatchObject({ error: 'validation' });
    expect(handlers.resolveBolo({ id: 4 })).toEqual({ error: 'validation', reason: 'inactive' });
    expect(handlers.resolveBolo({ id: 999 })).toEqual({ error: 'not_found' });
    expect(handlers.setTabletRevoked({ serial: 'PT-99999', revoked: true })).toEqual({ error: 'not_found' });
  });

  it('create → list → resolve, and expired BOLOs drop out of the live list', () => {
    let now = FIXED_NOW;
    const db = createMockDb({ me: ME, tier: 1, unit: 'igv', now: () => now });
    const h = createMockHandlers(db);
    const created = h.createBolo({ kind: 'vehicle', plate: 'GHJ55B', reason: 'Stulen i natt.', expiresInHours: 1 }) as { id: number; expiresAt: string };
    expect(created.expiresAt).toBe('2026-09-29T11:00:00Z');
    const live = () => (h.listBolos({ active: true, page: 1 }) as { items: { id: number }[] }).items.map((b) => b.id);
    expect(live()).toContain(created.id);
    expect((h.search({ query: 'GHJ55B', type: 'auto', page: 1 }) as { hits: { bolo?: boolean }[] }).hits[0]?.bolo).toBe(true);
    now += 2 * 3_600_000;
    expect(live()).not.toContain(created.id);
    expect(h.resolveBolo({ id: 1, note: 'Gripen.' })).toMatchObject({ active: false, resolveNote: 'Gripen.', resolvedBy: ME });
    expect(live()).toEqual([2, 3]);
  });

  it('the dev open payload carries the perms and tier from the URL', () => {
    const payload = mockOpenPayload('?unit=span&pages=search,bolos&perms=bolo.create&tier=2');
    expect(payload.unit).toBe('span');
    expect(payload.grants.tier).toBe(2);
    expect(payload.grants.grants).toEqual(['intel_tier:2', 'mdt_page:bolos', 'mdt_page:search', 'perm:bolo.create', 'unit:span']);
    expect(mockOpenPayload('?perms=none').grants.grants.some((g) => g.startsWith('perm:'))).toBe(false);
    expect(mockOpenPayload('').grants.grants).toContain('perm:tablets.manage');
  });
});
