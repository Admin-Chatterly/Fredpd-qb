<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Module: fredpd_service (tasks 1.6, 1.7, 1.7b service side, API for 1.8)

Node 22 + Fastify 5 + discord.js 14 + drizzle/mysql2, one process (`apps/service`). Implements docs/contracts.md
§C2 (grant resolution via `@fredpd/types`), §C5 (HMAC), §C6 (service endpoints, FXServer client), §C7
(`009_service.sql`) and §C10 (permissions admin API). Run: `pnpm --filter @fredpd/service start` (tsx, no build).

## Files

| File | Role |
|---|---|
| `src/config.ts` | zod-validated env (`.env.example` lists all); short secrets and every `.env.example` placeholder refused (secrets, Discord credentials, all-zero ids, DB password); `SESSION_SECRET` ≠ `FREDPD_HMAC_SECRET` |
| `src/app.ts` | `buildApp(deps)`: plugins, hooks, routes; deps = config, db, gateway, fx, clock, oauth?, fetch?, discordTokenHost?, log?, unitOrder? |
| `src/main.ts` | real deps, schema check, listen, bot login; SIGINT/SIGTERM or a fatal bot error → bot, HTTP, pool |
| `src/db/schema.ts`, `client.ts`, `repo.ts` | drizzle mirror of 001/009 tables; mysql2 `timezone: 'Z'` pool; every SQL statement |
| `src/grants.ts` | `computeGrants` = gateway member roles + DB rows → `resolveGrants` |
| `src/discord/gateway.ts` | `DiscordGateway` / `GatewayEvents` interfaces (tests fake them) |
| `src/discord/bot.ts` | discord.js adapter (intents Guilds + GuildMembers); per-member ordered event handling |
| `src/discord/sync.ts` | pure helpers (name, avatar, diffs) + orchestration (import, recompute, pushes) |
| `src/fx.ts` | signed FXServer client (`ping`, `pushGrants`, `recompute`, `pushOfficer`, `pushRulesChanged`), 3 s deadline, never throws |
| `src/fx-retry.ts` | redelivery of grant pushes/recomputes FXServer missed (one-shot timers 2 s / 10 s / 30 s, then next success) |
| `src/auth/session.ts`, `oauth.ts` | sessions/CSRF; Discord OAuth (`@fastify/oauth2`) behind `DiscordOAuth` |
| `src/routes/*.ts` | auth + `/api/session`, admin, internal, upload, avatar, ws |
| `src/ws/hub.ts`, `src/ws/events.ts` | WS fan-out per event type, socket cap; who may receive what (`LIVE_EVENT_GRANTS`), `/internal/events` payload check |
| `src/avatar.ts`, `src/catalog.ts`, `src/units.ts` | avatar disk cache, admin catalog, units.json |
| `db/migrations/009_service.sql` | `fredpd_sessions`, `fredpd_uploads` |
| `packages/types/src/actions.ts` | shared zod schemas (session, admin, internal, upload, MDT open payload, error codes) |

## Endpoints

Errors are always `{ error: <code>, detail? }`; codes and their locale keys are in `actions.ts`
(`API_ERROR_LOCALE_KEYS`). The service never produces player-facing text.

