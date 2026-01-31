# luaLLM - Local AI Model Manager

A command-line tool for managing and running local AI models with llama.cpp.

## Features

- 🎯 Interactive model picker with arrow key navigation
- 📝 Automatic tracking of last 4 used models
- ⚙️ Configurable default parameters for llama.cpp
- 🎨 Pattern-based model-specific overrides
- 📂 Simple configuration in `~/.config/luaLLM/`

## Installation

### Prerequisites

```bash
# Install Lua and required libraries
sudo apt install lua5.4 liblua5.4-dev luarocks  # Ubuntu/Debian
# or
brew install lua luarocks  # macOS
```

### Quick Install (with Make)

```bash
# Install dependencies and set up the script
sudo make install

# Or install to custom location
sudo make install PREFIX=/usr
```

**Note:** If you get "module not found" errors, the script will automatically configure luarocks paths. Alternatively, add this to your shell config (~/.bashrc or ~/.zshrc):

```bash
eval $(luarocks path --bin)
```

### Manual Install

```bash
# Install Lua dependencies
make deps

# Make executable
chmod +x luallm.lua

# Move to somewhere in your PATH
sudo mv luallm.lua /usr/local/bin/luallm
```

### Verify Installation

```bash
# Check if dependencies are installed
make check
```

## Configuration

On first run, a config file is created at `~/.config/luaLLM/config.json`:

```json
{
  "llama_cpp_path": "/usr/local/bin/llama-server",
  "models_dir": "/home/user/models",
  "default_params": ["-c", "4096", "--port", "8080", "--host", "127.0.0.1"],
  "model_overrides": {
    "codellama": ["-c", "8192"],
    "llama-3": ["--port", "8081"]
  }
}
```

### Configuration Options

- **llama_cpp_path**: Path to your llama-server binary
- **llama_cpp_source_dir**: Path to llama.cpp git repository (for rebuilding)
- **models_dir**: Directory containing your .gguf model files
- **recent_models_count**: Number of recent models to show in picker (default: 4)
- **default_params**: Default parameters passed to llama.cpp
- **cmake_options**: CMake build flags used when rebuilding llama.cpp
- **model_overrides**: Pattern-based overrides for specific models

## Usage

### Show Help

```bash
luallm help
```

### Interactive Picker (Default)

```bash
luallm
```

Shows the last 4 used models. Use arrow keys (↑/↓) to select, Enter to launch, or 'q' to quit.

### List All Models

```bash
luallm list
```

### Run Specific Model

```bash
luallm llama-3-8b
```

### Run with Custom Parameters

```bash
luallm llama-3-8b --port 9090 -c 8192
```

Custom parameters override both defaults and model-specific overrides.

### Show Model Info

```bash
luallm info
```

Shows an interactive picker of models with cached metadata. Use arrow keys to select a model and view its info.

```bash
luallm info llama-3-8b
```

Shows cached metadata about a specific model (context size, quantization, rope settings, etc.) without running it. The metadata is captured the first time you run a model.

```bash
luallm info llama-3-8b --kv
```

Shows the full structured KV dictionary for detailed comparison.

```bash
luallm info llama-3-8b --raw
```

Shows the raw captured output lines.

### View Config Location

```bash
luallm config
```

### Rebuild llama.cpp

```bash
luallm rebuild
```

Pulls the latest changes from git and rebuilds llama.cpp with optimized settings (Metal, Flash Attention, etc.). Configure the source directory in your config file.

### Clear Run History

```bash
luallm clear-history
```

Clears the history of models you've run. This resets the "last run" timestamps shown in the list.

## Model Overrides

The `model_overrides` section uses Lua pattern matching. Any model filename containing the pattern will use those overrides:

```json
{
  "model_overrides": {
    "codellama": ["-c 16384"],
    "llama%-3": ["--gpu-layers 35"],
    "mistral.*7b": ["-c 8192"]
  }
}
```

This way, `codellama-7b-v1.5.gguf` and `codellama-13b-v2.gguf` both match "codellama".

## Examples

```bash
# First time - pick interactively
luallm

# List all available models
luallm list

# Run a specific model
luallm mistral-7b

# Override port
luallm llama-3-8b --port 8081

# Multiple overrides
luallm codellama-13b -c 16384 --gpu-layers 40
```

## Tips

- Model files must have `.gguf` extension
- Use the base filename without `.gguf` when running
- The tool tracks your 4 most recent models automatically
- Edit config file directly for advanced customization

## License

MIT
