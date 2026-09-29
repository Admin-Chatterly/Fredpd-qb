// SPDX-License-Identifier: GPL-3.0-only
// State of the "Behörigheter" matrix (docs/contracts.md §C10): rows are Discord roles, columns are grant keys
// grouped by type, a cell is none / allow / deny. The server rows are the saved state; unsaved edits are kept per
// role as drafts, and a role is saved by sending all of its effective rows (PUT replaces the role's rows).
import { GRANT_TYPES } from '@fredpd/types/grants';
import type { GrantEffect, GrantType, RoleGrantRow } from '@fredpd/types/grants';
import { AdminRoleGrantSchema } from '@fredpd/types/actions';
import type { AdminRoleGrant, AdminRoleGrantsPutBody, AdminRolesResponse, GrantCatalogEntry } from '@fredpd/types/actions';
import { MDT_PAGE_KEYS } from '@fredpd/ui';

export type CellEffect = 'none' | GrantEffect;

/** Clicking a cell: none -> allow -> deny -> none. */
export const EFFECT_CYCLE: Readonly<Record<CellEffect, CellEffect>> = { none: 'allow', allow: 'deny', deny: 'none' };

export function nextEffect(effect: CellEffect): CellEffect {
  return EFFECT_CYCLE[effect];
}

/** `type:key` (the grant string format). Keys may contain ':' (`perm:rank:x`); the type never does. */
export type CellId = `${GrantType}:${string}`;

export function cellId(type: GrantType, key: string): CellId {
  return `${type}:${key}`;
}

export function parseCellId(id: CellId): { grantType: GrantType; grantKey: string } {
  const i = id.indexOf(':');
  return { grantType: id.slice(0, i) as GrantType, grantKey: id.slice(i + 1) };
}

/** Saved effects of one role. */
export type RoleEffects = ReadonlyMap<CellId, GrantEffect>;

/** Unsaved edits: roleId -> cell -> effect. Only cells that differ from the saved state are present. */
export type Drafts = Readonly<Record<string, Readonly<Partial<Record<CellId, CellEffect>>>>>;

export function savedEffects(grants: readonly RoleGrantRow[], roleId: string): Map<CellId, GrantEffect> {
  const map = new Map<CellId, GrantEffect>();
  for (const g of grants) if (g.discordRoleId === roleId) map.set(cellId(g.grantType, g.grantKey), g.effect);
  return map;
}

export function effectiveEffect(saved: RoleEffects, draft: Drafts[string] | undefined, id: CellId): CellEffect {
  return draft?.[id] ?? saved.get(id) ?? 'none';
}

/** Advances one cell. A cell that returns to its saved value leaves the draft. */
export function cycleCell(drafts: Drafts, roleId: string, id: CellId, saved: RoleEffects): Drafts {
  const current = drafts[roleId] ?? {};
  const next = nextEffect(effectiveEffect(saved, current, id));
  const { [id]: _previous, ...rest } = current;
  const roleDraft = next === (saved.get(id) ?? 'none') ? rest : { ...rest, [id]: next };
  const { [roleId]: _role, ...others } = drafts;
  return Object.keys(roleDraft).length === 0 ? others : { ...others, [roleId]: roleDraft };
}

export function withoutRole(drafts: Drafts, roleId: string): Drafts {
  const { [roleId]: _role, ...others } = drafts;
  return others;
}

export function changeCount(drafts: Drafts, roleId: string): number {
  return Object.keys(drafts[roleId] ?? {}).length;
}

const TYPE_INDEX = new Map<string, number>(GRANT_TYPES.map((t, i) => [t, i]));
const byCodeUnit = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);

/**
 * PUT body for one role: saved rows with the draft applied, `none` dropped, ordered by grant type (GRANT_TYPES)
 * then key, so equal states always produce the same body.
 */
