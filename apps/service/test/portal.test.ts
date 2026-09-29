// SPDX-License-Identifier: GPL-3.0-only
// Portal actions bridge (docs/modules/portal-api.md, task 7.1 server side / 7.2 hardening): character list and
// selection (license ownership), POST /api/mdt/:action (session, CSRF on reads too, character, live grants, world
// actions refused, zod input, forwarding to a fake FXServer, error mapping incl. 404 for intel, Lua output shapes,
// rate limit), the share route (JSON vs SPA page), portal hosting and security headers, and one round trip through
// the real fredpd_mdt/server/http.js handler with the real signed FX client.
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import vm from 'node:vm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { z } from 'zod';
import { verifySignature } from '@fredpd/types/hmac';
import { RATE_LIMIT_PER_MINUTE, cspDirectives } from '../src/app';
import { createFxClient, PORTAL_TIMEOUT_MS } from '../src/fx';
import type { FxResult } from '../src/fx';
import { silentLogger } from '../src/log';
import { PORTAL_ACTIONS, TABLET_ACTIONS, isIntelAction, isPortalAction } from '../src/portal/actions';
import { fromLua } from '../src/portal/lua-json';
import { SHARE_TOKEN_RE } from '../src/routes/portal';
import { HMAC_SECRET, ROOT, cleanup, ids, loginAs, makeApp, rows, seedRole, setupTestDb, testConfig } from './helpers';
import type { TestApp } from './helpers';

const PORTAL_LUA = join(ROOT, 'resources', '[fredpd]', 'fredpd_mdt', 'server', 'portal.lua');
const MDT_HTTP_JS = join(ROOT, 'resources', '[fredpd]', 'fredpd_mdt', 'server', 'http.js');

/** The M.ALLOWED list of fredpd_mdt/server/portal.lua (the FXServer's authoritative copy). */
function luaAllowed(): string[] {
  const src = readFileSync(PORTAL_LUA, 'utf8');
  const block = /M\.ALLOWED = \{([\s\S]*?)\n\}/.exec(src);
  if (!block) throw new Error('M.ALLOWED not found in portal.lua');
  return [...block[1]!.matchAll(/'([A-Za-z]+)'/g)].map((m) => m[1]!);
}

// ---------------------------------------------------------------------------------------------------------------
// Pure

describe('portal action list', () => {
  it('equals fredpd_mdt/server/portal.lua M.ALLOWED', () => {
    expect([...PORTAL_ACTIONS].sort()).toEqual(luaAllowed().sort());
  });

  it('is every tablet action except the tablet/world ones', () => {
    const refused = Object.keys(TABLET_ACTIONS).filter((a) => !isPortalAction(a)).sort();
    expect(refused).toEqual(['checkPlate', 'close', 'closeAlert', 'issueFine', 'leaveAlert', 'linkEvidence', 'setTabletRevoked', 'takeAlert']);
    expect(isIntelAction('getSource')).toBe(true);
    expect(isIntelAction('getCase')).toBe(false);
  });
});

describe('fromLua (Lua tables → the zod shape)', () => {
  const Item = z.object({ id: z.number(), note: z.string().nullable(), tag: z.string().nullable().optional() });
  const Schema = z.object({
    items: z.array(Item),
    meta: z.object({ owner: z.string().nullable() }),
    either: z.union([z.object({ kind: z.literal('a'), x: z.string().nullable() }), z.object({ kind: z.literal('b'), y: z.array(z.number()) })]),
  });

  it('restores absent nullable fields and empty containers, and nothing else', () => {
    const out = fromLua(Schema, { items: [{ id: 1 }, { id: 2, note: 'x' }], meta: [], either: { kind: 'b', y: {} } });
    expect(Schema.parse(out)).toEqual({ items: [{ id: 1, note: null }, { id: 2, note: 'x' }], meta: { owner: null }, either: { kind: 'b', y: [] } });
    expect((out as { items: Record<string, unknown>[] }).items[0]).not.toHaveProperty('tag');
  });

  it('turns {} into [] only for an empty list and leaves data it does not understand alone', () => {
    expect(fromLua(Schema, { items: {}, meta: {}, either: { kind: 'a' } })).toEqual({ items: [], meta: { owner: null }, either: { kind: 'a', x: null } });
    expect(fromLua(Schema, { items: { 1: 'x' } })).toMatchObject({ items: { 1: 'x' } });
    expect(fromLua(Schema, 'text')).toBe('text');
  });
});

