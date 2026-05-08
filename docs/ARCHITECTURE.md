# Architecture

This document describes how `bridge.lua` is loaded into FCEUX, how it exposes FCEUX's Lua API over TCP, and how the MCP server talks to it. Design rationale lives in [`CONCEPT.md`](./CONCEPT.md); the wrapped Lua surface is in [`FLUA-FUNCTIONS.md`](./FLUA-FUNCTIONS.md).

## Process model

```
MCP client (Claude, etc.)
        │  MCP (JSON-RPC over stdio)
        ▼
   MCP server  ───── TCP (loopback, line-framed JSON) ─────►  FCEUX
   (this repo)                                               + bridge.lua
                                                             + vendor/luasocket
```

Two processes. They are independent — FCEUX can be launched first and the MCP server later, or vice versa, as long as they agree on a port.

## Launch

```sh
fceux --loadlua bridge.lua <rom>
```

FCEUX boots, loads the ROM, and hands `bridge.lua` to its statically-linked Lua 5.1 interpreter. From that point on, `bridge.lua` runs inside FCEUX's Lua VM with full access to `emu.*`, `memory.*`, `joypad.*`, `gui.*`, etc.

## Loading LuaSocket from `vendor/`

FCEUX's embedded Lua does not ship LuaSocket. We bundle pre-built LuaSocket binaries under `vendor/luasocket/<platform>/` (see [`vendor/luasocket/README.md`](../vendor/luasocket/README.md)) and load them at script startup.

### Step 1 — extend Lua's module search paths

Before any `require`, `bridge.lua` prepends the vendor location to two globals:

- `package.cpath` — where Lua looks for **C extension modules** (`.so` files)
- `package.path` — where Lua looks for **pure-Lua modules** (`.lua` files)

```lua
local here   = debug.getinfo(1, "S").source:match("@(.*/)")
local VENDOR = here .. "vendor/luasocket/macos-arm64"

package.cpath = VENDOR .. "/lib/lua/5.1/?.so;"
             .. VENDOR .. "/lib/lua/5.1/?/core.so;"
             .. package.cpath

package.path  = VENDOR .. "/share/lua/5.1/?.lua;"
             .. VENDOR .. "/share/lua/5.1/?/init.lua;"
             .. package.path
```

The `?` is Lua's path placeholder — it is replaced by the dotted module name with `.` → `/`.

### Step 2 — `require("socket")` walks the tree

```lua
local socket = require("socket")
```

What Lua does:

1. Looks in `package.path` for `socket` → finds `vendor/luasocket/macos-arm64/share/lua/5.1/socket.lua`. Loads and runs it.
2. `socket.lua` requires `socket.core`.
3. For `socket.core`, Lua looks in `package.cpath` and finds `lib/lua/5.1/socket/core.so` (because `?/core.so` matches `socket/core.so`). Calls `dlopen` on it.
4. Lua then calls `luaopen_socket_core` from the freshly opened `.so`. That C function registers all the actual socket functions (`bind`, `connect`, `tcp`, …) into FCEUX's Lua state.
5. `socket.lua` finishes wiring things up and returns the table.

`socket/http.lua`, `socket/url.lua`, `mime`, `ltn12`, etc. are bundled but only loaded if something `require`s them — for the TCP bridge we only need `socket.core` and `socket.lua`.

### Step 3 — why the `.so` binds to FCEUX's Lua

Subtle but important: our vendored `core.so` was compiled against headers from the Lua 5.1.5 source tarball, but at runtime it has to use FCEUX's *statically-linked* Lua. This works because:

- On macOS, Lua C modules are linked with `-undefined dynamic_lookup` (visible in our build log: `gcc … -bundle -undefined dynamic_lookup -osocket-3.0.0.so`).
- That flag tells the linker: "don't resolve `lua_pushstring`, `lua_gettop`, etc. at link time — leave them undefined".
- When FCEUX `dlopen`s the bundle, those undefined symbols get bound against whatever Lua symbols already exist in the host process — which is FCEUX's static Lua.

So the headers we built against just defined the C-API contract; the actual implementation comes from FCEUX. As long as both sides are Lua 5.1.x (the C-API is stable across patch releases), it works.

LuaSocket reference: <https://lunarmodules.github.io/luasocket/reference.html>.

## Frame loop and TCP server

`bridge.lua` follows the standard FCEUX scripting idiom:

```lua
while true do
  pump_socket()      -- accept new clients, drain pending requests, send replies
  emu.frameadvance() -- yield to FCEUX for one frame
end
```

`emu.frameadvance` blocks until FCEUX has rendered the next frame (~16.6 ms at NTSC 60 Hz), giving the bridge a natural tick. `pump_socket()` is non-blocking — it polls the listening socket for new clients and drains whatever bytes are already in each client's receive buffer.

Trade-offs of this design:

- **Latency.** A request arriving just after `emu.frameadvance` returns will be processed immediately; one arriving just before will wait up to one frame. Worst case: ~16 ms.
- **Throughput.** Many requests can be processed per frame (the pump drains everything available), so batching is cheap.
- **Backpressure.** If the agent sends faster than one frame can drain, requests queue in the OS socket buffer. That's fine for typical tool-call rates.

## Wire protocol

**Line-framed JSON**, one message per line, both directions. Chosen for v1 because it's trivial to test by hand with `nc`. We can upgrade to length-prefix framing later without changing the message shape.

### Request

```json
{"id": 1, "method": "memory.readbyte", "params": {"address": 0x100}}
```

- `id` — opaque; echoed back in the response. Lets clients pipeline requests.
- `method` — dotted name like `emu.framecount`, `memory.readbyte`, `joypad.set`.
- `params` — object; per-method.

### Response (success)

```json
{"id": 1, "result": 42}
```

### Response (error)

```json
{"id": 1, "error": {"code": "method_not_found", "message": "no handler for 'memory.foo'"}}
```

Error codes:

| Code | Meaning | Source |
| --- | --- | --- |
| `parse_error` | Bridge couldn't parse the request line | bridge.lua |
| `method_not_found` | Unknown method | bridge.lua |
| `invalid_params` | Handler validation failure (raise via `bad_params(msg)`) | bridge.lua |
| `lua_error` | Unexpected Lua runtime error in a handler (`error("…")` or panic). The `file:line:` prefix is stripped before sending. | bridge.lua |
| `bridge_unreachable` | Transport failure — never sent over the wire; raised by the Python `BridgeClient` when connect / send / recv fails | server |

Server-side, `BridgeError` carries `code` and `message` attributes; `BridgeUnreachable` is a subclass for transport failures so callers can distinguish "FCEUX is gone" from "I sent bad input."

## Dispatch

`bridge.lua` holds a flat table of handlers keyed by method name. Each handler takes `params` (a Lua table) and returns either a result value or raises an error via `error(msg)`. The pump catches errors with `pcall` and converts them to the error response shape.

Initial handler set (v1):

**Core / timeline**

| Method | Description |
| --- | --- |
| `ping` | Smoke test; returns `"pong"` |
| `emu.framecount` | Current frame number |
| `emu.step` (`frames=1`) | Synchronously advance N frames; returns the new framecount |
| `emu.pause` / `emu.unpause` / `emu.paused` | Bridge-level pause flag (paused by default) |
| `emu.message` | Show a message in FCEUX's overlay |
| `emu.poweron` | Hard reset (NES power cycle) |
| `emu.softreset` | Soft reset |
| `emu.loadrom` (`filename`) | Switch ROMs mid-session; returns the loaded `{filename, framecount}` |

**Memory**

| Method | Description |
| --- | --- |
| `memory.readbyte` | Read one byte from CPU RAM |
| `memory.readbyterange` | Read N bytes; returned as a numeric array |
| `memory.readword` | 16-bit read; one-arg = little-endian @ addr / addr+1; two-arg = low @ `address`, high @ `address_high` |
| `memory.writebyte` | Write one byte |
| `memory.getregister` | Read a 6502 register: `a`, `x`, `y`, `s`, `p`, `pc` |

**Input**

| Method | Description |
| --- | --- |
| `joypad.get` | Read controller state for a player |
| `joypad.set` | Force controller state for a player |

**Savestates**

| Method | Description |
| --- | --- |
| `savestate.save` (`slot?`) | Save current state. With slot=1-10 → reusable session slot. Without slot → single-use anonymous state |
| `savestate.load` (`slot?`) | Restore. Slots are reusable; anonymous is consumed on load |

**Visuals**

| Method | Description |
| --- | --- |
| `gui.screenshot` (`path?`) | Write the emulated screen as PNG; returns `{path, framecount}`. Advances 1 frame as a side effect (see gotchas) |
| `gui.text` (`x, y, text, color?`) | Draw text on overlay. One-shot per call; FCEUX clears between frames |
| `gui.box` (`x1, y1, x2, y2, fillcolor?, outlinecolor?`) | Draw a rectangle. One-shot |
| `gui.pixel` (`x, y, color?`) | Draw one pixel. One-shot |

**ROM**

| Method | Description |
| --- | --- |
| `rom.getfilename` | Base filename of the loaded ROM |
| `rom.gethash` (`type=md5\|base64`) | Hash of the loaded ROM |

**Escape hatch**

| Method | Description |
| --- | --- |
| `lua.exec` (`code`) | Run an arbitrary Lua chunk inside FCEUX. The full FCEUX Lua API is in scope; `return EXPR` sends a value back. Use for batched reads, ad-hoc queries, and APIs not yet wrapped as typed handlers. `emu.frameadvance` is shadowed (would corrupt FCEUX state inside our pcall — see gotchas) — use `emu.step` for frames |

