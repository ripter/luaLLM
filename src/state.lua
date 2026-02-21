-- state.lua
-- Tracks which llama-server instances are running and on which ports.
-- Writes ~/.cache/luallm/state.json after every start/stop event so
-- external tools (e.g. luagent) can discover live servers without
-- polling HTTP or guessing ports.
--
-- Schema (version 1.0):
--   {
--     "version": "1.0",
--     "last_used": "mistral-7b.Q4_K_M",       -- most recently started model
--     "servers": [
--       {
--         "model":      "mistral-7b.Q4_K_M",   -- model name (no .gguf)
--         "port":       11434,                  -- integer, or null if unknown
--         "pid":        12345,                  -- integer, or null if unavailable
--         "state":      "running" | "stopped",
--         "started_at": "2024-06-01T10:30:00Z", -- ISO 8601 UTC
--         "stopped_at": "2024-06-01T11:00:00Z"  -- ISO 8601 UTC, only when stopped
--       }
--     ]
--   }
--
-- Notes on PID:
--   Standard Lua io.popen does not expose the child PID.  We attempt to
--   discover it by querying lsof/lsof (macOS/Linux) for the known port after
--   the server starts.  If discovery fails the field is written as json null.

local util   = require("util")
local config = require("config")
local json   = require("cjson")

local M = {}

-- ---------------------------------------------------------------------------
-- Paths
-- ---------------------------------------------------------------------------

local CACHE_DIR = (os.getenv("XDG_CACHE_HOME") or
                   (os.getenv("HOME") .. "/.cache")) .. "/luallm"

M.STATE_FILE = CACHE_DIR .. "/state.json"

local function ensure_cache_dir()
    util.ensure_dir(CACHE_DIR)
end

-- ---------------------------------------------------------------------------
-- Read / write
-- ---------------------------------------------------------------------------

local function load_state()
    local data, err = util.load_json(M.STATE_FILE)
    if not data then
        return { version = "1.0", servers = {} }
    end
    -- Ensure servers is always a table even if the file was hand-edited
    if type(data.servers) ~= "table" then
        data.servers = {}
    end
    return data
end

local function save_state(data)
    ensure_cache_dir()
    local ok, err = util.atomic_save_json(M.STATE_FILE, data)
    if not ok then
        -- Non-fatal: log to stderr and continue.  The server still runs;
        -- state.json is a convenience file, not a hard requirement.
        io.stderr:write("luallm: warning: could not write state.json: " ..
                        tostring(err) .. "\n")
    end
end

-- ---------------------------------------------------------------------------
-- PID discovery
-- ---------------------------------------------------------------------------

-- Attempt to find the PID of the process listening on *port* using lsof.
-- Returns an integer PID, or nil if discovery fails or port is nil.
local function discover_pid(port)
    if not port then return nil end

    -- lsof is available on macOS and most Linux distros.
    -- -t: terse output (PIDs only), -i: internet address filter, -sTCP:LISTEN
    local cmd = string.format(
        "lsof -t -i TCP:%d -sTCP:LISTEN 2>/dev/null | head -1", port)
    local handle = io.popen(cmd)
    if not handle then return nil end
    local out = handle:read("*l")
    handle:close()
    return tonumber(out)   -- nil if empty or non-numeric
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Call this just before io.popen launches llama-server.
-- *model_name*: string — the model name (no .gguf suffix)
-- *port*: integer or nil — parsed from the argv
function M.mark_running(model_name, port)
    local data = load_state()

    -- Remove any stale entry for this model
    for i = #data.servers, 1, -1 do
        if data.servers[i].model == model_name then
            table.remove(data.servers, i)
        end
    end

    local entry = {
        model      = model_name,
        port       = port or json.null,
        pid        = json.null,           -- will be updated by mark_pid_discovered
        state      = "running",
        started_at = util.iso8601(),
    }

    table.insert(data.servers, 1, entry)
    data.last_used = model_name

    save_state(data)
    return entry
end

-- Call this after the server has had a moment to bind its port.
-- Attempts PID discovery and patches the state file in place.
function M.try_update_pid(model_name, port)
    if not port then return end
    local pid = discover_pid(port)
    if not pid then return end

    local data = load_state()
    for _, entry in ipairs(data.servers) do
        if entry.model == model_name and entry.state == "running" then
            entry.pid = pid
            break
        end
    end
    save_state(data)
end

-- Call this when the server process exits (normally or via interrupt).
-- *exit_code*: integer
function M.mark_stopped(model_name, exit_code)
    local data = load_state()

    for _, entry in ipairs(data.servers) do
        if entry.model == model_name and entry.state == "running" then
            entry.state      = "stopped"
            entry.stopped_at = util.iso8601()
            entry.exit_code  = exit_code or 0
            break
        end
    end

    save_state(data)
