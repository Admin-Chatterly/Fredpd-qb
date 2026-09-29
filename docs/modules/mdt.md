<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Module: fredpd_mdt (task 2.1, the §C12 dispatcher, getHome, tablets)

The police tablet: the `pd_tablet` item and the vehicle terminal, the NUI host (the `apps/nui` bundle), the one
server callback every tablet action goes through, Hem data (`getHome`) and the tablet registry (`fredpd_tablets`,
Ledning page "Surfplattor"). Implements IMPLEMENTATION.md §4.3, §4.6, §4.7, §5.2, §8.3, §8.4, §8.12 and
docs/contracts.md §C1, §C6, §C12 (plus the §C13/§C14/§C15/§C16 action merges).

## Files

| File | Role |
|---|---|
| `fxmanifest.lua` | deps ox_lib, oxmysql, ox_inventory, ox_target, qbx_core, fredpd_core; `ui_page 'web/build/index.html'`; `files` = web/build, locales, `config.lua`, `shared/validate.lua` |
| `config.lua` | item name, prop/anim, terminal models and seats, `requireOwner`, serial format, rate limits, page size (client-readable, nothing secret) |
| `shared/validate.lua` | Lua mirror of the tablet input shapes (table-driven, incl. nested objects, unions, arrays, refines), `ACTIONS` = action → shape (52 actions, 40 shapes) |
| `server/main.lua` | registers the callbacks, `fredpd:mdt:closed`, exports, the close-on-event handlers, `/surfplatta` |
| `server/open.lua` | open flow, `Open[src]` sessions, pushes, forced closes |
| `server/dispatch.lua` | the §C12 dispatcher and its action table |
| `server/home.lua` | `getHome` |
| `server/tablets.lua` | issue, `listTablets`, `setTabletRevoked` |
| `server/common.lua` | player ids, rate limiter, pcall-guarded fredpd_core/export calls, throttled logs |
| `client/main.lua` | open/close, prop + animation, focus-trap safety, NUI callbacks, pushes, vehicle terminal |
| `test/*.test.ts`, `test/harness.lua`, `test/golden/` | vitest (validation parity, wire contract), Lua test harness, golden JSON |

## Open (`lib.callback 'fredpd:mdt:open'`, `server/open.lua`)

The client sends `{ mode = 'item' | 'terminal', slot? }`; everything is checked on the server, cheapest first. Each
refusal returns `{ error = <locale key> }`, which the client shows with `lib.notify` (Swedish via `L()`); nothing
opens.

| # | Check | Refusal key |
|---|---|---|
| 1 | rate limit 750 ms per player | `errors.rateLimited` |
| 2 | terminal: seated (driver/front passenger) in a `config.terminal.models` vehicle (server natives) | `tablet.unavailable` |
| 3 | item mode (or terminal with `requireItem`): `ox_inventory:GetItemCount(src, 'pd_tablet') > 0` | `tablet.noItem` |
| 4 | any `mdt_page:*` grant (`hasGrant` per MDT_PAGE_KEYS; deny/wildcard rules in fredpd_core) | `tablet.noGrant` |
| 5 | `exports.fredpd_core:isOnDuty(src)` | `tablet.notOnDuty` |
| 6 | a character (`getCitizenId`) | `tablet.unavailable` |
| 7 | serial: the reported slot if it holds a pd_tablet, else the first pd_tablet slot (`GetSlot`/`Search`); must be a row in `fredpd_tablets` | `tablet.unregistered` |
| 8 | not revoked | `tablet.revoked` |
| 9 | `requireOwner` only: `owner_citizenid` = the player's citizenid | `tablet.notOwner` |

ox_inventory, fredpd_core or the DB failing → `tablet.unavailable` / `tablet.noGrant` (fail closed). Success:
`Open[src] = { mode, serial, since }` and the MdtOpenPayload `{ grants = getGrants(src) copy, unit = grants.units[1]
(unit-code pattern, else absent), me = { citizenid, displayName, callsign } }`. `displayName` is the Discord name
from `getOfficer`; without an officer row it is `officer.unnamed` with the last 4 Discord digits (never the
character name, §4.9).

