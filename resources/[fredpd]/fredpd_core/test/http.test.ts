// SPDX-License-Identifier: GPL-3.0-only
// Tests for fredpd_core/server/http.js. The file is a FiveM server script (CommonJS, FiveM globals), so it is run in
// a vm context with mocked globals (SetHttpHandler, GetConvar, exports, ...), the way FXServer evaluates it.
// HMAC vectors come from packages/types/test/fixtures/hmac.fixtures.json (shared with packages/types/src/hmac.ts).
import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { createHmac } from 'node:crypto';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { describe, expect, it, vi } from 'vitest';

const here = dirname(fileURLToPath(import.meta.url));
const HTTP_JS = join(here, '..', 'server', 'http.js');
const REPO = resolve(here, '..', '..', '..', '..');

interface HmacVector { name: string; ts: string; rawBody: string; now: number; sig: string; ok: boolean; reason?: string }
const fixtures = JSON.parse(
  readFileSync(join(REPO, 'packages', 'types', 'test', 'fixtures', 'hmac.fixtures.json'), 'utf8'),
) as { secret: string; vectors: HmacVector[] };
const SECRET = fixtures.secret;

type Fn = (...args: unknown[]) => unknown;
type VerifyResult = { ok: true } | { ok: false; reason: string };
interface FakeRes { writeHead(status: number, headers?: Record<string, string>): void; send(body: string): void; write(chunk: string): void }
interface FakeReq {
  method: string; path: string; address: string; headers: Record<string, string>;
  setDataHandler(cb: (body: string) => void): void; setCancelHandler(cb: () => void): void;
}
type Handler = (req: FakeReq, res: FakeRes) => void;
type SignedFetch = (method: string, path: string, body: unknown, cb: (status: number, text: string) => void) => void;
interface HandlerDeps { secret: string | null; now(): number; callLua: Fn; emitEvent?: Fn; playerCount(): number; log(level: string, msg: string): void }
interface HttpApi {
  MAX_BODY_BYTES: number;
  MAX_RESPONSE_BYTES: number;
  REJECT_LOG_INTERVAL_S: number;
  RULES_CHANGED_EVENT: string;
  secretProblem(secret: unknown): string | null;
  signBody(secret: string, ts: string | number, rawBody: string): string;
  verifySignature(o: { secret: string; ts: string; sig: string; rawBody: string; nowSeconds: number }): VerifyResult;
  createHandler(deps: HandlerDeps): Handler;
  createSignedFetch(deps: { secret: string | null; baseUrl: string; now(): number; fetch?: Fn; timeoutMs?: number; log(level: string, msg: string): void; invoker?: () => string | null }): SignedFetch;
}

interface Loaded {
  api: HttpApi;
  handler: Handler | undefined;
  registered: Record<string, Fn>;
  lua: { applyGrants: ReturnType<typeof vi.fn>; recomputeGrants: ReturnType<typeof vi.fn>; setOfficerIdentity: ReturnType<typeof vi.fn> };
  /** The FiveM `emit` global (server-local TriggerEvent). */
  emit: ReturnType<typeof vi.fn>;
  logs: string[];
}

/** Evaluate http.js like FXServer would, with mocked FiveM globals. */
function load(opts: { secret?: string; serviceUrl?: string; fetch?: Fn } = {}): Loaded {
  const handlers: Handler[] = [];
  const registered: Record<string, Fn> = {};
  const lua = {
    applyGrants: vi.fn((): unknown => 1),
    recomputeGrants: vi.fn((): unknown => 2),
    setOfficerIdentity: vi.fn((): unknown => 1),
  };
  const exportsFn = Object.assign((name: string, fn: Fn) => { registered[name] = fn; }, { fredpd_core: lua });
  const emit = vi.fn((..._args: unknown[]): unknown => undefined);
  const logs: string[] = [];
  const convars: Record<string, string> = {
    fredpd_hmac_secret: opts.secret ?? SECRET,
    fredpd_service_url: opts.serviceUrl ?? 'http://127.0.0.1:3000/',
  };
  const push = (level: string) => (msg: string) => { logs.push(`${level} ${msg}`); };
  const sandbox = {
    require: createRequire(HTTP_JS),
    module: { exports: {} as unknown },
    Buffer, URL, AbortController, setTimeout, clearTimeout,
    console: { log: push('info'), warn: push('warn'), error: push('error') },
    SetHttpHandler: (h: Handler) => { handlers.push(h); },
    GetConvar: (name: string, def: string) => convars[name] ?? def,
    GetCurrentResourceName: () => 'fredpd_core',
    GetNumPlayerIndices: () => 7,
    exports: exportsFn,
    emit,
    fetch: opts.fetch,
  };
  vm.runInNewContext(readFileSync(HTTP_JS, 'utf8'), sandbox, { filename: HTTP_JS });
  return { api: sandbox.module.exports as HttpApi, handler: handlers[0], registered, lua, emit, logs };
}

interface Reply { status: number; headers: Record<string, string>; json: Record<string, unknown>; dataHandlerUsed: boolean }

