#!/usr/bin/env python3
"""
MOOS build script.

    python build.py            build build/moos.img (starts on BIOS and UEFI PCs)
    python build.py run        build, then start it in QEMU as an old BIOS PC
    python build.py uefi       build, then start it in QEMU as a modern UEFI PC
    python build.py fresh ...  start with an empty disk (erases saved files)
    python build.py vm         also make virtual machine disks:
                               moos.vdi (VirtualBox), moos.vmdk (VMware),
                               moos.vhd (Hyper-V generation 1),
                               moos.vhdx (Hyper-V generation 2)

Needs NASM (assembler) and, for "run", "uefi" and "vm", QEMU. Your saved
files inside the disk image are kept when you rebuild, unless you use
"fresh". See INSTALL.md for installing MOOS on a virtual machine or a PC.
"""
import os
import re
import shutil
import struct
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(ROOT, "build")
IMAGE = os.path.join(BUILD, "moos.img")
OLD_IMAGE = os.path.join(BUILD, "novaos.img")   # name used before the rename

SECTOR = 512
FS_MAGICS = (b"MOOSFS01", b"NOVAFS01")       # current and older signature
OLD_FS = (256, 520)                           # MOOSFS position in MOOS 1.0/1.1
KERNEL_ORG = 0x10000
KERNEL_ORG2 = 0x01010000                      # second assembly, for relocations
VDI_UUID = slice(0x188, 0x198)                # image UUID inside a .vdi header


def read_layout():
    """The disk layout constants from src/layout.inc (one source of truth)."""
    text = open(os.path.join(ROOT, "src", "layout.inc")).read()
    values = {}
    for name, expr in re.findall(r"^(\w+)\s+equ\s+([^;\n]+)", text, re.M):
        values[name] = eval(expr.strip(), {}, dict(values))
    return values


L = read_layout()
PART_START = L["PART_START"]
PART_SECTORS = L["PART_SECTORS"]
DISK_SECTORS = L["MOOS_DISK_SECTORS"]
FS_FIRST, FS_END = L["PART_FS_LBA"], L["PART_FS_END"]


# ------------------------------------------------------------------- tools
def find_tool(names, extra_dirs):
    for name in names:
        path = shutil.which(name)
        if path:
            return path
    for d in extra_dirs:
        for name in names:
            for candidate in (os.path.join(d, name), os.path.join(d, name + ".exe")):
                if os.path.isfile(candidate):
                    return candidate
    return None


def nasm_path():
    local = os.environ.get("LOCALAPPDATA", "")
    path = find_tool(["nasm"], [os.path.join(local, "bin", "NASM"),
                                r"C:\Program Files\NASM", r"C:\Program Files (x86)\NASM"])
    if not path:
        sys.exit("error: NASM not found. Install it (Windows: winget install NASM.NASM, "
                 "Linux: apt install nasm, macOS: brew install nasm).")
    return path


def qemu_path():
    path = find_tool(["qemu-system-x86_64", "qemu-system-i386"],
                     [r"C:\Program Files\qemu", r"C:\Program Files (x86)\qemu"])
    if not path:
        sys.exit("error: QEMU not found. Install it (Windows: winget install "
                 "SoftwareFreedomConservancy.QEMU, Linux: apt install qemu-system-x86).")
    return path


def qemu_img_path():
    qemu = qemu_path()
    path = os.path.join(os.path.dirname(qemu), "qemu-img" + (".exe" if qemu.endswith(".exe") else ""))
    if not os.path.isfile(path):
        path = shutil.which("qemu-img")
    if not path:
        sys.exit("error: qemu-img not found (it comes with QEMU).")
    return path


def ovmf_paths():
    """UEFI firmware for QEMU (comes with QEMU): code, and a writable copy of
    the settings store."""
    qemu_dir = os.path.dirname(qemu_path())
    for share in (os.path.join(qemu_dir, "share"), "/usr/share/qemu", "/usr/share/OVMF",
                  "/opt/homebrew/share/qemu", "/usr/local/share/qemu"):
        # QEMU's own names, then the Linux distributions' (Debian/Ubuntu: _4M)
        for code_name, vars_name in (("edk2-x86_64-code.fd", "edk2-i386-vars.fd"),
                                     ("OVMF_CODE.fd", "OVMF_VARS.fd"),
                                     ("OVMF_CODE_4M.fd", "OVMF_VARS_4M.fd")):
            code = os.path.join(share, code_name)
            vars_src = os.path.join(share, vars_name)
            if os.path.isfile(code):
                break
        if os.path.isfile(code):
            if not os.path.isfile(vars_src):
                vars_src = os.path.join(share, "OVMF_VARS.fd")
            vars_copy = os.path.join(BUILD, "uefi-vars.fd")
            if not os.path.isfile(vars_copy):
                shutil.copy(vars_src, vars_copy)
            return code, vars_copy
    sys.exit("error: no UEFI firmware for QEMU found (edk2-x86_64-code.fd / OVMF_CODE.fd)")


