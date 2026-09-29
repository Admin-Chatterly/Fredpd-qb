// SPDX-License-Identifier: GPL-3.0-only
// src/fx.ts against a real local HTTP server: requests are signed per §C5 over the exact body, a refused request
// and an unreachable or slow FXServer are reported as { ok: false } and logged, never thrown.
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { emptyGrantSet } from '@fredpd/types/grants';
import { HMAC_SIG_HEADER, HMAC_TS_HEADER, verifySignature } from '@fredpd/types/hmac';
import { createFxClient } from '../src/fx';
import type { Logger } from '../src/log';
import { HMAC_SECRET } from './helpers';

type Seen = { method: string; url: string; body: string; verified: boolean };
const seen: Seen[] = [];
let mode: 'ok' | 'refuse' | 'hang' = 'ok';

const server = createServer((req, res) => {
  let body = '';
  req.on('data', (c: Buffer) => (body += c.toString('utf8')));
  req.on('end', () => {
    const verified = verifySignature({
      secret: HMAC_SECRET,
      ts: req.headers[HMAC_TS_HEADER] as string,
      sig: req.headers[HMAC_SIG_HEADER] as string,
      rawBody: body,
    }).ok;
    seen.push({ method: req.method ?? '', url: req.url ?? '', body, verified });
    if (mode === 'hang') return; // never answer
    res.writeHead(mode === 'refuse' ? 400 : 200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(mode === 'refuse' ? { error: 'invalid_body' } : { ok: true, scheduled: 3 }));
  });
});

const warnings: unknown[] = [];
const log: Logger = { error() {}, info() {}, debug() {}, warn: (o) => warnings.push(o) };
let base = '';

beforeAll(async () => {
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});
afterAll(async () => {
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
});

describe('FXServer client', () => {
  it('signs GET with the empty body and POST over the exact JSON text', async () => {
    const fx = createFxClient({ baseUrl: base, secret: HMAC_SECRET, log });
    expect(await fx.ping()).toMatchObject({ ok: true, status: 200 });
    const grants = emptyGrantSet();
    await fx.pushGrants('123', grants);
    await fx.recompute(['1', '2']);
    await fx.recompute();
    await fx.pushOfficer('123', 'Anna B.', null);
    expect(seen.map((s) => [s.method, s.url, s.verified])).toEqual([
      ['GET', '/fredpd_core/ping', true],
      ['POST', '/fredpd_core/grants', true],
      ['POST', '/fredpd_core/recompute', true],
      ['POST', '/fredpd_core/recompute', true],
      ['POST', '/fredpd_core/officer', true],
    ]);
    expect(JSON.parse(seen[1]!.body)).toEqual({ discordId: '123', grants });
    expect(JSON.parse(seen[2]!.body)).toEqual({ discordIds: ['1', '2'] });
    expect(JSON.parse(seen[3]!.body)).toEqual({});
    expect(JSON.parse(seen[4]!.body)).toEqual({ discordId: '123', displayName: 'Anna B.', avatarUrl: null });
  });

  it('pushRulesChanged posts exactly {} to /rules, signed', async () => {
    seen.length = 0;
    const fx = createFxClient({ baseUrl: `${base}/`, secret: HMAC_SECRET, log });
    expect(await fx.pushRulesChanged()).toEqual({ ok: true, status: 200, body: { ok: true, scheduled: 3 } });
    expect(seen).toEqual([{ method: 'POST', url: '/fredpd_core/rules', body: '{}', verified: true }]);
  });

  it('pushRulesChanged reports a refusal or an unreachable FXServer without throwing', async () => {
    mode = 'refuse';
    try {
      const fx = createFxClient({ baseUrl: base, secret: HMAC_SECRET, log });
      expect(await fx.pushRulesChanged()).toEqual({ ok: false, status: 400, error: 'invalid_body' });
    } finally {
      mode = 'ok';
    }
    const down = createFxClient({ baseUrl: 'http://127.0.0.1:9', secret: HMAC_SECRET, log });
    expect(await down.pushRulesChanged()).toEqual({ ok: false, status: 0, error: 'network' });
  });

  it('returns the body of a successful call', async () => {
    const fx = createFxClient({ baseUrl: base, secret: HMAC_SECRET, log });
    const res = await fx.recompute(['1']);
    expect(res).toEqual({ ok: true, status: 200, body: { ok: true, scheduled: 3 } });
  });

  it('a refused request is { ok: false, error } and logged', async () => {
    mode = 'refuse';
    try {
      const fx = createFxClient({ baseUrl: base, secret: HMAC_SECRET, log });
      expect(await fx.pushOfficer('1', 'x', null)).toEqual({ ok: false, status: 400, error: 'invalid_body' });
      expect(warnings.length).toBeGreaterThan(0);
    } finally {
      mode = 'ok';
    }
  });

  it('times out instead of hanging, and never throws when FXServer is down', async () => {
    mode = 'hang';
    try {
      const fx = createFxClient({ baseUrl: base, secret: HMAC_SECRET, log, timeoutMs: 100 });
      const started = Date.now();
      expect(await fx.ping()).toEqual({ ok: false, status: 0, error: 'timeout' });
      expect(Date.now() - started).toBeLessThan(2000);
    } finally {
      mode = 'ok';
    }
    const down = createFxClient({ baseUrl: 'http://127.0.0.1:9', secret: HMAC_SECRET, log });
    expect(await down.ping()).toEqual({ ok: false, status: 0, error: 'network' });
  });
});
