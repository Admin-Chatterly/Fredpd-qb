<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Module: fredpd_records (Phase 2 read paths, Phase 5 writes)

Tasks 2.3/2.4/2.5 server side and the "my cases" part of 2.7 (IMPLEMENTATION.md §5.3, §4.2, §4.5–§4.7, §8.6;
docs/contracts.md §C3, §C7, §C12; shapes in `packages/types/src/mdt.ts`), and Phase 5 tasks 5.1, 5.3 server, 5.4
catalogue read, 5.5 server, 5.6 server (§C14; `packages/types/src/records.ts`). Phase 5 is described in
["Phase 5 writes"](#phase-5-writes) at the end.

## Files

| File | Role |
|---|---|
| `fredpd_records/fxmanifest.lua` | server only; deps `ox_lib`, `oxmysql`, `fredpd_core` (fredpd_bolo optional); no framework/inventory/target/doorlock dependency (§C17) |
| `server/main.lua` | registers the exports, each wrapped so a Lua error becomes `{ ok = false, error = 'unavailable' }` (logged) |
| `server/common.lua` | result helpers, row coercion, input checks, pcall-guarded calls to fredpd_core / fredpd_bolo / housing adapter |
| `server/caserefs.lua` | cases + assignees → `canViewMany` → `CaseRef` (full / masked / notice; none omitted) |
| `server/search.lua` | `search` |
| `server/summary.lua` | `getPersonSummary`, `getVehicleSummary`, `getHomeCases`, `countMyOpenCases` |
| `test/contract.test.ts`, `test/golden/*.json`, `test/tsconfig.json` | zod check of the Lua output |
| `tests/lua/records_env_test.lua` (harness), `records_search_test.lua`, `records_summary_test.lua` | Lua tests |

## Exports (§C12 convention: `(src, input)` → `{ ok = true, data }` or `{ ok = false, error }`)

| Export | Input | `data` |
|---|---|---|
| `search(src, input)` | `SearchInput` | `SearchOutput` |
| `getPersonSummary(src, { citizenid })` | | `PersonSummary` |
| `getVehicleSummary(src, { plate })` | | `VehicleSummary` |
| `getHomeCases(src, { limit? })` | limit 1–10, default 10 | `CaseRef[]` (HomeOutput.myCases) |
| `countMyOpenCases(src)` (**addition**) | | integer (HomeOutput.counts.myOpenCases) |

Every export re-validates its input (the dispatcher already did, but any server resource can call exports):
`src` must be a positive integer, strings trimmed/length-checked in code points, no control characters, valid
UTF-8, pages/limits integers in range. `search`/`getPerson…`/`getVehicle…` also re-check `mdt_page:search` via
`exports.fredpd_core:hasGrant` (cheap, in memory). `getHomeCases`/`countMyOpenCases` require *any* `mdt_page`
grant (the same gate fredpd_mdt applies to opening the tablet and to `getHome`, whose dispatcher entry has
`grant = nil`); there is no `mdt_page:home` key in `MDT_PAGE_KEYS`, so checking one would lock everyone out. The key
list is duplicated in `server/common.lua` `MDT_PAGE_KEYS` — keep it in sync with packages/types/src/mdtPages.ts. Duty and rate limits are left to the dispatcher. The actor for
"my cases" is `exports.fredpd_core:getCitizenId(src)`, never an argument. Errors: `validation`, `unauthorized`,
`not_found`, `unavailable` (DB error, formats.json missing).

## Search

- `auto` → `detectSearchType` (shared/format.lua, `config/formats.json` read with
  `LoadResourceFile('fredpd_core', 'config/formats.json')`, compiled once). Explicit `person` = personnummer if it
  looks like one, else name; `vehicle` = plate (upper case, whitespace removed, any characters, so GTA plates work);
  `case` = case number upper-cased. `detected` reports what ran.
- **name**: terms = runs of letters/digits (ASCII alnum + letters beyond ASCII; every ASCII punctuation character,
  Latin-1/general punctuation, zero-width and curly quotes separate), max 6 terms × 32 chars. Each term becomes
  `+term*` in `MATCH (p.firstname, p.lastname) AGAINST (? IN BOOLEAN MODE)` (all required, prefix). Terms the index
  cannot hold must instead **start a word** anywhere in the name: `CONCAT_WS(' ', firstname, lastname) REGEXP ?`
  with the bound pattern `WORD_START .. term`, where `WORD_START` = `(^|[^[:alnum:]` + the non-ASCII word ranges of
  `isWordCodePoint` as explicit `\x{…}` ranges `])` (regex characters escaped anyway; case-insensitive under the
  `_ci` collation). Listing the ranges makes Å/Ä/Ö word characters even on a PCRE2 build without UCP, so `rn` never
  finds "Björn" (tested, including the class itself in SQL). This is a deliberate deviation from the task's `LIKE 'x%'` on
  lastname/firstname: LIKE missed `Li` in "Anna-Li" and `la` in "de la Cruz", and with `firstname` unindexed the
  OR scanned anyway. A term needs the fallback when shorter than `@@innodb_ft_min_token_size` (read once, default
  3) or, with `innodb_ft_enable_stopword` on, when it is a stopword **or a prefix of one** (InnoDB does not index
  `will`, `de`, `la` …, so `Wil` would miss "Will"). With at least one FULLTEXT term the REGEXP only filters the
  rows `ft_name` found. No term left (e.g. `%_%`, `'--`) → no hits (never "everything"). Boolean operators can
  never reach MATCH (asserted on every sent statement in the tests); all user text is a bound parameter. Order
  `lastname, firstname, citizenid`.
- **personId**: `personnummer IN (…)`: `YYMMDD-XXXX` also matches `19`/`20` + it, `YYYYMMDD-XXXX` also matches the
  10-digit form (index-friendly instead of core.md's `RIGHT(personnummer, 11)`; EXPLAIN `idx_personnummer`).
- **plate**: PK lookup on `fredpd_vehicles_idx` (+ owner name from `fredpd_persons`); on a miss one
  `exports.fredpd_core:refreshPlate(plate)` and a re-read. **caseNumber**: exact `case_number`, shaped by canView;
  `none` is omitted **and not counted** (existence does not leak).
- Pagination 50; total by `COUNT(*) OVER ()` in the same statement (MariaDB ≥ 10.2); a page past the end runs one
  `COUNT(*)`. `SQL_CALC_FOUND_ROWS`/`FOUND_ROWS()` is not used: oxmysql pools connections.
- Hits (and person-page vehicle rows) get `bolo = true` from `exports.fredpd_bolo:hasVisibleBolo(src, kind, id)`
  (memory only in fredpd_bolo; canView on the cached entry incl. the BOLO's unit and issuer, any shape but `none`),
  only while `GetResourceState('fredpd_bolo') == 'started'` (checked once per request, pcall per call, one
  warning). No `getBolosFor` per hit, so a search page costs no extra queries. Inactive / hidden → false.
- Never `players`/`charinfo` (asserted over every statement in the tests).
- Measured (tests, 200 persons, `Ber` → 56 hits): EXPLAIN `key = ft_name`, server time (ANALYZE) **0.29 ms**.
  **Short-term scan**: a query of short/stopword terms only (`Bo`, `Li`, `de`) scans `fredpd_persons` (REGEXP;
  200 rows: well under 1 ms; cost grows linearly with the table, i.e. every character ever created — roughly
  ~1 ms per few thousand rows on MariaDB 10.11). The card's `LIKE 'x%'` would not avoid it: `firstname` leads no
  index, so `lastname LIKE ? OR firstname LIKE ?` is a scan too, and adding a `LIKE` OR-branch in front of the
  REGEXP (review suggestion) cannot use `idx_name` either. Needs sign-off from the contract/db owner; the cheap
  fix if it ever matters is a `KEY idx_firstname (firstname)` (index_merge union) plus a LIKE-only mode for
  one-term short queries.

## Person / vehicle pages, home

- **Person**: `fredpd_persons` (gender 0 → `male`, 1 → `female`, else `unknown`; dates via `DATE_FORMAT`),
  vehicles (≤ 50, BOLO flag each), `bolos = exports.fredpd_bolo:getBolosFor(src, 'person', cid)` (array or
  `{ ok, data }` accepted; `[]` when stopped/failing), cases via `fredpd_case_subjects` (≤ 50, open first, then
  `updated_at` desc; role = stored subject role), records = `fredpd_records` rows (≤ 100, newest first, **`revoked`
  excluded**; a record tied to a case is listed only when that case's content is visible — `full`, or `masked` at
  level ≤ tier — so a kontaktnotis/hidden case reveals nothing through the record list), title = the row's snapshot `title_sv` (§C14: history stays stable), falling back to the catalogue
  title only when the snapshot is empty. A record's `caseNumber` is set only when that case is `full`/`masked` for
  the viewer (a kontaktnotis case never leaks its number). Subject cases and record cases go through **one**
  `canViewMany` call (fallback: `canView` per case, one warning).
- **CaseRef**: `full` all fields; `masked` title only when `level <= getTier(src)`; `notice` = `{ contact =
  { displayName, unit } }` from the owner's `fredpd_officers` row (unit falls back to the case unit), nothing else;
  `none` omitted.
- **address**: `exports.fredpd_core:getAdapter('housing').getAddresses(cid)` (adapters/README.md). Across resources
  the adapter's functions arrive as msgpack function references (tables with a `__call` metatable, citizenfx
  scheduler.lua `funcref_mt`), so the check is `C.callable` (function or callable table), not `type == 'function'`;
  the test mock returns such a table. Up to 3 labels
  joined with `; `, ≤ 200 chars; no adapter / empty / error → null (one warning on error). The shipped housing
  adapters are stubs (task 6.2), so this is null in practice today.
- **Vehicle**: row (refresh on miss), owner `{ citizenid, name }` (name falls back to the citizenid when the mirror
  has no person row), BOLOs, cases (`subject_type = 'vehicle'`, role reported as **`vehicle`**), checks = last 20
  `fredpd_plate_checks` rows newest first with `OfficerRef` from `fredpd_officers` (unknown officer → null);
  `hit` is true only when the row's `bolo_id` BOLO is visible to the viewer (one `canViewMany` over the hit BOLOs,
  VisRecord built like fredpd_bolo's; `notice` counts as visible, `none`/unknown bolo → plain check). If the
  table is missing (fredpd_bolo's `010` not applied) or the query fails: `[]` + one warning. A plate with no index
  row, BOLO, case or check → `not_found`; an unregistered plate with any of them gets a page without owner/model.
- **Audit** (§4.5): `search` once per search (`targetType` = detected type, `targetId` = normalized query cut to 64
  bytes at a character boundary, meta `{ query, type, page, total, hits = ids shown }`; a notice hit is logged as
  `'notice'`); `lookup.person` / `lookup.vehicle` once per opened page (`meta.source = 'summary'`, vehicle also
  `registered`, and `found`). A `not_found` lookup **is** audited (`found = false`) so probing for citizenids or
  plates leaves a trace; validation/unauthorized rejections and "my cases" are not audited.
- **Home**: `fredpd_cases` owned by the actor UNION cases assigning the actor, open first then `updated_at` desc,
  LIMIT then canView (a `none` case — impossible with the default rules for own cases — makes the list shorter).

## Framework bridge (§C17, docs/modules/bridge.md)

fredpd_records calls **no** framework, inventory, target, doorlock or banking resource: no `qbx_core`, `qb-core`/
`QBCore`, `ox_inventory`, `ox_target`, `ox_doorlock`, `Renewed-Banking`, no `Player.Functions` (checked by the
static test in `tests/lua/records_bridge_test.lua`). It is server-only, so only server bridge exports are used, all
through `server/common.lua` (`M.core` pcall, one warning per export when fredpd_core itself fails):

| helper | bridge export | used by |
|---|---|---|
| `C.onlineSrc(cid)` | `getPlayerByCitizenId(cid)` → src \| nil | applyCharges (jail target), issueFine, assignCase / decideReleaseRequest notifications |
| `C.player(src)` | `getPlayer(src)` → normalised player \| nil | issueFine (target still has that character) |
| `C.removeMoney(src, 'bank', n, reason)` | `removeMoney` → boolean | issueFine |
| `C.addMoney(src, 'bank', n, reason)` | `addMoney` → boolean (FredPD addition, bridge.md open question 1) | issueFine refund |

The actor's citizenid, duty, grants and tier come from fredpd_core as before (`getCitizenId`, `isOnDuty`,
`hasGrant`, `getTier`), which themselves read the bridge. Jail: `getAdapter('prison')` (xt-prison adapter on the qb
server). Behaviour is the same on qb-core and qbx_core except the documented billing change (no society credit) and
the frameworks' own minus rules. A stopped framework → the bridge answers nil/false with **one** warning (fredpd_core
log): fines answer `target_offline`, jail/notifications are skipped; never an error.

## Lua has no null

As in fredpd_dispatch: nil fields are **absent** on the wire; empty lists are `[]`. `contract.test.ts` restores
absent nullable keys before parsing and fails on unknown keys. Edge: a notice for a case with neither owner officer
row nor unit would be `contact = {}`, which msgpack/JSON send as `[]` (not a zod object). Cases get a unit when
created (Phase 5), so this should not occur; the NUI restore step should map `[]` → `{}` for object schemas.

## UNVERIFIED (needs FXServer)

1. `MySQL.*.await` inside these exports when called from fredpd_mdt's `lib.callback` handler (common pattern).
2. Calling the housing adapter's `getAddresses` through the table returned by `exports.fredpd_core:getAdapter`: the
   function reference is accepted (callable table, as scheduler.lua unpacks it) and called under pcall; the actual
   round trip into fredpd_core / the housing resource is only mocked here.
3. oxmysql returns `@@innodb_ft_min_token_size` as a number and `DATE_FORMAT` text as strings (the shim does).

## Integration requests

- **fredpd_mdt**: route `search`, `getPerson → getPersonSummary`, `getVehicle → getVehicleSummary`; `getHome` uses
  `getHomeCases(src, { limit = 10 })` and `countMyOpenCases(src)` for `counts.myOpenCases`.
- **fredpd_bolo**: `hasVisibleBolo(src, kind, id) -> boolean` for flags; `getBolosFor(src, kind, id)` returns
  `Bolo[]` (canView-filtered) for page lists. A batch variant would save up to 50 export calls per search page.
- **NUI**: restore absent nullable keys (see contract.test.ts `restoreNulls`) before strict parsing.
- **db owner**: sign-off on the short-term scan (see "Short-term scan"), or an `idx_firstname` key.

## Tests

- `lua5.4 tests/lua/run.lua records_` (per-run DB `fredpd_test_records_lua_<stack>_<token>`, token = `FREDPD_TEST_RUN_ID` or random, stale ones (>1 h) dropped at prepare, sessions at
  `+02:00`; creates `fredpd_plate_checks` with the §C12 columns when the 010 migration is not in the checkout).
  Golden files are rewritten only on change. Set `FREDPD_TEST_VERBOSE=1` to print the measured query time.
- `pnpm exec vitest run --project resources fredpd_records` (15 tests),
  `pnpm exec tsc -p "resources/[fredpd]/fredpd_records/test/tsconfig.json"`.

## Open questions

1. Phase 2 added no locale keys (codes only); Phase 5 adds `locales/pending/records-writes.json` (see below).
2. **Contract request** (contract owner): add `countMyOpenCases(src) -> { ok, data = integer }` to §C12 (exported
   here, used by fredpd_mdt/server/home.lua) and `exports.fredpd_bolo:hasVisibleBolo(src, kind, id) -> boolean`
   (used by `server/common.lua` `boloFlag`; §C12 still lists only checkPlate/checkPerson/getBolosFor). The bolo owner
   should also list `hasVisibleBolo` in docs/modules/bolo.md. fredpd_records owns neither file.
3. Should the person page also refresh a missing `fredpd_persons` row from `players` (like `refreshPlate`)? Today a
   character never mirrored (backfill not run) is `not_found`.

---

# Phase 5 writes

Tasks 5.1, 5.3 (server), 5.4 (catalogue read), 5.5 (server), 5.6 (server). Contract §C14 +
`packages/types/src/records.ts` `RECORDS_ACTIONS`; the fredpd_mdt dispatcher already routes every RECORDS_ACTIONS name
to the export of the same name (fredpd_mdt `server/dispatch.lua`).

## Files (Phase 5)

| File | Role |
|---|---|
| `server/cases.lua` | listCases, getCase, createCase, updateCase, assignCase, unassignCase, addCaseSubject, closeCase; CaseDetail shaping, timeline, pushes |
| `server/reports.lua` | getReport, createReport, saveReport, saveReportDraft, listReportTemplates |
| `server/charges.lua` | listCharges, applyCharges (+ prison adapter), issueFine (billing) |
| `server/poi.lua` | getPoi, updatePoi |
| `server/shares.lua` + `server/random.js` | createShare, revokeShare, viewShare; CSPRNG export `randomToken` |
| `server/releases.lua` | createReleaseRequest (+ lib.callback `fredpd:records:releaseRequest`), createReleaseRequestPortal, listReleaseRequests, decideReleaseRequest |
| `server/export.lua` | masked exports (release: public tier-0 viewer; shares: max_level) |
| `server/lookupflag.lua` | obehörig sökning, evaluated on each person lookup |
| `db/migrations/013_records.sql` | additive: `fredpd_cases.resolution`, `fredpd_shares.max_level`, `fredpd_release_requests.channel` |
| `db/seed/report_templates_sv.sql` | templates Anmälan, PM, Beslagsprotokoll, Förhör (ids 1-4, unit NULL) |
| `test/contract.test.ts`, `test/proposed.ts`, `test/random.test.ts` | zod check of the new golden files; proposed schemas; random.js |
| `tests/lua/records_{cases,reports,charges,access}_test.lua` | Lua tests (MariaDB) |
| `locales/pending/records-writes.json` | 13 new keys (audit action labels, POI warnings, the Ledning flag notification) |

## Common rules (every Phase 5 export)

`(src, input)` → `{ ok = true, data }` | `{ ok = false, error, reason? }` (reason `^[%a_]+$`, forwarded by the
dispatcher). Each export re-checks: src is a player id; the RECORDS_ACTIONS grant (`listCharges`, shares: any
`mdt_page` grant); **on duty** (`reason = 'off_duty'`); a loaded character (the actor citizenid comes from
`exports.fredpd_core:getCitizenId(src)`, never the input); input shapes re-validated (trimmed, lengths in code points,
integers, enums, no unknown `type`s). Errors: `validation`, `unauthorized`, `not_found`, `rate_limited`,
`unavailable` (Lua error / DB). Reads follow canView: `none` → `not_found` (never `unauthorized`), so existence
does not leak; a `notice` viewer that tries to write gets `unauthorized` (existence is already known to it).
Reasons used: `off_duty`, `level_above_tier`, `lowering_needs_admin`, `unit`, `case_closed`, `unknown_officer`,
`not_assigned`, `person`, `vehicle`, `template`, `notice`, `unknown_charge`, `not_ordningsbot`, `target_offline`,
`target_too_far`, `insufficient_funds`, `payment_failed`, `self`, `zero_fine`, `already_decided`, `no_target`,
`nothing_releasable`.

Roles on a case: **editor** = owner, lead assignee or `records.admin` (update, assign, unassign, close, and edit
of any report); **contributor** = editor or any assignee (add subjects). createReport needs canView `full` on an open
case (owner, assignees, the owning unit, records.admin). Report edit (save, draft, charges) = author, case editor;
case open; report level ≤ actor tier.

Level rules (cases, reports, POI): never above the actor's tier (`level_above_tier`); lowering needs `records.admin`
(`lowering_needs_admin`); closing keeps the level.

Every write is audited via `exports.fredpd_core:audit` with `meta.label` = a short safe label used as the timeline
`detail` (case number, report number, officer display name, subject label, formatted amount). Actions:
`case.create|update|assign|unassign|subject|close`, `report.create|save`, `charges.apply`, `fine.issue`,
`poi.create|update`, `share.create|revoke|view`, `release.create|decide`, `lookup.flag`. Not audited (§C7): drafts,
`fredpd_sequences`. Case writes push topic `case` `{ type = 'caseUpdated', caseId }` to the open tablets of the
owner/assignees only (filter function passed to `pushToOpenTablets`) and fire `TriggerEvent('fredpd:caseUpdated', id)`.

### Push topics

| topic | payload | recipients (filter) |
|---|---|---|
| `case` | `{ type = 'caseUpdated', caseId }` — nothing else | open tablets of the case owner/assignees (+ the new assignee) |
| `ledning` | `{ type = 'releaseRequest', id }` (release queue changed: created, decided) | open tablets holding `perm:records.admin` |
| `ledning` | `{ type = 'lookupFlag', officer, count }` (obehörig sökning flagged; `officer` = citizenid) | open tablets holding `perm:records.admin` |

Constants `C.TOPIC_CASE` / `C.TOPIC_LEDNING` (server/common.lua). `ledning` is not yet in `PUSH_TOPICS`
(packages/types/src/mdt.ts, fredpd_mdt `server/open.lua`): until integration request 9 lands, fredpd_mdt refuses it
(its throttled warning, 0 tablets reached) — the lookup flag still reaches Ledning as an ox_lib notification; the
release queue refreshes only when the page is reopened. Ids and counts only, never text.

## Cases

- **Numbering**: `seq` from `fredpd_sequences` (`seq_type 'case'`, Stockholm year via `formatId('{{yyyy}}')`)
  allocated by **fredpd_core's `db.nextSeq`** (`fredpd_core/server/db.lua`, loaded with ox_lib
  `require '@fredpd_core.server.db'`; nothing in it runs at load time; this resource has no copy of the SQL any more):
  `INSERT … VALUES (?, ?, LAST_INSERT_ID(1)) ON DUPLICATE KEY UPDATE value = LAST_INSERT_ID(value + 1)` (the
  insert id is the allocated value), then
  `formatId(caseNumber, { seq, date })`, then the insert. Deviation from §C14's "same transaction": oxmysql's
  `transaction.await` is a fixed batch and `startTransaction` is experimental (docs/deps-verification.md §10); the
  atomic counter can never hand out a value twice, a failed insert leaves a gap. A number that is already taken (a
  hand-made row) is skipped with a warning (≤ 3 attempts). Tests: 3 interleaved creates and 6 parallel clients × 8
  allocations (48 distinct values 1..48).
