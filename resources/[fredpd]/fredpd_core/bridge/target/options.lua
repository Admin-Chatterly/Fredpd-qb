-- SPDX-License-Identifier: GPL-3.0-only
-- Normalised target options (docs/contracts.md §C17): { name, label, icon, distance, canInteract, onSelect }.
--   canInteract(entity, distance, coords) -> boolean     (coords may be nil on qb-target)
--   onSelect({ entity, coords, distance })               (distance nil on qb-target)
-- Pure: loaded by bridge/client.lua in any resource and by the tests. The impls (qb_target.lua, ox_target.lua)
-- translate the result to their upstream shape.

local M = {}

--- Validated copy of one option; nil + reason when unusable. name and label are required (qb-target keys options by
--- label, ox_target removes them by name); distance defaults to `default`.
function M.one(opt, default)
    if type(opt) ~= 'table' then return nil, 'not a table' end
    if type(opt.name) ~= 'string' or opt.name == '' then return nil, 'option without name' end
    if type(opt.label) ~= 'string' or opt.label == '' then return nil, ('option %s without label'):format(opt.name) end
    if opt.onSelect ~= nil and type(opt.onSelect) ~= 'function' and type(opt.onSelect) ~= 'table' then
        return nil, ('option %s: onSelect is not a function'):format(opt.name)
    end
    return {
        name = opt.name,
        label = opt.label,
        icon = type(opt.icon) == 'string' and opt.icon or nil,
        distance = tonumber(opt.distance) or default,
        canInteract = opt.canInteract,
        onSelect = opt.onSelect,
    }
end

--- A single option or a list -> list of validated options. Errors on the first bad one (a programming mistake).
function M.list(opts, default)
    if type(opts) ~= 'table' then error('target options must be a table', 3) end
    if opts.name ~= nil or opts.label ~= nil then opts = { opts } end
    local out = {}
    for i, opt in ipairs(opts) do
        local o, err = M.one(opt, default)
        if not o then error(('target option %d: %s'):format(i, err), 3) end
        out[#out + 1] = o
    end
    return out
end

--- Names and labels of a list (for the remove handle).
function M.keys(list)
    local names, labels = {}, {}
    for i, o in ipairs(list) do
        names[i] = o.name
        labels[i] = o.label
    end
    return names, labels
end

--- Largest option distance (qb-target's per-call `distance`), or nil.
function M.maxDistance(list)
    local max = nil
    for _, o in ipairs(list) do
        if o.distance and (not max or o.distance > max) then max = o.distance end
    end
    return max
end

--- The selection payload handed to onSelect.
function M.selection(entity, coords, distance)
    return { entity = entity, coords = coords, distance = distance }
end

return M
