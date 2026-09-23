"""MCP server for FCEUX.

Spawns FCEUX with bridge.lua and exposes the bridge's TCP/JSON command surface
as MCP tools. See docs/CONCEPT.md and docs/ARCHITECTURE.md for the design.

If a bridge is already listening on the configured port, the server attaches
to it instead of spawning (handy for development).
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP, Image

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 9999
BRIDGE_READY_TIMEOUT_SEC = 10.0
RECV_BUF = 4096

# Bundled minimal NES ROM used as a starter when the user didn't supply
# --rom. FCEUX 2.6.6 cannot load a ROM via emu.loadrom from a no-ROM state
# (the emulator process exits), but emu.loadrom from one loaded ROM to
# another works fine — so we always boot FCEUX with *something* and let the
# agent switch via emu_loadrom. See fceux_mcp/data/_generate_dummy.py.
BUNDLED_DUMMY_ROM = Path(__file__).resolve().parent / "data" / "dummy.nes"


# ---------------------------------------------------------------------------
# Bridge client
# ---------------------------------------------------------------------------

class BridgeError(RuntimeError):
    """Structured error from the bridge. `code` is one of: parse_error,
    method_not_found, invalid_params, lua_error, bridge_unreachable."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message


class BridgeUnreachable(BridgeError):
    """Server-side error for transport failures (FCEUX/bridge gone)."""

    def __init__(self, reason: str) -> None:
        super().__init__("bridge_unreachable", reason)


class BridgeClient:
    """Line-framed JSON client for bridge.lua over loopback TCP."""

    def __init__(self, host: str, port: int) -> None:
        self._host = host
        self._port = port
        self._sock: socket.socket | None = None
        self._buf = b""
        self._next_id = 1

    def connect(self) -> None:
        if self._sock is not None:
            return
        self._sock = socket.create_connection((self._host, self._port), timeout=5)
        self._sock.settimeout(30)
        self._buf = b""

    def close(self) -> None:
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
        self._sock = None
        self._buf = b""

    def call(self, method: str, params: dict | None = None) -> Any:
        if self._sock is None:
            try:
                self.connect()
            except OSError as e:
                raise BridgeUnreachable(f"connect failed: {e}") from e
        rid = self._next_id
        self._next_id += 1
        req: dict[str, Any] = {"id": rid, "method": method}
        if params:
            req["params"] = params
        line = (json.dumps(req) + "\n").encode()
        try:
            assert self._sock is not None
            self._sock.sendall(line)
            resp_line = self._recv_line()
        except OSError as e:
            self.close()
            raise BridgeUnreachable(f"transport error: {e}") from e

        try:
            msg = json.loads(resp_line)
        except json.JSONDecodeError as e:
            raise BridgeError("lua_error", f"invalid bridge response: {e}: {resp_line!r}") from e

        if "error" in msg:
            err = msg["error"]
            raise BridgeError(err.get("code", "lua_error"), err.get("message", ""))
        return msg.get("result")

    def _recv_line(self) -> str:
        assert self._sock is not None
        while b"\n" not in self._buf:
            chunk = self._sock.recv(RECV_BUF)
            if not chunk:
                raise BridgeUnreachable("bridge closed connection")
            self._buf += chunk
        line, _, self._buf = self._buf.partition(b"\n")
        return line.decode()


# ---------------------------------------------------------------------------
# FCEUX launch / port readiness
# ---------------------------------------------------------------------------

def is_port_open(host: str, port: int, timeout: float = 0.5) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def wait_for_port(host: str, port: int, timeout_sec: float, interval: float = 0.1) -> bool:
    deadline = time.monotonic() + timeout_sec
    while time.monotonic() < deadline:
        if is_port_open(host, port):
            return True
        time.sleep(interval)
    return False


