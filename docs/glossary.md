<!-- SPDX-License-Identifier: GPL-3.0-only -->
# FredPD glossary (ordlista)

This file lists the Swedish words FredPD uses in its interface, with an English gloss and notes on how each word is
used. `locales/sv.json` follows it. Task 8.2 checks every string against it.

PLAN §10 (the original glossary) is not in the repository yet. Until it is added, this file is the reference. When
PLAN.md arrives, reconcile the two and keep this file as the detailed version.

Scope: FredPD is roleplay on a Qbox server. Real Swedish police terms are used for flavour and familiarity. Where
real procedure would get in the way of fun, the game simplifies it. IMPLEMENTATION.md §8.9 has the rule: fun wins
over realism. The notes say when FredPD deviates from real practice.

---

## 1. Writing rules for Swedish UI text

| Rule | Example |
|---|---|
| Address the player as **du**. Keep it short and neutral. Don't use exclamation marks. | "Du har inte behörighet att göra det här." |
| **Sentence case.** Capitalise only the first word and proper nouns. | "Ny efterlysning", not "Ny Efterlysning" |
| **Status words agree with the noun's gender.** *Ett larm* and *ett ärende* are neuter; *en efterlysning*, *en surfplatta* and *en insats* are common gender. | Larm: Öppet · Tilldelat · Avslutat. Efterlysning: Aktiv · Återkallad |
| Buttons start with a **verb in the imperative**. Status labels use the **past participle**. | "Återkalla efterlysning" → status "Återkallad" |
| **Swedish quotation marks** ”…” on both sides. | Inga träffar på ”Andersson”. |
| Put the **ellipsis** "…" directly after the word. It marks work in progress. | "Laddar…", "Forcerar dörren…" |
| Write **i dag, i går, i morgon** as two words. Write times as **kl. 14:05**. Write dates as **2026-09-29**, using `formatDate`. | "Utkast sparat kl. {time}" |
| Write **amounts** with `formatCurrency`, which gives a thousands space and "kr". Never write "SEK" or "$". | "Ordningsbot på 1 500 kr" |
| Use a **middle dot** "·" to join short facts and an **en dash** "–" for ranges and grades. | "Tilldelad: IGV-07 · Anna B.", "A – Alltid tillförlitlig" |
| **No plural machinery.** Phrase counts so that the same wording works for 1 and for many. Never put `{count}` before a plural noun. | "Träffar: {count}", "{count} min", "{count} d sedan", not "{count} dagar sedan" |
| **Whole sentences in one key.** Never build a sentence from fragments. Use named `{placeholders}`. | "Det finns uppgifter som rör {subject}. Kontakta {owner}." |
| Officer jargon is fine inside the MDT. Don't use it on the public portal pages (login, allmän handling). | MDT: "slagning", "regnummer". Portal: "sökning", "registreringsnummer" |
| English fallback (`en.json`) uses **British spelling**. | authorised, licence, armoury, offence, analyse |

---

## 2. Organisation, roles and duty

