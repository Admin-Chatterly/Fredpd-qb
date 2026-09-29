// SPDX-License-Identifier: GPL-3.0-only
// fredpd_service HTTP app (IMPLEMENTATION.md §5.9, docs/contracts.md §C5, §C6, §C10). buildApp takes every outside
// dependency (DB, Discord gateway, FXServer client, clock, OAuth) so tests inject fakes; src/main.ts wires the real
// ones. Security baseline (§4.6): helmet, signed httpOnly/secure/SameSite=Lax session cookie, CSRF token on
// writes, 60 requests/min per user (or IP when logged out), uploads ≤ 5 MB with MIME sniffing, HMAC on /internal.
import { createHash } from 'node:crypto';
import { join, resolve } from 'node:path';
import cookie from '@fastify/cookie';
import helmet from '@fastify/helmet';
import multipart from '@fastify/multipart';
import rateLimit from '@fastify/rate-limit';
import websocket from '@fastify/websocket';
import Fastify from 'fastify';
import type { FastifyInstance, FastifyServerOptions } from 'fastify';
import { UPLOAD_MAX_BYTES } from '@fredpd/types/actions';
import { AvatarCache } from './avatar';
import { registerDiscordOAuth } from './auth/oauth';
import type { DiscordOAuth } from './auth/oauth';
import { loadSession, SESSION_COOKIE } from './auth/session';
import { systemClock } from './clock';
import type { Clock } from './clock';
import type { Config } from './config';
import { BackgroundTasks } from './context';
import type { AppContext } from './context';
import type { Db } from './db/client';
import type { DiscordGateway } from './discord/gateway';
import { createSync } from './discord/sync';
import type { FxClient } from './fx';
import { FxRetry } from './fx-retry';
import { errorHandler, HttpError } from './http/errors';
import { checkHmacBeforeParse } from './http/guards';
import { createLogger } from './log';
import type { Logger } from './log';
import { registerAdminRoutes } from './routes/admin';
import { registerAlertRoutes } from './routes/alerts';
import { registerAuthRoutes } from './routes/auth';
import { registerAvatarRoutes } from './routes/avatar';
import { registerInternalRoutes } from './routes/internal';
import { registerPortalRoutes } from './routes/portal';
import { isSpaRequest, registerPortalStatic, sendPortalIndex } from './routes/static';
import { registerUploadRoutes } from './routes/upload';
import { registerWsRoutes } from './routes/ws';
import { loadUnitCodes } from './units';
import { liveAccess } from './ws/events';
import { WsHub } from './ws/hub';
import { UnitsSnapshot } from './ws/units-snapshot';

export interface AppDeps {
  config: Config;
  db: Db;
  gateway: DiscordGateway;
  fx: FxClient;
  clock?: Clock;
  /** Default: @fastify/oauth2 against Discord. Tests pass a fake. */
  oauth?: DiscordOAuth;
  /** fetch for Discord HTTP calls: CDN downloads (avatar cache) and /users/@me after the OAuth exchange. */
  fetch?: typeof fetch;
  /** Tests: host of the OAuth token endpoint used by the default (@fastify/oauth2) login. */
  discordTokenHost?: string;
  /** Logger outside requests (sync, background work). */
  log?: Logger;
  /** Fastify's request logger. Default: pino at config.LOG_LEVEL. */
  logger?: FastifyServerOptions['logger'];
  /** Unit codes in primary-unit order. Default: config/units.json. */
  unitOrder?: string[];
  /** Redelivery delays for grant changes FXServer missed. Default FX_RETRY_DELAYS_MS (2 s, 10 s, 30 s). */
  fxRetryDelaysMs?: readonly number[];
}

/** Rate-limit key of a session cookie token (sha256, shortened): no raw token in the limiter's memory. */
function sessionRateKey(token: string): string {
  return createHash('sha256').update(token).digest('hex').slice(0, 32);
}

/**
 * Content-Security-Policy of every answer (task 7.2 review of helmet's defaults). Same-origin only: the portal's
 * scripts, styles, fonts, lazy chunks, /avatar images and the /ws socket; images also from data:/blob: (upload
 * previews); style-src keeps 'unsafe-inline' for React style attributes; no frames, no plugins, no <base>, forms
 * only to us. upgrade-insecure-requests only behind HTTPS (COOKIE_SECURE), so plain-http development still loads.
 */
export function cspDirectives(https: boolean): Record<string, string[] | null> {
  return {
    'default-src': ["'self'"],
    'script-src': ["'self'"],
    'script-src-attr': ["'none'"],
    'style-src': ["'self'", "'unsafe-inline'"],
    'img-src': ["'self'", 'data:', 'blob:'],
    'font-src': ["'self'", 'data:'],
    'connect-src': ["'self'"],
    'object-src': ["'none'"],
    'base-uri': ["'none'"],
    'form-action': ["'self'"],
    'frame-ancestors': ["'none'"],
    'upgrade-insecure-requests': https ? [] : null,
  };
}

/** Default JSON body limit; /upload raises it for base64 images. */
const BODY_LIMIT = 256 * 1024;
export const RATE_LIMIT_PER_MINUTE = 60;

