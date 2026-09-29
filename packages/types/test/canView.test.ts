// SPDX-License-Identifier: GPL-3.0-only
// Shared canView fixtures (also run by tests/lua/canview_test.lua), the seed ⇄ fixture drift check,
// and TS-only helper tests.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
  VISIBILITY_RESULTS,
  ViewerSchema,
  VisRecordSchema,
  VisibilityRuleSchema,
  capResult,
  canView,
  visibilityRank,
} from '../src/canView';
import type { VisRecord, VisibilityResult, VisibilityRule, ViewerLike } from '../src/canView';
import fixtures from './fixtures/canView.fixtures.json';

const SEED_PATH = fileURLToPath(new URL('../../../db/seed/visibility_rules_default.sql', import.meta.url));

type FixtureCase = { name: string; viewer: unknown; record: VisRecord; expected: VisibilityResult };
type EngineCase = FixtureCase & { rules: VisibilityRule[] };
/** Input the schemas reject (e.g. DB rows cast without parsing); both ports must fail closed identically. */
type UnvalidatedCase = { name: string; rules: unknown[]; viewer: unknown; record: unknown; expected: VisibilityResult };

// --- Minimal SQL reader for the seed file -------------------------------------------------------------

type Token = { kind: 'word' | 'num' | 'str' | 'punct'; value: string };

function tokenize(sql: string): Token[] {
  const tokens: Token[] = [];
  let i = 0;
  while (i < sql.length) {
    const ch = sql[i] as string;
    if (/\s/.test(ch)) {
      i++;
    } else if (sql.startsWith('--', i)) {
      const end = sql.indexOf('\n', i);
      i = end === -1 ? sql.length : end + 1;
    } else if (ch === "'") {
      let value = '';
      i++;
      for (;;) {
        if (i >= sql.length) throw new Error('unterminated string');
        if (sql[i] === "'" && sql[i + 1] === "'") {
          value += "'";
          i += 2;
        } else if (sql[i] === "'") {
          i++;
          break;
        } else {
          value += sql[i];
          i++;
        }
      }
      tokens.push({ kind: 'str', value });
    } else if (/[-\d]/.test(ch)) {
      const m = /^-?\d+/.exec(sql.slice(i));
      if (!m) throw new Error(`bad number at ${i}`);
      tokens.push({ kind: 'num', value: m[0] });
      i += m[0].length;
    } else if (/[A-Za-z_]/.test(ch)) {
      const m = /^[A-Za-z_][A-Za-z0-9_]*/.exec(sql.slice(i)) as RegExpExecArray;
      tokens.push({ kind: 'word', value: m[0] });
      i += m[0].length;
    } else if ('(),;='.includes(ch)) {
      tokens.push({ kind: 'punct', value: ch });
      i++;
    } else {
      throw new Error(`unexpected ${JSON.stringify(ch)} at ${i}`);
    }
  }
  return tokens;
}

type SqlValue = string | number | null;

