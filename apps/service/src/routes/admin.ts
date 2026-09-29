// SPDX-License-Identifier: GPL-3.0-only
// Permissions admin API for the portal page "Behörigheter" (docs/contracts.md §C10, task 1.8).
import type { FastifyInstance } from 'fastify';
import { AdminRoleGrantsPutBodySchema, DiscordRoleIdParamSchema } from '@fredpd/types/actions';
import type { AdminRoleGrant, AdminRoleGrantsPutResponse, AdminRolesResponse } from '@fredpd/types/actions';
import { buildCatalog } from '../catalog';
import type { AppContext } from '../context';
import { listRoleGrants, listRoles, replaceRoleGrants } from '../db/repo';
import { HttpError, parseOr400 } from '../http/errors';
import { requirePerm, requireSession, sessionOf } from '../http/guards';

export const ADMIN_PERM = 'admin.permissions';

/**
 * Unit grants must name a unit of config/units.json (or `*`): a typo would give holders a unit no module knows. A
 * key the role already has is kept acceptable, so a unit removed from units.json does not block saving the role's
 * other rows (the admin can drop it in the same save).
 */
async function checkUnitKeys(ctx: AppContext, roleId: string, grants: readonly AdminRoleGrant[]): Promise<void> {
  const units = grants.filter((g) => g.grantType === 'unit' && g.grantKey !== '*' && !ctx.unitOrder.includes(g.grantKey));
  if (units.length === 0) return;
  const stored = new Set((await listRoleGrants(ctx.db, roleId)).filter((g) => g.grantType === 'unit').map((g) => g.grantKey));
  const unknown = units.find((g) => !stored.has(g.grantKey));
  if (unknown) throw new HttpError(400, 'invalid_body', `unknown unit ${unknown.grantKey}`);
}

export function registerAdminRoutes(app: FastifyInstance, ctx: AppContext): void {
  const perm = requirePerm(ctx, ADMIN_PERM);

  app.get('/api/admin/roles', { preHandler: [requireSession({ csrf: false }), perm] }, async (): Promise<AdminRolesResponse> => {
    const [roles, grants] = await Promise.all([listRoles(ctx.db), listRoleGrants(ctx.db)]);
    return { roles, grants, catalog: buildCatalog(ctx.unitOrder, grants) };
  });

  app.put(
    '/api/admin/roles/:discordRoleId/grants',
    { preHandler: [requireSession({ csrf: true }), perm] },
    async (request): Promise<AdminRoleGrantsPutResponse & { fxPending?: true }> => {
      const session = sessionOf(request);
      const { discordRoleId } = parseOr400(DiscordRoleIdParamSchema, request.params);
      const body = parseOr400(AdminRoleGrantsPutBodySchema, request.body);
      await checkUnitKeys(ctx, discordRoleId, body.grants);
      const saved = await replaceRoleGrants(ctx.db, discordRoleId, body.grants, {
        discordId: session.discordId,
        citizenid: session.citizenid,
      });
      if (!saved) throw new HttpError(404, 'not_found', 'role');
      // Committed: recompute every holder, refresh fredpd_grant_cache, and have FXServer re-fetch the online ones.
      // The save stands even if that fails. `fxPending: true` (additive to §C10's `{ ok, recomputed }`) tells the
      // page that FXServer has not confirmed yet: the service redelivers it (src/fx-retry.ts), or, when the Discord
      // gateway was not ready, the resync after it reconnects recomputes everyone online.
      let recomputed = 0;
      let delivered = false;
      try {
        ({ scheduled: recomputed, delivered } = await ctx.sync.recomputeRoleHolders(discordRoleId));
      } catch (err) {
        request.log.error({ err, discordRoleId }, 'recompute after a permissions save failed');
      }
      return delivered ? { ok: true, recomputed } : { ok: true, recomputed, fxPending: true };
    },
  );
}