Sessions end on: the net event `fredpd:mdt:closed` (no arguments, so it can only clear the sender's own session;
not rate limited: idempotent, O(1), and a dropped close would leave a stale session), the `close` action,
`playerDropped` (also clears the limiter), `QBCore:Server:OnPlayerUnload`, and forced closes (below).

**Forced closes** (`TriggerClientEvent('fredpd:client:forceClose', src, reasonKey)`): a revoked serial
(`tablet.revoked`), `fredpd:grantsChanged` leaving no mdt_page grant (`tablet.noGrant`), `QBCore:Server:SetDuty`
false / `OnJobUpdate` while off duty (`tablet.notOnDuty`), the `closeTablet` export. Those handlers are
`AddEventHandler` only and ignore a player `source`. The session is written only after a final
`GetPlayerName(src)` check: the open checks yield (inventory, MySQL, core), and a player who dropped meanwhile
(playerDropped already ran) must not leave a stale session.

## Dispatcher (`lib.callback 'fredpd:mdt:action'`, `server/dispatch.lua`)

Exactly §C12: (1) `Open[src]` except `close` → `unauthorized`; a `terminal` session also re-runs the server seat
check (natives only, no DB) and is force-closed (`tablet.unavailable`) → `unauthorized` when the player is no
longer seated in the police vehicle, so a client that suppresses its close event cannot keep the terminal; (2) unknown action or input failing
`shared/validate.lua` → `validation`; (3) the action's grant → `unauthorized`, then on duty except `close` →
`{ error = 'unauthorized', reason = 'off_duty' }`; (4) rate limit per player per action → `rate_limited`;
(5) route. A refusal at any step does not consume the rate limit. Exports answer `{ ok, data | error, reason? }`
(§C12); `data` is returned as is, an error as `{ error, reason? }` (`reason` only if it matches `^[%a_]+$`, ≤ 32).
An unknown code, `ok` without data, a raise, a stopped resource or a malformed answer → `unavailable` (logged,
throttled per resource and function).

| Action | Grant | Limit | Route |
|---|---|---|---|
| close | – | – | local (clears the session) → `{ ok = true }` |
| getHome | – | read | local `home.lua` |
| search | mdt_page:search | lookup | fredpd_records:search |
| getPerson | mdt_page:search | lookup | fredpd_records:getPersonSummary |
| getVehicle | mdt_page:search | lookup | fredpd_records:getVehicleSummary |
| checkPlate | mdt_page:search | lookup | fredpd_bolo:plateCheck |
| listBolos | mdt_page:bolos | read | fredpd_bolo:listBolos |
| createBolo | perm:bolo.create | write | fredpd_bolo:createBolo |
| resolveBolo | perm:bolo.resolve | write | fredpd_bolo:resolveBolo |
| listTablets | perm:tablets.manage | read | local `tablets.lua` |
| setTabletRevoked | perm:tablets.manage | write | local `tablets.lua` |
| listAlerts / getUnits | mdt_page:alerts | read | fredpd_dispatch (§C13) |
| takeAlert | mdt_page:alerts | write | fredpd_dispatch:**assignSelf** (§C13 name; `takeAlert` is an alias there) |
| leaveAlert / closeAlert | mdt_page:alerts | write | fredpd_dispatch |
| listEvidence / getEvidence | mdt_page:evidence | read | fredpd_forensics (§C16) |
| linkEvidence | perm:evidence.link | write | fredpd_forensics |
| listCases / getCase / getReport / listReportTemplates | mdt_page:cases | read | fredpd_records:<same name> (§C14) |
| updateCase / assignCase / unassignCase / addCaseSubject / closeCase / createReport / saveReport | mdt_page:cases | write | fredpd_records |
| saveReportDraft | mdt_page:cases | **draft (5 s)** | fredpd_records |
| createCase | perm:cases.create | write | fredpd_records |
| listCharges | – (duty only) | read | fredpd_records |
| applyCharges / issueFine | perm:charges.apply / perm:charges.fine | write | fredpd_records |
| listSources / getSource / listIntelReports / getIntelReport / getGraph | perm:intel.read | read | fredpd_intel:<same name> (§C15) |
| searchEntities / getEntity / listMissions / getMission | mdt_page:intel | read | fredpd_intel |
| createSource / updateSource | perm:intel.handler | write | fredpd_intel |
| createIntelReport / ensureEntity / addLink / addMissionMember / closeMission | perm:intel.read | write | fredpd_intel |
| createMission | perm:intel.command | write | fredpd_intel |

