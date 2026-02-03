-- test_runner.lua
-- Discovers and executes all src/*.test.lua files.
-- Contract for each test file:  return a table { run = function() ... end }
--                            OR return function() ... end
-- Failure = error(). Success = no error.

local lfs = require("lfs")

local M = {}

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

-- Extract the first line of a (possibly multi-line) string.
local function first_line(s)
    return (tostring(s):match("^([^\n]+)"))
end

-- ---------------------------------------------------------------------------
-- discovery
-- ---------------------------------------------------------------------------

-- Return a sorted list of *.test.lua filenames found in src_dir.
local function discover(src_dir)
    local files = {}
    for entry in lfs.dir(src_dir) do
        if entry:match("^.+%.test%.lua$") then
            table.insert(files, entry)
        end
    end
    table.sort(files)          -- deterministic order
    return files
end

-- ---------------------------------------------------------------------------
-- runner
-- ---------------------------------------------------------------------------

-- src_dir: absolute path to the src/ directory (already on package.path).
function M.run_all(src_dir)
    local test_files = discover(src_dir)

    print("luaLLM Test Runner")
    print(string.rep("─", 60))

    if #test_files == 0 then
        print()
        print("No test files found (looking for *.test.lua in src/)")
        os.exit(0)
    end

    local results = {}          -- { name, passed, short_err, full_err }

    for _, filename in ipairs(test_files) do
        local filepath = src_dir .. "/" .. filename
        local display  = filename

        -- load the file; if dofile itself fails (syntax error etc.) that's a FAIL.
        local ok, mod = pcall(dofile, filepath)
        if not ok then
            table.insert(results, {
                name       = display,
                passed     = false,
                short_err  = first_line(mod),
                full_err   = tostring(mod)
            })
            print("FAIL  " .. display .. "  " .. first_line(mod))
        else
            -- Normalise: accept a bare function OR a table with .run()
            local run_fn
            if type(mod) == "function" then
                run_fn = mod
            elseif type(mod) == "table" and type(mod.run) == "function" then
                run_fn = mod.run
            else
                -- Neither recognised form — that's a test-file bug.
                local msg = "test file must return a function or a table with run()"
                table.insert(results, {
                    name       = display,
                    passed     = false,
                    short_err  = msg,
                    full_err   = msg
                })
                print("FAIL  " .. display .. "  " .. msg)
            end

            if run_fn then
                local run_ok, run_err = pcall(run_fn)
                if run_ok then
                    table.insert(results, { name = display, passed = true })
                    print("PASS  " .. display)
                else
                    table.insert(results, {
                        name       = display,
                        passed     = false,
                        short_err  = first_line(run_err),
                        full_err   = tostring(run_err)
                    })
                    print("FAIL  " .. display .. "  " .. first_line(run_err))
                end
            end
        end
    end

    -- -------------------------------------------------------------------
    -- summary
    -- -------------------------------------------------------------------
    local passed, failed = 0, 0
    local failures = {}
    for _, r in ipairs(results) do
        if r.passed then
            passed = passed + 1
        else
            failed = failed + 1
            table.insert(failures, r)
        end
    end

    print()                                               -- blank line before summary
    print(string.rep("─", 60))
    print(string.format("Results: %d total, %d passed, %d failed",
                        #results, passed, failed))

    if #failures > 0 then
        print()
        print("Failures:")
        for _, f in ipairs(failures) do
            print()
            print("  " .. f.name)
            -- indent every line of the full error by four spaces
            for line in f.full_err:gmatch("[^\n]+") do
                print("    " .. line)
            end
        end
        print()
        os.exit(1)
    end

    os.exit(0)
end

return M
