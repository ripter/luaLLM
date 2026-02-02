local M = {}
local model_info

function M.find_matching_models(config, query)
    if not model_info then
        model_info = require("model_info")
    end
    
    local all_models = model_info.list_models(config.models_dir)
    local query_lower = query:lower()
    
    for _, model in ipairs(all_models) do
        if model.name:lower() == query_lower then
            return {model.name}, "exact"
        end
    end
    
    local matches = {}
    for _, model in ipairs(all_models) do
        if model.name:lower():find(query_lower, 1, true) then
            table.insert(matches, model.name)
        end
    end
    
    if #matches > 0 then
        return matches, "substring"
    end
    
    return {}, "none"
end

return M
