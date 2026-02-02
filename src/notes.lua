local lfs = require("lfs")
local util = require("util")
local config = require("config")
local format = require("format")
local resolve = require("resolve")
local picker = require("picker")

local M = {}

M.NOTES_DIR = config.CONFIG_DIR .. "/notes"

local function ensure_notes_dir()
    util.ensure_dir(M.NOTES_DIR)
end

local function get_notes_path(model_name)
    return M.NOTES_DIR .. "/" .. model_name .. ".md"
end

local function has_notes(model_name)
    return util.file_exists(get_notes_path(model_name))
end

local function read_notes(model_name)
    local notes_path = get_notes_path(model_name)
    if not util.file_exists(notes_path) then
        return nil
    end
    
    local f = io.open(notes_path, "r")
    if not f then return nil end
    local content = f:read("*all")
    f:close()
    return content
end

local function write_notes(model_name, content)
    ensure_notes_dir()
    local notes_path = get_notes_path(model_name)
    local f = io.open(notes_path, "w")
    if not f then
        return false, "Failed to open notes file for writing"
    end
    f:write(content)
    f:close()
    return true
end

local function init_notes_file(model_name)
    local content = string.format("# %s\n\n## Notes\n\n## Summary\n", model_name)
    return write_notes(model_name, content)
end

local function add_note(model_name, note_text)
    ensure_notes_dir()
    local notes_path = get_notes_path(model_name)
    
    if not util.file_exists(notes_path) then
        init_notes_file(model_name)
    end
    
    local content = read_notes(model_name)
    if not content then
        return false, "Failed to read notes file"
    end
    
    local timestamp = os.date("%Y-%m-%d %H:%M")
    local new_note = string.format("- %s  %s\n", timestamp, note_text)
    
    local summary_pos = content:find("\n## Summary")
    if summary_pos then
        content = content:sub(1, summary_pos - 1) .. new_note .. content:sub(summary_pos)
    else
        if not content:match("\n$") then
            content = content .. "\n"
        end
        content = content .. new_note
    end
    
    return write_notes(model_name, content)
end

local function list_models_with_notes(cfg)
    ensure_notes_dir()
    local models = {}
    
    if not util.is_dir(M.NOTES_DIR) then
        return {}
    end
    
    for file in lfs.dir(M.NOTES_DIR) do
        if file:match("%.md$") then
            local name = file:gsub("%.md$", "")
            local filepath = M.NOTES_DIR .. "/" .. file
            local attr = lfs.attributes(filepath)
            if attr then
                local _, size_str, quant, last_run_str = format.get_model_row(cfg, name)
                table.insert(models, {
                    name = name,
                    size_str = size_str,
                    quant = quant,
                    last_run_str = last_run_str,
                    notes_mtime = attr.modification
                })
            end
        end
    end
    
    table.sort(models, function(a, b)
        return a.notes_mtime > b.notes_mtime
    end)
    
    return models
end

