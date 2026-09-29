-- SPDX-License-Identifier: GPL-3.0-only
-- Minimal backtracking regex engine for the patterns in config/formats.json (docs/contracts.md §C4).
--
-- Lua patterns cannot express `\d{6,8}-?\d{4}`, so the Lua side of the formats contract needs its own engine.
-- Supported (JavaScript semantics, no flags): `^ $ .`, character classes `[...]` / `[^...]` with ranges,
-- `\d \D \s \S \w \W`, control escapes `\t \n \v \f \r`, escaped punctuation (`\. \- \/ \( ...`) and the
-- quantifiers `? * + {n} {n,} {n,m}` on single-character atoms.
-- Everything else (groups, alternation, lazy quantifiers, backreferences, `\b`, lookaround, a bare `{`) is a
-- compile error, so a config that the Lua port cannot run fails loudly at start instead of matching wrongly.
-- packages/types/src/format.ts (assertRegexSubset / compileFormatRegex) accepts exactly the same subset and
-- rewrites `\s`, `\S` and `.` so the native RegExp has these same ASCII semantics.
--
-- Semantics are ASCII-only: `\s` is space, \t \n \v \f \r (not NBSP or other Unicode spaces) and `.` excludes only
-- \n and \r. Matching works on bytes: non-ASCII characters are allowed as plain literals outside classes only, and
-- `.` or negated classes consume one byte of a multi-byte UTF-8 character (JS consumes one UTF-16 unit).
-- Errors are raised as the string "invalid_regex: <detail>" (level 0, no position prefix).
--
-- Usage: local re = Regex.compile('^\\d{6,8}-?\\d{4}$'); re:test('19900101-1234') --> true

local M = {}

local MAX_REPEAT = 1000 -- upper bound for {n,m} counts; keeps a typo like {99999} from exhausting memory

local function fail(pattern, detail)
    error(('invalid_regex: %s in /%s/'):format(detail, pattern), 0)
end

local function isDigit(b) return b >= 48 and b <= 57 end
local function isSpace(b) return b == 32 or (b >= 9 and b <= 13) end -- space \t \n \v \f \r
local function isWord(b)
    return isDigit(b) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95
end
local function isAlnum(b)
    return isDigit(b) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
end

-- `\d` and friends: a predicate plus a negation flag.
local CLASS_ESCAPES = {
    d = { fn = isDigit, negate = false }, D = { fn = isDigit, negate = true },
    s = { fn = isSpace, negate = false }, S = { fn = isSpace, negate = true },
    w = { fn = isWord, negate = false }, W = { fn = isWord, negate = true },
}
local CONTROL_ESCAPES = { t = 9, n = 10, v = 11, f = 12, r = 13 }

--- Parse one atom inside or outside a class starting at `i`.
--- Returns item ({ byte = b } or { pred = CLASS_ESCAPES[x] }) and the index after it.
local function parseAtom(pattern, i, inClass)
    local b = pattern:byte(i)
    if b ~= 92 then -- not a backslash
        if b >= 128 and inClass then fail(pattern, 'non-ASCII character inside a class') end
        return { byte = b }, i + 1
    end
    local e = pattern:sub(i + 1, i + 1)
    if e == '' then fail(pattern, 'trailing backslash') end
    if CLASS_ESCAPES[e] then return { pred = CLASS_ESCAPES[e] }, i + 2 end
    if CONTROL_ESCAPES[e] then return { byte = CONTROL_ESCAPES[e] }, i + 2 end
    local eb = e:byte()
    if isAlnum(eb) then fail(pattern, ('unsupported escape \\%s'):format(e)) end
    if eb >= 128 then fail(pattern, 'escaped non-ASCII character') end
    return { byte = eb }, i + 2 -- escaped punctuation is a literal
end

