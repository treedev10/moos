#!/usr/bin/env python3
"""
Find (or check) the AAC Huffman codebooks by probing a reference decoder.

    python tools/aac_probe_codebooks.py --check       check every codeword in
                                                      tools/gen_aac_tables.py
    python tools/aac_probe_codebooks.py OUT.json      find all 12 codebooks

The codebooks are tables of the standard (ISO/IEC 14496-3, Annex 4.A). To
get them without a copy of the standard at hand, this tool treats ffmpeg's
decoder as a black box: it builds tiny ADTS streams by hand - one mono frame
whose band 0 is coded with the book under test, then a silent frame - and
decodes them to float PCM. A least-squares fit of the first eight inverse-
MDCT basis functions to the output gives back the dequantised spectrum, so
each probe tells whether a bit string was accepted and which values it
stood for.

Finding: a walk over the code tree, level by level. A bit string q is a
whole codeword when a frame "q, sign bits (+), escapes, END" decodes to a
symbol with exactly that many nonzero values (pair books: the band has two
pairs, so q is sent twice). Scale factor codes are found the same way, with
a known codebook-1 codeword in the band and the delta read from the output
level (each step of the scale factor is 2^(1/4)).

Checking: every codeword is sent once more in a different context (random
signs, other escape values, a different second codeword) and must decode to
its table values. Needs ffmpeg and numpy; takes a few minutes.
"""
import json
import os
import random
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

import numpy as np

N = 2048
_n = np.arange(N) + 0.5 + N / 4                    # n + n0, n0 = (N/2 + 1)/2
_win = np.sin(np.pi * (np.arange(N) + 0.5) / N)
NK = 8
BASIS = np.array([(2.0 / N) * np.cos(2 * np.pi / N * _n * (k + 0.5)) * _win / 32768.0
                  for k in range(NK)]).T

BOOKS = {1: (4, 1, True), 2: (4, 1, True), 3: (4, 2, False), 4: (4, 2, False),
         5: (2, 4, True), 6: (2, 4, True), 7: (2, 7, False), 8: (2, 7, False),
         9: (2, 12, False), 10: (2, 12, False), 11: (2, 16, False)}


def bits(n, v):
    return format(v, "0%db" % n) if n else ""


def pack(bitstr):
    bitstr += "0" * ((-len(bitstr)) % 8)
    return bytes(int(bitstr[i:i + 8], 2) for i in range(0, len(bitstr), 8))


def adts(raw, sfi=4, ch=1):
    n = len(raw) + 7
    h = "111111111111" + "0" + "00" + "1" + "01" + bits(4, sfi) + "0" + bits(3, ch)
    h += "0000" + bits(13, n) + bits(11, 0x7FF) + "00"
    return pack(h) + raw


# a silent frame: SCE, long window, max_sfb 0, END
ZERO = adts(pack("000" + "0000" + bits(8, 100) + "0" + "00" + "0" + bits(6, 0) + "0" + "000" + "111"))


def frame(cb, spec, gain=100, sfcode="0"):
    """SCE, long window, band 0 coded with book cb, scale factor delta code
    sfcode ('0' = +0), no pulse/TNS/gain control, then the spectral bits
    (which must end with END = 111)"""
    s = "000" + "0000" + bits(8, gain) + "0" + "00" + "0" + bits(6, 1) + "0"
    s += bits(4, cb) + bits(5, 1) + sfcode + "000" + spec
    return adts(pack(s))


def run(stream):
    """fitted spectrum (8 coefficients) of the probe frame, or None if ffmpeg
    rejected it"""
    p = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-threads", "1", "-f", "aac",
                        "-i", "-", "-f", "f32le", "-"], input=stream + ZERO, capture_output=True)
    out = np.frombuffer(p.stdout, dtype="<f4").astype(np.float64)
    if len(out) != 2 * 1024:
        return None
    c = np.linalg.lstsq(BASIS, out, rcond=None)[0]
    if np.sqrt(np.sum((BASIS @ c - out) ** 2)) > 1e-4 * max(np.sqrt(np.sum(out ** 2)), 1e-12):
        return None
    return c


def quant(c):
    """dequantised values (gain 1) -> integers, or None if not q^(4/3).
    (The fit is as exact as the float output, about 1e-7 of the largest
    value in the band.)"""
    out = []
    floor = 1e-5 * max(abs(x) for x in c)
    for v in c:
        q = round(abs(v) ** 0.75)
        if abs(q ** (4.0 / 3.0) - abs(v)) > 1e-3 * max(1, abs(v)) + floor:
            return None
        out.append(int(q) if v >= 0 else -int(q))
    return out


def leaf_test(cb, q):
    """values of the symbol if bit string q is a whole codeword of book cb"""
    dim, lav, signed = BOOKS[cb]
    if dim == 4:
        for s in ([0] if signed else [0, 1, 2, 3, 4]):
            c = run(frame(cb, q + "0" * s + "111"))
            v = quant(c) if c is not None else None
            if v is None or any(v[4:]):
                continue
            v = v[:4]
            if not signed and (sum(1 for x in v if x) != s or any(x < 0 for x in v)):
                continue
            return v
        return None
    hyps = [(0, 0)] if signed else [(0, 0), (1, 0), (2, 0)]
    if cb == 11:
        hyps += [(1, 1), (2, 1), (2, 2)]
    for s, e in hyps:
        tail = "0" * (s + 5 * e)                    # + signs, escapes "0 0000" = 16
        c = run(frame(cb, q + tail + q + tail + "111"))
        v = quant(c) if c is not None else None
        if v is None or any(v[4:]) or v[0:2] != v[2:4]:
            continue
        p = v[0:2]
        if not signed and (any(x < 0 for x in p) or sum(1 for x in p if x) != s
                           or sum(1 for x in p if x == 16) != e):
            continue
        return p
    return None


