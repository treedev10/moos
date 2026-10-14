#!/usr/bin/env python3
"""
mp4_data.py - make the test files for mp4_test.c and their references.

    python3 tests/native/mp4_data.py        # writes build/mp4/*.mp4 + *.ref + list.txt
    python3 tests/native/run.py mp4         # checks src/mp4.asm against them

Files are made with ffmpeg (libx264 + aac) in the shapes that matter for
MOOS: YouTube-style progressive MP4 (itag 18: H.264 baseline 640x360 + AAC
LC 44.1 kHz stereo) with the moov box first (faststart) and last, audio
only, video only, B-frames (ctts, also with negative offsets), a long file,
a delayed track (empty edit), a stream-copy cut (edit list starting
mid-frame), a QuickTime .mov (version 1 sound description, esds inside a
'wave' box), a fragmented file, and unsupported codecs. Then some are
rewritten with mp4box.py into shapes ffmpeg never writes: 64-bit box sizes,
a size-0 last box, co64, stz2 (16/8/4-bit), version-1 headers, a constant
sample size, extra boxes everywhere, and odd edit lists.

The reference for each file is what ffprobe says (-show_streams -show_data,
-show_packets) — an independent demuxer. Where ffmpeg deliberately differs
from the plain reading of the spec, the reference says so:
  - ffprobe gives the encoder-delay packets that the edit list hides
    (flag D) negative (and for audio, rewritten) times: MOOS clamps to 0.
  - when an edit starts in the middle of a video frame, ffmpeg drops that
    frame and moves the track so the next frame is at 0; MOOS keeps the
    spec's timing. The reference carries that shift (Python, from the
    tables) so the check stays exact.
  - for edit lists ffmpeg turns into a new packet list (several real edits,
    repeated segments), the reference is a Python model of MOOS's
    documented rules instead (marked "model").
  - a track's length: ffprobe's duration_ts for no or one edit; with
    several edits MOOS gives the end of the presentation (empty edits +
    the first real edit), checked against the same rule in Python.
"""
import json
import os
import struct
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mp4box  # noqa: E402
from mp4box import Box  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "build", "mp4")
FF = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"]


def ff(args, out):
    subprocess.run(FF + args.split() + [os.path.join(OUT, out)], check=True)


def src(w=640, h=360, rate=30, t=10, sr=44100, ac=2, audio=True, video=True):
    a = []
    if video:
        a += ["-f lavfi -i testsrc2=size=%dx%d:rate=%d" % (w, h, rate)]
    if audio:
        a += ["-f lavfi -i sine=frequency=440:beep_factor=4:sample_rate=%d" % sr]
    a += ["-t %g" % t]
    if audio:
        a += ["-ac %d" % ac]
    return " ".join(a)


YT = "-c:v libx264 -profile:v baseline -level 3.0 -pix_fmt yuv420p -g 60 -c:a aac -b:a 96k"
BF = "-c:v libx264 -profile:v high -bf 3 -g 48 -pix_fmt yuv420p -c:a aac"


def p(name):
    return os.path.join(OUT, name)


# ---------------------------------------------------------------- rewriting
def load(name):
    data = open(p(name), "rb").read()
    boxes = mp4box.parse(data)
    mdat = [b for b in boxes if b.type == b"mdat"][0]
    return boxes, mdat.offset + mdat.hdr


def moov_of(boxes):
    return [b for b in boxes if b.type == b"moov"][0]


def to_v1(b):
    """Rewrite an mvhd / tkhd / mdhd (version 0) as version 1 (64-bit times)."""
    d = b.data
    if d[0] != 0:
        return
    if b.type in (b"mvhd", b"mdhd"):
        ct, mt, ts, dur = struct.unpack_from(">IIII", d, 4)
        b.data = b"\x01" + d[1:4] + struct.pack(">QQIQ", ct, mt, ts, dur) + d[20:]
    elif b.type == b"tkhd":
        ct, mt, tid, res, dur = struct.unpack_from(">IIIII", d, 4)
        b.data = b"\x01" + d[1:4] + struct.pack(">QQIIQ", ct, mt, tid, res, dur) + d[24:]


