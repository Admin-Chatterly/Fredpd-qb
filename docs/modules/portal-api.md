<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Module: portal actions bridge (task 7.1 server side, task 7.2 hardening)

The portal runs the same tablet actions as the NUI (same names, same zod schemas) without a player in the world:
fredpd_service checks session, CSRF, character and live grants, then forwards the call HMAC-signed to FXServer, where
fredpd_mdt runs its §C12 dispatcher in **portal mode** for a **portal actor** of fredpd_core. Also: character
selection, the public share route, portal hosting by the service, headers/CSP, and the NSSM install script.

## Files

| File | Role |
|---|---|
| `apps/service/src/routes/portal.ts` | `GET /api/characters`, `POST /api/session/character`, `POST /api/mdt/:action`, `GET /share/:token`, `GET /api/share/:token` |
| `apps/service/src/portal/actions.ts` | `TABLET_ACTIONS` (MDT + DISPATCH + EVIDENCE + RECORDS + INTEL registries), `PORTAL_ACTIONS`, intel set |
| `apps/service/src/portal/lua-json.ts` | `fromLua(schema, value)`: Lua's absent nulls and `{}`/`[]` restored from the output schema |
| `apps/service/src/routes/static.ts` | serves `apps/portal/dist` (`PORTAL_DIR`) with SPA fallback |
| `apps/service/src/fx.ts` | + `portal(body)` → `POST <FXSERVER_URL>/fredpd_mdt/portal`, 17 s deadline |
| `apps/service/src/db/{schema,repo}.ts` | + read-only `fredpd_persons` mirror; `listCharacters`, `ownsCharacter`, `setSessionCitizenid` |
| `apps/service/src/app.ts`, `config.ts`, `.env.example` | CSP, `no-store` on `/api/*`, SPA not-found handler, `PORTAL_DIR` |
| `resources/[fredpd]/fredpd_mdt/server/http.js` | `SetHttpHandler`: `POST /fredpd_mdt/portal` (HMAC, loopback peer, requestId replay guard, 15 s Lua deadline) |
| `resources/[fredpd]/fredpd_mdt/server/portal.lua` | portal-mode dispatcher, `M.ALLOWED`, `viewShare` wiring, export `portalRequest(body, cb)` |
| `resources/[fredpd]/fredpd_mdt/server/main.lua`, `fxmanifest.lua` | `Portal.register()`; `server/http.js` in `server_scripts` |
| `resources/[fredpd]/fredpd_core/server/virtual.lua` (**new, outside my ownership list, see below**) | portal actors; internal export `portalActor(discordId, citizenid, grants)` (fredpd_mdt only) |
| `resources/[fredpd]/fredpd_core/server/{core,perms,audit,main}.lua` (**small edits, see below**) | stand-in player, grant cache slot, `meta.via = 'portal'`, registration |
| `resources/[fredpd]/fredpd_records/server/shares.lua` (**1 line, outside my list**) | `VIEW_CALLERS` + `fredpd_mdt`: viewShare refused every resource but fredpd_core/fredpd_records, so the portal route could not call it |
| `scripts/install-service.ps1` | idempotent NSSM install/update of `fredpd_service` (hosting.md §6) |
| `locales/pending/portal-api.json` | `audit.action.auth.character`, `errors.portalInGameOnly`, `errors.noCharacter` |

## Decision: where the FXServer route lives

`SetHttpHandler` routes are per resource (`/<resource>/<path>`), so fredpd_core's handler cannot answer
`/fredpd_mdt/portal`. **fredpd_mdt got its own `SetHttpHandler`** (`server/http.js`, the preferred option). The HMAC
helpers are **copied** from fredpd_core's http.js (requiring that file would run its FiveM wiring a second time in
fredpd_mdt); `fredpd_mdt/test/http.test.ts` runs them against `hmac.fixtures.json`. The portal work awaits MySQL in the
routed exports, which cannot yield across a JS→Lua export call, so http.js calls the Lua export
`portalRequest(body, cb)`, which starts a thread and answers through `cb(status, jsonText)` exactly once (15 s
deadline in JS → 504).

