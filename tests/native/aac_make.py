#!/usr/bin/env python3
"""
Make the test data for aac_test.c (the AAC-LC decoder, src/aac.asm).

    python tests/native/aac_make.py [--quick] [--variants]

(--variants: only remake the variants below from the cases already there)

For each case an .m4a is encoded with ffmpeg's AAC encoder from a synthetic
lavfi source, then
    NAME.adts   the same access units in ADTS framing (ffmpeg -c copy -f adts)
    NAME.asc    the AudioSpecificConfig, taken from the .m4a's esds box
    NAME.ref    what the decoder must output: ffmpeg's own decode, as 16-bit
                interleaved PCM (mono or stereo; more channels are downmixed
                to stereo here with the same matrix aac.asm uses)
and a line in build/aac/manifest.txt:  NAME MODE [ARG] [rate=R] [ch=C]
    snr  DB      SNR against NAME.ref must be at least DB
    pns  DB      PNS (random noise) is in use: band energies within DB of ref
    exact        output must equal NAME.ref (silence)
    same OTHER   decodes like case OTHER (variants: other headers, extra
                 elements); compared with OTHER.ref like snr 70
    rate=, ch=   what aac_info must report, when the ADTS header does not
                 say it (explicit rates, a PCE)

Variants made from the frames of other cases (no encoder needed):
  *_sbr5 / *_ps29 / *_sbrsync   HE-AAC signalling in the AudioSpecificConfig
                                (explicit AOT 5, AOT 29, sync extension 0x2b7):
                                only the AAC-LC core is decoded
  *_fil                         every frame starts with a FIL element (fill
                                data), a FIL with an SBR payload, a DSE and a
                                coupling channel element (CCE) with an empty
                                spectrum - all must be skipped
  *_explicit / *_rate44000       the sampling rate written out (index 15)
                                in the AudioSpecificConfig
Variants rewritten with aac_rewrite.py (parsed down to the spectral values
and written back), for what ffmpeg's encoder never writes:
  *_pulses     pulse data            *_tnshigh   TNS filters of order 9-12
  *_pnsms      M/S on noise bands of both channels (one shared noise)
  *_split      short windows: one window per group
  *_separate   common_window 0 instead of a shared ics_info
  *_cce        a coupling channel element with spectral data, a byte-aligned
               data stream element and a PCE before each frame's elements
  *_lfe        mono as an LFE element (PCE configuration with one LFE)
Changes that alter the sound (pulses, tnshigh, pnsms) are compared with
ffmpeg's decode of the rewritten stream; the others must decode exactly
like the original, which is also checked with ffmpeg where it can read them.
All files go to build/aac/. Needs ffmpeg, ffprobe, numpy.
"""
import os
import random
import struct
import subprocess
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import aac_rewrite                      # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "build", "aac")
A = 0.7071067811865476      # downmix weight of centre / surround channels

DUR = 5

