# MOOS — handoff

This is a working handoff for **MOOS (Mightily Optimized Operating System)**, a small
operating system written from scratch in x86 assembly. It is not based on Linux, DOS or
anything else. This document is for whoever picks the project up next (human or AI): what
exists, how it is put together, how to build and test it, and what is unfinished.

## What MOOS is

A ~200 KB operating system that boots on real PCs and virtual machines, on both **UEFI**
(modern) and **legacy BIOS** firmware, with a text shell, a persistent file system, a
networking stack with **HTTPS (TLS 1.3)**, a package manager that installs from **GitHub**,
a small scripting language, and a graphical desktop.

Everything is original code: boot loader, UEFI loader, drivers (screen, keyboard, timer,
disk, network card), file system, shell, editor, calculator, TCP/IP, cryptography and TLS,
X.509 certificate checking, and GUI.

## Current state (what works, all tested)

Tested in QEMU (BIOS and UEFI) and VirtualBox (BIOS and UEFI). Screenshots were taken at
each step. The installer and disk persistence were verified across reboots.

- **Boot**: BIOS (boot sector → 32-bit protected mode) and UEFI (`BOOTX64.EFI` loader →
  32-bit compatibility mode, firmware still live). One kernel serves both.
- **Console**: 80×25 text. On BIOS it is VGA text mode; on UEFI it is drawn into the
  graphics framebuffer with the built-in font. Status bar with a live clock.
- **File system (MOOSFS)**: 32 files × 4 KB, in the reserved sectors of a FAT16 partition.
  Write-through to disk. Reached via the ATA driver (BIOS/IDE), the BIOS (USB/AHCI), or the
  UEFI firmware (anything it can boot from).
- **Installer** (`install`): copies MOOS onto another disk; the result boots on BIOS and
  UEFI. Guards against erasing the running disk; requires typing `ERASE`.
- **Commands**: ls, cat, write, append, edit (full-screen editor), rm, rename, copy, find,
  wc, hexdump, echo, calc, run, clear, color, time, clock, net, apt, get, uptime, mem,
  sysinfo, history, login, format, reboot, shutdown, help, man, gui, install. Plus aliases
  (dir, del, nano, grep, wget, curl, …). Every command has a `man` page.
- **Networking** (`net`): RTL8139 NIC driver (PCI, polled, 32 KB receive ring), Ethernet/ARP,
  IPv4, UDP, DHCP, DNS, a small TCP client, HTTP GET. `net up/status/test/selftest/http`.
- **HTTPS** (`get`, and used by `apt` and the Browser): a TLS 1.3 client written from
  scratch — X25519, AES-128-GCM, SHA-256 (+ SHA-384/512 for certificates), HKDF key
  schedule, record layer — plus **X.509 certificate checking**: chain to built-in RSA roots,
  CA flags, dates, hostname/SAN wildcards, and the RSA-PSS CertificateVerify. Verified
  against real servers (raw.githubusercontent.com, github.com, www.google.com) and against
  local servers with bad certificates (untrusted, expired, wrong name, forged issuer), which
  are all refused. `net selftest` runs 23 known-answer tests of the crypto.
- **Clock** (`clock`): 12/24-hour, status-bar colour, timezone, and internet time sync
  (NTP, falling back to the HTTP `Date` header where UDP 123 is blocked). Settings persist.
- **Package manager** (`apt`): installs `.pkg` files from **GitHub over checked HTTPS**.
  `apt install <name>` → this repo's `packages/<name>.pkg`; `apt install /user/repo` →
  `moos.pkg` at the top of that GitHub repo. `apt remove/list/repo` (other http/https repos
  allowed). Packages cannot overwrite MOOS's settings files. Published packages: `desktop`,
  `hello`, `demos` (also `moos.pkg` at the repo root). Guide: `PACKAGES.md`.
- **Scripting** (`run`): a small language (variables, `if/else`, `while`, `print`,
  expressions with comparisons), sharing the calculator's expression engine.
- **Desktop** (`gui`, UEFI only): low-poly moose wallpaper, taskbar + clock, mouse cursor,
  and windowed apps — Terminal (runs real commands), Text Editor, Script IDE (edit + run),
  Browser (fetches `https://` and `http://` pages) and Settings. Installed with
  `apt install desktop`.
- **Sign-in** (`login`): optional password screen at start-up. Off by default.

## How to build

Needs **Python 3**, **NASM**, and **QEMU** (for running/testing). All are installed on the
original dev machine.

```
python build.py            # build build/moos.img (hybrid BIOS + UEFI, 5 MB)
python build.py run        # run in QEMU as a BIOS PC
python build.py uefi       # run in QEMU as a UEFI PC
python build.py vm         # also make VirtualBox/VMware/Hyper-V disks
python build.py fresh run  # start from an empty disk
```

