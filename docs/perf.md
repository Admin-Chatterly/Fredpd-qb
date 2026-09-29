<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Performance (task 8.1)

Two halves: **database timings** measured by an agent on the test database (below), and the **in-game resmon
measurement** that only Rami can run (procedure and a table to fill in at the end). Budgets come from
IMPLEMENTATION.md §4.7, §5.2, §5.5 and §5.9.

## Budgets

| What | Budget | Source |
|---|---|---|
| Tablet closed, client `fredpd_mdt` (and every other `fredpd_*`) | **0.00 ms** in resmon | §5.2 acceptance |
| Tablet open and idle, client `fredpd_mdt` | **≤ 0.05 ms** | §5.2 acceptance |
| Tablet open → first paint (dev build console line `[fredpd] open -> first paint … ms`) | **< 300 ms** on the host | §5.2 acceptance |
| New alert → toast on every on-duty officer | **≤ 100 ms** | §5.5 acceptance |
| Discord role change → in-game armory menu changes | **≤ 2 s** | §5.9 acceptance |
| Lists | paginated 50, server-side filters, indexed columns only | §4.7 |
| NUI while closed | `visibility:hidden` root, no `setInterval`, no `while true` / thread loops anywhere | §4.7, CLAUDE.md |
| Intel graph | ≤ 150 nodes, layout runs once then `stop()` | §4.7 |

No budget is written down for single queries; the working target used here is **≤ 5 ms median for anything that runs
on a tablet page open or a keystroke-triggered search** at the data sizes below, and no full-table scan on a table that
grows without bound (`fredpd_audit`, `fredpd_alerts`).

## Database timings (measured)

Script: [`scripts/perf/db-perf.mjs`](../scripts/perf/db-perf.mjs). It creates a scratch database
(`fredpd_test_perf`, dropped afterwards), applies `db/migrations` + seeds with `scripts/migrate.mjs`, loads
deterministic synthetic data (fixed PRNG seed) and times each hot query with the **same SQL the Lua resources send**
(copied from `fredpd_records/server/search.lua`, `cases.lua`, `lookupflag.lua` and
`fredpd_dispatch/server/alert_store.lua`). 5 warm-up runs, then 200 timed runs per query; times are client-side
round trips over TCP (mysql2 → local MariaDB), so they include the protocol, not only the execution.

```bash
node scripts/perf/db-perf.mjs                       # uses FREDPD_TEST_DB_URL (README "Development")
node scripts/perf/db-perf.mjs --persons 20000 --audit 200000 --cases 10000 --runs 100   # bigger server
node scripts/perf/db-perf.mjs --json > perf.json    # machine-readable, with the EXPLAIN rows
```

Run 2026-09-29 in the agent container (MariaDB 10.11.14, default InnoDB settings, 4 vCPU, data fully in the buffer
pool). Data: 5 000 persons, 6 000 vehicles, 2 000 cases (30 % open; 4 020 reports, 4 008 case subjects,
1 979 assignees), 20 150 audit rows, 3 000 alerts (40 open/assigned).