Limits (config, per player per action): lookup 500 ms and write 2 s (§C12); **read 500 ms** and **draft 5 s** are
our choice (§C12 leaves them open; the NUI debounces autosave ≥ 10 s anyway, §C14). The grant column is the same as
MDT_ACTIONS / DISPATCH_ACTIONS / EVIDENCE_ACTIONS / RECORDS_ACTIONS / INTEL_ACTIONS: the fixture file records it,
vitest compares it with the TS registries (and that no name is in two registries) and `mdt_dispatch_test` with this
table. Every export call is `pcall`ed: a resource not `started`, a missing export (FiveM raises "No such export"), a
raise or an answer without `{ ok }` → `unavailable` (logged, throttled per resource/function). Fine-grained rules
(owner/lead/records.admin, canView, handler/command, audits) stay in the owning resource.

## Validation (`shared/validate.lua`)

Shapes mirror zod 4.6 exactly (field kinds: string, int, bool, enum, number literal, nested object, union of
objects — first option that parses wins, as zod — and array of a kind, which must be a Lua sequence 1..n with no
other keys): JS `trim` white space set (incl. U+00A0, U+2000–200A, U+3000, U+FEFF), **string
lengths in code points** (zod ≥ 4.6 counts code points, not UTF-16 units: an emoji is 1), ints must be integral
numbers within ±(2^53 − 1) (1.0 is accepted and becomes 1), defaults filled, unknown keys dropped (strict `Empty`
refuses them), BoloCreate and CaseSubject refines (reported on `kind` / `type`). Checked twice against
`packages/types/test/fixtures/mdt-inputs.fixtures.json` (40 shapes, 52 actions — every action has valid and invalid
samples —, 113 valid samples with zod's output, 186 invalid) and, in vitest, a generated corpus of ~1800 inputs
(incl. nested `to` / `lines` values) run through zod and Lua must give the same decision and cleaned value.
Known differences: invalid UTF-8 and strings over max(64 KiB, 4 × the field's max) bytes are refused by Lua only (JS
cannot hold the first; the second can only be hit by whitespace that trim would remove); `[]` and `{}` are the same
Lua table (arrays here all have `min(1)`, so both are refused). JSON `null` arrives in Lua as an absent field, so an
optional field sent as `null` is accepted as absent (zod refuses). **This matters for the `.nullable().optional()`
fields** `updateCase.summary` and `updateSource.notes`: `null` ("clear it") reaches fredpd_records / fredpd_intel as
"no change". Integration request below: clear with `''` instead.

## Pushes (exports)

- `pushToOpenTablets(topic, payload[, filter]) -> n`: only open tablets whose holder is **on duty** (checked per
  push), plus `mdt_page:alerts` for topics `alerts`/`units` (docs/modules/dispatch.md request), plus
  `filter(src) == true` when given (a raise excludes). Topics = `PUSH_TOPICS`; `grants` is never broadcast.
- `pushTo(src, topic, payload) -> boolean`: one open tablet, no duty check (the caller targets it on purpose).
- `isTabletOpen(src)`, `closeTablet(src[, reasonKey])` (reason must look like a locale key, else dropped).
- Client: `fredpd:client:push` → `SendNUIMessage({ action = 'push', topic, payload })` only while open;
  `fredpd:client:grantsChanged` → push topic `grants` while open.

## getHome (`server/home.lua`)

**Open alerts count: not added.** HomeOutput.counts is `{ activeBolos, myOpenCases, onDuty }`; an extra key would be
stripped by the NUI's zod parse and is not in the type, so getHome does not call fredpd_dispatch (integration
request 1 below).

