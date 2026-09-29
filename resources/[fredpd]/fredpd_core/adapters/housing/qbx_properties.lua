-- SPDX-License-Identifier: GPL-3.0-only
-- housing adapter "qbx_properties": Qbox qbx_properties. Checked in task 6.2: nothing to call, so it stays a stub and
-- every call is the housing no-op (adapters/base.lua).
-- When qbx_properties is not started, the loader logs one warning at start and the calls stay no-ops.
-- qbx_properties has no exports at all (Qbox-project/qbx_properties@9bbdb43, docs/deps-verification.md §11), so this
-- stays a stub: servers running it use "ox_doorlock-only" with a door mapping (docs/modules/breach.md).
local adapter = require('adapters.base').define({
    kind = 'housing',
    name = 'qbx_properties',
    resource = 'qbx_properties',
    stub = true,
    task = '6.2',
    methods = {},
})

--- Convenience: the first address label, or nil (the same helper exists on every housing adapter).
function adapter.getAddress(citizenid)
    local list = adapter.getAddresses(citizenid)
    return type(list) == 'table' and list[1] and list[1].label or nil
end

return adapter
