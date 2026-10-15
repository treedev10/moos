; =============================================================================
;  MOOS kernel - entry points, global constants and module list
;
;  One 32-bit kernel for both kinds of PC firmware:
;
;  BIOS   The boot sector (boot.asm) loads the kernel to 0x10000 and jumps to
;         it in 32-bit protected mode. MOOS then drives the hardware itself:
;         VGA text screen, PS/2 keyboard, PIT timer, ATA disks (or the BIOS
;         for other disks).
;
;  UEFI   The loader (efi/loader.asm, BOOTX64.EFI) copies the kernel to
;         wherever the firmware has free memory, adjusts its addresses and
;         starts it in 32-bit "compatibility mode" with the firmware still
;         running. MOOS then uses the firmware's own drivers for keyboard,
;         disks and graphics (see efi.asm), so it works on any UEFI PC.
;
;  The kernel is assembled for address 0x10000. Every address below is
;  written relative to "kbase" so that the UEFI loader can move it.
;
;  Memory layout (offsets from 0x10000 when loaded somewhere else)
;    0x010000  kernel code + data + variables
;    0x090000  top of the kernel stack (grows down)
;    0x0A0000  UEFI: disk transfer buffer (64 KB)    BIOS: VGA/ROM area
;    0x100000  file system directory cache (1 KB)
;    0x101000  file system data cache (32 slots x 4 KB)
;    0x200000  scratch buffer (64 KB) - text being written / copied / edited
;    0x210000  output buffer (60 KB) - text shown by the pager
;    0x220000  network buffers, downloads, HTTPS
;    0x2B0000  TCP receive/send rings, HTTP headers, cookie jar (512 KB)
;
;  Two kernels are built from this source:
;    BIOS  (the boot sector loads it): the text system, in the map above. It
;          has to fit the 256 KB reserved for it, and below the stack.
;    FULL  (inside BOOTX64.EFI, UEFI only): everything, including the
;          desktop, the browser and the media players. It has much more
;          room (see FULL below); big buffers (video, pictures) are asked
;          from the UEFI firmware while MOOS runs (big_alloc, efi.asm).
; =============================================================================
bits 32
%ifndef KORG
  %define KORG 0x10000              ; build.py also assembles at another
%endif                              ; address to find what needs moving
org KORG

%include "src/macros.inc"
%include "src/bootinfo.inc"

%define KV(a) (kbase + ((a) - 0x10000))

