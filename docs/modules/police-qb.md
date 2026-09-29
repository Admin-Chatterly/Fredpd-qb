<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Module: QBCore police job integration (resource `qb-policejob`) + qb-core items

The QBCore twin of [police.md](police.md) (qbx_policejob), per docs/contracts.md §C17 "Police job":
`patches/qb-policejob.*.patch` is the primary target, the qbx patches stay for Qbox servers. Upstream is never
edited; `node scripts/apply-patches.mjs` applies the patches in name order. Line numbers are **upstream at the pin**
unless marked "patched".

Pins (deps.lock.json): qbcore-framework/qb-policejob@3ad3d19, qb-core@9b3cddc, qb-inventory@dc3d07f,
qb-target@a3ea78b, qb-doorlock@4a8e911. xt-prison@85fd705 (no licence: only its events/exports are named here).

## Files

| File | Role |
|---|---|
| `patches/qb-policejob.10-grants.patch` | adds `fredpd/server.lua` (global `FredPD`: grants bridge, config, rate limit, garage, spawn, armory, qb-inventory hooks) and `fredpd/client.lua` (armory zones + menu); edits `server/{main,commands,interactions,objects,vehicle}.lua`, `client/job.lua`, `client/interactions.lua`, `fxmanifest.lua`, `locales/en.lua` (`fredpd.*`) |
| `patches/qb-policejob.20-fredpd-replacements.patch` | built-in evidence off only with `hasFeature('evidence')`; `police_stormram` trunk item only with `setr fredpd_police_legacy true` |
| `patches/qb-policejob.30-bolo-hooks.patch` | adds `fredpd/server_bolo.lua` (global `FredPDBolo`); `client/anpr.lua`, radar handler, `IsPlateFlagged`, impound hook |
| `patches/qb-policejob.40-sv-locale.patch` | new `locales/sv.lua` (every en.lua key), `hud.*` / `info.open` for text that was hard-coded (NUI, evidence drawer) |
| `patches/qb-core.10-fredpd-items.patch` | `pd_tablet`, `pd_ram` in qb-core `shared/items.lua` |
| `config/police.json` `qbPolicejob` | qb-only overrides (actions `evidence`/`search`/`seizelicense`, garage, armories with qb item names, `qbShops`, `maxFine`); shared `actions` and `radar` are reused |
| `locales/pending/police-qb.json` | label for the new audit action `police.unjail` |
| `tests/lua/qbpolice_*_test.lua` | 59 tests (harness in `qbpolice_harness_test.lua`) |

`fredpd/*.lua` are plain Lua 5.4 (luac clean, SPDX header, no loops/timers). The patched fxmanifest loads
`fredpd/server.lua` right after `server/main.lua` (which sets `QBCore`) and then the glob `fredpd/server_*.lua`
before `server/commands.lua` (test-enforced order), so every upstream server file sees `FredPD`/`FredPDBolo`.
`config/police.json` is read server-side only with `LoadResourceFile('fredpd_core', 'config/police.json')`
(copied by `scripts/build.mjs`; missing → identical built-in defaults, test-enforced); reloaded when fredpd_core
restarts.

## Upstream facts (qb-policejob@3ad3d19)

- Every command checks `Player.PlayerData.job.type == 'leo' and job.onduty` inline (server/commands.lua:15-358,
  server/vehicle.lua:78-115); `/grantlicense`/`/revokelicense` use `grade.level >= Config.LicenseRank` (:15, :39);
  `/fine` any leo, duty not checked, crashes on a missing amount (:167-209); `/paylawyer` leo or `judge` (:334).
- Net events with weak or no checks: `BillPlayer` (interactions.lua:111-126, leo only, any amount incl. negative),
  `JailPlayer` (:128-152, leo only), `SeizeCash` (:154-171, leo), `SeizeDriverLicense` (:173-192, **anyone**),
  `SetTracker` (main.lua:199-222, **anyone**), `Impound` (vehicle.lua:37-49, **no check**), `TakeOutImpound`
  (:51-59, distance only), `spawnObject`/`deleteObject`/`SyncSpikes` (objects.lua:16-29, **no check**, broadcast to
  -1), `police:GetImpoundedVehicles` (vehicle.lua:10-18, every row to any client).
- `UpdateBlips` loops `for i = 1, #players` over the source-keyed `GetQBPlayers()` map (main.lua:11).
- **No armory code**: only the leftover `Config.ArmoryWhitelist = {}` (config.lua:6). Items come from the trunk
  (`Config.CarItems`, config.lua:120-124, `SetCarItemsInfo` client/job.lua:88-110) or a qb-inventory shop.
