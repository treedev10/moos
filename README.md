# MOOS — Mightily Optimized Operating System

A small operating system written from scratch in x86 assembly. It is **not** Linux, DOS or
anything else: the boot loader, UEFI loader, drivers, file system, networking stack, **HTTPS
(TLS 1.3) and certificate checking**, shell, text editor, package manager, scripting
language, graphical desktop, **web browser**, **video and audio players** and installer are
all original code - down to the H.264, AAC, JPEG, PNG and GIF decoders. The text system (BIOS
kernel), with a full manual for every command, is about **230 KB**; the full system for UEFI
PCs, with the desktop, the browser and the media players, about **420 KB**.

It starts on **modern UEFI PCs**, without legacy/CSM mode, on graphics-only screens with USB
keyboards and NVMe SSDs. It also starts on **old BIOS PCs**, and it can **install itself**
onto a computer's disk.

**New since the first version:** wired networking (DHCP/DNS/TCP), **HTTPS**
with MOOS's own TLS 1.3 and X.509 code, an `apt` package manager that installs **straight from
GitHub** (`apt install /user/repo`), internet clock sync, a `run` scripting language, a
graphical desktop (`gui`) whose windows can be moved, resized, maximized and minimized, a
**web browser** with its own HTML engine, and an optional sign-in screen.