def elst_entries(b):
    v = b.data[0]
    n = struct.unpack_from(">I", b.data, 4)[0]
    out = []
    for i in range(n):
        if v == 1:
            d, t, r = struct.unpack_from(">Qqi", b.data, 8 + 20 * i)
        else:
            d, t, r = struct.unpack_from(">Iii", b.data, 8 + 12 * i)
        out.append((d, t, r))
    return out


def make_elst(entries, v1=False):
    if v1:
        body = b"".join(struct.pack(">Qqi", d, t, r) for d, t, r in entries)
        return Box(b"elst", struct.pack(">II", 1 << 24, len(entries)) + body)
    body = b"".join(struct.pack(">Iii", d, t, r) for d, t, r in entries)
    return Box(b"elst", struct.pack(">II", 0, len(entries)) + body)


def set_elst(trak, entries, v1=False):
    edts = trak.find(b"edts")
    if edts is None:
        edts = Box(b"edts", children=[])
        trak.children.insert(1, edts)
    edts.children = [make_elst(entries, v1)]


def walk(b):
    yield b
    for c in b.children or []:
        yield from walk(c)


# -------------------------------------------------------------- the files
CASES = []


def case(name, expect=0, model=False):
    def reg(fn):
        CASES.append((name, fn, expect, model))
        return fn
    return reg


@case("yt18.mp4")
def _():
    ff(src() + " " + YT + " -movflags +faststart", "yt18.mp4")


@case("yt18_end.mp4")
def _():
    ff(src() + " " + YT, "yt18_end.mp4")


@case("audio.mp4")
def _():
    ff(src(t=20, sr=48000, video=False) + " -c:a aac -b:a 128k", "audio.mp4")


@case("video.mp4")
def _():
    ff(src(320, 240, 25, 6, audio=False) + " -c:v libx264 -g 50 -pix_fmt yuv420p", "video.mp4")


@case("bframes.mp4")
def _():
    ff(src(320, 240, 25, 8, sr=48000) + " " + BF, "bframes.mp4")


@case("negcts.mp4")
def _():
    ff(src(320, 240, 25, 6, sr=48000) + " " + BF + " -movflags negative_cts_offsets", "negcts.mp4")


@case("noedit.mp4")
def _():
    ff(src(320, 240, 25, 6, sr=48000) + " " + BF + " -use_editlist 0", "noedit.mp4")


@case("long.mp4")
def _():
    ff(src(160, 90, 30, 1500, sr=44100) + " -c:v libx264 -preset ultrafast -g 150 -pix_fmt yuv420p"
       " -c:a aac -b:a 32k -movflags +faststart", "long.mp4")


@case("mono22.mp4")
def _():
    ff(src(176, 144, 15, 5, sr=22050, ac=1) + " -c:v libx264 -g 30 -pix_fmt yuv420p -c:a aac", "mono22.mp4")


@case("surround.mp4")
def _():
    ff(src(176, 144, 24, 4, sr=96000, ac=6) + " -c:v libx264 -pix_fmt yuv420p -c:a aac", "surround.mp4")


@case("allkey.mp4")
def _():
    # every frame a key frame: the muxer writes no stss box
    ff(src(176, 144, 25, 3) + " -c:v libx264 -g 1 -pix_fmt yuv420p -c:a aac", "allkey.mp4")


def _bsrc():
    path = p("bsrc.mp4")
    if not os.path.exists(path):
        ff(src(320, 240, 25, 8, sr=48000) + " -c:v libx264 -bf 3 -g 100 -pix_fmt yuv420p -c:a aac", "bsrc.mp4")
    return path


@case("delay.mp4")
def _():
    s = _bsrc()
    subprocess.run(FF + ["-i", s, "-itsoffset", "1.5", "-i", s, "-map", "0:v", "-map", "1:a",
                         "-c", "copy", p("delay.mp4")], check=True)


@case("cut.mp4")
def _():
    subprocess.run(FF + ["-ss", "2.3", "-i", _bsrc(), "-c", "copy", p("cut.mp4")], check=True)


@case("quicktime.mov")
def _():
    subprocess.run(FF + ["-i", _bsrc(), "-c", "copy", "-f", "mov", p("quicktime.mov")], check=True)


@case("frag.mp4", expect=-3)
def _():
    subprocess.run(FF + ["-i", _bsrc(), "-c", "copy", "-movflags", "frag_keyframe+empty_moov",
                         p("frag.mp4")], check=True)


