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
local CONFIG_DIR = os.getenv("HOME") .. "/.config/luaLLM"
local CONFIG_FILE = CONFIG_DIR .. "/config.json"
local HISTORY_FILE = CONFIG_DIR .. "/history.json"

-- Utility functions
local function expand_path(path)
    if path:sub(1, 1) == "~" then
        local home = os.getenv("HOME")
        return home .. path:sub(2)
    end
    return path
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
    os.execute("mkdir -p " .. CONFIG_DIR)
end

local function load_json(filepath)
    if not file_exists(filepath) then
        return nil
    end
    local f = io.open(filepath, "r")
    local content = f:read("*all")
    f:close()
    return json.decode(content)
end

local function save_json(filepath, data)
    local f = io.open(filepath, "w")
    f:write(json.encode(data))
    f:close()
end

local function load_config()
    ensure_config_dir()
    local config = load_json(CONFIG_FILE)
    
    if not config then
        -- Check if example config exists next to the script
        local script_dir = arg[0]:match("(.*/)")
        local example_config = script_dir and (script_dir .. "config.example.json") or "config.example.json"
        
        if file_exists(example_config) then
            print("No config found. Creating from example config...")
            os.execute("cp " .. string.format("%q", example_config) .. " " .. string.format("%q", CONFIG_FILE))
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

local function add_to_history(model_name)
    local history = load_history()
    
    -- Remove if already exists (to update timestamp)
    for i, entry in ipairs(history) do
        local name = type(entry) == "string" and entry or entry.name
        if name == model_name then
            table.remove(history, i)
            break
        end
    end
    
    -- Add to front with timestamp
    table.insert(history, 1, {
        name = model_name,
        last_run = os.time()
    })
    
    -- Keep all history, don't limit here
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

local function list_models(models_dir)
    local models = {}
    models_dir = expand_path(models_dir)
    
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
    
    local cmd_parts = {config.llama_cpp_path, "-m", model_path}
    
    -- Add default params
    for _, param in ipairs(config.default_params) do
        table.insert(cmd_parts, param)
    end
    
    -- Check for model-specific overrides
    local override = find_matching_override(model_name, config.model_overrides)
    if override then
        for _, param in ipairs(override) do
            table.insert(cmd_parts, param)
        end
    end
    
    -- Add any extra command-line args
    if extra_args then
        for _, arg in ipairs(extra_args) do
            table.insert(cmd_parts, arg)
        end
    end
    
    return table.concat(cmd_parts, " ")
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
    print("Starting llama.cpp server with: " .. model_name)
    print("Command: " .. cmd)
    print()
    
    -- Only add to history after successful validation
    add_to_history(model_name)
    
    os.execute(cmd)
end

local function rebuild_llama(config)
    local source_dir = expand_path(config.llama_cpp_source_dir)
    
    if not file_exists(source_dir) then
        print("Error: llama.cpp source directory not found: " .. source_dir)
        print("Update 'llama_cpp_source_dir' in your config file: " .. CONFIG_FILE)
        os.exit(1)
    end
    
    print("Rebuilding llama.cpp from: " .. source_dir)
    print()
    
    -- Step 1: Pull latest changes
    print("Pulling latest changes from git...")
    local result = os.execute("cd " .. string.format("%q", source_dir) .. " && git pull")
    if not (result == 0 or result == true) then
        print("Error: git pull failed")
        os.exit(1)
    end
    print()
    
    -- Step 2: Remove old build directory
    print("Cleaning build directory...")
    local build_dir = source_dir .. "/build"
    os.execute("rm -rf " .. string.format("%q", build_dir))
    print()
    
    -- Step 3: Configure with cmake
    print("Configuring build with cmake...")
    local cmake_opts = {}
    if config.cmake_options then
        for _, opt in ipairs(config.cmake_options) do
            table.insert(cmake_opts, opt)
        end
    end
    
    local cmake_cmd = "cd " .. string.format("%q", source_dir) .. " && cmake -S . -B build"
    for _, opt in ipairs(cmake_opts) do
        cmake_cmd = cmake_cmd .. " " .. opt
    end
    
    result = os.execute(cmake_cmd)
    if not (result == 0 or result == true) then
        print("Error: cmake configuration failed")
        os.exit(1)
    end
    print()
    
    -- Step 4: Build
    print("Building (this may take a while)...")
    result = os.execute("cd " .. string.format("%q", source_dir) .. " && cmake --build build -j")
    if not (result == 0 or result == true) then
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
    
    -- Save terminal state
    os.execute("stty -echo -icanon")
    
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
            -- Restore terminal
            os.execute("stty echo icanon")
            io.write("\27[2J\27[H")
            return model_names[selected]
        elseif char == "q" or char == "Q" then
            -- Restore terminal
            os.execute("stty echo icanon")
            io.write("\27[2J\27[H")
            return nil
        end
    end
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
        
    elseif args[1] == "help" or args[1] == "--help" or args[1] == "-h" then
        -- Show help
        print("luaLLM - Local AI Model Manager")
        print()
        print("USAGE:")
        print("  luallm                Interactive picker for recent models")
        print("  luallm list           List all available models (sorted by date)")
        print("  luallm <model>        Run a specific model")
        print("  luallm <model> ...    Run model with custom llama.cpp flags")
        print("  luallm config         Show config file location")
        print("  luallm rebuild        Rebuild llama.cpp from source")
        print("  luallm clear-history  Clear run history")
        print("  luallm help           Show this help message")
        print()
        print("EXAMPLES:")
        print("  luallm                           # Pick from recent models")
        print("  luallm list                      # See all models")
        print("  luallm llama-3-8b                # Run specific model")
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

-- Run the script
main(arg)
