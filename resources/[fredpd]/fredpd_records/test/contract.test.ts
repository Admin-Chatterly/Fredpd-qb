// SPDX-License-Identifier: GPL-3.0-only
// Contract test: the JSON fredpd_records (Lua) returns through its exports must parse with the zod schemas in
// packages/types/src/mdt.ts (§C12). The golden files are written by tests/lua/records_search_test.lua and
// tests/lua/records_summary_test.lua from real MariaDB round trips (isoSelect timestamps, canView via the seeded
// default rules) with FiveM mocked.
//
// Lua cannot put null in a table: a nullable field that is nil is ABSENT on every Lua -> JS hop (msgpack for the
// export return and the lib.callback, JSON for the NUI message). The golden files keep that, and this test checks
// that only nullable keys are ever missing and that nothing extra is present (e.g. a notice CaseRef must never carry
// id, caseNumber, title or level), then parses after restoring the nulls. The NUI needs the same restore step
// before a strict parse (docs/modules/records.md, "Integration requests").
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
  CaseRefSchema,
  HomeOutputSchema,
  PersonSummarySchema,
  SearchOutputSchema,
  VehicleSummarySchema,
} from '../../../../packages/types/src/mdt';
import {
  ApplyChargesOutputSchema,
  CaseDetailSchema,
  CaseListOutputSchema,
  ChargeListOutputSchema,
  RECORDS_ACTIONS,
  ReportDetailSchema,
} from '../../../../packages/types/src/records';
import { PoiViewSchema, ReleaseRequestSchema } from './proposed';

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
  'search.name': as(SearchOutputSchema),
  'search.person-id': as(SearchOutputSchema),
  'search.plate': as(SearchOutputSchema),
  'search.case-full': as(SearchOutputSchema),
  'search.case-notice': as(SearchOutputSchema),
  'search.empty': as(SearchOutputSchema),
  'person.summary': as(PersonSummarySchema),
  'person.minimal': as(PersonSummarySchema),
  'vehicle.summary': as(VehicleSummarySchema),
  'vehicle.unregistered': as(VehicleSummarySchema),
  'home.cases': as(HomeOutputSchema.shape.myCases),
  // Phase 5 (§C14)
  'case.full': as(CaseDetailSchema),
  'case.masked': as(CaseDetailSchema),
  'case.notice': as(CaseDetailSchema),
  'cases.list': as(CaseListOutputSchema),
  'report.detail': as(ReportDetailSchema),
  'templates.list': as(RECORDS_ACTIONS.listReportTemplates.output),
  'charges.list': as(ChargeListOutputSchema),
  'charges.applied': as(ApplyChargesOutputSchema),
  // Phase 5 additions without a contract schema yet (test/proposed.ts; docs/modules/records.md)
  'poi.full': as(PoiViewSchema),
  'poi.notice': as(PoiViewSchema),
  'release.decided': as(ReleaseRequestSchema),
};

/** Golden files whose CaseRefs (objects with `visibility`) are the §C12 CaseRef shape. */
const CASEREF_FILES = new Set([
  'search.name', 'search.person-id', 'search.plate', 'search.case-full', 'search.case-notice', 'search.empty',
  'person.summary', 'person.minimal', 'vehicle.summary', 'vehicle.unregistered', 'home.cases', 'cases.list',
]);

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
 * them silently, but Lua must not leak fields onto the wire).
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

const read = (name: string): Json => JSON.parse(readFileSync(join(GOLDEN, `${name}.json`), 'utf8')) as Json;
const files = readdirSync(GOLDEN).filter((f) => f.endsWith('.json')).map((f) => f.replace(/\.json$/, '')).sort();

/** Every CaseRef found anywhere in a golden value (objects with a `visibility` key). */
function caseRefs(v: unknown, out: Record<string, unknown>[] = []): Record<string, unknown>[] {
  if (Array.isArray(v)) v.forEach((x) => caseRefs(x, out));
  else if (isRecord(v)) {
    if (typeof v.visibility === 'string') out.push(v);
    else Object.values(v).forEach((x) => caseRefs(x, out));
  }
  return out;
}

