-- SPDX-License-Identifier: GPL-3.0-only
-- Alert lifecycle (docs/contracts.md §C13): create, list, take (assignSelf / takeNewest), leave, close, units.
-- The src-taking functions are the tablet actions behind the fredpd_mdt dispatcher and follow its export
-- convention (§C12): { ok = true, data = … } or { ok = false, error = MDT error code }. The dispatcher has already
-- checked grant, duty and rate limits; they are checked again here (defensive: any resource can call an export).
--
-- Status rules: open -> assigned on the first take; assigned -> open when the last unit leaves; closed is final.
-- Take/leave/close are audited (alert.assign, alert.leave, alert.close); creation is not (the row is the record).
--
-- Fan-out after every change (all non-blocking, see server/fanout.lua):
--   created  toast to on-duty officers with mdt_page:alerts, server event fredpd:alertCreated(alert),
--            push alerts { type = 'created', alert }, POST /internal/events alertCreated
--   take     server event fredpd:alertAssigned(alertId, src), push alerts { type = 'updated', alert },
--            POST alertAssigned (payload = the updated Alert), units roster rebuild
--   leave    push 'updated', POST alertAssigned (assignment changed), units roster rebuild
--   close    server event fredpd:alertClosed(alertId, src), push alerts { type = 'closed', id }, POST alertClosed { id },
--            units roster rebuild
-- A take/leave whose read-back finds the alert closed (a close committed in between) skips its 'updated' push and
-- alertAssigned events: the close's 'closed' push must stay the last word for the tablets.

local Input = require 'shared.alert_input'
local Store = require 'server.alert_store'
local Fanout = require 'server.fanout'
local Roster = require 'server.unit_roster'

local M = {}

M.MANAGE_PERM = 'alerts.manage'
M.TAKE_ATTEMPTS = 3 -- takeNewest: candidates tried when other officers win the race for the newest one

local function fail(code, reason)
    return { ok = false, error = code, reason = reason }
end

local function ok(data)
    return { ok = true, data = data }
end

--- Run a DB step; a failure becomes 'unavailable' (logged), never an error thrown into the caller.
local function db(label, fn, ...)
    local okCall, a, b = pcall(fn, ...)
    if not okCall then
        Fanout.log('error', '%s failed: %s', label, tostring(a))
        return false
    end
    return true, a, b
end

--- The acting officer: a connected player with grant mdt_page:alerts, on duty, with a character.
--- @return table|nil { src, citizenid, callsign }, string|nil error, string|nil reason
function M.actor(src)
    src = tonumber(src)
    if not src or src < 1 or not math.tointeger(src) then return nil, 'unauthorized' end
    local core = exports.fredpd_core
    if core:hasGrant(src, Fanout.ALERTS_GRANT[1], Fanout.ALERTS_GRANT[2]) ~= true then return nil, 'unauthorized' end
    if core:isOnDuty(src) ~= true then return nil, 'unauthorized', 'off_duty' end
    local citizenid = core:getCitizenId(src)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil, 'unauthorized' end
    local officer = core:getOfficer(src)
    return { src = math.tointeger(src), citizenid = citizenid, callsign = officer and officer.callsign or nil }
end

local function audit(src, action, id, meta)
    local okCall, err = pcall(function() exports.fredpd_core:audit(src, action, 'alert', id, meta) end)
    if not okCall then Fanout.log('error', 'audit %s #%d failed: %s', action, id, tostring(err)) end
end

---------------------------------------------------------------------------------------------------------------
-- createAlert

--- export createAlert(data): data = AlertCreateInput (dispatch.ts). Returns the Alert, or nil and an error code
--- ('validation' + the bad field, or 'unavailable'). Must run in a thread (awaits the insert).
function M.create(data)
    local input, field = Input.validateCreate(data)
    if not input then return nil, 'validation', field end

    local okInsert, id = db('alert insert', Store.insert, input)
    if not okInsert or not id then return nil, 'unavailable' end

    -- The toast needs nothing the database adds but the id: send it before reading the row back (§5.5: toast
    -- within 100 ms).
    Fanout.toast({ id = id, code = input.code, title = input.title, street = input.street, priority = input.priority })

    local okLoad, alert = db('alert load', Store.loadOne, id)
    if not okLoad or not alert then return nil, 'unavailable' end
    TriggerEvent('fredpd:alertCreated', alert)
    Fanout.push('alerts', { type = 'created', alert = alert })
    Fanout.postInternal('alertCreated', alert)
    return alert
end

---------------------------------------------------------------------------------------------------------------
-- Take / leave / close

--- After a unit row was added. The join is audited in any case (the row exists), but when a close committed between
--- the join and the read-back, the close has already pushed { type = 'closed' }: an 'updated' push or an
--- alertAssigned event for the closed alert would put it back on the tablets. @return boolean still live
local function afterAssign(actor, alert, via)
    local closed = alert.status == 'closed'
    audit(actor.src, 'alert.assign', alert.id, closed and { via = via, closedMeanwhile = true } or { via = via })
    Roster.schedule()
    if closed then return false end
    TriggerEvent('fredpd:alertAssigned', alert.id, actor.src)
    Fanout.push('alerts', { type = 'updated', alert = alert })
    Fanout.postInternal('alertAssigned', alert)
    return true
end