end

-- Returns the current state table (or an empty one if the file doesn't exist).
function M.get_state()
    return load_state()
end

-- ---------------------------------------------------------------------------
-- luallm stop <model>
-- ---------------------------------------------------------------------------

-- Find a running server entry by fuzzy model name match.
local function find_running(model_query)
    local data = load_state()
    local query_lower = model_query:lower()
    for _, entry in ipairs(data.servers) do
        if entry.state == "running" then
            if entry.model:lower():find(query_lower, 1, true) then
                return entry
            end
        end
    end
    return nil
end

-- Attempt to stop a running server.
-- Strategy:
--   1. Look up the server in state.json by model name.
--   2. If we have a PID, send SIGTERM directly.
--   3. If we have a port but no PID, discover PID via lsof then SIGTERM.
--   4. Mark stopped in state.json.
function M.handle_stop_command(args, cfg)
    local model_query = args[2]
    if not model_query then
        print("Error: missing model name")
        print("Usage: luallm stop <model>")
        os.exit(1)
    end

    local entry = find_running(model_query)
    if not entry then
        print("No running server found matching: " .. model_query)

        -- Show what is in state.json so the user knows what's available
        local data = load_state()
        local running = {}
        for _, e in ipairs(data.servers) do
            if e.state == "running" then
                table.insert(running, e.model)
            end
        end
        if #running > 0 then
            print()
            print("Currently running (per state.json):")
            for _, name in ipairs(running) do
                print("  " .. name)
            end
        end
        os.exit(1)
    end

    -- Resolve PID
    local pid = (entry.pid ~= json.null and type(entry.pid) == "number")
                and entry.pid
                or  discover_pid(type(entry.port) == "number" and entry.port or nil)

    if pid then
        print(string.format("Stopping %s (PID %d)...", entry.model, pid))
        local kill_cmd = string.format("kill -TERM %d 2>/dev/null", pid)
        os.execute(kill_cmd)
        -- Give the process a moment to exit, then check
        os.execute("sleep 1")
        local still_alive = discover_pid(type(entry.port) == "number" and entry.port or nil)
        if still_alive then
            print("Process did not exit after SIGTERM; sending SIGKILL...")
            os.execute(string.format("kill -KILL %d 2>/dev/null", pid))
        end
    else
        print(string.format(
            "Warning: no PID found for %s — cannot send signal.", entry.model))
        print("If the server is still running, stop it manually.")
    end

    M.mark_stopped(entry.model, 0)
    print("✓ Marked " .. entry.model .. " as stopped in state.json")
end

-- ---------------------------------------------------------------------------
-- luallm status
-- ---------------------------------------------------------------------------

function M.handle_status_command(args, cfg)
    -- --json flag: output raw state.json contents
    if args[2] == "--json" then
        local data = load_state()
        print(json.encode(data))
        return
    end

    local data = load_state()

    if #data.servers == 0 then
        print("No server state recorded yet.")
        print("State file: " .. M.STATE_FILE)
        return
    end

    print("luallm server state  (" .. M.STATE_FILE .. ")")
    print()

    local running_count = 0
    for _, entry in ipairs(data.servers) do
        if entry.state == "running" then running_count = running_count + 1 end
    end

    -- Running servers first
    if running_count > 0 then
        print("RUNNING:")
        for _, entry in ipairs(data.servers) do
            if entry.state == "running" then
                local port_str = type(entry.port) == "number"
                                 and ("port " .. entry.port)
                                 or  "port unknown"
                local pid_str  = type(entry.pid) == "number"
                                 and ("pid " .. entry.pid)
                                 or  "pid unknown"
                print(string.format("  %-40s  %s  %s",
                    entry.model, port_str, pid_str))
                if entry.started_at then
                    print(string.format("  %s  started %s",
                        string.rep(" ", 40), entry.started_at))
                end
            end
        end
        print()
    end

    -- Recent stopped servers (last 5)
    local stopped = {}
    for _, entry in ipairs(data.servers) do
        if entry.state == "stopped" then
            table.insert(stopped, entry)
        end
    end

    if #stopped > 0 then
        print("RECENTLY STOPPED:")
        for i = 1, math.min(5, #stopped) do
            local entry = stopped[i]
            local port_str = type(entry.port) == "number"
                             and ("port " .. entry.port)
                             or  "port unknown"
            print(string.format("  %-40s  %s  stopped %s",
                entry.model, port_str, entry.stopped_at or "unknown"))
        end
        print()
    end

    if data.last_used then
        print("Last used: " .. data.last_used)
    end
end

return M
