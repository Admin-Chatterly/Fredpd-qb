<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Phase 3 in-game test (Rami)

Checks alerts end to end on the qb stack (IMPLEMENTATION.md §5.5, docs/contracts.md §C13): the ps-dispatch bridge,
the toast and sound, "Ta larm" (G) with waypoint, the tablet Larm page with live updates, closing, the BOLO radar
and garage hooks, and the portal's live list. Ten steps, about 35 minutes. Run it on the **test server**:
step 1 uses `/fredpd_testalert`, which only exists with `set fredpd_dev true`.

You need **three players**: **A** and **B** = officers on duty (police job, `mdt_page:alerts`, a tablet); B also has
`perm:alerts.manage` for step 5. **C** = a civilian (or an officer off duty).

Tick each step. If one fails, copy the F8 console and the txAdmin Live Console lines around it into the report.

## Before you start (once)

1. `scripts\fetch-deps.ps1`, `scripts\apply-patches.ps1` (ps-dispatch, qb-policejob and qb-garages patched copies),
   `scripts\build.ps1`, copy `resources\[fredpd]` and the patched upstream folders to the server, restart.
2. server.cfg: `ensure ps-dispatch` **before** `fredpd_dispatch`, `set fredpd_dev true` (test server only).
   The console shows migration `005_dispatch.sql` applied once and no ps-dispatch warnings about its UI.
3. ps-dispatch's own popup/menu must be **off**: no ps-dispatch NUI appears in any step (FredPD toasts instead), and
   `/dispatchtest` does not exist.

## Steps

### 1. Test alert → toast within a moment ☐

A (admin): `/fredpd_testalert`. A and B get a "Nytt larm" toast (code, title, street, "Tryck G för att ta larmet")
and a short sound, practically at once (target ≤ 100 ms). C gets **nothing**. Go off duty with B and repeat: only A gets it.

### 2. A real ps-dispatch alert becomes a FredPD alert ☐

C fires a gun on the street away from Ammu-Nation. A and B get one "Skottlossning" toast (not one per shot within a few
seconds). SQL: `SELECT id, code, status, source FROM fredpd_alerts ORDER BY id DESC LIMIT 3;` → the new row is `open`.

### 3. G = Ta larm: assigned, waypoint ☐

A presses **G**. A gets "Du har tagit larmet. Vägpunkten är satt." and a GPS waypoint. On B's tablet (Larm page
open) the row changes to "Tilldelad: <A:s anropssignal> · <namn>" by itself, without reopening the page.

### 4. Two officers press G at once ☐

Create two alerts (`/fredpd_testalert` twice). A and B press G at the same moment: each gets a **different** alert,
never the same one. Pressing G again right away is refused politely (1 per second).

### 5. Join, leave, close on the tablet ☐

B takes A's alert on the Larm page (Ta larmet), then Lämna larmet: it stays "Tilldelat" (A is still on it). A
leaves too: it goes back to "Öppet". An officer who is not on the alert and lacks `alerts.manage` cannot close it
(Avsluta larmet is missing or refused). B (`alerts.manage`) closes it: it disappears from every open tablet at once.

### 6. BOLO → radar alert ☐

B: `/fredpd_testbolo` or Efterlysningar → Ny, vehicle with the plate of a car C drives. C drives past a qb-policejob
speed radar (any speed). A and B get an alert "Efterlyst fordon: <plate>" (origin ANPR-kamera); the same plate
within 60 s does not alert again.

### 7. BOLO → garage alert ☐ *(needs the patched qb-garages; else skip)*

C parks the wanted car in a public garage: an alert "Efterlyst fordon: <plate>" with "<plate> parkerades i
<garage>." comes in (origin Garage).
Resolve the BOLO: parking the car again gives no alert.

### 8. Portal: live Larm ☐

Log in to the portal as A (the character with `mdt_page:alerts`), open **Larm**. `/fredpd_testalert` in game: the new
row appears within about a second, without reloading. A presses G in game: the portal row shows the assignment. Close
the alert on B's tablet: it leaves the portal's "Öppna" list. Stop `fredpd_service` for 10 s and start it again:
the page reconnects by itself and shows the current list.

### 9. Units ☐

Tablet Larm → Enheter (and the portal's Larm page): A and B are listed with anropssignal and status (Ledig / På
larm). B goes off
duty: B disappears from both lists within a few seconds.

### 10. Idle cost (resmon) ☐

F8 → `resmon 1`. With no alerts coming in, `fredpd_dispatch` shows **0.00 ms** on the client. Receiving a toast
gives only a short blip, then 0.00 again. `ps-dispatch` shows no steady cost either (its debug zones are off).
