<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Module: fredpd_intel (Phase 5b server, task 5b.1)

Sources (källor), intel reports, entity graph and missions (insatser). Implements IMPLEMENTATION.md §5.8 and
docs/contracts.md §C15 over `db/migrations/007_intel.sql` (no new migration: missions reach entities through
link → report → mission, see "Notices"). No new visibility rules: `db/seed/visibility_rules_default.sql` already
covers `mission` (60–62), `intel_report` (70–72) and `intel_source` (80–82).

## Files

| File | Role |
|---|---|
| `fxmanifest.lua` | server only; ox_lib, oxmysql, fredpd_core |
| `shared/input.lua` | Lua mirror of every INTEL_ACTIONS input schema (trim, lengths in code points, defaults, unions), `likePrefix`, `entityRef` |
| `server/store.lua` | all SQL (007 tables + read-only fredpd_officers / fredpd_persons / fredpd_vehicles_idx / fredpd_cases); UTC via `Time.isoSelect` |
| `server/access.lua` | pure: VisRecords, `min` of two views, OfficerRef, kontaktnotis, paging |
| `server/service.lua` | the action handlers, graph BFS, notices |
| `server/main.lua` | exports + `playerDropped` |
| `test/contract.test.ts`, `test/golden/*.json` | golden JSON (written by `intel_server_test.lua`) parsed with the intel.ts zod schemas |

Tests: `tests/lua/intel_input_test.lua` (8), `intel_access_test.lua` (6), `intel_server_test.lua` (20, MariaDB
`fredpd_test_intel_lua`, sessions at `+02:00`), Vitest `contract.test.ts` (24). 34 Lua tests in total.

## Exports

Every INTEL_ACTIONS name is an export `(src, input) → { ok = true, data } | { ok = false, error }` (§C12):
`listSources getSource createSource updateSource listIntelReports getIntelReport createIntelReport searchEntities
ensureEntity getEntity addLink getGraph listMissions getMission createMission addMissionMember closeMission`.
§4.3 names: `addSource` (= createSource), `addReport` (= createIntelReport), `addLink`, `getGraph` — which also
accepts the §4.3 form `getGraph(entityId, viewerSrc)` (two numbers → depth 1). Plus
`getPersonNotices(src, citizenid) → Notice[]` (plain array, empty on any error).

Handler order (§4.6): src is an integer ≥ 1 → grant from INTEL_ACTIONS → on duty (`isOnDuty`) → character
(`getCitizenId`) → input validated again (`shared/input.lua`) → rate limit → work under `pcall` (`unavailable`).
Rate limits on top of the dispatcher's: writes 500 ms, `getGraph` 250 ms per player (`Service.configure`).
Errors are only MDT_ERROR_CODES; a taken codename, a closed mission, a level above the actor's tier, a non-officer
member, an unknown `realCitizenid` → `validation`.

The actor is never taken from input: source handler, report author, mission lead, link/entity creator and
member `added_by` are the caller's citizenid (unknown input keys are dropped by the validator; tested).

## Visibility (§C3, §C15)

