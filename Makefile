.PHONY: install deps check clean uninstall help

PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin
SHAREDIR = $(PREFIX)/share/luallm
SCRIPT = luallm.lua
TARGET = $(BINDIR)/luallm
EXAMPLE_CONFIG = config.example.json

help:
	@echo "luaLLM - Makefile targets:"
	@echo ""
	@echo "  make deps      - Install Lua dependencies (lua-cjson, luafilesystem)"
	@echo "  make install   - Install dependencies and copy script to $(BINDIR)"
	@echo "  make check     - Check if dependencies are installed"
	@echo "  make uninstall - Remove installed script"
	@echo "  make clean     - Remove local build artifacts"
	@echo ""
	@echo "Options:"
	@echo "  PREFIX=/path   - Install location (default: /usr/local)"

check:
	@echo "Checking Lua installation..."
	@which lua > /dev/null || (echo "ERROR: lua not found. Install lua first." && exit 1)
	@which luarocks > /dev/null || (echo "ERROR: luarocks not found. Install luarocks first." && exit 1)
	@echo "✓ Lua and luarocks found"
	@echo ""
	@echo "Checking dependencies..."
	@lua -e 'require("cjson")' 2>/dev/null && echo "✓ lua-cjson installed" || echo "✗ lua-cjson missing"
	@lua -e 'require("lfs")' 2>/dev/null && echo "✓ luafilesystem installed" || echo "✗ luafilesystem missing"

deps:
	@echo "Installing Lua dependencies..."
	@which luarocks > /dev/null || (echo "ERROR: luarocks not found. Please install luarocks first." && exit 1)
	@echo "Installing lua-cjson..."
	@luarocks install --local lua-cjson || luarocks install lua-cjson
	@echo "Installing luafilesystem..."
	@luarocks install --local luafilesystem || luarocks install luafilesystem
	@echo ""
	@echo "✓ Dependencies installed"

install: deps
	@echo "Installing luallm..."
	@chmod +x $(SCRIPT)
	@echo "✓ Made $(SCRIPT) executable"
	@mkdir -p $(BINDIR)
	@mkdir -p $(SHAREDIR)
	@cp $(SCRIPT) $(TARGET)
	@echo "✓ Installed script to $(TARGET)"
	@cp $(EXAMPLE_CONFIG) $(SHAREDIR)/$(EXAMPLE_CONFIG)
	@echo "✓ Installed example config to $(SHAREDIR)/$(EXAMPLE_CONFIG)"
	@echo ""
	@echo "Installation complete! You can now run: luallm"
	@echo ""
	@echo "Note: If luarocks installed packages locally, you may need to add this to your shell config:"
	@echo '  eval $$(luarocks path --bin)'

uninstall:
	@echo "Uninstalling luallm..."
	@rm -f $(TARGET)
	@rm -rf $(SHAREDIR)
	@echo "✓ Removed $(TARGET) and $(SHAREDIR)"
	@echo ""
	@echo "Config files remain at ~/.config/luaLLM/"
	@echo "Run 'rm -rf ~/.config/luaLLM' to remove them."

clean:
	@echo "Cleaning up..."
	@rm -f $(SCRIPT).bak
	@echo "✓ Clean complete"
