<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Module: qbx_police integration (resource `qbx_policejob`)

Tasks 4.1 (grants, evidence/stormram off, jail decision, armory and garage from grants) and 4.3 (Swedish locale),
plus the qbx_police side of 3.3 (radar/ANPR → efterlysningar) and IMPLEMENTATION.md §5.4 item 4 (impound resolves an
efterlysning). Upstream is never edited: four patch files are applied by `node scripts/apply-patches.mjs` to
`resources/[upstream]/qbx_policejob` (pin `Qbox-project/qbx_police@7fa438f`, deps.lock.json). Line numbers below
are **upstream at the pin** unless marked "patched".

## Files

| File | Role |
|---|---|
| `patches/qbx_policejob.10-grants.patch` | adds `fredpd/server.lua` (bridge, garage, armory, ox_inventory hooks, rate limit), `fredpd/client.lua` (armory zones/menu); edits `server/main.lua`, `server/commands.lua`, `server/objects.lua`, `client/job.lua`, `fxmanifest.lua`, `locales/en.json` (`fredpd.*` keys) |
| `patches/qbx_policejob.20-fredpd-replacements.patch` | built-in evidence and stormram off unless `setr fredpd_police_legacy true` |
| `patches/qbx_policejob.30-bolo-hooks.patch` | adds `fredpd/bolo.lua`; radar handler, impound hook, `client/anpr.lua`, `isPlateFlagged` officers only |
| `patches/qbx_policejob.40-sv-locale.patch` | complete `locales/sv.json` (217 keys = every `en.json` key incl. `fredpd.*`); the remaining hard-coded English (impound menu, stash labels, NUI) through `locale()`: `locales/en.json` `menu.*`/`hud.*`, `client/job.lua`, `client/heli.lua`, `client/camera.lua`, `server/main.lua`, `html/script.js` |
| `config/police.json` | FredPD mapping: action → grant, garage, armories, ox_inventory shop → armory, radar limits |
| `locales/pending/police.json` | labels for the 4 audit actions (`audit.action.police.*`) |
| `tests/lua/police_*_test.lua` | 74 tests (harness in `police_harness_test.lua`) |

`fredpd/*.lua` are plain Lua 5.4 (luac clean, SPDX header), loaded with ox_lib `require 'fredpd.server'` /
`require 'fredpd.bolo'` from `server/main.lua` and `server/commands.lua` (no dependency on the `server/*.lua` glob
order, fxmanifest.lua:21-24); `fredpd/client.lua` is added to `client_scripts` (patched fxmanifest).
`config/police.json` reaches the game through `scripts/build.mjs` (copied to `fredpd_core/config/`, read
**server-side only** with `LoadResourceFile('fredpd_core', 'config/police.json')`; missing → identical built-in
defaults, test-enforced). It is not in fredpd_core's `files` (fxmanifest lists only `config/formats.json` and
`config/units.json`), so clients never receive it: they see only the armory positions and the per-officer filtered
item list the server sends.

## Upstream facts (qbx_policejob@7fa438f)

- `IsLeoAndOnDuty(player, minGrade)` global, `server/main.lua:13-18`; takes a qbx Player. Callers: main.lua:178,
  351, 411, 520, 606; `server/commands.lua:8-11` (`checkLeoAndOnDuty`, every command). `minGrade` only for licences
  (`config.licenseRank`, commands.lua:42, 78).
- No armory code: `config/shared.lua:41` "Not currently used, use ox_inventory shops" → ox_inventory
  `data/shops.lua:107-125` `PoliceArmoury` (groups police, per-item `grade`/`license`). ox_inventory's
  `openShop` callback returns the shop's shared item table (`modules/shops/server.lua:121-172`), so per-player
  filtering of that list is impossible with hooks; `buyItem` hooks can reject (`:266-279`, the hook fires after the `license`/`grade` checks at 227-236).
- Garage list is client-side: `client/job.lua:126-139` (`authorizedVehicles[grade]` + `whitelistedVehicles`,
  `config/client.lua:65-118`); spawning is `lib.callback 'qbx_policejob:server:spawnVehicle'` (main.lua:108-122)
  **with no check at all** (any client: any model, plate, place). Callers: garage `client/job.lua:90` (giveKeys
  `true`), helicopter `:200` (`true`), impound take-out `:65` (passes the row id as giveKeys).
