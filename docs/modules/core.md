<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Module: fredpd_core runtime + fredpd_devtools

Tasks 0.6 (adapters), 1.2 (HTTP bridge), 1.3 runtime (grant cache), 1.4 (search mirrors), 1.5 server wrapper
(canView), 1.7b FXServer side (officer identity, callsigns), plus the fredpd_devtools skeleton. Implements
docs/contracts.md §C1–§C9 on the FXServer. The pure shared modules (`shared/grants|canview|format|regex|sha256.lua`)
and the migration runner (`server/db.lua`) belong to other modules; this one calls them.

## Files

| File | Role |
|---|---|
| `fredpd_core/fxmanifest.lua` | cerulean, lua54, `node_version '22'`, `ox_lib 'locale'`; server: MySQL.lua, `server/http.js`, `server/main.lua` |
| `server/main.lua` | entry: config → exports/events (perms, canview, audit, mirror, officers, adapters) → `MySQL.ready`: `db.migrate()`, rules, officers, units, online players |
| `server/http.js` | HMAC bridge: `SetHttpHandler` routes (§C6) and the `signedFetch` export |
| `server/core.lua` | `Core.fetch`, `Core.rateLimit`, `Core.async`, SQL binding helpers, config, qbx player access, logging |
| `server/perms.lua` | grant cache `Cache[src]`, fallback to `fredpd_grant_cache`, `applyGrants` push, `fredpd_identities` |
| `server/canview.lua` | rules from `fredpd_visibility_rules`, `canView` / `canViewMany` |
| `server/audit.lua` | `audit` export, `Audit.write`, `archiveOlderThan` + command `fredpd_audit_archive` |
| `server/mirror.lua` | `fredpd_persons` / `fredpd_vehicles_idx`: qbx events, backfill, plate refresh, dev seeding |
| `server/officers.lua` | officer names from Discord, `fredpd_officers` rows, callsign on first duty, `fredpd_units` sync |
| `shared/locale.lua` | `L(key, vars)` over ox_lib `locale()`; pure `substitute` |
| `adapters/` | housing/garage/prison interfaces, `none` + stubs, loader (see `adapters/README.md`) |
| `fredpd_devtools/` | `/fredpd_selftest`, `/fredpd_backfill`, `/fredpd_seed`, `/fredpd_fakeunits` (dev only) |
| `server.cfg.example` | convars, ACE lines, ensure order |

Build: `scripts/build.mjs` (not owned here) already copies `config/*.json` → `fredpd_core/config/`,
`db/migrations` + `db/seed` → `fredpd_core/migrations/` (+ `index.json`), `locales/*.json` → every resource, and
**`packages/types/test/fixtures/*.fixtures.json` → `fredpd_devtools/fixtures/`**, which `/fredpd_selftest` reads.
Run it before starting the server.

## Exports and events (§C9 plus additions)

Contract exports: `hasGrant(src, type, key)`, `getGrants(src)` (copy), `getTier(src)`, `getUnits(src)` (copy),
`canView(src, record)`, `audit(src, action, targetType, targetId, meta)`, `applyGrants(discordId, grants)`,
`signedFetch(method, path, body, cb)` (JS), `getOfficer(src)`, `isOnDuty(src)`, `getCitizenId(src)`, `L(key, vars)`.

Additions (additive, no contract change needed):

| Export | Why |
|---|---|
| `canViewMany(src, records)` → results[] | a list page evaluates 50 records with one viewer lookup |
| `recomputeGrants(discordIds\|nil)` → n | called by http.js for `POST /recompute` |
| `setOfficerIdentity(discordId, displayName, avatarUrl)` → n | called by http.js for `POST /officer` |
| `ensureCallsign(src)` | lets a duty script trigger callsign allocation (async, returns nothing) |
| `refreshPlate(plate)` → row\|nil | vehicle search calls it on a `fredpd_vehicles_idx` miss |
| `backfillMirror(src)` → `{ persons, vehicles }` | `/fredpd_backfill`; audited |
| `seedDevRows(src, persons, vehicles)` → counts | `/fredpd_seed`; only `DEV…` citizenids, `INSERT IGNORE`, audited |
| `getAdapter(kind)` | task 0.6 |

Events: client `fredpd:client:grantsChanged(set)` (contract). New server-local events other modules may listen to:
`fredpd:grantsChanged(src)` after every cache change, `fredpd:officerChanged(citizenid)` after a name push or a new
callsign, `fredpd:devtools:fakeUnits(units|nil)` per fake-unit tick. `fredpd:rulesChanged` is consumed (server-only:
`AddEventHandler`, and a player source is ignored with a warning).