# lavfi sources (mono expressions; stereo ones give two channels)
SRC = {
    "sweep": "aevalsrc='0.5*sin(2*PI*(50*t+1000*t*t))':s=96000",
    "sweep2": "aevalsrc='0.5*sin(2*PI*(50*t+1000*t*t))|0.4*sin(2*PI*(8000*t-600*t*t))':s=96000",
    "tones": "aevalsrc='0.3*sin(2*PI*440*t)+0.2*sin(2*PI*1250*t)+0.1*sin(2*PI*5300*t)':s=96000",
    "white": "anoisesrc=color=white:amplitude=0.25:seed=7:r=96000",
    "pink": "anoisesrc=color=pink:amplitude=0.6:seed=11:r=96000",
    "music": ("aevalsrc='(0.18*sin(2*PI*220*t)+0.12*sin(2*PI*277.2*t)+0.12*sin(2*PI*329.6*t)"
              "+0.06*sin(2*PI*440*t)+0.05*sin(2*PI*880*t)+0.03*sin(2*PI*1760*t))"
              "*(0.6+0.4*sin(2*PI*1.5*t))+0.15*sin(2*PI*(660+30*sin(2*PI*5*t))*t)*gt(mod(t,1),0.5)"
              "|(0.18*sin(2*PI*196*t)+0.12*sin(2*PI*246.9*t)+0.12*sin(2*PI*293.7*t)"
              "+0.07*sin(2*PI*587.3*t)+0.04*sin(2*PI*1174.7*t))*(0.7+0.3*cos(2*PI*t))"
              "+0.1*sin(2*PI*3520*t)*exp(-6*mod(t,0.5))':s=96000"),
    "speech": ("aevalsrc='0.5*(0.5+0.5*sin(2*PI*3*t))*(sin(2*PI*(130+20*sin(2*PI*2*t))*t)"
               "+0.6*sin(4*PI*(130+20*sin(2*PI*2*t))*t)+0.4*sin(6*PI*(130+20*sin(2*PI*2*t))*t)"
               "+0.25*sin(2*PI*700*t)*sin(2*PI*(130+20*sin(2*PI*2*t))*t)"
               "+0.15*sin(2*PI*2400*t)*sin(2*PI*(130+20*sin(2*PI*2*t))*t))"
               "*gt(mod(t,0.8),0.15)+0.08*(random(0)-0.5)*lt(mod(t,0.8),0.15)':s=96000"),
    "clicks": ("aevalsrc='0.9*lt(mod(t,0.25),0.0015)*sin(2*PI*3000*t)"
               "+0.6*(random(1)-0.5)*exp(-80*mod(t+0.1,0.37))+0.05*sin(2*PI*300*t)':s=96000"),
    "clicks2": ("aevalsrc='0.9*lt(mod(t,0.25),0.0015)*sin(2*PI*3000*t)"
                "+0.6*(random(1)-0.5)*exp(-80*mod(t+0.1,0.37))"
                "|0.8*lt(mod(t+0.1,0.3),0.002)+0.5*(random(2)-0.5)*exp(-60*mod(t,0.41))"
                "+0.05*sin(2*PI*500*t)':s=96000"),
    "silence": "anullsrc=r=96000:cl=stereo",
    "wide": ("aevalsrc='0.4*sin(2*PI*440*t)+0.2*(random(3)-0.5)|0.4*sin(2*PI*440*t+1)"
             "+0.2*(random(4)-0.5)':s=96000"),
    "multi": ("aevalsrc='0.3*sin(2*PI*300*t)|0.3*sin(2*PI*500*t)|0.3*sin(2*PI*700*t)"
              "|0.2*sin(2*PI*60*t)|0.25*(random(5)-0.5)|0.25*sin(2*PI*1100*t)"
              "|0.2*sin(2*PI*1300*t)|0.2*sin(2*PI*1700*t)':s=96000"),
}

NOPNS = ["-aac_pns", "0"]


