#!/usr/bin/env python3
"""
h264_rewrite.py - change the headers of an H.264 Annex B stream, to make test
streams with features x264 never writes. The slice data is copied bit for bit;
only parameter sets and slice headers are rewritten (CAVLC, frames only).

    python3 tests/native/h264_rewrite.py OPS IN.264 OUT.264
    python3 tests/native/h264_rewrite.py synth OUT.264 [W H FRAMES]   (I_PCM stream)

OPS is a comma separated list:
  qp=N        every slice at QP N (slice_qp_delta; x264 refuses QP 0 in Baseline)
  qpcycle     picture n at slice QP (11 n + 3) % 52: every QP gets used
  poc0        picture order count type 0 (pic_order_cnt_lsb, 8 bits, wrapping)
  poc1        picture order count type 1 (a cycle of one reference frame)
  ids         several parameter sets: SPS id 3 and PPS ids 5 / 200 (alternating
              per picture; the second one with another chroma_qp_index_offset),
              plus a junk SPS / PPS with other ids that are never used
  ltr         long-term references: every 5th reference picture is marked
              long-term (MMCO 6, index 0 after MMCO 4); the next pictures put it
              first in their list (modification idc 2); MMCO 2 releases it
  mmco        a mix of MMCO 1 (drop a short-term picture), 2, 3 (short-term to
              long-term), 4 and 5 (everything unused; frame_num restarts) on a
              refs=1 stream, max_num_ref_frames 4 (list 0 entry 0 stays the
              previous picture)
  reorder     reference list modification: list 0 reversed on every P slice
  redundant   redundant_pic_cnt present; after every slice but the first of a
              picture a redundant copy (redundant_pic_cnt 1) with garbage
              slice data, which must be ignored
  gaps        gaps_in_frame_num_allowed: frame_num advances by 2 per reference
              picture (one "non-existing" frame each time), max_num_ref_frames
              grows by one and the lists skip the non-existing frames
  nonidr=K    drop every slice before the K-th picture (the stream starts with
              P slices; the parameter sets stay)
  eos         filler data, access unit delimiters, end of sequence / stream
              NAL units and unknown NAL types (20, 23) between the slices
  numref=N    max_num_ref_frames = N (bigger DPB)
"""
import sys


# ----------------------------------------------------------------- bit I/O
class BitReader:
    def __init__(self, data):
        self.d = data
        self.pos = 0

    def u(self, n):
        v = 0
        for _ in range(n):
            byte = self.d[self.pos >> 3] if (self.pos >> 3) < len(self.d) else 0
            v = (v << 1) | ((byte >> (7 - (self.pos & 7))) & 1)
            self.pos += 1
        return v

    def ue(self):
        lz = 0
        while self.u(1) == 0:
            lz += 1
            if lz > 32:
                raise ValueError("bad ue")
        return (1 << lz) - 1 + self.u(lz)

    def se(self):
        k = self.ue()
        return (k + 1) // 2 if k & 1 else -(k // 2)

    def more_rbsp_data(self):
        # data remains before the last one bit
        last = len(self.d) * 8 - 1
        while last >= 0 and not (self.d[last >> 3] >> (7 - (last & 7))) & 1:
            last -= 1
        return self.pos < last


class BitWriter:
    def __init__(self):
        self.bits = []

    def u(self, n, v):
        for i in range(n - 1, -1, -1):
            self.bits.append((v >> i) & 1)

    def ue(self, v):
        v += 1
        n = v.bit_length()
        self.u(n - 1, 0)
        self.u(n, v)

    def se(self, v):
        self.ue(2 * v - 1 if v > 0 else -2 * v)

    def copy_bits(self, r, start, end):
        for p in range(start, end):
            self.bits.append((r.d[p >> 3] >> (7 - (p & 7))) & 1)

    def trailing(self):
        self.bits.append(1)
        while len(self.bits) % 8:
            self.bits.append(0)

    def bytes(self):
        assert len(self.bits) % 8 == 0
        out = bytearray()
        for i in range(0, len(self.bits), 8):
            v = 0
            for b in self.bits[i:i + 8]:
                v = (v << 1) | b
            out.append(v)
        return bytes(out)


