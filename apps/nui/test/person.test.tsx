// SPDX-License-Identifier: GPL-3.0-only
// Tasks 2.4 and 2.5: person and vehicle pages. Case refs render per visibility (a kontaktnotis ONLY as the
// Notice, a masked ref without the title it did not get), records sum their fines with formatCurrency, the phase 5
// actions are disabled with a tooltip, Efterlys opens the BOLO dialog prefilled, Kontrollera records a check.
import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react';
import { BoloCreateInputSchema } from '@fredpd/types/mdt';
import { clearNuiMocks, registerNuiMock } from '../src/utils/fetchNui';
import { toLuaWire } from '../src/api/wire';
import { installMockRegister, renderAt } from './helpers';

afterEach(() => {
  cleanup();
  clearNuiMocks();
});

const section = (title: string) => screen.getByRole('region', { name: title });

describe('person page', () => {
  it('renders the header facts and never a field the server did not send', async () => {
    installMockRegister();
    renderAt('/person/FPD00006'); // Karin Andersson: no personnummer, birthdate, phone or address
    expect(await screen.findByRole('heading', { level: 1, name: /Karin Andersson/ })).toBeTruthy();
    const labels = [...document.querySelectorAll('dt')].map((dt) => dt.textContent);
    expect(labels).toEqual(['Kön']);
    renderAt('/person/FPD00001');
    await screen.findByText('19870412-5531', { selector: 'dd' });
    expect(screen.getByText('Grove Street 14, Davis')).toBeTruthy();
    expect(screen.getByText('070-412 55 31')).toBeTruthy();
  });

  it('a kontaktnotis case renders only the notice: no number, title or level', async () => {
    const { db } = installMockRegister();
    renderAt('/person/FPD00001');
    await screen.findByRole('heading', { level: 1, name: /Erik Nilsson/ });
    const cases = within(section('Ärenden')).getAllByRole('listitem');
    const noticeItem = cases.find((li) => within(li).queryByRole('note'));
    expect(noticeItem?.textContent).toBe('KontaktnotisDet finns uppgifter som rör Erik Nilsson. Kontakta Bo Carlsson (Spaning).');
    expect(noticeItem?.querySelector('a')).toBeNull();
    // The notice case (K-1077-26, level 2) exists in the register but nothing of it reaches the page, not even
    // through the record row that belongs to it.
    const hidden = db.cases.find((c) => c.visibility === 'notice' && c.id === 1077);
    expect(document.body.textContent).not.toContain(hidden?.caseNumber);
    expect(document.body.textContent).not.toContain(hidden?.title);
    expect(noticeItem?.textContent).not.toContain('Hemlig');
  });

  it('a masked case without a title shows number, role, status and the restricted badge only', async () => {
    installMockRegister();
    renderAt('/person/FPD00001');
    await screen.findByRole('heading', { level: 1, name: /Erik Nilsson/ });
    const masked = document.querySelector('[data-case-visibility="masked"]');
    expect(masked?.textContent).toBe('K-988-26MisstänktAvslutatDelvis maskeratBegränsad');
    expect(document.body.textContent).not.toContain('Narkotikabrott');
    const full = document.querySelector('[data-case-visibility="full"]');
    expect(full?.textContent).toBe('K-1042-26Grovt rån mot värdetransport, Legion SquareMisstänktÖppet');
    expect(full?.closest('a')?.getAttribute('href')).toBe('/arende/1042');
  });

  it('masked title: absent on the wire (Lua nil) and null render the same, a sent title is shown', async () => {
    installMockRegister();
    const summary = {
      person: { citizenid: 'X1', firstname: 'Test', lastname: 'Person', gender: 'unknown' },
      vehicles: [],
      bolos: [],
      cases: [
        { visibility: 'masked', id: 7, caseNumber: 'K-7-26', status: 'closed', level: 0 },
        { visibility: 'masked', id: 8, caseNumber: 'K-8-26', title: 'Stöld', status: 'closed', level: 0, role: 'witness' },
      ],
      records: [],
    };
    registerNuiMock('getPerson', () => summary);
    renderAt('/person/X1');
    await screen.findByRole('heading', { level: 1, name: /Test Person/ });
    const rows = [...document.querySelectorAll('[data-case-visibility="masked"]')].map((e) => e.textContent);
    expect(rows).toEqual(['K-7-26AvslutatDelvis maskerat', 'K-8-26StöldVittneAvslutatDelvis maskerat']);
  });

  it('records: fines formatted with formatCurrency and summed; a notice case number is never shown', async () => {
    installMockRegister();
    renderAt('/person/FPD00001');
    await screen.findByRole('heading', { level: 1, name: /Erik Nilsson/ });
    const records = section('Belastningsregister');
    expect(within(records).getByText('3 000 kr')).toBeTruthy();
    expect(within(records).getByText('2 400 kr')).toBeTruthy();
    expect(within(records).getByText('20 min')).toBeTruthy();
    expect(records.querySelector('[data-record-total]')?.textContent).toBe('Totalt bötesbelopp: 5 400 kr');
    const rows = within(records).getAllByRole('row').slice(1);
    expect(rows).toHaveLength(3);
    expect(rows.map((r) => r.lastElementChild?.textContent)).toEqual(['', '', 'K-988-26']);
  });

  it('phase 5 actions are disabled with a tooltip; Efterlys is disabled while a BOLO is live', async () => {
    installMockRegister();
    renderAt('/person/FPD00001');
    await screen.findByRole('heading', { level: 1, name: /Erik Nilsson/ });
    for (const name of ['Lägg till i ärende', 'Ny rapport', 'POI-blad']) {
      const button = screen.getByRole('button', { name }) as HTMLButtonElement;
      expect(button.disabled).toBe(true);
      expect(button.closest('[data-coming-soon]')?.getAttribute('title')).toBe('Kommer i fas 5');
    }
    expect((screen.getByRole('button', { name: 'Efterlys' }) as HTMLButtonElement).disabled).toBe(true);
    expect(screen.getAllByText('Efterlyst').length).toBeGreaterThan(0);
  });

  it('Efterlys opens the BOLO dialog prefilled with the person and sends a valid createBolo input', async () => {
    const { calls } = installMockRegister();
    renderAt('/person/FPD00002');
    await screen.findByRole('heading', { level: 1, name: /Maria Karlsson/ });
    fireEvent.click(screen.getByRole('button', { name: 'Efterlys' }));
    const dialog = screen.getByRole('dialog', { name: 'Ny efterlysning' });
    expect(within(dialog).getByRole('radio', { name: 'Person' }).getAttribute('aria-checked')).toBe('true');
    expect(dialog.querySelector('[data-bolo-subject]')?.textContent).toBe('Maria Karlsson');
    fireEvent.change(within(dialog).getByRole('textbox', { name: 'Anledning' }), { target: { value: '  Misstänkt för misshandel på Vespucci Beach.  ' } });
    fireEvent.change(within(dialog).getByRole('combobox', { name: 'Giltighetstid' }), { target: { value: '24' } });
    fireEvent.click(within(dialog).getByRole('button', { name: 'Efterlys' }));
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    const sent = calls.mock.calls.find(([action]) => action === 'createBolo')?.[1];
    expect(sent).toEqual({ kind: 'person', citizenid: 'FPD00002', reason: 'Misstänkt för misshandel på Vespucci Beach.', level: 0, expiresInHours: 24 });
    expect(BoloCreateInputSchema.parse(sent)).toEqual(sent);
    expect(await screen.findByText('Efterlysningen är utfärdad.')).toBeTruthy();
    // The mutation refetched the person: the new BOLO is listed.
    expect(await within(section('Efterlysningar')).findByText('Misstänkt för misshandel på Vespucci Beach.')).toBeTruthy();
  });

  it('unknown person: not found text', async () => {
    installMockRegister();
    renderAt('/person/NOPE');
    expect(await screen.findByText('Personen hittades inte.')).toBeTruthy();
  });
});