def case_list(quick):
    c = []   # (name, source, rate, channels, bitrate, options, mode, arg)
    # every sampling rate, mono and stereo
    for rate in (8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000, 64000, 88200,
                 96000, 7350):
        br = {8000: 24, 7350: 24, 11025: 32, 12000: 32, 16000: 48, 22050: 64, 24000: 64,
              32000: 96, 44100: 128, 48000: 128, 64000: 160, 88200: 192, 96000: 192}[rate]
        c.append(("music_%d_s" % rate, "music", rate, 2, br * 1000, NOPNS, "snr", 70))
        if not quick:
            c.append(("sweep_%d_m" % rate, "sweep", rate, 1, br * 500, NOPNS, "snr", 70))
    # bitrates 32-320 kbit/s at 44.1 kHz, several signals
    for br in ((32, 64, 128, 320) if quick else (32, 48, 64, 96, 128, 160, 192, 256, 320)):
        c.append(("tones_%dk" % br, "tones", 44100, 2, br * 1000, NOPNS, "snr", 70))
        c.append(("pink_%dk" % br, "pink", 44100, 2, br * 1000, NOPNS, "snr", 70))
        if not quick:
            c.append(("speech_%dk_m" % br, "speech", 44100, 1, br * 500, NOPNS, "snr", 70))
            c.append(("sweep2_%dk" % br, "sweep2", 44100, 2, br * 1000, NOPNS, "snr", 70))
    c.append(("white_128k", "white", 44100, 2, 128000, NOPNS, "snr", 70))
    c.append(("white_48k_m", "white", 48000, 1, 64000, NOPNS, "snr", 70))
    # transients -> short windows (and window shape switching)
    c.append(("clicks_128k", "clicks2", 44100, 2, 128000, NOPNS, "snr", 70))
    c.append(("clicks_64k_m", "clicks", 44100, 1, 64000, NOPNS, "snr", 70))
    c.append(("clicks_48k_48000", "clicks2", 48000, 2, 48000, NOPNS, "snr", 70))
    c.append(("clicks_96k_22050", "clicks", 22050, 1, 96000, NOPNS, "snr", 70))
    # encoder tools
    c.append(("music_fast", "music", 44100, 2, 128000, NOPNS + ["-aac_coder", "fast"], "snr", 70))
    c.append(("music_anmr", "music", 44100, 2, 128000, NOPNS + ["-aac_coder", "anmr", "-strict", "-2"], "snr", 70))
    c.append(("speech_fast_m", "speech", 44100, 1, 64000, NOPNS + ["-aac_coder", "fast"], "snr", 70))
    c.append(("tns_clicks", "clicks2", 44100, 2, 96000, NOPNS + ["-aac_tns", "1"], "snr", 70))
    c.append(("tns_speech", "speech", 44100, 1, 96000, NOPNS + ["-aac_tns", "1"], "snr", 70))
    c.append(("notns_clicks", "clicks2", 44100, 2, 96000, NOPNS + ["-aac_tns", "0"], "snr", 70))
    c.append(("is_wide_64k", "wide", 44100, 2, 64000, NOPNS + ["-aac_is", "1"], "snr", 70))
    c.append(("is_music_48k", "music", 44100, 2, 48000, NOPNS + ["-aac_is", "1"], "snr", 70))
    c.append(("is_tones_40k", "tones", 44100, 2, 40000, NOPNS + ["-aac_is", "1"], "snr", 70))
    c.append(("ms_music", "music", 44100, 2, 128000, NOPNS + ["-aac_ms", "1"], "snr", 70))
    c.append(("ms_wide", "wide", 44100, 2, 96000, NOPNS + ["-aac_ms", "1", "-aac_is", "0"], "snr", 70))
    c.append(("noms_music", "music", 44100, 2, 128000, NOPNS + ["-aac_ms", "0", "-aac_is", "0"],
              "snr", 70))
    c.append(("all_tools", "music", 44100, 2, 64000,
              NOPNS + ["-aac_tns", "1", "-aac_is", "1", "-aac_ms", "1"], "snr", 70))
    # PNS (random noise): compare band energies
    c.append(("pns_pink_64k", "pink", 44100, 2, 64000, ["-aac_pns", "1"], "pns", 1.0))
    c.append(("pns_white_48k_m", "white", 44100, 1, 48000, ["-aac_pns", "1"], "pns", 1.0))
    c.append(("pns_speech_32k", "speech", 44100, 1, 32000, ["-aac_pns", "1"], "pns", 1.0))
    c.append(("pns_music_48k", "music", 48000, 2, 48000,
              ["-aac_pns", "1", "-aac_is", "1", "-aac_tns", "1"], "pns", 1.0))
    c.append(("pns_white_32k_22050", "white", 22050, 2, 32000, ["-aac_pns", "1"], "pns", 1.0))
    # silence
    c.append(("silence_s", "silence", 44100, 2, 128000, [], "exact", 0))
    c.append(("silence_m", "silence", 48000, 1, 64000, [], "exact", 0))
    # more channels: downmixed to stereo (3.0, 4.0, 5.0, 5.1, 7.1; PCE config)
    for ch in ((6,) if quick else (3, 4, 5, 6, 8)):
        c.append(("multi_%dch" % ch, "multi", 48000, ch, 64000 * ch, NOPNS, "snr", 70))
    c.append(("multi_pce", "multi", 44100, 2, 128000, NOPNS + ["-aac_pce", "1"], "snr", 70))
    c.append(("multi_6ch_pce", "multi", 48000, 6, 384000, NOPNS + ["-aac_pce", "1"], "snr", 70))
    # a longer piece for the speed measurement
    c.append(("long_music", "music", 44100, 2, 128000, NOPNS, "snr", 70))
    return c


