-- resolver.lua
-- Unified model resolution with picker support for consistent fuzzy matching across all commands

local resolve = require("resolve")
local picker = require("picker")
local format = require("format")
local model_info = require("model_info")

local M = {}

-- ---------------------------------------------------------------------------
-- Shared model resolution with picker
-- ---------------------------------------------------------------------------

-- Resolve a model name with consistent fuzzy matching and picker behavior.
--
-- Arguments:
--   config: config table
--   query: model name query string (can be nil for picker-only mode)
--   opts: optional table with:
--     - title: custom picker title (default: generic "Select a model...")
--     - allow_picker: if false, return nil on ambiguity instead of showing picker (default true)
--     - show_suggestions: if true, print suggestions on no match (default true)
--     - picker_fn: override picker function for testing (default: picker.show_picker)
--     - on_no_match: function(query) called when no match found, before suggestions
--
-- Returns:
--   model_name (string or nil): resolved model name, or nil if user quit/not found
--   match_type (string): "exact", "substring", "picker", "none"
function M.resolve_model_name(config, query, opts)
    opts = opts or {}
    local allow_picker = opts.allow_picker ~= false
    local show_suggestions = opts.show_suggestions ~= false
    local picker_fn = opts.picker_fn or picker.show_picker
    local title = opts.title or "Select a model (↑/↓ arrows, Enter to confirm, q to quit):"
    
    -- If no query, show picker with all models
    if not query or query == "" then
        if not allow_picker then
            return nil, "none"
        end
        local all_models = model_info.list_models(config.models_dir)
        if #all_models == 0 then
            if show_suggestions then
                print("No models found.")
            end
            return nil, "none"
        end
        local selected = picker_fn(all_models, config, title)
        return selected, selected and "picker" or "none"
    end
    
    -- Find matches using existing resolve logic
    local matches, match_type = resolve.find_matching_models(config, query)
    
    if match_type == "exact" then
        -- Single exact match
        return matches[1], "exact"
    elseif match_type == "substring" then
        if #matches == 1 then
            -- Single substring match
            return matches[1], "substring"
        elseif #matches > 1 then
            -- Multiple matches - show picker if allowed
            if not allow_picker then
                if show_suggestions then
                    print("Multiple models match '" .. query .. "':")
                    for _, name in ipairs(matches) do
                        print("  " .. name)
                    end
                end
                return nil, "ambiguous"
            end
            
            local match_models = {}
            for _, name in ipairs(matches) do
                table.insert(match_models, {name = name})
            end
            
            local selected = picker_fn(match_models, config, title)
            return selected, selected and "picker" or "none"
        end
    end
    
    -- No matches - call hook if provided
    if opts.on_no_match then
        opts.on_no_match(query)
    end
    
    -- Show suggestions
    if show_suggestions then
        print("No model found matching: " .. query)
        print()
        print("Available models:")
        local all_models = model_info.list_models(config.models_dir)
        local suggestions = {}
        for i = 1, math.min(10, #all_models) do
            local _, size_str, quant, last_run_str = format.get_model_row(config, all_models[i].name)
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
    end
    
    return nil, "none"
end

-- ---------------------------------------------------------------------------
-- Helper: resolve and exit on failure
-- ---------------------------------------------------------------------------

-- Resolve a model name and os.exit(1) if not found or user quit.
-- Use this in command handlers that require a model.
function M.resolve_or_exit(config, query, opts)
    local model_name, match_type = M.resolve_model_name(config, query, opts)
    if not model_name then
        os.exit(1)
    end
    return model_name
end

return M