- **CaseDetail**: full / masked / notice per §C14. `masked` shows title/summary/subjects/timeline only when the case
  level ≤ tier. Report refs use the report's own canView (type `report`: report level, case status/unit/owner, case
  assignees + author): `none` → omitted, `notice` / masked above tier → `title` null. Evidence from
  `exports.fredpd_forensics:listCaseEvidence(src, { caseId })` (fallback `listEvidence`; pcall, `[]` when stopped);
  items without a tag are skipped. Timeline: `fredpd_audit` rows of the case, its reports and its evidence ids, newest
  first, max 100, without view rows (`lookup.*`, `search`, `share.view`, `report.read`); `detail` = `meta.label`
  (or `meta.tag`), dropped if it is not safe text. The audit insert is asynchronous in fredpd_core, so the detail
  returned right after a write may not yet contain that write's timeline entry.
- `updateCase` **summary semantics** (CaseUpdateInput `summary: string | null | undefined`): JSON `null` never
  reaches Lua as a value (NUI `json.decode` and export msgpack both drop the key), so "clear" is transported the way
  docs/modules/mdt.md (integration request 2) specifies: **`summary = ''`** (or only white space, trimmed) clears it
  (stored `NULL`, returned absent = zod `null`). Also accepted as clear, for callers that cannot send `''`: an
  explicit **`clearSummary = true`** (boolean; with a non-empty `summary` → `validation`) and a decoder null sentinel
  (`json.null`, when the runtime's json has one). Absent `summary` = no change. `closeCase` stores `resolution` (013),
  `closed_by`, `closed_at`. `assignCase` needs a `fredpd_officers` row; re-assigning changes the role; the assignee
  gets `case.assignedToYou` (ox_lib notify) when online. `addCaseSubject`: person in `fredpd_persons`, plate in
  `fredpd_vehicles_idx` (refreshPlate on a miss); re-adding updates the role.
- `listCases`: filter `mine` (owner/assignee), `unit` (case unit ∈ actor units), `open`, `closed`, `all`; `query`
  = case number or title (LIKE, wildcards escaped). At most 500 candidates are read (open first, newest first), then
  canView; only `full`/`masked` refs are listed and counted (kontaktnotiser belong on person/vehicle pages; counting
  them would reveal how many cases a unit has); a title match on a masked case whose title is hidden is dropped.
  Page size 50; `total` = visible candidates (≤ 500).

## Reports

- `n` = `MAX(n)+1` read before a batch `[SELECT id FROM fredpd_cases WHERE id = ? FOR UPDATE; INSERT … SELECT … FROM
  fredpd_cases WHERE id = ? AND status = 'open']`; a concurrent report with the same n fails the batch on
  `uq_case_n`/`uq_report_number` and is retried with a fresh n (≤ 5; tested with two interleaved creates → exactly
  one retry). A closed case inserts nothing → `case_closed`. `reportNumber = formatId(reportNumber, { case, n })`.
- Body: markdown-lite stored as given; CRLF → LF; control characters except LF/TAB removed; invalid UTF-8 refused;
  ≤ 100 000 code points. `saveReport` deletes the actor's draft for that report. Drafts: one per author and report
  (`uq_author_report`), not audited, `savedAt` read back from the DB (UTC). Draft of a *new* report (report_id NULL)
  is not offered: the NUI creates the report first.
- `getReport` for a `notice` viewer → `unauthorized`/`notice` (ReportDetail has no kontaktnotis shape).
- Templates: active, `unit IS NULL` or one of the actor's units, shared first; createReport with a template the actor
  may not use → `template`.

## Charges

- `listCharges`: active rows; `query` on code, title or law ref; `class` filter; ≤ 500, `category, code` order.
- `applyCharges`: report editable; person in `fredpd_persons`; every code active (`unknown_charge`); one batch:
  subject `INSERT IGNORE … 'suspect'` when not yet a subject (an existing role is kept) + one `fredpd_records` row per
  line (title/class/fine × quantity/jail × quantity snapshots, status `issued`, note). Returns the rows just inserted
  and their totals. **Jail**: when the lines carry prison time and the person is online within 5 m of the officer (in
  custody), `getAdapter('prison').jail(targetSrc, minutes, { { code, label } })`; the result goes into the audit meta
  `jailed`. The target's server id comes from the bridge `getPlayerByCitizenId`. With `prison = "xt-prison"` in
  config/integrations.json fredpd_core's xt-prison adapter confines the player (`SetJailTime` + xt-prison's enter
  callback; `true` = handed over); with `none` it logs and returns false (recorded, nobody jailed).
