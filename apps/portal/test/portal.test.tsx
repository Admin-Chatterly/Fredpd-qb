// SPDX-License-Identifier: GPL-3.0-only
// Portal pages (task 7.1) against a fake service whose /api/mdt/:action is answered by the tablet's mock register:
// the character flow, the shared tablet pages running on the portal transport, world-only actions hidden, grant
// filtering (nav + routes, intel 404), Ledning pages and the release form.
import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react';
import { vi } from 'vitest';
import { CSRF, ME, installFakeService, json, makeUser, renderPortal } from './helpers';

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

const navLabels = () => [...document.querySelectorAll('aside nav [data-nav]')].map((a) => a.getAttribute('data-nav'));

describe('character flow', () => {
  it('asks for a character after login, stores the pick with CSRF and then acts as it', async () => {
    const service = installFakeService(makeUser({ citizenid: null }));
    renderPortal('/');
    expect(await screen.findByRole('heading', { name: 'Välj karaktär' })).toBeTruthy();
    // No MDT sections without a character (they would act as nobody).
    expect(navLabels()).toEqual(['home']);
    const pick = await screen.findByRole('button', { name: 'Fortsätt som Nils Holm' });
    expect(screen.getByText('Senast spelad 2026-09-28')).toBeTruthy();
    fireEvent.click(pick);
    await waitFor(() => expect(service.user?.citizenid).toBe('DEV00009'));
    const post = service.fetchSpy.mock.calls.find(([url]) => url === '/api/session/character') as [string, RequestInit];
    expect(JSON.parse(String(post[1].body))).toEqual({ citizenid: 'DEV00009' });
    expect((post[1].headers as Record<string, string>)['x-csrf-token']).toBe(CSRF);
    // Hem (the tablet's page) loads through the portal transport.
    await waitFor(() => expect(service.mdtCalls.some(([a]) => a === 'getHome')).toBe(true));
    expect(navLabels()).toContain('search');
  });

  it('shows the empty text when the user has no characters', async () => {
    const service = installFakeService(makeUser({ citizenid: null }));
    service.routes['GET /api/characters'] = () => json([]);
    renderPortal('/sok');
    expect(await screen.findByText(/Vi hittade inga karaktärer/)).toBeTruthy();
    expect(service.mdtCalls).toEqual([]);
  });

  it('switches character from the sidebar and drops the cached records of the previous one', async () => {
    const service = installFakeService(makeUser());
    const { queryClient } = renderPortal('/brottskatalog');
    await screen.findByRole('heading', { name: 'Brottskatalog' });
    await waitFor(() => expect(queryClient.getQueryCache().findAll({ queryKey: ['mdt'] }).length).toBeGreaterThan(0));
    fireEvent.click(screen.getByRole('button', { name: 'Byt karaktär' }));
    fireEvent.click(await screen.findByRole('button', { name: 'Fortsätt som Nils Holm' }));
    await waitFor(() => expect(service.user?.citizenid).toBe('DEV00009'));
    await waitFor(() => expect(queryClient.getQueryCache().findAll({ queryKey: ['mdt', 'listCharges'] }).length).toBe(0));
  });

  it('a character switch also drops the portal\'s own live alert/unit caches, keeping only session and characters', async () => {
    const service = installFakeService(makeUser());
    const { queryClient } = renderPortal('/brottskatalog');
    await screen.findByRole('heading', { name: 'Brottskatalog' });
    queryClient.setQueryData(['portalAlerts', 'open', 1], { items: [], page: 1, total: 0 });
    queryClient.setQueryData(['portalUnits'], { units: [], receivedAt: 0 });
    fireEvent.click(screen.getByRole('button', { name: 'Byt karaktär' }));
    fireEvent.click(await screen.findByRole('button', { name: 'Fortsätt som Nils Holm' }));
    await waitFor(() => expect(service.user?.citizenid).toBe('DEV00009'));
    await waitFor(() => expect(queryClient.getQueryCache().findAll({ queryKey: ['portalAlerts'] }).length).toBe(0));
    expect(queryClient.getQueryCache().findAll({ queryKey: ['portalUnits'] }).length).toBe(0);
    expect(queryClient.getQueryData(['session'])).toBeTruthy();
  });
});

