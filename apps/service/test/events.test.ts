// SPDX-License-Identifier: GPL-3.0-only
// /ws live events without a database: who may receive what (docs/contracts.md §C13: only mdt_page:alerts, a deny
// wins, other grants give nothing), the per-type hub fan-out and socket cap, and the /internal/events payload check
// (DispatchInternalEventSchema after restoring Lua's absent nulls), including fredpd_dispatch's golden payloads.
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { InternalEvent } from '@fredpd/types/actions';
import { AlertSchema } from '@fredpd/types/dispatch';
import { emptyGrantSet } from '@fredpd/types/grants';
import type { GrantSet } from '@fredpd/types/grants';
import { CLOSE_SESSION_ENDED, CLOSE_TOO_MANY, WsHub } from '../src/ws/hub';
import type { HubSocket } from '../src/ws/hub';
import { checkInternalEvent, liveAccess, LIVE_EVENT_GRANTS, restoreNulls } from '../src/ws/events';
import { makeApp, ROOT, signedInject } from './helpers';
import type { TestApp } from './helpers';

const set = (grants: string[], denied: string[] = []): GrantSet => ({ ...emptyGrantSet(), grants, denied });

/** An Alert as fredpd_dispatch posts it: nullable fields that are nil in Lua are absent. */
const ALERT_FROM_LUA = {
  id: 7, code: '10-15', title: 'Skottlossning', priority: 1, source: 'ps-dispatch', status: 'open',
  createdAt: '2026-09-29T11:00:00Z', units: [], coords: { x: 1, y: 2, z: 3 },
};

class StubSocket implements HubSocket {
  readyState = 1;
  sent: string[] = [];
  closed: number | null = null;
  send(data: string): void {
    this.sent.push(data);
  }
  close(code?: number): void {
    this.closed = code ?? 1000;
    this.readyState = 3;
  }
}

describe('liveAccess (§C13)', () => {
  it('mdt_page:alerts (or mdt_page:*) gives every current event type', () => {
    for (const grants of [['mdt_page:alerts'], ['mdt_page:*']]) {
      expect([...liveAccess(true, set(grants))].sort()).toEqual(Object.keys(LIVE_EVENT_GRANTS).sort());
    }
  });

  it('any other grant gives nothing: weapon:*, tool:ram, perm:rank:x, mdt_page:search', () => {
    for (const g of ['weapon:*', 'tool:ram', 'perm:rank:inspektor', 'mdt_page:search', 'perm:*']) {
      expect(liveAccess(true, set([g])).size, g).toBe(0);
    }
  });

  it('a deny wins: allow mdt_page:* with deny mdt_page:alerts (or mdt_page:*) gives nothing', () => {
    expect(liveAccess(true, set(['mdt_page:*'], ['mdt_page:alerts'])).size).toBe(0);
    expect(liveAccess(true, set(['mdt_page:alerts'], ['mdt_page:*'])).size).toBe(0);
  });

  it('a non-member gets nothing whatever the set says', () => {
    expect(liveAccess(false, set(['mdt_page:alerts'])).size).toBe(0);
  });
});

describe('WsHub', () => {
  const session = (id: string, discordId: string) => ({ id, discordId, expiresAt: new Date(Date.now() + 3_600_000) });
  const event: InternalEvent = { type: 'alertClosed', payload: { id: 1 } };

  it('sends an event type only to users whose access includes it; setAccess applies without reconnecting', () => {
    const hub = new WsHub(() => new Date());
    const a = new StubSocket();
    const b = new StubSocket();
    hub.add(a, session('s1', '1'), liveAccess(true, set(['mdt_page:alerts'])));
    hub.add(b, session('s2', '2'), liveAccess(true, set(['weapon:*'])));
    expect(hub.broadcast(event)).toBe(1);
    expect(a.sent).toHaveLength(1);
    expect(b.sent).toHaveLength(0);
    hub.setAccess('1', liveAccess(true, set(['mdt_page:*'], ['mdt_page:alerts'])));
    hub.setAccess('2', liveAccess(true, set(['mdt_page:alerts'])));
    expect(hub.broadcast(event)).toBe(1);
    expect(a.sent).toHaveLength(1);
    expect(b.sent).toHaveLength(1);
    hub.setAccess('3', liveAccess(true, set(['mdt_page:alerts']))); // not connected: not tracked
    expect(hub.accessOf('3').size).toBe(0);
  });

  it('caps sockets per user: the oldest is closed with 4429', () => {
    const hub = new WsHub(() => new Date(), { maxSocketsPerUser: 2 });
    const access = liveAccess(true, set(['mdt_page:alerts']));
    const [s1, s2, s3] = [new StubSocket(), new StubSocket(), new StubSocket()];
    hub.add(s1, session('s', '1'), access);
    hub.add(s2, session('s', '1'), access);
    hub.add(new StubSocket(), session('x', '2'), access);
    hub.add(s3, session('s', '1'), access);
    expect(s1.closed).toBe(CLOSE_TOO_MANY);
    expect(s2.closed).toBeNull();
    expect(hub.size).toBe(3);
    expect(hub.broadcast(event)).toBe(3);
    expect(s1.sent).toHaveLength(0);
  });

  it('closes sockets of an expired session on the next broadcast', () => {
    let now = new Date('2026-09-29T12:00:00Z');
    const hub = new WsHub(() => now);
    const s = new StubSocket();
    hub.add(s, { id: 's', discordId: '1', expiresAt: new Date('2026-09-29T12:30:00Z') }, liveAccess(true, set(['mdt_page:alerts'])));
    now = new Date('2026-09-29T13:00:00Z');
    expect(hub.broadcast(event)).toBe(0);
    expect(s.closed).toBe(CLOSE_SESSION_ENDED);
  });
});