def run(cmd):
    p = subprocess.run(cmd, capture_output=True)
    if p.returncode:
        sys.exit("failed: %s\n%s" % (" ".join(cmd), p.stderr.decode(errors="replace")[-2000:]))
    return p.stdout


# ----------------------------------------------------------------- MP4 / ADTS
def boxes(data, start, end):
    pos = start
    while pos + 8 <= end:
        size, typ = struct.unpack(">I4s", data[pos:pos + 8])
        hdr = 8
        if size == 1:
            size = struct.unpack(">Q", data[pos + 8:pos + 16])[0]
            hdr = 16
        elif size == 0:
            size = end - pos
        yield typ.decode("latin1"), pos + hdr, pos + size
        pos += size


def find_box(data, path, start=0, end=None):
    end = len(data) if end is None else end
    for typ, s, e in boxes(data, start, end):
        if typ == path[0]:
            if len(path) == 1:
                return s, e
            skip = {"stsd": 8, "mp4a": 28}.get(typ, 0)
            r = find_box(data, path[1:], s + skip, e)
            if r:
                return r
    return None


def descriptor(data, pos):
    tag = data[pos]
    pos += 1
    n = 0
    for _ in range(4):
        b = data[pos]
        pos += 1
        n = (n << 7) | (b & 0x7F)
        if not b & 0x80:
            break
    return tag, pos, n


def asc_from_m4a(path):
    data = open(path, "rb").read()
    r = find_box(data, ["moov", "trak", "mdia", "minf", "stbl", "stsd", "mp4a", "esds"])
    if not r:
        sys.exit("no esds in " + path)
    pos = r[0] + 4                                  # version + flags
    tag, pos, n = descriptor(data, pos)             # ES_Descriptor
    assert tag == 3
    flags = data[pos + 2]
    pos += 3
    if flags & 0x80:
        pos += 2
    if flags & 0x40:
        pos += 1 + data[pos]
    if flags & 0x20:
        pos += 2
    tag, pos, n = descriptor(data, pos)             # DecoderConfigDescriptor
    assert tag == 4
    pos += 13
    tag, pos, n = descriptor(data, pos)             # DecoderSpecificInfo
    assert tag == 5
    return data[pos:pos + n]


def adts_frames(data):
    """split an ADTS stream into (header, raw access unit) pairs"""
    out, pos = [], 0
    while pos + 7 <= len(data):
        assert data[pos] == 0xFF and data[pos + 1] & 0xF0 == 0xF0
        prot_absent = data[pos + 1] & 1
        n = ((data[pos + 3] & 3) << 11) | (data[pos + 4] << 3) | (data[pos + 5] >> 5)
        hl = 7 if prot_absent else 9
        out.append((data[pos:pos + 7], data[pos + hl:pos + n]))
        pos += n
    return out


def adts_join(frames):
    out = bytearray()
    for hdr, raw in frames:
        h = bytearray(hdr)
        h[1] |= 1                                   # no CRC
        n = len(raw) + 7
        h[3] = (h[3] & 0xFC) | (n >> 11)
        h[4] = (n >> 3) & 0xFF
        h[5] = ((n & 7) << 5) | (h[5] & 0x1F)
        out += h + raw
    return bytes(out)


