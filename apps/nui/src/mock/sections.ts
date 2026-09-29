// SPDX-License-Identifier: GPL-3.0-only
// Browser dev mode only: answers for the Phase 3–5b tablet actions (DISPATCH_ACTIONS, EVIDENCE_ACTIONS,
// RECORDS_ACTIONS, INTEL_ACTIONS), sharing the Phase 2 register of src/mock/data.ts (persons, vehicles, the cases
// K-1042-26 full / K-988-26 masked / K-1077-26 kontaktnotis, officers). They follow the server rules the NUI can see
// (docs/modules/dispatch.md, records, forensics, intel): canView-shaped answers, `none` → not_found, level ≤ tier,
// 50 per page, `{ error, reason? }` refusals. test/sections.mocks.test.ts parses every answer with its output schema.
// The brottskatalog is the real seed (db/seed/charges_sv.sql), read as text; only reachable from dev builds.
import { PAGE_SIZE } from '@fredpd/types/mdt';
import type { Level, OfficerRef } from '@fredpd/types/mdt';
import type { Alert, UnitStatus } from '@fredpd/types/dispatch';
import type { CustodyEntry, EvidenceItem } from '@fredpd/types/evidence';
import type { CaseDetail, Charge } from '@fredpd/types/records';
import type { Entity, Graph } from '@fredpd/types/intel';
import { GRAPH_NODE_CAP } from '@fredpd/types/intel';
import chargesSeed from '../../../../db/seed/charges_sv.sql?raw';
import { TABLET_ACTIONS } from '../api/actions';
import type { TabletActionName, TabletActions, TabletOutput } from '../api/actions';
import { isoUtc } from './data';
import type { MockCase, MockDb } from './data';
import type { MockError } from './handlers';

export const SECTION_ACTIONS = [
  'listAlerts', 'takeAlert', 'leaveAlert', 'closeAlert', 'getUnits',
  'listEvidence', 'getEvidence', 'linkEvidence',
  'listCases', 'getCase', 'createCase', 'updateCase', 'assignCase', 'unassignCase', 'addCaseSubject', 'closeCase',
  'getReport', 'createReport', 'saveReport', 'saveReportDraft', 'listReportTemplates', 'listCharges', 'applyCharges', 'issueFine',
  'listSources', 'getSource', 'createSource', 'updateSource', 'listIntelReports', 'getIntelReport', 'createIntelReport',
  'searchEntities', 'ensureEntity', 'getEntity', 'addLink', 'getGraph', 'listMissions', 'getMission', 'createMission',
  'addMissionMember', 'closeMission',
] as const satisfies readonly TabletActionName[];
export type SectionActionName = (typeof SECTION_ACTIONS)[number];

type Parsed<A extends TabletActionName> = TabletActions[A]['input']['_zod']['output'];
export type SectionAnswer<A extends SectionActionName> = TabletOutput<A> | MockError;
export type SectionHandlers = { [A in SectionActionName]: (input: unknown) => SectionAnswer<A> };

const MIN = 60_000;
const fail = (error: MockError['error'], reason?: string): MockError => (reason ? { error, reason } : { error });

function paginate<T>(items: readonly T[], page: number): { items: T[]; total: number; page: number } {
  const start = (page - 1) * PAGE_SIZE;
  return { items: items.slice(start, start + PAGE_SIZE), total: items.length, page };
}

