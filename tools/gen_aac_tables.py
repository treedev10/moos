#!/usr/bin/env python3
"""
Generate src/aac_tables.inc: the constant tables of the AAC-LC decoder
(src/aac.asm).

    python tools/gen_aac_tables.py            writes src/aac_tables.inc
    python tools/gen_aac_tables.py --c FILE   also writes the same tables as a
                                              C header (for test models)

What is in it, and where it comes from (ISO/IEC 14496-3, subpart 4):

  - The 12 Huffman codebooks (scale factors, spectral books 1-11) of
    Annex 4.A, as (length, codeword) per index below. They were obtained -
    and are re-checked - with tools/aac_probe_codebooks.py, which finds each
    codeword by feeding hand-made frames to a reference decoder (ffmpeg) as
    a black box. This script checks that every book is a complete prefix
    code (Kraft sum exactly 1) before turning it into lookup tables.
  - Scale factor band offsets (swb_offset_long/short_window) and
    TNS_MAX_BANDS per sampling rate (tables 4.129 ff., 4.156).
  - Everything else is computed from its definition: the sine and
    Kaiser-Bessel-derived windows (4.6.11.3.2), |q|^(4/3), 2^(i/4), the TNS
    coefficient dequantisation (4.6.9.3), and the twiddle factors of the
    FFT-based inverse MDCT.

Floats are written as their exact 32-bit patterns.
"""
import math
import os
import struct
import sys
from fractions import Fraction

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "src", "aac_tables.inc")