@case("mpeg4mp2.mp4", expect=-4)
def _():
    ff(src(176, 144, 25, 2, sr=44100) + " -c:v mpeg4 -c:a mp2", "mpeg4mp2.mp4")


@case("mpeg4aac.mp4")
def _():
    ff(src(176, 144, 25, 2, sr=44100) + " -c:v mpeg4 -c:a aac", "mpeg4aac.mp4")


@case("twovideo.mp4")
def _():
    # an MPEG-4 part 2 video track first, then the H.264 one MOOS should pick
    ff(src(176, 144, 25, 2, sr=44100) + " -map 0:v -map 0:v -map 1:a -c:v:0 mpeg4 -c:v:1 libx264"
       " -pix_fmt yuv420p -c:a aac", "twovideo.mp4")


@case("audiofirst.mp4")
def _():
    ff(src(176, 144, 25, 3, sr=44100) + " -map 1:a -map 0:v -c:v libx264 -pix_fmt yuv420p -c:a aac",
       "audiofirst.mp4")


# --- rewrites of ffmpeg's files
@case("co64.mp4")
def _():
    boxes, old = load("yt18.mp4")
    for t in mp4box.tracks(moov_of(boxes)):
        st = mp4box.stbl_of(t)
        mp4box.set_chunk_offsets(st, mp4box.chunk_offsets(st), use64=True)
    mp4box.write_file(p("co64.mp4"), boxes, old)


@case("stz2.mp4")
def _():
    boxes, old = load("yt18_end.mp4")
    for t in mp4box.tracks(moov_of(boxes)):
        if mp4box.handler(t) == b"soun":
            mp4box.to_stz2(mp4box.stbl_of(t), 16)
    mp4box.write_file(p("stz2.mp4"), boxes, old)


def _shrink_sizes(name, out, field, limit):
    """Audio sample sizes made to fit a small field (the data no longer
    matches the sizes, which does not matter for demuxing)."""
    boxes, old = load(name)
    for t in mp4box.tracks(moov_of(boxes)):
        if mp4box.handler(t) == b"soun":
            st = mp4box.stbl_of(t)
            sz = st.find(b"stsz")
            n = struct.unpack_from(">I", sz.data, 8)[0]
            sizes = [(i * 7 + 3) % limit for i in range(n)]
            sz.data = sz.data[:12] + b"".join(struct.pack(">I", s) for s in sizes)
            mp4box.to_stz2(st, field)
    mp4box.write_file(p(out), boxes, old)


@case("stz2_8.mp4")
def _():
    _shrink_sizes("yt18.mp4", "stz2_8.mp4", 8, 256)


@case("stz2_4.mp4")
def _():
    _shrink_sizes("yt18.mp4", "stz2_4.mp4", 4, 16)


@case("constsize.mp4")
def _():
    boxes, old = load("yt18.mp4")
    for t in mp4box.tracks(moov_of(boxes)):
        if mp4box.handler(t) == b"soun":
            sz = mp4box.stbl_of(t).find(b"stsz")
            n = struct.unpack_from(">I", sz.data, 8)[0]
            sz.data = struct.pack(">III", 0, 200, n)
    mp4box.write_file(p("constsize.mp4"), boxes, old)


@case("big.mp4")
def _():
    # 64-bit sizes on mdat, moov (at the end) and many boxes inside it
    boxes, old = load("yt18_end.mp4")
    for b in boxes:
        if b.type in (b"mdat", b"moov", b"ftyp"):
            b.big = True
    for b in walk(moov_of(boxes)):
        if b.type in (b"trak", b"mdia", b"stbl", b"stco", b"stsz", b"stts", b"avcC", b"mvhd"):
            b.big = True
    mp4box.write_file(p("big.mp4"), boxes, old)


@case("zero.mp4")
def _():
    # moov first, then an mdat of size 0 ("to the end of the file")
    boxes, old = load("yt18.mp4")
    boxes = [b for b in boxes if b.type != b"free"]
    assert boxes[-1].type == b"mdat"
    boxes[-1].zero = True
    mp4box.write_file(p("zero.mp4"), boxes, old)