/** Parses the single `INSERT INTO t (cols) VALUES (...), ... ON DUPLICATE KEY UPDATE id = id;` statement. */
function parseSeed(sql: string): { table: string; columns: string[]; rows: SqlValue[][] } {
  const tokens = tokenize(sql);
  let p = 0;
  const next = (): Token => {
    const t = tokens[p++];
    if (!t) throw new Error('unexpected end of SQL');
    return t;
  };
  const expect_ = (value: string): void => {
    const t = next();
    if (t.value.toUpperCase() !== value) throw new Error(`expected ${value}, got ${t.value}`);
  };
  const value = (): SqlValue => {
    const t = next();
    if (t.kind === 'str') return t.value;
    if (t.kind === 'num') return Number(t.value);
    if (t.kind === 'word' && t.value.toUpperCase() === 'NULL') return null;
    throw new Error(`unexpected value ${t.value}`);
  };

  expect_('INSERT');
  expect_('INTO');
  const table = next().value;
  expect_('(');
  const columns: string[] = [];
  for (;;) {
    columns.push(next().value);
    const sep = next().value;
    if (sep === ')') break;
    if (sep !== ',') throw new Error(`expected , or ) in column list, got ${sep}`);
  }
  expect_('VALUES');
  const rows: SqlValue[][] = [];
  for (;;) {
    expect_('(');
    const row: SqlValue[] = [];
    for (;;) {
      row.push(value());
      const sep = next().value;
      if (sep === ')') break;
      if (sep !== ',') throw new Error(`expected , or ) in tuple, got ${sep}`);
    }
    rows.push(row);
    const sep = next().value;
    if (sep === ',') continue;
    if (sep.toUpperCase() !== 'ON') throw new Error(`expected , or ON after tuple, got ${sep}`);
    break;
  }
  for (const word of ['DUPLICATE', 'KEY', 'UPDATE', 'ID', '=', 'ID', ';']) expect_(word);
  if (p !== tokens.length) throw new Error('trailing SQL after the INSERT statement');
  return { table, columns, rows };
}

function seedRules(): VisibilityRule[] {
  const { table, columns, rows } = parseSeed(readFileSync(SEED_PATH, 'utf8'));
  expect(table).toBe('fredpd_visibility_rules');
  expect(columns).toEqual([
    'id', 'record_type', 'level', 'record_status', 'viewer_condition', 'condition_value', 'result', 'priority', 'enabled',
  ]);
  return rows.map((row) => {
    expect(row).toHaveLength(columns.length);
    const [id, recordType, level, recordStatus, viewerCondition, conditionValue, result, priority, enabled] = row;
    expect([0, 1]).toContain(enabled);
    return VisibilityRuleSchema.parse({
      id, recordType, level, recordStatus, viewerCondition, conditionValue, result, priority, enabled: enabled === 1,
    });
  });
}

// --- Tests ------------------------------------------------------------------------------------------

const rules = fixtures.rules as VisibilityRule[];
const cases = fixtures.cases as FixtureCase[];
const engineCases = fixtures.engineCases as EngineCase[];
const unvalidatedCases = fixtures.unvalidatedCases as UnvalidatedCase[];

describe('canView default rules', () => {
  it('fixture rules equal db/seed/visibility_rules_default.sql', () => {
    expect(seedRules()).toEqual(rules);
  });

  it('fixture rules are schema-valid with unique ids', () => {
    for (const rule of rules) expect(VisibilityRuleSchema.parse(rule)).toEqual(rule);
    expect(new Set(rules.map((r) => r.id)).size).toBe(rules.length);
  });

  it('the disabled id sentinel 999 is the highest seeded id (admin rules start at 1000)', () => {
    expect(Math.max(...rules.map((r) => r.id))).toBe(999);
    expect(rules.find((r) => r.id === 999)).toMatchObject({ recordType: '*', result: 'none', enabled: false });
  });

  it('has at least 24 cases with unique names', () => {
    expect(cases.length).toBeGreaterThanOrEqual(24);
    expect(new Set(cases.map((c) => c.name)).size).toBe(cases.length);
  });

  it('every fixture viewer is a complete, coherent Viewer (grants.tier/units mirror tier/units)', () => {
    for (const c of [...cases, ...engineCases]) {
      const viewer = ViewerSchema.parse(c.viewer);
      expect(viewer, c.name).toEqual(c.viewer); // nothing defaulted or stripped
      expect(viewer.grants.tier, c.name).toBe(viewer.tier);
      expect(viewer.grants.units, c.name).toEqual(viewer.units);
    }
  });

  for (const c of cases) {
    it(c.name, () => {
      const record = VisRecordSchema.parse(c.record);
      expect(canView(ViewerSchema.parse(c.viewer), record, rules)).toBe(c.expected);
    });
  }
});

