# FredPD — Implementation Plan

Version 1, 2026-09-29. Companion to `FredPD-PLAN.md` (requirements, access model, estimates). This document is the one Claude Code agents execute from. Put it in the repo root as `IMPLEMENTATION.md` and reference it from `CLAUDE.md`.

Legend: **REUSE** = take code from the named source. **PATCH** = upstream kept unmodified, one small patch file applied by script. **BUILD** = new code. **VERIFY** = check before depending on it; the task that owns it is named.

---

## 0. Rules for agents

1. Read `CLAUDE.md`, this file, and the module spec you are working on before writing code. Do not read the whole plan every time.
2. Server is authoritative. Every net event and callback validates `source`, on-duty status and the grant it needs via `fredpd_core`. Client data is a hint, never a fact.
3. No `while true` / `Citizen.CreateThread` loops that run while idle. Event-driven or zone-driven only. The reviewer rejects any polling loop.
4. Every string a player sees comes from `locales/sv.json` / `locales/en.json` via `lib.locale()` (Lua) or `t()` (TS). No hardcoded UI text.
5. Every write to FredPD tables goes through `fredpd_core` server functions that also write `fredpd_audit`.
6. Definition of done for a task: code + the acceptance test in its task card passes + the reviewer agent (Opus, separate context) approves + `pnpm lint && pnpm test` green.
7. Borrowed code keeps its licence header. FredPD is **GPL-3.0** (forced by qbx_police, evidences and bub-mdt, all GPL-3.0). Never copy from `ps-mdt` (CC BY-NC-SA).
8. Upstream resources are never edited in place. Changes go in `patches/<resource>.patch` and are applied by `scripts/apply-patches.sh`.
9. Secrets (bot token, HMAC secret, DB password) live in `server.cfg` convars and `apps/service/.env`, both git-ignored. Never in Lua/TS source.
10. Swedish is the product language. Function and table names are English. UI labels, notifications, docs for players: Swedish.

---

## 1. Tech stack (decided)