| Route | Auth | Notes |
|---|---|---|
| `GET /auth/discord` | – | 302 to Discord (scope `identify`, state cookie signed, path `/auth`) |
| `GET /auth/discord/callback` | state | member of `DISCORD_GUILD_ID` required; `fredpd_identities.last_seen` upsert; new session (old one ended); audit `auth.login`; 302 `PUBLIC_URL/`, on failure `PUBLIC_URL/?loginError=failed\|notMember\|unavailable` |
| `POST /auth/logout` | session + CSRF | deletes the row, closes its sockets, audit `auth.logout`; without a session just clears the cookie |
| `GET /api/session` | – | `{ user: { discordId, displayName, avatarUrl, citizenid, grants } \| null, csrfToken }`; a user who left the guild is logged out here |
| `GET /api/admin/roles` | session + `perm:admin.permissions` | §C10; roles include `colour` and deleted roles (flagged); catalog = `*` + units (units.json order) + tiers 0–2 + every `MDT_PAGE_KEYS` (nav order) + `KNOWN_PERMS` + tool `ram` + keys in use (see "Admin catalog") |
| `PUT /api/admin/roles/:id/grants` | + CSRF | 400 on duplicate/invalid rows (≤ 500) and on unit keys that are not `*` or a unit code fredpd_core accepts (`[A-Za-z0-9_-]{1,32}`, `UnitCodeSchema`) or that are neither in `config/units.json` nor already on the role; 404 unknown role; one transaction with `SELECT … FOR UPDATE` on the role + audit `perms.update` (`meta.before/after` as `±type:key`); then every holder is resolved, `fredpd_grant_cache` refreshed, FXServer `/recompute { discordIds }`; `recomputed` = FXServer's `scheduled`. When FXServer did not confirm (timeout, network, 5xx, or the gateway was not ready) the answer is `{ ok: true, recomputed: 0, fxPending: true }` and the recompute is redelivered (see "Grant redelivery") |
| `GET /internal/ping` | HMAC, loopback | `{ ok, discord, subscribers }` |
| `GET /internal/grants/:discordId` | HMAC, loopback | `{ discordId, member, grants }`, writes `fredpd_grant_cache`; **503 while the gateway is not ready** (FXServer then uses its cache instead of storing "no grants") |
| `POST /internal/events` | HMAC, loopback | `{ type, payload }` (strict); alert/unit events must match `DispatchInternalEventSchema` after restoring Lua's absent nulls (else 400 `invalid_body`), and the parsed value is what `/ws` sends; `{ ok, delivered }` |
| `POST /upload` | session + CSRF + ≥ 1 allowed grant (multipart `file`; 403 `forbidden` without a grant, 415 if not multipart) or HMAC from loopback (JSON `{ data, citizenid?, discordId? }`) | ≤ 5 MB else 413; `file-type` sniff png/jpeg/webp else 415; `UPLOAD_DIR/<32 hex>.<ext>`, row + audit `upload.create`. Malformed/stale HMAC headers, and HMAC requests that are proxied or not from loopback, are refused (401) in `onRequest`, before the body is read |
| `GET /avatar/:discordId` | – | PNG from disk; CDN fetched once per avatar hash; last file if the member is unknown; 404 otherwise; `CORP: cross-origin` for the NUI |
| `GET /ws` | session, Origin = PUBLIC_URL origin, a grant for at least one live event type (else 403) | server → client only; messages are `InternalEvent` |

**Loopback only (`/internal/*`).** `requireLoopback` (onRequest, before the body and the rate limiter) answers 404
`not_found` unless the TCP peer is loopback (`127.0.0.0/8`, `::1`, `::ffff:127.x`) **and** the request carries no
proxy header (`X-Forwarded-For`, `X-Forwarded-Host`, `X-Forwarded-Proto`, `Forwarded`, `X-Real-IP`,
`CF-Connecting-IP`, `CF-Ray`, `True-Client-IP`, `Via`). FXServer's `signedFetch` sends none of them. Through
cloudflared or Caddy on the same host the peer is loopback but a proxy header is present, so `/internal` stays closed
even when the tunnel points straight at the service (task 7.1) or a Caddy/WAF rule is missing, and a captured
signature cannot be replayed from outside the host (§C5 does not sign method or path, open question 4). **FXServer
and the service must run on the same host** (§C6 pins 127.0.0.1 both ways); FXServer↔service traffic must never
cross a network in clear text.

## Decisions

- **Sessions.** Cookie `fredpd_sid` = 32 random bytes base64url, signed with `SESSION_SECRET` (a forged cookie
  costs no DB read); DB stores sha256(token). httpOnly, `secure` = `COOKIE_SECURE`, SameSite=Lax, Path=/, 7 days,
  fixed expiry (no sliding). Expired rows are purged (≤ 500) on login/logout, no timer.
- **CSRF** is a synchroniser token of our own (not `@fastify/csrf-protection`): random per session, returned by
  `GET /api/session`, compared in constant time with `x-csrf-token` on every write that uses the session. Future
  `/api/*` writes must use `requireSession({ csrf: true })` from `src/http/guards.ts`.
- **HMAC** is verified on the raw body: the app replaces the JSON parser with one that keeps `request.rawBody`,
  verifies the signature first when the request carries HMAC headers and no session (a forged request gets 401
  without being parsed, not a 400 parse error), and then runs Fastify's own (prototype-poisoning-safe) parser;
  `requireHmac` on the route stays the authoritative check. GET → empty string. Every other method must carry a
  JSON body: a text/plain or multipart body is refused (401) instead of being checked as the empty string. So a
  multipart request cannot pass HMAC (hence the JSON variant of `/upload` for FXServer, e.g. a screenshot-basic
  data URI obtained server-side). Rejections are logged at most once per 10 s with a suppressed count
  (`suppressedSinceLast`), as http.js does, since `/internal` is reachable through the tunnel.
