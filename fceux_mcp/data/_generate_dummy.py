"""Build the minimal NES ROM checked in alongside this script.

The MCP server uses this ROM as a starter when the user doesn't provide a
`--rom` flag — FCEUX 2.6.6 cannot run `emu.loadrom` from a no-ROM state
(the emulator process exits), so we have to launch it with *something*
loaded; the agent's first action is then `emu_loadrom` to switch to the
real ROM, which works fine because emu.loadrom only crashes when nothing
was loaded previously.

Run this script to regenerate `dummy.nes`:

    python -m fceux_mcp.data._generate_dummy

The output is a deterministic 16,400-byte file: 16-byte iNES header +
16 KB PRG ROM. NROM mapper, no CHR ROM (uses CHR RAM), code at $C000
just disables interrupts and loops forever. The screen stays blank,
which is what we want — the agent will replace it immediately.
"""

from pathlib import Path


def build_dummy_nes() -> bytes:
    # iNES header: "NES\x1A", 1 PRG bank, 0 CHR banks, NROM (mapper 0).
    header = b"NES\x1a" + b"\x01\x00\x00\x00" + b"\x00" * 8

    prg = bytearray(16 * 1024)

    # Code at the start of PRG (mirrored at CPU $C000 on NROM-128):
    #   78        SEI            disable interrupts
    #   D8        CLD            clear decimal mode
    #   4C 00 C0  JMP $C000      loop forever
    prg[0:5] = b"\x78\xd8\x4c\x00\xc0"

    # 6502 reset / NMI / IRQ vectors live at $FFFA..$FFFF, which on NROM-128
    # maps to PRG offsets 0x3FFA..0x3FFF. Point all three at $C000 so any
    # vectoring lands back in the loop.
    prg[0x3FFA:0x4000] = b"\x00\xc0\x00\xc0\x00\xc0"  # NMI, reset, IRQ

    return bytes(header) + bytes(prg)


def main() -> None:
    out = Path(__file__).resolve().parent / "dummy.nes"
    data = build_dummy_nes()
    out.write_bytes(data)
    print(f"wrote {out} ({len(data)} bytes)")


if __name__ == "__main__":
    main()
