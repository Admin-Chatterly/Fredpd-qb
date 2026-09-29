-- SPDX-License-Identifier: GPL-3.0-only
-- prison adapter "qbx_police-jail": the jail built into qbx_police (resource name qbx_policejob; VERIFY in task 4.1).
-- Stub until task 4.1 (IMPLEMENTATION.md §7): every call is the prison no-op (adapters/base.lua).
-- When qbx_policejob is not started, the loader logs one warning at start and the calls stay no-ops.
return require('adapters.base').define({
    kind = 'prison',
    name = 'qbx_police-jail',
    resource = 'qbx_policejob',
    stub = true,
    task = '4.1',
    methods = {},
})
