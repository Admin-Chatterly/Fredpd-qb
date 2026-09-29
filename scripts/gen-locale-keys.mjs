#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-only
// Generates packages/types/src/locale-keys.ts from locales/sv.json (docs/contracts.md §C8).
//
//   node scripts/gen-locale-keys.mjs            write the file (left untouched when already current)
//   node scripts/gen-locale-keys.mjs --check    write nothing; exit 1 when the file is missing or stale, or when
//                                               a locale file is not in canonical form (sorted, 2-space, LF)
//   --root <dir>                                repository root (default: the parent of scripts/)
//
// Before generating it validates both locale files (flat string maps, no duplicate keys, key shape, identical key
// sets, identical placeholders per key, no stray braces), so a broken locale fails here instead of in Lua or the NUI.
// The helpers are exported for scripts/merge-pending-locales.mjs; importing this file has no side effects.
import { existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

export const LANGS = /** @type {const} */ (['sv', 'en']);
/** First segment lowercase, at least two segments (docs/modules/locales.md). */
export const KEY_PATTERN = /^[a-z0-9]+(\.[a-zA-Z0-9_]+)+$/;
/** A named placeholder: `{name}`. */
export const PLACEHOLDER_PATTERN = /\{([a-zA-Z][a-zA-Z0-9_]*)\}/g;
export const OUTPUT_PATH = join('packages', 'types', 'src', 'locale-keys.ts');

export class LocaleError extends Error {
  /** @param {string} message @param {string[]} [problems] */
  constructor(message, problems = []) {
    super(problems.length ? `${message}\n  - ${problems.join('\n  - ')}` : message);
    this.name = 'LocaleError';
    this.problems = problems;
  }
}

/** `path` relative to `root` with forward slashes, for messages that must read the same on Windows. */
export function displayPath(root, path) {
  return relative(root, path).split(sep).join('/');
}

/** Code-unit order, identical on every platform and Node version (no localeCompare). */
export function byCodeUnit(a, b) {
  return a < b ? -1 : a > b ? 1 : 0;
}

export function isPlainObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/** Sorted, de-duplicated placeholder names used in `text`. */
export function placeholdersOf(text) {
  return [...new Set([...text.matchAll(PLACEHOLDER_PATTERN)].map((m) => m[1]))].sort(byCodeUnit);
}

/** Problems with one translated string (empty list = fine). */
export function textProblems(text) {
  const problems = [];
  if (text.trim() === '') return ['is empty'];
  if (text !== text.trim()) problems.push('has leading or trailing whitespace');
  if (text.replace(PLACEHOLDER_PATTERN, '').match(/[{}]/)) problems.push('has a brace that is not a {placeholder}');
  // ox_lib's locale loader expands ${other.key} references; FredPD does not use them.
  if (text.includes('${')) problems.push('contains "${" (ox_lib would treat it as a key reference)');
  return problems;
}

/** Keys that are also a dotted prefix of another key ("a.b" next to "a.b.c"); these block a nested export. */
export function prefixCollisions(keys) {
  const prefixes = new Set();
  for (const key of keys) {
    const parts = key.split('.');
    for (let i = 1; i < parts.length; i++) prefixes.add(parts.slice(0, i).join('.'));
  }
  return keys.filter((key) => prefixes.has(key)).sort(byCodeUnit);
}

/**
 * Object keys that occur more than once in `text`, at any depth. JSON.parse silently keeps the last one (and a
 * reviver only sees the result), while ox_lib's json.decode may keep either, so a duplicate is always an error.
 * Each entry is the key's path, JSON-quoted and joined with " > ": `"common.save"` at the top level,
 * `"bolo.hit" > "sv"` one level down. Only valid for text that already parsed as JSON: the scan then needs just
 * the strings and the structural characters, and a string is always consumed whole, so braces or escaped quotes
 * inside a value cannot shift it.
 */
export function duplicateKeys(text) {
  const found = new Set();
  /** Open containers, innermost last. `keys` is null for an array; `path` is where the container sits. */
  const stack = [];
  let expectKey = false;
  let lastKey = '';
  for (const [token] of text.matchAll(/"(?:[^"\\]|\\.)*"|[{}[\]:,]/g)) {
    const top = stack.at(-1);
    if (token === '{' || token === '[') {
      const path = top ? [...top.path, top.keys ? lastKey : '[]'] : [];
      stack.push({ keys: token === '{' ? new Set() : null, path });
      expectKey = token === '{';
    } else if (token === '}' || token === ']') {
      stack.pop();
      expectKey = false;
    } else if (token === ',') {
      expectKey = Boolean(top?.keys);
    } else if (token === ':') {
      expectKey = false;
    } else if (expectKey) {
      // A string right after "{" or "," inside an object is a key; any other string is a value.
      lastKey = JSON.parse(token);
      if (top.keys.has(lastKey)) found.add([...top.path, lastKey].map((k) => JSON.stringify(k)).join(' > '));
      else top.keys.add(lastKey);
      expectKey = false;
    }
  }
  return [...found].sort(byCodeUnit);
}

