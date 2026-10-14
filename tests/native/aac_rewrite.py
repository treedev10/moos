#!/usr/bin/env python3
"""
aac_rewrite.py - read AAC raw data blocks (access units) into Python
objects and write them back, unchanged or changed, to make test streams
that ffmpeg's encoder never produces (used by aac_make.py).

The syntax follows ISO/IEC 14496-3 subpart 4 (raw_data_block and the
elements in it). Only what AAC-LC uses is understood: SCE, CPE and LFE are
parsed down to the quantised spectral values; CCE, DSE, PCE and FIL are
read past and kept as raw bits. Codebooks and band tables come from
tools/gen_aac_tables.py.

Writing a parsed frame gives back the same bits (checked by
identity_check), so each change below is the only difference:
  pulses      add pulse_data to long-window channels
  tns_high    TNS filters of order 9-12 on long windows
  pns_ms      ms_used set on noise bands of both channels of a pair
  split       eight-short-window channels: every window its own group
  ms_all      ms_mask_present 1 with every bit set -> ms_mask_present 2
  separate    common_window 1 without M/S -> two ics_info (common_window 0)
  cce         a coupling channel element with real spectral data, an
              aligned data stream element and a PCE in front of each frame
  as_lfe      single channel elements turned into LFE elements
  shapes      window_shape flipped (sine <-> KBD) in about half of the
              frames, so every pairing of a frame's shape with the last
              frame's shape occurs, for every window sequence
"""
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import gen_aac_tables as T          # noqa: E402

EIGHT_SHORT = 2
ZERO, NOISE, IS2, IS1 = 0, 13, 14, 15
SCE, CPE, CCE, LFE, DSE, PCE, FIL, END = range(8)


class BadStream(Exception):
    pass


# ------------------------------------------------------------- codebooks
def _books():
    books = T.parse_books()
    enc, dec = {}, {}
    for key, entries in books.items():
        enc[key] = entries                              # index -> (len, code)
        dec[key] = {(n, c): i for i, (n, c) in enumerate(entries)}
    return enc, dec


ENC, DEC = _books()


def swb_tables(sfi):
    lo = next(v for k, v in T.SWB_LONG.items() if sfi in k)
    sh = next(v for k, v in T.SWB_SHORT.items() if sfi in k)
    return lo, sh


# ------------------------------------------------------------- bits
class Reader:
    def __init__(self, data):
        self.bits = "".join(format(b, "08b") for b in data)
        self.pos = 0

    def get(self, n):
        if n == 0:
            return 0
        if self.pos + n > len(self.bits):
            raise BadStream("past the end")
        v = int(self.bits[self.pos:self.pos + n], 2)
        self.pos += n
        return v

    def raw(self, n):
        if self.pos + n > len(self.bits):
            raise BadStream("past the end")
        s = self.bits[self.pos:self.pos + n]
        self.pos += n
        return s

    def huff(self, book):
        d = DEC[book]
        v = 0
        for n in range(1, 20):
            v = (v << 1) | self.get(1)
            if (n, v) in d:
                return d[(n, v)]
        raise BadStream("bad codeword")

    def align(self):
        self.pos += (-self.pos) % 8


class Writer:
    def __init__(self):
        self.s = []
        self.n = 0

    def put(self, n, v):
        if not 0 <= v < (1 << n) and not (n == 0 and v == 0):
            raise BadStream("value %d does not fit %d bits" % (v, n))
        if n:
            self.s.append(format(v, "0%db" % n))
            self.n += n

    def raw(self, bits):
        self.s.append(bits)
        self.n += len(bits)

    def huff(self, book, index):
        if not 0 <= index < len(ENC[book]):
            raise BadStream("index %d not in codebook %s" % (index, book))
        n, c = ENC[book][index]
        self.put(n, c)

    def align(self):
        self.put((-self.n) % 8, 0)

    def bytes(self):
        bits = "".join(self.s)
        bits += "0" * ((-len(bits)) % 8)
        return bytes(int(bits[i:i + 8], 2) for i in range(0, len(bits), 8))


