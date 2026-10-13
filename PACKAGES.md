# Making MOOS packages

MOOS installs software with `apt`, which downloads a **package** over plain HTTP and writes
the files inside it onto the MOOS disk. A package is a single text file, `<name>.pkg`. This
guide is the developer documentation for the package format and for hosting packages.

## Quick start

```
# on your computer (the one running QEMU / hosting packages):
python packages/serve.py          # builds the example packages and serves them on :8000

# inside MOOS:
net up
apt repo 10.0.2.2:8000            # 10.0.2.2 is the QEMU host; use your LAN IP on real HW
apt install hello
apt install desktop
```

`apt install <name>` fetches `http://<repo>/<name>.pkg`. `apt install /user/repo` fetches
`http://<repo>/user/repo.pkg`, so a GitHub-style path layout works behind an HTTP mirror.

## The package format

A `.pkg` is plain text:

```
MOOSPKG 1
name: hello
desc: a friendly greeting
@file hello.ms 61
print "Hello from a MOOS package!"
set x = 6 * 7
print "6 times 7 is" x
@file readme.txt 64
This file was installed by apt over HTTP.
Run the script with:  run hello.ms
@end
```

- The first line must be `MOOSPKG 1`.
- Optional `name:` / `desc:` lines describe the package.
- Each file is a `@file <name> <size>` line, then **exactly `<size>` bytes** of that file,
  then a newline.
- `@end` finishes.
- After installing, apt writes a marker file `<name>.inst` so `apt list` can show it.

File names and sizes follow the MOOS file system limits: 1–19 characters, and at most
4096 bytes per file (see `man files`).

## Building a package

Use `tools/mkpkg.py` to build one from a set of files:

```
python tools/mkpkg.py hello --desc "a friendly greeting" hello.ms readme.txt > hello.pkg
```

Or drop a folder of files under `packages/<name>/` and run `python packages/serve.py`, which
turns every sub-folder into `<name>.pkg` and serves them.

## Hosting

Any plain-HTTP server works: `python -m http.server`, nginx, Apache, a static host, etc.
Point MOOS at it with `apt repo <host[:port]>`.

**GitHub note:** `raw.githubusercontent.com` and `github.com` serve only over **HTTPS**, and
MOOS does not implement TLS, so it cannot download from GitHub directly. Host the `.pkg`
files on a plain-HTTP server, or an HTTP mirror/proxy of your GitHub repo. The
`apt install /user/repo` syntax exists so a mirror laid out like GitHub paths just works.

## What packages can contain

- **Scripts** (`.ms`) that `run` executes — see `man script`.
- **Text files, data, configuration** used by other commands.
- The **desktop** is itself a package (`apt install desktop`); it writes a small file and the
  `desktop.inst` marker, which unlocks the built-in `gui` command.

Because MOOS has no dynamic loader for native code, packages are scripts and data, not new
native binaries. New built-in commands are added by editing the kernel source (see
`handoff.md`).
