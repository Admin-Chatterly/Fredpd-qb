// SPDX-License-Identifier: GPL-3.0-only
// Admin catalog (docs/contracts.md §C10, §C12): every mdt_page key, every pinned perm and tool is always listed, the
// PUT validator accepts every listed key, every perm an action registry checks is known, and each perm/tool has a
// label. Pure: no database.
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { AdminRoleGrantsPutBodySchema } from '@fredpd/types/actions';
import { DISPATCH_ACTIONS } from '@fredpd/types/dispatch';
import { EVIDENCE_ACTIONS } from '@fredpd/types/evidence';
import { GRANT_TYPES } from '@fredpd/types/grants';
import type { GrantType } from '@fredpd/types/grants';
import { INTEL_ACTIONS } from '@fredpd/types/intel';
import { MDT_ACTIONS } from '@fredpd/types/mdt';
import { MDT_PAGE_KEYS, isMdtPageKey } from '@fredpd/types/mdtPages';
import { RECORDS_ACTIONS } from '@fredpd/types/records';
import { MDT_PAGE_KEYS as UI_MDT_PAGE_KEYS } from '../../../packages/ui/src/mdtPages';
import { buildCatalog, KNOWN_PERMS, KNOWN_TOOLS } from '../src/catalog';
import { loadUnitCodes } from '../src/units';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const UNITS = loadUnitCodes();

/** §C12: perm keys the service catalog must list. */
const C12_PERMS = ['admin.permissions', 'records.admin', 'bolo.create', 'bolo.resolve', 'tablets.manage', 'intel.read', 'intel.handler', 'intel.command'];

const keysOf = (catalog: ReturnType<typeof buildCatalog>, type: GrantType) => catalog.find((c) => c.type === type)?.keys ?? [];

describe('buildCatalog', () => {
  it('lists one entry per grant type, each starting with the wildcard', () => {
    const catalog = buildCatalog(UNITS, []);
    expect(catalog.map((c) => c.type)).toEqual([...GRANT_TYPES]);
    for (const c of catalog) expect(c.keys[0], c.type).toBe('*');
  });

  it('always lists every mdt_page key, in nav order, even when no role uses one', () => {
    const catalog = buildCatalog(UNITS, []);
    expect(keysOf(catalog, 'mdt_page')).toEqual(['*', ...MDT_PAGE_KEYS]);
    expect(MDT_PAGE_KEYS).toEqual(['search', 'alerts', 'bolos', 'cases', 'evidence', 'intel', 'charges', 'roster', 'command']);
  });

  it('always lists the §C12 perms and tool:ram', () => {
    const catalog = buildCatalog(UNITS, []);
    expect(keysOf(catalog, 'perm')).toEqual(expect.arrayContaining(C12_PERMS));
    expect(keysOf(catalog, 'perm')).toEqual(['*', ...[...KNOWN_PERMS].sort()]);
    expect(keysOf(catalog, 'tool')).toEqual(['*', 'ram']);
    expect(keysOf(catalog, 'intel_tier')).toEqual(['*', '0', '1', '2']);
    expect(keysOf(catalog, 'unit')).toEqual(['*', ...UNITS]);
  });

  it('adds keys in use once, sorted after the fixed order (units and pages) or by code unit', () => {
    const catalog = buildCatalog(['igv', 'span'], [
      { grantType: 'mdt_page', grantKey: 'legacy' },
      { grantType: 'mdt_page', grantKey: 'search' },
      { grantType: 'unit', grantKey: 'nord' },
      { grantType: 'perm', grantKey: 'rank:inspektor' },
      { grantType: 'perm', grantKey: 'bolo.create' },
      { grantType: 'weapon', grantKey: 'pistol' },
      { grantType: 'weapon', grantKey: 'WEAPON_STUNGUN' },
      { grantType: 'weapon', grantKey: 'pistol' },
    ]);
    expect(keysOf(catalog, 'mdt_page')).toEqual(['*', ...MDT_PAGE_KEYS, 'legacy']);
    expect(keysOf(catalog, 'unit')).toEqual(['*', 'igv', 'span', 'nord']);
    expect(keysOf(catalog, 'perm').filter((k) => k === 'bolo.create')).toHaveLength(1);
    expect(keysOf(catalog, 'perm')).toContain('rank:inspektor');
    expect(keysOf(catalog, 'weapon')).toEqual(['*', 'WEAPON_STUNGUN', 'pistol']);
  });

  it('the PUT validator accepts every catalog key, as allow and as deny', () => {
    const catalog = buildCatalog(UNITS, [{ grantType: 'perm', grantKey: 'rank:kommissarie' }]);
    for (const effect of ['allow', 'deny'] as const) {
      const grants = catalog.flatMap((c) => c.keys.map((grantKey) => ({ grantType: c.type, grantKey, effect })));
      const parsed = AdminRoleGrantsPutBodySchema.safeParse({ grants });
      expect(parsed.success, JSON.stringify(parsed.error?.issues.slice(0, 3))).toBe(true);
      expect(parsed.data?.grants).toHaveLength(grants.length);
    }
  });
});