class Bits:
    def __init__(self):
        self.s = []

    def put(self, n, v):
        assert 0 <= v < (1 << n), (n, v)
        self.s.append(format(v, "0%db" % n) if n else "")
        return self

    def bits(self):
        return "".join(self.s)


def to_bytes(bitstr):
    bitstr += "0" * ((-len(bitstr)) % 8)
    return bytes(int(bitstr[i:i + 8], 2) for i in range(0, len(bitstr), 8))


def prepend_elements(raw, rnd, sbr):
    """put extra elements in front of an access unit's own elements"""
    b = Bits()
    # FIL with plain fill data (extension type EXT_FILL = 0)
    n = rnd.randint(1, 40)                          # payload bytes
    b.put(3, 6)
    if n >= 15:
        b.put(4, 15).put(8, n - 14)
    else:
        b.put(4, n)
    b.put(4, 0).put(4, 0)                           # EXT_FILL, fill nibble
    for _ in range(n - 1):
        b.put(8, 0xA5)
    # DSE: tag, byte-align flag 0, count, bytes
    n = rnd.randint(0, 300)
    b.put(3, 4).put(4, rnd.randint(0, 15)).put(1, 0)
    if n >= 255:
        b.put(8, 255).put(8, n - 255)
    else:
        b.put(8, n)
    for _ in range(n):
        b.put(8, rnd.randint(0, 255))
    # CCE coupling to one SCE, independently switched, empty spectrum
    b.put(3, 2).put(4, 0).put(1, 1).put(3, 0)       # tag, ind_sw_cce_flag, 1 target
    b.put(1, 0).put(4, 0)                           # target: SCE 0
    b.put(1, 0).put(1, 0).put(2, 0)                 # cc_domain, gain sign, gain scale
    b.put(8, 100).put(1, 0).put(2, 0).put(1, 0).put(6, 0).put(1, 0)   # ics: max_sfb 0
    b.put(3, 0)                                     # no pulse / tns / gain control
    # FIL holding an SBR extension payload (EXT_SBR_DATA = 13): random bytes
    if sbr:
        n = rnd.randint(8, 40)
        cnt = n + 1
        if cnt >= 15:
            b.put(3, 6).put(4, 15).put(8, cnt - 14)
        else:
            b.put(3, 6).put(4, cnt)
        b.put(4, 13)
        b.put(4, rnd.randint(0, 15))
        for _ in range(n):
            b.put(8, rnd.randint(0, 255))
    own = "".join(format(x, "08b") for x in raw)
    return to_bytes(b.bits() + own)


def sfi_of(rate):
    return [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025,
            8000, 7350].index(rate)


def he_ascs(asc):
    """HE-AAC style AudioSpecificConfigs around the LC core described by asc"""
    aot = asc[0] >> 3
    sfi = ((asc[0] & 7) << 1) | (asc[1] >> 7)
    ch = (asc[1] >> 3) & 15
    assert aot == 2 and sfi != 15
    ext = max(sfi - 3, 0)                           # twice the rate
    sbr5 = Bits().put(5, 5).put(4, sfi).put(4, ch).put(4, ext).put(5, 2).put(3, 0)
    ps29 = Bits().put(5, 29).put(4, sfi).put(4, ch).put(4, ext).put(5, 2).put(3, 0)
    sync = (Bits().put(5, 2).put(4, sfi).put(4, ch).put(3, 0).put(11, 0x2B7).put(5, 5)
            .put(1, 1).put(4, ext).put(11, 0x548).put(1, 1))
    return {"sbr5": to_bytes(sbr5.bits()), "ps29": to_bytes(ps29.bits()),
            "sbrsync": to_bytes(sync.bits())}


