// SPDX-License-Identifier: GPL-3.0-only
// Discord -> FredPD synchronisation (IMPLEMENTATION.md §4.1, §4.9, §5.9; tasks 1.7 and 1.7b, service side).
// Pure helpers (display name, avatar, diffs) plus the orchestration that writes the DB and pushes to FXServer. It
// only sees the DiscordGateway interface, so test/sync.test.ts drives it with a fake gateway and fake FXServer.
//
// Flows:
//   ready            -> (service start) import roles (upsert, soft-delete missing) -> FXServer /recompute (all), always
//   resynced         -> (guild caches reloaded: new gateway session / guild outage over) same as ready
//   role create/upd. -> upsert; a position change can move ranks -> /recompute the role's holders
//   role delete      -> soft delete -> /recompute (all online; the holders are no longer known)
//   member update    -> roles changed: resolve -> fredpd_grant_cache -> /grants push
//                       name/avatar changed: fredpd_officers display_name/avatar_url -> /officer push
//                       (bot.ts also reports user-level changes, global name / user avatar, as member updates)
//   member removed   -> resolve (now empty) -> cache -> /grants push
import type { GrantSet } from '@fredpd/types/grants';
import type { OfficerNameSource } from '../config';
import type { Clock } from '../clock';
import type { Db } from '../db/client';
import {
  listRoles, markRolesDeleted, updateOfficerIdentity, upsertRoles, writeAudit, writeGrantCache,
} from '../db/repo';
import type { OfficerIdentity, StoredRole } from '../db/repo';
import type { FxClient } from '../fx';
import { computeGrants, computeGrantsMany } from '../grants';
import type { MemberGrants } from '../grants';
import type { Logger } from '../log';
import type { DiscordGateway, GatewayEvents, GatewayMember, GatewayRole } from './gateway';

// ---------------------------------------------------------------------------------------------------------------
// Pure helpers

/** fredpd_officers.display_name is VARCHAR(100) utf8mb4: 100 code points (fredpd_core checks the same). */
export const MAX_NAME_CHARS = 100;

/** Trim, drop control characters, collapse whitespace, cap at 100 code points; empty -> null. */
export function cleanName(value: string | null | undefined): string | null {
  if (typeof value !== 'string') return null;
  // Control and format characters (zero-width, bidi overrides, BOM) and line/paragraph separators.
  const s = value.replace(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/gu, '').replace(/\s+/g, ' ').trim();
  if (s === '') return null;
  return [...s].slice(0, MAX_NAME_CHARS).join('');
}

/**
 * Officer display name per OFFICER_NAME_SOURCE (IMPLEMENTATION.md §4.9):
 *   discord_nick   server nickname -> global display name -> username
 *   discord_global global display name -> username
 *   character      null: the name is not taken from Discord (the service leaves display_name alone)
 */
export function resolveDisplayName(m: Pick<GatewayMember, 'nick' | 'globalName' | 'username'>, source: OfficerNameSource): string | null {
  if (source === 'character') return null;
  const order = source === 'discord_nick' ? [m.nick, m.globalName, m.username] : [m.globalName, m.username];
  for (const candidate of order) {
    const name = cleanName(candidate);
    if (name) return name;
  }
  return null;
}

/** Name to show for a portal user: like an officer, but never null (character mode falls back to Discord). */
export function portalDisplayName(m: Pick<GatewayMember, 'nick' | 'globalName' | 'username'>, source: OfficerNameSource): string {
  return resolveDisplayName(m, source === 'character' ? 'discord_nick' : source) ?? m.username;
}

const HASH_RE = /^(a_)?[0-9a-f]{32}$/;

export interface AvatarRef {
  /** Cache key, safe as part of a file name: g<hash> guild, u<hash> user, d<n> default avatar. */
  key: string;
  /** Discord CDN URL (PNG, 128 px); only the service fetches it (§4.9: the tablet never calls Discord). */
  cdnUrl: string;
}

/** Guild avatar (when names come from the server nickname) -> user avatar -> Discord's default avatar. */
export function avatarRef(m: Pick<GatewayMember, 'id' | 'avatar' | 'guildAvatar'>, guildId: string, source: OfficerNameSource): AvatarRef {
  if (source === 'discord_nick' && m.guildAvatar && HASH_RE.test(m.guildAvatar)) {
    return { key: `g${m.guildAvatar}`, cdnUrl: `https://cdn.discordapp.com/guilds/${guildId}/users/${m.id}/avatars/${m.guildAvatar}.png?size=128` };
  }
  if (m.avatar && HASH_RE.test(m.avatar)) {
    return { key: `u${m.avatar}`, cdnUrl: `https://cdn.discordapp.com/avatars/${m.id}/${m.avatar}.png?size=128` };
  }
  // Default avatar of the pomelo username system: (id >> 22) % 6.
  const index = /^\d{1,20}$/.test(m.id) ? Number((BigInt(m.id) >> 22n) % 6n) : 0;
  return { key: `d${index}`, cdnUrl: `https://cdn.discordapp.com/embed/avatars/${index}.png` };
}

