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

- **Server language.** TypeScript (matches most MCP examples), Python (easier to ship a Lua bridge alongside), or Rust (one static binary)?
- **Frame-stepping semantics.** Does `frameadvance` block until the frame completes, or fire-and-forget with a separate "wait for frame N" tool? Affects how agents reason about timing.
- **Screen capture format.** Return raw RGB bytes, base64 PNG, or a path to a saved file? PNG is friendlier to LLM clients but costs a conversion step.
- **Lifecycle.** Who launches FCEUX — the MCP server (spawn as subprocess) or the user (server attaches to a running instance)?
- **Error model.** Lua errors inside FCEUX need to surface as structured MCP tool errors, not silent failures.
