local util = require("util")
local history = require("history")

local M = {}
local model_info

local function extract_quant(model_name)
    local quant = model_name:match("Q%d+_K_[MS]") or 
                  model_name:match("Q%d+_K") or
                  model_name:match("Q%d+_%d+") or
                  model_name:match("Q%d+")
    return quant or "?"
end

function M.get_model_row(config, model_name)
    if not model_info then
        model_info = require("model_info")
    end
    
    local model_path = util.expand_path(config.models_dir) .. "/" .. model_name .. ".gguf"
    
    local size_str = "?"
    local attr = util.path_attr(model_path)
    if attr then
        size_str = util.format_size(attr.size)
    end
    
    local quant = extract_quant(model_name)
    
    local last_run_str = "never"
    local hist = history.load_history()
    for _, entry in ipairs(hist) do
        local name = type(entry) == "string" and entry or entry.name
        if name == model_name then
            local timestamp = type(entry) == "table" and entry.last_run or nil
            if timestamp then
                last_run_str = util.format_time(timestamp)
            end
            break
        end
    end
    
    if last_run_str == "never" then
        local info = model_info.load_model_info(model_name)
        if info and info.captured_at then
            last_run_str = util.format_time(info.captured_at)
        end
    end
    
    return model_name, size_str, quant, last_run_str
end

function M.calculate_column_widths(model_data)
    local max_name, max_size, max_quant = 0, 0, 0
    for _, m in ipairs(model_data) do
        if #m.name > max_name then max_name = #m.name end
        if #m.size_str > max_size then max_size = #m.size_str end
        if #m.quant > max_quant then max_quant = #m.quant end
    end
    return max_name, max_size, max_quant
end

function M.format_model_row(model_data_item, max_name, max_size, max_quant)
    local name_pad = string.rep(" ", max_name - #model_data_item.name)
    local size_pad = string.rep(" ", max_size - #model_data_item.size_str)
    local quant_pad = string.rep(" ", max_quant - #model_data_item.quant)
    
    return model_data_item.name .. name_pad .. "  " .. 
           model_data_item.size_str .. size_pad .. "  " .. 
           model_data_item.quant .. quant_pad .. "  " .. 
           model_data_item.last_run_str
end

function M.print_model_list(models, models_dir, config)
    if #models == 0 then
        print("  No models found.")
        return
    end
    
    local hist = history.load_history()
    
    local model_list = {}
    for _, model in ipairs(models) do
        local name = type(model) == "string" and model or model.name
        local _, size_str, quant, last_run_str = M.get_model_row(config, name)
        
        table.insert(model_list, {
            name = name,
            size_str = size_str,
            quant = quant,
            last_run_str = last_run_str,
            last_run_ts = 0
        })
        
        for _, entry in ipairs(hist) do
            local h_name = type(entry) == "string" and entry or entry.name
            if h_name == name then
                model_list[#model_list].last_run_ts = type(entry) == "table" and entry.last_run or 0
                break
            end
        end
        
        if model_list[#model_list].last_run_ts == 0 and model_info then
            local info = model_info.load_model_info(name)
            if info and info.captured_at then
                model_list[#model_list].last_run_ts = info.captured_at
            end
        end
    end
    
    table.sort(model_list, function(a, b)
        return a.last_run_ts > b.last_run_ts
    end)
    
    local max_name, max_size, max_quant = M.calculate_column_widths(model_list)
    
    for _, m in ipairs(model_list) do
        print("  " .. M.format_model_row(m, max_name, max_size, max_quant))
    end
end

return M