/** Drive a handler with a fake FiveM request; resolves when res.send is called. */
function request(handler: Handler, o: { method?: string; path: string; body?: string; headers?: Record<string, string> }): Promise<Reply> {
  return new Promise((resolvePromise) => {
    let status = 0;
    let headers: Record<string, string> = {};
    let dataHandlerUsed = false;
    const res: FakeRes = {
      writeHead(s, h) { status = s; headers = h ?? {}; },
      write() { throw new Error('http.js should use send()'); },
      send(body) { resolvePromise({ status, headers, json: JSON.parse(body) as Record<string, unknown>, dataHandlerUsed }); },
    };
    const req: FakeReq = {
      method: o.method ?? 'POST', path: o.path, address: '127.0.0.1:50000', headers: o.headers ?? {},
      setDataHandler(cb) { dataHandlerUsed = true; setImmediate(() => cb(o.body ?? '')); },
      setCancelHandler() {},
    };
    handler(req, res);
  });
}

const nowSeconds = () => Math.floor(Date.now() / 1000);
/** Narrow an optional value (noUncheckedIndexedAccess) and fail the test clearly when it is missing. */
function must<T>(v: T | undefined, what = 'value'): T {
  if (v === undefined) throw new Error(`missing ${what}`);
  return v;
}
const sign = (rawBody: string, ts: number = nowSeconds(), secret = SECRET) => ({
  'X-FredPD-Ts': String(ts),
  'X-FredPD-Sig': createHmac('sha256', secret).update(`${ts}.${rawBody}`, 'utf8').digest('hex'),
});
function signed(handler: Handler, method: string, path: string, bodyObj?: unknown, extra: Record<string, string> = {}) {
  const body = bodyObj === undefined ? '' : typeof bodyObj === 'string' ? bodyObj : JSON.stringify(bodyObj);
  return request(handler, { method, path, body, headers: { ...sign(body), ...extra } });
}

const GRANTS = {
  grants: ['mdt_page:search', 'unit:igv', 'weapon:*'], denied: ['weapon:rifle'], tier: 1, units: ['igv'],
  rank: { roleId: '222', key: 'inspektor' }, computedAt: '2026-09-29T12:00:00.000Z',
};
const DISCORD = '123456789012345678';

describe('http.js HMAC (hmac.fixtures.json)', () => {
  const { api } = load();
  for (const v of fixtures.vectors) {
    it(`verifySignature: ${v.name}`, () => {
      const r = api.verifySignature({ secret: SECRET, ts: v.ts, sig: v.sig, rawBody: v.rawBody, nowSeconds: v.now });
      expect(r.ok).toBe(v.ok);
      if (!r.ok) expect(r.reason).toBe(v.reason);
      if (v.ok) expect(api.signBody(SECRET, v.ts, v.rawBody)).toBe(v.sig.toLowerCase());
    });

    it(`handler: ${v.name} -> ${v.ok ? 'accepted' : '401'}`, async () => {
      const handle = api.createHandler({
        secret: SECRET, now: () => v.now, callLua: () => 1, playerCount: () => 0, log: () => {},
      });
      const reply = await request(handle, {
        method: 'POST', path: '/recompute', body: v.rawBody, headers: { 'x-fredpd-ts': v.ts, 'x-fredpd-sig': v.sig },
      });
      if (v.ok) expect(reply.status).not.toBe(401);
      else expect(reply).toMatchObject({ status: 401, json: { error: 'unauthorized' } });
    });
  }
});

