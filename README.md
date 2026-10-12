# MOOS — Mightily Optimized Operating System

A tiny operating system written from scratch in x86 assembly. It is **not** Linux, DOS or
anything else: the boot loader, UEFI loader, drivers, file system, shell, text editor, installer and
all commands are original code. The whole system, including a full manual for every command, is about
**100 KB**.

It starts on **modern UEFI PCs**, without legacy/CSM mode, on graphics-only screens with USB keyboards
and NVMe SSDs. It also starts on **old BIOS PCs**, and it can **install itself** onto a computer's disk.

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
- **Manual for every command** (`man <command>`), plus guides: `man intro`, `man keys`, `man files`.
- **Persistent file system** (MOOSFS): 32 files of up to 4 KB each, saved the moment you change
  something.
- **Proper power-off** through the PC's ACPI tables, on real PCs and virtual machines.
- **Safety:** destructive commands ask first, and MOOS only writes to its own partition (except when
  you run the installer).
- **Status bar** with a live clock, and colour themes.

### Commands

| Files | Text and tools | System |
|---|---|---|
| `ls` list files | `edit` full-screen editor | `time` date and time |
| `cat` show a file | `echo` print / save a line (`>`, `>>`) | `uptime` time since start |
| `write` type a new file | `calc` integer calculator | `mem` memory map, storage |
| `append` add lines | `clear` clear the screen | `sysinfo` firmware, CPU, screen |
| `rm` delete (asks first) | `color` colours and themes | `history` recent commands |
| `rename`, `copy` | `help` command list | `install` install MOOS on a disk |
| `find` search in files | `man` manuals | `format` erase all files |
| `wc` count, `hexdump` raw bytes | | `reboot`, `shutdown` |

Familiar aliases work too: `nano`, `notepad`, `dir`, `type`, `del`, `mv`, `cp`, `grep`, `cls`,
`date`, `exit` and others.

## How it works

One 32-bit kernel serves both kinds of firmware.

- **BIOS:** `boot.asm` loads the kernel and switches to 32-bit protected mode.
- **UEFI:** `efi/loader.asm` (`BOOTX64.EFI`) copies the kernel into free memory and adjusts its
  addresses. `build.py` assembles the kernel twice at different addresses to find the 1,400 places
  that need adjusting. The loader then enters the kernel in 32-bit *compatibility mode* while the
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
| File system | `src/fs.asm` | MOOSFS in the partition's reserved sectors, cached in RAM, write-through |
| Installer | `src/installer.asm` | disk list, copy, new partition table, verify |
| Power | `src/acpi.asm` | ACPI S5 power-off (FADT + `\_S5` from the DSDT) |
| Line editor, pager, shell | `src/readline.asm`, `src/pager.asm`, `src/shell.asm` | editing keys, history, Tab, typo suggestions |
| Commands | `src/cmd_*.asm`, `src/calc.asm`, `src/editor.asm` | the commands themselves |
| Layout | `src/layout.inc`, `src/bootinfo.inc` | disk layout and boot information shared by all parts |
| Font | `src/font8x16.bin` | the public-domain VGA font (`tools/makefont.py` extracts it from QEMU's VGA BIOS) |
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
  `@png=shot.png` for a real screenshot.

## Limits (by design, to stay tiny)

- 32 files, 4 KB each, no folders.
- Whole numbers only in `calc` (32-bit signed).
- The editor has no undo, and a command line fits on one screen row.
- 80×25 characters; US keyboard layout on BIOS PCs.
- UEFI PCs need Secure Boot turned off (MOOS is not signed). 32-bit-only UEFI is not supported.
