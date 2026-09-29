-- SPDX-License-Identifier: GPL-3.0-only
-- garage adapter "qbx_garages": Qbox qbx_garages (VERIFY a park/take-out event or add a patch in task 3.4).
-- Stub until task 3.4 (IMPLEMENTATION.md §7): every call is the garage no-op (adapters/base.lua).
-- When qbx_garages is not started, the loader logs one warning at start and the calls stay no-ops.
return require('adapters.base').define({
    kind = 'garage',
    name = 'qbx_garages',
    resource = 'qbx_garages',
    stub = true,
    task = '3.4',
    methods = {},
})
