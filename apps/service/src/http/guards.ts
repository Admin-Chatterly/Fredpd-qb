// SPDX-License-Identifier: GPL-3.0-only
// preHandler guards: portal session (+ CSRF on writes), perm checks from live grants, and HMAC for /internal/*.
import type { FastifyReply, FastifyRequest } from 'fastify';
import { hasGrant } from '@fredpd/types/grants';
import type { GrantSet } from '@fredpd/types/grants';
import { CSRF_HEADER } from '@fredpd/types/actions';
import { HMAC_SIG_HEADER, HMAC_TS_HEADER, verifySignature } from '@fredpd/types/hmac';
import { csrfMatches } from '../auth/session';
import type { SessionInfo } from '../auth/session';
import { unixSeconds } from '../clock';
import type { AppContext } from '../context';
import { computeGrants, GatewayNotReadyError } from '../grants';
import { HttpError } from './errors';

type Guard = (request: FastifyRequest, reply: FastifyReply) => Promise<void>;

/** The request's session; throws 401 when there is none. */
export function sessionOf(request: FastifyRequest): SessionInfo {
  if (!request.portalSession) throw new HttpError(401, 'unauthenticated');
  return request.portalSession;
}

/** Throws 403 csrf unless the x-csrf-token header matches the session. */
export function checkCsrf(request: FastifyRequest, session: SessionInfo): void {
  if (!csrfMatches(session, request.headers[CSRF_HEADER])) throw new HttpError(403, 'csrf');
}

export function requireSession(opts: { csrf: boolean }): Guard {
  return async (request) => {
    const session = sessionOf(request);
    if (opts.csrf) checkCsrf(request, session);
  };
}

/** Live grants of the session user; 503 while the Discord gateway is not ready. */
export async function sessionGrants(ctx: AppContext, session: SessionInfo): Promise<{ member: boolean; grants: GrantSet }> {
  try {
    return await computeGrants(ctx.grantDeps, session.discordId);
  } catch (err) {
    if (err instanceof GatewayNotReadyError) throw new HttpError(503, 'unavailable', 'discord');
    throw err;
  }
}

/**
 * Requires `perm:<key>` in the user's live grants, else 403 (docs/contracts.md §C10). Intel routes must answer 404
 * instead (IMPLEMENTATION.md §5.9); they get their own guard when they are built.
 */
export function requirePerm(ctx: AppContext, key: string): Guard {
  return async (request) => {
    const { member, grants } = await sessionGrants(ctx, sessionOf(request));
    if (!member || !hasGrant(grants, 'perm', key)) throw new HttpError(403, 'forbidden');
  };
}

/**
 * Headers a reverse proxy or tunnel adds (cloudflared, Caddy, nginx). FXServer's signedFetch sends none of them, so
 * their presence means the request came through the public side even when the socket peer is loopback.
 */
const FORWARDING_HEADERS = ['x-forwarded-for', 'x-forwarded-host', 'x-forwarded-proto', 'forwarded', 'x-real-ip', 'cf-connecting-ip', 'cf-ray', 'true-client-ip', 'via'];

function isLoopbackAddress(address: string | undefined): boolean {
  if (!address) return false;
  return address === '::1' || /^(::ffff:)?127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/i.test(address);
}

/** True when the TCP peer is loopback and no proxy forwarded the request (FXServer on the same host, §C6). */
export function isDirectLoopback(request: FastifyRequest): boolean {
  if (!isLoopbackAddress(request.socket?.remoteAddress)) return false;
  return !FORWARDING_HEADERS.some((h) => request.headers[h] !== undefined);
}

/**
 * onRequest guard for FXServer-only routes (/internal/*): 404, as if the route did not exist, unless the request
 * came straight from loopback. docs/hosting.md §7 blocks /internal at Caddy and the Cloudflare edge too; this keeps
 * it closed when the tunnel points straight at the service (task 7.1) or a proxy rule is missing.
 */