`build.py` assembles the kernel twice (at two addresses) to find the ~2,700 locations the
UEFI loader must relocate, builds the BIOS boot sector and the `BOOTX64.EFI` loader, lays
out a FAT16 partition with an MBR, and carries your saved files across rebuilds.

## How to test

`tools/screentest.py` boots a copy of the image in headless QEMU, types keys through the
QEMU monitor, and prints MOOS's screen (it finds the screen buffer in guest memory by a
marker). It can also save real screenshots.

```
python tools/screentest.py "help\n" @screen
python tools/screentest.py --uefi "gui\n" @wait=3 @png=shot.png
python tools/screentest.py --uefi --drive "-machine q35 ..." ...   # other disk types
```

Networking tests use QEMU user-mode networking (added automatically), and QEMU runs with
`-cpu max` so the guest has RDRAND. From the guest, the host is `10.0.2.2`.

```
python tools/screentest.py "net selftest\n" @wait=8 @screen        # crypto known answers
python tools/screentest.py "get https://raw.githubusercontent.com/treedev10/moos/HEAD/README.md\n" @wait=20 @screen
python tools/screentest.py "apt install /treedev10/moos\n" @wait=20 @screen
python packages/serve.py          # local package repo on :8000 (apt repo http://10.0.2.2:8000)
```

For TLS debugging, `get -v` prints every record and handshake message and the handshake
secret; compare with a local Python TLS 1.3 server that writes an SSLKEYLOGFILE
(`ssl.SSLContext.keylog_filename`). Negative tests need servers with bad certificates
(self-signed, expired, wrong name, forged issuer) — each must be refused.

## Architecture / source map

The kernel is one flat 32-bit binary, assembled for 0x10000, written so the UEFI loader can
move it. `src/kernel.asm` has the memory map and the module include list.

| Area | Files |
|---|---|
| Boot | `src/boot.asm` (BIOS MBR), `efi/loader.asm` (`BOOTX64.EFI`) |
| Kernel core | `src/kernel.asm`, `src/bootinfo.inc`, `src/layout.inc`, `src/macros.inc`, `src/lib.asm` |
| Firmware bridge | `src/efi.asm` (64-bit calls into UEFI: keyboard, disk, clock, reset, mouse, graphics) |
| Drivers | `src/vga.asm`, `src/idt.asm`, `src/kbd.asm`, `src/rtc.asm`, `src/ata.asm`, `src/bios.asm`, `src/acpi.asm` |
| File system | `src/fs.asm`; installer `src/installer.asm` |
| Networking | `src/net.asm`, `src/net_arp.asm`, `src/net_ip.asm`, `src/net_dhcp.asm`, `src/net_dns.asm`, `src/net_tcp.asm`, `src/cmd_net.asm` |
| Crypto | `src/crypto.asm` (SHA-256, HMAC, HKDF, RNG), `src/sha512.asm`, `src/aes.asm` (AES-128, GCM), `src/x25519.asm`, `src/rsa.asm`, `src/selftest.asm`; tables `src/crypto_tables.inc` (tools/gen_tables.py), test vectors `src/selftest_vectors.inc` (tools/gen_vectors.py) |
| HTTPS | `src/tls.asm` (TLS 1.3 client, https_get), `src/x509.asm` (certificate checks), `src/roots.bin` (tools/gen_roots.py), `src/url.asm` (url_fetch, `get`) |
| Shell + commands | `src/shell.asm`, `src/readline.asm`, `src/pager.asm`, `src/cmd_files.asm`, `src/cmd_system.asm`, `src/cmd_clock.asm`, `src/cmd_apt.asm`, `src/cmd_login.asm` |
| Calc + scripting | `src/calc.asm`, `src/script.asm` |
| Editor | `src/editor.asm` |
| Graphics + GUI | `src/gfx.asm`, `src/gui.asm`, `src/gui_win.asm`, `src/gui_apps.asm` |
| Manuals | `man/*.txt` (embedded into the kernel at build time) |
| Font | `src/font8x16.bin` (public-domain VGA font, extracted by `tools/makefont.py`) |

Key mechanisms to understand before changing things:

- **UEFI calls from 32-bit**: `efi64` (in `src/efi.asm`) far-calls into a 64-bit stub that
  invokes the firmware with the Microsoft x64 ABI, then returns. Drawing is done directly to
  the framebuffer from 32-bit code; only keyboard/disk/clock/mouse/reset go through the
  firmware.
- **Relocation**: the kernel uses `KV(addr)` (= `kbase + addr - 0x10000`) for absolute
  addresses so the UEFI loader can place it anywhere; `build.py` finds the fix-ups.
