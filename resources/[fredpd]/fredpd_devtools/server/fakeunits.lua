-- SPDX-License-Identifier: GPL-3.0-only
-- /fredpd_fakeunits n seconds: n fake on-duty units that move and raise a test alert every 5 s, for load tests
-- (IMPLEMENTATION.md §5.10, task 8.1). It runs as a SetTimeout chain that ends at the deadline or on stop(); there
-- is no loop and nothing runs while it is idle. Pure apart from the injected deps, so it is tested outside FiveM.

local M = {}

M.TICK_MS = 5000
M.MAX_UNITS = 200
M.MAX_SECONDS = 3600
-- Rough Los Santos bounds for fake positions.
M.AREA = { minX = -2000.0, maxX = 1500.0, minY = -2500.0, maxY = 1000.0, z = 30.0 }

local current = nil -- { id, units, deadline } of the running chain
local counter = 0

--- n fake units spread over the given unit codes, with callsigns like 'IGV-91' (90+ so they never look real).
--- @param units table[] config/units.json entries ({ code, callsign })
function M.makeUnits(n, unitConfig, rand)
    rand = rand or math.random
    local out = {}
    local list = (unitConfig and #unitConfig > 0) and unitConfig or { { code = 'igv', callsign = 'IGV' } }
    for i = 1, n do
        local u = list[(i - 1) % #list + 1]
        out[i] = {
            id = ('FAKE%03d'):format(i),
            unit = u.code,
            callsign = ('%s-%d'):format(u.callsign, 90 + i),
            coords = {
                x = M.AREA.minX + rand() * (M.AREA.maxX - M.AREA.minX),
                y = M.AREA.minY + rand() * (M.AREA.maxY - M.AREA.minY),
                z = M.AREA.z,
            },
            status = 'available',
        }
    end
    return out
end

--- Move every unit up to ~150 m.
function M.step(units, rand)
    rand = rand or math.random
    for _, u in ipairs(units) do
        u.coords.x = math.max(M.AREA.minX, math.min(M.AREA.maxX, u.coords.x + (rand() - 0.5) * 300))
        u.coords.y = math.max(M.AREA.minY, math.min(M.AREA.maxY, u.coords.y + (rand() - 0.5) * 300))
    end
end

--- Start (or replace) the chain. deps = {
---   setTimeout(ms, fn), now() -> ms, units = units.json entries, rand?,
---   emit(units|nil)  -- snapshot every tick; nil when the run ends
---   alert(unit, tick) -- raise one test alert
---   onEnd(reason)     -- 'deadline' | 'stopped' | 'replaced'
--- }. Returns the run id, n and seconds actually used (clamped).
function M.start(n, seconds, deps)
    n = math.max(1, math.min(M.MAX_UNITS, math.tointeger(n) or 1))
    seconds = math.max(1, math.min(M.MAX_SECONDS, math.tointeger(seconds) or 60))
    if current then M.stop('replaced') end
    counter = counter + 1
    local id = counter
    local run = { id = id, units = M.makeUnits(n, deps.units, deps.rand), deadline = deps.now() + seconds * 1000,
        deps = deps, ticks = 0 }
    current = run

    local function tick()
        if current ~= run then return end -- stopped or replaced: the chain ends here
        if deps.now() >= run.deadline then
            M.stop('deadline')
            return
        end
        run.ticks = run.ticks + 1
        M.step(run.units, deps.rand)
        deps.emit(run.units)
        local unit = run.units[(run.ticks - 1) % #run.units + 1]
        deps.alert(unit, run.ticks)
        deps.setTimeout(M.TICK_MS, tick)
    end

    deps.emit(run.units)
    deps.setTimeout(M.TICK_MS, tick)
    return id, n, seconds
end

--- Stop the running chain (the pending timeout then does nothing).
function M.stop(reason)
    local run = current
    if not run then return false end
    current = nil
    run.deps.emit(nil)
    if run.deps.onEnd then run.deps.onEnd(reason or 'stopped', run.ticks) end
    return true
end

function M.running()
    return current ~= nil
end

return M
