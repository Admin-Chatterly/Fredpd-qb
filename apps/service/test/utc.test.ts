// SPDX-License-Identifier: GPL-3.0-only
// UTC storage whatever the MariaDB time zone (docs/contracts.md §C7): the service's pool runs here with every
// session at +02:00 (a Stockholm-summer server that is not UTC). A Date written through the repo reads back as the
// same instant (drizzle and raw mysql2), is stored as UTC wall time, compares correctly in SQL, and DB defaults and
// updated_at (set by the writers, there is no ON UPDATE) are UTC. The Node process itself runs in Europe/Stockholm
// meanwhile (TZ, this worker only), like the service on Rami's Windows host. Own database fredpd_test_utc_service;
// skips without MariaDB.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createDatabase } from '../src/db/client';
import {
  findSession, insertSession, markRolesDeleted, touchIdentity, updateOfficerIdentity, upsertRoles, writeGrantCache,
} from '../src/db/repo';
import { emptyGrantSet } from '@fredpd/types/grants';
import { cleanup, ids, rows, setupTestDb, testDbUrl } from './helpers';

const UTC_DB = 'fredpd_test_utc_service';
const PREFIX = '871';
const migrated = await setupTestDb('utc.test', UTC_DB);
const database = migrated ? createDatabase(testDbUrl(UTC_DB), { connectionLimit: 2 }) : null;
// Every pooled connection starts with its session at +02:00; mysql2 runs a connection's commands in order, so this
// SET precedes the first query of each connection.
database?.pool.on('connection', (conn) => {
  conn.query("SET time_zone = '+02:00'");
});
const next = ids(PREFIX);
const OLD = '2000-01-01 00:00:00';

/** |seconds| between a UTC DATETIME column value and UTC_TIMESTAMP(), and minutes from it to the session clock. */
async function skew(sql: string, params: unknown[]): Promise<{ utc: number; session: number }> {
  const [r] = await rows<{ utc: number; session: number }>(database!,
    `SELECT ABS(TIMESTAMPDIFF(SECOND, x.t, UTC_TIMESTAMP())) AS utc, TIMESTAMPDIFF(MINUTE, x.t, NOW()) AS session FROM (${sql}) x`, params);
  return { utc: Number(r?.utc), session: Number(r?.session) };
}

function expectUtcNow(s: { utc: number; session: number }, what: string) {
  expect(s.utc, `${what}: within a minute of UTC_TIMESTAMP()`).toBeLessThanOrEqual(60);
  expect(s.session, `${what}: two hours behind the +02:00 session clock`).toBeGreaterThanOrEqual(119);
}

