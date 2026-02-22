-- state.test.lua — unit tests for src/state.lua
--
-- Design principles (matching the project's history/pins pattern):
--   - No real filesystem I/O.  util is stubbed with an in-memory store so
--     load_json / atomic_save_json / ensure_dir never touch disk.
--   - No real os.execute.  Shell commands are stubbed to return true; the
--     test captures *which* commands were attempted so we can assert on them.
--   - os.exit is stubbed to throw a catchable Lua error rather than killing
--     the process, so error-path tests work inside pcall.
--   - state module is evicted from package.loaded before each logical group
--     so CACHE_DIR / STATE_FILE constants are re-evaluated against the stub.

local T    = require("test_helpers")
local json = require("cjson")

-- ---------------------------------------------------------------------------
-- In-memory store (mirrors the history.test pattern)
-- ---------------------------------------------------------------------------

local function make_util_stub(initial_store)
    local store = initial_store or {}
    return store, {
        load_json = function(path)
            local v = store[path]
            if v == nil then return nil end
            -- return a deep copy so callers can't mutate the store directly
            return json.decode(json.encode(v))
        end,
        atomic_save_json = function(path, data)
            store[path] = json.decode(json.encode(data))
            return true
        end,
        ensure_dir = function() end,
        file_exists = function(path) return store[path] ~= nil end,
        sh_quote = function(s) return "'" .. s .. "'" end,
        iso8601 = function() return "2024-06-01T10:00:00Z" end,
    }
end

-- Stub os.execute: records every command; returns true for all by default.
-- Pass a table of { [cmd_substring] = false } to make specific commands fail.
local function make_execute_stub(failures)
    failures = failures or {}
    local calls = {}
    local function stub(cmd)
        table.insert(calls, cmd)
        for pattern, _ in pairs(failures) do
            if cmd:find(pattern, 1, true) then return false end
        end
        return true
    end
    return calls, stub
end

-- Stub os.exit to throw so error paths are testable with pcall.
local function stub_exit()
    local old = os.exit
    os.exit = function(code)
        error("os.exit(" .. tostring(code) .. ")", 2)
    end
    return function() os.exit = old end
end

-- Load a fresh state module against provided stubs.
-- Returns the module; stubs are active only inside *fn* if supplied,
-- otherwise the caller is responsible for cleanup via T.with_stubs.
local FAKE_CACHE = "/fake/cache/luallm"
local FAKE_STATE = FAKE_CACHE .. "/state.json"
local FAKE_LOGS  = FAKE_CACHE .. "/logs"
local FAKE_PIDS  = FAKE_CACHE .. "/pids"

local function load_state_mod(util_stub, env_overrides)
    local mod
    -- Patch os.getenv so CACHE_DIR resolves to our fake path
    local old_getenv = os.getenv
    os.getenv = function(k)
        if k == "XDG_CACHE_HOME" then return "/fake/cache" end
        if k == "HOME" then return "/fake/home" end
        return old_getenv(k)
    end
    T.with_stubs({ util = util_stub, state = T.REMOVE }, function()
        mod = require("state")
    end)
    os.getenv = old_getenv
    return mod
end

-- ---------------------------------------------------------------------------
-- Helper: build a state module backed by an in-memory store.
-- Returns (state_mod, store, execute_calls) where execute_calls accumulates
-- every command passed to os.execute while the stub is active.
-- ---------------------------------------------------------------------------
local function setup(initial_store)
    local store, util_stub = make_util_stub(initial_store or {})
    local exec_calls, exec_stub = make_execute_stub()

    local old_getenv = os.getenv
    local old_execute = os.execute
    os.getenv  = function(k)
        if k == "XDG_CACHE_HOME" then return "/fake/cache" end
        if k == "HOME"           then return "/fake/home"  end
        return old_getenv(k)
    end
    os.execute = exec_stub

    local mod
    T.with_stubs({ util = util_stub, state = T.REMOVE }, function()
        mod = require("state")
    end)

    -- Restore env; exec_stub stays active until the test resets os.execute.
    os.getenv = old_getenv

    return mod, store, exec_calls, function()
        os.execute = old_execute
    end
end

-- ===========================================================================
-- Tests
-- ===========================================================================

return { run = function()

    -- ── 1. safe_name: replaces bad chars with underscores ────────────────
    do
        local store, util_stub = make_util_stub()
        local s, _, _, restore = setup()
        restore()

        -- Characters outside [%w%-%._ ] become _
        T.assert_eq(s.safe_name("mistral-7b.Q4_K_M"),   "mistral-7b.Q4_K_M",
                    "alphanumeric + -/./_ preserved")
        T.assert_eq(s.safe_name("my model (v2)"),        "my_model__v2_",
                    "spaces and parens replaced with _")
        T.assert_eq(s.safe_name("foo/bar:baz"),          "foo_bar_baz",
                    "/ and : replaced")
    end

    -- ── 2. log_file_for: path is under LOGS_DIR with .log suffix ─────────
    do
        local s, _, _, restore = setup()
        restore()

        local path = s.log_file_for("my model (v2)")
        -- path must end with the safe name + .log
        T.assert_eq(path:match("my_model__v2_%.log$") ~= nil, true,
                    "log path uses safe name")
        -- and must live under the cache logs dir
        T.assert_eq(path:match("/logs/") ~= nil, true,
                    "log path is under /logs/")
    end

    -- ── 3. mark_running: writes entry, returns it ─────────────────────────
    do
        local s, store, _, restore = setup()
        restore()

        local entry = s.mark_running("alpha", 8080, "foreground")

        T.assert_eq(entry.model,      "alpha")
        T.assert_eq(entry.port,       8080)
        T.assert_eq(entry.mode,       "foreground")
        T.assert_eq(entry.state,      "running")
        T.assert_eq(entry.started_at, "2024-06-01T10:00:00Z")
        -- pid is json.null (not yet known)
        T.assert_eq(entry.pid, json.null, "pid starts as json.null")
        -- no log_file for foreground mode
        T.assert_eq(entry.log_file, nil, "foreground has no log_file")

        -- state file was persisted
        local saved = store[FAKE_STATE]
        T.assert_eq(saved ~= nil,              true,   "state file written")
        T.assert_eq(#saved.servers,            1,      "one server entry")
        T.assert_eq(saved.last_used,           "alpha","last_used set")
    end

    -- ── 4. mark_running: daemon mode includes log_file ────────────────────
    do
        local s, store, _, restore = setup()
        restore()

        local entry = s.mark_running("beta", 8081, "daemon")
        T.assert_eq(entry.log_file ~= nil, true, "daemon entry has log_file")
        T.assert_eq(entry.log_file:match("beta%.log$") ~= nil, true,
                    "log_file ends with model name + .log")
    end

    -- ── 5. mark_running: replaces existing entry for same model ───────────
    do
        local s, store, _, restore = setup()
        restore()

        s.mark_running("gamma", 8080, "foreground")
        s.mark_running("gamma", 8082, "daemon")   -- second call: different port

        local saved = store[FAKE_STATE]
        T.assert_eq(#saved.servers, 1, "only one entry per model")
        T.assert_eq(saved.servers[1].port, 8082,    "new port wins")
        T.assert_eq(saved.servers[1].mode, "daemon","new mode wins")
    end

    -- ── 6. mark_running: null port when port is nil ───────────────────────
    do
        local s, store, _, restore = setup()
        restore()

        local entry = s.mark_running("delta", nil, "foreground")
        T.assert_eq(entry.port, json.null, "nil port stored as json.null")
    end

    -- ── 7. update_pid: patches the running entry ─────────────────────────
    do
        local s, store, _, restore = setup()
        restore()

        s.mark_running("epsilon", 8080, "foreground")
        s.update_pid("epsilon", 9999)

        local entry = s.is_running("epsilon")
        T.assert_eq(entry.pid, 9999, "pid updated")
    end

    -- ── 8. is_running / mark_stopped lifecycle ───────────────────────────
    do
        local s, store, _, restore = setup()
        restore()

        -- not running yet
        T.assert_eq(s.is_running("zeta"), nil, "nil before start")

        s.mark_running("zeta", 8080, "foreground")
        T.assert_eq(s.is_running("zeta") ~= nil, true, "running after mark_running")

        s.mark_stopped("zeta", 0)
        T.assert_eq(s.is_running("zeta"), nil, "nil after mark_stopped")

        -- entry still exists in state as stopped
        local data = s.get_state()
        T.assert_eq(#data.servers, 1,                   "entry retained")
        T.assert_eq(data.servers[1].state, "stopped",   "state is stopped")
        T.assert_eq(data.servers[1].exit_code, 0,       "exit_code recorded")
        T.assert_eq(data.servers[1].stopped_at,
                    "2024-06-01T10:00:00Z",             "stopped_at set")
    end

    -- ── 9. launch_daemon: rejects if already running ─────────────────────
    do
        local s, store, exec_calls, restore = setup()

        s.mark_running("dupe", 8080, "foreground")   -- already running

        local pid, err = s.launch_daemon("dupe", "llama-server ...", 8081)

        restore()

        T.assert_eq(pid, nil,                           "pid nil on duplicate")
        T.assert_eq(err ~= nil,                         true, "error message returned")
        T.assert_contains(err, "already running",       "error mentions already running")
        T.assert_contains(err, "dupe",                  "error names the model")
        -- no shell command should have been executed
        T.assert_eq(#exec_calls, 0, "no os.execute called for duplicate")
    end

    -- ── 10. launch_daemon: happy path — writes state and reads pidfile ────
    do
        local s, store, exec_calls, restore = setup()

        -- Stub io.open so read_pid_file returns a known PID.
        -- The pidfile path is deterministic: FAKE_PIDS/<safe_name>.pid
        local pid_path  = FAKE_PIDS .. "/happy_daemon.pid"
        local log_path  = FAKE_LOGS .. "/happy_daemon.log"
        local old_open  = io.open
        io.open = function(path, mode)
            if path == pid_path and mode == "r" then
                return { read = function() return "54321" end, close = function() end }
            end
            if mode == "w" then
                -- accept log truncation open
                return { write = function() end, close = function() end }
            end
            return old_open(path, mode)
        end

        local pid, lp = s.launch_daemon("happy_daemon", "'llama-server' '-m' 'x.gguf'", 9000)

        io.open = old_open
        restore()

        T.assert_eq(pid, 54321,                    "PID read from pidfile")
        T.assert_eq(lp, log_path,                  "log path returned")

        -- state was updated with the real PID
        local running = s.is_running("happy_daemon")
        T.assert_eq(running ~= nil,        true,   "still running in state")
        T.assert_eq(running.pid,    54321,         "pid written to state")
        T.assert_eq(running.port,   9000,          "port written to state")
        T.assert_eq(running.mode,   "daemon",      "mode is daemon")

        -- nohup command was executed
        local found_nohup = false
        for _, cmd in ipairs(exec_calls) do
            if cmd:find("nohup", 1, true) then found_nohup = true end
        end
        T.assert_eq(found_nohup, true, "nohup command was executed")
    end

    -- ── 11. _stop_one (via handle_stop_command): SIGTERM → done ──────────
    do
        local s, store, exec_calls, restore = setup()

        s.mark_running("stopper", 8080, "daemon")
        s.update_pid("stopper", 1111)

        -- kill -0 returns false (process gone after SIGTERM) → no SIGKILL
        local old_execute = os.execute
        os.execute = function(cmd)
            table.insert(exec_calls, cmd)
            if cmd:find("kill -0", 1, true) then return false end
            return true
        end

        local restore_exit = stub_exit()
        T.capture_print(function()
            T.with_stubs({ state = s }, function()
                s.handle_stop_command({ "stop", "stopper" }, {})
            end)
        end)
        restore_exit()
        restore()

        -- SIGTERM sent
        local has_term = false
        for _, cmd in ipairs(exec_calls) do
            if cmd:find("kill -TERM", 1, true) and cmd:find("1111") then
                has_term = true
            end
        end
        T.assert_eq(has_term, true, "SIGTERM sent to PID 1111")

        -- no SIGKILL because kill -0 returned false
        local has_kill = false
        for _, cmd in ipairs(exec_calls) do
            if cmd:find("kill -KILL", 1, true) then has_kill = true end
        end
        T.assert_eq(has_kill, false, "no SIGKILL when process already gone")

        -- marked stopped in state
        T.assert_eq(s.is_running("stopper"), nil, "stopper marked stopped")
    end

    -- ── 12. _stop_one: escalates to SIGKILL when process survives ────────
    do
        local s, store, exec_calls, restore = setup()

        s.mark_running("stubborn", 8080, "daemon")
        s.update_pid("stubborn", 2222)

        local old_execute = os.execute
        os.execute = function(cmd)
            table.insert(exec_calls, cmd)
            -- kill -0 returns true → process still alive → should escalate
            if cmd:find("kill -0", 1, true) then return true end
            return true
        end

        local restore_exit = stub_exit()
        T.capture_print(function()
            T.with_stubs({ state = s }, function()
                s.handle_stop_command({ "stop", "stubborn" }, {})
            end)
        end)
        restore_exit()
        restore()

        local has_kill = false
        for _, cmd in ipairs(exec_calls) do
            if cmd:find("kill -KILL", 1, true) and cmd:find("2222") then
                has_kill = true
            end
        end
        T.assert_eq(has_kill, true, "SIGKILL sent when process survived SIGTERM")
    end

    -- ── 13. stop all: stops every running server ─────────────────────────
    do
        local s, store, exec_calls, restore = setup()

        s.mark_running("srv-a", 8080, "daemon")
        s.update_pid("srv-a", 3333)
        s.mark_running("srv-b", 8081, "daemon")
        s.update_pid("srv-b", 4444)

        local old_execute = os.execute
        os.execute = function(cmd)
            table.insert(exec_calls, cmd)
            if cmd:find("kill -0", 1, true) then return false end  -- both exit cleanly
            return true
        end

        local output = T.capture_print(function()
            s.handle_stop_command({ "stop", "all" }, {})
        end)

        restore()

        -- both servers were SIGTERMed
        local terms = {}
        for _, cmd in ipairs(exec_calls) do
            if cmd:find("kill -TERM", 1, true) then
                table.insert(terms, cmd)
            end
        end
        T.assert_eq(#terms, 2, "SIGTERM sent to both servers")

        -- both now stopped
        T.assert_eq(s.is_running("srv-a"), nil, "srv-a stopped")
        T.assert_eq(s.is_running("srv-b"), nil, "srv-b stopped")

        -- summary line printed
        local found_summary = false
        for _, line in ipairs(output) do
            if line:match("All servers stopped") or line:match("Stopped 2") then
                found_summary = true
            end
        end
        T.assert_eq(found_summary, true, "summary line printed")
    end

    -- ── 14. stop all: graceful when nothing running ───────────────────────
    do
        local s, _, _, restore = setup()
        restore()

        local output = T.capture_print(function()
            s.handle_stop_command({ "stop", "all" }, {})
        end)

        local found = false
        for _, line in ipairs(output) do
            if line:match("No servers") then found = true end
        end
        T.assert_eq(found, true, "no-servers message shown")
    end

    -- ── 15. stop: no match shows running list ────────────────────────────
    do
        local s, _, _, restore = setup()

        s.mark_running("visible", 8080, "daemon")

        local restore_exit = stub_exit()
        local output = T.capture_print(function()
            local ok, err = pcall(s.handle_stop_command, { "stop", "ghost" }, {})
            T.assert_eq(ok, false, "handle_stop_command should call os.exit")
            T.assert_contains(tostring(err), "os.exit(1)", "exits with code 1")
        end)
        restore_exit()
        restore()

        local found_no_match = false
        local found_visible  = false
        for _, line in ipairs(output) do
            if line:match("No running server found") then found_no_match = true end
            if line:match("visible")                 then found_visible  = true end
        end
        T.assert_eq(found_no_match, true, "no-match message shown")
        T.assert_eq(found_visible,  true, "lists available running servers")
    end

    -- ── 16. status: human-readable shows running servers ─────────────────
    do
        local s, _, _, restore = setup()

        s.mark_running("show-me", 9090, "daemon")
        s.update_pid("show-me", 7777)

        local output = T.capture_print(function()
            s.handle_status_command({ "status" }, {})
        end)
        restore()

        local found = false
        for _, line in ipairs(output) do
            if line:match("show%-me") and line:match("9090") and line:match("7777") then
                found = true
            end
        end
        T.assert_eq(found, true, "status shows model, port, and pid")
    end

    -- ── 17. status --json: valid JSON with correct schema ────────────────
    do
        local s, _, _, restore = setup()

        s.mark_running("json-test", 9091, "daemon")
        s.update_pid("json-test", 8888)
        s.mark_stopped("json-test", 0)    -- also add a stopped entry
        s.mark_running("json-test2", 9092, "foreground")

        local output = T.capture_print(function()
            s.handle_status_command({ "status", "--json" }, {})
        end)
        restore()

        T.assert_eq(#output, 1, "exactly one line of JSON output")
        local decoded = json.decode(output[1])
        T.assert_eq(decoded.version, "1.0",         "version field correct")
        T.assert_eq(#decoded.servers, 2,             "two server entries")
        -- most recent first
        T.assert_eq(decoded.servers[1].model, "json-test2", "most recent first")
        T.assert_eq(decoded.servers[1].state, "running",    "first entry running")
        T.assert_eq(decoded.servers[2].state, "stopped",    "second entry stopped")
    end

    -- ── 18. status: empty state shows helpful message ─────────────────────
    do
        local s, _, _, restore = setup()
        restore()

        local output = T.capture_print(function()
            s.handle_status_command({ "status" }, {})
        end)

        local found = false
        for _, line in ipairs(output) do
            if line:match("No server state") then found = true end
        end
        T.assert_eq(found, true, "empty state message shown")
    end

    -- ── 19. get_state: returns empty structure when no file ───────────────
    do
        local s, _, _, restore = setup()
        restore()

        local data = s.get_state()
        T.assert_eq(data.version,   "1.0", "version field present")
        T.assert_eq(type(data.servers), "table", "servers is table")
        T.assert_eq(#data.servers,  0,     "no servers initially")
    end

    -- ── 20. multiple models coexist independently ─────────────────────────
    do
        local s, store, _, restore = setup()
        restore()

        s.mark_running("model-x", 8080, "daemon")
        s.update_pid("model-x", 100)
        s.mark_running("model-y", 8081, "foreground")
        s.update_pid("model-y", 200)

        T.assert_eq(s.is_running("model-x").pid, 100, "model-x pid correct")
        T.assert_eq(s.is_running("model-y").pid, 200, "model-y pid correct")

        s.mark_stopped("model-x", 0)

        T.assert_eq(s.is_running("model-x"), nil,      "model-x stopped")
        T.assert_eq(s.is_running("model-y").pid, 200,  "model-y unaffected")

        local data = s.get_state()
        T.assert_eq(#data.servers, 2, "both entries retained")
    end
end }
