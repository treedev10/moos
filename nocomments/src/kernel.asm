bits 32
%ifndef KORG
  %define KORG 0x10000
%endif
org KORG

%include "src/macros.inc"
%include "src/bootinfo.inc"

%define KV(a) (kbase + ((a) - 0x10000))

%ifdef FULL

STACK_OFF    equ 0x480000
%define STACK_TOP    KV(0x480000)
%define UEFI_BOUNCE  KV(0x480000)
BOUNCE_OFF   equ 0x480000
%define FS_DIR       KV(0x500000)
%define FS_DATA      KV(0x501000)
%define SCRATCH      KV(0x600000)
%define OUTBUF       KV(0x610000)
%define NET_BUF      KV(0x620000)
%define PKG_BUF      KV(0x630000)
%define GUI_BB       KV(0xA30000)
%define NET_RING     KV(0xF30000)
%define TLS_BASE     KV(0xF40000)
%define BR_BASE      KV(0xF60000)
%define NET_STREAM   KV(0x1160000)
KMEM_END     equ 0x11E0000
KERNEL_LIMIT equ 0x400000
PKG_BUF_SIZE equ 0x400000
%else

STACK_OFF    equ 0x90000
%define STACK_TOP    KV(0x90000)
%define UEFI_BOUNCE  KV(0xA0000)
BOUNCE_OFF   equ 0xA0000
%define FS_DIR       KV(0x100000)
%define FS_DATA      KV(0x101000)
%define SCRATCH      KV(0x200000)
%define OUTBUF       KV(0x210000)
%define NET_BUF      KV(0x220000)
%define PKG_BUF      KV(0x230000)
%define NET_STREAM   KV(0x2B0000)
%define NET_RING     KV(0x7B0000)
%define TLS_BASE     KV(0x7C0000)
KMEM_END     equ 0x7E0000
KERNEL_LIMIT equ 0x80000
PKG_BUF_SIZE equ 0x80000
%endif
SCRATCH_SIZE equ 0x10000
OUTBUF_SIZE  equ 0xF000
KMEM_SIZE    equ KMEM_END - 0x10000

VGA_MEM      equ screen_buf
SCR_COLS     equ 80
SCR_ROWS     equ 25
TEXT_ROWS    equ 24

section .text
section .data
section .bss align=16
bss_start:
section .text

kbase:
    jmp near kernel_entry_bios
    times 8 - ($ - kbase) db 0x90
kernel_header:
    db "MOOSKRNL"
    dd kernel_entry_uefi - kbase
    dd bootinfo - kbase
    dd KMEM_SIZE
    dd efi_tick - kbase
    dd uefi_gdt - kbase
    dd UEFI_GDT_MAX
    dd STACK_OFF - 0x10000
    dd bss_end - kbase
    dd KERNEL_LIMIT - 0x10000

kernel_entry_bios:
    cli
    cld
    mov esp, STACK_TOP
    call zero_bss
    mov dword [bootinfo + BI.platform], PLATFORM_BIOS
    mov dword [bootinfo + BI.kbase], kbase
    movzx eax, byte [0x500]
    mov [bootinfo + BI.drive], eax
    mov eax, [0x508]
    mov [bootinfo + BI.part_lba], eax
    movzx eax, word [0x502]
    movzx edx, word [0x504]
    shl edx, 6
    add eax, edx
    jz .no_ram
    add eax, 1024
.no_ram:
    mov [bootinfo + BI.ram_kb], eax
    call vga_init
    call show_banner
    call idt_init
    sti
    call kbd_init
    PRINTF `\x01g[ OK ]\x01n Started by the PC BIOS - 32-bit protected mode\n`
    PRINTF `\x01g[ OK ]\x01n VGA text screen, PS/2 keyboard, 100 Hz timer\n`
    jmp kernel_common

kernel_entry_uefi:
    cld
    sti
    call zero_bss
    call vga_init
    call show_banner
    call efi_firmware_name
    PRINTF `\x01g[ OK ]\x01n Started by UEFI firmware (%s)\n`, esi
    PRINTF `\x01g[ OK ]\x01n Graphics %dx%d, keyboard and timer through the firmware\n`, dword [bootinfo + BI.fb_width], dword [bootinfo + BI.fb_height]

kernel_common:
    call cookie_clear
    call fs_init
    call clk_init
    call signin_maybe
    call shell_run
.hang:
    hlt
    jmp .hang

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
%include "src/bios.asm"
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
%include "src/mp4.asm"
%include "src/json.asm"
%include "src/aac.asm"
%include "src/sound.asm"
%include "src/h264.asm"
section .text
%else
%include "src/lite.asm"
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
            incbin "build/boot.bin"
kernel_image_end:

section .bss
alignb 4
bss_end:
