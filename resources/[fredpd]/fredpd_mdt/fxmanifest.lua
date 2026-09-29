-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_mdt: the police tablet (item pd_tablet + vehicle terminal), the NUI host and the tablet action dispatcher
-- (IMPLEMENTATION.md §5.2, docs/contracts.md §C12, docs/modules/mdt.md). web/build (the apps/nui bundle) and
-- locales/ are copied in by scripts/build.mjs (git-ignored here). The item itself comes from
-- patches/qb-core.10-fredpd-items.patch (qb-inventory) or patches/ox_inventory.10-fredpd-items.patch. Framework,
-- inventory and target are reached only through fredpd_core's bridge (docs/contracts.md §C17): server exports on
-- fredpd_core, client FredBridge from '@fredpd_core/bridge/client.lua'. No qb-*/qbx_*/ox_inventory/ox_target
-- dependency: which of them runs is fredpd_core's config/integrations.json.
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
    'fredpd_core',
}

ox_lib 'locale'

shared_scripts {
    '@ox_lib/init.lua',
}

-- server/*.lua modules are loaded with ox_lib `require` from server/main.lua (server-side LoadResourceFile reads any
-- file of the resource, so they need no `files` entry and are never sent to clients).
-- server/http.js: POST /fredpd_mdt/portal (HMAC-signed by fredpd_service; portal mode, server/portal.lua).
server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/http.js',
    'server/main.lua',
}

client_scripts {
    '@fredpd_core/bridge/client.lua',
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
