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
| qb-weapons | https://github.com/qbcore-framework/qb-weapons | qb | hard dependency of qb-inventory |
| qb-vehiclekeys | https://github.com/qbcore-framework/qb-vehiclekeys | both | used by qb-core |
| qb-banking | https://github.com/qbcore-framework/qb-banking | both | used by qb-core and for fines |
| progressbar | https://github.com/qbcore-framework/progressbar | both | used by qb-core |
| qb-menu | https://github.com/qbcore-framework/qb-menu | both | used by qb-policejob |
| qb-input | https://github.com/qbcore-framework/qb-input | both | used by qb-policejob and qb-doorlock |
| qb-minigames | https://github.com/qbcore-framework/qb-minigames | qb | used by qb-doorlock |
| LegacyFuel (or any fuel script with GetFuel/SetFuel) | https://github.com/InZidiuZ/LegacyFuel | both | set as Config.FuelResource in qb-policejob/qb-garages |
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

## 2. Put FredPD on the server (once)

Run these in PowerShell from the repo folder (`C:\FredPD\fredpd`), with your server's resources folder:

```powershell
.\scripts\link-server.ps1  -ServerResources "C:\Users\FiveM\Desktop\SalamDevQB\resources"
.\scripts\patch-server.ps1 --server "C:\Users\FiveM\Desktop\SalamDevQB\resources"
```

- **link-server** makes the server's `resources\[fredpd]` a junction to this clone, so updates need no copying. An
  existing `[fredpd]` folder is renamed to `[fredpd].bak-<time>`. Move that backup out of `resources\`.
- **patch-server** applies FredPD's patches to **your own** qb-policejob, qb-doorlock, qb-garages and ps-dispatch.
  It patches them in place, so your configs (doors, police locations) stay. Every touched file is backed up to
  `.server-backups\`. A patch that doesn't fit a customised file is reported, and nothing is changed for it.
- **Do not copy `resources\[upstream]` to the server.** Those are clean clones for development only.
- **Items:** FredPD adds the items itself at start (tablet `pd_tablet`, ram `pd_ram`, through qb-core's `AddItem`).
  qb-core is not patched.
- **Server config:** your settings go in `config\integrations.local.json` in the repo. It overrides
  `config\integrations.json`, and `git pull` never touches it. Example for a QBCore server:
  `{ "inventory": "qb-inventory", "target": "qb-target", "doorlock": "qb-doorlock", "prison": "qb-prison", "housing": "none" }`
- **Only for the ox stack:** install ox_inventory, ox_target and ox_doorlock from their release zips, and evidences
  from its v1.3.1 release zip. Then run patch-server again; it patches ox_inventory and evidences too.

After this, every later update is one command: see `docs/dev-loop.md`.

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
ensure fredpd_reloader   # console command fredpd_reload: restart all FredPD resources in order
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
| `… exists in more than one place (… [upstream] …)` | the whole `[upstream]` folder was copied to the server. **Delete `resources/[upstream]` on the server**; copy only the patched folders listed in step 2 over your existing copies |
| `ox_inventory` / `ox_doorlock`: "UI has not been built" | the git copy was installed. Use the **release zip**, then copy only FredPD's patched files over it (step 2). On the qb stack, don't run ox_inventory at all |
| qb-inventory **and** ox_inventory both started | pick one. Two inventories break items and shops. The qb stack uses qb-inventory; stop ox_inventory, ox_target, ox_doorlock, evidences and `fredpd_forensics` |
| `unknown target bridge "ox-target"` | a spelling mistake in `integrations.json` (use `ox_target` / `qb-target`). FredPD now also accepts dash spellings |
| `fredpd_bolo … Table 'fredpd_bolos' doesn't exist` on the very first start | fixed: BOLO and dispatch now wait for fredpd_core's migrations. On older builds, restart once |
| `No such export RegisterStash in resource ox_inventory` | ox_inventory failed to start (see "UI has not been built"), or you are on the qb stack with ox_inventory still running |
| `signedFetch POST /internal/events failed` | the FredPD service isn't running yet (step 5). Harmless until then |
| `prison adapter "xt-prison": resource xt-prison is missing` | set `"prison": "qb-prison"` if you run qb-prison (the default now), or `"none"` |
