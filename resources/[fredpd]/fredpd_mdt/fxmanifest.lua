-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_mdt: the police tablet (item pd_tablet + vehicle terminal), the NUI host and the tablet action dispatcher
-- (IMPLEMENTATION.md §5.2, docs/contracts.md §C12, docs/modules/mdt.md). web/build (the apps/nui bundle) and
-- locales/ are copied in by scripts/build.mjs (git-ignored here). The item itself comes from
-- patches/ox_inventory.10-fredpd-items.patch.
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'fredpd_mdt'
description 'FredPD surfplatta: tablet item, vehicle terminal, NUI host, action dispatcher, tablet registry'
author 'FredPD'
license 'GPL-3.0-only'
version '0.1.0'

dependencies {
    'ox_lib',
    'oxmysql',
    'ox_inventory',
    'ox_target',
    'qbx_core',
    'fredpd_core',
}

ox_lib 'locale'

shared_scripts {
    '@ox_lib/init.lua',
}

-- server/*.lua modules are loaded with ox_lib `require` from server/main.lua (server-side LoadResourceFile reads any
-- file of the resource, so they need no `files` entry and are never sent to clients).
server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
}

client_scripts {
    '@qbx_core/modules/playerdata.lua',
    'client/main.lua',
}

ui_page 'web/build/index.html'

-- Client-side ox_lib `require` reads config.lua and shared/validate.lua through LoadResourceFile.
files {
    'web/build/index.html',
    'web/build/**/*',
    'locales/*.json',
    'config.lua',
    'shared/validate.lua',
}
