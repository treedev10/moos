#!/usr/bin/env python3
"""
Make the test streams for tests/native/h264_test.c, and run the test on them.

    python3 tests/native/h264_make.py              make every stream (build/h264/)
    python3 tests/native/h264_make.py NAME...      only these (prefix match)
    python3 tests/native/h264_make.py --run [NAME...]   make (if missing) and test
    python3 tests/native/h264_make.py --run --avcc   parameter sets through h264_decode_avcc
    python3 tests/native/h264_make.py --list
    python3 tests/native/h264_make.py --fuzz=N [--seed=S] [NAME...]
                                         robustness: N damaged runs per stream

Each stream NAME.264 is encoded with ffmpeg + libx264 (Baseline profile unless
the case says otherwise) from one of ffmpeg's test sources, and NAME.yuv is
ffmpeg's own decode of it (-f rawvideo -pix_fmt yuv420p): the reference the
MOOS decoder must match bit for bit. Some cases are then changed by
tests/native/h264_rewrite.py (synthesised features that x264 never writes:
other POC types, long-term references, MMCO, reordering, redundant slices,
frame_num gaps, several parameter sets, I_PCM ...); the reference is always
ffmpeg's decode of the final stream.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "build", "h264")
REWRITE = os.path.join(ROOT, "tests", "native", "h264_rewrite.py")

BASE = "-profile:v baseline -preset medium"
# Main profile, CAVLC
MAINC = "-profile:v main -x264-params cabac=0"


def src(kind, w, h, rate=25):
    """an ffmpeg lavfi source"""
    if kind == "testsrc2":
        return "-f lavfi -i testsrc2=size=%dx%d:rate=%d" % (w, h, rate)
    if kind == "mandelbrot":
        return "-f lavfi -i mandelbrot=size=%dx%d:rate=%d" % (w, h, rate)
    if kind == "noise":
        return ("-f lavfi -i nullsrc=size=%dx%d:rate=%d -vf 'geq=random(1)*255:128:128'" %
                (w, h, rate))
    if kind == "noisy":       # moving picture + noise
        return ("-f lavfi -i testsrc2=size=%dx%d:rate=%d -vf noise=alls=40:allf=t+u" %
                (w, h, rate))
    if kind == "cuts":        # scene cuts: alternate between sources
        return ("-f lavfi -i testsrc2=size={w}x{h}:rate={r} -f lavfi -i mandelbrot=size={w}x{h}:rate={r} "
                "-filter_complex \"[0:v][1:v]blend=all_expr='if(lt(mod(N\\,20)\\,10)\\,A\\,B)'\"".format(w=w, h=h, r=rate))
    if kind == "fade":        # fades in and out (weighted prediction)
        return ("-f lavfi -i mandelbrot=size=%dx%d:rate=%d -vf "
                "'fade=in:0:15,fade=out:20:15'" % (w, h, rate))
    if kind == "smpte":
        return "-f lavfi -i smptehdbars=size=%dx%d:rate=%d" % (w, h, rate)
    if kind == "life":
        return "-f lavfi -i life=size=%dx%d:rate=%d:mold=10:ratio=0.3" % (w, h, rate)
    raise ValueError(kind)


# name: (source, w, h, frames, x264 options, rewrite options or None)
CASES = {
    # sizes (cropping where not a multiple of 16)
    "s16":        ("testsrc2", 16, 16, 10, "", None),
    "s64x48":     ("testsrc2", 64, 48, 20, "", None),
    "s100x58":    ("testsrc2", 100, 58, 20, "", None),
    "s34x18":     ("testsrc2", 34, 18, 20, "", None),
    "s176x144":   ("testsrc2", 176, 144, 30, "", None),
    "s640x360":   ("testsrc2", 640, 360, 60, "", None),
    "s1280x720":  ("testsrc2", 1280, 720, 20, "", None),
    # (4:2:0 crops in units of 2 pixels, so odd sizes such as 33x17 cannot be coded)
    "s34x18_m":   ("mandelbrot", 34, 18, 30, "-crf 10", None),
    "s2x2":       ("testsrc2", 2, 2, 10, "", None),
    "s18x10":     ("mandelbrot", 18, 10, 20, "-refs 4", None),
    "s100x58_m":  ("mandelbrot", 100, 58, 30, "-refs 3", None),
    # 640x360 (YouTube itag 18 size): moving content, intra only, slices, quality range
    "m640_mandel": ("mandelbrot", 640, 360, 60, "-crf 23 -refs 3", None),
    "m640_g1":    ("testsrc2", 640, 360, 10, "-g 1 -crf 23", None),
    "m640_slices": ("mandelbrot", 640, 360, 20, "-x264-params slices=4:ref=4", None),
    "m640_qp0":   ("noisy", 640, 360, 5, "-qp 1", "qp=0"),
    "m640_crf1":  ("noisy", 640, 360, 5, "-crf 1", None),
    "m640_crf51": ("mandelbrot", 640, 360, 30, "-crf 51", None),
    "m640_dbk":   ("noisy", 640, 360, 15, "-x264-params deblock=-2,3:ref=16", None),
    # intra only, deblocking variations
    "i_nodbk":    ("testsrc2", 64, 48, 5, "-g 1 -x264-params no-deblock=1", None),
    "i_dbk":      ("testsrc2", 64, 48, 5, "-g 1", None),
    "i_qp0":      ("testsrc2", 176, 144, 5, "-g 1 -qp 1", "qp=0"),
    "i_qp51":     ("testsrc2", 176, 144, 5, "-g 1 -qp 51", None),
    "i_mandel":   ("mandelbrot", 176, 144, 5, "-g 1 -crf 20", None),
    "i_noise":    ("noise", 176, 144, 3, "-g 1 -crf 10", None),
    "i_noise_qp0": ("noise", 64, 48, 3, "-g 1 -qp 1", "qp=0"),
    # quality range
    "crf1":       ("testsrc2", 176, 144, 20, "-crf 1", None),
    "crf10":      ("testsrc2", 176, 144, 20, "-crf 10", None),
    "crf23":      ("testsrc2", 176, 144, 20, "-crf 23", None),
    "crf35":      ("testsrc2", 176, 144, 20, "-crf 35", None),
    "crf51":      ("testsrc2", 176, 144, 20, "-crf 51", None),
    "qp0":        ("noisy", 176, 144, 10, "-qp 1", "qp=0"),
    "qp51":       ("testsrc2", 176, 144, 10, "-qp 51", None),
    # every QP 0..51 (x264 zones: a constant QP per frame; picture n at
    # (11 n + 3) % 52, a few lower for P frames; 0 itself comes from a rewrite)
    "qpcycle":    ("noisy", 176, 144, 104, "-x264-params zones={QPZONES}", None),
    "qpcycle_i":  ("mandelbrot", 176, 144, 52, "-g 1 -x264-params zones={QPZONES}", None),
    # motion
    "p_nodbk":    ("testsrc2", 176, 144, 30, "-x264-params no-deblock=1", None),
    "p_mandel":   ("mandelbrot", 176, 144, 30, "-crf 18", None),
    "p_noisy":    ("noisy", 176, 144, 30, "-crf 18", None),
    "p_noise":    ("noise", 176, 144, 10, "-crf 18", None),
    "p_life":     ("life", 176, 144, 30, "-crf 18", None),
    "p_smpte":    ("smpte", 320, 240, 20, "-crf 18", None),
    "longgop":    ("testsrc2", 176, 144, 300, "-g 300 -x264-params keyint=300:min-keyint=300:scenecut=0", None),
    "refs1":      ("mandelbrot", 176, 144, 30, "-refs 1", None),
    "refs4":      ("mandelbrot", 176, 144, 30, "-refs 4", None),
    "refs16":     ("mandelbrot", 176, 144, 40, "-refs 16", None),
    "refs16b":    ("noisy", 176, 144, 40, "-refs 16 -x264-params ref=16:me=umh:subme=9", None),
    "parts":      ("noisy", 176, 144, 30, "-x264-params partitions=all:subme=9:me=umh:ref=3", None),
    "parts_lo":   ("noisy", 176, 144, 30, "-crf 10 -x264-params partitions=all:subme=9:me=umh:ref=3", None),
    "slices4":    ("testsrc2", 176, 144, 20, "-x264-params slices=4", None),
    "slicesize":  ("noisy", 176, 144, 20, "-x264-params slice-max-size=500", None),
    "slicesize_hd": ("testsrc2", 640, 360, 10, "-x264-params slice-max-size=500", None),
    "dbk_off":    ("noisy", 176, 144, 20, "-x264-params no-deblock=1", None),
    "dbk_m6":     ("noisy", 176, 144, 20, "-x264-params deblock=-6,-6", None),
    "dbk_p6":     ("noisy", 176, 144, 20, "-x264-params deblock=6,6", None),
    "dbk_m3p2":   ("noisy", 176, 144, 20, "-x264-params deblock=-3,2", None),
    "dbk_slices": ("noisy", 176, 144, 20, "-x264-params slices=3:deblock=2,-2", None),
    "cuts":       ("cuts", 176, 144, 60, "", None),
    "cbr":        ("noisy", 320, 240, 40, "-b:v 300k -maxrate 300k -bufsize 150k -x264-params nal-hrd=cbr", None),
    "vbv":        ("p_mandel_src", 320, 240, 40, "", None),
    "cqp_chroma": ("noisy", 176, 144, 20, "-x264-params chroma-qp-offset=-12", None),
    "cqp_chroma2": ("noisy", 176, 144, 20, "-x264-params chroma-qp-offset=12", None),
    "fast":       ("testsrc2", 320, 240, 30, "-preset ultrafast", None),
    "slow":       ("noisy", 320, 240, 30, "-preset veryslow", None),
    "intrarefresh": ("testsrc2", 176, 144, 60, "-x264-params intra-refresh=1:keyint=30", None),
    # synthesised features (h264_rewrite.py)
    "poc0":       ("testsrc2", 176, 144, 300, "-g 300 -x264-params scenecut=0", "poc0"),
    "poc0_gop":   ("mandelbrot", 176, 144, 60, "-g 12", "poc0"),
    "poc1":       ("mandelbrot", 176, 144, 60, "-g 25", "poc1"),
    "ids":        ("noisy", 176, 144, 20, "", "ids"),
    "ltr":        ("mandelbrot", 176, 144, 40, "-refs 1", "ltr"),
    "mmco":       ("mandelbrot", 176, 144, 60, "-refs 1 -g 100", "mmco"),
    "reorder":    ("noisy", 176, 144, 30, "-refs 4", "reorder"),
    # (reference: the stream without the redundant slices - ffmpeg does not
    # skip them properly: "decode_slice_header error")
    "redundant":  ("noisy", 176, 144, 20, "-x264-params slices=2", "redundant"),
    "gaps":       ("mandelbrot", 176, 144, 40, "-refs 2", "gaps"),
    "nonidr":     ("testsrc2", 176, 144, 50, "-g 20", "nonidr=7"),
    "eos":        ("testsrc2", 176, 144, 30, "-g 10 -x264-params aud=1", "eos"),
    "pcm":        ("synth", 96, 80, 8, "", "synth"),
    "yt360":      ("testsrc2", 640, 360, 300, "-level 3.0 -crf 23 -g 60", None),
    "yt360_noisy": ("noisy", 640, 360, 120, "-level 3.0 -crf 23 -g 60", None),
    # Main profile with CAVLC (B slices, direct prediction, weighted
    # prediction without CABAC)
    "mc_b":       ("testsrc2", 176, 144, 30, MAINC, None),
    "mc_b_noisy": ("noisy", 176, 144, 30, MAINC + ":bframes=3:b-adapt=2", None),
    "mc_temporal": ("noisy", 176, 144, 30, MAINC + ":direct=temporal", None),
    "mc_temporal_r": ("mandelbrot", 176, 144, 40, MAINC + ":direct=temporal:ref=4:bframes=5", None),
    "mc_spatial": ("mandelbrot", 176, 144, 40, MAINC + ":direct=spatial:ref=4:bframes=5", None),
    "mc_nopyr":   ("noisy", 176, 144, 30, MAINC + ":b-pyramid=none:weightb=0", None),
    "mc_strict":  ("noisy", 176, 144, 30, MAINC + ":b-pyramid=strict", None),
    "mc_bparts":  ("noisy", 176, 144, 30, MAINC + ":partitions=all:subme=9:me=umh:ref=3:bframes=4", None),
    "mc_fade":    ("fade", 176, 144, 40, MAINC + ":weightp=2:weightb=1", None),
    "mc_fadeb":   ("fade", 176, 144, 40, MAINC + ":weightp=1:weightb=1:bframes=4", None),
    "mc_slices":  ("noisy", 176, 144, 20, MAINC + ":slices=3", None),
    "mc_cuts":    ("cuts", 176, 144, 60, MAINC, None),
    "mc_640":     ("testsrc2", 640, 360, 30, MAINC, None),
    "mc_100x58":  ("noisy", 100, 58, 20, MAINC, None),
}

# "vbv" uses mandelbrot with VBV limits
CASES["vbv"] = ("mandelbrot", 320, 240, 40, "-crf 20 -maxrate 400k -bufsize 200k", None)


def run(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if r.returncode:
        sys.stderr.write(r.stderr[-2000:])
        raise SystemExit("failed: " + cmd)
    return r


def make(name, force=False):
    case = CASES[name]
    kind, w, h, frames, opts, rew = case
    stream = os.path.join(OUT, name + ".264")
    yuv = os.path.join(OUT, name + ".yuv")
    if not force and os.path.exists(stream) and os.path.exists(yuv):
        return stream, yuv
    os.makedirs(OUT, exist_ok=True)
    base = BASE
    if "{QPZONES}" in opts:
        opts = opts.replace("{QPZONES}", "/".join("%d,%d,q=%d" % (i, i, max(1, (i * 11 + 3) % 52))
                                                  for i in range(frames)))
    if "-profile:v" in opts:
        base = "-preset medium"
    raw = stream if not rew else os.path.join(OUT, name + ".orig.264")
    if kind == "synth":
        run("%s %s synth %s %d %d %d" % (sys.executable, REWRITE, stream, w // 16, h // 16, frames))
        run("ffmpeg -y -hide_banner -loglevel error -i %s -f rawvideo -pix_fmt yuv420p %s" % (stream, yuv))
        return stream, yuv
    run("ffmpeg -y -hide_banner -loglevel error %s -frames:v %d -pix_fmt yuv420p -c:v libx264 %s %s -f h264 %s"
        % (src(kind, w, h), frames, base, opts, raw))
    if rew:
        run("%s %s %s %s %s" % (sys.executable, REWRITE, rew, raw, stream))
    refsrc = raw if name in REF_FROM_ORIGINAL else stream
    run("ffmpeg -y -hide_banner -loglevel error -i %s -f rawvideo -pix_fmt yuv420p %s" % (refsrc, yuv))
    return stream, yuv


REF_FROM_ORIGINAL = ("redundant",)


def main():
    args = sys.argv[1:]
    if "--list" in args:
        for n, c in CASES.items():
            print("%-14s %s %dx%d %d frames %s %s" % (n, c[0], c[1], c[2], c[3], c[4], c[5] or ""))
        return
    do_run = "--run" in args
    fuzz = [int(a.split("=")[1]) for a in args if a.startswith("--fuzz=")]
    seed = ([int(a.split("=")[1]) for a in args if a.startswith("--seed=")] or [1])[0]
    args = [a for a in args if not a.startswith("--")]
    names = [n for n in CASES if not args or any(n.startswith(a) for a in args)]
    if do_run:
        subprocess.run([sys.executable, os.path.join(ROOT, "tests", "native", "run.py"), "h264"],
                       capture_output=True)
    exe = os.path.join(ROOT, "build", "native", "h264_test")
    failed = []
    if fuzz:
        import concurrent.futures
        subprocess.run([sys.executable, os.path.join(ROOT, "tests", "native", "run.py"), "h264"],
                       capture_output=True)

        def one(n):
            stream, _ = make(n)
            w, h = CASES[n][1], CASES[n][2]
            # a few runs with less memory than the stream needs, too
            mx = "%dx%d" % (max(w, 16), max(h, 16)) if seed % 3 else "64x48"
            r = subprocess.run([exe, stream, "-fuzz", str(fuzz[0]), "-seed", str(seed),
                                "-max", mx], capture_output=True, text=True)
            return n, r.returncode, (r.stdout + r.stderr).strip().splitlines()[-1:]
        for n in names:
            make(n)
        with concurrent.futures.ThreadPoolExecutor(4) as ex:
            for n, rc, last in ex.map(one, names):
                print("%-14s %s %s" % (n, "ok " if rc == 0 else "FAILED (%d)" % rc, " ".join(last)))
                if rc:
                    failed.append(n)
        print("fuzz: %d of %d streams survived%s" % (len(names) - len(failed), len(names),
                                                     "; failed: " + " ".join(failed) if failed else ""))
        return
    for n in names:
        stream, yuv = make(n)
        if do_run:
            w, h = CASES[n][1], CASES[n][2]
            r = subprocess.run([exe, stream, yuv, "-q", "-size", "%dx%d" % (w, h),
                                "-max", "%dx%d" % (max(w, 16), max(h, 16))] +
                               (["-avcc"] if "--avcc" in sys.argv else []),
                               capture_output=True, text=True, timeout=600)
            line = (r.stdout.strip().splitlines() or ["(no output) " + r.stderr[-300:]])[-1]
            print("%-14s %s" % (n, line.replace(stream + ": ", "")))
            if r.returncode:
                failed.append(n)
        else:
            print("made", n)
    if do_run:
        print("%d of %d passed%s" % (len(names) - len(failed), len(names),
                                     "; failed: " + " ".join(failed) if failed else ""))


if __name__ == "__main__":
    main()
