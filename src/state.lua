-- state.lua
-- Tracks which llama-server instances are running and on which ports.
-- Writes ~/.cache/luallm/state.json after every start/stop event so
-- external tools (e.g. luagent) can discover live servers without
-- polling HTTP or guessing ports.
--
-- TWO LAUNCH MODES:
--
--   Foreground (luallm run / luallm <model>):
--     Uses io.popen, streams output to stdout.  PID discovered post-hoc
--     via lsof (best-effort).
--
--   Daemon (luallm start <model>):
--     Shell one-liner:  nohup <cmd> > logfile 2>&1 & echo $! > pidfile
--     Returns immediately.  PID is exact (read straight from the pidfile).
--     Log: ~/.cache/luallm/logs/<model>.log  (overwritten each launch).
--
-- Schema (state.json version 1.0):
--   {
--     "version":   "1.0",
--     "last_used": "mistral-7b.Q4_K_M",
--     "servers": [
--       {
--         "model":      "mistral-7b.Q4_K_M",
--         "port":       11434,
--         "pid":        12345,
--         "mode":       "daemon" | "foreground",
--         "log_file":   "/path/to/model.log",   -- daemon only
--         "state":      "running" | "stopped",
--         "started_at": "2024-06-01T10:30:00Z",
--         "stopped_at": "2024-06-01T11:00:00Z"
--       }
--     ]
--   }

local util = require("util")
local json = require("cjson")

local M = {}

-- ---------------------------------------------------------------------------
-- Paths
-- ---------------------------------------------------------------------------

local CACHE_DIR = (os.getenv("XDG_CACHE_HOME") or
                   (os.getenv("HOME") .. "/.cache")) .. "/luallm"
local LOGS_DIR  = CACHE_DIR .. "/logs"
local PIDS_DIR  = CACHE_DIR .. "/pids"

M.STATE_FILE = CACHE_DIR .. "/state.json"

local function ensure_dirs()
    util.ensure_dir(CACHE_DIR)
    util.ensure_dir(LOGS_DIR)
    util.ensure_dir(PIDS_DIR)
end

local function safe_name(model_name)
    return model_name:gsub("[^%w%-%._]", "_")
end
M.safe_name = safe_name

function M.log_file_for(model_name)
    return LOGS_DIR .. "/" .. safe_name(model_name) .. ".log"
end

local function pid_file_for(model_name)
    return PIDS_DIR .. "/" .. safe_name(model_name) .. ".pid"
end

-- ---------------------------------------------------------------------------
-- Read / write
-- ---------------------------------------------------------------------------

local function load_state()
    local data = util.load_json(M.STATE_FILE)
    if not data then
        return { version = "1.0", servers = {} }
    end
    if type(data.servers) ~= "table" then data.servers = {} end
    return data
end

local function save_state(data)
    ensure_dirs()
    local ok, err = util.atomic_save_json(M.STATE_FILE, data)
    if not ok then
        io.stderr:write("luallm: warning: could not write state.json: " ..
                        tostring(err) .. "\n")
    end
end

-- ---------------------------------------------------------------------------
-- PID helpers
-- ---------------------------------------------------------------------------

-- Read the PID written by `echo $! > pidfile` in the daemon launch shell cmd.
local function read_pid_file(model_name)
    local path = pid_file_for(model_name)
    local f = io.open(path, "r")
    if not f then return nil end
    local line = f:read("*l")
    f:close()
    return tonumber(line)
end

-- Best-effort PID lookup for foreground mode via lsof.
local function discover_pid_by_port(port)
    if not port then return nil end
    local cmd = string.format(
        "lsof -t -i TCP:%d -sTCP:LISTEN 2>/dev/null | head -1", port)
    local handle = io.popen(cmd)
    if not handle then return nil end
    local out = handle:read("*l")
    handle:close()
    return tonumber(out)
end

-- ---------------------------------------------------------------------------
-- Public API: state transitions
-- ---------------------------------------------------------------------------

-- Mark a model as running.  Call before launching the process.
-- mode: "foreground" | "daemon"
function M.mark_running(model_name, port, mode)
    local data = load_state()
    for i = #data.servers, 1, -1 do
        if data.servers[i].model == model_name then
            table.remove(data.servers, i)
        end
    end

    local entry = {
        model      = model_name,
        port       = port or json.null,
        pid        = json.null,
        mode       = mode or "foreground",
        state      = "running",
        started_at = util.iso8601(),
    }
    if mode == "daemon" then
        entry.log_file = M.log_file_for(model_name)
    end

    table.insert(data.servers, 1, entry)
    data.last_used = model_name
    save_state(data)
    return entry
end

-- Write a concrete PID into the running entry.
function M.update_pid(model_name, pid)
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

