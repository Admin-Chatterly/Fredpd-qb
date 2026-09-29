-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_intel server entry (IMPLEMENTATION.md §5.8, docs/contracts.md §C15, docs/modules/intel.md). Registers the
-- INTEL_ACTIONS exports (the fredpd_mdt dispatcher routes tablet actions to them, §C12 convention), the §4.3 exports
-- addSource / addReport / addLink / getGraph and getPersonNotices for fredpd_records. Nothing runs while idle: every
-- path starts from an export call.

local Service = require 'server.service'

local M = {}

function M.start()
    for name, fn in pairs(Service.ACTIONS) do exports(name, fn) end

    -- IMPLEMENTATION.md §4.3 names (same handlers, same { ok, data | error } results).
    exports('addSource', Service.createSource)
    exports('addReport', Service.createIntelReport)
    -- addLink and getGraph are already INTEL_ACTIONS names; getGraph also takes (entityId, viewerSrc).

    exports('getPersonNotices', Service.getPersonNotices)

    AddEventHandler('playerDropped', function()
        Service.forget(source)
    end)
end

M.start()

return M