## HTTP bridge (`server/http.js`)

- Check order: route → 404, method → 405 (`Allow` header), bridge disabled → 503 `bridge_disabled`, `Content-Length`
  or body > 64 KB → 413, HMAC (§C5, copied from `hmac.ts`) → 401 `{ "error": "unauthorized" }`, duplicate of a
  memo route → cached answer, JSON → 400 `bad_json` (also for non-object JSON and for an **empty POST body**), body
  shape → 400 `invalid_body`, Lua error → 500 `internal`.
- **Duplicate suppression, `/grants` and `/officer` only (beyond §C5, no contract change):** §C5 signs only
  `ts + "." + body` with 1 s resolution, so an identical request in the same second (a retried POST that reuses its
  headers) carries the same signature. It is **not** answered 401 (401 means skew or bad signature only). For these
  two state-carrying routes the first answer is remembered for 120 s per `method + path + signature`, and a repeat
  gets that answer again with header `X-FredPD-Duplicate: 1` without calling Lua, so a captured `/grants` push
  cannot be re-applied to roll back a newer one (an identical body is an identical state, so nothing is lost). 5xx
  answers are not remembered (a retry runs again). The memo only holds verified requests and is pruned on insert (no
  timer). **`/ping` and `/recompute` are never memoised:** two permission saves in one second send identical
  recomputes, and the second must run because the first may have read the service before the second change was
  committed; a replayed recompute only forces an extra reload.
- **`/recompute` body:** a JSON object with no key but `discordIds` (§C6); `{}` means everyone. An empty body is
  400 `bad_json` and any other key is 400 `invalid_body` (`unknown key …`). This keeps a captured `GET /ping`
  signature (empty body) or a `/grants` / `/officer` body from being reused as "recompute everyone" (§C5 does not
  sign the path). **The service must send `{}`, not an empty body, to recompute everyone.**
- Rejected requests (401) are logged at most once per 10 s with a count of the suppressed ones: the routes are on the
  public game port, so an unauthenticated client must not be able to flood the console.
- GET is answered without waiting for a body (signed with the empty string, §C5).
- Responses: `/ping` `{ ok, players }`, `/grants` `{ ok, applied }`, `/recompute` `{ ok, scheduled }`, `/officer`
  `{ ok, updated }`. The Lua exports it calls never yield; DB/network work runs in its own Lua thread.
- Secret: convar `fredpd_hmac_secret`, ≥ 32 chars and not a known placeholder (`change_me`/`changeme`,
  `placeholder`, `your_secret`, one repeated character), else an error is logged, every route answers 503 and
  `signedFetch` calls back `(0, '{"error":"bridge_disabled"}')`. `server.cfg.example` ships `"CHANGE_ME"`, which is
  refused on both counts, so copying the example as it is leaves the bridge off instead of on with a public secret.
- `/officer`: `displayName` is trimmed and limited to 100 **characters** (code points, like `utf8.len` in Lua and
  the `VARCHAR(100)` utf8mb4 column); a `false` from `setOfficerIdentity` is a 400 `invalid_body`, like `/grants`.
- `signedFetch(method, path, body, cb)`: `cb(status, bodyString)` exactly once; status 0 = no HTTP response, body
  `{"error":"timeout"|"network"|"invalid_request"|"invalid_body"|"bridge_disabled"}`. One overall 3 s deadline
  (timer + AbortController) for both transports: global `fetch` (hence `node_version '22'`) and the `node:http(s)`
  fallback, which is aborted by the same signal (not a socket idle timeout, so a trickling peer cannot hold it).
- The file is structured as pure factories (`createHandler`, `createSignedFetch`, `createBridge`) plus a few lines
  that wire the FiveM globals, so the test evaluates it in a `vm` context with mocked globals.

## Grants runtime (`server/perms.lua`)

- `playerJoining` → Discord id from `GetPlayerIdentifierByType(src, 'discord')` → `GET /internal/grants/:id` →
  validate → `Cache[src]` + `fredpd_grant_cache` upsert. Failure (status ≠ 200 or invalid set) → cached row + warning;
  no row → empty set. No Discord identifier → empty set + warning. Until loaded every check fails closed.