| Svenska (UI) | English | Usage in FredPD |
|---|---|---|
| **Polisen** | the Police | Title for notifications (`common.police`). |
| **polis** | police officer | Gender-neutral. Don't use *polisman*. |
| **enhet** | unit | One of the five units in `config/units.json`. A member's units come from `unit` grants, and the first unit in config order is the **huvudenhet** (primary unit). |
| **ingripandeverksamhet (IGV)** · UI: **Ingripande** | response / patrol policing | Uniformed first responders. Unit code `igv`, callsign prefix `IGV`. Officers usually just say "IGV". |
| **spaning** · colloquial **span** | surveillance | Plain-clothes surveillance. A *spanare* is a surveillance officer. The UI label is **Spaning**, while "span" is fine in chat and docs. Unit code `span`. |
| **utredning** | investigations | Detectives. An *utredare* is an investigator. Unit code `utredning`. |
| **kriminaltekniker** · short **tekniker** | forensic technician | The unit label is **Kriminalteknik**. Unit code `tekniker`. |
| **ledning** | command | The shift and management level. It owns the rosters, tablets, release requests and audit pages. Unit code `ledning`. |
| **vakthavande befäl (VB)** | duty officer | The officer in charge of the shift. This is a role within Ledning. |
| **befäl** | commanding officer | Generic. Don't use it as a rank. |
| **tjänstegrad** | rank | Comes from Discord roles through `perm:rank:<key>` (§4.9). Examples: *polisassistent*, *polisinspektör*, *poliskommissarie*, *polisintendent*. |
| **anropssignal** | callsign | Built from `formats.json → callsign`, for example **IGV-07**. Ledning can edit it. |
| **i tjänst / ej i tjänst** | on duty / off duty | Phrases: *gå i tjänst*, *gå ur tjänst*. **Tjänstgörande** means on duty (adjective), as in *tjänstgörande personal*. |
| **tjänstgöring** | service, duty period | Used in docs and logs, for example "senast i tjänst". |
| **handläggare** · **ansvarig handläggare** | case officer, assignee · lead officer | An officer assigned to an ärende. Assignee roles (`case.assignee.role.*`): **Ansvarig handläggare** (`lead`) and **Handläggare** (`member`). Shown on the POI sheet as "Handläggare". |
| **behörighet** | permission, authorisation | A grant. The portal page is **Behörigheter**. Text pattern: "Du har inte behörighet att …". |
| **personal** | staff, roster | The MDT roster page (`/register`) is labelled **Personal**. |

---

## 3. Cases, reports and records

| Svenska (UI) | English | Usage in FredPD |
|---|---|---|
| **ärende** | case | Numbered by `caseNumber`, for example **K-123-26**. Verbs: *upprätta* (open), *avsluta* (close), *återöppna* (reopen). Status: Öppet / Avslutat. |
| **ärendenummer** | case number | |
| **anmälan** | crime report | The report of a crime, from a victim or an officer (*polisanmälan*). It is one report kind. |
| **rapport** | report | Any written report attached to an ärende. Verb: *registrera rapport*. Number: `reportNumber`, for example **K-123-26/2**. |
| **PM** (promemoria) | memo | An internal memo. It is one report kind. |
| **utkast** | draft | A report draft. Autosaved while the editor is focused and changed (§5.3). |
| **inblandad** | involved party | A person or vehicle linked to an ärende. Roles: **misstänkt** (suspect), **målsägande** (injured party / victim), **vittne** (witness), **övrig** (other). |
| **förundersökning (FU)** | preliminary investigation | The formal investigation, led by police or a prosecutor (*åklagare*). Not modelled in FredPD; mentioned for context only. |
| **brottskatalog** | offence catalogue | The `fredpd_charges` table: code, offence, **kategori**, **lagrum**, **påföljd**, **bötesbelopp**, prison time. |
| **kategori** (brottskatalog) | category | Groups the catalogue (`charge.category.*`): **Brottsbalken** (`penal`), **Trafik**, **Narkotika**, **Vapen**, **Allmän ordning** (`public_order`), **Övrigt**. |
| **lagrum** | statute reference | For example "3 kap. 5 § BrB". |
| **brott** | offence | A row in the brottskatalog. Real Swedish law grades offences as *ringa / normalgraden / grovt*; in FredPD that grade is part of the offence's name ("Ringa misshandel", "Grov stöld"), not a separate field. |
| **påföljd** | penalty, sanction | The class of a charge (`charge.class.*`, column `class`): **Ordningsbot** (`ordningsbot`), **Böter** (`bot`) or **Fängelse** (`fängelse`, key `charge.class.fangelse`). See §8. |
| **belastning** (status) | applied charge | A row in `fredpd_records`. Status (`charge.status.*`): **Utfärdad**, **Betald**, **Avtjänad**, **Återkallad**. |
| **belastningsregister** | criminal record | The person page section that lists applied charges. "Inga belastningar." |
| **POI-blad** | person-of-interest sheet | A printable summary of a person, marked "Internt – får inte spridas". |
| **slagning** · verb **slå på** | lookup (in a register) | Every person or vehicle lookup is a slagning and is audited. Officer jargon, so use it in the MDT only. |
| **obehörig sökning** | unauthorised search | A lookup with no service reason. The system flags an officer after N lookups on the same subject with no linked case or alert. N is set in config and defaults to 3 (task 5.6; `config/integrations.json → unauthorizedLookupThreshold`). |
| **logg** · **loggkontroll** | audit log · log review | The `fredpd_audit` table, shown on the **Loggar** page. |