--- Parse a bracket class; `i` points just after '['. Returns the set node and the index after ']'.
local function parseClass(pattern, i)
    local node = { kind = 'set', ranges = {}, preds = {}, negate = false }
    local n = #pattern
    if pattern:sub(i, i) == '^' then
        node.negate = true
        i = i + 1
    end
    local function add(item)
        if item.pred then
            node.preds[#node.preds + 1] = item.pred
        else
            node.ranges[#node.ranges + 1] = { item.byte, item.byte }
        end
    end
    local closed = false
    while i <= n do
        if pattern:sub(i, i) == ']' then
            closed = true
            i = i + 1
            break
        end
        local item
        item, i = parseAtom(pattern, i, true)
        -- A '-' between two atoms makes a range, unless it is last before ']'.
        if pattern:sub(i, i) == '-' and i + 1 <= n and pattern:sub(i + 1, i + 1) ~= ']' then
            local hi, after = parseAtom(pattern, i + 1, true)
            if item.byte and hi.byte then
                if hi.byte < item.byte then fail(pattern, 'range out of order in class') end
                node.ranges[#node.ranges + 1] = { item.byte, hi.byte }
            else
                -- JS (Annex B): a class escape next to '-' makes the '-' literal, e.g. [\d-z] = \d, '-', 'z'.
                add(item)
                add({ byte = 45 })
                add(hi)
            end
            i = after
        else
            add(item)
        end
    end
    if not closed then fail(pattern, 'unterminated character class') end
    return node, i
end

--- Parse a quantifier at `i`. Returns min, max (nil = unbounded) and the next index, or nil when none.
local function parseQuantifier(pattern, i)
    local c = pattern:sub(i, i)
    if c == '*' then return 0, nil, i + 1 end
    if c == '+' then return 1, nil, i + 1 end
    if c == '?' then return 0, 1, i + 1 end
    if c ~= '{' then return nil end
    local lo, comma, hi, after = pattern:match('^{(%d+)(,?)(%d*)}()', i)
    if not lo then fail(pattern, 'invalid quantifier (escape a literal "{" as "\\{")') end
    local minC = tonumber(lo)
    local maxC
    if comma == '' then
        maxC = minC
    elseif hi ~= '' then
        maxC = tonumber(hi)
    end
    if minC > MAX_REPEAT or (maxC and maxC > MAX_REPEAT) then fail(pattern, 'repeat count too large') end
    if maxC and maxC < minC then fail(pattern, 'numbers out of order in {} quantifier') end
    return minC, maxC, after
end

local function parse(pattern)
    local nodes = {}
    local i, n = 1, #pattern
    while i <= n do
        local c = pattern:sub(i, i)
        local node
        if c == '^' then
            node, i = { kind = 'bol' }, i + 1
        elseif c == '$' then
            node, i = { kind = 'eol' }, i + 1
        elseif c == '.' then
            node, i = { kind = 'any' }, i + 1
        elseif c == '[' then
            node, i = parseClass(pattern, i + 1)
        elseif c == '(' or c == ')' or c == '|' then
            fail(pattern, 'groups and alternation are not supported')
        elseif c == '*' or c == '+' or c == '?' then
            local prev = nodes[#nodes]
            if c == '?' and prev and prev.quantified then fail(pattern, 'lazy quantifiers are not supported') end
            fail(pattern, 'nothing to repeat')
        elseif c == '{' then
            fail(pattern, 'nothing to repeat (escape a literal "{" as "\\{")')
        else
            local item
            item, i = parseAtom(pattern, i, false)
            if item.pred then
                node = { kind = 'set', ranges = {}, preds = { item.pred }, negate = false }
            else
                node = { kind = 'char', byte = item.byte }
            end
        end

        local minC, maxC, after = parseQuantifier(pattern, i)
        if minC then
            if node.kind == 'bol' or node.kind == 'eol' then fail(pattern, 'nothing to repeat') end
            if node.kind == 'char' and node.byte >= 128 then
                fail(pattern, 'quantifier after a non-ASCII character')
            end
            node.min, node.max, node.quantified = minC, maxC, true
            i = after
        else
            node.min, node.max = 1, 1
        end
        nodes[#nodes + 1] = node
    end
    return nodes
end

local function byteMatches(node, b)
    local kind = node.kind
    if kind == 'char' then return b == node.byte end
    if kind == 'any' then return b ~= 10 and b ~= 13 end -- JS '.' excludes line terminators
    local hit = false
    for _, r in ipairs(node.ranges) do
        if b >= r[1] and b <= r[2] then
            hit = true
            break
        end
    end
    if not hit then
        for _, p in ipairs(node.preds) do
            if p.fn(b) ~= p.negate then
                hit = true
                break
            end
        end
    end
    return hit ~= node.negate
end

--- Does nodes[idx..] match s starting at byte `pos`? Greedy with backtracking.
--- Every atom is a single byte, so (idx, pos) fully determines the outcome; failures are memoised, which bounds
--- the work to O(#nodes * #s^2) even for patterns like \d*\d*\d*x.
local function matchFrom(nodes, idx, s, pos, len, memo)
    local node = nodes[idx]
    if node == nil then return true end
    local key = idx * (len + 2) + pos
    if memo[key] then return false end

    local ok = false
    if node.kind == 'bol' then
        ok = pos == 1 and matchFrom(nodes, idx + 1, s, pos, len, memo)
    elseif node.kind == 'eol' then
        ok = pos == len + 1 and matchFrom(nodes, idx + 1, s, pos, len, memo)
    else
        local limit = len - pos + 1
        if node.max and node.max < limit then limit = node.max end
        local count = 0
        for p = pos, pos + limit - 1 do
            if not byteMatches(node, s:byte(p)) then break end
            count = count + 1
        end
        if count >= node.min then
            for k = count, node.min, -1 do
                if matchFrom(nodes, idx + 1, s, pos + k, len, memo) then
                    ok = true
                    break
                end
            end
        end
    end

    if not ok then memo[key] = true end
    return ok
end

local Matcher = {}
Matcher.__index = Matcher

--- Like JavaScript RegExp.prototype.test without flags: true when the pattern matches anywhere in s.
function Matcher:test(s)
    if type(s) ~= 'string' then error('regex: test() expects a string', 2) end
    local len = #s
    local memo = {}
    local lastStart = self.anchored and 1 or len + 1
    for start = 1, lastStart do
        if matchFrom(self.nodes, 1, s, start, len, memo) then return true end
    end
    return false
end

--- Compile a pattern. Raises "invalid_regex: ..." for syntax outside the supported subset.
function M.compile(pattern)
    if type(pattern) ~= 'string' then error('invalid_regex: pattern must be a string', 0) end
    local nodes = parse(pattern)
    return setmetatable({
        source = pattern,
        nodes = nodes,
        anchored = nodes[1] ~= nil and nodes[1].kind == 'bol',
    }, Matcher)
end

return M
