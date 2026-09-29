-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_bolo: efterlysningar (BOLO), plate checks (ox_target "Kontrollera registreringsskylt"), hit alerts.
-- ox_target, fredpd_dispatch and fredpd_mdt are optional at runtime (the option, the alerts and the tablet pushes
-- are skipped while they are not started). locales/ is copied in by scripts/build.mjs (git-ignored here).
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
    'qbx_core',
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
    '@qbx_core/modules/playerdata.lua',
    'client/main.lua',
}

-- Client-side ox_lib `require` reads these through LoadResourceFile.
files {
    'locales/*.json',
    'shared/view.lua',
}
