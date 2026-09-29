# FredPD

Polisens MDT och tjänstesystem för en svensk Qbox-server (FiveM): surfplatta i spelet, efterlysningar, larm,
ärenden och rapporter, bevis, underrättelser, dörrforcering, plus en webbportal och en Discord-bot som styr
behörigheter via Discord-roller.

Swedish police MDT and job suite for a Qbox (qbx_core) FiveM server, with a web portal and a Discord bot that maps
Discord roles to in-game permissions. Licence: **GPL-3.0-only** (see `LICENSE`).

- **Setup: [`docs/SETUP.md`](docs/SETUP.md)** (HeidiSQL: `db/install.sql`) · Plan: [`IMPLEMENTATION.md`](IMPLEMENTATION.md) · Contracts: [`docs/contracts.md`](docs/contracts.md) ·
  Agent rules: [`CLAUDE.md`](CLAUDE.md) · Glossary: [`docs/glossary.md`](docs/glossary.md)
- Module notes: [`docs/modules/`](docs/modules) · Upstream pins: [`deps.lock.json`](deps.lock.json),
  [`docs/deps-verification.md`](docs/deps-verification.md) · Hosting: [`docs/hosting.md`](docs/hosting.md)
- In-game test checklists for Rami: `docs/test-phase-N.md`

## Repository layout

| Path | What |
|---|---|
| `resources/[fredpd]/` | FiveM resources: `fredpd_core` (permissions, DB, audit, HTTP bridge), `fredpd_mdt` (tablet), `fredpd_records`, `fredpd_bolo`, `fredpd_dispatch`, `fredpd_forensics`, `fredpd_intel`, `fredpd_breach`, `fredpd_devtools` (dev only) |
| `resources/[upstream]/` | fetched by `scripts/fetch-deps.sh` at the commits in `deps.lock.json`; never committed, never edited (patches in `patches/`) |
| `apps/nui` | React tablet UI (single-file Vite build → `fredpd_mdt/web/build`) |
| `apps/portal` | React web portal |
| `apps/service` | `fredpd_service`: Fastify API, Discord OAuth, discord.js bot, uploads, WebSocket |
| `packages/types` | zod schemas and the TS side of every shared contract (grants, canView, formats, HMAC, actions) |
| `packages/ui` | shared React components, theme, `t()` |
| `db/` | SQL migrations (applied automatically by `fredpd_core`) and seeds |
| `config/` | `formats.json`, `units.json`, `integrations.json` — server-specific settings, no rebuild needed |
| `locales/` | `sv.json` (product language) and `en.json` |
| `tests/lua/` | plain Lua 5.4 tests for the Lua modules (run outside the game) |

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

Full guide with service setup, tunnel and backups: [`docs/hosting.md`](docs/hosting.md). Short version:

1. **Upstream resources.** `scripts/fetch-deps.ps1` then `scripts/apply-patches.ps1` — clones ox_lib, oxmysql,
   ox_inventory, ox_target, ox_doorlock, qbx_core, qbx_police, evidences, ps-dispatch, screenshot-basic at the pinned
   commits into `resources/[upstream]/` and applies `patches/*.patch`.
2. **Build.** `pnpm install` and `scripts/build.ps1` — builds the tablet UI and copies locales, config, migrations
   and fixtures into the resources.
3. **server.cfg.** Start from `server.cfg.example`: ensure order (oxmysql, ox_lib, qbx_core, ox_inventory, ox_target,
   ox_doorlock, upstream police/evidence/dispatch, `fredpd_core`, then the other `fredpd_*`), `setr ox:locale sv`,
   `set fredpd_hmac_secret` (≥ 32 random chars, same value as the service), `set fredpd_service_url`. Never ensure
   `fredpd_devtools` in production.
4. **Database.** Nothing to import by hand: `fredpd_core` applies `db/migrations` and seeds on start and records them
   in `fredpd_migrations`. FredPD stores times in UTC itself; the MariaDB server's time zone does not matter.
5. **Service.** `apps/service/.env` from `.env.example` (Discord app + bot token, guild id, DB URL, the same HMAC
   secret, session secret); run it as a Windows service with NSSM; expose the portal with Cloudflare Tunnel.
6. **Discord.** Invite the bot with the Server Members intent. In the portal, open **Behörigheter** and map roles to
   grants (weapons, vehicles, tablet pages, units, intel tier, perms such as `bolo.create`).
7. **Verify.** In game as admin: `/fredpd_selftest` (with `fredpd_devtools` on a test server) must print 100 % pass;
   then follow `docs/test-phase-1.md` and `docs/test-phase-2.md`.

## Status

| Phase | Content | State |
|---|---|---|
| 0 | Monorepo, scripts, locales, formats, adapters | done |
| 1 | Migrations, HMAC bridge, grants, canView, service, Discord bot, Behörigheter | done (in-game test pending) |
| 2 | Tablet, search, person/vehicle pages, BOLO, Hem | in progress |
| 3 | Alerts (ps-dispatch bridge, toast, "Ta larm", portal live list) | contract ready (§C13) |
| 4 | qbx_police patch, evidence | contract ready (§C16) |
| 5 / 5b | Cases, reports, charges, POI, release requests / intel | contracts ready (§C14, §C15) |
| 6–8 | Breach, portal completion, polish | planned |

## Licence and borrowed code

GPL-3.0-only, required by the GPL-3.0 upstreams it builds on (qbx_police, evidences, bub-mdt). Borrowed code keeps
its original header. Nothing is taken from ps-mdt (CC BY-NC-SA). If FredPD is given or sold to another server, its
source must go with it.
