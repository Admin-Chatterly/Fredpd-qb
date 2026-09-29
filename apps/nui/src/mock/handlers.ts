// SPDX-License-Identifier: GPL-3.0-only
// Browser dev mode only: one answer function per tablet action (MDT_ACTIONS), backed by the in-memory register of
// src/mock/data.ts. They follow the server rules the NUI can observe (fredpd_records / fredpd_bolo / fredpd_mdt
// docs): canView-shaped case refs, 50 per page, live = active and not expired, one live BOLO per subject, level ≤
// tier, `{ error, reason? }` for refusals. test/mocks.test.ts parses every answer with the action's output schema.
import { BoloCreateInputSchema, BoloListInputSchema, BoloResolveInputSchema, PAGE_SIZE, SearchInputSchema, TabletRevokeInputSchema } from '@fredpd/types/mdt';
import type { Bolo, CaseRef, MdtActionName, MdtError, MdtOutput, SearchHit } from '@fredpd/types/mdt';
import { detectSearchType } from '@fredpd/types/format';
import { homeVariantFor } from '../units';
import { isoUtc } from './data';
import type { MockCase, MockDb, MockPerson, MockRole, MockVehicle } from './data';

export type MockError = { error: MdtError['error']; reason?: string };
export type MockAnswer<A extends MdtActionName> = MdtOutput<A> | MockError;
export type MockHandlers = { [A in MdtActionName]: (input: unknown) => MockAnswer<A> };

const fail = (error: MockError['error'], reason?: string): MockError => (reason ? { error, reason } : { error });

function paginate<T>(items: readonly T[], page: number): { items: T[]; total: number; page: number } {
  const start = (page - 1) * PAGE_SIZE;
  return { items: items.slice(start, start + PAGE_SIZE), total: items.length, page };
}

const normalizePlate = (plate: string) => plate.toUpperCase().replace(/\s+/g, '');
const fullName = (p: MockPerson) => `${p.firstname} ${p.lastname}`;
const digitsOf = (s: string) => s.replace(/\D/g, '');

