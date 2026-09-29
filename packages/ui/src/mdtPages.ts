// SPDX-License-Identifier: GPL-3.0-only
// Keys of the `mdt_page` grant type: one per tablet section (docs/modules/ui.md). The NUI filters its navigation
// and guards its routes with hasGrant(grants, 'mdt_page', key); the portal's Behörigheter matrix always offers these
// keys as columns. Hem needs no grant. `mdt_page:*` opens every section.
import type { LocaleKey } from '@fredpd/types/locale-keys';

export const MDT_PAGE_KEYS = ['search', 'alerts', 'bolos', 'cases', 'evidence', 'intel', 'charges', 'roster', 'command'] as const;
export type MdtPageKey = (typeof MDT_PAGE_KEYS)[number];

/** Label of each section (nav item and permissions column). */
export const MDT_PAGE_LABEL_KEYS = {
  search: 'nav.search',
  alerts: 'nav.alerts',
  bolos: 'nav.bolos',
  cases: 'nav.cases',
  evidence: 'nav.evidence',
  intel: 'nav.intel',
  charges: 'nav.chargeCatalog',
  roster: 'nav.roster',
  command: 'nav.command',
} as const satisfies Record<MdtPageKey, LocaleKey>;

const MDT_PAGE_SET: ReadonlySet<string> = new Set(MDT_PAGE_KEYS);

export function isMdtPageKey(value: string): value is MdtPageKey {
  return MDT_PAGE_SET.has(value);
}
