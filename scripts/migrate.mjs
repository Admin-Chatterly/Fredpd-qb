#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-only
// FredPD migration runner for dev, CI and service tests (docs/contracts.md §C7, docs/modules/db.md).
// The canonical runner is resources/[fredpd]/fredpd_core/server/db.lua (oxmysql, runs on FXServer start); this
// file implements the same algorithm on mysql2, and packages/types/test/migrations.test.ts checks that both
// produce the same fredpd_migrations rows and the same schema.
//
// Usage: node scripts/migrate.mjs [--url mysql://user:pass@host:3306/db] [--seed] [--status]
//   --url     connection URL (default: env FREDPD_DB_URL)
//   --seed    also apply db/seed/*.sql that are new or changed since they were last applied
//   --status  print the state of every migration and seed instead of applying anything
//
// Time zones: none needed. Every timestamp default is (UTC_TIMESTAMP()) and every write uses UTC_TIMESTAMP()
// (docs/contracts.md §C7), so the runner works whatever the server's or the session's time zone is, and never
// changes either.
//
// Algorithm (shared with db.lua):
//   1. create fredpd_migrations if missing (MIGRATIONS_TABLE_DDL, identical to the statement in 001_core.sql);
//   2. read db/migrations/NNN_*.sql in byte order; checksum = sha256 hex of the file bytes after dropping a
//      UTF-8 BOM and turning CRLF into LF (so a Windows checkout hashes like a Linux one);
//   3. if any applied migration's checksum differs from its file, fail before running anything;
//   4. run each pending file statement by statement (splitStatements), skipping a statement whose
//      `-- @if-table-exists <table>` table is missing, then record (id, checksum), tolerating a row that a
//      concurrent runner inserted if its checksum is the same. DDL auto-commits in MariaDB,
//      so migrations are not transactional; IF NOT EXISTS everywhere makes a failed file safe to re-run;
//   5. seeds (id 'seed/<file>') run when new or changed, each in one transaction together with its record.
import { createHash } from 'node:crypto';
import { existsSync, readdirSync, readFileSync, realpathSync, statSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');

export const MIGRATIONS_DIR = join(ROOT, 'db', 'migrations');
export const SEED_DIR = join(ROOT, 'db', 'seed');
export const MIGRATION_FILE_RE = /^\d{3}_.+\.sql$/;
export const SEED_FILE_RE = /^[^.].*\.sql$/;
export const SEED_ID_PREFIX = 'seed/';
export const LOCK_NAME = 'fredpd_migrate';

// Keep identical to the fredpd_migrations statement in db/migrations/001_core.sql and to db.lua.
export const MIGRATIONS_TABLE_DDL = `CREATE TABLE IF NOT EXISTS fredpd_migrations (
  id VARCHAR(64) NOT NULL,
  checksum CHAR(64) NOT NULL,
  applied_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  created_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci`;

const TABLE_EXISTS_SQL =
  'SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ?';
// Tolerant of a concurrent runner: GET_LOCK only serialises migrate.mjs runs, not db.lua (see recordMigration).
const RECORD_MIGRATION_SQL = 'INSERT INTO fredpd_migrations (id, checksum) VALUES (?, ?) ON DUPLICATE KEY UPDATE id = id';
const RECORDED_CHECKSUM_SQL = 'SELECT checksum FROM fredpd_migrations WHERE id = ?';
const RECORD_SEED_SQL =
  'INSERT INTO fredpd_migrations (id, checksum) VALUES (?, ?) ' +
  'ON DUPLICATE KEY UPDATE checksum = VALUES(checksum), applied_at = UTC_TIMESTAMP()';

// ---------------------------------------------------------------------------------------------------------------
// Pure parts (mirrored in db.lua)

/** Whitespace as Lua's %s sees it (ASCII only), so both splitters agree on non-ASCII text. */
const WS = new Set([' ', '\t', '\n', '\r', '\f', '\v']);
const DIRECTIVE_PREFIX_RE = /^--[ \t]*@/;
const IF_TABLE_EXISTS_RE = /^--[ \t]*@if-table-exists[ \t]+([A-Za-z0-9_$]+)[ \t]*$/;

/**
 * Normalise file bytes before hashing/splitting: drop a UTF-8 BOM, CRLF -> LF.
 * @param {Buffer} buf
 * @returns {Buffer}
 */
export function normalizeBytes(buf) {
  let start = 0;
  if (buf.length >= 3 && buf[0] === 0xef && buf[1] === 0xbb && buf[2] === 0xbf) start = 3;
  const out = Buffer.allocUnsafe(buf.length - start);
  let o = 0;
  for (let i = start; i < buf.length; i++) {
    if (buf[i] === 0x0d && buf[i + 1] === 0x0a) continue; // the LF is copied on the next iteration
    out[o++] = buf[i];
  }
  return out.subarray(0, o);
}

/**
 * sha256 hex of the normalised content (a string is hashed as UTF-8).
 * @param {Buffer | string} content
 * @returns {string}
 */
export function checksum(content) {
  const buf = typeof content === 'string' ? Buffer.from(content, 'utf8') : content;
  return createHash('sha256').update(normalizeBytes(buf)).digest('hex');
}

/** Strip trailing ASCII whitespace. */
function trimEnd(s) {
  return s.replace(/[ \t\n\r\f\v]+$/, '');
}

/**
 * Split a migration/seed file into statements (docs/contracts.md §C7).
 *
 * A statement ends at a `;` outside quotes and comments (the file convention is one statement per `;` at end of
 * line; a mid-line `;` also splits). Comments (`-- `, `#`, `/* *\/`) between statements are dropped; comments
 * inside a statement stay in its text. `/*! ... *\/` executable comments count as code. A line comment
 * `-- @if-table-exists <table>` directly before a statement makes it conditional; any other `-- @...` comment is
 * an error, as is a directive inside a statement or a statement without a closing `;`.
 *
 * @param {string} source
 * @returns {{ sql: string, ifTableExists: string | null, line: number }[]}
 */
export function splitStatements(source) {
  const sql = String(source).replace(/^\uFEFF/, '').replace(/\r\n/g, '\n');
  const n = sql.length;
  const out = [];
  let i = 0;
  let line = 1;
  let start = -1; // index of the first character of the current statement, -1 between statements
  let startLine = 0;
  let directive = null; // { table, line }
  const fail = (msg, at) => {
    throw new Error(`line ${at}: ${msg}`);
  };
  /** Scan to the end of a block comment opened at i; returns the index after `*\/`. */
  const skipBlock = () => {
    const end = sql.indexOf('*/', i + 2);
    if (end === -1) fail('unterminated /* comment', line);
    for (let k = i; k < end; k++) if (sql[k] === '\n') line++;
    return end + 2;
  };

  while (i < n) {
    const c = sql[i];
    if (c === '\n') {
      line++;
      i++;
      continue;
    }
    if (WS.has(c)) {
      i++;
      continue;
    }
    const isDashComment = c === '-' && sql[i + 1] === '-' && (i + 2 >= n || WS.has(sql[i + 2]));
    if (isDashComment || c === '#') {
      let end = sql.indexOf('\n', i);
      if (end === -1) end = n;
      const text = sql.slice(i, end);
      if (isDashComment && DIRECTIVE_PREFIX_RE.test(text)) {
        if (start !== -1) fail('directive inside a statement', line);
        if (directive) fail('two directives before one statement', line);
        const m = IF_TABLE_EXISTS_RE.exec(text);
        if (!m) fail(`unknown or malformed directive: ${trimEnd(text)}`, line);
        directive = { table: m[1], line };
      }
      i = end; // the newline is counted by the loop
      continue;
    }
    if (c === '/' && sql[i + 1] === '*') {
      const executable = sql[i + 2] === '!' || (sql[i + 2] === 'M' && sql[i + 3] === '!');
      if (!executable) {
        i = skipBlock();
        continue;
      }
      if (start === -1) {
        start = i;
        startLine = line;
      }
      i = skipBlock();
      continue;
    }
    if (c === ';') {
      if (start === -1) {
        // empty statement (e.g. `;;`): nothing to run
        if (directive) fail('directive not followed by a statement', directive.line);
      } else {
        out.push({ sql: trimEnd(sql.slice(start, i)), ifTableExists: directive ? directive.table : null, line: startLine });
        start = -1;
        directive = null;
      }
      i++;
      continue;
    }
    if (start === -1) {
      start = i;
      startLine = line;
    }
    if (c === "'" || c === '"' || c === '`') {
      const quoteLine = line;
      let j = i + 1;
      for (;;) {
        if (j >= n) fail(`unterminated ${c} quote`, quoteLine);
        const d = sql[j];
        if (d === '\\' && c !== '`') {
          if (sql[j + 1] === '\n') line++;
          j += 2;
          continue;
        }
        if (d === '\n') line++;
        if (d === c) {
          if (sql[j + 1] === c) {
            j += 2;
            continue;
          }
          break;
        }
        j++;
      }
      i = j + 1;
      continue;
    }
    i++;
  }
  if (start !== -1) fail('statement not terminated by ;', startLine);
  if (directive) fail('directive not followed by a statement', directive.line);
  return out;
}

/**
 * List `*.sql` files of a directory matching `re`, sorted by byte order (as db.lua sorts index.json).
 * @param {string} dir
 * @param {RegExp} re
 * @returns {string[]}
 */
export function listSqlFiles(dir, re) {
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((name) => re.test(name) && statSync(join(dir, name)).isFile())
    .sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
}

/** Read and normalise a file: { text, checksum }. */
function loadFile(dir, name) {
  const bytes = normalizeBytes(readFileSync(join(dir, name)));
  return { text: bytes.toString('utf8'), checksum: createHash('sha256').update(bytes).digest('hex') };
}

// ---------------------------------------------------------------------------------------------------------------
// Database parts

/**
 * mysql2/promise. The root package does not depend on mysql2 yet (apps/service does), so fall back to the copy
 * installed for apps/service; fail with a clear message when neither resolves.
 */
async function loadMysql() {
  try {
    return (await import('mysql2/promise')).default;
  } catch {
    try {
      return createRequire(join(ROOT, 'apps', 'service', 'package.json'))('mysql2/promise');
    } catch (err) {
      throw new Error(
        'mysql2 is not installed: run `pnpm install` at the repository root (scripts/migrate.mjs uses the mysql2 ' +
          `installed for apps/service until the root package depends on it). ${err.message}`,
        { cause: err },
      );
    }
  }
}

/**
 * Open a mysql2/promise connection for a `mysql://user:pass@host:port/db` URL. The session keeps the server's
 * default time zone (FredPD SQL never depends on it); `timezone: 'Z'` makes mysql2 read DATETIME values into Dates
 * as UTC and write Dates as UTC text, which is what FredPD stores.
 * @param {string} url
 */
export async function connect(url) {
  if (!url) throw new Error('no database URL: pass --url or set FREDPD_DB_URL');
  const mysql = await loadMysql();
  return mysql.createConnection({ uri: url, charset: 'utf8mb4', timezone: 'Z', multipleStatements: false });
}

/**
 * Record an applied migration. If another runner recorded it meanwhile, its row stays and must carry the same
 * checksum (same text as recordMigration in db.lua).
 */
async function recordMigration(conn, f) {
  await conn.query(RECORD_MIGRATION_SQL, [f.id, f.checksum]);
  const [[row]] = await conn.query(RECORDED_CHECKSUM_SQL, [f.id]);
  const sum = String(row?.checksum);
  if (sum !== f.checksum) {
    throw new Error(`${f.id} was recorded concurrently by another runner with checksum ${sum.slice(0, 12)}…, file ${f.checksum.slice(0, 12)}…`);
  }
}

async function tableExists(conn, table) {
  const [rows] = await conn.query(TABLE_EXISTS_SQL, [table]);
  return Number(rows[0].n) > 0;
}

/** Rows of fredpd_migrations by id; the caller makes sure the table exists. */
async function readApplied(conn) {
  const [rows] = await conn.query('SELECT id, checksum, applied_at FROM fredpd_migrations');
  return new Map(rows.map((r) => [String(r.id), { checksum: String(r.checksum), appliedAt: r.applied_at }]));
}

/** splitStatements with the file id in front of its `line N: …` error (same text as runnable() in db.lua). */
function splitFile(id, text) {
  try {
    return splitStatements(text);
  } catch (err) {
    throw new Error(`${id}: ${err.message}`, { cause: err });
  }
}

/** Split a file and resolve the statements to run: drop conditional ones whose table is missing. */
async function runnable(conn, id, text, log, skipped) {
  const out = [];
  for (const [k, st] of splitFile(id, text).entries()) {
    if (st.ifTableExists && !(await tableExists(conn, st.ifTableExists))) {
      log(`[migrate] ${id}: skipped statement ${k + 1} (line ${st.line}), table ${st.ifTableExists} does not exist`);
      skipped.push(`${id}#${k + 1}`);
      continue;
    }
    out.push({ ...st, index: k + 1 });
  }
  return out;
}

function statementError(id, st, err) {
  const head = st.sql.split('\n')[0].slice(0, 80);
  const e = new Error(`${id}: statement ${st.index} (line ${st.line}) failed: ${err.message}\n  ${head}`);
  e.cause = err;
  return e;
}

async function withConnection(opts, fn) {
  const own = !opts.connection;
  const conn = opts.connection ?? (await connect(opts.url ?? process.env.FREDPD_DB_URL));
  try {
    return await fn(conn);
  } finally {
    if (own) await conn.end();
  }
}

/**
 * Apply pending migrations (and, with `seed`, new or changed seeds). Fails before anything runs when an applied
 * migration drifted. Any server or session time zone is fine (docs/contracts.md §C7); a caller-supplied
 * `connection` is used as it is.
 * @param {{ url?: string, connection?: object, migrationsDir?: string, seedDir?: string, seed?: boolean,
 *           log?: (msg: string) => void }} [opts]
 * @returns {Promise<{ applied: string[], seeded: string[], skipped: string[] }>}
 */
export async function migrate(opts = {}) {
  const { migrationsDir = MIGRATIONS_DIR, seedDir = SEED_DIR, seed = false, log = console.log } = opts;
  return withConnection(opts, async (conn) => {
    const [[lock]] = await conn.query('SELECT GET_LOCK(?, 60) AS ok', [LOCK_NAME]);
    if (Number(lock.ok) !== 1) throw new Error('could not acquire the migration lock (another runner is busy)');
    try {
      return await applyAll(conn, { migrationsDir, seedDir, seed, log });
    } finally {
      // Never let a failed release (e.g. a dropped connection) hide the original error; the server frees the
      // lock when the session ends anyway.
      await conn.query('SELECT RELEASE_LOCK(?)', [LOCK_NAME]).catch(() => {});
    }
  });
}

/** Steps 1-5 of the algorithm on a locked session. */
async function applyAll(conn, { migrationsDir, seedDir, seed, log }) {
  await conn.query(MIGRATIONS_TABLE_DDL);
  const applied = await readApplied(conn);
  const result = { applied: [], seeded: [], skipped: [] };

  const files = listSqlFiles(migrationsDir, MIGRATION_FILE_RE).map((name) => ({ id: name, ...loadFile(migrationsDir, name) }));
  for (const f of files) if (f.id.length > 64) throw new Error(`migration file name longer than 64 characters: ${f.id}`);

  // Fail before touching anything if an applied migration was edited.
  const drift = files.filter((f) => applied.has(f.id) && applied.get(f.id).checksum !== f.checksum);
  if (drift.length > 0) {
    const list = drift.map((f) => `${f.id} (applied ${applied.get(f.id).checksum.slice(0, 12)}…, file ${f.checksum.slice(0, 12)}…)`);
    throw new Error(
      `checksum mismatch for applied migration(s): ${list.join(', ')}. ` +
        'Never edit an applied migration; restore it and add a new NNN_*.sql instead.',
    );
  }
  const known = new Set(files.map((f) => f.id));
  for (const id of applied.keys()) {
    if (!id.startsWith(SEED_ID_PREFIX) && !known.has(id)) log(`[migrate] warning: ${id} is applied but its file is missing`);
  }

  for (const f of files) {
    if (applied.has(f.id)) continue;
    const statements = await runnable(conn, f.id, f.text, log, result.skipped);
    for (const st of statements) {
      try {
        await conn.query(st.sql);
      } catch (err) {
        throw statementError(f.id, st, err);
      }
    }
    await recordMigration(conn, f);
    result.applied.push(f.id);
    log(`[migrate] applied ${f.id}`);
  }

  if (seed) {
    for (const name of listSqlFiles(seedDir, SEED_FILE_RE)) {
      const id = SEED_ID_PREFIX + name;
      const f = loadFile(seedDir, name);
      if (applied.get(id)?.checksum === f.checksum) continue;
      const statements = await runnable(conn, id, f.text, log, result.skipped);
      await conn.beginTransaction();
      try {
        for (const st of statements) {
          try {
            await conn.query(st.sql);
          } catch (err) {
            throw statementError(id, st, err);
          }
        }
        await conn.query(RECORD_SEED_SQL, [id, f.checksum]);
        await conn.commit();
      } catch (err) {
        await conn.rollback();
        throw err;
      }
      result.seeded.push(id);
      log(`[migrate] seeded ${id}`);
    }
  }
  if (result.applied.length === 0 && result.seeded.length === 0) log('[migrate] up to date');
  return result;
}

/**
 * Report every migration and seed: applied | pending | changed (a migration: drift error; a seed: re-applied by
 * --seed) | missing (applied, file gone). Read-only: a database without fredpd_migrations reports everything
 * pending and is left without it.
 * @param {{ url?: string, connection?: object, migrationsDir?: string, seedDir?: string }} [opts]
 * @returns {Promise<{ id: string, state: 'applied' | 'pending' | 'changed' | 'missing', appliedAt: Date | null }[]>}
 */
export async function status(opts = {}) {
  const { migrationsDir = MIGRATIONS_DIR, seedDir = SEED_DIR } = opts;
  return withConnection(opts, async (conn) => {
    const applied = (await tableExists(conn, 'fredpd_migrations')) ? await readApplied(conn) : new Map();
    const rows = [];
    const add = (id, sum) => {
      const a = applied.get(id);
      rows.push({ id, state: !a ? 'pending' : a.checksum === sum ? 'applied' : 'changed', appliedAt: a?.appliedAt ?? null });
    };
    for (const name of listSqlFiles(migrationsDir, MIGRATION_FILE_RE)) add(name, loadFile(migrationsDir, name).checksum);
    for (const name of listSqlFiles(seedDir, SEED_FILE_RE)) add(SEED_ID_PREFIX + name, loadFile(seedDir, name).checksum);
    const listed = new Set(rows.map((r) => r.id));
    for (const [id, a] of applied) if (!listed.has(id)) rows.push({ id, state: 'missing', appliedAt: a.appliedAt });
    return rows;
  });
}

// ---------------------------------------------------------------------------------------------------------------
// CLI

function parseArgs(argv) {
  const args = { url: process.env.FREDPD_DB_URL, seed: false, status: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--seed') args.seed = true;
    else if (a === '--status') args.status = true;
    else if (a === '--url') args.url = argv[++i];
    else if (a.startsWith('--url=')) args.url = a.slice('--url='.length);
    else throw new Error(`unknown argument: ${a}`);
  }
  return args;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.status) {
    const rows = await status({ url: args.url });
    for (const r of rows) {
      const at = r.appliedAt instanceof Date ? r.appliedAt.toISOString().replace('T', ' ').slice(0, 19) : '';
      console.log(`${r.state.padEnd(8)} ${r.id.padEnd(40)} ${at}`);
    }
    if (rows.some((r) => r.state === 'changed' && !r.id.startsWith(SEED_ID_PREFIX))) process.exitCode = 1;
    return;
  }
  await migrate({ url: args.url, seed: args.seed });
}

/**
 * True when this file is the script node was started with. import.meta.url is already a real path but argv[1] is
 * not, so compare real paths: a symlinked checkout, a Windows junction or a subst drive must still run the CLI
 * instead of silently exiting 0.
 */
function isMain() {
  if (!process.argv[1]) return false;
  try {
    return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

if (isMain()) {
  main().catch((err) => {
    console.error(`[migrate] ${err.message}`);
    process.exit(1);
  });
}