@case("v1.mp4")
def _():
    boxes, old = load("bframes.mp4")
    moov = moov_of(boxes)
    for b in walk(moov):
        if b.type in (b"mvhd", b"tkhd", b"mdhd"):
            to_v1(b)
    for t in mp4box.tracks(moov):
        e = t.find(b"edts").find(b"elst")
        set_elst(t, elst_entries(e), v1=True)
    mp4box.write_file(p("v1.mp4"), boxes, old)


@case("extra.mp4")
def _():
    # unknown and padding boxes everywhere, and udta inside the tracks
    boxes, old = load("yt18.mp4")
    moov = moov_of(boxes)
    junk = lambda: Box(b"free", b"\0" * 13)  # noqa: E731
    moov.children.insert(0, Box(b"uuid", b"\x11" * 16 + b"hello"))
    moov.children.insert(2, junk())
    for t in mp4box.tracks(moov):
        t.children.insert(0, junk())
        t.children.append(Box(b"udta", children=[Box(b"name", b"track")]))
        st = mp4box.stbl_of(t)
        st.children.insert(1, junk())
        st.children.append(Box(b"sdtp", b"\0" * 20))
    i = [b.type for b in boxes].index(b"moov")
    boxes.insert(i, Box(b"skip", b"x" * 100))
    boxes.insert(1, Box(b"uuid", b"\x22" * 16))
    mp4box.write_file(p("extra.mp4"), boxes, old)


@case("topmeta.mp4")
def _():
    # other top-level boxes between mdat and a moov at the end (meta with
    # XMP, udta, free): a player that fetches the file in parts restarts
    # mp4_find_moov at each of them
    boxes, old = load("yt18_end.mp4")
    i = [b.type for b in boxes].index(b"moov")
    boxes[i:i] = [Box(b"meta", b"\0\0\0\0" + Box(b"hdlr", b"\0" * 8 + b"mdir" + b"\0" * 13).encode()
                      + Box(b"XMP_", b"<x:xmpmeta/>").encode()),
                  Box(b"udta", Box(b"name", b"title").encode()),
                  Box(b"free", b"\0" * 7)]
    mp4box.write_file(p("topmeta.mp4"), boxes, old)


@case("oddedit.mp4", model=True)
def _():
    # several edits: two empty ones, a real one, then a repeat (MOOS uses
    # the first real one); audio: an edit with rate 2 (rate ignored)
    boxes, old = load("bframes.mp4")
    moov = moov_of(boxes)
    for t in mp4box.tracks(moov):
        if mp4box.handler(t) == b"vide":
            set_elst(t, [(300, -1, 1 << 16), (200, -1, 1 << 16), (2000, 2048, 1 << 16),
                         (1000, 512, 1 << 16)])
        else:
            set_elst(t, [(4000, 3000, 2 << 16)], v1=True)
    mp4box.write_file(p("oddedit.mp4"), boxes, old)


@case("emptyonly.mp4", model=True)
def _():
    # only an empty edit on the video, a media time past the end on audio
    boxes, old = load("yt18.mp4")
    for t in mp4box.tracks(moov_of(boxes)):
        if mp4box.handler(t) == b"vide":
            set_elst(t, [(700, -1, 1 << 16)])
        else:
            set_elst(t, [(1000, 10 ** 9, 1 << 16)])
    mp4box.write_file(p("emptyonly.mp4"), boxes, old)


@case("avc3.mp4")
def _():
    boxes, old = load("video.mp4")
    for t in mp4box.tracks(moov_of(boxes)):
        st = mp4box.stbl_of(t).find(b"stsd")
        st.data = st.data[:12] + b"avc3" + st.data[16:]
    mp4box.write_file(p("avc3.mp4"), boxes, old)


# ------------------------------------------------------------ references
def avcc_parts(x):
    """First SPS and PPS of an avcC record (empty if missing)."""
    sps = pps = b""
    try:
        n = x[5] & 31
        i = 6
        for k in range(n):
            ln = struct.unpack_from(">H", x, i)[0]
            if k == 0:
                sps = x[i + 2:i + 2 + ln]
            i += 2 + ln
        n = x[i]
        i += 1
        for k in range(n):
            ln = struct.unpack_from(">H", x, i)[0]
            if k == 0:
                pps = x[i + 2:i + 2 + ln]
            i += 2 + ln
    except (IndexError, struct.error):
        pass
    return sps, pps


