<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Module: locales (task 0.4)

This module implements docs/contracts.md §C8. The Swedish terms are defined in [docs/glossary.md](../glossary.md).

| Part | File |
|---|---|
| Strings (688 keys, Swedish product text and British English fallback) | `locales/sv.json`, `locales/en.json` |
| Key union for TS | `packages/types/src/locale-keys.ts`, generated. Do not edit it. |
| Generator | `scripts/gen-locale-keys.mjs` (`pnpm gen:locale-keys`). Add `--check` to only check whether the file is current. |
| Pending merge | `scripts/merge-pending-locales.mjs [--force] [--dry-run]` |
| Tests | `packages/types/test/locales.test.ts` |

## File format

- Each file is a flat JSON object of `"dotted.key": "text"`, sorted by key in code-unit order, with 2-space indent,
  LF line endings and a trailing newline. The merge script writes exactly this canonical form.
- **Key pattern** `^[a-z0-9]+(\.[a-zA-Z0-9_]+)+$`. The first segment is a lowercase namespace. Every key has at least
  two segments.
- **A key is never also a prefix of another key.** For example, `alert.toast` cannot exist next to
  `alert.toast.title`. This keeps the file convertible to nested JSON, which ox_lib flattens back to the same dotted
  keys. The test and the merge script enforce this.
- **Placeholders** are written `{camelCase}`. A key must use the same set of placeholders in sv and en. Any other brace
  is rejected.