--- Join alert `id` (open or assigned). Idempotent: an officer already on it gets the alert back (no new audit).
local function join(actor, id, via)
    local okAdd, added = db('alert addUnit', Store.addUnit, id, actor.citizenid, actor.callsign)
    if not okAdd then return fail('unavailable') end
    if added == 0 then
        local okState, status, mine = db('alert state', Store.state, id, actor.citizenid)
        if not okState then return fail('unavailable') end
        if not status or status == 'closed' or not mine then return fail('not_found') end
        local okLoad, alert = db('alert load', Store.loadOne, id)
        if not okLoad or not alert then return fail('unavailable') end
        return ok(alert)
    end
    local okMark = db('alert markAssigned', Store.markAssigned, id)
    if not okMark then return fail('unavailable') end
    local okLoad, alert = db('alert load', Store.loadOne, id)
    if not okLoad or not alert then return fail('unavailable') end
    if not afterAssign(actor, alert, via) then return fail('not_found') end -- closed in the meantime
    return ok(alert)
end

--- export assignSelf(src, { id }) (= tablet action takeAlert).
function M.assignSelf(src, input, via)
    local actor, code, reason = M.actor(src)
    if not actor then return fail(code, reason) end
    local id = Input.alertId(input)
    if not id then return fail('validation') end
    return join(actor, id, via or 'tablet')
end

--- export takeNewest(src): claim the newest open alert and join it (the "Ta larm" key). Only open alerts are
--- candidates; when two officers press at once, the claim (open -> assigned) has one winner and the other gets
--- the next open alert, or not_found.
function M.takeNewest(src)
    local actor, code, reason = M.actor(src)
    if not actor then return fail(code, reason) end
    for _ = 1, M.TAKE_ATTEMPTS do
        local okId, id = db('alert newestOpen', Store.newestOpenId)
        if not okId then return fail('unavailable') end
        if not id then return fail('not_found') end
        local okClaim, claimed = db('alert claim', Store.claim, id)
        if not okClaim then return fail('unavailable') end
        if claimed then
            local okAdd, added = db('alert addUnit', Store.addUnit, id, actor.citizenid, actor.callsign)
            if okAdd and added > 0 then
                -- Same as join(): if another officer joined and left between the claim and our addUnit, their
                -- leave reopened the alert (nobody on it yet); mark it assigned again. No-op when still assigned.
                if not db('alert markAssigned', Store.markAssigned, id) then return fail('unavailable') end
                local okLoad, alert = db('alert load', Store.loadOne, id)
                if not okLoad or not alert then return fail('unavailable') end
                if afterAssign(actor, alert, 'keybind') then return ok(alert) end
                -- Closed right after we joined: try the next open alert.
            else
                -- Closed between claim and join (or the insert failed): undo the claim if nobody is on it.
                db('alert reopen', Store.reopenIfEmpty, id)
                if not okAdd then return fail('unavailable') end
            end
        end
    end
    return fail('not_found')
end

--- export leaveAlert(src, { id }).
function M.leave(src, input)
    local actor, code, reason = M.actor(src)
    if not actor then return fail(code, reason) end
    local id = Input.alertId(input)
    if not id then return fail('validation') end
    local okRemove, removed = db('alert removeUnit', Store.removeUnit, id, actor.citizenid)
    if not okRemove then return fail('unavailable') end
    if removed == 0 then return fail('not_found') end
    db('alert reopen', Store.reopenIfEmpty, id)
    audit(actor.src, 'alert.leave', id, nil)
    local okLoad, alert = db('alert load', Store.loadOne, id)
    if not okLoad or not alert then return fail('unavailable') end
    Roster.schedule()
    -- The leave itself succeeded; if a close committed right after it, the close's { type = 'closed' } push stands
    -- and no 'updated' (which would put the closed alert back on the tablets) follows.
    if alert.status ~= 'closed' then
        Fanout.push('alerts', { type = 'updated', alert = alert })
        Fanout.postInternal('alertAssigned', alert)
    end
    return ok(alert)
end

--- export closeAlert(src, { id }): an officer on the alert, or a holder of perm alerts.manage.
function M.close(src, input)
    local actor, code, reason = M.actor(src)
    if not actor then return fail(code, reason) end
    local id = Input.alertId(input)
    if not id then return fail('validation') end
    local okState, status, mine = db('alert state', Store.state, id, actor.citizenid)
    if not okState then return fail('unavailable') end
    if not status or status == 'closed' then return fail('not_found') end
    if not mine and exports.fredpd_core:hasGrant(actor.src, 'perm', M.MANAGE_PERM) ~= true then
        return fail('unauthorized')
    end
    local okClose, closed = db('alert close', Store.close, id, actor.citizenid)
    if not okClose then return fail('unavailable') end
    if not closed then return fail('not_found') end -- closed by someone else in the meantime
    audit(actor.src, 'alert.close', id, { assigned = mine })
    local okLoad, alert = db('alert load', Store.loadOne, id)
    if not okLoad or not alert then return fail('unavailable') end
    TriggerEvent('fredpd:alertClosed', id, actor.src)
    Fanout.push('alerts', { type = 'closed', id = id })
    Fanout.postInternal('alertClosed', { id = id })
    Roster.schedule()
    return ok(alert)
end

---------------------------------------------------------------------------------------------------------------
-- Reads

--- export listAlerts(src, { filter?, page? }) -> AlertListOutput.
function M.list(src, input)
    local actor, code, reason = M.actor(src)
    if not actor then return fail(code, reason) end
    local q = Input.listInput(input)
    if not q then return fail('validation') end
    local okList, result = db('alert list', Store.list, q.filter, actor.citizenid, q.page)
    if not okList then return fail('unavailable') end
    return ok(result)
end

--- export getUnits(src) -> UnitsPush.
function M.getUnits(src)
    local actor, code, reason = M.actor(src)
    if not actor then return fail(code, reason) end
    local okUnits, units = db('units roster', Roster.current)
    if not okUnits then return fail('unavailable') end
    return ok({ units = units })
end

return M
