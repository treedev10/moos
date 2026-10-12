#!/usr/bin/env python3
"""
Extracts the classic 8x16 PC font (256 glyphs, code page 437) that MOOS draws
on graphics screens, and writes it to src/font8x16.bin (4096 bytes).

Source: the VGA BIOS that ships with QEMU (SeaVGABIOS). Its font tables come
from the "fntcol16" collection by Joseph Gil, whose individual fonts are in
the public domain.

    python tools/makefont.py [path/to/vgabios-stdvga.bin]

You only need to run this if src/font8x16.bin is missing.
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_ROM = r"C:\Program Files\qemu\share\vgabios-stdvga.bin"
GLYPH_A = bytes([0x00, 0x00, 0x10, 0x38, 0x6C, 0xC6, 0xC6, 0xFE,
                 0xC6, 0xC6, 0xC6, 0xC6, 0x00, 0x00, 0x00, 0x00])
GLYPH_SMILEY = bytes([0x00, 0x00, 0x7E, 0x81, 0xA5, 0x81, 0x81, 0xBD,
                      0x99, 0x81, 0x81, 0x7E, 0x00, 0x00, 0x00, 0x00])


def main():
    rom_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_ROM
    rom = open(rom_path, "rb").read()
    at = rom.find(GLYPH_A)
    if at < 0x41 * 16:
        sys.exit("error: no 8x16 font found in %s" % rom_path)
    font = rom[at - 0x41 * 16: at - 0x41 * 16 + 4096]
    if font[16:32] != GLYPH_SMILEY or font[0:16] != bytes(16):
        sys.exit("error: the font in %s does not look like the standard VGA font" % rom_path)
    out = os.path.join(ROOT, "src", "font8x16.bin")
    open(out, "wb").write(font)
    print("wrote", os.path.relpath(out, ROOT))


if __name__ == "__main__":
    main()
