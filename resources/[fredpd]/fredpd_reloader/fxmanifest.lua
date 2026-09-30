-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_reloader: restarts every FredPD resource in dependency order from one console command, without a server
-- restart (docs/dev-loop.md). It depends on nothing, so it survives the restart it performs. DEV/TEST servers;
-- harmless in production (console/ACE only), but not needed there.
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'fredpd_reloader'
description 'Restart all FredPD resources in order (development)'
author 'FredPD'
license 'GPL-3.0-only'
version '0.1.0'

server_scripts {
    'server.lua',
}