def sf_test(q, k1):
    """scale factor index if q is a whole scale factor codeword"""
    code, k1v = k1
    c = run(frame(1, code + "111", gain=100, sfcode=q))
    if c is None:
        return None
    ref = np.array(k1v, dtype=float)
    i = int(np.argmax(np.abs(ref)))
    if c[i] == 0 or np.sign(c[i]) != np.sign(ref[i]):
        return None
    d = 4 * np.log2(abs(c[i]) / abs(ref[i]))
    di = round(d)
    if abs(d - di) > 1e-3:
        return None
    scaled = ref * 2.0 ** (di / 4.0)
    big = max(1, np.max(np.abs(scaled)))
    if np.max(np.abs(c[:4] - scaled)) > 1e-3 * big or np.max(np.abs(c[4:])) > 1e-5 * big:
        return None
    return [di + 60]


def walk(test, maxdepth):
    leaves, level = {}, ["0", "1"]
    with ThreadPoolExecutor(8) as pool:
        while level:
            nxt = []
            for q, v in zip(level, pool.map(test, level)):
                if v is not None:
                    leaves[q] = v
                elif len(q) < maxdepth:
                    nxt += [q + "0", q + "1"]
                else:
                    sys.exit("no codeword found below " + q)
            level = nxt
    return leaves


def find(path):
    result = {}
    for cb in range(1, 12):
        print("codebook", cb, file=sys.stderr)
        result[str(cb)] = walk(lambda q: leaf_test(cb, q), 17)
    k1 = next((c, v) for c, v in sorted(result["1"].items(), key=lambda t: len(t[0])) if any(v))
    print("scale factor codebook", file=sys.stderr)
    result["sf"] = walk(lambda q: sf_test(q, k1), 20)
    json.dump(result, open(path, "w"), indent=0, sort_keys=True)
    print("wrote", path, file=sys.stderr)


# ----------------------------------------------------------------- checking
def table_books():
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import gen_aac_tables
    return gen_aac_tables.parse_books()


def values_of(cb, index):
    dim, lav, signed = BOOKS[cb]
    mod = 2 * lav + 1 if signed else lav + 1
    vals = []
    for _ in range(dim):
        vals.append(index % mod)
        index //= mod
    vals.reverse()
    return [v - lav for v in vals] if signed else vals


def code_str(entry):
    n, c = entry
    return bits(n, c)


def coded(cb, vals, rnd):
    """bits for one codeword's worth of values (unsigned books: random signs;
    escape values for 16s) and the values the decoder should give"""
    dim, lav, signed = BOOKS[cb]
    if signed:
        return vals, ""
    out, signs, esc = [], "", ""
    for v in vals:
        if v and rnd.random() < 0.5:
            signs += "1"
            out.append(-v)
        else:
            signs += "0" if v else ""
            out.append(v)
    if cb == 11:
        for i, v in enumerate(vals):
            if v == 16:
                n = rnd.randint(0, 8)               # escape: n ones, 0, n+4 bits
                word = rnd.randint(0, (1 << (n + 4)) - 1)
                esc += "1" * n + "0" + bits(n + 4, word)
                big = (1 << (n + 4)) + word
                out[i] = -big if out[i] < 0 else big
    return out, signs + esc


def check_one(args):
    cb, index, books, seed = args
    rnd = random.Random(seed)
    if cb == "sf":
        # band 0: book 1 codeword for (1, 0, 0, 0) at gain 100; delta = index - 60
        k1i = 2 * 27 + 1 * 9 + 1 * 3 + 1
        delta = index - 60
        gain = 100 - delta if delta > 0 else 100
        c = run(frame(1, code_str(books[1][k1i]) + "111", gain=gain,
                      sfcode=code_str(books["sf"][index])))
        if c is None:
            return False
        want = 2.0 ** ((gain + delta - 100) / 4.0)
        return abs(c[0] - want) < 1e-3 * want and np.max(np.abs(c[1:])) < 1e-5 * want
    dim, lav, signed = BOOKS[cb]
    if dim == 4:
        v, extra = coded(cb, values_of(cb, index), rnd)
        c = run(frame(cb, code_str(books[cb][index]) + extra + "111"))
        return c is not None and quant(c) == v + [0] * 4
    other = rnd.randrange(len(books[cb]))
    v1, x1 = coded(cb, values_of(cb, index), rnd)
    v2, x2 = coded(cb, values_of(cb, other), rnd)
    order = rnd.random() < 0.5
    if order:
        v1, x1, v2, x2, i1, i2 = v2, x2, v1, x1, other, index
    else:
        i1, i2 = index, other
    c = run(frame(cb, code_str(books[cb][i1]) + x1 + code_str(books[cb][i2]) + x2 + "111"))
    return c is not None and quant(c) == v1 + v2 + [0] * 4


def check():
    books = table_books()
    jobs = [("sf", i, books, i) for i in range(len(books["sf"]))]
    for cb in range(1, 12):
        jobs += [(cb, i, books, 1000 * cb + i) for i in range(len(books[cb]))]
    with ThreadPoolExecutor(8) as pool:
        res = list(pool.map(check_one, jobs))
    bad = [(j[0], j[1]) for j, ok in zip(jobs, res) if not ok]
    print("%d codewords checked, %d wrong%s" % (len(jobs), len(bad),
                                                 (": %s" % bad[:20]) if bad else ""))
    return 1 if bad else 0


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--check":
        sys.exit(check())
    if len(sys.argv) == 2:
        find(sys.argv[1])
    else:
        sys.exit(__doc__)