## Decision: portal actors (fredpd_core)

Every routed export (records, intel, bolo, forensics, dispatch) asks fredpd_core by `src` for grants, citizenid,
duty, canView viewer and audit actor. The portal has no `src`, so fredpd_core now issues **stand-in ids** ≥
`Core.VIRTUAL_BASE` (1 000 000 000; no FiveM player id reaches that):

- `hasGrant/getGrants/getTier/getUnits/getDiscordId`: the GrantSet the service resolved live for the Discord id and
  sent in the signed body, validated with `Perms.validateSet` (same trust as a `/grants` push). A `/grants` push for
  that Discord id also updates the actor (no client event is sent to a stand-in id).
- `Core.getPlayerData` → stand-in player: the session's character (the service re-checks ownership on every call), a
  `leo` job with `onduty = true` (**the portal has no duty requirement**, so downstream duty gates pass).
- The framework bridge (`getPlayer`, inventory) still answers nil/0 for it; natives find no ped. World actions are
  refused before routing anyway.
- `audit(src, …)`: actor citizenid + Discord id of the portal user, `meta.via = 'portal'` (copy; caller's meta untouched).
- One id per (Discord id, citizenid), reused (so per-src rate limits are per user), released after 10 min idle by a
  one-shot `SetTimeout` (re-armed for the remainder while in use; no polling); release fires the server-local event
  `fredpd:portalActorReleased(src)` (fredpd_mdt forgets its limiter entry). At most 5000 live actors.

The edits: `core.lua` (+ `VIRTUAL_BASE`, `virtualActor/isVirtual/setVirtualActor`, 2 lines in `getPlayerData`),
`perms.lua` (`setVirtual/clearVirtual`; `store` skips the client event for stand-ins), `audit.lua` (`portalMeta`, 1
line in `audit`), `main.lua` (require + `Virtual.register()`). The fredpd_core owner should review them (they are
outside this task's file list, but the contract's "virtual actor … via fredpd_core" is impossible without them).

## Wire contract

### Browser ↔ service

| Route | Auth | Answer |
|---|---|---|
| `GET /api/characters` | session (401 `unauthenticated`) | `[{ citizenid, name }]`: `fredpd_persons` whose `license` = the user's `fredpd_identities.license` (non-null) **and** that have a `fredpd_officers` row with `discord_id` = the user (police characters only; a civilian alt is never a portal actor, and fredpd_core's `portalActor` refuses such a citizenid too). A license belongs to the Discord user who last loaded a character on it (fredpd_core clears it, and the sessions' character, for every other Discord id). Sorted by last/first name, ≤ 50, `no-store` |
| `POST /api/session/character` | session + CSRF (403 `csrf`) | body `{ citizenid }` (strict); not one of the list → 403 `forbidden`; stored in `fredpd_sessions.citizenid`, audited `auth.character` (only on change) → `{ ok: true, citizenid }` |
| `POST /api/mdt/:action` | session + CSRF on **every** call | body = action input (absent = `{}`, ≤ 448 KB) → 200 = action output |
| `GET /share/:token` | – | `Accept` with `application/json` and without `text/html` → share JSON; else `index.html` (SPA route) |
| `GET /api/share/:token` | – | share JSON (same) |

`/api/mdt/:action`, in this order (nothing reaches FXServer before step 8):

1. no session → **401** `{ error: 'unauthorized', reason: 'session' }`;
2. CSRF mismatch → **403** `{ error: 'csrf' }` (the service's CSRF code, which the portal transport reacts to);
3. action not in `TABLET_ACTIONS` → **400** `{ error: 'validation', detail: 'action' }`;
4. not in `PORTAL_ACTIONS` → **403** `{ error: 'unauthorized', reason: 'portal' }`;
5. no character, or it is no longer linked to the user (then also cleared from the session) → **403** `reason: 'no_character'`;
6. live grants (503 `unavailable` while Discord is not ready); not a guild member → **403** `unauthorized`; **no
   `mdt_page` grant at all** (the tablet's `tablet.noGrant` gate, so grant-less actions such as `getHome` — on-duty
   count — and `listCharges` are not open to civilians) → **403** `{ error: 'unauthorized', reason: 'no_grant' }`
   (fredpd_mdt `portal.lua` repeats the check with `C.anyMdtGrant`); the registry grant missing → **403** `unauthorized`;
7. zod input parse → **400** `{ error: 'validation', detail: <first path> }`;
8. FXServer: unreachable / timeout / 5xx / 401 / 409 / malformed → **503** `unavailable`; `{ ok: false, error }` →
   `validation` 400, `unauthorized` 403, `not_found` 404, `rate_limited` 429, `unavailable` (and any unknown code) 503;
   `reason` passed when it matches `^[A-Za-z_]{1,32}$`;
9. **every refusal of an INTEL action (steps 4–8: `unauthorized` or `not_found`, including step 5's `no_character`
   and step 6's `no_grant`) is 404 `{ error: 'not_found' }`** (§C15).
   Records already answer `not_found` for canView `none`.
10. `{ ok: true, data }` → `fromLua(output schema)` then zod parse (unknown keys stripped) → 200. A drifted answer that
    still fails the schema is sent as restored with one warning per action and minute (the tablet shows it unparsed
    too; a hard failure would take a page down for a cosmetic drift).

Rate limit: the global 60/min per session (per IP when logged out) covers `/api/mdt`; 429 `{ error: 'rate_limited' }`.
FXServer adds the tablet's per-action limit classes per portal actor. Share routes: 30/min per IP.

Portal-allowed actions (`PORTAL_ACTIONS` = `portal.lua M.ALLOWED`; both tests compare them): every read (limit class
`read`/`lookup`) and the fredpd_records / fredpd_intel / fredpd_bolo writes, minus world actions. Refused: `close`,
`checkPlate` (plate check + BOLO hit alert), `takeAlert`, `leaveAlert`, `closeAlert`, `issueFine` (bills a player),
`setTabletRevoked`, `linkEvidence`. `applyCharges` is allowed: its jail step needs the target near the actor's ped, and a
portal actor has none, so it records only.

### Service → FXServer (`POST /fredpd_mdt/portal`, §C5-signed)

```json
{ "requestId": "<32 hex, random per call>", "discordId": "…", "citizenid": "…", "grants": GrantSet, "action": "…", "input": {…} }
{ "requestId": "…", "action": "viewShare", "input": { "token": "<43 base64url>" } }
```

Answers: 200 `{ ok: true, data }` | 200 `{ ok: false, error, reason? }`; 400 `bad_json`/`invalid_body` (detail);
401 `unauthorized`; 404 (other path, or a non-loopback peer); 405; **409 `duplicate`** (requestId seen within 120 s:
§C5 signs only ts + body, so a captured write could otherwise be replayed for 60 s); 413 (> 512 KB); 503
`bridge_disabled`/`unavailable`/`busy`; 504 `timeout`.

fredpd_mdt portal mode (`server/portal.lua`) vs the tablet dispatcher: no open tablet / terminal check; unknown action
or bad input → `validation`; not allowed → `unauthorized` + `portal`; the action's grant; **no duty check**; same rate
limit classes keyed by the portal actor; same routes and unwrap. `fredpd_core:portalActor` refused → `unauthorized`;
fredpd_core down → `unavailable`.

### Share view

`viewShare` has no actor. portal.lua checks the token shape (43 × `[A-Za-z0-9_-]`, else `not_found` without a DB
call) and calls `exports.fredpd_records:viewShare(token)`, which counts and audits every view (`share.view`). The
service answers 404 for `not_found`, 503 otherwise, with `Cache-Control: no-store`, `X-Robots-Tag: noindex, nofollow`,
`Referrer-Policy: no-referrer` (the token is in the URL). The page itself is the SPA's `/share/:token`.

## Hosting (closes service open question 8)

`@fastify/static` serves `PORTAL_DIR` (default `../portal/dist` relative to `apps/service`): `/` → `index.html`,
`/assets/*` `public, max-age=31536000, immutable`, everything else `no-cache`; no listings, dotfiles refused. A GET
that accepts `text/html` outside `/api/ /auth/ /avatar/ /ws /upload /internal/` gets `index.html`; everything else keeps
the JSON 404. A tunnel can now point straight at `127.0.0.1:3000`.

## Hardening review (task 7.2)

- **Headers/CSP**: helmet with an explicit CSP: `default-src 'self'`, `script-src 'self'`, `script-src-attr 'none'`,
  `style-src 'self' 'unsafe-inline'` (React style attributes), `img-src 'self' data: blob:`, `font-src 'self' data:`,
  `connect-src 'self'` (same-origin `/ws`), `object-src 'none'`, `base-uri 'none'`, `form-action 'self'`,
  `frame-ancestors 'none'`, `upgrade-insecure-requests` only when `COOKIE_SECURE`. helmet's other defaults stay
  (nosniff, HSTS, `Referrer-Policy: no-referrer`, COOP/CORP same-origin; `/avatar` keeps its own `CORP: cross-origin`).
  `Cache-Control: no-store` on every `/api/*` answer that sets none.
- **CSRF**: synchroniser token also on `/api/mdt` reads (contract), constant-time compare; SameSite=Lax cookie.
- **Uploads** (reviewed, unchanged): ≤ 5 MB (413) before buffering, magic-byte sniff png/jpeg/webp only (415), random
  names, `wx` writes, 10/min per portal session, officers only, loopback-only HMAC variant. Open: no pixel-dimension
  limit (decompression bombs) and no serving route yet; the future `GET /uploads/:file` must send the stored MIME,
  `nosniff`, `Content-Disposition: inline` and a `default-src 'none'` CSP.
- **Rate limits**: as above; FXServer side per actor per action.
- **Actor**: never from the client: citizenid = the session's (ownership re-checked per call), Discord id = the
  session's, grants = resolved live by the service; extra keys in the input are stripped by zod before forwarding and
  re-validated by `validate.lua`.

## Tests

- `pnpm exec vitest run --project service test/portal.test.ts` — **22**: action list = `portal.lua` `M.ALLOWED`;
  refused set; `fromLua`; CSP; signed `fx.portal`; (DB) characters (401, license filter, sort, empty), character
  selection (CSRF, ownership, session, audit), `/api/mdt` 401/403 csrf/no_character, 400 unknown/validation, world →
  403 portal (no FX call), forwarding (live grants, session character, cleaned input, actor keys stripped, fresh
  requestId), 403 grant and 404 intel without a round trip, FX answers → 404 intel, full error mapping incl. FX down,
  no mdt_page grant (getHome/listCharges 403 no_grant, intel 404, no FX call), intel without character 404,
  output restore/strip/drift, revoked grant and unlinked character mid-session, Discord not ready, 61st call 429,
  share 31st call per IP 429, share JSON/headers/404/503/SPA page, hosting (index, SPA route, immutable assets, dotfiles, JSON 404), and a round
  trip through the real `fredpd_mdt/server/http.js` with the real signed client (replay 409, wrong secret 401).
- `pnpm exec vitest run --project resources fredpd_mdt` — `test/http.test.ts` **20** (HMAC vectors, secrets, wiring,
  route/method/peer/size, 401s, 400/409, 503, 504, `isRemotePeer`); fredpd_mdt total 112.
- `lua5.4 tests/lua/run.lua mdt_portal` — **22** (8 with the real fredpd_core modules: grants/tier/units/Discord id from
  the set, deny wins, citizenid, duty, canView viewer, no bridge player, reuse and refresh, bad input, audit via
  portal, idle release/re-arm, `/grants` push, internal export; 14 portal.lua over the mdt harness: allowed list derived
  from dispatch.lua's classes, reads without tablet or duty, world actions refused unrouted, grants from the set,
  no mdt_page grant refuses everything (no_grant),
  domain writes with cleaned input, validation and 400s, getHome, per-actor limits, unwrap, core refusal/down,
  viewShare, request/export/JSON, main.lua wiring). Also green on `FREDPD_MDT_STACK=ox`.

## UNVERIFIED (needs FXServer / Windows)

1. JS → Lua export with a JS callback (`portalRequest(body, cb)`), and that callback invoked later from a Lua thread.
2. `GetInvokingResource()` for a same-resource JS → Lua export call is `fredpd_mdt` (or empty); both are accepted.
3. `req.address` format of FXServer HTTP requests (`ip:port` assumed; unparsable addresses are let through).
4. `TriggerClientEvent` to a stand-in id (records' `notify`, etc.) is dropped silently.
5. Lua `json.encode` of the answers (empty tables, large report bodies) and a 512 KB body through `SetHttpHandler`.
6. `scripts/install-service.ps1` was not run (no PowerShell here); `nssm set … DependOnService` with several values and
   `nssm reset`.
7. The portal build path `../portal/dist` as seen from NSSM's `AppDirectory` (`apps\service`).

## Contract additions (for docs/contracts.md; orchestrator merges)

- **§C6 service table**: `GET /api/characters`, `POST /api/session/character` (session + CSRF),
  `POST /api/mdt/:action` (session + CSRF on every call; errors above; CSRF is `{ error: 'csrf' }`, not an MDT code),
  `GET /share/:token` (Accept negotiation) and `GET /api/share/:token`; SPA hosting of `PORTAL_DIR`.
- **§C6 FXServer table**: `POST /fredpd_mdt/portal` (fredpd_mdt's own handler, §C5-signed) with the body/answers above,
  including `requestId` and 409 on replay; `grants` (GrantSet) is part of the body.
- **§C9**: fredpd_core internal export `portalActor(discordId, citizenid, grants) → src|false` (fredpd_mdt only);
  portal actor ids ≥ 1 000 000 000; server event `fredpd:portalActorReleased(src)`; `audit` adds `meta.via = 'portal'`
  for them; `isOnDuty` is true for them. fredpd_mdt export `portalRequest(body, cb)` (own resource only).
- **§C12**: portal mode (no tablet, no duty, any `mdt_page` grant required as on the tablet → `reason: 'no_grant'`,
  `reason: 'portal'` for the refused list) and the allowed list.
- New audit action `auth.character` (service).

## Integration requests

1. **fredpd_core owner**: review `server/virtual.lua` and the four small edits (above); core.md should list them.
   **fredpd_records owner**: `shares.lua` `VIEW_CALLERS` now includes `fredpd_mdt` (records.md "Share links" should say so).
2. **fredpd_records / packages/types**: the portal pages call `getPoi`, `updatePoi`, `createShare`, `revokeShare`,
   `listReleaseRequests`, `decideReleaseRequest` (apps/portal/src/mdt/extra.ts). They are not in the TS registries,
   `validate.lua` or the dispatcher yet (records.md requests 1–2), so today they answer 400 `validation`. Once added,
   put them in `PORTAL_ACTIONS` and `portal.lua M.ALLOWED` (all are portal-safe). The public "Begär ut allmän handling"
   form needs a service route for `createReleaseRequestPortal` (a second `action` on `/fredpd_mdt/portal`, like
   `viewShare`, is the natural place).
3. **packages/types owner**: move `TABLET_ACTIONS` into packages/types (NUI and service both merge the same five
   registries) and add the character/select schemas (`CharacterSchema`, `CharacterSelectSchema` in routes/portal.ts).
4. **docs/hosting.md owner**: §6 can call `scripts\install-service.ps1 -Account .\fredpd-svc`; the §7 interim note is
   obsolete (the service serves the portal; point the tunnel at `http://127.0.0.1:3000`, keep `/internal*` blocked at
   the edge); `PORTAL_DIR` in the `.env` list.
5. **Portal (apps/portal)**: 401 → session ended; 403 `reason: 'no_character'` → character picker; `reason: 'portal'`
   → `errors.portalInGameOnly`; `reason: 'no_grant'` → the same "no MDT access" view as the tablet's `tablet.noGrant`; the dev proxy needs `/share` for the JSON fetch.
6. **Locale merge**: `locales/pending/portal-api.json` (3 keys).
7. **Records owner (optional)**: `applyCharges` from the portal never jails (no actor ped); if sentences entered in the
   portal should jail an online suspect later, that needs an explicit design.
