// SPDX-License-Identifier: GPL-3.0-only
// Record visibility (docs/contracts.md §C3, IMPLEMENTATION.md §4.6). Ported 1:1 to
// resources/[fredpd]/fredpd_core/shared/canview.lua; both run
// packages/types/test/fixtures/canView.fixtures.json. Change the two together.
import { z } from 'zod';
import { GrantSetSchema, IntelTierSchema, hasGrant } from './grants';
import type { GrantLists, IntelTier } from './grants';

/** Ascending: none < notice (kontaktnotis) < masked < full. */
export const VISIBILITY_RESULTS = ['none', 'notice', 'masked', 'full'] as const;
export const VisibilityResultSchema = z.enum(VISIBILITY_RESULTS);
export type VisibilityResult = z.infer<typeof VisibilityResultSchema>;

export const VIS_RECORD_TYPES = [
  'case', 'report', 'evidence', 'poi', 'bolo', 'mission', 'intel_report', 'intel_source',
] as const;
export const VisRecordTypeSchema = z.enum(VIS_RECORD_TYPES);
export type VisRecordType = z.infer<typeof VisRecordTypeSchema>;

export const VIEWER_CONDITIONS = ['any', 'assigned', 'handler', 'unit', 'tier_gte', 'perm'] as const;
export const ViewerConditionSchema = z.enum(VIEWER_CONDITIONS);
export type ViewerCondition = z.infer<typeof ViewerConditionSchema>;

export const VisRecordSchema = z.object({
  type: VisRecordTypeSchema,
  id: z.union([z.string(), z.number()]),
  level: IntelTierSchema,
  status: z.enum(['open', 'closed']),
  unit: z.string().nullish(),
  assignees: z.array(z.string()).optional(),
  ownerCitizenid: z.string().nullish(),
  handlerCitizenid: z.string().nullish(),
});
export type VisRecord = z.infer<typeof VisRecordSchema>;

export const ViewerSchema = z.object({
  citizenid: z.string().nullable(),
  tier: IntelTierSchema,
  units: z.array(z.string()),
  grants: GrantSetSchema,
});
export type Viewer = z.infer<typeof ViewerSchema>;

/**
 * Row of fredpd_visibility_rules, camelCased. recordType is any string as in §C3 (record_type VARCHAR(32)):
 * '*' matches every type, a type canView does not know never matches (as in Lua), so one admin typo or a
 * future record type cannot make parsing the whole rules table throw.
 */
export const VisibilityRuleSchema = z.object({
  id: z.number().int(),
  recordType: z.string().min(1).max(32),
  level: IntelTierSchema.nullable(), // null = any level
  recordStatus: z.enum(['open', 'closed', 'any']),
  viewerCondition: ViewerConditionSchema,
  conditionValue: z.string().nullable(),
  result: VisibilityResultSchema,
  priority: z.number().int(),
  enabled: z.boolean(),
});
export type VisibilityRule = z.infer<typeof VisibilityRuleSchema>;

/** What canView reads from a viewer; grants only needs the grants/denied lists. */
export type ViewerLike = Pick<Viewer, 'citizenid' | 'tier' | 'units'> & { grants: GrantLists };

const RANK: Record<VisibilityResult, number> = { none: 0, notice: 1, masked: 2, full: 3 };

export function visibilityRank(result: VisibilityResult): number {
  return RANK[result];
}

/** The lower of `result` and `max` ("at most max"). */
export function capResult(result: VisibilityResult, max: VisibilityResult): VisibilityResult {
  return RANK[result] > RANK[max] ? max : result;
}

// canView is the portal's security gate and may be handed DB rows cast to VisRecord/VisibilityRule without
// parsing. The helpers below read every field the way the Lua port does, failing closed on values the
// schemas reject (canView.fixtures.json `unvalidatedCases` pins this for both ports).

/** A string, or null for anything else (NULL, missing, a number…). */
function str(value: unknown): string | null {
  return typeof value === 'string' ? value : null;
}

/** Record classification 0..2; anything else (null, missing, out of range, a string) counts as 2 (hemlig). */
function levelOf(record: VisRecord): IntelTier {
  const level: unknown = record.level;
  return level === 0 || level === 1 || level === 2 ? level : 2;
}