- **Rate limit** 60/min keyed `session:<sha256(token), 32 hex>` when the request carries a validly signed session
  cookie, else `ip:<ip>`. The global `onRequest` hook only unsigns the cookie (no I/O); the session row is loaded in
  a global `preParsing` hook, i.e. after the limiter's route-level `onRequest` hook, so an over-limit request costs no
  DB query (test: an app without a database answers 500 for 60 requests with a session cookie, then 429). Sessions
  are one per user (a new login ends the old one), so this is still per user. The raw token never enters the
  limiter's store. `trustProxy: 'loopback'` (Cloudflare Tunnel/Caddy on the same host). Higher limits: `/internal/*`
  1200/min (FXServer bursts on restart), `/avatar` 300/min (rosters). `/upload`'s own `onRequest` runs before the
  session is loaded and uses the signed-cookie token to pick the portal path.
- **Admin catalog** (`src/catalog.ts`, §C10/§C12). Always listed, whether or not a role uses them:
  - `mdt_page`: every key of `MDT_PAGE_KEYS`, which now live in `packages/types/src/mdtPages.ts` (`@fredpd/ui`
    re-exports them). They are sorted in nav order (search, alerts, bolos, cases, evidence, intel, charges, roster,
    command), not alphabetically; keys that are only stored come after them.
  - `perm`: `KNOWN_PERMS` = every perm pinned in docs/contracts.md, which is the §C12 list (`admin.permissions`,
    `records.admin`, `bolo.create`, `bolo.resolve`, `tablets.manage`, `intel.read`, `intel.handler`,
    `intel.command`) plus `alerts.manage` (§C13), `cases.create`, `charges.apply`, `charges.fine` (§C14) and
    `evidence.link` (§C16). An admin can map them before the checking module ships. Ranks (`rank:<key>`) come from
    the keys in use.
  - `tool`: `ram` (§C16).

  `test/catalog.test.ts` fails when an action registry in `@fredpd/types` (`MDT_ACTIONS`, `DISPATCH_ACTIONS`,
  `RECORDS_ACTIONS`, `INTEL_ACTIONS`, `EVIDENCE_ACTIONS`) names a perm missing from `KNOWN_PERMS` or an `mdt_page`
  outside `MDT_PAGE_KEYS`, or when a known perm or tool has no sv/en label. The PUT validator
  (`AdminRoleGrantSchema`) needed no change: it accepts every catalog key (tested, pure and through the route). The
  new labels (`perms.perm.{alerts.manage,bolo.create,bolo.resolve,cases.create,charges.apply,charges.fine,
  evidence.link,tablets.manage}`) are in `locales/pending/service.json`.
- **Grants** are always resolved live (gateway roles + DB rows). Pushes: member role change → `POST /grants`;
  admin save and role moves → `POST /recompute { discordIds }` (> 2000 ids → `{}` = all online); gateway ready and
  resync (always) and role delete → `/recompute {}`. `fredpd_grant_cache` is written by the service on every resolution
  it sends (FXServer also writes it on push). **Cache rows only move forward**: `writeGrantCache` keeps the stored
  row when the new set's `computedAt` is older (`grants = IF(VALUES(computed_at) >= computed_at, …)`,
  `computed_at = GREATEST(…)`; seconds precision, so within one second the last write wins), the same rule as
  fredpd_core perms.lua, which also ignores an older set in memory (core.md "Grants runtime").
- **Grant redelivery** (`src/fx-retry.ts`). A `/grants` push or `/recompute` that gets no answer (timeout, network) or
  a 5xx marks its Discord ids (or "everyone online") pending. Pending ids go out as **one** `/recompute { discordIds }`
  (or `{}`), so FXServer re-fetches the live set and a retry can never deliver an outdated one. One-shot timers after
  2 s, 10 s and 30 s, armed only while something is pending (no idle polling); after the last attempt the ids stay
  pending and go out with the next FX call that succeeds (any push, including `/officer`) or the next failure's
  retry. 4xx answers are not retried. `app.close()` stops the timer. Pending ids are in memory only: after a service
  restart the ready-time `/recompute {}` covers them.
