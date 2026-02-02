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
local PINS_FILE = CONFIG_DIR .. "/pins.json"
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

local function get_recent_models(config, exclude_set, limit)
    -- Returns up to 'limit' recent models, excluding any in exclude_set
    -- exclude_set is a table where keys are model names to exclude
    local history = load_history()
    exclude_set = exclude_set or {}
    limit = limit or (config.recent_models_count or 4)
    
    local recent = {}
    local seen = {}
    
    for _, entry in ipairs(history) do
        local name = type(entry) == "string" and entry or entry.name
        
        -- Skip if excluded or already seen
        if not exclude_set[name] and not seen[name] then
            table.insert(recent, entry)
            seen[name] = true
            
            if #recent >= limit then
                break
            end
        end
    end
    
    return recent
end

local function clear_history()
    save_history({})
end

-- Pins management
local function load_pins()
    if not file_exists(PINS_FILE) then
        return {}
    end
    
    local pins, err = load_json(PINS_FILE)
    if err or type(pins) ~= "table" then
        io.stderr:write("Warning: Invalid pins file, treating as empty\n")
        return {}
    end
    
    return pins
end

local function save_pins(pins)
    save_json(PINS_FILE, pins)
end

local function is_pinned(model_name)
    local pins = load_pins()
    for _, pin in ipairs(pins) do
        if pin == model_name then
            return true
        end
    end
    return false
end

local function add_pin(model_name)
    local pins = load_pins()
    
    -- Check if already pinned
    for _, pin in ipairs(pins) do
        if pin == model_name then
            return false -- Already pinned
        end
    end
    
    -- Add to end
    table.insert(pins, model_name)
    save_pins(pins)
    return true
end

local function remove_pin(model_name)
    local pins = load_pins()
    
    for i, pin in ipairs(pins) do
        if pin == model_name then
            table.remove(pins, i)
            save_pins(pins)
            return true
        end
    end
    
    return false -- Not pinned
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
    
    -- Also capture lines with load time or memory info
    if line:match("load time") or line:match(" mem ") or line:match("memory") then
        return true
    end
    
    return false
end

local function sanitize_large_arrays(line)
    -- Replace massive tokenizer arrays with placeholders
    -- Match pattern: "key arr[type,count] = [...]"
    -- If count > 2048, replace entire value with clean placeholder
    
    local prefix, key, arr_type, count, rest = line:match("^(.-)([%w%.]+)%s+arr%[([^,]+),(%d+)%]%s*=%s*(.*)$")
    
    if prefix and count then
        local num_count = tonumber(count)
        if num_count and num_count > 2048 then
            -- Fully omit large arrays with clean placeholder
            return prefix .. key .. " arr[" .. arr_type .. "," .. count .. "] = <omitted, " .. count .. " entries>"
        end
    end
    
    return line
end

