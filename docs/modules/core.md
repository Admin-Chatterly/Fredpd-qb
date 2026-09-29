<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Module: fredpd_core runtime + fredpd_devtools

Tasks 0.6 (adapters), 1.2 (HTTP bridge), 1.3 runtime (grant cache), 1.4 (search mirrors), 1.5 server wrapper
(canView), 1.7b FXServer side (officer identity, callsigns), plus the fredpd_devtools skeleton. Implements
docs/contracts.md §C1–§C9 on the FXServer. The pure shared modules (`shared/grants|canview|format|regex|sha256.lua`)
and the migration runner (`server/db.lua`) belong to other modules; this one calls them.

## Files

| File | Role |
|---|---|
| `fredpd_core/fxmanifest.lua` | cerulean, lua54, `node_version '22'`, `ox_lib 'locale'`; server: MySQL.lua, `server/http.js`, `server/main.lua`; `files`: see "Client files" |
| `server/main.lua` | entry: config → exports/events (perms, canview, audit, mirror, officers, adapters) → `MySQL.ready`: `db.migrate()`, rules, officers, units, online players |
| `server/http.js` | HMAC bridge: `SetHttpHandler` routes (§C6) and the `signedFetch` export |
| `server/core.lua` | `Core.fetch`, `Core.rateLimit`, `Core.async`, `Core.internalExport`, SQL binding helpers, config, qbx player access, logging |
| `server/perms.lua` | grant cache `Cache[src]`, fallback to `fredpd_grant_cache`, `applyGrants` push, `fredpd_identities` |
| `server/canview.lua` | rules from `fredpd_visibility_rules`, `canView` / `canViewMany` |
| `server/audit.lua` | `audit` export, `Audit.write`, `archiveOlderThan` + command `fredpd_audit_archive` |
| `server/mirror.lua` | `fredpd_persons` / `fredpd_vehicles_idx`: qbx events, backfill, plate refresh, dev seeding |
| `server/officers.lua` | officer names from Discord, `fredpd_officers` rows, callsign on first duty, `fredpd_units` sync |
| `shared/locale.lua` | `L(key, vars)` over ox_lib `locale()`; pure `substitute` |
| `shared/time.lua` | UTC timestamps (§C7, §C12): `isoSelect`, `toIsoUtc`, `toDatetime`, `toEpoch`, `toEpochMs`, `nowIso` (see "Timestamps") |
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
| `recomputeGrants(discordIds\|nil)` → n | called by http.js for `POST /recompute` (**internal**) |
| `setOfficerIdentity(discordId, displayName, avatarUrl)` → n | called by http.js for `POST /officer` (**internal**) |
| `ensureCallsign(src)` | lets a duty script trigger callsign allocation (async, returns nothing) |
| `refreshPlate(plate)` → row\|nil | vehicle search calls it on a `fredpd_vehicles_idx` miss |
| `backfillMirror(src)` → `{ persons, vehicles }` | `/fredpd_backfill`; audited (**fredpd_devtools only**) |
| `seedDevRows(src, persons, vehicles)` → counts | `/fredpd_seed`; only `DEV…` citizenids, `INSERT IGNORE`, audited (**fredpd_devtools only**) |
| `getAdapter(kind)` | task 0.6 |

**Internal exports.** `applyGrants`, `recomputeGrants` and `setOfficerIdentity` exist only for `server/http.js`, and
`backfillMirror` / `seedDevRows` only for fredpd_devtools. As plain exports any server resource could call them
(`exports.fredpd_core:applyGrants(id, { grants = { 'perm:*' }, … })` would escalate a player; `seedDevRows` is live
in production), so they are registered with `Core.internalExport(name, fn, allowed)`: the call runs only when
`GetInvokingResource()` is nil/empty (console, same runtime), `fredpd_core` itself (http.js calls
`exports[resource][name]` from this resource's JS runtime) or a listed resource (`fredpd_devtools` for the two dev
exports); anyone else gets `false` and one warning per export and resource. **UNVERIFIED** (FiveM runtime): that
`GetInvokingResource()` inside a Lua export called from the same resource's JS runtime is `'fredpd_core'` (or nil);
if it were anything else, `/grants`, `/recompute` and `/officer` would answer 400 `rejected by …` and the log would
show `export … is internal to fredpd_core; call from resource … refused`.

