<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Phase 4 in-game test (Rami)

Checks the patched **qb-policejob** (docs/modules/police-qb.md, docs/contracts.md §C17 "Police job"): duty and
grants instead of job grade, the armory and garage built from Discord grants, the hardened net events, the Swedish
locale, and evidence (qb-policejob's own on the qb stack; `evidences` + fredpd_forensics only on the ox stack). Ten
steps, about 40 minutes. You need **two players**: **A** = officer (police job) and **B** = a civilian.

Tick each step. If one fails, copy the F8 console and the txAdmin Live Console lines around it into the report.

## Before you start (once)

1. `scripts\apply-patches.ps1` (qb-policejob patches 10–40, `qb-core.10-fredpd-items`), `scripts\build.ps1`, copy
   the patched `qb-core`, `qb-policejob` and `resources\[fredpd]` to the server, restart.
2. server.cfg: `setr qb_locale "sv"`; `ensure fredpd_core` **after** qb-core, qb-inventory, qb-target.
3. Portal → Behörigheter: give A's role `armory:mrpd`, `weapon:weapon_pistol`, `armory:handcuffs` (or any one armory
   item), `vehicle:police`, `perm:police.jail`, `perm:police.impound`, `perm:charges.fine`. **Not** `weapon:weapon_smg`,
   **not** `vehicle:police2`.

## Steps

### 1. Duty gates everything ☐

A **off** duty: `/cuff`, `/fine`, the armory and the police garage are refused ("Endast för polis i tjänst" or
the Swedish equivalent). Clock in: they work. B (civilian) gets the same refusal for every police command.

### 2. Swedish texts ☐

Every qb-policejob notification, menu header and the evidence/stash texts A sees in steps 1–10 are in Swedish. Note
any English line (screenshot) for the string pass (task 8.2).

### 3. Armory shows only granted items ☐

A at MRPD's armory (462, -981, 30): the menu lists the pistol and the granted item, **no** SMG. Take the pistol: it
lands in the inventory; txAdmin SQL `SELECT action, meta FROM fredpd_audit WHERE action = 'police.armory' ORDER BY id
DESC LIMIT 1;` shows it.

### 4. A Discord role change reaches the armory in ~2 s ☐

With the armory menu closed, remove `weapon:weapon_pistol` from A's role in the portal (or remove the Discord role).
Within about 2 s reopen the menu: the pistol is gone. Grant it back: it returns. (Measure roughly; > 5 s is a fail.)

### 5. Garage only offers granted vehicles ☐

A at the MRPD garage: only `police` is offered, not `police2`. It spawns at the garage spot with a police plate.
Going off duty and opening the garage: empty / refused.

### 6. Fines are bounded ☐

A: `/fine <B:s id> 500` → B's bank drops 500 kr. `/fine <id> -500`, `/fine <id> 0`, `/fine <id> 200000` and `/fine
<id>` without an amount are refused, nothing crashes (F8/server console clean). Two fines within 2 s: the second is
refused ("Försök igen …").

### 7. Jail and impound need their perms ☐

Remove `perm:police.jail` from A: `/jail <id> 5` is refused; give it back: B is jailed. Same with
`perm:police.impound` and `/impound` on a car. `/unjail -1` is refused.

### 8. No stormram, locked-down lockers ☐

The police vehicle trunk has **no** `police_stormram` (FredPD's `pd_ram` replaces it, Phase 6). A opens the evidence
locker drawer 1 in MRPD: works; standing 20 m away (or as B) the same drawer cannot be opened.

### 9. Evidence on the qb stack ☐ *(qb-inventory; skip on the ox stack)*

A fires a few shots: qb-policejob's own casings appear and can be picked up (built-in evidence stays **on** because
`evidences` needs ox_inventory). Console once at start: fredpd_forensics says it is idle (no ox_inventory/ox_target),
no errors.

### 10. Evidence on the ox stack ☐ *(ox_inventory + ox_target + evidences; else skip)*

Collect a fingerprint with the evidences kit → hand it in to the evidence locker → Analysera at the lab → "Koppla till
ärende" → pick a case. The tablet's case page (Bevis) shows the item with **4** chain-of-custody entries (insamlad,
inlämnad, analyserad, kopplad). qb-policejob's casings do **not** appear any more.
