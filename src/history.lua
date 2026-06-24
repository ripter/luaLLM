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

    for i, entry in ipairs(history) do
        local name = type(entry) == "string" and entry or entry.name
        if name == model_name and type(entry) == "table" and entry.status == "running" then
            entry.status = status
            entry.end_time = os.time()
            if exit_code then
                entry.exit_code = exit_code
            end
            M.save_history(history)
            return
        end
    end

    -- No in-progress entry — capture old count before removing existing entries.
    local old_count = 0
    for i = #history, 1, -1 do
        local name = type(history[i]) == "string" and history[i] or history[i].name
        if name == model_name then
            if type(history[i]) == "table" and history[i].run_count then
                old_count = history[i].run_count
            elseif old_count == 0 then
                old_count = 1
            end
            table.remove(history, i)
        end
    end

    table.insert(history, 1, {
        name = model_name,
        last_run = os.time(),
        status = status,
        exit_code = exit_code,
        run_count = old_count + 1,
    })

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

function M.handle_history_command(args)
    local hist = M.load_history()

    if #hist == 0 then
        print("No history yet.")
        return
    end

    local want_json = args[2] == "--json"

    if want_json then
        local json_ok, json = pcall(require, "cjson")
        if not json_ok then
            io.stderr:write("Error: cjson not available for JSON output\n")
            os.exit(1)
        end
        local out = {}
        for _, entry in ipairs(hist) do
            local name = type(entry) == "string" and entry or entry.name
            local count = (type(entry) == "table" and entry.run_count) or 1
            local last_run = type(entry) == "table" and entry.last_run or nil
            table.insert(out, { name = name, run_count = count, last_run = last_run })
        end
        print(json.encode(out))
        return
    end

    local HDR_NAME, HDR_RUNS, HDR_LAST = "Model", "Runs", "Last Used"
    local max_name = #HDR_NAME
    local max_runs = #HDR_RUNS
    for _, entry in ipairs(hist) do
        local name = type(entry) == "string" and entry or entry.name
        local count_str = tostring((type(entry) == "table" and entry.run_count) or 1)
        if #name > max_name then max_name = #name end
        if #count_str > max_runs then max_runs = #count_str end
    end

    local function row(name, runs, last)
        return "  " .. name .. string.rep(" ", max_name - #name)
               .. "  " .. runs .. string.rep(" ", max_runs - #runs)
               .. "  " .. last
    end

    print(row(HDR_NAME, HDR_RUNS, HDR_LAST))
    print("  " .. string.rep("-", max_name) .. "  " .. string.rep("-", max_runs) .. "  " .. string.rep("-", 20))

    for _, entry in ipairs(hist) do
        local name = type(entry) == "string" and entry or entry.name
        local count = (type(entry) == "table" and entry.run_count) or 1
        local last_run = type(entry) == "table" and entry.last_run or nil
        local last_str = last_run and util.format_time(last_run) or "unknown"
        print(row(name, tostring(count), last_str))
    end
end

function M.clear_history()
    M.save_history({})
end

return M
