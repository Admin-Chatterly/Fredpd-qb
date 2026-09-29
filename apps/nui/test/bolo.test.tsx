// SPDX-License-Identifier: GPL-3.0-only
// Task 2.6 UI: the createBolo input the form builds (checked with BoloCreateInputSchema), the Efterlysningar page
// (active / all, create through the subject picker, resolve with a note, errors) and the perm hints.
import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react';
import { BoloCreateInputSchema } from '@fredpd/types/mdt';
import { boloStatus, buildBoloCreateInput, checkBoloForm, initialBoloForm } from '../src/bolo';
import type { BoloForm } from '../src/bolo';
import { clearNuiMocks } from '../src/utils/fetchNui';
import { installMockRegister, renderAt } from './helpers';

afterEach(() => {
  cleanup();
  clearNuiMocks();
});

const person = { kind: 'person', citizenid: 'FPD00002', label: 'Maria Karlsson' } as const;
const vehicle = { kind: 'vehicle', plate: 'GHJ55B', label: 'GHJ55B · asea' } as const;

describe('createBolo input', () => {
  it('person: citizenid only, reason trimmed, default level, no expiry key', () => {
    const form: BoloForm = { ...initialBoloForm('person', person), reason: '  Misstänkt för rån.  ' };
    const input = buildBoloCreateInput(form);
    expect(input).toEqual({ kind: 'person', citizenid: 'FPD00002', reason: 'Misstänkt för rån.', level: 0 });
    expect(BoloCreateInputSchema.parse(input)).toEqual(input);
  });

  it('vehicle: plate only, level and expiry as chosen', () => {
    const form: BoloForm = { ...initialBoloForm('vehicle', vehicle), reason: 'Stulen i natt', level: 1, expiresInHours: 72 };
    const input = buildBoloCreateInput(form);
    expect(input).toEqual({ kind: 'vehicle', plate: 'GHJ55B', reason: 'Stulen i natt', level: 1, expiresInHours: 72 });
    expect(BoloCreateInputSchema.safeParse(input).success).toBe(true);
    expect(checkBoloForm(form, 1)).toEqual({ ok: true, input });
  });

  it('a subject of the other kind is dropped (never citizenid and plate together)', () => {
    const form: BoloForm = { kind: 'vehicle', subject: person, reason: 'Stulen bil', level: 0, expiresInHours: null };
    expect(buildBoloCreateInput(form)).toEqual({ kind: 'vehicle', reason: 'Stulen bil', level: 0 });
    expect(initialBoloForm('vehicle', person).subject).toBeNull();
  });

  it('reports the fields to fix: subject, short reason, level above the tier', () => {
    expect(checkBoloForm({ ...initialBoloForm('person'), reason: 'ok' }, 0)).toEqual({ ok: false, issues: expect.arrayContaining(['subject', 'reason']) });
    const high: BoloForm = { ...initialBoloForm('person', person), reason: 'Misstänkt för rån.', level: 2 };
    expect(checkBoloForm(high, 1)).toEqual({ ok: false, issues: ['level'] });
    expect(checkBoloForm(high, 2).ok).toBe(true);
  });

  it('status: active, resolved, expired', () => {
    expect(boloStatus({ active: true, resolvedAt: null })).toBe('active');
    expect(boloStatus({ active: false, resolvedAt: '2026-09-29T08:00:00Z' })).toBe('resolved');
    expect(boloStatus({ active: false, resolvedAt: null })).toBe('expired');
  });
});

