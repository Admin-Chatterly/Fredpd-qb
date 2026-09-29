// SPDX-License-Identifier: GPL-3.0-only
// Tablet navigation: one entry per section, shown only with its `mdt_page` grant (Hem always). At most
// MAX_NAV_ITEMS entries are shown; when more are allowed, the last slot becomes "Meny" and holds the rest.
// The primary unit moves its everyday sections to the front (docs/modules/ui.md "Navigation").
import type { ComponentType } from 'react';
import { hasGrant } from '@fredpd/types/grants';
import type { GrantLists } from '@fredpd/types/grants';
import type { LocaleKey } from '@fredpd/types/locale-keys';
import { IconBell, IconBook, IconBox, IconEye, IconFlag, IconFolder, IconHome, IconSearch, IconShield, IconUsers, MDT_PAGE_LABEL_KEYS } from '@fredpd/ui';
import type { IconProps, MdtPageKey } from '@fredpd/ui';

export const MAX_NAV_ITEMS = 6;

export interface NavEntry {
  id: 'home' | MdtPageKey;
  /** Grant needed (`mdt_page:<page>`); null = always shown. */
  page: MdtPageKey | null;
  to: string;
  label: LocaleKey;
  icon: ComponentType<IconProps>;
  /** Path prefixes that mark the entry active (its detail pages included). */
  match: readonly string[];
}

const entry = (page: MdtPageKey, to: string, icon: ComponentType<IconProps>, match: readonly string[] = [to]): NavEntry => ({
  id: page,
  page,
  to,
  label: MDT_PAGE_LABEL_KEYS[page],
  icon,
  match,
});

/** Base order (IMPLEMENTATION.md §5.2 routes). */
export const NAV_ENTRIES: readonly NavEntry[] = [
  { id: 'home', page: null, to: '/', label: 'nav.home', icon: IconHome, match: [] },
  entry('search', '/sok', IconSearch, ['/sok', '/person/', '/fordon/']),
  entry('alerts', '/larm', IconBell),
  entry('bolos', '/efterlysning', IconFlag),
  entry('cases', '/arenden', IconFolder, ['/arenden', '/arende/', '/rapport/']),
  entry('evidence', '/bevis', IconBox),
  entry('intel', '/intel', IconEye),
  entry('charges', '/brottskatalog', IconBook),
  entry('roster', '/register', IconUsers),
  entry('command', '/ledning', IconShield),
];

/** Sections each unit uses most, placed right after Hem (unknown units keep the base order). */
export const UNIT_NAV_PRIORITY: Readonly<Record<string, readonly MdtPageKey[]>> = {
  igv: ['alerts', 'search', 'bolos'],
  span: ['bolos', 'intel', 'search'],
  utredning: ['cases', 'search', 'evidence'],
  tekniker: ['evidence', 'cases'],
  ledning: ['command', 'roster', 'alerts'],
};

export function canSeePage(grants: GrantLists | null | undefined, page: MdtPageKey | null): boolean {
  return page === null || hasGrant(grants, 'mdt_page', page);
}

/** Every entry the grants allow, Hem first, then the unit's priorities, then the base order. */
export function allowedNavEntries(grants: GrantLists | null | undefined, unit: string | null): NavEntry[] {
  const allowed = NAV_ENTRIES.filter((e) => canSeePage(grants, e.page));
  const priority = (unit && UNIT_NAV_PRIORITY[unit]) || [];
  const rank = (e: NavEntry) => (e.page === null ? -1 : priority.includes(e.page) ? priority.indexOf(e.page) : priority.length);
  // Array.prototype.sort is stable, so entries of equal rank keep the base order.
  return allowed.sort((a, b) => rank(a) - rank(b));
}

export interface NavModel {
  /** Shown directly; with overflow, the menu toggle is the extra (last) slot. */
  items: NavEntry[];
  /** Entries behind "Meny" (empty when everything fits). */
  overflow: NavEntry[];
}

export function buildNav(grants: GrantLists | null | undefined, unit: string | null): NavModel {
  const allowed = allowedNavEntries(grants, unit);
  if (allowed.length <= MAX_NAV_ITEMS) return { items: allowed, overflow: [] };
  return { items: allowed.slice(0, MAX_NAV_ITEMS - 1), overflow: allowed.slice(MAX_NAV_ITEMS - 1) };
}

/** The entry a path belongs to (for aria-current), or undefined. */
export function activeNavId(pathname: string): NavEntry['id'] | undefined {
  if (pathname === '/') return 'home';
  return NAV_ENTRIES.find((e) => e.match.some((m) => (m.endsWith('/') ? pathname.startsWith(m) : pathname === m || pathname.startsWith(`${m}/`))))?.id;
}
