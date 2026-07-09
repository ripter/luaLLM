-- hf.lua
-- Import recommended llama.cpp flags from a HuggingFace model card.
-- Uses a running llama-server (or llama-cli) to extract structured settings
-- from the model card's README, then saves them as a "hf" preset and adds
-- a note linking back to the HF page.

local util     = require("util")
local config   = require("config")
local resolver = require("resolver")
local state    = require("state")

local json_ok, json = pcall(require, "cjson")
if not json_ok then json = nil end

local M = {}

-- ---------------------------------------------------------------------------
-- URL / repo helpers
-- ---------------------------------------------------------------------------

-- Extract "owner/repo" from any HuggingFace URL variant.
-- Supports:
--   https://huggingface.co/owner/repo
--   https://huggingface.co/owner/repo/tree/main
--   https://hf.co/owner/repo
local function parse_hf_url(url)
    local owner, repo = url:match("huggingface%.co/([^/]+)/([^/?#]+)")
    if not owner then
        owner, repo = url:match("hf%.co/([^/]+)/([^/?#]+)")
    end
    return owner, repo
end

local function raw_readme_url(owner, repo)
    return string.format("https://huggingface.co/%s/%s/raw/main/README.md", owner, repo)
end

-- ---------------------------------------------------------------------------
-- Fetching the model card
-- ---------------------------------------------------------------------------

local function fetch_url(url)
    if M._fetch_url then return M._fetch_url(url) end
    local cmd = string.format(
        "curl -fsSL --max-time 30 %s 2>&1",
        util.sh_quote(url)
    )
    local h = io.popen(cmd)
    if not h then return nil, "io.popen failed" end
    local body = h:read("*a")
    local ok = h:close()
    if not ok or body == "" then
        return nil, "curl returned no content (check network or URL)"
    end
    return body
end

-- ---------------------------------------------------------------------------
-- Regex-based flag extraction (fast path, no LLM needed)
-- ---------------------------------------------------------------------------

-- Collect llama.cpp-style flags that appear verbatim in text.
local KNOWN_FLAGS = {
    "-c", "--ctx-size",
    "--n-gpu-layers", "--ngl",
    "--threads", "-t",
    "--flash-attn",
    "--mlock",
    "--no-mmap",
    "--numa",
    "--batch-size", "-b",
    "--ubatch-size", "-ub",
    "--rope-freq-base",
    "--rope-freq-scale",
    "--cache-type-k", "--cache-type-v",
    "--temp",
    "--top-p",
    "--top-k",
    "--repeat-penalty",
    "--repeat-last-n",
    "--min-p",
    "--dynatemp-range",
    "--dynatemp-exp",
}

local function regex_extract_flags(text)
    local flags = {}
    local seen = {}

    for _, flag in ipairs(KNOWN_FLAGS) do
        -- Escape flag for pattern: "-" becomes "%-"
        local pat = flag:gsub("%-", "%%-")
        -- Match flag followed by optional space and a value token
        for value in text:gmatch(pat .. "%s+([%S]+)") do
            -- Skip values that are themselves flags
            if not value:match("^%-") then
                local key = flag .. " " .. value
                if not seen[key] then
                    seen[key] = true
                    table.insert(flags, flag)
                    table.insert(flags, value)
                end
            end
        end
        -- Also match boolean flags (--flash-attn without a value)
        if not seen[flag] then
            if text:find(pat .. "[%s\n\r]") or text:find(pat .. "$") then
                -- Only add boolean-style flags that never took a value above
                local has_value = false
                for _, v in ipairs(flags) do
                    if v == flag then has_value = true; break end
                end
                if not has_value then
                    -- Check if it appears in a command-line context
                    if text:find(pat) and
                       (flag == "--flash-attn" or flag == "--mlock" or flag == "--no-mmap") then
                        seen[flag] = true
                        table.insert(flags, flag)
                        table.insert(flags, "true")
                    end
                end
            end
        end
    end

    return flags
end

-- ---------------------------------------------------------------------------
-- LLM-based flag extraction (slow path, requires running model)
-- ---------------------------------------------------------------------------

