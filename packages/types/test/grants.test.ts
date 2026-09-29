// SPDX-License-Identifier: GPL-3.0-only
// Shared grant fixtures (also run by tests/lua/grants_test.lua) plus TS-only edge cases.
import { describe, expect, it } from 'vitest';
import {
  GRANT_TYPES,
  GrantSetSchema,
  GrantStringSchema,
  ResolveInputSchema,
  RoleGrantRowSchema,
  emptyGrantSet,
  hasGrant,
  resolveGrants,
} from '../src/grants';
import type { GrantType, ResolveInput, RoleGrantRow } from '../src/grants';
import fixtures from './fixtures/grants.fixtures.json';

type FixtureCase = {
  name: string;
  memberRoleIds: string[];
  grants: RoleGrantRow[];
  roles?: ResolveInput['roles'];
  unitOrder?: string[];
  expected: unknown;
  checks?: { type: GrantType; key: string; expected: boolean }[];
};

const cases = fixtures.cases as FixtureCase[];
/** Rows ResolveInputSchema rejects (DB/JSON callers); both ports ignore them. */
const unvalidatedCases = fixtures.unvalidatedCases as FixtureCase[];
const NOW = new Date('2026-09-29T12:00:00.000Z');

function inputOf(c: FixtureCase): ResolveInput {
  return {
    memberRoleIds: c.memberRoleIds,
    roles: c.roles ?? (fixtures.roles as ResolveInput['roles']),
    grants: c.grants,
    unitOrder: c.unitOrder ?? fixtures.unitOrder,
  };
}

describe('grants fixtures', () => {
  it('has at least 20 cases with unique names', () => {
    expect(cases.length).toBeGreaterThanOrEqual(20);
    expect(new Set(cases.map((c) => c.name)).size).toBe(cases.length);
  });

  for (const c of cases) {
    it(c.name, () => {
      const input = ResolveInputSchema.parse(inputOf(c));
      const result = resolveGrants(input, NOW);
      expect(GrantSetSchema.parse(result)).toEqual(result);
      const { computedAt, ...rest } = result;
      expect(computedAt).toBe(NOW.toISOString());
      expect(rest).toEqual(c.expected);
      for (const check of c.checks ?? []) {
        expect(hasGrant(result, check.type, check.key), `hasGrant ${check.type}:${check.key}`).toBe(check.expected);
      }
    });

    it(`${c.name} (input order independent)`, () => {
      const input = inputOf(c);
      const reversed = { ...input, roles: [...input.roles].reverse(), grants: [...input.grants].reverse() };
      const { computedAt: _a, ...forward } = resolveGrants(input, NOW);
      const { computedAt: _b, ...backward } = resolveGrants(reversed, NOW);
      expect(backward).toEqual(forward);
    });
  }
});

describe('grants unvalidated input (ignored like the Lua port)', () => {
  for (const c of unvalidatedCases) {
    it(c.name, () => {
      const input = inputOf(c);
      expect(ResolveInputSchema.safeParse(input).success, 'must hold a schema-invalid row').toBe(false);
      const result = resolveGrants(input, NOW);
      expect(GrantSetSchema.parse(result)).toEqual(result);
      const { computedAt: _c, ...rest } = result;
      expect(rest).toEqual(c.expected);
      for (const check of c.checks ?? []) {
        expect(hasGrant(result, check.type, check.key), `hasGrant ${check.type}:${check.key}`).toBe(check.expected);
      }
    });
  }
});

