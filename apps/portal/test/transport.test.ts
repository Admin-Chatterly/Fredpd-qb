// SPDX-License-Identifier: GPL-3.0-only
// The portal MdtTransport and the shared typed client over it (callMdt with a transport): the same error mapping
// as the tablet's fetchNui path.
import { afterEach, describe, expect, it, vi } from 'vitest';
import { MdtTransportError } from '@fredpd/ui';
import { createPortalTransport } from '../src/mdt/transport';
import { callMdt } from '../../nui/src/api/client';
import { MdtClientError } from '../../nui/src/api/errors';
import { json } from './helpers';

afterEach(() => vi.unstubAllGlobals());

const transport = (opts: Partial<Parameters<typeof createPortalTransport>[0]> = {}) => createPortalTransport({ csrfToken: () => 'tok', ...opts });

describe('portal transport', () => {
  it('POSTs the input to /api/mdt/:action with the CSRF header (reads too)', async () => {
    const spy = vi.fn(async () => json({ items: [] }));
    vi.stubGlobal('fetch', spy);
    expect(await transport().call('listCharges', {})).toEqual({ items: [] });
    const [url, init] = spy.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe('/api/mdt/listCharges');
    expect(init.method).toBe('POST');
    expect(init.credentials).toBe('same-origin');
    expect(init.body).toBe('{}');
    expect(init.headers).toEqual({ accept: 'application/json', 'content-type': 'application/json', 'x-csrf-token': 'tok' });
  });

  it('hands `{ error }` bodies back so callMdt maps them like the dispatcher answer', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => json({ error: 'not_found' }, 404)));
    await expect(callMdt('getCase', { id: 1 }, transport())).rejects.toMatchObject({ code: 'not_found' });
    vi.stubGlobal('fetch', vi.fn(async () => json({ error: 'unauthorized', reason: 'portal' }, 403)));
    await expect(callMdt('checkPlate', { plate: 'ABC12D' }, transport())).rejects.toMatchObject({ code: 'unauthorized', reason: 'portal' });
    vi.stubGlobal('fetch', vi.fn(async () => json({ error: 'unavailable' }, 503)));
    await expect(callMdt('listCharges', {}, transport())).rejects.toMatchObject({ code: 'unavailable' });
    vi.stubGlobal('fetch', vi.fn(async () => json({ error: 'rate_limited' }, 429)));
    await expect(callMdt('listCharges', {}, transport())).rejects.toMatchObject({ code: 'rate_limited' });
  });

  it('maps the service refusals to the dispatcher codes', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => json({ error: 'forbidden' }, 403)));
    await expect(callMdt('listCharges', {}, transport())).rejects.toMatchObject({ code: 'unauthorized' });
    vi.stubGlobal('fetch', vi.fn(async () => json({ error: 'invalid_body' }, 400)));
    await expect(callMdt('listCharges', {}, transport())).rejects.toMatchObject({ code: 'validation' });
  });

  it('401 ends the session and fails as a network error', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => json({ error: 'unauthenticated' }, 401)));
    const onUnauthorized = vi.fn();
    await expect(transport({ onUnauthorized }).call('getHome', {})).rejects.toBeInstanceOf(MdtTransportError);
    expect(onUnauthorized).toHaveBeenCalledOnce();
    await expect(callMdt('getHome', {}, transport())).rejects.toMatchObject({ code: 'network' });
  });

  it('a csrf refusal re-reads the session', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => json({ error: 'csrf' }, 403)));
    const onCsrfRejected = vi.fn();
    await expect(callMdt('createBolo', { kind: 'person', citizenid: 'A1', reason: 'x', level: 0 } as never, transport({ onCsrfRejected }))).rejects.toBeInstanceOf(MdtClientError);
    expect(onCsrfRejected).toHaveBeenCalledOnce();
  });

  it('a status without a readable error body, or no answer at all, is a network error', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response('<html>bad gateway</html>', { status: 502 })));
    await expect(callMdt('listCharges', {}, transport())).rejects.toMatchObject({ code: 'network' });
    vi.stubGlobal('fetch', vi.fn(async () => Promise.reject(new TypeError('offline'))));
    await expect(callMdt('listCharges', {}, transport())).rejects.toMatchObject({ code: 'network' });
  });

  it('answers are normalised from the Lua wire like the tablet (absent nulls restored)', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => json({ items: {}, total: 0, page: 1 })));
    expect(await callMdt('listCases', { filter: 'all', page: 1 }, transport())).toEqual({ items: [], total: 0, page: 1 });
  });
});
