// SPDX-License-Identifier: GPL-3.0-only
// NUI ⇄ Lua action contract for the tablet, Phase 2 (docs/contracts.md §C12). The NUI calls
// fetchNui(action, input); fredpd_mdt's client forwards it to the server callback `fredpd:mdt:action`
// ({ action, input }); the server validates input with the Lua mirror of these shapes, checks the action's grant,
// rate-limits, and returns the output shape (or MdtError). Every shape here is the wire JSON on both hops.
import { z } from 'zod';
import { CitizenIdSchema } from './actions';

// ---------------------------------------------------------------------------------------------------------------
// Shared pieces
// ---------------------------------------------------------------------------------------------------------------

export const LevelSchema = z.union([z.literal(0), z.literal(1), z.literal(2)]);
export type Level = z.infer<typeof LevelSchema>;

/** Plate as stored by qbx (uppercase, no inner space normalisation beyond trim), 1–16 chars. */
export const PlateSchema = z.string().trim().min(1).max(16);
export const PageSchema = z.number().int().min(1).max(10_000).default(1);
export const PAGE_SIZE = 50;

/** ISO-8601 UTC timestamp string as produced by the server (`YYYY-MM-DDTHH:mm:ssZ`). */
export const IsoUtcSchema = z.string().regex(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/);

/** Officer as shown on the tablet: Discord display name + callsign (§4.9), never the character name. */
export const OfficerRefSchema = z.object({
  citizenid: CitizenIdSchema,
  displayName: z.string(),
  callsign: z.string().nullable(),
  unit: z.string().nullable(),
});
export type OfficerRef = z.infer<typeof OfficerRefSchema>;

export const MDT_ERROR_CODES = [
  'unauthorized', // no grant / not on duty / tablet revoked
  'not_found',
  'validation',
  'rate_limited',
  'unavailable', // DB or dependency failure
] as const;
export const MdtErrorSchema = z.object({ error: z.enum(MDT_ERROR_CODES) });
export type MdtError = z.infer<typeof MdtErrorSchema>;

// ---------------------------------------------------------------------------------------------------------------
// Visibility-shaped case references (canView applied server-side; §C3)
// ---------------------------------------------------------------------------------------------------------------

export const CaseRefSchema = z.discriminatedUnion('visibility', [
  z.object({
    visibility: z.literal('full'),
    id: z.number().int(),
    caseNumber: z.string(),
    title: z.string(),
    status: z.enum(['open', 'closed']),
    level: LevelSchema,
    role: z.enum(['suspect', 'victim', 'witness', 'vehicle', 'other']).nullable(),
  }),
  z.object({
    visibility: z.literal('masked'),
    id: z.number().int(),
    caseNumber: z.string(),
    /** Title only when the case's own level ≤ viewer tier; else null. */
    title: z.string().nullable(),
    status: z.enum(['open', 'closed']),
    level: LevelSchema,
    role: z.enum(['suspect', 'victim', 'witness', 'vehicle', 'other']).nullable(),
  }),
  /** Kontaktnotis: existence + whom to contact. No id, number, title or level. */
  z.object({
    visibility: z.literal('notice'),
    contact: z.object({ displayName: z.string().nullable(), unit: z.string().nullable() }),
  }),
]);
export type CaseRef = z.infer<typeof CaseRefSchema>;

// ---------------------------------------------------------------------------------------------------------------
// BOLO (efterlysning)
// ---------------------------------------------------------------------------------------------------------------

export const BoloKindSchema = z.enum(['person', 'vehicle']);
export const BoloSchema = z.object({
  id: z.number().int(),
  kind: BoloKindSchema,
  citizenid: CitizenIdSchema.nullable(),
  plate: z.string().nullable(),
  /** Subject label: person name or plate + model. */
  subject: z.string(),
  reason: z.string(),
  level: LevelSchema,
  issuedBy: OfficerRefSchema.nullable(),
  createdAt: IsoUtcSchema,
  expiresAt: IsoUtcSchema.nullable(),
  active: z.boolean(),
  resolvedBy: OfficerRefSchema.nullable(),
  resolvedAt: IsoUtcSchema.nullable(),
  resolveNote: z.string().nullable(),
});
export type Bolo = z.infer<typeof BoloSchema>;

