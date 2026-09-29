// SPDX-License-Identifier: GPL-3.0-only
// Public share page and the POI print view: masked data only, expiry, print CSS.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, screen, waitFor } from '@testing-library/react';
import { installFakeService, json, makeUser, renderPortal } from './helpers';
import { safePhotoUrl } from '../src/mdt/extra';

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

const TOKEN = 'AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abcde';

describe('share page /share/:token', () => {
  it('renders only the masked POI fields, without login, fetched as JSON', async () => {
    const service = installFakeService(null);
    service.routes[`GET /api/share/${TOKEN}`] = (init) => {
      expect((init?.headers as Record<string, string>).accept).toBe('application/json');
      return json({
        targetType: 'poi',
        expiresAt: '2026-09-30T10:00:00Z',
        content: {
          type: 'poi',
          name: 'Omar Nilsson',
          level: 0,
          status: 'open',
          summary: 'Känd för rån',
          warnings: ['armed', 'gang', 'made_up'],
          updatedAt: '2026-09-10T10:00:00Z',
          // Not part of the share shape: must never reach the page even if a server bug sent it.
          citizenid: 'RP502',
          owner: { displayName: 'Olle Utredare', callsign: 'UTR-02' },
          notes: 'HEMLIG_TEXT',
        },
      });
    };
    renderPortal(`/share/${TOKEN}`);
    expect(await screen.findByText('Omar Nilsson')).toBeTruthy();
    expect(screen.getByText('Känd för rån')).toBeTruthy();
    expect(screen.getByText('Beväpnad')).toBeTruthy();
    expect(screen.getByText('Kopplad till kriminellt nätverk')).toBeTruthy();
    expect(screen.getByText('Varje visning loggas.')).toBeTruthy();
    const html = document.body.innerHTML;
    for (const secret of ['RP502', 'Olle Utredare', 'UTR-02', 'HEMLIG_TEXT', 'made_up']) expect(html).not.toContain(secret);
    // No login page, no session needed.
    expect(screen.queryByText('Logga in med Discord')).toBeNull();
  });

  it('renders a shared case as released content (no officers or subjects)', async () => {
    const service = installFakeService(null);
    service.routes[`GET /api/share/${TOKEN}`] = () =>
      json({
        targetType: 'case',
        expiresAt: '2026-09-30T10:00:00Z',
        content: { type: 'case', caseNumber: 'K-1-26', status: 'closed', title: 'Skadegörelse på skola', createdAt: '2026-09-01T10:00:00Z', closedAt: '2026-09-02T10:00:00Z', reports: [{ reportNumber: 'K-1-26/1', title: 'Anmälan', body: '**Klotter** på fasaden', createdAt: '2026-09-01T11:00:00Z' }], assignees: ['Olle Utredare'] },
      });
    renderPortal(`/share/${TOKEN}`);
    expect(await screen.findByText('Skadegörelse på skola')).toBeTruthy();
    expect(screen.getByText('Klotter').tagName).toBe('STRONG');
    expect(document.body.innerHTML).not.toContain('Olle Utredare');
  });

  it('says the link has expired for 404 and for a malformed token (without asking the server)', async () => {
    const service = installFakeService(null);
    service.routes[`GET /api/share/${TOKEN}`] = () => json({ error: 'not_found' }, 404);
    renderPortal(`/share/${TOKEN}`);
    expect(await screen.findByText('Länken har gått ut.')).toBeTruthy();
    cleanup();
    service.fetchSpy.mockClear();
    renderPortal('/share/short');
    expect(await screen.findByText('Länken har gått ut.')).toBeTruthy();
    expect(service.fetchSpy.mock.calls.some(([url]) => String(url).includes('/share/'))).toBe(false);
  });

  it('says so when the content is withheld now (level raised after the link was made)', async () => {
    const service = installFakeService(null);
    service.routes[`GET /api/share/${TOKEN}`] = () => json({ targetType: 'poi', expiresAt: '2026-09-30T10:00:00Z' });
    renderPortal(`/share/${TOKEN}`);
    expect(await screen.findByText(/Innehållet är inte längre tillgängligt/)).toBeTruthy();
  });
});

const poiFull = {
  citizenid: 'FPD00001',
  name: 'Erik Nilsson',
  poi: {
    visibility: 'full',
    id: 1,
    level: 1,
    status: 'open',
    unit: 'utredning',
    owner: { citizenid: 'OFF00003', displayName: 'Lina Ek', callsign: 'UTR-03', unit: 'utredning' },
    summary: 'Misstänkt för väpnade rån.',
    warnings: ['armed'],
    updatedAt: '2026-09-10T10:00:00Z',
    updatedBy: null,
    editable: true,
  },
};