/** Reads locales/<lang>.json as a flat string map. `optional` returns {} for a missing file. */
export function readLocale(root, lang, { optional = false } = {}) {
  return readLocaleFile(root, lang, { optional }).locale;
}

/**
 * Like readLocale, but also returns the raw text (LF-normalised; null for a missing optional file).
 * Throws LocaleError for invalid JSON, a non-flat object or duplicate keys.
 */
export function readLocaleFile(root, lang, { optional = false } = {}) {
  const path = join(root, 'locales', `${lang}.json`);
  const rel = displayPath(root, path);
  if (!existsSync(path)) {
    if (optional) return { locale: {}, text: null };
    throw new LocaleError(`${rel} does not exist`);
  }
  const text = readFileSync(path, 'utf8').replace(/\r\n/g, '\n');
  let data;
  try {
    data = JSON.parse(text);
  } catch (err) {
    throw new LocaleError(`${rel} is not valid JSON: ${err.message}`);
  }
  if (!isPlainObject(data)) throw new LocaleError(`${rel} must be a JSON object`);
  const bad = Object.entries(data).filter(([, v]) => typeof v !== 'string').map(([k]) => `${k}: value is not a string`);
  if (bad.length) throw new LocaleError(`${rel} must be flat (key -> string)`, bad);
  const dups = duplicateKeys(text);
  if (dups.length) {
    throw new LocaleError(`${rel} has duplicate keys; keep one text per key`, dups);
  }
  return { locale: /** @type {Record<string, string>} */ (data), text };
}

/** Every problem across the locale set `{ sv, en }`; empty list = valid. */
export function validateLocales(locales) {
  const problems = [];
  const [base, ...others] = LANGS;
  const baseKeys = Object.keys(locales[base]);
  for (const lang of LANGS) {
    for (const [key, text] of Object.entries(locales[lang])) {
      if (!KEY_PATTERN.test(key)) problems.push(`${lang}: key "${key}" does not match ${KEY_PATTERN}`);
      for (const p of textProblems(text)) problems.push(`${lang}: "${key}" ${p}`);
    }
  }
  for (const lang of others) {
    const keys = new Set(Object.keys(locales[lang]));
    for (const key of baseKeys) if (!keys.has(key)) problems.push(`${lang}: missing key "${key}" (present in ${base})`);
    for (const key of keys) if (!(key in locales[base])) problems.push(`${base}: missing key "${key}" (present in ${lang})`);
    for (const key of baseKeys) {
      if (!keys.has(key)) continue;
      const a = placeholdersOf(locales[base][key]).join(', ');
      const b = placeholdersOf(locales[lang][key]).join(', ');
      if (a !== b) problems.push(`"${key}": placeholders differ (${base}: [${a}], ${lang}: [${b}])`);
    }
  }
  for (const key of prefixCollisions(baseKeys)) problems.push(`"${key}" is both a key and a prefix of other keys`);
  return problems;
}

/** Canonical file content: keys sorted, 2-space indent, trailing newline. */
export function serializeLocale(locale) {
  const sorted = Object.fromEntries(Object.keys(locale).sort(byCodeUnit).map((k) => [k, locale[k]]));
  return `${JSON.stringify(sorted, null, 2)}\n`;
}

/** The TypeScript source for packages/types/src/locale-keys.ts. Deterministic for a given locale. */
export function renderLocaleKeys(locale) {
  const keys = Object.keys(locale).sort(byCodeUnit);
  const withVars = keys
    .map((key) => [key, placeholdersOf(locale[key])])
    .filter(([, names]) => names.length > 0);
  const lines = [
    '// SPDX-License-Identifier: GPL-3.0-only',
    '// Generated by scripts/gen-locale-keys.mjs from locales/sv.json. Do not edit: change the locale files (or add',
    '// locales/pending/<module>.json and run scripts/merge-pending-locales.mjs), then run `pnpm gen:locale-keys`.',
    '',
    `/** Every key in locales/sv.json and locales/en.json (${keys.length}), in code-unit order. */`,
    'export const LOCALE_KEYS = [',
    ...keys.map((key) => `  '${key}',`),
    '] as const;',
    '',
    '/** A key present in both locale files. `t()` (TS) and `L()` (Lua) take one of these. */',
    'export type LocaleKey = (typeof LOCALE_KEYS)[number];',
    '',
    '/** The named `{placeholders}` of every key that has any. Keys without placeholders are absent. */',
    ...(withVars.length === 0
      ? ['export type LocalePlaceholders = Record<never, never>;']
      : [
          'export type LocalePlaceholders = {',
          ...withVars.map(([key, names]) => `  '${key}': ${names.map((n) => `'${n}'`).join(' | ')};`),
          '};',
        ]),
    '',
    '/** The values a key needs: exactly its placeholders, or nothing for a key without any. */',
    'export type LocaleVars<K extends LocaleKey> = K extends keyof LocalePlaceholders',
    '  ? { [P in LocalePlaceholders[K]]: string | number }',
    '  : Record<string, never>;',
    '',
    '/** Rest parameters for `t(key, ...args)`: the vars object is required exactly when the key has placeholders. */',
    'export type LocaleArgs<K extends LocaleKey> = K extends keyof LocalePlaceholders',
    '  ? [vars: LocaleVars<K>]',
    '  : [vars?: Record<string, never>];',
    '',
    'const LOCALE_KEY_SET: ReadonlySet<string> = new Set<string>(LOCALE_KEYS);',
    '',
    '/** Narrows a runtime string (for example `audit.action.${action}`) to a LocaleKey. */',
    'export function isLocaleKey(value: string): value is LocaleKey {',
    '  return LOCALE_KEY_SET.has(value);',
    '}',
    '',
  ];
  return lines.join('\n');
}

