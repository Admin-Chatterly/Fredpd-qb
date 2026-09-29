-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_forensics: thin adapter over noobsystems/evidences (IMPLEMENTATION.md §5.7, docs/contracts.md §C16):
-- evidence register + custody chain (collect, hand-in, analyse, link), "Koppla till ärende", station lab zone,
-- evidence lockers, tablet actions listEvidence / getEvidence / linkEvidence.
-- evidences is optional at start (its event simply never fires without it) but needs
-- patches/evidences.20-fredpd-integration.patch for fingerprint/DNA analyses and "Analysera".
-- locales/ is copied in by scripts/build.mjs (git-ignored here).
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'fredpd_forensics'
description 'FredPD forensics: evidence register, chain of custody, lab and lockers over noobsystems/evidences'
author 'FredPD'
license 'GPL-3.0-only'
version '0.1.0'

dependencies {
    'ox_lib',
    'oxmysql',
    'ox_inventory',
    'ox_target',
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
    'config.lua',
    'shared/*.lua',
    'locales/*.json',
}
