# luaLLM

A fast, scriptable command-line tool for managing, running, benchmarking, and optimizing local LLMs. Built in Lua on top of [llama.cpp](https://github.com/ggerganov/llama.cpp).

Launch models interactively or as background daemons. Pin your favorites. Benchmark performance across thread counts, KV cache types, and flash attention configs. Let the recommendation engine find your fastest settings automatically. Keep freeform notes on every model. All from a single `luallm` command.

---

## Features

**Running Models**
- Interactive TUI picker with pinned + recent model sections
- Foreground and background (daemon) mode with multi-server support
- Fuzzy model name matching — no need to type exact filenames
- Saved presets (`--preset throughput`, `--preset cold-start`) for optimized launches

**Model Management**
- Pin models for quick access at the top of the picker
- Freeform markdown notes per model with timestamped entries
- Cached model metadata (context size, quantization, rope settings)
- Multi-part GGUF merging for split model files

**Benchmarking & Optimization**
- Automated benchmark sweeps with `llama-bench` (configurable runs, warmup, threads)
- Side-by-side model comparison with delta/percentage stats and comparability warnings
- `recommend throughput` — sweeps thread counts, KV cache types, and flash attention to find the fastest flags
- `recommend cold-start` — generates a preset optimized for minimum time-to-first-token

**Utilities**
- `--json` output on `list`, `status`, `notes`, `help` for scripting and tool integration
- Configuration diagnostics (`doctor`) to validate your setup
- Rebuild llama.cpp from source with one command

---

## Quick Start

```bash
# 1. Install
brew install lua luarocks        # macOS
make install

# 2. Configure (auto-created on first run)
luallm config                    # shows config file path — edit it to set your models_dir and llama_cpp_path

# 3. Run
luallm                           # interactive picker
luallm mistral                   # run by name (fuzzy match)
luallm start mistral             # launch as background daemon
```

---

## Installation

### Prerequisites

- **Lua 5.3+** and **luarocks**
- **llama.cpp** binaries — at minimum `llama-server`; also `llama-bench` (for benchmarking), `llama-gguf-split` (for join), `llama-cli` (optional)
- One or more `.gguf` model files

```bash
# macOS
brew install lua luarocks

# Ubuntu / Debian
sudo apt install lua5.4 liblua5.4-dev luarocks
```

### Install with Make

```bash
make install                # installs Lua deps and symlinks to ~/.local/bin/luallm
```

Make sure `~/.local/bin` is in your PATH (it is by default on most systems).

For system-wide installation:

```bash
sudo make install PREFIX=/usr/local
```

### Manual Install

```bash
make deps                         # install lua-cjson and luafilesystem via luarocks
chmod +x luallm.lua
mkdir -p ~/.local/bin
ln -sf $(pwd)/luallm.lua ~/.local/bin/luallm
```

> **Note:** `luallm.lua` must be symlinked, not copied — it resolves `src/` module imports relative to the script location.

### Verify

```bash
make check                       # checks that Lua dependencies are installed
luallm doctor                    # validates config, binaries, and models directory
```

### Luarocks Path

If you get "module not found" errors, add this to your shell config (`~/.bashrc` or `~/.zshrc`):

```bash
eval $(luarocks path --bin)
```

---

## Usage

### Running Models

```bash
luallm                           # interactive picker (pinned + recent models)
luallm <model>                   # fuzzy-match a model name, run in foreground
luallm run <model>               # explicit run command (same as above)
luallm run <model> --preset throughput   # run with saved optimized flags
luallm <model> --port 9090 -c 8192      # pass extra llama.cpp flags (override defaults)
```

Model names are fuzzy-matched — `mistral` matches `mistral-7b-instruct-v0.3.Q4_K_M.gguf`. If multiple models match, the picker appears.

### Daemon Mode

Run models as background servers that persist after you close the terminal:

```bash
luallm start <model>             # launch in background, returns immediately
luallm start <model> --port 8081 # run on a specific port
luallm start <model> --preset throughput

luallm status                    # show running and recently stopped servers
luallm logs <model>              # view daemon output
luallm logs <model> --follow     # tail logs in real time
luallm stop <model>              # stop a server (SIGTERM, then SIGKILL)
luallm stop all                  # stop everything
```

Multiple servers can run simultaneously on different ports. State is tracked in `~/.cache/luallm/state.json`.

### Model Management

```bash
luallm list                      # list all models (name, size, quantization, last run)
luallm list --json               # JSON output for scripting

luallm info <model>              # show cached metadata (context size, quant, rope, etc.)
luallm info <model> --kv         # show full GGUF key-value pairs
luallm info <model> --raw        # show raw captured llama.cpp output

luallm pin <model>               # pin a model (appears at top of picker)
luallm unpin <model>
luallm pinned                    # list pinned models

luallm notes <model>             # view notes for a model
luallm notes add <model> "great for coding, fast on 8 threads"
luallm notes edit <model>        # open in $EDITOR
luallm notes list                # list all models with notes

luallm join                      # merge multi-part GGUF files (ModelName-00001-of-00003.gguf -> ModelName.gguf)
luallm join llama-405b           # merge a specific model
```

Metadata is captured automatically the first time you run a model and cached locally.

### Benchmarking & Optimization

```bash
luallm bench <model>             # run benchmark sweep (5 runs, 1 warmup)
luallm bench <model> --n 10      # 10 measured runs
luallm bench <model> --warmup 2  # 2 warmup runs
luallm bench <model> --threads 8

luallm bench show                # view saved results (picker)
luallm bench show <model>        # view results for a specific model
luallm bench compare <A> <B>     # side-by-side comparison with deltas
luallm bench compare <A> <B> --verbose   # include hardware and build details
luallm bench clear               # delete all saved benchmark data
```

**Preset Recommendations:**

```bash
luallm recommend throughput <model>   # benchmark sweep across threads, KV cache types, flash attention
                                      # finds the fastest flags and saves them as a preset

luallm recommend cold-start <model>   # generates a preset optimized for fast model loading
                                      # (small context, reduced GPU layers, no flash attention)

luallm run <model> --preset throughput # use the saved preset
luallm start <model> --preset cold-start
```

The `throughput` profile tests combinations of thread counts, KV cache quantization (`q8_0`, `q4_0`), and flash attention, then saves the winner. The `cold-start` profile generates a static preset tuned for minimum time-to-first-token.

### Maintenance

```bash
luallm doctor                    # validate config, check binaries, count models
luallm config                    # show config file path
luallm rebuild                   # git pull + rebuild llama.cpp from source
luallm clear-history             # reset run history
luallm test                      # run the test suite
```

### Help

```bash
luallm help                      # overview of all commands
luallm help <command>            # detailed help for a specific command
luallm help --json               # structured JSON output (for tool integration)
```

---

## Configuration

On first run, a config file is created at `~/.config/luaLLM/config.json`. See [`config.example.json`](config.example.json) for a full example.

```json
{
  "llama_cpp_path": "/usr/local/bin/llama-server",
  "llama_bench_path": "/usr/local/bin/llama-bench",
  "llama_cli_path": "/usr/local/bin/llama-cli",
  "llama_cpp_source_dir": "/home/user/llama.cpp",
  "models_dir": "/home/user/models",
  "recent_models_count": 7,
  "default_port": 8080,
  "default_params": ["-c 4096", "--host 127.0.0.1", "--threads 8"],
  "bench": {
    "default_n": 5,
    "default_warmup": 1,
    "default_ctx": 2048,
    "default_gen": 256,
    "default_batch": 512,
    "default_threads": 8
  },
  "cmake_options": [
    "-DGGML_METAL=ON",
    "-DGGML_METAL_EMBED_LIBRARY=ON",
    "-DGGML_USE_FLASH_ATTENTION=ON",
    "-DLLAMA_BUILD_SERVER=ON",
    "-DCMAKE_BUILD_TYPE=Release"
  ],
  "model_overrides": {
    "codellama": ["-c 16384", "--gpu-layers 35"],
    "llama%-3.*70b": ["-c 8192", "--gpu-layers 40", "--threads 16"],
    "mistral": ["-c 8192"]
  }
}
```

### Configuration Reference

| Key | Required | Description |
|-----|----------|-------------|
| `llama_cpp_path` | Yes | Path to `llama-server` binary |
| `models_dir` | Yes | Directory containing `.gguf` model files |
| `default_params` | No | Default flags passed to llama-server on every run |
| `default_port` | No | Default port for llama-server (default: 8080) |
| `recent_models_count` | No | Number of recent models shown in picker (default: 4) |
| `llama_bench_path` | No | Path to `llama-bench` (auto-resolved from `llama_cpp_path` if not set) |
| `llama_cli_path` | No | Path to `llama-cli` |
| `llama_cpp_source_dir` | No | Path to llama.cpp source for `rebuild` command |
| `cmake_options` | No | CMake flags used by `rebuild` |
| `bench.default_n` | No | Default number of benchmark runs |
| `bench.default_warmup` | No | Default warmup runs before measuring |
| `bench.default_threads` | No | Default thread count for benchmarking |
| `bench.default_ctx` | No | Default context size for benchmarks |
| `bench.default_gen` | No | Default generation length for benchmarks |
| `bench.default_batch` | No | Default batch size for benchmarks |
| `model_overrides` | No | Pattern-based per-model parameter overrides (see below) |

### Model Overrides

The `model_overrides` keys are [Lua patterns](https://www.lua.org/pil/20.2.html) matched against model filenames. Any model whose filename contains the pattern will use those additional flags:

```json
{
  "model_overrides": {
    "codellama": ["-c 16384"],
    "llama%-3": ["--gpu-layers 35"],
    "mistral.*7b": ["-c 8192"]
  }
}
```

Both `codellama-7b-v1.5.gguf` and `codellama-13b-v2.gguf` match `"codellama"`. Note the `%-` escape — `-` is a special character in Lua patterns.

---

## Command Reference

| Command | Description |
|---------|-------------|
| `luallm` | Interactive picker (pinned + recent models) |
| `luallm <model>` | Fuzzy-match and run a model |
| `luallm run <model>` | Run with optional `--preset` |
| `luallm start <model>` | Start as background daemon |
| `luallm stop <model\|all>` | Stop running server(s) |
| `luallm status` | Show server status |
| `luallm logs <model>` | View daemon logs (`--follow`) |
| `luallm list` | List all models (`--json`) |
| `luallm info <model>` | Show model metadata (`--kv`, `--raw`) |
| `luallm pin/unpin <model>` | Pin or unpin a model |
| `luallm pinned` | List pinned models |
| `luallm notes <model>` | View/add/edit model notes |
| `luallm bench <model>` | Run benchmarks |
| `luallm bench show/compare` | View or compare benchmark results |
| `luallm recommend <profile>` | Generate optimized presets |
| `luallm join` | Merge multi-part GGUF files |
| `luallm doctor` | Run diagnostics |
| `luallm config` | Show config file path |
| `luallm rebuild` | Rebuild llama.cpp from source |
| `luallm clear-history` | Clear run history |
| `luallm help [command]` | Show help (`--json`) |
| `luallm test` | Run test suite |

---

## Data Locations

| Path | Contents |
|------|----------|
| `~/.config/luaLLM/config.json` | Configuration |
| `~/.config/luaLLM/history.json` | Run history |
| `~/.config/luaLLM/pins.json` | Pinned models |
| `~/.config/luaLLM/model_info/` | Cached model metadata |
| `~/.config/luaLLM/notes/` | Per-model markdown notes |
| `~/.config/luaLLM/bench/` | Benchmark results |
| `~/.cache/luallm/state.json` | Server state (running/stopped) |
| `~/.cache/luallm/logs/` | Daemon log files |
| `~/.cache/luallm/pids/` | Daemon PID files |

---

## License

[Apache-2.0](LICENSE)
