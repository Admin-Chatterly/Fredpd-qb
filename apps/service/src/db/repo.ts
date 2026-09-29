// SPDX-License-Identifier: GPL-3.0-only
// Every SQL statement of the service. Routes and the Discord sync call these; nothing else builds queries.
// Writes that change what an officer may do or see are audited in the same transaction (fredpd_audit, §4.5).
// Not audited per row, as in fredpd_core (docs/modules/core.md "Audit exemption"): fredpd_grant_cache and
// fredpd_identities (caches of data audited at its source) and fredpd_sessions (login/logout are audited instead).
// Times (docs/contracts.md §C7): Date values are written as UTC by drizzle/mysql2; updated_at is set to
// UTC_TIMESTAMP() by every update()/onDuplicateKeyUpdate() through the schema's $onUpdate, changed or not, so the
// writers of tables with updated_at only touch rows that really change (callers pass diffRoles output, the officer
// identity update filters stale rows, markRolesDeleted skips deleted ones); SQL never uses the session clock
// (comparisons take the injected clock's Date).
import { and, eq, gt, inArray, sql } from 'drizzle-orm';
import type { GrantSet, GrantType, RoleGrantRow, RoleRow } from '@fredpd/types/grants';
import type { Db } from './client';
import { audit, grantCache, identities, officers, roleGrants, roles, sessions, uploads } from './schema';
import type { GatewayRole } from '../discord/gateway';

/** A transaction handle or the database itself. */
export type Tx = Parameters<Parameters<Db['transaction']>[0]>[0];
export type DbOrTx = Db | Tx;

// ---------------------------------------------------------------------------------------------------------------
// Audit

export interface AuditEntry {
  action: string;
  actorDiscord?: string | null;
  actorCitizenid?: string | null;
  targetType?: string | null;
  targetId?: string | null;
  meta?: unknown;
}

const ACTION_RE = /^[\w][\w.:-]{0,63}$/;
const MAX_META_BYTES = 16 * 1024; // same cap as fredpd_core/server/audit.lua

export async function writeAudit(db: DbOrTx, e: AuditEntry): Promise<void> {
  if (!ACTION_RE.test(e.action)) throw new Error(`invalid audit action ${JSON.stringify(e.action)}`);
  let meta = e.meta ?? null;
  if (meta !== null) {
    const bytes = Buffer.byteLength(JSON.stringify(meta), 'utf8');
    if (bytes > MAX_META_BYTES) meta = { truncated: true, bytes };
  }
  await db.insert(audit).values({
    action: e.action,
    actorDiscord: e.actorDiscord ?? null,
    actorCitizenid: e.actorCitizenid ?? null,
    targetType: e.targetType?.slice(0, 32) ?? null,
    targetId: e.targetId?.slice(0, 64) ?? null,
    meta,
  });
}

// ---------------------------------------------------------------------------------------------------------------
// Roles and grants

export interface StoredRole extends RoleRow {
  colour: number;
}

export async function listRoles(db: DbOrTx): Promise<StoredRole[]> {
  const rows = await db
    .select({
      discordRoleId: roles.discordRoleId,
      name: roles.name,
      colour: roles.colour,
      position: roles.position,
      deleted: roles.deleted,
    })
    .from(roles);
  return rows.sort((a, b) => b.position - a.position || (a.discordRoleId < b.discordRoleId ? -1 : 1));
}

export async function listRoleGrants(db: DbOrTx, roleId?: string): Promise<RoleGrantRow[]> {
  const q = db
    .select({
      discordRoleId: roleGrants.discordRoleId,
      grantType: roleGrants.grantType,
      grantKey: roleGrants.grantKey,
      effect: roleGrants.effect,
    })
    .from(roleGrants);
  const rows = roleId === undefined ? await q : await q.where(eq(roleGrants.discordRoleId, roleId));
  return rows.sort(
    (a, b) =>
      cmp(a.discordRoleId, b.discordRoleId) || cmp(a.grantType, b.grantType) || cmp(a.grantKey, b.grantKey),
  );
}

