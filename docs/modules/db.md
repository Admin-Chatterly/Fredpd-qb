<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Module: database (task 1.1; schema for IMPLEMENTATION.md §6)

Implements docs/contracts.md §C7. Owned files:

| File | Purpose |
|---|---|
| `db/migrations/001_core.sql` … `008_tablets.sql` | schema, one file per §6 line |
| `db/seed/charges_sv.sql` | Brottskatalog, 127 rows |
| `db/dev/qbx_stub.sql` | minimal qbx `players` / `player_vehicles` for tests (never on a server) |
| `resources/[fredpd]/fredpd_core/server/db.lua` | canonical runner (oxmysql) + query helpers |
| `resources/[fredpd]/fredpd_core/shared/sha256.lua` | pure Lua SHA-256 for checksums |
| `resources/[fredpd]/fredpd_core/shared/time.lua` | UTC timestamps: `isoSelect`, `toIsoUtc`, `toDatetime`, `toEpoch`, `nowIso` |
| `scripts/migrate.mjs` | same runner on mysql2 (dev, CI, service tests) |
| `tests/lua/db_test.lua`, `tests/lua/time_test.lua`, `tests/lua/mysql_shim.lua` | Lua tests; fake `MySQL` global backed by the `mariadb` CLI |
| `packages/types/test/migrations.test.ts` | Node tests + Lua/Node parity |

## Time zones: UTC storage on any server

docs/contracts.md §C7. FredPD stores every DATETIME as **UTC** and does not care which time zone the MariaDB server
or session uses (a Windows MariaDB defaults to `SYSTEM` = Europe/Stockholm; nothing has to change in `my.ini`, and
other resources on the same server keep their local-time data):

- **Defaults** are `DEFAULT (UTC_TIMESTAMP())`: an expression default (MariaDB 10.2+). MariaDB also takes it without
  the parentheses, MySQL 8 does not, so the parenthesised form is the one convention (linted). Never
  `CURRENT_TIMESTAMP`/`NOW()` (session clock).
- **No `ON UPDATE`.** MariaDB has no `ON UPDATE UTC_TIMESTAMP()`, so every writer sets `updated_at = UTC_TIMESTAMP()`
  itself. Lua upserts use `Core.buildInsert(..., touch = 'updated_at')`, which puts
  `updated_at = IF(BINARY a <=> BINARY VALUES(a) AND …, updated_at, UTC_TIMESTAMP())` **first** in the
  `ON DUPLICATE KEY UPDATE` list (MariaDB assigns left to right, so it still sees the old values): like the old
  `ON UPDATE`, only a real change (byte comparison, so a case-only change counts) moves it. `charges_sv.sql` does
  the same by hand. Plain `UPDATE`s add `, updated_at = UTC_TIMESTAMP()` and a `WHERE` that skips unchanged rows
  where that matters (units sync, officer relink). The service's drizzle schema sets it through `$onUpdate`.
- **Writes** use `UTC_TIMESTAMP()` (and `UTC_TIMESTAMP() - INTERVAL n DAY` for cutoffs); a timestamp from the wire
  is bound as `Time.toDatetime(iso)` (Lua) or a JS `Date` (mysql2 `timezone: 'Z'` writes it as UTC text).
- **Reads in Lua**: oxmysql turns DATETIME into epoch milliseconds read in the FXServer host's **local** zone (off
  by 1–2 h on a Stockholm host). Select DATETIME as text instead: `Time.isoSelect('b.created_at', 'createdAt')` →
  `DATE_FORMAT(b.created_at, '%Y-%m-%dT%H:%i:%sZ') AS createdAt` (identifiers validated; the `%` means the finished
  SQL must not go through `string.format`). `Time.toIsoUtc(v)` normalises `YYYY-MM-DD HH:MM:SS`/ISO text (numbers
  raise, with that explanation). `Time.nowIso()` = `os.date('!%Y-%m-%dT%H:%M:%SZ')`.
