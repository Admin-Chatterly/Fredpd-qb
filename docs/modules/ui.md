<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Module: ui (tasks 0.1 web apps, 1.8 UI, 2.2, 2.3–2.7 NUI pages)

Shared React layer (`packages/ui`), the tablet NUI shell (`apps/nui`) and the portal shell with the
"Behörigheter" page (`apps/portal`). Implements IMPLEMENTATION.md §4.4, §4.7, §5.2 (NUI routes), §5.9 (admin UI)
and docs/contracts.md §C8 (t()) and §C10 (permissions admin API, client side).

## packages/ui

| File | Content |
|---|---|
| `src/theme.css` | Tailwind v4 `@theme` tokens. Dark and flat. There is one accent hue (`accent`, `accent-strong`, `accent-text`, `accent-soft`), plus `canvas/surface/raised`, `line`, `fg/muted/subtle` and the status colours `success/warning/danger`. The base is 15 px (`html { font-size: 15px }`, so 1rem = 15 px). The default palette and shadows are removed (`--color-*: initial`), so pages can only use these tokens. Apps import it after `@import "tailwindcss"`. Its `@source "./"` makes Tailwind scan the shared components. It sets **no `color-scheme`** (see "color-scheme" below). |
| `src/i18n.tsx` | `createI18n(messages, { lang = 'sv', fallbackLang = 'en', onMissing })` returns `{ lang, t, tx, has }`. `t(key: LocaleKey, vars)` is typed through `LocaleArgs`, so vars are required exactly when the key has placeholders. `tx(key: string, vars?, fallback?)` handles keys built from data, such as ``tx(`unit.${code}`, undefined, code)``. Lookup order is lang, then en, then the key itself. `{name}` is substituted and a placeholder without a value is left as is. Also exports `I18nProvider`, `useI18n()` and `useT()`. Without a provider, components render their keys. |
| `src/components/*` | `Button` (primary/secondary/ghost/danger, `loading`), `IconButton` (a `label` is required; a padding-free square from `buttonClass(…, 'icon')`), `Input`/`Label` (`fieldClass` is the input look without a width, for `<select>`), `SearchInput` (controlled, trims on Enter, has a clear button), `Card`, `Badge` (`level={0\|1\|2}` gives Standard/Begränsad/Hemlig in neutral/warning/danger), `Notice` (kontaktnotis) and `VisibilityGate`, `EmptyState`, `Spinner` (CSS only), `VirtualList` (TanStack Virtual), `Table`, and the layout pieces `AppShell`, `Sidebar`, `NavItem`, `PageHeader`. |
| `src/components/` (Phase 2) | `Dialog` (modal; `absolute inset-0` over the nearest positioned ancestor, which is the tablet frame in the NUI, or `position="fixed"`; focuses the first field, gives focus back on close; Esc is left to the tablet), `Pagination` (prev / "Sida x av y" / next, hidden for one page), `Textarea`, `VirtualListbox` (keyboard-navigable windowed `role="listbox"` with `aria-activedescendant`: ↑/↓, Home/End, PageUp/PageDown, Enter or click activates, `isDisabled` rows can be selected but not activated). |
| `src/mdtPages.ts` | Re-exports `MDT_PAGE_KEYS`, `MdtPageKey`, `MDT_PAGE_LABEL_KEYS` and `isMdtPageKey` from `@fredpd/types/mdtPages` (docs/contracts.md §C12), so the apps keep importing them from `@fredpd/ui` (see below). |
| `src/icons.tsx` | A small stroke icon set drawn for FredPD (`aria-hidden`). |

`cn()` only joins class names, and Tailwind orders utilities in its stylesheet, not by class order. So never
override a utility with another one for the same property (`px-0` over `px-3.5`, `w-52` over `w-full`): add a
variant (as `buttonClass` shapes do) or use a different property (`max-w-*`).

`Notice` takes only `subject` and `owner` (null means "Kontakta ledningen"). It never receives a record, so no record
field can reach the DOM. `VisibilityGate` renders content by `canView` result: `none` renders nothing, `notice`
renders only the Notice, `masked` renders a banner and the content, and `full` renders the content.

## Grant keys `mdt_page:<key>` (pinned in docs/contracts.md §C12; source `packages/types/src/mdtPages.ts`)

