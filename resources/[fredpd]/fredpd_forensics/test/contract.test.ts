// SPDX-License-Identifier: GPL-3.0-only
// Contract test: the JSON fredpd_forensics (Lua) returns must parse with the zod schemas in
// packages/types/src/evidence.ts (EvidenceItemSchema, EVIDENCE_ACTIONS.listEvidence.output). The golden files are
// written by tests/lua/forensics_server_test.lua from a real MariaDB round trip (collect -> analyse -> link ->
// hand-in, masked and unlinked views, ballistics) with timestamps normalised.
//
// Lua cannot put null in a table: a nullable field that is nil is ABSENT on every Lua -> JS hop (msgpack for
// exports/events/NUI). The golden files keep that, and this test checks that only nullable keys are ever missing and
// that nothing unknown is present, then parses after restoring the nulls (same approach as fredpd_dispatch).
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { EVIDENCE_ACTIONS, EvidenceItemSchema, EvidenceTypeSchema } from '../../../../packages/types/src/evidence';

const here = dirname(fileURLToPath(import.meta.url));
const GOLDEN = join(here, 'golden');

/** The part of a zod 4 schema this test walks (zod is not resolvable from resources/, so no instanceof). */
interface Schema {
  safeParse(v: unknown): { success: boolean; error?: { issues: unknown[] } };
  def: { type: string; shape?: Record<string, Schema>; element?: Schema; innerType?: Schema; options?: Schema[] };
}
const as = (s: unknown): Schema => s as Schema;

const ITEM = as(EvidenceItemSchema);
const LIST = as(EVIDENCE_ACTIONS.listEvidence.output);