def spawn_fceux(rom: Path | None, bridge_lua: Path, port: int, fceux: str = "fceux") -> subprocess.Popen:
    if not bridge_lua.exists():
        raise FileNotFoundError(f"bridge.lua not found: {bridge_lua}")
    # The Windows build has no --loadlua; it takes -lua <script>, and the
    # script's path must be absolute (FCEUX changes into the script's folder).
    if os.name == "nt":
        argv = [fceux, "-lua", str(bridge_lua.resolve())]
    else:
        argv = [fceux, "--loadlua", str(bridge_lua)]
    if rom is not None:
        if not rom.exists():
            raise FileNotFoundError(f"ROM not found: {rom}")
        argv.append(str(rom))
    env = {**os.environ, "FCEUX_BRIDGE_PORT": str(port)}
    return subprocess.Popen(
        argv, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


# ---------------------------------------------------------------------------
# MCP tools
# ---------------------------------------------------------------------------

def build_server(client: BridgeClient) -> FastMCP:
    mcp = FastMCP("fceux-mcp")

    @mcp.tool()
    def ping() -> str:
        """Round-trip ping to the FCEUX bridge."""
        return client.call("ping")

    @mcp.tool()
    def emu_framecount() -> int:
        """Current NES frame counter."""
        return client.call("emu.framecount")

    @mcp.tool()
    def emu_step(frames: int = 1) -> int:
        """Advance the emulator by N frames synchronously. Returns the new framecount."""
        return client.call("emu.step", {"frames": frames})

    @mcp.tool()
    def emu_pause() -> bool:
        """Set the bridge-level pause flag — frames stop advancing until emu_unpause."""
        return client.call("emu.pause")

    @mcp.tool()
    def emu_unpause() -> bool:
        """Clear the bridge-level pause flag — frames advance at NTSC ~60 Hz."""
        return client.call("emu.unpause")

    @mcp.tool()
    def emu_paused() -> bool:
        """Return the current bridge-level pause state."""
        return client.call("emu.paused")

    @mcp.tool()
    def emu_message(text: str) -> bool:
        """Display a message in FCEUX's HUD overlay."""
        return client.call("emu.message", {"text": text})

    @mcp.tool()
    def memory_readbyte(address: int) -> int:
        """Read one unsigned byte from CPU RAM at the given address (0x0000–0xFFFF)."""
        return client.call("memory.readbyte", {"address": address})

    @mcp.tool()
    def memory_readbyterange(address: int, length: int) -> list[int]:
        """Read `length` unsigned bytes from CPU RAM starting at `address`."""
        return client.call("memory.readbyterange", {"address": address, "length": length})

    @mcp.tool()
    def memory_writebyte(address: int, value: int) -> bool:
        """Write one byte to CPU RAM at the given address."""
        return client.call("memory.writebyte", {"address": address, "value": value})

    @mcp.tool()
    def joypad_get(player: int = 1) -> dict[str, bool]:
        """Read controller state for the given player (1–4)."""
        return client.call("joypad.get", {"player": player})

    @mcp.tool()
    def joypad_set(buttons: dict[str, bool], player: int = 1) -> bool:
        """Force controller buttons. `buttons` is a dict mapping NES button names
        ("A", "B", "up", "down", "left", "right", "start", "select") to True/False."""
        return client.call("joypad.set", {"player": player, "input": buttons})

    @mcp.tool()
    def gui_screenshot() -> Image:
        """Capture the current emulated screen as PNG. Note: advances the timeline
        by one frame (FCEUX defers screenshot writes until the next frame render)."""
        result = client.call("gui.screenshot")
        return Image(path=result["path"], format="png")

    # --- Emulator lifecycle -------------------------------------------------

    @mcp.tool()
    def emu_poweron() -> dict:
        """Power-cycle the NES (hard reset). Frame counter resets to 0."""
        return client.call("emu.poweron")

    @mcp.tool()
    def emu_softreset() -> dict:
        """Soft-reset the NES (equivalent to the console's reset button)."""
        return client.call("emu.softreset")

    @mcp.tool()
    def emu_loadrom(filename: str) -> dict:
        """Load a different ROM. Path is resolved relative to bridge.lua or
        as absolute. Note: if the path can't be loaded, FCEUX silently falls
        back to the most-recent ROM; the returned `filename` is what's
        actually loaded so the caller can detect that case."""
        return client.call("emu.loadrom", {"filename": filename})

    # --- Savestates ---------------------------------------------------------

    @mcp.tool()
    def savestate_save(slot: int | None = None) -> dict:
        """Save current emulator state. With slot=1-10 saves into a session
        slot that's reusable across many loads (in-memory; cleared when
        FCEUX exits). Without slot saves into a single-use anonymous
        in-memory state — note these are single-use: FCEUX deletes the
        state on load, so you must save again before each anonymous
        load. For repeated rewinds to the same point, use a slot."""
        params = {"slot": slot} if slot is not None else None
        return client.call("savestate.save", params)

    @mcp.tool()
    def savestate_load(slot: int | None = None) -> dict:
        """Restore a previously saved state. With slot=1-10 loads from that
        session slot (reusable). Without slot loads from the single-use
        anonymous state. Errors if the slot was never saved or the
        anonymous state isn't fresh."""
        params = {"slot": slot} if slot is not None else None
        return client.call("savestate.load", params)

    # --- Memory: word reads + CPU registers ---------------------------------

    @mcp.tool()
    def memory_readword(address: int, address_high: int | None = None) -> int:
        """Read a 16-bit word from CPU RAM. With one address, reads
        little-endian at address & address+1. With two, reads the low byte
        from `address` and the high byte from `address_high` (useful for
        games that store 16-bit values as separated low/high bytes)."""
        params: dict[str, int] = {"address": address}
        if address_high is not None:
            params["address_high"] = address_high
        return client.call("memory.readword", params)

    @mcp.tool()
    def memory_getregister(name: str) -> int:
        """Read a 6502 CPU register: one of a, x, y, s, p, pc."""
        return client.call("memory.getregister", {"name": name})

    # --- ROM info -----------------------------------------------------------

    @mcp.tool()
    def rom_getfilename() -> str:
        """Base filename of the loaded ROM."""
        return client.call("rom.getfilename")

    @mcp.tool()
    def rom_gethash(type: str = "md5") -> str:
        """Hash of the loaded ROM. `type` is 'md5' (hex) or 'base64'."""
        return client.call("rom.gethash", {"type": type})

    # --- GUI overlay drawing (one-shot per call) ---------------------------

    @mcp.tool()
    def gui_text(x: int, y: int, text: str, color: str | None = None) -> bool:
        """Draw text on FCEUX's overlay at (x, y). Drawn for one frame only;
        call every step to keep it visible. Color may be a name ('red',
        'orange', 'white'), '#rrggbb', or 'P##' palette code."""
        params: dict = {"x": x, "y": y, "text": text}
        if color is not None:
            params["color"] = color
        return client.call("gui.text", params)

    @mcp.tool()
    def gui_box(x1: int, y1: int, x2: int, y2: int,
                fillcolor: str | None = None,
                outlinecolor: str | None = None) -> bool:
        """Draw a rectangle on FCEUX's overlay. One-shot per call."""
        params: dict = {"x1": x1, "y1": y1, "x2": x2, "y2": y2}
        if fillcolor is not None:
            params["fillcolor"] = fillcolor
        if outlinecolor is not None:
            params["outlinecolor"] = outlinecolor
        return client.call("gui.box", params)

    @mcp.tool()
    def gui_pixel(x: int, y: int, color: str | None = None) -> bool:
        """Draw one pixel on FCEUX's overlay. One-shot per call."""
        params: dict = {"x": x, "y": y}
        if color is not None:
            params["color"] = color
        return client.call("gui.pixel", params)

    @mcp.tool()
    def lua_exec(code: str) -> Any:
        """Run arbitrary Lua inside FCEUX. The full FCEUX Lua API is in
        scope (emu.*, memory.*, ppu.*, joypad.*, gui.*, …) — see
        docs/FLUA-FUNCTIONS.md.

        Use `return EXPR` to send back a value. Returned values must be
        JSON-serializable: tables / numbers / strings / booleans / nil.
        Functions and userdata error out as lua_error.

        Use this for batched reads, ad-hoc queries, or APIs that aren't
        wrapped as typed tools yet. For common operations the typed
        tools are preferable — they document themselves to the agent
        and are validated.

        Caveat: cannot call emu.frameadvance() from here (Lua 5.1
        forbids yielding across the pcall this tool runs inside). Call
        the typed `emu_step` tool to advance frames, then read state
        via lua_exec.

        Examples:
            lua_exec("return memory.readbyte(0x100)")
            lua_exec("return {x = memory.readbyte(0x10), y = memory.readbyte(0x11)}")
            lua_exec("local t={} for i=0,15 do t[i+1]=memory.readbyte(i) end return t")
        """
        return client.call("lua.exec", {"code": code})

    return mcp


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(prog="fceux-mcp", description=__doc__.splitlines()[0] if __doc__ else "")
    parser.add_argument("--rom", type=Path, default=None,
                        help="path to NES ROM (required if no bridge is already running)")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT,
                        help=f"bridge TCP port (default: {DEFAULT_PORT})")
    parser.add_argument("--host", default=DEFAULT_HOST,
                        help=f"bridge host (default: {DEFAULT_HOST})")
    parser.add_argument("--fceux", default="fceux",
                        help="FCEUX executable (default: fceux on PATH; on Windows e.g. C:\\FCEUX\\fceux.exe)")
    parser.add_argument("--bridge-lua", type=Path, default=None,
                        help="path to bridge.lua (default: <repo>/bridge.lua next to this script)")
    args = parser.parse_args()

    bridge_lua = args.bridge_lua or (Path(__file__).resolve().parent.parent / "bridge.lua")

    fceux_proc: subprocess.Popen | None = None
    if is_port_open(args.host, args.port):
        print(f"[fceux-mcp] attaching to existing bridge on {args.host}:{args.port}", file=sys.stderr)
    else:
        rom = args.rom or BUNDLED_DUMMY_ROM
        if args.rom is None:
            print("[fceux-mcp] launching FCEUX with bundled dummy ROM "
                  "(agent should call emu_loadrom to switch to a real ROM)",
                  file=sys.stderr)
        else:
            print(f"[fceux-mcp] launching FCEUX with {rom}", file=sys.stderr)
        fceux_proc = spawn_fceux(rom, bridge_lua, args.port, args.fceux)
        if not wait_for_port(args.host, args.port, BRIDGE_READY_TIMEOUT_SEC):
            print(f"[fceux-mcp] bridge did not start within {BRIDGE_READY_TIMEOUT_SEC}s",
                  file=sys.stderr)
            fceux_proc.terminate()
            return 1

    client = BridgeClient(args.host, args.port)
    client.connect()

    mcp = build_server(client)
    try:
        mcp.run()
    finally:
        client.close()
        if fceux_proc is not None:
            fceux_proc.terminate()
            try:
                fceux_proc.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                fceux_proc.kill()

    return 0


if __name__ == "__main__":
    sys.exit(main())
