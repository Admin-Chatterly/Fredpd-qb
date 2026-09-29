# Upstream verification (task 0.3)

Checked 2026-09-29 from git clones (blobless, `git log -1 --format='%H %cI'`) and by reading source. The GitHub web
UI and REST API were not reachable from the agent sandbox (HTTP 403); release assets were checked with `curl -I`
(302 = the asset exists, 404 for a made-up tag as control). Pins are in `deps.lock.json`; `node scripts/fetch-deps.mjs`
checks every non-REFERENCE pin out into `resources/[upstream]/<name>/`, which is what the `file:line` references below point to
(`ox_doorlock/server/main.lua:275` = `resources/[upstream]/ox_doorlock/server/main.lua` at the pinned commit).
fetch-deps skips REFERENCE pins but does **not** delete a directory that an earlier run already fetched: after a pin
becomes REFERENCE (qbx_prison, xt-prison, bub-mdt), remove `resources/[upstream]/<name>/` by hand so it cannot be
`ensure`d by accident.
Repos that are not fetched are cited as `owner/repo@sha path:line`. Anything marked **UNVERIFIED** was not observable
without a running FXServer or access to Rami's server.

## 1. Repositories

| Repo | Default branch | HEAD (sha, date) | Commits in 2026 | Licence (from LICENSE) | Latest tag (sha, date) | Pinned |
|---|---|---|---|---|---|---|
| overextended/ox_lib | main | b8f5a04 2026-09-04 | yes (137) | LGPL-3.0-or-later (NOTICE.md) | v3.39.0 08bac37 2026-07-13 | tag |
| overextended/ox_inventory | main | 172b391 2026-08-27 | yes (144) | GPL-3.0-or-later | v2.47.9 952c128 2026-07-13 | tag |
| overextended/ox_target | main | bf03d52 2026-06-09 | yes (5) | MIT | v1.18.1 abe153a 2026-04-25 | tag |
| overextended/ox_doorlock | main | ba092ff 2026-07-03 | yes (8) | GPL-3.0-or-later | v1.22.1 7d72ff7 2026-04-25 | tag |
| overextended/oxmysql | main | 030d3bd 2026-07-03 | yes (41) | LGPL-3.0-or-later | v2.14.1 f0385c4 2026-05-04 | tag |
| CommunityOx/ox_lib | main | a8bf225 2026-02-20 | yes (7) | LGPL-3.0 | v3.32.3 = HEAD | no |
| CommunityOx/ox_inventory | main | 89736ce 2026-04-02 | yes (8) | GPL-3.0 | v2.45.0 143a4a5 | no |
| CommunityOx/ox_target | main | 3e676ad 2026-02-19 | yes (1) | MIT | v1.18.0 = HEAD | no |
| CommunityOx/ox_doorlock | main | 95f5758 2026-02-19 | yes (2) | GPL-3.0 | v1.22.0 = HEAD | no |
| CommunityOx/oxmysql | main | f974bd7 2026-02-20 | yes (1) | LGPL-3.0 | v2.13.1 d30676c 2025-05-02 | no |
| Qbox-project/qbx_core | main | f0553b6 2026-09-26 | yes (55) | GPL-3.0-or-later (ESX header in LICENSE) | v1.24.0 c1c3ca1 2026-08-22 | HEAD |
| Qbox-project/qbx_police | main | 7fa438f 2026-09-26 | yes (15) | GPL-3.0 (bare text) | none | HEAD |
| Qbox-project/qbx_prison | main | 977634b 2026-07-09 | yes (1, chore only) | GPL-3.0 (bare text) | none | HEAD, REFERENCE (not run, §2a) |
| xT-Development/xt-prison | main | 85fd705 2026-08-24 | yes | **none** (no LICENSE file) | v1.4.9 6f4d06f 2026-06-24 | tag, REFERENCE (recipe installs the zip) |
| Qbox-project/qbx_vehicles | main | 5712829 2026-09-26 | yes (4) | GPL-3.0 (bare text) | v1.4.2 7cd0380 2024-12-19 | HEAD |
| Qbox-project/qbx_garages | main | 3dcd903 2026-09-26 | yes (15) | GPL-3.0 (bare text) | v1.1.4 1ff6eff 2024-11-11 | HEAD |
| Qbox-project/qbx_properties | main | 9bbdb43 2026-09-26 | yes (12) | GPL-3.0 (bare text) | none | not locked |
| noobsystems/evidences | main | 0d15876 2026-08-18 | yes (44) | GPL-3.0-or-later (README) | v1.3.1 = HEAD | tag (= HEAD) |
| Project-Sloth/ps-dispatch | main | d488316 2026-08-12 | yes (4) | GPL-3.0 (bare text) | 3.0.0 8de73dd 2026-08-12 | HEAD (= 3.0.0 + README) |
| Project-Sloth/ps-housing | main | eaba693 2026-02-06 | yes (1) | **CC BY-NC-SA 4.0** | 2.0.7 4ac6035 2024-11-03 | not locked |
| BubbleDK/bub-mdt | main | 85607d6 2025-07-20 | **no** | GPL-3.0-or-later (fxmanifest) | none | REFERENCE |
| citizenfx/screenshot-basic | master | 5e89d4a 2022-01-06 | **no** | MIT | none | HEAD |

Also read for context: Qbox-project/txAdminRecipe@7fabe1f (how a Qbox server is installed), xT-Development/xt-prison@85fd705
(HEAD; v1.4.9 differs only in `configs/client.lua`, so its refs hold for the pinned tag), itschip/screencapture@8fb1021 (v0.17.2, AGPL-3.0), citizenfx/fivem@e60d29a (sparse).

**overextended vs CommunityOx.** Every CommunityOx HEAD is an ancestor of the overextended HEAD of the same repo
(`git merge-base --is-ancestor`), e.g. ox_target has "Merge remote-tracking branch 'upstream/main'" and "chore: update
name and refs" on 2026-04-24/25. overextended took the CommunityOx work back and has been the active line since
(Linden: 75 of 137 ox_lib commits in 2026). CommunityOx's last commits are Feb–Apr 2026. That the CommunityOx org is
archived (IMPLEMENTATION §1) is consistent with this but was **UNVERIFIED** (no web/API access).

**Install path.** The Qbox txAdmin recipe (`qbox.yaml:422-461`) downloads `overextended/<name>/releases/latest/download/<name>.zip`
for all five ox resources, and ox_lib/ox_inventory/ox_doorlock/oxmysql have no built UI/dist in git
(`ox_lib/fxmanifest.lua` needs `web/build/`, which the checkout does not contain). So the five ox resources and
evidences (`html/dui/laptop/dist` is built) are pinned to their release **tag's commit** and must run from the
release zip of that tag (`release` field in deps.lock.json).

The Qbox txAdminRecipe has **three** recipes, and they install the Qbox resources differently:

| Recipe | qbx_core / qbx_vehicles / qbx_garages | qbx_police | prison | screenshots |
|---|---|---|---|---|
| `qbox.yaml` "Qbox Project" | git `ref: main` (165-168, 172-175, 237-240) | main (257-260) | xt-prison release (119-124) | screencapture (62-67) |
| `qbox-lean.yaml` "Qbox Lean Pack" | `releases/latest/download/*.zip` (150-157, 159-166, 209-214) | main (255-258) | xt-prison release (241-246) | screencapture (62-67) |
| `qbox-stable.yaml` "Qbox Stable" ("Recommend for those who want a working server out of the box", :5) | `releases/latest/download/*.zip` (144-151, 153-160, 221-226) | **not installed** | xt-prison release (207-212) | screencapture (62-67) |

