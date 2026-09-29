// SPDX-License-Identifier: GPL-3.0-only
// Live events for the portal (/ws; docs/contracts.md §C6, §C13). FXServer posts {type, payload} to /internal/events
// and the hub forwards each event only to the sockets of users whose grants allow that event type (src/ws/events.ts:
// mdt_page:alerts for every current type). The access set is decided when the socket opens and replaced whenever
// that user's grants are recomputed, so a demoted user stops receiving events without reconnecting. Sockets of an
// expired or logged-out session are closed. At most MAX_SOCKETS_PER_USER sockets per Discord user: the oldest one
// is closed (4429) when another opens.
import type { InternalEvent } from '@fredpd/types/actions';
import { NO_LIVE_ACCESS } from './events';
import type { LiveAccess } from './events';

/** The part of a ws WebSocket the hub uses (lets tests pass a stub). */
export interface HubSocket {
  readonly readyState: number;
  send(data: string): void;
  close(code?: number, reason?: string): void;
}

interface Client {
  socket: HubSocket;
  sessionId: string;
  discordId: string;
  expiresAt: Date;
}

const OPEN = 1;
/** 4401: application-defined close code, "session ended" (the portal shows portal.sessionExpired). */
export const CLOSE_SESSION_ENDED = 4401;
/** 4429: closed because the same user opened more than MAX_SOCKETS_PER_USER sockets (the portal must not reconnect). */
export const CLOSE_TOO_MANY = 4429;
/** Tabs of one user; a new socket beyond this closes that user's oldest. */
export const MAX_SOCKETS_PER_USER = 5;

export class WsHub {
  private readonly clients = new Set<Client>();
  /** discordId -> event types the user may receive. */
  private readonly access = new Map<string, LiveAccess>();
  private readonly maxPerUser: number;

  constructor(
    private readonly now: () => Date,
    opts: { maxSocketsPerUser?: number } = {},
  ) {
    this.maxPerUser = Math.max(1, opts.maxSocketsPerUser ?? MAX_SOCKETS_PER_USER);
  }

  get size(): number {
    return this.clients.size;
  }

  /** Register an open socket; returns a function that unregisters it (call it on 'close'). */
  add(socket: HubSocket, session: { id: string; discordId: string; expiresAt: Date }, access: LiveAccess): () => void {
    const mine = [...this.clients].filter((c) => c.discordId === session.discordId);
    for (const old of mine.slice(0, Math.max(0, mine.length - this.maxPerUser + 1))) {
      this.clients.delete(old);
      old.socket.close(CLOSE_TOO_MANY, 'too many connections');
    }
    const client: Client = { socket, sessionId: session.id, discordId: session.discordId, expiresAt: session.expiresAt };
    this.clients.add(client);
    this.access.set(session.discordId, access);
    return () => {
      this.clients.delete(client);
      if (![...this.clients].some((c) => c.discordId === session.discordId)) this.access.delete(session.discordId);
    };
  }

  /** Grants of a user changed; only users with an open socket are tracked. */
  setAccess(discordId: string, access: LiveAccess): void {
    if (this.access.has(discordId)) this.access.set(discordId, access);
  }

  /** Event types a connected user may receive (tests, diagnostics). */
  accessOf(discordId: string): LiveAccess {
    return this.access.get(discordId) ?? NO_LIVE_ACCESS;
  }

  /** Send to every open socket with a live session whose user may receive this event type. Returns the count. */
  broadcast(event: InternalEvent): number {
    const data = JSON.stringify({ type: event.type, payload: event.payload ?? null });
    const now = this.now();
    let delivered = 0;
    for (const c of [...this.clients]) {
      if (c.expiresAt <= now) {
        this.clients.delete(c);
        c.socket.close(CLOSE_SESSION_ENDED, 'session expired');
        continue;
      }
      if (c.socket.readyState !== OPEN || this.access.get(c.discordId)?.has(event.type) !== true) continue;
      try {
        c.socket.send(data);
        delivered += 1;
      } catch {
        // A socket that fails mid-send is closing; its 'close' handler unregisters it.
      }
    }
    return delivered;
  }

  /** Close every socket of a session (logout). */
  closeSession(sessionId: string): void {
    for (const c of [...this.clients]) {
      if (c.sessionId === sessionId) {
        this.clients.delete(c);
        c.socket.close(CLOSE_SESSION_ENDED, 'logged out');
      }
    }
  }

  /** Close every socket of a user (a new login ended their earlier sessions). */
  closeUser(discordId: string): void {
    for (const c of [...this.clients]) {
      if (c.discordId === discordId) {
        this.clients.delete(c);
        c.socket.close(CLOSE_SESSION_ENDED, 'logged in again');
      }
    }
    this.access.delete(discordId);
  }

  closeAll(): void {
    for (const c of this.clients) c.socket.close(1001, 'server shutting down');
    this.clients.clear();
    this.access.clear();
  }
}