`me` = OfficerRef (as above, with `unit`); `variant` = `config/units.json` `home` of the primary unit (first of
`getUnits`), read once from `fredpd_core/config/units.json`; no unit, unknown unit or unreadable file → `igv`
(HomeOutput has no default variant). `counts.activeBolos` and `recentBolos` (≤ 10) from one
`fredpd_bolo:listBolos(src, { active = true, page = 1 })` (so both follow canView and the bolos grant: without
`mdt_page:bolos` they are 0/[]); `myCases` from `fredpd_records:getHomeCases(src, { limit = 10 })`,
`counts.myOpenCases` from `countMyOpenCases(src)`; `counts.onDuty` = online players with
`fredpd_core:isOnDuty`; `roster` (variant `ledning` only) = those with a `getOfficer` row as OfficerRef +
`onDuty = true`, sorted by callsign, name. A stopped or failing source gives 0/[] (logged), never an error.

## Tablets (`server/tablets.lua`, table `fredpd_tablets` from 008)

- **Issue:** `/surfplatta <server id>` (`lib.addCommand`, param `playerId`, **no ACE restriction**: the handler
  requires `perm:tablets.manage` via `hasGrant` and 1 per 2 s; the server console may always issue, for the first
  tablet). Target checked with `TabletIssueInputSchema`'s mirror, must be connected with a character and pass
  `CanCarryItem`. Serial `SP-XXXX-XXXX` (alphabet without I/O/0/1, `math.random`), `INSERT IGNORE` with
  `issued_at = UTC_TIMESTAMP()`, retried on a taken serial (5 attempts); then `AddItem(target, 'pd_tablet', 1,
  { serial, owner = citizenid, description = tablet.itemSerial })`; if AddItem fails the row is deleted again.
  Audit `tablet.issue` `{ owner, target }` (actor 0 for the console); the target gets `tablet.received`.
- **listTablets:** `TabletListOutput`, 50 per page, newest first; `owner.name` = the owner's `fredpd_officers`
  display name, else the citizenid (never the character name); `issuedBy` = OfficerRef or absent (console);
  `issuedAt` via `Time.isoSelect`.
- **setTabletRevoked:** unknown serial → `not_found`. A real change updates `revoked`, `revoked_by`,
  `revoked_at = UTC_TIMESTAMP()` (reinstating clears both) and audits `tablet.revoke` / `tablet.reinstate`
  `{ owner }`; an unchanged state writes nothing. Revoking always force-closes every open tablet with that serial.

## Client (`client/main.lua`)

- `exports('open', function(data, slot))` is ox_inventory's `client.export`; it runs `M.open('item', slot)` in a
  thread. Refused while dead, in the pause menu, or when `web/build/index.html` is missing (no page → nothing
  could answer Esc → never take focus). After the callback: `SetNuiFocus(true, true)`, then
  `SendNUIMessage({ action = 'open', grants, unit, me })` (docs/modules/ui.md), **then** the prop (so streaming
  never delays first paint): `lib.requestAnimDict`/`lib.requestModel`, `CreateObject` (networked per config), attach
  to bone 28422 with the config offset/rotation, `SetModelAsNoLongerNeeded`, `TaskPlayAnim` flag 49,
  `RemoveAnimDict`. A tablet closed while the model streams releases it; a load failure keeps the tablet open
  without prop. No prop in a vehicle.
- `close(notifyServer)`: only when open: `SetNuiFocus(false, false)`, `{ action = 'close' }`, prop detached and
  deleted, anim stopped, `fredpd:mdt:closed` unless the server closed it. When closed it does nothing, so logout
  (`OnPlayerUnload`) or a forceClose never takes focus from another resource's NUI (qbx multicharacter). Focus is
  released unconditionally only by the NUI `close` callback (our own page asked), the F8 command and resource stop.
- **Focus traps (§8.3):** NUI `close` callback (Esc, close button; answers `{ ok = true }`), `forceClose`, death
  (`gameEventTriggered` `CEventNetworkEntityDamage` with the own ped dead, `baseevents:onPlayerDied/Killed`,
  state bag `isDead` of `player:<serverId>` — these handlers are added on open and removed on close, so a closed
  tablet costs nothing), terminal vehicle exit (`lib.onCache('vehicle')`), `QBCore:Client:OnPlayerUnload`, resource
  stop, and the F8 command `fredpd_mdt_close` as a last resort.