Events: client `fredpd:client:grantsChanged(set)` (contract). New server-local events other modules may listen to:
`fredpd:grantsChanged(src)` after every cache change, `fredpd:officerChanged(citizenid)` after a name push or a new
callsign, `fredpd:devtools:fakeUnits(units|nil)` per fake-unit tick. `fredpd:rulesChanged` is produced by http.js
(`emit`, server-local) for a signed `POST /rules` and may also be fired by another server resource with
`TriggerEvent`; canview.lua consumes it (server-only: `AddEventHandler`, and a player source is ignored with a
warning).

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
- **`POST /rules` (§C6):** body exactly `{}`: an empty body or non-object JSON is 400 `bad_json`, any key is 400
  `invalid_body` (`unknown key …`), so no other route's body or a GET signature is accepted. It fires the
  server-local event `fredpd:rulesChanged` with FiveM's JS `emit` (= `TriggerEvent`; Lua handlers then see
  `source == ''`, never a player id) and answers `{ ok: true }` at once: the reload runs in canview.lua's own
  thread, so the answer means "reload started", not "rules loaded" (the console then prints `loaded N visibility
  rules`). Not memoised, like `/recompute`: two rule edits in one second sign identically and both must reload.
  Replay within 60 s (or a captured `/recompute {}`, which signs the same body) only costs an extra reload. The
  service client is `fx.pushRulesChanged()` (docs/modules/service.md).
- **Info log lines (console, for the Phase 1 checklist):** one line per accepted push: `grants pushed for discord
  <id>: <n> grant(s), applied to <m> player(s)`, `grant recompute for <n discord id(s) | everyone online>: <m>
  player(s) re-fetching`, `officer name for discord <id> is now "<name>" (<m> officer character(s))` (JSON-quoted, so control
  characters cannot forge log lines) and `visibility rules changed: reloading`. Pushes are rare (role or name
  changes, service start, permission saves), so this is not per-request noise; rejections stay throttled.
- Rejected requests (401) are logged at most once per 10 s with a count of the suppressed ones: the routes are on the
  public game port, so an unauthenticated client must not be able to flood the console.
- GET is answered without waiting for a body (signed with the empty string, §C5).
- Responses: `/ping` `{ ok, players }`, `/grants` `{ ok, applied }`, `/recompute` `{ ok, scheduled }`, `/officer`
  `{ ok, updated }`, `/rules` `{ ok }`. The Lua exports it calls never yield; DB/network work runs in its own Lua thread.
- Secret: convar `fredpd_hmac_secret`, ≥ 32 chars and not a known placeholder (`change_me`/`changeme`,
  `placeholder`, `your_secret`, one repeated character), else an error is logged, every route answers 503 and
  `signedFetch` calls back `(0, '{"error":"bridge_disabled"}')`. `server.cfg.example` ships `"CHANGE_ME"`, which is
  refused on both counts, so copying the example as it is leaves the bridge off instead of on with a public secret.
- `/officer`: `displayName` is trimmed and limited to 100 **characters** (code points, like `utf8.len` in Lua and
  the `VARCHAR(100)` utf8mb4 column); a `false` from `setOfficerIdentity` is a 400 `invalid_body`, like `/grants`.
- `signedFetch(method, path, body, cb)`: `cb(status, bodyString)` exactly once; status 0 = no HTTP response, body
  `{"error":"timeout"|"network"|"invalid_request"|"invalid_body"|"bridge_disabled"|"forbidden"|"too_large"}`.
  `forbidden`: the calling resource (`GetInvokingResource()`, empty = fredpd_core itself) is not `fredpd_*`, or the
  path is not `/internal/...` or `/upload` (dot segments and `%2e`/`%2f` refused), so other server resources cannot
  make signed service calls through the export (review fix; a resource that can read the convar is out of scope).
  `too_large`: the response passed 1 MiB (`MAX_RESPONSE_BYTES`, by Content-Length or counted while reading, on both
  transports). UNVERIFIED in FXServer: that `GetInvokingResource()` in a JS export names a Lua caller. One overall 3 s deadline
  (timer + AbortController) for both transports: global `fetch` (hence `node_version '22'`) and the `node:http(s)`
  fallback, which is aborted by the same signal (not a socket idle timeout, so a trickling peer cannot hold it).
