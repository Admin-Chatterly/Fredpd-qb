-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_records: search, person/vehicle pages, cases, reports, charges, POI sheets, share links and release requests
-- (Phases 2 and 5). Server only: the fredpd_mdt dispatcher calls the exports (docs/contracts.md §C12,
-- docs/modules/records.md). fredpd_bolo is optional (BOLO flags and lists are empty while it is stopped).
fx_version 'cerulean'
game 'gta5'
lua54 'yes'
node_version '22'

name 'fredpd_records'
description 'FredPD records: search, person/vehicle pages, cases, reports, charges, POI, shares, release requests'
author 'FredPD'
license 'GPL-3.0-only'
version '0.2.0'

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
    'server/random.js', -- CSPRNG for share tokens (exports randomToken)
    'server/main.lua',
}