- Garage list is built client-side from `Config.AuthorizedVehicles[0..grade]` (client/job.lua:207-225) and spawned
  with qb-core's **unchecked** callback `QBCore:Server:SpawnVehicle` (qb-core server/events.lua:275; garage
  client/job.lua:177, impound :157, helicopter :489, with client coordinates).
- Evidence: nine `evidence:server:*` events (server/evidence.lua:67-162), commands `clearcasings`, `clearblood`,
  `takedna` (commands.lua:212-248), four client loops (client/evidence.lua:196-356).
- Stormram: only the trunk entry config.lua:123 (item qb-core shared/items.lua:354); no code uses it.
- Radar: `Config.EnableRadars = true` (config.lua:107); the **driver** asks `police:server:IsPlateFlagged`
  (client/anpr.lua:22-27) and then sends client coords + plate to `police:server:FlaggedPlateTriggered`
  (vehicle.lua:61-73, trusted entirely; recipients `job.name == 'police'` on duty).
- Jail: `police:server:JailPlayer` sets `injail`/`criminalrecord` and sends `police:client:SendToJail`
  (interactions.lua:145-151) → client `TriggerEvent('prison:client:Enter', time)` (client/main.lua:211-218).
  **xt-prison also handles `police:server:JailPlayer`** (xt-prison bridge/compat/server.lua:20-31, gated by its own
  `PoliceJobs` only) and `prison:client:Enter` (bridge/compat/client.lua:4-7): upstream, one jail = two entries.
- Locale: qb-core `Locale` (shared/locale.lua:95 `Locale:t`), files `locales/*.lua` each ending with
  `if GetConvar('qb_locale', 'en') == '<lang>' then Lang = Locale:new({ ..., fallbackLang = Lang }) end`
  (e.g. locales/de.lua), en.lua sets `Lang = Lang or Locale:new(...)`; fxmanifest shared_scripts load en.lua first.
- qb-inventory@dc3d07f **has hooks** (docs/contracts.md §C17 says it has none — see request 4): `AddHook(type, fn)`
  (server/functions.lua:905-921), `false` cancels (server/hooks.lua:1-22); `ShopOpened` fn(shopType,
  { source, shop, ... }) (functions.lua:611-612), `ItemBought` fn(shopType, { toId, item, amount, ... })
  (server/main.lua:455-457); hooks of a stopped resource are dropped (main.lua:147-166).

## Patch 10 — grants

`FredPD.check(src, action)`: **nil while fredpd_core is not `started`** (caller applies the upstream condition via
`FredPD.allowed(src, action, upstreamOk)`), else `exports.fredpd_core:isOnDuty(src)` then, for a mapped action,
`hasGrant(src, type, key)`. Export error or unmapped action = refusal (fail closed, one warning). Refusal message:
`fredpd.no_permission` when on duty, else `error.on_duty_police_only`.

| Action | Grant (config/police.json) | Used by |
|---|---|---|
| `impound` | `perm:police.impound` | `/impound`, `/depot`, net `Impound`, `TakeOutImpound`, `GetImpoundedVehicles`, impound spawn |
| `jail` | `perm:police.jail` | `/jail`, `/unjail` (+ valid target, audit `police.unjail`), net `JailPlayer`/`fredpdJailPlayer` |
| `license` | `perm:police.license` | `/grantlicense`, `/revokelicense` (upstream: grade ≥ LicenseRank) |
| `fine`, `bill` | `perm:charges.fine` | `/fine`, net `BillPlayer` |
| `flagplate`, `unflagplate` | `perm:bolo.create`, `perm:bolo.resolve` | `/flagplate`, `/unflagplate` |
| `cuff`, `object`, `spikestrip`, `camera`, `seizecash`, `tracker`, `anklet`, `plateinfo`, `paytow`, `paylawyer`, `evidence`*, `search`*, `seizelicense`* | `duty` | the matching commands / net events (* qb-only, `qbPolicejob.actions`) |

Hardening in **both modes**: bill/`/fine` whole amount 1..`maxFine` (100 000 kr), jail whole months ≥ 1,
`/unjail` refuses `-1`/unknown ids, objects only `Config.Objects` types and ≤ `Config.MaxSpikes` sanitised spikes,
impound price whole ≥ 0, `TakeOutImpound` only a known lot and only a `state = 2` row, `pairs` in `UpdateBlips`.
Rate limits (`FredPD.rateLimit`, after the grant check, cleared on `playerDropped`): bill, jail, `/fine`, `/paytow`,
`/paylawyer`, spawn 1/2 s; impound, take-out, seizecash, tracker, armory take, radar 1/s; objects, armory open
1/500 ms. `/fine`, `/paytow`, `/paylawyer` answer `fredpd.try_again`.

