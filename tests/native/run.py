#!/usr/bin/env python3
"""
Build and run the native (Linux, 32-bit) test of a MOOS module.

    python tests/native/run.py <test> [arguments for the test]

<test> is tests/native/<test>_test.c. Its first line may name the modules
it needs, e.g.   // modules: png inflate
(default: the module with the test's own name). Each module src/<m>.asm is
assembled with  nasm -f elf32 -DNATIVE  and linked with the C test using
gcc -m32. Needs nasm and gcc with 32-bit support (gcc-multilib).
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "build", "native")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    test = sys.argv[1]
    csrc = os.path.join(ROOT, "tests", "native", test + "_test.c")
    if not os.path.isfile(csrc):
        sys.exit("no such test: " + csrc)
    first = open(csrc).readline()
    m = re.match(r"\s*//\s*modules:\s*(.*)", first)
    modules = m.group(1).split() if m else [test]
    os.makedirs(OUT, exist_ok=True)
    objs = []
    for mod in modules:
        obj = os.path.join(OUT, mod + ".o")
        subprocess.run(["nasm", "-f", "elf32", "-DNATIVE", "-w-error=label-redef-late",
                        "-I", ROOT + "/", os.path.join("src", mod + ".asm"), "-o", obj],
                       cwd=ROOT, check=True)
        objs.append(obj)
    exe = os.path.join(OUT, test + "_test")
    subprocess.run(["gcc", "-m32", "-O1", "-g", "-no-pie", "-Wall",
                    "-I", os.path.join(ROOT, "tests", "native"), csrc] + objs +
                   ["-o", exe, "-lm", "-z", "noexecstack"], check=True)
    sys.exit(subprocess.run([exe] + sys.argv[2:]).returncode)


if __name__ == "__main__":
    main()
