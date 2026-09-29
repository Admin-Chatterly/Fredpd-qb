<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Module: fredpd_records (Phase 2 read paths)

Tasks 2.3/2.4/2.5 server side and the "my cases" part of 2.7 (IMPLEMENTATION.md §5.3, §4.2, §4.5–§4.7, §8.6;
docs/contracts.md §C3, §C7, §C12; shapes in `packages/types/src/mdt.ts`). Read only: no case writes until Phase 5.

## Files

| File | Role |
|---|---|
| `fredpd_records/fxmanifest.lua` | server only; deps `ox_lib`, `oxmysql`, `fredpd_core` (fredpd_bolo optional) |
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
`exports.fredpd_core:hasGrant` (cheap, in memory). Duty and rate limits are left to the dispatcher. The actor for
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
  cannot hold use `(p.lastname LIKE 'term%' OR p.firstname LIKE 'term%')` instead: shorter than
  `@@innodb_ft_min_token_size` (read once, default 3) or, with `innodb_ft_enable_stopword` on, a stopword **or a
  prefix of one** (InnoDB does not index `will`, `de`, `la` …, so `Wil` would miss "Will"). No term left (e.g.
  `%_%`, `'--`) → no hits (never "everything"). Boolean operators can never reach MATCH (asserted on every sent
  statement in the tests); all user text is a bound parameter. Order `lastname, firstname, citizenid`.