describe('security headers', () => {
  it('CSP: same origin only, no framing, upgrade only behind HTTPS', () => {
    expect(cspDirectives(true)['frame-ancestors']).toEqual(["'none'"]);
    expect(cspDirectives(true)['upgrade-insecure-requests']).toEqual([]);
    expect(cspDirectives(false)['upgrade-insecure-requests']).toBeNull();
    expect(cspDirectives(true)['script-src']).toEqual(["'self'"]);
  });
});

describe('FX client portal()', () => {
  it('posts the body signed (§C5) to /fredpd_mdt/portal with the portal deadline', async () => {
    const seen: { url: string; headers: Record<string, string>; body: string; signal: AbortSignal | undefined }[] = [];
    const fetchFake = (async (url: string, init: RequestInit) => {
      seen.push({ url, headers: init.headers as Record<string, string>, body: String(init.body), signal: init.signal ?? undefined });
      return new Response(JSON.stringify({ ok: true, data: { x: 1 } }), { status: 200 });
    }) as unknown as typeof fetch;
    const fx = createFxClient({ baseUrl: 'http://127.0.0.1:30120/', secret: HMAC_SECRET, log: silentLogger, fetch: fetchFake });
    const res = await fx.portal({ requestId: 'a'.repeat(32), action: 'getHome', input: {} });
    expect(res).toEqual({ ok: true, status: 200, body: { ok: true, data: { x: 1 } } });
    expect(seen[0]!.url).toBe('http://127.0.0.1:30120/fredpd_mdt/portal');
    const h = seen[0]!.headers;
    expect(verifySignature({ secret: HMAC_SECRET, ts: h['x-fredpd-ts'] ?? null, sig: h['x-fredpd-sig'] ?? null, rawBody: seen[0]!.body })).toEqual({ ok: true });
    expect(PORTAL_TIMEOUT_MS).toBeGreaterThan(15_000);
  });
});

// ---------------------------------------------------------------------------------------------------------------
// Routes (DB)

const database = await setupTestDb('portal.test');
const PREFIX = '771';
const nextId = ids(PREFIX);
const LICENSE = `license:${PREFIX}portaltest`;

function portalDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'fredpd-portal-'));
  writeFileSync(join(dir, 'index.html'), '<!doctype html><title>FredPD</title><div id="root"></div>');
  mkdirSync(join(dir, 'assets'));
  writeFileSync(join(dir, 'assets', 'app-abc123.js'), 'console.log(1)');
  writeFileSync(join(dir, '.env'), 'SECRET=1');
  return dir;
}

