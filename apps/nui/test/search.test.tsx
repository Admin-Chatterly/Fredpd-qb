// SPDX-License-Identifier: GPL-3.0-only
// Task 2.3: header search (type chip, Enter opens the top hit, Shift+Enter shows the list) and the results page
// (virtualised listbox, ↑/↓/Enter, BOLO flag, kontaktnotis rows that open nothing). Answers come from the dev mock
// register with Lua-style nulls (test/helpers.tsx).
import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest';
import { cleanup, fireEvent, screen, within } from '@testing-library/react';
import { clearNuiMocks } from '../src/utils/fetchNui';
import { detectQueryType, hitPath, searchPath } from '../src/search';
import { fakeLayout, installMockRegister, renderAt } from './helpers';

let restoreLayout: () => void;
beforeAll(() => {
  restoreLayout = fakeLayout();
});
afterAll(() => restoreLayout());
afterEach(() => {
  cleanup();
  clearNuiMocks();
});

function typeAndEnter(value: string, opts: { shiftKey?: boolean } = {}) {
  const box = screen.getByRole('searchbox', { name: 'Sök' });
  fireEvent.change(box, { target: { value } });
  fireEvent.keyDown(box, { key: 'Enter', ...opts });
  return box;
}

describe('search helpers', () => {
  it('detects the query type with config/formats.json (the header chip)', () => {
    expect(detectQueryType('abc 12d')).toBe('plate');
    expect(detectQueryType('K-1042-26')).toBe('caseNumber');
    expect(detectQueryType('19870412-5531')).toBe('personId');
    expect(detectQueryType('Erik Nils')).toBe('name');
    expect(detectQueryType('E')).toBeNull();
  });

  it('routes every hit kind; a kontaktnotis opens nothing', () => {
    expect(hitPath({ kind: 'person', citizenid: 'FPD00001', name: 'Erik Nilsson', birthdate: null, personnummer: null, bolo: false })).toBe('/person/FPD00001');
    expect(hitPath({ kind: 'vehicle', plate: 'ABC12D', model: null, ownerName: null, ownerCitizenid: null, bolo: true })).toBe('/fordon/ABC12D');
    expect(hitPath({ kind: 'case', case: { visibility: 'masked', id: 988, caseNumber: 'K-988-26', title: null, status: 'closed', level: 1, role: null } })).toBe('/arende/988');
    expect(hitPath({ kind: 'case', case: { visibility: 'notice', contact: { displayName: 'Bo', unit: null } } })).toBeNull();
    expect(searchPath(' Erik ', 2)).toBe('/sok?q=Erik&page=2');
  });
});

describe('header search', () => {
  it('shows the detected type while typing', () => {
    installMockRegister();
    renderAt('/');
    const box = screen.getByRole('searchbox', { name: 'Sök' });
    fireEvent.change(box, { target: { value: 'abc 12d' } });
    expect(document.querySelector('[data-search-type]')?.textContent).toBe('Registreringsnummer');
    fireEvent.change(box, { target: { value: '19870412-5531' } });
    expect(document.querySelector('[data-search-type]')?.textContent).toBe('Personnummer');
  });

  it('Enter opens the top person hit directly', async () => {
    const { calls } = installMockRegister();
    renderAt('/');
    typeAndEnter('Erik Nilsson');
    expect(await screen.findByRole('heading', { level: 1, name: /Erik Nilsson/ })).toBeTruthy();
    expect(document.querySelector('[data-person]')?.getAttribute('data-person')).toBe('FPD00001');
    expect(calls.mock.calls.map(([action]) => action)).toEqual(['getHome', 'search', 'getPerson']);
    expect(calls.mock.calls[1]?.[1]).toEqual({ query: 'Erik Nilsson', type: 'auto', page: 1 });
  });

  it('Enter opens the vehicle of a plate and the case of a case number', async () => {
    installMockRegister();
    renderAt('/');
    typeAndEnter('abc 12d');
    expect(await screen.findByRole('heading', { level: 1, name: /ABC12D/ })).toBeTruthy();
    typeAndEnter('K-1042-26');
    // /arende/:id is the Phase 5 placeholder: its subtitle is the id.
    expect(await screen.findByRole('heading', { level: 1, name: 'Ärendenummer' })).toBeTruthy();
    expect(screen.getByText('1042')).toBeTruthy();
  });

  it('a kontaktnotis top hit is not opened: the results page shows only the notice', async () => {
    installMockRegister();
    renderAt('/');
    typeAndEnter('K-1077-26');
    expect(await screen.findByRole('heading', { name: 'Sökresultat' })).toBeTruthy();
    const option = await screen.findByRole('option');
    expect(option.getAttribute('aria-disabled')).toBe('true');
    expect(option.textContent).toBe('KontaktnotisDet finns uppgifter som rör K-1077-26. Kontakta Bo Carlsson (Spaning).');
    // Enter on it stays on the results page.
    fireEvent.keyDown(screen.getByRole('listbox'), { key: 'Enter' });
    expect(screen.getByRole('heading', { name: 'Sökresultat' })).toBeTruthy();
  });

  it('Shift+Enter shows the results list instead of the top hit', async () => {
    installMockRegister();
    renderAt('/');
    typeAndEnter('Erik Nilsson', { shiftKey: true });
    expect(await screen.findByRole('heading', { name: 'Sökresultat' })).toBeTruthy();
    const options = await screen.findAllByRole('option');
    expect(options[0]?.textContent).toContain('Erik Nilsson');
    expect(options[0]?.textContent).toContain('Efterlyst');
  });
});

