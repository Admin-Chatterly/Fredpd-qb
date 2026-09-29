// SPDX-License-Identifier: GPL-3.0-only
// Signed client for the FXServer endpoints of fredpd_core (docs/contracts.md §C6, handled by
// resources/[fredpd]/fredpd_core/server/http.js). Every call has one deadline (3 s by default) and never throws:
// a failure is logged and returned as { ok: false }, because FXServer being down must not break a portal request
// or a Discord event handler (players then get their grants on the next join).
import { signedHeaders } from '@fredpd/types/hmac';
import type { GrantSet } from '@fredpd/types/grants';
import type { Logger } from './log';

export type FxResult =
  | { ok: true; status: number; body: Record<string, unknown> }
  | { ok: false; status: number; error: string };

export interface FxClient {
  ping(): Promise<FxResult>;
  /** POST /grants: apply a freshly resolved set to that Discord user's online players. */
  pushGrants(discordId: string, grants: GrantSet): Promise<FxResult>;
  /** POST /recompute: FXServer re-fetches grants for these (or, without ids, all) online players. */
  recompute(discordIds?: string[]): Promise<FxResult>;
  /** POST /officer: refresh the in-memory officer name/avatar used for rosters. */
  pushOfficer(discordId: string, displayName: string, avatarUrl: string | null): Promise<FxResult>;
}

export interface FxClientOptions {
  baseUrl: string;
  secret: string;
  log: Logger;
  timeoutMs?: number;
  fetch?: typeof fetch;
  nowSeconds?: () => number;
}

/** http.js accepts at most this many ids in one /recompute; more than that means "everyone online". */
export const MAX_RECOMPUTE_IDS = 2000;

export function createFxClient(opts: FxClientOptions): FxClient {
  const doFetch = opts.fetch ?? globalThis.fetch;
  const timeoutMs = opts.timeoutMs ?? 3000;
  const base = `${opts.baseUrl.replace(/\/+$/, '')}/fredpd_core`;

  async function call(method: 'GET' | 'POST', path: string, body?: unknown): Promise<FxResult> {
    const raw = body === undefined ? '' : JSON.stringify(body);
    const headers: Record<string, string> = signedHeaders(opts.secret, raw, opts.nowSeconds?.());
    if (method === 'POST') headers['content-type'] = 'application/json';
    try {
      const res = await doFetch(`${base}${path}`, {
        method,
        headers,
        body: method === 'POST' ? raw : undefined,
        signal: AbortSignal.timeout(timeoutMs),
      });
      const text = await res.text();
      let parsed: unknown = null;
      try {
        parsed = text === '' ? {} : JSON.parse(text);
      } catch {
        parsed = null;
      }
      if (!res.ok) {
        const error = parsed && typeof parsed === 'object' && 'error' in parsed ? String((parsed as { error: unknown }).error) : `http_${res.status}`;
        opts.log.warn({ component: 'fx', method, path, status: res.status, error }, 'FXServer refused the request');
        return { ok: false, status: res.status, error };
      }
      const obj = parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : {};
      return { ok: true, status: res.status, body: obj };
    } catch (err) {
      const e = err as Error;
      const error = e.name === 'TimeoutError' || e.name === 'AbortError' ? 'timeout' : 'network';
      opts.log.warn({ component: 'fx', method, path, error, detail: e.message }, 'FXServer unreachable');
      return { ok: false, status: 0, error };
    }
  }

  return {
    ping: () => call('GET', '/ping'),
    pushGrants: (discordId, grants) => call('POST', '/grants', { discordId, grants }),
    recompute: (discordIds) =>
      call('POST', '/recompute', discordIds && discordIds.length <= MAX_RECOMPUTE_IDS ? { discordIds } : {}),
    pushOfficer: (discordId, displayName, avatarUrl) => call('POST', '/officer', { discordId, displayName, avatarUrl }),
  };
}