# The Huffman codebooks of ISO/IEC 14496-3 Annex 4.A, in index order.
# Each token is 'length:codeword' (length in bits, decimal; codeword in
# hex). Index: scale factors = delta + 60; quads = 27w + 9x + 3y + z and
# pairs = mod*y + z, with values offset by LAV in the signed books
# (Table 4.139), mod = 2*LAV+1 (signed) or LAV+1 (unsigned).
CODEBOOKS = {
    "sf": """
        18:3ffe8 18:3ffe6 18:3ffe7 18:3ffe5 19:7fff5 19:7fff1 19:7ffed 19:7fff6 19:7ffee
        19:7ffef 19:7fff0 19:7fffc 19:7fffd 19:7ffff 19:7fffe 19:7fff7 19:7fff8 19:7fffb
        19:7fff9 18:3ffe4 19:7fffa 18:3ffe3 17:1ffef 17:1fff0 16:fff5 17:1ffee 16:fff2
        16:fff3 16:fff4 16:fff1 15:7ff6 15:7ff7 14:3ff9 14:3ff5 14:3ff7 14:3ff3
        14:3ff6 14:3ff2 13:1ff7 13:1ff5 12:ff9 12:ff7 12:ff6 11:7f9 12:ff4
        11:7f8 10:3f9 10:3f7 10:3f5 9:1f8 9:1f7 8:fa 8:f8 8:f6
        7:79 6:3a 6:38 5:1a 4:b 3:4 1:0 4:a 4:c
        5:1b 6:39 6:3b 7:78 7:7a 8:f7 8:f9 9:1f6 9:1f9
        10:3f4 10:3f6 10:3f8 11:7f5 11:7f4 11:7f6 11:7f7 12:ff5 12:ff8
        13:1ff4 13:1ff6 13:1ff8 14:3ff8 14:3ff4 16:fff0 15:7ff4 16:fff6 15:7ff5
        18:3ffe2 19:7ffd9 19:7ffda 19:7ffdb 19:7ffdc 19:7ffdd 19:7ffde 19:7ffd8 19:7ffd2
        19:7ffd3 19:7ffd4 19:7ffd5 19:7ffd6 19:7fff2 19:7ffdf 19:7ffe7 19:7ffe8 19:7ffe9
        19:7ffea 19:7ffeb 19:7ffe6 19:7ffe0 19:7ffe1 19:7ffe2 19:7ffe3 19:7ffe4 19:7ffe5
        19:7ffd7 19:7ffec 19:7fff4 19:7fff3
    """,
    1: """
        11:7f8 9:1f1 11:7fd 10:3f5 7:68 10:3f0 11:7f7 9:1ec 11:7f5
        10:3f1 7:72 10:3f4 7:74 5:11 7:76 9:1eb 7:6c 10:3f6
        11:7fc 9:1e1 11:7f1 9:1f0 7:61 9:1f6 11:7f2 9:1ea 11:7fb
        9:1f2 7:69 9:1ed 7:77 5:17 7:6f 9:1e6 7:64 9:1e5
        7:67 5:15 7:62 5:12 1:0 5:14 7:65 5:16 7:6d
        9:1e9 7:63 9:1e4 7:6b 5:13 7:71 9:1e3 7:70 9:1f3
        11:7fe 9:1e7 11:7f3 9:1ef 7:60 9:1ee 11:7f0 9:1e2 11:7fa
        10:3f3 7:6a 9:1e8 7:75 5:10 7:73 9:1f4 7:6e 10:3f7
        11:7f6 9:1e0 11:7f9 10:3f2 7:66 9:1f5 11:7ff 9:1f7 11:7f4
    """,
    2: """
        9:1f3 7:6f 9:1fd 8:eb 6:23 8:ea 9:1f7 8:e8 9:1fa
        8:f2 6:2d 7:70 6:20 5:6 6:2b 7:6e 6:28 8:e9
        9:1f9 7:66 8:f8 8:e7 6:1b 8:f1 9:1f4 7:6b 9:1f5
        8:ec 6:2a 7:6c 6:2c 5:a 6:27 7:67 6:1a 8:f5
        6:24 5:8 6:1f 5:9 3:0 5:7 6:1d 5:b 6:30
        8:ef 6:1c 7:64 6:1e 5:c 6:29 8:f3 6:2f 8:f0
        9:1fc 7:71 9:1f2 8:f4 6:21 8:e6 8:f7 7:68 9:1f8
        8:ee 6:22 7:65 6:31 4:2 6:26 8:ed 6:25 7:6a
        9:1fb 7:72 9:1fe 7:69 6:2e 8:f6 9:1ff 7:6d 9:1f6
    """,
    3: """
        1:0 4:9 8:ef 4:b 5:19 8:f0 9:1eb 9:1e6 10:3f2
        4:a 6:35 9:1ef 6:34 6:37 9:1e9 9:1ed 9:1e7 10:3f3
        9:1ee 10:3ed 13:1ffa 9:1ec 9:1f2 11:7f9 11:7f8 10:3f8 12:ff8
        4:8 6:38 10:3f6 6:36 7:75 10:3f1 10:3eb 10:3ec 12:ff4
        5:18 7:76 11:7f4 6:39 7:74 10:3ef 9:1f3 9:1f4 11:7f6
        9:1e8 10:3ea 13:1ffc 8:f2 9:1f1 12:ffb 10:3f5 11:7f3 12:ffc
        8:ee 10:3f7 15:7ffe 9:1f0 11:7f5 15:7ffd 13:1ffb 14:3ffa 16:ffff
        8:f1 10:3f0 14:3ffc 9:1ea 10:3ee 14:3ffb 12:ff6 12:ffa 15:7ffc
        11:7f2 12:ff5 16:fffe 10:3f4 11:7f7 15:7ffb 12:ff7 12:ff9 15:7ffa
    """,
    4: """
        4:7 5:16 8:f6 5:18 4:8 8:ef 9:1ef 8:f3 11:7f8
        5:19 5:17 8:ed 5:15 4:1 8:e2 8:f0 7:70 10:3f0
        9:1ee 8:f1 11:7fa 8:ee 8:e4 10:3f2 11:7f6 10:3ef 11:7fd
        4:5 5:14 8:f2 4:9 4:4 8:e5 8:f4 8:e8 10:3f4
        4:6 4:2 8:e7 4:3 4:0 7:6b 8:e3 7:69 9:1f3
        8:eb 8:e6 10:3f6 7:6e 7:6a 9:1f4 10:3ec 9:1f0 10:3f9
        8:f5 8:ec 11:7fb 8:ea 7:6f 10:3f7 11:7f9 10:3f3 12:fff
        8:e9 7:6d 10:3f8 7:6c 7:68 9:1f5 10:3ee 9:1f2 11:7f4
        11:7f7 10:3f1 12:ffe 10:3ed 9:1f1 11:7f5 11:7fe 10:3f5 11:7fc
    """,
    5: """
        13:1fff 12:ff7 11:7f4 11:7e8 10:3f1 11:7ee 11:7f9 12:ff8 13:1ffd
        12:ffd 11:7f1 10:3e8 9:1e8 8:f0 9:1ec 10:3ee 11:7f2 12:ffa
        12:ff4 10:3ef 9:1f2 8:e8 7:70 8:ec 9:1f0 10:3ea 11:7f3
        11:7eb 9:1eb 8:ea 5:1a 4:8 5:19 8:ee 9:1ef 11:7ed
        10:3f0 8:f2 7:73 4:b 1:0 4:a 7:71 8:f3 11:7e9
        11:7ef 9:1ee 8:ef 5:18 4:9 5:1b 8:eb 9:1e9 11:7ec
        11:7f6 10:3eb 9:1f3 8:ed 7:72 8:e9 9:1f1 10:3ed 11:7f7
        12:ff6 11:7f0 10:3e9 9:1ed 8:f1 9:1ea 10:3ec 11:7f8 12:ff9
        13:1ffc 12:ffc 12:ff5 11:7ea 10:3f3 10:3f2 11:7f5 12:ffb 13:1ffe
    """,
    6: """
        11:7fe 10:3fd 9:1f1 9:1eb 9:1f4 9:1ea 9:1f0 10:3fc 11:7fd
        10:3f6 9:1e5 8:ea 7:6c 7:71 7:68 8:f0 9:1e6 10:3f7
        9:1f3 8:ef 6:32 6:27 6:28 6:26 6:31 8:eb 9:1f7
        9:1e8 7:6f 6:2e 4:8 4:4 4:6 6:29 7:6b 9:1ee
        9:1ef 7:72 6:2d 4:2 4:0 4:3 6:2f 7:73 9:1fa
        9:1e7 7:6e 6:2b 4:7 4:1 4:5 6:2c 7:6d 9:1ec
        9:1f9 8:ee 6:30 6:24 6:2a 6:25 6:33 8:ec 9:1f2
        10:3f8 9:1e4 8:ed 7:6a 7:70 7:69 7:74 8:f1 10:3fa
        11:7ff 10:3f9 9:1f6 9:1ed 9:1f8 9:1e9 9:1f5 10:3fb 11:7fc
    """,
    7: """
        1:0 3:5 6:37 7:74 8:f2 9:1eb 10:3ed 11:7f7 3:4
        4:c 6:35 7:71 8:ec 8:ee 9:1ee 9:1f5 6:36 6:34
        7:72 8:ea 8:f1 9:1e9 9:1f3 10:3f5 7:73 7:70 8:eb
        8:f0 9:1f1 9:1f0 10:3ec 10:3fa 8:f3 8:ed 9:1e8 9:1ef
        10:3ef 10:3f1 10:3f9 11:7fb 9:1ed 8:ef 9:1ea 9:1f2 10:3f3
        10:3f8 11:7f9 11:7fc 10:3ee 9:1ec 9:1f4 10:3f4 10:3f7 11:7f8
        12:ffd 12:ffe 11:7f6 10:3f0 10:3f2 10:3f6 11:7fa 11:7fd 12:ffc
        12:fff
    """,
    8: """
        5:e 4:5 5:10 6:30 7:6f 8:f1 9:1fa 10:3fe 4:3
        3:0 4:4 5:12 6:2c 7:6a 7:75 8:f8 5:f 4:2
        4:6 5:14 6:2e 7:69 7:72 8:f5 6:2f 5:11 5:13
        6:2a 6:32 7:6c 8:ec 8:fa 7:71 6:2b 6:2d 6:31
        7:6d 7:70 8:f2 9:1f9 8:ef 7:68 6:33 7:6b 7:6e
        8:ee 8:f9 10:3fc 9:1f8 7:74 7:73 8:ed 8:f0 8:f6
        9:1f6 9:1fd 10:3fd 8:f3 8:f4 8:f7 9:1f7 9:1fb 9:1fc
        10:3ff
    """,
    9: """
        1:0 3:5 6:37 8:e7 9:1de 10:3ce 10:3d9 11:7c8 11:7cd
        12:fc8 12:fdd 13:1fe4 13:1fec 3:4 4:c 6:35 7:72 8:ea
        8:ed 9:1e2 10:3d1 10:3d3 10:3e0 11:7d8 12:fcf 12:fd5 6:36
        6:34 7:71 8:e8 8:ec 9:1e1 10:3cf 10:3dd 10:3db 11:7d0
        12:fc7 12:fd4 12:fe4 8:e6 7:70 8:e9 9:1dd 9:1e3 10:3d2
        10:3dc 11:7cc 11:7ca 11:7de 12:fd8 12:fea 13:1fdb 9:1df 8:eb
        9:1dc 9:1e6 10:3d5 10:3de 11:7cb 11:7dd 11:7dc 12:fcd 12:fe2
        12:fe7 13:1fe1 10:3d0 9:1e0 9:1e4 10:3d6 11:7c5 11:7d1 11:7db
        12:fd2 11:7e0 12:fd9 12:feb 13:1fe3 13:1fe9 11:7c4 9:1e5 10:3d7
        11:7c6 11:7cf 11:7da 12:fcb 12:fda 12:fe3 12:fe9 13:1fe6 13:1ff3
        13:1ff7 11:7d3 10:3d8 10:3e1 11:7d4 11:7d9 12:fd3 12:fde 13:1fdd
        13:1fd9 13:1fe2 13:1fea 13:1ff1 13:1ff6 11:7d2 10:3d4 10:3da 11:7c7
        11:7d7 11:7e2 12:fce 12:fdb 13:1fd8 13:1fee 14:3ff0 13:1ff4 14:3ff2
        11:7e1 10:3df 11:7c9 11:7d6 12:fca 12:fd0 12:fe5 12:fe6 13:1feb
        13:1fef 14:3ff3 14:3ff4 14:3ff5 12:fe0 11:7ce 11:7d5 12:fc6 12:fd1
        12:fe1 13:1fe0 13:1fe8 13:1ff0 14:3ff1 14:3ff8 14:3ff6 15:7ffc 12:fe8
        11:7df 12:fc9 12:fd7 12:fdc 13:1fdc 13:1fdf 13:1fed 13:1ff5 14:3ff9
        14:3ffb 15:7ffd 15:7ffe 13:1fe7 12:fcc 12:fd6 12:fdf 13:1fde 13:1fda
        13:1fe5 13:1ff2 14:3ffa 14:3ff7 14:3ffc 14:3ffd 15:7fff
    """,
    10: """
        6:22 5:8 6:1d 6:26 7:5f 8:d3 9:1cf 10:3d0 10:3d7
        10:3ed 11:7f0 11:7f6 12:ffd 5:7 4:0 4:1 5:9 6:20
        7:54 7:60 8:d5 8:dc 9:1d4 10:3cd 10:3de 11:7e7 6:1c
        4:2 5:6 5:c 6:1e 6:28 7:5b 8:cd 8:d9 9:1ce
        9:1dc 10:3d9 10:3f1 6:25 5:b 5:a 5:d 6:24 7:57
        7:61 8:cc 8:dd 9:1cc 9:1de 10:3d3 10:3e7 7:5d 6:21
        6:1f 6:23 6:27 7:59 7:64 8:d8 8:df 9:1d2 9:1e2
        10:3dd 10:3ee 8:d1 7:55 6:29 7:56 7:58 7:62 8:ce
        8:e0 8:e2 9:1da 10:3d4 10:3e3 11:7eb 9:1c9 7:5e 7:5a
        7:5c 7:63 8:ca 8:da 9:1c7 9:1ca 9:1e0 10:3db 10:3e8
        11:7ec 9:1e3 8:d2 8:cb 8:d0 8:d7 8:db 9:1c6 9:1d5
        9:1d8 10:3ca 10:3da 11:7ea 11:7f1 9:1e1 8:d4 8:cf 8:d6
        8:de 8:e1 9:1d0 9:1d6 10:3d1 10:3d5 10:3f2 11:7ee 11:7fb
        10:3e9 9:1cd 9:1c8 9:1cb 9:1d1 9:1d7 9:1df 10:3cf 10:3e0
        10:3ef 11:7e6 11:7f8 12:ffa 10:3eb 9:1dd 9:1d3 9:1d9 9:1db
        10:3d2 10:3cc 10:3dc 10:3ea 11:7ed 11:7f3 11:7f9 12:ff9 11:7f2
        10:3ce 9:1e4 10:3cb 10:3d8 10:3d6 10:3e2 10:3e5 11:7e8 11:7f4
        11:7f5 11:7f7 12:ffb 11:7fa 10:3ec 10:3df 10:3e1 10:3e4 10:3e6
        10:3f0 11:7e9 11:7ef 12:ff8 12:ffe 12:ffc 12:fff
    """,
    11: """
        4:0 5:6 6:19 7:3d 8:9c 8:c6 9:1a7 10:390 10:3c2
        10:3df 11:7e6 11:7f3 12:ffb 11:7ec 12:ffa 12:ffe 10:38e 5:5
        4:1 5:8 6:14 7:37 7:42 8:92 8:af 9:191 9:1a5
        9:1b5 10:39e 10:3c0 10:3a2 10:3cd 11:7d6 8:ae 6:17 5:7
        5:9 6:18 7:39 7:40 8:8e 8:a3 8:b8 9:199 9:1ac
        9:1c1 10:3b1 10:396 10:3be 10:3ca 8:9d 7:3c 6:15 6:16
        6:1a 7:3b 7:44 8:91 8:a5 8:be 9:196 9:1ae 9:1b9
        10:3a1 10:391 10:3a5 10:3d5 8:94 8:9a 7:36 7:38 7:3a
        7:41 8:8c 8:9b 8:b0 8:c3 9:19e 9:1ab 9:1bc 10:39f
        10:38f 10:3a9 10:3cf 8:93 8:bf 7:3e 7:3f 7:43 7:45
        8:9e 8:a7 8:b9 9:194 9:1a2 9:1ba 9:1c3 10:3a6 10:3a7
        10:3bb 10:3d4 8:9f 9:1a0 8:8f 8:8d 8:90 8:98 8:a6
        8:b6 8:c4 9:19f 9:1af 9:1bf 10:399 10:3bf 10:3b4 10:3c9
        10:3e7 8:a8 9:1b6 8:ab 8:a4 8:aa 8:b2 8:c2 8:c5
        9:198 9:1a4 9:1b8 10:38c 10:3a4 10:3c4 10:3c6 10:3dd 10:3e8
        8:ad 10:3af 9:192 8:bd 8:bc 9:18e 9:197 9:19a 9:1a3
        9:1b1 10:38d 10:398 10:3b7 10:3d3 10:3d1 10:3db 11:7dd 8:b4
        10:3de 9:1a9 9:19b 9:19c 9:1a1 9:1aa 9:1ad 9:1b3 10:38b
        10:3b2 10:3b8 10:3ce 10:3e1 10:3e0 11:7d2 11:7e5 8:b7 11:7e3
        9:1bb 9:1a8 9:1a6 9:1b0 9:1b2 9:1b7 10:39b 10:39a 10:3ba
        10:3b5 10:3d6 11:7d7 10:3e4 11:7d8 11:7ea 8:ba 11:7e8 10:3a0
        9:1bd 9:1b4 10:38a 9:1c4 10:392 10:3aa 10:3b0 10:3bc 10:3d7
        11:7d4 11:7dc 11:7db 11:7d5 11:7f0 8:c1 11:7fb 10:3c8 10:3a3
        10:395 10:39d 10:3ac 10:3ae 10:3c5 10:3d8 10:3e2 10:3e6 11:7e4
        11:7e7 11:7e0 11:7e9 11:7f7 9:190 11:7f2 10:393 9:1be 9:1c0
        10:394 10:397 10:3ad 10:3c3 10:3c1 10:3d2 11:7da 11:7d9 11:7df
        11:7eb 11:7f4 11:7fa 9:195 11:7f8 10:3bd 10:39c 10:3ab 10:3a8
        10:3b3 10:3b9 10:3d0 10:3e3 10:3e5 11:7e2 11:7de 11:7ed 11:7f1
        11:7f9 11:7fc 9:193 12:ffd 10:3dc 10:3b6 10:3c7 10:3cc 10:3cb
        10:3d9 10:3da 11:7d3 11:7e1 11:7ee 11:7ef 11:7f5 11:7f6 12:ffc
        12:fff 9:19d 9:1c2 8:b5 8:a1 8:96 8:97 8:95 8:99
        8:a0 8:a2 8:ac 8:a9 8:b1 8:b3 8:bb 8:c0 9:18f
        5:4
    """,
}

