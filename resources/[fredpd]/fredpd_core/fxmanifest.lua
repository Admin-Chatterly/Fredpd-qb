-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_core: permissions, visibility, audit, search mirrors, officer identity, HTTP bridge, migrations, adapters,
-- framework bridge (qb-core | qbx_core, qb-inventory | ox_inventory, qb-target | ox_target, qb-doorlock | ox_doorlock;
-- docs/contracts.md §C17, docs/modules/bridge.md).
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

-- Only hard dependencies here. The framework, inventory, target and doorlock resources are chosen in
-- config/integrations.json and checked with GetResourceState (server/bridge.lua): a missing one gives one warning.
dependencies {
    'ox_lib',
    'oxmysql',
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

-- bridge/client.lua defines FredBridge (other resources load the same file with '@fredpd_core/bridge/client.lua').
client_scripts {
    'bridge/client.lua',
    'client/bridge.lua',
}

-- Sent to every client, so only what client code may load: the shared modules, formats/units (non-secret display
-- config) and locales. Not migrations/ (schema DDL; db.lua reads them server-side with LoadResourceFile, which needs
-- no `files` entry) and not config/integrations.json (server-only settings such as unauthorizedLookupThreshold).
files {
    'shared/*.lua',
    -- read by bridge/client.lua with LoadResourceFile in whichever resource includes it
    'bridge/client.lua',
    'bridge/select.lua',
    'bridge/framework/normalize.lua',
    'bridge/target/*.lua',
    'bridge/doorlock/*.lua',
    'config/formats.json',
    'config/units.json',
    'locales/*.json',
}
