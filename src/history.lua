local util = require("util")
local config = require("config")

local M = {}

M.HISTORY_FILE = config.CONFIG_DIR .. "/history.json"

function M.load_history()
    local history = util.load_json(M.HISTORY_FILE)
    if not history then
        return {}
    end
    return history
end

function M.save_history(history)
    util.save_json(M.HISTORY_FILE, history)
end

function M.add_to_history(model_name, status, exit_code)
    status = status or "running"
    local history = M.load_history()
    
    local found_running = false
    for i, entry in ipairs(history) do
        local name = type(entry) == "string" and entry or entry.name
        if name == model_name and type(entry) == "table" and entry.status == "running" then
            entry.status = status
            entry.end_time = os.time()
            if exit_code then
                entry.exit_code = exit_code
            end
            found_running = true
            M.save_history(history)
            return
        end
    end
    
    if not found_running then
        for i = #history, 1, -1 do
            local name = type(history[i]) == "string" and history[i] or history[i].name
            if name == model_name then
                table.remove(history, i)
            end
        end
        
        table.insert(history, 1, {
            name = model_name,
            last_run = os.time(),
            status = status,
            exit_code = exit_code
        })
    end
    
    M.save_history(history)
end

function M.get_recent_models(config, exclude_set, limit)
    local history = M.load_history()
    exclude_set = exclude_set or {}
    limit = limit or (config.recent_models_count or 4)
    
    local recent = {}
    local seen = {}
    
    for _, entry in ipairs(history) do
        local name = type(entry) == "string" and entry or entry.name
        
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

function M.clear_history()
    M.save_history({})
end

return M