- `police:GetImpoundedVehicles` (main.lua:104-106) returns every impounded `player_vehicles` row to any client.
- `server/objects.lua`: lib callbacks `police:server:spawnSpikeStrip` (:35-42) and `police:server:spawnObject`
  (:48-54), net events `police:server:despawnSpikeStrip` (:63-65) / `despawnObject` (:67-69) have **no check at
  all** (any client: any model hash, any coordinates, no object cap, any index; the spike cap is `>` maxSpikes, so
  maxSpikes + 1). Only the commands `/spikestrip`, `/pobject` (commands.lua:17, 99) and the client events
  (client/objects.lua:43, 106) check leo + duty.
- Cuffing is item-based by design: the usable item `handcuffs` (main.lua:66-70) sends anyone holding it to
  `police:client:CuffPlayerSoft` → lib callback `police:server:CuffPlayer` (main.lua:218-229), which needs only the
  item and 2.5 m. `police:server:EscortPlayer` (main.lua:231-245) lets any `leo` or `ems` job (duty not checked)
  drag a player who is neither cuffed nor down.
- Net events without an officer check: `BillPlayer` 291-303 (leo, not duty; no amount validation → negative bill
  pays the target), `JailPlayer` 306-331 (leo, not duty), `SeizeCash` 375-388 (none), `SetTracker` 571-594 (none),
  `TakeOutImpound` 197-205 (distance only).
- `for i = 1, #players` over the source-keyed `GetQBPlayers()` map: 135, 350 (+ `i` used as target at 358-359),
  519, commands.lua:394 — misses officers once low ids disconnect.
- Evidence: nine `evidence:server:*` net events 435-512 and 528-557 (UpdateCurrentCops 514-526 sits between),
  commands `clearcasings` 139, `clearblood` 170, `takedna` 357; client `client/evidence.lua` with four
  loops (184-189, 201-208 `Wait(0)`, 266-314 `Wait(0)`, 336-347). `police:GetPlayerStatus` 91-102 calls
  `next(nil)` for a player without status (93).
- Stormram: no code; only `config/client.lua:144` (trunk item list `carItems`, which no code reads).
- Radar: `client/anpr.lua` (off: `config/client.lua:124 enableRadars = false`); only the **driver** reports
  (`:20 cache.seat ~= -1`), after asking `police:server:isPlateFlagged` (`:25-34`, main.lua:124-131, in-memory
  `Plates` from `/flagplate` commands.lua:201-225); every radar reports as the last one (`:51 #speedCams`).
  Server `police:server:FlaggedPlateTriggered` 345-362 trusts the client entirely.
- Impound: `police:server:Impound` 408-433 → `ImpoundWithPrice` (state 0 + depotprice, storage.lua:17-19,
  `/depot`) or `ImpoundForever` (state 2, :21-23, `/impound`), then `DeleteEntity` 432.
- Locales: ox_lib `locale()` (`fxmanifest.lua:9 ox_lib 'locale'`, `locales/*.json` shipped at :36); ox_lib merges
  `en.json` with `<ox:locale>.json` (`ox_lib imports/locale/shared.lua:65-77`), server key = `GetConvar('ox:locale')`
  (`resource/locale/server.lua:9`), client = the player's ox_lib setting or the replicated convar
  (`resource/settings.lua:24-31`). Upstream sv.json had 176/191 keys.

## Patch 10 — grants (task 4.1)

`FredPD.check(src, action)` (fredpd/server.lua): **nil while fredpd_core is not `started`** (caller applies the
upstream check), else `exports.fredpd_core:isOnDuty(src)` and, for a mapped action, `hasGrant(src, type, key)`;
an export error or an unmapped action is a refusal (fail closed, one warning). The patched
`IsLeoAndOnDuty(player, minGrade, action)` returns that answer; qbx grades are not used while FredPD runs (a
`minGrade` without an action maps to `gradeN`, unmapped → refused). Refusals show `fredpd.no_permission` when on
duty, else `error.on_duty_police_only` (`FredPD.deniedKey`).

