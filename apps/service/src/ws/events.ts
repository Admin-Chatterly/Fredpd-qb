// SPDX-License-Identifier: GPL-3.0-only
// /ws live events: who may receive which event type, and the check of an /internal/events body before it is fanned
// out (docs/contracts.md §C6, §C13). §C13: /ws forwards only to logged-in users whose grants include
// mdt_page:alerts. The grant is looked up per event type, so a later event type can require another grant without
// touching the hub; an allow on any other grant (weapon:*, tool:ram, perm:rank:x) gives no live data, and a deny
// wins as everywhere else (hasGrant).
import type { ZodType } from 'zod';
import { INTERNAL_EVENT_TYPES } from '@fredpd/types/actions';
import type { InternalEvent, InternalEventType } from '@fredpd/types/actions';
import { DispatchInternalEventSchema } from '@fredpd/types/dispatch';
import { hasGrant } from '@fredpd/types/grants';
import type { GrantSet, GrantType } from '@fredpd/types/grants';

/** Grant a user needs to receive each event type. */
export const LIVE_EVENT_GRANTS: Readonly<Record<InternalEventType, readonly [GrantType, string]>> = {
  alertCreated: ['mdt_page', 'alerts'],
  alertAssigned: ['mdt_page', 'alerts'],
  alertClosed: ['mdt_page', 'alerts'],
  unitsChanged: ['mdt_page', 'alerts'],
  // No producer and no payload contract yet: the §C13 /ws rule applies until their module pins one.
  playerJoined: ['mdt_page', 'alerts'],
  playerDropped: ['mdt_page', 'alerts'],
};

/** Event types one user may receive. Empty = not eligible for /ws at all. */
export type LiveAccess = ReadonlySet<InternalEventType>;
export const NO_LIVE_ACCESS: LiveAccess = new Set<InternalEventType>();

export function liveAccess(member: boolean, grants: GrantSet): LiveAccess {
  if (!member) return NO_LIVE_ACCESS;
  const out = new Set<InternalEventType>();
  for (const type of INTERNAL_EVENT_TYPES) {
    const [grantType, key] = LIVE_EVENT_GRANTS[type];
    if (hasGrant(grants, grantType, key)) out.add(type);
  }
  return out;
}

// ---------------------------------------------------------------------------------------------------------------
// Payload check

/** Event types whose payload shape is pinned (DispatchInternalEventSchema, §C13). */
const DISPATCH_TYPES: ReadonlySet<InternalEventType> = new Set(['alertCreated', 'alertAssigned', 'alertClosed', 'unitsChanged']);

/** The part of a zod 4 schema restoreNulls walks (its public `def`). */
interface SchemaDef {
  type: string;
  shape?: Record<string, ZodType>;
  element?: ZodType;
  innerType?: ZodType;
  options?: ZodType[];
}
const defOf = (s: ZodType): SchemaDef => (s as unknown as { def: SchemaDef }).def;

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

/**
 * Lua cannot put null in a table, so a nullable field that is nil is ABSENT in what fredpd_dispatch posts
 * (docs/modules/dispatch.md "Lua cannot send null"). Put those nulls back before the strict parse: every absent key
 * whose schema accepts null becomes null, recursively through objects, arrays and (discriminated) unions. Keys the
 * schema does not know are left for zod, which strips them.
 */
export function restoreNulls(schema: ZodType, value: unknown): unknown {
  let s = schema;
  for (let i = 0; i < 10; i += 1) {
    const d = defOf(s);
    if (!['nullable', 'optional', 'default'].includes(d.type) || !d.innerType) break;
    s = d.innerType;
  }
  const def = defOf(s);
  if (Array.isArray(value) && def.type === 'array' && def.element) {
    const element = def.element;
    return value.map((item) => restoreNulls(element, item));
  }
  if (isRecord(value) && def.type === 'union' && def.options) {
    for (const option of def.options) {
      const candidate = restoreNulls(option, value);
      if (option.safeParse(candidate).success) return candidate;
    }
    return value;
  }
  if (isRecord(value) && def.type === 'object' && def.shape) {
    const out: Record<string, unknown> = { ...value };
    for (const [key, field] of Object.entries(def.shape)) {
      if (value[key] === undefined) {
        if (field.safeParse(null).success) out[key] = null;
      } else {
        out[key] = restoreNulls(field, value[key]);
      }
    }
    return out;
  }
  return value;
}

export type EventCheck = { ok: true; event: InternalEvent } | { ok: false; detail: string };

/**
 * Alert and unit events must match DispatchInternalEventSchema (after restoring Lua's absent nulls); what is
 * forwarded is the parsed value, so unknown keys never reach a browser. Types without a pinned payload yet
 * (playerJoined, playerDropped) pass unchanged; they are still only sent to users with the event's grant.
 */
export function checkInternalEvent(event: InternalEvent): EventCheck {
  if (!DISPATCH_TYPES.has(event.type)) return { ok: true, event };
  const parsed = DispatchInternalEventSchema.safeParse(restoreNulls(DispatchInternalEventSchema, event));
  if (!parsed.success) {
    const issue = parsed.error.issues[0];
    const path = issue?.path.map(String).join('.') || 'payload';
    return { ok: false, detail: `${path}: ${issue?.message ?? 'invalid'}`.slice(0, 200) };
  }
  return { ok: true, event: parsed.data };
}