local EXTRACTION_PROMPT = [[You are a helpful assistant that extracts llama.cpp command-line flags from model documentation.

Given the following model card / README, extract any recommended llama.cpp flags and settings.
Only include flags that are explicitly mentioned or recommended in the text.
Output ONLY a JSON object in this exact format with no other text:
{"flags": ["-c", "8192", "--n-gpu-layers", "35", "--threads", "8"]}

If no flags are mentioned, output: {"flags": []}

Model card:
---
%s
---

JSON output:]]

local function find_any_running_server()
    local data = state.get_state()
    for _, entry in ipairs(data.servers) do
        if entry.state == "running" and entry.port then
            return entry
        end
    end
    return nil
end

local function query_via_server(entry, readme_text)
    local prompt = string.format(EXTRACTION_PROMPT, readme_text:sub(1, 6000))
    local payload = json.encode({
        prompt      = prompt,
        n_predict   = 256,
        temperature = 0,
        stop        = {"\n\n", "```"},
    })

    local tmpfile = os.tmpname()
    local f = io.open(tmpfile, "w")
    if not f then return nil, "cannot write temp file" end
    f:write(payload)
    f:close()

    local url = string.format("http://127.0.0.1:%d/completion", entry.port)
    local cmd = string.format(
        "curl -fsSL --max-time 60 -X POST -H 'Content-Type: application/json' -d @%s %s 2>&1",
        util.sh_quote(tmpfile),
        util.sh_quote(url)
    )
    local h = io.popen(cmd)
    local body = h and h:read("*a") or ""
    if h then h:close() end
    os.remove(tmpfile)

    if body == "" then return nil, "no response from server" end

    if not json then return nil, "cjson not available to parse response" end
    local ok, resp = pcall(json.decode, body)
    if not ok or type(resp) ~= "table" then
        return nil, "could not parse server response"
    end
    return resp.content or resp.response or ""
end

local function query_via_cli(cfg, readme_text)
    if not cfg.llama_cli_path then
        return nil, "llama_cli_path not configured"
    end

    local prompt = string.format(EXTRACTION_PROMPT, readme_text:sub(1, 6000))

    -- Find any GGUF file to use for one-shot inference
    local model_file = nil
    local last_model = nil
    do
        local s = state.get_state()
        if s.last_used then last_model = s.last_used end
    end

    if last_model and cfg.models_dir then
        local path = util.expand_path(cfg.models_dir) .. "/" .. last_model
        if util.file_exists(path) then
            model_file = path
        end
    end

    if not model_file then
        return nil, "no model available for llama-cli inference (start a server first)"
    end

    local tmpfile = os.tmpname()
    local f = io.open(tmpfile, "w")
    if not f then return nil, "cannot write temp prompt file" end
    f:write(prompt)
    f:close()

    local cmd = string.format(
        "%s -m %s -f %s --n-predict 256 --temp 0 --log-disable 2>/dev/null",
        util.sh_quote(cfg.llama_cli_path),
        util.sh_quote(model_file),
        util.sh_quote(tmpfile)
    )
    local h = io.popen(cmd)
    local output = h and h:read("*a") or ""
    if h then h:close() end
    os.remove(tmpfile)

    return output
end

-- Parse the LLM's JSON response into a flat flags table.
local function parse_llm_flags(text)
    if not text or text == "" then return nil end
    if not json then return nil end

    -- Find the JSON object in the response
    local json_str = text:match("{.-}")
    if not json_str then return nil end

    local ok, obj = pcall(json.decode, json_str)
    if not ok or type(obj) ~= "table" then return nil end

    local flags = obj.flags
    if type(flags) ~= "table" or #flags == 0 then return nil end

    -- Validate: must be alternating flag/value strings
    local result = {}
    for _, v in ipairs(flags) do
        if type(v) == "string" then
            table.insert(result, v)
        elseif type(v) == "number" then
            table.insert(result, tostring(v))
        end
    end
    return #result > 0 and result or nil
end

-- ---------------------------------------------------------------------------
-- Config helpers (mirrors recommend.lua)
-- ---------------------------------------------------------------------------

local function ensure_models_config(cfg)
    if not cfg.models then cfg.models = {} end
    return cfg.models
end

local function ensure_model_config(cfg, model_name)
    local models = ensure_models_config(cfg)
    if not models[model_name] then models[model_name] = {} end
    return models[model_name]
end

local function ensure_presets_config(cfg, model_name)
    local model_cfg = ensure_model_config(cfg, model_name)
    if not model_cfg.presets then model_cfg.presets = {} end
    return model_cfg.presets