- **NUI callbacks:** one per action in `validate.lua` (except `close`): `lib.callback.await('fredpd:mdt:action',
  false, { action, input })` → `cb(result)`; while closed `{ error = 'unauthorized' }` without a server call;
  nothing / a raise → `{ error = 'unavailable' }`.
- **Vehicle terminal:** `ox_target:addModel(config.terminal.models, …)` once (again when ox_target restarts,
  removed on stop); `canInteract` = on-duty leo, seated in that vehicle as driver or front passenger; opens with
  `mode = 'terminal'` and no prop.

## ox_inventory item: `patches/ox_inventory.10-fredpd-items.patch`

Adds `pd_tablet` at the **end** of `data/items.lua`: label `Surfplatta`, Swedish description, weight 800,
`stack = false`, `close = true`, **`consume = 0`** (an item with `client.export` otherwise gets `consume = 1`,
docs/deps-verification.md §8), `client = { export = 'fredpd_mdt.open' }`. Serial and owner are metadata set by
`/surfplatta`, never by the item definition.

- Generated with `git diff` against ox_inventory at the `deps.lock.json` pin (`952c128`, v2.47.9) in a scratch copy
  (the shared `resources/[upstream]` checkout was not modified). `git apply --check` passes there, and it applies
  **before** `ox_inventory.20-evidence-items.patch` (name order in `scripts/apply-patches.mjs`) without touching
  its hunk (that one inserts after `armour`, this one at the end of the file). A later `pd_ram` item (Phase 6)
  should go in its own `ox_inventory.30-*.patch` anchored elsewhere, or be appended to this hunk.
- **Qbox recipe servers:** the txAdmin recipe overwrites `data/items.lua` with Qbox's own list
  (deps-verification §8), so this git patch will not apply there. Paste this block into the server's
  `ox_inventory/data/items.lua` inside the returned table instead:
  ```lua
  ['pd_tablet'] = {
      label = 'Surfplatta',
      description = 'Polisens surfplatta med tillgång till registren. Kräver behörighet och tjänst.',
      weight = 800,
      stack = false,
      close = true,
      consume = 0,
      client = { export = 'fredpd_mdt.open' },
  },
  ```
- Image: ox_inventory looks for `web/images/pd_tablet.png`; none ships (add one, or the default icon shows).

## Locale

New keys in `locales/pending/mdt.json` (8): `tablet.unregistered`, `tablet.issueTarget`, `tablet.issueNoCharacter`,
`tablet.issueCannotCarry`, `tablet.issueFailed`, `tablet.received`, `tablet.itemSerial`,
`audit.action.tablet.reinstate`. Everything else reuses existing `tablet.*` / `errors.*` keys and core's pending
`officer.unnamed`. `mdt_locale_test` checks every key the code uses exists in sv and en with equal placeholders.
The Phase 3–5b wiring adds no player-facing text (errors are codes; the NUI localises them), so there is no
`locales/pending/mdt-wiring.json`.
Note: `tablet.issued` ends with "." after `{name}`, so a name ending in "." shows two dots.

## Tests

- `lua5.4 tests/lua/run.lua mdt_` — 68 tests: `mdt_validate` (fixtures, JS trim, code points, ints, defaults,
  refine), `mdt_dispatch` (order, grants vs fixtures, limits, routing with cleaned input, unwrap, close, main.lua
  wiring; RECORDS/INTEL: every valid fixture sample routed to the same-named export with zod's cleaned value, limit
  class and window per action, each grant column removed → unauthorized and not routed, listCharges duty-only,
  stopped resource / missing export / raise / malformed → unavailable, union/array/refine cleaning), `mdt_open` (every refusal with its Swedish text, payload, slot/serial choice, requireOwner, fail closed,
  rate limit, terminal incl. signed/unsigned model hashes, sessions, forced closes, pushes), `mdt_home`,
  `mdt_tablets` (MariaDB `fredpd_test_mdt_lua`, sessions at `+02:00`: issue/row/metadata/audit, collisions,
  rollback, command, list/paging/ISO UTC, revoke/force-close/reinstate), `mdt_client`, `mdt_locale`.
