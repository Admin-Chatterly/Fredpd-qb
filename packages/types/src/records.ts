// SPDX-License-Identifier: GPL-3.0-only
// Cases, reports and charges contract, Phase 5 (docs/contracts.md §C14). Tablet actions in RECORDS_ACTIONS are merged
// into the fredpd_mdt dispatcher and routed to fredpd_records exports ({ ok, data | error }, §C12). The portal calls
// the same actions over /api/mdt/:action with the same schemas.
import { z } from 'zod';
import { CitizenIdSchema } from './actions';
import { CaseRefSchema, IsoUtcSchema, LevelSchema, OfficerRefSchema, PageSchema, PlateSchema } from './mdt';

export const CaseStatusSchema = z.enum(['open', 'closed']);
export const SubjectRoleSchema = z.enum(['suspect', 'victim', 'witness', 'other']);
export const ChargeClassSchema = z.enum(['ordningsbot', 'bot', 'fängelse']);

// ---------------------------------------------------------------------------------------------------------------
// Case detail — shaped by canView (§C3). 'none' never reaches the client (not_found); 'notice' returns the notice.
// ---------------------------------------------------------------------------------------------------------------

export const CaseSubjectSchema = z.discriminatedUnion('type', [
  z.object({ type: z.literal('person'), citizenid: CitizenIdSchema, label: z.string(), role: SubjectRoleSchema }),
  z.object({ type: z.literal('vehicle'), plate: z.string(), label: z.string(), role: SubjectRoleSchema }),
]);
export type CaseSubject = z.infer<typeof CaseSubjectSchema>;

export const ReportRefSchema = z.object({
  id: z.number().int(),
  reportNumber: z.string(),
  /** null when the report's level is above the viewer's tier (masked case view). */
  title: z.string().nullable(),
  level: LevelSchema,
  author: OfficerRefSchema.nullable(),
  createdAt: IsoUtcSchema,
});

export const TimelineEntrySchema = z.object({
  at: IsoUtcSchema,
  actor: OfficerRefSchema.nullable(),
  /** audit action, e.g. case.create, case.assign, report.create, evidence.link, case.close */
  action: z.string(),
  /** Localised on the client from audit.action.<action>; detail is a short, already-safe label. */
  detail: z.string().nullable(),
});

const CaseDetailBase = z.object({
  id: z.number().int(),
  caseNumber: z.string(),
  status: CaseStatusSchema,
  level: LevelSchema,
  unit: z.string().nullable(),
  owner: OfficerRefSchema.nullable(),
  assignees: z.array(OfficerRefSchema.extend({ role: z.enum(['lead', 'member']) })),
  createdAt: IsoUtcSchema,
  closedAt: IsoUtcSchema.nullable(),
});

export const CaseDetailSchema = z.discriminatedUnion('visibility', [
  CaseDetailBase.extend({
    visibility: z.literal('full'),
    title: z.string(),
    summary: z.string().nullable(),
    subjects: z.array(CaseSubjectSchema),
    reports: z.array(ReportRefSchema),
    /** Phase 4 fills this (fredpd_forensics); empty until then. */
    evidence: z.array(z.object({ id: z.number().int(), tag: z.string(), type: z.string(), collectedAt: IsoUtcSchema.nullable() })),
    timeline: z.array(TimelineEntrySchema),
  }),
  /** Standard parts only: title/summary null when the case level > viewer tier; reports filtered per their level. */
  CaseDetailBase.extend({
    visibility: z.literal('masked'),
    title: z.string().nullable(),
    summary: z.string().nullable(),
    subjects: z.array(CaseSubjectSchema),
    reports: z.array(ReportRefSchema),
    evidence: z.array(z.object({ id: z.number().int(), tag: z.string(), type: z.string(), collectedAt: IsoUtcSchema.nullable() })),
    timeline: z.array(TimelineEntrySchema),
  }),
  z.object({
    visibility: z.literal('notice'),
    contact: z.object({ displayName: z.string().nullable(), unit: z.string().nullable() }),
  }),
]);
export type CaseDetail = z.infer<typeof CaseDetailSchema>;

export const CaseListInputSchema = z.object({
  filter: z.enum(['mine', 'unit', 'open', 'closed', 'all']).default('mine'),
  query: z.string().trim().max(64).optional(),
  page: PageSchema,
});
export const CaseListOutputSchema = z.object({ items: z.array(CaseRefSchema), total: z.number().int().nonnegative(), page: z.number().int() });