local function parse_kv_line(line)
    -- Parse lines like: "llama_model_loader: - kv  32: llama.block_count u32 = 40"
    -- Returns: key, value
    
    -- More robust pattern - allow underscores, dashes in keys
    local key, type_str, value_str = line:match("^llama_model_loader:%s*%-?%s*kv%s+%d+:%s*([%w%._%-]+)%s+([%w%[%],]+)%s*=%s*(.+)$")
    
    -- Try without index number as fallback
    if not key then
        key, type_str, value_str = line:match("^llama_model_loader:%s*%-?%s*kv%s*:%s*([%w%._%-]+)%s+([%w%[%],]+)%s*=%s*(.+)$")
    end
    
    if not key then
        return nil
    end
    
    -- Trim whitespace from value_str
    value_str = value_str:match("^%s*(.-)%s*$")
    
    -- Handle different types
    if type_str == "u32" or type_str == "i32" or type_str == "u64" or type_str == "i64" then
        local num = tonumber(value_str)
        return key, num
    elseif type_str == "f32" or type_str == "f64" then
        local num = tonumber(value_str)
        return key, num
    elseif type_str == "bool" then
        return key, (value_str == "true")
    elseif type_str == "str" then
        -- Remove quotes if present
        local str = value_str:match('^"(.*)"$') or value_str
        return key, str
    elseif type_str:match("^arr%[") then
        -- Handle arrays
        local arr_type, count = type_str:match("arr%[([^,]+),(%d+)%]")
        local num_count = tonumber(count) or 0
        
        -- Check if value is the omitted placeholder
        if value_str:match("^<omitted") then
            return key, {
                type = "array",
                array_type = arr_type,
                count = num_count,
                note = "omitted"
            }
        end
        
        -- Check for truncation with "..."
        if value_str:find("%.%.%.") then
            return key, {
                type = "array",
                array_type = arr_type,
                count = num_count,
                note = "truncated_in_output",
                partial = true
            }
        end
        
        -- For large arrays (>2048), should already be omitted by sanitize_large_arrays
        if num_count > 2048 then
            return key, {
                type = "array",
                array_type = arr_type,
                count = num_count,
                note = "omitted"
            }
        end
        
        -- For small arrays, try to parse the actual values
        if arr_type == "str" and value_str:match("^%[") then
            -- String array - parse into Lua array
            local items = {}
            for item in value_str:gmatch('"([^"]*)"') do
                table.insert(items, item)
            end
            if #items > 0 then
                return key, items
            end
        elseif (arr_type == "i32" or arr_type == "u32" or arr_type == "f32") and value_str:match("^%[") then
            -- Numeric array - parse into Lua array
            local items = {}
            for item in value_str:gmatch("%-?%d+%.?%d*") do
                table.insert(items, tonumber(item))
            end
            if #items > 0 then
                return key, items
            end
        end
        
        -- Fallback: store as string with type info
        return key, {
            type = "array",
            array_type = arr_type,
            count = num_count,
            value = value_str
        }
    end
    
    -- Unknown type - store as string
    return key, value_str
end

local function get_model_info_path(model_name)
    return MODEL_INFO_DIR .. "/" .. model_name .. ".json"
end

-- Minimal GGUF reader for extracting general.tags
local function read_u32_le(file)
    local bytes = file:read(4)
    if not bytes or #bytes ~= 4 then return nil end
    local b1, b2, b3, b4 = bytes:byte(1, 4)
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function read_u64_le(file)
    local bytes = file:read(8)
    if not bytes or #bytes ~= 8 then return nil end
    local b1, b2, b3, b4, b5, b6, b7, b8 = bytes:byte(1, 8)
    -- Lua 5.1/5.2/5.3 safe: build up to 53-bit precision
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216 + 
           b5 * 4294967296 + b6 * 1099511627776 + 
           b7 * 281474976710656 + b8 * 72057594037927936
end

local function read_gguf_string(file)
    local len = read_u64_le(file)
    if not len then return nil end
    if len == 0 then return "" end
    if len > 1000000 then -- Safety: don't allocate huge strings
        file:seek("cur", len) -- Skip
        return nil
    end
    return file:read(len)
end

local function skip_gguf_value(file, type_id)
    -- GGUF type IDs (from spec)
    -- 0=UINT8, 1=INT8, 2=UINT16, 3=INT16, 4=UINT32, 5=INT32, 
    -- 6=FLOAT32, 7=BOOL, 8=STRING, 9=ARRAY, 10=UINT64, 11=INT64, 12=FLOAT64
    
    if type_id == 0 or type_id == 1 then -- UINT8/INT8
        file:read(1)
    elseif type_id == 2 or type_id == 3 then -- UINT16/INT16
        file:read(2)
    elseif type_id == 4 or type_id == 5 then -- UINT32/INT32
        file:read(4)
    elseif type_id == 6 then -- FLOAT32
        file:read(4)
    elseif type_id == 7 then -- BOOL
        file:read(1)
    elseif type_id == 8 then -- STRING
        read_gguf_string(file)
    elseif type_id == 10 or type_id == 11 then -- UINT64/INT64
        file:read(8)
    elseif type_id == 12 then -- FLOAT64
        file:read(8)
    elseif type_id == 9 then -- ARRAY
        local elem_type = read_u32_le(file)
        local count = read_u64_le(file)
        if not elem_type or not count then return false end
        
        -- Skip array elements
        for i = 1, count do
            skip_gguf_value(file, elem_type)
        end
    else
        return false -- Unknown type
    end
    return true
