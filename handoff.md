# MOOS — handoff

This is a working handoff for **MOOS (Mightily Optimized Operating System)**, a small
operating system written from scratch in x86 assembly. It is not based on Linux, DOS or
anything else. This document is for whoever picks the project up next (human or AI): what
exists, how it is put together, how to build and test it, and what is unfinished.

## What MOOS is

A ~220 KB operating system that boots on real PCs and virtual machines, on both **UEFI**
(modern) and **legacy BIOS** firmware, with a text shell, a persistent file system, a
networking stack with **HTTPS (TLS 1.3)**, a package manager that installs from **GitHub**,
a small scripting language, and a graphical desktop with movable, resizable windows and a
web browser that renders HTML.

Everything is original code: boot loader, UEFI loader, drivers (screen, keyboard, timer,
disk, network card), file system, shell, editor, calculator, TCP/IP, cryptography and TLS,
X.509 certificate checking, GUI, window manager, and the browser's HTML engine.

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
- **Networking** (`net`): Ethernet/ARP, IPv4, UDP, DHCP, DNS, a small TCP client, HTTP GET.
  `net up [firmware|native]/status/cards/test/selftest/http`. Network cards, all polled:
  - **UEFI firmware driver** (`src/nic_snp.asm`): the Simple Network Protocol, so on a UEFI
    PC any wired card the firmware can network-boot from works. Tried first on UEFI.
  - **Intel e1000 / e1000e** (`src/nic_e1000.asm`): 8254x, 8257x, I217/I218/I219.
  - **Realtek RTL8111/8168/8169/810x** (`src/nic_rtl8168.asm`): the common onboard chip.
    **Untested on real hardware** (no emulator models it).
  - **Realtek RTL8139** (in `src/net.asm`): QEMU's default.
  `net cards` scans every PCI bus, lists network devices with IDs and driver status, and
  on UEFI says whether the firmware offers SNP (and how to enable it if not).
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
- **Desktop** (`gui`, UEFI only): solid-colour background (8 choices in Settings, saved in
  clock.cfg byte 2), taskbar (buttons show open/focused windows; clicking the focused app's
  button minimizes it) + clock, mouse cursor (a hand over links), mouse wheel.
  **Window manager** (`src/gui_win.asm`): one window per app, any number open, overlapping
  in a z-order; drag the title bar to move, any edge/corner (or the dotted grip) to resize,
  maximize (button or double-click title; dragging a maximized window restores it),
  minimize to the taskbar, close (x or Esc). Keyboard: F1-F5 and F11 open apps, F6 next
  window, F7/F8 move/resize with arrows, F9 minimize, F10 maximize. Apps: Terminal (runs real
  commands, keeps their colours), Text Editor and Script IDE (separate buffers; Run shows
  output in the Terminal), Browser, Settings (lines clickable), Task Manager. Installed with
  `apt install desktop`.
