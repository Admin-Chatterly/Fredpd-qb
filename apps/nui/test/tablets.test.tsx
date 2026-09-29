// SPDX-License-Identifier: GPL-3.0-only
// Ledning → Surfplattor: listTablets and the revoke / reinstate toggle (perm tablets.manage, a UI hint).
import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react';
import { clearNuiMocks } from '../src/utils/fetchNui';
import { installMockRegister, renderAt } from './helpers';

afterEach(() => {
  cleanup();
  clearNuiMocks();
});

const row = (serial: string) => screen.getByText(serial).closest('tr') as HTMLElement;

describe('Surfplattor', () => {
  it('is reached from the Ledning page', async () => {
    installMockRegister();
    renderAt('/ledning');
    fireEvent.click(await screen.findByRole('link', { name: 'Surfplattor' }));
    expect(await screen.findByRole('heading', { level: 1, name: 'Surfplattor' })).toBeTruthy();
    expect(await screen.findByText('PT-00012')).toBeTruthy();
  });

  it('revoking asks first, then sends setTabletRevoked; reinstating is direct', async () => {
    const { calls, db } = installMockRegister();
    renderAt('/ledning/surfplattor');
    await screen.findByText('PT-00013');
    expect(within(row('PT-00015')).getByText('Spärrad')).toBeTruthy();
    fireEvent.click(within(row('PT-00013')).getByRole('button', { name: 'Spärra' }));
    const dialog = screen.getByRole('dialog', { name: 'Spärra' });
    expect(within(dialog).getByText('Spärra surfplatta PT-00013? Den slutar fungera direkt.')).toBeTruthy();
    expect(calls.mock.calls.some(([a]) => a === 'setTabletRevoked')).toBe(false);
    fireEvent.click(within(dialog).getByRole('button', { name: 'Spärra' }));
    expect(await screen.findByText('Surfplatta PT-00013 är spärrad.')).toBeTruthy();
    expect(calls.mock.calls.find(([a]) => a === 'setTabletRevoked')?.[1]).toEqual({ serial: 'PT-00013', revoked: true });
    await waitFor(() => expect(within(row('PT-00013')).getByText('Spärrad')).toBeTruthy());
    expect(db.tablets.find((x) => x.serial === 'PT-00013')?.revoked).toBe(true);

    fireEvent.click(within(row('PT-00015')).getByRole('button', { name: 'Häv spärren' }));
    expect(await screen.findByText('Spärren för surfplatta PT-00015 är hävd.')).toBeTruthy();
    expect(calls.mock.calls.filter(([a]) => a === 'setTabletRevoked').map(([, i]) => i)).toEqual([
      { serial: 'PT-00013', revoked: true },
      { serial: 'PT-00015', revoked: false },
    ]);
  });

  it('without tablets.manage: no list call, an unauthorized message', async () => {
    const { calls } = installMockRegister();
    renderAt('/ledning/surfplattor', ['mdt_page:*']);
    expect(await screen.findByText('Du har inte behörighet att göra det här.')).toBeTruthy();
    expect(calls.mock.calls.some(([a]) => a === 'listTablets')).toBe(false);
  });

  it('without mdt_page:command the section is guarded', async () => {
    installMockRegister();
    renderAt('/ledning/surfplattor', ['mdt_page:search', 'perm:tablets.manage']);
    expect(await screen.findByText('Du har inte behörighet att göra det här.')).toBeTruthy();
    expect(screen.queryByRole('heading', { name: 'Surfplattor' })).toBeNull();
  });
});