export const BoloCreateInputSchema = z
  .object({
    kind: BoloKindSchema,
    citizenid: CitizenIdSchema.optional(),
    plate: PlateSchema.optional(),
    reason: z.string().trim().min(3).max(500),
    level: LevelSchema.default(0),
    /** Hours until expiry, 1–720 (30 days); omitted = no expiry. */
    expiresInHours: z.number().int().min(1).max(720).optional(),
  })
  .refine((v) => (v.kind === 'person' ? !!v.citizenid && !v.plate : !!v.plate && !v.citizenid), {
    message: 'person BOLO needs citizenid only, vehicle BOLO needs plate only',
  });
export type BoloCreateInput = z.infer<typeof BoloCreateInputSchema>;

export const BoloResolveInputSchema = z.object({ id: z.number().int().positive(), note: z.string().trim().max(500).default('') });
export const BoloListInputSchema = z.object({ active: z.boolean().default(true), page: PageSchema });
export const BoloListOutputSchema = z.object({ items: z.array(BoloSchema), total: z.number().int().nonnegative(), page: z.number().int() });

/** Result of "Kontrollera registreringsskylt" (ox_target) and of the NUI plate check. */
export const PlateCheckResultSchema = z.object({
  plate: z.string(),
  model: z.string().nullable(),
  owner: z.object({ citizenid: CitizenIdSchema, name: z.string() }).nullable(),
  bolo: BoloSchema.nullable(),
  checkedAt: IsoUtcSchema,
});
export type PlateCheckResult = z.infer<typeof PlateCheckResultSchema>;

// ---------------------------------------------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------------------------------------------

export const SearchInputSchema = z.object({
  query: z.string().trim().min(2).max(64),
  /** 'auto' runs detectSearchType (§C4) server-side. */
  type: z.enum(['auto', 'person', 'vehicle', 'case']).default('auto'),
  page: PageSchema,
});
export type SearchInput = z.infer<typeof SearchInputSchema>;

export const SearchHitSchema = z.discriminatedUnion('kind', [
  z.object({
    kind: z.literal('person'),
    citizenid: CitizenIdSchema,
    name: z.string(),
    birthdate: z.string().nullable(), // YYYY-MM-DD
    personnummer: z.string().nullable(),
    bolo: z.boolean(),
  }),
  z.object({
    kind: z.literal('vehicle'),
    plate: z.string(),
    model: z.string().nullable(),
    ownerName: z.string().nullable(),
    ownerCitizenid: CitizenIdSchema.nullable(),
    bolo: z.boolean(),
  }),
  z.object({ kind: z.literal('case'), case: CaseRefSchema }),
]);
export type SearchHit = z.infer<typeof SearchHitSchema>;

export const SearchOutputSchema = z.object({
  detected: z.enum(['plate', 'caseNumber', 'personId', 'name']),
  normalized: z.string(),
  hits: z.array(SearchHitSchema),
  total: z.number().int().nonnegative(),
  page: z.number().int(),
});
export type SearchOutput = z.infer<typeof SearchOutputSchema>;

// ---------------------------------------------------------------------------------------------------------------
// Person / vehicle pages
// ---------------------------------------------------------------------------------------------------------------

export const PersonSchema = z.object({
  citizenid: CitizenIdSchema,
  firstname: z.string(),
  lastname: z.string(),
  birthdate: z.string().nullable(),
  personnummer: z.string().nullable(),
  gender: z.enum(['male', 'female', 'unknown']),
  phone: z.string().nullable(),
});
export type Person = z.infer<typeof PersonSchema>;

/** Applied charge on a person (fredpd_records row), Standard level only on Phase 2. */
export const RecordRowSchema = z.object({
  id: z.number().int(),
  chargeCode: z.string(),
  title: z.string(),
  fine: z.number().int().nonnegative(),
  jailMinutes: z.number().int().nonnegative(),
  createdAt: IsoUtcSchema,
  caseNumber: z.string().nullable(),
});

export const VehicleShortSchema = z.object({ plate: z.string(), model: z.string().nullable(), bolo: z.boolean() });

export const PersonSummarySchema = z.object({
  person: PersonSchema,
  vehicles: z.array(VehicleShortSchema),
  bolos: z.array(BoloSchema),
  cases: z.array(CaseRefSchema),
  records: z.array(RecordRowSchema),
  /** Address from the housing adapter (§9), null when none/unknown. */
  address: z.string().nullable(),
});
export type PersonSummary = z.infer<typeof PersonSummarySchema>;

