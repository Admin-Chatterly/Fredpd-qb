// SPDX-License-Identifier: GPL-3.0-only
// Database migrations (docs/contracts.md §C7, docs/modules/db.md): scripts/migrate.mjs (Node, mysql2) and
// fredpd_core/server/db.lua (Lua, run through tests/lua/mysql_shim.lua) must split, hash and apply
// db/migrations identically. DB tests use fredpd_test_db (Node) and fredpd_test_db_lua (Lua) on the server from
// FREDPD_TEST_DB_URL and are skipped with a warning when it is unreachable; Lua parity tests need lua5.4. The time
// zone regression test (docs/contracts.md §C7: UTC whatever the server zone) uses fredpd_test_utc_node and
// fredpd_test_utc_lua with +02:00 sessions; only with FREDPD_TEST_GLOBAL_TZ=1 (set in CI) does it also briefly set the
// server's GLOBAL time_zone to '+02:00' (restored afterwards, under the server-side lock fredpd_test_global_tz so
// concurrent runs on one MariaDB take turns), so a developer's shared MariaDB is never switched by default.
import { spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterAll, describe, expect, it } from 'vitest';

const ROOT = fileURLToPath(new URL('../../../', import.meta.url));
const MIGRATIONS_DIR = join(ROOT, 'db', 'migrations');
const SEED_DIR = join(ROOT, 'db', 'seed');
const STUB_FILE = join(ROOT, 'db', 'dev', 'qbx_stub.sql');
const NODE_DB = 'fredpd_test_db';
const LUA_DB = 'fredpd_test_db_lua';
const UTC_NODE_DB = 'fredpd_test_utc_node';
const UTC_LUA_DB = 'fredpd_test_utc_lua';
const DB_TIMEOUT = 60_000;

type Statement = { sql: string; ifTableExists: string | null; line: number };
type MigrateResult = { applied: string[]; seeded: string[]; skipped: string[] };
type Row = Record<string, unknown>;
type Conn = { query(sql: string, values?: unknown[]): Promise<[unknown, unknown]>; end(): Promise<void> };
type MigrateOptions = {
  url?: string; connection?: Conn; migrationsDir?: string; seedDir?: string; seed?: boolean; log?: (m: string) => void;
};
type MigrateModule = {
  splitStatements(sql: string): Statement[];
  checksum(content: string | Buffer): string;
  listSqlFiles(dir: string, re: RegExp): string[];
  migrate(opts: MigrateOptions): Promise<MigrateResult>;
  status(opts: MigrateOptions): Promise<{ id: string; state: string }[]>;
  connect(url: string): Promise<Conn>;
  MIGRATIONS_TABLE_DDL: string;
  MIGRATION_FILE_RE: RegExp;
  SEED_FILE_RE: RegExp;
};

// Plain .mjs without type declarations: import through a variable so TS does not resolve it, then type it here.
const MIGRATE_PATH: string = join(ROOT, 'scripts', 'migrate.mjs');
const mig = (await import(MIGRATE_PATH)) as MigrateModule;
const noop = () => {};

// --- environment ---------------------------------------------------------------------------------------------

const BASE_URL = process.env.FREDPD_TEST_DB_URL ?? 'mysql://fredpd:fredpd@127.0.0.1:3306/fredpd_test';
function urlFor(database: string): string {
  const u = new URL(BASE_URL);
  u.pathname = `/${database}`;
  return u.toString();
}

let admin: Conn | null = null;
try {
  admin = await mig.connect(urlFor(''));
} catch (err) {
  console.warn(`[migrations.test] database unreachable at ${new URL(BASE_URL).host} (${(err as Error).message}); skipping DB tests`);
}
const LUA = ['lua5.4', 'lua54', 'lua'].find((bin) => /Lua 5\.4/.test(spawnSync(bin, ['-v'], { encoding: 'utf8' }).stdout ?? ''));
if (!LUA) console.warn('[migrations.test] no Lua 5.4 interpreter; skipping Lua parity tests');

const connections: Conn[] = [];
afterAll(async () => {
  await Promise.all([...connections, ...(admin ? [admin] : [])].map((c) => c.end()));
});

async function rows(conn: Conn, sql: string, values?: unknown[]): Promise<Row[]> {
  const [r] = await conn.query(sql, values);
  return r as Row[];
}

async function resetDb(name: string, stub: boolean): Promise<Conn> {
  if (!admin) throw new Error('no database');
  await admin.query(`DROP DATABASE IF EXISTS \`${name}\``);
  await admin.query(`CREATE DATABASE \`${name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_swedish_ci`);
  const conn = await mig.connect(urlFor(name));
  connections.push(conn);
  if (stub) for (const st of mig.splitStatements(readFileSync(STUB_FILE, 'utf8'))) await conn.query(st.sql);
  return conn;
}

function lua(args: string[]) {
  if (!LUA) throw new Error('no lua');
  const r = spawnSync(LUA, ['tests/lua/mysql_shim.lua', ...args], {
    cwd: ROOT, encoding: 'utf8', env: { ...process.env, FREDPD_TEST_DB_URL: BASE_URL }, maxBuffer: 64 * 1024 * 1024,
  });
  if (r.status !== 0) throw new Error(`lua ${args.join(' ')} exited ${r.status}: ${r.stderr}`);
  return r.stdout;
}

const migrationFiles = mig.listSqlFiles(MIGRATIONS_DIR, mig.MIGRATION_FILE_RE);
const seedFiles = mig.listSqlFiles(SEED_DIR, mig.SEED_FILE_RE);

// --- splitStatements ------------------------------------------------------------------------------------------

type SplitCase = { name: string; input: string; expected: Statement[] | { error: string } };
const st = (sql: string, line: number, ifTableExists: string | null = null): Statement => ({ sql, ifTableExists, line });

