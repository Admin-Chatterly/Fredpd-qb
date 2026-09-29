<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Module: grants + canView (tasks 1.3 / 1.5, pure part)

Implements docs/contracts.md §C2 and §C3. The TS and Lua versions have identical semantics and run the same
fixture files.

| Part | TS (`@fredpd/types`) | Lua (`fredpd_core/shared`) |
|---|---|---|
| Grants | `src/grants.ts`: `GRANT_TYPES`, `GrantTypeSchema`, `GrantEffectSchema`, `IntelTierSchema`, `GRANT_KEY_PATTERN`, `GrantKeySchema`, `RoleRowSchema`, `RoleGrantRowSchema`, `ResolveInputSchema`, `GrantStringSchema`, `GrantRankSchema`, `GrantSetSchema`, `resolveGrants(input, now?)`, `hasGrant(set, type, key)`, `emptyGrantSet(now?)` | `grants.lua`: `M.resolve(input, now?)`, `M.has(set, type, key)`, `M.empty(now?)`, `M.TYPES`, `M.byteLess` |
| Visibility | `src/canView.ts`: `VISIBILITY_RESULTS`, `VisibilityResultSchema`, `VisRecordTypeSchema`, `ViewerConditionSchema`, `VisRecordSchema`, `ViewerSchema`, `VisibilityRuleSchema`, `canView`, `visibilityRank`, `capResult`, `applyHardCaps`, `ruleApplies`, `conditionHolds` | `canview.lua`: `M.evaluate(viewer, record, rules)`, `M.rank`, `M.cap`, `M.applyCaps`, `M.ruleApplies`, `M.conditionHolds`, `M.RESULTS` |
| Fixtures | `test/fixtures/grants.fixtures.json` (36 cases, 2 unvalidated cases), `test/fixtures/canView.fixtures.json` (37 seed rules, 44 cases, 26 engine cases, 17 unvalidated cases) | `tests/lua/grants_test.lua`, `tests/lua/canview_test.lua` |
| Seed | `db/seed/visibility_rules_default.sql` (a TS test parses it and asserts it equals the fixture `rules`) | |

`now` is optional (a `Date` in TS, unix seconds in Lua) so tests get a fixed `computedAt`. TS writes milliseconds
(`toISOString()`), Lua writes seconds; both pass `GrantSetSchema` (`z.iso.datetime()`).

## Grant resolution decisions (where §C2 leaves room)

- **Held roles**: a role counts only if it is in `memberRoleIds`, is present in `roles`, and is not deleted. Rows of
  a role id missing from `roles` are ignored (the FK should prevent them anyway). Lua also reads `deleted` 0/1.
- **Grant keys are ASCII identifiers**: `GRANT_KEY_PATTERN` = `[A-Za-z0-9_.:*-]{1,64}` (grant_key is VARCHAR(64)).
  `RoleGrantRowSchema.grantKey` and the key part of `GrantStringSchema` use it, so the admin API (§C10, which
  validates with these schemas) rejects whitespace, control characters and non-ASCII keys at write time. Every key
  used in the repo fits; rank display names come from the Discord role, so the key is `rank:inspektor`, not
  `rank:inspektör`. This also keeps TS code-unit order and Lua byte order identical.
- **Invalid rows** (unknown `grantType` or `effect`, missing key or a key outside the pattern) are skipped in both
  ports, so DB or JSON input cannot inject odd strings and `resolveGrants` output always passes `GrantSetSchema`
  (a seeded random TS test checks this for schema-valid input; fixture `unvalidatedCases` for invalid rows). A deny
  row with an invalid key is skipped too; no valid key could match it anyway.
- **`grants`** = allow rows not denied exactly or by their type's wildcard. A wildcard allow survives an exact deny
  (`weapon:*` stays; `weapon:rifle` is in `denied`), so always ask `hasGrant`, never `grants.includes`.
- **`tier`**: keys matching `^-?\d+$`, clamped to 0..2, max over allowed keys. `intel_tier:*` and other
  non-integers (`abc`, `1.5`, `0x2`) do not raise the tier (hemlig needs an explicit grant), although
  `hasGrant(set, 'intel_tier', '2')` is true for a wildcard. Use `tier`, not `hasGrant`, for tier checks.
- **intel_tier deny works by tier value.** Because keys are clamped, `5`, `02` and `2` all mean tier 2. A deny of
  any integer intel_tier key denies every allowed intel_tier key that parses to the same tier: `deny intel_tier:2`
  drops `allow intel_tier:5` / `02` / `3` (from `grants` and from `tier`), and `deny intel_tier:5` drops
  `allow intel_tier:2`. Without this, a second spelling of the same tier would bypass the deny (review finding).
  A deny only blocks its own tier value: `deny intel_tier:1` does not block `allow intel_tier:2`.
- **`units`**: `unit:*` adds no units (it passes `hasGrant` only). Order: position in `unitOrder` (first occurrence
  wins for duplicates), then unknown units in byte/code-unit order.
