<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Phase 6 in-game test (Rami)

Checks door breaching with the ram (IMPLEMENTATION.md §5.6, docs/modules/breach.md, docs/contracts.md §C16/§C17) on
the qb stack (qb-doorlock, qb-target, qb-inventory): the grant, duty and item checks, the 4 s progress bar, the unlock
through fredpd_core's doorlock bridge, the audit row, the cooldown and the deny list. Ten steps, about 30 minutes.
You need **two players**: **A** = officer (police job) and **B** = a civilian, plus one **locked qb-doorlock door**
that is not a station door (e.g. a shop back door you add to qb-doorlock's config) — call it "testdörren".

Tick each step. If one fails, copy the F8 console and the txAdmin Live Console lines around it into the report.

## Before you start (once)

1. `scripts\apply-patches.ps1` (`qb-core.10-fredpd-items` adds `pd_ram` "Murbräcka", `qb-doorlock` patch adds the
   door export/event), `scripts\build.ps1`, copy `qb-core`, `qb-doorlock` and `resources\[fredpd]`, restart.
2. `ensure fredpd_breach` after `fredpd_core`. Console once: `bridge: framework=qb-core, … doorlock=qb-doorlock`.
3. Give A the item: `/giveitem <A:s id> pd_ram 1`. Portal → Behörigheter: A's role gets `tool:ram` — **not yet**
   (step 1 is without it).

## Steps

### 1. Without the grant: no option ☐

A (on duty, ram in the inventory, no `tool:ram`) looks at testdörren with qb-target: there is **no** "Forcera dörr".
B (civilian) never sees it either.

### 2. Grant arrives live ☐

Give A's role `tool:ram` in the portal. Within a few seconds, without relogging, "Forcera dörr" appears on
testdörren for A. B still sees nothing.

### 3. Breach: progress, unlock, audit ☐

A: Forcera dörr → "Forcerar dörren…" bar for 4 s with the ram in hand → "Dörren är forcerad." and the door is
**unlocked for everyone** (B can open it). SQL: `SELECT actor_citizenid, target_id, meta FROM fredpd_audit WHERE
action = 'breach.door' ORDER BY id DESC LIMIT 1;` → A, the door id and name.

### 4. Cancel keeps it locked ☐

Lock testdörren again (qb-doorlock keys). A starts the breach and cancels (X / move): "Dörrforceringen avbröts.", the
door stays **locked**, no new audit row.

### 5. Cooldown ☐

Right after a successful breach, A tries another locked door: "Vänta en stund innan du forcerar nästa dörr." After
10 s it works.

### 6. Unlocked door, distance ☐

On an **unlocked** door the option is hidden (or "Dörren är redan olåst."). Start the breach at the edge of the target
range and walk 5 m away during the bar: at the end "Du står för långt från dörren.", door still locked.

### 7. Off duty or without the ram ☐

A clocks out: the breach is refused ("Du har inte behörighet …" / duty message). Clock in, drop the ram: "Du behöver
en murbräcka." Nothing unlocks.

### 8. Station doors are denied ☐

A tries a Mission Row door (any door whose name starts with `mrpd` or mentions armory/evidence/vault/bank):
"Dörren kan inte forceras." It stays locked. (Add your own secure doors to `denyDoors` in
`fredpd_breach/config.lua`; see docs/modules/breach.md "Deny list".)

### 9. qb-doorlock restart ☐

`restart qb-doorlock` in the server console. After a few seconds "Forcera dörr" is back on testdörren for A (the door
list is re-read), and a breach still works.

### 10. Housing door ☐ *(needs ps-housing with an MLO property whose door is a doorlock door; else skip)*

`config/integrations.json` `"housing": "ps-housing"`. A breaches the property's front door: it unlocks and the audit
row names it. A **shell** property has no doorlock door: FredPD offers nothing there (ps-housing's own raid applies).