describe('shared pages on the portal transport', () => {
  it('posts every MDT call to /api/mdt/:action with the CSRF header, reads included', async () => {
    const service = installFakeService(makeUser());
    renderPortal('/fordon/ABC12D');
    expect(await screen.findByRole('heading', { level: 1, name: /ABC12D/ })).toBeTruthy();
    const [action, input, headers] = service.mdtCalls.find(([a]) => a === 'getVehicle')!;
    expect(action).toBe('getVehicle');
    expect(input).toEqual({ plate: 'ABC12D' });
    expect(headers['x-csrf-token']).toBe(CSRF);
    // Lua-wire answers (absent nulls) are normalised as in the tablet: the owner link renders.
    expect(screen.getByRole('link', { name: /Erik Nilsson|Nilsson/ })).toBeTruthy();
  });

  it('hides world-only actions: no plate check on the vehicle page', async () => {
    installFakeService(makeUser());
    renderPortal('/fordon/ABC12D');
    await screen.findByRole('heading', { level: 1, name: /ABC12D/ });
    expect(screen.queryByRole('button', { name: 'Kontrollera' })).toBeNull();
    // BOLO writes are portal actions and stay.
    expect(screen.getByRole('button', { name: /Efterlys/ })).toBeTruthy();
  });

  it('hides tablet revocation on Ledning → Surfplattor (read-only list)', async () => {
    const service = installFakeService(makeUser());
    renderPortal('/ledning/surfplattor');
    await screen.findByRole('heading', { name: 'Surfplattor' });
    await waitFor(() => expect(service.mdtCalls.some(([a]) => a === 'listTablets')).toBe(true));
    await waitFor(() => expect(document.querySelectorAll('tbody tr').length).toBeGreaterThan(0));
    expect(screen.queryByRole('button', { name: 'Spärra' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Återaktivera' })).toBeNull();
  });

  it('links the person page to the POI sheet (the tablet keeps its disabled button)', async () => {
    installFakeService(makeUser());
    renderPortal('/person/FPD00001');
    await screen.findByRole('heading', { level: 1, name: /Erik Nilsson/ });
    expect(document.querySelector('a[data-poi-link]')?.getAttribute('href')).toBe('/person/FPD00001/poi');
  });

  it('shows a refused call with its text (403 portal, as the service answers world actions)', async () => {
    const service = installFakeService(makeUser());
    service.routes['POST /api/mdt/getVehicle'] = () => json({ error: 'unauthorized', reason: 'portal' }, 403);
    renderPortal('/fordon/ABC12D');
    expect(await screen.findByText('Du har inte behörighet att göra det här.')).toBeTruthy();
  });
});

describe('grants', () => {
  it('lists only granted sections in the nav and guards the routes', async () => {
    installFakeService(makeUser({ grants: ['mdt_page:search', 'mdt_page:cases'] }));
    renderPortal('/brottskatalog');
    expect(await screen.findByText('Du har inte behörighet att göra det här.')).toBeTruthy();
    expect(navLabels()).toEqual(['home', 'search', 'cases', 'release']);
  });

  it('answers intel routes with "not found" without the grant (never "not authorised")', async () => {
    const service = installFakeService(makeUser({ grants: ['mdt_page:search'] }));
    renderPortal('/intel/kallor');
    expect(await screen.findByText('Uppgiften hittades inte.')).toBeTruthy();
    expect(screen.queryByText('Du har inte behörighet att göra det här.')).toBeNull();
    expect(service.mdtCalls).toEqual([]);
  });

  it('answers intel sources with "not found" with mdt_page:intel but without perm intel.read', async () => {
    installFakeService(makeUser({ grants: ['mdt_page:intel'] }));
    renderPortal('/intel/kallor');
    expect(await screen.findByText('Uppgiften hittades inte.')).toBeTruthy();
  });
});

describe('Ledning', () => {
  const request = {
    id: 7,
    status: 'pending',
    channel: 'portal',
    requesterName: 'Sara Ek',
    description: 'Jag vill ta del av ärendet om klottret',
    target: { type: 'case', id: '1', label: 'K-1042-26' },
    createdAt: '2026-09-29T08:00:00Z',
  };

  it('decides a release request with masking and shows the released (masked) content', async () => {
    const service = installFakeService(makeUser());
    service.routes['POST /api/mdt/listReleaseRequests'] = () => json({ items: [request], total: 1, page: 1 });
    service.routes['POST /api/mdt/decideReleaseRequest'] = (init) => {
      const body = JSON.parse(String(init?.body)) as Record<string, unknown>;
      expect(body).toEqual({ id: 7, decision: 'partial', note: 'Maskerat enligt OSL', targetType: 'case', targetId: 1 });
      return json({
        ...request,
        status: 'partial',
        decidedAt: '2026-09-29T09:00:00Z',
        decidedBy: { citizenid: 'OFF00006', displayName: 'Helena Sjöberg', callsign: 'LED-01', unit: 'ledning' },
        decisionNote: 'Maskerat enligt OSL',
        released: { type: 'case', caseNumber: 'K-1042-26', status: 'closed', title: 'Rån Legion Square', createdAt: '2026-09-01T10:00:00Z', reports: {} },
      });
    };
    renderPortal('/ledning/utlamning');
    const row = await screen.findByText('Jag vill ta del av ärendet om klottret');
    const li = row.closest('li')!;
    fireEvent.click(within(li).getByRole('button', { name: 'Öppna' }));
    fireEvent.change(within(li).getByRole('textbox'), { target: { value: 'Maskerat enligt OSL' } });
    fireEvent.click(within(li).getByRole('button', { name: 'Lämna ut med maskering' }));
    expect(await within(li).findByText('Beslutet är registrerat.')).toBeTruthy();
    expect(within(li).getByText('Rån Legion Square')).toBeTruthy();
    expect(li.getAttribute('data-status')).toBe('partial');
  });

  it('shows the refusal text of a decision (nothing releasable)', async () => {
    const service = installFakeService(makeUser());
    service.routes['POST /api/mdt/listReleaseRequests'] = () => json({ items: [request], total: 1, page: 1 });
    service.routes['POST /api/mdt/decideReleaseRequest'] = () => json({ error: 'validation', reason: 'nothing_releasable' }, 400);
    renderPortal('/ledning/utlamning');
    const li = (await screen.findByText(request.description)).closest('li')!;
    fireEvent.click(within(li).getByRole('button', { name: 'Öppna' }));
    fireEvent.click(within(li).getByRole('button', { name: 'Lämna ut med maskering' }));
    expect(await within(li).findByText(/Det finns inget i handlingen som kan lämnas ut/)).toBeTruthy();
  });

  it('hides the release queue and the audit view without records.admin', async () => {
    const service = installFakeService(makeUser({ grants: ['mdt_page:command', 'perm:tablets.manage'] }));
    renderPortal('/ledning');
    await screen.findByRole('heading', { name: 'Ledning' });
    expect([...document.querySelectorAll('[data-command-link]')].map((a) => a.getAttribute('data-command-link'))).toEqual(['surfplattor']);
    cleanup();
    renderPortal('/ledning/utlamning');
    expect(await screen.findByText('Uppgiften hittades inte.')).toBeTruthy();
    expect(service.mdtCalls.some(([a]) => a === 'listReleaseRequests')).toBe(false);
  });

  it('renders the audit view placeholder (no audit action yet)', async () => {
    installFakeService(makeUser());
    renderPortal('/ledning/granskning');
    expect(await screen.findByText(/Loggvyn är inte klar än/)).toBeTruthy();
  });

  it('shows the roster from getHome (Ledning variant), on duty first', async () => {
    installFakeService(makeUser({ units: ['ledning'] }), { unit: 'ledning' });
    renderPortal('/register');
    await screen.findByRole('heading', { name: 'Personal' });
    const rows = await screen.findAllByRole('row');
    expect(rows.length).toBeGreaterThanOrEqual(2);
    expect(within(rows[1]!).getByText('I tjänst')).toBeTruthy();
  });
});

describe('Begär ut allmän handling', () => {
  it('sends description and reference and says the request was received', async () => {
    const service = installFakeService(makeUser());
    service.routes['POST /api/mdt/createReleaseRequest'] = (init) => {
      expect(JSON.parse(String(init?.body))).toEqual({ description: 'Polisrapporten om inbrottet', reference: 'K-1-26' });
      return json({ id: 12 });
    };
    renderPortal('/begar-ut');
    await screen.findByRole('heading', { name: 'Begär ut allmän handling' });
    const submit = screen.getByRole('button', { name: 'Skicka begäran' }) as HTMLButtonElement;
    expect(submit.disabled).toBe(true);
    fireEvent.change(screen.getByLabelText('Vad vill du ta del av?'), { target: { value: '  Polisrapporten om inbrottet ' } });
    fireEvent.change(screen.getByLabelText('Ärende- eller rapportnummer (om du vet det)'), { target: { value: 'K-1-26' } });
    fireEvent.click(submit);
    expect(await screen.findByText(/Din begäran är mottagen/)).toBeTruthy();
  });

  it('shows "not available yet" instead of a validation error while the server does not know the action', async () => {
    const service = installFakeService(makeUser());
    service.routes['POST /api/mdt/createReleaseRequest'] = () => json({ error: 'validation', reason: 'action' }, 400);
    renderPortal('/begar-ut');
    await screen.findByRole('heading', { name: 'Begär ut allmän handling' });
    fireEvent.change(screen.getByLabelText('Vad vill du ta del av?'), { target: { value: 'Polisrapporten' } });
    fireEvent.click(screen.getByRole('button', { name: 'Skicka begäran' }));
    expect(await screen.findByText('Den här funktionen är inte tillgänglig i portalen än.')).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Skicka begäran' })).toBeNull();
  });

  it('the release queue and the POI sheet show the same placeholder for an unknown action', async () => {
    const service = installFakeService(makeUser());
    service.routes['POST /api/mdt/listReleaseRequests'] = () => json({ error: 'validation', reason: 'action' }, 400);
    service.routes['POST /api/mdt/getPoi'] = () => json({ error: 'validation', reason: 'action' }, 400);
    const first = renderPortal('/ledning/utlamning');
    expect(await screen.findByText('Den här funktionen är inte tillgänglig i portalen än.')).toBeTruthy();
    first.unmount();
    renderPortal('/person/DEV00002/poi');
    expect(await screen.findByText('Den här funktionen är inte tillgänglig i portalen än.')).toBeTruthy();
  });
});

describe('session end', () => {
  it('a 401 from /api/mdt shows the login page with the expiry text', async () => {
    const service = installFakeService(makeUser());
    service.routes['POST /api/mdt/listCharges'] = () => json({ error: 'unauthenticated' }, 401);
    renderPortal('/brottskatalog');
    expect(await screen.findByText('Sessionen har gått ut. Logga in igen.')).toBeTruthy();
    expect(ME.citizenid).toBe('DEV00001');
  });
});
