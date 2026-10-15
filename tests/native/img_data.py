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
import struct
import subprocess
import sys
import urllib.request
import zlib

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

    def add_ref(self, name, data, rgb, bg=BG):
        """save the file with a reference made here (rgb: h x w x 3)"""
        path = os.path.join(self.dir, name)
        open(path, "wb").write(data)
        open(path + ".rgb", "wb").write(np.ascontiguousarray(rgb, dtype=np.uint8).tobytes())
        self.lines.append("%s %d %d %06x" % (name, rgb.shape[1], rgb.shape[0], bg))

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


ADAM7 = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2),
         (0, 1, 1, 2)]
CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}


def png_chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def png_filter(raw, prior, bpp, ft):
    out = bytearray(len(raw))
    for i in range(len(raw)):
        a = raw[i - bpp] if i >= bpp else 0
        b = prior[i]
        c = prior[i - bpp] if i >= bpp else 0
        if ft == 0:
            pr = 0
        elif ft == 1:
            pr = a
        elif ft == 2:
            pr = b
        elif ft == 3:
            pr = (a + b) >> 1
        else:
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
        out[i] = (raw[i] - pr) & 255
    return bytes(out)


def png_write(samples, ctype, depth, interlace=0, plte=None, trns=None, idat_size=None,
              rnd=None):
    """a PNG of samples (h x w x channels, values at the given depth), each
    row with a random filter type, the zlib data split into IDAT chunks"""
    h, w = samples.shape[:2]
    bits = CHANNELS[ctype] * depth
    bpp = max(1, bits // 8)
    passes = ADAM7 if interlace else [(0, 0, 1, 1)]
    raw = bytearray()
    for (x0, y0, dx, dy) in passes:
        sub = samples[y0::dy, x0::dx]
        if sub.shape[0] == 0 or sub.shape[1] == 0:
            continue
        rb = (sub.shape[1] * bits + 7) // 8
        prior = bytes(rb)
        for row in sub:
            flat = row.reshape(-1).astype(np.uint32)
            if depth == 16:
                line = b"".join(struct.pack(">H", v) for v in flat)
            elif depth == 8:
                line = bytes(flat.astype(np.uint8))
            else:
                acc, n, out = 0, 0, bytearray()
                for v in flat:
                    acc = acc << depth | int(v)
                    n += depth
                    if n == 8:
                        out.append(acc)
                        acc, n = 0, 0
                if n:
                    out.append(acc << (8 - n))
                line = bytes(out)
            ft = rnd.randrange(5)
            raw.append(ft)
            raw += png_filter(line, prior, bpp, ft)
            prior = line
    z = zlib.compress(bytes(raw), 9)
    out = b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, depth, ctype,
                                                                0, 0, interlace))
    if plte is not None:
        out += png_chunk(b"PLTE", bytes(np.asarray(plte, dtype=np.uint8).reshape(-1)))
    if trns is not None:
        out += png_chunk(b"tRNS", trns)
    out += png_chunk(b"tEXt", b"Comment\0made by img_data.py")
    step = idat_size or len(z) or 1
    for i in range(0, max(len(z), 1), step):
        out += png_chunk(b"IDAT", z[i:i + step])
    return out + png_chunk(b"IEND", b"")


def png_model(samples, ctype, depth, plte=None, trns=None):
    """RGBA (h x w x 4) that the PNG spec gives for the samples"""
    s = samples.astype(np.uint32)
    h, w = s.shape[:2]
    scale = {1: 255, 2: 85, 4: 17, 8: 1}
    down = (lambda v: v >> 8) if depth == 16 else (lambda v: v * scale[depth])
    a = np.full((h, w), 255, np.uint32)
    if ctype == 3:
        pal = np.zeros((256, 4), np.uint32)
        pal[:, 3] = 255
        pal[:len(plte), :3] = plte
        if trns is not None:
            pal[:len(trns), 3] = list(trns)
        return pal[s[..., 0]].astype(np.uint8)
    if ctype == 0:
        rgb = np.repeat(down(s), 3, axis=2)
        if trns is not None:
            a[s[..., 0] == struct.unpack(">H", trns)[0]] = 0
    elif ctype == 2:
        rgb = down(s)
        if trns is not None:
            key = struct.unpack(">HHH", trns)
            a[(s[..., 0] == key[0]) & (s[..., 1] == key[1]) & (s[..., 2] == key[2])] = 0
    elif ctype == 4:
        rgb = np.repeat(down(s[..., :1]), 3, axis=2)
        a = down(s[..., 1])
    else:
        rgb = down(s[..., :3])
        a = down(s[..., 3])
    return np.concatenate([rgb, a[..., None]], axis=2).astype(np.uint8)