/**
 * Validates the locales and writes (or, with `check`, compares) locale-keys.ts.
 * Returns `{ path, changed, nonCanonical }`: `changed` means written (or, with `check`, stale); `nonCanonical`
 * lists the locale files whose text is not exactly serializeLocale() of their content (unsorted, reformatted).
 * Throws LocaleError when invalid (including duplicate keys).
 */
export function generateLocaleKeys({ root, check = false }) {
  const files = Object.fromEntries(LANGS.map((lang) => [lang, readLocaleFile(root, lang)]));
  const locales = Object.fromEntries(LANGS.map((lang) => [lang, files[lang].locale]));
  const problems = validateLocales(locales);
  if (problems.length) throw new LocaleError('locales/*.json are invalid', problems);
  // POSIX-style names, so the message reads the same on the Windows host.
  const nonCanonical = LANGS.filter((lang) => files[lang].text !== serializeLocale(locales[lang])).map(
    (lang) => `locales/${lang}.json`,
  );
  const path = join(root, OUTPUT_PATH);
  const next = renderLocaleKeys(locales.sv);
  // Compare with normalised line endings so a CRLF checkout on the Windows host is not reported as stale.
  const current = existsSync(path) ? readFileSync(path, 'utf8').replace(/\r\n/g, '\n') : null;
  const changed = current !== next;
  if (changed && !check) {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, next);
  }
  return { path, changed, nonCanonical };
}

/** Minimal flag parser shared by both scripts: known boolean flags plus `--root <dir>`. */
export function parseArgs(argv, flags) {
  const opts = { root: resolve(dirname(fileURLToPath(import.meta.url)), '..') };
  for (const flag of flags) opts[flag] = false;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--root' && argv[i + 1]) opts.root = resolve(argv[++i]);
    else if (arg.startsWith('--') && flags.includes(arg.slice(2))) opts[arg.slice(2)] = true;
    else throw new LocaleError(`unknown argument "${arg}" (flags: ${flags.map((f) => `--${f}`).join(', ')}, --root <dir>)`);
  }
  return opts;
}

function main() {
  try {
    const opts = parseArgs(process.argv.slice(2), ['check']);
    const { path, changed, nonCanonical } = generateLocaleKeys({ root: opts.root, check: opts.check });
    const rel = displayPath(opts.root, path);
    if (nonCanonical.length) {
      // A hand edit left a locale file unsorted or reformatted. Only --check fails on it; the merge script (with no
      // pending files) rewrites the files in canonical form.
      const message = `${nonCanonical.join(', ')} not in canonical form (sorted keys, 2-space indent, LF, trailing newline). Run \`node scripts/merge-pending-locales.mjs\` to rewrite.`;
      if (opts.check) {
        console.error(message);
        process.exitCode = 1;
      } else {
        console.warn(`Warning: ${message}`);
      }
    }
    if (opts.check && changed) {
      console.error(`${rel} is stale. Run \`pnpm gen:locale-keys\`.`);
      process.exitCode = 1;
    } else if (opts.check) {
      console.log(`${rel} is up to date.`);
    } else {
      console.log(changed ? `Wrote ${rel}.` : `${rel} already up to date.`);
    }
  } catch (err) {
    console.error(err instanceof LocaleError ? err.message : err);
    process.exitCode = 1;
  }
}

/** `path` with symlinks, junctions and subst drives resolved; the plain resolved path when it cannot be resolved. */
function realPath(path) {
  try {
    return realpathSync(path);
  } catch {
    return resolve(path);
  }
}

// Run only when invoked directly (the merge script imports this file). Node realpaths the entry module, so
// import.meta.url never goes through a symlink while process.argv[1] may: compare the real paths of both, or
// `node <symlinked dir>/gen-locale-keys.mjs --check` would silently do nothing and exit 0. Windows paths compare
// case-insensitively.
const self = realPath(fileURLToPath(import.meta.url));
const invoked = process.argv[1] ? realPath(process.argv[1]) : '';
if (process.platform === 'win32' ? invoked.toLowerCase() === self.toLowerCase() : invoked === self) main();