def unescape(nal):
    out = bytearray()
    z = 0
    for b in nal:
        if z >= 2 and b == 3:
            z = 0
            continue
        out.append(b)
        z = z + 1 if b == 0 else 0
    return bytes(out)


def escape(rbsp):
    out = bytearray()
    z = 0
    for b in rbsp:
        if z >= 2 and b <= 3:
            out.append(3)
            z = 0
        out.append(b)
        z = z + 1 if b == 0 else 0
    return bytes(out)


def split(data):
    nals, i, start = [], 0, None
    while i + 3 <= len(data):
        if data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1:
            if start is not None:
                e = i
                while e > start and data[e - 1] == 0:
                    e -= 1
                nals.append(data[start:e])
            i += 3
            start = i
            continue
        i += 1
    if start is not None:
        e = len(data)
        while e > start and data[e - 1] == 0:
            e -= 1
        nals.append(data[start:e])
    return nals


def join(nals):
    return b"".join(b"\x00\x00\x00\x01" + n for n in nals)


# ------------------------------------------------------------ parameter sets
HIGH = (100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135)


def parse_sps(rbsp):
    r = BitReader(rbsp)
    s = {}
    s["profile"] = r.u(8)
    s["constraints"] = r.u(8)
    s["level"] = r.u(8)
    s["id"] = r.ue()
    if s["profile"] in HIGH:
        raise ValueError("High profile SPS not supported by the rewriter")
    s["log2fn"] = r.ue() + 4
    s["poctype"] = r.ue()
    if s["poctype"] == 0:
        s["log2poc"] = r.ue() + 4
    elif s["poctype"] == 1:
        s["dpocz"] = r.u(1)
        s["offnr"] = r.se()
        s["offtb"] = r.se()
        n = r.ue()
        s["offref"] = [r.se() for _ in range(n)]
    s["nref"] = r.ue()
    s["gaps"] = r.u(1)
    s["mbw"] = r.ue() + 1
    s["mbh"] = r.ue() + 1
    s["frameonly"] = r.u(1)
    assert s["frameonly"], "frames only"
    s["d8x8"] = r.u(1)
    s["crop"] = r.u(1)
    if s["crop"]:
        s["cropv"] = [r.ue() for _ in range(4)]
    s["vui_start"] = r.pos
    s["rbsp"] = rbsp
    return s


def write_sps(s):
    w = BitWriter()
    w.u(8, s["profile"])
    w.u(8, s["constraints"])
    w.u(8, s["level"])
    w.ue(s["id"])
    w.ue(s["log2fn"] - 4)
    w.ue(s["poctype"])
    if s["poctype"] == 0:
        w.ue(s["log2poc"] - 4)
    elif s["poctype"] == 1:
        w.u(1, s["dpocz"])
        w.se(s["offnr"])
        w.se(s["offtb"])
        w.ue(len(s["offref"]))
        for o in s["offref"]:
            w.se(o)
    w.ue(s["nref"])
    w.u(1, s["gaps"])
    w.ue(s["mbw"] - 1)
    w.ue(s["mbh"] - 1)
    w.u(1, 1)
    w.u(1, s["d8x8"])
    w.u(1, s["crop"])
    if s["crop"]:
        for v in s["cropv"]:
            w.ue(v)
    # the VUI (and the stop bit) as they were, possibly with a new
    # max_dec_frame_buffering
    r = BitReader(s["rbsp"])
    rest = len(s["rbsp"]) * 8
    while rest > 0 and not (s["rbsp"][(rest - 1) >> 3] >> (7 - ((rest - 1) & 7))) & 1:
        rest -= 1
    w.copy_bits(r, s["vui_start"], rest - 1)
    w.trailing()
    return w.bytes()


