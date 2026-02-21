-- recommend.lua
-- Preset recommendation and management for luaLLM

local util = require("util")
local config = require("config")
local resolver = require("resolver")
local model_info = require("model_info")
local bench = require("bench")

local M = {}

-- Available profiles
M.PROFILES = {"throughput", "cold-start", "context"}

-- For testing: inject custom bench runner
M._bench_runner = nil

-- Get or create models section in config
local function ensure_models_config(cfg)
    if not cfg.models then
        cfg.models = {}
    end
    return cfg.models
end

-- Get or create model entry in config
local function ensure_model_config(cfg, model_name)
    local models = ensure_models_config(cfg)
    if not models[model_name] then
        models[model_name] = {}
    end
    return models[model_name]
end

-- Get or create presets section for a model
local function ensure_presets_config(cfg, model_name)
    local model_cfg = ensure_model_config(cfg, model_name)
    if not model_cfg.presets then
        model_cfg.presets = {}
    end
    return model_cfg.presets
end

-- Save config to file
local function save_config(cfg)
    util.save_json(config.CONFIG_FILE, cfg)
end

-- Determine system capabilities
local function get_system_capabilities()
    local caps = {}
    
    -- Detect Metal (macOS)
    local uname_output = io.popen("uname -s 2>/dev/null"):read("*a") or ""
    caps.has_metal = uname_output:match("Darwin") ~= nil
    
    -- Get CPU thread count
    local thread_count
    if caps.has_metal then
        local sysctl_output = io.popen("sysctl -n hw.ncpu 2>/dev/null"):read("*a") or ""
        thread_count = tonumber(sysctl_output)
    else
        local nproc_output = io.popen("nproc 2>/dev/null"):read("*a") or ""
        thread_count = tonumber(nproc_output)
    end
    caps.cpu_threads = thread_count or 8
    
    return caps
end

-- Choose safe context size for throughput preset
-- Returns {value = number|nil, reason = string}
local function choose_context_for_throughput(model_name, cfg)
    -- Priority A: derived.ctx_runtime from model info
    local info = model_info.load_model_info(model_name)
    if info and info.derived and info.derived.ctx_runtime then
        return {
            value = info.derived.ctx_runtime,
            reason = string.format("reused from model info (ctx_runtime = %d)", info.derived.ctx_runtime)
        }
    end
    
    -- Priority B: context from last run argv
    if info and info.run_config and info.run_config.argv then
        for i, arg in ipairs(info.run_config.argv) do
            if (arg == "-c" or arg == "--ctx-size") and info.run_config.argv[i + 1] then
                local ctx = tonumber(info.run_config.argv[i + 1])
                if ctx then
                    return {
                        value = ctx,
                        reason = string.format("reused from last run (%s %d)", arg, ctx)
                    }
                end
            end
        end
    end
    
    -- Priority C: configured default
    if cfg.default_ctx_size then
        return {
            value = cfg.default_ctx_size,
            reason = string.format("using default (%d)", cfg.default_ctx_size)
        }
    end
    
    -- Priority D: no context (let run defaults apply)
    return {
        value = nil,
        reason = "not set (uses run defaults)"
    }
end

-- Get default thread count from config
local function get_default_threads(cfg, caps)
    -- Priority A: parse cfg.default_params for "-t N"
    if cfg.default_params then
        for _, param in ipairs(cfg.default_params) do
            local threads = param:match("^%-t%s+(%d+)")
            if threads then
                return math.floor(tonumber(threads) + 0.5)
            end
        end
    end
    
    -- Priority B: bench.default_threads
    if cfg.bench and cfg.bench.default_threads then
        local threads = cfg.bench.default_threads
        return math.floor(threads + 0.5)
    end
    
    -- Priority C: CPU threads
    return math.floor(caps.cpu_threads + 0.5)
end

