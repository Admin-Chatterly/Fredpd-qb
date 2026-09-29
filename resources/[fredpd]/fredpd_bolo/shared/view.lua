-- SPDX-License-Identifier: GPL-3.0-only
-- Result of "Kontrollera registreringsskylt" as an ox_lib context menu (pure; tests/lua/bolo_client_test.lua).
-- ox_lib renders context titles and descriptions as markdown (react-markdown), so every value that comes from data
-- (plate, owner, model, reason, subject, officer names) is escaped before it is put into a locale template; the
-- templates themselves are trusted text. A hit is the first row: red warning icon and a full red bar.

local M = {}

M.MENU_ID = 'fredpd_bolo_platecheck'
M.HIT_COLOR = '#e03131'
M.CLEAR_COLOR = '#2f9e44'

--- Markdown-safe text: control characters become spaces and every ASCII punctuation character is backslash-escaped
--- (CommonMark renders "\x" as the plain character), so no link, image, heading, list or emphasis can be built.
function M.escape(s)
    if s == nil then return '' end
    s = tostring(s):gsub('%c', ' ')
    return (s:gsub('[%p]', '\\%0'))
end

--- Player text for a failed check (server { error, reason }).
function M.errorText(res, L)
    local e = type(res) == 'table' and res.error or nil
    local r = type(res) == 'table' and res.reason or nil
    if e == 'unauthorized' and r == 'off_duty' then return L('errors.notOnDuty') end
    if e == 'unauthorized' then return L('errors.unauthorized') end
    if e == 'rate_limited' then return L('errors.rateLimited') end
    if r == 'too_far' then return L('errors.tooFar') end
    if r == 'no_plate' then return L('bolo.checkPlate.noPlate') end
    if e == 'not_found' then return L('errors.notFound') end
    if e == 'unavailable' then return L('errors.serviceUnavailable') end
    return L('errors.unknown')
end

local function levelLabel(level, L)
    if level == 1 then return L('level.begransad') end
    if level == 2 then return L('level.hemlig') end
    return L('level.standard')
end

--- ox_lib context menu (lib.registerContext argument) for a PlateCheckResult.
--- @param res table PlateCheckResult (nullable fields absent)
--- @param L function locale
--- @param formatDate function|nil (isoUtc) -> 'YYYY-MM-DD HH:mm' for expiresAt; omitted = not shown
function M.menu(res, L, formatDate)
    local plate = M.escape(res.plate)
    local options = {}
    local bolo = res.bolo
    if type(bolo) == 'table' then
        local metadata = { { label = L('bolo.field.level'), value = levelLabel(bolo.level, L) } }
        if type(bolo.issuedBy) == 'table' then
            local by = bolo.issuedBy.callsign and L('bolo.notice.owner',
                { callsign = bolo.issuedBy.callsign, name = bolo.issuedBy.displayName })
                or bolo.issuedBy.displayName
            metadata[#metadata + 1] = { label = L('bolo.field.issuedBy'), value = by }
        end
        if bolo.expiresAt and formatDate then
            local okFmt, text = pcall(formatDate, bolo.expiresAt)
            if okFmt and text then metadata[#metadata + 1] = { label = L('bolo.field.expiresAt'), value = text } end
        end
        options[#options + 1] = {
            title = L('bolo.hit.title'),
            description = L('bolo.hit.plate', { plate = plate, reason = M.escape(bolo.reason) }),
            icon = 'triangle-exclamation',
            iconColor = M.HIT_COLOR,
            progress = 100,
            colorScheme = 'red',
            metadata = metadata,
            readOnly = true,
        }
    else
        options[#options + 1] = {
            title = L('bolo.checkPlate.clear', { plate = plate }),
            icon = 'circle-check',
            iconColor = M.CLEAR_COLOR,
            readOnly = true,
        }
    end
    if type(res.owner) == 'table' then
        options[#options + 1] = {
            title = L('bolo.checkPlate.owner', { name = M.escape(res.owner.name) }),
            icon = 'user',
            readOnly = true,
        }
    else
        options[#options + 1] = {
            title = L('bolo.checkPlate.unregistered', { plate = plate }),
            icon = 'circle-question',
            readOnly = true,
        }
    end
    if res.model then
        options[#options + 1] = {
            title = L('bolo.checkPlate.model', { model = M.escape(res.model) }),
            icon = 'car',
            readOnly = true,
        }
    end
    return {
        id = M.MENU_ID,
        title = L('bolo.checkPlate.header', { plate = plate }),
        options = options,
    }
end

return M
