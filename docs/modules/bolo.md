<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Module: fredpd_bolo (efterlysningar)

Task 2.6: server, exports and the ox_target plate check. IMPLEMENTATION.md §5.4 acceptance items 1 (plate check →
popup, alert to other officers; expired BOLOs never hit) and 4 (impound resolves), docs/contracts.md §C3, §C7, §C12.
Hooks ready for tasks 3.3 (ANPR, already wired by `patches/qbx_policejob.30-bolo-hooks.patch`) and 3.4 (garage).
The create/resolve **UI** is the NUI's (fredpd_mdt / apps/nui); this module provides the actions behind it.

## Files

| File | Role |
|---|---|
| `fxmanifest.lua` | deps `ox_lib`, `oxmysql`, `qbx_core`, `fredpd_core`; ox_target, fredpd_dispatch, fredpd_mdt optional (runtime checks) |
| `shared/input.lua` | pure: Lua mirror of `BoloCreateInput`/`BoloResolveInput`/`BoloListInput`/`PlateSchema`/`CitizenIdSchema`, `normalizePlate` |
| `shared/view.lua` | pure: plate-check context menu, markdown escaping, error texts (client) |
| `server/store.lua` | SQL: the single loader (joins persons/vehicles_idx/officers, `isoSelect` times), insert/resolve/expire, registry lookups, `fredpd_plate_checks` rows |
| `server/cache.lua` | in-memory `byId` / `activeByPlate` / `activeByCitizen`, generation counter, lazy expiry |
| `server/visibility.lua` | canView → wire Bolo (full/masked/notice/none), kontaktnotis text, SQL filter for paginated lists |
| `server/fanout.lua` | audit, tablet push, `fredpd:boloChanged`, hit alerts with the 60 s cooldown, throttled logging |
| `server/service.lua` | the exports' behaviour, the ox_target callback, the hit handler |
| `server/main.lua` | exports, `lib.callback`, server-only events, start-up rebuild, dev command `/fredpd_testbolo` |
| `client/main.lua` | ox_target global vehicle option "Kontrollera registreringsskylt", result menu |
| `test/contract.test.ts`, `test/golden/*.json` | Lua output vs `packages/types/src/mdt.ts` (+ `AlertCreateInputSchema`) |
| `db/migrations/010_plate_checks.sql` | `fredpd_plate_checks`; widens `fredpd_bolos.resolve_note` to 500 |

## Exports and events

Tablet actions (fredpd_mdt dispatcher, §C12 convention `{ ok = true, data }` / `{ ok = false, error, reason? }`):

| Export | Grant (re-checked + on duty) | Returns |
|---|---|---|
| `listBolos(src, { active?, page? })` | `mdt_page:bolos` | `BoloListOutput`. `active = true` (default): live BOLOs from memory; `false`: **all** BOLOs incl. resolved/expired, newest first (SQL) |
| `createBolo(src, BoloCreateInput)` | `perm:bolo.create` | `Bolo` (as the creator sees it) |
| `resolveBolo(src, { id, note? })` | `perm:bolo.resolve` | `Bolo` |
| `plateCheck(src, { plate })` (action `checkPlate`) | `mdt_page:search` | `PlateCheckResult`; records the check, fires `fredpd:boloHit` on a hit |

`reason` values: `off_duty`, `level` (BOLO level above the actor's tier), `duplicate` (an active BOLO for that
subject exists; `error = 'validation'`, NUI text `bolo.create.duplicate`), `too_far`, `no_plate`, or the invalid field
name for `validation`. `not_found` also covers "subject not in the register" on create.

Server lookups (no player, no canView, **never wait**, full wire Bolo): `checkPlate(plate) → Bolo|nil` (any
spelling, normalised here), `checkPerson(citizenid) → Bolo|nil`. Records: `getBolosFor(src, kind, id) → Bolo[]` — a
**plain list** (not `{ ok, data }`), `kind` `'person'` + citizenid or `'vehicle'` + plate, live first then newest, at
most 20, canView-shaped, needs `mdt_page:search` or `mdt_page:bolos`, `{}` on any error. Impound:
`resolveOnImpound(plate, src) → boolean` (never raises).