// The same inputs run through db.lua below (Lua parity), so edge cases are pinned for both splitters.
const SPLIT_CASES: SplitCase[] = [
  { name: 'basic', input: '-- header\nCREATE TABLE a (x INT);\n\nINSERT INTO a VALUES (1) ;  \nSELECT 1;',
    expected: [st('CREATE TABLE a (x INT)', 2), st('INSERT INTO a VALUES (1)', 4), st('SELECT 1', 5)] },
  { name: 'quotes', input: "INSERT INTO t VALUES ('a;b', \"c;d\", 'it''s;', 'x\\';y');\nSELECT `we;ird`;",
    expected: [st("INSERT INTO t VALUES ('a;b', \"c;d\", 'it''s;', 'x\\';y')", 1), st('SELECT `we;ird`', 2)] },
  { name: 'multi-line string', input: "SELECT 'multi\nline;\nstring';\nSELECT 2;",
    expected: [st("SELECT 'multi\nline;\nstring'", 1), st('SELECT 2', 4)] },
  { name: 'comments', input: '# hash; comment\n/* block ; comment\n*/ SELECT 1 /* inner ; */ -- tail;\n;\nSELECT 2;',
    expected: [st('SELECT 1 /* inner ; */ -- tail;', 3), st('SELECT 2', 5)] },
  { name: 'double dash without space', input: 'SELECT 1--1;', expected: [st('SELECT 1--1', 1)] },
  { name: 'executable comment', input: '/*!40101 SET NAMES utf8mb4 */;', expected: [st('/*!40101 SET NAMES utf8mb4 */', 1)] },
  { name: 'empty statements', input: ';;\nSELECT 1;;', expected: [st('SELECT 1', 2)] },
  { name: 'only comments', input: '-- only a comment\n\n', expected: [] },
  { name: 'crlf and bom', input: '\uFEFFCREATE TABLE a (\r\n  x INT\r\n);\r\nSELECT 1;\r\n',
    expected: [st('CREATE TABLE a (\n  x INT\n)', 1), st('SELECT 1', 4)] },
  { name: 'utf-8 text', input: "INSERT INTO c VALUES ('Hastighetsöverträdelse 1–10 km/h; ä');\n",
    expected: [st("INSERT INTO c VALUES ('Hastighetsöverträdelse 1–10 km/h; ä')", 1)] },
  { name: 'directive', input: 'SELECT 1;\n-- @if-table-exists player_vehicles\nCREATE INDEX IF NOT EXISTS plate ON player_vehicles (plate);\nSELECT 2;',
    expected: [st('SELECT 1', 1), st('CREATE INDEX IF NOT EXISTS plate ON player_vehicles (plate)', 3, 'player_vehicles'), st('SELECT 2', 4)] },
  { name: 'directive spacing', input: '--   @if-table-exists  players  \nSELECT 1;', expected: [st('SELECT 1', 2, 'players')] },
  { name: 'not a directive', input: '-- not a @directive\nSELECT 1;', expected: [st('SELECT 1', 2)] },
  { name: 'unknown directive', input: '-- @if-table-exist players\nSELECT 1;',
    expected: { error: 'line 1: unknown or malformed directive: -- @if-table-exist players' } },
  { name: 'directive without table', input: '-- @if-table-exists\nSELECT 1;',
    expected: { error: 'line 1: unknown or malformed directive: -- @if-table-exists' } },
  { name: 'directive inside statement', input: 'SELECT\n-- @if-table-exists a\n1;', expected: { error: 'line 2: directive inside a statement' } },
  { name: 'two directives', input: '-- @if-table-exists a\n-- @if-table-exists b\nSELECT 1;',
    expected: { error: 'line 2: two directives before one statement' } },
  { name: 'dangling directive', input: 'SELECT 1;\n-- @if-table-exists a\n', expected: { error: 'line 2: directive not followed by a statement' } },
  { name: 'missing semicolon', input: 'SELECT 1;\n\nSELECT 2', expected: { error: 'line 3: statement not terminated by ;' } },
  { name: 'unterminated quote', input: "SELECT 'abc;\n", expected: { error: "line 1: unterminated ' quote" } },
  { name: 'unterminated comment', input: 'SELECT 1;\n/* open', expected: { error: 'line 2: unterminated /* comment' } },
];

function splitOutcome(input: string): Statement[] | { error: string } {
  try {
    return mig.splitStatements(input);
  } catch (err) {
    return { error: (err as Error).message };
  }
}

