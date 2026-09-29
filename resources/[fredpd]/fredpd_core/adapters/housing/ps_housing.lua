-- SPDX-License-Identifier: GPL-3.0-only
-- housing adapter "ps-housing": Project Sloth ps-housing (VERIFY its property lock export/event in task 6.2).
-- Stub until task 6.2 (IMPLEMENTATION.md §7): every call is the housing no-op (adapters/base.lua).
-- When ps-housing is not started, the loader logs one warning at start and the calls stay no-ops.
return require('adapters.base').define({
    kind = 'housing',
    name = 'ps-housing',
    resource = 'ps-housing',
    stub = true,
    task = '6.2',
    methods = {},
})
