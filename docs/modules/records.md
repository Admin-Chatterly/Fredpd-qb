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

- `lua5.4 tests/lua/run.lua records_` (24 tests; DB `fredpd_test_records_lua`, reset once per run, sessions at
  `+02:00`; creates `fredpd_plate_checks` with the §C12 columns when the 010 migration is not in the checkout).
  Golden files are rewritten only on change. Set `FREDPD_TEST_VERBOSE=1` to print the measured query time.
- `pnpm exec vitest run --project resources fredpd_records` (15 tests),
  `pnpm exec tsc -p "resources/[fredpd]/fredpd_records/test/tsconfig.json"`.

## Open questions

1. No new locale keys: nothing here is player-facing (codes only), so no `locales/pending/records.json`.
2. **Contract request** (contract owner): add `countMyOpenCases(src) -> { ok, data = integer }` to §C12 (exported
   here, used by fredpd_mdt/server/home.lua) and `exports.fredpd_bolo:hasVisibleBolo(src, kind, id) -> boolean`
   (used by `server/common.lua` `boloFlag`; §C12 still lists only checkPlate/checkPerson/getBolosFor). The bolo owner
   should also list `hasVisibleBolo` in docs/modules/bolo.md. fredpd_records owns neither file.
3. Should the person page also refresh a missing `fredpd_persons` row from `players` (like `refreshPlate`)? Today a
   character never mirrored (backfill not run) is `not_found`.
