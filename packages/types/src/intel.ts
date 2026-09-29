// SPDX-License-Identifier: GPL-3.0-only
// Intelligence contract, Phase 5b (docs/contracts.md §C15): sources (källor), intel reports, entities, links,
// missions (insatser) and the capped graph. Everything is canView-shaped server-side (fredpd_intel); 'none' never
// reaches the client (not_found — portal intel routes answer 404, never 403, §5.9).
import { z } from 'zod';
import { CitizenIdSchema } from './actions';
import { IsoUtcSchema, LevelSchema, OfficerRefSchema, PageSchema } from './mdt';

export const ReliabilitySchema = z.enum(['A', 'B', 'C', 'D']);
export const EntityTypeSchema = z.enum(['person', 'vehicle', 'location', 'group', 'case']);
export const GRAPH_NODE_CAP = 150;

const Notice = z.object({
  visibility: z.literal('notice'),
  contact: z.object({ displayName: z.string().nullable(), unit: z.string().nullable() }),
});

// Sources ------------------------------------------------------------------------------------------------------

export const SourceSchema = z.discriminatedUnion('visibility', [
  z.object({
    visibility: z.literal('full'),
    id: z.number().int(),
    codename: z.string(),
    reliability: ReliabilitySchema,
    status: z.enum(['open', 'closed']),
    level: LevelSchema,
    unit: z.string().nullable(),
    notes: z.string().nullable(),
    handler: OfficerRefSchema.nullable(),
    /** Only for the handler holding perm intel.handler, or perm intel.command (§5.8). Every read is audited. */
    realIdentity: z.object({ citizenid: CitizenIdSchema, name: z.string() }).nullable(),
  }),
  /** intel.read without handler rights: codename and reliability, nothing that identifies the person or handler. */
  z.object({
    visibility: z.literal('masked'),
    id: z.number().int(),
    codename: z.string(),
    reliability: ReliabilitySchema,
    status: z.enum(['open', 'closed']),
    level: LevelSchema,
  }),
  Notice,
]);
export type Source = z.infer<typeof SourceSchema>;

export const SourceCreateInputSchema = z.object({
  codename: z.string().trim().min(2).max(64),
  reliability: ReliabilitySchema.default('C'),
  notes: z.string().trim().max(5000).optional(),
  realCitizenid: CitizenIdSchema.optional(),
  level: LevelSchema.default(2),
});
export const SourceUpdateInputSchema = z.object({
  id: z.number().int().positive(),
  reliability: ReliabilitySchema.optional(),
  status: z.enum(['open', 'closed']).optional(),
  notes: z.string().trim().max(5000).nullable().optional(),
});

// Entities, links, graph -----------------------------------------------------------------------------------------

export const EntitySchema = z.object({
  id: z.number().int(),
  type: EntityTypeSchema,
  /** citizenid / plate / case number / free text; null for groups and locations without a key. */
  ref: z.string().nullable(),
  label: z.string(),
});
export type Entity = z.infer<typeof EntitySchema>;

export const LinkSchema = z.object({
  id: z.number().int(),
  from: EntitySchema,
  to: EntitySchema,
  type: z.string(),
  confidence: z.number().int().min(0).max(100),
  level: LevelSchema,
  reportId: z.number().int().nullable(),
  createdBy: OfficerRefSchema.nullable(),
  createdAt: IsoUtcSchema,
});

export const EnsureEntityInputSchema = z.object({
  type: EntityTypeSchema,
  ref: z.string().trim().max(64).optional(),
  label: z.string().trim().min(1).max(128),
});
/** The 3-click flow: pick "from" (current entity), pick/create "to", choose type → addLink. */
export const AddLinkInputSchema = z.object({
  fromId: z.number().int().positive(),
  to: z.union([z.object({ id: z.number().int().positive() }), EnsureEntityInputSchema]),
  type: z.string().trim().min(2).max(32),
  confidence: z.number().int().min(0).max(100).default(50),
  reportId: z.number().int().positive().optional(),
  level: LevelSchema.default(1),
});

export const EntityDetailSchema = z.object({
  entity: EntitySchema,
  /** List-first view: visible links, newest first; hidden ones are counted, never described. */
  links: z.array(LinkSchema),
  hiddenLinks: z.number().int().nonnegative(),
  reports: z.array(z.object({ id: z.number().int(), level: LevelSchema, createdAt: IsoUtcSchema, author: OfficerRefSchema.nullable() })),
  /** Missions touching this entity that the viewer only gets a kontaktnotis for. */
  notices: z.array(Notice),
});

export const GraphInputSchema = z.object({ entityId: z.number().int().positive(), depth: z.union([z.literal(1), z.literal(2)]).default(1) });
export const GraphSchema = z.object({
  nodes: z.array(EntitySchema.extend({ root: z.boolean() })).max(GRAPH_NODE_CAP),
  edges: z.array(z.object({ id: z.number().int(), from: z.number().int(), to: z.number().int(), type: z.string(), confidence: z.number().int() })),
  /** True when the cap cut nodes; the UI offers "expand" per node instead of loading more at once. */
  truncated: z.boolean(),
});
export type Graph = z.infer<typeof GraphSchema>;

