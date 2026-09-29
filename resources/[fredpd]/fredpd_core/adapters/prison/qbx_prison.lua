-- SPDX-License-Identifier: GPL-3.0-only
-- prison adapter "qbx_prison": Qbox qbx_prison. OPT-IN ONLY, NOT RECOMMENDED: qbx_prison must not run on a FredPD
-- server as shipped. Its net event qbx_prison:server:onGateHackDone lets any client unlock any ox_doorlock door
-- (station doors, fredpd_breach targets), and clients can clear or set their own sentence
-- (docs/deps-verification.md §2a, Decision 2). Only for a server that already runs it with those events patched
-- (e.g. a server-side gate key); selecting it logs a warning every start. The default is "none" until the
-- xt-prison adapter exists (task 4.1).
-- Stub until task 4.1 (IMPLEMENTATION.md §7): every call is the prison no-op (adapters/base.lua).
return require('adapters.base').define({
    kind = 'prison',
    name = 'qbx_prison',
    resource = 'qbx_prison',
    stub = true,
    task = '4.1',
    caution = 'qbx_prison lets any client unlock any ox_doorlock door and clear its own sentence unless patched '
        .. '(docs/deps-verification.md §2a); use xt-prison (task 4.1) or "none"',
    methods = {},
})
