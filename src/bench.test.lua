-- bench.test.lua — unit tests for src/bench.lua

local bench = require("bench")
local T = require("test_helpers")

return {
    run = function()
        -- ── Test JSON parsing from llama-bench output ──────────────────
        local sample_json = [[
[
  {
    "model": "test-model.gguf",
    "n_prompt": 512,
    "n_gen": 0,
    "n_threads": 12,
    "avg_ts": 216.49,
    "samples_ts": [ 214.5, 218.4 ]
  },
  {
    "model": "test-model.gguf",
    "n_prompt": 0,
    "n_gen": 128,
    "n_threads": 12,
    "avg_ts": 18.46,
    "samples_ts": [ 18.1, 18.8 ]
  }
]
]]
        
        local parsed, err = bench._parse_json_for_test(sample_json)
        
        T.assert_eq(err, nil, "no error parsing valid JSON")
        T.assert_eq(type(parsed), "table", "parsed result is a table")
        T.assert_eq(#parsed.pp_values, 1, "found 1 pp value (n_prompt>0, n_gen=0)")
        T.assert_eq(#parsed.tg_values, 1, "found 1 tg value (n_gen>0)")
        T.assert_eq(parsed.pp_values[1], 216.49, "pp value correct")
        T.assert_eq(parsed.tg_values[1], 18.46, "tg value correct")
        T.assert_eq(parsed.reported_threads, 12, "threads extracted")
        
        -- ── Test JSON with only pp results ─────────────────────────────
        local pp_only_json = [[
[
  {
    "n_prompt": 512,
    "n_gen": 0,
    "avg_ts": 123.45
  }
]
]]
        
        local parsed2, err2 = bench._parse_json_for_test(pp_only_json)
        
        T.assert_eq(err2, nil, "no error with pp-only JSON")
        T.assert_eq(#parsed2.pp_values, 1, "found 1 pp value")
        T.assert_eq(#parsed2.tg_values, 0, "found 0 tg values")
        T.assert_eq(parsed2.pp_values[1], 123.45, "pp value correct")
        
        -- ── Test JSON with only tg results ─────────────────────────────
        local tg_only_json = [[
[
  {
    "n_prompt": 0,
    "n_gen": 128,
    "avg_ts": 67.89
  }
]
]]
        
        local parsed3, err3 = bench._parse_json_for_test(tg_only_json)
        
        T.assert_eq(err3, nil, "no error with tg-only JSON")
        T.assert_eq(#parsed3.pp_values, 0, "found 0 pp values")
        T.assert_eq(#parsed3.tg_values, 1, "found 1 tg value")
        T.assert_eq(parsed3.tg_values[1], 67.89, "tg value correct")
        
        -- ── Test malformed JSON ─────────────────────────────────────────
        local bad_json = "{ this is not valid json"
        
        local parsed4, err4 = bench._parse_json_for_test(bad_json)
        
        T.assert_eq(parsed4, nil, "malformed JSON returns nil")
        T.assert_eq(type(err4), "string", "error message is string")
        T.assert_contains(err4, "parse", "error mentions parsing")
        
        -- ── Test empty array ────────────────────────────────────────────
        local empty_array_json = "[]"
        
        local parsed5, err5 = bench._parse_json_for_test(empty_array_json)
        
        T.assert_eq(err5, nil, "empty array is valid")
        T.assert_eq(#parsed5.pp_values, 0, "no pp values in empty array")
        T.assert_eq(#parsed5.tg_values, 0, "no tg values in empty array")
        
        -- ── Test JSON with both pp and tg ───────────────────────────────
        local mixed_json = [[
[
  {
    "n_prompt": 1024,
    "n_gen": 0,
    "avg_ts": 100.0
  },
  {
    "n_prompt": 0,
    "n_gen": 256,
    "avg_ts": 50.0
  }
]
]]
        
        local parsed6, err6 = bench._parse_json_for_test(mixed_json)
        
        T.assert_eq(err6, nil, "no error with mixed JSON")
        T.assert_eq(#parsed6.pp_values, 1, "found 1 pp value")
        T.assert_eq(#parsed6.tg_values, 1, "found 1 tg value")
        T.assert_eq(parsed6.pp_values[1], 100.0, "pp value correct")
        T.assert_eq(parsed6.tg_values[1], 50.0, "tg value correct")
        
        -- ── Test markdown table parsing (fallback) ─────────────────────
        local markdown_output = [[
| model                          |       size |     params | backend    | threads | n_batch |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | ------: | ------: | --------------: | -------------------: |
| llama 13B Q6_K                 |  18.01 GiB |    23.57 B | Metal,BLAS |      12 |     512 |          pp2048 |        216.49 ± 0.93 |
| llama 13B Q6_K                 |  18.01 GiB |    23.57 B | Metal,BLAS |      12 |     512 |           tg256 |         18.46 ± 0.35 |
]]
        
        local parsed_md = bench._parse_markdown_for_test(markdown_output)
        
        T.assert_eq(type(parsed_md), "table", "markdown parsed to table")
        T.assert_eq(#parsed_md.pp_values, 1, "found 1 pp value from markdown")
        T.assert_eq(#parsed_md.tg_values, 1, "found 1 tg value from markdown")
        T.assert_eq(parsed_md.pp_values[1], 216.49, "pp value from markdown correct")
        T.assert_eq(parsed_md.tg_values[1], 18.46, "tg value from markdown correct")
    end
}
