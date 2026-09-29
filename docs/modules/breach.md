<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Module: fredpd_breach + housing adapters

Tasks 6.1 (breach, scene evidence) and 6.2 (housing adapters). Implements IMPLEMENTATION.md §5.6 and
docs/contracts.md §C16 (`tool:ram`, on duty, locked ox_doorlock door → progress → unlock; audited `breach.door`;
server-only export `sceneEvidence(kind, coords, suspectSrc)`, kinds = `SceneKindSchema` in
`packages/types/src/evidence.ts`).

## Files

| File | Role |
|---|---|
| `resources/[fredpd]/fredpd_breach/fxmanifest.lua` | cerulean, lua54, `ox_lib 'locale'`; deps ox_lib, ox_doorlock, ox_inventory, ox_target, fredpd_core |
| `fredpd_breach/config.lua` | item, grant, ram prop (placeholder), anim candidates, timings, distance, `breachEvidence`, scene cooldown/bounds |
| `fredpd_breach/config/scene_evidence.lua` | §5.6 table keyed by SceneKind (server-only) |
| `fredpd_breach/server/breach.lua` | `start` / `finish` (token flow), `forget` on drop |
| `fredpd_breach/server/scene.lua` | `sceneEvidence` validation, cooldown, evidences call, audit |
| `fredpd_breach/server/main.lua` | callbacks `fredpd:breach:start`, `fredpd:breach:finish`, export `sceneEvidence`, `playerDropped` |
| `fredpd_breach/client/main.lua` | door list, ox_target option, progress bar, grant copy |
| `fredpd_core/adapters/housing/ps_housing.lua` | ps-housing adapter (no longer a stub) |
| `fredpd_core/adapters/housing/ox_doorlock_only.lua` + `.json` | mapping adapter (no longer a stub) |
| `fredpd_core/adapters/housing/none.lua`, `qbx_properties.lua` | + `getAddress` helper; qbx_properties stays a stub (no API) |
| `patches/ox_inventory.30-breach-items.patch` | item `pd_ram` (after patches 10 and 20) |
| `locales/pending/breach.json` | 5 new keys |
| `tests/lua/breach_server_test.lua`, `breach_client_test.lua`, `housing_adapter_test.lua` | 31 + 7 + 8 tests |

## Breach flow

1. **Client, once at start**: `exports.ox_target:addGlobalObject({ 'Forcera dörr' })`; door list from ox_doorlock's own
   callback `lib.callback('ox_doorlock:getDoors')`; grant copy from `fredpd:getMyGrants` (+ `fredpd:client:grantsChanged`,
   `QBCore:Client:OnPlayerLoaded`). No loop. `canInteract(entity)`: `Entity(entity).state.doorId` (set by ox_doorlock
   on the door entities it manages) → door state 1 in the local list → `Grants.has(copy, 'tool', 'ram')` →
   `ox_inventory:GetItemCount('pd_ram') > 0`. All hints.
2. **Server `fredpd:breach:start(doorId)`**: `local src = source` → grant `tool:ram` → on duty → rate limit (1/s) and
   cooldown (10 s after a successful breach) → door id integer 1..1e6 → `ox_inventory:GetItemCount(src, 'pd_ram') > 0`
   → `ox_doorlock:getDoor(id)` exists and `state == 1` → `#(GetEntityCoords(GetPlayerPed(src)) - door.coords) <= 3.0`.
   Returns `{ ok, data = { token (32 hex), doorId, durationMs = 4000 } }`. One live token per player (a new start
   replaces it); expired tokens are pruned on each start (no timer).
3. **Client**: `lib.progressBar` 4 s, `canCancel`, movement/combat disabled, `prop` = `config.ramModel` (ox_lib
   attaches it only while the bar runs and deletes it afterwards, `ox_lib resource/interface/client/progress.lua:58-67,
   121-158, 220, 310-313`), `anim` = first candidate whose dict exists and whose clip has a duration.