def parse_pps(rbsp):
    r = BitReader(rbsp)
    p = {}
    p["id"] = r.ue()
    p["sps"] = r.ue()
    p["cabac"] = r.u(1)
    p["bfpoc"] = r.u(1)
    p["nsg"] = r.ue() + 1
    assert p["nsg"] == 1, "no FMO"
    p["nref0"] = r.ue() + 1
    p["nref1"] = r.ue() + 1
    p["wp"] = r.u(1)
    p["wbi"] = r.u(2)
    p["qp"] = r.se() + 26
    p["qs"] = r.se() + 26
    p["cqp"] = r.se()
    p["dbk"] = r.u(1)
    p["cip"] = r.u(1)
    p["rpc"] = r.u(1)
    p["ext"] = None
    if r.more_rbsp_data():
        raise ValueError("PPS extension not supported by the rewriter")
    return p


def write_pps(p):
    w = BitWriter()
    w.ue(p["id"])
    w.ue(p["sps"])
    w.u(1, p["cabac"])
    w.u(1, p["bfpoc"])
    w.ue(p["nsg"] - 1)
    w.ue(p["nref0"] - 1)
    w.ue(p["nref1"] - 1)
    w.u(1, p["wp"])
    w.u(2, p["wbi"])
    w.se(p["qp"] - 26)
    w.se(p["qs"] - 26)
    w.se(p["cqp"])
    w.u(1, p["dbk"])
    w.u(1, p["cip"])
    w.u(1, p["rpc"])
    w.trailing()
    return w.bytes()


# -------------------------------------------------------------------- slices
def parse_slice(rbsp, nal_type, ref_idc, spss, ppss):
    r = BitReader(rbsp)
    h = {"nal_type": nal_type, "ref_idc": ref_idc}
    h["first_mb"] = r.ue()
    h["slice_type"] = r.ue()
    h["pps"] = r.ue()
    pps = ppss[h["pps"]]
    sps = spss[pps["sps"]]
    st = h["slice_type"] % 5
    h["frame_num"] = r.u(sps["log2fn"])
    if nal_type == 5:
        h["idr_id"] = r.ue()
    if sps["poctype"] == 0:
        h["poc_lsb"] = r.u(sps["log2poc"])
        if pps["bfpoc"]:
            h["dpb"] = r.se()
    if sps["poctype"] == 1 and not sps["dpocz"]:
        h["dpoc0"] = r.se()
        if pps["bfpoc"]:
            h["dpoc1"] = r.se()
    if pps["rpc"]:
        h["rpc"] = r.ue()
    if st == 1:
        h["dspat"] = r.u(1)
    h["nref_override"] = None
    if st in (0, 1, 3):
        if r.u(1):
            h["nref_override"] = [r.ue() + 1, r.ue() + 1 if st == 1 else None]
    h["rplm"] = [None, None]
    if st not in (2, 4):
        for lx in range(2 if st == 1 else 1):
            if r.u(1):
                ops = []
                while True:
                    idc = r.ue()
                    if idc == 3:
                        break
                    ops.append((idc, r.ue()))
                h["rplm"][lx] = ops
    if (pps["wp"] and st in (0, 3)) or (pps["wbi"] == 1 and st == 1):
        raise ValueError("weighted prediction not supported by the rewriter")
    h["mark"] = None
    if ref_idc:
        if nal_type == 5:
            h["mark"] = ("idr", r.u(1), r.u(1))
        else:
            if r.u(1):
                ops = []
                while True:
                    op = r.ue()
                    if op == 0:
                        break
                    v = []
                    if op in (1, 3):
                        v.append(r.ue())
                    if op == 2:
                        v.append(r.ue())
                    if op in (3, 6):
                        v.append(r.ue())
                    if op == 4:
                        v.append(r.ue())
                    ops.append((op, v))
                h["mark"] = ("adaptive", ops)
            else:
                h["mark"] = ("sliding",)
    if pps["cabac"] and st not in (2, 4):
        h["cabac_init"] = r.ue()
    h["qp_delta"] = r.se()
    if st in (3, 4):
        raise ValueError("SP/SI not supported")
    if pps["dbk"]:
        h["dbk"] = [r.ue()]
        if h["dbk"][0] != 1:
            h["dbk"] += [r.se(), r.se()]
    h["data_start"] = r.pos
    h["rbsp"] = rbsp
    return h


