// SPDX-License-Identifier: GPL-3.0-only
// /ws: session required, foreign Origin refused, only users with mdt_page:alerts (docs/contracts.md §C13) may open a
// socket and receive /internal/events (any other grant, or allow mdt_page:* with a deny on mdt_page:alerts, gets
// 403 and nothing), and a grant change (Discord role removed) stops delivery without reconnecting.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { WebSocket } from '@fastify/websocket';
import { cleanup, GUILD_ID, ids, loginAs, makeApp, seedRole, setupTestDb, signedInject } from './helpers';
import type { TestApp } from './helpers';

const PREFIX = '905';
const database = await setupTestDb('ws.test');
const nextId = ids(PREFIX);

/** injectWS's fake upgrade request has no socket; give it the loopback address a real connection would have. */
function connect(t: TestApp, headers: Record<string, string> = {}): Promise<WebSocket> {
  return t.app.injectWS('/ws', { headers, socket: { remoteAddress: '127.0.0.1' } } as unknown as Parameters<TestApp['app']['injectWS']>[1]);
}

/** An Alert as fredpd_dispatch posts it (nullable fields that are nil in Lua are absent). */
const ALERT = {
  id: 7, code: '10-15', title: 'Skottlossning', priority: 1, source: 'ps-dispatch', status: 'open',
  createdAt: '2026-09-29T11:00:00Z', units: [], coords: { x: 1, y: 2, z: 3 },
};

function nextMessage(ws: WebSocket, timeoutMs = 1000): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('no message')), timeoutMs);
    ws.once('message', (data) => {
      clearTimeout(timer);
      resolve(JSON.parse(String(data)));
    });
  });
}

describe.skipIf(!database)('/ws live events (DB)', () => {
  let t: TestApp;
  const role = nextId();
  const armoryRole = nextId();
  const deniedRole = nextId();
  const officer = nextId();
  const civilian = nextId();
  const armoryOnly = nextId();
  const denied = nextId();
  const sockets: WebSocket[] = [];

  beforeAll(async () => {
    if (!database) return;
    await cleanup(database, PREFIX);
    await seedRole(database, role, 'Polis', 10, [['mdt_page', 'alerts', 'allow']]);
    await seedRole(database, armoryRole, 'Vapen', 11, [['weapon', '*', 'allow'], ['tool', 'ram', 'allow'], ['perm', 'rank:inspektor', 'allow']]);
    await seedRole(database, deniedRole, 'Utan larm', 12, [['mdt_page', '*', 'allow'], ['mdt_page', 'alerts', 'deny']]);
    t = await makeApp({ database });
    t.gateway.addMember({ id: officer, roleIds: [GUILD_ID, role] });
    t.gateway.addMember({ id: civilian, roleIds: [GUILD_ID] });
    t.gateway.addMember({ id: armoryOnly, roleIds: [GUILD_ID, armoryRole] });
    t.gateway.addMember({ id: denied, roleIds: [GUILD_ID, deniedRole] });
  });

  afterAll(async () => {
    sockets.forEach((s) => s.terminate());
    if (!database) return;
    await t?.app.close();
    await cleanup(database, PREFIX);
    await database.close();
  });

  it('refuses the upgrade without a session and from a foreign origin', async () => {
    await expect(connect(t)).rejects.toThrow(/401/);
    const { cookie } = await loginAs(t, database!, officer);
    await expect(connect(t, { cookie, origin: 'https://evil.example' })).rejects.toThrow(/403/);
  });

  it('refuses the upgrade (403) for members whose grants allow no live event', async () => {
    for (const who of [civilian, armoryOnly, denied]) {
      const { cookie } = await loginAs(t, database!, who);
      await expect(connect(t, { cookie }), who).rejects.toThrow(/403/);
    }
  });

  it('delivers /internal/events to mdt_page:alerts holders only; stops after the role is removed', async () => {
    const off = await loginAs(t, database!, officer);
    const wsOfficer = await connect(t, { cookie: off.cookie, origin: 'https://portal.example.test' });
    sockets.push(wsOfficer);

    const got = nextMessage(wsOfficer);
    const res = await signedInject(t, { method: 'POST', url: '/internal/events', body: { type: 'alertCreated', payload: ALERT } });
    expect(res.json()).toEqual({ ok: true, delivered: 1 });
    // What the browser gets is the parsed Alert: the nulls Lua could not send are filled in.
    expect(await got).toEqual({ type: 'alertCreated', payload: { ...ALERT, description: null, street: null, closedBy: null, closedAt: null } });

    // Discord role removed -> recompute -> the hub drops the officer.
    const before = t.gateway.getMember(officer)!;
    t.gateway.addMember({ ...before, roleIds: [GUILD_ID] });
    await t.app.fredpd.sync.memberUpdated(before, t.gateway.getMember(officer)!);
    const res2 = await signedInject(t, { method: 'POST', url: '/internal/events', body: { type: 'alertClosed', payload: { id: 7 } } });
    expect(res2.json()).toEqual({ ok: true, delivered: 0 });

    // A deny added to a connected officer's roles (FXServer re-fetch) also stops delivery.
    t.gateway.addMember({ ...before, roleIds: [GUILD_ID, role] });
    await t.app.fredpd.sync.memberUpdated({ ...before, roleIds: [GUILD_ID] }, t.gateway.getMember(officer)!);
    expect((await signedInject(t, { method: 'POST', url: '/internal/events', body: { type: 'alertClosed', payload: { id: 7 } } })).json()).toEqual({ ok: true, delivered: 1 });
    t.gateway.addMember({ ...before, roleIds: [GUILD_ID, role, deniedRole] });
    await signedInject(t, { method: 'GET', url: `/internal/grants/${officer}` });
    expect((await signedInject(t, { method: 'POST', url: '/internal/events', body: { type: 'alertClosed', payload: { id: 7 } } })).json()).toEqual({ ok: true, delivered: 0 });
    t.gateway.addMember({ ...before, roleIds: [GUILD_ID, role] });
  });

  it('logout closes the session sockets', async () => {
    t.gateway.addMember({ id: officer, roleIds: [GUILD_ID, role] });
    const off = await loginAs(t, database!, officer);
    const ws = await connect(t, { cookie: off.cookie });
    sockets.push(ws);
    const closed = new Promise<number>((resolve) => ws.once('close', (code) => resolve(code)));
    await t.app.inject({ method: 'POST', url: '/auth/logout', headers: { cookie: off.cookie, 'x-csrf-token': off.csrf } });
    expect(await closed).toBe(4401);
  });
});