| Action (config/police.json `actions`) | Grant | Used by |
|---|---|---|
| `impound` | `perm:police.impound` | `/impound`, `/depot`, net Impound, TakeOutImpound, GetImpoundedVehicles, impound take-out spawn |
| `jail` | `perm:police.jail` | `/jail`, `/unjail`, net JailPlayer |
| `license` | `perm:police.license` | `/grantlicense`, `/revokelicense` (was grade ≥ licenseRank) |
| `fine`, `bill` | `perm:charges.fine` | `/fine` + net IssueFine, net BillPlayer |
| `flagplate`, `unflagplate` | `perm:bolo.create`, `perm:bolo.resolve` | `/flagplate`, `/unflagplate` |
| `cuff` | `duty` | `/cuff`, `/sc`; the leo bypass of net `EscortPlayer` (FredPD mode only) |
| `spikestrip`, `object` | `duty` | `/spikestrip`, `/pobject` **and** `server/objects.lua` spawn callbacks + despawn net events |
| `camera`, `seizecash`, `tracker`, `anklet`, `plateinfo` | `duty` | the matching commands / net events |
| `paytow`, `paylawyer` | `duty` | `/paytow`, `/paylawyer` (both pay the tow driver/lawyer `config.towPay`/`lawyerPay` from nowhere, commands.lua:304, 328; set e.g. `perm:police.pay` in config/police.json to restrict them further) |

`/paylawyer` (upstream commands.lua:318: any `leo`, duty not checked, or the `judge` job): while fredpd_core runs a
police officer needs `FredPD.check(src, 'paylawyer')` (FredPD duty + the mapped grant), otherwise `job.type == 'leo'`
as upstream; the `judge` job is allowed in both modes (patched commands.lua:332-340).

Not gated (upstream design, unchanged): `/escort`, `/callsign`, `/911p`; cuffing through the
`handcuffs` item / `police:server:CuffPlayer` (anyone holding handcuffs, e.g. criminals — "cuffs stay duty-only"
holds for `/cuff` and `/sc`, not for the item); escorting a cuffed/dead player (anyone). `EscortPlayer`'s bypass
for a player who is *not* cuffed or down needs `FredPD.check(src, 'cuff')` (on duty) while fredpd_core runs,
`job.type == 'leo'` (upstream) otherwise; EMS keep theirs.