export function createMockHandlers(db: MockDb): MockHandlers {
  const person = (cid: string) => db.persons.find((p) => p.citizenid === cid);
  const vehicle = (plate: string) => db.vehicles.find((v) => v.plate === plate);

  const isLive = (b: Bolo) => b.active && (b.expiresAt === null || Date.parse(b.expiresAt) > db.now());
  /** Expired BOLOs drop out lazily, as fredpd_bolo does. */
  const sweep = () => {
    for (const b of db.bolos) if (b.active && !isLive(b)) b.active = false;
  };
  const byNewest = (a: Bolo, b: Bolo) => Date.parse(b.createdAt) - Date.parse(a.createdAt);
  const liveBolos = () => {
    sweep();
    return db.bolos.filter(isLive).sort(byNewest);
  };
  const bolosFor = (kind: Bolo['kind'], id: string) => {
    sweep();
    return db.bolos
      .filter((b) => b.kind === kind && (kind === 'person' ? b.citizenid === id : b.plate === id))
      .sort((a, b) => Number(isLive(b)) - Number(isLive(a)) || byNewest(a, b))
      .slice(0, 20);
  };
  const liveFor = (kind: Bolo['kind'], id: string) => bolosFor(kind, id).find(isLive);

  const caseRef = (c: MockCase, role: MockRole | 'vehicle' | null): CaseRef => {
    switch (c.visibility) {
      case 'full':
        return { visibility: 'full', id: c.id, caseNumber: c.caseNumber, title: c.title, status: c.status, level: c.level, role };
      case 'masked':
        return { visibility: 'masked', id: c.id, caseNumber: c.caseNumber, title: c.maskedTitle ? c.title : null, status: c.status, level: c.level, role };
      case 'notice':
        return { visibility: 'notice', contact: { ...c.contact } };
    }
  };
  const openFirst = (a: MockCase, b: MockCase) => Number(b.status === 'open') - Number(a.status === 'open') || b.id - a.id;

  const personHit = (p: MockPerson): SearchHit => ({
    kind: 'person',
    citizenid: p.citizenid,
    name: fullName(p),
    birthdate: p.birthdate,
    personnummer: p.personnummer,
    bolo: !!liveFor('person', p.citizenid),
  });
  const vehicleHit = (v: MockVehicle): SearchHit => {
    const owner = v.ownerCitizenid ? person(v.ownerCitizenid) : undefined;
    return {
      kind: 'vehicle',
      plate: v.plate,
      model: v.model,
      ownerName: owner ? fullName(owner) : null,
      ownerCitizenid: v.ownerCitizenid,
      bolo: !!liveFor('vehicle', v.plate),
    };
  };
  const byName = (a: MockPerson, b: MockPerson) =>
    a.lastname.localeCompare(b.lastname, 'sv') || a.firstname.localeCompare(b.firstname, 'sv') || a.citizenid.localeCompare(b.citizenid);

  const officerRef = () => ({ ...db.me });
  const newBoloSubject = (kind: Bolo['kind'], id: string): string | null => {
    if (kind === 'person') {
      const p = person(id);
      return p ? fullName(p) : null;
    }
    const v = vehicle(id);
    return v ? (v.model ? `${v.plate} · ${v.model}` : v.plate) : null;
  };

  return {
    close: () => ({ ok: true }),

    getHome: () => {
      const unitVariant = homeVariantFor(db.unit);
      const variant = unitVariant === 'default' ? 'igv' : unitVariant;
      const live = liveBolos();
      const mine = db.cases.filter((c) => c.mine).sort(openFirst);
      return {
        me: officerRef(),
        variant,
        counts: {
          activeBolos: live.length,
          myOpenCases: mine.filter((c) => c.status === 'open').length,
          onDuty: db.officers.filter((o) => o.onDuty).length,
        },
        recentBolos: live.slice(0, 10),
        myCases: mine.slice(0, 10).map((c) => caseRef(c, null)),
        roster: variant === 'ledning' ? db.officers.map((o) => ({ ...o })) : [],
      };
    },

    search: (raw) => {
      const parsed = SearchInputSchema.safeParse(raw);
      if (!parsed.success) return fail('validation', String(parsed.error.issues[0]?.path[0] ?? 'query'));
      const { query, type, page } = parsed.data;
      let detected: MdtOutput<'search'>['detected'];
      let normalized: string;
      if (type === 'vehicle') {
        detected = 'plate';
        normalized = normalizePlate(query);
      } else if (type === 'case') {
        detected = 'caseNumber';
        normalized = query.toUpperCase();
      } else {
        const d = detectSearchType(query);
        if (type === 'person' && (d.type === 'plate' || d.type === 'caseNumber')) {
          detected = 'name';
          normalized = query;
        } else {
          detected = d.type;
          normalized = d.normalized;
        }
      }

      let hits: SearchHit[];
      if (detected === 'name') {
        const terms = normalized.toLocaleLowerCase('sv').split(/[^\p{L}\p{N}]+/u).filter(Boolean).slice(0, 6);
        hits = terms.length === 0
          ? []
          : db.persons
              .filter((p) => terms.every((term) => [p.firstname, p.lastname].some((n) => n.toLocaleLowerCase('sv').startsWith(term))))
              .sort(byName)
              .map(personHit);
      } else if (detected === 'personId') {
        const digits = digitsOf(normalized);
        hits = db.persons
          .filter((p) => p.personnummer && (digitsOf(p.personnummer) === digits || digitsOf(p.personnummer).slice(2) === digits))
          .map(personHit);
      } else if (detected === 'plate') {
        hits = db.vehicles.filter((v) => v.plate === normalized).map(vehicleHit);
      } else {
        hits = db.cases.filter((c) => c.caseNumber === normalized).map((c) => ({ kind: 'case' as const, case: caseRef(c, null) }));
      }
      const pageOf = paginate(hits, page);
      return { detected, normalized, hits: pageOf.items, total: pageOf.total, page };
    },

    getPerson: (raw) => {
      const cid = typeof raw === 'object' && raw !== null ? (raw as { citizenid?: unknown }).citizenid : undefined;
      if (typeof cid !== 'string' || !/^[A-Za-z0-9_-]{1,50}$/.test(cid)) return fail('validation', 'citizenid');
      const p = person(cid);
      if (!p) return fail('not_found');
      const cases = db.cases.filter((c) => c.persons.some((s) => s.citizenid === cid)).sort(openFirst);
      const caseById = new Map(db.cases.map((c) => [c.id, c]));
      return {
        person: { citizenid: p.citizenid, firstname: p.firstname, lastname: p.lastname, birthdate: p.birthdate, personnummer: p.personnummer, gender: p.gender, phone: p.phone },
        vehicles: db.vehicles.filter((v) => v.ownerCitizenid === cid).map((v) => ({ plate: v.plate, model: v.model, bolo: !!liveFor('vehicle', v.plate) })),
        bolos: bolosFor('person', cid),
        cases: cases.map((c) => caseRef(c, c.persons.find((s) => s.citizenid === cid)?.role ?? null)),
        records: db.records
          .filter((r) => r.citizenid === cid)
          .sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt))
          .map((r) => {
            const c = r.caseId !== null ? caseById.get(r.caseId) : undefined;
            // A kontaktnotis case never leaks its number (records.md).
            return { id: r.id, chargeCode: r.chargeCode, title: r.title, fine: r.fine, jailMinutes: r.jailMinutes, createdAt: r.createdAt, caseNumber: c && c.visibility !== 'notice' ? c.caseNumber : null };
          }),
        address: p.address,
      };
    },

    getVehicle: (raw) => {
      const plateIn = typeof raw === 'object' && raw !== null ? (raw as { plate?: unknown }).plate : undefined;
      if (typeof plateIn !== 'string' || plateIn.trim() === '' || plateIn.length > 16) return fail('validation', 'plate');
      const plate = normalizePlate(plateIn);
      const v = vehicle(plate);
      const bolos = bolosFor('vehicle', plate);
      const cases = db.cases.filter((c) => c.vehicles.includes(plate)).sort(openFirst);
      const checks = db.checks.filter((c) => c.plate === plate).sort((a, b) => Date.parse(b.checkedAt) - Date.parse(a.checkedAt)).slice(0, 20);
      if (!v && bolos.length === 0 && cases.length === 0 && checks.length === 0) return fail('not_found');
      const owner = v?.ownerCitizenid ? person(v.ownerCitizenid) : undefined;
      return {
        vehicle: { plate, model: v?.model ?? null },
        owner: v?.ownerCitizenid ? { citizenid: v.ownerCitizenid, name: owner ? fullName(owner) : v.ownerCitizenid } : null,
        bolos,
        cases: cases.map((c) => caseRef(c, 'vehicle')),
        checks: checks.map((c) => ({ checkedAt: c.checkedAt, officer: c.officer, hit: c.hit })),
      };
    },

    checkPlate: (raw) => {
      const plateIn = typeof raw === 'object' && raw !== null ? (raw as { plate?: unknown }).plate : undefined;
      if (typeof plateIn !== 'string' || plateIn.trim() === '' || plateIn.length > 16) return fail('validation', 'plate');
      const plate = normalizePlate(plateIn);
      const v = vehicle(plate);
      const owner = v?.ownerCitizenid ? person(v.ownerCitizenid) : undefined;
      const hit = liveFor('vehicle', plate) ?? null;
      const checkedAt = isoUtc(db.now());
      db.checks.push({ plate, checkedAt, officer: officerRef(), hit: hit !== null });
      return {
        plate,
        model: v?.model ?? null,
        owner: v?.ownerCitizenid ? { citizenid: v.ownerCitizenid, name: owner ? fullName(owner) : v.ownerCitizenid } : null,
        bolo: hit,
        checkedAt,
      };
    },

    listBolos: (raw) => {
      const parsed = BoloListInputSchema.safeParse(raw ?? {});
      if (!parsed.success) return fail('validation');
      sweep();
      const items = parsed.data.active ? liveBolos() : [...db.bolos].sort(byNewest);
      return paginate(items, parsed.data.page);
    },

    createBolo: (raw) => {
      const parsed = BoloCreateInputSchema.safeParse(raw);
      if (!parsed.success) return fail('validation', String(parsed.error.issues[0]?.path[0] ?? 'kind'));
      const input = parsed.data;
      if (input.level > db.tier) return fail('unauthorized', 'level');
      const id = input.kind === 'person' ? (input.citizenid ?? '') : normalizePlate(input.plate ?? '');
      const subject = newBoloSubject(input.kind, id);
      if (subject === null) return fail('not_found');
      if (liveFor(input.kind, id)) return fail('validation', 'duplicate');
      const now = db.now();
      const created: Bolo = {
        id: db.nextBoloId,
        kind: input.kind,
        citizenid: input.kind === 'person' ? id : null,
        plate: input.kind === 'vehicle' ? id : null,
        subject,
        reason: input.reason,
        level: input.level,
        issuedBy: officerRef(),
        createdAt: isoUtc(now),
        expiresAt: input.expiresInHours ? isoUtc(now + input.expiresInHours * 3_600_000) : null,
        active: true,
        resolvedBy: null,
        resolvedAt: null,
        resolveNote: null,
      };
      db.nextBoloId += 1;
      db.bolos.push(created);
      return { ...created };
    },

    resolveBolo: (raw) => {
      const parsed = BoloResolveInputSchema.safeParse(raw);
      if (!parsed.success) return fail('validation');
      sweep();
      const b = db.bolos.find((x) => x.id === parsed.data.id);
      if (!b) return fail('not_found');
      if (!b.active) return fail('validation', 'inactive');
      b.active = false;
      b.resolvedBy = officerRef();
      b.resolvedAt = isoUtc(db.now());
      b.resolveNote = parsed.data.note === '' ? null : parsed.data.note;
      return { ...b };
    },

    listTablets: (raw) => {
      const page = typeof raw === 'object' && raw !== null && typeof (raw as { page?: unknown }).page === 'number' ? (raw as { page: number }).page : 1;
      return paginate(db.tablets, page);
    },

    setTabletRevoked: (raw) => {
      const parsed = TabletRevokeInputSchema.safeParse(raw);
      if (!parsed.success) return fail('validation');
      const tablet = db.tablets.find((x) => x.serial === parsed.data.serial);
      if (!tablet) return fail('not_found');
      tablet.revoked = parsed.data.revoked;
      return { ...tablet };
    },
  };
}
