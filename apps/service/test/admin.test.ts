// SPDX-License-Identifier: GPL-3.0-only
// Permissions admin API (docs/contracts.md §C10) against fredpd_test_service: session + perm admin.permissions
// (403 otherwise) + x-csrf-token on the PUT; the PUT replaces the rows in one transaction, writes perms.update to
// fredpd_audit, refreshes fredpd_grant_cache for every holder and asks FXServer (fake) to recompute them.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { AdminRolesResponseSchema } from '@fredpd/types/actions';
import { cleanup, GUILD_ID, ids, loginAs, makeApp, rows, seedRole, setupTestDb } from './helpers';
import type { TestApp } from './helpers';

const PREFIX = '902';
const database = await setupTestDb('admin.test');
const nextId = ids(PREFIX);

describe.skipIf(!database)('permissions admin API (DB)', () => {
  let t: TestApp;
  const adminRole = nextId();
  const polisRole = nextId();
  const admin = nextId();
  const polis1 = nextId();
  const polis2 = nextId();
  const plain = nextId();
  let adminSession: { cookie: string; csrf: string };
  let plainSession: { cookie: string; csrf: string };

  beforeAll(async () => {
    if (!database) return;
    await cleanup(database, PREFIX);
    await seedRole(database, adminRole, 'Admin', 40, [['perm', 'admin.permissions', 'allow']]);
    await seedRole(database, polisRole, 'Polis', 10, [['weapon', 'pistol', 'allow']]);
    t = await makeApp({ database });
    t.gateway.addMember({ id: admin, roleIds: [GUILD_ID, adminRole] });
    t.gateway.addMember({ id: polis1, roleIds: [GUILD_ID, polisRole] });
    t.gateway.addMember({ id: polis2, roleIds: [GUILD_ID, polisRole] });
    t.gateway.addMember({ id: plain, roleIds: [GUILD_ID] });
    adminSession = await loginAs(t, database, admin);
    plainSession = await loginAs(t, database, plain);
  });

  afterAll(async () => {
    if (!database) return;
    await t?.app.close();
    await cleanup(database, PREFIX);
    await database.close();
  });

  const put = (session: { cookie: string; csrf: string } | null, roleId: string, body: unknown, csrf?: string) =>
    t.app.inject({
      method: 'PUT',
      url: `/api/admin/roles/${roleId}/grants`,
      headers: {
        ...(session ? { cookie: session.cookie } : {}),
        ...(csrf !== undefined ? { 'x-csrf-token': csrf } : {}),
        'content-type': 'application/json',
      },
      payload: JSON.stringify(body),
    });

  it('GET /api/admin/roles: 401 logged out, 403 without the perm', async () => {
    expect((await t.app.inject({ method: 'GET', url: '/api/admin/roles' })).statusCode).toBe(401);
    const res = await t.app.inject({ method: 'GET', url: '/api/admin/roles', headers: { cookie: plainSession.cookie } });
    expect(res.statusCode).toBe(403);
    expect(res.json()).toEqual({ error: 'forbidden' });
  });

  it('GET /api/admin/roles: roles, grants and the catalog for an admin', async () => {
    const res = await t.app.inject({ method: 'GET', url: '/api/admin/roles', headers: { cookie: adminSession.cookie } });
    expect(res.statusCode).toBe(200);
    const body = AdminRolesResponseSchema.parse(res.json());
    expect(body.roles).toEqual(expect.arrayContaining([expect.objectContaining({ discordRoleId: polisRole, name: 'Polis', position: 10, deleted: false })]));
    expect(body.grants).toEqual(expect.arrayContaining([{ discordRoleId: polisRole, grantType: 'weapon', grantKey: 'pistol', effect: 'allow' }]));
    const units = body.catalog.find((c) => c.type === 'unit');
    expect(units?.keys.slice(0, 6)).toEqual(['*', 'ledning', 'span', 'utredning', 'tekniker', 'igv']);
    expect(body.catalog.find((c) => c.type === 'intel_tier')?.keys).toEqual(['*', '0', '1', '2']);
    expect(body.catalog.find((c) => c.type === 'perm')?.keys).toEqual(expect.arrayContaining(['admin.permissions', 'intel.read']));
    expect(body.catalog.find((c) => c.type === 'weapon')?.keys).toEqual(expect.arrayContaining(['*', 'pistol']));
  });

  it('PUT: 401 logged out, 403 csrf without or with a wrong token, 403 forbidden without the perm', async () => {
    const body = { grants: [] };
    expect((await put(null, polisRole, body)).statusCode).toBe(401);
    const noCsrf = await put(adminSession, polisRole, body);
    expect(noCsrf.statusCode).toBe(403);
    expect(noCsrf.json()).toEqual({ error: 'csrf' });
    expect((await put(adminSession, polisRole, body, plainSession.csrf)).json()).toEqual({ error: 'csrf' });
    const noPerm = await put(plainSession, polisRole, body, plainSession.csrf);
    expect(noPerm.statusCode).toBe(403);
    expect(noPerm.json()).toEqual({ error: 'forbidden' });
    // Nothing was written by the refused requests.
    expect(await rows(database!, 'SELECT grant_key FROM fredpd_role_grants WHERE discord_role_id = ?', [polisRole])).toHaveLength(1);
  });

  it('PUT: 400 for duplicate or invalid rows, 404 for an unknown role', async () => {
    const dup = await put(adminSession, polisRole, { grants: [{ grantType: 'weapon', grantKey: 'x', effect: 'allow' }, { grantType: 'weapon', grantKey: 'x', effect: 'deny' }] }, adminSession.csrf);
    expect(dup.statusCode).toBe(400);
    const bad = await put(adminSession, polisRole, { grants: [{ grantType: 'weapon', grantKey: 'has space', effect: 'allow' }] }, adminSession.csrf);
    expect(bad.statusCode).toBe(400);
    const missing = await put(adminSession, nextId(), { grants: [] }, adminSession.csrf);
    expect(missing.statusCode).toBe(404);
  });

  it('PUT: 400 for a unit key FXServer would reject or that config/units.json does not know', async () => {
    for (const grantKey of ['igv.nord', 'igv:nord', 'x'.repeat(33), 'nord']) {
      const res = await put(adminSession, polisRole, { grants: [{ grantType: 'unit', grantKey, effect: 'allow' }] }, adminSession.csrf);
      expect(res.statusCode, grantKey).toBe(400);
      expect(res.json()).toMatchObject({ error: 'invalid_body' });
    }
    expect(t.fx.of('recompute')).toHaveLength(0);
    // A unit the role already has stays saveable after it was removed from units.json (so the role can be edited).
    await database!.pool.query("INSERT INTO fredpd_role_grants (discord_role_id, grant_type, grant_key, effect) VALUES (?, 'unit', 'nord', 'allow')", [adminRole]);
    const keep = await put(adminSession, adminRole, { grants: [{ grantType: 'perm', grantKey: 'admin.permissions', effect: 'allow' }, { grantType: 'unit', grantKey: 'nord', effect: 'allow' }] }, adminSession.csrf);
    expect(keep.statusCode).toBe(200);
    const dropped = await put(adminSession, adminRole, { grants: [{ grantType: 'perm', grantKey: 'admin.permissions', effect: 'allow' }] }, adminSession.csrf);
    expect(dropped.statusCode).toBe(200);
    t.fx.calls = [];
  });

  it('PUT: replaces the rows, audits perms.update, recomputes the holders and pushes to FXServer', async () => {
    t.fx.calls = [];
    t.fx.scheduled = 1; // one of the two holders is online
    const grants = [
      { grantType: 'weapon', grantKey: 'pistol', effect: 'allow' },
      { grantType: 'weapon', grantKey: 'rifle', effect: 'deny' },
      { grantType: 'unit', grantKey: 'igv', effect: 'allow' },
    ];
    const res = await put(adminSession, polisRole, { grants }, adminSession.csrf);
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ ok: true, recomputed: 1 });

    const stored = await rows<{ grant_type: string; grant_key: string; effect: string }>(database!, 'SELECT grant_type, grant_key, effect FROM fredpd_role_grants WHERE discord_role_id = ?', [polisRole]);
    expect(stored.map((r) => `${r.effect}:${r.grant_type}:${r.grant_key}`).sort()).toEqual(['allow:unit:igv', 'allow:weapon:pistol', 'deny:weapon:rifle']);

    const audit = await rows<{ actor_discord: string; target_type: string; meta: unknown }>(database!, "SELECT actor_discord, target_type, CAST(meta AS CHAR) AS meta FROM fredpd_audit WHERE action = 'perms.update' AND target_id = ?", [polisRole]);
    expect(audit).toHaveLength(1);
    expect(audit[0]!.actor_discord).toBe(admin);
    expect(audit[0]!.target_type).toBe('role');
    expect(JSON.parse(String(audit[0]!.meta))).toEqual({ before: ['+weapon:pistol'], after: ['+unit:igv', '+weapon:pistol', '-weapon:rifle'] });

    const recompute = t.fx.of('recompute');
    expect(recompute).toHaveLength(1);
    expect(new Set(recompute[0]!.discordIds)).toEqual(new Set([polis1, polis2]));

    const cache = await rows<{ discord_id: string; grants: string }>(database!, 'SELECT discord_id, CAST(grants AS CHAR) AS grants FROM fredpd_grant_cache WHERE discord_id IN (?, ?)', [polis1, polis2]);
    expect(cache).toHaveLength(2);
    for (const c of cache) {
      const set = JSON.parse(c.grants);
      expect(set.grants).toEqual(['unit:igv', 'weapon:pistol']);
      expect(set.denied).toEqual(['weapon:rifle']);
      expect(set.units).toEqual(['igv']);
    }
  });

  it('PUT with an empty list removes every row of the role', async () => {
    const res = await put(adminSession, polisRole, { grants: [] }, adminSession.csrf);
    expect(res.statusCode).toBe(200);
    expect(await rows(database!, 'SELECT id FROM fredpd_role_grants WHERE discord_role_id = ?', [polisRole])).toHaveLength(0);
  });
});