# ------------------------------------------------------------- syntax
class Info:
    """ics_info"""

    def read(self, r, sfi):
        if r.get(1):
            raise BadStream("reserved bit")
        self.seq = r.get(2)
        self.shape = r.get(1)
        if self.seq == EIGHT_SHORT:
            self.max_sfb = r.get(4)
            self.grouping = r.get(7)
        else:
            self.max_sfb = r.get(6)
            if r.get(1):
                raise BadStream("prediction")
            self.grouping = 0
        self.setup(sfi)
        return self

    def setup(self, sfi):
        lo, sh = swb_tables(sfi)
        if self.seq == EIGHT_SHORT:
            self.nwin, self.swb = 8, sh
            self.glen = [1]
            for i in range(6, -1, -1):
                if (self.grouping >> i) & 1:
                    self.glen[-1] += 1
                else:
                    self.glen.append(1)
        else:
            self.nwin, self.swb, self.glen = 1, lo, [1]
        if self.max_sfb > len(self.swb) - 1:
            raise BadStream("max_sfb")

    def write(self, w):
        w.put(1, 0)
        w.put(2, self.seq)
        w.put(1, self.shape)
        if self.seq == EIGHT_SHORT:
            w.put(4, self.max_sfb)
            w.put(7, self.grouping)
        else:
            w.put(6, self.max_sfb)
            w.put(1, 0)

    def copy(self):
        c = Info()
        c.__dict__.update(self.__dict__)
        c.glen = list(self.glen)
        return c


def book_shape(cb):
    """(values per codeword, largest value, signed, modulus) of book 1-11"""
    dim, lav, signed = T.BOOKS[cb]
    return dim, lav, signed, (2 * lav + 1 if signed else lav + 1)