# ----------------------------------------------------------------- reference
def pce_roles(asc):
    """channel roles, in element order, of the program_config_element in an
    AudioSpecificConfig with channelConfiguration 0 (the order ffmpeg uses
    when it cannot name the layout)"""
    bits = "".join(format(b, "08b") for b in asc)
    pos = [16]                  # after AOT, rate, channels and GASpecificConfig (5+4+4+3)

    def get(n):
        v = int(bits[pos[0]:pos[0] + n], 2)
        pos[0] += n
        return v
    get(4 + 2 + 4)
    nf, ns, nb, nl = get(4), get(4), get(4), get(2)
    get(3 + 4)
    for _ in range(3):
        if get(1):
            get(4 if _ < 2 else 3)
    roles = []
    front = [get(1 + 4) >> 4 for _ in range(nf)]
    side = [get(1 + 4) >> 4 for _ in range(ns)]
    back = [get(1 + 4) >> 4 for _ in range(nb)]
    pairs = 0
    for cpe in front:
        if cpe:
            roles += ["FL", "FR"] if pairs == 0 else ["FLC", "FRC"]
            pairs += 1
        else:
            roles.append("FC")
    for cpe in side:
        roles += ["SL", "SR"] if cpe else ["BC"]
    for cpe in back:
        roles += ["BL", "BR"] if cpe else ["BC"]
    roles += ["LFE"] * nl
    return roles


def channel_roles(path):
    out = run(["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries",
               "stream=channel_layout,channels", "-of", "default=nw=1", path]).decode()
    info = dict(l.split("=", 1) for l in out.split())
    layout = info.get("channel_layout", "")
    n = int(info["channels"])
    names = {
        "mono": "FC", "stereo": "FL+FR", "2.1": "FL+FR+LFE", "3.0": "FL+FR+FC",
        "3.0(back)": "FL+FR+BC", "4.0": "FL+FR+FC+BC", "quad": "FL+FR+BL+BR",
        "quad(side)": "FL+FR+SL+SR", "5.0": "FL+FR+FC+BL+BR", "5.0(side)": "FL+FR+FC+SL+SR",
        "5.1": "FL+FR+FC+LFE+BL+BR", "5.1(side)": "FL+FR+FC+LFE+SL+SR",
        "6.1": "FL+FR+FC+LFE+BC+SL+SR", "7.1": "FL+FR+FC+LFE+BL+BR+SL+SR",
        "7.1(wide)": "FL+FR+FC+LFE+BL+BR+FLC+FRC", "7.1(wide-side)": "FL+FR+FC+LFE+FLC+FRC+SL+SR",
    }
    if layout == "unknown":
        roles = pce_roles(open(path[:-5] + ".asc", "rb").read())
        assert len(roles) == n, (roles, n)
        return roles
    if layout not in names:
        sys.exit("unknown layout %r in %s" % (layout, path))
    roles = names[layout].split("+")
    assert len(roles) == n, (layout, n)
    return roles


# the downmix aac.asm does (documented there): left = FL + A*(FC + SL + BL +
# BC + FLC), right = FR + A*(FC + SR + BR + BC + FRC), both divided by the sum
# of the weights that feed the left output; LFE is left out.
def downmix(pcm, roles):
    wl = {"FL": 1, "FC": A, "SL": A, "BL": A, "BC": A, "FLC": A}
    wr = {"FR": 1, "FC": A, "SR": A, "BR": A, "BC": A, "FRC": A}
    norm = sum(wl.get(r, 0) for r in roles)
    left = sum(pcm[:, i] * wl.get(r, 0) for i, r in enumerate(roles)) / norm
    right = sum(pcm[:, i] * wr.get(r, 0) for i, r in enumerate(roles)) / norm
    return np.stack([left, right], axis=1)