def make_png():
    ix = Index("png")
    rnd = random.Random(3)
    nprng = np.random.default_rng(3)
    combos = [(0, 1), (0, 2), (0, 4), (0, 8), (0, 16), (2, 8), (2, 16), (3, 1), (3, 2), (3, 4),
              (3, 8), (4, 8), (4, 16), (6, 8), (6, 16)]
    sizes = [(1, 1), (2, 3), (5, 5), (13, 7), (33, 20), (64, 64), (100, 37), (9, 1), (1, 9)]
    pillow_quirk = 0
    for ctype, depth in combos:
        for (w, h) in sizes:
            for interlace in (0, 1):
                for withtrns in ((0, 1) if ctype in (0, 2, 3) else (0,)):
                    top = 1 << depth
                    plte = trns = None
                    s = nprng.integers(0, top, (h, w, CHANNELS[ctype]))
                    s[: h // 2, : w // 2] = s[0, 0]           # some flat area
                    if ctype == 3:
                        npal = rnd.choice([top, max(1, top - 1), min(top, 3)])
                        s %= npal
                        plte = nprng.integers(0, 256, (npal, 3))
                        if withtrns:
                            trns = bytes(nprng.integers(0, 256, rnd.randrange(1, npal + 1))
                                         .astype(np.uint8))
                    elif withtrns:
                        key = s[h - 1, w - 1]
                        trns = struct.pack(">" + "H" * len(key), *[int(v) for v in key])
                    data = png_write(s, ctype, depth, interlace, plte, trns,
                                     rnd.choice([None, 7, 100]), rnd)
                    rgb = blend(png_model(s, ctype, depth, plte, trns), BG)
                    # Pillow must agree, except where it does not follow the
                    # spec: tRNS keys of 2/4-bit grey and 16-bit RGB (compared
                    # after scaling to 8 bits) and 16-bit grey (clipped, not scaled)
                    quirk = (ctype == 0 and depth == 16) or \
                        (withtrns and ((ctype == 0 and depth in (2, 4)) or
                                       (ctype == 2 and depth == 16)))
                    if not quirk:
                        im = Image.open(io.BytesIO(data))
                        ref = blend(np.asarray(im.convert("RGBA")), BG)
                        assert (ref == rgb).all(), (ctype, depth, w, h, interlace, withtrns)
                    else:
                        pillow_quirk += 1
                    ix.add_ref("t%d_d%d_%dx%d_i%d_t%d.png" % (ctype, depth, w, h, interlace,
                                                              withtrns), data, rgb)
    print("png: %d pictures checked against the PNG spec only (Pillow quirks)" % pillow_quirk)
    for mode in ("RGB", "RGBA", "L", "LA", "P", "1"):
        for (w, h) in ((320, 180), (17, 33), (1, 1)):
            base = Image.fromarray(picture(w, h, w + h))
            if mode in ("RGBA", "LA"):
                al = np.fromfunction(lambda y, x: (x * 255 // max(w - 1, 1)), (h, w)).astype(np.uint8)
                im = base.convert("RGBA")
                im.putalpha(Image.fromarray(al))
                im = im.convert(mode)
            elif mode == "P":
                im = base.quantize(200)
            else:
                im = base.convert(mode)
            for opt in (False, True):
                ix.add("pil_%s_%dx%d_o%d.png" % (mode, w, h, opt), save(im, format="PNG", optimize=opt))
            ix.add("pil_%s_%dx%d_c1.png" % (mode, w, h), save(im, format="PNG", compress_level=1))
    pt = Image.fromarray(picture(200, 100, 4)).quantize(16)
    ix.add("pil_P_trns.png", save(pt, format="PNG", transparency=3))
    big = Image.fromarray(picture(1280, 720, 8))
    ix.add("big_rgb.png", save(big, format="PNG"))
    bigA = big.convert("RGBA")
    bigA.putalpha(Image.fromarray(np.fromfunction(lambda y, x: (x + y) % 256, (720, 1280))
                                  .astype(np.uint8)))
    ix.add("big_rgba.png", save(bigA, format="PNG"))
    if shutil.which("convert"):                                # Adam7 from libpng
        src = os.path.join(ix.dir, "src.png")
        big.resize((333, 222)).save(src)
        out = os.path.join(ix.dir, "tmp.png")
        for args in (["-interlace", "PNG"], ["-interlace", "PNG", "-define", "png:color-type=6"],
                     ["-colors", "16", "-interlace", "PNG"]):
            if subprocess.run(["convert", src] + args + [out]).returncode == 0:
                ix.add("im_%d.png" % len(ix.lines), open(out, "rb").read())
        os.remove(out)
        os.remove(src)
    ix.close()


def main():
    which = sys.argv[1:] or ["jpeg", "png", "gif"]
    random.seed(1)
    for fmt in which:
        globals()["make_" + fmt]()


if __name__ == "__main__":
    main()
