// SPDX-License-Identifier: GPL-3.0-only
// Contract test: the JSON fredpd_mdt (Lua) sends must parse with the zod schemas the NUI uses — MdtOpenPayload
// (actions.ts), HomeOutput, TabletListOutput and Tablet (mdt.ts). The golden files are written by
// tests/lua/mdt_open_test.lua, mdt_home_test.lua and mdt_tablets_test.lua (the tablet ones from a real MariaDB round
// trip with isoSelect timestamps and officer joins).
//
// Lua cannot put null in a table: a nullable field that is nil is ABSENT on the wire (msgpack/JSON), and an empty
// Lua table is written as [] here (as msgpack may send it). restoreNulls() puts the nulls back where the schema
// accepts null and reports keys the schema does not know, so no internal field can leak onto the wire unnoticed.
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { MdtOpenPayloadSchema } from '../../../../packages/types/src/actions';
import { HomeOutputSchema, TabletListOutputSchema, TabletSchema } from '../../../../packages/types/src/mdt';

const here = dirname(fileURLToPath(import.meta.url));
const GOLDEN = join(here, 'golden');

/** The part of a zod 4 schema walked here (introspected through `def`; zod is resolved from packages/types). */
interface Schema {
  safeParse(v: unknown): { success: boolean; data?: unknown; error?: { issues: unknown[] } };
  def: { type: string; shape?: Record<string, Schema>; element?: Schema; innerType?: Schema; options?: Schema[]; in?: Schema };
}
const as = (s: unknown): Schema => s as Schema;

const SCHEMAS: Record<string, Schema> = {
  'open.payload': as(MdtOpenPayloadSchema),
  'home.igv': as(HomeOutputSchema),
  'home.ledning': as(HomeOutputSchema),
  'tablets.list': as(TabletListOutputSchema),
  'tablet.revoked': as(TabletSchema),
};

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

function unwrap(schema: Schema): Schema {
  let s = schema;
  for (let i = 0; i < 10; i++) {
    if (['nullable', 'optional', 'default', 'readonly'].includes(s.def.type) && s.def.innerType) s = s.def.innerType;
    else if (s.def.type === 'pipe' && s.def.in) s = s.def.in;
    else break;
  }
  return s;
}

interface Walk { value: unknown; filled: string[]; unknown: string[] }

function restoreNulls(schema: Schema, value: unknown): Walk {
  const filled: string[] = [];
  const unknownKeys: string[] = [];
  function walk(sch: Schema, v: unknown, path: string, into: { filled: string[]; unknown: string[] }): unknown {
    const s = unwrap(sch);
    const { type, shape, element, options } = s.def;
    // An empty Lua table: [] where the schema wants an object.
    if (Array.isArray(v) && v.length === 0 && type === 'object') v = {};
    if (Array.isArray(v) && type === 'array' && element) return v.map((item, i) => walk(element, item, `${path}[${i}]`, into));
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
      for (const key of Object.keys(v)) if (!(key in shape)) into.unknown.push(`${path}.${key}`);
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

function golden(name: string): unknown {
  return JSON.parse(readFileSync(join(GOLDEN, `${name}.json`), 'utf8')) as unknown;
}

const files = readdirSync(GOLDEN).filter((f) => f.endsWith('.json')).map((f) => f.replace(/\.json$/, '')).sort();

describe('fredpd_mdt golden JSON vs packages/types', () => {
  it('has a schema for every golden file and a golden file for every schema', () => {
    expect(files).toEqual(Object.keys(SCHEMAS).sort());
  });

  for (const name of Object.keys(SCHEMAS).sort()) {
    it(`${name} parses (after restoring Lua's absent nulls) with no unknown keys`, () => {
      const schema = SCHEMAS[name]!;
      const walk = restoreNulls(schema, golden(name));
      expect(walk.unknown).toEqual([]);
      const parsed = schema.safeParse(walk.value);
      expect(parsed.success, parsed.success ? '' : JSON.stringify(parsed.error?.issues, null, 2)).toBe(true);
    });
  }

  it('the open payload carries the grants copy, the primary unit and me without a unit field', () => {
    const payload = MdtOpenPayloadSchema.parse(restoreNulls(as(MdtOpenPayloadSchema), golden('open.payload')).value);
    expect(payload.unit).toBe('ledning');
    expect(payload.me).toEqual({ citizenid: 'MDT10002', displayName: 'Eva L.', callsign: 'LED-01' });
    expect(payload.grants.denied).toEqual([]);
  });

  it('Hem: roster only for Ledning, at most 10 BOLOs and cases, OfficerRef on the roster', () => {
    const igv = HomeOutputSchema.parse(restoreNulls(as(HomeOutputSchema), golden('home.igv')).value);
    const led = HomeOutputSchema.parse(restoreNulls(as(HomeOutputSchema), golden('home.ledning')).value);
    expect(igv.variant).toBe('igv');
    expect(igv.roster).toEqual([]);
    expect(igv.recentBolos.length).toBe(10);
    expect(led.variant).toBe('ledning');
    expect(led.roster.map((r) => r.callsign)).toEqual(['IGV-07', 'IGV-11', 'LED-01', 'SPAN-02']);
    expect(led.roster.every((r) => r.onDuty)).toBe(true);
    expect(led.myCases.some((c) => c.visibility === 'notice')).toBe(true);
  });

  it('tablets: ISO-8601 UTC issue times, OfficerRef issuer or null for the console', () => {
    const list = TabletListOutputSchema.parse(restoreNulls(as(TabletListOutputSchema), golden('tablets.list')).value);
    expect(list.items[0]!.issuedAt).toBe('2026-09-28T08:00:00Z');
    expect(list.items[0]!.issuedBy?.callsign).toBe('LED-01');
    expect(list.items[1]!.issuedBy).toBeNull();
    const walk = restoreNulls(as(TabletSchema), golden('tablet.revoked'));
    expect(walk.filled).toEqual([]);
    expect(TabletSchema.parse(walk.value).revoked).toBe(true);
  });
});
