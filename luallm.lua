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
local recommend = require("recommend")
local join = require("join")

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
        
    elseif args[1] == "recommend" then
        recommend.handle_recommend_command(args, cfg)

    elseif args[1] == "join" then
        join.handle_join_command(args, cfg)

    elseif args[1] == "run" then
        -- New explicit run command with --preset support
        if #args < 2 then
            print("Error: Missing model name")
            print("Usage: luallm run <model> [--preset <profile>] [...extra args]")
            os.exit(1)
        end
        
        local model_query = args[2]
        local preset_name = nil
        local extra_args = {}
        
        -- Parse args looking for --preset
        local i = 3
        while i <= #args do
            if args[i] == "--preset" and args[i + 1] then
                preset_name = args[i + 1]
                i = i + 2
            else
                table.insert(extra_args, args[i])
                i = i + 1
            end
        end
        
        local model_name = resolver.resolve_or_exit(cfg, model_query)
        model_info.run_model(cfg, model_name, extra_args, preset_name)
        
    elseif args[1] == "help" or args[1] == "--help" or args[1] == "-h" then
        print_help(args[2])
        
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

-- ---------------------------------------------------------------------------
-- Subcommand help pages
-- ---------------------------------------------------------------------------

local SUBCOMMAND_HELP = {}

SUBCOMMAND_HELP["run"] = function()
    print("luallm run — Run a model with an optional saved preset")
    print()
    print("USAGE:")
    print("  luallm run <model> [--preset <profile>] [extra llama.cpp flags...]")
    print()
    print("  Model name supports fuzzy matching (substring, case-insensitive).")
    print("  The model name must come before any flags.")
    print()
    print("OPTIONS:")
    print("  --preset <profile>   Load saved preset flags for this model.")
    print("                       Any extra flags you pass override the preset.")
    print("                       Profiles: throughput, cold-start, context")
    print()
    print("EXAMPLES:")
    print("  luallm run mistral                          # Run with default settings")
    print("  luallm run mistral --preset throughput      # Run with throughput preset")
    print("  luallm run mistral --preset cold-start      # Run with cold-start preset")
    print("  luallm run mistral --preset throughput -c 8192  # Preset + override context")
    print("  luallm run mistral -c 4096 --port 9090     # Custom flags, no preset")
end

SUBCOMMAND_HELP["bench"] = function()
    print("luallm bench — Benchmark a model using llama-bench")
    print()
    print("USAGE:")
    print("  luallm bench <model> [options]")
    print("  luallm bench show [model]")
    print("  luallm bench compare <model-A> <model-B> [--verbose]")
    print("  luallm bench clear")
    print()
    print("SUBCOMMANDS:")
    print("  <model>              Run a benchmark sweep (5 runs, 1 warmup by default)")
    print("  show [model]         View saved benchmark results (picker if no model given)")
    print("  compare <A> <B>      Compare results for two models side by side")
    print("  clear                Delete all saved benchmark logs")
    print()
    print("OPTIONS (for bench <model>):")
    print("  --n <N>              Number of benchmark runs  (default: 5)")
    print("  --warmup <W>         Warmup runs before measuring  (default: 1)")
    print("  --threads <T>        Thread count to benchmark at")
    print()
    print("OPTIONS (for bench compare):")
    print("  --verbose            Include hardware and build environment details")
    print()
    print("EXAMPLES:")
    print("  luallm bench mistral                        # 5 runs, 1 warmup")
    print("  luallm bench mistral --n 10                 # 10 runs")
    print("  luallm bench mistral --n 10 --warmup 2      # 10 runs, 2 warmup")
    print("  luallm bench mistral --threads 8            # Benchmark at 8 threads")
    print("  luallm bench show                           # Pick model to view results")
    print("  luallm bench show TheDrummer                # View specific model")
    print("  luallm bench compare Cydonia Maginum        # Compare two models")
    print("  luallm bench compare Cydonia Maginum --verbose")
    print("  luallm bench clear                          # Wipe all benchmark logs")
end

SUBCOMMAND_HELP["recommend"] = function()
    print("luallm recommend — Generate optimised run presets for a model")
    print()
    print("USAGE:")
    print("  luallm recommend <profile> [model]")
    print()
    print("  Presets are saved to config and applied with: luallm run <model> --preset <profile>")
    print("  Model name supports fuzzy matching. Picker shown if omitted.")
    print()
    print("PROFILES:")
    print("  throughput    Benchmark sweep to find the flags that maximise token/s.")
    print("                Tests combinations of thread counts, KV cache types, and")
    print("                flash attention. Saves the best result as a preset.")
    print()
    print("  cold-start    Static preset optimised for fast model load time.")
    print("                Uses a small context, reduced GPU layers (Metal), and")
    print("                disables flash attention to minimise startup cost.")
    print()
    print("  context       (not yet implemented)")
    print()
    print("EXAMPLES:")
    print("  luallm recommend throughput mistral         # Sweep and save best preset")
    print("  luallm recommend throughput                 # Pick model interactively")
    print("  luallm recommend cold-start mistral         # Generate cold-start preset")
    print("  luallm run mistral --preset throughput      # Use the saved preset")
end

