// SPDX-License-Identifier: GPL-3.0-only
// Contract test: the JSON fredpd_intel (Lua) returns must parse with the zod schemas in packages/types/src/intel.ts
// (INTEL_ACTIONS outputs). The golden files are written by tests/lua/intel_server_test.lua from a real MariaDB round
// trip (the §5.8 Hemlig mission story, a source, links, a depth-2 graph) with timestamps normalised.
//
// Lua cannot put null in a table: a nullable field that is nil is ABSENT on every Lua -> JS hop (msgpack for
// exports/events/NUI). The golden files keep that; this test checks that only nullable keys are ever missing and that
// nothing unknown is present, then parses after restoring the nulls (same approach as fredpd_dispatch/forensics).
// Discriminated unions (visibility full | masked | notice) are walked with the option whose literal matches.
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { GRAPH_NODE_CAP, INTEL_ACTIONS, MissionSchema } from '../../../../packages/types/src/intel';

const here = dirname(fileURLToPath(import.meta.url));
const GOLDEN = join(here, 'golden');

/** The part of a zod 4 schema this test walks (zod is not resolvable from resources/, so no instanceof). */
interface Schema {
  safeParse(v: unknown): { success: boolean; error?: { issues: unknown[] } };
  def: {
    type: string;
    shape?: Record<string, Schema>;
    element?: Schema;
    innerType?: Schema;
    options?: Schema[];
    values?: unknown[];
  };
}
const as = (s: unknown): Schema => s as Schema;
const out = (name: keyof typeof INTEL_ACTIONS): Schema => as(INTEL_ACTIONS[name].output);

