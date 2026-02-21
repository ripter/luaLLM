local lfs = require("lfs")
local json = require("cjson")
local util = require("util")
local config = require("config")
local history = require("history")
local gguf = require("gguf")
local picker = require("picker")

local M = {}

M.MODEL_INFO_DIR = config.CONFIG_DIR .. "/model_info"

local function ensure_model_info_dir()
    util.ensure_dir(M.MODEL_INFO_DIR)
end

local function get_model_info_path(model_name)
    local safe_name = util.safe_filename(model_name)
    return M.MODEL_INFO_DIR .. "/" .. safe_name .. ".json"
end

local function should_capture_line(line)
    local patterns = {
        "^llama_model_loader:",
        "^llama_model_load:",
        "^llama_new_context_with_model:",
        "^llama_kv_cache",
        "^ggml_metal_",
        "^gguf_",
        "^system_info:",
        "^main: "
    }
    
    for _, pattern in ipairs(patterns) do
        if line:match(pattern) then
            return true
        end
    end
    
    if line:match("load time") or line:match(" mem ") or line:match("memory") then
        return true
    end
    
    return false
end

local function sanitize_large_arrays(line)
    local prefix, key, arr_type, count, rest = line:match("^(.-)([%w%.]+)%s+arr%[([^,]+),(%d+)%]%s*=%s*(.*)$")
    
    if prefix and count then
        local num_count = tonumber(count)
        if num_count and num_count > 2048 then
            return prefix .. key .. " arr[" .. arr_type .. "," .. count .. "] = <omitted, " .. count .. " entries>"
        end
    end
    
    return line
end

local function parse_kv_line(line)
    local key, type_str, value_str = line:match("^llama_model_loader:%s*%-?%s*kv%s+%d+:%s*([%w%._%-]+)%s+([%w%[%],]+)%s*=%s*(.+)$")
    
    if not key then
        key, type_str, value_str = line:match("^llama_model_loader:%s*%-?%s*kv%s*:%s*([%w%._%-]+)%s+([%w%[%],]+)%s*=%s*(.+)$")
    end
    
    if not key then
        return nil
    end
    
    value_str = value_str:match("^%s*(.-)%s*$")
    
    if type_str == "u32" or type_str == "i32" or type_str == "u64" or type_str == "i64" then
        local num = tonumber(value_str)
        return key, num
    elseif type_str == "f32" or type_str == "f64" then
        local num = tonumber(value_str)
        return key, num
    elseif type_str == "bool" then
        return key, (value_str == "true")
    elseif type_str == "str" then
        local str = value_str:match('^"(.*)"$') or value_str
        return key, str
    elseif type_str:match("^arr%[") then
        local arr_type, count = type_str:match("arr%[([^,]+),(%d+)%]")
        local num_count = tonumber(count) or 0
        
        if value_str:match("^<omitted") then
            return key, {
                type = "array",
                array_type = arr_type,
                count = num_count,
                note = "omitted"
            }
        end
        
        if value_str:find("%.%.%.") then
            return key, {
                type = "array",
                array_type = arr_type,
                count = num_count,
                note = "truncated_in_output",
                partial = true
            }
        end
        
        if num_count > 2048 then
            return key, {
                type = "array",
                array_type = arr_type,
                count = num_count,
                note = "omitted"
            }
        end
        
        if arr_type == "str" and value_str:match("^%[") then
            local items = {}
            for item in value_str:gmatch('"([^"]*)"') do
                table.insert(items, item)
            end
            if #items > 0 then
                return key, items
            end
        elseif (arr_type == "i32" or arr_type == "u32" or arr_type == "f32") and value_str:match("^%[") then
            local items = {}
            for item in value_str:gmatch("%-?%d+%.?%d*") do
                table.insert(items, tonumber(item))
            end
            if #items > 0 then
                return key, items
            end
        end
        
        return key, {
            type = "array",
            array_type = arr_type,
            count = num_count,
            value = value_str
        }
    end
    
    return key, value_str
end

local function get_model_fingerprint(model_path)
    local attr = util.path_attr(model_path)
    if not attr then
        return nil
    end
    return {
        size = attr.size,
        mtime = attr.modification
    }
end

