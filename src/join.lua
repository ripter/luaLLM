-- join.lua
-- Merge multi-part GGUF files into a single file using llama-gguf-split --merge.
--
-- Multi-part GGUFs use the naming convention:
--   ModelName-00001-of-00003.gguf
--   ModelName-00002-of-00003.gguf
--   ModelName-00003-of-00003.gguf
--
-- llama-gguf-split --merge only needs the first part; it discovers the rest
-- itself.  The output file is named ModelName.gguf in the same directory.

local util   = require("util")
local lfs    = require("lfs")

local M = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Given a filename like "Foo-00001-of-00003.gguf", return:
--   base      = "Foo"        (the logical model name without the part suffix)
--   part      = 1
--   total     = 3
-- Returns nil if the filename does not match the multi-part pattern.
local function parse_multipart_name(filename)
    -- Strip .gguf extension first
    local stem = filename:match("^(.+)%.gguf$")
    if not stem then return nil end

    local base, part_str, total_str =
        stem:match("^(.+)%-(%d+)-of%-(%d+)$")
    if not base then return nil end

    return base, tonumber(part_str), tonumber(total_str)
end

-- Scan models_dir and return a list of multipart groups.
-- Each group is a table:
--   { base = "ModelName", total = 3, first_file = "ModelName-00001-of-00003.gguf",
--     dir = "/path/to/models" }
local function find_multipart_groups(models_dir)
    models_dir = util.expand_path(models_dir)
    local groups = {}   -- keyed by base name

    for file in lfs.dir(models_dir) do
        local base, part, total = parse_multipart_name(file)
        if base then
            if not groups[base] then
                groups[base] = { base = base, total = total,
                                 parts = {}, dir = models_dir }
            end
            groups[base].parts[part] = file
        end
    end

    -- Convert to a list, keeping only groups that have part 1
    local result = {}
    for _, g in pairs(groups) do
        if g.parts[1] then
            g.first_file = g.parts[1]
            table.insert(result, g)
        end
    end

    table.sort(result, function(a, b) return a.base < b.base end)
    return result
end

-- ---------------------------------------------------------------------------
-- Public command handler
-- ---------------------------------------------------------------------------

function M.handle_join_command(args, cfg)
    -- ── Locate llama-gguf-split ──────────────────────────────────────
    local split_path = util.resolve_gguf_split_path(cfg)
    if not split_path then
        print("Error: llama-gguf-split not found.")
        print("Add one of the following to your config:")
        print("  llama_gguf_split_path  — explicit path to llama-gguf-split")
        print("  llama_cpp_path         — path to llama-server (sibling binary used)")
        print("  llama_cpp_source_dir   — path to llama.cpp source (build/bin/ searched)")
        os.exit(1)
    end

    local models_dir = util.expand_path(cfg.models_dir)

    -- ── Find multipart groups ────────────────────────────────────────
    local groups = find_multipart_groups(models_dir)

    if #groups == 0 then
        print("No multi-part GGUF files found in: " .. models_dir)
        print()
        print("Multi-part files use names like:")
        print("  ModelName-00001-of-00003.gguf")
        print("  ModelName-00002-of-00003.gguf")
        print("  ModelName-00003-of-00003.gguf")
        os.exit(0)
    end

    -- ── Filter by user query if provided ────────────────────────────
    local query = args[2]
    local targets = {}

    if query then
        local query_lower = query:lower()
        for _, g in ipairs(groups) do
            if g.base:lower():find(query_lower, 1, true) then
                table.insert(targets, g)
            end
        end
        if #targets == 0 then
            print("No multi-part model matching: " .. query)
            print()
            print("Available multi-part models:")
            for _, g in ipairs(groups) do
                print(string.format("  %s  (%d parts)", g.base, g.total))
            end
            os.exit(1)
        end
    else
        targets = groups
    end

    -- ── If more than one target, show list and ask which ────────────
    local group
    if #targets == 1 then
        group = targets[1]
    else
        print("Multiple multi-part models found:")
        print()
        for i, g in ipairs(targets) do
            print(string.format("  [%d] %s  (%d parts)", i, g.base, g.total))
        end
        print()
        io.write("Enter number to join (or q to quit): ")
        io.flush()
        local input = io.read("*l")
        if not input or input:lower() == "q" then
            os.exit(0)
        end
        local choice = tonumber(input)
        if not choice or not targets[choice] then
            print("Invalid selection")
            os.exit(1)
        end
        group = targets[choice]
    end

    -- ── Confirm all parts are present ───────────────────────────────
    print(string.format("Joining: %s  (%d parts)", group.base, group.total))
    print()

    local missing = {}
    for i = 1, group.total do
        if not group.parts[i] then
            table.insert(missing, string.format("%s-%05d-of-%05d.gguf",
                group.base, i, group.total))
        end
    end

    if #missing > 0 then
        print("Error: missing parts:")
        for _, f in ipairs(missing) do
            print("  " .. f)
        end
        os.exit(1)
    end

    -- ── Print part list ──────────────────────────────────────────────
    for i = 1, group.total do
        print(string.format("  Part %d/%d: %s", i, group.total, group.parts[i]))
    end
    print()

    -- ── Determine output path ────────────────────────────────────────
    local output_file = group.base .. ".gguf"
    local output_path = group.dir .. "/" .. output_file

    if util.file_exists(output_path) then
        print("Warning: output file already exists: " .. output_file)
        io.write("Overwrite? [y/N]: ")
        io.flush()
        local answer = io.read("*l")
        if not answer or answer:lower() ~= "y" then
            print("Aborted.")
            os.exit(0)
        end
        print()
    end

    print("Output: " .. output_file)
    print()

    -- ── Run llama-gguf-split --merge ─────────────────────────────────
    local first_part_path = group.dir .. "/" .. group.first_file
    local cmd = util.sh_quote(split_path) ..
                " --merge " ..
                util.sh_quote(first_part_path) .. " " ..
                util.sh_quote(output_path) ..
                " 2>&1"

    print("Running: " .. cmd)
    print()

    local handle = io.popen(cmd)
    if not handle then
        print("Error: failed to launch llama-gguf-split")
        os.exit(1)
    end

    -- Stream output line by line so the user sees progress
    for line in handle:lines() do
        print(line)
    end

    local ok, why, code = handle:close()
    local exit_code = util.normalize_exit_code(ok, why, code)

    if exit_code ~= 0 then
        print()
        print(string.format("Error: llama-gguf-split exited with code %d", exit_code))
        os.exit(1)
    end

    print()
    print("✓ Joined successfully: " .. output_file)
    print()
    print("The part files can now be deleted if you no longer need them:")
    for i = 1, group.total do
        print("  rm " .. util.sh_quote(group.dir .. "/" .. group.parts[i]))
    end
end

return M
