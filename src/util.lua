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

return M
