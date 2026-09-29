-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_devtools: self-test, backfill, seed data and fake units for development. DEV ONLY: never `ensure` it on a
-- production server (see server.cfg.example). fixtures/ and locales/ are copied in by scripts/build.mjs.
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'fredpd_devtools'
description 'FredPD development tools (never start in production)'
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