describe.skipIf(!database)('UTC round trip with the DB session at +02:00', () => {
  const savedTz = process.env.TZ;
  beforeAll(() => {
    process.env.TZ = 'Europe/Stockholm'; // Node re-reads TZ when it is assigned
  });
  afterAll(async () => {
    if (savedTz === undefined) delete process.env.TZ;
    else process.env.TZ = savedTz;
    if (database) await cleanup(database, PREFIX);
    await database?.close();
    await migrated?.close();
  });

  it('the pool sessions really run at +02:00 (and the Node host in Stockholm time)', async () => {
    const [r] = await rows(database!, 'SELECT @@session.time_zone AS tz, TIMESTAMPDIFF(MINUTE, UTC_TIMESTAMP(), NOW()) AS off');
    expect({ tz: r?.tz, off: Number(r?.off) }).toEqual({ tz: '+02:00', off: 120 });
    expect(new Date('2026-09-29T12:00:00Z').getTimezoneOffset()).toBe(-120);
  });

  it('a Date written by the service reads back as the same instant', async () => {
    const id = `${next()}`.padEnd(64, 'a');
    const discordId = next();
    const expiresAt = new Date('2026-09-29T12:34:56.000Z');
    await insertSession(database!.db, { id, discordId, citizenid: null, csrfToken: 'csrf', expiresAt });

    // drizzle (reads the text, appends Z)
    const found = await findSession(database!.db, id, new Date('2026-09-29T12:34:55.000Z'));
    expect(found?.expiresAt.toISOString()).toBe('2026-09-29T12:34:56.000Z');
    // SQL comparisons with a Date parameter use the same UTC wall time: one second later the session has expired.
    expect(await findSession(database!.db, id, new Date('2026-09-29T12:34:56.000Z'))).toBeNull();

    // raw mysql2 (timezone 'Z') and the stored wall time
    const [raw] = await rows<{ e: Date; iso: string }>(database!,
      "SELECT expires_at AS e, DATE_FORMAT(expires_at, '%Y-%m-%dT%H:%i:%sZ') AS iso FROM fredpd_sessions WHERE id = ?", [id]);
    expect(raw?.e).toBeInstanceOf(Date);
    expect(raw?.e.getTime()).toBe(expiresAt.getTime());
    expect(raw?.iso).toBe('2026-09-29T12:34:56Z');

    // created_at comes from the DB default (UTC_TIMESTAMP()), not the session clock.
    expectUtcNow(await skew('SELECT created_at AS t FROM fredpd_sessions WHERE id = ?', [id]), 'fredpd_sessions.created_at');
  });

  it('grant cache computed_at and identity last_seen keep the instant', async () => {
    const discordId = next();
    const set = { ...emptyGrantSet(new Date('2026-09-29T08:00:00.000Z')), computedAt: '2026-09-29T08:00:00.000Z' };
    await writeGrantCache(database!.db, [{ discordId, grants: set }]);
    const [cache] = await rows<{ iso: string }>(database!,
      "SELECT DATE_FORMAT(computed_at, '%Y-%m-%dT%H:%i:%sZ') AS iso FROM fredpd_grant_cache WHERE discord_id = ?", [discordId]);
    expect(cache?.iso).toBe('2026-09-29T08:00:00Z');

    const seen = new Date('2026-03-29T00:59:59.000Z'); // one second before the EU summer-time switch
    await touchIdentity(database!.db, discordId, seen);
    const [identity] = await rows<{ t: Date }>(database!, 'SELECT last_seen AS t FROM fredpd_identities WHERE discord_id = ?', [discordId]);
    expect(identity?.t.toISOString()).toBe('2026-03-29T00:59:59.000Z');
    expectUtcNow(await skew('SELECT created_at AS t FROM fredpd_identities WHERE discord_id = ?', [discordId]), 'fredpd_identities.created_at');
  });

  it('updated_at is set to UTC by drizzle updates and upserts (no ON UPDATE clause)', async () => {
    const roleId = next();
    await upsertRoles(database!.db, [{ id: roleId, name: 'Polis', colour: 0, position: 3 }]);
    expectUtcNow(await skew('SELECT created_at AS t FROM fredpd_roles WHERE discord_role_id = ?', [roleId]), 'roles.created_at');
    expectUtcNow(await skew('SELECT updated_at AS t FROM fredpd_roles WHERE discord_role_id = ?', [roleId]), 'roles.updated_at (insert)');

    await database!.pool.query('UPDATE fredpd_roles SET updated_at = ? WHERE discord_role_id = ?', [OLD, roleId]);
    await upsertRoles(database!.db, [{ id: roleId, name: 'Polisen', colour: 0, position: 3 }]);
    expectUtcNow(await skew('SELECT updated_at AS t FROM fredpd_roles WHERE discord_role_id = ?', [roleId]), 'roles.updated_at (upsert)');

    await database!.pool.query('UPDATE fredpd_roles SET updated_at = ? WHERE discord_role_id = ?', [OLD, roleId]);
    await markRolesDeleted(database!.db, [roleId]);
    expectUtcNow(await skew('SELECT updated_at AS t FROM fredpd_roles WHERE discord_role_id = ?', [roleId]), 'roles.updated_at (update)');

    const discordId = next();
    const citizenid = `T${PREFIX}UTC1`;
    await database!.pool.query("INSERT INTO fredpd_officers (citizenid, discord_id, display_name, updated_at) VALUES (?, ?, 'Gammal', ?)",
      [citizenid, discordId, OLD]);
    expectUtcNow(await skew('SELECT created_at AS t FROM fredpd_officers WHERE citizenid = ?', [citizenid]), 'officers.created_at');
    expect(await updateOfficerIdentity(database!.db, discordId, { displayName: 'Ny', avatarUrl: null })).toEqual({ rows: 1, changed: 1 });
    expectUtcNow(await skew('SELECT updated_at AS t FROM fredpd_officers WHERE citizenid = ?', [citizenid]), 'officers.updated_at');
    await database!.pool.query('DELETE FROM fredpd_officers WHERE citizenid = ?', [citizenid]);
  });
});