| Query (where it runs) | Rows | min | median | p95 | max | Plan (table: type/key) |
|---|---:|---:|---:|---:|---:|---|
| Personsök, namn, FULLTEXT `+lars* +nils*` (search.lua personPage) | 4 | 0.60 | 0.93 | 2.61 | 5.67 | p: fulltext/ft_name (Using where; Using temporary; Using filesort) |
| Personsök, namn, broad `+and*` (50-row page) | 50 | 1.20 | 1.42 | 2.97 | 7.62 | p: fulltext/ft_name (Using where; Using temporary; Using filesort) |
| Personsök, short term "Bo" (REGEXP word-start scan, worst case) | 50 | 3.21 | 4.12 | 5.49 | 7.61 | p: **ALL** (Using where; Using temporary; Using filesort) |
| Personsök, personnummer (search.lua searchPersonId) | 1 | 0.12 | 0.19 | 0.65 | 2.98 | p: range/idx_personnummer |
| Registreringsnummer (search.lua VEHICLE_SQL) | 1 | 0.10 | 0.15 | 0.33 | 0.61 | v: const/PRIMARY; p: const/PRIMARY |
| Ärendelista "Mina" (owner ∪ assignee, cases.lua listCases) | 72 | 0.44 | 0.84 | 1.23 | 5.74 | derived union of ref/idx_owner + ref/idx_citizenid; c: eq_ref/PRIMARY |
| Ärendelista "Öppna" (LIST_SCAN 500) | 500 | 1.17 | 1.76 | 2.49 | 4.63 | c: range/idx_status_updated (Using filesort) |
| Ärendelista "Alla" + fritext "stöld" | 288 | 1.37 | 1.90 | 2.74 | 6.85 | c: **ALL** (Using where; Using filesort) |
| Personsida: ärenden där personen är inblandad | 1 | 0.12 | 0.16 | 0.44 | 1.05 | s: ref/idx_subject; c: eq_ref/PRIMARY |
| Ärendets händelser (audit by target, 150+ rows on the case, cases.lua timeline) | 100 | 0.64 | 0.96 | 1.28 | 2.35 | a: range/idx_target (Using filesort) |
| Obehörig sökning: recent lookups (runs on every person lookup, lookupflag.lua) | 28 | 0.61 | 1.03 | 1.46 | 4.12 | a: range/idx_actor_created; s: ref/idx_subject; ca: unique_subquery/PRIMARY |
| Larm, öppna: COUNT (alert_store.lua list) | 1 | 0.10 | 0.14 | 0.39 | 0.59 | a: range/idx_status_created (Using index) |
| Larm, öppna: page 1, `id DESC` | 40 | 0.11 | 0.14 | 0.36 | 0.84 | a: range/idx_status_created (Using index; Using filesort) |
| Larm, mina (join `fredpd_alert_units`) | 0 | 0.16 | 0.22 | 0.59 | 1.53 | u: ref/idx_citizenid; a: eq_ref/PRIMARY |

Times in ms.

### Reading the results

- **Everything is inside the 5 ms median target.** The index-backed lookups (plate, personnummer, person's cases,
  alerts) answer in ≈ 0.1–0.2 ms, i.e. protocol cost only. FULLTEXT name search is ≈ 1–1.5 ms median.
- **Audit by target** uses `idx_target` (range over the case + its report ids) and sorts at most the matching rows;
  it does not grow with the total audit size, only with one case's history (capped at 100 rows returned).
- **Obehörig-sökning check** uses `idx_actor_created` (actor + last 60 min), so it stays flat as `fredpd_audit`
  grows; the `NOT EXISTS` probe goes through `idx_subject` and the assignee primary key.
- **Two full scans, both known and bounded:**
  1. *Short-term name search* ("Bo", "Li", stopwords): no index can hold terms under
     `innodb_ft_min_token_size` (docs/modules/records.md "Short-term scan"). 4 ms at 5 000 persons, linear in
     `fredpd_persons` (≈ 16 ms at 20 000). Acceptable: it runs only on an explicit search, never on page open.
     If it ever matters, set `innodb_ft_min_token_size = 2` in `my.ini` and rebuild the index
     (`OPTIMIZE TABLE fredpd_persons` with `innodb_optimize_fulltext_only = ON`); search.lua reads the setting at start.
  2. *Case list "Alla" with free text*: `LIKE '%…%'` on number and title cannot use an index. 2 ms at 2 000 cases,
     linear in `fredpd_cases`; the list is capped by `LIST_SCAN` (500) after the sort. Acceptable for years of
     cases; a FULLTEXT key on `fredpd_cases(title)` would be the fix if a server reaches ~50 000 cases.
- `Using temporary; Using filesort` on the person searches comes from `COUNT(*) OVER ()` + `ORDER BY lastname,
  firstname`; it sorts only the matching rows (≤ a few hundred for a real name), which is what the timings show.
- Alerts: the open list is a range on `idx_status_created`; closed alerts (the growing part) are never read by the
  default filter. `filter = 'all'` pages by primary key.