**Jail + xt-prison**: the patched client sends `police:server:fredpdJailPlayer` (patched client/interactions.lua:157);
the server serves it and, only while xt-prison is **not** started, the old `police:server:JailPlayer`. So with
xt-prison a jail is grant-checked and enters the prison once (qb `SendToJail` → `prison:client:Enter` → xt-prison
compat). A modified client can still fire the old name at xt-prison's own handler (xt-prison's job check only) —
request 2.

**Garage/helicopter/impound spawn**: new callbacks `police:server:fredpdGarageVehicles` (FredPD: candidates =
`qbPolicejob.garage.vehicles` or every `AuthorizedVehicles` model, filtered by `vehicle:<model lower>`, empty off
duty; fallback: upstream grade list for an on-duty leo) and `police:server:fredpdSpawnVehicle(kind, model, index,
plate)`: the client names only a location **index**; coordinates come from `Config.Locations`; officer ≤ 15 m;
garage: grant re-check, plate `info.police_plate` + 4 digits; helicopter: `Config.PoliceHelicopter` +
`vehicle:polmav`, nearest pad when no index, `ZULU` plate; impound: impound grant + `player_vehicles` row with that
plate, `state = 2` and that model. Spawn via `QBCore.Functions.SpawnVehicle` (qb-core server/functions.lua:331).

**Armory** (FredPD only; `qbPolicejob.armories`, default `mrpd` at 462.23, -981.12, 30.68): qb-target circle zone
(`Config.UseTarget`) or PolyZone box + qb-menu header → `police:server:fredpdArmory(id)` sends only granted items
(`weapon:<name>` for `weapon_*`, else `armory:<name>`) after on duty + `armory:<id>` + distance;
`police:server:fredpdArmoryTake(id, item)` re-checks all of it, item `max` (qb-inventory `GetItemCount`,
functions.lua:357), `CanAddItem` (:384), `AddItem(src, item, count, false, info, 'qb-policejob:fredpd-armory')`
(:711), ItemBox, audit `police.armory`. Items are signed out, not bought. **qb-inventory shops** (e.g. a qb-shops
police shop) listed in `qbShops` get `ShopOpened` (on duty + `armory:<id>`) and `ItemBought` (+ item grant) hooks;
no opinion while fredpd_core is stopped; re-registered when qb-inventory restarts. The shop still lists every item.

## Patch 20 — replacements

- Evidence: `FredPD.evidenceReplaced()` = fredpd_core started **and** `exports.fredpd_core:hasFeature('evidence')`
  (true only with ox_inventory + ox_target + evidences, fredpd_core server/bridge.lua:161-169). Then the nine
  `evidence:server:*` events, `/clearcasings`, `/clearblood`, `/takedna` return early and the client loops stop.
  Clients ask `police:server:fredpdEvidence` at start and get `police:client:fredpdEvidence` when fredpd_core,
  fredpd_forensics or evidences start/stop (only on change). **On a qb-inventory server evidence stays on.**
- Stormram: `Config.CarItems[3]` exists only with `GetConvar('fredpd_police_legacy') == 'true'` (use `setr`;
  config.lua is shared). The ram is fredpd_breach's `pd_ram`.

## Patch 30 — BOLO hooks

- Client (patched client/anpr.lua:21-28): every radar pass of a driver is reported as `(radarIndex, plate,
  street)`, no `IsPlateFlagged` pre-check (a driver never learns whether its plate is wanted).