describe('Efterlysningar page', () => {
  const rows = () => screen.getAllByRole('row').slice(1);

  it('lists live BOLOs, and all of them with the filter', async () => {
    const { calls } = installMockRegister();
    renderAt('/efterlysning');
    await screen.findByText('Erik Nilsson');
    expect(rows().map((r) => r.querySelector('td:nth-child(2)')?.textContent)).toEqual(['ABC12D · sultan', 'Erik Nilsson', 'XYZ98A · sentinel']);
    expect(rows()[2]?.textContent).toContain('Begränsad');
    fireEvent.click(screen.getByRole('tab', { name: 'Alla' }));
    await waitFor(() => expect(rows()).toHaveLength(5));
    expect(screen.getByText('Återkallad', { selector: 'span' })).toBeTruthy();
    expect(screen.getByText('Utgången', { selector: 'span' })).toBeTruthy();
    expect(calls.mock.calls.filter(([a]) => a === 'listBolos').map(([, input]) => input)).toEqual([
      { active: true, page: 1 },
      { active: false, page: 1 },
    ]);
  });

  it('creates a vehicle BOLO through the subject picker (search action)', async () => {
    const { calls } = installMockRegister();
    renderAt('/efterlysning');
    await screen.findByText('Erik Nilsson');
    fireEvent.click(screen.getByRole('button', { name: 'Ny efterlysning' }));
    const dialog = screen.getByRole('dialog', { name: 'Ny efterlysning' });
    fireEvent.click(within(dialog).getByRole('radio', { name: 'Fordon' }));
    const picker = within(dialog).getByRole('searchbox', { name: 'Sök registreringsnummer' });
    fireEvent.change(picker, { target: { value: 'ghj 55b' } });
    fireEvent.keyDown(picker, { key: 'Enter' });
    fireEvent.click(await within(dialog).findByRole('button', { name: 'GHJ55B · asea' }));
    expect(calls.mock.calls.find(([a]) => a === 'search')?.[1]).toEqual({ query: 'ghj 55b', type: 'vehicle', page: 1 });
    fireEvent.change(within(dialog).getByRole('textbox', { name: 'Anledning' }), { target: { value: 'Stulen under natten, Mirror Park.' } });
    fireEvent.change(within(dialog).getByRole('combobox', { name: /Sekretessnivå/ }), { target: { value: '1' } });
    fireEvent.click(within(dialog).getByRole('button', { name: 'Efterlys' }));
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    const sent = calls.mock.calls.find(([a]) => a === 'createBolo')?.[1];
    expect(sent).toEqual({ kind: 'vehicle', plate: 'GHJ55B', reason: 'Stulen under natten, Mirror Park.', level: 1 });
    expect(BoloCreateInputSchema.safeParse(sent).success).toBe(true);
    expect(await screen.findByText('GHJ55B · asea')).toBeTruthy();
  });

  it('validates before sending and shows the server refusal (duplicate)', async () => {
    const { calls } = installMockRegister();
    renderAt('/efterlysning');
    await screen.findByText('Erik Nilsson');
    fireEvent.click(screen.getByRole('button', { name: 'Ny efterlysning' }));
    const dialog = screen.getByRole('dialog', { name: 'Ny efterlysning' });
    fireEvent.click(within(dialog).getByRole('button', { name: 'Efterlys' }));
    expect(within(dialog).getByText('Välj en person eller ett fordon.')).toBeTruthy();
    expect(within(dialog).getByText('Minst 3 tecken.')).toBeTruthy();
    expect(calls.mock.calls.some(([a]) => a === 'createBolo')).toBe(false);

    const picker = within(dialog).getByRole('searchbox', { name: 'Sök namn eller personnummer' });
    fireEvent.change(picker, { target: { value: '19870412-5531' } });
    fireEvent.keyDown(picker, { key: 'Enter' });
    fireEvent.click(await within(dialog).findByRole('button', { name: 'Erik Nilsson (19870412-5531)' }));
    fireEvent.change(within(dialog).getByRole('textbox', { name: 'Anledning' }), { target: { value: 'Ny efterlysning på samma person' } });
    fireEvent.click(within(dialog).getByRole('button', { name: 'Efterlys' }));
    expect(await within(dialog).findByText('Det finns redan en aktiv efterlysning på Erik Nilsson (19870412-5531).')).toBeTruthy();
  });

  it('levels above the viewer tier cannot be chosen', async () => {
    installMockRegister({ tier: 0 });
    renderAt('/efterlysning', ['mdt_page:*', 'perm:bolo.create'], { tier: 0 });
    await screen.findByText('Erik Nilsson');
    fireEvent.click(screen.getByRole('button', { name: 'Ny efterlysning' }));
    const options = within(screen.getByRole('combobox', { name: /Sekretessnivå/ })).getAllByRole('option') as HTMLOptionElement[];
    expect(options.map((o) => [o.textContent, o.disabled])).toEqual([
      ['Standard', false],
      ['Begränsad', true],
      ['Hemlig', true],
    ]);
  });

  it('resolves a BOLO with a note', async () => {
    const { calls } = installMockRegister();
    renderAt('/efterlysning');
    await screen.findByText('Erik Nilsson');
    const erik = rows().find((r) => r.textContent?.includes('Erik Nilsson'));
    fireEvent.click(within(erik as HTMLElement).getByRole('button', { name: 'Återkalla efterlysning' }));
    const dialog = screen.getByRole('dialog', { name: 'Återkalla efterlysning' });
    expect(within(dialog).getByText('Återkalla efterlysningen på Erik Nilsson?')).toBeTruthy();
    fireEvent.change(within(dialog).getByRole('textbox'), { target: { value: ' Gripen vid Legion Square. ' } });
    fireEvent.click(within(dialog).getByRole('button', { name: 'Återkalla efterlysning' }));
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
    expect(calls.mock.calls.find(([a]) => a === 'resolveBolo')?.[1]).toEqual({ id: 1, note: 'Gripen vid Legion Square.' });
    expect(await screen.findByText('Efterlysningen är återkallad.')).toBeTruthy();
    await waitFor(() => expect(rows()).toHaveLength(2));
  });

  it('without bolo.create / bolo.resolve the buttons are not shown (UI hint only)', async () => {
    installMockRegister();
    renderAt('/efterlysning', ['mdt_page:*']);
    await screen.findByText('Erik Nilsson');
    expect(screen.queryByRole('button', { name: 'Ny efterlysning' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Återkalla efterlysning' })).toBeNull();
  });
});