Server events fired: `fredpd:boloHit(bolo, context)` (plate checks: `{ source = 'plate_check', plate, officer =
citizenid, coords = vehicle }`), **`fredpd:boloChanged(bolo, change)`** with `change` = `'created' | 'resolved' |
'expired'` (the second argument is additive). Consumed (AddEventHandler, server-only, player sources ignored):
`fredpd:boloHit` (any source: raises the alert; `radar` also writes a `fredpd_plate_checks` row with no officer),
`fredpd:bolo:vehicleImpounded(plate, officerSrc)` (event form of `resolveOnImpound`, unused so far), `playerDropped`.
Callback: `lib.callback 'fredpd:bolo:plateCheck'(netId)`. Dev only (`set fredpd_dev true`, ACE `group.admin`):
`/fredpd_testbolo [plate] [hours]` issues a vehicle BOLO through `createBolo` as the caller (same checks; without a
plate, the vehicle the caller sits in). Tablet push: topic `bolo`, payload `{ type = 'created' |
'resolved' | 'expired', id }` through `exports.fredpd_mdt:pushToOpenTablets` (pcall, skipped while not started).

Audit actions: `bolo.create` (meta kind/plate/citizenid/level/expiresInHours), `bolo.resolve` (meta `via =
'tablet' | 'impound'`), `bolo.expire` (system actor, meta expiresAt), `bolo.check` (target `vehicle`/plate, meta
hit/boloId/via — the lookup audit of §4.5; the `fredpd_plate_checks` row itself is exempt, §C7).

## Design decisions

- **Active** = `active = 1 AND (expires_at IS NULL OR expires_at > UTC_TIMESTAMP())`. No timers: the cache compares
  `expires_at` (read as ISO UTC, `Time.toEpoch`) with `os.time()`; a lookup, list, rebuild or `getBolosFor` that
  meets an expired BOLO drops it and runs one non-blocking `UPDATE … SET active = 0 WHERE id = ? AND active = 1`;
  only the call that changed the row writes `bolo.expire`, pushes `expired` and fires `fredpd:boloChanged`. An
  expired BOLO never hits (plate check, radar, garage) and can be issued anew.
- **Cache**: rebuilt (`WHERE active = 1`) when oxmysql is ready and after every create/resolve/expiry, in a
  one-shot thread; each write also updates the maps at once and bumps a generation counter, and a rebuild whose query
  started before a write is discarded (and re-run, at most 5 times). `checkPlate`/`checkPerson` read only memory
  (qbx_police calls `checkPlate` inside a net event); before the first load they answer `nil`. Tablet paths that need
  the list (`plateCheck`, `listBolos`, `createBolo`) load it first and answer `unavailable` if they cannot — a plate
  check never says "no BOLO" because the database was down.
- **Plates** are stored and compared normalised: whitespace removed, upper case, `[A-Za-z0-9-]`, ≤ 16 — the same as
  `fredpd_vehicles_idx`, `detectSearchType` (tested against it) and the qbx_police bridge. `PlateCheckResult.plate`
  and `Bolo.plate` are normalised (`ABC12D`).
- **Subject must exist**: a person in `fredpd_persons`, a plate in `fredpd_vehicles_idx` (a miss calls
  `fredpd_core:refreshPlate`, which reads `player_vehicles`). NPC/fake plates cannot be efterlysta (open question 3).
  Subject label: "Förnamn Efternamn" or "ABC12D · sultan" (`bolo.subject.vehicle`), joined at read time.
- **One active BOLO per subject**: in-memory check + an in-flight reservation + `INSERT … SELECT … WHERE NOT EXISTS`
  (the SQL guard alone is tested).
