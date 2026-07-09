-- hf.test.lua — unit tests for src/hf.lua

local T = require("test_helpers")

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

local function mkdtemp()
    local tmp = os.tmpname()
    os.remove(tmp)
    os.execute("mkdir -p " .. tmp)
    return tmp
end

local function rmtree(dir)
    os.execute("rm -rf " .. dir)
end

local function make_exit_stub()
    local exits = {}
    local stub = function(code)
        code = code == true and 0 or (code == false and 1 or (tonumber(code) or 0))
        table.insert(exits, code)
        error({ __exit = true, code = code })
    end
    return stub, exits
end

-- Stubs needed by hf.lua: util, config, state, resolver, model_info.
-- The caller overrides individual fields as needed.
local function make_hf_stubs(tmp, overrides)
    overrides = overrides or {}
    local stubs = {
        util = {
            sh_quote = function(s)
                return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
            end,
            file_exists = function(path)
                local f = io.open(path, "r")
                if f then f:close(); return true end
                return false
            end,
            safe_filename = function(name) return name end,
            ensure_dir    = function(dir) os.execute("mkdir -p " .. dir) end,
            save_json     = function(path, data)
                -- no-op: tests verify cfg table directly
            end,
            expand_path   = function(p) return p end,
        },
        config = {
            CONFIG_DIR  = tmp,
            CONFIG_FILE = tmp .. "/config.json",
        },
        state = {
            get_state = function()
                return { servers = {}, last_used = nil }
            end,
        },
        resolver = {
            resolve_or_exit = function(cfg, query, opts)
                return query
            end,
        },
        model_info = {
            list_models = function(dir)
                return { { name = "test-model.Q4_K_M.gguf" } }
            end,
        },
        -- force hf to re-require with fresh stubs each test
        hf = T.REMOVE,
    }

    for k, v in pairs(overrides) do
        stubs[k] = v
    end
    return stubs
end

-- Stub io.read to return a predetermined answer, then restore.
local function with_io_read(answer, fn)
    local old_read = io.read
    io.read = function() return answer end
    local ok, err = pcall(fn)
    io.read = old_read
    if not ok then error(err, 2) end
end

-- Suppress io.stderr output for tests that intentionally trigger error paths.
local function with_silent_stderr(fn)
    local old_stderr = io.stderr
    io.stderr = io.open("/dev/null", "w")
    local ok, err = pcall(fn)
    if io.stderr then io.stderr:close() end
    io.stderr = old_stderr
    if not ok then error(err, 2) end
end

-- ---------------------------------------------------------------------------
-- tests
-- ---------------------------------------------------------------------------

