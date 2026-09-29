// SPDX-License-Identifier: GPL-3.0-only
// Tests for fredpd_mdt/server/http.js (POST /fredpd_mdt/portal, docs/modules/portal-api.md). The file is a FiveM
// server script (CommonJS, FiveM globals), so it runs in a vm context with mocked globals, as FXServer evaluates it.
// HMAC vectors: packages/types/test/fixtures/hmac.fixtures.json (shared with hmac.ts and fredpd_core's http.js).
import { readFileSync } from 'node:fs';
import { createHmac } from 'node:crypto';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { describe, expect, it } from 'vitest';

const here = dirname(fileURLToPath(import.meta.url));
const HTTP_JS = join(here, '..', 'server', 'http.js');
const REPO = resolve(here, '..', '..', '..', '..');

interface HmacVector { name: string; ts: string; rawBody: string; now: number; sig: string; ok: boolean; reason?: string }
const fixtures = JSON.parse(readFileSync(join(REPO, 'packages', 'types', 'test', 'fixtures', 'hmac.fixtures.json'), 'utf8')) as {
  secret: string;
  vectors: HmacVector[];
};
const SECRET = fixtures.secret;

type Cb = (status: number, text: string) => void;
interface FakeReq {
  method: string; path: string; address: string; headers: Record<string, string>;
  setDataHandler(cb: (body: string) => void): void; setCancelHandler(cb: () => void): void;
}
interface FakeRes { writeHead(status: number, headers?: Record<string, string>): void; send(body: string): void }
type Handler = (req: FakeReq, res: FakeRes) => void;
interface Deps {
  secret: string | null; now(): number; log(level: string, msg: string): void;
  setTimer(fn: () => void, ms: number): unknown; clearTimer(h: unknown): void; callLua(body: Record<string, unknown>, cb: Cb): unknown;
}
interface Api {
  PORTAL_PATH: string; MAX_BODY_BYTES: number; LUA_TIMEOUT_MS: number;
  verifySignature(o: { secret: string; ts: string; sig: string; rawBody: string; nowSeconds: number }): { ok: boolean; reason?: string };
  secretProblem(s: unknown): string | null;
  isRemotePeer(a: unknown): boolean;
  createHandler(d: Deps): Handler;
}

function load(opts: { secret?: string } = {}) {
  const handlers: Handler[] = [];
  const lua: { calls: [Record<string, unknown>, Cb][] } = { calls: [] };
  const logs: string[] = [];
  const push = (level: string) => (msg: string) => { logs.push(`${level} ${msg}`); };
  const exportsFn = Object.assign(() => {}, {
    fredpd_mdt: { portalRequest: (body: Record<string, unknown>, cb: Cb) => { lua.calls.push([body, cb]); return true; } },
  });
  const sandbox = {
    require: createRequire(HTTP_JS),
    module: { exports: {} as unknown },
    Buffer, setTimeout, clearTimeout,
    console: { log: push('info'), warn: push('warn'), error: push('error') },
    SetHttpHandler: (h: Handler) => { handlers.push(h); },
    GetConvar: (name: string, def: string) => (name === 'fredpd_hmac_secret' ? opts.secret ?? SECRET : def),
    GetCurrentResourceName: () => 'fredpd_mdt',
    exports: exportsFn,
  };
  vm.runInNewContext(readFileSync(HTTP_JS, 'utf8'), sandbox, { filename: HTTP_JS });
  return { api: sandbox.module.exports as Api, handler: handlers[0], lua, logs };
}

interface Reply { status: number; headers: Record<string, string>; body: string }

function send(handler: Handler, o: { method?: string; path?: string; body?: string; headers?: Record<string, string>; address?: string }): Promise<Reply> {
  return new Promise((done) => {
    let status = 0;
    let headers: Record<string, string> = {};
    handler(
      {
        method: o.method ?? 'POST', path: o.path ?? '/portal', address: o.address ?? '127.0.0.1:50000', headers: o.headers ?? {},
        setDataHandler(cb) { setImmediate(() => cb(o.body ?? '')); },
        setCancelHandler() {},
      },
      { writeHead(s, h) { status = s; headers = h ?? {}; }, send(body) { done({ status, headers, body }); } },
    );
  });
}

const now = () => Math.floor(Date.now() / 1000);
const sign = (raw: string, ts = now(), secret = SECRET) => ({
  'X-FredPD-Ts': String(ts),
  'X-FredPD-Sig': createHmac('sha256', secret).update(`${ts}.${raw}`, 'utf8').digest('hex'),
});
let counter = 0;
const rid = () => (++counter).toString(16).padStart(32, '0');
const BODY = () => ({ requestId: rid(), discordId: '1', citizenid: 'ABC', grants: {}, action: 'getHome', input: {} });

/** A handler with controllable Lua and timers. */
function harness(opts: { secret?: string | null; lua?: (body: Record<string, unknown>, cb: Cb) => unknown } = {}) {
  const { api } = load();
  const timers: { fn: () => void; ms: number; cleared: boolean }[] = [];
  const logs: string[] = [];
  const handler = api.createHandler({
    secret: opts.secret === undefined ? SECRET : opts.secret,
    now,
    log: (l, m) => logs.push(`${l} ${m}`),
    setTimer: (fn, ms) => { const t = { fn, ms, cleared: false }; timers.push(t); return t; },
    clearTimer: (h) => { (h as { cleared: boolean }).cleared = true; },
    callLua: opts.lua ?? ((body, cb) => { setImmediate(() => cb(200, JSON.stringify({ ok: true, data: { action: body.action } }))); return true; }),
  });
  const post = (obj: unknown, extra: { headers?: Record<string, string>; address?: string; path?: string; method?: string } = {}) => {
    const raw = typeof obj === 'string' ? obj : JSON.stringify(obj);
    return send(handler, { body: raw, headers: { ...sign(raw), ...extra.headers }, address: extra.address, path: extra.path, method: extra.method });
  };
  return { api, handler, timers, logs, post };
}

