// SPDX-License-Identifier: GPL-3.0-only
// Proposed wire shapes for the fredpd_records Phase 5 additions that packages/types does not define yet (POI sheet,
// share links, release requests; docs/modules/records.md "Integration requests"). Once packages/types/src/records.ts
// carries them, contract.test.ts should import those instead and this file goes away.
// zod is not a dependency of resources/ (not a workspace package); it is taken from packages/types.
import { z } from '../../../../packages/types/node_modules/zod/index.js';
import { CitizenIdSchema } from '../../../../packages/types/src/actions';
import { IsoUtcSchema, LevelSchema, OfficerRefSchema } from '../../../../packages/types/src/mdt';

export const PoiWarningSchema = z.enum(['armed', 'violent', 'flight_risk', 'gang']);

const PoiContentSchema = z.object({
  id: z.number().int(),
  level: LevelSchema,
  status: z.enum(['open', 'closed']),
  unit: z.string().nullable(),
  owner: OfficerRefSchema.nullable(),
  summary: z.string().nullable(),
  warnings: z.array(PoiWarningSchema),
  photoUrl: z.string().nullable(),
  updatedAt: IsoUtcSchema,
  updatedBy: OfficerRefSchema.nullable(),
  editable: z.boolean(),
});

export const PoiSheetSchema = z.discriminatedUnion('visibility', [
  PoiContentSchema.extend({ visibility: z.literal('full') }),
  PoiContentSchema.extend({ visibility: z.literal('masked') }),
  z.object({
    visibility: z.literal('notice'),
    contact: z.object({ displayName: z.string().nullable(), unit: z.string().nullable() }),
  }),
]);

export const PoiViewSchema = z.object({ citizenid: CitizenIdSchema, name: z.string(), poi: PoiSheetSchema.nullable() });
export const PoiUpdateInputSchema = z.object({
  citizenid: CitizenIdSchema,
  summary: z.string().trim().max(20_000).optional(),
  warnings: z.array(PoiWarningSchema).max(8).optional(),
  level: LevelSchema.optional(),
  status: z.enum(['open', 'closed']).optional(),
  photoUrl: z.string().max(255).optional(),
});

export const ShareCreateInputSchema = z.object({
  targetType: z.enum(['poi', 'case', 'report']),
  /** citizenid for 'poi', numeric id otherwise */
  targetId: z.union([z.number().int().positive(), CitizenIdSchema]),
  expiresInHours: z.number().int().min(1).max(168),
});
export const ShareCreatedSchema = z.object({
  id: z.number().int(),
  token: z.string().regex(/^[A-Za-z0-9_-]{43}$/),
  path: z.string(),
  expiresAt: IsoUtcSchema,
  maxLevel: LevelSchema,
});

const ReleasedReportSchema = z.object({ reportNumber: z.string(), title: z.string(), body: z.string(), createdAt: IsoUtcSchema });
export const ReleasedContentSchema = z.discriminatedUnion('type', [
  z.object({
    type: z.literal('case'),
    caseNumber: z.string(),
    status: z.enum(['open', 'closed']),
    title: z.string(),
    summary: z.string().nullable(),
    createdAt: IsoUtcSchema,
    closedAt: IsoUtcSchema.nullable(),
    reports: z.array(ReleasedReportSchema),
  }),
  z.object({
    type: z.literal('report'),
    caseNumber: z.string(),
    reportNumber: z.string(),
    title: z.string(),
    body: z.string(),
    createdAt: IsoUtcSchema,
  }),
]);

export const ReleaseRequestSchema = z.object({
  id: z.number().int(),
  status: z.enum(['pending', 'approved', 'partial', 'denied']),
  channel: z.string().nullable(),
  requesterName: z.string().nullable(),
  requesterCitizenid: CitizenIdSchema.nullable(),
  description: z.string(),
  target: z.object({ type: z.string(), id: z.string(), label: z.string().nullable() }).nullable(),
  createdAt: IsoUtcSchema,
  decidedAt: IsoUtcSchema.nullable(),
  decidedBy: OfficerRefSchema.nullable(),
  decisionNote: z.string().nullable(),
  released: ReleasedContentSchema.nullable(),
});
export const ReleaseDecideInputSchema = z.object({
  id: z.number().int().positive(),
  decision: z.enum(['approved', 'partial', 'denied']),
  note: z.string().trim().max(2000).optional(),
  targetType: z.enum(['case', 'report']).optional(),
  targetId: z.number().int().positive().optional(),
});
