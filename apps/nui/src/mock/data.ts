// SPDX-License-Identifier: GPL-3.0-only
// Browser dev mode only: an in-memory register with Swedish mock data behind every tablet action (src/mock/
// handlers.ts). Built by createMockDb() on demand; nothing runs at import time, so production builds drop the
// module (it is only reachable from `import.meta.env.DEV` branches).
import type { Bolo, Level, OfficerRef } from '@fredpd/types/mdt';

export interface MockPerson {
  citizenid: string;
  firstname: string;
  lastname: string;
  birthdate: string | null;
  personnummer: string | null;
  gender: 'male' | 'female' | 'unknown';
  phone: string | null;
  address: string | null;
}

export interface MockVehicle {
  plate: string;
  model: string | null;
  ownerCitizenid: string | null;
}

export type MockRole = 'suspect' | 'victim' | 'witness' | 'other';

export interface MockCase {
  id: number;
  caseNumber: string;
  title: string;
  status: 'open' | 'closed';
  level: Level;
  /** What canView gives the dev viewer for this case. */
  visibility: 'full' | 'masked' | 'notice';
  /** Masked only: whether the title is shown (case level ≤ viewer tier). */
  maskedTitle: boolean;
  contact: { displayName: string | null; unit: string | null };
  persons: { citizenid: string; role: MockRole }[];
  vehicles: string[];
  mine: boolean;
}

export interface MockRecord {
  id: number;
  citizenid: string;
  chargeCode: string;
  title: string;
  fine: number;
  jailMinutes: number;
  createdAt: string;
  caseId: number | null;
}

export interface MockCheck {
  plate: string;
  checkedAt: string;
  officer: OfficerRef | null;
  hit: boolean;
}

export interface MockTablet {
  serial: string;
  owner: { citizenid: string; name: string } | null;
  revoked: boolean;
  issuedBy: OfficerRef | null;
  issuedAt: string;
}

export interface MockOfficer extends OfficerRef {
  onDuty: boolean;
}

export interface MockDb {
  now: () => number;
  me: OfficerRef;
  tier: Level;
  unit: string | null;
  persons: MockPerson[];
  vehicles: MockVehicle[];
  cases: MockCase[];
  records: MockRecord[];
  bolos: Bolo[];
  checks: MockCheck[];
  tablets: MockTablet[];
  officers: MockOfficer[];
  nextBoloId: number;
}

export interface MockDbOptions {
  me: OfficerRef;
  tier: Level;
  unit: string | null;
  /** Fixed clock for tests; default Date.now. */
  now?: () => number;
}

const HOUR = 3_600_000;

/** `YYYY-MM-DDTHH:mm:ssZ`, the server's format (§C12). */
export function isoUtc(ms: number): string {
  return new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
}

const FIRST_NAMES: readonly (readonly [string, 'male' | 'female'])[] = [
  ['Anders', 'male'], ['Maria', 'female'], ['Erik', 'male'], ['Karin', 'female'], ['Johan', 'male'],
  ['Sara', 'female'], ['Lars', 'male'], ['Emma', 'female'], ['Oskar', 'male'], ['Elin', 'female'],
  ['Mohammed', 'male'], ['Fatima', 'female'], ['Nils', 'male'], ['Ingrid', 'female'], ['Peter', 'male'],
  ['Linnea', 'female'], ['Ali', 'male'], ['Sofia', 'female'], ['Gustav', 'male'], ['Amira', 'female'],
];
const LAST_NAMES: readonly string[] = [
  'Andersson', 'Johansson', 'Karlsson', 'Nilsson', 'Eriksson', 'Larsson', 'Olsson', 'Persson', 'Svensson',
  'Gustafsson', 'Pettersson', 'Lindqvist', 'Berg', 'Holm', 'Hassan', 'Yusuf', 'Lindberg', 'Ekström', 'Åberg',
];
const STREETS: readonly string[] = [
  'Grove Street', 'Forum Drive', 'Vespucci Boulevard', 'Alta Street', 'Mirror Park Boulevard', 'Paleto Boulevard',
  'Algonquin Boulevard', 'Integrity Way', 'Hawick Avenue', 'Strawberry Avenue',
];
const MODELS: readonly string[] = ['sultan', 'buffalo', 'sentinel', 'asea', 'blista', 'bison', 'dominator', 'oracle', 'tailgater', 'premier', 'stanier', 'felon'];
const PLATE_LETTERS = 'ABCDEFGHJKLMNOPRSTUWXYZ';