describe('http.js routes (SetHttpHandler)', () => {
  it('registers exactly one handler and the signedFetch export', () => {
    const { handler, registered } = load();
    expect(typeof handler).toBe('function');
    expect(typeof registered.signedFetch).toBe('function');
  });

  it('GET /ping answers without reading a body', async () => {
    const { handler } = load();
    const reply = await signed(handler!, 'GET', '/ping');
    expect(reply).toMatchObject({ status: 200, json: { ok: true, players: 7 }, dataHandlerUsed: false });
  });

  it('POST /grants calls applyGrants(discordId, grants)', async () => {
    const { handler, lua, logs } = load();
    const reply = await signed(handler!, 'POST', '/grants', { discordId: DISCORD, grants: GRANTS });
    expect(reply).toMatchObject({ status: 200, json: { ok: true, applied: 1 } });
    expect(logs).toContain(`info [fredpd_core:http] grants pushed for discord ${DISCORD}: 3 grant(s), applied to 1 player(s)`);
    expect(lua.applyGrants).toHaveBeenCalledTimes(1);
    const [id, set] = lua.applyGrants.mock.calls[0] as unknown[];
    expect(id).toBe(DISCORD);
    expect(JSON.parse(JSON.stringify(set))).toEqual(GRANTS);
  });

  it('POST /grants with rank null is accepted', async () => {
    const { handler, lua } = load();
    const reply = await signed(handler!, 'POST', '/grants', { discordId: DISCORD, grants: { ...GRANTS, rank: null } });
    expect(reply.status).toBe(200);
    expect(lua.applyGrants).toHaveBeenCalledTimes(1);
  });

  it('header names are case-insensitive', async () => {
    const { handler } = load();
    const h = sign('');
    const reply = await request(handler!, {
      method: 'GET', path: '/ping', headers: { 'x-fredpd-ts': h['X-FredPD-Ts'], 'X-FREDPD-SIG': h['X-FredPD-Sig'] },
    });
    expect(reply.status).toBe(200);
  });

  it('bad signature -> 401 and Lua is not called', async () => {
    const { handler, lua, logs } = load();
    const body = JSON.stringify({ discordId: DISCORD, grants: GRANTS });
    const headers = sign(body, nowSeconds(), 'another-secret-that-is-long-enough-0000');
    const reply = await request(handler!, { method: 'POST', path: '/grants', body, headers });
    expect(reply).toMatchObject({ status: 401, json: { error: 'unauthorized' } });
    expect(lua.applyGrants).not.toHaveBeenCalled();
    expect(logs.some((l) => l.startsWith('warn') && l.includes('signature'))).toBe(true);
  });

  it('stale timestamp -> 401', async () => {
    const { handler, lua } = load();
    const body = JSON.stringify({ discordId: DISCORD, grants: GRANTS });
    const reply = await request(handler!, { method: 'POST', path: '/grants', body, headers: sign(body, nowSeconds() - 120) });
    expect(reply).toMatchObject({ status: 401, json: { error: 'unauthorized' } });
    expect(lua.applyGrants).not.toHaveBeenCalled();
  });

  it('missing signature headers -> 401', async () => {
    const { handler } = load();
    const reply = await request(handler!, { method: 'GET', path: '/ping' });
    expect(reply).toMatchObject({ status: 401, json: { error: 'unauthorized' } });
  });

  it('a repeated request gets the first answer again without re-running Lua (no 401)', async () => {
    const { handler, lua } = load();
    const body = JSON.stringify({ discordId: DISCORD, grants: GRANTS });
    const headers = sign(body);
    const first = await request(handler!, { method: 'POST', path: '/grants', body, headers });
    expect(first).toMatchObject({ status: 200, json: { ok: true, applied: 1 } });
    expect(first.headers['X-FredPD-Duplicate']).toBeUndefined();
    lua.applyGrants.mockReturnValue(5); // would change the answer if Lua ran again
    const again = await request(handler!, { method: 'POST', path: '/grants', body, headers });
    expect(again).toMatchObject({ status: 200, json: { ok: true, applied: 1 }, headers: { 'X-FredPD-Duplicate': '1' } });
    expect(lua.applyGrants).toHaveBeenCalledTimes(1);
  });

  it('an identical POST /officer is memoised like /grants', async () => {
    const { handler, lua } = load();
    const body = JSON.stringify({ discordId: DISCORD, displayName: 'Anna', avatarUrl: null });
    const headers = sign(body);
    expect((await request(handler!, { method: 'POST', path: '/officer', body, headers })).status).toBe(200);
    const again = await request(handler!, { method: 'POST', path: '/officer', body, headers });
    expect(again).toMatchObject({ status: 200, headers: { 'X-FredPD-Duplicate': '1' } });
    expect(lua.setOfficerIdentity).toHaveBeenCalledTimes(1);
  });

  it('two identical GET /ping in the same second both run (no memo)', async () => {
    let players = 7;
    const { api } = load();
    const handle = api.createHandler({ secret: SECRET, now: nowSeconds, callLua: () => 1, playerCount: () => players, log: () => {} });
    const headers = sign('');
    expect((await request(handle, { method: 'GET', path: '/ping', headers })).json).toEqual({ ok: true, players: 7 });
    players = 8;
    const again = await request(handle, { method: 'GET', path: '/ping', headers });
    expect(again).toMatchObject({ status: 200, json: { ok: true, players: 8 } });
    expect(again.headers['X-FredPD-Duplicate']).toBeUndefined();
  });

  it('two identical signed POST /recompute in the same second both call recomputeGrants', async () => {
    const { handler, lua } = load();
    for (const bodyObj of [{ discordIds: [DISCORD] }, {}]) {
      lua.recomputeGrants.mockClear();
      const body = JSON.stringify(bodyObj);
      const headers = sign(body);
      const first = await request(handler!, { method: 'POST', path: '/recompute', body, headers });
      const second = await request(handler!, { method: 'POST', path: '/recompute', body, headers });
      expect(first).toMatchObject({ status: 200, json: { ok: true, scheduled: 2 } });
      expect(second).toMatchObject({ status: 200, json: { ok: true, scheduled: 2 } });
      expect(second.headers['X-FredPD-Duplicate']).toBeUndefined();
      expect(lua.recomputeGrants).toHaveBeenCalledTimes(2);
    }
  });

  it('a GET /ping signature (empty body) is not accepted by POST /recompute', async () => {
    const { handler, lua } = load();
    const headers = sign('');
    expect((await request(handler!, { method: 'GET', path: '/ping', headers })).status).toBe(200);
    const reused = await request(handler!, { method: 'POST', path: '/recompute', headers });
    expect(reused).toMatchObject({ status: 400, json: { error: 'bad_json' } });
    expect(lua.recomputeGrants).not.toHaveBeenCalled();
  });

  it('5xx answers are not remembered: a retry of the same signed /grants runs again', async () => {
    const { handler, lua } = load();
    const body = JSON.stringify({ discordId: DISCORD, grants: GRANTS });
    const h = sign(body);
    lua.applyGrants.mockImplementationOnce(() => { throw new Error('transient'); });
    expect((await request(handler!, { method: 'POST', path: '/grants', body, headers: h })).status).toBe(500);
    expect((await request(handler!, { method: 'POST', path: '/grants', body, headers: h })).status).toBe(200);
    expect(lua.applyGrants).toHaveBeenCalledTimes(2);
  });

  it('rejections are logged at most once per interval, with a count of the suppressed ones', async () => {
    const { api } = load();
    const logs: string[] = [];
    let now = 1_800_000_000;
    const handle = api.createHandler({ secret: SECRET, now: () => now, callLua: () => 1, playerCount: () => 0, log: (l, m) => { logs.push(`${l} ${m}`); } });
    const bad = { 'x-fredpd-ts': String(now), 'x-fredpd-sig': 'ab'.repeat(32) };
    for (let i = 0; i < 5; i++) expect((await request(handle, { method: 'GET', path: '/ping', headers: bad })).status).toBe(401);
    expect(logs).toHaveLength(1);
    now += api.REJECT_LOG_INTERVAL_S;
    await request(handle, { method: 'GET', path: '/ping', headers: { ...bad, 'x-fredpd-ts': String(now) } });
    expect(logs).toHaveLength(2);
    expect(logs[1]).toContain('4 more rejected');
  });

  it('invalid JSON with a valid signature -> 400 bad_json', async () => {
    const { handler, lua } = load();
    const reply = await signed(handler!, 'POST', '/grants', '{"discordId": ');
    expect(reply).toMatchObject({ status: 400, json: { error: 'bad_json' } });
    expect(lua.applyGrants).not.toHaveBeenCalled();
  });

  it('JSON that is not an object -> 400 bad_json', async () => {
    const { handler } = load();
    expect((await signed(handler!, 'POST', '/recompute', '[1,2]')).json).toEqual({ error: 'bad_json' });
    expect((await signed(handler!, 'POST', '/recompute', 'null')).json).toEqual({ error: 'bad_json' });
  });

  it('oversize body -> 413 (checked before the signature)', async () => {
    const { handler, lua, api } = load();
    const big = JSON.stringify({ discordId: DISCORD, pad: 'x'.repeat(api.MAX_BODY_BYTES) });
    const reply = await signed(handler!, 'POST', '/grants', big);
    expect(reply).toMatchObject({ status: 413, json: { error: 'payload_too_large' } });
    const unsigned = await request(handler!, { method: 'POST', path: '/grants', body: big });
    expect(unsigned.status).toBe(413);
    expect(lua.applyGrants).not.toHaveBeenCalled();
  });

  it('oversize Content-Length -> 413 without reading the body', async () => {
    const { handler } = load();
    const reply = await request(handler!, { method: 'POST', path: '/grants', headers: { 'Content-Length': String(64 * 1024 + 1) } });
    expect(reply).toMatchObject({ status: 413, dataHandlerUsed: false });
  });

  it('exactly 64 KB is accepted', async () => {
    const { handler, api, lua } = load();
    const body = '{' + ' '.repeat(api.MAX_BODY_BYTES - 2) + '}'; // JSON whitespace: parses as {}
    expect(Buffer.byteLength(body)).toBe(api.MAX_BODY_BYTES);
    expect((await signed(handler!, 'POST', '/recompute', body)).status).toBe(200);
    expect(lua.recomputeGrants).toHaveBeenCalledWith(null);
  });

  it('unknown path -> 404, wrong method -> 405 with Allow', async () => {
    const { handler } = load();
    expect((await signed(handler!, 'GET', '/nope')).status).toBe(404);
    const reply = await signed(handler!, 'GET', '/grants');
    expect(reply).toMatchObject({ status: 405, json: { error: 'method_not_allowed' }, headers: { Allow: 'POST' } });
    expect((await signed(handler!, 'POST', '/ping', {})).status).toBe(405);
  });

  it('path query string and trailing slash are ignored', async () => {
    const { handler } = load();
    expect((await signed(handler!, 'GET', '/ping/?x=1')).status).toBe(200);
  });

  it('POST /grants with a malformed GrantSet -> 400, Lua not called', async () => {
    const { handler, lua } = load();
    const bad = [
      { discordId: 'abc', grants: GRANTS },
      { discordId: DISCORD },
      { discordId: DISCORD, grants: { ...GRANTS, tier: 3 } },
      { discordId: DISCORD, grants: { ...GRANTS, grants: ['no-colon'] } },
      { discordId: DISCORD, grants: { ...GRANTS, units: 'igv' } },
      { discordId: DISCORD, grants: { ...GRANTS, rank: 'x' } },
    ];
    for (const b of bad) {
      const reply = await signed(handler!, 'POST', '/grants', b);
      expect(reply.status, JSON.stringify(b)).toBe(400);
      expect(reply.json.error).toBe('invalid_body');
    }
    expect(lua.applyGrants).not.toHaveBeenCalled();
  });

  it('applyGrants returning false -> 400', async () => {
    const { handler, lua } = load();
    lua.applyGrants.mockReturnValueOnce(false);
    const reply = await signed(handler!, 'POST', '/grants', { discordId: DISCORD, grants: GRANTS });
    expect(reply).toMatchObject({ status: 400, json: { error: 'invalid_body' } });
  });

  it('a Lua error -> 500 internal', async () => {
    const { handler, lua, logs } = load();
    lua.applyGrants.mockImplementationOnce(() => { throw new Error('boom'); });
    const reply = await signed(handler!, 'POST', '/grants', { discordId: DISCORD, grants: GRANTS });
    expect(reply).toMatchObject({ status: 500, json: { error: 'internal' } });
    expect(logs.some((l) => l.startsWith('error') && l.includes('boom'))).toBe(true);
  });

  it('POST /recompute passes the ids, or null for everyone ({})', async () => {
    const { handler, lua, logs } = load();
    expect((await signed(handler!, 'POST', '/recompute', { discordIds: [DISCORD, '42'] })).json).toEqual({ ok: true, scheduled: 2 });
    expect(lua.recomputeGrants).toHaveBeenLastCalledWith([DISCORD, '42']);
    expect(logs).toContain('info [fredpd_core:http] grant recompute for 2 discord id(s): 2 player(s) re-fetching');
    await signed(handler!, 'POST', '/recompute', {});
    expect(lua.recomputeGrants).toHaveBeenLastCalledWith(null);
    expect(logs).toContain('info [fredpd_core:http] grant recompute for everyone online: 2 player(s) re-fetching');
    await signed(handler!, 'POST', '/recompute', { discordIds: null });
    expect(lua.recomputeGrants).toHaveBeenLastCalledWith(null);
    expect((await signed(handler!, 'POST', '/recompute', { discordIds: ['x'] })).status).toBe(400);
    expect(lua.recomputeGrants).toHaveBeenCalledTimes(3);
  });

  it('POST /recompute needs a JSON object body with no key but discordIds', async () => {
    const { handler, lua } = load();
    expect((await signed(handler!, 'POST', '/recompute')).json).toEqual({ error: 'bad_json' });
    const extra = await signed(handler!, 'POST', '/recompute', { discordIds: [DISCORD], all: true });
    expect(extra).toMatchObject({ status: 400, json: { error: 'invalid_body', detail: 'unknown key all' } });
    // Bodies signed for the other routes are refused here too (§C5 does not sign the path).
    expect((await signed(handler!, 'POST', '/recompute', { discordId: DISCORD, grants: GRANTS })).status).toBe(400);
    expect((await signed(handler!, 'POST', '/recompute', { discordId: DISCORD, displayName: 'A', avatarUrl: null })).status).toBe(400);
    expect(lua.recomputeGrants).not.toHaveBeenCalled();
  });

  it('POST /officer calls setOfficerIdentity with a trimmed name', async () => {
    const { handler, lua, logs } = load();
    const reply = await signed(handler!, 'POST', '/officer', { discordId: DISCORD, displayName: '  Anna B. ', avatarUrl: null });
    expect(reply).toMatchObject({ status: 200, json: { ok: true, updated: 1 } });
    expect(lua.setOfficerIdentity).toHaveBeenCalledWith(DISCORD, 'Anna B.', null);
    expect(logs).toContain(`info [fredpd_core:http] officer name for discord ${DISCORD} is now "Anna B." (1 officer character(s))`);
    await signed(handler!, 'POST', '/officer', { discordId: DISCORD, displayName: 'Erik', avatarUrl: 'http://x/a.png' });
    expect(lua.setOfficerIdentity).toHaveBeenLastCalledWith(DISCORD, 'Erik', 'http://x/a.png');
    expect((await signed(handler!, 'POST', '/officer', { discordId: DISCORD, displayName: ' ' })).status).toBe(400);
    expect((await signed(handler!, 'POST', '/officer', { discordId: DISCORD, displayName: 'x'.repeat(101) })).status).toBe(400);
    expect((await signed(handler!, 'POST', '/officer', { discordId: DISCORD, displayName: 'A', avatarUrl: 5 })).status).toBe(400);
  });

  it('POST /officer counts characters, not UTF-16 units, and maps a Lua rejection to 400', async () => {
    const { handler, lua } = load();
    const emoji = '\u{1F46E}'; // 2 UTF-16 units, 4 UTF-8 bytes, 1 character
    expect((await signed(handler!, 'POST', '/officer', { discordId: DISCORD, displayName: emoji.repeat(100) })).status).toBe(200);
    expect((await signed(handler!, 'POST', '/officer', { discordId: DISCORD, displayName: emoji.repeat(101) })).status).toBe(400);
    lua.setOfficerIdentity.mockReturnValueOnce(false);
    const reply = await signed(handler!, 'POST', '/officer', { discordId: DISCORD, displayName: 'Anna' });
    expect(reply).toMatchObject({ status: 400, json: { error: 'invalid_body' } });
  });
});

