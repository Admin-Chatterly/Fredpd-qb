<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Module: fredpd_forensics (evidence register over noobsystems/evidences)

Task 4.2. Implements IMPLEMENTATION.md §5.7 and docs/contracts.md §C16 (types: `packages/types/src/evidence.ts`).
A thin adapter: evidences does the gameplay (traces, collecting, the laptop and its analysis); FredPD keeps the
register (`fredpd_evidence`, migration 006 + `011_evidence.sql`: two identity columns), the chain of custody, the
case link and the tablet actions.

## Files

| File | Role |
|---|---|
| `fredpd_forensics/fxmanifest.lua` | deps `ox_lib`, `oxmysql`, `fredpd_core` (§C17: no ox_inventory/ox_target/framework dependency); client includes `'@fredpd_core/bridge/client.lua'`; evidences, ox_inventory, ox_target and fredpd_mdt checked at runtime |
| `config.lua` | lab box(es) + local laptop spot, evidence lockers (stashes), locker patterns, container items, lab unit, timings. MRPD defaults are **placeholders** (see below) |
| `shared/evidence.lua` | pure: item map, uids, result whitelist, same-evidence check, custody action for a move, input validation (mirror of evidence.ts), lab box test |
| `server/store.lua` | SQL: `fredpd_evidence` writes (insert, append, first analysis, link transaction) and reads; read-only lookups in `fredpd_cases`/`fredpd_case_assignees`, `fredpd_officers`, `fredpd_persons`, evidences' registers |
| `server/service.lua` | collect (mint + register), give/arrival, uid registry, custody (swapItems post-hook), analysis, visibility/shape, list/get/link, case page list, locker check, dialog callback body |
| `server/main.lua` | bridge switch (`bridgeInfo().evidence`), wiring: exports (gated), `evidences:evidenceItemAnalysed`, callback `fredpd:forensics:link`, stashes, ox_inventory hooks `createItem`/`swapItems`/`openInventory` (again after an ox_inventory restart), formats, replicated convar `fredpd_forensics_evidence` |
| `db/migrations/011_evidence.sql` | `fredpd_evidence.item_name`, `ident` (uid registry, Decision 5.2); additive, `ADD COLUMN IF NOT EXISTS` |
| `client/main.lua` | lab zone (`lib.zones.box`) → "Analysera", local lab laptop, locker target (`FredBridge.target`), "Koppla till ärende" dialog; nothing until evidence is on |
| `test/contract.test.ts`, `test/golden/*.json` | Lua output vs `EvidenceItemSchema` / `EVIDENCE_ACTIONS.listEvidence.output` |
| `patches/evidences.20-fredpd-integration.patch` | evidences: biometric analysis event fix, inventory passed with the event, `openLaptop` client export |
| `patches/evidences.30-sv-locale.patch` | evidences: `locales/sv.json` (276 strings; laptop UI too) |
| `patches/ox_inventory.20-evidence-items.patch` | the 14 evidences items in `data/items.lua`, Swedish labels |
| `locales/pending/forensics.json` | 25 new keys (`evidence.*`, `audit.action.evidence.*`) |

## evidences v1.3.1 (pin 0d15876) — what FredPD relies on

Paths are in `resources/[upstream]/evidences/` at the pin (`node scripts/fetch-deps.mjs --only evidences`).

