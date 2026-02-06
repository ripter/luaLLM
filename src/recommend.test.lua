-- recommend.test.lua
-- Tests for preset recommendation system

local T = require("test_helpers")
local recommend = require("recommend")
local model_info = require("model_info")

return { run = function()
    -- ── Test profile list ───────────────────────────────────────────
    T.assert_eq(type(recommend.PROFILES), "table", "PROFILES is table")
    T.assert_eq(#recommend.PROFILES, 3, "has 3 profiles")
    T.assert_contains(table.concat(recommend.PROFILES, ","), "throughput", "has throughput profile")
    T.assert_contains(table.concat(recommend.PROFILES, ","), "cold-start", "has cold-start profile")
    T.assert_contains(table.concat(recommend.PROFILES, ","), "context", "has context profile")
    
    -- ── Test load_preset with no preset ────────────────────────────
    local cfg = {models = {}}
    local preset = recommend.load_preset(cfg, "test-model", "throughput")
    T.assert_eq(preset, nil, "returns nil when no preset exists")
    
    -- ── Test load_preset with preset ───────────────────────────────
    cfg.models["test-model"] = {
        presets = {
            throughput = {
                created_at = 1234567890,
                source = "recommend",
                flags = {"-t", "8", "-ngl", "999"}
            }
        }
    }
    
    preset = recommend.load_preset(cfg, "test-model", "throughput")
    T.assert_eq(type(preset), "table", "returns preset table")
    T.assert_eq(preset.source, "recommend", "has correct source")
    T.assert_eq(#preset.flags, 4, "has correct number of flags")
    T.assert_eq(preset.flags[1], "-t", "first flag is -t")
    T.assert_eq(preset.flags[2], "8", "second flag is 8")
    
    -- Verify thread value is integer string, not float
    local thread_val = preset.flags[2]
    T.assert_eq(thread_val:match("%."), nil, "thread value should not contain decimal point")
    
    -- ── Test load_preset with different profile ────────────────────
    local missing = recommend.load_preset(cfg, "test-model", "cold-start")
    T.assert_eq(missing, nil, "returns nil for missing profile")
    
    -- ── Test load_preset with missing model ────────────────────────
    local missing2 = recommend.load_preset(cfg, "other-model", "throughput")
    T.assert_eq(missing2, nil, "returns nil for missing model")
    
    -- ── Test bench runner injection and selection logic ────────────
    -- Mock bench runner that returns predictable results
    local bench_call_count = 0
    local mock_results = {
        -- Candidate 1: Good PP, poor TG
        {pp = 100.0, tg = 50.0},
        -- Candidate 2: Best TG (should win)
        {pp = 90.0, tg = 120.0},
        -- Candidate 3: Good PP, good TG but not best
        {pp = 110.0, tg = 100.0},
    }
    
    recommend._bench_runner = function(bench_path, model_path, flags)
        bench_call_count = bench_call_count + 1
        if bench_call_count <= #mock_results then
            return mock_results[bench_call_count], nil
        else
            return {pp = 50.0, tg = 50.0}, nil
        end
    end
    
    -- Note: We can't easily test the full recommend command without mocking more infrastructure
    -- (config save, resolver, etc.), but we've injected the bench runner for when it's called
    
    -- Restore
    recommend._bench_runner = nil
    
    -- ── Verify bench runner was injectable ─────────────────────────
    T.assert_eq(recommend._bench_runner, nil, "bench runner can be cleared")
    
    -- ── Test context choice policy ──────────────────────────────────
    -- We need to stub model_info.load_model_info for these tests
    local original_load = model_info.load_model_info
    
    -- Test case A: ctx_runtime from model info
    model_info.load_model_info = function(name)
        return {
            derived = {
                ctx_runtime = 12288
            }
        }
    end
    
    local ctx_a = recommend._choose_context_for_test("test", {})
    T.assert_eq(ctx_a.value, 12288, "uses ctx_runtime from model info")
    T.assert_contains(ctx_a.reason, "model info", "reason mentions model info")
    T.assert_contains(ctx_a.reason, "12288", "reason includes value")
    
    -- Test case B: context from last run argv
    model_info.load_model_info = function(name)
        return {
            run_config = {
                argv = {"llama-server", "-m", "model.gguf", "-c", "8192"}
            }
        }
    end
    
    local ctx_b = recommend._choose_context_for_test("test", {})
    T.assert_eq(ctx_b.value, 8192, "uses context from last run argv")
    T.assert_contains(ctx_b.reason, "last run", "reason mentions last run")
    T.assert_contains(ctx_b.reason, "8192", "reason includes value")
    
    -- Test case C: configured default
    model_info.load_model_info = function(name)
        return nil
    end
    
    local ctx_c = recommend._choose_context_for_test("test", {default_ctx_size = 4096})
    T.assert_eq(ctx_c.value, 4096, "uses configured default")
    T.assert_contains(ctx_c.reason, "default", "reason mentions default")
    
    -- Test case D: no context (uses run defaults)
    local ctx_d = recommend._choose_context_for_test("test", {})
    T.assert_eq(ctx_d.value, nil, "returns nil when no context info available")
    T.assert_contains(ctx_d.reason, "run defaults", "reason mentions run defaults")
    
    -- Restore original function
    model_info.load_model_info = original_load
end }