| Layer | Choice | Why |
|---|---|---|
| Game framework | qbx_core (existing) | already chosen |
| Lua libs | ox_lib, oxmysql, ox_inventory, ox_target, ox_doorlock — **overextended/** repos | qbx_core README links overextended; CommunityOx org was archived 2026-04-28 (all 23 repos read-only). Pin commit hashes in `deps.lock.json`. VERIFY at task 0.3 that overextended repos have commits in 2026; if not, pin the last CommunityOx release and note it |
| Server code (game) | Lua (cfxlua) + one small JS file for HMAC/HTTP | Lua for everything ox-related; FiveM's server JS runtime has Node `crypto`, Lua has none |
| NUI (tablet) | React 19 + TypeScript + Vite, Tailwind v4, TanStack Query, TanStack Virtual, react-router (memory router) | Rami knows React; virtualised lists + query cache satisfy the speed budget; one bundle shared with the portal |
| Web portal + Discord bot + API | Node 22, Fastify 5, discord.js 14, drizzle-orm + mysql2, `@fastify/oauth2` (Discord) | one process (`fredpd_service`), same DB as the game; discord.js gateway is not run inside FXServer (fragile) |
| Shared UI | `packages/ui` (components, theme, `t()`), `packages/types` (zod schemas shared by Lua-facing JSON, NUI and portal) | one source of truth for shapes |
| DB | MariaDB (existing), utf8mb4, InnoDB | Swedish characters, JSON columns, FULLTEXT |
| Migrations | plain SQL files in `db/migrations/NNN_*.sql`, applied by `fredpd_core` on start via oxmysql, tracked in `fredpd_migrations` | no ORM migration tooling inside FiveM |
| Graph view | Cytoscape.js, lazy-loaded chunk | render-once, no animation loop, 150-node cap |
| Images (mugshots, evidence photos) | `screenshot-basic` → POST to `fredpd_service /upload` → stored on disk under `data/uploads`, served by the service | no third-party image host, no Discord webhooks as storage |
| PDF (POI sheet) | portal renders print CSS; "Ladda ner PDF" uses browser print / `playwright` in service for server-side PDF | one template, two outputs |
| Tooling | pnpm workspaces, TypeScript strict, ESLint, Vitest, Playwright (portal e2e), lua-language-server with ox_lib types, `.editorconfig` | agents can self-test everything except in-game |
| Host | Windows laptop: FXServer via txAdmin; MariaDB service; `fredpd_service` as a Windows service via NSSM; Caddy or Cloudflare Tunnel for HTTPS on the portal | matches existing hosting decision |

Not chosen: Svelte (ps-mdt uses it; no shared skill), Prisma (heavier than drizzle for MariaDB), Socket.io (Fastify + native WebSocket is enough for the portal's live alerts).

---

## 2. Repository layout

```
fredpd/                          (GitHub: Admin-Chatterly/fredpd, private, GPL-3.0)
├─ CLAUDE.md                     agent rules (short), links to IMPLEMENTATION.md
├─ IMPLEMENTATION.md             this file
├─ PLAN.md                       FredPD-PLAN.md
├─ deps.lock.json                upstream repo → pinned commit
├─ patches/                      *.patch for upstream resources
├─ scripts/
│  ├─ fetch-deps.sh              clones pinned upstreams into resources/[upstream]/
│  ├─ apply-patches.sh
│  ├─ build.sh                   builds NUI + portal, copies bundle into resources
│  └─ seed-dev.lua               fake persons/vehicles/cases for testing
├─ config/
│  ├─ formats.json                 identifier templates, regexes, date/currency (§4.8)
│  ├─ units.json                   unit codes, labels, order, home-page variant
│  └─ integrations.json            which housing/garage/prison/dispatch adapter is active (§9)
├─ db/
│  ├─ migrations/001_core.sql … 
│  └─ seed/charges_sv.sql        Swedish charge catalogue
├─ resources/
│  ├─ [fredpd]/
│  │  ├─ fredpd_core/            perms, DB, audit, locale, HTTP bridge
│  │  ├─ fredpd_mdt/             tablet item + NUI host (web/build from apps/nui)
│  │  ├─ fredpd_bolo/
│  │  ├─ fredpd_dispatch/
│  │  ├─ fredpd_breach/
│  │  ├─ fredpd_forensics/       adapter around evidences
│  │  ├─ fredpd_intel/           server logic only; UI lives in fredpd_mdt
│  │  ├─ fredpd_records/         cases, reports, POI, shares, release requests
│  │  └─ fredpd_devtools/        seed + fake units, never started in production
│  └─ [upstream]/                fetched, not committed: qbx_police, evidences, ps-dispatch, ox_*
├─ apps/
│  ├─ nui/                       React tablet UI (Vite, single-file build)
│  ├─ portal/                    React web portal (Vite SPA)
│  └─ service/                   Fastify + discord.js + API + uploads
├─ packages/
│  ├─ ui/                        shared components + theme + i18n
│  └─ types/                     zod schemas, TS types, locale keys
└─ locales/                      sv.json, en.json (source of truth; copied into each resource at build)
```

---

## 3. Dependencies and where code comes from

| Component | Source | Licence | Mode | What we take / do |
|---|---|---|---|---|
| Police job | `https://github.com/Qbox-project/qbx_police` (resource name `qbx_policejob`) | GPL-3.0 (verified) | PATCH | Keep duty, armory, garage, stash, impound, jail, cuffs, escort, radar, spikestrips. Patch: replace `IsLeoAndOnDuty(player, minGrade)` body with a call to `exports.fredpd_core:hasGrant(src, grant)`; disable its `evidence:server:*` events (replaced by evidences); disable stormram (replaced by fredpd_breach); expose `police:server:FlaggedPlateTriggered` to fredpd_bolo |
| Evidence | `https://github.com/noobsystems/evidences` | GPL-3.0 (verified) | REUSE unmodified | Server exports `getFingerprint(playerId)`, `getDNA(playerId)`, `syncEvidence(type, owner, fn, ...)` with `atCoords`, `atEntity`, `atVehicleDoor`, `atPlayer`; server event `evidences:evidenceItemAnalysed(playerId, item)`. Also its ox_target fork for vehicle doors (VERIFY needed, task 4.2) |
| Alerts | `https://github.com/Project-Sloth/ps-dispatch` | GPL-3.0 | PATCH | Supports Qbox (verified). Use its 35+ preset exports as the alert *generator*. Patch: one `TriggerEvent('fredpd:alertCreated', data)` where it stores a new call; turn off its own NUI/HUD (VERIFY config flag exists, else patch out `SendNUIMessage`). Dependency `lsn-radar` is only needed for its radar feature; VERIFY it can be omitted |
| MDT patterns | `https://github.com/BubbleDK/bub-mdt` | GPL-3.0 | REUSE selectively | Copy: NUI↔Lua callback layout (`web/src/utils/fetchNui.ts`, `debugData`), dispatch unit tracking in `server/`, SQL for reports/incidents as starting point. Do not copy its licence-points code (broken, and Sweden has no points) |
| Doors | `https://github.com/overextended/ox_doorlock` | see LICENSE at pin | REUSE unmodified | Server: `exports.ox_doorlock:getDoor(id)`, `TriggerEvent('ox_doorlock:setState', id, state)`; listen `ox_doorlock:stateChanged` |
| Inventory | `https://github.com/overextended/ox_inventory` | GPL-3.0 (VERIFY) | REUSE | Items: `pd_tablet` (client export opens MDT), `pd_ram`, evidence items from evidences. Metadata on tablet: `serial`, `owner` |
| Lib / target / mysql | `https://github.com/overextended/ox_lib` (LGPL-3.0), `ox_target`, `oxmysql` | LGPL/… | REUSE | callbacks, locale, zones, progress, context menus |
| Prison | `Qbox-project/qbx_prison` (VERIFY exists and is maintained, task 0.3) | GPL-3.0 (VERIFY) | REUSE via adapter | default; else qbx_police built-in jail adapter |
| Housing | `Project-Sloth/ps-housing` (assumed; VERIFY installed + lock API, task 6.2) | see LICENSE | REUSE via adapter, no code copied | property → door unlock for breach; address for person page |
| Discord role pattern | `JaredScar/Badger_Discord_API`, `ReckerXF/DiscordSync` | | reference only | shows role-ID→ACE mapping; we do it in the service with live gateway events instead |
| Screenshot | `https://github.com/citizenfx/screenshot-basic` | MIT | REUSE | `exports['screenshot-basic']:requestScreenshotUpload(url, field, cb)` |
| Charge catalogue | own data (`db/seed/charges_sv.sql`) | — | BUILD | Brottsbalken + trafik + narkotika + vapen, with fine/time for the game |
| ps-mdt | `Project-Sloth/ps-mdt` | CC BY-NC-SA 4.0 | **ideas only** | feature list, nothing else |

`scripts/fetch-deps.sh` clones each REUSE/PATCH repo at the commit in `deps.lock.json` into `resources/[upstream]/`, then `apply-patches.sh` applies `patches/*.patch`. Updating an upstream = bump hash, re-run, fix patch if it fails.

---

## 4. Cross-cutting design

### 4.1 Permission engine (`fredpd_core`)

Data:
```sql
fredpd_roles        (discord_role_id PK, name, colour, position, deleted TINYINT)
fredpd_role_grants  (id, discord_role_id, grant_type ENUM('weapon','vehicle','armory','tool','mdt_page','intel_tier','unit','perm'), grant_key VARCHAR(64), effect ENUM('allow','deny'))
fredpd_identities   (discord_id PK, license, last_citizenid, last_seen)
fredpd_grant_cache  (discord_id PK, grants JSON, computed_at)   -- fallback if service is down
```

Resolution (in the service, `packages/types/src/grants.ts`, also ported to Lua for the fallback path):
```
allow = union of allow rows over the member's roles
deny  = union of deny rows
grants = allow − deny
tier   = max(intel_tier grants)        -- 0 standard, 1 begränsad, 2 hemlig
units  = set(unit grants)              -- igv, span, utredning, tekniker, ledning
```

Runtime on FXServer:
- `playerJoining` → read discord identifier → `GET /internal/grants/:discordId` from service (signed) → store in `Grants[src]` (server-only Lua table) and `fredpd_grant_cache`. If service unreachable → use `fredpd_grant_cache` row, log a warning.
- Exports: `hasGrant(src, type, key) → bool`, `getGrants(src) → table`, `getTier(src)`, `getUnits(src)`, `canView(src, record) → 'full'|'masked'|'notice'|'none'` (see PLAN §5d).
- Client copy of grants (for building menus only) delivered by `lib.callback('fredpd:getMyGrants')` on tablet open and pushed by `fredpd:client:grantsChanged` when the service posts an update.
- Service → FXServer push: `POST http://127.0.0.1:30120/fredpd_core/grants` with body `{discordId, grants}`; FXServer handler in `server/http.js` verifies HMAC and calls back into Lua via `exports.fredpd_core:applyGrants(discordId, grants)`.

HMAC contract (both directions):
```
headers: X-FredPD-Ts: <unix seconds>, X-FredPD-Sig: hex(hmac_sha256(SECRET, ts + "." + rawBody))
reject if |now − ts| > 60 s or sig mismatch. SECRET from convar fredpd_hmac_secret / env FREDPD_HMAC_SECRET.
```

### 4.2 Search mirror tables (speed)

`players.charinfo` is JSON and cannot be indexed. Maintain:
```sql
fredpd_persons (citizenid PK, firstname, lastname, birthdate, gender, phone, license, updated_at,
                FULLTEXT ft_name (firstname, lastname), INDEX (lastname, firstname))
fredpd_vehicles_idx (plate PK, citizenid, model, INDEX (citizenid))
```
Filled by: one-time backfill command `/fredpd_backfill` (devtools) + handlers on `qbx_core` player loaded / character updated events (VERIFY exact event names, task 1.4) + `player_vehicles` insert/delete hooks (VERIFY qbx_vehicles events; else nightly-free approach: refresh a plate on first lookup miss).

### 4.3 Events and exports contract (all resources)

Server exports:
```
fredpd_core:    hasGrant, getGrants, getTier, getUnits, canView, audit(src, action, targetType, targetId, meta), applyGrants
fredpd_records: createCase, addAssignee, closeCase, createReport, addCharge, getPersonSummary(citizenid, viewerSrc)
fredpd_bolo:    createBolo, resolveBolo, checkPlate(plate) → bolo|nil, checkPerson(citizenid)
fredpd_dispatch:createAlert(data), assignSelf(src, alertId), closeAlert
fredpd_intel:   addSource, addReport, addLink, getGraph(entityId, viewerSrc)
```
Server events (fired for other resources):
```
fredpd:alertCreated(alert)        fredpd:alertAssigned(alertId, src)
fredpd:boloHit(bolo, context)     fredpd:caseUpdated(caseId)
fredpd:evidenceLinked(caseId, evidenceId)
```
Client events (server → tablet): `fredpd:client:push(topic, payload)` with topics `alerts`, `units`, `bolo`, `case`. Only sent to players whose tablet is open (`OpenTablets[src] = true`).

NUI ↔ Lua: `fetchNui('<action>', data)` → `RegisterNUICallback` → `lib.callback.await('fredpd:<action>')` server → return. One generic dispatcher per module, actions listed in `packages/types/src/actions.ts` (zod-validated on both ends).

### 4.4 Locale

`locales/sv.json` and `en.json` at repo root are the source. Build copies them into each resource's `locales/` and into the NUI/portal bundles. Keys are namespaced `mdt.search.placeholder`, `bolo.create.title` … `packages/types` exports the key union so TS catches typos. `setr ox:locale sv` in server.cfg.

### 4.5 Audit

`fredpd_audit (id, actor_citizenid, actor_discord, action, target_type, target_id, meta JSON, created_at, INDEX (target_type, target_id), INDEX (actor_citizenid, created_at))`. Written by `fredpd_core.audit()`. Lookups of persons/vehicles are audited too (basis for the "obehörig sökning" flag). Retention: keep 90 days in the table, older rows moved to `fredpd_audit_archive` by a monthly command, not a timer.

### 4.6 Security checklist (reviewer uses this)

- Every `RegisterNetEvent` handler: `local src = source`, then `hasGrant`, then rate-limit (`lib` cooldown per src per action, e.g. lookups 1/s).
- Never accept `citizenid` for the *actor* from the client. Actor = `exports.qbx_core:GetPlayer(src).PlayerData.citizenid`.
- Tablet open requires item in inventory (`exports.ox_inventory:GetItemCount(src, 'pd_tablet') > 0`) and serial not revoked.
- Service: Discord OAuth, session cookie `httpOnly; secure; sameSite=lax`, CSRF token on writes, rate limit 60 req/min per user, uploads max 5 MB + MIME sniff.
- Portal exposes only what `canView` allows; the same function is ported to TS (`packages/types/src/canView.ts`) and unit-tested with the same fixtures as the Lua version.
- Shares: token = 32 random bytes base64url, expiry mandatory, every view logged.

### 4.7 Performance rules (from PLAN §12 and §5b) — enforced

- NUI page: `visibility:hidden` root when closed; no `setInterval`; TanStack Query `staleTime` 30 s, refetch only on open/focus.
- Server pushes only to open tablets. Lists paginated 50, server-side filtering, indexed columns only.
- ox_target options are added once at resource start; zone-based options for station interiors via `lib.zones`.
- Tablet prop: attach on open, detach on close/resource stop; anim via `lib.requestAnimDict` then release.
- Graph: build node/edge arrays server-side, capped 150; Cytoscape `layout: 'cose'` run once, then `stop()`.

### 4.8 Formats config (one file, used by Lua, NUI, portal, service)

`config/formats.json` at repo root; build copies it into `fredpd_core/config/` and bundles it into `packages/types`. Template placeholders: `{{seq}}` (DB sequence per type per year), `{{n}}` / `{{n:3}}` (zero-padded per-parent counter), `{{yy}}` / `{{yyyy}}`, `{{unit}}` (unit code), `{{case}}`. One formatter, `packages/types/src/format.ts`, and its Lua port `fredpd_core/shared/format.lua`, tested against the same `format.fixtures.json`. Regex fields are compiled once at start. Changing a format needs a resource restart, not a rebuild; existing identifiers are never rewritten.

### 4.9 Officer identity from Discord

- Source of truth for an officer's displayed name is Discord, not the character. On join and on `guildMemberUpdate` (nickname/avatar change) the bot upserts `fredpd_officers (citizenid PK, discord_id, display_name, avatar_url, callsign, unit, rank_role_id, updated_at)`. Resolution order (config `officerNameSource`): server nickname → global display name → username.
- Where it shows: roster, alert assignment ("Tilldelad: IGV-07 · Anna B."), report author line, audit log, case assignees, portal header, POI sheet "Handläggare".
- Where the character name still shows: anywhere the *person* is a subject (a cop looked up as a civilian shows the character record).
- Callsign is generated from the format template on first duty (`{{unit}}-{{n:2}}` picks the lowest free number in that unit) and editable by Ledning. Unit comes from the `unit` grant; if a member has several units, the first in `config/units.json` order is the primary.
- Rank shown = the member's highest role that is mapped to `grant_type = 'perm', grant_key = 'rank:*'` (so ranks are also just Discord roles). Avatar is cached locally by the service (`/avatar/:discordId`) so the tablet never calls Discord.
- Offline fallback: if the service is down, the last stored `display_name` is used; never the character name for an officer unless config says so.

---

## 5. Module specs

Each module: purpose · source · data · server · client/UI · acceptance tests.

### 5.1 fredpd_core (BUILD, JS+Lua)

- `server/http.js`: HMAC verify, `SetHttpHandler` route `/grants`, `/recompute`, `/ping`; outbound `signedFetch(path, body)` used by Lua via export.
- `server/perms.lua`: grant cache, exports, `playerJoining`/`playerDropped`.
- `server/canview.lua`: implements PLAN §5d rules; rules table loaded from `fredpd_visibility_rules` at start and on `fredpd:rulesChanged`.
- `server/db.lua`: migrations runner; thin query helpers.
- `server/audit.lua`.
- `shared/locale.lua`: `lib.locale()` init.
- Acceptance: unit fixtures in `packages/types/test/canView.test.ts` mirrored by `fredpd_devtools` command `/fredpd_selftest` that runs the same 20 fixtures in Lua and prints pass/fail. Service down → player still gets cached grants (test by stopping service).

### 5.2 fredpd_mdt (BUILD; NUI patterns from bub-mdt)

- Item `pd_tablet` (`ox_inventory/data/items.lua`): `client.export = 'fredpd_mdt.open'`, `stack=false`, metadata `serial`, `owner`.
- `client/main.lua`: `open()` → server callback `fredpd:mdt:open` (checks item, revoked, duty, grants) → prop `prop_cs_tablet` on bone 28422, anim dict `amb@code_human_in_bus_passenger_idles@female@tablet@base` clip `base` (VERIFY plays standing; task 2.1) → `SetNuiFocus(true,true)` → `SendNUIMessage({action='open', grants, unit, me})`. `close()` reverses. Keybind `Esc` handled in NUI → `fetchNui('close')`.
- Vehicle terminal: ox_target option on police vehicle models (config list) → same `open()` without prop.
- Revocation: `fredpd_tablets (serial PK, owner_citizenid, revoked, issued_by, issued_at)`; Ledning page "Surfplattor".
- NUI routes (`apps/nui`): `/` Hem (unit-tailored), `/sok` results, `/person/:cid`, `/fordon/:plate`, `/efterlysning`, `/larm`, `/arenden`, `/arende/:id`, `/rapport/:id`, `/bevis`, `/intel/*`, `/brottskatalog`, `/register` (roster), `/ledning/*`.
- Search box: detect type with the regexes from `formats.json` (`plate`, `caseNumber` derived from its template, `personId`), else FULLTEXT name. Enter opens top hit.
- Acceptance: open→first paint < 300 ms on the host (measure with `performance.now()` logged to console in dev build); resmon idle 0.00, open ≤ 0.05 ms; Esc always closes and releases focus; using the item without grant shows a Swedish notification and opens nothing.

### 5.3 fredpd_records (BUILD; SQL shapes from bub-mdt)

- Tables: `fredpd_cases`, `fredpd_case_assignees`, `fredpd_case_subjects (case_id, subject_type person|vehicle, subject_id)`, `fredpd_reports`, `fredpd_records` (charges applied), `fredpd_charges` (catalogue), `fredpd_poi`, `fredpd_shares`, `fredpd_release_requests`, `fredpd_visibility_rules`.
- Case, report and evidence numbers from `formats.json` templates via the shared formatter (§4.8).
- `getPersonSummary(citizenid, viewerSrc)`: joins persons, vehicles_idx, records, active BOLO, case subjects; applies `canView` per case → full / kontaktnotis / hidden.
- Reports: markdown body (rich text is not needed; keep a small toolbar: bold, list, heading), templates in `fredpd_report_templates`, autosave draft every 10 s **only while the editor is focused and dirty** (debounced input, not a timer), stored in `fredpd_report_drafts`.
- Charges picker: type-ahead on `fredpd_charges (code, title_sv, law_ref, fine, jail_min, class)`, sums fine and time; "Utfärda ordningsbot" writes a record and bills via qbx_police `police:server:BillPlayer`.
- POI sheet: single React component `PoiSheet` used by NUI and portal; export via portal print CSS; share via `fredpd_shares`.
- Release requests: portal form + station ox_target "Begär ut allmän handling"; officer decision UI; masking = apply `canView` with viewer tier 0 and strip source fields.
- Acceptance: create case → assign → IGV without assignment sees kontaktnotis only → close case → IGV sees Standard parts; release request with masking yields no Begränsad text (assert on rendered HTML in Playwright).

### 5.4 fredpd_bolo (BUILD)

- Table `fredpd_bolos (id, kind person|vehicle, citizenid, plate, reason, level, issued_by, created_at, expires_at, active, resolved_by, resolved_at)`. In-memory maps `activeByPlate`, `activeByCitizen` rebuilt on start and on change.
- Hit sources:
  1. ox_target "Kontrollera registreringsskylt" on any vehicle (bone `platelight`/whole vehicle) → `fredpd:bolo:checkPlate` → result popup (ox_lib context/alert) + `fredpd:boloHit`.
  2. qbx_police radar: bridge `police:server:FlaggedPlateTriggered` → check active BOLO (VERIFY how qbx_police builds its flagged list; feed it from `activeByPlate`, task 3.3).
  3. Garage: PATCH qbx_garages `parkVehicle` callback and the take-out path to `TriggerEvent('qbx_garages:server:vehicleParked'|'vehicleTakenOut', citizenid, plate, garage)` (task 3.4; first check qbx_vehicles for an existing state-change event).
  4. Impound with active BOLO → auto-resolve with note.
- Hit fan-out: alert to on-duty units via `fredpd_dispatch.createAlert` with cooldown 60 s per plate.
- Acceptance: create vehicle BOLO → target the car → popup within 200 ms → alert appears on other officer's tablet; park in public garage → alert; expired BOLO never hits.

### 5.5 fredpd_dispatch (BUILD + ps-dispatch PATCH)

- ps-dispatch generates calls; patched event `fredpd:alertCreated` mirrors into `fredpd_alerts (id, code, title, coords, street, priority, source, created_at, status open|assigned|closed)` and `fredpd_alert_units`.
- No always-on React HUD (would cost NUI time while the tablet is closed). The alert toast is `lib.notify` with a custom style and a sound; the full list lives in the tablet. One keybind `Ta larm` (default `G`, `lib.addKeybind`) assigns you to the newest open alert and sets `SetNewWaypoint`.
- Unit status: on duty list from qbx_police duty event; callsign, unit and Discord display name from `fredpd_officers` (§4.9).
- Portal: live alert list via WebSocket from the service, which receives `fredpd:alertCreated` through the signed push (`POST /internal/events`).
- Acceptance: `exports['ps-dispatch']:Shooting()` from devtools → toast on all on-duty within 100 ms → press G → assigned, waypoint set, others see "Tilldelad: <callsign>"; closing removes from list on all open tablets.

### 5.6 fredpd_breach (BUILD)

- Item `pd_ram`. Prop: GTA has no battering-ram model; task 6.1 VERIFIES whether a free (CC0/GPL-compatible) ram model exists; until then use `prop_tool_shovel` as a placeholder and keep the model name in config so Rami can swap it.
- ox_target on door entities registered in ox_doorlock (`exports.ox_doorlock:getDoorFromName` not needed; client has door list from ox_doorlock statebag/`ox_doorlock:getDoors` VERIFY) → "Forcera dörr" option visible only with grant `tool:ram`.
- Server: check grant + on duty + door locked → `lib.progressBar` 4 s with anim `missheistfbi3b_ig7` (VERIFY) → `TriggerEvent('ox_doorlock:setState', id, 0)` → audit → optional evidence spawn.
- Scene evidence generation table `config/scene_evidence.lua`: `{ burglary = { {type='fingerprint', at='door', chance=80}, {type='toolmark', at='door', chance=100} }, shooting = { casings from evidences automatically } , assault = { {type='blood', chance=60} } }` executed via `exports.evidences:syncEvidence(type, ownerId, 'atCoords', coords, meta)`. Which crime happened is passed by the script that triggers it (robbery/heist scripts call `exports.fredpd_breach:sceneEvidence('burglary', coords, suspectSrc)`).
- Housing adapter: `adapters/housing/ps-housing.lua` (default, §9) maps property → unlock call; `ox_doorlock-only` adapter for scripts whose doors are already ox_doorlock doors (task 6.2).
- Acceptance: locked ox_doorlock door + ram + grant → door unlocks, audit row; without grant option not shown; evidence spawn for `burglary` produces a collectable fingerprint at the door.

### 5.7 fredpd_forensics (BUILD thin adapter over evidences)

- Listens `evidences:evidenceItemAnalysed(playerId, item)` → offers "Koppla till ärende" (ox_lib input) → `fredpd_evidence (id, case_id, item_uid, type, result JSON, collected_by, collected_at, chain JSON)`.
- Chain of custody appended on: collect (from evidences metadata), hand-in to locker (ox_inventory server hook `exports.ox_inventory:registerHook('swapItems', …)` filtered to the evidence stash — VERIFY signature in task 4.2), analysis, link.
- Station lab zone (`lib.zones.box`) with ox_target "Analysera" → uses evidences laptop flow; nothing new.
- Acceptance: collect fingerprint → analyse → link to case → case page shows evidence row with 4 chain entries.

### 5.8 fredpd_intel (BUILD)

- Tables: `fredpd_intel_sources (id, codename, handler_citizenid, reliability ENUM('A','B','C','D'), status, notes, real_citizenid NULL, level)`, `fredpd_intel_reports (id, source_id, author, body, reliability, level, created_at)`, `fredpd_intel_entities (id, type person|vehicle|location|group|case, ref, label)`, `fredpd_intel_links (id, from_id, to_id, type, confidence TINYINT, report_id, created_by, level)`, `fredpd_missions (id, title, unit, status, level, lead)`, `fredpd_mission_members`.
- `getGraph(entityId, depth=1, viewer)` → filtered by `canView`, capped 150 nodes; expand per node.
- Real identity of a source is returned only if `hasGrant(viewer,'perm','intel.handler')` and viewer is the handler, or `intel.command`.
- UI: list-first entity page; graph tab lazy-loads Cytoscape chunk.
- Acceptance: Span user creates mission Hemlig; IGV searching a subject sees kontaktnotis only; Utredning assigned sees full; audit rows exist for each read of a Hemlig report.

### 5.9 fredpd_service (BUILD, Node)

- Routes: `/auth/discord`, `/api/*` (same actions as NUI, same zod schemas), `/internal/*` (HMAC, from FXServer), `/upload`, `/share/:token`, `/ws` (alerts, units).
- Discord bot: on ready → fetch roles → upsert `fredpd_roles`; `guildRoleCreate/Update/Delete`, `guildMemberUpdate` → recompute grants **and** refresh `display_name`/`avatar_url` for that member → signed push to FXServer if online. Needs `GuildMembers` intent; roles and names come from the same member object, so this is one event handler.
- Admin UI "Behörigheter": role × grant matrix; save → recompute all online.
- Character selection on login: `fredpd_identities` gives characters for the Discord user; pick one; officer identity = that citizenid.
- Acceptance: change a Discord role → within 2 s the in-game armory menu changes (measure); portal user without `intel.read` gets 404 (not 403) on intel routes; upload of a 6 MB file rejected.

### 5.10 fredpd_devtools (BUILD, dev only)

Commands: `/fredpd_seed 200` (persons, vehicles, cases), `/fredpd_fakeunits 20` (server-side fake on-duty entries + alerts every 5 s **only while the command runs, ends after N seconds**), `/fredpd_selftest`, `/fredpd_backfill`. Never `ensure`d in production `server.cfg`.

---

## 6. Database migration list

```
001_core.sql        fredpd_migrations, fredpd_roles, fredpd_role_grants, fredpd_identities, fredpd_grant_cache, fredpd_audit, fredpd_units, fredpd_officers, fredpd_visibility_rules
002_index.sql       fredpd_persons, fredpd_vehicles_idx (+ INDEX on player_vehicles.plate if missing)
003_records.sql     fredpd_cases, fredpd_case_assignees, fredpd_case_subjects, fredpd_reports, fredpd_report_drafts, fredpd_report_templates, fredpd_charges, fredpd_records, fredpd_poi, fredpd_shares, fredpd_release_requests
004_bolo.sql        fredpd_bolos
005_dispatch.sql    fredpd_alerts, fredpd_alert_units
006_evidence.sql    fredpd_evidence
007_intel.sql       fredpd_intel_sources, fredpd_intel_reports, fredpd_intel_entities, fredpd_intel_links, fredpd_missions, fredpd_mission_members
008_tablets.sql     fredpd_tablets
seed/charges_sv.sql
seed/visibility_rules_default.sql
```
All tables: `ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_swedish_ci`, `created_at DATETIME DEFAULT CURRENT_TIMESTAMP`. Times stored UTC, displayed Europe/Stockholm.

---

## 7. Execution plan — tasks for agents

Format: **id · model · what · inputs → outputs · acceptance**. Agent-hour estimates from PLAN §13 apply per phase. Run tasks in a phase in order unless marked ∥ (parallel-safe). After each phase: Rami in-game test, then reviewer sign-off.

### Phase 0 — Bootstrap (Opus 1 h, Sonnet 2 h)
- 0.1 · Sonnet · monorepo skeleton (pnpm, TS, Vite apps, packages, ESLint, Vitest, Playwright, .luarc, CLAUDE.md) → `pnpm -r build` passes.
- 0.2 · Sonnet · `deps.lock.json`, `fetch-deps.sh`, `apply-patches.sh` (git apply --check first) → running them yields `resources/[upstream]/*`.
- 0.3 · Opus · VERIFY upstream health: overextended ox_lib/ox_inventory/ox_target/ox_doorlock/oxmysql last commit dates; qbx_prison existence; evidences ox_target fork necessity; ps-dispatch NUI disable flag and lsn-radar optionality; qbx_vehicles state events. Output `docs/deps-verification.md` with decisions written into `deps.lock.json`.
- 0.4 · Sonnet · `locales/sv.json`, `en.json` with the glossary from PLAN §10 + key namespaces; `packages/types` locale key union.
- 0.5 · Sonnet · `config/formats.json`, `config/units.json`, `config/integrations.json` with the §9 defaults; formatter in TS + Lua with shared fixtures → 15 fixtures pass in both.
- 0.6 · Sonnet · adapter interfaces + no-op stubs for housing/garage/prison; `ps-housing`, `qbx_garages`, `qbx_prison` adapters filled in their phases (6.2, 3.4, 4.1).

### Phase 1 — Foundation (Opus-heavy)
- 1.1 · Opus · `db/migrations/001–002`, migration runner in `fredpd_core/server/db.lua` → fresh DB migrates idempotently twice.
- 1.2 · Opus · `fredpd_core/server/http.js` HMAC + `SetHttpHandler`; `signedFetch` export → test with `curl` signed by a Node one-liner; bad ts/sig → 401.
- 1.3 · Opus · grant resolution in `packages/types/src/grants.ts` + Lua port; `perms.lua` with cache and fallback → Vitest fixtures; `/fredpd_selftest` prints 20/20.
- 1.4 · Sonnet · persons/vehicles mirror (backfill + event handlers; VERIFY event names in qbx_core source) → 200 seeded persons searchable by FULLTEXT in < 20 ms (EXPLAIN + timing).
- 1.5 · Opus · `canview.lua` + `canView.ts` from PLAN §5d, rules table + defaults seed → shared fixtures pass in both.
- 1.6 · Sonnet · `apps/service` skeleton: Fastify, drizzle schema generated from migrations, Discord OAuth, session, `/internal/ping` signed → e2e login test with a mocked Discord.
- 1.7 · Opus · discord.js bot: role import, member update → recompute → push → change a role in a test guild, `Grants[src]` updates in game (Rami test), `fredpd_grant_cache` row written.
- 1.7b · Sonnet · officer identity sync (§4.9): `fredpd_officers` upsert on join and on nickname change, avatar cache route, callsign generator using `formats.json` → rename yourself in Discord, roster shows the new name within 2 s; first duty assigns `IGV-01`.
- 1.8 · Sonnet · portal admin page "Behörigheter" (matrix) → save triggers recompute; audit row.
- Reviewer gate: security checklist §4.6 on everything above.

### Phase 2 — Tablet + MDT MVP
- 2.1 · Sonnet · `fredpd_mdt` item, prop/anim, open/close, NUI host, vehicle terminal target; `fredpd_tablets` + revoke → acceptance in §5.2.
- 2.2 ∥ · Sonnet · `apps/nui` shell: memory router, theme (dark, flat, one accent, 15 px), layout with ≤ 6 nav items filtered by grants, `fetchNui` + `debugData` mock mode (from bub-mdt) → runs in browser with mock data.
- 2.3 · Sonnet · Search box with type detection + results page (virtualised) → Enter opens top hit; keyboard nav.
- 2.4 · Sonnet · Person page (`getPersonSummary`) with actions row (Efterlys, Lägg i ärende, Ny rapport, POI-blad), kontaktnotis rendering → masked cases render notice only.
- 2.5 · Sonnet · Vehicle page (owner, BOLO flag, linked cases, "Kontrollera" history).
- 2.6 · Opus · `fredpd_bolo` server + create/resolve UI + ox_target plate check → §5.4 acceptance items 1 and 4.
- 2.7 · Sonnet · Unit-tailored Hem page (IGV/Span/Utredning/Tekniker/Ledning variants; data from one callback).
- Rami test: open speed, resmon, feel. Adjust theme before phase 3.

### Phase 3 — Alerts
- 3.1 · Opus · ps-dispatch patch (`fredpd:alertCreated`, NUI off) + `fredpd_dispatch` tables/server → devtools `Shooting()` creates row.
- 3.2 · Sonnet · toast via `lib.notify` custom style + sound, keybind "Ta larm", waypoint, tablet Larm page with live push → §5.5 acceptance.
- 3.3 · Opus · radar/ANPR bridge (`police:server:FlaggedPlateTriggered` ← `activeByPlate`).
- 3.4 · Opus · garage hook (qbx_vehicles event or qbx_garages patch) → park with BOLO → alert.
- 3.5 · Sonnet · portal live alerts/units via `/ws`.

### Phase 4 — Police job + evidence
- 4.1 · Opus · qbx_police patch: `IsLeoAndOnDuty` → grants; disable built-in evidence + stormram; jail decision (qbx_prison or built-in); armory and garage lists generated from grants → armory shows only granted weapons; server rejects ungranted buy.
- 4.2 · Sonnet · install evidences, items, images, `sv.json` for it (upstream PR-able), lab zone + targets; `fredpd_forensics` adapter → §5.7 acceptance.
- 4.3 · Sonnet · all qbx_police player-facing strings → Swedish (its locale file).

### Phase 5 — Records
- 5.1 · Opus · `003_records.sql`, case/report/charge server API, case numbering, assignments, close flow.
- 5.2 · Sonnet · Ärenden list + case page (subjects, assignees, reports, evidence, timeline).
- 5.3 · Sonnet · Report editor (markdown-lite, templates, debounced autosave), charge picker with sums, ordningsbot.
- 5.4 · Sonnet · Brottskatalog page + `charges_sv.sql` (≈120 rows; Rami reviews values).
- 5.5 · Sonnet · POI sheet component + portal print/PDF + shares (`/share/:token`).
- 5.6 · Opus · release requests (Begär ut allmän handling) + masking + obehörig-sökning flag (config threshold, default 3) → §5.3 acceptance.

### Phase 5b — Intel
- 5b.1 · Opus · `007_intel.sql`, server API, `getGraph`, identity gating.
- 5b.2 · Sonnet · Intel pages: sources (handler view), reports, entity page list-first, add-link flow (3 clicks), missions.
- 5b.3 · Sonnet · Graph tab (Cytoscape lazy chunk, render-once, expand per node).

### Phase 6 — Breach
- 6.1 · Opus · `fredpd_breach` item/target/server/`ox_doorlock:setState`, scene evidence table + export → §5.6 acceptance.
- 6.2 · Sonnet · `ps-housing` adapter: VERIFY its lock export/event (read `ps-housing/server` for the property lock state and the door/zone it uses); map property → unlock; if ps-housing is absent on the server the adapter is a no-op.

### Phase 7 — Portal completion
- 7.1 · Sonnet · portal pages reuse NUI routes via `packages/ui`; character picker; Ledning pages (roster, tablets, release queue, audit view).
- 7.2 · Opus · hardening: rate limits, CSRF, headers, upload checks; `docs/hosting.md` with Cloudflare Tunnel as the default (`cloudflared` as a Windows service, tunnel → `localhost:3000`), Caddy as the alternative; NSSM install script for `fredpd_service`.

### Phase 8 — Polish
- 8.1 · Sonnet · `/fredpd_fakeunits 20` load test; record resmon and query timings in `docs/perf.md`.
- 8.2 · Sonnet · Swedish string pass against glossary; hand list of all strings to native reader; apply fixes.
- 8.3 · Opus · final security review + licence headers + `README.md` install guide (txAdmin recipe steps).

---

## 8. Keep in mind

1. **Licence.** GPL-3.0 for the whole thing. Fine for running a server; if FredPD is ever sold or given to another server, source must go with it. No ps-mdt code, ever.
2. **Upstream drift.** overextended repos are the linked upstream, but activity must be checked (task 0.3). Pin hashes; never "latest".
3. **NUI focus traps.** Every open path must have a matching close on: Esc, resource stop, player death, vehicle exit if using the vehicle terminal (`lib.onCache('vehicle')`).
4. **OneSync.** Prop attach and door natives must work with OneSync Infinity (entities may be out of scope). Use `NetworkGetEntityFromNetworkId` and `DoorSystem` via ox_doorlock only.
5. **Identity.** Discord ID is the permission key; citizenid is the record key. A player with two characters is one Discord user; grants follow the user, records follow the character.
6. **Charinfo JSON.** Never query `players.charinfo` in a search path; use the mirror tables.
7. **Swedish specifics.** No licence points (use varning/återkallelse). Plate format ABC 12D. Personnummer format in search. Sekretess after close stays.
8. **GDPR.** Discord IDs and in-game names of real players are personal data. Keep a short privacy notice on the portal login, audit retention 90 days, no public share links without expiry.
9. **Fun over realism when they conflict.** The visibility rules table and the obehörig-sökning threshold are config for this reason. Default to permissive for IGV lookups, strict only for sources and missions.
10. **Agents cannot play.** Every phase ends with a Rami in-game checklist (generated by the agent as `docs/test-phase-N.md`, ≤ 10 steps). Same-day feedback keeps the 3–4 week estimate.
11. **Windows host.** Paths, service management (NSSM), and backups are Windows-specific; document them in `docs/hosting.md`, don't assume Linux in scripts (`scripts/*.sh` need Git Bash; provide `.ps1` twins).
12. **Statebags are readable by all clients.** Never put tiers, units or sensitive flags in statebags; keep them server-side and send per-player copies.

---

## 9. Assumed defaults (most common choice on a Qbox stack; each is a config key, not code)

| Decision | Default | Config key | Alternatives supported by an adapter/flag |
|---|---|---|---|
| Housing | `ps-housing` (Project Sloth) | `config/integrations.json → housing: "ps-housing"` | `qbx_properties`, `ox_doorlock-only` (any script whose doors are ox_doorlock doors) |
| Garage | `qbx_garages` | `garage: "qbx_garages"` | `jg-advancedgarages` via adapter stub (not built unless needed) |
| Prison | `qbx_prison` (qbx_police already calls `qbx_prison:JailPlayer` when present) | `prison: "qbx_prison"` | `qbx_police` built-in jail, `xt-prison` |
| Alerts generator | `ps-dispatch` | `dispatch: "ps-dispatch"` | none needed; own `createAlert` export exists |
| Portal exposure | Cloudflare Tunnel (no open ports, free HTTPS, fits the 0-fee hosting) | `docs/hosting.md` | Caddy with open 443, LAN-only |
| Officer name source | Discord server nickname → global name → username (see §4.9) | `officerNameSource: "discord_nick"` | `discord_global`, `character` |
| Callsign format | `{{unit}}-{{n:2}}` → `IGV-07` | `config/formats.json → callsign` | any template |
| Case number | `K-{{seq}}-{{yy}}` → `K-123-26` | `formats.json → caseNumber` | any template |
| Report number | `{{case}}/{{n}}` → `K-123-26/2` | `formats.json → reportNumber` | |
| Evidence tag | `B-{{case}}-{{n:3}}` → `B-K-123-26-004` | `formats.json → evidenceTag` | |
| Plate pattern | `^[A-Z]{3}\s?\d{2}[A-Z0-9]$` (Swedish) | `formats.json → plate` | e.g. `^[A-Z0-9]{2,8}$` for GTA default |
| Personnummer | `^\d{6,8}-?\d{4}$` | `formats.json → personId` | |
| Date / time | `YYYY-MM-DD` / `HH:mm`, tz `Europe/Stockholm` | `formats.json → date, time, tz` | |
| Currency | `kr`, no decimals, thousands space | `formats.json → currency` | |

Adapters live in `resources/[fredpd]/fredpd_core/adapters/<kind>/<name>.lua` and export one interface per kind (`housing: getDoorForProperty, unlock`, `garage: onParked, onTakenOut`, `prison: jail(src, minutes, charges)`). Adding a script = adding one file and one config value. Task 0.3 verifies each default's exports; if a default is not installed on Rami's server, the adapter is a no-op and logs one warning at start.
