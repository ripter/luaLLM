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
    end
}
