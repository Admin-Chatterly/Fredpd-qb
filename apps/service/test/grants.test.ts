// SPDX-License-Identifier: GPL-3.0-only
// GET /internal/grants/:discordId against the real database (fredpd_test_service) with a fake gateway:
// resolution per docs/contracts.md §C2 (deny wins, deleted roles ignored, units ordered, rank by position), the
// fredpd_grant_cache row, non-members, and the officer-name push on join. Skips when MariaDB is unreachable.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { GrantsResponseSchema } from '@fredpd/types/actions';
import { hasGrant } from '@fredpd/types/grants';
import { cleanup, GUILD_ID, ids, makeApp, rows, seedRole, setupTestDb, signedInject } from './helpers';
import type { TestApp } from './helpers';

const PREFIX = '901';
const database = await setupTestDb('grants.test');
const nextId = ids(PREFIX);

describe.skipIf(!database)('GET /internal/grants/:discordId (DB)', () => {
  let t: TestApp;
  const role = { polis: nextId(), igv: nextId(), noArmory: nextId(), chef: nextId(), gone: nextId() };
  const officer = nextId();
  const civilian = nextId();
  const stranger = nextId();

  beforeAll(async () => {
    if (!database) return;
    await cleanup(database, PREFIX);
    await seedRole(database, role.polis, 'Polis', 10, [
      ['weapon', '*', 'allow'],
      ['armory', 'station', 'allow'],
      ['unit', 'igv', 'allow'],
      ['intel_tier', '1', 'allow'],
      ['perm', 'rank:assistent', 'allow'],
    ]);
    await seedRole(database, role.igv, 'IGV', 11, [['unit', 'ledning', 'allow'], ['mdt_page', 'alerts', 'allow']]);
    // Deny wins over any allow, wildcard included.
    await seedRole(database, role.noArmory, 'Avstängd', 5, [['armory', 'station', 'deny'], ['weapon', 'pistol', 'deny']]);
    await seedRole(database, role.chef, 'Kommissarie', 30, [['perm', 'rank:kommissarie', 'allow'], ['intel_tier', '2', 'allow']]);
    // Deleted role: its grants must not count.
    await seedRole(database, role.gone, 'Gammal', 50, [['perm', 'admin.permissions', 'allow']], true);

    t = await makeApp({ database });
    t.gateway.addMember({ id: officer, nick: 'Anna B.', roleIds: [GUILD_ID, role.polis, role.igv, role.noArmory, role.chef, role.gone] });
    t.gateway.addMember({ id: civilian, roleIds: [GUILD_ID] });
  });

  afterAll(async () => {
    if (!database) return;
    await t?.app.close();
    await cleanup(database, PREFIX);
    await database.close();
  });

  it('resolves grants: deny wins, deleted roles ignored, units in config order, rank from the highest role', async () => {
    const res = await signedInject(t, { method: 'GET', url: `/internal/grants/${officer}` });
    expect(res.statusCode).toBe(200);
    const body = GrantsResponseSchema.parse(res.json());
    expect(body.discordId).toBe(officer);
    expect(body.member).toBe(true);
    const g = body.grants;
    expect(g.grants).toEqual(['intel_tier:1', 'intel_tier:2', 'mdt_page:alerts', 'perm:rank:assistent', 'perm:rank:kommissarie', 'unit:igv', 'unit:ledning', 'weapon:*']);
    expect(g.denied).toEqual(['armory:station', 'weapon:pistol']);
    expect(hasGrant(g, 'armory', 'station')).toBe(false); // allowed by Polis, denied by Avstängd
    expect(hasGrant(g, 'weapon', 'pistol')).toBe(false); // wildcard allow, exact deny
    expect(hasGrant(g, 'weapon', 'rifle')).toBe(true);
    expect(hasGrant(g, 'perm', 'admin.permissions')).toBe(false); // only on the deleted role
    expect(g.tier).toBe(2);
    expect(g.units).toEqual(['ledning', 'igv']);
    expect(g.rank).toEqual({ roleId: role.chef, key: 'kommissarie' });
  });

  it('writes fredpd_grant_cache with the same set', async () => {
    const res = await signedInject(t, { method: 'GET', url: `/internal/grants/${officer}` });
    const [row] = await rows<{ grants: string; computed_at: Date }>(database!, 'SELECT CAST(grants AS CHAR) AS grants, computed_at FROM fredpd_grant_cache WHERE discord_id = ?', [officer]);
    expect(row).toBeDefined();
    const cached = JSON.parse(row!.grants);
    expect(cached).toEqual(res.json().grants);
    // computed_at is the set's computedAt as UTC DATETIME (whole seconds).
    expect(row!.computed_at.getTime()).toBe(Math.floor(Date.parse(cached.computedAt) / 1000) * 1000);
  });

  it('a guild member without grant roles gets an empty set; a non-member gets member=false', async () => {
    const civ = await signedInject(t, { method: 'GET', url: `/internal/grants/${civilian}` });
    expect(civ.json()).toMatchObject({ member: true, grants: { grants: [], denied: [], tier: 0, units: [], rank: null } });
    const out = await signedInject(t, { method: 'GET', url: `/internal/grants/${stranger}` });
    expect(out.statusCode).toBe(200);
    expect(out.json()).toMatchObject({ discordId: stranger, member: false, grants: { grants: [] } });
  });

  it('rejects a malformed Discord id with 400', async () => {
    const res = await signedInject(t, { method: 'GET', url: '/internal/grants/abc' });
    expect(res.statusCode).toBe(400);
  });

  it('pushes the Discord name to FXServer for officers on join (not for members without grants)', async () => {
    t.fx.calls = [];
    await signedInject(t, { method: 'GET', url: `/internal/grants/${officer}` });
    await signedInject(t, { method: 'GET', url: `/internal/grants/${civilian}` });
    await t.app.fredpd.background.drain();
    const pushes = t.fx.of('officer');
    expect(pushes).toHaveLength(1);
    expect(pushes[0]).toMatchObject({ discordId: officer, displayName: 'Anna B.' });
    expect(pushes[0]!.avatarUrl).toMatch(new RegExp(`^https://portal\\.example\\.test/avatar/${officer}\\?v=d\\d$`));
  });
});
