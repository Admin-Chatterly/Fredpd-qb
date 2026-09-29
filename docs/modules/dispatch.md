<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Module: fredpd_dispatch (alerts / larm)

Tasks 3.1 (ps-dispatch patch + tables/server) and the server/client half of 3.2 (toast, "Ta larm" key, waypoint).
Implements IMPLEMENTATION.md §5.5 and docs/contracts.md §C13. Not here yet: the tablet Larm page (NUI), the portal
list (3.5), the radar/ANPR and garage bridges (3.3, 3.4).

## Files

| File | Role |
|---|---|
| `fredpd_dispatch/fxmanifest.lua` | deps `ox_lib`, `oxmysql`, `fredpd_core`; ps-dispatch and fredpd_mdt are optional (runtime checks) |
| `shared/alert_input.lua` | pure: `validateCreate` (AlertCreateInputSchema mirror), `fromPsDispatch` (hostile-data normalisation), `alertId`/`listInput`, sliding-window limiter |
| `server/alert_store.lua` | SQL on `fredpd_alerts` / `fredpd_alert_units`: the single loader, atomic status transitions |
| `server/alert_service.lua` | create / list / assignSelf / takeNewest / leave / close / getUnits; actor checks, audit, fan-out |
| `server/fanout.lua` | toasts, `fredpd_mdt:pushToOpenTablets`, signed `POST /internal/events`, throttled logging |
| `server/unit_roster.lua` | on-duty roster (UnitsPush), debounced rebuild + push, devtools fake units |
| `server/ps_bridge.lua` | `fredpd:dispatch:incoming` handler body: player-source check, rate limit, police filter |
| `server/main.lua` | exports, events, keybind callback, roster triggers, dev command |
| `client/main.lua` | toast (`lib.notify` + frontend sound), keybind `fredpd_take_alert` |
| `test/contract.test.ts`, `test/golden/*.json` | Lua output vs `packages/types/src/dispatch.ts` |
| `patches/ps-dispatch.10-fredpd-bridge.patch`, `patches/ps-dispatch.20-no-polyzone.patch` | upstream patches |

## Flow

```
ps-dispatch client preset (Shooting() …) ─TriggerServerEvent→ ps-dispatch:server:notify (stores the call)
   └─ patch: TriggerEvent('fredpd:dispatch:incoming', data, src)          [server-local, AddEventHandler]
        └─ ps_bridge: source must not be a player → jobs ∋ leo|police → 5/30 s per reporter → fromPsDispatch
             └─ createAlert(input) ── INSERT (UTC_TIMESTAMP) → toast to on-duty + mdt_page:alerts
                                      → load (isoSelect + units/officers join) → fredpd:alertCreated(alert)
                                      → pushToOpenTablets('alerts', {type='created', alert})
                                      → signedFetch POST /internal/events {type='alertCreated', payload=alert}
G ("Ta larm") → lib.callback 'fredpd:dispatch:takeNewest' → grant → 1/s → duty → claim newest open → join
   → Alert back to the client → SetNewWaypoint + notify; audit alert.assign; push 'updated'; alertAssigned
```

## Exports and events

Exports (`src`-taking ones return `{ ok = true, data }` / `{ ok = false, error, reason? }`, §C12):

| Export | Returns | Notes |
|---|---|---|
| `createAlert(data)` | `Alert` or `nil, 'validation'\|'unavailable', field?` | AlertCreateInput; must run in a thread. `message` is accepted when `title` is missing (fredpd_devtools sends it) |
| `listAlerts(src, { filter?, page? })` | AlertListOutput | `open` = open+assigned, `mine` = not closed and I am on it, `all`; newest first, 50 per page |
| `assignSelf(src, { id })` / `takeAlert` (alias, DISPATCH_ACTIONS name) | Alert | joins an open or assigned alert; idempotent (no second audit) |
| `leaveAlert(src, { id })` | Alert | last unit leaving → `open` |
| `closeAlert(src, { id })` | Alert | officer on the alert or perm `alerts.manage`; else `unauthorized` |
| `getUnits(src)` | UnitsPush | last built roster |
| `takeNewest(src)` | Alert | newest `open` alert only |

