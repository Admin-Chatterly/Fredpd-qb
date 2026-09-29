// SPDX-License-Identifier: GPL-3.0-only
// Behörigheter page against a mocked service: cells cycle, Save sends the role's full row set with the CSRF
// header, the UI updates before the answer (optimistic) and rolls back when the service refuses.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { QueryClientProvider } from '@tanstack/react-query';
import { MemoryRouter } from 'react-router';
import { I18nProvider, createI18n } from '@fredpd/ui';
import type { AdminRolesResponse, SessionUser } from '@fredpd/types/actions';
import { App } from '../src/App';
import { i18n } from '../src/i18n';
import { createPortalQueryClient } from '../src/queryClient';
import { SessionContext, SessionProvider } from '../src/session';
import type { SessionState } from '../src/session';
import sv from '../../../locales/sv.json';
import en from '../../../locales/en.json';

/** The real locales, as the portal bundles them. */
function portalI18n() {
  return createI18n({ sv, en }, { lang: 'sv', fallbackLang: 'en' });
}

const POLIS = '100000000000000001';
const LEDNING = '100000000000000002';

const rolesResponse = (): AdminRolesResponse => ({
  roles: [
    { discordRoleId: POLIS, name: 'Polis', position: 2, deleted: false, colour: 0x3b82f6 },
    { discordRoleId: LEDNING, name: 'Ledning', position: 5, deleted: false, colour: 0 },
  ],
  grants: [
    { discordRoleId: POLIS, grantType: 'mdt_page', grantKey: 'search', effect: 'allow' },
    { discordRoleId: POLIS, grantType: 'unit', grantKey: 'igv', effect: 'allow' },
    { discordRoleId: LEDNING, grantType: 'perm', grantKey: 'admin.permissions', effect: 'allow' },
  ],
  catalog: [
    { type: 'mdt_page', keys: ['*', 'search'] },
    { type: 'unit', keys: ['*', 'ledning', 'igv'] },
    { type: 'intel_tier', keys: ['*', '0', '1', '2'] },
    { type: 'perm', keys: ['*', 'admin.permissions'] },
  ],
});

const admin: SessionUser = {
  discordId: '200000000000000001',
  displayName: 'Anna Berg',
  avatarUrl: null,
  citizenid: null,
  grants: { grants: ['perm:admin.permissions'], denied: [], tier: 0, units: [], rank: null, computedAt: '2026-09-29T10:00:00.000Z' },
};

type Handler = (init: RequestInit | undefined) => Response | Promise<Response>;
let routes: Record<string, Handler>;
let fetchSpy: ReturnType<typeof vi.fn>;

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

