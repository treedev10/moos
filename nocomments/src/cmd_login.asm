section .bss
alignb 4
login_user      resb 20
login_hash      resd 1
pw_buf          resb 40

section .data
login_file      db "login.cfg", 0
str_set         db "set", 0
str_off         db "off", 0
signin_prompt   db "Password: ", 0

section .text

login_hashstr:
    push ebx
    push ecx
    push esi
    mov eax, 0x811C9DC5
    mov ecx, 0x01000193
.l: movzx ebx, byte [esi]
    test bl, bl
    jz .done
    xor eax, ebx
    imul eax, ecx
    inc esi
    jmp .l
.done:
    pop esi
    pop ecx
    pop ebx
    ret

login_load:
    pushad
    mov esi, login_file
    call fs_find_top
    jc .off
    mov ecx, [edi + DE_SIZE]
    call fs_slot
    mov edi, login_user
    xor ecx, ecx
.u: mov al, [esi]
    cmp al, 10
    je .uend
    test al, al
    jz .uend
    cmp ecx, 18
    jae .uskip
    mov [edi], al
    inc edi
    inc ecx
.uskip:
    inc esi
    jmp .u
.uend:
    mov byte [edi], 0
    cmp byte [esi], 10
    jne .no_nl
    inc esi
.no_nl:
    call parse_uint_partial
    jc .off
    mov [login_hash], eax
    popad
    clc
    ret
.off:
    popad
    stc
    ret

signin_maybe:
    call login_load
    jc .r
    pushad
.ask:
    call vga_clear
    call show_banner
    PRINTF `\n  This computer is signed in as \x01w%s\x01n.\n\n`, login_user
    mov esi, signin_prompt
    call pw_read
    mov esi, pw_buf
    call login_hashstr
    cmp eax, [login_hash]
    je .ok
    PRINTF `\n  \x01rWrong password.\x01n\n`
    mov ecx, 150
    call sleep_ticks
    jmp .ask
.ok:
    call vga_clear
    PRINTF `\x01gWelcome, %s.\x01n\n`, login_user
    popad
.r:
    ret

pw_read:
    pushad
    call vga_fresh_line
    mov esi, [esp + 20]

    mov esi, signin_prompt
    call vga_puts
    xor ecx, ecx
.key:
    call kbd_getkey
    cmp eax, 10
    je .done
    cmp eax, 8
    je .back
    cmp eax, 3
    je .clear
    cmp eax, ' '
    jb .key
    cmp eax, '~'
    ja .key
    cmp ecx, 38
    jae .key
    mov [pw_buf + ecx], al
    inc ecx
    mov al, '*'
    call vga_putc
    jmp .key
.back:
    test ecx, ecx
    jz .key
    dec ecx
    mov al, 8
    call vga_putc
    mov al, ' '
    call vga_putc
    mov al, 8
    call vga_putc
    jmp .key
.clear:
    xor ecx, ecx
    jmp .key
.done:
    mov byte [pw_buf + ecx], 0
    mov al, 10
    call vga_putc
    popad
    ret

cmd_login:
    cmp dword [argc], 2
    jb .status
    mov esi, [argv + 4]
    mov edi, str_set
    call str_icmp
    je .set
    mov edi, str_off
    call str_icmp
    je .off
.status:
    call login_load
    jc .is_off
    PRINTF `Sign-in is \x01won\x01n (user \x01w%s\x01n). Turn it off with \x01wlogin off\x01n.\n`, login_user
    ret
.is_off:
    PRINTF `Sign-in is \x01woff\x01n. Turn it on with \x01wlogin set <user> <password>\x01n.\n`
    ret
.set:
    cmp dword [argc], 4
    jb .set_usage
    mov esi, [argv + 12]
    call login_hashstr
    mov [login_hash], eax
    mov edi, SCRATCH
    mov esi, [argv + 8]
    call str_copy_noterm
    mov byte [edi], 10
    inc edi
    mov eax, [login_hash]
    push edi
    mov ebx, 10
    call fmt_uint
    pop edi
    rep movsb
    mov byte [edi], 10
    inc edi
    mov ecx, edi
    sub ecx, SCRATCH
    mov esi, login_file
    mov edx, SCRATCH
    call fs_save_top
    jc .err
    PRINTF `\x01gSign-in is on.\x01n You will be asked for the password at start-up.\n`
    PRINTF `\x01yKeep it safe - there is no password recovery.\x01n\n`
    ret
.set_usage:
    PRINTF `Usage: \x01wlogin set <user> <password>\x01n\n`
    ret
.err:
    PRINTF `\x01rerror:\x01n %s\n`, esi
    ret
.off:
    mov esi, login_file
    call fs_find_top
    jc .already
    call fs_delete
    PRINTF `Sign-in turned off.\n`
    ret
.already:
    PRINTF `Sign-in was already off.\n`
    ret
