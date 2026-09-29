# FredPD — setup (Windows, txAdmin, HeidiSQL)

Short checklist for installing FredPD on an existing **QBCore** server. Follow it top to bottom. More detail,
including running things as Windows services, backups and Caddy, is in `docs/hosting.md`.

FredPD talks to the framework, inventory, target and doorlock through `fredpd_core`'s bridge (docs/contracts.md
§C17). Two stacks are supported; pick one in `config/integrations.json` (step 4):

| | Default: qb stack | Alternative: ox stack |
|---|---|---|
| Framework | qb-core | qb-core (or qbx_core on Qbox) |
| Inventory / target / doorlock | qb-inventory, qb-target, qb-doorlock | ox_inventory, ox_target, ox_doorlock |
| Evidence (fredpd_forensics + evidences laptop, chain of custody) | **off**: qb-policejob keeps its own evidence | **on** (evidences needs ox_inventory + ox_target) |
| xt-prison item confiscation, prison break | off (xt-prison calls ox_inventory / ox_doorlock) | on |

Switching later = change the four values in `integrations.json`, install the other resources, restart. No database
change.

## You need

- A working QBCore server in txAdmin, with MariaDB and HeidiSQL.
- **Git for Windows** (includes Git Bash), **Node.js 22 LTS**, then in a terminal: `npm install -g pnpm`.
- A Discord application with a bot (https://discord.com/developers/applications):
  - under **Bot**, turn on **Server Members Intent** and copy the **token**;
  - under **OAuth2**, copy the **Client ID** and **Client Secret**;
  - under **OAuth2 → Redirects**, add `https://<your portal address>/auth/discord/callback`;
  - invite the bot to your Discord server with the `bot` scope.
- Two random secrets. Run this twice in a terminal and save both outputs:
  `node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"`.
  The first is the **HMAC secret**, the second the **session secret**.

## Dependencies

| Resource | Link | Stack | Notes |
|---|---|---|---|
| oxmysql | https://github.com/overextended/oxmysql/releases | both | release zip |
| ox_lib | https://github.com/overextended/ox_lib/releases | both | release zip; FredPD needs it on qb too |
| qb-core | https://github.com/qbcore-framework/qb-core | both | **patched copy** (FredPD items) |
| qb-policejob | https://github.com/qbcore-framework/qb-policejob | both | **patched copy** (grants, BOLO hooks, Swedish) |
| qb-inventory | https://github.com/qbcore-framework/qb-inventory | qb | unmodified |
| qb-target | https://github.com/qbcore-framework/qb-target | qb | unmodified; needs PolyZone |
| qb-doorlock | https://github.com/qbcore-framework/qb-doorlock | qb | **patched copy** (door export + event) |
| qb-garages | https://github.com/qbcore-framework/qb-garages | optional | **patched copy** (park/take-out events for BOLO) |
| PolyZone | https://github.com/mkafrin/PolyZone | qb | used by qb-target and qb-garages |
| ps-dispatch | https://github.com/Project-Sloth/ps-dispatch | both | **patched copy** |
| xt-prison | https://github.com/xT-Development/xt-prison/releases | optional | release zip v1.4.9, unmodified |
| ps-housing | https://github.com/Project-Sloth/ps-housing | optional | unmodified |
| ox_inventory | https://github.com/overextended/ox_inventory/releases | ox | release zip + **patched files** |
| ox_target | https://github.com/overextended/ox_target/releases | ox | release zip |
| ox_doorlock | https://github.com/overextended/ox_doorlock/releases | ox | release zip |
| evidences | https://github.com/noobsystems/evidences/releases | ox | release zip v1.3.1 + **patched files** |

## 1. Get and build FredPD

In Git Bash:

```bash
cd /c/FredPD
git clone https://github.com/Admin-Chatterly/Fredpd-qb.git fredpd
cd fredpd
pnpm install
./scripts/fetch-deps.sh      # downloads qb-*, ox_*, evidences, ps-dispatch … at pinned versions
./scripts/apply-patches.sh   # applies FredPD's patches to them; every line must say "apply" or "ok"
./scripts/build.sh           # builds the tablet UI and copies locales/config into the resources
```

## 2. Copy resources to the server

- Copy `resources/[fredpd]/` into the server's `resources/` folder.
  Leave out `fredpd_devtools`; it is for test servers only.
- From `resources/[upstream]/`, copy **only** these patched folders over the server's copies:
  `qb-core`, `qb-policejob`, `qb-doorlock`, `ps-dispatch`, and `qb-garages` if you run it.
  Don't copy the others (qb-inventory, qb-target, ox_lib, qbx_*, …); two copies with the same name break startup.
- **Back up the server's `qb-core` first.** Copying replaces local edits (`shared/jobs.lua`, `shared/items.lua`,
  `config.lua`). If yours has edits, re-apply them afterwards, or keep your copy and add only the FredPD item entries
  from `patches/qb-core.10-fredpd-items.patch`.
- The new items (tablet `pd_tablet`, ram `pd_ram`) come with the patched `qb-core` (`shared/items.lua`). Item images
  are optional.
- **xt-prison** (optional): unpack the v1.4.9 release zip into `resources/[standalone]/xt-prison`. In its
  `configs/server.lua`, set `PoliceJobs = { 'police' }`.
- **Only for the ox stack:** install ox_inventory, ox_target and ox_doorlock from their release zips, then copy
  `resources/[upstream]/ox_inventory` over it (FredPD items). For evidence: unpack the **evidences v1.3.1 release
  zip** into `resources/[police]/evidences` (the git copy has no built laptop UI), then copy
  `resources/[upstream]/evidences` over it.

