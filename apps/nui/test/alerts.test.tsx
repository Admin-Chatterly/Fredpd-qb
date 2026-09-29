// SPDX-License-Identifier: GPL-3.0-only
// Task 3.2 Larm page: list per filter, priority chips, "Tilldelad: callsign · name", take/leave/close, the units
// panel, and live pushes written into the cache WITHOUT fetching (no listAlerts/getUnits call after the first load).
import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react';
import { PAGE_SIZE } from '@fredpd/types/mdt';
import type { Alert } from '@fredpd/types/dispatch';
import { applyAlertChange, matchesFilter, parseAlertPush } from '../src/alerts';
import type { AlertPage } from '../src/alerts';
import { toLuaWire } from '../src/api/wire';
import { clearNuiMocks } from '../src/utils/fetchNui';
import { ME, installMockRegister, renderAt, send } from './helpers';

afterEach(() => {
  cleanup();
  clearNuiMocks();
});

const alert = (id: number, over: Partial<Alert> = {}): Alert => ({
  id,
  code: '10-71',
  title: `Larm ${id}`,
  description: null,
  coords: null,
  street: null,
  priority: 2,
  source: 'ps-dispatch',
  status: 'open',
  createdAt: '2026-09-29T09:59:00Z',
  units: [],
  closedBy: null,
  closedAt: null,
  ...over,
});
const meOn = { ...ME };

describe('applyAlertChange (pure)', () => {
  const page = (items: Alert[], p = 1): AlertPage => ({ items, total: items.length, page: p });

  it('prepends a new matching alert on page 1 only, capped at the page size', () => {
    const full = page(Array.from({ length: PAGE_SIZE }, (_, i) => alert(100 - i)));
    const next = applyAlertChange(full, { type: 'upsert', alert: alert(500) }, 'open', ME.citizenid);
    expect(next.items[0]?.id).toBe(500);
    expect(next.items).toHaveLength(PAGE_SIZE);
    expect(next.total).toBe(PAGE_SIZE + 1);
    const page2 = page([alert(1)], 2);
    expect(applyAlertChange(page2, { type: 'upsert', alert: alert(500) }, 'open', ME.citizenid)).toBe(page2);
  });

  it('replaces a row in place and removes it when it stops matching the filter', () => {
    const base = page([alert(2), alert(1)]);
    const taken = alert(1, { status: 'assigned', units: [meOn] });
    expect(applyAlertChange(base, { type: 'upsert', alert: taken }, 'open', ME.citizenid).items[1]).toEqual(taken);
    const mine = page([taken]);
    const left = alert(1, { status: 'open', units: [] });
    expect(applyAlertChange(mine, { type: 'upsert', alert: left }, 'mine', ME.citizenid)).toEqual({ items: [], total: 0, page: 1 });
  });

  it('closed: removed from open/mine, marked closed in all; unknown ids leave the page untouched', () => {
    const base = page([alert(2), alert(1)]);
    expect(applyAlertChange(base, { type: 'closed', id: 1 }, 'open', ME.citizenid).items.map((a) => a.id)).toEqual([2]);
    expect(applyAlertChange(base, { type: 'closed', id: 1 }, 'all', ME.citizenid).items[1]?.status).toBe('closed');
    expect(applyAlertChange(base, { type: 'closed', id: 9 }, 'open', ME.citizenid)).toBe(base);
  });

  it('filters follow fredpd_dispatch: open = open + assigned, mine = not closed and on it', () => {
    expect(matchesFilter(alert(1, { status: 'assigned' }), 'open', ME.citizenid)).toBe(true);
    expect(matchesFilter(alert(1, { status: 'closed' }), 'open', ME.citizenid)).toBe(false);
    expect(matchesFilter(alert(1, { units: [meOn] }), 'mine', ME.citizenid)).toBe(true);
    expect(matchesFilter(alert(1, { units: [meOn], status: 'closed' }), 'mine', ME.citizenid)).toBe(false);
  });

  it('reads a Lua push (absent nulls) and refuses a malformed one', () => {
    const lua = toLuaWire({ type: 'created', alert: alert(7) });
    expect(parseAlertPush(lua)).toEqual({ type: 'created', alert: alert(7) });
    expect(parseAlertPush({ type: 'created', alert: { id: 'x' } })).toBeNull();
    expect(parseAlertPush({ type: 'closed', id: 3 })).toEqual({ type: 'closed', id: 3 });
  });
});