- **Offline members' cache rows** are re-resolved on `ready` and `resynced` (`sync.refreshGrantCache`: every
  `discord_id` in `fredpd_grant_cache`, chunks of 500, one rows load): FXServer's fallback (used while the service is
  down) would otherwise hand a joining player grants that were revoked while the service was down. Members who left
  the guild get the empty set. A failure there is logged and does not stop start-up. No maximum age on FXServer's
  fallback rows: with this refresh a row is at most as old as the last service start.
- **Visibility rules push.** `fx.pushRulesChanged()` sends `POST /fredpd_core/rules` with the body `{}` (exactly
  that: http.js refuses anything else) and fredpd_core reloads `fredpd_visibility_rules`. It never throws, like every
  fx call. There is no caller yet. The future rules editor (a Ledning page) must call it **after** its transaction
  commits (TODO in `src/fx.ts`). Until then rules are edited in SQL and reloaded with the signed curl call in
  docs/test-phase-1.md step 10.
- **Discord sync.** On ready roles are diffed against `fredpd_roles`: upsert (`INSERT … ON DUPLICATE KEY UPDATE`,
  never REPLACE), missing roles soft-deleted, one `roles.sync` audit row when something changed. Then FXServer is
  always asked to `/recompute {}` every online player: member role changes made while the service was down
  (crash, update, NSSM restart after `onFatal`) were never pushed, and perms.lua does not re-fetch on its own, so
  players who joined meanwhile would keep their `fredpd_grant_cache` fallback until they rejoin. Name-only role
  edits are stored without a recompute. Member removed → empty set pushed.
- **Gateway cache reloads.** Whenever the guild becomes available again — the GUILD_CREATE of a **new gateway
  session** (READY marks every guild unavailable) or the end of a **guild outage** (GUILD_DELETE `{unavailable}`,
  then GUILD_CREATE, no ShardReady) — discord.js replaces the guild's role and member caches with that packet's
  contents, which without the presences intent is only the bot's own member. bot.ts counts these invalidations
  (`GuildAvailable`; ShardReady after ready as a fallback, which discord.js emits in the same tick and so shares
  the reload) and `isReady()` is false until the guild has been reloaded for the latest one, and during an outage
  (`guild.available`): grant lookups answer 503, `/api/session` does not end sessions, FXServer keeps its cache.
  Events arriving meanwhile are not forwarded; after the reload the roles are re-imported and FXServer asked to
  `/recompute {}` (`resynced`). A resume replays events itself and needs none of this. If the guild/members cannot
  be loaded (at start or on a reload), or the bot is removed from the guild (GUILD_DELETE without `unavailable`),
  the bot calls `onFatal`: the gateway reports not-ready (503) and `main.ts` exits with code 1 for NSSM to restart
  it.
- **User-level changes.** Discord sends global name / username / user avatar changes in GUILD_MEMBER_UPDATE, but
  discord.js emits those only as `userUpdate` (its `guildMemberUpdate` ignores user fields, and its `before` clone
  shares the updated User). bot.ts therefore also listens to `userUpdate` and forwards a member update whose
  `before` is the member with the OLD user fields; it reads the member one microtask later, after the rest of the
  same packet (nickname, roles) is applied. Events of one member (and of one role) are handled strictly in order.
- **Officer identity (§4.9).** Name per `OFFICER_NAME_SOURCE` (`discord_nick`: nick → global → username;
  `discord_global`: global → username), cleaned (control/format chars removed, ≤ 100 code points). Avatar: guild
  avatar (nick mode only) → user avatar → Discord default. `avatar_url` stored/pushed is
  `PUBLIC_URL/avatar/<id>?v=<key>` so the tablet never calls Discord. The bot UPDATEs every `fredpd_officers` row
  of that Discord id (FXServer creates the rows) and audits `officer.identity`; `/officer` is pushed when rows
  changed, and on join (`/internal/grants`) for officers (a row or ≥ 1 allowed grant) so FXServer has the name
  before the character row is created. `character` mode: names are not synced (see open questions).
- **WS access** (docs/contracts.md §C13): per event type, `LIVE_EVENT_GRANTS` in `src/ws/events.ts` — every current
  type (`alertCreated`, `alertAssigned`, `alertClosed`, `unitsChanged`, and `playerJoined` / `playerDropped`, which
  have no producer or payload contract yet) needs `mdt_page:alerts`, checked with `hasGrant`, so a deny wins (allow
  `mdt_page:*` + deny `mdt_page:alerts` → nothing) and other grants (`weapon:*`, `tool:ram`, `perm:rank:x`) give
  nothing. A user with no live event type gets 403 at the upgrade. The hub keeps the allowed types per Discord id,
  replaced on every recompute of that user (`/internal/grants`, sync), so a demoted user stops receiving without
  reconnecting. At most 5 sockets per Discord user: a new one closes that user's oldest with **4429** (the portal
  must not auto-reconnect on 4429). Close code 4401 = session ended (logout, expiry, left guild).
