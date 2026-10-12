; =============================================================================
;  kbd.asm - PS/2 keyboard driver (scan code set 1, US layout)
;  IRQ 1 stores raw scan codes in a ring buffer; kbd_getkey translates them.
; =============================================================================
KBD_BUF_MASK equ 63

section .bss
kbd_buf     resb KBD_BUF_MASK + 1
kbd_head    resb 1
kbd_tail    resb 1
kbd_shift   resb 1
kbd_ctrl    resb 1
kbd_caps    resb 1
kbd_e0      resb 1

section .data
; scan code -> ASCII, 0x00..0x39
keymap_normal:
    db 0, 27, "1234567890-=", 8, 9
    db "qwertyuiop[]", 10, 0, "as"
    db "dfghjkl;'`", 0, "\zxcv"
    db "bnm,./", 0, "*", 0, " "
keymap_shift:
    db 0, 27, "!@#$%^&*()_+", 8, 9
    db "QWERTYUIOP{}", 10, 0, "AS"
    db 'DFGHJKL:"~', 0, "|ZXCV"
    db "BNM<>?", 0, "*", 0, " "
; scan codes 0x47..0x53 (cursor block / keypad)
keymap_nav:
    dw KEY_HOME, KEY_UP, KEY_PGUP, '-', KEY_LEFT, 0, KEY_RIGHT, '+'
    dw KEY_END, KEY_DOWN, KEY_PGDN, 0, KEY_DEL

section .text

irq1_keyboard:
    push eax
    push ebx
    in al, 0x60
    movzx ebx, byte [kbd_head]
    mov ah, bl
    inc ah
    and ah, KBD_BUF_MASK
    cmp ah, [kbd_tail]
    je .full                        ; buffer full: drop the key
    mov [kbd_buf + ebx], al
    mov [kbd_head], ah
.full:
    mov al, 0x20
    out 0x20, al
    pop ebx
    pop eax
    iretd

; kbd_collect: move key codes waiting in the keyboard controller into the
; buffer. Used after a BIOS call, when the keyboard interrupt was masked.
kbd_collect:
    push eax
    push ebx
.l: in al, 0x64
    test al, 1
    jz .done
    in al, 0x60
    movzx ebx, byte [kbd_head]
    mov ah, bl
    inc ah
    and ah, KBD_BUF_MASK
    cmp ah, [kbd_tail]
    je .l
    mov [kbd_buf + ebx], al
    mov [kbd_head], ah
    jmp .l
.done:
    pop ebx
    pop eax
    ret

; kbd_init: throw away anything the BIOS left in the controller
kbd_getkey_uefi:                    ; (EBX is already saved)
.wait:
    call status_tick
    call screen_present
    mov eax, efi_readkey64              ; waits up to half a second
    call efi64
    test eax, eax
    jz .wait
    mov ebx, eax
    shr ebx, 16                         ; EBX = UEFI scan code
    and eax, 0xFFFF                     ; EAX = character
    jz .scan
    cmp eax, 13
    je .enter
    cmp eax, 127
    je .backspace
    ja .wait                            ; not plain ASCII
    jmp .done
.enter:
    mov eax, 10
    jmp .done
.backspace:
    mov eax, 8
    jmp .done
.scan:
    cmp ebx, 0x17                       ; Esc
    je .esc
    cmp ebx, 0x0A
    ja .wait
    movzx eax, word [efi_scan_keys + ebx * 2]
    test eax, eax
    jz .wait
    jmp .done
.esc:
    mov eax, 27
.done:
    pop ebx
    ret

section .data
efi_scan_keys:                          ; UEFI scan codes 0x00-0x0A
    dw 0, KEY_UP, KEY_DOWN, KEY_RIGHT, KEY_LEFT, KEY_HOME, KEY_END
    dw 0, KEY_DEL, KEY_PGUP, KEY_PGDN
section .text

kbd_init:
    cmp dword [bootinfo + BI.platform], PLATFORM_UEFI
    je .r
    push eax
.l: in al, 0x64
    test al, 1
    jz .e
    in al, 0x60
    jmp .l
.e: pop eax
.r: ret