/** The avatar URL stored in fredpd_officers and pushed to FXServer: this service's cached copy. */
export function officerAvatarUrl(publicUrl: string, discordId: string, ref: AvatarRef): string {
  return `${publicUrl}/avatar/${discordId}?v=${ref.key}`;
}

export interface IdentityOptions {
  publicUrl: string;
  guildId: string;
  nameSource: OfficerNameSource;
}

/** fredpd_officers identity columns for a member, or null in character mode. */
export function officerIdentity(m: GatewayMember, o: IdentityOptions): OfficerIdentity | null {
  const displayName = resolveDisplayName(m, o.nameSource);
  if (displayName === null) return null;
  return { displayName, avatarUrl: officerAvatarUrl(o.publicUrl, m.id, avatarRef(m, o.guildId, o.nameSource)) };
}

export function rolesChanged(before: GatewayMember | null, after: GatewayMember): boolean {
  if (!before) return true;
  const a = new Set(before.roleIds);
  return a.size !== new Set(after.roleIds).size || after.roleIds.some((id) => !a.has(id));
}

export function identityChanged(before: GatewayMember | null, after: GatewayMember, o: IdentityOptions): boolean {
  if (!before) return true;
  return (
    resolveDisplayName(before, o.nameSource) !== resolveDisplayName(after, o.nameSource) ||
    avatarRef(before, o.guildId, o.nameSource).key !== avatarRef(after, o.guildId, o.nameSource).key
  );
}

export interface RoleDiff {
  created: GatewayRole[];
  /** Changed name, colour or position, or back after being deleted. */
  updated: GatewayRole[];
  /** Stored, not deleted, gone from the guild. */
  deleted: string[];
}

export function diffRoles(stored: StoredRole[], guild: GatewayRole[]): RoleDiff {
  const byId = new Map(stored.map((r) => [r.discordRoleId, r]));
  const present = new Set(guild.map((r) => r.id));
  const diff: RoleDiff = { created: [], updated: [], deleted: [] };
  for (const r of guild) {
    const s = byId.get(r.id);
    if (!s) diff.created.push(r);
    else if (s.deleted || s.name !== r.name.slice(0, 100) || s.colour !== r.colour >>> 0 || s.position !== r.position) diff.updated.push(r);
  }
  for (const s of stored) if (!s.deleted && !present.has(s.discordRoleId)) diff.deleted.push(s.discordRoleId);
  return diff;
}

// ---------------------------------------------------------------------------------------------------------------
// Orchestration

export interface SyncDeps {
  db: Db;
  gateway: DiscordGateway;
  fx: FxClient;
  clock: Clock;
  log: Logger;
  unitOrder: string[];
  identity: IdentityOptions;
  /** Called after every recompute (the /ws hub re-checks who may receive live events). */
  onGrantsChanged?: (discordId: string, grants: GrantSet, member: boolean) => void;
}

export interface Sync extends GatewayEvents {
  /** Diff roles into fredpd_roles; FXServer /recompute (all) when something changed or `recomputeAll`. */
  importRoles(roles: GatewayRole[], opts?: { recomputeAll?: boolean }): Promise<RoleDiff>;
  recomputeAndPush(discordId: string): Promise<MemberGrants>;
  /** Recompute and cache every holder of a role, then ask FXServer to re-fetch them. Returns FXServer's count. */
  recomputeRoleHolders(roleId: string): Promise<number>;
  /**
   * Write the member's name/avatar to fredpd_officers and push it to FXServer. `force` pushes even when no row
   * changed (FXServer's in-memory name may be older than the DB), but only for officers: members with a
   * fredpd_officers row or at least one allowed grant.
   */
  syncIdentity(member: GatewayMember, opts?: { force?: boolean; grants?: GrantSet }): Promise<{ rows: number; changed: number; pushed: boolean }>;
}

const CACHE_CHUNK = 500;

