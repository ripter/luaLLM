#!/usr/bin/env lua

-- Set up luarocks path if needed
local function setup_luarocks_path()
    local handle = io.popen("luarocks path --lr-path 2>/dev/null")
    if handle then
        local lr_path = handle:read("*a")
        handle:close()
        if lr_path and lr_path ~= "" then
            package.path = lr_path:gsub("\n", "") .. ";" .. package.path
        end
    end
    
    handle = io.popen("luarocks path --lr-cpath 2>/dev/null")
    if handle then
        local lr_cpath = handle:read("*a")
        handle:close()
        if lr_cpath and lr_cpath ~= "" then
            package.cpath = lr_cpath:gsub("\n", "") .. ";" .. package.cpath
        end
    end
end

setup_luarocks_path()

local json = require("cjson")
local lfs = require("lfs")

-- Configuration
local CONFIG_DIR = (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. "/luaLLM"
local CONFIG_FILE = CONFIG_DIR .. "/config.json"
local HISTORY_FILE = CONFIG_DIR .. "/history.json"
local MODEL_INFO_DIR = CONFIG_DIR .. "/model_info"

-- Utility functions
local function sh_quote(s)
    -- Strong POSIX shell quoting: wraps in single quotes and escapes embedded single quotes
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function exec(cmd)
    -- Normalize os.execute across Lua 5.1/5.2/5.3/5.4
    local a, b, c = os.execute(cmd)
    if type(a) == "number" then
        return a == 0, a
    end
    if a == true then
        return true, 0
    end
    if b == "exit" then
        return c == 0, c
    end
    return false, c or 1
end

local function normalize_exit_code(ok, reason, code)
    -- Normalize io.popen handle:close() return values across Lua versions
    if type(ok) == "number" then
        return ok
    elseif reason == "exit" then
        return code or 0
    elseif not ok then
        return code or 1
    end
    return 0
end

local function expand_path(path)
    if path:sub(1, 1) == "~" then
        local home = os.getenv("HOME")
        return home .. path:sub(2)
    end
    return path
end

local function path_attr(path)
    path = expand_path(path)
    return lfs.attributes(path)
end

local function is_dir(path)
    local attr = path_attr(path)
    return attr and attr.mode == "directory"
end

local function file_exists(path)
    path = expand_path(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

local function ensure_config_dir()
    exec("mkdir -p " .. sh_quote(CONFIG_DIR))
end

local function ensure_model_info_dir()
    exec("mkdir -p " .. sh_quote(MODEL_INFO_DIR))
end

local function load_json(filepath)
    if not file_exists(filepath) then
        return nil
    end
    local f = assert(io.open(expand_path(filepath), "r"))
    local content = f:read("*all")
    f:close()
    
    local ok, data = pcall(json.decode, content)
    if not ok then
        return nil, ("Invalid JSON in %s"):format(filepath)
    end
    return data
end

local function save_json(filepath, data)
    local f = io.open(filepath, "w")
    f:write(json.encode(data))
    f:close()
end

local function load_config()
    ensure_config_dir()
    local config, err = load_json(CONFIG_FILE)
    
    if err then
        print("Error: " .. err)
        print("Please fix or delete the config file and try again.")
        os.exit(1)
    end
    
    if not config then
        -- Check if example config exists next to the script
        local script_dir = arg[0]:match("(.*/)")
        local example_config = script_dir and (script_dir .. "config.example.json") or "config.example.json"
        
        if file_exists(example_config) then
            print("No config found. Creating from example config...")
            exec("cp " .. sh_quote(example_config) .. " " .. sh_quote(CONFIG_FILE))
            config = load_json(CONFIG_FILE)
            if config then
                print("Config created at: " .. CONFIG_FILE)
                print("Please edit it to set your paths.")
                print()
            else
                print("Error: Failed to create config from example.")
                os.exit(1)
            end
        else
            print("Error: No config file found.")
            print()
            print("Please create a config file at:")
            print("  " .. CONFIG_FILE)
            print()
            print("You can find an example config (config.example.json) in the")
            print("same directory as the luallm script, or create one manually.")
            os.exit(1)
        end
    end
    
    return config
end

local function load_history()
    local history = load_json(HISTORY_FILE)
    return history or {}
end

local function save_history(history)
    save_json(HISTORY_FILE, history)
end

local function add_to_history(model_name, status, exit_code)
    status = status or "running"
    local history = load_history()
    
    -- Check if there's already a running entry for this model
    local found_running = false
    for i, entry in ipairs(history) do
        local name = type(entry) == "string" and entry or entry.name
        if name == model_name and type(entry) == "table" and entry.status == "running" then
            -- Update the running entry
            entry.status = status
            entry.end_time = os.time()
            if exit_code then
                entry.exit_code = exit_code
            end
            found_running = true
            save_history(history)
            return
        end
    end
    
    -- If updating a non-running entry or creating new
    if not found_running then
        -- Remove any old entries for this model
        for i = #history, 1, -1 do
            local name = type(history[i]) == "string" and history[i] or history[i].name
            if name == model_name then
                table.remove(history, i)
            end
        end
        
        -- Add new entry at front
        table.insert(history, 1, {
            name = model_name,
            last_run = os.time(),
            status = status,
            exit_code = exit_code
        })
    end
    
    save_history(history)
end

local function get_recent_models(config)
    local history = load_history()
    local count = config.recent_models_count or 4
    local recent = {}
    
    for i = 1, math.min(count, #history) do
        table.insert(recent, history[i])
    end
    
    return recent
end

local function clear_history()
    save_history({})
end

local function get_last_run_time(model_name, history)
    for _, entry in ipairs(history) do
        local name = type(entry) == "string" and entry or entry.name
        if name == model_name then
            return type(entry) == "table" and entry.last_run or nil
        end
    end
    return nil
end

local function get_model_fingerprint(model_path)
    local attr = path_attr(model_path)
    if not attr then
        return nil
    end
    return {
        size = attr.size,
        mtime = attr.modification
    }
end

local function should_capture_line(line)
    -- Check if line matches patterns we want to capture
    local patterns = {
        "^llama_model_loader:",
        "^llama_model_load:",
        "^llama_new_context_with_model:",
        "^llama_kv_cache_init:",
        "^gguf_",
        "^system_info:",
        "^main: "
    }
    
    for _, pattern in ipairs(patterns) do
        if line:match(pattern) then
            return true
        end
    end
    
    return false
end

local function get_model_info_path(model_name)
    return MODEL_INFO_DIR .. "/" .. model_name .. ".json"
end

local function save_model_info(config, model_name, captured_lines, is_partial)
    ensure_model_info_dir()
    
    local model_path = expand_path(config.models_dir) .. "/" .. model_name .. ".gguf"
    local fingerprint = get_model_fingerprint(model_path)
    
    if not fingerprint then
        return false
    end
    
    local info = {
        model_name = model_name,
        gguf_path = model_path,
        gguf_size_bytes = fingerprint.size,
        gguf_mtime = fingerprint.mtime,
        captured_at = os.time(),
        llama_cpp_path = expand_path(config.llama_cpp_path),
        captured_lines = captured_lines,
        partial = is_partial or false
    }
    
    local info_path = get_model_info_path(model_name)
    save_json(info_path, info)
    return true
end

local function load_model_info(model_name)
    local info_path = get_model_info_path(model_name)
    local info = load_json(info_path)
    
    if not info then
        return nil, "no_cache"
    end
    
    -- Check if cache is stale
    local current_fingerprint = get_model_fingerprint(info.gguf_path)
    if not current_fingerprint then
        return info, "gguf_missing"
    end
    
    if current_fingerprint.size ~= info.gguf_size_bytes or 
       current_fingerprint.mtime ~= info.gguf_mtime then
        return info, "stale"
    end
    
    return info, "valid"
end

local function list_models(models_dir)
    local models = {}
    models_dir = expand_path(models_dir)
    
    if not is_dir(models_dir) then
        return {}
    end
    
    for file in lfs.dir(models_dir) do
        if file:match("%.gguf$") then
            local name = file:gsub("%.gguf$", "")
            local filepath = models_dir .. "/" .. file
            local attr = lfs.attributes(filepath)
            if attr then
                table.insert(models, {
                    name = name,
                    mtime = attr.modification
                })
            end
        end
    end
    
    -- Sort by modification time, newest first
    table.sort(models, function(a, b)
        return a.mtime > b.mtime
    end)
    
    return models
end

local function format_time(timestamp)
    local now = os.time()
    local diff = now - timestamp
    
    -- Within last minute
    if diff < 60 then
        return "just now"
    end
    
    -- Within last hour
    if diff < 3600 then
        local mins = math.floor(diff / 60)
        return mins .. " minute" .. (mins > 1 and "s" or "") .. " ago"
    end
    
    -- Within last day
    if diff < 86400 then
        local hours = math.floor(diff / 3600)
        return hours .. " hour" .. (hours > 1 and "s" or "") .. " ago"
    end
    
    -- Within last week
    if diff < 604800 then
        local days = math.floor(diff / 86400)
        return days .. " day" .. (days > 1 and "s" or "") .. " ago"
    end
    
    -- Within last month (30 days)
    if diff < 2592000 then
        local weeks = math.floor(diff / 604800)
        return weeks .. " week" .. (weeks > 1 and "s" or "") .. " ago"
    end
    
    -- Otherwise show date
    return os.date("%b %d, %Y", timestamp)
end

local function print_model_list(models, models_dir)
    if #models == 0 then
        print("  No models found.")
        return
    end
    
    -- Load history to check for last run times
    local history = load_history()
    
    -- Convert simple names to model objects if needed
    local model_list = {}
    for _, model in ipairs(models) do
        if type(model) == "string" then
            -- Simple name - need to get the file info
            local filepath = expand_path(models_dir) .. "/" .. model .. ".gguf"
            local attr = lfs.attributes(filepath)
            local mtime = attr and attr.modification or 0
            
            -- Check if we have a last run time in history
            local last_run = get_last_run_time(model, history)
            if last_run then
                mtime = last_run
            end
            
            table.insert(model_list, {name = model, mtime = mtime})
        else
            -- Already a model object, check for last run time
            local last_run = get_last_run_time(model.name, history)
            if last_run then
                model.mtime = last_run
            end
            table.insert(model_list, model)
        end
    end
    
    -- Sort by modification time, newest first
    table.sort(model_list, function(a, b)
        return a.mtime > b.mtime
    end)
    
    -- Find longest model name for alignment
    local max_len = 0
    for _, model in ipairs(model_list) do
        if #model.name > max_len then
            max_len = #model.name
        end
    end
    
    for _, model in ipairs(model_list) do
        local padding = string.rep(" ", max_len - #model.name)
        print("  " .. model.name .. padding .. "  " .. format_time(model.mtime))
    end
end

local function find_matching_override(model_name, overrides)
    for pattern, params in pairs(overrides) do
        if model_name:match(pattern) then
            return params
        end
    end
    return nil
end

local function build_llama_command(config, model_name, extra_args)
    local model_path = expand_path(config.models_dir) .. "/" .. model_name .. ".gguf"
    
    local argv = {expand_path(config.llama_cpp_path), "-m", model_path}
    
    -- Helper to split space-separated params into individual args
    local function add_params(params)
        for _, param in ipairs(params) do
            -- Split on spaces to get individual arguments
            for arg in param:gmatch("%S+") do
                table.insert(argv, arg)
            end
        end
    end
    
    -- Add default params
    if config.default_params then
        add_params(config.default_params)
    end
    
    -- Check for model-specific overrides
    local override = find_matching_override(model_name, config.model_overrides or {})
    if override then
        add_params(override)
    end
    
    -- Add any extra command-line args
    if extra_args then
        for _, arg in ipairs(extra_args) do
            table.insert(argv, arg)
        end
    end
    
    -- Quote all args safely for POSIX shells
    for i = 1, #argv do
        argv[i] = sh_quote(argv[i])
    end
    
    return table.concat(argv, " ")
end

local function run_model(config, model_name, extra_args)
    local model_path = expand_path(config.models_dir) .. "/" .. model_name .. ".gguf"
    
    if not file_exists(model_path) then
        print("Error: Model file not found: " .. model_path)
        print()
        print("Available models:")
        local models = list_models(config.models_dir)
        print_model_list(models, config.models_dir)
        os.exit(1)
    end
    
    local cmd = build_llama_command(config, model_name, extra_args)
    print("Starting llama.cpp with: " .. model_name)
    print("Command: " .. cmd)
    print()
    
    -- State that persists across the run
    local captured_lines = {}
    local capture_count = 0
    local capture_bytes = 0
    local max_capture_lines = 400
    local max_capture_bytes = 64 * 1024
    local capturing = true
    local pipe = nil
    local info_written = false
    
    -- Finalize function that ALWAYS runs
    local function finalize(opts)
        opts = opts or {}
        
        -- Close pipe if still open
        if pipe then
            pcall(function() pipe:close() end)
        end
        
        -- Always save captured metadata if we have any
        if #captured_lines > 0 then
            local is_partial = opts.interrupted or (opts.exit_code ~= 0)
            save_model_info(config, model_name, captured_lines, is_partial)
        end
        
        -- Always update history with final status
        local status = "exited"
        if opts.interrupted then
            status = "interrupted"
        elseif opts.exit_code and opts.exit_code ~= 0 then
            status = "failed"
        end
        
        add_to_history(model_name, status, opts.exit_code)
    end
    
    -- Write initial "running" history entry
    add_to_history(model_name, "running", nil)
    
    -- Main execution wrapped in xpcall
    local ok, err = xpcall(function()
        pipe = io.popen(cmd .. " 2>&1", "r")
        if not pipe then
            error("Failed to execute command")
        end
        
        for line in pipe:lines() do
            -- Always print to terminal
            print(line)
            
            -- Capture relevant lines
            if capturing and should_capture_line(line) then
                table.insert(captured_lines, line)
                capture_count = capture_count + 1
                capture_bytes = capture_bytes + #line
                
                -- Write model info early (first time we get metadata)
                if not info_written and #captured_lines >= 10 then
                    save_model_info(config, model_name, captured_lines, true)
                    info_written = true
                end
                
                -- Stop capturing if we hit limits
                if capture_count >= max_capture_lines or capture_bytes >= max_capture_bytes then
                    capturing = false
                end
            end
        end
        
        -- Get exit code
        local close_ok, reason, code = pipe:close()
        pipe = nil
        local exit_code = normalize_exit_code(close_ok, reason, code)
        
        finalize({ exit_code = exit_code, interrupted = false })
        
        if exit_code ~= 0 then
            print(("Error: llama.cpp exited with code %d"):format(exit_code))
            os.exit(exit_code)
        end
        
    end, debug.traceback)
    
    -- Handle errors
    if not ok then
        local err_msg = tostring(err)
        if err_msg:match("interrupted") then
            -- Ctrl-C: finalize and exit cleanly
            print()
            print("Interrupted by user")
            finalize({ exit_code = 130, interrupted = true })
            os.exit(130)
        else
            -- Other error: finalize and propagate
            finalize({ exit_code = 1, interrupted = false, reason = "error" })
            error(err)
        end
    end
end

local function rebuild_llama(config)
    local source_dir = expand_path(config.llama_cpp_source_dir)
    
    if not is_dir(source_dir) then
        print("Error: llama.cpp source directory not found: " .. source_dir)
        print("Update 'llama_cpp_source_dir' in your config file: " .. CONFIG_FILE)
        os.exit(1)
    end
    
    print("Rebuilding llama.cpp from: " .. source_dir)
    print()
    
    -- Step 1: Pull latest changes
    print("Pulling latest changes from git...")
    local ok, code = exec("cd " .. sh_quote(source_dir) .. " && git pull")
    if not ok then
        print("Error: git pull failed")
        os.exit(1)
    end
    print()
    
    -- Step 2: Remove old build directory
    print("Cleaning build directory...")
    local build_dir = source_dir .. "/build"
    exec("rm -rf " .. sh_quote(build_dir))
    print()
    
    -- Step 3: Configure with cmake
    print("Configuring build with cmake...")
    local cmake_opts = {}
    if config.cmake_options then
        for _, opt in ipairs(config.cmake_options) do
            table.insert(cmake_opts, sh_quote(opt))
        end
    end
    
    local cmake_cmd = "cd " .. sh_quote(source_dir) .. " && cmake -S . -B build"
    for _, opt in ipairs(cmake_opts) do
        cmake_cmd = cmake_cmd .. " " .. opt
    end
    
    ok, code = exec(cmake_cmd)
    if not ok then
        print("Error: cmake configuration failed")
        os.exit(1)
    end
    print()
    
    -- Step 4: Build
    print("Building (this may take a while)...")
    ok, code = exec("cd " .. sh_quote(source_dir) .. " && cmake --build build -j")
    if not ok then
        print("Error: build failed")
        os.exit(1)
    end
    
    print()
    print("✓ Build complete!")
    print()
    print("Binaries are in: " .. source_dir .. "/build/bin/")
    print()
    print("You may want to update your config with the new binary path:")
    print("  " .. source_dir .. "/build/bin/llama-server")
end

-- Interactive picker using arrow keys
local function with_raw_tty(fn)
    exec("stty -echo -icanon")
    local ok, result = xpcall(fn, function(err)
        return err .. "\n" .. debug.traceback()
    end)
    exec("stty echo icanon")
    io.write("\27[2J\27[H")
    
    if not ok then
        error(result)
    end
    return result
end

local function show_picker(models)
    if #models == 0 then
        print("No recent models found.")
        return nil
    end
    
    -- Convert history entries to just names for display
    local model_names = {}
    for _, entry in ipairs(models) do
        local name = type(entry) == "string" and entry or entry.name
        table.insert(model_names, name)
    end
    
    return with_raw_tty(function()
        local selected = 1
        local function draw()
            -- Clear screen and move cursor to top
            io.write("\27[2J\27[H")
            print("Select a model (↑/↓ arrows, Enter to confirm, q to quit):\n")
            
            for i, model in ipairs(model_names) do
                if i == selected then
                    io.write("  → \27[1m" .. model .. "\27[0m\n")
                else
                    io.write("    " .. model .. "\n")
                end
            end
        end
        
        draw()
        
        while true do
            local char = io.read(1)
            
            if char == "\27" then
                -- Escape sequence
                local next = io.read(1)
                if next == "[" then
                    local arrow = io.read(1)
                    if arrow == "A" then -- Up
                        selected = selected > 1 and selected - 1 or #model_names
                        draw()
                    elseif arrow == "B" then -- Down
                        selected = selected < #model_names and selected + 1 or 1
                        draw()
                    end
                end
            elseif char == "\n" or char == "\r" then
                return model_names[selected]
            elseif char == "q" or char == "Q" then
                return nil
            end
        end
    end)
end

-- Main logic
local function main(args)
    local config = load_config()
    
    if #args == 0 then
        -- Show interactive picker with recent models
        local recent = get_recent_models(config)
        if #recent == 0 then
            print("No recent models. Use 'luallm list' to see available models.")
            os.exit(0)
        end
        
        local selected = show_picker(recent)
        if selected then
            run_model(config, selected, nil)
        end
        
    elseif args[1] == "list" then
        -- List all models
        local models = list_models(config.models_dir)
        print("Available models in " .. expand_path(config.models_dir) .. ":\n")
        print_model_list(models, config.models_dir)
        
    elseif args[1] == "info" then
        -- Show cached model info
        if #args < 2 then
            print("Error: Missing model name")
            print("Usage: luallm info <model_name>")
            os.exit(1)
        end
        
        local model_name = args[2]
        local raw_mode = args[3] == "--raw"
        
        local info, status = load_model_info(model_name)
        
        if status == "no_cache" then
            print("No cached info for model: " .. model_name)
            print("Run the model once to capture metadata:")
            print("  luallm " .. model_name)
            os.exit(0)
        end
        
        if status == "gguf_missing" then
            print("⚠ Warning: GGUF file no longer exists")
            print()
        elseif status == "stale" then
            print("⚠ Warning: Cache is stale (GGUF has been modified)")
            print("Run the model again to refresh cache:")
            print("  luallm " .. model_name)
            print()
        end
        
        if info.partial then
            print("⚠ Note: This is partial metadata (capture was interrupted)")
            print()
        end
        
        if raw_mode then
            -- Print raw captured lines
            for _, line in ipairs(info.captured_lines) do
                print(line)
            end
        else
            -- Print formatted info
            print("Model Info: " .. info.model_name)
            print()
            print("GGUF Path: " .. info.gguf_path)
            print("GGUF Size: " .. info.gguf_size_bytes .. " bytes")
            print("GGUF Modified: " .. os.date("%Y-%m-%d %H:%M:%S", info.gguf_mtime))
            print("Info Captured: " .. os.date("%Y-%m-%d %H:%M:%S", info.captured_at))
            print("llama.cpp: " .. info.llama_cpp_path)
            print()
            print("Captured Metadata (" .. #info.captured_lines .. " lines):")
            print("---")
            for _, line in ipairs(info.captured_lines) do
                print(line)
            end
        end
        
    elseif args[1] == "config" then
        -- Show config file location
        print("Config file: " .. CONFIG_FILE)
        print("Edit this file to customize settings.")
        
    elseif args[1] == "rebuild" then
        -- Rebuild llama.cpp
        rebuild_llama(config)
        
    elseif args[1] == "clear-history" then
        -- Clear run history
        clear_history()
        print("✓ History cleared")
        
    elseif args[1] == "doctor" then
        -- Run diagnostics
        print("luaLLM diagnostics")
        print()
        
        -- Check Lua version
        print("Lua version: " .. _VERSION)
        
        -- Check dependencies
        local has_cjson = pcall(require, "cjson")
        local has_lfs = pcall(require, "lfs")
        print("lua-cjson: " .. (has_cjson and "✓ installed" or "✗ missing"))
        print("luafilesystem: " .. (has_lfs and "✓ installed" or "✗ missing"))
        print()
        
        -- Check config
        print("Config file: " .. CONFIG_FILE)
        if file_exists(CONFIG_FILE) then
            print("  ✓ exists")
            local cfg, err = load_json(CONFIG_FILE)
            if err then
                print("  ✗ " .. err)
            else
                print("  ✓ valid JSON")
                
                -- Check llama.cpp binary
                if cfg.llama_cpp_path then
                    local llama_path = expand_path(cfg.llama_cpp_path)
                    if file_exists(llama_path) then
                        print("  ✓ llama.cpp binary exists: " .. llama_path)
                    else
                        print("  ✗ llama.cpp binary not found: " .. llama_path)
                    end
                end
                
                -- Check models directory
                if cfg.models_dir then
                    local models_dir = expand_path(cfg.models_dir)
                    if is_dir(models_dir) then
                        local models = list_models(cfg.models_dir)
                        print("  ✓ models directory exists: " .. models_dir)
                        print("    Found " .. #models .. " model(s)")
                    else
                        print("  ✗ models directory not found: " .. models_dir)
                    end
                end
                
                -- Check source directory
                if cfg.llama_cpp_source_dir then
                    local source_dir = expand_path(cfg.llama_cpp_source_dir)
                    if is_dir(source_dir) then
                        print("  ✓ llama.cpp source directory exists: " .. source_dir)
                    else
                        print("  ✗ llama.cpp source directory not found: " .. source_dir)
                    end
                end
            end
        else
            print("  ✗ not found")
        end
        print()
        
        -- Check history
        print("History file: " .. HISTORY_FILE)
        if file_exists(HISTORY_FILE) then
            local hist = load_history()
            print("  ✓ exists (" .. #hist .. " entries)")
        else
            print("  - not yet created")
        end
        
    elseif args[1] == "help" or args[1] == "--help" or args[1] == "-h" then
        -- Show help
        print("luaLLM - Local AI Model Manager")
        print()
        print("USAGE:")
        print("  luallm                Interactive picker for recent models")
        print("  luallm list           List all available models (sorted by date)")
        print("  luallm <model>        Run a specific model")
        print("  luallm <model> ...    Run model with custom llama.cpp flags")
        print("  luallm info <model>   Show cached model metadata")
        print("  luallm config         Show config file location")
        print("  luallm rebuild        Rebuild llama.cpp from source")
        print("  luallm clear-history  Clear run history")
        print("  luallm doctor         Run diagnostics")
        print("  luallm help           Show this help message")
        print()
        print("EXAMPLES:")
        print("  luallm                           # Pick from recent models")
        print("  luallm list                      # See all models")
        print("  luallm llama-3-8b                # Run specific model")
        print("  luallm info llama-3-8b           # Show cached metadata")
        print("  luallm info llama-3-8b --raw     # Show raw captured output")
        print("  luallm codellama --port 9090     # Override default port")
        print("  luallm mistral -c 8192           # Override context size")
        print()
        print("CONFIG:")
        print("  Location: " .. CONFIG_FILE)
        print("  Edit to customize model directory, llama.cpp path, defaults, etc.")
        print()
        
    else
        -- Run specific model
        local model_name = args[1]
        local extra_args = {}
        for i = 2, #args do
            table.insert(extra_args, args[i])
        end
        
        run_model(config, model_name, extra_args)
    end
end

-- Run the script with error handling
local ok, err = xpcall(function()
    main(arg)
end, debug.traceback)

if not ok then
    local err_msg = tostring(err)
    if err_msg:match("interrupted") then
        os.exit(130)
    end
    io.stderr:write(err .. "\n")
    os.exit(1)
end
