# Making MOOS packages

MOOS installs software with `apt`. A **package** is a single text file, `<name>.pkg`,
that holds one or more files; `apt` downloads it (from GitHub, over HTTPS) and writes those
files onto the MOOS disk. This is the developer guide: the format, how to build a package,
and how to publish it so anyone can install it.

## Installing (the user's side)

```
apt install desktop            # from the official repository (this repo's packages/)
apt install /someone/theirrepo # from any GitHub repository that has a moos.pkg
apt list                       # what's installed, and where it came from
```

- `apt install <name>` fetches `<repository>/<name>.pkg`. The default repository is
  `https://raw.githubusercontent.com/treedev10/moos/HEAD/packages`.
- `apt install /user/repo` fetches `https://raw.githubusercontent.com/user/repo/HEAD/moos.pkg`
  — the file `moos.pkg` at the top of that GitHub repository, on its default branch.

Both go over **HTTPS with the certificate checked** (MOOS's own TLS 1.3 + X.509 code), so a
package really comes from GitHub and wasn't changed on the way.

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
- `name:` is the package's name (used for `apt list` / `apt remove`; up to 14 characters of
  letters, digits, `.`, `-`, `_`). `desc:` is a one-line description. Both are optional.
- Each file is a `@file <name> <size>` line, then **exactly `<size>` bytes** of the file,
  then a newline. The bytes are copied as-is, so files may contain anything.
- `@end` finishes the package.

Limits come from the MOOS file system: file names are 1–19 characters (letters, digits,
`.`, `-`, `_`), each file holds at most **4096 bytes**, and a disk holds 32 files.

For safety, a package can never replace MOOS's own settings files (`apt.repo`, `login.cfg`,
`clock.cfg`) or the `*.inst` markers that track installed packages; such entries are skipped
with a warning.

## What a package can contain

- **Scripts** for MOOS's scripting language (`.ms` files) — `run name.ms` runs them, and the
  desktop's Script IDE edits and runs them. See `man script`.
- **Text, data and configuration** for other commands.
- The **desktop** itself is a package: installing it writes `desktop.inst`, which unlocks
  the built-in `gui` command.

MOOS has no loader for native machine code, so packages are scripts and data. Nothing in a
package runs until the user runs it.

## Building a package

From a list of files:

```
python tools/mkpkg.py hello --desc "a friendly greeting" hello.ms readme.txt > hello.pkg
```

Or from a folder: put the files in `packages/<name>/` in this repository and run

```
python packages/serve.py --build
```

which writes `packages/<name>.pkg` for every folder (and copies `demos.pkg` to the repository
root as `moos.pkg`).

## Publishing on GitHub (recommended)

1. Create a GitHub repository, for example `you/coolstuff`.
2. Build your package and commit it **at the top of the repository** as `moos.pkg`.
3. Push. Anyone can now install it in MOOS with:

   ```
   apt install /you/coolstuff
   ```

That's all — no server to run. `apt` asks for `.../HEAD/moos.pkg`, so it always gets the
latest version on your default branch (GitHub's cache can take a few minutes to update after
a push).

Example: this repository publishes its demo scripts that way —
`apt install /treedev10/moos` installs `primes.ms`, `fizzbuzz.ms` and `countdown.ms`.

### Adding to the official repository

The packages under `apt install <name>` live in this repository's `packages/` folder. To add
one: create `packages/<name>/` with its files, run `python packages/serve.py --build`, and
commit both the folder and the generated `packages/<name>.pkg`.

## Hosting elsewhere (HTTP or HTTPS)

Any web server can host packages; point MOOS at it with `apt repo`:

```
apt repo https://example.com/moos-packages   # checked HTTPS
apt repo http://10.0.2.2:8000                # plain HTTP (a test server on the QEMU host)
apt repo github                              # back to the default
```

For local development, `python packages/serve.py` builds the packages in `packages/` and
serves them on port 8000; from QEMU the host is `10.0.2.2`.

Plain `http://` repositories are neither encrypted nor checked — use them only on a network
you trust.

## Requirements for HTTPS hosts

MOOS's TLS client supports TLS 1.3 with `TLS_AES_128_GCM_SHA256`, X25519 key exchange, and
**RSA** certificates (chains signed with SHA-256/384/512 RSA) that lead to one of its
built-in root certificates (see `tools/gen_roots.py`). GitHub's raw-content server meets all
of these. Servers with only ECDSA certificates are not supported yet.
