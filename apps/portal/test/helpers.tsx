// SPDX-License-Identifier: GPL-3.0-only
// Portal test harness: a fake fredpd_service behind `fetch` (session, characters, /api/mdt/:action answered by the
// tablet's dev mock register in Lua wire shape, the way FXServer answers through the service; alerts/units; share)
// and the real providers (SessionProvider, the portal query client, BrowserRouter-like MemoryRouter).
import { render } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { QueryClientProvider } from '@tanstack/react-query';
import { vi } from 'vitest';
import { I18nProvider } from '@fredpd/ui';
import type { SessionUser } from '@fredpd/types/actions';
import type { OfficerRef } from '@fredpd/types/mdt';
import { App } from '../src/App';
import { i18n } from '../src/i18n';
import { createPortalQueryClient } from '../src/queryClient';
import { SessionProvider } from '../src/session';
import { createMockDb } from '../../nui/src/mock/data';
import type { MockDb } from '../../nui/src/mock/data';
import { createMockHandlers } from '../../nui/src/mock/handlers';
import { createSectionMocks } from '../../nui/src/mock/sections';
import { toLuaWire } from '../../nui/src/api/wire';

export const ME: OfficerRef = { citizenid: 'DEV00001', displayName: 'Anna Berg', callsign: 'IGV-07', unit: 'igv' };
export const FIXED_NOW = Date.parse('2026-09-29T10:00:00Z');
export const CSRF = 'csrf-token-1';

export function makeUser(opts: { citizenid?: string | null; grants?: string[]; tier?: 0 | 1 | 2; units?: string[] } = {}): SessionUser {
  return {
    discordId: '200000000000000001',
    displayName: 'Anna Berg',
    avatarUrl: null,
    citizenid: opts.citizenid === undefined ? ME.citizenid : opts.citizenid,
    grants: {
      grants: opts.grants ?? ['mdt_page:*', 'perm:bolo.create', 'perm:bolo.resolve', 'perm:tablets.manage', 'perm:records.admin', 'perm:intel.read'],
      denied: [],
      tier: opts.tier ?? 1,
      units: opts.units ?? ['igv'],
      rank: null,
      computedAt: '2026-09-29T10:00:00.000Z',
    },
  };
}

export type RouteHandler = (init: RequestInit | undefined, url: string) => Response | Promise<Response>;

export const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json', ...headers } });

const STATUS: Record<string, number> = { unauthorized: 403, not_found: 404, validation: 400, rate_limited: 429, unavailable: 503 };

export interface FakeService {
  db: MockDb;
  fetchSpy: ReturnType<typeof vi.fn>;
  /** Extra or overriding routes, keyed "METHOD /path" (the path without the query string). */
  routes: Record<string, RouteHandler>;
  /** Every /api/mdt call as [action, input, headers]. */
  mdtCalls: [string, unknown, Record<string, string>][];
  user: SessionUser | null;
}

export function installFakeService(user: SessionUser | null, opts: { tier?: 0 | 1 | 2; unit?: string } = {}): FakeService {
  const db = createMockDb({ me: ME, tier: opts.tier ?? 1, unit: opts.unit ?? 'igv', now: () => FIXED_NOW });
  const handlers = { ...createMockHandlers(db), ...createSectionMocks(db) } as Record<string, (input: unknown) => unknown>;
  const service: FakeService = { db, fetchSpy: vi.fn(), routes: {}, mdtCalls: [], user };
  const routes: Record<string, RouteHandler> = {
    'GET /api/session': () => json({ user: service.user, csrfToken: service.user ? CSRF : null }),
    'GET /api/characters': () =>
      json([
        { citizenid: ME.citizenid, name: 'Anna Berg', lastSeen: '2026-09-28T18:00:00Z' },
        { citizenid: 'DEV00009', name: 'Nils Holm' },
      ]),
    'POST /api/session/character': (init) => {
      const body = JSON.parse(String(init?.body)) as { citizenid: string };
      if (service.user) service.user = { ...service.user, citizenid: body.citizenid };
      return json({ ok: true });
    },
  };
  service.fetchSpy = vi.fn(async (url: string, init?: RequestInit) => {
    const method = init?.method ?? 'GET';
    const path = url.split('?')[0] ?? url;
    const key = `${method} ${path}`;
    const override = service.routes[key] ?? routes[key];
    if (override) return override(init, url);
    if (method === 'POST' && path.startsWith('/api/mdt/')) {
      const action = decodeURIComponent(path.slice('/api/mdt/'.length));
      const input = JSON.parse(String(init?.body ?? '{}')) as unknown;
      service.mdtCalls.push([action, input, (init?.headers ?? {}) as Record<string, string>]);
      const handler = handlers[action];
      if (!handler) return json({ error: 'not_found' }, 404);
      const answer = handler(input) as { error?: string } | undefined;
      if (answer && typeof answer === 'object' && typeof answer.error === 'string') return json(answer, STATUS[answer.error] ?? 400);
      return json(toLuaWire(answer));
    }
    return json({ error: 'not_found' }, 404);
  });
  vi.stubGlobal('fetch', service.fetchSpy);
  return service;
}

export function renderPortal(path: string) {
  const queryClient = createPortalQueryClient();
  const utils = render(
    <I18nProvider i18n={i18n}>
      <QueryClientProvider client={queryClient}>
        <MemoryRouter initialEntries={[path]}>
          <SessionProvider>
            <App />
          </SessionProvider>
        </MemoryRouter>
      </QueryClientProvider>
    </I18nProvider>,
  );
  return { ...utils, queryClient };
}
