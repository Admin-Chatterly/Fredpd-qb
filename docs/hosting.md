<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Hosting FredPD on Windows

This guide sets up a Windows host (IMPLEMENTATION.md §1, §7 task 7.2, §8.11). The host runs these four processes:

| Process | How it runs | Listens on | Reachable from |
|---|---|---|---|
| MariaDB 10.11 | Windows service `MariaDB` (MSI installer) | `127.0.0.1:3306` | this PC only |
| FXServer + txAdmin | `FXServer.exe`, optionally as NSSM service `fxserver` | game `30120` TCP+UDP, txAdmin `40120` | players: 30120; txAdmin: this PC/LAN only |
| fredpd_service (portal API, Discord bot) | NSSM service `fredpd_service` | `127.0.0.1:3000` | this PC; the internet only through the tunnel/Caddy |
| cloudflared (default) or Caddy | Windows service `cloudflared` / NSSM service `caddy` | outbound only / `80`+`443` | the internet |

FXServer and the service talk to each other on loopback, with HMAC signatures (docs/contracts.md §C5/§C6):

- FXServer → `http://127.0.0.1:3000/internal/*`.
- The service → `http://127.0.0.1:30120/fredpd_core/*`.

The `/fredpd_core/*` routes share the public game port, so the HMAC secret is what protects them (§8).

Paths used below (change them freely, but consistently): repository `C:\FredPD\fredpd`, logs `C:\FredPD\logs`,
tools `C:\FredPD\tools`, backups `D:\Backups\FredPD`, FXServer `C:\FXServer\server`, server data
`C:\FXServer\txData\<profile>.base` (the folder txAdmin created for your Qbox recipe). Run the commands in
**PowerShell as Administrator**.

## 1. Prerequisites

- Windows 10/11 or Windows Server 2019+, with time sync on (`w32tm /query /status`). HMAC allows 60 s of clock skew.
- **Git for Windows**, which provides Git Bash for `scripts/*.sh`. The `.ps1` twins do the same thing.
- **Node.js 22 LTS** (`winget install OpenJS.NodeJS.LTS`). Then pnpm, which is pinned in package.json:
  `corepack enable; corepack prepare pnpm@10.33.0 --activate`.
- **NSSM** 2.24-101 or newer: the pre-release build, because 2.24 can fail to start services on Windows 10 1703+.
  Download it from nssm.cc and copy `win64\nssm.exe` to `C:\FredPD\tools\`. Add that folder to the system `PATH`.
- Clone the repository: `git clone https://github.com/Admin-Chatterly/Fredpd-qb C:\FredPD\fredpd`. If the
  repository is private, Git Credential Manager (part of Git for Windows) opens a GitHub sign-in the first time.
  Sign in with an account that can read the repository.
- Build it: `cd C:\FredPD\fredpd; pnpm install --frozen-lockfile; .\scripts\build.ps1`.
- Lock the folder down. On Windows 10/11, a folder made at the root of `C:` can be changed by every signed-in
  account, including the service accounts below. This makes `C:\FredPD` read-only for everyone except
  Administrators and SYSTEM. §6 and §7 then grant each service account only the folders it writes to:
  ```powershell
  icacls C:\FredPD /inheritance:r /grant:r "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F" "Authenticated Users:(OI)(CI)RX"
  ```

## 2. MariaDB

1. Install **MariaDB 10.11** (LTS) with the MSI from mariadb.org. You can also keep the one your Qbox server already
   uses. In the installer:
   - tick *Install as service* (name `MariaDB`) and *Enable networking* (port 3306);
   - tick *Use UTF8 as default server's character set*;
   - set a strong root password.
2. In `C:\Program Files\MariaDB 10.11\data\my.ini`, under `[mysqld]`, add `bind-address=127.0.0.1`. Then run
   `Restart-Service MariaDB`.