; kbd_pop: CF=0 and AL = scan code, or CF=1 when the buffer is empty
kbd_pop:
    push ebx
    cli
    movzx ebx, byte [kbd_tail]
    cmp bl, [kbd_head]
    je .empty
    mov al, [kbd_buf + ebx]
    inc bl
    and bl, KBD_BUF_MASK
    mov [kbd_tail], bl
    sti
    pop ebx
    clc
    ret
.empty:
    sti
    pop ebx
    stc
    ret

; kbd_getkey: wait for a key press -> EAX = ASCII code or KEY_* constant.
; Ctrl+letter gives 1..26. While waiting the CPU sleeps (hlt) and the
; status bar clock is kept up to date.
kbd_getkey:
    push ebx
    cmp dword [bootinfo + BI.platform], PLATFORM_UEFI
    je kbd_getkey_uefi
.wait:
    call kbd_pop
    jnc .got
    call status_tick
    call screen_present
    hlt
    jmp .wait
.got:
    cmp al, 0xE0
    jne .not_prefix
    mov byte [kbd_e0], 1
    jmp .wait
.not_prefix:
    movzx eax, al
    mov bl, [kbd_e0]
    mov byte [kbd_e0], 0
    test al, 0x80
    jnz .release
    test bl, bl
    jnz .extended

    cmp al, 0x2A                    ; left shift
    je .shift_on
    cmp al, 0x36                    ; right shift
    je .shift_on
    cmp al, 0x1D                    ; ctrl
    je .ctrl_on
    cmp al, 0x3A                    ; caps lock
    je .caps
    cmp al, 0x47
    jae .nav
    cmp al, 0x39
    ja .wait                        ; F-keys etc: ignored

    movzx ebx, al
    mov al, [keymap_normal + ebx]
    test al, al
    jz .wait
    mov ah, [kbd_shift]             ; letters: caps lock inverts shift
    cmp al, 'a'
    jb .no_letter
    cmp al, 'z'
    ja .no_letter
    xor ah, [kbd_caps]
    cmp byte [kbd_ctrl], 0
    je .no_letter
    and eax, 0x1F                   ; Ctrl+letter -> 1..26
    jmp .done
.no_letter:
    test ah, ah
    jz .ascii
    mov al, [keymap_shift + ebx]
.ascii:
    movzx eax, al
    jmp .done

.extended:                          ; keys sent with an 0xE0 prefix
    cmp al, 0x1C
    je .kp_enter
    cmp al, 0x35
    je .kp_slash
    cmp al, 0x1D
    je .ctrl_on
    cmp al, 0x47
    jb .wait
.nav:
    cmp al, 0x53
    ja .wait
    movzx eax, word [keymap_nav - 0x47 * 2 + eax * 2]
    test eax, eax
    jz .wait
    jmp .done
.kp_enter:
    mov eax, 10
    jmp .done
.kp_slash:
    mov eax, '/'
    jmp .done

.release:
    and al, 0x7F
    cmp al, 0x1D
    je .ctrl_off
    test bl, bl                     ; ignore fake shifts sent with E0
    jnz .wait
    cmp al, 0x2A
    je .shift_off
    cmp al, 0x36
    je .shift_off
    jmp .wait

.shift_on:
    mov byte [kbd_shift], 1
    jmp .wait
.shift_off:
    mov byte [kbd_shift], 0
    jmp .wait
.ctrl_on:
    mov byte [kbd_ctrl], 1
    jmp .wait
.ctrl_off:
    mov byte [kbd_ctrl], 0
    jmp .wait
.caps:
    xor byte [kbd_caps], 1
    jmp .wait
.done:
    pop ebx
    ret

; confirm: ESI = question. Prints it with " (y/n) " and waits.
; CF=0 for yes, CF=1 for no (n, Esc, Enter or Ctrl+C).
confirm:
    push eax
    PRINTF `%s \x01w(y/n)\x01n `, esi
.k: call kbd_getkey
    cmp eax, 'y'
    je .yes
    cmp eax, 'Y'
    je .yes
    cmp eax, 'n'
    je .no
    cmp eax, 'N'
    je .no
    cmp eax, 27
    je .no
    cmp eax, 10
    je .no
    cmp eax, 3
    je .no
    jmp .k
.yes:
    PRINTF `yes\n`
    pop eax
    clc
    ret
.no:
    PRINTF `no\n`
    pop eax
    stc
    ret