- **Level ≤ the actor's tier** on create (as §C14 for cases): tier 0 officers issue Standard only.
- **Visibility** (record `{ type = 'bolo', id, level, status = live and 'open' or 'closed', unit = issuer's unit,
  ownerCitizenid = issued_by }`, defaults 50–55): `full`; `masked` = without `issuedBy`, `resolvedBy`,
  `resolveNote`; `notice` = kontaktnotis: id, kind, citizenid/plate, subject, `level` = fixed `NOTICE_LEVEL` 1 (never the real
  level, so Begränsad and Hemlig cannot be told apart; BoloSchema requires a level), createdAt, active, and `reason` =
  `visibility.notice.text` ("Det finns uppgifter som rör {subject}. Kontakta Bo C. (SPAN-02)."), everything else
  absent; `none` = hidden (`resolveBolo` → `not_found`; a kontaktnotis viewer gets `unauthorized`). canView's cap
  makes masked impossible above the viewer's tier (it becomes notice).
- **Paginated history** is filtered in SQL, so hidden BOLOs are neither on a page nor in `total`: a BOLO's result
  depends only on (level, open/closed, viewer is issuer, BOLO unit ∈ viewer units); those ≤ 24 combinations are
  evaluated in one `canViewMany` call and the visible ones become the WHERE clause (none with the default rules).
- **Duplicate check reveals hidden BOLOs (accepted)**: `createBolo` answers `validation` + `duplicate` whenever an
  active BOLO exists for the subject, even one whose canView result for the actor is `none`, so an officer with
  `bolo.create` can learn that a hidden BOLO exists (not its content). This is the price of one active BOLO per
  subject; any other answer (e.g. `unauthorized`) would differ from a successful create just the same. With the
  default rules no BOLO is ever `none`, so it only matters under configured rules.
- **Pushes carry ids only**: every open tablet refetches through `listBolos`, which applies canView per viewer, so no
  Begränsad/Hemlig text is broadcast. `fredpd:boloChanged` (server-side) carries the full Bolo.
- **Hit fan-out**: `fredpd_dispatch:createAlert` in its own thread, at most once per plate (vehicle) or citizenid
  (person) per 60 s, whatever the source; code `Efterlyst` (`bolo.hit.alertCode`, trimmed/cut to 16 characters; no hardcoded fallback: a missing key means no
  alert and an error log), title `bolo.hit.alertTitle` /
  `alertTitlePerson`, description "{subject} är efterlyst: {reason}" + "Källa: {source}", priority 2, `source =
  'bolo'`, meta `{ boloId, hit, plate, radar }`. Alerts reach every on-duty officer, so for level > 0 the description
  carries the kontaktnotis instead of the reason. The payload of `fredpd:boloHit` is not trusted: the BOLO is looked
  up by id in the cache and must be live. The police bridge's own per-camera cooldown is separate.
- **ox_target plate check**: the client sends only the vehicle's network id; the server checks grant
  `mdt_page:search`, duty, 1 request/s per player, that the entity exists and is a vehicle (`GetEntityType == 2`),
  that it is within 10 m of the officer, and reads the plate with `GetVehicleNumberPlateText` itself. Option: whole
  vehicle (no bone: many models lack `platelight`), 3 m, added once at start (and again if ox_target restarts),
  removed on stop. Result: ox_lib context menu, hit first (red icon + full red bar + frontend sound), then owner and
  model; values are markdown-escaped (ox_lib renders context text as markdown). One request at a time per client.
- **In-flight flags never stick** (docs/deps-verification.md §10: `MySQL.*.await` may never resume): the rebuild
  flag and the per-subject create guard store `GetGameTimer()` and count as released after `STALE_FLAG_MS` (30 s);
  the client's one-request-at-a-time flag after `BUSY_STALE_MS` (15 s). Checked on the next call, no timer.
- **Subject placeholder**: a BOLO whose subject has no register row and no citizenid/plate shows `common.unknown`.
- **`fredpd_plate_checks.source`** (`target` | `tablet` | `radar`) is an addition to the §C12 column list;
  `idx_officer_created` supports per-officer review. 010 also widens `resolve_note` to `VARCHAR(500)`
  (`BoloResolveInputSchema` allows 500; 004 had 255).
- **Times**: writes `UTC_TIMESTAMP()` (expiry `UTC_TIMESTAMP() + INTERVAL n HOUR`, n a validated literal), reads
  `Time.isoSelect`; tests run every session at `+02:00`. `checkedAt` = `Time.nowIso()`.
