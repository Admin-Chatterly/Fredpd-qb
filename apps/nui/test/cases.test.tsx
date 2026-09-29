// SPDX-License-Identifier: GPL-3.0-only
// Task 5.2: Ärenden list and case page. A kontaktnotis renders ONLY the Notice (no number, title, level, sections);
// a masked case never renders the fields the server nulled (title, summary, report titles above the tier); a full
// case shows every section and its writes (assign, subject, close) send the contract's inputs.
import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react';
import { RECORDS_ACTIONS } from '@fredpd/types/records';
import { clearNuiMocks, registerNuiMock } from '../src/utils/fetchNui';
import { toLuaWire } from '../src/api/wire';
import { installMockRegister, renderAt } from './helpers';

afterEach(() => {
  cleanup();
  clearNuiMocks();
});

const region = (name: string) => screen.getByRole('region', { name });
const lastInput = (calls: { mock: { calls: [string, unknown][] } }, action: string) => calls.mock.calls.filter(([a]) => a === action).at(-1)?.[1];

describe('Ärenden list', () => {
  it('lists my cases, switches filters and searches; notice rows are only the Notice', async () => {
    const { calls } = installMockRegister();
    renderAt('/arenden');
    expect(await screen.findByText('K-1042-26')).toBeTruthy();
    expect(screen.getByText('K-1101-26')).toBeTruthy();
    expect(lastInput(calls, 'listCases')).toEqual({ filter: 'mine', page: 1 });

    fireEvent.click(screen.getByRole('tab', { name: 'Alla' }));
    await screen.findByText('K-988-26');
    const notices = screen.getAllByRole('note');
    expect(notices.length).toBe(2);
    expect(document.body.textContent).not.toContain('K-1077-26');
    expect(document.body.textContent).not.toContain('Olaga vapeninnehav');
    expect(document.body.textContent).not.toContain('Narkotikabrott, Sandy Shores'); // masked without title

    const search = screen.getByRole('searchbox', { name: 'Sök ärendenummer eller rubrik' });
    fireEvent.change(search, { target: { value: 'rån' } });
    fireEvent.keyDown(search, { key: 'Enter' });
    await waitFor(() => expect(lastInput(calls, 'listCases')).toEqual({ filter: 'all', page: 1, query: 'rån' }));
    await waitFor(() => expect(screen.queryByText('K-1101-26')).toBeNull());
    expect(screen.getByText('K-1042-26')).toBeTruthy();
  });

  it('Nytt ärende (perm cases.create) creates the case and opens it', async () => {
    const { calls } = installMockRegister();
    renderAt('/arenden', ['mdt_page:*', 'perm:cases.create']);
    fireEvent.click(await screen.findByRole('button', { name: 'Nytt ärende' }));
    const dialog = screen.getByRole('dialog');
    fireEvent.change(within(dialog).getByLabelText('Rubrik'), { target: { value: 'Inbrott i villa' } });
    fireEvent.click(within(dialog).getByRole('button', { name: 'Skapa' }));
    expect(await screen.findByRole('heading', { level: 1, name: /Inbrott i villa/ })).toBeTruthy();
    const input = lastInput(calls, 'createCase');
    expect(RECORDS_ACTIONS.createCase.input.safeParse(input).success).toBe(true);
    expect(input).toEqual({ title: 'Inbrott i villa', level: 0 });
  });

  it('without perm cases.create there is no create button', async () => {
    installMockRegister();
    renderAt('/arenden');
    await screen.findByText('K-1042-26');
    expect(screen.queryByRole('button', { name: 'Nytt ärende' })).toBeNull();
  });
});

