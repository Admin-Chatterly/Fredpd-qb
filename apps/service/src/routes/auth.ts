// SPDX-License-Identifier: GPL-3.0-only
// Discord login, logout and the session probe (docs/contracts.md §C6, §C10; IMPLEMENTATION.md §4.6).
import type { FastifyInstance, FastifyReply } from 'fastify';
import type { LoginErrorCode, SessionResponse } from '@fredpd/types/actions';
import { createSession, destroySession, SESSION_COOKIE, SESSION_TTL_SECONDS } from '../auth/session';
import type { AppContext } from '../context';
import { touchIdentity, writeAudit } from '../db/repo';
import { avatarRef, portalDisplayName } from '../discord/sync';
import { checkCsrf, sessionGrants } from '../http/guards';

export function registerAuthRoutes(app: FastifyInstance, ctx: AppContext): void {
  const { config } = ctx;
  const cookieOptions = {
    path: '/',
    httpOnly: true,
    secure: config.COOKIE_SECURE,
    sameSite: 'lax' as const,
    signed: true,
  };

  const loginFailed = (reply: FastifyReply, code: LoginErrorCode) =>
    reply.redirect(`${config.PUBLIC_URL}/?loginError=${code}`);

  app.get('/auth/discord', async (request, reply) => {
    return reply.redirect(await ctx.oauth.authorizeUrl(request, reply));
  });

  app.get('/auth/discord/callback', async (request, reply) => {
    let userId: string;
    try {
      const accessToken = await ctx.oauth.exchangeCode(request, reply);
      userId = (await ctx.oauth.fetchUser(accessToken)).id;
    } catch (err) {
      // Denied consent, a forged/expired state or a bad code all end here; the reason is only logged.
      request.log.warn({ detail: (err as Error).message }, 'Discord login failed');
      return loginFailed(reply, 'failed');
    }
    if (!ctx.gateway.isReady()) return loginFailed(reply, 'unavailable');
    if (!ctx.gateway.getMember(userId)) return loginFailed(reply, 'notMember');

    const now = ctx.clock.now();
    // A new login always gets a new session id (no fixation); the one the browser had ends.
    if (request.portalSession) {
      await destroySession(ctx.db, request.portalSession.id, now);
      ctx.hub.closeSession(request.portalSession.id);
    }
    await touchIdentity(ctx.db, userId, now);
    const { token, session } = await createSession(ctx.db, userId, now);
    await writeAudit(ctx.db, { action: 'auth.login', actorDiscord: userId, targetType: 'discord', targetId: userId });
    reply.setCookie(SESSION_COOKIE, token, { ...cookieOptions, maxAge: SESSION_TTL_SECONDS, expires: session.expiresAt });
    return reply.redirect(`${config.PUBLIC_URL}/`);
  });

  app.post('/auth/logout', async (request, reply) => {
    const session = request.portalSession;
    if (session) {
      checkCsrf(request, session);
      await destroySession(ctx.db, session.id, ctx.clock.now());
      ctx.hub.closeSession(session.id);
      await writeAudit(ctx.db, {
        action: 'auth.logout',
        actorDiscord: session.discordId,
        actorCitizenid: session.citizenid,
        targetType: 'discord',
        targetId: session.discordId,
      });
    }
    reply.clearCookie(SESSION_COOKIE, { path: '/' });
    return { ok: true };
  });

  app.get('/api/session', async (request, reply): Promise<SessionResponse> => {
    const session = request.portalSession;
    if (!session) return { user: null, csrfToken: null };
    const { member, grants } = await sessionGrants(ctx, session);
    const m = member ? ctx.gateway.getMember(session.discordId) : null;
    if (!m) {
      // Left (or was removed from) the guild: the session ends here.
      await destroySession(ctx.db, session.id, ctx.clock.now());
      ctx.hub.closeSession(session.id);
      reply.clearCookie(SESSION_COOKIE, { path: '/' });
      return { user: null, csrfToken: null };
    }
    const ref = avatarRef(m, config.DISCORD_GUILD_ID, config.OFFICER_NAME_SOURCE);
    return {
      user: {
        discordId: m.id,
        displayName: portalDisplayName(m, config.OFFICER_NAME_SOURCE),
        avatarUrl: `/avatar/${m.id}?v=${ref.key}`,
        citizenid: session.citizenid,
        grants,
      },
      csrfToken: session.csrfToken,
    };
  });
}
