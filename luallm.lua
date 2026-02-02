#!/usr/bin/env lua

-- Determine script directory for module loading
local script_path = arg[0]
local script_dir = script_path:match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/src/?.lua;" .. 
               script_dir .. "/src/?/init.lua;" .. 
               script_dir .. "/?.lua;" .. 
               package.path

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

-- Load modules
local config = require("config")
local util = require("util")
local format = require("format")
local history = require("history")
local pins = require("pins")
local picker = require("picker")
local resolve = require("resolve")
local model_info = require("model_info")
local notes = require("notes")

-- Main command dispatcher
local function main(args)
    local cfg = config.load_config()
    
    if #args == 0 then
        local selected = picker.show_sectioned_picker(cfg)
        if selected then
            model_info.run_model(cfg, selected, nil)
        end
        
    elseif args[1] == "list" then
        local models = model_info.list_models(cfg.models_dir)
        print("Available models in " .. util.expand_path(cfg.models_dir) .. ":\n")
        format.print_model_list(models, cfg.models_dir, cfg)
        
    elseif args[1] == "info" then
        model_info.handle_info_command(args, cfg)
        
    elseif args[1] == "config" then
        print("Config file: " .. config.CONFIG_FILE)
        print("Edit this file to customize settings.")
        
    elseif args[1] == "rebuild" then
        model_info.rebuild_llama(cfg)
        
    elseif args[1] == "clear-history" then
        history.clear_history()
        print("✓ History cleared")
        
    elseif args[1] == "pin" then
        pins.handle_pin_command(args, cfg)
        
    elseif args[1] == "unpin" then
        pins.handle_unpin_command(args, cfg)
        
    elseif args[1] == "pinned" then
        pins.handle_pinned_command(cfg)
        
    elseif args[1] == "notes" then
        notes.handle_notes_command(args, cfg)
        
    elseif args[1] == "doctor" then
        handle_doctor_command(cfg)
        
    elseif args[1] == "help" or args[1] == "--help" or args[1] == "-h" then
        print_help()
        
    else
        local model_query = args[1]
        local extra_args = {}
        for i = 2, #args do
            table.insert(extra_args, args[i])
        end
        
        local matches, match_type = resolve.find_matching_models(cfg, model_query)
        
        if #matches == 0 then
            print("No model found matching: " .. model_query)
            print()
            print("Available models:")
            local all_models = model_info.list_models(cfg.models_dir)
            local suggestions = {}
            for i = 1, math.min(10, #all_models) do
                local _, size_str, quant, last_run_str = format.get_model_row(cfg, all_models[i].name)
                table.insert(suggestions, {
                    name = all_models[i].name,
                    size_str = size_str,
                    quant = quant,
                    last_run_str = last_run_str
                })
            end
            local max_name, max_size, max_quant = format.calculate_column_widths(suggestions)
            for _, m in ipairs(suggestions) do
                print("  " .. format.format_model_row(m, max_name, max_size, max_quant))
            end
            os.exit(1)
        elseif #matches == 1 then
            model_info.run_model(cfg, matches[1], extra_args)
        else
            print("Multiple models match '" .. model_query .. "':\n")
            local match_models = {}
            for _, name in ipairs(matches) do
                table.insert(match_models, {name = name})
            end
            local selected = picker.show_picker(match_models, cfg, "Select a model (↑/↓ arrows, Enter to confirm, q to quit):")
            if selected then
                model_info.run_model(cfg, selected, extra_args)
            end
        end
    end
end

function handle_doctor_command(cfg)
    print("luaLLM diagnostics")
    print()
    print("Lua version: " .. _VERSION)
    
    local has_cjson = pcall(require, "cjson")
    local has_lfs = pcall(require, "lfs")
    print("lua-cjson: " .. (has_cjson and "✓ installed" or "✗ missing"))
    print("luafilesystem: " .. (has_lfs and "✓ installed" or "✗ missing"))
    print()
    
    print("Config file: " .. config.CONFIG_FILE)
    if util.file_exists(config.CONFIG_FILE) then
        print("  ✓ exists")
        local loaded_cfg, err = util.load_json(config.CONFIG_FILE)
        if err then
            print("  ✗ " .. err)
        else
            print("  ✓ valid JSON")
            
            if loaded_cfg.llama_cpp_path then
                local llama_path = util.expand_path(loaded_cfg.llama_cpp_path)
                if util.file_exists(llama_path) then
                    print("  ✓ llama.cpp binary exists: " .. llama_path)
                else
                    print("  ✗ llama.cpp binary not found: " .. llama_path)
                end
            end
            
            if loaded_cfg.models_dir then
                local models_dir = util.expand_path(loaded_cfg.models_dir)
                if util.is_dir(models_dir) then
                    local models = model_info.list_models(loaded_cfg.models_dir)
                    print("  ✓ models directory exists: " .. models_dir)
                    print("    Found " .. #models .. " model(s)")
                else
                    print("  ✗ models directory not found: " .. models_dir)
                end
            end
        end
    else
        print("  ✗ not found")
    end
    print()
    
    print("History file: " .. history.HISTORY_FILE)
    if util.file_exists(history.HISTORY_FILE) then
        local hist = history.load_history()
        print("  ✓ exists (" .. #hist .. " entries)")
    else
        print("  - not yet created")
    end
end

function print_help()
    print("luaLLM - Local AI Model Manager")
    print()
    print("USAGE:")
    print("  luallm                    Interactive picker for recent models")
    print("  luallm list               List all available models (sorted by date)")
    print("  luallm <model>            Run a specific model")
    print("  luallm <model> ...        Run model with custom llama.cpp flags")
    print("  luallm info [model]       Show cached model metadata (interactive if no model)")
    print("  luallm pin <model>        Pin a model for quick access")
    print("  luallm unpin <model>      Unpin a model")
    print("  luallm pinned             List pinned models")
    print("  luallm notes [model]      Show notes for a model (interactive if no model)")
    print("  luallm notes add <model> <text...>  Add a timestamped note")
    print("  luallm notes edit [model] Edit notes in $EDITOR")
    print("  luallm notes list         List models with notes")
    print("  luallm notes path <model> Show notes file path")
    print("  luallm config             Show config file location")
    print("  luallm rebuild            Rebuild llama.cpp from source")
    print("  luallm clear-history      Clear run history")
    print("  luallm doctor             Run diagnostics")
    print("  luallm help               Show this help message")
    print()
    print("EXAMPLES:")
    print("  luallm                           # Pick from recent models")
    print("  luallm list                      # See all models")
    print("  luallm llama-3-8b                # Run specific model")
    print("  luallm pin codellama             # Pin a model")
    print("  luallm notes add mistral \"great for coding\"  # Add note")
    print("  luallm notes mistral             # View notes")
    print("  luallm notes edit mistral        # Edit notes")
    print("  luallm notes list                # See models with notes")
    print("  luallm pinned                    # See pinned models")
    print("  luallm info                      # Pick model to view info")
    print("  luallm info llama-3-8b           # Show cached metadata")
    print("  luallm info llama-3-8b --kv      # Show structured KV data")
    print("  luallm info llama-3-8b --raw     # Show raw captured output")
    print("  luallm codellama --port 9090     # Override default port")
    print("  luallm mistral -c 8192           # Override context size")
    print()
    print("CONFIG:")
    print("  Location: " .. config.CONFIG_FILE)
    print("  Edit to customize model directory, llama.cpp path, defaults, etc.")
    print()
end

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