export function buildPutBody(saved: RoleEffects, draft: Drafts[string] | undefined): AdminRoleGrantsPutBody {
  const merged = new Map<CellId, CellEffect>(saved);
  for (const [id, effect] of Object.entries(draft ?? {}) as [CellId, CellEffect][]) merged.set(id, effect);
  const grants: AdminRoleGrant[] = [];
  for (const [id, effect] of merged) {
    if (effect === 'none') continue;
    const { grantType, grantKey } = parseCellId(id);
    grants.push({ grantType, grantKey, effect });
  }
  grants.sort((a, b) => (TYPE_INDEX.get(a.grantType) ?? 0) - (TYPE_INDEX.get(b.grantType) ?? 0) || byCodeUnit(a.grantKey, b.grantKey));
  return { grants };
}

/** The cached GET response with one role's rows replaced (optimistic save and its rollback). */
export function replaceRoleRows(data: AdminRolesResponse, roleId: string, rows: readonly Omit<RoleGrantRow, 'discordRoleId'>[]): AdminRolesResponse {
  return {
    ...data,
    grants: [...data.grants.filter((g) => g.discordRoleId !== roleId), ...rows.map((r) => ({ ...r, discordRoleId: roleId }))],
  };
}

/** Highest Discord position first (as Discord lists roles), then by name. */
export function sortRoles<R extends { position: number; name: string }>(roles: readonly R[]): R[] {
  return [...roles].sort((a, b) => b.position - a.position || a.name.localeCompare(b.name, 'sv'));
}

export interface ColumnGroup {
  type: GrantType;
  keys: string[];
}

/**
 * Columns grouped by type in GRANT_TYPES order: the catalog's keys in its order (wildcard first), then, sorted,
 * keys that only occur in stored rows, the admin's locally added columns (`added`) and, for mdt_page, the tablet
 * sections (MDT_PAGE_KEYS).
 */
export function buildColumns(catalog: readonly GrantCatalogEntry[], grants: readonly RoleGrantRow[], added: readonly CellId[] = []): ColumnGroup[] {
  const addedByType = added.map(parseCellId);
  return GRANT_TYPES.map((type) => {
    const fromCatalog = catalog.find((c) => c.type === type)?.keys ?? [];
    const keys = new Set<string>(['*', ...fromCatalog]);
    const extra = new Set<string>(grants.filter((g) => g.grantType === type).map((g) => g.grantKey));
    for (const a of addedByType) if (a.grantType === type) extra.add(a.grantKey);
    if (type === 'mdt_page') MDT_PAGE_KEYS.forEach((k) => extra.add(k));
    for (const k of keys) extra.delete(k);
    return { type, keys: [...keys, ...[...extra].sort(byCodeUnit)] };
  });
}

/** Perm keys `rank:<key>` are ranks (IMPLEMENTATION.md §4.9: the rank shown is the highest role mapped to one). */
export const RANK_PREFIX = 'rank:';

/**
 * What the "add column" form can create. The catalog cannot know free-form keys: weapon, vehicle and armory item
 * names, extra tools, perms and ranks. mdt_page (fixed MDT_PAGE_KEYS) and intel_tier (0–2) are always complete, so
 * they are not offered. Neither is unit: the service only accepts a unit key that is in config/units.json or
 * already on the role (apps/service/src/routes/admin.ts), and buildCatalog already lists both as columns, so a
 * portal-added unit could never be saved. `rank` is a perm key with the `rank:` prefix added.
 */
export const NEW_KEY_KINDS = ['weapon', 'vehicle', 'armory', 'tool', 'perm', 'rank'] as const;
export type NewKeyKind = (typeof NEW_KEY_KINDS)[number];

/**
 * The column a typed key stands for, or null when the service would refuse it: the same AdminRoleGrantSchema the
 * PUT body is checked with (GRANT_KEY_PATTERN). Surrounding spaces are ignored; for a rank a typed `rank:` prefix
 * is not doubled.
 */
export function parseNewKey(kind: NewKeyKind, raw: string): CellId | null {
  let key = raw.trim();
  let grantType: GrantType;
  if (kind === 'rank') {
    if (key.startsWith(RANK_PREFIX)) key = key.slice(RANK_PREFIX.length);
    if (key === '' || key === '*') return null;
    grantType = 'perm';
    key = `${RANK_PREFIX}${key}`;
  } else {
    grantType = kind;
  }
  if (key === '') return null;
  return AdminRoleGrantSchema.safeParse({ grantType, grantKey: key, effect: 'allow' }).success ? cellId(grantType, key) : null;
}