-- Generate candidate configurations for throughput optimization
local function generate_throughput_candidates(cfg, model_name, caps)
    local candidates = {}
    local base_ctx = 2048  -- For benchmarking only
    
    local baseline_threads = get_default_threads(cfg, caps)
    
    -- Thread candidates: {baseline, baseline-2, baseline-4, baseline+2} clamped to [1..cpu_threads]
    local thread_offsets = {0, -2, -4, 2}
    local thread_options = {}
    for _, offset in ipairs(thread_offsets) do
        local t = baseline_threads + offset
        if t >= 1 and t <= caps.cpu_threads then
            local found = false
            for _, existing in ipairs(thread_options) do
                if existing == t then
                    found = true
                    break
                end
            end
            if not found then
                table.insert(thread_options, t)
            end
        end
    end
    
    -- Ensure baseline is included
    local baseline_found = false
    for _, t in ipairs(thread_options) do
        if t == baseline_threads then
            baseline_found = true
            break
        end
    end
    if not baseline_found then
        table.insert(thread_options, 1, baseline_threads)
    end
    
    -- Base flags (common to all candidates)
    local function make_base_flags(threads)
        local flags = {
            "-t", tostring(threads),
            "-b", tostring(base_ctx)  -- -b is batch-size, used as context
        }
        return flags
    end
    
    if caps.has_metal then
        -- Metal candidates
        local ngl = "999"  -- Default GPU offload
        local cache_options = {
            {k = "q8_0", v = "q8_0"},
            {k = "q4_0", v = "q4_0"}
        }
        -- Only test flash=on; flash=off is llama-bench default and may cause issues
        local flash_options = {"1"}  -- Just test with flash enabled
        
        -- Generate all combinations
        for _, threads in ipairs(thread_options) do
            for _, cache in ipairs(cache_options) do
                for _, flash in ipairs(flash_options) do
                    local flags = make_base_flags(threads)
                    table.insert(flags, "-ngl")
                    table.insert(flags, ngl)
                    table.insert(flags, "-ctk")
                    table.insert(flags, cache.k)
                    table.insert(flags, "-ctv")
                    table.insert(flags, cache.v)
                    table.insert(flags, "-fa")
                    table.insert(flags, flash)
                    
                    local flash_label = flash == "1" and "on" or "off"
                    table.insert(candidates, {
                        name = string.format("t=%d cache=%s flash=%s", threads, cache.k, flash_label),
                        flags = flags,
                        flash_bench = flash  -- Keep bench value (0/1) for reference
                    })
                end
            end
        end
    else
        -- Non-Metal: just vary threads
        for _, threads in ipairs(thread_options) do
            local flags = make_base_flags(threads)
            table.insert(candidates, {
                name = string.format("t=%d", threads),
                flags = flags
            })
        end
    end
    
    return candidates
end

-- Run bench for a single candidate (with flag overrides)
local function bench_candidate(bench_path, model_path, extra_flags)
    -- Extract threads from flags
    local threads = nil
    for i, flag in ipairs(extra_flags) do
        if flag == "-t" and extra_flags[i + 1] then
            threads = math.floor(tonumber(extra_flags[i + 1]) + 0.5)
            break
        end
    end
    
    -- Build command - pass through all flags
    local cmd_parts = {
        util.sh_quote(bench_path),
        "-m", util.sh_quote(model_path),
        "-o", "json",
        "-r", "1"  -- Single run
    }
    
    -- Add all extra flags - use simple iteration to avoid double-adding values
    local i = 1
    while i <= #extra_flags do
        local flag = extra_flags[i]
        
        if flag == "-t" or flag == "-b" or flag == "-ngl" then
            -- Numeric flags - ensure integers
            table.insert(cmd_parts, flag)
            if extra_flags[i + 1] then
                local value = tonumber(extra_flags[i + 1])
                if value then
                    table.insert(cmd_parts, tostring(math.floor(value + 0.5)))
                else
                    table.insert(cmd_parts, extra_flags[i + 1])
                end
                i = i + 2  -- Skip value
            else
                i = i + 1
            end
        elseif flag == "-ctk" or flag == "-ctv" or flag == "-fa" then
            -- Flags with values - pass through as-is
            table.insert(cmd_parts, flag)
            if extra_flags[i + 1] then
                table.insert(cmd_parts, extra_flags[i + 1])
                i = i + 2  -- Skip value
            else
                i = i + 1
            end
        else
            -- Standalone flag
            table.insert(cmd_parts, flag)
            i = i + 1
        end
    end
    
    local cmd = table.concat(cmd_parts, " ") .. " 2>&1"
    
    local handle = io.popen(cmd)
    if not handle then
        return nil, "failed to run llama-bench"
    end
    
    local output = handle:read("*all")
    local ok, why, code = handle:close()
    
    -- Check exit code
    local exit_code = util.normalize_exit_code(ok, why, code)
    if exit_code ~= 0 then
        return nil, string.format("llama-bench exited with code %d", exit_code)
    end
    
    -- Parse JSON to get PP and TG
    local obj_start = output:find("%{")
    local arr_start = output:find("%[")
    local json_start = nil
    
    if obj_start and arr_start then
        json_start = math.min(obj_start, arr_start)
    elseif obj_start then
        json_start = obj_start
    elseif arr_start then
        json_start = arr_start
    end
    
    if not json_start then
        return nil, "no JSON found in output"
    end
    
    local json_str = output:sub(json_start)
    local json = require("cjson")
    local ok, data = pcall(json.decode, json_str)
    if not ok then
        return nil, "failed to parse JSON"
    end
    
    -- Extract PP and TG values
    local pp_val, tg_val
    local results_array = data
    if type(data) == "table" and data.results then
        results_array = data.results
    end
    
    for _, result in ipairs(results_array) do
        local is_pp = result.n_prompt and result.n_prompt > 0 and (not result.n_gen or result.n_gen == 0)
        local is_tg = result.n_gen and result.n_gen > 0
        
        if result.avg_ts then
            if is_pp and not pp_val then
                pp_val = result.avg_ts
            elseif is_tg and not tg_val then
                tg_val = result.avg_ts
            end
        end
    end
    
    return {pp = pp_val, tg = tg_val, threads = threads}, nil
end

-- Select best candidate based on TG (primary) and PP (tie-break)
local function select_best_candidate(candidates, results)
    local best_idx = 1
    local best_result = results[1]
    
    for i = 2, #candidates do
        local result = results[i]
        
        -- Skip failed candidates
        if not result then
            goto continue
        end
        
        -- Compare TG first (primary metric)
        if result.tg and best_result.tg then
            if result.tg > best_result.tg then
                best_idx = i
                best_result = result
            elseif result.tg == best_result.tg then
                -- Tie-break with PP
                if result.pp and best_result.pp and result.pp > best_result.pp then
                    best_idx = i
                    best_result = result
                end
            end
        end
        
        ::continue::
    end
    
    return best_idx, best_result
end

-- Generate throughput preset via benchmark sweep
local function recommend_throughput_sweep(cfg, model_name, caps)
    print("Generating candidate configurations...")
    local candidates = generate_throughput_candidates(cfg, model_name, caps)
    print(string.format("Testing %d candidates (this may take a few minutes)...", #candidates))
    print()
    
    -- Get model path
    local model_path = util.expand_path(cfg.models_dir) .. "/" .. model_name .. ".gguf"
    if not util.file_exists(model_path) then
        error("Model file not found: " .. model_path)
    end
    
    -- Get bench path
    local bench_path = util.resolve_bench_path(cfg)
    if not bench_path then
        error("llama-bench not found. Configure llama_bench_path, llama_cli_path, or llama_cpp_source_dir")
    end
    
    -- Run benchmarks
    local results = {}
    local baseline_threads = get_default_threads(cfg, caps)
    local baseline_result = nil
    
    for i, candidate in ipairs(candidates) do
        io.write(string.format("  [%d/%d] %s... ", i, #candidates, candidate.name))
        io.flush()
        
        local result, err
        if M._bench_runner then
            -- Use injected bench runner for testing
            result, err = M._bench_runner(bench_path, model_path, candidate.flags)
        else
            -- Use real bench runner
            result, err = bench_candidate(bench_path, model_path, candidate.flags)
        end
        
        if result then
            results[i] = result
            print(string.format("PP=%.1f t/s, TG=%.1f t/s", result.pp or 0, result.tg or 0))
            
            -- Track baseline (candidate with baseline_threads)
            if result.threads == baseline_threads then
                baseline_result = result
            end
        else
            results[i] = nil
            print("FAILED: " .. (err or "unknown error"))
        end
    end
    
    print()
    
    -- Check if any candidates succeeded
    local any_success = false
    for i = 1, #results do
        if results[i] then
            any_success = true
            break
        end
    end
    
    if not any_success then
        print("✗ All candidates failed. Showing first error for debugging:")
        print()
        
        -- Re-run first candidate to get detailed error output
        local first_candidate = candidates[1]
        local cmd_parts = {
            util.sh_quote(bench_path),
            "-m", util.sh_quote(model_path),
            "-o", "json",
            "-r", "1"
        }
        for _, flag in ipairs(first_candidate.flags) do
            table.insert(cmd_parts, flag)
        end
        local cmd = table.concat(cmd_parts, " ") .. " 2>&1"
        
        print("Command: " .. cmd)
        print()
        
        local handle = io.popen(cmd)
        if handle then
            local output = handle:read("*all")
            handle:close()
            print("Output:")
            print(output)
        end
        
        error("Benchmark sweep failed - all candidates returned errors")
    end
    
    -- Select best candidate
    local best_idx, best_result = select_best_candidate(candidates, results)
    local best_candidate = candidates[best_idx]
    
    if not best_result then
        error("Failed to select best candidate - all results were nil")
    end
    
    print(string.format("✓ Best configuration: %s", best_candidate.name))
    print(string.format("  PP: %.1f t/s", best_result.pp or 0))
    print(string.format("  TG: %.1f t/s", best_result.tg or 0))
    print()
    
    -- Check for improvement over baseline
    if baseline_result and baseline_result.tg then
        local improvement_ratio = best_result.tg / baseline_result.tg
        print(string.format("Baseline (t=%d): TG=%.1f t/s", baseline_threads, baseline_result.tg))
        print(string.format("Improvement: %.1f%%", (improvement_ratio - 1) * 100))
        print()
        
        if improvement_ratio < 1.02 then
            print("✗ No significant improvement found (< 2%)")
            print("Keeping existing configuration")
            return nil, "no improvement"
        end
    end
    
    -- Create preset
    -- Create preset with converted flags for llama-server
    -- llama-bench uses different flag names than llama-server
    local preset_flags = {}
    local i = 1
    while i <= #best_candidate.flags do
        local flag = best_candidate.flags[i]
        local value = best_candidate.flags[i + 1]
        
        if flag == "-b" then
            -- Skip -b from bench flags; we'll add proper context below
            i = i + 2
            goto continue
        elseif flag == "-ctk" then
            -- -ctk -> --cache-type-k
            table.insert(preset_flags, "--cache-type-k")
            table.insert(preset_flags, value)
        elseif flag == "-ctv" then
            -- -ctv -> --cache-type-v
            table.insert(preset_flags, "--cache-type-v")
            table.insert(preset_flags, value)
        elseif flag == "-fa" then
            -- -fa -> --flash-attn, convert 0/1 to on/off
            table.insert(preset_flags, "--flash-attn")
            table.insert(preset_flags, value == "1" and "on" or "off")
        else
            -- Pass through unchanged (-t, -ngl, etc.)
            table.insert(preset_flags, flag)
            if value then
                table.insert(preset_flags, value)
            end
        end
        
        i = i + 2
        ::continue::
    end
    
    -- Determine safe context for this model
    local ctx_choice = choose_context_for_throughput(model_name, cfg)
    local ctx_reason = ctx_choice.reason
    
    -- Add context flag only if we have a safe value
    if ctx_choice.value then
        table.insert(preset_flags, "-c")
        table.insert(preset_flags, tostring(ctx_choice.value))
    end
    
    -- For llama-server, we need both -t and -tb
    -- Find -t value and add -tb with same value
    for i = 1, #preset_flags do
        if preset_flags[i] == "-t" and preset_flags[i + 1] then
            local threads = preset_flags[i + 1]
            table.insert(preset_flags, i + 2, threads)
            table.insert(preset_flags, i + 2, "-tb")
            break
        end
    end
    
    local preset = {
        created_at = os.time(),
        source = "recommend",
        notes = string.format("Optimized for throughput via benchmark sweep (%d candidates tested). Best TG: %.1f t/s. Context: %s", 
            #candidates, best_result.tg or 0, ctx_reason),
        flags = preset_flags
    }
    
    return preset, ctx_reason
end

-- Generate throughput preset (stub that calls sweep)
local function recommend_throughput(cfg, model_name, caps)
    return recommend_throughput_sweep(cfg, model_name, caps)
end

-- Generate cold-start preset (static, derived from model properties)
--
-- Cold-start optimises for minimum time-to-first-token when the model is not
-- already in memory.  llama-bench does not expose load time in its JSON output,
-- so this profile is derived statically from model properties and system caps
-- rather than via a benchmark sweep.
--
-- The main levers are:
--   * Small context (-c): less KV cache to allocate at startup
--   * Fewer GPU layers (-ngl on Metal): less VRAM to allocate and fewer Metal
--     shaders to compile on first load; we use ~50% of layers as a heuristic
--   * No flash attention: avoids additional Metal kernel compilation on load
--   * Standard cache types (f16): no quantisation conversion at load time
--   * Same thread count as throughput (load time is not thread-sensitive)
local function recommend_cold_start(cfg, model_name, caps)
    print("Analysing model for cold-start preset...")
    print()

    -- Load model info if available
    local info = model_info.load_model_info(model_name)
    local kv      = info and info.kv or {}
    local derived = info and info.derived or {}

    -- ── Context size ────────────────────────────────────────────────
    -- Use a small fixed context to minimise KV cache allocation.
    -- 512 is enough for most chat uses and cheap to allocate.
    -- If the model's training context is smaller, clamp to that.
    local cold_ctx = 512
    local ctx_reason
    if derived.ctx_train and derived.ctx_train < cold_ctx then
        cold_ctx = derived.ctx_train
        ctx_reason = string.format(
            "clamped to training context (%d)", derived.ctx_train)
    else
        ctx_reason = string.format(
            "fixed small context (%d) to minimise KV cache allocation", cold_ctx)
    end

    -- ── GPU layers (Metal only) ──────────────────────────────────────
    -- Offloading all layers maximises throughput but requires allocating
    -- all VRAM upfront and compiling every Metal shader on first load.
    -- For cold-start we use ~50% of layers as a balance: inference remains
    -- GPU-accelerated but startup cost is roughly halved.
    local ngl_value = nil
    local ngl_reason
    if caps.has_metal then
        local block_count = kv["llama.block_count"]
        if block_count and type(block_count) == "number" then
            ngl_value = math.floor(block_count * 0.5 + 0.5)
            ngl_reason = string.format(
                "~50%% of %d layers (%d) to reduce Metal shader compilation and VRAM allocation",
                block_count, ngl_value)
        else
            -- No layer count available — use a conservative fixed value
            ngl_value = 16
            ngl_reason = "fixed 16 layers (layer count unavailable; run luallm info to populate)"
        end
    end

    -- ── Thread count ────────────────────────────────────────────────
    -- Load time is not meaningfully affected by thread count.
    -- Use the default so inference after load is still performant.
    local threads = get_default_threads(cfg, caps)

    -- ── Assemble preset flags ────────────────────────────────────────
    local preset_flags = {
        "-t",  tostring(threads),
        "-tb", tostring(threads),   -- batch threads = same as compute threads
        "-c",  tostring(cold_ctx),
    }

    if caps.has_metal and ngl_value then
        table.insert(preset_flags, "-ngl")
        table.insert(preset_flags, tostring(ngl_value))
        -- Explicitly disable flash attention to avoid shader compilation on load
        table.insert(preset_flags, "--flash-attn")
        table.insert(preset_flags, "off")
        -- Use f16 cache types (no quantisation conversion overhead at load time)
        table.insert(preset_flags, "--cache-type-k")
        table.insert(preset_flags, "f16")
        table.insert(preset_flags, "--cache-type-v")
        table.insert(preset_flags, "f16")
    end

    -- ── Build notes ─────────────────────────────────────────────────
    local notes_parts = {
        "Optimised for fast cold-start (minimum time-to-first-token from cold memory).",
        string.format("Context: %s.", ctx_reason),
    }
    if ngl_reason then
        table.insert(notes_parts, string.format("GPU layers: %s.", ngl_reason))
    end
    if caps.has_metal then
        table.insert(notes_parts,
            "Flash attention disabled and f16 cache types used to avoid extra Metal kernel " ..
            "compilation on first load.")
    end
    table.insert(notes_parts,
        "Note: this preset trades peak throughput for faster startup. " ..
        "For sustained performance use the throughput preset.")

    local preset = {
        created_at = os.time(),
        source     = "recommend",
        notes      = table.concat(notes_parts, " "),
        flags      = preset_flags,
    }

    -- ── Print analysis ───────────────────────────────────────────────
    if caps.has_metal and ngl_value then
        print(string.format("  Context:     %d tokens (%s)", cold_ctx, ctx_reason))
        print(string.format("  GPU layers:  %d (%s)", ngl_value, ngl_reason))
        print("  Flash attn:  off (avoids Metal shader compilation)")
        print("  Cache types: f16/f16 (no quantisation conversion overhead)")
        print(string.format("  Threads:     %d", threads))
    else
        print(string.format("  Context:     %d tokens (%s)", cold_ctx, ctx_reason))
        print(string.format("  Threads:     %d", threads))
    end
    print()

    return preset
end

-- Generate context preset (stub for now)
local function recommend_context(cfg, model_name, caps)
    error("context profile not yet implemented - coming soon!")
end

-- Main recommend command handler
function M.handle_recommend_command(args, cfg)
    if #args < 2 then
        print("Error: Missing profile name")
        print("Usage: luallm recommend <profile> [model]")
        print("Profiles: " .. table.concat(M.PROFILES, ", "))
        os.exit(1)
    end
    
    local profile = args[2]
    local model_query = args[3]
    
    -- Validate profile
    local valid_profile = false
    for _, p in ipairs(M.PROFILES) do
        if p == profile then
            valid_profile = true
            break
        end
    end
    
    if not valid_profile then
        print("Error: Unknown profile '" .. profile .. "'")
        print("Available profiles: " .. table.concat(M.PROFILES, ", "))
        os.exit(1)
    end
    
    -- Resolve model (use picker if not specified)
    local model_name
    if model_query then
        model_name = resolver.resolve_or_exit(cfg, model_query, {
            title = "Select model for " .. profile .. " preset (↑/↓ arrows, Enter to confirm, q to quit):"
        })
    else
        -- Use picker
        local picker = require("picker")
        model_name = picker.show_sectioned_picker(cfg)
        if not model_name then
            print("No model selected")
            os.exit(0)
        end
    end
    
    print("Generating " .. profile .. " preset for: " .. model_name)
    print()
    
    -- Get system capabilities
    local caps = get_system_capabilities()
    
    -- Generate recommendation based on profile
    local preset, ctx_reason
    if profile == "throughput" then
        preset, ctx_reason = recommend_throughput(cfg, model_name, caps)
        
        -- Check if no improvement was found
        if not preset and ctx_reason == "no improvement" then
            print("No preset saved (keeping existing configuration)")
            return
        end
    elseif profile == "cold-start" then
        preset = recommend_cold_start(cfg, model_name, caps)
    elseif profile == "context" then
        preset = recommend_context(cfg, model_name, caps)
    else
        error("Unknown profile: " .. profile)
    end
    
    -- Save preset to config
    local presets = ensure_presets_config(cfg, model_name)
    presets[profile] = preset
    save_config(cfg)
    
    -- Print summary
    print("✓ Saved " .. profile .. " preset for " .. model_name)
    print()
    print("Preset flags:")
    for i = 1, #preset.flags, 2 do
        local flag = preset.flags[i]
        local value = preset.flags[i + 1] or ""
        print("  " .. flag .. " " .. value)
    end
    print()
    if ctx_reason then
        print("Context: " .. ctx_reason)
        print()
    end
    if preset.notes then
        print("Notes: " .. preset.notes)
        print()
    end
    print("Saved to: " .. config.CONFIG_FILE)
    print()
    print("Run with: luallm run " .. model_name .. " --preset " .. profile)
end

-- Load preset for a model
function M.load_preset(cfg, model_name, profile)
    if not cfg.models or not cfg.models[model_name] then
        return nil
    end
    
    local model_cfg = cfg.models[model_name]
    if not model_cfg.presets or not model_cfg.presets[profile] then
        return nil
    end
    
    return model_cfg.presets[profile]
end

-- Export for testing
M._choose_context_for_test         = choose_context_for_throughput
M._get_default_threads_for_test    = get_default_threads
M._generate_candidates_for_test    = generate_throughput_candidates
M._select_best_candidate_for_test  = select_best_candidate

return M
