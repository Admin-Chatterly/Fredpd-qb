// SPDX-License-Identifier: GPL-3.0-only
// Task 2.7: Hem makes one getHome call; the variant (unit first, then the server's) picks the order of the count
// cards (first one emphasised) and the blocks; Ledning shows the roster; grants hide cards and blocks.
import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, screen, waitFor, within } from '@testing-library/react';
import { HOME_LAYOUTS, homeLayoutFor, selectHomeVariant } from '../src/pages/HomePage';
import { clearNuiMocks } from '../src/utils/fetchNui';
import { installMockRegister, renderAt } from './helpers';

afterEach(() => {
  cleanup();
  clearNuiMocks();
});

const stats = () => [...document.querySelectorAll('[data-stat]')].map((e) => e.getAttribute('data-stat'));
const blocks = () => screen.getAllByRole('heading', { level: 2 }).map((h) => h.textContent);

describe('variant selection', () => {
  it('uses the primary unit, then the server variant, then default', () => {
    expect(selectHomeVariant('tekniker', 'igv')).toBe('tekniker');
    expect(selectHomeVariant('ledning')).toBe('ledning');
    expect(selectHomeVariant(null, 'span')).toBe('span');
    expect(selectHomeVariant('unknown-unit', 'utredning')).toBe('utredning');
    expect(selectHomeVariant(null)).toBe('default');
    expect(selectHomeVariant(undefined, null)).toBe('default');
  });

  it('every variant has its own card order; only Ledning has the roster', () => {
    expect(HOME_LAYOUTS.igv.stats[0]).toBe('activeBolos');
    expect(HOME_LAYOUTS.utredning.stats[0]).toBe('myOpenCases');
    expect(HOME_LAYOUTS.ledning.stats[0]).toBe('onDuty');
    expect(HOME_LAYOUTS.utredning.blocks[0]).toBe('myCases');
    for (const [variant, layout] of Object.entries(HOME_LAYOUTS)) expect(layout.blocks.includes('roster')).toBe(variant === 'ledning');
  });

  it('drops cards and blocks without their mdt_page grant', () => {
    const grants = { grants: ['mdt_page:cases'], denied: [] };
    expect(homeLayoutFor('igv', grants)).toEqual({ stats: ['onDuty', 'myOpenCases'], blocks: ['myCases'] });
    expect(homeLayoutFor('ledning', { grants: ['mdt_page:*'], denied: ['mdt_page:roster'] }).blocks).toEqual(['recentBolos', 'myCases']);
  });
});

describe('Hem page', () => {
  it('IGV: one getHome call, BOLO count emphasised, recent BOLOs then my cases, no roster', async () => {
    const { calls } = installMockRegister();
    renderAt('/');
    expect(document.querySelector('[data-home-variant]')?.getAttribute('data-home-variant')).toBe('igv');
    await screen.findByText('Använd vid rånet på Legion Square. Svart Sultan med skadad bakruta.');
    expect(calls.mock.calls.map(([a]) => a)).toEqual(['getHome']);
    expect(stats()).toEqual(['activeBolos', 'onDuty', 'myOpenCases']);
    expect(document.querySelector('[data-emphasis]')?.getAttribute('data-stat')).toBe('activeBolos');
    const bolosCard = document.querySelector('[data-stat="activeBolos"]');
    expect(bolosCard?.textContent).toBe('3Aktiva efterlysningar');
    expect(bolosCard?.getAttribute('href')).toBe('/efterlysning');
    expect(document.querySelector('[data-stat="myOpenCases"]')?.textContent).toBe('2Mina öppna ärenden');
    expect(document.querySelector('[data-stat="onDuty"]')?.textContent).toBe('5I tjänst');
    expect(blocks()).toEqual(['Aktiva efterlysningar', 'Mina ärenden']);
    expect(screen.queryByRole('table', { name: 'Tjänstgörande personal' })).toBeNull();
    // Recent BOLOs link to their subject.
    expect(screen.getByRole('link', { name: 'Erik Nilsson' }).getAttribute('href')).toBe('/person/FPD00001');
  });

  it('Utredning puts my cases first', async () => {
    installMockRegister({ unit: 'utredning' });
    renderAt('/', undefined, { unit: 'utredning' });
    await screen.findByText('Misshandel, Vespucci Beach');
    expect(stats()).toEqual(['myOpenCases', 'activeBolos', 'onDuty']);
    expect(blocks()).toEqual(['Mina ärenden', 'Aktiva efterlysningar']);
  });

  it('Ledning shows the roster with on/off duty', async () => {
    installMockRegister({ unit: 'ledning' });
    renderAt('/', undefined, { unit: 'ledning' });
    const roster = await screen.findByRole('table', { name: 'Tjänstgörande personal' });
    expect(stats()[0]).toBe('onDuty');
    expect(blocks()[0]).toBe('Tjänstgörande personal');
    const bo = within(roster).getByText('Bo Carlsson').closest('tr');
    expect(bo?.textContent).toBe('SPAN-02Bo CarlssonSpaningI tjänst');
    const mats = within(roster).getByText('Mats Öberg').closest('tr');
    expect(mats?.textContent).toContain('Ej i tjänst');
    // No callsign / unit: nothing rendered for them.
    expect(within(roster).getByText('Jonas Wikström').closest('tr')?.textContent).toBe('Jonas WikströmEj i tjänst');
  });

  it('without a unit the server variant is used', async () => {
    installMockRegister({ unit: null });
    renderAt('/', undefined, { unit: null });
    // The mock server answers `igv` for a member without a unit.
    await waitFor(() => expect(document.querySelector('[data-home-variant]')?.getAttribute('data-home-variant')).toBe('igv'));
  });
});