const pad = (n: number, width: number) => String(n).padStart(width, '0');

function generatedPerson(i: number): MockPerson {
  const [firstname, gender] = FIRST_NAMES[i % FIRST_NAMES.length] ?? ['Anna', 'female'];
  const lastname = LAST_NAMES[(i * 7 + 3) % LAST_NAMES.length] ?? 'Svensson';
  const year = 1958 + ((i * 37) % 47);
  const month = ((i * 5) % 12) + 1;
  const day = ((i * 11) % 28) + 1;
  // Second-to-last digit odd for men, even for women (Swedish personnummer).
  const serial = `${pad((i * 13) % 100, 2)}${gender === 'male' ? (i % 5) * 2 + 1 : (i % 5) * 2}${(i * 7) % 10}`;
  const birthdate = `${year}-${pad(month, 2)}-${pad(day, 2)}`;
  return {
    citizenid: `FPD${pad(100 + i, 5)}`,
    firstname,
    lastname,
    birthdate,
    personnummer: i % 9 === 4 ? null : `${year}${pad(month, 2)}${pad(day, 2)}-${serial}`,
    gender,
    phone: i % 4 === 3 ? null : `070-${pad((i * 7919) % 1000, 3)} ${pad((i * 31) % 100, 2)} ${pad((i * 17) % 100, 2)}`,
    address: i % 3 === 2 ? null : `${STREETS[i % STREETS.length]} ${(i % 60) + 1}`,
  };
}

function generatedPlate(i: number): string {
  const l = (k: number) => PLATE_LETTERS[k % PLATE_LETTERS.length];
  return `${l(i * 3 + 1)}${l(i * 5 + 7)}${l(i * 11 + 2)}${pad((i * 29) % 100, 2)}${l(i * 13 + 5)}`;
}