export const VehicleSummarySchema = z.object({
  vehicle: z.object({ plate: z.string(), model: z.string().nullable() }),
  owner: z.object({ citizenid: CitizenIdSchema, name: z.string() }).nullable(),
  bolos: z.array(BoloSchema),
  cases: z.array(CaseRefSchema),
  /** Last 20 plate checks, newest first. */
  checks: z.array(z.object({ checkedAt: IsoUtcSchema, officer: OfficerRefSchema.nullable(), hit: z.boolean() })),
});
export type VehicleSummary = z.infer<typeof VehicleSummarySchema>;

// ---------------------------------------------------------------------------------------------------------------
// Home (unit-tailored, one callback; task 2.7)
// ---------------------------------------------------------------------------------------------------------------

export const HomeOutputSchema = z.object({
  me: OfficerRefSchema,
  variant: z.enum(['igv', 'span', 'utredning', 'tekniker', 'ledning']),
  counts: z.object({ activeBolos: z.number().int(), myOpenCases: z.number().int(), onDuty: z.number().int() }),
  recentBolos: z.array(BoloSchema).max(10),
  myCases: z.array(CaseRefSchema).max(10),
  /** Ledning only: officers on duty (else empty). */
  roster: z.array(OfficerRefSchema.extend({ onDuty: z.boolean() })),
});
export type HomeOutput = z.infer<typeof HomeOutputSchema>;

// ---------------------------------------------------------------------------------------------------------------
// Tablets (Ledning page "Surfplattor"; task 2.1)
// ---------------------------------------------------------------------------------------------------------------

export const TabletSchema = z.object({
  serial: z.string(),
  owner: z.object({ citizenid: CitizenIdSchema, name: z.string() }).nullable(),
  revoked: z.boolean(),
  issuedBy: OfficerRefSchema.nullable(),
  issuedAt: IsoUtcSchema,
});
export const TabletListOutputSchema = z.object({ items: z.array(TabletSchema), total: z.number().int(), page: z.number().int() });
export const TabletRevokeInputSchema = z.object({ serial: z.string().min(1).max(32), revoked: z.boolean() });
export const TabletIssueInputSchema = z.object({ targetServerId: z.number().int().positive() });

// ---------------------------------------------------------------------------------------------------------------
// Action registry: name → input/output schema + grant required (checked server-side; client copy only for UI).
// ---------------------------------------------------------------------------------------------------------------

const Empty = z.object({}).strict();

export const MDT_ACTIONS = {
  close: { input: Empty, output: z.object({ ok: z.literal(true) }), grant: null },
  getHome: { input: Empty, output: HomeOutputSchema, grant: null },
  search: { input: SearchInputSchema, output: SearchOutputSchema, grant: ['mdt_page', 'search'] },
  getPerson: { input: z.object({ citizenid: CitizenIdSchema }), output: PersonSummarySchema, grant: ['mdt_page', 'search'] },
  getVehicle: { input: z.object({ plate: PlateSchema }), output: VehicleSummarySchema, grant: ['mdt_page', 'search'] },
  checkPlate: { input: z.object({ plate: PlateSchema }), output: PlateCheckResultSchema, grant: ['mdt_page', 'search'] },
  listBolos: { input: BoloListInputSchema, output: BoloListOutputSchema, grant: ['mdt_page', 'bolos'] },
  createBolo: { input: BoloCreateInputSchema, output: BoloSchema, grant: ['perm', 'bolo.create'] },
  resolveBolo: { input: BoloResolveInputSchema, output: BoloSchema, grant: ['perm', 'bolo.resolve'] },
  listTablets: { input: z.object({ page: PageSchema }), output: TabletListOutputSchema, grant: ['perm', 'tablets.manage'] },
  setTabletRevoked: { input: TabletRevokeInputSchema, output: TabletSchema, grant: ['perm', 'tablets.manage'] },
} as const;

export type MdtActionName = keyof typeof MDT_ACTIONS;
export type MdtInput<A extends MdtActionName> = z.input<(typeof MDT_ACTIONS)[A]['input']>;
export type MdtOutput<A extends MdtActionName> = z.infer<(typeof MDT_ACTIONS)[A]['output']>;

/** Server → tablet push topics (`fredpd:client:push` → NUI `{ action: 'push', topic, payload }`). */
export const PUSH_TOPICS = ['alerts', 'units', 'bolo', 'case', 'grants', 'ledning'] as const;
export type PushTopic = (typeof PUSH_TOPICS)[number];
