<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Phase 1 in-game test (Rami)

Checks Phase 1 end to end on the real server: migrations, the HMAC bridge, grants from Discord roles, the grant
cache when the service is down, officer names from Discord, callsigns, and the self-test. Ten steps, about 40
minutes. Run it on the **test server**, because step 4 needs `fredpd_devtools`, which must never run in production.
Use a Discord account with a character you can play.

Tick each step. If one fails, copy the console lines around it (txAdmin → Live Console) and the service log
(`C:\FredPD\logs\fredpd_service.log`) into the report. Keep going with the steps that do not depend on it.

## Before you start (once)

Setup is in [`docs/hosting.md`](hosting.md). For this test you need:

1. **Build and deploy.** On the host, in the repository folder:
   `pnpm install --frozen-lockfile`, then `scripts\build.ps1`, then copy `resources\[fredpd]` to the server
   (hosting.md §5).
2. **server.cfg** (txAdmin → Settings → FXServer → CFG Editor). It must contain:
   ```cfg
   setr ox:locale sv
   set fredpd_hmac_secret "<64 hex characters, the same value as FREDPD_HMAC_SECRET>"
   set fredpd_service_url "http://127.0.0.1:3000"
   add_ace group.admin command allow
   add_principal identifier.discord:<your Discord id> group.admin
   ensure fredpd_core
   ensure fredpd_devtools
   ```
   Keep the four `add_ace resource.ox_lib …` lines from `server.cfg.example`. Make the secret with
   `node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"`.
3. **fredpd_service is installed but stopped.** Fill in `apps\service\.env` from `.env.example`:
   - `FREDPD_HMAC_SECRET` is the same value as in server.cfg;
   - `FREDPD_DB_URL` points at the **same database** as `mysql_connection_string`;
   - `FXSERVER_URL` is `http://127.0.0.1:30120`.

   Install the service (hosting.md §6), then run `nssm stop fredpd_service`. `nssm status fredpd_service` prints
   `SERVICE_STOPPED`. Step 1 needs the game server to create the tables first, and step 2 starts the service.
4. **Discord.** You have an admin role (step 3 gives it the Behörigheter page). A separate test role exists, for
   example `FredPD Test`, and you can add it to yourself and remove it again. Do not add it yet.

In the SQL steps, "SQL" means HeidiSQL (installed with MariaDB) or `mariadb -u root -p <db>` on the host.

## Steps

### 1. Migrations run on start ☐

1. Use a database that has never run FredPD (the Qbox tables may be in it). Start the server in txAdmin. If FredPD
   already ran on this database, skip to point 3.
2. The Live Console shows, in this order:
   - `[fredpd_core:db] applied 001_core.sql` … `applied 009_service.sql` (9 lines);
   - `seeded seed/charges_sv.sql`, `seeded seed/visibility_rules_default.sql`;
   - `loaded 37 visibility rules`, then `fredpd_core ready`.
3. SQL: `SELECT id, applied_at FROM fredpd_migrations ORDER BY id;` returns 11 rows. `applied_at` is UTC, so it is
   1–2 h behind Swedish time.
4. Restart the server. This time the console shows `[fredpd_core:db] up to date` and no `applied` lines.

### 2. The service and FXServer see each other ☐

1. Run `nssm start fredpd_service`.
2. The service log shows `"FXServer bridge check"` with `"fxserver":"reachable"`, then `"Discord roles imported"`.
3. Within a few seconds the Live Console shows
   `grant recompute for everyone online: <n> player(s) re-fetching`.

### 3. First admin, and the test role on Behörigheter ☐

1. SQL, once per database (hosting.md §6 step 7). Find your admin role's id, then give that role the permissions
   page. Skip this if a role already has `admin.permissions`.
   ```sql
   SELECT discord_role_id, name FROM fredpd_roles WHERE deleted = 0 ORDER BY position DESC;
   INSERT INTO fredpd_role_grants (discord_role_id, grant_type, grant_key, effect)
     VALUES ('<admin role id>', 'perm', 'admin.permissions', 'allow');
   ```