- A push (`applyGrants`) that arrives while a fetch is in flight wins: the older fetch result is discarded.
- `fredpd_grant_cache.grants` is written with a hand-built encoder so empty lists are `[]` (FiveM's json may encode
  `{}`); `computed_at` = the set's `computedAt` as UTC DATETIME (or `NOW()` when it is not a `…Z` ISO string).
- `lib.callback 'fredpd:getMyGrants'` returns the player's own copy; never nil. Rate limit 250 ms per player: a
  limited call gets the copy built last time (memoised per player, dropped on every grant change), so a spamming
  client never makes the server copy anything and the NUI never sees nil as "no grants". No grant check: it only
  exposes the caller's own grants.
- `fredpd_identities`: `last_seen` on join; `license` + `last_citizenid` when a character loads (a NULL license
  never erases a known one).
- Nothing about grants is ever put in a statebag.

## Core helpers (`server/core.lua`)

- `Core.fetch(method, path, body)` → `status, decoded` (promise + `Citizen.Await`; must run in a thread).
- `Core.rateLimit(src, action, ms[, now])` → true when allowed. **Deviation:** uses `GetGameTimer()` rather than
  `os.clock()`: on Linux `os.clock` is CPU time, not wall time. `os.clock` stays as the non-FiveM fallback.
  State is cleared on `playerDropped`.
- `Core.bindRow` / `Core.buildInsert`: nil values become a literal `NULL` in the SQL instead of holes in the
  parameter array (a Lua array with nil holes does not reach oxmysql as an array).
- `Core.getPlayerData(src)` always asks `exports.qbx_core:GetPlayer(src)`, so the actor is never taken from the
  client or a stale cache (§4.6).

## Search mirrors (`server/mirror.lua`, task 1.4)

- Handlers (all `AddEventHandler`, idempotent): **VERIFY** the qbx_core names —
  `QBCore:Server:PlayerLoaded` (arg: Player), `QBCore:Player:SetPlayerData` (arg: PlayerData, fires on every data
  change), `QBCore:Server:OnPlayerUnload` (src). `docs/deps-verification.md` did not exist when this was written;
  task 0.3 should confirm or correct these three names.
- `QBCore:Server:OnPlayerLoaded` is deliberately **not** handled: in the QB ecosystem the client fires it with
  `TriggerServerEvent`, so a local `AddEventHandler` would never run and FXServer would print "not safe for net" on
  every character load. `QBCore:Server:PlayerLoaded` (server-side, from qbx_core's login) covers the load. **VERIFY**
  in task 0.3 that qbx_core does not fire `OnPlayerLoaded` server-side.
  A fingerprint of the mirrored fields skips the frequent SetPlayerData calls (money, metadata) without a DB write.
  The fingerprint is checked synchronously in the handler (`claimRow`); a thread (`Core.async` → `writeClaimed`) is
  only started when a mirrored field changed, so a money tick costs no thread.
- `backfill()`: keyset pages of 500 over `players` (the only bulk read of `charinfo`) and `player_vehicles` (skipped
  when that table does not exist), multi-row upserts, one audit row `mirror.backfill`.
- `refreshPlate(plate)`: looks up `player_vehicles.plate IN ('ABC12D', 'ABC 12D')` (index-friendly) and upserts.
- Plates are stored normalised (upper case, no whitespace), like `detectSearchType`.
- **personnummer**: qbx characters have none. `charinfo.personnummer` is used when it holds 10 or 12 digits;
  otherwise it is derived as `YYYYMMDD-NNNC` from the birthdate and an FNV-1a hash of the citizenid (third digit odd
  for men, even for women, valid control digit). Stable per character; two characters born the same day collide
  with probability ~1/1000. The value equals `detectSearchType('YYYYMMDDNNNC').normalized`; a 10-digit query
  (`YYMMDD-NNNC`) must be matched by the search module with `RIGHT(personnummer, 11) = ?`.
- Mirror rows are caches of qbx data and are not audited per row; backfill and seeding write one audit row each.

## Officers and callsigns (`server/officers.lua`, task 1.7b)

- `POST /officer` updates an in-memory name map (the bot writes `fredpd_officers` itself) and fires
  `fredpd:officerChanged`; `getOfficer` prefers the pushed name over the stored `display_name`. The row is reloaded
  whenever the character loads. `setIdentity` limits the name to 100 characters (`utf8.len`; invalid UTF-8 is
  refused) and the `GetPlayerName` placeholder is cut at a character boundary.
- `getOfficer(src).rankRoleId` / `.rankKey` come from the player's **live** grant set (`GrantSet.rank`, refreshed by
  every `/grants` push); the stored `rank_role_id` is only used until the grants have loaded.
