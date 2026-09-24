# FCEUX MCP Server — Concept

## Goal

Expose FCEUX's Lua scripting API as MCP tools, so an LLM agent can drive an NES emulator: read memory, send controller input, advance frames, manage savestates, capture the screen, and draw overlays.

The Lua surface we are wrapping is documented in [FLUA-FUNCTIONS.md](./FLUA-FUNCTIONS.md).

## Motivation

FCEUX already has a rich Lua API designed for bots, TAS work, and game analysis. What it lacks is a way for an external agent (LLM, scripted client, another tool) to call that API over a structured protocol. MCP fills that gap: any MCP-aware client can then control FCEUX without writing Lua by hand.

Concrete use cases:

- LLM agents that play NES games turn-by-turn (read RAM → decide → send input → advance frame).
- Automated reverse engineering of NES ROMs (memory watches, execute hooks, register inspection).
- AI-assisted TAS authoring and replay.
- Live debugging sessions where the agent narrates / annotates what the game is doing.

## Architecture

FCEUX does not expose a network API directly — Lua scripts run *inside* the emulator. So the system is two processes connected by a bridge:

```
MCP client (Claude, etc.)
        │  MCP (JSON-RPC over stdio)
        ▼
   MCP server  ───── TCP (loopback, JSON frames) ─────►  FCEUX
   (this repo)                                          + bridge.lua
```

