// SPDX-License-Identifier: GPL-3.0-only
// Live events for the portal (/ws; docs/contracts.md §C6). FXServer posts {type, payload} to /internal/events and
// the hub forwards it to every open socket of a logged-in officer. "Officer" = guild member with at least one
// allowed grant; it is decided when the socket opens and updated whenever that user's grants are recomputed, so a
// demoted user stops receiving events without reconnecting. Sockets of an expired or logged-out session are closed.
import type { InternalEvent } from '@fredpd/types/actions';

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

export class WsHub {
  private readonly clients = new Set<Client>();
  /** discordId -> may receive live events. */
  private readonly eligible = new Map<string, boolean>();

  constructor(private readonly now: () => Date) {}

  get size(): number {
    return this.clients.size;
  }

  /** Register an open socket; returns a function that unregisters it (call it on 'close'). */
  add(socket: HubSocket, session: { id: string; discordId: string; expiresAt: Date }, eligible: boolean): () => void {
    const client: Client = { socket, sessionId: session.id, discordId: session.discordId, expiresAt: session.expiresAt };
    this.clients.add(client);
    this.eligible.set(session.discordId, eligible);
    return () => {
      this.clients.delete(client);
      if (![...this.clients].some((c) => c.discordId === session.discordId)) this.eligible.delete(session.discordId);
    };
  }

  /** Grants of a user changed; only tracked users are stored. */
  setEligible(discordId: string, eligible: boolean): void {
    if (this.eligible.has(discordId)) this.eligible.set(discordId, eligible);
  }

  /** Send to every eligible open socket with a live session. Returns how many sockets got it. */
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
      if (c.socket.readyState !== OPEN || this.eligible.get(c.discordId) !== true) continue;
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

  closeAll(): void {
    for (const c of this.clients) c.socket.close(1001, 'server shutting down');
    this.clients.clear();
    this.eligible.clear();
  }
}
