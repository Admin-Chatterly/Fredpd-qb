// SPDX-License-Identifier: GPL-3.0-only
// Portal actions bridge (docs/modules/portal-api.md; IMPLEMENTATION.md §5.9, §7 tasks 7.1/7.2):
//   GET  /api/characters           session            → [{ citizenid, name }] (fredpd_identities.license ⋈ fredpd_persons)
//   POST /api/session/character    session + CSRF     { citizenid } (one of those) → stored in the session, audited
//   POST /api/mdt/:action          session + CSRF     body = action input → 200 action output (TABLET_ACTIONS zod)
//   GET  /share/:token             –                  Accept: application/json → share JSON; otherwise the SPA page
//   GET  /api/share/:token         –                  share JSON (same answer)
// /api/mdt forwards to FXServer POST /fredpd_mdt/portal, HMAC-signed, where fredpd_mdt runs the tablet dispatcher in
// portal mode for a portal actor (fredpd_core server/virtual.lua): grants = the set resolved here for the Discord id,
// actor = the session's character, audit meta.via = 'portal'. Errors are `{ error: <MDT_ERROR_CODES>, reason? }`:
//   400 validation · 401 unauthorized (no session) · 403 unauthorized (grant, character, reason 'portal' for world
//   actions) · 403 csrf (the service's CSRF code, which the portal re-reads its session on) · 404 not_found (and every
//   refusal of an intel action, §C15) · 429 rate_limited · 503 unavailable (FXServer or Discord unreachable).
import { randomBytes } from 'node:crypto';
import type { FastifyError, FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { z } from 'zod';
import { CitizenIdSchema } from '@fredpd/types/actions';
import { hasGrant } from '@fredpd/types/grants';
import type { GrantSet } from '@fredpd/types/grants';
import { MDT_ERROR_CODES } from '@fredpd/types/mdt';
import { MDT_PAGE_KEYS } from '@fredpd/types/mdtPages';
import { csrfMatches } from '../auth/session';
import type { SessionInfo } from '../auth/session';
import type { AppContext } from '../context';
import { listCharacters, ownsCharacter, setSessionCitizenid, writeAudit } from '../db/repo';
import { HttpError, parseOr400 } from '../http/errors';
import { requireSession, sessionGrants, sessionOf } from '../http/guards';
import { actionDef, isIntelAction, isPortalAction } from '../portal/actions';
import { fromLua } from '../portal/lua-json';
import { sendPortalIndex } from './static';

type MdtErrorCode = (typeof MDT_ERROR_CODES)[number];
const MDT_CODES: ReadonlySet<string> = new Set(MDT_ERROR_CODES);
const STATUS: Record<MdtErrorCode, number> = { validation: 400, unauthorized: 403, not_found: 404, rate_limited: 429, unavailable: 503 };
const REASON_RE = /^[A-Za-z_]{1,32}$/;

/** Report bodies (100 000 code points) need more than the default 256 KB; fredpd_mdt's route takes 512 KB. */
export const MDT_BODY_LIMIT = 448 * 1024;
export const SHARE_TOKEN_RE = /^[A-Za-z0-9_-]{43}$/;
/** Per IP (share viewers have no session). A token is 256 bits, so this only limits load, not guessing. */
export const SHARE_PER_MINUTE = 30;

export const CharacterSelectSchema = z.object({ citizenid: CitizenIdSchema }).strict();
export const CharacterSchema = z.object({ citizenid: CitizenIdSchema, name: z.string() });
export const CharacterListSchema = z.array(CharacterSchema);
export type Character = z.infer<typeof CharacterSchema>;

/** What the service posts to FXServer POST /fredpd_mdt/portal (signed, §C5). */
export type PortalFxBody =
  | { requestId: string; discordId: string; citizenid: string; grants: GrantSet; action: string; input: unknown }
  | { requestId: string; action: 'viewShare'; input: { token: string } };

/** An answer of the portal route, as fredpd_mdt/server/portal.lua sends it. */
const FxAnswerSchema = z.union([
  z.object({ ok: z.literal(true), data: z.unknown() }),
  z.object({ ok: z.literal(false), error: z.string(), reason: z.string().optional() }),
]);

class MdtReply extends Error {
  constructor(
    readonly status: number,
    readonly body: Record<string, string>,
  ) {
    super(body.error);
  }
}

function mdtError(code: MdtErrorCode, reason?: string, detail?: string): MdtReply {
  const body: Record<string, string> = { error: code };
  if (reason) body.reason = reason;
  if (detail) body.detail = detail;
  return new MdtReply(STATUS[code], body);
}

/** Refusal of an action: intel actions answer 404 for anything they refuse (§C15: existence never leaks). */
function refuse(action: string, code: MdtErrorCode, reason?: string): MdtReply {
  if (isIntelAction(action) && (code === 'unauthorized' || code === 'not_found')) return mdtError('not_found');
  return mdtError(code, reason);
}

const newRequestId = () => randomBytes(16).toString('hex');

/** Characters of a Discord user, as the portal shows them. */
export async function charactersFor(ctx: AppContext, discordId: string): Promise<Character[]> {
  const rows = await listCharacters(ctx.db, discordId);
  return rows.map((r) => ({ citizenid: r.citizenid, name: `${r.firstname} ${r.lastname}`.trim() || r.citizenid }));
}

/** At most one "output does not match its schema" warning per action and minute. */
const outputWarned = new Map<string, number>();

export function registerPortalRoutes(app: FastifyInstance, ctx: AppContext): void {
  const noStore = (reply: FastifyReply) => reply.header('cache-control', 'no-store');

  // ------------------------------------------------------------------------------------------------------------
  // Characters

  app.get('/api/characters', async (request, reply): Promise<Character[]> => {
    const session = sessionOf(request);
    noStore(reply);
    return charactersFor(ctx, session.discordId);
  });

  app.post('/api/session/character', { preHandler: requireSession({ csrf: true }) }, async (request) => {
    const session = sessionOf(request);
    const { citizenid } = parseOr400(CharacterSelectSchema, request.body);
    if (!(await ownsCharacter(ctx.db, session.discordId, citizenid))) throw new HttpError(403, 'forbidden', 'citizenid');
    if (session.citizenid !== citizenid) {
      await setSessionCitizenid(ctx.db, session.id, citizenid);
      await writeAudit(ctx.db, {
        action: 'auth.character',
        actorDiscord: session.discordId,
        actorCitizenid: citizenid,
        targetType: 'citizen',
        targetId: citizenid,
        meta: { via: 'portal', previous: session.citizenid },
      });
    }
    return { ok: true, citizenid };
  });

  // ------------------------------------------------------------------------------------------------------------
  // Actions

  /** Everything thrown before the handler (body parser, limits) in the MDT vocabulary. */
  const mdtErrorHandler = (error: FastifyError | Error, request: FastifyRequest, reply: FastifyReply) => {
    if (error instanceof MdtReply) return reply.code(error.status).send(error.body);
    if (error instanceof HttpError) {
      if (error.code === 'csrf') return reply.code(403).send({ error: 'csrf' });
      if (error.statusCode === 401) return reply.code(401).send({ error: 'unauthorized', reason: 'session' });
      if (error.statusCode === 429) return reply.code(429).send({ error: 'rate_limited' });
      if (error.statusCode === 503) return reply.code(503).send({ error: 'unavailable' });
      if (error.statusCode === 403) return reply.code(403).send({ error: 'unauthorized' });
      if (error.statusCode === 404) return reply.code(404).send({ error: 'not_found' });
      if (error.statusCode < 500) return reply.code(400).send({ error: 'validation' });
    }
    const status = (error as FastifyError).statusCode;
    if (status === 429) return reply.code(429).send({ error: 'rate_limited' });
    if (typeof status === 'number' && status >= 400 && status < 500) return reply.code(400).send({ error: 'validation' });
    request.log.error({ err: error }, 'portal action failed');
    return reply.code(503).send({ error: 'unavailable' });
  };

  app.post<{ Params: { action: string } }>(
    '/api/mdt/:action',
    { bodyLimit: MDT_BODY_LIMIT, errorHandler: mdtErrorHandler },
    async (request, reply) => {
      noStore(reply);
      const session = request.portalSession;
      if (!session) throw new MdtReply(401, { error: 'unauthorized', reason: 'session' });
      // Reads too (portal action contract): the token is only readable by our own origin.
      if (!csrfMatches(session, request.headers['x-csrf-token'])) return reply.code(403).send({ error: 'csrf' });

      const action = request.params.action;
      const def = actionDef(action);
      // reason 'action': the portal shows "not available yet" for an action the server does not know
      // (apps/portal NotAvailableYet, docs/modules/portal.md), instead of a generic validation error.
      if (!def) throw mdtError('validation', 'action', 'action');
      if (!isPortalAction(action)) throw refuse(action, 'unauthorized', 'portal');

      const citizenid = await selectedCharacter(ctx, session).catch((err: unknown) => {
        // §C15: an intel action never answers 403, not even for a missing character.
        if (err instanceof MdtReply && isIntelAction(action)) throw mdtError('not_found');
        throw err;
      });
      const { member, grants } = await sessionGrants(ctx, session);
      if (!member) throw refuse(action, 'unauthorized');
      // The tablet's entry gate (fredpd_mdt open.lua tablet.noGrant): no mdt_page grant, no MDT at all.
      if (!anyMdtPage(grants)) throw refuse(action, 'unauthorized', 'no_grant');
      if (def.grant && !hasGrant(grants, def.grant[0], def.grant[1])) throw refuse(action, 'unauthorized');

      const parsed = def.input.safeParse(request.body ?? {});
      if (!parsed.success) {
        const first = parsed.error.issues[0];
        throw mdtError('validation', undefined, first ? first.path.join('.').slice(0, 64) || '(root)' : undefined);
      }

      const body: PortalFxBody = { requestId: newRequestId(), discordId: session.discordId, citizenid, grants, action, input: parsed.data };
      const answer = await forward(ctx, request, body);
      if (!answer.ok) {
        const code: MdtErrorCode = MDT_CODES.has(answer.error) ? (answer.error as MdtErrorCode) : 'unavailable';
        const reason = answer.reason && REASON_RE.test(answer.reason) ? answer.reason : undefined;
        throw refuse(action, code, reason);
      }
      return outputOf(ctx, request, action, def.output, answer.data);
    },
  );

  // ------------------------------------------------------------------------------------------------------------
  // Share links (§4.6: no session; fredpd_records counts and audits every view)

  const shareJson = async (request: FastifyRequest<{ Params: { token: string } }>, reply: FastifyReply) => {
    noStore(reply);
    reply.header('x-robots-tag', 'noindex, nofollow');
    reply.header('referrer-policy', 'no-referrer');
    const token = request.params.token;
    if (!SHARE_TOKEN_RE.test(token)) return reply.code(404).send({ error: 'not_found' });
    const answer = await forward(ctx, request, { requestId: newRequestId(), action: 'viewShare', input: { token } }).catch((err: unknown) => {
      if (err instanceof MdtReply) return null;
      throw err;
    });
    if (!answer) return reply.code(503).send({ error: 'unavailable' });
    if (!answer.ok) {
      if (answer.error === 'not_found') return reply.code(404).send({ error: 'not_found' });
      return reply.code(503).send({ error: 'unavailable' });
    }
    return answer.data ?? {};
  };
  const shareLimit = { rateLimit: { max: SHARE_PER_MINUTE, timeWindow: '1 minute' } };

  app.get<{ Params: { token: string } }>('/api/share/:token', { config: shareLimit }, shareJson);
  app.get<{ Params: { token: string } }>('/share/:token', { config: shareLimit }, async (request, reply) => {
    if (wantsJson(request)) return shareJson(request, reply);
    reply.header('x-robots-tag', 'noindex, nofollow');
    reply.header('referrer-policy', 'no-referrer');
    return sendPortalIndex(ctx, reply);
  });
}

/** JSON when the client asks for it and not for HTML (the SPA's fetch sends `accept: application/json`). */
function wantsJson(request: FastifyRequest): boolean {
  const accept = String(request.headers.accept ?? '').toLowerCase();
  return accept.includes('application/json') && !accept.includes('text/html');
}

/** Does the set hold any mdt_page grant (the rule fredpd_mdt's Open applies before the tablet opens)? */
export function anyMdtPage(grants: GrantSet): boolean {
  return MDT_PAGE_KEYS.some((key) => hasGrant(grants, 'mdt_page', key));
}

/** The session's character, re-checked against the user's characters on every call (a sold/deleted character). */
async function selectedCharacter(ctx: AppContext, session: SessionInfo): Promise<string> {
  if (!session.citizenid) throw mdtError('unauthorized', 'no_character');
  if (!(await ownsCharacter(ctx.db, session.discordId, session.citizenid))) {
    await setSessionCitizenid(ctx.db, session.id, null);
    throw mdtError('unauthorized', 'no_character');
  }
  return session.citizenid;
}

/** FXServer round trip; 503 unavailable when it is down, slow, refuses the signature or answers garbage. */
async function forward(ctx: AppContext, request: FastifyRequest, body: PortalFxBody): Promise<z.infer<typeof FxAnswerSchema>> {
  const res = await ctx.fx.portal(body as unknown as Record<string, unknown>);
  if (!res.ok) {
    request.log.warn({ action: body.action, status: res.status, error: res.error }, 'portal action: FXServer unavailable');
    throw mdtError('unavailable');
  }
  const answer = FxAnswerSchema.safeParse(res.body);
  if (!answer.success) {
    request.log.warn({ action: body.action }, 'portal action: malformed FXServer answer');
    throw mdtError('unavailable');
  }
  return answer.data;
}

/**
 * The action's output: Lua's absent nulls and {}/[] restored from the schema, then parsed (unknown keys stripped).
 * An answer that still does not match is sent as restored (the tablet gets it unparsed too) with a warning, so a
 * schema drift shows in the log instead of breaking the page.
 */
function outputOf(ctx: AppContext, request: FastifyRequest, action: string, schema: z.ZodType, data: unknown): unknown {
  const restored = fromLua(schema, data);
  const parsed = schema.safeParse(restored);
  if (parsed.success) return parsed.data;
  const now = ctx.clock.now().getTime();
  if ((outputWarned.get(action) ?? -Infinity) < now - 60_000) {
    outputWarned.set(action, now);
    const issue = parsed.error.issues[0];
    request.log.warn({ action, path: issue?.path.join('.'), issue: issue?.message }, 'portal action output does not match its schema');
  }
  return restored;
}
