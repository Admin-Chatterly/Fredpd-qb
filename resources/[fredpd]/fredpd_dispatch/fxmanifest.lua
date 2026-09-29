-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_dispatch: alerts (larm) from ps-dispatch and FredPD resources, toast + "Ta larm" key, units roster.
-- ps-dispatch is optional (patched by patches/ps-dispatch.*.patch; start it before this resource so no call is
-- missed). fredpd_mdt is optional too (tablet pushes are skipped while it is not started).
-- locales/ is copied in by scripts/build.mjs (git-ignored here).
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'fredpd_dispatch'
description 'FredPD alerts: ps-dispatch bridge, toasts, Ta larm keybind, units roster'
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
    'client/main.lua',
}

files {
    'locales/*.json',
}