describe('Larm page', () => {
  const rows = () => [...document.querySelectorAll('[data-alert-id]')].map((li) => Number(li.getAttribute('data-alert-id')));

  it('lists open alerts newest first with priority chips and assigned units', async () => {
    const { calls } = installMockRegister();
    renderAt('/larm');
    await screen.findByText('Skottlossning');
    expect(rows()).toEqual([306, 305, 304, 303, 302]);
    const robbery = document.querySelector('[data-alert-id="305"]') as HTMLElement;
    expect(within(robbery).getByText('Hög')).toBeTruthy();
    expect(within(robbery).getByText('Tilldelad: IGV-12 · Karl Lund')).toBeTruthy();
    expect(within(document.querySelector('[data-alert-id="306"]') as HTMLElement).getByText('Ej tilldelat')).toBeTruthy();
    expect(calls.mock.calls.filter(([a]) => a === 'listAlerts')[0]?.[1]).toEqual({ filter: 'open', page: 1 });
    // Units panel: on-duty officers only, busy first.
    await screen.findAllByText('Ledig');
    const units = [...document.querySelectorAll('[data-unit]')].map((li) => li.getAttribute('data-unit'));
    expect(units).not.toContain('OFF00004'); // off duty
    expect(units.slice(0, 2).sort()).toEqual(['DEV00001', 'OFF00005']);
  });

  it('switches filters (Mina / Alla)', async () => {
    const { calls } = installMockRegister();
    renderAt('/larm');
    await screen.findByText('Skottlossning');
    fireEvent.click(screen.getByRole('tab', { name: 'Mina' }));
    await waitFor(() => expect(rows()).toEqual([304]));
    fireEvent.click(screen.getByRole('tab', { name: 'Alla' }));
    await waitFor(() => expect(rows()).toContain(301));
    expect(calls.mock.calls.filter(([a]) => a === 'listAlerts').map(([, i]) => (i as { filter: string }).filter)).toEqual(['open', 'mine', 'all']);
  });

  it('take / leave / close update the row from the answer, without refetching the list', async () => {
    const { calls } = installMockRegister();
    renderAt('/larm');
    await screen.findByText('Skottlossning');
    const row = () => document.querySelector('[data-alert-id="306"]') as HTMLElement;
    fireEvent.click(within(row()).getByRole('button', { name: 'Ta larmet' }));
    await waitFor(() => expect(within(row()).getByText('Tilldelad: IGV-07 · Anna Berg')).toBeTruthy());
    fireEvent.click(within(row()).getByRole('button', { name: 'Lämna larmet' }));
    await waitFor(() => expect(within(row()).getByText('Ej tilldelat')).toBeTruthy());
    fireEvent.click(within(row()).getByRole('button', { name: 'Ta larmet' }));
    await waitFor(() => within(row()).getByRole('button', { name: 'Avsluta larmet' }));
    fireEvent.click(within(row()).getByRole('button', { name: 'Avsluta larmet' }));
    await waitFor(() => expect(rows()).not.toContain(306));
    const actions = calls.mock.calls.map(([a]) => a);
    expect(actions.filter((a) => a === 'listAlerts')).toHaveLength(1);
    expect(actions.filter((a) => a === 'takeAlert' || a === 'leaveAlert' || a === 'closeAlert')).toEqual(['takeAlert', 'leaveAlert', 'takeAlert', 'closeAlert']);
  });

  it('close is offered only when on the alert (or with perm alerts.manage)', async () => {
    installMockRegister();
    renderAt('/larm');
    await screen.findByText('Skottlossning');
    const robbery = document.querySelector('[data-alert-id="305"]') as HTMLElement;
    expect(within(robbery).queryByRole('button', { name: 'Avsluta larmet' })).toBeNull();
    cleanup();
    renderAt('/larm', ['mdt_page:*', 'perm:alerts.manage']);
    await screen.findByText('Skottlossning');
    expect(within(document.querySelector('[data-alert-id="305"]') as HTMLElement).getByRole('button', { name: 'Avsluta larmet' })).toBeTruthy();
  });

  it('pushes on alerts/units update the page from the payload and never fetch', async () => {
    const { calls } = installMockRegister();
    renderAt('/larm');
    await screen.findByText('Skottlossning');
    await screen.findAllByText('Ledig');
    const before = calls.mock.calls.length;

    // created (as Lua sends it: nulls absent) → new top row
    send({ action: 'push', topic: 'alerts', payload: toLuaWire({ type: 'created', alert: alert(400, { title: 'Inbrott pågår', priority: 1 }) }) });
    await waitFor(() => expect(rows()[0]).toBe(400));
    expect(screen.getByText('Inbrott pågår')).toBeTruthy();
    // updated → row replaced
    send({ action: 'push', topic: 'alerts', payload: toLuaWire({ type: 'updated', alert: alert(400, { title: 'Inbrott pågår', status: 'assigned', units: [{ citizenid: 'OFF00002', displayName: 'Bo Carlsson', callsign: 'SPAN-02', unit: 'span' }] }) }) });
    await waitFor(() => expect(screen.getByText('Tilldelad: SPAN-02 · Bo Carlsson')).toBeTruthy());
    // closed → removed from Öppna
    send({ action: 'push', topic: 'alerts', payload: { type: 'closed', id: 400 } });
    await waitFor(() => expect(rows()).not.toContain(400));
    // units → panel replaced
    send({ action: 'push', topic: 'units', payload: { units: [{ citizenid: 'OFF00009', displayName: 'Ny Polis', callsign: 'IGV-99', unit: 'igv', onDuty: true }] } });
    await waitFor(() => expect(screen.getByText('IGV-99 · Ny Polis')).toBeTruthy());
    expect([...document.querySelectorAll('[data-unit]')]).toHaveLength(1);

    expect(calls.mock.calls.slice(before)).toEqual([]);
  });

  it('malformed pushes are logged and only mark the list stale: no fetch at all', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => undefined);
    const { calls } = installMockRegister();
    const { queryClient } = renderAt('/larm');
    await screen.findByText('Skottlossning');
    const before = calls.mock.calls.length;
    for (let i = 0; i < 5; i += 1) send({ action: 'push', topic: 'alerts', payload: { type: 'created', alert: { id: 'bad' } } });
    send({ action: 'push', topic: 'units', payload: { units: 'bad' } });
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(calls.mock.calls.slice(before)).toEqual([]);
    expect(warn).toHaveBeenCalledTimes(6);
    expect(queryClient.getQueryCache().findAll({ queryKey: ['mdt', 'listAlerts'] }).every((q) => q.isStale())).toBe(true);
    warn.mockRestore();
  });
});