SUBCOMMAND_HELP["notes"] = function()
    print("luallm notes — Attach freeform notes to a model")
    print()
    print("USAGE:")
    print("  luallm notes [model]")
    print("  luallm notes add <model> <text...>")
    print("  luallm notes edit [model]")
    print("  luallm notes list")
    print("  luallm notes path <model>")
    print()
    print("SUBCOMMANDS:")
    print("  [model]              View notes for a model (picker if omitted)")
    print("  add <model> <text>   Append a timestamped note")
    print("  edit [model]         Open notes file in $EDITOR (picker if omitted)")
    print("  list                 List all models that have notes")
    print("  path <model>         Print the path to the notes file")
    print()
    print("EXAMPLES:")
    print("  luallm notes mistral                        # View notes")
    print("  luallm notes add mistral \"great for coding\" # Add a note")
    print("  luallm notes edit mistral                   # Edit in $EDITOR")
    print("  luallm notes list                           # See all annotated models")
end

SUBCOMMAND_HELP["info"] = function()
    print("luallm info — Show cached metadata for a model")
    print()
    print("USAGE:")
    print("  luallm info [model] [--kv] [--raw]")
    print()
    print("  Metadata is captured the first time a model is run and cached locally.")
    print("  Picker shown if no model name is given.")
    print()
    print("OPTIONS:")
    print("  --kv     Show the structured GGUF key-value pairs")
    print("  --raw    Show the raw captured llama.cpp output")
    print()
    print("EXAMPLES:")
    print("  luallm info                     # Pick model interactively")
    print("  luallm info mistral             # Show summary")
    print("  luallm info mistral --kv        # Show GGUF KV data")
    print("  luallm info mistral --raw       # Show raw captured output")
end

SUBCOMMAND_HELP["join"] = function()
    print("luallm join — Merge multi-part GGUF files into a single file")
    print()
    print("USAGE:")
    print("  luallm join [query]")
    print()
    print("  Scans your models directory for files matching the multi-part naming")
    print("  convention and merges them using llama-gguf-split --merge.")
    print("  If multiple models are found, an interactive picker is shown.")
    print()
    print("  Multi-part files look like:")
    print("    ModelName-00001-of-00003.gguf")
    print("    ModelName-00002-of-00003.gguf")
    print("    ModelName-00003-of-00003.gguf")
    print("  Output: ModelName.gguf  (same directory)")
    print()
    print("  Requires llama-gguf-split, which ships with llama.cpp.")
    print("  It is found automatically if llama_cpp_path is configured.")
    print("  You can also set llama_gguf_split_path explicitly in config.")
    print()
    print("EXAMPLES:")
    print("  luallm join                     # Find and merge any multi-part GGUFs")
    print("  luallm join llama-405b          # Merge a specific model by name")
end

SUBCOMMAND_HELP["pin"] = function()
    print("luallm pin / unpin / pinned — Pin models for quick access")
    print()
    print("USAGE:")
    print("  luallm pin <model>")
    print("  luallm unpin <model>")
    print("  luallm pinned")
    print()
    print("  Pinned models appear at the top of the interactive picker.")
    print()
    print("EXAMPLES:")
    print("  luallm pin mistral              # Pin a model")
    print("  luallm unpin mistral            # Unpin a model")
    print("  luallm pinned                   # List all pinned models")
end

-- ---------------------------------------------------------------------------
-- Top-level help
-- ---------------------------------------------------------------------------

function print_help(subcommand)
    -- Subcommand detail page
    if subcommand and SUBCOMMAND_HELP[subcommand] then
        print()
        SUBCOMMAND_HELP[subcommand]()
        print()
        return
    end

    -- Unknown subcommand passed to help
    if subcommand then
        print("No detailed help available for '" .. subcommand .. "'.")
        print()
    end

    print("luaLLM — Local LLM manager")
    print()
    print("USAGE:  luallm <command> [args...]")
    print("        luallm help <command>   Show detailed help for a command")
    print()
    print("RUNNING MODELS:")
    print("  luallm                  Interactive picker (most-recent first)")
    print("  luallm <model>          Run a model  (fuzzy name match)")
    print("  luallm run <model>      Run with optional --preset flag")
    print()
    print("MODEL MANAGEMENT:")
    print("  luallm list             List all models")
    print("  luallm info [model]     Show cached metadata")
    print("  luallm join [query]     Merge multi-part GGUF files")
    print("  luallm pin/unpin        Pin models for quick picker access")
    print("  luallm notes            Attach notes to a model")
    print()
    print("BENCHMARKING & PRESETS:")
    print("  luallm bench <model>    Benchmark with llama-bench")
    print("  luallm recommend        Generate optimised run presets")
    print()
    print("UTILITIES:")
    print("  luallm doctor           Run configuration diagnostics")
    print("  luallm config           Show config file location")
    print("  luallm rebuild          Rebuild llama.cpp from source")
    print("  luallm clear-history    Clear run history")
    print("  luallm test             Run test suite")
    print()
    print("DETAILED HELP:")
    print("  luallm help run         Running models with presets and flags")
    print("  luallm help bench       Benchmarking and comparing models")
    print("  luallm help recommend   Generating optimised presets")
    print("  luallm help notes       Attaching notes to models")
    print("  luallm help info        Viewing model metadata")
    print("  luallm help join        Merging multi-part GGUF files")
    print("  luallm help pin         Pinning models")
    print()
    print("Config: " .. config.CONFIG_FILE)
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