3. **No time-zone setting is needed.** FredPD stores every timestamp in UTC itself: it uses `UTC_TIMESTAMP()`
   defaults and writes, and reads DATETIME columns as ISO strings (docs/contracts.md §C7). Leave `default_time_zone`
   as it is (`SYSTEM`). The server may run on Swedish time.
4. FredPD tables live in the **same database as Qbox** (the one in `mysql_connection_string`). Create the users as
   root, with `mariadb -u root -p` or in HeidiSQL. Use your database name instead of `qbox`:

   ```sql
   -- FXServer (oxmysql). FredPD's migrations run through it, so it needs DDL rights (CREATE/ALTER/INDEX).
   CREATE USER IF NOT EXISTS 'fivem'@'127.0.0.1' IDENTIFIED BY '<password 1>';
   GRANT ALL PRIVILEGES ON `qbox`.* TO 'fivem'@'127.0.0.1';
   -- fredpd_service: data only, no DDL (it refuses to start until fredpd_core has migrated).
   CREATE USER IF NOT EXISTS 'fredpd_service'@'127.0.0.1' IDENTIFIED BY '<password 2>';
   GRANT SELECT, INSERT, UPDATE, DELETE ON `qbox`.* TO 'fredpd_service'@'127.0.0.1';
   -- Backups (§9): read-only.
   CREATE USER IF NOT EXISTS 'fredpd_backup'@'127.0.0.1' IDENTIFIED BY '<password 3>';
   GRANT SELECT, SHOW VIEW, TRIGGER, LOCK TABLES ON `qbox`.* TO 'fredpd_backup'@'127.0.0.1';
   ```

   Connection URLs must URL-encode special characters in passwords (for example `@` becomes `%40`).
5. Nothing needs to be imported by hand. `fredpd_core` applies `db/migrations` and the seeds when it starts, and
   records them in `fredpd_migrations`. For a dev database, `node scripts/migrate.mjs --url … --seed` does the same.

## 3. FXServer via txAdmin

1. Download the recommended **Windows server artifact** (runtime.fivem.net → `build_server_windows`) and extract it
   to `C:\FXServer\server`. Run `FXServer.exe` and open `http://localhost:40120`. Link your Cfx.re account and
   deploy the Qbox recipe, or keep your existing txAdmin profile.
2. Firewall: players need **30120 TCP and UDP** inbound. Do not open 40120 (txAdmin), 3000 or 3306 to the internet:
   ```powershell
   New-NetFirewallRule -DisplayName "FXServer 30120 TCP" -Direction Inbound -Protocol TCP -LocalPort 30120 -Action Allow
   New-NetFirewallRule -DisplayName "FXServer 30120 UDP" -Direction Inbound -Protocol UDP -LocalPort 30120 -Action Allow
   ```
3. Edit **server.cfg** in txAdmin → Settings → FXServer → CFG Editor. It lives in txData, never in the repository.
   Take the FredPD block from `server.cfg.example`: ensure order, `setr ox:locale sv`, the ACE lines,
   `set fredpd_hmac_secret`, `set fredpd_service_url "http://127.0.0.1:3000"`, and a
   `set mysql_connection_string "mysql://fivem:<password 1>@127.0.0.1:3306/qbox?charset=utf8mb4"` with
   `utf8mb4`. Use `set`, **never `setr` or `sets`, for secrets**: `setr` replicates the value to every client, and
   `sets` publishes it to the server list.
