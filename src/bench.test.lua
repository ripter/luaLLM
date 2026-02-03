-- bench.test.lua — unit tests for src/bench.lua

local bench = require("bench")
local T = require("test_helpers")

return {
    run = function()
        -- ── Test new llama-bench table format ──────────────────────────
        local sample_output = [[
| model                          |       size |     params | backend    | threads | n_batch |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | ------: | ------: | --------------: | -------------------: |
| llama 13B Q6_K                 |  18.01 GiB |    23.57 B | Metal,BLAS |      12 |     512 |          pp2048 |        216.49 ± 0.93 |
| llama 13B Q6_K                 |  18.01 GiB |    23.57 B | Metal,BLAS |      12 |     512 |           tg256 |         18.46 ± 0.35 |
]]

        local metrics = bench._parse_metrics_for_test(sample_output)
        
        T.assert_eq(metrics.pp_tps, 216.49, "pp_tps should be 216.49")
        T.assert_eq(metrics.tg_tps, 18.46,  "tg_tps should be 18.46")
        
        -- ── Test with extra spacing/alignment variations ───────────────
        local sample_with_spacing = [[
| model     |  test   |     t/s        |
| foo       |  pp512  |  123.45 ± 0.1  |
| foo       |  tg128  |  67.89 ± 0.2   |
]]
        
        local metrics2 = bench._parse_metrics_for_test(sample_with_spacing)
        
        T.assert_eq(metrics2.pp_tps, 123.45, "pp_tps with varied spacing")
        T.assert_eq(metrics2.tg_tps, 67.89,  "tg_tps with varied spacing")
        
        -- ── Test older format (ensure backward compatibility) ──────────
        local old_format = [[
| pp 512 | tg 128 | pl 512 | 1 | pp 1234.56 ± 0.00 | tg 567.89 ± 0.00 |
]]
        
        local metrics3 = bench._parse_metrics_for_test(old_format)
        
        T.assert_eq(metrics3.pp_tps, 1234.56, "old format pp_tps")
        T.assert_eq(metrics3.tg_tps, 567.89,  "old format tg_tps")
        
        -- ── Test with only pp or only tg ───────────────────────────────
        local partial_output = [[
| model | test | t/s |
| foo   | pp1024 | 99.99 ± 0.01 |
]]
        
        local metrics4 = bench._parse_metrics_for_test(partial_output)
        
        T.assert_eq(metrics4.pp_tps, 99.99, "partial: pp_tps only")
        T.assert_eq(metrics4.tg_tps, nil,   "partial: tg_tps should be nil")
        
        -- ── Test empty/malformed input ──────────────────────────────────
        local empty_metrics = bench._parse_metrics_for_test("")
        T.assert_eq(empty_metrics.pp_tps, nil, "empty input: pp_tps is nil")
        T.assert_eq(empty_metrics.tg_tps, nil, "empty input: tg_tps is nil")
        
        local no_table = bench._parse_metrics_for_test("just some random text")
        T.assert_eq(no_table.pp_tps, nil, "no table: pp_tps is nil")
        T.assert_eq(no_table.tg_tps, nil, "no table: tg_tps is nil")
    end
}