- When a `job.type == 'leo'` character loads, FXServer creates its `fredpd_officers` row (the bot cannot know the
  citizenid) without touching the Discord-owned columns of an existing row. `display_name` is NOT NULL: until the
  bot fills it, the FiveM account name (`GetPlayerName`) is used, never the character name (§4.9).
- Callsign on first duty: `formats.json callsign` with `{{unit}}` = the `units.json` callsign prefix of the primary
  unit (the held unit first in `units.json` order) and `{{n}}` = lowest free number in that unit (gaps are reused).
  `uq_unit_callsign` turns a concurrent allocation into an error that is retried (5 attempts). An existing callsign
  is never overwritten. Audited as `officer.callsign` with `meta.auto = true`; the player gets
  `officer.callsignAssigned`. **VERIFY** triggers: `QBCore:Server:SetDuty(src, onDuty)`,
  `QBCore:Server:OnJobUpdate(src, job)`, plus `QBCore:Server:PlayerLoaded` when already on duty.
- A new `fredpd_officers` row (character load or first-duty allocation) writes one `officer.create` audit row
  (system actor, `meta = { discordId, auto, via = 'load'|'duty' }`). Creation is detected with
  `INSERT IGNORE` (affectedRows 1 = inserted, 0 = existed), **never** from `INSERT … ON DUPLICATE KEY UPDATE`:
  oxmysql runs mysql2 with `CLIENT_FOUND_ROWS`, so an upsert that matches an unchanged row also reports 1. The
  callsign is then set with `UPDATE … SET unit, callsign WHERE citizenid = ? AND callsign IS NULL` (a taken
  candidate fails on `uq_unit_callsign` and is retried) and read back, so no affectedRows is interpreted there.
- When a character's row exists but the player now uses another Discord account, `discord_id` is updated
  (`WHERE discord_id <> ?`, so affectedRows means "changed" with FOUND_ROWS too) and audited as `officer.relink`.
  Citizenids longer than the 50-character column are refused (INSERT IGNORE would truncate the key).
- `fredpd_units` is upserted from `config/units.json` at start; codes no longer in the config get `active = 0`.
- **Audit exemption (needs the contract owner):** CLAUDE.md says every `fredpd_*` write is audited. These are not
  audited per row, because they are system-maintained caches of data whose change is audited at its source:
  `fredpd_grant_cache` and `fredpd_identities` (the service audits `perms.update`), `fredpd_persons` /
  `fredpd_vehicles_idx` mirror upserts (qbx is the source; backfill and seeding write one row each),
  `fredpd_units` (a copy of `config/units.json`). The exemption should be recorded in CLAUDE.md or
  docs/contracts.md §C7; this module cannot edit either, so it stays an open deviation until the orchestrator does.

## Audit (`server/audit.lua`)

- Actor = qbx citizenid + Discord id of `src`; `src` 0 = system (both NULL). Validation: action
  `^[%w_][%w_.:-]*$` ≤ 64, target type ≤ 32, target id ≤ 64 (numbers stringified), meta JSON ≤ 16 KB (else replaced
  by `{ truncated, bytes }`). Inserts are fire-and-forget (`MySQL.insert` with callback).
- `fredpd_audit_archive [days]` (ACE `group.admin`, console or in game; default 90): one fixed cutoff
  (`NOW() - INTERVAL days DAY`, same clock as `created_at DEFAULT CURRENT_TIMESTAMP`), batches of 5000, each batch
  one transaction (copy then delete the same ids). Writes an `audit.archive` row. Run by hand monthly; no timer.

## Adapters (task 0.6)

- `adapter.init` runs while fredpd_core starts. A configured resource in state `missing` (not installed) is warned
  about at once. One that exists but is not running yet may be ensured after fredpd_core, so it gets one deferred
  re-check (`SetTimeout`, 15 s, one shot) and a call made while it is still down also reports it; either way only
  **one** warning per adapter. `server.cfg.example` now ensures the default integrations before fredpd_core.

## Locale