- **`/internal/events` payloads**: alert and unit events are parsed with `DispatchInternalEventSchema` after
  `restoreNulls` (fredpd_dispatch sends nullable fields that are nil in Lua as absent keys, docs/modules/dispatch.md);
  a mismatch is 400 `invalid_body` with the first issue path, and what `/ws` forwards is the parsed value (nulls
  filled in, unknown keys stripped). fredpd_dispatch's golden files (`fredpd_dispatch/test/golden/internal.*.json`)
  are checked in `test/events.test.ts`. `playerJoined` / `playerDropped` pass unchanged until their module pins a
  schema.
- **Audit actions written**: `perms.update`, `auth.login`, `auth.logout`, `roles.sync`, `officer.identity`,
  `upload.create` (labels in `locales/pending/service.json`). Not audited per row, as in fredpd_core:
  `fredpd_grant_cache`, `fredpd_identities`, `fredpd_sessions`.
- **DB time** (docs/contracts.md §C7): DATETIME is UTC whatever the MariaDB server/session zone, and the pool no
  longer sets a session zone. mysql2 runs with `timezone: 'Z'` (Dates written and raw-read as UTC); drizzle reads
  DATETIME as text + `Z`. Schema defaults are `(UTC_TIMESTAMP())`; `updated_at` columns have
  `$onUpdate(() => sql\`UTC_TIMESTAMP()\`)`, so every drizzle `update()` and `onDuplicateKeyUpdate()` sets it (the
  tables have no ON UPDATE clause; raw SQL writers must set it themselves). Unlike the old ON UPDATE rule and
  fredpd_core's `buildInsert` `touch` (which move it only when a value really changes), `$onUpdate` moves it on
  every write, changed or not. The writers therefore only write rows that change: `upsertRoles` gets `diffRoles`'
  created/updated roles, `markRolesDeleted` skips roles already deleted, `updateOfficerIdentity` updates only
  stale rows. A new drizzle writer to a table with `updated_at` must filter the same way. Comparisons use the injected clock's
  Date, never the session clock. `test/utc.test.ts` proves it with every session at `+02:00` and the Node process
  in Europe/Stockholm.
- `main.ts` refuses to start if `fredpd_sessions` is missing (run `node scripts/migrate.mjs` or start FXServer
  once) and exits (for NSSM to restart) if the Discord login fails or the bot reports a fatal error.

## Tests (`pnpm exec vitest run --project service`)

DB tests use `fredpd_test_service` (created + migrated by `test/helpers.ts`; per-file id prefixes, parallel-safe)
and `fredpd_test_service_sync` (sync.test.ts: a role import soft-deletes unknown roles). They skip with a warning
when MariaDB is unreachable. `signedInject` sends from `127.0.0.1` without proxy headers unless told otherwise.
Files: `events` (pure: live access per grant incl. deny and non-alert grants, hub per-type fan-out, socket cap,
expiry, payload check incl. the dispatch golden files, `/internal/events` 400/200), `fx-retry` (backoff, pending
merge, 4xx not retried, redelivery on success, close), `catalog` (pure: catalog contents and order, PUT schema over the whole catalog,
registry perms/pages, labels), `hmac`, `grants`, `admin` (incl. a PUT of every fixed catalog key; only the fixed
part of the catalog is asserted, since other files' keys in the shared database may follow it), `fx` (incl.
`pushRulesChanged`: exactly `{}` to `/rules`, signed; refusal/unreachable → `{ ok: false }`), `upload`, `auth`,
`oauth` (real @fastify/oauth2 against a local token endpoint), `ws`, `sync`, `bot` (discord.js packet handlers on
a Client that never logs in), `avatar`, `config`, `schema` (drizzle vs information_schema), `actions`, `ratelimit`, `utc` (own database
`fredpd_test_utc_service`, sessions at `+02:00`: Date round trip via drizzle and raw mysql2, stored wall time,
SQL comparison, UTC defaults, `updated_at` on upsert/update, untouched on a repeated soft delete). `setupTestDb`
drops and rebuilds a test database with an applied migration whose checksum no longer matches `db/migrations`, under
a per-database lock; an applied migration whose file is missing from the checkout (another checkout's newer
migration on a shared MariaDB) only gets the runner's warning and never triggers a drop.

