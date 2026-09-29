// SPDX-License-Identifier: GPL-3.0-only
import { afterEach, describe, expect, it, vi } from 'vitest';
import { SessionResponseSchema } from '@fredpd/types/actions';
import { ApiRequestError, apiFetch, errorLocaleKey } from '../src/api';
import { createPortalQueryClient } from '../src/queryClient';
import { SESSION_QUERY_KEY } from '../src/session';

afterEach(() => vi.unstubAllGlobals());

const schema = { parse: (d: unknown) => d };

describe('apiFetch', () => {
  it('sends the CSRF header on writes only', async () => {
    const fetchSpy = vi.fn(async () => new Response('{"ok":true}', { status: 200 }));
    vi.stubGlobal('fetch', fetchSpy);
    await apiFetch('/api/x', { csrfToken: 'tok', schema });
    await apiFetch('/api/x', { method: 'PUT', body: { a: 1 }, csrfToken: 'tok', schema });
    const [get, put] = fetchSpy.mock.calls as unknown as [[string, RequestInit], [string, RequestInit]];
    expect(get[1].headers).toEqual({ accept: 'application/json' });
    expect(put[1].headers).toEqual({ accept: 'application/json', 'content-type': 'application/json', 'x-csrf-token': 'tok' });
    expect(put[1].body).toBe('{"a":1}');
  });

  it('validates the answer with the schema', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response('{"user":null,"csrfToken":null}')));
    expect(await apiFetch('/api/session', { schema: SessionResponseSchema })).toEqual({ user: null, csrfToken: null });
    vi.stubGlobal('fetch', vi.fn(async () => new Response('{"user":"x"}')));
    await expect(apiFetch('/api/session', { schema: SessionResponseSchema })).rejects.toThrow();
  });

  it('maps errors to locale keys: service codes, non-JSON bodies and network failures', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response('{"error":"csrf"}', { status: 403 })));
    const csrf = await apiFetch('/api/x', { schema }).catch((e: unknown) => e);
    expect(csrf).toMatchObject({ status: 403, code: 'csrf' });
    expect(errorLocaleKey(csrf)).toBe('errors.csrf');

    vi.stubGlobal('fetch', vi.fn(async () => new Response('<html>Bad gateway</html>', { status: 502 })));
    const html = await apiFetch('/api/x', { schema }).catch((e: unknown) => e);
    expect(html).toMatchObject({ status: 502, code: 'internal' });
    expect(errorLocaleKey(html)).toBe('errors.unknown');

    vi.stubGlobal('fetch', vi.fn(async () => Promise.reject(new TypeError('Failed to fetch'))));
    const net = await apiFetch('/api/x', { schema }).catch((e: unknown) => e);
    expect(net).toBeInstanceOf(ApiRequestError);
    expect(errorLocaleKey(net)).toBe('errors.network');
    expect(errorLocaleKey(new Error('x'))).toBe('errors.unknown');
    expect(errorLocaleKey(new ApiRequestError(418, 'teapot'))).toBe('errors.unknown');
  });
});

describe('session expiry', () => {
  it('a 401 from any query marks the session logged out and expired', async () => {
    const client = createPortalQueryClient();
    client.setQueryData(SESSION_QUERY_KEY, { user: null, csrfToken: 'x' });
    vi.stubGlobal('fetch', vi.fn(async () => new Response('{"error":"unauthenticated"}', { status: 401 })));
    await client.fetchQuery({ queryKey: ['admin', 'roles'], queryFn: () => apiFetch('/api/admin/roles', { schema }), retry: false }).catch(() => {});
    expect(client.getQueryData(SESSION_QUERY_KEY)).toEqual({ user: null, csrfToken: null, expired: true });
  });
});
