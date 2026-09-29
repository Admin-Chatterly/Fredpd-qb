-- SPDX-License-Identifier: GPL-3.0-only
-- Tablet search (task 2.3 server side; SearchInput/SearchOutput in packages/types/src/mdt.ts, §C12).
-- 'auto' classifies the query with shared/format.lua detectSearchType and config/formats.json (§C4):
--   name       -> fredpd_persons FULLTEXT ft_name (MATCH ... AGAINST IN BOOLEAN MODE, '+term*' per term); terms the
--                 index cannot hold (shorter than innodb_ft_min_token_size, or stopwords / their prefixes) use
--                 lastname/firstname LIKE 'term%' instead. Never players.charinfo (IMPLEMENTATION.md §8.6).
--   personId   -> fredpd_persons.personnummer exact (10- and 12-digit spellings, idx_personnummer)
--   plate      -> fredpd_vehicles_idx primary key; a miss asks exports.fredpd_core:refreshPlate once
--   caseNumber -> fredpd_cases.case_number exact, shaped by canView (server/caserefs.lua)
-- User text only ever reaches SQL as bound parameters; boolean-mode operators are removed from the terms (a term
-- is a run of letters/digits), so `+x -y "z" (w) ~v @3` cannot change the query. Pages of 50, total via
-- COUNT(*) OVER () in the same query. One audit row per search (§4.5), BOLO flags via fredpd_bolo.

local C = require 'server.common'
local Refs = require 'server.caserefs'
local Format = require '@fredpd_core.shared.format'

local M = {}

M.PAGE_SIZE = 50
M.MAX_PAGE = 10000
M.MAX_TERMS = 6
M.MAX_TERM_CHARS = 32
M.TYPES = { auto = true, person = true, vehicle = true, case = true }

-- InnoDB's default FULLTEXT stopwords (INFORMATION_SCHEMA.INNODB_FT_DEFAULT_STOPWORD, MariaDB 10.11). Stopwords
-- are not indexed, so 'Will' or 'De' can only be found with LIKE; a server-level custom stopword table is not read.
M.STOPWORDS = {
    'a', 'about', 'an', 'are', 'as', 'at', 'be', 'by', 'com', 'de', 'en', 'for', 'from', 'how', 'i', 'in', 'is', 'it',
    'la', 'of', 'on', 'or', 'that', 'the', 'this', 'to', 'was', 'what', 'when', 'where', 'who', 'will', 'with', 'und',
    'www',
}

local PERSON_COLS = "p.citizenid, p.firstname, p.lastname, DATE_FORMAT(p.birthdate, '%Y-%m-%d') AS birthdate, "
    .. 'p.personnummer'
local PERSON_ORDER = ' ORDER BY p.lastname, p.firstname, p.citizenid'

---------------------------------------------------------------------------------------------------------------
-- Config (formats.json from fredpd_core; FULLTEXT settings from the server), loaded once

local formats -- compiled by Format.load
local ftSettings

--- Load config/formats.json from fredpd_core (copied there by scripts/build.mjs). Returns true when usable.
function M.loadFormats()
    if formats then return true end
    local text = LoadResourceFile(C.CORE, 'config/formats.json')
    if type(text) ~= 'string' then
        C.warnOnce('formats', 'fredpd_core config/formats.json not found; search is unavailable')
        return false
    end
    local okDecode, tbl = pcall(json.decode, text)
    if not okDecode or type(tbl) ~= 'table' then
        C.warnOnce('formats', 'fredpd_core config/formats.json is not valid JSON; search is unavailable')
        return false
    end
    local ok, res = pcall(Format.load, tbl)
    if not ok then
        C.warnOnce('formats', ('config/formats.json rejected: %s'):format(tostring(res)))
        return false
    end
    formats = res
    return true
end

--- innodb_ft_min_token_size / innodb_ft_enable_stopword, read once (defaults 3 / on when unreadable).
function M.ftSettings()
    if ftSettings then return ftSettings end
    local ok, row = pcall(MySQL.single.await,
        'SELECT @@innodb_ft_min_token_size AS minToken, @@innodb_ft_enable_stopword AS stopwords')
    local minToken = ok and type(row) == 'table' and C.int(row.minToken) or nil
    ftSettings = {
        minToken = minToken and minToken >= 1 and minToken or 3,
        stopwords = not (ok and type(row) == 'table' and tonumber(row.stopwords) == 0),
    }
    return ftSettings
end

--- Tests only: forget the cached config.
function M.reset()
    formats, ftSettings = nil, nil
end

---------------------------------------------------------------------------------------------------------------
-- Name terms

--- Code point that belongs to a word: ASCII letters/digits and letters beyond ASCII. Latin-1 punctuation and
--- symbols, × ÷, general punctuation (dashes, curly quotes, zero-width), symbol blocks, CJK and full-width
--- punctuation separate words, as every ASCII character outside [A-Za-z0-9] does.
local function isWordCodePoint(cp)
    if cp < 128 then
        return (cp >= 48 and cp <= 57) or (cp >= 65 and cp <= 90) or (cp >= 97 and cp <= 122)
    end
    if cp < 0xC0 or cp == 0xD7 or cp == 0xF7 then return false end
    if cp >= 0x2000 and cp <= 0x2BFF then return false end
    if cp >= 0x3000 and cp <= 0x303F then return false end
    if cp >= 0xFE10 and cp <= 0xFE6F then return false end
    if cp >= 0xFF00 and cp <= 0xFF20 then return false end
    if cp == 0xFEFF then return false end
    return true