- **`bridge.lua`** runs inside FCEUX. It registers a per-frame callback, accepts a TCP connection on loopback via [LuaSocket](https://lunarmodules.github.io/luasocket/), dispatches incoming commands to the appropriate `emu.*` / `memory.*` / `joypad.*` / etc. function, and returns results.
- **MCP server** (this repo) speaks MCP to the client and translates each tool call into a TCP request to `bridge.lua`.

### Bridge transport — decided: TCP via LuaSocket

Verified end-to-end on macOS / Apple Silicon with FCEUX 2.6.6 from Homebrew: FCEUX's embedded Lua 5.1 loads a locally-built `socket/core.so` (built via the steps in the [README](../README.md)), binds a loopback port, and round-trips JSON frames with an external client. macOS's `-undefined dynamic_lookup` linker behavior makes the LuaSocket C module bind `lua_*` symbols against FCEUX's static Lua at load time, so an ABI mismatch with the Lua 5.1 used to compile LuaSocket is not an issue.

Wire format: length-prefixed JSON messages — 4-byte big-endian length followed by a UTF-8 JSON object. Each request carries an `id`, a `method` (e.g. `"memory.readbyte"`), and `params`; each response echoes the `id` and carries either `result` or `error`.

Alternatives considered and rejected: stdio piping (FCEUX is GUI-only, no inherited stdio for Lua), named pipes (OS-specific, awkward on Windows), file polling (no install but adds at least one frame of latency per call). File polling stays viable as a documented fallback for builds where LuaSocket cannot be loaded.

### Server language — decided: Python

The MCP server is glue: receive an MCP tool call, forward a JSON line over TCP to `bridge.lua`, return the response. Python with the official [`mcp`](https://pypi.org/project/mcp/) SDK keeps that to a small file with no build step, and Python is already required for the bridge smoke tests so contributors don't pick up a new language just to run things.

Alternatives considered: TypeScript with `@modelcontextprotocol/sdk` has more public MCP server examples, but that gap doesn't matter for a project this small; Rust would be over-engineered for thin TCP plumbing. Both remain viable rewrites if the server ever grows beyond glue.

### Frame-stepping semantics — decided: paused by default + `emu.step(n)`

LLMs can't reason at 60 Hz, so a continuously-ticking emulator forces the agent into races between "set joypad" and "frame consumes input," and means every memory read is slightly stale. The bridge therefore starts paused and only advances frames when the agent asks.

Tools:

- `emu.step(frames=1)` — advances exactly N frames, then returns the new framecount. Synchronous: the response is only sent after the frames are emulated, so a follow-up `memory.readbyte` reads the post-step state.
- `emu.step(steps=[{buttons, frames, reset}])` — the same, holding each step's buttons for its frames. `joypad.set` applies to the next frame only, so holding a button through a multi-frame `emu.step(frames=N)` is not possible; with `steps` the bridge sets all eight buttons on every frame. Measured on Windows: a published FM2 movie (TASVideos #3728, 67,117 frames) played through `steps` of up to 600 frames matches FCEUX's own playback of it on every checked frame.
- `emu.pause` / `emu.unpause` / `emu.paused` — FCEUX's own pause. `unpause` switches into real-time mode (NTSC ~60 Hz) for cases like recording a demo or watching a run. `pause` returns to step-only.

Alternative considered and rejected: an `advance_until(condition)` tool that resolves when a memory address matches a value. Expressive but defers logic to the bridge that's better expressed as a step-and-poll loop on the agent side; revisit if a real workload needs it.

### Screen capture format — decided: PNG via temp file path

The bridge calls `gui.savescreenshotas` with a default path under the platform tmp dir — `/tmp/fceux-mcp-cap.png` on macOS/Linux, `%TEMP%\fceux-mcp-cap.png` on Windows — and returns the resolved path. Per-request override available via `params.path`. The MCP server reads the file and forwards the bytes as an MCP image content block to the client. FCEUX's PNG encoder handles compression, so the payload is small (typical NES frame compresses to under 10 KB) and the bridge handler stays trivial.

Alternatives considered: inline raw RGBA via `gui.gdscreenshot` (no disk I/O but ~330 KB base64 payload per frame and adds a Pillow dependency); inline PNG bytes read back by the bridge (small payload, but bridge has to do file I/O and base64 in Lua, more moving parts). The temp-file approach keeps the bridge simple and lets the MCP server own all binary handling.

### Lifecycle — decided: server-launched, with attach-if-running fallback

Because the agent owns the timeline (paused-by-default + `emu.step`), the user has very little to do with the emulator's day-to-day operation — they're an observer of the FCEUX window, not a co-driver. So the MCP server owns FCEUX's process lifecycle:

- On startup, the server probes the bridge port. If something is already listening (dev/debug case), it just attaches.
- Otherwise the server spawns `fceux --loadlua bridge.lua <rom>` (on Windows `fceux.exe -lua <absolute path to bridge.lua> <rom>`; `--fceux` names the executable) as a subprocess, polls the port until the bridge is listening (with a timeout), and then announces tools as available.
- ROM path comes from server config (Claude Desktop JSON / CLI flag / env var). Mid-session ROM switching is supported later via an `emu.loadrom` tool that wraps FCEUX's `emu.loadrom`.
- On server shutdown the server asks the spawned FCEUX to close itself (`emu.exit`), and terminates it only if it is still running 5 s later. If FCEUX crashes, the server respawns on the next tool call.

Alternative considered: user-launched (server only attaches). Cleaner separation of GUI lifecycle but two-step setup, and forces the user to manage a process they otherwise don't interact with much. Kept as a fallback (server attaches if a bridge is already up).

### Error model — decided: typed codes end-to-end

Bridge responses are either `{id, result}` or `{id, error: {code, message}}`. The codes are a fixed taxonomy that the Python server preserves and surfaces to the MCP client:

| Code | Meaning | Source |
| --- | --- | --- |
| `parse_error` | Bridge couldn't parse the JSON request | bridge.lua |
| `method_not_found` | Unknown method name | bridge.lua |
| `invalid_params` | Handler-level validation failure (wrong type, missing field, …) | bridge.lua |
| `lua_error` | Unexpected Lua-runtime failure inside a handler | bridge.lua |
| `bridge_unreachable` | TCP connect / send / recv failed (FCEUX gone, port closed, …) | server |

Bridge handlers raise `invalid_params` via a small `bad_params(msg)` helper that throws a typed table; the dispatcher recognizes the shape and emits the right code. Plain `error("…")` (or runtime panics) get wrapped as `lua_error` with the `file:line:` prefix stripped from the message so the client sees clean text. Transport failures from the server side raise `BridgeUnreachable` so the agent / user can distinguish "FCEUX crashed" from "I sent bad input."

## Tool surface (initial scope)

Wrap the most useful Lua libraries first; defer the rest until there's a real need.

**In scope for v1:**

- `emu` — `frameadvance`, `pause`, `unpause`, `framecount`, `message`, `loadrom`, `poweron`, `softreset`, `getscreenpixel`
- `memory` — `readbyte`, `readbyterange`, `readword`, `writebyte`, `getregister`
- `joypad` — `get`, `set`
- `savestate` — `object`, `save`, `load`, `persist`
- `gui` — `text`, `box`, `pixel`, `gdscreenshot` (for returning the framebuffer to the agent)
- `rom` — `getfilename`, `gethash`

**Deferred:**

- `memory.register*` execution/read/write hooks (need a callback story across the bridge)
- `ppu.*`, `debugger.*`, `sound.*` (niche; add when asked)
- `taseditor.*`, `movie.*` (large surface; treat as separate milestone)
- `zapper.*`, `input.*` keyboard/mouse polling

## Session model

Two interaction styles to consider:

1. **Long-lived session.** Client connects, ROM is loaded once, agent issues many tool calls over the session's lifetime. Best for interactive play / debugging.
2. **One-shot.** Each MCP call boots FCEUX, runs a script, returns a result. Simpler but throws away emulator state between calls.

v1 should target the long-lived session — it's what makes "play this game" feasible — but the bridge protocol should not preclude one-shot use later.

## Open questions

### Pausing: FCEUX's own pause, requests read from `gui.register`?

Between requests FCEUX itself is paused, and the bridge reads its socket from a `gui.register` callback, which FCEUX runs on every pass of its main loop, paused or not. A request that runs frames unpauses FCEUX for exactly those frames. See ARCHITECTURE.md, "Frame loop and TCP server".

The current design, which this would replace: a bridge-local pause flag with a main loop that polls the socket and sleeps without yielding. It never hands control back to FCEUX while paused, so FCEUX pumps no window messages: on Windows the window stops redrawing, is marked "Not Responding" after 5 s, and cannot be closed until the script yields.

Open because it reverses the gotcha that `emu.pause()` blocks the frame loop entirely, including the pump (CLAUDE.md): with the pump in a `gui.register` callback, FCEUX's own pause no longer blocks it. Measured only on Windows (FCEUX 2.6.6 win32 and win64); not yet tried on macOS, where it needs FCEUX's Qt build to run the callback while paused.

### Transport: files where LuaSocket cannot load?

FCEUX's win64-QtSDL build ships no LuaSocket, and no C module can be added to it: Lua is compiled into `qfceux.exe` without its C API exported, and LuaSocket linked against a separate Lua DLL runs a second Lua on FCEUX's state (a heap corruption, measured). The proposal: when `require("socket")` fails, `bridge.lua` talks through files in a folder (`FCEUX_BRIDGE_DIR`, or `ipc` next to `bridge.lua`), with the same JSON lines. A client claims one of eight slots with a token of its own; requests and replies are numbered files, each written under another name and renamed. It uses only Lua's own `io`, so it needs no vendoring; `fceux-mcp` uses it by itself for `qfceux.exe`, or with `--bridge-dir`. See ARCHITECTURE.md, "File transport".

Open because it is a second transport beside "Bridge transport — decided: TCP via LuaSocket". Alternatives looked at: a named pipe through `io.open` (a read blocks FCEUX until a request arrives), and LuaSocket built for Windows (the heap corruption above). Measured on Windows only, with the win64-QtSDL build: TASVideos movie 3728 in sync, a median of 33 ms per request from WSL.