/** Parses the charges seed: `('CODE', 'category', 'title', 'law ref', 'class', fine, jail),` rows. */
export function parseChargesSeed(sql: string): Charge[] {
  const re = /^\s*\('([^']+)',\s*'([^']+)',\s*'((?:[^']|'')*)',\s*'((?:[^']|'')*)',\s*'(ordningsbot|bot|fängelse)',\s*(\d+),\s*(\d+)\)/gm;
  const out: Charge[] = [];
  for (const m of sql.matchAll(re)) {
    out.push({
      code: m[1]!,
      category: m[2]!,
      title: m[3]!.replace(/''/g, "'"),
      lawRef: m[4]!.replace(/''/g, "'"),
      class: m[5] as Charge['class'],
      fine: Number(m[6]),
      jailMinutes: Number(m[7]),
    });
  }
  return out;
}

interface MockReport {
  id: number;
  caseId: number;
  n: number;
  title: string;
  body: string;
  level: Level;
  author: OfficerRef | null;
  createdAt: string;
  updatedAt: string;
  charges: TabletOutput<'applyCharges'>['records'];
}

interface MockCaseExtra {
  summary: string | null;
  owner: OfficerRef | null;
  assignees: (OfficerRef & { role: 'lead' | 'member' })[];
  createdAt: string;
  closedAt: string | null;
  timeline: CaseTimeline[];
}
type CaseTimeline = Extract<CaseDetail, { visibility: 'full' }>['timeline'][number];

interface MockEntity extends Entity {}
interface MockLink {
  id: number;
  fromId: number;
  toId: number;
  type: string;
  confidence: number;
  level: Level;
  reportId: number | null;
  createdBy: OfficerRef | null;
  createdAt: string;
}

export function createSectionMocks(db: MockDb): SectionHandlers {
  const now = () => db.now();
  const t0 = now();
  const at = (minutesFromNow: number) => isoUtc(t0 + minutesFromNow * MIN);
  const officer = (cid: string): OfficerRef => {
    const o = db.officers.find((x) => x.citizenid === cid);
    return o ? { citizenid: o.citizenid, displayName: o.displayName, callsign: o.callsign, unit: o.unit } : { ...db.me };
  };
  const me = (): OfficerRef => ({ citizenid: db.me.citizenid, displayName: db.me.displayName, callsign: db.me.callsign, unit: db.me.unit });
  const karl = officer('OFF00005');
  const bo = officer('OFF00002');
  const lina = officer('OFF00003');
  const mats = officer('OFF00004');
  const helena = officer('OFF00006');
  const personName = (cid: string) => {
    const p = db.persons.find((x) => x.citizenid === cid);
    return p ? `${p.firstname} ${p.lastname}` : null;
  };
  /** The input as the server sees it after validation (defaults filled), or null. */
  const parse = <A extends TabletActionName>(action: A, raw: unknown): Parsed<A> | null => {
    const parsed = TABLET_ACTIONS[action].input.safeParse(raw ?? {});
    return parsed.success ? (parsed.data as Parsed<A>) : null;
  };

  // ---------------------------------------------------------------------------------------------------------------
  // Larm
  // ---------------------------------------------------------------------------------------------------------------
  const alert = (a: Partial<Alert> & Pick<Alert, 'id' | 'code' | 'title' | 'priority'>): Alert => ({
    description: null, coords: null, street: null, source: 'ps-dispatch', status: 'open', createdAt: at(-5), units: [],
    closedBy: null, closedAt: null, ...a,
  });
  const alerts: Alert[] = [
    alert({ id: 301, code: '10-10', title: 'Slagsmål', street: 'Vespucci Beach', priority: 2, createdAt: at(-95), status: 'closed', units: [], closedBy: helena, closedAt: at(-60), coords: { x: -1310.2, y: -1560.4, z: 4.3 } }),
    alert({ id: 302, code: '10-66', title: 'Misstänkt person vid bankomat', street: 'Vinewood Boulevard', priority: 3, createdAt: at(-40), description: 'Person i mörk luvtröja står länge vid bankomaten och tittar på förbipasserande.' }),
    alert({ id: 303, code: 'BOLO', title: 'Efterlyst fordon ABC12D kontrollerat', street: 'Legion Square', priority: 2, source: 'bolo', createdAt: at(-22), description: 'Skylten kontrollerades av IGV-12. Svart Sultan med skadad bakruta.' }),
    alert({ id: 304, code: '10-50', title: 'Trafikolycka med personskada', street: 'Great Ocean Highway', priority: 2, createdAt: at(-15), status: 'assigned', units: [me()], coords: { x: -2150.1, y: -380.6, z: 13.2 } }),
    alert({ id: 305, code: '10-90', title: 'Butiksrån pågår', street: 'Innocence Boulevard', priority: 1, createdAt: at(-8), status: 'assigned', units: [karl], coords: { x: 25.7, y: -1347.3, z: 29.5 }, description: 'Larmknapp utlöst i butiken. Två gärningspersoner, en med kniv.' }),
    alert({ id: 306, code: '10-71', title: 'Skottlossning', street: 'Grove Street', priority: 1, createdAt: at(-3), coords: { x: 104.2, y: -1938.9, z: 20.8 }, description: 'Flera skott hörda enligt inringare. Ungefärlig plats (inom 110 m).' }),
  ];
  const onAlert = (a: Alert, cid: string) => a.units.some((u) => u.citizenid === cid);
  const units = (): { units: UnitStatus[] } => ({
    units: db.officers.map((o) => {
      const busy = alerts.filter((a) => a.status !== 'closed' && onAlert(a, o.citizenid)).sort((x, y) => y.id - x.id)[0];
      return { citizenid: o.citizenid, displayName: o.displayName, callsign: o.callsign, unit: o.unit, onDuty: o.onDuty, alertId: busy?.id ?? null };
    }),
  });
  const findAlert = (id: number) => alerts.find((a) => a.id === id);

  // ---------------------------------------------------------------------------------------------------------------
  // Ärenden, rapporter, brottskatalog
  // ---------------------------------------------------------------------------------------------------------------
  const extras = new Map<number, MockCaseExtra>();
  const extraFor = (c: MockCase): MockCaseExtra => {
    let x = extras.get(c.id);
    if (!x) {
      const owner = c.mine ? me() : c.contact.displayName === 'Bo Carlsson' ? bo : c.contact.displayName === 'Karl Lund' ? karl : lina;
      x = {
        summary: c.id === 1042 ? 'Värdetransport rånad vid Legion Square cirka kl. 14. Två gärningspersoner flydde i svart Sultan (ABC 12D). Vittne hörs.' : null,
        owner,
        assignees: [{ ...owner, role: 'lead' }, ...(c.id === 1042 ? [{ ...karl, role: 'member' as const }] : [])],
        createdAt: at(-60 * 24 * (c.id % 7 + 1)),
        closedAt: c.status === 'closed' ? at(-60 * 24) : null,
        timeline: [],
      };
      x.timeline.push({ at: x.createdAt, actor: owner, action: 'case.create', detail: null });
      extras.set(c.id, x);
    }
    return x;
  };
  let nextCaseId = 1200;
  let nextReportId = 900;
  let nextRecordId = 700;

  const reports: MockReport[] = [
    {
      id: 811, caseId: 1042, n: 1, title: 'Anmälan: rån mot värdetransport', level: 0, author: lina, createdAt: at(-60 * 20), updatedAt: at(-60 * 19),
      body: '# Händelse\nVärdetransporten stoppades av **två maskerade personer** vid Legion Square.\n\n## Iakttagelser\n- Svart Sultan, ABC 12D\n- En gärningsperson bar automatvapen\n\nVittnet Sara Lindqvist hörs på plats.',
      charges: [],
    },
    {
      id: 812, caseId: 1042, n: 2, title: 'PM: spaning mot misstänkt', level: 1, author: bo, createdAt: at(-60 * 10), updatedAt: at(-60 * 10),
      body: '# Spaning\nMisstänkt setts vid **Grove Street 14** flera kvällar i rad.', charges: [],
    },
    {
      id: 813, caseId: 1042, n: 3, title: 'Hemlig rapport från källa', level: 2, author: bo, createdAt: at(-60 * 5), updatedAt: at(-60 * 5),
      body: 'Källuppgifter.', charges: [],
    },
    {
      id: 820, caseId: 1101, n: 1, title: 'Anmälan: misshandel', level: 0, author: me(), createdAt: at(-60 * 3), updatedAt: at(-60 * 3),
      body: '# Anmälan\nMålsäganden **Maria Karlsson** uppger att hon blev slagen i ansiktet vid Vespucci Beach.\n\n- Rodnad vid vänster kind\n- Gärningspersonen okänd',
      charges: [],
    },
  ];
  const reportNumber = (r: MockReport, c: MockCase) => `${c.caseNumber}-R${String(r.n).padStart(2, '0')}`;
  const templates = [
    { id: 1, name: 'Anmälan – misshandel', unit: 'igv', body: '# Anmälan\n**Målsägande:** \n**Plats:** \n\n## Händelseförlopp\n\n## Skador\n- \n\n## Vittnen\n- ' },
    { id: 2, name: 'Rapport – trafikolycka', unit: 'igv', body: '# Trafikolycka\n**Plats:** \n**Inblandade fordon:** \n\n## Förlopp\n\n## Åtgärder\n- Alkoholutandningsprov\n- ' },
    { id: 3, name: 'PM – spaning', unit: 'span', body: '# Promemoria\n**Spaningsobjekt:** \n**Tid:** \n\n## Iakttagelser\n- ' },
    { id: 4, name: 'Beslagsprotokoll', unit: null, body: '# Beslag\n**Plats:** \n\n## Beslagtaget gods\n- \n\n## Anledning\n' },
  ];
  const charges = parseChargesSeed(chargesSeed);
  const chargeByCode = new Map(charges.map((c) => [c.code, c]));

  const visibleCase = (id: number) => db.cases.find((c) => c.id === id);
  const caseRef = (c: MockCase): TabletOutput<'listCases'>['items'][number] => {
    switch (c.visibility) {
      case 'full':
        return { visibility: 'full', id: c.id, caseNumber: c.caseNumber, title: c.title, status: c.status, level: c.level, role: null };
      case 'masked':
        return { visibility: 'masked', id: c.id, caseNumber: c.caseNumber, title: c.maskedTitle ? c.title : null, status: c.status, level: c.level, role: null };
      case 'notice':
        return { visibility: 'notice', contact: { ...c.contact } };
    }
  };
  const subjectsOf = (c: MockCase) => [
    ...c.persons.map((p) => ({ type: 'person' as const, citizenid: p.citizenid, label: personName(p.citizenid) ?? p.citizenid, role: p.role })),
    ...c.vehicles.map((plate) => ({ type: 'vehicle' as const, plate, label: `${plate} (${db.vehicles.find((v) => v.plate === plate)?.model ?? '?'})`, role: 'other' as const })),
  ];
  const reportRefs = (c: MockCase, masked: boolean) =>
    reports
      .filter((r) => r.caseId === c.id && (!masked || r.level <= db.tier))
      .map((r) => ({ id: r.id, reportNumber: reportNumber(r, c), title: r.level > db.tier ? null : r.title, level: r.level, author: r.author, createdAt: r.createdAt }));
  // Evidence is declared below; the case page reads it through this function.
  const caseEvidence = (caseId: number) =>
    evidence.filter((e) => e.caseId === caseId && e.tag !== null).map((e) => ({ id: e.id, tag: e.tag!, type: e.type, collectedAt: e.collectedAt }));
  const caseDetail = (c: MockCase): CaseDetail => {
    const x = extraFor(c);
    const base = { id: c.id, caseNumber: c.caseNumber, status: c.status, level: c.level, unit: c.contact.unit, owner: x.owner, assignees: x.assignees, createdAt: x.createdAt, closedAt: x.closedAt };
    const timeline = [
      ...x.timeline,
      ...reports.filter((r) => r.caseId === c.id).map((r): CaseTimeline => ({ at: r.createdAt, actor: r.author, action: 'report.create', detail: reportNumber(r, c) })),
    ].sort((a, b) => Date.parse(b.at) - Date.parse(a.at));
    switch (c.visibility) {
      case 'notice':
        return { visibility: 'notice', contact: { ...c.contact } };
      case 'masked':
        return { ...base, visibility: 'masked', title: c.maskedTitle ? c.title : null, summary: c.maskedTitle ? x.summary : null, subjects: subjectsOf(c), reports: reportRefs(c, true), evidence: caseEvidence(c.id), timeline };
      case 'full':
        return { ...base, visibility: 'full', title: c.title, summary: x.summary, subjects: subjectsOf(c), reports: reportRefs(c, false), evidence: caseEvidence(c.id), timeline };
    }
  };
  /** Case writes: the server refuses non-full views with not_found (read-level) and closed cases with validation. */
  const writableCase = (id: number): MockCase | MockError => {
    const c = visibleCase(id);
    if (!c || c.visibility === 'notice') return fail('not_found');
    if (c.visibility !== 'full') return fail('unauthorized');
    if (c.status === 'closed') return fail('validation', 'closed');
    return c;
  };
  const isErr = (v: unknown): v is MockError => typeof v === 'object' && v !== null && 'error' in v;
  const reportDetail = (r: MockReport): TabletOutput<'getReport'> => {
    const c = visibleCase(r.caseId)!;
    return {
      id: r.id, reportNumber: reportNumber(r, c), caseId: c.id, caseNumber: c.caseNumber, title: r.title, body: r.body, level: r.level,
      author: r.author, createdAt: r.createdAt, updatedAt: r.updatedAt, charges: r.charges, editable: c.status === 'open',
    };
  };
  const readableReport = (id: number): MockReport | MockError => {
    const r = reports.find((x) => x.id === id);
    const c = r ? visibleCase(r.caseId) : undefined;
    if (!r || !c || c.visibility !== 'full' || r.level > db.tier) return fail('not_found');
    return r;
  };
  const chargeRows = (citizenid: string, lines: { code: string; quantity: number }[]) => {
    const rows: TabletOutput<'applyCharges'>['records'] = [];
    for (const line of lines) {
      const charge = chargeByCode.get(line.code);
      if (!charge) return null;
      nextRecordId += 1;
      rows.push({
        id: nextRecordId, citizenid, personName: personName(citizenid) ?? citizenid, code: charge.code, title: charge.title, class: charge.class,
        quantity: line.quantity, fine: charge.fine * line.quantity, jailMinutes: charge.jailMinutes * line.quantity, status: 'issued',
      });
    }
    return rows;
  };
  const totals = (rows: { fine: number; jailMinutes: number }[]) => ({ fine: rows.reduce((s, r) => s + r.fine, 0), jailMinutes: rows.reduce((s, r) => s + r.jailMinutes, 0) });

  // ---------------------------------------------------------------------------------------------------------------
  // Bevis
  // ---------------------------------------------------------------------------------------------------------------
  const custody = (minutes: number, actor: OfficerRef | null, action: CustodyEntry['action'], location: string | null = null, note: string | null = null): CustodyEntry => ({
    at: at(minutes), actor, action, location, note,
  });
  const evidence: EvidenceItem[] = [
    {
      id: 41, tag: 'B-K-1042-26-001', type: 'fingerprint', caseId: 1042, caseNumber: 'K-1042-26', level: 0,
      result: { fingerprint: 'FP-7F3A-19C2', match: { citizenid: 'FPD00001', name: 'Erik Nilsson' }, crimeScene: 'Legion Square' },
      collectedBy: mats, collectedAt: at(-60 * 19),
      chain: [custody(-60 * 19, mats, 'collect', 'Legion Square'), custody(-60 * 18, mats, 'handin', 'evidence_locker_mrpd'), custody(-60 * 12, mats, 'analyse', 'Kriminaltekniskt labb'), custody(-60 * 11, lina, 'link')],
    },
    {
      id: 42, tag: 'B-K-1042-26-002', type: 'casing', caseId: 1042, caseNumber: 'K-1042-26', level: 0,
      result: { serial: 'SN-44821', weaponType: 'Automatkarbin', kind: 'casing' }, collectedBy: mats, collectedAt: at(-60 * 19),
      chain: [custody(-60 * 19, mats, 'collect', 'Legion Square'), custody(-60 * 18, mats, 'handin', 'evidence_locker_mrpd'), custody(-60 * 9, mats, 'analyse'), custody(-60 * 8, lina, 'link')],
    },
    {
      id: 57, tag: null, type: 'dna', caseId: null, caseNumber: null, level: 0,
      result: { dna: 'DNA-0B21-77E4', crimeScene: 'Grove Street' }, collectedBy: karl, collectedAt: at(-90),
      chain: [custody(-90, karl, 'collect', 'Grove Street'), custody(-70, karl, 'handin', 'evidence_locker_mrpd'), custody(-30, mats, 'analyse')],
    },
    {
      id: 58, tag: null, type: 'blood', caseId: null, caseNumber: null, level: 0,
      result: { dna: 'DNA-5C90-1A3F', match: { citizenid: 'FPD00005', name: 'Mohammed Hassan' }, note: 'Blodstänk på dörrkarm.' }, collectedBy: me(), collectedAt: at(-50),
      chain: [custody(-50, me(), 'collect', 'Innocence Boulevard'), custody(-40, me(), 'transfer', null, 'Överlämnat till TEK-01'), custody(-35, mats, 'handin', 'evidence_locker_mrpd'), custody(-12, mats, 'analyse')],
    },
    {
      id: 59, tag: null, type: 'projectile', caseId: null, caseNumber: null, level: 0,
      result: { weaponType: 'Pistol', kind: 'projectile' }, collectedBy: mats, collectedAt: at(-20),
      chain: [custody(-20, mats, 'collect', 'Grove Street'), custody(-15, mats, 'analyse')],
    },
    {
      id: 60, tag: 'B-K-988-26-001', type: 'photo', caseId: 988, caseNumber: 'K-988-26', level: 1,
      result: null, collectedBy: bo, collectedAt: at(-60 * 24 * 30),
      chain: [custody(-60 * 24 * 30, bo, 'collect', 'Sandy Shores'), custody(-60 * 24 * 29, bo, 'link')],
    },
  ];

  // ---------------------------------------------------------------------------------------------------------------
  // Underrättelser
  // ---------------------------------------------------------------------------------------------------------------
  type SourceRow = { id: number; codename: string; reliability: 'A' | 'B' | 'C' | 'D'; status: 'open' | 'closed'; level: Level; unit: string | null; notes: string | null; handler: OfficerRef | null; real: { citizenid: string; name: string } | null; view: 'full' | 'masked' | 'notice' };
  const sources: SourceRow[] = [
    { id: 11, codename: 'KORPEN', reliability: 'B', status: 'open', level: 2, unit: 'span', notes: 'Rör sig i Vagos kretsar. Träffas endast på parkeringen vid Sandy Shores motell.', handler: me(), real: { citizenid: 'FPD00005', name: 'Mohammed Hassan' }, view: 'full' },
    { id: 12, codename: 'FALKEN', reliability: 'C', status: 'open', level: 2, unit: 'span', notes: null, handler: bo, real: { citizenid: 'FPD00003', name: 'Johan Andersson' }, view: 'masked' },
    { id: 13, codename: 'UGGLAN', reliability: 'D', status: 'closed', level: 2, unit: 'span', notes: null, handler: bo, real: null, view: 'notice' },
  ];
  const sourceView = (s: SourceRow, withIdentity: boolean): TabletOutput<'getSource'> => {
    if (s.view === 'notice') return { visibility: 'notice', contact: { displayName: s.handler?.displayName ?? null, unit: s.unit } };
    if (s.view === 'masked') return { visibility: 'masked', id: s.id, codename: s.codename, reliability: s.reliability, status: s.status, level: s.level };
    return { visibility: 'full', id: s.id, codename: s.codename, reliability: s.reliability, status: s.status, level: s.level, unit: s.unit, notes: s.notes, handler: s.handler, realIdentity: withIdentity ? s.real : null };
  };

  const entities: MockEntity[] = [
    { id: 1, type: 'person', ref: 'FPD00001', label: 'Erik Nilsson' },
    { id: 2, type: 'vehicle', ref: 'ABC12D', label: 'ABC12D (sultan)' },
    { id: 3, type: 'group', ref: null, label: 'Vagos' },
    { id: 4, type: 'location', ref: null, label: 'Sandy Shores motell' },
    { id: 5, type: 'person', ref: 'FPD00005', label: 'Mohammed Hassan' },
    { id: 6, type: 'case', ref: 'K-1042-26', label: 'K-1042-26' },
    { id: 7, type: 'vehicle', ref: 'XYZ98A', label: 'XYZ98A (sentinel)' },
    { id: 8, type: 'group', ref: null, label: 'Ballas' },
  ];
  let nextEntityId = 100;
  const links: MockLink[] = [];
  let nextLinkId = 1;
  const link = (fromId: number, toId: number, type: string, confidence: number, level: Level, reportId: number | null = null, by: OfficerRef | null = bo, minutes = -600) => {
    links.push({ id: nextLinkId, fromId, toId, type, confidence, level, reportId, createdBy: by, createdAt: at(minutes) });
    nextLinkId += 1;
  };
  link(1, 2, 'owns', 90, 0, null, lina, -1200);
  link(1, 3, 'member_of', 70, 1, 31);
  link(1, 4, 'seen_at', 60, 1, 31);
  link(5, 3, 'member_of', 80, 1, 32);
  link(5, 1, 'associate', 55, 1, 32);
  link(1, 6, 'related', 100, 0, null, lina);
  link(7, 3, 'uses', 65, 2, 33);
  link(5, 7, 'uses', 40, 2, 33);
  // A large group, so the graph cap (150 nodes, truncated) shows in dev.
  for (let i = 0; i < 170; i += 1) {
    const p = db.persons[6 + i];
    if (!p) break;
    const id = 200 + i;
    entities.push({ id, type: 'person', ref: p.citizenid, label: `${p.firstname} ${p.lastname}` });
    link(id, 8, 'member_of', 50 + (i % 40), 0, null, bo, -3000 + i);
  }
  link(1, 8, 'associate', 30, 0);

  type IntelReportRow = { id: number; sourceId: number | null; missionId: number | null; author: OfficerRef | null; body: string; reliability: 'A' | 'B' | 'C' | 'D' | null; level: Level; status: 'open' | 'closed'; createdAt: string; view: 'full' | 'notice' };
  const intelReports: IntelReportRow[] = [
    { id: 31, sourceId: 11, missionId: 21, author: me(), body: 'KORPEN uppger att Erik Nilsson hämtar vapen hos Vagos vid motellet på torsdagar.', reliability: 'B', level: 1, status: 'open', createdAt: at(-60 * 30), view: 'full' },
    { id: 32, sourceId: null, missionId: 21, author: bo, body: 'Mohammed Hassan och Erik Nilsson sedda tillsammans vid Grove Street.', reliability: 'C', level: 1, status: 'open', createdAt: at(-60 * 26), view: 'full' },
    { id: 33, sourceId: 13, missionId: 22, author: bo, body: '', reliability: null, level: 2, status: 'open', createdAt: at(-60 * 20), view: 'notice' },
  ];
  type MissionRow = { id: number; title: string; description: string | null; unit: string | null; status: 'open' | 'closed'; level: Level; lead: OfficerRef | null; members: (OfficerRef & { role: string | null })[]; view: 'full' | 'notice' };
  const missions: MissionRow[] = [
    { id: 21, title: 'Insats Nattfjäril', description: 'Kartläggning av vapenflödet till Vagos i Sandy Shores.', unit: 'span', status: 'open', level: 1, lead: me(), members: [{ ...me(), role: 'Insatsledare' }, { ...bo, role: 'Spanare' }], view: 'full' },
    { id: 22, title: 'Insats Vinterträd', description: null, unit: 'span', status: 'open', level: 2, lead: bo, members: [], view: 'notice' },
    { id: 23, title: 'Insats Grävling', description: 'Avslutad kartläggning av stölder i Paleto Bay.', unit: 'span', status: 'closed', level: 0, lead: helena, members: [{ ...helena, role: null }], view: 'full' },
  ];
  let nextMissionId = 30;
  let nextSourceId = 20;
  let nextIntelReportId = 40;
  const missionView = (m: MissionRow): TabletOutput<'getMission'> =>
    m.view === 'notice'
      ? { visibility: 'notice', contact: { displayName: m.lead?.displayName ?? null, unit: m.unit } }
      : {
          visibility: 'full', id: m.id, title: m.title, description: m.description, unit: m.unit, status: m.status, level: m.level, lead: m.lead,
          members: m.members, reports: intelReports.filter((r) => r.missionId === m.id && r.view === 'full').map((r) => ({ id: r.id, level: r.level, createdAt: r.createdAt })),
        };
  const entityById = (id: number) => entities.find((e) => e.id === id);
  const linkVisible = (l: MockLink) => l.level <= db.tier;
  const linkView = (l: MockLink): TabletOutput<'addLink'> => ({
    id: l.id, from: { ...entityById(l.fromId)! }, to: { ...entityById(l.toId)! }, type: l.type, confidence: l.confidence, level: l.level, reportId: l.reportId, createdBy: l.createdBy, createdAt: l.createdAt,
  });
  const intelReportView = (r: IntelReportRow): TabletOutput<'getIntelReport'> => {
    if (r.view === 'notice' || r.level > db.tier) {
      const m = missions.find((x) => x.id === r.missionId);
      return { visibility: 'notice', contact: { displayName: m?.lead?.displayName ?? r.author?.displayName ?? null, unit: m?.unit ?? r.author?.unit ?? null } };
    }
    const s = sources.find((x) => x.id === r.sourceId);
    const m = missions.find((x) => x.id === r.missionId);
    return {
      visibility: 'full', id: r.id, source: s && s.view !== 'notice' ? { id: s.id, codename: s.codename } : null, mission: m && m.view === 'full' ? { id: m.id, title: m.title } : null,
      author: r.author, body: r.body, reliability: r.reliability, level: r.level, status: r.status, createdAt: r.createdAt,
      links: links.filter((l) => l.reportId === r.id && linkVisible(l)).map(linkView),
    };
  };
  const ensure = (input: { type: Entity['type']; ref?: string; label: string }): MockEntity => {
    const ref = input.ref?.trim() || null;
    const existing = entities.find((e) => e.type === input.type && (ref ? e.ref === ref : e.ref === null && e.label.toLocaleLowerCase('sv') === input.label.toLocaleLowerCase('sv')));
    if (existing) return existing;
    nextEntityId += 1;
    const created: MockEntity = { id: nextEntityId, type: input.type, ref, label: input.label };
    entities.push(created);
    return created;
  };

  return {
    // ---- Larm -----------------------------------------------------------------------------------------------------
    listAlerts: (raw) => {
      const input = parse('listAlerts', raw);
      if (!input) return fail('validation');
      const cid = db.me.citizenid;
      const list = alerts
        .filter((a) => (input.filter === 'open' ? a.status !== 'closed' : input.filter === 'mine' ? a.status !== 'closed' && onAlert(a, cid) : true))
        .sort((a, b) => b.id - a.id);
      return paginate(list, input.page);
    },
    takeAlert: (raw) => {
      const input = parse('takeAlert', raw);
      const a = input && findAlert(input.id);
      if (!a || a.status === 'closed') return fail('not_found');
      if (!onAlert(a, db.me.citizenid)) a.units = [...a.units, me()];
      a.status = 'assigned';
      return { ...a };
    },
    leaveAlert: (raw) => {
      const input = parse('leaveAlert', raw);
      const a = input && findAlert(input.id);
      if (!a || a.status === 'closed' || !onAlert(a, db.me.citizenid)) return fail('not_found');
      a.units = a.units.filter((u) => u.citizenid !== db.me.citizenid);
      if (a.units.length === 0) a.status = 'open';
      return { ...a };
    },
    closeAlert: (raw) => {
      const input = parse('closeAlert', raw);
      const a = input && findAlert(input.id);
      if (!a || a.status === 'closed') return fail('not_found');
      if (!onAlert(a, db.me.citizenid) && db.unit !== 'ledning') return fail('unauthorized');
      a.status = 'closed';
      a.closedBy = me();
      a.closedAt = isoUtc(now());
      return { ...a };
    },
    getUnits: () => units(),

    // ---- Bevis ----------------------------------------------------------------------------------------------------
    listEvidence: (raw) => {
      const input = parse('listEvidence', raw);
      if (!input) return fail('validation');
      let list = evidence.filter((e) => e.level <= db.tier);
      if (input.caseId !== undefined) list = list.filter((e) => e.caseId === input.caseId);
      else if (input.unlinked) list = list.filter((e) => e.caseId === null && e.chain.some((c) => c.action === 'analyse'));
      list = list.slice().sort((a, b) => Date.parse(b.collectedAt ?? '') - Date.parse(a.collectedAt ?? '') || b.id - a.id);
      return paginate(list, input.page);
    },
    getEvidence: (raw) => {
      const input = parse('getEvidence', raw);
      const e = input && evidence.find((x) => x.id === input.id);
      if (!e || e.level > db.tier) return fail('not_found');
      return structuredClone(e);
    },
    linkEvidence: (raw) => {
      const input = parse('linkEvidence', raw);
      const e = input && evidence.find((x) => x.id === input.id);
      if (!input || !e) return fail('not_found', 'evidence');
      if (e.caseId !== null) return fail('validation', 'already_linked');
      const c = visibleCase(input.caseId);
      if (!c || c.visibility === 'notice') return fail('not_found', 'case');
      if (c.visibility !== 'full') return fail('unauthorized');
      if (c.status === 'closed') return fail('validation', 'case_closed');
      const n = evidence.filter((x) => x.caseId === c.id).length + 1;
      e.caseId = c.id;
      e.caseNumber = c.caseNumber;
      e.tag = `B-${c.caseNumber}-${String(n).padStart(3, '0')}`;
      e.chain = [...e.chain, custody(0, me(), 'link')].map((entry, i, all) => (i === all.length - 1 ? { ...entry, at: isoUtc(now()) } : entry));
      extraFor(c).timeline.push({ at: isoUtc(now()), actor: me(), action: 'evidence.link', detail: e.tag });
      return structuredClone(e);
    },

    // ---- Ärenden --------------------------------------------------------------------------------------------------
    listCases: (raw) => {
      const input = parse('listCases', raw);
      if (!input) return fail('validation');
      const q = input.query?.toLocaleLowerCase('sv') ?? '';
      const list = db.cases
        .filter((c) => {
          switch (input.filter) {
            case 'mine':
              return c.mine;
            case 'unit':
              return db.unit !== null && c.contact.unit === db.unit;
            case 'open':
              return c.status === 'open';
            case 'closed':
              return c.status === 'closed';
            case 'all':
              return true;
          }
        })
        // A query matches the number, and the title only where the viewer may see it (never a notice's).
        .filter((c) => !q || (c.visibility !== 'notice' && (c.caseNumber.toLocaleLowerCase('sv').includes(q) || ((c.visibility === 'full' || c.maskedTitle) && c.title.toLocaleLowerCase('sv').includes(q)))))
        .sort((a, b) => Number(b.status === 'open') - Number(a.status === 'open') || b.id - a.id)
        .map(caseRef);
      return paginate(list, input.page);
    },
    getCase: (raw) => {
      const input = parse('getCase', raw);
      const c = input && visibleCase(input.id);
      if (!c) return fail('not_found');
      return caseDetail(c);
    },
    createCase: (raw) => {
      const input = parse('createCase', raw);
      if (!input) return fail('validation');
      if (input.level > db.tier) return fail('validation', 'level');
      nextCaseId += 1;
      const c: MockCase = {
        id: nextCaseId, caseNumber: `K-${nextCaseId}-26`, title: input.title, status: 'open', level: input.level, visibility: 'full', maskedTitle: true,
        contact: { displayName: db.me.displayName, unit: input.unit ?? db.unit }, persons: [], vehicles: [], mine: true,
      };
      db.cases.push(c);
      extraFor(c).summary = input.summary ?? null;
      return caseDetail(c);
    },
    updateCase: (raw) => {
      const input = parse('updateCase', raw);
      if (!input) return fail('validation');
      const c = writableCase(input.id);
      if (isErr(c)) return c;
      if (input.level !== undefined && (input.level > db.tier || input.level < c.level)) return fail('validation', 'level');
      if (input.title !== undefined) c.title = input.title;
      if (input.summary !== undefined) extraFor(c).summary = input.summary || null;
      if (input.level !== undefined) c.level = input.level;
      return caseDetail(c);
    },
    assignCase: (raw) => {
      const input = parse('assignCase', raw);
      if (!input) return fail('validation');
      const c = writableCase(input.id);
      if (isErr(c)) return c;
      const o = db.officers.find((x) => x.citizenid === input.citizenid);
      if (!o) return fail('not_found', 'officer');
      const x = extraFor(c);
      x.assignees = [...x.assignees.filter((a) => a.citizenid !== o.citizenid), { ...officer(o.citizenid), role: input.role }];
      x.timeline.push({ at: isoUtc(now()), actor: me(), action: 'case.assign', detail: o.callsign ? `${o.callsign} · ${o.displayName}` : o.displayName });
      return caseDetail(c);
    },
    unassignCase: (raw) => {
      const input = parse('unassignCase', raw);
      if (!input) return fail('validation');
      const c = writableCase(input.id);
      if (isErr(c)) return c;
      const x = extraFor(c);
      if (!x.assignees.some((a) => a.citizenid === input.citizenid)) return fail('not_found');
      x.assignees = x.assignees.filter((a) => a.citizenid !== input.citizenid);
      x.timeline.push({ at: isoUtc(now()), actor: me(), action: 'case.unassign', detail: null });
      return caseDetail(c);
    },
    addCaseSubject: (raw) => {
      const input = parse('addCaseSubject', raw);
      if (!input) return fail('validation');
      const c = writableCase(input.id);
      if (isErr(c)) return c;
      if (input.type === 'person') {
        if (!input.citizenid || !personName(input.citizenid)) return fail('not_found');
        if (!c.persons.some((p) => p.citizenid === input.citizenid)) c.persons.push({ citizenid: input.citizenid, role: input.role });
      } else {
        const plate = input.plate?.toUpperCase().replace(/\s+/g, '') ?? '';
        if (!db.vehicles.some((v) => v.plate === plate)) return fail('not_found');
        if (!c.vehicles.includes(plate)) c.vehicles.push(plate);
      }
      extraFor(c).timeline.push({ at: isoUtc(now()), actor: me(), action: 'case.subject', detail: null });
      return caseDetail(c);
    },
    closeCase: (raw) => {
      const input = parse('closeCase', raw);
      if (!input) return fail('validation');
      const c = writableCase(input.id);
      if (isErr(c)) return c;
      c.status = 'closed';
      const x = extraFor(c);
      x.closedAt = isoUtc(now());
      x.timeline.push({ at: x.closedAt, actor: me(), action: 'case.close', detail: null });
      return caseDetail(c);
    },

    // ---- Rapporter ------------------------------------------------------------------------------------------------
    getReport: (raw) => {
      const input = parse('getReport', raw);
      if (!input) return fail('not_found');
      const r = readableReport(input.id);
      return isErr(r) ? r : reportDetail(r);
    },
    createReport: (raw) => {
      const input = parse('createReport', raw);
      if (!input) return fail('validation');
      const c = writableCase(input.caseId);
      if (isErr(c)) return c;
      if (input.level > db.tier) return fail('validation', 'level');
      nextReportId += 1;
      const template = templates.find((x) => x.id === input.templateId);
      const r: MockReport = {
        id: nextReportId, caseId: c.id, n: reports.filter((x) => x.caseId === c.id).length + 1, title: input.title, body: template?.body ?? '', level: input.level,
        author: me(), createdAt: isoUtc(now()), updatedAt: isoUtc(now()), charges: [],
      };
      reports.push(r);
      return reportDetail(r);
    },
    saveReport: (raw) => {
      const input = parse('saveReport', raw);
      if (!input) return fail('validation');
      const r = readableReport(input.id);
      if (isErr(r)) return r;
      if (visibleCase(r.caseId)?.status !== 'open') return fail('validation', 'closed');
      if (input.level > db.tier) return fail('validation', 'level');
      Object.assign(r, { title: input.title, body: input.body, level: input.level, updatedAt: isoUtc(now()) });
      return reportDetail(r);
    },
    saveReportDraft: (raw) => {
      const input = parse('saveReportDraft', raw);
      if (!input) return fail('validation');
      const r = readableReport(input.reportId);
      return isErr(r) ? r : { savedAt: isoUtc(now()) };
    },
    listReportTemplates: () => ({ items: templates.filter((x) => x.unit === null || x.unit === db.unit || db.unit === null).map((x) => ({ ...x })) }),
    listCharges: (raw) => {
      const input = parse('listCharges', raw);
      if (!input) return fail('validation');
      const q = input.query?.toLocaleLowerCase('sv') ?? '';
      return {
        items: charges.filter(
          (c) => (!input.class || c.class === input.class) && (!q || [c.code, c.title, c.lawRef].some((f) => f.toLocaleLowerCase('sv').includes(q))),
        ),
      };
    },
    applyCharges: (raw) => {
      const input = parse('applyCharges', raw);
      if (!input) return fail('validation');
      const r = readableReport(input.reportId);
      if (isErr(r)) return r;
      if (!personName(input.citizenid)) return fail('not_found', 'person');
      const rows = chargeRows(input.citizenid, input.lines);
      if (!rows) return fail('validation', 'code');
      r.charges = [...r.charges, ...rows];
      return { records: rows, totals: totals(rows) };
    },
    issueFine: (raw) => {
      const input = parse('issueFine', raw);
      if (!input) return fail('validation');
      if (input.lines.some((l) => chargeByCode.get(l.code)?.class !== 'ordningsbot')) return fail('validation', 'class');
      if (!personName(input.citizenid)) return fail('not_found', 'person');
      const rows = chargeRows(input.citizenid, input.lines);
      if (!rows) return fail('validation', 'code');
      return { records: rows, totals: totals(rows) };
    },

    // ---- Underrättelser -------------------------------------------------------------------------------------------
    listSources: (raw) => {
      const input = parse('listSources', raw);
      if (!input) return fail('validation');
      // Lists never carry the real identity (docs/modules/intel.md "Sources").
      return paginate(sources.map((s) => sourceView(s, false)), input.page);
    },
    getSource: (raw) => {
      const input = parse('getSource', raw);
      const s = input && sources.find((x) => x.id === input.id);
      if (!s) return fail('not_found');
      return sourceView(s, s.handler?.citizenid === db.me.citizenid);
    },
    createSource: (raw) => {
      const input = parse('createSource', raw);
      if (!input) return fail('validation');
      if (input.level > db.tier) return fail('validation', 'level');
      nextSourceId += 1;
      const row: SourceRow = {
        id: nextSourceId, codename: input.codename.toUpperCase(), reliability: input.reliability, status: 'open', level: input.level, unit: db.unit,
        notes: input.notes ?? null, handler: me(), real: input.realCitizenid ? { citizenid: input.realCitizenid, name: personName(input.realCitizenid) ?? input.realCitizenid } : null, view: 'full',
      };
      sources.push(row);
      return sourceView(row, true);
    },
    updateSource: (raw) => {
      const input = parse('updateSource', raw);
      const s = input && sources.find((x) => x.id === input.id);
      if (!input || !s || s.view === 'notice') return fail('not_found');
      if (s.handler?.citizenid !== db.me.citizenid) return fail('unauthorized');
      if (input.reliability) s.reliability = input.reliability;
      if (input.status) s.status = input.status;
      if (input.notes !== undefined) s.notes = input.notes || null;
      return sourceView(s, true);
    },
    listIntelReports: (raw) => {
      const input = parse('listIntelReports', raw);
      if (!input) return fail('validation');
      let list = intelReports.slice();
      if (input.sourceId !== undefined) list = list.filter((r) => r.sourceId === input.sourceId && r.view === 'full');
      if (input.missionId !== undefined) list = list.filter((r) => r.missionId === input.missionId);
      const views = list.sort((a, b) => b.id - a.id).map(intelReportView);
      // Notice-only reports collapse to one kontaktnotis per contact.
      const seen = new Set<string>();
      const collapsed = views.filter((v) => {
        if (v.visibility !== 'notice') return true;
        const key = `${v.contact.displayName}|${v.contact.unit}`;
        if (seen.has(key)) return false;
        seen.add(key);
        return true;
      });
      return paginate(collapsed, input.page);
    },
    getIntelReport: (raw) => {
      const input = parse('getIntelReport', raw);
      const r = input && intelReports.find((x) => x.id === input.id);
      if (!r) return fail('not_found');
      return intelReportView(r);
    },
    createIntelReport: (raw) => {
      const input = parse('createIntelReport', raw);
      if (!input) return fail('validation');
      if (input.level > db.tier) return fail('validation', 'level');
      if (input.sourceId !== undefined && sources.find((s) => s.id === input.sourceId)?.view !== 'full') return fail('not_found');
      if (input.missionId !== undefined && missions.find((m) => m.id === input.missionId)?.view !== 'full') return fail('not_found');
      nextIntelReportId += 1;
      const row: IntelReportRow = {
        id: nextIntelReportId, sourceId: input.sourceId ?? null, missionId: input.missionId ?? null, author: me(), body: input.body, reliability: input.reliability ?? null,
        level: input.level, status: 'open', createdAt: isoUtc(now()), view: 'full',
      };
      intelReports.push(row);
      return intelReportView(row);
    },
    searchEntities: (raw) => {
      const input = parse('searchEntities', raw);
      if (!input) return fail('validation');
      const q = input.query.toLocaleLowerCase('sv');
      return {
        items: entities
          .filter((e) => (!input.type || e.type === input.type) && (e.label.toLocaleLowerCase('sv').startsWith(q) || (e.ref ?? '').toLocaleLowerCase('sv') === q))
          .slice(0, 25)
          .map((e) => ({ ...e })),
      };
    },
    ensureEntity: (raw) => {
      const input = parse('ensureEntity', raw);
      if (!input) return fail('validation');
      return { ...ensure(input) };
    },
    getEntity: (raw) => {
      const input = parse('getEntity', raw);
      const e = input && entityById(input.id);
      if (!e) return fail('not_found');
      const touching = links.filter((l) => l.fromId === e.id || l.toId === e.id);
      const visible = touching.filter(linkVisible).sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt) || b.id - a.id);
      const reportIds = new Set(visible.map((l) => l.reportId).filter((id): id is number => id !== null));
      const hiddenMissions = new Set(
        touching
          .map((l) => intelReports.find((r) => r.id === l.reportId))
          .filter((r): r is IntelReportRow => !!r && (r.view === 'notice' || r.level > db.tier))
          .map((r) => r.missionId),
      );
      return {
        entity: { ...e },
        links: visible.map(linkView),
        hiddenLinks: touching.length - visible.length,
        reports: intelReports.filter((r) => reportIds.has(r.id) && r.view === 'full' && r.level <= db.tier).map((r) => ({ id: r.id, level: r.level, createdAt: r.createdAt, author: r.author })),
        notices: [...hiddenMissions].flatMap((mid) => {
          const m = missions.find((x) => x.id === mid);
          return m ? [{ visibility: 'notice' as const, contact: { displayName: m.lead?.displayName ?? null, unit: m.unit } }] : [];
        }),
      };
    },
    addLink: (raw) => {
      const input = parse('addLink', raw);
      if (!input) return fail('validation');
      const from = entityById(input.fromId);
      if (!from) return fail('not_found');
      if (input.level > db.tier) return fail('validation', 'level');
      const to = 'id' in input.to ? entityById(input.to.id) : ensure(input.to);
      if (!to) return fail('not_found');
      if (to.id === from.id) return fail('validation');
      link(from.id, to.id, input.type, input.confidence, input.level, input.reportId ?? null, me(), 0);
      const created = links[links.length - 1]!;
      created.createdAt = isoUtc(now());
      return linkView(created);
    },
    getGraph: (raw) => {
      const input = parse('getGraph', raw);
      const root = input && entityById(input.entityId);
      if (!input || !root) return fail('not_found');
      const nodes = new Map<number, boolean>([[root.id, true]]);
      const edges: Graph['edges'] = [];
      let truncated = false;
      let frontier = [root.id];
      for (let depth = 0; depth < input.depth; depth += 1) {
        const next: number[] = [];
        for (const id of frontier) {
          for (const l of links.filter((x) => linkVisible(x) && (x.fromId === id || x.toId === id))) {
            const other = l.fromId === id ? l.toId : l.fromId;
            if (!nodes.has(other)) {
              if (nodes.size >= GRAPH_NODE_CAP) {
                truncated = true;
                continue;
              }
              nodes.set(other, false);
              next.push(other);
            }
          }
        }
        frontier = next;
      }
      for (const l of links) {
        if (linkVisible(l) && nodes.has(l.fromId) && nodes.has(l.toId) && !edges.some((e) => e.id === l.id)) {
          edges.push({ id: l.id, from: l.fromId, to: l.toId, type: l.type, confidence: l.confidence });
        }
      }
      return { nodes: [...nodes].map(([id, isRoot]) => ({ ...entityById(id)!, root: isRoot })), edges, truncated };
    },
    listMissions: (raw) => {
      const input = parse('listMissions', raw);
      if (!input) return fail('validation');
      return paginate(missions.slice().sort((a, b) => Number(b.status === 'open') - Number(a.status === 'open') || b.id - a.id).map(missionView), input.page);
    },
    getMission: (raw) => {
      const input = parse('getMission', raw);
      const m = input && missions.find((x) => x.id === input.id);
      if (!m) return fail('not_found');
      return missionView(m);
    },
    createMission: (raw) => {
      const input = parse('createMission', raw);
      if (!input) return fail('validation');
      if (input.level > db.tier) return fail('validation', 'level');
      nextMissionId += 1;
      const m: MissionRow = { id: nextMissionId, title: input.title, description: input.description ?? null, unit: input.unit ?? db.unit, status: 'open', level: input.level, lead: me(), members: [{ ...me(), role: null }], view: 'full' };
      missions.push(m);
      return missionView(m);
    },
    addMissionMember: (raw) => {
      const input = parse('addMissionMember', raw);
      const m = input && missions.find((x) => x.id === input.id);
      if (!input || !m || m.view !== 'full') return fail('not_found');
      if (m.status === 'closed') return fail('validation', 'closed');
      if (m.lead?.citizenid !== db.me.citizenid) return fail('unauthorized');
      if (!db.officers.some((o) => o.citizenid === input.citizenid)) return fail('not_found', 'officer');
      m.members = [...m.members.filter((x) => x.citizenid !== input.citizenid), { ...officer(input.citizenid), role: input.role ?? null }];
      return missionView(m);
    },
    closeMission: (raw) => {
      const input = parse('closeMission', raw);
      const m = input && missions.find((x) => x.id === input.id);
      if (!m || m.view !== 'full') return fail('not_found');
      if (m.lead?.citizenid !== db.me.citizenid) return fail('unauthorized');
      m.status = 'closed';
      return missionView(m);
    },
  };
}