const SCHEMAS: Record<string, Schema | null> = {
  'evidence.full': ITEM,
  'evidence.masked': ITEM,
  'evidence.unlinked': ITEM,
  'evidence.collected': ITEM,
  'evidence.ballistics': ITEM,
  'evidence.collector': ITEM,
  'list.case': LIST,
  // listCaseEvidence (case page, fredpd_records): same output as listEvidence.
  'list.caseExport': LIST,
  'list.empty': LIST,
  // FredPD-internal payloads without a zod schema; checked by hand below.
  offer: null,
  'push.case': null,
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

/** Put back the nulls Lua could not send and collect keys the schema does not know. */
function restoreNulls(schema: Schema, value: unknown): Walk {
  const filled: string[] = [];
  const unknownKeys: string[] = [];

  function walk(sch: Schema, v: unknown, path: string): unknown {
    const s = unwrap(sch);
    const { type, shape, element } = s.def;
    if (Array.isArray(v) && type === 'array' && element) return v.map((item, i) => walk(element, item, `${path}[${i}]`));
    if (isRecord(v) && type === 'object' && shape) {
      const out: Record<string, unknown> = {};
      for (const key of Object.keys(v)) if (!(key in shape)) unknownKeys.push(`${path}.${key}`);
      for (const [key, field] of Object.entries(shape)) {
        if (v[key] === undefined) {
          if (field.safeParse(null).success) {
            out[key] = null;
            filled.push(`${path}.${key}`);
          }
        } else {
          out[key] = walk(field, v[key], `${path}.${key}`);
        }
      }
      return out;
    }
    return v;
  }

  return { value: walk(schema, value, '$'), filled, unknown: unknownKeys };
}

const read = (name: string): Json => JSON.parse(readFileSync(join(GOLDEN, `${name}.json`), 'utf8')) as Json;
const files = readdirSync(GOLDEN).filter((f) => f.endsWith('.json')).map((f) => f.replace(/\.json$/, '')).sort();

describe('fredpd_forensics golden JSON vs packages/types/src/evidence.ts', () => {
  it('has a schema entry for every golden file and a golden file for every entry', () => {
    expect(files).toEqual(Object.keys(SCHEMAS).sort());
  });

  for (const name of files.filter((n) => SCHEMAS[n])) {
    it(`${name} parses (after restoring Lua's absent nulls) with no unknown keys`, () => {
      const schema = SCHEMAS[name] as Schema;
      const walk = restoreNulls(schema, read(name));
      expect(walk.unknown).toEqual([]);
      const parsed = schema.safeParse(walk.value);
      expect(parsed.success, parsed.success ? '' : JSON.stringify(parsed.error?.issues, null, 2)).toBe(true);
    });
  }

  it('the §5.7 story: four custody entries on the case evidence, tag from formats.json evidenceTag', () => {
    const item = read('evidence.full') as Record<string, unknown>;
    const chain = item.chain as { action: string; at: string }[];
    expect(chain.map((e) => e.action)).toEqual(['collect', 'analyse', 'link', 'handin']);
    expect(item.tag).toBe('B-K-123-26-001');
    for (const e of chain) expect(e.at).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  });

  it('a person match reaches only viewers with a full view of the case', () => {
    const full = read('evidence.full') as { result: Record<string, unknown> };
    const masked = read('evidence.masked') as { result: Record<string, unknown> };
    const unlinked = read('evidence.unlinked') as { result: Record<string, unknown> };
    expect(full.result.match).toEqual({ citizenid: 'SUS00001', name: 'Sven Svensson' });
    expect(masked.result.match).toBeUndefined();
    expect(masked.result.fingerprint).toBe(full.result.fingerprint);
    expect(unlinked.result.match).toEqual({ citizenid: 'SUS00001', name: 'Sven Svensson' });
  });

  it('an unlinked item seen by its collector (canView assigned) has no person match', () => {
    const item = read('evidence.collector') as { result: Record<string, unknown>; chain: { action: string }[] };
    expect(item.result.fingerprint).toBeTypeOf('string');
    expect(item.result.match).toBeUndefined();
    expect(item.chain.map((e) => e.action)).toEqual(['collect', 'transfer', 'analyse']);
  });

  it('a hand-over between officers (give) is a transfer entry: actor = recipient, no location', () => {
    const list = read('list.caseExport') as { items: { chain: Record<string, unknown>[] }[]; total: number };
    expect(list.total).toBe(1);
    const [collect, transfer, ...rest] = list.items[0]?.chain ?? [];
    expect([collect?.action, transfer?.action, ...rest.map((e) => e.action)]).toEqual(['collect', 'transfer', 'analyse', 'link']);
    expect((transfer?.actor as Record<string, unknown> | undefined)?.citizenid).toBe('FOR10001');
    expect(transfer?.location).toBeUndefined();
    expect((collect?.actor as Record<string, unknown> | undefined)?.citizenid).toBe('FOR10003');
  });

  it('only nullable EvidenceItem fields are ever absent (collected, not analysed or linked)', () => {
    const walk = restoreNulls(ITEM, read('evidence.collected'));
    expect(walk.filled.sort()).toEqual([
      '$.caseId', '$.caseNumber', '$.chain[0].note', '$.result', '$.tag',
    ]);
    // A strict consumer without the restore step rejects it: the documented integration point (fredpd_mdt / NUI).
    expect(EvidenceItemSchema.safeParse(read('evidence.collected')).success).toBe(false);
  });

  it('list output pages and totals', () => {
    const list = read('list.case') as { items: unknown[]; total: number; page: number };
    expect(list.total).toBe(1);
    expect(list.page).toBe(1);
    expect(read('list.empty')).toEqual({ items: [], page: 1, total: 0 });
  });

  it('offer (fredpd:forensics:client:offerLink) and push (topic case) carry ids only', () => {
    const offer = read('offer') as Record<string, unknown>;
    expect(Object.keys(offer).sort()).toEqual(['example', 'id', 'type']);
    expect(Number.isInteger(offer.id)).toBe(true);
    expect(EvidenceTypeSchema.safeParse(offer.type).success).toBe(true);
    expect(read('push.case')).toEqual({ caseId: 1, evidenceId: 1, type: 'evidenceLinked' });
  });
});
