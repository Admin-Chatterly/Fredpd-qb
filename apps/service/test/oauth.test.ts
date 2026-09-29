// SPDX-License-Identifier: GPL-3.0-only
// The real @fastify/oauth2 wiring, no network: the code exchange goes to a local token endpoint that records every
// request, /users/@me to an injected fetch. /auth/discord redirects to Discord with scope identify, our callback
// URL and a state that is also set as a signed cookie; a callback whose state does not match is refused BEFORE any
// token request, a matching one is exchanged; the session cookie is Secure under the default COOKIE_SECURE=true.
import { createServer } from 'node:http';
import type { AddressInfo, Server } from 'node:net';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { SESSION_COOKIE } from '../src/auth/session';
import { cleanup, GUILD_ID, ids, makeApp, rows, setupTestDb, testConfig } from './helpers';
import type { TestApp } from './helpers';

const PREFIX = '906';
const nextId = ids(PREFIX);
const USER = nextId();

let server: Server;
let tokenHost: string;
const tokenRequests: { url: string; body: string }[] = [];
const userRequests: string[] = [];

/** Discord's /users/@me, answered locally; records the bearer token it was called with. */
const fakeFetch: typeof fetch = async (_input, init) => {
  userRequests.push(String(new Headers(init?.headers).get('authorization')));
  return new Response(JSON.stringify({ id: USER, username: 'anna_b', global_name: 'Anna Berg', avatar: null }), {
    status: 200,
    headers: { 'content-type': 'application/json' },
  });
};

beforeAll(async () => {
  server = createServer((req, res) => {
    let body = '';
    req.on('data', (chunk: Buffer) => {
      body += chunk.toString();
    });
    req.on('end', () => {
      tokenRequests.push({ url: String(req.url), body });
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ access_token: 'access-abc', token_type: 'Bearer', expires_in: 604800, refresh_token: 'r', scope: 'identify' }));
    });
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  tokenHost = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});
afterAll(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()));
});
beforeEach(() => {
  tokenRequests.length = 0;
  userRequests.length = 0;
});

/** GET /auth/discord: the state from Discord's URL and the signed state cookie the browser would keep. */
async function begin(t: TestApp): Promise<{ state: string; stateCookie: string }> {
  const res = await t.app.inject({ method: 'GET', url: '/auth/discord' });
  const state = new URL(String(res.headers.location)).searchParams.get('state') ?? '';
  const cookie = res.cookies.find((c) => c.name === 'oauth2-redirect-state');
  return { state, stateCookie: cookie?.value ?? '' };
}

const callback = (t: TestApp, query: string, stateCookie: string) =>
  t.app.inject({ method: 'GET', url: `/auth/discord/callback?${query}`, cookies: { 'oauth2-redirect-state': stateCookie } });

describe('Discord OAuth2 via @fastify/oauth2', () => {
  let t: TestApp;
  beforeAll(async () => {
    t = await makeApp({ deps: { oauth: undefined, discordTokenHost: tokenHost, fetch: fakeFetch } });
  });
  afterAll(async () => {
    await t.app.close();
  });

  it('redirects to Discord with scope identify and a state cookie', async () => {
    const res = await t.app.inject({ method: 'GET', url: '/auth/discord' });
    expect(res.statusCode).toBe(302);
    const url = new URL(String(res.headers.location));
    expect(`${url.origin}${url.pathname}`).toBe('https://discord.com/api/oauth2/authorize');
    expect(url.searchParams.get('client_id')).toBe('200000000000000000');
    expect(url.searchParams.get('scope')).toBe('identify');
    expect(url.searchParams.get('redirect_uri')).toBe('https://portal.example.test/auth/discord/callback');
    const state = url.searchParams.get('state');
    expect(state).toBeTruthy();
    const cookies = ([] as string[]).concat(res.headers['set-cookie'] ?? []);
    const stateCookie = cookies.find((c) => c.startsWith('oauth2-redirect-state='));
    expect(stateCookie).toMatch(/HttpOnly/i);
    expect(stateCookie).toMatch(/Path=\/auth/);
  });

  it('refuses a callback whose state does not match: no token request is made', async () => {
    const { stateCookie } = await begin(t);
    const forged = await callback(t, 'code=abc&state=forged', stateCookie);
    expect(forged.statusCode).toBe(302);
    expect(forged.headers.location).toBe('https://portal.example.test/?loginError=failed');
    const noCookie = await t.app.inject({ method: 'GET', url: '/auth/discord/callback?code=abc&state=forged' });
    expect(noCookie.headers.location).toBe('https://portal.example.test/?loginError=failed');
    expect(tokenRequests).toEqual([]);
    expect(userRequests).toEqual([]);
  });

  it('exchanges the code when the state matches, then asks Discord who the user is', async () => {
    const { state, stateCookie } = await begin(t);
    const res = await callback(t, `code=abc&state=${encodeURIComponent(state)}`, stateCookie);
    expect(tokenRequests).toHaveLength(1);
    expect(tokenRequests[0]!.url).toBe('/api/oauth2/token');
    const form = new URLSearchParams(tokenRequests[0]!.body);
    expect(form.get('grant_type')).toBe('authorization_code');
    expect(form.get('code')).toBe('abc');
    expect(form.get('redirect_uri')).toBe('https://portal.example.test/auth/discord/callback');
    expect(userRequests).toEqual(['Bearer access-abc']);
    // The user is not in the fake guild (no database needed for this part).
    expect(res.headers.location).toBe('https://portal.example.test/?loginError=notMember');
  });
});

const database = await setupTestDb('oauth.test');

describe.skipIf(!database)('Discord OAuth2 login creates a session (DB)', () => {
  let t: TestApp;
  beforeAll(async () => {
    if (!database) return;
    await cleanup(database, PREFIX);
    // COOKIE_SECURE unset -> its default (true); testConfig sets 'false' for the other files.
    const config = testConfig({ COOKIE_SECURE: undefined });
    expect(config.COOKIE_SECURE).toBe(true);
    t = await makeApp({ database, config, deps: { oauth: undefined, discordTokenHost: tokenHost, fetch: fakeFetch } });
    t.gateway.addMember({ id: USER, roleIds: [GUILD_ID] });
  });
  afterAll(async () => {
    if (!database) return;
    await t?.app.close();
    await cleanup(database, PREFIX);
    await database.close();
  });

  it('matching state + guild member: Secure, httpOnly, SameSite=Lax session cookie and a session row', async () => {
    const { state, stateCookie } = await begin(t);
    const res = await callback(t, `code=abc&state=${encodeURIComponent(state)}`, stateCookie);
    expect(res.statusCode).toBe(302);
    expect(res.headers.location).toBe('https://portal.example.test/');
    const sid = ([] as string[]).concat(res.headers['set-cookie'] ?? []).find((c) => c.startsWith(`${SESSION_COOKIE}=`));
    expect(sid).toBeDefined();
    expect(sid).toMatch(/;\s*Secure/i);
    expect(sid).toMatch(/;\s*HttpOnly/i);
    expect(sid).toMatch(/;\s*SameSite=Lax/i);
    expect(await rows(database!, 'SELECT id FROM fredpd_sessions WHERE discord_id = ?', [USER])).toHaveLength(1);
  });
});