- **Task Manager** (`gui tasks`, F11, taskbar "Tasks", `man tasks`; `src/gui_tasks.asm`):
  open windows with state, CPU % and memory, and an End task button per row (closes the
  window, calls the app's `end` hook, `big_free_owner`); CPU graph of the last 60 s; network
  bytes/s in/out graph and totals (counters in `net_tx_frame` / `net_rx_poll`); memory:
  kernel code/variables, fixed buffers, big blocks by owner, RAM installed and free from the
  firmware's memory map (`efi_memmap`); uptime; frames per second. Updates once a second,
  redrawing only its own content when it is the top window (`gui_content_dirty`); one column
  with a scroll bar (wheel, PgUp/PgDn/Home/End) when narrow. `mem take <MB>` / `mem give`
  (full kernel) take big blocks by hand, to try this out.
- **fetch** (alias `neofetch`, both kernels, also in the desktop Terminal): an original ASCII
  cow in colour beside user@host, OS, firmware, kernel and size, uptime, apt packages,
  shell, resolution, CPU brand (CPUID) / processors (ACPI MADT) / TSC MHz, memory, MOOSFS,
  network, and the 16 colours.
- **Browser** (`gui browser [url]`, `man browser`): its own HTML engine (`src/html.asm`) and
  app (`src/browser.asm`) — see "Browser engine" below. Toolbar (Back/Forward/Reload/Home,
  address bar with a lock for HTTPS, Go), status line (progress, size, security, hovered
  link), scroll bar + wheel + keys, Tab/Enter link navigation, history (16), redirects (8),
  `#anchors`, `<base href>`, chunked replies, plain text, `view-source:`, GET forms (text,
  password, hidden, checkbox, radio, submit, `<button>`), `about:home` and `about:test`.
  Tested against local servers (HTTP, HTTPS with a self-signed cert → refused with the
  reason, and with the check disabled in a throwaway build → rendered with the lock) and a
  real 306 KB GitHub page served locally.
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
python tools/screentest.py --uefi "gui browser 10.0.2.2:8000/\n" @wait=10 @ptr=250,202,0 @ptr=250,202,1 @ptr=250,202,0 @png=b.png
```

The desktop needs the `desktop.inst` marker that `apt install desktop` leaves; the image
keeps your files across rebuilds, so install it once (or write the marker into a test copy
of the image). For the browser, serve test pages from the host (`python -m http.server
8000`) and open `10.0.2.2:8000/...`; `about:test` exercises the engine without a network.

Networking tests use QEMU user-mode networking (added automatically), and QEMU runs with
`-cpu max` so the guest has RDRAND. From the guest, the host is `10.0.2.2`. The card is an
RTL8139 unless you pick another: `screentest.py --nic e1000` (or `e1000e`, `virtio-net-pci`,
`none`), or `MOOS_NIC=e1000` for `build.py run/uefi`. Under `--uefi`, QEMU's iPXE option
ROMs give the firmware SNP driver, so `net up` uses it; `net up native` forces MOOS's own.
QEMU's e1000 ignores received frames for about a second after RCTL is written — DHCP waits
3 s per step and ignores stray/late replies (`dhcp_wait_type`) partly because of this.

```
python tools/screentest.py "net selftest\n" @wait=8 @screen        # crypto known answers
python tools/screentest.py "get https://raw.githubusercontent.com/treedev10/moos/HEAD/README.md\n" @wait=20 @screen
python tools/screentest.py "apt install /treedev10/moos\n" @wait=20 @screen
python packages/serve.py          # local package repo on :8000 (apt repo http://10.0.2.2:8000)
```

**Native module tests**: the self-contained modules (`src/mp4.asm`, `src/json.asm`, and
the other media decoders) are also assembled on their own and linked with C test programs
on Linux, which check them against independent references (ffprobe for MP4, Python's
`json` module for JSON) with guard pages around every buffer, fuzz them, and time them.
`tests/native/README.md` has the module rules and the API contracts.

```
python3 tests/native/mp4_data.py && python3 tests/native/run.py mp4      # 32 files vs ffprobe
python3 tests/native/run.py mp4 fuzz 2000                                  # mutated moov boxes
python3 tests/native/json_data.py && python3 tests/native/run.py json    # ~32k documents vs Python
python3 tests/native/run.py json fuzz 20000 ; python3 tests/native/run.py json bench
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
| Networking | `src/net.asm` (PCI scan, card table, dispatch, RTL8139), `src/nic_e1000.asm`, `src/nic_rtl8168.asm`, `src/nic_snp.asm`, `src/net_arp.asm`, `src/net_ip.asm`, `src/net_dhcp.asm`, `src/net_dns.asm`, `src/net_tcp.asm`, `src/cmd_net.asm` |
| Crypto | `src/crypto.asm` (SHA-256, HMAC, HKDF, RNG), `src/sha512.asm`, `src/aes.asm` (AES-128, GCM), `src/x25519.asm`, `src/rsa.asm`, `src/selftest.asm`; tables `src/crypto_tables.inc` (tools/gen_tables.py), test vectors `src/selftest_vectors.inc` (tools/gen_vectors.py) |
| HTTPS | `src/tls.asm` (TLS 1.3 client, https_get), `src/x509.asm` (certificate checks), `src/roots.bin` (tools/gen_roots.py), `src/url.asm` (url_fetch, `get`) |
| Shell + commands | `src/shell.asm`, `src/readline.asm`, `src/pager.asm`, `src/cmd_files.asm`, `src/cmd_system.asm`, `src/cmd_clock.asm`, `src/cmd_apt.asm`, `src/cmd_login.asm`, `src/cmd_fetch.asm` |
| Calc + scripting | `src/calc.asm`, `src/script.asm` |
| Editor | `src/editor.asm` |
| Graphics + GUI | `src/gfx.asm` (back buffer, clip rectangle, sized/styled glyphs, icons), `src/gui.asm` (desktop, taskbar, cursor, main loop), `src/gui_win.asm` (window manager), `src/gui_apps.asm` (terminal, editor, IDE, settings), `src/gui_tasks.asm` (Task Manager, CPU accounting) |
| Browser | `src/html.asm` (parser, layout, painter, forms), `src/browser.asm` (the app: toolbar, navigation, history, URLs) |
| Media / data modules (UEFI kernel only) | `src/mp4.asm` (MP4 demuxer: find the moov box, tracks, sample tables), `src/json.asm` (JSON tokenizer); self-contained (`src/module.inc`), tested natively in `tests/native/` |
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
  log buffer so command output can be shown in a window. `gui_capture = 2` throws output
  away (the browser sets it while fetching). While the desktop runs, `gui_active` makes
  `screen_present` a no-op, so network code that refreshes the text console while waiting
  cannot draw over the desktop.
- **Window manager** (`gui_win.asm`): per-app arrays `wn_x/y/w/h/f` (+ the rectangle to
  restore after maximizing), `z_list` (bottom first), `cur_app` = focused window. Each frame
  `gui_windows` draws bottom to top; for each window `wm_draw` sets `cb_x/y/w/h` (content
  box) and narrows the gfx clip rectangle to it before calling the app's draw. `wm_hit`
  finds window + part (title, buttons, content, edges with `EDGE_*` bits) under the mouse;
  `gui_handle` turns press/hold/release into raise, button actions, `DRAG_MOVE`,
  `DRAG_SIZE` or `DRAG_APP` (the browser's scroll bar). Apps plug in through `app_init`,
  `app_draw`, `app_title`, `app_click`, `app_key` (+ `brow_hover/wheel/drag`), `app_tick`
  (every round of the main loop while the window is open, even minimized: background work
  such as feeding a sound card; return CF=1 when it did work) and `app_end` (End task: let
  go of everything; big blocks owned by the app number are freed afterwards).
- **CPU accounting** (`gui_tasks.asm`): every RDTSC cycle of the desktop is charged to one
  owner: idle (rounds of `cmd_gui .loop` in which nothing happened - the polling), an app
  (between `cpu_enter`/`cpu_leave`; the `APP_CALL owner, routine` macro wraps every call
  into an app, including nested redraws while a page loads), or the desktop (`CPU_DESK`:
  window manager, taskbar, cursor, presenting). Once 100 ticks have passed, `cpu_sample`
  turns the counts into thousandths (`cpu_pm`), calibrates the TSC against the timer
  (`cpu_mhz`), takes the network rates and fps, and appends to 60-entry rings (`cpuh_*`).
  While an app holds the loop up (a long command, a page load) nothing is sampled; the
  whole stretch is then averaged and fills one point per second. New apps must call
  through `APP_CALL` (or the dispatchers) or their time lands on the desktop.
  `screentest.py @peek=cpu_pm,17` reads the numbers from the guest.
- **Browser engine** (`html.asm`): three stages. `html_parse` turns HTML into a compact node
  stream at `BR_NODES` (text already decoded to the CP437 font: entities, UTF-8, a
  Windows-1252 fallback, collapsed spaces; element open/close with only the attributes MOOS
  uses; script/style/svg/select/template and hidden parts — `hidden`, `display:none`,
  well-known hiding classes — dropped). `html_layout` flows nodes into 32-byte display
  items (`BR_ITEMS`: text runs in one style, rectangles, form fields) at a given width,
  with a style stack (`BR_STACK`), margins, list markers, implicit closing (`<p>`, `<li>`,
  `<td>`...), and a measuring pre-pass that lines up simple tables' columns. It reruns when
  the window's width changes. `html_paint` draws visible items; `html_link_at` /
  `html_field_at` hit-test. Fonts are the 8x16 VGA font stretched to 10/12/16-pixel widths
  (h3/h2/h1), with bold/italic/underline/strike done by `gfx_glyph`.
- **Browser memory**: `BR_BASE` = KV(0x7E0000), 2 MB (nodes 640K, items 768K, pool, anchors,
  element stack, history, tables, form fields). `KMEM_SIZE` grew to 0x9E0000 - 0x10000, so
  the UEFI loader allocates ~10 MB; BIOS never touches the browser area.
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
The commented source is canonical. (`nocomments/` was last regenerated before the media
foundation; it was left alone on the `media/taskmgr` branch so parallel branches merge
cleanly - run `python tools/strip_comments.py` once after merging them.)

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
- **No Wi-Fi** (it would need a USB stack, chip firmware, 802.11 and WPA2) and no USB
  network adapters except through the UEFI firmware driver. The RTL8168 and I217/I219
  paths have not been run on real hardware; on such PCs the firmware driver is the safer
  route (enable "Network Stack" in the firmware setup).
- **Networking** uses one card at a time, one ARP cache, no IP fragmentation, and a TCP client
  that assumes in-order, lossless delivery and retransmits nothing but its SYN (3 tries) —
  fine behind QEMU's SLIRP, which does the real TCP; fragile on a real lossy network. Downloads are limited to the
  512 KB package buffer; saved files to 4 KB (the MOOSFS limit).
- **GUI apps are deliberately simple**: the editor is append/backspace/enter (no mid-line
  cursor). One window per app.
- **Browser limits**: no CSS (beyond a few inline properties: display/visibility, colour,
  bold, italic, centring), no JavaScript, no images (alt text shown), no cookies, GET forms
  only, no text selection/copy, HTTP/1.0 with `User-Agent: MOOS`. Pages are cut at the
  512 KB download buffer, 24,576 display items and 512 open elements. Tables are lined up
  only when simple (no nested tables/blocks in cells, at most 16 columns, fits the width);
  otherwise cells flow one after another. Characters outside CP437 show as a small box.
  Sites that need ECDSA certificates are refused (TLS limits above). Fetching blocks the
  desktop (the status line says "Loading ..." first).
- **The mouse comes from the firmware**: `efi_ptrinit64` connects all drivers, then polls
  every Absolute Pointer (tablets/touch) and Simple Pointer (USB/PS/2 mice) handle. The
  console handle's merged virtual device is polled but not counted (it exists even with no
  mouse). QEMU's OVMF has **no mouse driver at all** (no UsbMouseDxe/Ps2MouseDxe/tablet), so
  the relative-mouse path was tested with a temporary scripted fake Simple Pointer (moved
  to the Settings button and clicked it). Not yet confirmed with a real mouse on hardware.
  `screentest.py` has `@mouse=DX,DY`, `@click` and `@mon=CMD` for firmware that has one,
  and **`@ptr=X,Y,B` / `@wheel=N`**, which write MOOS's own `mouse_x/y/btn/wheel` through
  QEMU's gdbstub (addresses from a NASM map of the kernel), so the window manager and the
  browser can be driven in QEMU: e.g. `@ptr=400,164,1 @ptr=800,330,1 @ptr=800,330,0` drags
  a title bar. The wheel code (Z of both pointer kinds) is untested on hardware.
- **Drawing**: the desktop redraws fully on keys, clicks, drags (every mouse step while
  moving/resizing a window), hover changes over links, and clock ticks; plain mouse moves
  just restore/redraw the cursor area (`gfx_copy_rect`, `gfx_present_rect`). An app whose
  window is on top can ask for just its content box (`gui_content_dirty`, `gui_dirty` bit
  4; the Task Manager does once a second). Smooth in QEMU at 1280x800; a dirty-rectangle
  scheme would make dragging cheaper. Measured in QEMU without KVM (TCG, 1280x800): idle
  desktop 0.1% busy, Task Manager on top 0.5-0.9%, Task Manager behind another window (a
  full-screen redraw each second) 1.3-1.9%. Attribution checks: a 1,000,000-step script in
  the Terminal showed Terminal 89.9% / desktop 3.4% / idle 6.2% for its stretch; a 400 KB
  page typed into the Browser's address bar showed Browser 93.3% and 200 KB/s in for 2 s.
- **MP4 demuxer limits** (`src/mp4.asm`): plays the first H.264 (avc1/avc3) and the first
  AAC track; fragmented MP4 (moof, as in DASH) is refused (-3); edit lists: leading empty
  edits and the first real edit's start only (later edits and edit rates are ignored);
  files and boxes must be under 4 GB (64-bit sizes are read, but only below 4 GB); sample
  times are 32-bit in the track's time scale. HE-AAC is recognised (the output rate is
  reported) but whether it plays is up to the AAC decoder.
- **JSON limits** (`src/json.asm`): UTF-8 inside strings is passed through without being
  validated; numbers are kept as text (json_int reads int32 only); nesting is limited to
  1000 levels.
- **Sign-in is light protection**, not real security (simple password hash, no encryption).

## Good next steps

- Confirm the mouse (and wheel) on real PCs.
- Browser: images (PNG/GIF/JPEG decoders + fetching them), a little CSS (at least
  `display`, margins and colours from `<style>`), cookies, POST forms, text selection,
  fetching without blocking the desktop, a page cache for Back.
- A fuller GUI text editor (cursor movement, selection) reusing `src/editor.asm` logic.
- BIOS graphics (VBE) so the desktop runs on old PCs too.
- Confirm the RTL8168 driver on a real board; a virtio-net driver for BIOS-mode VMs.
- ECDSA (P-256/P-384) certificate verification, to reach ECDSA-only sites.
- TCP retransmission and a receive window that tracks free buffer space.
- A larger file system (MOOSFS files are 4 KB), so bigger packages and downloads fit.