`releases/latest` currently resolves to qbx_core **v1.24.0** (c1c3ca1), qbx_vehicles **v1.4.2** (7cd0380), qbx_garages
**v1.1.4** (1ff6eff) (`curl -I` → 302 Location). The lock pins HEAD of main (what `qbox.yaml` installs, and what
FredPD was verified against); on a lean/stable server the running versions are those tags, which are 16, 6 and 20
commits behind. Which recipe Rami used is an open question; re-verify §5/§6 against the tags if it was lean/stable.

## 2. qbx_police (resource name `qbx_policejob`)

- **Resource name**: `qbx_policejob/fxmanifest.lua:4` `name 'qbx_policejob'`, `:6` repository `.../qbx_policejob`,
  `README.md:1` "# qbx_policejob". FiveM names a resource after its **folder**; the Qbox recipe clones it to
  `resources/[qbx]/qbx_police` (`qbox.yaml:257-260`). Nothing upstream calls it by name (no `exports['qbx_policejob']`
  anywhere in the fetched repos), so either folder name works, but server.cfg and the adapter must match the folder.
- **IsLeoAndOnDuty**: global, `qbx_policejob/server/main.lua:10-18`
  `function IsLeoAndOnDuty(player, minGrade)` — takes a qbx **Player object**, not a source:
  `job.type == 'leo' and job.onduty` then `job.grade.level >= (minGrade or 0)`. Callers: main.lua:178, 351, 411, 520,
  606 and `server/commands.lua:8-11` (`checkLeoAndOnDuty` for every command). Patch body therefore needs
  `player.PlayerData.source` → `exports.fredpd_core:isOnDuty(src)` (+ a grant for `minGrade`; `hasGrant` is
  `(src, type, key)`, not `(src, grant)` as §3 writes).
- **evidence:server:\*** (all `RegisterNetEvent`, `server/main.lua`): UpdateStatus 435, CreateBloodDrop 439,
  CreateFingerDrop 448, ClearBlooddrops 455, AddBlooddropToInventory 463, AddFingerprintToInventory 485, CreateCasing 505,
  ClearCasings 528, AddCasingToInventory 537; client side `client/evidence.lua` (whole file; triggers at 40, 63, 114,
  159, 177, pickups 281-310). None validates `source` or distance — disabling them (patch) is also a security fix.
  `lib.callback 'police:GetPlayerStatus'` (main.lua:91-102) reads `playerStatus` filled by UpdateStatus.
- **Stormram**: there is **no stormram code** in qbx_police. The only reference is the trunk item list
  `config/client.lua:141-145` (`police_stormram`, slot 3) and `README.md:18`. The consumer is ps-housing
  (`Config.RaidItem = "police_stormram"`, see §11). "Disable stormram" = drop that trunk entry; nothing else.
- **police:server:FlaggedPlateTriggered** `server/main.lua:345-362` (net event, args `radar, plate, street`): no
  validation or rate limit, and it is **unreliable**: `GetQBPlayers()` is a map keyed by source
  (`qbx_core/server/functions.lua:140-147` `table<Source, Player>`), so `i` *is* the source and `players[i]` that
  player; the bug is the `for i = 1, #players` loop (main.lua:350). `#` on a sparse source-keyed map returns any border:
  once a low server id has disconnected it is typically 0, and alerts are silently skipped for some or all officers.
  Correct form: `for src, player in pairs(players)`. The same pattern is in `police:server:UpdateCurrentCops`
  (main.lua:519, the client-visible cop count). Flagged list: global `Plates = {}` (main.lua:7), in memory only, filled by `/flagplate`
  (`server/commands.lua:201-225`, key `args.plate:upper()`), cleared by `/unflagplate` (227-247), read by `/plateinfo`
  (249-267) and `lib.callback 'police:server:isPlateFlagged'` (main.lua:124-131). Triggered by the client ANPR
  (`client/anpr.lua:19-38`, a `lib.points` per radar; radars are **off by default**, `config/client.lua:124`
  `enableRadars = false`). Task 3.3 should replace the handler body (lookup via `fredpd_bolo:checkPlate`) and the
  `isPlateFlagged` callback, not feed `Plates`.
- **Jail: qbx_police has no jail of its own.** `server/main.lua:305-332` `police:server:JailPlayer(targetSrc, time)`
  (registered only when xt-prison is not started, `IsUsingXTPrison` main.lua:8) sets metadata `injail` and
  `criminalrecord` (320-324), then calls `exports.qbx_prison:JailPlayer(src, time)` if qbx_prison is started (325-326),
  else `TriggerClientEvent('police:client:SendToJail', …)` (328). That client handler (`client/main.lua:157-164`, also
  gated on `not isUsingXTPrison`, :4) only uncuffs and does `TriggerEvent('prison:client:Enter', time)` (163), and
  **nothing confines the player on that path**: qbx_prison's `prison:client:Enter` is a deprecated stub that only logs
  (`Qbox-project/qbx_prison@977634b client/main.lua:335-338`); xt-prison's compat handler would enter prison
  (`xt-prison@85fd705 bridge/compat/client.lua:4-7`) but is unreachable because both qbx_police handlers are skipped when xt-prison runs.
  So without a prison resource, "jail" = the `injail` metadata and nothing else. `/jail` `/unjail`
  (`server/commands.lua:145-168`, `exports.qbx_prison:ReleasePlayer(id)` at 163) are likewise skipped under xt-prison,
  which brings its own `/jail` and a compat `police:server:JailPlayer` (see §2a). The net event needs the officer
  within 2.5 m of the target (`isTargetTooFar`, 207-216), so a server-side prison adapter cannot call it anyway.
- **police:server:BillPlayer** `server/main.lua:291-303`: checks distance and `job.type == 'leo'` but **not on-duty**,
  never validates `price` (type/sign), and hard-calls `exports['Renewed-Banking']:addAccountMoney` (301). The newer
  `/fine` → `police:server:IssueFine` (596-657) validates everything. Recommend the patch removes BillPlayer's client
  path or adds the same checks.
- **Armory / duty / garage**: no armory code; `config/shared.lua:41` "Not currently used, use ox_inventory shops" →
  `ox_inventory/data/shops.lua:107` `PoliceArmoury` (groups = police). Grant-gated armory = an ox_inventory `buyItem`
  hook (`ox_inventory/modules/shops/server.lua:266-279`, payload source, shopType, itemName, count, …), not a
  qbx_police patch. Duty is qbx_core's `QBCore:ToggleDuty` (client/job.lua:404-406 → `qbx_core/server/events.lua:239-250`).
- **Locales**: `qbx_policejob/locales/*.json`, 18 languages incl. `sv.json` (176 of 191 `en` keys), nested objects,
  `%s` placeholders via ox_lib `locale()`. Task 4.3 = complete sv.json.

## 2a. Prison resources (qbx_prison, xt-prison)

Both trust the client for the sentence. Neither is a server-authoritative jail.

- **qbx_prison** (`Qbox-project/qbx_prison@977634b`, not fetched; lock mode REFERENCE; delete any stale
  `resources/[upstream]/qbx_prison/` left by an earlier fetch): exports `JailPlayer(src,
  minutes)` / `ReleasePlayer(src)` (`server/main.lua:23-44`). Last functional commit 2024-06-23. It has three verified
  holes, which are reasons **not to run it**:
  1. **Any client can unlock any ox_doorlock door**. `RegisterNetEvent('qbx_prison:server:onGateHackDone',
     function(success, currentGate, gateKey)` (`server/main.lua:77-85`) only rejects `source == ''` and then calls
     `exports.ox_doorlock:setDoorState(gateKey, 0)` with a client-chosen `gateKey`. On the export path `source` is
     `nil` inside ox_doorlock (§7), so `authorised = not source or …` (`ox_doorlock/server/main.lua:281`) passes. This
     opens station doors, ps-housing MLO doors and any door fredpd_breach relies on being locked.
  2. A client clears its own sentence with `qbx_prison:server:playerEscaped` (61-64, `setJailStatus(source, 0)`).
  3. It can also set any value with `prison:server:SetJailStatus(jailTime)` (19-21).
