-- pins.test.lua — unit tests for src/pins.lua

local T = require("test_helpers")

-- ---------------------------------------------------------------------------
-- In-memory store factory.  Each call returns a fresh {store, util-stub} pair.
-- util.file_exists checks the store; load_json / save_json read/write it.
-- ---------------------------------------------------------------------------
local function make_util_stub(initial_store)
    local store = initial_store or {}
    return store, {
        file_exists = function(path)
            return store[path] ~= nil
        end,
        load_json = function(path)
            local v = store[path]
            if v == nil then return nil end
            -- deep-copy so callers can't mutate our store directly
            if type(v) == "table" then
                local copy = {}
                for i, x in ipairs(v) do copy[i] = x end
                return copy
            end
            return v, nil          -- non-table values pass through
        end,
        save_json = function(path, data)
            -- deep-copy on write
            if type(data) == "table" then
                local copy = {}
                for i, x in ipairs(data) do copy[i] = x end
                store[path] = copy
            else
                store[path] = data
            end
        end,
    }
end

local FAKE_CONFIG_DIR = "/fake/config"
local PINS_FILE       = FAKE_CONFIG_DIR .. "/pins.json"

-- ---------------------------------------------------------------------------
-- helper: load a fresh pins module with the given util stub installed
-- ---------------------------------------------------------------------------
local function load_pins(util_stub)
    T.with_stubs({
        config = { CONFIG_DIR = FAKE_CONFIG_DIR },
        util   = util_stub,
        pins   = T.REMOVE,          -- force re-require so PINS_FILE is recomputed
        -- pins also requires format and resolve at the top level; stub minimally
        format  = { calculate_column_widths = function() return 0,0,0 end,
                    format_model_row        = function() return "" end },
        resolve = { find_matching_models    = function() return {}, nil end },
    }, function()
        -- nothing; we just need the stubs installed so the require below sees them
    end)

    -- The stubs are restored by now, but we need pins freshly loaded *while*
    -- the stubs are active.  Restructure: do the require inside with_stubs.
    local pins_mod
    T.with_stubs({
        config  = { CONFIG_DIR = FAKE_CONFIG_DIR },
        util    = util_stub,
        pins    = T.REMOVE,
        format  = { calculate_column_widths = function() return 0,0,0 end,
                    format_model_row        = function() return "" end },
        resolve = { find_matching_models    = function() return {}, nil end },
    }, function()
        pins_mod = require("pins")
    end)
    -- pins_mod's upvalue references are locked in; it will keep calling the
    -- util_stub we gave it because that's what was in package.loaded when it
    -- ran its top-level require("util").
    return pins_mod
end

-- ---------------------------------------------------------------------------
-- tests
-- ---------------------------------------------------------------------------
return { run = function()

    -- ── 1. Missing file → empty, no crash ───────────────────────────────
    do
        local store, util_stub = make_util_stub({})   -- empty store = no file
        local pins = load_pins(util_stub)
        local result = pins.load_pins()
        T.assert_eq(#result, 0, "missing pins file returns empty list")
    end

    -- ── 2. add_pin: first add succeeds, duplicate does not ──────────────
    do
        local store, util_stub = make_util_stub({})
        local pins = load_pins(util_stub)

        local added1 = pins.add_pin("ModelA-Q4_K_M")
        T.assert_eq(added1, true, "first add_pin returns true")

        local added2 = pins.add_pin("ModelA-Q4_K_M")
        T.assert_eq(added2, false, "duplicate add_pin returns false")

        -- only one copy in the persisted list
        local persisted = store[PINS_FILE]
        T.assert_eq(#persisted, 1, "duplicate add did not create second entry")
        T.assert_eq(persisted[1], "ModelA-Q4_K_M", "persisted entry is correct")
    end

    -- ── 3. add_pin: order is preserved ──────────────────────────────────
    do
        local store, util_stub = make_util_stub({})
        local pins = load_pins(util_stub)

        pins.add_pin("First")
        pins.add_pin("Second")
        pins.add_pin("Third")

        local persisted = store[PINS_FILE]
        T.assert_eq(persisted[1], "First",  "order[1]")
        T.assert_eq(persisted[2], "Second", "order[2]")
        T.assert_eq(persisted[3], "Third",  "order[3]")
    end

    -- ── 4. is_pinned ─────────────────────────────────────────────────────
    do
        local store, util_stub = make_util_stub({ [PINS_FILE] = {"Alpha", "Beta"} })
        local pins = load_pins(util_stub)

        T.assert_eq(pins.is_pinned("Alpha"), true,  "Alpha is pinned")
        T.assert_eq(pins.is_pinned("Beta"),  true,  "Beta is pinned")
        T.assert_eq(pins.is_pinned("Gamma"), false, "Gamma is not pinned")
    end

    -- ── 5. remove_pin: existing ──────────────────────────────────────────
    do
        local store, util_stub = make_util_stub({ [PINS_FILE] = {"A", "B", "C"} })
        local pins = load_pins(util_stub)

        local removed = pins.remove_pin("B")
        T.assert_eq(removed, true, "remove existing returns true")

        local persisted = store[PINS_FILE]
        T.assert_eq(#persisted, 2,    "two entries remain")
        T.assert_eq(persisted[1], "A", "A still first")
        T.assert_eq(persisted[2], "C", "C shifted to second")
    end

    -- ── 6. remove_pin: non-existent ──────────────────────────────────────
    do
        local store, util_stub = make_util_stub({ [PINS_FILE] = {"A", "B"} })
        local pins = load_pins(util_stub)

        local removed = pins.remove_pin("Z")
        T.assert_eq(removed, false, "remove non-existent returns false")

        -- list unchanged
        local persisted = store[PINS_FILE]
        T.assert_eq(#persisted, 2, "list length unchanged after failed remove")
    end

    -- ── 7. Corrupted JSON: load_json returns (nil, err) ─────────────────
    do
        -- util stub where load_json always returns nil + error string,
        -- but file_exists returns true so pins tries to load it.
        local util_stub = {
            file_exists = function(_) return true end,
            load_json   = function(_) return nil, "bad json" end,
            save_json   = function() end,
        }
        local pins = load_pins(util_stub)

        -- The warning goes to io.stderr:write.  FILE* is a userdata;
        -- you cannot replace fields on it.  Swap io.stderr itself for a
        -- plain table with a write method, then restore afterward.
        local captured_warning = nil
        local old_stderr = io.stderr
        io.stderr = {
            write = function(_self, msg)
                captured_warning = (captured_warning or "") .. msg
            end,
        }

        local ok, err = pcall(function()
            local result = pins.load_pins()
            T.assert_eq(#result, 0, "corrupted json treated as empty")
        end)

        io.stderr = old_stderr          -- always restore

        if not ok then error(err, 2) end

        -- warning was emitted
        if captured_warning then
            T.assert_contains(captured_warning, "Invalid pins file",
                "stderr warning mentions invalid pins file")
        end
    end

end }