- The file is structured as pure factories (`createHandler`, `createSignedFetch`, `createBridge`) plus a few lines
  that wire the FiveM globals (`SetHttpHandler`, `GetConvar`, `exports`, `emit`, …), so the test evaluates it in a
  `vm` context with mocked globals.

## Visibility rules (`server/canview.lua`)

- Loaded once after the migrations (`MySQL.ready`) and again on every `fredpd:rulesChanged` (`Core.async`, one-shot
  thread). A failed query keeps the previous rules; no rules at all means every record is `none` (fail closed).
- **Load tickets:** each load takes a ticket; a load whose query finishes after a newer load was already applied is
  discarded (`discarded an overtaken visibility rules load`), so two quick rule edits can never leave the older rule
  set active. Verified outside the game with coroutines that finish out of order (a scratch script, not in the suite:
  `tests/lua/` is not owned by this task; suggested for `core_canview_test.lua`).
- **Source guard:** `tonumber(source) > 0` (a player) → ignored with a warning; `''`/nil/0 (server-local emit,
  console) → reload. Belt and braces: `AddEventHandler` without `RegisterNetEvent` already makes FXServer drop a
  client's `TriggerServerEvent` ("not safe for net"). Covered by `core_canview_test.lua` (source `''`, nil, 12).

## Grants runtime (`server/perms.lua`)

- `playerJoining` → Discord id from `GetPlayerIdentifierByType(src, 'discord')` → `GET /internal/grants/:id` →
  validate → `Cache[src]` + `fredpd_grant_cache` upsert. Failure (status ≠ 200 or invalid set) → cached row + warning;
  no row → empty set (or, for a player who already holds a set, that set is kept). No Discord identifier → empty set
  + warning. Until loaded every check fails closed.
- **Sets only move forward (`computedAt`, milliseconds via `Time.toEpochMs`).** A fetched, pushed or cached set older
  than the one the player holds is ignored (`applyGrants` counts only the players it updated and logs the skipped
  ones). So a `/grants` push resolved before an admin's revocation that reaches FXServer after the recompute that
  revocation triggered cannot bring the revoked grants back, whichever order they arrive in; the old rule "a push
  always beats an in-flight fetch" is gone. A set without a readable `computedAt` is never treated as older (the
  service always sends one). The `fredpd_grant_cache` upsert has the same rule in SQL
  (`grants = IF(VALUES(computed_at) >= computed_at, …)`, `computed_at = GREATEST(…)`; order-independent). The column
  is `DATETIME` (seconds), so in the DB two sets within one second tie and the last write wins; the in-memory
  comparison has millisecond precision. The service's `writeGrantCache` uses the same rule.
- **Loads are coalesced per player:** while a fetch is in flight, further loads (a burst of `/recompute`, a join and a
  recompute) only queue **one** more load that starts when the first ends. A change committed during the first fetch
  is still picked up by the second; a replayed `/recompute {}` costs at most one extra fetch per player at a time.
- `fredpd_grant_cache.grants` is written with a hand-built encoder so empty lists are `[]` (FiveM's json may encode
  `{}`); `computed_at` = the set's `computedAt` as UTC DATETIME (`Time.toDatetime`; an offset is converted), or
  `UTC_TIMESTAMP()` when it is not an ISO timestamp. `fredpd_identities.last_seen` = `UTC_TIMESTAMP()`.
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
  parameter array (a Lua array with nil holes does not reach oxmysql as an array). `buildInsert(tbl, cols, rows,
  update, touch)`: with `touch = 'updated_at'` the upsert maintains that column, moving it to `UTC_TIMESTAMP()` only
  when an `update` column really changes (docs/modules/db.md "Time zones"); mirrors and the units sync use it.
- `Core.getPlayerData(src)` always asks `exports.qbx_core:GetPlayer(src)`, so the actor is never taken from the
  client or a stale cache (§4.6).

## Timestamps (`shared/time.lua`, docs/contracts.md §C7/§C12)