describe('fredpd_records golden JSON vs packages/types/src/mdt.ts', () => {
  it('has a schema for every golden file and a golden file for every schema', () => {
    expect(files).toEqual(Object.keys(SCHEMAS).sort());
  });

  for (const name of files) {
    it(`${name} parses (after restoring Lua's absent nulls) with no unknown keys`, () => {
      const schema = SCHEMAS[name];
      if (!schema) throw new Error(`no schema for ${name}`);
      const walk = restoreNulls(schema, read(name));
      expect(walk.unknown).toEqual([]);
      const parsed = schema.safeParse(walk.value);
      expect(parsed.success, parsed.success ? '' : JSON.stringify(parsed.error?.issues, null, 2)).toBe(true);
    });
  }

  it('CaseRef variants carry exactly their fields: notice has no id, number, title or level', () => {
    const refs = files.filter((name) => CASEREF_FILES.has(name)).flatMap((name) => caseRefs(read(name)));
    const seen = new Set<string>();
    for (const ref of refs) {
      const keys = Object.keys(ref).sort();
      if (ref.visibility === 'notice') {
        expect(keys).toEqual(['contact', 'visibility']);
        const contact = ref.contact as Record<string, unknown>;
        expect(Object.keys(contact).every((k) => k === 'displayName' || k === 'unit')).toBe(true);
        seen.add(Object.keys(contact).length === 2 ? 'notice' : 'notice-unit-only');
      } else {
        const required = ['caseNumber', 'id', 'level', 'status', 'visibility'];
        expect(required.every((k) => keys.includes(k)), JSON.stringify(ref)).toBe(true);
        expect(keys.every((k) => [...required, 'title', 'role'].includes(k)), JSON.stringify(ref)).toBe(true);
        if (ref.visibility === 'full') expect(keys).toContain('title');
        seen.add(ref.visibility === 'masked' && !('title' in ref) ? 'masked-untitled' : String(ref.visibility));
      }
      expect(CaseRefSchema.safeParse(restoreNulls(as(CaseRefSchema), ref).value).success).toBe(true);
    }
    // the fixtures cover every shape a viewer can receive ('none' is never on the wire)
    expect([...seen].sort()).toEqual(['full', 'masked', 'masked-untitled', 'notice', 'notice-unit-only']);
  });

  it('only nullable fields are ever absent', () => {
    const minimal = restoreNulls(as(PersonSummarySchema), read('person.minimal'));
    expect(minimal.filled.sort()).toEqual([
      '$.address', '$.person.birthdate', '$.person.personnummer', '$.person.phone', '$.records[0].caseNumber',
    ]);
    // Without restoring, a strict consumer would reject it: this is the documented integration point.
    expect(PersonSummarySchema.safeParse(read('person.minimal')).success).toBe(false);
    const unregistered = restoreNulls(as(VehicleSummarySchema), read('vehicle.unregistered'));
    expect(unregistered.filled.sort()).toEqual([
      '$.bolos[0].citizenid', '$.bolos[0].expiresAt', '$.bolos[0].resolveNote', '$.bolos[0].resolvedAt',
      '$.bolos[0].resolvedBy', '$.owner', '$.vehicle.model',
    ]);
  });

  it('timestamps are ISO-8601 UTC; plate checks newest first', () => {
    const vehicle = read('vehicle.summary') as { checks: { checkedAt: string }[] };
    expect(vehicle.checks).toHaveLength(20);
    const times = vehicle.checks.map((c) => c.checkedAt);
    for (const t of times) expect(t).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
    expect([...times].sort().reverse()).toEqual(times);
    const person = read('person.summary') as { records: { createdAt: string }[] };
    expect(person.records[0]?.createdAt).toBe('2026-09-04T12:00:00Z');
  });
});

describe('fredpd_records Phase 5 golden JSON: visibility shapes carry only what they may', () => {
  it('a notice CaseDetail is exactly { visibility, contact }', () => {
    const notice = read('case.notice') as Record<string, unknown>;
    expect(Object.keys(notice).sort()).toEqual(['contact', 'visibility']);
  });

  it('masked CaseDetail: reports above the viewer tier have no title; the full view has them all', () => {
    const masked = read('case.masked') as { visibility: string; reports: { level: number; title?: string }[] };
    expect(masked.visibility).toBe('masked');
    for (const r of masked.reports) {
      if (r.level > 0) expect(r).not.toHaveProperty('title');
      else expect(typeof r.title).toBe('string');
    }
    const full = read('case.full') as { reports: { title?: string }[]; timeline: unknown[] };
    expect(full.reports.every((r) => typeof r.title === 'string')).toBe(true);
    expect(full.timeline.length).toBeGreaterThan(0);
  });

  it('a notice POI sheet carries only its contact', () => {
    const view = read('poi.notice') as { poi: Record<string, unknown> };
    expect(Object.keys(view.poi).sort()).toEqual(['contact', 'visibility']);
  });

  it('a released export has no officer, subject or level > 0 content (§5.3 acceptance)', () => {
    const text = JSON.stringify(read('release.decided'));
    const released = JSON.stringify((read('release.decided') as { released: unknown }).released);
    for (const banned of ['BEGRANSAD', 'HEMLIG', 'uppgiftslämnare']) expect(text).not.toContain(banned);
    for (const field of ['author', 'subjects', 'evidence', 'citizenid', 'REC100']) expect(released).not.toContain(field);
  });

  it('charges totals add up', () => {
    const applied = read('charges.applied') as { records: { fine: number; jailMinutes: number }[]; totals: { fine: number; jailMinutes: number } };
    expect(applied.totals.fine).toBe(applied.records.reduce((sum, r) => sum + r.fine, 0));
    expect(applied.totals.jailMinutes).toBe(applied.records.reduce((sum, r) => sum + r.jailMinutes, 0));
  });
});
