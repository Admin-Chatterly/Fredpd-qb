<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Module: qb adapters (garage `qb-garages`, prison `xt-prison`)

fredpd_core adapters for the QBCore server (IMPLEMENTATION.md §9, docs/contracts.md §C17, adapters/README.md). They
use the existing loader and interfaces unchanged (`adapters/base.lua`, `adapters/loader.lua`). Select them in
`config/integrations.json`: `"garage": "qb-garages"`, `"prison": "xt-prison"`.

Pins: qbcore-framework/qb-garages@f22a09f (GPL-3.0, deps.lock.json), xT-Development/xt-prison@85fd705 (**no
licence**, REFERENCE: only its export and ox_lib callbacks are called, nothing copied or patched).

## Files

| File | Role |
|---|---|
| `resources/[fredpd]/fredpd_core/adapters/garage/qb_garages.lua` | garage adapter: `onParked` / `onTakenOut` listeners + the fredpd_bolo relay |
| `patches/qb-garages.10-fredpd-events.patch` | two server-only events in qb-garages `server.lua` |
| `resources/[fredpd]/fredpd_core/adapters/prison/xt_prison.lua` | prison adapter: `jail(src, minutes, charges)` |
| `locales/pending/adapters-qb.json` | `prison.notify.released`, `prison.notify.timeChanged` |
| `tests/lua/adapters_qb_test.lua` | 14 tests (selection, both adapters with mocks, the patch applied to the pin and run) |

## Garage: qb-garages

**Upstream at the pin** (`server.lua`): no server event on park or take-out. The server-authoritative points are
- park: callback `qb-garages:server:canDeposit(source, cb, plate, type, garage, state)` (:160-177): ownership
  check against `player_vehicles.citizenid` (:162-166), then `UPDATE … state = 1, garage = ?` (:171-173). The
  garage name is client-chosen (client.lua:66-79 sends `data.indexgarage`). Note the parameter named `type`
  shadows Lua's `type()` in this function.
- take-out: callback `qb-garages:server:spawnvehicle(source, cb, plate, _, coords)` (:125-149): owned-vehicle
  lookup (:131), server-side `CreateVehicleServerSetter` (:142). The garage is not sent (client.lua:292-316).
- `qb-garages:server:updateVehicleState` (:188-193) is a client-triggered net event (state 0 after spawn) and is
  not used: a client could send it at will.

**Patch 10** adds, after those checks:

```lua
TriggerEvent('fredpd:garage:parked',  citizenid, plate, Config.Garages[garage] and garage or nil, source)
TriggerEvent('fredpd:garage:takenOut', citizenid, plate, player_vehicles.garage, source)  -- SELECT gains `garage`
```

**Adapter**: installs `AddEventHandler` for both events when selected (`init`), never `RegisterNetEvent` (FiveM
refuses client triggers of non-net events); an event with a player `source` is dropped too. The plate is
normalised like fredpd_bolo (whitespace removed, upper case, `[A-Z0-9-]`, ≤ 16), the garage kept only when printable
and ≤ 64 chars. The actor is the passed `src` only when the bridge says it is that citizenid, else
`Bridge.getPlayerByCitizenId(citizenid)` (nil when offline). Then:
1. every `onParked` / `onTakenOut` listener: `cb(plate, src, garageName)` (pcall; ≤ 16 each; function or
   cross-resource function reference; the same cb once);
2. **fredpd_bolo relay** (while fredpd_bolo is started): `exports.fredpd_bolo:checkPlate(plate)` (memory only,
   docs/modules/bolo.md "Server lookups") and on a hit `TriggerEvent('fredpd:boloHit', bolo, { source = 'garage',
   plate, coords, garage, action = 'parked' | 'takenOut' })`; coords = the player's ped server-side. fredpd_bolo's
   handler (server/main.lua:48) re-reads the BOLO by id, applies the 60 s per-plate cooldown and raises the larm
   with label `bolo.hit.source.garage` (fanout.lua:86). Both park and take-out relay.

`onParked` / `onTakenOut` return `true` once the listener is stored; while qb-garages is not started they are the
base no-op (`false`, one warning at start), so ensure qb-garages before fredpd_core.

## Prison: xt-prison

**Upstream (xt-prison@85fd705)**, framework bridges: `bridge/server/qb.lua:1` runs when qb-core is started and
qbx_core is not; `bridge/server/qbx.lua` for Qbox. Both define `setJailTime` and `exports('SetJailTime')`
(qb.lua:30-46): sets `Player(src).state.jailTime`, `xtprison_identifier`, metadata `injail`, returns true; it does
not move the player. Confinement is the client callback `xt-prison:client:enterJail(minutes)` (client/cl_main.lua:5-7
→ client/modules/prison.lua `enterPrison`, which itself calls `xt-prison:server:setJailStatus`), release
`xt-prison:client:exitJail(true)` after `setJailTime(src, 0)` (server/sv_roster.lua:14-22). xt-prison's own `/jail`
updates a jailed player with `setJailTime` and enters a free one with the callback (server/sv_commands.lua:80-96).

**Adapter** `jail(src, minutes, charges)` (server only; FredPD's record is the authority, the caller fredpd_records
has done grant, custody and range checks):

