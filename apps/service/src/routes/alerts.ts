// SPDX-License-Identifier: GPL-3.0-only
// Portal alert list and units roster (docs/contracts.md §C13, task 3.5 service part). Both need a session and the
// grant mdt_page:alerts, resolved live on every request (a removed Discord role takes effect at once); the global
// limiter (60/min per session, src/app.ts) applies. Read only: fredpd_dispatch owns every write, so the portal gets
// the same Alert shape as the tablet (AlertListOutputSchema, UnitsPushSchema).
//
//   GET /api/alerts?filter=open|all&page=n  → { items: Alert[], total, page }  (50 per page, newest first)
//   GET /api/units                          → { units: UnitStatus[] }  newest `unitsChanged` roster, best effort;
//                                             header x-fredpd-units-received-at = ISO UTC of that event (absent
//                                             while the roster is the empty default) so the portal can show its age
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { AlertList } from '../db/alerts';
import { listAlerts, toIsoUtc } from '../db/alerts';
import type { AppContext } from '../context';
import { parseOr400 } from '../http/errors';
import { requireGrant, requireSession } from '../http/guards';
import type { UnitsPush } from '../ws/units-snapshot';

/**
 * Query of GET /api/alerts. The tablet's AlertListInputSchema also has 'mine', which needs the officer's citizenid;
 * a portal session has none it can prove, so the portal offers open and all only.
 */
export const AlertListQuerySchema = z.object({
  filter: z.enum(['open', 'all']).default('open'),
  page: z.coerce.number().int().min(1).max(10_000).default(1),
});

/** Response header of GET /api/units: when the roster being served arrived (ISO UTC, §C7). */
export const UNITS_RECEIVED_AT_HEADER = 'x-fredpd-units-received-at';

export function registerAlertRoutes(app: FastifyInstance, ctx: AppContext): void {
  const guards = { preHandler: [requireSession({ csrf: false }), requireGrant(ctx, 'mdt_page', 'alerts')] };

  app.get('/api/alerts', guards, async (request, reply): Promise<AlertList> => {
    const { filter, page } = parseOr400(AlertListQuerySchema, request.query);
    void reply.header('cache-control', 'no-store');
    const onInvalid = (id: number): void => {
      request.log.warn({ alertId: id }, 'alert row left out: not a valid Alert');
    };
    // COUNT(*) and the page SELECT share one snapshot (REPEATABLE READ takes it at the first read, the COUNT), so
    // `total` matches the rows the page was cut from. No `withConsistentSnapshot`: drizzle 0.45 joins it to
    // `read only` without the comma MariaDB needs, and the failed START leaks the pooled connection.
    return ctx.db.transaction((tx) => listAlerts(tx, filter, page, onInvalid), {
      isolationLevel: 'repeatable read',
      accessMode: 'read only',
    });
  });

  app.get('/api/units', guards, async (_request, reply): Promise<UnitsPush> => {
    void reply.header('cache-control', 'no-store');
    const receivedAt = toIsoUtc(ctx.liveUnits.receivedAt);
    if (receivedAt) void reply.header(UNITS_RECEIVED_AT_HEADER, receivedAt);
    return ctx.liveUnits.get();
  });
}
