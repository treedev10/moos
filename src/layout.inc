; =============================================================================
;  layout.inc - where things are on a MOOS disk (build.py uses the same
;  numbers). Sectors are 512 bytes.
;
;    sector 0               master boot record: BIOS boot code + partition
;                           table with one partition (type 0xEF = EFI
;                           system partition, marked active)
;    sectors 1 .. 2047      empty
;    sector 2048 ...        the MOOS partition (FAT16, 4 MB):
;        +0                 FAT boot sector, OEM name "MOOS"
;        +8   .. +519       the kernel, for BIOS PCs
;        +528 .. +791       MOOSFS - your files
;        +1024 ...          FAT tables and files: \EFI\BOOT\BOOTX64.EFI
;                           (the UEFI loader, with its own copy of the
;                           kernel inside)
; =============================================================================
%ifndef LAYOUT_INC
%define LAYOUT_INC

PART_START          equ 2048            ; first sector of the partition
PART_SECTORS        equ 8192            ; its size
PART_KERNEL_LBA     equ 8               ; inside the partition
PART_KERNEL_SECTS   equ 512             ; room for the kernel (256 KB)
PART_FS_LBA         equ 528             ; MOOSFS header
PART_FS_END         equ 792             ; first sector after MOOSFS
PART_RESERVED       equ 1024            ; FAT "reserved sectors"
MOOS_DISK_SECTORS   equ PART_START + PART_SECTORS

%endif
