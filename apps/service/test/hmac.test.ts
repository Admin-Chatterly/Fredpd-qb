// SPDX-License-Identifier: GPL-3.0-only
// /internal/* HMAC (docs/contracts.md §C5): 401 { error: 'unauthorized' } on a missing, wrong or skewed signature,
// 200 on a good one; the signature covers the raw body text (a POST body that is not JSON cannot pass); rejections
// are logged throttled. No database needed.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { HMAC_SIG_HEADER, HMAC_TS_HEADER, signBody } from '@fredpd/types/hmac';
import { HMAC_REJECT_LOG_INTERVAL_MS } from '../src/http/guards';
import { HMAC_SECRET, makeApp, signedInject } from './helpers';
import type { TestApp } from './helpers';

let t: TestApp;
beforeAll(async () => {
  t = await makeApp();
});
afterAll(async () => {
  await t.app.close();
});

const now = () => Math.floor(t.clock.now().getTime() / 1000);

describe('HMAC-protected routes', () => {
  it('GET /internal/ping: 200 with a good signature over the empty body', async () => {
    const res = await signedInject(t, { method: 'GET', url: '/internal/ping' });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ ok: true, discord: true, subscribers: 0 });
  });

  it('401 without headers', async () => {
    const res = await t.app.inject({ method: 'GET', url: '/internal/ping' });
    expect(res.statusCode).toBe(401);
    expect(res.json()).toEqual({ error: 'unauthorized' });
  });

  it('401 with a signature made with another secret', async () => {
    const res = await signedInject(t, { method: 'GET', url: '/internal/ping', secret: 'another-secret-0123456789abcdef-XYZ' });
    expect(res.statusCode).toBe(401);
  });

  it('401 when the timestamp is more than 60 s off (both directions), 200 at exactly 60 s', async () => {
    for (const skew of [61, -61, 3600]) {
      const res = await signedInject(t, { method: 'GET', url: '/internal/ping', ts: now() - skew });
      expect(res.statusCode, `skew ${skew}`).toBe(401);
    }
    const edge = await signedInject(t, { method: 'GET', url: '/internal/ping', ts: now() - 60 });
    expect(edge.statusCode).toBe(200);
  });

  it('401 on a malformed signature header', async () => {
    const res = await t.app.inject({
      method: 'GET',
      url: '/internal/ping',
      headers: { [HMAC_TS_HEADER]: String(now()), [HMAC_SIG_HEADER]: 'not-hex' },
    });
    expect(res.statusCode).toBe(401);
  });

  it('POST /internal/events: 200 when the raw body is signed, 401 when the body was altered', async () => {
    const good = await signedInject(t, { method: 'POST', url: '/internal/events', body: { type: 'alertClosed', payload: { id: 1 } } });
    expect(good.statusCode).toBe(200);
    expect(good.json()).toEqual({ ok: true, delivered: 0 });

    // Signed with whitespace in the JSON: the signature is over the exact text, so it still verifies.
    const spaced = '{ "type": "unitsChanged",  "payload": { "units": [] } }';
    const ok2 = await signedInject(t, { method: 'POST', url: '/internal/events', rawBody: spaced });
    expect(ok2.statusCode).toBe(200);

    const ts = String(now());
    const sig = signBody(HMAC_SECRET, ts, '{"type":"alertCreated","payload":{"id":1}}');
    const tampered = await t.app.inject({
      method: 'POST',
      url: '/internal/events',
      headers: { [HMAC_TS_HEADER]: ts, [HMAC_SIG_HEADER]: sig, 'content-type': 'application/json' },
      payload: '{"type":"alertCreated","payload":{"id":2}}',
    });
    expect(tampered.statusCode).toBe(401);
  });

  it('POST with a wrong signature is refused before its JSON is parsed (401, not 400)', async () => {
    const ts = String(now());
    const res = await t.app.inject({
      method: 'POST',
      url: '/internal/events',
      headers: { [HMAC_TS_HEADER]: ts, [HMAC_SIG_HEADER]: 'b'.repeat(64), 'content-type': 'application/json' },
      payload: '{"type": not json',
    });
    expect(res.statusCode).toBe(401);
    expect(res.json()).toEqual({ error: 'unauthorized' });
  });

  it('POST with a body the app does not keep raw (text/plain) is refused, even signed over the empty string', async () => {
    const ts = String(now());
    const res = await t.app.inject({
      method: 'POST',
      url: '/internal/events',
      headers: { [HMAC_TS_HEADER]: ts, [HMAC_SIG_HEADER]: signBody(HMAC_SECRET, ts, ''), 'content-type': 'text/plain' },
      payload: '{"type":"alertCreated","payload":{}}',
    });
    expect(res.statusCode).toBe(401);
    expect(res.json()).toEqual({ error: 'unauthorized' });
  });

  it('logs rejections at most once per interval, with the number suppressed in between', async () => {
    const lines: string[] = [];
    const t2 = await makeApp({ deps: { logger: { level: 'warn', stream: { write: (line: string) => void lines.push(line) } } } });
    const rejected = () => lines.map((l) => JSON.parse(l) as { msg: string; suppressedSinceLast: number }).filter((l) => l.msg === 'HMAC rejected');
    try {
      for (let i = 0; i < 5; i += 1) expect((await t2.app.inject({ method: 'GET', url: '/internal/ping' })).statusCode).toBe(401);
      expect(rejected()).toHaveLength(1);
      t2.clock.advance(HMAC_REJECT_LOG_INTERVAL_MS);
      await t2.app.inject({ method: 'GET', url: '/internal/ping' });
      expect(rejected()).toHaveLength(2);
      expect(rejected()[1]!.suppressedSinceLast).toBe(4);
    } finally {
      await t2.app.close();
    }
  });

  it('POST /internal/events validates the body after the signature (400 invalid_body)', async () => {
    const res = await signedInject(t, { method: 'POST', url: '/internal/events', body: { type: 'nope', payload: {} } });
    expect(res.statusCode).toBe(400);
    expect(res.json()).toMatchObject({ error: 'invalid_body' });
    const extra = await signedInject(t, { method: 'POST', url: '/internal/events', body: { type: 'alertClosed', payload: {}, discordIds: [] } });
    expect(extra.statusCode).toBe(400);
  });

  it('GET /internal/grants: 401 unsigned, 503 while the Discord gateway is not ready', async () => {
    const unsigned = await t.app.inject({ method: 'GET', url: '/internal/grants/123456789012345678' });
    expect(unsigned.statusCode).toBe(401);
    t.gateway.ready = false;
    try {
      const res = await signedInject(t, { method: 'GET', url: '/internal/grants/123456789012345678' });
      expect(res.statusCode).toBe(503);
      expect(res.json()).toMatchObject({ error: 'unavailable' });
    } finally {
      t.gateway.ready = true;
    }
  });

  it('/internal/* only straight from loopback: another address or any proxy header is 404, even correctly signed', async () => {
    for (const remoteAddress of ['127.0.0.1', '127.0.0.2', '::1', '::ffff:127.0.0.1']) {
      const res = await signedInject(t, { method: 'GET', url: '/internal/ping', remoteAddress });
      expect(res.statusCode, remoteAddress).toBe(200);
    }
    for (const remoteAddress of ['203.0.113.5', '192.168.1.10', '::ffff:10.0.0.1', '::2']) {
      const res = await signedInject(t, { method: 'GET', url: '/internal/ping', remoteAddress });
      expect(res.statusCode, remoteAddress).toBe(404);
      expect(res.json()).toEqual({ error: 'not_found' });
    }
    // Through cloudflared or Caddy on the same host: the peer is loopback, but the proxy says where it came from.
    for (const header of ['x-forwarded-for', 'forwarded', 'x-real-ip', 'cf-connecting-ip', 'via']) {
      const res = await signedInject(t, { method: 'GET', url: '/internal/grants/123456789012345678', headers: { [header]: '198.51.100.7' } });
      expect(res.statusCode, header).toBe(404);
    }
    const post = await signedInject(t, { method: 'POST', url: '/internal/events', body: { type: 'alertClosed', payload: { id: 1 } }, headers: { 'x-forwarded-for': '198.51.100.7' } });
    expect(post.statusCode).toBe(404);
  });

  it('unknown routes answer 404 { error: not_found }', async () => {
    const res = await t.app.inject({ method: 'GET', url: '/internal/nope' });
    expect(res.statusCode).toBe(404);
    expect(res.json()).toEqual({ error: 'not_found' });
  });
});