local function save_model_info(config, model_name, captured_lines, run_config, end_reason, exit_code)
    ensure_model_info_dir()
    
    local model_path = util.expand_path(config.models_dir) .. "/" .. model_name .. ".gguf"
    local fingerprint = get_model_fingerprint(model_path)
    
    if not fingerprint then
        return false
    end
    
    local kv = {}
    for _, line in ipairs(captured_lines) do
        local key, value = parse_kv_line(line)
        if key then
            kv[key] = value
        end
    end
    
    local saw_ctx_line = false
    for _, line in ipairs(captured_lines) do
        if line:find("llama%.context_length") then
            saw_ctx_line = true
            break
        end
    end
    if saw_ctx_line and kv["llama.context_length"] == nil then
        kv["_kv_parse_warning"] = "missing llama.context_length despite being in captured_lines"
    end
    
    local tags_value = kv["general.tags"]
    local needs_full_tags = false
    
    if not tags_value then
        needs_full_tags = true
    elseif type(tags_value) == "table" then
        if tags_value.partial or tags_value.note == "truncated_in_output" then
            needs_full_tags = true
        end
    end
    
    if needs_full_tags then
        local full_tags = gguf.read_gguf_general_tags(model_path)
        if full_tags and #full_tags > 0 then
            kv["general.tags"] = full_tags
        end
    end
    
    local derived = {}
    
    if kv["llama.context_length"] then
        derived.ctx_train = kv["llama.context_length"]
    end
    
    if run_config and run_config.argv then
        for i, arg in ipairs(run_config.argv) do
            if (arg == "-c" or arg == "--ctx-size") and run_config.argv[i+1] then
                derived.ctx_runtime = tonumber(run_config.argv[i+1])
            elseif arg == "--cache-type-k" and run_config.argv[i+1] then
                derived.cache_type_k = run_config.argv[i+1]
            elseif arg == "--cache-type-v" and run_config.argv[i+1] then
                derived.cache_type_v = run_config.argv[i+1]
            end
        end
    end
    
    if derived.ctx_train and derived.ctx_runtime and 
       type(derived.ctx_train) == "number" and type(derived.ctx_runtime) == "number" then
        derived.ctx_ratio = derived.ctx_runtime / derived.ctx_train
    end
    
    for _, line in ipairs(captured_lines) do
        local kv_mib = line:match("llama_kv_cache.*%s(%d+%.%d+)%s*MiB")
        if not kv_mib then
            kv_mib = line:match("llama_kv_cache.*%s(%d+)%s*MiB")
        end
        if kv_mib then
            derived.kv_cache_mib = tonumber(kv_mib)
            break
        end
    end
    
    local final_exit_code = exit_code and tonumber(exit_code) or 0
    
    local info = {
        schema_version = 1,
        model_name = model_name,
        gguf_path = model_path,
        gguf_size_bytes = fingerprint.size,
        gguf_mtime = fingerprint.mtime,
        captured_at = os.time(),
        llama_cpp_path = util.expand_path(config.llama_cpp_path),
        captured_lines = captured_lines,
        kv = kv,
        derived = derived,
        run_config = run_config,
        is_partial = (end_reason ~= "exit" or final_exit_code ~= 0),
        end_reason = end_reason,
        exit_code = final_exit_code
    }
    
    local info_path = get_model_info_path(model_name)
    util.save_json(info_path, info)
    return true
end

function M.load_model_info(model_name)
    local info_path = get_model_info_path(model_name)
    local info = util.load_json(info_path)
    
    if not info then
        return nil, "no_cache"
    end
    
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

function M.list_models(models_dir)
    local models = {}
    models_dir = util.expand_path(models_dir)
    
    if not util.is_dir(models_dir) then
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
    
    table.sort(models, function(a, b)
        return a.mtime > b.mtime
    end)
    
    return models
end

local function find_matching_override(model_name, overrides)
    for pattern, params in pairs(overrides) do
        if model_name:match(pattern) then
            return params
        end
    end
    return nil
end