Every src-taking export re-checks grant `mdt_page:alerts`, on duty (`reason = 'off_duty'` when that is what
failed) and its input, even though the fredpd_mdt dispatcher already did. Errors: `unauthorized`, `not_found`
(missing, closed, or not on it), `validation`, `rate_limited` (keybind only), `unavailable` (DB failure).

Server events fired: `fredpd:alertCreated(alert)`, `fredpd:alertAssigned(alertId, src)` (take only),
**`fredpd:alertClosed(alertId, src)`** (additive; not in §4.3). Consumed: `fredpd:dispatch:incoming(data, src)`
(ps-dispatch patch), `fredpd:devtools:fakeUnits(units|nil)`, roster triggers below, `playerDropped`.
Client events: `fredpd:client:alertToast(AlertToast)`, `fredpd:dispatch:client:testShooting` (dev).
Service events (`POST /internal/events`): `alertCreated` (Alert), `alertAssigned` (Alert — sent on take **and on
leave**: "assignment changed"), `alertClosed` (`{ id }`), `unitsChanged` (UnitsPush).

## Design decisions

- **Status transitions are single conditional statements** (`alert_store.lua`), so concurrent actions cannot
  produce an impossible state: keybind claim `UPDATE … SET status='assigned' WHERE id=? AND status='open'` (one
  winner; the loser tries the next open alert, 3 attempts), join `INSERT IGNORE … SELECT … WHERE status IN
  ('open','assigned')`, leave `DELETE … JOIN … status <> 'closed'` then reopen `… WHERE status='assigned' AND NOT
  EXISTS (units)`, close `… WHERE status IN ('open','assigned')`. Every UPDATE changes the row it matches (status or
  `updated_at`), so affectedRows is the same with or without mysql2's CLIENT_FOUND_ROWS.
- **Keybind vs tablet take**: the key only claims `open` alerts (two officers pressing G at once get different
  alerts); the tablet's take joins an already assigned alert as an extra unit. Both mark the alert `assigned` again
  after their unit row is in (a tablet join + leave between the key's claim and its join would otherwise leave an
  `open` alert with a unit).
- **Close wins races**: when a close commits between a join/leave and its read-back, the close's `{ type = 'closed' }`
  push stands: no `updated` push, no `alertAssigned` (server or internal) follows. The late joiner gets `not_found`
  (the key tries the next open alert); the join is still audited (`meta.closedMeanwhile = true`, the unit row exists);
  a late leave returns the closed alert.
- **Timestamps**: all writes `UTC_TIMESTAMP()`; reads `Time.isoSelect` (`created_at`, `closed_at`); `updated_at`
  set by every writer. Tested with the session at `+02:00`.
- **Toast before read-back**: the toast only needs the new id, so it is sent right after the INSERT (§5.5 "within
  100 ms"), before the loader query. Recipients: every online player for whom `hasGrant(mdt_page, alerts)` (checked
  first, in-memory) and `isOnDuty` hold.
- **Toast text is markdown-escaped on the client**: ox_lib renders `lib.notify`'s `description` with react-markdown,
  and code/title/street come from ps-dispatch, i.e. from any client (`ps-dispatch:server:notify`). Every ASCII
  punctuation character of those values (and of the key name) is backslash-escaped and control characters become
  spaces, so no image (IP leak, screen cover), link, heading, list or code span can be built; the locale template
  itself stays markdown (the `'  \n'` line break). Values are cut to the server's limits in UTF-8 characters (code 16,
  title 160, street 128), never inside a character, and invalid bytes are dropped before escaping.
- **Pushes** go only through `exports.fredpd_mdt:pushToOpenTablets(topic, payload)` (pcall; skipped while
  fredpd_mdt is not started); nothing is `TriggerClientEvent`'d to tablets directly.
- **Service calls** use `exports.fredpd_core:signedFetch` with a callback (never awaited); failures are logged at
  most once a minute per kind.
