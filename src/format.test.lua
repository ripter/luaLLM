-- format.test.lua — unit tests for the pure column-formatting helpers in format.lua
-- Does NOT touch the filesystem or history; only exercises
-- calculate_column_widths() and format_model_row().

local format = require("format")

local function assert_eq(got, want, msg)
    if got ~= want then
        error(string.format("%s\n  got:  %q\n  want: %q", msg or "assertion failed", tostring(got), tostring(want)), 2)
    end
end

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
        assert_eq(max_size,  #"1.2GB",               "max_size — all size strings are 4-5 chars; 1.2GB is 5")
        assert_eq(max_quant, #"Q4_K_M",              "max_quant")

        -- ── format_model_row ────────────────────────────────────
        -- Build a row for "short" and verify the padding lands correctly.
        local row = format.format_model_row(data[1], max_name, max_size, max_quant)

        -- Expected layout:
        --   "short" + (max_name - 5) spaces + "  " + "1.2GB" + (max_size - 5) spaces + "  " + "Q4_K_M" + (max_quant - 6) spaces + "  " + "never"
        local name_pad  = string.rep(" ", max_name  - #data[1].name)
        local size_pad  = string.rep(" ", max_size  - #data[1].size_str)
        local quant_pad = string.rep(" ", max_quant - #data[1].quant)
        local expected  = data[1].name .. name_pad .. "  " ..
                          data[1].size_str .. size_pad .. "  " ..
                          data[1].quant .. quant_pad .. "  " ..
                          data[1].last_run_str
        assert_eq(row, expected, "format_model_row padding for 'short'")

        -- The longest-name row should have zero name-padding.
        local row2 = format.format_model_row(data[2], max_name, max_size, max_quant)
        -- name portion is exactly max_name chars (no extra spaces before the first "  ")
        assert_eq(row2:sub(1, max_name), data[2].name, "longest name fills column exactly")

        -- ── single-element list ─────────────────────────────────
        local single = { { name = "x", size_str = "1B", quant = "Q4", last_run_str = "now" } }
        local mn, ms, mq = format.calculate_column_widths(single)
        assert_eq(mn, 1,  "single: max_name")
        assert_eq(ms, 2,  "single: max_size")
        assert_eq(mq, 2,  "single: max_quant")
        local row3 = format.format_model_row(single[1], mn, ms, mq)
        assert_eq(row3, "x  1B  Q4  now", "single-element row is tight, no extra padding")

        -- ── empty list ──────────────────────────────────────────
        local mn0, ms0, mq0 = format.calculate_column_widths({})
        assert_eq(mn0, 0, "empty: max_name")
        assert_eq(ms0, 0, "empty: max_size")
        assert_eq(mq0, 0, "empty: max_quant")
    end
}