end

local function read_gguf_array(file, type_id)
    -- Only handles ARRAY type
    if type_id ~= 9 then return nil end
    
    local elem_type = read_u32_le(file)
    local count = read_u64_le(file)
    if not elem_type or not count then return nil end
    
    -- Only parse string arrays
    if elem_type == 8 then -- STRING
        local strings = {}
        for i = 1, count do
            local s = read_gguf_string(file)
            if s then
                table.insert(strings, s)
            else
                return nil -- Failed to read element
            end
        end
        return strings
    end
    
    return nil
end

local function read_gguf_general_tags(gguf_path)
    local file = io.open(gguf_path, "rb")
    if not file then return nil end
    
    local ok, result = pcall(function()
        -- Read header
        local magic = read_u32_le(file)
        if not magic or magic ~= 0x46554747 then -- "GGUF" in little-endian
            return nil
        end
        
        local version = read_u32_le(file)
        if not version or version < 2 then -- Need v2+
            return nil
        end
        
        local n_tensors = read_u64_le(file)
        local n_kv = read_u64_le(file)
        if not n_tensors or not n_kv then return nil end
        
        -- Read KV pairs, looking for general.tags
        for i = 1, n_kv do
            local key = read_gguf_string(file)
            if not key then return nil end
            
            local type_id = read_u32_le(file)
            if not type_id then return nil end
            
            if key == "general.tags" then
                -- Found it! Read the array
                return read_gguf_array(file, type_id)
            else
                -- Skip this value
                if not skip_gguf_value(file, type_id) then
                    return nil
                end
            end
        end
        
        return nil -- Didn't find general.tags
    end)
    
    file:close()
    
    if ok then
        return result
    else
        return nil
    end
end

