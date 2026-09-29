// SPDX-License-Identifier: GPL-3.0-only
// Known grant keys per type for the "Behörigheter" matrix (docs/contracts.md §C10, §C12): units from config/units.json,
// tiers 0–2, every tablet section (mdt_page), the perms and tools FredPD checks, every key already stored, and the
// type wildcard. The PUT validator (AdminRoleGrantSchema) accepts every key listed here (test/catalog.test.ts).
import { GRANT_TYPES } from '@fredpd/types/grants';
import type { GrantType, RoleGrantRow } from '@fredpd/types/grants';
import { MDT_PAGE_KEYS } from '@fredpd/types/mdtPages';
import type { GrantCatalogEntry } from '@fredpd/types/actions';

/**
 * Perm keys pinned in docs/contracts.md (§C10 admin, §C12 tablet, §C13 alerts, §C14 records, §C15 intel, §C16
 * evidence), so an admin can map them before the module that checks them ships. Each has a `perms.perm.<key>` locale
 * label. Ranks are `rank:<key>` and come from the keys in use. test/catalog.test.ts fails when an action registry in
 * @fredpd/types names a perm that is missing here: add it (and its label) when a contract adds one.
 */
export const KNOWN_PERMS = [
  'admin.permissions',
  'alerts.manage',
  'bolo.create',
  'bolo.resolve',
  'cases.create',
  'charges.apply',
  'charges.fine',
  'evidence.link',
  'intel.command',
  'intel.handler',
  'intel.read',
  'records.admin',
  'tablets.manage',
] as const;

/** Tool keys FredPD checks (fredpd_breach `tool:ram`, §C16), each with a `perms.tool.<key>` label. */
export const KNOWN_TOOLS = ['ram'] as const;

export function buildCatalog(unitCodes: readonly string[], inUse: readonly Pick<RoleGrantRow, 'grantType' | 'grantKey'>[]): GrantCatalogEntry[] {
  const keys = new Map<GrantType, Set<string>>(GRANT_TYPES.map((t) => [t, new Set<string>(['*'])]));
  const add = (t: GrantType, k: string) => keys.get(t)?.add(k);
  unitCodes.forEach((u) => add('unit', u));
  ['0', '1', '2'].forEach((t) => add('intel_tier', t));
  MDT_PAGE_KEYS.forEach((p) => add('mdt_page', p));
  KNOWN_PERMS.forEach((p) => add('perm', p));
  KNOWN_TOOLS.forEach((p) => add('tool', p));
  inUse.forEach((g) => add(g.grantType, g.grantKey));
  const unitIndex = new Map(unitCodes.map((u, i) => [u, i]));
  const pageIndex = new Map<string, number>(MDT_PAGE_KEYS.map((p, i) => [p, i]));
  return GRANT_TYPES.map((type) => {
    const list = [...(keys.get(type) ?? [])];
    // Wildcard first, then units in config order and tablet sections in nav order, everything else by code unit.
    const order = type === 'unit' ? unitIndex : type === 'mdt_page' ? pageIndex : null;
    list.sort((a, b) => {
      if (a === '*' || b === '*') return a === '*' ? -1 : 1;
      if (order) {
        const ia = order.get(a) ?? Infinity;
        const ib = order.get(b) ?? Infinity;
        if (ia !== ib) return ia - ib;
      }
      return a < b ? -1 : a > b ? 1 : 0;
    });
    return { type, keys: list };
  });
}
