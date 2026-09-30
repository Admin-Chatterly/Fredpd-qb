-- SPDX-License-Identifier: GPL-3.0-only
-- `fredpd_reload [extra ...]` (server console, txAdmin live console, RCON, or a player with the ACE
-- command.fredpd_reload): stops every started fredpd_* resource (dependents first), then ensures them again in
-- dependency order. Extra resource names (e.g. qb-policejob ps-dispatch) are restarted after FredPD. Console-only text:
-- this is an operator tool, not player-facing.

local ORDER = {
    'fredpd_core', 'fredpd_mdt', 'fredpd_records', 'fredpd_bolo', 'fredpd_dispatch', 'fredpd_forensics',
    'fredpd_intel', 'fredpd_breach', 'fredpd_devtools',
}
local STEP_MS = 300 -- between stop/ensure steps, so each state change settles
local busy = false

local function started(name)
    local state = GetResourceState(name)
    return state == 'started' or state == 'starting'
end

local function run(steps, i)
    if i > #steps then
        busy = false
        print('[fredpd_reloader] done')
        return
    end
    print('[fredpd_reloader] ' .. steps[i])
    ExecuteCommand(steps[i])
    SetTimeout(STEP_MS, function() run(steps, i + 1) end)
end

RegisterCommand('fredpd_reload', function(_source, args)
    if busy then return print('[fredpd_reloader] already running') end
    local active = {}
    for _, name in ipairs(ORDER) do
        if started(name) then active[#active + 1] = name end
    end
    local steps = {}
    for i = #active, 1, -1 do steps[#steps + 1] = 'stop ' .. active[i] end
    for _, name in ipairs(active) do steps[#steps + 1] = 'ensure ' .. name end
    for _, extra in ipairs(args) do
        if type(extra) == 'string' and extra:match('^[%w_%-]+$') and GetResourceState(extra) ~= 'missing' then
            steps[#steps + 1] = (started(extra) and 'restart ' or 'ensure ') .. extra
        end
    end
    if #steps == 0 then return print('[fredpd_reloader] no FredPD resource is started') end
    busy = true
    run(steps, 1)
end, true) -- restricted: console, or ACE command.fredpd_reload