const SCHEMAS: Record<string, Schema> = {
  'source.full': out('getSource'),
  'source.masked': out('getSource'),
  'source.notice': out('getSource'),
  'sources.list': out('listSources'),
  'report.full': out('getIntelReport'),
  'report.notice': out('getIntelReport'),
  'reports.list': out('listIntelReports'),
  'entity.full': out('getEntity'),
  'entity.notice': out('getEntity'),
  'entity.ensure': out('ensureEntity'),
  'entities.search': out('searchEntities'),
  link: out('addLink'),
  'graph.depth2': out('getGraph'),
  'mission.full': out('getMission'),
  'mission.notice': out('getMission'),
  'missions.list': out('listMissions'),
  // getPersonNotices (fredpd_records' person page): an array of the §C15 Notice shape (MissionSchema's notice option).
  personNotices: {
    safeParse: (v: unknown) => {
      const ok = Array.isArray(v) && v.every((n) => MissionSchema.safeParse(n).success && (n as { visibility?: string }).visibility === 'notice');
      return ok ? { success: true } : { success: false, error: { issues: ['not an array of notices'] } };
    },
    def: { type: 'array', element: as(MissionSchema) },
  },
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
function restoreNulls(schema: Schema, value: unknown, path = '$'): Walk {
  const s = unwrap(schema);
  const { type, shape, element, options } = s.def;
  if (type === 'union' && options) {
    let first: Walk | undefined;
    for (const option of options) {
      const w = restoreNulls(option, value, path);
      first ??= w;
      if (w.unknown.length === 0 && option.safeParse(w.value).success) return w;
    }
    return first ?? { value, filled: [], unknown: [] };
  }
  if (Array.isArray(value) && type === 'array' && element) {
    const res: Walk = { value: [], filled: [], unknown: [] };
    res.value = value.map((item, i) => {
      const w = restoreNulls(element, item, `${path}[${i}]`);
      res.filled.push(...w.filled);
      res.unknown.push(...w.unknown);
      return w.value;
    });
    return res;
  }
  if (isRecord(value) && type === 'object' && shape) {
    const res: Walk = { value: undefined, filled: [], unknown: [] };
    const o: Record<string, unknown> = {};
    for (const key of Object.keys(value)) if (!(key in shape)) res.unknown.push(`${path}.${key}`);
    for (const [key, field] of Object.entries(shape)) {
      if (value[key] === undefined) {
        if (field.safeParse(null).success) {
          o[key] = null;
          res.filled.push(`${path}.${key}`);
        }
      } else {
        const w = restoreNulls(field, value[key], `${path}.${key}`);
        res.filled.push(...w.filled);
        res.unknown.push(...w.unknown);
        o[key] = w.value;
      }
    }
    res.value = o;
    return res;
  }
  return { value, filled: [], unknown: [] };
}

const read = (name: string): Json => JSON.parse(readFileSync(join(GOLDEN, `${name}.json`), 'utf8')) as Json;
const files = readdirSync(GOLDEN).filter((f) => f.endsWith('.json')).map((f) => f.replace(/\.json$/, '')).sort();
type Obj = Record<string, unknown>;

describe('fredpd_intel golden JSON vs packages/types/src/intel.ts', () => {
  it('has a schema entry for every golden file and a golden file for every entry', () => {
    expect(files).toEqual(Object.keys(SCHEMAS).sort());
  });

  for (const name of files) {
    it(`${name} parses (after restoring Lua's absent nulls) with no unknown keys`, () => {
      const schema = SCHEMAS[name] as Schema;
      const walk = restoreNulls(schema, read(name));
      expect(walk.unknown).toEqual([]);
      const parsed = schema.safeParse(walk.value);
      expect(parsed.success, parsed.success ? '' : JSON.stringify(parsed.error?.issues, null, 2)).toBe(true);
    });
  }

  it('§5.8: the IGV gets a kontaktnotis only (contact of the lead), no link, report or body', () => {
    const igv = read('entity.notice') as Obj;
    expect(igv.links).toEqual([]);
    expect(igv.reports).toEqual([]);
    expect(igv.hiddenLinks).toBe(2); // the Hemlig seen_at link and Utredning's owns link (IGV lacks intel.read)
    const notice = { visibility: 'notice', contact: { displayName: 'Sara S.', unit: 'span' } };
    expect(igv.notices).toEqual([notice]);
    expect(read('mission.notice')).toEqual(notice);
    expect(read('personNotices')).toEqual([notice]);
    expect(JSON.stringify(igv)).not.toContain('Grove');
  });

  it('§5.8: Utredning assigned reads the Hemlig report, mission and links in full', () => {
    const report = read('report.full') as Obj;
    expect(report.visibility).toBe('full');
    expect(report.level).toBe(2);
    expect(report.body).toBe('Sven ses vid Grove Street varje kväll.');
    expect((report.links as unknown[]).length).toBe(1);
    const mission = read('mission.full') as Obj;
    expect((mission.members as Obj[]).map((m) => m.citizenid)).toEqual(['UTR00004']);
    const entity = read('entity.full') as Obj;
    expect(entity.hiddenLinks).toBe(0);
    expect(entity.notices).toEqual([]);
  });

  it('a notice carries only { displayName, unit }', () => {
    for (const name of ['source.notice', 'report.notice', 'mission.notice']) {
      const n = read(name) as Obj;
      expect(Object.keys(n).sort()).toEqual(['contact', 'visibility']);
      expect(Object.keys(n.contact as Obj).sort()).toEqual(['displayName', 'unit']);
    }
  });

  it('real identity only in the handler view; masked sources have no handler or notes', () => {
    expect((read('source.full') as Obj).realIdentity).toEqual({ citizenid: 'INF00001', name: 'Ingvar Informant' });
    expect(Object.keys(read('source.masked') as Obj).sort()).toEqual(['codename', 'id', 'level', 'reliability', 'status', 'visibility']);
    const list = read('sources.list') as { items: Obj[] };
    expect(list.items[0]?.realIdentity).toBeUndefined();
  });

  it('graph: root flagged once, edges only between nodes, within the cap', () => {
    const g = read('graph.depth2') as { nodes: { id: number; root: boolean }[]; edges: { from: number; to: number }[]; truncated: boolean };
    expect(g.nodes.filter((n) => n.root).length).toBe(1);
    expect(g.nodes[0]?.root).toBe(true);
    expect(g.nodes.length).toBeLessThanOrEqual(GRAPH_NODE_CAP);
    const ids = new Set(g.nodes.map((n) => n.id));
    for (const e of g.edges) expect(ids.has(e.from) && ids.has(e.to)).toBe(true);
    expect(g.truncated).toBe(false);
  });

  it('only nullable fields are ever absent (Lua drops nil)', () => {
    for (const name of files) {
      for (const p of restoreNulls(SCHEMAS[name] as Schema, read(name)).filled) {
        expect(p, name).toMatch(/\.(ref|reportId|createdBy|callsign|unit|author|displayName|notes|handler|realIdentity|source|mission|description|lead|reliability|role)$/);
      }
    }
    // A strict consumer without the restore step rejects a keyless entity: the documented integration point.
    expect(INTEL_ACTIONS.ensureEntity.output.safeParse({ id: 1, type: 'group', label: 'Ballas' }).success).toBe(false);
  });
});
