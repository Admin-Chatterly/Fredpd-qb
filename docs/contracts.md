# FredPD — shared contracts

Binding interface decisions that several modules depend on. `IMPLEMENTATION.md` is the plan; this file pins the
details the plan leaves open so that modules built in parallel fit together. Change a contract here first, then in code.

`PLAN.md` (FredPD-PLAN.md) is not in the repo yet. Where the plan refers to PLAN §5d (visibility) or §10 (glossary),
the assumptions below apply until PLAN.md is added; each assumption is marked **ASSUMED**.

---

## C1. Lua module conventions

- Pure shared modules live in `resources/[fredpd]/fredpd_core/shared/*.lua`, are written as `local M = {} … return M`,
  use only plain Lua 5.4 plus the global `json` (FiveM provides it; `tests/lua/run.lua` provides rxi/json.lua) and
  touch no FiveM natives at load time. They are unit-tested outside the game by `tests/lua/*_test.lua`
  (`pnpm test:lua`, which does `require('shared.format')` etc. with `package.path` rooted at `fredpd_core/`).
- Inside resources, modules are loaded with ox_lib `require` (`require 'shared.format'` within fredpd_core,
  `require '@fredpd_core.shared.format'` from another resource). fredpd_core's fxmanifest lists `shared/*.lua`
  and `config/*.json` under `files`.
- Write plain Lua 5.4 (no cfxlua compound operators, no backtick hashes) so `luac5.4 -p` in `pnpm lint` passes.
- No `while true` and no `Citizen.CreateThread` polling (lint rejects them). Use events, `SetTimeout`, `lib.zones`,
  `lib.onCache`, and ox_lib callbacks.
- Every server net event/callback: `local src = source` → grant check → rate limit (`lib` cooldown) → work.

## C2. Grants (`packages/types/src/grants.ts` ⇄ `fredpd_core/shared/grants.lua`)

Grant key string: `"<type>:<key>"`, type ∈ `weapon | vehicle | armory | tool | mdt_page | intel_tier | unit | perm`.
Wildcard `"<type>:*"` allows every key of that type. Deny always wins over allow, wildcard deny included.

Input rows (DB column names camelCased):

```ts
type RoleRow = { discordRoleId: string; name: string; position: number; deleted: boolean };
type RoleGrantRow = { discordRoleId: string; grantType: GrantType; grantKey: string; effect: 'allow' | 'deny' };
type ResolveInput = { memberRoleIds: string[]; roles: RoleRow[]; grants: RoleGrantRow[]; unitOrder: string[] };
```

Output, identical JSON on the wire (`/internal/grants`, `/fredpd_core/grants` push), in `fredpd_grant_cache.grants`
and in the Lua cache:

```ts
type GrantSet = {
  grants: string[];      // allowed "type:key", sorted, deduped (deny NOT subtracted for wildcards; see denied)
  denied: string[];      // denied "type:key", sorted, deduped
  tier: 0 | 1 | 2;       // max allowed, non-denied intel_tier key parsed as int, clamped 0..2, default 0
  units: string[];       // allowed, non-denied unit keys, ordered by unitOrder, unknown units after, alphabetical
  rank: { roleId: string; key: string } | null; // highest-position role holding an allowed perm:rank:<key>
  computedAt: string;    // ISO-8601 UTC
};
```

- Roles with `deleted = true` and role ids not in `memberRoleIds` are ignored.
- `hasGrant(set, type, key)`: `(grants ∋ type:key or grants ∋ type:*) and not (denied ∋ type:key or denied ∋ type:*)`.
- TS exports: `GrantTypeSchema`, `GrantSetSchema` (zod), `resolveGrants(input)`, `hasGrant(set, type, key)`,
  `emptyGrantSet()`. Lua exports: `M.resolve(input)`, `M.has(set, type, key)`, `M.empty()`.
- Shared fixtures: `packages/types/test/fixtures/grants.fixtures.json` (≥ 20 cases, `computedAt` excluded from
  comparison).

## C3. Visibility (`canView.ts` ⇄ `shared/canview.lua`; server wrapper `fredpd_core/server/canview.lua`)

Result order: `none < notice < masked < full`. `notice` = kontaktnotis (the record exists; contact the owner/unit).
`masked` = content visible with parts above the viewer's tier and source fields stripped.

