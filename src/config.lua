local util = require("util")

local M = {}

M.CONFIG_DIR = (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. "/luaLLM"
M.CONFIG_FILE = M.CONFIG_DIR .. "/config.json"

local function ensure_config_dir()
    util.ensure_dir(M.CONFIG_DIR)
end

local function create_default_config()
    ensure_config_dir()
    
    local example_path = "config.example.json"
    if util.file_exists(example_path) then
        util.exec("cp " .. util.sh_quote(example_path) .. " " .. util.sh_quote(M.CONFIG_FILE))
    else
        local default = {
            llama_cpp_path = "/usr/local/bin/llama-server",
            models_dir = os.getenv("HOME") .. "/models",
            default_port = 8080,
            recent_models_count = 7,
            default_params = {"-c 4096", "--host 127.0.0.1"}
        }
        util.save_json(M.CONFIG_FILE, default)
    end
end

function M.load_config()
    ensure_config_dir()
    local cfg, err = util.load_json(M.CONFIG_FILE)
    
    if err then
        print("Error: " .. err)
        print("Creating default config...")
        create_default_config()
        cfg = util.load_json(M.CONFIG_FILE)
    end
    
    if not cfg then
        print("Error: Could not load config")
        os.exit(1)
    end
    
    return cfg
end

return M
