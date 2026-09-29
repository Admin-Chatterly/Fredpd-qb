// SPDX-License-Identifier: GPL-3.0-only
// Test helpers: config, fakes for every outside dependency of buildApp, the shared test database
// (fredpd_test_service, migrated with scripts/migrate.mjs) and HMAC/cookie request helpers.
// Test files run in parallel against one database, so each file uses its own id prefix (ids()) and cleans only
// its own rows.
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { FastifyInstance, InjectOptions } from 'fastify';
import mysql from 'mysql2/promise';
import { signedHeaders } from '@fredpd/types/hmac';
import type { GrantSet } from '@fredpd/types/grants';
import { buildApp } from '../src/app';
import type { AppDeps } from '../src/app';
import type { DiscordOAuth, DiscordUser } from '../src/auth/oauth';
import { createSession, SESSION_COOKIE } from '../src/auth/session';
import type { Clock } from '../src/clock';
import { ConfigSchema } from '../src/config';
import type { Config } from '../src/config';
import { createDatabase } from '../src/db/client';
import type { Database, Db } from '../src/db/client';
import type { DiscordGateway, GatewayMember, GatewayRole } from '../src/discord/gateway';
import type { FxClient, FxResult } from '../src/fx';
import { silentLogger } from '../src/log';

export const ROOT = fileURLToPath(new URL('../../../', import.meta.url));
export const HMAC_SECRET = 'test-hmac-secret-0123456789abcdef-XYZ';
export const GUILD_ID = '100000000000000000';

export function testConfig(overrides: Partial<Record<keyof Config, string>> = {}): Config {
  return ConfigSchema.parse({
    FREDPD_DB_URL: 'mysql://fredpd:fredpd@127.0.0.1:3306/fredpd_test_service',
    FREDPD_HMAC_SECRET: HMAC_SECRET,
    DISCORD_CLIENT_ID: '200000000000000000',
    DISCORD_CLIENT_SECRET: 'client-secret',
    DISCORD_BOT_TOKEN: 'bot-token',
    DISCORD_GUILD_ID: GUILD_ID,
    PUBLIC_URL: 'https://portal.example.test',
    SESSION_SECRET: 'test-session-secret-0123456789abcdef-XYZ',
    COOKIE_SECURE: 'false',
    LOG_LEVEL: 'silent',
    ...overrides,
  });
}

// ---------------------------------------------------------------------------------------------------------------
// Fakes

export class FakeGateway implements DiscordGateway {
  ready = true;
  members = new Map<string, GatewayMember>();
  roles: GatewayRole[] = [];

  isReady(): boolean {
    return this.ready;
  }
  getMember(id: string): GatewayMember | null {
    const m = this.members.get(id);
    return m ? { ...m, roleIds: [...m.roleIds] } : null;
  }
  listRoles(): GatewayRole[] {
    return [...this.roles];
  }
  membersWithRole(roleId: string): string[] {
    return [...this.members.values()].filter((m) => m.roleIds.includes(roleId)).map((m) => m.id);
  }
  addMember(partial: Partial<GatewayMember> & { id: string }): GatewayMember {
    const m: GatewayMember = { username: `user${partial.id.slice(-4)}`, globalName: null, nick: null, avatar: null, guildAvatar: null, roleIds: [], ...partial };
    this.members.set(m.id, m);
    return m;
  }
}

export type FxCall =
  | { kind: 'ping' }
  | { kind: 'grants'; discordId: string; grants: GrantSet }
  | { kind: 'recompute'; discordIds: string[] | undefined }
  | { kind: 'officer'; discordId: string; displayName: string; avatarUrl: string | null }
  | { kind: 'rules' }
  | { kind: 'portal'; body: Record<string, unknown> };

export class FakeFx implements FxClient {
  calls: FxCall[] = [];
  scheduled = 0;
  ok = true;

