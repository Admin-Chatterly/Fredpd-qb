// SPDX-License-Identifier: GPL-3.0-only
// Discord login end to end with a fake OAuth provider injected through deps (no network): the callback creates a
// session row and the signed httpOnly cookie, GET /api/session returns the user and CSRF token, logout needs the
// token and ends the session. Also: non-members and failed exchanges are redirected with a login error.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { SessionResponseSchema } from '@fredpd/types/actions';
import { hashToken, SESSION_COOKIE } from '../src/auth/session';
import { cleanup, GUILD_ID, ids, makeApp, rows, seedRole, setupTestDb } from './helpers';
import type { TestApp } from './helpers';

const PREFIX = '904';
const database = await setupTestDb('auth.test');
const nextId = ids(PREFIX);

function cookieFrom(setCookie: string | string[] | undefined): { header: string; attrs: string } {
  const list = Array.isArray(setCookie) ? setCookie : setCookie ? [setCookie] : [];
  const line = list.find((c) => c.startsWith(`${SESSION_COOKIE}=`));
  if (!line) throw new Error('no session cookie set');
  return { header: line.split(';')[0]!, attrs: line };
}

describe.skipIf(!database)('Discord OAuth login and session (DB)', () => {
  let t: TestApp;
  const role = nextId();
  const member = nextId();
  const outsider = nextId();

  beforeAll(async () => {
    if (!database) return;
    await cleanup(database, PREFIX);
    await seedRole(database, role, 'Polis', 10, [['unit', 'igv', 'allow']]);
    t = await makeApp({ database });
    t.gateway.addMember({ id: member, username: 'anna', globalName: 'Anna Berg', nick: 'Anna B.', roleIds: [GUILD_ID, role] });
  });

  afterAll(async () => {
    if (!database) return;
    await t?.app.close();
    await cleanup(database, PREFIX);
    await database.close();
  });

  it('GET /auth/discord redirects to the provider', async () => {
    const res = await t.app.inject({ method: 'GET', url: '/auth/discord' });
    expect(res.statusCode).toBe(302);
    expect(res.headers.location).toBe('https://discord.test/oauth2/authorize?state=fake');
  });

  it('logged out: GET /api/session answers { user: null, csrfToken: null }', async () => {
    const res = await t.app.inject({ method: 'GET', url: '/api/session' });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ user: null, csrfToken: null });
  });

  it('callback: creates the session cookie and row, records the identity, then /api/session and logout work', async () => {
    const res = await t.app.inject({ method: 'GET', url: `/auth/discord/callback?code=good-${member}&state=fake` });
    expect(res.statusCode).toBe(302);
    expect(res.headers.location).toBe('https://portal.example.test/');
    const { header, attrs } = cookieFrom(res.headers['set-cookie']);
    expect(attrs).toMatch(/HttpOnly/i);
    expect(attrs).toMatch(/SameSite=Lax/i);
    expect(attrs).toMatch(/Path=\//);
    expect(attrs).toMatch(/Max-Age=604800/);

    // The cookie is signed; the DB holds sha256 of the token only.
    const token = t.app.unsignCookie(decodeURIComponent(header.slice(SESSION_COOKIE.length + 1)));
    expect(token.valid).toBe(true);
    const sessions = await rows<{ id: string; citizenid: string | null }>(database!, 'SELECT id, citizenid FROM fredpd_sessions WHERE discord_id = ?', [member]);
    expect(sessions).toEqual([{ id: hashToken(token.value!), citizenid: null }]);
    expect(await rows(database!, 'SELECT last_seen FROM fredpd_identities WHERE discord_id = ? AND last_seen IS NOT NULL', [member])).toHaveLength(1);
    expect(await rows(database!, "SELECT id FROM fredpd_audit WHERE action = 'auth.login' AND actor_discord = ?", [member])).toHaveLength(1);

    const me = await t.app.inject({ method: 'GET', url: '/api/session', headers: { cookie: header } });
    expect(me.statusCode).toBe(200);
    const body = SessionResponseSchema.parse(me.json());
    expect(body.user).toMatchObject({ discordId: member, displayName: 'Anna B.', citizenid: null, avatarUrl: expect.stringMatching(new RegExp(`^/avatar/${member}\\?v=`)) });
    expect(body.user?.grants.units).toEqual(['igv']);
    expect(body.csrfToken).toMatch(/^[A-Za-z0-9_-]{43}$/);

    // Logout without the CSRF token is refused and the session survives.
    const refused = await t.app.inject({ method: 'POST', url: '/auth/logout', headers: { cookie: header } });
    expect(refused.statusCode).toBe(403);
    const out = await t.app.inject({ method: 'POST', url: '/auth/logout', headers: { cookie: header, 'x-csrf-token': body.csrfToken! } });
    expect(out.statusCode).toBe(200);
    expect(await rows(database!, 'SELECT id FROM fredpd_sessions WHERE discord_id = ?', [member])).toHaveLength(0);
    const after = await t.app.inject({ method: 'GET', url: '/api/session', headers: { cookie: header } });
    expect(after.json()).toEqual({ user: null, csrfToken: null });
  });

  it('a tampered or unsigned cookie is ignored', async () => {
    const res = await t.app.inject({ method: 'GET', url: '/api/session', headers: { cookie: `${SESSION_COOKIE}=${'a'.repeat(43)}` } });
    expect(res.json()).toEqual({ user: null, csrfToken: null });
  });

  it('an expired session is not accepted', async () => {
    const res = await t.app.inject({ method: 'GET', url: `/auth/discord/callback?code=good-${member}` });
    const { header } = cookieFrom(res.headers['set-cookie']);
    t.clock.advance(7 * 24 * 3600 * 1000 + 1000);
    try {
      const me = await t.app.inject({ method: 'GET', url: '/api/session', headers: { cookie: header } });
      expect(me.json()).toEqual({ user: null, csrfToken: null });
    } finally {
      t.clock.advance(-(7 * 24 * 3600 * 1000 + 1000));
    }
  });

  it('redirects with loginError for a failed exchange, a non-member and a gateway that is not ready', async () => {
    const bad = await t.app.inject({ method: 'GET', url: '/auth/discord/callback?code=forged' });
    expect(bad.headers.location).toBe('https://portal.example.test/?loginError=failed');
    expect(bad.headers['set-cookie']).toBeUndefined();

    const notMember = await t.app.inject({ method: 'GET', url: `/auth/discord/callback?code=good-${outsider}` });
    expect(notMember.headers.location).toBe('https://portal.example.test/?loginError=notMember');
    expect(await rows(database!, 'SELECT id FROM fredpd_sessions WHERE discord_id = ?', [outsider])).toHaveLength(0);

    t.gateway.ready = false;
    try {
      const down = await t.app.inject({ method: 'GET', url: `/auth/discord/callback?code=good-${member}` });
      expect(down.headers.location).toBe('https://portal.example.test/?loginError=unavailable');
    } finally {
      t.gateway.ready = true;
    }
  });

  it('a user who left the guild loses the session on the next /api/session', async () => {
    const res = await t.app.inject({ method: 'GET', url: `/auth/discord/callback?code=good-${member}` });
    const { header } = cookieFrom(res.headers['set-cookie']);
    const saved = t.gateway.members.get(member)!;
    t.gateway.members.delete(member);
    try {
      const me = await t.app.inject({ method: 'GET', url: '/api/session', headers: { cookie: header } });
      expect(me.json()).toEqual({ user: null, csrfToken: null });
      const token = t.app.unsignCookie(decodeURIComponent(header.slice(SESSION_COOKIE.length + 1))).value!;
      expect(await rows(database!, 'SELECT id FROM fredpd_sessions WHERE id = ?', [hashToken(token)])).toHaveLength(0);
    } finally {
      t.gateway.members.set(member, saved);
    }
  });
});
