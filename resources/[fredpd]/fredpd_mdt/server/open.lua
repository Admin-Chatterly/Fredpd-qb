-- SPDX-License-Identifier: GPL-3.0-only
-- Tablet sessions (IMPLEMENTATION.md §4.3, §4.6, §5.2; docs/contracts.md §C12). `Open[src]` is set only by a
-- successful `fredpd:mdt:open` and is what the action dispatcher and the pushes check. It is cleared by the NUI close
-- (net event fredpd:mdt:closed or the `close` action), playerDropped, logout, and forceClose (revoked tablet, grants
-- or duty lost).
--
-- Open checks, in this order (cheap first, the DB last), each failing with a locale key the client shows:
--   rate limit (errors.rateLimited) -> item mode: pd_tablet in the inventory (tablet.noItem) / terminal mode: seated
--   in a police vehicle (tablet.unavailable) -> any mdt_page grant (tablet.noGrant) -> on duty (tablet.notOnDuty)
--   -> character (tablet.unavailable) -> serial registered (tablet.unregistered), not revoked (tablet.revoked),
--   owner (tablet.notOwner, only with config requireOwner).

local C = require 'server.common'
local Config = require 'config'

local M = {}

M.PUSH_TOPICS = { alerts = true, units = true, bolo = true, case = true, grants = true, ledning = true } -- mdt.ts PUSH_TOPICS
--- Extra recipient rules per topic (dispatch.md: live alerts/units only for holders of mdt_page:alerts).
M.TOPIC_GRANTS = { alerts = { 'mdt_page', 'alerts' }, units = { 'mdt_page', 'alerts' } }
M.UNIT_PATTERN = '^[A-Za-z0-9_%-]+$' -- actions.ts UNIT_CODE_RE ({1,32})

local Open = {} -- [src] = { mode = 'item'|'terminal', serial = string|nil, since = ms }

---------------------------------------------------------------------------------------------------------------
-- State

function M.isOpen(src)
    src = C.playerSrc(src)
    return src ~= nil and Open[src] ~= nil
end

function M.session(src)
    return Open[src]
end

--- Mark closed (NUI close, drop, logout). Returns true when a session was cleared.
function M.markClosed(src)
    src = C.playerSrc(src)
    if not src or not Open[src] then return false end
    Open[src] = nil
    return true
end

--- Close a player's tablet from the server: clear the session and tell the client to release focus and the prop.
--- `reasonKey` (a locale key) is shown to the player. Returns true when the tablet was open.
function M.forceClose(src, reasonKey)
    src = C.playerSrc(src)
    if not src or not Open[src] then return false end
    Open[src] = nil
    TriggerClientEvent('fredpd:client:forceClose', src, reasonKey)
    return true
end