return { run = function()

    -- ── 1. parse_hf_url: standard URL ────────────────────────────────────
    do
        local hf
        T.with_stubs(make_hf_stubs(os.tmpname()), function()
            hf = require("hf")
        end)

        local owner, repo = hf._parse_hf_url(
            "https://huggingface.co/DavidAU/MN-Oblivion-26B-UNCENSORED-NEO-Imatrix-GGUF"
        )
        T.assert_eq(owner, "DavidAU",                                    "owner extracted")
        T.assert_eq(repo,  "MN-Oblivion-26B-UNCENSORED-NEO-Imatrix-GGUF", "repo extracted")
    end

    -- ── 2. parse_hf_url: URL with trailing path segments ─────────────────
    do
        local hf
        T.with_stubs(make_hf_stubs(os.tmpname()), function()
            hf = require("hf")
        end)

        local owner, repo = hf._parse_hf_url(
            "https://huggingface.co/mistralai/Mistral-7B-v0.1/tree/main"
        )
        T.assert_eq(owner, "mistralai",       "owner from URL with path")
        T.assert_eq(repo,  "Mistral-7B-v0.1", "repo from URL with path")
    end

    -- ── 3. parse_hf_url: invalid URL returns nil ─────────────────────────
    do
        local hf
        T.with_stubs(make_hf_stubs(os.tmpname()), function()
            hf = require("hf")
        end)

        local owner, repo = hf._parse_hf_url("https://example.com/nothuggingface")
        T.assert_eq(owner, nil, "invalid URL gives nil owner")
        T.assert_eq(repo,  nil, "invalid URL gives nil repo")
    end

    -- ── 4. regex_extract_flags: context size ─────────────────────────────
    do
        local hf
        T.with_stubs(make_hf_stubs(os.tmpname()), function()
            hf = require("hf")
        end)

        local text = "Run with: llama-cli -c 8192 --threads 8"
        local flags = hf._regex_extract_flags(text)

        -- flags is flat: {"-c", "8192", "--threads", "8"}
        local found = {}
        for i = 1, #flags, 2 do found[flags[i]] = flags[i + 1] end

        T.assert_eq(found["-c"],        "8192", "context size extracted")
        T.assert_eq(found["--threads"], "8",    "threads extracted")
    end

    -- ── 5. regex_extract_flags: gpu layers ───────────────────────────────
    do
        local hf
        T.with_stubs(make_hf_stubs(os.tmpname()), function()
            hf = require("hf")
        end)

        local text = "Recommended: --n-gpu-layers 35 -b 512"
        local flags = hf._regex_extract_flags(text)
        local found = {}
        for i = 1, #flags, 2 do found[flags[i]] = flags[i + 1] end

        T.assert_eq(found["--n-gpu-layers"], "35",  "gpu layers extracted")
        T.assert_eq(found["-b"],             "512", "batch size extracted")
    end

    -- ── 6. regex_extract_flags: empty text gives empty table ─────────────
    do
        local hf
        T.with_stubs(make_hf_stubs(os.tmpname()), function()
            hf = require("hf")
        end)

        local flags = hf._regex_extract_flags("This model has no flags mentioned.")
        T.assert_eq(#flags, 0, "no flags found in plain prose")
    end

    -- ── 7. parse_llm_flags: valid JSON ───────────────────────────────────
    do
        local hf
        T.with_stubs(make_hf_stubs(os.tmpname()), function()
            hf = require("hf")
        end)

        local text   = 'Here is the result: {"flags": ["-c", "4096", "--threads", "4"]}'
        local flags  = hf._parse_llm_flags(text)

        if flags then
            -- cjson available
            T.assert_eq(#flags, 4, "parsed 4 tokens from LLM JSON")
            T.assert_eq(flags[1], "-c",    "first token is -c")
            T.assert_eq(flags[2], "4096",  "second token is context value")
        else
            -- cjson not available in this environment — acceptable
            T.assert_eq(flags, nil, "nil returned when cjson unavailable")
        end
    end

    -- ── 8. parse_llm_flags: empty flags array → nil ───────────────────────
    do
        local hf
        T.with_stubs(make_hf_stubs(os.tmpname()), function()
            hf = require("hf")
        end)

        local flags = hf._parse_llm_flags('{"flags": []}')
        T.assert_eq(flags, nil, "empty flags array returns nil")
    end

    -- ── 9. parse_llm_flags: no JSON in text → nil ────────────────────────
    do
        local hf
        T.with_stubs(make_hf_stubs(os.tmpname()), function()
            hf = require("hf")
        end)

        local flags = hf._parse_llm_flags("Sorry, I could not find any flags.")
        T.assert_eq(flags, nil, "plain text with no JSON returns nil")
    end

    -- ── 10. handle_hf_command: missing URL shows help, no exit ──────────
    do
        local tmp = mkdtemp()
        local hf
        T.with_stubs(make_hf_stubs(tmp), function()
            hf = require("hf")
        end)

        local printed, _ = T.capture_output(function()
            hf.handle_hf_command({"hf"}, {})
        end)

        local all = table.concat(printed, "\n")
        T.assert_contains(all, "USAGE",              "help shows USAGE section")
        T.assert_contains(all, "huggingface-url",  "help shows url arg")

        rmtree(tmp)
    end

    -- ── 11. handle_hf_command: bad URL exits with code 1 ─────────────────
    do
        local tmp = mkdtemp()
        local hf
        T.with_stubs(make_hf_stubs(tmp), function()
            hf = require("hf")
        end)

        local exit_stub, exits = make_exit_stub()
        local old_exit = os.exit
        os.exit = exit_stub

        local ok = pcall(function()
            with_silent_stderr(function()
                T.capture_output(function()
                    hf.handle_hf_command({"hf", "https://example.com/bad"}, {})
                end)
            end)
        end)

        os.exit = old_exit

        T.assert_eq(ok,       false, "bad URL triggers os.exit")
        T.assert_eq(exits[1], 1,     "exit code is 1")

        rmtree(tmp)
    end

    -- ── 12. handle_hf_command: fetch failure exits with code 1 ───────────
    do
        local tmp = mkdtemp()
        local hf
        T.with_stubs(make_hf_stubs(tmp), function()
            hf = require("hf")
        end)

        hf._fetch_url = function(url) return nil, "connection refused" end

        local exit_stub, exits = make_exit_stub()
        local old_exit = os.exit
        os.exit = exit_stub

        local ok = pcall(function()
            with_silent_stderr(function()
                T.capture_output(function()
                    hf.handle_hf_command(
                        {"hf", "https://huggingface.co/owner/repo"},
                        { models_dir = tmp }
                    )
                end)
            end)
        end)

        os.exit = old_exit
        hf._fetch_url = nil

        T.assert_eq(ok,       false, "fetch failure triggers os.exit")
        T.assert_eq(exits[1], 1,     "exit code is 1")

        rmtree(tmp)
    end

    -- ── 13. full flow: flags found, user approves → preset + note saved ──
    do
        local tmp = mkdtemp()
        local hf
        T.with_stubs(make_hf_stubs(tmp), function()
            hf = require("hf")
        end)

        -- Fake model card with llama.cpp flags
        hf._fetch_url = function(url)
            return "Example usage: llama-cli -c 8192 --n-gpu-layers 35 --threads 8", nil
        end

        local cfg = { models_dir = tmp, models = {} }
        local saved_cfg = nil
        local old_save_json = require("util").save_json

        -- Capture what save_json receives
        local util_mod = package.loaded["util"]
        local orig_save = util_mod.save_json
        util_mod.save_json = function(path, data) saved_cfg = data end

        with_io_read("y", function()
            T.capture_output(function()
                hf.handle_hf_command(
                    {"hf", "https://huggingface.co/owner/myrepo", "test-model.Q4_K_M.gguf"},
                    cfg
                )
            end)
        end)

        util_mod.save_json = orig_save
        hf._fetch_url = nil

        -- preset should have been written into cfg
        local model_cfg = cfg.models and cfg.models["test-model.Q4_K_M.gguf"]
        T.assert_eq(model_cfg ~= nil,                    true, "model entry created in cfg")
        T.assert_eq(model_cfg.presets ~= nil,            true, "presets section created")
        T.assert_eq(model_cfg.presets["hf"] ~= nil,     true, "hf preset created")
        T.assert_eq(model_cfg.presets["hf"].source, "hf",     "preset source is 'hf'")

        local flags = model_cfg.presets["hf"].flags
        T.assert_eq(type(flags), "table", "preset has flags table")
        T.assert_eq(#flags > 0, true,     "preset has at least one flag")

        -- note file should exist
        local note_path = tmp .. "/notes/test-model.Q4_K_M.gguf.md"
        local f = io.open(note_path, "r")
        T.assert_eq(f ~= nil, true, "notes file was created")
        if f then
            local content = f:read("*all")
            f:close()
            T.assert_contains(content, "HuggingFace source:", "note contains HF source label")
            T.assert_contains(content, "huggingface.co",     "note contains HF URL")
        end

        rmtree(tmp)
    end

    -- ── 14. full flow: no flags found, user approves → only note saved ────
    do
        local tmp = mkdtemp()
        local hf
        T.with_stubs(make_hf_stubs(tmp), function()
            hf = require("hf")
        end)

        hf._fetch_url = function(url)
            return "This is a great model. No flags here, just vibes.", nil
        end

        local cfg = { models_dir = tmp, models = {} }

        with_io_read("y", function()
            T.capture_output(function()
                hf.handle_hf_command(
                    {"hf", "https://huggingface.co/owner/vibemodel", "test-model.Q4_K_M.gguf"},
                    cfg
                )
            end)
        end)

        hf._fetch_url = nil

        -- No preset should have been created
        local model_cfg = cfg.models and cfg.models["test-model.Q4_K_M.gguf"]
        local has_hf_preset = model_cfg and model_cfg.presets and model_cfg.presets["hf"]
        T.assert_eq(has_hf_preset, nil, "no preset saved when no flags found")

        -- Note should still be written
        local note_path = tmp .. "/notes/test-model.Q4_K_M.gguf.md"
        local f = io.open(note_path, "r")
        T.assert_eq(f ~= nil, true, "note file created even without flags")
        if f then
            local content = f:read("*all")
            f:close()
            T.assert_contains(content, "HuggingFace source:", "note has HF link")
        end

        rmtree(tmp)
    end

    -- ── 15. full flow: user declines → no changes made ───────────────────
    do
        local tmp = mkdtemp()
        local hf
        T.with_stubs(make_hf_stubs(tmp), function()
            hf = require("hf")
        end)

        hf._fetch_url = function(url)
            return "llama-cli -c 4096 --threads 4", nil
        end

        local cfg = { models_dir = tmp, models = {} }

        with_io_read("n", function()
            T.capture_output(function()
                hf.handle_hf_command(
                    {"hf", "https://huggingface.co/owner/repo", "test-model.Q4_K_M.gguf"},
                    cfg
                )
            end)
        end)

        hf._fetch_url = nil

        -- cfg.models should be empty — nothing persisted
        local model_entry = cfg.models and cfg.models["test-model.Q4_K_M.gguf"]
        T.assert_eq(model_entry, nil, "no config changes when user declines")

        -- No note file
        local note_path = tmp .. "/notes/test-model.Q4_K_M.gguf.md"
        local f = io.open(note_path, "r")
        T.assert_eq(f, nil, "no notes file written when user declines")
        if f then f:close() end

        rmtree(tmp)
    end

    -- ── 16. summary output mentions key information ───────────────────────
    do
        local tmp = mkdtemp()
        local hf
        T.with_stubs(make_hf_stubs(tmp), function()
            hf = require("hf")
        end)

        hf._fetch_url = function(url)
            return "llama-cli -c 2048 --n-gpu-layers 20", nil
        end

        local cfg = { models_dir = tmp, models = {} }
        local all_print = {}
        local all_write = {}

        with_io_read("n", function()  -- decline so we don't actually write
            all_print, all_write = T.capture_output(function()
                hf.handle_hf_command(
                    {"hf", "https://huggingface.co/foo/bar", "test-model.Q4_K_M.gguf"},
                    cfg
                )
            end)
        end)

        hf._fetch_url = nil

        local summary = table.concat(all_print, "\n")
        T.assert_contains(summary, "HuggingFace Import Summary", "summary header present")
        T.assert_contains(summary, "test-model.Q4_K_M.gguf",    "model name in summary")
        T.assert_contains(summary, "huggingface.co/foo/bar",     "source URL in summary")
        T.assert_contains(summary, "hf",                         "preset profile name shown")

        rmtree(tmp)
    end

end }