# value layout of each spectral book: (values per codeword, largest absolute
# value, signed?)  - Table 4.139 (spectrum Huffman codebooks parameters)
BOOKS = {1: (4, 1, True), 2: (4, 1, True), 3: (4, 2, False), 4: (4, 2, False),
         5: (2, 4, True), 6: (2, 4, True), 7: (2, 7, False), 8: (2, 7, False),
         9: (2, 12, False), 10: (2, 12, False), 11: (2, 16, False)}

# swb_offset tables. Key: the sampling frequency indices that use them.
SWB_LONG = {
    (0, 1): [0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 64, 72, 80, 88, 96,
             108, 120, 132, 144, 156, 172, 188, 212, 240, 276, 320, 384, 448, 512, 576, 640,
             704, 768, 832, 896, 960, 1024],
    (2,): [0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 64, 72, 80, 88, 100, 112,
           124, 140, 156, 172, 192, 216, 240, 268, 304, 344, 384, 424, 464, 504, 544, 584, 624,
           664, 704, 744, 784, 824, 864, 904, 944, 984, 1024],
    (3, 4): [0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72, 80, 88, 96, 108, 120, 132,
             144, 160, 176, 196, 216, 240, 264, 292, 320, 352, 384, 416, 448, 480, 512, 544,
             576, 608, 640, 672, 704, 736, 768, 800, 832, 864, 896, 928, 1024],
    (5,): [0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72, 80, 88, 96, 108, 120, 132,
           144, 160, 176, 196, 216, 240, 264, 292, 320, 352, 384, 416, 448, 480, 512, 544, 576,
           608, 640, 672, 704, 736, 768, 800, 832, 864, 896, 928, 960, 992, 1024],
    (6, 7): [0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 52, 60, 68, 76, 84, 92, 100, 108, 116,
             124, 136, 148, 160, 172, 188, 204, 220, 240, 260, 284, 308, 336, 364, 396, 432,
             468, 508, 552, 600, 652, 704, 768, 832, 896, 960, 1024],
    (8, 9, 10): [0, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 100, 112, 124, 136, 148, 160,
                 172, 184, 196, 212, 228, 244, 260, 280, 300, 320, 344, 368, 396, 424, 456, 492,
                 532, 572, 616, 664, 716, 772, 832, 896, 960, 1024],
    (11, 12): [0, 12, 24, 36, 48, 60, 72, 84, 96, 108, 120, 132, 144, 156, 172, 188, 204, 220,
               236, 252, 268, 288, 308, 328, 348, 372, 396, 420, 448, 476, 508, 544, 580, 620,
               664, 712, 764, 820, 880, 944, 1024],
}
SWB_SHORT = {
    (0, 1, 2): [0, 4, 8, 12, 16, 20, 24, 32, 40, 48, 64, 92, 128],
    (3, 4, 5): [0, 4, 8, 12, 16, 20, 28, 36, 44, 56, 68, 80, 96, 112, 128],
    (6, 7): [0, 4, 8, 12, 16, 20, 24, 28, 36, 44, 52, 64, 76, 92, 108, 128],
    (8, 9, 10): [0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 60, 72, 88, 108, 128],
    (11, 12): [0, 4, 8, 12, 16, 20, 24, 28, 36, 44, 52, 60, 72, 88, 108, 128],
}
NUM_SWB_LONG = [41, 41, 47, 49, 49, 51, 47, 47, 43, 43, 43, 40, 40]
NUM_SWB_SHORT = [12, 12, 12, 14, 14, 14, 15, 15, 15, 15, 15, 15, 15]
TNS_MAX_BANDS_LONG = [31, 31, 34, 40, 42, 51, 46, 46, 42, 42, 42, 39, 39]
TNS_MAX_BANDS_SHORT = [9, 9, 10, 14, 14, 14, 14, 14, 14, 14, 14, 14, 14]