-- Best-effort lsof PID update for the foreground path.
function M.try_update_pid(model_name, port)
    local pid = discover_pid_by_port(port)
    if pid then M.update_pid(model_name, pid) end
end

-- Mark a model as stopped.
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

-- Return the running state entry for a model, or nil if not running.
function M.is_running(model_name)
    local data = load_state()
    for _, entry in ipairs(data.servers) do
        if entry.model == model_name and entry.state == "running" then
            return entry
        end
    end
    return nil
end

-- Return the current state table.
function M.get_state()
    return load_state()
end

-- ---------------------------------------------------------------------------
-- luallm start <model> — daemon launch
-- ---------------------------------------------------------------------------

-- Called by model_info.start_model_daemon after building the command.
-- Launches the server in the background; writes PID to a pidfile; returns
-- the PID and log path so the caller can print a confirmation.
function M.launch_daemon(model_name, cmd, port)
    ensure_dirs()

    -- Refuse to start if already running — prevents zombie orphans
    local existing = M.is_running(model_name)
    if existing then
        local pid_str = type(existing.pid) == "number"
                        and (" (PID " .. existing.pid .. ")") or ""
        local port_str = type(existing.port) == "number"
                         and (" on port " .. existing.port) or ""
        return nil, string.format(
            "%s is already running%s%s\nUse 'luallm stop %s' first.",
            model_name, pid_str, port_str, model_name)
    end

    local log_path = M.log_file_for(model_name)
    local pid_path = pid_file_for(model_name)

    -- Truncate the log file at launch so stale output is never shown
    local lf = io.open(log_path, "w")
    if lf then lf:close() end

    -- Shell one-liner:
    --   nohup … redirects so the process survives terminal close.
    --   >> appends; the explicit truncation above handles the "overwrite each launch" requirement.
    --   $! is the PID of the backgrounded nohup process.
    local shell_cmd = string.format(
        "nohup %s >> %s 2>&1 & echo $! > %s",
        cmd,
        util.sh_quote(log_path),
        util.sh_quote(pid_path)
    )

    M.mark_running(model_name, port, "daemon")

    local ok = os.execute(shell_cmd)
    if not ok then
        M.mark_stopped(model_name, 1)
        return nil, "failed to launch server"
    end

    -- Give the shell a moment to write the pidfile then read it
    os.execute("sleep 0.3")
    local pid = read_pid_file(model_name)
    if pid then
        M.update_pid(model_name, pid)
    end

    return pid, log_path
end

-- ---------------------------------------------------------------------------
-- Private: stop one running entry — shared by "stop <model>" and "stop all"
-- Returns true on success, or false + error string on failure.
-- ---------------------------------------------------------------------------
local function _stop_one(entry)
    -- PID resolution priority: pidfile → state.json → lsof
    local pid = read_pid_file(entry.model)
    if not pid then
        pid = type(entry.pid) == "number" and entry.pid or nil
    end
    if not pid then
        pid = discover_pid_by_port(type(entry.port) == "number" and entry.port or nil)
    end

    if pid then
        print(string.format("  Stopping %s (PID %d)...", entry.model, pid))
        os.execute(string.format("kill -TERM %d 2>/dev/null", pid))
        os.execute("sleep 1")
        -- os.execute returns true on exit code 0 (Lua 5.2+).
        -- kill -0 exits 0 if the process is still alive, non-zero if gone.
        if os.execute(string.format("kill -0 %d 2>/dev/null", pid)) then
            print("  Still running after SIGTERM — sending SIGKILL...")
            os.execute(string.format("kill -KILL %d 2>/dev/null", pid))
        end
        os.remove(pid_file_for(entry.model))
    else
        return false, "no PID found"
    end

    M.mark_stopped(entry.model, 0)
    return true
end

-- ---------------------------------------------------------------------------
-- luallm stop <model> | all
-- ---------------------------------------------------------------------------

local function find_running_entry(model_query)
    local data = load_state()
    local q = model_query:lower()
    for _, entry in ipairs(data.servers) do
        if entry.state == "running" and entry.model:lower():find(q, 1, true) then
            return entry
        end
    end
    return nil
end

