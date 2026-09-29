// SPDX-License-Identifier: GPL-3.0-only
// GET /ws — live events for the logged-in portal (docs/contracts.md §C6, §C13). The server only sends; messages from
// the client are ignored. Session required (401 before the upgrade); a browser Origin must be PUBLIC_URL's origin,
// so another site cannot open a socket with the user's cookie (cross-site WebSocket hijacking). A user whose grants
// allow no live event type (src/ws/events.ts: mdt_page:alerts) gets 403 instead of an idle socket.
import type { FastifyInstance } from 'fastify';
import type { AppContext } from '../context';
import { HttpError } from '../http/errors';
import { sessionGrants, sessionOf } from '../http/guards';
import { liveAccess, NO_LIVE_ACCESS } from '../ws/events';
import type { LiveAccess } from '../ws/events';

declare module 'fastify' {
  interface FastifyRequest {
    /** Set by the /ws preValidation hook: the live event types the user may receive. */
    wsAccess?: LiveAccess;
  }
}

export function registerWsRoutes(app: FastifyInstance, ctx: AppContext): void {
  const allowedOrigin = new URL(ctx.config.PUBLIC_URL).origin;

  app.get(
    '/ws',
    {
      websocket: true,
      preValidation: async (request) => {
        const session = sessionOf(request);
        const origin = request.headers.origin;
        if (origin !== undefined && origin !== allowedOrigin) throw new HttpError(403, 'forbidden', 'origin');
        const { member, grants } = await sessionGrants(ctx, session);
        const access = liveAccess(member, grants);
        if (access.size === 0) throw new HttpError(403, 'forbidden', 'no live events');
        request.wsAccess = access;
      },
    },
    (socket, request) => {
      const session = sessionOf(request);
      const remove = ctx.hub.add(socket, session, request.wsAccess ?? NO_LIVE_ACCESS);
      socket.on('close', remove);
      socket.on('error', remove);
      socket.on('message', () => {
        // Server -> client only.
      });
    },
  );
}
