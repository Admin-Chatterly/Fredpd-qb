-- SPDX-License-Identifier: GPL-3.0-only
-- housing adapter "none": no integration installed; every call is the housing no-op from adapters/base.lua.
local adapter = require('adapters.base').define({ kind = 'housing', name = 'none' })

--- Convenience: the first address label, or nil (the same helper exists on every housing adapter).
function adapter.getAddress(citizenid)
    local list = adapter.getAddresses(citizenid)
    return type(list) == 'table' and list[1] and list[1].label or nil
end

return adapter