describe('splitStatements (scripts/migrate.mjs)', () => {
  for (const c of SPLIT_CASES) {
    it(c.name, () => {
      expect(splitOutcome(c.input)).toEqual(c.expected);
    });
  }

  it('parses every migration and seed file; only 002 has a conditional statement', () => {
    expect(migrationFiles.slice(0, 8)).toEqual([
      '001_core.sql', '002_index.sql', '003_records.sql', '004_bolo.sql',
      '005_dispatch.sql', '006_evidence.sql', '007_intel.sql', '008_tablets.sql',
    ]);
    const conditional: string[] = [];
    for (const f of migrationFiles) {
      for (const s of mig.splitStatements(readFileSync(join(MIGRATIONS_DIR, f), 'utf8'))) {
        if (s.ifTableExists) conditional.push(`${f}: ${s.ifTableExists}: ${s.sql}`);
      }
    }
    for (const f of seedFiles) expect(() => mig.splitStatements(readFileSync(join(SEED_DIR, f), 'utf8'))).not.toThrow();
    expect(conditional).toEqual(['002_index.sql: player_vehicles: CREATE INDEX IF NOT EXISTS plate ON player_vehicles (plate)']);
  });

  it('no migration or seed statement contains ? (oxmysql would bind it to NULL)', () => {
    // oxmysql pads every `?` with NULL even for a statement without parameters, inside quotes and comments too.
    const offenders: string[] = [];
    for (const [dir, files] of [[MIGRATIONS_DIR, migrationFiles], [SEED_DIR, seedFiles]] as const) {
      for (const f of files) {
        for (const s of mig.splitStatements(readFileSync(join(dir, f), 'utf8'))) if (s.sql.includes('?')) offenders.push(`${f}:${s.line}`);
      }
    }
    expect(offenders).toEqual([]);
  });

  it('MIGRATIONS_TABLE_DDL is the first statement of 001_core.sql', () => {
    expect(mig.splitStatements(readFileSync(join(MIGRATIONS_DIR, '001_core.sql'), 'utf8'))[0]?.sql).toBe(mig.MIGRATIONS_TABLE_DDL);
  });

  it('checksum ignores a BOM and CRLF line endings only', () => {
    const lf = 'CREATE TABLE x (a INT);\nSELECT 1;\n';
    expect(mig.checksum(`\uFEFF${lf.replace(/\n/g, '\r\n')}`)).toBe(mig.checksum(lf));
    expect(mig.checksum(Buffer.from(lf))).toBe(mig.checksum(lf));
    expect(mig.checksum('a;\n')).not.toBe(mig.checksum('a; \n'));
    expect(mig.checksum('')).toBe('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
  });
});

describe.skipIf(!LUA)('Lua parity (fredpd_core/server/db.lua)', () => {
  it('splits and hashes every case and every migration/seed file exactly like migrate.mjs', () => {
    const dir = mkdtempSync(join(tmpdir(), 'fredpd-split-'));
    try {
      const files = SPLIT_CASES.map((c, i) => {
        const p = join(dir, `case-${String(i).padStart(2, '0')}.sql`);
        writeFileSync(p, c.input);
        return { path: p, content: Buffer.from(c.input) };
      });
      for (const f of migrationFiles) files.push({ path: join(MIGRATIONS_DIR, f), content: readFileSync(join(MIGRATIONS_DIR, f)) });
      for (const f of seedFiles) files.push({ path: join(SEED_DIR, f), content: readFileSync(join(SEED_DIR, f)) });

      const out = JSON.parse(lua(['split', ...files.map((f) => f.path)])) as Record<
        string, { checksum: string; statements?: { sql: string; ifTableExists?: string; line: number }[]; error?: string }
      >;
      for (const f of files) {
        const l = out[f.path];
        expect(l, f.path).toBeDefined();
        expect(l?.checksum, f.path).toBe(mig.checksum(f.content));
        const luaOutcome = l?.error !== undefined
          ? { error: l.error }
          : (l?.statements ?? []).map((s) => ({ sql: s.sql, ifTableExists: s.ifTableExists ?? null, line: s.line }));
        expect(luaOutcome, f.path).toEqual(splitOutcome(f.content.toString('utf8')));
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('db.lua MIGRATIONS_TABLE_DDL matches migrate.mjs', () => {
    const consts = JSON.parse(lua(['consts'])) as { migrationsTableDdl: string; nextSeqSql: string };
    expect(consts.migrationsTableDdl).toBe(mig.MIGRATIONS_TABLE_DDL);
  });
});

// --- CLI -----------------------------------------------------------------------------------------------------

describe('scripts/migrate.mjs CLI', () => {
  it('runs through a symlinked or junctioned path instead of silently exiting 0', () => {
    const dir = mkdtempSync(join(tmpdir(), 'fredpd-link-'));
    try {
      const link = join(dir, 'repo');
      symlinkSync(ROOT, link, 'junction'); // 'junction' needs no privilege on Windows; ignored elsewhere
      const r = spawnSync(process.execPath, [join(link, 'scripts', 'migrate.mjs'), '--bogus'], { encoding: 'utf8' });
      expect(r.status).toBe(1);
      expect(r.stderr).toContain('[migrate] unknown argument: --bogus');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

// --- time zone independence (static) --------------------------------------------------------------------------

describe('UTC storage (docs/contracts.md §C7)', () => {
  // SQL that reads the session clock or converts through the session zone: the current-time functions, plus
  // FROM_UNIXTIME(n) and UNIX_TIMESTAMP(value) (with an argument; bare UNIX_TIMESTAMP() is a zone-free epoch).
  // Epoch arithmetic is TIMESTAMPDIFF(SECOND, '1970-01-01', col) / '1970-01-01' + INTERVAL n SECOND (db.md).
  const CLOCK_PARTS = [
    String.raw`\b(?:CURRENT_TIMESTAMP|CURRENT_DATE|CURRENT_TIME|LOCALTIME|LOCALTIMESTAMP)\b`,
    String.raw`\b(?:SYSDATE|CURDATE|CURTIME|FROM_UNIXTIME)\s*\(`,
    String.raw`\bUNIX_TIMESTAMP\s*\(\s*[^)\s]`,
  ];
  // Not after . : $ or a word character: x.now(), self:now() and ${clock.now()} in a template are clock calls.
  const NOW_PART = String.raw`(?<![\w.$:])NOW\s*\(`;
  const SESSION_CLOCK = new RegExp([...CLOCK_PARTS, NOW_PART].join('|'), 'i');

  it('migrations and seeds default to (UTC_TIMESTAMP()) and never use the session clock or ON UPDATE', () => {
    const offenders: string[] = [];
    for (const [dir, files] of [[MIGRATIONS_DIR, migrationFiles], [SEED_DIR, seedFiles]] as const) {
      for (const f of files) {
        for (const s of mig.splitStatements(readFileSync(join(dir, f), 'utf8'))) {
          if (SESSION_CLOCK.test(s.sql)) offenders.push(`${f}:${s.line}: session clock`);
          if (/ON UPDATE\s+(UTC|CURRENT|NOW)/i.test(s.sql)) offenders.push(`${f}:${s.line}: ON UPDATE timestamp`);
          if (/DEFAULT\s+UTC_TIMESTAMP/i.test(s.sql)) offenders.push(`${f}:${s.line}: write DEFAULT (UTC_TIMESTAMP())`);
        }
      }
    }
    expect(offenders).toEqual([]);
    expect(mig.MIGRATIONS_TABLE_DDL).toContain('applied_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP())');
  });

  it('FredPD code never writes the session clock into SQL (Lua, service, scripts)', () => {
    // Anywhere in a line: every SESSION_CLOCK name except now(), which only counts in upper case there (a lower-case
    // now() is a JS/Lua clock call, e.g. clock.now() or an interface member). Inside string literals (quotes on one
    // line, JS template literals and Lua long strings across lines) every name counts in any case, now() included.
    const LINE_CLOCK = [new RegExp(NOW_PART), new RegExp(CLOCK_PARTS.join('|'), 'i')];
    const STRING_CLOCK = SESSION_CLOCK;
    const STRINGS = {
      lua: /\[(=*)\[[\s\S]*?\]\1\]|'(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*"/g,
      js: /`(?:[^`\\]|\\[\s\S])*`|'(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*"/g,
    };
    const roots = [join(ROOT, 'resources', '[fredpd]'), join(ROOT, 'apps', 'service', 'src'), join(ROOT, 'scripts')];
    const skip = new Set(['node_modules', 'migrations', 'build', 'dist', 'locales', 'fixtures', 'config', 'test']);
    const offenders = new Set<string>();
    const walk = (dir: string) => {
      if (!existsSync(dir)) return;
      for (const name of readdirSync(dir)) {
        const path = join(dir, name);
        if (statSync(path).isDirectory()) {
          if (!skip.has(name)) walk(path);
        } else if (/\.(lua|js|mjs|ts|tsx)$/.test(name)) {
          const text = readFileSync(path, 'utf8');
          const where = (index: number) => `${path.slice(ROOT.length)}:${text.slice(0, index).split('\n').length}`;
          text.split('\n').forEach((line, i) => {
            for (const re of LINE_CLOCK) {
              const m = re.exec(line);
              if (m) offenders.add(`${path.slice(ROOT.length)}:${i + 1}: ${m[0]}`);
            }
          });
          for (const s of text.matchAll(name.endsWith('.lua') ? STRINGS.lua : STRINGS.js)) {
            const m = STRING_CLOCK.exec(s[0]);
            if (m) offenders.add(`${where((s.index ?? 0) + m.index)}: ${m[0]} (in a string)`);
          }
        }
      }
    };
    roots.forEach(walk);
    expect([...offenders]).toEqual([]);
  });

  it('the session clock guards catch the zone-dependent spellings and allow the UTC ones', () => {
    for (const bad of ['DEFAULT CURRENT_TIMESTAMP', 'x < now()', 'NOW( )', 'CURRENT_DATE', 'CURRENT_TIME', 'LOCALTIME',
      'LOCALTIMESTAMP()', 'SYSDATE()', 'curdate()', 'CURTIME()', 'FROM_UNIXTIME(?)', 'from_unixtime (1)',
      'UNIX_TIMESTAMP(created_at)', 'unix_timestamp( ? )']) {
      expect(SESSION_CLOCK.test(bad), bad).toBe(true);
    }
    for (const ok of ['UTC_TIMESTAMP()', 'DEFAULT (UTC_TIMESTAMP())', 'UNIX_TIMESTAMP()', 'UNIX_TIMESTAMP( )', 'UTC_DATE()',
      "TIMESTAMPDIFF(SECOND, '1970-01-01', created_at)", "'1970-01-01' + INTERVAL ? SECOND", 'known_at', 'snow()',
      '${clock.now()}', 'self:now()', '$now()']) {
      expect(SESSION_CLOCK.test(ok), ok).toBe(false);
    }
  });

  it('the runners have no time zone check left', () => {
    const js = readFileSync(MIGRATE_PATH, 'utf8');
    const lua = readFileSync(join(ROOT, 'resources', '[fredpd]', 'fredpd_core', 'server', 'db.lua'), 'utf8');
    for (const text of [js, lua]) {
      expect(text).not.toMatch(/allowNonUtc|allow-non-utc|timeZoneProblem|TIME_ZONE_SQL|SET time_zone/);
      expect(text).not.toMatch(SESSION_CLOCK);
    }
  });
});

// --- charge catalogue (static) --------------------------------------------------------------------------------

describe('db/seed/charges_sv.sql', () => {
  const text = readFileSync(join(SEED_DIR, 'charges_sv.sql'), 'utf8');
  const valueLines = text.split('\n').filter((l) => l.startsWith("  ('"));
  const ROW_RE = /^ {2}\('([A-Z]{3}-\d{3})', '(penal|traffic|narcotics|weapons|public_order|other)', '((?:[^']|'')+)', '((?:[^']|'')+)', '(ordningsbot|bot|fängelse)', (\d+), (\d+)\),?$/;
  const parsed = valueLines.map((l) => ROW_RE.exec(l));

  it('has at least 110 well-formed rows with unique codes', () => {
    expect(valueLines.length).toBeGreaterThanOrEqual(110);
    expect(valueLines.filter((_, i) => !parsed[i])).toEqual([]);
    const codes = parsed.map((m) => m?.[1]);
    expect(new Set(codes).size).toBe(codes.length);
    const titles = parsed.map((m) => m?.[3]);
    expect(new Set(titles).size).toBe(titles.length);
  });

  it('is game-balanced by class', () => {
    for (const m of parsed) {
      if (!m) continue;
      const [, code, , , , cls, fine, jail] = m;
      if (cls === 'fängelse') expect(Number(jail), code).toBeGreaterThan(0);
      else expect(Number(jail), code).toBe(0);
      if (cls === 'ordningsbot') expect(Number(fine), code).toBeLessThanOrEqual(4000);
      if (cls !== 'fängelse') expect(Number(fine), code).toBeGreaterThan(0);
    }
  });

  it('covers speeding levels and every category', () => {
    const categories = new Set(parsed.map((m) => m?.[2]));
    expect([...categories].sort()).toEqual(['narcotics', 'other', 'penal', 'public_order', 'traffic', 'weapons']);
    expect(parsed.filter((m) => m?.[3]?.startsWith('Hastighetsöverträdelse')).length).toBeGreaterThanOrEqual(6);
    // Sweden has no licence points: no points column in the INSERT, no "prickar" in the rows.
    expect(text).toContain('INSERT INTO fredpd_charges (code, category, title_sv, law_ref, class, fine, jail_min) VALUES');
    expect(valueLines.join('\n')).not.toMatch(/prick|poäng/i);
  });
});

// --- against MariaDB ------------------------------------------------------------------------------------------

describe.skipIf(!admin)('migrations against MariaDB', () => {
  const nodeUrl = urlFor(NODE_DB);
  const noopOpts = { url: nodeUrl, log: noop };

  it('status is read-only on a fresh database', { timeout: DB_TIMEOUT }, async () => {
    const conn = await resetDb(NODE_DB, false);
    const states = await mig.status(noopOpts);
    expect(states.map((s) => s.id)).toEqual([...migrationFiles, ...seedFiles.map((f) => `seed/${f}`)]);
    expect(states.every((s) => s.state === 'pending')).toBe(true);
    expect(await rows(conn, "SHOW TABLES LIKE 'fredpd_migrations'")).toEqual([]);
  });

  it('skips the player_vehicles index when qbx tables are absent', { timeout: DB_TIMEOUT }, async () => {
    await resetDb(NODE_DB, false);
    const r = await mig.migrate({ ...noopOpts, seed: false });
    expect(r.applied).toEqual(migrationFiles);
    expect(r.skipped).toEqual(['002_index.sql#3']);
  });

  it('migrates a fresh database, then a second run is a no-op', { timeout: DB_TIMEOUT }, async () => {
    const conn = await resetDb(NODE_DB, true);
    const first = await mig.migrate({ ...noopOpts, seed: true });
    expect(first.applied).toEqual(migrationFiles);
    expect(first.seeded).toEqual(seedFiles.map((f) => `seed/${f}`));
    expect(first.skipped).toEqual([]);

    const second = await mig.migrate({ ...noopOpts, seed: true });
    expect(second).toEqual({ applied: [], seeded: [], skipped: [] });
    expect((await mig.status(noopOpts)).every((s) => s.state === 'applied')).toBe(true);

    const idx = await rows(conn, "SELECT index_name FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = 'player_vehicles' AND column_name = 'plate'");
    expect(idx.map((r) => r.index_name ?? r.INDEX_NAME)).toEqual(['plate']);
  });

  it('creates every §6 table as InnoDB utf8mb4_swedish_ci with created_at', { timeout: DB_TIMEOUT }, async () => {
    const conn = await mig.connect(nodeUrl);
    connections.push(conn);
    const tables = (await rows(conn,
      "SELECT table_name AS t, engine AS e, table_collation AS c FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name LIKE 'fredpd\\_%'"));
    const names = tables.map((t) => String(t.t)).sort();
    const expected = [
      'fredpd_migrations', 'fredpd_roles', 'fredpd_role_grants', 'fredpd_identities', 'fredpd_grant_cache', 'fredpd_audit',
      'fredpd_audit_archive', 'fredpd_units', 'fredpd_officers', 'fredpd_visibility_rules', 'fredpd_sequences',
      'fredpd_persons', 'fredpd_vehicles_idx',
      'fredpd_cases', 'fredpd_case_assignees', 'fredpd_case_subjects', 'fredpd_reports', 'fredpd_report_drafts',
      'fredpd_report_templates', 'fredpd_charges', 'fredpd_records', 'fredpd_poi', 'fredpd_shares', 'fredpd_release_requests',
      'fredpd_bolos', 'fredpd_alerts', 'fredpd_alert_units', 'fredpd_evidence',
      'fredpd_intel_sources', 'fredpd_intel_reports', 'fredpd_intel_entities', 'fredpd_intel_links', 'fredpd_missions',
      'fredpd_mission_members', 'fredpd_tablets',
    ];
    expect(names).toEqual(expect.arrayContaining(expected));
    for (const t of tables.filter((x) => expected.includes(String(x.t)))) {
      expect([t.t, t.e, t.c]).toEqual([t.t, 'InnoDB', 'utf8mb4_swedish_ci']);
    }
    const created = await rows(conn,
      "SELECT table_name AS t, data_type AS d, column_default AS def FROM information_schema.columns WHERE table_schema = DATABASE() AND column_name = 'created_at' AND table_name LIKE 'fredpd\\_%'");
    const byTable = new Map(created.map((c) => [String(c.t), c]));
    for (const t of expected) {
      expect(byTable.get(t)?.d, t).toBe('datetime');
      expect(String(byTable.get(t)?.def).toLowerCase(), t).toBe('utc_timestamp()');
    }
    // No DATETIME default reads the session clock and nothing updates itself (writers set updated_at, §C7).
    const clocks = await rows(conn,
      "SELECT CONCAT(table_name, '.', column_name) AS c, column_default AS def, extra AS x FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name LIKE 'fredpd\\_%' AND data_type IN ('datetime', 'timestamp')");
    expect(clocks.filter((c) => c.def !== null && !['utc_timestamp()', 'null'].includes(String(c.def).toLowerCase())).map((c) => `${String(c.c)} ${String(c.def)}`)).toEqual([]);
    expect(clocks.filter((c) => /on update/i.test(String(c.x ?? ''))).map((c) => c.c)).toEqual([]);
    const keys = await rows(conn,
      "SELECT table_name AS t, index_name AS i, GROUP_CONCAT(column_name ORDER BY seq_in_index) AS cols, MAX(non_unique) AS nu, MAX(index_type) AS type FROM information_schema.statistics WHERE table_schema = DATABASE() GROUP BY table_name, index_name");
    const key = (t: string, i: string) => keys.find((k) => k.t === t && k.i === i);
    expect(key('fredpd_persons', 'ft_name')).toMatchObject({ cols: 'firstname,lastname', type: 'FULLTEXT' });
    expect(key('fredpd_role_grants', 'uq_role_grant')).toMatchObject({ cols: 'discord_role_id,grant_type,grant_key', nu: 0 });
    expect(key('fredpd_officers', 'uq_unit_callsign')).toMatchObject({ cols: 'unit,callsign', nu: 0 });
    expect(key('fredpd_audit', 'idx_target')).toMatchObject({ cols: 'target_type,target_id' });
    expect(key('fredpd_audit', 'idx_actor_created')).toMatchObject({ cols: 'actor_citizenid,created_at' });
    expect(key('fredpd_bolos', 'idx_plate_active')).toMatchObject({ cols: 'plate,active' });
    expect(key('fredpd_bolos', 'idx_citizen_active')).toMatchObject({ cols: 'citizenid,active' });
    expect(key('fredpd_alerts', 'idx_status_created')).toMatchObject({ cols: 'status,created_at' });
    expect(key('fredpd_case_subjects', 'idx_subject')).toMatchObject({ cols: 'subject_type,subject_id' });
    expect(key('fredpd_sequences', 'PRIMARY')).toMatchObject({ cols: 'seq_type,year' });
  });

  it('loads the charge catalogue: >= 110 rows, unique codes', { timeout: DB_TIMEOUT }, async () => {
    const conn = await mig.connect(nodeUrl);
    connections.push(conn);
    const [c] = await rows(conn, 'SELECT COUNT(*) AS n, COUNT(DISTINCT code) AS d FROM fredpd_charges');
    const fileRows = readFileSync(join(SEED_DIR, 'charges_sv.sql'), 'utf8').split('\n').filter((l) => l.startsWith("  ('")).length;
    expect(Number(c?.n)).toBeGreaterThanOrEqual(110);
    expect(Number(c?.d)).toBe(Number(c?.n));
    expect(Number(c?.n)).toBe(fileRows);
  });

  it('detects checksum drift of an applied migration and runs nothing', { timeout: DB_TIMEOUT }, async () => {
    const dir = mkdtempSync(join(tmpdir(), 'fredpd-migrations-'));
    try {
      cpSync(MIGRATIONS_DIR, dir, { recursive: true });
      writeFileSync(join(dir, '002_index.sql'), `${readFileSync(join(dir, '002_index.sql'), 'utf8')}-- edited after it was applied\n`);
      writeFileSync(join(dir, '999_new.sql'), 'CREATE TABLE IF NOT EXISTS fredpd_drift_probe (id INT) ENGINE=InnoDB;\n');
      await expect(mig.migrate({ ...noopOpts, migrationsDir: dir })).rejects.toThrow(/checksum mismatch.*002_index\.sql/);
      const states = await mig.status({ ...noopOpts, migrationsDir: dir });
      expect(states.find((s) => s.id === '002_index.sql')?.state).toBe('changed');
      expect(states.find((s) => s.id === '999_new.sql')?.state).toBe('pending');
      const conn = await mig.connect(nodeUrl);
      connections.push(conn);
      expect(await rows(conn, "SHOW TABLES LIKE 'fredpd_drift_probe'")).toEqual([]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('writes UTC on a caller connection at +02:00 and leaves its zone alone', { timeout: DB_TIMEOUT }, async () => {
    const conn = await mig.connect(nodeUrl);
    connections.push(conn);
    const id = '008_tablets.sql';
    await conn.query('DELETE FROM fredpd_migrations WHERE id = ?', [id]); // so migrate() writes a row
    await conn.query("SET time_zone = '+02:00'");
    const r = await mig.migrate({ connection: conn, log: noop, seed: true });
    expect(r).toEqual({ applied: [id], seeded: [], skipped: [] });
    expect(await rows(conn, 'SELECT @@session.time_zone AS tz')).toEqual([{ tz: '+02:00' }]);
    // applied_at (DEFAULT (UTC_TIMESTAMP())) is UTC although the session is +02:00.
    const [skew] = await rows(conn,
      'SELECT TIMESTAMPDIFF(SECOND, applied_at, UTC_TIMESTAMP()) AS utc, TIMESTAMPDIFF(MINUTE, applied_at, NOW()) AS session FROM fredpd_migrations WHERE id = ?', [id]);
    expect(Math.abs(Number(skew?.utc))).toBeLessThanOrEqual(60);
    expect(Number(skew?.session)).toBeGreaterThanOrEqual(119);
  });

  it('tolerates a migration recorded concurrently with the same checksum, rejects another', { timeout: DB_TIMEOUT }, async () => {
    const conn = await mig.connect(nodeUrl);
    const other = await mig.connect(nodeUrl);
    connections.push(conn, other);
    const id = '008_tablets.sql';
    const sum = mig.checksum(readFileSync(join(MIGRATIONS_DIR, id)));
    // A connection that lets "another runner" record `id` just before our own insert.
    const racing = (otherChecksum: string): Conn => ({
      query: async (sql: string, values?: unknown[]) => {
        if (sql.startsWith('INSERT INTO fredpd_migrations') && values?.[0] === id) {
          await other.query('INSERT INTO fredpd_migrations (id, checksum) VALUES (?, ?)', [id, otherChecksum]);
        }
        return conn.query(sql, values);
      },
      end: async () => {},
    });
    try {
      await conn.query('DELETE FROM fredpd_migrations WHERE id = ?', [id]);
      expect(await mig.migrate({ connection: racing(sum), log: noop })).toEqual({ applied: [id], seeded: [], skipped: [] });
      await conn.query('DELETE FROM fredpd_migrations WHERE id = ?', [id]);
      await expect(mig.migrate({ connection: racing('c'.repeat(64)), log: noop }))
        .rejects.toThrow(`${id} was recorded concurrently by another runner with checksum cccccccccccc…, file ${sum.slice(0, 12)}…`);
    } finally {
      await conn.query('REPLACE INTO fredpd_migrations (id, checksum) VALUES (?, ?)', [id, sum]);
    }
  });

  it('FULLTEXT name search over 200 persons uses ft_name', { timeout: DB_TIMEOUT }, async () => {
    const conn = await mig.connect(nodeUrl);
    connections.push(conn);
    await conn.query('DELETE FROM fredpd_persons');
    const first = ['Anna', 'Erik', 'Maria', 'Lars', 'Karin', 'Johan', 'Sara', 'Mikael', 'Elin', 'Oskar'];
    const last = ['Andersson', 'Johansson', 'Karlsson', 'Nilsson', 'Eriksson', 'Larsson', 'Olsson', 'Persson', 'Svensson',
      'Gustafsson', 'Pettersson', 'Jonsson', 'Jansson', 'Hansson', 'Bengtsson', 'Jönsson', 'Lindberg', 'Jakobsson',
      'Magnusson', 'Öberg'];
    const values: unknown[][] = [];
    for (let i = 0; i < 200; i++) {
      values.push([`FPD${String(i).padStart(5, '0')}`, first[i % first.length], last[Math.floor(i / 10) % last.length],
        `19${String(60 + (i % 40)).padStart(2, '0')}-0${1 + (i % 9)}-1${i % 10}`, i % 2]);
    }
    await conn.query('INSERT INTO fredpd_persons (citizenid, firstname, lastname, birthdate, gender) VALUES ?', [values]);
    const [count] = await rows(conn, 'SELECT COUNT(*) AS n FROM fredpd_persons');
    expect(Number(count?.n)).toBe(200);

    const SEARCH = 'SELECT citizenid, firstname, lastname FROM fredpd_persons WHERE MATCH (firstname, lastname) AGAINST (? IN BOOLEAN MODE) LIMIT 50';
    const t0 = performance.now();
    const hits = await rows(conn, SEARCH, ['+nilsson*']);
    const ms = performance.now() - t0;
    expect(hits).toHaveLength(10);
    expect(hits.every((h) => h.lastname === 'Nilsson')).toBe(true);
    const both = await rows(conn, SEARCH, ['+anna* +nils*']);
    expect(both.map((h) => `${String(h.firstname)} ${String(h.lastname)}`)).toEqual(['Anna Nilsson']);
    const swedish = await rows(conn, SEARCH, ['+öberg*']);
    expect(swedish).toHaveLength(10);

    const plan = await rows(conn, `EXPLAIN ${SEARCH}`, ['+nilsson*']);
    expect(plan[0]).toMatchObject({ type: 'fulltext', key: 'ft_name' });
    console.info(`[migrations.test] FULLTEXT search over 200 persons: ${ms.toFixed(1)} ms`);
    expect(ms).toBeLessThan(250); // task 1.4 target is < 20 ms on the host; loose bound against CI noise
  });

  it.skipIf(!LUA)('Lua and Node runners produce identical fredpd_migrations rows and schemas', { timeout: DB_TIMEOUT }, async () => {
    const node = await mig.connect(nodeUrl); // migrated with stub + seeds by the tests above
    connections.push(node);
    const out = lua(['migrate', LUA_DB, '--reset', '--stub']);
    const result = JSON.parse(out.split('\n').find((l) => l.startsWith('RESULT '))?.slice(7) ?? 'null') as MigrateResult;
    expect(result.applied).toEqual(migrationFiles);
    expect(result.seeded).toEqual(seedFiles.map((f) => `seed/${f}`));

    const second = JSON.parse(lua(['migrate', LUA_DB]).split('\n').find((l) => l.startsWith('RESULT '))?.slice(7) ?? 'null') as MigrateResult;
    expect(second).toEqual({ applied: [], seeded: [], skipped: [] });

    const luaConn = await mig.connect(urlFor(LUA_DB));
    connections.push(luaConn);
    const MIGRATIONS = 'SELECT id, checksum FROM fredpd_migrations ORDER BY id';
    const nodeRows = await rows(node, MIGRATIONS);
    expect(nodeRows.map((r) => r.id)).toEqual([...migrationFiles, ...seedFiles.map((f) => `seed/${f}`)]);
    expect(await rows(luaConn, MIGRATIONS)).toEqual(nodeRows);

    const schemaQueries = [
      `SELECT table_name, column_name, ordinal_position, column_type, is_nullable, column_default, extra, collation_name, column_comment
         FROM information_schema.columns WHERE table_schema = DATABASE() ORDER BY table_name, ordinal_position`,
      `SELECT table_name, index_name, seq_in_index, column_name, non_unique, index_type
         FROM information_schema.statistics WHERE table_schema = DATABASE() ORDER BY table_name, index_name, seq_in_index`,
      `SELECT constraint_name, table_name, referenced_table_name, update_rule, delete_rule
         FROM information_schema.referential_constraints WHERE constraint_schema = DATABASE() ORDER BY constraint_name`,
      `SELECT table_name, constraint_name, check_clause
         FROM information_schema.check_constraints WHERE constraint_schema = DATABASE() ORDER BY table_name, constraint_name`,
      'SELECT code, category, title_sv, law_ref, class, fine, jail_min, active FROM fredpd_charges ORDER BY code',
      'SELECT * FROM fredpd_visibility_rules ORDER BY id',
    ];
    for (const q of schemaQueries) {
      const strip = (list: Row[]) => list.map(({ created_at: _c, updated_at: _u, ...rest }) => rest);
      expect(strip(await rows(luaConn, q)), q).toEqual(strip(await rows(node, q)));
    }
  });

  it.skipIf(!LUA)('db.lua nextSeq SQL returns the allocated number as insertId (mysql2, as under oxmysql)', { timeout: DB_TIMEOUT }, async () => {
    const { nextSeqSql } = JSON.parse(lua(['consts'])) as { nextSeqSql: string };
    const conn = await mig.connect(nodeUrl);
    connections.push(conn);
    await conn.query('DELETE FROM fredpd_sequences');
    const next = async (type: string, year: number) => {
      const [res] = await conn.query(nextSeqSql, [type, year]);
      return (res as { insertId: number }).insertId;
    };
    expect([await next('caseNumber', 2026), await next('caseNumber', 2026), await next('caseNumber', 2027), await next('caseNumber', 2026)])
      .toEqual([1, 2, 1, 3]);
  });

  it('a malformed migration fails with its file name (same text from the Lua runner) and records nothing', { timeout: DB_TIMEOUT }, async () => {
    const dir = mkdtempSync(join(tmpdir(), 'fredpd-bad-'));
    try {
      writeFileSync(join(dir, '999_bad.sql'), 'SELECT 1;\n-- @if-table-exist players\nSELECT 2;\n');
      const expected = '999_bad.sql: line 2: unknown or malformed directive: -- @if-table-exist players';
      const conn = await resetDb(NODE_DB, false);
      await expect(mig.migrate({ ...noopOpts, migrationsDir: dir })).rejects.toThrow(expected);
      expect(await rows(conn, 'SELECT id FROM fredpd_migrations')).toEqual([]);
      if (LUA) {
        const r = spawnSync(LUA, ['tests/lua/mysql_shim.lua', 'migrate', LUA_DB, '--reset', '--no-seed', `--migrations-dir=${dir}`], {
          cwd: ROOT, encoding: 'utf8', env: { ...process.env, FREDPD_TEST_DB_URL: BASE_URL },
        });
        expect(r.status, r.stderr).toBe(1);
        expect(r.stderr.trim()).toBe(expected);
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  // Regression for docs/contracts.md §C7: a Windows MariaDB defaults to SYSTEM = Europe/Stockholm. Both runners
  // must migrate there, and every default must still be UTC. The GLOBAL zone is what oxmysql and every new
  // session inherit; with FREDPD_TEST_GLOBAL_TZ=1 (CI) it is switched for the duration of this test (restored in
  // finally; if this user may not set it, only the sessions are switched and a warning says so). Without the flag
  // only the sessions are switched, so a shared dev MariaDB (e.g. one a running qbx server uses) is left alone. Several checkouts may test against one shared
  // MariaDB at once, so the whole test (save, switch, the fredpd_test_utc_* databases, restore) runs under the
  // server-side lock GLOBAL_TZ_LOCK: a second run waits and then saves the real original instead of the first run's
  // '+02:00', and can neither restore '+02:00' last nor drop the first run's databases. The server releases the lock
  // if the holder's connection dies.
  it('migrates with global and session time_zone +02:00 and every created_at default is UTC (both runners)', { timeout: 3 * DB_TIMEOUT }, async () => {
    if (!admin) throw new Error('no database');
    const GLOBAL_TZ_LOCK = 'fredpd_test_global_tz';
    const [[lock]] = (await admin.query('SELECT GET_LOCK(?, 90) AS ok', [GLOBAL_TZ_LOCK])) as [Row[], unknown];
    if (Number(lock?.ok) !== 1) throw new Error(`${GLOBAL_TZ_LOCK} is still held by another test run after 90 s`);
    let original = '';
    let restored: unknown = null;
    let global = process.env.FREDPD_TEST_GLOBAL_TZ === '1';
    const checked: Row[] = [];
    try {
      const [[before]] = (await admin.query('SELECT @@global.time_zone AS tz')) as [Row[], unknown];
      original = String(before?.tz);
      if (global) try {
        await admin.query("SET GLOBAL time_zone = '+02:00'");
      } catch (err) {
        global = false;
        console.warn(`[migrations.test] cannot SET GLOBAL time_zone (${(err as Error).message}); testing +02:00 sessions only`);
      }
      for (const db of [UTC_NODE_DB, UTC_LUA_DB]) {
        await admin.query(`DROP DATABASE IF EXISTS \`${db}\``);
        await admin.query(`CREATE DATABASE \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_swedish_ci`);
      }
      // Node runner on a connection of its own (the global zone) or on a +02:00 caller connection.
      const nodeConn = await mig.connect(urlFor(UTC_NODE_DB));
      connections.push(nodeConn);
      if (!global) await nodeConn.query("SET time_zone = '+02:00'");
      const r = await mig.migrate(global ? { url: urlFor(UTC_NODE_DB), log: noop, seed: true } : { connection: nodeConn, log: noop, seed: true });
      expect(r.applied).toEqual(migrationFiles);
      // Lua runner: every shim query is a new session, as with oxmysql's pool.
      if (LUA) {
        const out = lua(['migrate', UTC_LUA_DB, '--reset', '--stub', ...(global ? [] : ['--time-zone=+02:00'])]);
        const lr = JSON.parse(out.split('\n').find((l) => l.startsWith('RESULT '))?.slice(7) ?? 'null') as MigrateResult;
        expect(lr.applied).toEqual(migrationFiles);
      }
      for (const db of LUA ? [UTC_NODE_DB, UTC_LUA_DB] : [UTC_NODE_DB]) {
        const conn = await mig.connect(urlFor(db));
        connections.push(conn);
        if (!global) await conn.query("SET time_zone = '+02:00'");
        const [zone] = await rows(conn, 'SELECT @@global.time_zone AS g, @@session.time_zone AS s, TIMESTAMPDIFF(MINUTE, UTC_TIMESTAMP(), NOW()) AS off');
        expect({ s: zone?.s, off: Number(zone?.off) }).toEqual({ s: '+02:00', off: 120 });
        if (global) expect(zone?.g).toBe('+02:00');
        // Rows the migration wrote through defaults, plus one fresh insert per kind of table.
        await conn.query("INSERT INTO fredpd_audit (action) VALUES ('test.utc')");
        await conn.query("INSERT INTO fredpd_tablets (serial) VALUES ('UTC-1')");
        await conn.query("INSERT INTO fredpd_roles (discord_role_id, name) VALUES ('1', 'utc')");
        const probes = [
          'SELECT applied_at AS t FROM fredpd_migrations', 'SELECT created_at AS t FROM fredpd_migrations',
          'SELECT created_at AS t FROM fredpd_charges', 'SELECT updated_at AS t FROM fredpd_charges',
          'SELECT created_at AS t FROM fredpd_visibility_rules', "SELECT created_at AS t FROM fredpd_audit WHERE action = 'test.utc'",
          "SELECT issued_at AS t FROM fredpd_tablets WHERE serial = 'UTC-1'", "SELECT created_at AS t FROM fredpd_tablets WHERE serial = 'UTC-1'",
          "SELECT updated_at AS t FROM fredpd_roles WHERE discord_role_id = '1'", "SELECT created_at AS t FROM fredpd_roles WHERE discord_role_id = '1'",
        ];
        for (const q of probes) {
          const [skew] = await rows(conn,
            `SELECT COUNT(*) AS n, MAX(ABS(TIMESTAMPDIFF(SECOND, x.t, UTC_TIMESTAMP()))) AS utc, MIN(TIMESTAMPDIFF(MINUTE, x.t, NOW())) AS session FROM (${q}) x`);
          checked.push({ db, q, ...skew });
          expect(Number(skew?.n), `${db}: ${q}`).toBeGreaterThan(0);
          expect(Number(skew?.utc), `${db}: ${q} is UTC`).toBeLessThanOrEqual(60);
          expect(Number(skew?.session), `${db}: ${q} is not session time`).toBeGreaterThanOrEqual(119);
        }
      }
      expect(checked.length).toBeGreaterThanOrEqual(10);
      // Only after a pass (a failure leaves them for inspection), and still under the lock.
      for (const db of [UTC_NODE_DB, UTC_LUA_DB]) await admin.query(`DROP DATABASE IF EXISTS \`${db}\``);
    } finally {
      try {
        if (global && original) {
          await admin.query('SET GLOBAL time_zone = ?', [original]);
          // Read back while still holding the lock: after the release another run may switch it again.
          restored = (await rows(admin, 'SELECT @@global.time_zone AS tz'))[0]?.tz;
        }
      } finally {
        await admin.query('SELECT RELEASE_LOCK(?)', [GLOBAL_TZ_LOCK]);
      }
    }
    if (global) expect(restored).toBe(original);
  });
});