describe('http.js POST /rules (§C6)', () => {
  it('a signed {} emits fredpd:rulesChanged once (server-local emit) and answers { ok: true }', async () => {
    const { handler, emit, lua, api, logs } = load();
    const reply = await signed(handler!, 'POST', '/rules', {});
    expect(reply).toMatchObject({ status: 200, json: { ok: true } });
    expect(reply.json).toEqual({ ok: true });
    expect(logs).toContain('info [fredpd_core:http] visibility rules changed: reloading');
    expect(api.RULES_CHANGED_EVENT).toBe('fredpd:rulesChanged');
    expect(emit).toHaveBeenCalledTimes(1);
    expect(emit).toHaveBeenCalledWith('fredpd:rulesChanged');
    // Nothing else is touched: no grants, no recompute.
    expect(lua.applyGrants).not.toHaveBeenCalled();
    expect(lua.recomputeGrants).not.toHaveBeenCalled();
  });

  it('the body must be exactly {}: empty or non-object -> 400 bad_json, any key -> 400 invalid_body', async () => {
    const { handler, emit } = load();
    expect((await signed(handler!, 'POST', '/rules')).json).toEqual({ error: 'bad_json' });
    expect((await signed(handler!, 'POST', '/rules', '[]')).json).toEqual({ error: 'bad_json' });
    expect((await signed(handler!, 'POST', '/rules', 'null')).json).toEqual({ error: 'bad_json' });
    expect((await signed(handler!, 'POST', '/rules', '"{}"')).json).toEqual({ error: 'bad_json' });
    expect(await signed(handler!, 'POST', '/rules', { reload: true })).toMatchObject({ status: 400, json: { error: 'invalid_body', detail: 'unknown key reload' } });
    // Bodies signed for the other routes are refused here too (§C5 does not sign the path).
    for (const b of [{ discordIds: [DISCORD] }, { discordIds: null }, { discordId: DISCORD, grants: GRANTS }, { discordId: DISCORD, displayName: 'A', avatarUrl: null }]) {
      const reply = await signed(handler!, 'POST', '/rules', b);
      expect(reply.status, JSON.stringify(b)).toBe(400);
      expect(reply.json.error).toBe('invalid_body');
    }
    expect(emit).not.toHaveBeenCalled();
  });

  it('whitespace around {} is still the empty object', async () => {
    const { handler, emit } = load();
    expect((await signed(handler!, 'POST', '/rules', ' { } ')).status).toBe(200);
    expect(emit).toHaveBeenCalledTimes(1);
  });

  it('unsigned, badly signed or stale -> 401 and nothing is emitted', async () => {
    const { handler, emit } = load();
    expect((await request(handler!, { method: 'POST', path: '/rules', body: '{}' })).status).toBe(401);
    const forged = sign('{}', nowSeconds(), 'another-secret-that-is-long-enough-0000');
    expect((await request(handler!, { method: 'POST', path: '/rules', body: '{}', headers: forged })).status).toBe(401);
    expect((await request(handler!, { method: 'POST', path: '/rules', body: '{}', headers: sign('{}', nowSeconds() - 120) })).status).toBe(401);
    expect(emit).not.toHaveBeenCalled();
  });

  it('GET /rules -> 405 with Allow: POST; a GET /ping signature reused on /rules -> 400', async () => {
    const { handler, emit } = load();
    expect(await signed(handler!, 'GET', '/rules')).toMatchObject({ status: 405, headers: { Allow: 'POST' } });
    const headers = sign('');
    expect((await request(handler!, { method: 'GET', path: '/ping', headers })).status).toBe(200);
    expect(await request(handler!, { method: 'POST', path: '/rules', headers })).toMatchObject({ status: 400, json: { error: 'bad_json' } });
    expect(emit).not.toHaveBeenCalled();
  });

  it('two identical signed /rules in the same second both reload (not memoised)', async () => {
    const { handler, emit } = load();
    const headers = sign('{}');
    const first = await request(handler!, { method: 'POST', path: '/rules', body: '{}', headers });
    const second = await request(handler!, { method: 'POST', path: '/rules', body: '{}', headers });
    expect(first.status).toBe(200);
    expect(second).toMatchObject({ status: 200, json: { ok: true } });
    expect(second.headers['X-FredPD-Duplicate']).toBeUndefined();
    expect(emit).toHaveBeenCalledTimes(2);
  });

  it('an emit that throws -> 500 internal (logged), and a retry runs again', async () => {
    const { handler, emit, logs } = load();
    emit.mockImplementationOnce(() => { throw new Error('no handler runtime'); });
    const headers = sign('{}');
    expect(await request(handler!, { method: 'POST', path: '/rules', body: '{}', headers })).toMatchObject({ status: 500, json: { error: 'internal' } });
    expect(logs.some((l) => l.startsWith('error') && l.includes('no handler runtime'))).toBe(true);
    expect((await request(handler!, { method: 'POST', path: '/rules', body: '{}', headers })).status).toBe(200);
    expect(emit).toHaveBeenCalledTimes(2);
  });

  it('bridge disabled -> 503 and nothing is emitted', async () => {
    const { handler, emit } = load({ secret: 'CHANGE_ME' });
    expect((await request(handler!, { method: 'POST', path: '/rules', body: '{}', headers: sign('{}', nowSeconds(), 'CHANGE_ME') })).status).toBe(503);
    expect(emit).not.toHaveBeenCalled();
  });
});