export const CaseCreateInputSchema = z.object({
  title: z.string().trim().min(3).max(160),
  summary: z.string().trim().max(20_000).optional(),
  level: LevelSchema.default(0),
  /** Owning unit; defaults to the creator's primary unit. Must be one of the creator's units unless records.admin. */
  unit: z.string().max(32).optional(),
});
export const CaseUpdateInputSchema = z.object({
  id: z.number().int().positive(),
  title: z.string().trim().min(3).max(160).optional(),
  summary: z.string().trim().max(20_000).nullable().optional(),
  /** Raising is allowed for owner/lead/records.admin; lowering only for records.admin. Never above the actor's tier. */
  level: LevelSchema.optional(),
});
export const CaseAssigneeInputSchema = z.object({
  id: z.number().int().positive(),
  citizenid: CitizenIdSchema,
  role: z.enum(['lead', 'member']).default('member'),
});
export const CaseUnassignInputSchema = z.object({ id: z.number().int().positive(), citizenid: CitizenIdSchema });
export const CaseSubjectInputSchema = z
  .object({
    id: z.number().int().positive(),
    type: z.enum(['person', 'vehicle']),
    citizenid: CitizenIdSchema.optional(),
    plate: PlateSchema.optional(),
    role: SubjectRoleSchema.default('other'),
  })
  .refine((v) => (v.type === 'person' ? !!v.citizenid && !v.plate : !!v.plate && !v.citizenid), {
    message: 'person subject needs citizenid only, vehicle subject needs plate only',
  });
export const CaseCloseInputSchema = z.object({ id: z.number().int().positive(), resolution: z.string().trim().min(3).max(2000) });

// ---------------------------------------------------------------------------------------------------------------
// Reports
// ---------------------------------------------------------------------------------------------------------------

export const AppliedChargeSchema = z.object({
  id: z.number().int(),
  citizenid: CitizenIdSchema,
  personName: z.string(),
  code: z.string(),
  title: z.string(),
  class: ChargeClassSchema,
  quantity: z.number().int().positive(),
  fine: z.number().int().nonnegative(),
  jailMinutes: z.number().int().nonnegative(),
  status: z.enum(['issued', 'paid', 'served', 'revoked']),
});

export const ReportDraftSchema = z.object({
  title: z.string().nullable(),
  body: z.string(),
  savedAt: IsoUtcSchema,
});
export type ReportDraft = z.infer<typeof ReportDraftSchema>;

export const ReportDetailSchema = z.object({
  id: z.number().int(),
  reportNumber: z.string(),
  caseId: z.number().int(),
  caseNumber: z.string(),
  title: z.string(),
  /** markdown-lite: **bold**, # heading, - list; rendered without HTML passthrough. */
  body: z.string(),
  level: LevelSchema,
  author: OfficerRefSchema.nullable(),
  createdAt: IsoUtcSchema,
  updatedAt: IsoUtcSchema,
  charges: z.array(AppliedChargeSchema),
  /** True when the viewer may edit (author, case owner/lead, records.admin) and the case is open. */
  editable: z.boolean(),
  /**
   * The viewer's own autosaved draft (fredpd_report_drafts; only ever the draft's author, only while `editable`),
   * else null. The editor offers "Återställ utkast" when `savedAt` is newer than `updatedAt`. `title` is null when the
   * autosave carried none. Lua sends a missing draft as an absent key (restored to null by the NUI's wire layer).
   */
  draft: ReportDraftSchema.nullable(),
});
export type ReportDetail = z.infer<typeof ReportDetailSchema>;

export const ReportCreateInputSchema = z.object({
  caseId: z.number().int().positive(),
  title: z.string().trim().min(3).max(160),
  templateId: z.number().int().positive().optional(),
  level: LevelSchema.default(0),
});
export const ReportSaveInputSchema = z.object({
  id: z.number().int().positive(),
  title: z.string().trim().min(3).max(160),
  body: z.string().max(100_000),
  level: LevelSchema,
});
/** Autosave (debounced while focused + dirty; §5.3) — goes to fredpd_report_drafts, never to the report itself. */
export const ReportDraftInputSchema = z.object({
  reportId: z.number().int().positive(),
  title: z.string().max(160).optional(),
  body: z.string().max(100_000),
});
export const ReportTemplateSchema = z.object({ id: z.number().int(), name: z.string(), unit: z.string().nullable(), body: z.string() });

