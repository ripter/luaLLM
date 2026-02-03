-- bench.lua
-- Benchmark module for luaLLM using llama-bench

local lfs = require("lfs")
local util = require("util")
local config = require("config")
local resolve = require("resolve")

local M = {}

M.BENCH_DIR = config.CONFIG_DIR .. "/bench"

-- ---------------------------------------------------------------------------
-- Path resolution
-- ---------------------------------------------------------------------------

local function resolve_bench_path(cfg)
    -- Priority 1: Explicit config path
    if cfg.llama_bench_path then
        local path = util.expand_path(cfg.llama_bench_path)
        if util.file_exists(path) then
            return path
        end
    end
    
    -- Priority 2: Derive from llama_cli_path directory
    if cfg.llama_cli_path then
        local cli_path = util.expand_path(cfg.llama_cli_path)
        local bench_path = cli_path:gsub("llama%-cli$", "llama-bench")
        if bench_path ~= cli_path and util.file_exists(bench_path) then
            return bench_path
        end
    end
    
    -- Priority 3: Derive from llama_cpp_path directory
    if cfg.llama_cpp_path then
        local server_path = util.expand_path(cfg.llama_cpp_path)
        local bench_path = server_path:gsub("llama%-server$", "llama-bench")
        if bench_path ~= server_path and util.file_exists(bench_path) then
            return bench_path
        end
    end
    
    -- Priority 4: Derive from source directory
    if cfg.llama_cpp_source_dir then
        local src_dir = util.expand_path(cfg.llama_cpp_source_dir)
        local candidates = {
            src_dir .. "/build/bin/llama-bench",
            src_dir .. "/build/llama-bench",
        }
        for _, path in ipairs(candidates) do
            if util.file_exists(path) then
                return path
            end
        end
    end
    
    return nil
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function ensure_bench_dir()
    util.ensure_dir(M.BENCH_DIR)
end

local function get_bench_log_path(model_name)
    return M.BENCH_DIR .. "/" .. model_name .. ".json"
end

-- ---------------------------------------------------------------------------
-- Metrics parsing
-- ---------------------------------------------------------------------------

local function parse_metrics(output)
    local metrics = {}
    
    -- llama-bench outputs a markdown-style table like:
    -- | model | size | params | backend | threads | n_batch | test | t/s |
    -- | ...   | ...  | ...    | ...     | ...     | ...     | pp2048 | 216.49 ± 0.93 |
    -- | ...   | ...  | ...    | ...     | ...     | ...     | tg256  | 18.46 ± 0.35 |
    --
    -- Or older formats with columns like:
    -- | pp 512 | tg 128 | pl 512 | 1 | pp 1234.56 ± 0.00 | tg 567.89 ± 0.00 |
    
    for line in output:gmatch("[^\n]+") do
        -- New table format: split by | and check last two columns
        if line:find("|") then
            local columns = {}
            for col in line:gmatch("|([^|]*)") do
                local trimmed = col:match("^%s*(.-)%s*$")
                if trimmed and trimmed ~= "" then
                    table.insert(columns, trimmed)
                end
            end
            
            -- Need at least 2 columns: test and t/s
            if #columns >= 2 then
                local test_col = columns[#columns - 1]
                local tps_col = columns[#columns]
                
                -- Check if test_col is pp* or tg*
                if test_col:match("^pp%d+") then
                    -- Parse t/s column: "216.49 ± 0.93" -> 216.49
                    local value = tps_col:match("([%d.]+)%s*±")
                    if value then
                        metrics.pp_tps = tonumber(value)
                    end
                elseif test_col:match("^tg%d+") then
                    local value = tps_col:match("([%d.]+)%s*±")
                    if value then
                        metrics.tg_tps = tonumber(value)
                    end
                end
            end
        end
        
        -- Fallback: older formats
        -- Try: "| pp 1234.56 ± ... |" pattern
        if not metrics.pp_tps then
            local pp_tps = line:match("|%s*pp%s+([%d.]+)%s+±")
            if pp_tps then
                metrics.pp_tps = tonumber(pp_tps)
            end
        end
        
        if not metrics.tg_tps then
            local tg_tps = line:match("|%s*tg%s+([%d.]+)%s+±")
            if tg_tps then
                metrics.tg_tps = tonumber(tg_tps)
            end
        end
        
        -- Fallback: look for patterns like "pp: 1234.56 t/s" or "tg: 567.89 t/s"
        if not metrics.pp_tps then
            local pp = line:match("pp[:%s]+([%d.]+)%s*t/s")
            if pp then metrics.pp_tps = tonumber(pp) end
        end
        
        if not metrics.tg_tps then
            local tg = line:match("tg[:%s]+([%d.]+)%s*t/s")
            if tg then metrics.tg_tps = tonumber(tg) end
        end
    end
    
    return metrics
end

-- Expose for testing
M._parse_metrics_for_test = parse_metrics

-- ---------------------------------------------------------------------------
-- Stats computation
-- ---------------------------------------------------------------------------

local function compute_stats(values)
    if #values == 0 then
        return nil
    end
    
    local sum = 0
    local min_val = values[1]
    local max_val = values[1]
    
    for _, v in ipairs(values) do
        sum = sum + v
        if v < min_val then min_val = v end
        if v > max_val then max_val = v end
    end
    
    return {
        avg = sum / #values,
        min = min_val,
        max = max_val
    }
end

local function aggregate_metrics(runs, metric_key)
    local values = {}
    for _, run in ipairs(runs) do
        if run[metric_key] then
            table.insert(values, run[metric_key])
        end
    end
    return compute_stats(values)
end

-- ---------------------------------------------------------------------------
-- Benchmark execution
-- ---------------------------------------------------------------------------

local function run_single_bench(bench_path, model_path, ctx, gen, batch)
    -- llama-bench takes flags like: -m model.gguf -p 512 -n 256 -b 512
    -- where -p is prompt tokens (ctx), -n is gen tokens, -b is batch
    local cmd_parts = {
        util.sh_quote(bench_path),
        "-m", util.sh_quote(model_path),
        "-p", tostring(ctx),
        "-n", tostring(gen),
        "-b", tostring(batch),
        "-ngl", "999",  -- try to offload everything
    }
    
    local cmd = table.concat(cmd_parts, " ") .. " 2>&1"
    
    local handle = io.popen(cmd)
    if not handle then
        return nil, nil
    end
    
    local output = handle:read("*all")
    handle:close()
    
    return parse_metrics(output), output
end

-- ---------------------------------------------------------------------------
-- Main bench command
-- ---------------------------------------------------------------------------

function M.handle_bench_command(args, cfg)
    if args[2] == "clear" then
        if util.is_dir(M.BENCH_DIR) then
            os.execute("rm -rf " .. util.sh_quote(M.BENCH_DIR))
            print("✓ Cleared bench logs: " .. M.BENCH_DIR)
        else
            print("No bench logs to clear.")
        end
        return
    end
    
    -- Parse args
    if #args < 2 then
        print("Error: Missing model name")
        print("Usage: luallm bench <model> [--n N] [--warmup W] [--ctx C] [--gen G] [--batch B]")
        print("       luallm bench clear")
        os.exit(1)
    end
    
    local model_query = args[2]
    
    -- Parse flags
    local bench_cfg = cfg.bench or {}
    local n_repeats = bench_cfg.default_n or 5
    local warmup_runs = bench_cfg.default_warmup or 1
    local ctx = bench_cfg.default_ctx or 2048
    local gen = bench_cfg.default_gen or 256
    local batch = bench_cfg.default_batch or 512
    
    local i = 3
    while i <= #args do
        if args[i] == "--n" and args[i+1] then
            n_repeats = tonumber(args[i+1])
            if not n_repeats or n_repeats < 1 then
                print("Error: --n must be a positive integer")
                os.exit(1)
            end
            i = i + 2
        elseif args[i] == "--warmup" and args[i+1] then
            warmup_runs = tonumber(args[i+1])
            if not warmup_runs or warmup_runs < 0 then
                print("Error: --warmup must be >= 0")
                os.exit(1)
            end
            i = i + 2
        elseif args[i] == "--ctx" and args[i+1] then
            ctx = tonumber(args[i+1])
            i = i + 2
        elseif args[i] == "--gen" and args[i+1] then
            gen = tonumber(args[i+1])
            i = i + 2
        elseif args[i] == "--batch" and args[i+1] then
            batch = tonumber(args[i+1])
            i = i + 2
        else
            i = i + 1
        end
    end
    
    -- Resolve model
    local matches, match_type = resolve.find_matching_models(cfg, model_query)
    
    if #matches == 0 then
        print("No model found matching: " .. model_query)
        os.exit(1)
    elseif #matches > 1 then
        print("Multiple models match '" .. model_query .. "'. Please be more specific.")
        for _, name in ipairs(matches) do
            print("  " .. name)
        end
        os.exit(1)
    end
    
    local model_name = matches[1]
    local model_path = util.expand_path(cfg.models_dir) .. "/" .. model_name .. ".gguf"
    
    if not util.file_exists(model_path) then
        print("Error: Model file not found: " .. model_path)
        os.exit(1)
    end
    
    -- Resolve llama-bench path
    local bench_path = resolve_bench_path(cfg)
    if not bench_path then
        print("Error: llama-bench not found")
        print()
        print("Please build llama.cpp with llama-bench, or set llama_bench_path in config:")
        print("  " .. config.CONFIG_FILE)
        print()
        print("Example config entry:")
        print('  "llama_bench_path": "/usr/local/bin/llama-bench"')
        os.exit(1)
    end
    
    -- Get model fingerprint
    local model_attr = util.path_attr(model_path)
    local gguf_size = model_attr and model_attr.size or 0
    local gguf_mtime = model_attr and model_attr.modification or 0
    
    print("Benchmarking: " .. model_name)
    print("GGUF: " .. model_path)
    print("Size: " .. util.format_size(gguf_size))
    print()
    print("Settings:")
    print("  Repeats: " .. n_repeats)
    print("  Warmup:  " .. warmup_runs)
    print("  Context: " .. ctx)
    print("  Gen:     " .. gen)
    print("  Batch:   " .. batch)
    print()
    print("Tool: " .. bench_path)
    print()
    
    -- Run warmup
    if warmup_runs > 0 then
        print("Warmup runs...")
        for i = 1, warmup_runs do
            io.write(string.format("  Warmup %d/%d... ", i, warmup_runs))
            io.flush()
            local metrics, _ = run_single_bench(bench_path, model_path, ctx, gen, batch)
            if metrics and (metrics.pp_tps or metrics.tg_tps) then
                io.write("OK\n")
            else
                io.write("FAILED\n")
            end
        end
        print()
    end
    
    -- Run measured benchmarks
    print("Measured runs...")
    local runs = {}
    local all_output = {}
    
    for run_idx = 1, n_repeats do
        io.write(string.format("  Run %d/%d... ", run_idx, n_repeats))
        io.flush()
        
        local metrics, raw_output = run_single_bench(bench_path, model_path, ctx, gen, batch)
        
        if run_idx == 1 then
            -- Save output for debugging
            for line in raw_output:gmatch("[^\n]+") do
                table.insert(all_output, line)
            end
        end
        
        if metrics and (metrics.pp_tps or metrics.tg_tps) then
            table.insert(runs, metrics)
            local pp = metrics.pp_tps and string.format("pp=%.1f", metrics.pp_tps) or "pp=N/A"
            local tg = metrics.tg_tps and string.format("tg=%.1f", metrics.tg_tps) or "tg=N/A"
            io.write(string.format("%s %s t/s\n", pp, tg))
        else
            io.write("FAILED (no metrics)\n")
            -- Show tail of output on first failure
            if run_idx == 1 and raw_output then
                print("  Debug: Last 600 chars of output:")
                local start = math.max(1, #raw_output - 600)
                print("  " .. raw_output:sub(start):gsub("\n", "\n  "))
            end
        end
    end
    
    if #runs == 0 then
        print()
        print("✗ All runs failed. Check llama-bench output above.")
        os.exit(1)
    end
    
    -- Compute stats
    local stats = {
        pp_tps = aggregate_metrics(runs, "pp_tps"),
        tg_tps = aggregate_metrics(runs, "tg_tps")
    }
    
    -- Print summary
    print()
    print("Results:")
    if stats.pp_tps then
        print(string.format("  Prompt processing:  avg=%.1f  min=%.1f  max=%.1f t/s",
            stats.pp_tps.avg, stats.pp_tps.min, stats.pp_tps.max))
    end
    if stats.tg_tps then
        print(string.format("  Token generation:   avg=%.1f  min=%.1f  max=%.1f t/s",
            stats.tg_tps.avg, stats.tg_tps.min, stats.tg_tps.max))
    end
    print()
    
    -- Save results (keep last ~200 lines of output)
    local raw_tail = {}
    local tail_start = math.max(1, #all_output - 200)
    for i = tail_start, #all_output do
        table.insert(raw_tail, all_output[i])
    end
    
    local bench_results = {
        schema_version = 1,
        tool = "llama-bench",
        model_name = model_name,
        gguf_path = model_path,
        gguf_size_bytes = gguf_size,
        gguf_mtime = gguf_mtime,
        ran_at = os.time(),
        bench_config = {
            n = n_repeats,
            warmup = warmup_runs,
            ctx = ctx,
            gen = gen,
            batch = batch
        },
        run_config = {
            llama_bench_path = bench_path,
            argv_template = {bench_path, "-m", model_path, "-p", tostring(ctx), "-n", tostring(gen), "-b", tostring(batch), "-ngl", "999"}
        },
        runs = runs,
        stats = stats,
        raw_tail = raw_tail
    }
    
    ensure_bench_dir()
    local log_path = get_bench_log_path(model_name)
    util.save_json(log_path, bench_results)
    
    print("✓ Benchmark complete")
    print("Results saved to: " .. log_path)
end

return M
