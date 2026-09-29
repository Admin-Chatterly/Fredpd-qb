// SPDX-License-Identifier: GPL-3.0-only
// Discord OAuth2 (scope identify). The routes only see the DiscordOAuth interface: production uses @fastify/oauth2
// (state cookie, code exchange) plus a fetch of /users/@me; tests inject a fake (test/helpers.ts FakeOAuth), or run
// the real wiring against a local token endpoint (test/oauth.test.ts); no network either way.
import fastifyOauth2 from '@fastify/oauth2';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { z } from 'zod';
import type { Config } from '../config';

export interface DiscordUser {
  id: string;
  username: string;
  globalName: string | null;
  avatar: string | null;
}

export interface DiscordOAuth {
  /** URL of Discord's consent page; may set the state cookie on the reply. */
  authorizeUrl(request: FastifyRequest, reply: FastifyReply): Promise<string>;
  /** Verify state and exchange ?code= for an access token. Throws on any failure (denied, bad state, bad code). */
  exchangeCode(request: FastifyRequest, reply: FastifyReply): Promise<string>;
  fetchUser(accessToken: string): Promise<DiscordUser>;
}

const DiscordUserResponseSchema = z.object({
  id: z.string().regex(/^\d{17,20}$/),
  username: z.string(),
  global_name: z.string().nullish(),
  avatar: z.string().nullish(),
});

export const DISCORD_API = 'https://discord.com/api/v10';

/** Fetch the user behind an access token (5 s deadline). */
export async function fetchDiscordUser(accessToken: string, doFetch: typeof fetch = fetch): Promise<DiscordUser> {
  const res = await doFetch(`${DISCORD_API}/users/@me`, {
    headers: { authorization: `Bearer ${accessToken}` },
    signal: AbortSignal.timeout(5000),
  });
  if (!res.ok) throw new Error(`Discord /users/@me answered ${res.status}`);
  const u = DiscordUserResponseSchema.parse(await res.json());
  return { id: u.id, username: u.username, globalName: u.global_name ?? null, avatar: u.avatar ?? null };
}

export interface DiscordOAuthOptions {
  /** Where the code exchange goes. Default https://discord.com; tests point it at a local server. */
  tokenHost?: string;
  /** fetch for /users/@me. */
  fetch?: typeof fetch;
}

/** Register @fastify/oauth2 on the app and wrap it. Call after @fastify/cookie is registered. */
export async function registerDiscordOAuth(app: FastifyInstance, config: Config, opts: DiscordOAuthOptions = {}): Promise<DiscordOAuth> {
  await app.register(fastifyOauth2, {
    name: 'oauth2Discord',
    scope: ['identify'],
    credentials: {
      client: { id: config.DISCORD_CLIENT_ID, secret: config.DISCORD_CLIENT_SECRET },
      auth: { ...fastifyOauth2.DISCORD_CONFIGURATION, ...(opts.tokenHost ? { tokenHost: opts.tokenHost } : {}) },
    },
    callbackUri: `${config.PUBLIC_URL}/auth/discord/callback`,
    // Both /auth/discord and its callback are under /auth; the state cookie is signed with SESSION_SECRET.
    cookie: { secure: config.COOKIE_SECURE, sameSite: 'lax', httpOnly: true, path: '/auth', signed: true },
  });
  const ns = app.oauth2Discord;
  if (!ns) throw new Error('@fastify/oauth2 did not register oauth2Discord');
  return {
    authorizeUrl: (request, reply) => ns.generateAuthorizationUri(request, reply),
    async exchangeCode(request, reply) {
      const token = await ns.getAccessTokenFromAuthorizationCodeFlow(request, reply);
      return token.token.access_token;
    },
    fetchUser: (accessToken) => fetchDiscordUser(accessToken, opts.fetch),
  };
}