| Topic | Finding | Where |
|---|---|---|
| Server exports | `getFingerprint(playerId)`, `getDNA(playerId)`, `syncEvidence(evidenceClass, owner, fun, ...)`; nothing for analysis or the laptop | `server/biometrics/biometrics_provider.lua:97-105`, `server/evidences/api.lua:50-60` |
| Analysed event | `TriggerEvent("evidences:evidenceItemAnalysed", source, item)` inside `lib.callback "evidences:setAnalysed"`, after `SetMetadata`. `item` = ox_inventory slot table `{ name, slot, count, metadata }`, `metadata[type] = { owner, createdAt, analysed = true }`, `metadata.information` | `server/dui/callbacks.lua:184-211` |
| **Bug at the pin** | `for key, value in pairs(arguments.information)`: the fingerprint/DNA analysis sends no `information` (`html/dui/laptop/src/components/atoms/EvidenceAnalysis.tsx:47-70`; only `BallisticsAnalysis.tsx:49-72` sends it), so `pairs(nil)` raises, ox_lib's `pcall` swallows it (`ox_lib imports/callback/server.lua:97-122`) and the event **never fires for fingerprints or DNA**. Fixed by `evidences.20` (`or {}`) | `server/dui/callbacks.lua:202-203` |
| Inventory of the analysed item | not in the event; `arguments.inventory` is the player id or a container id (any string is accepted) | `server/dui/callbacks.lua:150-159`; `evidences.20` passes it as a 3rd argument |
| Item identity | none: collect = `AddItem` then `atItem(source, slot, clientMetadata)` which copies client keys over the item metadata | `server/evidences/actions.lua:35-94` (61, 75), `server/evidences/classes/evidence.lua:273-289` |
| Evidence metadata keys | `fingerprint` (collected_fingerprint), `dna` (blood, saliva), `ballistics` (casing, bullet, magazine, gunshot residue: `owner` = serial or scratched serial, `serial`, `weaponType`, `type`) | `server/evidences/classes/*.lua` (`superClassName`), `common/evidence_types.lua:3-35` |
| Registers (the laptop's "match") | `linked_fingerprint`, `linked_dna` (fingerprint/DNA → citizenid), `firearms_registry` (serial → citizenid) | `server/biometrics/linked_biometrics.lua:10-28, 60-73`, `server/firearms/firearms.lua:10-24` |
| Laptop flow | item `evidence_laptop` places a `p_laptop_02_s` prop (stored in `evidence_laptops`); ox_target `addModel` on that model → `focus.start(entity)` (camera on the prop, `SetNuiFocus(true, false)`); **no export** to open it | `client/dui/laptops/item.lua:7-74`, `client/dui/laptops/target.lua:9-35`, `client/dui/focus.lua:65-126`, `server/dui/laptops.lua:35-54` |
| Laptop language | the DUI fetches `locales/<ox:locale>.json` (same files as Lua), so `sv.json` covers both | `html/dui/laptop/src/components/TranslationContext.tsx:18-28`, `client/dui/focus.lua:86` |
| ox_target fork | not needed: README only recommends it for vehicle doors; the fxmanifest depends on plain `ox_target` | `README.md:48`, `fxmanifest.lua:9-15` |
| Items | not shipped by ox_inventory; README step 2 = paste `.github/setup/<lang>_items.lua` into `ox_inventory/data/items.lua` (checked at start) | `README.md:51`, `server/items.lua:4-9` |
| Jobs | `config.permissions` job → min grade, **no on-duty check** | `config.lua:84-104`, `common/frameworks/framework.lua:18-28` |

ox_inventory v2.47.9 (pin 952c128), `resources/[upstream]/ox_inventory/`:

- `registerHook(event, fn, { itemFilter = { [name] = true }, inventoryFilter = { luaPattern, … } })` returns the hook
  id (`<resource>:<event>:<n>`); a hook returning `false` blocks, anything else allows; `createItem` replaces the
  metadata with a returned table (`modules/hooks/server.lua:6-28, 60-116, 118-149`). The item filter matches the
  dragged item or the target slot's item; the inventory filter matches either inventory id.
- **Post-hook event**: every invoked hook gets `TriggerEvent(hookId, success, payload)` 50 ms after the action, with
  `success = false` when the move failed after the hook (`modules/hooks/server.lua:34-54`, used through `<close>` at
  `modules/inventory/server.lua:1802-1902`). fredpd_forensics does its custody work there.
- swapItems payload `{ source, fromInventory, fromSlot (item), fromType, toInventory, toSlot (item or slot number),
  toType, count, action = 'move'|'stack'|'swap' }` (`modules/inventory/server.lua:1783-1792`); `SwapSlots` clones,
  so the payload items keep their original `slot` (`:918-929`).
- Its own police lockers are `evidence-<number>` (type `policeevidence`, `:118-119, 184-185`); container ids are
  `GenerateText(3)..os.time()` (`modules/items/server.lua:198`); `GetContainerFromSlot` loads a container (`:267-281`).
- Hooks of a stopped resource are removed (`modules/hooks/server.lua:151-163`), and an ox_inventory restart drops all
  of them: fredpd_forensics re-registers on `onResourceStart('ox_inventory')`.

## Flow

```
collect   evidences collect → ox_inventory AddItem → createItem hook (FredPD): metadata += item_uid, collected_by,
          collected_at → evidences atItem writes owner/information → +250 ms: the item with that uid is there? →
          INSERT IGNORE fredpd_evidence (type, item_name, ident, chain = [collect {at, actor, location = crime
          scene}]) → audit evidence.collect (not there = no row: failed AddItem, overwritten uid)
give      ox_inventory giveItem → AddItem on the recipient with the item's metadata → createItem hook: uid present
          → kept (metadata unchanged) → +250 ms: item there? uid registry ok? → transfer {actor = recipient}
          (a locker via another resource: handin/return, locker → locker: transfer) → audit evidence.transfer
hand-in   player moves an evidence item (or an evidence_box with items) into/out of a locker → swapItems hook
          returns true → post-hook event (success) → handin | checkout | return | transfer appended → audit
analyse   evidences setAnalysed → evidences:evidenceItemAnalysed(src, item, inventory) → inventory = the analyst's
          own or a container in it? (else audit evidence.mismatch 'not_holder', nothing stored) → row by uid → first
          analysis: result (whitelist + match from the registers, crime scene from the collect entry) + 'analyse'
          (location = lab id if the analyst stands in a lab box) → audit evidence.analyse → client offer "Koppla till
          ärende" (perm evidence.link + on duty, unlinked)
link      dialog → lib.callback fredpd:forensics:link { id, caseNumber } (or tablet linkEvidence { id, caseId })
          → checks → n = MAX(n)+1, tag = formatId(evidenceTag, { case, n }) → transaction [SELECT case FOR UPDATE;
          UPDATE evidence SET case_id, n, tag, level, chain += link WHERE case_id IS NULL] → retry once on a
          (case_id, n) conflict → audit evidence.link → fredpd:evidenceLinked(caseId, id) → push 'case'
```

## Framework bridge (docs/contracts.md §C17)

evidences needs ox_inventory + ox_target (its fxmanifest), so fredpd_forensics only works on that pair. The server
runs qb-core + qb-inventory + qb-target today; there the resource **stays idle** and qb-policejob keeps its own evidence.

| | evidence on (`exports.fredpd_core:bridgeInfo().evidence` and `.inventory == 'ox_inventory'`) | evidence off |
|---|---|---|
| server | everything below (hooks, stashes, `evidences:evidenceItemAnalysed`, callback `fredpd:forensics:link`, `playerDropped`); replicated convar `fredpd_forensics_evidence = 'on'`; net event `fredpd:forensics:client:enable` to all clients; one info line | nothing registered except the four exports and one `onResourceStart` listener; convar `'off'`; **one** warning `evidence is not available (bridge: inventory=…, target=…, evidences …)` |
| exports `listEvidence`/`getEvidence`/`linkEvidence`/`listCaseEvidence` | as before | `{ ok = false, error = 'unavailable', reason = 'evidence_off' }` (fresh table); fredpd_mdt passes code + reason to the NUI; fredpd_records' case page shows no evidence |
| client | lab zones, locker boxes and the laptop "Koppla till ärende" option through `FredBridge.target`; offer net event | nothing registered |

- **Late start:** evidences (or ox_inventory, or ox_target) starting after fredpd_forensics → `onResourceStart` → one look at the
  bridge `RECHECK_MS` (1 s) later (one-shot `SetTimeout`, not a loop; the bridge's `hasFeature` wants `started`).
  Wiring happens at most once; it is never undone (evidences stopping just stops its event).
- **Client switch:** active when the server says so (convar at join, or the enable event later) **and** locally
  `FredBridge.target.impl == 'ox_target'`, ox_target started and ox_inventory started; re-tried on
  `onClientResourceStart` of ox_target/ox_inventory. A forged local enable event on a qb client does nothing.
- **ox_inventory stays direct, gated:** hooks (`registerHook`), `RegisterStash`, `GetSlotsWithItem` on stashes,
  `GetSlot`, `SetMetadata`, `GetContainerFromSlot`, `GetInventoryItems` have no bridge equivalent (§C17 `hooks` are
  ox-only; the bridge `find` takes a player src only). Server code reaches them only through `Service.inventory()`,
  which raises unless `cfg.inventory == 'ox_inventory'` (set from `bridgeInfo()` at activation); every caller is in a
  `pcall`. The client opens a locker with `exports.ox_inventory:openInventory` only while active.
- **Framework calls:** none. Actor, grants, duty, units, tier and canView come from fredpd_core's exports
  (`getCitizenId`, `hasGrant`, `isOnDuty`, …), which use the bridge; the audit actor resolves through it too.

## Exports, events, callbacks

| Export (`{ ok, data } \| { ok = false, error, reason? }`, §C12) | Grant | Output |
|---|---|---|
| `listEvidence(src, { caseId?, unlinked?, page? })` | `mdt_page:evidence` | `{ items: EvidenceItem[], total, page }` — `caseId`: that case's evidence by `n`; `unlinked`: analysed, not linked (Tekniker queue), newest first; neither: the newest evidence the viewer may see (500 newest rows considered) |
| `getEvidence(src, { id })` | `mdt_page:evidence` | `EvidenceItem`; not visible = `not_found` |
| `linkEvidence(src, { id, caseId })` | `perm:evidence.link` | `EvidenceItem` |
| `listCaseEvidence(src, { caseId, page? })` | none: on duty + canView of the case ≠ `none` (else `not_found`); `notice` = empty list | as `listEvidence` — for fredpd_records' case page |

All re-check grant, on duty (`reason = 'off_duty'`) and input. Errors: `unauthorized`, `not_found` (`reason`
`case`/`evidence` on link), `validation` (`reason` `already_linked`, `case_closed`, `case_number`, `id`),
`rate_limited` (dialog only), `unavailable` (also: every link path while fredpd_core's `formats.json` is missing or
rejected; no link offer is sent then).

- Server event fired: `fredpd:evidenceLinked(caseId, evidenceId)` (§4.3). Consumed: `evidences:evidenceItemAnalysed`
  (server-only `AddEventHandler`), the swapItems post-hook event, `playerDropped`, `onResourceStart`.
- Callback `fredpd:forensics:link` `{ id, caseNumber }` → `{ ok = true, tag, caseNumber } | { ok = false, error,
  reason? }`: grant `perm:evidence.link`, on duty, 1 attempt per 2 s per player, input, then the shared link checks.
- Client event `fredpd:forensics:client:offerLink` `{ id, type, example }` (example = a case number in the configured
  format, for the placeholder).
- Tablet push: `pushToOpenTablets('case', { type = 'evidenceLinked', caseId, evidenceId })` (ids only; the tablet
  refetches through canView).

## Design decisions

- **Item uid.** Minted by FredPD's `createItem` hook for every new evidence item **without** one. An item created
  with a uid already in its metadata is an existing item on the move and keeps it: ox_inventory's give is
  `AddItem(recipient, …, data.metadata)` then `RemoveItem(giver)` (`modules/inventory/server.lua:2529-2553`; the hook
  runs inside `Items.Metadata`, `:1147-1174`, `modules/items/server.lua:224-234`), so replacing the uid there split
  the record (review R1). Only server code can pass metadata to `AddItem` (evidences' collect passes none,
  `actions.lua:61`), so keeping it opens no client path. Stored as metadata `item_uid` (with `collected_by`,
  `collected_at`), which is also what the evidences security patch must strip from client metadata (see
  Integration requests). Items without a uid (collected before FredPD ran) get one where they lie at their first
  hand-in or analysis (`SetMetadata`), with a `collect` entry built from evidences' metadata (`createdAt`, crime
  scene; actor unknown).
- **Only uids this server minted are trusted without a row** (review 2, finding 1). The metadata keys `item_uid`,
  `collected_by`, `collected_at` are client-writable at the pin (evidences:syncEvidence → `atItem`,
  docs/deps-verification.md §3), so `collected_by`/`collected_at` are written for display only and **never read
  back**. `mint` (and a re-stamp) remembers each uid in memory (`minted[uid] = { cid, at }`, dropped once the row
  exists; expired entries older than `mintedTtlMs` = 6 h pruned on a later mint once `mintedCap` = 2000 is reached).
  A well-formed uid with no row that is in `minted` (registration missed the item, or its insert failed) gets its row
  with the collector and time from the mint (audit `evidence.collect`, `via = 'late'`). Any other one (forged, or
  minted before a restart and never registered) is treated like a legacy item: re-stamped where it lies with
  `collected_by`/`collected_at` removed, `collect` entry without actor at evidences' `createdAt`, audited
  `evidence.collect` (`via = 'unknown_uid'`) plus `evidence.mismatch` (`why = 'unknown_uid'`, `meta.uid` = the
  forged uid). Where it cannot be re-stamped (no inventory known) nothing is written and the mismatch is audited
  without a target id.
- **Registration and arrivals check the inventory** (`GetSlotsWithItem(holder, name, { item_uid })`, registerDelayMs
  later): a minted uid that never landed (failed `AddItem`, the first of `AddItem`'s two `Items.Metadata` calls, a
  uid overwritten by `atItem`) gets no row; a give ox_inventory undid gets no entry; AddItem's repeated
  `Items.Metadata` calls for one item give one arrival check (keyed uid@inventory). An arrival where the chain
  already has the item (same recipient / same inventory) adds nothing. A hand-over to a person is `transfer` with
  `actor` = recipient and no location; `lastLockerAction` ignores such transfers, so checkout → give → put back is
  still `return`.
- **Uid registry** (docs/deps-verification.md §3, Decision 5.2; migration 011): each row keeps the item name and the
  evidence identity first seen for its uid (`fingerprint:<string>`, `dna:<string>`,
  `ballistics:<owner>|<serial>|<weapon type>|<kind>`), written at registration (after evidences' `atItem`) or, for
  rows without them (pre-011, evidence not yet on the item), at the next sighting (`COALESCE`, then a re-read).
  Every analysis, hand-in/checkout and arrival compares type, item name and identity, and on a difference writes
  nothing and audits `evidence.mismatch` (`meta.why` = `type` | `item` | `evidence`; `unknown_uid` and `not_holder`
  below) — also while `result IS NULL` (review R2: owner rewritten before analysis; R3: another item carrying an
  unanalysed uid). Analysed rows are also
  compared with the stored result. The first analysis is final (`… WHERE result IS NULL`); evidences re-fires the
  event on every ballistics view, those repeats add nothing. **Residual until the evidences security patch**: a
  client can still choose the owner at collect time (evidences trusts it, `actions.lua:92-94`), change it within the
  250 ms before registration, copy a uid together with an identical identity (same person, same item name), or
  replace an item's uid with a fresh one (the item is then re-stamped as collector unknown: the real collector is
  lost, but no forged one is recorded); the `collect` time and crime scene of re-stamped/legacy items are evidences'
  client-asserted `createdAt` / `information.crimeScene`.
- **Analysis by the holder only** (review 2, finding 3): evidences' laptop lists the analyst's own items and those in
  containers inside their inventory (`getItemsMatchingFilter`, `server/dui/callbacks.lua:25-81`), but its `getItem`
  (`:150-159`) accepts any stash id. With the `inventory` argument (`evidences.20`) FredPD records an analysis only
  when it is the analyst's server id or the `metadata.container` of an item in their inventory
  (`GetInventoryItems(src)`); otherwise nothing is stored, no link offer, audit `evidence.mismatch`
  (`why = 'not_holder'`, `meta.inventory`). evidences has already marked the item analysed then, and does not
  re-fire for fingerprints/DNA, so such a row stays unanalysed in FredPD (visible in the audit). On duty is **not**
  required for the analysis to be recorded (evidences checks job + grade; refusing would lose a biometric result for
  good, and the `analyse` entry names the actor truthfully); the link offer and linking require it. Without the
  argument (unpatched evidences) the holder cannot be checked.
- **Result whitelist**: fingerprint → `fingerprint`; DNA/blood → `dna`; ballistics → `serial`, `weaponType`, `kind`;
  all → `crimeScene` (from the `collect` entry recorded at registration, not the analysis-time metadata that
  setAnalysed's client `information` can overwrite), `collectionTime` (the collector's client clock) and `note`
  (evidences' laptop "additional data" text, editable by anyone with laptop access through
  `evidences:updateAdditionalData`: shown as reported), `analysedAt` (DB clock)
  and `match { citizenid, name }` from the registers the laptop uses (name from `fredpd_persons`, never
  `players.charinfo`). Scratched serials (`imperfections`), image paths, labels etc. are not stored.
- **Hook never blocks**: the swapItems hook function is `return true` and touches nothing; the post-hook event
  (only for completed moves) runs the DB work in its own thread. Custody action: into a locker = `handin`
  (`return` after a `checkout`), out of one = `checkout`, locker → locker = `transfer`, within one inventory =
  nothing. Lockers = inventory ids matching `lockerPatterns` (`^evidence_` FredPD stashes, `^evidence%-%d+$`
  ox_inventory's own police lockers).
- **Chain** is appended in SQL (`JSON_ARRAY_APPEND`, one statement, no lost update), entries
  `{ at (DATE_FORMAT(UTC_TIMESTAMP())), actor (citizenid), action, location, note }`, capped at 200: the oldest entry
  after `collect` is dropped. The output maps actors to `OfficerRef` (Discord name + callsign from `fredpd_officers`).
- **Link transaction**: oxmysql's `transaction.await` is a fixed batch (docs/deps-verification.md §10), so `n` is read
  just before (`MAX(n)+1`), the tag formatted in Lua with fredpd_core's `formatId`, and the batch locks the case row
  (`SELECT … FOR UPDATE`) and updates the evidence `WHERE case_id IS NULL`. A concurrent link that took the same `n`
  makes the batch roll back on `uq_case_n`/`uq_tag`; it is retried once with a fresh `n`. A read-back decides the
  outcome (someone linked it elsewhere meanwhile → `already_linked`). Evidence level becomes `GREATEST(level,
  case level)`. `MySQL.startTransaction` was not used: experimental, a console warning per call, and its commit is
  not awaited (`oxmysql src/database/connection.ts:61-66`).
- **Link rules**: actor on duty with `perm:evidence.link`; the evidence is visible in full to the actor or was
  analysed by them; not linked yet; the case exists (`none` → `not_found`, so existence does not leak), the actor's
  canView of the case is `full` (else `unauthorized`), the case is open.
- **Visibility** (§C3, record type `evidence`): linked evidence takes the case's status, unit, assignees and owner,
  and the higher of its stored level and the case's **current** level (review 2, finding 2: a case raised after the
  link, §C14; the output `level` is that effective level; lowering a case does not lower evidence below the level
  stored at link time); its view is also capped at the viewer's view of the case (evidence is never more visible
  than its case, whatever the rules);
  unlinked evidence is a record of unit `labUnit` (tekniker) with the collector and analysts as assignees, and holders
  of `perm:evidence.link` see unlinked evidence up to their tier. `full`/`masked` are returned, `notice`/`none` are
  left out (`not_found` for get). The person `match` is only returned when the evidence view is `full` and, for
  linked evidence, the viewer's view of the case is `full`; for unlinked evidence the viewer must also be in the lab
  unit (`getUnits`), hold `perm:evidence.link` (up to their tier) or `perm:records.admin`. A collector/analyst who sees
  unlinked evidence only through `assigned` gets it without the match.