| Key | Routes | Nav label |
|---|---|---|
| (none, Hem) | `/` | `nav.home` |
| `search` | `/sok`, `/person/:cid`, `/fordon/:plate` | `nav.search` |
| `alerts` | `/larm` | `nav.alerts` |
| `bolos` | `/efterlysning` | `nav.bolos` |
| `cases` | `/arenden`, `/arende/:id`, `/rapport/:id` | `nav.cases` |
| `evidence` | `/bevis` | `nav.evidence` |
| `intel` | `/intel/*` | `nav.intel` |
| `charges` | `/brottskatalog` | `nav.chargeCatalog` |
| `roster` | `/register` | `nav.roster` |
| `command` | `/ledning/*` | `nav.command` |

`mdt_page:*` opens every section. Routes without the grant show `errors.unauthorized`. The server must still check
every callback: the client copy of the grants only shapes the menus.

## color-scheme (why the NUI must not set it on the document)

FiveM shows each `ui_page` as a transparent full-screen iframe inside its root NUI page, whose scheme is `normal`.
When an iframe's used `color-scheme` differs from its embedder's, Chromium paints the iframe canvas opaque in that
scheme's Canvas colour. `html { color-scheme: dark }` in the NUI therefore blacked out the whole game, even with the
tablet closed (checked in headless Chromium: rgb(18,18,18) over a red parent; transparent without it). The portal
sets it on `html` (`apps/portal/src/index.css`). The NUI sets it on `#fredpd-tablet` only, which keeps form controls
and scrollbars dark. `apps/nui/test/theme.test.ts` compiles the NUI CSS with Tailwind and fails if html, `:root`,
`:host` or body get a `color-scheme`.

## apps/nui (tablet)

- **Build.** The app uses Vite 7, Tailwind v4 (`@tailwindcss/vite`) and `vite-plugin-singlefile`, with `base: './'`.
  The output is a single `dist/index.html` (about 470 kB, with JS, CSS and both locale files inlined), which
  `scripts/build.mjs` copies to `fredpd_mdt/web/build`. `pnpm --filter @fredpd/nui build:dev` runs
  `vite build --mode development`. That build keeps the first-paint log and the missing-key warnings
  (`IS_DEV_BUILD`). Copy it with `node scripts/build.mjs --skip-web`.
- **NUI messages (Lua to NUI)**, for task 2.1 to send with `SendNUIMessage`:
  - `{ action = 'open', grants = <GrantSet>, unit = 'igv' | nil, me = { citizenid, displayName, callsign | nil } }`
    - The fields sit next to `action`, as in §5.2.
    - They are validated with `MdtOpenPayloadSchema`.
    - A missing `unit` or `me.callsign` becomes null.
    - An empty Lua table `{}` in `grants.grants/denied/units` is read as `[]`.
    - An invalid payload still opens the tablet, which shows `errors.unknown` and can still be closed.
  - `{ action = 'close' }` hides the tablet.
  - `{ action = 'push', topic = '<topic>', payload = … }` does two things. It calls
    `queryClient.invalidateQueries({ queryKey: [topic] })`, so pages should key their queries with the topic first:
    `['alerts', …]`, `['units']`, `['bolo', …]`, `['case', id]`. It also notifies `usePush(topic, fn)` subscribers.
  - The topic `grants` with a GrantSet payload replaces the client grants while the tablet is open. This is how
    `fredpd:client:grantsChanged` reaches the tablet. It also sets the primary unit to `grants.units[0]` (null
    when empty or not a unit code), since §C2 orders `units` by units.json, so nav priority, the Hem variant and
    the unit label follow a unit change.
- **NUI to Lua.** `fetchNui(action, data?, mockData?)` POSTs JSON to `https://<GetParentResourceName()>/<action>`.
  A non-2xx answer throws `NuiRequestError`, and an empty body resolves to `undefined`. In a browser, where
  `window.GetParentResourceName` is absent, it never posts. It answers with `mockData`, else the mock from
  `registerNuiMock(action, fn)`, else `undefined`. `debugData(messages)` dispatches fake Lua messages, in the
  browser only.
- **Close.** Esc always closes (§5.2), even while typing: the tablet hides at once and calls `fetchNui('close')`.
  Lua must answer the `close` callback with `SetNuiFocus(false, false)`. The header close button does the same.
- **Idle cost.** The root `#fredpd-tablet` stays mounted with `visibility:hidden` when closed, so the router keeps
  the last page. There are no timers. TanStack Query uses `staleTime` 30 s and `refetchOnWindowFocus`, and
  `focusManager` is driven by open and close: opening counts as focus and refetches stale queries, while nothing
  refetches while closed. An `open` for a different citizenid clears the query cache and remounts the router.