FIRST_BITS = 8          # bits looked up at once by the first table level
SUB_BITS = 6            # at most this many bits per further level


# ------------------------------------------------------------- codebooks
def parse_books():
    books = {}
    for key, text in CODEBOOKS.items():
        entries = []
        for tok in text.split():
            n, code = tok.split(":")
            entries.append((int(n), int(code, 16)))
        books[key] = entries
    return books


def check_book(name, entries):
    """complete prefix code: Kraft sum 1 and no codeword is a prefix of another"""
    kraft = sum(Fraction(1, 1 << n) for n, _ in entries)
    assert kraft == 1, "codebook %s: Kraft sum %s" % (name, kraft)
    strs = sorted(format(c, "0%db" % n) for n, c in entries)
    for a, b in zip(strs, strs[1:]):
        assert not b.startswith(a), "codebook %s: %s is a prefix of %s" % (name, a, b)
    for n, c in entries:
        assert 0 < n <= 19 and c < (1 << n)


def leaf_value(book, index):
    """what a leaf of the decode table carries: the scale factor index, or
    the codeword's values packed (quads: 4 x 2 bits, pairs: 2 x 5 bits),
    each stored as value + LAV for signed books so they are never negative"""
    if book == "sf":
        return index
    dim, lav, signed = BOOKS[book]
    mod = 2 * lav + 1 if signed else lav + 1
    vals = []
    for _ in range(dim):
        vals.append(index % mod)
        index //= mod
    vals.reverse()                          # first value = most significant
    if dim == 4:
        w, x, y, z = vals
        return (w << 6) | (x << 4) | (y << 2) | z
    y, z = vals
    return (y << 5) | z


