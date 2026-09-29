// SPDX-License-Identifier: GPL-3.0-only
// GET /api/alerts and GET /api/units (docs/contracts.md §C13, task 3.5 service part): session + live grant
// mdt_page:alerts (403 otherwise, and at once after the role is removed), rate limit, AlertListOutputSchema /
// UnitsPushSchema shape checked with zod, 50 per page newest first, 'open' = open + assigned, units in take order
// with the current callsign, ISO UTC timestamps with the DB session at +02:00, and the units roster kept from the
// last valid `unitsChanged` event. Own database fredpd_test_service_alerts (it empties fredpd_alerts); the pure
// mapping tests run without MariaDB.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { AlertListOutputSchema, AlertSchema, UnitsPushSchema } from '@fredpd/types/dispatch';
import { RATE_LIMIT_PER_MINUTE } from '../src/app';
import { cap, officerRef, rowToAlert, toIsoUtc } from '../src/db/alerts';
import type { AlertRow } from '../src/db/alerts';
import { createDatabase } from '../src/db/client';
import { AlertListQuerySchema, UNITS_RECEIVED_AT_HEADER } from '../src/routes/alerts';
import { UnitsSnapshot } from '../src/ws/units-snapshot';
import { cleanup, GUILD_ID, ids, loginAs, makeApp, rows, seedRole, setupTestDb, signedInject, testDbUrl } from './helpers';
import type { TestApp } from './helpers';

// ---------------------------------------------------------------------------------------------------------------
// Pure mapping (no database)

const ROW: AlertRow = {
  id: 5, code: '10-15', title: 'Skottlossning', description: null, coords: { x: 1, y: 2.5, z: 3 }, street: 'Vespucci Blvd',
  priority: 1, source: 'ps-dispatch', status: 'assigned', closedBy: null, closedAt: null,
  createdAt: new Date('2026-09-29T11:00:00Z'), closedByName: null, closedByCallsign: null, closedByUnit: null,
};

describe('rowToAlert (same rules as fredpd_dispatch alert_store.lua)', () => {
  it('maps a row to a valid Alert with ISO UTC times', () => {
    const a = rowToAlert(ROW, []);
    expect(AlertSchema.parse(a)).toEqual(a);
    expect(a).toMatchObject({ id: 5, createdAt: '2026-09-29T11:00:00Z', coords: { x: 1, y: 2.5, z: 3 }, closedBy: null, closedAt: null, units: [] });
  });

  it('units: current callsign wins over the snapshot; name falls back to callsign, then citizenid', () => {
    const a = rowToAlert(ROW, [
      { alertId: 5, citizenid: 'ABC123', snapCallsign: 'OLD-01', displayName: 'Anna', callsign: 'IGV-07', unit: 'igv' },
      { alertId: 5, citizenid: 'DEF456', snapCallsign: 'SPN-02', displayName: null, callsign: null, unit: null },
      { alertId: 5, citizenid: 'GHI789', snapCallsign: null, displayName: null, callsign: null, unit: null },
      { alertId: 5, citizenid: 'bad id!', snapCallsign: null, displayName: 'X', callsign: null, unit: null },
    ]);
    expect(a?.units).toEqual([
      { citizenid: 'ABC123', displayName: 'Anna', callsign: 'IGV-07', unit: 'igv' },
      { citizenid: 'DEF456', displayName: 'SPN-02', callsign: 'SPN-02', unit: null },
      { citizenid: 'GHI789', displayName: 'GHI789', callsign: null, unit: null },
    ]);
  });

  it('bad coords -> null, priority outside 1–3 -> 2, over-long text capped without splitting a surrogate pair', () => {
    const a = rowToAlert({ ...ROW, coords: { x: 1, y: 'nope', z: 3 }, priority: 9, description: `${'a'.repeat(999)}😀x` }, []);
    expect(a?.coords).toBeNull();
    expect(a?.priority).toBe(2);
    expect(a?.description).toBe('a'.repeat(999));
    expect(rowToAlert({ ...ROW, coords: '{"x":1}' }, [])?.coords).toBeNull();
    expect(cap('ab😀', 3)).toBe('ab');
  });

  it('a closed alert carries closedBy and closedAt', () => {
    const a = rowToAlert({ ...ROW, status: 'closed', closedBy: 'ABC123', closedAt: new Date('2026-09-29T12:30:00Z'), closedByName: 'Anna', closedByCallsign: 'IGV-07', closedByUnit: 'igv' }, []);
    expect(a).toMatchObject({ status: 'closed', closedAt: '2026-09-29T12:30:00Z', closedBy: { citizenid: 'ABC123', displayName: 'Anna', callsign: 'IGV-07', unit: 'igv' } });
    expect(officerRef(null, 'x', null, null)).toBeNull();
  });

  it('toIsoUtc drops the milliseconds and keeps the instant', () => {
    expect(toIsoUtc(new Date('2026-01-02T03:04:05.000Z'))).toBe('2026-01-02T03:04:05Z');
    expect(toIsoUtc(null)).toBeNull();
  });
});

