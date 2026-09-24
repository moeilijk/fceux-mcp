# fceux-mcp

An MCP server that exposes the [FCEUX](https://fceux.com/) NES emulator's Lua API as MCP tools, so an LLM agent can read memory, send controller input, advance frames, manage savestates, and capture the screen.

## How it works

The MCP server (Python) spawns FCEUX with `fceux --loadlua bridge.lua <rom>` (on Windows: `fceux.exe -lua <absolute path to bridge.lua> <rom>`). The bridge script runs inside FCEUX's embedded Lua 5.1 interpreter, loads [LuaSocket](https://lunarmodules.github.io/luasocket/) from `vendor/` (on Windows FCEUX has it built in), opens a loopback TCP port, and dispatches JSON commands to FCEUX's `emu.*` / `memory.*` / `joypad.*` libraries. The server speaks MCP (JSON-RPC over stdio) to the client and TCP to the bridge.

LuaSocket isn't part of FCEUX's Lua, so pre-built binaries are vendored under `vendor/luasocket/<platform>/` and `bridge.lua` adds them to `package.cpath` at startup.

If the server starts and finds the bridge port already listening, it skips the spawn and just attaches — handy for development.

## Prerequisites

- **macOS (Apple Silicon)** — `brew install fceux`. The repo ships pre-built LuaSocket for `macos-arm64`.
- **Python 3.10+** — for the MCP server.
- **Windows** — FCEUX 2.6.6 for Windows ([fceux.com](https://fceux.com)), the win32 or win64 build (`fceux.exe`, `fceux64.exe`). They have LuaSocket's core built in, so nothing needs to be built; pass the executable with `--fceux C:\path\to\fceux64.exe`.
- **Other platforms** — `vendor/luasocket/` currently only contains `macos-arm64` artifacts. For macOS Intel or Linux, build LuaSocket for that platform and drop the files into `vendor/luasocket/<platform>/`. Recipe in [`vendor/luasocket/README.md`](./vendor/luasocket/README.md).

## Install

From the repo root:

```sh
python3 -m venv .venv
.venv/bin/pip install -e .
```

This installs the `fceux-mcp` console script into `.venv/bin/`.

## Run

```sh
# With a starter ROM:
.venv/bin/fceux-mcp --rom /path/to/your.nes

# Or without — boots on a bundled no-op dummy ROM; agent loads a real
# ROM via emu_loadrom as its first action:
.venv/bin/fceux-mcp
```

Flags:

- `--rom PATH` — optional. Without it, FCEUX boots on a bundled minimal NES ROM (`fceux_mcp/data/dummy.nes`) and the agent is expected to switch to a real ROM via the `emu_loadrom` tool. With it, that ROM is the starter; the agent can still switch later. Ignored entirely if attaching to an already-running bridge.
- `--port N` — bridge TCP port (default 9999). Also overridable via `FCEUX_BRIDGE_PORT` for the bridge side.
- `--host HOST` — bridge host (default 127.0.0.1).
- `--bridge-lua PATH` — override `bridge.lua` location (defaults to the one next to the package).
- `--fceux PATH` — the FCEUX executable (default `fceux` on the `PATH`).

Environment for the bridge:

- `FCEUX_BRIDGE_DISABLE` — comma-separated method names the bridge refuses for this session, e.g. `lua.exec,memory.writebyte`.

## Claude Code configuration

Two ways to register the server with Claude Code.

**Via the CLI (easiest)** — adds the server to your user-scope config:

```sh
# Minimum: server picks the bundled dummy ROM, agent loads real ROMs on demand
claude mcp add fceux /absolute/path/to/fceux-mcp/.venv/bin/fceux-mcp

# Or pin a starter ROM
claude mcp add fceux /absolute/path/to/fceux-mcp/.venv/bin/fceux-mcp -- --rom /absolute/path/to/your.nes
```

**Via `.mcp.json` at the root of a project** — scopes the server to that project:

```json
{
  "mcpServers": {
    "fceux": {
      "command": "/absolute/path/to/fceux-mcp/.venv/bin/fceux-mcp"
    }
  }
}
```

Add `"args": ["--rom", "/absolute/path/to/your.nes"]` to pin a starter ROM.

After either, restart `claude` (or run `/mcp` inside a session) and the 26 fceux tools should appear.

## Notes

- Verified on macOS 15 / Apple Silicon with FCEUX 2.6.6 from Homebrew and Python 3.13.
- Verified on Windows 11 (build 26200) with FCEUX 2.6.6, the win32 and the win64 build: TASVideos movie 3728 (67,117 frames) played through `emu.step` with `steps` gives the same RAM as FCEUX's own playback after every call; a savestate file loads the same RAM after FCEUX was closed and started again; savestate slots, `emu.loadrom` (a missing file refused, no dialog), `emu.reload`, `gui.screenshot`, `gui.screen`, `gui.text`/`gui.box`/`gui.pixel` on screen, several clients at once, a client dropped in the middle of a step, the window responding after 60 s paused, closing the window, and `emu.exit`; the sound against FCEUX's own playback (see [ARCHITECTURE](./docs/ARCHITECTURE.md)); and the MCP server on Windows (Python 3.12.14) spawning both builds and closing it with `emu.exit`. Not yet verified: the new pausing on the macOS/Linux (Qt) build.
