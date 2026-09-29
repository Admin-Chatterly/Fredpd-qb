// SPDX-License-Identifier: GPL-3.0-only
// Contract test: the JSON that fredpd_dispatch (Lua) produces must parse with the zod schemas in
// packages/types/src/dispatch.ts. The golden files are written by tests/lua/dispatch_server_test.lua from a real
// MariaDB round trip (single loader, isoSelect timestamps) and the captured toast/push/service payloads.
//
// Lua cannot put null in a table: a nullable field that is nil is ABSENT on every Lua -> JS hop (msgpack for
// exports/events/NUI, JSON.stringify of that object in fredpd_core's signedFetch). The golden files keep that
// (absent keys), and this test checks that only nullable keys are ever missing and that nothing extra is present,
// then parses after restoring the nulls. Consumers (NUI push handler, service /ws, portal) need the same
// restoreNulls step before a strict parse; see "Integration requests" in docs/modules/dispatch.md.
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
  AlertCreateInputSchema,
  AlertListOutputSchema,
  AlertPushSchema,
  AlertSchema,
  AlertToastSchema,
  DispatchInternalEventSchema,
  UnitsPushSchema,
} from '../../../../packages/types/src/dispatch';

const here = dirname(fileURLToPath(import.meta.url));
const GOLDEN = join(here, 'golden');

/**
 * The part of a zod 4 schema this test walks. zod is not resolvable from resources/ (not a workspace package), so
 * the schemas are introspected through their public `def` instead of `instanceof z.ZodObject`.
 */
interface Schema {
  safeParse(v: unknown): { success: boolean; error?: { issues: unknown[] } };
  def: { type: string; shape?: Record<string, Schema>; element?: Schema; innerType?: Schema; options?: Schema[] };
}
const as = (s: unknown): Schema => s as Schema;

const SCHEMAS: Record<string, Schema> = {
  'alert.open': as(AlertSchema),
  'alert.bare': as(AlertSchema),
  'alert.assigned': as(AlertSchema),
  'alert.closed': as(AlertSchema),
  'list.all': as(AlertListOutputSchema),
  'list.empty': as(AlertListOutputSchema),
  units: as(UnitsPushSchema),
  toast: as(AlertToastSchema),
  'toast.nostreet': as(AlertToastSchema),
  'push.created': as(AlertPushSchema),
  'push.updated': as(AlertPushSchema),
  'push.closed': as(AlertPushSchema),
  'internal.alertCreated': as(DispatchInternalEventSchema),
  'internal.alertAssigned': as(DispatchInternalEventSchema),
  'internal.alertClosed': as(DispatchInternalEventSchema),
  'internal.unitsChanged': as(DispatchInternalEventSchema),
  'create-input.ps-dispatch': as(AlertCreateInputSchema),
};

type Json = null | boolean | number | string | Json[] | { [k: string]: Json };

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

function unwrap(schema: Schema): Schema {
  let s = schema;
  for (let i = 0; i < 10 && ['nullable', 'optional', 'default'].includes(s.def.type) && s.def.innerType; i++) {
    s = s.def.innerType;
  }
  return s;
}

interface Walk { value: unknown; filled: string[]; unknown: string[] }

/**
 * Put back the nulls Lua could not send: every ABSENT key whose schema accepts null becomes null (recursively
 * through objects, arrays and discriminated unions). Also collects keys the schema does not know (z.object strips
 * them silently, but Lua must not leak fields such as `meta` onto the wire).
 */
function restoreNulls(schema: Schema, value: unknown): Walk {
  const filled: string[] = [];
  const unknownKeys: string[] = [];

  function walk(sch: Schema, v: unknown, path: string, into: { filled: string[]; unknown: string[] }): unknown {
    const s = unwrap(sch);
    const { type, shape, element, options } = s.def;
    if (Array.isArray(v) && type === 'array' && element) {
      return v.map((item, i) => walk(element, item, `${path}[${i}]`, into));
    }
    if (isRecord(v) && type === 'union' && options) {
      for (const option of options) {
        const probe = { filled: [] as string[], unknown: [] as string[] };
        const candidate = walk(option, v, path, probe);
        if (option.safeParse(candidate).success) {
          into.filled.push(...probe.filled);
          into.unknown.push(...probe.unknown);
          return candidate;
        }
      }
      return v;
    }
    if (isRecord(v) && type === 'object' && shape) {
      const out: Record<string, unknown> = {};
      for (const key of Object.keys(v)) {
        if (!(key in shape)) into.unknown.push(`${path}.${key}`);
      }
      for (const [key, field] of Object.entries(shape)) {
        if (v[key] === undefined) {
          if (field.safeParse(null).success) {
            out[key] = null;
            into.filled.push(`${path}.${key}`);
          }
        } else {
          out[key] = walk(field, v[key], `${path}.${key}`, into);
        }
      }
      return out;
    }
    return v;
  }

  const restored = walk(schema, value, '$', { filled, unknown: unknownKeys });
  return { value: restored, filled, unknown: unknownKeys };
}

const files = readdirSync(GOLDEN).filter((f) => f.endsWith('.json')).map((f) => f.replace(/\.json$/, '')).sort();

describe('fredpd_dispatch golden JSON vs packages/types/src/dispatch.ts', () => {
  it('has a schema for every golden file and a golden file for every schema', () => {
    expect(files).toEqual(Object.keys(SCHEMAS).sort());
  });

  for (const name of files) {
    it(`${name} parses (after restoring Lua's absent nulls) with no unknown keys`, () => {
      const schema = SCHEMAS[name];
      if (!schema) throw new Error(`no schema for ${name}`);
      const raw = JSON.parse(readFileSync(join(GOLDEN, `${name}.json`), 'utf8')) as Json;
      const walk = restoreNulls(schema, raw);
      expect(walk.unknown).toEqual([]);
      const parsed = schema.safeParse(walk.value);
      expect(parsed.success, parsed.success ? '' : JSON.stringify(parsed.error?.issues, null, 2)).toBe(true);
    });
  }

  it('only nullable Alert fields are ever absent', () => {
    const alert = JSON.parse(readFileSync(join(GOLDEN, 'alert.bare.json'), 'utf8')) as Record<string, unknown>;
    const walk = restoreNulls(as(AlertSchema), alert);
    expect(walk.filled.sort()).toEqual(['$.closedAt', '$.closedBy', '$.coords', '$.description', '$.street']);
    // Without restoring, a strict consumer would reject it: this is the documented integration point.
    expect(AlertSchema.safeParse(alert).success).toBe(false);
  });

  it('timestamps are ISO-8601 UTC and the toast carries only its five fields', () => {
    const closed = JSON.parse(readFileSync(join(GOLDEN, 'alert.closed.json'), 'utf8')) as Record<string, string>;
    expect(closed.createdAt).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
    expect(closed.closedAt).toBe('2026-09-29T10:30:00Z');
    const toast = JSON.parse(readFileSync(join(GOLDEN, 'toast.json'), 'utf8')) as Record<string, unknown>;
    expect(Object.keys(toast).sort()).toEqual(['code', 'id', 'priority', 'street', 'title']);
  });
});
