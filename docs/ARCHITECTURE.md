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
fceux --loadlua bridge.lua <rom>                          # SDL/Qt builds (macOS, Linux)
fceux.exe -lua C:\full\path\to\bridge.lua <rom>          # Windows build
```

The Windows build has no `--loadlua`; its option is `-lua <script>` (src/drivers/win/args.cpp), and every option takes a value. The script path should be absolute: FCEUX changes into the script's folder when it loads it.

FCEUX boots, loads the ROM, and hands `bridge.lua` to its statically-linked Lua 5.1 interpreter. From that point on, `bridge.lua` runs inside FCEUX's Lua VM with full access to `emu.*`, `memory.*`, `joypad.*`, `gui.*`, etc.

## Loading LuaSocket from `vendor/`

On Windows nothing is loaded from `vendor/`: the Windows build of FCEUX has the C core of LuaSocket 2.0.2 built in (`package.preload["socket.core"]`, src/lua-engine.cpp), but not its Lua half (`socket.lua`), so `socket.bind` is missing. `bridge.lua` uses `require("socket.core")` there and rebuilds `bind` from the core's `tcp()`, `bind` and `listen`.

Elsewhere, FCEUX's embedded Lua does not ship LuaSocket. We bundle pre-built LuaSocket binaries under `vendor/luasocket/<platform>/` (see [`vendor/luasocket/README.md`](../vendor/luasocket/README.md)) and load them at script startup.

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

Between requests FCEUX itself is paused (`emu.pause()`), and requests are read from a `gui.register` callback:

```lua
gui.register(poll)   -- FCEUX calls it on every pass of its main loop, paused or not
emu.pause()
while true do        -- the main coroutine: runs only while FCEUX is unpaused
  if job queued then run(job) else emu.frameadvance() end