def assemble(nasm, source, output, defines=()):
    cmd = [nasm, "-f", "bin", "-w-error=label-redef-late", source, "-o", output] + \
        ["-D" + d for d in defines]
    result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if result.stdout or result.stderr:
        print((result.stdout + result.stderr).rstrip())
    if result.returncode != 0:
        sys.exit("error: assembling %s failed" % source)
    return open(os.path.join(ROOT, output), "rb").read()


# ------------------------------------------------------------- relocations
def find_relocations(a, b, delta):
    """Offsets of the 32-bit addresses in kernel image a (built for
    KERNEL_ORG) that differ by delta in image b (built elsewhere)."""
    if len(a) != len(b):
        sys.exit("error: the kernel changes size when moved - cannot relocate it")
    relocs = []
    i = 0
    while i < len(a):
        if i + 4 <= len(a):
            va = struct.unpack_from("<I", a, i)[0]
            vb = struct.unpack_from("<I", b, i)[0]
            if va != vb and (va + delta) & 0xFFFFFFFF == vb:
                relocs.append(i)
                i += 4
                continue
        if a[i] != b[i]:
            sys.exit("error: kernel byte %#x depends on its address in an unsupported way" % i)
        i += 1
    return relocs


# ------------------------------------------------------------------ FAT16
def fat_name(name):
    base, _, ext = name.partition(".")
    return (base.upper().ljust(8) + ext.upper().ljust(3)).encode("ascii")


def fat_entry(name11, attr, cluster, size, stamp):
    date, tm = stamp
    e = bytearray(32)
    e[0:11] = name11
    e[11] = attr
    # created time/date, accessed date, cluster high, written time/date,
    # first cluster, size
    struct.pack_into("<HHHHHHHI", e, 14, tm, date, date, 0, tm, date, cluster, size)
    return bytes(e)