/** Viewer tier 0..2; anything else counts as 0. */
function tierOf(viewer: ViewerLike): IntelTier {
  const tier: unknown = viewer.tier;
  return tier === 0 || tier === 1 || tier === 2 ? tier : 0;
}

/** Array membership only: a string must not match by substring. */
function listHas(list: unknown, value: string): boolean {
  return Array.isArray(list) && list.includes(value);
}

/** `enabled` as boolean or as an unparsed TINYINT(1) (1 / '1'), like the Lua port. */
function isEnabled(value: unknown): boolean {
  return value === true || value === 1 || value === '1';
}

/** A null/empty (or non-string) citizenid is "no identity" and never matches an owner, assignee or handler. */
function identity(viewer: ViewerLike): string | null {
  const cid = str(viewer.citizenid);
  return cid ? cid : null;
}

function isAssigned(viewer: ViewerLike, record: VisRecord): boolean {
  const me = identity(viewer);
  return me !== null && (record.ownerCitizenid === me || listHas(record.assignees, me));
}

function isHandler(viewer: ViewerLike, record: VisRecord): boolean {
  const me = identity(viewer);
  return me !== null && record.handlerCitizenid === me;
}

export function ruleApplies(rule: VisibilityRule, record: VisRecord): boolean {
  return (
    isEnabled(rule.enabled) &&
    Object.hasOwn(RANK, rule.result) && // skip an unknown result from unvalidated DB rows, as the Lua port does
    (rule.recordType === '*' || rule.recordType === record.type) &&
    (rule.level == null || rule.level === levelOf(record)) && // == also accepts a missing level, like Lua
    (rule.recordStatus === 'any' || rule.recordStatus === record.status)
  );
}

export function conditionHolds(rule: VisibilityRule, viewer: ViewerLike, record: VisRecord): boolean {
  switch (rule.viewerCondition) {
    case 'any':
      return true;
    case 'assigned':
      return isAssigned(viewer, record);
    case 'handler':
      return isHandler(viewer, record);
    case 'unit': {
      // Literal §C3: only NULL falls back to record.unit; '' names no unit and never matches.
      const unit = str(rule.conditionValue) ?? str(record.unit);
      return unit !== null && listHas(viewer.units, unit);
    }
    case 'tier_gte':
      return tierOf(viewer) >= levelOf(record);
    case 'perm': {
      // A key-less perm rule (NULL or '') never matches, not even for perm:* (fail closed).
      const perm = str(rule.conditionValue);
      return perm !== null && perm !== '' && hasGrant(viewer.grants, 'perm', perm);
    }
    default:
      return false; // unknown condition from a newer schema: never grants anything
  }
}

/**
 * Hard caps, applied after the rules and not overridable by config (§C3):
 * 1. intel_source: `full` only for (handler with perm intel.handler) or perm intel.command, else at most `masked`.
 * 2. record.level > viewer.tier, viewer not assigned/owner/handler and without perm intel.command → at most `notice`.
 */
export function applyHardCaps(viewer: ViewerLike, record: VisRecord, result: VisibilityResult): VisibilityResult {
  const command = hasGrant(viewer.grants, 'perm', 'intel.command');
  const handler = isHandler(viewer, record);
  let out = result;
  if (record.type === 'intel_source' && !command && !(handler && hasGrant(viewer.grants, 'perm', 'intel.handler'))) {
    out = capResult(out, 'masked');
  }
  if (levelOf(record) > tierOf(viewer) && !command && !handler && !isAssigned(viewer, record)) {
    out = capResult(out, 'notice');
  }
  return out;
}

/**
 * Enabled rules matching the record's type/level/status, by priority desc then id asc; the first rule whose
 * viewer condition holds gives the result (no match → `none`), then the hard caps apply.
 */
export function canView(viewer: ViewerLike, record: VisRecord, rules: readonly VisibilityRule[]): VisibilityResult {
  const candidates = rules
    .filter((rule) => ruleApplies(rule, record))
    .sort((a, b) => b.priority - a.priority || a.id - b.id);
  const hit = candidates.find((rule) => conditionHolds(rule, viewer, record));
  return applyHardCaps(viewer, record, hit ? hit.result : 'none');
}