function M.handle_notes_command(args, cfg)
    local subcommand = args[2]
    
    if not subcommand then
        local model_info = require("model_info")
        local all_models = model_info.list_models(cfg.models_dir)
        if #all_models == 0 then
            print("No models found.")
            os.exit(1)
        end
        
        local model_objs = {}
        for _, m in ipairs(all_models) do
            table.insert(model_objs, {name = m.name})
        end
        
        local selected = picker.show_picker(model_objs, cfg, "Select a model to view notes (↑/↓ arrows, Enter to confirm, q to quit):")
        if not selected then
            os.exit(0)
        end
        
        local content = read_notes(selected)
        if content then
            print(content)
        else
            print("No notes yet for " .. selected .. ".")
            print("Notes file: " .. get_notes_path(selected))
        end
        
    elseif subcommand == "list" then
        local models = list_models_with_notes(cfg)
        
        if #models == 0 then
            print("No models have notes yet.")
            os.exit(0)
        end
        
        print("Models with notes:\n")
        
        local max_name, max_size, max_quant = format.calculate_column_widths(models)
        for _, m in ipairs(models) do
            print("  " .. format.format_model_row(m, max_name, max_size, max_quant))
        end
        
    elseif subcommand == "path" then
        if #args < 3 then
            print("Error: Missing model name")
            print("Usage: luallm notes path <model_name>")
            os.exit(1)
        end
        
        local model_query = args[3]
        local matches, match_type = resolve.find_matching_models(cfg, model_query)
        
        if #matches == 0 then
            print("No model found matching: " .. model_query)
            os.exit(1)
        elseif #matches == 1 then
            print(get_notes_path(matches[1]))
        else
            local match_models = {}
            for _, name in ipairs(matches) do
                table.insert(match_models, {name = name})
            end
            local selected = picker.show_picker(match_models, cfg, "Select a model (↑/↓ arrows, Enter to confirm, q to quit):")
            if selected then
                print(get_notes_path(selected))
            end
        end
        
    elseif subcommand == "add" then
        if #args < 4 then
            print("Error: Missing model name and note text")
            print("Usage: luallm notes add <model_name> <text...>")
            os.exit(1)
        end
        
        local model_query = args[3]
        local note_parts = {}
        for i = 4, #args do
            table.insert(note_parts, args[i])
        end
        local note_text = table.concat(note_parts, " ")
        
        local matches, match_type = resolve.find_matching_models(cfg, model_query)
        
        if #matches == 0 then
            print("No model found matching: " .. model_query)
            os.exit(1)
        elseif #matches == 1 then
            local ok, err = add_note(matches[1], note_text)
            if ok then
                print("Note added to " .. matches[1])
            else
                print("Error: " .. err)
                os.exit(1)
            end
        else
            local match_models = {}
            for _, name in ipairs(matches) do
                table.insert(match_models, {name = name})
            end
            local selected = picker.show_picker(match_models, cfg, "Select a model to add note (↑/↓ arrows, Enter to confirm, q to quit):")
            if selected then
                local ok, err = add_note(selected, note_text)
                if ok then
                    print("Note added to " .. selected)
                else
                    print("Error: " .. err)
                    os.exit(1)
                end
            end
        end
        
    elseif subcommand == "edit" then
        local model_query = args[3]
        
        if not model_query then
            print("Error: Missing model name")
            print("Usage: luallm notes edit <model_name>")
            os.exit(1)
        end
        
        local matches, match_type = resolve.find_matching_models(cfg, model_query)
        
        if #matches == 0 then
            print("No model found matching: " .. model_query)
            os.exit(1)
        elseif #matches == 1 then
            local model_name = matches[1]
            local notes_path = get_notes_path(model_name)
            
            if not util.file_exists(notes_path) then
                init_notes_file(model_name)
            end
            
            local editor = os.getenv("EDITOR") or "vi"
            local cmd = editor .. " " .. util.sh_quote(notes_path)
            os.execute(cmd)
        else
            local match_models = {}
            for _, name in ipairs(matches) do
                table.insert(match_models, {name = name})
            end
            local selected = picker.show_picker(match_models, cfg, "Select a model to edit notes (↑/↓ arrows, Enter to confirm, q to quit):")
            if selected then
                local notes_path = get_notes_path(selected)
                
                if not util.file_exists(notes_path) then
                    init_notes_file(selected)
                end
                
                local editor = os.getenv("EDITOR") or "vi"
                local cmd = editor .. " " .. util.sh_quote(notes_path)
                os.execute(cmd)
            end
        end
        
    else
        local model_query = subcommand
        local matches, match_type = resolve.find_matching_models(cfg, model_query)
        
        if #matches == 0 then
            print("No model found matching: " .. model_query)
            os.exit(1)
        elseif #matches == 1 then
            local content = read_notes(matches[1])
            if content then
                print(content)
            else
                print("No notes yet for " .. matches[1] .. ".")
                print("Notes file: " .. get_notes_path(matches[1]))
            end
        else
            local match_models = {}
            for _, name in ipairs(matches) do
                table.insert(match_models, {name = name})
            end
            local selected = picker.show_picker(match_models, cfg, "Select a model to view notes (↑/↓ arrows, Enter to confirm, q to quit):")
            if selected then
                local content = read_notes(selected)
                if content then
                    print(content)
                else
                    print("No notes yet for " .. selected .. ".")
                    print("Notes file: " .. get_notes_path(selected))
                end
            end
        end
    end
end

return M