- `pnpm exec vitest run --project resources fredpd_mdt` — 92 tests (`validate.test.ts`: fixtures vs zod, grant
  columns vs registries, zod/Lua corpus parity; `contract.test.ts`: golden open payload, Hem, tablet list/row vs
  the zod schemas after restoring Lua's absent nulls).
- `pnpm exec tsc -p "resources/[fredpd]/fredpd_mdt/test/tsconfig.json"` (resources/ is not a workspace package; the
  `pnpm lint` owner may want to add it, as for fredpd_core/bolo).

## UNVERIFIED (needs FXServer / the game)

1. The tablet animation clip looks right standing (§5.2 VERIFY); prop offset/rotation on bone 28422.
2. Client-created networked prop under `sv_entityLockdown` (set `prop.networked = false` if it is blocked).
3. Server natives `GetVehiclePedIsIn`, `GetPedInVehicleSeat`, `GetEntityModel` for the terminal check under
   OneSync; that `joaat` (or `GetHashKey`) exists server-side (both handled; hashes compared as unsigned 32-bit).
4. ox_target raycasts hitting the vehicle the player sits in (the terminal option is only for seated players).
5. `CEventNetworkEntityDamage` argument 1 = victim; the qbx death state bag key `isDead`.
6. `lib.callback.await` inside `RegisterNUICallback` handlers; `SetNuiFocus` being per resource.
7. Open → first paint < 300 ms and resmon idle 0.00 / open ≤ 0.05 ms (no threads or timers exist, only handlers).
8. `exports.<res>:<fn>` for an export the (started) resource does not register raises (caught → `unavailable`),
   and nested arrays/objects (`lines`, `to`) survive NUI → client → server msgpack as Lua sequences/tables.
9. A 100 000-code-point report body through `lib.callback` (≈ 400 KB worst case) within ox_lib/FiveM event limits.

## Decisions and questions for the contract owner

1. DISPATCH_ACTIONS and EVIDENCE_ACTIONS are merged now (their exports exist; dispatch.md and forensics.md asked).
2. `reason` passes through with MDT errors (`off_duty`, `duplicate`, …); MdtErrorSchema is non-strict, so this is
   additive. Suggest recording it in §C12.
3. Read-class limit 250 ms (not in §C12). Open limit 750 ms.
4. Serial without an `fredpd_tablets` row → `tablet.unregistered` (an admin `/giveitem pd_tablet` does not work).
5. The vehicle terminal needs no item by default (`terminal.requireItem`); §4.6's item rule is applied to the
   hand-held tablet. Say if the terminal must also require a registered tablet.
6. A hand-held tablet taken from the holder while open keeps working until it closes (the item is checked at open,
   §4.6; grant and duty are checked on every action). Not done: an ox_inventory `swapItems` hook (itemFilter
   `pd_tablet`) that force-closes when the serial leaves the inventory. The terminal is re-checked per action.
7. `pushToOpenTablets` gained the duty/topic-grant rules dispatch.md asked for and an optional filter argument.
8. §C12 names no Hem variant for officers without a unit: `igv` is used.
9. RECORDS_ACTIONS and INTEL_ACTIONS merged (fredpd_records exports coded against §C14's convention — same names —
   while that module is being written; until an export exists the action answers `unavailable`).
10. `takeAlert` routes to `assignSelf` (§C13's export name).

## Integration requests (Phase 3–5b wiring)

1. **Contract owner (mdt.ts HomeOutput):** add `counts.openAlerts: z.number().int().optional()` (open alerts for
   holders of `mdt_page:alerts`, else absent). fredpd_mdt would fill it from one
   `fredpd_dispatch:listAlerts(src, { filter = 'open', page = 1 })` (`data.total`, pcall'd, 0 on failure); a
   cheaper `countOpenAlerts(src)` export in fredpd_dispatch would avoid building 50 Alert rows.
2. **NUI / fredpd_records / fredpd_intel:** `updateCase.summary` and `updateSource.notes` cannot be cleared with
   `null` through the tablet (Lua has no null); treat `''` (valid in zod: trimmed, no min) as "clear".
3. **fredpd_records:** export every RECORDS_ACTIONS name with `(src, input) → { ok, data | error }`; the
   dispatcher already checked grant/duty/limit, but re-validate (any resource can call exports).
4. **Contract owner:** record in §C12 the read (500 ms) and draft (5 s) limit classes.