4. `ensure fredpd_devtools` belongs on the test server only (docs/test-phase-1.md), never in production.
5. **Autostart.** Turn on txAdmin → Settings → FXServer → *Autostart*, so the game server starts with txAdmin. Then
   run `FXServer.exe` as an NSSM service. The console is hidden then; use txAdmin's Live Console instead.
   - Give it its own local account. Without `ObjectName`, NSSM runs a service as LocalSystem. FXServer runs
     third-party Lua and JS with file and OS access, so a compromised resource would then control the whole PC.
   - The account can change `C:\FXServer` (artifact, txData, server data). It can only read `C:\FredPD` (§1), and
     it cannot read the service's `.env` (§6).
   ```powershell
   $pw = Read-Host -AsSecureString "Password for fxserver-svc"
   New-LocalUser -Name fxserver-svc -Password $pw -PasswordNeverExpires -AccountNeverExpires -Description "Runs FXServer and txAdmin"
   icacls C:\FXServer /inheritance:r /grant:r "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F" "fxserver-svc:(OI)(CI)M"
   nssm install fxserver "C:\FXServer\server\FXServer.exe"
   nssm set fxserver AppDirectory "C:\FXServer\server"
   nssm set fxserver DependOnService MariaDB
   nssm set fxserver Start SERVICE_DELAYED_AUTO_START
   nssm set fxserver ObjectName ".\fxserver-svc" "<the password you just typed>"
   nssm start fxserver
   ```
   A scheduled task *At startup* also works, if it runs as `fxserver-svc` (`/RU fxserver-svc`), not as SYSTEM.
   Error 1069 at start is fixed as in §6 step 4.

## 4. Upstream resources

The Qbox recipe already installs ox_lib, oxmysql, ox_inventory, ox_target, ox_doorlock, qbx_core and friends.
`deps.lock.json` records the versions FredPD was verified against (docs/deps-verification.md). Rules:

- `scripts\fetch-deps.ps1` clones every pinned upstream into `resources\[upstream]\`, and `scripts\apply-patches.ps1`
  applies `patches\*.patch`. That tree is for patching and review. **Never copy all of `resources\[upstream]` to the
  server.** A second copy of a resource the recipe already installed gives FXServer duplicate resource names, and it
  may start the unbuilt git copy.
- Resources with a `release` field (ox_*, evidences) run from **that release zip**, because git has no built UI. A
  resource FredPD patches (`mode: PATCH`) is deployed patched:
  - If it runs from a zip, extract the pinned zip, then inside that folder run
    `git apply C:\FredPD\fredpd\patches\<name>.*.patch`. `git apply` also works outside a repository.
  - Otherwise, copy the patched `resources\[upstream]\<name>`.
- Phase 1 needs no patched upstream. ps-dispatch (Phase 3) is the first one.

## 5. Deploying FredPD resources

Build in the repository, then copy `resources\[fredpd]` into the server data folder. Copying (instead of a junction)
means a `git pull` never changes files under a running server:

```powershell
cd C:\FredPD\fredpd
pnpm install --frozen-lockfile
.\scripts\build.ps1
robocopy "C:\FredPD\fredpd\resources\[fredpd]" "C:\FXServer\txData\<profile>.base\resources\[fredpd]" /MIR /XD test node_modules /NFL /NDL /NP
```

- `build.ps1` copies the locales, `config/*.json`, migrations and seeds, the self-test fixtures and the tablet UI
  into the resources.
- In **production**, add `fredpd_devtools` after `/XD`.
- robocopy exit codes 0–7 mean success, 8 and higher mean failure.
- Then restart the game server in txAdmin. Watch the Live Console for `[fredpd_core:db] applied …` (new migrations)
  or `up to date`, and for `fredpd_core ready`.

## 6. fredpd_service as a Windows service (NSSM)

1. Configuration: `copy apps\service\.env.example apps\service\.env` and fill it in. `.env.example` explains every
   key. In short:
   - `FREDPD_DB_URL=mysql://fredpd_service:<password 2>@127.0.0.1:3306/qbox`, the **same database** as oxmysql;
   - `FREDPD_HMAC_SECRET` is the same value as `fredpd_hmac_secret`;
   - `SESSION_SECRET` is a different random value;
   - the Discord client id, secret, bot token and guild id;
   - `PUBLIC_URL=https://polis.example.se` and `COOKIE_SECURE=true`.

   The service refuses to start while a placeholder is left in `.env`.
2. Discord application:
   - OAuth2 redirect `<PUBLIC_URL>/auth/discord/callback`;
   - the bot needs the **Server Members Intent** and must be a member of the guild.
3. A dedicated local account, so the service does not run as LocalSystem:
   ```powershell
   $pw = Read-Host -AsSecureString "Password for fredpd-svc"
   New-LocalUser -Name fredpd-svc -Password $pw -PasswordNeverExpires -AccountNeverExpires -Description "Runs fredpd_service"
   New-Item -ItemType Directory -Force C:\FredPD\logs, C:\FredPD\fredpd\apps\service\data | Out-Null
   icacls C:\FredPD\logs /grant "fredpd-svc:(OI)(CI)M"
   icacls C:\FredPD\fredpd\apps\service\data /grant "fredpd-svc:(OI)(CI)M"
   icacls C:\FredPD\fredpd\apps\service\.env /inheritance:r /grant:r "Administrators:F" "SYSTEM:F" "fredpd-svc:R"
   ```
4. Install the service. It runs `src/main.ts` through tsx, like `pnpm --filter @fredpd/service start`, and reads
   `apps\service\.env` itself. `AppDirectory` must be `apps\service`, because `UPLOAD_DIR` is relative to it. Check
   the node path with `(Get-Command node).Source`.
   ```powershell
   nssm install fredpd_service "C:\Program Files\nodejs\node.exe"
   nssm set fredpd_service AppParameters "--import tsx src/main.ts"
   nssm set fredpd_service AppDirectory "C:\FredPD\fredpd\apps\service"
   nssm set fredpd_service DisplayName "FredPD service"
   nssm set fredpd_service Description "FredPD portal API, Discord bot and FXServer bridge"
   nssm set fredpd_service Start SERVICE_DELAYED_AUTO_START
   nssm set fredpd_service DependOnService MariaDB
   nssm set fredpd_service AppEnvironmentExtra NODE_ENV=production
   nssm set fredpd_service AppStdout "C:\FredPD\logs\fredpd_service.log"
   nssm set fredpd_service AppStderr "C:\FredPD\logs\fredpd_service.log"
   nssm set fredpd_service AppRotateFiles 1
   nssm set fredpd_service AppRotateOnline 1
   nssm set fredpd_service AppRotateBytes 10485760
   nssm set fredpd_service AppExit Default Restart
   nssm set fredpd_service AppRestartDelay 5000
   nssm set fredpd_service AppStopMethodConsole 10000
   nssm set fredpd_service ObjectName ".\fredpd-svc" "<the password from step 3>"
   nssm start fredpd_service
   nssm status fredpd_service
   ```
   - The service exits with code 1 when the Discord login fails or the bot loses the guild, and NSSM then restarts
     it (`AppExit Default Restart`).
   - On stop, NSSM sends Ctrl+C. The service closes the bot, HTTP and the DB pool within `AppStopMethodConsole`.
   - Error 1069 at start means the account lacks *Log on as a service*. Grant it in `secpol.msc` → Local Policies →
     User Rights Assignment.
5. Check it:
   - `Get-Content C:\FredPD\logs\fredpd_service.log -Tail 20` shows JSON lines with `"FXServer bridge check"` and
     `"Discord roles imported"`;
   - `curl.exe -s http://127.0.0.1:3000/api/session` returns `{"user":null,…}`.
6. Start order does not matter:
   - If FXServer starts first, players get their grants from `fredpd_grant_cache`.
   - When the bot is ready, the service sends `/recompute {}` and everyone online re-fetches (docs/test-phase-1.md
     step 6).
7. **First admin.** The Behörigheter page (and `GET /api/admin/roles`) needs `perm:admin.permissions`. On a new
   database no role has it, and the service has no owner or Discord-Administrator shortcut. Grant it once in SQL to
   the Discord role your admins have. After that, every change is made on the page, and each one is audited.
   - The service must have run once first. It imports the Discord roles into `fredpd_roles`, which the grant row
     references.
   - Run it as root (`mariadb -u root -p qbox`) or in HeidiSQL. The first query lists the role ids (or, in Discord
     with Developer Mode on, right-click the role → *Copy Role ID*):
   ```sql
   SELECT discord_role_id, name FROM fredpd_roles WHERE deleted = 0 ORDER BY position DESC;
   INSERT INTO fredpd_role_grants (discord_role_id, grant_type, grant_key, effect)
     VALUES ('<admin role id>', 'perm', 'admin.permissions', 'allow');
   ```
   - The portal reads grants live, so reloading the page is enough: **Behörigheter** appears in the menu. This row
     is the only grant written outside the page, so it has no `perms.update` audit row.

## 7. Portal over HTTPS: Cloudflare Tunnel (default) or Caddy

The portal must be served over HTTPS at `PUBLIC_URL`. `/internal/*` is for FXServer on loopback only, and must never
be reachable from the internet (docs/modules/service.md, open question 4).

> **Interim:** fredpd_service does not serve the portal build (`apps\portal\dist`) yet. That is task 7.1. Until it
> does, the Caddyfile below serves the SPA and proxies the service routes to `127.0.0.1:3000`. With the tunnel,
> Caddy only listens on loopback. Once the service serves the portal itself, point the tunnel straight at
> `http://127.0.0.1:3000` and remove Caddy.
>
> For a quick Phase 1 test on the host itself you can skip all of this. Run `pnpm --filter @fredpd/portal dev`, and
> set `PUBLIC_URL=http://localhost:5173` and `COOKIE_SECURE=false` in `.env`. Register
> `http://localhost:5173/auth/discord/callback` in the Discord application, then run
> `nssm restart fredpd_service`.

`C:\FredPD\caddy\Caddyfile` (Caddy 2, `caddy_windows_amd64.exe` renamed to `caddy.exe` in `C:\FredPD\caddy`):

```caddyfile
{
	# The admin API (localhost:2019) would let any local process rewrite this config. Restart the service instead.
	admin off
	servers {
		# Tunnel mode: cloudflared connects from loopback. Trusting it keeps the client address Cloudflare put in
		# X-Forwarded-For. Without this, Caddy replaces the header with 127.0.0.1 and every visitor shares one
		# rate-limit bucket. Harmless in Caddy mode, where loopback is never a client.
		trusted_proxies static 127.0.0.1/32 ::1/128
	}
}

(fredpd) {
	encode zstd gzip
	# FXServer calls /internal/* on 127.0.0.1:3000 directly; never expose it.
	handle /internal* {
		respond 404
	}
	@service path /api/* /auth/* /avatar/* /ws /upload /share/*
	handle @service {
		reverse_proxy 127.0.0.1:3000
	}
	# Portal SPA, until fredpd_service serves apps/portal/dist itself (task 7.1).
	handle {
		root * C:/FredPD/fredpd/apps/portal/dist
		try_files {path} /index.html
		file_server
	}
}

# Cloudflare Tunnel mode: plain HTTP on loopback, any Host header (cloudflared keeps the public one).
http://:8080 {
	bind 127.0.0.1
	import fredpd
}

# Caddy mode instead of the tunnel: delete the block above and uncomment this one.
# polis.example.se {
# 	import fredpd
# }
```

Install Caddy as a service with its own account, not LocalSystem. Run `caddy validate` first.
`XDG_DATA_HOME` and `XDG_CONFIG_HOME` put Caddy's storage in `C:\FredPD\caddy`. In Caddy mode that includes the
TLS certificates and their private keys, so only `caddy-svc` may read `data`:

```powershell
C:\FredPD\caddy\caddy.exe validate --config C:\FredPD\caddy\Caddyfile --adapter caddyfile
$pw = Read-Host -AsSecureString "Password for caddy-svc"
New-LocalUser -Name caddy-svc -Password $pw -PasswordNeverExpires -AccountNeverExpires -Description "Runs Caddy"
New-Item -ItemType Directory -Force C:\FredPD\caddy\data, C:\FredPD\caddy\config | Out-Null
icacls C:\FredPD\caddy\data /inheritance:r /grant:r "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F" "caddy-svc:(OI)(CI)M"
icacls C:\FredPD\caddy\config /grant "caddy-svc:(OI)(CI)M"
icacls C:\FredPD\logs /grant "caddy-svc:(OI)(CI)M"
nssm install caddy "C:\FredPD\caddy\caddy.exe"
nssm set caddy AppParameters "run --config C:\FredPD\caddy\Caddyfile --adapter caddyfile"
nssm set caddy AppDirectory "C:\FredPD\caddy"
nssm set caddy AppEnvironmentExtra XDG_DATA_HOME=C:\FredPD\caddy\data XDG_CONFIG_HOME=C:\FredPD\caddy\config
nssm set caddy AppStdout "C:\FredPD\logs\caddy.log"
nssm set caddy AppStderr "C:\FredPD\logs\caddy.log"
nssm set caddy Start SERVICE_DELAYED_AUTO_START
nssm set caddy ObjectName ".\caddy-svc" "<the password you just typed>"
nssm start caddy
```

With `admin off`, `caddy reload` does not work. Apply a Caddyfile change with `nssm restart caddy`.

### 7a. Cloudflare Tunnel (default: no open ports, free TLS)

1. The domain must be on Cloudflare (its nameservers point at Cloudflare).
2. Install cloudflared with `winget install --id Cloudflare.cloudflared`.
3. In the Cloudflare dashboard, go to Zero Trust → Networks → Tunnels → *Create a tunnel* → *Cloudflared*. Name it
   `fredpd` and pick *Windows*. The dashboard shows `cloudflared.exe service install <TOKEN>`. Run that command in
   the Administrator PowerShell. It installs the Windows service `cloudflared`, which starts automatically. The token
   is a secret (§8).
4. *Public hostname*: subdomain `polis`, your domain, service type **HTTP**, URL **`127.0.0.1:8080`** (Caddy,
   interim). Use `127.0.0.1:3000` once task 7.1 is done. Write `127.0.0.1`, not `localhost`: Caddy and the service
   listen on IPv4 loopback only, and `localhost` may try `::1` first.
5. Block `/internal` at the edge too. In Security → WAF → Custom rules, add a rule with the expression
   `(http.host eq "polis.example.se" and starts_with(http.request.uri.path, "/internal"))` and the action **Block**.
6. WebSockets are on by default (Network → WebSockets). Cloudflare closes idle sockets after about 100 s. The portal
   reconnects by itself.
7. Check it: `sc.exe query cloudflared` shows `RUNNING`, and `https://polis.example.se/` shows the portal login.
   `https://polis.example.se/internal/ping` must return 403 or 404.

### 7b. Caddy with its own certificate (alternative)

Use this when the domain is not on Cloudflare, or you do not want the tunnel:

1. Make a DNS `A` record for `polis.example.se` pointing at your public IP.
2. Forward TCP 80 and 443 on the router to this PC, and open them in the firewall:
   ```powershell
   New-NetFirewallRule -DisplayName "Caddy HTTP/HTTPS" -Direction Inbound -Protocol TCP -LocalPort 80,443 -Action Allow
   ```
3. In the Caddyfile, delete the `http://:8080` block and uncomment the `polis.example.se` block. Then run
   `nssm restart caddy`. Caddy gets and renews the Let's Encrypt certificate itself.

**Client addresses.** The service trusts `X-Forwarded-For` only from loopback (`trustProxy: 'loopback'`). Its per-IP
rate limit (60 requests a minute) counts every logged-out request: `/api/session` before login, `/auth/discord`, the
OAuth callback and `/share/…`. That limit only works if the service sees the real client address:

- **Tunnel mode.** The Cloudflare edge puts the client address in `X-Forwarded-For`, and cloudflared connects to
  Caddy from `127.0.0.1`. The `trusted_proxies` line in the Caddyfile makes Caddy keep that header and append to
  it. Without the line, Caddy replaces the header with `127.0.0.1`. Every visitor then shares one bucket, and one
  busy client (or a wave of logins after a restart) locks everyone out of the portal login.
- **Caddy mode.** Caddy's peer is the client itself, and Caddy sets the header from it.
- **After task 7.1** (tunnel straight to the service), the service reads the edge's header itself.

Check it after setup. Open the portal from another network, for example a phone on mobile data. The service log's
`"incoming request"` lines must show that public address as `"remoteAddress"`, not `127.0.0.1`.

## 8. Secrets

| Secret | Where | Notes |
|---|---|---|
| HMAC secret | server.cfg `set fredpd_hmac_secret` **and** `.env` `FREDPD_HMAC_SECRET` | identical, ≥ 32 random chars; placeholders are refused on both sides |
| Session secret | `.env` `SESSION_SECRET` | different from the HMAC secret |
| Discord bot token, OAuth client secret | `.env` | reset in the Discord developer portal if leaked |
| DB passwords | server.cfg `mysql_connection_string`, `.env` `FREDPD_DB_URL`, `C:\FredPD\backup\backup.cnf` | one user per purpose (§2) |
| Tunnel token | the `cloudflared` service | rotate in the Zero Trust dashboard if leaked |

- Generate random values with `node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"`.
- server.cfg (in txData) and `apps\service\.env` are git-ignored. Never commit them, never paste them in Discord, and
  keep them readable only by Administrators and the service account (§6 `icacls`).
- Rotating the HMAC secret: change both places, then `nssm restart fredpd_service` and restart the game server.
  Until both run with the new value, pushes fail with 401 and players fall back to their cached grants.

## 9. Backups (mariadb-dump + Task Scheduler)

`C:\FredPD\backup\backup.cnf`. Restrict it with
`icacls C:\FredPD\backup\backup.cnf /inheritance:r /grant:r "Administrators:F" "SYSTEM:F"`:

```ini
[client]
user=fredpd_backup
password=<password 3>
host=127.0.0.1
```

`C:\FredPD\backup\backup.ps1`:

```powershell
$ErrorActionPreference = 'Stop'
$db    = 'qbox'                                   # your Qbox/FredPD database
$dest  = 'D:\Backups\FredPD'
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
$dump  = 'C:\Program Files\MariaDB 10.11\bin\mariadb-dump.exe'
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$sql = Join-Path $dest "$db-$stamp.sql"
# --defaults-extra-file must be the first option. --single-transaction: consistent InnoDB snapshot without locks.
& $dump --defaults-extra-file=C:\FredPD\backup\backup.cnf --single-transaction --no-tablespaces `
  --default-character-set=utf8mb4 --result-file=$sql $db
if ($LASTEXITCODE -ne 0) { throw "mariadb-dump failed with exit code $LASTEXITCODE" }
Compress-Archive -Path $sql -DestinationPath "$sql.zip" -Force
Remove-Item $sql
# Uploaded images (mugshots, evidence photos) live next to the service, not in the database.
if (Test-Path 'C:\FredPD\fredpd\apps\service\data\uploads') {
  Compress-Archive -Path 'C:\FredPD\fredpd\apps\service\data\uploads' -DestinationPath (Join-Path $dest "uploads-$stamp.zip") -Force
}
# Keep 14 days.
Get-ChildItem $dest -Filter *.zip | Where-Object LastWriteTime -lt (Get-Date).AddDays(-14) | Remove-Item
```

Schedule it daily at 05:30 as SYSTEM, and run it once now to test it:

```powershell
schtasks /Create /TN "FredPD\Database backup" /SC DAILY /ST 05:30 /RU SYSTEM /RL HIGHEST /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\FredPD\backup\backup.ps1"
schtasks /Run /TN "FredPD\Database backup"
```

- **Copy the zips off the laptop** (another disk, NAS or cloud folder). A backup on the same disk does not survive a
  disk failure.
- **Restore:**
  1. Stop the service with `nssm stop fredpd_service`, and stop the game server in txAdmin.
  2. Unzip the dump.
  3. Run `& 'C:\Program Files\MariaDB 10.11\bin\mariadb.exe' -u root -p qbox -e "source D:/Backups/FredPD/qbox-<stamp>.sql"`.
  4. Start the service and the game server again.

  Practise a restore into a scratch database now and then.
- **Monthly audit retention (IMPLEMENTATION.md §4.5):** type `fredpd_audit_archive` in the txAdmin Live Console. It
  moves audit rows older than 90 days to `fredpd_audit_archive`. It never runs on a timer.

## 10. Updating

**FredPD:**

1. Run the backup task (`schtasks /Run /TN "FredPD\Database backup"`).
2. Run `nssm stop fredpd_service` **first**. The service runs straight from this checkout (tsx, `src\main.ts`), so
   `git pull` and `pnpm install` must not change its files while it runs. In game, players keep their cached
   grants while it is stopped.
3. Run `git pull`, `pnpm install --frozen-lockfile` and `.\scripts\build.ps1`. Optionally run `pnpm test`.
4. Stop the game server in txAdmin, deploy (§5), then start the game server. Migrations apply now. The Live Console
   shows `applied NNN_….sql`, then `fredpd_core ready`.
5. Run `nssm start fredpd_service`. Starting it after the migrations means the new code finds its tables.
6. A migration error stops FredPD with the reason. An *edited* migration is refused by design: restore the file.
   Never edit an applied migration.

**Upstream pins** (`deps.lock.json`; never "latest", IMPLEMENTATION.md §8.2):

1. Read the upstream changes between the pinned commit and the new one.
2. In `deps.lock.json`, change `commit`, `date` and, for release installs, `tag` and `release`. `commit` must be the
   tag's commit.
3. Run `.\scripts\fetch-deps.ps1 --only <name>`, then `.\scripts\apply-patches.ps1`.
4. If a patch no longer applies, regenerate it against the new version (`patches\<name>.*.patch`). Never edit the
   upstream files on the server.
5. Re-check that resource's section and the VERIFY notes in `docs/deps-verification.md`, for example event names and
   export signatures.
6. Test on the test server with the relevant `docs/test-phase-N.md`, then deploy it as described in §4. For a
   release-zip install, download the new tag's zip and apply the patches in it.
7. The Qbox recipe's own updates (txAdmin) can move ox_* and qbx_* past the pins. Compare the versions with
   `deps.lock.json` after a recipe update.

## 11. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Console: `HTTP bridge DISABLED: …` | `fredpd_hmac_secret` is missing, shorter than 32 characters or a placeholder |
| Every push fails with `401` / console `rejected … signature` | the secrets differ between server.cfg and `.env`, or the clocks differ by more than 60 s (`w32tm /resync`) |
| Service stops at once; log `invalid fredpd_service configuration` | fix the listed `.env` keys (placeholders are refused) |
| Service log: `fredpd_sessions` missing | fredpd_core has not migrated this database yet: start the game server once, or check that both use the same database |
| Players have no grants; console `unavailable from fredpd_service (HTTP 503)` | the bot is not ready: Server Members Intent off, or the bot is not in the guild |
| Portal login loops or `/ws` is refused | `PUBLIC_URL` must match the address in the browser exactly (scheme, host, port); `COOKIE_SECURE=true` needs HTTPS |
| `https://…/internal/ping` answers | the Caddy `/internal` block or the WAF rule is missing (§7) |