function cmp(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

/** Roles + grant rows, the DB half of grant resolution (docs/contracts.md §C2). */
export async function loadResolveRows(db: DbOrTx): Promise<{ roles: RoleRow[]; grants: RoleGrantRow[] }> {
  const [r, g] = await Promise.all([listRoles(db), listRoleGrants(db)]);
  return { roles: r.map(({ colour: _c, ...role }) => role), grants: g };
}

/**
 * Upsert guild roles and un-delete them. INSERT … ON DUPLICATE KEY UPDATE, never REPLACE: REPLACE deletes the row
 * and the FK cascade would wipe the role's grants (001_core.sql).
 */
export async function upsertRoles(db: DbOrTx, list: GatewayRole[]): Promise<void> {
  if (list.length === 0) return;
  await db
    .insert(roles)
    .values(list.map((r) => ({ discordRoleId: r.id, name: r.name.slice(0, 100), colour: r.colour >>> 0, position: r.position, deleted: false })))
    .onDuplicateKeyUpdate({
      set: {
        name: sql`VALUES(${roles.name})`,
        colour: sql`VALUES(${roles.colour})`,
        position: sql`VALUES(${roles.position})`,
        deleted: sql`VALUES(${roles.deleted})`,
      },
    });
}

/**
 * Soft delete: the row and its grants stay for the audit trail; resolution ignores deleted roles. Rows already
 * deleted are skipped, so their updated_at (moved by $onUpdate on every write) keeps the time of the real deletion.
 */
export async function markRolesDeleted(db: DbOrTx, ids: string[]): Promise<void> {
  if (ids.length === 0) return;
  await db.update(roles).set({ deleted: true }).where(and(inArray(roles.discordRoleId, ids), eq(roles.deleted, false)));
}

export async function getRole(db: DbOrTx, roleId: string): Promise<StoredRole | null> {
  const [row] = await db
    .select({ discordRoleId: roles.discordRoleId, name: roles.name, colour: roles.colour, position: roles.position, deleted: roles.deleted })
    .from(roles)
    .where(eq(roles.discordRoleId, roleId));
  return row ?? null;
}

export interface GrantInput {
  grantType: GrantType;
  grantKey: string;
  effect: 'allow' | 'deny';
}

/**
 * Replace a role's grant rows in one transaction and audit it as perms.update with the before/after rows
 * (docs/contracts.md §C10). Returns false when the role does not exist.
 */
export async function replaceRoleGrants(
  db: Db,
  roleId: string,
  next: GrantInput[],
  actor: { discordId: string; citizenid: string | null },
): Promise<{ before: GrantInput[]; after: GrantInput[] } | false> {
  return db.transaction(async (tx) => {
    // Lock the role row so two concurrent saves serialise instead of interleaving delete/insert.
    const [role] = await tx
      .select({ id: roles.discordRoleId })
      .from(roles)
      .where(eq(roles.discordRoleId, roleId))
      .for('update');
    if (!role) return false;
    const before = (await listRoleGrants(tx, roleId)).map(({ grantType, grantKey, effect }) => ({ grantType, grantKey, effect }));
    await tx.delete(roleGrants).where(eq(roleGrants.discordRoleId, roleId));
    if (next.length > 0) {
      await tx.insert(roleGrants).values(next.map((g) => ({ discordRoleId: roleId, ...g })));
    }
    const after = [...next].sort((a, b) => cmp(a.grantType, b.grantType) || cmp(a.grantKey, b.grantKey));
    await writeAudit(tx, {
      action: 'perms.update',
      actorDiscord: actor.discordId,
      actorCitizenid: actor.citizenid,
      targetType: 'role',
      targetId: roleId,
      meta: { before: before.map(grantString), after: after.map(grantString) },
    });
    return { before, after };
  });
}

function grantString(g: GrantInput): string {
  return `${g.effect === 'deny' ? '-' : '+'}${g.grantType}:${g.grantKey}`;
}

// ---------------------------------------------------------------------------------------------------------------
// Grant cache (fallback for FXServer when the service is down)

/**
 * Upsert cache rows. A row only moves forward in time: a set whose computedAt is older than the stored one (a push
 * that lost a race with a newer resolution) leaves the row alone. `computed_at` is DATETIME (seconds), so within
 * one second the last write wins (tie rule). The same rule is in fredpd_core perms.lua (CACHE_UPSERT_SQL). The two
 * assignments do not depend on their order: `VALUES(computed_at) >= GREATEST(old, new)` iff `new >= old`.
 */
export async function writeGrantCache(db: DbOrTx, entries: { discordId: string; grants: GrantSet }[]): Promise<void> {
  if (entries.length === 0) return;
  await db
    .insert(grantCache)
    .values(entries.map((e) => ({ discordId: e.discordId, grants: e.grants, computedAt: new Date(e.grants.computedAt) })))
    .onDuplicateKeyUpdate({
      set: {
        grants: sql`IF(VALUES(${grantCache.computedAt}) >= ${grantCache.computedAt}, VALUES(${grantCache.grants}), ${grantCache.grants})`,
        computedAt: sql`GREATEST(${grantCache.computedAt}, VALUES(${grantCache.computedAt}))`,
      },
    });
}

/** Every Discord id with a cache row (sync.refreshGrantCache re-resolves them on service start). */
export async function listGrantCacheIds(db: DbOrTx): Promise<string[]> {
  const rows = await db.select({ discordId: grantCache.discordId }).from(grantCache).orderBy(grantCache.discordId);
  return rows.map((r) => r.discordId);
}

// ---------------------------------------------------------------------------------------------------------------
// Identities

/** Record a portal login: create the identity row or bump last_seen. */
export async function touchIdentity(db: DbOrTx, discordId: string, now: Date): Promise<void> {
  await db.insert(identities).values({ discordId, lastSeen: now }).onDuplicateKeyUpdate({ set: { lastSeen: now } });
}

// ---------------------------------------------------------------------------------------------------------------
// Sessions

export interface SessionRow {
  id: string;
  discordId: string;
  citizenid: string | null;
  csrfToken: string;
  expiresAt: Date;
}

export async function insertSession(db: DbOrTx, row: SessionRow): Promise<void> {
  await db.insert(sessions).values(row);
}

export async function findSession(db: DbOrTx, id: string, now: Date): Promise<SessionRow | null> {
  const [row] = await db
    .select({ id: sessions.id, discordId: sessions.discordId, citizenid: sessions.citizenid, csrfToken: sessions.csrfToken, expiresAt: sessions.expiresAt })
    .from(sessions)
    .where(and(eq(sessions.id, id), gt(sessions.expiresAt, now)));
  return row ?? null;
}

export async function deleteSession(db: DbOrTx, id: string): Promise<void> {
  await db.delete(sessions).where(eq(sessions.id, id));
}

/** Housekeeping on login/logout instead of a timer; bounded so one login never does a large delete. */
export async function purgeExpiredSessions(db: DbOrTx, now: Date): Promise<void> {
  await db.execute(sql`DELETE FROM ${sessions} WHERE ${sessions.expiresAt} <= ${now} LIMIT 500`);
}

// ---------------------------------------------------------------------------------------------------------------
// Officers (identity columns only; FXServer creates the rows, IMPLEMENTATION.md §4.9)

export interface OfficerIdentity {
  displayName: string;
  avatarUrl: string | null;
}

/**
 * Set display_name/avatar_url on every character row of a Discord user. Returns how many rows exist and how many
 * changed (0 changed = nothing to push or audit).
 */
export async function updateOfficerIdentity(db: Db, discordId: string, next: OfficerIdentity): Promise<{ rows: number; changed: number }> {
  return db.transaction(async (tx) => {
    const current = await tx
      .select({ citizenid: officers.citizenid, displayName: officers.displayName, avatarUrl: officers.avatarUrl })
      .from(officers)
      .where(eq(officers.discordId, discordId))
      .for('update');
    const stale = current.filter((o) => o.displayName !== next.displayName || o.avatarUrl !== next.avatarUrl);
    if (stale.length > 0) {
      await tx
        .update(officers)
        .set({ displayName: next.displayName, avatarUrl: next.avatarUrl })
        .where(and(eq(officers.discordId, discordId), inArray(officers.citizenid, stale.map((o) => o.citizenid))));
      await writeAudit(tx, {
        action: 'officer.identity',
        targetType: 'discord',
        targetId: discordId,
        meta: { displayName: next.displayName, previous: [...new Set(stale.map((o) => o.displayName))], citizenids: stale.map((o) => o.citizenid) },
      });
    }
    return { rows: current.length, changed: stale.length };
  });
}

// ---------------------------------------------------------------------------------------------------------------
// Uploads

export interface UploadRow {
  id: string;
  fileName: string;
  mime: string;
  sizeBytes: number;
  sha256: string;
  source: 'portal' | 'game';
  uploaderDiscord: string | null;
  uploaderCitizenid: string | null;
}

export async function insertUpload(db: Db, row: UploadRow): Promise<void> {
  await db.transaction(async (tx) => {
    await tx.insert(uploads).values(row);
    await writeAudit(tx, {
      action: 'upload.create',
      actorDiscord: row.uploaderDiscord,
      actorCitizenid: row.uploaderCitizenid,
      targetType: 'upload',
      targetId: row.id,
      meta: { mime: row.mime, size: row.sizeBytes, source: row.source },
    });
  });
}