describe.skipIf(!database)('portal routes (DB)', () => {
  const db = database!;
  let t: TestApp;
  const user = nextId();
  const other = nextId();
  const roleCases = nextId();
  const roleIntel = nextId();
  const cidA = `T${PREFIX}A01`;
  const cidB = `T${PREFIX}B02`;
  const cidOther = `T${PREFIX}X03`;
  /** A civilian alt on the user's license: no fredpd_officers row (8.3 review: never a portal actor). */
  const cidCivil = `T${PREFIX}L06`;
  /** On the user's license, but the officer row belongs to another Discord user (relinked in game). */
  const cidRelinked = `T${PREFIX}R05`;
  const token = 'Ab_-'.repeat(10) + 'xyz';

  const q = (sql: string, params: unknown[] = []) => db.pool.query(sql, params);

  beforeAll(async () => {
    t = await makeApp({ database: db, config: testConfig({ PORTAL_DIR: portalDir() }) });
    await seedRole(db, roleCases, 'Utredare', 5, [['mdt_page', 'cases', 'allow'], ['mdt_page', 'search', 'allow'], ['mdt_page', 'bolos', 'allow']]);
    await seedRole(db, roleIntel, 'Underrättelse', 6, [['perm', 'intel.read', 'allow']]);
    t.gateway.addMember({ id: user, roleIds: [roleCases] });
    t.gateway.addMember({ id: other, roleIds: [roleCases] });
    await q('INSERT INTO fredpd_identities (discord_id, license, last_citizenid) VALUES (?, ?, ?), (?, ?, ?)', [user, LICENSE, cidA, other, `${LICENSE}-other`, cidOther]);
    await q(
      "INSERT INTO fredpd_persons (citizenid, firstname, lastname, license) VALUES (?, 'Sven', 'Ödman', ?), (?, 'Anna', 'Berg', ?), (?, 'Olle', 'Annan', ?) " +
        'ON DUPLICATE KEY UPDATE license = VALUES(license)',
      [cidA, LICENSE, cidB, LICENSE, cidOther, `${LICENSE}-other`],
    );
    await q(
      "INSERT INTO fredpd_persons (citizenid, firstname, lastname, license) VALUES (?, 'Carl', 'Civil', ?), (?, 'Rut', 'Relänkad', ?) " +
        'ON DUPLICATE KEY UPDATE license = VALUES(license)',
      [cidCivil, LICENSE, cidRelinked, LICENSE],
    );
    await q(
      "INSERT INTO fredpd_officers (citizenid, discord_id, display_name) VALUES (?, ?, 'A'), (?, ?, 'B'), (?, ?, 'X'), (?, ?, 'R') " +
        'ON DUPLICATE KEY UPDATE discord_id = VALUES(discord_id)',
      [cidA, user, cidB, user, cidOther, other, cidRelinked, other],
    );
  });

  afterAll(async () => {
    await t?.app.close();
    await q('DELETE FROM fredpd_persons WHERE citizenid LIKE ?', [`T${PREFIX}%`]);
    await q('DELETE FROM fredpd_officers WHERE citizenid LIKE ?', [`T${PREFIX}%`]);
    await cleanup(db, PREFIX);
    await db.close();
  });

  /** A logged-in user with character A selected. */
  async function withCharacter(discordId = user, citizenid = cidA) {
    const s = await loginAs(t, db, discordId);
    await q('UPDATE fredpd_sessions SET citizenid = ? WHERE discord_id = ?', [citizenid, discordId]);
    return s;
  }

  const mdt = (s: { cookie: string; csrf: string } | null, action: string, body: unknown = {}, csrf = true) =>
    t.app.inject({
      method: 'POST',
      url: `/api/mdt/${action}`,
      headers: { ...(s ? { cookie: s.cookie } : {}), ...(s && csrf ? { 'x-csrf-token': s.csrf } : {}), 'content-type': 'application/json' },
      payload: JSON.stringify(body),
    });

  const portalCalls = () => t.fx.of('portal').map((c) => c.body);
  const answer = (body: Record<string, unknown>, status = 200): FxResult => ({ ok: true, status, body });

  it('GET /api/characters: 401 without a session; only the characters of the linked license, sorted', async () => {
    expect((await t.app.inject({ method: 'GET', url: '/api/characters' })).statusCode).toBe(401);
    const s = await loginAs(t, db, user);
    const res = await t.app.inject({ method: 'GET', url: '/api/characters', headers: { cookie: s.cookie } });
    expect(res.statusCode).toBe(200);
    expect(res.headers['cache-control']).toBe('no-store');
    expect(res.json()).toEqual([
      { citizenid: cidB, name: 'Anna Berg' },
      { citizenid: cidA, name: 'Sven Ödman' },
    ]);
    const lonely = nextId();
    t.gateway.addMember({ id: lonely });
    const s2 = await loginAs(t, db, lonely);
    expect((await t.app.inject({ method: 'GET', url: '/api/characters', headers: { cookie: s2.cookie } })).json()).toEqual([]);
  });

  it('POST /api/session/character: CSRF, ownership, stored in the session and audited', async () => {
    const s = await loginAs(t, db, user);
    const post = (citizenid: string, csrf: string | null = s.csrf) =>
      t.app.inject({
        method: 'POST',
        url: '/api/session/character',
        headers: { cookie: s.cookie, 'content-type': 'application/json', ...(csrf ? { 'x-csrf-token': csrf } : {}) },
        payload: JSON.stringify({ citizenid }),
      });
    expect((await post(cidA, null)).json()).toEqual({ error: 'csrf' });
    expect((await post(cidOther)).statusCode).toBe(403);
    expect((await post('bad id!')).statusCode).toBe(400);
    const ok = await post(cidB);
    expect(ok.json()).toEqual({ ok: true, citizenid: cidB });
    const session = await t.app.inject({ method: 'GET', url: '/api/session', headers: { cookie: s.cookie } });
    expect(session.json().user.citizenid).toBe(cidB);
    const audit = await rows(db, "SELECT actor_citizenid, target_id FROM fredpd_audit WHERE action = 'auth.character' AND actor_discord = ?", [user]);
    expect(audit.at(-1)).toEqual({ actor_citizenid: cidB, target_id: cidB });
  });

  it('a civilian alt (no officer row) or an officer row of another Discord user is never a portal character', async () => {
    const s = await loginAs(t, db, user);
    const listed = (await t.app.inject({ method: 'GET', url: '/api/characters', headers: { cookie: s.cookie } })).json() as { citizenid: string }[];
    expect(listed.map((c) => c.citizenid)).not.toContain(cidCivil);
    expect(listed.map((c) => c.citizenid)).not.toContain(cidRelinked);
    for (const citizenid of [cidCivil, cidRelinked]) {
      const res = await t.app.inject({
        method: 'POST',
        url: '/api/session/character',
        headers: { cookie: s.cookie, 'content-type': 'application/json', 'x-csrf-token': s.csrf },
        payload: JSON.stringify({ citizenid }),
      });
      expect(res.statusCode, citizenid).toBe(403);
    }
    const before = portalCalls().length;
    for (const citizenid of [cidCivil, cidRelinked]) {
      const sc = await withCharacter(user, citizenid);
      const res = await mdt(sc, 'createCase', { title: 'x' });
      expect(res.statusCode, citizenid).toBe(403);
      expect(res.json(), citizenid).toEqual({ error: 'unauthorized', reason: 'no_character' });
    }
    expect(portalCalls().length).toBe(before);
  });

  it('/api/mdt: session (401), CSRF on reads too (403 csrf), character (403 no_character)', async () => {
    const before = portalCalls().length;
    expect((await mdt(null, 'getHome')).statusCode).toBe(401);
    expect((await mdt(null, 'getHome')).json()).toEqual({ error: 'unauthorized', reason: 'session' });
    const s = await loginAs(t, db, user);
    const noCsrf = await mdt(s, 'getHome', {}, false);
    expect(noCsrf.statusCode).toBe(403);
    expect(noCsrf.json()).toEqual({ error: 'csrf' });
    const noChar = await mdt(s, 'getHome');
    expect(noChar.statusCode).toBe(403);
    expect(noChar.json()).toEqual({ error: 'unauthorized', reason: 'no_character' });
    expect(portalCalls().length).toBe(before);
  });

  it('/api/mdt: unknown action 400, world actions 403 reason portal, bad input 400 — none reach FXServer', async () => {
    const s = await withCharacter();
    const before = portalCalls().length;
    expect((await mdt(s, 'dropTables')).json()).toMatchObject({ error: 'validation', reason: 'action' });
    // Not in the registries yet (8.3 review): refused before FXServer, and the portal can tell "not available yet".
    for (const action of ['getPoi', 'createShare', 'listReleaseRequests', 'decideReleaseRequest', 'createReleaseRequest']) {
      const res = await mdt(s, action, {});
      expect(res.statusCode, action).toBe(400);
      expect(res.json(), action).toMatchObject({ error: 'validation', reason: 'action' });
    }
    for (const [action, input] of [['checkPlate', { plate: 'ABC123' }], ['takeAlert', { id: 1 }], ['close', {}], ['issueFine', {}], ['setTabletRevoked', {}]] as const) {
      const res = await mdt(s, action, input);
      expect(res.statusCode, action).toBe(403);
      expect(res.json(), action).toEqual({ error: 'unauthorized', reason: 'portal' });
    }
    const bad = await mdt(s, 'getCase', { id: 'x' });
    expect(bad.statusCode).toBe(400);
    expect(bad.json()).toMatchObject({ error: 'validation', detail: 'id' });
    expect(portalCalls().length).toBe(before);
  });

  it('/api/mdt: forwards the live grants, the session character and the cleaned input (actor never from the body)', async () => {
    const s = await withCharacter();
    t.fx.portalAnswer = () => answer({ ok: true, data: { items: {}, total: 0, page: 1 } });
    const res = await mdt(s, 'listCases', { filter: 'open', query: '  inbrott ', citizenid: 'EVIL', discordId: '1' });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ items: [], total: 0, page: 1 });
    const body = portalCalls().at(-1)!;
    expect(body).toMatchObject({ discordId: user, citizenid: cidA, action: 'listCases', input: { filter: 'open', query: 'inbrott', page: 1 } });
    expect(body.input).not.toHaveProperty('citizenid');
    expect(body.requestId).toMatch(/^[0-9a-f]{32}$/);
    expect((body.grants as { grants: string[] }).grants).toContain('mdt_page:cases');
    await mdt(s, 'listCases', {});
    expect(portalCalls().at(-1)!.requestId).not.toBe(body.requestId);
  });

  it('/api/mdt: a missing grant is 403 without a round trip; intel refusals are always 404', async () => {
    const s = await withCharacter();
    const before = portalCalls().length;
    const noGrant = await mdt(s, 'listEvidence', {});
    expect(noGrant.statusCode).toBe(403);
    expect(noGrant.json()).toEqual({ error: 'unauthorized' });
    const intel = await mdt(s, 'getSource', { id: 1 });
    expect(intel.statusCode).toBe(404);
    expect(intel.json()).toEqual({ error: 'not_found' });
    expect(portalCalls().length).toBe(before);

    t.gateway.addMember({ id: user, roleIds: [roleCases, roleIntel] });
    try {
      t.fx.portalAnswer = () => answer({ ok: false, error: 'unauthorized', reason: 'not_handler' });
      const refused = await mdt(s, 'getSource', { id: 1 });
      expect(refused.statusCode).toBe(404);
      expect(refused.json()).toEqual({ error: 'not_found' });
      t.fx.portalAnswer = () => answer({ ok: false, error: 'not_found' });
      expect((await mdt(s, 'getIntelReport', { id: 2 })).statusCode).toBe(404);
    } finally {
      t.gateway.addMember({ id: user, roleIds: [roleCases] });
    }
  });

  it('/api/mdt: no mdt_page grant at all (the tablet gate) is refused without a round trip, getHome included', async () => {
    const civilian = nextId();
    const cidCiv = `T${PREFIX}C04`;
    t.gateway.addMember({ id: civilian, roleIds: [] });
    await q('INSERT INTO fredpd_identities (discord_id, license, last_citizenid) VALUES (?, ?, ?)', [civilian, `${LICENSE}-civ`, cidCiv]);
    await q("INSERT INTO fredpd_persons (citizenid, firstname, lastname, license) VALUES (?, 'Civil', 'Person', ?)", [cidCiv, `${LICENSE}-civ`]);
    // A police character (officer row) of a Discord user without any grant: the character check passes, the gate refuses.
    await q("INSERT INTO fredpd_officers (citizenid, discord_id, display_name) VALUES (?, ?, 'C')", [cidCiv, civilian]);
    const s = await withCharacter(civilian, cidCiv);
    const before = portalCalls().length;
    for (const action of ['getHome', 'listCharges']) {
      const res = await mdt(s, action, {});
      expect(res.statusCode, action).toBe(403);
      expect(res.json(), action).toEqual({ error: 'unauthorized', reason: 'no_grant' });
    }
    const intel = await mdt(s, 'listSources', {});
    expect(intel.statusCode).toBe(404);
    expect(intel.json()).toEqual({ error: 'not_found' });
    expect(portalCalls().length).toBe(before);
  });

  it('/api/mdt: an intel action without a selected character is 404, never 403', async () => {
    const s = await loginAs(t, db, user);
    await q('UPDATE fredpd_sessions SET citizenid = NULL WHERE discord_id = ?', [user]);
    const before = portalCalls().length;
    const res = await mdt(s, 'getSource', { id: 1 });
    expect(res.statusCode).toBe(404);
    expect(res.json()).toEqual({ error: 'not_found' });
    expect(portalCalls().length).toBe(before);
  });

  it('/api/mdt: FXServer answers map to 400/403/404/429/503 with the reason kept when it looks like one', async () => {
    const s = await withCharacter();
    const cases: [Record<string, unknown>, number, Record<string, unknown>][] = [
      [{ ok: false, error: 'not_found' }, 404, { error: 'not_found' }],
      [{ ok: false, error: 'unauthorized', reason: 'not_lead' }, 403, { error: 'unauthorized', reason: 'not_lead' }],
      [{ ok: false, error: 'unauthorized', reason: 'bad reason!' }, 403, { error: 'unauthorized' }],
      [{ ok: false, error: 'validation' }, 400, { error: 'validation' }],
      [{ ok: false, error: 'rate_limited' }, 429, { error: 'rate_limited' }],
      [{ ok: false, error: 'unavailable' }, 503, { error: 'unavailable' }],
      [{ ok: false, error: 'weird' }, 503, { error: 'unavailable' }],
      [{ nonsense: true }, 503, { error: 'unavailable' }],
    ];
    for (const [fxBody, status, expected] of cases) {
      t.fx.portalAnswer = () => answer(fxBody);
      const res = await mdt(s, 'getCase', { id: 7 });
      expect(res.statusCode, JSON.stringify(fxBody)).toBe(status);
      expect(res.json(), JSON.stringify(fxBody)).toEqual(expected);
    }
    t.fx.portalAnswer = () => ({ ok: false, status: 504, error: 'timeout' });
    expect((await mdt(s, 'getCase', { id: 7 })).json()).toEqual({ error: 'unavailable' });
    t.fx.ok = false;
    try {
      const down = await mdt(s, 'getCase', { id: 7 });
      expect(down.statusCode).toBe(503);
      expect(down.json()).toEqual({ error: 'unavailable' });
    } finally {
      t.fx.ok = true;
    }
  });

  it('/api/mdt: output restored from Lua and parsed; unknown keys stripped; a drifted answer still arrives', async () => {
    const s = await withCharacter();
    t.fx.portalAnswer = () => answer({ ok: true, data: { items: {}, total: 0, page: 1, secret: 'x' } });
    expect((await mdt(s, 'listBolos', {})).json()).toEqual({ items: [], total: 0, page: 1 });
    t.fx.portalAnswer = () => answer({ ok: true, data: { items: {}, total: 'many' } });
    expect((await mdt(s, 'listBolos', {})).json()).toEqual({ items: [], total: 'many' });
  });

  it('/api/mdt: a revoked grant or a character no longer linked is refused on the next call', async () => {
    const s = await withCharacter();
    t.fx.portalAnswer = () => answer({ ok: true, data: { items: [], total: 0, page: 1 } });
    expect((await mdt(s, 'listCases', {})).statusCode).toBe(200);
    t.gateway.addMember({ id: user, roleIds: [] });
    try {
      expect((await mdt(s, 'listCases', {})).statusCode).toBe(403);
    } finally {
      t.gateway.addMember({ id: user, roleIds: [roleCases] });
    }
    await q('UPDATE fredpd_persons SET license = ? WHERE citizenid = ?', ['license:someone-else', cidA]);
    try {
      const res = await mdt(s, 'listCases', {});
      expect(res.statusCode).toBe(403);
      expect(res.json()).toEqual({ error: 'unauthorized', reason: 'no_character' });
      const [row] = await rows<{ citizenid: string | null }>(db, 'SELECT citizenid FROM fredpd_sessions WHERE discord_id = ?', [user]);
      expect(row!.citizenid).toBeNull();
    } finally {
      await q('UPDATE fredpd_persons SET license = ? WHERE citizenid = ?', [LICENSE, cidA]);
    }
  });

  it('/api/mdt: Discord not ready → 503; the 61st call in a minute → 429 rate_limited', async () => {
    const s = await withCharacter(other, cidOther);
    t.gateway.ready = false;
    try {
      expect((await mdt(s, 'listCases', {})).json()).toEqual({ error: 'unavailable' });
    } finally {
      t.gateway.ready = true;
    }
    t.fx.portalAnswer = () => answer({ ok: true, data: { items: [], total: 0, page: 1 } });
    let last = 0;
    // The refused call above counted: 59 more fill the minute.
    for (let i = 1; i < RATE_LIMIT_PER_MINUTE; i += 1) last = (await mdt(s, 'listCases', {})).statusCode;
    expect(last).not.toBe(429);
    const over = await mdt(s, 'listCases', {});
    expect(over.statusCode).toBe(429);
    expect(over.json()).toEqual({ error: 'rate_limited' });
  });

  it('share: JSON for fetch (no session, headers, 404, 503), index.html for a browser', async () => {
    const before = portalCalls().length;
    const json = (url: string) => t.app.inject({ method: 'GET', url, headers: { accept: 'application/json' } });
    t.fx.portalAnswer = (body) =>
      answer((body.input as { token: string }).token === token ? { ok: true, data: { targetType: 'poi', expiresAt: '2026-10-01T10:00:00Z' } } : { ok: false, error: 'not_found' });
    const res = await json(`/share/${token}`);
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ targetType: 'poi', expiresAt: '2026-10-01T10:00:00Z' });
    expect(res.headers['cache-control']).toBe('no-store');
    expect(res.headers['x-robots-tag']).toBe('noindex, nofollow');
    expect(res.headers['referrer-policy']).toBe('no-referrer');
    const body = portalCalls().at(-1)!;
    expect(body).toMatchObject({ action: 'viewShare', input: { token } });
    expect(body).not.toHaveProperty('discordId');
    expect(body).not.toHaveProperty('grants');
    expect((await json(`/api/share/${token}`)).json()).toEqual({ targetType: 'poi', expiresAt: '2026-10-01T10:00:00Z' });
    expect((await json(`/share/${'Z'.repeat(43)}`)).statusCode).toBe(404);
    const calls = portalCalls().length;
    expect((await json('/share/short')).statusCode).toBe(404);
    expect(portalCalls().length).toBe(calls);
    t.fx.ok = false;
    try {
      expect((await json(`/share/${token}`)).statusCode).toBe(503);
    } finally {
      t.fx.ok = true;
    }
    const page = await t.app.inject({ method: 'GET', url: `/share/${token}`, headers: { accept: 'text/html,application/xhtml+xml' } });
    expect(page.statusCode).toBe(200);
    expect(page.headers['content-type']).toContain('text/html');
    expect(page.body).toContain('<div id="root">');
    expect(page.headers['referrer-policy']).toBe('no-referrer');
    expect(portalCalls().length).toBeGreaterThan(before);
    expect(SHARE_TOKEN_RE.test(token)).toBe(true);
  });

  it('share: its own limit of 30 per minute per IP (the 31st answers 429)', async () => {
    t.fx.portalAnswer = () => answer({ ok: true, data: { targetType: 'poi' } });
    const get = () => t.app.inject({ method: 'GET', url: `/api/share/${token}`, remoteAddress: '10.77.1.31', headers: { accept: 'application/json' } });
    for (let i = 0; i < 30; i += 1) expect((await get()).statusCode, `call ${i + 1}`).toBe(200);
    const over = await get();
    expect(over.statusCode).toBe(429);
  });

  it('hosting: SPA routes get index.html, assets are immutable, dotfiles and API paths are not served', async () => {
    const html = { accept: 'text/html' };
    const root = await t.app.inject({ method: 'GET', url: '/', headers: html });
    expect(root.statusCode).toBe(200);
    expect(root.headers['cache-control']).toBe('no-cache');
    expect(root.headers['content-security-policy']).toContain("frame-ancestors 'none'");
    expect(root.headers['x-content-type-options']).toBe('nosniff');
    expect((await t.app.inject({ method: 'GET', url: '/cases/12', headers: html })).body).toContain('id="root"');
    const asset = await t.app.inject({ method: 'GET', url: '/assets/app-abc123.js' });
    expect(asset.statusCode).toBe(200);
    expect(asset.headers['cache-control']).toBe('public, max-age=31536000, immutable');
    expect((await t.app.inject({ method: 'GET', url: '/.env', headers: html })).body).not.toContain('SECRET');
    const api = await t.app.inject({ method: 'GET', url: '/api/nope', headers: html });
    expect(api.statusCode).toBe(404);
    expect(api.json()).toEqual({ error: 'not_found' });
    expect((await t.app.inject({ method: 'GET', url: '/internal/ping', headers: html })).statusCode).not.toBe(200);
  });
});

