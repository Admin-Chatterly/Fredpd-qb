// SPDX-License-Identifier: GPL-3.0-only
// Everything a route needs, built once by buildApp (src/app.ts) and reachable as app.fredpd.
import type { AvatarCache } from './avatar';
import type { DiscordOAuth } from './auth/oauth';
import type { SessionInfo } from './auth/session';
import type { Clock } from './clock';
import type { Config } from './config';
import type { Db } from './db/client';
import type { DiscordGateway } from './discord/gateway';
import type { Sync } from './discord/sync';
import type { FxClient } from './fx';
import type { FxRetry } from './fx-retry';
import type { GrantDeps } from './grants';
import type { Logger } from './log';
import type { WsHub } from './ws/hub';

/**
 * Work that runs after the response (officer name push on join). Tracked so shutdown and tests can wait for it
 * instead of racing it.
 */
export class BackgroundTasks {
  private readonly pending = new Set<Promise<unknown>>();

  constructor(private readonly log: Logger) {}

  run(name: string, fn: () => Promise<unknown>): void {
    const p = fn()
      .catch((err: unknown) => this.log.error({ err, task: name }, 'background task failed'))
      .finally(() => this.pending.delete(p));
    this.pending.add(p);
  }

  async drain(): Promise<void> {
    while (this.pending.size > 0) await Promise.allSettled([...this.pending]);
  }
}

export interface AppContext {
  config: Config;
  db: Db;
  gateway: DiscordGateway;
  fx: FxClient;
  clock: Clock;
  log: Logger;
  oauth: DiscordOAuth;
  sync: Sync;
  /** Redelivers grant changes FXServer missed (src/fx-retry.ts). */
  fxRetry: FxRetry;
  hub: WsHub;
  avatars: AvatarCache;
  background: BackgroundTasks;
  unitOrder: string[];
  grantDeps: GrantDeps;
}

declare module 'fastify' {
  interface FastifyInstance {
    fredpd: AppContext;
  }
  interface FastifyRequest {
    /** Validly signed fredpd_sid token (onRequest, no DB read yet); the rate limiter keys on it. */
    sessionToken: string | undefined;
    /** Live portal session from the fredpd_sid cookie (loaded in preParsing, after the rate limiter), or null. */
    portalSession: SessionInfo | null;
    /** Raw request body as received (JSON bodies), for HMAC verification (§C5). */
    rawBody: string | undefined;
  }
}
