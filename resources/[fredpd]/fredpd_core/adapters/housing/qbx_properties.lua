-- SPDX-License-Identifier: GPL-3.0-only
-- housing adapter "qbx_properties": Qbox qbx_properties (VERIFY its door/lock API in task 6.2).
-- Stub until task 6.2 (IMPLEMENTATION.md §7): every call is the housing no-op (adapters/base.lua).
-- When qbx_properties is not started, the loader logs one warning at start and the calls stay no-ops.
return require('adapters.base').define({
    kind = 'housing',
    name = 'qbx_properties',
    resource = 'qbx_properties',
    stub = true,
    task = '6.2',
    methods = {},
})