- **Navigation.** Hem comes first, then the primary unit's priority sections (`UNIT_NAV_PRIORITY`, for example
  tekniker gets evidence and then cases), then the base order. At most 6 slots are shown. When more sections are
  allowed, the 6th slot is **Meny** (`nav.menu`), which expands the rest in the sidebar.
- **Hem.** See "Phase 2 pages" below.
- **Dev.** `pnpm --filter @fredpd/nui dev` serves http://localhost:5174 and opens the tablet with mock data. The
  mock open is sent from `TabletProvider`'s `onReady` (called once the message listener is attached); a message
  dispatched before that is lost. Use
  `?unit=tekniker&pages=search,cases&perms=bolo.create&tier=2` (or `unit=none`, `perms=none`) to preview other units
  or grants (default: igv, `mdt_page:*`, perms `bolo.create,bolo.resolve,tablets.manage`, tier 1). While the tablet
  is closed, a "Öppna surfplattan" button reopens it. Every tablet action answers from an in-memory Swedish register
  (`src/mock/data.ts`: ~900 persons, ~85 vehicles, cases full/masked/notice, BOLOs live/resolved/expired, tablets,
  plate checks; `src/mock/handlers.ts` follows the server rules the NUI can see: canView-shaped refs, 50 per page,
  one live BOLO per subject, level ≤ tier, `{ error, reason }` refusals). Answers go through `toLuaWire` (nulls
  removed, as Lua sends them) after 150 ms, so the page code runs the game path. Try "Andersson", "19870412-5531",
  "ABC 12D", "K-1042-26" (full), "K-988-26" (masked), "K-1077-26" (kontaktnotis). The mocks are only reachable from
  `import.meta.env.DEV` branches and are absent from the production bundle.
- **First paint.** Dev builds log `[fredpd] open -> first paint N ms`, measured on the second animation frame after
  the open message.

## Phase 2 pages (tasks 2.3–2.7, Ledning → Surfplattor)

Shapes: `packages/types/src/mdt.ts` (`MDT_ACTIONS`), docs/contracts.md §C3, §C12. The fredpd_mdt dispatcher answers
the output data or `{ error, reason? }` (docs/modules/mdt.md).

### Typed client (`src/api/`)

| File | Content |
|---|---|
| `client.ts` | `callMdt(action, input)`: `fetchNui` → `{ error }` becomes `MdtClientError(code, reason)` (unknown codes → `unknown`, a non-2xx callback → `network`) → `normalizeWire` → **dev builds only** (`IS_DEV_BUILD`): `MDT_ACTIONS[action].output.safeParse`, a mismatch is logged with the zod issues and thrown as `unknown`/`contract`. Query keys `['mdt', action, input]`. `PUSH_INVALIDATES`: `bolo` → listBolos, getPerson, getVehicle, getHome, search (its BOLO flag); `case` → getPerson, getVehicle, getHome, search; `grants` → every read action. `MUTATION_INVALIDATES`: createBolo/resolveBolo → the `bolo` set, checkPlate → getVehicle, setTabletRevoked → listTablets. |
| `wire.ts` | `normalizeWire(schema, value)`: Lua has no null, so absent nullable keys are restored as null, `{}` where a list is expected becomes `[]` and `[]` where an object is expected `{}` (records.md edge case), through arrays and discriminated unions (by the discriminator literal). It reads the zod schemas' public `def` only (no parsing), so it runs in production too; it never adds or drops other keys. `toLuaWire` is its inverse for mocks/tests. |
| `errors.ts` | `MdtClientError`, `errorLocaleKey(err)`: `unauthorized/not_found/validation/rate_limited/unavailable/network/unknown` → `errors.unauthorized/notFound/validation/rateLimited/serviceUnavailable/network/unknown`; reasons first: `off_duty` → `errors.notOnDuty`, `too_far` → `errors.tooFar`, `revoked` → `tablet.revoked`. `useErrorText()`. |
| `hooks.ts` | `useMdtQuery(action, input, { enabled, keepPrevious })` and `useMdtMutation(action, { onSuccess, onError })` over TanStack Query (client defaults: staleTime 30 s, refetch on open, no interval). A query retries once (600 ms) only for `network/unavailable/rate_limited/unknown`. `mdtQueryOptions()` is shared with imperative `fetchQuery` calls. |

