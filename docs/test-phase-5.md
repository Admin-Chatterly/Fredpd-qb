<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Phase 5 in-game test (Rami)

Checks cases, reports, charges and ordningsbot end to end, the visibility story of IMPLEMENTATION.md §5.3 (kontaktnotis
while open, Standard parts after close), sekretess levels, the obehörig-sökning flag and the masked release. Ten
steps, about 45 minutes. You need **two players**: **A** = you (Utredning or Ledning unit, `intel_tier:1` or higher,
`mdt_page:cases`, `mdt_page:search`, `perm:cases.create`, `perm:charges.apply`, `perm:charges.fine`) and **B** = a
patrol officer (IGV unit, tier 0, `mdt_page:cases`, `mdt_page:search`, `perm:charges.fine`, no `records.admin`).
Step 9 needs someone with `perm:records.admin` (A may hold it for that step only). Both on duty with a tablet.

Tick each step. If one fails, copy the F8 console and the txAdmin Live Console lines around it into the report.

## Before you start (once)

1. `node scripts/merge-pending-locales.mjs`, then `scripts\build.ps1`, copy `resources\[fredpd]` to the server and
   restart. The console shows migration `013_records.sql` and seed `report_templates_sv.sql` applied once.
2. SQL: `SELECT id, name FROM fredpd_report_templates;` → Anmälan, PM, Beslagsprotokoll, Förhör.
3. `config/integrations.json`: `framework` `qb-core` (qb-inventory, qb-target, qb-doorlock) and `"prison": "xt-prison"`.
   The console line `bridge: framework=qb-core, …` appears once; fredpd_records logs nothing about qbx_core,
   Renewed-Banking or ox_*.

## Steps

### 1. Create a case: number and owner ☐

A: Ärenden → Nytt ärende, rubrik "Test misshandel", sekretessnivå Standard. The case opens with number
**K-1-26** (or the next free number this year), A as handläggare, unit = A's unit. Create a second one: number + 1.
Try sekretessnivå **Hemlig** as a tier-1 officer: refused ("behörighet"), nothing created.

### 2. B sees only a kontaktnotis while the case is open ☐

A adds B's character as inblandad (misstänkt) on "Test misshandel". B looks up **their own character** (Sök → person):
under Ärenden B sees "Det finns uppgifter som rör … Kontakta <A:s namn>" and **no** case number or rubrik. B opens
Ärenden → Alla: the case is **not** listed.

### 3. Assign, push and timeline ☐

A: Lägg till handläggare → B as Handläggare. Within a second B gets "Du har tilldelats ärende K-…" and, with the
tablet open on Ärenden, the list refreshes by itself. B now opens the case in full. The Händelser list shows
"Ärende upprättat", "Inblandad tillagd", "Handläggare tilldelad" with A's Discord name, newest first.

### 4. Report: template, autosave, numbering ☐

A: Ny rapport → mall **Anmälan**: the body is prefilled; number **K-…/1**. Type a few lines, wait 10 s without typing:
"Utkast sparat kl. hh:mm". Close the tablet, reopen the report: the draft is offered. Spara. B (member, not author)
opens the report: readable, **not** editable. Both press Ny rapport at the same time: the two reports get /2 and /3.

### 5. Charges with sums ☐

A in the report: Lägg till brott → "Misshandel" × 2 and "Ringa misshandel": totals show 14 000 kr and 20 min.
Save. The person page of the suspect lists the three rows under Belastningsregister. With the suspect's character
standing ≤ 5 m from A when saving, xt-prison takes them in for 20 min (`charges.apply` audit meta `jailed = true`). Change nothing in the catalogue:
Brottskatalog page lists ≈120 rows, search "hastighet" finds the speeding codes.

### 6. Ordningsbot: class, distance, money ☐

B stands next to A's character (≤ 5 m), Utfärda ordningsbot → "Förargelseväckande beteende": A's bank balance drops
1 500 kr, A gets "Du har fått en ordningsbot på 1 500 kr." (The money is not credited to any police account yet.)
B walks 10 m away and tries again: refused (too far).
Choosing a non-ordningsbot charge (e.g. Ringa misshandel) is refused. Two fines within 2 s: the second is refused.

### 7. Sekretess: levels and lowering ☐

A: create a report at level **Begränsad** in the case. B (tier 0, assigned) can read it (assignment beats the tier).
A officer of **A's unit** with tier 0 (not assigned) sees the report number **without** rubrik on the case page and
cannot open it. Remove B as handläggare: B is back to the kontaktnotis for the whole case. A tries to lower the report
to Standard: refused unless A has `records.admin`; setting it to Hemlig as a tier-1 officer is refused.

### 8. Close: Standard parts become visible ☐

A: Avsluta ärendet with a motivering. Status Avslutat, sekretessnivå unchanged. B (not assigned) looks the suspect up
again: the case now shows **number and rubrik** (Standard parts), not only the kontaktnotis. A Begränsad case closed
the same way still shows only the kontaktnotis to B.

### 9. Obehörig sökning ☐

B looks up three different persons who are not in any of B's cases (Sök → open each person). Ledning (records.admin,
on duty) gets "Möjlig obehörig sökning: <B> har slagit på 3 personer …" once; a fourth lookup does not notify again.
SQL: `SELECT action, target_id, meta FROM fredpd_audit WHERE action = 'lookup.flag' ORDER BY id DESC LIMIT 1;`.

### 10. Begär ut allmän handling (masked) ☐ *(needs the station target / portal form; else skip)*

A civilian character requests "K-1-26" at the station (or on the portal). Ledning: Utlämnanden → pröva → "Lämna ut
med maskering". SQL: `SELECT status, released_body FROM fredpd_release_requests ORDER BY id DESC LIMIT 1;` →
`released_body` holds the Standard rubrik and the Standard report text only: **no** Begränsad report from step 7, no
officer names, no person names. Requesting an **open** case: "Lämna ut" is refused (nothing releasable).
