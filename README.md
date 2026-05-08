# fceux-mcp

An MCP server that exposes the [FCEUX](https://fceux.com/) NES emulator's Lua API as MCP tools, so an LLM agent can read memory, send controller input, advance frames, manage savestates, and capture the screen.

See [`docs/CONCEPT.md`](./docs/CONCEPT.md) for the design. The Lua surface being wrapped is documented in [`docs/FLUA-FUNCTIONS.md`](./docs/FLUA-FUNCTIONS.md).

## How it works

FCEUX is launched with `fceux --loadlua bridge.lua <rom>`. The bridge script runs inside FCEUX's embedded Lua 5.1 interpreter, loads [LuaSocket](https://lunarmodules.github.io/luasocket/) from `vendor/`, opens a loopback TCP port, and dispatches incoming JSON commands to FCEUX's `emu.*` / `memory.*` / `joypad.*` libraries.

The MCP server is a separate process: it speaks MCP to the client and TCP to `bridge.lua`.

LuaSocket isn't part of FCEUX's Lua, so pre-built binaries are vendored under `vendor/luasocket/<platform>/` and `bridge.lua` adds them to `package.cpath` at startup.

## Prerequisites

### macOS (Apple Silicon)

```sh
brew install fceux
```

The repo ships pre-built LuaSocket for `macos-arm64` under [`vendor/luasocket/macos-arm64/`](./vendor/luasocket/), so no compile step is needed.

### Other platforms

`vendor/luasocket/` currently only contains `macos-arm64` artifacts. For macOS Intel, Linux, or Windows, build LuaSocket for that platform and drop the files into `vendor/luasocket/<platform>/`. The build recipe is in [`vendor/luasocket/README.md`](./vendor/luasocket/README.md).

## Notes

- Verified on macOS 15 / Apple Silicon with FCEUX 2.6.6 from Homebrew.