- **xt-prison** (`xT-Development/xt-prison@85fd705` = HEAD; latest release v1.4.9 = 6f4d06f, which differs only in
  `configs/client.lua`; **no LICENSE**, so call it only, never copy or patch-and-ship). All three recipes install it
  (§1).
  - Export `SetJailTime(src, minutes)` (`bridge/server/qbx.lua:30-47`) only sets `Player(src).state.jailTime` and the
    `injail` metadata. **It does not move the player.** Confinement is the client callback
    `lib.callback.await('xt-prison:client:enterJail', target, minutes)` (`client/cl_main.lua:5-7`), which xt-prison's
    own `/jail` uses (`server/sv_commands.lua:96`) and so does its compat `police:server:JailPlayer` (distance +
    `isCop` checks, `bridge/compat/server.lua:20-31`). ox_lib routes the answer to the calling resource
    (`ox_lib/imports/callback/server.lua:29-39, 121-122`), so fredpd_core can call it too (in-game **UNVERIFIED**).
    Release is `lib.callback.await('xt-prison:client:exitJail', target, true)` after `setJailTime(target, 0)`
    (`server/sv_roster.lua:14-22`).
  - Client trust: the countdown runs on the client, which writes the replicated state bag itself
    (`client/modules/prison.lua:17-28, 258-261`). `prison:server:SetJailStatus(jailTime)`
    (`bridge/compat/server.lua:14-17`) and `lib.callback 'xt-prison:server:setJailStatus'` (`server/sv_main.lua:150-163`)
    let any client set its own time to 0. Its door changes only index the configured prison gates
    (`HackZones[terminalID].gate`, `server/modules/prisonbreak.lua:58-59, 86-92`), so it has no any-door hole like
    qbx_prison's. Whether its prison-break events validate the hack itself was not audited.
- **FredPD-built jail**: a server-side sentence table, teleport, zone and release timer. It is the only
  server-authoritative option, but it is not in the plan (new module, and prison life, jobs and escape gameplay would
  be duplicated).

## 3. evidences (v1.3.1)

- **Exports**: `getFingerprint(playerId)` `evidences/server/biometrics/biometrics_provider.lua:97-101`;
  `getDNA(playerId)` `:103-105` (both via `getBiometricData(playerId, type)` 87-95, keyed by citizenid from
  `common/frameworks/qbx/server.lua:5-14`). `syncEvidence(evidenceClass, owner, fun, ...)` `server/evidences/api.lua:50-60`:
  `owner` = serverId (resolved to the biometric key) or the key string itself; `fun` = method name on the evidence
  object. Types (`api.lua:7-15`): `fingerprint, blood, saliva, magazine, casing, bullet, gunshot_residue`.
- **Methods** (`server/evidences/classes/evidence.lua`): `atEntity(netIdOrEntity, meta)` 44, `atRelativeEntityCoords` 70,
  `atVehicleSeat` 125, `atVehicleDoor(vehicle, doorId, meta)` 162, `atPlayer(playerId, meta)` 198,
  `atCoords(coords, meta)` 224, `atItem` 273, `atLastUsedItemOf` 315, `atWeaponOf` 325, plus `removeFrom*` twins.
  Entity/player evidence lives in statebags (`Entity(e).state['evidences:<type>']`, 31-37), coords evidence is pushed
  with `TriggerClientEvent(... -1 ...)` (233).
- **Security note**: `RegisterNetEvent("evidences:syncEvidence", syncEvidence)` (`api.lua:59`) runs
  `evidenceHolder[fun](evidenceHolder, ...)` (53) with a client-chosen method and arguments and **no permission
  check**. Any client can therefore create or remove any evidence for any owner, and through `fun = "atItem"` /
  `"removeFromItem"` it can write or strip metadata on **any slot of any inventory**, lockers and stashes included.
  `atItem(inventory, slot, data)` copies every key of `data` into the item metadata (`classes/evidence.lua:273-289`).
  Upstream's own client uses the net event for shots, blood and prints, and `atItem`/`removeFromItem` only on the
  player's own inventory (`client/evidences/registry/fingerprint.lua:41`).