- **`rank`**: from allowed `perm:rank:<key>` rows; `rank:*` and `rank:` are not ranks and `perm:*` gives none.
  Highest role `position` wins; ties: lower `roleId` (string order), then lower key.
- **Sorting** uses code-unit order in TS and byte order in Lua (`M.byteLess`; Lua's `<` is locale dependent).
  Identical for ASCII keys, which is what grant keys should be.
- **Wire shape**: Lua cannot hold JSON null, so a Lua-encoded set has no `rank` key; `GrantSetSchema` reads a
  missing `rank` as `null`. Lua sorts and dedupes, so empty lists encode as `[]` with rxi/json.lua.
- `hasGrant` accepts any `{ grants, denied }` (`GrantLists`), so partial sets work; a missing set, or one without a
  `grants` array, is false, and a missing `denied` list denies nothing (as in Lua). Lists must be arrays; a string
  never matches by substring.
- FiveM client Lua may lack `os.date`; `grants.lua` then stamps `1970-01-01T00:00:00Z` (clients only call `M.has`).

## canView decisions

- Evaluation and hard caps exactly as §C3. Caps only lower a result (`capResult` = min).
- A `null` or `''` citizenid is "no identity": it never matches an owner, assignee or handler (so `null` does not
  equal a `null` owner).
- `conditionValue` is read literally as in §C3: only NULL falls back to `record.unit` for `unit`; `''` names no unit
  and never matches. `perm` with NULL or `''` never matches, not even for `perm:*` (a key-less `hasGrant` is
  undefined in §C3; fail closed). **The rule-write path (future portal rules editor / admin API) must normalise `''`
  to NULL** so that an empty form field means "the record's unit".
- A rule with an unknown `viewerCondition` or `result` never matches (future DB values fail closed).
- **`VisibilityRuleSchema.recordType` is any 1–32 character string** (§C3 types it `string`; record_type is
  VARCHAR(32)). `'*'` matches every type; a type canView does not know (an admin typo, a future type) is accepted
  and never matches, exactly as in Lua. So the service can parse the whole rules table with the schema (after
  mapping TINYINT `enabled` to boolean) without one bad row throwing away every rule. `viewerCondition`,
  `recordStatus` and `result` stay enums: the DB columns are ENUMs with the same values.
- **Unvalidated input fails closed identically in both ports** (canView is the portal's security gate and may get
  DB rows cast to `VisRecord`/`VisibilityRule` without parsing): a record `level` other than 0/1/2 (null, missing,
  -1, 3, `'1'`) counts as 2; a viewer `tier` other than 0/1/2 counts as 0; a non-string or empty `citizenid` is no
  identity; `units`/`assignees`/grant lists must be arrays (no substring matches); a non-string `conditionValue` is
  NULL; `enabled` is `true`, `1` or `'1'`. Fixture `unvalidatedCases` pins each of these for both suites; a
  TS⇄Lua differential run over 20,000 random malformed canView inputs and 5,000 malformed grant inputs found no
  mismatch.
- `canview.lua` does `pcall(require, '@fredpd_core.shared.grants')` first and falls back to
  `require 'shared.grants'`. ox_lib resolves bare names against the *calling* resource, so a resource that loads
  canview and ships its own `shared/grants.lua` would otherwise bind the wrong module. The qualified name works in
  every resource (fredpd_core included); the bare name is only reached in `tests/lua` (plain `package.path`).
  UNVERIFIED in FiveM: ox_lib `require` of `@fredpd_core.shared.grants` from fredpd_core itself.

## Default rules (`db/seed/visibility_rules_default.sql`)

Priorities: 100 perm override · 95 BOLO level 0 · 90 assigned/handler · 80 unit · 70 tier_gte · 60 intel.read ·
50 disabled example · 10 fallback. Ids are grouped per type (case 10–19 … intel_source 80–89).

| Type | Rules (first match wins) | Else |
|---|---|---|
| case, report, evidence | `records.admin` full · assigned full · open + unit full · closed + tier_gte masked | notice |
| case (id 15, **disabled**) | open + any masked (example: loosen open cases from notice to masked) | |
| poi | `records.admin` full · assigned · unit · tier_gte full | notice |
| bolo | `records.admin` full · level 0 any full · assigned · unit · tier_gte full | notice |
| mission | `intel.command` full · assigned (members/lead) full | notice |
| intel_report | `intel.command` full · assigned (author) full · `intel.read` full | none |
| intel_source | `intel.command` full · handler full · `intel.read` masked | none |
| `*` (id 999, **disabled**) | id sentinel: any → none, priority -1000 (see "Id reservation") | |

### OPEN contract question (review accepted option (a); docs/contracts.md §C3 text still to be amended)

§C3 says intel reports are "author/assigned and (`intel.read` + tier_gte) → full, else none". Rules have one
condition and no negation, so "intel.read AND tier_gte" cannot be written: with single-condition first-match rules,
any rule that gives `full` to (intel.read, tier ≥ level) also matches either (intel.read, tier < level) or
(no intel.read, tier ≥ level). The shipped seed uses rule 72 `intel.read → full`; hard cap 2 then gives a viewer
with `intel.read` and a tier below the report's level **`notice`, not `none`** (they learn the report exists and
whom to contact). Fixture case 41 pins this and is named "OPEN contract question". Options:

- (a) Accept `notice`: amend the ASSUMED §C3 text. No code change.
- (b) Add a viewer condition that combines perm and tier (e.g. `perm_tier` = `perm` AND `tier_gte`) to §C3, the
  engines, the `viewer_condition` ENUM in `001_core.sql` and the schemas; seed `intel_report perm_tier intel.read →
  full`. Matches the text exactly. Recommended if existence of Begränsad/Hemlig reports must stay hidden.
- (c) Fail closed within the current contract: replace rule 72 by `intel_report level=0 perm intel.read → full`, so
  levels 1–2 are reachable only when assigned or with `intel.command`. Too strict for cleared analysts.

Status: the module review accepted (a). The orchestrator amends the §C3 intel-report sentence (e.g. "author/assigned
→ full; intel.read → full (hard cap 2 lowers it to notice when tier < level); else none"); then drop the "OPEN"
wording from fixture case 41, the comment above rule 72 and this heading. Option (b) would be a separate
cross-module task.

Other deviations from the ASSUMED text in §C3, all consistent with the rule language:

- `intel.command → full` was added for intel reports and sources (§C3 lists it only for missions), matching
  cap 1 and the §5.8 story "real identity … or intel.command".
- `records.admin` is still subject to hard cap 2: a tier-0 admin sees a level-1 case as `notice`.
- **Missions count as intel**: `records.admin` gets no mission rule (§C3 "everything but intel"; fredpd_missions
  belongs to fredpd_intel, and the §C3 mission text says "others → notice"). Only members (assigned) and
  `intel.command` get `full`; fixture case "mission: records.admin tier 2, not a member" pins `notice`.
- Report/evidence/poi/bolo rules are not in §C3; they follow "permissive for IGV lookups".

The seed is `INSERT … ON DUPLICATE KEY UPDATE id = id` with explicit ids: re-running adds missing rows and keeps
admin edits, while still failing loudly on bad values (unlike `INSERT IGNORE`). The table is defined in
`db/migrations/001_core.sql` (`fredpd_visibility_rules`); the seed was verified against it on MariaDB 10.11 with
`node scripts/migrate.mjs --seed` (37 rows, 35 enabled). A manual re-apply kept an admin edit (`enabled = 0`) and put
back a deleted default, and the first admin-inserted rule got id 1000.

**Default rules (ids 1–999) are switched off with `enabled = 0`, never deleted.** The runners (`scripts/migrate.mjs`,
`server/db.lua`) re-apply the seed whenever its checksum changes, even for a comment-only edit, and every missing
default id is inserted again, so a deleted default rule silently comes back. The future portal rules editor should
offer only enable/disable (and priority/result edits) for seeded ids 1–999.

**Id reservation.** After the seed, AUTO_INCREMENT is MAX(id) + 1. Rule 999 is a disabled sentinel
(`'*'`, any → `none`, priority -1000; harmless even if enabled, since `none` is also the no-match result), so
admin-created rules get ids from 1000 up and ids 1–998 stay free for future defaults. A new default added to the
seed must use an unused id below 999; `ON DUPLICATE KEY UPDATE id = id` would otherwise skip it without an error.
Keep 999 the highest seeded id (both suites assert it). An alternative is `AUTO_INCREMENT=1000` on the table in
`001_core.sql` (db module); the sentinel works without touching that file.

## Fixture format

- `grants.fixtures.json`: `{ roles, unitOrder, cases: [{ name, memberRoleIds, grants, roles?, unitOrder?,
  expected: GrantSet minus computedAt, checks?: [{ type, key, expected }] }] }`. `checks` run `hasGrant` on the
  result. Both suites also resolve each case with reversed `roles`/`grants` and expect the same output.
- `grants.fixtures.json` `unvalidatedCases` (same shape as `cases`): rows `ResolveInputSchema` rejects; both
  suites resolve them unparsed, and TS also asserts the result passes `GrantSetSchema`.
- `canView.fixtures.json`: `{ rules, cases: [{ name, viewer, record, expected }], engineCases: [{ name, rules,
  viewer, record, expected }], unvalidatedCases: [same shape as engineCases] }`. `unvalidatedCases` hold at least
  one schema-invalid value each (TS asserts that) and run unparsed in both suites; `/fredpd_selftest` ignores them. Every `viewer` is a complete `Viewer` (`ViewerSchema.parse` accepts it
  unchanged): `viewer.grants` is a full GrantSet whose `tier`/`units` mirror `viewer.tier`/`units`, `rank: null`,
  fixed `computedAt`. Both suites use the viewers as decoded and assert this shape. (Harnesses that still rebuild
  the viewer from `grants`/`denied`, such as `/fredpd_selftest`, keep working.) `engineCases` pin the evaluation
  semantics (tie by id, `'*'`, level/status filters, conditions incl. literal `''`, caps) with their own rules.
- Regenerate `rules` by hand from the SQL; the TS drift test fails on any difference.
