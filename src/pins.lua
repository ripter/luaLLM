local util = require("util")
local config = require("config")
local format = require("format")
local resolve = require("resolve")

local M = {}

-- Lazy load picker to avoid circular dependency
local picker

M.PINS_FILE = config.CONFIG_DIR .. "/pins.json"

function M.load_pins()
    if not util.file_exists(M.PINS_FILE) then
        return {}
    end
    
    local pins, err = util.load_json(M.PINS_FILE)
    if err or type(pins) ~= "table" then
        io.stderr:write("Warning: Invalid pins file, treating as empty\n")
        return {}
    end
    
    return pins
end

function M.save_pins(pins)
    util.save_json(M.PINS_FILE, pins)
end

function M.is_pinned(model_name)
    local pins = M.load_pins()
    for _, pin in ipairs(pins) do
        if pin == model_name then
            return true
        end
    end
    return false
end

function M.add_pin(model_name)
    local pins = M.load_pins()
    
    for _, pin in ipairs(pins) do
        if pin == model_name then
            return false
        end
    end
    
    table.insert(pins, model_name)
    M.save_pins(pins)
    return true
end

function M.remove_pin(model_name)
    local pins = M.load_pins()
    
    for i, pin in ipairs(pins) do
        if pin == model_name then
            table.remove(pins, i)
            M.save_pins(pins)
            return true
        end
    end
    
    return false
end

function M.handle_pin_command(args, cfg)
    if #args < 2 then
        print("Error: Missing model name")
        print("Usage: luallm pin <model_name>")
        os.exit(1)
    end
    
    local model_query = args[2]
    local matches, match_type = resolve.find_matching_models(cfg, model_query)
    
    if #matches == 0 then
        print("No model found matching: " .. model_query)
        print()
        print("Available models:")
        local model_info = require("model_info")
        local all_models = model_info.list_models(cfg.models_dir)
        local suggestions = {}
        for i = 1, math.min(10, #all_models) do
            local _, size_str, quant, last_run_str = format.get_model_row(cfg, all_models[i].name)
            table.insert(suggestions, {
                name = all_models[i].name,
                size_str = size_str,
                quant = quant,
                last_run_str = last_run_str
            })
        end
        local max_name, max_size, max_quant = format.calculate_column_widths(suggestions)
        for _, m in ipairs(suggestions) do
            print("  " .. format.format_model_row(m, max_name, max_size, max_quant))
        end
        os.exit(1)
    elseif #matches == 1 then
        local model_name = matches[1]
        if M.add_pin(model_name) then
            print("Pinned: " .. model_name)
        else
            print("Already pinned: " .. model_name)
        end
    else
        -- Lazy load picker to avoid circular dependency
        if not picker then
            picker = require("picker")
        end
        
        print("Multiple models match '" .. model_query .. "':\n")
        local match_models = {}
        for _, name in ipairs(matches) do
            table.insert(match_models, {name = name})
        end
        local selected = picker.show_picker(match_models, cfg, "Select a model to pin (↑/↓ arrows, Enter to confirm, q to quit):")
        if selected then
            if M.add_pin(selected) then
                print("Pinned: " .. selected)
            else
                print("Already pinned: " .. selected)
            end
        end
    end
end

function M.handle_unpin_command(args, cfg)
    if #args < 2 then
        print("Error: Missing model name")
        print("Usage: luallm unpin <model_name>")
        os.exit(1)
    end
    
    local model_query = args[2]
    local matches, match_type = resolve.find_matching_models(cfg, model_query)
    
    if #matches == 0 then
        print("No model found matching: " .. model_query)
        os.exit(1)
    elseif #matches == 1 then
        local model_name = matches[1]
        if M.remove_pin(model_name) then
            print("Unpinned: " .. model_name)
        else
            print("Not pinned: " .. model_name)
        end
    else
        -- Lazy load picker to avoid circular dependency
        if not picker then
            picker = require("picker")
        end
        
        print("Multiple models match '" .. model_query .. "':\n")
        local match_models = {}
        for _, name in ipairs(matches) do
            table.insert(match_models, {name = name})
        end
        local selected = picker.show_picker(match_models, cfg, "Select a model to unpin (↑/↓ arrows, Enter to confirm, q to quit):")
        if selected then
            if M.remove_pin(selected) then
                print("Unpinned: " .. selected)
            else
                print("Not pinned: " .. selected)
            end
        end
    end
end

function M.handle_pinned_command(cfg)
    local pins = M.load_pins()
    
    if #pins == 0 then
        print("No pinned models.")
        os.exit(0)
    end
    
    print("Pinned models:\n")
    
    local pin_data = {}
    for _, name in ipairs(pins) do
        local _, size_str, quant, last_run_str = format.get_model_row(cfg, name)
        table.insert(pin_data, {
            name = name,
            size_str = size_str,
            quant = quant,
            last_run_str = last_run_str
        })
    end
    
    local max_name, max_size, max_quant = format.calculate_column_widths(pin_data)
    for _, m in ipairs(pin_data) do
        print("  " .. format.format_model_row(m, max_name, max_size, max_quant))
    end
end

return M
