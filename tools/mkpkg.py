#!/usr/bin/env python3
"""
Build a MOOS package (.pkg) from one or more files.

    python tools/mkpkg.py <name> [--desc "text"] FILE [FILE ...] > <name>.pkg

Each FILE is included under its base name. The result is plain text (see
PACKAGES.md): a header, then one @file section per file, then @end.
Put the .pkg on an HTTP server and install it in MOOS with  apt install <name>.
"""
import os
import sys


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        sys.exit(__doc__)
    name = args.pop(0)
    desc = ""
    files = []
    while args:
        a = args.pop(0)
        if a == "--desc":
            desc = args.pop(0)
        else:
            files.append(a)
    if not files:
        sys.exit("error: give at least one file to include")

    out = sys.stdout.buffer
    out.write(b"MOOSPKG 1\n")
    out.write(("name: %s\n" % name).encode())
    if desc:
        out.write(("desc: %s\n" % desc).encode())
    for path in files:
        data = open(path, "rb").read()
        base = os.path.basename(path)
        out.write(("@file %s %d\n" % (base, len(data))).encode())
        out.write(data)
        out.write(b"\n")
    out.write(b"@end\n")


if __name__ == "__main__":
    main()