def write_slice(h, spss, ppss):
    pps = ppss[h["pps"]]
    sps = spss[pps["sps"]]
    st = h["slice_type"] % 5
    w = BitWriter()
    w.ue(h["first_mb"])
    w.ue(h["slice_type"])
    w.ue(h["pps"])
    w.u(sps["log2fn"], h["frame_num"] & ((1 << sps["log2fn"]) - 1))
    if h["nal_type"] == 5:
        w.ue(h["idr_id"])
    if sps["poctype"] == 0:
        w.u(sps["log2poc"], h["poc_lsb"] & ((1 << sps["log2poc"]) - 1))
        if pps["bfpoc"]:
            w.se(h.get("dpb", 0))
    if sps["poctype"] == 1 and not sps["dpocz"]:
        w.se(h.get("dpoc0", 0))
        if pps["bfpoc"]:
            w.se(h.get("dpoc1", 0))
    if pps["rpc"]:
        w.ue(h.get("rpc", 0))
    if st == 1:
        w.u(1, h["dspat"])
    if st in (0, 1, 3):
        if h["nref_override"]:
            w.u(1, 1)
            w.ue(h["nref_override"][0] - 1)
            if st == 1:
                w.ue(h["nref_override"][1] - 1)
        else:
            w.u(1, 0)
    if st not in (2, 4):
        for lx in range(2 if st == 1 else 1):
            ops = h["rplm"][lx]
            if ops:
                w.u(1, 1)
                for idc, v in ops:
                    w.ue(idc)
                    w.ue(v)
                w.ue(3)
            else:
                w.u(1, 0)
    if h["ref_idc"]:
        m = h["mark"]
        if h["nal_type"] == 5:
            w.u(1, m[1])
            w.u(1, m[2])
        elif m[0] == "adaptive":
            w.u(1, 1)
            for op, v in m[1]:
                w.ue(op)
                for x in v:
                    w.ue(x)
            w.ue(0)
        else:
            w.u(1, 0)
    if pps["cabac"] and st not in (2, 4):
        w.ue(h["cabac_init"])
    w.se(h["qp_delta"])
    if pps["dbk"]:
        d = h.get("dbk", [0, 0, 0])
        w.ue(d[0])
        if d[0] != 1:
            w.se(d[1])
            w.se(d[2])
    r = BitReader(h["rbsp"])
    end = len(h["rbsp"]) * 8
    if pps["cabac"]:
        while len(w.bits) % 8:
            w.bits.append(1)
        start = (h["data_start"] + 7) & ~7
    else:
        start = h["data_start"]
    w.copy_bits(r, start, end)
    while len(w.bits) % 8:
        w.bits.append(0)
    return w.bytes()


def nslices_slicetype(h):
    return h["slice_type"] % 5