`TabletContext` calls `invalidateForPush(queryClient, topic, refetchType)` next to its `[topic]` invalidation (closed
tablet: `refetchType: 'none'`, refetched on the next open) and on a `grants` push.

### Pages

- **Routes.** Hem and the placeholders are eager (Hem is the first paint after open); Sök, Person, Fordon,
  Efterlysningar and Ledning are `React.lazy` behind one `Suspense` around the layout's `<Outlet>`. With
  `vite-plugin-singlefile` the lazy chunks are inlined into the one `index.html` (dynamic imports inlined), so lazy
  loading defers their rendering, not their download. New: `/ledning` (index) and `/ledning/surfplattor`.
- **Header search (2.3)** (`components/HeaderSearch.tsx`): a chip shows `detectSearchType` (config/formats.json via
  `@fredpd/types/format`) while typing. **Enter** posts `search { query, type: 'auto', page: 1 }` and opens the top hit
  (person → `/person/:cid`, vehicle → `/fordon/:plate`, case → `/arende/:id`); no hit, a kontaktnotis top hit, an
  error or a query under 2 characters opens `/sok?q=` instead. **Shift+Enter** / "Visa alla" always open the list.
  Typing posts nothing.
- **Results `/sok?q=&page=` (2.3):** `VirtualListbox` (64 px rows, 50 per page, `Pagination`), focused on arrival:
  ↑/↓ select, Enter or click opens, **Esc closes the tablet** (§5.2 wins over "Esc" in the task text; the hint
  string `mdt.search.keys` says "Esc stänger"). Person/vehicle rows carry the BOLO flag; a `notice` case row is
  only the Notice (subject = the searched number, owner = contact) and is `aria-disabled` (opens nothing).
- **Person (2.4):** header facts (personnummer, birthdate, gender, phone, address; absent ones are not rendered),
  Efterlys (perm `bolo.create`; disabled with the duplicate text while a BOLO is live) opens the BOLO dialog prefilled
  (kind person); Lägg i ärende / Ny rapport / POI-blad are disabled with the tooltip `common.comingPhase5` (on a
  wrapper: disabled buttons get no pointer events). Sections: BOLOs (resolve with perm `bolo.resolve`), vehicles,
  cases, belastningsregister (fine per row and `charge.totalFine` with `formatCurrency`; jail as `time.duration.minutes`,
  the field is `jailMinutes`).
- **CaseRef rendering** (`components/CaseRefs.tsx`): `full` → number, title, role, status, level badge (> 0);
  `masked` → number, status, "Begränsad insyn" badge, level badge, role, and the title **only if sent**; `notice` →
  **only** `<Notice>`; only `contact` is passed on, owner line "Name (Unit)" / name / unit / null → "Kontakta
  ledningen".
- **Vehicle (2.5):** plate, model, owner link (or `vehicle.ownerUnknown`), BOLO flag, Efterlys (vehicle), linked
  cases, Kontrollera (`checkPlate`: hit → danger callout with the reason; unregistered; clear) and the history
  (officer label, hit badge; refetched after a check).
- **Efterlysningar (2.6 UI):** tabs Aktiva / Alla (`listBolos { active, page }`), table with subject link, level,
  issuer, times, status (active / resolved / expired), Pagination; "Ny efterlysning" (perm `bolo.create`) and
  resolve (perm `bolo.resolve`) are UI hints only. **BOLO dialog** (`components/Bolos.tsx`, logic in `src/bolo.ts`):
  kind, subject picker (`search` with `type: person | vehicle`, Enter searches, pick from ≤ 8 hits), reason (3–500),
  level (options above the viewer's tier disabled, hint `level.hint.*`), expiry (none, 1/4/12 h, 1/3/7/30 dygn).
  `buildBoloCreateInput` sends citizenid **or** plate (never both), the trimmed reason, the level and
  `expiresInHours` only when chosen; `checkBoloForm` runs `BoloCreateInputSchema` plus level ≤ tier before sending.
  Refusals: `reason = duplicate` → `bolo.create.duplicate`, `level` → `bolo.create.levelTooHigh`, `not_found` →
  `bolo.create.subjectNotFound`.
- **Hem (2.7):** one `getHome`. Variant = the primary unit's `home` (instant; follows a grants push), else the
  server's `variant`, else `default`. `HOME_LAYOUTS` per variant: count cards in order (first emphasised; links to
  their page when granted) and blocks: igv/span/default BOLOs first, utredning/tekniker my cases first, ledning the
  roster first (`officer.roster` table: callsign, name, unit, on/off duty). Cards/blocks need `mdt_page` bolos /
  cases / roster (the on-duty count needs none).
