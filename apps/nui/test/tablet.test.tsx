// SPDX-License-Identifier: GPL-3.0-only
// The tablet shell end to end in jsdom: Lua messages open/close it, Esc closes it through fetchNui('close'),
// the navigation follows the grants, and pushes invalidate queries.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { QueryClientProvider, QueryObserver } from '@tanstack/react-query';
import { I18nProvider } from '@fredpd/ui';
import { App } from '../src/App';
import { i18n } from '../src/i18n';
import { createQueryClient } from '../src/queryClient';
import { TabletProvider, primaryUnit } from '../src/tablet/TabletContext';
import type { NuiMessage } from '../src/tablet/messages';
import { debugData } from '../src/utils/debugData';

const grantSet = (grants: string[], denied: string[] = []) => ({
  grants,
  denied,
  tier: 0 as const,
  units: ['igv'],
  rank: null,
  computedAt: '2026-09-29T10:00:00.000Z',
});

const openMessage = (grants: string[], denied: string[] = [], unit: string | null = 'igv'): NuiMessage => ({
  action: 'open',
  grants: grantSet(grants, denied),
  unit,
  me: { citizenid: 'ABC12345', displayName: 'Anna Berg', callsign: 'IGV-07' },
});

function send(data: unknown) {
  act(() => {
    window.dispatchEvent(new MessageEvent('message', { data }));
  });
}

function mount(onReady?: () => void) {
  const queryClient = createQueryClient();
  render(
    <I18nProvider i18n={i18n}>
      <QueryClientProvider client={queryClient}>
        <TabletProvider queryClient={queryClient} onReady={onReady}>
          <App />
        </TabletProvider>
      </QueryClientProvider>
    </I18nProvider>,
  );
  return { queryClient, root: () => document.getElementById('fredpd-tablet') as HTMLElement };
}

let fetchSpy: ReturnType<typeof vi.fn>;

beforeEach(() => {
  // Inside FiveM: fetchNui posts to https://fredpd_mdt/<action>.
  window.GetParentResourceName = () => 'fredpd_mdt';
  fetchSpy = vi.fn(async () => new Response('{}', { status: 200 }));
  vi.stubGlobal('fetch', fetchSpy);
  vi.spyOn(console, 'info').mockImplementation(() => {});
});

