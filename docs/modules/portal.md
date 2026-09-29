<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Module: portal pages (task 7.1 UI)

The web portal (`apps/portal`) runs the tablet's MDT pages unchanged on a second transport, plus portal-only pages
(character picker, live Larm, Register, Ledning → Utlämningskö / Granskning, POI print view, public share page,
"Begär ut allmän handling"). Server side: docs/modules/portal-api.md (service + fredpd_mdt portal mode).

## MDT host and transport (`packages/ui/src/mdtHost.tsx`)

| Export | Meaning |
|---|---|
| `MdtTransport { mode: 'tablet' \| 'portal'; call(action, input) }` | Answers the dispatcher's raw JSON: the output or `{ error, reason? }`. Throws `MdtTransportError(action, status)` when nothing usable came back. |
| `MdtHostProvider { transport, session }` | `session` = the tablet's `MdtOpenPayload` shape (grants for menus, primary unit, `me`). |
| `useMdtHost()`, `useMdtTransport()`, `useMdtMode()` | `null` / `'tablet'` outside a provider. |
| `PORTAL_BLOCKED_ACTIONS`, `isActionAvailable(mode, action)`, `useActionAvailable(action)` | `close, checkPlate, takeAlert, leaveAlert, closeAlert, issueFine, setTabletRevoked, linkEvidence` (identical to the service's refusal list, apps/service/src/portal/actions.ts). |
| `PoiSheet`, `knownWarnings`, `POI_WARNINGS` | Presentational POI-blad (§5.3 "one component for NUI and portal"): renders only the fields it is given, only the four known warnings. |
| `IconPrint` | New icon (Skriv ut). |

Tablet (`apps/nui`): `api/transport.ts` `nuiTransport` (fetchNui). `callMdt(action, input, transport = nuiTransport)`,
`mdtQueryOptions(action, input, transport)`, and the hooks read `useTransport()` = host transport or `nuiTransport`.
`routes.tsx` wraps the tablet routes in `MdtHostProvider` (transport + the open payload); pages read the session
through `src/session.ts` (`useSession()` = host session) instead of `TabletContext`. NUI behaviour is unchanged
(all previous NUI tests pass unmodified; main chunk 154 → 158 kB).

World-only controls hidden in portal mode: Kontrollera (VehiclePage), take/leave/close (AlertRow), Utfärda
ordningsbot (ChargePicker), Spärra/Häv spärren (TabletsPage), Koppla till ärende (EvidencePage). Portal-only in shared
pages: PersonPage's POI-blad becomes a link to `/person/:cid/poi`; IntelSection's "needs intel.read" shows
`errors.notFound` (never "not authorised", §C15).

## Shared pages: why they stay in apps/nui

The pages import `@tanstack/react-query`, `react-router` and (lazily) `cytoscape`. `packages/ui` has none of them as
dependencies, so moving the files there needs a `package.json` change + `pnpm install` (lockfile), which this task may
not do. The portal therefore imports the page modules from `apps/nui/src` by relative path — only through two barrels
(`apps/portal/src/mdt/shared.ts`, utilities for the eager shell; `apps/portal/src/mdt/shared-pages.ts`, page-level
building blocks AlertRow/UnitsPanel/Roster/CasePicker/alert helpers that only lazy pages import, kept apart so they
never enter the main chunk; `src/i18n.ts` also reads `pendingMessages`) and one lazy registry (`apps/portal/src/mdt/pages.tsx`, every page
`React.lazy`, so each is its own portal chunk and Cytoscape stays in the graph chunk). Module resolution follows the
importing file, so both apps resolve the same physical react/react-query (pnpm store) and there is one copy in each
bundle. Tailwind: `apps/portal/src/index.css` has `@source "../../nui/src"`. A physical move to `packages/ui` (or a
`packages/pages`) is mechanical once the dependencies are added (integration request 1).

## Portal (`apps/portal`)

| Route | Page | Needs |
|---|---|---|
| `/share/:token` | `SharePage` (public; `GET /api/share/:token`, JSON) | nothing (no session) |
| `/` | tablet Hem, or the character picker | session |
| `/karaktar` | `CharacterPicker` (Byt karaktär) | session |
| `/sok`, `/person/:cid`, `/fordon/:plate` | tablet pages | character + `mdt_page:search` |
| `/person/:cid/poi` | `PoiPage` (getPoi, print, createShare) | character + `mdt_page:search` |
| `/efterlysning`, `/arenden`, `/arende/:id`, `/rapport/:id`, `/bevis`, `/brottskatalog` | tablet pages | character + page grant |
| `/intel/*` | tablet IntelSection | character + `mdt_page:intel`, else **not found** |
| `/larm` | `AlertsLivePage` | character + `mdt_page:alerts` |
| `/register` | `RosterPage` (getHome.roster) | character + `mdt_page:roster` |
| `/ledning`, `/ledning/surfplattor`, `/ledning/utlamning`, `/ledning/granskning` | `CommandSection` | character + `mdt_page:command`; Surfplattor perm `tablets.manage`; Utlämningskö and Granskning perm `records.admin` (else not found) |
| `/begar-ut` | `ReleaseRequestPage` | character |
| `/behorigheter` | `PermissionsPage` (unchanged) | perm `admin.permissions` (no character needed) |

- **Character flow.** `GET /api/session` gives `user.citizenid` (null until picked). Without one, MDT routes show the
  picker (`GET /api/characters` → `[{ citizenid, name, lastSeen? }]`, invalid rows dropped); a pick POSTs
  `/api/session/character { citizenid }` with CSRF, removes every cached `['mdt', …]` answer, writes the citizenid
  into the cached session and re-reads it. The actor is the server-side session's character; the portal never sends
  one as the actor.
- **Transport** (`src/mdt/transport.ts`): `POST /api/mdt/:action`, `x-csrf-token` on every call (reads too), body =
  input. 2xx → body; `{ error }` bodies are returned to `callMdt` (same mapping as the tablet); service codes
  `forbidden → unauthorized`, `invalid_body → validation`, `internal → unavailable`; `csrf` re-reads the session;
  401 → the cached session becomes "logged out, expired" (login page shows `portal.sessionExpired`); a status
  without a readable `{ error }` → network. `PortalMdtHost` (src/mdt/PortalHost.tsx) builds the host session:
  grants from the session, `unit` = first valid unit, `me = { citizenid, displayName, callsign: null }`.
- **Nav** (`components/PortalLayout.tsx`): the tablet's nav model (`allowedNavEntries`, unit priority) without the
  6-slot cap, plus "Begär ut allmän handling" and Behörigheter; without a character only Hem (the picker) and
  Behörigheter. Header: the tablet's HeaderSearch (with `mdt_page:search`). Footer: name, Byt karaktär, Logga ut.
- **Larm** (read-only, live): `GET /api/alerts?filter=open|all&page=n`, `GET /api/units` once (age from
  `x-fredpd-units-received-at`), then `/ws`: `alertCreated`/`alertAssigned` → the tablet's `applyAlertChange` on every
  cached page, `alertClosed` removes, `unitsChanged` replaces. No polling: one `setTimeout` per close (1 s, doubling
  to 30 s) and one refetch of the lists after a reconnect; no reconnect after 4401 (session ended → login page), 4429
  (another tab) or a socket that never opened (refused upgrade; "Försök igen" button). Socket closed on unmount.
- **POI print view**: `PoiSheet` + "Skriv ut" (`window.print()`) + "Utskrivet {date} av {name}". Print CSS
  (`index.css` `@media print`): sidebar (`aside`, `print:hidden`), header and every `[data-print-hide]` (share box,
  buttons) hidden, `main` unrolled, sheet black on white. Full → handler + share box (createShare 1 h – 7 dygn, link
  `origin + path`, "Varje visning loggas."); masked → banner, no handler, no share; kontaktnotis → only `<Notice>`;
  `poi: null` → `poi.none`.
- **Share page**: POI → `PoiSheet masked` with only name/level/status/summary/warnings/photo/updated (the reader copies
  only those fields; a stray `citizenid`/owner in the answer never renders); case/report → `ReleasedContentView`
  (number, status, title, summary, dates, report title/body through MarkdownLite). 404 or a malformed token (no
  request) → `portal.share.expired`; `content` absent → `portal.share.withheld`. Never refetched (each view is logged).
- **Utlämningskö**: `listReleaseRequests { status: 'pending' | –, page }`, row → decide form (Lämna ut / med maskering /
  Avslå, grounds, target = the request's matched case/report or a case from the tablet's CasePicker) →
  `decideReleaseRequest { id, decision, note?, targetType?, targetId? }`; the answer's `released` content is shown
  (masked). Reasons `no_target`, `nothing_releasable`, `already_decided` have their own texts.
- **Granskning**: placeholder (`portal.audit.pending`); no audit-read action exists (integration request 3).
- **Register**: `getHome.roster`. fredpd_mdt fills it only for the Ledning variant and only with on-duty officers
  online (integration request 4).
- **Begär ut**: `createReleaseRequest { description (3–2000 code points), reference? (≤ 48) }` → `release.submitted`.
- Actions not in the packages/types registries yet (`getPoi`, `createShare`, `listReleaseRequests`,
  `decideReleaseRequest`, `createReleaseRequest`) go through `src/mdt/extra.ts`: same error path as `callMdt`, hand-written
  readers of fredpd_records' wire shapes (records.md, `test/proposed.ts`) that accept Lua's absent nulls and copy only
  the listed fields; a mismatch is `unknown`/`contract`.
- **Unknown action placeholder**: while those actions are not registered, the service answers
  `{ error: 'validation', reason: 'action' }`; `components/NotAvailableYet.tsx` (`isActionMissing`) turns that into
  `portal.notAvailableYet` on Begär ut (replaces the form), POI-blad (sheet and share box) and Utlämningskö, instead of
  a validation error.
- **POI photos**: `mdt/extra.ts` `safePhotoUrl` keeps only our own uploads, rewritten to the same-origin path
  `/upload/<name>.<ext>` (fredpd_records' `photoInput` stores only `/upload/` files, relative or on the service base);
  any other host, scheme, query or `..` → no `<img>` (the anonymous share viewer never contacts a third party).
- **Character switch** drops every query cache except `['session']` and `['characters']` (MDT answers and the live
  `portalAlerts`/`portalUnits` lists of the previous character).
- Build: same vendor `manualChunks` as the NUI, `chunkSizeWarningLimit` 600.

### Bundle (`pnpm --filter @fredpd/portal build`, 2026-09-29)

| Chunk | Size | gzip |
|---|---|---|
| main `index-*.js` (shell, action schemas, nav, login, permissions) | 166 kB | 53 kB |
| `vendor-*.js` | 391 kB | 120 kB |
| `cytoscape.esm-*.js` (intel graph only) | 443 kB | 142 kB |
| IntelSection / ReportPage / CasePage / AlertsLivePage / CommandSection / PoiPage | 25 / 12 / 10 / 8.6 / 6.5 / 3.1 kB | 6.3 / 4.1 / 3.0 / 3.4 / 2.4 / 1.4 kB |
| CSS | 26 kB | 6.0 kB |

NUI (`pnpm --filter @fredpd/nui build`): main 158 kB (49 kB gzip), vendor 390 kB, cytoscape 443 kB, CSS 22.6 kB;
split unchanged (`test/bundle.test.ts` green).

## Locale keys

`locales/pending/portal-ui.json` (11 keys, incl. `portal.notAvailableYet`, read with `tx()`; the portal's i18n now layers `locales/pending/*.json`
like the NUI): `portal.live.otherTab`, `portal.live.offline`, `portal.live.unitsAge`, `portal.audit.pending`,
`portal.share.withheld`, `poi.none`, `release.field.target`, `release.error.noTarget`,
`release.error.nothingReleasable`, `release.error.alreadyDecided`.

## Tests

- `packages/ui/test/portal.test.tsx` (4): host/mode/`useActionAvailable`, PoiSheet fields and masking.
- `apps/nui/test/transport.test.tsx` (5): tablet routes use fetchNui; the same VehiclePage on another host transport
  never calls fetchNui and hides Kontrollera in portal mode; tablet-mode host keeps it; `callMdt` transport argument;
  blocked list = real action names.
- `apps/portal/test/transport.test.ts` (7), `portal.test.tsx` (21: character flow incl. CSRF and cache drop (MDT and live alert/unit caches), unknown-action placeholder on Begär ut / Utlämningskö / POI, shared
  pages on `/api/mdt` answered by the tablet's mock register in Lua wire shape, world-only controls hidden, grant
  nav/route filtering, intel 404, release decide + refusal, Ledning perms, audit placeholder, roster, release form,
  401), `share.test.tsx` (10: `safePhotoUrl` allow-list, share page drops a third-party photo, share page masked fields only, case content, expired/malformed, withheld; POI print view,
  print CSS, masked/notice sheet, share link), `alerts.test.tsx` (4: live list, backoff/catch-up/4429, never-opened
  and 4401, close on unmount). Existing `api`, `matrix`, `permissions` unchanged and green.

## UNVERIFIED

1. End to end against the real service/FXServer (tests use a fake service); in particular `/ws` behind Cloudflare and
   the real `unitsChanged` cadence.
2. `window.print()` output in real browsers (print CSS checked only as text; jsdom has no print layout).
3. `getHome.roster` for a portal actor (fredpd_mdt computes the variant from the virtual actor's unit).
4. That fredpd_mdt's portal mode answers `getPoi`/`createShare`/release actions at all (they are not registered yet,
   see requests 1–2); until then those pages show `portal.notAvailableYet`.
5. That the service serves `GET /upload/<file>` to the browser: only `POST /upload` exists in apps/service, so POI
   photos (now same-origin `/upload/...` only) do not load yet (integration request 7).

## Contract additions (for the orchestrator to merge into docs/contracts.md)

- **§C12/§C6 portal host.** `packages/ui` `MdtTransport`/`MdtHostProvider`; the portal refuses/hides
  `PORTAL_BLOCKED_ACTIONS` = `close, checkPlate, takeAlert, leaveAlert, closeAlert, issueFine, setTabletRevoked,
  linkEvidence` (same list as apps/service `PORTAL_ACTIONS` complement).
- **§C6** `GET /api/share/:token` (no session) → `{ targetType: 'poi'|'case'|'report', expiresAt, content? }`,
  404 `not_found` for unknown/expired/revoked; the SPA uses this path. `GET /api/characters` items may carry an
  optional `lastSeen` (ISO UTC).
- **§C14** the portal calls `getPoi`, `createShare`, `listReleaseRequests`, `decideReleaseRequest`,
  `createReleaseRequest` with the shapes of fredpd_records (`test/proposed.ts`); they belong in `RECORDS_ACTIONS`.

## Integration requests

1. **packages/types + dispatcher + service (records/mdt/service owners):** add `getPoi`, `updatePoi`, `createShare`,
   `revokeShare` (`mdt_page:search`), `listReleaseRequests`, `decideReleaseRequest` (`perm:records.admin`) and
   `createReleaseRequest` (no grant; in portal mode routed to `createReleaseRequestPortal({ discordId, name, description,
   reference })`) to `RECORDS_ACTIONS` with the proposed zod shapes, to fredpd_mdt's `M.ALLOWED` and the service's
   `PORTAL_ACTIONS`. Then `apps/portal/src/mdt/extra.ts` can be replaced by the typed hooks. Adding
   `@tanstack/react-query`, `react-router` (+ `cytoscape`) to `packages/ui` dependencies (`pnpm install`) would let
   the pages move there physically.
2. **fredpd_mdt portal mode**: `createReleaseRequest` needs the character's name for `requesterName`.
3. **Audit view (Granskning):** a read action, e.g. `listAudit { actor?, action?, targetType?, targetId?, page }`
   (perm `records.admin`, fredpd_audit rows ≤ 90 days, 50 per page, officer labels, `meta.label` only), for the
   portal page that is a placeholder now.
4. **Roster:** a `listRoster { page }` action (`mdt_page:roster`: every `fredpd_officers` row with on/off duty,
   callsign, unit, last seen) — getHome only has on-duty officers and only for Ledning.
5. **Tablets in the portal:** if Ledning should revoke tablets from the portal, allow `setTabletRevoked` in portal
   mode (it is a pure DB write) and drop it from `PORTAL_BLOCKED_ACTIONS`.
6. **Locale owner:** merge `locales/pending/portal-ui.json`.
7. **Service:** serve uploaded images at `GET /upload/:file` (`<32 hex>.<png|jpg|webp>`, from `UPLOAD_DIR`, stored
   MIME, `nosniff`, long cache) — the portal renders POI photos only from that same-origin path.
