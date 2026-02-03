-- format.test.lua — unit tests for src/format.lua

local format       = require("format")
local test_helpers = require("test_helpers")

local assert_eq       = test_helpers.assert_eq
local assert_contains = test_helpers.assert_contains
local with_stubs      = test_helpers.with_stubs
local capture_print   = test_helpers.capture_print

-- ---------------------------------------------------------------------------
-- regression: print_model_list must fall back to model_info.captured_at for
-- sort order when a model has no history entry.
-- ---------------------------------------------------------------------------
local function test_print_model_list_sorts_by_model_info_fallback()
    with_stubs({
        format     = test_helpers.REMOVE,   -- force re-require against our stubs
        util = {
            expand_path = function(p) return p end,
            path_attr   = function(_) return { size = 123456789 } end,
            format_size = function(_) return "117.7MB" end,
            format_time = function(ts) return "T" .. tostring(ts) end,
        },
        history = {
            load_history = function()
                return { { name = "ModelB-Q6_K", last_run = 10 } }
            end,
        },
        model_info = {
            load_model_info = function(name)
                if name == "ModelA-Q6_K" then
                    return { captured_at = 20 }
                end
                return nil
            end,
        },
    }, function()
        local format = require("format")
        local config = { models_dir = "/models" }

        -- ModelA has no history but captured_at=20; ModelB has last_run=10.
        -- ModelA must sort first.
        local printed = capture_print(function()
            format.print_model_list({ "ModelA-Q6_K", "ModelB-Q6_K" }, "/models", config)
        end)

        if #printed < 2 then
            error("expected at least 2 printed lines, got " .. tostring(#printed))
        end

        assert_contains(printed[1], "ModelA-Q6_K", "ModelA should sort first (captured_at fallback)")
        assert_contains(printed[2], "ModelB-Q6_K", "ModelB should sort second")
        assert_contains(printed[1], "T20",         "ModelA last_run_str should use captured_at")
        assert_contains(printed[2], "T10",         "ModelB last_run_str should use history last_run")
    end)
end

-- ---------------------------------------------------------------------------
-- main
-- ---------------------------------------------------------------------------
return {
    run = function()
        -- ── calculate_column_widths ─────────────────────────────
        local data = {
            { name = "short",              size_str = "1.2GB", quant = "Q4_K_M", last_run_str = "never" },
            { name = "a-much-longer-name", size_str = "400MB", quant = "Q8_0",   last_run_str = "2 hours ago" },
            { name = "mid",                size_str = "12GB",  quant = "Q5_K_S", last_run_str = "just now" },
        }

        local max_name, max_size, max_quant = format.calculate_column_widths(data)

        assert_eq(max_name,  #"a-much-longer-name",  "max_name")
        assert_eq(max_size,  #"1.2GB",               "max_size")
        assert_eq(max_quant, #"Q4_K_M",              "max_quant")

        -- ── format_model_row ────────────────────────────────────
        local row = format.format_model_row(data[1], max_name, max_size, max_quant)

        local name_pad  = string.rep(" ", max_name  - #data[1].name)
        local size_pad  = string.rep(" ", max_size  - #data[1].size_str)
        local quant_pad = string.rep(" ", max_quant - #data[1].quant)
        local expected  = data[1].name .. name_pad .. "  " ..
                          data[1].size_str .. size_pad .. "  " ..
                          data[1].quant .. quant_pad .. "  " ..
                          data[1].last_run_str
        assert_eq(row, expected, "format_model_row padding for 'short'")

        -- longest name → zero name-padding
        local row2 = format.format_model_row(data[2], max_name, max_size, max_quant)
        assert_eq(row2:sub(1, max_name), data[2].name, "longest name fills column exactly")

        -- ── single-element list ─────────────────────────────────
        local single = { { name = "x", size_str = "1B", quant = "Q4", last_run_str = "now" } }
        local mn, ms, mq = format.calculate_column_widths(single)
        assert_eq(mn, 1,  "single: max_name")
        assert_eq(ms, 2,  "single: max_size")
        assert_eq(mq, 2,  "single: max_quant")
        local row3 = format.format_model_row(single[1], mn, ms, mq)
        assert_eq(row3, "x  1B  Q4  now", "single-element row is tight")

        -- ── empty list ──────────────────────────────────────────
        local mn0, ms0, mq0 = format.calculate_column_widths({})
        assert_eq(mn0, 0, "empty: max_name")
        assert_eq(ms0, 0, "empty: max_size")
        assert_eq(mq0, 0, "empty: max_quant")

        -- ── regression ──────────────────────────────────────────
        test_print_model_list_sorts_by_model_info_fallback()
    end
}
