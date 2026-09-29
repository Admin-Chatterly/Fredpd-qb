-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_forensics: thin adapter over noobsystems/evidences (IMPLEMENTATION.md §5.7, docs/contracts.md §C16):
-- evidence register + custody chain (collect, hand-in, analyse, link), "Koppla till ärende", station lab zone,
-- evidence lockers, tablet actions listEvidence / getEvidence / linkEvidence.
-- evidences is optional at start (its event simply never fires without it) but needs
-- patches/evidences.20-fredpd-integration.patch for fingerprint/DNA analyses and "Analysera".
-- Framework bridge (docs/contracts.md §C17): no hard dependency on ox_inventory / ox_target / a framework. evidences
-- needs ox_inventory + ox_target, so the resource wires itself only while exports.fredpd_core:bridgeInfo().evidence
-- is true; on qb-inventory / qb-target it stays idle (one warning) and the tablet's Bevis page says "not available".
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
    '@fredpd_core/bridge/client.lua',
    'client/main.lua',
}

files {
    'config.lua',
    'shared/*.lua',
    'locales/*.json',
}
