// SPDX-License-Identifier: GPL-3.0-only
// GET /avatar/:discordId: fetched from the (fake) Discord CDN once per avatar hash, then served from disk; the
// last cached file is served when the member is unknown; 404 when nothing is known. No database needed.
import { mkdtempSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { GUILD_ID, makeApp, PNG_1X1, testConfig } from './helpers';
import type { TestApp } from './helpers';

const HASH_A = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const HASH_B = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const dir = mkdtempSync(join(tmpdir(), 'fredpd-avatar-'));
const fetched: string[] = [];
let cdnBody: Buffer = PNG_1X1;

const fakeFetch = (async (input: string | URL | Request) => {
  const url = String(input instanceof Request ? input.url : input);
  fetched.push(url);
  return new Response(new Uint8Array(cdnBody), { status: 200, headers: { 'content-type': 'image/png' } });
}) as typeof fetch;

describe('GET /avatar/:discordId', () => {
  let t: TestApp;
  const id = '400000000000000001';

  beforeAll(async () => {
    t = await makeApp({ config: testConfig({ UPLOAD_DIR: dir }), deps: { fetch: fakeFetch } });
    t.gateway.addMember({ id, avatar: HASH_A, roleIds: [GUILD_ID] });
  });
  afterAll(async () => {
    await t.app.close();
    rmSync(dir, { recursive: true, force: true });
  });

  it('downloads once, then serves from disk, readable cross-origin by the tablet', async () => {
    const first = await t.app.inject({ method: 'GET', url: `/avatar/${id}?v=u${HASH_A}` });
    expect(first.statusCode).toBe(200);
    expect(first.headers['content-type']).toBe('image/png');
    expect(first.headers['cross-origin-resource-policy']).toBe('cross-origin');
    expect(first.headers['cache-control']).toBe('public, max-age=86400');
    expect(first.rawPayload.equals(PNG_1X1)).toBe(true);
    const second = await t.app.inject({ method: 'GET', url: `/avatar/${id}` });
    expect(second.statusCode).toBe(200);
    expect(second.headers['cache-control']).toBe('public, max-age=300');
    expect(fetched).toEqual([`https://cdn.discordapp.com/avatars/${id}/${HASH_A}.png?size=128`]);
    expect(readdirSync(join(dir, 'avatars'))).toEqual([`${id}-u${HASH_A}.png`]);
  });

  it('a new avatar hash is fetched once and replaces the old file', async () => {
    t.gateway.addMember({ id, avatar: HASH_B, roleIds: [GUILD_ID] });
    const res = await t.app.inject({ method: 'GET', url: `/avatar/${id}` });
    expect(res.statusCode).toBe(200);
    expect(fetched).toHaveLength(2);
    expect(readdirSync(join(dir, 'avatars'))).toEqual([`${id}-u${HASH_B}.png`]);
  });

  it('serves the cached file when the member is unknown (bot down or member left)', async () => {
    t.gateway.ready = false;
    try {
      const res = await t.app.inject({ method: 'GET', url: `/avatar/${id}` });
      expect(res.statusCode).toBe(200);
      expect(fetched).toHaveLength(2);
    } finally {
      t.gateway.ready = true;
    }
  });

  it('404 for an unknown id or a malformed one; a CDN answer that is not a PNG is not cached', async () => {
    expect((await t.app.inject({ method: 'GET', url: '/avatar/499999999999999999' })).statusCode).toBe(404);
    expect((await t.app.inject({ method: 'GET', url: '/avatar/..%2F..%2Fetc' })).statusCode).toBe(404);
    const other = '400000000000000002';
    t.gateway.addMember({ id: other, avatar: HASH_A, roleIds: [GUILD_ID] });
    cdnBody = Buffer.from('<html>not an image</html>');
    try {
      const res = await t.app.inject({ method: 'GET', url: `/avatar/${other}` });
      expect(res.statusCode).toBe(404);
      expect(readdirSync(join(dir, 'avatars')).some((n) => n.startsWith(other))).toBe(false);
    } finally {
      cdnBody = PNG_1X1;
    }
  });
});
