-- SPDX-License-Identifier: GPL-3.0-only
-- fredpd_records server entry (IMPLEMENTATION.md §5.3, docs/contracts.md §C12, docs/modules/records.md).
-- Exports, one lib.callback (station release requests) and one server event listener; no threads or timers. The fredpd_mdt dispatcher calls them after its own input, grant,
-- duty and rate-limit checks; any server resource could call them too, so each export validates its input again
-- (and re-checks the search grant) and never trusts an actor citizenid from its arguments.
-- Convention (§C12): exports.fredpd_records:<fn>(src, input) -> { ok = true, data = … } | { ok = false, error = code }.

local C = require 'server.common'
local Search = require 'server.search'
local Summary = require 'server.summary'
local Cases = require 'server.cases'
local Reports = require 'server.reports'
local Charges = require 'server.charges'
local Poi = require 'server.poi'
local Shares = require 'server.shares'
local Releases = require 'server.releases'
local Export = require 'server.export'

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
    -- Phase 5 (§C14 RECORDS_ACTIONS)
    listCases = Cases.listCases,
    getCase = Cases.getCase,
    createCase = Cases.createCase,
    updateCase = Cases.updateCase,
    assignCase = Cases.assignCase,
    unassignCase = Cases.unassignCase,
    addCaseSubject = Cases.addCaseSubject,
    closeCase = Cases.closeCase,
    getReport = Reports.getReport,
    createReport = Reports.createReport,
    saveReport = Reports.saveReport,
    saveReportDraft = Reports.saveReportDraft,
    listReportTemplates = Reports.listReportTemplates,
    listCharges = Charges.listCharges,
    applyCharges = Charges.applyCharges,
    issueFine = Charges.issueFine,
    -- Phase 5 additions (docs/modules/records.md: POI, shares, release requests)
    getPoi = Poi.getPoi,
    updatePoi = Poi.updatePoi,
    createShare = Shares.createShare,
    revokeShare = Shares.revokeShare,
    createReleaseRequest = Releases.createReleaseRequest,
    listReleaseRequests = Releases.listReleaseRequests,
    decideReleaseRequest = Releases.decideReleaseRequest,
}

-- Exports without a player src (service via the fredpd_core HTTP bridge; both check GetInvokingResource).
local SYSTEM_EXPORTS = {
    viewShare = Shares.viewShare,
    createReleaseRequestPortal = Releases.createReleaseRequestPortal,
}

-- §4.3 aliases (IMPLEMENTATION.md): createCase, closeCase, createReport as above; addAssignee = assignCase,
-- addCharge = applyCharges.
EXPORTS.addAssignee = Cases.assignCase
EXPORTS.addCharge = Charges.applyCharges

for name, fn in pairs(EXPORTS) do
    exports(name, guarded(name, fn))
end
for name, fn in pairs(SYSTEM_EXPORTS) do
    exports(name, function(input)
        return guarded(name, function(_, i) return fn(i) end)(0, input)
    end)
end

-- "Begär ut allmän handling" at a station (a FredBridge.target box zone on the client, integration request): any player with a character;
-- rate limited in Releases.createReleaseRequest (1 per 60 s). The station position is not checked (see the module doc).
if type(lib) == 'table' and type(lib.callback) == 'table' and lib.callback.register then
    lib.callback.register('fredpd:records:releaseRequest', function(source, input)
        local src = source
        return guarded('releaseRequest', Releases.createReleaseRequest)(src, input)
    end)
end

-- The masked release export evaluates canView itself (public viewer); reload its rule copy when the rules change.
AddEventHandler('fredpd:rulesChanged', function() Export.resetRules() end)

-- formats.json is read lazily by the first search as well; loading it here only reports a problem early.
Search.loadFormats()

return { guarded = guarded, EXPORTS = EXPORTS, SYSTEM_EXPORTS = SYSTEM_EXPORTS }