describe('results page', () => {
  it('is virtualised and keyboard navigable: ↓ ↓ Enter opens the third hit', async () => {
    const { db } = installMockRegister();
    renderAt('/sok?q=Andersson');
    const listbox = await screen.findByRole('listbox', { name: 'Sökresultat' });
    const expected = db.persons
      .filter((p) => p.lastname === 'Andersson' || p.firstname.startsWith('Andersson'))
      .sort((a, b) => a.firstname.localeCompare(b.firstname, 'sv') || a.citizenid.localeCompare(b.citizenid));
    expect(expected.length).toBeGreaterThan(3);
    expect(screen.getByText(`Träffar: ${expected.length}`)).toBeTruthy();
    // Focus lands on the list; the first row is active.
    expect(document.activeElement).toBe(listbox);
    const activeText = () => document.getElementById(listbox.getAttribute('aria-activedescendant') ?? '')?.textContent ?? '';
    expect(activeText()).toContain(`${expected[0]?.firstname} Andersson`);
    fireEvent.keyDown(listbox, { key: 'ArrowDown' });
    fireEvent.keyDown(listbox, { key: 'ArrowDown' });
    fireEvent.keyDown(listbox, { key: 'ArrowUp' });
    fireEvent.keyDown(listbox, { key: 'ArrowDown' });
    const third = expected[2];
    expect(activeText()).toContain(`${third?.firstname} Andersson`);
    expect(within(listbox).getAllByRole('option', { selected: true })).toHaveLength(1);
    fireEvent.keyDown(listbox, { key: 'Enter' });
    expect(await screen.findByRole('heading', { level: 1, name: new RegExp(`${third?.firstname} Andersson`) })).toBeTruthy();
    expect(document.querySelector('[data-person]')?.getAttribute('data-person')).toBe(third?.citizenid);
  });

  it('renders a window of rows for a long result and pages by 50', async () => {
    installMockRegister();
    renderAt('/sok?q=an');
    await screen.findByRole('listbox');
    const total = Number(/Träffar: (\d+)/.exec(document.body.textContent ?? '')?.[1]);
    expect(total).toBeGreaterThan(50);
    // 640 px / 64 px rows = 10 visible + overscan, out of 50 on the page.
    expect(screen.getAllByRole('option').length).toBeLessThan(25);
    expect(screen.getAllByRole('option')[0]?.getAttribute('aria-setsize')).toBe('50');
    fireEvent.click(screen.getByRole('button', { name: 'Nästa' }));
    expect(await screen.findByText(`Sida 2 av ${Math.ceil(total / 50)}`)).toBeTruthy();
  });

  it('a too short query asks for more characters and posts nothing', async () => {
    const { calls } = installMockRegister();
    renderAt('/sok?q=E');
    expect(await screen.findByText('Skriv minst 2 tecken.')).toBeTruthy();
    expect(calls.mock.calls.some(([action]) => action === 'search')).toBe(false);
  });

  it('a masked case hit shows number, status and the restricted badge but no title it did not get', async () => {
    installMockRegister();
    renderAt('/sok?q=K-988-26');
    const option = await screen.findByRole('option');
    expect(option.textContent).toBe('K-988-26AvslutatBegränsad insynBegränsad');
    expect(option.textContent).not.toContain('Narkotikabrott');
  });
});