---

## 4. Secrecy and visibility

| Svenska (UI) | English | Usage in FredPD |
|---|---|---|
| **sekretess** | secrecy, confidentiality | The classification stays after a case is closed (§8.7). |
| **sekretessnivå** | classification, clearance | `level` on a record and `intel_tier` on a viewer. There are three levels: **Standard** (0), **Begränsad** (1) and **Hemlig** (2). The level is a *requirement*: it never widens access. Who sees what is decided by the visibility rules (for example, an open ärende is full for assigned officers and the owning unit and a kontaktnotis for everyone else), and the level then caps the result. |
| **Standard** | standard / unclassified | No clearance required. The visibility rules alone decide access. |
| **Begränsad** | restricted | Requires clearance Begränsad or Hemlig. A viewer below that who is not assigned, owner or handler (and lacks `intel.command`) gets at most a kontaktnotis. |
| **Hemlig** | secret | Requires clearance Hemlig. Other viewers get at most a kontaktnotis, with the same exceptions as Begränsad. |
| **kontaktnotis** | contact notice | The `notice` result: the viewer learns that the record exists and whom to ask. The fixed text is "Det finns uppgifter som rör {subject}. Kontakta {owner}." |
| **maskera · maskerad · [Maskerat]** | mask / redact | The `masked` result. Parts above the viewer's level and all source fields are removed. |
| **full insyn** | full access | The `full` result. |
| **dold** | hidden | The `none` result. The UI behaves as if the record does not exist. |

Real Swedish security classification has four levels: *begränsat hemlig*, *konfidentiell*, *hemlig* and *kvalificerat
hemlig*. FredPD's three levels are its own scale. Don't mix the real names into the UI.

---

## 5. Alerts, operations and BOLOs

| Svenska (UI) | English | Usage in FredPD |
|---|---|---|
| **larm** | alert, dispatch call | Created by ps-dispatch or `createAlert`. Status: Öppet / Tilldelat / Avslutat. |
| **Ta larm** | take alert | The keybind (default G). It assigns you to the newest open larm and sets a **vägpunkt** (waypoint). Other officers then see "Tilldelad: {callsign} · {name}". |
| **tilldelad** | assigned | Used for alerts and cases. |
| **uppdrag** | task, assignment | Loose dispatch talk ("vi har ett uppdrag"). Not used as a UI label, so that it does not clash with *larm* and *insats*. |
| **insats** | operation, mission | A planned operation (`fredpd_missions`), usually run by Spaning. It has an **insatsledare** (lead) and **deltagare** (members). Status: Pågående (`open`) / Avslutad (`closed`). |
| **efterlysning** | BOLO, wanted notice | A wanted notice for a person or a vehicle. Verbs: *efterlys* (button) or *utfärda*, and *återkalla* (resolve). Status: Aktiv / Återkallad / Utgången. A **träff på efterlysning** is a BOLO hit. |
| **efterlyst** | wanted | Badge on a person or vehicle. |
| **skyltkontroll** · **Kontrollera registreringsskylt** | plate check | The ox_target option on vehicles. |
| **ANPR-kamera** | ANPR camera | The qbx_police radar feed (§3.3). |
| **prioritet** | priority | Hög / Normal / Låg, from `fredpd_alerts.priority` 1 (or 0) / 2 / 3 and higher. |
| **regionledningscentral (RLC)** | regional dispatch centre | Context only. The UI says "larm", not "RLC". |

