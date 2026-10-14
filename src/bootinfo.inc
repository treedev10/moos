; =============================================================================
;  bootinfo.inc - what the boot code tells the kernel (shared by the kernel
;  and the UEFI loader in efi/loader.asm)
;
;  BIOS:  the boot sector leaves a few values at 0x500 (drive, memory size,
;         partition start); the kernel copies them into "bootinfo".
;  UEFI:  the loader fills "bootinfo" directly before starting the kernel.
; =============================================================================
PLATFORM_BIOS   equ 0
PLATFORM_UEFI   equ 1

KERNEL_ORG      equ 0x10000         ; address the kernel is assembled for

; ---- the header right after the kernel's first jump (at kernel offset 8)
struc KH
    .magic      resb 8              ; "MOOSKRNL"
    .entry      resd 1              ; UEFI entry point (32-bit), kernel offset
    .bootinfo   resd 1              ; offset of bootinfo
    .memsize    resd 1              ; bytes of memory the kernel needs
    .tick       resd 1              ; 64-bit timer callback, kernel offset
    .gdt        resd 1              ; buffer for the GDT under UEFI
    .gdtmax     resd 1              ; its size
    .stack      resd 1              ; offset of the stack top
    .bssend     resd 1              ; offset of the end of the variables
    .limit      resd 1              ; how far code + variables may go
endstruc

; ---- boot information
struc BI
    .platform   resd 1              ; PLATFORM_BIOS / PLATFORM_UEFI
    .drive      resd 1              ; BIOS: boot drive number
    .part_lba   resd 1              ; BIOS: first sector of the MOOS partition
    .ram_kb     resd 1              ; installed memory in KB (0 = unknown)
    .cs64       resd 1              ; UEFI: firmware's 64-bit code selector
    .kbase      resd 1              ; where the kernel really runs
    .fb_width   resd 1              ; UEFI graphics: pixels
    .fb_height  resd 1
    .fb_pitch   resd 1              ; pixels per scan line
    .fb_format  resd 1              ; 0 RGBX, 1 BGRX, 2 bit mask, 3 Blt only
    .fb_rmask   resd 1
    .fb_gmask   resd 1
    .fb_bmask   resd 1
    .fw_rev     resd 1              ; UEFI firmware revision
    .fb_base    resq 1              ; (the rest are 64-bit UEFI pointers)
    .systab     resq 1
    .bs         resq 1              ; boot services
    .rs         resq 1              ; runtime services
    .conin      resq 1
    .blockio    resq 1              ; Block I/O of the partition MOOS came from
    .gop        resq 1
    .image      resq 1
    .esp_path   resq 1              ; device path of that partition
    .fw_vendor  resq 1
    .wait_key   resq 1              ; events for WaitForEvent: key pressed,
    .wait_tick  resq 1              ;   half-second timer
    .tick_event resq 1              ; 100 Hz timer (counts "ticks")
endstruc