function M.handle_stop_command(args, cfg)
    local model_query = args[2]

    -- "stop all" — stop every running server
    if model_query and model_query:lower() == "all" then
        local data = load_state()
        local running = {}
        for _, e in ipairs(data.servers) do
            if e.state == "running" then table.insert(running, e) end
        end

        if #running == 0 then
            print("No servers are currently running.")
            return
        end

        print("Stopping " .. #running .. " running server(s)...")
        local failed = 0
        for _, entry in ipairs(running) do
            local ok, err = _stop_one(entry)
            if not ok then
                print("  ✗ " .. entry.model .. ": " .. (err or "unknown error"))
                failed = failed + 1
            else
                print("  ✓ Stopped " .. entry.model)
            end
        end
        print()
        if failed == 0 then
            print("All servers stopped.")
        else
            print(string.format("Stopped %d/%d. %d failed.",
                #running - failed, #running, failed))
        end
        return
    end

    -- "stop <model>"
    if not model_query then
        print("Error: missing model name")
        print("Usage: luallm stop <model> | all")
        os.exit(1)
    end

    local entry = find_running_entry(model_query)
    if not entry then
        print("No running server found matching: " .. model_query)
        local data = load_state()
        local running = {}
        for _, e in ipairs(data.servers) do
            if e.state == "running" then table.insert(running, e.model) end
        end
        if #running > 0 then
            print()
            print("Currently running (per state.json):")
            for _, name in ipairs(running) do print("  " .. name) end
        end
        os.exit(1)
    end

    local ok, err = _stop_one(entry)
    if not ok then
        print("Warning: " .. (err or "could not send signal"))
        print("If the server is still running, stop it manually.")
    end
    print("✓ " .. entry.model .. " stopped")
end

-- ---------------------------------------------------------------------------
-- luallm status
-- ---------------------------------------------------------------------------

function M.handle_status_command(args, cfg)
    if args[2] == "--json" then
        print(json.encode(load_state()))
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

    local running, stopped = {}, {}
    for _, e in ipairs(data.servers) do
        if e.state == "running" then table.insert(running, e)
        else                         table.insert(stopped, e) end
    end

    if #running > 0 then
        print("RUNNING:")
        for _, e in ipairs(running) do
            local port_str = type(e.port) == "number" and tostring(e.port) or "?"
            local pid_str  = type(e.pid)  == "number" and tostring(e.pid)  or "?"
            local mode_tag = e.mode == "daemon" and " [daemon]" or " [fg]"
            print(string.format("  %-42s  port %-6s  pid %-7s%s",
                e.model, port_str, pid_str, mode_tag))
            if e.started_at then
                print(string.format("  %s  started %s",
                    string.rep(" ", 42), e.started_at))
            end
            if e.log_file then
                print(string.format("  %s  log     %s",
                    string.rep(" ", 42), e.log_file))
            end
        end
        print()
    else
        print("No servers currently running.")
        print()
    end

    if #stopped > 0 then
        print("RECENTLY STOPPED:")
        for i = 1, math.min(5, #stopped) do
            local e = stopped[i]
            local port_str = type(e.port) == "number" and tostring(e.port) or "?"
            print(string.format("  %-42s  port %-6s  stopped %s",
                e.model, port_str, e.stopped_at or "unknown"))
        end
        print()
    end

    if data.last_used then print("Last used: " .. data.last_used) end
end

-- ---------------------------------------------------------------------------
-- luallm logs <model> [--follow]
-- ---------------------------------------------------------------------------

function M.handle_logs_command(args, cfg)
    local model_query = nil
    local follow = false
    for i = 2, #args do
        if args[i] == "--follow" or args[i] == "-f" then
            follow = true
        elseif args[i]:sub(1, 1) ~= "-" and not model_query then
            model_query = args[i]
        end
    end

    -- If no query, find any model with an existing log file
    if not model_query then
        local data = load_state()
        local candidates = {}
        for _, e in ipairs(data.servers) do
            if e.log_file and util.file_exists(e.log_file) then
                table.insert(candidates, e)
            end
        end
        if #candidates == 0 then
            print("No log files found.")
            print("Logs are created when you use: luallm start <model>")
            os.exit(0)
        elseif #candidates == 1 then
            model_query = candidates[1].model
        else
            print("Multiple log files available:")
            for i, e in ipairs(candidates) do
                print(string.format("  [%d] %s", i, e.model))
            end
            io.write("Enter number: ")
            io.flush()
            local choice = tonumber(io.read("*l"))
            if not choice or not candidates[choice] then
                print("Invalid selection"); os.exit(1)
            end
            model_query = candidates[choice].model
        end
    end

    -- Resolve log path via state.json, then fall back to canonical path
    local log_path
    local data = load_state()
    local q = model_query:lower()
    for _, e in ipairs(data.servers) do
        if e.model:lower():find(q, 1, true) and e.log_file then
            log_path = e.log_file
            break
        end
    end
    log_path = log_path or M.log_file_for(model_query)

    if not util.file_exists(log_path) then
        print("No log file found for: " .. model_query)
        print("Expected: " .. log_path)
        os.exit(1)
    end

    if follow then
        print("Following " .. log_path .. "  (Ctrl-C to stop)")
        print()
        os.execute("tail -f " .. util.sh_quote(log_path))
    else
        print("Log: " .. log_path)
        print()
        os.execute("cat " .. util.sh_quote(log_path))
    end
end

return M