--- Force-close every open tablet using `serial` (a revoked tablet stops working at once). Returns the count.
function M.closeBySerial(serial, reasonKey)
    local hit = {}
    for src, s in pairs(Open) do
        if s.serial ~= nil and s.serial == serial then hit[#hit + 1] = src end
    end
    for _, src in ipairs(hit) do M.forceClose(src, reasonKey) end
    return #hit
end

function M.openSources()
    local out = {}
    for src in pairs(Open) do out[#out + 1] = src end
    table.sort(out)
    return out
end

function M.reset()
    Open = {}
end

---------------------------------------------------------------------------------------------------------------
-- Pushes (only to open tablets, §4.3 / §4.7)

local function validTopic(topic)
    return type(topic) == 'string' and M.PUSH_TOPICS[topic] == true
end

--- Send `topic`/`payload` to every open tablet whose holder is on duty, holds the topic's grant (alerts, units) and
--- passes `filter(src)` when given (a function or a cross-resource function reference). `grants` is per player and
--- never broadcast (use pushTo). Returns the number of tablets reached.
function M.pushToOpenTablets(topic, payload, filter)
    if not validTopic(topic) or topic == 'grants' then
        C.logThrottled('topic:' .. tostring(topic), 'warn', 'pushToOpenTablets: refused topic %s', tostring(topic))
        return 0
    end
    local need = M.TOPIC_GRANTS[topic]
    local n = 0
    for _, src in ipairs(M.openSources()) do
        local ok = C.isOnDuty(src) and (not need or C.hasGrant(src, need[1], need[2]))
        if ok and filter ~= nil then
            local okCall, res = pcall(filter, src)
            ok = okCall and res == true
        end
        if ok then
            TriggerClientEvent('fredpd:client:push', src, topic, payload)
            n = n + 1
        end
    end
    return n
end

--- Send one push to one player's tablet, if it is open. Returns true when sent.
function M.pushTo(src, topic, payload)
    src = C.playerSrc(src)
    if not src or not Open[src] or not validTopic(topic) then return false end
    TriggerClientEvent('fredpd:client:push', src, topic, payload)
    return true
end

---------------------------------------------------------------------------------------------------------------
-- Open

local function fail(key)
    return { error = key }
end

--- The serial of the tablet being used: the slot the inventory reported (ox: the client's item export; qb: qb-core's
--- usable-item callback, server-side) if it really holds a pd_tablet (its serial, or none), else the first pd_tablet
--- slot with a serial. Through the bridge `find` (metadata = ox metadata / qb info). Returns ok, serial|nil.
local function findSerial(src, slot)
    local list = C.findItems(src, Config.item)
    if not list then return false end
    local first = nil
    for _, s in ipairs(list) do
        local serial = type(s) == 'table' and type(s.metadata) == 'table' and s.metadata.serial or nil
        if type(serial) ~= 'string' then serial = nil end
        -- The used tablet decides, even without a serial (it must not borrow another tablet's registration).
        if slot and type(s) == 'table' and s.slot == slot then return true, serial end
        first = first or serial
    end
    return true, first
end

local TERMINAL_MODELS = nil -- model hash set, built on first use (joaat needs FiveM)

--- Model hashes as unsigned 32-bit integers: GetHashKey/GetEntityModel may hand out the signed form.
local function u32(h)
    local i = math.tointeger(h)
    if i then return i & 0xFFFFFFFF end
    return h
end

local function terminalModels()
    if not TERMINAL_MODELS then
        TERMINAL_MODELS = {}
        local hash = joaat or GetHashKey
        for _, name in ipairs(Config.terminal.models) do TERMINAL_MODELS[u32(hash(name))] = true end
    end
    return TERMINAL_MODELS
end

--- Server-side check of the vehicle terminal: the player sits in a listed police model, in an allowed seat.
function M.inTerminalVehicle(src)
    if not Config.terminal.enabled then return false end
    local ok, res = pcall(function()
        local ped = GetPlayerPed(src)
        if not ped or ped == 0 then return false end
        local vehicle = GetVehiclePedIsIn(ped, false)
        if not vehicle or vehicle == 0 or not terminalModels()[u32(GetEntityModel(vehicle))] then return false end
        for _, seat in ipairs(Config.terminal.seats) do
            if GetPedInVehicleSeat(vehicle, seat) == ped then return true end
        end
        return false
    end)
    return ok and res == true
end

local function truthy(v)
    return v == true or v == 1 or v == '1'
end

M.TABLET_SQL = 'SELECT revoked, owner_citizenid FROM fredpd_tablets WHERE serial = ?'

--- Registered and not revoked (and owned by `citizenid` with requireOwner). Returns nil or a locale key.
local function checkSerial(serial, citizenid)
    if type(serial) ~= 'string' or serial == '' or #serial > 32 then return 'tablet.unregistered' end
    local ok, row = pcall(MySQL.single.await, M.TABLET_SQL, { serial })
    if not ok then
        C.logThrottled('db:tablet', 'error', 'tablet lookup failed: %s', tostring(row))
        return 'tablet.unavailable'
    end
    if type(row) ~= 'table' then return 'tablet.unregistered' end
    if truthy(row.revoked) then return 'tablet.revoked' end
    if Config.requireOwner and row.owner_citizenid ~= citizenid then return 'tablet.notOwner' end
    return nil
end

--- MdtOpenPayload.me / the name part of an OfficerRef. Never the character name (§4.9).
function M.me(src, citizenid)
    local ok, officer = C.core('getOfficer', src)
    officer = ok and type(officer) == 'table' and officer or nil
    local name = officer and type(officer.displayName) == 'string' and officer.displayName ~= '' and officer.displayName
    if not name then
        local discord = GetPlayerIdentifierByType and GetPlayerIdentifierByType(src, 'discord') or nil
        local digits = type(discord) == 'string' and discord:match('(%d%d%d%d)$') or '????'
        name = C.L('officer.unnamed', { id = digits })
    end
    return {
        citizenid = citizenid,
        displayName = name,
        callsign = officer and type(officer.callsign) == 'string' and officer.callsign or nil,
        unit = officer and type(officer.unit) == 'string' and officer.unit or nil,
    }
end

--- lib.callback 'fredpd:mdt:open'. req = { mode = 'item'|'terminal', slot = n|nil } (a hint; everything is checked
--- here). Returns MdtOpenPayload { grants, unit, me } or { error = <locale key> }.
function M.open(src, req)
    src = C.playerSrc(src)
    if not src then return fail('tablet.unavailable') end
    if not C.allow(src, 'open', Config.limits.open) then return fail('errors.rateLimited') end
    req = type(req) == 'table' and req or {}
    local mode = req.mode == 'terminal' and 'terminal' or 'item'
    local slot = math.tointeger(tonumber(req.slot))
    if slot and (slot < 1 or slot > 1000) then slot = nil end

    local needItem = mode == 'item' or Config.terminal.requireItem
    if mode == 'terminal' and not M.inTerminalVehicle(src) then return fail('tablet.unavailable') end
    if needItem then
        local count = C.itemCount(src, Config.item)
        if not count then return fail('tablet.unavailable') end
        -- The bridge answers 0 while the inventory is down: say "unavailable" then, not "no tablet".
        if count < 1 then return fail(C.inventoryUp() and 'tablet.noItem' or 'tablet.unavailable') end
    end
    if not C.anyMdtGrant(src) then return fail('tablet.noGrant') end
    if not C.isOnDuty(src) then return fail('tablet.notOnDuty') end
    local citizenid = C.citizenId(src)
    if not citizenid then return fail('tablet.unavailable') end

    local serial = nil
    if needItem then
        local ok, found = findSerial(src, mode == 'item' and slot or nil)
        if not ok then return fail('tablet.unavailable') end
        serial = found
        local problem = checkSerial(serial, citizenid)
        if problem then return fail(problem) end
    end

    local okGrants, grants = C.core('getGrants', src)
    if not okGrants or type(grants) ~= 'table' then return fail('tablet.unavailable') end
    local units = type(grants.units) == 'table' and grants.units or {}
    local unit = units[1]
    if type(unit) ~= 'string' or #unit > 32 or not unit:find(M.UNIT_PATTERN) then unit = nil end
    local me = M.me(src, citizenid)

    -- The checks above yield (inventory, MySQL, core); a player who dropped meanwhile must not leave a stale session.
    if not GetPlayerName(tostring(src)) then return fail('tablet.unavailable') end
    Open[src] = { mode = mode, serial = serial, since = C.now() }
    return { grants = grants, unit = unit, me = { citizenid = me.citizenid, displayName = me.displayName,
        callsign = me.callsign } }
end

--- Tablet item used where the inventory reports the use on the server (qb: qb-inventory -> qb-core usable item ->
--- fredpd_core registerUsable -> here; ox_inventory too if its item definition ever uses server.export =
--- 'fredpd_core.useItem'). `slot` comes from the inventory resource, never from a client. Runs the same open flow as
--- the 'fredpd:mdt:open' callback (the ox client.export path) and sends its result to the player's client, which
--- shows the tablet or the refusal (fredpd:client:openTablet). Call from a thread (MySQL await).
function M.useItem(src, slot)
    src = C.playerSrc(src)
    if not src then return false end
    slot = math.tointeger(tonumber(slot))
    local res = M.open(src, { mode = 'item', slot = slot })
    TriggerClientEvent('fredpd:client:openTablet', src, res)
    return res.error == nil
end

---------------------------------------------------------------------------------------------------------------
-- Server-side reasons to close

--- fredpd:grantsChanged(src) (fredpd_core, server-local): close when no mdt_page grant is left.
function M.onGrantsChanged(src)
    src = C.playerSrc(src)
    if src and Open[src] and not C.anyMdtGrant(src) then M.forceClose(src, 'tablet.noGrant') end
end

--- fredpd:bridge:dutyChanged / jobChanged (fredpd_core bridge): close when the player is no longer on duty.
function M.onDutyChanged(src)
    src = C.playerSrc(src)
    if src and Open[src] and not C.isOnDuty(src) then M.forceClose(src, 'tablet.notOnDuty') end
end

--- fredpd:bridge:playerUnloaded (logout or drop): clear the session and close the client's tablet (the server decides;
--- the client listens to no framework event).
function M.onUnloaded(src)
    return M.forceClose(src, nil)
end

function M.onDropped(src)
    src = C.playerSrc(src)
    if not src then return end
    Open[src] = nil
    C.forget(src)
end

return M
