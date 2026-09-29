# Module: formats (task 0.5)

Implements docs/contracts.md §C4. The code lives in three places:

- TS: `packages/types/src/format.ts`
- Lua: `resources/[fredpd]/fredpd_core/shared/format.lua` and `shared/regex.lua`
- Shared fixtures: `packages/types/test/fixtures/format.fixtures.json`. It has 119 cases plus 58 regex cases. Vitest runs them from `packages/types/test/format.test.ts` and Lua runs them from `tests/lua/format_test.lua` and `tests/lua/regex_test.lua`.

This file records the decisions that go beyond the contract. Other modules should rely on them.

## API additions (compatible with §C4)

- **Optional `formats` argument.** Every function takes `formats` as an optional last argument. Without it, the function uses the active formats.
  - TS: the active formats are loaded lazily from the bundled `config/formats.json`, so importing never throws. `loadFormats(json)` replaces them and returns the parsed value. `getFormats()` returns the active formats.
  - Lua: `Format.load(tbl)` sets the active formats and `Format.get()` returns them. Before `load`, any call that needs formats raises `not_loaded`.
  - **fredpd_core must call `Format.load(json.decode(LoadResourceFile(GetCurrentResourceName(), 'config/formats.json')))` at start, on the server and on the client.**
- **Errors.** Every error is `"<code>: <detail>"`.
  - Codes: `unknown_placeholder`, `missing_value`, `invalid_value`, `invalid_template`, `invalid_regex`, `invalid_config`, and `not_loaded` (Lua only).
  - TS throws a `FormatError` that has `.code`.
  - Lua raises the same string at level 0, so the message has no file:line prefix. Get the code with `err:match('^([%w_]+):')`, for example to map it to a locale key.
  - `load` and schema failures are always reported as `invalid_config`.
- **Instants** (`date` in `formatId`, and the input of `formatDate`/`formatTime`):
  - An ISO-8601 string with a `Z`, `±HH:MM` or `±HHMM` offset. A string with no offset is treated as **UTC**, not local time. A date-only string means UTC midnight. Fractions are ignored.
  - Or a number of **epoch milliseconds**. oxmysql returns DATETIME values in this form, and so does `Date.now()`.
  - TS also accepts a `Date`.
  - Invalid calendar values, such as 30 February or hour 24, raise `invalid_value`.
  - Instants outside `1900-01-01T00:00:00Z`..`9999-12-31T23:59:59Z` raise `invalid_value` in both ports. Beyond that range JS `Intl` throws a `RangeError` (past ±8.64e15 ms) or applies local mean time, and Lua would overflow.
- **Placeholders.**
  - `seq` and `n` accept a non-negative safe integer or a string of digits. Both accept `:k` for zero-padding, with k from 1 to 20.
  - `unit` must match `[A-Z]+`, so that the ID matches `templateToRegex`. Pass the `callsign` field from `config/units.json` (`IGV`), not its `code` (`igv`).
  - `case` is any non-empty string. It is deliberately not checked against the current caseNumber pattern, because existing IDs are never rewritten.
  - An empty string counts as missing.
- **`FormatsSchema`.**
  - Strips unknown keys such as `$comment`.
  - Adds an optional `currency.decimalSeparator`, default `,`.
  - `tz` is limited to `SUPPORTED_TIME_ZONES`: Stockholm, Oslo, Copenhagen, Berlin, Helsinki, London and UTC. These are the zones the Lua port can convert without a tz database.
  - `plate` and `personId` must stay inside the regex subset (see below).
  - `caseNumber` must not contain `{{case}}`.
- **`detectSearchType`** first folds every non-ASCII character that JS `\s` matches (U+00A0, U+1680, U+2000–U+200A, U+2028, U+2029, U+202F, U+205F, U+3000, U+FEFF) to an ASCII space, so a pasted NBSP behaves like a space. It then trims and checks in this order:
  1. caseNumber, first as typed, then upper-cased.
  2. personId. The result is the digits only, with a `-` before the last four.
  3. plate. The query is upper-cased and all whitespace is removed.
  4. name. The query is trimmed and runs of whitespace become one space.

  After the fold, trimming and upper-casing apply to ASCII only, so both ports give byte-identical results. A non-string query raises `invalid_value`.
