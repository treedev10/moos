#!/usr/bin/env python3
"""
Make the test streams for src/inflate.asm: build/inflate/NAME.z (compressed by
Python's zlib) and NAME.raw (the original), and index.txt with one line per
stream: NAME FORMAT (0 raw DEFLATE, 1 zlib, 2 gzip).

    python3 tests/native/inflate_data.py
"""
import os
import random
import shutil
import struct
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "build", "inflate")


def payloads():
    rnd = random.Random(7)
    text = open(os.path.join(ROOT, "README.md"), "rb").read()
    yield "empty", b""
    yield "one", b"x"
    yield "text", text
    yield "text4", text * 4
    yield "random", bytes(rnd.getrandbits(8) for _ in range(70000))
    yield "zeros", bytes(300000)
    yield "runs", b"".join(bytes([rnd.randrange(4)]) * rnd.randrange(1, 300) for _ in range(3000))
    yield "pixels", bytes((x * y + (x ^ y)) & 255 for y in range(300) for x in range(400))
    yield "words", b" ".join(rnd.choice([b"the", b"picture", b"decoder", b"MOOS", b"a", b"zlib"])
                             for _ in range(60000))
    big = bytearray()
    while len(big) < 3 << 20:
        big += text[rnd.randrange(len(text) // 2):][:rnd.randrange(1, 5000)]
        big += bytes(rnd.getrandbits(8) for _ in range(rnd.randrange(0, 200)))
    yield "big", bytes(big)


def zlib_wrap(raw, comp, wbits):
    cmf = (wbits - 8) << 4 | 8
    flg = (31 - cmf * 256 % 31) % 31
    return bytes([cmf, flg]) + comp + struct.pack(">I", zlib.adler32(raw))


def gzip_wrap(raw, comp, flags):
    h = b"\x1f\x8b\x08" + bytes([flags]) + b"\0\0\0\0\0\3"
    if flags & 4:
        h += struct.pack("<H", 5) + b"extra"
    if flags & 8:
        h += b"name.txt\0"
    if flags & 16:
        h += b"a comment\0"
    if flags & 2:
        h += struct.pack("<H", zlib.crc32(h) & 0xFFFF)
    return h + comp + struct.pack("<II", zlib.crc32(raw), len(raw) & 0xFFFFFFFF)


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(OUT)
    lines = []

    def add(name, fmt, raw, comp):
        open(os.path.join(OUT, name + ".z"), "wb").write(comp)
        open(os.path.join(OUT, name + ".raw"), "wb").write(raw)
        lines.append("%s %d" % (name, fmt))

    strategies = [("def", zlib.Z_DEFAULT_STRATEGY), ("huff", zlib.Z_HUFFMAN_ONLY),
                  ("rle", zlib.Z_RLE), ("fixed", zlib.Z_FIXED), ("filt", zlib.Z_FILTERED)]
    for pname, raw in payloads():
        for level in (0, 1, 6, 9):
            for sname, strat in strategies:
                if sname != "def" and level != 6:
                    continue
                for wbits in (15, 9, 12):
                    if wbits != 15 and (level != 9 or sname != "def"):
                        continue
                    c = zlib.compressobj(level, zlib.DEFLATED, -wbits, 9 if level else 8, strat)
                    comp = c.compress(raw) + c.flush()
                    tag = "%s_l%d_%s_w%d" % (pname, level, sname, wbits)
                    add(tag + "_raw", 0, raw, comp)
                    add(tag + "_zlib", 1, raw, zlib_wrap(raw, comp, wbits))
                    if level == 6:
                        add(tag + "_gz", 2, raw, gzip_wrap(raw, comp, 0))
        c = zlib.compressobj(6, zlib.DEFLATED, -15)      # many small blocks (full flushes)
        part = raw[:200000]
        comp = b"".join(c.compress(part[i:i + 997]) + c.flush(zlib.Z_FULL_FLUSH)
                        for i in range(0, len(part), 997)) + c.flush()
        add(pname + "_flushes_raw", 0, part, comp)
    raw = b"hello, hello, hello gzip"
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    comp = c.compress(raw) + c.flush()
    for flags in (2, 4, 8, 16, 30):
        add("gzflags%d" % flags, 2, raw, gzip_wrap(raw, comp, flags))
    open(os.path.join(OUT, "index.txt"), "w").write("\n".join(lines) + "\n")
    print("%s: %d streams" % (OUT, len(lines)))


if __name__ == "__main__":
    main()
