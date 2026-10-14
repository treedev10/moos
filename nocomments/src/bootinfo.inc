PLATFORM_BIOS   equ 0
PLATFORM_UEFI   equ 1

KERNEL_ORG      equ 0x10000

struc KH
    .magic      resb 8
    .entry      resd 1
    .bootinfo   resd 1
    .memsize    resd 1
    .tick       resd 1
    .gdt        resd 1
    .gdtmax     resd 1
    .stack      resd 1
    .bssend     resd 1
    .limit      resd 1
endstruc

struc BI
    .platform   resd 1
    .drive      resd 1
    .part_lba   resd 1
    .ram_kb     resd 1
    .cs64       resd 1
    .kbase      resd 1
    .fb_width   resd 1
    .fb_height  resd 1
    .fb_pitch   resd 1
    .fb_format  resd 1
    .fb_rmask   resd 1
    .fb_gmask   resd 1
    .fb_bmask   resd 1
    .fw_rev     resd 1
    .fb_base    resq 1
    .systab     resq 1
    .bs         resq 1
    .rs         resq 1
    .conin      resq 1
    .blockio    resq 1
    .gop        resq 1
    .image      resq 1
    .esp_path   resq 1
    .fw_vendor  resq 1
    .wait_key   resq 1
    .wait_tick  resq 1
    .tick_event resq 1
endstruc
