// SPDX-License-Identifier: GPL-3.0-only
// HMAC contract between FXServer (fredpd_core/server/http.js) and fredpd_service. See docs/contracts.md §C5.
import { createHmac, timingSafeEqual } from 'node:crypto';

export const HMAC_TS_HEADER = 'x-fredpd-ts';
export const HMAC_SIG_HEADER = 'x-fredpd-sig';
export const HMAC_MAX_SKEW_SECONDS = 60;
export const HMAC_MIN_SECRET_LENGTH = 32;

export function signBody(secret: string, ts: number | string, rawBody: string): string {
  return createHmac('sha256', secret).update(`${ts}.${rawBody}`, 'utf8').digest('hex');
}

export type VerifyResult = { ok: true } | { ok: false; reason: 'missing' | 'skew' | 'signature' };

export function verifySignature(opts: {
  secret: string;
  ts: string | undefined | null;
  sig: string | undefined | null;
  rawBody: string;
  nowSeconds?: number;
  maxSkewSeconds?: number;
}): VerifyResult {
  const { secret, ts, sig, rawBody } = opts;
  if (!ts || !sig || !/^\d{1,12}$/.test(ts) || !/^[0-9a-f]{64}$/i.test(sig)) return { ok: false, reason: 'missing' };
  const now = opts.nowSeconds ?? Math.floor(Date.now() / 1000);
  if (Math.abs(now - Number(ts)) > (opts.maxSkewSeconds ?? HMAC_MAX_SKEW_SECONDS)) return { ok: false, reason: 'skew' };
  const expected = Buffer.from(signBody(secret, ts, rawBody), 'hex');
  const given = Buffer.from(sig.toLowerCase(), 'hex');
  if (given.length !== expected.length || !timingSafeEqual(given, expected)) return { ok: false, reason: 'signature' };
  return { ok: true };
}

/** Headers for an outgoing signed request. */
export function signedHeaders(secret: string, rawBody: string, nowSeconds?: number): Record<string, string> {
  const ts = String(nowSeconds ?? Math.floor(Date.now() / 1000));
  return { [HMAC_TS_HEADER]: ts, [HMAC_SIG_HEADER]: signBody(secret, ts, rawBody) };
}