- Nothing polls: every query above runs only on a user action or a push-triggered refetch of an **open** tablet.

## In-game measurement (Rami)

Agents cannot run FiveM, so this part is a procedure. Run it on the **test server** (it needs `fredpd_devtools`,
which must never be ensured in production) with a **development build** of the tablet so the first-paint line is logged:
`pnpm --filter @fredpd/nui exec vite build --mode development`, then `node scripts/build.mjs --skip-web` (copies it
into `fredpd_mdt/web/build` without rebuilding it for production). Rebuild normally (`scripts\build.ps1`) before
production. About 30 minutes. Write the numbers into the table at the end and commit it (or send it to the agent).

### Setup

1. server.cfg (test server): `ensure fredpd_devtools`, `set fredpd_dev true`, and for oxmysql's query statistics
   `set mysql_ui true` (then `/mysql` in game as admin shows per-resource query counts and times) and
   `set mysql_slow_query_warning 50` (oxmysql logs every query slower than 50 ms to the console).
2. Restart the server. Join with an admin character that is police, on duty, with `mdt_page:*` and a tablet.
3. Optional realism: `/fredpd_seed 200` (persons, vehicles, cases).

### What to run and record

| # | Situation | How | Record |
|---|---|---|---|
| 1 | Baseline, tablet **closed** | F8 → `resmon 1`, stand still 30 s | client ms of every `fredpd_*` resource and `ps-dispatch` (budget 0.00) |
| 2 | Tablet **open**, idle on Hem | open, wait 30 s without touching | `fredpd_mdt` client ms (budget ≤ 0.05); CPU/"NUI" row if shown |
| 3 | Open → first paint | open/close the tablet 5 times | the 5 values of `[fredpd] open -> first paint … ms` in F8 (budget < 300; note the worst) |
| 4 | Load: 20 fake units + alerts | `/fredpd_fakeunits 20 300` (20 units, an alert every 5 s, stops after 300 s) | during the run, tablet **closed**: client ms of `fredpd_dispatch`/`fredpd_mdt`; toast arrives every 5 s |
| 5 | Load, tablet open on **Larm** | same run, tablet open on Larm → Öppna | `fredpd_mdt` client ms (spikes when a push arrives, back to ≈ 0 between); the list updates without reopening |
| 6 | Load, portal Larm | same run, portal Larm page open in a browser | the list updates live; service log shows no errors or 429s |
| 7 | Server side | txAdmin → Live Console during #4: `profiler record 500`, then `profiler view` (opens the profiler in the browser) — or read the txAdmin dashboard's server thread chart | server ms of `fredpd_dispatch`, `fredpd_core`, `fredpd_mdt` (should be single-digit ms spikes every 5 s, nothing in between) |
| 8 | Queries | `/mysql` (mysql_ui) after #4 | slowest query and total queries per `fredpd_*` resource; any slow-query warnings in the console |
| 9 | Toast latency (§5.5) | two officers side by side (or one screen + stream), `/fredpd_testalert` | does the toast appear on both "at once"? (subjective; > ~0.3 s visible delay is a fail) |
| 10 | Role change → armory (§5.9) | remove a weapon grant in the portal, reopen the armory | seconds until the item is gone (budget ≤ 2 s) |
| 11 | Stop | `/fredpd_fakeunits 0` | the fake units disappear from Enheter; resmon back to row 1 values |

### Results (fill in)

| # | Value | Budget | Pass? | Notes |
|---|---|---|---|---|
| 1 | | 0.00 ms | | |
| 2 | | ≤ 0.05 ms | | |
| 3 | worst: | < 300 ms | | |
| 4 | | ≈ 0.00 ms between alerts | | |
| 5 | | ≤ 0.05 ms idle, short spikes | | |
| 6 | | live, no errors | | |
| 7 | | spikes only on ticks | | |
| 8 | slowest: | < 50 ms, no warnings | | |
| 9 | | ≤ 100 ms | | |
| 10 | | ≤ 2 s | | |
| 11 | | back to baseline | | |

Host: CPU ______, RAM ______, players online ______, date ______.