describe('canView engine semantics', () => {
  for (const c of engineCases) {
    it(c.name, () => {
      const record = VisRecordSchema.parse(c.record);
      const caseRules = c.rules.map((r) => VisibilityRuleSchema.parse(r));
      expect(canView(ViewerSchema.parse(c.viewer), record, caseRules)).toBe(c.expected);
    });
  }

  it('does not reorder the caller’s rules array', () => {
    const own = [...rules].reverse();
    const before = own.map((r) => r.id);
    canView(ViewerSchema.parse(cases[0]!.viewer), cases[0]!.record, own);
    expect(own.map((r) => r.id)).toEqual(before);
  });
});

describe('canView on unvalidated input (fails closed like the Lua port)', () => {
  for (const c of unvalidatedCases) {
    it(c.name, () => {
      const valid =
        ViewerSchema.safeParse(c.viewer).success &&
        VisRecordSchema.safeParse(c.record).success &&
        c.rules.every((r) => VisibilityRuleSchema.safeParse(r).success);
      expect(valid, 'an unvalidated case must hold at least one schema-invalid value').toBe(false);
      expect(canView(c.viewer as ViewerLike, c.record as VisRecord, c.rules as VisibilityRule[])).toBe(c.expected);
    });
  }

  it('a record without a level is capped like a level-2 record', () => {
    const viewer = ViewerSchema.parse(cases[0]!.viewer); // IGV, tier 0
    const anyFull = { ...(rules[0] as VisibilityRule), recordType: '*', viewerCondition: 'any', result: 'full' } as const;
    const record = { type: 'case', id: 1, status: 'open' } as unknown as VisRecord;
    expect(canView(viewer, record, [anyFull])).toBe('notice');
    expect(canView(viewer, { ...record, level: 0 }, [anyFull])).toBe('full');
  });
});

describe('visibility helpers', () => {
  it('ranks none < notice < masked < full', () => {
    expect(VISIBILITY_RESULTS.map(visibilityRank)).toEqual([0, 1, 2, 3]);
  });

  it('capResult keeps the lower of result and cap', () => {
    expect(capResult('full', 'masked')).toBe('masked');
    expect(capResult('masked', 'notice')).toBe('notice');
    expect(capResult('notice', 'masked')).toBe('notice');
    expect(capResult('none', 'full')).toBe('none');
    expect(capResult('full', 'full')).toBe('full');
  });

  it('rejects malformed rules and records', () => {
    const rule = rules[0] as VisibilityRule;
    // recordType is any 1–32 char string (VARCHAR(32)); an unknown type is valid but never matches.
    expect(VisibilityRuleSchema.safeParse({ ...rule, recordType: 'car' }).success).toBe(true);
    expect(VisibilityRuleSchema.safeParse({ ...rule, recordType: '' }).success).toBe(false);
    expect(VisibilityRuleSchema.safeParse({ ...rule, recordType: 'x'.repeat(33) }).success).toBe(false);
    expect(VisibilityRuleSchema.safeParse({ ...rule, level: 3 }).success).toBe(false);
    expect(VisibilityRuleSchema.safeParse({ ...rule, viewerCondition: 'friend' }).success).toBe(false);
    expect(VisibilityRuleSchema.safeParse({ ...rule, enabled: 1 }).success).toBe(false);
    expect(VisRecordSchema.safeParse({ type: 'case', id: 1, level: 0, status: 'pending' }).success).toBe(false);
  });

  it('seed parser rejects anything but the single INSERT statement', () => {
    expect(() => parseSeed("INSERT INTO t (a) VALUES (1) ON DUPLICATE KEY UPDATE id = id; DELETE FROM t;")).toThrow();
    expect(() => parseSeed("INSERT INTO t (a) VALUES ('x) ON DUPLICATE KEY UPDATE id = id;")).toThrow();
    expect(parseSeed("INSERT INTO t (a, b) VALUES ('it''s', NULL) -- c\nON DUPLICATE KEY UPDATE id = id;").rows).toEqual([
      ["it's", null],
    ]);
  });
});
