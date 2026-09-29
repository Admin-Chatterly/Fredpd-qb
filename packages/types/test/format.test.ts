// SPDX-License-Identifier: GPL-3.0-only
// Runs the shared format fixtures (also run by tests/lua/format_test.lua) plus TS-only checks.
import { describe, expect, it } from 'vitest';
import {
  FormatError,
  FormatsSchema,
  assertRegexSubset,
  compileFormatRegex,
  detectSearchType,
  formatCurrency,
  formatDate,
  formatId,
  formatTime,
  getFormats,
  loadFormats,
  templateToRegex,
  type FormatIdContext,
  type FormatName,
  type Formats,
} from '../src/format';
import fixturesJson from './fixtures/format.fixtures.json';
import configFormats from '../../../config/formats.json';

interface FixtureCase {
  name: string;
  fn: 'formatId' | 'templateToRegex' | 'detectSearchType' | 'formatDate' | 'formatTime' | 'formatCurrency' | 'load';
  formats?: Record<string, unknown>;
  format?: string;
  template?: string;
  ctx?: FormatIdContext;
  query?: string;
  input?: string | number;
  expected?: unknown;
  error?: string;
  matches?: string[];
  rejects?: string[];
}
interface RegexCase { pattern: string; yes?: string[]; no?: string[]; error?: boolean }
interface FixtureFile { formats: Record<string, unknown>; cases: FixtureCase[]; regex: RegexCase[] }

const fixtures = fixturesJson as unknown as FixtureFile;

function run(c: FixtureCase): unknown {
  // Shallow merge, exactly like the Lua suite; cast because load cases deliberately pass invalid shapes.
  const formats = { ...fixtures.formats, ...c.formats } as unknown as Formats;
  switch (c.fn) {
    case 'formatId': {
      const template = c.template ?? (fixtures.formats[c.format as string] as string);
      return formatId(template, c.ctx ?? {}, formats);
    }
    case 'templateToRegex':
      return templateToRegex(c.format as FormatName, formats);
    case 'detectSearchType':
      return detectSearchType(c.query as string, formats);
    case 'formatDate':
      return formatDate(c.input as string | number, formats);
    case 'formatTime':
      return formatTime(c.input as string | number, formats);
    case 'formatCurrency':
      return formatCurrency(c.input as number, formats);
    case 'load':
      // Validate without touching the active formats (loadFormats itself is covered below).
      templateToRegex('caseNumber', formats);
      return undefined;
  }
}

describe('format fixtures', () => {
  it('has at least 20 uniquely named cases', () => {
    expect(fixtures.cases.length).toBeGreaterThanOrEqual(20);
    expect(new Set(fixtures.cases.map((c) => c.name)).size).toBe(fixtures.cases.length);
  });

  for (const c of fixtures.cases) {
    it(c.name, () => {
      if (c.error !== undefined) {
        let thrown: unknown;
        try {
          run(c);
        } catch (e) {
          thrown = e;
        }
        expect(thrown).toBeInstanceOf(FormatError);
        expect((thrown as FormatError).code).toBe(c.error);
        expect((thrown as FormatError).message.startsWith(`${c.error}: `)).toBe(true);
        return;
      }
      const result = run(c);
      if (c.expected !== undefined) expect(result).toEqual(c.expected);
      if (c.fn === 'templateToRegex') {
        const re = new RegExp(result as string);
        for (const s of c.matches ?? []) expect(re.test(s), `${String(result)} should match ${s}`).toBe(true);
        for (const s of c.rejects ?? []) expect(re.test(s), `${String(result)} should reject ${s}`).toBe(false);
      }
    });
  }
});

const isAscii = (s: string) => [...s].every((ch) => ch.charCodeAt(0) < 128);

describe('regex subset fixtures (same expectations as the Lua engine)', () => {
  for (const r of fixtures.regex) {
    it(`/${r.pattern}/`, () => {
      if (r.error) {
        expect(() => assertRegexSubset(r.pattern)).toThrow(/^invalid_regex: /);
        expect(() => compileFormatRegex(r.pattern)).toThrow(/^invalid_regex: /);
        return;
      }
      expect(() => assertRegexSubset(r.pattern)).not.toThrow();
      const re = compileFormatRegex(r.pattern);
      // Native RegExp is an independent reference wherever its Unicode \s and `.` cannot differ: ASCII inputs.
      const native = new RegExp(r.pattern);
      const cases = [...(r.yes ?? []).map((s) => [s, true] as const), ...(r.no ?? []).map((s) => [s, false] as const)];
      for (const [s, want] of cases) {
        expect(re.test(s), JSON.stringify(s)).toBe(want);
        if (isAscii(s)) expect(native.test(s), `native ${JSON.stringify(s)}`).toBe(want);
      }
    });
  }
});