  private result(body: Record<string, unknown>): FxResult {
    return this.ok ? { ok: true, status: 200, body } : { ok: false, status: 0, error: 'network' };
  }
  async ping() {
    this.calls.push({ kind: 'ping' });
    return this.result({ ok: true, players: 0 });
  }
  async pushGrants(discordId: string, grants: GrantSet) {
    this.calls.push({ kind: 'grants', discordId, grants });
    return this.result({ ok: true, applied: 1 });
  }
  async recompute(discordIds?: string[]) {
    this.calls.push({ kind: 'recompute', discordIds });
    return this.result({ ok: true, scheduled: this.scheduled });
  }
  async pushOfficer(discordId: string, displayName: string, avatarUrl: string | null) {
    this.calls.push({ kind: 'officer', discordId, displayName, avatarUrl });
    return this.result({ ok: true, updated: 1 });
  }
  async pushRulesChanged() {
    this.calls.push({ kind: 'rules' });
    return this.result({ ok: true });
  }
  /** Answer of POST /fredpd_mdt/portal; tests replace it (a fake FXServer running fredpd_mdt in portal mode). */
  portalAnswer: (body: Record<string, unknown>) => FxResult | Promise<FxResult> = () => ({ ok: true, status: 200, body: { ok: true, data: {} } });
  async portal(body: Record<string, unknown>) {
    this.calls.push({ kind: 'portal', body });
    if (!this.ok) return { ok: false as const, status: 0, error: 'network' };
    return this.portalAnswer(body);
  }
  of<K extends FxCall['kind']>(kind: K): Extract<FxCall, { kind: K }>[] {
    return this.calls.filter((c): c is Extract<FxCall, { kind: K }> => c.kind === kind);
  }
}

/** OAuth without Discord: ?code=good-<discordId> logs in as that user, anything else fails like a bad code. */
export class FakeOAuth implements DiscordOAuth {
  users = new Map<string, DiscordUser>();
  async authorizeUrl(): Promise<string> {
    return 'https://discord.test/oauth2/authorize?state=fake';
  }
  async exchangeCode(request: { query: unknown }): Promise<string> {
    const code = (request.query as { code?: string }).code ?? '';
    if (!code.startsWith('good-')) throw new Error('invalid_grant');
    return `token-${code.slice(5)}`;
  }
  async fetchUser(accessToken: string): Promise<DiscordUser> {
    const id = accessToken.replace(/^token-/, '');
    return this.users.get(id) ?? { id, username: `user${id.slice(-4)}`, globalName: null, avatar: null };
  }
}

export function fixedClock(start = new Date()): Clock & { set(d: Date): void; advance(ms: number): void } {
  let now = new Date(Math.floor(start.getTime() / 1000) * 1000);
  return {
    now: () => new Date(now),
    set: (d) => {
      now = new Date(d);
    },
    advance: (ms) => {
      now = new Date(now.getTime() + ms);
    },
  };
}

// ---------------------------------------------------------------------------------------------------------------
// Database

const BASE_URL = process.env.FREDPD_TEST_DB_URL ?? 'mysql://fredpd:fredpd@127.0.0.1:3306/fredpd_test';
export const TEST_DB = 'fredpd_test_service';

export function testDbUrl(database: string = TEST_DB): string {
  const u = new URL(BASE_URL);
  u.pathname = `/${database}`;
  return u.toString();
}

type MigrateModule = {
  migrate(opts: { url: string; log?: (m: string) => void }): Promise<unknown>;
  status(opts: { url: string }): Promise<{ id: string; state: string }[]>;
};

/**
 * Create (if needed) and migrate fredpd_test_service (or another test database); null with a warning when MariaDB
 * is unreachable, so DB tests skip. A test database with an applied migration whose checksum no longer matches
 * db/migrations (an edited migration) is dropped and rebuilt, since the runner rightly refuses that drift. An applied
 * migration whose file is not in this checkout ('missing', e.g. a newer checkout's 010_*.sql on a shared MariaDB) only
 * gets the runner's warning: dropping would pull the database from under the other checkout's running tests. The
 * check-drop-migrate runs under a server-side lock per database, so the first of the parallel test files rebuilds
 * it and the others find it current.
 */