| Case | Call | Returns |
|---|---|---|
| bad src / minutes (not a whole number 0..99999) / no character loaded (bridge `getPlayer`) | none | `false` |
| `minutes > 0`, `state.jailTime` ≤ 0 | `exports['xt-prison']:SetJailTime(src, minutes)` first (as xt-prison's police-qb compat path does), then `lib.callback('xt-prison:client:enterJail', src, cb, minutes)`; enterPrison's `setJailStatus` (server/sv_main.lua:150-158) sees the same time and only confines, and a client that drops the callback is re-jailed on relog via `initJailTime` | `false` if `SetJailTime` refuses (nothing sent), else `true` (sent) |
| `minutes > 0`, already jailed | `exports['xt-prison']:SetJailTime(src, minutes)` + notice `prison.notify.timeChanged` | its result |
| `minutes == 0`, jailed | `SetJailTime(src, 0)`, then `lib.callback('xt-prison:client:exitJail', src, cb, true)` + `prison.notify.released` | `SetJailTime` result |
| `minutes == 0`, not jailed | none | `true` |
| xt-prison not started | base no-op, one warning | `false` |

The client callbacks are sent **without waiting** (ox_lib response handler): enterPrison takes several seconds of
screen fades and ox_lib's await timeout is 300 s (`ox:callbackTimeout`, ox_lib imports/callback/server.lua:11), which
would block the tablet action. `true` therefore means "handed to xt-prison"; a response other than `true` is logged
as a warning. `charges` are not passed (xt-prison has no field). An error raised by xt-prison is caught by the base
(`log.error`, `false`).

**xt-prison on a qb stack — limits (upstream, cannot be patched: no licence):**
- Item confiscation/return and the canteen call `exports.ox_inventory` unconditionally (server/sv_main.lua:5, 65,
  82, 105-144, 174): with qb-inventory those handlers error, items are **not** taken on entry; confinement,
  countdown and release still work (they do not depend on them).
- Prison break gates use `exports.ox_doorlock` (server/modules/prisonbreak.lua:5, 32-33, 58-59, 86-92): without
  ox_doorlock prison break does not work.
- Targets use qb-target when it is started (client/modules/prison.lua:36-59, client/cl_canteen.lua,
  client/cl_infirmary.lua), except the roster (client/cl_roster.lua:92, ox_target only).
- Client trust (docs/deps-verification.md §2a): `prison:server:SetJailStatus` (bridge/compat/server.lua:14-17) and
  `xt-prison:server:setJailStatus` (server/sv_main.lua:150-163) let a client set its own time; the compat
  `police:server:JailPlayer` (bridge/compat/server.lua:20-31) is gated only by xt-prison's `PoliceJobs`.
  Set `PoliceJobs` in xt-prison's `configs/server.lua` to the police job only.

## Tests

`lua5.4 tests/lua/run.lua adapters_qb` — 14 tests. The patch test applies `patches/qb-garages.*.patch` to the pinned
commit with the qb-policejob harness (`H.tree('qb-garages')`), checks reverse-apply and `luac`, and runs the patched
`server.lua` with qb-core/oxmysql mocked (park owned/unowned/unknown garage/state 0, take-out owned/unowned). The
xt-prison name check greps a checkout given in `FREDPD_XT_PRISON` (skipped otherwise, since xt-prison is not
fetched).

## UNVERIFIED (needs the game)

1. ox_lib `lib.callback(event, src, cb, ...)` from fredpd_core reaching xt-prison's client handler (ox_lib routes
   the reply to the calling resource, imports/callback/server.lua:13-21, 38-39).
2. xt-prison's enterPrison on qb-core with qb-inventory: the failing `xt-prison:server:removeItems` handler must not
   stop confinement (it is a separate server event).
3. `exports['xt-prison']:SetJailTime` from another resource: its `while … Wait(1)` loop (qb.lua:39-41) should not
   run, because a server-side state bag write is visible at once.
4. Passing the adapter's listener functions across resources (`exports.fredpd_core:getAdapter('garage')
   .onParked(cb)`): function references both ways.
5. `GetEntityCoords(GetPlayerPed(src))` at park time (OneSync) as the hit location.

## Integration requests

1. **config/integrations.json owner**: `"garage": "qb-garages"`, `"prison": "xt-prison"` for the QBCore server
   (`"none"` where the resource is not installed); update `tests/lua/core_adapters_test.lua` default-config test
   (it asserts `garage = qbx_garages`, `prison = none`).
2. **adapters/README.md**: two rows added (qb-garages, xt-prison).
3. **fredpd_bolo**: nothing required (the adapter relays `fredpd:boloHit`). Do **not** also register an
   `onParked` listener that fires hits, or each park alerts twice (the cooldown hides the second).
4. **qb-policejob patch owner (police-qb)**: with `"prison": "xt-prison"`, `police:server:fredpdJailPlayer` could
   call `exports.fredpd_core:getAdapter('prison').jail(target, months)` instead of `SendToJail` →
   `prison:client:Enter` (avoids xt-prison's "deprecated" path).
5. **fredpd_records**: `jail` returning `true` means "sent"; audit wording should say so.
