// SPDX-License-Identifier: GPL-3.0-only
// Evidence (Phase 4, fredpd_forensics over noobsystems/evidences) and breach (Phase 6, fredpd_breach) contract —
// docs/contracts.md §C16. Evidence rows are shaped by canView with record type 'evidence' (level + linked case).
import { z } from 'zod';
import { IsoUtcSchema, LevelSchema, OfficerRefSchema, PageSchema } from './mdt';

export const EvidenceTypeSchema = z.enum(['fingerprint', 'dna', 'blood', 'casing', 'projectile', 'toolmark', 'fiber', 'photo', 'other']);
export const CustodyActionSchema = z.enum(['collect', 'handin', 'analyse', 'link', 'checkout', 'return', 'transfer']);

export const CustodyEntrySchema = z.object({
  at: IsoUtcSchema,
  actor: OfficerRefSchema.nullable(),
  action: CustodyActionSchema,
  /** Stash id / zone label, e.g. 'evidence_locker_mrpd'. */
  location: z.string().nullable(),
  note: z.string().nullable(),
});
export type CustodyEntry = z.infer<typeof CustodyEntrySchema>;

export const EvidenceItemSchema = z.object({
  id: z.number().int(),
  tag: z.string().nullable(), // B-K-123-26-004 once linked
  type: EvidenceTypeSchema,
  caseId: z.number().int().nullable(),
  caseNumber: z.string().nullable(),
  level: LevelSchema,
  /**
   * Analysis result as reported by evidences (e.g. { fingerprint: 'FP-…', match: { citizenid, name } | null }).
   * A match on a person is only included when the viewer's canView on the linked case is 'full'.
   */
  result: z.record(z.string(), z.unknown()).nullable(),
  collectedBy: OfficerRefSchema.nullable(),
  collectedAt: IsoUtcSchema.nullable(),
  chain: z.array(CustodyEntrySchema),
});
export type EvidenceItem = z.infer<typeof EvidenceItemSchema>;

export const EvidenceListInputSchema = z.object({
  caseId: z.number().int().positive().optional(),
  /** Analysed items not yet linked to a case — the Tekniker work queue. */
  unlinked: z.boolean().default(false),
  page: PageSchema,
});
export const EvidenceLinkInputSchema = z.object({ id: z.number().int().positive(), caseId: z.number().int().positive() });

export const EVIDENCE_ACTIONS = {
  listEvidence: {
    input: EvidenceListInputSchema,
    output: z.object({ items: z.array(EvidenceItemSchema), total: z.number().int().nonnegative(), page: z.number().int() }),
    grant: ['mdt_page', 'evidence'],
  },
  getEvidence: { input: z.object({ id: z.number().int().positive() }), output: EvidenceItemSchema, grant: ['mdt_page', 'evidence'] },
  linkEvidence: { input: EvidenceLinkInputSchema, output: EvidenceItemSchema, grant: ['perm', 'evidence.link'] },
} as const;
export type EvidenceActionName = keyof typeof EVIDENCE_ACTIONS;

/** fredpd_breach scene evidence kinds (config/scene_evidence.lua keys) — called by robbery/heist scripts. */
export const SceneKindSchema = z.enum(['burglary', 'shooting', 'assault', 'robbery', 'vehicle_theft']);
export type SceneKind = z.infer<typeof SceneKindSchema>;
