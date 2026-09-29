// SPDX-License-Identifier: GPL-3.0-only
// Locale integrity (docs/contracts.md §C8, docs/modules/locales.md): sv/en parity, canonical file form, placeholders,
// key shape, the generated key union, unit labels, a key for every DB enum value the UI labels, and the
// pending-merge script run against a throwaway repo root.
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterAll, describe, expect, it } from 'vitest';
import { LOCALE_KEYS, isLocaleKey, type LocaleArgs, type LocaleKey, type LocaleVars } from '../src/locale-keys';

const ROOT = fileURLToPath(new URL('../../../', import.meta.url));
const GEN = join(ROOT, 'scripts', 'gen-locale-keys.mjs');
const MERGE = join(ROOT, 'scripts', 'merge-pending-locales.mjs');
const KEY_PATTERN = /^[a-z0-9]+(\.[a-zA-Z0-9_]+)+$/;
const PLACEHOLDER = /\{([a-zA-Z][a-zA-Z0-9_]*)\}/g;

type Locale = Record<string, string>;

function readJson<T>(path: string): T {
  return JSON.parse(readFileSync(path, 'utf8')) as T;
}

function placeholders(text: string): string[] {
  return [...new Set([...text.matchAll(PLACEHOLDER)].map((m) => m[1] ?? ''))].sort();
}

const byCodeUnit = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);

/** The canonical file text, as serializeLocale() in scripts/gen-locale-keys.mjs writes it. */
function serialize(locale: Locale): string {
  const sorted = Object.fromEntries(Object.keys(locale).sort(byCodeUnit).map((k) => [k, locale[k]]));
  return `${JSON.stringify(sorted, null, 2)}\n`;
}

/** Data value -> key segment (docs/modules/locales.md): strip diacritics, lowercase ('fängelse' -> 'fangelse'). */
const keySegment = (value: string) => value.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase();

/** The values of `<column> ENUM(...)` in `CREATE TABLE IF NOT EXISTS <table> (...)` across db/migrations. */
function enumValues(table: string, column: string): string[] {
  const dir = join(ROOT, 'db', 'migrations');
  for (const file of readdirSync(dir).filter((name) => name.endsWith('.sql')).sort()) {
    const sql = readFileSync(join(dir, file), 'utf8');
    const start = sql.indexOf(`CREATE TABLE IF NOT EXISTS ${table} (`);
    if (start < 0) continue;
    const body = sql.slice(start, sql.indexOf(') ENGINE=', start));
    const match = new RegExp(`^\\s*${column} ENUM\\(([^)]*)\\)`, 'm').exec(body);
    if (!match) throw new Error(`${file}: ${table}.${column} is not an ENUM column`);
    return [...(match[1] ?? '').matchAll(/'([^']*)'/g)].map((m) => m[1] ?? '');
  }
  throw new Error(`db/migrations: table ${table} not found`);
}

const sv = readJson<Locale>(join(ROOT, 'locales', 'sv.json'));
const en = readJson<Locale>(join(ROOT, 'locales', 'en.json'));
const locales: Record<'sv' | 'en', Locale> = { sv, en };

function run(script: string, args: string[]) {
  const r = spawnSync(process.execPath, [script, ...args], { encoding: 'utf8' });
  return { status: r.status, out: `${r.stdout}${r.stderr}` };
}