- **Output capture**: the GUI terminal sets `gui_capture`, which reroutes `out_char` into a
  log buffer so command output can be shown in a window.
- **Calling conventions**: most of the kernel passes arguments in registers. The crypto/TLS
  code uses C-style calls (`CCALL fn, a, b, c` + `CENTER`/`CLEAVE`, `ARG(n)`; EBX ESI EDI EBP
  preserved, EAX ECX EDX not) because those functions take many arguments.
- **TLS flow** (`tls_connect`): ClientHello (SNI, x25519 key share, RSA sig algs) →
  ServerHello → handshake keys (HKDF) → decrypt EncryptedExtensions/Certificate/
  CertificateVerify/Finished, check the Finished MAC → `tls_check_server` (x509.asm) →
  application keys → our Finished. Records are read through `tcp_pump` into a 32 KB stream
  buffer (`TLS_BASE` in kernel.asm's memory map).
- **Certificate trust** fails closed: unknown algorithm, unknown issuer, non-CA issuer,
  bad date, wrong name or bad signature all refuse the connection. `get -k` is the only way
  to skip it (prints a warning; apt never uses it).
- **Common asm gotchas seen in this codebase**: `str_iprefix`/`str_icmp` take the prefix in
  ESI and the string in EDI (easy to swap); a macro that `mov`s into a register must not be
  passed that same register as a later argument (RECT/`net_tx_frame` had this); keeping a
  loop counter in a register whose low half you later overwrite (`mov bx, 123` clobbering a
  count in EBX) bit the NTP and DHCP code. The calculator's comparison must `cmp` and `setcc`
  with nothing in between that touches flags. `rep movsb` counts ECX down to 0 — save the
  length first (bit the TLS handshake buffer). With CCALL, ECX/EDX don't survive calls.
- **Build quirk**: in the Bash tool here, `\\` inside a quoted heredoc becomes `\` — write
  Python edit scripts to files with the Write tool when they contain backslashes.

## Comment-free source

The source in `src/` and `efi/` is heavily commented on purpose. Comments do not affect the
assembled binary, so a comment-stripped copy lives in `nocomments/` (about 29% smaller),
generated by `tools/strip_comments.py` (`--check` rebuilds from it to prove it still works).
The commented source is canonical.

## Known limitations / not done

- **GUI is UEFI-only** (needs the graphics framebuffer and the firmware pointer protocol).
  On BIOS, `gui` says so. A VBE/VESA path + PS/2 mouse driver would add BIOS support.
- **HTTPS limits**: TLS 1.3 only, one cipher suite (TLS_AES_128_GCM_SHA256), X25519 only,
  **RSA certificates only** — sites that offer only ECDSA certificates (e.g. Wikipedia) are
  refused (alert 40). No session resumption, no client certificates, no revocation (OCSP/CRL)
  checks, no certificate-transparency checks. 15 built-in roots (tools/gen_roots.py); roots
  are not updated automatically. Date checks use the PC clock (UTC assumed).
- **Randomness**: TLS keys use RDRAND when the CPU has it, otherwise a SHA-256 pool fed by
  timer jitter, the MAC address and the time — fine for a hobby OS, weaker than a real OS.
- **NTP (UDP 123)** works on normal networks but is blocked in some environments (it was in
  the dev sandbox); `clock sync` falls back to HTTP there.
- **Networking** has one NIC (RTL8139), one ARP cache, no IP fragmentation, and a TCP client
  that assumes in-order, lossless delivery and never retransmits (fine behind QEMU's SLIRP,
  which does the real TCP; fragile on a real lossy network). Downloads are limited to the
  512 KB package buffer; saved files to 4 KB (the MOOSFS limit).
- **GUI apps are deliberately simple**: the editor is append/backspace/enter (no mid-line
  cursor); the browser shows page text only (no HTML rendering); one window at a time.
- **Mouse interaction** (clicking taskbar buttons / the close box) is implemented but was
  hard to drive in the headless test harness, so it was verified mainly by launching apps
  via `gui <app>` from the keyboard. Worth a manual click-through.
- **Sign-in is light protection**, not real security (simple password hash, no encryption).

## Good next steps

- Click-through test of the GUI with a real mouse; add window dragging and multiple windows.
- A fuller GUI text editor (cursor movement, selection) reusing `src/editor.asm` logic.
- BIOS graphics (VBE) so the desktop runs on old PCs too.
- A second NIC driver (e1000/virtio) and a more robust TCP.
- ECDSA (P-256/P-384) certificate verification, to reach ECDSA-only sites.
- TCP retransmission and a receive window that tracks free buffer space.
- A larger file system (MOOSFS files are 4 KB), so bigger packages and downloads fit.