- Stored UTC whatever the MariaDB zone; SQL writes `UTC_TIMESTAMP()`, never the session clock; `updated_at` is set
  by the writer (`RELINK_SQL`, `CALLSIGN_SQL`, units deactivation, `buildInsert` touch, `db.nextSeq`).
- Reading a DATETIME for the wire: `'SELECT ' .. Time.isoSelect('b.created_at', 'createdAt') .. ' FROM …'` →
  `'2026-09-29T12:00:00Z'`. Never read DATETIME columns bare through oxmysql: it returns epoch ms computed in the
  FXServer host's local zone (1–2 h off on a Stockholm host). `Time.toIsoUtc` rejects such numbers with that
  explanation; it also normalises `YYYY-MM-DD HH:MM:SS` text (e.g. from `DATE_FORMAT(…, '%Y-%m-%d %H:%i:%s')`).
- `Time.toDatetime(iso)` binds a wire timestamp into a DATETIME parameter; `Time.toEpoch(v)` compares with
  `os.time()`; `Time.nowIso()` is `os.date('!…')` (UTC, zone-independent). Never `UNIX_TIMESTAMP(col)` or
  `FROM_UNIXTIME(?)` in SQL (they convert through the session zone); see docs/modules/db.md "Time zones", Epochs.
- No existing core read exposes a DATETIME column yet (officers, perms cache, mirror and rules select none); the
  audit archive cutoff is computed with `UTC_TIMESTAMP()` and logged in the audit meta as ISO UTC.
- `/fredpd_selftest` adds a `time` suite: pure checks plus, in game, `isoSelect(UTC_TIMESTAMP())` through oxmysql
  compared with the Lua UTC clock (must be a string, within 60 s) and the session zone printed. UNVERIFIED until run
  on FXServer.

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
  citizenid) without touching the Discord-owned columns of an existing row. `display_name` is NOT NULL: the name
  pushed by the bot (`/officer`, sent when the player joins) if FXServer has it, else a **neutral placeholder**
  `L('officer.unnamed', { id = <last 4 digits of the Discord id> })` ("Polis utan namn (…1234)"), stored in the server
  language. Never the character name (§4.9) and no longer the FiveM account name: that one is player-chosen (control,
  bidi, zero-width and look-alike characters included) and could imitate another officer on rosters. The placeholder
  stays until the bot's next identity sync for that user (next join or name change) when the service was down at
  the first load; with `OFFICER_NAME_SOURCE=character` (not implemented here, service.md question 1) it stays.
- **Duty and job events are rate limited**: `QBCore:Server:SetDuty` and `QBCore:Server:OnJobUpdate` run at most once
  per player per 2 s each (`Core.rateLimit`, keys `officers:duty` / `officers:job`), because duty toggling starts with
  the client net event `QBCore:ToggleDuty` and each run costs DB queries. A dropped repeat loses nothing (the run it
  follows did the work). "No unit grant" / "no callsign prefix" is logged once per character and reason until the
  next `fredpd:grantsChanged` for that player.
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
- **Audit exemption:** docs/contracts.md §C7 now exempts `fredpd_grant_cache`, `fredpd_identities` (last_seen),
  `fredpd_persons` and `fredpd_vehicles_idx`, which covers the per-row writes here (the service audits
  `perms.update`; backfill and seeding write one audit row each). Two writes are still outside the §C7 list (see
  open question 6): `fredpd_identities.license` / `last_citizenid` (written when a character loads, not only
  `last_seen`) and `fredpd_units` (a copy of `config/units.json`, upserted at start).

## Audit (`server/audit.lua`)

- Actor = qbx citizenid + Discord id of `src`; `src` 0 = system (both NULL). Validation: action
  `^[%w_][%w_.:-]*$` ≤ 64, target type ≤ 32, target id ≤ 64 (numbers stringified), meta JSON ≤ 16 KB (else replaced
  by `{ truncated, bytes }`). Inserts are fire-and-forget (`MySQL.insert` with callback).
- `fredpd_audit_archive [days]` (ACE `group.admin`, console or in game; default 90): one fixed cutoff
  (`UTC_TIMESTAMP() - INTERVAL days DAY`, the same UTC clock as `created_at DEFAULT (UTC_TIMESTAMP())`, whatever
  the session zone), batches of 5000, each batch
  one transaction (copy then delete the same ids). Writes an `audit.archive` row. Run by hand monthly; no timer.

