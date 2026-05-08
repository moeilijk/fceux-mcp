# fceux-mcp

An MCP server that exposes the [FCEUX](https://fceux.com/) NES emulator's Lua API as MCP tools, so an LLM agent can read memory, send controller input, advance frames, manage savestates, and capture the screen.

See [`docs/CONCEPT.md`](./docs/CONCEPT.md) for the design. The Lua surface being wrapped is documented in [`docs/FLUA-FUNCTIONS.md`](./docs/FLUA-FUNCTIONS.md).

## How it works

The MCP server (Python) spawns FCEUX with `fceux --loadlua bridge.lua <rom>`. The bridge script runs inside FCEUX's embedded Lua 5.1 interpreter, loads [LuaSocket](https://lunarmodules.github.io/luasocket/) from `vendor/`, opens a loopback TCP port, and dispatches JSON commands to FCEUX's `emu.*` / `memory.*` / `joypad.*` libraries. The server speaks MCP (JSON-RPC over stdio) to the client and TCP to the bridge.

LuaSocket isn't part of FCEUX's Lua, so pre-built binaries are vendored under `vendor/luasocket/<platform>/` and `bridge.lua` adds them to `package.cpath` at startup.

If the server starts and finds the bridge port already listening, it skips the spawn and just attaches — handy for development.

## Prerequisites

- **macOS (Apple Silicon)** — `brew install fceux`. The repo ships pre-built LuaSocket for `macos-arm64`.
- **Python 3.10+** — for the MCP server.
- **Other platforms** — `vendor/luasocket/` currently only contains `macos-arm64` artifacts. For macOS Intel, Linux, or Windows, build LuaSocket for that platform and drop the files into `vendor/luasocket/<platform>/`. Recipe in [`vendor/luasocket/README.md`](./vendor/luasocket/README.md).

## Install

From the repo root:

```sh
python3 -m venv .venv
.venv/bin/pip install -e .
```

This installs the `fceux-mcp` console script into `.venv/bin/`.

## Run

```sh
.venv/bin/fceux-mcp --rom /path/to/your.nes
```

Flags:

- `--rom PATH` — required when no bridge is already running; ignored if attaching to an existing bridge.
- `--port N` — bridge TCP port (default 9999). Also overridable via `FCEUX_BRIDGE_PORT` for the bridge side.
- `--host HOST` — bridge host (default 127.0.0.1).
- `--bridge-lua PATH` — override `bridge.lua` location (defaults to the one next to the package).

## Claude Desktop configuration

```json
{
  "mcpServers": {
    "fceux": {
      "command": "/absolute/path/to/fceux-mcp/.venv/bin/fceux-mcp",
      "args": ["--rom", "/absolute/path/to/your.nes"]
    }
  }
}
```

## Notes

- Verified on macOS 15 / Apple Silicon with FCEUX 2.6.6 from Homebrew and Python 3.13.