describe('POI photo URLs', () => {
  it('keeps only our own /upload/<file> path and drops every other host or scheme', () => {
    expect(safePhotoUrl('/upload/0123456789abcdef0123456789abcdef.png')).toBe('/upload/0123456789abcdef0123456789abcdef.png');
    expect(safePhotoUrl('http://127.0.0.1:3000/upload/abc.webp')).toBe('/upload/abc.webp');
    expect(safePhotoUrl('https://evil.example/track.png')).toBeNull();
    expect(safePhotoUrl('https://evil.example/upload/../x.png')).toBeNull();
    expect(safePhotoUrl('//evil.example/upload/a.png')).toBeNull();
    expect(safePhotoUrl('/upload/../secret.png')).toBeNull();
    expect(safePhotoUrl('/upload/a.png?x=1')).toBeNull();
    expect(safePhotoUrl('javascript:alert(1)')).toBeNull();
    expect(safePhotoUrl('data:image/png;base64,AAAA')).toBeNull();
    expect(safePhotoUrl(null)).toBeNull();
  });

  it('the share page never loads a third-party photo', async () => {
    const service = installFakeService(null);
    service.routes[`GET /api/share/${TOKEN}`] = () =>
      json({
        targetType: 'poi',
        expiresAt: '2026-09-30T10:00:00Z',
        content: { type: 'poi', name: 'Omar Nilsson', level: 0, status: 'open', summary: 'x', warnings: [], photoUrl: 'https://tracker.example/p.png', updatedAt: '2026-09-10T10:00:00Z' },
      });
    renderPortal(`/share/${TOKEN}`);
    expect(await screen.findByText('Omar Nilsson')).toBeTruthy();
    expect(document.querySelector('img')).toBeNull();
    expect(document.body.innerHTML).not.toContain('tracker.example');
  });
});

describe('POI sheet print view', () => {
  it('renders the sheet, prints with window.print and keeps controls out of the print', async () => {
    const service = installFakeService(makeUser());
    service.routes['POST /api/mdt/getPoi'] = () => json(poiFull);
    const print = vi.spyOn(window, 'print').mockImplementation(() => {});
    renderPortal('/person/FPD00001/poi');
    expect(await screen.findByText('Misstänkt för väpnade rån.')).toBeTruthy();
    expect(screen.getByText('UTR-03 · Lina Ek')).toBeTruthy();
    expect(screen.getByText(/Utskrivet .* av Anna Berg/)).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Skriv ut' }));
    expect(print).toHaveBeenCalledOnce();
    // Share box, back link and print button are marked for the print CSS; the sheet is not.
    expect(document.querySelector('[data-poi-sheet]')?.closest('[data-print-hide]')).toBeNull();
    expect(screen.getByRole('button', { name: 'Skriv ut' }).closest('[data-print-hide]')).not.toBeNull();
    expect(screen.getByRole('button', { name: 'Skapa delningslänk' }).closest('[data-print-hide]')).not.toBeNull();
    expect(document.querySelector('aside')?.className).toContain('print:hidden');
  });

  it('the print stylesheet hides the frame and the marked controls and unrolls the scroll area', () => {
    const css = readFileSync(join(__dirname, '../src/index.css'), 'utf8');
    const print = css.slice(css.indexOf('@media print'));
    expect(print).toMatch(/\[data-print-hide\][^{]*\{\s*display:\s*none !important/);
    expect(print).toMatch(/aside/);
    expect(print).toMatch(/main\s*\{\s*overflow:\s*visible !important/);
    expect(print).toMatch(/\.poi-sheet/);
  });

  it('masked sheet: banner, no handler, no share box; kontaktnotis: only the notice', async () => {
    const service = installFakeService(makeUser());
    service.routes['POST /api/mdt/getPoi'] = () => json({ ...poiFull, poi: { ...poiFull.poi, visibility: 'masked', owner: undefined } });
    renderPortal('/person/FPD00001/poi');
    expect(await screen.findByText('Misstänkt för väpnade rån.')).toBeTruthy();
    expect(document.querySelector('[data-poi-masked]')).not.toBeNull();
    expect(screen.queryByText('Handläggare')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Skapa delningslänk' })).toBeNull();
    cleanup();
    service.routes['POST /api/mdt/getPoi'] = () => json({ citizenid: 'FPD00001', name: 'Erik Nilsson', poi: { visibility: 'notice', contact: { displayName: 'Lina Ek', unit: 'utredning' } } });
    renderPortal('/person/FPD00001/poi');
    await waitFor(() => expect(document.querySelector('[data-poi-sheet]')).toBeNull());
    expect(await screen.findByText(/Lina Ek/)).toBeTruthy();
    expect(screen.queryByText('Misstänkt för väpnade rån.')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Skriv ut' })).toBeNull();
  });

  it('creates a share link with the chosen expiry', async () => {
    const service = installFakeService(makeUser());
    service.routes['POST /api/mdt/getPoi'] = () => json(poiFull);
    service.routes['POST /api/mdt/createShare'] = (init) => {
      expect(JSON.parse(String(init?.body))).toEqual({ targetType: 'poi', targetId: 'FPD00001', expiresInHours: 4 });
      return json({ id: 3, token: TOKEN, path: `/share/${TOKEN}`, expiresAt: '2026-09-29T14:00:00Z', maxLevel: 1 });
    };
    renderPortal('/person/FPD00001/poi');
    await screen.findByText('Misstänkt för väpnade rån.');
    fireEvent.change(screen.getByLabelText('Giltighetstid'), { target: { value: '4' } });
    fireEvent.click(screen.getByRole('button', { name: 'Skapa delningslänk' }));
    const link = (await screen.findByRole('textbox', { name: 'Dela' })) as HTMLInputElement;
    expect(link.value).toBe(`${window.location.origin}/share/${TOKEN}`);
    expect(screen.getByText('Varje visning loggas.')).toBeTruthy();
  });
});
