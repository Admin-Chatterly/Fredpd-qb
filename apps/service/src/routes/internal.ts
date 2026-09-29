// SPDX-License-Identifier: GPL-3.0-only
// /internal/* — called by FXServer (fredpd_core signedFetch), HMAC-signed (docs/contracts.md §C5, §C6). FXServer
// reaches the service on loopback (§C6, docs/hosting.md §7), so a request that did not come straight from loopback
// (another address, or any proxy forwarding header: tunnel, Caddy) is answered 404 before anything else. A captured
// signature therefore cannot be replayed from outside the host (§C5 does not sign method or path; see
// docs/modules/service.md).
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { DiscordIdSchema, InternalEventSchema } from '@fredpd/types/actions';
import type { GrantsResponse } from '@fredpd/types/actions';
import type { AppContext } from '../context';
import { writeGrantCache } from '../db/repo';
import { computeGrants, GatewayNotReadyError } from '../grants';
import { HttpError, parseOr400 } from '../http/errors';
import { requireHmac, requireLoopback } from '../http/guards';
import { checkInternalEvent, liveAccess } from '../ws/events';
import type { UnitsPush } from '../ws/units-snapshot';

/** FXServer is one trusted caller that may burst (a restart re-fetches every online player); HMAC gates it. */
const INTERNAL_RATE = { max: 1200, timeWindow: '1 minute' };

const ParamsSchema = z.object({ discordId: DiscordIdSchema });

export function registerInternalRoutes(app: FastifyInstance, ctx: AppContext): void {
  const hmac = requireHmac(ctx);
  // onRequest: before the body is read and before the rate limiter (whose hook the plugin appends after this one).
  const opts = { onRequest: requireLoopback, preHandler: hmac, config: { rateLimit: INTERNAL_RATE } };

  app.get('/internal/ping', opts, async () => ({
    ok: true,
    discord: ctx.gateway.isReady(),
    subscribers: ctx.hub.size,
  }));

  app.get('/internal/grants/:discordId', opts, async (request) => {
    const { discordId } = parseOr400(ParamsSchema, request.params);
    let result;
    try {
      result = await computeGrants(ctx.grantDeps, discordId);
    } catch (err) {
      // 503, not an empty set: FXServer then falls back to fredpd_grant_cache (perms.lua) instead of storing
      // "no grants" for everyone who joins while the bot is still connecting.
      if (err instanceof GatewayNotReadyError) throw new HttpError(503, 'unavailable', 'discord');
      throw err;
    }
    await writeGrantCache(ctx.db, [{ discordId, grants: result.grants }]);
    ctx.hub.setAccess(discordId, liveAccess(result.member, result.grants));

    // A player is joining (or FXServer re-fetches): make sure FXServer has the Discord name before the character
    // loads and fredpd_core creates the fredpd_officers row (§4.9). After the response, officers only.
    const member = result.member ? ctx.gateway.getMember(discordId) : null;
    if (member) {
      const grants = result.grants;
      ctx.background.run('officer-identity', () => ctx.sync.syncIdentity(member, { force: true, grants }));
    }
    const body: GrantsResponse = { discordId, member: result.member, grants: result.grants };
    return body;
  });

  app.post('/internal/events', opts, async (request) => {
    const checked = checkInternalEvent(parseOr400(InternalEventSchema, request.body));
    if (!checked.ok) throw new HttpError(400, 'invalid_body', checked.detail);
    // Kept for GET /api/units (only a payload that passed UnitsPushSchema above gets here).
    if (checked.event.type === 'unitsChanged') ctx.liveUnits.set(checked.event.payload as UnitsPush, ctx.clock.now());
    return { ok: true as const, delivered: ctx.hub.broadcast(checked.event) };
  });
}
