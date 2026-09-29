// SPDX-License-Identifier: GPL-3.0-only
// The portal's MdtTransport (packages/ui mdtHost.tsx; portal action contract, task 7.1):
// POST /api/mdt/:action with the session cookie and `x-csrf-token` on every call (reads too), body = the action
// input, 200 = the action output. Errors are `{ error: <MDT_ERROR_CODES> }` with 400/401/403/404/429/503; such a body
// is handed back as the dispatcher's answer, so the shared client (apps/nui/src/api/client.ts) maps it exactly as it
// maps fredpd_mdt's `{ error }` in the tablet. 401 = the session ended: `onUnauthorized` replaces the cached session
// (the login page then says so) and the call fails as a network error. A status without a readable `{ error }` body
// (a proxy's HTML page, an empty 502) is an MdtTransportError.
import { CSRF_HEADER } from '@fredpd/types/actions';
import { MdtTransportError } from '@fredpd/ui';
import type { MdtTransport } from '@fredpd/ui';

export const MDT_API_PREFIX = '/api/mdt/';

export interface PortalTransportOptions {
  /** The current CSRF token (GET /api/session); read on every call so a refreshed token is used at once. */
  csrfToken: () => string | null;
  /** Called on 401 before the call fails. */
  onUnauthorized?: () => void;
  /** Called when the service refused the CSRF token (the session is re-read, so a retry carries a fresh one). */
  onCsrfRejected?: () => void;
}

function parseJson(text: string): unknown {
  if (text === '') return undefined;
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return undefined;
  }
}

const hasErrorCode = (value: unknown): value is { error: string; reason?: unknown } =>
  typeof value === 'object' && value !== null && typeof (value as { error?: unknown }).error === 'string';

/**
 * The service's own refusals (API_ERROR_CODES) in the dispatcher's vocabulary (MDT_ERROR_CODES), so both hosts show
 * the same texts: a missing grant is `unauthorized`, a body the service's zod check refused is `validation`.
 */
const SERVICE_TO_MDT: Readonly<Record<string, string>> = {
  forbidden: 'unauthorized',
  invalid_body: 'validation',
  unauthenticated: 'unauthorized',
  internal: 'unavailable',
};

export function createPortalTransport({ csrfToken, onUnauthorized, onCsrfRejected }: PortalTransportOptions): MdtTransport {
  return {
    mode: 'portal',
    async call(action, input) {
      const headers: Record<string, string> = { accept: 'application/json', 'content-type': 'application/json' };
      const token = csrfToken();
      if (token) headers[CSRF_HEADER] = token;
      let response: Response;
      try {
        response = await fetch(`${MDT_API_PREFIX}${encodeURIComponent(action)}`, {
          method: 'POST',
          headers,
          credentials: 'same-origin',
          body: JSON.stringify(input ?? {}),
        });
      } catch {
        throw new MdtTransportError(action, 0);
      }
      const body = parseJson(await response.text());
      if (response.status === 401) {
        onUnauthorized?.();
        throw new MdtTransportError(action, 401);
      }
      if (response.ok) return body;
      if (hasErrorCode(body)) {
        if (body.error === 'csrf') onCsrfRejected?.();
        const mapped = SERVICE_TO_MDT[body.error];
        return mapped ? { ...body, error: mapped } : body;
      }
      throw new MdtTransportError(action, response.status);
    },
  };
}