export async function requireLoopback(request: FastifyRequest): Promise<void> {
  if (!isDirectLoopback(request)) throw new HttpError(404, 'not_found');
}

export function hasHmacHeaders(request: FastifyRequest): boolean {
  return typeof request.headers[HMAC_TS_HEADER] === 'string' || typeof request.headers[HMAC_SIG_HEADER] === 'string';
}

/**
 * /internal is reachable from the internet (Cloudflare Tunnel), so rejections are logged at most once per interval
 * with a count of the ones suppressed in between, like fredpd_core http.js does on the game port.
 */
export const HMAC_REJECT_LOG_INTERVAL_MS = 10_000;
const rejectLogState = new WeakMap<AppContext, { last: number; suppressed: number }>();

function rejectHmac(ctx: AppContext, request: FastifyRequest, reason: string): never {
  let state = rejectLogState.get(ctx);
  if (!state) {
    state = { last: -Infinity, suppressed: 0 };
    rejectLogState.set(ctx, state);
  }
  const now = ctx.clock.now().getTime();
  if (now - state.last < HMAC_REJECT_LOG_INTERVAL_MS) {
    state.suppressed += 1;
  } else {
    request.log.warn({ reason, method: request.method, url: request.url, suppressedSinceLast: state.suppressed }, 'HMAC rejected');
    state.last = now;
    state.suppressed = 0;
  }
  throw new HttpError(401, 'unauthorized');
}

function verifyRequest(ctx: AppContext, request: FastifyRequest, rawBody: string) {
  const ts = request.headers[HMAC_TS_HEADER];
  const sig = request.headers[HMAC_SIG_HEADER];
  return verifySignature({
    secret: ctx.config.FREDPD_HMAC_SECRET,
    ts: typeof ts === 'string' ? ts : null,
    sig: typeof sig === 'string' ? sig : null,
    rawBody,
    nowSeconds: unixSeconds(ctx.clock),
  });
}

/**
 * The part of the §C5 check that needs no body (both headers well-formed, timestamp within the skew), for the
 * onRequest hook of a route with a large body: such a request is refused before its body is read. The JSON parser
 * then verifies the signature before parsing (checkHmacBeforeParse), and requireHmac once more afterwards.
 */
export function precheckHmacHeaders(ctx: AppContext, request: FastifyRequest): void {
  const result = verifyRequest(ctx, request, '');
  if (!result.ok && result.reason !== 'signature') rejectHmac(ctx, request, result.reason);
}

/**
 * For the JSON body parser (src/app.ts): a request that carries HMAC headers and no portal session claims to be
 * FXServer, so its signature is checked over the raw text before JSON.parse runs. An unauthenticated caller gets 401
 * without its body being parsed (not a 400 that shows how far it got). Throws HttpError 401, logged throttled.
 * requireHmac on the route stays the authoritative check.
 */
export function checkHmacBeforeParse(ctx: AppContext, request: FastifyRequest, rawBody: string): void {
  if (request.portalSession || !hasHmacHeaders(request)) return;
  const result = verifyRequest(ctx, request, rawBody);
  if (!result.ok) rejectHmac(ctx, request, result.reason);
}

/**
 * HMAC over the raw body (§C5): 401 `{ error: 'unauthorized' }` on a missing, skewed or wrong signature. A GET has
 * no body and is signed with the empty string. Any other method must carry a body the app kept raw (JSON, see the
 * parser in src/app.ts): a text/plain or multipart body is refused instead of being checked as the empty string,
 * which a GET signature from the same second would match.
 */
export function requireHmac(ctx: AppContext): Guard {
  return async (request) => {
    const bodyless = request.method === 'GET' || request.method === 'HEAD';
    if (!bodyless && request.rawBody === undefined) rejectHmac(ctx, request, 'body');
    const result = verifyRequest(ctx, request, request.rawBody ?? '');
    if (!result.ok) rejectHmac(ctx, request, result.reason);
  };
}