def hexdata(s):
    """ffprobe's hexdump text -> bytes."""
    out = b""
    for line in (s or "").strip().splitlines():
        hexpart = line.split(":", 1)[1][:40]
        out += bytes.fromhex(hexpart.replace(" ", ""))
    return out


def track_tables(trak):
    """Python model of MOOS's sample table rules (see src/mp4.asm)."""
    st = mp4box.stbl_of(trak)
    sz = st.find(b"stsz")
    if sz is not None:
        const, n = struct.unpack_from(">II", sz.data, 4)
        sizes = [const] * n if const else list(struct.unpack_from(">%dI" % n, sz.data, 12))
    else:
        z = st.find(b"stz2")
        field = z.data[7]
        n = struct.unpack_from(">I", z.data, 8)[0]
        body = z.data[12:]
        if field == 16:
            sizes = list(struct.unpack_from(">%dH" % n, body))
        elif field == 8:
            sizes = list(body[:n])
        else:
            sizes = [(body[i >> 1] >> (0 if i & 1 else 4)) & 15 for i in range(n)]
    co = mp4box.chunk_offsets(st)
    sc = st.find(b"stsc")
    nsc = struct.unpack_from(">I", sc.data, 4)[0]
    stsc = [struct.unpack_from(">III", sc.data, 8 + 12 * i) for i in range(nsc)]
    offs = []
    e = 0
    for k in range(1, len(co) + 1):
        while e + 1 < len(stsc) and stsc[e + 1][0] <= k:
            e += 1
        spc = stsc[e][1] if stsc[e][0] <= k else 0
        o = co[k - 1]
        for _ in range(spc):
            if len(offs) >= n:
                break
            offs.append(o)
            o += sizes[len(offs) - 1]
    n = len(offs)
    tt = st.find(b"stts")
    ntt = struct.unpack_from(">I", tt.data, 4)[0]
    stts = [struct.unpack_from(">II", tt.data, 8 + 8 * i) for i in range(ntt)]
    deltas = []
    for c, d in stts:
        deltas += [d] * c
    while len(deltas) < n:
        deltas.append(stts[-1][1])
    ct = st.find(b"ctts")
    cts = []
    if ct is not None:
        nct = struct.unpack_from(">I", ct.data, 4)[0]
        for i in range(nct):
            c, o = struct.unpack_from(">Ii", ct.data, 8 + 8 * i)
            cts += [o] * c
    cts += [0] * max(0, n - len(cts))
    dts = [0] * n
    for i in range(1, n):
        dts[i] = dts[i - 1] + deltas[i - 1]
    ss = st.find(b"stss")
    if ss is None:
        sync = [1] * n
    else:
        sync = [0] * n
        nss = struct.unpack_from(">I", ss.data, 4)[0]
        for i in range(nss):
            k = struct.unpack_from(">I", ss.data, 8 + 4 * i)[0]
            if 1 <= k <= n:
                sync[k - 1] = 1
    return offs, sizes[:n], dts, cts[:n], sync, deltas[:n]


def mdhd_of(trak):
    md = trak.find(b"mdia").find(b"mdhd").data
    if md[0] == 1:
        return struct.unpack_from(">IQ", md, 20)
    return struct.unpack_from(">II", md, 12)


def mvhd_scale(moov):
    mv = moov.find(b"mvhd").data
    return struct.unpack_from(">I", mv, 20 if mv[0] == 1 else 12)[0]