Hardening that applies **in both modes** (never blocks a legitimate upstream use): BillPlayer amount must be
a whole number 1..`maxFine`; JailPlayer time a whole number ≥ 1; SeizeCash/SetTracker need `IsLeoAndOnDuty`;
TakeOutImpound ignores an unknown lot; the four `#players` loops use `pairs`; GetPlayerStatus no longer errors.
`server/objects.lua`: spawning and removing need `IsLeoAndOnDuty(player, nil, 'object'|'spikestrip')`, the
position within 10 m of the officer (for removal: the object's, when it still exists), one call per 500 ms, only
models listed in `config/shared.lua objects`, a whole index in `1..#list`, and at most `maxSpikes` spike strips.
Rate limits per officer (`FredPD.rateLimit`, after the grant check, so a refused call costs nothing; both modes):
BillPlayer, JailPlayer, IssueFine, `/paytow`, `/paylawyer` 1 per 2 s; Impound, TakeOutImpound, SeizeCash, SetTracker
1 per s (IssueFine, `/paytow` and `/paylawyer` answer `fredpd.try_again`, the others drop the call).

**Garage**: server callback `qbx_policejob:server:garageVehicles` → `{ model = label }`: FredPD: candidates
(`garage.vehicles`, or every model of `authorizedVehicles` + `whitelistedVehicles`) filtered by
`vehicle:<model lower case>`, empty when off duty; fallback: upstream list for the qbx grade, leo on duty only
(client/job.lua:546). `spawnVehicle` re-check (FredPD only; upstream has none): on duty, officer ≤ 15 m from the
spawn point, 1 spawn / 2 s, and the spawn point itself must be within 5 m (`SPAWN_TOLERANCE`) of a
`config/shared.lua` location of the right kind, because the client supplies the coordinates: giveKeys `true` → a
garage model at a `locations.vehicle` entry with a plate `policePlatePrefix` + letters/digits (≤ 8, as
client/job.lua:85-89 makes it), or `garage.helicopter` at a `locations.helicopter` entry (the officer inside the
4 m zone, client/job.lua:199-203, 496-500) with a `ZULU` plate, plus its vehicle grant; otherwise (impound) a
`locations.impound` entry, the impound grant and a `player_vehicles` row with that plate, `state = 2` and that
model. A granted officer can therefore no longer spawn a car elsewhere or with a copied civilian plate (and get
its keys).

**Armory** (FredPD only; `config/police.json armories`, default `mrpd` at the upstream placeholder
462.23, -981.12, 30.68): ox_target zone (client, `menu.pol_armory`) → `qbx_policejob:server:fredpdArmory(id)`
returns only items the officer holds a grant for (`weapon:<item lower>` for `WEAPON_*`, else `armory:<item lower>`)
after on duty + `armory:<id>` + distance; `qbx_policejob:server:fredpdArmoryTake(id, item)` re-checks all of it,
1 take/s, the item's optional `max` (refused with `fredpd.armory_limit` while
`exports.ox_inventory:GetItemCount(src, item)` ≥ max; ox_inventory@952c128 modules/inventory/server.lua:2322-2341;
defaults: 1 of each weapon, 150 9 mm, 180 rifle rounds, 2 handcuffs), `CanCarryItem`, `AddItem(count, metadata)`
(weapons registered to the officer by ox_inventory), audit `police.armory`. Items are free (equipment is signed
out, not bought); `max` caps what one officer carries, not what they can hand on after dropping it — every take
is audited. **ox_inventory `PoliceArmoury`** (if kept):
hooks `openShop` (on duty + `armory:mrpd`) and `buyItem` (+ item grant) with `typeFilter` from `oxShops`; no opinion
while fredpd_core is stopped; re-registered when ox_inventory restarts. Its list still shows every item, and its
`grade`/`license` rules still apply first → see integration request 5.

Audit (fire-and-forget `exports.fredpd_core:audit`, only while fredpd_core runs): `police.armory` (item),
`police.impound` (vehicle, normalised plate, `{ full, price, owned }`; written by patch 30 next to the
efterlysning hook), `police.jail` (player citizenid,
`{ minutes }`), `police.fine` (player, `{ amount, offence }` or `{ amount, via = 'bill' }`). Labels:
`locales/pending/police.json`.

## Patch 20 — FredPD replacements

`GetConvar('fredpd_police_legacy', 'false') == 'true'` (use **`setr`**: client/evidence.lua and config/client.lua
read it on the client) re-enables: the nine `evidence:server:*` events (UpdateCurrentCops stays registered),
`/clearcasings`, `/clearblood`, `/takedna`, all of `client/evidence.lua` (so its four per-frame/interval loops no
longer run by default) and the `police_stormram` trunk entry. Evidence is noobsystems/evidences (task 4.2); the ram is
fredpd_breach (Phase 6). The station fingerprint scanner (`police:server:showFingerprint*`) is not scene evidence
and stays.

## Patch 30 — BOLO hooks (task 3.3, §5.4 item 4)

- Client: every radar pass by a driver is reported (no `isPlateFlagged` pre-check, so a driver's client never learns
  whether its plate is wanted) with the radar's own index.