export async function setupTestDb(tag: string, database: string = TEST_DB): Promise<Database | null> {
  const admin = new URL(BASE_URL);
  admin.pathname = '/';
  let conn: mysql.Connection;
  try {
    conn = await mysql.createConnection({ uri: admin.toString(), connectTimeout: 3000 });
  } catch (err) {
    console.warn(`[${tag}] database unreachable at ${admin.host} (${(err as Error).message}); skipping DB tests`);
    return null;
  }
  const migratePath: string = join(ROOT, 'scripts', 'migrate.mjs');
  const mig = (await import(migratePath)) as MigrateModule;
  const lock = `fredpd_test_setup_${database}`.slice(0, 64);
  try {
    const [[got]] = (await conn.query('SELECT GET_LOCK(?, 120) AS ok', [lock])) as unknown as [[{ ok: number }]];
    if (Number(got.ok) !== 1) throw new Error(`[${tag}] could not lock ${database} for setup`);
    await conn.query(`CREATE DATABASE IF NOT EXISTS \`${database}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_swedish_ci`);
    const states = await mig.status({ url: testDbUrl(database) });
    if (states.some((s) => s.state === 'changed' && !s.id.startsWith('seed/'))) {
      await conn.query(`DROP DATABASE \`${database}\``);
      await conn.query(`CREATE DATABASE \`${database}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_swedish_ci`);
    }
    await mig.migrate({ url: testDbUrl(database), log: () => {} });
  } finally {
    await conn.query('SELECT RELEASE_LOCK(?)', [lock]).catch(() => {});
    await conn.end();
  }
  return createDatabase(testDbUrl(database), { connectionLimit: 4 });
}

/** 18-digit snowflake-like ids with a per-file 3-digit prefix, so parallel files never collide. */
export function ids(prefix: string): () => string {
  if (!/^\d{3}$/.test(prefix)) throw new Error('prefix must be 3 digits');
  let n = 0;
  return () => `${prefix}${String(++n).padStart(15, '0')}`;
}

/** Delete every row a file created (ids starting with its prefix). */
export async function cleanup(database: Database, prefix: string): Promise<void> {
  const like = `${prefix}%`;
  const q = (s: string, params: unknown[]) => database.pool.query(s, params);
  await q('DELETE FROM fredpd_roles WHERE discord_role_id LIKE ?', [like]); // cascades to fredpd_role_grants
  await q('DELETE FROM fredpd_grant_cache WHERE discord_id LIKE ?', [like]);
  await q('DELETE FROM fredpd_identities WHERE discord_id LIKE ?', [like]);
  await q('DELETE FROM fredpd_sessions WHERE discord_id LIKE ?', [like]);
  await q('DELETE FROM fredpd_officers WHERE discord_id LIKE ?', [like]);
  await q('DELETE FROM fredpd_uploads WHERE uploader_discord LIKE ? OR uploader_citizenid LIKE ?', [like, `T${prefix}%`]);
  await q('DELETE FROM fredpd_audit WHERE actor_discord LIKE ? OR target_id LIKE ? OR actor_citizenid LIKE ?', [like, like, `T${prefix}%`]);
}

export async function rows<T = Record<string, unknown>>(database: Database, sql: string, params: unknown[] = []): Promise<T[]> {
  const [r] = await database.pool.query(sql, params);
  return r as T[];
}

