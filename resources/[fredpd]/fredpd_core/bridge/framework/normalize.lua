-- SPDX-License-Identifier: GPL-3.0-only
-- PlayerData -> the normalised bridge player (docs/contracts.md §C17). qb-core and qbx_core share the PlayerData
-- layout FredPD reads:
--   job = { name, label, type, onduty, isboss, grade = { name, level } }
--     qb-core  server/player.lua:66-91 (Player:SetJob), shared/jobs.lua:14-26 (police: type = 'leo')
--     qbx_core server/player.lua:217-231 (toPlayerJob), :699-711 (on load), same keys
--   charinfo = { firstname, lastname, birthdate, gender, phone, ... }, citizenid, license, source
-- Pure (no FiveM natives), tested by tests/lua/bridge_framework_test.lua.

local M = {}

--- Normalised job: { name, label, type, grade = level (integer), gradeName, onduty = boolean, isboss = boolean }.
--- nil when job is not a table.
function M.job(job)
    if type(job) ~= 'table' then return nil end
    local grade, gradeName = 0, nil
    if type(job.grade) == 'table' then
        grade = math.tointeger(tonumber(job.grade.level)) or 0
        gradeName = type(job.grade.name) == 'string' and job.grade.name or nil
    elseif tonumber(job.grade) then
        grade = math.tointeger(tonumber(job.grade)) or 0
    end
    return {
        name = type(job.name) == 'string' and job.name or nil,
        label = type(job.label) == 'string' and job.label or nil,
        type = type(job.type) == 'string' and job.type or nil,
        grade = grade,
        gradeName = gradeName,
        onduty = job.onduty == true,
        isboss = job.isboss == true or (type(job.grade) == 'table' and job.grade.isboss == true),
    }
end

--- Character name from charinfo (qb-core Player:GetName, server/player.lua:132-135), or nil.
function M.name(charinfo)
    if type(charinfo) ~= 'table' then return nil end
    local first = type(charinfo.firstname) == 'string' and charinfo.firstname or ''
    local last = type(charinfo.lastname) == 'string' and charinfo.lastname or ''
    local name = (first .. ' ' .. last):match('^%s*(.-)%s*$')
    if name == '' then return nil end
    return name
end

--- Normalised player: { source, citizenid, license, name, job, charinfo } or nil (no citizenid).
function M.player(pd)
    if type(pd) ~= 'table' or type(pd.citizenid) ~= 'string' or pd.citizenid == '' then return nil end
    local charinfo = type(pd.charinfo) == 'table' and pd.charinfo or {}
    return {
        source = tonumber(pd.source),
        citizenid = pd.citizenid,
        license = type(pd.license) == 'string' and pd.license or nil,
        name = M.name(charinfo),
        job = M.job(pd.job) or M.job({}),
        charinfo = charinfo,
    }
end

--- Validated money arguments for removeMoney: account name and a positive whole amount, or nil.
function M.money(account, amount)
    if type(account) ~= 'string' or not account:match('^[%a_]+$') or #account > 32 then return nil end
    amount = tonumber(amount)
    if not amount or amount ~= amount or amount <= 0 or amount == math.huge then return nil end
    amount = math.floor(amount + 0.5)
    if amount <= 0 then return nil end
    return account:lower(), amount
end

return M