## Open questions

1. `OFFICER_NAME_SOURCE=character` is accepted but only disables Discord name sync; fredpd_core has no character
   naming path yet (officers.lua always uses the Discord/FiveM name).
2. Serving uploads (`GET /uploads/:file`) is not built: who may view an image depends on the record it belongs to
   (`canView`), so it belongs to the records/evidence tasks. `/upload` returns `{ id, fileName }`.
3. screenshot-basic's `requestScreenshotUpload` posts from the *client*, which cannot sign HMAC. FXServer should
   use the server-side `requestClientScreenshot` and forward the data URI with `signedFetch('POST', '/upload', …)`
   (≤ 5 MB decoded; http.js `signedFetch` body limits permitting).
4. §C5 does not sign method or path (see core.md question 5). A captured signature is valid for 60 s on **every
   route that accepts the same body**: all GETs are signed as `ts + "."`, so a `GET /internal/ping` signature (or the
   service's own `GET /ping` to FXServer) also authorises `GET /internal/grants/<any discordId>`. Since this fix
   `/internal/*` and the HMAC `/upload` answer only direct loopback requests without proxy headers ("Loopback only"),
   so such a replay needs a process on the host itself. Cross-route replay of POST bodies stays blocked by the strict,
   disjoint body schemas. Still proposed for the contract owner: sign
   `ts + "." + METHOD + " " + path + "." + rawBody` (ideally with a direction tag) in §C5, `hmac.ts`, `http.js` and
   the fixtures together.
5. No WebSocket keep-alive ping (no timers): Cloudflare closes idle sockets after ~100 s; the portal must
   reconnect on close (it already has `portal.live.reconnecting`), except after 4401 (session ended) and 4429
   (too many sockets: another tab of the same user took over), and must not retry a 403 upgrade (no live grant).
6. Unused dependencies in `apps/service/package.json`: `@fastify/csrf-protection`, `@fastify/formbody`,
   `@fastify/static` (portal hosting is a later task).
7. Uploads have no per-user quota yet (only 60 requests/min × 5 MB, officers only) and nothing cleans up files
   that no record references; both belong with the records/evidence tasks that serve them (question 2).
8. The service does not serve the portal build (`apps/portal/dist`; `@fastify/static` is installed but unused), so
   a tunnel pointed at `127.0.0.1:3000` (IMPLEMENTATION.md §7.2) has no portal page yet. docs/hosting.md §7 bridges
   this with a Caddy site that serves the SPA and proxies the service routes. Task 7.1 should add static serving with
   an SPA fallback that excludes `/api`, `/auth`, `/avatar`, `/ws`, `/upload`, `/share` and `/internal`.
   The per-IP rate limit (`ip:<request.ip>`, every logged-out request) relies on `trustProxy: 'loopback'` seeing
   the real client: behind the tunnel that needs Caddy's global `trusted_proxies static 127.0.0.1/32 ::1/128`
   (hosting.md §7), otherwise Caddy replaces `X-Forwarded-For` with cloudflared's `127.0.0.1` and all visitors share
   one bucket. Once the tunnel points straight at the service, Fastify reads the edge's `X-Forwarded-For` itself.
9. The PUT accepts any well-formed `mdt_page` key, not only `MDT_PAGE_KEYS` (a typo is stored and shown as an extra
   column). This is kept so rows written before a key rename stay editable. If wanted, refuse unknown page keys the
   way unknown unit keys are refused (allowed when the role already has it).
10. There is no first-admin bootstrap: on a new database no role holds `perm:admin.permissions`, so nobody can open
    Behörigheter. hosting.md §6 step 7 documents a one-time SQL insert (no audit row). If wanted, a later task could
    add an `.env` key naming a bootstrap role (audited as `perms.update` by the service at start).
11. `fxPending: true` in the PUT answer is additive to §C10 (`AdminRoleGrantsPutResponseSchema` strips it on parse).
    The portal owner may show "FXServer has not confirmed yet"; the contract owner may add it to the schema. The
    reviewer's `recomputed: null` was not used: the pinned schema requires a number.
12. `playerJoined` / `playerDropped` (§C6 event types) have no producer and no payload schema; they are gated on
    `mdt_page:alerts` like the rest of /ws (§C13). If a roster module produces them, it should pin a payload and
    decide whether `mdt_page:roster` fits better (one line in `LIVE_EVENT_GRANTS`).