## Adapters (task 0.6)

- **Prison default is `none`** (config/integrations.json) until the xt-prison adapter exists (task 4.1,
  docs/deps-verification.md Decision 2). `qbx_prison` must never run as shipped (any client can unlock any
  ox_doorlock door and clear its own sentence, §2a): `server.cfg.example` no longer ensures it (a commented
  `# ensure xt-prison` instead) and the `qbx_prison` adapter is opt-in and logs a caution at every start. The
  `qbx_police` → `qbx_police-jail` alias is gone (qbx_police has no jail, §2); that stub is rescoped to "metadata
  only, no confinement" and warns when selected. Adapters can carry a `caution` (`base.lua`), logged once per init.
- `adapter.init` runs while fredpd_core starts. A configured resource in state `missing` (not installed) is warned
  about at once. One that exists but is not running yet may be ensured after fredpd_core, so it gets one deferred
  re-check (`SetTimeout`, 15 s, one shot) and a call made while it is still down also reports it; either way only
  **one** warning per adapter. `server.cfg.example` now ensures the default integrations before fredpd_core.

## Locale

`L(key, vars)` calls `locale(key)` with the key only (ox_lib's own varargs run `string.format`) and substitutes
`{name}` literally; a missing var leaves `{name}` visible. The earlier 27 keys are merged. New since then:
`locales/pending/core.json` → `officer.unnamed` (the roster placeholder above); the merge dry run validates it.
`tests/lua/locale_test.lua` fails if code uses an `L('…')` key that exists nowhere.

## Client files (`fxmanifest.lua` `files`)

`shared/*.lua`, `config/formats.json`, `config/units.json`, `locales/*.json`. **Not** `migrations/*` (schema DDL,
index.json; `db.lua` reads them server-side with `LoadResourceFile`, which needs no `files` entry) and **not**
`config/integrations.json` (server-only; it holds e.g. `unauthorizedLookupThreshold`, which a client should not
learn). **Deviation from §C1** ("`config/*.json` under `files`"): only the two display configs client code may need
are listed; the contract owner may want to narrow §C1 the same way. No client code loads any of them yet.

## fredpd_devtools

Commands (all `lib.addCommand … restricted = 'group.admin'`, also usable from the console). Never `ensure`d in
production (`server.cfg.example` has it commented out).

- `/fredpd_selftest`: runs `grants`, `canView` (cases + engine cases) and `format` (cases + regex) fixtures through
  `server/selftest.lua`, plus the `time` suite (UTC probe through oxmysql, in a one-shot thread); prints per-suite
  counts and failures, notifies the caller. Outside the game
  `core_devtools_test` runs the same runner over the same fixture files and requires every case to pass.
- `/fredpd_backfill`, `/fredpd_seed [n=200]` (via core exports; DEV prefix; ≤ 5000), `/fredpd_fakeunits [n=20]
  [seconds=60]`: a `SetTimeout` chain that ticks every 5 s and ends at its deadline, on `/fredpd_fakeunits 0` or on
  resource stop (n ≤ 200, ≤ 3600 s).

## Tests

- `pnpm exec vitest run --project resources` → `fredpd_core/test/http.test.ts`: all HMAC vectors on
  `verifySignature` and through the handler, every route and status, duplicate suppression on `/grants` and
  `/officer` only (identical `/recompute`, `/rules` and `/ping` all run), the `/recompute` body rules, `/rules`
  (exactly `{}`, other routes' bodies and a GET signature refused, one `emit('fredpd:rulesChanged')`, 401/405/503,
  an `emit` that throws → 500 and a retry runs), the info log lines, rejection-log
  throttling, size limits, disabled bridge incl. placeholder secrets, signedFetch signing/timeout/network/fallback
  over a real local `node:http` server incl. a trickling peer cut off at the deadline. **It is `.ts`, not `.js`:**
  Vitest 5 refuses `require('vitest')` and the ESLint block for `resources/**/*.js` is CommonJS, so an ESM `.js`
  test would not lint. The `resources` project glob includes `.ts`.
- Type check: `pnpm exec tsc -p "resources/[fredpd]/fredpd_core/test/tsconfig.json"`. `resources/` is not a
  workspace package, so `pnpm -r typecheck` does not run it: **the owner of `package.json` should add this command
  to `pnpm lint`** (or cover it with typed ESLint).
- `lua5.4 tests/lua/run.lua core_`, `locale_test` and `time_test` (incl. `toEpochMs`). Added for the review fixes:
  perms (newer set wins in both arrival orders, stale push ignored, fallback row vs held set, coalesced loads,
  internal exports refused for other resources), officers (neutral placeholder, duty/job rate limit, warn once),
  helpers (`internalExport`), adapters (prison default `none`, cautions, alias gone), DB (`07b` cache rows only move
  forward, placeholder names). `core_db_test.lua` runs against MariaDB through
  `tests/lua/mysql_shim.lua` in database `fredpd_test_core_lua` (reset once per run; skipped with a notice when
  unreachable), **every session at time_zone `+02:00`**: backfill/idempotency/FULLTEXT EXPLAIN, refreshPlate,
  seeding, grant cache JSON round trip (+ UTC fallback), identities (UTC last_seen/created_at), seed rules loaded ==
  fixtures, audit archive (incl. a row 30 min inside the window that a session-clock cutoff would move), units sync,
  callsign allocation incl. a forced race, `ensureRow` repeated (one `officer.create`) and relinked, and updated_at
  maintenance (mirror upserts move it only for changed rows, units, relink, callsign). Its `withDb` emulates oxmysql's `CLIENT_FOUND_ROWS` for
  `INSERT … ON DUPLICATE KEY UPDATE` (an unchanged match reports 1, not the CLI's 0), so a count read from such an
  upsert cannot pass here and fail in FXServer. `core_officers_test` mocks the same semantics.
- Task 1.4 timing (manual, same DB, 203 persons): `MATCH … AGAINST ('+Andersson' IN BOOLEAN MODE)` 0.6 ms,
  EXPLAIN `type = fulltext, key = ft_name`.

## Open questions

1. Resolved: `POST /rules` (§C6) is built (http.js emits `fredpd:rulesChanged`; service `fx.pushRulesChanged()`).
   There is no rule editor yet, so nothing calls it; until the Ledning rules page exists, rules are edited in the
   database and applied with the signed curl call in `docs/test-phase-1.md` step 10 (or a fredpd_core restart).
2. Resolved: `migrations/*` and `config/integrations.json` are no longer sent to clients (see "Client files").
3. The derived personnummer is FredPD-only. If an ID-card script is added, store its number in
   `charinfo.personnummer` so both agree.
4. Should `getOfficer` fall back to anything when a character has no `fredpd_officers` row (currently nil)?
5. §C5 signs `ts + "." + body` only, not method or path. `/recompute` refuses an empty body and unknown keys, so a
   captured `GET /ping` signature or `/grants` / `/officer` body is not accepted there; what remains is that a
   captured `/recompute` body can be replayed within 60 s, and `/rules {}` and `/recompute {}` sign the same bytes
   (an extra rules reload or grant re-fetch; no state changes). Mitigations now in place without a contract change:
   loads are coalesced per player (one in flight + one queued), and the service answers `/internal/*` (and the
   HMAC `/upload`) only to direct loopback requests without proxy headers, so a captured signature cannot be
   replayed through the tunnel. **FXServer↔service traffic must stay on loopback** (never cross a network in clear
   text; §C6 pins `127.0.0.1` both ways). Still proposed for the contract owner: sign
   `ts + "." + METHOD + " " + path + "." + rawBody` (ideally with a direction tag) in §C5, `hmac.ts`, `http.js` and
   the fixtures together. Not done here: refusing non-loopback `req.address` in http.js, because the format of
   FXServer's `req.address` is unverified and a wrong parse would disable the bridge.
6. §C7's audit-exempt list lacks `fredpd_units` (system copy of `config/units.json`) and names only `last_seen` of
   `fredpd_identities`, while perms.lua also writes `license` and `last_citizenid` there (a cache of which character
   a Discord user plays, whose source is qbx). Suggest adding both to §C7 (contract owner).
