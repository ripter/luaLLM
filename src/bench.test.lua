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
        
        -- ── Test JSON with leading junk (no JSON chars in junk) ──────
        -- Note: The parser naively finds first { or [, so junk shouldn't contain these
        local junk_before_json = [[
llama-bench: loading model
some log output here
more logs
[
  {
    "n_prompt": 512,
    "n_gen": 0,
    "avg_ts": 99.9
  }
]
]]
        
        local parsed7, err7 = bench._parse_json_for_test(junk_before_json)
        
        T.assert_eq(err7, nil, "leading junk handled")
        T.assert_eq(#parsed7.pp_values, 1, "found pp value despite junk")
        T.assert_eq(parsed7.pp_values[1], 99.9, "pp value correct")
        
        -- ── Test JSON object wrapper with build info ───────────────────
        local wrapped_json = [[
{
  "build_commit": "abc123",
  "build_number": 9999,
  "results": [
    {
      "n_prompt": 512,
      "n_gen": 0,
      "avg_ts": 200.0
    }
  ]
}
]]
        
        local parsed8, err8 = bench._parse_json_for_test(wrapped_json)
        
        T.assert_eq(err8, nil, "object wrapper handled")
        T.assert_eq(#parsed8.pp_values, 1, "found pp value")
        T.assert_eq(parsed8.build_info.commit, "abc123", "build commit extracted")
        T.assert_eq(parsed8.build_info.number, 9999, "build number extracted")
        
        -- ── Test that parser finds first valid JSON structure ──────────
        local starts_with_array = "[{ \"n_prompt\": 1, \"n_gen\": 0, \"avg_ts\": 50 }]"
        
        local parsed9, err9 = bench._parse_json_for_test(starts_with_array)
        
        T.assert_eq(err9, nil, "parses array starting with [")
        T.assert_eq(#parsed9.pp_values, 1, "found pp value from array")
        T.assert_eq(parsed9.pp_values[1], 50, "pp value correct")
        
        -- ── Test object with no results and no array ───────────────────
        local no_results_obj = [[
{
  "build_commit": "test",
  "something_else": 123
}
]]
        
        local parsed10, err10 = bench._parse_json_for_test(no_results_obj)
        
        T.assert_eq(parsed10, nil, "object without results returns nil")
        T.assert_eq(type(err10), "string", "error is string")
        T.assert_contains(err10, "results", "error mentions results")
        T.assert_contains(err10, "array", "error mentions array")
        
        -- ── Test empty object ───────────────────────────────────────────
        local empty_obj = "{}"
        
        local parsed11, err11 = bench._parse_json_for_test(empty_obj)
        
        T.assert_eq(parsed11, nil, "empty object returns nil")
        T.assert_eq(type(err11), "string", "error is string")
        
        -- ── Test aggregate_samples ──────────────────────────────────────
        local pp_vals = {100.0, 105.0, 95.0, 110.0, 98.0}
        local tg_vals = {50.0, 52.0, 48.0, 51.0, 49.0}
        
        local stats = bench._aggregate_samples_for_test(pp_vals, tg_vals)
        
        T.assert_eq(type(stats), "table", "stats is a table")
        T.assert_eq(type(stats.pp), "table", "pp stats exist")
        T.assert_eq(type(stats.tg), "table", "tg stats exist")
        
        -- Check PP stats
        T.assert_eq(stats.pp.avg, 101.6, "pp avg correct")
        T.assert_eq(stats.pp.min, 95.0, "pp min correct")
        T.assert_eq(stats.pp.max, 110.0, "pp max correct")
        
        -- Check TG stats
        T.assert_eq(stats.tg.avg, 50.0, "tg avg correct")
        T.assert_eq(stats.tg.min, 48.0, "tg min correct")
        T.assert_eq(stats.tg.max, 52.0, "tg max correct")
        
        -- Test with empty arrays
        local stats_empty = bench._aggregate_samples_for_test({}, {})
        T.assert_eq(type(stats_empty), "table", "empty arrays return table")
        T.assert_eq(stats_empty.pp, nil, "empty pp returns nil")
        T.assert_eq(stats_empty.tg, nil, "empty tg returns nil")
        
        -- Test with single value
        local stats_single = bench._aggregate_samples_for_test({100}, {50})
        T.assert_eq(stats_single.pp.avg, 100, "single pp avg = value")
        T.assert_eq(stats_single.pp.min, 100, "single pp min = value")
        T.assert_eq(stats_single.pp.max, 100, "single pp max = value")
        
        -- ── Test fingerprinting ──────────────────────────────────────────
        local fp1, details1 = bench._create_run_fingerprint_for_test(
            "/usr/bin/llama-bench",
            {"llama-bench", "-m", "model.gguf", "-t", "8"},
            8,
            1,
            {commit = "abc123", number = 1234}
        )
        
        T.assert_eq(type(fp1), "string", "fingerprint is string")
        T.assert_contains(fp1, "fnv1a32:", "fingerprint has prefix")
        T.assert_eq(#fp1, 16, "fingerprint is fnv1a32:XXXXXXXX (16 chars)")
        
        -- Same config should produce same fingerprint
        local fp2, details2 = bench._create_run_fingerprint_for_test(
            "/usr/bin/llama-bench",
            {"llama-bench", "-m", "model.gguf", "-t", "8"},
            8,
            1,
            {commit = "abc123", number = 1234}
        )
        T.assert_eq(fp1, fp2, "same config produces same fingerprint")
        
        -- Different threads should produce different fingerprint
        local fp3 = bench._create_run_fingerprint_for_test(
            "/usr/bin/llama-bench",
            {"llama-bench", "-m", "model.gguf", "-t", "16"},
            16,
            1,
            {commit = "abc123", number = 1234}
        )
        if fp1 == fp3 then
            error("different threads should produce different fingerprint, but got same: " .. fp1, 2)
        end
        
        -- Different build should produce different fingerprint
        local fp4 = bench._create_run_fingerprint_for_test(
            "/usr/bin/llama-bench",
            {"llama-bench", "-m", "model.gguf", "-t", "8"},
            8,
            1,
            {commit = "def456", number = 1234}
        )
        if fp1 == fp4 then
            error("different build should produce different fingerprint, but got same: " .. fp1, 2)
        end
        
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
        
        -- ── Test aggregate_samples function ────────────────────────────
        local test_pp = {100, 110, 105, 95, 108}
        local test_tg = {20, 22, 21, 19, 23}
        
        local stats = bench._aggregate_samples_for_test(test_pp, test_tg)
        
        T.assert_eq(type(stats), "table", "aggregate_samples returns table")
        T.assert_eq(type(stats.pp), "table", "pp stats present")
        T.assert_eq(type(stats.tg), "table", "tg stats present")
        
        -- PP: sum=518, avg=103.6, min=95, max=110
        T.assert_eq(stats.pp.avg, 103.6, "pp avg correct")
        T.assert_eq(stats.pp.min, 95, "pp min correct")
        T.assert_eq(stats.pp.max, 110, "pp max correct")
        
        -- TG: sum=105, avg=21, min=19, max=23
        T.assert_eq(stats.tg.avg, 21, "tg avg correct")
        T.assert_eq(stats.tg.min, 19, "tg min correct")
        T.assert_eq(stats.tg.max, 23, "tg max correct")
        
        -- Test with empty arrays
        local empty_stats = bench._aggregate_samples_for_test({}, {})
        T.assert_eq(type(empty_stats), "table", "empty samples returns table")
        T.assert_eq(empty_stats.pp, nil, "empty pp is nil")
        T.assert_eq(empty_stats.tg, nil, "empty tg is nil")
        
        -- Test with only pp values
        local pp_only_stats = bench._aggregate_samples_for_test({50, 60}, {})
        T.assert_eq(type(pp_only_stats.pp), "table", "pp-only has pp stats")
        T.assert_eq(pp_only_stats.tg, nil, "pp-only has no tg stats")
        
        -- ── Test FNV-1a hash is deterministic ──────────────────────────
        local hash1 = bench._fnv1a_32_for_test("test string")
        local hash2 = bench._fnv1a_32_for_test("test string")
        local hash3 = bench._fnv1a_32_for_test("different string")
        
        T.assert_eq(type(hash1), "number", "hash is a number")
        T.assert_eq(hash1, hash2, "same input produces same hash")
        if hash1 == hash3 then
            error("different input should produce different hash", 2)
        end
        
        -- ── Test fingerprint computation ───────────────────────────────
        local fp1, details1 = bench._create_run_fingerprint_for_test(
            "/path/bench", {"bench", "-m", "model"}, 8, 1, {commit="abc123"}
        )
        
        T.assert_eq(type(fp1), "string", "fingerprint is string")
        T.assert_contains(fp1, "fnv1a32:", "fingerprint has correct prefix")
        T.assert_eq(type(details1), "table", "details is table")
        T.assert_eq(details1.threads_requested, 8, "details has threads")
        T.assert_eq(details1.warmup, 1, "details has warmup")
        
        -- Different config should produce different fingerprint
        local fp2, _ = bench._create_run_fingerprint_for_test(
            "/path/bench", {"bench", "-m", "model"}, 16, 1, {commit="abc123"}
        )
        
        T.assert_eq(fp1 == fp2, false, "different threads produces different fingerprint")
        
        -- Same config should produce same fingerprint
        local fp3, _ = bench._create_run_fingerprint_for_test(
            "/path/bench", {"bench", "-m", "model"}, 8, 1, {commit="abc123"}
        )
        
        T.assert_eq(fp1, fp3, "same config produces same fingerprint")
        
        -- ── Test config fingerprint (excludes model info) ──────────────
        local cfg_fp1 = bench._create_config_fingerprint_for_test(
            "/usr/bin/llama-bench", 8, 1, 5, {commit = "abc123", number = 1234}
        )
        
        T.assert_eq(type(cfg_fp1), "string", "config fingerprint is string")
        T.assert_contains(cfg_fp1, "fnv1a32:", "config fingerprint has correct prefix")
        
        -- Same config should produce same fingerprint
        local cfg_fp2 = bench._create_config_fingerprint_for_test(
            "/usr/bin/llama-bench", 8, 1, 5, {commit = "abc123", number = 1234}
        )
        T.assert_eq(cfg_fp1, cfg_fp2, "same config produces same config fingerprint")
        
        -- Different threads should change it
        local cfg_fp3 = bench._create_config_fingerprint_for_test(
            "/usr/bin/llama-bench", 16, 1, 5, {commit = "abc123", number = 1234}
        )
        if cfg_fp1 == cfg_fp3 then
            error("different threads should produce different config fingerprint", 2)
        end
        
        -- Different n should change it
        local cfg_fp4 = bench._create_config_fingerprint_for_test(
            "/usr/bin/llama-bench", 8, 1, 10, {commit = "abc123", number = 1234}
        )
        if cfg_fp1 == cfg_fp4 then
            error("different n should produce different config fingerprint", 2)
        end
        
        -- ── Test preamble extraction ───────────────────────────────────
        local sample_output = [[
llama-bench: loading model
Metal: Apple M1 Max
offloaded 33/33 layers to GPU
[
  {"n_prompt": 512, "n_gen": 0, "avg_ts": 100.0}
]
]]
        
        local preamble, json_str = bench._extract_preamble_and_json_for_test(sample_output)
        
        T.assert_contains(preamble, "Metal:", "preamble contains Metal")
        T.assert_contains(preamble, "offloaded", "preamble contains offload info")
        T.assert_contains(json_str, '"n_prompt"', "JSON string contains expected content")
        
        -- ── Test runtime signal extraction ─────────────────────────────
        local signals = bench._extract_runtime_signals_for_test(preamble)
        
        T.assert_eq(signals.backend_hint, "metal", "detected Metal backend")
        T.assert_eq(type(signals.gpu_name), "string", "extracted GPU name")
        T.assert_contains(signals.gpu_name, "M1", "GPU name contains M1")
        T.assert_eq(type(signals.offload), "table", "offload info is table")
        T.assert_eq(signals.offload.offloaded, 33, "offloaded count correct")
        T.assert_eq(signals.offload.total, 33, "total count correct")
        
        -- Test CUDA detection
        local cuda_preamble = "CUDA: NVIDIA RTX 4090\noffloaded 40/40 layers"
        local cuda_signals = bench._extract_runtime_signals_for_test(cuda_preamble)
        T.assert_eq(cuda_signals.backend_hint, "cuda", "detected CUDA backend")
        
        -- Test CPU detection
        local cpu_preamble = "CPU: running on BLAS"
        local cpu_signals = bench._extract_runtime_signals_for_test(cpu_preamble)
        T.assert_eq(cpu_signals.backend_hint, "cpu", "detected CPU backend")
        
        -- ── Test ID extraction ─────────────────────────────────────────
        local results_array = {
            {n_prompt = 512, n_gen = 0, avg_ts = 100},
            {n_prompt = 1024, n_gen = 0, avg_ts = 200},
            {n_prompt = 0, n_gen = 128, avg_ts = 50},
            {n_prompt = 0, n_gen = 256, avg_ts = 60}
        }
        
        local test_ids = bench._extract_test_ids_for_test(results_array)
        
        T.assert_eq(type(test_ids), "table", "test_ids is table")
        T.assert_eq(#test_ids.pp, 2, "found 2 PP tests")
        T.assert_eq(#test_ids.tg, 2, "found 2 TG tests")
        T.assert_eq(test_ids.pp[1], "pp512", "first PP test is pp512")
        T.assert_eq(test_ids.pp[2], "pp1024", "second PP test is pp1024")
        T.assert_eq(test_ids.tg[1], "tg128", "first TG test is tg128")
        T.assert_eq(test_ids.tg[2], "tg256", "second TG test is tg256")
        
        -- Test with explicit test names
        local named_results = {
            {test = "custom_pp", n_prompt = 512, n_gen = 0, avg_ts = 100},
            {test = "custom_tg", n_prompt = 0, n_gen = 128, avg_ts = 50}
        }
        
        local named_test_ids = bench._extract_test_ids_for_test(named_results)
        T.assert_eq(named_test_ids.pp[1], "custom_pp", "uses explicit test name for PP")
        T.assert_eq(named_test_ids.tg[1], "custom_tg", "uses explicit test name for TG")
        
        -- ── Test format_speed_ratio ────────────────────────────────────
        T.assert_eq(bench._format_speed_ratio_for_test(100, 50), "2.00×", "2x faster")
        T.assert_eq(bench._format_speed_ratio_for_test(50, 100), "0.50×", "0.5x (slower)")
        T.assert_eq(bench._format_speed_ratio_for_test(100, 99), "≈same speed", "within 2% is same")
        T.assert_eq(bench._format_speed_ratio_for_test(100, 101), "≈same speed", "within 2% is same (other direction)")
        T.assert_eq(bench._format_speed_ratio_for_test(543.21, 100.5), "5.41×", "5.41x faster")
        
        -- ── Test compute_winner ─────────────────────────────────────────
        local stats_a = {pp = {avg = 100}, tg = {avg = 50}}
        local stats_b = {pp = {avg = 50}, tg = {avg = 25}}
        local winner = bench._compute_winner_for_test(stats_a, stats_b, "ModelA", "ModelB")
        
        T.assert_eq(winner.pp_winner, "ModelA", "ModelA wins PP")
        T.assert_eq(winner.pp_formatted, "2.00×", "PP ratio correct")
        T.assert_eq(winner.tg_winner, "ModelA", "ModelA wins TG")
        T.assert_eq(winner.tg_formatted, "2.00×", "TG ratio correct")
        T.assert_eq(winner.overall_winner, "ModelA", "ModelA overall winner")
        T.assert_eq(winner.is_mixed, false, "not mixed")
        
        -- Test mixed result
        local stats_a_mixed = {pp = {avg = 100}, tg = {avg = 25}}
        local stats_b_mixed = {pp = {avg = 50}, tg = {avg = 50}}
        local winner_mixed = bench._compute_winner_for_test(stats_a_mixed, stats_b_mixed, "ModelA", "ModelB")
        
        T.assert_eq(winner_mixed.is_mixed, true, "mixed result detected")
        T.assert_eq(winner_mixed.pp_winner, "ModelA", "ModelA wins PP in mixed")
        T.assert_eq(winner_mixed.tg_winner, "ModelB", "ModelB wins TG in mixed")
        
        -- ── Test format_result_line ─────────────────────────────────────
        local result_line = bench._format_result_line_for_test(winner, true, {})
        T.assert_contains(result_line, "ModelA is faster overall", "contains winner")
        T.assert_contains(result_line, "×", "contains × symbol")
        T.assert_contains(result_line, "Prompt processing (PP)", "spells out PP")
        T.assert_contains(result_line, "Token generation (TG)", "spells out TG")
        T.assert_contains(result_line, "(Same benchmark config.)", "same config qualifier")
        
        -- Test with config differences
        local result_line_diff = bench._format_result_line_for_test(winner, false, {"threads (8 vs 16)", "backend (metal vs cpu)"})
        T.assert_contains(result_line_diff, "Configs differ", "contains config diff warning")
        T.assert_contains(result_line_diff, "threads", "mentions threads diff")
        T.assert_contains(result_line_diff, "treat with caution", "has caution warning")
        
        -- Test mixed result line
        local result_line_mixed = bench._format_result_line_for_test(winner_mixed, true, {})
        T.assert_contains(result_line_mixed, "Mixed results", "identifies mixed results")
        T.assert_contains(result_line_mixed, "but", "contains 'but' for mixed")
        
        -- ── Test extract_env_summary ────────────────────────────────────
        local mock_log = {
            runtime_info = {
                signals = {
                    backend_hint = "metal",
                    gpu_name = "Apple M3 Max"
                },
                build_info = {
                    commit = "abc1234",
                    number = 5678
                }
            },
            tests = {
                pp = {"pp512", "pp1024"},
                tg = {"tg128"}
            },
            raw = {
                runs = {{
                    results_array = {{
                        n_batch = 512,
                        n_ubatch = 128,
                        n_gpu_layers = 33
                    }}
                }}
            }
        }
        
        local env = bench._extract_env_summary_for_test(mock_log)
        T.assert_eq(env.backend, "metal", "backend extracted")
        T.assert_eq(env.gpu, "Apple M3 Max", "GPU extracted")
        T.assert_contains(env.build, "abc1234", "build contains commit")
        T.assert_contains(env.build, "5678", "build contains number")
        T.assert_contains(env.tests, "pp512", "tests contain pp512")
        T.assert_contains(env.knobs, "n_batch=512", "knobs contain n_batch")
        T.assert_contains(env.knobs, "n_gpu_layers=33", "knobs contain n_gpu_layers")
    end
}