The bridge starts **paused** so an LLM agent owns the timeline; frames only tick when the agent calls `emu.step`. Switch to real-time mode with `emu.unpause` (frames tick at NTSC ~60 Hz from the bridge's main loop).

Adding a new method is a one-line entry in the dispatch table — see `bridge.lua`.

## FCEUX-specific quirks (gotchas we hit during bring-up)

- **Non-standard `tostring`.** FCEUX 2.6.6's embedded Lua has a `tostring` that stringifies *all* its arguments and concatenates them, like `print` does — `tostring(true, {a=1}) -> "true {a=1}"`. Standard Lua 5.1 ignores extra args. rxi/json originally mapped `boolean` directly to the global `tostring`, so the encoder's internal `stack` table leaked into encoded output. The vendored copy in `vendor/json/json.lua` patches this with a one-arg wrapper; comment in the file marks the change.
- **`emu.pause()` blocks the frame loop.** Once FCEUX is paused, `emu.frameadvance()` blocks indefinitely waiting for the next frame, so the bridge's `pump()` would never run again — including `emu.unpause`. To avoid that, `bridge.lua` does **not** call FCEUX's `emu.pause()`. Instead, the `emu.pause` / `emu.unpause` / `emu.paused` handlers manipulate a bridge-local `paused` flag that suppresses `emu.frameadvance()` in the main loop. The agent gets the same observable effect (no frames advance) and the bridge stays responsive.
- **First `emu.frameadvance` after script load is a warm-up.** Under FCEUX 2.6.6, the very first `emu.frameadvance()` a script runs yields control but does not bump `emu.framecount()`. Subsequent calls increment normally. `bridge.lua` calls `emu.frameadvance()` once at startup before entering the main loop so the first agent-driven `emu.step` doesn't see an off-by-one.
- **Lua 5.1 cannot yield across `pcall`.** `emu.frameadvance` yields under the hood, and Lua 5.1's `pcall` blocks coroutine yielding (`attempt to yield across metamethod/C-call boundary`). The dispatcher therefore runs handlers that call `emu.frameadvance` (currently `emu.step` and `gui.screenshot`) *unprotected*. The `YIELDING_METHODS` set in `bridge.lua` lists them; their handlers must be written so they do not error in normal operation.
- **`gui.savescreenshotas` is deferred.** Calling it queues the PNG write for the next frame render; if the bridge stays paused, the file is never written. `gui.screenshot` therefore advances exactly one frame after `savescreenshotas` to flush the write, and returns the post-advance framecount alongside the path so the agent knows what frame was captured.
- **`savestate.persist` crashes the embedded Lua.** The docs say it makes a state survive across loads, but calling it under FCEUX 2.6.6 takes the bridge down. The savestate handlers therefore don't call it — anonymous saves end up single-use (FCEUX deletes the state on load), and slots stay in-memory rather than being written to disk.
- **`savestate.object(N)` returns a fresh handle each call.** A save through one handle and a load through another (even for the same slot N) operate on different objects — the load sees no state. The handlers cache one savestate object per slot for the script's lifetime so save and load see the same handle, which makes slots 1-10 reusable across many save/load cycles within a session.
- **An *attempted* yield across pcall corrupts FCEUX's frame loop.** Calling `emu.frameadvance` from inside a pcall'd handler not only fails with `attempt to yield across metamethod/C-call boundary` (expected for Lua 5.1), but also leaves FCEUX in a state where subsequent `emu.frameadvance` calls hang indefinitely. The dispatcher therefore runs handlers that legitimately need to yield (`emu.step`, `gui.screenshot`) outside pcall via `YIELDING_METHODS`. For `lua.exec`, which runs *inside* pcall and lets the agent write arbitrary code, we shadow `emu.frameadvance` in a sandboxed environment so it errors *before* any yield is attempted — keeping FCEUX healthy.

The Python server side has its own response-encode hardening: the bridge now wraps `json.encode(resp)` in pcall and falls back to a `lua_error` response if a handler ever returns something non-JSON-serializable (e.g. a userdata leaked from a `lua.exec` chunk). Without this, the encode would throw out of the main loop and crash the bridge.

## Limitations / future work

- **Length-prefix framing.** Line-framed is fine while everything is small; binary payloads (e.g. screen captures) want length-prefix. Easy upgrade.
- **Async / streaming responses.** Today it's strict request → response. Memory-watch hooks and frame-by-frame screen feeds will need server-pushed messages.
- **Cross-platform vendor builds.** Only `macos-arm64` LuaSocket is shipped. Linux and Windows artifacts are not yet built.
- **Hot reload.** No way to restart `bridge.lua` without restarting FCEUX. Not a v1 concern.