```ts
type Viewer = { citizenid: string | null; tier: 0 | 1 | 2; units: string[]; grants: GrantSet };
type VisRecord = {
  type: 'case' | 'report' | 'evidence' | 'poi' | 'bolo' | 'mission' | 'intel_report' | 'intel_source';
  id: string | number; level: 0 | 1 | 2; status: 'open' | 'closed';
  unit?: string | null; assignees?: string[]; ownerCitizenid?: string | null; handlerCitizenid?: string | null;
};
type VisibilityRule = {   // table fredpd_visibility_rules
  id: number; recordType: string /* or '*' */; level: 0 | 1 | 2 | null /* null = any */;
  recordStatus: 'open' | 'closed' | 'any';
  viewerCondition: 'any' | 'assigned' | 'handler' | 'unit' | 'tier_gte' | 'perm';
  conditionValue: string | null; result: 'full' | 'masked' | 'notice' | 'none'; priority: number; enabled: boolean;
};
canView(viewer, record, rules): 'full' | 'masked' | 'notice' | 'none'
```

- Conditions: `assigned` = viewer.citizenid ∈ assignees or = ownerCitizenid; `handler` = viewer.citizenid =
  handlerCitizenid; `unit` = viewer.units ∋ (conditionValue ?? record.unit); `tier_gte` = viewer.tier ≥ record.level;
  `perm` = hasGrant(viewer.grants, 'perm', conditionValue); `any` = true.
- Evaluation: enabled rules whose recordType/level/status match, sorted by priority desc then id asc; first rule
  whose condition holds gives the result; no match → `none`.
- Hard caps applied after the rules (not overridable by config):
  1. `intel_source`: `full` only if (handler and perm `intel.handler`) or perm `intel.command`; otherwise at most `masked`.
  2. `record.level > viewer.tier` and the viewer is not assigned/owner/handler and lacks perm `intel.command` →
     at most `notice`.
- **ASSUMED (PLAN §5d)** default rules, seeded by `db/seed/visibility_rules_default.sql`: permissive for IGV lookups,
  strict for sources and missions. Open case: assigned/unit → full, anyone else → notice. Closed case: tier_gte →
  masked, assigned → full. Perm `records.admin` → full on everything but intel. Missions: members (assigned) and
  `intel.command` → full, others → notice. Intel reports: author/assigned and (`intel.read` + tier_gte) → full, else
  none. Intel sources: handler → full, `intel.read` → masked, else none. BOLO level 0 → full for everyone.
- Shared fixtures: `packages/types/test/fixtures/canView.fixtures.json` = `{ rules: VisibilityRule[], cases: [{ name,
  viewer, record, expected }] }`, ≥ 20 cases, also run in game by `/fredpd_selftest`.

## C4. Formats (`packages/types/src/format.ts` ⇄ `shared/format.lua`, config `config/formats.json`)

- `formatId(template, ctx)`; ctx: `{ seq?, n?, unit?, case?, date? }` (`date` ISO string, `yy`/`yyyy` derived from it
  in Europe/Stockholm). `{{n:3}}` zero-pads to width 3. Unknown placeholder or missing value → error.
- `templateToRegex(name, formats)` → anchored pattern string for `caseNumber`, `reportNumber`, `evidenceTag`,
  `callsign` (`{{seq}}`/`{{n}}` → `\d+`, `{{n:k}}` → `\d{k,}`, `{{yy}}` → `\d{2}`, `{{yyyy}}` → `\d{4}`,
  `{{unit}}` → `[A-Z]+`, `{{case}}` → the caseNumber pattern without anchors, literals escaped).
- `detectSearchType(query, formats)` → `{ type: 'plate' | 'caseNumber' | 'personId' | 'name', normalized }`
  (trim; plate uppercased with the inner space removed; personId digits with a dash before the last four).
- `formatDate(isoUtc)`, `formatTime(isoUtc)`, `formatCurrency(amount)` per formats.json. Lua has no tz database:
  the Lua port implements the EU DST rule for Europe/Stockholm (CET/CEST switching at 01:00 UTC on the last Sunday
  of March/October).
- The Lua port needs a small regex engine (`shared/regex.lua`) covering what formats.json uses: `^ $ . [...] [^...]`
  ranges, `\d \s \w`, escapes, quantifiers `? * + {n} {n,} {n,m}`. Unsupported syntax errors at compile time.
