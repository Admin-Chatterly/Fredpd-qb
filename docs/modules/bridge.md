<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Module: framework bridge (fredpd_core, docs/contracts.md §C17)

FredPD resources never call a framework, inventory, target or doorlock resource directly. They call fredpd_core's
bridge, which picks one implementation per kind from `config/integrations.json`:

| kind | values | `auto` order (first **started**, then starting, then installed, else default) | default |
|---|---|---|---|
| framework | `qb-core` \| `qbx_core` | qbx_core, qb-core | qb-core |
| inventory | `qb-inventory` \| `ox_inventory` | ox_inventory, qb-inventory | qb-inventory |
| target | `qb-target` \| `ox_target` | ox_target, qb-target | qb-target |
| doorlock | `qb-doorlock` \| `ox_doorlock` | ox_doorlock, qb-doorlock | qb-doorlock |

An unknown value warns once and falls back to `auto`. **`auto` is decided once, when fredpd_core starts** (the
implementations bind upstream events at load): when neither resource of a pair is started or starting yet, it takes
the first *installed* one (ox first). So with `auto`, ensure the upstream resources **before** fredpd_core; if auto
picked a resource that never came up while the other one runs, the 15 s re-check logs one warning naming the value to
set. The shipped `config/integrations.json` uses explicit values, which avoids this. Switching = change the value and restart fredpd_core (and the
resources that include the client file). Line numbers below are **upstream at the pin** (deps.lock.json).

## Files

| File | Role |
|---|---|
| `fredpd_core/bridge/select.lua` | pure selection (`resolve(kind, configured, stateOf)`), shared by server and client |
| `fredpd_core/bridge/framework/normalize.lua` | PlayerData → normalised player/job; money argument validation (pure, also sent to clients) |
| `fredpd_core/bridge/framework/qb_core.lua`, `qbx_core.lua` | server framework implementations |
| `fredpd_core/bridge/inventory/qb_inventory.lua`, `ox_inventory.lua` | server inventory implementations |
| `fredpd_core/bridge/doorlock/qb_doorlock.lua`, `ox_doorlock.lua` | server + client doorlock implementations |
| `fredpd_core/bridge/target/options.lua`, `qb_target.lua`, `ox_target.lua` | client target option normalisation + implementations |
| `fredpd_core/bridge/client.lua` | client facade `FredBridge` (framework job hint, target, doorlock); other resources include it with `'@fredpd_core/bridge/client.lua'` |
| `fredpd_core/server/bridge.lua` | server facade: load/select, guarded calls, exports, normalised events, capability report, `hasFeature` |
| `fredpd_core/client/bridge.lua` | client exports `clientBridgeInfo`, `listDoors(cb)` |
| `patches/qb-doorlock.10-fredpd-bridge.patch` | qb-doorlock server exports `getDoor`, `setDoorState` + server event `qb-doorlock:server:doorChanged` |
| `patches/qb-core.10-fredpd-items.patch` | `pd_tablet`, `pd_ram` in qb-core `shared/items.lua` |
| `tests/lua/bridge_*_test.lua` | 42 tests in 6 files (harness `bridge_harness_test.lua`, which also offers `useQbx()` for other server tests) |

fxmanifest: hard `dependencies` are only `ox_lib` and `oxmysql`; the framework/inventory/target/doorlock resources
are checked with `GetResourceState`. The bridge files the client needs are in `files` (read with `LoadResourceFile`
by `bridge/client.lua` in whichever resource includes it); `config/integrations.json` is not sent to clients — the
server replicates only its choice in the convars `fredpd_bridge_framework`, `fredpd_bridge_target`,
`fredpd_bridge_doorlock` (`SetConvarReplicated`).

## Server interface (exports on fredpd_core)

