# FredPD — test loop (update in one command, test without reinstalling)

The server runs FredPD **straight from the git clone**. An update is `git pull`, a build only when needed, and a live
restart of the FredPD resources. No copying, no reinstall, no full server restart.

## One-time setup (≈ 10 minutes)

All commands run in PowerShell on the server machine.

1. **Clone and build once** (if you haven't already):
   ```powershell
   cd C:\FredPD
   git clone -b claude/fredpd-implementation-bum86o https://github.com/Admin-Chatterly/Fredpd-qb.git fredpd
   cd fredpd
   pnpm install
   node scripts/build.mjs
   ```
2. **Link and patch the server.** This replaces copying. `SETUP.md` step 2 explains what these do:
   ```powershell
   .\scripts\link-server.ps1  -ServerResources "C:\Users\FiveM\Desktop\SalamDevQB\resources"
   .\scripts\patch-server.ps1 --server "C:\Users\FiveM\Desktop\SalamDevQB\resources"
   ```
   Then delete `resources\[upstream]` on the server if it is still there, and move the `*.bak-*` folders out of
   `resources\`.
3. **Your server settings** go in `config\integrations.local.json` (git never overwrites it):
   ```json
   { "inventory": "qb-inventory", "target": "qb-target", "doorlock": "qb-doorlock",
     "prison": "qb-prison", "housing": "none", "garage": "none" }
   ```
   Use `"garage": "qb-garages"` only if players park with qb-garages, not jg-advancedgarages.
   Run `node scripts/build.mjs --skip-web` once after creating it.
4. **server.cfg**, test server only:
   ```cfg
   set fredpd_dev true            # enables /fredpd_devgrant and the other dev commands
   ensure fredpd_reloader         # the fredpd_reload console command
   ensure fredpd_devtools         # NEVER on the real server
   set rcon_password "long-random-password"   # optional: lets update.ps1 restart FredPD by itself
   ```
   On a QBCore server, do not ensure `ox_inventory`, `ox_target`, `ox_doorlock`, `evidences` or `fredpd_forensics`.
5. **Environment variables for update.ps1**, set once for your Windows user in PowerShell. Open a new PowerShell
   window afterwards:
   ```powershell
   setx FREDPD_SERVER_RESOURCES "C:\Users\FiveM\Desktop\SalamDevQB\resources"
   setx FREDPD_RCON_PASSWORD "long-random-password"   # same as rcon_password; leave out to restart by hand
   ```
6. Restart the server once in txAdmin.

## Every update (≈ 10–60 seconds)

```powershell
cd C:\FredPD\fredpd
.\scripts\update.ps1
```

It pulls, installs/builds only what changed, patches your qb resources if a patch changed, and restarts FredPD live:
- **With RCON set:** the restart happens automatically. Look for `fredpd_reloader done` in the txAdmin console.
- **Without RCON:** it prints a line like `fredpd_reload qb-policejob`. Paste it into the txAdmin **Live Console**.
- **When the portal service changed:** it restarts it with NSSM (or tells you how).
- **Full server restart:** only needed when it says so (for example a qb-core or inventory change).

Flags: `--force` redoes every step, `--no-pull` skips the pull, `--no-restart` skips the restart.

## How to test

Work top to bottom. Stop at the first thing that fails and send me what you see (see "Reporting" below).

### A. Tablet UI in the browser (no game needed)

On any PC with the repo:
```powershell
pnpm --filter @fredpd/nui dev
```
Open the printed `http://localhost:5173`. Every page works with Swedish mock data. Check layout, texts, the
flows (search → person → vehicle, create BOLO, case page, report editor), and the keyboard: arrows, Enter, Esc.
Everything you find here can be fixed without touching the server.

### B. In game without the Discord service

1. Join the test server with your police character. Go on duty (qb-policejob's duty point or `/duty` if you have
   it).
2. In the txAdmin Live Console:
   ```
   fredpd_devgrant <your server id> all
   ```
   You get every tablet page and permission. It is stored, so it survives a rejoin. Use preset `igv` to test as
   an ordinary patrol officer, and `none` to test being refused. Your FiveM account must have Discord linked
   (FiveM settings → Accounts).
3. Give yourself the tablet: `/giveitem <id> pd_tablet 1`. Use it from the inventory.
   - **Tablet:** opens within about 0.3 s, and Esc always closes it.
   - **Without a grant:** a Swedish message, and the tablet does not open.
4. `fredpd_selftest` in the console: every suite must say `n/n`.
5. `fredpd_seed 50` adds 50 fake persons and vehicles. Search for one on the tablet (name, `ABC 123`,
   personnummer), then open the person and the vehicle.
6. **BOLO:** create one on a seeded vehicle's plate. Spawn a car, then use target → "Kontrollera registreringsskylt"
   (that car's plate won't match; use `/fredpd_testbolo` while sitting in it to create a BOLO on its plate). You
   should get a hit popup, and the alert should appear on the Larm page.
7. **Alerts:** `fredpd_testalert` shows a toast. Press **G** to take the alert: a waypoint is set, and it shows
   as assigned on the Larm page.
8. **Cases and reports:** create a case, add the seeded person as suspect, write a report, add charges, then close
   the case.
9. **Police job:** the armory and garage only show what your preset allows; with `igv` there's no special gear.
   Cuff, escort and `/jail` (qb-prison) still work.
10. **Breach:** `/giveitem <id> pd_ram 1`, then use a locked qb-doorlock door that isn't on the deny list →
    "Forcera dörr".

Detailed checklists per phase: `docs/test-phase-2.md` (tablet), `-3` (alerts), `-4` (police job), `-5` (cases),
`-5b` (intel), `-6` (breach).

### C. With the Discord service and portal

Only after A and B work: `SETUP.md` steps 5–6. Then `docs/test-phase-1.md` (roles → permissions within 2 s) and
`docs/test-phase-7.md` (portal).

## Reporting

For each failure, send:
- **Step:** the step number from the list above.
- **Expected vs happened:** what you expected and what happened instead.
- **Console:** the txAdmin console lines around it (everything with `fredpd`, `qb-policejob` or `SCRIPT ERROR`).
- **Tablet UI errors:** press F8 in game and copy any red lines.

I fix, push, and you run `.\scripts\update.ps1` again. That is the whole loop.