describe('grants edge cases', () => {
  it('hasGrant on a missing set is false', () => {
    expect(hasGrant(null, 'perm', 'intel.read')).toBe(false);
    expect(hasGrant(undefined, 'perm', 'intel.read')).toBe(false);
  });

  it('emptyGrantSet is a valid, empty GrantSet', () => {
    const set = emptyGrantSet(NOW);
    expect(GrantSetSchema.parse(set)).toEqual({
      grants: [], denied: [], tier: 0, units: [], rank: null, computedAt: '2026-09-29T12:00:00.000Z',
    });
    expect(hasGrant(set, 'weapon', 'pistol')).toBe(false);
  });

  it('GrantSetSchema reads a missing rank (Lua-encoded set) as null and accepts second precision', () => {
    const parsed = GrantSetSchema.parse({
      grants: ['perm:intel.read'], denied: [], tier: 1, units: ['igv'], computedAt: '2026-09-29T12:00:00Z',
    });
    expect(parsed.rank).toBeNull();
  });

  it('GrantSetSchema rejects malformed sets', () => {
    const base = emptyGrantSet(NOW);
    expect(GrantSetSchema.safeParse({ ...base, tier: 3 }).success).toBe(false);
    expect(GrantSetSchema.safeParse({ ...base, grants: ['nope:x'] }).success).toBe(false);
    expect(GrantSetSchema.safeParse({ ...base, grants: ['weapon:'] }).success).toBe(false);
    expect(GrantSetSchema.safeParse({ ...base, computedAt: 'yesterday' }).success).toBe(false);
  });

  it('ignores rows an untyped (DB/JSON) caller could pass: unknown type, unknown effect, empty key', () => {
    const roles = [{ discordRoleId: '1', name: 'R', position: 1, deleted: false }];
    const grants = [
      { discordRoleId: '1', grantType: 'spell', grantKey: 'fireball', effect: 'allow' },
      { discordRoleId: '1', grantType: 'weapon', grantKey: 'pistol', effect: 'maybe' },
      { discordRoleId: '1', grantType: 'weapon', grantKey: '', effect: 'deny' },
      { discordRoleId: '1', grantType: 'weapon', grantKey: 'smg', effect: 'allow' },
    ] as unknown as RoleGrantRow[];
    const { computedAt: _c, ...rest } = resolveGrants({ memberRoleIds: ['1'], roles, grants, unitOrder: [] }, NOW);
    expect(rest).toEqual({ grants: ['weapon:smg'], denied: [], tier: 0, units: [], rank: null });
  });

  it('ResolveInputSchema rejects unknown grant types and effects', () => {
    const bad = { discordRoleId: '1', grantType: 'spell', grantKey: 'x', effect: 'allow' };
    expect(ResolveInputSchema.safeParse({ memberRoleIds: [], roles: [], grants: [bad], unitOrder: [] }).success).toBe(false);
  });

  it('grant keys are ASCII identifiers of 1-64 characters', () => {
    const row = (grantKey: string) => ({ discordRoleId: '1', grantType: 'perm', grantKey, effect: 'allow' });
    for (const key of ['intel.read', 'rank:kommissarie', '*', 'WEAPON_PISTOL', 'a-b', '-1', 'k'.repeat(64)]) {
      expect(RoleGrantRowSchema.safeParse(row(key)).success, key).toBe(true);
      expect(GrantStringSchema.safeParse(`perm:${key}`).success, key).toBe(true);
    }
    for (const key of ['', 'a\nb', 'a b', 'rank:inspektör', 'tab\t', 'k'.repeat(65)]) {
      expect(RoleGrantRowSchema.safeParse(row(key)).success, JSON.stringify(key)).toBe(false);
      expect(GrantStringSchema.safeParse(`perm:${key}`).success, JSON.stringify(key)).toBe(false);
    }
  });

  it('every ResolveInputSchema-valid input resolves to a GrantSetSchema-valid set (seeded random inputs)', () => {
    // Small deterministic LCG so a failure is reproducible.
    let state = 20260929;
    const rand = (n: number): number => {
      state = (state * 1103515245 + 12345) % 2147483648;
      return state % n;
    };
    const charset = 'abcXYZ019_.:*-';
    const specials = ['*', 'rank:', 'rank:*', 'rank:a', '2', '-1', '02', '5', 'igv', 'x'.repeat(64)];
    const key = (): string => {
      if (rand(3) === 0) return specials[rand(specials.length)] as string;
      let out = '';
      for (let i = 0, n = 1 + rand(8); i < n; i++) out += charset[rand(charset.length)];
      return out;
    };
    const roleIds = ['1', '2', '3', '4'];
    for (let iter = 0; iter < 500; iter++) {
      const input = ResolveInputSchema.parse({
        memberRoleIds: roleIds.filter(() => rand(4) !== 0),
        roles: roleIds.map((id) => ({ discordRoleId: id, name: id, position: rand(5), deleted: rand(5) === 0 })),
        grants: Array.from({ length: rand(12) }, () => ({
          discordRoleId: roleIds[rand(roleIds.length)],
          grantType: GRANT_TYPES[rand(GRANT_TYPES.length)],
          grantKey: key(),
          effect: rand(3) === 0 ? 'deny' : 'allow',
        })),
        unitOrder: ['igv', 'abc'],
      });
      const result = resolveGrants(input, NOW);
      expect(GrantSetSchema.safeParse(result).success, JSON.stringify(input)).toBe(true);
    }
  });
});
