// SPDX-License-Identifier: GPL-3.0-only
// Errors of tablet actions. fredpd_mdt answers `{ error = <MDT_ERROR_CODES>, reason? }` (docs/contracts.md §C12;
// `reason` is additive, docs/modules/bolo.md); a failed NUI callback (non-2xx) is a network error. Every one maps
// to an `errors.*` text (reason first when it has its own text).
import { useCallback } from 'react';
import { MDT_ERROR_CODES } from '@fredpd/types/mdt';
import type { MdtError } from '@fredpd/types/mdt';
import type { LocaleKey } from '@fredpd/types/locale-keys';
import { useI18n } from '@fredpd/ui';
import { NuiRequestError } from '../utils/fetchNui';
import { isRecord } from './wire';

export type MdtErrorCode = MdtError['error'];
export type MdtClientErrorCode = MdtErrorCode | 'network' | 'unknown';

export class MdtClientError extends Error {
  constructor(
    readonly action: string,
    readonly code: MdtClientErrorCode,
    readonly reason?: string,
  ) {
    super(`${action}: ${code}${reason ? ` (${reason})` : ''}`);
    this.name = 'MdtClientError';
  }
}

const isErrorCode = (v: unknown): v is MdtErrorCode => typeof v === 'string' && (MDT_ERROR_CODES as readonly string[]).includes(v);

/** `{ error: '<code>', reason?: '<why>' }` from the dispatcher; null for anything else. */
export function readErrorResponse(action: string, value: unknown): MdtClientError | null {
  if (!isRecord(value) || typeof value.error !== 'string') return null;
  const reason = typeof value.reason === 'string' && value.reason !== '' ? value.reason : undefined;
  return new MdtClientError(action, isErrorCode(value.error) ? value.error : 'unknown', reason);
}

export function toMdtClientError(action: string, err: unknown): MdtClientError {
  if (err instanceof MdtClientError) return err;
  if (err instanceof NuiRequestError) return new MdtClientError(action, 'network');
  return new MdtClientError(action, 'unknown');
}

export const ERROR_LOCALE_KEYS: Readonly<Record<MdtClientErrorCode, LocaleKey>> = {
  unauthorized: 'errors.unauthorized',
  not_found: 'errors.notFound',
  validation: 'errors.validation',
  rate_limited: 'errors.rateLimited',
  unavailable: 'errors.serviceUnavailable',
  network: 'errors.network',
  unknown: 'errors.unknown',
};

/** Reasons with a more precise text than their code (bolo.md "reason values"). */
export const REASON_LOCALE_KEYS: Readonly<Record<string, LocaleKey>> = {
  off_duty: 'errors.notOnDuty',
  too_far: 'errors.tooFar',
  revoked: 'tablet.revoked',
};

export function errorLocaleKey(err: unknown): LocaleKey {
  if (!(err instanceof MdtClientError)) return err instanceof NuiRequestError ? 'errors.network' : 'errors.unknown';
  return (err.reason !== undefined ? REASON_LOCALE_KEYS[err.reason] : undefined) ?? ERROR_LOCALE_KEYS[err.code];
}

/** Codes where retrying the same call can help (the query retries once; the UI offers "Försök igen"). */
export function isRetryable(err: unknown): boolean {
  return err instanceof MdtClientError && (err.code === 'network' || err.code === 'unavailable' || err.code === 'rate_limited' || err.code === 'unknown');
}

/** Localised text for any error thrown by the client. */
export function useErrorText(): (err: unknown) => string {
  const { t } = useI18n();
  return useCallback((err: unknown) => t(errorLocaleKey(err)), [t]);
}
