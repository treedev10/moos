#!/usr/bin/env python3
"""
Make the test pictures for the picture decoders (src/jpeg.asm, src/png.asm,
src/gif.asm) and their references, decoded by Pillow.

    python3 tests/native/img_data.py [jpeg] [png] [gif]     (default: all)

Writes build/img/<format>/: the pictures, NAME.rgb = Pillow's pixels (3 bytes
R G B per pixel, transparent ones blended over the background as the
decoders do it: (a * c + (255 - a) * bg) / 255, rounded), and index.txt with
one line per picture: NAME WIDTH HEIGHT BG(hex). Real YouTube thumbnails are
fetched from i.ytimg.com when the network allows (skipped otherwise).
"""
import io
import os
import random
import shutil
import subprocess
import sys
import urllib.request

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "build", "img")
BG = 0x336699


def blend(rgba, bg):
    """RGBA uint8 array -> RGB uint8, blended over bg like the decoders do"""
    a = rgba[..., 3:4].astype(np.uint32)
    c = rgba[..., :3].astype(np.uint32)
    b = np.array([(bg >> 16) & 255, (bg >> 8) & 255, bg & 255], dtype=np.uint32)
    v = a * c + (255 - a) * b + 128
    return ((v + (v >> 8)) >> 8).astype(np.uint8)


def picture(w, h, seed):
    """a test picture: gradients, waves, noise and sharp-edged shapes"""
    rnd = np.random.default_rng(seed)
    y, x = np.mgrid[0:h, 0:w].astype(np.float64)
    r = 128 + 100 * np.sin(x / (3 + seed % 7) + y / 11.0)
    g = 255 * x / max(w - 1, 1)
    b = 255 * y / max(h - 1, 1)
    img = np.stack([r, g, b], -1) + rnd.normal(0, 12, (h, w, 3))
    for _ in range(6):
        x0, y0 = rnd.integers(0, w), rnd.integers(0, h)
        x1, y1 = x0 + rnd.integers(1, w // 3 + 2), y0 + rnd.integers(1, h // 3 + 2)
        img[y0:y1, x0:x1] = rnd.integers(0, 256, 3)
    return np.clip(img, 0, 255).astype(np.uint8)


class Index:
    def __init__(self, fmt):
        self.dir = os.path.join(OUT, fmt)
        shutil.rmtree(self.dir, ignore_errors=True)
        os.makedirs(self.dir)
        self.lines = []

    def add(self, name, data, bg=BG):
        """save the file and Pillow's reference; skip files Pillow refuses"""
        path = os.path.join(self.dir, name)
        open(path, "wb").write(data)
        im = Image.open(io.BytesIO(data))
        im.load()
        if im.mode in ("RGBA", "LA", "PA") or "transparency" in im.info:
            px = blend(np.asarray(im.convert("RGBA")), bg)
        else:
            px = np.asarray(im.convert("RGB"))
        open(path + ".rgb", "wb").write(px.tobytes())
        self.lines.append("%s %d %d %06x" % (name, im.width, im.height, bg))

    def close(self):
        open(os.path.join(self.dir, "index.txt"), "w").write("\n".join(self.lines) + "\n")
        print("%s: %d pictures" % (self.dir, len(self.lines)))


def save(img, **kw):
    f = io.BytesIO()
    img.save(f, **kw)
    return f.getvalue()


def make_jpeg():
    ix = Index("jpeg")
    sizes = [(320, 180), (480, 360), (1, 1), (2, 2), (3, 7), (7, 5), (17, 33), (33, 17),
             (255, 3), (100, 75), (16, 16), (64, 48), (1000, 7), (9, 300)]
    n = 0
    for (w, h) in sizes:
        img = Image.fromarray(picture(w, h, n))
        for sub in (0, 1, 2):
            for q in (30, 75, 95, 100):
                if q in (30, 100) and (w, h) not in ((320, 180), (17, 33), (100, 75)):
                    continue
                tag = "%dx%d_s%d_q%d" % (w, h, sub, q)
                ix.add("b_%s.jpg" % tag, save(img, format="JPEG", quality=q, subsampling=sub))
                if q == 75:
                    ix.add("p_%s.jpg" % tag, save(img, format="JPEG", quality=q,
                                                  subsampling=sub, progressive=True))
                    ix.add("r_%s.jpg" % tag, save(img, format="JPEG", quality=q,
                                                  subsampling=sub, restart_marker_blocks=3))
        ix.add("g_%dx%d.jpg" % (w, h), save(img.convert("L"), format="JPEG", quality=80))
        ix.add("gp_%dx%d.jpg" % (w, h), save(img.convert("L"), format="JPEG", quality=80,
                                             progressive=True))
        n += 1
    big = Image.fromarray(picture(1280, 720, 99))
    ix.add("b_1280x720.jpg", save(big, format="JPEG", quality=85))
    ix.add("p_1280x720.jpg", save(big, format="JPEG", quality=85, progressive=True))
    ix.add("rr_1280x720.jpg", save(big, format="JPEG", quality=85, restart_marker_rows=1))
    try:
        ix.add("rgb_100x75.jpg", save(Image.fromarray(picture(100, 75, 5)), format="JPEG",
                                      quality=90, keep_rgb=True))
    except Exception as e:
        print("no RGB JPEG:", e)
    if shutil.which("convert"):          # sampling factors Pillow cannot write
        src = os.path.join(ix.dir, "src.png")
        Image.fromarray(picture(99, 61, 7)).save(src)
        for sf in ("1x2", "4x1", "2x2,1x1,2x2", "1x1,2x2,1x1"):
            for il in ("none", "plane"):
                out = os.path.join(ix.dir, "tmp.jpg")
                if subprocess.run(["convert", src, "-sampling-factor", sf, "-interlace", il,
                                   "-quality", "85", out]).returncode == 0:
                    ix.add("im_%s_%s.jpg" % (sf.replace(",", "-"), il), open(out, "rb").read())
                    os.remove(out)
        os.remove(src)
    for vid in ("jNQXAC9IVRw", "dQw4w9WgXcQ", "9bZkp7q19f0"):
        for kind in ("mqdefault", "hqdefault", "default"):
            try:
                data = urllib.request.urlopen("https://i.ytimg.com/vi/%s/%s.jpg" % (vid, kind),
                                              timeout=10).read()
                ix.add("yt_%s_%s.jpg" % (vid, kind), data)
            except Exception as e:
                print("no thumbnail %s/%s: %s" % (vid, kind, e))
    ix.close()


def main():
    which = sys.argv[1:] or ["jpeg", "png", "gif"]
    random.seed(1)
    for fmt in which:
        globals()["make_" + fmt]()


if __name__ == "__main__":
    main()
