# FredPD

Polisens MDT och tjänstesystem för en svensk FiveM-server på **QBCore** (qb-core, qb-inventory, qb-target,
qb-doorlock, qb-policejob): surfplatta i spelet, efterlysningar, larm, ärenden och rapporter, bevis, underrättelser,
dörrforcering, plus en webbportal och en Discord-bot som styr behörigheter via Discord-roller.

Swedish police MDT and job suite for a **QBCore** FiveM server, with a web portal and a Discord bot that maps Discord
roles to in-game permissions. FredPD never calls the framework directly: `fredpd_core`'s bridge
([docs/contracts.md §C17](docs/contracts.md)) selects qb-core + qb-inventory/qb-target/qb-doorlock (the default) or
the ox scripts (ox_inventory/ox_target/ox_doorlock, and qbx_core on Qbox) in `config/integrations.json`, with no code
or database change. Licence: **GPL-3.0-only** (see `LICENSE`).

- **Setup: [`docs/SETUP.md`](docs/SETUP.md)** (HeidiSQL: `db/install.sql`) · Plan: [`IMPLEMENTATION.md`](IMPLEMENTATION.md) · Contracts: [`docs/contracts.md`](docs/contracts.md) ·
  Agent rules: [`CLAUDE.md`](CLAUDE.md) · Glossary: [`docs/glossary.md`](docs/glossary.md)
- Module notes: [`docs/modules/`](docs/modules) · Upstream pins: [`deps.lock.json`](deps.lock.json),
  [`docs/deps-verification.md`](docs/deps-verification.md) · Hosting: [`docs/hosting.md`](docs/hosting.md)
- In-game test checklists for Rami (≤ 10 steps each): [Phase 1](docs/test-phase-1.md) ·
  [2](docs/test-phase-2.md) · [3](docs/test-phase-3.md) · [4](docs/test-phase-4.md) · [5](docs/test-phase-5.md) ·
  [5b](docs/test-phase-5b.md) · [6](docs/test-phase-6.md) · [7](docs/test-phase-7.md) · Performance: [`docs/perf.md`](docs/perf.md)

## Repository layout

| Path | What |
|---|---|
| `resources/[fredpd]/` | FiveM resources: `fredpd_core` (permissions, DB, audit, HTTP bridge), `fredpd_mdt` (tablet), `fredpd_records`, `fredpd_bolo`, `fredpd_dispatch`, `fredpd_forensics`, `fredpd_intel`, `fredpd_breach`, `fredpd_devtools` (dev only) |
| `resources/[upstream]/` | fetched by `scripts/fetch-deps.sh` at the commits in `deps.lock.json` (qb-core, qb-policejob, qb-inventory, qb-target, qb-doorlock, qb-garages, ps-dispatch, and the ox/qbx alternatives); never committed, never edited (patches in `patches/`) |
| `apps/nui` | React tablet UI (code-split Vite build → `fredpd_mdt/web/build`) |
| `apps/portal` | React web portal |
| `apps/service` | `fredpd_service`: Fastify API, Discord OAuth, discord.js bot, uploads, WebSocket |
| `packages/types` | zod schemas and the TS side of every shared contract (grants, canView, formats, HMAC, actions) |
| `packages/ui` | shared React components, theme, `t()` |
| `db/` | SQL migrations (applied automatically by `fredpd_core`) and seeds |
| `config/` | `formats.json`, `units.json`, `integrations.json` — server-specific settings, no rebuild needed |
| `locales/` | `sv.json` (product language) and `en.json` |
| `tests/lua/` | plain Lua 5.4 tests for the Lua modules (run outside the game) |
| `scripts/perf/` | `db-perf.mjs`: seeds a scratch DB and times the hot queries (docs/perf.md) |

## Development

Requirements: Node 22, pnpm 10, Lua 5.4 (`lua5.4`/`luac5.4` on PATH), MariaDB 10.11 for the DB-backed tests
(`FREDPD_TEST_DB_URL`, default `mysql://fredpd:fredpd@127.0.0.1:3306/fredpd_test`; the user needs rights to create
`fredpd_test_*` databases — tests skip with a warning when the DB is unreachable).

