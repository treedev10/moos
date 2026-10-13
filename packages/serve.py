#!/usr/bin/env python3
"""
Build the example MOOS packages and serve them over HTTP, so MOOS can install
them with apt.

    python packages/serve.py [port]        (default port 8000)
    python packages/serve.py --build       only (re)build the .pkg files

Each sub-folder here (hello/, desktop/, ...) becomes <name>.pkg containing all
the files in it. Then, inside MOOS:

    apt repo 10.0.2.2:8000      (10.0.2.2 is the QEMU host; use your host's
                                 address on a real network)
    apt install hello
    apt install desktop

See PACKAGES.md for how to make your own packages.
"""
import http.server
import os
import socketserver
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tools"))


def build_packages():
    import mkpkg  # noqa: F401 (reuse its format)
    for name in sorted(os.listdir(HERE)):
        folder = os.path.join(HERE, name)
        if not os.path.isdir(folder):
            continue
        files = [os.path.join(folder, f) for f in sorted(os.listdir(folder))
                 if os.path.isfile(os.path.join(folder, f))]
        if not files:
            continue
        out = os.path.join(HERE, name + ".pkg")
        with open(out, "wb") as o:
            o.write(b"MOOSPKG 1\n")
            o.write(("name: %s\n" % name).encode())
            for path in files:
                data = open(path, "rb").read()
                o.write(("@file %s %d\n" % (os.path.basename(path), len(data))).encode())
                o.write(data)
                o.write(b"\n")
            o.write(b"@end\n")
        print("built", name + ".pkg")


def main():
    if "--build" in sys.argv[1:]:
        build_packages()
        # the demos package doubles as this repo's own GitHub package:
        # "apt install /treedev10/moos" fetches moos.pkg at the top level
        demos = os.path.join(HERE, "demos.pkg")
        if os.path.exists(demos):
            data = open(demos, "rb").read()
            open(os.path.join(HERE, "..", "moos.pkg"), "wb").write(data)
            print("copied demos.pkg -> moos.pkg (repository root)")
        return
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
    build_packages()
    os.chdir(HERE)
    handler = http.server.SimpleHTTPRequestHandler
    with socketserver.TCPServer(("", port), handler) as httpd:
        print("Serving MOOS packages on http://localhost:%d  (Ctrl+C to stop)" % port)
        print("In MOOS:  apt repo 10.0.2.2:%d   then   apt install desktop" % port)
        httpd.serve_forever()


if __name__ == "__main__":
    main()
