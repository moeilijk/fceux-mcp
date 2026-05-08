# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Read these first

- [`docs/CONCEPT.md`](docs/CONCEPT.md) — design, resolved open questions, and rationale for every load-bearing decision (transport, lifecycle, error model, frame stepping, screen capture).
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — the moving parts, full handler table, wire protocol, and (critically) the **FCEUX 2.6.6 / Lua 5.1 quirks the bridge works around**. Read the gotchas section before touching `bridge.lua`.
- [`docs/FLUA-FUNCTIONS.md`](docs/FLUA-FUNCTIONS.md) — the FCEUX Lua API surface this project wraps.

## Running things

All commands assume the repo root.

```sh
# Set up Python env (one time)
python3 -m venv .venv && .venv/bin/pip install -e .

# Run the MCP server (spawns FCEUX with the bridge)
.venv/bin/fceux-mcp --rom /path/to/some.nes

# Run the bridge alone for debugging (server will attach instead of spawning)
fceux --loadlua bridge.lua /path/to/some.nes
```

There is no automated test suite yet. End-to-end smoke tests are written ad-hoc as Python scripts in `/tmp/test-*.py` during development; the pattern is `spawn_fceux → wait_for_port → BridgeClient(...).call(...)` (all importable from `fceux_mcp.__main__`). The known test ROM used during bring-up is `/Users/ingvar/private/nes-test1/controller-test/controller-test.nes`.

## High-level architecture

Three processes:

```
MCP client  ──MCP/stdio──▶  Python server  ──TCP/JSON-lines──▶  FCEUX + bridge.lua
```

- **`bridge.lua`** runs *inside* FCEUX's embedded Lua 5.1 (loaded via `fceux --loadlua`). It dispatches JSON requests to FCEUX's `emu.*` / `memory.*` / `joypad.*` / `gui.*` libraries. Loads vendored LuaSocket from `vendor/luasocket/<platform>/` to get TCP support.
- **`fceux_mcp/__main__.py`** is a single-file Python server using the official `mcp` SDK's FastMCP. On startup it probes the bridge port: if listening, attaches; otherwise spawns FCEUX. Owns the FCEUX subprocess lifecycle.
- **`vendor/`** is intentionally checked in — pre-built LuaSocket binaries and `rxi/json.lua`. Don't add system-level dependencies that the user has to install separately; vendor them.

## Adding a new bridge handler

The pattern, end-to-end:

1. **Lua side (`bridge.lua`)** — add `handlers["foo.bar"] = function(p) ... end`. Validate inputs with the `bad_params(msg)` helper; it throws a typed table that `dispatch` turns into an `invalid_params` error response. Plain `error("…")` becomes `lua_error`.
2. **Yielding handlers go in `YIELDING_METHODS`.** If your handler calls `emu.frameadvance` (directly or transitively), add the method name to that set so `dispatch` skips `pcall` for it. **Lua 5.1 cannot yield across `pcall` and an attempted-and-failed yield corrupts FCEUX's frame loop** (see ARCHITECTURE.md gotchas) — this is non-negotiable. Handlers in `YIELDING_METHODS` run unprotected; they must be written so they never error in normal operation.
3. **Python side (`fceux_mcp/__main__.py`)** — add a thin `@mcp.tool()` wrapper inside `build_server` that calls `client.call("foo.bar", params)`. Use Python type hints; FastMCP turns them into the tool's JSON schema. The docstring becomes the tool description visible to the agent — make it good.
4. **Update [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)**'s handler table.

## Gotchas you'll hit (full list in ARCHITECTURE.md)

These are real, not theoretical — every one cost a debugging round during bring-up. The short version:

- FCEUX's `tostring` is non-standard — concatenates *all* arguments. `vendor/json/json.lua` is patched to wrap booleans in a 1-arg shim.
- FCEUX's `emu.pause()` blocks the frame loop entirely, including our pump. The `emu.pause`/`unpause` handlers manipulate a bridge-local flag instead.
- The first `emu.frameadvance` after script load is a yield-only warm-up that doesn't increment `framecount`. The bridge primes once before the main loop.
- `gui.savescreenshotas` is deferred until the next frame render. `gui.screenshot` advances one frame to flush.
- `savestate.persist` crashes the embedded Lua and `savestate.object(N)` returns a fresh handle each call. The handlers cache a single object per slot for the script's lifetime.
- An *attempted* yield across pcall corrupts FCEUX's frame loop (subsequent `emu.frameadvance` calls hang). `lua.exec` shadows `emu.frameadvance` in a sandboxed environment via `setfenv` so the agent's code errors *before* any yield is attempted.

## Conventions

- **No Python type stubs / mypy / linter** configured. Plain Python 3.10+ with simple type hints for FastMCP's schema generation.
- **Don't add backwards-compatibility shims** for the JSON wire format yet — there's only one server and one bridge, version them together.
- **Don't add new system dependencies** lightly. The vendoring story is deliberate (see CONCEPT.md "Bridge transport"). New deps need a vendoring story for macOS / Linux / Windows.
- **`docs/CONCEPT.md`'s "Open questions" section is authoritative.** When a new design tension comes up, add it there first; resolve in conversation; then move it to a "decided" subsection with the rationale. Don't quietly bake decisions into code.
