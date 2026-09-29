// SPDX-License-Identifier: GPL-3.0-only
// Database migrations (docs/contracts.md §C7, docs/modules/db.md): scripts/migrate.mjs (Node, mysql2) and
// fredpd_core/server/db.lua (Lua, run through tests/lua/mysql_shim.lua) must split, hash and apply
// db/migrations identically. DB tests use fredpd_test_db (Node) and fredpd_test_db_lua (Lua) on the server from
// FREDPD_TEST_DB_URL and are skipped with a warning when it is unreachable; Lua parity tests need lua5.4.
import { spawnSync } from 'node:child_process';
import { cpSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
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
const DB_TIMEOUT = 60_000;

type Statement = { sql: string; ifTableExists: string | null; line: number };
type MigrateResult = { applied: string[]; seeded: string[]; skipped: string[] };
type Row = Record<string, unknown>;
type Conn = { query(sql: string, values?: unknown[]): Promise<[unknown, unknown]>; end(): Promise<void> };
type MigrateOptions = {
  url?: string; connection?: Conn; migrationsDir?: string; seedDir?: string; seed?: boolean; allowNonUtc?: boolean;
  log?: (m: string) => void;
};
type MigrateModule = {
  splitStatements(sql: string): Statement[];
  checksum(content: string | Buffer): string;
  timeZoneProblem(row: Row | null | undefined): string | null;
  TIME_ZONE_SQL: string;
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

// --- time zone check -----------------------------------------------------------------------------------------

// TIME_ZONE_SQL rows as MariaDB returns them (the same rows are in tests/lua/db_test.lua).
const TZ_ROWS: Row[] = [
  { tz: 'SYSTEM', system_tz: 'UTC', now_offset: 0, jan_skew: 0, jul_skew: 0 },
  { tz: '+00:00', system_tz: 'CEST', now_offset: '0', jan_skew: '0', jul_skew: '0' },
  { tz: 'SYSTEM', system_tz: 'CEST', now_offset: 120, jan_skew: -3600, jul_skew: -7200 },
  { tz: 'Europe/London', system_tz: 'UTC', now_offset: 0, jan_skew: 0, jul_skew: -3600 },
  { tz: '-05:30', system_tz: 'UTC', now_offset: -330, jan_skew: 19800, jul_skew: 19800 },
  {},
];

describe('timeZoneProblem (scripts/migrate.mjs)', () => {
  it('accepts only a zone that is UTC all year', () => {
    expect(mig.timeZoneProblem(TZ_ROWS[0])).toBeNull();
    expect(mig.timeZoneProblem(TZ_ROWS[1])).toBeNull();
    expect(mig.timeZoneProblem(TZ_ROWS[2])).toBe(
      'MariaDB sessions do not use UTC (time_zone=SYSTEM, system_time_zone=CEST; UTC offset now +120 min, January +60, ' +
        'July +120). docs/contracts.md §C7 requires every DATETIME DEFAULT CURRENT_TIMESTAMP in UTC. ' +
        "Set default-time-zone='+00:00' under [mysqld] in my.ini (my.cnf on Linux) and restart MariaDB; see docs/modules/db.md.",
    );
    expect(mig.timeZoneProblem(TZ_ROWS[3])).toContain('now +0 min, January +0, July +60');
    expect(mig.timeZoneProblem(TZ_ROWS[4])).toContain('now -330 min, January -330, July -330');
    expect(mig.timeZoneProblem(null)).toContain('time_zone=nil, system_time_zone=nil; UTC offset now ? min, January ?, July ?');
  });

  it.skipIf(!LUA)('db.lua judges every row with the same text and uses the same probe SQL', () => {
    const out = JSON.parse(lua(['tzproblem', JSON.stringify(TZ_ROWS)])) as { problem?: string }[];
    expect(out.map((o) => o.problem ?? null)).toEqual(TZ_ROWS.map((r) => mig.timeZoneProblem(r)));
    const consts = JSON.parse(lua(['consts'])) as { timeZoneSql: string };
    expect(consts.timeZoneSql).toBe(mig.TIME_ZONE_SQL);
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
      expect(String(byTable.get(t)?.def).toLowerCase(), t).toMatch(/^current_timestamp/);
    }
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

  it('checks the server default time zone, writes in UTC on a caller connection and restores its zone', { timeout: DB_TIMEOUT }, async () => {
    const conn = await mig.connect(nodeUrl);
    connections.push(conn);
    const [[probe]] = (await conn.query(mig.TIME_ZONE_SQL)) as [Row[], unknown];
    expect(mig.timeZoneProblem(probe)).toBeNull(); // connect() sets the session to UTC
    const id = '008_tablets.sql';
    await conn.query('DELETE FROM fredpd_migrations WHERE id = ?', [id]); // so migrate() writes a row
    await conn.query("SET time_zone = '+02:00'");
    // Passes although this session is +02:00: the check reads the default (UTC on the test server).
    const r = await mig.migrate({ connection: conn, log: noop, seed: true });
    expect(r).toEqual({ applied: [id], seeded: [], skipped: [] });
    expect(await rows(conn, 'SELECT @@session.time_zone AS tz')).toEqual([{ tz: '+02:00' }]);
    // applied_at (DEFAULT CURRENT_TIMESTAMP) was written in UTC, not in the caller's +02:00.
    await conn.query("SET time_zone = '+00:00'");
    const [skew] = await rows(conn, 'SELECT TIMESTAMPDIFF(MINUTE, applied_at, UTC_TIMESTAMP()) AS m FROM fredpd_migrations WHERE id = ?', [id]);
    expect(Math.abs(Number(skew?.m))).toBeLessThanOrEqual(1);
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
});