| export | returns | qb | ox / Qbox |
|---|---|---|---|
| `getPlayer(src)` | `{ source, citizenid, license, name, job = { name, label, type, grade (level), gradeName, onduty, isboss }, charinfo }` \| nil | `exports['qb-core']:GetCoreObject({ 'Functions' })` (shared/main.lua:7-18) → `Functions.GetPlayer` (server/functions.lua:46-52) | `exports.qbx_core:GetPlayer` (server/functions.lua:86-94) |
| `getPlayerByCitizenId(cid)` | src \| nil | `Functions.GetPlayerByCitizenId` (:57-59) | `GetPlayerByCitizenId` (:98-110) |
| `getPlayers()` | sorted srcs with a character | `Functions.GetPlayers` (:115-121) | `GetQBPlayers` keys (:143-147) |
| `removeMoney(src, account, amount, reason)` | boolean | `Player.Functions.RemoveMoney` (server/player.lua:209-243; Functions built by `buildMethodTable` :22-43) | `exports.qbx_core:RemoveMoney` (server/player.lua:1371-1423) |
| `addMoney(src, account, amount, reason)` | boolean | `Player.Functions.AddMoney` (:185-207) | `exports.qbx_core:AddMoney` (:1320-1364) |
| `count(src, item)` | integer | `exports['qb-inventory']:GetItemCount` (server/functions.lua:357-376) | `GetItemCount` (modules/inventory/server.lua:2322-2341) |
| `find(src, item, filter?)` | `{ slot, metadata }[]` by slot; metadata ⊇ filter | `GetItemsByName` (:319-333), metadata = `info` (AddItem :736-750) | `GetSlotsWithItem` (:2272-2295) |
| `add(src, item, count, metadata?)` | boolean | `AddItem(src, item, n, nil, info, 'fredpd')` (:711-802) | `AddItem(src, item, n, metadata)` (:1126-1242) |
| `remove(src, item, count, slot?)` | boolean | `RemoveItem(src, item, n, slot, 'fredpd')` (:812-899) | `RemoveItem(src, item, n, nil, slot)` (:1336-1445) |
| `registerUsable(item, fn(src, slot, metadata))` | boolean | `exports['qb-core']:CreateUseableItem` (server/functions.lua:491-510, exported :735-739), called by qb-inventory `UseItem` (server/functions.lua:226-235) with the server-side slot item | item definition `server = { export = 'fredpd_core.useItem' }` (ox modules/items/shared.lua:1-5, 49-50; `usingItem` server.lua:484, `false` cancels) |
| `getDoor(id)` | `{ id, name, locked, coords }` \| nil | patched `exports['qb-doorlock']:getDoor` | `exports.ox_doorlock:getDoor` (server/main.lua:53-68, `state == 1`) |
| `setLocked(id, locked, src?)` | boolean | patched `exports['qb-doorlock']:setDoorState` | `exports.ox_doorlock:setDoorState(id, 0\|1)` (:275-314) |
| `hasFeature(name)` | boolean | `'evidence'` = inventory ox_inventory **and** target ox_target **and** `evidences` started; `'inventoryHooks'` = ox_inventory | |
| `bridgeInfo()` | `{ framework, inventory, target, doorlock, hooks, evidence }` | | |