- Server `police:server:FlaggedPlateTriggered(radar, plate, street)`: accepted only when `src` is in the **driver's
  seat** of a vehicle whose plate (`qbx.getVehiclePlate`) equals `plate`, within `radar.maxDistance` (50 m) of
  `config/client.lua radars.locations[radar]`, 1 report/s per client. Then
  `exports.fredpd_bolo:checkPlate(normalisedPlate)` (pcall; only while fredpd_core and fredpd_bolo run): an active
  efterlysning fires **once per plate and radar per `radar.cooldownSeconds` (60)**:

  ```lua
  TriggerEvent('fredpd:boloHit', bolo, {
      source = 'radar',        -- qbx_police ANPR camera
      plate = 'ABC123',        -- upper case, no whitespace (docs/contracts.md C4)
      coords = { x = 1635.01, y = 1073.99, z = 80.9 },  -- the vehicle at the camera, 2 decimals
      street = 'Vespucci Blvd | Legion Sq', -- client-supplied display text, control chars removed, <= 100 chars, may be nil
      radar = 3,               -- index in qbx_police config/client.lua radars.locations
  })
  ```

  **Deviation from the task text:** there is no `officer` field. The reporting client is the *driver of the
  wanted car* (client/anpr.lua:20), not an officer, so it cannot be "validated on duty"; the camera is the
  reporter.
- Which qbx phone/blip alert follows (`FredPDBolo.radarAlert(pass, flagged)`, fredpd/bolo.lua; patched
  main.lua:389):

  | Efterlysning | fredpd_dispatch | qbx alert to every on-duty officer (`pairs`) |
  |---|---|---|
  | active | `started` | none: fredpd_bolo raises the larm (its `Fanout.hitAlert` needs fredpd_dispatch, fredpd_bolo server/fanout.lua:174-177) |
  | active, fresh hit (event fired) | not started | `fredpd.bolo_radar` "Träff på efterlysning: {plate} passerade {street} (ANPR-kamera {n})" — the hit is not lost in degraded mode; no reason text (the efterlysning may be restricted) |
  | active, cooling down | not started | the upstream `/flagplate` alert if the plate is also flagged, else none |
  | none | either | the upstream `/flagplate` alert (`info.plate_triggered`) if flagged, else none |
- `police:server:isPlateFlagged` (main.lua:129) and the deprecated bridge callback `police:IsPlateFlagged` (:148)
  answer from `/flagplate` flags only (never from efterlysningar) and, while fredpd_core runs, only to an on-duty
  officer (`FredPD.check(source) ~= false`; everyone else gets `false`), so a driver cannot ask whether its own
  plate is flagged. fredpd_core stopped → upstream (anyone).
- Impound: after the upstream success path of `police:server:Impound` (after `DeleteEntity`):
  `exports.fredpd_bolo:resolveOnImpound(normalisedPlate, src)` (pcall; `src` = the impounding officer, already
  checked on duty + `perm:police.impound`). Both `/depot` and `/impound`, owned or not.

## Patch 40 — Swedish (task 4.3)

`locales/sv.json` rewritten: all 217 keys, same `%s`/`%d` order as en.json (test-enforced), glossary terms
(*polis i tjänst*, *tjänstegrad*, *behörighet*, *ordningsbot* for `/fine`, *hylsa*, *bevispåse*, *bevisförråd*,
*vapenförråd*, *bärga/bärgad* for impound = qbx state, *ta i beslag* for `/impound` and cash, *omhänderta* for a
körkort, *ANPR-kamera*, *112*), kr instead of $, no exclamation marks, "…". Selected by `setr ox:locale sv`
(already in server.cfg.example:13; clients use it unless a player picked another language in ox_lib settings,
`ox:userLocales`). Other languages fall back to en for the `fredpd.*`, `hud.*` and new `menu.*` keys.

Hard-coded English outside `locales/*.json` now goes through `locale()` (new en/sv keys, test-enforced):

| Upstream | Now |
|---|---|
| impound menu metadata 'Engine' / 'Fuel' (client/job.lua:159-160) | `menu.impound_engine` / `menu.impound_fuel` (Motor / Bränsle) |
| ox_inventory stash labels 'Police Trash' / 'Police Locker' (server/main.lua:671, 674) | `menu.trash_stash` / `menu.locker_stash` (Polisens papperskorg / Personligt skåp; server locale) |
| fingerprint NUI 'Fingerprint ID' / 'No result' (html/script.js:89, 98) | `hud.fingerprint_id` / `hud.fingerprint_none`, sent as `labels` with `fingerprintOpen` (client/job.lua:14) |
| heli camera 'MODEL:' / 'PLATE:' / 'KM/U' (html/script.js:71-74) | `hud.heli_model` / `hud.heli_plate` / `hud.heli_speed` (Modell / Regnr / km/h; upper-cased by main.css), sent with `heliupdateinfo` (client/heli.lua:124) |
| CCTV 'CONNECTED' / 'CONNECTION FAILED' / 'ERROR #400: BAD REQUEST' / 'ERROR' (html/script.js:22, 30-33) | `hud.camera_*`, sent with `enablecam` (client/camera.lua:89), upper-cased in JS as upstream showed them |