```bash
pnpm install
pnpm lint        # ESLint + TypeScript + Lua syntax check + no-polling-loop check
pnpm test        # Vitest (TS + FiveM JS) + Lua 5.4 suite
pnpm build       # typecheck + Vite builds
pnpm --filter @fredpd/nui dev      # tablet UI in a browser with mock data
pnpm --filter @fredpd/portal dev   # portal (proxies /api, /auth, /ws to the service on :3000)
```

On Windows use Git Bash for `scripts/*.sh` or the PowerShell twins `scripts/*.ps1`; both run the same Node scripts.

## Installing on the server (txAdmin, Windows host)

**Follow [`docs/SETUP.md`](docs/SETUP.md)**: the step-by-step checklist for a QBCore server (dependencies with links,
`scripts\fetch-deps.ps1` + `scripts\apply-patches.ps1`, `scripts\build.ps1`, server.cfg ensure order and convars,
`db/install.sql` for HeidiSQL or automatic migrations, `apps/service/.env`, Discord bot and role mapping). Running the
service and the Cloudflare Tunnel as Windows services, backups and Caddy: [`docs/hosting.md`](docs/hosting.md).
Afterwards, as admin on a **test** server with `fredpd_devtools`: `/fredpd_selftest` must print 100 % pass, then work
through the phase checklists above. Never ensure `fredpd_devtools` in production.

## Status

"Code done" = implemented, reviewed, `pnpm lint && pnpm test` green; the in-game checklist is what Rami still runs.

| Phase | Content | Code | In-game checklist |
|---|---|---|---|
| 0 | Monorepo, scripts, locales, formats, adapters, upstream pins | done | – |
| 1 | Migrations, HMAC bridge, grants, canView, service, Discord bot, Behörigheter | done | [test-phase-1](docs/test-phase-1.md) |
| 2 | Tablet, search, person/vehicle pages, BOLO, Hem, Surfplattor | done | [test-phase-2](docs/test-phase-2.md) |
| 3 | Alerts: ps-dispatch bridge, toast, "Ta larm", radar/garage BOLO hits, portal live list | done | [test-phase-3](docs/test-phase-3.md) |
| 4 | qb-policejob patch (grants, armory, garage, Swedish), evidence (ox stack) | done | [test-phase-4](docs/test-phase-4.md) |
| 5 | Cases, reports (autosave + draft restore), charges, ordningsbot, POI, release requests, obehörig sökning | done | [test-phase-5](docs/test-phase-5.md) |
| 5b | Intel: sources, reports, entities, links, missions, graph | done | [test-phase-5b](docs/test-phase-5b.md) |
| 6 | Breach (ram, doorlock bridge, scene evidence), housing adapters | done | [test-phase-6](docs/test-phase-6.md) |
| 7 | Portal completion (character picker, MDT pages, Ledning, hardening, hosting) | done | [test-phase-7](docs/test-phase-7.md) |
| 8 | Polish: perf (8.1), Swedish string pass (8.2), final security review + install guide (8.3) | 8.1 done (DB part; resmon pending in game, [perf](docs/perf.md)); 8.2, 8.3 open | – |

Known gaps: the portal's POI-blad, share links, Utlämningskö and "Begär ut" wait for their actions to be registered in
`packages/types` and the fredpd_mdt dispatcher (docs/modules/portal.md, records.md "Integration requests"); Ledning →
Granskning has no audit-read action yet. Deviations from the plan: [IMPLEMENTATION.md, appendix](IMPLEMENTATION.md).

## Licence and borrowed code

GPL-3.0-only, required by the GPL-3.0 upstreams it builds on (qb-policejob, qbx_police, evidences, bub-mdt). Borrowed code keeps
its original header. Nothing is taken from ps-mdt (CC BY-NC-SA). If FredPD is given or sold to another server, its
source must go with it.