## 3. Database (HeidiSQL)

1. Open HeidiSQL, connect, and **click the database QBCore uses** (the one in `mysql_connection_string`) so it is
   selected.
2. **File → Run SQL file…** → choose `C:\FredPD\fredpd\db\install.sql` → run it.
3. The last result shows `FredPD database installed`. It is safe to run again, and FredPD will not re-run it on
   start.

Using a separate DB user for the service (optional): in HeidiSQL, create user `fredpd` with a password and give it
SELECT, INSERT, UPDATE and DELETE on the QBCore database.

## 4. server.cfg and integrations

Add the FredPD lines from `server.cfg.example` (secrets, locale, ACE lines, `ensure` order). The `ensure` lines go
after your existing qb lines:

```cfg
setr ox:locale sv
setr qb_locale sv
set fredpd_hmac_secret "<HMAC secret>"
set fredpd_service_url "http://127.0.0.1:3000"

ensure qb-policejob
ensure ps-dispatch
ensure qb-garages
ensure xt-prison
ensure fredpd_core
ensure fredpd_mdt
ensure fredpd_records
ensure fredpd_bolo
ensure fredpd_dispatch
# ensure fredpd_forensics   # ox stack only (needs ox_inventory + ox_target)
ensure fredpd_intel
ensure fredpd_breach
```

Then edit `resources/[fredpd]/fredpd_core/config/integrations.json`:

```json
"framework": "qb-core", "inventory": "qb-inventory", "target": "qb-target", "doorlock": "qb-doorlock",
"garage": "qb-garages", "prison": "xt-prison", "housing": "ps-housing"
```

Use `"none"` for a garage, prison or housing script you don't run. For the ox stack use `ox_inventory`, `ox_target`,
`ox_doorlock`, and uncomment `ensure evidences` and `ensure fredpd_forensics` in step 4. Never `ensure qbx_prison`: any client can use it to unlock any door.

## 5. The service (portal + Discord bot)

1. Copy `apps/service/.env.example` to `apps/service/.env` and fill in:
   - `FREDPD_DB_URL=mysql://<user>:<password>@127.0.0.1:3306/<the QBCore database>`
   - `FREDPD_HMAC_SECRET=<HMAC secret>` (the same value as in server.cfg)
   - `SESSION_SECRET=<session secret>`
   - `DISCORD_CLIENT_ID`, `DISCORD_CLIENT_SECRET`, `DISCORD_BOT_TOKEN`
   - `DISCORD_GUILD_ID`: right-click your server in Discord → Copy Server ID (Developer Mode on)
   - `PUBLIC_URL=https://<your portal address>`
2. Test run: `cd apps/service && pnpm start`. It should log that the bot is ready and listening on port 3000.
   Stop it with Ctrl+C.
3. Make it permanent and reachable from the internet: `docs/hosting.md` §6 (NSSM service) and §7 (Cloudflare
   Tunnel to `http://localhost:3000`).

## 6. First start and permissions

1. Restart the server in txAdmin. The console should show `fredpd_core ready`, one `bridge:` line naming the stack,
   and no red FredPD errors.
2. Open the portal, log in with Discord, then go to **Behörigheter** to map Discord roles to grants:
   - units: `unit:igv`, `unit:span` …
   - tablet pages: `mdt_page:search`, `mdt_page:bolos`, `mdt_page:alerts`, `mdt_page:cases` …
   - weapons, vehicles and armory items
   - `perm:bolo.create`, `perm:police.jail`, `tool:ram` …

   The first admin needs `perm:admin.permissions`. Until someone has it, add that one row in HeidiSQL:
   `INSERT INTO fredpd_role_grants (discord_role_id, grant_type, grant_key, effect) VALUES ('<admin role id>', 'perm', 'admin.permissions', 'allow');`
   The role id comes from Discord: Server Settings → Roles → right-click the role → Copy Role ID. The insert only
   works after the service has started once, because the bot imports the Discord roles into `fredpd_roles` then.
   Afterwards, the admin logs out and in again on the portal.
3. In game: go on duty as police, `/giveitem <your id> pd_tablet 1`, then use the tablet. It should open in
   Swedish.

## Updating

```bash
cd /c/FredPD/fredpd && git pull && pnpm install && ./scripts/fetch-deps.sh && ./scripts/apply-patches.sh && ./scripts/build.sh
```

Then repeat step 2 (copy) and step 3 (run the new `db/install.sql`; running it again is safe), then restart the
service and the server.

## If something is wrong

| Symptom | Fix |
|---|---|
| `apply-patches` says "does not apply" | the upstream copy was changed: `./scripts/fetch-deps.sh --force`, then apply again |
| Console: "bridge disabled" / HMAC error | `fredpd_hmac_secret` and `FREDPD_HMAC_SECRET` differ or are shorter than 32 chars |
| Console: `resource … is missing` for an adapter or bridge | `integrations.json` names a script you don't run: set it to `none` (or the other stack) |
| Tablet does not open / "ingen behörighet" | the player's Discord role has no `mdt_page:*` grant, or they are off duty |
| Portal login says not a member | the bot isn't in the server, or Server Members Intent is off |
| Breach ram does nothing on a qb-doorlock door | the patched `qb-doorlock` copy was not installed (step 2) |
| No BOLO alert when a wanted car is parked | `qb-garages` is not the patched copy, or `"garage"` is not `qb-garages` |
| Evidence laptop is blank / missing | qb stack: expected (ox stack only); ox stack: evidences was not installed from the release zip |