- **Case page**: `listCaseEvidence` needs no `mdt_page:evidence` (a case viewer without the Bevis page still sees the
  case's evidence): on duty, canView of the case `none` → `not_found`, `notice` (kontaktnotis) → an empty list,
  `full`/`masked` → the same per-row shaping as `listEvidence`.
- **Dialog vs laptop focus**: the offer arrives while evidences' laptop holds NUI focus (`SetNuiFocus(true, false)`);
  opening `lib.inputDialog` on top and closing it would drop the focus the laptop relies on (Esc arrives as an NUI
  key event), leaving the player stuck in the laptop camera. So the dialog opens at once only when
  `IsNuiFocused()` is false; otherwise the player is told to close the laptop and pick "Koppla till ärende" on any
  laptop (an ox_target option whose `canInteract` is "an offer waits"). No polling.
- **Lab**: entering a lab box adds "Analysera" on the laptop model and spawns a local, frozen `p_laptop_02_s` at the
  configured bench (evidences' own "Använd laptop" option works on it too); leaving removes both. "Analysera" calls
  evidences' `openLaptop` export (added by `evidences.20`); without the patch it tells the player to use the
  laptop's own option. No analysis logic in FredPD.
- **Lockers**: `RegisterStash` at start (label from `evidence.locker`, `groups = { police = 0 }` = ox_inventory's own
  open check, which knows neither duty nor FredPD grants: the qbx bridge ignores duty) plus an ox_target box per
  locker, and an ox_inventory `openInventory` hook (`inventoryFilter = lockerPatterns`, ox_inventory `server.lua:260`
  groups then `:288-290` hook) that returns false unless the player is on duty and holds `config.lockerGrant`
  (default `mdt_page:evidence`; everyone who hands in evidence needs it, patrol included; `false` = groups only),
  with an `ox_lib:notify` (`evidence.lockerDenied`). Synchronous in-memory checks only; it also gates
  ox_inventory's own `evidence-<n>` lockers. Custody is recorded for any locker matching the patterns.
- Migration `011_evidence.sql` adds `item_name` and `ident` (uid registry); `result IS NULL` = not analysed.

## Coordinates (config.lua) — placeholders

`labs[1]` (box at 474.6, -990.4, 26.3, laptop 474.9, -990.1, 27.25, heading 180) and `lockers[1]` (475.0, -996.25,
26.27, the location common qb police configs use for the MRPD evidence room) are **not verified** on Rami's MRPD
interior. Stand at the bench / locker in game, read the position with any coords tool, edit `config.lua`, restart
`fredpd_forensics`. If the lab laptop floats or sinks, adjust `laptop.z` only.

## In-game steps (§5.7 acceptance)

Prerequisites: patches applied (`node scripts/apply-patches.mjs`), evidences run from its v1.3.1 release zip with
`evidences.20` + `.30` applied to it, `setr ox:locale sv`, `ensure fredpd_forensics` after ox_inventory, ox_target,
evidences and fredpd_core. Tester: job police, FredPD grants `mdt_page:evidence`, `perm:evidence.link`,
`unit:tekniker`, on duty, assigned to an open case (e.g. K-123-26), with a `forensic_kit`.

1. Let a second player touch a car door (or shoot) so evidences leaves a fingerprint; aim at it with the forensic kit
   → "Säkra fingeravtryck". A "Säkrat fingeravtryck" item appears.
2. Walk into the MRPD lab box: a laptop appears on the bench with the option **Analysera**; open it.
3. In the fingerprint app select the item → "Starta analys". Close the laptop (Esc).
4. A notice says the evidence is analysed; aim at the laptop → **Koppla till ärende** → enter the case number
   (e.g. `K-123-26`) → "Bevis B-K-123-26-001 är kopplat till ärende K-123-26."
5. Go to the evidence locker → "Öppna bevisförrådet" → drag the item in.
6. Open the tablet → the case → evidence row `B-K-123-26-001` → its chain shows 4 entries: Säkrat, Analyserat,
   Kopplat, Inlämnat (needs the fredpd_mdt/NUI integration below).
7. Take the item out of the locker, give it (ox_inventory Ge) to an on-duty colleague with `mdt_page:evidence`, who
   puts it back: the chain gains Uttaget, Överlämnat (to the colleague) and Återlämnat, and the Bevis list still
   shows one row (no second record for the colleague).
8. Console: no `SCRIPT ERROR` from evidences' `setAnalysed` (the unpatched evidences would print one in step 3).

Note on the "collect → hand-in → analyse → link" order: evidences only analyses items the analyst carries
(`getPlayersItemsWithEvidence`, `server/dui/callbacks.lua:113-147`), so evidence handed in first must be taken out
again, which is recorded as `checkout` (5 entries: collect, handin, checkout, analyse, link; tested). The 4-entry
story is collect → analyse → link → hand-in (tested, and the steps above).

## Tests

- `lua5.4 tests/lua/run.lua forensics_` → 49, on both stacks: default `FREDPD_FORENSICS_STACK` (qb: qb-core
  framework + ox pair) and `FREDPD_FORENSICS_STACK=qbx` (qbx_core + ox pair); the fredpd_core mock's `bridgeInfo` and
  the audit actor are the REAL `server/bridge.lua`. `forensics_bridge_test` (6): plain qb stack idle (nothing
  registered, one warning, exports `unavailable`, ox_inventory never touched, also after evidences starts), ox pair
  with evidences started late (idle → wired once by the re-check, enable event + convar), qb/qbx smoke (collect,
  link, audit actor), `Service.inventory()` gate, static check (no qb-core/qbx/ox_target/doorlock calls,
  ox_inventory only in the two gated places, fxmanifest deps). `forensics_shared_test` (9, pure),
  `forensics_client_test` (10, the REAL `bridge/client.lua` over mocked ox_target/qb-target, ox_lib, natives; 08-10:
  qb-target stack registers nothing, enable event, late ox_inventory start), `forensics_server_test` (24, MariaDB `fredpd_test_forensics_lua`, session time zone
  `+02:00`, an ox_inventory double that runs the registered hooks with upstream's filter/post-event semantics,
  including `giveItem` and `AddItem`'s repeated `Items.Metadata`):
  wiring, collect + UTC + no phantom rows, hook never blocks / no SQL in the hook / failed moves, the §5.7 story (4
  entries), the hand-in-first story (checkout/return/transfer, swap moves both items, ox `evidence-<n>` lockers),
  repeat/copied-uid/type-mismatch/non-analysed events, ballistics + firearm register, legacy items, the link
  authorization matrix (12 cases + rate limit + playerDropped), tag numbering per case with a concurrent link forcing
  the retry, tablet exports, visibility (full/masked/notice/unlinked/records.admin/level cap), chain cap,
  evidence_box, golden JSON, static SQL/SPDX and locale-key checks; review fixes: give keeps one record (+ undone
  give, same holder, locker arrivals, checkout → give → return), uid registry (R2 tampered owner, R3 copied uid,
  item-name mismatch, pre-011 row filled then enforced), locker open matrix, `formats.json` missing, case page
  export + unlinked match rules; review 2: a forged fresh uid + collector re-stamped without collector (also in a
  locker, and unknown uid without inventory = nothing written), a minted uid whose registration failed registered
  late with the mint's collector, a case raised after the link hides its evidence (get/list/listCaseEvidence, output
  level, view capped at the case view under a permissive rule), analysis refused for a locker / another player /
  someone else's container and accepted for the analyst's own container, crime scene from the collect entry.
  Skips with a notice when MariaDB is unreachable.
- `pnpm exec vitest run --project resources "resources/[fredpd]/fredpd_forensics"` → 17 (goldens vs zod, incl. the
  collector view without match and the `listCaseEvidence` output with a `transfer` entry).
- `pnpm exec tsc -p "resources/[fredpd]/fredpd_forensics/test/tsconfig.json"`.

## UNVERIFIED (needs FXServer)

- ox_inventory's post-hook `TriggerEvent(hookId, …)` reaching a handler in another resource, and the createItem hook
  result crossing the resource boundary (both read from source only).
- The biometric analysis bug and its fix (read from source: `pairs(nil)` in Lua 5.4 raises; ox_lib pcall).
- `IsNuiFocused()` being true while evidences' laptop is focused; `lib.inputDialog` over it.
- `exports.evidences:openLaptop` (patched export) opening the DUI on a client-side (non-networked) prop.
- Server-side `GetEntityCoords(GetPlayerPed(src))` for the lab location (OneSync).
- `GetContainerFromSlot` + `GetInventoryItems` on a container just moved into a locker.
- MRPD coordinates in `config.lua`.
- The give path end to end: ox_inventory `giveItem` → `AddItem` → `Items.Metadata` → FredPD's createItem hook seeing
  the giver's `item_uid` in `payload.metadata` (read from source; the metadata is a `table.clone`, crossing the
  export boundary as msgpack) and returning nil to keep it.
- The `openInventory` hook's `false` stopping `forceOpenInventory` too (admins without the grant are blocked), and the
  `ox_lib:notify` reaching the player.
- `exports.ox_inventory:GetInventoryItems(src)` listing a held container item with `metadata.container` (the analysis
  holder check), and evidences passing a player inventory as a number (msgpack) in `arguments.inventory`.

- Bridge: `SetConvarReplicated` at runtime reaching already-connected clients (the enable event covers them anyway);
  `onResourceStart('evidences')` + 1 s being late enough for `GetResourceState('evidences') == 'started'`;
  `onClientResourceStart` firing for ox_inventory/ox_target that start after this resource on a client.

## Integration requests

1. **fredpd_mdt**: merge `EVIDENCE_ACTIONS` (packages/types/src/evidence.ts) into the dispatcher and route
   `listEvidence`/`getEvidence`/`linkEvidence` to `exports.fredpd_forensics:<name>(src, input)`; add their Lua input
   mirrors to `shared/validate.lua`. Rate limit class: reads for list/get, write for link. Restore absent nullable
   fields before a strict parse (as for alerts; `contract.test.ts` shows which).
2. **NUI Bevis page** (`mdt_page:evidence`): tabs "Att koppla" (`unlinked = true`) and "Alla"; detail = chain
   (`evidence.chain.*` labels incl. the new `checkedOut`/`returned`/`transferred`, `evidence.field.location`),
   result (`evidence.match` only when `result.match` is present), "Koppla till ärende" (`linkEvidence`, perm
   `evidence.link`). Topic `case` push `{ type = 'evidenceLinked', caseId, evidenceId }` → refetch.
3. **fredpd_records**: `getCase` fills `evidence` from `exports.fredpd_forensics:listCaseEvidence(src, { caseId })`
   (not `listEvidence`, which needs `mdt_page:evidence`; same output, `{ id, tag, type, collectedAt }` per item);
   the case timeline can use the `evidence.link` audit rows (`target_type = 'evidence'`, `meta.caseId`).
4. **Orchestrator: evidences security patch** (docs/deps-verification.md Decision 5.1; deps.lock assigns it to task
   4.2, the task card limited `patches/evidences.*` to the Swedish locale). Either extend this task's ownership to
   `patches/evidences.10-security.patch` or assign it before Phase 4 sign-off: in `actions.collect` strip
   `item_uid`, `collected_by`, `collected_at` from the client `metadata` and allow only `removeFrom*` in
   `remove.fun`; make the net `evidences:syncEvidence` accept only the methods its client uses, with
   `atItem`/`removeFromItem` only on `inventory == source` and client `data` dropped. The uid registry (Decision 5.2,
   done here) refuses mismatching items but cannot stop a client-chosen owner at collect or a uid copied together
   with an identical identity. Keep clear of `server/dui/callbacks.lua:199-214` and
   `client/dui/laptops/target.lua:7-9`, which `evidences.20` changes.
5. **evidences permissions → FredPD grants** (deps-verification §3): evidences checks jobs only (`config.lua:84-104`,
   no duty). A small patch of `framework.hasPermission` to `exports.fredpd_core:hasGrant` + `isOnDuty` would make
   collecting/the laptop follow Discord roles. Not done here (scope).
6. **Orchestrator: ratify `patches/evidences.20-fredpd-integration.patch`** (outside "Swedish locale only"; review 2
   finding 4, still open — a decision, not a code change): without its one-line fix (`pairs(nil)` at
   `server/dui/callbacks.lua:202-203`) the §5.7 fingerprint story cannot work at the pin, "Analysera" has nothing to
   call, and the analysis holder check has no inventory to check. Ratify it together with item 4, or move its three
   hunks to whoever owns evidences' functional patches. Item 4 (`evidences.10-security`) removes most of the residuals
   above (forged uids/collectors via `atItem`, remote `setAnalysed`/`updateAdditionalData` on stash items if it also
   restricts `getItem` to the source's own inventory and containers).
7. **ox_inventory items**: `ox_inventory.20-evidence-items.patch` is generated against pristine upstream (no
   `ox_inventory.10-fredpd-items.patch` existed). It inserts after `['lockpick']` (not at the end of the table) to
   stay clear of an append by `.10`; if `.10` edits that spot, regenerate `.20` on top of it. A recipe-installed
   server replaces `data/items.lua` (deps open question), so the block may have to be pasted by hand. Item images:
   evidences' `item_images.zip` release asset into `ox_inventory/web/images/`.
8. **server.cfg.example** (owner): `ensure evidences` (release zip) before `ensure fredpd_forensics`.
9. Perm label `perms.perm.evidence.link` is in `locales/pending/service.json` (service agent).
10. **NUI Bevis page / case page** (addition to 2): a `transfer` entry without `location` is a hand-over between
    officers → `evidence.chain.handedOver` ("Överlämnat till {name}"); with a location → `evidence.chain.transferred`.
11. **db owner** (docs/modules/db.md): list `011_evidence.sql` (fredpd_evidence `item_name`, `ident`; owner
    fredpd_forensics) next to 006.
12. **Role config**: opening an evidence locker now needs `mdt_page:evidence` + on duty (`config.lockerGrant`); give
    it to every role that hands in evidence (patrol included), or set `lockerGrant = false`.
13. **NUI (Bevis page)**: while evidence is off the tablet actions answer `unavailable` with reason `evidence_off`.
    Today `errorLocaleKey` shows the generic `errors.serviceUnavailable` ("Tjänsten är inte tillgänglig just nu. Försök
    igen om en stund.") with a retry. Add `evidence_off: 'evidence.unavailable'` to `REASON_LOCALE_KEYS`
    (apps/nui/src/api/errors.ts), treat it as not retryable, and ideally hide the Bevis nav entry / case-page evidence
    block; key in `locales/pending/forensics-bridge.json`.
14. **docs/contracts.md §C17 owner**: document the forensics switch (convar `fredpd_forensics_evidence`, net event
    `fredpd:forensics:client:enable`, reason `evidence_off`); the bridge doc still lists `ox_inventory`/`ox_target`
    among this resource's direct calls, now limited to `Service.inventory()` and the client locker open.
15. **fredpd_core (bridge)**: optional `inventory` in `clientBridgeInfo()` / a replicated `fredpd_bridge_inventory`
    convar would let the client check the selected inventory itself instead of "ox_inventory started".
