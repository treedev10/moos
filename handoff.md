# MOOS — handoff

This is a working handoff for **MOOS (Mightily Optimized Operating System)**, a small
operating system written from scratch in x86 assembly. It is not based on Linux, DOS or
anything else. This document is for whoever picks the project up next (human or AI): what
exists, how it is put together, how to build and test it, and what is unfinished.

## What MOOS is

A ~130 KB operating system that boots on real PCs and virtual machines, on both **UEFI**
(modern) and **legacy BIOS** firmware, with a text shell, a persistent file system, a
networking stack, a package manager, a small scripting language, and a graphical desktop.

Everything is original code: boot loader, UEFI loader, drivers (screen, keyboard, timer,
disk, network card), file system, shell, editor, calculator, TCP/IP, and GUI.

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
  wc, hexdump, echo, calc, run, clear, color, time, clock, net, apt, uptime, mem, sysinfo,
  history, login, format, reboot, shutdown, help, man, gui, install. Plus aliases
  (dir, del, nano, grep, …). Every command has a `man` page.
- **Networking** (`net`): RTL8139 NIC driver (PCI, polled), Ethernet/ARP, IPv4, UDP, DHCP,
  DNS, a minimal TCP client, and HTTP GET. `net up`, `net status`, `net test`, `net http`.
- **Clock** (`clock`): 12/24-hour, status-bar colour, timezone, and internet time sync
  (NTP, falling back to the HTTP `Date` header where UDP 123 is blocked). Settings persist.
- **Package manager** (`apt`): downloads `.pkg` files over HTTP and installs them into the
  file system. `apt install/remove/list/repo`. Packages are plain text; `tools/mkpkg.py`
  builds them.
- **Scripting** (`run`): a small language (variables, `if/else`, `while`, `print`,
  expressions with comparisons), sharing the calculator's expression engine.
- **Desktop** (`gui`, UEFI only): low-poly moose wallpaper, taskbar + clock, mouse cursor,
  and windowed apps — Terminal (runs real commands), Text Editor, Script IDE (edit + run),
  and a Browser (fetches `http://` pages). Installed with `apt install desktop`.
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

Networking tests use QEMU user-mode networking (added automatically). For the package
manager, run a local HTTP server and point `apt repo` at `10.0.2.2:<port>` (the SLIRP
gateway is the host):

```
cd some/package/dir && python -m http.server 8000
# in MOOS:  apt repo 10.0.2.2:8000   then   apt install <name>
```

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
- **Common asm gotchas seen in this codebase**: `str_iprefix`/`str_icmp` take the prefix in
  ESI and the string in EDI (easy to swap); a macro that `mov`s into a register must not be
  passed that same register as a later argument (RECT/`net_tx_frame` had this); keeping a
  loop counter in a register whose low half you later overwrite (`mov bx, 123` clobbering a
  count in EBX) bit the NTP and DHCP code. The calculator's comparison must `cmp` and `setcc`
  with nothing in between that touches flags.

## Comment-free source

The source in `src/` and `efi/` is heavily commented on purpose. Comments do not affect the
assembled binary, so a comment-stripped copy lives in `nocomments/` (about 29% smaller),
generated by `tools/strip_comments.py` (`--check` rebuilds from it to prove it still works).
The commented source is canonical.

## Known limitations / not done

- **GUI is UEFI-only** (needs the graphics framebuffer and the firmware pointer protocol).
  On BIOS, `gui` says so. A VBE/VESA path + PS/2 mouse driver would add BIOS support.
- **No HTTPS/TLS** — far too large to write from scratch here. So the package manager and
  the browser use **plain HTTP**. GitHub serves only over HTTPS, so packages must be hosted
  on a plain-HTTP server (or an HTTP mirror); `apt install /user/repo` fetches
  `/user/repo.pkg` to fit a GitHub-style path layout behind such a mirror.
- **NTP (UDP 123)** works on normal networks but is blocked in some environments (it was in
  the dev sandbox); `clock sync` falls back to HTTP there.
- **Networking** has one NIC (RTL8139), one ARP cache, no IP fragmentation, and a TCP client
  that assumes in-order, lossless delivery (fine for SLIRP and a nearby server, not the open
  internet under loss).
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
- Publish real packages to a plain-HTTP host and document the flow end to end.