local function save_model_info(config, model_name, captured_lines, run_config, end_reason, exit_code)
    ensure_model_info_dir()
    
    local model_path = expand_path(config.models_dir) .. "/" .. model_name .. ".gguf"
    local fingerprint = get_model_fingerprint(model_path)
    
    if not fingerprint then
        return false
    end
    
    -- Parse KV lines into structured dictionary
    local kv = {}
    for _, line in ipairs(captured_lines) do
        local key, value = parse_kv_line(line)
        if key then
            kv[key] = value
        end
    end
    
    -- Self-check: verify critical keys were parsed
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
    
    -- Populate full general.tags from GGUF file if captured version is partial/truncated
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
        local full_tags = read_gguf_general_tags(model_path)
        if full_tags and #full_tags > 0 then
            kv["general.tags"] = full_tags
        end
    end
    
    -- Build derived fields for tuning
    local derived = {}
    
    -- Extract training context from KV
    if kv["llama.context_length"] then
        derived.ctx_train = kv["llama.context_length"]
    end
    
    -- Extract runtime context from run args
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
    
    -- Compute context ratio if both are available and numeric
    if derived.ctx_train and derived.ctx_runtime and 
       type(derived.ctx_train) == "number" and type(derived.ctx_runtime) == "number" then
        derived.ctx_ratio = derived.ctx_runtime / derived.ctx_train
    end
    
    -- Extract KV cache memory from captured lines (best-effort)
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
    
    -- Ensure exit_code is an integer
    local final_exit_code = exit_code and tonumber(exit_code) or 0
    
    local info = {
        schema_version = 1,
        model_name = model_name,
        gguf_path = model_path,
        gguf_size_bytes = fingerprint.size,
        gguf_mtime = fingerprint.mtime,
        captured_at = os.time(),
        llama_cpp_path = expand_path(config.llama_cpp_path),
        captured_lines = captured_lines,
        kv = kv,
        derived = derived,
        run_config = run_config,
        is_partial = (end_reason ~= "exit" or final_exit_code ~= 0),
        end_reason = end_reason,
        exit_code = final_exit_code
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

local function format_size(bytes)
    if bytes < 1024 then
        return bytes .. "B"
    elseif bytes < 1024 * 1024 then
        return string.format("%.1fKB", bytes / 1024)
    elseif bytes < 1024 * 1024 * 1024 then
        return string.format("%.1fMB", bytes / (1024 * 1024))
    else
        return string.format("%.1fGB", bytes / (1024 * 1024 * 1024))
    end
end

local function extract_quant(model_name)
    -- Extract quantization from model name
    local quant = model_name:match("Q%d+_K_[MS]") or 
                  model_name:match("Q%d+_K") or
                  model_name:match("Q%d+_%d+") or
                  model_name:match("Q%d+")
    return quant or "?"
end

local function get_model_row(config, model_name)
    -- Returns: name, size_str, quant, last_run_str
    local model_path = expand_path(config.models_dir) .. "/" .. model_name .. ".gguf"
    
    -- Get size
    local size_str = "?"
    local attr = path_attr(model_path)
    if attr then
        size_str = format_size(attr.size)
    end
    
    -- Get quant
    local quant = extract_quant(model_name)
    
    -- Get last run time (check history first, then model_info)
    local last_run_str = "never"
    local history = load_history()
    for _, entry in ipairs(history) do
        local name = type(entry) == "string" and entry or entry.name
        if name == model_name then
            local timestamp = type(entry) == "table" and entry.last_run or nil
            if timestamp then
                last_run_str = format_time(timestamp)
            end
            break
        end
    end
    
    -- Fallback to model_info captured_at if not in history
    if last_run_str == "never" then
        local info = load_model_info(model_name)
        if info and info.captured_at then
            last_run_str = format_time(info.captured_at)
        end
    end
    
    return model_name, size_str, quant, last_run_str
end

local function calculate_column_widths(model_data)
    -- Calculate max widths for alignment
    local max_name, max_size, max_quant = 0, 0, 0
    for _, m in ipairs(model_data) do
        if #m.name > max_name then max_name = #m.name end
        if #m.size_str > max_size then max_size = #m.size_str end
        if #m.quant > max_quant then max_quant = #m.quant end
    end
    return max_name, max_size, max_quant
end

local function format_model_row(model_data_item, max_name, max_size, max_quant)
    -- Returns formatted row string with proper column alignment
    local name_pad = string.rep(" ", max_name - #model_data_item.name)
    local size_pad = string.rep(" ", max_size - #model_data_item.size_str)
    local quant_pad = string.rep(" ", max_quant - #model_data_item.quant)
    
    return model_data_item.name .. name_pad .. "  " .. 
           model_data_item.size_str .. size_pad .. "  " .. 
           model_data_item.quant .. quant_pad .. "  " .. 
           model_data_item.last_run_str
end

local function print_model_list(models, models_dir, config)
    if #models == 0 then
        print("  No models found.")
        return
    end
    
    -- Load history to check for last run times
    local history = load_history()
    
    -- Convert simple names to model objects if needed and add row data
    local model_list = {}
    for _, model in ipairs(models) do
        local name = type(model) == "string" and model or model.name
        local _, size_str, quant, last_run_str = get_model_row(config, name)
        
        table.insert(model_list, {
            name = name,
            size_str = size_str,
            quant = quant,
            last_run_str = last_run_str,
            -- Get timestamp for sorting
            last_run_ts = 0
        })
        
        -- Get timestamp for sorting
        for _, entry in ipairs(history) do
            local h_name = type(entry) == "string" and entry or entry.name
            if h_name == name then
                model_list[#model_list].last_run_ts = type(entry) == "table" and entry.last_run or 0
                break
            end
        end
        
        if model_list[#model_list].last_run_ts == 0 then
            local info = load_model_info(name)
            if info and info.captured_at then
                model_list[#model_list].last_run_ts = info.captured_at
            end
        end
    end
    
    -- Sort by last run time, newest first
    table.sort(model_list, function(a, b)
        return a.last_run_ts > b.last_run_ts
    end)
    
    -- Calculate column widths
    local max_name, max_size, max_quant = calculate_column_widths(model_list)
    
    -- Print each row
    for _, m in ipairs(model_list) do
        print("  " .. format_model_row(m, max_name, max_size, max_quant))
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
    
    -- Build quoted command string
    local quoted_argv = {}
    for i = 1, #argv do
        quoted_argv[i] = sh_quote(argv[i])
    end
    
    return table.concat(quoted_argv, " "), argv
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
    
    local cmd, argv = build_llama_command(config, model_name, extra_args)
    print("Starting llama.cpp with: " .. model_name)
    print("Command: " .. cmd)
    print()
    
    -- Build run config for storage
    local run_config = {
        llama_cpp_path = expand_path(config.llama_cpp_path),
        argv = argv,
        models_dir = expand_path(config.models_dir),
        model_name = model_name,
        extra_args = (extra_args and #extra_args > 0) and extra_args or json.empty_array
    }
    
    -- Extract host/port from argv if present
    for i, arg in ipairs(argv) do
        if arg == "--host" and argv[i+1] then
            run_config.host = argv[i+1]
        elseif arg == "--port" and argv[i+1] then
            run_config.port = tonumber(argv[i+1])
        end
    end
    
    -- State that persists across the run
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
    
    -- Finalize function that ALWAYS runs
    local function finalize(opts)
        opts = opts or {}
        
        -- Close pipe if still open
        if pipe then
            pcall(function() pipe:close() end)
        end
        
        -- Determine end reason and exit code
        end_reason = opts.interrupted and "sigint" or (opts.error and "error" or "exit")
        final_exit_code = opts.exit_code or 0
        
        -- Always save captured metadata if we have any
        if #captured_lines > 0 then
            save_model_info(config, model_name, captured_lines, run_config, end_reason, final_exit_code)
        end
        
        -- Always update history with final status
        local status = "exited"
        if opts.interrupted then
            status = "interrupted"
        elseif final_exit_code ~= 0 then
            status = "failed"
        end
        
        add_to_history(model_name, status, final_exit_code)
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
                -- Sanitize large arrays before storing
                local sanitized_line = sanitize_large_arrays(line)
                table.insert(captured_lines, sanitized_line)
                capture_count = capture_count + 1
                capture_bytes = capture_bytes + #sanitized_line
                
                -- Write model info early (first time we get metadata)
                if not info_written and #captured_lines >= 10 then
                    save_model_info(config, model_name, captured_lines, run_config, "running", 0)
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
            finalize({ exit_code = 1, interrupted = false, error = true })
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

local function show_picker(models, config, title)
    if #models == 0 then
        print("No models found.")
        return nil
    end
    
    title = title or "Select a model (↑/↓ arrows, Enter to confirm, q to quit):"
    
    -- Convert history entries to model data with formatting
    local model_data = {}
    for _, entry in ipairs(models) do
        local name = type(entry) == "string" and entry or entry.name
        local _, size_str, quant, last_run_str = get_model_row(config, name)
        table.insert(model_data, {
            name = name,
            size_str = size_str,
            quant = quant,
            last_run_str = last_run_str
        })
    end
    
    -- Calculate column widths for alignment
    local max_name, max_size, max_quant = calculate_column_widths(model_data)
    
    return with_raw_tty(function()
        local selected = 1
        local function draw()
            -- Clear screen and move cursor to top
            io.write("\27[2J\27[H")
            print(title .. "\n")
            
            for i, m in ipairs(model_data) do
                local row = format_model_row(m, max_name, max_size, max_quant)
                if i == selected then
                    io.write("  > \27[1m" .. row .. "\27[0m\n")
                else
                    io.write("    " .. row .. "\n")
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
                        selected = selected > 1 and selected - 1 or #model_data
                        draw()
                    elseif arrow == "B" then -- Down
                        selected = selected < #model_data and selected + 1 or 1
                        draw()
                    end
                end
            elseif char == "\n" or char == "\r" then
                return model_data[selected].name
            elseif char == "q" or char == "Q" then
                return nil
            end
        end
    end)
end

local function show_sectioned_picker(config)
    -- Build combined pinned + recent picker with sections
    local pins = load_pins()
    local recent_limit = config.recent_models_count or 7
    
    -- Build pinned set for exclusion
    local pinned_set = {}
    for _, name in ipairs(pins) do
        pinned_set[name] = true
    end
    
    -- Build pinned section data
    local pinned_data = {}
    for _, name in ipairs(pins) do
        local model_path = expand_path(config.models_dir) .. "/" .. name .. ".gguf"
        if file_exists(model_path) then
            local _, size_str, quant, last_run_str = get_model_row(config, name)
            table.insert(pinned_data, {
                name = name,
                size_str = size_str,
                quant = quant,
                last_run_str = last_run_str
            })
        end
    end
    
    -- Get recent models excluding pinned
    local recent_models = get_recent_models(config, pinned_set, recent_limit)
    local recent_data = {}
    for _, entry in ipairs(recent_models) do
        local name = type(entry) == "string" and entry or entry.name
        local _, size_str, quant, last_run_str = get_model_row(config, name)
        table.insert(recent_data, {
            name = name,
            size_str = size_str,
            quant = quant,
            last_run_str = last_run_str
        })
    end
    
    -- Build render items array
    local render_items = {}
    local selectable_indices = {}
    
    if #pinned_data > 0 then
        table.insert(render_items, {kind = "header", text = "Pinned"})
        for _, m in ipairs(pinned_data) do
            table.insert(render_items, {kind = "model", model_data = m})
            table.insert(selectable_indices, #render_items)
        end
    end
    
    table.insert(render_items, {kind = "header", text = "Recent"})
    if #recent_data > 0 then
        for _, m in ipairs(recent_data) do
            table.insert(render_items, {kind = "model", model_data = m})
            table.insert(selectable_indices, #render_items)
        end
    else
        table.insert(render_items, {kind = "message", text = "(none)"})
    end
    
    if #selectable_indices == 0 then
        print("No models available.")
        return nil
    end
    
    -- Calculate column widths across all model data
    local all_model_data = {}
    for _, item in ipairs(render_items) do
        if item.kind == "model" then
            table.insert(all_model_data, item.model_data)
        end
    end
    local max_name, max_size, max_quant = calculate_column_widths(all_model_data)
    
    return with_raw_tty(function()
        local selected_idx = 1 -- Index into selectable_indices
        
        local function draw()
            io.write("\27[2J\27[H")
            print("Select a model (↑/↓ arrows, Enter to confirm, q to quit):\n")
            
            local current_selectable = selectable_indices[selected_idx]
            
            for i, item in ipairs(render_items) do
                if item.kind == "header" then
                    io.write("\27[1m" .. item.text .. "\27[0m\n")
                elseif item.kind == "model" then
                    local row = format_model_row(item.model_data, max_name, max_size, max_quant)
                    if i == current_selectable then
                        io.write("  > \27[1m" .. row .. "\27[0m\n")
                    else
                        io.write("    " .. row .. "\n")
                    end
                elseif item.kind == "message" then
                    io.write("  " .. item.text .. "\n")
                end
            end
        end
        
        draw()
        
        while true do
            local char = io.read(1)
            
            if char == "\27" then
                local next = io.read(1)
                if next == "[" then
                    local arrow = io.read(1)
                    if arrow == "A" then -- Up
                        selected_idx = selected_idx > 1 and selected_idx - 1 or #selectable_indices
                        draw()
                    elseif arrow == "B" then -- Down
                        selected_idx = selected_idx < #selectable_indices and selected_idx + 1 or 1
                        draw()
                    end
                end
            elseif char == "\n" or char == "\r" then
                local render_idx = selectable_indices[selected_idx]
                return render_items[render_idx].model_data.name
            elseif char == "q" or char == "Q" then
                return nil
            end
        end
    end)
end

-- Fuzzy model matching
local function find_matching_models(config, query)
    local all_models = list_models(config.models_dir)
    local query_lower = query:lower()
    
    -- Check for exact match first (case-insensitive)
    for _, model in ipairs(all_models) do
        if model.name:lower() == query_lower then
            return {model.name}, "exact"
        end
    end
    
    -- Substring match (case-insensitive)
    local matches = {}
    for _, model in ipairs(all_models) do
        if model.name:lower():find(query_lower, 1, true) then
            table.insert(matches, model.name)
        end
    end
    
    if #matches > 0 then
        return matches, "substring"
    end
    
    -- No matches
    return {}, "none"
end

-- Main logic
local function main(args)
    local config = load_config()
    
    if #args == 0 then
        -- Show interactive picker with pinned + recent models
        local selected = show_sectioned_picker(config)
        if selected then
            run_model(config, selected, nil)
        end
        
    elseif args[1] == "list" then
        -- List all models
        local models = list_models(config.models_dir)
        print("Available models in " .. expand_path(config.models_dir) .. ":\n")
        print_model_list(models, config.models_dir, config)
        
    elseif args[1] == "info" then
        -- Show cached model info
        local model_name = args[2]
        local raw_mode = args[3] == "--raw"
        local show_kv = args[3] == "--kv"
        
        -- If no model name, show picker of models with cached info
        if not model_name then
            ensure_model_info_dir()
            local models_with_info = {}
            
            -- Scan model_info directory for cached info files
            if is_dir(MODEL_INFO_DIR) then
                for file in lfs.dir(MODEL_INFO_DIR) do
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
            
            -- Convert to model objects for picker
            local info_models = {}
            for _, name in ipairs(models_with_info) do
                table.insert(info_models, {name = name})
            end
            
            -- Show picker
            local selected = show_picker(info_models, config, "Select a model to view info (↑/↓ arrows, Enter to confirm, q to quit):")
            
            if not selected then
                os.exit(0)
            end
            
            model_name = selected
            -- Clear screen after picker
            io.write("\27[2J\27[H")
        end
        
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
        
        if info.is_partial then
            local reason_str = info.end_reason == "sigint" and "interrupted by user" or
                             info.end_reason == "error" and "error during run" or
                             "non-zero exit"
            print("⚠ Note: Partial capture (" .. reason_str .. ", exit code: " .. (info.exit_code or "unknown") .. ")")
            print()
        end
        
        -- Show KV parse warning if present
        if info.kv and info.kv["_kv_parse_warning"] then
            print("⚠ KV Parse Warning: " .. info.kv["_kv_parse_warning"])
            print()
        end
        
        if show_kv then
            -- Show structured KV data
            print("Structured Model Metadata (KV):")
            print()
            if info.kv and next(info.kv) then
                -- Sort keys for consistent display
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
            if info.exit_code then
                print("Exit Code: " .. info.exit_code)
            end
            if info.end_reason then
                print("End Reason: " .. info.end_reason)
            end
            print()
            
            -- Show run config if available
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
            
            -- Show key metadata from KV if available
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
            
            -- Show derived tuning fields if available
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
        
    elseif args[1] == "pin" then
        -- Pin a model
        if #args < 2 then
            print("Error: Missing model name")
            print("Usage: luallm pin <model_name>")
            os.exit(1)
        end
        
        local model_query = args[2]
        local matches, match_type = find_matching_models(config, model_query)
        
        if #matches == 0 then
            print("No model found matching: " .. model_query)
            print()
            print("Available models:")
            local all_models = list_models(config.models_dir)
            local suggestions = {}
            for i = 1, math.min(10, #all_models) do
                local _, size_str, quant, last_run_str = get_model_row(config, all_models[i].name)
                table.insert(suggestions, {
                    name = all_models[i].name,
                    size_str = size_str,
                    quant = quant,
                    last_run_str = last_run_str
                })
            end
            local max_name, max_size, max_quant = calculate_column_widths(suggestions)
            for _, m in ipairs(suggestions) do
                print("  " .. format_model_row(m, max_name, max_size, max_quant))
            end
            os.exit(1)
        elseif #matches == 1 then
            local model_name = matches[1]
            if add_pin(model_name) then
                print("Pinned: " .. model_name)
            else
                print("Already pinned: " .. model_name)
            end
        else
            print("Multiple models match '" .. model_query .. "':\n")
            local match_models = {}
            for _, name in ipairs(matches) do
                table.insert(match_models, {name = name})
            end
            local selected = show_picker(match_models, config, "Select a model to pin (↑/↓ arrows, Enter to confirm, q to quit):")
            if selected then
                if add_pin(selected) then
                    print("Pinned: " .. selected)
                else
                    print("Already pinned: " .. selected)
                end
            end
        end
        
    elseif args[1] == "unpin" then
        -- Unpin a model
        if #args < 2 then
            print("Error: Missing model name")
            print("Usage: luallm unpin <model_name>")
            os.exit(1)
        end
        
        local model_query = args[2]
        local matches, match_type = find_matching_models(config, model_query)
        
        if #matches == 0 then
            print("No model found matching: " .. model_query)
            os.exit(1)
        elseif #matches == 1 then
            local model_name = matches[1]
            if remove_pin(model_name) then
                print("Unpinned: " .. model_name)
            else
                print("Not pinned: " .. model_name)
            end
        else
            print("Multiple models match '" .. model_query .. "':\n")
            local match_models = {}
            for _, name in ipairs(matches) do
                table.insert(match_models, {name = name})
            end
            local selected = show_picker(match_models, config, "Select a model to unpin (↑/↓ arrows, Enter to confirm, q to quit):")
            if selected then
                if remove_pin(selected) then
                    print("Unpinned: " .. selected)
                else
                    print("Not pinned: " .. selected)
                end
            end
        end
        
    elseif args[1] == "pinned" then
        -- List pinned models
        local pins = load_pins()
        
        if #pins == 0 then
            print("No pinned models.")
            os.exit(0)
        end
        
        print("Pinned models:\n")
        
        -- Build model data for all pins
        local pin_data = {}
        for _, name in ipairs(pins) do
            local _, size_str, quant, last_run_str = get_model_row(config, name)
            table.insert(pin_data, {
                name = name,
                size_str = size_str,
                quant = quant,
                last_run_str = last_run_str
            })
        end
        
        -- Calculate column widths and print
        local max_name, max_size, max_quant = calculate_column_widths(pin_data)
        for _, m in ipairs(pin_data) do
            print("  " .. format_model_row(m, max_name, max_size, max_quant))
        end
        
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
        print("  luallm info [model]   Show cached model metadata (interactive if no model)")
        print("  luallm pin <model>    Pin a model for quick access")
        print("  luallm unpin <model>  Unpin a model")
        print("  luallm pinned         List pinned models")
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
        print("  luallm pin codellama             # Pin a model")
        print("  luallm pinned                    # See pinned models")
        print("  luallm info                      # Pick model to view info")
        print("  luallm info llama-3-8b           # Show cached metadata")
        print("  luallm info llama-3-8b --kv      # Show structured KV data")
        print("  luallm info llama-3-8b --raw     # Show raw captured output")
        print("  luallm codellama --port 9090     # Override default port")
        print("  luallm mistral -c 8192           # Override context size")
        print()
        print("CONFIG:")
        print("  Location: " .. CONFIG_FILE)
        print("  Edit to customize model directory, llama.cpp path, defaults, etc.")
        print()
        
    else
        -- Run specific model with fuzzy matching
        local model_query = args[1]
        local extra_args = {}
        for i = 2, #args do
            table.insert(extra_args, args[i])
        end
        
        -- Find matching models
        local matches, match_type = find_matching_models(config, model_query)
        
        if #matches == 0 then
            -- No matches
            print("No model found matching: " .. model_query)
            print()
            print("Available models:")
            local all_models = list_models(config.models_dir)
            
            -- Build model data for up to 5 most recent
            local suggestions = {}
            for i = 1, math.min(5, #all_models) do
                local _, size_str, quant, last_run_str = get_model_row(config, all_models[i].name)
                table.insert(suggestions, {
                    name = all_models[i].name,
                    size_str = size_str,
                    quant = quant,
                    last_run_str = last_run_str
                })
            end
            
            -- Calculate column widths and print
            local max_name, max_size, max_quant = calculate_column_widths(suggestions)
            for _, m in ipairs(suggestions) do
                print("  " .. format_model_row(m, max_name, max_size, max_quant))
            end
            os.exit(1)
        elseif #matches == 1 then
            -- Exact match, run it
            run_model(config, matches[1], extra_args)
        else
            -- Multiple matches, show picker
            print("Multiple models match '" .. model_query .. "':\n")
            local match_models = {}
            for _, name in ipairs(matches) do
                table.insert(match_models, {name = name})
            end
            local selected = show_picker(match_models, config, "Select a model (↑/↓ arrows, Enter to confirm, q to quit):")
            if selected then
                run_model(config, selected, extra_args)
            end
        end
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
