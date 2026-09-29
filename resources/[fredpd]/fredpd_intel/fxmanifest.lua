-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_intel: sources (källor), intel reports, entity graph and missions (insatser), all shaped by fredpd_core's
-- canView (IMPLEMENTATION.md §5.8, docs/contracts.md §C15). Server only: the tablet pages live in apps/nui and reach
-- these exports through the fredpd_mdt action dispatcher.
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'fredpd_intel'
description 'FredPD intelligence: sources, reports, entity links, graph and missions'
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

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
}