end
```

Why it works (FCEUX 2.6.6 source):

- While paused, FCEUX's main loop keeps calling `FCEUI_Emulate`, which draws the last frame through `FCEU_PutImage` → `FCEU_LuaGui` (fceu.cpp, video.cpp), and that runs the `gui.register` callback. On Windows the loop then pumps window messages and sleeps 50 ms (drivers/win/main.cpp); on Qt the emulator thread does the same through `fceuWrapperUpdate` → `DoFun`. So the window, sound and close keep working, and `poll()` runs about 20 times a second.
- A paused FCEUX does not resume the script's main coroutine: `FCEUI_Emulate` returns before `FCEU_LuaFrameBoundary`. A request that runs frames (a *job*: `emu.step`, `emu.loadrom`) therefore unpauses FCEUX, and the main coroutine runs it at the start of the next frame, before that frame's input is read, so a `joypad.set` there applies to that frame.
- A job calls `finish()` right before its last `emu.frameadvance`: that pauses FCEUX again (unless the agent chose real-time mode) and marks the job done. The frame is still emulated, and `poll()` sends the reply on its next pass. A job of N frames runs exactly N frames.
- `poll()` is non-blocking (the sockets have timeout 0) and never yields. It serves several clients at once, each with its own buffer (a host may play from one process and save states from another), and runs one job at a time: while a job runs, every client's next request waits in its buffer, and the job's reply goes to the client that asked. A client should keep its connection open: a new connection is accepted on one pass and its request read on the next, a pass of ~50 ms more per request while paused (measured on Windows: gaps in the sound of 66-91 ms per 60-frame call with a connection per call, 20-34 ms with one kept open).

Trade-offs of this design:

- **Latency.** While paused, a request waits up to one pass of FCEUX's loop, about 50 ms on Windows.
- **Throughput.** Requests that don't run frames are handled in the same pass, as many as are buffered.
- **Sound.** FCEUX makes sound only for emulated frames, so there can be a gap between two jobs. Measured on Windows with the win32 and the win64 build, against FCEUX's own playback of the same movie (OBS recording, gaps of 20 ms or more at -50 dB): steps of 600 frames give the same silences as FCEUX's own playback, with one extra gap of 64 ms in five steps on win64; steps of 60 frames a gap of 20–25 ms at about half of the steps; steps of 1 frame about 33 ms of silence after every step. The win64-QtSDL build, through the file transport: steps of 600 frames give no extra gap; steps of 60 frames a gap of 25–42 ms at 6 of 10 steps; steps of 1 frame give no sound at all, because the Qt build fades its sound to zero while paused and plays again only once its buffer is more than a quarter full (`fillaudio`, sdl-sound.cpp), which one frame between two pauses never fills. Batch input into long steps when sound matters.

## File transport (FCEUX's Qt build on Windows)

Every FCEUX build has Lua 5.1 compiled into its executable, and none exports Lua's C API (`fceux64.exe` exports only `luaopen_winapi`, `qfceux.exe` nothing). The win32 and win64 builds link LuaSocket 2.0.2 in with their other Lua extras (`luaperks.lib`, `vc/vc14_fceux.vcxproj`) and preload it (`package.preload["socket.core"]`, lua-engine.cpp, only in the Windows driver build); the win64-QtSDL build, built with CMake, has none of them. A C module such as LuaSocket cannot be added there: it needs Lua's C API from a DLL, and linked against a separate Lua DLL (the `lua5.1.dll` in the Qt zip, which `qfceux.exe` does not use) it runs a second Lua on FCEUX's state, and FCEUX ends with a heap corruption (0xc0000374, measured). `bridge.lua` therefore talks through files when LuaSocket cannot be loaded, with the same JSON lines:

- The folder is `FCEUX_BRIDGE_DIR`, or `ipc` next to `bridge.lua`; the client creates it.
- A client claims one of eight places by creating `client-<k>` exclusively, with a token of its own inside. The bridge reads the places every 30 passes (~0.5 s paused): a new token is a new client, a missing file a closed one. A place whose client has not touched it for 10 s is free for the next client.
- Requests go to `<token>-in-<n>`, replies come back in `<token>-out-<n>` (n = 1, 2, ...), each written under another name and then renamed, so a file that exists is complete. Checking whether a file exists does not block, so this runs in the same pass of FCEUX's loop as the TCP server.
- A client writes a batch as one file: FCEUX clears its drawing overlay at the first `gui.*` call of a pass after the previous drawing was shown (`gui_prepare`, lua-engine.cpp), so calls that land in different passes replace each other.
- Measured from WSL over `/mnt/c`: 200 requests in 6.5 s, a median of 33 ms per request; FCEUX runs the `gui.register` callback about 62 times a second while paused.

`fceux-mcp` uses files by itself when `--fceux` is `qfceux.exe` on Windows, or when `--bridge-dir` names the folder.

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
| `emu.step` (`frames=1`) | Synchronously advance N frames with whatever input is set; returns the new framecount |
| `emu.step` (`steps=[{buttons, frames, reset}]`) | Play each step's buttons for its frames: all eight buttons (`A`, `B`, `select`, `start`, `up`, `down`, `left`, `right`) are set on every frame, true when listed; `reset` gives a soft reset before the step's first frame, as an FM2 reset command. Returns the new framecount |
| `emu.pause` / `emu.unpause` / `emu.paused` | FCEUX's own pause. Paused by default: FCEUX pauses again after every job. `unpause` switches into real-time mode |
| `emu.exit` | Close FCEUX the way the user would (`emu.exit`, after the reply has gone out) |
| `emu.message` | Show a message in FCEUX's overlay |
| `emu.poweron` | Hard reset (NES power cycle) |
| `emu.softreset` | Soft reset |
| `emu.loadrom` (`filename`) | Switch ROMs mid-session; returns the loaded `{filename, framecount}`. In FCEUX's Windows build immediate, no frames; in the Qt build the emulator thread takes the load a frame or more later, so the job runs frames until the frame count starts again (at most 120; measured on win64-QtSDL). A file the bridge cannot open is refused with `invalid_params`: FCEUX's Windows build would show a modal error window and then reload its most recent ROM from power-on |
| `emu.reload` | Windows: the current ROM again, from power-on, through FCEUX's own ReloadRom. Unlike `emu.poweron` ("Power on" over the game) a load clears FCEUX's messages. No frames. The Qt build's `emu.loadrom` needs a file name, so there the bridge answers `invalid_params`; `fceux-mcp`'s `emu_reload` then loads the ROM it loaded last again |

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
| `savestate.savefile` (`path`) | Save the current state to a file (FCEUX's own savestate format), for a host that keeps a session's state between runs of FCEUX; returns `{path, framecount}` |
| `savestate.loadfile` (`path`) | Restore a state from such a file |

**Visuals**

| Method | Description |
| --- | --- |
| `gui.screenshot` (`path?`) | Write the emulated screen as PNG; returns `{path, framecount}`. Runs no frames (see gotchas). FCEUX shows "Snapshot Saved." over the game |
| `gui.screen` | The emulated screen before anything is drawn over it (FCEUX's messages, Lua overlays), from `gui.gdscreenshot(true)`: `{width, height, rgb}` with `rgb` as base64 (3 bytes a pixel). No file, no message, no frames |
| `gui.text` (`x, y, text, color?`) | Draw text on the overlay. It stays on screen while FCEUX is paused and is cleared after the next frame that runs (`FCEU_LuaGui`, lua-engine.cpp); a `gui.*` call in a later pass of FCEUX's loop replaces what was drawn before (`gui_prepare`), so send what belongs together in one batch. Measured on the win32, win64 and win64-QtSDL builds |
| `gui.box` (`x1, y1, x2, y2, fillcolor?, outlinecolor?`) | Draw a rectangle, kept like `gui.text` |
| `gui.pixel` (`x, y, color?`) | Draw one pixel, kept like `gui.text`; seen on screen on the win32 and win64 builds |

**ROM**

| Method | Description |
| --- | --- |
| `rom.getfilename` | Base filename of the loaded ROM |
| `rom.gethash` (`type=md5\|base64`) | Hash of the loaded ROM |

**Escape hatch**

| Method | Description |
| --- | --- |
| `lua.exec` (`code`) | Run an arbitrary Lua chunk inside FCEUX. The full FCEUX Lua API is in scope; `return EXPR` sends a value back. Use for batched reads, ad-hoc queries, and APIs not yet wrapped as typed handlers. `emu.frameadvance` is shadowed (would corrupt FCEUX state inside our pcall — see gotchas) — use `emu.step` for frames |

The bridge starts **paused** so an LLM agent owns the timeline; frames only tick when the agent calls `emu.step`. Switch to real-time mode with `emu.unpause` (FCEUX runs at NTSC ~60 Hz).

Methods can be switched off for a session with the environment variable `FCEUX_BRIDGE_DISABLE`, a comma-separated list of method names (e.g. `lua.exec,memory.writebyte`), for a host that hands the bridge to an agent that must not change the game. A disabled method answers `method_not_found`.

Adding a new method is a one-line entry in the dispatch table — see `bridge.lua`.

## FCEUX-specific quirks (gotchas we hit during bring-up)

- **Non-standard `tostring`.** FCEUX 2.6.6's embedded Lua has a `tostring` that stringifies *all* its arguments and concatenates them, like `print` does — `tostring(true, {a=1}) -> "true {a=1}"`. Standard Lua 5.1 ignores extra args. rxi/json originally mapped `boolean` directly to the global `tostring`, so the encoder's internal `stack` table leaked into encoded output. The vendored copy in `vendor/json/json.lua` patches this with a one-arg wrapper; comment in the file marks the change.
- **`emu.pause()` stops the main coroutine.** Once FCEUX is paused, a script waiting in `emu.frameadvance()` is not resumed until something unpauses FCEUX. A script that instead loops without yielding (socket poll + sleep) keeps FCEUX from pumping window messages: the window stops redrawing, Windows marks it "Not Responding" after 5 s, and closing it waits for the script. The bridge therefore polls from a `gui.register` callback, which FCEUX runs while paused (see "Frame loop and TCP server").
- **First `emu.frameadvance` after script load is a warm-up.** Under FCEUX 2.6.6, the very first `emu.frameadvance()` a script runs yields control but does not bump `emu.framecount()`. The main loop parks in it while FCEUX is paused, so the first job starts counting from frame 0 (measured: `emu.step` of 300 frames from power-on returns 300).
- **Lua 5.1 cannot yield across `pcall`.** `emu.frameadvance` yields under the hood, and Lua 5.1's `pcall` blocks coroutine yielding (`attempt to yield across metamethod/C-call boundary`). The frames of a job therefore run in the main coroutine, *unprotected*: a job's `check` (protected, in the callback) validates the params first, so its `run` does not error in normal operation.
- **`gui.savescreenshotas` is deferred.** Calling it queues the PNG write for the start of the next `FCEU_PutImage` (video.cpp), which also runs while paused. `gui.screenshot` therefore runs no frames: it asks for the file in one pass of the callback and replies on the next, after the file is written.
- **`savestate.persist` writes without a check.** `LuaSaveState::persist` (lua-engine.cpp) calls `fopen` and `fwrite` on the state's data without checking either, so it takes FCEUX down on a state that was never saved or a path that cannot be written. `savestate.savefile` therefore opens the path for writing first and always saves before it persists.
- **`savestate.persist` crashes the embedded Lua.** The docs say it makes a state survive across loads, but calling it under FCEUX 2.6.6 takes the bridge down. The savestate handlers therefore don't call it — anonymous saves end up single-use (FCEUX deletes the state on load), and slots stay in-memory rather than being written to disk.
- **`savestate.object(N)` returns a fresh handle each call.** A save through one handle and a load through another (even for the same slot N) operate on different objects — the load sees no state. The handlers cache one savestate object per slot for the script's lifetime so save and load see the same handle, which makes slots 1-10 reusable across many save/load cycles within a session.
- **An *attempted* yield across pcall corrupts FCEUX's frame loop.** Calling `emu.frameadvance` from inside a pcall'd handler not only fails with `attempt to yield across metamethod/C-call boundary` (expected for Lua 5.1), but also leaves FCEUX in a state where subsequent `emu.frameadvance` calls hang indefinitely. The frames of `emu.step` and `emu.loadrom` therefore run in the main coroutine, outside any pcall. For `lua.exec`, which runs *inside* pcall and lets the agent write arbitrary code, we shadow `emu.frameadvance` in a sandboxed environment so it errors *before* any yield is attempted — keeping FCEUX healthy.
- **`emu.loadrom` is deferred on the Qt build AND can't recover from a no-ROM state.** Two related quirks: (1) on the Qt build (macOS, Linux) `emu.loadrom` queues the swap for the next frame render (`LoadGameFromLua`), so a follow-up `rom.getfilename` would still see the old ROM unless we advance a frame first — the job does that there. On Windows `emu.loadrom` calls `ALoad` directly and the swap is done when it returns (lua-engine.cpp), so no frame is run. (2) `emu.loadrom` invoked when **no** ROM was loaded at startup crashes the FCEUX process entirely; spawning FCEUX bare with `--loadlua` works, but the agent can never recover because any loadrom kills the emulator. The Python server therefore always launches FCEUX with *something* loaded — either the user-supplied `--rom` or a bundled minimal NES ROM (`fceux_mcp/data/dummy.nes`); the agent's first `emu_loadrom` then transitions cleanly between two loaded ROMs.

The Python server side has its own response-encode hardening: the bridge now wraps `json.encode(resp)` in pcall and falls back to a `lua_error` response if a handler ever returns something non-JSON-serializable (e.g. a userdata leaked from a `lua.exec` chunk). Without this, the encode would throw out of the main loop and crash the bridge.

## Limitations / future work

- **Length-prefix framing.** Line-framed is fine while everything is small; binary payloads (e.g. screen captures) want length-prefix. Easy upgrade.
- **Async / streaming responses.** Today it's strict request → response. Memory-watch hooks and frame-by-frame screen feeds will need server-pushed messages.
- **Cross-platform vendor builds.** Only `macos-arm64` LuaSocket is shipped; Windows needs none (built in). Linux artifacts are not yet built.
- **Hot reload.** No way to restart `bridge.lua` without restarting FCEUX. Not a v1 concern.