# ------------------------------------------------------------------ rewriting
def rewrite(ops, data):
    nals = split(data)
    spss, ppss = {}, {}       # original parameter sets
    nspss, nppss = {}, {}     # rewritten ones
    out = []
    pic = -1                  # picture number (decoding order)
    refpic = -1               # reference picture number
    prev_first = None
    pics = []                 # parse everything first: list of (kind, data)
    items = []
    for n in nals:
        t = n[0] & 31
        rb = unescape(n[1:])
        if t == 7:
            s = parse_sps(rb)
            spss[s["id"]] = s
            items.append(("sps", n[0], s))
        elif t == 8:
            p = parse_pps(rb)
            ppss[p["id"]] = p
            items.append(("pps", n[0], p))
        elif t in (1, 5):
            h = parse_slice(rb, t, n[0] >> 5, spss, ppss)
            items.append(("slice", n[0], h))
        else:
            items.append(("other", n[0], n))
    # picture numbering
    pic = -1
    for it in items:
        if it[0] == "slice":
            h = it[2]
            if h["first_mb"] == 0:
                pic += 1
            h["pic"] = pic
    npics = pic + 1
    opts = {}
    for o in ops.split(","):
        if "=" in o:
            k, v = o.split("=")
            opts[k] = int(v)
        elif o:
            opts[o] = 1

    def emit(nal_hdr, rbsp):
        out.append(bytes([nal_hdr]) + escape(rbsp))

    # per-picture state for the rewrites
    ref_count = 0             # reference pictures so far (since the IDR)
    lt_pic = None
    fn_scale = 2 if "gaps" in opts else 1
    frame_num_of = {}
    poc_count = 0
    cur_pic = -1
    start_pic = opts.get("nonidr", 0)
    idr_seen = 0
    fn_base = 0
    mmco5_pending = None
    sim = {"short": [], "long": {}, "maxlt": -1}
    pic_fn_orig = 0
    import random
    rnd = random.Random(5)
    for kind, hdr, obj in items:
        if kind == "sps":
            s = dict(obj)
            if "poc0" in opts:
                s["poctype"] = 0
                s["log2poc"] = 8
            if "poc1" in opts:
                s["poctype"] = 1
                s["dpocz"] = 1
                s["offnr"] = -1
                s["offtb"] = 0
                s["offref"] = [2]
            if "gaps" in opts:
                s["gaps"] = 1
                s["nref"] = min(16, 2 * s["nref"])
                s["log2fn"] = min(16, s["log2fn"] + 1)
            if "numref" in opts:
                s["nref"] = opts["numref"]
            if "ltr" in opts or "mmco" in opts:
                s["nref"] = max(s["nref"], 4)
            if "ids" in opts:
                junk = dict(s)
                junk["id"] = 0
                junk["mbw"] = s["mbw"] + 2
                emit(hdr, write_sps(junk))
                s["id"] = 3
            nspss[s["id"]] = s
            emit(hdr, write_sps(s))
            continue
        if kind == "pps":
            p = dict(obj)
            if "redundant" in opts:
                p["rpc"] = 1
            if "ids" in opts:
                p["sps"] = 3
                p2 = dict(p)
                p2["id"] = 200
                p2["cqp"] = max(-12, min(12, p["cqp"] + 3))
                p["id"] = 5
                junk = dict(p)
                junk["id"] = 6
                junk["sps"] = 0
                emit(hdr, write_pps(junk))
                nppss[p2["id"]] = p2
                emit(hdr, write_pps(p2))
            nppss[p["id"]] = p
            emit(hdr, write_pps(p))
            continue
        if kind == "other":
            if start_pic and cur_pic < start_pic and obj[0] & 31 in (6, 9):
                continue
            out.append(obj)
            continue
        h = dict(obj)
        if h["pic"] < start_pic:
            continue
        newpic = h["pic"] != cur_pic
        cur_pic = h["pic"]
        if newpic and mmco5_pending is not None:
            fn_base = mmco5_pending
            mmco5_pending = None
        st = h["slice_type"] % 5
        if newpic:
            if h["nal_type"] == 5:
                idr_seen += 1
                ref_count = 0
                poc_count = 0
                lt_pic = None
            if "eos" in opts and h["pic"] > 0:
                if h["nal_type"] == 5:
                    out.append(bytes([0x0A]))                  # end of sequence
                out.append(bytes([0x09, 0x10 | 0x00, ]))       # AUD (primary_pic_type 0)
                out.append(bytes([0x0C]) + b"\xff" * rnd.randrange(1, 40) + b"\x80")
                out.append(bytes([0x17, 0x12, 0x34]))          # unknown types
                out.append(bytes([0x14, 0x80]))
        # which picture we are in, counted from the IDR
        if newpic:
            this_ref = h["ref_idc"] != 0
            h_pic_index = poc_count
            poc_count += 1
            if this_ref:
                ref_count += 1
        nal_type = h["nal_type"]
        if "qp" in opts:
            pps = ppss[h["pps"]]
            h["qp_delta"] = opts["qp"] - pps["qp"] + (h["qp_delta"] - h["qp_delta"])
        if "qpcycle" in opts:
            # every picture at another QP (the macroblock QP deltas of the
            # original stream still apply on top, modulo 52)
            pps = ppss[h["pps"]]
            base = pps["qp"] + h["qp_delta"]
            want = (h["pic"] * 11 + 3) % 52
            h["qp_delta"] = want - pps["qp"]
        if "ids" in opts:
            h["pps"] = 5 if h["pic"] % 2 == 0 else 200
            hp = h
        else:
            hp = h
        if "poc0" in opts:
            h["poc_lsb"] = (2 * h_pic_index) & 255
        if "gaps" in opts:
            h["frame_num"] = (h["frame_num"] * fn_scale)
            if st == 0:
                # the real previous reference is PicNum - 2 (the one between
                # is "non-existing"): put the real frames first
                nref = (h["nref_override"] or [ppss[obj["pps"]]["nref0"]])[0]
                ops_ = []
                for k in range(nref):
                    ops_.append((0, 1))      # each: two pictures further back
                h["rplm"][0] = ops_
        if "ltr" in opts and h["ref_idc"] and nal_type == 1:
            k = ref_count
            if k % 5 == 0:
                h["mark"] = ("adaptive", [(4, [1]), (6, [0])])
                lt_pic = h["pic"]
            elif lt_pic is not None and k % 5 == 3:
                h["mark"] = ("adaptive", [(2, [0])])
                lt_pic = None
        if "ltr" in opts and st == 0 and lt_pic is not None and lt_pic != h["pic"]:
            # the long-term picture first in the list (it was the previous one
            # when it was marked)
            h["rplm"][0] = [(2, 0)]
        if "mmco" in opts and h["ref_idc"] and newpic:
            # simulate the reference marking to choose valid operations
            log2 = nspss[nppss[h["pps"]]["sps"]]["log2fn"]
            maxfn = 1 << log2
            nref = nspss[nppss[h["pps"]]["sps"]]["nref"]
            curfn = (h["frame_num"] - (fn_base if mmco5_pending is None else fn_base)) % maxfn
            if nal_type == 5:
                sim = {"short": [], "long": {}, "maxlt": -1}
                curfn = 0
            def pn(fn):
                return fn if fn <= curfn else fn - maxfn
            ops_ = []
            k = ref_count
            sh, lg = sim["short"], sim["long"]
            if nal_type == 1:
                if k % 7 == 2 and sh:
                    ops_.append((1, [curfn - pn(sh[0]) - 1]))
                    sh.pop(0)
                elif k % 7 == 3 and sh:
                    ops_.append((4, [2]))
                    sim["maxlt"] = 1
                    for i in [i for i in lg if i > 1]:
                        del lg[i]
                    ops_.append((3, [curfn - pn(sh[0]) - 1, 1]))
                    lg[1] = sh.pop(0)
                elif k % 7 == 4 and sh and sim["maxlt"] >= 0:
                    ops_.append((3, [curfn - pn(sh[-1]) - 1, 0]))
                    lg[0] = sh.pop()
                elif k % 7 == 5 and 1 in lg:
                    ops_.append((2, [1]))
                    del lg[1]
                elif k % 7 == 6 and h["pic"] % 2 == 0:
                    ops_.append((5, []))
                    sh.clear()
                    lg.clear()
                    sim["maxlt"] = -1
                elif k % 7 == 0:
                    ops_.append((4, [0]))
                    lg.clear()
                    sim["maxlt"] = -1
                if ops_:
                    while len(sh) + len(lg) + 1 > nref:
                        if sh:
                            ops_.append((1, [curfn - pn(sh[0]) - 1]))
                            sh.pop(0)
                        else:
                            i = max(lg)
                            ops_.append((2, [i]))
                            del lg[i]
                    h["mark"] = ("adaptive", ops_)
                elif len(sh) + len(lg) >= max(nref, 1):
                    sh.pop(0)                    # sliding window
            if any(op == 5 for op, _ in ops_):
                sim["short"] = [0]               # the picture counts as frame_num 0
            else:
                sh.append(curfn)
            sim["short"] = [x for x in sim["short"]]
        if "reorder" in opts and st == 0:
            nref = (h["nref_override"] or [ppss[obj["pps"]]["nref0"]])[0]
            # reverse: ask for PicNum - nref, - nref + 1, ... (abs diff steps)
            if nref > 1:
                ops_ = [(0, nref - 1)] + [(1, 0)] * (nref - 1)
                h["rplm"][0] = ops_
        hdr_out = hdr
        if "mmco" in opts:
            # after MMCO 5 frame_num starts again (the picture counts as 0)
            if nal_type == 5:
                fn_base = 0
            log2 = nspss[nppss[h["pps"]]["sps"]]["log2fn"]
            if newpic:
                pic_fn_orig = h["frame_num"]
            h["frame_num"] = (h["frame_num"] - fn_base) % (1 << log2)
            if h["mark"] and h["mark"][0] == "adaptive" and any(op == 5 for op, _ in h["mark"][1]):
                mmco5_pending = pic_fn_orig
        emit(hdr_out, write_slice(h, nspss, nppss))
        if "redundant" in opts and h["first_mb"] > 0:
            # (only for slices that do not start the picture: ffmpeg, the
            # reference decoder, starts a new picture at any slice with
            # first_mb_in_slice 0 before it looks at redundant_pic_cnt)
            r = dict(h)
            r["rpc"] = 1
            junk = bytearray(h["rbsp"])
            for i in range((h["data_start"] >> 3) + 1, len(junk) - 1):
                junk[i] = rnd.randrange(256)
            r["rbsp"] = bytes(junk)
            emit(hdr_out, write_slice(r, nspss, nppss))
    if "eos" in opts:
        out.append(bytes([0x0B]))                              # end of stream
    return join(out)


