-- SPDX-License-Identifier: GPL-3.0-only
-- Fake persons and vehicles for /fredpd_seed. Pure (random source injectable). The rows are inserted by
-- exports.fredpd_core:seedDevRows, which only accepts citizenids starting with 'DEV' and never overwrites a row.
-- Names are sample data, not UI text.

local M = {}

M.PREFIX = 'DEV'
M.FIRST_MALE = { 'Erik', 'Lars', 'Johan', 'Anders', 'Nils', 'Oskar', 'Per', 'Karl', 'Olof', 'Gustav', 'Axel', 'Mikael' }
M.FIRST_FEMALE = { 'Anna', 'Sara', 'Karin', 'Emma', 'Maria', 'Elin', 'Ida', 'Lina', 'Maja', 'Ebba', 'Astrid', 'Sofia' }
M.LAST = {
    'Andersson', 'Johansson', 'Karlsson', 'Nilsson', 'Eriksson', 'Larsson', 'Olsson', 'Persson', 'Svensson',
    'Gustafsson', 'Pettersson', 'Jönsson', 'Lindberg', 'Öberg', 'Åberg', 'Lindqvist', 'Sandström', 'Holm',
}
M.MODELS = { 'sultan', 'blista', 'asea', 'premier', 'stanier', 'primo', 'tailgater', 'buffalo', 'baller', 'rumpo' }
-- Swedish plates skip I, Q and V (and Å, Ä, Ö).
local LETTERS = 'ABCDEFGHJKLMNOPRSTUWXYZ'
local LAST_CHAR = LETTERS .. '0123456789'

local function pick(list, rand) return list[rand(1, #list)] end
local function char(set, rand)
    local i = rand(1, #set)
    return set:sub(i, i)
end

--- A plate in the default Swedish format 'ABC12D' (normalised, no space).
function M.plate(rand)
    return char(LETTERS, rand) .. char(LETTERS, rand) .. char(LETTERS, rand)
        .. ('%02d'):format(rand(0, 99)) .. char(LAST_CHAR, rand)
end

--- n persons with citizenids DEV<startIndex..>, each with 0-2 vehicles.
--- @param n integer
--- @param startIndex integer first number after the prefix
--- @param rand function|nil math.random-compatible (rand(a, b) inclusive)
--- @return table persons, table vehicles
function M.generate(n, startIndex, rand)
    rand = rand or math.random
    local persons, vehicles = {}, {}
    for i = 0, n - 1 do
        local citizenid = ('%s%05d'):format(M.PREFIX, startIndex + i)
        local gender = rand(0, 1)
        persons[#persons + 1] = {
            citizenid = citizenid,
            firstname = pick(gender == 0 and M.FIRST_MALE or M.FIRST_FEMALE, rand),
            lastname = pick(M.LAST, rand),
            birthdate = ('%04d-%02d-%02d'):format(rand(1950, 2006), rand(1, 12), rand(1, 28)),
            gender = gender,
            phone = ('07%d%07d'):format(rand(0, 9), rand(0, 9999999)),
        }
        for _ = 1, rand(0, 2) do
            vehicles[#vehicles + 1] = { plate = M.plate(rand), citizenid = citizenid, model = pick(M.MODELS, rand) }
        end
    end
    return persons, vehicles
end

return M