4. **Server `fredpd:breach:finish(token)`**: token must be 32 hex, exist and belong to `src` (another player's token →
   `not_found`, left untouched); consumed; `> 8 s` → `expired`; `< progressMs - 500 ms` → `too_early` (the bar cannot be
   skipped); grant, duty, item, locked, distance again → `exports.ox_doorlock:setDoorState(id, 0)` → audit
   `breach.door` (target `door`/id, meta `{ doorId, name, coords }`) → optional `config.breachEvidence`.

Error codes (`{ ok = false, error, reason }`): `unauthorized` (grant/off_duty), `rate_limited` (rate/cooldown),
`validation` (door/no_item/not_locked/too_far/too_early/token), `not_found` (door/token), `expired`, `unavailable`.
The client maps each to Swedish text (`breach.*`, `errors.*`).

**Item missing.** `Breach.checkItem()` at start: `exports.ox_inventory:Items('pd_ram') == nil` → one warning; starts
then answer `no_item` (GetItemCount returns 0 for unknown items, `modules/inventory/server.lua:2324-2326`).

**Why the export and not `TriggerEvent('ox_doorlock:setState', …)`**: both skip ox_doorlock's own authorisation from
the server (docs/deps-verification.md §7); the export returns `true/false`, so a failure is reported
(`unavailable`/`doorlock`) instead of being audited as a success.

## Scene evidence

`exports.fredpd_breach:sceneEvidence(kind, coords, suspectSrc)` → `{ ok = true, data = { spawned = { type… } } }` or
`{ ok = false, error, reason }` (`validation` kind/coords/suspect, `rate_limited` cooldown, `unavailable` evidences).

- kind must be a key of the validated table (keys must be SceneKinds; the test compares with `evidence.ts`).
- coords: vector3 or `{x,y,z}`, three finite numbers inside `config.mapBounds`.
- suspectSrc: integer ≥ 1 with `DoesPlayerExist` (same check evidences uses, `api.lua:34`).
- cooldown: same kind within `sceneRadius` (5 m) of a scene accepted < `sceneCooldownMs` (60 s) ago → refused.
- each entry rolled (`chance` %), spawned as `exports.evidences:syncEvidence(type, suspectSrc, 'atCoords',
  vector3(x + i·0.25, y, z), { scene = kind })`; pieces are spaced because evidences drops a second piece at identical
  coords (`classes/evidence.lua:226-228`).
- audited `breach.scene` (actor 0 = system, target `scene`/kind, meta coords, suspect id + citizenid, spawned, invoking
  resource).
- **toolmark**: evidences has no toolmark type (`api.lua:7-15`); the `burglary` toolmark entry stays in the table but is
  skipped with one warning. `config.breachEvidence` (door evidence on a police breach) defaults to `false` for the
  same reason.
- `shooting` is empty: evidences spawns casings/bullets/GSR itself.

## Verified upstream APIs (pins from deps.lock.json)

| API | Where |
|---|---|
| `getDoor(id)` → `{id,name,state,coords,…}` / `false` | ox_doorlock `server/main.lua:53-68` |
| `setDoorState(id, state)` export, source nil → authorised, returns boolean | ox_doorlock `server/main.lua:275-314` |
| `getDoorFromName(name)` | ox_doorlock `server/main.lua:80-86` |
| client door list `lib.callback('ox_doorlock:getDoors')` | ox_doorlock `client/main.lua:37`, server `:316-320` |
| `Entity(entity).state.doorId = door.id` on managed doors | ox_doorlock `client/main.lua:61, 101` |
| client events `ox_doorlock:setState(id, state, source, data)`, `ox_doorlock:editDoorlock(id, data)` | ox_doorlock `client/main.lua:117, 195`; server sends at `server/main.lua:107, 285, 344` |
| `addGlobalObject(options)` / `removeGlobalObject(names)` | ox_target `client/api.lua:208-218` |
| server `GetItemCount(inv, name)`, `Items(name)` | ox_inventory `modules/inventory/server.lua:2322-2341`, `modules/items/server.lua:46` |
| client `GetItemCount(name)` | ox_inventory `modules/inventory/client.lua:277, 301` |
| `lib.progressBar` `prop` / `anim` | ox_lib `resource/interface/client/progress.lua:18-34, 58-67, 114-171` |
| `syncEvidence(class, owner, fun, ...)` export; `atCoords(coords, meta)` | evidences `server/evidences/api.lua:50-60`, `classes/evidence.lua:224-245` |
| fingerprint/blood `atCoords` collectable with `forensic_kit` | evidences `client/evidences/evidence_at_coords.lua:9-60`, `common/evidence_types.lua:39-71` |
| ps-housing `getMainDoor(propertyId, doorIndex, isShell)`; MLO door name `ps_mloproperty<id>_<i>` | Project-Sloth/ps-housing@eaba693b44a8fc87680fb3b02805694e5b11c5f8 `server/server.lua:174-188` |
| ps-housing raid unlocks `1..door_data.count` MLO doors; shells via `Property:StartRaid` | same commit `server/sv_property.lua:628-700` (677-683) |
| ps-housing `properties` table (owner_citizenid, street, apartment, shell) | same commit `README - INSTALL INSTRUCTIONS/QBOX/properties.sql` |