class ICS:
    """individual_channel_stream: everything as values, so that changing
    one thing re-encodes the rest consistently"""

    def read(self, r, sfi, info=None):
        self.gain = r.get(8)
        self.info = info if info is not None else Info().read(r, sfi)
        inf = self.info
        # section_data
        sbits, sesc = (3, 7) if inf.seq == EIGHT_SHORT else (5, 31)
        self.bt = []
        self.sections = []                              # (book, bands) per group
        for g in range(len(inf.glen)):
            row, secs = [], []
            while len(row) < inf.max_sfb:
                cb = r.get(4)
                if cb == 12:
                    raise BadStream("book 12")
                n = 0
                while True:
                    inc = r.get(sbits)
                    n += inc
                    if inc != sesc:
                        break
                if len(row) + n > inf.max_sfb:
                    raise BadStream("section")
                row += [cb] * n
                secs.append((cb, n))
            self.bt.append(row)
            self.sections.append(secs)
        # scale_factor_data: absolute values (sf / is position / noise energy)
        sf, isp, nrg, first = self.gain, 0, self.gain - 90, True
        self.sf = []
        for g, row in enumerate(self.bt):
            vals = []
            for cb in row:
                if cb == ZERO:
                    vals.append(0)
                elif cb in (IS1, IS2):
                    isp += r.huff("sf") - 60
                    vals.append(isp)
                elif cb == NOISE:
                    if first:
                        nrg += r.get(9) - 256
                        first = False
                    else:
                        nrg += r.huff("sf") - 60
                    vals.append(nrg)
                else:
                    sf += r.huff("sf") - 60
                    vals.append(sf)
            self.sf.append(vals)
        # pulse_data
        self.pulse = None
        if r.get(1):
            n = r.get(2) + 1
            start = r.get(6)
            self.pulse = (start, [(r.get(5), r.get(4)) for _ in range(n)])
        # tns_data
        self.tns = None
        if r.get(1):
            short = inf.seq == EIGHT_SHORT
            self.tns = []
            for _ in range(inf.nwin):
                win = {"res": 0, "filters": []}
                nf = r.get(1 if short else 2)
                if nf:
                    win["res"] = r.get(1)
                for _ in range(nf):
                    length = r.get(4 if short else 6)
                    order = r.get(3 if short else 5)
                    f = {"len": length, "order": order, "dir": 0, "compress": 0, "coef": []}
                    if order:
                        f["dir"] = r.get(1)
                        f["compress"] = r.get(1)
                        bits = win["res"] + 3 - f["compress"]
                        for _ in range(order):
                            v = r.get(bits)
                            f["coef"].append(v - (1 << bits) if v >> (bits - 1) else v)
                    win["filters"].append(f)
                self.tns.append(win)
        if r.get(1):
            raise BadStream("gain control")
        # spectral_data: q[w][k]
        self.q = [[0] * (128 if inf.nwin == 8 else 1024) for _ in range(inf.nwin)]
        w0 = 0
        for g, row in enumerate(self.bt):
            for b, cb in enumerate(row):
                if cb == ZERO or cb >= NOISE:
                    continue
                lo, hi = inf.swb[b], inf.swb[b + 1]
                for w in range(w0, w0 + inf.glen[g]):
                    k = lo
                    while k < hi:
                        vals = self.read_tuple(r, cb)
                        self.q[w][k:k + len(vals)] = vals
                        k += len(vals)
            w0 += inf.glen[g]
        return self

    @staticmethod
    def read_tuple(r, cb):
        dim, lav, signed, mod = book_shape(cb)
        idx = r.huff(cb)
        vals = []
        for _ in range(dim):
            vals.append(idx % mod)
            idx //= mod
        vals.reverse()
        if signed:
            return [v - lav for v in vals]
        for i, v in enumerate(vals):
            if v and r.get(1):
                vals[i] = -v
        if cb == 11:
            for i, v in enumerate(vals):
                if abs(v) == 16:
                    n = 4
                    while r.get(1):
                        n += 1
                        if n > 12:
                            raise BadStream("escape")
                    mag = (1 << n) + r.get(n)
                    vals[i] = -mag if v < 0 else mag
        return vals

    def write(self, w, common):
        inf = self.info
        w.put(8, self.gain)
        if not common:
            inf.write(w)
        sbits, sesc = (3, 7) if inf.seq == EIGHT_SHORT else (5, 31)
        for g, row in enumerate(self.bt):
            # the sections as read (an encoder may split a run of one book),
            # unless the bands have changed: then one section per run
            secs = self.sections[g] if g < len(self.sections) else None
            if secs is None or sum(([cb] * n for cb, n in secs), []) != row:
                secs, b = [], 0
                while b < len(row):
                    e = b
                    while e < len(row) and row[e] == row[b]:
                        e += 1
                    secs.append((row[b], e - b))
                    b = e
            for cb, n in secs:
                w.put(4, cb)
                while n >= sesc:
                    w.put(sbits, sesc)
                    n -= sesc
                w.put(sbits, n)
        sf, isp, nrg, first = self.gain, 0, self.gain - 90, True
        for g, row in enumerate(self.bt):
            for b, cb in enumerate(row):
                v = self.sf[g][b]
                if cb == ZERO:
                    continue
                if cb in (IS1, IS2):
                    w.huff("sf", v - isp + 60)
                    isp = v
                elif cb == NOISE:
                    if first:
                        w.put(9, v - nrg + 256)
                        first = False
                    else:
                        w.huff("sf", v - nrg + 60)
                    nrg = v
                else:
                    w.huff("sf", v - sf + 60)
                    sf = v
        if self.pulse:
            start, pulses = self.pulse
            w.put(1, 1)
            w.put(2, len(pulses) - 1)
            w.put(6, start)
            for off, amp in pulses:
                w.put(5, off)
                w.put(4, amp)
        else:
            w.put(1, 0)
        if self.tns:
            short = inf.seq == EIGHT_SHORT
            w.put(1, 1)
            for win in self.tns:
                w.put(1 if short else 2, len(win["filters"]))
                if win["filters"]:
                    w.put(1, win["res"])
                for f in win["filters"]:
                    w.put(4 if short else 6, f["len"])
                    w.put(3 if short else 5, f["order"])
                    if f["order"]:
                        w.put(1, f["dir"])
                        w.put(1, f["compress"])
                        bits = win["res"] + 3 - f["compress"]
                        for c in f["coef"]:
                            if not -(1 << (bits - 1)) <= c < (1 << (bits - 1)):
                                raise BadStream("TNS coefficient")
                            w.put(bits, c & ((1 << bits) - 1))
        else:
            w.put(1, 0)
        w.put(1, 0)                                     # no gain control
        w0 = 0
        for g, row in enumerate(self.bt):
            for b, cb in enumerate(row):
                if cb == ZERO or cb >= NOISE:
                    continue
                lo, hi = inf.swb[b], inf.swb[b + 1]
                dim = T.BOOKS[cb][0]
                for wi in range(w0, w0 + inf.glen[g]):
                    for k in range(lo, hi, dim):
                        self.write_tuple(w, cb, self.q[wi][k:k + dim])
            w0 += inf.glen[g]

    @staticmethod
    def write_tuple(w, cb, vals):
        dim, lav, signed, mod = book_shape(cb)
        idx = 0
        if signed:
            for v in vals:
                if abs(v) > lav:
                    raise BadStream("value too big for the book")
                idx = idx * mod + v + lav
            w.huff(cb, idx)
            return
        for v in vals:
            a = min(abs(v), 16) if cb == 11 else abs(v)
            if a > lav:
                raise BadStream("value too big for the book")
            idx = idx * mod + a
        w.huff(cb, idx)
        for v in vals:
            if v:
                w.put(1, 1 if v < 0 else 0)
        if cb == 11:
            for v in vals:
                a = abs(v)
                if a >= 16:
                    if a > 8191:
                        raise BadStream("escape too big")
                    n = a.bit_length() - 1                # 2^n <= a
                    w.put(n - 4, (1 << (n - 4)) - 1)      # n-4 ones
                    w.put(1, 0)
                    w.put(n, a - (1 << n))


