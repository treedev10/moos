#!/usr/bin/env python3
"""
Make a comment-free copy of the MOOS source.

    python tools/strip_comments.py          write the copy to nocomments/
    python tools/strip_comments.py --check   build from it to prove it works

The MOOS source in src/ and efi/ is heavily commented so it is easy to read.
Comments do not affect the assembled binary (the assembler ignores them), so
this is purely a smaller, comment-free view of the same code. The commented
source stays the canonical one; this copy is provided as the "optimized"
(comment-stripped) version.

The stripper is quote-aware: a ';' inside a NASM string (" ... ", ' ... ' or
` ... `) is kept; a ';' outside strings starts a comment and is removed.
"""
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "nocomments")


def strip_line(line):
    out = []
    quote = None
    i = 0
    while i < len(line):
        c = line[i]
        if quote:
            out.append(c)
            if c == quote:
                quote = None
        elif c in '"\'`':
            quote = c
            out.append(c)
        elif c == ';':
            break                       # a comment starts here
        else:
            out.append(c)
        i += 1
    return "".join(out).rstrip()


def strip_text(text):
    lines = []
    blanks = 0
    for raw in text.split("\n"):
        s = strip_line(raw)
        if s.strip() == "":
            blanks += 1
            if blanks <= 1:             # collapse runs of blank lines
                lines.append("")
        else:
            blanks = 0
            lines.append(s)
    return "\n".join(lines).strip("\n") + "\n"


def generate():
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    exts = (".asm", ".inc")
    total_in = total_out = 0
    for sub in ("src", "efi"):
        src_dir = os.path.join(ROOT, sub)
        for name in sorted(os.listdir(src_dir)):
            path = os.path.join(src_dir, name)
            if not os.path.isfile(path):
                continue
            dst = os.path.join(OUT, sub, name)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if name.endswith(exts):
                text = open(path, encoding="utf-8", newline="").read()
                stripped = strip_text(text)
                open(dst, "w", encoding="utf-8", newline="").write(stripped)
                total_in += len(text)
                total_out += len(stripped)
            else:
                shutil.copy(path, dst)      # font8x16.bin etc.
    print("Wrote comment-free source to %s/" % os.path.relpath(OUT, ROOT))
    print("  source bytes: %d -> %d (%.0f%% smaller)" %
          (total_in, total_out, 100 * (1 - total_out / total_in)))


def check():
    """Build once from the stripped copy to prove it still assembles."""
    generate()
    bak = os.path.join(ROOT, ".srcbak")
    if os.path.isdir(bak):
        shutil.rmtree(bak)
    os.makedirs(bak)
    for sub in ("src", "efi"):
        shutil.move(os.path.join(ROOT, sub), os.path.join(bak, sub))
        shutil.copytree(os.path.join(OUT, sub), os.path.join(ROOT, sub))
    try:
        r = subprocess.run([sys.executable, "build.py"], cwd=ROOT,
                           capture_output=True, text=True)
        ok = r.returncode == 0
        print((r.stdout + r.stderr).rstrip()[-400:])
    finally:
        for sub in ("src", "efi"):
            shutil.rmtree(os.path.join(ROOT, sub))
            shutil.move(os.path.join(bak, sub), os.path.join(ROOT, sub))
        shutil.rmtree(bak)
    print("stripped source builds:" , "YES" if ok else "NO")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    if "--check" in sys.argv[1:]:
        check()
    else:
        generate()