def build_table(codes, nbits):
    """codes: list of (length, code, value) relative to this level.
    Returns a list of entries; sub-tables are appended after the top one.
    Entry: leaf  = (length << 10) | value              (bit 15 clear)
           link  = 0x8000 | (subbits << 11) | offset   (offset from table start)"""
    table = [None] * (1 << nbits)
    subs = {}
    for n, c, v in codes:
        if n <= nbits:
            first = c << (nbits - n)
            for i in range(first, first + (1 << (nbits - n))):
                assert table[i] is None
                table[i] = (n << 10) | v
        else:
            top = c >> (n - nbits)
            subs.setdefault(top, []).append((n - nbits, c & ((1 << (n - nbits)) - 1), v))
    out = table
    for top in sorted(subs):
        sub = subs[top]
        sb = min(max(n for n, _, _ in sub), SUB_BITS)
        offset = len(out)
        subtab = build_table(sub, sb)
        # links inside the sub-table are relative to the sub-table: rebase
        for i, e in enumerate(subtab):
            if e & 0x8000:
                subtab[i] = (e & 0xF800) | ((e & 0x7FF) + offset)
        assert offset < 2048 and sb < 16
        out[top] = 0x8000 | (sb << 11) | offset
        out = out + subtab
    assert all(e is not None for e in out)
    return out


