-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_bolo: efterlysningar (BOLO), plate checks (target option "Kontrollera registreringsskylt"), hit alerts.
-- Framework and target go through fredpd_core's bridge (docs/contracts.md §C17: qb-core/qbx_core, qb-target/
-- ox_target). The target resource, fredpd_dispatch and fredpd_mdt are optional at runtime (the option, the alerts
-- and the tablet pushes are skipped while they are not started). locales/ is copied in by scripts/build.mjs (git-ignored here).
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'fredpd_bolo'
description 'FredPD efterlysningar: BOLO store, plate checks, hit alerts'
author 'FredPD'
license 'GPL-3.0-only'
version '0.1.0'

dependencies {
    'ox_lib',
    'oxmysql',
    'fredpd_core',
}

ox_lib 'locale'

shared_scripts {
    '@ox_lib/init.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
}

client_scripts {
    '@fredpd_core/bridge/client.lua',
    'client/main.lua',
}

-- Client-side ox_lib `require` reads these through LoadResourceFile.
files {
    'locales/*.json',
    'shared/view.lua',
}
