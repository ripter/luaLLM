-- notes.test.lua — unit tests for src/notes.lua
--
-- notes.lua does real io.open read/write for note files, so we use a genuine
-- temp directory.  Everything else (config paths, resolve, format, picker)
-- is stubbed.  The temp dir is cleaned up at the end of each test block.

local T = require("test_helpers")
local lfs = require("lfs")

-- ---------------------------------------------------------------------------
-- temp-dir helpers
-- ---------------------------------------------------------------------------

local function mkdtemp()
    -- os.tmpname() gives a unique file; remove it and mkdir in its place.
    local tmp = os.tmpname()
    os.remove(tmp)
    os.execute("mkdir -p " .. tmp)
    return tmp
end

local function rmtree(dir)
    os.execute("rm -rf " .. dir)
end

-- ---------------------------------------------------------------------------
-- os.exit stub: throws a structured table so the test can catch it with pcall
-- without the process actually exiting.
-- ---------------------------------------------------------------------------
local function make_exit_stub()
    local exits = {}                        -- record of every exit call
    local stub  = function(code)
        code = code == true and 0 or (code == false and 1 or (tonumber(code) or 0))
        table.insert(exits, code)
        error({ __exit = true, code = code })
    end
    return stub, exits
end

-- ---------------------------------------------------------------------------
-- Stub set builder.  notes.lua requires: lfs, util, config, format, resolver,
-- picker.  We keep lfs *real* (temp dir has real files) and stub the rest.
-- ---------------------------------------------------------------------------
local function make_notes_stubs(notes_dir, resolver_stub)
    return {
        config  = { CONFIG_DIR = notes_dir },   -- NOTES_DIR = CONFIG_DIR .. "/notes"
        util    = {
            file_exists = function(path)
                local f = io.open(path, "r")
                if f then f:close(); return true end
                return false
            end,
            is_dir = function(path)
                local attr = lfs.attributes(path)
                return attr and attr.mode == "directory"
            end,
            ensure_dir = function(dir)
                os.execute("mkdir -p " .. dir)
            end,
            sh_quote = function(s)
                return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
            end,
            safe_filename = function(name)
                -- Simple stub that just returns the name for testing
                return name
            end,
        },
        resolver = resolver_stub,
        format  = {
            get_model_row = function(_, name)
                return name, "0B", "Q0", "never"
            end,
            calculate_column_widths = function(data)
                local mn, ms, mq = 0, 0, 0
                for _, row in ipairs(data) do
                    if #row.name      > mn then mn = #row.name      end
                    if #row.size_str  > ms then ms = #row.size_str  end
                    if #row.quant     > mq then mq = #row.quant     end
                end
                return mn, ms, mq
            end,
            format_model_row = function(row)
                return row.name
            end,
        },
        picker  = { show_picker = function() return nil end },
        notes   = T.REMOVE,         -- force re-require so NOTES_DIR is recomputed
    }
end