- **`formatDate` and `formatTime`** render the `formats.date` and `formats.time` patterns. The tokens are `YYYY YY MM DD HH mm ss`, and any other text is kept as a literal.
- **`formatCurrency`**:
  - Rounds half away from zero to `decimals`.
  - Groups thousands with `thousandsSeparator`.
  - A suffix symbol has a space before it (`1 234 kr`). A prefix symbol has no space (`€1 234`).
  - Negative amounts start with an ASCII `-`. An amount that rounds to 0 has no sign.
  - Non-finite amounts, or amounts ≥ 2^53 after scaling, raise `invalid_value`. Lua scales in floating point, like TS, so large integers such as `math.mininteger` cannot wrap around.
  - The separator is inserted literally, even if it contains `$`.
- **Formats objects are immutable once used.** Both ports cache the compiled formats by object identity. TS freezes the object that `loadFormats`/`getFormats` return. Lua cannot freeze a table cheaply, so do not mutate a formats table, whether you passed it in or got it from `Format.load`/`Format.get`. Build a new one instead.
- **`compileFormatRegex(pattern)`** (TS only, exported) validates a subset pattern and returns a native `RegExp` with the Lua engine's semantics (see below). NUI and service code should use it instead of `new RegExp(...)` for `plate`, `personId` and `templateToRegex` results. The template patterns contain no `\s` or `.`, so plain `new RegExp` also agrees for those.
- **`templateToRegex`** accepts only the four format names. Names such as `toString` raise `invalid_value`.
- **`formatId` context.** TS `formatId(template, null)` (or `undefined`) behaves like Lua's `nil` context. Any other context that is not an object or table raises `invalid_value` in both ports, even when the template has no placeholders. This covers numbers, booleans (including `false`) and strings.

## Time zones in Lua

The Lua port has no tz database. It applies the EU rule for every year: CET/CEST change at 01:00 UTC on the last Sunday of March and of October. All time handling is integer arithmetic on the UTC epoch, using Hinnant's civil-date algorithms. The port never calls `os.date` or `os.time`, so the machine's TZ has no effect. The tests pass under `TZ=America/New_York` and `TZ=Pacific/Auckland`.

A one-off check compared the port with Node `Intl` on 29,764 instants: every supported zone, 1996–2037, including ±1 s around every switch. There were 0 mismatches. A second check used 1,500 random instants per zone from 1996 to 9999, and also found 0 mismatches.

**The ports agree only for instants from `1996-01-01T00:00Z` on.** Earlier instants use the real history in TS (`Intl`) and the EU rule in Lua, so they can differ by an hour for whole seasons, not only near switch dates:

- Sweden had no DST in most years from 1900 to 1979. For example, `formatTime('1975-07-01T12:00:00Z')` gives `14:00` in Lua and `13:00` in TS.
- In the continental zones, DST from 1980 (Helsinki from 1981) to 1995 ended on the last Sunday of September. So the ports differ from late September to late October.
- London used UTC+1 all year from 1968 to 1971. For example, `formatTime('1970-01-15T12:00:00Z')` gives `12:00` in Lua and `13:00` in TS.
- Helsinki used local mean time (+1:39:49) before 1921, so times differ by minutes.

In a random sample of 1,500 instants per zone from 1900 to 1995, between 317 (London) and 892 (Helsinki) differed in each EU zone. UTC never differs.

**Date-only strings still agree.** Every supported zone's offset is between 0 and +3 hours in every year. So a date-only string (UTC midnight) renders the same date in both ports. A check of every day from 1900-01-01 to 1995-12-31 in all seven zones found 0 differences, and fixtures lock this for Stockholm, London and Helsinki. **Pass dates of birth and other historical dates as date-only strings (`'1975-07-01'`)**, with a `formats.date` pattern that has no time tokens. Never pass them as instants with a time of day. In practice, in-game instants are always recent, so the pre-1996 gap only matters for historical data.

