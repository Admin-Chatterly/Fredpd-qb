// SPDX-License-Identifier: GPL-3.0-only
// Known grant keys per type for the "Behörigheter" matrix (docs/contracts.md §C10): units from config/units.json,
// tiers 0–2, the perms FredPD checks, the tools it knows, every key already stored, and the type wildcard.
import { GRANT_TYPES } from '@fredpd/types/grants';
import type { GrantType, RoleGrantRow } from '@fredpd/types/grants';
import type { GrantCatalogEntry } from '@fredpd/types/actions';

/**
 * Perm keys FredPD code checks (hasGrant(set, 'perm', key)); each has a `perms.perm.<key>` locale label. Ranks are
 * `rank:<key>` and come from the keys in use. Add a perm here when a module starts checking it.
 */
export const KNOWN_PERMS = ['admin.permissions', 'intel.command', 'intel.handler', 'intel.read', 'records.admin'] as const;

/** Tool keys with a `perms.tool.<key>` label. */
export const KNOWN_TOOLS = ['ram'] as const;

export function buildCatalog(unitCodes: readonly string[], inUse: readonly Pick<RoleGrantRow, 'grantType' | 'grantKey'>[]): GrantCatalogEntry[] {
  const keys = new Map<GrantType, Set<string>>(GRANT_TYPES.map((t) => [t, new Set<string>(['*'])]));
  const add = (t: GrantType, k: string) => keys.get(t)?.add(k);
  unitCodes.forEach((u) => add('unit', u));
  ['0', '1', '2'].forEach((t) => add('intel_tier', t));
  KNOWN_PERMS.forEach((p) => add('perm', p));
  KNOWN_TOOLS.forEach((p) => add('tool', p));
  inUse.forEach((g) => add(g.grantType, g.grantKey));
  const unitIndex = new Map(unitCodes.map((u, i) => [u, i]));
  return GRANT_TYPES.map((type) => {
    const list = [...(keys.get(type) ?? [])];
    // Wildcard first, then units in config order, everything else by code unit.
    list.sort((a, b) => {
      if (a === '*' || b === '*') return a === '*' ? -1 : 1;
      if (type === 'unit') {
        const ia = unitIndex.get(a) ?? Infinity;
        const ib = unitIndex.get(b) ?? Infinity;
        if (ia !== ib) return ia - ib;
      }
      return a < b ? -1 : a > b ? 1 : 0;
    });
    return { type, keys: list };
  });
}