def decode_check(table, nbits, entries, book):
    """decode every codeword through the table, as aac.asm does"""
    for index, (n, c) in enumerate(entries):
        bits = c << (32 - n)                # MSB-aligned, then zeros
        pos, nb, base = 0, nbits, 0
        while True:
            e = table[base + (((bits << pos) & 0xFFFFFFFF) >> (32 - nb))]
            if e & 0x8000:
                pos += nb
                nb = (e >> 11) & 15
                base = e & 0x7FF
                continue
            pos += (e >> 10) & 31
            break
        assert pos == n and (e & 0x3FF) == leaf_value(book, index), (book, index)


# ------------------------------------------------------------- numbers
def f32(x):
    return struct.unpack("<I", struct.pack("<f", x))[0]


def bessel_i0(x):
    s, term, k = 1.0, 1.0, 1
    while term > 1e-30 * s:
        term *= (x / (2 * k)) ** 2
        s += term
        k += 1
    return s


def kbd_left(n_total, alpha):
    """rising half of the Kaiser-Bessel-derived window of length n_total"""
    half = n_total // 2
    w = [bessel_i0(math.pi * alpha * math.sqrt(1.0 - ((p - n_total / 4) / (n_total / 4)) ** 2))
         for p in range(half + 1)]
    total = sum(w)
    out, acc = [], 0.0
    for n in range(half):
        acc += w[n]
        out.append(math.sqrt(acc / total))
    return out