end

local function save_config(cfg)
    util.save_json(config.CONFIG_FILE, cfg)
end

-- ---------------------------------------------------------------------------
-- Notes helper
-- ---------------------------------------------------------------------------

local function add_note(model_name, note_text)
    -- Inline to avoid circular require; notes.lua exposes add_note as local.
    -- We call the notes module's public command instead via a direct write.
    local notes_dir = config.CONFIG_DIR .. "/notes"
    util.ensure_dir(notes_dir)

    local safe_name = util.safe_filename(model_name)
    local notes_path = notes_dir .. "/" .. safe_name .. ".md"

    local content
    if not util.file_exists(notes_path) then
        content = string.format("# %s\n\n## Notes\n\n## Summary\n", model_name)
    else
        local f = io.open(notes_path, "r")
        content = f and f:read("*a") or ""
        if f then f:close() end
    end

    local timestamp = os.date("%Y-%m-%d %H:%M")
    local new_note = string.format("- %s  %s\n", timestamp, note_text)

    local summary_pos = content:find("\n## Summary")
    if summary_pos then
        content = content:sub(1, summary_pos - 1) .. new_note .. content:sub(summary_pos)
    else
        if not content:match("\n$") then content = content .. "\n" end
        content = content .. new_note
    end

    local f = io.open(notes_path, "w")
    if f then
        f:write(content)
        f:close()
    end
end

-- ---------------------------------------------------------------------------
-- Confirmation prompt
-- ---------------------------------------------------------------------------

local function confirm(prompt_text)
    io.write(prompt_text .. " [y/N] ")
    io.flush()
    local line = io.read("*l") or ""
    return line:match("^[Yy]") ~= nil
end

-- ---------------------------------------------------------------------------
-- Main command handler
-- ---------------------------------------------------------------------------