describe('fredpd_mdt http.js HMAC (hmac.fixtures.json)', () => {
  const { api } = load();
  for (const v of fixtures.vectors) {
    it(`verifySignature: ${v.name}`, () => {
      const r = api.verifySignature({ secret: SECRET, ts: v.ts, sig: v.sig, rawBody: v.rawBody, nowSeconds: v.now });
      expect(r.ok).toBe(v.ok);
      if (!r.ok) expect(r.reason).toBe(v.reason);
    });
  }
  it('refuses short and placeholder secrets', () => {
    expect(api.secretProblem('')).toMatch(/not set/);
    expect(api.secretProblem('short')).toMatch(/shorter/);
    expect(api.secretProblem('CHANGE_ME_generate_64_hex_characters')).toMatch(/placeholder/);
    expect(api.secretProblem(SECRET)).toBeNull();
  });
});

describe('fredpd_mdt http.js wiring', () => {
  it('registers one handler that calls the portalRequest export', async () => {
    const { handler, lua } = load();
    expect(handler).toBeTypeOf('function');
    const raw = JSON.stringify(BODY());
    const pending = send(handler!, { body: raw, headers: sign(raw) });
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    expect(lua.calls).toHaveLength(1);
    lua.calls[0]![1](200, '{"ok":true,"data":{"x":1}}');
    const reply = await pending;
    expect(reply.status).toBe(200);
    expect(JSON.parse(reply.body)).toEqual({ ok: true, data: { x: 1 } });
  });

  it('a placeholder secret disables the route (503) and logs why', async () => {
    const { handler, logs } = load({ secret: 'CHANGE_ME_generate_64_hex_characters' });
    expect(logs.join('\n')).toMatch(/DISABLED/);
    expect((await send(handler!, { body: '{}' })).status).toBe(503);
  });
});

describe('fredpd_mdt http.js POST /portal', () => {
  it('answers the Lua result verbatim', async () => {
    const h = harness();
    const r = await h.post(BODY());
    expect(r.status).toBe(200);
    expect(JSON.parse(r.body)).toEqual({ ok: true, data: { action: 'getHome' } });
    expect(h.timers[0]!.cleared).toBe(true);
  });

  it('route, method, peer, size', async () => {
    const h = harness();
    expect((await h.post(BODY(), { path: '/other' })).status).toBe(404);
    const get = await h.post(BODY(), { method: 'GET' });
    expect(get.status).toBe(405);
    expect(get.headers.Allow).toBe('POST');
    expect((await h.post(BODY(), { address: '203.0.113.9:4444' })).status).toBe(404);
    expect((await h.post(BODY(), { address: '[2001:db8::1]:4444' })).status).toBe(404);
    expect((await h.post(BODY(), { address: '[::1]:4444' })).status).toBe(200);
    const big = await send(h.handler, { body: 'x', headers: { 'content-length': String(h.api.MAX_BODY_BYTES + 1) } });
    expect(big.status).toBe(413);
  });

  it('401 for a missing, stale or wrong signature; nothing reaches Lua', async () => {
    let called = 0;
    const h = harness({ lua: () => { called += 1; return true; } });
    const raw = JSON.stringify(BODY());
    expect((await send(h.handler, { body: raw })).status).toBe(401);
    expect((await send(h.handler, { body: raw, headers: sign(raw, now() - 120) })).status).toBe(401);
    expect((await send(h.handler, { body: raw, headers: sign(raw, now(), `${SECRET}x`) })).status).toBe(401);
    expect((await send(h.handler, { body: raw, headers: sign(`${raw} `) })).status).toBe(401);
    expect(called).toBe(0);
  });

  it('400 for bad JSON or a missing requestId; 409 for a replayed requestId', async () => {
    const h = harness();
    expect((await h.post('not json')).status).toBe(400);
    expect((await h.post('[1]')).status).toBe(400);
    expect((await h.post({ ...BODY(), requestId: 'short' })).status).toBe(400);
    const body = BODY();
    expect((await h.post(body)).status).toBe(200);
    const again = await h.post(body);
    expect(again.status).toBe(409);
    expect(JSON.parse(again.body)).toEqual({ error: 'duplicate' });
  });

  it('503 when Lua does not take the request (resource stopping, export missing, raise)', async () => {
    expect((await harness({ lua: () => false }).post(BODY())).status).toBe(503);
    expect((await harness({ lua: () => { throw new Error('No such export'); } }).post(BODY())).status).toBe(503);
  });

  it('504 when Lua never answers; a late answer is dropped', async () => {
    let late: Cb | null = null;
    const h = harness({ lua: (_b, cb) => { late = cb; return true; } });
    const pending = h.post(BODY());
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
    expect(h.timers[0]!.ms).toBe(h.api.LUA_TIMEOUT_MS);
    h.timers[0]!.fn();
    const r = await pending;
    expect(r.status).toBe(504);
    expect(() => late!(200, '{}')).not.toThrow();
  });

  it('isRemotePeer: loopback and unparsable peers pass, other addresses do not', () => {
    const { api } = load();
    for (const a of ['127.0.0.1:1', '127.8.9.10:65535', '[::1]:5', '::1', '::ffff:127.0.0.1', '', undefined, 'weird']) expect(api.isRemotePeer(a), String(a)).toBe(false);
    for (const a of ['10.0.0.2:1', '203.0.113.9', '[2001:db8::1]:80', '::ffff:10.0.0.1']) expect(api.isRemotePeer(a), a).toBe(true);
  });
});