2. Open the portal (hosting.md §7), log in with Discord, and reload. **Behörigheter** is in the menu.
3. On Behörigheter, map the **test role**: `unit` → `igv` = Tillåt, `mdt_page` → `search` = Tillåt and
   `perm` → `bolo.create` = Tillåt, then Spara. The page says "Behörigheterna är sparade".
4. SQL: `SELECT action, target_id, created_at FROM fredpd_audit WHERE action = 'perms.update' ORDER BY id DESC LIMIT 1;`
   returns that save, with the test role's id as `target_id` and `created_at` in UTC.

### 4. Self-test passes 100 % ☐

1. In game, as admin, type `/fredpd_selftest`. You can also type `fredpd_selftest` in the Live Console.
2. You get the notification **"Självtest: N av N godkända, 0 fel."**, where both numbers are the same.
3. The console shows one line per suite: `[fredpd_selftest] grants: x/x`, `canView: x/x`, `format: x/x`,
   `time: x/x`. None of the suites has a `FAIL` line.

### 5. A Discord role change reaches the game within 2 s ☐

Your other roles also give you grants (at least `admin.permissions`), so the counts below depend on them.

1. Be in game, with the Live Console open next to Discord. The test role is not on your account yet.
2. Add the test role to yourself in Discord and start a stopwatch.
3. Within **2 s** the console shows
   `grants pushed for discord <your id>: A grant(s), applied to 1 player(s)`. Write down A.
