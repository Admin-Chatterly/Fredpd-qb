// SPDX-License-Identifier: GPL-3.0-only
// Redelivery of grant changes that did not reach FXServer. Every fx call has a 3 s deadline and never throws
// (src/fx.ts), so a `/grants` push or `/recompute` that times out, meets a network error or a 5xx would otherwise
// only be logged, and online players would keep revoked grants until they rejoin.
//
// A failed push or recompute marks its Discord ids (or "everyone online") as pending. Pending ids are redelivered
// as one `/recompute { discordIds }` (or `{}`), which makes FXServer re-fetch the live set from /internal/grants,
// so a retry can never deliver an outdated set. Retries are one-shot timers after 2 s, 10 s and 30 s, armed only
// while something is pending (no idle polling). After the last one the ids stay pending and go out with the next
// FX call that succeeds, or with the next failure's retry. 4xx answers are not retried (a request FXServer refused
// will be refused again; fx.ts logs them).
import type { FxClient, FxResult } from './fx';
import { MAX_RECOMPUTE_IDS } from './fx';
import type { Logger } from './log';

export const FX_RETRY_DELAYS_MS: readonly number[] = [2_000, 10_000, 30_000];

export interface FxRetryOptions {
  fx: FxClient;
  log: Logger;
  delaysMs?: readonly number[];
  /** One-shot timer (default setTimeout, unref'd so it never keeps the process alive). */
  setTimer?: (fn: () => void, ms: number) => unknown;
  clearTimer?: (handle: unknown) => void;
}

/** A result worth retrying: no HTTP answer (timeout, network) or a server error. */
export function isRetryable(res: FxResult): boolean {
  return !res.ok && (res.status === 0 || res.status >= 500);
}

export class FxRetry {
  private readonly ids = new Set<string>();
  private all = false;
  private timer: unknown = null;
  private attempt = 0;
  private flushing: Promise<boolean> | null = null;
  private closed = false;
  private readonly delays: readonly number[];
  private readonly setTimer: (fn: () => void, ms: number) => unknown;
  private readonly clearTimer: (handle: unknown) => void;

  constructor(private readonly opts: FxRetryOptions) {
    this.delays = opts.delaysMs && opts.delaysMs.length > 0 ? opts.delaysMs : FX_RETRY_DELAYS_MS;
    this.setTimer =
      opts.setTimer ??
      ((fn, ms) => {
        const t = setTimeout(fn, ms);
        t.unref?.();
        return t;
      });
    this.clearTimer = opts.clearTimer ?? ((h) => clearTimeout(h as ReturnType<typeof setTimeout>));
  }

  /** What is waiting for redelivery. */
  get pending(): { all: boolean; discordIds: string[] } {
    return { all: this.all, discordIds: [...this.ids].sort() };
  }

  get hasPending(): boolean {
    return this.all || this.ids.size > 0;
  }

  /**
   * Record the outcome of a grant push or recompute for these ids (undefined = everyone online). A retryable
   * failure marks them pending and arms the next retry; a success lets anything pending go out now.
   */
  track(res: FxResult, discordIds: readonly string[] | undefined): FxResult {
    if (res.ok) {
      this.succeeded();
    } else if (isRetryable(res)) {
      this.markPending(discordIds);
      if (this.hasPending && this.timer === null && this.flushing === null) this.arm(this.attempt);
    }
    return res;
  }

  /** FXServer answered something: redeliver what is pending without waiting for the timer. */
  succeeded(): void {
    if (!this.hasPending || this.flushing !== null || this.closed) return;
    this.disarm();
    void this.flush();
  }

  /** Send everything pending as one /recompute. Resolves true when FXServer accepted it (or nothing was pending). */
  flush(): Promise<boolean> {
    if (this.flushing) return this.flushing;
    this.disarm();
    if (!this.hasPending || this.closed) return Promise.resolve(true);
    const all = this.all || this.ids.size > MAX_RECOMPUTE_IDS;
    const ids = all ? undefined : [...this.ids].sort();
    this.all = false;
    this.ids.clear();
    this.flushing = this.send(ids).finally(() => {
      this.flushing = null;
    });
    return this.flushing;
  }

  /** Stop the timer (app shutdown). Pending ids are dropped: FXServer re-fetches on the next service start. */
  close(): void {
    this.closed = true;
    this.disarm();
  }

  private async send(ids: string[] | undefined): Promise<boolean> {
    const res = await this.opts.fx.recompute(ids);
    if (res.ok) {
      this.attempt = 0;
      this.opts.log.info({ component: 'fx-retry', discordIds: ids?.length ?? 'all' }, 'pending grant changes redelivered to FXServer');
      // Failures recorded while this one was on the wire.
      if (this.hasPending && !this.closed) this.arm(0);
      return true;
    }
    this.markPending(ids);
    if (!isRetryable(res)) {
      this.opts.log.warn({ component: 'fx-retry', status: res.status, error: res.error }, 'FXServer refused the grant redelivery; not retrying');
      return false;
    }
    this.attempt += 1;
    if (this.attempt < this.delays.length) {
      this.arm(this.attempt);
    } else {
      this.opts.log.error(
        { component: 'fx-retry', error: res.error, pending: this.all ? 'all' : this.ids.size },
        'FXServer still unreachable: grant changes stay pending until the next successful FXServer call',
      );
    }
    return false;
  }

  private markPending(discordIds: readonly string[] | undefined): void {
    if (discordIds === undefined) {
      this.all = true;
      this.ids.clear();
    } else if (!this.all) {
      for (const id of discordIds) this.ids.add(id);
    }
  }

  private arm(step: number): void {
    if (this.closed) return;
    this.disarm();
    this.timer = this.setTimer(() => {
      this.timer = null;
      void this.flush();
    }, this.delays[Math.min(step, this.delays.length - 1)]!);
  }

  private disarm(): void {
    if (this.timer !== null) this.clearTimer(this.timer);
    this.timer = null;
  }
}
