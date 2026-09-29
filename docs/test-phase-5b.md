<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Phase 5b in-game test (Rami)

Checks Underrättelser (IMPLEMENTATION.md §5.8, docs/contracts.md §C15, docs/modules/intel.md): sources with protected
identity, Hemlig reports with read logging, missions, the kontaktnotis for outsiders and the network graph. Eight
steps, about 30 minutes. You need **three players** on duty with a tablet: **S** = Span (`mdt_page:intel`,
`perm:intel.read`, `perm:intel.handler`, `intel_tier:2`), **U** = Utredning (`mdt_page:intel`, `perm:intel.read`,
`intel_tier:1`), **I** = IGV (tier 0, `mdt_page:search`, **no** `intel.read`).

Tick each step. If one fails, copy the F8 console and the txAdmin Live Console lines around it into the report.

## Before you start (once)

`scripts\build.ps1`, copy `resources\[fredpd]`, restart. Console: migration `007_intel.sql` applied once.

## Steps

### 1. Source with a protected identity ☐

S: Underrättelser → Källor → Ny källa, kodnamn "Korpen", tillförlitlighet B, verklig identitet = a character. S (the
handler) sees "Verklig identitet". U opens the source: "Identiteten är skyddad." SQL: `SELECT COUNT(*) FROM
fredpd_audit WHERE action = 'intel.source.identity';` grows by one each time S opens the identity.

### 2. Hemlig report: read logging ☐

S: Ny underrättelserapport from "Korpen", sekretessnivå **Hemlig**, about a person P. S sees "Din läsning loggas."
U (tier 1) cannot open it (not listed, or a kontaktnotis). Every open by S adds an `intel.report.read` audit row.

### 3. Mission Hemlig, members only ☐

S: Insatser → Ny insats, Hemlig, S as insatsledare. U (not a member) sees at most a kontaktnotis ("en insats").
S: Lägg till deltagare → U. U now opens it in full.

### 4. Outsiders get only a kontaktnotis ☐

I searches person P (Sök → person): the person page says there is information about P and whom to contact, but no
report text, no source, no mission name. I's tablet menu has no Underrättelser; on the portal `<portal>/intel`
answers "hittades inte".

### 5. Add a link in three clicks ☐

U: Objekt → P → Lägg till koppling → Till: a vehicle, Typ "Använder", Säkerhet → save: "Kopplingen är sparad." The
link shows on P's page and on the vehicle's page.

### 6. Hidden links are counted, not shown ☐

S adds a link from P to a group inside the Hemlig report. U on P's page sees "Kopplingar som är dolda för dig: 1",
not the group.

### 7. Network graph ☐

S: P → Nätverk. The graph draws once and then stays still (no endless animation); "Objekt: n · Kopplingar: m".
Select a node → Visa kopplingar expands it. With a big network the page says it shows at most 150 objects.

### 8. Idle cost ☐

F8 `resmon 1`: with the tablet closed `fredpd_mdt` and `fredpd_intel` stay at **0.00 ms**; after closing the graph
page nothing keeps running.