class Element:
    pass


def read_frame(data, sfi):
    """a raw_data_block -> list of elements (END not included)"""
    r = Reader(data)
    els = []
    while True:
        e = Element()
        start = r.pos
        e.id = r.get(3)
        if e.id == END:
            break
        if e.id in (SCE, LFE):
            e.tag = r.get(4)
            e.common, e.ms, e.ms_used = 0, 0, None
            e.ch = [ICS().read(r, sfi)]
        elif e.id == CPE:
            e.tag = r.get(4)
            e.common = r.get(1)
            e.ms = 0
            e.ms_used = None
            info = None
            if e.common:
                info = Info().read(r, sfi)
                e.ms = r.get(2)
                if e.ms == 3:
                    raise BadStream("ms_mask_present 3")
                if e.ms == 1:
                    e.ms_used = [[r.get(1) for _ in range(info.max_sfb)]
                                 for _ in range(len(info.glen))]
            e.ch = [ICS().read(r, sfi, info), ICS().read(r, sfi, info)]
        else:
            # kept as they are: the bits, with the places where they align
            # to a byte (which move if the elements before them change)
            e.parts = []
            r.mark = start
            skip_other(r, e.id, sfi, e.parts)
            e.parts.append(r.bits[r.mark:r.pos])
        els.append(e)
    return els


def aligned(r, parts):
    """byte_alignment() inside an element that is kept as bits"""
    parts.append(r.bits[r.mark:r.pos])
    parts.append(None)
    r.align()
    r.mark = r.pos


def skip_other(r, eid, sfi, parts):
    if eid == DSE:
        r.get(4)
        align = r.get(1)
        n = r.get(8)
        if n == 255:
            n += r.get(8)
        if align:
            aligned(r, parts)
        r.raw(8 * n)
    elif eid == FIL:
        n = r.get(4)
        if n == 15:
            n += r.get(8) - 1
        r.raw(8 * n)
    elif eid == PCE:
        r.get(10)
        nf, ns, nb, nl, na, nc = r.get(4), r.get(4), r.get(4), r.get(2), r.get(3), r.get(4)
        if r.get(1):
            r.get(4)
        if r.get(1):
            r.get(4)
        if r.get(1):
            r.get(3)
        r.raw(5 * (nf + ns + nb) + 4 * nl + 4 * na + 5 * nc)
        aligned(r, parts)
        r.raw(8 * r.get(8))
    elif eid == CCE:
        r.get(4)
        ind = r.get(1)
        lists = 0
        for _ in range(r.get(3) + 1):
            lists += 1
            if r.get(1):
                r.get(4)
                if r.get(1) & r.get(1):
                    lists += 1
            else:
                r.get(4)
        r.get(4)
        ics = ICS().read(r, sfi)
        for _ in range(1, lists):
            if ind or r.get(1):
                r.huff("sf")
            else:
                for row in ics.bt:
                    for cb in row:
                        if cb != ZERO:
                            r.huff("sf")


def write_frame(els):
    w = Writer()
    for e in els:
        if hasattr(e, "parts"):
            for p in e.parts:
                if p is None:
                    w.align()
                else:
                    w.raw(p)
            continue
        w.put(3, e.id)
        w.put(4, e.tag)
        if e.id == CPE:
            w.put(1, e.common)
            if e.common:
                e.ch[0].info.write(w)
                w.put(2, e.ms)
                if e.ms == 1:
                    for row in e.ms_used:
                        for bit in row:
                            w.put(1, bit)
        for c in e.ch:
            c.write(w, e.id == CPE and e.common)
    w.put(3, END)
    w.align()
    return w.bytes()


def identity_check(frames, sfi):
    """parsing and writing back must give the same bytes"""
    for i, raw in enumerate(frames):
        out = write_frame(read_frame(raw, sfi))
        if out != raw:
            n = next((k for k in range(min(len(out), len(raw))) if out[k] != raw[k]), None)
            raise BadStream("frame %d differs after rewriting (byte %s)" % (i, n))


