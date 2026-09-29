// SPDX-License-Identifier: GPL-3.0-only
// The typed client: Lua wire normalisation (absent nulls, `{}`/`[]`), `{ error }` answers → MdtClientError →
// errors.* text, dev-build validation against mdt.ts, and push/mutation invalidation.
import { afterEach, describe, expect, it, vi } from 'vitest';
import { QueryClient } from '@tanstack/react-query';
import { CaseRefSchema, HomeOutputSchema, PersonSummarySchema, SearchOutputSchema, VehicleSummarySchema } from '@fredpd/types/mdt';
import { NuiRequestError, clearNuiMocks, registerNuiMock } from '../src/utils/fetchNui';
import { acceptsNull, normalizeWire } from '../src/api/wire';
import { MdtClientError, errorLocaleKey } from '../src/api/errors';
import { LEDNING_PUSH_QUERIES, PUSH_INVALIDATES, callMdt, invalidateForPush, ledningPushQueries, mdtQueryKey } from '../src/api/client';
import { pendingMessages } from '../src/i18n';

afterEach(() => {
  clearNuiMocks();
  delete window.GetParentResourceName;
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe('normalizeWire', () => {
  it('restores absent nullable keys, through arrays and discriminated unions', () => {
    const lua = {
      person: { citizenid: 'A1', firstname: 'Karin', lastname: 'Andersson', gender: 'unknown' },
      vehicles: {},
      bolos: [],
      cases: [
        { visibility: 'masked', id: 7, caseNumber: 'K-7-26', status: 'closed', level: 1 },
        { visibility: 'notice', contact: [] },
        { visibility: 'full', id: 8, caseNumber: 'K-8-26', title: 'Rån', status: 'open', level: 0 },
      ],
      records: [{ id: 1, chargeCode: 'BrB 8:1', title: 'Stöld', fine: 100, jailMinutes: 0, createdAt: '2026-09-01T10:00:00Z' }],
    };
    const out = normalizeWire(PersonSummarySchema, lua);
    expect(out).toEqual({
      person: { citizenid: 'A1', firstname: 'Karin', lastname: 'Andersson', gender: 'unknown', birthdate: null, personnummer: null, phone: null },
      vehicles: [],
      bolos: [],
      cases: [
        { visibility: 'masked', id: 7, caseNumber: 'K-7-26', title: null, status: 'closed', level: 1, role: null },
        // A notice gets no id/number/title keys: only what its own schema has (contact `[]` → `{}` with nulls).
        { visibility: 'notice', contact: { displayName: null, unit: null } },
        { visibility: 'full', id: 8, caseNumber: 'K-8-26', title: 'Rån', status: 'open', level: 0, role: null },
      ],
      records: [{ id: 1, chargeCode: 'BrB 8:1', title: 'Stöld', fine: 100, jailMinutes: 0, createdAt: '2026-09-01T10:00:00Z', caseNumber: null }],
      address: null,
    });
    expect(PersonSummarySchema.safeParse(out).success).toBe(true);
    expect(PersonSummarySchema.safeParse(lua).success).toBe(false);
  });

  it('leaves required keys absent (validation still catches them) and never adds or drops other keys', () => {
    const out = normalizeWire(CaseRefSchema, { visibility: 'full', id: 1, extra: 'x' }) as Record<string, unknown>;
    expect(out).toEqual({ visibility: 'full', id: 1, extra: 'x', role: null });
    expect('caseNumber' in out || 'title' in out).toBe(false);
    expect(normalizeWire(SearchOutputSchema, 'garbage')).toBe('garbage');
    expect(acceptsNull(VehicleSummarySchema.shape.owner)).toBe(true);
    expect(acceptsNull(VehicleSummarySchema.shape.bolos)).toBe(false);
  });

  it('restores nested nullables (home roster, vehicle checks)', () => {
    const home = normalizeWire(HomeOutputSchema, {
      me: { citizenid: 'A', displayName: 'Anna' },
      variant: 'ledning',
      counts: { activeBolos: 0, myOpenCases: 0, onDuty: 1 },
      recentBolos: {},
      myCases: {},
      roster: [{ citizenid: 'A', displayName: 'Anna', onDuty: true }],
    });
    expect(HomeOutputSchema.parse(home).roster[0]).toEqual({ citizenid: 'A', displayName: 'Anna', callsign: null, unit: null, onDuty: true });
  });
});

describe('callMdt', () => {
  it('returns the normalised answer', async () => {
    registerNuiMock('getVehicle', () => ({ vehicle: { plate: 'ABC12D' }, bolos: [], cases: [], checks: [{ checkedAt: '2026-09-29T10:00:00Z', hit: false }] }));
    const out = await callMdt('getVehicle', { plate: 'ABC12D' });
    expect(out.owner).toBeNull();
    expect(out.vehicle.model).toBeNull();
    expect(out.checks[0]?.officer).toBeNull();
  });

  it('turns `{ error, reason }` into MdtClientError and maps it to errors.* text', async () => {
    registerNuiMock('createBolo', () => ({ error: 'validation', reason: 'duplicate' }));
    const err = await callMdt('createBolo', { kind: 'person', citizenid: 'A', reason: 'abc' }).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(MdtClientError);
    expect(err).toMatchObject({ action: 'createBolo', code: 'validation', reason: 'duplicate' });
    expect(errorLocaleKey(err)).toBe('errors.validation');
    expect(errorLocaleKey(new MdtClientError('x', 'unauthorized', 'off_duty'))).toBe('errors.notOnDuty');
    expect(errorLocaleKey(new MdtClientError('x', 'unauthorized', 'revoked'))).toBe('tablet.revoked');
    expect(errorLocaleKey(new MdtClientError('x', 'rate_limited'))).toBe('errors.rateLimited');
    expect(errorLocaleKey(new MdtClientError('x', 'unavailable'))).toBe('errors.serviceUnavailable');
    expect(errorLocaleKey(new MdtClientError('x', 'not_found'))).toBe('errors.notFound');
    expect(errorLocaleKey(new Error('boom'))).toBe('errors.unknown');
    registerNuiMock('getHome', () => ({ error: 'something_new' }));
    await expect(callMdt('getHome', {})).rejects.toMatchObject({ code: 'unknown' });
  });

  it('a failed NUI callback is a network error', async () => {
    window.GetParentResourceName = () => 'fredpd_mdt';
    vi.stubGlobal('fetch', vi.fn(async () => new Response('', { status: 500 })));
    const err = await callMdt('getHome', {}).catch((e: unknown) => e);
    expect(err).toMatchObject({ code: 'network' });
    expect(errorLocaleKey(new NuiRequestError('getHome', 500))).toBe('errors.network');
  });

  it('dev builds reject an answer that does not match mdt.ts (and log why)', async () => {
    const log = vi.spyOn(console, 'error').mockImplementation(() => {});
    registerNuiMock('listBolos', () => ({ items: [{ id: 'not a number' }], total: 1, page: 1 }));
    await expect(callMdt('listBolos', { active: true, page: 1 })).rejects.toMatchObject({ code: 'unknown', reason: 'contract' });
    expect(log).toHaveBeenCalled();
  });
});

describe('invalidation', () => {
  it('push topic bolo invalidates listBolos/getPerson/getVehicle/getHome (and search flags), not tablets', async () => {
    const qc = new QueryClient();
    const keys = [
      mdtQueryKey('listBolos', { active: true, page: 1 }),
      mdtQueryKey('getPerson', { citizenid: 'A' }),
      mdtQueryKey('getVehicle', { plate: 'ABC12D' }),
      mdtQueryKey('getHome', {}),
      mdtQueryKey('search', { query: 'ab', type: 'auto', page: 1 }),
      mdtQueryKey('listTablets', { page: 1 }),
    ];
    for (const key of keys) qc.setQueryData(key, { cached: true });
    await invalidateForPush(qc, 'bolo', 'none');
    expect(keys.map((key) => qc.getQueryState(key)?.isInvalidated)).toEqual([true, true, true, true, true, false]);
    expect(PUSH_INVALIDATES.bolo).toEqual(expect.arrayContaining(['listBolos', 'getPerson', 'getVehicle', 'getHome']));
    await invalidateForPush(qc, 'grants', 'none');
    expect(qc.getQueryState(keys[5] ?? [])?.isInvalidated).toBe(true);
    await expect(invalidateForPush(qc, 'unknown-topic', 'none')).resolves.toBeUndefined();
  });

  it("push topic ledning: releaseRequest refreshes the release queue, lookupFlag the Ledning Hem; nothing else", async () => {
    const qc = new QueryClient();
    const queue = ['mdt', 'listReleaseRequests', { status: 'pending', page: 1 }] as const;
    const home = mdtQueryKey('getHome', {});
    const others = [mdtQueryKey('listCases', { scope: 'mine', page: 1 } as never), mdtQueryKey('getPerson', { citizenid: 'A' }), mdtQueryKey('listAlerts', { filter: 'open' } as never)];
    const all = [queue, home, ...others];
    const reset = () => {
      for (const key of all) qc.setQueryData(key, { cached: true });
    };
    const invalidated = () => all.map((key) => qc.getQueryState(key)?.isInvalidated ?? false);

    reset();
    await invalidateForPush(qc, 'ledning', 'none', { type: 'releaseRequest', id: 7 });
    expect(invalidated()).toEqual([true, false, false, false, false]);

    reset();
    await invalidateForPush(qc, 'ledning', 'none', { type: 'lookupFlag', officer: 'ABC12345', count: 3 });
    expect(invalidated()).toEqual([false, true, false, false, false]);

    // malformed / unknown payload: every ledning query, still nothing outside them
    reset();
    await invalidateForPush(qc, 'ledning', 'none', 'garbage');
    expect(invalidated()).toEqual([true, true, false, false, false]);
    expect(ledningPushQueries(undefined)).toEqual(expect.arrayContaining([...LEDNING_PUSH_QUERIES.releaseRequest, ...LEDNING_PUSH_QUERIES.lookupFlag]));
    expect(PUSH_INVALIDATES.ledning).toBeUndefined(); // handled by payload type, not the generic table
  });
});

describe('pending locale keys', () => {
  it('are layered under the main files per language, $comment skipped', () => {
    const files = { a: { $comment: 'x', 'k.one': { sv: 'Ett', en: 'One' }, 'k.two': { sv: 'Två' } } };
    expect(pendingMessages(files, 'sv')).toEqual({ 'k.one': 'Ett', 'k.two': 'Två' });
    expect(pendingMessages(files, 'en')).toEqual({ 'k.one': 'One' });
  });
});
