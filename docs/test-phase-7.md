<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Phase 7 in-game test (Rami)

Checks the finished web portal (docs/modules/portal.md, docs/modules/portal-api.md, docs/hosting.md): Discord login
with the privacy notice, the character picker, the tablet's pages in the browser (world-only buttons hidden), live
Larm, Ledning → Surfplattor, the intel 404 rule, and the hosting set-up (service + tunnel). Ten steps, about 40
minutes. You need **A** = your Discord account with an officer character (`mdt_page:*`, `perm:tablets.manage`, no
`intel.read` for step 7) and the game running on a second screen or with a second player.

Known gaps (not failures): POI-blad, delningslänkar, Utlämningskö and "Begär ut allmän handling" show "Den här
funktionen är inte tillgänglig i portalen än." until their actions are registered (docs/modules/portal.md
"Integration requests"); Ledning → Granskning shows "Loggvyn är inte klar än …".

Tick each step. If one fails, note the URL, take a screenshot, and copy the service log
(`C:\FredPD\logs\fredpd_service.log`) lines around it into the report.

## Before you start (once)

1. `scripts\build.ps1` (builds `apps/portal` into the service), restart the `fredpd_service` Windows service
   (`nssm restart fredpd_service`), restart FXServer.
2. The Cloudflare tunnel (docs/hosting.md) points at `http://localhost:3000`; the portal address opens over HTTPS.

## Steps

### 1. Login and privacy notice ☐

Open the portal in a private window: "Logga in" page with "Så hanterar vi dina uppgifter" (Discord-ID, names, logs
kept 90 days). "Logga in med Discord" → Discord consent → back on the portal. A Discord account that is not in the
server gets "Ditt Discord-konto är inte med i vår Discord-server."

### 2. Character picker ☐

"Välj karaktär" lists your characters with "Senast spelad …". Pick the officer: Hem opens with that character's name
in the footer. "Byt karaktär" → pick another character: nothing of the first character's data is shown any more
(open Ärenden: the list is the new character's).

### 3. The tablet pages in the browser ☐

Search a person, open a vehicle, a case and a report: same content as the tablet in game. World-only buttons are
**missing**: Kontrollera (vehicle), Ta larmet/Lämna/Avsluta (Larm), Utfärda ordningsbot (report), Koppla till ärende
(Bevis), Spärra (Surfplattor). Writing works: add a line to one of your reports and Spara; the tablet in game shows
it after reopening.

### 4. Live Larm ☐

Portal → Larm shows "Live". In game `/fredpd_testalert` (test server): the new alert appears in the portal within
about a second without reloading. Open the portal in a second tab: that tab says "Liveuppdateringarna visas i en
annan flik." (one live connection per user).

### 5. Personal (Register) ☐

With A in the Ledning unit and two officers on duty in game: Personal lists both with anropssignal. One goes off
duty: after reloading the page they are gone.

### 6. Ledning → Surfplattor ☐

Give yourself a tablet in game (`/surfplatta <id>`). Portal → Ledning → Surfplattor lists its serial and owner, but
**without** Spärra/Häv spärren (revoking is a tablet-only action, refused by the service too). In game, Ledning →
Surfplattor → Spärra: the portal list shows it spärrad after a reload, and that tablet no longer opens. Häv spärren
in game. SQL: `SELECT action FROM fredpd_audit WHERE target_type = 'tablet' ORDER BY id DESC LIMIT 3;` →
`tablet.reinstate`, `tablet.revoke`, `tablet.issue`.

### 7. Intel answers "not found", never "no permission" ☐

Without `intel.read`: open `<portal>/intel` and `<portal>/intel/kallor` by typing the URL. Both show "hittades
inte", not "behörighet"; the menu has no Underrättelser. Grant `intel.read` + `mdt_page:intel` in Behörigheter,
reload: the section opens.

### 8. Session end ☐

Log out: "Du är utloggad." Press Back in the browser: no MDT data is shown, only the login page. Log in again, then
remove your character's officer role in Discord: within a few seconds the next page load shows the reduced menu (or
"Du har inte behörighet till portalen.").

### 9. Security headers ☐

Browser F12 → Network → reload → the document request. Response headers include `content-security-policy` (with
`default-src 'self'`), `x-content-type-options: nosniff`, `strict-transport-security` (behind the tunnel), and the
session cookie is `HttpOnly; Secure; SameSite=Lax`. Console shows no CSP violations while you click through Hem, Sök,
Ärenden and Larm.

### 10. Host reboot ☐

Restart the Windows host (or stop/start both services). Without logging in to Windows, `fredpd_service` and
`cloudflared` start by themselves (Services list: Automatic, Running) and the portal is reachable again; the service
log shows "listening on …:3000" and the Discord bot "ready".
