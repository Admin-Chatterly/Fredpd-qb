// SPDX-License-Identifier: GPL-3.0-only
// Bevis page (Phase 4 UI) and Brottskatalog (task 5.4): the Tekniker queue, the drawer with the chain of custody
// and the result (match only when sent), linking to a case (perm evidence.link), and the virtualised catalogue.
import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react';
import { EVIDENCE_ACTIONS } from '@fredpd/types/evidence';
import { custodyText, resultFields, resultMatch } from '../src/evidence';
import { i18n } from '../src/i18n';
import { clearNuiMocks } from '../src/utils/fetchNui';
import { fakeLayout, installMockRegister, renderAt } from './helpers';

afterEach(() => {
  cleanup();
  clearNuiMocks();
});

const officer = { citizenid: 'OFF00004', displayName: 'Mats Öberg', callsign: 'TEK-01', unit: 'tekniker' };

describe('evidence helpers', () => {
  it('chain lines per action; a transfer without location is a hand-over', () => {
    const at = '2026-09-29T08:00:00Z';
    expect(custodyText(i18n, { at, actor: officer, action: 'collect', location: 'Grove Street', note: null }, { caseNumber: null })).toBe('Säkrat av TEK-01 · Mats Öberg');
    expect(custodyText(i18n, { at, actor: officer, action: 'link', location: null, note: null }, { caseNumber: 'K-1042-26' })).toBe('Kopplat av TEK-01 · Mats Öberg till ärende K-1042-26');
    expect(custodyText(i18n, { at, actor: officer, action: 'transfer', location: null, note: null }, { caseNumber: null })).toBe('Överlämnat till TEK-01 · Mats Öberg');
    expect(custodyText(i18n, { at, actor: null, action: 'transfer', location: 'Förråd 2', note: null }, { caseNumber: null })).toBe('Flyttat av Okänt till Förråd 2');
  });

  it('result: match only when a well-formed one is present; plain fields listed', () => {
    expect(resultMatch({ match: { citizenid: 'FPD00001', name: 'Erik Nilsson' } })).toEqual({ citizenid: 'FPD00001', name: 'Erik Nilsson' });
    expect(resultMatch({ fingerprint: 'FP-1' })).toBeNull();
    expect(resultMatch({ match: 'x' })).toBeNull();
    expect(resultFields({ fingerprint: 'FP-1', match: { citizenid: 'a', name: 'b' }, nested: { a: 1 }, empty: '' })).toEqual([['fingerprint', 'FP-1']]);
  });
});

describe('Bevis page', () => {
  it('the queue lists analysed, unlinked evidence; the drawer shows result and chain', async () => {
    const { calls } = installMockRegister();
    renderAt('/bevis?queue=1');
    const table = await screen.findByRole('table');
    await waitFor(() => expect(within(table).getAllByRole('row')).toHaveLength(1 + 3)); // header + 57, 58, 59
    expect(calls.mock.calls.find(([a]) => a === 'listEvidence')?.[1]).toEqual({ unlinked: true, page: 1 });
    fireEvent.click(within(table).getByText('Blod'));
    const drawer = await screen.findByRole('dialog');
    await within(drawer).findByText('Träff: Mohammed Hassan');
    const chain = [...drawer.querySelectorAll('[data-chain] li > p:first-child')].map((p) => p.textContent);
    expect(chain).toEqual([
      'Säkrat av IGV-07 · Anna Berg',
      'Överlämnat till IGV-07 · Anna Berg',
      'Inlämnat av TEK-01 · Mats Öberg till bevisförrådet',
      'Analyserat av TEK-01 · Mats Öberg',
    ]);
    expect(within(drawer).getByText('DNA-profil')).toBeTruthy();
    // Without perm evidence.link: no link form.
    expect(drawer.querySelector('[data-link-evidence]')).toBeNull();
  });

  it('no match line when the result carries none', async () => {
    installMockRegister();
    renderAt('/bevis?id=57');
    const drawer = await screen.findByRole('dialog');
    await within(drawer).findByText('DNA-0B21-77E4');
    expect(drawer.textContent).not.toContain('Träff:');
  });

  it('links an item to an open case (perm evidence.link) with the case picker', async () => {
    const { calls } = installMockRegister();
    renderAt('/bevis?queue=1&id=59', ['mdt_page:*', 'perm:evidence.link']);
    const drawer = await screen.findByRole('dialog');
    const form = await waitFor(() => {
      const el = drawer.querySelector<HTMLElement>('[data-link-evidence]');
      if (!el) throw new Error('link form not rendered yet');
      return el;
    });
    const box = within(form).getByRole('searchbox');
    fireEvent.change(box, { target: { value: 'K-1042' } });
    fireEvent.keyDown(box, { key: 'Enter' });
    fireEvent.click(await within(form).findByRole('button', { name: /K-1042-26/ }));
    fireEvent.click(within(form).getByRole('button', { name: 'Koppla till ärende' }));
    await within(drawer).findByText('Bevis B-K-1042-26-003 är kopplat till ärende K-1042-26.');
    const input = calls.mock.calls.find(([a]) => a === 'linkEvidence')?.[1];
    expect(input).toEqual({ id: 59, caseId: 1042 });
    expect(EVIDENCE_ACTIONS.linkEvidence.input.safeParse(input).success).toBe(true);
    expect(calls.mock.calls.find(([a]) => a === 'listCases')?.[1]).toEqual({ filter: 'open', query: 'K-1042', page: 1 });
  });

  it('a case filter lists that case’s evidence', async () => {
    const { calls } = installMockRegister();
    renderAt('/bevis?case=1042');
    await screen.findByText('B-K-1042-26-001');
    expect(screen.getByText('B-K-1042-26-002')).toBeTruthy();
    expect(calls.mock.calls.find(([a]) => a === 'listEvidence')?.[1]).toEqual({ caseId: 1042, page: 1 });
  });
});

describe('Brottskatalog', () => {
  it('loads the catalogue once, filters as you type without calling the server, and renders a window', async () => {
    const restore = fakeLayout(600, 900);
    try {
      const { calls } = installMockRegister();
      renderAt('/brottskatalog');
      await screen.findByText('Mord');
      const rendered = document.querySelectorAll('[data-charge]').length;
      expect(rendered).toBeGreaterThan(5);
      expect(rendered).toBeLessThan(40); // ~130 charges, only a window in the DOM
      const box = screen.getByRole('searchbox', { name: 'Sök brott eller lagrum' });
      fireEvent.change(box, { target: { value: 'grovt rån' } });
      await waitFor(() => expect([...document.querySelectorAll('[data-charge]')].map((e) => e.getAttribute('data-charge'))).toEqual(['BRB-023']));
      fireEvent.change(box, { target: { value: '' } });
      fireEvent.click(screen.getByRole('tab', { name: 'Ordningsbot' }));
      await waitFor(() => expect(document.querySelector('[data-charge="BRB-001"]')).toBeNull());
      expect(document.querySelector('[data-charge="TRF-009"]')).toBeTruthy();
      expect(calls.mock.calls.filter(([a]) => a === 'listCharges')).toEqual([['listCharges', {}]]);
    } finally {
      restore();
    }
  });
});