describe('locales/sv.json and locales/en.json', () => {
  it('are flat objects of strings', () => {
    for (const locale of Object.values(locales)) {
      expect(typeof locale).toBe('object');
      const nonStrings = Object.entries(locale).filter(([, v]) => typeof v !== 'string').map(([k]) => k);
      expect(nonStrings).toEqual([]);
    }
  });

  it('cover the Phase 0–3 namespaces with a substantial key set', () => {
    expect(Object.keys(sv).length).toBeGreaterThanOrEqual(250);
    const namespaces = new Set(Object.keys(sv).map((k) => k.split('.')[0]));
    for (const ns of [
      'common', 'nav', 'unit', 'tablet', 'mdt', 'person', 'vehicle', 'bolo', 'alert', 'case', 'report', 'charge',
      'evidence', 'intel', 'breach', 'visibility', 'level', 'perms', 'officer', 'portal', 'release', 'audit',
      'errors', 'time', 'currency',
    ]) {
      expect(namespaces, ns).toContain(ns);
    }
  });

  it('have identical key sets', () => {
    expect(Object.keys(en).sort()).toEqual(Object.keys(sv).sort());
  });

  it('are stored with sorted keys (run scripts/merge-pending-locales.mjs to re-sort)', () => {
    for (const locale of Object.values(locales)) {
      const keys = Object.keys(locale);
      expect(keys).toEqual([...keys].sort(byCodeUnit));
    }
  });

  it('are stored in canonical form, so no duplicate key hides behind JSON.parse', () => {
    // JSON.parse keeps the last of two equal keys; the re-serialised text then has one entry fewer than the file.
    for (const lang of ['sv', 'en'] as const) {
      const raw = readFileSync(join(ROOT, 'locales', `${lang}.json`), 'utf8').replace(/\r\n/g, '\n');
      expect(raw === serialize(locales[lang]), `locales/${lang}.json is not canonical`).toBe(true);
    }
  });

  it('use dotted keys matching the key pattern', () => {
    const bad = Object.keys(sv).filter((k) => !KEY_PATTERN.test(k));
    expect(bad).toEqual([]);
  });

  it('never use a key as a prefix of another key', () => {
    const keys = Object.keys(sv);
    const prefixes = new Set(keys.flatMap((k) => k.split('.').slice(0, -1).map((_, i, parts) => parts.slice(0, i + 1).join('.'))));
    expect(keys.filter((k) => prefixes.has(k))).toEqual([]);
  });

  it('have no empty or padded strings', () => {
    for (const [lang, locale] of Object.entries(locales)) {
      const bad = Object.entries(locale).filter(([, v]) => v.trim() === '' || v !== v.trim()).map(([k]) => `${lang}:${k}`);
      expect(bad).toEqual([]);
    }
  });

  it('use the same named placeholders per key in both languages', () => {
    const mismatched = Object.keys(sv)
      .filter((k) => en[k] !== undefined)
      .filter((k) => placeholders(sv[k] ?? '').join() !== placeholders(en[k] ?? '').join())
      .map((k) => `${k}: sv [${placeholders(sv[k] ?? '')}] en [${placeholders(en[k] ?? '')}]`);
    expect(mismatched).toEqual([]);
  });

  it('have no stray braces and no ox_lib ${key} references', () => {
    for (const [lang, locale] of Object.entries(locales)) {
      const bad = Object.entries(locale)
        .filter(([, v]) => /[{}]/.test(v.replace(PLACEHOLDER, '')) || v.includes('${'))
        .map(([k]) => `${lang}:${k}`);
      expect(bad).toEqual([]);
    }
  });

  it('keep the texts other modules and the plan quote verbatim', () => {
    expect(sv['alert.assigned']).toBe('Tilldelad: {callsign} · {name}');
    expect(sv['alert.keybind.take']).toBe('Ta larm');
    expect(sv['visibility.notice.text']).toBe('Det finns uppgifter som rör {subject}. Kontakta {owner}.');
    expect(sv['bolo.checkPlate.target']).toBe('Kontrollera registreringsskylt');
    expect(sv['breach.target']).toBe('Forcera dörr');
    expect(sv['evidence.link.action']).toBe('Koppla till ärende');
    expect(sv['release.target']).toBe('Begär ut allmän handling');
    expect([sv['level.standard'], sv['level.begransad'], sv['level.hemlig']]).toEqual(['Standard', 'Begränsad', 'Hemlig']);
    expect(sv['portal.privacy.retention']).toContain('{days}');
  });

  it('have a key for every DB enum value the UI labels (docs/modules/locales.md mapping table)', () => {
    const columns: [table: string, column: string, prefix: string][] = [
      ['fredpd_role_grants', 'grant_type', 'perms.type'],
      ['fredpd_visibility_rules', 'viewer_condition', 'visibility.condition'],
      ['fredpd_visibility_rules', 'result', 'visibility.result'],
      ['fredpd_cases', 'status', 'case.status'],
      ['fredpd_case_assignees', 'role', 'case.assignee.role'],
      ['fredpd_case_subjects', 'subject_type', 'case.subject'],
      ['fredpd_case_subjects', 'role', 'case.subject.role'],
      ['fredpd_charges', 'class', 'charge.class'],
      ['fredpd_records', 'class', 'charge.class'],
      ['fredpd_records', 'status', 'charge.status'],
      ['fredpd_release_requests', 'status', 'release.status'],
      ['fredpd_bolos', 'kind', 'bolo.kind'],
      ['fredpd_alerts', 'status', 'alert.status'],
      ['fredpd_intel_sources', 'status', 'intel.source.status'],
      ['fredpd_intel_sources', 'reliability', 'intel.reliability'],
      ['fredpd_missions', 'status', 'intel.mission.status'],
      ['fredpd_intel_reports', 'status', 'intel.report.status'],
      ['fredpd_intel_entities', 'type', 'intel.entity.type'],
    ];
    const missing: string[] = [];
    for (const [table, column, prefix] of columns) {
      const values = enumValues(table, column);
      expect(values.length, `${table}.${column}`).toBeGreaterThan(0);
      for (const value of values) {
        const key = `${prefix}.${keySegment(value)}`;
        if (!isLocaleKey(key) || en[key] === undefined) missing.push(`${table}.${column} '${value}' -> ${key}`);
      }
    }
    // fredpd_charges.category is a VARCHAR; the keys are listed in 003_records.sql and used by the seed.
    const seed = readFileSync(join(ROOT, 'db', 'seed', 'charges_sv.sql'), 'utf8');
    const categories = new Set(['penal', 'traffic', 'narcotics', 'weapons', 'public_order', 'other']);
    for (const m of seed.matchAll(/^\s*\('[^']*', '([a-z_]+)',/gm)) categories.add(m[1] ?? '');
    for (const category of categories) {
      if (!isLocaleKey(`charge.category.${category}`)) missing.push(`charges category '${category}'`);
    }
    // alert priority and person gender (TINYINT) and qbx licence types have fixed mappings.
    for (const key of [
      'alert.priority.high', 'alert.priority.normal', 'alert.priority.low',
      'person.gender.male', 'person.gender.female', 'person.gender.unknown',
    ]) {
      if (!isLocaleKey(key)) missing.push(key);
    }
    for (const type of ['driver', 'weapon']) {
      for (const key of [`person.licence.${type}`, `person.licence.status.${type}.valid`, `person.licence.status.${type}.revoked`]) {
        if (!isLocaleKey(key)) missing.push(key);
      }
    }
    expect(missing).toEqual([]);
  });

  it('contain every labelKey used by config/units.json', () => {
    const units = readJson<{ units: { code: string; labelKey: string }[] }>(join(ROOT, 'config', 'units.json')).units;
    expect(units.length).toBeGreaterThan(0);
    for (const unit of units) {
      // unit.label / unit.none / unit.primary are static labels in the unit.<code> namespace.
      expect(['label', 'none', 'primary'], `reserved unit code ${unit.code}`).not.toContain(unit.code);
      expect(sv, unit.code).toHaveProperty([unit.labelKey]);
      expect(en, unit.code).toHaveProperty([unit.labelKey]);
      expect(isLocaleKey(unit.labelKey)).toBe(true);
    }
  });
});

describe('packages/types/src/locale-keys.ts', () => {
  it('lists exactly the locale keys, sorted', () => {
    expect([...LOCALE_KEYS]).toEqual(Object.keys(sv).sort(byCodeUnit));
  });

  it('is not stale (gen-locale-keys --check)', () => {
    const r = run(GEN, ['--check']);
    expect(r.out).toContain('up to date');
    expect(r.status).toBe(0);
  });

  it('narrows runtime strings with isLocaleKey', () => {
    expect(isLocaleKey('common.save')).toBe(true);
    expect(isLocaleKey('common.nope')).toBe(false);
  });

  it('types keys and placeholder variables (checked by tsc)', () => {
    const key: LocaleKey = 'mdt.search.placeholder';
    // @ts-expect-error unknown key
    const bad: LocaleKey = 'mdt.search.nope';
    const vars: LocaleVars<'alert.assigned'> = { callsign: 'IGV-07', name: 'Anna B.' };
    // @ts-expect-error `name` is missing
    const missing: LocaleVars<'alert.assigned'> = { callsign: 'IGV-07' };
    const none: LocaleArgs<'common.save'> = [];
    const needed: LocaleArgs<'time.at'> = [{ date: '2026-09-29', time: '12:00' }];
    // @ts-expect-error vars are required for a key with placeholders
    const omitted: LocaleArgs<'time.at'> = [];
    expect([key, bad, vars, missing, none, needed, omitted]).toHaveLength(7);
  });
});

describe('scripts/merge-pending-locales.mjs', () => {
  const dirs: string[] = [];
  afterAll(() => {
    for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
  });

  /** A throwaway repo root with small locale files and the given pending files. */
  function fixtureRoot(pending: Record<string, unknown>, base: { sv: Locale; en: Locale } = {
    sv: { 'common.save': 'Spara', 'common.cancel': 'Avbryt' },
    en: { 'common.save': 'Save', 'common.cancel': 'Cancel' },
  }) {
    const root = mkdtempSync(join(tmpdir(), 'fredpd-locales-'));
    dirs.push(root);
    mkdirSync(join(root, 'locales', 'pending'), { recursive: true });
    writeFileSync(join(root, 'locales', 'sv.json'), serialize(base.sv));
    writeFileSync(join(root, 'locales', 'en.json'), serialize(base.en));
    for (const [name, content] of Object.entries(pending)) {
      writeFileSync(join(root, 'locales', 'pending', name), typeof content === 'string' ? content : JSON.stringify(content));
    }
    return {
      root,
      read: (lang: 'sv' | 'en') => readFileSync(join(root, 'locales', `${lang}.json`), 'utf8'),
      pendingExists: (name: string) => existsSync(join(root, 'locales', 'pending', name)),
      keysFile: () => join(root, 'packages', 'types', 'src', 'locale-keys.ts'),
    };
  }

  it('merges, sorts, regenerates the key list and deletes the merged files', () => {
    const f = fixtureRoot({
      'bolo.json': { $comment: 'ignored', 'bolo.test.hit': { sv: '{plate} är efterlyst', en: '{plate} is wanted' } },
      'alert.json': { 'alert.test.toast': { sv: 'Nytt larm', en: 'New alert' }, 'common.save': { sv: 'Spara', en: 'Save' } },
    });
    const r = run(MERGE, ['--root', f.root]);
    expect(r.status, r.out).toBe(0);
    expect(r.out).toContain('2 added, 0 updated, 1 unchanged');
    const merged = JSON.parse(f.read('sv')) as Locale;
    expect(Object.keys(merged)).toEqual(['alert.test.toast', 'bolo.test.hit', 'common.cancel', 'common.save']);
    expect(JSON.parse(f.read('en'))).toMatchObject({ 'bolo.test.hit': '{plate} is wanted' });
    expect(f.read('sv').endsWith('}\n')).toBe(true);
    expect(f.pendingExists('bolo.json') || f.pendingExists('alert.json')).toBe(false);
    const keys = readFileSync(f.keysFile(), 'utf8');
    expect(keys).toContain("'bolo.test.hit': 'plate';");
    expect(run(GEN, ['--root', f.root, '--check']).status).toBe(0);
  });

  it('refuses to change an existing text without --force and writes nothing', () => {
    const f = fixtureRoot({ 'x.json': { 'common.save': { sv: 'Spara nu', en: 'Save now' } } });
    const before = f.read('sv');
    const r = run(MERGE, ['--root', f.root]);
    expect(r.status).toBe(1);
    expect(r.out).toContain('--force');
    expect(f.read('sv')).toBe(before);
    expect(f.pendingExists('x.json')).toBe(true);
    expect(existsSync(f.keysFile())).toBe(false);

    const forced = run(MERGE, ['--root', f.root, '--force']);
    expect(forced.status, forced.out).toBe(0);
    expect(JSON.parse(f.read('sv'))).toMatchObject({ 'common.save': 'Spara nu' });
    expect(f.pendingExists('x.json')).toBe(false);
  });

  it('reports two pending files that disagree as a conflict', () => {
    const f = fixtureRoot({
      'a.json': { 'case.test.title': { sv: 'Ärende', en: 'Case' } },
      'b.json': { 'case.test.title': { sv: 'Ärenden', en: 'Cases' } },
    });
    const r = run(MERGE, ['--root', f.root]);
    expect(r.status).toBe(1);
    expect(r.out).toContain('a.json');
    expect(r.out).toContain('b.json');
  });

  it('rejects invalid entries (placeholders, missing language, bad key, prefix clash, bad JSON)', () => {
    const cases: [Record<string, unknown>, string][] = [
      [{ 'p.json': { 'alert.test.x': { sv: 'Hej {name}', en: 'Hello {nam}' } } }, 'placeholders differ'],
      [{ 'p.json': { 'alert.test.x': { sv: 'Hej' } } }, 'missing a "en" string'],
      [{ 'p.json': { 'alert.test.x': { sv: 'Hej', en: 'Hi', se: 'Hej' } } }, 'unknown field'],
      [{ 'p.json': { 'Alert.x': { sv: 'Hej', en: 'Hi' } } }, 'does not match'],
      [{ 'p.json': { 'alert.test.x': { sv: ' ', en: 'Hi' } } }, 'is empty'],
      [{ 'p.json': { 'common.save.label': { sv: 'Spara', en: 'Save' } } }, 'both a key and a prefix'],
      [{ 'p.json': '{ not json' }, 'not valid JSON'],
      // JSON.parse would keep only the last text; the merge must refuse instead of losing the first one.
      [
        { 'p.json': '{ "alert.test.x": { "sv": "Hej", "en": "Hi" }, "alert.test.x": { "sv": "Hallå", "en": "Hello" } }' },
        'duplicate key "alert.test.x";',
      ],
      [{ 'p.json': '{ "alert.test.x": { "sv": "Hej", "sv": "Hallå", "en": "Hi" } }' }, 'duplicate key "alert.test.x" > "sv"'],
    ];
    for (const [pending, message] of cases) {
      const f = fixtureRoot(pending);
      const r = run(MERGE, ['--root', f.root]);
      expect(r.status, message).toBe(1);
      expect(r.out).toContain(message);
      expect(f.pendingExists('p.json')).toBe(true);
    }
  });

  it('writes nothing in --dry-run', () => {
    const f = fixtureRoot({ 'x.json': { 'alert.test.x': { sv: 'Larm', en: 'Alert' } } });
    const before = f.read('sv');
    const r = run(MERGE, ['--root', f.root, '--dry-run']);
    expect(r.status, r.out).toBe(0);
    expect(r.out).toContain('1 added');
    expect(f.read('sv')).toBe(before);
    expect(f.pendingExists('x.json')).toBe(true);
  });

  it('gen-locale-keys --check fails on a stale or missing key file and on mismatched locales', () => {
    const f = fixtureRoot({});
    expect(run(GEN, ['--root', f.root, '--check']).status).toBe(1);
    expect(run(GEN, ['--root', f.root]).status).toBe(0);
    expect(run(GEN, ['--root', f.root, '--check']).status).toBe(0);
    writeFileSync(join(f.root, 'locales', 'en.json'), JSON.stringify({ 'common.save': 'Save' }));
    const r = run(GEN, ['--root', f.root, '--check']);
    expect(r.status).toBe(1);
    expect(r.out).toContain('missing key "common.cancel"');
  });

  it('gen-locale-keys runs when invoked through a symlinked directory (--check is not a silent no-op)', () => {
    const f = fixtureRoot({});
    // 'junction' lets Windows create the link without admin rights; other platforms ignore the type.
    const link = join(f.root, 'scripts-link');
    symlinkSync(join(ROOT, 'scripts'), link, 'junction');
    const viaLink = join(link, 'gen-locale-keys.mjs');
    const stale = run(viaLink, ['--root', f.root, '--check']);
    expect(stale.status, stale.out).toBe(1);
    expect(stale.out).toContain('is stale');
    expect(run(viaLink, ['--root', f.root]).status).toBe(0);
    expect(run(viaLink, ['--root', f.root, '--check']).out).toContain('up to date');
  });

  it('rejects duplicate keys in a locale file (gen-locale-keys and the merge script)', () => {
    const f = fixtureRoot({});
    const svPath = join(f.root, 'locales', 'sv.json');
    writeFileSync(svPath, '{\n  "common.cancel": "Avbryt",\n  "common.save": "Spara",\n  "common.save": "Spara nu"\n}\n');
    for (const r of [run(GEN, ['--root', f.root, '--check']), run(GEN, ['--root', f.root]), run(MERGE, ['--root', f.root])]) {
      expect(r.status, r.out).toBe(1);
      expect(r.out).toContain('duplicate keys');
      expect(r.out).toContain('"common.save"');
    }
    // An escaped quote inside a value must not shift the key/value pairing.
    writeFileSync(svPath, '{\n  "common.cancel": "Avbryt \\"nu\\", \\"common.cancel\\"",\n  "common.save": "Spara"\n}\n');
    writeFileSync(join(f.root, 'locales', 'en.json'), '{\n  "common.cancel": "Cancel",\n  "common.save": "Save"\n}\n');
    const ok = run(GEN, ['--root', f.root]);
    expect(ok.status, ok.out).toBe(0);
  });

  it('gen-locale-keys --check fails on a locale file that is not canonical; the merge script rewrites it', () => {
    const f = fixtureRoot({});
    const svPath = join(f.root, 'locales', 'sv.json');
    expect(run(GEN, ['--root', f.root]).status).toBe(0);
    writeFileSync(svPath, JSON.stringify({ 'common.save': 'Spara', 'common.cancel': 'Avbryt' }, null, 2));
    const r = run(GEN, ['--root', f.root, '--check']);
    expect(r.status).toBe(1);
    expect(r.out).toContain('locales/sv.json not in canonical form');
    const write = run(GEN, ['--root', f.root]);
    expect(write.status, write.out).toBe(0);
    expect(write.out).toContain('Warning');
    expect(run(MERGE, ['--root', f.root]).status).toBe(0);
    expect(f.read('sv')).toBe(serialize({ 'common.cancel': 'Avbryt', 'common.save': 'Spara' }));
    expect(run(GEN, ['--root', f.root, '--check']).status).toBe(0);
    // A CRLF checkout (Windows) of a canonical file is still canonical.
    writeFileSync(svPath, f.read('sv').replace(/\n/g, '\r\n'));
    expect(run(GEN, ['--root', f.root, '--check']).status).toBe(0);
  });
});