export async function seedRole(database: Database, id: string, name: string, position: number, grants: [string, string, 'allow' | 'deny'][] = [], deleted = false): Promise<void> {
  await database.pool.query(
    'INSERT INTO fredpd_roles (discord_role_id, name, position, deleted) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE name = VALUES(name), position = VALUES(position), deleted = VALUES(deleted), updated_at = UTC_TIMESTAMP()',
    [id, name, position, deleted ? 1 : 0],
  );
  for (const [type, key, effect] of grants) {
    await database.pool.query('INSERT INTO fredpd_role_grants (discord_role_id, grant_type, grant_key, effect) VALUES (?, ?, ?, ?)', [id, type, key, effect]);
  }
}

// ---------------------------------------------------------------------------------------------------------------
// App + requests

export interface TestApp {
  app: FastifyInstance;
  gateway: FakeGateway;
  fx: FakeFx;
  oauth: FakeOAuth;
  clock: ReturnType<typeof fixedClock>;
  config: Config;
}

/** config/units.json order the test apps run with (the admin catalog lists these units first). */
export const TEST_UNIT_ORDER = ['ledning', 'span', 'utredning', 'tekniker', 'igv'];

/**
 * buildApp with fakes. Without a database, a lazy pool to a closed port stands in: routes that never query work,
 * anything that does fails loudly.
 */
export async function makeApp(opts: { database?: Database | null; config?: Config; deps?: Partial<AppDeps> } = {}): Promise<TestApp> {
  const gateway = new FakeGateway();
  const fx = new FakeFx();
  const oauth = new FakeOAuth();
  const clock = fixedClock();
  const config = opts.config ?? testConfig();
  const db: Db = opts.database?.db ?? createDatabase('mysql://nobody:none@127.0.0.1:9/none', { connectionLimit: 1 }).db;
  const app = await buildApp({ config, db, gateway, fx, clock, oauth, log: silentLogger, logger: false, unitOrder: TEST_UNIT_ORDER, ...opts.deps });
  await app.ready();
  return { app, gateway, fx, oauth, clock, config };
}

/**
 * Inject with §C5 headers signed over the exact body text. By default from 127.0.0.1 without proxy headers, like
 * FXServer on the same host; `remoteAddress` / `headers` simulate a request through a proxy or from elsewhere.
 */
export function signedInject(
  t: TestApp,
  opts: { method: 'GET' | 'POST'; url: string; body?: unknown; secret?: string; ts?: number; rawBody?: string; remoteAddress?: string; headers?: Record<string, string> },
) {
  const raw = opts.rawBody ?? (opts.body === undefined ? '' : JSON.stringify(opts.body));
  const now = opts.ts ?? Math.floor(t.clock.now().getTime() / 1000);
  const headers: Record<string, string> = { ...opts.headers, ...signedHeaders(opts.secret ?? HMAC_SECRET, raw, now) };
  const inject: InjectOptions = { method: opts.method, url: opts.url, headers, remoteAddress: opts.remoteAddress ?? '127.0.0.1' };
  if (opts.method === 'POST') {
    headers['content-type'] = 'application/json';
    inject.payload = raw;
  }
  return t.app.inject(inject);
}

/** A logged-in session for a Discord id: the cookie header value and the CSRF token. */
export async function loginAs(t: TestApp, database: Database, discordId: string): Promise<{ cookie: string; csrf: string }> {
  const { token, session } = await createSession(database.db, discordId, t.clock.now());
  return { cookie: `${SESSION_COOKIE}=${t.app.signCookie(token)}`, csrf: session.csrfToken };
}

/** 1×1 transparent PNG. */
export const PNG_1X1 = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  'base64',
);

/** multipart/form-data body with one file field, built by the platform's FormData encoder. */
export async function multipartBody(field: string, file: Buffer, filename: string, type: string): Promise<{ payload: Buffer; contentType: string }> {
  const form = new FormData();
  form.append(field, new Blob([new Uint8Array(file)], { type }), filename);
  const req = new Request('http://localhost/upload', { method: 'POST', body: form });
  return { payload: Buffer.from(await req.arrayBuffer()), contentType: req.headers.get('content-type') ?? '' };
}