%ifdef FULL
; FULL (UEFI) kernel: code + variables may use 0x010000 - 0x400000 (4 MB),
; the stack is below 0x480000; the buffers follow.
STACK_OFF    equ 0x480000
%define STACK_TOP    KV(0x480000)
%define UEFI_BOUNCE  KV(0x480000)    ; disk transfers through the firmware (64K)
BOUNCE_OFF   equ 0x480000
%define FS_DIR       KV(0x500000)
%define FS_DATA      KV(0x501000)
%define SCRATCH      KV(0x600000)
%define OUTBUF       KV(0x610000)
%define NET_BUF      KV(0x620000)    ; NIC DMA buffers + network scratch (64K)
%define PKG_BUF      KV(0x630000)    ; downloads (4M)
%define GUI_BB       KV(0xA30000)    ; GUI back buffer (up to 1280x1024x4 = 5M)
%define NET_RING     KV(0xF30000)    ; NIC receive ring: 32K + wrap room
%define TLS_BASE     KV(0xF40000)    ; HTTPS buffers (128K, see tls.asm)
%define BR_BASE      KV(0xF60000)    ; web browser (2M, see html.asm)
%define NET_STREAM   KV(0x1160000)   ; TCP rings, HTTP, cookies (512K, net_tcp.asm)
KMEM_END     equ 0x11E0000
KERNEL_LIMIT equ 0x400000           ; (build.py checks the kernel fits)
PKG_BUF_SIZE equ 0x400000
%else
; BIOS kernel: the classic map, all below 8 MB
STACK_OFF    equ 0x90000
%define STACK_TOP    KV(0x90000)
%define UEFI_BOUNCE  KV(0xA0000)
BOUNCE_OFF   equ 0xA0000
%define FS_DIR       KV(0x100000)
%define FS_DATA      KV(0x101000)
%define SCRATCH      KV(0x200000)
%define OUTBUF       KV(0x210000)
%define NET_BUF      KV(0x220000)    ; NIC DMA buffers + network scratch (64K)
%define PKG_BUF      KV(0x230000)    ; downloaded package (512K, under KMEM)
%define NET_STREAM   KV(0x2B0000)    ; TCP rings, HTTP, cookies (512K, net_tcp.asm)
%define NET_RING     KV(0x7B0000)    ; NIC receive ring: 32K + wrap room
%define TLS_BASE     KV(0x7C0000)    ; HTTPS buffers (128K, see tls.asm)
KMEM_END     equ 0x7E0000
KERNEL_LIMIT equ 0x80000            ; (below the stack's last 64 KB)
PKG_BUF_SIZE equ 0x80000
%endif
SCRATCH_SIZE equ 0x10000
OUTBUF_SIZE  equ 0xF000
KMEM_SIZE    equ KMEM_END - 0x10000 ; everything above, from kbase

VGA_MEM      equ screen_buf         ; all drawing goes to this copy of the
SCR_COLS     equ 80                 ; screen; screen_present shows it
SCR_ROWS     equ 25
TEXT_ROWS    equ 24                 ; row 24 is the status bar

section .text
section .data
section .bss align=16
bss_start:
section .text

kbase:
    jmp near kernel_entry_bios      ; the BIOS boot sector jumps here
    times 8 - ($ - kbase) db 0x90
kernel_header:                      ; read by the UEFI loader
    db "MOOSKRNL"
    dd kernel_entry_uefi - kbase
    dd bootinfo - kbase
    dd KMEM_SIZE
    dd efi_tick - kbase
    dd uefi_gdt - kbase
    dd UEFI_GDT_MAX
    dd STACK_OFF - 0x10000
    dd bss_end - kbase              ; (for build.py: where the variables end)
    dd KERNEL_LIMIT - 0x10000       ; (... and how far they may go)

; ---------------------------------------------------------------- BIOS start
kernel_entry_bios:
    cli
    cld
    mov esp, STACK_TOP
    call zero_bss
    mov dword [bootinfo + BI.platform], PLATFORM_BIOS
    mov dword [bootinfo + BI.kbase], kbase
    movzx eax, byte [0x500]         ; values left by the boot sector
    mov [bootinfo + BI.drive], eax
    mov eax, [0x508]
    mov [bootinfo + BI.part_lba], eax
    movzx eax, word [0x502]         ; KB between 1 MB and 16 MB
    movzx edx, word [0x504]         ; 64 KB blocks above 16 MB
    shl edx, 6
    add eax, edx
    jz .no_ram
    add eax, 1024
.no_ram:
    mov [bootinfo + BI.ram_kb], eax
    call vga_init
    call show_banner
    call idt_init                   ; GDT, IDT, PIC remap, 100 Hz timer
    sti
    call kbd_init
    PRINTF `\x01g[ OK ]\x01n Started by the PC BIOS - 32-bit protected mode\n`
    PRINTF `\x01g[ OK ]\x01n VGA text screen, PS/2 keyboard, 100 Hz timer\n`
    jmp kernel_common

; ---------------------------------------------------------------- UEFI start
; Entered from efi/loader.asm in 32-bit compatibility mode: CS, DS, ES, SS
; and ESP are set up, interrupts are on and belong to the firmware.
kernel_entry_uefi:
    cld
    sti                             ; the firmware needs its interrupts
    call zero_bss
    call vga_init
    call show_banner
    call efi_firmware_name
    PRINTF `\x01g[ OK ]\x01n Started by UEFI firmware (%s)\n`, esi
    PRINTF `\x01g[ OK ]\x01n Graphics %dx%d, keyboard and timer through the firmware\n`, dword [bootinfo + BI.fb_width], dword [bootinfo + BI.fb_height]

kernel_common:
    call cookie_clear               ; (the jar's memory is not zeroed)
    call fs_init
    call clk_init
    call signin_maybe
    call shell_run
.hang:
    hlt
    jmp .hang

; zero_bss: clear the kernel's variables (nobody did it for us)
zero_bss:
    push eax
    push ecx
    push edi
    mov edi, bss_start
    mov ecx, bss_end
    sub ecx, edi
    xor eax, eax
    rep stosb
    pop edi
    pop ecx
    pop eax
    ret

%include "src/lib.asm"
%include "src/bios.asm"               ; must stay in the first 64 KB
%include "src/efi.asm"
%include "src/vga.asm"
%include "src/idt.asm"
%include "src/kbd.asm"
%include "src/rtc.asm"
%include "src/ata.asm"
%include "src/fs.asm"
%include "src/net.asm"
%include "src/crypto.asm"
%include "src/sha512.asm"
%include "src/aes.asm"
%include "src/x25519.asm"
%include "src/rsa.asm"
%include "src/selftest.asm"
%include "src/tls.asm"
%include "src/x509.asm"
%include "src/url.asm"
%include "src/readline.asm"
%include "src/pager.asm"
%include "src/shell.asm"
%include "src/cmd_files.asm"
%include "src/cmd_system.asm"
%include "src/cmd_fetch.asm"
%include "src/cmd_net.asm"
%include "src/cmd_clock.asm"
%include "src/cmd_apt.asm"
%include "src/cmd_login.asm"
%include "src/script.asm"
%ifdef FULL
%include "src/gfx.asm"
%include "src/gui.asm"
%include "src/mp4.asm"                ; MP4 demuxer (self-contained module)
%include "src/json.asm"               ; JSON tokenizer (self-contained module)
%include "src/aac.asm"                ; AAC-LC audio decoder (self-contained module)
%include "src/sound.asm"              ; sound cards (HDA, AC'97)
%include "src/h264.asm"               ; H.264 video decoder (module)
%include "src/jpeg.asm"               ; JPEG picture decoder (module)
%include "src/inflate.asm"            ; DEFLATE / zlib / gzip decompressor (module)
%include "src/png.asm"                ; PNG picture decoder (module)
section .text
%else
%include "src/lite.asm"               ; (the BIOS kernel has no desktop)
%endif
%include "src/calc.asm"
%include "src/editor.asm"
%include "src/installer.asm"
%include "src/acpi.asm"
%include "src/manpages.asm"

section .data
align 8
bootinfo:   times BI_size db 0
UEFI_GDT_MAX equ 256
align 16
uefi_gdt:   times UEFI_GDT_MAX db 0
font_8x16:  incbin "src/font8x16.bin"
mbr_template:
            incbin "build/boot.bin"     ; for the installer
kernel_image_end:

section .bss
alignb 4
bss_end:
