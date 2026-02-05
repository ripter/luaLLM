-- bench.lua
-- Benchmark module for luaLLM using llama-bench with JSON output

local lfs = require("lfs")
local json = require("cjson")
local util = require("util")
local config = require("config")
local resolver = require("resolver")
local format = require("format")
local picker = require("picker")

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
    local safe_name = util.safe_filename(model_name)
    return M.BENCH_DIR .. "/" .. safe_name .. ".json"
end

local function list_models_with_bench_logs()
    ensure_bench_dir()
    local models = {}
    
    if not util.is_dir(M.BENCH_DIR) then
        return {}
    end
    
    for file in lfs.dir(M.BENCH_DIR) do
        if file:match("%.json$") then
            local name = file:gsub("%.json$", "")
            table.insert(models, name)
        end
    end
    
    table.sort(models)
    return models
end

-- ---------------------------------------------------------------------------
-- Runtime info extraction from preamble text
-- ---------------------------------------------------------------------------

-- Extract preamble (text before JSON) and JSON substring
local function extract_preamble_and_json(output)
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
    
    if json_start and json_start > 1 then
        local preamble = output:sub(1, json_start - 1)
        local json_str = output:sub(json_start)
        return preamble, json_str
    else
        return "", output
    end
end

-- Extract runtime signals from preamble text (best-effort)
local function extract_runtime_signals(preamble)
    if not preamble or preamble == "" then
        return {}
    end
    
    local signals = {}
    
    -- Detect backend hints
    if preamble:match("[Mm]etal") then
        signals.backend_hint = "metal"
    elseif preamble:match("CUDA") or preamble:match("cuda") then
        signals.backend_hint = "cuda"
    elseif preamble:match("[Vv]ulkan") then
        signals.backend_hint = "vulkan"
    elseif preamble:match("CPU") or preamble:match("BLAS") then
        signals.backend_hint = "cpu"
    end
    
    -- Extract GPU name if present
    local gpu_line = preamble:match("Metal: ([^\n]+)") or
                     preamble:match("CUDA: ([^\n]+)") or
                     preamble:match("GPU[^:]*: ([^\n]+)")
    if gpu_line then
        signals.gpu_name = gpu_line:match("^%s*(.-)%s*$")  -- trim
    end
    
    -- Look for offload information
    local offload_match = preamble:match("offload[^%d]*(%d+)%s*/%s*(%d+)")
    if offload_match then
        local offloaded, total = preamble:match("offload[^%d]*(%d+)%s*/%s*(%d+)")
        signals.offload = {
            offloaded = tonumber(offloaded),
            total = tonumber(total)
        }
    end
    
    -- Collect warning lines
    local warnings = {}
    for line in preamble:gmatch("[^\n]+") do
        if line:match("[Ww]arning") or 
           line:match("[Ff]ailed") or 
           line:match("not enough") or
           line:match("[Ff]allback") then
            table.insert(warnings, line:match("^%s*(.-)%s*$"))  -- trim
            if #warnings >= 5 then break end  -- cap at 5 warnings
        end
    end
    if #warnings > 0 then
        signals.warnings = warnings
    end
    
    return signals
end

-- Extract test IDs from results array
local function extract_test_ids(results_array)
    local pp_tests = {}
    local tg_tests = {}
    local seen_pp = {}
    local seen_tg = {}
    
    for _, result in ipairs(results_array) do
        local test_name = result.test or result.name or result.id
        
        -- Check if this is a PP or TG test
        local is_pp = result.n_prompt and result.n_prompt > 0 and (not result.n_gen or result.n_gen == 0)
        local is_tg = result.n_gen and result.n_gen > 0
        
        if is_pp then
            -- Use explicit name or infer from n_prompt
            local id = test_name or string.format("pp%d", result.n_prompt)
            if not seen_pp[id] then
                table.insert(pp_tests, id)
                seen_pp[id] = true
            end
        elseif is_tg then
            -- Use explicit name or infer from n_gen
            local id = test_name or string.format("tg%d", result.n_gen)
            if not seen_tg[id] then
                table.insert(tg_tests, id)
                seen_tg[id] = true
            end
        end
    end
    
    return {
        pp = pp_tests,
        tg = tg_tests
    }
end

-- ---------------------------------------------------------------------------
-- JSON parsing from llama-bench
-- ---------------------------------------------------------------------------

local function parse_json_results(output)
    -- llama-bench might print non-JSON lines before the JSON output
    -- Find the actual JSON portion (starts with [ or {)
    local obj_start = output:find("%{")
    local arr_start = output:find("%[")
    local json_start = nil
    local starts_with_array = false
    
    if obj_start and arr_start then
        json_start = math.min(obj_start, arr_start)
        starts_with_array = (arr_start < obj_start)
    elseif obj_start then
        json_start = obj_start
        starts_with_array = false
    elseif arr_start then
        json_start = arr_start
        starts_with_array = true
    end
    
    if json_start then
        output = output:sub(json_start)
    end
    
    local ok, data = pcall(json.decode, output)
    if not ok then
        return nil, "failed to parse JSON: " .. tostring(data)
    end
    
    -- llama-bench JSON can be either an array directly or an object with results
    local results_array
    if type(data) ~= "table" then
        return nil, "JSON root is not a table"
    end
    
    if data.results and type(data.results) == "table" then
        -- Object with results field
        results_array = data.results
    elseif data[1] ~= nil then
        -- Array directly (has numeric index 1)
        results_array = data
    elseif next(data) == nil and starts_with_array then
        -- Empty table that started with [ - it's an empty array
        results_array = data
    else
        -- Non-empty object without results field, or empty object
        return nil, "JSON missing 'results' array and is not an array (no [1])"
    end
    
    if not results_array or type(results_array) ~= "table" then
        return nil, "results is not an array"
    end
    
    local pp_values = {}
    local tg_values = {}
    local reported_threads = nil
    local build_info = {
        commit = data.build_commit,
        number = data.build_number
    }
    
    for _, result in ipairs(results_array) do
        -- Extract test type from result
        -- llama-bench JSON has fields like: test, n_prompt, n_gen, avg_ts (tokens/sec)
        local is_pp = result.n_prompt and result.n_prompt > 0 and (not result.n_gen or result.n_gen == 0)
        local is_tg = result.n_gen and result.n_gen > 0
        
        if result.avg_ts then
            if is_pp then
                table.insert(pp_values, result.avg_ts)
            elseif is_tg then
                table.insert(tg_values, result.avg_ts)
            end
        end
        
        -- Extract threads if available
        if not reported_threads and result.n_threads then
            reported_threads = result.n_threads
        end
    end
    
    return {
        pp_values = pp_values,
        tg_values = tg_values,
        reported_threads = reported_threads,
        build_info = build_info,
        bench_json = data,           -- raw decoded JSON (top-level)
        results_array = results_array  -- normalized results array
    }
end

-- Parse markdown table output (fallback for older llama-bench versions)
local function parse_markdown_table(output)
    local pp_values = {}
    local tg_values = {}
    local reported_threads = nil
    
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
                    local value = tps_col:match("([%d.]+)%s*±")
                    if value then
                        table.insert(pp_values, tonumber(value))
                    end
                elseif test_col:match("^tg%d+") then
                    local value = tps_col:match("([%d.]+)%s*±")
                    if value then
                        table.insert(tg_values, tonumber(value))
                    end
                end
                
                -- Try to extract threads from threads column
                if not reported_threads then
                    for _, col in ipairs(columns) do
                        local t = tonumber(col)
                        if t and t > 0 and t < 256 then  -- reasonable thread count
                            -- This is a heuristic - might be threads
                            if col:match("^%d+$") and #columns > 5 then
                                reported_threads = t
                            end
                        end
                    end
                end
            end
        end
    end
    
    if #pp_values > 0 or #tg_values > 0 then
        return {
            pp_values = pp_values,
            tg_values = tg_values,
            reported_threads = reported_threads,
            build_info = {}
        }
    end
    
    return nil
end

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

-- Aggregate multiple sample arrays into stats
-- Exposed for testing
local function aggregate_samples(pp_values, tg_values)
    return {
        pp = compute_stats(pp_values),
        tg = compute_stats(tg_values)
    }
end

-- ---------------------------------------------------------------------------
-- Run fingerprinting (for detecting incomparable benchmarks)
-- ---------------------------------------------------------------------------

-- Simple FNV-1a 32-bit hash implementation
local function fnv1a_32(str)
    local hash = 2166136261  -- FNV offset basis
    for i = 1, #str do
        -- XOR without bit32 library (portable across Lua versions)
        local byte_val = string.byte(str, i)
        hash = hash ~ byte_val  -- Lua 5.3+ bitwise XOR operator
        hash = (hash * 16777619) % 4294967296  -- FNV prime, keep 32-bit
    end
    return hash
end

-- Create a deterministic fingerprint string from benchmark config
-- Returns: fingerprint_string, details_table
local function create_run_fingerprint(bench_path, argv_template, threads, warmup, build_info)
    local details = {
        llama_bench_path = bench_path,
        argv_template = argv_template,
        threads_requested = threads,
        warmup = warmup,
        build_commit = build_info and build_info.commit or nil,
        build_number = build_info and build_info.number or nil
    }
    
    -- Build canonical string from all config that affects results
    local parts = {
        "bench_path:" .. (details.llama_bench_path or ""),
        "threads:" .. (details.threads_requested or ""),
        "warmup:" .. (details.warmup or ""),
        "argv:" .. table.concat(details.argv_template or {}, " "),
        "build:" .. (details.build_commit or "") .. ":" .. (details.build_number or "")
    }
    
    local canonical = table.concat(parts, "|")
    local hash = fnv1a_32(canonical)
    local fingerprint = string.format("fnv1a32:%08x", hash)
    
    return fingerprint, details
end

-- Create config fingerprint for comparability checking
-- Excludes model-specific fields (model path, model name, etc.)
-- Only includes configuration that affects whether results are comparable
local function create_config_fingerprint(bench_path, threads, warmup, n, build_info)
    local parts = {
        "bench_path:" .. (bench_path or ""),
        "threads:" .. (threads or ""),
        "warmup:" .. (warmup or ""),
        "n:" .. (n or ""),
        "build:" .. (build_info and build_info.commit or "") .. ":" .. (build_info and build_info.number or "")
    }
    
    local canonical = table.concat(parts, "|")
    local hash = fnv1a_32(canonical)
    return string.format("fnv1a32:%08x", hash)
end

-- ---------------------------------------------------------------------------
-- Stats computation
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Benchmark execution
-- ---------------------------------------------------------------------------

local function run_bench_with_json(bench_path, model_path, threads)
    -- Build minimal llama-bench command with r=1 (single rep)
    -- We run this multiple times externally to get N independent samples
    local cmd_parts = {
        util.sh_quote(bench_path),
        "-m", util.sh_quote(model_path),
        "-o", "json",
    }
    
    -- Add threads if specified
    if threads and threads > 0 then
        table.insert(cmd_parts, "-t")
        table.insert(cmd_parts, string.format("%d", threads))
    end
    
    -- Always use r=1 for single sample per invocation
    table.insert(cmd_parts, "-r")
    table.insert(cmd_parts, "1")
    
    local cmd = table.concat(cmd_parts, " ") .. " 2>&1"
    
    local handle = io.popen(cmd)
    if not handle then
        return nil, nil, "failed to run llama-bench"
    end
    
    local output = handle:read("*all")
    local ok, why, code = handle:close()
    
    -- Check exit code first
    local exit_code = util.normalize_exit_code(ok, why, code)
    if exit_code ~= 0 then
        -- Command failed
        local err_msg = string.format("llama-bench exited with code %d", exit_code)
        
        -- Check if it looks like help/usage
        if output:match("^usage:") or output:match("Multiple values can be given") then
            err_msg = err_msg .. " (printed help/usage - check flags compatibility)"
        end
        
        return nil, output, err_msg
    end
    
    -- Extract preamble (text before JSON) for runtime signals
    local preamble, json_only = extract_preamble_and_json(output)
    
    -- Try to parse JSON
    local parsed, err = parse_json_results(json_only)
    if not parsed then
        return nil, output, err
    end
    
    -- Extract single values (we only expect 1 pp and 1 tg from r=1)
    local pp_val = parsed.pp_values[1]
    local tg_val = parsed.tg_values[1]
    
    -- Extract runtime signals from preamble
    local signals = extract_runtime_signals(preamble)
    
    -- Cap preamble length for storage
    local preamble_excerpt = preamble
    if #preamble_excerpt > 4096 then
        preamble_excerpt = preamble_excerpt:sub(1, 4096) .. "...[truncated]"
    end
    
    return {
        pp = pp_val,
        tg = tg_val,
        threads_reported = parsed.reported_threads,
        build_info = parsed.build_info,
        bench_json = parsed.bench_json,
        results_array = parsed.results_array,
        preamble_excerpt = preamble_excerpt,
        signals = signals
    }, output, nil
end

-- ---------------------------------------------------------------------------
-- Main bench command
-- ---------------------------------------------------------------------------

function M.handle_bench_command(args, cfg)
    local subcommand = args[2]
    
    if subcommand == "clear" then
        if util.is_dir(M.BENCH_DIR) then
            local ok, err = util.rm_rf(M.BENCH_DIR)
            if ok then
                print("✓ Cleared bench logs: " .. M.BENCH_DIR)
            else
                print("✗ Failed to clear bench logs: " .. (err or "unknown error"))
                os.exit(1)
            end
        else
            print("No bench logs to clear.")
        end
        return
    end
    
    if subcommand == "show" then
        M.handle_bench_show(args, cfg)
        return
    end
    
    if subcommand == "compare" then
        M.handle_bench_compare(args, cfg)
        return
    end
    
    -- Default: run bench
    if #args < 2 then
        print("Error: Missing model name")
        print("Usage: luallm bench <model> [--n N] [--warmup W] [--threads T]")
        print("       luallm bench show [model]")
        print("       luallm bench compare <modelA> <modelB>")
        print("       luallm bench clear")
        os.exit(1)
    end
    
    local model_query = args[2]
    
    -- Parse flags
    local bench_cfg = cfg.bench or {}
    local n_repeats = bench_cfg.default_n or 5
    local warmup_runs = bench_cfg.default_warmup or 1
    local threads = bench_cfg.default_threads or 8
    
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
        elseif (args[i] == "--threads" or args[i] == "-t") and args[i+1] then
            threads = tonumber(args[i+1])
            if not threads or threads < 1 then
                print("Error: --threads must be a positive integer")
                os.exit(1)
            end
            i = i + 2
        else
            i = i + 1
        end
    end
    
    -- Validate threads
    if not threads or threads < 1 then
        print("Error: Invalid threads value: " .. tostring(threads))
        os.exit(1)
    end
    
    -- Resolve model
    local model_name = resolver.resolve_or_exit(cfg, model_query, {
        title = "Select a model to benchmark (↑/↓ arrows, Enter to confirm, q to quit):"
    })
    
    local model_path = util.expand_path(cfg.models_dir) .. "/" .. model_name .. ".gguf"
    
    if not util.file_exists(model_path) then
        print("Error: Model file not found: " .. model_path)
        os.exit(1)
    end
    
    -- Preflight: ensure bench directory exists and is writable
    ensure_bench_dir()
    if not util.is_dir(M.BENCH_DIR) then
        print("Error: Could not create bench directory: " .. M.BENCH_DIR)
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
    print("  Note: llama-bench uses its own default test sizes")
    print("  Threads: " .. threads)
    print()
    print("Tool: " .. bench_path)
    print()
    
    -- Run warmup
    if warmup_runs > 0 then
        print("Warmup runs...")
        local warmup_failures = 0
        for i = 1, warmup_runs do
            io.write(string.format("  Warmup %d/%d... ", i, warmup_runs))
            io.flush()
            local result, _, err = run_bench_with_json(bench_path, model_path, threads)
            if result and (result.pp or result.tg) then
                io.write("OK\n")
            else
                warmup_failures = warmup_failures + 1
                io.write("FAILED")
                if err then
                    io.write(" (" .. err .. ")")
                end
                io.write("\n")
            end
        end
        
        if warmup_failures == warmup_runs then
            print()
            print("✗ All warmup runs failed. Cannot proceed.")
            print("Try running with --warmup 0 to skip warmup and diagnose the issue.")
            os.exit(1)
        elseif warmup_failures > 0 then
            print()
            print(string.format("⚠ Warning: %d/%d warmup runs failed", warmup_failures, warmup_runs))
        end
        
        print()
    end
    
    -- Run measured benchmarks - N independent runs
    print("Running " .. n_repeats .. " independent benchmark runs...")
    io.flush()
    
    local all_pp_values = {}
    local all_tg_values = {}
    local build_info = nil
    local reported_threads = nil
    local raw_runs = {}  -- Store raw data from each run
    local first_signals = nil  -- Runtime signals from first run
    local first_preamble = nil
    
    for run = 1, n_repeats do
        io.write(string.format("  Run %d/%d... ", run, n_repeats))
        io.flush()
        
        -- Each run calls llama-bench once (with -r 1 for single measurement)
        local result, raw_output, err = run_bench_with_json(bench_path, model_path, threads)
        
        if not result or err then
            print()
            print("✗ Run " .. run .. " failed: " .. (err or "unknown error"))
            if raw_output then
                print()
                print("Last 800 chars of output:")
                local start = math.max(1, #raw_output - 800)
                print(raw_output:sub(start))
            end
            os.exit(1)
        end
        
        -- Collect values from this run
        if result.pp then
            table.insert(all_pp_values, result.pp)
        end
        if result.tg then
            table.insert(all_tg_values, result.tg)
        end
        
        -- Store raw data from this run
        table.insert(raw_runs, {
            bench_json = result.bench_json,
            results_array = result.results_array
        })
        
        -- Capture build info, threads, and runtime signals from first run
        if run == 1 then
            build_info = result.build_info
            reported_threads = result.threads_reported
            first_signals = result.signals
            first_preamble = result.preamble_excerpt
        end
        
        -- Print results for this run
        io.write(string.format("PP=%.1f t/s", result.pp or 0))
        if result.tg then
            io.write(string.format(", TG=%.1f t/s", result.tg))
        end
        io.write("\n")
    end
    
    -- Extract test IDs from first run's results
    local test_ids = {}
    if raw_runs[1] and raw_runs[1].results_array then
        test_ids = extract_test_ids(raw_runs[1].results_array)
    end
    
    -- Compute aggregate stats
    local stats = aggregate_samples(all_pp_values, all_tg_values)
    
    if not stats.pp and not stats.tg then
        print()
        print("✗ No metrics found in benchmark output")
        print()
        print("Diagnostic info:")
        print("  Expected: pp (prompt processing) and/or tg (text generation) tests")
        print("  Found: " .. #all_pp_values .. " pp values, " .. #all_tg_values .. " tg values")
        os.exit(1)
    end
    
    -- Print summary
    print()
    print("Results:")
    if stats.pp then
        print(string.format("  Prompt processing (n=%d):  avg=%.1f  min=%.1f  max=%.1f t/s",
            #all_pp_values, stats.pp.avg, stats.pp.min, stats.pp.max))
    end
    if stats.tg then
        print(string.format("  Token generation (n=%d):   avg=%.1f  min=%.1f  max=%.1f t/s",
            #all_tg_values, stats.tg.avg, stats.tg.min, stats.tg.max))
    end
    
    -- Check threads mismatch
    if reported_threads and reported_threads ~= threads then
        print()
        print(string.format("⚠ Warning: Requested threads=%d, llama-bench reported=%d", 
            threads, reported_threads))
        print("  (check CPU affinity / system limits)")
    end
    
    print()
    
    -- Compute run fingerprint (includes model-specific info)
    local argv_template = {bench_path, "-m", model_path, "-t", tostring(threads), "-r", "1", "-o", "json"}
    local run_fingerprint, fingerprint_details = create_run_fingerprint(
        bench_path, argv_template, threads, warmup_runs, build_info
    )
    
    -- Compute config fingerprint (excludes model-specific info, for comparability)
    local config_fingerprint = create_config_fingerprint(
        bench_path, threads, warmup_runs, n_repeats, build_info
    )
    
    -- Save results
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
            threads_requested = threads,
            threads_reported = reported_threads,
            note = "llama-bench uses default test sizes (typically pp512, tg128)"
        },
        run_fingerprint = run_fingerprint,
        config_fingerprint = config_fingerprint,
        run_fingerprint_details = fingerprint_details,
        run_config = {
            llama_bench_path = bench_path,
            build_info = build_info or {},
            argv_template = argv_template
        },
        results = {
            pp_values = all_pp_values,
            tg_values = all_tg_values
        },
        stats = stats,
        tests = test_ids,  -- Test IDs (pp512, tg128, etc.)
        runtime_info = {
            preamble_excerpt = first_preamble,
            signals = first_signals,
            threads = {
                requested = threads,
                reported = reported_threads
            },
            build_info = build_info
        },
        raw = {
            -- Store all runs if n is small, or just first representative run
            runs = n_repeats <= 5 and raw_runs or {raw_runs[1]}
        }
    }
    
    ensure_bench_dir()
    local log_path = get_bench_log_path(model_name)
    util.save_json(log_path, bench_results)
    
    print("✓ Benchmark complete")
    print("Results saved to: " .. log_path)
end

-- ---------------------------------------------------------------------------
-- bench show command
-- ---------------------------------------------------------------------------

function M.handle_bench_show(args, cfg)
    local model_query = args[3]
    local model_name
    
    if not model_query then
        -- No model specified - show picker of models with bench logs
        local models_with_bench = list_models_with_bench_logs()
        
        if #models_with_bench == 0 then
            print("No benchmark logs found.")
            print("Run 'luallm bench <model>' to create benchmarks.")
            os.exit(0)
        end
        
        local bench_models = {}
        for _, name in ipairs(models_with_bench) do
            table.insert(bench_models, {name = name})
        end
        
        model_name = picker.show_picker(bench_models, cfg, "Select a model to view bench results (↑/↓ arrows, Enter to confirm, q to quit):")
        
        if not model_name then
            os.exit(0)
        end
    else
        -- Model specified - resolve it
        model_name = resolver.resolve_or_exit(cfg, model_query, {
            title = "Select a model to view bench results (↑/↓ arrows, Enter to confirm, q to quit):"
        })
    end
    
    -- Load bench log
    local log_path = get_bench_log_path(model_name)
    local bench_data = util.load_json(log_path)
    
    if not bench_data then
        print("No benchmark results found for: " .. model_name)
        print("Run: luallm bench " .. model_name)
        os.exit(1)
    end
    
    -- Display results
    print()
    print("Benchmark Results: " .. model_name)
    print()
    
    -- Model info
    local _, size_str, quant, last_run_str = format.get_model_row(cfg, model_name)
    print("Model:   " .. model_name)
    print("Size:    " .. (bench_data.gguf_size_bytes and util.format_size(bench_data.gguf_size_bytes) or size_str))
    print("Quant:   " .. quant)
    if bench_data.ran_at then
        print("Tested:  " .. os.date("%Y-%m-%d %H:%M:%S", bench_data.ran_at))
    end
    print()
    
    -- Bench config
    local bc = bench_data.bench_config or {}
    print("Configuration:")
    print("  Repeats:         " .. (bc.n or "?"))
    print("  Warmup:          " .. (bc.warmup or "?"))
    if bc.note then
        print("  " .. bc.note)
    end
    if bc.threads_requested then
        local threads_str = tostring(bc.threads_requested)
        if bc.threads_reported and bc.threads_reported ~= bc.threads_requested then
            threads_str = threads_str .. " (reported: " .. bc.threads_reported .. ")"
        end
        print("  Threads:         " .. threads_str)
    end
    print()
    
    -- Results
    print("Performance:")
    local stats = bench_data.stats or {}
    local results = bench_data.results or {}
    
    if stats.pp then
        local n_samples = results.pp_values and #results.pp_values or "?"
        print(string.format("  Prompt processing (n=%s): avg=%.1f  min=%.1f  max=%.1f t/s",
            tostring(n_samples), stats.pp.avg, stats.pp.min, stats.pp.max))
    else
        print("  Prompt processing: N/A")
    end
    
    if stats.tg then
        local n_samples = results.tg_values and #results.tg_values or "?"
        print(string.format("  Token generation (n=%s):  avg=%.1f  min=%.1f  max=%.1f t/s",
            tostring(n_samples), stats.tg.avg, stats.tg.min, stats.tg.max))
    else
        print("  Token generation:  N/A")
    end
    print()
    
    -- Build info
    if bench_data.run_config and bench_data.run_config.build_info then
        local bi = bench_data.run_config.build_info
        if bi.commit or bi.number then
            print("Build:")
            if bi.commit then print("  Commit: " .. bi.commit) end
            if bi.number then print("  Number: " .. bi.number) end
            print()
        end
    end
end

-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- bench show command
-- ---------------------------------------------------------------------------

-- Format speed ratio as "X.XX×" or "≈same speed"
local function format_speed_ratio(faster_avg, slower_avg)
    if not faster_avg or not slower_avg or slower_avg == 0 then
        return "N/A"
    end
    
    local ratio = faster_avg / slower_avg
    
    -- Within 2% is "same speed"
    if ratio >= 0.98 and ratio <= 1.02 then
        return "≈same speed"
    end
    
    return string.format("%.2f×", ratio)
end

-- Compute winner for comparison
local function compute_winner(stats_a, stats_b, model_a, model_b)
    local result = {
        pp_winner = nil,
        pp_ratio = nil,
        pp_formatted = nil,
        tg_winner = nil,
        tg_ratio = nil,
        tg_formatted = nil,
        overall_winner = nil,
        is_mixed = false
    }
    
    -- PP comparison
    if stats_a.pp and stats_b.pp then
        local pp_a_avg = stats_a.pp.avg
        local pp_b_avg = stats_b.pp.avg
        
        if pp_a_avg > pp_b_avg then
            result.pp_winner = model_a
            result.pp_loser = model_b
            result.pp_ratio = pp_a_avg / pp_b_avg
            result.pp_formatted = format_speed_ratio(pp_a_avg, pp_b_avg)
        else
            result.pp_winner = model_b
            result.pp_loser = model_a
            result.pp_ratio = pp_b_avg / pp_a_avg
            result.pp_formatted = format_speed_ratio(pp_b_avg, pp_a_avg)
        end
    end
    
    -- TG comparison
    if stats_a.tg and stats_b.tg then
        local tg_a_avg = stats_a.tg.avg
        local tg_b_avg = stats_b.tg.avg
        
        if tg_a_avg > tg_b_avg then
            result.tg_winner = model_a
            result.tg_loser = model_b
            result.tg_ratio = tg_a_avg / tg_b_avg
            result.tg_formatted = format_speed_ratio(tg_a_avg, tg_b_avg)
        else
            result.tg_winner = model_b
            result.tg_loser = model_a
            result.tg_ratio = tg_b_avg / tg_a_avg
            result.tg_formatted = format_speed_ratio(tg_b_avg, tg_a_avg)
        end
    end
    
    -- Determine overall winner
    if result.pp_winner and result.tg_winner then
        if result.pp_winner == result.tg_winner then
            result.overall_winner = result.pp_winner
            result.is_mixed = false
        else
            result.is_mixed = true
        end
    elseif result.pp_winner then
        result.overall_winner = result.pp_winner
    elseif result.tg_winner then
        result.overall_winner = result.tg_winner
    end
    
    return result
end

-- Extract environment summary from bench log
local function extract_env_summary(log)
    local summary = {}
    
    -- Backend
    local rt = log.runtime_info or {}
    local signals = rt.signals or {}
    summary.backend = signals.backend_hint or "(unavailable)"
    
    -- GPU
    summary.gpu = signals.gpu_name or "(unavailable)"
    
    -- Build info
    local build = rt.build_info or {}
    if build.commit or build.number then
        summary.build = string.format("%s (build %s)", 
            build.commit or "?", 
            tostring(build.number or "?"))
    else
        summary.build = "(unavailable)"
    end
    
    -- Tests
    local tests = log.tests or {}
    local pp_tests = tests.pp or {}
    local tg_tests = tests.tg or {}
    if #pp_tests > 0 or #tg_tests > 0 then
        local pp_str = #pp_tests > 0 and table.concat(pp_tests, ", ") or "none"
        local tg_str = #tg_tests > 0 and table.concat(tg_tests, ", ") or "none"
        summary.tests = string.format("prompt processing = %s, token generation = %s", pp_str, tg_str)
    else
        summary.tests = "(unavailable)"
    end
    
    -- Extract knobs from first raw result if available
    local raw = log.raw or {}
    local runs = raw.runs or {}
    if runs[1] and runs[1].results_array and runs[1].results_array[1] then
        local first_result = runs[1].results_array[1]
        local knobs = {}
        
        if first_result.n_batch then table.insert(knobs, "n_batch=" .. first_result.n_batch) end
        if first_result.n_ubatch then table.insert(knobs, "n_ubatch=" .. first_result.n_ubatch) end
        if first_result.n_gpu_layers then table.insert(knobs, "n_gpu_layers=" .. first_result.n_gpu_layers) end
        if first_result.split_mode then table.insert(knobs, "split_mode=" .. first_result.split_mode) end
        if first_result.devices then table.insert(knobs, "devices=" .. first_result.devices) end
        
        summary.knobs = #knobs > 0 and table.concat(knobs, ", ") or "(unavailable)"
    else
        summary.knobs = "(unavailable)"
    end
    
    return summary
end

-- Format result line
local function format_result_line(winner_info, config_comparable, config_diffs)
    if not winner_info.pp_winner and not winner_info.tg_winner then
        return "Result: No performance data available for comparison."
    end
    
    local parts = {}
    
    if winner_info.is_mixed then
        table.insert(parts, "Result: Mixed results.")
        
        if winner_info.pp_winner and winner_info.pp_formatted ~= "≈same speed" then
            table.insert(parts, string.format("Prompt processing (PP): %s is %s faster than %s", 
                winner_info.pp_winner, winner_info.pp_formatted, winner_info.pp_loser))
        end
        
        if winner_info.tg_winner and winner_info.tg_formatted ~= "≈same speed" then
            if #parts > 1 then
                parts[#parts] = parts[#parts] .. ","
            end
            table.insert(parts, string.format("but token generation (TG): %s is %s faster than %s", 
                winner_info.tg_winner, winner_info.tg_formatted, winner_info.tg_loser))
        end
    elseif winner_info.overall_winner then
        table.insert(parts, string.format("Result: %s is faster overall.", winner_info.overall_winner))
        
        if winner_info.pp_winner and winner_info.pp_formatted ~= "≈same speed" then
            table.insert(parts, string.format("Prompt processing (PP): %s faster than %s.", 
                winner_info.pp_formatted, winner_info.pp_loser))
        end
        
        if winner_info.tg_winner and winner_info.tg_formatted ~= "≈same speed" then
            table.insert(parts, string.format("Token generation (TG): %s faster.", 
                winner_info.tg_formatted))
        end
    end
    
    -- Add config comparability qualifier
    if config_comparable then
        table.insert(parts, "(Same benchmark config.)")
    else
        if config_diffs and #config_diffs > 0 then
            -- Show top 3 diffs
            local diff_str = table.concat(config_diffs, ", ", 1, math.min(3, #config_diffs))
            table.insert(parts, string.format("(Configs differ: %s — treat with caution.)", diff_str))
        else
            table.insert(parts, "(Configs differ — treat with caution.)")
        end
    end
    
    return table.concat(parts, " ")
end

-- ---------------------------------------------------------------------------
-- bench compare command
-- ---------------------------------------------------------------------------

function M.handle_bench_compare(args, cfg)
    if #args < 4 then
        print("Error: Missing model names")
        print("Usage: luallm bench compare <modelA> <modelB> [--verbose]")
        os.exit(1)
    end
    
    local model_a_query = args[3]
    local model_b_query = args[4]
    
    -- Check for --verbose flag
    local verbose = false
    for i = 5, #args do
        if args[i] == "--verbose" or args[i] == "-v" then
            verbose = true
            break
        end
    end
    
    -- Resolve both models
    local model_a = resolver.resolve_or_exit(cfg, model_a_query, {
        title = "Select first model to compare (↑/↓ arrows, Enter to confirm, q to quit):"
    })
    
    local model_b = resolver.resolve_or_exit(cfg, model_b_query, {
        title = "Select second model to compare (↑/↓ arrows, Enter to confirm, q to quit):"
    })
    
    -- Load bench logs
    local log_a = util.load_json(get_bench_log_path(model_a))
    local log_b = util.load_json(get_bench_log_path(model_b))
    
    if not log_a then
        print("No benchmark results found for: " .. model_a)
        print("Run: luallm bench " .. model_a)
        os.exit(1)
    end
    
    if not log_b then
        print("No benchmark results found for: " .. model_b)
        print("Run: luallm bench " .. model_b)
        os.exit(1)
    end
    
    -- Display comparison
    print()
    print("Benchmark Comparison")
    print()
    
    -- Model headers
    local _, size_a, quant_a = format.get_model_row(cfg, model_a)
    local _, size_b, quant_b = format.get_model_row(cfg, model_b)
    
    print("A: " .. model_a)
    print("   Size: " .. (log_a.gguf_size_bytes and util.format_size(log_a.gguf_size_bytes) or size_a) .. 
          "  Quant: " .. quant_a .. 
          (log_a.ran_at and ("  Tested: " .. os.date("%Y-%m-%d %H:%M", log_a.ran_at)) or ""))
    print()
    print("B: " .. model_b)
    print("   Size: " .. (log_b.gguf_size_bytes and util.format_size(log_b.gguf_size_bytes) or size_b) .. 
          "  Quant: " .. quant_b .. 
          (log_b.ran_at and ("  Tested: " .. os.date("%Y-%m-%d %H:%M", log_b.ran_at)) or ""))
    print()
    
    -- Check config fingerprint compatibility (not run fingerprint!)
    -- Config fingerprint excludes model-specific info, so it only warns
    -- when actual benchmark settings differ (threads, build, etc.)
    local cfg_fp_a = log_a.config_fingerprint
    local cfg_fp_b = log_b.config_fingerprint
    
    if cfg_fp_a and cfg_fp_b and cfg_fp_a ~= cfg_fp_b then
        print("⚠⚠⚠ WARNING: Benchmark configurations differ - comparison may not be valid! ⚠⚠⚠")
        print()
        
        -- Show what differs
        local fpd_a = log_a.run_fingerprint_details or {}
        local fpd_b = log_b.run_fingerprint_details or {}
        local bc_a = log_a.bench_config or {}
        local bc_b = log_b.bench_config or {}
        
        local diffs = {}
        
        if fpd_a.llama_bench_path ~= fpd_b.llama_bench_path then
            table.insert(diffs, "  • llama-bench path: A=" .. (fpd_a.llama_bench_path or "?") .. ", B=" .. (fpd_b.llama_bench_path or "?"))
        end
        
        if bc_a.threads_requested ~= bc_b.threads_requested then
            table.insert(diffs, "  • Threads: A=" .. (bc_a.threads_requested or "?") .. ", B=" .. (bc_b.threads_requested or "?"))
        end
        
        if bc_a.warmup ~= bc_b.warmup then
            table.insert(diffs, "  • Warmup: A=" .. (bc_a.warmup or "?") .. ", B=" .. (bc_b.warmup or "?"))
        end
        
        if bc_a.n ~= bc_b.n then
            table.insert(diffs, "  • Sample count (n): A=" .. (bc_a.n or "?") .. ", B=" .. (bc_b.n or "?"))
        end
        
        -- Check build info
        local build_a = fpd_a.build_commit or (fpd_a.build_info and fpd_a.build_info.commit)
        local build_b = fpd_b.build_commit or (fpd_b.build_info and fpd_b.build_info.commit)
        if build_a and build_b and build_a ~= build_b then
            table.insert(diffs, "  • Build commit: A=" .. build_a .. ", B=" .. build_b)
        end
        
        if #diffs > 0 then
            print("Differences detected:")
            for _, diff in ipairs(diffs) do
                print(diff)
            end
            print()
        end
    end
    
    -- Check runtime info (backend/GPU) differences
    local rt_a = log_a.runtime_info or {}
    local rt_b = log_b.runtime_info or {}
    local sig_a = rt_a.signals or {}
    local sig_b = rt_b.signals or {}
    
    if sig_a.backend_hint and sig_b.backend_hint and sig_a.backend_hint ~= sig_b.backend_hint then
        print("⚠ Backend mismatch detected:")
        print(string.format("  A backend: %s, B backend: %s", sig_a.backend_hint, sig_b.backend_hint))
        print("  (possible GPU offload mismatch - results may not be comparable)")
        print()
    end
    
    -- Check test ID differences
    local tests_a = log_a.tests or {}
    local tests_b = log_b.tests or {}
    
    local function lists_differ(list_a, list_b)
        if #list_a ~= #list_b then return true end
        for i = 1, #list_a do
            if list_a[i] ~= list_b[i] then return true end
        end
        return false
    end
    
    local pp_tests_differ = lists_differ(tests_a.pp or {}, tests_b.pp or {})
    local tg_tests_differ = lists_differ(tests_a.tg or {}, tests_b.tg or {})
    
    if pp_tests_differ or tg_tests_differ then
        print("⚠ Test suites differ:")
        if pp_tests_differ then
            print("  PP tests: A=[" .. table.concat(tests_a.pp or {}, ", ") .. "]")
            print("           B=[" .. table.concat(tests_b.pp or {}, ", ") .. "]")
        end
        if tg_tests_differ then
            print("  TG tests: A=[" .. table.concat(tests_a.tg or {}, ", ") .. "]")
            print("           B=[" .. table.concat(tests_b.tg or {}, ", ") .. "]")
        end
        print("  (different test sets may affect comparability)")
        print()
    end
    
    -- Verbose environment summary (if requested)
    if verbose then
        print("Environment / Config Summary (verbose)")
        print()
        
        local env_a = extract_env_summary(log_a)
        local env_b = extract_env_summary(log_b)
        
        print("A (" .. model_a .. "):")
        print("  • backend: " .. env_a.backend)
        print("  • gpu: " .. env_a.gpu)
        print("  • llama.cpp build: " .. env_a.build)
        print("  • tests: " .. env_a.tests)
        print("  • knobs: " .. env_a.knobs)
        print()
        
        print("B (" .. model_b .. "):")
        print("  • backend: " .. env_b.backend)
        print("  • gpu: " .. env_b.gpu)
        print("  • llama.cpp build: " .. env_b.build)
        print("  • tests: " .. env_b.tests)
        print("  • knobs: " .. env_b.knobs)
        print()
    end
    
    -- Build config diff summary for result line
    local config_diffs = {}
    if cfg_fp_a and cfg_fp_b and cfg_fp_a ~= cfg_fp_b then
        local fpd_a = log_a.run_fingerprint_details or {}
        local fpd_b = log_b.run_fingerprint_details or {}
        local bc_a = log_a.bench_config or {}
        local bc_b = log_b.bench_config or {}
        
        if bc_a.threads_requested ~= bc_b.threads_requested then
            table.insert(config_diffs, string.format("threads (%s vs %s)", 
                tostring(bc_a.threads_requested or "?"), 
                tostring(bc_b.threads_requested or "?")))
        end
        
        local sig_a = (log_a.runtime_info or {}).signals or {}
        local sig_b = (log_b.runtime_info or {}).signals or {}
        if sig_a.backend_hint and sig_b.backend_hint and sig_a.backend_hint ~= sig_b.backend_hint then
            table.insert(config_diffs, string.format("backend (%s vs %s)", sig_a.backend_hint, sig_b.backend_hint))
        end
        
        local build_a = fpd_a.build_commit or (fpd_a.build_info and fpd_a.build_info.commit)
        local build_b = fpd_b.build_commit or (fpd_b.build_info and fpd_b.build_info.commit)
        if build_a and build_b and build_a ~= build_b then
            table.insert(config_diffs, string.format("build (%s vs %s)", 
                build_a:sub(1, 7), build_b:sub(1, 7)))
        end
    end
    
    -- Performance comparison
    print("Performance:")
    print()
    
    local stats_a = log_a.stats or {}
    local stats_b = log_b.stats or {}
    local results_a = log_a.results or {}
    local results_b = log_b.results or {}
    
    -- PP comparison
    if stats_a.pp and stats_b.pp then
        local pp_a = stats_a.pp
        local pp_b = stats_b.pp
        local n_a = results_a.pp_values and #results_a.pp_values or "?"
        local n_b = results_b.pp_values and #results_b.pp_values or "?"
        local delta_abs = pp_b.avg - pp_a.avg
        local delta_pct = (delta_abs / pp_a.avg) * 100
        local ratio = pp_b.avg / pp_a.avg
        
        print(string.format("  PP t/s (A n=%s, B n=%s):", tostring(n_a), tostring(n_b)))
        print(string.format("    A %.1f (%.1f–%.1f)  |  B %.1f (%.1f–%.1f)  |  Δ %+.1f (%+.1f%%)",
            pp_a.avg, pp_a.min, pp_a.max,
            pp_b.avg, pp_b.min, pp_b.max,
            delta_abs, delta_pct))
        
        -- Show ratio if delta is huge
        if math.abs(delta_pct) >= 100 or ratio >= 2.0 or ratio <= 0.5 then
            print(string.format("    (B is %.1f× A)", ratio))
        end
    else
        print("  PP t/s:  N/A")
    end
    
    -- TG comparison
    if stats_a.tg and stats_b.tg then
        local tg_a = stats_a.tg
        local tg_b = stats_b.tg
        local n_a = results_a.tg_values and #results_a.tg_values or "?"
        local n_b = results_b.tg_values and #results_b.tg_values or "?"
        local delta_abs = tg_b.avg - tg_a.avg
        local delta_pct = (delta_abs / tg_a.avg) * 100
        local ratio = tg_b.avg / tg_a.avg
        
        print(string.format("  TG t/s (A n=%s, B n=%s):", tostring(n_a), tostring(n_b)))
        print(string.format("    A %.1f (%.1f–%.1f)  |  B %.1f (%.1f–%.1f)  |  Δ %+.1f (%+.1f%%)",
            tg_a.avg, tg_a.min, tg_a.max,
            tg_b.avg, tg_b.min, tg_b.max,
            delta_abs, delta_pct))
        
        -- Show ratio if delta is huge
        if math.abs(delta_pct) >= 100 or ratio >= 2.0 or ratio <= 0.5 then
            print(string.format("    (B is %.1f× A)", ratio))
        end
    else
        print("  TG t/s:  N/A")
    end
    
    print()
    
    -- Compute and print result line
    local winner_info = compute_winner(stats_a, stats_b, model_a, model_b)
    local config_comparable = (cfg_fp_a and cfg_fp_b and cfg_fp_a == cfg_fp_b)
    local result_line = format_result_line(winner_info, config_comparable, config_diffs)
    print(result_line)
end

-- Expose parse functions and helpers for testing
M._parse_json_for_test = parse_json_results
M._parse_markdown_for_test = parse_markdown_table
M._aggregate_samples_for_test = aggregate_samples
M._fnv1a_32_for_test = fnv1a_32
M._create_run_fingerprint_for_test = create_run_fingerprint
M._create_config_fingerprint_for_test = create_config_fingerprint
M._extract_preamble_and_json_for_test = extract_preamble_and_json
M._extract_runtime_signals_for_test = extract_runtime_signals
M._extract_test_ids_for_test = extract_test_ids
M._format_speed_ratio_for_test = format_speed_ratio
M._compute_winner_for_test = compute_winner
M._extract_env_summary_for_test = extract_env_summary
M._format_result_line_for_test = format_result_line

return M