describe('format (TS only)', () => {
  it('parses the bundled config/formats.json', () => {
    const parsed = FormatsSchema.parse(configFormats);
    expect(parsed.tz).toBe('Europe/Stockholm');
    expect(parsed.currency.decimalSeparator).toBe(',');
    expect(parsed).not.toHaveProperty('$comment');
  });

  it('defaults to config/formats.json without an explicit formats argument', () => {
    expect(getFormats().caseNumber).toBe(configFormats.caseNumber);
    expect(formatCurrency(1234567)).toBe('1 234 567 kr');
    expect(detectSearchType('abc 12d')).toEqual({ type: 'plate', normalized: 'ABC12D' });
  });

  it('loadFormats replaces the active formats', () => {
    try {
      loadFormats({ ...configFormats, time: 'HH.mm' });
      expect(formatTime('2026-07-01T10:15:00Z')).toBe('12.15');
    } finally {
      loadFormats(configFormats);
    }
    expect(formatTime('2026-07-01T10:15:00Z')).toBe('12:15');
  });

  it('loadFormats reports every zod issue as invalid_config', () => {
    expect(() => loadFormats({ ...configFormats, tz: 'Mars/Olympus' })).toThrow(/^invalid_config: tz: /);
  });

  it('accepts Date objects as instants', () => {
    expect(formatTime(new Date(Date.UTC(2026, 9, 25, 1, 0)))).toBe('02:00');
    expect(formatId('{{yyyy}}', { date: new Date(Date.UTC(2026, 11, 31, 23, 30)) })).toBe('2027');
  });

  it('does not depend on the process time zone for ISO strings without an offset', () => {
    // A naive `new Date('2026-09-29T10:15:00')` would be local time; ours is UTC by contract.
    expect(formatTime('2026-09-29T10:15:00')).toBe(formatTime('2026-09-29T10:15:00Z'));
  });

  it('compileFormatRegex gives \\s and . the Lua engine\'s ASCII semantics', () => {
    expect(compileFormatRegex('^\\s$').source).toBe('^[\\t\\n\\v\\f\\r ]$');
    expect(compileFormatRegex('^\\S.$').source).toBe('^[^\\t\\n\\v\\f\\r ][^\\n\\r]$');
    expect(compileFormatRegex('[^\\S\\d]').source).toBe('[^\\x00-\\x08\\x0e-\\x1f!-\\uffff\\d]');
    expect(compileFormatRegex('[\\s-z]').source).toBe('[\\t\\n\\v\\f\\r \\-z]');
    // A literal '-' is always escaped, so only the translator's own range dashes stay bare.
    expect(compileFormatRegex('[\\d--a]').source).toBe('[\\d\\-\\-a]');
    expect(compileFormatRegex('[a-\\s-z]').source).toBe('[a\\-\\t\\n\\v\\f\\r \\-z]');
    expect(compileFormatRegex('[--/]').source).toBe('[\\--/]');
    // Everything else is passed through unchanged.
    const plate = '^[A-Z]{3}\\s?\\d{2}[A-Z0-9]$';
    expect(compileFormatRegex(plate).source).toBe('^[A-Z]{3}[\\t\\n\\v\\f\\r ]?\\d{2}[A-Z0-9]$');
    expect(compileFormatRegex('^\\d{6,8}-?\\d{4}$').source).toBe('^\\d{6,8}-?\\d{4}$');
    expect(() => compileFormatRegex(5 as unknown as string)).toThrow(/^invalid_regex: /);
  });

  it('formatId treats a null ctx like an empty one', () => {
    expect(formatId('ABC', null)).toBe('ABC');
    expect(formatId('ABC', undefined)).toBe('ABC');
    expect(() => formatId('{{seq}}', null)).toThrow(/^missing_value: /);
  });

  it('formatId rejects a ctx that is not an object, like Lua', () => {
    for (const bad of [5, true, false, 'IGV', () => ({})]) {
      expect(() => formatId('ABC', bad as unknown as FormatIdContext)).toThrow(/^invalid_value: /);
    }
  });

  it('templateToRegex rejects every inherited Object member', () => {
    for (const name of ['toString', 'constructor', 'hasOwnProperty', '__proto__', 'valueOf']) {
      expect(() => templateToRegex(name as FormatName)).toThrow(/^invalid_value: /);
    }
  });

  it('loadFormats returns a frozen object so the identity cache cannot go stale', () => {
    const loaded = loadFormats(configFormats);
    expect(Object.isFrozen(loaded)).toBe(true);
    expect(Object.isFrozen(loaded.currency)).toBe(true);
    expect(getFormats()).toBe(loaded);
  });

  it('out-of-range instants raise FormatError, not RangeError', () => {
    for (const v of [1e300, -1e300, 8.64e15 + 1000, new Date(Number.NaN)]) {
      expect(() => formatDate(v)).toThrow(FormatError);
    }
  });

  it('rejects non-finite currency amounts', () => {
    expect(() => formatCurrency(Number.NaN)).toThrow(/^invalid_value: /);
    expect(() => formatCurrency(Number.POSITIVE_INFINITY)).toThrow(/^invalid_value: /);
  });

  it('matches Intl across the EU DST switch for every year 1996-2040', () => {
    // Independent weekday check: the last Sunday of March/October at 00:59Z and 01:00Z.
    for (let y = 1996; y <= 2040; y++) {
      for (const [month, before, after] of [[3, '01:59', '03:00'], [10, '02:59', '02:00']] as const) {
        const last = new Date(Date.UTC(y, month, 0)); // day 0 of next month = last day of `month`
        const day = last.getUTCDate() - last.getUTCDay();
        const iso = (h: number, m: number) =>
          `${y}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}T${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:00Z`;
        expect(formatTime(iso(0, 59)), iso(0, 59)).toBe(before);
        expect(formatTime(iso(1, 0)), iso(1, 0)).toBe(after);
      }
    }
  });
});
