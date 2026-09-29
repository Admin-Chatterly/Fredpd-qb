// SPDX-License-Identifier: GPL-3.0-only
// 60 requests per minute per user, or per IP when logged out (IMPLEMENTATION.md §4.6); the 61st gets 429 with the
// shared error shape. Security headers from helmet are present. Only the per-user test needs the database.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { RATE_LIMIT_PER_MINUTE } from '../src/app';
import { cleanup, GUILD_ID, ids, loginAs, makeApp, setupTestDb } from './helpers';
import type { TestApp } from './helpers';

let t: TestApp;
beforeAll(async () => {
  t = await makeApp();
});
afterAll(async () => {
  await t.app.close();
});

describe('rate limit and headers', () => {
  it('answers 429 { error: rate_limited } after 60 requests a minute from one IP', async () => {
    const hit = () => t.app.inject({ method: 'GET', url: '/api/session', remoteAddress: '203.0.113.7' });
    for (let i = 0; i < RATE_LIMIT_PER_MINUTE; i += 1) expect((await hit()).statusCode).toBe(200);
    const limited = await hit();
    expect(limited.statusCode).toBe(429);
    expect(limited.json()).toEqual({ error: 'rate_limited' });
    expect(limited.headers['retry-after']).toBeDefined();
    // Another client is not affected.
    const other = await t.app.inject({ method: 'GET', url: '/api/session', remoteAddress: '203.0.113.8' });
    expect(other.statusCode).toBe(200);
  });

  it('sets helmet security headers', async () => {
    const res = await t.app.inject({ method: 'GET', url: '/api/session', remoteAddress: '203.0.113.9' });
    expect(res.headers['x-content-type-options']).toBe('nosniff');
    expect(res.headers['content-security-policy']).toContain("default-src 'self'");
  });
});

const PREFIX = '907';
const nextId = ids(PREFIX);
const database = await setupTestDb('ratelimit.test');

describe.skipIf(!database)('rate limit per user (DB)', () => {
  let u: TestApp;
  const anna = nextId();
  const bo = nextId();
  beforeAll(async () => {
    if (!database) return;
    await cleanup(database, PREFIX);
    u = await makeApp({ database });
    u.gateway.addMember({ id: anna, roleIds: [GUILD_ID] });
    u.gateway.addMember({ id: bo, roleIds: [GUILD_ID] });
  });
  afterAll(async () => {
    if (!database) return;
    await u?.app.close();
    await cleanup(database, PREFIX);
    await database.close();
  });

  it('two logged-in users behind one IP have separate budgets (key user:<discordId>)', async () => {
    const [a, b] = [await loginAs(u, database!, anna), await loginAs(u, database!, bo)];
    const hit = (cookie?: string) =>
      u.app.inject({ method: 'GET', url: '/api/session', remoteAddress: '198.51.100.20', headers: cookie ? { cookie } : {} });
    for (let i = 0; i < RATE_LIMIT_PER_MINUTE; i += 1) expect((await hit(a.cookie)).statusCode).toBe(200);
    expect((await hit(a.cookie)).statusCode).toBe(429);
    // Same IP, other user: own budget. Same IP, logged out: the IP budget, untouched by Anna's requests.
    const other = await hit(b.cookie);
    expect(other.statusCode).toBe(200);
    expect(other.json()).toMatchObject({ user: { discordId: bo } });
    expect((await hit()).statusCode).toBe(200);
  });
});
