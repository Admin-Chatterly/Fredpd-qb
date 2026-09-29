<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Module: ui (tasks 0.1 web apps, 1.8 UI, 2.2)

Shared React layer (`packages/ui`), the tablet NUI shell (`apps/nui`) and the portal shell with the
"Behörigheter" page (`apps/portal`). Implements IMPLEMENTATION.md §4.4, §4.7, §5.2 (NUI routes), §5.9 (admin UI)
and docs/contracts.md §C8 (t()) and §C10 (permissions admin API, client side).

## packages/ui

| File | Content |
|---|---|
| `src/theme.css` | Tailwind v4 `@theme` tokens. Dark and flat. There is one accent hue (`accent`, `accent-strong`, `accent-text`, `accent-soft`), plus `canvas/surface/raised`, `line`, `fg/muted/subtle` and the status colours `success/warning/danger`. The base is 15 px (`html { font-size: 15px }`, so 1rem = 15 px). The default palette and shadows are removed (`--color-*: initial`), so pages can only use these tokens. Apps import it after `@import "tailwindcss"`. Its `@source "./"` makes Tailwind scan the shared components. It sets **no `color-scheme`** (see "color-scheme" below). |
| `src/i18n.tsx` | `createI18n(messages, { lang = 'sv', fallbackLang = 'en', onMissing })` returns `{ lang, t, tx, has }`. `t(key: LocaleKey, vars)` is typed through `LocaleArgs`, so vars are required exactly when the key has placeholders. `tx(key: string, vars?, fallback?)` handles keys built from data, such as ``tx(`unit.${code}`, undefined, code)``. Lookup order is lang, then en, then the key itself. `{name}` is substituted and a placeholder without a value is left as is. Also exports `I18nProvider`, `useI18n()` and `useT()`. Without a provider, components render their keys. |
| `src/components/*` | `Button` (primary/secondary/ghost/danger, `loading`), `IconButton` (a `label` is required; a padding-free square from `buttonClass(…, 'icon')`), `Input`/`Label` (`fieldClass` is the input look without a width, for `<select>`), `SearchInput` (controlled, trims on Enter, has a clear button), `Card`, `Badge` (`level={0\|1\|2}` gives Standard/Begränsad/Hemlig in neutral/warning/danger), `Notice` (kontaktnotis) and `VisibilityGate`, `EmptyState`, `Spinner` (CSS only), `VirtualList` (TanStack Virtual), `Table`, and the layout pieces `AppShell`, `Sidebar`, `NavItem`, `PageHeader`. |
| `src/mdtPages.ts` | `MDT_PAGE_KEYS` and their `nav.*` labels (see below). |
| `src/icons.tsx` | A small stroke icon set drawn for FredPD (`aria-hidden`). |

`cn()` only joins class names, and Tailwind orders utilities in its stylesheet, not by class order. So never
override a utility with another one for the same property (`px-0` over `px-3.5`, `w-52` over `w-full`): add a
variant (as `buttonClass` shapes do) or use a different property (`max-w-*`).

`Notice` takes only `subject` and `owner` (null means "Kontakta ledningen"). It never receives a record, so no record
field can reach the DOM. `VisibilityGate` renders content by `canView` result: `none` renders nothing, `notice`
renders only the Notice, `masked` renders a banner and the content, and `full` renders the content.

## Grant keys `mdt_page:<key>` (decided here)

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
- **Hem.** The variant comes from `config/units.json` `home` for the primary unit, or `default` when there is none.
  Each section is shown only with its `mdt_page` grant. Task 2.7 fills the sections with data.
- **Dev.** `pnpm --filter @fredpd/nui dev` serves http://localhost:5174 and opens the tablet with mock data. The
  mock open is sent from `TabletProvider`'s `onReady` (called once the message listener is attached); a message
  dispatched before that is lost. Use
  `?unit=tekniker&pages=search,cases` (or `unit=none`) to preview other units or grants. While the tablet is
  closed, a "Öppna surfplattan" button reopens it.
- **First paint.** Dev builds log `[fredpd] open -> first paint N ms`, measured on the second animation frame after
  the open message.

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
- `apps/nui/test`
  - `fetchNui`: mock mode, FiveM mode, errors and `debugData`.
  - `nav`: grant filtering, the 6-item cap with Meny, denies over the wildcard, unit priority, active paths, the Hem
    variant, and message parsing (Lua nil and `{}`).
  - `tablet`: open and close with visibility, Esc (also from the search field, and nothing when closed), the close
    button, an invalid payload, `onReady` (a message or a `debugData` open sent from it arrives), the first-paint
    log, nav filtering, the grants push with the route guard and the primary unit, header search, the Hem
    variant, and push invalidation (refetch while open; while closed only marked stale, refetched on open).
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
4. **`MDT_PAGE_KEYS` (orchestrator action with the types and service owners).** They are a cross-module contract
   (NUI routes, portal columns, and fredpd_mdt callbacks will check them server-side) but live in `packages/ui`
   because the types package is owned elsewhere. They should move to `packages/types`, be listed by
   `buildCatalog` in `apps/service/src/catalog.ts`, and be pinned in docs/contracts.md §C2. The portal can then
   drop its local merge in `buildColumns`.
5. **Locale keys.** `perms.addKey`, `perms.newKey` (the add-column form) and `perms.csrfRetry` are in
   `locales/pending/ui.json` and read with `tx()` until merged (`node scripts/merge-pending-locales.mjs`); after
   the merge they can become `t()`. Everything else uses existing keys; the matrix cell labels join existing labels with " · ".