describe('case page', () => {
  it('a kontaktnotis renders only the Notice: no number, title, level or sections', async () => {
    const { db } = installMockRegister();
    renderAt('/arende/1077');
    const note = await screen.findByRole('note');
    expect(note.textContent).toBe('KontaktnotisDet finns uppgifter som rör ett ärende. Kontakta Bo Carlsson (Spaning).');
    const hidden = db.cases.find((c) => c.id === 1077)!;
    expect(document.body.textContent).not.toContain(hidden.caseNumber);
    expect(document.body.textContent).not.toContain(hidden.title);
    expect(document.body.textContent).not.toContain('Hemlig');
    expect(screen.queryByRole('region')).toBeNull();
    expect(screen.queryByRole('heading', { level: 1 })).toBeNull();
  });

  it('a notice with fields it must not have still renders only the Notice (the page reads nothing else)', async () => {
    registerNuiMock('getCase', () => toLuaWire({ visibility: 'notice', contact: { displayName: null, unit: 'span' }, caseNumber: 'K-5-26', title: 'LÄCKA' }));
    renderAt('/arende/5');
    await screen.findByRole('note');
    expect(document.body.textContent).not.toContain('K-5-26');
    expect(document.body.textContent).not.toContain('LÄCKA');
  });

  it('a masked case never renders the fields the server nulled (null or absent)', async () => {
    installMockRegister();
    renderAt('/arende/988');
    expect(await screen.findByRole('heading', { level: 1, name: 'K-988-26' })).toBeTruthy();
    expect(screen.getByText('Delvis maskerat')).toBeTruthy();
    expect(document.body.textContent).not.toContain('Narkotikabrott');
    expect(document.body.textContent).not.toContain('null');
    expect(document.body.textContent).not.toContain('undefined');
    // Read-only: no write controls.
    expect(screen.queryByRole('button', { name: 'Avsluta ärendet' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Lägg till handläggare' })).toBeNull();
  });

  it('a full case shows header, assignees, subjects, reports (hidden titles not rendered), evidence and timeline', async () => {
    installMockRegister();
    renderAt('/arende/1042');
    expect(await screen.findByRole('heading', { level: 1, name: /K-1042-26.*Grovt rån/ })).toBeTruthy();
    expect(within(region('Handläggare')).getByText('IGV-07 · Anna Berg')).toBeTruthy();
    expect(within(region('Handläggare')).getByText('IGV-12 · Karl Lund')).toBeTruthy();
    expect(within(region('Inblandade')).getByRole('link', { name: 'Erik Nilsson' }).getAttribute('href')).toBe('/person/FPD00001');
    const reports = within(region('Rapporter')).getAllByRole('link');
    expect(reports.map((a) => a.getAttribute('href'))).toEqual(['/rapport/811', '/rapport/812', '/rapport/813']);
    expect(document.body.textContent).not.toContain('Hemlig rapport från källa'); // level 2 > tier 1: title null
    expect(within(region('Bevis')).getByText('B-K-1042-26-001')).toBeTruthy();
    expect(within(region('Händelser')).getByText('Ärende upprättat')).toBeTruthy();
    expect(within(region('Händelser')).getAllByText('Rapport registrerad').length).toBe(3);
  });

  it('adds and removes an assignee, adds a subject through the search picker, closes with a resolution', async () => {
    const { calls } = installMockRegister();
    renderAt('/arende/1101');
    await screen.findByRole('heading', { level: 1, name: /K-1101-26/ });

    // Assignee from the on-duty roster (getUnits).
    const assignees = region('Handläggare');
    const officer = await within(assignees).findByRole('combobox', { name: 'Polis i tjänst' });
    await waitFor(() => expect(within(officer).getByRole('option', { name: 'SPAN-02 · Bo Carlsson' })).toBeTruthy());
    fireEvent.change(officer, { target: { value: 'OFF00002' } });
    fireEvent.click(within(assignees).getByRole('button', { name: 'Lägg till handläggare' }));
    await waitFor(() => expect(document.querySelector('[data-assignee="OFF00002"]')?.textContent).toContain('SPAN-02 · Bo Carlsson'));
    expect(lastInput(calls, 'assignCase')).toEqual({ id: 1101, citizenid: 'OFF00002', role: 'member' });
    const bo = document.querySelector('[data-assignee="OFF00002"]') as HTMLElement;
    fireEvent.click(within(bo).getByRole('button', { name: 'Ta bort handläggare' }));
    await waitFor(() => expect(document.querySelector('[data-assignee="OFF00002"]')).toBeNull());
    expect(lastInput(calls, 'unassignCase')).toEqual({ id: 1101, citizenid: 'OFF00002' });

    // Subject: person search → pick.
    fireEvent.click(within(region('Inblandade')).getByRole('button', { name: 'Lägg till inblandad' }));
    const form = document.querySelector('[data-subject-form]') as HTMLElement;
    fireEvent.change(within(form).getByRole('combobox', { name: 'Roll' }), { target: { value: 'witness' } });
    const box = within(form).getByRole('searchbox');
    fireEvent.change(box, { target: { value: 'Johan Andersson' } });
    fireEvent.keyDown(box, { key: 'Enter' });
    fireEvent.click(await within(form).findByRole('button', { name: 'Johan Andersson (19790105-1238)' }));
    await waitFor(() => expect(within(region('Inblandade')).getByRole('link', { name: 'Johan Andersson' })).toBeTruthy());
    const subjectInput = lastInput(calls, 'addCaseSubject');
    expect(subjectInput).toEqual({ id: 1101, type: 'person', citizenid: 'FPD00003', role: 'witness' });
    expect(RECORDS_ACTIONS.addCaseSubject.input.safeParse(subjectInput).success).toBe(true);

    // Close with a resolution (min 3 characters).
    fireEvent.click(screen.getByRole('button', { name: 'Avsluta ärendet' }));
    const dialog = screen.getByRole('dialog');
    const confirm = within(dialog).getByRole('button', { name: 'Avsluta ärendet' }) as HTMLButtonElement;
    expect(confirm.disabled).toBe(true);
    fireEvent.change(within(dialog).getByLabelText('Avslutsanteckning'), { target: { value: 'Gärningsperson lagförd.' } });
    fireEvent.click(confirm);
    await waitFor(() => expect(screen.getByText('Avslutat', { selector: 'span' })).toBeTruthy());
    expect(lastInput(calls, 'closeCase')).toEqual({ id: 1101, resolution: 'Gärningsperson lagförd.' });
    expect(screen.queryByRole('button', { name: 'Avsluta ärendet' })).toBeNull();
  });

  it('Ny rapport offers the templates and opens the created report', async () => {
    const { calls } = installMockRegister();
    renderAt('/arende/1101');
    fireEvent.click(await screen.findByRole('button', { name: 'Ny rapport' }));
    const dialog = screen.getByRole('dialog');
    fireEvent.change(within(dialog).getByLabelText('Rubrik'), { target: { value: 'Anmälan om misshandel' } });
    const template = within(dialog).getByRole('combobox', { name: 'Mall' });
    await waitFor(() => expect(within(template).getByRole('option', { name: 'Anmälan – misshandel' })).toBeTruthy());
    fireEvent.change(template, { target: { value: '1' } });
    fireEvent.click(within(dialog).getByRole('button', { name: 'Skapa' }));
    expect(await screen.findByRole('heading', { level: 1, name: /Anmälan om misshandel/ })).toBeTruthy();
    expect(lastInput(calls, 'createReport')).toEqual({ caseId: 1101, title: 'Anmälan om misshandel', level: 0, templateId: 1 });
    expect((screen.getByRole('textbox', { name: 'Rapporttext' }) as HTMLTextAreaElement).value).toContain('## Händelseförlopp');
  });

  it('an invalid id shows "not found" without calling anything', async () => {
    const { calls } = installMockRegister();
    renderAt('/arende/abc');
    expect(await screen.findByText('Ärendet hittades inte.')).toBeTruthy();
    expect(calls.mock.calls.filter(([a]) => a === 'getCase')).toEqual([]);
  });
});
