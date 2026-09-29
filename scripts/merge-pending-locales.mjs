#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-only
// Merges locales/pending/*.json into locales/sv.json + locales/en.json (docs/contracts.md §C8).
//
//   node scripts/merge-pending-locales.mjs [--force] [--dry-run] [--root <dir>]
//
// Pending file shape: { "<key>": { "sv": "…", "en": "…" } }. Top-level keys starting with "$" (e.g. "$comment")
// are ignored. Files are processed in name order. Steps:
//   1. Validate every pending file: no duplicate keys, key shape, both languages present and non-empty, same
//      placeholders.
//   2. Conflicts: a key whose sv or en text differs from locales/*.json, or two pending files that disagree.
//      Conflicts abort the merge unless --force (then the pending text wins; later files win over earlier ones).
//      Identical re-submissions are not conflicts.
//   3. Validate the merged result as a whole (same rules as scripts/gen-locale-keys.mjs).
//   4. Write sv/en in canonical form (sorted keys), regenerate packages/types/src/locale-keys.ts, and only then
//      delete the pending files that were merged. Files added while the script runs are left alone.
// Nothing is written when any step fails. With no pending files it just re-sorts the locale files and regenerates
// the key list, so it doubles as a formatter. --dry-run reports what would happen and writes nothing.
import { existsSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import {
  KEY_PATTERN,
  LANGS,
  LocaleError,
  displayPath,
  duplicateKeys,
  generateLocaleKeys,
  isPlainObject,
  parseArgs,
  placeholdersOf,
  readLocale,
  serializeLocale,
  textProblems,
  validateLocales,
} from './gen-locale-keys.mjs';

/**
 * Reads and validates the pending files. Returns the entries in file order plus any problems.
 * @returns {{ entries: { key: string, file: string, text: Record<string, string> }[], problems: string[] }}
 */
function readPending(pendingDir, files) {
  const entries = [];
  const problems = [];
  for (const file of files) {
    const text = readFileSync(join(pendingDir, file), 'utf8');
    let data;
    try {
      data = JSON.parse(text);
    } catch (err) {
      problems.push(`${file}: not valid JSON (${err.message})`);
      continue;
    }
    // JSON.parse keeps only the last of two equal keys, so the first text would be lost (and its file deleted).
    for (const dup of duplicateKeys(text)) problems.push(`${file}: duplicate key ${dup}; keep one entry per key`);
    if (!isPlainObject(data)) {
      problems.push(`${file}: must be an object of { "<key>": { "sv": "…", "en": "…" } }`);
      continue;
    }
    for (const [key, value] of Object.entries(data)) {
      if (key.startsWith('$')) continue;
      const where = `${file}: "${key}"`;
      if (!KEY_PATTERN.test(key)) problems.push(`${where} does not match ${KEY_PATTERN}`);
      if (!isPlainObject(value)) {
        problems.push(`${where} must be { ${LANGS.map((l) => `"${l}": "…"`).join(', ')} }`);
        continue;
      }
      const extra = Object.keys(value).filter((k) => !LANGS.includes(k));
      if (extra.length) problems.push(`${where} has unknown field(s) ${extra.join(', ')} (allowed: ${LANGS.join(', ')})`);
      let complete = true;
      for (const lang of LANGS) {
        if (typeof value[lang] !== 'string') {
          problems.push(`${where} is missing a "${lang}" string`);
          complete = false;
          continue;
        }
        for (const p of textProblems(value[lang])) problems.push(`${where} ${lang} ${p}`);
      }
      if (!complete) continue;
      const names = LANGS.map((lang) => placeholdersOf(value[lang]).join(', '));
      if (new Set(names).size > 1) {
        problems.push(`${where} placeholders differ (${LANGS.map((l, i) => `${l}: [${names[i]}]`).join(', ')})`);
      }
      entries.push({ key, file, text: Object.fromEntries(LANGS.map((lang) => [lang, value[lang]])) });
    }
  }
  return { entries, problems };
}

function sameText(a, b) {
  return LANGS.every((lang) => a[lang] === b[lang]);
}

function describe(text) {
  return LANGS.map((lang) => `${lang} ${JSON.stringify(text[lang])}`).join(', ');
}

function main() {
  const opts = parseArgs(process.argv.slice(2), ['force', 'dry-run']);
  const { root } = opts;
  const pendingDir = join(root, 'locales', 'pending');
  const files = existsSync(pendingDir)
    ? readdirSync(pendingDir).filter((name) => name.endsWith('.json')).sort()
    : [];

  const locales = Object.fromEntries(LANGS.map((lang) => [lang, readLocale(root, lang, { optional: true })]));
  const { entries, problems } = readPending(pendingDir, files);
  if (problems.length) throw new LocaleError('Pending locale files are invalid; nothing was merged', problems);

  // Conflict detection against the current files and between pending files.
  const conflicts = [];
  /** @type {Map<string, { file: string, text: Record<string, string> }>} */
  const incoming = new Map();
  for (const entry of entries) {
    const earlier = incoming.get(entry.key);
    if (earlier && !sameText(earlier.text, entry.text)) {
      conflicts.push(`"${entry.key}": ${earlier.file} (${describe(earlier.text)}) vs ${entry.file} (${describe(entry.text)})`);
    }
    const existing = Object.fromEntries(LANGS.map((lang) => [lang, locales[lang][entry.key]]));
    const exists = LANGS.some((lang) => existing[lang] !== undefined);
    if (exists && !sameText(existing, entry.text)) {
      conflicts.push(`"${entry.key}": ${entry.file} would change the existing text (${describe(existing)} -> ${describe(entry.text)})`);
    }
    incoming.set(entry.key, { file: entry.file, text: entry.text });
  }
  if (conflicts.length && !opts.force) {
    throw new LocaleError('Conflicting locale texts; nothing was merged (rerun with --force to let pending texts win)', conflicts);
  }
  for (const c of conflicts) console.warn(`overwriting ${c}`);

  let added = 0;
  let updated = 0;
  let unchanged = 0;
  for (const [key, { text }] of incoming) {
    const existed = LANGS.some((lang) => locales[lang][key] !== undefined);
    const same = LANGS.every((lang) => locales[lang][key] === text[lang]);
    if (!existed) added++;
    else if (same) unchanged++;
    else updated++;
    for (const lang of LANGS) locales[lang][key] = text[lang];
  }

  const invalid = validateLocales(locales);
  if (invalid.length) throw new LocaleError('The merged locales would be invalid; nothing was merged', invalid);

  const summary = `${files.length} pending file(s), ${incoming.size} key(s): ${added} added, ${updated} updated, ${unchanged} unchanged`;
  if (opts['dry-run']) {
    console.log(`[dry run] ${summary}. Nothing written.`);
    return;
  }

  for (const lang of LANGS) {
    const path = join(root, 'locales', `${lang}.json`);
    const next = serializeLocale(locales[lang]);
    const current = existsSync(path) ? readFileSync(path, 'utf8').replace(/\r\n/g, '\n') : null;
    if (current !== next) writeFileSync(path, next);
  }
  const keys = generateLocaleKeys({ root });
  for (const file of files) rmSync(join(pendingDir, file));

  console.log(`Merged ${summary}.`);
  console.log(`${displayPath(root, keys.path)} ${keys.changed ? 'regenerated' : 'already up to date'}.`);
}

try {
  main();
} catch (err) {
  console.error(err instanceof LocaleError ? err.message : err);
  process.exitCode = 1;
}
