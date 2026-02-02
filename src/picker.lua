local util = require("util")
local format = require("format")
local history = require("history")

local M = {}

-- Lazy load pins to avoid circular dependency
local pins

function M.with_raw_tty(fn)
    util.exec("stty -echo -icanon")
    local ok, result = xpcall(fn, function(err)
        return err .. "\n" .. debug.traceback()
    end)
    util.exec("stty echo icanon")
    io.write("\27[2J\27[H")
    
    if not ok then
        error(result)
    end
    return result
end

function M.show_picker(models, config, title)
    if #models == 0 then
        print("No models found.")
        return nil
    end
    
    title = title or "Select a model (↑/↓ arrows, Enter to confirm, q to quit):"
    
    local model_data = {}
    for _, entry in ipairs(models) do
        local name = type(entry) == "string" and entry or entry.name
        local _, size_str, quant, last_run_str = format.get_model_row(config, name)
        table.insert(model_data, {
            name = name,
            size_str = size_str,
            quant = quant,
            last_run_str = last_run_str
        })
    end
    
    local max_name, max_size, max_quant = format.calculate_column_widths(model_data)
    
    return M.with_raw_tty(function()
        local selected = 1
        local function draw()
            io.write("\27[2J\27[H")
            print(title .. "\n")
            
            for i, m in ipairs(model_data) do
                local row = format.format_model_row(m, max_name, max_size, max_quant)
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
                local next = io.read(1)
                if next == "[" then
                    local arrow = io.read(1)
                    if arrow == "A" then
                        selected = selected > 1 and selected - 1 or #model_data
                        draw()
                    elseif arrow == "B" then
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

function M.show_sectioned_picker(config)
    -- Lazy load pins to avoid circular dependency
    if not pins then
        pins = require("pins")
    end
    
    local pin_list = pins.load_pins()
    local recent_limit = config.recent_models_count or 7
    
    local pinned_set = {}
    for _, name in ipairs(pin_list) do
        pinned_set[name] = true
    end
    
    local pinned_data = {}
    for _, name in ipairs(pin_list) do
        local model_path = util.expand_path(config.models_dir) .. "/" .. name .. ".gguf"
        if util.file_exists(model_path) then
            local _, size_str, quant, last_run_str = format.get_model_row(config, name)
            table.insert(pinned_data, {
                name = name,
                size_str = size_str,
                quant = quant,
                last_run_str = last_run_str
            })
        end
    end
    
    local recent_models = history.get_recent_models(config, pinned_set, recent_limit)
    local recent_data = {}
    for _, entry in ipairs(recent_models) do
        local name = type(entry) == "string" and entry or entry.name
        local _, size_str, quant, last_run_str = format.get_model_row(config, name)
        table.insert(recent_data, {
            name = name,
            size_str = size_str,
            quant = quant,
            last_run_str = last_run_str
        })
    end
    
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
    
    local all_model_data = {}
    for _, item in ipairs(render_items) do
        if item.kind == "model" then
            table.insert(all_model_data, item.model_data)
        end
    end
    local max_name, max_size, max_quant = format.calculate_column_widths(all_model_data)
    
    return M.with_raw_tty(function()
        local selected_idx = 1
        
        local function draw()
            io.write("\27[2J\27[H")
            print("Select a model (↑/↓ arrows, Enter to confirm, q to quit):\n")
            
            local current_selectable = selectable_indices[selected_idx]
            
            for i, item in ipairs(render_items) do
                if item.kind == "header" then
                    io.write("\27[1m" .. item.text .. "\27[0m\n")
                elseif item.kind == "model" then
                    local row = format.format_model_row(item.model_data, max_name, max_size, max_quant)
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
                    if arrow == "A" then
                        selected_idx = selected_idx > 1 and selected_idx - 1 or #selectable_indices
                        draw()
                    elseif arrow == "B" then
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

return M
