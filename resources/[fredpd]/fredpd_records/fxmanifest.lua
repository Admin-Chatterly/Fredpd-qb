-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_records: search, person/vehicle pages and "my cases" for the tablet (Phase 2 read paths; case writes come
-- in Phase 5). Server only: the fredpd_mdt dispatcher calls the exports (docs/contracts.md §C12,
-- docs/modules/records.md). fredpd_bolo is optional (BOLO flags and lists are empty while it is stopped).
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'fredpd_records'
description 'FredPD records: search, person and vehicle summaries, case references with visibility applied'
author 'FredPD'
license 'GPL-3.0-only'
version '0.1.0'

dependencies {
    'ox_lib',
    'oxmysql',
    'fredpd_core',
}

shared_scripts {
    '@ox_lib/init.lua',
}

-- server/*.lua modules are loaded with ox_lib `require` from server/main.lua (server-side LoadResourceFile reads
-- any file of the resource, so they need no `files` entry and are never sent to clients).
server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
}