- `issueFine`: every line class `ordningsbot` (`not_ordningsbot`); target online (bridge `getPlayerByCitizenId`
  and `getPlayer` with the same citizenid), not the officer, same routing bucket and ≤ 5 m (server-side ped coords)
  → else `target_offline` / `target_too_far`; 1 fine per 2 s per officer. Money through the **fredpd_core bridge**
  (§C17): `removeMoney(target, 'bank', total, 'police-fine')` → false = `unavailable` when the bridge then no longer
  resolves the target (`getPlayer` nil: framework stopped / player dropped), else `insufficient_funds` (qb-core refuses below
  `Config.Money.MinusLimit` -5000; qbx_core lets bank go negative unless a `removeMoney` hook refuses). **No society
  credit**: Renewed-Banking (qbx-only) is no longer called, so the fine leaves the player and is credited nowhere on
  both stacks (integration request 10: a `billing` adapter). `payment_failed` is no longer produced. Rows are stored
  `paid` after the money moved; a failed insert refunds with `addMoney(target, 'bank', total, 'police-fine-refund')`
  and raises (`internal` to the caller; the log says whether the refund succeeded). The target gets `charge.ordningsbot.received` with the formatted amount. Optional `caseId`
  needs canView full on an open case; the audit then targets the case (timeline).

