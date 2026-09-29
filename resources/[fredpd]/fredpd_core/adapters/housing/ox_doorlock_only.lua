-- SPDX-License-Identifier: GPL-3.0-only
-- housing adapter "ox_doorlock-only": for housing scripts whose doors are plain ox_doorlock doors. The property id
-- is then an ox_doorlock door id (or a list of them) and a breach unlocks it through ox_doorlock.
-- Stub until task 6.2 (IMPLEMENTATION.md §7): every call is the housing no-op (adapters/base.lua). When ox_doorlock
-- is not started, the loader logs one warning at start and the calls stay no-ops.
return require('adapters.base').define({
    kind = 'housing',
    name = 'ox_doorlock-only',
    resource = 'ox_doorlock',
    stub = true,
    task = '6.2',
    methods = {},
})
