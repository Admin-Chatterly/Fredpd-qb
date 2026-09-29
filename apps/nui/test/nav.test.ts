// SPDX-License-Identifier: GPL-3.0-only
import { describe, expect, it } from 'vitest';
import { MAX_NAV_ITEMS, NAV_ENTRIES, activeNavId, allowedNavEntries, buildNav } from '../src/nav';
import { homeVariantFor } from '../src/units';
import { parseNuiMessage } from '../src/tablet/messages';

const lists = (grants: string[], denied: string[] = []) => ({ grants, denied });
const ids = (entries: { id: string }[]) => entries.map((e) => e.id);

describe('navigation filtered by mdt_page grants', () => {
  it('shows only Hem without grants', () => {
    expect(ids(buildNav(lists([]), null).items)).toEqual(['home']);
    expect(ids(buildNav(null, null).items)).toEqual(['home']);
  });

  it('shows the granted sections in base order', () => {
    const nav = buildNav(lists(['mdt_page:cases', 'mdt_page:search', 'unit:igv', 'weapon:*']), null);
    expect(ids(nav.items)).toEqual(['home', 'search', 'cases']);
    expect(nav.overflow).toEqual([]);
  });

  it('ignores grants of other types with the same key', () => {
    expect(ids(buildNav(lists(['perm:search', 'tool:alerts']), null).items)).toEqual(['home']);
  });

  it('never shows more than 6 items: with more allowed, the 6th slot is the menu', () => {
    const nav = buildNav(lists(['mdt_page:*']), null);
    expect(NAV_ENTRIES).toHaveLength(10);
    expect(nav.items).toHaveLength(MAX_NAV_ITEMS - 1);
    expect(ids(nav.items)).toEqual(['home', 'search', 'alerts', 'bolos', 'cases']);
    expect(ids(nav.overflow)).toEqual(['evidence', 'intel', 'charges', 'roster', 'command']);
  });

  it('shows exactly 6 items without a menu when 6 are allowed', () => {
    const six = ['search', 'alerts', 'bolos', 'cases', 'evidence'].map((p) => `mdt_page:${p}`);
    const nav = buildNav(lists(six), null);
    expect(nav.items).toHaveLength(6);
    expect(nav.overflow).toEqual([]);
  });

  it('applies denies, including over the wildcard', () => {
    const nav = buildNav(lists(['mdt_page:*'], ['mdt_page:intel', 'mdt_page:command']), null);
    expect(ids([...nav.items, ...nav.overflow])).not.toContain('intel');
    expect(ids([...nav.items, ...nav.overflow])).not.toContain('command');
    expect(ids(buildNav(lists(['mdt_page:*'], ['mdt_page:*']), null).items)).toEqual(['home']);
  });

  it('puts the primary unit’s sections first, keeping Hem first', () => {
    expect(ids(allowedNavEntries(lists(['mdt_page:*']), 'tekniker')).slice(0, 3)).toEqual(['home', 'evidence', 'cases']);
    expect(ids(buildNav(lists(['mdt_page:*']), 'ledning').items)).toEqual(['home', 'command', 'roster', 'alerts', 'search']);
    // A priority page without its grant is simply absent.
    expect(ids(buildNav(lists(['mdt_page:search', 'mdt_page:bolos']), 'igv').items)).toEqual(['home', 'search', 'bolos']);
    // Unknown unit: base order.
    expect(ids(buildNav(lists(['mdt_page:alerts', 'mdt_page:search']), 'hundforare').items)).toEqual(['home', 'search', 'alerts']);
  });

  it('maps paths (detail pages included) to the active entry', () => {
    expect(activeNavId('/')).toBe('home');
    expect(activeNavId('/sok')).toBe('search');
    expect(activeNavId('/person/ABC123')).toBe('search');
    expect(activeNavId('/fordon/ABC12D')).toBe('search');
    expect(activeNavId('/arende/K-1-26')).toBe('cases');
    expect(activeNavId('/rapport/7')).toBe('cases');
    expect(activeNavId('/intel/kallor')).toBe('intel');
    expect(activeNavId('/ledning')).toBe('command');
    expect(activeNavId('/larmx')).toBeUndefined();
    expect(activeNavId('/okand')).toBeUndefined();
  });
});

describe('Hem variant by primary unit (config/units.json home)', () => {
  it('uses the configured variant, default otherwise', () => {
    expect(homeVariantFor('igv')).toBe('igv');
    expect(homeVariantFor('tekniker')).toBe('tekniker');
    expect(homeVariantFor('ledning')).toBe('ledning');
    expect(homeVariantFor(null)).toBe('default');
    expect(homeVariantFor('okand')).toBe('default');
  });
});

describe('Lua messages', () => {
  const grantSet = { grants: ['mdt_page:*'], denied: [], tier: 0, units: ['igv'], rank: null, computedAt: '2026-09-29T10:00:00.000Z' };
  const me = { citizenid: 'ABC12345', displayName: 'Anna B.', callsign: 'IGV-07' };

  it('reads open with the payload next to action', () => {
    expect(parseNuiMessage({ action: 'open', grants: grantSet, unit: 'igv', me })).toEqual({
      action: 'open',
      payload: { grants: grantSet, unit: 'igv', me },
    });
  });

  it('accepts what Lua sends for nil and empty tables', () => {
    const luaGrants = { grants: ['mdt_page:search'], denied: {}, tier: 0, units: {}, computedAt: '2026-09-29T10:00:00.000Z' };
    const parsed = parseNuiMessage({ action: 'open', grants: luaGrants, me: { citizenid: 'ABC12345', displayName: 'Anna B.' } });
    expect(parsed).toEqual({
      action: 'open',
      payload: { grants: { ...luaGrants, denied: [], units: [], rank: null }, unit: null, me: { citizenid: 'ABC12345', displayName: 'Anna B.', callsign: null } },
    });
  });

  it('keeps a null payload for an invalid open and ignores foreign messages', () => {
    expect(parseNuiMessage({ action: 'open', grants: 'all' })).toEqual({ action: 'open', payload: null });
    expect(parseNuiMessage({ type: 'something-else' })).toBeNull();
    expect(parseNuiMessage('open')).toBeNull();
    expect(parseNuiMessage({ action: 'push' })).toBeNull();
    expect(parseNuiMessage({ action: 'unknown' })).toBeNull();
  });

  it('reads push topics; the grants topic carries a GrantSet', () => {
    expect(parseNuiMessage({ action: 'push', topic: 'alerts', payload: { id: 1 } })).toEqual({ action: 'push', topic: 'alerts', payload: { id: 1 } });
    expect(parseNuiMessage({ action: 'push', topic: 'grants', payload: grantSet })).toEqual({ action: 'grants', grants: grantSet });
    expect(parseNuiMessage({ action: 'push', topic: 'grants', payload: { nope: true } })).toBeNull();
  });
});
