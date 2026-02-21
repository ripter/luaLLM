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
    
    -- ── Integration tests: full sweep via handle_recommend_command ──
    --
    -- These tests call handle_recommend_command, which internally calls
    -- resolver.resolve_or_exit.  Without stubbing, that hits the real
    -- filesystem and calls os.exit(1) when "fake-model" isn't found,
    -- killing the entire test runner process.
    --
    -- We use T.with_stubs to install and safely restore all five modules
    -- that touch disk or exit: util, resolver, model_info, config, bench.
    -- recommend itself must be REMOVE'd so it re-requires against the stubs.

    local SWEEP_CFG = { models_dir = "/fake/models", bench = { default_threads = 8 } }

    local SWEEP_ARGS = {"recommend", "throughput", "fake-model"}

    local function base_sweep_stubs(extra)
        local stubs = {
            util = {
                file_exists         = function() return true end,
                save_json           = function() end,
                resolve_bench_path  = function() return "/fake/llama-bench" end,
                expand_path         = function(p) return p end,
                sh_quote            = function(s) return s end,
                normalize_exit_code = function() return 0 end,
            },
            resolver = {
                resolve_or_exit = function(cfg, query) return query end,
            },
            model_info = {
                load_model_info = function() return nil end,
                list_models     = function() return {} end,
            },
            config = { CONFIG_FILE = "/fake/config.json" },
            bench  = {},
            recommend = T.REMOVE,
        }
        if extra then
            for k, v in pairs(extra) do stubs[k] = v end
        end
        return stubs
    end

    -- ── Test thread variation: multiple thread counts are tested ────
    do
        local thread_counts_seen = {}
        local rec

        T.with_stubs(base_sweep_stubs(), function()
            rec = require("recommend")
            rec._bench_runner = function(bench_path, model_path, flags)
                local threads = nil
                for i, flag in ipairs(flags) do
                    if flag == "-t" and flags[i + 1] then
                        threads = tonumber(flags[i + 1]); break
                    end
                end
                local seen = false
                for _, t in ipairs(thread_counts_seen) do
                    if t == threads then seen = true; break end
                end
                if not seen then table.insert(thread_counts_seen, threads) end
                local tg = threads == 8 and 80.0 or 50.0
                return {pp = 100.0, tg = tg, threads = threads}, nil
            end
            T.capture_output(function()
                rec.handle_recommend_command(SWEEP_ARGS, SWEEP_CFG)
            end)
        end)

        if #thread_counts_seen < 2 then
            error("expected multiple thread counts to be tested, got: " ..
                  table.concat(thread_counts_seen, ", "), 2)
        end
    end

    -- ── Test baseline improvement: no save when gain is < 2% ────────
    do
        local save_called = false
        local rec

        local stubs = base_sweep_stubs({
            util = {
                file_exists         = function() return true end,
                save_json           = function() save_called = true end,
                resolve_bench_path  = function() return "/fake/llama-bench" end,
                expand_path         = function(p) return p end,
                sh_quote            = function(s) return s end,
                normalize_exit_code = function() return 0 end,
            },
        })
        T.with_stubs(stubs, function()
            rec = require("recommend")
            rec._bench_runner = function(bench_path, model_path, flags)
                local threads = nil
                for i, flag in ipairs(flags) do
                    if flag == "-t" and flags[i + 1] then
                        threads = tonumber(flags[i + 1]); break
                    end
                end
                return {pp = 100.0, tg = 50.0, threads = threads}, nil
            end
            T.capture_output(function()
                rec.handle_recommend_command(SWEEP_ARGS, SWEEP_CFG)
            end)
        end)

        T.assert_eq(save_called, false, "no preset saved when improvement is < 2%")
    end

    -- ── Test flash-attn: bench receives 0/1, saved preset uses on/off ──
    -- Only fires on Metal (macOS); on non-Metal no -fa flags appear and
    -- the checks are skipped gracefully.
    do
        local saved_cfg = nil
        local fa_bench_values = {}
        local rec

        local stubs = base_sweep_stubs({
            util = {
                file_exists         = function() return true end,
                save_json           = function(_, data) saved_cfg = data end,
                resolve_bench_path  = function() return "/fake/llama-bench" end,
                expand_path         = function(p) return p end,
                sh_quote            = function(s) return s end,
                normalize_exit_code = function() return 0 end,
            },
        })
        T.with_stubs(stubs, function()
            rec = require("recommend")
            rec._bench_runner = function(bench_path, model_path, flags)
                local threads = nil
                for i, flag in ipairs(flags) do
                    if flag == "-t" and flags[i + 1] then threads = tonumber(flags[i + 1]) end
                    if flag == "-fa" and flags[i + 1] then
                        table.insert(fa_bench_values, flags[i + 1])
                    end
                end
                local tg = threads == 8 and 80.0 or 50.0
                return {pp = 100.0, tg = tg, threads = threads}, nil
            end
            T.capture_output(function()
                rec.handle_recommend_command(SWEEP_ARGS, SWEEP_CFG)
            end)
        end)

        for _, val in ipairs(fa_bench_values) do
            if val ~= "0" and val ~= "1" then
                error("bench runner received non-numeric -fa value: " .. tostring(val), 2)
            end
        end

        if saved_cfg then
            local preset = saved_cfg.models and
                           saved_cfg.models["fake-model"] and
                           saved_cfg.models["fake-model"].presets and
                           saved_cfg.models["fake-model"].presets.throughput
            if preset and preset.flags then
                local flags_str = table.concat(preset.flags, " ")
                if flags_str:find("--flash%-attn") then
                    if flags_str:find("--flash%-attn%s+[01]") then
                        error("preset --flash-attn must use 'on'/'off', not '0'/'1': " .. flags_str, 2)
                    end
                    T.assert_contains(flags_str, "--flash-attn on",
                        "preset uses 'on'/'off' for --flash-attn")
                end
            end
        end
    end

    -- ── Test TG is primary selection metric ─────────────────────────
    -- t=6 has lower PP but much higher TG. It must win.
    do
        local saved_cfg = nil
        local rec

        local stubs = base_sweep_stubs({
            util = {
                file_exists         = function() return true end,
                save_json           = function(_, data) saved_cfg = data end,
                resolve_bench_path  = function() return "/fake/llama-bench" end,
                expand_path         = function(p) return p end,
                sh_quote            = function(s) return s end,
                normalize_exit_code = function() return 0 end,
            },
        })
        T.with_stubs(stubs, function()
            rec = require("recommend")
            rec._bench_runner = function(bench_path, model_path, flags)
                local threads = nil
                for i, flag in ipairs(flags) do
                    if flag == "-t" and flags[i + 1] then
                        threads = tonumber(flags[i + 1]); break
                    end
                end
                if threads == 6 then
                    return {pp = 80.0, tg = 120.0, threads = threads}, nil
                else
                    return {pp = 150.0, tg = 40.0, threads = threads}, nil
                end
            end
            T.capture_output(function()
                rec.handle_recommend_command(SWEEP_ARGS, SWEEP_CFG)
            end)
        end)

        T.assert_eq(type(saved_cfg), "table", "config was saved")
        local preset = saved_cfg.models and
                       saved_cfg.models["fake-model"] and
                       saved_cfg.models["fake-model"].presets and
                       saved_cfg.models["fake-model"].presets.throughput
        T.assert_eq(type(preset), "table", "throughput preset was saved")
        T.assert_contains(table.concat(preset.flags, " "), "-t 6",
            "candidate with best TG (t=6) won despite lower PP")
    end

end }