- Shared fixtures: `packages/types/test/fixtures/format.fixtures.json`, ≥ 15 cases, run by Vitest and Lua.

## C5. HMAC (`packages/types/src/hmac.ts` ⇄ `fredpd_core/server/http.js`)

Headers `X-FredPD-Ts` (unix seconds) and `X-FredPD-Sig` = hex(hmac_sha256(secret, ts + "." + rawBody)). A GET is
signed with an empty rawBody. Reject when |now − ts| > 60 s or the signature mismatches (constant-time compare) →
HTTP 401 `{ "error": "unauthorized" }`. Secret: convar `fredpd_hmac_secret` / env `FREDPD_HMAC_SECRET`; refuse to
start the bridge if it is empty or shorter than 32 chars. Vectors: `packages/types/test/fixtures/hmac.fixtures.json`.

## C6. HTTP endpoints

FXServer (`SetHttpHandler` in fredpd_core, reached at `http://127.0.0.1:30120/fredpd_core/<path>`, all HMAC-signed):

| Method | Path | Body | Effect |
|---|---|---|---|
| GET | `/ping` | – | `{ ok: true, players: n }` |
| POST | `/grants` | `{ discordId, grants: GrantSet }` | `applyGrants` → cache, `fredpd_grant_cache`, `fredpd:client:grantsChanged` to that player |
| POST | `/recompute` | `{ discordIds?: string[] }` | re-fetch grants from the service for those (or all) online players |
| POST | `/officer` | `{ discordId, displayName, avatarUrl }` | refresh the in-memory officer name used for rosters |
| POST | `/rules` | `{}` | reload `fredpd_visibility_rules` (fires `fredpd:rulesChanged`); sent by the service after a rule edit |

