-- history.test.lua — unit tests for src/history.lua

local T = require("test_helpers")

-- ---------------------------------------------------------------------------
-- In-memory store (same pattern as pins.test)
-- ---------------------------------------------------------------------------
local function make_util_stub(initial_store)
    local store = initial_store or {}
    return store, {
        load_json = function(path)
            local v = store[path]
            if v == nil then return nil end
            -- deep-copy array
            if type(v) == "table" then
                local copy = {}
                for i, entry in ipairs(v) do
                    if type(entry) == "table" then
                        local e = {}
                        for k2, v2 in pairs(entry) do e[k2] = v2 end
                        copy[i] = e
                    else
                        copy[i] = entry
                    end
                end
                return copy
            end
            return v
        end,
        save_json = function(path, data)
            -- deep-copy array of tables on write
            if type(data) == "table" then
                local copy = {}
                for i, entry in ipairs(data) do
                    if type(entry) == "table" then
                        local e = {}
                        for k2, v2 in pairs(entry) do e[k2] = v2 end
                        copy[i] = e
                    else
                        copy[i] = entry
                    end
                end
                store[path] = copy
            else
                store[path] = data
            end
        end,
    }
end

local FAKE_CONFIG_DIR = "/fake/config"
local HISTORY_FILE    = FAKE_CONFIG_DIR .. "/history.json"

-- ---------------------------------------------------------------------------
-- Load a fresh history module with stubs active
-- ---------------------------------------------------------------------------
local function load_history_mod(util_stub)
    local mod
    T.with_stubs({
        config  = { CONFIG_DIR = FAKE_CONFIG_DIR },
        util    = util_stub,
        history = T.REMOVE,     -- recompute HISTORY_FILE against our config stub
    }, function()
        mod = require("history")
    end)
    return mod
end

-- ---------------------------------------------------------------------------
-- tests
-- ---------------------------------------------------------------------------
return { run = function()

    -- ── 1. add_to_history: prepends new entry with stubbed os.time ───────
    do
        local store, util_stub = make_util_stub({})
        local history = load_history_mod(util_stub)

        local old_time = os.time
        os.time = function() return 1000 end

        history.add_to_history("ModelA")

        os.time = old_time

        local persisted = store[HISTORY_FILE]
        T.assert_eq(#persisted, 1,                  "one entry after first add")
        T.assert_eq(persisted[1].name, "ModelA",    "entry name is correct")
        T.assert_eq(persisted[1].last_run, 1000,    "last_run set to stubbed time")
        T.assert_eq(persisted[1].status, "running", "default status is running")
    end

    -- ── 2. add_to_history: re-add moves to front, no duplicates ─────────
    do
        -- seed with two entries
        local store, util_stub = make_util_stub({
            [HISTORY_FILE] = {
                { name = "ModelA", last_run = 100, status = "exit" },
                { name = "ModelB", last_run = 90,  status = "exit" },
            }
        })
        local history = load_history_mod(util_stub)

        local old_time = os.time
        os.time = function() return 2000 end

        history.add_to_history("ModelB")   -- ModelB already exists, not "running"

        os.time = old_time

        local persisted = store[HISTORY_FILE]
        T.assert_eq(#persisted, 2,                  "still two entries, no duplicate")
        T.assert_eq(persisted[1].name, "ModelB",    "ModelB moved to front")
        T.assert_eq(persisted[1].last_run, 2000,    "ModelB last_run updated")
        T.assert_eq(persisted[2].name, "ModelA",    "ModelA is now second")
    end

    -- ── 3. add_to_history: updates existing "running" entry in place ─────
    do
        local store, util_stub = make_util_stub({
            [HISTORY_FILE] = {
                { name = "ModelA", last_run = 500, status = "running" },
                { name = "ModelB", last_run = 400, status = "exit" },
            }
        })
        local history = load_history_mod(util_stub)

        local old_time = os.time
        os.time = function() return 3000 end

        -- call with status="exit" and exit_code=0 — this hits the
        -- "found running entry" branch and updates it in place
        history.add_to_history("ModelA", "exit", 0)

        os.time = old_time

        local persisted = store[HISTORY_FILE]
        -- entry stays at index 1 (in-place update, not moved)
        T.assert_eq(persisted[1].name, "ModelA",  "ModelA still at front")
        T.assert_eq(persisted[1].status, "exit",  "status updated to exit")
        T.assert_eq(persisted[1].exit_code, 0,    "exit_code recorded")
        T.assert_eq(persisted[1].end_time, 3000,  "end_time set to stubbed time")
    end

    -- ── 4. get_recent_models: respects exclude_set and limit ─────────────
    do
        local store, util_stub = make_util_stub({
            [HISTORY_FILE] = {
                { name = "A", last_run = 500, status = "exit" },
                { name = "B", last_run = 400, status = "exit" },
                { name = "C", last_run = 300, status = "exit" },
                { name = "D", last_run = 200, status = "exit" },
                { name = "E", last_run = 100, status = "exit" },
            }
        })
        local history = load_history_mod(util_stub)

        -- exclude A and C, limit 2 → should get B, D
        local cfg = { recent_models_count = 99 }   -- high default; we pass explicit limit
        local recent = history.get_recent_models(cfg, { A = true, C = true }, 2)

        T.assert_eq(#recent, 2,          "exactly 2 returned")
        T.assert_eq(recent[1].name, "B", "first non-excluded is B")
        T.assert_eq(recent[2].name, "D", "second non-excluded is D")
    end

    -- ── 5. get_recent_models: backfill — scans past excluded entries ─────
    do
        -- All of the first 3 are excluded; limit is 2.
        -- Must scan past them to find D and E.
        local store, util_stub = make_util_stub({
            [HISTORY_FILE] = {
                { name = "X", last_run = 600, status = "exit" },
                { name = "Y", last_run = 500, status = "exit" },
                { name = "Z", last_run = 400, status = "exit" },
                { name = "D", last_run = 300, status = "exit" },
                { name = "E", last_run = 200, status = "exit" },
            }
        })
        local history = load_history_mod(util_stub)

        local cfg = {}
        local recent = history.get_recent_models(cfg, { X=true, Y=true, Z=true }, 2)

        T.assert_eq(#recent, 2,          "backfill returned 2")
        T.assert_eq(recent[1].name, "D", "backfill[1] = D")
        T.assert_eq(recent[2].name, "E", "backfill[2] = E")
    end

    -- ── 6. get_recent_models: deduplicates repeated names ───────────────
    do
        local store, util_stub = make_util_stub({
            [HISTORY_FILE] = {
                { name = "A", last_run = 600, status = "exit" },
                { name = "A", last_run = 500, status = "exit" },   -- dup
                { name = "B", last_run = 400, status = "exit" },
            }
        })
        local history = load_history_mod(util_stub)

        local recent = history.get_recent_models({}, {}, 3)

        T.assert_eq(#recent, 2,          "duplicates collapsed")
        T.assert_eq(recent[1].name, "A", "first A kept")
        T.assert_eq(recent[2].name, "B", "B is second")
    end

    -- ── 7. clear_history: load after clear returns empty ────────────────
    do
        local store, util_stub = make_util_stub({
            [HISTORY_FILE] = {
                { name = "A", last_run = 100, status = "exit" },
            }
        })
        local history = load_history_mod(util_stub)

        history.clear_history()

        local after = history.load_history()
        T.assert_eq(#after, 0, "history empty after clear")

        -- store itself holds the empty array
        T.assert_eq(#store[HISTORY_FILE], 0, "persisted store is empty after clear")
    end

end }