- **Lua cannot send `null`**: nullable fields are absent on the wire (same as fredpd_dispatch).

## Tests

- **39 passed** in fredpd_bolo's own suites: `lua5.4 tests/lua/run.lua bolo_input` 7 (validation mirror, plate
  normalisation vs `detectSearchType`, menu/escaping/errors), `bolo_server` 26 against MariaDB database
  `fredpd_test_bolo_lua` (session `+02:00`; real fredpd_core audit/mirror/canview modules), `bolo_client` 6.
  `run.lua bolo` reports **54** because it also picks up `police_bolo_test` (15, not ours), which uses the same
  exports.
- `pnpm exec vitest run --project resources fredpd_bolo` → **19 passed** (13 golden files parsed with
  `BoloSchema` / `BoloListOutputSchema` / `PlateCheckResultSchema` / `AlertCreateInputSchema` after restoring absent
  nulls, no unknown keys; push payload shape). Golden files are rewritten by `bolo_server_test` only on change.
- Type check: `pnpm exec tsc -p "resources/[fredpd]/fredpd_bolo/test/tsconfig.json"`.
- `node scripts/migrate.mjs` applies 010 on a fresh database and is a no-op the second time.

## UNVERIFIED (needs a running FXServer)

1. Server-side `NetworkGetEntityFromNetworkId` / `GetVehicleNumberPlateText` / `GetEntityType` on a vehicle the
   officer targets (OneSync; the plate is padded to 8 characters — normalisation strips it).
2. ox_target `addGlobalVehicle` with a function `canInteract` from another resource, `data.entity` in `onSelect`,
   and `onClientResourceStart/Stop` for ox_target restarts.
3. `lib.registerContext` with `readOnly`, `progress` + `colorScheme = 'red'`, `iconColor`; escaped punctuation
   renders as the plain character in ox_lib's react-markdown.
4. The plate-check round trip within 200 ms (one awaited SELECT on the hot path; the check row and audit are not
   awaited).
5. Awaiting oxmysql inside exports called from other resources (`createBolo` etc. from the fredpd_mdt dispatcher,
   `resolveOnImpound` from qbx_police) — the same pattern as fredpd_dispatch's `createAlert`.
6. `TriggerEvent('fredpd:boloHit')` reaching this resource's own `AddEventHandler` synchronously (the alert then
   runs in its own thread).
7. Client `require '@fredpd_core.shared.format'` + `LoadResourceFile('fredpd_core', 'config/formats.json')` for the
   expiry line (it is simply left out if that fails).

## Integration requests (owners other than this module)

- **fredpd_mdt**: route `listBolos`, `createBolo`, `resolveBolo` to the same-named exports and `checkPlate` to
  `exports.fredpd_bolo:plateCheck(src, input)`; unwrap `{ ok, data | error }` (an extra `reason` may be present:
  map `validation`/`duplicate` to `bolo.create.duplicate`, `unauthorized`/`level` to a level hint). Provide
  `pushToOpenTablets(topic, payload)`; topic `bolo` payload `{ type, id }` → invalidate the BOLO queries. NUI: restore
  absent nullable keys before a strict zod parse (`restoreNulls` in the contract test). `getHome` can take
  `recentBolos` from `listBolos(src, { active = true })` (first 10) and `counts.activeBolos` from its `total`.
- **fredpd_records**: `getBolosFor(src, 'person' | 'vehicle', id)` returns a plain `Bolo[]`; search hits' `bolo` flag
  = `exports.fredpd_bolo:checkPlate(plate) ~= nil` / `checkPerson(citizenid) ~= nil` (no DB). VehicleSummary.checks:
  `fredpd_plate_checks` (`officer_citizenid` NULL for radar rows; `source` says where from).
- **docs/contracts.md owner**: record in §C12 the `fredpd_plate_checks.source` column, the `resolve_note` width,
  the `bolo` push payload, `fredpd:boloChanged(bolo, change)`, `getBolosFor` returning a plain list, the error
  `reason`s above; consider `BoloPushSchema` in mdt.ts and a `visibility` field on `BoloSchema` (open question 1).
