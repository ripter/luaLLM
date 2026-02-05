-- doctor.lua
-- Diagnostics and configuration validation for luaLLM

local util = require("src.util")
local config = require("src.config")
local model_info = require("src.model_info")
local history = require("src.history")

local M = {}

-- Required configuration fields
local REQUIRED_FIELDS = {
    {
        path = "llama_cpp_path",
        desc = "Path to llama-server binary",
        check = "file"
    },
    {
        path = "models_dir",
        desc = "Directory containing GGUF models",
        check = "dir"
    },
    {
        path = "bench.default_n",
        desc = "Default number of benchmark samples",
        check = "number"
    },
    {
        path = "bench.default_warmup",
        desc = "Default number of warmup runs",
        check = "number"
    },
    {
        path = "bench.default_threads",
        desc = "Default thread count for benchmarking",
        check = "number"
    },
}

-- Get nested config value by path (e.g., "bench.default_n")
local function get_config_value(cfg, path)
    local parts = {}
    for part in path:gmatch("[^.]+") do
        table.insert(parts, part)
    end
    
    local value = cfg
    for _, part in ipairs(parts) do
        if type(value) == "table" then
            value = value[part]
        else
            return nil
        end
    end
    
    return value
end

-- Validate a single config field
local function validate_field(cfg, field)
    local value = get_config_value(cfg, field.path)
    
    if value == nil then
        return {
            status = "missing",
            message = "✗ " .. field.path .. " (missing)",
            issue = {
                field = field.path,
                issue = "missing",
                fix = "Add to config: " .. field.path .. " = <value>"
            }
        }
    end
    
    if field.check == "file" then
        local expanded = util.expand_path(value)
        if util.file_exists(expanded) then
            return {
                status = "ok",
                message = "✓ " .. field.path .. " → " .. expanded
            }
        else
            return {
                status = "error",
                message = "✗ " .. field.path .. " → " .. expanded .. " (not found)",
                issue = {
                    field = field.path,
                    issue = "file not found",
                    fix = "Update " .. field.path .. " to point to valid file"
                }
            }
        end
    elseif field.check == "dir" then
        local expanded = util.expand_path(value)
        if util.is_dir(expanded) then
            local models = model_info.list_models(value)
            return {
                status = "ok",
                message = "✓ " .. field.path .. " → " .. expanded .. " (" .. #models .. " models)"
            }
        else
            return {
                status = "error",
                message = "✗ " .. field.path .. " → " .. expanded .. " (not found)",
                issue = {
                    field = field.path,
                    issue = "directory not found",
                    fix = "Create directory or update " .. field.path .. " to valid path"
                }
            }
        end
    elseif field.check == "number" then
        if type(value) == "number" then
            return {
                status = "ok",
                message = "✓ " .. field.path .. " = " .. value
            }
        else
            return {
                status = "error",
                message = "✗ " .. field.path .. " = " .. tostring(value) .. " (should be number)",
                issue = {
                    field = field.path,
                    issue = "wrong type",
                    fix = field.path .. " should be a number"
                }
            }
        end
    end
    
    return {status = "ok", message = "✓ " .. field.path}
end

-- Check Lua dependencies
local function check_dependencies()
    print("Lua version: " .. _VERSION)
    
    local has_cjson = pcall(require, "cjson")
    local has_lfs = pcall(require, "lfs")
    print("lua-cjson: " .. (has_cjson and "✓ installed" or "✗ missing"))
    print("luafilesystem: " .. (has_lfs and "✓ installed" or "✗ missing"))
    print()
    
    return has_cjson and has_lfs
end

-- Check config file existence and validity
local function check_config_file()
    print("Config file: " .. config.CONFIG_FILE)
    
    if not util.file_exists(config.CONFIG_FILE) then
        print("  ✗ not found")
        print()
        print("Create a config file at: " .. config.CONFIG_FILE)
        print("See README for configuration details")
        return nil
    end
    
    print("  ✓ exists")
    
    local loaded_cfg, err = util.load_json(config.CONFIG_FILE)
    if err then
        print("  ✗ " .. err)
        return nil
    end
    
    print("  ✓ valid JSON")
    print()
    
    return loaded_cfg
end

-- Validate required configuration
local function validate_required_config(cfg)
    print("Required Configuration:")
    
    local issues = {}
    
    for _, field in ipairs(REQUIRED_FIELDS) do
        local result = validate_field(cfg, field)
        print("  " .. result.message)
        
        if result.issue then
            table.insert(issues, result.issue)
        end
    end
    
    print()
    return issues
end

-- Check optional configuration
local function check_optional_config(cfg)
    print("Optional Configuration:")
    
    -- Check for llama-bench
    local bench_path = util.resolve_bench_path(cfg)
    if bench_path then
        print("  ✓ llama-bench found → " .. bench_path)
    else
        print("  - llama-bench not configured")
        print("    Add one of: llama_bench_path, llama_cli_path, or llama_cpp_source_dir")
        print("    (required for 'luallm bench' command)")
    end
    
    -- Check llama-cli
    if cfg.llama_cli_path then
        local cli_path = util.expand_path(cfg.llama_cli_path)
        if util.file_exists(cli_path) then
            print("  ✓ llama-cli found → " .. cli_path)
        else
            print("  ✗ llama-cli configured but not found → " .. cli_path)
        end
    end
    
    print()
end

-- Check history file
local function check_history()
    print("History file: " .. history.HISTORY_FILE)
    
    if util.file_exists(history.HISTORY_FILE) then
        local hist = history.load_history()
        print("  ✓ exists (" .. #hist .. " entries)")
    else
        print("  - not yet created (will be created on first model run)")
    end
    
    print()
end

-- Print issues summary
local function print_issues_summary(issues)
    if #issues == 0 then
        print("✓ All required configuration is valid")
        return
    end
    
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("CONFIGURATION ISSUES FOUND:")
    print()
    
    for i, issue in ipairs(issues) do
        print(string.format("%d. %s (%s)", i, issue.field, issue.issue))
        print("   Fix: " .. issue.fix)
        print()
    end
    
    print("Edit your config file: " .. config.CONFIG_FILE)
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
end

-- Main doctor command handler
function M.run(cfg)
    print("luaLLM diagnostics")
    print()
    
    -- Check Lua dependencies
    local deps_ok = check_dependencies()
    if not deps_ok then
        print("✗ Missing required Lua dependencies")
        print("Install: lua-cjson and luafilesystem")
        return
    end
    
    -- Check and load config file
    local loaded_cfg = check_config_file()
    if not loaded_cfg then
        return
    end
    
    -- Validate required configuration
    local issues = validate_required_config(loaded_cfg)
    
    -- Check optional configuration
    check_optional_config(loaded_cfg)
    
    -- Check history file
    check_history()
    
    -- Print summary
    print_issues_summary(issues)
end

return M
