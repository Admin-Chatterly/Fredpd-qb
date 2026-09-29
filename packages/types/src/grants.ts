// SPDX-License-Identifier: GPL-3.0-only
// Grant resolution (docs/contracts.md §C2, IMPLEMENTATION.md §4.1).
// Ported 1:1 to resources/[fredpd]/fredpd_core/shared/grants.lua; both run
// packages/types/test/fixtures/grants.fixtures.json. Change the two together.
import { z } from 'zod';

export const GRANT_TYPES = ['weapon', 'vehicle', 'armory', 'tool', 'mdt_page', 'intel_tier', 'unit', 'perm'] as const;
export const GrantTypeSchema = z.enum(GRANT_TYPES);
export type GrantType = z.infer<typeof GrantTypeSchema>;

export const GrantEffectSchema = z.enum(['allow', 'deny']);
export type GrantEffect = z.infer<typeof GrantEffectSchema>;

/** Intel tier (0 standard, 1 begränsad, 2 hemlig). Also the classification level of a record. */
export const IntelTierSchema = z.union([z.literal(0), z.literal(1), z.literal(2)]);
export type IntelTier = z.infer<typeof IntelTierSchema>;

/** Row of fredpd_roles, camelCased. */
export const RoleRowSchema = z.object({
  discordRoleId: z.string().min(1),
  name: z.string(),
  position: z.number().int(),
  deleted: z.boolean(),
});
export type RoleRow = z.infer<typeof RoleRowSchema>;

/**
 * Grant keys are ASCII identifiers: letters, digits and `_ . : * -`, 1–64 characters (grant_key VARCHAR(64)).
 * No whitespace, control or non-ASCII characters, so a key survives JSON, the DB and the Lua port unchanged,
 * every resolved set passes GrantSetSchema, and TS code-unit order equals Lua byte order. A key may itself
 * contain ':' (perm `rank:kommissarie`); `*` alone is the type's wildcard. Rank display names come from the
 * Discord role, so `rank:inspektor` (not `rank:inspektör`) is the key.
 */
export const GRANT_KEY_PATTERN = '[A-Za-z0-9_.:*-]{1,64}';
const GRANT_KEY_RE = new RegExp(`^${GRANT_KEY_PATTERN}$`);
export const GrantKeySchema = z.string().regex(GRANT_KEY_RE);

/** Row of fredpd_role_grants, camelCased. */
export const RoleGrantRowSchema = z.object({
  discordRoleId: z.string().min(1),
  grantType: GrantTypeSchema,
  grantKey: GrantKeySchema,
  effect: GrantEffectSchema,
});
export type RoleGrantRow = z.infer<typeof RoleGrantRowSchema>;

export const ResolveInputSchema = z.object({
  memberRoleIds: z.array(z.string()),
  roles: z.array(RoleRowSchema),
  grants: z.array(RoleGrantRowSchema),
  unitOrder: z.array(z.string()),
});
export type ResolveInput = z.infer<typeof ResolveInputSchema>;

/** "type:key" where type is a known grant type and key matches GRANT_KEY_PATTERN. */
export const GrantStringSchema = z.string().regex(new RegExp(`^(${GRANT_TYPES.join('|')}):${GRANT_KEY_PATTERN}$`));

export const GrantRankSchema = z.object({ roleId: z.string(), key: z.string() });
export type GrantRank = z.infer<typeof GrantRankSchema>;

export const GrantSetSchema = z.object({
  grants: z.array(GrantStringSchema),
  denied: z.array(GrantStringSchema),
  tier: IntelTierSchema,
  units: z.array(z.string()),
  // The Lua port cannot represent JSON null (it decodes to nil and re-encodes as a missing key),
  // so a missing rank is read as null.
  rank: GrantRankSchema.nullable().default(null),
  computedAt: z.iso.datetime(),
});
export type GrantSet = z.infer<typeof GrantSetSchema>;

/** The two lists hasGrant needs; any GrantSet satisfies it. */
export type GrantLists = Pick<GrantSet, 'grants' | 'denied'>;

const GRANT_TYPE_SET: ReadonlySet<string> = new Set(GRANT_TYPES);
const RANK_PREFIX = 'rank:';
const TIER_KEY = /^-?\d+$/;

/**
 * Code-unit order (not localeCompare) so the result is identical to the Lua port's byte order
 * for the ASCII keys used in practice.
 */
