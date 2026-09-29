// SPDX-License-Identifier: GPL-3.0-only
// /ws: session required, foreign Origin refused, /internal/events fan out to logged-in officers only, and a
// grant change (Discord role removed) stops delivery without reconnecting.
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
  const officer = nextId();
  const civilian = nextId();
  const sockets: WebSocket[] = [];

  beforeAll(async () => {
    if (!database) return;
    await cleanup(database, PREFIX);
    await seedRole(database, role, 'Polis', 10, [['mdt_page', 'alerts', 'allow']]);
    t = await makeApp({ database });
    t.gateway.addMember({ id: officer, roleIds: [GUILD_ID, role] });
    t.gateway.addMember({ id: civilian, roleIds: [GUILD_ID] });
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

  it('delivers /internal/events to officers, not to members without grants; stops after a role is removed', async () => {
    const off = await loginAs(t, database!, officer);
    const civ = await loginAs(t, database!, civilian);
    const wsOfficer = await connect(t, { cookie: off.cookie, origin: 'https://portal.example.test' });
    const wsCivilian = await connect(t, { cookie: civ.cookie });
    sockets.push(wsOfficer, wsCivilian);

    const got = nextMessage(wsOfficer);
    const res = await signedInject(t, { method: 'POST', url: '/internal/events', body: { type: 'alertCreated', payload: { id: 7, code: '10-15' } } });
    expect(res.json()).toEqual({ ok: true, delivered: 1 });
    expect(await got).toEqual({ type: 'alertCreated', payload: { id: 7, code: '10-15' } });

    // Discord role removed -> recompute -> the hub drops the officer.
    const before = t.gateway.getMember(officer)!;
    t.gateway.addMember({ ...before, roleIds: [GUILD_ID] });
    await t.app.fredpd.sync.memberUpdated(before, t.gateway.getMember(officer)!);
    const res2 = await signedInject(t, { method: 'POST', url: '/internal/events', body: { type: 'alertClosed', payload: { id: 7 } } });
    expect(res2.json()).toEqual({ ok: true, delivered: 0 });
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