def make_fat16(total, reserved, hidden, files, reserved_data):
    """A FAT16 partition image. files: {"EFI/BOOT/BOOTX64.EFI": bytes}.
    reserved_data: {sector: bytes} copied into the reserved sectors."""
    spc, root_entries = 1, 512
    root_secs = root_entries * 32 // SECTOR
    fat_secs = 1
    while True:
        clusters = (total - reserved - 2 * fat_secs - root_secs) // spc
        need = ((clusters + 2) * 2 + SECTOR - 1) // SECTOR
        if need <= fat_secs:
            break
        fat_secs = need
    assert 4085 <= clusters < 65525, "not a FAT16 size"
    t = time.localtime()
    stamp = (((t.tm_year - 1980) << 9) | (t.tm_mon << 5) | t.tm_mday,
             (t.tm_hour << 11) | (t.tm_min << 5) | (t.tm_sec // 2))
    img = bytearray(total * SECTOR)

    vbr = bytearray(SECTOR)                       # FAT boot sector
    vbr[0:3] = b"\xEB\x3C\x90"
    vbr[3:11] = b"MOOS1.2 "                       # the kernel checks "MOOS"
    struct.pack_into("<HBHBHHBHHHII", vbr, 11, SECTOR, spc, reserved, 2, root_entries,
                     total if total < 65536 else 0, 0xF8, fat_secs, 63, 255, hidden,
                     total if total >= 65536 else 0)
    vbr[36], vbr[38] = 0x80, 0x29
    struct.pack_into("<I", vbr, 39, int(time.time()) & 0xFFFFFFFF)
    vbr[43:54] = b"MOOS       "
    vbr[54:62] = b"FAT16   "
    vbr[62:64] = b"\xEB\xFE"                      # not meant to be started
    vbr[510:512] = b"\x55\xAA"
    img[0:SECTOR] = vbr
    for sector, data in reserved_data.items():
        img[sector * SECTOR: sector * SECTOR + len(data)] = data

    fat = [0] * (clusters + 2)
    fat[0], fat[1] = 0xFFF8, 0xFFFF
    data_start = reserved + 2 * fat_secs + root_secs
    next_free = [2]

    def alloc(nbytes):
        count = max(1, (nbytes + SECTOR * spc - 1) // (SECTOR * spc))
        first = next_free[0]
        for c in range(first, first + count):
            fat[c] = c + 1
        fat[first + count - 1] = 0xFFFF
        next_free[0] += count
        return first

    def put(cluster, data):
        off = (data_start + (cluster - 2) * spc) * SECTOR
        img[off:off + len(data)] = data

    def build_dir(path, parent_cluster, own_cluster):
        """Directory listing for path (entries for its children)."""
        names = sorted({f[len(path):].split("/")[0] for f in files if f.startswith(path)})
        entries = []
        if own_cluster:
            entries.append(fat_entry(b".          ", 0x10, own_cluster, 0, stamp))
            entries.append(fat_entry(b"..         ", 0x10, parent_cluster, 0, stamp))
        for name in names:
            full = path + name
            if full in files:
                data = files[full]
                c = alloc(len(data))
                put(c, data)
                entries.append(fat_entry(fat_name(name), 0x20, c, len(data), stamp))
            else:
                c = alloc(SECTOR)
                put(c, build_dir(full + "/", own_cluster, c))
                entries.append(fat_entry(fat_name(name), 0x10, c, 0, stamp))
        return b"".join(entries)

    root = fat_entry(b"MOOS       ", 0x08, 0, 0, stamp) + build_dir("", 0, 0)
    root_off = (reserved + 2 * fat_secs) * SECTOR
    img[root_off:root_off + len(root)] = root
    fat_bytes = b"".join(struct.pack("<H", v) for v in fat)
    for n in range(2):
        off = (reserved + n * fat_secs) * SECTOR
        img[off:off + len(fat_bytes)] = fat_bytes
    return img


def chs(lba):
    c, rest = divmod(lba, 255 * 63)
    h, s = divmod(rest, 63)
    if c > 1023:
        return bytes([0xFE, 0xFF, 0xFF])
    return bytes([h, (s + 1) | ((c >> 2) & 0xC0), c & 0xFF])


def make_mbr(boot, start, sectors):
    mbr = bytearray(boot)
    struct.pack_into("<I", mbr, 440, int(time.time()) & 0xFFFFFFFF)   # disk signature
    entry = bytes([0x80]) + chs(start) + bytes([0xEF]) + chs(start + sectors - 1) + \
        struct.pack("<II", start, sectors)
    mbr[446:462] = entry
    mbr[510:512] = b"\x55\xAA"
    return mbr


# ------------------------------------------------------- keeping your files
def read_fs_region(raw):
    """The MOOSFS sectors of a MOOS disk image (any version), or None."""
    size = (FS_END - FS_FIRST) * SECTOR
    if len(raw) >= SECTOR:
        start = struct.unpack_from("<I", raw, 446 + 8)[0]
        off = (start + FS_FIRST) * SECTOR
        if start and len(raw) >= off + size and raw[off:off + 8] in FS_MAGICS:
            return raw[off:off + size]
    off = OLD_FS[0] * SECTOR
    if len(raw) >= OLD_FS[1] * SECTOR and raw[off:off + 8] in FS_MAGICS:
        return raw[off:OLD_FS[1] * SECTOR]
    return None


def insert_fs_region(image, region):
    off = (PART_START + FS_FIRST) * SECTOR
    image[off:off + len(region)] = region


# ------------------------------------------------------------------- build
def build(fresh):
    os.makedirs(BUILD, exist_ok=True)
    nasm = nasm_path()
    boot = assemble(nasm, "src/boot.asm", "build/boot.bin")
    assert len(boot) == SECTOR, "the boot sector must be exactly 512 bytes"
    kernel = assemble(nasm, "src/kernel.asm", "build/kernel.bin")
    moved = assemble(nasm, "src/kernel.asm", "build/kernel-moved.bin", ["KORG=%#x" % KERNEL_ORG2])
    os.remove(os.path.join(BUILD, "kernel-moved.bin"))
    relocs = find_relocations(kernel, moved, KERNEL_ORG2 - KERNEL_ORG)
    with open(os.path.join(BUILD, "kernel.rel"), "wb") as f:
        f.write(struct.pack("<I", len(relocs)) + b"".join(struct.pack("<I", r) for r in relocs))
    if len(kernel) > L["PART_KERNEL_SECTS"] * SECTOR:
        sys.exit("error: the kernel is bigger than the room reserved for it")
    efi = assemble(nasm, "efi/loader.asm", "build/BOOTX64.EFI")

    partition = make_fat16(PART_SECTORS, L["PART_RESERVED"], PART_START,
                           {"EFI/BOOT/BOOTX64.EFI": efi},
                           {L["PART_KERNEL_LBA"]: kernel})
    image = bytearray(DISK_SECTORS * SECTOR)
    image[0:SECTOR] = make_mbr(boot, PART_START, PART_SECTORS)
    image[PART_START * SECTOR:] = partition

    kept = False
    previous = IMAGE if os.path.isfile(IMAGE) else OLD_IMAGE
    if not fresh and os.path.isfile(previous):
        region = read_fs_region(open(previous, "rb").read())
        if region:
            insert_fs_region(image, region)
            kept = True
    with open(IMAGE, "wb") as f:
        f.write(image)

    print("MOOS built: %s (%d MB)" % (os.path.relpath(IMAGE, ROOT), len(image) >> 20))
    print("  kernel        %6d bytes (%d addresses adjusted by the UEFI loader)" % (len(kernel), len(relocs)))
    print("  BOOTX64.EFI   %6d bytes (UEFI loader + kernel)" % len(efi))
    print("  starts on     BIOS PCs (boot sector) and UEFI PCs (\\EFI\\BOOT\\BOOTX64.EFI)")
    print("  disk          %s" % ("your saved files were kept" if kept else "empty file system (created on first start)"))


def make_vm_disks():
    """Convert build/moos.img into VM disks. If a VM disk already exists, the
    files saved inside it are carried over, and a .vdi keeps its UUID so the
    VirtualBox VM that uses it keeps working."""
    qemu_img = qemu_img_path()
    targets = [("moos.vdi", "vdi", ["-o", "static=off"], "VirtualBox"),
               ("moos.vmdk", "vmdk", [], "VMware"),
               ("moos.vhd", "vpc", ["-o", "subformat=fixed,force_size=on"], "Hyper-V 1"),
               ("moos.vhdx", "vhdx", [], "Hyper-V 2")]
    base = open(IMAGE, "rb").read()

    def qemu_img_run(args):
        result = subprocess.run([qemu_img] + args, capture_output=True, text=True)
        if result.returncode != 0:
            sys.exit("error: qemu-img %s failed: %s" % (args[0], result.stderr.strip()))

    print("Virtual machine disks:")
    for name, fmt, options, product in targets:
        out = os.path.join(BUILD, name)
        tmp = out + ".tmp"
        image = bytearray(base)
        note, uuid = "new", None
        if os.path.exists(out):
            qemu_img_run(["convert", "-f", fmt, "-O", "raw", out, tmp])
            region = read_fs_region(open(tmp, "rb").read())
            if region:
                insert_fs_region(image, region)
                note = "updated, files inside kept"
            if fmt == "vdi":
                uuid = open(out, "rb").read()[VDI_UUID]
            try:
                os.remove(out)
            except OSError:
                os.remove(tmp)
                sys.exit("error: %s is in use - power off the virtual machine first" % name)
        with open(tmp, "wb") as f:
            f.write(image)
        qemu_img_run(["convert", "-f", "raw", "-O", fmt] + options + [tmp, out])
        os.remove(tmp)
        if uuid:
            with open(out, "r+b") as f:
                f.seek(VDI_UUID.start)
                f.write(uuid)
        print("  %-18s for %-10s (%s)" % (os.path.relpath(out, ROOT), product, note))


def qemu_command(uefi, image=IMAGE, extra=()):
    cmd = [qemu_path(), "-drive", "file=%s,format=raw,index=0,media=disk" % image,
           "-m", "256" if uefi else "32", "-rtc", "base=localtime", "-name", "MOOS",
           "-cpu", "max",
           "-netdev", "user,id=n0",
           "-device", os.environ.get("MOOS_NIC", "rtl8139") + ",netdev=n0",
           "-device", "qemu-xhci", "-device", "usb-tablet"]
    if uefi:
        code, vars_copy = ovmf_paths()
        cmd += ["-drive", "if=pflash,format=raw,readonly=on,file=%s" % code,
                "-drive", "if=pflash,format=raw,file=%s" % vars_copy]
    return cmd + list(extra)


def run(uefi):
    print("Starting QEMU as a %s PC... (close the window or type 'shutdown' to stop)"
          % ("UEFI" if uefi else "BIOS"))
    subprocess.run(qemu_command(uefi))


if __name__ == "__main__":
    args = [a.lower() for a in sys.argv[1:]]
    unknown = [a for a in args if a not in ("run", "uefi", "fresh", "vm")]
    if unknown:
        sys.exit(__doc__)
    build(fresh="fresh" in args)
    if "vm" in args:
        make_vm_disks()
    if "run" in args:
        run(uefi=False)
    elif "uefi" in args:
        run(uefi=True)