describe('vehicle page', () => {
  it('shows the owner link, the BOLO flag, the linked cases and the check history', async () => {
    installMockRegister();
    renderAt('/fordon/ABC12D');
    expect(await screen.findByRole('heading', { level: 1, name: /ABC12D/ })).toBeTruthy();
    expect(screen.getAllByText('Efterlyst fordon').length).toBeGreaterThan(0);
    expect(screen.getByRole('link', { name: 'Erik Nilsson' }).getAttribute('href')).toBe('/person/FPD00001');
    expect(within(section('Kopplade ärenden')).getByText('K-1042-26')).toBeTruthy();
    const history = within(section('Kontrollhistorik')).getAllByRole('listitem');
    expect(history).toHaveLength(3);
    expect(history[0]?.textContent).toContain('Kontrollerad av IGV-12 · Karl Lund');
    expect(history[0]?.textContent).toContain('Träff');
  });

  it('Kontrollera runs checkPlate, shows the hit and refreshes the history', async () => {
    const { calls } = installMockRegister();
    renderAt('/fordon/ABC12D');
    await screen.findByRole('heading', { level: 1, name: /ABC12D/ });
    fireEvent.click(screen.getByRole('button', { name: 'Kontrollera' }));
    expect(await screen.findByText('Träff på efterlysning')).toBeTruthy();
    expect(screen.getByText(/ABC12D är efterlyst: Använd vid rånet/)).toBeTruthy();
    expect(calls.mock.calls.find(([a]) => a === 'checkPlate')?.[1]).toEqual({ plate: 'ABC12D' });
    await waitFor(() => expect(within(section('Kontrollhistorik')).getAllByRole('listitem')).toHaveLength(4));
  });

  it('a plate without BOLO checks clear; an unregistered one says so', async () => {
    installMockRegister();
    renderAt('/fordon/GHJ55B');
    await screen.findByRole('heading', { level: 1, name: /GHJ55B/ });
    expect(screen.getByText('Fordonet har inte kontrollerats.')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Kontrollera' }));
    expect(await screen.findByText('GHJ55B: ingen aktiv efterlysning.')).toBeTruthy();

    registerNuiMock('getVehicle', () =>
      toLuaWire({ vehicle: { plate: 'ZZZ99Z', model: null }, owner: null, bolos: [], cases: [], checks: [{ checkedAt: '2026-09-29T08:00:00Z', officer: null, hit: false }] }),
    );
    registerNuiMock('checkPlate', () => toLuaWire({ plate: 'ZZZ99Z', model: null, owner: null, bolo: null, checkedAt: '2026-09-29T10:00:00Z' }));
    cleanup();
    renderAt('/fordon/ZZZ99Z');
    await screen.findByRole('heading', { level: 1, name: /ZZZ99Z/ });
    expect(screen.getByText('Ägare saknas i registret')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Kontrollera' }));
    expect(await screen.findByText(/ZZZ99Z: fordonet finns inte i registret\./)).toBeTruthy();
  });
});
