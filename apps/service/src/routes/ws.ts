// SPDX-License-Identifier: GPL-3.0-only
// GET /ws — live events for the logged-in portal (docs/contracts.md §C6). The server only sends; messages from the
// client are ignored. Session required (401 before the upgrade); a browser Origin must be PUBLIC_URL's origin, so
// another site cannot open a socket with the user's cookie (cross-site WebSocket hijacking).
import type { FastifyInstance } from 'fastify';
import type { AppContext } from '../context';
import { HttpError } from '../http/errors';
import { sessionGrants, sessionOf } from '../http/guards';

declare module 'fastify' {
  interface FastifyRequest {
    /** Set by the /ws preValidation hook: the user may receive live events. */
    wsEligible?: boolean;
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
        request.wsEligible = member && grants.grants.length > 0;
      },
    },
    (socket, request) => {
      const session = sessionOf(request);
      const remove = ctx.hub.add(socket, session, request.wsEligible === true);
      socket.on('close', remove);
      socket.on('error', remove);
      socket.on('message', () => {
        // Server -> client only.
      });
    },
  );
}
