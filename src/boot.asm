; =============================================================================
;  MOOS master boot record (512 bytes, loaded by a PC BIOS at 0x7C00)
;  UEFI PCs do not use it - they start \EFI\BOOT\BOOTX64.EFI instead.
;
;  1. sets 80x25 text mode
;  2. finds the MOOS partition in the partition table below and loads the
;     kernel from its reserved sectors to 0x10000
;  3. stores boot info (drive, memory size, partition start) at 0x500
;  4. enables the A20 line, switches to 32-bit protected mode
;  5. jumps to the kernel at 0x10000
;
;  Bytes 440-509 (disk signature and partition table) are filled in by
;  build.py and by the installer.
; =============================================================================
bits 16
org 0x7C00

%include "src/layout.inc"
KERNEL_SECTORS equ PART_KERNEL_SECTS

KERNEL_SEG  equ 0x1000              ; 0x1000:0000 = linear 0x10000
BOOTINFO    equ 0x0500              ; +0 drive, +2 KB 1M-16M, +4 64K blocks
                                    ; >16M, +8 partition start
CHUNK       equ 32                  ; sectors per BIOS read call

start:
    jmp 0x0000:entry                ; normalise CS:IP

entry:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    cld
    mov [BOOTINFO], dl

    mov ax, 0x0003                  ; 80x25 colour text mode (clears screen)
    int 0x10
    mov ax, 0x1003                  ; blink off -> 16 background colours
    xor bx, bx
    int 0x10

    mov si, msg_boot
    call print

    mov ah, 0x41                    ; need INT 13h extensions (LBA reads)
    mov bx, 0x55AA
    mov dl, [BOOTINFO]
    int 0x13
    jc disk_error
    cmp bx, 0xAA55
    jne disk_error

    mov eax, [0x7C00 + 0x1BE + 8]   ; partition 1: first sector
    test eax, eax
    jz disk_error
    mov [BOOTINFO + 8], eax
    add eax, PART_KERNEL_LBA
    mov [dap.lba], eax
    mov cx, KERNEL_SECTORS
.load:
    mov ax, cx
    cmp ax, CHUNK
    jbe .count_ok
    mov ax, CHUNK
.count_ok:
    mov [dap.count], ax
    pusha
    mov si, dap
    mov ah, 0x42
    mov dl, [BOOTINFO]
    int 0x13
    popa
    jc disk_error
    add [dap.lba], ax
    adc word [dap.lba + 2], 0
    shl ax, 5                      ; sectors * 512 / 16 = paragraphs
    add [dap.seg], ax
    shr ax, 5
    sub cx, ax
    jnz .load

    ; memory size (INT 15h E801): AX/CX = KB 1M..16M, BX/DX = 64K blocks >16M
    mov ax, 0xE801
    xor bx, bx
    xor cx, cx
    xor dx, dx
    int 0x15
    jc .no_mem
    jcxz .use_ax
    mov ax, cx
    mov bx, dx
.use_ax:
    mov [BOOTINFO+2], ax
    mov [BOOTINFO+4], bx
.no_mem:

    mov ax, 0x2401                  ; A20 via BIOS ...
    int 0x15
    in al, 0x92                     ; ... and via the "fast A20" port
    or al, 2
    and al, 0xFE
    out 0x92, al

    cli
    lgdt [gdt_desc]
    mov eax, cr0
    or eax, 1
    mov cr0, eax
    jmp 0x08:pmode

bits 32
pmode:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000
    jmp 0x10000

bits 16
disk_error:
    mov si, msg_err
    call print
.halt:
    cli
    hlt
    jmp .halt

print:                              ; SI = zero-terminated string
    lodsb
    test al, al
    jz .done
    mov ah, 0x0E
    xor bx, bx
    int 0x10
    jmp print
.done:
    ret

align 8
gdt:
    dq 0                            ; null descriptor
    dq 0x00CF9A000000FFFF           ; 0x08: code, base 0, limit 4 GB
    dq 0x00CF92000000FFFF           ; 0x10: data, base 0, limit 4 GB
gdt_desc:
    dw gdt_desc - gdt - 1
    dd gdt

dap:                                ; disk address packet for INT 13h AH=42h
    db 0x10, 0
.count: dw 0
.off:   dw 0
.seg:   dw KERNEL_SEG
.lba:   dd 1
        dd 0

msg_boot db "MOOS: loading kernel...", 13, 10, 0
msg_err  db "Disk read error - system halted.", 0

times 440-($-$$) db 0                ; (an error here: the code is too big)
times 70 db 0                       ; disk signature + partition table
dw 0xAA55