# ------------------------------------------------------------- changes
def channels(els):
    for e in els:
        if hasattr(e, "ch"):
            for c in e.ch:
                yield e, c


def spectral_positions(c):
    """(window, k) of every value in a band with a spectral codebook"""
    inf = c.info
    out, w0 = [], 0
    for g, row in enumerate(c.bt):
        for b, cb in enumerate(row):
            if 1 <= cb <= 11:
                for w in range(w0, w0 + inf.glen[g]):
                    out += [(w, k) for k in range(inf.swb[b], inf.swb[b + 1])]
        w0 += inf.glen[g]
    return out


def pulses(els, rnd):
    """pulse_data on about half of the long-window channels without it:
    up to 4 pulses (amplitude 1-15) at values of spectral bands"""
    done = 0
    for e, c in channels(els):
        if c.info.seq == EIGHT_SHORT or c.pulse or rnd.random() < 0.5:
            continue
        pos = [k for _, k in spectral_positions(c)]
        if not pos:
            continue
        k0 = rnd.choice(pos)
        start = max(b for b in range(len(c.info.swb) - 1) if c.info.swb[b] <= k0)
        k = c.info.swb[start]
        plist = []
        for _ in range(rnd.randint(1, 4)):
            cands = [p for p in pos if k <= p <= k + 31]
            if not cands:
                break
            p = rnd.choice(cands)
            amp = rnd.choice([1, 1, 1, 2, 2, 3, 5, 15])
            plist.append((p - k, amp))
            k = p
        if plist:
            c.pulse = (start, plist)
            done += 1
    return done


def tns_high(els, rnd):
    """long windows: TNS filters raised to order 9-12 (small random extra
    coefficients); channels without TNS get a filter"""
    done = 0
    for e, c in channels(els):
        if c.info.seq == EIGHT_SHORT or rnd.random() < 0.3:
            continue
        if not c.tns:
            res = rnd.randint(0, 1)
            c.tns = [{"res": res, "filters": [{"len": rnd.randint(1, 40), "order": 0,
                                               "dir": rnd.randint(0, 1), "compress": 0,
                                               "coef": []}]}]
        win = c.tns[0]
        if not win["filters"]:
            win["filters"].append({"len": rnd.randint(1, 40), "order": 0, "dir": 0,
                                   "compress": 0, "coef": []})
        f = win["filters"][0]
        bits = win["res"] + 3 - f["compress"]
        lim = min(2, (1 << (bits - 1)) - 1)
        order = rnd.randint(9, 12)
        f["coef"] = f["coef"][:order] + [rnd.randint(-lim, lim)
                                         for _ in range(order - len(f["coef"][:order]))]
        f["order"] = order
        done += 1
    return done


def pns_ms(els, rnd):
    """channel pairs: ms_used on every band where both channels are noise"""
    done = 0
    for e in els:
        if getattr(e, "id", None) != CPE or not e.common:
            continue
        a, b = e.ch
        hits = [(g, s) for g in range(len(a.bt)) for s in range(len(a.bt[g]))
                if a.bt[g][s] == NOISE and b.bt[g][s] == NOISE]
        if not hits:
            continue
        if e.ms == 0:
            e.ms = 1
            e.ms_used = [[0] * len(row) for row in a.bt]
        if e.ms == 1:
            for g, s in hits:
                e.ms_used[g][s] = 1
        done += len(hits)
    return done


def split_groups(els, rnd):
    """eight short windows: one group per window (each window of an old
    group gets its sections and scale factors)"""
    done = 0
    for e in els:
        if not hasattr(e, "ch"):
            continue
        saved = [(c.info, c.bt, c.sf, c.sections) for c in e.ch], e.ms_used
        new_infos = {}
        for c in e.ch:
            old = c.info
            if old.seq != EIGHT_SHORT or len(old.glen) == 8:
                continue
            if id(old) not in new_infos:            # (a pair may share it)
                ni = old.copy()
                ni.grouping, ni.glen = 0, [1] * 8
                new_infos[id(old)] = ni
            bt, sf, secs = [], [], []
            for g, n in enumerate(old.glen):
                bt += [list(c.bt[g]) for _ in range(n)]
                sf += [list(c.sf[g]) for _ in range(n)]
                secs += [list(c.sections[g]) for _ in range(n)]
            c.info, c.bt, c.sf, c.sections = new_infos[id(old)], bt, sf, secs
        if not new_infos:
            continue
        if e.ms_used:
            glen = saved[0][0][0].glen
            e.ms_used = sum(([list(row) for _ in range(n)] for row, n in zip(e.ms_used, glen)),
                            [])
        try:                                        # can the deltas be coded?
            for c in e.ch:
                c.write(Writer(), e.id == CPE and e.common)
            done += 1
        except BadStream:                           # no: leave this one
            for c, (info, bt, sf, secs) in zip(e.ch, saved[0]):
                c.info, c.bt, c.sf, c.sections = info, bt, sf, secs
            e.ms_used = saved[1]
    return done


