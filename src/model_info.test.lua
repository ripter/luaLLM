-- model_info.test.lua — unit tests for src/model_info.lua
-- Covers list_models (directory scan + sort) and load_model_info (cache
-- status logic).  Everything is stubbed; no real filesystem or llama.cpp.

local T = require("test_helpers")

local FAKE_CONFIG_DIR   = "/fake/config"
local FAKE_MODELS_DIR   = "/fake/models"
local MODEL_INFO_DIR    = FAKE_CONFIG_DIR .. "/model_info"

-- ---------------------------------------------------------------------------
-- Shared stub builders
-- ---------------------------------------------------------------------------

-- lfs stub: dir() returns an iterator over a provided list; attributes()
-- returns a table keyed by full path.
local function make_lfs_stub(dir_entries, attr_map)
    return {
        dir = function(path)
            local list = dir_entries[path] or {}
            local i = 0
            return function()
                i = i + 1
                return list[i]
            end
        end,
        attributes = function(path)
            return attr_map[path]   -- nil if not present
        end,
    }
end

-- util stub wired to an in-memory JSON store and configurable path_attr / is_dir.
local function make_util_stub(json_store, path_attrs, is_dir_set)
    return {
        expand_path = function(p) return p end,
        is_dir = function(p)
            return is_dir_set[p] or false
        end,
        load_json = function(path)
            return json_store[path]
        end,
        save_json = function(path, data)
            json_store[path] = data
        end,
        path_attr = function(path)
            return path_attrs[path]   -- nil means file missing
        end,
        ensure_dir = function() end,
        safe_filename = function(name)
            -- Simple stub that just returns the name for testing
            return name
        end,
        file_exists = function(path)
            return json_store[path] ~= nil
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Load a fresh model_info module with stubs
-- ---------------------------------------------------------------------------
local function load_model_info_mod(stubs)
    local mod
    T.with_stubs(stubs, function()
        mod = require("model_info")
    end)
    return mod
end

-- ---------------------------------------------------------------------------
-- tests
-- ---------------------------------------------------------------------------
return { run = function()

    -- ═══════════════════════════════════════════════════════════════════════
    -- list_models
    -- ═══════════════════════════════════════════════════════════════════════

    -- ── 1. Only .gguf files included; names stripped of extension ────────
    do
        local lfs_stub = make_lfs_stub(
            { [FAKE_MODELS_DIR] = {
                "alpha.gguf",
                "readme.txt",
                "beta.gguf",
                ".DS_Store",
                "notes.md",
            }},
            {   -- attributes keyed by full path
                [FAKE_MODELS_DIR .. "/alpha.gguf"] = { modification = 200 },
                [FAKE_MODELS_DIR .. "/beta.gguf"]  = { modification = 100 },
            }
        )
        local util_stub = make_util_stub({}, {}, { [FAKE_MODELS_DIR] = true })

        local mi = load_model_info_mod({
            lfs        = lfs_stub,
            util       = util_stub,
            config     = { CONFIG_DIR = FAKE_CONFIG_DIR },
            model_info = T.REMOVE,
            -- model_info top-level requires these; stub them out
            history    = { load_history = function() return {} end },
            gguf       = {},
            picker     = {},
            cjson      = { encode = function(v) return tostring(v) end,
                           decode = function(s) return {} end },
        })

        local models = mi.list_models(FAKE_MODELS_DIR)

        T.assert_eq(#models, 2, "only two .gguf files found")
        -- sorted by mtime descending: alpha (200) before beta (100)
        T.assert_eq(models[1].name, "alpha", "first is alpha (newer mtime)")
        T.assert_eq(models[2].name, "beta",  "second is beta (older mtime)")
    end

    -- ── 2. Empty directory → empty list ──────────────────────────────────
    do
        local lfs_stub  = make_lfs_stub({ [FAKE_MODELS_DIR] = {} }, {})
        local util_stub = make_util_stub({}, {}, { [FAKE_MODELS_DIR] = true })

        local mi = load_model_info_mod({
            lfs        = lfs_stub,
            util       = util_stub,
            config     = { CONFIG_DIR = FAKE_CONFIG_DIR },
            model_info = T.REMOVE,
            history    = { load_history = function() return {} end },
            gguf       = {},
            picker     = {},
            cjson      = { encode = function() return "[]" end, decode = function() return {} end },
        })

        local models = mi.list_models(FAKE_MODELS_DIR)
        T.assert_eq(#models, 0, "empty dir returns empty list")
    end

    -- ── 3. Non-existent directory → empty list ──────────────────────────
    do
        local lfs_stub  = make_lfs_stub({}, {})
        local util_stub = make_util_stub({}, {}, {})   -- is_dir returns false for everything

        local mi = load_model_info_mod({
            lfs        = lfs_stub,
            util       = util_stub,
            config     = { CONFIG_DIR = FAKE_CONFIG_DIR },
            model_info = T.REMOVE,
            history    = { load_history = function() return {} end },
            gguf       = {},
            picker     = {},
            cjson      = { encode = function() return "[]" end, decode = function() return {} end },
        })

        local models = mi.list_models(FAKE_MODELS_DIR)
        T.assert_eq(#models, 0, "missing dir returns empty list")
    end

    -- ── 4. Sorting: mtime descending ─────────────────────────────────────
    do
        local lfs_stub = make_lfs_stub(
            { [FAKE_MODELS_DIR] = { "old.gguf", "mid.gguf", "new.gguf" } },
            {
                [FAKE_MODELS_DIR .. "/old.gguf"] = { modification = 100 },
                [FAKE_MODELS_DIR .. "/mid.gguf"] = { modification = 200 },
                [FAKE_MODELS_DIR .. "/new.gguf"] = { modification = 300 },
            }
        )
        local util_stub = make_util_stub({}, {}, { [FAKE_MODELS_DIR] = true })

        local mi = load_model_info_mod({
            lfs        = lfs_stub,
            util       = util_stub,
            config     = { CONFIG_DIR = FAKE_CONFIG_DIR },
            model_info = T.REMOVE,
            history    = { load_history = function() return {} end },
            gguf       = {},
            picker     = {},
            cjson      = { encode = function() return "[]" end, decode = function() return {} end },
        })

        local models = mi.list_models(FAKE_MODELS_DIR)
        T.assert_eq(models[1].name, "new", "newest first")
        T.assert_eq(models[2].name, "mid", "middle second")
        T.assert_eq(models[3].name, "old", "oldest last")
    end

    -- ═══════════════════════════════════════════════════════════════════════
    -- load_model_info  (cache status paths)
    -- ═══════════════════════════════════════════════════════════════════════

    -- The four paths depend on:
    --   util.load_json(info_path)   → nil          ⇒ "no_cache"
    --   util.path_attr(gguf_path)   → nil          ⇒ "gguf_missing"
    --   fingerprint mismatch                       ⇒ "stale"
    --   fingerprint match                          ⇒ "valid"

    local function make_stubs_for_load(json_store, path_attrs)
        local util_stub = make_util_stub(json_store, path_attrs, {})
        return {
            lfs        = make_lfs_stub({}, {}),
            util       = util_stub,
            config     = { CONFIG_DIR = FAKE_CONFIG_DIR },
            model_info = T.REMOVE,
            history    = { load_history = function() return {} end },
            gguf       = {},
            picker     = {},
            cjson      = { encode = function() return "{}" end, decode = function() return {} end },
        }
    end

    -- ── 5. no_cache: load_json returns nil ───────────────────────────────
    do
        local mi = load_model_info_mod(make_stubs_for_load({}, {}))

        local info, status = mi.load_model_info("Missing")
        T.assert_eq(info,   nil,        "info is nil when no cache")
        T.assert_eq(status, "no_cache", "status is no_cache")
    end

    -- ── 6. gguf_missing: cache exists but path_attr returns nil ─────────
    do
        local gguf_path  = FAKE_MODELS_DIR .. "/GgufGone.gguf"
        local info_path  = MODEL_INFO_DIR  .. "/GgufGone.json"
        local cached_info = {
            model_name      = "GgufGone",
            gguf_path       = gguf_path,
            gguf_size_bytes = 999,
            gguf_mtime      = 888,
        }

        local mi = load_model_info_mod(make_stubs_for_load(
            { [info_path] = cached_info },   -- json store has the cache
            {}                               -- path_attrs empty → path_attr returns nil
        ))

        local info, status = mi.load_model_info("GgufGone")
        T.assert_eq(status, "gguf_missing", "status is gguf_missing")
        -- info is still returned (the cached object)
        T.assert_eq(info.model_name, "GgufGone", "cached info returned even when gguf missing")
    end

    -- ── 7. stale: fingerprint size mismatch ──────────────────────────────
    do
        local gguf_path  = FAKE_MODELS_DIR .. "/Stale.gguf"
        local info_path  = MODEL_INFO_DIR  .. "/Stale.json"
        local cached_info = {
            model_name      = "Stale",
            gguf_path       = gguf_path,
            gguf_size_bytes = 1000,
            gguf_mtime      = 500,
        }

        local mi = load_model_info_mod(make_stubs_for_load(
            { [info_path] = cached_info },
            { [gguf_path] = { size = 9999, modification = 500 } }   -- size differs
        ))

        local info, status = mi.load_model_info("Stale")
        T.assert_eq(status, "stale", "size mismatch → stale")
    end

    -- ── 8. stale: fingerprint mtime mismatch ─────────────────────────────
    do
        local gguf_path  = FAKE_MODELS_DIR .. "/StaleMtime.gguf"
        local info_path  = MODEL_INFO_DIR  .. "/StaleMtime.json"
        local cached_info = {
            model_name      = "StaleMtime",
            gguf_path       = gguf_path,
            gguf_size_bytes = 1000,
            gguf_mtime      = 500,
        }

        local mi = load_model_info_mod(make_stubs_for_load(
            { [info_path] = cached_info },
            { [gguf_path] = { size = 1000, modification = 999 } }   -- mtime differs
        ))

        local info, status = mi.load_model_info("StaleMtime")
        T.assert_eq(status, "stale", "mtime mismatch → stale")
    end

    -- ── 9. valid: fingerprint matches exactly ───────────────────────────
    do
        local gguf_path  = FAKE_MODELS_DIR .. "/Good.gguf"
        local info_path  = MODEL_INFO_DIR  .. "/Good.json"
        local cached_info = {
            model_name      = "Good",
            gguf_path       = gguf_path,
            gguf_size_bytes = 1234,
            gguf_mtime      = 5678,
        }

        local mi = load_model_info_mod(make_stubs_for_load(
            { [info_path] = cached_info },
            { [gguf_path] = { size = 1234, modification = 5678 } }   -- exact match
        ))

        local info, status = mi.load_model_info("Good")
        T.assert_eq(status, "valid", "matching fingerprint → valid")
        T.assert_eq(info.model_name, "Good", "correct info object returned")
    end

end }