function M.handle_hf_command(args, cfg)
    local url = args[2]
    if not url or url == "--help" or url == "-h" then
        print("luallm hf — Import recommended llama.cpp flags from a HuggingFace model card")
        print()
        print("USAGE:")
        print("  luallm hf <huggingface-url> [model]")
        print()
        print("ARGUMENTS:")
        print("  <url>    HuggingFace model page URL")
        print("  [model]  Local model name (fuzzy match). Prompted if omitted.")
        print()
        print("EXAMPLES:")
        print("  luallm hf https://huggingface.co/DavidAU/MN-Oblivion-26B-UNCENSORED-NEO-Imatrix-GGUF")
        print("  luallm hf https://huggingface.co/mistralai/Mistral-7B-v0.1 mistral-7b.Q4_K_M.gguf")
        return
    end

    -- 1. Parse the URL
    io.write("Parsing URL... ")
    io.flush()
    local owner, repo = parse_hf_url(url)
    if not owner then
        print("FAILED")
        io.stderr:write("Error: could not parse HuggingFace URL: " .. url .. "\n")
        io.stderr:write("Expected format: https://huggingface.co/<owner>/<repo>\n")
        os.exit(1)
    end
    print(string.format("ok (%s/%s)", owner, repo))

    -- 2. Fetch the model card README
    local readme_url = raw_readme_url(owner, repo)
    io.write("Fetching model card from HuggingFace... ")
    io.flush()
    local readme, fetch_err = fetch_url(readme_url)
    if not readme then
        print("FAILED")
        io.stderr:write("Error: " .. (fetch_err or "unknown") .. "\n")
        io.stderr:write("URL tried: " .. readme_url .. "\n")
        os.exit(1)
    end
    print(string.format("ok (%d bytes)", #readme))

    -- 3. Resolve the local model name
    local model_query = args[3]
    local model_name
    if model_query then
        model_name = resolver.resolve_or_exit(cfg, model_query, {
            title = "Select a model (↑/↓ arrows, Enter to confirm, q to quit):"
        })
    else
        -- Try fuzzy-matching the HF repo name against local models
        local model_info = require("model_info")
        local all_models = model_info.list_models(cfg.models_dir)
        if #all_models == 0 then
            io.stderr:write("Error: no models found in " .. tostring(cfg.models_dir) .. "\n")
            os.exit(1)
        end

        -- Use repo name (lowercase, hyphens→nothing) as a search hint
        local hint = repo:lower():gsub("%-gguf$", ""):gsub("%-imatrix$", "")
        model_name = resolver.resolve_or_exit(cfg, hint, {
            title = "Select the local model to configure (↑/↓ arrows, Enter to confirm, q to quit):"
        })
    end
    print("Model: " .. model_name)

    -- 4. Extract flags — try regex first, then LLM
    local flags = nil
    local extraction_method = nil

    io.write("Scanning model card for llama.cpp flags (regex)... ")
    io.flush()
    local regex_flags = regex_extract_flags(readme)
    if #regex_flags > 0 then
        flags = regex_flags
        extraction_method = "regex"
        print(string.format("found %d flag tokens", #flags))
    else
        print("none found")
    end

    if not flags then
        -- Try LLM extraction
        local server_entry = find_any_running_server()
        if server_entry then
            io.write(string.format(
                "Querying local LLM on port %d for flag extraction... ",
                server_entry.port
            ))
            io.flush()
            if not json then
                print("SKIPPED (cjson not available)")
            else
                local llm_output, llm_err = query_via_server(server_entry, readme)
                if llm_output then
                    flags = parse_llm_flags(llm_output)
                    if flags and #flags > 0 then
                        extraction_method = "llm (server)"
                        print(string.format("found %d flag tokens", #flags))
                    else
                        print("no flags extracted from LLM response")
                    end
                else
                    print("FAILED (" .. (llm_err or "unknown") .. ")")
                end
            end
        else
            io.write("Querying local LLM via llama-cli for flag extraction... ")
            io.flush()
            local llm_output, llm_err = query_via_cli(cfg, readme)
            if llm_output then
                flags = parse_llm_flags(llm_output)
                if flags and #flags > 0 then
                    extraction_method = "llm (cli)"
                    print(string.format("found %d flag tokens", #flags))
                else
                    print("no flags extracted from LLM response")
                end
            else
                print("SKIPPED (" .. (llm_err or "no model available") .. ")")
            end
        end
    end

    -- 5. Print summary
    print()
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("  HuggingFace Import Summary")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print(string.format("  Model:   %s", model_name))
    print(string.format("  Source:  %s", url))
    print()

    if flags and #flags > 0 then
        print(string.format("  Preset profile 'hf' will be saved with %d flags:", #flags / 2))
        for i = 1, #flags, 2 do
            local flag  = flags[i]
            local value = flags[i + 1] or ""
            if value == "true" then
                print(string.format("    %s", flag))
            else
                print(string.format("    %s %s", flag, value))
            end
        end
        print(string.format("  (extracted via %s)", extraction_method))
    else
        print("  No llama.cpp flags were found in the model card.")
        print("  A note with the HF link will still be added.")
        print("  No preset will be saved.")
    end

    print()
    print("  Note will be added:")
    print(string.format("    HuggingFace source: %s", url))
    print()
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print()

    -- 6. Confirm
    if not confirm("Apply these changes?") then
        print("Aborted — no changes made.")
        return
    end

    -- 7. Save preset (if we have flags)
    if flags and #flags > 0 then
        io.write("Saving preset 'hf'... ")
        io.flush()
        local preset = {
            created_at = os.time(),
            source     = "hf",
            notes      = string.format("Imported from %s", url),
            flags      = flags,
        }
        local presets = ensure_presets_config(cfg, model_name)
        presets["hf"] = preset
        save_config(cfg)
        print("done")
    end

    -- 8. Add note
    io.write("Adding note... ")
    io.flush()
    add_note(model_name, "HuggingFace source: " .. url)
    print("done")

    print()
    if flags and #flags > 0 then
        print(string.format("✓ Preset saved. Run with: luallm run %s --preset hf", model_name))
    else
        print(string.format("✓ Note added. View with: luallm notes %s", model_name))
    end
end

-- ---------------------------------------------------------------------------
-- Test hooks (mirrors recommend._bench_runner pattern)
-- ---------------------------------------------------------------------------

-- Inject a fake fetcher: M._fetch_url = function(url) return body, err end
M._fetch_url = nil

-- Expose pure helpers for unit testing
M._parse_hf_url       = parse_hf_url
M._regex_extract_flags = regex_extract_flags
M._parse_llm_flags    = parse_llm_flags

return M