describe('checkInternalEvent / restoreNulls', () => {
  it('fills the nulls Lua could not send, then parses strictly and strips unknown keys', () => {
    const r = checkInternalEvent({ type: 'alertCreated', payload: { ...ALERT_FROM_LUA, meta: { secret: 1 } } });
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    const alert = AlertSchema.parse(r.event.payload);
    expect(alert).toMatchObject({ description: null, street: null, closedBy: null, closedAt: null, coords: { x: 1, y: 2, z: 3 } });
    expect(r.event.payload).not.toHaveProperty('meta');
  });

  it('refuses alert and unit events that do not match DispatchInternalEventSchema', () => {
    const bad: InternalEvent[] = [
      { type: 'alertCreated', payload: { id: 7, code: '10-15' } },
      { type: 'alertAssigned', payload: { ...ALERT_FROM_LUA, priority: 9 } },
      { type: 'alertClosed', payload: {} },
      { type: 'alertClosed', payload: null },
      { type: 'unitsChanged', payload: [] },
      { type: 'unitsChanged', payload: { units: [{ citizenid: 'A1' }] } },
    ];
    for (const e of bad) {
      const r = checkInternalEvent(e);
      expect(r.ok, JSON.stringify(e)).toBe(false);
    }
  });

  it('types without a pinned payload pass unchanged', () => {
    const e: InternalEvent = { type: 'playerJoined', payload: { src: 1 } };
    expect(checkInternalEvent(e)).toEqual({ ok: true, event: e });
  });

  it('restoreNulls leaves present values and non-objects alone', () => {
    expect(restoreNulls(AlertSchema, 5)).toBe(5);
    expect(restoreNulls(AlertSchema, { ...ALERT_FROM_LUA, street: 'Vinewood' })).toMatchObject({ street: 'Vinewood', description: null });
  });

  const golden = join(ROOT, 'resources', '[fredpd]', 'fredpd_dispatch', 'test', 'golden');
  const files = existsSync(golden) ? readdirSync(golden).filter((f) => /^internal\..+\.json$/.test(f)) : [];
  it.skipIf(files.length === 0)("fredpd_dispatch's golden /internal/events payloads all pass", () => {
    for (const f of files) {
      const r = checkInternalEvent(JSON.parse(readFileSync(join(golden, f), 'utf8')) as InternalEvent);
      expect(r.ok, f).toBe(true);
    }
  });
});

describe('POST /internal/events', () => {
  let t: TestApp;
  beforeAll(async () => {
    t = await makeApp();
  });
  afterAll(async () => {
    await t.app.close();
  });

  it('400 invalid_body for an alert payload that does not match the contract, 200 for a Lua-shaped one', async () => {
    const bad = await signedInject(t, { method: 'POST', url: '/internal/events', body: { type: 'alertCreated', payload: { id: 7, code: '10-15' } } });
    expect(bad.statusCode).toBe(400);
    expect(bad.json()).toMatchObject({ error: 'invalid_body' });
    const good = await signedInject(t, { method: 'POST', url: '/internal/events', body: { type: 'alertCreated', payload: ALERT_FROM_LUA } });
    expect(good.statusCode).toBe(200);
    expect(good.json()).toEqual({ ok: true, delivered: 0 });
  });
});
