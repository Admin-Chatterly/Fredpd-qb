-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_breach: "Forcera dörr" on locked doors with the pd_ram item (grant tool:ram, on duty), and the server-only
-- export sceneEvidence(kind, coords, suspectSrc) that crime scripts call to leave collectable evidence through
-- noobsystems/evidences (IMPLEMENTATION.md §5.6, docs/contracts.md §C16, docs/modules/breach.md).
-- Inventory, doorlock and target go through fredpd_core's bridge (docs/contracts.md §C17: qb-inventory/ox_inventory,
-- qb-doorlock (patched)/ox_doorlock, qb-target/ox_target). evidences and the pd_ram item definition are optional at
-- start: without them the export answers 'unavailable' and nobody can hold a ram (one warning each).
-- locales/ is copied in by scripts/build.mjs (git-ignored here).
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'fredpd_breach'
description 'FredPD breach: battering ram on locked doors, scene evidence for crime scripts'
author 'FredPD'
license 'GPL-3.0-only'
version '0.1.0'

dependencies {
    'ox_lib',
    'fredpd_core',
}

ox_lib 'locale'

shared_scripts {
    '@ox_lib/init.lua',
}

server_scripts {
    'server/main.lua',
}

client_scripts {
    '@fredpd_core/bridge/client.lua',
    'client/main.lua',
}

-- config/scene_evidence.lua is server-only (loaded with ox_lib require, which reads it with LoadResourceFile).
files {
    'config.lua',
    'locales/*.json',
}