def ms_all(els, rnd):
    done = 0
    for e in els:
        if getattr(e, "id", None) == CPE and e.common and e.ms == 1 and \
                all(all(row) for row in e.ms_used):
            e.ms, e.ms_used = 2, None
            done += 1
    return done


def separate(els, rnd):
    done = 0
    for e in els:
        if getattr(e, "id", None) == CPE and e.common and e.ms == 0:
            e.common = 0
            e.ch[1].info = e.ch[0].info.copy()
            done += 1
    return done


def shapes(els, rnd):
    done = 0
    seen = set()
    for e, c in channels(els):
        if id(c.info) in seen:                      # (shared by a pair)
            continue
        seen.add(id(c.info))
        if rnd.random() < 0.5:
            c.info.shape ^= 1
            done += 1
    return done


def as_lfe(els, rnd):
    done = 0
    for e in els:
        if getattr(e, "id", None) == SCE:
            e.id = LFE
            done += 1
    return done


def cce_front(els, rnd):
    """in front of the frame: a CCE carrying a copy of the frame's first
    channel (and gain elements), a byte-aligned DSE and a PCE"""
    src = next((c for _, c in channels(els)), None)
    if src is None:
        return 0
    w = Writer()
    w.put(3, CCE)
    w.put(4, rnd.randint(0, 15))
    ind = rnd.randint(0, 1)
    w.put(1, ind)
    targets = rnd.randint(0, 7)
    w.put(3, targets)
    lists = 0
    for _ in range(targets + 1):
        lists += 1
        cpe = rnd.randint(0, 1)
        w.put(1, cpe)
        w.put(4, rnd.randint(0, 15))
        if cpe:
            l, r = rnd.randint(0, 1), rnd.randint(0, 1)
            w.put(1, l)
            w.put(1, r)
            lists += l & r
    w.put(1, rnd.randint(0, 1))                         # cc_domain
    w.put(1, rnd.randint(0, 1))                         # gain_element_sign
    w.put(2, rnd.randint(0, 3))                         # gain_element_scale
    src.write(w, False)
    for _ in range(1, lists):
        cge = 1 if ind else rnd.randint(0, 1)
        if not ind:
            w.put(1, cge)
        if cge:
            w.huff("sf", rnd.randint(50, 70))
        else:
            for row in src.bt:
                for cb in row:
                    if cb != ZERO:
                        w.huff("sf", rnd.randint(55, 65))
    # DSE, byte-aligned (relative to the frame start: the CCE comes first)
    w.put(3, DSE)
    w.put(4, rnd.randint(0, 15))
    w.put(1, 1)
    n = rnd.randint(0, 20)
    w.put(8, n)
    w.align()
    for _ in range(n):
        w.put(8, rnd.randint(0, 255))
    # PCE: one front channel pair, a comment
    w.put(3, PCE)
    for n, v in ((4, 0), (2, 1), (4, 4), (4, 1), (4, 0), (4, 0), (2, 0), (3, 0), (4, 0),
                 (1, 0), (1, 0), (1, 0), (1, 1), (4, 0)):
        w.put(n, v)
    w.align()
    w.put(8, 3)
    for ch in b"moo":
        w.put(8, ch)
    e = Element()
    e.id = CCE
    e.parts = ["".join(w.s)]                        # (it goes first, so its
    els.insert(0, e)                                #  alignment holds)
    return 1


CHANGES = {"pulses": pulses, "tns_high": tns_high, "pns_ms": pns_ms, "split": split_groups,
           "ms_all": ms_all, "separate": separate, "as_lfe": as_lfe, "cce": cce_front,
           "shapes": shapes}


def rewrite(frames, sfi, change, seed=1):
    """apply a change to every frame; returns (new frames, frames changed)"""
    rnd = random.Random(seed)
    out, changed = [], 0
    for raw in frames:
        els = read_frame(raw, sfi)
        n = CHANGES[change](els, rnd)
        changed += 1 if n else 0
        out.append(write_frame(els))
    return out, changed