- Server `FlaggedPlateTriggered`: accepted only from the driver's seat of a vehicle whose plate equals `plate`,
  ≤ `radar.maxDistance` (50 m) from `Config.Radars[index]`, 1/s. `exports.fredpd_bolo:checkPlate(normalised)`
  (pcall, only while fredpd_core + fredpd_bolo run) → `TriggerEvent('fredpd:boloHit', bolo, { source = 'radar',
  plate, coords, street, radar })` once per plate and radar per `radar.cooldownSeconds` (60). Same context as the
  qbx patch (police.md "Patch 30"); no `officer` (the reporter is the wanted car's driver).
- Alert: efterlysning + fredpd_dispatch started → none (fredpd_bolo raises the larm); fresh hit + fredpd_dispatch
  down → qb alert `fredpd.bolo_radar` to on-duty `police` job players (upstream recipients); otherwise the upstream
  `/flagplate` alert (`info.flagged_vehicle_radar`) if flagged.
- `police:server:IsPlateFlagged`: while fredpd_core runs only on-duty officers get a true answer; flags only.
- Impound: after `police:server:Impound` succeeds (owned or not, `/depot` and `/impound`):
  `exports.fredpd_bolo:resolveOnImpound(normalisedPlate, src)` (pcall) via `FredPD.impoundHooks`.

## Patch 40 — Swedish

`locales/sv.lua`: every key of the patched en.lua (≥ 200, same `%{name}` placeholders, test-enforced), glossary
terms (polis i tjänst, behörighet, vapenförråd, efterlysning, ANPR-kamera, kr, no `!`). `info.police_plate` stays
`LSPD` (a 4-letter plate prefix, not text). Selected by **`setr qb_locale "sv"`**; other languages fall back to en
for the new keys. `info.open` replaces the hard-coded `'open'` (client/job.lua:452); the NUI's English
(html/script.js fingerprint/heli/CCTV) becomes `hud.*` sent with the NUI messages (defaults kept in `Labels`).

## qb-core items (patches/qb-core.10-fredpd-items.patch)

Same shape as the neighbouring qb-core entries (name, label, weight, type, image, unique, useable, shouldClose,
description; shared/items.lua:353-354): `pd_tablet` "Surfplatta" (unique, useable, image `tablet.png`; `info.serial`
/ `info.owner` are set server-side when Ledning issues it) and `pd_ram` "Murbräcka" (unique, not useable, image
`police_stormram.png`). Both images exist in qb-inventory html/images at its pin (test-enforced).

## Tests

`lua5.4 tests/lua/run.lua qbpolice` → **59 passed** (harness 7, grants 16, armory 12, evidence 6, bolo 12, locale 6).
The harness `git archive`s the pins of qb-policejob and qb-core, applies the patches, and runs the patched files
with FiveM/qb-core (real `shared/locale.lua`)/qb-inventory/oxmysql/fredpd_core/fredpd_bolo mocked. Without the
upstream checkouts all qbpolice tests skip with one notice; `FREDPD_REQUIRE_UPSTREAM=1` makes that a failure.
luac5.4 rejects `client/evidence.lua`, `client/interactions.lua`, `client/objects.lua`, `config.lua`,
`server/main.lua` for upstream cfxlua syntax only (test-enforced list); they load after the test rewrite.

## UNVERIFIED in FiveM

1. Server-side `GetVehiclePedIsIn`/`GetPedInVehicleSeat`/`GetVehicleNumberPlateText` under OneSync (radar check).
2. `GetConvar('fredpd_police_legacy')` in the shared config.lua on the client (needs `setr`).
3. qb-inventory `AddHook` with a function from another resource (function reference) and `false` refusing.
4. `onClientResourceStart` for fredpd_core/qb-target re-adding armory zones; qb-target `AddCircleZone` options
   with `jobType`/`canInteract`.
5. xt-prison entering via `prison:client:Enter` from qb's `SendToJail` (logs xt-prison's "deprecated" error once).
6. The spawned vehicle's plate set server-side (`SetVehicleNumberPlateText`) before the client sets it again.

## Integration requests

1. **fredpd_core (bridge owner)**: add `canCarry(src, item, count)` and `itemInfo(name)` to the inventory bridge
   (needed by fredpd_mdt and fredpd_breach, see below); record in §C17 that qb-inventory@dc3d07f has
   `AddHook` (ShopOpened/ItemBought/ItemMoved/...), so `hooks` could be true for qb-inventory too.
2. **Rami / server.cfg.example owner**: `setr qb_locale "sv"`, `setr fredpd_police_legacy false`; with xt-prison
   set its `PoliceJobs` to the police job only (its compat `JailPlayer` handler is not grant-gated and cannot be
   patched — no licence).
3. **qb-core patch owner (optional)**: qb-core's `QBCore:Server:SpawnVehicle` (server/events.lua:275) spawns any
   model anywhere for any client; qb-policejob no longer uses it, other scripts may.
4. **docs/contracts.md owner**: §C17 says qb-inventory has no hooks — it has (above); audit labels
   `audit.action.police.fine/jail` say "med qbx_police" — make them framework-neutral; add `police.unjail`
   (locales/pending/police-qb.json).
5. **Resource owners — direct framework calls to move behind the bridge** (list in the task reply).
