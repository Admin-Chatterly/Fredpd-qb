// SPDX-License-Identifier: GPL-3.0-only
// JSON calls to fredpd_service (docs/contracts.md §C6, §C10). Same-origin: in dev, Vite proxies /api, /auth and
// /ws to the service. Writes carry the session's CSRF token in `x-csrf-token`.
import { API_ERROR_LOCALE_KEYS, ApiErrorSchema, CSRF_HEADER } from '@fredpd/types/actions';
import type { ApiErrorCode } from '@fredpd/types/actions';
import type { LocaleKey } from '@fredpd/types/locale-keys';

/** `status` 0 = the request never got an answer (network). `code` is the service's `{ error }` code. */
export class ApiRequestError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
  ) {
    super(`API request failed: ${status} ${code}`);
    this.name = 'ApiRequestError';
  }
}

/** Any zod schema (or anything with parse); keeps zod out of the portal's own dependencies. */
export interface Parser<T> {
  parse(data: unknown): T;
}

export interface ApiOptions<T> {
  method?: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';
  body?: unknown;
  csrfToken?: string | null;
  schema: Parser<T>;
}

/** Body as JSON; undefined when empty or not JSON (e.g. a proxy's HTML error page). */
function parseJson(text: string): unknown {
  if (text === '') return undefined;
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return undefined;
  }
}

export async function apiFetch<T>(path: string, { method = 'GET', body, csrfToken, schema }: ApiOptions<T>): Promise<T> {
  const headers: Record<string, string> = { accept: 'application/json' };
  if (body !== undefined) headers['content-type'] = 'application/json';
  if (method !== 'GET' && csrfToken) headers[CSRF_HEADER] = csrfToken;

  let response: Response;
  try {
    response = await fetch(path, {
      method,
      headers,
      credentials: 'same-origin',
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch {
    throw new ApiRequestError(0, 'network');
  }

  const json = parseJson(await response.text());
  if (!response.ok) {
    const error = ApiErrorSchema.safeParse(json);
    throw new ApiRequestError(response.status, error.success ? error.data.error : 'internal');
  }
  return schema.parse(json);
}

const isApiErrorCode = (code: string): code is ApiErrorCode => Object.hasOwn(API_ERROR_LOCALE_KEYS, code);

/** Message for an error thrown by apiFetch (or anything else). */
export function errorLocaleKey(error: unknown): LocaleKey {
  if (error instanceof ApiRequestError) {
    if (error.code === 'network') return 'errors.network';
    if (isApiErrorCode(error.code)) return API_ERROR_LOCALE_KEYS[error.code];
  }
  return 'errors.unknown';
}
