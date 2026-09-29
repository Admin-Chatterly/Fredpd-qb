// SPDX-License-Identifier: GPL-3.0-only
import { describe, expect, it } from 'vitest';
import { AdminRoleGrantsPutBodySchema } from '@fredpd/types/actions';
import type { AdminRolesResponse } from '@fredpd/types/actions';
import type { RoleGrantRow } from '@fredpd/types/grants';
import {
  buildColumns,
  buildPutBody,
  cellId,
  changeCount,
  cycleCell,
  effectiveEffect,
  NEW_KEY_KINDS,
  nextEffect,
  parseCellId,
  parseNewKey,
  replaceRoleRows,
  savedEffects,
  sortRoles,
  withoutRole,
} from '../src/permissions/matrix';
import type { Drafts } from '../src/permissions/matrix';

const ROLE = '111111111111111111';
const OTHER = '222222222222222222';

const rows: RoleGrantRow[] = [
  { discordRoleId: ROLE, grantType: 'unit', grantKey: 'igv', effect: 'allow' },
  { discordRoleId: ROLE, grantType: 'weapon', grantKey: 'WEAPON_STUNGUN', effect: 'allow' },
  { discordRoleId: ROLE, grantType: 'perm', grantKey: 'rank:inspektor', effect: 'allow' },
  { discordRoleId: OTHER, grantType: 'mdt_page', grantKey: '*', effect: 'allow' },
];

describe('cell cycling', () => {
  it('cycles none -> allow -> deny -> none', () => {
    expect(nextEffect('none')).toBe('allow');
    expect(nextEffect('allow')).toBe('deny');
    expect(nextEffect('deny')).toBe('none');
  });

  it('keeps only changed cells in the draft and drops a cell that returns to its saved value', () => {
    const saved = savedEffects(rows, ROLE);
    const page = cellId('mdt_page', 'alerts');
    let drafts: Drafts = {};
    drafts = cycleCell(drafts, ROLE, page, saved);
    expect(effectiveEffect(saved, drafts[ROLE], page)).toBe('allow');
    drafts = cycleCell(drafts, ROLE, page, saved);
    expect(drafts[ROLE]).toEqual({ 'mdt_page:alerts': 'deny' });
    expect(changeCount(drafts, ROLE)).toBe(1);
    drafts = cycleCell(drafts, ROLE, page, saved);
    expect(drafts).toEqual({});

    // A saved allow: one click is a deny (change), two clicks none (change), three back to saved (no change).
    const unit = cellId('unit', 'igv');
    drafts = cycleCell(drafts, ROLE, unit, saved);
    expect(drafts[ROLE]).toEqual({ 'unit:igv': 'deny' });
    drafts = cycleCell(drafts, ROLE, unit, saved);
    expect(drafts[ROLE]).toEqual({ 'unit:igv': 'none' });
    drafts = cycleCell(drafts, ROLE, unit, saved);
    expect(drafts).toEqual({});
  });

  it('keeps roles apart', () => {
    const drafts = cycleCell(cycleCell({}, ROLE, 'tool:ram', new Map()), OTHER, 'tool:ram', new Map());
    expect(Object.keys(drafts).sort()).toEqual([ROLE, OTHER]);
    expect(withoutRole(drafts, ROLE)).toEqual({ [OTHER]: { 'tool:ram': 'allow' } });
  });

  it('splits cell ids at the first colon (perm keys may contain one)', () => {
    expect(parseCellId(cellId('perm', 'rank:inspektor'))).toEqual({ grantType: 'perm', grantKey: 'rank:inspektor' });
  });
});

describe('PUT body', () => {
  it('sends every effective row of the role, none dropped, ordered by type then key', () => {
    const saved = savedEffects(rows, ROLE);
    let drafts: Drafts = {};
    drafts = cycleCell(drafts, ROLE, 'mdt_page:search', saved); // allow
    drafts = cycleCell(drafts, ROLE, 'mdt_page:alerts', saved); // allow
    drafts = cycleCell(drafts, ROLE, 'mdt_page:alerts', saved); // deny
    drafts = cycleCell(drafts, ROLE, 'unit:igv', saved); // deny
    drafts = cycleCell(drafts, ROLE, 'unit:igv', saved); // none -> removed
    const body = buildPutBody(saved, drafts[ROLE]);
    expect(body).toEqual({
      grants: [
        { grantType: 'weapon', grantKey: 'WEAPON_STUNGUN', effect: 'allow' },
        { grantType: 'mdt_page', grantKey: 'alerts', effect: 'deny' },
        { grantType: 'mdt_page', grantKey: 'search', effect: 'allow' },
        { grantType: 'perm', grantKey: 'rank:inspektor', effect: 'allow' },
      ],
    });
    expect(AdminRoleGrantsPutBodySchema.parse(body)).toEqual(body);
  });

  it('is the saved rows unchanged without a draft, and empty when everything is cleared', () => {
    const saved = savedEffects(rows, ROLE);
    expect(buildPutBody(saved, undefined).grants).toHaveLength(3);
    const cleared = { 'unit:igv': 'none', 'weapon:WEAPON_STUNGUN': 'none', 'perm:rank:inspektor': 'none' } as const;
    expect(buildPutBody(saved, cleared)).toEqual({ grants: [] });
  });
});