# ----------------------------------------------------- synthetic I_PCM stream
def ue_bits(w, v):
    w.ue(v)


def synth(w_mb, h_mb, frames):
    """A stream x264 cannot make: I_PCM macroblocks mixed with Intra16x16 DC
    macroblocks (with and without DC coefficients), then P pictures of skips
    and 16x16 motion; deblocking on (I_PCM counts as qP 0)."""
    import random
    rnd = random.Random(7)
    out = []
    # SPS: Baseline, level 3, POC type 2, 1 ref
    w = BitWriter()
    w.u(8, 66); w.u(8, 0xC0); w.u(8, 30); w.ue(0)
    w.ue(0)            # log2_max_frame_num 4
    w.ue(2)            # poc type 2
    w.ue(1)            # 1 ref
    w.u(1, 0)
    w.ue(w_mb - 1); w.ue(h_mb - 1)
    w.u(1, 1); w.u(1, 1); w.u(1, 0); w.u(1, 0)
    w.trailing()
    out.append(bytes([0x67]) + escape(w.bytes()))
    w = BitWriter()
    w.ue(0); w.ue(0); w.u(1, 0); w.u(1, 0); w.ue(0)
    w.ue(0); w.ue(0); w.u(1, 0); w.u(2, 0)
    w.se(4)            # pic_init_qp 30
    w.se(0); w.se(2)   # chroma_qp_index_offset 2
    w.u(1, 1)          # deblocking_filter_control_present
    w.u(1, 0); w.u(1, 0)
    w.trailing()
    out.append(bytes([0x68]) + escape(w.bytes()))
    nmb = w_mb * h_mb
    for f in range(frames):
        idr = f == 0
        w = BitWriter()
        w.ue(0)
        w.ue(7 if idr else 5)          # I or P (all slices same type)
        w.ue(0)
        w.u(4, f & 15)
        if idr:
            w.ue(0)
        else:
            w.u(1, 0)                  # num_ref_idx_active_override
            w.u(1, 0)                  # no list modification
        if idr:
            w.u(1, 0); w.u(1, 0)       # marking
        else:
            w.u(1, 0)                  # sliding window
        w.se(0)                        # slice_qp_delta: QP 30
        w.ue(0); w.se(1); w.se(-1)     # deblocking on, offsets 2 / -2
        if idr:
            for mb in range(nmb):
                if (mb * 7 + 3) % 3 == 0 or mb == 0:
                    w.ue(25)                       # I_PCM
                    while len(w.bits) % 8:
                        w.bits.append(0)
                    base = rnd.randrange(30, 220)
                    for i in range(384):
                        v = base + rnd.randrange(-20, 21) + (i % 16) * 2
                        w.u(8, max(1, min(255, v)))
                else:
                    # I_16x16_2_0_0: DC prediction, no AC, no chroma; the DC
                    # block: coeff_token for TotalCoeff 0 (nC from neighbours)
                    w.ue(3)
                    w.ue(0)                        # intra_chroma_pred_mode DC
                    w.se(0)                        # mb_qp_delta
                    # nC: left / above neighbours; I_PCM counts 16, I16 (no
                    # AC) counts 0
                    x, y = mb % w_mb, mb // w_mb
                    def ispcm(m):
                        return (m * 7 + 3) % 3 == 0 or m == 0
                    na = 16 if x > 0 and ispcm(mb - 1) else 0
                    nb = 16 if y > 0 and ispcm(mb - w_mb) else 0
                    if x > 0 and y > 0:
                        nc = (na + nb + 1) >> 1
                    elif x > 0:
                        nc = na
                    elif y > 0:
                        nc = nb
                    else:
                        nc = 0
                    # TotalCoeff 0: "1" (nC<2), "11" (2..3), "1111" (4..7), "000011" (>=8)
                    if nc < 2:
                        w.u(1, 1)
                    elif nc < 4:
                        w.u(2, 3)
                    elif nc < 8:
                        w.u(4, 15)
                    else:
                        w.u(6, 3)
        else:
            mb = 0
            while mb < nmb:
                run = rnd.randrange(0, 4)
                run = min(run, nmb - mb)
                w.ue(run)
                mb += run
                if mb >= nmb:
                    break
                w.ue(0)                            # P_L0_16x16 (ref 0)
                w.se(rnd.randrange(-40, 41))       # mvd x
                w.se(rnd.randrange(-40, 41))       # mvd y
                w.ue(0)                            # coded_block_pattern 0
                mb += 1
        w.trailing()
        out.append(bytes([0x65 if idr else 0x41]) + escape(w.bytes()))
    return join(out)


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "synth":
        wmb = int(sys.argv[3]) if len(sys.argv) > 3 else 6
        hmb = int(sys.argv[4]) if len(sys.argv) > 4 else 5
        frames = int(sys.argv[5]) if len(sys.argv) > 5 else 8
        open(sys.argv[2], "wb").write(synth(wmb, hmb, frames))
        return
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    data = open(sys.argv[2], "rb").read()
    open(sys.argv[3], "wb").write(rewrite(sys.argv[1], data))


if __name__ == "__main__":
    main()
