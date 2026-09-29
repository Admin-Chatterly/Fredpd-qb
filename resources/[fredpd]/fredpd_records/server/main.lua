-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_records server entry (IMPLEMENTATION.md §5.3, docs/contracts.md §C12, docs/modules/records.md).
-- Exports only; no events, threads or timers. The fredpd_mdt dispatcher calls them after its own input, grant,
-- duty and rate-limit checks; any server resource could call them too, so each export validates its input again
-- (and re-checks the search grant) and never trusts an actor citizenid from its arguments.
-- Convention (§C12): exports.fredpd_records:<fn>(src, input) -> { ok = true, data = … } | { ok = false, error = code }.

local C = require 'server.common'
local Search = require 'server.search'
local Summary = require 'server.summary'

--- Wrap an export: a Lua error (database down, a dependency raising) becomes { ok = false, error = 'unavailable' }
--- and is logged; a malformed return value is treated the same way.
local function guarded(name, fn)
    return function(src, input)
        local ok, res = pcall(fn, src, input)
        if not ok then
            C.error(('%s failed: %s'):format(name, tostring(res)))
            return C.fail('unavailable')
        end
        if type(res) ~= 'table' or type(res.ok) ~= 'boolean' then
            C.error(('%s returned no result'):format(name))
            return C.fail('unavailable')
        end
        return res
    end
end

local EXPORTS = {
    search = Search.search,
    getPersonSummary = Summary.person,
    getVehicleSummary = Summary.vehicle,
    getHomeCases = Summary.homeCases,
    countMyOpenCases = Summary.countMyOpenCases,
}

for name, fn in pairs(EXPORTS) do
    exports(name, guarded(name, fn))
end

-- formats.json is read lazily by the first search as well; loading it here only reports a problem early.
Search.loadFormats()

return { guarded = guarded, EXPORTS = EXPORTS }