Service (Fastify, `FREDPD_SERVICE_URL`, default `http://127.0.0.1:3000`; convar `fredpd_service_url` on FXServer):

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/internal/ping` | HMAC | health |
| GET | `/internal/grants/:discordId` | HMAC | `{ discordId, member: boolean, grants: GrantSet }` |
| POST | `/internal/events` | HMAC | `{ type, payload }`, type ∈ `alertCreated, alertAssigned, alertClosed, unitsChanged, playerJoined, playerDropped` → WebSocket fan-out |
| GET | `/auth/discord`, `/auth/discord/callback`, `POST /auth/logout` | – | Discord OAuth2, session cookie |
| * | `/api/*` | session + CSRF on writes | portal API, same action names and zod schemas as the NUI |
| POST | `/upload` | session or HMAC | ≤ 5 MB, MIME sniffed, png/jpeg/webp |
| GET | `/avatar/:discordId`, `/share/:token`, `/ws` | – / token / session | see §4.9, §4.6 |

Lua → service: `exports.fredpd_core:signedFetch(method, path, bodyTable|nil, cb)` (JS export; `cb(status, bodyString)`).
Lua wraps it as `Core.fetch(method, path, body)` returning `status, decoded` inside a coroutine (promise + Citizen.Await).

## C7. Database

- Migrations: `db/migrations/NNN_name.sql`, table `fredpd_migrations (id VARCHAR(64) PK = filename, checksum
  CHAR(64), applied_at)`. Statements end with `;` at end of line; no procedures/triggers/DELIMITER. A statement may be
  preceded by `-- @if-table-exists <table>` to run only when that (non-FredPD) table exists (for `player_vehicles`).
  A changed checksum for an applied migration is an error, never a silent re-run.
- Runners: canonical `fredpd_core/server/db.lua` (oxmysql; the build copies `db/migrations` into
  `fredpd_core/migrations/` with an `index.json`) and `scripts/migrate.mjs` (mysql2; dev/CI/service tests). Both
  implement the same algorithm and are tested against MariaDB.
- File ownership: `001`–`008` as listed in IMPLEMENTATION.md §6; `009_service.sql` (`fredpd_sessions`,
  `fredpd_uploads`) belongs to apps/service.
- Test DB: env `FREDPD_TEST_DB_URL`, default `mysql://fredpd:fredpd@127.0.0.1:3306/fredpd_test`. DB tests skip (with
  a console warning) when it is unreachable. `db/dev/qbx_stub.sql` creates minimal `players`/`player_vehicles` for tests.
- Every table: InnoDB, utf8mb4, `utf8mb4_swedish_ci`, `created_at DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP())`.
  Times are UTC regardless of the MariaDB server/session time zone: defaults use `(UTC_TIMESTAMP())`, code writes
  `UTC_TIMESTAMP()`, and `updated_at` is set explicitly by the writer (MariaDB has no `ON UPDATE UTC_TIMESTAMP()`).
  Never `NOW()`, `CURRENT_TIMESTAMP` or `ON UPDATE CURRENT_TIMESTAMP`. The DB server does not need to run in UTC.
- Audit (§0 rule 5) covers authoritative records. Exempt, because they are caches, mirrors or logs themselves:
  `fredpd_migrations`, `fredpd_grant_cache`, `fredpd_identities` (last_seen), `fredpd_persons`, `fredpd_vehicles_idx`,
  `fredpd_sessions`, `fredpd_sequences`, `fredpd_plate_checks`, `fredpd_report_drafts`, `fredpd_audit*`.

## C8. Locale

- `locales/sv.json` and `locales/en.json`: flat objects with dotted keys (`"mdt.search.placeholder": "…"`), identical
  key sets. Named placeholders `{name}`. Lua: `L(key, vars)` from `fredpd_core/shared/locale.lua` (wraps ox_lib
  `locale()`, then substitutes `{name}`). TS: `t(key, vars)` from `@fredpd/ui`.
- `packages/types/src/locale-keys.ts` is generated by `pnpm gen:locale-keys` (type `LocaleKey`).
- Modules that need new strings while another agent owns the locale files add
  `locales/pending/<module>.json` = `{ "<key>": { "sv": "…", "en": "…" } }`; `node scripts/merge-pending-locales.mjs`
  merges and deletes them.

## C9. Server exports and events

As IMPLEMENTATION.md §4.3. fredpd_core additionally exports `signedFetch`, `getOfficer(src)`, `isOnDuty(src)`,
`getCitizenId(src)`, `L(key, vars)`. Other resources never read `Grants[src]` directly.

## C10. Permissions admin API (portal "Behörigheter", task 1.8)

Requires perm `admin.permissions` (grant `perm:admin.permissions`). Schemas in `packages/types/src/actions.ts`.

- `GET /api/admin/roles` → `{ roles: RoleRow[], grants: RoleGrantRow[], catalog: { type: GrantType, keys: string[] }[] }`
  (catalog = known keys per type: units from config/units.json, tiers 0–2, perms list, plus keys already in use).
- `PUT /api/admin/roles/:discordRoleId/grants` body `{ grants: { grantType, grantKey, effect }[] }` → replaces that
  role's rows in one transaction, writes `fredpd_audit` (`action = 'perms.update'`), recomputes every online member
  holding the role and pushes to FXServer. Returns `{ ok: true, recomputed: n }`.
- Writes need the `x-csrf-token` header (value from `GET /api/session` → `{ user, csrfToken }`).

## C11. Ownership while modules are built in parallel

Do not edit `docs/contracts.md` from a module task; record module-level decisions in `docs/modules/<module>.md`.

## C12. Tablet actions (Phase 2) — `packages/types/src/mdt.ts`

- Flow: NUI `fetchNui(action, input)` → fredpd_mdt client `RegisterNUICallback(action)` → one server callback
  `lib.callback.await('fredpd:mdt:action', false, { action, input })` → fredpd_mdt server dispatcher:
  1. `local src = source`; the tablet must be open for `src` (`OpenTablets[src]`, set by `fredpd:mdt:open`), except `close`;
  2. unknown action → `{ error = 'validation' }`; input validated with the Lua mirror of the zod shape
     (`fredpd_mdt/shared/validate.lua`, table-driven, strings trimmed and length-capped, ints range-checked);
  3. grant from `MDT_ACTIONS[action].grant` via `exports.fredpd_core:hasGrant(src, type, key)` → `{ error = 'unauthorized' }`;
     on-duty required for every action except `close`;
  4. rate limit per src per action (search/getPerson/getVehicle/checkPlate 1 per 500 ms, writes 1 per 2 s) → `rate_limited`;
  5. route to the owning resource's export; return its data or `{ error = <MDT_ERROR_CODES> }`.
- Cross-resource export convention for actions: `exports.<res>:<fn>(src, input)` returns
  `{ ok = true, data = <output shape> }` or `{ ok = false, error = '<code>' }`. The dispatcher unwraps it.
- Owners: `fredpd_records` exports `search`, `getPersonSummary(src, { citizenid })`, `getVehicleSummary(src, { plate })`,
  `getHomeCases(src, { limit })` (case refs with canView applied; no case writes in Phase 2).
  `fredpd_bolo` exports `listBolos`, `createBolo`, `resolveBolo`, `plateCheck(src, { plate })` (records the check,
  fires `fredpd:boloHit`), plus the §4.3 lookups `checkPlate(plate) → bolo|nil`, `checkPerson(citizenid) → bolo|nil`
  and `getBolosFor(src, kind, id)` (canView-filtered, used by records for person/vehicle pages).
  `fredpd_mdt` owns `getHome` (composes records + bolo + core), `close`, `listTablets`, `setTabletRevoked`.
- Timestamps on the wire: ISO-8601 UTC strings. oxmysql converts DATETIME columns to epoch-ms using the FXServer
  host's local zone (wrong for UTC-stored values on a Stockholm host), so Lua reads select them as strings:
  `DATE_FORMAT(col, '%Y-%m-%dT%H:%i:%sZ') AS col` (helper `fredpd_core/shared/time.lua`: `M.isoSelect('col')` builds that
  fragment; `M.toIsoUtc(v)` normalises `YYYY-MM-DD HH:MM:SS` strings; `M.nowIso()`). All SQL writes use
  `UTC_TIMESTAMP()`, never `NOW()`/`CURRENT_TIMESTAMP`.
- Officers on the wire are `OfficerRef` from `fredpd_officers` (display name + callsign, §4.9).
- Perm keys used so far (service catalog must list them): `admin.permissions`, `records.admin`, `bolo.create`,
  `bolo.resolve`, `tablets.manage`, `intel.read`, `intel.handler`, `intel.command`, `rank:<key>`.
  `mdt_page` keys: `packages/types/src/mdtPages.ts` (`search, alerts, bolos, cases, evidence, intel, charges, roster, command`);
  `packages/ui` re-exports them and the service catalog lists them.
- Migrations added in Phase 2: `010_plate_checks.sql` (fredpd_bolo: `fredpd_plate_checks (id, plate, officer_citizenid,
  hit, bolo_id, created_at)`, index (plate, created_at)).
- Items live in `patches/ox_inventory.*.patch` (upstream is never edited): `pd_tablet` (`client.export =
  'fredpd_mdt.open'`, `stack = false`, metadata `serial`, `owner`).

## C13. Alerts (Phase 3) — `packages/types/src/dispatch.ts`

- **Event names (deviation from IMPLEMENTATION.md §5.5):** the ps-dispatch patch fires the *inbound* server event
  `fredpd:dispatch:incoming(data, playerSrc)` (its raw call data plus the `source` that reported it). fredpd_dispatch
  normalises, stores and then fires the *outbound* `fredpd:alertCreated(alert)` of §4.3 for other resources. Using one
  name for both directions would loop. The inbound handler uses `AddEventHandler` (not `RegisterNetEvent`), so clients
  cannot call it directly. ps-dispatch alerts are reported by clients, though, so the data is still untrusted:
  per-reporter rate limit (5 per 30 s), string caps, coords validation, priority clamped to 1–3.
- Exports (`{ ok, data | error }` for the src-taking ones, §C12): `createAlert(data)` (AlertCreateInput; used by
  fredpd_bolo hits with `source = 'bolo'` and a 60 s per-plate cooldown on the bolo side), `listAlerts(src, input)`,
  `assignSelf(src, { id })` (= takeAlert), `leaveAlert(src, { id })`, `closeAlert(src, { id })` (assigned officer or perm
  `alerts.manage`), `getUnits(src)`, `takeNewest(src)` (the keybind).
- Keybind "Ta larm" (`lib.addKeybind`, default `G`): client → `lib.callback.await('fredpd:dispatch:takeNewest')`; the
  server checks grant `mdt_page:alerts`, on duty, rate limit 1/s; it picks the newest `open` alert, assigns and returns
  the Alert (client sets `SetNewWaypoint(coords.x, coords.y)`). No tablet needs to be open.
- Toast: `TriggerClientEvent('fredpd:client:alertToast', src, AlertToast)` to every on-duty officer with
  `mdt_page:alerts`; client shows `lib.notify` (custom style + sound). No always-on NUI.
- Tablet: push topic `alerts` (AlertPush) and `units` (UnitsPush) only to open tablets
  (`exports.fredpd_mdt:pushToOpenTablets`). The mdt dispatcher merges `DISPATCH_ACTIONS` into its action table.
- Service: FXServer posts `/internal/events` with `DispatchInternalEvent`; `/ws` forwards to logged-in users whose
  grants include `mdt_page:alerts`.
- Status rules: `open` → `assigned` on the first take; `assigned` → `open` when the last unit leaves; `closed` is
  final. Every take/leave/close is audited (`alert.assign`, `alert.leave`, `alert.close`). Alert creation is not
  audited (high volume; the alert row itself is the record).
- Perm keys added: `alerts.manage`.

## C14. Cases, reports, charges (Phase 5) — `packages/types/src/records.ts`

- `RECORDS_ACTIONS` merge into the fredpd_mdt dispatcher (§C12 order and export convention). Fine-grained rules are
  enforced in fredpd_records: edit/assign/close = case owner, lead assignee or perm `records.admin`; reading follows
  canView (`none` → `not_found`, never `unauthorized`, so existence does not leak).
- Numbers: case `formatId(caseNumber, { seq, date })` where `seq` comes from `fredpd_sequences` (`seq_type = 'case'`,
  year in Europe/Stockholm) incremented in the same transaction as the insert; report `n` = next per case
  (`MAX(n)+1` under `SELECT … FOR UPDATE` on the case row); evidence tag the same per case.
- Level rules: a case/report level is never set above the actor's tier; lowering needs `records.admin`; closing keeps
  the level (sekretess after close stays, §8.7), but canView's closed-case rules then give `masked` Standard parts.
- Reports: markdown-lite rendered as text (no HTML passthrough, no links/images). Autosave writes only
  `fredpd_report_drafts`, debounced in the NUI (≥ 10 s after the last keystroke, only while focused and dirty).
- Charges: catalogue read-only in game (`fredpd_charges`, seeded); `applyCharges` copies title/class/fine/jail into
  `fredpd_records` rows (history stays stable if the catalogue changes). `issueFine` accepts only class `ordningsbot`
  and bills through the prison/billing adapter (qbx_police `police:server:BillPlayer` path verified in
  docs/deps-verification.md); jail goes through the prison adapter `jail(src, minutes, charges)`.
- Timeline = audit rows for the case (`target_type = 'case'`) plus its reports/evidence, newest first, max 100.
- Perm keys added: `cases.create`, `charges.apply`, `charges.fine`.

## C15. Intelligence (Phase 5b) — `packages/types/src/intel.ts`

- Record types for canView: `intel_source`, `intel_report`, `mission` (links inherit their report's/own level; entities
  carry no level — what is hidden are the links and reports around them).
- Real identity of a source: only for (handler with perm `intel.handler`) or perm `intel.command`; every such read
  audited `intel.source.identity`. Every read of a Hemlig (level 2) report audited `intel.report.read` (§5.8).
- Graph: built server-side, BFS from the root to `depth` (1 or 2), only links the viewer may see, capped at
  `GRAPH_NODE_CAP` (150) nodes with `truncated = true`; the NUI lazy-loads Cytoscape, runs `cose` once, then `stop()`.
- Portal: intel routes answer 404 (not 403) without `intel.read`, and for any record canView says `none`.
- Perm keys: `intel.read`, `intel.handler`, `intel.command` (already listed); mdt_page `intel`.

## C16. Evidence and breach (Phases 4 and 6) — `packages/types/src/evidence.ts`

- fredpd_forensics listens to `evidences:evidenceItemAnalysed(playerId, item)` (verify exact payload in
  docs/deps-verification.md), upserts `fredpd_evidence` by `item_uid`, appends custody entries on collect / hand-in
  (ox_inventory `swapItems` hook filtered to evidence stashes) / analyse / link. Linking assigns `tag` via
  `formatId(evidenceTag, { case, n })` in the same transaction; audited `evidence.link` + `fredpd:evidenceLinked`.
- Perm keys: `evidence.link`; mdt_page `evidence`.
- fredpd_breach: `tool:ram` grant, on duty, door locked (ox_doorlock) → progress → `ox_doorlock:setState(id, 0)`;
  audited `breach.door`. Export `sceneEvidence(kind: SceneKind, coords, suspectSrc)` for crime scripts (server-only;
  validates kind, coords and that `suspectSrc` is a connected player).

## C17. Framework bridge (QBCore first; ox or qb scripts chosen by config)

The target server runs **qb-core** with **qb-inventory, qb-target, qb-doorlock** today and may switch to the ox
scripts later. FredPD's own resources never call a framework, inventory, target or doorlock resource directly; they go
through `fredpd_core`'s bridge, selected in `config/integrations.json`:

```json
"framework": "qb-core",        // "qb-core" | "qbx_core"
"inventory": "qb-inventory",   // "qb-inventory" | "ox_inventory"
"target":    "qb-target",      // "qb-target" | "ox_target"
"doorlock":  "qb-doorlock"     // "qb-doorlock" | "ox_doorlock"
```

`"auto"` picks the first started resource of each pair (ox wins when both run). Switching = change the value and
restart; no code change, no DB change.

- **Layout:** `fredpd_core/bridge/<kind>/<impl>.lua` (server + client parts as needed), one interface per kind,
  loaded like the adapters (§9). Server exports on fredpd_core: `bridge(kind)` is internal; other resources use the
  exports below. Client side: a shared file other resources load with `'@fredpd_core/bridge/client.lua'`.
- **framework** (server): `getPlayer(src)` → `{ citizenid, license, name, job = { name, type, grade, onduty },
  charinfo }` or nil; client `getJob()` (UI hints only); `getPlayerByCitizenId(cid)` → src or nil; `getPlayers()` → srcs; normalised server events
  `fredpd:bridge:playerLoaded(src)`, `fredpd:bridge:playerUnloaded(src)`, `fredpd:bridge:jobChanged(src)`,
  `fredpd:bridge:dutyChanged(src, onduty)`. "Police" = `job.type == 'leo'` (both frameworks set it; qb-core's default
  police job has `type = 'leo'`). Money for fines: `removeMoney(src, 'bank', amount, reason)`, refunds `addMoney(src, 'bank', amount, reason)`.
  `bridgeInfo()` (server) / `clientBridgeInfo()` report the selected impl per kind and the `evidence` feature flag.
- **inventory** (server): `count(src, item)`, `find(src, item, metadataFilter)` → `{ slot, metadata }[]`,
  `add(src, item, count, metadata)`, `remove(src, item, count, slot?)`, `registerUsable(item, fn(src, slot, metadata))`
  (qb: `QBCore.Functions.CreateUseableItem`; ox: the item's `server.export`, both reach the same fn); capability flag
  `hooks` (ox `registerHook('swapItems')` only; qb-inventory has none). Item definitions ship for both:
  `patches/qb-core.*-fredpd-items.patch` (qb-core `shared/items.lua`) and `patches/ox_inventory.*.patch`.
- **target** (client): `addGlobalVehicle(opts)`, `addModel(models, opts)`, `addBoxZone(name, box, opts)`,
  `addEntity(netIds, opts)`, `remove(handle)`; options normalised to `{ name, label, icon, distance, canInteract,
  onSelect }`.
- **doorlock:** server `getDoor(id)` → `{ id, name, locked, coords }` or nil, `setLocked(id, locked, src?)`; client
  `listDoors()`; event `fredpd:bridge:doorChanged(id, locked)`. qb-doorlock ids are its door config keys.
- **Degradation:** features whose upstream needs the ox stack are disabled with ONE start-up warning, never an error:
  **evidences requires ox_inventory + ox_target** (its fxmanifest), so with qb-inventory `fredpd_forensics` stays
  idle and qb-policejob's built-in evidence stays ON (the police patch only disables it when fredpd_forensics is
  active). Chain-of-custody hand-in (ox hook) is ox-only.
- **Police job:** `patches/qb-policejob.*.patch` (grants, armory/garage filtering, stormram off, radar/impound BOLO
  hooks, Swedish locale) is the primary target; the `qbx_policejob` patches stay for Qbox servers.
  `fetch-deps` pins both stacks; `apply-patches` only patches resources that are fetched.
