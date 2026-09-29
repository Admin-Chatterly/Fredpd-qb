// SPDX-License-Identifier: GPL-3.0-only
// Contract test: the JSON that fredpd_bolo (Lua) produces must parse with the zod schemas in
// packages/types/src/mdt.ts (Bolo, BoloListOutput, PlateCheckResult) and, for the hit alert, dispatch.ts
// (AlertCreateInput). The golden files are written by tests/lua/bolo_server_test.lua from a real MariaDB round trip
// (isoSelect timestamps, officer/person/vehicle joins, canView shaping with the seeded rules).
//
// Lua cannot put null in a table: a nullable field that is nil is ABSENT on every Lua -> JS hop (msgpack for
// exports/NUI). The golden files keep that; this test checks that only nullable keys are ever missing and that
// nothing extra (unit, issuedByCid, flagActive, expiresEpoch …) leaks onto the wire, then parses after restoring the
// nulls. Consumers (the fredpd_mdt NUI) need the same restoreNulls step before a strict parse (docs/modules/bolo.md).
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { AlertCreateInputSchema } from '../../../../packages/types/src/dispatch';
import { BoloListOutputSchema, BoloSchema, PlateCheckResultSchema, PUSH_TOPICS } from '../../../../packages/types/src/mdt';

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
  'bolo.full': as(BoloSchema),
  'bolo.person': as(BoloSchema),
  'bolo.masked': as(BoloSchema),
  'bolo.notice': as(BoloSchema),
  'bolo.resolved': as(BoloSchema),
  'list.active': as(BoloListOutputSchema),
  'list.all': as(BoloListOutputSchema),
  'list.empty': as(BoloListOutputSchema),
  'plateCheck.hit': as(PlateCheckResultSchema),
  'plateCheck.clear': as(PlateCheckResultSchema),
  'plateCheck.unregistered': as(PlateCheckResultSchema),
  'plateCheck.notice': as(PlateCheckResultSchema),
  'alert-input.hit': as(AlertCreateInputSchema),
};
/** Checked by hand below (mdt.ts has no schema for the 'bolo' push payload yet). */
const MANUAL = ['push.created'];

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
 * through objects, arrays and unions). Also collects keys the schema does not know (z.object strips them silently,
 * but Lua must not leak internal fields onto the wire). Same algorithm as fredpd_dispatch's contract test.
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

function golden(name: string): Json {
  return JSON.parse(readFileSync(join(GOLDEN, `${name}.json`), 'utf8')) as Json;
}

const files = readdirSync(GOLDEN).filter((f) => f.endsWith('.json')).map((f) => f.replace(/\.json$/, '')).sort();

describe('fredpd_bolo golden JSON vs packages/types/src/mdt.ts', () => {
  it('has a schema for every golden file and a golden file for every schema', () => {
    expect(files).toEqual([...Object.keys(SCHEMAS), ...MANUAL].sort());
  });

  for (const name of Object.keys(SCHEMAS).sort()) {
    it(`${name} parses (after restoring Lua's absent nulls) with no unknown keys`, () => {
      const schema = SCHEMAS[name];
      if (!schema) throw new Error(`no schema for ${name}`);
      const walk = restoreNulls(schema, golden(name));
      expect(walk.unknown).toEqual([]);
      const parsed = schema.safeParse(walk.value);
      expect(parsed.success, parsed.success ? '' : JSON.stringify(parsed.error?.issues, null, 2)).toBe(true);
    });
  }

  it('a kontaktnotis carries the subject and whom to contact, nothing about the case', () => {
    const notice = golden('bolo.notice') as Record<string, unknown>;
    const walk = restoreNulls(as(BoloSchema), notice);
    expect(walk.filled.sort()).toEqual([
      '$.expiresAt', '$.issuedBy', '$.plate', '$.resolveNote', '$.resolvedAt', '$.resolvedBy',
    ]);
    expect(notice.reason).toMatch(/^Det finns uppgifter som rör .+\. Kontakta .+\.$/);
    expect(JSON.stringify(notice)).not.toContain('Hot mot tjänsteman');
    const checked = golden('plateCheck.notice') as { bolo: Record<string, unknown> };
    expect(checked.bolo.issuedBy).toBeUndefined();
    expect(String(checked.bolo.reason)).toContain('Kontakta');
  });

  it('masked hides who issued it; full and resolved carry OfficerRefs and ISO-8601 UTC times', () => {
    const masked = golden('bolo.masked') as Record<string, unknown>;
    expect(masked.issuedBy).toBeUndefined();
    expect(masked.reason).toBe('Hot mot tjänsteman');
    const resolved = BoloSchema.parse(restoreNulls(as(BoloSchema), golden('bolo.resolved')).value);
    expect(resolved.active).toBe(false);
    expect(resolved.resolvedBy?.displayName).toBe('Anna B.');
    expect(resolved.resolvedAt).toBe('2026-09-29T10:30:00Z');
    const person = BoloSchema.parse(restoreNulls(as(BoloSchema), golden('bolo.person')).value);
    expect(person.expiresAt).toBe('2026-10-01T10:10:00Z');
    expect(person.createdAt).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  });

  it('only nullable PlateCheckResult fields are absent for an unregistered plate', () => {
    const walk = restoreNulls(as(PlateCheckResultSchema), golden('plateCheck.unregistered'));
    expect(walk.filled.sort()).toEqual(['$.bolo', '$.model', '$.owner']);
    // Without restoring, a strict consumer would reject it: this is the documented integration point.
    expect(PlateCheckResultSchema.safeParse(golden('plateCheck.unregistered')).success).toBe(false);
  });

  it("the 'bolo' push payload is { type, id } only (no BOLO text is broadcast)", () => {
    expect(PUSH_TOPICS).toContain('bolo');
    const push = golden('push.created') as Record<string, unknown>;
    expect(Object.keys(push).sort()).toEqual(['id', 'type']);
    expect(['created', 'resolved', 'expired']).toContain(push.type);
    expect(Number.isInteger(push.id) && (push.id as number) > 0).toBe(true);
  });

  it('the hit alert is a valid createAlert input with source bolo', () => {
    const input = AlertCreateInputSchema.parse(golden('alert-input.hit'));
    expect(input.source).toBe('bolo');
    expect(input.title).toBe('Efterlyst fordon: ABC12D');
  });
});