- **Ledning → Surfplattor:** `listTablets` (50 per page), revoke asks (`tablet.revokeConfirm`), reinstate is direct,
  result `tablet.revokedNotice` / `tablet.reinstatedNotice`. Without perm `tablets.manage` the page shows
  `errors.unauthorized` and calls nothing.
- **Locale keys:** the 16 Phase 2 keys from `locales/pending/nui.json` are merged into `locales/sv.json`/`en.json`
  (commit 82fd2e9) and are now read with the typed `t()`. `src/i18n.ts` still layers any future
  `locales/pending/nui.json` under sv/en through `import.meta.glob` (finds nothing today; no build break).

### Bundle

`pnpm --filter @fredpd/nui build`: `dist/index.html` **583.4 kB** (gzip 177.5 kB; 2026-09-29), up from 472.4 kB
before Phase 2 (the growth since the first Phase 2 build is the merged locale files). Largest parts:
react-dom 210 kB, zod 89 kB (already present for the open payload), locale files + app code ~113 kB, react-router
38 kB, query-core 33 kB, virtual-core 24 kB (new, for the virtualised list), `@fredpd/types` format/mdt ~13 kB.

## apps/portal

- **Routes.** `BrowserRouter` serves `/` (Hem) and `/behorigheter`. The Behörigheter nav item and route appear only
  with `perm:admin.permissions`. Without it, the route shows "not found" and never calls the admin API. Logged-out
  users get the login page on every route.
- **Session.** `GET /api/session` provides the user and the `csrfToken`. `apiFetch` sends `x-csrf-token` on every
  non-GET request. A 401 from any query or mutation replaces the cached session with "logged out, expired", and the
  login page then shows `portal.sessionExpired`. Logout does a `POST /auth/logout` with CSRF and then shows
  `portal.loggedOut`. If the logout is refused, the page re-reads the session to get a fresh token.
- **Login.** The page has a Discord button (`/auth/discord`, a full page load) and shows `?loginError=` messages
  (`LOGIN_ERROR_LOCALE_KEYS`). It includes the privacy notice (`portal.privacy.*`, with `{days}` = 90 from
  `AUDIT_RETENTION_DAYS`).
- **Behörigheter matrix** (`src/permissions/matrix.ts` holds the pure logic, `src/pages/PermissionsPage.tsx` the
  page):
  - Rows are the roles sorted by Discord position, highest first, then by name. Deleted roles are dimmed and
    marked with `perms.roleDeleted`.
  - Columns are grouped by type in `GRANT_TYPES` order. Within a type come the catalog keys (wildcard first), then
    keys found only in stored rows, and for `mdt_page` also all `MDT_PAGE_KEYS`.
  - Clicking a cell cycles none → allow → deny → none. Changed cells are outlined, and each role shows
    `perms.unsaved {count}` and has its own Save and Discard buttons.
  - Save sends `PUT /api/admin/roles/:id/grants` with the role's **full** effective row set. The rows are sorted by
    type and then key, and `none` cells are dropped.
  - The save is optimistic: the cached rows are replaced and the draft cleared right away, and the role's cells are
    locked while the request runs. On error, the role's previous rows **and its draft** are restored (the admin
    can retry without redoing the clicks) and the `errors.*` message is shown. A `csrf` refusal also re-reads
    `/api/session`, so the retry carries a fresh token, and shows `perms.csrfRetry` ("Sessionen förnyades. Försök
    spara igen.") instead of `errors.csrf`, which says to reload and would drop the restored edits (pending key;
    `errors.csrf` is the fallback until the merge). On success, `perms.saved {count: recomputed}` is shown.
    Either way the page refetches afterwards.
  - **Add column.** The catalog only knows units, tiers, known perms and tools, plus keys already stored. The form
    next to the filter (type + key + Lägg till) adds a local column for weapon, vehicle, armory, tool, perm or
    **Tjänstegrad** (`perm:rank:<key>`, the prefix is added). Keys are checked with `AdminRoleGrantSchema`, the
    same schema as the PUT body; an invalid key shows `errors.validation`. The column stays once a role is saved
    with Tillåt or Neka in it. Rank columns are labelled `Tjänstegrad · <key>`. Unit is **not** addable: the
    service refuses a unit key that is neither in `config/units.json` nor already on the role, and the catalog
    already lists both, so a new unit needs a units.json change first. mdt_page and intel_tier are always
    complete.
  - The browser tab title is set from `portal.title` at boot (`index.html` only has a neutral "FredPD").