- **ps-dispatch data is hostile**: only whitelisted keys are read (never `pairs(data)`), strings are cut to a few
  bytes per allowed character *before* scanning, control characters and invalid UTF-8 are removed (the INSERT cannot
  fail on them), coords must be three finite numbers within ±10000 (else the call is dropped), priority is clamped to
  1–3 (ps-dispatch's critical 0 → 1), EMS-only calls (`jobs` without `leo`/`police`) are ignored. The description is
  built from `information` plus Swedish labels (`alert.detail.area|vehicle|weapon|caller`); the other details go to
  `meta` (never on the wire). The reporter's identity is **not** stored: for most presets the reporter is the suspect.
- **Offset alerts stay approximate (decision, see Open questions 4).** ps-dispatch deliberately shows officers only a
  displaced position for the blip types with `offset = true` (shooting, vehicleshots, fight, vehicletheft, carjack,
  explosion, houserobbery, susactivity, suspicioushandoff): `displayCoords`, somewhere within `mapRadius` (60–130 m)
  of the truth, and it never sends the true `coords` to a client. FredPD keeps that balance: when `displayCoords` is
  present the Alert's `coords` (keybind waypoint, tablet, portal) are `displayCoords`, the description gets the line
  "Ungefärlig plats (inom N m)" (`alert.detail.area`, when `mapRadius` is usable), and the true position is stored
  only in `fredpd_alerts.meta` (`exactX/exactY/exactZ`, plus `mapRadius`), which no export or event returns. A
  malformed `displayCoords` drops the call like malformed `coords`. Alerts without an offset keep their exact coords.
- **Rate limits**: 5 police calls / 30 s per reporting player (§C13; EMS-only calls are filtered out *before* the
  limiter, so a downed player's /311 or InjuriedPerson reports cannot use up the budget for a real 911 or Shooting
  report); reporter `nil`/`0` (server-generated) share one bucket of 30 / 30 s; keybind 1/s per player on the server
  plus a 750 ms client debounce and an in-flight lock of at most 5 s, released only by the reply to the newest request
  (a late reply to an older one cannot unlock the key while a newer request is pending). Buckets are dropped on
  `playerDropped`.
- **Units roster**: rebuilt from `exports.fredpd_core:getPlayers()` (players with a character, through the §C17
  bridge) + `isOnDuty`/`getOfficer` (Discord name + callsign from fredpd_officers; the FiveM account name until the
  row exists, never the character name) and one query for each officer's newest non-closed alert. Triggers
  (`AddEventHandler`, server-local): fredpd_core's normalised `fredpd:bridge:dutyChanged`, `fredpd:bridge:jobChanged`,
  `fredpd:bridge:playerLoaded`, `fredpd:bridge:playerUnloaded` (qb-core or qbx_core), `playerDropped`,
  `fredpd:officerChanged`, take/leave/close, devtools fake units. Debounce: `SetTimeout`, first
  change waits 250 ms, pushes ≥ 2 s apart, an unchanged roster (fingerprint) is not pushed again.
- **Lua cannot send `null`.** Nullable Alert fields (`description`, `coords`, `street`, `closedBy`, `closedAt`) and
  OfficerRef `callsign`/`unit`, UnitStatus `alertId` are *absent* on every Lua → JS hop (msgpack, and
  `JSON.stringify` in signedFetch). Empty lists arrive as `[]`. See Integration requests.
- **Dev command** `/fredpd_testalert`: only registered with `set fredpd_dev true`, `restricted = 'group.admin'`.
  ps-dispatch's presets are **client** exports (docs/deps-verification.md), so with ps-dispatch running the server
  asks the caller's client to run `exports['ps-dispatch']:Shooting()` (the whole patched path); from the console or
  without ps-dispatch it calls `createAlert` with a fake shooting (`source = 'devtools'`).

## Framework bridge (docs/contracts.md §C17)

fredpd_dispatch calls no framework resource (static check in `tests/lua/dispatch_bridge_test.lua`):

| Before (qbx only) | Now (qb and ox stacks) |
|---|---|
| roster triggers `QBCore:Server:SetDuty`, `…:OnJobUpdate`, `…:PlayerLoaded`, `…:OnPlayerUnload`, `qbx_core:server:playerLoggedOut` | `fredpd:bridge:dutyChanged`, `jobChanged`, `playerLoaded`, `playerUnloaded` (deduplicated by the bridge; qb-core's drop unload included) |
| player lists (toasts, roster) from the `GetPlayers()` native | `exports.fredpd_core:getPlayers()` (qb-core `Functions.GetPlayers` / qbx_core `GetQBPlayers`: only players with a character, so civilians in the character menu cost nothing); `{}` + a throttled error if fredpd_core cannot answer |
| audit actor via qbx_core (fredpd_core) | unchanged code: fredpd_core's audit resolves it through the bridge |

**ps-dispatch on qb-core** needs no FredPD change: it is a qb-core resource (`exports['qb-core']:GetCoreObject()`,
server/main.lua:6-7; Qbox reaches it through qbx_core's qb-core `provide`). The patch's
`TriggerEvent('fredpd:dispatch:incoming', data, src)` sits in the framework-independent part of the
`ps-dispatch:server:notify` handler (after the call is stored, before `broadcastCall`); the QBCore branch only
decides who gets ps-dispatch's own popups (`QBCore.Functions.GetQBPlayers()` job/duty filter, off by default).
Verified by `dispatch_bridge_test`: both patches apply to the pinned commit in a temporary copy, the patched
`server/main.lua` runs with qb-core's `GetCoreObject`, a stored Shooting() fires the event with the reporter, merged
repeats and invalid reports do not, `shared/alert_input.lua` normalises the data, and with
`setr fredpd_psdispatch_ui true` the popups go to on-duty leo players only.

## ps-dispatch patches (apply inside `resources/[upstream]/ps-dispatch`)

`patches/ps-dispatch.10-fredpd-bridge.patch` (ps-dispatch has no NUI-off config flag, docs/deps-verification.md §4):

| Hunk | Change | Why |
|---|---|---|
| server/main.lua, after the QBCore lookup | `local fredpdUi = GetConvar('fredpd_psdispatch_ui', 'false') == 'true'` | one switch, default off |
| server `broadcastCall` | `if not fredpdUi then return end` | no `ps-dispatch:client:notify` to officers (bandwidth; FredPD toasts instead) |
| server `ps-dispatch:server:notify`, after `data.listed = true` | `TriggerEvent('fredpd:dispatch:incoming', data, src)` | the bridge, at the point the call is stored (true coords still in `data`; merged repeats are not new calls) |
| client/main.lua top | same convar local (client reads **replicated** convars: `setr`) | |
| client keybinds | `RespondToDispatch`/`OpenDispatchMenu` (E/O) only registered when the UI is on | E is the interact key; FredPD has G |
| client `ps-dispatch:client:notify` | early return when off | covers targeted alerts and third-party senders (popup, blip, sound, NUI message) |
| client `ps-dispatch:client:openMenu` | early return when off | `/dispatch` would take NUI focus for a hidden board |
| server callback `ps-dispatch:callback:getLatestDispatch` | returns `nil` when off | no job check upstream: any client could read the newest call with its **true** coords, caller name and phone; only the (unregistered) E key uses it |
| server callback `ps-dispatch:callback:getCalls` | returns `{}` when off | same, for the whole (public) call list; only the menu/NUI uses it |
| server command `/dispatch` | registered only when on | it sent `publicCalls()` to any player; not even shown as a command while off |
| shared/config.lua | `Config.Debug = false` (upstream `true`) | deps-verification Decision 3. `true` makes on-duty officers who shoot or speed raise Shooting/Speeding alerts (→ FredPD alert + toast to every officer) and draws the no-dispatch zones (Ammu-Nation boxes, 650 m hunting sphere) every frame for every player. The preset exports (`Shooting()` …) do not read it |
| shared/config.lua | `Config.TestCommand = false` (upstream `'dispatchtest'`, "set false in production") | upstream registers `/dispatchtest` as an **unrestricted** client command (`RegisterCommand(…, false)`): any player could fire its ~11 demo alerts (OfficerDown, OfficerInDistress at priority 1 …), and through the bridge each becomes a stored FredPD alert, a toast with the priority sound to every on-duty officer, a tablet push and a portal event, again and again (only the 5/30 s reporter limit in between). The same flag also removes the client sound check `/dispatchsound`. The acceptance helper is `/fredpd_testalert` (dev convar + `group.admin`) |

Everything else of ps-dispatch keeps working: call storage and merges, `/911`/`311`, the alert presets and
`CustomAlert`, `GetDispatchCalls`. **Targeted alerts are lost while the UI is off**: `SendTargetedAlert` /
`ps-dispatch:server:targetAlert` only send `ps-dispatch:client:notify` to the chosen players (which the client hunk
drops) and never pass `ps-dispatch:server:notify`, so they are neither shown by ps-dispatch nor mirrored to FredPD,
even with `addToList = true` (Open questions 3; no FredPD resource sends them, ps-mdt's PlateCheckAlert is their
known user). To get ps-dispatch's own UI back (popups, E/O keys, `/dispatch`, the call-list callbacks, targeted
alerts): `setr fredpd_psdispatch_ui true`. `/dispatchtest` stays off either way (config hunk). `ui_page` stays (an
idle frame).

`patches/ps-dispatch.20-no-polyzone.patch`: removes the three `@PolyZone/*` client includes from `fxmanifest.lua`;
no ps-dispatch code uses PolyZone (zones are `lib.zones`) and Qbox servers usually do not run it.

**lsn-radar** is not a dependency (not in the fxmanifest, not referenced by code): no hunk needed.

Verify: `node scripts/fetch-deps.mjs --only ps-dispatch && node scripts/apply-patches.mjs` (both apply cleanly on the
pinned commit d488316), then `git -C "resources/[upstream]/ps-dispatch" checkout -- .` to keep the checkout clean.

## Tests

- **Stacks**: `lua5.4 tests/lua/run.lua dispatch_` → **80 passed** with the default qb stack and with
  `FREDPD_STACK=ox` (qbx_core); `dispatch_server_test` runs the real fredpd_core bridge over the stack's framework mock
  (getPlayers, audit actor, the framework's `QBCore:Server:SetDuty` → `fredpd:bridge:dutyChanged` → roster).
  `dispatch_bridge_test` (11): static check, 4 server tests re-run on both stacks, the ps-dispatch qb-core path (2).
  `dispatch_stack_test` (2) is the shared stack helper for bolo/dispatch/breach tests (`FREDPD_STACK`).
- Earlier count: `lua5.4 tests/lua/run.lua dispatch` → **51 passed** (`dispatch_input_test` 17, `dispatch_server_test` 24 against
  MariaDB database `fredpd_test_dispatch_lua`, sessions at `+02:00`, `dispatch_client_test` 10). Covers hostile ps-dispatch
  data (2 MB strings, NaN/inf/out-of-range coords, priority 99/0, missing fields, invalid UTF-8, EMS calls), offset
  alerts (displayCoords on the wire, true coords only in meta), the reporter rate limit (EMS-only calls not counted),
  player-sourced incoming, createAlert round trip + fan-out, toasts only to on-duty grant holders, no client event
  but toasts (tablet pushes only via `pushToOpenTablets`; none at all on take/leave/close), internal events, audit
  rows (real fredpd_core audit module),
  concurrent take (interleaved claim), join/leave losing to a close (no `updated` push), keybind take after a
  tablet join + leave (stays `assigned`), markdown in toast data escaped, leave → open, close rules (`unauthorized` without assignment/`alerts.manage`),
  takeNewest ordering, list filters/paging, export re-checks, roster debounce, main.lua wiring, the dev command,
  UTC timestamps, locale keys, no `NOW()`/`CURRENT_TIMESTAMP`; client: toast text cut by UTF-8 characters, the
  keybind lock tied to its request.
- `pnpm exec vitest run --project resources contract` → **20 passed**: the 17 golden files
  (Alert ×4, list ×2, units, toast ×2, push ×3, internal ×4, normalised ps-dispatch input) parse with
  AlertSchema / AlertListOutputSchema / UnitsPushSchema / AlertToastSchema / AlertPushSchema /
  DispatchInternalEventSchema / AlertCreateInputSchema after restoring Lua's absent nulls, with no unknown keys.
  Golden files are regenerated by `dispatch_server_test` (deterministic ids/timestamps; rewritten only on change).
- Type check: `pnpm exec tsc -p "resources/[fredpd]/fredpd_dispatch/test/tsconfig.json"` (not part of `pnpm lint`,
  same as fredpd_core's test).

## UNVERIFIED (needs a running FXServer)

1. `source` inside the `fredpd:dispatch:incoming` handler is `''` when ps-dispatch fires it from inside its own net
   handler (FiveM resets `source` per event; ox_doorlock relies on the same).
2. `createAlert` awaiting oxmysql inside an export / event handler called from another resource (FiveM runs them in
   a coroutine and returns the async result; the pattern is common, not tested here).
3. ox_lib `lib.notify` `id` replaces an existing toast with the same id; `style`, `iconColor` and the markdown line
   break (`'  \n'`) render as intended; backslash-escaped punctuation (`10\-11`) renders as the plain character in
   ox_lib's react-markdown 8 (CommonMark says so; not seen in game); `keybind:getCurrentKey()` returns a printable key
   name.
4. The stock sounds `TIMER_STOP`/`HUD_MINI_GAME_SOUNDSET` and `Event_Message_Purple`/`GTAO_FM_Events_Soundset`.
5. Client `GetConvar('fredpd_psdispatch_ui', …)` sees the value only when set with `setr`.
6. `GetEntityCoords(GetPlayerPed(src))` server-side for the dev command (OneSync).
7. Toast latency ≤ 100 ms (§5.5 acceptance): one INSERT before the toasts, measured only in game.
8. Offset alerts reach the bridge with `displayCoords`/`mapRadius` already set (read from the pinned source:
   `resolveBlipMeta` runs before the hook), not observed in game. The client's `utf8.len(s, i, j)`/`utf8.codepoint`
   behave as in stock Lua 5.4 (CfxLua is 5.4; tested with lua5.4 only).

## Integration requests (owners other than this module)

- **fredpd_mdt**: merge `DISPATCH_ACTIONS` into the dispatcher: `listAlerts → exports.fredpd_dispatch:listAlerts`,
  `takeAlert → takeAlert` (or `assignSelf`), `leaveAlert`, `closeAlert`, `getUnits`; unwrap `{ ok, data | error }`
  (an extra `reason` field may be present). Provide `exports('pushToOpenTablets', function(topic, payload) … end)`
  (this module calls it with exactly those two arguments) and send topics `alerts` and `units` only to open tablets
  whose owner holds `mdt_page:alerts` **and** is on duty (`exports.fredpd_core:isOnDuty(src)`, checked per push,
  not only when the tablet opened) — the same rule as the toast; an officer who goes off duty with the tablet open
  must stop receiving live alerts and units. (Alternative, if preferred: accept an optional recipient filter
  argument; this module would then pass the duty + grant check itself.) In the NUI push handler, restore absent nullable keys to `null` before a
  strict zod parse (see `restoreNulls` in `fredpd_dispatch/test/contract.test.ts`; worth moving into packages/types).
- **NUI (apps/nui)**: Larm page — list via `listAlerts` (Öppna/Mina/Alla), live `alerts` push (`created` prepend,
  `updated` replace, `closed` remove), units panel from `getUnits` + `units` push, "Tilldelad: {callsign} · {name}"
  (`alert.assigned`), actions take/leave/close/waypoint.
- **fredpd_service**: `/ws` must forward `alertCreated|alertAssigned|alertClosed|unitsChanged` only to users whose
  grants include `mdt_page:alerts`; payloads arrive without null keys (Lua), `alertAssigned` is also sent on leave.
- **fredpd_devtools**: `/fredpd_fakeunits` calls `createAlert({ …, message = … })`; please send `title` (the alias
  stays for now). Its `fredpd:devtools:fakeUnits` snapshots are already shown in the roster.
- **docs/contracts.md §C13** (contract owner): record the additive `fredpd:alertClosed(alertId, src)` event, that
  `alertAssigned` doubles as "assignment changed" (leave), `createAlert`'s return (`Alert` or `nil, code`), the
  keybind error `reason = 'off_duty'`, the second patch file, and the Lua-null rule above.
- **server.cfg.example**: `ensure ps-dispatch` before `ensure fredpd_dispatch` (after fredpd_core); no PolyZone
  needed with patch 20; optional `setr fredpd_psdispatch_ui true`; dev servers `set fredpd_dev true`.
- **locales**: merge `locales/pending/dispatch.json` (10 keys) with `node scripts/merge-pending-locales.mjs`.
- **service permission catalog**: perm `alerts.manage` (already in §C13).

## In-game test (§5.5 acceptance; for docs/test-phase-3.md)

1. Build + apply patches (`node scripts/build.mjs`, `node scripts/fetch-deps.mjs`, `node scripts/apply-patches.mjs`),
   `set fredpd_dev true`, ensure order ps-dispatch → fredpd_core → fredpd_dispatch; restart.
2. Two officers with Discord role granting `mdt_page:alerts`, both `/duty` on; a third player off duty.
3. Officer A runs `/fredpd_testalert`: both on-duty officers get the "Nytt larm" toast with code, title, street and
   "Tryck G …" plus a sound within ~100 ms; the off-duty player gets nothing; no ps-dispatch popup/blip appears.
4. Officer B presses G: waypoint set (Shooting is an offset alert: somewhere within 110 m of A, the description says
   "Ungefärlig plats (inom 110 m)"), "Du har tagit larmet. Vägpunkten är satt."; A's open tablet shows
   "Tilldelad: <B's callsign> · <name>" (needs the Larm page).
5. A presses G within a second: "Inga öppna larm." (no second open alert).
6. Fire a gun as a civilian near an NPC (ps-dispatch detection): a real ps-dispatch alert arrives the same way.
7. B closes the alert on the tablet: it disappears from every open tablet; A (not assigned, no `alerts.manage`)
   closing another alert gets "Du har inte behörighet".
8. Check `fredpd_audit`: `alert.assign` (meta via keybind) and `alert.close` rows with B's citizenid.
9. Go off duty and press G: "Du är inte i tjänst."; as a civilian pressing G: nothing happens, and `/dispatchtest`
   is not a command.
10. `/fredpd_fakeunits 5 30`: the units panel shows the fake units, and alerts every 5 s arrive as toasts.

## Open questions

1. Should an officer who goes off duty or disconnects leave their alerts automatically (ps-dispatch does ghost-unit
   cleanup)? Today the alert stays `assigned` until someone leaves/closes it (Ledning can close with `alerts.manage`).
2. Old open alerts are never expired; a manual/commanded "close stale alerts" (no timer) may be wanted later.
3. ps-dispatch merged repeat reports (×N, escalation to priority 1) are not mirrored; an `alertUpdated` bridge would
   need a second hunk in `tryMergeCall`. Likewise targeted alerts (`SendTargetedAlert`, `ps-dispatch:server:targetAlert`)
   are dropped while the ps-dispatch UI is off. If a resource that sends them is ever used, either mirror them (a
   hunk in `sendTargetedAlert`, plus a FredPD path that toasts only the chosen players instead of every on-duty
   officer) or drop the client hunk's early return in `ps-dispatch:client:notify` (with the UI off, `broadcastCall`
   sends nothing, so only targeted alerts arrive there; they would show ps-dispatch's own popup).
4. (For Rami) Offset alerts: FredPD shows the approximate position ps-dispatch shows (Design decisions). If officers
   should get the exact spot instead (waypoint straight to the shooter), swap `coords` for `meta.exactX/Y/Z` in
   `fromPsDispatch`; that changes ps-dispatch's intended balance for shootings, fights, thefts and explosions.
