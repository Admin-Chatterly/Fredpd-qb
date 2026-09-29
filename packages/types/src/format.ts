// SPDX-License-Identifier: GPL-3.0-only
// Identifier formats, search-type detection and date/time/currency formatting (docs/contracts.md §C4).
// Lua port: resources/[fredpd]/fredpd_core/shared/format.lua (+ shared/regex.lua). Both run
// packages/types/test/fixtures/format.fixtures.json, so keep behaviour, error codes and edge cases in lockstep.
//
// Every function takes an optional trailing `formats`; without it the active formats are used, which default to
// config/formats.json (bundled at build time) until loadFormats() is called with a runtime copy.
import { z } from 'zod';
import defaultFormatsJson from '../../../config/formats.json';

// ---------------------------------------------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------------------------------------------

export type FormatErrorCode =
  | 'unknown_placeholder'
  | 'missing_value'
  | 'invalid_value'
  | 'invalid_template'
  | 'invalid_regex'
  | 'invalid_config';

/** Thrown by every function here. `message` is "<code>: <detail>", the same string the Lua port raises. */
export class FormatError extends Error {
  readonly code: FormatErrorCode;
  constructor(code: FormatErrorCode, detail: string) {
    super(`${code}: ${detail}`);
    this.name = 'FormatError';
    this.code = code;
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Regex subset (must match what shared/regex.lua can run)
// ---------------------------------------------------------------------------------------------------------------

const MAX_REPEAT = 1000;
const CLASS_ESCAPES = new Set(['d', 'D', 's', 'S', 'w', 'W']);
const CONTROL_ESCAPES: Record<string, number> = { t: 9, n: 10, v: 11, f: 12, r: 13 };
const isAlnum = (c: string) => /^[0-9A-Za-z]$/.test(c);

// Native JS `\s` also matches Unicode spaces (U+00A0, U+3000, U+FEFF, ...) and `.` skips U+2028/U+2029, while the
// Lua engine is ASCII-only. The native source is rewritten so both ports agree: `\s` = the six ASCII whitespace
// characters, `.` = anything but \n and \r. `\d` and `\w` are already ASCII-only without the `u` flag.
const ASCII_SPACE = '\\t\\n\\v\\f\\r '; // class body: \t \n \v \f \r and space (isSpace in regex.lua)
const ASCII_NON_SPACE = '\\x00-\\x08\\x0e-\\x1f!-\\uffff'; // class body: every UTF-16 unit not in ASCII_SPACE
const NATIVE_OUTSIDE: Record<string, string> = { s: `[${ASCII_SPACE}]`, S: `[^${ASCII_SPACE}]` };
const NATIVE_IN_CLASS: Record<string, string> = { s: ASCII_SPACE, S: ASCII_NON_SPACE };

/** A parsed atom plus its source text for the native RegExp. */
type Atom = ({ code: number } | { cls: string }) & { src: string };

/**
 * Validate `pattern` against the subset the Lua engine supports and return the equivalent native JS source with
 * the Lua engine's ASCII semantics. Subset: `^ $ .`, `[...]`/`[^...]` with ranges, `\d \D \s \S \w \W`,
 * `\t \n \v \f \r`, escaped punctuation and the quantifiers `? * + {n} {n,} {n,m}` on single characters.
 * Mirrors the parser in shared/regex.lua rule for rule. Throws FormatError('invalid_regex').
 */
function translateRegex(pattern: string): string {
  if (typeof pattern !== 'string') throw new FormatError('invalid_regex', 'pattern must be a string');
  const fail = (detail: string): never => {
    throw new FormatError('invalid_regex', `${detail} in /${pattern}/`);
  };
  const n = pattern.length;

  const parseAtom = (i: number, inClass: boolean): [Atom, number] => {
    const c = pattern[i] as string;
    if (c !== '\\') {
      if (c.charCodeAt(0) >= 128 && inClass) fail('non-ASCII character inside a class');
      // A literal '-' in a class is emitted escaped, so every bare '-' in the native class is a range operator
      // that parseClass wrote itself. Otherwise [\d--a] would become [\d\--a], where native reads '\--a' as a
      // range, and [a-\s-z] would fuse the expanded \s body into ' -z'.
      return [{ code: c.charCodeAt(0), src: inClass && c === '-' ? '\\-' : c }, i + 1];
    }
    const e = pattern[i + 1];
    if (e === undefined) return fail('trailing backslash');
    const src = `\\${e}`;
    if (CLASS_ESCAPES.has(e)) {
      return [{ cls: e, src: (inClass ? NATIVE_IN_CLASS[e] : NATIVE_OUTSIDE[e]) ?? src }, i + 2];
    }
    const ctl = CONTROL_ESCAPES[e];
    if (ctl !== undefined) return [{ code: ctl, src }, i + 2];
    if (isAlnum(e)) fail(`unsupported escape \\${e}`);
    if (e.charCodeAt(0) >= 128) fail('escaped non-ASCII character');
    return [{ code: e.charCodeAt(0), src }, i + 2];
  };

  /** `start` is just after '['. Returns the native class source and the index after ']'. */
  const parseClass = (start: number): [string, number] => {
    let i = start;
    let out = '[';
    if (pattern[i] === '^') {
      out += '^';
      i++;
    }
    while (i < n) {
      if (pattern[i] === ']') return [`${out}]`, i + 1];
      let item: Atom;
      [item, i] = parseAtom(i, true);
      if (pattern[i] === '-' && i + 1 < n && pattern[i + 1] !== ']') {
        const [hi, after] = parseAtom(i + 1, true);
        if ('code' in item && 'code' in hi) {
          if (hi.code < item.code) fail('range out of order in class');
          out += `${item.src}-${hi.src}`;
        } else {
          // A class escape on either side makes '-' literal (JS Annex B): [\d-z] = \d, '-', 'z'. The escaped
          // dash keeps the expanded \s/\S bodies from fusing into an unintended range.
          out += `${item.src}\\-${hi.src}`;
        }
        i = after;
      } else {
        out += item.src;
      }
    }
    return fail('unterminated character class');
  };

  /** [min, max|undefined, next] or undefined when there is no quantifier at i. */
  const parseQuantifier = (i: number): [number, number | undefined, number] | undefined => {
    const c = pattern[i];
    if (c === '*') return [0, undefined, i + 1];
    if (c === '+') return [1, undefined, i + 1];
    if (c === '?') return [0, 1, i + 1];
    if (c !== '{') return undefined;
    const m = /^\{(\d+)(,?)(\d*)\}/.exec(pattern.slice(i));
    if (!m) return fail('invalid quantifier (escape a literal "{" as "\\{")');
    const min = Number(m[1]);
    const max = m[2] === '' ? min : m[3] !== '' ? Number(m[3]) : undefined;
    if (min > MAX_REPEAT || (max !== undefined && max > MAX_REPEAT)) fail('repeat count too large');
    if (max !== undefined && max < min) fail('numbers out of order in {} quantifier');
    return [min, max, i + m[0].length];
  };

  let out = '';
  let i = 0;
  let prevQuantified = false;
  while (i < n) {
    const c = pattern[i] as string;
    let kind: 'assert' | 'char' | 'other';
    let code = 0;
    if (c === '^' || c === '$') {
      kind = 'assert';
      out += c;
      i++;
    } else if (c === '.') {
      kind = 'other';
      out += '[^\\n\\r]';
      i++;
    } else if (c === '[') {
      kind = 'other';
      let cls: string;
      [cls, i] = parseClass(i + 1);
      out += cls;
    } else if (c === '(' || c === ')' || c === '|') {
      return fail('groups and alternation are not supported');
    } else if (c === '*' || c === '+' || c === '?') {
      if (c === '?' && prevQuantified) fail('lazy quantifiers are not supported');
      return fail('nothing to repeat');
    } else if (c === '{') {
      return fail('nothing to repeat (escape a literal "{" as "\\{")');
    } else {
      let atom: Atom;
      [atom, i] = parseAtom(i, false);
      kind = 'code' in atom ? 'char' : 'other';
      if ('code' in atom) code = atom.code;
      out += atom.src;
    }
    const q = parseQuantifier(i);
    if (q) {
      if (kind === 'assert') fail('nothing to repeat');
      if (kind === 'char' && code >= 128) fail('quantifier after a non-ASCII character');
      out += pattern.slice(i, q[2]);
      i = q[2];
    }
    prevQuantified = q !== undefined;
  }
  return out;
}

/** Throw FormatError('invalid_regex') unless `pattern` stays inside the subset shared/regex.lua supports. */
export function assertRegexSubset(pattern: string): void {
  translateRegex(pattern);
}

/**
 * Compile a subset pattern (config/formats.json `plate`/`personId`, or a templateToRegex result) to a native
 * RegExp that matches exactly like the Lua engine on the same string: ASCII-only `\s`, `.` excluding only \n/\r.
 * Prefer this over `new RegExp(...)` wherever NUI/service code must agree with the game.
 */
export function compileFormatRegex(pattern: string): RegExp {
  const source = translateRegex(pattern);
  try {
    return new RegExp(source);
  } catch (e) {
    throw new FormatError('invalid_regex', `${(e as Error).message} in /${pattern}/`);
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Templates
// ---------------------------------------------------------------------------------------------------------------

export const FORMAT_NAMES = ['callsign', 'caseNumber', 'reportNumber', 'evidenceTag'] as const;
export type FormatName = (typeof FORMAT_NAMES)[number];

type Placeholder = 'seq' | 'n' | 'yy' | 'yyyy' | 'unit' | 'case';
type TemplateToken = { literal: string } | { name: Placeholder; width?: number };

const PLACEHOLDERS = new Set<string>(['seq', 'n', 'yy', 'yyyy', 'unit', 'case']);
const COUNTERS = new Set<string>(['seq', 'n']); // placeholders that accept a :width
const MAX_WIDTH = 20;

/** Split a template into literal and placeholder tokens. Throws unknown_placeholder / invalid_template. */
function parseTemplate(template: string): TemplateToken[] {
  if (typeof template !== 'string') throw new FormatError('invalid_template', 'template must be a string');
  const tokens: TemplateToken[] = [];
  const literal = (text: string) => {
    if (text === '') return;
    if (text.includes('{{') || text.includes('}}')) {
      throw new FormatError('invalid_template', `unbalanced braces in "${template}"`);
    }
    tokens.push({ literal: text });
  };
  let pos = 0;
  for (const m of template.matchAll(/\{\{([^{}]*)\}\}/g)) {
    literal(template.slice(pos, m.index));
    const inner = m[1] as string;
    const parsed = /^([a-z]+)(?::(\d+))?$/.exec(inner);
    const name = parsed?.[1];
    const width = parsed?.[2];
    if (!name || !PLACEHOLDERS.has(name) || (width !== undefined && !COUNTERS.has(name))) {
      throw new FormatError('unknown_placeholder', `{{${inner}}} in "${template}"`);
    }
    const token: TemplateToken = { name: name as Placeholder };
    if (width !== undefined) {
      const w = Number(width);
      if (w < 1 || w > MAX_WIDTH) {
        throw new FormatError('invalid_template', `width must be 1..${MAX_WIDTH} in {{${inner}}}`);
      }
      token.width = w;
    }
    tokens.push(token);
    pos = m.index + m[0].length;
  }
  literal(template.slice(pos));
  return tokens;
}

const escapeRegex = (text: string) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** Regex body (no anchors); caseBody is the caseNumber body used for {{case}}. */
function templateBody(tokens: TemplateToken[], caseBody: string | undefined): string {
  return tokens
    .map((tok) => {
      if ('literal' in tok) return escapeRegex(tok.literal);
      switch (tok.name) {
        case 'seq':
        case 'n':
          return tok.width ? `\\d{${tok.width},}` : '\\d+';
        case 'yy':
          return '\\d{2}';
        case 'yyyy':
          return '\\d{4}';
        case 'unit':
          return '[A-Z]+';
        case 'case':
          if (caseBody === undefined) throw new FormatError('invalid_template', 'caseNumber cannot contain {{case}}');
          return caseBody;
      }
    })
    .join('');
}

// ---------------------------------------------------------------------------------------------------------------
// Config schema
// ---------------------------------------------------------------------------------------------------------------

/**
 * Time zones both ports can convert to. The Lua port has no tz database and applies the EU DST rule to these
 * (see TIME_ZONES in format.lua), so a zone outside this list would silently differ between NUI and game.
 */
export const SUPPORTED_TIME_ZONES = [
  'Europe/Stockholm',
  'Europe/Oslo',
  'Europe/Copenhagen',
  'Europe/Berlin',
  'Europe/Helsinki',
  'Europe/London',
  'UTC',
] as const;
export type SupportedTimeZone = (typeof SUPPORTED_TIME_ZONES)[number];

/** Adds a zod issue when fn throws. */
const validWith = (fn: (v: string) => unknown) => (v: string, ctx: z.RefinementCtx) => {
  try {
    fn(v);
  } catch (e) {
    ctx.addIssue({ code: 'custom', message: (e as Error).message });
  }
};

const TemplateSchema = z.string().min(1).superRefine(validWith(parseTemplate));
const PatternSchema = z.string().min(1).superRefine(validWith(compileFormatRegex));

/** config/formats.json. Unknown keys (e.g. "$comment") are stripped. */
export const FormatsSchema = z
  .object({
    callsign: TemplateSchema,
    caseNumber: TemplateSchema,
    reportNumber: TemplateSchema,
    evidenceTag: TemplateSchema,
    plate: PatternSchema,
    personId: PatternSchema,
    date: z.string().min(1),
    time: z.string().min(1),
    tz: z.enum(SUPPORTED_TIME_ZONES),
    currency: z.object({
      symbol: z.string(),
      decimals: z.number().int().min(0).max(6),
      thousandsSeparator: z.string(),
      decimalSeparator: z.string().default(','),
      position: z.enum(['prefix', 'suffix']),
    }),
  })
  .superRefine((f, ctx) => {
    if (/\{\{case\}\}/.test(f.caseNumber)) {
      ctx.addIssue({ code: 'custom', path: ['caseNumber'], message: 'caseNumber cannot contain {{case}}' });
    }
  });

export type Formats = z.output<typeof FormatsSchema>;

interface Compiled {
  formats: Formats;
  patterns: Record<FormatName, string>;
  plate: RegExp;
  personId: RegExp;
  caseNumber: RegExp;
}

// Keyed by object identity: a formats object is treated as immutable once it has been passed in. The normalised
// object that loadFormats/getFormats return is frozen; a caller-supplied object must not be mutated afterwards.
const compiledCache = new WeakMap<object, Compiled>();

function compile(input: unknown): Compiled {
  if (typeof input === 'object' && input !== null) {
    const hit = compiledCache.get(input);
    if (hit) return hit;
  }
  const res = FormatsSchema.safeParse(input);
  if (!res.success) {
    const detail = res.error.issues.map((i) => `${i.path.join('.') || '(root)'}: ${i.message}`).join('; ');
    throw new FormatError('invalid_config', detail);
  }
  const formats = res.data;
  Object.freeze(formats.currency);
  Object.freeze(formats);
  const patterns = {} as Record<FormatName, string>;
  try {
    const caseBody = templateBody(parseTemplate(formats.caseNumber), undefined);
    for (const name of FORMAT_NAMES) {
      patterns[name] = `^${templateBody(parseTemplate(formats[name]), caseBody)}$`;
      compileFormatRegex(patterns[name]); // compiled once here (IMPLEMENTATION.md §4.8)
    }
  } catch (e) {
    throw new FormatError('invalid_config', (e as Error).message);
  }
  const entry: Compiled = {
    formats,
    patterns,
    plate: compileFormatRegex(formats.plate),
    personId: compileFormatRegex(formats.personId),
    caseNumber: compileFormatRegex(patterns.caseNumber),
  };
  if (typeof input === 'object' && input !== null) compiledCache.set(input, entry);
  compiledCache.set(formats, entry);
  return entry;
}

let active: Compiled | undefined;

/** Active compiled formats; lazily loads the bundled config/formats.json so importing never throws. */
function resolve(formats?: Formats): Compiled {
  if (formats !== undefined) return compile(formats);
  active ??= compile(defaultFormatsJson);
  return active;
}

/** Validate a decoded config/formats.json, make it the default for every function and return it. */
export function loadFormats(json: unknown): Formats {
  active = compile(json);
  return active.formats;
}

/** The active formats (bundled config/formats.json unless loadFormats was called). */
export function getFormats(): Formats {
  return resolve().formats;
}

// ---------------------------------------------------------------------------------------------------------------
// Dates: parse to UTC epoch seconds ourselves (no local-time Date parsing), render with Intl in formats.tz
// ---------------------------------------------------------------------------------------------------------------

/** Days since 1970-01-01 for a proleptic Gregorian date (same algorithm as the Lua port). */
function daysFromCivil(y: number, m: number, d: number): number {
  const yy = m <= 2 ? y - 1 : y;
  const era = Math.floor(yy / 400);
  const yoe = yy - era * 400;
  const mp = (m + 9) % 12;
  const doy = Math.floor((153 * mp + 2) / 5) + d - 1;
  const doe = yoe * 365 + Math.floor(yoe / 4) - Math.floor(yoe / 100) + doy;
  return era * 146097 + doe - 719468;
}

const daysInMonth = (y: number, m: number) =>
  m === 2 ? (y % 4 === 0 && (y % 100 !== 0 || y % 400 === 0) ? 29 : 28) : [4, 6, 9, 11].includes(m) ? 30 : 31;

// Accepted instants: 1900-01-01T00:00:00Z .. 9999-12-31T23:59:59Z. Outside that, Intl throws (beyond ±8.64e15 ms)
// or applies local mean time, and the Lua port would overflow or disagree, so both ports reject with invalid_value.
// Inside the range the ports agree on instants only from 1996 on: Intl applies the real pre-1996 DST history, the
// Lua port the EU rule. Date-only strings (dates of birth) render the same date in both for every year.
const MIN_EPOCH_SECONDS = daysFromCivil(1900, 1, 1) * 86400;
const MAX_EPOCH_SECONDS = daysFromCivil(10000, 1, 1) * 86400 - 1;

/** Range check shared by both input forms. */
function inRange(t: number, what: string): number {
  if (!(t >= MIN_EPOCH_SECONDS && t <= MAX_EPOCH_SECONDS)) {
    throw new FormatError('invalid_value', `${what} is outside 1900-01-01..9999-12-31 UTC`);
  }
  return t;
}

const ISO_RE = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?)?$/;

/** An instant: ISO-8601 string (Z/±HH:MM/±HHMM; no offset = UTC; date-only = UTC midnight), epoch ms, or Date. */
export type Instant = string | number | Date;

/** UTC epoch seconds (floored), within 1900..9999. Throws missing_value / invalid_value. */
function toEpochSeconds(value: Instant | null | undefined, what: string): number {
  if (value === undefined || value === null) throw new FormatError('missing_value', `no value for ${what}`);
  if (value instanceof Date) value = value.getTime();
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new FormatError('invalid_value', `${what} is not a finite number`);
    return inRange(Math.floor(value / 1000), what);
  }
  if (typeof value !== 'string') throw new FormatError('invalid_value', `${what} must be an ISO string or epoch ms`);
  const m = ISO_RE.exec(value);
  const bad = () => new FormatError('invalid_value', `${what} is not a valid ISO-8601 date: ${value}`);
  if (!m) throw bad();
  const [y, mo, d, h, mi, s] = [m[1], m[2], m[3], m[4], m[5], m[6]].map((v) => Number(v ?? 0)) as [
    number, number, number, number, number, number,
  ];
  let offset = 0;
  const zone = m[7];
  if (zone && zone !== 'Z') {
    const oh = Number(zone.slice(1, 3));
    const om = Number(zone.slice(-2));
    if (oh > 23 || om > 59) throw bad();
    offset = (oh * 60 + om) * (zone[0] === '-' ? -1 : 1);
  }
  if (mo < 1 || mo > 12 || d < 1 || d > daysInMonth(y, mo) || h > 23 || mi > 59 || s > 59) throw bad();
  return inRange(daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s - offset * 60, what);
}

interface ZonedParts { year: number; month: number; day: number; hour: number; minute: number; second: number }

const dtfCache = new Map<string, Intl.DateTimeFormat>();

function zonedParts(epochSeconds: number, tz: string): ZonedParts {
  let dtf = dtfCache.get(tz);
  if (!dtf) {
    dtf = new Intl.DateTimeFormat('en-US', {
      timeZone: tz, hourCycle: 'h23', numberingSystem: 'latn',
      year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit',
    });
    dtfCache.set(tz, dtf);
  }
  const out: ZonedParts = { year: 0, month: 0, day: 0, hour: 0, minute: 0, second: 0 };
  for (const p of dtf.formatToParts(epochSeconds * 1000)) {
    if (p.type in out) out[p.type as keyof ZonedParts] = Number(p.value);
  }
  return out;
}

const pad2 = (v: number) => String(v).padStart(2, '0');

function renderTokens(pattern: string, p: ZonedParts): string {
  const values: Record<string, string> = {
    YYYY: String(p.year).padStart(4, '0'), YY: pad2(p.year % 100), MM: pad2(p.month), DD: pad2(p.day),
    HH: pad2(p.hour), mm: pad2(p.minute), ss: pad2(p.second),
  };
  return pattern.replace(/YYYY|YY|MM|DD|HH|mm|ss/g, (tok) => values[tok] as string);
}

// ---------------------------------------------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------------------------------------------

/** Values for formatId. `date` feeds {{yy}}/{{yyyy}} (year in formats.tz). */
export interface FormatIdContext {
  seq?: number | string;
  n?: number | string;
  unit?: string;
  case?: string;
  date?: Instant;
}

function counterString(v: unknown, name: string): string {
  if (v === undefined || v === null) throw new FormatError('missing_value', `no value for {{${name}}}`);
  if (typeof v === 'string' && /^\d+$/.test(v)) return v;
  if (typeof v === 'number' && Number.isSafeInteger(v) && v >= 0) return String(v);
  throw new FormatError('invalid_value', `{{${name}}} must be a non-negative integer`);
}

/** Fill a template, e.g. formatId('K-{{seq}}-{{yy}}', { seq: 123, date }) → 'K-123-26'. */
export function formatId(template: string, context?: FormatIdContext | null, formats?: Formats): string {
  const tokens = parseTemplate(template);
  // null/undefined behave like Lua's nil; anything else that is not an object (5, false, 'x') is rejected, as in Lua.
  if (context !== null && context !== undefined && typeof context !== 'object') {
    throw new FormatError('invalid_value', 'ctx must be an object (table)');
  }
  const ctx: FormatIdContext = context ?? {};
  let parts: ZonedParts | undefined; // computed on the first {{yy}}/{{yyyy}}
  return tokens
    .map((tok) => {
      if ('literal' in tok) return tok.literal;
      switch (tok.name) {
        case 'seq':
        case 'n': {
          const s = counterString(ctx[tok.name], tok.name);
          return tok.width ? s.padStart(tok.width, '0') : s;
        }
        case 'unit': {
          const v: unknown = ctx.unit;
          if (v === undefined || v === null || v === '') throw new FormatError('missing_value', 'no value for {{unit}}');
          if (typeof v !== 'string' || !/^[A-Z]+$/.test(v)) {
            throw new FormatError('invalid_value', '{{unit}} must be upper-case letters A-Z (the unit callsign prefix)');
          }
          return v;
        }
        case 'case': {
          const v: unknown = ctx.case;
          if (v === undefined || v === null || v === '') throw new FormatError('missing_value', 'no value for {{case}}');
          if (typeof v !== 'string') throw new FormatError('invalid_value', '{{case}} must be a string');
          return v;
        }
        case 'yy':
        case 'yyyy': {
          parts ??= zonedParts(toEpochSeconds(ctx.date, 'date'), resolve(formats).formats.tz);
          return tok.name === 'yyyy' ? String(parts.year).padStart(4, '0') : pad2(parts.year % 100);
        }
      }
    })
    .join('');
}

/** Anchored pattern string for callsign / caseNumber / reportNumber / evidenceTag (subset-safe for Lua). */
export function templateToRegex(name: FormatName, formats?: Formats): string {
  const { patterns } = resolve(formats);
  // Whitelist check first: `patterns` is a plain object, so 'toString' or '__proto__' would hit Object.prototype.
  if (!(FORMAT_NAMES as readonly string[]).includes(name)) {
    throw new FormatError('invalid_value', `unknown format name ${String(name)}`);
  }
  return patterns[name];
}

export type DetectedSearchType = 'plate' | 'caseNumber' | 'personId' | 'name';
export interface SearchDetection { type: DetectedSearchType; normalized: string }

// ASCII whitespace/case only, so the result is byte-identical to the Lua port.
// Non-ASCII characters that JS `\s` would match (Zs, U+2028/U+2029, U+FEFF), folded to ' ' before anything else so a
// pasted NBSP or ideographic space behaves like a space. Same list as UNICODE_SPACES in format.lua.
const UNICODE_SPACES = /[\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]/g;
const trimAscii = (s: string) => s.replace(/^[ \t\n\r\f\v]+|[ \t\n\r\f\v]+$/g, '');
const upperAscii = (s: string) => s.replace(/[a-z]/g, (c) => c.toUpperCase());

/**
 * Classify a search query. Unicode spaces are folded to ' ', then the query is trimmed. Order: caseNumber (as typed,
 * then upper-cased), personId, plate, name.
 */
export function detectSearchType(query: string, formats?: Formats): SearchDetection {
  if (typeof query !== 'string') throw new FormatError('invalid_value', 'query must be a string');
  const c = resolve(formats);
  const q = trimAscii(query.replace(UNICODE_SPACES, ' '));
  const upper = upperAscii(q);
  if (c.caseNumber.test(q)) return { type: 'caseNumber', normalized: q };
  if (c.caseNumber.test(upper)) return { type: 'caseNumber', normalized: upper };
  if (c.personId.test(q)) {
    const digits = q.replace(/\D/g, '');
    return { type: 'personId', normalized: digits.length > 4 ? `${digits.slice(0, -4)}-${digits.slice(-4)}` : digits };
  }
  if (c.plate.test(upper)) return { type: 'plate', normalized: upper.replace(/[ \t\n\r\f\v]/g, '') };
  return { type: 'name', normalized: q.replace(/[ \t\n\r\f\v]+/g, ' ') };
}

/** Date of an instant in formats.tz, rendered with formats.date (tokens YYYY YY MM DD HH mm ss). */
export function formatDate(iso: Instant, formats?: Formats): string {
  const { formats: f } = resolve(formats);
  return renderTokens(f.date, zonedParts(toEpochSeconds(iso, 'date'), f.tz));
}

/** Time of an instant in formats.tz, rendered with formats.time. */
export function formatTime(iso: Instant, formats?: Formats): string {
  const { formats: f } = resolve(formats);
  return renderTokens(f.time, zonedParts(toEpochSeconds(iso, 'time'), f.tz));
}

// Replacer function, not a string: a separator such as '$&' must be inserted literally.
const groupThousands = (digits: string, sep: string) => digits.replace(/\B(?=(\d{3})+$)/g, () => sep);

/**
 * Money per formats.currency: rounded half away from zero to `decimals`, thousands grouped, symbol as suffix
 * ("1 234 kr") or prefix ("€1 234"); negative amounts get a leading '-'. Same arithmetic as the Lua port.
 */
export function formatCurrency(amount: number, formats?: Formats): string {
  const { currency: cur } = resolve(formats).formats;
  if (typeof amount !== 'number' || !Number.isFinite(amount)) {
    throw new FormatError('invalid_value', 'amount must be a finite number');
  }
  const factor = 10 ** cur.decimals;
  const scaled = Math.floor(Math.abs(amount) * factor + 0.5);
  if (scaled > Number.MAX_SAFE_INTEGER) throw new FormatError('invalid_value', 'amount too large');
  let s = groupThousands(String(Math.floor(scaled / factor)), cur.thousandsSeparator);
  if (cur.decimals > 0) s += cur.decimalSeparator + String(scaled % factor).padStart(cur.decimals, '0');
  if (cur.symbol !== '') s = cur.position === 'suffix' ? `${s} ${cur.symbol}` : `${cur.symbol}${s}`;
  return amount < 0 && scaled > 0 ? `-${s}` : s;
}
