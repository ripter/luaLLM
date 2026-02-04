-- util.test.lua — unit tests for src/util.lua
-- Uses only the pure, side-effect-free helpers.

local util         = require("util")
local test_helpers = require("test_helpers")

local assert_eq = test_helpers.assert_eq

return {
    run = function()
        -- ── sh_quote ────────────────────────────────────────────
        assert_eq(util.sh_quote("hello"),          "'hello'",             "plain word")
        assert_eq(util.sh_quote("hello world"),    "'hello world'",       "word with space")
        assert_eq(util.sh_quote("it's"),           "'it'\\''s'",          "embedded single-quote")
        assert_eq(util.sh_quote(""),               "''",                  "empty string")
        assert_eq(util.sh_quote("a'b'c"),          "'a'\\''b'\\''c'",     "multiple single-quotes")

        -- ── expand_path ─────────────────────────────────────────
        local home = os.getenv("HOME") or ""
        assert_eq(util.expand_path("~/foo"),       home .. "/foo",        "tilde expansion")
        assert_eq(util.expand_path("/abs/path"),   "/abs/path",           "absolute path unchanged")
        assert_eq(util.expand_path("rel/path"),    "rel/path",            "relative path unchanged")

        -- ── format_size ─────────────────────────────────────────
        assert_eq(util.format_size(0),                                    "0B",    "zero bytes")
        assert_eq(util.format_size(512),                                  "512B",  "sub-KB")
        assert_eq(util.format_size(1024),                                 "1.0KB", "exactly 1 KB")
        assert_eq(util.format_size(1536),                                 "1.5KB", "1.5 KB")
        assert_eq(util.format_size(1048576),                              "1.0MB", "exactly 1 MB")
        assert_eq(util.format_size(1073741824),                           "1.0GB", "exactly 1 GB")
        assert_eq(util.format_size(math.floor(4.7 * 1024*1024*1024)),     "4.7GB", "4.7 GB")

        -- ── file_exists ─────────────────────────────────────────
        assert_eq(util.file_exists("/this/path/does/not/exist/ever"), false, "file_exists on missing")
        
        -- ── safe_filename ───────────────────────────────────────
        assert_eq(util.safe_filename("model-name"),           "model-name",      "simple name unchanged")
        assert_eq(util.safe_filename("model_name_v2.1"),      "model_name_v2.1", "underscores and dots ok")
        assert_eq(util.safe_filename("model/with/slashes"),   "model_with_slashes", "slashes replaced")
        assert_eq(util.safe_filename("model:with:colons"),    "model_with_colons",  "colons replaced")
        assert_eq(util.safe_filename("model with spaces"),    "model_with_spaces",  "spaces replaced")
        assert_eq(util.safe_filename("../../../etc/passwd"),  "_________etc_passwd",   "directory traversal blocked")
        assert_eq(util.safe_filename(".."),                   "__",                 "double-dot becomes double-underscore")
        assert_eq(util.safe_filename(".hidden"),              "hidden",             "leading dot trimmed")
        assert_eq(util.safe_filename("file."),                "file",               "trailing dot trimmed")
        assert_eq(util.safe_filename(""),                     "unnamed",            "empty becomes unnamed")
        assert_eq(util.safe_filename("model<>:\"|?*"),        "model_______",     "Windows unsafe chars replaced")
        
        -- ── rm_rf ───────────────────────────────────────────────
        -- Test with temp directory
        local tmpdir = os.tmpname()
        os.remove(tmpdir)  -- tmpname creates a file, we want a dir
        
        -- Create test structure
        local ok = util.exec("mkdir -p " .. tmpdir .. "/subdir")
        if ok then
            local f = io.open(tmpdir .. "/file.txt", "w")
            if f then
                f:write("test")
                f:close()
            end
            
            f = io.open(tmpdir .. "/subdir/nested.txt", "w")
            if f then
                f:write("nested")
                f:close()
            end
            
            -- Test rm_rf
            local rm_ok, rm_err = util.rm_rf(tmpdir)
            assert_eq(rm_ok, true, "rm_rf returns true on success")
            assert_eq(rm_err, nil, "rm_rf returns nil error on success")
            assert_eq(util.is_dir(tmpdir) or false, false, "directory removed")
            
            -- Test rm_rf on non-existent path (should succeed)
            local rm_ok2, rm_err2 = util.rm_rf(tmpdir)
            assert_eq(rm_ok2, true, "rm_rf on non-existent path returns true")
        end
        
        -- Test rm_rf on single file
        local tmpfile = os.tmpname()
        local f = io.open(tmpfile, "w")
        if f then
            f:write("test")
            f:close()
            
            local rm_ok, rm_err = util.rm_rf(tmpfile)
            assert_eq(rm_ok, true, "rm_rf removes single file")
            assert_eq(util.file_exists(tmpfile), false, "file removed")
        end
    end
}