- **evidences:evidenceItemAnalysed**: `TriggerEvent("evidences:evidenceItemAnalysed", source, item)`
  `server/dui/callbacks.lua:211`, inside `lib.callback 'evidences:setAnalysed'` (184-214) after `SetMetadata`. `item` is the
  ox_inventory slot table (`name, slot, count, metadata`; `metadata[type] = { owner, analysed = true }`,
  `metadata.information`). The payload is **client-influenced**:
  - The inventory is not passed. It was `arguments.inventory`, and `getItem` accepts any string inventory id, i.e.
    any stash (150-159; it only blocks *other players'* numeric ids).
  - `arguments.information` from the client is merged into `metadata.information` (202-205).
  - `metadata[type].owner` was itself chosen by the collecting client (see collect below).
  So a permitted client can mark items in any stash as analysed and attach arbitrary `information` fields.
  fredpd_forensics should use only `name`, `slot`, `metadata[type].analysed` and the uid (checked as below), and treat
  `owner`/`information` as client-asserted data.
- **No unique id** on evidence items: collecting (`lib.callback 'evidences:collect'` → `actions.collect`,
  `server/evidences/actions.lua:35-94`) does `AddItem(source, collectedItem, 1)` (61), then
  `atItem(source, slot, metadata)` (75), where `owner`, `remove` and `metadata` all come **from the client** (92-94).
  `remove.fun` is also an arbitrary method name (69). C16's `item_uid` must be minted by FredPD, e.g. in an ox_inventory
  `createItem` hook on the collected-item names (`ox_inventory/modules/hooks/server.lua:91-94`; evidences already
  chains its own createItem hook, `evidences/server/items.lua:63-73`). **A createItem-minted uid is client-overwritable**,
  though. The hook runs inside `AddItem` (61), and `atItem` (75) then copies the client's `metadata` over it, so a
  collector can stamp another evidence's uid on the new item. Via `syncEvidence` → `atItem` any client can do the same
  to any item. fredpd_forensics' upsert by `item_uid` would then merge or overwrite records across cases. Required
  mitigations (Decision 5):
  1. PATCH evidences so that `collect` strips reserved keys (`item_uid`, …) from the client `metadata` and allows only
     `removeFrom*` in `remove.fun`, and so that the net `syncEvidence` accepts only the methods its client uses, with
     `atItem`/`removeFromItem` restricted to `inventory == source` and client `data` dropped.
  2. As defence in depth, fredpd_forensics keeps a server-side registry: uid → item name and inventory at mint time
     (the hook runs before `atItem`, so type/owner are not known yet), plus the evidence type and owner first seen
     for that uid; moves are tracked by the C16 `swapItems` hook. It rejects an event whose item name, type or owner
     differ from the registered ones.
- **ox_target fork**: not needed. `README.md:48` only *recommends* noobsystems/ox_target "that improves targetting of
  vehicle doors"; the fxmanifest depends on plain `ox_target` (`fxmanifest.lua:9-15`) and the code uses standard
  exports (`client/evidences/evidences.lua:386-426`).
- **Permissions**: `config.lua:95-110` job → min grade tables, checked by `framework.hasPermission`
  (`common/frameworks/framework.lua:18-28`) through `playerData.jobs[job]` — **no on-duty check**. Grant-based access
  (task 4.2) needs a small patch of `hasPermission` or config.
- **Locales**: `locales/{cs,de,en,es,fr,ja,tr}.json` — no `sv`. Items: `.github/setup/<lang>_items.lua` → paste into
  ox_inventory `data/items.lua`; images: release asset `item_images.zip`.

## 4. ps-dispatch (3.0.0)

- **Qbox support**: only through qbx_core's qb-core bridge: `server/main.lua:6-7` `pcall(exports['qb-core']:GetCoreObject())`,
  `client/main.lua:1` (not pcall'd); qbx_core `fxmanifest.lua:72` `provide 'qb-core'`, bridge on unless
  `qbx:enablebridge` is `false` (`qbx_core/bridge/qb/server/main.lua:1`). Without the bridge the server silently
  broadcasts every alert to **every** player (`server/main.lua:155-158`) and lets anyone clear calls (574-575).
- **Where a call is stored**: `RegisterServerEvent('ps-dispatch:server:notify', …)` `server/main.lua:287-336`;
  `calls[#calls + 1] = data` at **329**, `data.listed = true` 333, `broadcastCall(data)` 335. **Patch point** (the
  §3 `fredpd:alertCreated` hook, renamed to the inbound event by contract C13): insert
  `TriggerEvent('fredpd:dispatch:incoming', data, src)` between 333 and 335 (`src` is the local at 288; data still has
  the true `coords`, `publicCall` strips them only for the client copy, 70-76). Other paths: merged repeat reports
  return at 302-308 (no new call;
  optional `fredpd:alertUpdated`), targeted alerts with `addToList` 535-539. All data arrives from a client and is
  only shape-checked (`sanitizeNotify` 195-205; rate limit `Config.NotifyRateLimit` 12/10 s, 178-193): fredpd_dispatch
  must validate and cap fields. Officer alerts carry the **character** name + `metadata.callsign`
  (`client/alerts.lua:488-489`), not the §4.9 Discord name.
- **NUI/HUD off**: **no config flag exists** (`shared/config.lua` has none; the client pushes every alert with an
  unconditional `SendNUIMessage({action='newCall'})`, `client/main.lua:499-577`, 532). See Decisions.
- **lsn-radar**: optional. Not in the fxmanifest and not referenced by any Lua or UI file; only `README.md:17`.
- **PolyZone**: **hard** manifest include `fxmanifest.lua:13-18` (`@PolyZone/client.lua`, `CircleZone.lua`,
  `BoxZone.lua`), although the zones use `lib.zones` (`client/main.lua:69-110`). Without PolyZone installed the
  resource will not load cleanly (**UNVERIFIED** whether FXServer refuses to start it or only logs missing files).
- **Preset exports**: all **client-side** (`client/alerts.lua`): CustomAlert 52, VehicleTheft 79, Shooting 102, Hunting
  125, VehicleShooting 155, SpeedingVehicle 182, Fight 202, PrisonBreak 222, StoreRobbery 243, FleecaBankRobbery 264,
  PaletoBankRobbery 285, PacificBankRobbery 306, VangelicoRobbery 327, HouseRobbery 347, YachtHeist 367, DrugSale 387,
  SuspiciousActivity 407, CarJacking 434, InjuriedPerson 454, DeceasedPerson 474, OfficerDown 496, OfficerBackup 520,
  PlateBackup 544, OfficerInDistress 568, EmsDown 590, Explosion 612, ArtGalleryRobbery 676, HumaneRobbery 696,
  TrainRobbery 716, VanRobbery 736, UndergroundRobbery 755, DrugBoatRobbery 775, UnionRobbery 795, CarBoosting 822,
  SignRobbery 842, BobcatSecurityHeist 862 (35 presets + CustomAlert). Server exports: `GetDispatchCalls` 278,
  `SendTargetedAlert(targets, data)` 506-556.
- Other: `Config.Debug = true` by default (`shared/config.lua:3`: alerts when LEOs break the law and draws zones) — set
  false. `Config.CallLifetime = 30` (125) is used as **minutes** (`server/main.lua:480-491`) while the README says
  seconds. `Config.MdtMapImage` points into ps-mdt (142; cosmetic). Locales: 8 languages, no `sv`, UI English.

## 5. qbx_core — events and data

| Event (server, `AddEventHandler`) | Where | Payload |
|---|---|---|
| `QBCore:Server:PlayerLoaded` | `qbx_core/server/player.lua:979` (end of CreatePlayer, after `UpdatePlayerData` 977) | `Player` object (`.PlayerData.source`) |
| `QBCore:Player:SetPlayerData` | `server/player.lua:1153` (`UpdatePlayerData`, called by SetPlayerData, SetCharInfo 1262-1276, SetMetadata, SetJobDuty, money…) | `PlayerData` |
| `QBCore:Server:OnPlayerUnload` | `server/player.lua:750` (`Logout` only) | `source` |
| `qbx_core:server:playerLoggedOut` | `server/player.lua:757` (after `Wait(200)`, player already removed) | `source` |
| `QBCore:Server:SetDuty` | `server/player.lua:205` (`SetJobDuty`, online players only) | `source, onDuty` |
| `QBCore:Server:OnJobUpdate` | `server/player.lua:266` (SetPlayerPrimaryJob), `:1026` (job definition changed, for every holder) | `source, job` |
| `qbx_core:server:onGroupUpdate` | `server/player.lua:326, 373, 536, 592` | `source, groupName, grade?` |
| `qbx_core:server:onSetMetaData` | `server/player.lua:1212` | `key, oldValue, newValue, source` |
| `QBCore:Server:OnPlayerLoaded` | `server/events.lua:191` is a **`RegisterNetEvent`** fired by the client (`client/character.lua:280`); qbx_core never fires it server-side | — |

- On disconnect `playerDropped` (`server/events.lua:38-57`) only saves and removes the player: **no** OnPlayerUnload.
- Duty at login is restored from the saved job (`server/player.lua:704`) or forced to `defaultDuty` (712-713); no
  SetDuty event fires at login. Duty toggle: net event `QBCore:ToggleDuty` (`server/events.lua:239-250`).
- `exports.qbx_core:GetPlayer(src).PlayerData.citizenid` ✓ (`server/functions.lua:86-94`; `PlayerData.source` set in
  `CheckPlayerData` 610). `PlayerData.license` keeps the stored `players.license` for a loaded character (`playerData.license
  or …`, 611; login only accepts a row whose license equals the player's `license2` or `license`, 111). The
  `license2`-else-`license` fallback applies only to a new character.
- **charinfo** (`server/player.lua:625-634`): `firstname, lastname, birthdate` (default `'00-00-0000'`; creator format
  `YYYY-MM-DD`, `config/client.lua:12`), `gender` (0/1), `backstory, nationality, phone, account, cid`. Also
  `players.phone_number` column (`qbx_core.sql:14`). `metadata.fingerprint`, `metadata.bloodtype`, `metadata.callsign`.
- **Characters per license**: no export. Internal `storage.fetchAllPlayerEntities(license2, license)`
  (`server/storage/players.lua:153-170`, `WHERE license = ? OR license = ?`) and client callback
  `qbx_core:server:getCharacters` (caller's own licenses only, `server/character.lua:28-35`). For the portal: qbx keeps a
  `users` table (`userId, username, license, license2, fivem, discord`, `server/storage/players.lua:4-15`) and
  `players.userId` (`server/events.lua:176-185`); `users.discord` holds `discord:<id>` (identifier with prefix,
  `events.lua:61-73`) but is written **only when the user row is created** on first connect (110-114), so it can be
  NULL/stale — `fredpd_identities (discord_id, license)` is the safer join.
- Mirror/officers comparison: see "Mismatches" — every name and payload FredPD uses matches.

## 6. qbx_vehicles / qbx_garages

- States (`qbx_vehicles/server/main.lua:8-13`): `OUT 0, GARAGED 1, IMPOUNDED 2`.
- **Event**: `qbx_vehicles:server:vehicleSaved(vehicleId)` after every `SaveVehicle` (`qbx_vehicles/server/main.lua:305-320`,
  316) — i.e. park (GARAGED) and take-out (OUT). Payload is only the id; read `player_vehicles` for plate/state.
- **Hooks** (`@qbx_core.modules.hooks`, `qbx_core/modules/hooks.lua:39-53`; each resource that loads it exports its own
  `registerHook(event, fn)`, returning false cancels): qbx_vehicles `createPlayerVehicle {citizenid, garage, props}`
  (169) and `changeVehicleOwner {vehicleId, newCitizenId}` (194); qbx_garages (`server/main.lua:25`)
  `parkVehicle {source, vehicleId, vehicle, garageName}` (309), `spawnVehicle {source, vehicleId, garageName}`
  (`server/spawn-vehicle.lua:113`), `spawnedVehicle {source, vehicleId, vehicle, garageName}` (150). No hook/event on
  `DeletePlayerVehicles` (212-222).
- **Code paths**: park = `lib.callback 'qbx_garages:server:isParkable'` (main.lua:275-284) then
  `'qbx_garages:server:parkVehicle'` (291-322 → hook 309 → `SaveVehicle{state=GARAGED}` 311-315 → DeleteVehicle).
  Take-out = `'qbx_garages:server:spawnVehicle'` (`spawn-vehicle.lua:178`) → `spawnVehicle` (46-176) →
  `setVehicleStateToOut` (19-25) → `TriggerEvent('qbx_garages:server:vehicleSpawned', veh)` (174).
  Bypasses: qbx_garages start moves all OUT to GARAGED in one UPDATE (`main.lua:330-334`, `storage.lua:2-4`);
  qbx_police impound writes `player_vehicles.state` directly (`qbx_policejob/server/storage.lua:13-23`).
- Task 3.4 needs **no patch**: `exports.qbx_garages:registerHook('parkVehicle', fn)` (return true) or the
  `vehicleSaved` event.

## 7. ox_doorlock (v1.22.1)

- `exports.ox_doorlock:getDoor(id)` `ox_doorlock/server/main.lua:53-68` → `{id, name, state, coords, characters, groups,
  items, maxDistance}` or `false`; also `getAllDoors` 70-78, `getDoorFromName(name)` 80-86.
- `setState`: `RegisterNetEvent('ox_doorlock:setState', setDoorState)` 313 and **export** `setDoorState(id, state,
  lockpick)` 314 (275-311). `state` 0/1 or boolean. `authorised = not source or source == '' or isAuthorised(…)` (281)
  skips the checks for both server paths, which is correct for fredpd_breach:
  - A server-side `TriggerEvent('ox_doorlock:setState', …)` runs with `source == ''`. A local event's source defaults
    to an empty string (`citizenfx/fivem@e60d29a code/components/citizen-resources-core/include/ResourceEventComponent.h:51,
    141`), and the Lua event routine assigns it to `_G.source` (`data/shared/citizen/scripting/lua/scheduler.lua:124-180`).
  - An export call `exports.ox_doorlock:setDoorState(…)` runs through the function-reference routine
    (`scheduler.lua:465`), which never sets `_G.source`. So `source` is `nil` in ox_doorlock's runtime, even when a
    net event in another resource made the call (the only exception is a call nested inside one of ox_doorlock's
    own event handlers). That is also why qbx_prison's gate event can open any door (§2a).
- `ox_doorlock:stateChanged` (server event): `TriggerEvent('ox_doorlock:stateChanged', source, doorId, isLocked,
  usedItem|false)` 298-299. The first argument is a player id for a net `setState`, `''` after a server
  `TriggerEvent`, and `nil` after an export call or an autolock relock (293). Listeners must treat both `''` and `nil`
  as "server".
- `exports.ox_doorlock:registerHook('doorAuthorization', fn, { nameFilter })` (`server/hooks.lua:39-59`), payload
  `{source, door, lockpick, authorised}` (240-245). A hook can **grant** but not deny: the result is
  `authorised or hookResult == nil or hookResult` (249).
- **Clients' door list**: once at start `lib.callback('ox_doorlock:getDoors', false, cb)` (`client/main.lua:37`) → the
  server returns the whole `doors` table + sounds (`server/main.lua:316-320`), passcodes included; kept in sync by the
  client events `ox_doorlock:setState` (117) and `ox_doorlock:editDoorlock` (195). No statebags. Client exports:
  `getClosestDoor()` 358, `useClosestDoor()` 357.

## 8. ox_inventory (v2.47.9)

- **Items**: `data/items.lua` returns `{ [name] = { label, weight, stack, close, consume, degrade, description,
  client = { image, anim, prop, usetime, export = 'resource.exportName', event }, server = { export }, buttons } }`
  (example `data/items.lua:2-55`). **An item with `client.export` and no `consume` gets `consume = 1`**
  (`modules/items/shared.lua:32-34`). It is consumed only if the export calls `useItem` (next bullet), so `pd_tablet`
  should set `consume = 0` to guard against a later `useItem` call (`0` is truthy in Lua, so it is kept; C12 does not
  say so).
- **Client export call**: `data.export(data, { name, slot, metadata })` (`client.lua:519`) through
  `exports[resource][export](nil, ...)` (`modules/items/shared.lua:1-5`) → `exports('open', function(data, slot)
  … slot.metadata.serial … end)`. Consumption only happens if the export calls `exports.ox_inventory:useItem(data, cb)`
  (`client.lua:436-480`). Server-side export: `cb('usingItem'|'usedItem'|'buying', item, inventory, slot)`
  (`server.lua:484, 573`, `modules/shops/server.lua:241`).
- **registerHook(event, fn, options)** `modules/hooks/server.lua:118-148`, options `itemFilter` (set of names),
  `inventoryFilter` (Lua patterns on inventory ids), `typeFilter`, `print`; returns a hook id; returning `false`
  rejects. **swapItems payload** (`modules/inventory/server.lua:1783-1792`): `{ source, fromInventory, fromSlot (slot
  table), fromType, toInventory, toSlot (slot table or number), toType, count, action = 'move'|'stack'|'swap' }`;
  drop variant 1625-1636 adds `dropId`, `toInventory = 'newdrop'`.
- **Queries**: `GetItemCount(inv, itemName, metadata?, strict?)` → number (`modules/inventory/server.lua:2322-2341`);
  `Search(inv, 'count'|'slots', items, metadata?)` (1248-1293) → number/slot list for one item, a map for several,
  `false` if the inventory is unknown. Also `GetSlot`, `SetMetadata`, `GetSlotsWithItem`.
- Qbox recipe **overwrites `data/items.lua`** with Qbox's list (`txAdminRecipe/qbox.yaml:458-461`).

## 9. ox_lib (v3.39.0)

- **Callbacks**: server `lib.callback.register(name, function(source, ...) … end)` (`imports/callback/server.lua:116-124`;
  an error in the handler returns nothing to the client, 97-108); server→client `lib.callback.await(name, playerId, ...)`
  (93). Client `lib.callback(name, delay|false, cb, ...)` / `lib.callback.await(name, delay|false, ...)`
  (`imports/callback/client.lua:88-114`); a call within `delay` ms of the previous one returns nil immediately (27-49).
- **addCommand**: `lib.addCommand(name|names, { help, params = {{name, type = 'number'|'playerId'|'string'|'longString',
  help, optional}}, restricted = true|'group.admin'|{…} }, function(source, args, raw) … end)`
  (`imports/addCommand/server.lua:9-18, 111-173`). A string/table `restricted` → `RegisterCommand(…, true)` +
  `lib.addAce(principal, 'command.<name>')` (149-163) — needs the four `add_ace resource.ox_lib …` lines
  (server.cfg.example has them).
- **Locale**: `lib.locale()` loads `locales/en.json`, deep-merges `locales/<ox:locale>.json`, then **flattens nested
  tables with dots** (`imports/locale/shared.lua:16-28, 65-91`). Flat keys such as `"mdt.search.placeholder"` are kept
  as-is, so FredPD's flat dotted files are compatible. `locale(key, ...)` runs `string.format` only when extra args
  are passed (33-45) — FredPD's `L()` passes the key only and does `{name}` itself (`fredpd_core/shared/locale.lua:35-41,
  59-66`), so `%` in texts is safe. One trap: ox_lib replaces `${other.key}` inside values with that key's text
  (79-87); FredPD locales contain no `${` today (checked) — keep it that way. Client locale follows the player's ox_lib
  setting (`resource/locale/client.lua:18`), server the `ox:locale` convar (`resource/locale/server.lua:9`).

## 10. oxmysql (v2.14.1)

- **DATETIME/TIMESTAMP/DATE → epoch milliseconds**, parsed by `new Date('YYYY-MM-DD HH:MM:SS').getTime()`
  (`oxmysql/src/utils/typeCast.ts:30-43`; execute path 8-25) — a string without zone is **local time of the FXServer
  process**, so UTC-stored values are shifted on a Stockholm host. C12's `DATE_FORMAT(…'%Y-%m-%dT%H:%i:%sZ')` rule is
  right. `TINYINT(1)` → **boolean** (44-45; HEAD changed NULL handling, 887d841) — FredPD already accepts both
  (`fredpd_core/server/canview.lua:30`, `shared/grants.lua` `truthy`).
- **MySQL.transaction.await(queries, params?)** (`src/database/rawTransaction.ts:15-92`): one pooled connection,
  `BEGIN`, each query in order, `COMMIT` → `true`; any error → `ROLLBACK`, logs, fires `oxmysql:transaction-error` and
  returns `false` (no per-query results). Query forms (`src/utils/parseTransaction.ts:7-34`): `{ 'sql', … }` with shared
  params, `{ { query = , values|parameters = }, … }`, or `{ { 'sql', params }, … }`. It is a **fixed batch**: no
  intermediate result (insert id, `SELECT … FOR UPDATE` row, `MAX(n)`) reaches Lua before `COMMIT`, so "read a value,
  compute in Lua, write in the same transaction" cannot be done with it.
- **Interactive transaction**: `MySQL.startTransaction(function(query) … end)` (`lib/MySQL.lua:151-153` →
  `src/index.ts:81-87`, `src/database/startTransaction.ts:18-52`). It is marked **experimental** (a `console.warn` on
  every call, index.ts:85). One connection, `BEGIN`, then the Lua function runs `query(sql, params)` as often as it
  needs and gets each result. Returning `false` rolls back; anything else commits when the connection is disposed
  (`src/database/connection.ts:61-66`). There is a hard **30 s** limit (startTransaction.ts:30, 39). A Lua call to the
  JS `query` gets a promise, which Lua awaits through the `__cfx_async_retval` bridge
  (`citizenfx/fivem@e60d29a data/shared/citizen/scripting/v8/main.js:185-187`, `lua/scheduler.lua:569-572`); in-game
  **UNVERIFIED**.
- **Hang on pool errors**: `rawTransaction.ts:31`, `rawQuery.ts:29` and `rawExecute.ts:34` all do `using connection =
  await getConnection()` *outside* their `try`. If the pool cannot hand out a connection (DB down, connect timeout),
  the async function rejects, the callback is never called, and every `MySQL.*.await` in Lua (`lib/MySQL.lua:15-27`,
  a promise resolved only from that callback) **never resumes**. FredPD code should not assume an `.await` returns
  after a DB outage (e.g. a start-up migration runner holding a lock).
- **affectedRows**: `MySQL.update` returns `affectedRows` (`src/utils/parseResponse.ts:10`). oxmysql only adds
  `CONNECT_WITH_DB` to user flags (`src/config.ts:102-103`). The mysql2 it bundles is `mysql2@3.22.2` plus a patch
  (`oxmysql/package.json:28, 43`; the patch touches only connection.js, encode_parameter and the parsers). Its default
  flags include `FOUND_ROWS` (npm `mysql2@3.22.2` `lib/connection_config.js:226-229`, same in the repo's own 3.24.4), so
  an UPDATE reports **matched** rows and an unchanged `INSERT … ON DUPLICATE KEY UPDATE` reports 1. `officers.lua` already relies on this correctly
  (`INSERT IGNORE`, `WHERE discord_id <> ?`). A connection-string `flags=["-FOUND_ROWS"]` would change it.

## 11. ps-housing (and qbx_properties)

- Licence **CC BY-NC-SA 4.0** (LICENSE) — same problem as ps-mdt: never copy or patch it; call its exports only.
Neither repo is fetched; refs are `Project-Sloth/ps-housing@eaba693` and `Qbox-project/qbx_properties@9bbdb43`.

- Exports: `getMainDoor(propertyId, doorIndex, isShell)` (`ps-housing@eaba693 server/server.lua:174-188`; MLO → the
  ox_doorlock door named `ps_mloproperty<propertyId>_<doorIndex>` via `getDoorFromName`, shell → `{ coords }`),
  `IsOwner(src, propertyId)` (431), `registerProperty` (193). No lock-state event.
- Police raid: net event `ps-housing:server:raidProperty(property_id)` (`ps-housing@eaba693 server/sv_property.lua:628-700`): job in
  `Config.PoliceJobNames`, on duty, grade ≥ `Config.MinGradeToRaid` (3), item `Config.RaidItem = "police_stormram"`
  (`ps-housing@eaba693 shared/config.lua:34-47`); MLO → `ox_doorlock:setDoorState(door.id, 0)` for every door (677-683), shell →
  `Property:StartRaid` (141). Shells cannot be opened from another resource (no export; the net event needs a player
  source). Defaults `Config.Target = "qb"`, `Config.Inventory = "qb"` (10, 13) must be `"ox"` on Qbox; needs
  `fivem-freecam` (`ps-housing@eaba693 fxmanifest.lua:14-16`). Installed on Rami's server: **UNVERIFIED**.
- qbx_properties: no exports at all (`qbx_properties@9bbdb43 server/property.lua:165` is its only server event) → only the
  `ox_doorlock-only` style adapter or no-op is possible.

## 12. screenshot-basic

- Client export `requestScreenshotUpload(url, field, options?, cb)` (`screenshot-basic/src/client/client.ts:49-66`); when
  `cb` is omitted the third argument is the callback (50-55), so `(url, field, cb)` works; defaults `encoding 'jpg'`.
  The **player's CEF** posts the multipart upload, so the URL must be reachable from players' PCs and carry a
  per-request token. Server export `requestClientScreenshot(player, options, cb)` (README "Server") saves on the
  FXServer instead (no public URL).
- The fxmanifest builds `dist/` at start via `dependency 'yarn'` / `'webpack'` (cfx-server-data builders).
- Qbox recipe servers run itschip/screencapture instead (all three recipes, e.g. `qbox.yaml:62-67`): AGPL-3.0, `provide 'screenshot-basic'`,
  same export (`game/client/bootstrap.ts:49-100`, default encoding `webp`), and the upload is proxied by the FXServer
  (`game/server/process-upload.ts:100-109`) so a localhost URL works. Which one Rami runs: **UNVERIFIED**.

## 13. FiveM server JS runtime (citizenfx/fivem@e60d29a)

- `SetHttpHandler(fn(req, res))` (`code/components/citizen-server-impl/src/ResourceHttpHandler.cpp:42-62, 103-236`):
  `req = { headers (map string→string, names as sent), method, address, path ('/' + part after '/<resource>/'),
  setDataHandler(cb[, 'binary']), setCancelHandler(cb) }` — `cb(body)` gets the body as a string (or byte array in
  binary mode, 146-180); `res = { write(str), writeHead(status[, headers]), send([str]) }` (182-232). Every resource
  endpoint is rate-limited per peer address, **10/s burst 25 → 429** (`HandleRequest` 67-79), **except** for proxy
  addresses (`if (!fx::IsProxyAddress(address) && !limiter->Consume(address))`, 72). The default `sv_proxyIPRanges`
  is `10.0.0.0/8 127.0.0.0/8 192.168.0.0/16 172.16.0.0/12` (`code/components/citizen-server-net/src/ProxyAddressList.cpp:182-197`),
  so the service's pushes from `127.0.0.1` (or a private LAN/docker address) are exempt by default. Two caveats: IPv6
  `::1` is **not** in the list, so the service should target `127.0.0.1`, not `localhost`; and a server that overrides
  `sv_proxyIPRanges` loses the exemption.
  `fredpd_core/server/http.js` matches this API (lower-cases headers at 102, `writeHead` + `send` 107-108,
  `setDataHandler` 292).
- **Node**: server `.js` files are run by `citizen-scripting-node` for any file (`NodeScriptRuntime.cpp:605-612`),
  started with `--fork-node22` (494) → Node 22, global `fetch` available. `node_version` is only read by the client V8
  runtime (`citizen-scripting-v8/src/V8ScriptRuntime.cpp:2061`). Rami's FXServer artifact: **UNVERIFIED**; older
  artifacts ran Node 16 (no `fetch`) — http.js's `node:http` fallback covers that.
- **JS → Lua export in the same resource**: `exports[res][name](...)` emits `__cfx_export_<res>_<name>` and caches the
  returned function (`data/shared/citizen/scripting/v8/main.js:548-603`); Lua `exports(name, fn)` answers that event
  (`data/shared/citizen/scripting/lua/scheduler.lua:627-653` + export registration). Works across runtimes in one
  resource (events are per resource, not per runtime); in-game **UNVERIFIED**.
- **Lua function as callback to a JS export**: Lua functions are packed as function references
  (`scheduler.lua:590-624`, `msgpack.settype("function", EXT_FUNCREF)`); JS unpacks them into a callable
  (`main.js:89-130`) that stays valid for later async calls. oxmysql (a JS resource calling Lua callbacks after async
  I/O, `oxmysql/src/database/rawTransaction.ts:83-86`) is the production proof of the pattern.

## Mismatches with FredPD code

| Where (our repo) | Finding | Change |
|---|---|---|
| `fredpd_core/server/mirror.lua:341, 350, 355` | `QBCore:Server:PlayerLoaded(Player)`, `QBCore:Player:SetPlayerData(PlayerData)`, `QBCore:Server:OnPlayerUnload(src)` — names and payloads match (§5). OnPlayerUnload fires only on `/logout`, never on disconnect | none; drop the "VERIFY" markers; comment at 354 could say "logout only" |
| `fredpd_core/server/officers.lua:342, 346, 350` | PlayerLoaded, `QBCore:Server:SetDuty(src, onDuty)`, `QBCore:Server:OnJobUpdate(src, job)` match. OnJobUpdate also fires for every holder when a job definition changes (player.lua:1026) — handler is idempotent | none |
| `docs/modules/core.md:143-150, 180` | asks 0.3 to confirm names and that `OnPlayerLoaded` is client-fired | confirmed (events.lua:191 RegisterNetEvent, character.lua:280) — owner can remove the VERIFY notes |
| `docs/contracts.md` C12 (Items) | `pd_tablet` with `client.export` gets `consume = 1` implicitly | add `consume = 0`; export signature `(data, slot)` |
| `docs/contracts.md` C12 (Items) / deps `ox_inventory` PATCH | recipe replaces `data/items.lua`; a git patch against upstream items.lua won't apply there | decide: document a paste block, or a patch generated from Rami's actual items.lua |
| IMPLEMENTATION.md §3 qbx_police row | `IsLeoAndOnDuty(player, minGrade)` takes a Player; `hasGrant` is `(src, type, key)`; stormram has no code in qbx_police | patch as in §2 above |
| IMPLEMENTATION.md §5.5 acceptance, `fredpd_devtools` | `exports['ps-dispatch']:Shooting()` is a **client** export; devtools is server-only | trigger it client-side (devtools client script or a `TriggerClientEvent` to the tester) |
| `docs/contracts.md` C13 "priority clamped to 1–3" | ps-dispatch has a priority **0** critical tier (`server/main.lua:296-298`, `Config.CriticalCodes`) | clamp to 0–3, or accept that critical calls become 1 |
| `docs/contracts.md` C14 `issueFine` "BillPlayer path verified" | `police:server:BillPlayer` is a client net event (officer within 2.5 m, no on-duty/price checks, main.lua:291-303); it cannot be called server-side | the billing adapter must do what `IssueFine` does itself: `RemoveMoney('bank', …)` + `exports['Renewed-Banking']:addAccountMoney('police', …)` with refund on failure (main.lua:626-636); Renewed-Banking presence **UNVERIFIED** |
| `docs/contracts.md` C16 `item_uid` | evidences items carry no unique id, and a uid minted in an ox_inventory `createItem` hook is **client-overwritable**: `collect` copies client metadata over it (`actions.lua:61, 75, 92-94`), and the unauthenticated `evidences:syncEvidence` → `atItem` writes any metadata into any inventory slot (§3) | mint in a `createItem` hook **and** PATCH evidences (strip reserved keys in `collect`, whitelist `remove.fun` and the net `syncEvidence` methods, `atItem`/`removeFromItem` only on `inventory == source`); fredpd_forensics additionally keeps a uid registry (name + inventory at mint, type/owner when first seen, moves via `swapItems`) and rejects mismatches |
| `docs/contracts.md` C16 `evidenceItemAnalysed(playerId, item)` | payload confirmed, but no inventory id is passed, `getItem` accepts any stash (`dui/callbacks.lua:150-159`), and `information`/`owner` are client data (202-205) | fredpd_forensics uses only `name`, `slot`, `metadata[type].analysed` and the registry-checked uid; stores `information` as client-asserted text |
| `docs/contracts.md` C14 numbering | `MySQL.transaction.await` is a fixed batch (§10): "seq incremented in the same transaction as the insert, then `formatId` in Lua" and "`MAX(n)+1` under `SELECT … FOR UPDATE`" cannot be done with it | case `seq`: allocate first with `fredpd_core/server/db.lua` `NEXT_SEQ_SQL` (`LAST_INSERT_ID(value + 1)`, insert id = new value), then insert (a failed insert leaves a gap), or run both in `MySQL.startTransaction` (experimental, 30 s). Report/evidence `n`: `INSERT … SELECT COALESCE(MAX(n),0)+1 … WHERE case_id = ?` in SQL plus retry on the `(case_id, n)` duplicate key (as `003_records.sql:5-7` already plans), then read `n` back for the `formatId` tag, or do it all in `startTransaction`. Every `.await` can hang on pool errors (§10) |
| IMPLEMENTATION.md §5.5 "duty event from qbx_police" | qbx_police has no duty event | use `QBCore:Server:SetDuty` (qbx_core) |
| IMPLEMENTATION.md §5.6 scene_evidence | evidences has no `toolmark` type; `blood` needs a DNA owner | use `fingerprint`/`blood`/`casing`… only, or keep toolmarks FredPD-side |
| IMPLEMENTATION.md §3 ps-dispatch row | "turn off NUI via config flag": none exists | patch (Decisions) |
| IMPLEMENTATION.md §4.2 "player_vehicles insert/delete hooks" | create/owner-change hooks exist (pre-write, can cancel); no delete hook/event | keep refresh-on-miss for deletes |
| `server.cfg.example` (not mine) | missing `ensure PolyZone` (ps-dispatch) or its patch, `ensure qbx_vehicles` (before qbx_garages), `ensure screenshot-basic`/screencapture, `fivem-freecam` for ps-housing; `qbx_policejob` vs recipe folder `qbx_police` | owner of server.cfg.example to update after Rami confirms his folders |
| `server.cfg.example:57` `ensure qbx_prison` (now resolved: 57-61 comment it out and warn) | qbx_prison lets any client unlock any ox_doorlock door and clear its own sentence (§2a); all three recipes ship xt-prison | owner: `ensure xt-prison` (recipe folder `[standalone]/xt-prison`), never qbx_prison |
| `server.cfg.example:48-50` evidences "fetched into resources/[upstream]" | the git checkout has no `html/dui/laptop/dist` (`evidences/fxmanifest.lua:40`), so the laptop UI cannot load from it; the same holds for ox_lib/ox_inventory/ox_doorlock (`web/build`) and oxmysql (no `fxmanifest.lua` in git at all) | owner: run evidences (and ox_*) from the pinned **release zip** (`release` in deps.lock.json); `[upstream]` is for patching/review only |
| `config/integrations.json:5` `"prison": "qbx_prison"` | default points at the resource Decision 2 rejects | owner: default `"xt-prison"` (adapter to add in task 4.1), `"none"` when absent |
| `fredpd_core/adapters/prison/qbx_police_jail.lua` | qbx_police has **no jail**: without a prison resource `JailPlayer` only sets `injail`/`criminalrecord` metadata and fires a client event nobody implements (§2); the net event also needs the officer within 2.5 m | drop the adapter (use `none`), or rescope it to "metadata only, no confinement" and say so |
| `fredpd_core/adapters/prison/qbx_prison.lua` | resource not recommended (§2a) | keep only as an opt-in for servers that already run it; add an `xt-prison.lua` adapter: `exports['xt-prison']:SetJailTime` for time changes of a jailed player, `lib.callback.await('xt-prison:client:enterJail', src, minutes)` to confine, `…:client:exitJail` to release (§2a); FredPD's record is the authority |
| IMPLEMENTATION.md §3 Prison row (:102), §9 table (:423), task 4.1 (:368) | "qbx_prison default; else qbx_police built-in jail" — neither holds (§2, §2a) | default xt-prison adapter; alternatives `none`, qbx_prison (opt-in, insecure); drop "built-in jail" |
| `scripts/fetch-deps.mjs` (not mine) + REUSE pins in deps.lock.json | REUSE pins of resources the recipe already installs (ox_*, qbx_core, qbx_vehicles, qbx_garages, screenshot-basic) are cloned into `resources/[upstream]`; deployed next to `[ox]`/`[qbx]` FXServer sees duplicate resource names and may start the unbuilt copy | owner of fetch-deps: add a mode that is recorded but not fetched (e.g. `PIN`), or fetch outside `resources/`; until then, never deploy `resources/[upstream]` wholesale — only the PATCH resources |
| `fredpd_core/adapters/housing/qbx_properties.lua` | qbx_properties has no API | keep as permanent no-op (or ox_doorlock-only) |
| `fredpd_core/fxmanifest.lua:8` | `node_version '22'` is ignored server-side on current artifacts | harmless; keep |

## Decisions

1. **ox_\* → overextended** for all five (superset of CommunityOx, active in 2026). Pin the latest **release tag**
   and run its release zip (documented install; git has no built UI). `scripts/fetch-deps.mjs` fetches the git tree
   at that commit (for patches/review) — it does not download the zip; the `release` field is ready for that.
2. **Prison → xt-prison adapter** (default); `none` when no prison resource runs; **no** "qbx_police jail" (it does
   not exist, §2). Reasons:
   - All three Qbox recipes install xt-prison (§1).
   - qbx_prison is unmaintained, and its gate event lets any client open any ox_doorlock door (§2a). That breaks
     station security and fredpd_breach, so qbx_prison is **not run**: lock mode REFERENCE. It stays available as an
     opt-in adapter only for a server that already runs it, and then only after a patch that validates `gateKey`
     against its configured gates.
   - A FredPD-built jail would be the only server-authoritative option, but it is out of scope for now.

   The adapter confines with `lib.callback.await('xt-prison:client:enterJail', src, minutes)` and changes the time of an
   already-jailed player with `SetJailTime` (§2a). xt-prison lets a client zero its own sentence (§2a). No LICENSE, so
   no patch can be shipped. FredPD's `fredpd_records` jail row is therefore the authority. A cheap detector is a server
   `AddStateBagChangeHandler('jailTime', …)` that audits a drop to 0 before the recorded release time (**UNVERIFIED**:
   whether client-set replicated state reaches server handlers in time). **Ask Rami** whether his server runs
   xt-prison.
3. **ps-dispatch NUI off**: one server hunk — guard the three client sends (`broadcastCall` at `server/main.lua:306` and
   `335`, targeted loop 547-552) behind a convar (e.g. `fredpd:psd_ui`, default off) so no client ever receives
   `ps-dispatch:client:notify` (no popup, blip, sound or NUI message) — plus a client hunk that skips registering the
   `E`/`O` keybinds (`client/main.lua:414-430`) under the same convar (otherwise `O` opens an empty board and takes
   NUI focus). `ui_page` stays (idle frame). Same patch file adds the `fredpd:dispatch:incoming` line (C13) and removes the three
   `@PolyZone` includes. Set `Config.Debug = false`.
4. **lsn-radar**: omit (no code reference).
5. **evidences**: upstream ox_target, no fork. sv locale + items via task 4.2. Mode **PATCH** (was REUSE). A small
   hunk in `server/evidences/api.lua` (net `syncEvidence`: method whitelist, and `atItem`/`removeFromItem` only on
   `inventory == source` without client `data`) and one in `server/evidences/actions.lua` (`collect`: strip reserved
   metadata keys, `remove.fun` must be `removeFrom*`). Without them C16's `item_uid` and custody chain can be forged
   by any client (§3). Task 4.2 writes the patch; fredpd_forensics also keeps the uid registry.
6. **screenshot-basic**: pinned as listed, but prefer `requestClientScreenshot` (server-side save) or screencapture on
   a recipe server so `/upload` need not be public. Do not run both.
7. **ps-housing**: adapter only (exports + ox_doorlock door names); not in deps.lock (Rami's install, NC licence).

## Open questions

- Which txAdmin recipe did Rami use: `qbox.yaml` (Qbox resources from `main`, matches the HEAD pins),
  `qbox-lean.yaml` or `qbox-stable.yaml` (qbx_core v1.24.0 / qbx_vehicles v1.4.2 / qbx_garages v1.1.4 release zips;
  stable has no qbx_police)? Keep the HEAD pins only for `qbox.yaml`; otherwise re-pin to those tags' commits and
  re-verify §5/§6.
- Which of qbx_police/qbx_policejob folder, xt-prison (or qbx_prison), screenshot-basic/screencapture, ps-housing does
  Rami's server run, and which ox_* versions are installed now?
- ox_inventory items: patch vs documented paste block (recipe-replaced `data/items.lua`).
- Should fetch-deps download `release` zips for the tag-pinned resources (needs a script change, not in this task)?