afterEach(() => {
  cleanup();
  delete window.GetParentResourceName;
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe('open / close', () => {
  it('is hidden (visibility:hidden) until Lua opens it and after Lua closes it', () => {
    const { root } = mount();
    expect(root().style.visibility).toBe('hidden');
    send(openMessage(['mdt_page:*']));
    expect(root().style.visibility).toBe('visible');
    expect(screen.getByRole('heading', { name: 'Hej Anna Berg' })).toBeTruthy();
    send({ action: 'close' });
    expect(root().style.visibility).toBe('hidden');
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it('Esc hides the tablet and calls fetchNui("close") so Lua releases focus', () => {
    const { root } = mount();
    send(openMessage(['mdt_page:*']));
    fireEvent.keyDown(window, { key: 'Escape' });
    expect(root().style.visibility).toBe('hidden');
    expect(fetchSpy).toHaveBeenCalledTimes(1);
    expect(fetchSpy.mock.calls[0]?.[0]).toBe('https://fredpd_mdt/close');
  });

  it('Esc closes even while typing in the search field', () => {
    const { root } = mount();
    send(openMessage(['mdt_page:*']));
    const search = screen.getByRole('searchbox', { name: 'Sök' });
    fireEvent.change(search, { target: { value: 'Andersson' } });
    fireEvent.keyDown(search, { key: 'Escape' });
    expect(root().style.visibility).toBe('hidden');
    expect(fetchSpy.mock.calls.map((c) => c[0])).toEqual(['https://fredpd_mdt/close']);
  });

  it('Esc does nothing while closed; other keys do nothing while open', () => {
    mount();
    fireEvent.keyDown(window, { key: 'Escape' });
    send(openMessage(['mdt_page:*']));
    fireEvent.keyDown(window, { key: 'Enter' });
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it('the close button closes like Esc', () => {
    const { root } = mount();
    send(openMessage([]));
    fireEvent.click(screen.getByRole('button', { name: 'Stäng surfplattan' }));
    expect(root().style.visibility).toBe('hidden');
    expect(fetchSpy.mock.calls[0]?.[0]).toBe('https://fredpd_mdt/close');
  });

  it('an invalid open payload still opens a closable tablet with an error', () => {
    const { root } = mount();
    vi.spyOn(console, 'error').mockImplementation(() => {});
    send({ action: 'open', grants: 'everything' });
    expect(root().style.visibility).toBe('visible');
    expect(screen.getByText('Något gick fel. Försök igen.')).toBeTruthy();
    fireEvent.keyDown(window, { key: 'Escape' });
    expect(root().style.visibility).toBe('hidden');
  });

  it('calls onReady once the message listener is attached, so a message sent from it is not lost', () => {
    const { root } = mount(() => window.dispatchEvent(new MessageEvent('message', { data: openMessage(['mdt_page:*']) })));
    expect(root().style.visibility).toBe('visible');
  });

  it('browser dev mode: a debugData open sent from onReady opens the tablet', async () => {
    delete window.GetParentResourceName; // plain browser, not FiveM
    const { root } = mount(() => debugData([openMessage(['mdt_page:*'])]));
    expect(root().style.visibility).toBe('hidden');
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(root().style.visibility).toBe('visible');
  });

  it('logs open -> first paint in dev builds', async () => {
    mount();
    send(openMessage([]));
    await act(async () => {
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    });
    expect(vi.mocked(console.info).mock.calls.some(([msg]) => String(msg).includes('open -> first paint'))).toBe(true);
  });
});

describe('navigation', () => {
  const navLabels = () =>
    within(screen.getByRole('navigation'))
      .queryAllByRole('link')
      .map((a) => a.textContent);

  it('shows only the sections the grants allow', () => {
    mount();
    send(openMessage(['mdt_page:search', 'mdt_page:cases']));
    expect(navLabels()).toEqual(['Hem', 'Sök', 'Ärenden']);
    expect(screen.queryByRole('button', { name: 'Meny' })).toBeNull();
  });

  it('caps the sidebar at 6 entries and puts the rest behind Meny', () => {
    mount();
    send(openMessage(['mdt_page:*']));
    expect(navLabels()).toEqual(['Hem', 'Larm', 'Sök', 'Efterlysningar', 'Ärenden']);
    const menu = screen.getByRole('button', { name: 'Meny' });
    expect(menu.getAttribute('aria-expanded')).toBe('false');
    fireEvent.click(menu);
    expect(navLabels()).toHaveLength(10);
    fireEvent.click(screen.getByRole('link', { name: 'Bevis' }));
    expect(screen.getByRole('heading', { name: 'Bevis' })).toBeTruthy();
    // Navigating from the menu folds it again; Meny is highlighted as holding the active page.
    expect(navLabels()).toHaveLength(5);
    expect(screen.getByRole('button', { name: 'Meny' }).className).toContain('bg-accent-soft');
  });

  it('follows a grants push while open and guards routes without the grant', () => {
    mount();
    send(openMessage(['mdt_page:search', 'mdt_page:alerts']));
    fireEvent.click(screen.getByRole('link', { name: 'Larm' }));
    expect(screen.getByRole('heading', { name: 'Larm' })).toBeTruthy();
    send({ action: 'push', topic: 'grants', payload: grantSet(['mdt_page:search']) });
    expect(navLabels()).toEqual(['Hem', 'Sök']);
    expect(screen.getByText('Du har inte behörighet att göra det här.')).toBeTruthy();
  });

  it('a grants push also moves the primary unit (Hem variant, unit label) to the new units[0]', () => {
    mount();
    send(openMessage(['mdt_page:*'], [], 'igv'));
    expect(document.querySelector('[data-home-variant]')?.getAttribute('data-home-variant')).toBe('igv');
    send({ action: 'push', topic: 'grants', payload: { ...grantSet(['mdt_page:*']), units: ['tekniker', 'igv'] } });
    expect(document.querySelector('[data-home-variant]')?.getAttribute('data-home-variant')).toBe('tekniker');
    expect(screen.getByText('I tjänst som IGV-07 · Kriminalteknik')).toBeTruthy();
    send({ action: 'push', topic: 'grants', payload: { ...grantSet(['mdt_page:*']), units: [] } });
    expect(document.querySelector('[data-home-variant]')?.getAttribute('data-home-variant')).toBe('default');
  });

  it('primaryUnit ignores a first unit that is not a valid unit code', () => {
    expect(primaryUnit({ ...grantSet([]), units: ['span'] })).toBe('span');
    expect(primaryUnit({ ...grantSet([]), units: ['not a unit'] })).toBeNull();
    expect(primaryUnit({ ...grantSet([]), units: [] })).toBeNull();
  });

  it('header search opens the search page with the query', () => {
    mount();
    send(openMessage(['mdt_page:search']));
    const search = screen.getByRole('searchbox', { name: 'Sök' });
    fireEvent.change(search, { target: { value: 'ABC 12D' } });
    fireEvent.keyDown(search, { key: 'Enter' });
    expect(screen.getByRole('heading', { name: 'Sök' })).toBeTruthy();
    expect(screen.getByText('ABC 12D')).toBeTruthy();
  });

  it('picks the Hem variant from the primary unit and hides sections without grant', () => {
    mount();
    send(openMessage(['mdt_page:evidence', 'mdt_page:cases'], [], 'tekniker'));
    const home = document.querySelector('[data-home-variant]');
    expect(home?.getAttribute('data-home-variant')).toBe('tekniker');
    expect(screen.getByText('I tjänst som IGV-07 · Kriminalteknik')).toBeTruthy();
    expect(screen.getAllByRole('heading', { level: 2 }).map((h) => h.textContent)).toEqual([
      'Bevis att analysera',
      'Mina ärenden',
      'Enhetens ärenden',
    ]);
  });
});

describe('push', () => {
  it('invalidates the queries of the pushed topic', () => {
    const { queryClient } = mount();
    const spy = vi.spyOn(queryClient, 'invalidateQueries');
    send(openMessage(['mdt_page:*']));
    send({ action: 'push', topic: 'alerts', payload: { id: 1 } });
    expect(spy).toHaveBeenCalledWith({ queryKey: ['alerts'], refetchType: 'active' });
  });

  it('only marks the topic stale while closed; the next open refetches it', async () => {
    const { queryClient } = mount();
    const queryFn = vi.fn(async () => 'data');
    // An active query, as the last page's queries stay mounted (hidden) while the tablet is closed.
    const observer = new QueryObserver(queryClient, { queryKey: ['alerts', 'list'], queryFn });
    const unsubscribe = observer.subscribe(() => {});
    await act(async () => {});
    expect(queryFn).toHaveBeenCalledTimes(1);

    send(openMessage(['mdt_page:*']));
    send({ action: 'close' });
    send({ action: 'push', topic: 'alerts', payload: { id: 1 } });
    await act(async () => {});
    expect(queryFn).toHaveBeenCalledTimes(1);
    expect(queryClient.getQueryState(['alerts', 'list'])?.isInvalidated).toBe(true);

    send(openMessage(['mdt_page:*']));
    await act(async () => {});
    expect(queryFn).toHaveBeenCalledTimes(2);

    // Open: a push refetches at once.
    send({ action: 'push', topic: 'alerts', payload: { id: 2 } });
    await act(async () => {});
    expect(queryFn).toHaveBeenCalledTimes(3);
    unsubscribe();
  });
});