describe('AlertListQuerySchema', () => {
  it('defaults to open, page 1; coerces the page; refuses mine, page 0 and junk', () => {
    expect(AlertListQuerySchema.parse({})).toEqual({ filter: 'open', page: 1 });
    expect(AlertListQuerySchema.parse({ filter: 'all', page: '3' })).toEqual({ filter: 'all', page: 3 });
    for (const q of [{ filter: 'mine' }, { page: '0' }, { page: 'abc' }, { page: '1.5' }, { page: '10001' }]) {
      expect(AlertListQuerySchema.safeParse(q).success, JSON.stringify(q)).toBe(false);
    }
  });
});

describe('UnitsSnapshot', () => {
  it('is an empty roster until the first unitsChanged, then the newest one', () => {
    const s = new UnitsSnapshot();
    expect(s.get()).toEqual({ units: [] });
    expect(s.receivedAt).toBeNull();
    const at = new Date('2026-09-29T10:00:00Z');
    s.set({ units: [{ citizenid: 'A1', displayName: 'A', callsign: null, unit: null, onDuty: true, alertId: null }] }, at);
    expect(s.get().units).toHaveLength(1);
    expect(s.receivedAt).toEqual(at);
  });
});

// ---------------------------------------------------------------------------------------------------------------
// Routes (database)

const ALERTS_DB = 'fredpd_test_service_alerts';
const PREFIX = '911';
const migrated = await setupTestDb('alerts.test', ALERTS_DB);
const database = migrated ? createDatabase(testDbUrl(ALERTS_DB), { connectionLimit: 3 }) : null;
// Every pooled connection runs at +02:00 (a Stockholm-summer server that is not UTC); the API must still say UTC.
database?.pool.on('connection', (conn) => {
  conn.query("SET time_zone = '+02:00'");
});
const nextId = ids(PREFIX);