- **Dev.** `pnpm --filter @fredpd/portal dev` serves http://localhost:5173 and proxies `/api`, `/auth`, `/avatar` and
  `/ws` (WebSocket) to `http://127.0.0.1:3000`. Set `PUBLIC_URL=http://localhost:5173` in `apps/service/.env` so
  that the OAuth redirect and the `/ws` Origin check match.

## Tests (`pnpm exec vitest run --project ui --project nui --project portal`)

- `packages/ui/test`
  - `i18n`: substitution, the en and then key fallback, `tx`, `onMissing`, and the real locale files.
  - `components`:
    - Notice renders only the notice text, and VisibilityGate behaves correctly for each result.
    - VirtualList renders about 15 of 5000 rows, moves its window on scroll, and does not recompute every row
      key on a scroll-driven re-render (stable `getItemKey`/`estimateSize`).
    - IconButton is a padding-free square (no `px-*`/`w-*`), text buttons keep their padding.
    - Badge levels, the SearchInput Enter and clear behaviour, and NavItem routing.
- `packages/ui/test/phase2.test.tsx`: Dialog (closed, labelled modal, focus in and back, backdrop/close button),
  Pagination, Textarea, VirtualListbox (window, keys, Enter/click activation, disabled rows).
- `apps/nui/test`
  - `search`: detection chip, Enter opens the top person / vehicle / case hit, a kontaktnotis top hit shows the
    results page with only the notice (aria-disabled, Enter stays), Shift+Enter lists, ↓ ↓ ↑ ↓ Enter opens the third
    hit, a 50-row page renders a window and pages, too short query posts nothing, masked hit without title.
  - `person`: absent facts not rendered, notice case = only the Notice (the case's number/title appear nowhere, not
    even through its record row), masked without title (null and absent), fines summed with formatCurrency, phase 5
    buttons disabled with tooltip, Efterlys → prefilled dialog → createBolo input parsed with BoloCreateInputSchema →
    refetch; vehicle page owner/flag/cases/history, Kontrollera hit/clear/unregistered.
  - `bolo`: `buildBoloCreateInput` / `checkBoloForm` (zod-parsed), list active/all, create via the subject picker,
    client validation + duplicate refusal, levels above tier disabled, resolve with note, perm hints.
  - `home`: variant selection, layouts, grant filtering, IGV / Utredning / Ledning (roster) rendering, server variant.
  - `tablets`: Ledning → Surfplattor, revoke with confirm, reinstate, perm and page guards.
  - `mocks`: a mock for every MDT action; every answer parses with its output schema, as built and after
    `toLuaWire` + `normalizeWire`; refusals; create → list → resolve, lazy expiry; dev URL params.
  - `client`: normalizeWire (nulls, `{}`/`[]`, unions), `{ error, reason }` → MdtClientError → errors.* keys,
    network errors, dev-build contract check, push invalidation per topic, pending locale layering.
  - `fetchNui`: mock mode, FiveM mode, errors and `debugData`.
  - `nav`: grant filtering, the 6-item cap with Meny, denies over the wildcard, unit priority, active paths, the Hem
    variant, and message parsing (Lua nil and `{}`).
  - `tablet`: open and close with visibility, Esc (also from the search field, and nothing when closed), the close
    button, an invalid payload, `onReady` (a message or a `debugData` open sent from it arrives), the first-paint
    log, nav filtering, the grants push with the route guard and the primary unit, header search, the Hem
    variant, and push invalidation (refetch while open; while closed only marked stale, refetched on open). The
    header search test now expects the results page (no hit to open) and the posted search input; the Hem test
    checks the grant-filtered cards/blocks and the single getHome call.
  - `theme`: the compiled NUI CSS never gives a selector that can reach the document (`*`, html, `:root`,
    `:host`, body, also compound: `html.dark`, `:root:not(…)`, `:where(html)`) a `color-scheme`; the guard is
    self-tested. `index.html` has no color-scheme meta, and its html/body carry no style or class (Tailwind
    utilities generated) that sets one. `#fredpd-tablet` is dark.
