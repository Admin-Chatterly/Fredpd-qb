-- SPDX-License-Identifier: GPL-3.0-only
-- prison adapter "qbx_prison": Qbox qbx_prison (VERIFY it exists and its jail export in tasks 0.3/4.1).
-- Stub until task 4.1 (IMPLEMENTATION.md §7): every call is the prison no-op (adapters/base.lua).
-- When qbx_prison is not started, the loader logs one warning at start and the calls stay no-ops.
return require('adapters.base').define({
    kind = 'prison',
    name = 'qbx_prison',
    resource = 'qbx_prison',
    stub = true,
    task = '4.1',
    methods = {},
})
