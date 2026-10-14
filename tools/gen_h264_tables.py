#!/usr/bin/env python3
"""
Generate src/h264_tab.inc: the constant tables of the H.264 decoder (h264.asm).

    python tools/gen_h264_tables.py

The tables are typed from ITU-T Rec. H.264 (the variable length code tables of
clause 9.2, the dequantisation factors of 8.5.9, the chroma QP mapping of
Table 8-15, the deblocking thresholds of Tables 8-16 / 8-17 and the coded
block pattern mapping of Table 9-4), then checked: every code table must be
prefix free and use its code space fully (Kraft sum), and the coded block
pattern mappings must be permutations of 0..47.

Variable length codes are turned into small lookup tables indexed by the
number of leading zero bits and the next few bits after the first one bit
(see h264_vlc in h264.asm):
    db LZMAX, S, Z, 0          ; header (Z = 1: there is an all-zero code,
                               ; LZMAX bits long; more zeros still match it)
    dw entries[(LZMAX + 1) << S]
Each entry: low byte = code length in bits (0 = not a valid code), high byte =
the decoded value. A table with an all-zero code of n bits has LZMAX = n
and Z = 1, so that the all-zero code can be looked up too; without one, more
than LZMAX leading zeros is not a valid code.
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "src", "h264_tab.inc")

# --------------------------------------------------------------------------
# coeff_token (Table 9-5). For each nC range: code length and code value,
# indexed [TrailingOnes][TotalCoeff].
CT_LEN = [
    [  # 0 <= nC < 2
        [1, 6, 8, 9, 10, 11, 13, 13, 13, 14, 14, 15, 15, 16, 16, 16, 16],
        [0, 2, 6, 8, 9, 10, 11, 13, 13, 14, 14, 15, 15, 15, 16, 16, 16],
        [0, 0, 3, 7, 8, 9, 10, 11, 13, 13, 14, 14, 15, 15, 16, 16, 16],
        [0, 0, 0, 5, 6, 7, 8, 9, 10, 11, 13, 14, 14, 15, 15, 16, 16],
    ],
    [  # 2 <= nC < 4
        [2, 6, 6, 7, 8, 8, 9, 11, 11, 12, 12, 12, 13, 13, 13, 14, 14],
        [0, 2, 5, 6, 6, 7, 8, 9, 11, 11, 12, 12, 13, 13, 14, 14, 14],
        [0, 0, 3, 6, 6, 7, 8, 9, 11, 11, 12, 12, 13, 13, 13, 14, 14],
        [0, 0, 0, 4, 4, 5, 6, 6, 7, 9, 11, 11, 12, 13, 13, 13, 14],
    ],
    [  # 4 <= nC < 8
        [4, 6, 6, 6, 7, 7, 7, 7, 8, 8, 9, 9, 9, 10, 10, 10, 10],
        [0, 4, 5, 5, 5, 5, 6, 6, 7, 8, 8, 9, 9, 9, 10, 10, 10],
        [0, 0, 4, 5, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 10],
        [0, 0, 0, 4, 4, 4, 4, 4, 5, 6, 7, 8, 8, 9, 10, 10, 10],
    ],
]
CT_CODE = [
    [
        [1, 5, 7, 7, 7, 7, 15, 11, 8, 15, 11, 15, 11, 15, 11, 7, 4],
        [0, 1, 4, 6, 6, 6, 6, 14, 10, 14, 10, 14, 10, 1, 14, 10, 6],
        [0, 0, 1, 5, 5, 5, 5, 5, 13, 9, 13, 9, 13, 9, 13, 9, 5],
        [0, 0, 0, 3, 3, 4, 4, 4, 4, 4, 12, 12, 8, 12, 8, 12, 8],
    ],
    [
        [3, 11, 7, 7, 7, 4, 7, 15, 11, 15, 11, 8, 15, 11, 7, 9, 7],
        [0, 2, 7, 10, 6, 6, 6, 6, 14, 10, 14, 10, 14, 10, 11, 8, 6],
        [0, 0, 3, 9, 5, 5, 5, 5, 13, 9, 13, 9, 13, 9, 6, 10, 5],
        [0, 0, 0, 5, 4, 6, 8, 4, 4, 4, 12, 8, 12, 12, 8, 1, 4],
    ],
    [
        [15, 15, 11, 8, 15, 11, 9, 8, 15, 11, 15, 11, 8, 13, 9, 5, 1],
        [0, 14, 15, 12, 10, 8, 14, 10, 14, 14, 10, 14, 10, 7, 12, 8, 4],
        [0, 0, 13, 14, 11, 9, 13, 9, 13, 10, 13, 9, 13, 9, 11, 7, 3],
        [0, 0, 0, 12, 11, 10, 9, 8, 13, 12, 12, 12, 8, 12, 10, 6, 2],
    ],
]
# nC == -1 (chroma DC, 4:2:0): [TrailingOnes][TotalCoeff 0..4]
CTC_LEN = [[2, 6, 6, 6, 6], [0, 1, 6, 7, 8], [0, 0, 3, 7, 8], [0, 0, 0, 6, 7]]
CTC_CODE = [[1, 7, 4, 3, 2], [0, 1, 6, 3, 3], [0, 0, 1, 2, 2], [0, 0, 0, 5, 0]]

# total_zeros for 4x4 blocks (Tables 9-7, 9-8), index TotalCoeff 1..15,
# listed for total_zeros = 0, 1, 2, ...
TZ = {
    1: "1 011 010 0011 0010 00011 00010 000011 000010 0000011 0000010 00000011 00000010 000000011 000000010 000000001",
    2: "111 110 101 100 011 0101 0100 0011 0010 00011 00010 000011 000010 000001 000000",
    3: "0101 111 110 101 0100 0011 100 011 0010 00011 00010 000001 00001 000000",
    4: "00011 111 0101 0100 110 101 100 0011 011 0010 00010 00001 00000",
    5: "0101 0100 0011 111 110 101 100 011 0010 00001 0001 00000",
    6: "000001 00001 111 110 101 100 011 010 0001 001 000000",
    7: "000001 00001 101 100 011 11 010 0001 001 000000",
    8: "000001 0001 00001 011 11 10 010 001 000000",
    9: "000001 000000 0001 11 10 001 01 00001",
    10: "00001 00000 001 11 10 01 0001",
    11: "0000 0001 001 010 1 011",
    12: "0000 0001 01 1 001",
    13: "000 001 1 01",
    14: "00 01 1",
    15: "0 1",
}
# total_zeros for the 2x2 chroma DC block (Table 9-9 a), TotalCoeff 1..3
TZC = {1: "1 01 001 000", 2: "1 01 00", 3: "1 0"}
# run_before (Table 9-10), zerosLeft 1..6 and > 6 (index 7)
RB = {
    1: "1 0",
    2: "1 01 00",
    3: "11 10 01 00",
    4: "11 10 01 001 000",
    5: "11 10 011 010 001 000",
    6: "11 000 001 011 010 101 100",
    7: "111 110 101 100 011 010 001 0001 00001 000001 0000001 00000001 "
       "000000001 0000000001 00000000001",
}

# coded_block_pattern for Intra_4x4 and Inter macroblocks (Table 9-4,
# chroma_format_idc 1 or 2), indexed by codeNum
CBP_INTRA = [47, 31, 15, 0, 23, 27, 29, 30, 7, 11, 13, 14, 39, 43, 45, 46,
             16, 3, 5, 10, 12, 19, 21, 26, 28, 35, 37, 42, 44, 1, 2, 4,
             8, 17, 18, 20, 24, 6, 9, 22, 25, 32, 33, 34, 36, 40, 38, 41]
CBP_INTER = [0, 16, 1, 2, 4, 8, 32, 3, 5, 10, 12, 15, 47, 7, 11, 13,
             14, 6, 9, 31, 35, 37, 42, 44, 33, 34, 36, 40, 39, 43, 45, 46,
             17, 18, 20, 24, 19, 21, 26, 28, 23, 27, 29, 30, 22, 25, 38, 41]

# 4x4 zig-zag scan (frame macroblocks): scan index -> raster position
ZIGZAG = [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15]

# normAdjust4x4 (8.5.9): v[m][class], class 0: both coordinates even,
# 1: both odd, 2: otherwise
NORM = [[10, 16, 13], [11, 18, 14], [13, 20, 16], [14, 23, 18], [16, 25, 20], [18, 29, 23]]

# Table 8-15: QPc for qPi = 30..51 (below 30 QPc = qPi)
QPC_HI = [29, 30, 31, 32, 32, 33, 34, 34, 35, 35, 36, 36, 37, 37, 37, 38, 38, 38, 39, 39, 39, 39]

# Table 8-16: alpha' and beta' for indexA / indexB 16..51 (0 below 16)
ALPHA = [4, 4, 5, 6, 7, 8, 9, 10, 12, 13, 15, 17, 20, 22, 25, 28, 32, 36, 40, 45, 50,
         56, 63, 71, 80, 90, 101, 113, 127, 144, 162, 182, 203, 226, 255, 255]
BETA = [2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12,
        13, 13, 14, 14, 15, 15, 16, 16, 17, 17, 18, 18]
# Table 8-17: tC0' for bS = 1, 2, 3 and indexA 17..51 (0 below 17)
TC0 = [
    [0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5, 6, 6,
     7, 8, 9, 10, 11, 13],
    [0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 4, 4, 5, 5, 6, 7, 8, 8,
     10, 11, 12, 13, 15, 17],
    [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5, 6, 6, 7, 8, 9, 10, 11,
     13, 14, 16, 18, 20, 23, 25],
]


# --------------------------------------------------------------------------
def bits(length, code):
    return format(code, "0%db" % length)


def check_code(name, codes, complete=True):
    """codes: list of (bitstring, value). Prefix free; Kraft sum (= 1 when
    complete). Returns the Kraft sum."""
    strs = [c for c, _ in codes]
    for i, a in enumerate(strs):
        for j, b in enumerate(strs):
            if i != j and b.startswith(a):
                raise SystemExit("%s: code %s is a prefix of %s" % (name, a, b))
    kraft = sum(2.0 ** -len(c) for c in strs)
    if kraft > 1.0 + 1e-12 or (complete and abs(kraft - 1.0) > 1e-12):
        raise SystemExit("%s: Kraft sum %.10f" % (name, kraft))
    return kraft


def lz_table(name, codes):
    """Lookup table indexed by min(leading zeros, LZMAX) << S | next S bits."""
    lzmax, s, zero = 0, 0, 0
    for c, _ in codes:
        lz = len(c) - len(c.lstrip("0"))
        if lz == len(c):                    # the all-zero code
            lzmax = max(lzmax, lz)
            zero = 1
        else:
            lzmax = max(lzmax, lz)
            s = max(s, len(c) - lz - 1)
    rows = lzmax + 1
    tab = [0] * (rows << s)
    for c, v in codes:
        assert 0 <= v < 256 and len(c) < 256
        lz = len(c) - len(c.lstrip("0"))
        if lz == len(c):
            for k in range(1 << s):
                assert tab[(lz << s) | k] == 0
                tab[(lz << s) | k] = len(c) | (v << 8)
            continue
        suf = c[lz + 1:]
        pad = s - len(suf)
        for k in range(1 << pad):
            idx = (lz << s) | (int(suf, 2) << pad if suf else 0) | k
            assert tab[idx] == 0, (name, c)
            tab[idx] = len(c) | (v << 8)
    out = ["%s:" % name, "    db %d, %d, %d, 0" % (lzmax, s, zero)]
    for i in range(0, len(tab), 8):
        out.append("    dw " + ", ".join("0x%04X" % x for x in tab[i:i + 8]))
    return out


def check_tables():
    for t in range(3):
        codes = []
        for t1 in range(4):
            for tc in range(17):
                if t1 > tc or (t1 == 0 and tc == 0 and False):
                    continue
                ln = CT_LEN[t][t1][tc]
                if t1 <= tc and ln:
                    codes.append((bits(ln, CT_CODE[t][t1][tc]), tc | (t1 << 5)))
                elif t1 <= tc:
                    raise SystemExit("coeff_token table %d: missing %d/%d" % (t, t1, tc))
        assert len(codes) == 62
        check_code("coeff_token %d" % t, codes, complete=False)
    codes = []
    for t1 in range(4):
        for tc in range(5):
            if t1 <= tc:
                codes.append((bits(CTC_LEN[t1][tc], CTC_CODE[t1][tc]), tc | (t1 << 5)))
    check_code("coeff_token chroma DC", codes)
    for tc, s in TZ.items():
        c = s.split()
        assert len(c) == 17 - tc, tc
        # (TotalCoeff 1 leaves the all-zero 9-bit code unused)
        check_code("total_zeros %d" % tc, [(x, i) for i, x in enumerate(c)], complete=tc != 1)
    for tc, s in TZC.items():
        c = s.split()
        assert len(c) == 5 - tc
        check_code("total_zeros chroma DC %d" % tc, [(x, i) for i, x in enumerate(c)])
    for zl, s in RB.items():
        c = s.split()
        assert len(c) == (zl + 1 if zl < 7 else 15)
        # (zerosLeft > 6 leaves the all-zero 11-bit code unused)
        check_code("run_before %d" % zl, [(x, i) for i, x in enumerate(c)], complete=zl != 7)
    assert sorted(CBP_INTRA) == list(range(48)) and sorted(CBP_INTER) == list(range(48))
    assert sorted(ZIGZAG) == list(range(16))
    assert len(QPC_HI) == 22 and len(ALPHA) == 36 and len(BETA) == 36
    assert all(len(r) == 35 for r in TC0)


# --------------------------------------------------------------------------
# Intra_4x4 prediction modes 3..8 (8.3.1.2.4 - 8.3.1.2.9) as operations on
# the edge array E: E[0] = E[1] = L3, E[2] = L2, E[3] = L1, E[4] = L0,
# E[5] = Q (top-left), E[6..13] = T0..T7, E[14] = T7 (L = left column,
# T = row above, with the top-right samples). Each predicted sample is
# op 0: E[i]; op 1: (E[i] + E[i+1] + 1) >> 1; op 2: (E[i-1] + 2 E[i] +
# E[i+1] + 2) >> 2, stored as op << 4 | i.
def i4_ops():
    ops = {}
    for mode in range(3, 9):
        row = []
        for y in range(4):
            for x in range(4):
                if mode == 3:                       # diagonal down left
                    op = (2, 13) if x == 3 and y == 3 else (2, 7 + x + y)
                elif mode == 4:                     # diagonal down right
                    op = (2, 5 + x - y)
                elif mode == 5:                     # vertical right
                    z = 2 * x - y
                    k = x - (y >> 1)
                    if z >= 0 and z % 2 == 0:
                        op = (1, 5 + k)
                    elif z >= 0:
                        op = (2, 5 + k)
                    elif z == -1:
                        op = (2, 5)
                    else:
                        op = (2, 6 - y)
                elif mode == 6:                     # horizontal down
                    z = 2 * y - x
                    k = y - (x >> 1)
                    if z >= 0 and z % 2 == 0:
                        op = (1, 4 - k)
                    elif z >= 0:
                        op = (2, 5 - k)
                    elif z == -1:
                        op = (2, 5)
                    else:
                        op = (2, 4 + x)
                elif mode == 7:                     # vertical left
                    k = x + (y >> 1)
                    op = (1, 6 + k) if y % 2 == 0 else (2, 7 + k)
                else:                               # horizontal up
                    z = x + 2 * y
                    k = y + (x >> 1)
                    if z > 5:
                        op = (0, 1)
                    elif z == 5:
                        op = (2, 1)
                    elif z % 2 == 0:
                        op = (1, 3 - k)
                    else:
                        op = (2, 3 - k)
                row.append(op)
        ops[mode] = row
    return ops


def i4_reference(mode, L, Q, T):
    """The formulas as written in the standard, for checking."""
    P = lambda x, y: Q if (x == -1 and y == -1) else (L[y] if x == -1 else T[x])
    out = []
    for y in range(4):
        for x in range(4):
            if mode == 3:
                v = (T[6] + 3 * T[7] + 2) >> 2 if x == 3 and y == 3 else \
                    (T[x + y] + 2 * T[x + y + 1] + T[x + y + 2] + 2) >> 2
            elif mode == 4:
                if x > y:
                    v = (P(x - y - 2, -1) + 2 * P(x - y - 1, -1) + P(x - y, -1) + 2) >> 2
                elif x < y:
                    v = (P(-1, y - x - 2) + 2 * P(-1, y - x - 1) + P(-1, y - x) + 2) >> 2
                else:
                    v = (P(0, -1) + 2 * Q + P(-1, 0) + 2) >> 2
            elif mode == 5:
                z = 2 * x - y
                if z >= 0 and z % 2 == 0:
                    v = (P(x - (y >> 1) - 1, -1) + P(x - (y >> 1), -1) + 1) >> 1
                elif z >= 0:
                    v = (P(x - (y >> 1) - 2, -1) + 2 * P(x - (y >> 1) - 1, -1) + P(x - (y >> 1), -1) + 2) >> 2
                elif z == -1:
                    v = (P(-1, 0) + 2 * Q + P(0, -1) + 2) >> 2
                else:
                    v = (P(-1, y - 1) + 2 * P(-1, y - 2) + P(-1, y - 3) + 2) >> 2
            elif mode == 6:
                z = 2 * y - x
                if z >= 0 and z % 2 == 0:
                    v = (P(-1, y - (x >> 1) - 1) + P(-1, y - (x >> 1)) + 1) >> 1
                elif z >= 0:
                    v = (P(-1, y - (x >> 1) - 2) + 2 * P(-1, y - (x >> 1) - 1) + P(-1, y - (x >> 1)) + 2) >> 2
                elif z == -1:
                    v = (P(-1, 0) + 2 * Q + P(0, -1) + 2) >> 2
                else:
                    v = (P(x - 1, -1) + 2 * P(x - 2, -1) + P(x - 3, -1) + 2) >> 2
            elif mode == 7:
                if y % 2 == 0:
                    v = (T[x + (y >> 1)] + T[x + (y >> 1) + 1] + 1) >> 1
                else:
                    v = (T[x + (y >> 1)] + 2 * T[x + (y >> 1) + 1] + T[x + (y >> 1) + 2] + 2) >> 2
            else:
                z = x + 2 * y
                if z % 2 == 0 and z < 5:
                    v = (L[y + (x >> 1)] + L[y + (x >> 1) + 1] + 1) >> 1
                elif z < 5:
                    v = (L[y + (x >> 1)] + 2 * L[y + (x >> 1) + 1] + L[y + (x >> 1) + 2] + 2) >> 2
                elif z == 5:
                    v = (L[2] + 3 * L[3] + 2) >> 2
                else:
                    v = L[3]
            out.append(v)
    return out


def check_i4(ops):
    import random
    rnd = random.Random(1)
    for _ in range(2000):
        L = [rnd.randrange(256) for _ in range(4)]
        T = [rnd.randrange(256) for _ in range(8)]
        Q = rnd.randrange(256)
        E = [L[3], L[3], L[2], L[1], L[0], Q] + T + [T[7]]
        for mode in range(3, 9):
            ref = i4_reference(mode, L, Q, T)
            got = []
            for op, i in ops[mode]:
                if op == 0:
                    got.append(E[i])
                elif op == 1:
                    got.append((E[i] + E[i + 1] + 1) >> 1)
                else:
                    got.append((E[i - 1] + 2 * E[i] + E[i + 1] + 2) >> 2)
            assert got == ref, (mode, got, ref)


def main():
    check_tables()
    ops = i4_ops()
    check_i4(ops)
    o = ["; =============================================================================",
         ";  h264_tab.inc - constant tables of the H.264 decoder (h264.asm)",
         ";",
         ";  GENERATED by tools/gen_h264_tables.py from the tables of ITU-T H.264",
         ";  (do not edit by hand; edit and run the script). See the script for the",
         ";  layout of the variable length code lookup tables.",
         "; =============================================================================",
         "section .data", "align 4"]
    # coeff_token
    for t in range(3):
        codes = []
        for t1 in range(4):
            for tc in range(t1, 17):
                codes.append((bits(CT_LEN[t][t1][tc], CT_CODE[t][t1][tc]), tc | (t1 << 5)))
        o += ["; coeff_token, %s (value = TotalCoeff | TrailingOnes << 5)" %
              ["0 <= nC < 2", "2 <= nC < 4", "4 <= nC < 8"][t], "align 4"]
        o += lz_table("h264_ct%d" % t, codes)
    codes = []
    for t1 in range(4):
        for tc in range(t1, 5):
            codes.append((bits(CTC_LEN[t1][tc], CTC_CODE[t1][tc]), tc | (t1 << 5)))
    o += ["; coeff_token, chroma DC (nC = -1)", "align 4"] + lz_table("h264_ctc", codes)
    for tc, s in TZ.items():
        o += ["; total_zeros, TotalCoeff = %d" % tc, "align 4"]
        o += lz_table("h264_tz%d" % tc, [(x, i) for i, x in enumerate(s.split())])
    for tc, s in TZC.items():
        o += ["; total_zeros, chroma DC, TotalCoeff = %d" % tc, "align 4"]
        o += lz_table("h264_tzc%d" % tc, [(x, i) for i, x in enumerate(s.split())])
    for zl, s in RB.items():
        o += ["; run_before, zerosLeft %s" % (zl if zl < 7 else "> 6"), "align 4"]
        o += lz_table("h264_rb%d" % zl, [(x, i) for i, x in enumerate(s.split())])
    o += ["align 4", "; total_zeros tables by TotalCoeff (entry 0 unused)",
          "h264_tz_tab: dd 0, " + ", ".join("h264_tz%d" % i for i in range(1, 16)),
          "h264_tzc_tab: dd 0, h264_tzc1, h264_tzc2, h264_tzc3",
          "; run_before tables by zerosLeft (1..6, then > 6 for 7..14)",
          "h264_rb_tab: dd 0, " + ", ".join("h264_rb%d" % min(i, 7) for i in range(1, 15)),
          "h264_ct_tab: dd h264_ct0, h264_ct0, h264_ct1, h264_ct1, h264_ct2, h264_ct2, "
          "h264_ct2, h264_ct2"]
    o += ["; coded_block_pattern by codeNum: Intra_4x4, Inter (Table 9-4)",
          "h264_cbp_intra: db " + ", ".join(map(str, CBP_INTRA)),
          "h264_cbp_inter: db " + ", ".join(map(str, CBP_INTER)),
          "; 4x4 zig-zag scan: scan index -> raster position (y * 4 + x)",
          "h264_zigzag: db " + ", ".join(map(str, ZIGZAG))]
    # dequantisation: LevelScale4x4 / 16 << (qP / 6) = v(qP % 6, pos) << (qP / 6)
    o += ["; 4x4 dequantisation factor for qP 0..51 at each raster position:",
          "; normAdjust4x4(qP % 6, i, j) << (qP / 6) (flat scaling matrices)",
          "align 4", "h264_dq4:"]
    for qp in range(52):
        row = []
        for pos in range(16):
            i, j = pos % 4, pos // 4
            cls = 0 if (i % 2 == 0 and j % 2 == 0) else (1 if (i % 2 == 1 and j % 2 == 1) else 2)
            row.append(NORM[qp % 6][cls] << (qp // 6))
        o.append("    dd " + ", ".join(map(str, row)))
    o += ["; normAdjust4x4(m, 0, 0) * 16 = LevelScale4x4 of the DC position, by qP % 6",
          "h264_ls0: dd " + ", ".join(str(NORM[m][0] * 16) for m in range(6))]
    qpc = [q if q < 30 else QPC_HI[q - 30] for q in range(52)]
    o += ["; QPc from qPi (Table 8-15)", "h264_qpc: db " + ", ".join(map(str, qpc))]
    alpha = [0] * 16 + ALPHA
    beta = [0] * 16 + BETA
    o += ["; deblocking thresholds by indexA / indexB (Table 8-16)",
          "h264_alpha: db " + ", ".join(map(str, alpha)),
          "h264_beta: db " + ", ".join(map(str, beta)),
          "; tC0 by indexA * 4 + bS (bS 1..3; Table 8-17)", "h264_tc0:"]
    for ia in range(52):
        vals = [0] + [TC0[b][ia - 17] if ia >= 17 else 0 for b in range(3)]
        o.append("    db " + ", ".join(map(str, vals)))
    # macroblock geometry: 4x4 block index (bitstream order) -> x, y in 4x4 units
    bx = [0, 1, 0, 1, 2, 3, 2, 3, 0, 1, 0, 1, 2, 3, 2, 3]
    by = [0, 0, 1, 1, 0, 0, 1, 1, 2, 2, 3, 3, 2, 2, 3, 3]
    o += ["; luma 4x4 block index (bitstream order) -> raster index y * 4 + x",
          "h264_blk_r: db " + ", ".join(str(by[i] * 4 + bx[i]) for i in range(16)),
          "; raster index -> 4x4 block index",
          "h264_r_blk: db " + ", ".join(str(next(i for i in range(16) if by[i] * 4 + bx[i] == r))
                                        for r in range(16))]
    o += ["; Intra_4x4 modes 3..8: per sample (raster) op << 4 | index into the edge",
          "; array (see tools/gen_h264_tables.py)", "h264_i4tab:"]
    for mode in range(3, 9):
        o.append("    db " + ", ".join("0x%02X" % (op << 4 | i) for op, i in ops[mode]))
    text = "\n".join(o) + "\n"
    open(OUT, "w").write(text)
    print("wrote", OUT, len(text), "bytes")


if __name__ == "__main__":
    main()