def sine_left(n_total):
    return [math.sin(math.pi / n_total * (n + 0.5)) for n in range(n_total // 2)]


def bitrev(i, bits):
    r = 0
    for _ in range(bits):
        r = (r << 1) | (i & 1)
        i >>= 1
    return r


# ------------------------------------------------------------- output
class Out:
    def __init__(self):
        self.asm = []
        self.c = []

    def comment(self, text):
        self.asm.append("; " + text)
        self.c.append("/* " + text + " */")

    def array(self, name, kind, values, per_line=8):
        """kind: 'dd' (uint32), 'df' (float, as bits), 'dw', 'db'"""
        asm_kind = {"df": "dd"}.get(kind, kind)
        self.asm.append("align 16")
        self.asm.append(name + ":")
        vals = [f32(v) if kind == "df" else v for v in values]
        fmt = {"dd": "0x%08x", "df": "0x%08x", "dw": "0x%04x", "db": "%d"}[kind]
        for i in range(0, len(vals), per_line):
            self.asm.append("    %s %s" % (asm_kind, ", ".join(fmt % v for v in vals[i:i + per_line])))
        ctype = {"dd": "uint32_t", "df": "uint32_t", "dw": "uint16_t", "db": "uint8_t"}[kind]
        self.c.append("static const %s %s[%d] __attribute__((aligned(16))) = {" % (ctype, name, len(vals)))
        for i in range(0, len(vals), per_line):
            self.c.append("    " + ", ".join(fmt % v for v in vals[i:i + per_line]) + ",")
        self.c.append("};")


def main():
    out = Out()
    books = parse_books()
    order = ["sf"] + list(range(1, 12))
    out.comment("Huffman decode tables, one per codebook (sf, 1..11). An entry is")
    out.comment("  leaf: (codeword bits used at this level << 10) | value   (bit 15 = 0)")
    out.comment("  link: 0x8000 | (index bits of the next level << 11) | its offset")
    out.comment("value: sf index; quads w,x,y,z as 2-bit fields (w in bits 7-6);")
    out.comment("pairs y,z as 5-bit fields (y in bits 9-5); signed books add LAV.")
    all_entries = []
    offsets = []
    for b in order:
        entries = books[b]
        check_book(b, entries)
        codes = [(n, c, leaf_value(b, i)) for i, (n, c) in enumerate(entries)]
        table = build_table(codes, FIRST_BITS)
        decode_check(table, FIRST_BITS, entries, b)
        offsets.append(len(all_entries))
        all_entries += table
    out.array("aac_hcb", "dw", all_entries, 12)
    out.comment("start of each codebook in aac_hcb (in entries): sf, 1..11")
    out.array("aac_hcb_start", "dd", offsets, 12)

    out.comment("swb_offset per sampling frequency index (0-12): long, short")
    long_rows, short_rows = [], []
    for sfi in range(13):
        lo = next(v for k, v in SWB_LONG.items() if sfi in k)
        sh = next(v for k, v in SWB_SHORT.items() if sfi in k)
        assert len(lo) == NUM_SWB_LONG[sfi] + 1 and len(sh) == NUM_SWB_SHORT[sfi] + 1
        assert lo[-1] == 1024 and sh[-1] == 128
        assert all(b > a and (b - a) % 4 == 0 for a, b in zip(lo, lo[1:]))
        assert all(b > a and (b - a) % 4 == 0 for a, b in zip(sh, sh[1:]))
        long_rows.append(lo + [1024] * (52 - len(lo)))
        short_rows.append(sh + [128] * (16 - len(sh)))
    out.comment("long: 52 words per rate (padded with 1024)")
    out.array("aac_swb_long", "dw", sum(long_rows, []), 13)
    out.comment("short: 16 words per rate (padded with 128)")
    out.array("aac_swb_short", "dw", sum(short_rows, []), 16)
    out.comment("per rate: num_swb long, num_swb short, TNS max bands long, short")
    rows = []
    for sfi in range(13):
        rows += [NUM_SWB_LONG[sfi], NUM_SWB_SHORT[sfi], TNS_MAX_BANDS_LONG[sfi],
                 TNS_MAX_BANDS_SHORT[sfi]]
    out.array("aac_rate_info", "db", rows, 4)
    rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025,
             8000, 7350]
    out.comment("sampling frequency of each index")
    out.array("aac_rates", "dd", rates, 7)

    out.comment("rising halves of the windows: sine and KBD (alpha 4), 2048 long;")
    out.comment("sine and KBD (alpha 6), 256 long")
    out.array("aac_win_sine_long", "df", sine_left(2048))
    out.array("aac_win_kbd_long", "df", kbd_left(2048, 4))
    out.array("aac_win_sine_short", "df", sine_left(256))
    out.array("aac_win_kbd_short", "df", kbd_left(256, 6))

    out.comment("|q|^(4/3) for q = 0..1023 (larger values are computed)")
    out.array("aac_pow43", "df", [q ** (4.0 / 3.0) for q in range(1024)])
    out.comment("2^(i/4), i = 0..3")
    out.array("aac_pow2q", "df", [2.0 ** (i / 4.0) for i in range(4)])

    out.comment("TNS coefficients: sin(c / iqfac) for 3-bit and 4-bit resolution,")
    out.comment("indexed by the signed value c + 8")
    for bits in (3, 4):
        iq = ((1 << (bits - 1)) - 0.5) / (math.pi / 2)
        iqm = ((1 << (bits - 1)) + 0.5) / (math.pi / 2)
        vals = []
        for c in range(-8, 8):
            vals.append(math.sin(c / (iq if c >= 0 else iqm)))
        out.array("aac_tns_coef%d" % bits, "df", vals)

    out.comment("inverse MDCT by a quarter-size complex FFT (see aac.asm). For M =")
    out.comment("1024 and 128 coefficients, phi = pi / (4M):")
    out.comment("  pre[p]  = cos, sin of phi*(4p+1), times 1/M (= 2/N, the IMDCT scale)")
    out.comment("  post[q] = cos, sin of 4*phi*q")
    for m, name in ((1024, "long"), (128, "short")):
        phi = math.pi / (4 * m)
        pre, post = [], []
        for p in range(m // 2):
            pre += [math.cos(phi * (4 * p + 1)) / m, math.sin(phi * (4 * p + 1)) / m]
            post += [math.cos(4 * phi * p), math.sin(4 * phi * p)]
        out.array("aac_pre_" + name, "df", pre)
        out.array("aac_post_" + name, "df", post)
        bits = (m // 2).bit_length() - 1
        out.array("aac_brev_" + name, "dw", [bitrev(i, bits) for i in range(m // 2)], 16)
    out.comment("FFT twiddles for the stages of length L = 4, 8, ..., 512, one stage")
    out.comment("after the other; per pair of butterflies j, j+1 (w = e^(-2 pi i j/L)):")
    out.comment("  re w(j), re w(j), re w(j+1), re w(j+1),")
    out.comment("  -im w(j), im w(j), -im w(j+1), im w(j+1)")
    tw = []
    L = 4
    while L <= 512:
        for j in range(0, L // 2, 2):
            w0 = complex(math.cos(2 * math.pi * j / L), -math.sin(2 * math.pi * j / L))
            w1 = complex(math.cos(2 * math.pi * (j + 1) / L), -math.sin(2 * math.pi * (j + 1) / L))
            tw += [w0.real, w0.real, w1.real, w1.real, -w0.imag, w0.imag, -w1.imag, w1.imag]
        L *= 2
    out.array("aac_fft_tw", "df", tw)

    head = ["; =============================================================================",
            ";  aac_tables.inc - constant tables of the AAC decoder (src/aac.asm)",
            ";  Generated by tools/gen_aac_tables.py - do not edit by hand.",
            "; =============================================================================",
            "section .data"]
    data = "\n".join(head + out.asm) + "\nsection .text\n"
    with open(OUT, "w") as f:
        f.write(data)
    size = sum(len(l) for l in out.asm)
    print("wrote", OUT)
    if "--c" in sys.argv:
        path = sys.argv[sys.argv.index("--c") + 1]
        with open(path, "w") as f:
            f.write("/* generated by tools/gen_aac_tables.py */\n#include <stdint.h>\n")
            f.write("\n".join(out.c) + "\n")
        print("wrote", path)


if __name__ == "__main__":
    main()
