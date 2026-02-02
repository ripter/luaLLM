local M = {}

local function read_u32_le(file)
    local bytes = file:read(4)
    if not bytes or #bytes ~= 4 then return nil end
    local b1, b2, b3, b4 = bytes:byte(1, 4)
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function read_u64_le(file)
    local bytes = file:read(8)
    if not bytes or #bytes ~= 8 then return nil end
    local b1, b2, b3, b4, b5, b6, b7, b8 = bytes:byte(1, 8)
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216 + 
           b5 * 4294967296 + b6 * 1099511627776 + 
           b7 * 281474976710656 + b8 * 72057594037927936
end

local function read_gguf_string(file)
    local len = read_u64_le(file)
    if not len then return nil end
    if len == 0 then return "" end
    if len > 1000000 then
        file:seek("cur", len)
        return nil
    end
    return file:read(len)
end

local function skip_gguf_value(file, type_id)
    if type_id == 0 or type_id == 1 then
        file:read(1)
    elseif type_id == 2 or type_id == 3 then
        file:read(2)
    elseif type_id == 4 or type_id == 5 then
        file:read(4)
    elseif type_id == 6 then
        file:read(4)
    elseif type_id == 7 then
        file:read(1)
    elseif type_id == 8 then
        read_gguf_string(file)
    elseif type_id == 10 or type_id == 11 then
        file:read(8)
    elseif type_id == 12 then
        file:read(8)
    elseif type_id == 9 then
        local elem_type = read_u32_le(file)
        local count = read_u64_le(file)
        if not elem_type or not count then return false end
        
        for i = 1, count do
            skip_gguf_value(file, elem_type)
        end
    else
        return false
    end
    return true
end

local function read_gguf_array(file, type_id)
    if type_id ~= 9 then return nil end
    
    local elem_type = read_u32_le(file)
    local count = read_u64_le(file)
    if not elem_type or not count then return nil end
    
    if elem_type == 8 then
        local strings = {}
        for i = 1, count do
            local s = read_gguf_string(file)
            if s then
                table.insert(strings, s)
            else
                return nil
            end
        end
        return strings
    end
    
    return nil
end

function M.read_gguf_general_tags(gguf_path)
    local file = io.open(gguf_path, "rb")
    if not file then return nil end
    
    local ok, result = pcall(function()
        local magic = read_u32_le(file)
        if not magic or magic ~= 0x46554747 then
            return nil
        end
        
        local version = read_u32_le(file)
        if not version or version < 2 then
            return nil
        end
        
        local n_tensors = read_u64_le(file)
        local n_kv = read_u64_le(file)
        if not n_tensors or not n_kv then return nil end
        
        for i = 1, n_kv do
            local key = read_gguf_string(file)
            if not key then return nil end
            
            local type_id = read_u32_le(file)
            if not type_id then return nil end
            
            if key == "general.tags" then
                return read_gguf_array(file, type_id)
            else
                if not skip_gguf_value(file, type_id) then
                    return nil
                end
            end
        end
        
        return nil
    end)
    
    file:close()
    
    if ok then
        return result
    else
        return nil
    end
end

return M