def rescale(x, a, b):
    if b == 0:
        return 0
    return min((x * a + b // 2) // b, 0xFFFFFFFF)


def edit_rule(trak, mscale):
    """(shift, duration, entries) by MOOS's rules."""
    ts, mdur = mdhd_of(trak)
    mdur = min(mdur, 0xFFFFFFFF)
    edts = trak.find(b"edts")
    ents = elst_entries(edts.find(b"elst")) if edts is not None and edts.find(b"elst") else []
    if not ents:
        return 0, mdur, ents
    empty = 0
    media, seg = 0, 0
    for d, t, r in ents:
        if t == -1:
            empty = min(empty + d, 0xFFFFFFFF)
            continue
        if t < 0:
            return 0, mdur, ents
        media, seg = t, d
        break
    e = rescale(empty, ts, mscale)
    shift = max(media - e, -(1 << 31))
    if seg:
        dur = rescale(min(empty + seg, 0xFFFFFFFF), ts, mscale)
    else:
        dur = max(mdur - media, 0) + e
    return shift, (dur or mdur), ents


def make_ref(name, expect, model):
    path = p(name)
    boxes = mp4box.parse(open(path, "rb").read())
    moov = moov_of(boxes)
    mscale = mvhd_scale(moov)
    traks = mp4box.tracks(moov)
    pr = json.loads(subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-show_data", "-of", "json",
                                    path], capture_output=True, check=True, text=True).stdout)
    streams = pr["streams"]
    lines = ["EXPECT %d" % expect]
    picks = {}
    for kind, ctype, cname in (("V", "video", "h264"), ("A", "audio", "aac")):
        cand = [s for s in streams if s["codec_type"] == ctype]
        good = [s for s in cand if s.get("codec_name") == cname]
        s = good[0] if good else (cand[0] if cand else None)
        if s is None:
            lines.append("%s none" % kind)
            continue
        ok = 1 if (good and expect == 0) else 0
        idx = s["index"]
        tag = s["codec_tag_string"]
        if len(tag) != 4:
            tag = mp4box.stbl_of(traks[idx]).find(b"stsd").data[12:16].decode("latin1")
        lines.append("%s %d %s %d" % (kind, ok, tag, idx))
        picks[kind] = (idx, s, ok)
    pk = None
    if any(v[2] for v in picks.values()) and not model:
        pk = json.loads(subprocess.run(["ffprobe", "-v", "error", "-show_packets", "-show_entries",
                                        "packet=stream_index,pts,dts,pos,size,flags", "-of", "json", path],
                                       capture_output=True, check=True, text=True).stdout)["packets"]
    for kind, (idx, s, ok) in picks.items():
        if not ok:
            continue
        trak = traks[idx]
        ts = int(s["time_base"].split("/")[1])
        shift, dur, ents = edit_rule(trak, mscale)
        if len([e for e in ents if e[1] != -1]) <= 1 and not model and len(ents) <= 1:
            dur = int(s["duration_ts"])            # ffprobe's own length
        ex = hexdata(s.get("extradata"))
        if kind == "V":
            sps, pps = avcc_parts(ex)
            lines.append("VI %d %d %d %d %d %s %s %s" % (s["width"], s["height"], ts, dur,
                         int(s.get("nal_length_size", 0)), ex.hex() or "-", sps.hex() or "-", pps.hex() or "-"))
        else:
            lines.append("AI %d %d %d %d %s" % (int(s["sample_rate"]), s["channels"], ts, dur, ex.hex() or "-"))
        offs, sizes, dts, cts, sync, deltas = track_tables(trak)
        if model:
            for i in range(len(offs)):
                pts = dts[i] + cts[i] - shift
                hidden = "D" if pts + deltas[i] <= 0 else ""
                pts = min(max(pts, 0), 0xFFFFFFFF)
                lines.append("P %s %d %d %d %s%s" % (kind, offs[i], sizes[i], pts, "K" if sync[i] else "_",
                                                     hidden))
            continue
        # ffmpeg's extra shift for an edit starting inside a video frame
        corr = 0
        real = [e for e in ents if e[1] != -1]
        if kind == "V" and real:
            m = real[0][1]
            kept = [dts[i] + cts[i] for i in range(len(dts)) if dts[i] + cts[i] >= m]
            if kept:
                corr = max(min(kept) - m, 0)
        lines.append("%sO %d" % (kind, corr))
        for q in pk:
            if q["stream_index"] != idx:
                continue
            fl = q.get("flags", "___")
            lines.append("P %s %s %s %s %s" % (kind, q["pos"], q["size"], q.get("pts", "N/A"),
                                               ("K" if "K" in fl else "_") + ("D" if "D" in fl else "")))
    with open(path + ".ref", "w") as f:
        f.write("\n".join(lines) + "\n")


def main():
    os.makedirs(OUT, exist_ok=True)
    only = sys.argv[1:]
    names = []
    for name, fn, expect, model in CASES:
        names.append(name)
        if only and name not in only:
            continue
        print("making", name)
        fn()
        make_ref(name, expect, model)
    with open(os.path.join(OUT, "list.txt"), "w") as f:
        f.write("\n".join(names) + "\n")
    print("%d files in %s" % (len(names), os.path.relpath(OUT, ROOT)))


if __name__ == "__main__":
    main()