// Intel reports and missions ---------------------------------------------------------------------------------------

export const IntelReportSchema = z.discriminatedUnion('visibility', [
  z.object({
    visibility: z.literal('full'),
    id: z.number().int(),
    source: z.object({ id: z.number().int(), codename: z.string() }).nullable(),
    mission: z.object({ id: z.number().int(), title: z.string() }).nullable(),
    author: OfficerRefSchema.nullable(),
    body: z.string(),
    reliability: ReliabilitySchema.nullable(),
    level: LevelSchema,
    status: z.enum(['open', 'closed']),
    createdAt: IsoUtcSchema,
    links: z.array(LinkSchema),
  }),
  Notice,
]);
export const IntelReportCreateInputSchema = z.object({
  sourceId: z.number().int().positive().optional(),
  missionId: z.number().int().positive().optional(),
  body: z.string().trim().min(3).max(50_000),
  reliability: ReliabilitySchema.optional(),
  level: LevelSchema.default(1),
});
export const IntelReportListInputSchema = z.object({
  sourceId: z.number().int().positive().optional(),
  missionId: z.number().int().positive().optional(),
  page: PageSchema,
});

export const MissionSchema = z.discriminatedUnion('visibility', [
  z.object({
    visibility: z.literal('full'),
    id: z.number().int(),
    title: z.string(),
    description: z.string().nullable(),
    unit: z.string().nullable(),
    status: z.enum(['open', 'closed']),
    level: LevelSchema,
    lead: OfficerRefSchema.nullable(),
    members: z.array(OfficerRefSchema.extend({ role: z.string().nullable() })),
    reports: z.array(z.object({ id: z.number().int(), level: LevelSchema, createdAt: IsoUtcSchema })),
  }),
  Notice,
]);
export const MissionCreateInputSchema = z.object({
  title: z.string().trim().min(3).max(160),
  description: z.string().trim().max(20_000).optional(),
  level: LevelSchema.default(2),
  unit: z.string().max(32).optional(),
});
export const MissionMemberInputSchema = z.object({
  id: z.number().int().positive(),
  citizenid: CitizenIdSchema,
  role: z.string().trim().max(32).optional(),
});

const Id = z.object({ id: z.number().int().positive() });
const ListOut = <T extends z.ZodTypeAny>(item: T) => z.object({ items: z.array(item), total: z.number().int().nonnegative(), page: z.number().int() });

export const INTEL_ACTIONS = {
  listSources: { input: z.object({ page: PageSchema }), output: ListOut(SourceSchema), grant: ['perm', 'intel.read'] },
  getSource: { input: Id, output: SourceSchema, grant: ['perm', 'intel.read'] },
  createSource: { input: SourceCreateInputSchema, output: SourceSchema, grant: ['perm', 'intel.handler'] },
  updateSource: { input: SourceUpdateInputSchema, output: SourceSchema, grant: ['perm', 'intel.handler'] },
  listIntelReports: { input: IntelReportListInputSchema, output: ListOut(IntelReportSchema), grant: ['perm', 'intel.read'] },
  getIntelReport: { input: Id, output: IntelReportSchema, grant: ['perm', 'intel.read'] },
  createIntelReport: { input: IntelReportCreateInputSchema, output: IntelReportSchema, grant: ['perm', 'intel.read'] },
  searchEntities: {
    input: z.object({ query: z.string().trim().min(2).max(64), type: EntityTypeSchema.optional() }),
    output: z.object({ items: z.array(EntitySchema) }),
    grant: ['mdt_page', 'intel'],
  },
  ensureEntity: { input: EnsureEntityInputSchema, output: EntitySchema, grant: ['perm', 'intel.read'] },
  getEntity: { input: Id, output: EntityDetailSchema, grant: ['mdt_page', 'intel'] },
  addLink: { input: AddLinkInputSchema, output: LinkSchema, grant: ['perm', 'intel.read'] },
  getGraph: { input: GraphInputSchema, output: GraphSchema, grant: ['perm', 'intel.read'] },
  listMissions: { input: z.object({ page: PageSchema }), output: ListOut(MissionSchema), grant: ['mdt_page', 'intel'] },
  getMission: { input: Id, output: MissionSchema, grant: ['mdt_page', 'intel'] },
  createMission: { input: MissionCreateInputSchema, output: MissionSchema, grant: ['perm', 'intel.command'] },
  addMissionMember: { input: MissionMemberInputSchema, output: MissionSchema, grant: ['perm', 'intel.read'] },
  closeMission: { input: Id, output: MissionSchema, grant: ['perm', 'intel.read'] },
} as const;
export type IntelActionName = keyof typeof INTEL_ACTIONS;
