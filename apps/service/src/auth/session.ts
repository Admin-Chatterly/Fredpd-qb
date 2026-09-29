// SPDX-License-Identifier: GPL-3.0-only
// Portal sessions (IMPLEMENTATION.md §4.6, docs/contracts.md §C10). The cookie fredpd_sid holds a random 256-bit
// token, signed with SESSION_SECRET (@fastify/cookie) so garbage cookies are rejected without a DB read; the table
// stores sha256(token) only. CSRF: a per-session random token, returned by GET /api/session, required as the
// x-csrf-token header on every write and compared in constant time (synchroniser token; SameSite=Lax on top).
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import type { Db } from '../db/client';
import { deleteSession, deleteSessionsOf, findSession, insertSession, purgeExpiredSessions } from '../db/repo';
import type { SessionRow } from '../db/repo';

export const SESSION_COOKIE = 'fredpd_sid';
export const SESSION_TTL_SECONDS = 7 * 24 * 60 * 60;

export type SessionInfo = SessionRow;

/** 32 random bytes, base64url (43 characters). */
export function newToken(): string {
  return randomBytes(32).toString('base64url');
}

export function hashToken(token: string): string {
  return createHash('sha256').update(token, 'utf8').digest('hex');
}

const TOKEN_RE = /^[A-Za-z0-9_-]{43}$/;

/**
 * A new session for a user. Sessions are one per user: every earlier session of this user ends here (so a stolen
 * cookie does not outlive a fresh login, and one user has one rate-limit budget). The caller closes their sockets.
 */
export async function createSession(db: Db, discordId: string, now: Date): Promise<{ token: string; session: SessionInfo }> {
  const token = newToken();
  const session: SessionInfo = {
    id: hashToken(token),
    discordId,
    citizenid: null,
    csrfToken: newToken(),
    // DATETIME has whole seconds; round down so the cookie never outlives the row.
    expiresAt: new Date(Math.floor(now.getTime() / 1000) * 1000 + SESSION_TTL_SECONDS * 1000),
  };
  await purgeExpiredSessions(db, now);
  await deleteSessionsOf(db, discordId);
  await insertSession(db, session);
  return { token, session };
}

/** The live session for a (verified, unsigned) cookie token, or null. */
export async function loadSession(db: Db, token: string | undefined, now: Date): Promise<SessionInfo | null> {
  if (!token || !TOKEN_RE.test(token)) return null;
  return findSession(db, hashToken(token), now);
}

export async function destroySession(db: Db, id: string, now: Date): Promise<void> {
  await deleteSession(db, id);
  await purgeExpiredSessions(db, now);
}

/** Constant-time comparison of the x-csrf-token header with the session's token. */
export function csrfMatches(session: SessionInfo, header: string | string[] | undefined): boolean {
  if (typeof header !== 'string' || header.length === 0) return false;
  const a = Buffer.from(header, 'utf8');
  const b = Buffer.from(session.csrfToken, 'utf8');
  return a.length === b.length && timingSafeEqual(a, b);
}
