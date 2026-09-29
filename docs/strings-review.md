<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Swedish strings review (task 8.2)

This page is for a native Swedish reader. It lists every Swedish string FredPD shows, grouped by area, so it can be
skimmed in one sitting. It also records what the 8.2 pass changed and what is still open.

- Source of truth: `locales/sv.json` (FredPD) and the Swedish locales that FredPD adds to upstream resources through
  `patches/evidences.30-sv-locale.patch`, `patches/qbx_policejob.40-sv-locale.patch` and
  `patches/qb-policejob.40-sv-locale.patch`.
- Reference: `docs/glossary.md` (terms and writing rules). The pass checked every string for: the same term for the
  same concept, du-form, sentence case, no anglicisms, punctuation and ellipsis, intact `{placeholders}` / `%s`,
  and short button labels.
- To suggest a change: note the key and the new text. FredPD keys go in `locales/sv.json` (and `locales/en.json`
  when the meaning changes); upstream keys go in the matching patch (regenerate it, never edit upstream).
- Before the pass, `locales/pending/portal-api.json` and `locales/pending/portal-ui.json` (14 keys) were merged with
  `node scripts/merge-pending-locales.mjs`.

## Changelog

### FredPD (`locales/sv.json`, `locales/en.json`)

| Key | Before | After | Why |
|---|---|---|---|
| `breach.noItem` | Du behöver en dörrkross. | Du behöver en murbräcka. | One item name (`pd_ram` is *murbräcka*). |
| `audit.flag.unauthorizedSearchNotify` | Möjlig obehörig sökning: {officer} har slagit på {count} personer utan koppling till sina ärenden. | Möjlig obehörig sökning av {officer}. Slagningar utan koppling till egna ärenden: {count}. | `{count}` before a plural noun. |
| `intel.entity.hiddenLinks` | {count} kopplingar är dolda för dig. | Kopplingar som är dolda för dig: {count} | Same plural rule. |
| `intel.graph.hint` | {nodes} objekt, {edges} kopplingar. Välj … | Objekt: {nodes} · Kopplingar: {edges}. Välj … | Same plural rule; middle dot. |
| `intel.graph.capped` | … Expandera ett objekt för att se fler. | … Välj ett objekt och sedan ”Visa kopplingar” för att se fler. | Names the real button, no anglicism. |
| `intel.graph.truncated` | … Välj ett objekt och Visa kopplingar för att se fler. | … Välj ett objekt och sedan ”Visa kopplingar” för att se fler. | Quote button names. |
| `dev.backfill.done` | …: {persons} personer och {vehicles} fordon. | Söktabellerna är uppdaterade. Personer: {persons} · Fordon: {vehicles} | Plural rule. |
| `dev.seed.done` | Testdata skapad: {persons} personer och {vehicles} fordon. | Testdata skapad. Personer: {persons} · Fordon: {vehicles} | Plural rule. |
| `dev.fakeunits.started` | {count} påhittade enheter körs i {seconds} sekunder. | Påhittade enheter: {count}. De körs i {seconds} s. | Plural rule. |
| `core.auditArchive.done` | {count} loggposter äldre än {days} dagar har flyttats till arkivet. | Loggposter äldre än {days} dagar har flyttats till arkivet. Antal: {count} | Plural rule (`{days}` is the allowed config exception). |
| `charge.ordningsbot.onlyHint` | … alla valda brott är ordningsbotsbrott. | … alla valda brott har påföljden ordningsbot. | Glossary term *påföljd*; no coined word. |
| `evidence.laptop.useOwnOption` | … eget alternativ, Använd laptop. | … eget alternativ, ”Använd laptop”. | Quote option names. |
| `evidence.link.pending` | … välj Koppla till ärende på den. | … välj ”Koppla till ärende” på den. | Quote option names. |
| `evidence.lockerDenied` | Bevisförrådet kräver att du är i tjänst och har behörighet till Bevis. | För att öppna bevisförrådet måste du vara i tjänst och ha behörighet till Bevis. | Du-form, clearer. |
| `tablet.issueNotAdded` | … spelarens förråd (fullt, eller föremålet saknas i inventoriet). … | Surfplattan fick inte plats hos spelaren, eller så saknas föremålet på servern. Registreringen är ångrad. | Mixed *förråd*/*inventoriet*; *förråd* means a station stash in the glossary. |
| `tablet.issueCannotCarry` | … Be personen frigöra plats. | … Be spelaren göra plats. | Same noun as the first sentence. |
| `tablet.field.issuedAt` / `issuedBy` | Utfärdad / Utfärdad av | Registrerad / Registrerad av | A tablet is *registrerad* (`tablet.issue` = Registrera surfplatta). |
| `audit.action.roles.sync` | Discord-roller synkade | Discord-roller synkroniserade | Informal word. |
| `audit.action.share.view` | Delad länk visad | Delningslänk visad | Glossary term *delningslänk*. |
| `case.action.reopen` | Återöppna | Återöppna ärendet | Matches Avsluta ärendet. |
| `person.action.addToCase` | Lägg i ärende | Lägg till i ärende | Idiomatic; matches Lägg till inblandad. |
| `portal.live.unitsAge` | Enhetslistan uppdaterades {time}. | Enhetslistan uppdaterades kl. {time}. | Times are written *kl. 14:05*. |
| `portal.audit.pending` | Granskningsvyn är inte klar än. Loggarna finns kvar … | Loggvyn är inte klar än. Loggposterna sparas … | The page is called Loggar. |
| `visibility.masked.badge` | Begränsad insyn | Delvis maskerat | Read like the level *Begränsad*; the NUI showed "Begränsad insyn Begränsad" side by side. |

English-only fixes in `locales/en.json`: fixed penalty wording (`charge.ordningsbot.onlyHint`,
`perms.perm.charges.fine` no longer say "on-the-spot fine"), `charge.totalJailMinutes` says "prison time" like
`charge.totalJail`, tablet texts say "registered" and avoid contractions, release errors say "refuse"/"reviewed"
like the decision labels, plus the English twins of the rows above.

Tests that asserted the old Swedish text were updated: `apps/nui/test/{cases,intel,person,search}.test.tsx`,
`apps/portal/test/portal.test.tsx`, `tests/lua/forensics_{client,server}_test.lua`.

### Upstream Swedish locales (patches regenerated from a fresh checkout)

| Resource | Change | Why |
|---|---|---|
| evidences | `…` with no space before it (Sök…, Laddar…, Jämför %s med registret…, Analyserar ballistiskt bevis…); "Inget att välja …" → "Inget att välja" | Ellipsis rule. |
| evidences | 27 "!" removed: status messages end with ".", headers ("Träff i registret") with nothing | No exclamation marks. |
| evidences | "Säkra kula" / "Ta bort kula" → "Säkra projektil" / "Ta bort projektil"; ballistics text says *projektil* | Glossary term, matches FredPD `evidence.type.projectile`. |
| evidences | Fingerprint match "(%s • %s)" → "(%s · %s)" | Middle dot. |
| evidences | "Det lyckades inte" → "Något gick fel" | Matches `errors.unknown`. |
| qbx_policejob + qb-policejob | " \| " → " · " in vehicle info, evidence stash, current evidence, officer down | Middle dot. |
| qbx_policejob + qb-policejob | "Du tog av fotbojan från …" → "… på …"; "Ta ut helikopter" → "Ta ut helikoptern"; "det högsta antal du får" → "det högsta antalet som du får" | Grammar / consistency. |
| qbx_policejob + qb-policejob | "Krutrester på kläderna" → "Krutstänk på kläderna" | Same term as evidences. |
| qbx_policejob + qb-policejob | citizen_id → "Karaktärens citizen-id" (was "Karaktärens citizenid" / "Personens citizenid") | Same text in both, matches `officer.citizenid`. |
| qbx_policejob | trash "Soptunna" → "Papperskorg" | Matches `menu.trash_stash` and qb-policejob. |
| qb-policejob | mr/mrs "Herr"/"Fru" → "herr"/"fru" | Used mid-sentence; matches qbx. |
| qb-policejob | impound texts: "Fordon i beslag" → "Bärgade fordon", "inga fordon i beslag" → "inga bärgade fordon", "uthämtat ur beslag" → "uthämtat från uppställningsplatsen", "[E] Ställ in fordonet på uppställningsplatsen" → "[E] Bärga fordonet" | *Bärgad* is the vehicle state; *beslag* is a legal seizure (glossary §6, §9). Matches qbx. |
| qb-policejob | "Serienumret går inte att läsa…" → no ellipsis | Not work in progress; matches qbx. |

`docs/glossary.md` gained: *krutstänk*, *laptop / bevislaptop*, *projektil* not *kula*, *Bärgade fordon /
uppställningsplats*, the *Delvis maskerat* badge, quoted option names, "no space before …", "· not | or •", the
`{days}` exception to the plural rule, and three new words to avoid (dörrkross, begränsad insyn, synka).

## Open questions

1. **`{days}` plurals.** `audit.retention`, `portal.privacy.retention` and `core.auditArchive.*` keep "{days} dagar".
   Retention is 90 by default and never 1 in practice, so the glossary now allows it. Alternative: "{days} dygn"
   (same form in singular and plural) at the cost of sounding less natural. Native reader to decide.
2. **`breach.noRam`** is not used by any code (the breach client uses `breach.noItem`). Keep or delete?
3. **`patches/ox_inventory.30-breach-items.patch`** describes the ram as "Tung dörrkross …". That patch is outside
   this task (item definitions, not a locale); suggest "Tung murbräcka för att forcera låsta dörrar. …".
4. **Periods in upstream notifications.** qbx_policejob and qb-policejob notifications have no final period (the
   upstream English style); FredPD's own strings end sentences with a period. Left as is, consistent per resource.
5. **"licens" in qbx/qb-policejob.** The police job says *licens / licenstyp* generically, while FredPD says
   *körkort och tillstånd*. The upstream command only grants driver/weapon licences, so *licens* was kept.
6. **"Citizen-id"** (`officer.citizenid`, police job citizen_id) is a Qbox concept with no Swedish name.
   Kept as a technical loan word; alternative "Karaktärs-id".
7. **`person.licence.revokeConfirm`** says "tillståndet" for both körkort and vapenlicens. A per-licence text would
   need a new placeholder; left as is.
8. **Code comments** in `apps/nui/src/components/CaseRefs.tsx`, `apps/nui/src/pages/PersonPage.tsx` and
   `docs/modules/ui.md` still quote the old texts "Begränsad insyn" and "Lägg i ärende" (outside this task's files).

## All Swedish strings

### FredPD (`locales/sv.json`)

#### Allmänt (common)

| Nyckel | Svenska |
|---|---|
| `common.actions` | Åtgärder |
| `common.add` | Lägg till |
| `common.all` | Alla |
| `common.back` | Tillbaka |
| `common.cancel` | Avbryt |
| `common.clear` | Rensa |
| `common.close` | Stäng |
| `common.comingPhase5` | Kommer i fas 5 |
| `common.confirm` | Bekräfta |
| `common.confirmDelete` | Vill du ta bort {name}? Det går inte att ångra. |
| `common.copied` | Kopierat |
| `common.copy` | Kopiera |
| `common.create` | Skapa |
| `common.createdAt` | Skapad |
| `common.createdBy` | Skapad av |
| `common.date` | Datum |
| `common.delete` | Ta bort |
| `common.description` | Beskrivning |
| `common.details` | Detaljer |
| `common.discardChanges` | Släng ändringarna |
| `common.edit` | Redigera |
| `common.empty` | Inget att visa. |
| `common.filter` | Filtrera |
| `common.hide` | Dölj |
| `common.loading` | Laddar… |
| `common.name` | Namn |
| `common.next` | Nästa |
| `common.no` | Nej |
| `common.notSet` | Ej angivet |
| `common.notes` | Anteckningar |
| `common.ok` | OK |
| `common.open` | Öppna |
| `common.optional` | Valfritt |
| `common.page` | Sida {page} av {pages} |
| `common.police` | Polisen |
| `common.previous` | Föregående |
| `common.print` | Skriv ut |
| `common.reason` | Anledning |
| `common.remove` | Ta bort |
| `common.required` | Obligatoriskt |
| `common.results` | Träffar: {count} |
| `common.retry` | Försök igen |
| `common.save` | Spara |
| `common.saved` | Sparat |
| `common.saving` | Sparar… |
| `common.search` | Sök |
| `common.share` | Dela |
| `common.show` | Visa |
| `common.showAll` | Visa alla |
| `common.showMore` | Visa fler |
| `common.status` | Status |
| `common.time` | Tid |
| `common.type` | Typ |
| `common.unknown` | Okänt |
| `common.unsavedChanges` | Du har osparade ändringar. Vill du lämna sidan ändå? |
| `common.updatedAt` | Uppdaterad |
| `common.yes` | Ja |

#### Meny (nav)

| Nyckel | Svenska |
|---|---|
| `nav.alerts` | Larm |
| `nav.audit` | Loggar |
| `nav.bolos` | Efterlysningar |
| `nav.cases` | Ärenden |
| `nav.chargeCatalog` | Brottskatalog |
| `nav.command` | Ledning |
| `nav.evidence` | Bevis |
| `nav.home` | Hem |
| `nav.intel` | Underrättelser |
| `nav.menu` | Meny |
| `nav.missions` | Insatser |
| `nav.permissions` | Behörigheter |
| `nav.releases` | Utlämnanden |
| `nav.reports` | Rapporter |
| `nav.roster` | Personal |
| `nav.search` | Sök |
| `nav.sources` | Källor |
| `nav.tablets` | Surfplattor |

#### Felmeddelanden (errors)

| Nyckel | Svenska |
|---|---|
| `errors.busy` | Vänta tills den pågående åtgärden är klar. |
| `errors.conflict` | Någon annan har ändrat uppgiften. Ladda om och försök igen. |
| `errors.csrf` | Sessionen är ogiltig. Ladda om sidan. |
| `errors.field.invalidCaseNumber` | Ogiltigt ärendenummer. Exempel: {example} |
| `errors.field.invalidNumber` | Ange ett giltigt tal. |
| `errors.field.invalidPersonId` | Ogiltigt personnummer. Exempel: {example} |
| `errors.field.invalidPlate` | Ogiltigt registreringsnummer. Exempel: {example} |
| `errors.field.required` | Fältet måste fyllas i. |
| `errors.field.tooLong` | Högst {max} tecken. |
| `errors.field.tooShort` | Minst {min} tecken. |
| `errors.network` | Kunde inte ansluta. Kontrollera anslutningen. |
| `errors.noCharacter` | Välj en karaktär först. |
| `errors.notFound` | Uppgiften hittades inte. |
| `errors.notOnDuty` | Du är inte i tjänst. |
| `errors.portalInGameOnly` | Det här går bara att göra i spelet. |
| `errors.rateLimited` | För många förfrågningar. Vänta en stund och försök igen. |
| `errors.serviceUnavailable` | Tjänsten är inte tillgänglig just nu. Försök igen om en stund. |
| `errors.tooFar` | Du är för långt bort. |
| `errors.unauthenticated` | Du är inte inloggad. |
| `errors.unauthorized` | Du har inte behörighet att göra det här. |
| `errors.unknown` | Något gick fel. Försök igen. |
| `errors.uploadTooLarge` | Filen är för stor. Högst {max} MB. |
| `errors.uploadType` | Filtypen stöds inte. Använd PNG, JPEG eller WebP. |
| `errors.validation` | Kontrollera de markerade fälten. |

#### Tid (time)

| Nyckel | Svenska |
|---|---|
| `time.at` | {date} kl. {time} |
| `time.daysAgo` | {count} d sedan |
| `time.duration.days` | {count} dygn |
| `time.duration.hours` | {count} tim |
| `time.duration.minutes` | {count} min |
| `time.expired` | Har gått ut |
| `time.expires` | Går ut {date} |
| `time.hoursAgo` | {count} tim sedan |
| `time.justNow` | Nyss |
| `time.minutesAgo` | {count} min sedan |
| `time.never` | Aldrig |
| `time.today` | I dag |
| `time.tomorrow` | I morgon |
| `time.validUntil` | Gäller till {date} |
| `time.yesterday` | I går |

#### Belopp (currency)

| Nyckel | Svenska |
|---|---|
| `currency.amount` | Belopp |
| `currency.unitName` | kronor |

#### Hem (home)

| Nyckel | Svenska |
|---|---|
| `home.activeBolos` | Aktiva efterlysningar |
| `home.activeMissions` | Pågående insatser |
| `home.empty` | Inget att visa just nu. |
| `home.evidenceQueue` | Bevis att analysera |
| `home.flaggedSearches` | Flaggade slagningar |
| `home.greeting` | Hej {name} |
| `home.myCases` | Mina ärenden |
| `home.myOpenCases` | Mina öppna ärenden |
| `home.onDutyAs` | I tjänst som {callsign} · {unit} |
| `home.openAlerts` | Öppna larm |
| `home.quickActions` | Snabbval |
| `home.recentLookups` | Mina senaste slagningar |
| `home.releaseQueue` | Begäranden att pröva |
| `home.unitCases` | Enhetens ärenden |
| `home.unitsOnDuty` | Enheter i tjänst |

#### Sökning (mdt.search)

| Nyckel | Svenska |
|---|---|
| `mdt.search.caseNotFound` | Inget ärende med nummer {number}. |
| `mdt.search.detected` | Sökning: {type} |
| `mdt.search.failed` | Sökningen misslyckades. Försök igen. |
| `mdt.search.group.cases` | Ärenden |
| `mdt.search.group.persons` | Personer |
| `mdt.search.group.vehicles` | Fordon |
| `mdt.search.hint` | Enter öppnar första träffen. |
| `mdt.search.keys` | ↑ ↓ väljer · Enter öppnar · Esc stänger |
| `mdt.search.logged` | Alla slagningar loggas. |
| `mdt.search.noResults` | Inga träffar på ”{query}”. |
| `mdt.search.personNotFound` | Ingen person med personnummer {personId}. |
| `mdt.search.placeholder` | Sök namn, personnummer, regnummer eller ärende |
| `mdt.search.plateNotFound` | Inget fordon med registreringsnummer {plate}. |
| `mdt.search.recent` | Senaste sökningar |
| `mdt.search.searching` | Söker… |
| `mdt.search.title` | Sökresultat |
| `mdt.search.tooShort` | Skriv minst {min} tecken. |
| `mdt.search.type.caseNumber` | Ärendenummer |
| `mdt.search.type.name` | Namn |
| `mdt.search.type.personId` | Personnummer |
| `mdt.search.type.plate` | Registreringsnummer |

#### Person (person)

| Nyckel | Svenska |
|---|---|
| `person.action.addToCase` | Lägg till i ärende |
| `person.action.bolo` | Efterlys |
| `person.action.newReport` | Ny rapport |
| `person.action.poiSheet` | POI-blad |
| `person.addedToCase` | {name} har lagts till i ärende {number}. |
| `person.field.address` | Adress |
| `person.field.birthdate` | Födelsedatum |
| `person.field.firstname` | Förnamn |
| `person.field.gender` | Kön |
| `person.field.lastname` | Efternamn |
| `person.field.name` | Namn |
| `person.field.nationality` | Medborgarskap |
| `person.field.personId` | Personnummer |
| `person.field.phone` | Telefon |
| `person.field.photo` | Foto |
| `person.gender.female` | Kvinna |
| `person.gender.male` | Man |
| `person.gender.unknown` | Okänt |
| `person.licence.driver` | Körkort |
| `person.licence.revoke` | Återkalla |
| `person.licence.revokeConfirm` | Återkalla tillståndet för {name}? Återkallelsen loggas. |
| `person.licence.revoked` | Tillståndet är återkallat. |
| `person.licence.status.driver.revoked` | Återkallat |
| `person.licence.status.driver.valid` | Giltigt |
| `person.licence.status.none` | Saknas |
| `person.licence.status.weapon.revoked` | Återkallad |
| `person.licence.status.weapon.valid` | Giltig |
| `person.licence.warn` | Meddela varning |
| `person.licence.warned` | Varning meddelad {date} |
| `person.licence.warningCount` | Varningar: {count} |
| `person.licence.weapon` | Vapenlicens |
| `person.noCases` | Förekommer inte i några ärenden. |
| `person.noRecords` | Inga belastningar. |
| `person.noVehicles` | Inga registrerade fordon. |
| `person.notFound` | Personen hittades inte. |
| `person.section.bolos` | Efterlysningar |
| `person.section.cases` | Ärenden |
| `person.section.licences` | Körkort och tillstånd |
| `person.section.records` | Belastningsregister |
| `person.section.reports` | Rapporter |
| `person.section.vehicles` | Fordon |
| `person.title` | Person |
| `person.wanted` | Efterlyst |

#### Fordon (vehicle)

| Nyckel | Svenska |
|---|---|
| `vehicle.check` | Kontrollera |
| `vehicle.checkClear` | Ingen träff |
| `vehicle.checkHistory` | Kontrollhistorik |
| `vehicle.checkHit` | Träff |
| `vehicle.checkedBy` | Kontrollerad av {name} |
| `vehicle.field.model` | Modell |
| `vehicle.field.owner` | Ägare |
| `vehicle.field.plate` | Registreringsnummer |
| `vehicle.field.state` | Status |
| `vehicle.noCases` | Inga kopplade ärenden. |
| `vehicle.noChecks` | Fordonet har inte kontrollerats. |
| `vehicle.notFound` | Fordonet hittades inte. |
| `vehicle.notRegistered` | Fordonet finns inte i registret. |
| `vehicle.ownerUnknown` | Ägare saknas i registret |
| `vehicle.section.cases` | Kopplade ärenden |
| `vehicle.state.garaged` | I garage |
| `vehicle.state.impounded` | Bärgad |
| `vehicle.state.out` | Ute |
| `vehicle.title` | Fordon |
| `vehicle.wanted` | Efterlyst fordon |

#### Larm (alert)

| Nyckel | Svenska |
|---|---|
| `alert.action.close` | Avsluta larmet |
| `alert.action.leave` | Lämna larmet |
| `alert.action.take` | Ta larmet |
| `alert.action.waypoint` | Sätt vägpunkt |
| `alert.alreadyAssigned` | Du är redan tilldelad larmet. |
| `alert.assigned` | Tilldelad: {callsign} · {name} |
| `alert.assignedNoCallsign` | Tilldelad: {name} |
| `alert.assignedSelf` | Du har tagit larmet. Vägpunkten är satt. |
| `alert.assignedSelfNoWaypoint` | Du har tagit larmet. |
| `alert.closed` | Larmet är avslutat. |
| `alert.closedBy` | Avslutat av {name} |
| `alert.detail.area` | Ungefärlig plats (inom {radius} m) |
| `alert.detail.caller` | Inringare: {value} |
| `alert.detail.vehicle` | Fordon: {value} |
| `alert.detail.weapon` | Vapen: {value} |
| `alert.field.code` | Kod |
| `alert.field.location` | Plats |
| `alert.field.origin` | Ursprung |
| `alert.field.priority` | Prioritet |
| `alert.field.receivedAt` | Inkom |
| `alert.field.units` | Enheter |
| `alert.filter.all` | Alla |
| `alert.filter.mine` | Mina |
| `alert.filter.open` | Öppna |
| `alert.keybind.take` | Ta larm |
| `alert.left` | Du har lämnat larmet. |
| `alert.noOpen` | Inga öppna larm. |
| `alert.priority.high` | Hög |
| `alert.priority.low` | Låg |
| `alert.priority.normal` | Normal |
| `alert.status.assigned` | Tilldelat |
| `alert.status.closed` | Avslutat |
| `alert.status.open` | Öppet |
| `alert.title` | Larm |
| `alert.toast.body` | {code} {title} · {street} |
| `alert.toast.bodyNoStreet` | {code} {title} |
| `alert.toast.hint` | Tryck {key} för att ta larmet |
| `alert.toast.title` | Nytt larm |
| `alert.unassigned` | Ej tilldelat |
| `alert.unit.busy` | På larm |
| `alert.unit.free` | Ledig |
| `alert.unitCount` | Enheter: {count} |

#### Efterlysningar (bolo)

| Nyckel | Svenska |
|---|---|
| `bolo.checkPlate.clear` | {plate}: ingen aktiv efterlysning. |
| `bolo.checkPlate.header` | Skyltkontroll: {plate} |
| `bolo.checkPlate.model` | Modell: {model} |
| `bolo.checkPlate.noPlate` | Fordonet saknar läsbar skylt. |
| `bolo.checkPlate.owner` | Ägare: {name} |
| `bolo.checkPlate.target` | Kontrollera registreringsskylt |
| `bolo.checkPlate.title` | Skyltkontroll |
| `bolo.checkPlate.unregistered` | {plate}: fordonet finns inte i registret. |
| `bolo.create.changeSubject` | Byt |
| `bolo.create.duplicate` | Det finns redan en aktiv efterlysning på {subject}. |
| `bolo.create.levelTooHigh` | Du kan inte utfärda en efterlysning med högre sekretessnivå än din egen. |
| `bolo.create.searchPerson` | Sök namn eller personnummer |
| `bolo.create.searchVehicle` | Sök registreringsnummer |
| `bolo.create.subjectNotFound` | Personen eller fordonet finns inte i registret. |
| `bolo.create.subjectRequired` | Välj en person eller ett fordon. |
| `bolo.create.submit` | Efterlys |
| `bolo.create.success` | Efterlysningen är utfärdad. |
| `bolo.create.title` | Ny efterlysning |
| `bolo.expiry.none` | Ingen slutdag |
| `bolo.field.duration` | Giltighetstid |
| `bolo.field.expiresAt` | Gäller till |
| `bolo.field.issuedBy` | Utfärdad av |
| `bolo.field.kind` | Typ |
| `bolo.field.level` | Sekretessnivå |
| `bolo.field.person` | Person |
| `bolo.field.plate` | Registreringsnummer |
| `bolo.field.reason` | Anledning |
| `bolo.field.resolvedBy` | Återkallad av |
| `bolo.field.subject` | Avser |
| `bolo.filter.active` | Aktiva |
| `bolo.filter.all` | Alla |
| `bolo.hit.alertCode` | Efterlyst |
| `bolo.hit.alertTitle` | Efterlyst fordon: {plate} |
| `bolo.hit.alertTitlePerson` | Efterlyst person: {name} |
| `bolo.hit.garageParked` | {plate} parkerades i {garage}. |
| `bolo.hit.garageTakenOut` | {plate} hämtades ut från {garage}. |
| `bolo.hit.person` | {name} är efterlyst: {reason} |
| `bolo.hit.plate` | {plate} är efterlyst: {reason} |
| `bolo.hit.source.check` | Skyltkontroll |
| `bolo.hit.source.garage` | Garage |
| `bolo.hit.source.impound` | Bärgning |
| `bolo.hit.source.radar` | ANPR-kamera |
| `bolo.hit.title` | Träff på efterlysning |
| `bolo.hit.unitsNotified` | Tjänstgörande enheter har larmats. |
| `bolo.hit.via` | Källa: {source} |
| `bolo.kind.person` | Person |
| `bolo.kind.vehicle` | Fordon |
| `bolo.none` | Inga aktiva efterlysningar. |
| `bolo.notice.owner` | {name} ({callsign}) |
| `bolo.resolve.autoImpound` | Återkallad automatiskt: fordonet bärgades. |
| `bolo.resolve.button` | Återkalla efterlysning |
| `bolo.resolve.confirm` | Återkalla efterlysningen på {subject}? |
| `bolo.resolve.note` | Kommentar (t.ex. var och när) |
| `bolo.resolve.success` | Efterlysningen är återkallad. |
| `bolo.status.active` | Aktiv |
| `bolo.status.expired` | Utgången |
| `bolo.status.resolved` | Återkallad |
| `bolo.subject.vehicle` | {plate} · {model} |
| `bolo.title` | Efterlysningar |

#### Ärenden (case)

| Nyckel | Svenska |
|---|---|
| `case.action.addAssignee` | Lägg till handläggare |
| `case.action.addSubject` | Lägg till inblandad |
| `case.action.close` | Avsluta ärendet |
| `case.action.linkEvidence` | Koppla bevis |
| `case.action.newReport` | Ny rapport |
| `case.action.removeAssignee` | Ta bort handläggare |
| `case.action.reopen` | Återöppna ärendet |
| `case.assignedToYou` | Du har tilldelats ärende {number}. |
| `case.assignee.role.lead` | Ansvarig handläggare |
| `case.assignee.role.member` | Handläggare |
| `case.close.confirm` | Avsluta ärende {number}? Sekretessnivån ligger kvar efter avslut. |
| `case.closed` | Ärende {number} är avslutat. |
| `case.create.success` | Ärende {number} är upprättat. |
| `case.create.title` | Nytt ärende |
| `case.field.assignees` | Handläggare |
| `case.field.createdBy` | Upprättat av |
| `case.field.level` | Sekretessnivå |
| `case.field.number` | Ärendenummer |
| `case.field.resolution` | Avslutsanteckning |
| `case.field.status` | Status |
| `case.field.subjects` | Inblandade |
| `case.field.summary` | Sammanfattning |
| `case.field.title` | Rubrik |
| `case.field.unit` | Ansvarig enhet |
| `case.filter.all` | Alla |
| `case.filter.closed` | Avslutade |
| `case.filter.mine` | Mina |
| `case.filter.open` | Öppna |
| `case.filter.unit` | Enhetens |
| `case.mine` | Mina ärenden |
| `case.none` | Inga ärenden. |
| `case.notFound` | Ärendet hittades inte. |
| `case.notice.subject` | ett ärende |
| `case.reopened` | Ärende {number} är återöppnat. |
| `case.search` | Sök ärendenummer eller rubrik |
| `case.section.evidence` | Bevis |
| `case.section.reports` | Rapporter |
| `case.section.timeline` | Händelser |
| `case.status.closed` | Avslutat |
| `case.status.open` | Öppet |
| `case.subject.person` | Person |
| `case.subject.role.other` | Övrig |
| `case.subject.role.suspect` | Misstänkt |
| `case.subject.role.victim` | Målsägande |
| `case.subject.role.witness` | Vittne |
| `case.subject.roleLabel` | Roll |
| `case.subject.vehicle` | Fordon |
| `case.timeline.assigned` | {name} tilldelades ärendet |
| `case.timeline.closed` | {name} avslutade ärendet |
| `case.timeline.created` | {name} upprättade ärendet |
| `case.timeline.evidenceLinked` | Bevis {tag} kopplades till ärendet |
| `case.timeline.reopened` | {name} återöppnade ärendet |
| `case.timeline.reportAdded` | {name} registrerade rapport {number} |
| `case.timeline.subjectAdded` | {subject} lades till som inblandad |
| `case.title` | Ärenden |

#### Rapporter (report)

| Nyckel | Svenska |
|---|---|
| `report.draft.available` | Det finns ett osparat utkast från {time} som är nyare än rapporten. |
| `report.draft.discard` | Släng utkastet |
| `report.draft.label` | Utkast |
| `report.draft.restore` | Återställ utkast |
| `report.draft.restored` | Ett sparat utkast har återställts. |
| `report.draft.saved` | Utkast sparat kl. {time} |
| `report.draft.saving` | Sparar utkast… |
| `report.empty` | Rapporten är tom. |
| `report.field.author` | Upprättad av |
| `report.field.body` | Rapporttext |
| `report.field.case` | Ärende |
| `report.field.number` | Rapportnummer |
| `report.field.template` | Mall |
| `report.field.title` | Rubrik |
| `report.kind.anmalan` | Anmälan |
| `report.kind.pm` | PM |
| `report.kind.rapport` | Rapport |
| `report.new` | Ny rapport |
| `report.none` | Inga rapporter. |
| `report.notFound` | Rapporten hittades inte. |
| `report.preview` | Förhandsvisning |
| `report.submit` | Registrera rapport |
| `report.submitted` | Rapport {number} är registrerad. |
| `report.template.choose` | Välj mall |
| `report.template.none` | Ingen mall |
| `report.title` | Rapporter |
| `report.toolbar.bold` | Fetstil |
| `report.toolbar.heading` | Rubrik |
| `report.toolbar.list` | Punktlista |

#### Brottskatalog och påföljder (charge)

| Nyckel | Svenska |
|---|---|
| `charge.add` | Lägg till brott |
| `charge.applied` | Brotten är registrerade på rapporten. |
| `charge.apply` | Registrera brott |
| `charge.category.narcotics` | Narkotika |
| `charge.category.other` | Övrigt |
| `charge.category.penal` | Brottsbalken |
| `charge.category.public_order` | Allmän ordning |
| `charge.category.traffic` | Trafik |
| `charge.category.weapons` | Vapen |
| `charge.class.bot` | Böter |
| `charge.class.fangelse` | Fängelse |
| `charge.class.ordningsbot` | Ordningsbot |
| `charge.field.category` | Kategori |
| `charge.field.class` | Påföljd |
| `charge.field.code` | Kod |
| `charge.field.count` | Antal |
| `charge.field.fine` | Bötesbelopp |
| `charge.field.jail` | Fängelse |
| `charge.field.lawRef` | Lagrum |
| `charge.field.status` | Status |
| `charge.field.title` | Brott |
| `charge.jailMonths` | {count} mån |
| `charge.noResults` | Inga brott matchar ”{query}”. |
| `charge.none` | Inga brott valda. |
| `charge.ordningsbot.confirm` | Utfärda ordningsbot på {amount} till {name}? |
| `charge.ordningsbot.issue` | Utfärda ordningsbot |
| `charge.ordningsbot.issued` | Ordningsbot på {amount} utfärdad till {name}. |
| `charge.ordningsbot.onlyHint` | Ordningsbot kan bara utfärdas när alla valda brott har påföljden ordningsbot. |
| `charge.ordningsbot.received` | Du har fått en ordningsbot på {amount}. |
| `charge.person` | Person |
| `charge.sanction.revocation` | Återkallelse |
| `charge.sanction.strafforelaggande` | Strafföreläggande |
| `charge.sanction.warning` | Varning |
| `charge.search` | Sök brott eller lagrum |
| `charge.status.issued` | Utfärdad |
| `charge.status.paid` | Betald |
| `charge.status.revoked` | Återkallad |
| `charge.status.served` | Avtjänad |
| `charge.title` | Brottskatalog |
| `charge.totalFine` | Totalt bötesbelopp: {amount} |
| `charge.totalJail` | Total fängelsetid: {count} mån |
| `charge.totalJailMinutes` | Total fängelsetid: {count} min |

#### Fängelse (prison)

| Nyckel | Svenska |
|---|---|
| `prison.notify.released` | Du har släppts från fängelset. |
| `prison.notify.timeChanged` | Din strafftid är nu {count} min. |

#### Bevis (evidence)

| Nyckel | Svenska |
|---|---|
| `evidence.action.openLocker` | Öppna bevisförrådet |
| `evidence.analyse` | Analysera |
| `evidence.analysed` | Analysen är klar. |
| `evidence.chain.analysed` | Analyserat av {name} |
| `evidence.chain.checkedOut` | Uttaget av {name} ur {location} |
| `evidence.chain.collected` | Säkrat av {name} |
| `evidence.chain.handedIn` | Inlämnat av {name} till bevisförrådet |
| `evidence.chain.handedOver` | Överlämnat till {name} |
| `evidence.chain.linked` | Kopplat av {name} till ärende {number} |
| `evidence.chain.returned` | Återlämnat av {name} till {location} |
| `evidence.chain.transferred` | Flyttat av {name} till {location} |
| `evidence.field.case` | Ärende |
| `evidence.field.chain` | Beviskedja |
| `evidence.field.collectedAt` | Säkrat |
| `evidence.field.collectedBy` | Säkrat av |
| `evidence.field.location` | Plats |
| `evidence.field.result` | Analysresultat |
| `evidence.field.tag` | Bevisnummer |
| `evidence.field.type` | Typ |
| `evidence.lab` | Kriminaltekniskt labb |
| `evidence.laptop.unavailable` | Bevislaptopen är inte tillgänglig just nu. |
| `evidence.laptop.useOwnOption` | Öppna laptopen med dess eget alternativ, ”Använd laptop”. |
| `evidence.link.action` | Koppla till ärende |
| `evidence.link.alreadyLinked` | Beviset är redan kopplat till ett ärende. |
| `evidence.link.caseClosed` | Ärendet är avslutat. Bevis kan bara kopplas till öppna ärenden. |
| `evidence.link.caseNoAccess` | Du har inte full åtkomst till ärendet och kan inte koppla bevis till det. |
| `evidence.link.caseNotFound` | Ärendet hittades inte. |
| `evidence.link.caseNumber` | Ärendenummer |
| `evidence.link.dialogHint` | {type} #{id}. Ange ärendenumret som beviset ska kopplas till. |
| `evidence.link.evidenceNotFound` | Beviset hittades inte. |
| `evidence.link.offerLabel` | {type} #{id} |
| `evidence.link.pending` | Beviset är analyserat. Stäng laptopen och välj ”Koppla till ärende” på den. |
| `evidence.link.success` | Bevis {tag} är kopplat till ärende {number}. |
| `evidence.locker` | Bevisförråd |
| `evidence.lockerDenied` | För att öppna bevisförrådet måste du vara i tjänst och ha behörighet till Bevis. |
| `evidence.match` | Träff: {name} |
| `evidence.noMatch` | Ingen träff i registret. |
| `evidence.none` | Inga bevis. |
| `evidence.notAnalysed` | Inte analyserat än. |
| `evidence.result.analysedAt` | Analyserat |
| `evidence.result.collectionTime` | Säkringstid |
| `evidence.result.crimeScene` | Brottsplats |
| `evidence.result.dna` | DNA-profil |
| `evidence.result.fingerprint` | Fingeravtryck |
| `evidence.result.kind` | Slag |
| `evidence.result.note` | Anteckning |
| `evidence.result.serial` | Serienummer |
| `evidence.result.weaponType` | Vapentyp |
| `evidence.tab.queue` | Att koppla |
| `evidence.title` | Bevis |
| `evidence.type.blood` | Blod |
| `evidence.type.casing` | Hylsa |
| `evidence.type.dna` | DNA |
| `evidence.type.fiber` | Fiber |
| `evidence.type.fingerprint` | Fingeravtryck |
| `evidence.type.other` | Övrigt |
| `evidence.type.photo` | Foto |
| `evidence.type.projectile` | Projektil |
| `evidence.type.toolmark` | Verktygsspår |
| `evidence.unavailable` | Bevishantering är inte aktiverad på den här servern (kräver ox_inventory, ox_target och evidences). |

#### Underrättelser (intel)

| Nyckel | Svenska |
|---|---|
| `intel.entity.create` | Skapa nytt objekt |
| `intel.entity.hiddenLinks` | Kopplingar som är dolda för dig: {count} |
| `intel.entity.search` | Sök person, fordon, plats eller gruppering |
| `intel.entity.type.case` | Ärende |
| `intel.entity.type.group` | Gruppering |
| `intel.entity.type.location` | Plats |
| `intel.entity.type.person` | Person |
| `intel.entity.type.vehicle` | Fordon |
| `intel.graph.capped` | Visar {shown} av {total} objekt. Välj ett objekt och sedan ”Visa kopplingar” för att se fler. |
| `intel.graph.expand` | Visa kopplingar |
| `intel.graph.hint` | Objekt: {nodes} · Kopplingar: {edges}. Välj ett objekt för att visa dess kopplingar. |
| `intel.graph.loading` | Laddar nätverk… |
| `intel.graph.truncated` | Nätverket visar högst {max} objekt. Välj ett objekt och sedan ”Visa kopplingar” för att se fler. |
| `intel.link.add` | Lägg till koppling |
| `intel.link.added` | Kopplingen är sparad. |
| `intel.link.confidence` | Säkerhet |
| `intel.link.from` | Från |
| `intel.link.to` | Till |
| `intel.link.typeLabel` | Typ av koppling |
| `intel.linkType.associate` | Umgås med |
| `intel.linkType.member_of` | Medlem i |
| `intel.linkType.owns` | Äger |
| `intel.linkType.related` | Kopplad till |
| `intel.linkType.seen_at` | Sedd vid |
| `intel.linkType.uses` | Använder |
| `intel.mission.addMember` | Lägg till deltagare |
| `intel.mission.close` | Avsluta insatsen |
| `intel.mission.lead` | Insatsledare |
| `intel.mission.members` | Deltagare |
| `intel.mission.name` | Insatsnamn |
| `intel.mission.new` | Ny insats |
| `intel.mission.status.closed` | Avslutad |
| `intel.mission.status.open` | Pågående |
| `intel.none` | Inga underrättelser. |
| `intel.notice.mission` | en insats |
| `intel.notice.report` | en underrättelserapport |
| `intel.notice.source` | en källa |
| `intel.reliability.a` | A – Alltid tillförlitlig |
| `intel.reliability.b` | B – Oftast tillförlitlig |
| `intel.reliability.c` | C – Ibland tillförlitlig |
| `intel.reliability.d` | D – Otillförlitlig eller oprövad |
| `intel.report.author` | Upprättad av |
| `intel.report.body` | Innehåll |
| `intel.report.new` | Ny underrättelserapport |
| `intel.report.readLogged` | Din läsning loggas. |
| `intel.report.source` | Källa |
| `intel.report.status.closed` | Avslutad |
| `intel.report.status.open` | Aktiv |
| `intel.section.entities` | Objekt |
| `intel.section.graph` | Nätverk |
| `intel.section.links` | Kopplingar |
| `intel.section.missions` | Insatser |
| `intel.section.reports` | Rapporter |
| `intel.section.sources` | Källor |
| `intel.source.codename` | Kodnamn |
| `intel.source.handler` | Källhanterare |
| `intel.source.identityHidden` | Identiteten är skyddad. |
| `intel.source.new` | Ny källa |
| `intel.source.realIdentity` | Verklig identitet |
| `intel.source.reliability` | Tillförlitlighet |
| `intel.source.status.closed` | Avregistrerad |
| `intel.source.status.open` | Aktiv |
| `intel.title` | Underrättelser |

#### Sekretessnivåer (level)

| Nyckel | Svenska |
|---|---|
| `level.begransad` | Begränsad |
| `level.hemlig` | Hemlig |
| `level.hint.begransad` | Kräver nivå Begränsad eller Hemlig. Andra ser högst en kontaktnotis. |
| `level.hint.hemlig` | Kräver nivå Hemlig. Andra ser högst en kontaktnotis. |
| `level.hint.standard` | Ingen särskild sekretessnivå krävs. |
| `level.label` | Sekretessnivå |
| `level.standard` | Standard |

#### Synlighet (visibility)

| Nyckel | Svenska |
|---|---|
| `visibility.condition.any` | Alla |
| `visibility.condition.assigned` | Tilldelad |
| `visibility.condition.handler` | Källhanterare |
| `visibility.condition.perm` | Behörighet |
| `visibility.condition.tier_gte` | Tillräcklig sekretessnivå |
| `visibility.condition.unit` | Enhet |
| `visibility.masked.badge` | Delvis maskerat |
| `visibility.masked.placeholder` | [Maskerat] |
| `visibility.masked.reason` | Kräver sekretessnivå {level}. |
| `visibility.masked.text` | Delar av innehållet är maskerade. |
| `visibility.notice.owner` | {name} ({unit}) |
| `visibility.notice.text` | Det finns uppgifter som rör {subject}. Kontakta {owner}. |
| `visibility.notice.textCommand` | Det finns uppgifter som rör {subject}. Kontakta ledningen. |
| `visibility.notice.title` | Kontaktnotis |
| `visibility.result.full` | Full insyn |
| `visibility.result.masked` | Maskerad |
| `visibility.result.none` | Dold |
| `visibility.result.notice` | Kontaktnotis |

#### POI-blad (poi)

| Nyckel | Svenska |
|---|---|
| `poi.confidential` | Internt – får inte spridas |
| `poi.handler` | Handläggare |
| `poi.none` | Det finns inget POI-blad för {name}. |
| `poi.printedBy` | Utskrivet {date} av {name} |
| `poi.section.associates` | Kända kopplingar |
| `poi.section.officerSafety` | Säkerhetsinformation |
| `poi.section.summary` | Sammanfattning |
| `poi.title` | POI-blad |
| `poi.warning.armed` | Beväpnad |
| `poi.warning.flight_risk` | Rymningsbenägen |
| `poi.warning.gang` | Kopplad till kriminellt nätverk |
| `poi.warning.violent` | Våldsbenägen |

#### Allmän handling (release)

| Nyckel | Svenska |
|---|---|
| `release.decided` | Beslutet är registrerat. |
| `release.decision.deny` | Avslå |
| `release.decision.release` | Lämna ut |
| `release.decision.releaseMasked` | Lämna ut med maskering |
| `release.error.alreadyDecided` | Begäran är redan prövad. |
| `release.error.noTarget` | Välj vilket ärende som ska lämnas ut. |
| `release.error.nothingReleasable` | Det finns inget i handlingen som kan lämnas ut. Avslå begäran i stället. |
| `release.field.decidedBy` | Prövad av |
| `release.field.description` | Vad vill du ta del av? |
| `release.field.grounds` | Motivering |
| `release.field.reference` | Ärende- eller rapportnummer (om du vet det) |
| `release.field.requester` | Sökande |
| `release.field.target` | Handling som lämnas ut |
| `release.intro` | Du har rätt att ta del av allmänna handlingar. Uppgifter som omfattas av sekretess maskeras. |
| `release.masked` | Uppgifter har maskerats med stöd av offentlighets- och sekretesslagen. |
| `release.none` | Inga begäranden. |
| `release.notFound` | Handlingen hittades inte. |
| `release.notify.decided` | Beslut om din begäran: {status} |
| `release.queue` | Begäranden att pröva |
| `release.status.approved` | Beviljad |
| `release.status.denied` | Avslagen |
| `release.status.partial` | Delvis beviljad |
| `release.status.pending` | Under prövning |
| `release.submit` | Skicka begäran |
| `release.submitted` | Din begäran är mottagen. Du får besked när den har prövats. |
| `release.target` | Begär ut allmän handling |
| `release.title` | Begär ut allmän handling |

#### Personal och tjänst (officer)

| Nyckel | Svenska |
|---|---|
| `officer.callsign` | Anropssignal |
| `officer.callsignAssigned` | Du har fått anropssignalen {callsign}. |
| `officer.callsignInvalid` | Ogiltig anropssignal. Exempel: {example} |
| `officer.callsignTaken` | Anropssignalen {callsign} är upptagen. |
| `officer.callsignUpdated` | Anropssignalen är ändrad till {callsign}. |
| `officer.citizenid` | Citizen-id |
| `officer.count` | I tjänst: {count} |
| `officer.dutyEnded` | Du har gått ur tjänst. |
| `officer.dutyStarted` | Du är i tjänst som {callsign}. |
| `officer.editCallsign` | Ändra anropssignal |
| `officer.handler` | Handläggare |
| `officer.lastSeen` | Senast i tjänst {date} |
| `officer.name` | Namn |
| `officer.none` | Inga poliser i tjänst. |
| `officer.offDuty` | Ej i tjänst |
| `officer.onDuty` | I tjänst |
| `officer.pick` | Polis i tjänst |
| `officer.rank` | Tjänstegrad |
| `officer.roster` | Tjänstgörande personal |
| `officer.status.available` | Tillgänglig |
| `officer.status.busy` | Upptagen |
| `officer.status.enRoute` | På väg |
| `officer.status.onScene` | På plats |
| `officer.unit` | Enhet |
| `officer.unnamed` | Polis utan namn (…{id}) |

#### Enheter (unit)

| Nyckel | Svenska |
|---|---|
| `unit.igv` | Ingripande |
| `unit.label` | Enhet |
| `unit.ledning` | Ledning |
| `unit.none` | Ingen enhet |
| `unit.primary` | Huvudenhet |
| `unit.span` | Spaning |
| `unit.tekniker` | Kriminalteknik |
| `unit.utredning` | Utredning |

#### Surfplattor (tablet)

| Nyckel | Svenska |
|---|---|
| `tablet.close` | Stäng surfplattan |
| `tablet.field.issuedAt` | Registrerad |
| `tablet.field.issuedBy` | Registrerad av |
| `tablet.field.owner` | Innehavare |
| `tablet.field.serial` | Serienummer |
| `tablet.issue` | Registrera surfplatta |
| `tablet.issueCannotCarry` | Spelaren kan inte bära surfplattan. Be spelaren göra plats. |
| `tablet.issueFailed` | Surfplattan kunde inte registreras. Försök igen. |
| `tablet.issueNoCharacter` | Spelaren har ingen karaktär inläst. |
| `tablet.issueNotAdded` | Surfplattan fick inte plats hos spelaren, eller så saknas föremålet på servern. Registreringen är ångrad. |
| `tablet.issueTarget` | Spelarens server-ID |
| `tablet.issued` | Surfplatta {serial} är registrerad på {name}. |
| `tablet.itemLabel` | Surfplatta (polis) |
| `tablet.itemSerial` | Serienummer: {serial} |
| `tablet.noGrant` | Du har inte behörighet att använda surfplattan. |
| `tablet.noItem` | Du har ingen surfplatta. |
| `tablet.none` | Inga registrerade surfplattor. |
| `tablet.notOnDuty` | Du måste vara i tjänst för att använda surfplattan. |
| `tablet.notOwner` | Surfplattan är registrerad på någon annan. |
| `tablet.open` | Öppna surfplattan |
| `tablet.received` | Du har fått surfplatta {serial}. |
| `tablet.reinstate` | Häv spärren |
| `tablet.reinstatedNotice` | Spärren för surfplatta {serial} är hävd. |
| `tablet.revoke` | Spärra |
| `tablet.revokeConfirm` | Spärra surfplatta {serial}? Den slutar fungera direkt. |
| `tablet.revoked` | Surfplattan är spärrad. Kontakta ledningen. |
| `tablet.revokedNotice` | Surfplatta {serial} är spärrad. |
| `tablet.status.active` | Aktiv |
| `tablet.status.revoked` | Spärrad |
| `tablet.title` | Surfplattor |
| `tablet.unavailable` | Du kan inte använda surfplattan just nu. |
| `tablet.unregistered` | Surfplattan är inte registrerad. Kontakta ledningen. |
| `tablet.useTerminal` | Använd fordonsdatorn |
| `tablet.vehicleTerminal` | Fordonsdator |

#### Dörrforcering (breach)

| Nyckel | Svenska |
|---|---|
| `breach.cancelled` | Dörrforceringen avbröts. |
| `breach.cooldown` | Vänta en stund innan du forcerar nästa dörr. |
| `breach.expired` | Forceringen tog för lång tid. Försök igen. |
| `breach.itemLabel` | Murbräcka |
| `breach.noGrant` | Du har inte behörighet att forcera dörrar. |
| `breach.noItem` | Du behöver en murbräcka. |
| `breach.noRam` | Du behöver en murbräcka. |
| `breach.notLocked` | Dörren är redan olåst. |
| `breach.notSupported` | Dörren kan inte forceras. |
| `breach.progress` | Forcerar dörren… |
| `breach.success` | Dörren är forcerad. |
| `breach.target` | Forcera dörr |
| `breach.tooFar` | Du står för långt från dörren. |

#### Behörigheter (perms)

| Nyckel | Svenska |
|---|---|
| `perms.addKey` | Lägg till kolumn |
| `perms.csrfRetry` | Sessionen förnyades. Försök spara igen. |
| `perms.effect.allow` | Tillåt |
| `perms.effect.deny` | Neka |
| `perms.effect.unset` | Ej satt |
| `perms.filter` | Filtrera roller |
| `perms.intro` | Koppla Discord-roller till behörigheter. Neka går alltid före Tillåt. |
| `perms.newKey` | Ny nyckel |
| `perms.noRoles` | Inga roller har importerats. Kontrollera att boten är ansluten. |
| `perms.perm.admin.permissions` | Hantera behörigheter |
| `perms.perm.alerts.manage` | Hantera alla larm |
| `perms.perm.bolo.create` | Utfärda efterlysningar |
| `perms.perm.bolo.resolve` | Återkalla efterlysningar |
| `perms.perm.cases.create` | Upprätta ärenden |
| `perms.perm.charges.apply` | Registrera brott |
| `perms.perm.charges.fine` | Utfärda ordningsbot |
| `perms.perm.evidence.link` | Koppla bevis till ärenden |
| `perms.perm.intel.command` | Underrättelseledning |
| `perms.perm.intel.handler` | Källhanterare |
| `perms.perm.intel.read` | Läsa underrättelser |
| `perms.perm.records.admin` | Registeradministration |
| `perms.perm.tablets.manage` | Hantera surfplattor |
| `perms.rank` | Tjänstegrad |
| `perms.role` | Roll |
| `perms.roleDeleted` | Rollen finns inte längre i Discord. |
| `perms.save` | Spara ändringar |
| `perms.saved` | Behörigheterna är sparade. Uppdaterade spelare: {count} |
| `perms.title` | Behörigheter |
| `perms.tool.ram` | Murbräcka |
| `perms.type.armory` | Vapenförråd |
| `perms.type.intel_tier` | Sekretessnivå |
| `perms.type.mdt_page` | MDT-sidor |
| `perms.type.perm` | Särskilda behörigheter |
| `perms.type.tool` | Verktyg |
| `perms.type.unit` | Enheter |
| `perms.type.vehicle` | Fordon |
| `perms.type.weapon` | Vapen |
| `perms.unsaved` | Osparade ändringar: {count} |
| `perms.wildcard` | Alla (*) |

#### Loggar (audit)

| Nyckel | Svenska |
|---|---|
| `audit.action.alert.assign` | Larm taget |
| `audit.action.alert.close` | Larm avslutat |
| `audit.action.alert.leave` | Larm lämnat |
| `audit.action.audit.archive` | Loggar arkiverade |
| `audit.action.auth.character` | Karaktär vald i portalen |
| `audit.action.auth.login` | Inloggning i portalen |
| `audit.action.auth.logout` | Utloggning från portalen |
| `audit.action.bolo.check` | Skyltkontroll |
| `audit.action.bolo.create` | Efterlysning utfärdad |
| `audit.action.bolo.expire` | Efterlysning utgången |
| `audit.action.bolo.resolve` | Efterlysning återkallad |
| `audit.action.breach.door` | Dörrforcering |
| `audit.action.breach.scene` | Brottsplatsspår skapade |
| `audit.action.case.assign` | Handläggare tilldelad |
| `audit.action.case.close` | Ärende avslutat |
| `audit.action.case.create` | Ärende upprättat |
| `audit.action.case.subject` | Inblandad tillagd i ärendet |
| `audit.action.case.unassign` | Handläggare borttagen |
| `audit.action.case.update` | Ärende ändrat |
| `audit.action.charges.apply` | Brott registrerade |
| `audit.action.door.breach` | Dörrforcering |
| `audit.action.evidence.analyse` | Bevis analyserat |
| `audit.action.evidence.checkout` | Bevis uttaget ur bevisförrådet |
| `audit.action.evidence.collect` | Bevis säkrat |
| `audit.action.evidence.handin` | Bevis inlämnat till bevisförrådet |
| `audit.action.evidence.link` | Bevis kopplat |
| `audit.action.evidence.mismatch` | Bevis som inte stämmer med registret avvisat |
| `audit.action.evidence.return` | Bevis återlämnat till bevisförrådet |
| `audit.action.evidence.transfer` | Bevis överlämnat eller flyttat |
| `audit.action.fine.issue` | Ordningsbot utfärdad |
| `audit.action.intel.read` | Underrättelse läst |
| `audit.action.lookup.flag` | Möjlig obehörig sökning flaggad |
| `audit.action.lookup.person` | Slagning på person |
| `audit.action.lookup.vehicle` | Slagning på fordon |
| `audit.action.mirror.backfill` | Söktabeller fyllda |
| `audit.action.mirror.seed` | Testdata skapad |
| `audit.action.officer.callsign` | Anropssignal ändrad |
| `audit.action.officer.create` | Polis tillagd i personallistan |
| `audit.action.officer.identity` | Polisens namn eller bild uppdaterad från Discord |
| `audit.action.officer.relink` | Polisens Discord-konto bytt |
| `audit.action.perms.update` | Behörigheter ändrade |
| `audit.action.poi.create` | POI-blad upprättat |
| `audit.action.poi.update` | POI-blad ändrat |
| `audit.action.police.armory` | Utrustning utkvitterad ur vapenförrådet |
| `audit.action.police.fine` | Böter utfärdade med qbx_police |
| `audit.action.police.impound` | Fordon bärgat eller taget i beslag |
| `audit.action.police.jail` | Person skickad till fängelse med qbx_police |
| `audit.action.police.unjail` | Person släppt ur fängelset |
| `audit.action.release.create` | Begäran om allmän handling mottagen |
| `audit.action.release.decide` | Begäran prövad |
| `audit.action.report.create` | Rapport registrerad |
| `audit.action.report.save` | Rapport sparad |
| `audit.action.roles.sync` | Discord-roller synkroniserade |
| `audit.action.share.create` | Delningslänk skapad |
| `audit.action.share.revoke` | Delningslänk återkallad |
| `audit.action.share.view` | Delningslänk visad |
| `audit.action.tablet.issue` | Surfplatta registrerad |
| `audit.action.tablet.reinstate` | Spärr hävd för surfplatta |
| `audit.action.tablet.revoke` | Surfplatta spärrad |
| `audit.action.upload.create` | Bild uppladdad |
| `audit.field.action` | Händelse |
| `audit.field.actor` | Utförd av |
| `audit.field.details` | Detaljer |
| `audit.field.target` | Objekt |
| `audit.field.time` | Tidpunkt |
| `audit.filter.action` | Filtrera på händelse |
| `audit.filter.actor` | Filtrera på polis |
| `audit.flag.unauthorizedSearch` | Möjlig obehörig sökning |
| `audit.flag.unauthorizedSearchDetail` | Slagningar på {subject} utan koppling till ärende eller larm: {count} |
| `audit.flag.unauthorizedSearchNotify` | Möjlig obehörig sökning av {officer}. Slagningar utan koppling till egna ärenden: {count}. |
| `audit.none` | Inga loggposter. |
| `audit.retention` | Loggposter sparas i {days} dagar. |
| `audit.title` | Loggar |

#### Portalen (portal)

| Nyckel | Svenska |
|---|---|
| `portal.audit.pending` | Loggvyn är inte klar än. Loggposterna sparas och visas här när servern kan läsa ut dem. |
| `portal.character.lastSeen` | Senast spelad {date} |
| `portal.character.none` | Vi hittade inga karaktärer. Spela på servern minst en gång och försök igen. |
| `portal.character.select` | Fortsätt som {name} |
| `portal.character.switch` | Byt karaktär |
| `portal.character.title` | Välj karaktär |
| `portal.live.connected` | Live |
| `portal.live.offline` | Liveuppdateringar är inte tillgängliga just nu. |
| `portal.live.otherTab` | Liveuppdateringarna visas i en annan flik. |
| `portal.live.reconnecting` | Anslutningen bröts. Återansluter… |
| `portal.live.unitsAge` | Enhetslistan uppdaterades kl. {time}. |
| `portal.loggedOut` | Du är utloggad. |
| `portal.login.discord` | Logga in med Discord |
| `portal.login.failed` | Inloggningen misslyckades. Försök igen. |
| `portal.login.noAccess` | Du har inte behörighet till portalen. |
| `portal.login.notMember` | Ditt Discord-konto är inte med i vår Discord-server. |
| `portal.login.title` | Logga in |
| `portal.logout` | Logga ut |
| `portal.notAvailableYet` | Den här funktionen är inte tillgänglig i portalen än. |
| `portal.privacy.data` | När du loggar in behandlar vi ditt Discord-ID, ditt visningsnamn, din profilbild och namnen på dina rollspelskaraktärer. Uppgifterna används för att ge dig rätt behörigheter och visa vem som har gjort vad. |
| `portal.privacy.link` | Integritet |
| `portal.privacy.retention` | Sökningar och ändringar loggas. Loggarna sparas i {days} dagar. |
| `portal.privacy.rights` | Kontakta serverledningen om du vill veta vilka uppgifter vi har om dig eller vill få dem raderade. |
| `portal.privacy.title` | Så hanterar vi dina uppgifter |
| `portal.sessionExpired` | Sessionen har gått ut. Logga in igen. |
| `portal.share.copied` | Länken är kopierad. |
| `portal.share.create` | Skapa delningslänk |
| `portal.share.duration` | Giltighetstid |
| `portal.share.expired` | Länken har gått ut. |
| `portal.share.expires` | Länken gäller till {date}. |
| `portal.share.logged` | Varje visning loggas. |
| `portal.share.withheld` | Innehållet är inte längre tillgängligt via den här länken. |
| `portal.title` | Polisportalen |

#### Serverkommandon (core)

| Nyckel | Svenska |
|---|---|
| `core.auditArchive.done` | Loggposter äldre än {days} dagar har flyttats till arkivet. Antal: {count} |
| `core.auditArchive.failed` | Arkiveringen misslyckades. Se serverkonsolen. |
| `core.auditArchive.invalidDays` | Ange ett positivt antal dagar. |
| `core.command.auditArchive` | Flytta gamla loggposter till arkivet (körs för hand en gång i månaden) |
| `core.param.days` | Äldre än så här många dagar (standard 90) |

#### Utvecklarverktyg (dev)

| Nyckel | Svenska |
|---|---|
| `dev.backfill.done` | Söktabellerna är uppdaterade. Personer: {persons} · Fordon: {vehicles} |
| `dev.backfill.failed` | Söktabellerna kunde inte fyllas. Se serverkonsolen. |
| `dev.backfill.started` | Söktabellerna fylls från spelardatabasen… |
| `dev.command.backfill` | Fyll söktabellerna från spelardatabasen |
| `dev.command.fakeunits` | Kör påhittade enheter och testlarm en begränsad tid (antal 0 stoppar) |
| `dev.command.seed` | Skapa påhittade personer och fordon för test |
| `dev.command.selftest` | Kör FredPD:s självtest (behörigheter, synlighet, format) |
| `dev.command.testalert` | Skapa ett testlarm (skottlossning) vid din position |
| `dev.command.testbolo` | Efterlys ett fordon för test (skylten, eller fordonet du sitter i) |
| `dev.fakeunits.alert` | Testlarm från påhittad enhet {callsign} |
| `dev.fakeunits.started` | Påhittade enheter: {count}. De körs i {seconds} s. |
| `dev.fakeunits.stopped` | De påhittade enheterna är stoppade. |
| `dev.param.count` | Antal |
| `dev.param.seconds` | Sekunder |
| `dev.seed.done` | Testdata skapad. Personer: {persons} · Fordon: {vehicles} |
| `dev.seed.failed` | Testdata kunde inte skapas. Se serverkonsolen. |
| `dev.selftest.missingFixtures` | Testfilen {file} saknas. Kör scripts/build.mjs. |
| `dev.selftest.result` | Självtest: {passed} av {total} godkända, {failed} fel. |
| `dev.testalert.sent` | Testlarmet är skickat. |
| `dev.testalert.title` | Skottlossning (testlarm) |
| `dev.testbolo.reason` | Testefterlysning |

### Upstream resources (Swedish locales added by FredPD patches)

#### evidences (patches/evidences.30-sv-locale.patch)

| Nyckel | Svenska |
|---|---|
| `commands.invalid_radius.title` | Bevis |
| `commands.invalid_radius.description` | Bevisen kunde inte tas bort: radien är ogiltig. (Ange ett heltal mellan 1 och 500) |
| `commands.no_evidences.title` | Bevis |
| `commands.no_evidences.description` | Bevisen kunde inte tas bort: det finns inga bevis inom radien. |
| `commands.evidences_deleted.title` | Bevis |
| `commands.evidences_deleted.description` | Alla bevis inom %s har tagits bort. (Antal: %s) |
| `evidences.evidence_box_label_dialog.title` | Märk låda |
| `evidences.evidence_box_label_dialog.name_textfield_title` | Namn |
| `evidences.evidence_box_label_dialog.name_textfield_details` | Namnet som visas i förrådet |
| `evidences.evidence_box_label_dialog.description_textfield_title` | Beskrivning |
| `evidences.evidence_box_label_dialog.description_textfield_details` | Kort beskrivning som visas under föremålet i förrådet |
| `evidences.fingerprint.collecting_label` | Säkra fingeravtryck |
| `evidences.fingerprint.destroying_label` | Ta bort fingeravtryck |
| `evidences.blood.collecting_label` | Säkra blodspår |
| `evidences.blood.destroying_label` | Ta bort blodspår |
| `evidences.saliva.collecting_label` | Säkra saliv |
| `evidences.saliva.destroying_label` | Ta bort saliv |
| `evidences.magazine.collecting_label` | Säkra magasin |
| `evidences.magazine.destroying_label` | Ta bort magasin |
| `evidences.casing.collecting_label` | Säkra hylsa |
| `evidences.casing.destroying_label` | Ta bort hylsa |
| `evidences.bullet.collecting_label` | Säkra projektil |
| `evidences.bullet.destroying_label` | Ta bort projektil |
| `evidences.gunshot_residue.collecting_label` | Säkra krutstänk |
| `evidences.gunshot_residue.destroying_label` | Ta bort krutstänk |
| `evidences.information.in_vehicle` | på %s (registreringsnummer: %s) |
| `evidences.information.at_vehicle` | på fordon (registreringsnummer: %s) |
| `evidences.information.at_coords` | på marken |
| `evidences.information.at_player` | från en person |
| `evidences.information.metadata.crime_scene` | Brottsplats |
| `evidences.information.metadata.collection_time` | Säkrat |
| `evidences.information.metadata.additionalData` | Information |
| `evidences.information.metadata.weapon_type` | Vapentyp |
| `evidences.information.metadata.serial` | Serienummer |
| `evidences.information.seats.-1` | förarsätet |
| `evidences.information.seats.0` | främre passagerarsätet |
| `evidences.information.seats.1` | baksätet bakom föraren |
| `evidences.information.seats.2` | baksätet bakom passageraren |
| `evidences.information.doors.0` | förardörren |
| `evidences.information.doors.1` | främre passagerardörren |
| `evidences.information.doors.2` | bakdörren på förarsidan |
| `evidences.information.doors.3` | bakdörren på passagerarsidan |
| `evidences.notifications.common.placeholders.at_coords` | på marken |
| `evidences.notifications.common.placeholders.at_player` | på den här personen |
| `evidences.notifications.common.placeholders.at_vehicle_door` | på den här fordonsdörren |
| `evidences.notifications.common.placeholders.at_vehicle_seat` | på ditt säte |
| `evidences.notifications.common.placeholders.at_entity` | på det här föremålet |
| `evidences.notifications.common.placeholders.at_weapon` | på vapnet |
| `evidences.notifications.common.errors.collect.title` | Bevis |
| `evidences.notifications.common.errors.collect.description` | Något gick fel när beviset skulle säkras |
| `evidences.notifications.common.errors.destroy.title` | Bevis |
| `evidences.notifications.common.errors.destroy.description` | Något gick fel när beviset skulle tas bort |
| `evidences.notifications.collect.title` | Bevis |
| `evidences.notifications.collect.description` | Bevis %s har säkrats |
| `evidences.notifications.destroy.title` | Bevis |
| `evidences.notifications.destroy.description` | Bevis %s har tagits bort |
| `evidences.notifications.biometrics_pasted.title` | Bevis |
| `evidences.notifications.biometrics_pasted.description` | Biometriska uppgifter har kopierats till urklipp |
| `evidences.notifications.serial_pasted.title` | Bevis |
| `evidences.notifications.serial_pasted.description` | Serienumret har kopierats till urklipp |
| `evidences.notifications.missing_serial.title` | Bevis |
| `evidences.notifications.missing_serial.description` | Beviset har inget serienummer |
| `evidences.notifications.not_analysed.title` | Bevis |
| `evidences.notifications.not_analysed.description` | Beviset har inte analyserats ännu |
| `fingerprint_scanner.target` | Lägg fingret på läsaren |
| `fingerprint_scanner.input_help` | Tryck %s för att avbryta |
| `fingerprint_scanner.scan_match.title` | Fingeravtryck läst |
| `fingerprint_scanner.scan_match.description` | Träff i registret: %s (%s · %s) |
| `fingerprint_scanner.scan_no_match.title` | Fingeravtryck läst |
| `fingerprint_scanner.scan_no_match.description` | Ingen träff i registret |
| `fingerprint_scanner.scan_gloves.title` | Läsningen misslyckades |
| `fingerprint_scanner.scan_gloves.description` | Du har handskar på dig |
| `fingerprint_scanner.scan_error.title` | Läsningen misslyckades |
| `fingerprint_scanner.scan_error.description` | Fingeravtrycket kunde inte läsas |
| `steel_file.serial_removed.title` | Serienummer bortfilat |
| `steel_file.serial_removed.description` | Serienumret har filats bort från vapnet |
| `biometrics_taking.description` | Polisen %s vill ta ditt %s. Samtycker du? |
| `biometrics_taking.deny` | Neka |
| `biometrics_taking.accept` | Godkänn |
| `biometrics_taking.target.take_fingerprint` | Ta fingeravtryck |
| `biometrics_taking.target.take_dna` | Ta DNA-prov |
| `biometrics_taking.target.force_take_fingerprint` | Ta fingeravtryck med tvång |
| `biometrics_taking.target.force_take_dna` | Ta DNA-prov med tvång |
| `biometrics_taking.notifications.request_sent.title` | Bevis |
| `biometrics_taking.notifications.request_sent.description` | Förfrågan har skickats |
| `biometrics_taking.notifications.error.title` | Bevis |
| `biometrics_taking.notifications.error.description` | Något gick fel |
| `biometrics_taking.notifications.no_consent.title` | Bevis |
| `biometrics_taking.notifications.no_consent.description` | Personen nekade |
| `biometrics_taking.notifications.consent.title` | Bevis |
| `biometrics_taking.notifications.consent.description` | Personen har samtyckt |
| `biometrics_taking.notifications.no_permission.title` | Bevis |
| `biometrics_taking.notifications.no_permission.description` | Du har inte behörighet |
| `laptop.notifications.error_laptop_creation.title` | Bevis |
| `laptop.notifications.error_laptop_creation.description` | Laptopen kunde inte placeras |
| `laptop.notifications.error_laptop_pickup.title` | Bevis |
| `laptop.notifications.error_laptop_pickup.description` | Laptopen kunde inte plockas upp |
| `laptop.notifications.input_help` | Tryck %s för att placera laptopen.%sTryck %s för att avbryta |
| `laptop.notifications.no_permission.title` | Bevis |
| `laptop.notifications.no_permission.description` | Du har inte behörighet |
| `laptop.target.interact` | Använd laptop |
| `laptop.target.pickup` | Plocka upp |
| `laptop.login_screen.title` | Annan användare |
| `laptop.login_screen.username_placeholder` | Användarnamn |
| `laptop.login_screen.password_placeholder` | Lösenord |
| `laptop.login_screen.welcome` | Välkommen |
| `laptop.login_screen.missing_permission` | Fel användarnamn eller lösenord |
| `laptop.desktop_screen.common.date_locales` | sv-SE |
| `laptop.desktop_screen.common.evidence_placeholder` | Bevis |
| `laptop.desktop_screen.common.crime_scene_placeholder` | Brottsplats |
| `laptop.desktop_screen.common.collection_time_placeholder` | Säkrat |
| `laptop.desktop_screen.common.additional_data_placeholder` | Övrig information |
| `laptop.desktop_screen.common.name_placeholder` | Namn |
| `laptop.desktop_screen.common.firstname_placeholder` | Förnamn |
| `laptop.desktop_screen.common.lastname_placeholder` | Efternamn |
| `laptop.desktop_screen.common.fullname_placeholder` | Förnamn Efternamn |
| `laptop.desktop_screen.common.birthdate_placeholder` | Födelsedatum |
| `laptop.desktop_screen.common.gender_placeholder` | Kön |
| `laptop.desktop_screen.common.from` | från |
| `laptop.desktop_screen.common.by` | av |
| `laptop.desktop_screen.common.fingerprint` | fingeravtryck |
| `laptop.desktop_screen.common.dna` | DNA |
| `laptop.desktop_screen.common.statuses.search` | Sök… |
| `laptop.desktop_screen.common.statuses.loading` | Laddar… |
| `laptop.desktop_screen.common.statuses.error` | Fel |
| `laptop.desktop_screen.common.statuses.no_data` | Inga uppgifter |
| `laptop.desktop_screen.common.statuses.delete` | Ta bort |
| `laptop.desktop_screen.common.statuses.save` | Spara |
| `laptop.desktop_screen.common.statuses.cancel` | Avbryt |
| `laptop.desktop_screen.common.statuses.unknown` | okänd |
| `laptop.desktop_screen.common.statuses.analysed` | analyserat |
| `laptop.desktop_screen.common.statuses.no_selection` | Inget att välja |
| `laptop.desktop_screen.common.statuses.select_evidence` | Välj ett bevis. |
| `laptop.desktop_screen.common.statuses.select_citizen` | Välj en person. |
| `laptop.desktop_screen.common.statuses.select_firearm` | Välj ett vapen. |
| `laptop.desktop_screen.common.statuses.fill_all_fields` | Fyll i alla fält. |
| `laptop.desktop_screen.common.dropdowns.select_citizen` | Välj person |
| `laptop.desktop_screen.common.dropdowns.select_firearm` | Välj vapen |
| `laptop.desktop_screen.citizens_app.name` | Personregister |
| `laptop.desktop_screen.citizens_app.create_citizen` | Lägg till person |
| `laptop.desktop_screen.citizens_app.personal_data` | Personuppgifter |
| `laptop.desktop_screen.citizens_app.biometric_data` | Biometriska uppgifter |
| `laptop.desktop_screen.citizens_app.notes.header` | Anteckningar |
| `laptop.desktop_screen.citizens_app.notes.create` | Ny anteckning |
| `laptop.desktop_screen.citizens_app.notes.edit` | Redigera anteckning |
| `laptop.desktop_screen.citizens_app.notes.title` | Rubrik |
| `laptop.desktop_screen.citizens_app.notes.text` | Text |
| `laptop.desktop_screen.citizens_app.registered_firearms` | Registrerade vapen |
| `laptop.desktop_screen.citizens_app.statuses.no_citizens_found` | Inga personer hittades |
| `laptop.desktop_screen.citizens_app.statuses.no_notes_found` | Inga anteckningar hittades |
| `laptop.desktop_screen.citizens_app.statuses.no_registered_firearms` | Inga registrerade vapen |
| `laptop.desktop_screen.citizens_app.statuses.select_evidence` | Välj bevis |
| `laptop.desktop_screen.citizens_app.status_messages.citizen_creation_success` | Personen har lagts till. |
| `laptop.desktop_screen.citizens_app.status_messages.citizen_creation_error` | Personen kunde inte läggas till. |
| `laptop.desktop_screen.citizens_app.status_messages.citizen_update_success` | Personen har uppdaterats. |
| `laptop.desktop_screen.citizens_app.status_messages.citizen_update_error` | Personen kunde inte sparas. |
| `laptop.desktop_screen.citizens_app.status_messages.citizen_deletion_success` | Personen har tagits bort. |
| `laptop.desktop_screen.citizens_app.status_messages.citizen_deletion_error` | Personen kunde inte tas bort. |
| `laptop.desktop_screen.citizens_app.status_messages.note_save_success` | Anteckningen har sparats. |
| `laptop.desktop_screen.citizens_app.status_messages.note_save_error` | Anteckningen kunde inte sparas. |
| `laptop.desktop_screen.citizens_app.status_messages.note_deletion_success` | Anteckningen har tagits bort. |
| `laptop.desktop_screen.citizens_app.status_messages.note_deletion_error` | Anteckningen kunde inte tas bort. |
| `laptop.desktop_screen.citizens_app.status_messages.biometric_data_link_success` | %s har kopplats till den valda personen. |
| `laptop.desktop_screen.citizens_app.status_messages.biometric_data_unlink_success` | %s har kopplats bort från den valda personen. |
| `laptop.desktop_screen.citizens_app.status_messages.biometric_data_link_error` | %s kunde inte kopplas till personen. |
| `laptop.desktop_screen.citizens_app.gender.header` | Välj kön |
| `laptop.desktop_screen.citizens_app.gender.male` | Man |
| `laptop.desktop_screen.citizens_app.gender.female` | Kvinna |
| `laptop.desktop_screen.citizens_app.gender.non_binary` | Icke-binär |
| `laptop.desktop_screen.fingerprint_app.name` | Fingeravtrycksanalys |
| `laptop.desktop_screen.fingerprint_app.no_items_with_fingerprints` | Du har inga föremål med fingeravtryck på dig. |
| `laptop.desktop_screen.dna_app.name` | DNA-analys |
| `laptop.desktop_screen.dna_app.no_items_with_dna` | Du har inga föremål med DNA på dig. |
| `laptop.desktop_screen.evidence_analysis.start_analyzation` | Starta analys |
| `laptop.desktop_screen.evidence_analysis.matching_biometric_data` | Jämför %s med registret… |
| `laptop.desktop_screen.evidence_analysis.database_match.header` | Träff i registret |
| `laptop.desktop_screen.evidence_analysis.database_match.description` | Spåret (%s) på beviset tillhör följande person: |
| `laptop.desktop_screen.evidence_analysis.database_match.open_citizens_app` | Öppna i personregistret |
| `laptop.desktop_screen.evidence_analysis.no_database_match.header` | Ingen träff i registret |
| `laptop.desktop_screen.evidence_analysis.no_database_match.description` | Spåret (%s) på beviset tillhör en okänd person. Om du vet vem det är kan du koppla spåret (%s) från beviset till personen i personregistret. |
| `laptop.desktop_screen.firearms_registry_app.name` | Vapenregister |
| `laptop.desktop_screen.firearms_registry_app.firearm_information` | Information |
| `laptop.desktop_screen.firearms_registry_app.firearm_type` | Typ |
| `laptop.desktop_screen.firearms_registry_app.firearm_serial` | Serienummer |
| `laptop.desktop_screen.firearms_registry_app.firearm_owner` | Ägare |
| `laptop.desktop_screen.firearms_registry_app.registered_by` | Registrerat av |
| `laptop.desktop_screen.firearms_registry_app.registered_at` | Registrerat |
| `laptop.desktop_screen.firearms_registry_app.firearm_registration` | Registrering |
| `laptop.desktop_screen.firearms_registry_app.firearm_status` | Status |
| `laptop.desktop_screen.firearms_registry_app.registration_reason` | Skäl för registrering |
| `laptop.desktop_screen.firearms_registry_app.no_firearms_found` | Inga vapen hittades |
| `laptop.desktop_screen.firearms_registry_app.registration_popup.header` | Registrera vapen |
| `laptop.desktop_screen.firearms_registry_app.registration_popup.citizen` | Person |
| `laptop.desktop_screen.firearms_registry_app.registration_popup.firearm` | Vapen |
| `laptop.desktop_screen.firearms_registry_app.registration_popup.reason` | Skäl för registrering |
| `laptop.desktop_screen.firearms_registry_app.registration_popup.status` | Vapnets status |
| `laptop.desktop_screen.firearms_registry_app.status.header` | Välj status |
| `laptop.desktop_screen.firearms_registry_app.status.unknown` | Okänd |
| `laptop.desktop_screen.firearms_registry_app.status.registered` | Registrerat |
| `laptop.desktop_screen.firearms_registry_app.status.lost` | Förlorat |
| `laptop.desktop_screen.firearms_registry_app.status.stolen` | Stulet |
| `laptop.desktop_screen.firearms_registry_app.status.confiscated` | Beslagtaget |
| `laptop.desktop_screen.firearms_registry_app.status.destroyed` | Förstört |
| `laptop.desktop_screen.firearms_registry_app.status.suspended` | Spärrat |
| `laptop.desktop_screen.firearms_registry_app.status_messages.firearm_registration_success` | Vapnet har registrerats. |
| `laptop.desktop_screen.firearms_registry_app.status_messages.firearm_registration_error` | Vapnet kunde inte registreras. |
| `laptop.desktop_screen.firearms_registry_app.status_messages.firearm_already_registered` | Vapnet är redan registrerat. |
| `laptop.desktop_screen.firearms_registry_app.status_messages.firearm_update_success` | Vapnet har uppdaterats. |
| `laptop.desktop_screen.firearms_registry_app.status_messages.firearm_update_error` | Vapnet kunde inte sparas. |
| `laptop.desktop_screen.firearms_registry_app.status_messages.firearm_deletion_success` | Vapnet har tagits bort. |
| `laptop.desktop_screen.firearms_registry_app.status_messages.firearm_deletion_error` | Vapnet kunde inte tas bort. |
| `laptop.desktop_screen.ballistics_app.name` | Ballistisk analys |
| `laptop.desktop_screen.ballistics_app.no_ballistics_evidence_items` | Du har inga ballistiska bevis på dig. |
| `laptop.desktop_screen.ballistics_app.start_analyzation` | Starta analys |
| `laptop.desktop_screen.ballistics_app.matching_serial` | Analyserar ballistiskt bevis… |
| `laptop.desktop_screen.ballistics_app.registry_match.header` | Träff i vapenregistret |
| `laptop.desktop_screen.ballistics_app.registry_match.description` | Det ballistiska beviset kommer från följande vapen: |
| `laptop.desktop_screen.ballistics_app.registry_match.open_firearms_registry` | Öppna i vapenregistret |
| `laptop.desktop_screen.ballistics_app.no_registry_match.header` | Ingen träff i vapenregistret |
| `laptop.desktop_screen.ballistics_app.no_registry_match.casing_description` | Hylsan har inget serienummer som matchar ett vapen i vapenregistret. Hylsor kan ändå identifieras genom de unika mikroskopiska verktygsspår som ojämnheter i vapnet lämnar. Välj ett vapen som du har på dig för att se om hylsan kommer från just det vapnet (eller åtminstone från ett vapen av samma typ). |
| `laptop.desktop_screen.ballistics_app.no_registry_match.bullet_description` | Avfyrade projektiler kan identifieras genom de unika mikroskopiska spår som ojämnheter i vapnets pipa lämnar. Välj ett vapen som du har på dig för att se om projektilen kommer från just det vapnet (eller åtminstone från ett vapen av samma typ). |
| `laptop.desktop_screen.ballistics_app.no_registry_match.inventory_match.microstamp` | Det ballistiska beviset kommer från just det valda vapnet: serienumret är mikrostämplat på beviset. |
| `laptop.desktop_screen.ballistics_app.no_registry_match.inventory_match.imperfections` | Det ballistiska beviset kommer från just det valda vapnet: de har samma unika ojämnheter. |
| `laptop.desktop_screen.ballistics_app.no_registry_match.inventory_match.type` | Det ballistiska beviset kommer från ett vapen av samma typ som det valda vapnet. |
| `laptop.desktop_screen.ballistics_app.no_registry_match.inventory_match.none` | Det ballistiska beviset matchar inte det valda vapnet. |
| `laptop.desktop_screen.ballistics_app.show_type.header` | Analysen är klar |
| `laptop.desktop_screen.ballistics_app.show_type.magazine_description` | Ett magasin kan knytas till en vapentyp men inte till ett enskilt vapen. Det här magasinet hör till ett vapen av den här typen: |
| `laptop.desktop_screen.ballistics_app.show_type.gunshot_residue_description` | Krutstänk visar vilken typ av vapen som avfyrats, och av koncentrationen går det att räkna ut när skottet avlossades. Analysen av de valda krutstänken gav följande: |
| `laptop.desktop_screen.ballistics_app.show_type.fired_at` | Avfyrat |
| `laptop.desktop_screen.wiretap_app.name` | Avlyssning |
| `laptop.desktop_screen.wiretap_app.warning_popup.title` | Viktigt |
| `laptop.desktop_screen.wiretap_app.warning_popup.warning` | Telefonsamtal och radiotrafik får bara avlyssnas med tillstånd från domstol. Vid fara i dröjsmål får åklagare besluta om avlyssning i väntan på rättens prövning. |
| `laptop.desktop_screen.wiretap_app.warning_popup.accept_button` | Jag förstår |
| `laptop.desktop_screen.wiretap_app.phone_calls.header` | Telefonsamtal |
| `laptop.desktop_screen.wiretap_app.phone_calls.no_calls_running` | Inga pågående samtal |
| `laptop.desktop_screen.wiretap_app.phone_calls.lacking_permissions` | Du har inte behörighet att avlyssna telefonsamtal |
| `laptop.desktop_screen.wiretap_app.phone_calls.notifications.popup_header` | Aviseringar om samtal |
| `laptop.desktop_screen.wiretap_app.phone_calls.notifications.status_subscribed` | Du får en avisering när %s påbörjar ett samtal. Här kan du sluta få aviseringar eller byta person: |
| `laptop.desktop_screen.wiretap_app.phone_calls.notifications.status_unsubscribed` | Ange personens %s för att få en avisering när personen påbörjar ett samtal: |
| `laptop.desktop_screen.wiretap_app.phone_calls.notifications.placeholder_full_name` | fullständiga namn |
| `laptop.desktop_screen.wiretap_app.phone_calls.notifications.placeholder_phone_number` | telefonnummer |
| `laptop.desktop_screen.wiretap_app.phone_calls.notifications.subscribe_button` | Prenumerera |
| `laptop.desktop_screen.wiretap_app.phone_calls.notifications.unsubscribe_button` | Avsluta prenumeration |
| `laptop.desktop_screen.wiretap_app.phone_calls.notifications.status_messages.subscribed` | Du får nu aviseringar |
| `laptop.desktop_screen.wiretap_app.phone_calls.notifications.status_messages.unsubscribed` | Du får inte längre aviseringar |
| `laptop.desktop_screen.wiretap_app.phone_calls.notifications.notification.title` | Avlyssning av samtal |
| `laptop.desktop_screen.wiretap_app.phone_calls.notifications.notification.description` | %s deltar nu i ett samtal som kan avlyssnas |
| `laptop.desktop_screen.wiretap_app.spy_microphones.header` | Buggmikrofoner |
| `laptop.desktop_screen.wiretap_app.spy_microphones.no_spy_microphones_placed` | Inga buggmikrofoner utplacerade |
| `laptop.desktop_screen.wiretap_app.spy_microphones.lacking_permissions` | Du har inte behörighet att lyssna på buggmikrofoner |
| `laptop.desktop_screen.wiretap_app.radio.header` | Radio |
| `laptop.desktop_screen.wiretap_app.radio.lacking_permissions` | Du har inte behörighet att avlyssna radiokanaler |
| `laptop.desktop_screen.wiretap_app.latest_actions.header` | Senaste åtgärder |
| `laptop.desktop_screen.wiretap_app.latest_actions.no_actions_available` | Inga protokollförda åtgärder |
| `laptop.desktop_screen.wiretap_app.latest_actions.end_reached` | Slut på listan |
| `laptop.desktop_screen.wiretap_app.latest_actions.action_duration` | %s från %s till %s |
| `laptop.desktop_screen.wiretap_app.latest_actions.actions.ObservableCall` | %s avlyssnade ett samtal mellan %s |
| `laptop.desktop_screen.wiretap_app.latest_actions.actions.ObservableRadioFreq` | %s avlyssnade radiokanalen %s MHz |
| `laptop.desktop_screen.wiretap_app.latest_actions.actions.ObservableSpyMicrophone` | %s lyssnade på buggmikrofonen %s |
| `laptop.desktop_screen.wiretap_app.running_observation_popup.ObservableCall` | Pågående avlyssning av samtal #%s |
| `laptop.desktop_screen.wiretap_app.running_observation_popup.ObservableRadioFreq` | Pågående avlyssning av radiokanal %s MHz |
| `laptop.desktop_screen.wiretap_app.running_observation_popup.ObservableSpyMicrophone` | Lyssnar på buggmikrofonen %s |
| `laptop.desktop_screen.wiretap_app.running_observation_popup.status_messages.protocol_save_success` | Avlyssningsprotokollet har sparats. |
| `laptop.desktop_screen.wiretap_app.running_observation_popup.status_messages.protocol_save_error` | Avlyssningsprotokollet kunde inte sparas. |
| `laptop.desktop_screen.wiretap_app.protocol_popup.header.ObservableCall` | Protokoll över avlyssning av samtal #%s |
| `laptop.desktop_screen.wiretap_app.protocol_popup.header.ObservableRadioFreq` | Protokoll över avlyssning av radiokanal #%s |
| `laptop.desktop_screen.wiretap_app.protocol_popup.header.ObservableSpyMicrophone` | Protokoll över buggmikrofon #%s |
| `laptop.desktop_screen.wiretap_app.protocol_popup.observation_started` | Avlyssningen startade. |
| `laptop.desktop_screen.wiretap_app.protocol_popup.observation_ended` | Avlyssningen avslutades. |
| `spy_microphone.input_help` | Tryck %s för att placera buggmikrofonen.%sTryck %s för att avbryta |
| `spy_microphone.error_spy_microphone_creation.title` | Bevis |
| `spy_microphone.error_spy_microphone_creation.description` | Det finns redan en buggmikrofon med det namnet |
| `spy_microphone.spy_microphone_label_dialog.title` | Namnge buggmikrofon |
| `spy_microphone.spy_microphone_label_dialog.label_textfield_title` | Namn |
| `spy_microphone.spy_microphone_label_dialog.label_textfield_details` | Välj ett unikt namn för buggmikrofonen i avlyssningsappen på bevislaptopen |
| `spy_microphone.target_collect` | Plocka upp buggmikrofon |

#### qbx_policejob (patches/qbx_policejob.40-sv-locale.patch)

| Nyckel | Svenska |
|---|---|
| `error.in_vehicle` | Du kan inte göra det i ett fordon |
| `error.license_already` | Personen har redan licensen |
| `error.error_license` | Personen har inte den licensen |
| `error.no_camera` | Kameran finns inte |
| `error.blood_not_cleared` | Blodet togs inte bort |
| `error.bullet_casing_not_removed` | Hylsorna togs inte bort |
| `error.none_nearby` | Ingen i närheten |
| `error.canceled` | Avbrutet |
| `error.time_higher` | Tiden måste vara större än 0 |
| `error.amount_higher` | Beloppet måste vara större än 0 |
| `error.vehicle_cuff` | Du kan inte sätta handfängsel på någon som sitter i ett fordon |
| `error.no_cuff` | Du har inga handfängsel med dig |
| `error.no_impound` | Det finns inga bärgade fordon |
| `error.no_spikestripe` | Du kan inte lägga ut fler spikmattor |
| `error.error_license_type` | Ogiltig licenstyp |
| `error.rank_license` | Din tjänstegrad räcker inte för att utfärda licenser |
| `error.revoked_license` | En av dina licenser har återkallats |
| `error.rank_revoke` | Din tjänstegrad räcker inte för att återkalla licenser |
| `error.on_duty_police_only` | Endast för polis i tjänst |
| `error.vehicle_not_flag` | Fordonet är inte flaggat |
| `error.vehicle_flag` | Fordonet är redan flaggat |
| `error.not_towdriver` | Personen är inte bärgare |
| `error.not_lawyer` | Personen är inte advokat |
| `error.no_anklet` | Personen har ingen fotboja |
| `error.have_evidence_bag` | Du behöver en tom bevispåse |
| `error.no_driver_license` | Inget körkort |
| `error.not_cuffed_dead` | Personen är varken handfängslad eller död |
| `error.no_rob` | Personen är varken handfängslad eller död och har inte händerna uppe |
| `error.target_too_far` | Personen är för långt bort |
| `error.player_not_found` | Personen hittades inte |
| `error.insufficient_funds` | Personen har inte tillräckligt med pengar |
| `error.invalid_fine` | Uppgifterna för ordningsboten är ogiltiga |
| `error.fine_payment_failed` | Betalningen av ordningsboten misslyckades och beloppet har betalats tillbaka |
| `success.uncuffed` | Dina handfängsel har tagits av |
| `success.granted_license` | Du har fått en licens |
| `success.grant_license` | Du har utfärdat en licens |
| `success.revoke_license` | Du har återkallat en licens |
| `success.tow_paid` | Du har fått 500 kr i ersättning |
| `success.blood_clear` | Blodet har tagits bort |
| `success.bullet_casing_removed` | Hylsorna har tagits bort |
| `success.anklet_taken_off` | Din fotboja har tagits av |
| `success.took_anklet_from` | Du tog av fotbojan på %s %s |
| `success.put_anklet` | Du har fått en fotboja |
| `success.put_anklet_on` | Du satte en fotboja på %s %s |
| `success.vehicle_flagged` | Fordonet %s är flaggat för: %s |
| `success.impound_vehicle_removed` | Fordonet är uthämtat från uppställningsplatsen |
| `success.impounded` | Fordonet har bärgats |
| `success.escapedcuff` | Du tog dig ur handfängslet |
| `success.fine_issued` | Du har fått en ordningsbot på %d kr för %s av polis %s (%s) |
| `success.fine_sent` | Du har utfärdat en ordningsbot till %s på %d kr |
| `info.mr` | herr |
| `info.mrs` | fru |
| `info.impound_price` | Avgift för att hämta ut fordonet (kan vara 0) |
| `info.plate_number` | Registreringsnummer |
| `info.flag_reason` | Anledning till flaggningen |
| `info.camera_id_help` | Kamera-ID |
| `info.callsign_name` | Din anropssignal |
| `info.poobject_object` | Objekttyp att placera, eller ”delete” för att ta bort |
| `info.player_id` | Spelar-ID |
| `info.citizen_id` | Karaktärens citizen-id |
| `info.dna_sample` | DNA-prov |
| `info.jail_time` | Tid i fängelse |
| `info.jail_time_no` | Fängelsetiden måste vara större än 0 |
| `info.license_type` | Licenstyp (driver = körkort, weapon = vapenlicens) |
| `info.ankle_location` | Fotbojans position |
| `info.cuff` | Du är handfängslad |
| `info.cuffed_walk` | Du är handfängslad men kan gå |
| `info.vehicle_flagged` | Fordonet %s är flaggat för: %s |
| `info.unflag_vehicle` | Flaggningen av fordonet %s är borttagen |
| `info.tow_driver_paid` | Du har betalat bärgaren |
| `info.paid_lawyer` | Du har betalat advokaten |
| `info.vehicle_taken_depot` | Fordonet har bärgats mot en avgift på %s kr |
| `info.vehicle_seized` | Fordonet har tagits i beslag |
| `info.stolen_money` | Du har stulit %s kr |
| `info.cash_robbed` | Du har blivit rånad på %s kr |
| `info.driving_license_confiscated` | Ditt körkort har omhändertagits |
| `info.cash_confiscated` | Dina kontanter har tagits i beslag |
| `info.searched_success` | Du har kroppsvisiterat personen |
| `info.being_searched` | Du kroppsvisiteras |
| `info.cash_found` | Hittade %s kr på personen |
| `info.sent_jail_for` | Personen skickades till fängelse i %s mån |
| `info.fine_received` | Du har fått böter på %s kr |
| `info.blip_text` | Polislarm – %s |
| `info.jail_time_input` | Fängelsetid |
| `info.submit` | Skicka |
| `info.time_months` | Tid i månader |
| `info.bill` | Böter |
| `info.amount` | Belopp |
| `info.vehicle_info` | Motor: %s % · Bränsle: %s % |
| `info.evidence_stash` | Bevisförråd · %s |
| `info.slot` | Fack nr (1, 2, 3) |
| `info.current_evidence` | %s · Låda %s |
| `info.on_duty` | [E] Gå i tjänst |
| `info.off_duty` | [E] Gå ur tjänst |
| `info.onoff_duty` | I tjänst / ur tjänst |
| `info.stash` | Förråd %s |
| `info.delete_spike` | [E] Ta bort spikmattan |
| `info.close_camera` | Stäng kameran |
| `info.bullet_casing` | [~g~G~s~] Hylsa %s |
| `info.casing` | Hylsa |
| `info.blood` | Blod |
| `info.blood_text` | [~g~G~s~] Blod %s |
| `info.fingerprint_text` | [G] Fingeravtryck |
| `info.fingerprint` | Fingeravtryck |
| `info.store_heli` | [E] Ställ in helikoptern |
| `info.take_heli` | [E] Ta ut helikoptern |
| `info.impound_veh` | [E] Bärga fordonet |
| `info.store_veh` | [E] Ställ in fordonet |
| `info.grab_veh` | [E] Fordonsgarage |
| `info.armory` | Vapenförråd |
| `info.enter_armory` | [E] Vapenförråd |
| `info.finger_scan` | Fingeravtrycksläsare |
| `info.scan_fingerprint` | [E] Läs av fingeravtryck |
| `info.trash` | Papperskorg |
| `info.trash_enter` | [E] Papperskorg |
| `info.stash_enter` | [E] Öppna skåpet |
| `info.evidence` | [E] Bevis |
| `info.target_location` | Positionen för %s %s är markerad på kartan |
| `info.anklet_location` | Fotbojans position |
| `info.new_call` | Nytt larm |
| `info.officer_down` | Skadad polis: %s · %s |
| `info.plate_triggered` | Flaggat fordon %s passerade %s (ANPR-kamera %s) |
| `info.plate_triggered_blip` | Flaggat fordon vid ANPR-kamera %s |
| `info.camera_id` |  – kamera-ID:  |
| `info.fine_title` | Utfärda ordningsbot |
| `info.law_violated` | Förseelse |
| `info.law_placeholder` | t.ex. hastighetsöverträdelse, körning mot rött ljus |
| `info.fine_amount` | Belopp (kr) |
| `info.officer_notes` | Anteckningar (valfritt) |
| `info.notes_placeholder` | Mer information om förseelsen… |
| `info.select_citizen` | Välj person |
| `evidence.red_hands` | Röda händer |
| `evidence.wide_pupils` | Vidgade pupiller |
| `evidence.red_eyes` | Röda ögon |
| `evidence.weed_smell` | Luktar cannabis |
| `evidence.gunpowder` | Krutstänk på kläderna |
| `evidence.chemicals` | Luktar kemikalier |
| `evidence.heavy_breathing` | Andas tungt |
| `evidence.sweat` | Svettas kraftigt |
| `evidence.handbleed` | Blod på händerna |
| `evidence.confused` | Förvirrad |
| `evidence.alcohol` | Luktar alkohol |
| `evidence.heavy_alcohol` | Luktar starkt av alkohol |
| `evidence.agitated` | Uppjagad – tecken på metamfetaminpåverkan |
| `evidence.serial_not_visible` | Serienumret går inte att läsa |
| `menu.garage_title` | Polisfordon |
| `menu.close` | ⬅ Stäng menyn |
| `menu.impound` | Bärgade fordon |
| `menu.pol_impound` | Polisens uppställningsplats |
| `menu.pol_garage` | Polisgarage |
| `menu.pol_armory` | Polisens vapenförråd |
| `menu.impound_engine` | Motor |
| `menu.impound_fuel` | Bränsle |
| `menu.trash_stash` | Polisens papperskorg |
| `menu.locker_stash` | Personligt skåp |
| `hud.heli_model` | Modell |
| `hud.heli_plate` | Regnr |
| `hud.heli_speed` | km/h |
| `hud.fingerprint_id` | Fingeravtrycks-ID |
| `hud.fingerprint_none` | Inget resultat |
| `hud.camera_connected` | Ansluten |
| `hud.camera_failed` | Anslutningen misslyckades |
| `hud.camera_bad_request` | Fel #400: ogiltig begäran |
| `hud.camera_error` | Fel |
| `email.sender` | Kronofogden |
| `email.subject` | Indrivning av böter |
| `email.message` | Hej %s %s, /  / Kronofogden har drivit in böterna som du fick av polisen. / <strong>%s kr</strong> har dragits från ditt konto. /  / Med vänlig hälsning / Kronofogden |
| `commands.place_spike` | Lägg ut en spikmatta (endast polis) |
| `commands.license_grant` | Utfärda en licens till någon |
| `commands.license_revoke` | Återkalla någons licens |
| `commands.place_object` | Placera eller ta bort ett objekt (endast polis) |
| `commands.cuff_player` | Sätt handfängsel på en person (endast polis) |
| `commands.escort` | Eskortera en person |
| `commands.callsign` | Ange din anropssignal |
| `commands.clear_casign` | Ta bort hylsor i området (endast polis) |
| `commands.jail_player` | Skicka en person till fängelse (endast polis) |
| `commands.unjail_player` | Släpp en person ur fängelset (endast polis) |
| `commands.clearblood` | Ta bort blod i området (endast polis) |
| `commands.seizecash` | Ta kontanter i beslag (endast polis) |
| `commands.softcuff` | Sätt handfängsel så att personen kan gå (endast polis) |
| `commands.camera` | Visa en övervakningskamera (endast polis) |
| `commands.flagplate` | Flagga ett registreringsnummer (endast polis) |
| `commands.unflagplate` | Ta bort flaggningen av ett registreringsnummer (endast polis) |
| `commands.plateinfo` | Slå på ett registreringsnummer (endast polis) |
| `commands.depot` | Bärga ett fordon mot avgift (endast polis) |
| `commands.impound` | Ta ett fordon i beslag (endast polis) |
| `commands.paytow` | Betala bärgaren (endast polis) |
| `commands.paylawyer` | Betala advokaten (endast polis och domare) |
| `commands.anklet` | Sätt på en fotboja (endast polis) |
| `commands.ankletlocation` | Visa var en persons fotboja finns |
| `commands.removeanklet` | Ta av en fotboja (endast polis) |
| `commands.drivinglicense` | Omhänderta ett körkort (endast polis) |
| `commands.takedna` | Ta ett DNA-prov från en person (kräver en tom bevispåse, endast polis) |
| `commands.police_report` | Larma polisen |
| `commands.message_sent` | Meddelande |
| `commands.civilian_call` | Samtal från allmänheten |
| `commands.emergency_call` | Nytt 112-samtal |
| `commands.fine` | Utfärda en ordningsbot till en person i närheten (endast polis) |
| `progressbar.blood_clear` | Tar bort blod… |
| `progressbar.bullet_casing` | Tar bort hylsor… |
| `progressbar.robbing` | Rånar personen… |
| `progressbar.place_object` | Placerar objektet… |
| `progressbar.remove_object` | Tar bort objektet… |
| `progressbar.impound` | Bärgar fordonet… |
| `fredpd.no_permission` | Du har inte behörighet att göra det här |
| `fredpd.try_again` | Vänta en stund och försök igen |
| `fredpd.garage_empty` | Det finns inga fordon som du har behörighet att ta ut |
| `fredpd.armory_title` | Vapenförråd – %s |
| `fredpd.armory_count` | Antal: %s |
| `fredpd.armory_taken` | Du har kvitterat ut %s × %s |
| `fredpd.armory_empty` | Det finns inget här som du har behörighet att kvittera ut |
| `fredpd.armory_too_far` | Du är för långt från vapenförrådet |
| `fredpd.armory_full` | Du kan inte bära det |
| `fredpd.armory_limit` | Du bär redan det högsta antalet som du får kvittera ut |
| `fredpd.armory_unavailable` | Vapenförrådet är inte tillgängligt |
| `fredpd.armory_failed` | Utrustningen kunde inte lämnas ut |
| `fredpd.bolo_radar` | Träff på efterlysning: %s passerade %s (ANPR-kamera %s) |

#### qb-policejob (patches/qb-policejob.40-sv-locale.patch)

| Nyckel | Svenska |
|---|---|
| `error.license_already` | Personen har redan licensen |
| `error.error_license` | Personen har inte den licensen |
| `error.no_camera` | Kameran finns inte |
| `error.blood_not_cleared` | Blodet togs inte bort |
| `error.bullet_casing_not_removed` | Hylsorna togs inte bort |
| `error.none_nearby` | Ingen i närheten |
| `error.canceled` | Avbrutet |
| `error.time_higher` | Tiden måste vara större än 0 |
| `error.amount_higher` | Beloppet måste vara större än 0 |
| `error.vehicle_cuff` | Du kan inte sätta handfängsel på någon som sitter i ett fordon |
| `error.no_cuff` | Du har inga handfängsel med dig |
| `error.no_impound` | Det finns inga bärgade fordon |
| `error.no_spikestripe` | Du kan inte lägga ut fler spikmattor |
| `error.error_license_type` | Ogiltig licenstyp |
| `error.rank_license` | Din tjänstegrad räcker inte för att utfärda licenser |
| `error.revoked_license` | En av dina licenser har återkallats |
| `error.rank_revoke` | Din tjänstegrad räcker inte för att återkalla licenser |
| `error.on_duty_police_only` | Endast för polis i tjänst |
| `error.vehicle_not_flag` | Fordonet är inte flaggat |
| `error.not_towdriver` | Personen är inte bärgare |
| `error.not_lawyer` | Personen är inte advokat |
| `error.no_anklet` | Personen har ingen fotboja |
| `error.have_evidence_bag` | Du behöver en tom bevispåse |
| `error.no_driver_license` | Inget körkort |
| `error.not_cuffed_dead` | Personen är varken handfängslad eller död |
| `error.fine_yourself` | Du kan inte utfärda en ordningsbot till dig själv |
| `error.not_online` | Personen är inte inloggad |
| `success.uncuffed` | Dina handfängsel har tagits av |
| `success.granted_license` | Du har fått en licens |
| `success.grant_license` | Du har utfärdat en licens |
| `success.revoke_license` | Du har återkallat en licens |
| `success.tow_paid` | Du har fått 500 kr i ersättning |
| `success.blood_clear` | Blodet har tagits bort |
| `success.bullet_casing_removed` | Hylsorna har tagits bort |
| `success.anklet_taken_off` | Din fotboja har tagits av |
| `success.took_anklet_from` | Du tog av fotbojan på %{firstname} %{lastname} |
| `success.put_anklet` | Du har fått en fotboja |
| `success.put_anklet_on` | Du satte en fotboja på %{firstname} %{lastname} |
| `success.vehicle_flagged` | Fordonet %{plate} är flaggat för: %{reason} |
| `success.impound_vehicle_removed` | Fordonet är uthämtat från uppställningsplatsen |
| `success.impounded` | Fordonet har bärgats |
| `info.mr` | herr |
| `info.mrs` | fru |
| `info.impound_price` | Avgift för att hämta ut fordonet (kan vara 0) |
| `info.plate_number` | Registreringsnummer |
| `info.flag_reason` | Anledning till flaggningen |
| `info.camera_id` | Kamera-ID |
| `info.callsign_name` | Din anropssignal |
| `info.poobject_object` | Objekttyp att placera, eller ”delete” för att ta bort |
| `info.player_id` | Spelar-ID |
| `info.citizen_id` | Karaktärens citizen-id |
| `info.dna_sample` | DNA-prov |
| `info.jail_time` | Tid i fängelse |
| `info.jail_time_no` | Fängelsetiden måste vara större än 0 |
| `info.license_type` | Licenstyp (driver = körkort, weapon = vapenlicens) |
| `info.ankle_location` | Fotbojans position |
| `info.cuff` | Du är handfängslad |
| `info.cuffed_walk` | Du är handfängslad men kan gå |
| `info.vehicle_flagged` | Fordonet %{vehicle} är flaggat för: %{reason} |
| `info.flagged_vehicle_radar` | Flaggat fordon passerade en ANPR-kamera: %{plate} |
| `info.unflag_vehicle` | Flaggningen av fordonet %{vehicle} är borttagen |
| `info.tow_driver_paid` | Du har betalat bärgaren |
| `info.paid_lawyer` | Du har betalat advokaten |
| `info.vehicle_taken_depot` | Fordonet har bärgats mot en avgift på %{price} kr |
| `info.vehicle_seized` | Fordonet har tagits i beslag |
| `info.stolen_money` | Du har stulit %{stolen} kr |
| `info.cash_robbed` | Du har blivit rånad på %{money} kr |
| `info.driving_license_confiscated` | Ditt körkort har omhändertagits |
| `info.cash_confiscated` | Dina kontanter har tagits i beslag |
| `info.being_searched` | Du kroppsvisiteras |
| `info.cash_found` | Hittade %{cash} kr på personen |
| `info.sent_jail_for` | Personen skickades till fängelse i %{time} mån |
| `info.fine_received` | Du har fått böter på %{fine} kr |
| `info.blip_text` | Polislarm – %{value} |
| `info.jail_time_input` | Fängelsetid |
| `info.submit` | Skicka |
| `info.time_months` | Tid i månader |
| `info.bill` | Böter |
| `info.amount` | Belopp |
| `info.police_plate` | LSPD |
| `info.vehicle_info` | Motor: %{value} % · Bränsle: %{value2} % |
| `info.evidence_stash_prompt` | Bevisförråd |
| `info.evidence_stash` | Bevisförråd · %{value} |
| `info.slot` | Fack nr (1, 2, 3) |
| `info.open` | Öppna |
| `info.current_evidence` | %{value} · Låda %{value2} |
| `info.on_duty` | [E] Gå i tjänst |
| `info.off_duty` | [E] Gå ur tjänst |
| `info.onoff_duty` | ~g~I tjänst~s~ / ~r~ur tjänst~s~ |
| `info.stash` | Förråd %{value} |
| `info.delete_spike` | [~r~E~s~] Ta bort spikmattan |
| `info.close_camera` | Stäng kameran |
| `info.bullet_casing` | [~g~G~s~] Hylsa %{value} |
| `info.casing` | Hylsa |
| `info.blood` | Blod |
| `info.blood_text` | [~g~G~s~] Blod %{value} |
| `info.fingerprint_text` | [G] Fingeravtryck |
| `info.fingerprint` | Fingeravtryck |
| `info.store_heli` | [E] Ställ in helikoptern |
| `info.take_heli` | [E] Ta ut helikoptern |
| `info.impound_veh` | [E] Bärga fordonet |
| `info.store_veh` | [E] Ställ in fordonet |
| `info.armory` | Vapenförråd |
| `info.enter_armory` | [E] Vapenförråd |
| `info.finger_scan` | Fingeravtrycksläsare |
| `info.scan_fingerprint` | [E] Läs av fingeravtryck |
| `info.trash` | Papperskorg |
| `info.trash_enter` | [E] Papperskorg |
| `info.stash_enter` | [E] Öppna skåpet |
| `info.target_location` | Positionen för %{firstname} %{lastname} är markerad på kartan |
| `info.anklet_location` | Fotbojans position |
| `info.new_call` | Nytt larm |
| `info.officer_down` | Skadad polis: %{lastname} · %{callsign} |
| `info.fine_issued` | Ordningsboten har utfärdats |
| `info.received_fine` | Kronofogden har drivit in dina obetalda böter |
| `evidence.red_hands` | Röda händer |
| `evidence.wide_pupils` | Vidgade pupiller |
| `evidence.red_eyes` | Röda ögon |
| `evidence.weed_smell` | Luktar cannabis |
| `evidence.gunpowder` | Krutstänk på kläderna |
| `evidence.chemicals` | Luktar kemikalier |
| `evidence.heavy_breathing` | Andas tungt |
| `evidence.sweat` | Svettas kraftigt |
| `evidence.handbleed` | Blod på händerna |
| `evidence.confused` | Förvirrad |
| `evidence.alcohol` | Luktar alkohol |
| `evidence.heavy_alcohol` | Luktar starkt av alkohol |
| `evidence.agitated` | Uppjagad – tecken på metamfetaminpåverkan |
| `evidence.serial_not_visible` | Serienumret går inte att läsa |
| `hud.fingerprint_id` | Fingeravtrycks-ID |
| `hud.fingerprint_none` | Inget resultat |
| `hud.heli_model` | Modell |
| `hud.heli_plate` | Regnr |
| `hud.heli_speed` | km/h |
| `hud.camera_connected` | Ansluten |
| `hud.camera_failed` | Anslutningen misslyckades |
| `hud.camera_bad_request` | Fel #400: ogiltig begäran |
| `hud.camera_error` | Fel |
| `menu.garage_title` | Polisfordon |
| `menu.close` | ⬅ Stäng menyn |
| `menu.impound` | Bärgade fordon |
| `menu.pol_impound` | Polisens uppställningsplats |
| `menu.pol_garage` | Polisgarage |
| `menu.pol_armory` | Polisens vapenförråd |
| `email.sender` | Kronofogden |
| `email.subject` | Indrivning av böter |
| `email.message` | Hej %{value} %{value2}, /  / Kronofogden har drivit in böterna som du fick av polisen. / <strong>%{value3} kr</strong> har dragits från ditt konto. /  / Med vänlig hälsning / Kronofogden |
| `commands.place_spike` | Lägg ut en spikmatta (endast polis) |
| `commands.license_grant` | Utfärda en licens till någon |
| `commands.license_revoke` | Återkalla någons licens |
| `commands.place_object` | Placera eller ta bort ett objekt (endast polis) |
| `commands.cuff_player` | Sätt handfängsel på en person (endast polis) |
| `commands.escort` | Eskortera en person |
| `commands.callsign` | Ange din anropssignal |
| `commands.clear_casign` | Ta bort hylsor i området (endast polis) |
| `commands.jail_player` | Skicka en person till fängelse (endast polis) |
| `commands.unjail_player` | Släpp en person ur fängelset (endast polis) |
| `commands.clearblood` | Ta bort blod i området (endast polis) |
| `commands.seizecash` | Ta kontanter i beslag (endast polis) |
| `commands.softcuff` | Sätt handfängsel så att personen kan gå (endast polis) |
| `commands.camera` | Visa en övervakningskamera (endast polis) |
| `commands.flagplate` | Flagga ett registreringsnummer (endast polis) |
| `commands.unflagplate` | Ta bort flaggningen av ett registreringsnummer (endast polis) |
| `commands.plateinfo` | Slå på ett registreringsnummer (endast polis) |
| `commands.depot` | Bärga ett fordon mot avgift (endast polis) |
| `commands.impound` | Ta ett fordon i beslag (endast polis) |
| `commands.paytow` | Betala bärgaren (endast polis) |
| `commands.paylawyer` | Betala advokaten (endast polis och domare) |
| `commands.anklet` | Sätt på en fotboja (endast polis) |
| `commands.ankletlocation` | Visa var en persons fotboja finns |
| `commands.removeanklet` | Ta av en fotboja (endast polis) |
| `commands.drivinglicense` | Omhänderta ett körkort (endast polis) |
| `commands.takedna` | Ta ett DNA-prov från en person (kräver en tom bevispåse, endast polis) |
| `commands.police_report` | Larma polisen |
| `commands.message_sent` | Meddelande |
| `commands.civilian_call` | Samtal från allmänheten |
| `commands.emergency_call` | Nytt 112-samtal |
| `commands.fine` | Utfärda en ordningsbot till en person (endast polis) |
| `progressbar.blood_clear` | Tar bort blod… |
| `progressbar.bullet_casing` | Tar bort hylsor… |
| `progressbar.robbing` | Rånar personen… |
| `progressbar.place_object` | Placerar objektet… |
| `progressbar.remove_object` | Tar bort objektet… |
| `progressbar.impound` | Bärgar fordonet… |
| `target.sign_in` | Gå i eller ur tjänst |
| `target.open_personal_stash` | Öppna personligt skåp |
| `target.open_trash` | Öppna papperskorgen |
| `target.open_fingerprint` | Öppna fingeravtrycksläsaren |
| `target.open_armory` | Öppna vapenförrådet |
| `target.open_evidence_stash` | Öppna bevisförrådet |
| `fredpd.no_permission` | Du har inte behörighet att göra det här |
| `fredpd.try_again` | Vänta en stund och försök igen |
| `fredpd.amount_too_high` | Beloppet får vara högst %{max} kr |
| `fredpd.garage_empty` | Det finns inga fordon som du har behörighet att ta ut |
| `fredpd.armory_title` | Vapenförråd – %{armory} |
| `fredpd.armory_count` | Antal: %{count} |
| `fredpd.armory_taken` | Du har kvitterat ut %{count} × %{item} |
| `fredpd.armory_empty` | Det finns inget här som du har behörighet att kvittera ut |
| `fredpd.armory_too_far` | Du är för långt från vapenförrådet |
| `fredpd.armory_full` | Du kan inte bära det |
| `fredpd.armory_limit` | Du bär redan det högsta antalet som du får kvittera ut |
| `fredpd.armory_unavailable` | Vapenförrådet är inte tillgängligt |
| `fredpd.armory_failed` | Utrustningen kunde inte lämnas ut |
| `fredpd.bolo_radar` | Träff på efterlysning: %{plate} passerade %{street} (ANPR-kamera %{radar}) |