export async function buildApp(deps: AppDeps): Promise<FastifyInstance> {
  const { config, db, gateway, fx } = deps;
  const clock = deps.clock ?? systemClock;
  const log = deps.log ?? createLogger('fredpd_service', config.LOG_LEVEL);
  const unitOrder = deps.unitOrder ?? loadUnitCodes();

  const app = Fastify({
    logger: deps.logger ?? { level: config.LOG_LEVEL },
    bodyLimit: BODY_LIMIT,
    // The service listens on loopback behind Cloudflare Tunnel or Caddy on the same host: take the client address
    // from X-Forwarded-For only when the connection comes from loopback (so rate limits are per real client).
    trustProxy: 'loopback',
  });

  app.decorateRequest('sessionToken', undefined);
  app.decorateRequest('portalSession', null);
  app.decorateRequest('rawBody', undefined);
  app.setErrorHandler(errorHandler);
  await app.register(helmet, { contentSecurityPolicy: { directives: cspDirectives(config.COOKIE_SECURE) } });
  await app.register(cookie, { secret: config.SESSION_SECRET });

  // The session cookie is only unsigned here (no I/O): a validly signed token keys the rate limiter (whose hooks are
  // route-level and so run after this one), everyone else is limited per IP. The session row is read afterwards, in
  // preParsing, so a client over its limit costs no DB query. The key is a hash of the token (sessions are one per
  // user: a new login ends the old one), so the raw token is never kept in the limiter's store.
  app.addHook('onRequest', async (request) => {
    const raw = request.cookies[SESSION_COOKIE];
    if (!raw) return;
    const unsigned = request.unsignCookie(raw);
    if (!unsigned.valid || unsigned.value === null) return;
    request.sessionToken = unsigned.value;
  });

  await app.register(rateLimit, {
    max: RATE_LIMIT_PER_MINUTE,
    timeWindow: '1 minute',
    keyGenerator: (request) => (request.sessionToken ? `session:${sessionRateKey(request.sessionToken)}` : `ip:${request.ip}`),
    errorResponseBuilder: () => new HttpError(429, 'rate_limited'),
  });

  // After every onRequest hook (rate limit, route guards), before the body is parsed: the JSON parser (HMAC check)
  // and every later hook see request.portalSession.
  app.addHook('preParsing', async (request) => {
    if (request.sessionToken) request.portalSession = await loadSession(db, request.sessionToken, clock.now());
  });
  await app.register(multipart, {
    limits: { fileSize: UPLOAD_MAX_BYTES, files: 1, fields: 4, parts: 5, fieldSize: 1024 },
    throwFileSizeLimit: true,
  });
  await app.register(websocket, { options: { maxPayload: 4096 } });
  const oauth = deps.oauth ?? (await registerDiscordOAuth(app, config, { tokenHost: deps.discordTokenHost, fetch: deps.fetch }));

  const hub = new WsHub(() => clock.now());
  const grantDeps = { db, gateway, clock, unitOrder };
  const fxRetry = new FxRetry({ fx, log, delaysMs: deps.fxRetryDelaysMs });
  const sync = createSync({
    db,
    gateway,
    fx,
    clock,
    log,
    unitOrder,
    retry: fxRetry,
    identity: { publicUrl: config.PUBLIC_URL, guildId: config.DISCORD_GUILD_ID, nameSource: config.OFFICER_NAME_SOURCE },
    onGrantsChanged: (discordId, grants, member) => hub.setAccess(discordId, liveAccess(member, grants)),
  });
  const ctx: AppContext = {
    config,
    db,
    gateway,
    fx,
    clock,
    log,
    oauth,
    sync,
    fxRetry,
    hub,
    liveUnits: new UnitsSnapshot(),
    avatars: new AvatarCache({ dir: join(resolve(config.UPLOAD_DIR), 'avatars'), log, fetch: deps.fetch }),
    background: new BackgroundTasks(log),
    unitOrder,
    grantDeps,
  };
  app.decorate('fredpd', ctx);

  // JSON with the raw text kept for HMAC (§C5 signs the exact bytes). A request with HMAC headers and no session is
  // verified before it is parsed (401, no parsing, for a forged one). Fastify's own parser then does the parsing,
  // with prototype-poisoning protection. Set up here, once ctx exists and before the routes below (which use the
  // root instance's parser; the plugins above add no JSON routes).
  const parseJson = app.getDefaultJsonParser('error', 'error');
  app.removeContentTypeParser('application/json');
  app.addContentTypeParser('application/json', { parseAs: 'string' }, (request, body, done) => {
    const raw = body as string;
    request.rawBody = raw;
    try {
      checkHmacBeforeParse(ctx, request, raw);
    } catch (err) {
      done(err as Error, undefined);
      return;
    }
    parseJson(request, raw, done);
  });

  registerAuthRoutes(app, ctx);
  registerAdminRoutes(app, ctx);
  registerAlertRoutes(app, ctx);
  registerInternalRoutes(app, ctx);
  registerUploadRoutes(app, ctx);
  registerAvatarRoutes(app, ctx);
  registerWsRoutes(app, ctx);
  registerPortalRoutes(app, ctx);
  await registerPortalStatic(app, ctx);

  // The SPA's client-side routes get index.html; everything else (API paths, missing files) the JSON 404.
  app.setNotFoundHandler((request, reply) => {
    if (isSpaRequest(request)) return sendPortalIndex(ctx, reply);
    return reply.code(404).send({ error: 'not_found' });
  });

  // API answers are per user and never cached by a browser or proxy.
  app.addHook('onSend', async (request, reply, payload) => {
    if (request.url.startsWith('/api/') && !reply.hasHeader('cache-control')) reply.header('cache-control', 'no-store');
    return payload;
  });

  app.addHook('onClose', async () => {
    fxRetry.close();
    hub.closeAll();
    await ctx.background.drain();
  });
  return app;
}
