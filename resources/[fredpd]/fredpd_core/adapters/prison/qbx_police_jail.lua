-- SPDX-License-Identifier: GPL-3.0-only
-- prison adapter "qbx_police-jail": METADATA ONLY, NO CONFINEMENT. qbx_police (resource qbx_policejob) has no jail
-- of its own: police:server:JailPlayer only sets the `injail` / `criminalrecord` metadata and fires a client event
-- nothing implements, and it needs the officer within 2.5 m of the target (docs/deps-verification.md §2). Kept only so
-- task 4.1 can decide between "metadata only" and removing it; never a default. Select it explicitly with
-- "prison": "qbx_police-jail" (the old alias "qbx_police" is gone).
-- Stub until task 4.1 (IMPLEMENTATION.md §7): every call is the prison no-op (adapters/base.lua).
return require('adapters.base').define({
    kind = 'prison',
    name = 'qbx_police-jail',
    resource = 'qbx_policejob',
    stub = true,
    task = '4.1',
    caution = 'qbx_police has no jail: this adapter can only set metadata, it never confines anyone '
        .. '(docs/deps-verification.md §2)',
    methods = {},
})
