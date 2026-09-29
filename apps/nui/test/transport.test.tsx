// SPDX-License-Identifier: GPL-3.0-only
// The pages' data layer goes through the host's MdtTransport (packages/ui mdtHost.tsx, task 7.1): inside the tablet
// it is fetchNui (TabletRoutes provides it); any other host's transport replaces it without touching the pages, and
// portal mode hides the world-only controls.
import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router';
import { QueryClientProvider } from '@tanstack/react-query';
import { I18nProvider, MdtHostProvider, PORTAL_BLOCKED_ACTIONS, isActionAvailable } from '@fredpd/ui';
import type { MdtHostMode, MdtTransport } from '@fredpd/ui';
import { MDT_ACTIONS } from '@fredpd/types/mdt';
import { i18n } from '../src/i18n';
import { createQueryClient } from '../src/queryClient';
import { VehiclePage } from '../src/pages/VehiclePage';
import { nuiTransport } from '../src/api/transport';
import { callMdt } from '../src/api/client';
import { TABLET_ACTION_NAMES } from '../src/api/actions';
import { toLuaWire } from '../src/api/wire';
import { clearNuiMocks } from '../src/utils/fetchNui';
import { createMockDb } from '../src/mock/data';
import { createMockHandlers } from '../src/mock/handlers';
import { ME, FIXED_NOW, installMockRegister, openMessage, renderAt } from './helpers';

afterEach(() => {
  cleanup();
  clearNuiMocks();
});

/** A transport answering from the mock register, recording calls (stands in for the portal's /api/mdt). */
function fakeTransport(mode: MdtHostMode) {
  const db = createMockDb({ me: ME, tier: 1, unit: 'igv', now: () => FIXED_NOW });
  const handlers = createMockHandlers(db) as Record<string, (input: unknown) => unknown>;
  const calls: [string, unknown][] = [];
  const transport: MdtTransport = {
    mode,
    call: vi.fn(async (action: string, input: unknown) => {
      calls.push([action, input]);
      return toLuaWire(handlers[action]!(input));
    }),
  };
  return { transport, calls };
}

function renderVehicle(transport: MdtTransport) {
  const { grants, unit, me } = openMessage(['mdt_page:*', 'perm:bolo.create']) as Extract<ReturnType<typeof openMessage>, { action: 'open' }>;
  render(
    <I18nProvider i18n={i18n}>
      <QueryClientProvider client={createQueryClient()}>
        <MdtHostProvider transport={transport} session={{ grants, unit: unit ?? null, me }}>
          <MemoryRouter initialEntries={['/fordon/ABC12D']}>
            <Routes>
              <Route path="/fordon/:plate" element={<VehiclePage />} />
            </Routes>
          </MemoryRouter>
        </MdtHostProvider>
      </QueryClientProvider>
    </I18nProvider>,
  );
}

describe('MdtTransport swap', () => {
  it('the tablet routes use the NUI transport (fetchNui)', async () => {
    const register = installMockRegister();
    renderAt('/fordon/ABC12D');
    await screen.findByRole('heading', { level: 1, name: /ABC12D/ });
    expect(register.calls).toHaveBeenCalledWith('getVehicle', { plate: 'ABC12D' });
    expect(screen.getByRole('button', { name: 'Kontrollera' })).toBeTruthy();
    register.unregister();
  });

  it('the same page runs on another host transport and never calls fetchNui', async () => {
    const register = installMockRegister();
    const { transport, calls } = fakeTransport('portal');
    renderVehicle(transport);
    await screen.findByRole('heading', { level: 1, name: /ABC12D/ });
    expect(calls).toContainEqual(['getVehicle', { plate: 'ABC12D' }]);
    expect(register.calls).not.toHaveBeenCalled();
    // Portal mode: the plate check (a world action) is hidden, BOLO writes stay.
    expect(screen.queryByRole('button', { name: 'Kontrollera' })).toBeNull();
    expect(screen.getByRole('button', { name: /Efterlys/ })).toBeTruthy();
    register.unregister();
  });

  it('a tablet-mode host transport keeps the world actions', async () => {
    const { transport } = fakeTransport('tablet');
    renderVehicle(transport);
    await screen.findByRole('heading', { level: 1, name: /ABC12D/ });
    await waitFor(() => expect(screen.getByRole('button', { name: 'Kontrollera' })).toBeTruthy());
  });

  it('callMdt defaults to the NUI transport and uses the one it is given', async () => {
    expect(nuiTransport.mode).toBe('tablet');
    const { transport, calls } = fakeTransport('portal');
    const out = await callMdt('getVehicle', { plate: 'ABC12D' }, transport);
    expect(out.vehicle.plate).toBe('ABC12D');
    expect(calls).toEqual([['getVehicle', { plate: 'ABC12D' }]]);
  });

  it('the portal blocks exactly the world-only / non-portal writes, all of them real actions', () => {
    for (const a of PORTAL_BLOCKED_ACTIONS) expect(TABLET_ACTION_NAMES as string[]).toContain(a);
    expect(isActionAvailable('portal', 'checkPlate')).toBe(false);
    expect(isActionAvailable('portal', 'issueFine')).toBe(false);
    expect(isActionAvailable('portal', 'createBolo')).toBe(true);
    expect(isActionAvailable('portal', 'saveReport')).toBe(true);
    expect(isActionAvailable('portal', 'addLink')).toBe(true);
    for (const a of Object.keys(MDT_ACTIONS)) expect(isActionAvailable('tablet', a)).toBe(true);
  });
});
