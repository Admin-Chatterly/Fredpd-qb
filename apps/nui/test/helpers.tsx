// SPDX-License-Identifier: GPL-3.0-only
// Test harness for tablet pages: mounts the real providers and routes at a path, opened with a given grant set,
// in browser mode (fetchNui answers from registerNuiMock). `installMockRegister` installs the dev mock handlers
// (src/mock) with Lua-style answers (nulls removed), the same path the game takes.
import { act, render } from '@testing-library/react';
import type { ReactNode } from 'react';
import { MemoryRouter } from 'react-router';
import { QueryClientProvider } from '@tanstack/react-query';
import { vi } from 'vitest';
import { I18nProvider } from '@fredpd/ui';
import type { MdtActionName, OfficerRef } from '@fredpd/types/mdt';
import { i18n } from '../src/i18n';
import { createQueryClient } from '../src/queryClient';
import { TabletProvider, useTablet } from '../src/tablet/TabletContext';
import { TabletRoutes } from '../src/routes';
import type { NuiMessage } from '../src/tablet/messages';
import { registerNuiMock } from '../src/utils/fetchNui';
import { toLuaWire } from '../src/api/wire';
import { createMockDb } from '../src/mock/data';
import type { MockDb } from '../src/mock/data';
import { createMockHandlers } from '../src/mock/handlers';

export const ME: OfficerRef = { citizenid: 'DEV00001', displayName: 'Anna Berg', callsign: 'IGV-07', unit: 'igv' };
export const FIXED_NOW = Date.parse('2026-09-29T10:00:00Z');

export const ALL_PERMS = ['perm:bolo.create', 'perm:bolo.resolve', 'perm:tablets.manage'];

export function openMessage(grants: string[], opts: { unit?: string | null; tier?: 0 | 1 | 2 } = {}): NuiMessage {
  const unit = opts.unit === undefined ? 'igv' : opts.unit;
  return {
    action: 'open',
    grants: { grants, denied: [], tier: opts.tier ?? 1, units: unit ? [unit] : [], rank: null, computedAt: '2026-09-29T10:00:00.000Z' },
    unit,
    me: { citizenid: ME.citizenid, displayName: ME.displayName, callsign: ME.callsign },
  };
}

export function send(data: unknown) {
  act(() => {
    window.dispatchEvent(new MessageEvent('message', { data }));
  });
}

function SessionGate({ children }: { children: ReactNode }) {
  const { session } = useTablet();
  return session ? <>{children}</> : null;
}

/** Mounts the tablet routes at `path` with the grants, already opened. */
export function renderAt(path: string, grants: string[] = ['mdt_page:*', ...ALL_PERMS], opts: { unit?: string | null; tier?: 0 | 1 | 2 } = {}) {
  const queryClient = createQueryClient();
  const utils = render(
    <I18nProvider i18n={i18n}>
      <QueryClientProvider client={queryClient}>
        <TabletProvider queryClient={queryClient} onReady={() => window.dispatchEvent(new MessageEvent('message', { data: openMessage(grants, opts) }))}>
          <div id="fredpd-tablet" className="relative">
            <SessionGate>
              <MemoryRouter initialEntries={[path]}>
                <TabletRoutes />
              </MemoryRouter>
            </SessionGate>
          </div>
        </TabletProvider>
      </QueryClientProvider>
    </I18nProvider>,
  );
  return { ...utils, queryClient };
}

/**
 * Installs the dev mock register for every action (Lua-style answers) and returns it, plus a spy that records
 * each call as [action, input].
 */
export function installMockRegister(opts: { tier?: 0 | 1 | 2; unit?: string | null } = {}) {
  const db: MockDb = createMockDb({ me: ME, tier: opts.tier ?? 1, unit: opts.unit === undefined ? 'igv' : opts.unit, now: () => FIXED_NOW });
  const handlers = createMockHandlers(db);
  const calls = vi.fn<(action: MdtActionName, input: unknown) => void>();
  const unregister: (() => void)[] = [];
  for (const action of Object.keys(handlers) as MdtActionName[]) {
    const handler = handlers[action] as (input: unknown) => unknown;
    unregister.push(
      registerNuiMock(action, (input) => {
        calls(action, input);
        return toLuaWire(handler(input));
      }),
    );
  }
  return { db, calls, unregister: () => unregister.forEach((u) => u()) };
}

/** jsdom has no layout: TanStack Virtual reads the viewport from offsetHeight/offsetWidth. */
export function fakeLayout(height = 640, width = 900) {
  const heightDesc = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'offsetHeight');
  const widthDesc = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'offsetWidth');
  Object.defineProperty(HTMLElement.prototype, 'offsetHeight', { configurable: true, get: () => height });
  Object.defineProperty(HTMLElement.prototype, 'offsetWidth', { configurable: true, get: () => width });
  return () => {
    if (heightDesc) Object.defineProperty(HTMLElement.prototype, 'offsetHeight', heightDesc);
    if (widthDesc) Object.defineProperty(HTMLElement.prototype, 'offsetWidth', widthDesc);
  };
}