describe('matrix layout', () => {
  it('sorts roles by Discord position, highest first', () => {
    const roles = [
      { discordRoleId: '1', name: 'Polis', position: 3, deleted: false },
      { discordRoleId: '2', name: 'Ledning', position: 9, deleted: false },
      { discordRoleId: '3', name: 'Aspirant', position: 3, deleted: false },
    ];
    expect(sortRoles(roles).map((r) => r.name)).toEqual(['Ledning', 'Aspirant', 'Polis']);
  });

  it('groups columns by type: catalog keys first (wildcard leading), then stored and MDT page keys', () => {
    const catalog = [
      { type: 'unit' as const, keys: ['*', 'ledning', 'igv'] },
      { type: 'mdt_page' as const, keys: ['*', 'alerts'] },
    ];
    const columns = buildColumns(catalog, [...rows, { discordRoleId: ROLE, grantType: 'unit', grantKey: 'hund', effect: 'allow' }]);
    expect(columns.map((c) => c.type)).toEqual(['weapon', 'vehicle', 'armory', 'tool', 'mdt_page', 'intel_tier', 'unit', 'perm']);
    expect(columns.find((c) => c.type === 'unit')?.keys).toEqual(['*', 'ledning', 'igv', 'hund']);
    expect(columns.find((c) => c.type === 'mdt_page')?.keys).toEqual([
      '*', 'alerts', 'bolos', 'cases', 'charges', 'command', 'evidence', 'intel', 'roster', 'search',
    ]);
    expect(columns.find((c) => c.type === 'weapon')?.keys).toEqual(['*', 'WEAPON_STUNGUN']);
    expect(columns.find((c) => c.type === 'vehicle')?.keys).toEqual(['*']);
  });

  it('adds locally added columns to their type, sorted with the stored-only keys', () => {
    const columns = buildColumns([{ type: 'weapon', keys: ['*'] }], rows, ['weapon:WEAPON_PISTOL', 'perm:rank:kommissarie', 'weapon:WEAPON_STUNGUN']);
    expect(columns.find((c) => c.type === 'weapon')?.keys).toEqual(['*', 'WEAPON_PISTOL', 'WEAPON_STUNGUN']);
    expect(columns.find((c) => c.type === 'perm')?.keys).toEqual(['*', 'rank:inspektor', 'rank:kommissarie']);
  });

  it('replaces one role’s rows in the cached response', () => {
    const data: AdminRolesResponse = { roles: [], grants: rows, catalog: [] };
    const next = replaceRoleRows(data, ROLE, [{ grantType: 'tool', grantKey: 'ram', effect: 'deny' }]);
    expect(next.grants).toEqual([rows[3], { discordRoleId: ROLE, grantType: 'tool', grantKey: 'ram', effect: 'deny' }]);
    expect(data.grants).toHaveLength(4);
  });
});

describe('parseNewKey (add column)', () => {
  it('accepts free-form keys the service accepts', () => {
    expect(parseNewKey('weapon', ' WEAPON_PISTOL ')).toBe('weapon:WEAPON_PISTOL');
    expect(parseNewKey('vehicle', 'polis_volvo')).toBe('vehicle:polis_volvo');
    expect(parseNewKey('armory', 'mpd.lspd-1')).toBe('armory:mpd.lspd-1');
    expect(parseNewKey('perm', 'records.admin')).toBe('perm:records.admin');
  });

  it('does not offer unit: every unit the service accepts is already a catalog column', () => {
    expect(NEW_KEY_KINDS).not.toContain('unit');
  });

  it('prefixes ranks with rank: once', () => {
    expect(parseNewKey('rank', 'kommissarie')).toBe('perm:rank:kommissarie');
    expect(parseNewKey('rank', 'rank:inspektor')).toBe('perm:rank:inspektor');
    expect(parseNewKey('rank', '*')).toBeNull();
    expect(parseNewKey('rank', 'rank:')).toBeNull();
  });

  it('refuses what the PUT body schema would refuse', () => {
    expect(parseNewKey('weapon', '')).toBeNull();
    expect(parseNewKey('weapon', '   ')).toBeNull();
    expect(parseNewKey('weapon', 'två ord')).toBeNull();
    expect(parseNewKey('rank', 'inspektör')).toBeNull(); // non-ASCII (docs/contracts.md §C2)
    expect(parseNewKey('tool', 'x'.repeat(65))).toBeNull();
  });
});