describe.skipIf(!database)('GET /api/alerts, /api/units (DB)', () => {
  let t: TestApp;
  const role = nextId();
  const denyRole = nextId();
  const officer = nextId();
  const civilian = nextId();
  const denied = nextId();
  const limited = nextId();
  const get = (url: string, cookie?: string) => t.app.inject({ method: 'GET', url, headers: cookie ? { cookie } : {} });

  beforeAll(async () => {
    const db = database!;
    await cleanup(db, PREFIX);
    await db.pool.query('DELETE FROM fredpd_alerts'); // own database: cascades to fredpd_alert_units
    await seedRole(db, role, 'Polis', 10, [['mdt_page', 'alerts', 'allow']]);
    await seedRole(db, denyRole, 'Utan larm', 11, [['mdt_page', '*', 'allow'], ['mdt_page', 'alerts', 'deny']]);
    await db.pool.query(
      'INSERT INTO fredpd_officers (citizenid, discord_id, display_name, callsign, unit) VALUES (?, ?, ?, ?, ?), (?, ?, ?, ?, ?)',
      ['T911A', officer, 'Anna Andersson', 'IGV-07', 'igv', 'T911B', civilian, 'Bertil', null, null],
    );
    // 120 alerts: ids ascending with created_at one minute apart from 2026-09-29 10:00:00 UTC. Every third is
    // closed (by T911A), the rest open; alerts 1..4 have units.
    const values: unknown[] = [];
    const marks: string[] = [];
    for (let i = 1; i <= 120; i += 1) {
      const closed = i % 3 === 0;
      const created = new Date(Date.UTC(2026, 8, 29, 10, i, 0)).toISOString().slice(0, 19).replace('T', ' ');
      marks.push('(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)');
      values.push(i, '10-15', `Larm ${i}`, i === 1 ? 'Beskrivning' : null, i % 2 === 0 ? JSON.stringify({ x: i, y: -i, z: 30.5 }) : null,
        i % 2 === 0 ? 'Vespucci Blvd' : null, (i % 3) + 1, 'ps-dispatch', closed ? 'closed' : 'open', closed ? 'T911A' : null,
        closed ? created : null, created);
    }
    await db.pool.query(
      `INSERT INTO fredpd_alerts (id, code, title, description, coords, street, priority, source, status, closed_by, closed_at, created_at) VALUES ${marks.join(', ')}`,
      values,
    );
    await db.pool.query("UPDATE fredpd_alerts SET status = 'assigned' WHERE id IN (118, 119)");
    await db.pool.query(
      "INSERT INTO fredpd_alert_units (alert_id, citizenid, callsign, created_at) VALUES (119, 'T911B', 'SPN-02', '2026-09-29 12:00:01'), (119, 'T911A', 'OLD-01', '2026-09-29 12:00:00'), (118, 'T911Z', 'TKN-01', '2026-09-29 12:00:00')",
    );
    t = await makeApp({ database: db });
    t.gateway.addMember({ id: officer, roleIds: [GUILD_ID, role] });
    t.gateway.addMember({ id: civilian, roleIds: [GUILD_ID] });
    t.gateway.addMember({ id: denied, roleIds: [GUILD_ID, role, denyRole] });
    t.gateway.addMember({ id: limited, roleIds: [GUILD_ID, role] });
  });

  afterAll(async () => {
    await t?.app.close();
    if (database) {
      await database.pool.query('DELETE FROM fredpd_alerts');
      await cleanup(database, PREFIX);
      await database.close();
    }
    await migrated?.close();
  });

  it('401 without a session; 403 without mdt_page:alerts, with a deny, and for a user who left the guild', async () => {
    expect((await get('/api/alerts')).statusCode).toBe(401);
    expect((await get('/api/units')).json()).toEqual({ error: 'unauthenticated' });
    for (const who of [civilian, denied]) {
      const { cookie } = await loginAs(t, database!, who);
      for (const url of ['/api/alerts', '/api/units']) {
        const res = await get(url, cookie);
        expect(res.statusCode, `${who} ${url}`).toBe(403);
        expect(res.json()).toEqual({ error: 'forbidden' });
      }
    }
  });

  it('open list: AlertListOutputSchema shape, 50 per page, newest first, open + assigned only', async () => {
    const { cookie } = await loginAs(t, database!, officer);
    const res = await get('/api/alerts', cookie);
    expect(res.statusCode).toBe(200);
    expect(res.headers['cache-control']).toBe('no-store');
    const body = AlertListOutputSchema.parse(res.json());
    expect(body).toEqual(res.json()); // nothing stripped: exactly the contract's keys
    expect(body.total).toBe(80);
    expect(body.page).toBe(1);
    expect(body.items).toHaveLength(50);
    expect(body.items.map((a) => a.id).slice(0, 4)).toEqual([119, 118, 116, 115]);
    expect(body.items.every((a) => a.status !== 'closed')).toBe(true);

    const p2 = AlertListOutputSchema.parse((await get('/api/alerts?filter=open&page=2', cookie)).json());
    expect(p2.items).toHaveLength(30);
    expect(p2.page).toBe(2);
    expect(new Set([...body.items, ...p2.items].map((a) => a.id)).size).toBe(80);
    const p3 = AlertListOutputSchema.parse((await get('/api/alerts?page=3', cookie)).json());
    expect(p3).toEqual({ items: [], total: 80, page: 3 });
  });

  it('all list: every alert; closed ones carry closedBy (current officer row) and closedAt', async () => {
    const { cookie } = await loginAs(t, database!, officer);
    const body = AlertListOutputSchema.parse((await get('/api/alerts?filter=all', cookie)).json());
    expect(body.total).toBe(120);
    expect(body.items[0]?.id).toBe(120);
    expect(body.items[0]).toMatchObject({
      status: 'closed', closedAt: '2026-09-29T12:00:00Z',
      closedBy: { citizenid: 'T911A', displayName: 'Anna Andersson', callsign: 'IGV-07', unit: 'igv' },
    });
    const last = AlertListOutputSchema.parse((await get('/api/alerts?filter=all&page=3', cookie)).json());
    expect(last.items.map((a) => a.id)).toEqual([20, 19, 18, 17, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1]);
    expect(last.items.at(-1)).toMatchObject({ id: 1, description: 'Beskrivning', coords: null, street: null, priority: 2, units: [] });
    expect(last.items.find((a) => a.id === 2)).toMatchObject({ coords: { x: 2, y: -2, z: 30.5 }, street: 'Vespucci Blvd', priority: 3 });
  });

  it('units in take order, current callsign over the snapshot, unknown officer by snapshot callsign', async () => {
    const { cookie } = await loginAs(t, database!, officer);
    const body = AlertListOutputSchema.parse((await get('/api/alerts', cookie)).json());
    expect(body.items[0]?.units).toEqual([
      { citizenid: 'T911A', displayName: 'Anna Andersson', callsign: 'IGV-07', unit: 'igv' },
      { citizenid: 'T911B', displayName: 'Bertil', callsign: 'SPN-02', unit: null },
    ]);
    expect(body.items[1]?.units).toEqual([{ citizenid: 'T911Z', displayName: 'TKN-01', callsign: 'TKN-01', unit: null }]);
  });

  it('UTC round trip: stored UTC wall time comes back as the same Z instant with the session at +02:00', async () => {
    const [tz] = await rows<{ tz: string }>(database!, 'SELECT @@session.time_zone AS tz');
    expect(tz?.tz).toBe('+02:00');
    const { cookie } = await loginAs(t, database!, officer);
    const body = AlertListOutputSchema.parse((await get('/api/alerts?filter=all&page=3', cookie)).json());
    expect(body.items.find((a) => a.id === 1)?.createdAt).toBe('2026-09-29T10:01:00Z');
    // A row written with UTC_TIMESTAMP() (as fredpd_dispatch does) reads back within a minute of now.
    await database!.pool.query("INSERT INTO fredpd_alerts (id, code, title, source, status, created_at, updated_at) VALUES (500, '10-99', 'Nu', 'devtools', 'open', UTC_TIMESTAMP(), UTC_TIMESTAMP())");
    try {
      const now = AlertListOutputSchema.parse((await get('/api/alerts', cookie)).json()).items[0]!;
      expect(now.id).toBe(500);
      expect(Math.abs(Date.parse(now.createdAt) - Date.now())).toBeLessThan(60_000);
    } finally {
      await database!.pool.query('DELETE FROM fredpd_alerts WHERE id = 500');
    }
  });

  it('400 invalid_body for a bad query', async () => {
    const { cookie } = await loginAs(t, database!, officer);
    for (const q of ['filter=mine', 'filter=x', 'page=0', 'page=abc']) {
      const res = await get(`/api/alerts?${q}`, cookie);
      expect(res.statusCode, q).toBe(400);
      expect(res.json()).toMatchObject({ error: 'invalid_body' });
    }
  });

  it('a grant revoked mid-session applies to the next request', async () => {
    const { cookie } = await loginAs(t, database!, officer);
    expect((await get('/api/units', cookie)).statusCode).toBe(200);
    t.gateway.addMember({ id: officer, roleIds: [GUILD_ID] });
    try {
      expect((await get('/api/alerts', cookie)).statusCode).toBe(403);
      expect((await get('/api/units', cookie)).statusCode).toBe(403);
      t.gateway.members.delete(officer); // left the guild
      expect((await get('/api/alerts', cookie)).statusCode).toBe(403);
    } finally {
      t.gateway.addMember({ id: officer, roleIds: [GUILD_ID, role] });
    }
    expect((await get('/api/alerts', cookie)).statusCode).toBe(200);
  });

  it('/api/units: empty roster, then the last valid unitsChanged (Lua nulls restored); an invalid one changes nothing', async () => {
    const { cookie } = await loginAs(t, database!, officer);
    const empty = await get('/api/units', cookie);
    expect(empty.json()).toEqual({ units: [] });
    expect(empty.headers[UNITS_RECEIVED_AT_HEADER]).toBeUndefined();
    const lua = { units: [{ citizenid: 'T911A', displayName: 'Anna Andersson', callsign: 'IGV-07', unit: 'igv', onDuty: true, alertId: 119 }, { citizenid: 'T911B', displayName: 'Bertil', onDuty: true }] };
    const posted = await signedInject(t, { method: 'POST', url: '/internal/events', body: { type: 'unitsChanged', payload: lua } });
    expect(posted.statusCode).toBe(200);
    const res = await get('/api/units', cookie);
    expect(res.headers['cache-control']).toBe('no-store');
    // The roster's age: when the service received it, ISO UTC without milliseconds.
    expect(res.headers[UNITS_RECEIVED_AT_HEADER]).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
    const units = UnitsPushSchema.parse(res.json());
    expect(units.units[1]).toEqual({ citizenid: 'T911B', displayName: 'Bertil', callsign: null, unit: null, onDuty: true, alertId: null });
    const bad = await signedInject(t, { method: 'POST', url: '/internal/events', body: { type: 'unitsChanged', payload: { units: [{ citizenid: 'x' }] } } });
    expect(bad.statusCode).toBe(400);
    expect((await get('/api/units', cookie)).json()).toEqual(units);
    // Only unitsChanged replaces the roster.
    await signedInject(t, { method: 'POST', url: '/internal/events', body: { type: 'alertClosed', payload: { id: 1 } } });
    expect((await get('/api/units', cookie)).json()).toEqual(units);
  });

  it('rate limit: the 61st request a minute from one session gets 429', async () => {
    const { cookie } = await loginAs(t, database!, limited);
    for (let i = 0; i < RATE_LIMIT_PER_MINUTE; i += 1) expect((await get('/api/units', cookie)).statusCode).toBe(200);
    const res = await get('/api/alerts', cookie);
    expect(res.statusCode).toBe(429);
    expect(res.json()).toEqual({ error: 'rate_limited' });
  });
});