Internal: `useItem` (ox_inventory's item callback; only ox_inventory may call it, `Core.internalExport`).
In fredpd_core itself `Core.getPlayerData(src)` now returns the **normalised** bridge player (perms, officers, mirror,
audit, canview read `citizenid`, `job.type`, `job.onduty`, `charinfo`, `license` — all present).

Every call validates its arguments (src positive integer, item `^[%w_%-.]+$` ≤ 64, count 1..1e6, account `^[%a_]+$`,
amount rounded, > 0), checks the resource state (`REQUIRES`: qb-inventory's `registerUsable` needs qb-core), and runs
in `pcall`: a down resource gives the fallback (`nil`, `{}`, `0`, `false`) and **one** warning; an upstream error is
logged at most once per minute per method. `registerUsable` is remembered and re-applied when the inventory (or qb-core)
restarts; qb-core also drops it when fredpd_core stops (qb-core server/events.lua:23-29).

## Normalised server events (server-local: `TriggerEvent`, consumers `AddEventHandler`; never net)

| event | qb-core source | qbx_core source |
|---|---|---|
| `fredpd:bridge:playerLoaded(src)` | `QBCore:Server:PlayerLoaded(Player)` server/player.lua:458 (Players[src] already set :455) | same, server/player.lua:979 |
| `fredpd:bridge:playerUnloaded(src)` | `QBCore:Server:OnPlayerUnload(src)` player.lua:351 (logout), events.lua:17 (drop) | `OnPlayerUnload` player.lua:750 (logout) + `playerDropped` |
| `fredpd:bridge:jobChanged(src)` | `QBCore:Server:OnJobUpdate(src, job)` events.lua:200-208 (re-fired from `OnPlayerUpdated` 'job'/'all') when name/type/grade differ | `OnJobUpdate` player.lua:266, :1026 |
| `fredpd:bridge:dutyChanged(src, onduty)` | `OnJobUpdate` with only `onduty` changed (SetJobDuty) or `QBCore:Server:SetDuty` events.lua:189 — deduplicated | `QBCore:Server:SetDuty` player.lua:205 |
| `fredpd:bridge:doorChanged(id, locked)` | patched `qb-doorlock:server:doorChanged` (player toggle, export, autoLock) | `ox_doorlock:stateChanged(source, id, locked)` server/main.lua:293, 298 |

Internal (not an event, because qbx fires `QBCore:Player:SetPlayerData` on every money/hunger tick):
`Bridge.onPlayerUpdated(fn(src, player))` — qb: `QBCore:Server:OnPlayerUpdated` (player.lua:55-62) except keys
money/metadata/items/position; qbx: `QBCore:Player:SetPlayerData` (player.lua:1153). Used by the search mirror.
Jobs of online players are primed at start (`primeOnline`), so a fredpd_core restart still sees the next change.

## Client (`FredBridge`, include `'@fredpd_core/bridge/client.lua'`)

- `FredBridge.target.addGlobalVehicle(opts)`, `addModel(models, opts)`, `addBoxZone(name, { coords, size, rotation?,
  debug? }, opts)`, `addEntity(netIds, opts)` → handle \| nil; `remove(handle)`. `opts`: one option or a list of
  `{ name, label, icon?, distance?, canInteract?(entity, distance, coords), onSelect({ entity, coords, distance }) }`.
  - ox_target (client/api.lua:54-61, 88-113, 195-205, 235-272, 278-318): options passed through, removal by `name`.
  - qb-target (registration.lua): `{ options, distance = max option distance }`; options are keyed **by label**
    (SetOptions :5-14), removal by label; `action(entity)` → `onSelect` with `GetEntityCoords(entity)`, distance nil
    (client.lua:505-506); `canInteract(entity, distance, data)` → coords nil (client.lua:48-60); `addEntity` converts
    network ids to entities **once, at the call**: an id whose entity is not streamed in on this client then is skipped
    and never gets the options later, and `remove` misses entities no longer local (ox_target keeps network ids and
    has neither limit). Callers on qb-target add entity options when the entity is known to exist locally (e.g. right
    after creating/receiving it) and prefer `addModel`/`addGlobalVehicle` for long-lived targets. No event-free way
    exists to re-add on stream-in without polling (§0 forbids it); box zone → `AddBoxZone(name, center, length = size.y, width = size.x, { heading, minZ,
    maxZ, debugPoly })` (:29-38).
- `FredBridge.doorlock.listDoors()` (ox: `lib.callback.await 'ox_doorlock:getDoors'` — call from a thread; qb:
  `exports['qb-doorlock']:GetDoorList()` client.lua:930-932, filled after `QBCore:Client:OnPlayerLoaded`),
  `onDoorChanged(cb(id, locked))` (ox net `ox_doorlock:setState`; qb net `qb-doorlock:client:setState` client.lua:362).
- `FredBridge.framework.getJob()` → normalised job \| nil, a **hint** for `canInteract` only (the server decides).
  Fetched once with `exports[fw]:GetPlayerData()` (qb client/functions.lua:38-41 exported :1128-1132; qbx
  client/functions.lua:41-45), kept current by `QBCore:Client:OnJobUpdate`, `QBCore:Client:SetDuty`,
  `QBCore:Player:SetPlayerData`, load/unload (both frameworks fire these names).

## Degradation (start-up)

One info line, e.g. `bridge: framework=qb-core, inventory=qb-inventory (hooks: no), target=qb-target,
doorlock=qb-doorlock (needs its FredPD patch); evidence: off (needs ox_inventory + ox_target + evidences)`.
A configured resource that is `missing` → one warning at once; installed but not started → one re-check after 15 s,
one warning if still down. `evidences` installed but the ox pair not selected → one warning ("fredpd_forensics stays
idle and the police job keeps its own evidence"). The ox pair selected but `evidences` installed and not started yet
(ensured after fredpd_core) → the report says `evidence: pending (evidences is stopped; on once it starts)` and one
re-check after 15 s warns only if it is still down (`hasFeature('evidence')` is live, so it turns true once evidences
starts). qb-doorlock without the patch → one warning, `getDoor` nil,
`setLocked` false (breach disabled).

## Integration requests (call sites to move to the bridge)

See the orchestrator report; each FredPD resource replaces its direct calls with `exports.fredpd_core:<fn>` (server)
or `FredBridge.*` (client, add `'@fredpd_core/bridge/client.lua'` to `client_scripts`), listens to `fredpd:bridge:*`
instead of `QBCore:Server:*`, and drops `qbx_core`/`ox_*` from its fxmanifest `dependencies` (and
`'@qbx_core/modules/playerdata.lua'`). fredpd_forensics keeps its ox calls but must stay idle unless
`exports.fredpd_core:hasFeature('evidence')`.

## UNVERIFIED (needs the game)

1. Function references across exports: qb-core `GetPlayer` returns a Player object; its `Functions.RemoveMoney` /
   `AddMoney` closures cross the export boundary as function references (standard CFX behaviour, not run here).
2. `GetResourceState('qb-core')` on a Qbox server where qbx_core `provide`s qb-core (fxmanifest.lua:72): assumed
   `missing`; `auto` prefers qbx_core anyway.
3. qb-target box zones through PolyZone `BoxZone:Create(center, length, width, options)` (PolyZone is not fetched):
   length/width/heading mapping and minZ/maxZ.
4. `SetConvarReplicated` values visible to clients before resources that include `bridge/client.lua` start (they
   start after fredpd_core); without them the client falls back to `auto`, which gives the same answer when only one
   stack runs.
5. qb-inventory's `UseItem` ignores the usable fn's return value, so `false` cannot cancel a qb item use (ox can).
6. The patched qb-doorlock `setDoorState` sends `qb-doorlock:client:setState` with `serverId = src or 0`, so a
   breaching officer gets qb-doorlock's door animation (client.lua:366) only when `src` is passed.

## Open questions (contract, §C17)

1. Exports beyond the §C17 list, to be added to docs/contracts.md §C17 by its owner (this module may not edit it):
   server `addMoney(src, account, amount, reason)` (fredpd_records refunds a fine whose DB write failed,
   `charges.lua:314`) and `bridgeInfo()`; client `FredBridge.framework.getJob()`, `FredBridge.doorlock.onDoorChanged`,
   and the fredpd_core client export `clientBridgeInfo()`. Until then they are FredPD-internal additions with the
   signatures documented above.
2. qb-inventory at the pin has `AddHook`/`AddListener` (server/functions.lua:905-971, events such as `ItemMoved`);
   §C17 defines `hooks` as ox `registerHook('swapItems')` only, so `hooks = false` for qb. A qb chain-of-custody
   hook is possible later.
3. `FredBridge.framework.getJob()` (client) is not in §C17 either; needed because fredpd_mdt/fredpd_bolo client code
   reads `QBX.PlayerData` (qbx-only) for their `canInteract` hints.
4. ox item definitions: `pd_tablet` in `patches/ox_inventory.10-fredpd-items.patch` uses `client.export =
   'fredpd_mdt.open'` (a client export). With the bridge a server-side use handler needs `server.export =
   'fredpd_core.useItem'`; the fredpd_mdt owner decides which path the tablet takes on both inventories.
5. Test files outside this module: `bolo_server_test.lua`, `dispatch_server_test.lua`, `intel_server_test.lua`,
   `forensics_server_test.lua` each got one line, `require('bridge_harness_test').useQbx()`, because the real
   fredpd_core audit they load now resolves the actor through the bridge. No shared helper loads fredpd_core (each test
   loads it itself), so there is nothing to move it into; the module owners should acknowledge the line.