export function createMockDb(options: MockDbOptions): MockDb {
  const now = options.now ?? (() => Date.now());
  const t0 = now();
  const at = (hoursFromNow: number) => isoUtc(t0 + hoursFromNow * HOUR);
  const me = options.me;

  const meRef: OfficerRef = { citizenid: me.citizenid, displayName: me.displayName, callsign: me.callsign, unit: me.unit };
  const bo: OfficerRef = { citizenid: 'OFF00002', displayName: 'Bo Carlsson', callsign: 'SPAN-02', unit: 'span' };
  const lina: OfficerRef = { citizenid: 'OFF00003', displayName: 'Lina Ek', callsign: 'UTR-03', unit: 'utredning' };
  const mats: OfficerRef = { citizenid: 'OFF00004', displayName: 'Mats Öberg', callsign: 'TEK-01', unit: 'tekniker' };
  const karl: OfficerRef = { citizenid: 'OFF00005', displayName: 'Karl Lund', callsign: 'IGV-12', unit: 'igv' };
  const helena: OfficerRef = { citizenid: 'OFF00006', displayName: 'Helena Sjöberg', callsign: 'LED-01', unit: 'ledning' };
  const jonas: OfficerRef = { citizenid: 'OFF00007', displayName: 'Jonas Wikström', callsign: null, unit: null };
  const officers: MockOfficer[] = [
    { ...meRef, onDuty: true },
    { ...bo, onDuty: true },
    { ...lina, onDuty: true },
    { ...mats, onDuty: false },
    { ...karl, onDuty: true },
    { ...helena, onDuty: true },
    { ...jonas, onDuty: false },
  ];

  const persons: MockPerson[] = [
    { citizenid: 'FPD00001', firstname: 'Erik', lastname: 'Nilsson', birthdate: '1987-04-12', personnummer: '19870412-5531', gender: 'male', phone: '070-412 55 31', address: 'Grove Street 14, Davis' },
    { citizenid: 'FPD00002', firstname: 'Maria', lastname: 'Karlsson', birthdate: '1992-07-21', personnummer: '19920721-3382', gender: 'female', phone: '073-721 33 82', address: 'Mirror Park Boulevard 7' },
    { citizenid: 'FPD00003', firstname: 'Johan', lastname: 'Andersson', birthdate: '1979-01-05', personnummer: '19790105-1238', gender: 'male', phone: '076-105 12 38', address: null },
    { citizenid: 'FPD00004', firstname: 'Sara', lastname: 'Lindqvist', birthdate: '2001-09-30', personnummer: '20010930-4460', gender: 'female', phone: null, address: 'Alta Street 3' },
    { citizenid: 'FPD00005', firstname: 'Mohammed', lastname: 'Hassan', birthdate: '1995-02-14', personnummer: '19950214-7719', gender: 'male', phone: '072-214 77 19', address: 'Forum Drive 22' },
    { citizenid: 'FPD00006', firstname: 'Karin', lastname: 'Andersson', birthdate: null, personnummer: null, gender: 'unknown', phone: null, address: null },
  ];
  for (let i = 0; i < 900; i += 1) persons.push(generatedPerson(i));

  const vehicles: MockVehicle[] = [
    { plate: 'ABC12D', model: 'sultan', ownerCitizenid: 'FPD00001' },
    { plate: 'KLM34F', model: 'buffalo', ownerCitizenid: 'FPD00002' },
    { plate: 'GHJ55B', model: 'asea', ownerCitizenid: 'FPD00003' },
    { plate: 'XYZ98A', model: 'sentinel', ownerCitizenid: 'FPD00005' },
    { plate: 'MNO77C', model: 'blista', ownerCitizenid: 'FPD00001' },
  ];
  for (let i = 0; i < 80; i += 1) {
    vehicles.push({ plate: generatedPlate(i), model: MODELS[i % MODELS.length] ?? null, ownerCitizenid: persons[6 + ((i * 3) % 200)]?.citizenid ?? null });
  }

  const cases: MockCase[] = [
    {
      id: 1042, caseNumber: 'K-1042-26', title: 'Grovt rån mot värdetransport, Legion Square', status: 'open', level: 0,
      visibility: 'full', maskedTitle: true, contact: { displayName: 'Lina Ek', unit: 'utredning' },
      persons: [{ citizenid: 'FPD00001', role: 'suspect' }, { citizenid: 'FPD00004', role: 'witness' }], vehicles: ['ABC12D'], mine: true,
    },
    {
      id: 988, caseNumber: 'K-988-26', title: 'Narkotikabrott, Sandy Shores', status: 'closed', level: 1,
      visibility: 'masked', maskedTitle: false, contact: { displayName: 'Bo Carlsson', unit: 'span' },
      persons: [{ citizenid: 'FPD00001', role: 'suspect' }], vehicles: [], mine: false,
    },
    {
      id: 1077, caseNumber: 'K-1077-26', title: 'Olaga vapeninnehav (spaning)', status: 'open', level: 2,
      visibility: 'notice', maskedTitle: false, contact: { displayName: 'Bo Carlsson', unit: 'span' },
      persons: [{ citizenid: 'FPD00001', role: 'suspect' }], vehicles: ['XYZ98A'], mine: false,
    },
    {
      id: 1101, caseNumber: 'K-1101-26', title: 'Misshandel, Vespucci Beach', status: 'open', level: 0,
      visibility: 'full', maskedTitle: true, contact: { displayName: meRef.displayName, unit: me.unit },
      persons: [{ citizenid: 'FPD00002', role: 'victim' }], vehicles: [], mine: true,
    },
    {
      id: 1120, caseNumber: 'K-1120-26', title: 'Stöld av fordon, Rockford Hills', status: 'closed', level: 0,
      visibility: 'masked', maskedTitle: true, contact: { displayName: 'Karl Lund', unit: 'igv' },
      persons: [{ citizenid: 'FPD00003', role: 'witness' }], vehicles: ['KLM34F'], mine: false,
    },
    {
      id: 1133, caseNumber: 'K-1133-26', title: 'Skadegörelse, Pillbox Hill', status: 'open', level: 0,
      visibility: 'notice', maskedTitle: false, contact: { displayName: null, unit: 'igv' },
      persons: [{ citizenid: 'FPD00003', role: 'other' }], vehicles: [], mine: false,
    },
  ];

  const records: MockRecord[] = [
    { id: 501, citizenid: 'FPD00001', chargeCode: 'BrB 8:1', title: 'Stöld', fine: 3000, jailMinutes: 0, createdAt: at(-24 * 40), caseId: 988 },
    { id: 502, citizenid: 'FPD00001', chargeCode: 'TrafikF 3:17', title: 'Hastighetsöverträdelse 31–40 km/h', fine: 2400, jailMinutes: 0, createdAt: at(-24 * 12), caseId: null },
    { id: 503, citizenid: 'FPD00001', chargeCode: 'BrB 3:5', title: 'Misshandel', fine: 0, jailMinutes: 20, createdAt: at(-24 * 3), caseId: 1077 },
    { id: 504, citizenid: 'FPD00002', chargeCode: 'OrdL 2:1', title: 'Förargelseväckande beteende', fine: 1500, jailMinutes: 0, createdAt: at(-24 * 60), caseId: null },
  ];

  const bolo = (b: Partial<Bolo> & Pick<Bolo, 'id' | 'kind' | 'subject' | 'reason'>): Bolo => ({
    citizenid: null, plate: null, level: 0, issuedBy: null, createdAt: at(-1), expiresAt: null, active: true,
    resolvedBy: null, resolvedAt: null, resolveNote: null, ...b,
  });
  const bolos: Bolo[] = [
    bolo({ id: 1, kind: 'person', citizenid: 'FPD00001', subject: 'Erik Nilsson', reason: 'Misstänkt för grovt rån mot värdetransport. Kan vara beväpnad, iaktta försiktighet.', issuedBy: lina, createdAt: at(-3), expiresAt: at(69) }),
    bolo({ id: 2, kind: 'vehicle', plate: 'ABC12D', subject: 'ABC12D · sultan', reason: 'Använd vid rånet på Legion Square. Svart Sultan med skadad bakruta.', issuedBy: karl, createdAt: at(-2) }),
    bolo({ id: 3, kind: 'vehicle', plate: 'XYZ98A', subject: 'XYZ98A · sentinel', reason: 'Spaningsobjekt. Rapportera iakttagelser till SPAN-02, ingrip inte.', level: 1, issuedBy: bo, createdAt: at(-26), expiresAt: at(22) }),
    bolo({ id: 4, kind: 'person', citizenid: 'FPD00006', subject: 'Karin Andersson', reason: 'Försvunnen sedan i går kväll, senast sedd vid Vinewood Bowl.', issuedBy: helena, createdAt: at(-30), active: false, resolvedBy: meRef, resolvedAt: at(-5), resolveNote: 'Påträffad oskadd i Vinewood Hills.' }),
    bolo({ id: 5, kind: 'vehicle', plate: 'KLM34F', subject: 'KLM34F · buffalo', reason: 'Smitning från trafikolycka på Great Ocean Highway.', issuedBy: karl, createdAt: at(-80), expiresAt: at(-8), active: false }),
  ];

  const checks: MockCheck[] = [
    { plate: 'ABC12D', checkedAt: at(-0.5), officer: karl, hit: true },
    { plate: 'ABC12D', checkedAt: at(-2.5), officer: meRef, hit: false },
    { plate: 'ABC12D', checkedAt: at(-6), officer: null, hit: false },
    { plate: 'KLM34F', checkedAt: at(-20), officer: bo, hit: true },
  ];

  const personName = (cid: string) => {
    const p = persons.find((x) => x.citizenid === cid);
    return p ? `${p.firstname} ${p.lastname}` : cid;
  };
  const tablets: MockTablet[] = [
    { serial: 'PT-00012', owner: { citizenid: me.citizenid, name: me.displayName }, revoked: false, issuedBy: helena, issuedAt: at(-24 * 30) },
    { serial: 'PT-00013', owner: { citizenid: 'OFF00002', name: 'Bo Carlsson' }, revoked: false, issuedBy: helena, issuedAt: at(-24 * 29) },
    { serial: 'PT-00014', owner: { citizenid: 'OFF00003', name: 'Lina Ek' }, revoked: false, issuedBy: helena, issuedAt: at(-24 * 20) },
    { serial: 'PT-00015', owner: { citizenid: 'FPD00001', name: personName('FPD00001') }, revoked: true, issuedBy: karl, issuedAt: at(-24 * 12) },
    { serial: 'PT-00016', owner: { citizenid: 'OFF00005', name: 'Karl Lund' }, revoked: false, issuedBy: null, issuedAt: at(-24 * 8) },
    { serial: 'PT-00017', owner: null, revoked: false, issuedBy: helena, issuedAt: at(-24 * 2) },
  ];

  return {
    now,
    me,
    tier: options.tier,
    unit: options.unit,
    persons,
    vehicles,
    cases,
    records,
    bolos,
    checks,
    tablets,
    officers,
    nextBoloId: 6,
  };
}