describe('catalog completeness', () => {
  const registries = { MDT_ACTIONS, DISPATCH_ACTIONS, RECORDS_ACTIONS, INTEL_ACTIONS, EVIDENCE_ACTIONS };
  const grantsOf = () =>
    Object.entries(registries).flatMap(([registry, actions]) =>
      Object.entries(actions as Record<string, { grant: readonly [string, string] | null }>).flatMap(([action, def]) =>
        def.grant ? [{ where: `${registry}.${action}`, type: def.grant[0], key: def.grant[1] }] : [],
      ),
    );

  it('every perm an action registry checks is in KNOWN_PERMS', () => {
    const perms = grantsOf().filter((g) => g.type === 'perm');
    expect(perms.length).toBeGreaterThan(0);
    for (const g of perms) expect(KNOWN_PERMS as readonly string[], g.where).toContain(g.key);
  });

  it('every mdt_page an action registry checks is an MDT_PAGE_KEYS entry', () => {
    const pages = grantsOf().filter((g) => g.type === 'mdt_page');
    expect(pages.length).toBeGreaterThan(0);
    for (const g of pages) expect(isMdtPageKey(g.key), g.where).toBe(true);
  });

  it('@fredpd/ui re-exports the same keys', () => {
    expect(UI_MDT_PAGE_KEYS).toBe(MDT_PAGE_KEYS);
  });

  it('every known perm and tool has a sv and en label (locales or locales/pending)', () => {
    const labels: Record<'sv' | 'en', Set<string>> = { sv: new Set(), en: new Set() };
    for (const lang of ['sv', 'en'] as const) {
      Object.keys(JSON.parse(readFileSync(join(REPO, 'locales', `${lang}.json`), 'utf8')) as object).forEach((k) => labels[lang].add(k));
    }
    const pendingDir = join(REPO, 'locales', 'pending');
    const pendingFiles = existsSync(pendingDir) ? readdirSync(pendingDir).filter((f) => f.endsWith('.json')) : [];
    for (const file of pendingFiles) {
      const data = JSON.parse(readFileSync(join(pendingDir, file), 'utf8')) as Record<string, { sv?: string; en?: string }>;
      for (const [key, text] of Object.entries(data)) {
        if (key.startsWith('$')) continue;
        if (text.sv) labels.sv.add(key);
        if (text.en) labels.en.add(key);
      }
    }
    const wanted = [...KNOWN_PERMS.map((p) => `perms.perm.${p}`), ...KNOWN_TOOLS.map((t) => `perms.tool.${t}`)];
    for (const key of wanted) {
      expect(labels.sv.has(key), `sv ${key}`).toBe(true);
      expect(labels.en.has(key), `en ${key}`).toBe(true);
    }
  });
});