- **apps/service catalog**: perms `bolo.create`, `bolo.resolve` (already in §C12).
- **locales**: done — `locales/pending/bolo.json` was merged into `locales/sv.json` / `en.json` (commit 82fd2e9); all `L()` keys used here exist.
- **server.cfg.example**: `ensure fredpd_bolo` after `fredpd_core` (and after `ox_target`, `fredpd_dispatch` when used).
- **qbx_police patch 30** (police): its requests are met — `checkPlate` takes any spelling, ignores expired rows and
  never waits; `resolveOnImpound` returns true/false and never raises; radar `fredpd:boloHit` gets a check row and the
  alert (per plate, 60 s).

## In-game test

1. Build (`node scripts/build.mjs`), ensure order ox_target → fredpd_core → fredpd_dispatch → fredpd_bolo; restart.
   Two officers A and B with `mdt_page:search`, `mdt_page:bolos`, `mdt_page:alerts`, `perm:bolo.create`,
   `perm:bolo.resolve`, both `/duty` on.
2. With `set fredpd_dev true`, A sits in a player-owned car (in the register) and runs `/fredpd_testbolo` (or
   the tablet "Ny efterlysning" once the NUI has it): "Efterlysningen är utfärdad."; `fredpd_audit` has `bolo.create`
   with A's citizenid. Running it again: "Det finns redan en aktiv efterlysning på …".
3. B targets that car → "Kontrollera registreringsskylt" → within ~200 ms a menu "Skyltkontroll: ABC12D" with the red
   "Träff på efterlysning" row, owner and model, plus a sound.
4. A (tablet open or not) gets the "Nytt larm" toast "Efterlyst … Efterlyst fordon: ABC12D"; checking again within
   60 s gives the menu but no second larm.
5. Check a car without efterlysning: green "ABC…: ingen aktiv efterlysning."; an NPC car: "fordonet finns inte i
   registret".
6. Go off duty and try the option: it is hidden; as a civilian it is never shown.
7. `/fredpd_testbolo <plate> 1` on another car, then set its `expires_at` in the past in the DB (or wait an hour):
   the next check shows no hit and `fredpd_audit` has `bolo.expire` (no actor).
8. `/impound` the wanted car (qbx_police with patch 30): the efterlysning is resolved with "Återkallad automatiskt:
   fordonet bärgades." (`bolo.resolve`, meta via impound); a new check shows no hit.
9. Issue a Begränsad (level 1) efterlysning as a tier-1 officer of another unit; a tier-0 IGV officer's check shows
   "Det finns uppgifter som rör … Kontakta …" instead of the reason, and the larm text does not contain the reason.
10. `SELECT * FROM fredpd_plate_checks ORDER BY id DESC LIMIT 5`: rows with officer, hit, bolo_id, source `target`.

## Open questions

1. **Contract request (§C11/§C12)**: `BoloSchema` has no `visibility` field, so the NUI cannot mark a kontaktnotis
   as such, and `level`/`createdAt` are required. Add `visibility: 'full' | 'masked' | 'notice'` (like
   `CaseRefSchema`) and make `level` and `createdAt` nullable/omitted for notices; then fredpd_bolo drops both from
   the notice shape and the NUI (`apps/nui/src/components/Bolos.tsx`) hides the level badge for notices. Until then
   every notice carries level 1 (a notice row shows "Begränsad" even for Hemlig) and its real `createdAt`.
2. MDT_ERROR_CODES has no `conflict`: a duplicate BOLO is `validation` + `reason = 'duplicate'`.
3. Vehicle BOLOs need a plate in the register; efterlysning of an unregistered/stolen-plate or NPC car is refused
   (`not_found`), as the task asked. Allow it (subject = plate only) if Rami wants that.
4. `fredpd_plate_checks` grows without bound (every check, every radar hit); a manual retention command like the
   audit archive may be wanted.
5. Hit alert priority is 2 (normal); raise to 1 for BOLO hits?
6. **Contract request (§C12)**: record the `fredpd_plate_checks.source` column and the `fredpd_bolos.resolve_note`
   widening to `VARCHAR(500)` done by 010.