def make_ref(adts, ref, ch):
    if ch <= 2:
        pcm = run(["ffmpeg", "-v", "error", "-f", "aac", "-i", adts, "-f", "s16le", "-"])
        open(ref, "wb").write(pcm)
        return
    roles = channel_roles(adts)
    f = np.frombuffer(run(["ffmpeg", "-v", "error", "-f", "aac", "-i", adts, "-f", "f32le", "-"]),
                      dtype="<f4").reshape(-1, len(roles)).astype(np.float64)
    mix = downmix(f, roles) * 32768.0
    mix = np.clip(np.rint(mix), -32768, 32767).astype("<i2")
    open(ref, "wb").write(mix.tobytes())


def write_case(name, frames, asc):
    """an .adts (frames: (ADTS header, access unit) pairs) and an .asc"""
    adts = os.path.join(OUT, name + ".adts")
    open(adts, "wb").write(adts_join(frames))
    open(os.path.join(OUT, name + ".asc"), "wb").write(asc)
    return adts


def explicit_asc(asc, rate):
    """the AudioSpecificConfig of an AAC-LC stream with its sampling rate
    written out (index 15 + 24 bits)"""
    ch = (asc[1] >> 3) & 15
    assert asc[0] >> 3 == 2 and ch != 0
    return to_bytes(Bits().put(5, 2).put(4, 15).put(24, rate).put(4, ch).put(3, 0).bits())


def lfe_asc(asc):
    """channelConfiguration 0 with a PCE that has a single LFE element"""
    sfi = ((asc[0] & 7) << 1) | (asc[1] >> 7)
    b = Bits().put(5, 2).put(4, sfi).put(4, 0).put(3, 0)
    b.put(4, 0).put(2, 1).put(4, sfi)               # PCE: tag, profile, rate
    b.put(4, 0).put(4, 0).put(4, 0).put(2, 1).put(3, 0).put(4, 0)
    b.put(1, 0).put(1, 0).put(1, 0)                 # no mixdowns
    b.put(4, 0)                                     # the LFE's tag
    bits = b.bits()
    bits += "0" * ((-len(bits)) % 8)                # byte_alignment
    return to_bytes(bits + "00000000")              # no comment


def ffmpeg_pcm(adts):
    return run(["ffmpeg", "-v", "error", "-f", "aac", "-i", adts, "-f", "s16le", "-"])


def rewritten(lines, quick):
    """the variants made with aac_rewrite.py (see the top of this file)"""
    have = set(l.split()[0] for l in lines)
    jobs = [  # (change, suffix, bases, comparison)
        ("pulses", "pulses", ["music_44100_s", "speech_64k_m", "clicks_128k", "pink_64k"],
         "snr"),
        ("tns_high", "tnshigh", ["music_44100_s", "tns_speech", "tones_64k"], "snr"),
        ("pns_ms", "pnsms", ["pns_pink_64k", "pns_music_48k"], "pns"),
        ("split", "split", ["clicks_128k", "clicks_64k_m", "tns_clicks", "clicks_48k_48000"],
         "same"),
        ("separate", "separate", ["music_44100_s", "noms_music"], "same"),
        ("cce", "cce", ["music_44100_s", "speech_64k_m", "pink_64k"], "same"),
        ("as_lfe", "lfe", ["speech_64k_m", "sweep_44100_m"], "same"),
    ]
    out = []
    for change, suffix, bases, how in jobs:
        for base in bases:
            if base not in have:
                continue
            asc = open(os.path.join(OUT, base + ".asc"), "rb").read()
            frames = adts_frames(open(os.path.join(OUT, base + ".adts"), "rb").read())
            sfi = (frames[0][0][2] >> 2) & 15
            raws = [r for _, r in frames]
            aac_rewrite.identity_check(raws, sfi)
            new, n = aac_rewrite.rewrite(raws, sfi, change)
            if n == 0:
                print("  (%s: nothing to change in %s)" % (change, base), file=sys.stderr)
                continue
            name = "%s_%s" % (base, suffix)
            extra = ""
            if change == "as_lfe":
                asc = lfe_asc(asc)
                extra = " ch=1"
            adts = write_case(name, [(h, r) for (h, _), r in zip(frames, new)], asc)
            if how == "same":
                out.append("%s same %s%s" % (name, base, extra))
                if change in ("split", "separate"):         # ffmpeg must agree
                    a = ffmpeg_pcm(adts)
                    b = open(os.path.join(OUT, base + ".ref"), "rb").read()
                    if a != b:
                        sys.exit("ffmpeg decodes %s differently from %s" % (name, base))
            else:
                ch = 1 if (asc[1] >> 3) & 15 == 1 else 2
                make_ref(adts, os.path.join(OUT, name + ".ref"), ch)
                out.append("%s %s %s" % (name, how, "70" if how == "snr" else "1.0"))
            print("%s (%d of %d frames changed)" % (name, n, len(frames)), file=sys.stderr)
    return out