**Newest:**
- **YouTube in the browser:** search, results with thumbnails, and videos that play with picture
  and sound (H.264 + AAC, decoded by MOOS itself) - see [YouTube, video and sound](#youtube-video-and-sound).
- **Pictures and video on web pages:** JPEG, PNG and GIF; `<video>` and `<audio>` with a player
  (control bar, seeking, volume, full screen).
- **Sound** through Intel HD Audio and AC'97 sound cards (`sound`, `sound test`).
- **A Start menu** (Start button, F12 or Ctrl+Esc) and **right-click menus**: right-click the
  desktop to make a new folder or text file, right-click an icon to open, rename or delete it.
  Desktop icons, a **Files** window, and **folders** in the file system and the shell (`cd`,
  `mkdir`, `rmdir`, paths like `docs/notes.txt`).
- **A Task Manager** (F11): CPU use per app, memory, network and frame-rate graphs, End task.
- **`fetch`** (alias `neofetch`): a system summary next to a cow.
- Faster, sturdier networking: POST, Range requests, cookies, streaming downloads, TCP that
  copes with lost and out-of-order packets.

See [handoff.md](handoff.md) for the full picture.

```
moos> help
 MOOS commands - type man <command> for the full manual of any of them

  help     list all commands             man      read a command's manual
  ls       list files                    cat      show what is in a file
  edit     full-screen text editor       write    create or replace a file
  ...
```

## Run it

You need [NASM](https://nasm.us) and [QEMU](https://www.qemu.org); both are installed on this PC.

| | as a BIOS PC | as a UEFI PC |
|---|---|---|
| Windows | double-click `run.bat` | double-click `run-uefi.bat` |
| any OS | `python build.py run` | `python build.py uefi` |

| Command | What it does |
|---|---|
| `python build.py` | build `build/moos.img`, a hybrid BIOS + UEFI disk image |
| `python build.py vm` | also make VirtualBox / VMware / Hyper-V disks |
| `python build.py fresh run` | start with an empty disk (erases files you saved inside MOOS) |

Rebuilding keeps the files you created inside MOOS, unless you use `fresh`.

When it starts, type `man intro` for a five-minute guided tour.

**Putting MOOS on a real PC:** write `build/moos.img` to a USB stick, start the PC from it and type
`install`. Secure Boot must be off. See **[INSTALL.md](INSTALL.md)** for the details, or `man install`
inside MOOS.

## Features

- **Works on UEFI and BIOS PCs.**
  - On UEFI, MOOS uses the firmware's own drivers, so any keyboard (USB or PS/2), any disk the PC can
    start from (USB, NVMe, SATA, eMMC) and any graphics card work.
  - On BIOS PCs it drives the hardware itself.
- **Graphics console:** no VGA text mode needed. On UEFI, MOOS draws the classic 8×16 PC font into
  the framebuffer itself, at double size when the screen is big enough.
- **Installer** (`install`): lists the PC's disks and copies MOOS (and optionally your files) onto the
  one you choose. The disk MOOS runs from is never offered, and you must type `ERASE` to confirm.
  The installed disk starts on both UEFI and BIOS.
- **Full-screen text editor** (`edit <file>`):
  - arrow keys and PgUp/PgDn to move
  - find (Ctrl+F) and go to line (Ctrl+G)
  - cut and paste lines (Ctrl+K / Ctrl+U)
  - save (Ctrl+S)
- **Shell:**
  - line editing and a 16-entry history (Up/Down)
  - Tab completion of commands, manuals and file names
  - "did you mean...?" suggestions for typos
- **Manual for every command** (`man <command>`), plus guides: `man intro`, `man keys`, `man files`,
  `man browser`, `man youtube`, `man tasks`.
- **Persistent file system** (MOOSFS) with **folders**: up to 32 files and folders, 4 KB per file,
  saved the moment you change something. Every file command takes paths (`docs/notes.txt`,
  `../x`, `/top.txt`); `cd`, `mkdir`, `rmdir` and `pwd` work as you would expect. Disks made by
  older versions of MOOS read the same.
- **Proper power-off** through the PC's ACPI tables, on real PCs and virtual machines.
- **Safety:** destructive commands ask first, and MOOS only writes to its own partition (except when
  you run the installer).
- **Status bar** with a live clock, and colour themes.

### Commands

| Files | Tools | Net & system |
|---|---|---|
| `ls` list files and folders | `edit` full-screen editor | `net` connect to the network |
| `cd`, `pwd`, `mkdir`, `rmdir` | `calc` integer calculator | `apt` install packages (GitHub) |
| `cat` show a file | `run` run a MOOS script | `get` download (HTTPS, POST, headers) |
| `write`, `append` | `echo` print / save a line | `nettest` streaming download test |
| `rm` delete (asks first) | `color` colours and themes | `gui` graphical desktop (UEFI) |
| `rename` (also moves), `copy` | `help`, `man` | `sound` sound card, `sound test` (UEFI) |
| `find` search in files | `clear` | `fetch` system summary, `login` optional sign-in |
| `wc`, `hexdump` | `history` | `time`, `clock`, `uptime`, `mem`, `sysinfo` |
| | | `install`, `format`, `reboot`, `shutdown` |

Familiar aliases work too: `nano`, `notepad`, `dir`, `md`, `rd`, `type`, `del`, `mv`, `cp`,
`grep`, `cls`, `date`, `wget`, `curl`, `neofetch`, `exit` and others.

## Networking, packages, scripting, and the desktop

- **Networking** (`net up`): wired Ethernet with DHCP, DNS, UDP, TCP and an HTTP/1.1 client
  — all written from scratch. TCP handles lost and out-of-order packets (SACK, retransmission,
  window updates); HTTP does GET and POST, extra headers, Range requests, chunked bodies,
  redirects and cookies (`net cookies`), and can stream a long download while other things go
  on (what the video player uses). `clock sync` sets the time from the internet.
  - Network cards: on UEFI PCs, the firmware's own network driver, which covers most
    onboard Ethernet. MOOS also has its own drivers for Realtek RTL8111/8168/8169 and
    RTL8139, and Intel PRO/1000 / I217–I219.
  - `net cards` shows what MOOS can see. If no card is found, see `man net`. You may need
    to turn on "Network Stack" in the PC's firmware setup.
  - Wi-Fi is not supported.
- **HTTPS** (`get https://...`): a TLS 1.3 client (X25519, AES-128-GCM, SHA-256/384/512)
  that checks the server's certificate chain against built-in root certificates, the site
  name, the dates, and the server's signature — and refuses the connection if anything is
  wrong. `net selftest` checks the crypto against known answers.
- **Packages from GitHub**: `apt install desktop` installs from this repo's `packages/`
  folder, and `apt install /user/repo` installs the `moos.pkg` from any GitHub repository —
  over checked HTTPS. Publishing a package is just committing a `moos.pkg`; see
  [PACKAGES.md](PACKAGES.md).
- **Scripting** (`run file.ms`): variables, `if/else`, `while`, `print`, and expressions.
- **Desktop** (`apt install desktop`, then `gui`): a plain-colour desktop, a taskbar, a mouse
  (USB or PS/2, wheel and right button included, through the firmware), and overlapping windows
  you can drag, resize from any edge or corner, maximize (button or double-click) and minimize to
  the taskbar — or do all that with the keyboard. UEFI only.
  - **Start menu** (the Start button, F12 or Ctrl+Esc): every app, YouTube, Leave desktop,
    Restart and Shut down.
  - **Desktop icons** for the files and folders in `/desktop`. **Right-click** empty space for
    *New folder* and *New text file* (you type its name straight away), or an icon for *Open*,
    *Rename*, *Delete* and *Properties*. Double-click opens a file in the Text Editor or a folder
    in Files. Keys: arrows, Enter, F2, Delete, Shift+F10.
  - Apps: Terminal, Text Editor, Script IDE, Browser, Settings, **Files** (a folder's contents
    with the same menus) and the **Task Manager** (F11: open windows with CPU % and memory, End
    task, CPU and network graphs, memory by owner, frames per second).
- **Web browser** (`gui browser <address>`, `man browser`): MOOS's own HTML engine parses pages
  (entities, UTF-8, scripts and hidden parts dropped) and lays them out to the window's width —
  headings in larger type, bold/italic/underline, code, lists, tables with aligned columns,
  quotes, preformatted text and links — re-flowing when the window is resized. Back/Forward
  history, redirects, relative links and `#anchors`, a hand pointer over links, Tab to walk
  links, scroll bar and wheel, GET forms (search boxes), plain-text files and `view-source:`,
  over HTTP or checked HTTPS. **Pictures** (JPEG, PNG, GIF, and `data:` pictures) load after
  the page is shown; **`<video>` and `<audio>`** get a player. No JavaScript or style sheets.

## YouTube, video and sound

- **YouTube** (`gui browser youtube.com`, `man youtube`): YouTube's own pages are a JavaScript
  program, so MOOS asks YouTube's API (the one its apps use) and builds plain pages itself: a
  search box, results with thumbnails, channel, length and views, and a watch page with the
  player, the title and the description. Links to YouTube and embedded YouTube videos on other
  pages lead there too. MOOS plays YouTube's basic stream (360p H.264 video with AAC sound in one
  MP4). Newer app details can be put in `yt.cfg` if YouTube changes what its apps must send.
- **The player:** downloads the file in pieces with Range requests (so jumping back is free),
  reads the MP4 index, decodes H.264 video and AAC sound, and keeps the picture in step with the
  sound card. Control bar with play/pause, time, a progress bar (light grey: downloaded; click to
  jump), volume and full screen; keys K (pause), J / L (10 s back / ahead), F (full screen), M
  (mute). On a slow computer it skips pictures rather than fall behind the sound.
- **Decoders, all written for MOOS:** H.264 (Baseline and Main CAVLC, bit-exact against ffmpeg
  on 91 test streams), AAC-LC (within 70 dB of ffmpeg on 87 test streams), MP4 demuxing, JSON,
  JPEG (baseline and progressive), PNG (all colour types, Adam7) with DEFLATE, and GIF.
- **Sound** (`sound`, `sound test`, `sound volume N`): Intel High Definition Audio (most PCs
  since 2005) and AC'97, with the output path found by walking the codec's widgets.

## How it works

One 32-bit kernel serves both kinds of firmware.

- **BIOS:** `boot.asm` loads the kernel and switches to 32-bit protected mode.
- **UEFI:** `efi/loader.asm` (`BOOTX64.EFI`) copies the kernel into free memory and adjusts its
  addresses. `build.py` assembles the kernel twice at different addresses to find the 13,000
  places that need adjusting. The loader then enters the kernel in 32-bit *compatibility mode* while the
  firmware keeps running. For keyboard, disk, clock and power requests, the kernel jumps briefly into
  64-bit code that calls the firmware (`src/efi.asm`).

| Part | File | Notes |
|---|---|---|
| BIOS boot sector | `src/boot.asm` | finds the MOOS partition, loads the kernel, enters protected mode |
| UEFI loader | `efi/loader.asm` | hand-written PE32+ file: GOP graphics, memory, timers, GDT, jump to kernel |
| Kernel entry | `src/kernel.asm` | memory map, BIOS and UEFI start-up, module list |
| Firmware bridge | `src/efi.asm` | 64-bit calls into UEFI: keyboard, Block I/O, clock, reset, disk list, screen drawing |
| BIOS disk access | `src/bios.asm` | drops to real mode to call INT 13h (USB sticks, AHCI disks) |
| Screen | `src/vga.asm` | off-screen 80×25 buffer, shown as VGA text (BIOS) or drawn with the font (UEFI); `kprintf` |
| Interrupts | `src/idt.asm` | GDT/IDT, crash screen, PIC, 100 Hz PIT timer (BIOS) |
| Keyboard | `src/kbd.asm` | PS/2 driver (BIOS), firmware keys (UEFI) |
| Clock | `src/rtc.asm` | CMOS clock (BIOS) or firmware time (UEFI) |
| ATA disks | `src/ata.asm` | ATA PIO driver (BIOS) |
| File system | `src/fs.asm` | MOOSFS in the partition's reserved sectors, cached in RAM, write-through; folders and paths |
| Installer | `src/installer.asm` | disk list, copy, new partition table, verify |
| Power | `src/acpi.asm` | ACPI S5 power-off (FADT + `\_S5` from the DSDT) |
| Line editor, pager, shell | `src/readline.asm`, `src/pager.asm`, `src/shell.asm` | editing keys, history, Tab, typo suggestions |
| Commands | `src/cmd_*.asm`, `src/calc.asm`, `src/editor.asm` | the commands themselves |
| Layout | `src/layout.inc`, `src/bootinfo.inc` | disk layout and boot information shared by all parts |
| Font | `src/font8x16.bin` | the public-domain VGA font (`tools/makefont.py` extracts it from QEMU's VGA BIOS) |
| Graphics, desktop | `src/gfx.asm`, `src/gui.asm`, `src/gui_win.asm`, `src/gui_apps.asm` | back buffer, clipping, sized/styled text, picture blitting; taskbar, cursor; window manager; the apps |
| Start menu, icons, Files | `src/gui_desk.asm`, `src/gui_menu.asm` | desktop icons, Start menu, right-click menus, rename in place, Files app; popup menus and message boxes |
| Task Manager | `src/gui_tasks.asm`, `src/cmd_fetch.asm` | CPU accounting, graphs, End task; the `fetch` command |
| Web browser | `src/html.asm`, `src/browser.asm`, `src/imgcache.asm` | HTML parser, layout engine and painter; the browser app (address bar, history, forms); pictures |
| Video player, YouTube | `src/player.asm`, `src/youtube.asm` | download in Range pieces, A/V sync, controls, full screen; YouTube pages from its JSON API |
| Media modules | `src/h264.asm`, `src/aac.asm`, `src/mp4.asm`, `src/json.asm`, `src/jpeg.asm`, `src/png.asm`, `src/inflate.asm`, `src/gif.asm` | self-contained decoders, also built natively and tested against ffmpeg, Pillow, zlib and Python (`tests/native`) |
| Sound | `src/sound.asm` | Intel HD Audio and AC'97 drivers |
| Networking | `src/net*.asm`, `src/nic_*.asm`, `src/url.asm`, `src/tls.asm`, `src/x509.asm` | Ethernet drivers, IP/TCP, HTTP client and streaming, cookies, TLS 1.3, certificates |
| Manuals | `man/*.txt` | plain text, embedded into the kernel at build time |

The disk layout has two parts:

- **Sector 0:** a master boot record with one partition, active and of type 0xEF (EFI system
  partition).
- **From sector 2048:** a 4 MB FAT16 partition. Its reserved sectors hold the BIOS kernel (+8) and
  MOOSFS (+528). Its FAT area holds `\EFI\BOOT\BOOTX64.EFI`.

## Change it

- **Edit a manual:** change the text in `man/<command>.txt` and rebuild. Lines that start at the left
  edge with a capital letter are shown as yellow headings. Indent body text by 4 spaces and keep lines
  within 79 characters.
- **Add a command:**
  1. Write a handler in one of the `cmd_*.asm` files. It reads `argc` / `argv` / `rest_ptr` and may use
     any register.
  2. Add a `COMMAND` line to the table in `src/shell.asm`.
  3. Add a `MANPAGE` line in `src/manpages.asm` plus a `man/*.txt` file.
- **Test without a window:** `python tools/screentest.py "help\n" @screen` boots a copy of the image
  in headless QEMU, types keys and prints MOOS's screen. Add `--uefi` for a UEFI PC and
  `@png=shot.png` for a real screenshot. `@ptr=X,Y,BUTTON` moves MOOS's own mouse (QEMU's UEFI
  firmware has no mouse driver), so clicks and drags on the desktop can be tested too (button 2 is
  the right button). `--audio out.wav` records what MOOS plays.
- **Test suites:** `tests/native` (the decoders against reference tools: `python3
  tests/native/run.py h264` and so on), `tests/net/run.py` (the network stack against local
  servers), and `tests/youtube` (a stand-in YouTube server, `mock.py`, and an end-to-end test,
  `e2e.py`, that plays a video in QEMU and checks the picture and the recorded sound).

## Limits (by design, to stay tiny)

- 32 files and folders in all, 4 KB per file.
- Video: MP4 with H.264 (Baseline or Main without CABAC) and AAC; YouTube's basic 360p stream.
  No JavaScript or style sheets in the browser.
- Whole numbers only in `calc` (32-bit signed).
- The editor has no undo, and a command line fits on one screen row.
- 80×25 characters; US keyboard layout on BIOS PCs.
- UEFI PCs need Secure Boot turned off (MOOS is not signed). 32-bit-only UEFI is not supported.
