// SPDX-License-Identifier: GPL-3.0-only
// Task 7.1 pieces of @fredpd/ui: the MDT host (transport + mode) and the POI sheet.
import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, render, screen } from '@testing-library/react';
import { I18nProvider, MdtHostProvider, PoiSheet, createI18n, knownWarnings, useActionAvailable, useMdtHost, useMdtMode } from '../src';
import type { MdtTransport } from '../src';
import sv from '../../../locales/sv.json';
import en from '../../../locales/en.json';

const i18n = createI18n({ sv, en }, { lang: 'sv', fallbackLang: 'en' });

afterEach(cleanup);

const session = {
  grants: { grants: [], denied: [], tier: 0 as const, units: [], rank: null, computedAt: '2026-09-29T10:00:00.000Z' },
  unit: null,
  me: { citizenid: 'A1', displayName: 'Anna', callsign: null },
};

function Probe() {
  const host = useMdtHost();
  const mode = useMdtMode();
  const check = useActionAvailable('checkPlate');
  const bolo = useActionAvailable('createBolo');
  return <p data-probe>{`${host ? 'host' : 'none'} ${mode} check=${check} bolo=${bolo}`}</p>;
}

describe('MdtHostProvider', () => {
  it('without a provider: no host, tablet mode, everything available', () => {
    render(<Probe />);
    expect(screen.getByText('none tablet check=true bolo=true')).toBeTruthy();
  });

  it('a portal transport hides the world-only actions', () => {
    const transport: MdtTransport = { mode: 'portal', call: async () => ({}) };
    render(
      <MdtHostProvider transport={transport} session={session}>
        <Probe />
      </MdtHostProvider>,
    );
    expect(screen.getByText('host portal check=false bolo=true')).toBeTruthy();
  });
});

describe('PoiSheet', () => {
  const data = { name: 'Omar Nilsson', level: 1 as const, status: 'open' as const, summary: 'Känd för rån', warnings: ['armed', 'bogus'], photoUrl: null };

  it('renders the given fields, only known warnings, and no handler/date rows when absent', () => {
    render(
      <I18nProvider i18n={i18n}>
        <PoiSheet data={data} />
      </I18nProvider>,
    );
    expect(screen.getByText('Omar Nilsson')).toBeTruthy();
    expect(screen.getByText('Beväpnad')).toBeTruthy();
    expect(screen.getByText('Begränsad')).toBeTruthy();
    expect(document.body.textContent).not.toContain('bogus');
    expect(screen.queryByText('Handläggare')).toBeNull();
    expect(document.querySelector('[data-poi-masked]')).toBeNull();
    expect(knownWarnings(['gang', 'x', 'armed'])).toEqual(['armed', 'gang']);
  });

  it('masked: banner; full: handler, date and footer', () => {
    render(
      <I18nProvider i18n={i18n}>
        <PoiSheet data={{ ...data, handler: 'UTR-02 · Olle', updatedAt: '2026-09-10 12:00', citizenid: 'RP502' }} masked footer="Utskrivet" />
      </I18nProvider>,
    );
    expect(document.querySelector('[data-poi-masked]')).not.toBeNull();
    expect(screen.getByText('UTR-02 · Olle')).toBeTruthy();
    expect(screen.getByText('RP502')).toBeTruthy();
    expect(screen.getByText('Utskrivet')).toBeTruthy();
  });
});