end

--- Split a name query into at most MAX_TERMS terms of letters/digits (each cut to MAX_TERM_CHARS code points).
function M.terms(query)
    if type(query) ~= 'string' then return {} end
    if not utf8.len(query) then query = query:gsub('[\128-\255]', ' ') end
    local terms, current = {}, {}
    local function flush()
        if #current > 0 and #terms < M.MAX_TERMS then
            local n = math.min(#current, M.MAX_TERM_CHARS)
            terms[#terms + 1] = utf8.char(table.unpack(current, 1, n))
        end
        current = {}
    end
    for _, cp in utf8.codes(query) do
        if isWordCodePoint(cp) then current[#current + 1] = cp else flush() end
    end
    flush()
    return terms
end

--- Whether a term must use LIKE instead of FULLTEXT: shorter than the index's minimum token size, or (with
--- stopwords on) a stopword or the prefix of one ('wil' would miss 'Will', which the index does not hold).
function M.needsLike(term, settings)
    settings = settings or M.ftSettings()
    if utf8.len(term) < settings.minToken then return true end
    if not settings.stopwords then return false end
    local lower = term:lower()
    for _, word in ipairs(M.STOPWORDS) do
        if word:sub(1, #lower) == lower then return true end
    end
    return false
end

--- LIKE pattern 'term%' with LIKE metacharacters escaped (terms hold none, but never rely on that).
function M.likePrefix(term)
    return (term:gsub('[\\%%_]', '\\%0')) .. '%'
end

--- WHERE clause and params for a name search, or nil when no usable term is left.
function M.nameWhere(terms, settings)
    settings = settings or M.ftSettings()
    local ft, likes, params = {}, {}, {}
    for _, term in ipairs(terms) do
        if M.needsLike(term, settings) then
            likes[#likes + 1] = term
        else
            ft[#ft + 1] = '+' .. term .. '*'
        end
    end
    if #ft == 0 and #likes == 0 then return nil end
    local clauses = {}
    if #ft > 0 then
        clauses[#clauses + 1] = 'MATCH (p.firstname, p.lastname) AGAINST (? IN BOOLEAN MODE)'
        params[#params + 1] = table.concat(ft, ' ')
    end
    for _, term in ipairs(likes) do
        clauses[#clauses + 1] = '(p.lastname LIKE ? OR p.firstname LIKE ?)'
        local pattern = M.likePrefix(term)
        params[#params + 1] = pattern
        params[#params + 1] = pattern
    end
    return table.concat(clauses, ' AND '), params
end

--- personnummer spellings stored in fredpd_persons for a normalised personId ('YYMMDD-XXXX' also matches
--- 'YYYYMMDD-XXXX' of either century; 'YYYYMMDD-XXXX' also matches 'YYMMDD-XXXX').
function M.personnummerCandidates(normalized)
    local head, tail = normalized:match('^(%d+)%-(%d%d%d%d)$')
    if not head then return { normalized } end
    if #head == 6 then return { normalized, '19' .. normalized, '20' .. normalized } end
    if #head == 8 then return { normalized, head:sub(3) .. '-' .. tail } end
    return { normalized }
end

---------------------------------------------------------------------------------------------------------------
-- Queries

local function offset(page)
    return ('%d'):format((page - 1) * M.PAGE_SIZE)
end

--- Page of persons for a WHERE clause: rows and total (COUNT(*) OVER () on the page; a separate COUNT only when a
--- page past the end comes back empty).
local function personPage(where, params, page)
    local rows = MySQL.query.await('SELECT ' .. PERSON_COLS .. ', COUNT(*) OVER () AS total FROM fredpd_persons p '
        .. 'WHERE ' .. where .. PERSON_ORDER .. ' LIMIT ' .. ('%d'):format(M.PAGE_SIZE) .. ' OFFSET ' .. offset(page),
        params)
    if type(rows) ~= 'table' then error('person search query failed', 0) end
    local total = rows[1] and C.nonNeg(rows[1].total) or 0
    if #rows == 0 and page > 1 then
        total = C.nonNeg(MySQL.scalar.await('SELECT COUNT(*) FROM fredpd_persons p WHERE ' .. where, params))
    end
    return rows, total
end

local function personHits(src, rows)
    local running = C.boloRunning()
    local hits = {}
    for _, row in ipairs(rows) do
        local cid = C.str(row.citizenid)
        if cid then
            hits[#hits + 1] = {
                kind = 'person',
                citizenid = cid,
                name = C.fullName(row.firstname, row.lastname) or cid,
                birthdate = C.str(row.birthdate),
                personnummer = C.str(row.personnummer),
                bolo = C.boloFlag(src, 'person', cid, running),
            }
        end
    end
    return hits
end

local function searchName(src, normalized, page)
    local where, params = M.nameWhere(M.terms(normalized))
    if not where then return {}, 0 end
    local rows, total = personPage(where, params, page)
    return personHits(src, rows), total
end

local function searchPersonId(src, normalized, page)
    local candidates = M.personnummerCandidates(normalized)
    local rows, total = personPage('p.personnummer IN (' .. C.marks(#candidates) .. ')', candidates, page)
    return personHits(src, rows), total
end

local VEHICLE_SQL = 'SELECT v.plate, v.model, v.citizenid, p.firstname, p.lastname FROM fredpd_vehicles_idx v '
    .. 'LEFT JOIN fredpd_persons p ON p.citizenid = v.citizenid WHERE v.plate = ?'

--- fredpd_vehicles_idx row (+ owner name) for a normalised plate; on a miss fredpd_core re-reads player_vehicles.
function M.vehicleRow(plate)
    local row = MySQL.single.await(VEHICLE_SQL, { plate })
    if row then return row end
    local ok, refreshed = C.core('refreshPlate', plate)
    if not ok then
        C.warnOnce('refreshPlate', ('exports.fredpd_core:refreshPlate failed: %s'):format(tostring(refreshed)))
        return nil
    end
    if type(refreshed) ~= 'table' then return nil end
    return MySQL.single.await(VEHICLE_SQL, { plate })
end

local function searchPlate(src, normalized, page)
    if #normalized > 16 then return {}, 0 end
    local row = M.vehicleRow(normalized)
    if not row then return {}, 0 end
    if page > 1 then return {}, 1 end
    local owner = C.str(row.citizenid)
    return { {
        kind = 'vehicle',
        plate = C.str(row.plate) or normalized,
        model = C.str(row.model),
        ownerName = owner and C.fullName(row.firstname, row.lastname) or nil,
        ownerCitizenid = C.citizenid(owner),
        bolo = C.boloFlag(src, 'vehicle', C.str(row.plate) or normalized, C.boloRunning()),
    } }, 1
end

local function searchCase(src, normalized, page)
    if utf8.len(normalized) > 32 then return {}, 0 end
    local rows = MySQL.query.await('SELECT ' .. Refs.CASE_COLS .. ' FROM fredpd_cases c WHERE c.case_number = ?',
        { normalized })
    if type(rows) ~= 'table' then error('case search query failed', 0) end
    local refs = Refs.evaluate(src, Refs.fromRows(rows))
    if page > 1 then return {}, #refs end
    local hits = {}
    for i, ref in ipairs(refs) do hits[i] = { kind = 'case', case = ref } end
    return hits, #hits
end

---------------------------------------------------------------------------------------------------------------
-- Export

--- SearchInput -> query, type, page (defaults applied), or nil when invalid.
function M.validate(input)
    if type(input) ~= 'table' then return nil end
    local query = C.text(input.query, 2, 64)
    if not query then return nil end
    local kind = input.type
    if kind == nil then kind = 'auto' end
    if not M.TYPES[kind] then return nil end
    local page = C.optInt(input.page, 1, M.MAX_PAGE, 1)
    if not page then return nil end
    return query, kind, page
end

--- detected + normalized for the requested type ('auto' = detectSearchType).
function M.classify(query, kind)
    local detected = Format.detectSearchType(query, formats)
    if kind == 'auto' then return detected.type, detected.normalized end
    if kind == 'vehicle' then return 'plate', (query:gsub('%s', ''):upper()) end
    if kind == 'case' then return 'caseNumber', query:upper() end
    -- person: a personnummer-shaped query searches personnummer, anything else is a name
    if detected.type == 'personId' then return 'personId', detected.normalized end
    return 'name', (query:gsub('%s+', ' '))
end

local SEARCHERS = { name = searchName, personId = searchPersonId, plate = searchPlate, caseNumber = searchCase }

--- Audit meta: what was asked and which records were shown (ids of the hits on this page).
local function auditMeta(query, kind, page, total, hits)
    local ids = {}
    for i, h in ipairs(hits) do
        ids[i] = h.citizenid or h.plate or (h.case and h.case.id) or 'notice'
    end
    return { query = query, type = kind, page = page, total = total, hits = ids }
end

--- export search(src, input) -> { ok = true, data = SearchOutput } | { ok = false, error = code }
function M.search(src, input)
    src = C.playerSrc(src)
    if not src then return C.fail('unauthorized') end
    local query, kind, page = M.validate(input)
    if not query then return C.fail('validation') end
    if not C.hasGrant(src, 'mdt_page', 'search') then return C.fail('unauthorized') end
    if not M.loadFormats() then return C.fail('unavailable') end

    local detected, normalized = M.classify(query, kind)
    local hits, total = SEARCHERS[detected](src, normalized, page)
    C.audit(src, 'search', detected, C.cutBytes(normalized, 64), auditMeta(query, kind, page, total, hits))
    return C.ok({ detected = detected, normalized = normalized, hits = hits, total = total, page = page })
end

return M
