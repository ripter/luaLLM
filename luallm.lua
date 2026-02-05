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
local resolver = require("resolver")
local model_info = require("model_info")
local notes = require("notes")
local bench = require("bench")
local doctor = require("doctor")

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
        
    elseif args[1] == "bench" then
        bench.handle_bench_command(args, cfg)
        
    elseif args[1] == "doctor" then
        doctor.run(cfg)
        
    elseif args[1] == "help" or args[1] == "--help" or args[1] == "-h" then
        print_help()
        
    else
        local model_query = args[1]
        local extra_args = {}
        for i = 2, #args do
            table.insert(extra_args, args[i])
        end
        
        local model_name = resolver.resolve_or_exit(cfg, model_query)
        model_info.run_model(cfg, model_name, extra_args)
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
    print("  luallm bench <model>      Benchmark a model with llama-bench")
    print("  luallm bench <model> --n N  Benchmark with N repeats")
    print("  luallm bench <model> --n N --warmup W  Benchmark with warmup runs")
    print("  luallm bench <model> --threads T  Benchmark with T threads")
    print("  luallm bench show [model] View benchmark results")
    print("  luallm bench compare <A> <B>  Compare two model benchmarks")
    print("  luallm bench clear        Clear all benchmark logs")
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
    print("  luallm test               Run all src/*.test.lua tests")
    print("  luallm help               Show this help message")
    print()
    print("EXAMPLES:")
    print("  luallm                           # Pick from recent models")
    print("  luallm list                      # See all models")
    print("  luallm llama-3-8b                # Run specific model")
    print("  luallm bench mistral             # Benchmark model (5 runs, 1 warmup)")
    print("  luallm bench mistral --n 10      # Benchmark with 10 runs")
    print("  luallm bench mistral --n 10 --warmup 2  # 10 runs, 2 warmup")
    print("  luallm bench mistral --threads 16  # Benchmark with 16 threads")
    print("  luallm bench show                # Pick model to view results")
    print("  luallm bench show TheDrummer     # View specific model results")
    print("  luallm bench compare Cydonia Maginum  # Compare two models")
    print("  luallm bench clear               # Clear benchmark logs")
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

-- "test" is handled before main() so it never requires a config file.
if arg[1] == "test" then
    local script_dir = (arg[0]:match("^(.*)/[^/]+$") or ".")
    local test_runner = require("test_runner")
    test_runner.run_all(script_dir .. "/src")
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
