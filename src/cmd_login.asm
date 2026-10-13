; =============================================================================
;  cmd_login.asm - an optional sign-in screen
;
;  Off by default. "login set <user> <password>" turns it on by saving a
;  config file (login.cfg) with the user name and a hash of the password;
;  then every start-up asks for the password before the shell appears.
;  "login off" turns it back off.
;
;  This is light protection for a personal machine, not real security: the
;  hash is a simple one and anyone who can edit the disk can remove the file.
; =============================================================================
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

; login_hashstr: ESI = string -> EAX = 32-bit FNV-1a hash
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

; login_load: read login.cfg into login_user / login_hash.
; CF=0 if sign-in is enabled, CF=1 if not.
login_load:
    pushad
    mov esi, login_file
    call fs_find
    jc .off
    mov ecx, [edi + DE_SIZE]
    call fs_slot                    ; ESI = "user<newline>hash"
    mov edi, login_user             ; copy the user name (first line)
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
    call parse_uint_partial         ; the hash (decimal; stops at newline)
    jc .off
    mov [login_hash], eax
    popad
    clc
    ret
.off:
    popad
    stc
    ret

; signin_maybe: called at start-up. If sign-in is enabled, ask for the
; password and do not return until it is right.
signin_maybe:
    call login_load
    jc .r
    pushad
.ask:
    call vga_clear
    call show_banner
    PRINTF `\n  This computer is signed in as \x01w%s\x01n.\n\n`, login_user
    mov esi, signin_prompt
    call pw_read                    ; -> pw_buf
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

; pw_read: ESI = prompt. Reads a line into pw_buf, showing * for each key.
pw_read:
    pushad
    call vga_fresh_line
    mov esi, [esp + 20]             ; (prompt passed in ESI via pushad slot)
    ; simpler: reload prompt from a fixed location
    mov esi, signin_prompt
    call vga_puts
    xor ecx, ecx
.key:
    call kbd_getkey
    cmp eax, 10
    je .done
    cmp eax, 8
    je .back
    cmp eax, 3                      ; Ctrl+C: clear
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

; cmd_login: manage the sign-in setting
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
    mov esi, [argv + 12]            ; hash the password
    call login_hashstr
    mov [login_hash], eax
    mov edi, SCRATCH                ; build "user\nhash\n"
    mov esi, [argv + 8]
    call str_copy_noterm
    mov byte [edi], 10
    inc edi
    mov eax, [login_hash]           ; hash as decimal text
    push edi
    mov ebx, 10
    call fmt_uint                   ; ESI=digits, ECX=len
    pop edi
    rep movsb
    mov byte [edi], 10
    inc edi
    mov ecx, edi
    sub ecx, SCRATCH
    mov esi, login_file
    mov edx, SCRATCH
    call fs_save
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
    call fs_find
    jc .already
    call fs_delete
    PRINTF `Sign-in turned off.\n`
    ret
.already:
    PRINTF `Sign-in was already off.\n`
    ret