local function build_llama_command(config, model_name, extra_args, preset_flags)
    local model_path = util.expand_path(config.models_dir) .. "/" .. model_name .. ".gguf"
    
    local argv = {util.expand_path(config.llama_cpp_path), "-m", model_path}
    
    local function add_params(params)
        for _, param in ipairs(params) do
            for arg in param:gmatch("%S+") do
                table.insert(argv, arg)
            end
        end
    end
    
    -- Add default params
    if config.default_params then
        add_params(config.default_params)
    end
    
    -- Add preset flags (if provided)
    if preset_flags then
        for _, flag in ipairs(preset_flags) do
            table.insert(argv, flag)
        end
    end
    
    -- Add model-specific overrides
    local override = find_matching_override(model_name, config.model_overrides or {})
    if override then
        add_params(override)
    end
    
    -- Add extra args (these override everything)
    if extra_args then
        for _, arg in ipairs(extra_args) do
            table.insert(argv, arg)
        end
    end
    
    local quoted_argv = {}
    for i = 1, #argv do
        quoted_argv[i] = util.sh_quote(argv[i])
    end
    
    return table.concat(quoted_argv, " "), argv
end

function M.run_model(config, model_name, extra_args, preset_name)
    local model_path = util.expand_path(config.models_dir) .. "/" .. model_name .. ".gguf"
    
    if not util.file_exists(model_path) then
        print("Error: Model file not found: " .. model_path)
        print()
        print("Available models:")
        local models = M.list_models(config.models_dir)
        local format = require("format")
        format.print_model_list(models, config.models_dir, config)
        os.exit(1)
    end
    
    -- Load preset if specified
    local preset_flags = nil
    if preset_name then
        local recommend = require("recommend")
        local preset = recommend.load_preset(config, model_name, preset_name)
        
        if not preset then
            print("Error: No '" .. preset_name .. "' preset found for " .. model_name)
            print("Run: luallm recommend " .. preset_name .. " " .. model_name)
            os.exit(1)
        end
        
        preset_flags = preset.flags
        print("Using " .. preset_name .. " preset")
        print()
    end
    
    local state = require("state")

    local cmd, argv = build_llama_command(config, model_name, extra_args, preset_flags)
    print("Starting llama.cpp with: " .. model_name)
    print("Command: " .. cmd)
    print()
    
    local run_config = {
        llama_cpp_path = util.expand_path(config.llama_cpp_path),
        argv = argv,
        models_dir = util.expand_path(config.models_dir),
        model_name = model_name,
        extra_args = (extra_args and #extra_args > 0) and extra_args or json.empty_array
    }
    
    for i, arg in ipairs(argv) do
        if arg == "--host" and argv[i+1] then
            run_config.host = argv[i+1]
        elseif arg == "--port" and argv[i+1] then
            run_config.port = tonumber(argv[i+1])
        end
    end
    
    local captured_lines = {}
    local capture_count = 0
    local capture_bytes = 0
    local max_capture_lines = 400
    local max_capture_bytes = 64 * 1024
    local capturing = true
    local pipe = nil
    local info_written = false
    local end_reason = "exit"
    local final_exit_code = 0
    
    local function finalize(opts)
        opts = opts or {}
        
        if pipe then
            pcall(function() pipe:close() end)
        end
        
        end_reason = opts.interrupted and "sigint" or (opts.error and "error" or "exit")
        final_exit_code = opts.exit_code or 0
        
        if #captured_lines > 0 then
            save_model_info(config, model_name, captured_lines, run_config, end_reason, final_exit_code)
        end

        state.mark_stopped(model_name, final_exit_code)
        
        local status = "exited"
        if opts.interrupted then
            status = "interrupted"
        elseif final_exit_code ~= 0 then
            status = "failed"
        end
        
        history.add_to_history(model_name, status, final_exit_code)
    end
    
    history.add_to_history(model_name, "running", nil)
    state.mark_running(model_name, run_config.port)

    local ok, err = xpcall(function()
        pipe = io.popen(cmd .. " 2>&1", "r")
        if not pipe then
            error("Failed to execute command")
        end

        local pid_updated = false
        for line in pipe:lines() do
            print(line)

            -- After the server has had a few lines to bind its port,
            -- attempt a one-shot PID discovery (non-blocking best-effort).
            if not pid_updated and capture_count >= 3 then
                state.try_update_pid(model_name, run_config.port)
                pid_updated = true
            end
            
            if capturing and should_capture_line(line) then
                local sanitized_line = sanitize_large_arrays(line)
                table.insert(captured_lines, sanitized_line)
                capture_count = capture_count + 1
                capture_bytes = capture_bytes + #sanitized_line
                
                if not info_written and #captured_lines >= 10 then
                    save_model_info(config, model_name, captured_lines, run_config, "running", 0)
                    info_written = true
                end
                
                if capture_count >= max_capture_lines or capture_bytes >= max_capture_bytes then
                    capturing = false
                end
            end
        end
        
        local close_ok, reason, code = pipe:close()
        pipe = nil
        local exit_code = util.normalize_exit_code(close_ok, reason, code)
        
        finalize({ exit_code = exit_code, interrupted = false })
        
        if exit_code ~= 0 then
            print(("Error: llama.cpp exited with code %d"):format(exit_code))
            os.exit(exit_code)
        end
        
    end, debug.traceback)
    
    if not ok then
        local err_msg = tostring(err)
        if err_msg:match("interrupted") then
            print()
            print("Interrupted by user")
            finalize({ exit_code = 130, interrupted = true })
            os.exit(130)
        else
            finalize({ exit_code = 1, interrupted = false, reason = "error" })
            error(err)
        end
    end
end

function M.rebuild_llama(config)
    if not config.llama_cpp_source_dir then
        print("Error: llama_cpp_source_dir not set in config")
        os.exit(1)
    end
    
    local source_dir = util.expand_path(config.llama_cpp_source_dir)
    
    if not util.is_dir(source_dir) then
        print("Error: llama.cpp source directory not found: " .. source_dir)
        os.exit(1)
    end
    
    print("Rebuilding llama.cpp...")
    print("Source: " .. source_dir)
    print()
    
    local original_dir = lfs.currentdir()
    lfs.chdir(source_dir)
    
    local cmake_opts = config.cmake_options or {}
    local cmake_cmd = "cmake -B build " .. table.concat(cmake_opts, " ")
    
    print("Running: " .. cmake_cmd)
    local ok, code = util.exec(cmake_cmd)
    if not ok then
        lfs.chdir(original_dir)
        print("Error: cmake failed")
        os.exit(code)
    end
    
    print()
    print("Running: cmake --build build --config Release")
    ok, code = util.exec("cmake --build build --config Release")
    if not ok then
        lfs.chdir(original_dir)
        print("Error: build failed")
        os.exit(code)
    end
    
    lfs.chdir(original_dir)
    print()
    print("✓ Build complete")
end

function M.handle_info_command(args, cfg)
    -- Parse flags and model query separately
    local model_query = nil
    local raw_mode = false
    local show_kv = false
    
    -- Extract flags and model query from args
    for i = 2, #args do
        if args[i] == "--raw" then
            raw_mode = true
        elseif args[i] == "--kv" then
            show_kv = true
        elseif not model_query then
            -- First non-flag argument is the model query
            model_query = args[i]
        end
    end
    
    local model_name
    
    if not model_query then
        -- No model specified - show interactive picker
        ensure_model_info_dir()
        local models_with_info = {}
        
        if util.is_dir(M.MODEL_INFO_DIR) then
            for file in lfs.dir(M.MODEL_INFO_DIR) do
                if file:match("%.json$") then
                    local name = file:gsub("%.json$", "")
                    table.insert(models_with_info, name)
                end
            end
        end
        
        if #models_with_info == 0 then
            print("No cached model info found.")
            print("Run a model once to capture its metadata.")
            os.exit(0)
        end
        
        local info_models = {}
        for _, name in ipairs(models_with_info) do
            table.insert(info_models, {name = name})
        end
        
        local selected = picker.show_picker(info_models, cfg, "Select a model to view info (↑/↓ arrows, Enter to confirm, q to quit):")
        
        if not selected then
            os.exit(0)
        end
        
        model_name = selected
        io.write("\27[2J\27[H")
    else
        -- Model query provided - use resolver
        local resolver = require("resolver")
        model_name = resolver.resolve_or_exit(cfg, model_query, {
            title = "Select a model to view info (↑/↓ arrows, Enter to confirm, q to quit):"
        })
    end
    
    local info, status = M.load_model_info(model_name)
    
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
    
    if info.is_partial then
        local reason_str = info.end_reason == "sigint" and "interrupted by user" or
                         info.end_reason == "error" and "error during run" or
                         "non-zero exit"
        print("⚠ Note: Partial capture (" .. reason_str .. ", exit code: " .. (info.exit_code or "unknown") .. ")")
        print()
    end
    
    if info.kv and info.kv["_kv_parse_warning"] then
        print("⚠ KV Parse Warning: " .. info.kv["_kv_parse_warning"])
        print()
    end
    
    if show_kv then
        print("Structured Model Metadata (KV):")
        print()
        if info.kv and next(info.kv) then
            local keys = {}
            for k in pairs(info.kv) do
                table.insert(keys, k)
            end
            table.sort(keys)
            
            for _, key in ipairs(keys) do
                local value = info.kv[key]
                if type(value) == "table" then
                    if value.type == "array" then
                        print("  " .. key .. ": [array:" .. (value.array_type or "unknown") .. ", count:" .. (value.count or 0) .. "]")
                    else
                        print("  " .. key .. ": " .. json.encode(value))
                    end
                else
                    print("  " .. key .. ": " .. tostring(value))
                end
            end
        else
            print("  (no structured KV data)")
        end
    elseif raw_mode then
        for _, line in ipairs(info.captured_lines) do
            print(line)
        end
    else
        print("Model Info: " .. info.model_name)
        print()
        print("GGUF Path: " .. info.gguf_path)
        print("GGUF Size: " .. info.gguf_size_bytes .. " bytes")
        print("GGUF Modified: " .. os.date("%Y-%m-%d %H:%M:%S", info.gguf_mtime))
        print("Info Captured: " .. os.date("%Y-%m-%d %H:%M:%S", info.captured_at))
        print("llama.cpp: " .. info.llama_cpp_path)
        if info.exit_code then
            print("Exit Code: " .. info.exit_code)
        end
        if info.end_reason then
            print("End Reason: " .. info.end_reason)
        end
        print()
        
        if info.run_config then
            print("Run Configuration:")
            if info.run_config.host then
                print("  Host: " .. info.run_config.host)
            end
            if info.run_config.port then
                print("  Port: " .. info.run_config.port)
            end
            if info.run_config.argv then
                print("  Command: " .. table.concat(info.run_config.argv, " "))
            end
            print()
        end
        
        if info.kv and next(info.kv) then
            print("Key Metadata:")
            local important_keys = {
                "llama.context_length",
                "llama.embedding_length", 
                "llama.block_count",
                "llama.rope.freq_base",
                "general.quantization_version",
                "general.file_type",
                "tokenizer.ggml.model"
            }
            for _, key in ipairs(important_keys) do
                if info.kv[key] then
                    local value = info.kv[key]
                    if type(value) == "table" then
                        print("  " .. key .. ": [complex]")
                    else
                        print("  " .. key .. ": " .. tostring(value))
                    end
                end
            end
            print()
        end
        
        if info.derived and next(info.derived) then
            print("Derived (for tuning):")
            if info.derived.ctx_train then
                print("  Training context: " .. info.derived.ctx_train)
            end
            if info.derived.ctx_runtime then
                print("  Runtime context: " .. info.derived.ctx_runtime)
            end
            if info.derived.ctx_ratio then
                print("  Context ratio: " .. string.format("%.2f", info.derived.ctx_ratio))
            end
            if info.derived.cache_type_k then
                print("  Cache type K: " .. info.derived.cache_type_k)
            end
            if info.derived.cache_type_v then
                print("  Cache type V: " .. info.derived.cache_type_v)
            end
            if info.derived.kv_cache_mib then
                print("  KV cache memory: " .. info.derived.kv_cache_mib .. " MiB")
            end
            print()
        end
        
        print("Captured Metadata (" .. #info.captured_lines .. " lines):")
        print("---")
        for _, line in ipairs(info.captured_lines) do
            print(line)
        end
        print()
        print("Use 'luallm info " .. model_name .. " --kv' to see all structured metadata")
        print("Use 'luallm info " .. model_name .. " --raw' to see raw captured output")
    end
end

return M