---

## 6. Evidence and forensics

| Svenska (UI) | English | Usage in FredPD |
|---|---|---|
| **spår** | trace | Something found at a scene: fingerprints, blood, tool marks. It becomes a **bevis** once it is secured and registered. |
| **bevis** | evidence | A registered item (`fredpd_evidence`). **Bevisnummer** is the evidence tag, for example **B-K-123-26-004**. |
| **säkra** · **säkrat av** | collect, secure | The first link in the beviskedja. |
| **beviskedja** | chain of custody | Entries: säkrat → inlämnat (bevisförråd) → analyserat → kopplat till ärende (§5.7). |
| **bevisförråd** | evidence locker | The station stash. |
| **kriminaltekniskt labb** · **analysera** | forensic lab · analyse | The station lab zone. |
| **fingeravtryck** | fingerprint | |
| **DNA** | DNA | |
| **blod** | blood | |
| **hylsa** · **projektil** | cartridge case · projectile (bullet) | From shootings. Casings are generated automatically by the evidences resource. |
| **verktygsspår** | tool mark | For example at a forced door. |
| **beslag** · **ta i beslag** | seizure · seize | Property seized by the police. It may also be evidence, but beslag is a legal act and not a type of evidence. Not modelled before Phase 4+. Don't use it as a synonym for *bevis*. |

---

## 7. Intelligence

| Svenska (UI) | English | Usage in FredPD |
|---|---|---|
| **underrättelse(r)** | intelligence | The MDT section **Underrättelser**. An *underrättelserapport* is an intel report. |
| **källa** | source (informant) | `fredpd_intel_sources`. Has a **kodnamn** (codename). The **verklig identitet** (true identity) is shown only to the handler or intel command. Status: Aktiv (`open`) / Avregistrerad (`closed`). |
| **källhantering** | source handling | The practice of running sources. |
| **källhanterare** | handler | The officer responsible for a källa (perm `intel.handler`). |
| **underrättelseledning** | intelligence command | perm `intel.command`. |
| **tillförlitlighet A–D** | reliability grade | A – Alltid tillförlitlig, B – Oftast tillförlitlig, C – Ibland tillförlitlig, D – Otillförlitlig eller oprövad. |
| **koppling** · **nätverk** | link · network (graph) | Graph edges and the graph tab. |
| **objekt** | entity | A person, vehicle, place (*plats*), group (*gruppering*) or case in the intel graph. |
| **gruppering** | group, gang | Swedish police usage for a criminal group. |

---

## 8. Sanctions

| Svenska (UI) | English | Usage in FredPD |
|---|---|---|
| **ordningsbot** | fixed penalty notice | Issued on the spot by the police for minor offences. Billed through qbx_police. Button text: "Utfärda ordningsbot". Påföljd (charge class) `ordningsbot`. |
| **strafföreläggande** | summary penalty order | Issued by a prosecutor and accepted by the suspect. In game it is a sanction type for more serious fines. |
| **böter** · **bötesbelopp** | fine · fine amount | Amounts in kr, formatted with `formatCurrency`. Real *dagsböter* (day-fines) are not modelled. Påföljd `bot` (böter through strafföreläggande or court) is labelled **Böter**. |
| **fängelse** | prison | Påföljd `fängelse`. Time is shown in **mån** (in-game months), for example "Total fängelsetid: 12 mån". `jail_min` is stored in minutes and shown one minute to one month, the usual FiveM convention (ASSUMED until the jail module confirms it). |
| **varning** | warning | For example a warning on a driving licence. **Sweden has no licence-points system**, so never write *prickar* or *poäng* (§8.7). |
| **återkallelse** · **återkalla** | revocation · revoke | Revoking a **körkort** or **vapenlicens**. Also the verb for resolving an efterlysning. |
| **gripa · gripande** | arrest | Use *gripen*, not *arresterad*. For context: *anhålla* is a prosecutor's decision and *häkta* is a court's decision. |
| **omhänderta** | take into custody | For example a drunk person (LOB). Context only. |