| Record | VisRecord |
|---|---|
| source | `intel_source`, `handlerCitizenid` = handler, level, unit (handler's primary unit at creation), status |
| mission | `mission`, `ownerCitizenid` = lead, `assignees` = lead + members, level, unit, status |
| report | `intel_report`, `ownerCitizenid` = author; mission-bound: `assignees` = lead + members, `unit` = mission unit |
| link | `intel_report` record with level = max(link, report), status/owner from the report (else the creator), assignees = creator + mission lead/members |

- **Decision: mission cap.** A mission-bound report (and a link on it) is `min(report view, mission view)`. Default
  rules give intel.read + tier ≥ level `full` on reports; without the cap a Span analyst outside a Hemlig insats
  would read its reports. With it they stay with members, the lead and intel.command (§5.8 "strict for missions").
- `none` → `not_found`, identical to a missing id, for reads and writes (a write on a record you cannot see).
  `notice` → `{ visibility: 'notice', contact: { displayName, unit } }` of the owner/lead (report in a mission: the
  mission lead and unit; source: the handler). A visible record the caller may not change → `unauthorized`.
- Links are shown for `full` and `masked`; masked links drop `createdBy` and `reportId`.
- Level rule (as §C14): a source/report/link/mission level above the actor's tier is refused unless intel.command.

### Sources

- `realIdentity` only when the view is `full` **and** (caller is the handler with perm `intel.handler`, or perm
  `intel.command`) — checked again on top of canView's hard cap 1. Every response carrying it is audited
  `intel.source.identity` (`meta.via` = get/create/update). **Lists never carry it** (`realIdentity` null); the UI
  must call `getSource`.
- `updateSource` needs perm `intel.handler` (INTEL_ACTIONS) and being the handler, or intel.command **and**
  intel.handler: intel.command alone is refused by the grant column. Change for 5b.2 if command should edit.
- `createIntelReport` with `sourceId`: only the source's handler or intel.command; the source must be open.
  A report shows `source: { id, codename }` only when the viewer's source view is at least masked.

### Reports

- Every response carrying the body of a level-2 report is audited `intel.report.read` (`meta.via` = get/list), one
  row per report. The author's own create response is not a read. Mission pages and entity pages list reports
  without bodies (not audited).
- `missionId`: the caller must see the mission `full` (member, lead, intel.command) and it must be open.
- `listIntelReports` filters are checked like reads of the filtered record: `sourceId`/`missionId` unknown or `none`
  → `not_found`; seen only as `notice` → empty page (total 0). With `sourceId`, only reports the viewer sees `full`
  (the ones that show their `source`) match, so reports are never grouped by a source the viewer cannot see.
- Notice-only reports in a list collapse to one kontaktnotis per contact (mission lead + unit, or a standalone
  report's author): a list never counts or dates a secret insats's reports.

### Entities

- `ensureEntity` dedups on `uq_type_ref`; keyless locations/groups dedup by label. Keyed refs are validated and the
  label is derived server-side (client label ignored): person → `fredpd_persons` "Förnamn Efternamn", vehicle →
  `fredpd_vehicles_idx` "PLATE (model)", case → `fredpd_cases` case number only (never the title), and only if the
  caller's case view is `full` or `masked` (`notice` answers `not_found`, like a missing case: no probing of case
  numbers). Malformed ref → `validation`, unknown record → `not_found`. A renamed person is
  relabelled on the next ensure (audited `intel.entity.relabel`). Every ensure of an existing person/vehicle is a
  lookup and is audited `intel.entity.view` (`meta.via = 'ensure'`); a new one is audited `intel.entity.create`.
- Case entities (label = case number) are hidden from a viewer whose case view is not `full`/`masked` — `none` or
  `notice` (a case kontaktnotis never carries the case number, as in fredpd_records' caserefs; with the default
  rules 14 + hard cap 2 a Hemlig case is `notice` for everyone off it); case row gone counts as `none`: dropped from `searchEntities`, `not_found` from `getEntity`/`getGraph` as root and as an `addLink` end,
  and links to them count as hidden (`hiddenLinks`, graph, report links). Batched: one cases query, one assignees
  query, one `canViewMany`, only when case entities are involved.
- `searchEntities`: `label LIKE ? ESCAPE '!'` prefix with `! % _` escaped, bound as a parameter, limit 25. Entities
  carry no level; what is hidden are the links and reports around them. A result containing person/vehicle
  entities is a lookup: one `intel.entity.search` audit row per call (`meta = { query, type, entityIds }`).
- `getEntity`: visible links newest first (≤ 500 considered), `hiddenLinks` = all links touching − visible (no
  details), `reports` = visible reports behind the *visible* links only (meta only; a hidden link is never tied to
  a report), `notices` (below).
- `addLink` runs every read-only check first — `from` exists, the `to` end (by id, or keyed ref validated and an
  existing entity looked up without writing), neither is a hidden case (`not_found`), then `from ≠ to`
  (`validation`), report visible, would-be link visible (creator = caller, level, report/mission) — and only then
  creates a new `to` entity and the link: any error answer leaves no row and no audit. An identical stored link the caller can see is returned
  instead of a new row. Person/vehicle
  views are audited `intel.entity.view` (§4.5 lookups).

### Notices (kontaktnotis)

A mission touches an entity when a link touching it carries a report of that mission. `getEntity` and
`getPersonNotices` return one notice per mission the caller sees only as `notice`, plus standalone reports touching
the entity seen as `notice`, deduplicated by contact. `getPersonNotices` needs only an on-duty officer (no intel
grant: an IGV on the person page must get the kontaktnotis, §5.8); unknown person → `[]`.

### Graph

BFS from the root to depth 1|2 over visible links only; per level one UNION query for the whole frontier
(`linksTouching`, ≤ 2000 links, newest first), one members query, one `canViewMany` and one entity query for the
new ends (hidden case entities are dropped with their links). Nodes capped at 150 (root first, `root: true`); a node
that did not fit, or a level with more than 2000 links, sets `truncated`. Edges only between included nodes.
Measured: depth 1 over 200 neighbours ≤ 4 queries, 1 `canViewMany`.

### Missions

`createMission` needs intel.command (lead = caller, unit = input or the caller's primary unit).
`addMissionMember` / `closeMission`: grant intel.read, then the lead or intel.command; members must exist in
`fredpd_officers`; closed missions take no members/reports; a second close is a no-op (not audited).

## Audit actions

`intel.source.create|update|identity`, `intel.report.create|read`, `intel.entity.create|relabel|view|search`,
`intel.link.create`, `mission.create|close|member.add|member.role`. Target types `intel_source`, `intel_report`,
`intel_entity`, `intel_link`, `mission`.

## Locale

No player-facing strings are produced server-side (errors are codes; labels are record data), so no
`locales/pending/intel.json`. The NUI keys `intel.*` already exist in `locales/sv.json`.

## UNVERIFIED (FiveM runtime)

- Exports run in a thread so `MySQL.*.await` works (same assumption as fredpd_forensics/dispatch).
- `exports.fredpd_core:canViewMany(src, records)` with nested `assignees` arrays survives the msgpack hop unchanged.
- An empty Lua table in a response (`links`, `notices`) arrives as `[]` (the golden files assume it).
- Nullable fields that are nil are absent on the wire (contract test restores them; a strict consumer must too).

## Integration requests

1. **fredpd_mdt** (`server/dispatch.lua`): merge INTEL_ACTIONS with routes `{ 'fredpd_intel', <name> }`; grants as in
   intel.ts; limits `write` for createSource, updateSource, createIntelReport, ensureEntity, addLink, createMission,
   addMissionMember, closeMission; `read` for the rest (getGraph ideally ≥ 500 ms).
2. **fredpd_records** `getPersonSummary`: call `exports.fredpd_intel:getPersonNotices(src, citizenid)` (guard with
   `GetResourceState('fredpd_intel') == 'started'`) and show the notices on the person page.
3. **apps/service** portal intel routes: answer 404 for `not_found` and for missing `intel.read` (§C15).
4. **docs/contracts.md** owner: record the mission cap for mission-bound reports/links, "lists carry no real
   identity", and that `updateSource` requires intel.handler even for intel.command.