- **No `${` in text.** ox_lib's loader reads `${other.key}` as a reference to another key.
- **Avoid `%` in text.** ox_lib's `locale(key, ...)` runs `string.format` when extra arguments are passed. `L(key,
  vars)` must therefore call `locale(key)` without extra arguments and then substitute `{name}` itself.
- Strings are non-empty and have no leading or trailing whitespace.
- **No duplicate keys.** `JSON.parse` keeps the last of two equal keys and ox_lib's decoder may keep either, so both
  scripts reject a file with a duplicate key, and the test requires each file to equal its canonical serialisation.

## Key conventions

Namespaces: `common`, `nav`, `unit`, `home`, `tablet`, `mdt.search`, `person`, `vehicle`, `bolo`, `alert`, `case`,
`report`, `charge`, `evidence`, `intel`, `breach`, `visibility`, `level`, `perms`, `officer`, `poi`, `portal`,
`release`, `audit`, `errors`, `time`, `currency`.

Suffixes inside a namespace follow the same pattern everywhere:

| Suffix | Use |
|---|---|
| `.title` | Page or dialog title |
| `.field.<name>` | Form and column labels |
| `.action.<verb>` | Buttons |
| `.status.<value>` | Status badges |
| `.none`, `.notFound` | Empty states |

Several keys are built directly from data values, so the UI can call ``t(`unit.${code}`)``. Guard those calls with
`isLocaleKey()` and fall back to the raw value. Key segments are ASCII, so a value becomes a segment by stripping
diacritics and lowercasing it: `fängelse` → `fangelse`, `A` → `a`. Every other value below is already ASCII lowercase
and is used as is. The test reads the `ENUM` columns in `db/migrations` and fails when a value has no key.

| Data (schema) | Key |
|---|---|
| unit code (config/units.json `labelKey`) | `unit.<code>`. `unit.label`, `unit.none` and `unit.primary` are static labels in the same namespace, so `label`, `none` and `primary` are reserved and must not be unit codes (the test checks config/units.json). |
| `level` 0 / 1 / 2 | `level.standard` / `level.begransad` / `level.hemlig` (picker hint: `level.hint.<same>`) |
| `fredpd_role_grants.grant_type` | `perms.type.<type>` (for example `perms.type.intel_tier`) |
| perm grant key | `perms.perm.<key>` (for example `perms.perm.intel.read`) |
| canView result / `viewer_condition` | `visibility.result.<result>` / `visibility.condition.<condition>` |
| `fredpd_audit.action` | `audit.action.<action>` (for example `audit.action.perms.update`) |
| `fredpd_alerts.status` (`open`, `assigned`, `closed`) | `alert.status.<status>` |
| `fredpd_alerts.priority` (TINYINT, 1 = highest, default 2) | ≤ 1 → `alert.priority.high`, 2 → `alert.priority.normal`, ≥ 3 → `alert.priority.low` |
| `fredpd_cases.status` (`open`, `closed`) | `case.status.<status>` |
| `fredpd_case_assignees.role` (`lead`, `member`) | `case.assignee.role.<role>` |
| `fredpd_case_subjects.subject_type` / `.role` | `case.subject.<type>` / `case.subject.role.<role>` |
| `fredpd_charges.class`, `fredpd_records.class` (`ordningsbot`, `bot`, `fängelse`) | `charge.class.ordningsbot` / `charge.class.bot` / `charge.class.fangelse` (note `fängelse` → `fangelse`) |
| `fredpd_charges.category` (`penal`, `traffic`, `narcotics`, `weapons`, `public_order`, `other`) | `charge.category.<category>` |
| `fredpd_records.status` (`issued`, `paid`, `served`, `revoked`) | `charge.status.<status>` |
| BOLO state (`active` flag, `resolved_at`, `expires_at`) / `fredpd_bolos.kind` | `bolo.status.active` / `resolved` / `expired`; `bolo.kind.<kind>` |
| `fredpd_release_requests.status` | `release.status.<status>` (`pending`, `approved`, `partial`, `denied`) |
| `fredpd_persons.gender` (TINYINT, qbx charinfo: 0 man, 1 kvinna, NULL not set) | 0 → `person.gender.male`, 1 → `person.gender.female`, NULL or any other value → `person.gender.unknown` |
| qbx_vehicles state 0 / 1 / 2 | `vehicle.state.out` / `garaged` / `impounded` |
| qbx licence type (`metadata.licences` key `driver`, `weapon`) | label `person.licence.<type>`; status `person.licence.status.<type>.valid` / `.revoked` (they differ: *ett körkort* is Giltigt, *en vapenlicens* is Giltig); no licence → `person.licence.status.none` |
| `fredpd_poi.warnings` entries (`armed`, `violent`) | `poi.warning.<key>` |
| `reliability` A–D (sources, intel reports) | `intel.reliability.a` … `d` |
| `fredpd_intel_sources.status` (`open`, `closed`) | `intel.source.status.<status>` (Aktiv / Avregistrerad) |
| `fredpd_missions.status` (`open`, `closed`) | `intel.mission.status.<status>` (Pågående / Avslutad) |
| `fredpd_intel_reports.status` (`open`, `closed`) | `intel.report.status.<status>` (Aktiv / Avslutad) |
| `fredpd_intel_entities.type` | `intel.entity.type.<type>` |
| `fredpd_intel_links.type` (VARCHAR: `associate`, `owns`, `member_of`, `seen_at`, `uses`, `related`) | `intel.linkType.<type>` |
| `fredpd_evidence.type` (VARCHAR: `fingerprint`, `dna`, `blood`, `casing`, `projectile`, `toolmark`, `photo`, `other`) | `evidence.type.<type>` |

`charge.class.*` is the only key set for the påföljd column. `charge.sanction.*` (`warning`, `revocation`,
`strafforelaggande`) labels the sanctions that are not a charge class: a warning or revocation of a licence, and a
strafföreläggande as a sanction type. Earlier `charge.sanction.fine` / `ordningsbot` / `prison` keys duplicated
`charge.class.*` and were removed, so there is one key per concept.

`report.kind.*` (anmälan, PM, rapport) has no column in `fredpd_reports` yet. The reports module can use it for
template names or add a `kind` column later. VARCHAR sets (link types, evidence types, POI warnings) are open: a module
that writes a new value adds its key through a pending file.

The `audit.action.*` names (`lookup.person`, `lookup.vehicle`, `case.create`, `bolo.create`, `door.breach`, …) are
proposals for the modules that write audit rows. A module that picks a different action string should add the
matching key through a pending file.

## Values passed into placeholders

- Format values before passing them in:
  - `{amount}` with `formatCurrency`
  - `{date}` and `{time}` with `formatDate` and `formatTime`
  - `{level}` with `t('level.…')`
  - `{unit}` with `t(unit.labelKey)`
- `{name}` is the officer's Discord display name when the text refers to an officer (§4.9), and the character name
  when the text refers to a subject.
- There are no plural forms. Every text with a count is phrased so the same wording works for 1 and for many
  ("Träffar: {count}", "{count} min", "{count} d sedan", "Uppdaterade spelare: {count}"). A pending text that puts a
  count before a plural noun ("{count} slagningar") must be rephrased before it is merged.
- `portal.privacy.retention` and `audit.retention` take `{days}` (90, §4.5 and §8.8), so the text follows config.

## Generated TS API (`@fredpd/types`)

- `LOCALE_KEYS`: a readonly tuple of all keys, sorted.
- `LocaleKey`: the union of all keys.
- `LocalePlaceholders`: maps each key that has placeholders to a union of its placeholder names.
- `LocaleVars<K>`: `{ [placeholder]: string | number }`, or `Record<string, never>` for a key without placeholders.
- `LocaleArgs<K>`: the rest parameters for a key. Vars are required exactly when the key has placeholders. Suggested
  `t` signature: `t<K extends LocaleKey>(key: K, ...args: LocaleArgs<K>): string`.
- `isLocaleKey(value)`: a runtime guard for dynamic keys.

The generator reads `sv.json`, the source of truth for keys. Before writing, it validates both files with all the
rules above. `--check` writes nothing and exits 1 when `locale-keys.ts` is stale or when a locale file is not in
canonical form (a hand edit that left it unsorted or reformatted; run the merge script to rewrite it). Both
comparisons normalise line endings, so a CRLF checkout on Windows passes. Without `--check`, a non-canonical locale
file only prints a warning.

## Pending strings from other modules

1. Add `locales/pending/<module>.json` with `{ "key": { "sv": "…", "en": "…" } }`. Top-level `$comment` keys are
   ignored.
2. The orchestrator runs `node scripts/merge-pending-locales.mjs`. The script:
   - validates every pending file and the merged result;
   - refuses conflicts (an existing key with different text, or two pending files that disagree) unless `--force`
     is given, in which case the pending text wins and later files win over earlier ones;
   - writes sorted sv/en files, regenerates `locale-keys.ts`, and only then deletes the merged pending files.

   If any step fails, nothing is written. Resubmitting a key with identical text is a no-op. With no pending files
   the script just re-sorts the locale files, so it also works as a formatter. `--dry-run` prints the summary only.

## Tests (`pnpm exec vitest run --project types test/locales.test.ts`)

The test file checks:

- sv and en are flat and have identical key sets.
- Each file equals its canonical serialisation (catches duplicate keys and formatting drift).
- Keys are sorted and match the pattern, and no key is a prefix of another.
- No string is empty or padded.
- Each key has the same placeholders in both files, with no stray braces and no `${`.
- Strings quoted by the plan or other modules are kept verbatim, for example `alert.assigned` and
  `visibility.notice.text`.
- Every `config/units.json` `labelKey` exists.
- Every value of the `ENUM` columns in the mapping table, and every charge category, has its key.
- `LOCALE_KEYS` equals the sv keys, and `gen-locale-keys --check` passes.
- The types hold under tsc (`@ts-expect-error` cases).
- The merge script behaves correctly in a temporary repo root: merge and delete, conflict with and without
  `--force`, disagreeing pending files, invalid entries (including duplicate keys in a pending file, at the top
  level or inside an entry), dry run, a stale or mismatched key file, duplicate keys in a locale file, and a
  non-canonical (or CRLF) locale file.
- `gen-locale-keys --check` still runs, and still fails on a stale key file, when invoked through a symlinked
  (or, on Windows, junctioned) directory.

## Open points

- `fredpd_charges.class` and `fredpd_records.class` use the non-ASCII value `fängelse`, which cannot be a key segment.
  The UI maps it to `charge.class.fangelse` (rule above). If the db module switches to the ASCII value `fangelse`, the
  keys stay as they are and the mapping becomes a no-op.
- The old `charge.class.infraction` / `misdemeanor` / `felony` keys (a bub-mdt style grading) were removed, because the
  schema grades charges by påföljd (`ordningsbot`, `bot`, `fängelse`) instead.

- `pnpm lint` does not run `node scripts/gen-locale-keys.mjs --check` yet, because root `package.json` is not owned
  by this module. The Vitest suite covers staleness in the meantime.
- §4.5 moves audit rows older than 90 days to `fredpd_audit_archive`, while §8.8 says "audit retention 90 days". The
  privacy text says logs are kept for `{days}` days. If the archive is kept longer, the notice must say so. Decide
  before the portal goes live.
