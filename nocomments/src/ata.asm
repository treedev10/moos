ATA_IO      equ 0x1F0
ATA_ALT     equ 0x3F6
ATA_TIMEOUT equ 0x400000

section .text

ata_wait_ready:
    push eax
    push ecx
    push edx
    mov edx, ATA_IO + 7
    mov ecx, ATA_TIMEOUT
.l: in al, dx
    test al, 0x80
    jz .ok
    loop .l
    stc
    jmp .out
.ok:
    test al, 0x21
    jnz .fail
    clc
    jmp .out
.fail:
    stc
.out:
    pop edx
    pop ecx
    pop eax
    ret

ata_wait_drq:
    push eax
    push ecx
    push edx
    mov edx, ATA_IO + 7
    mov ecx, ATA_TIMEOUT
.l: in al, dx
    test al, 0x80
    jnz .next
    test al, 0x21
    jnz .fail
    test al, 0x08
    jnz .ok
.next:
    loop .l
.fail:
    stc
    jmp .out
.ok:
    clc
.out:
    pop edx
    pop ecx
    pop eax
    ret

ata_command:
    push eax
    push ecx
    push edx
    mov ecx, eax
    call ata_wait_ready
    jc .out
    mov edx, ATA_IO + 6
    mov eax, ecx
    shr eax, 24
    and al, 0x0F
    or al, 0xE0
    out dx, al
    mov edx, ATA_ALT
    in al, dx
    in al, dx
    in al, dx
    in al, dx
    mov edx, ATA_IO + 2
    mov al, 1
    out dx, al
    inc edx
    mov al, cl
    out dx, al
    inc edx
    mov al, ch
    out dx, al
    inc edx
    mov eax, ecx
    shr eax, 16
    out dx, al
    mov edx, ATA_IO + 7
    mov al, bl
    out dx, al
    clc
.out:
    pop edx
    pop ecx
    pop eax
    ret

ata_read:
    pushad
.next:
    test ecx, ecx
    jz .ok
    mov bl, 0x20
    call ata_command
    jc .fail
    call ata_wait_drq
    jc .fail
    push ecx
    mov ecx, 256
    mov edx, ATA_IO
    rep insw
    pop ecx
    inc eax
    dec ecx
    jmp .next
.ok:
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

ata_write:
    pushad
.next:
    test ecx, ecx
    jz .flush
    mov bl, 0x30
    call ata_command
    jc .fail
    call ata_wait_drq
    jc .fail
    push ecx
    mov ecx, 256
    mov edx, ATA_IO
.w: outsw
    loop .w
    pop ecx
    call ata_wait_ready
    jc .fail
    inc eax
    dec ecx
    jmp .next
.flush:
    mov edx, ATA_IO + 7
    mov al, 0xE7
    out dx, al
    call ata_wait_ready
    jc .fail
    popad
    clc
    ret
.fail:
    popad
    stc
    ret