beforeEach(() => {
  let current = rolesResponse();
  routes = {
    'GET /api/admin/roles': () => json(current),
    // Default save: accept and store, like the service.
    [`PUT /api/admin/roles/${POLIS}/grants`]: (init) => {
      const body = JSON.parse(String(init?.body)) as { grants: { grantType: string; grantKey: string; effect: string }[] };
      current = {
        ...current,
        grants: [...current.grants.filter((g) => g.discordRoleId !== POLIS), ...body.grants.map((g) => ({ ...g, discordRoleId: POLIS }))] as AdminRolesResponse['grants'],
      };
      return json({ ok: true, recomputed: 3 });
    },
  };
  fetchSpy = vi.fn(async (url: string, init?: RequestInit) => {
    const handler = routes[`${init?.method ?? 'GET'} ${url}`];
    return handler ? handler(init) : json({ error: 'not_found' }, 404);
  });
  vi.stubGlobal('fetch', fetchSpy);
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

function renderPage(user: SessionUser | null = admin, path = '/behorigheter') {
  const queryClient = createPortalQueryClient();
  const session: SessionState = { status: 'ready', user, csrfToken: 'csrf-token-1', expired: false, error: null, refetch: () => {} };
  render(
    <I18nProvider i18n={i18n}>
      <QueryClientProvider client={queryClient}>
        <MemoryRouter initialEntries={[path]}>
          <SessionContext value={session}>
            <App />
          </SessionContext>
        </MemoryRouter>
      </QueryClientProvider>
    </I18nProvider>,
  );
  return queryClient;
}

const cell = (roleId: string, id: string) => {
  const el = document.querySelector<HTMLButtonElement>(`tr[data-role="${roleId}"] button[data-cell="${id}"]`);
  if (!el) throw new Error(`no cell ${roleId} ${id}`);
  return el;
};

const puts = () => fetchSpy.mock.calls.filter(([, init]) => (init as RequestInit | undefined)?.method === 'PUT');

describe('Behörigheter matrix', () => {
  it('lists roles by position with columns grouped by grant type', async () => {
    renderPage();
    await screen.findByRole('heading', { name: 'Behörigheter' });
    const rowNames = [...document.querySelectorAll('tbody tr')].map((tr) => tr.querySelector('th')?.textContent);
    expect(rowNames).toEqual(['Ledning', 'Polis']);
    const groups = [...document.querySelectorAll('thead th[scope="colgroup"]')].map((th) => th.textContent);
    expect(groups).toEqual(['Vapen', 'Fordon', 'Vapenförråd', 'Verktyg', 'MDT-sidor', 'Sekretessnivå', 'Enheter', 'Särskilda behörigheter']);
    expect(cell(POLIS, 'mdt_page:search').dataset.effect).toBe('allow');
    expect(cell(POLIS, 'mdt_page:alerts').dataset.effect).toBe('none');
    expect(cell(POLIS, 'mdt_page:alerts').getAttribute('aria-label')).toBe('Polis · MDT-sidor · Larm · Ej satt');
    expect(cell(LEDNING, 'intel_tier:2').getAttribute('aria-label')).toBe('Ledning · Sekretessnivå · Hemlig · Ej satt');
  });

  it('cycles a cell none -> allow -> deny -> none and tracks unsaved changes per role', async () => {
    renderPage();
    await screen.findByRole('heading', { name: 'Behörigheter' });
    const c = cell(POLIS, 'mdt_page:alerts');
    fireEvent.click(c);
    expect(c.dataset.effect).toBe('allow');
    expect(c.dataset.dirty).toBe('true');
    expect(screen.getByText('Osparade ändringar: 1')).toBeTruthy();
    fireEvent.click(c);
    expect(c.dataset.effect).toBe('deny');
    fireEvent.click(c);
    expect(c.dataset.effect).toBe('none');
    expect(c.dataset.dirty).toBeUndefined();
    expect(screen.queryByRole('button', { name: 'Spara ändringar' })).toBeNull();
  });

  it('saves one role with PUT, the full row set and the CSRF header', async () => {
    renderPage();
    await screen.findByRole('heading', { name: 'Behörigheter' });
    fireEvent.click(cell(POLIS, 'mdt_page:alerts')); // allow
    fireEvent.click(cell(POLIS, 'mdt_page:alerts')); // deny
    fireEvent.click(cell(POLIS, 'intel_tier:1')); // allow
    fireEvent.click(cell(POLIS, 'unit:igv')); // saved allow -> deny
    fireEvent.click(cell(LEDNING, 'unit:ledning')); // another role: not part of this save

    const saveButtons = screen.getAllByRole('button', { name: 'Spara ändringar' });
    expect(saveButtons).toHaveLength(2);
    const polisRow = document.querySelector(`tr[data-role="${POLIS}"]`) as HTMLElement;
    fireEvent.click(within(polisRow).getByRole('button', { name: 'Spara ändringar' }));

    await waitFor(() => expect(puts()).toHaveLength(1));
    const [url, init] = puts()[0] as [string, RequestInit];
    expect(url).toBe(`/api/admin/roles/${POLIS}/grants`);
    expect(init.method).toBe('PUT');
    expect((init.headers as Record<string, string>)['x-csrf-token']).toBe('csrf-token-1');
    expect((init.headers as Record<string, string>)['content-type']).toBe('application/json');
    expect(init.credentials).toBe('same-origin');
    expect(JSON.parse(String(init.body))).toEqual({
      grants: [
        { grantType: 'mdt_page', grantKey: 'alerts', effect: 'deny' },
        { grantType: 'mdt_page', grantKey: 'search', effect: 'allow' },
        { grantType: 'intel_tier', grantKey: '1', effect: 'allow' },
        { grantType: 'unit', grantKey: 'igv', effect: 'deny' },
      ],
    });

    expect(await screen.findByText('Polis · Behörigheterna är sparade. Uppdaterade spelare: 3')).toBeTruthy();
    // Saved state is shown, the other role's draft is untouched.
    expect(cell(POLIS, 'mdt_page:alerts').dataset.effect).toBe('deny');
    expect(cell(POLIS, 'mdt_page:alerts').dataset.dirty).toBeUndefined();
    expect(cell(LEDNING, 'unit:ledning').dataset.dirty).toBe('true');
  });

  it('shows the change before the service answers and rolls back when it refuses', async () => {
    let answer: (r: Response) => void = () => {};
    routes[`PUT /api/admin/roles/${POLIS}/grants`] = () => new Promise<Response>((resolve) => (answer = resolve));
    renderPage();
    await screen.findByRole('heading', { name: 'Behörigheter' });

    fireEvent.click(cell(POLIS, 'tool:*')); // allow
    fireEvent.click(cell(POLIS, 'mdt_page:search')); // saved allow -> deny
    fireEvent.click(screen.getByRole('button', { name: 'Spara ändringar' }));

    // Optimistic: the new state is shown as saved (not dirty) while the request is pending, cells are locked.
    await waitFor(() => expect(puts()).toHaveLength(1));
    expect(cell(POLIS, 'tool:*').dataset.effect).toBe('allow');
    expect(cell(POLIS, 'tool:*').dataset.dirty).toBeUndefined();
    expect(cell(POLIS, 'mdt_page:search').dataset.effect).toBe('deny');
    expect(cell(POLIS, 'tool:*').disabled).toBe(true);

    // The refetch after the failure never answers, so what is shown next comes from the rollback alone.
    routes['GET /api/admin/roles'] = () => new Promise<Response>(() => {});
    await act(async () => answer(json({ error: 'invalid_body', detail: 'unknown unit' }, 400)));

    expect(await screen.findByText('Polis · Kontrollera de markerade fälten.')).toBeTruthy();
    // The admin's edits come back as unsaved changes on top of the restored rows, ready to retry.
    expect(cell(POLIS, 'tool:*').dataset.effect).toBe('allow');
    expect(cell(POLIS, 'tool:*').dataset.dirty).toBe('true');
    expect(cell(POLIS, 'mdt_page:search').dataset.effect).toBe('deny');
    expect(cell(POLIS, 'mdt_page:search').dataset.dirty).toBe('true');
    expect(screen.getByText('Osparade ändringar: 2')).toBeTruthy();
    expect(cell(POLIS, 'tool:*').disabled).toBe(false);
    // Discarding them shows the restored saved rows (not the optimistic ones).
    fireEvent.click(screen.getByRole('button', { name: 'Släng ändringarna' }));
    expect(cell(POLIS, 'tool:*').dataset.effect).toBe('none');
    expect(cell(POLIS, 'mdt_page:search').dataset.effect).toBe('allow');
    expect(cell(POLIS, 'unit:igv').dataset.effect).toBe('allow');
  });

  it('a csrf refusal keeps the edits and re-reads the session, so the retry carries the fresh token', async () => {
    let issued = 0;
    routes['GET /api/session'] = () => json({ user: admin, csrfToken: `csrf-token-${++issued}` });
    const accept = routes[`PUT /api/admin/roles/${POLIS}/grants`] as Handler;
    let refused = false;
    routes[`PUT /api/admin/roles/${POLIS}/grants`] = (init) => {
      if (refused) return accept(init);
      refused = true;
      return json({ error: 'csrf' }, 403);
    };
    const queryClient = createPortalQueryClient();
    render(
      <I18nProvider i18n={portalI18n()}>
        <QueryClientProvider client={queryClient}>
          <MemoryRouter initialEntries={['/behorigheter']}>
            <SessionProvider>
              <App />
            </SessionProvider>
          </MemoryRouter>
        </QueryClientProvider>
      </I18nProvider>,
    );
    await screen.findByRole('heading', { name: 'Behörigheter' });

    fireEvent.click(cell(POLIS, 'tool:*'));
    fireEvent.click(screen.getByRole('button', { name: 'Spara ändringar' }));
    // Not errors.csrf ("Ladda om sidan"): a reload would drop the restored edits, and a plain retry works.
    expect(await screen.findByText('Polis · Sessionen förnyades. Försök spara igen.')).toBeTruthy();
    expect(cell(POLIS, 'tool:*').dataset.dirty).toBe('true');
    await waitFor(() => expect(issued).toBe(2));

    fireEvent.click(screen.getByRole('button', { name: 'Spara ändringar' }));
    await waitFor(() => expect(puts()).toHaveLength(2));
    const tokens = puts().map(([, init]) => ((init as RequestInit).headers as Record<string, string>)['x-csrf-token']);
    expect(tokens).toEqual(['csrf-token-1', 'csrf-token-2']);
    expect(await screen.findByText('Polis · Behörigheterna är sparade. Uppdaterade spelare: 3')).toBeTruthy();
    expect(cell(POLIS, 'tool:*').dataset.effect).toBe('allow');
    expect(cell(POLIS, 'tool:*').dataset.dirty).toBeUndefined();
  });

  it('adds a column the catalog does not list (a rank) and saves a role with it', async () => {
    renderPage();
    await screen.findByRole('heading', { name: 'Behörigheter' });
    const form = document.querySelector<HTMLFormElement>('form[data-add-key]') as HTMLFormElement;
    const kind = within(form).getByRole('combobox', { name: 'Typ' });
    const input = within(form).getByRole('textbox');
    const add = within(form).getByRole('button', { name: 'Lägg till' });

    // Unit is not offered: every unit the service accepts is already a column.
    expect(within(kind).queryByRole('option', { name: 'Enheter' })).toBeNull();
    expect([...(kind as HTMLSelectElement).options].map((o) => o.value)).not.toContain('unit');

    // Invalid key: marked, nothing added.
    fireEvent.change(kind, { target: { value: 'weapon' } });
    fireEvent.change(input, { target: { value: 'två ord' } });
    fireEvent.click(add);
    expect(input.getAttribute('aria-invalid')).toBe('true');
    expect(within(form).getByText('Kontrollera de markerade fälten.')).toBeTruthy();
    expect(document.querySelector('button[data-cell="weapon:två ord"]')).toBeNull();

    fireEvent.change(kind, { target: { value: 'rank' } });
    fireEvent.change(input, { target: { value: ' kommissarie ' } });
    fireEvent.click(add);
    expect(input.getAttribute('aria-invalid')).toBeNull();
    expect((input as HTMLInputElement).value).toBe('');
    const rankCell = cell(POLIS, 'perm:rank:kommissarie');
    expect(rankCell.getAttribute('aria-label')).toBe('Polis · Särskilda behörigheter · Tjänstegrad · kommissarie · Ej satt');

    fireEvent.click(rankCell);
    fireEvent.click(screen.getByRole('button', { name: 'Spara ändringar' }));
    await waitFor(() => expect(puts()).toHaveLength(1));
    const body = JSON.parse(String((puts()[0] as [string, RequestInit])[1].body)) as { grants: unknown[] };
    expect(body.grants).toContainEqual({ grantType: 'perm', grantKey: 'rank:kommissarie', effect: 'allow' });
  });

  it('discards a role’s draft', async () => {
    renderPage();
    await screen.findByRole('heading', { name: 'Behörigheter' });
    fireEvent.click(cell(POLIS, 'tool:*'));
    fireEvent.click(screen.getByRole('button', { name: 'Släng ändringarna' }));
    expect(cell(POLIS, 'tool:*').dataset.effect).toBe('none');
    expect(puts()).toHaveLength(0);
  });

  it('filters roles by name', async () => {
    renderPage();
    await screen.findByRole('heading', { name: 'Behörigheter' });
    fireEvent.change(screen.getByRole('searchbox', { name: 'Filtrera roller' }), { target: { value: 'led' } });
    expect([...document.querySelectorAll('tbody tr')].map((tr) => tr.getAttribute('data-role'))).toEqual([LEDNING]);
  });
});

describe('access', () => {
  it('shows Behörigheter in the navigation only with perm admin.permissions', async () => {
    renderPage(admin, '/');
    expect(screen.getByRole('link', { name: 'Behörigheter' })).toBeTruthy();
    cleanup();
    renderPage({ ...admin, grants: { ...admin.grants, grants: ['mdt_page:*'] } }, '/');
    expect(screen.queryByRole('link', { name: 'Behörigheter' })).toBeNull();
  });

  it('answers not found on the page without the perm and never calls the admin API', () => {
    renderPage({ ...admin, grants: { ...admin.grants, grants: ['perm:admin.permissions'], denied: ['perm:admin.permissions'] } });
    expect(screen.getByText('Uppgiften hittades inte.')).toBeTruthy();
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it('shows the login page with the privacy notice when logged out', () => {
    renderPage(null, '/?loginError=notMember');
    expect(screen.getByRole('heading', { name: 'Logga in' })).toBeTruthy();
    expect(screen.getByRole('alert').textContent).toBe('Ditt Discord-konto är inte med i vår Discord-server.');
    expect(screen.getByRole('link', { name: 'Logga in med Discord' }).getAttribute('href')).toBe('/auth/discord');
    expect(screen.getByText('Så hanterar vi dina uppgifter')).toBeTruthy();
    expect(screen.getByText('Sökningar och ändringar loggas. Loggarna sparas i 90 dagar.')).toBeTruthy();
  });
});
