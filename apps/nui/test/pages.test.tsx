// SPDX-License-Identifier: GPL-3.0-only
// Phase 3–5b pages together: every route renders its mock data (no error state) for several tiers/units, the nav
// keeps its 6-slot cap with every section granted, and every literal key read with tx() exists in sv and en
// (locales/sv.json + en.json, or a pending file).
import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, screen } from '@testing-library/react';
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import sv from '../../../locales/sv.json';
import en from '../../../locales/en.json';
import { buildNav, MAX_NAV_ITEMS } from '../src/nav';
import { clearNuiMocks } from '../src/utils/fetchNui';
import { installMockRegister, renderAt } from './helpers';

afterEach(() => {
  cleanup();
  clearNuiMocks();
});

const ROUTES: [string, RegExp][] = [
  ['/larm', /Skottlossning/],
  ['/arenden', /K-1042-26/],
  ['/arende/1042', /Grovt rån mot värdetransport/],
  ['/rapport/811', /K-1042-26-R01/],
  ['/brottskatalog', /Brottskatalog/],
  ['/bevis', /Fingeravtryck/],
  ['/intel/objekt/1', /Erik Nilsson/],
  ['/intel/kallor', /KORPEN/],
  ['/intel/rapporter', /KORPEN uppger/],
  ['/intel/insatser', /Insats Nattfjäril/],
];

describe('every Phase 3–5b page renders its mocks', () => {
  for (const tier of [1, 2] as const) {
    for (const [path, expected] of ROUTES) {
      it(`${path} (tier ${tier})`, async () => {
        installMockRegister({ tier, unit: tier === 2 ? 'span' : 'igv' });
        renderAt(path, ['mdt_page:*', 'perm:intel.read'], { tier, unit: tier === 2 ? 'span' : 'igv' });
        expect((await screen.findAllByText(expected)).length).toBeGreaterThan(0);
        expect(document.body.textContent).not.toMatch(/Något gick fel|Kunde inte ansluta|Uppgiften hittades inte/);
      });
    }
  }
});

describe('navigation with every section', () => {
  it('keeps at most 6 visible entries (the rest behind Meny)', () => {
    const nav = buildNav({ grants: ['mdt_page:*'], denied: [] }, 'utredning');
    expect(nav.items.length + 1).toBeLessThanOrEqual(MAX_NAV_ITEMS);
    expect(nav.items.length + nav.overflow.length).toBe(10);
  });
});

describe('locale keys read with tx()', () => {
  const walk = (dir: string): string[] =>
    readdirSync(dir).flatMap((f) => {
      const p = join(dir, f);
      return statSync(p).isDirectory() ? walk(p) : /\.tsx?$/.test(f) ? [p] : [];
    });
  const pendingDir = join(__dirname, '../../../locales/pending');
  const pending: Record<string, { sv?: string; en?: string }> = Object.assign(
    {},
    ...readdirSync(pendingDir)
      .filter((f) => f.endsWith('.json'))
      .map((f) => JSON.parse(readFileSync(join(pendingDir, f), 'utf8')) as Record<string, { sv?: string; en?: string }>),
  );
  const has = (key: string, lang: 'sv' | 'en') => key in (lang === 'sv' ? sv : en) || !!pending[key]?.[lang];

  it('every literal tx() key and case filter key exists in both languages', () => {
    const keys = new Set<string>();
    for (const file of walk(join(__dirname, '../src'))) {
      const text = readFileSync(file, 'utf8');
      for (const m of text.matchAll(/\btx\('([a-zA-Z0-9_.]+)'/g)) keys.add(m[1]!);
      for (const m of text.matchAll(/'(case\.filter\.[a-z]+)'/g)) keys.add(m[1]!);
    }
    expect(keys.size).toBeGreaterThan(20);
    expect([...keys].filter((k) => !has(k, 'sv') || !has(k, 'en'))).toEqual([]);
  });

  it('nui-pages.json (until merged) only adds keys that sv.json does not have yet', () => {
    const file = join(pendingDir, 'nui-pages.json');
    if (!existsSync(file)) return;
    const mine = JSON.parse(readFileSync(file, 'utf8')) as Record<string, unknown>;
    expect(Object.keys(mine).filter((k) => k in sv)).toEqual([]);
  });
});