function byCodeUnit(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

function sortedUnique(values: Iterable<string>): string[] {
  return [...new Set(values)].sort(byCodeUnit);
}

function wildcardOf(grant: string): string {
  return `${grant.slice(0, grant.indexOf(':'))}:*`;
}

function isDenied(denied: ReadonlySet<string>, grant: string): boolean {
  return denied.has(grant) || denied.has(wildcardOf(grant));
}

/**
 * `(grants ∋ type:key or grants ∋ type:*) and not (denied ∋ type:key or denied ∋ type:*)`.
 * A missing set grants nothing.
 */
export function hasGrant(set: GrantLists | null | undefined, type: GrantType, key: string): boolean {
  // Like the Lua port, a set without a grants array (unparsed input) grants nothing and a missing denied
  // list denies nothing. Array checks also stop a string from matching by substring.
  if (!set || !Array.isArray(set.grants)) return false;
  const denied: readonly string[] = Array.isArray(set.denied) ? set.denied : [];
  const exact = `${type}:${key}`;
  const wildcard = `${type}:*`;
  if (!set.grants.includes(exact) && !set.grants.includes(wildcard)) return false;
  return !denied.includes(exact) && !denied.includes(wildcard);
}

export function emptyGrantSet(now: Date = new Date()): GrantSet {
  return { grants: [], denied: [], tier: 0, units: [], rank: null, computedAt: now.toISOString() };
}

/** Parses an intel_tier key ("0".."2"; other integers are clamped). Non-integer keys, including "*", give null. */
function parseTier(key: string): IntelTier | null {
  if (!TIER_KEY.test(key)) return null;
  const n = Number(key);
  return n >= 2 ? 2 : n <= 0 ? 0 : 1;
}

/**
 * Is an allow row denied? Exact key or the type's wildcard; for intel_tier also any deny whose key parses to the
 * same tier, so `deny intel_tier:2` cannot be bypassed by `allow intel_tier:5` / `02` (both mean tier 2).
 */
function isRowDenied(denied: ReadonlySet<string>, deniedTiers: ReadonlySet<IntelTier>, row: RoleGrantRow): boolean {
  if (isDenied(denied, `${row.grantType}:${row.grantKey}`)) return true;
  if (row.grantType !== 'intel_tier') return false;
  const t = parseTier(row.grantKey);
  return t !== null && deniedTiers.has(t);
}

/**
 * Resolves a member's grants from their Discord roles (docs/contracts.md §C2).
 *
 * - Only rows of roles the member holds, that exist in `roles` and are not deleted, count. Rows a typed caller
 *   cannot produce (unknown type or effect, key outside GRANT_KEY_PATTERN) are ignored, so the result always
 *   passes GrantSetSchema.
 * - `denied` = every deny row. `grants` = allow rows that are not denied exactly or by their type's
 *   wildcard; a wildcard allow survives an exact deny (hasGrant then consults `denied`).
 * - intel_tier deny works by tier value: an allow whose key parses to a denied key's tier is dropped too
 *   (`deny intel_tier:2` also removes `allow intel_tier:5` and `allow intel_tier:02`).
 * - `tier` = highest allowed integer intel_tier key, clamped to 0..2; `intel_tier:*` does not raise the tier.
 * - `units` = allowed unit keys in `unitOrder` order, unknown units after them alphabetically; `unit:*` adds none.
 * - `rank` = allowed `perm:rank:<key>` of the highest-position role (ties: lower roleId, then lower key).
 */
export function resolveGrants(input: ResolveInput, now: Date = new Date()): GrantSet {
  const member = new Set(input.memberRoleIds);
  const heldRoles = new Map<string, RoleRow>();
  for (const role of input.roles) {
    if (!role.deleted && member.has(role.discordRoleId)) heldRoles.set(role.discordRoleId, role);
  }

  // Ignore rows a typed caller cannot produce but a DB/JSON caller can; the Lua port does the same.
  const rows = input.grants.filter(
    (row) =>
      heldRoles.has(row.discordRoleId) &&
      GRANT_TYPE_SET.has(row.grantType) &&
      (row.effect === 'allow' || row.effect === 'deny') &&
      typeof row.grantKey === 'string' &&
      GRANT_KEY_RE.test(row.grantKey),
  );

  const denyRows = rows.filter((r) => r.effect === 'deny');
  const denied = new Set(denyRows.map((r) => `${r.grantType}:${r.grantKey}`));
  const deniedTiers = new Set<IntelTier>();
  for (const r of denyRows) {
    const t = r.grantType === 'intel_tier' ? parseTier(r.grantKey) : null;
    if (t !== null) deniedTiers.add(t);
  }
  const allowedRows = rows.filter((r) => r.effect === 'allow' && !isRowDenied(denied, deniedTiers, r));

  let tier: IntelTier = 0;
  const units = new Set<string>();
  let rank: { position: number; roleId: string; key: string } | null = null;

  for (const row of allowedRows) {
    if (row.grantType === 'intel_tier') {
      const t = parseTier(row.grantKey);
      if (t !== null && t > tier) tier = t;
    } else if (row.grantType === 'unit') {
      if (row.grantKey !== '*') units.add(row.grantKey);
    } else if (row.grantType === 'perm' && row.grantKey.startsWith(RANK_PREFIX)) {
      const key = row.grantKey.slice(RANK_PREFIX.length);
      const position = heldRoles.get(row.discordRoleId)?.position ?? 0;
      if (key !== '' && key !== '*') {
        const better =
          rank === null ||
          position > rank.position ||
          (position === rank.position &&
            (row.discordRoleId < rank.roleId || (row.discordRoleId === rank.roleId && key < rank.key)));
        if (better) rank = { position, roleId: row.discordRoleId, key };
      }
    }
  }

  const order = new Map<string, number>();
  input.unitOrder.forEach((unit, i) => {
    if (!order.has(unit)) order.set(unit, i);
  });
  const sortedUnits = [...units].sort((a, b) => {
    const ia = order.get(a);
    const ib = order.get(b);
    if (ia !== undefined && ib !== undefined) return ia - ib;
    if (ia !== undefined) return -1;
    if (ib !== undefined) return 1;
    return byCodeUnit(a, b);
  });

  return {
    grants: sortedUnique(allowedRows.map((r) => `${r.grantType}:${r.grantKey}`)),
    denied: sortedUnique(denied),
    tier,
    units: sortedUnits,
    rank: rank === null ? null : { roleId: rank.roleId, key: rank.key },
    computedAt: now.toISOString(),
  };
}