## Housing adapters (task 6.2)

Interface unchanged (adapters/README.md): `getDoorForProperty`, `unlock`, `getAddresses`. Added on every housing
adapter: `getAddress(citizenid)` → first label or nil (a plain field, not part of `base.lua`'s interface).

- **ps-housing**: doors = `getMainDoor(id, i, false)` for i = 1..8 until the first nil (MLO only). `unlock` →
  `setDoorState(id, 0)` for each. `getAddresses` → `SELECT property_id, street, apartment FROM properties WHERE
  owner_citizenid = ? ORDER BY property_id LIMIT 10`, label `"<street or apartment> <id>"` (ps-housing's own labelling,
  `sv_property.lua:648`). Citizenid checked `^[%w]+$`, ≤ 50. ps-housing is CC BY-NC-SA: only its export and table
  are used.
- **ox_doorlock-only**: `adapters/housing/ox_doorlock_only.json` =
  `{ "properties": { "<propertyId>": { "doors": [12, "door_name"], "label": "…" } } }` (ids or ox_doorlock names);
  an unlisted numeric property id is taken as an ox_doorlock door id. No ownership → `getAddresses` = `{}`.
- **qbx_properties**: no exports (deps-verification §11) → stays a stub; use ox_doorlock-only with a mapping.
- Not started → no-op + one warning (base.lua).

**Breaching ps-housing doors.** MLO property doors are ordinary ox_doorlock doors, so the generic "Forcera dörr"
option covers them with no extra code. **Limitation:** shell properties have no ox_doorlock door (the entrance is
ps-housing's own zone/target) and ps-housing exposes no export to open or raid a shell; its raid is only the net
event `ps-housing:server:raidProperty`, which needs a player source, job grade ≥ 3 and its own `police_stormram` item.
Shell raids therefore stay on ps-housing's own flow; FredPD cannot audit them.

## Ram model

GTA V has no battering ram. Searched 2026-09-29 for a free model compatible with GPL-3.0 redistribution:
- Sketchfab "Battering Ram" by thecrazy_craft (SWAT style) — https://sketchfab.com/3d-models/battering-ram-b9922e50a32040178d95de5418e4e0f7
  — "Free Standard" licence, not CC0/CC BY: redistributing the asset inside a GPL resource is not clearly allowed.
- Open3dModel "Police Battering Ram" — https://open3dmodel.com/3d-models/police-battering-ram_490469.html — licence not stated.
- CL-PropsPacks (FiveM conversions of Sketchfab models) — https://github.com/NevoSwissa/CL-PropsPacks — no licence.
- The rest (TurboSquid, CGTrader, Free3D, RP Works, Tugamars) are paid or proprietary.

Result: **placeholder kept** (`ramModel = 'prop_tool_shovel'`). Rami can stream a model he has rights to and set
`ramModel`/`ramPos`/`ramRot`; it is not shipped in the repo. VERIFY in game: the shovel's grip offsets.

## UNVERIFIED (needs a running server)

- Anim `missheistfbi3b_ig7` / `lift_fibagent_loop` (§5.6 names only the dict) and the fallback
  `melee@large_wpn@streamed_core` / `ground_attack_on_spot`: the client checks `DoesAnimDictExist` + `GetAnimDuration > 0`
  and falls back / plays none, so a wrong name cannot break the breach.
- `Entity(entity).state.doorId` is a client-local statebag written by ox_doorlock's runtime; reading it from
  fredpd_breach's runtime on the same client is assumed to work (statebags are per entity, not per resource).
- `addGlobalObject` targets the door entity ox_doorlock found with `GetClosestObjectOfType`; doors ox_doorlock has not
  yet resolved (> 80 m on approach) get the option once it has.
- `getAdapter('housing')` returns the adapter table across resources; its `getAddresses` does `MySQL.query.await` in
  fredpd_core when fredpd_records calls it (cross-resource function reference yielding).
- `exports.evidences:syncEvidence(…, 'atCoords', vector3, meta)` from another resource: the signature is verified in
  source; that a vector3 passed through an export keeps its type (evidences keys `EvidencesAtCoords[coords]` by it) is not.

## Integration requests

1. **tests/lua/core_adapters_test.lua (owner: core)** — ps-housing and ox_doorlock-only are no longer stubs:
   - line 46: `t.eq(a.stub, true)` → `t.eq(a.stub, spec[2] ~= 'ps-housing' and spec[2] ~= 'ox_doorlock-only')`
     (and rename the test "…and every adapter file loads");
   - line 72: `t.eq(#log.debugs, 3, …)` → `t.eq(#log.debugs, 1, 'stub notices are debug level (qbx_garages only)')`.
   Until then these 2 tests fail.
2. **adapters/README.md (owner: core)** — table rows: `ps-housing` → "done (task 6.2)", `ox_doorlock-only` → "done
   (task 6.2), mapping in `housing/ox_doorlock_only.json`", `qbx_properties` → "stub (no API, §11)"; add a line
   "every housing adapter also has `getAddress(citizenid)` → first label or nil".
3. **locales (owner: locales)** — merge `locales/pending/breach.json`. The existing `breach.itemLabel` ("Murbräcka")
   and `breach.noRam` ("…murbräcka") disagree with the item label "Dörrkross"; fredpd_breach uses the new
   `breach.noItem` and does not use those two. `audit.action.door.breach` is unused (contract name is `breach.door`,
   new key `audit.action.breach.door`).
4. **docs/modules/police.md / qbx_police** — ps-housing's raid still needs `police_stormram`; either give ps-housing
   `Config.RaidItem = 'pd_ram'` in the server's own ps-housing config (a local setting, not a FredPD patch: ps-housing
   is CC BY-NC-SA) or keep both items.
5. **Service catalog** — grant `tool:ram` must be listed.

## In-game test (§5.6 acceptance, ≤ 8 steps)

1. `node scripts/apply-patches.mjs`, restart ox_inventory; `ensure fredpd_breach`. Console: no pd_ram warning.
2. Give an officer role grant `tool:ram`; go on duty; `/giveitem <id> pd_ram 1`.
3. At a locked ox_doorlock door (e.g. a MRPD cell door): target it → "Forcera dörr" is shown.
4. Select it: 4 s progress bar with a prop in hand and an animation; the door unlocks; "Dörren är forcerad."
5. Portal/DB: `fredpd_audit` has `breach.door` with the door id and coords.
6. Remove the grant (or go off duty): the option disappears; forcing via console event is refused.
7. From a small server-side test resource (exports cannot be called from the console): `exports.fredpd_breach:sceneEvidence('burglary', GetEntityCoords(GetPlayerPed(<id>)), <id>)`
   → as a Tekniker with `forensic_kit`, a fingerprint can be collected at that spot; audit `breach.scene`.
8. Run the same call again at once → `rate_limited` (cooldown).