// ---------------------------------------------------------------------------------------------------------------
// Round trip: the real signed FX client against fredpd_mdt/server/http.js (Lua answered by a fake portalRequest)

interface MdtHttpApi {
  createHandler(deps: {
    secret: string | null;
    now(): number;
    log(level: string, msg: string): void;
    setTimer(fn: () => void, ms: number): unknown;
    clearTimer(h: unknown): void;
    callLua(body: Record<string, unknown>, cb: (status: number, text: string) => void): boolean;
  }): (req: unknown, res: unknown) => void;
}

describe('round trip through fredpd_mdt/server/http.js', () => {
  it('the service signs what the FXServer route verifies; requestId replays are refused', async () => {
    // A FiveM CommonJS script in a "type": "module" repository: evaluate it like FXServer does (no FiveM globals, so
    // it wires nothing and only exports its API).
    const cjs = { exports: {} as unknown };
    vm.runInNewContext(readFileSync(MDT_HTTP_JS, 'utf8'), { module: cjs, require: createRequire(MDT_HTTP_JS), Buffer, console, setTimeout, clearTimeout });
    const mod = cjs.exports as MdtHttpApi;
    const received: Record<string, unknown>[] = [];
    const handle = mod.createHandler({
      secret: HMAC_SECRET,
      now: () => Math.floor(Date.now() / 1000),
      log: () => {},
      setTimer: (fn, ms) => setTimeout(fn, ms),
      clearTimer: (h) => clearTimeout(h as NodeJS.Timeout),
      callLua: (body, cb) => {
        received.push(body);
        setImmediate(() => cb(200, JSON.stringify({ ok: true, data: { echo: body.action } })));
        return true;
      },
    });
    // FXServer's request/response objects over node:http.
    const server = createServer((req, res) => {
      const chunks: Buffer[] = [];
      req.on('data', (c: Buffer) => chunks.push(c));
      req.on('end', () => {
        const fxReq = {
          method: req.method,
          path: String(req.url).replace(/^\/fredpd_mdt/, ''),
          address: `${req.socket.remoteAddress}:${req.socket.remotePort}`,
          headers: req.headers,
          setDataHandler: (cb: (b: string) => void) => cb(Buffer.concat(chunks).toString('utf8')),
          setCancelHandler: () => {},
        };
        const fxRes = {
          writeHead: (status: number, headers: Record<string, string>) => res.writeHead(status, headers),
          send: (text: string) => res.end(text),
        };
        handle(fxReq, fxRes);
      });
    });
    await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
    try {
      const port = (server.address() as AddressInfo).port;
      const fx = createFxClient({ baseUrl: `http://127.0.0.1:${port}`, secret: HMAC_SECRET, log: silentLogger });
      const body = { requestId: 'c'.repeat(32), discordId: '1', citizenid: 'ABC', grants: {}, action: 'getHome', input: {} };
      expect(await fx.portal(body)).toEqual({ ok: true, status: 200, body: { ok: true, data: { echo: 'getHome' } } });
      expect(received[0]).toEqual(body);
      const replay = await fx.portal(body);
      expect(replay).toMatchObject({ ok: false, status: 409 });
      const wrong = createFxClient({ baseUrl: `http://127.0.0.1:${port}`, secret: `${HMAC_SECRET}-wrong`, log: silentLogger });
      expect(await wrong.portal({ ...body, requestId: 'd'.repeat(32) })).toMatchObject({ ok: false, status: 401 });
      expect(received).toHaveLength(1);
    } finally {
      await new Promise<void>((r) => server.close(() => r()));
    }
  });
});
