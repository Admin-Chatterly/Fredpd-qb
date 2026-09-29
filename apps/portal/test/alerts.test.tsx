// SPDX-License-Identifier: GPL-3.0-only
// Portal Larm: read-only list from /api/alerts + /api/units, live over /ws (fake WebSocket), reconnect rules.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { act, cleanup, screen, waitFor } from '@testing-library/react';
import type { Alert } from '@fredpd/types/dispatch';
import { installFakeService, json, makeUser, renderPortal } from './helpers';

class FakeSocket {
  static instances: FakeSocket[] = [];
  onopen: (() => void) | null = null;
  onmessage: ((e: { data: string }) => void) | null = null;
  onclose: ((e: { code: number }) => void) | null = null;
  closed = false;
  constructor(readonly url: string) {
    FakeSocket.instances.push(this);
  }
  close() {
    this.closed = true;
  }
  open() {
    act(() => this.onopen?.());
  }
  send(message: unknown) {
    act(() => this.onmessage?.({ data: JSON.stringify(message) }));
  }
  drop(code: number) {
    act(() => this.onclose?.({ code }));
  }
}

const alert = (id: number, over: Partial<Alert> = {}): Alert => ({
  id,
  code: '10-71',
  title: `Skottlossning ${id}`,
  description: null,
  coords: null,
  street: 'Grove Street',
  priority: 1,
  source: 'ps-dispatch',
  status: 'open',
  createdAt: '2026-09-29T09:00:00Z',
  units: [],
  closedBy: null,
  closedAt: null,
  ...over,
});

beforeEach(() => {
  FakeSocket.instances = [];
  vi.stubGlobal('WebSocket', FakeSocket);
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

function setup() {
  const service = installFakeService(makeUser());
  vi.stubGlobal('WebSocket', FakeSocket);
  service.routes['GET /api/alerts'] = (_init, url) => {
    expect(url).toBe('/api/alerts?filter=open&page=1');
    return json({ items: [alert(1)], total: 1, page: 1 });
  };
  service.routes['GET /api/units'] = () =>
    json({ units: [{ citizenid: 'OFF00005', displayName: 'Karl Lund', callsign: 'IGV-12', unit: 'igv', onDuty: true, alertId: null }] }, 200, { 'x-fredpd-units-received-at': '2026-09-29T08:30:00Z' });
  return service;
}

describe('portal Larm', () => {
  it('lists alerts read-only and follows /ws events without refetching', async () => {
    const service = setup();
    renderPortal('/larm');
    expect(await screen.findByText('Skottlossning 1')).toBeTruthy();
    expect(await screen.findByText('IGV-12 · Karl Lund')).toBeTruthy();
    expect(document.querySelector('[data-units-age]')).not.toBeNull();
    // No take/leave/close in the portal.
    expect(document.querySelector('[data-alert-id] button')).toBeNull();
    const ws = FakeSocket.instances[0]!;
    expect(ws.url).toMatch(/^ws:\/\/.*\/ws$/);
    ws.open();
    expect(document.querySelector('[data-live="live"]')).not.toBeNull();
    const calls = service.fetchSpy.mock.calls.length;
    ws.send({ type: 'alertCreated', payload: alert(2) });
    expect(await screen.findByText('Skottlossning 2')).toBeTruthy();
    ws.send({ type: 'alertAssigned', payload: alert(2, { status: 'assigned', units: [{ citizenid: 'OFF00005', displayName: 'Karl Lund', callsign: 'IGV-12', unit: 'igv' }] }) });
    await waitFor(() => expect(document.querySelector('[data-alert-id="2"]')?.getAttribute('data-status')).toBe('assigned'));
    ws.send({ type: 'alertClosed', payload: { id: 1 } });
    await waitFor(() => expect(screen.queryByText('Skottlossning 1')).toBeNull());
    ws.send({ type: 'unitsChanged', payload: { units: [] } });
    expect(await screen.findByText('Inga poliser i tjänst.')).toBeTruthy();
    ws.send({ type: 'alertCreated', payload: { id: 'bad' } });
    expect(service.fetchSpy.mock.calls.length).toBe(calls);
  });

  it('reconnects after a drop with a backoff and catches up once; never after 4429 or a refused upgrade', async () => {
    const service = setup();
    renderPortal('/larm');
    await screen.findByText('Skottlossning 1');
    vi.useFakeTimers();
    const first = FakeSocket.instances[0]!;
    first.open();
    first.drop(1006);
    expect(document.querySelector('[data-live="reconnecting"]')).not.toBeNull();
    expect(FakeSocket.instances.length).toBe(1);
    act(() => vi.advanceTimersByTime(1000));
    expect(FakeSocket.instances.length).toBe(2);
    const before = service.fetchSpy.mock.calls.filter(([u]) => String(u).startsWith('/api/alerts')).length;
    FakeSocket.instances[1]!.open();
    vi.useRealTimers();
    await waitFor(() => expect(service.fetchSpy.mock.calls.filter(([u]) => String(u).startsWith('/api/alerts')).length).toBe(before + 1));
    vi.useFakeTimers();
    FakeSocket.instances[1]!.drop(4429);
    act(() => vi.advanceTimersByTime(60_000));
    expect(FakeSocket.instances.length).toBe(2);
    expect(document.querySelector('[data-live="otherTab"]')).not.toBeNull();
  });

  it('does not retry a socket that never opened; 4401 shows the login page', async () => {
    setup();
    renderPortal('/larm');
    await screen.findByText('Skottlossning 1');
    vi.useFakeTimers();
    FakeSocket.instances[0]!.drop(1006);
    act(() => vi.advanceTimersByTime(60_000));
    expect(FakeSocket.instances.length).toBe(1);
    expect(document.querySelector('[data-live="offline"]')).not.toBeNull();
    vi.useRealTimers();
    act(() => screen.getByRole('button', { name: 'Försök igen' }).click());
    expect(FakeSocket.instances.length).toBe(2);
    FakeSocket.instances[1]!.open();
    FakeSocket.instances[1]!.drop(4401);
    expect(await screen.findByText('Sessionen har gått ut. Logga in igen.')).toBeTruthy();
  });

  it('closes the socket when the page is left', async () => {
    setup();
    const { unmount } = renderPortal('/larm');
    await screen.findByText('Skottlossning 1');
    unmount();
    expect(FakeSocket.instances[0]!.closed).toBe(true);
  });
});