## POI

`getPoi(src, { citizenid })` → `{ citizenid, name, poi: PoiSheet | null }`; `updatePoi(src, { citizenid, summary?,
warnings?, level?, status?, photoUrl? })` → same. canView type `poi` (default rules: records.admin, owner, unit,
tier ≥ level → full, else kontaktnotis). Edit: full + (owner, member of the sheet's unit, records.admin); the first
update creates the sheet (owner = actor, unit = primary unit). Warnings: `armed`, `violent`, `flight_risk`, `gang`
(deduplicated, ≤ 8). `photoUrl` (≤ 255; `''` clears) is **restricted to fredpd_service's own uploads**: `POST
/upload` stores `<32 lower-case hex>.<png|jpg|webp>` (§C6), so the accepted forms are
`<service public URL>/upload/<file>` and the service-relative `/upload/<file>`. The public URL is the convar
`fredpd_service_public_url` (= the service's `PUBLIC_URL`), else `fredpd_service_url`; scheme and host compare
case-insensitively, the base path (e.g. `/FredPD`) and the file name exactly; anything else (another host, `/uploads/`, `..`, other extensions) → `validation`.
Shapes: `test/proposed.ts` `PoiViewSchema`.

## Share links

`createShare(src, { targetType: 'poi'|'case'|'report', targetId, expiresInHours: 1..168 })` → `{ id, token, path:
'/share/<token>', expiresAt, maxLevel }`. Needs canView `full` on the target. Token = 32 bytes from Node
`crypto.randomBytes` (this resource's JS export `randomToken`, base64url, 43 chars); if the export is missing the
call fails `unavailable` (never `math.random`). Only `sha256_hex(token)` is stored (`fredpd_core/shared/sha256.lua`);
the token is never logged or audited. `max_level` (013) = the creator's tier: a link never shows text above it, even
when the creator could read more through an assignment. `revokeShare(src, { id })`: creator or records.admin
(others get `not_found`). `viewShare(token)`: callable only from `fredpd_core` / this resource / the console
(`GetInvokingResource`); unknown, expired or revoked → `not_found`; each view increments `view_count`, sets
`last_viewed_at` and is audited `share.view`; content = `server/export.lua` at `max_level` (case: number, status,
title, summary, dates, reports ≤ max_level; report; POI: name, level, status, summary, warnings, photo) — never
officers, subjects, charges or evidence; `content` absent when the target is now above `max_level`.

## Release requests (Begär ut allmän handling)

- `createReleaseRequest(src, { description (3-2000), reference? (≤ 48) })`: any player with a character (the
  station target zone — a `FredBridge.target.addBoxZone` on the client — is an integration request; the lib.callback `fredpd:records:releaseRequest` calls the
  same function). 1 per 60 s per player. The reference is matched to a case/report number and stored; the requester
  learns nothing about it. `createReleaseRequestPortal({ discordId, name, description, reference? })`: only via the
  fredpd_core bridge (service). Both audit `release.create`, push `{ type = 'releaseRequest', id }` (topic `ledning`) to
  open tablets with records.admin.
- `listReleaseRequests(src, { status?, page })` and `decideReleaseRequest(src, { id, decision:
  'approved'|'partial'|'denied', note?, targetType?, targetId? })`: perm records.admin. A pending request only
  (`already_decided`, race-safe `WHERE status = 'pending'`). approved/partial need a target (`no_target`) and a
  non-empty export (`nothing_releasable`), stored as JSON in `released_body`.
- **Masking** (`server/export.lua`): canView (`shared/canview.lua` with the rules from `fredpd_visibility_rules`,
  reloaded on `fredpd:rulesChanged`) for a public viewer (no character, tier 0, no units, no grants). Default rules:
  a closed level-0 case → masked (releasable), an open case or a level ≥ 1 case → kontaktnotis (withheld). Content:
  case number, status, level-0 title/summary, dates and the title/body of level-0 reports the public viewer may see.
  No officers, subjects, charges, evidence, intel or resolution ("source fields"). Nothing above level 0 is ever read
  into the export, so no Begränsad/Hemlig text can be released (test `access 04`, golden `release.decided`).
- Shapes: `test/proposed.ts` `ReleaseRequestSchema`, `ReleasedContentSchema`.

## Obehörig sökning

On every `getPersonSummary` (after its `lookup.person` audit, also for `not_found`): count = distinct persons the
officer looked up within `unauthorizedLookupWindowMinutes` (integrations.json, default 60) that are not a subject of
a case the officer owns or is assigned to, plus the current person when unlinked. Distinct persons, not rows, because
the audit insert of the current lookup is asynchronous. At `unauthorizedLookupThreshold` (default 3) → audit
`lookup.flag` (target `officer`, meta `{ count, windowMinutes, threshold, persons ≤ 20 }`), push `{ type = 'lookupFlag',
officer, count }` (topic `ledning`) to open tablets with records.admin, and `audit.flag.unauthorizedSearchNotify` to
on-duty records.admin players. One flag per officer per window (in memory; no timers). Two indexed queries per
lookup (`fredpd_audit (actor_citizenid, created_at)`, `fredpd_case_subjects idx_subject`). Alerts are not linked to
persons in the schema, so "koppling till larm" is not counted.

## Person page: intel notices

`getPersonSummary` merges `exports.fredpd_intel:getPersonNotices(src, citizenid)` (pcall, only while fredpd_intel is
started; plain array or `{ ok, data }` accepted; only `{ displayName, unit }` strings taken) into `cases[]` as notice
CaseRefs, deduplicated by contact and re-sorted with the case notices (`caserefs.order`), so an intel notice cannot
be told apart from a case notice.

## Tests (Phase 5)

- Each run uses its own database `fredpd_test_records_lua_<stack>_<token>` (`FREDPD_TEST_RUN_ID` or random), so
  qb/qbx or parallel runs never reset each other's tables; databases of runs older than 1 h are dropped at prepare.
- `lua5.4 tests/lua/run.lua records_` → **60 tests** (24 Phase 2 + cases 10, reports 7, charges 5, access 7, bridge
  7). The framework is reached through the **real fredpd_core bridge** (`server/bridge.lua`, loaded per test by
  `H.loadBridge`) over the bridge harness's upstream mocks (`bridge_harness_test.lua` `qbCore` / `qbxCore`); the
  stack is `FREDPD_RECORDS_STACK=qb` (default: qb-core + qb-inventory/qb-target/qb-doorlock) or `qbx` (qbx_core +
  ox_*). Run the suites once per stack. `records_bridge_test.lua` always runs a smoke matrix on both stacks (fine +
  refund, jail target, assign notification, framework stopped → one warning) and the static no-direct-calls check.
  The harness also mocks fredpd_mdt pushes, fredpd_forensics, fredpd_intel, the prison adapter, ped coords/buckets,
  `GetInvokingResource`, `GetConvar`, and can write audit rows to `fredpd_audit` (`env.auditDb`). `H.interleave` runs functions as coroutines that yield before every SQL statement
  (each shim statement is its own client session = a pool connection).
- `pnpm exec vitest run --project resources fredpd_records` → **33 tests** (contract 31 incl. 12 new golden files,
  random.js 2); `pnpm exec tsc -p "resources/[fredpd]/fredpd_records/test/tsconfig.json"`.

## UNVERIFIED (Phase 5, needs FXServer)

1. `exports.fredpd_records:randomToken(32)` from this resource's Lua into its own JS runtime (same-resource export
   across runtimes) and Node's `base64url` encoding in FXServer's Node 22.
2. oxmysql `MySQL.insert.await` returning the `LAST_INSERT_ID(expr)` value for `INSERT … ON DUPLICATE KEY UPDATE`
   (MySQL protocol: the OK packet carries it; tested with the mariadb client here). A duplicate-key error from
   `MySQL.insert.await` is caught either way (raise or nil + read-back).
3. The bridge exports from this resource (`exports.fredpd_core:getPlayerByCitizenId/getPlayer/removeMoney/addMoney`)
   on a live qb-core server (the bridge's own UNVERIFIED 1: qb Player.Functions closures across its export).
7. ox_lib `require '@fredpd_core.server.db'` from this resource: db.lua's inner `pcall(require, 'shared.sha256')`
   fails here and falls back to `@fredpd_core.shared.sha256` (the file is written for that); only mocked in tests.
8. xt-prison through `getAdapter('prison')` confining a player jailed from the tablet (adapter is fredpd_core's).
4. `GetEntityCoords(GetPlayerPed(src))` on the server under OneSync for the 5 m checks.
5. The filter function passed to `exports.fredpd_mdt:pushToOpenTablets` arrives as a callable function reference.
6. `GetInvokingResource()` in `viewShare`/`createReleaseRequestPortal` when called through the fredpd_core JS bridge
   (expected `'fredpd_core'`).

## Integration requests (Phase 5)

1. **packages/types / contract owner**: add POI, share and release-request shapes and actions (proposed in
   `test/proposed.ts`: `PoiViewSchema`, `PoiUpdateInputSchema`, `ShareCreateInputSchema`, `ShareCreatedSchema`,
   `ReleaseRequestSchema`, `ReleasedContentSchema`, `ReleaseDecideInputSchema`) — suggested actions and grants:
   `getPoi`/`updatePoi`/`createShare`/`revokeShare` (`mdt_page:search`), `listReleaseRequests`/
   `decideReleaseRequest` (`perm:records.admin`). Record in §C14: the case-number deviation (atomic counter before the
   insert, gaps allowed), `summary: ''` clears, the reasons list above, `listCases` omits notices, the new perm-free
   exports `viewShare`/`createReleaseRequestPortal` (bridge only), 013 columns.
2. **fredpd_mdt** (dispatcher): once 1 lands, route the POI/share/release actions to the same-named exports (write
   limit for updatePoi/createShare/revokeShare/decideReleaseRequest). Topic `case` carries only `caseUpdated`; the
   release queue and lookup flag moved to topic `ledning` (request 9).
3. **fredpd_core (HTTP bridge owner)**: add signed routes for the service: `GET /share/:token` →
   `exports.fredpd_records:viewShare(token)` and `POST /release` → `createReleaseRequestPortal(body)`. Optionally
   export a `randomBytes`/`randomToken` from `http.js` (then fredpd_records can drop `random.js`).
4. **apps/service**: `/share/:token` page (portal renders `ReleasedContent`-like content with `t()` labels; show
   "innehållet är inte längre tillgängligt" when `content` is absent; 404 for `not_found`); release form →
   bridge; Ledning release queue uses the records.admin actions.
5. **Station target client** (`FredBridge.target.addBoxZone`, "Begär ut allmän handling", `release.target` key exists): an `lib.inputDialog` with
   `release.field.description` / `release.field.reference` → `lib.callback.await('fredpd:records:releaseRequest', false,
   { description, reference })`. Owner: whoever owns station zones (fredpd_police/mdt client); needs station
   coordinates in config.
6. **Locale owner**: merge `locales/pending/records-writes.json` (13 keys).
7. **NUI**: CaseDetail `notice` shows only the contact; `reports[].title` may be null; ReportDetail errors with reason
   `notice`; restore absent nullable keys as for Phase 2.
8. **Prison**: done — the xt-prison adapter exists; set `"prison": "xt-prison"` in config/integrations.json on the qb
   server (else `none`: time recorded, nobody jailed, audit `jailed = false`).
9. **packages/types (`PUSH_TOPICS`, mdt.ts:274) + fredpd_mdt (`server/open.lua` `M.PUSH_TOPICS`)**: add topic
   `'ledning'` (payloads in "Push topics"; recipients are filtered by this resource to `perm:records.admin`; a
   `TOPIC_GRANTS.ledning = { 'perm', 'records.admin' }` in fredpd_mdt would enforce it twice). The NUI release queue
   refreshes on `releaseRequest`; `lookupFlag` may show a toast. Until then the pushes are refused (one throttled
   fredpd_mdt warning).
10. **fredpd_core (adapters owner)**: a `billing` adapter kind (`deposit(account, amount) -> boolean`; qb-banking /
    qb-management / Renewed-Banking implementations) so fines are credited to the police society account again;
    issueFine would call it after `removeMoney` and refund on a false. Until then fines are credited nowhere.
11. **server.cfg.example / apps/service**: add `set fredpd_service_public_url "https://…"` (= the service's
    `PUBLIC_URL`) so POI photo URLs can use the public host (without it only `fredpd_service_url` or `/upload/<file>`
    is accepted), and a `GET /upload/:file` route serving the stored uploads (none exists yet, so photos are stored
    but not viewable).
12. **fredpd_mdt / NUI** (mdt.md request 2): send `summary: ''` (or `clearSummary: true`, which needs a
    `CaseUpdateInputSchema` field first — else fredpd_mdt's validator drops it) when the officer empties the summary.
13. **Locale owner**: `locales/pending/records-bridge.json` holds only a `$comment`: the bridge move added no strings.
