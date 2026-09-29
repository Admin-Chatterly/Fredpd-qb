// SPDX-License-Identifier: GPL-3.0-only
import { afterEach, describe, expect, it, vi } from 'vitest';
import { NuiRequestError, clearNuiMocks, fetchNui, registerNuiMock } from '../src/utils/fetchNui';
import { debugData } from '../src/utils/debugData';
import { isEnvBrowser } from '../src/utils/env';

const inFiveM = () => {
  window.GetParentResourceName = () => 'fredpd_mdt';
};

afterEach(() => {
  delete window.GetParentResourceName;
  clearNuiMocks();
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

describe('fetchNui in mock mode (browser, no GetParentResourceName)', () => {
  it('detects the browser', () => {
    expect(isEnvBrowser()).toBe(true);
    inFiveM();
    expect(isEnvBrowser()).toBe(false);
  });

  it('answers with mockData, then a registered mock, then undefined, and never posts', async () => {
    const fetchSpy = vi.fn();
    vi.stubGlobal('fetch', fetchSpy);
    expect(await fetchNui('getHome', { a: 1 }, { ok: 'inline' })).toEqual({ ok: 'inline' });

    const handler = vi.fn((data: unknown) => ({ echo: data }));
    const unregister = registerNuiMock('getHome', handler);
    expect(await fetchNui('getHome', { a: 1 })).toEqual({ echo: { a: 1 } });
    expect(handler).toHaveBeenCalledWith({ a: 1 });
    // Inline mock data wins over the registered one.
    expect(await fetchNui('getHome', undefined, 42)).toBe(42);

    unregister();
    expect(await fetchNui('getHome')).toBeUndefined();
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it('awaits async mocks', async () => {
    registerNuiMock('search', async () => ['hit']);
    expect(await fetchNui<string[]>('search', { q: 'x' })).toEqual(['hit']);
  });
});

describe('fetchNui inside FiveM', () => {
  it('POSTs JSON to https://<resource>/<action> and parses the answer', async () => {
    inFiveM();
    const fetchSpy = vi.fn(async () => new Response(JSON.stringify({ ok: true }), { status: 200 }));
    vi.stubGlobal('fetch', fetchSpy);
    registerNuiMock('getHome', () => 'mock must be ignored in game');

    expect(await fetchNui('getHome', { unit: 'igv' }, { ignored: true })).toEqual({ ok: true });
    expect(fetchSpy).toHaveBeenCalledWith('https://fredpd_mdt/getHome', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: '{"unit":"igv"}',
    });
  });

  it('sends {} without data and returns undefined for an empty body', async () => {
    inFiveM();
    const fetchSpy = vi.fn(async () => new Response('', { status: 200 }));
    vi.stubGlobal('fetch', fetchSpy);
    expect(await fetchNui('close')).toBeUndefined();
    expect(fetchSpy).toHaveBeenCalledWith('https://fredpd_mdt/close', expect.objectContaining({ body: '{}' }));
  });

  it('rejects with NuiRequestError on a non-2xx answer', async () => {
    inFiveM();
    vi.stubGlobal('fetch', vi.fn(async () => new Response('nope', { status: 404 })));
    const err = await fetchNui('missing').catch((e: unknown) => e);
    expect(err).toBeInstanceOf(NuiRequestError);
    expect(err).toMatchObject({ action: 'missing', status: 404 });
  });
});

describe('debugData', () => {
  it('dispatches the messages as window message events in the browser', () => {
    vi.useFakeTimers();
    const received: unknown[] = [];
    const listener = (e: MessageEvent) => received.push(e.data);
    window.addEventListener('message', listener);
    debugData([{ action: 'close' }, { action: 'push', topic: 'alerts', payload: 1 }]);
    expect(received).toEqual([]);
    vi.runAllTimers();
    expect(received).toEqual([{ action: 'close' }, { action: 'push', topic: 'alerts', payload: 1 }]);
    window.removeEventListener('message', listener);
  });

  it('does nothing inside FiveM', () => {
    vi.useFakeTimers();
    inFiveM();
    const listener = vi.fn();
    window.addEventListener('message', listener);
    debugData([{ action: 'close' }]);
    vi.runAllTimers();
    expect(listener).not.toHaveBeenCalled();
    window.removeEventListener('message', listener);
  });
});
