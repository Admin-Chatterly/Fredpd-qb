# FredPD — setup (Windows, txAdmin, HeidiSQL)

Short checklist for installing FredPD on an existing Qbox server. Follow it top to bottom. More detail, including
running things as Windows services, backups and Caddy, is in `docs/hosting.md`.

## You need

- A working Qbox server in txAdmin, with MariaDB and HeidiSQL.
- **Git for Windows** (includes Git Bash), **Node.js 22 LTS**, then in a terminal: `npm install -g pnpm`.
- A Discord application with a bot (https://discord.com/developers/applications):
  - under **Bot**, turn on **Server Members Intent** and copy the **token**;
  - under **OAuth2**, copy the **Client ID** and **Client Secret**;
  - under **OAuth2 → Redirects**, add `https://<your portal address>/auth/discord/callback`;
  - invite the bot to your Discord server with the `bot` scope.
- Two random secrets. Run this twice in a terminal and save both outputs:
  `node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"`.
  The first is the **HMAC secret**, the second the **session secret**.

## 1. Get and build FredPD

In Git Bash:

```bash
cd /c/FredPD
git clone https://github.com/Admin-Chatterly/Fredpd-qb.git fredpd
cd fredpd
pnpm install
./scripts/fetch-deps.sh      # downloads ox_*, qbx_policejob, evidences, ps-dispatch … at pinned versions
./scripts/apply-patches.sh   # applies FredPD's patches to them; every line must say "apply" or "ok"
./scripts/build.sh           # builds the tablet UI and copies locales/config into the resources
```

## 2. Copy resources to the server

- Copy `resources/[fredpd]/` into the server's `resources/` folder.
  Leave out `fredpd_devtools`; it is for test servers only.
- From `resources/[upstream]/`, copy **only** `qbx_policejob`, `ps-dispatch` and `ox_inventory` over the server's
  copies of those resources. Don't copy the others (ox_lib, qbx_core, …); your recipe already installed them, and
  two copies with the same name break startup.
- **evidences:** download the **v1.3.1 release zip** from https://github.com/noobsystems/evidences/releases
  (the git copy has no built laptop UI). Unpack it into `resources/[police]/evidences`. Then copy the files from
  `resources/[upstream]/evidences` over it, so the FredPD patches (Swedish locale, fixes) are included.
- The new ox_inventory items (tablet `pd_tablet`, ram `pd_ram`, the evidence items) come with the patched
  `ox_inventory` folder. Item images are optional.

## 3. Database (HeidiSQL)

1. Open HeidiSQL, connect, and **click the database Qbox uses** (the one in `mysql_connection_string`) so it is
   selected.
2. **File → Run SQL file…** → choose `C:\FredPD\fredpd\db\install.sql` → run it.
3. The last result shows `FredPD database installed`. It is safe to run again, and FredPD will not re-run it on
   start.

Using a separate DB user for the service (optional): in HeidiSQL, create user `fredpd` with a password and give it
SELECT, INSERT, UPDATE and DELETE on the Qbox database.

## 4. server.cfg

Add these lines (see `server.cfg.example` for comments). Put the `ensure` lines after your existing ox/qbx lines:

```cfg
setr ox:locale sv
set fredpd_hmac_secret "<HMAC secret>"
set fredpd_service_url "http://127.0.0.1:3000"

add_ace resource.ox_lib command.add_ace allow
add_ace resource.ox_lib command.remove_ace allow
add_ace resource.ox_lib command.add_principal allow
add_ace resource.ox_lib command.remove_principal allow

ensure qbx_policejob
ensure evidences
ensure ps-dispatch
ensure fredpd_core
ensure fredpd_mdt
ensure fredpd_records
ensure fredpd_bolo
ensure fredpd_dispatch
ensure fredpd_forensics
ensure fredpd_intel
ensure fredpd_breach
```

Never `ensure qbx_prison`: any client can use it to unlock any door. In `resources/[fredpd]/fredpd_core/config/integrations.json`, set
`housing` / `garage` to the scripts you actually run (`ps-housing` or `none`, `qbx_garages` or `none`).

## 5. The service (portal + Discord bot)

1. Copy `apps/service/.env.example` to `apps/service/.env` and fill in:
   - `FREDPD_DB_URL=mysql://<user>:<password>@127.0.0.1:3306/<the Qbox database>`
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

1. Restart the server in txAdmin. The console should show `fredpd_core ready` and no red FredPD errors.
2. Open the portal, log in with Discord, then go to **Behörigheter** to map Discord roles to grants:
   - units: `unit:igv`, `unit:span` …
   - tablet pages: `mdt_page:search`, `mdt_page:bolos`, `mdt_page:alerts`, `mdt_page:cases` …
   - weapons, vehicles and armory items
   - `perm:bolo.create`, `tool:ram` …

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
| Tablet does not open / "ingen behörighet" | the player's Discord role has no `mdt_page:*` grant, or they are off duty |
| Portal login says not a member | the bot isn't in the server, or Server Members Intent is off |
| Evidence laptop is blank | evidences was not installed from the release zip (step 2) |