describe('http.js with a missing, short or placeholder secret', () => {
  it('secretProblem accepts a random secret and refuses placeholders', () => {
    const { api } = load();
    expect(api.secretProblem(SECRET)).toBeNull();
    expect(api.secretProblem('3f9a0c1d2e4b5a6978c0d1e2f3a4b5c6d7e8f90112233445566778899aabbcc')).toBeNull();
    for (const p of ['CHANGE_ME_TO_64_RANDOM_HEX_CHARACTERS_______________________________', 'changeme-changeme-changeme-changeme',
      'please-change-me-before-going-live-now', 'your_secret_here_0000000000000000000', 'x'.repeat(40)]) {
      expect(api.secretProblem(p), p).toMatch(/placeholder/);
    }
  });

  for (const secret of ['', 'too-short-secret', 'CHANGE_ME', 'CHANGE_ME_TO_64_RANDOM_HEX_CHARACTERS_______________________________']) {
    it(`secret ${JSON.stringify(secret)}: bridge disabled with an error log`, async () => {
      const { handler, registered, logs, lua } = load({ secret });
      expect(logs.some((l) => l.startsWith('error') && l.includes('DISABLED'))).toBe(true);
      const reply = await request(handler!, { method: 'POST', path: '/grants', body: '{}', headers: sign('{}', nowSeconds(), secret) });
      expect(reply).toMatchObject({ status: 503, json: { error: 'bridge_disabled' } });
      expect(lua.applyGrants).not.toHaveBeenCalled();
      const cb = vi.fn();
      must(registered.signedFetch)('GET', '/internal/ping', null, cb);
      expect(cb).toHaveBeenCalledWith(0, JSON.stringify({ error: 'bridge_disabled' }));
    });
  }
});