`L(key, vars)` calls `locale(key)` with the key only (ox_lib's own varargs run `string.format`) and substitutes
`{name}` literally; a missing var leaves `{name}` visible. New strings are in `locales/pending/core.json` (27 keys:
`core.*`, `dev.*`, `officer.callsignAssigned`,
`audit.action.{audit.archive,mirror.backfill,mirror.seed,officer.create,officer.relink}`); the merge dry run
validates them. `tests/lua/locale_test.lua` fails if code uses an `L('…')` key that exists nowhere.

## fredpd_devtools

Commands (all `lib.addCommand … restricted = 'group.admin'`, also usable from the console). Never `ensure`d in
production (`server.cfg.example` has it commented out).

- `/fredpd_selftest`: runs `grants`, `canView` (cases + engine cases) and `format` (cases + regex) fixtures through
  `server/selftest.lua`; prints per-suite counts and failures, notifies the caller. Outside the game
  `core_devtools_test` runs the same runner over the same fixture files and requires every case to pass.
- `/fredpd_backfill`, `/fredpd_seed [n=200]` (via core exports; DEV prefix; ≤ 5000), `/fredpd_fakeunits [n=20]
  [seconds=60]`: a `SetTimeout` chain that ticks every 5 s and ends at its deadline, on `/fredpd_fakeunits 0` or on
  resource stop (n ≤ 200, ≤ 3600 s).

## Tests

- `pnpm exec vitest run --project resources` → `fredpd_core/test/http.test.ts`: all HMAC vectors on
  `verifySignature` and through the handler, every route and status, duplicate suppression on `/grants` and
  `/officer` only (identical `/recompute` and `/ping` both run), the `/recompute` body rules, rejection-log
  throttling, size limits, disabled bridge incl. placeholder secrets, signedFetch signing/timeout/network/fallback
  over a real local `node:http` server incl. a trickling peer cut off at the deadline. **It is `.ts`, not `.js`:**
  Vitest 5 refuses `require('vitest')` and the ESLint block for `resources/**/*.js` is CommonJS, so an ESM `.js`
  test would not lint. The `resources` project glob includes `.ts`.
- Type check: `pnpm exec tsc -p "resources/[fredpd]/fredpd_core/test/tsconfig.json"`. `resources/` is not a
  workspace package, so `pnpm -r typecheck` does not run it: **the owner of `package.json` should add this command
  to `pnpm lint`** (or cover it with typed ESLint).
- `lua5.4 tests/lua/run.lua core_` and `locale_test`. `core_db_test.lua` runs against MariaDB through
  `tests/lua/mysql_shim.lua` in database `fredpd_test_core_lua` (reset once per run; skipped with a notice when
  unreachable): backfill/idempotency/FULLTEXT EXPLAIN, refreshPlate, seeding, grant cache JSON round trip,
  identities, seed rules loaded == fixtures, audit archive, units sync, callsign allocation incl. a forced race,
  `ensureRow` repeated (one `officer.create`) and relinked. Its `withDb` emulates oxmysql's `CLIENT_FOUND_ROWS` for
  `INSERT … ON DUPLICATE KEY UPDATE` (an unchanged match reports 1, not the CLI's 0), so a count read from such an
  upsert cannot pass here and fail in FXServer. `core_officers_test` mocks the same semantics.
- Task 1.4 timing (manual, same DB, 203 persons): `MATCH … AGAINST ('+Andersson' IN BOOLEAN MODE)` 0.6 ms,
  EXPLAIN `type = fulltext, key = ft_name`.

## Open questions

1. There is no route for the portal to tell FXServer that visibility rules changed, so `fredpd:rulesChanged` has no
   producer and rule edits reach FXServer only on restart. Suggest adding `POST /rules` (HMAC) to §C6; http.js then
   routes it to a Lua export that runs `Core.async(CanView.loadRules)`. Until then: **restart fredpd_core after
   editing visibility rules** (belongs in `docs/test-phase-1.md`, not owned by this module).
2. `files { 'migrations/*' }` (as specified) ships the SQL files to every client; `db.lua` reads them with
   `LoadResourceFile` on the server, which does not need `files`. Consider dropping it.
3. The derived personnummer is FredPD-only. If an ID-card script is added, store its number in
   `charinfo.personnummer` so both agree.
4. Should `getOfficer` fall back to anything when a character has no `fredpd_officers` row (currently nil)?
5. §C5 signs `ts + "." + body` only, not method or path. `/recompute` now refuses an empty body and unknown keys,
   so a captured `GET /ping` signature or `/grants` / `/officer` body is no longer accepted there; what remains is
   that a captured `/recompute` body can be replayed within 60 s (an extra reload). Still suggest signing
   `ts + "." + METHOD + " " + path + "." + body` in a contract revision (both sides + fixtures).