// ---------------------------------------------------------------------------------------------------------------
// Charges (brottskatalog) and sanctions
// ---------------------------------------------------------------------------------------------------------------

export const ChargeSchema = z.object({
  code: z.string(),
  category: z.string(),
  title: z.string(),
  lawRef: z.string(),
  class: ChargeClassSchema,
  fine: z.number().int().nonnegative(),
  jailMinutes: z.number().int().nonnegative(),
});
export type Charge = z.infer<typeof ChargeSchema>;
export const ChargeListInputSchema = z.object({ query: z.string().trim().max(64).optional(), class: ChargeClassSchema.optional() });
export const ChargeListOutputSchema = z.object({ items: z.array(ChargeSchema) });

export const ChargeLineSchema = z.object({ code: z.string().min(1).max(16), quantity: z.number().int().min(1).max(20).default(1) });
export const ApplyChargesInputSchema = z.object({
  reportId: z.number().int().positive(),
  citizenid: CitizenIdSchema,
  lines: z.array(ChargeLineSchema).min(1).max(30),
  note: z.string().trim().max(255).optional(),
});
/** "Utfärda ordningsbot": only class 'ordningsbot' codes; writes records and bills via qbx_police (Phase 5, task 5.3). */
export const IssueFineInputSchema = z.object({
  citizenid: CitizenIdSchema,
  lines: z.array(ChargeLineSchema).min(1).max(10),
  caseId: z.number().int().positive().optional(),
});
export const ChargeTotalsSchema = z.object({ fine: z.number().int().nonnegative(), jailMinutes: z.number().int().nonnegative() });
export const ApplyChargesOutputSchema = z.object({ records: z.array(AppliedChargeSchema), totals: ChargeTotalsSchema });

const Id = z.object({ id: z.number().int().positive() });

/**
 * Phase 5 tablet actions (merged into the fredpd_mdt dispatcher). Grants are the coarse gate; fine rules (owner, lead,
 * assigned, records.admin, canView) are enforced inside fredpd_records.
 */
export const RECORDS_ACTIONS = {
  listCases: { input: CaseListInputSchema, output: CaseListOutputSchema, grant: ['mdt_page', 'cases'] },
  getCase: { input: Id, output: CaseDetailSchema, grant: ['mdt_page', 'cases'] },
  createCase: { input: CaseCreateInputSchema, output: CaseDetailSchema, grant: ['perm', 'cases.create'] },
  updateCase: { input: CaseUpdateInputSchema, output: CaseDetailSchema, grant: ['mdt_page', 'cases'] },
  assignCase: { input: CaseAssigneeInputSchema, output: CaseDetailSchema, grant: ['mdt_page', 'cases'] },
  unassignCase: { input: CaseUnassignInputSchema, output: CaseDetailSchema, grant: ['mdt_page', 'cases'] },
  addCaseSubject: { input: CaseSubjectInputSchema, output: CaseDetailSchema, grant: ['mdt_page', 'cases'] },
  closeCase: { input: CaseCloseInputSchema, output: CaseDetailSchema, grant: ['mdt_page', 'cases'] },
  getReport: { input: Id, output: ReportDetailSchema, grant: ['mdt_page', 'cases'] },
  createReport: { input: ReportCreateInputSchema, output: ReportDetailSchema, grant: ['mdt_page', 'cases'] },
  saveReport: { input: ReportSaveInputSchema, output: ReportDetailSchema, grant: ['mdt_page', 'cases'] },
  saveReportDraft: { input: ReportDraftInputSchema, output: z.object({ savedAt: IsoUtcSchema }), grant: ['mdt_page', 'cases'] },
  listReportTemplates: { input: z.object({}).strict(), output: z.object({ items: z.array(ReportTemplateSchema) }), grant: ['mdt_page', 'cases'] },
  listCharges: { input: ChargeListInputSchema, output: ChargeListOutputSchema, grant: null },
  applyCharges: { input: ApplyChargesInputSchema, output: ApplyChargesOutputSchema, grant: ['perm', 'charges.apply'] },
  issueFine: { input: IssueFineInputSchema, output: ApplyChargesOutputSchema, grant: ['perm', 'charges.fine'] },
} as const;
export type RecordsActionName = keyof typeof RECORDS_ACTIONS;
