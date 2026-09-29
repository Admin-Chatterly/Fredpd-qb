# FredPD — agent rules

FredPD is a Swedish police MDT/job suite for a Qbox (qbx_core) FiveM server, plus a web portal and Discord bot.
Licence GPL-3.0. Product language Swedish; code identifiers English.

Read before writing code:
1. `IMPLEMENTATION.md` — the plan (§0 rules, §4 cross-cutting design, §5 module spec for your module, §7 task card).
2. `docs/contracts.md` — pinned interfaces (grants, canView, formats, HMAC, endpoints, DB, locale). Change the
   contract first if you must change an interface.
3. `PLAN.md` — requirements (not yet committed; see the ASSUMED notes in docs/contracts.md).

Hard rules (reviewer rejects violations):
- Server is authoritative: every net event/callback does `local src = source`, grant check via fredpd_core, rate limit.
  Never take the actor's citizenid from the client.
- No idle polling: no `while true`, no `Citizen.CreateThread` loops, no `setInterval` in NUI/portal.
- No hardcoded player-facing text: `L()` in Lua, `t()` in TS, strings in `locales/sv.json` + `locales/en.json`.
- Every write to `fredpd_*` tables goes through fredpd_core helpers that also write `fredpd_audit`.
- Upstream resources are never edited; changes go in `patches/<resource>.patch`.
- Never copy code from ps-mdt (CC BY-NC-SA). Borrowed GPL/MIT code keeps its header.
- Secrets only in `server.cfg` convars / `apps/service/.env` (both git-ignored).
- Tiers, units and sensitive flags never go in statebags.

Commands:
- `pnpm install` · `pnpm lint` (eslint + typecheck + Lua syntax/polling lint) · `pnpm test` (Vitest + Lua 5.4 tests)
- `pnpm build` · `node scripts/migrate.mjs` (apply db/migrations to `FREDPD_DB_URL`)
- `scripts/fetch-deps.sh` + `scripts/apply-patches.sh` (or the `.ps1` twins on Windows)

Definition of done: code + task acceptance test + reviewer approval + `pnpm lint && pnpm test` green.
Agents cannot play: end each phase with `docs/test-phase-N.md` (≤ 10 in-game steps for Rami).
