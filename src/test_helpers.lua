-- test_helpers.lua
-- Shared utilities for *.test.lua files.  Not a test itself (no .test. in the
-- name) so the runner skips it.  Loaded via plain require("test_helpers").

local M = {}

-- ---------------------------------------------------------------------------
-- assertions
-- ---------------------------------------------------------------------------

-- Strict equality.  Formats values with %q when they are strings so that
-- whitespace / special chars are visible in the error message.
function M.assert_eq(got, want, msg)
    if got ~= want then
        local fmt_got  = type(got)  == "string" and string.format("%q", got)  or tostring(got)
        local fmt_want = type(want) == "string" and string.format("%q", want) or tostring(want)
        error(string.format("%s\n  got:  %s\n  want: %s",
              msg or "assertion failed", fmt_got, fmt_want), 2)
    end
end

-- Substring membership.  Both arguments must be strings.
function M.assert_contains(haystack, needle, msg)
    if not haystack:find(needle, 1, true) then
        error(msg or ("expected to find '" .. needle .. "' in: " .. haystack), 2)
    end
end

-- ---------------------------------------------------------------------------
-- module stubbing
-- ---------------------------------------------------------------------------

-- Run *fn* with a set of module stubs installed, then restore the originals
-- no matter what.  *stubs* is a plain table mapping module name → stub value.
-- Any key whose value is the special sentinel M.REMOVE will have its entry
-- deleted from package.loaded (equivalent to stubbing with nil, which is
-- otherwise impossible to distinguish from "not in the table").
--
-- Usage:
--   with_stubs({
--       util       = { expand_path = function(p) return p end },
--       history    = { load_history = function() return {} end },
--       format     = M.REMOVE,   -- force re-require
--   }, function()
--       -- test body; require("format") will re-evaluate against the stubs
--   end)
--
-- If fn throws, the error is re-raised *after* restore so the test runner
-- still sees the failure.
M.REMOVE = setmetatable({}, { __tostring = function() return "<REMOVE>" end })

function M.with_stubs(stubs, fn)
    -- 1. snapshot
    local saved = {}
    for name in pairs(stubs) do
        saved[name] = package.loaded[name]   -- may be nil; that is fine
    end

    -- 2. install
    for name, stub in pairs(stubs) do
        if stub == M.REMOVE then
            package.loaded[name] = nil
        else
            package.loaded[name] = stub
        end
    end

    -- 3. run + unconditional restore
    local ok, err = pcall(fn)

    for name in pairs(stubs) do
        package.loaded[name] = saved[name]   -- nil restores correctly here too
    end

    if not ok then error(err, 2) end
end

-- ---------------------------------------------------------------------------
-- output capture
-- ---------------------------------------------------------------------------

-- Run *fn* (no arguments) and return a table of every string that was passed
-- to print() during its execution.  Each element is the single-call output
-- joined by spaces, exactly as print() would concatenate its arguments.
-- _G.print is restored unconditionally afterward.
function M.capture_print(fn)
    local lines = {}
    local old_print = _G.print

    _G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[#parts + 1] = tostring(select(i, ...))
        end
        lines[#lines + 1] = table.concat(parts, "\t")
    end

    local ok, err = pcall(fn)
    _G.print = old_print          -- always restore

    if not ok then error(err, 2) end
    return lines
end

return M