- **personId**: `personnummer IN (…)`: `YYMMDD-XXXX` also matches `19`/`20` + it, `YYYYMMDD-XXXX` also matches the
  10-digit form (index-friendly instead of core.md's `RIGHT(personnummer, 11)`; EXPLAIN `idx_personnummer`).
- **plate**: PK lookup on `fredpd_vehicles_idx` (+ owner name from `fredpd_persons`); on a miss one
  `exports.fredpd_core:refreshPlate(plate)` and a re-read. **caseNumber**: exact `case_number`, shaped by canView;
  `none` is omitted **and not counted** (existence does not leak).
- Pagination 50; total by `COUNT(*) OVER ()` in the same statement (MariaDB ≥ 10.2); a page past the end runs one
  `COUNT(*)`. `SQL_CALC_FOUND_ROWS`/`FOUND_ROWS()` is not used: oxmysql pools connections.
- Hits get `bolo = true` from `exports.fredpd_bolo:checkPerson(cid)` / `checkPlate(plate)`, only while
  `GetResourceState('fredpd_bolo') == 'started'` (checked once per request, pcall per call, one warning). A BOLO
  with level > 0 flags only when `canView(src, { type = 'bolo', … })` is not `none` (so a boolean cannot leak a
  Hemlig BOLO); inactive → false.
- Never `players`/`charinfo` (asserted over every statement in the tests).
- Measured (tests, 200 persons, `Ber` → 56 hits): EXPLAIN `key = ft_name`, server time (ANALYZE) **0.29 ms**.
  A LIKE-only query (`Bo`) scans `fredpd_persons` because `firstname` has no B-tree index (see open questions).

## Person / vehicle pages, home

- **Person**: `fredpd_persons` (gender 0 → `male`, 1 → `female`, else `unknown`; dates via `DATE_FORMAT`),
  vehicles (≤ 50, BOLO flag each), `bolos = exports.fredpd_bolo:getBolosFor(src, 'person', cid)` (array or
  `{ ok, data }` accepted; `[]` when stopped/failing), cases via `fredpd_case_subjects` (≤ 50, open first, then
  `updated_at` desc; role = stored subject role), records = `fredpd_records` rows (≤ 100, newest first, **`revoked`
  excluded**), title = the row's snapshot `title_sv` (§C14: history stays stable), falling back to the catalogue
  title only when the snapshot is empty. A record's `caseNumber` is set only when that case is `full`/`masked` for
  the viewer (a kontaktnotis case never leaks its number). Subject cases and record cases go through **one**
  `canViewMany` call (fallback: `canView` per case, one warning).
- **CaseRef**: `full` all fields; `masked` title only when `level <= getTier(src)`; `notice` = `{ contact =
  { displayName, unit } }` from the owner's `fredpd_officers` row (unit falls back to the case unit), nothing else;
  `none` omitted.
- **address**: `exports.fredpd_core:getAdapter('housing').getAddresses(cid)` (adapters/README.md); up to 3 labels
  joined with `; `, ≤ 200 chars; no adapter / empty / error → null (one warning on error). The shipped housing
  adapters are stubs (task 6.2), so this is null in practice today.
- **Vehicle**: row (refresh on miss), owner `{ citizenid, name }` (name falls back to the citizenid when the mirror
  has no person row), BOLOs, cases (`subject_type = 'vehicle'`, role reported as **`vehicle`**), checks = last 20
  `fredpd_plate_checks` rows newest first with `OfficerRef` from `fredpd_officers` (unknown officer → null). If the
  table is missing (fredpd_bolo's `010` not applied) or the query fails: `[]` + one warning. A plate with no index
  row, BOLO, case or check → `not_found`; an unregistered plate with any of them gets a page without owner/model.
- **Audit** (§4.5): `search` once per search (`targetType` = detected type, `targetId` = normalized query cut to 64
  bytes at a character boundary, meta `{ query, type, page, total, hits = ids shown }`; a notice hit is logged as
  `'notice'`); `lookup.person` / `lookup.vehicle` once per opened page (`meta.source = 'summary'`, vehicle also
  `registered`). Rejected/not_found calls and "my cases" are not audited.
- **Home**: `fredpd_cases` owned by the actor UNION cases assigning the actor, open first then `updated_at` desc,
  LIMIT then canView (a `none` case — impossible with the default rules for own cases — makes the list shorter).

## Lua has no null

As in fredpd_dispatch: nil fields are **absent** on the wire; empty lists are `[]`. `contract.test.ts` restores
absent nullable keys before parsing and fails on unknown keys. Edge: a notice for a case with neither owner officer
row nor unit would be `contact = {}`, which msgpack/JSON send as `[]` (not a zod object). Cases get a unit when
created (Phase 5), so this should not occur; the NUI restore step should map `[]` → `{}` for object schemas.

## UNVERIFIED (needs FXServer)

1. `MySQL.*.await` inside these exports when called from fredpd_mdt's `lib.callback` handler (common pattern).
2. Calling the housing adapter's `getAddresses` through the table returned by `exports.fredpd_core:getAdapter` (the
   functions arrive as cross-resource function references).
3. oxmysql returns `@@innodb_ft_min_token_size` as a number and `DATE_FORMAT` text as strings (the shim does).

## Integration requests

- **fredpd_mdt**: route `search`, `getPerson → getPersonSummary`, `getVehicle → getVehicleSummary`; `getHome` uses
  `getHomeCases(src, { limit = 10 })` and `countMyOpenCases(src)` for `counts.myOpenCases`.
- **fredpd_bolo**: `checkPlate(plate)` / `checkPerson(cid)` return the bolo table (fields `id`, `level`, `active`,
  `unit`, issuer as `issuedBy` OfficerRef or citizenid) or nil; `getBolosFor(src, kind, id)` returns `Bolo[]`
  (canView-filtered). A batch `checkPersons(cids)` would save 50 export calls per search page.
- **NUI**: restore absent nullable keys (see contract.test.ts `restoreNulls`) before strict parsing.
- **db owner**: consider `KEY idx_firstname (firstname)` so short first-name searches avoid a table scan.

## Tests

- `lua5.4 tests/lua/run.lua records_` (23 tests; DB `fredpd_test_records_lua`, reset once per run, sessions at
  `+02:00`; creates `fredpd_plate_checks` with the §C12 columns when the 010 migration is not in the checkout).
  Golden files are rewritten only on change. Set `FREDPD_TEST_VERBOSE=1` to print the measured query time.
- `pnpm exec vitest run --project resources fredpd_records` (15 tests),
  `pnpm exec tsc -p "resources/[fredpd]/fredpd_records/test/tsconfig.json"`.

## Open questions

1. No new locale keys: nothing here is player-facing (codes only), so no `locales/pending/records.json`.
2. `countMyOpenCases` is additive to §C12 (contract owner may record it).
3. Should the person page also refresh a missing `fredpd_persons` row from `players` (like `refreshPlate`)? Today a
   character never mirrored (backfill not run) is `not_found`.