4. Remove the role again. Within 2 s the console shows `… B grant(s), applied to 1 player(s)`, where
   **B = A − 3** (the test role's three keys).
   - If B is larger, one of your other roles already grants `unit:igv`, `mdt_page:search` or `perm:bolo.create`.
   - In that case, repeat this step with a second Discord account that has no other FredPD-mapped role.
5. SQL: check that the cache lost the three keys:
   ```sql
   SELECT JSON_CONTAINS(grants, '"unit:igv"', '$.grants') AS igv,
          JSON_CONTAINS(grants, '"mdt_page:search"', '$.grants') AS search,
          JSON_CONTAINS(grants, '"perm:bolo.create"', '$.grants') AS bolo,
          computed_at
   FROM fredpd_grant_cache WHERE discord_id = '<your id>';
   ```
   It returns `0`, `0`, `0` and a fresh `computed_at` (UTC).
6. **Add the role again** before step 6.

### 6. Service down: the grants come from the cache ☐

1. Run `nssm stop fredpd_service`, then disconnect from the game and connect again.
2. The console shows `grants for player <n> (discord <your id>) unavailable from fredpd_service (HTTP 0); using
   fredpd_grant_cache`. It does **not** show `no cached grants for discord …`.
3. Run `nssm start fredpd_service`. Within about 10 s the console shows
   `grant recompute for everyone online: 1 player(s) re-fetching` and no new warning for you.

### 7. First duty gives the callsign IGV-01 ☐

1. Use a character that has never been on duty with FredPD, and a database where no officer holds `IGV-01`. You need
   the test role (grant `unit:igv`), and none of your other roles may grant a unit.
2. As admin, type `/setjob <your server id> police 1` and then relog the character. The officer row is created when
   a police (`leo`) character loads.
3. Go on duty (the duty point at the station, qbx_core `QBCore:ToggleDuty`). If the job starts on duty, the
   callsign is already assigned when the character loads.
4. You get the notification **"Du har fått anropssignalen IGV-01."**
5. SQL: `SELECT citizenid, display_name, unit, callsign FROM fredpd_officers WHERE discord_id = '<your id>';`
   returns `igv` and `IGV-01`.
6. Go off duty and on again. The callsign stays `IGV-01` and there is no new notification.

### 8. Renaming yourself in Discord renames the officer within 2 s ☐

1. Be in game, with the police character from step 7 loaded.
2. In Discord, change your **server nickname**, for example to `Test Testsson`.
3. Within **2 s** the console shows `officer name for discord <your id> is now "Test Testsson" (1 officer character(s))`.
4. SQL: `SELECT display_name, updated_at FROM fredpd_officers WHERE discord_id = '<your id>';` shows the new name.
5. The portal header (Hem, "Hej …") shows the new name after you reload the page.
6. If `fredpd_mdt` is installed, the tablet roster also shows the new name. It never shows the character name.

### 9. The bridge refuses bad signatures (curl) ☐

Open PowerShell **on the host**. The first line asks for the secret from server.cfg:
- The input is hidden, and PowerShell does not save it in its history.
- node reads the secret from the environment, so it never appears on a command line or in the process list.

```powershell
$env:FREDPD_S = [Net.NetworkCredential]::new('', (Read-Host -AsSecureString 'fredpd_hmac_secret')).Password
$ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$sig = node -e "console.log(require('crypto').createHmac('sha256', process.env.FREDPD_S).update(process.argv[1] + '.').digest('hex'))" $ts
curl.exe -s -H "X-FredPD-Ts: $ts" -H "X-FredPD-Sig: $sig" http://127.0.0.1:30120/fredpd_core/ping
curl.exe -s -H "X-FredPD-Ts: $ts" -H "X-FredPD-Sig: $('0' * 64)" http://127.0.0.1:30120/fredpd_core/ping
curl.exe -s -H "X-FredPD-Ts: $($ts - 120)" -H "X-FredPD-Sig: $sig" http://127.0.0.1:30120/fredpd_core/ping
```

1. The first call prints `{"ok":true,"players":<n>}`.
2. The second call (bad signature) and the third (timestamp 2 min old) print `{"error":"unauthorized"}`.
3. The console shows a `rejected GET /ping from 127.0.0.1…: signature` line. When several rejections come quickly,
   only one line is logged, and later lines add a count.
4. Run `curl.exe -s http://127.0.0.1:30120/fredpd_core/ping` with no headers. It also prints
   `{"error":"unauthorized"}`.

### 10. Reload the visibility rules without a restart (`POST /rules`) ☐

There is no rules editor yet. After changing `fredpd_visibility_rules` in SQL, you apply the change like this, in the
same PowerShell window:

```powershell
$ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$sig = node -e "console.log(require('crypto').createHmac('sha256', process.env.FREDPD_S).update(process.argv[1] + '.{}').digest('hex'))" $ts
curl.exe -s -X POST -H "Content-Type: application/json" -H "X-FredPD-Ts: $ts" -H "X-FredPD-Sig: $sig" --data-binary "{}" http://127.0.0.1:30120/fredpd_core/rules
```

1. The call prints `{"ok":true}`. The console shows `visibility rules changed: reloading`, then
   `loaded 37 visibility rules` (or the new count).
2. Only the exact body `{}` is accepted. A correctly signed `[]` is refused, and nothing is reloaded:
   ```powershell
   $sig = node -e "console.log(require('crypto').createHmac('sha256', process.env.FREDPD_S).update(process.argv[1] + '.[]').digest('hex'))" $ts
   curl.exe -s -X POST -H "Content-Type: application/json" -H "X-FredPD-Ts: $ts" -H "X-FredPD-Sig: $sig" --data-binary "[]" http://127.0.0.1:30120/fredpd_core/rules
   ```
   It prints `{"error":"bad_json"}`, and the console has no new `loaded … visibility rules` line.
3. Run `Remove-Item Env:FREDPD_S`, or close the window.

## Report back

Write the step numbers that failed, with the console and service log lines. Say which txAdmin recipe the server was
installed with and which of `qbx_police` or `qbx_policejob` is its police folder. docs/deps-verification.md needs
both answers.