The 1900 lower bound is an input limit, not a guarantee that the ports agree.

## Regex subset (`shared/regex.lua` ⇄ `assertRegexSubset` in TS)

**Supported** (JavaScript semantics, no flags):

- `^ $ .`
- `[...]` and `[^...]`, with ranges. `[\d-z]` makes the `-` a literal, as JS Annex B does.
- `\d \D \s \S \w \W`
- `\t \n \v \f \r`
- Escaped punctuation.
- `? * + {n} {n,} {n,m}`, where the counts are at most 1000.
- A bare `]` or `}` is a literal.

**Compile error** (in both ports), so a config that the game cannot run is rejected everywhere:

- Groups, alternation and lookaround.
- Backreferences, `\b` and `\p`.
- Lazy quantifiers.
- A bare `{`.
- A non-ASCII character inside a class, or a non-ASCII character followed by a quantifier.

The fixture `regex` section checks the Lua engine against native JS `RegExp`.

**ASCII semantics in both ports.** The Lua engine's `\s` is only space, `\t \n \v \f \r`, and its `.` excludes only `\n` and `\r`. Native JS `\s` also matches Unicode spaces and its `.` also excludes U+2028/U+2029. So the TS port rewrites the pattern before it builds the native `RegExp`:

- `\s` becomes `[\t\n\v\f\r ]` and `\S` becomes `[^\t\n\v\f\r ]`. Inside a class they expand to the same sets, and `\S` expands as ranges.
- `.` becomes `[^\n\r]`.
- Every literal `-` inside a class is written as `\-`. Examples are a leading or trailing `-`, one next to a class escape (the Annex B case), and one used as a range endpoint. So the only bare `-` in the native class is a range operator that the translator wrote itself. Before this rule, the output could fuse into ranges that the original pattern did not have. For example, `[\d--a]` became `[\d\--a]`, which native JS reads as the range `-`..`a`. And `[a-\s-z]` expanded to `... -z`, which is a range from space to `z`. Fixtures now cover both of these, plus `[\d-.- ]`, `[--/]` and `[!--]`.

Differential runs (scratch scripts, not in the repo), after the `\-` fix:

- 40,000 random bracket-class patterns (two seeds, each with 127 single-ASCII-character inputs). The two ports gave 0 accept/reject differences and 0 match differences. The Lua engine also agreed with plain native `RegExp` on the original pattern for all 40,000.
- 8,000 general patterns with 301 inputs each. There were 0 accept/reject differences and 0 match differences.

An earlier run, made before the fix, claimed that the ports accepted exactly the same set. That was wrong for class forms like the ones above: over 20,000 class patterns there were 75 accept/reject differences and 43 match differences.

**Remaining divergence:** Lua matches bytes. A multi-byte UTF-8 character therefore counts as 2 to 4 characters for `.`, negated classes, `\D`, `\S`, `\W` and `{n}`, where JS counts one UTF-16 unit. The default patterns only accept ASCII, so this cannot change a result for them. Unicode spaces are folded before `detectSearchType` matches, so they never reach the engine.

The Lua matcher memoises failed (atom, position) pairs, which bounds the work to O(atoms · n²).

## Loading in FiveM

`format.lua` first tries `require '@fredpd_core.shared.regex'` (ox_lib), which works from any resource. If that fails, it falls back to `require 'shared.regex'`, which covers plain Lua tests and code inside fredpd_core. Any resource that uses the module needs `@ox_lib/init.lua` in its manifest.

## Open questions

1. `detectSearchType` only knows `caseNumber`. Report numbers (`K-123-26/2`) and evidence tags fall through to `name`. Should they be new types, or should they map to their case? That would be a change to the §C4 contract.
2. §C4 could absorb the additions above: error codes, optional `formats`, epoch-ms instants, the tz list and `decimalSeparator`.