- `apps/portal/test`
  - `matrix`: the cycle, the draft bookkeeping, the PUT body, sorting, columns (with added ones) and `parseNewKey`.
  - `permissions`: rendering, cycling, the PUT body with the CSRF header, optimistic update and rollback of rows
    and draft (checked with a refetch that never answers), csrf refusal (retry message, rendered with the pending
    keys merged) then retry with the fresh token, adding a rank column and saving it (unit is not offered),
    discard, filter, perm gating, and the login page with the privacy notice.
  - `api`: headers, schema validation, error mapping, and 401 expiry.

## Deviations and open questions

1. **Lockfile (orchestrator action).** `packages/ui/package.json` now declares `@tanstack/react-virtual` (runtime)
   and `@testing-library/react` (dev), and both apps dropped the unused `@vitejs/plugin-react`. The versions are
   the ones the apps already use and are already in the pnpm store. **`pnpm-lock.yaml` (not owned here) has not
   been updated**: run `pnpm install --lockfile-only --offline` at the root and commit it, or `--frozen-lockfile`
   (pnpm's default under `CI=true`) fails with `ERR_PNPM_OUTDATED_LOCKFILE`.
2. **No `@vitejs/plugin-react`.** 6.x needs Vite 8 (it imports `vite/internal`) while the apps pin `vite ^7.3.6`,
   so it was removed from both apps. JSX is compiled by esbuild (`jsx: 'automatic'`), so there is no Fast Refresh
   in dev. To get it back: add plugin-react ^5 to the apps and their vite configs, or bump vite to ^8.
3. **Browser support.** Tailwind v4 CSS targets Chromium 111 and later (`@property`, `color-mix`). The Chromium
   version of FiveM's CEF has not been checked on the host (UNVERIFIED).
4. **`MDT_PAGE_KEYS`: done.** They live in `packages/types/src/mdtPages.ts` (exported from `@fredpd/types`),
   `packages/ui/src/mdtPages.ts` re-exports them, and `buildCatalog` always lists them, in nav order, and they are
   pinned in docs/contracts.md §C12. The portal's local merge in `buildColumns` (`apps/portal/src/permissions/matrix.ts`,
   not changed by that task) is now redundant but harmless: the keys already come from the catalog, so it adds nothing.
   It can be dropped when the portal is next touched.
5. **Locale keys.** `perms.addKey`, `perms.newKey` (the add-column form) and `perms.csrfRetry` are in
   `locales/pending/ui.json` and read with `tx()` until merged (`node scripts/merge-pending-locales.mjs`); after
   the merge they can become `t()`. Everything else uses existing keys; the matrix cell labels join existing labels with " · ".
6. **Phase 2 locale keys.** `locales/pending/nui.json` (16 keys: `bolo.create.*` picker/refusal texts,
   `bolo.expiry.none`, `bolo.field.subject`, `case.notice.subject`, `common.comingPhase5`, `home.myOpenCases`,
   `person.field.address`, `vehicle.checkHit/checkClear`, `visibility.masked.badge`, `visibility.notice.owner`).
   Merged (82fd2e9); the literal-key `tx()` calls are now `t()`. `tx()` remains only for data-built keys.
7. **BOLO kontaktnotis** (bolo.md open question 1): `BoloSchema` has no `visibility`, so a notice-shaped BOLO is
   shown as a normal row whose reason is the notice text (issuer etc. absent, so not rendered). A `visibility`
   field would let the NUI render it with `<Notice>` like case refs.
8. **Jail time** is shown as `time.duration.minutes` because the wire field is `jailMinutes`. If in-game "månader"
   are meant, switch to `charge.jailMonths`.
9. **Esc** on the results page and in dialogs closes the tablet (§5.2 "Esc always closes" wins); the task text's
   "Esc" for the results list is therefore the global close. Dialogs do not trap Tab.
10. **Hem variant** comes from the client unit first (no layout jump, follows grants pushes); the server's
    `variant` is used only without a known unit. The mock server answers `igv` for a member without a unit.
11. **UNVERIFIED in FiveM:** that fredpd_mdt's `cb(table)` delivers empty Lua tables as `[]`/`{}` in the way
    `normalizeWire` expects (both are handled), and CEF behaviour of the lazy Suspense fallback on first visit
    (all chunks are inlined, so it should resolve in the same tick).
