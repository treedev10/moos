# Installing MOOS

MOOS ships as a single 5 MB disk image, `build/moos.img`, that starts on **both kinds of PC**:

- **Modern PCs with UEFI firmware.** Practically every PC since about 2012. Legacy/CSM mode is **not**
  needed. The firmware starts `\EFI\BOOT\BOOTX64.EFI` from the image's EFI system partition. MOOS then
  draws on the graphics screen and uses the firmware's drivers, so USB keyboards, NVMe/SATA/USB disks
  and any graphics card work.
- **Old PCs with a BIOS.** The image's boot sector starts MOOS in the classic VGA text mode.

The usual way to install:

1. Write `moos.img` to a USB stick.
2. Start the PC from the stick.
3. Type **`install`** and pick the PC's disk.

That's it. Inside MOOS, `man install` explains the installer.

| Option | Good for |
|---|---|
| [1. QEMU](#1-qemu-quickest) | trying MOOS in a window on this computer |
| [2. Virtual machine](#2-virtual-machines) | VirtualBox, VMware, Hyper-V (BIOS or UEFI) |
| [3. USB stick](#3-usb-stick-real-pc) | running MOOS on any real PC |
| [4. Install to the PC's disk](#4-install-onto-the-pcs-disk) | a PC that starts MOOS by itself |

## What a real PC needs

- **An x86 PC** with 64-bit UEFI firmware, or a classic BIOS. 32-bit-only UEFI tablets are not
  supported.
- **Secure Boot turned off** in the firmware setup. MOOS is not signed by Microsoft, so a PC with
  Secure Boot on refuses to start it. Nothing else needs changing; CSM/Legacy boot can stay off.
- **A disk of at least 5 MB** (any USB stick or SSD) with 512-byte sectors.

## Before you start: build MOOS

You need **Python 3**, **NASM** and, for testing, **QEMU** on the computer you build on.

| System | Install the tools |
|---|---|
| Windows | `winget install NASM.NASM` and `winget install SoftwareFreedomConservancy.QEMU` (already done on this PC) |
| Ubuntu / Debian | `sudo apt install nasm qemu-system-x86 qemu-utils ovmf python3` |
| macOS | `brew install nasm qemu python` |

Then, in the MOOS folder:

```bash
python build.py
```

This creates `build/moos.img`. Rebuilding keeps the files you saved inside it. `python build.py fresh`
starts with an empty disk.

## 1. QEMU (quickest)

| | BIOS PC | UEFI PC |
|---|---|---|
| Windows | double-click `run.bat` | double-click `run-uefi.bat` |
| any system | `python build.py run` | `python build.py uefi` |

## 2. Virtual machines

Create the virtual disks:

```bash
python build.py vm
```

| File | For |
|---|---|
| `build/moos.vdi` | VirtualBox |
| `build/moos.vmdk` | VMware Workstation / Player / Fusion |
| `build/moos.vhd` | Hyper-V generation 1 |
| `build/moos.vhdx` | Hyper-V generation 2 |

**VirtualBox:**
1. Create a new machine. Type: **Other**; version: **Other/Unknown (64-bit)**.
2. Give it 128 MB of memory.
3. Choose **Use an existing virtual hard disk file** and pick `moos.vdi`.
4. Under *Settings > System*, *Enable EFI* may be on or off; both work.
5. `shutdown` powers the VM off.

**VMware:**
1. Create a new VM and choose **I will install the operating system later**. Guest OS: **Other
   64-bit**.
2. Replace the wizard's disk with `moos.vmdk`, as an IDE or SATA disk. Firmware: BIOS or UEFI.
3. Turn off Secure Boot if VMware turned it on.

**Hyper-V:**
1. Copy the disk to a local folder such as `C:\VMs\`. Hyper-V can refuse disks inside OneDrive.
2. **Generation 2:** use `moos.vhdx`. Under *Security*, **turn off Secure Boot**.
3. **Generation 1:** use `moos.vhd` on IDE controller 0.
4. Either way, give it 128 MB of memory with Dynamic Memory off.

**Updating a VM:** power the VM off and run `python build.py vm` again. MOOS is updated inside the VM
disks, the files saved in each VM are kept, and the VirtualBox disk keeps its ID.

## 3. USB stick (real PC)

> **Warning:** everything on the USB stick is erased.

### Write the stick

- **Windows: Rufus** ([rufus.ie](https://rufus.ie)).
  1. Choose the stick under *Device*. Check the name and size carefully.
  2. Click *SELECT* and pick `build/moos.img`.
  3. Click *START*. If Rufus asks, choose **DD Image mode**.
- **Any system: balenaEtcher** ([etcher.balena.io](https://etcher.balena.io)): *Flash from file* >
  `moos.img` > *Select target* > *Flash*.
- **Linux:** find the stick with `lsblk` (e.g. `/dev/sdb`, not a partition like `/dev/sdb1`), then run:
  ```bash
  sudo dd if=build/moos.img of=/dev/sdX bs=1M conv=fsync
  ```
- **macOS:** find the stick with `diskutil list`, then run:
  ```bash
  diskutil unmountDisk /dev/diskN
  sudo dd if=build/moos.img of=/dev/rdiskN bs=1m
  ```

### Start the PC from the stick

1. Plug the stick in, switch the PC on and press the **boot menu key** while the logo shows. It is
   usually **F12** (Dell, Lenovo, Acer), **F11** (MSI, ASRock), **F8** (ASUS), **F9** (HP) or **Esc**.
2. Pick the USB stick. On UEFI PCs it may be called *UEFI: <stick name>*.
3. If the PC refuses ("Secure Boot violation" or similar), turn **Secure Boot off** in the firmware
   setup (often **Del** or **F2** at power-on).

Files you create are saved on the stick.

## 4. Install onto the PC's disk

> **Warning:** the chosen disk is **completely erased**, including Windows, Linux and all files on it.

1. Start MOOS from the USB stick (above).
2. Type `install`. The installer lists the PC's disks (NVMe SSD, SATA, USB, ...) with their sizes. The
   stick MOOS is running from is marked and cannot be chosen.
3. Type the disk's number, then type `ERASE` to confirm, then answer whether your files should be
   copied too.
4. When it says **Done!**, take the stick out and type `reboot`.

If the PC does not start MOOS by itself, choose the disk in the boot menu, or make it the first boot
device in the firmware setup. MOOS uses only the first 5 MB of the disk; the rest stays empty.

**Updating an installed MOOS:** start the new version from a USB stick and run `install` again.
Answer *y* to keep your files.

## How MOOS reaches the disk

| PC | Started from | Files are saved through |
|---|---|---|
| UEFI | anything the firmware can start from (USB, NVMe, SATA, eMMC, ...) | the firmware's Block I/O drivers |
| BIOS | IDE/ATA disk | MOOS's own ATA driver |
| BIOS | USB stick, SATA (AHCI) or NVMe disk | the BIOS disk services (INT 13h) |

For safety, MOOS writes only to the disk it started from, and only inside its own partition, unless
you run the installer.

## Troubleshooting

| Problem | What to do |
|---|---|
| "Secure Boot violation", or the stick is ignored | Turn Secure Boot off in the firmware setup. |
| UEFI PC shows nothing from the stick in the boot menu | Rewrite the stick in DD mode (Rufus) or with balenaEtcher. Some firmware lists it only after a restart. |
| Old BIOS PC: `Disk read error - system halted.` | The BIOS could not read the stick, or it is older than about 1998. Try another port or stick. |
| Keyboard does nothing (BIOS PC) | Enable "USB legacy support" in the setup, or use a PS/2 keyboard. On UEFI PCs every keyboard works. |
| Installer does not list a disk | The firmware has no driver for it, or the disk is too small or uses 4096-byte sectors. |
| Installed disk does not start | Choose it in the boot menu; check Secure Boot is off. On BIOS PCs, check the disk comes first in the boot order. |
| `[WARN] Disk: ... RAM only` | MOOS could not reach the disk it started from. Files are lost at power-off. |
| Clock is wrong | MOOS shows the PC's hardware clock; set it in the firmware setup. |
| VirtualBox: "UUID ... does not match" | The VM disk was replaced outside `build.py vm`. In *Virtual Media Manager*, release and remove `moos.vdi`, then attach it again. |

## Removing MOOS

- **Virtual machine:** delete the VM.
- **USB stick:** reformat it. On Windows: Disk Management > *Delete Volume* > *New Simple Volume*, or
  `diskpart` > `clean`.
- **Installed disk:** install another operating system over it.

## What was tested

These were tested with MOOS 1.2:

- **QEMU with a BIOS:** IDE, SATA/AHCI and USB-stick boot.
- **QEMU with UEFI (EDK II firmware):** IDE, SATA/AHCI, NVMe and USB-stick boot, plus a USB keyboard.
- **VirtualBox:** BIOS and EFI modes, on this PC's Ryzen CPU.
- **The installer:**
  - UEFI, from a USB stick to an NVMe SSD.
  - BIOS, from a USB stick to an IDE disk.
  - Each installed disk then started on its own, on both BIOS and UEFI.

Not tested here, because they weren't available:

- VMware and Hyper-V.
- Physical PCs.

These use the same standard UEFI and BIOS interfaces, so they are expected to work.
