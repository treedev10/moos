#!/usr/bin/env python3
"""Copy a MOOS disk image and put files into its file system (for tests).

    python tools/seedfs.py IN.img OUT.img name=path name=@text ...

name=path copies a file from the host; name=@text writes the text (Python
escapes such as \\n work). Files are at most 4 KB (the MOOSFS limit). For
example, to test the desktop without installing it with apt first:

    python tools/seedfs.py build/moos.img /tmp/t.img desktop.inst=@1
    python tools/screentest.py --uefi --image /tmp/t.img "gui\\n" @png=s.png
"""
import shutil
import struct
import sys

SECTOR = 512
PART_START = 2048
FS_HDR = PART_START + 528
FS_DIR = FS_HDR + 1
FS_DATA = FS_HDR + 8

src, dst = sys.argv[1], sys.argv[2]
shutil.copy(src, dst)
img = bytearray(open(dst, 'rb').read())
hdr = FS_HDR * SECTOR
if img[hdr:hdr + 8] != b'MOOSFS01':
    img[hdr:hdr + SECTOR] = b'MOOSFS01' + bytes(SECTOR - 8)
    img[FS_DIR * SECTOR:(FS_DIR + 2) * SECTOR] = bytes(2 * SECTOR)
d = FS_DIR * SECTOR
used = {}
for i in range(32):
    e = img[d + i * 32:d + i * 32 + 32]
    if e[24] & 1:
        used[e[:20].split(b'\0')[0].decode()] = i
for arg in sys.argv[3:]:
    name, val = arg.split('=', 1)
    data = val[1:].encode().decode('unicode_escape').encode('latin1') if val.startswith('@') \
        else open(val, 'rb').read()
    assert len(data) <= 4096, name
    i = used.get(name)
    if i is None:
        i = next(j for j in range(32) if not img[d + j * 32 + 24] & 1)
        used[name] = i
    e = bytearray(32)
    e[:len(name)] = name.encode()
    struct.pack_into('<III', e, 20, len(data), 1, 0)
    img[d + i * 32:d + i * 32 + 32] = e
    off = (FS_DATA + 8 * i) * SECTOR
    img[off:off + 4096] = data.ljust(4096, b'\0')
open(dst, 'wb').write(img)
print('seeded', dst, sorted(used))
