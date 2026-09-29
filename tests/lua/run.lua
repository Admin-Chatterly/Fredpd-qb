-- FredPD Lua test runner. Runs outside FiveM with plain Lua 5.4.
-- Usage (from repo root): lua5.4 tests/lua/run.lua [filter]
-- Each tests/lua/*_test.lua file returns a table { [name] = function(t) ... end }.

package.path = table.concat({
    './tests/lua/?.lua',
    './tests/lua/vendor/?.lua',
    './resources/[fredpd]/fredpd_core/?.lua',
    './resources/[fredpd]/fredpd_core/?/init.lua',
    package.path,
}, ';')

json = require('json') -- FiveM provides a global `json`; mirror that here
local helper = require('helper')

local filter = arg[1]
local files = {}
local p = io.popen('ls tests/lua/*_test.lua 2>/dev/null')
if p then
    for line in p:lines() do files[#files + 1] = line end
    p:close()
end
table.sort(files)

local passed, failed = 0, 0
for _, file in ipairs(files) do
    if not filter or file:find(filter, 1, true) then
        local ok, suite = pcall(dofile, file)
        if not ok then
            failed = failed + 1
            print(('FAIL %s (load error)\n    %s'):format(file, tostring(suite)))
        else
            local names = {}
            for name in pairs(suite) do names[#names + 1] = name end
            table.sort(names)
            for _, name in ipairs(names) do
                local okc, err = pcall(suite[name], helper)
                if okc then
                    passed = passed + 1
                else
                    failed = failed + 1
                    print(('FAIL %s :: %s\n    %s'):format(file, name, tostring(err)))
                end
            end
        end
    end
end

print(('lua: %d passed, %d failed'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
