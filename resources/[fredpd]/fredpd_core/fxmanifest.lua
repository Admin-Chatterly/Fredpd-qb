-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_core: permissions, visibility, audit, search mirrors, officer identity, HTTP bridge, migrations, adapters.
-- config/, locales/ and migrations/ are copied in by scripts/build.mjs (git-ignored here).
fx_version 'cerulean'
game 'gta5'
lua54 'yes'
-- server/http.js needs global fetch (Node 18+); it falls back to node:http on older FXServer Node runtimes.
node_version '22'

name 'fredpd_core'
description 'FredPD core: permissions, visibility, audit, search mirrors, officer identity, service bridge'
author 'FredPD'
license 'GPL-3.0-only'
version '0.1.0'

dependencies {
    'ox_lib',
    'oxmysql',
    'qbx_core',
}

-- ox_lib loads locales/<ox:locale>.json (en.json as fallback) before our scripts run.
ox_lib 'locale'

shared_scripts {
    '@ox_lib/init.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/http.js',
    'server/main.lua',
}

files {
    'shared/*.lua',
    'config/*.json',
    'locales/*.json',
    'migrations/*',
}