export function createSync(deps: SyncDeps): Sync {
  const grantDeps = { db: deps.db, gateway: deps.gateway, clock: deps.clock, unitOrder: deps.unitOrder };

  const notify = (m: MemberGrants) => {
    try {
      deps.onGrantsChanged?.(m.discordId, m.grants, m.member);
    } catch (err) {
      deps.log.error({ err, component: 'sync' }, 'onGrantsChanged listener failed');
    }
  };

  async function auditRoles(diff: RoleDiff, via: string): Promise<void> {
    if (diff.created.length + diff.updated.length + diff.deleted.length === 0) return;
    await writeAudit(deps.db, {
      action: 'roles.sync',
      targetType: 'guild',
      targetId: deps.identity.guildId,
      meta: {
        via,
        created: diff.created.map((r) => ({ id: r.id, name: r.name })),
        updated: diff.updated.map((r) => ({ id: r.id, name: r.name, position: r.position })),
        deleted: diff.deleted,
      },
    });
  }

  async function importRoles(guildRoles: GatewayRole[], opts: { recomputeAll?: boolean } = {}): Promise<RoleDiff> {
    const diff = diffRoles(await listRoles(deps.db), guildRoles);
    await upsertRoles(deps.db, [...diff.created, ...diff.updated]);
    await markRolesDeleted(deps.db, diff.deleted);
    await auditRoles(diff, 'import');
    const changed = diff.created.length + diff.updated.length + diff.deleted.length;
    deps.log.info({ component: 'sync', roles: guildRoles.length, created: diff.created.length, updated: diff.updated.length, deleted: diff.deleted.length }, 'Discord roles imported');
    // Positions or deletions may have moved ranks and grants of anyone online; one request re-fetches them all.
    if (changed > 0 || opts.recomputeAll) await deps.fx.recompute();
    return diff;
  }

  async function recomputeAndPush(discordId: string): Promise<MemberGrants> {
    const result = await computeGrants(grantDeps, discordId);
    await writeGrantCache(deps.db, [{ discordId, grants: result.grants }]);
    notify(result);
    await deps.fx.pushGrants(discordId, result.grants);
    return result;
  }

  async function recomputeRoleHolders(roleId: string): Promise<number> {
    const holders = deps.gateway.membersWithRole(roleId);
    if (holders.length === 0) return 0;
    const results = await computeGrantsMany(grantDeps, holders);
    for (let i = 0; i < results.length; i += CACHE_CHUNK) {
      await writeGrantCache(deps.db, results.slice(i, i + CACHE_CHUNK).map((r) => ({ discordId: r.discordId, grants: r.grants })));
    }
    results.forEach(notify);
    const res = await deps.fx.recompute(holders);
    return res.ok && typeof res.body.scheduled === 'number' ? res.body.scheduled : 0;
  }

  async function syncIdentity(member: GatewayMember, opts: { force?: boolean; grants?: GrantSet } = {}) {
    const ident = officerIdentity(member, deps.identity);
    if (!ident) return { rows: 0, changed: 0, pushed: false };
    const { rows, changed } = await updateOfficerIdentity(deps.db, member.id, ident);
    let push = changed > 0;
    if (!push && opts.force) {
      const grants = opts.grants ?? (await computeGrants(grantDeps, member.id)).grants;
      push = rows > 0 || grants.grants.length > 0;
    }
    if (push) {
      const res = await deps.fx.pushOfficer(member.id, ident.displayName, ident.avatarUrl);
      return { rows, changed, pushed: res.ok };
    }
    return { rows, changed, pushed: false };
  }

  return {
    importRoles,
    recomputeAndPush,
    recomputeRoleHolders,
    syncIdentity,

    async ready(roles) {
      // Member role changes while the service was down were never pushed, and perms.lua does not re-fetch on its
      // own: every online player re-fetches (/internal/grants resolves live, refreshes fredpd_grant_cache and the
      // /ws eligibility, and re-syncs the officer name).
      await importRoles(roles, { recomputeAll: true });
    },

    async resynced(roles) {
      // Same gap after a gateway outage: changes made meanwhile were never delivered as events.
      await importRoles(roles, { recomputeAll: true });
    },

    async roleUpserted(role, before) {
      const [stored] = (await listRoles(deps.db)).filter((r) => r.discordRoleId === role.id);
      const diff = diffRoles(stored ? [stored] : [], [role]);
      if (diff.created.length + diff.updated.length === 0) return;
      await upsertRoles(deps.db, [role]);
      await auditRoles(diff, before ? 'update' : 'create');
      // Only the position (or a restore) can change what a holder resolves to: ranks follow role position.
      const moved = stored && (stored.deleted || stored.position !== role.position);
      if (moved) {
        const holders = deps.gateway.membersWithRole(role.id);
        if (holders.length > 0) await recomputeRoleHolders(role.id);
      }
    },

    async roleDeleted(roleId) {
      await markRolesDeleted(deps.db, [roleId]);
      await auditRoles({ created: [], updated: [], deleted: [roleId] }, 'delete');
      await deps.fx.recompute();
    },

    async memberUpdated(before, after) {
      let grants: GrantSet | undefined;
      let grantsPushed = false;
      if (rolesChanged(before, after)) {
        grants = (await recomputeAndPush(after.id)).grants;
        grantsPushed = true;
      }
      let identity = { rows: 0, changed: 0, pushed: false };
      if (identityChanged(before, after, deps.identity)) {
        identity = await syncIdentity(after, { force: true, grants });
      }
      return { grantsPushed, identity };
    },

    async memberRemoved(discordId) {
      return recomputeAndPush(discordId);
    },
  };
}