-- ---------------------------------------------------------------------------
-- tests
-- ---------------------------------------------------------------------------
return { run = function()

    -- ── 1. notes add: creates file, appends note under ## Notes ─────────
    do
        local tmp = mkdtemp()

        -- resolver stub: resolve_or_exit returns the query directly
        local resolver_stub = {
            resolve_or_exit = function(cfg, query, opts)
                return query  -- just return what was queried
            end
        }

        local notes
        T.with_stubs(make_notes_stubs(tmp, resolver_stub), function()
            notes = require("notes")
        end)

        -- simulate: luallm notes add mymodel hello world
        local printed = T.capture_print(function()
            notes.handle_notes_command({"notes", "add", "mymodel", "hello", "world"}, { models_dir = tmp })
        end)

        -- confirm "Note added" was printed
        local found_added = false
        for _, line in ipairs(printed) do
            if line:find("Note added") then found_added = true end
        end
        T.assert_eq(found_added, true, "notes add prints 'Note added'")

        -- read the file and verify structure
        local notes_path = tmp .. "/notes/mymodel.md"
        local f = io.open(notes_path, "r")
        T.assert_eq(f ~= nil, true, "notes file was created")
        local content = f:read("*all")
        f:close()

        T.assert_contains(content, "# mymodel",     "file starts with model header")
        T.assert_contains(content, "## Notes",      "file has Notes section")
        T.assert_contains(content, "hello world",   "appended text is present")
        T.assert_contains(content, "## Summary",    "Summary section preserved")

        rmtree(tmp)
    end

    -- ── 2. notes add: second note appends without overwriting ───────────
    do
        local tmp = mkdtemp()
        local resolver_stub = {
            resolve_or_exit = function(cfg, query, opts) return query end
        }

        local notes
        T.with_stubs(make_notes_stubs(tmp, resolver_stub), function()
            notes = require("notes")
        end)

        T.capture_print(function()
            notes.handle_notes_command({"notes", "add", "m1", "first note"}, {})
        end)
        T.capture_print(function()
            notes.handle_notes_command({"notes", "add", "m1", "second note"}, {})
        end)

        local f = io.open(tmp .. "/notes/m1.md", "r")
        local content = f:read("*all")
        f:close()

        T.assert_contains(content, "first note",  "first note still present")
        T.assert_contains(content, "second note", "second note also present")

        rmtree(tmp)
    end

    -- ── 3. notes list: prints both model names when two notes exist ─────
    do
        local tmp = mkdtemp()
        os.execute("mkdir -p " .. tmp .. "/notes")

        -- Pre-create two note files directly
        local f1 = io.open(tmp .. "/notes/AlphaModel.md", "w")
        f1:write("# AlphaModel\n\n## Notes\n\n## Summary\n")
        f1:close()

        local f2 = io.open(tmp .. "/notes/BetaModel.md", "w")
        f2:write("# BetaModel\n\n## Notes\n\n## Summary\n")
        f2:close()

        local resolver_stub = {
            resolve_or_exit = function(cfg, query, opts) return query end
        }

        local notes
        T.with_stubs(make_notes_stubs(tmp, resolver_stub), function()
            notes = require("notes")
        end)

        local printed = T.capture_print(function()
            notes.handle_notes_command({"notes", "list"}, {})
        end)

        -- join all printed lines to search
        local all_output = table.concat(printed, "\n")
        T.assert_contains(all_output, "AlphaModel", "list output contains AlphaModel")
        T.assert_contains(all_output, "BetaModel",  "list output contains BetaModel")

        rmtree(tmp)
    end

    -- ── 4. notes add with missing text → exits non-zero ─────────────────
    do
        local tmp = mkdtemp()
        local resolver_stub = {
            resolve_or_exit = function(cfg, query, opts) return query end
        }

        local exit_stub, exits = make_exit_stub()
        local old_exit = os.exit
        os.exit = exit_stub

        local notes
        T.with_stubs(make_notes_stubs(tmp, resolver_stub), function()
            notes = require("notes")
        end)

        -- args: {"notes", "add", "mymodel"} — no text parts (need >= 4 args)
        local ok, err = pcall(function()
            T.capture_print(function()
                notes.handle_notes_command({"notes", "add", "mymodel"}, {})
            end)
        end)

        os.exit = old_exit

        -- The exit stub threw; pcall caught it.
        T.assert_eq(ok, false, "os.exit was called (pcall caught the throw)")
        -- The exit table was populated
        T.assert_eq(#exits > 0, true, "at least one exit recorded")
        T.assert_eq(exits[1], 1,      "exit code is 1 (error)")

        rmtree(tmp)
    end

    -- ── 5. notes list with no notes → prints "no notes" message ─────────
    do
        local tmp = mkdtemp()
        -- notes dir exists but is empty
        os.execute("mkdir -p " .. tmp .. "/notes")

        local resolver_stub = {
            resolve_or_exit = function(cfg, query, opts) return query end
        }

        local exit_stub, exits = make_exit_stub()
        local old_exit = os.exit
        os.exit = exit_stub

        local notes
        T.with_stubs(make_notes_stubs(tmp, resolver_stub), function()
            notes = require("notes")
        end)

        -- list calls os.exit(0) when empty; capture_print will propagate the
        -- throw from exit_stub, so wrap in pcall
        local printed = {}
        local ok = pcall(function()
            printed = T.capture_print(function()
                notes.handle_notes_command({"notes", "list"}, {})
            end)
        end)

        os.exit = old_exit

        -- Either we got the print before exit, or the exit fired first.
        -- Either way, check exit code is 0.
        T.assert_eq(exits[1], 0, "empty list exits 0")

        rmtree(tmp)
    end

end }