- **Reads in Node**: mysql2 with `timezone: 'Z'` (service pool, `migrate.mjs`), drizzle reads text and appends `Z`.
- The runners never check or set the time zone. `db/dev/qbx_stub.sql` keeps upstream qbx's `TIMESTAMP … ON UPDATE
  CURRENT_TIMESTAMP` (it mirrors a table FredPD does not own; `TIMESTAMP` is stored zone-independently anyway).
- Guards: db_test.lua and migrations.test.ts reject `CURRENT_TIMESTAMP`, `NOW()`, `LOCALTIME…`, `SYSDATE/CURDATE/
  CURTIME(`, `ON UPDATE <clock>` and an unparenthesised `DEFAULT UTC_TIMESTAMP` in every migration/seed statement,
  and migrations.test.ts rejects the session-clock functions in all FredPD Lua/JS/TS code (`resources/[fredpd]`,
  `apps/service/src`, `scripts`; upper-case `NOW()` only, since `x.now()` is a clock call).

## Runner algorithm (both runners)

No time zone step: `applied_at`, `created_at` and seeded rows get `(UTC_TIMESTAMP())` defaults in any session, and a
caller-supplied `connection` (migrate.mjs) is used as it is.

1. `CREATE TABLE IF NOT EXISTS fredpd_migrations` (`MIGRATIONS_TABLE_DDL`, byte-identical to the first statement of
   001; a test checks all three copies).
2. Migrations: file names matching `^\d{3}_.+\.sql$` (≤ 64 chars), sorted by bytes. Node reads `db/migrations`;
   Lua reads `migrations/index.json` + files from the resource (`scripts/build.mjs` copies them).
3. Checksum = sha256 hex of the file bytes after dropping a UTF-8 BOM and turning CRLF into LF, so Windows and Linux
   checkouts agree. Any applied migration whose checksum differs → error **before anything runs**. Applied ids
   without a file only log a warning.
4. Each pending file: split (below), run statement by statement, then record `(id, checksum)` with
   `ON DUPLICATE KEY UPDATE id = id` and re-read the row: a row another runner recorded meanwhile is fine if its
   checksum matches, else an error. MariaDB DDL auto-commits, so a file is not atomic; `IF NOT EXISTS` everywhere
   makes a half-applied file safe to re-run.
5. Seeds (`db/seed/*.sql`, Lua `migrations/seed/index.json`) are recorded as `seed/<file>` and run when new **or
   changed**; each seed and its record commit in one transaction. A changed seed is re-applied, never an error, so
   seeds must be idempotent upserts. Node applies seeds only with `--seed`; Lua applies them unless `seed = false`.

**Splitting.** A statement ends at `;` outside quotes (`'` `"` with backslash and doubled-quote escapes, `` ` ``)
and comments (`-- ` + whitespace, `#`, `/* */`). Comments between statements are dropped, comments inside stay.
`/*! */` counts as code. `-- @if-table-exists <table>` right before a statement makes it conditional
(`information_schema.tables` in the current schema); any other `-- @…` comment, a directive inside a statement, two
directives, a dangling directive, an unterminated quote/comment or a final statement without `;` is an error
`line N: …` from `splitStatements`, and `<file>: line N: …` from a run (identical text in both runners, tested).
A broken file fails when its turn comes: the migrations before it are applied and recorded. Whitespace is ASCII
only in both.

**Conditional statements are decided once**: if `player_vehicles` does not exist when 002 runs, its index is never
added later. Install qbx tables before first starting FredPD.

**Locking.** migrate.mjs holds `GET_LOCK('fredpd_migrate')` on its single connection, which serialises Node runs.
The Lua runner cannot (a lock belongs to one connection and oxmysql pools them). A Lua run racing a Node run
executes the same idempotent statements twice and both record the same row (tolerated, step 4), so it is safe but
wasteful; avoid running `migrate.mjs` against the live database while FXServer is starting.

## Using it

Lua (fredpd_core owner): fxmanifest needs `'@oxmysql/lib/MySQL.lua'` in `server_scripts` and the build-copied
`migrations/` folder on disk. Do **not** list `migrations/` under `files`: server-side `LoadResourceFile` reads
any file of the resource, and `files` would only stream the schema and seeds to every client. Load with
`local db = require 'server.db'` (not a server_script) and run once on start:

```lua
MySQL.ready(function()
    local ok, err = pcall(db.migrate)          -- { applied, seeded, skipped } or raises
    if not ok then error(('database migration failed: %s'):format(err)) end
end)
```

`db.migrate(opts)`: `opts.seed` (default true), `opts.log`, `opts.resource`.
Helpers: `db.query/scalar/single/
insert/update/transaction` (thin `MySQL.*.await` wrappers, coroutine only), `db.nextSeq(seqType, year)` (atomic
`{{seq}}` counter; the insert id of `INSERT … LAST_INSERT_ID(value + 1)`; verified through mysql2, which oxmysql uses),
`db.splitStatements`, `db.checksum`, `db.normalize`, `db.sortNames`. The helpers are raw access: gameplay writes to
`fredpd_*` must still go through the audited core helpers.

Node: `node scripts/migrate.mjs [--url mysql://…] [--seed] [--status]` (`FREDPD_DB_URL`).
`--status` is read-only (on a database without `fredpd_migrations` it reports everything pending and creates
nothing); exit 1 when an applied migration changed. The CLI runs when the real path of `argv[1]` is this file, so
a symlinked checkout, a Windows junction or a `subst` drive work too.
Exports `migrate`, `status`, `connect`, `splitStatements`, `checksum`, `normalizeBytes`, `listSqlFiles`,
`MIGRATIONS_TABLE_DDL`, … (`connect()` keeps the server's session zone; `timezone: 'Z'` for Dates). The root package does not depend on mysql2, so
migrate.mjs falls back to `apps/service`'s copy and says `run pnpm install` when neither resolves (open questions).

### Joining qbx tables

qbx_core `players` and qbx_vehicles `player_vehicles` are `utf8mb4_unicode_ci`; FredPD tables are
`utf8mb4_swedish_ci`. Comparing a FredPD string column with a qbx one (`p.citizenid = v.citizenid`,
`p.license = i.license`) fails with `ERROR 1267 Illegal mix of collations`. Never compare them bare:

- put `COLLATE` on the side you drive **from**, so the other table's index stays usable. The portal character
  list (driven by the identity row, looked up in `players` by its `license` index):
  `SELECT p.citizenid, p.charinfo FROM fredpd_identities i JOIN players p ON p.license = i.license COLLATE
  utf8mb4_unicode_ci WHERE i.discord_id = ?` (EXPLAIN: `ref`/`range` on `players.license`; db_test.lua asserts
  the plan and the ERROR 1267 of the bare join).
  Driving from qbx into a FredPD index, collate the qbx side: `… ON f.citizenid = p.citizenid COLLATE
  utf8mb4_swedish_ci`;
- or use two queries (read the keys, then `WHERE x IN (?, …)`): bound parameters are coerced to the column's
  collation and never clash.

`db/dev/qbx_stub.sql` uses the upstream collations, so a bare join fails in tests exactly as on a server.

## Writing a new migration

`NNN_name.sql`, never edit one that has been applied anywhere. `CREATE TABLE IF NOT EXISTS`, `ADD COLUMN IF NOT
EXISTS`, `CREATE INDEX IF NOT EXISTS`, InnoDB + `utf8mb4_swedish_ci` + `created_at DATETIME NOT NULL DEFAULT
(UTC_TIMESTAMP())` (db_test.lua lints 001–008 for this), no `ON UPDATE`, no session-clock function (linted in every
file). 001–009 were edited in place for the UTC change before anything was deployed (checksums changed; the test
databases rebuild themselves, see Tests). No `DELIMITER`, procedures or triggers. No `?` anywhere in a statement, not even in a string or comment:
oxmysql binds every `?` to NULL when a statement has no parameters (both test suites reject it).

## Seeds are the source of truth

A seed re-runs whenever its file changes (Lua: on the next FXServer start). Consequences for other modules:

- `charges_sv.sql` upserts `category`, `title_sv`, `law_ref`, `class`, `fine` and `jail_min` on `code`, so the
  file owns those values: an edit made in the Brottskatalog UI (task 5.4) is overwritten the next time the file
  changes. The UI may only toggle `active` (the one column the seed never writes) and add codes outside the
  seeded prefixes; value changes go into `charges_sv.sql` via a pull request.
- `visibility_rules_default.sql` (grants-canview module) inserts missing default ids with
  `ON DUPLICATE KEY UPDATE id = id`, so a default rule an admin **deleted** comes back on the next re-apply, which
  would silently restore a permissive rule. Default rules (ids 1–998 reserved, 999 a disabled sentinel so admin
  rules start at 1000; see the seed header) must be switched off with `enabled = 0`, never deleted; the admin UI
  should offer "disable", not "delete", for them.

## Schema decisions

- **Types**: `citizenid VARCHAR(50)` (qbx_core), Discord ids `VARCHAR(20)`, units `VARCHAR(32)`, levels `TINYINT
  UNSIGNED CHECK (level <= 2)`, JSON columns (MariaDB `LONGTEXT` + `json_valid`). Times are `DATETIME` in UTC
  (see "Time zones").
- **FKs** only between FredPD tables. Attachments cascade (assignees, subjects, drafts, alert units, mission members,
  role grants, graph links); records are kept (reports, charges applied, evidence, intel reports reference with the
  default RESTRICT, or SET NULL for optional links such as `template_id`).
- **fredpd_role_grants**: `UNIQUE (discord_role_id, grant_type, grant_key)` — a role cannot both allow and deny a
  key; the admin PUT replaces rows. FK to `fredpd_roles` with `ON DELETE CASCADE` (roles are soft-deleted with
  `deleted = 1`). **Upsert `fredpd_roles` only with `INSERT … ON DUPLICATE KEY UPDATE`** (drizzle
  `onDuplicateKeyUpdate`), never `REPLACE INTO`: REPLACE deletes the old row, and the cascade then silently wipes
  every grant of that role (bot role import, task 1.7).
- **fredpd_officers**: PK `citizenid` (records follow the character). `UNIQUE (discord_id, citizenid)` is implied by
  the PK but kept as the index for "all rows of this Discord user"; `discord_id` alone is **not** unique (one user,
  several characters). `UNIQUE (unit, callsign)`; NULL callsigns may repeat.
- **fredpd_audit** indexes: `(target_type, target_id)`, `(actor_citizenid, created_at)` (per-officer + obehörig
  sökning), `(actor_discord, created_at)` (portal actors without character), `(created_at)` (monthly archive).
  `fredpd_audit_archive` has the same columns + `archived_at`; its id is copied, not AUTO_INCREMENT.
- **fredpd_units**: SQL mirror of `config/units.json` (config stays the source; fredpd_core should upsert it at
  start). Nothing fills it yet.
- **fredpd_sequences** `(seq_type, year, value)`: `year` is the Europe/Stockholm year, 0 = never resets.
  Per-parent `{{n}}` (reports, evidence) is `MAX(n) + 1` in the inserting transaction, guarded by `UNIQUE (case_id, n)`.
- **fredpd_visibility_rules**: §C3 columns; `record_status`, `viewer_condition`, `result` are ENUMs (a new value
  needs a migration and a contract change anyway); `record_type` is free text (`'*'` = all).
- **fredpd_persons** adds `personnummer` (normalised `YYMMDD-XXXX`/`YYYYMMDD-XXXX`, indexed) because the `personId`
  search type needs a column; `FULLTEXT ft_name (firstname, lastname)` + `idx_name (lastname, firstname)`.
- **Plates** in `fredpd_vehicles_idx` and `fredpd_bolos` are meant to be stored normalised like
  `detectSearchType` (upper case, no spaces) so lookups are key hits.
- `fredpd_missions.lead_citizenid` (plan: `lead`; LEAD is reserved in MySQL 8). `fredpd_shares.token_hash` stores
  sha256 of the token, never the token. `fredpd_charges` adds `category` (English key) and `active`;
  `fredpd_records` snapshots title/class/fine/jail at issue time. `fredpd_evidence.case_id/n/tag` are NULL until
  "Koppla till ärende". `fredpd_release_requests.target_*` optional + `description`.

## FULLTEXT caveats (for task 1.4)

InnoDB indexes words of ≥ `innodb_ft_min_token_size` (default 3) characters and skips its stopword list, so
two-letter names (`Bo`, `Li`) are not in `ft_name`. Either set `innodb_ft_min_token_size=2` and
`innodb_ft_enable_stopword=0` in `my.ini` (needs a MariaDB restart) and rebuild `ft_name` (drop and re-add it in a
new migration), or fall back to `lastname LIKE 'x%'` on `idx_name` for short tokens. Use `IN BOOLEAN MODE` with `+word*` terms. Measured here:
200 persons, `+nilsson*` → 0.7 ms, EXPLAIN `type = fulltext, key = ft_name`.

## Charge catalogue

Codes `BRB-`, `TRF-`, `NAR-`, `VAP-`, `ORD-`, `OVR-` + 3 digits are permanent (records reference them; retire with
`active = 0`, which the seed never overwrites). Fines are game-balanced SEK, `jail_min` game minutes, speeding in 9
bands (ordningsbot up to 30 km/h over, bot above). `law_ref` values are best effort and need Rami's review
(task 5.4); several are chapter-level on purpose. No licence points.

## Tests

- `lua5.4 tests/lua/run.lua tests/lua/db_test` — sha256 vectors, splitter, conventions and session-clock lint, and
  real `db.migrate()` runs on `fredpd_test_db_lua` via the shim, one of them with every session at `+02:00`
  (defaults and a re-applied seed's `applied_at` are UTC; skipped with a notice when MariaDB is unreachable).
  `run.lua time_test` covers shared/time.lua (plus a DATE_FORMAT round trip in a `+02:00` session).
  The expected seed list is read from `db/seed`, so other modules may add seeds. (`run.lua db_test` also matches
  core_db_test.)
- `pnpm exec vitest run --project types migrations` — splitter cases (also fed through db.lua for parity), seed
  checks, session-clock lint of all FredPD code, CLI through a symlinked path, Node runner on `fredpd_test_db`
  (read-only status, fresh, no-op rerun, drift, UTC writes on a `+02:00` caller connection, FULLTEXT/EXPLAIN, schema
  incl. every DATETIME default = `utc_timestamp()` and no `on update`), Lua runner via
  `lua5.4 tests/lua/mysql_shim.lua migrate`, then identical `fredpd_migrations` rows, columns, indexes, FKs, checks
  and seed data in both databases, and the same `<file>: line N: …` error from both for a malformed file. The last
  test on `fredpd_test_db*` leaves both holding only an empty `fredpd_migrations`. The **time zone regression**
  then sets the server's `GLOBAL time_zone` to `+02:00` (restored in `finally`; falls back to `+02:00` sessions with a
  warning if the user lacks the privilege), runs both runners on `fredpd_test_utc_node` / `fredpd_test_utc_lua` and
  checks that `applied_at`, `created_at` (migrations, charges, rules, fresh audit/tablet/role rows), `issued_at` and
  `updated_at` defaults are within a minute of `UTC_TIMESTAMP()` and two hours off the session clock, then drops both.
- Server/credentials from `FREDPD_TEST_DB_URL` (default `mysql://fredpd:fredpd@127.0.0.1:3306/fredpd_test`); the
  tests drop and recreate `fredpd_test_db` and `fredpd_test_db_lua`; `fredpd_test_core_lua` is reset once per Lua
  run; the service's `setupTestDb` drops and rebuilds its database when an applied migration's checksum changed or
  its file is gone (under a per-database `GET_LOCK`, so parallel test files rebuild it once). Any server time zone
  works.
- The shim keeps the server's default session time zone like oxmysql; `shim.sessionTimeZone = '+02:00'` (or
  `install({ sessionTimeZone = … })`, CLI `--time-zone=+02:00`) simulates a non-UTC server. core_db_test.lua runs
  all its sessions at `+02:00`.

## Open questions

- Add `mysql2` as a root devDependency so `scripts/migrate.mjs` does not borrow `apps/service`'s copy (needs
  `pnpm add -Dw mysql2`, which this module may not run).
- IMPLEMENTATION.md §6 still says `created_at DATETIME DEFAULT CURRENT_TIMESTAMP`; docs/contracts.md §C7 (UTC
  defaults) supersedes it. Not edited here (not owned).
- The time zone regression briefly changes the test server's `GLOBAL time_zone`. FredPD code does not care, but
  a non-FredPD process on the same test server that opens a session in that window gets `+02:00`.
- fredpd_core's fxmanifest lists `'migrations/*'` under `files`; the core owner should remove it (see "Using it").
- A per-seed apply-once mode (e.g. a `-- @seed-once` header) would stop re-inserting deleted visibility rules, but
  extends the §C7 directive grammar and means new default rules need a migration; not done, disable-not-delete
  is documented instead.
- `fredpd_units` sync from `config/units.json` belongs to fredpd_core (not implemented here).
