local lfs = require("lfs")
local json = require("cjson")

local M = {}

function M.sh_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function M.exec(cmd)
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

function M.normalize_exit_code(ok, reason, code)
    if type(ok) == "number" then
        return ok
    elseif reason == "exit" then
        return code or 0
    elseif not ok then
        return code or 1
    end
    return 0
end

function M.file_exists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

function M.path_attr(path)
    return lfs.attributes(path)
end

function M.is_dir(path)
    local attr = lfs.attributes(path)
    return attr and attr.mode == "directory"
end

function M.rm_rf(path)
    -- Recursively remove directory or file
    local attr = lfs.attributes(path)
    if not attr then
        return true  -- Already doesn't exist
    end
    
    if attr.mode == "directory" then
        -- Recursively delete directory contents
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                local entry_path = path .. "/" .. entry
                local ok, err = M.rm_rf(entry_path)
                if not ok then
                    return false, err
                end
            end
        end
        -- Remove the now-empty directory
        local ok, err = lfs.rmdir(path)
        if not ok then
            return false, "failed to remove directory: " .. (err or path)
        end
    else
        -- Remove file
        local ok, err = os.remove(path)
        if not ok then
            return false, "failed to remove file: " .. (err or path)
        end
    end
    
    return true
end

function M.safe_filename(name)
    -- Replace unsafe characters with underscores
    -- Keep alphanumeric, dash, underscore, dot
    local safe = name:gsub("[^%w%.%-_]", "_")
    -- Prevent directory traversal
    safe = safe:gsub("%.%.", "__")
    -- Trim dots from start/end
    safe = safe:gsub("^%.+", ""):gsub("%.+$", "")
    -- Ensure not empty
    if safe == "" then
        safe = "unnamed"
    end
    return safe
end

function M.expand_path(path)
    if path:sub(1, 1) == "~" then
        local home = os.getenv("HOME")
        if home then
            return home .. path:sub(2)
        end
    end
    return path
end

function M.ensure_dir(dir)
    M.exec("mkdir -p " .. M.sh_quote(dir))
end

function M.load_json(filepath)
    if not M.file_exists(filepath) then
        return nil
    end
    local f = assert(io.open(M.expand_path(filepath), "r"))
    local content = f:read("*all")
    f:close()
    
    local ok, data = pcall(json.decode, content)
    if not ok then
        return nil, ("Invalid JSON in %s"):format(filepath)
    end
    return data
end

function M.save_json(filepath, data)
    local f = io.open(filepath, "w")
    f:write(json.encode(data))
    f:close()
end

function M.format_time(timestamp)
    local now = os.time()
    local diff = now - timestamp
    
    if diff < 60 then
        return "just now"
    end
    
    if diff < 3600 then
        local mins = math.floor(diff / 60)
        return mins .. " minute" .. (mins > 1 and "s" or "") .. " ago"
    end
    
    if diff < 86400 then
        local hours = math.floor(diff / 3600)
        return hours .. " hour" .. (hours > 1 and "s" or "") .. " ago"
    end
    
    if diff < 604800 then
        local days = math.floor(diff / 86400)
        return days .. " day" .. (days > 1 and "s" or "") .. " ago"
    end
    
    if diff < 2592000 then
        local weeks = math.floor(diff / 604800)
        return weeks .. " week" .. (weeks > 1 and "s" or "") .. " ago"
    end
    
    return os.date("%b %d, %Y", timestamp)
end

function M.format_size(bytes)
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

-- Resolve llama-bench path from config
function M.resolve_bench_path(cfg)
    -- Priority 1: Explicit config path
    if cfg.llama_bench_path then
        local path = M.expand_path(cfg.llama_bench_path)
        if M.file_exists(path) then
            return path
        end
    end
    
    -- Priority 2: Derive from llama_cli_path directory
    if cfg.llama_cli_path then
        local cli_path = M.expand_path(cfg.llama_cli_path)
        local bench_path = cli_path:gsub("llama%-cli$", "llama-bench")
        if bench_path ~= cli_path and M.file_exists(bench_path) then
            return bench_path
        end
    end
    
    -- Priority 3: Derive from llama_cpp_path directory
    if cfg.llama_cpp_path then
        local server_path = M.expand_path(cfg.llama_cpp_path)
        local bench_path = server_path:gsub("llama%-server$", "llama-bench")
        if bench_path ~= server_path and M.file_exists(bench_path) then
            return bench_path
        end
    end
    
    -- Priority 4: Derive from source directory
    if cfg.llama_cpp_source_dir then
        local src_dir = M.expand_path(cfg.llama_cpp_source_dir)
        local candidates = {
            src_dir .. "/build/bin/llama-bench",
            src_dir .. "/build/llama-bench",
        }
        for _, path in ipairs(candidates) do
            if M.file_exists(path) then
                return path
            end
        end
    end
    
    return nil
end

return M
