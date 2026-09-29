<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Phase 2 in-game test (Rami)

Checks the tablet end to end: issuing, opening (item and vehicle terminal), speed and idle cost, that Esc always
gives the mouse back, search/person/vehicle pages, BOLOs reaching another officer's tablet, the Hem page and
revoking a tablet. Ten steps, about 45 minutes. You need **two players** (a second PC or a friend) for steps 7 and
9, both with a police character and a Discord role that has `mdt_page:search`, `mdt_page:bolos`,
`perm:bolo.create` and (for you) the Ledning unit plus `perm:tablets.manage` (Behörigheter page, Phase 1).

Tick each step. If one fails, copy the F8 console and the txAdmin Live Console lines around it into the report.

## Before you start (once)

1. **Build:** `scripts\build.ps1` and copy `resources\[fredpd]` to the server. (The tablet texts are already in
   `locales/sv.json`; only if `locales/pending/` holds files from later work, run
   `node scripts/merge-pending-locales.mjs` first.) For step 3 build the NUI in dev mode once: `pnpm --filter @fredpd/nui build:dev`, then
   `node scripts/build.mjs --skip-web`.
2. **Item:** `scripts\apply-patches.ps1` adds `pd_tablet` to ox_inventory. On a txAdmin **Qbox recipe** install the
   patch cannot apply (the recipe replaced `data/items.lua`): paste the block from `docs/modules/mdt.md`
   ("ox_inventory item") into `ox_inventory/data/items.lua` instead.
3. **server.cfg:** after `ensure fredpd_core` add `ensure fredpd_records`, `ensure fredpd_bolo`, `ensure fredpd_mdt`.
   Restart the server.

## Steps

### 1. Issue two tablets ☐

In the txAdmin console: `surfplatta <your server id>` and `surfplatta <other player's id>` (ids from `status`).
Each player gets "Du har fått surfplatta SP-…". Hover the item: label **Surfplatta**, "Serienummer: SP-…".
SQL: `SELECT serial, owner_citizenid, issued_at FROM fredpd_tablets;` → two rows, `issued_at` 1–2 h behind Swedish
time (UTC). In game, as Ledning: `/surfplatta <id>` works too; a player without `perm:tablets.manage` gets "Du har
inte behörighet att göra det här."

### 2. No grant or off duty: Swedish message, nothing opens ☐

Go **off duty** and use the tablet: "Du måste vara i tjänst för att använda surfplattan." Remove your mdt roles in
Discord (or use a character/account without them), go on duty, use it: "Du har inte behörighet att använda
surfplattan." In both cases no tablet, no prop, and the mouse cursor does **not** appear. Give the roles back.

### 3. Opening: speed, prop and animation ☐

On duty, use the tablet from the inventory. The tablet opens at once; F8 (dev build) shows
`[fredpd] open -> first paint N ms` with **N < 300**. Your character holds a tablet in the right hand and plays the
tablet animation **standing** (tell us if the pose or the prop's position looks wrong). Other players see the prop.

### 4. Esc always closes ☐

With the tablet open: press **Esc** → it closes, the mouse is back, the prop is gone. Open it, click into the
search field, type something, press Esc → closes. Open it, use the close button → closes. Open it and die (fall
from a roof or `/kill` if you have it) → it closes by itself. If you are ever stuck with a cursor: F8 →
`fredpd_mdt_close` (and report it).

### 5. Idle cost (resmon) ☐

F8 → `resmon 1`. With the tablet **closed**, `fredpd_mdt` shows **0.00 ms**. With it **open** and idle, at most
**0.05 ms**. Close it again → back to 0.00.

### 6. Search, person and vehicle pages ☐

Search a name, a personnummer and a plate (`ABC 12D` style); Enter opens the top hit. The person page shows the
person's vehicles and BOLOs; the vehicle page shows owner, BOLO flag and "Kontrollera"-history. Search `a`
(one letter): nothing breaks, the page asks for 2 characters.

### 7. BOLO → plate check → the other officer's tablet ☐

Player B keeps their tablet **open** on Efterlysningar. You create a vehicle BOLO for a car standing nearby (its
plate). Within a second it appears on B's list without B doing anything. Close the tablet, walk to the car, ox_target
**Kontrollera registreringsskylt** → the popup shows the hit in red and an alert goes out.

### 8. Vehicle terminal ☐

Sit in a police car (driver or front passenger; models in `fredpd_mdt/config.lua`). ox_target on the car →
**Använd fordonsdatorn** → the tablet opens **without** a prop in hand. Leave the car (F) → it closes by itself and
the mouse is back. From the back seat the option is not offered.

### 9. Revoke a tablet that is in use ☐

Player B opens their tablet. You (Ledning) open Ledning → **Surfplattor**: both tablets, owner names from Discord,
"Utfärdad" in Swedish time. **Spärra** B's tablet → B's tablet closes at once with "Surfplattan är spärrad.
Kontakta ledningen." and B cannot open it again (same message). **Häv spärren** → B can open it again.
SQL: `SELECT action, target_id FROM fredpd_audit WHERE action LIKE 'tablet.%' ORDER BY id;` → issue ×2, revoke,
reinstate.

### 10. Hem per unit ☐

Your Hem (Ledning) shows active BOLOs, your open cases, officers on duty and the roster of on-duty officers with
callsigns. Player B (IGV) sees the IGV variant without the roster. Go off duty while the tablet is open → it
closes with "Du måste vara i tjänst för att använda surfplattan."
