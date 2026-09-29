// SPDX-License-Identifier: GPL-3.0-only
// Grants of a Discord user = resolveGrants(member roles from the gateway, role/grant rows from the DB)
// (docs/contracts.md §C2, IMPLEMENTATION.md §4.1). One resolver for /internal/grants, the portal session, the admin
// recompute and the Discord member-update push.
import { emptyGrantSet, resolveGrants } from '@fredpd/types/grants';
import type { GrantSet, RoleGrantRow, RoleRow } from '@fredpd/types/grants';
import type { Clock } from './clock';
import type { Db } from './db/client';
import { loadResolveRows } from './db/repo';
import type { DiscordGateway } from './discord/gateway';

export interface GrantDeps {
  db: Db;
  gateway: DiscordGateway;
  clock: Clock;
  unitOrder: string[];
}

export interface MemberGrants {
  discordId: string;
  /** In the Discord guild. A non-member gets the empty set. */
  member: boolean;
  grants: GrantSet;
}

/** Thrown when the gateway has not cached the guild yet: an answer now would wrongly be "no grants". */
export class GatewayNotReadyError extends Error {
  override name = 'GatewayNotReadyError';
  constructor() {
    super('Discord gateway is not ready');
  }
}

/** Resolve with rows already loaded (one DB read for many members). */
export function resolveFor(
  deps: Pick<GrantDeps, 'gateway' | 'clock' | 'unitOrder'>,
  rows: { roles: RoleRow[]; grants: RoleGrantRow[] },
  discordId: string,
): MemberGrants {
  const member = deps.gateway.getMember(discordId);
  const now = deps.clock.now();
  if (!member) return { discordId, member: false, grants: emptyGrantSet(now) };
  const grants = resolveGrants(
    { memberRoleIds: member.roleIds, roles: rows.roles, grants: rows.grants, unitOrder: deps.unitOrder },
    now,
  );
  return { discordId, member: true, grants };
}

export async function computeGrants(deps: GrantDeps, discordId: string): Promise<MemberGrants> {
  if (!deps.gateway.isReady()) throw new GatewayNotReadyError();
  return resolveFor(deps, await loadResolveRows(deps.db), discordId);
}

export async function computeGrantsMany(deps: GrantDeps, discordIds: string[]): Promise<MemberGrants[]> {
  if (!deps.gateway.isReady()) throw new GatewayNotReadyError();
  if (discordIds.length === 0) return [];
  const rows = await loadResolveRows(deps.db);
  return [...new Set(discordIds)].map((id) => resolveFor(deps, rows, id));
}