---

## 9. People and vehicles

| Svenska (UI) | English | Usage in FredPD |
|---|---|---|
| **personnummer** | personal identity number | Format `YYMMDD-XXXX` or `YYYYMMDD-XXXX`. The search box accepts either form, with or without the dash (§4.8). |
| **registreringsnummer** · colloquial **regnummer**, **regnr** | registration number | Swedish format **ABC 12D** (`formats.json → plate`). A **skylt** is a plate. |
| **fordonsägare** · UI label **Ägare** | registered owner | "Ägare saknas i registret" for unregistered vehicles. |
| **Ute · I garage · Bärgad** | out · garaged · impounded | qbx_vehicles state 0 / 1 / 2. |
| **körkort** · **vapenlicens** | driving licence · firearms licence | The formal Swedish term is *vapentillstånd*. The UI uses the everyday word *vapenlicens*. Status words follow the gender: *ett körkort* is **Giltigt** / **Återkallat**, *en vapenlicens* is **Giltig** / **Återkallad**, so each licence type has its own status keys. |
| **karaktär** · **rollspelskaraktär** | character, roleplay character | The in-game identity (citizenid). An officer's *displayed* name comes from Discord, not from the character (§4.9). |

---

## 10. Equipment, doors and the tablet

| Svenska (UI) | English | Usage in FredPD |
|---|---|---|
| **surfplatta** | tablet | Item `pd_tablet`. Verbs: *spärra* (revoke) and *häv spärren* (reinstate). Fields: **serienummer** and **innehavare** (holder). Don't use "tabletten" or "paddan". |
| **fordonsdator** | vehicle terminal | The MDT opened from a police vehicle. |
| **murbräcka** | battering ram | Item `pd_ram`, grant `tool:ram`. |
| **forcera dörr** · **dörrforcering** | breach a door · door breach | The ox_target option "Forcera dörr". Each breach is audited. |
| **husrannsakan** | house search | The legal basis for a real door breach. Context only; FredPD does not model warrants. |
| **vapenförråd** | armoury | Grant type `armory`. |

---

## 11. Portal and public access

| Svenska (UI) | English | Usage in FredPD |
|---|---|---|
| **portalen** · **Polisportalen** | the portal | The web app. Button text: **Logga in med Discord**. |
| **välj karaktär** | choose character | Picked after login. The officer identity is the chosen citizenid. |
| **integritet** | privacy | The privacy notice on the login page (GDPR, §8.8): what is processed, the {days}-day log retention (90 by default), and how to ask for access or deletion. |
| **allmän handling** | public document | A player can **begära ut** (request) one. An officer **prövar** (reviews) the request and then **lämnar ut** (releases), **lämnar ut med maskering** (releases with masking) or **avslår** (refuses). The page is **Utlämnanden**. |
| **offentlighets- och sekretesslagen (OSL)** | Public Access to Information and Secrecy Act | Cited when information is masked. |
| **delningslänk** | share link | Always has an expiry date. Every view is logged (§4.6). |

---

## 12. Words to avoid

| Don't write | Write instead | Why |
|---|---|---|
| BOLO, APB | efterlysning | English jargon. |
| prickar, poäng (on a licence) | varning, återkallelse | Sweden has no points system. |
| arrestera, arresterad | gripa, gripen | Swedish police usage. |
| polisman | polis | Gender-neutral. |
| case, dispatch, callout | ärende, larm | Swedish product language. |
| tabletten, paddan | surfplattan | Consistent item name. |
| raid | insats, dörrforcering | English jargon. |
| felony, misdemeanour, infraction (as a charge class) | the påföljd: ordningsbot, böter, fängelse | FredPD classes charges by påföljd; the grade (ringa, grov) is part of the offence's name. |
| real classification names (konfidentiell, kvalificerat hemlig) | Standard, Begränsad, Hemlig | FredPD's own three-level scale. |