describe('http.js signedFetch', () => {
  interface Call { url: string; init: { method: string; headers: Record<string, string>; body?: string; signal?: AbortSignal } }
  function withFetch(impl: (url: string, init: Call['init']) => Promise<unknown>) {
    const calls: Call[] = [];
    const fetch = vi.fn((url: unknown, init: unknown) => {
      calls.push({ url: url as string, init: init as Call['init'] });
      return impl(url as string, init as Call['init']);
    });
    return { calls, loaded: load({ fetch: fetch as Fn }) };
  }
  const ok = (status: number, text: string) => Promise.resolve({ status, text: () => Promise.resolve(text) });
  const call = (sf: Fn, ...args: unknown[]) =>
    new Promise<[number, string]>((res) => { sf(...args, (s: number, t: string) => res([s, t])); });

  it('GET is signed with an empty body and goes to fredpd_service_url', async () => {
    const { calls, loaded } = withFetch(() => ok(200, '{"member":true}'));
    const [status, text] = await call(must(loaded.registered.signedFetch), 'get', `/internal/grants/${DISCORD}`, null);
    expect([status, text]).toEqual([200, '{"member":true}']);
    expect(must(calls[0]).url).toBe(`http://127.0.0.1:3000/internal/grants/${DISCORD}`);
    expect(must(calls[0]).init.method).toBe('GET');
    expect(must(calls[0]).init.body).toBeUndefined();
    const h = must(calls[0]).init.headers;
    const v = loaded.api.verifySignature({ secret: SECRET, ts: h['x-fredpd-ts'] ?? '', sig: h['x-fredpd-sig'] ?? '', rawBody: '', nowSeconds: nowSeconds() });
    expect(v.ok).toBe(true);
  });

  it('POST sends the JSON body it signed', async () => {
    const { calls, loaded } = withFetch(() => ok(202, ''));
    const body = { type: 'playerJoined', payload: { citizenid: 'ABC123', name: 'Åsa' } };
    expect(await call(must(loaded.registered.signedFetch), 'POST', '/internal/events', body)).toEqual([202, '']);
    const init = must(calls[0]).init;
    expect(init.body).toBe(JSON.stringify(body));
    expect(init.headers['Content-Type']).toBe('application/json');
    const v = loaded.api.verifySignature({ secret: SECRET, ts: init.headers['x-fredpd-ts'] ?? '', sig: init.headers['x-fredpd-sig'] ?? '', rawBody: init.body ?? '', nowSeconds: nowSeconds() });
    expect(v.ok).toBe(true);
  });

  it('network error -> cb(0, network)', async () => {
    const { loaded } = withFetch(() => Promise.reject(new Error('ECONNREFUSED')));
    expect(await call(must(loaded.registered.signedFetch), 'GET', '/internal/ping', null)).toEqual([0, '{"error":"network"}']);
  });

  it('invalid method or path -> cb(0, invalid_request) without fetching', async () => {
    const { calls, loaded } = withFetch(() => ok(200, ''));
    expect(await call(must(loaded.registered.signedFetch), 'TRACE', '/x', null)).toEqual([0, '{"error":"invalid_request"}']);
    expect(await call(must(loaded.registered.signedFetch), 'GET', 'http://evil/x', null)).toEqual([0, '{"error":"invalid_request"}']);
    expect(calls).toHaveLength(0);
  });

  it('only fredpd_* resources may sign requests', async () => {
    const { api } = load();
    let caller: string | null = 'evil_resource';
    const fetch = vi.fn(() => ok(200, '{}'));
    const sf = api.createSignedFetch({ secret: SECRET, baseUrl: 'http://127.0.0.1:1', now: nowSeconds, fetch: fetch as Fn, log: () => {}, invoker: () => caller });
    expect(await call(sf as unknown as Fn, 'POST', '/internal/events', {})).toEqual([0, '{"error":"forbidden"}']);
    expect(fetch).not.toHaveBeenCalled();
    caller = 'fredpd_dispatch';
    expect(await call(sf as unknown as Fn, 'POST', '/internal/events', {})).toEqual([200, '{}']);
    caller = null; // fredpd_core's own runtime
    expect(await call(sf as unknown as Fn, 'GET', '/internal/ping', null)).toEqual([200, '{}']);
  });

  it('only the /internal/ and /upload service paths can be signed', async () => {
    const { calls, loaded } = withFetch(() => ok(200, '{}'));
    const sf = must(loaded.registered.signedFetch);
    for (const path of ['/auth/me', '/api/officers', '/internal/../auth/me', '/internal/%2e%2e/api', '/internalx', '/upload/../api']) {
      expect(await call(sf, 'GET', path, null), path).toEqual([0, '{"error":"forbidden"}']);
    }
    expect(calls).toHaveLength(0);
    expect(await call(sf, 'POST', '/upload', {})).toEqual([200, '{}']);
    expect(await call(sf, 'GET', '/internal/grants/123?x=1', null)).toEqual([200, '{}']);
  });

  it('a response larger than MAX_RESPONSE_BYTES fails with too_large', async () => {
    const { loaded } = withFetch(() => ok(200, 'x'.repeat(loaded.api.MAX_RESPONSE_BYTES + 1)));
    expect(await call(must(loaded.registered.signedFetch), 'GET', '/internal/ping', null)).toEqual([0, '{"error":"too_large"}']);
    const big = new Response('y'.repeat(10), { headers: { 'content-length': String(loaded.api.MAX_RESPONSE_BYTES + 1) } });
    const sf = loaded.api.createSignedFetch({ secret: SECRET, baseUrl: 'http://127.0.0.1:1', now: nowSeconds, fetch: (() => Promise.resolve(big)) as Fn, log: () => {} });
    expect(await call(sf as unknown as Fn, 'GET', '/internal/ping', null)).toEqual([0, '{"error":"too_large"}']);
    const streamed = new Response('z'.repeat(loaded.api.MAX_RESPONSE_BYTES + 10));
    const sf2 = loaded.api.createSignedFetch({ secret: SECRET, baseUrl: 'http://127.0.0.1:1', now: nowSeconds, fetch: (() => Promise.resolve(streamed)) as Fn, log: () => {} });
    expect(await call(sf2 as unknown as Fn, 'GET', '/internal/ping', null)).toEqual([0, '{"error":"too_large"}']);
  });

  it('timeout aborts the request and calls back once', async () => {
    const { api } = load();
    const cb = vi.fn();
    const fetch = vi.fn((_url: unknown, init: unknown) => new Promise((_res, rej) => {
      (init as { signal: AbortSignal }).signal.addEventListener('abort', () => rej(Object.assign(new Error('aborted'), { name: 'AbortError' })));
    }));
    const sf = api.createSignedFetch({ secret: SECRET, baseUrl: 'http://127.0.0.1:1', now: nowSeconds, fetch: fetch as Fn, timeoutMs: 20, log: () => {} });
    sf('GET', '/internal/ping', null, cb);
    await vi.waitFor(() => expect(cb).toHaveBeenCalled());
    await new Promise((r) => setTimeout(r, 30));
    expect(cb).toHaveBeenCalledTimes(1);
    expect(cb).toHaveBeenCalledWith(0, '{"error":"timeout"}');
  });

  it('node:http fallback: a peer that trickles bytes is cut off at the overall deadline', async () => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const server = createServer((_req, res) => {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      const drip = () => { res.write(' '); timer = setTimeout(drip, 20); }; // never ends; each byte resets an idle timer
      drip();
      res.on('close', () => clearTimeout(timer));
    });
    await new Promise<void>((r) => server.listen(0, '127.0.0.1', () => r()));
    try {
      const { api } = load();
      const port = (server.address() as AddressInfo).port;
      const sf = api.createSignedFetch({ secret: SECRET, baseUrl: `http://127.0.0.1:${port}`, now: nowSeconds, fetch: undefined, timeoutMs: 150, log: () => {} });
      const started = Date.now();
      const result = await call(sf as unknown as Fn, 'GET', '/internal/ping', null);
      expect(result).toEqual([0, '{"error":"timeout"}']);
      expect(Date.now() - started).toBeLessThan(1000);
    } finally {
      clearTimeout(timer);
      server.closeAllConnections();
      await new Promise((r) => server.close(r));
    }
  });

  it('falls back to node:http when the runtime has no global fetch', async () => {
    const received: { method?: string; url?: string; headers: Record<string, string | string[] | undefined>; body: string } = { headers: {}, body: '' };
    const server = createServer((req, res) => {
      let body = '';
      req.on('data', (c: Buffer) => { body += c.toString('utf8'); });
      req.on('end', () => {
        Object.assign(received, { method: req.method, url: req.url, headers: req.headers, body });
        res.writeHead(201, { 'Content-Type': 'application/json' });
        res.end('{"ok":true}');
      });
    });
    await new Promise<void>((r) => server.listen(0, '127.0.0.1', () => r()));
    try {
      const port = (server.address() as AddressInfo).port;
      const { registered, api } = load({ serviceUrl: `http://127.0.0.1:${port}` });
      const result = await call(must(registered.signedFetch), 'POST', '/internal/events', { type: 'unitsChanged', payload: {} });
      expect(result).toEqual([201, '{"ok":true}']);
      expect(received.method).toBe('POST');
      expect(received.url).toBe('/internal/events');
      const v = api.verifySignature({
        secret: SECRET, ts: String(received.headers['x-fredpd-ts']), sig: String(received.headers['x-fredpd-sig']),
        rawBody: received.body, nowSeconds: nowSeconds(),
      });
      expect(v.ok).toBe(true);
    } finally {
      await new Promise((r) => server.close(r));
    }
  });
});