html/script.js keeps English defaults in a `Labels` table (used only if a message arrives without `labels`) and
HTML-escapes the received labels. `html/index.html:20-21, 29-38` still hold English placeholder text; it is never
visible (`Fingerprint.Open` replaces it before the fade-in, the heli info is hidden until `heliupdateinfo`) and is
left alone. Vue's initial `connectLabel: "CONNECTED"` (script.js:6) is likewise overwritten before the camera view
shows.

## Jail (§9) — which path is active

| Prison setup | qbx_police `/jail` + net `police:server:JailPlayer` | FredPD `getAdapter('prison').jail(src, minutes)` |
|---|---|---|
| xt-prison running (all Qbox recipes; Decision 2 default) | **not registered** (main.lua:8, 305; commands.lua:145 — commands.lua only if main.lua loaded first, glob order UNVERIFIED); xt-prison's own `/jail` and compat JailPlayer apply, **not grant-gated** (no licence to patch) | needs an `xt-prison` adapter (request 2) |
| `prison: "qbx_prison"`, qbx_prison running (opt-in, insecure §2a) | patched: `perm:police.jail`; officer ≤ 2.5 m; sets `injail`/`criminalrecord` then `exports.qbx_prison:JailPlayer` (main.lua:320-326: confiscates inventory, **sets the job to unemployed** qbx_prison@977634b server/main.lua:10-13, client teleport) | stub → request 2 code (same export, no proximity) |
| `prison: "qbx_police-jail"`, no prison resource | patched net event sets metadata only; client `police:client:SendToJail` → `prison:client:Enter`, which nothing implements (qbx_prison's is a deprecated stub, client/main.lua:336-338): **no confinement** | metadata only (request 2 code), returns false |
| `none` (current default in config/integrations.json) | as the row above | no-op |

No qbx_prison patch is shipped: qbx_prison is REFERENCE in deps.lock.json (not fetched), so a
`patches/qbx_prison.*.patch` would make `apply-patches` fail on a fresh checkout.

## Tests

`lua5.4 tests/lua/run.lua police_` → **74 passed** (harness 7, grants 24, armory 17, evidence 5, bolo 15, locale 6);
full Lua suite 786 passed; `node scripts/lint-lua.mjs` clean (119 files). The harness `git archive`s the pinned commit into a
temp dir, applies the four patches with `git apply`, reads the files and deletes the dir, then runs the **patched**
`server/*.lua` (+ `fredpd/*.lua` via `require`) and client files in an isolated `_ENV` with FiveM/ox_lib/qbx_core/
oxmysql/ox_inventory/fredpd_core/fredpd_bolo mocked. cfxlua syntax (`+=`, backticks, `?.`) is rewritten only for
loading.

**The police tests need `resources/[upstream]/qbx_policejob` at the pinned commit.** Without it (a fresh clone, or
CI today: `.github/workflows/ci.yml` never runs fetch-deps) all 74 police tests, including "patches apply /
reverse-apply", pass with one `SKIP police tests` notice and test nothing. `FREDPD_REQUIRE_UPSTREAM=1` turns the skip
into a failure (integration request 7).

Manual verification (task step 6): `node scripts/fetch-deps.mjs --only qbx_policejob --force` +
`node scripts/apply-patches.mjs` → all 4 apply (exit 0); `luac5.4 -p` passes on `fredpd/*.lua`, `client/anpr.lua`,
`client/camera.lua`, `config/client.lua`, `server/commands.lua`, `fxmanifest.lua`; `node --check html/script.js`
passes; luac rejects `server/main.lua:579`, `client/job.lua:332`, `client/heli.lua:146` (patched line numbers; upstream
`+=`/`-=`), `server/objects.lua:70` and `client/evidence.lua:31` (upstream backtick hashes) for **upstream cfxlua
syntax only**; after rewriting those they compile except `client/evidence.lua`, which
still stops at upstream `?.` (the test rewrite handles it; test-enforced). A second `apply-patches.mjs` run reports all four "already applied":
the patches never touch the same or neighbouring lines (each reverse-applies alone on the patched tree,
test-enforced), which is why patch 20 declares `legacyEvidence` right above the evidence block and patch 30
requires `fredpd.bolo` right above `FlaggedPlateTriggered`. Checkouts restored clean afterwards.

## UNVERIFIED in FiveM

1. Server-side `GetVehiclePedIsIn` / `GetPedInVehicleSeat(veh, -1) == GetPlayerPed(src)` under OneSync (radar
   validation); `qbx.getVehiclePlate` server-side on that vehicle.
2. ox_lib `require 'config.client'` on the server (file loads with server-side `vec3`/`vec4`/`GetConvar`).
3. ox_inventory `registerHook` with a qbx_policejob function: `false` from `buyItem`/`openShop` refuses, `Notify`
   from inside the hook; hooks dropped/re-added across restarts.
4. Client `GetConvar('fredpd_police_legacy')` sees `setr`; `onClientResourceStart('fredpd_core')` fires on clients
   (fredpd_core has only `files`) so armory zones appear if fredpd_core starts after qbx_police.
5. ox_target `addBoxZone`/`removeZone` return/accept the zone id as used; `exports.ox_inventory:Items(name).label`
   on the server; weapon `metadata.serial = 'POL'` gives a POL-prefixed serial.
6. `lib.callback` vector3/vector4 arguments arrive with `.x/.y/.z` (spawn distance and location checks, object
   and spike-strip coordinates); `GetEntityCoords` on server-created police objects (removal distance) under
   OneSync; backtick model hashes in `config/shared.lua objects` equal the hash the client sends.
7. The `server/*.lua` glob order (commands.lua before/after main.lua) — decides whether `/jail` exists under
   xt-prison (upstream behaviour, unchanged).

## Integration requests

1. ~~**fredpd_bolo**~~ **done** (docs/modules/bolo.md:159-161): `checkPlate` normalises and never waits
   (fredpd_bolo server/service.lua:132), `resolveOnImpound` never raises (:313), the `fredpd:boloHit` listener
   (server/main.lua:48 → service.lua:465) writes the radar `fredpd_plate_checks` row and raises the larm through
   fredpd_dispatch. Nothing open; without fredpd_dispatch the qbx alert covers the hit (patch 30 above).
2. **fredpd_core (adapters, owner of prison/)**: replace the stubs; add `adapters/prison/xt_prison.lua` (Decision 2
   default; set `"prison": "xt-prison"` when Rami runs it):

   ```lua
   -- adapters/prison/xt_prison.lua
   return require('adapters.base').define({
       kind = 'prison', name = 'xt-prison', resource = 'xt-prison',
       methods = {
           jail = function(src, minutes, _charges)
               src, minutes = tonumber(src), math.tointeger(tonumber(minutes))
               if not src or not minutes or minutes < 1 or not exports.qbx_core:GetPlayer(src) then return false end
               -- xt-prison@85fd705 client/cl_main.lua:5-7; must run in a thread (lib.callback handlers do). UNVERIFIED
               return lib.callback.await('xt-prison:client:enterJail', src, minutes) ~= false
           end,
       },
   })
   -- adapters/prison/qbx_prison.lua: methods = { jail = function(src, minutes, _charges)
   --     src, minutes = tonumber(src), math.tointeger(tonumber(minutes))
   --     local player = src and minutes and minutes > 0 and exports.qbx_core:GetPlayer(src)
   --     if not player then return false end
   --     player.Functions.SetMetaData('criminalrecord', { hasRecord = true, date = os.date('!*t') })
   --     exports.qbx_prison:JailPlayer(src, minutes)  -- qbx_prison@977634b server/main.lua:23-35
   --     return true
   -- end } (drop stub/task; keep the caution)
   -- adapters/prison/qbx_police_jail.lua: methods = { jail = function(src, minutes, _charges)
   --     (same validation) player.Functions.SetMetaData('injail', minutes)
   --     player.Functions.SetMetaData('criminalrecord', { hasRecord = true, date = os.date('!*t') })
   --     if GetResourceState('qbx_prison') == 'started' then exports.qbx_prison:JailPlayer(src, minutes) return true end
   --     TriggerClientEvent('police:client:SendToJail', src, minutes) -- uncuffs only
   --     return false -- metadata only, nobody confined (qbx_policejob main.lua:320-329)
   -- end }; resource = 'qbx_policejob' misses recipe servers whose folder is qbx_police (deps-verification §2)
   ```
3. **apps/service catalog** (`KNOWN_PERMS` + `perms.perm.*` labels): `police.impound`, `police.jail`,
   `police.license`; suggest listing `config/police.json` keys (armory ids, `weapon:weapon_*`, `armory:<item>`,
   `vehicle:<model>`) so admins do not type them. Keys are **lower case**.
4. **docs/contracts.md owner**: record the perms above, the lower-case weapon/vehicle/armory key convention and the
   radar `fredpd:boloHit` context (no officer) in C2/C12/§4.3.
5. **ox_inventory patch owner / Rami**: the `PoliceArmoury` shop cannot be filtered per player by hooks; remove it
   from `data/shops.lua` (or at least its `grade = 3` / `license` fields, checked before the hooks) and use the FredPD
   armory. Purchases there are grant-checked either way.
6. **server.cfg.example owner**: document `setr fredpd_police_legacy false`; `ensure ox_target` before
   `qbx_policejob` (armory zones); run `scripts/build.mjs` so `fredpd_core/config/police.json` exists. ps-housing's
   raid still needs the `police_stormram` item (`Config.RaidItem`) until fredpd_breach replaces it.
7. **CI owner (`.github/workflows/ci.yml`)**: before `pnpm test`, add
   `- run: node scripts/fetch-deps.mjs --only qbx_policejob` and set `FREDPD_REQUIRE_UPSTREAM: '1'` in the job `env`,
   so the 74 police tests (and the patch apply/reverse-apply checks) run instead of skipping. Only this upstream is
   needed (git clone of a public repository at the pin; no other network access).

## In-game steps (for docs/test-phase-4.md)

1. Officer A with grants `perm:police.impound`, `vehicle:police3`, `armory:mrpd`, `weapon:weapon_pistol`; officer B
   on duty with none. `ensure qbx_policejob` shows no errors; `setr ox:locale sv` → `/impound` help text is Swedish.
2. B at the MRPD garage: "Det finns inga fordon som du har behörighet att ta ut". A: only Police Car 3 is listed and
   spawns.
3. A at the armory (462, -981): menu lists only Pistol; takes it (weapon in inventory, audit row `police.armory`);
   a second take says "Du bär redan det högsta antal du får kvittera ut". B: "Du har inte behörighet att göra det
   här". The ox_inventory Police Armoury refuses B's purchase.
4. B `/impound` next to a car → refused; A → car impounded, audit `police.impound`.
5. Shoot a pistol: no casings/qbx evidence appear and `/clearcasings` does not exist (evidences handles evidence).
   B `/spikestrip` works; with B off duty (FredPD) neither `/spikestrip` nor `/pobject cone` places anything.
6. Stop fredpd_core (`stop fredpd_core`): B can now `/impound` and gets the qbx grade garage list (upstream); start
   it again.
7. With `enableRadars = true` in qbx_police config and an active vehicle efterlysning on car X, drive X past a radar:
   one larm (from fredpd_bolo) within a second, none again for 60 s at that camera. `stop fredpd_dispatch`, wait 60 s,
   pass again: the qbx phone/blip alert reads "Träff på efterlysning: …". B `/paylawyer` twice at once pays once.
8. `/impound` car X as A → its efterlysning is resolved (MDT shows Återkallad).