def variants(lines, quick):
    """variants made from the frames of the cases in lines"""
    out = []
    have = set(l.split()[0] for l in lines)
    rnd = random.Random(1)
    for base in ("music_44100_s", "music_22050_s", "pink_64k" if quick else "speech_64k_m"):
        asc = open(os.path.join(OUT, base + ".asc"), "rb").read()
        frames = adts_frames(open(os.path.join(OUT, base + ".adts"), "rb").read())
        for kind, a in he_ascs(asc).items():
            if kind == "ps29" and ((asc[1] >> 3) & 15) != 1:
                continue                        # PS needs a mono core
            name = "%s_%s" % (base, kind)
            write_case(name, frames, a)
            out.append("%s same %s" % (name, base))
        name = base + "_fil"
        extra = [(h, prepend_elements(r, rnd, True)) for h, r in frames]
        write_case(name, extra, asc)
        out.append("%s same %s" % (name, base))
    # explicit sampling rates: the same frames
    base = "music_44100_s"
    asc = open(os.path.join(OUT, base + ".asc"), "rb").read()
    frames = adts_frames(open(os.path.join(OUT, base + ".adts"), "rb").read())
    for name, rate in (("explicit", 44100), ("rate44000", 44000)):
        write_case("%s_%s" % (base, name), frames, explicit_asc(asc, rate))
        out.append("%s_%s same %s rate=%d" % (base, name, base, rate))
    assert all(l.split()[2] in have for l in out if l.split()[1] == "same")
    return out + rewritten(lines, quick)


def main():
    quick = "--quick" in sys.argv
    os.makedirs(OUT, exist_ok=True)
    manifest = os.path.join(OUT, "manifest.txt")
    if "--variants" in sys.argv:
        lines = open(manifest).read().split("\n")
        lines = [l for l in lines[:lines.index("# variants")] if l]
        lines += ["# variants"] + variants(lines, quick)
        open(manifest, "w").write("\n".join(lines) + "\n")
        print("%d lines in %s" % (len(lines), manifest), file=sys.stderr)
        return
    lines = []
    for name, src, rate, ch, br, opts, mode, arg in case_list(quick):
        m4a = os.path.join(OUT, name + ".m4a")
        adts = os.path.join(OUT, name + ".adts")
        dur = 30 if name.startswith("long") else DUR
        cmd = ["ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i", SRC[src], "-t", str(dur),
               "-ar", str(rate), "-ac", str(ch), "-c:a", "aac", "-b:a", str(br)] + opts + [m4a]
        run(cmd)
        run(["ffmpeg", "-y", "-v", "error", "-i", m4a, "-c:a", "copy", "-f", "adts", adts])
        open(os.path.join(OUT, name + ".asc"), "wb").write(asc_from_m4a(m4a))
        make_ref(adts, os.path.join(OUT, name + ".ref"), ch)
        lines.append("%s %s %s" % (name, mode, arg) if mode != "exact" else "%s exact" % name)
        print(name, file=sys.stderr)
    lines += ["# variants"] + variants(lines, quick)
    open(manifest, "w").write("\n".join(lines) + "\n")
    print("%d lines in %s" % (len(lines), manifest), file=sys.stderr)


if __name__ == "__main__":
    main()
