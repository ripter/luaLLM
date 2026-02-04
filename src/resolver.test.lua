-- resolver.test.lua — unit tests for src/resolver.lua

local T = require("test_helpers")

return { run = function()
    
    -- ── Test 1: Exact match wins over substring ────────────────────────
    do
        local resolver
        T.with_stubs({
            resolve = {
                find_matching_models = function(cfg, query)
                    -- Simulate: "test" exactly matches "test" even though "test-model" also matches
                    if query:lower() == "test" then
                        return {"test"}, "exact"
                    else
                        return {"test", "test-model"}, "substring"
                    end
                end
            },
            picker = { show_picker = function() error("picker should not be called") end },
            format = { get_model_row = function() return "n", "1GB", "Q4", "never" end,
                       calculate_column_widths = function() return 10, 3, 2 end,
                       format_model_row = function() return "row" end },
            model_info = {
                list_models = function() return {{name="test"}, {name="test-model"}} end
            },
            resolver = T.REMOVE,
        }, function()
            resolver = require("resolver")
        end)
        
        local cfg = {models_dir = "/fake"}
        local model_name, match_type = resolver.resolve_model_name(cfg, "test", {show_suggestions = false})
        
        T.assert_eq(model_name, "test", "exact match wins")
        T.assert_eq(match_type, "exact", "match_type is exact")
    end
    
    -- ── Test 2: Single substring match returns automatically ───────────
    do
        local resolver
        T.with_stubs({
            resolve = {
                find_matching_models = function(cfg, query)
                    return {"unique-model"}, "substring"
                end
            },
            picker = { show_picker = function() error("picker should not be called") end },
            format = { get_model_row = function() return "n", "1GB", "Q4", "never" end },
            model_info = { list_models = function() return {} end },
            resolver = T.REMOVE,
        }, function()
            resolver = require("resolver")
        end)
        
        local cfg = {models_dir = "/fake"}
        local model_name, match_type = resolver.resolve_model_name(cfg, "unique", {show_suggestions = false})
        
        T.assert_eq(model_name, "unique-model", "single substring match returned")
        T.assert_eq(match_type, "substring", "match_type is substring")
    end
    
    -- ── Test 3: Multiple matches trigger picker ────────────────────────
    do
        local resolver
        local picker_was_called = false
        T.with_stubs({
            resolve = {
                find_matching_models = function(cfg, query)
                    return {"model-a", "model-b", "model-c"}, "substring"
                end
            },
            picker = {
                show_picker = function(models, cfg, title)
                    picker_was_called = true
                    T.assert_eq(#models, 3, "picker received 3 models")
                    return "model-b"  -- user selects second one
                end
            },
            format = { get_model_row = function() return "n", "1GB", "Q4", "never" end },
            model_info = { list_models = function() return {} end },
            resolver = T.REMOVE,
        }, function()
            resolver = require("resolver")
        end)
        
        local cfg = {models_dir = "/fake"}
        local model_name, match_type = resolver.resolve_model_name(cfg, "model", {show_suggestions = false})
        
        T.assert_eq(picker_was_called, true, "picker was called for ambiguous match")
        T.assert_eq(model_name, "model-b", "user-selected model returned")
        T.assert_eq(match_type, "picker", "match_type is picker")
    end
    
    -- ── Test 4: No match returns nil + suggestions ──────────────────────
    do
        local resolver
        T.with_stubs({
            resolve = {
                find_matching_models = function(cfg, query)
                    return {}, "none"
                end
            },
            picker = { show_picker = function() error("picker should not be called") end },
            format = { 
                get_model_row = function(cfg, name)
                    return name, "1GB", "Q4", "never"
                end,
                calculate_column_widths = function() return 10, 3, 2 end,
                format_model_row = function(m) return m.name end
            },
            model_info = {
                list_models = function() return {{name="suggestion-1"}, {name="suggestion-2"}} end
            },
            resolver = T.REMOVE,
        }, function()
            resolver = require("resolver")
        end)
        
        local cfg = {models_dir = "/fake"}
        
        -- Capture print output to verify suggestions shown
        local printed = T.capture_print(function()
            local model_name, match_type = resolver.resolve_model_name(cfg, "nonexistent")
            T.assert_eq(model_name, nil, "no match returns nil")
            T.assert_eq(match_type, "none", "match_type is none")
        end)
        
        -- Verify suggestions were printed
        local output = table.concat(printed, "\n")
        T.assert_contains(output, "No model found", "error message shown")
        T.assert_contains(output, "Available models", "suggestions header shown")
    end
    
    -- ── Test 5: allow_picker=false prevents picker on ambiguity ────────
    do
        local resolver
        T.with_stubs({
            resolve = {
                find_matching_models = function(cfg, query)
                    return {"model-a", "model-b"}, "substring"
                end
            },
            picker = { show_picker = function() error("picker should not be called") end },
            format = { get_model_row = function() return "n", "1GB", "Q4", "never" end },
            model_info = { list_models = function() return {} end },
            resolver = T.REMOVE,
        }, function()
            resolver = require("resolver")
        end)
        
        local cfg = {models_dir = "/fake"}
        local model_name, match_type = resolver.resolve_model_name(cfg, "model", {
            allow_picker = false,
            show_suggestions = false
        })
        
        T.assert_eq(model_name, nil, "ambiguous match with allow_picker=false returns nil")
        T.assert_eq(match_type, "ambiguous", "match_type is ambiguous")
    end
    
    -- ── Test 6: Empty query shows picker with all models ───────────────
    do
        local resolver
        local picker_was_called = false
        T.with_stubs({
            resolve = { find_matching_models = function() error("should not be called") end },
            picker = {
                show_picker = function(models, cfg, title)
                    picker_was_called = true
                    T.assert_eq(#models, 2, "picker received all models")
                    return "all-model-1"
                end
            },
            format = { get_model_row = function() return "n", "1GB", "Q4", "never" end },
            model_info = {
                list_models = function() return {{name="all-model-1"}, {name="all-model-2"}} end
            },
            resolver = T.REMOVE,
        }, function()
            resolver = require("resolver")
        end)
        
        local cfg = {models_dir = "/fake"}
        local model_name, match_type = resolver.resolve_model_name(cfg, nil)
        
        T.assert_eq(picker_was_called, true, "empty query triggered picker")
        T.assert_eq(model_name, "all-model-1", "user selection returned")
        T.assert_eq(match_type, "picker", "match_type is picker")
    end
    
    -- ── Test 7: User quits picker returns nil ───────────────────────────
    do
        local resolver
        T.with_stubs({
            resolve = {
                find_matching_models = function(cfg, query)
                    return {"model-a", "model-b"}, "substring"
                end
            },
            picker = {
                show_picker = function() return nil end  -- user quit
            },
            format = { get_model_row = function() return "n", "1GB", "Q4", "never" end },
            model_info = { list_models = function() return {} end },
            resolver = T.REMOVE,
        }, function()
            resolver = require("resolver")
        end)
        
        local cfg = {models_dir = "/fake"}
        local model_name, match_type = resolver.resolve_model_name(cfg, "model", {show_suggestions = false})
        
        T.assert_eq(model_name, nil, "user quit returns nil")
        T.assert_eq(match_type, "none", "match_type is none when user quits")
    end
    
    -- ── Test 8: resolve_or_exit calls os.exit on failure ───────────────
    do
        local resolver
        local exit_called = false
        local old_exit = os.exit
        
        T.with_stubs({
            resolve = {
                find_matching_models = function() return {}, "none" end
            },
            picker = { show_picker = function() error("should not be called") end },
            format = { 
                get_model_row = function() return "n", "1GB", "Q4", "never" end,
                calculate_column_widths = function() return 10, 3, 2 end,
                format_model_row = function() return "row" end
            },
            model_info = { list_models = function() return {} end },
            resolver = T.REMOVE,
        }, function()
            resolver = require("resolver")
        end)
        
        os.exit = function(code)
            exit_called = true
            T.assert_eq(code, 1, "exit code is 1")
            error({__test_exit = true})  -- prevent actual exit
        end
        
        local cfg = {models_dir = "/fake"}
        local ok = pcall(function()
            resolver.resolve_or_exit(cfg, "nonexistent", {show_suggestions = false})
        end)
        
        os.exit = old_exit
        
        T.assert_eq(exit_called, true, "os.exit was called")
        T.assert_eq(ok, false, "resolve_or_exit threw when exit was stubbed")
    end
    
end }
