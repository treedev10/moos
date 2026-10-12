; =============================================================================
;  bios.asm - disk access through the BIOS (INT 13h) from protected mode
;
;  Used only when MOOS was started by a PC BIOS. MOOS has its own driver for
;  ATA/IDE disks; for anything else - a USB stick, a SATA disk in AHCI mode,
;  an NVMe disk - the BIOS can still read and write it. For each request MOOS
;  briefly switches the CPU back to 16-bit real mode, restores the interrupt
;  setup the BIOS expects, calls INT 13h with a buffer below 1 MB, and then
;  returns to protected mode.
;
;  This code must stay within the first 64 KB of the kernel (it runs with
;  CS = 0x1000 in real mode), so kernel.asm includes it early.
; =============================================================================
BOUNCE_SEG  equ 0x6000                  ; transfer buffer at 0x60000 (64 KB)
BOUNCE      equ BOUNCE_SEG * 16
BIOS_CHUNK  equ 64                      ; sectors per call (32 KB)
RM_STACK    equ 0x7C00
%define REL(x) ((x) - kbase)            ; offset within real-mode segment 0x1000

SEL_CODE16  equ 0x18
SEL_DATA16  equ 0x20

section .text

; bios_int13: run INT 13h with AX = bx_ax, DX = bx_dx, DS:SI = bx_ds:bx_si.
; -> bx_ax = AX afterwards, CF=1 if the BIOS reported an error.
bios_int13:
    pushad
    mov [bx_esp], esp
    cli
    call pic_bios_mode
    jmp SEL_CODE16:REL(.pm16)

bits 16
.pm16:                                  ; 16-bit protected mode
    mov ax, SEL_DATA16
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov eax, cr0
    and eax, 0xFFFFFFFE                 ; protection off
    mov cr0, eax
    jmp 0x1000:REL(.real)
.real:                                  ; real mode
    mov ax, 0x1000
    mov ds, ax
    xor ax, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov sp, RM_STACK
    lidt [REL(rm_idt)]
    sti
    mov ax, [REL(bx_ax)]
    mov dx, [REL(bx_dx)]
    mov si, [REL(bx_si)]
    mov ds, [REL(bx_ds)]
    int 0x13
    mov bx, 0x1000
    mov ds, bx
    mov [REL(bx_ax)], ax
    setc [REL(bx_failed)]
    cli
    mov eax, cr0
    or eax, 1                           ; protection on again
    mov cr0, eax
    jmp dword 0x08:.pm32

bits 32
.pm32:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, [bx_esp]
    lidt [idt_desc]
    call pic_moos_mode
    call kbd_collect                    ; keys pressed during the call
    sti
    bt dword [bx_failed], 0
    popad
    ret

align 4
rm_idt      dw 0x3FF                    ; the BIOS interrupt table at 0
            dd 0
bx_esp      dd 0
bx_failed   dd 0
bx_ax       dw 0
bx_dx       dw 0
bx_si       dw 0
bx_ds       dw 0
align 4
bx_dap:     db 16, 0                    ; INT 13h disk address packet
bx_count    dw 0
            dw 0, BOUNCE_SEG
bx_lba      dd 0, 0

; bios_xfer: EAX = LBA (bits 32-63 in disk_lba_hi), ECX = sectors
; (1..BIOS_CHUNK), BL = 0x42 read / 0x43 write, DL = drive.
; Data is in / goes to BOUNCE. CF=1 on error.
bios_xfer:
    pushad
    mov [bx_lba], eax
    mov eax, [disk_lba_hi]
    mov [bx_lba + 4], eax
    mov [bx_count], cx
    mov byte [bx_ax], 0                 ; AL = 0: write without verify
    mov [bx_ax + 1], bl
    mov byte [bx_dx], dl
    mov word [bx_ds], 0x1000
    mov word [bx_si], REL(bx_dap)
    call bios_int13
    popad
    ret

; bios_rw: EAX = LBA, ECX = count, ESI = buffer, BL = 0x42 / 0x43,
; DL = drive. Moves any number of sectors. CF=1 on error.
bios_rw:
    pushad
.next:
    test ecx, ecx
    jz .ok
    mov ebp, ecx
    cmp ebp, BIOS_CHUNK
    jbe .chunk
    mov ebp, BIOS_CHUNK
.chunk:
    push ecx
    mov ecx, ebp
    shl ecx, 9
    cmp bl, 0x43
    jne .call
    push esi                            ; write: copy the data down first
    mov edi, BOUNCE
    rep movsb
    pop esi
.call:
    mov ecx, ebp
    call bios_xfer
    jc .fail
    shl ecx, 9
    cmp bl, 0x42
    jne .advance
    push esi                            ; read: copy the data up
    mov edi, esi
    mov esi, BOUNCE
    rep movsb
    pop esi
.advance:
    pop ecx
    mov edi, ebp
    shl edi, 9
    add esi, edi
    add eax, ebp
    sub ecx, ebp
    jmp .next
.ok:
    popad
    clc
    ret
.fail:
    pop ecx
    popad
    stc
    ret

; bios_read / bios_write: the boot drive. EAX = LBA, ECX = count,
; EDI (read) / ESI (write) = buffer. CF=1 on error.
bios_read:
    pushad
    mov esi, edi
    mov bl, 0x42
    mov dl, [bootinfo + BI.drive]
    call bios_rw
    popad
    ret

bios_write:
    pushad
    mov bl, 0x43
    mov dl, [bootinfo + BI.drive]
    call bios_rw
    popad
    ret

; bios_drive_info: DL = drive -> CF=0 and the INT 13h AH=48h result at
; BOUNCE (total sectors at +0x10, bytes per sector at +0x18), CF=1 if the
; drive does not exist or does not support LBA.
bios_drive_info:
    pushad
    mov edi, BOUNCE
    mov ecx, 0x42
    xor eax, eax
    rep stosb
    mov word [BOUNCE], 0x42
    mov word [bx_ax], 0x4800
    mov byte [bx_dx], dl
    mov word [bx_ds], BOUNCE_SEG
    mov word [bx_si], 0
    call bios_int13
    popad
    ret

; ------------------------------------------------------------------ disk API
; The file system calls these; they use whichever method fs_init chose.
DISK_NONE   equ 0
DISK_ATA    equ 1
DISK_BIOS   equ 2
DISK_UEFI   equ 3

disk_read:
    cmp byte [disk_mode], DISK_ATA
    je ata_read
    cmp byte [disk_mode], DISK_BIOS
    je bios_read
    cmp byte [disk_mode], DISK_UEFI
    je efi_read
    stc
    ret

disk_write:
    cmp byte [disk_mode], DISK_ATA
    je ata_write
    cmp byte [disk_mode], DISK_BIOS
    je bios_write
    cmp byte [disk_mode], DISK_UEFI
    je efi_write
    stc
    ret

section .bss
disk_mode   resb 1
alignb 4
disk_lba_hi resd 1                      ; high half of 64-bit LBAs (installer)
section .text
