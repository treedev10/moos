#!/usr/bin/env python3
"""
mp4box.py - a small ISO BMFF (MP4) box reader and writer for making test files.

Used by mp4_data.py to look inside the files ffmpeg makes and to rewrite them in
ways ffmpeg itself never writes (64-bit box sizes, a size-0 last box, co64 chunk
offsets, compact stz2 sample sizes, odd edit lists, a QuickTime 'wave' wrapper).
Written from ISO/IEC 14496-12; it is test tooling only, not part of MOOS.

    python3 tests/native/mp4box.py FILE        # print the box tree
"""
import struct
import sys

# boxes whose payload is a list of child boxes
CONTAINERS = {b"moov", b"trak", b"mdia", b"minf", b"stbl", b"edts", b"dinf",
              b"udta", b"mvex", b"moof", b"traf", b"wave"}


class Box:
    """One box: type (4 bytes), payload bytes (leaves) or children (containers).
    big = write a 64-bit size; zero = write size 0 (box runs to the end of the file)."""

    def __init__(self, typ, data=b"", children=None, big=False, zero=False):
        self.type = typ
        self.data = data
        self.children = children
        self.big = big
        self.zero = zero

    def payload(self):
        if self.children is not None:
            return b"".join(c.encode() for c in self.children)
        return self.data

    def encode(self):
        p = self.payload()
        if self.big:
            return struct.pack(">I4sQ", 1, self.type, len(p) + 16) + p
        if self.zero:
            return struct.pack(">I4s", 0, self.type) + p
        return struct.pack(">I4s", len(p) + 8, self.type) + p

    def find(self, typ):
        for c in self.children or []:
            if c.type == typ:
                return c
        return None

    def findall(self, typ):
        return [c for c in (self.children or []) if c.type == typ]


def parse(buf, start=0, end=None, depth=0):
    """Parse the boxes in buf[start:end] into a list of Box."""
    end = len(buf) if end is None else end
    out = []
    pos = start
    while pos + 8 <= end:
        size, typ = struct.unpack_from(">I4s", buf, pos)
        hdr = 8
        if size == 1:
            size = struct.unpack_from(">Q", buf, pos + 8)[0]
            hdr = 16
        elif size == 0:
            size = end - pos
        if size < hdr or pos + size > end:
            break
        body = (pos + hdr, pos + size)
        if typ in CONTAINERS:
            b = Box(typ, children=parse(buf, body[0], body[1], depth + 1))
        elif typ == b"stsd":
            # full box + entry count, then sample entries; keep the entries raw
            b = Box(typ, buf[body[0]:body[1]])
        else:
            b = Box(typ, buf[body[0]:body[1]])
        b.offset = pos
        b.hdr = hdr
        out.append(b)
        pos += size
    return out


def dump(boxes, indent=0):
    for b in boxes:
        info = ""
        if b.type in (b"mdhd", b"mvhd"):
            v = b.data[0]
            if v == 1:
                ts, dur = struct.unpack_from(">IQ", b.data, 20)
            else:
                ts, dur = struct.unpack_from(">II", b.data, 12)
            info = " timescale=%d duration=%d" % (ts, dur)
        elif b.type == b"elst":
            v = b.data[0]
            n = struct.unpack_from(">I", b.data, 4)[0]
            ents = []
            for i in range(n):
                if v == 1:
                    d, t, r = struct.unpack_from(">Qqi", b.data, 8 + i * 20)
                else:
                    d, t, r = struct.unpack_from(">Iii", b.data, 8 + i * 12)
                ents.append((d, t, r / 65536))
            info = " v%d %s" % (v, ents)
        elif b.type in (b"stts", b"ctts", b"stss", b"stsc", b"stco", b"co64"):
            info = " v%d entries=%d" % (b.data[0], struct.unpack_from(">I", b.data, 4)[0])
        elif b.type == b"stsz":
            info = " size=%d count=%d" % struct.unpack_from(">II", b.data, 4)
        elif b.type == b"hdlr":
            info = " " + b.data[8:12].decode("latin1")
        elif b.type == b"stsd":
            info = " entry=%s" % b.data[12:16].decode("latin1")
        print("%s%s @%d size=%d%s" % ("  " * indent, b.type.decode("latin1"),
                                       getattr(b, "offset", -1), len(b.payload()) + b.hdr, info))
        if b.children is not None:
            dump(b.children, indent + 1)


def tracks(moov):
    return moov.findall(b"trak")


def stbl_of(trak):
    return trak.find(b"mdia").find(b"minf").find(b"stbl")


def handler(trak):
    return trak.find(b"mdia").find(b"hdlr").data[8:12]


def chunk_offsets(stbl):
    """List of chunk offsets (stco or co64)."""
    b = stbl.find(b"stco")
    if b:
        n = struct.unpack_from(">I", b.data, 4)[0]
        return list(struct.unpack_from(">%dI" % n, b.data, 8))
    b = stbl.find(b"co64")
    n = struct.unpack_from(">I", b.data, 4)[0]
    return list(struct.unpack_from(">%dQ" % n, b.data, 8))


def set_chunk_offsets(stbl, offs, use64=None):
    """Write chunk offsets back, as stco or co64 (use64), replacing the old box."""
    old = stbl.find(b"stco") or stbl.find(b"co64")
    if use64 is None:
        use64 = old.type == b"co64"
    if use64:
        new = Box(b"co64", struct.pack(">II", 0, len(offs)) + b"".join(struct.pack(">Q", o) for o in offs))
    else:
        new = Box(b"stco", struct.pack(">II", 0, len(offs)) + b"".join(struct.pack(">I", o) for o in offs))
    stbl.children[stbl.children.index(old)] = new


def sample_sizes(stbl):
    b = stbl.find(b"stsz")
    const, n = struct.unpack_from(">II", b.data, 4)
    if const:
        return [const] * n
    return list(struct.unpack_from(">%dI" % n, b.data, 12))


def to_stz2(stbl, field):
    """Replace stsz by a compact stz2 box with 4, 8 or 16-bit entries."""
    sizes = sample_sizes(stbl)
    if field == 16:
        body = b"".join(struct.pack(">H", s) for s in sizes)
    elif field == 8:
        body = bytes(sizes)
    else:
        if len(sizes) & 1:
            sizes = sizes + [0]
        body = bytes((sizes[i] << 4) | sizes[i + 1] for i in range(0, len(sizes), 2))
    n = len(sample_sizes(stbl))
    old = stbl.find(b"stsz")
    # full box header, 24 reserved bits, field_size, sample_count, entries
    stbl.children[stbl.children.index(old)] = Box(b"stz2", struct.pack(">I3xBI", 0, field, n) + body)


def write_file(path, boxes, mdat_payload_offset_before, fixup=True):
    """Serialize top-level boxes to path. If fixup, shift every track's chunk
    offsets by how far the mdat payload moved (old payload start given)."""
    if fixup:
        # find where the mdat payload lands in the new layout
        pos = 0
        for b in boxes:
            enc_len = len(b.encode())
            if b.type == b"mdat":
                hdr = 16 if b.big else 8
                delta = pos + hdr - mdat_payload_offset_before
                break
            pos += enc_len
        moov = [b for b in boxes if b.type == b"moov"][0]
        for t in tracks(moov):
            st = stbl_of(t)
            set_chunk_offsets(st, [o + delta for o in chunk_offsets(st)])
    with open(path, "wb") as f:
        for b in boxes:
            f.write(b.encode())


if __name__ == "__main__":
    data = open(sys.argv[1], "rb").read()
    dump(parse(data))
