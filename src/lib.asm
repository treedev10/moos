; =============================================================================
;  lib.asm - small string helpers
;  Unless stated otherwise every routine preserves all registers it does not
;  return a value in.
; =============================================================================
section .text

; to_lower: AL = character -> AL lower-cased (flags clobbered)
to_lower:
    cmp al, 'A'
    jb .r
    cmp al, 'Z'
    ja .r
    add al, 32
.r: ret

; str_len: ESI = string -> ECX = length
str_len:
    push esi
    xor ecx, ecx
.l: cmp byte [esi], 0
    je .e
    inc esi
    inc ecx
    jmp .l
.e: pop esi
    ret

; str_icmp: compare ESI and EDI ignoring case -> ZF=1 when equal
str_icmp:
    push eax
    push ebx
    push esi
    push edi
.l: mov al, [esi]
    call to_lower
    mov bl, al
    mov al, [edi]
    call to_lower
    cmp al, bl
    jne .out
    test al, al
    jz .out
    inc esi
    inc edi
    jmp .l
.out:
    pop edi
    pop esi
    pop ebx
    pop eax
    ret

; str_iprefix: ZF=1 when string EDI starts with prefix ESI (ignoring case)
str_iprefix:
    push eax
    push ebx
    push esi
    push edi
.l: mov al, [esi]
    test al, al
    jz .out
    call to_lower
    mov bl, al
    mov al, [edi]
    call to_lower
    cmp al, bl
    jne .out
    inc esi
    inc edi
    jmp .l
.out:
    pop edi
    pop esi
    pop ebx
    pop eax
    ret

; str_copy: copy zero-terminated ESI to EDI
str_copy:
    push eax
    push esi
    push edi
.l: lodsb
    stosb
    test al, al
    jnz .l
    pop edi
    pop esi
    pop eax
    ret

; str_copy_noterm: copy zero-terminated ESI to EDI without the 0; EDI is
; left just past the copy (ESI kept)
str_copy_noterm:
    push eax
    push esi
.l: mov al, [esi]
    test al, al
    jz .e
    mov [edi], al
    inc edi
    inc esi
    jmp .l
.e: pop esi
    pop eax
    ret

; str_append: append the string ESI to the end of the string at EDI
str_append:
    push eax
    push esi
    push edi
.find:
    cmp byte [edi], 0
    je .copy
    inc edi
    jmp .find
.copy:
    mov al, [esi]
    mov [edi], al
    test al, al
    jz .done
    inc esi
    inc edi
    jmp .copy
.done:
    pop edi
    pop esi
    pop eax
    ret

; str_lower: lower-case the string at ESI in place
str_lower:
    push eax
    push esi
.l: mov al, [esi]
    test al, al
    jz .e
    call to_lower
    mov [esi], al
    inc esi
    jmp .l
.e: pop esi
    pop eax
    ret

; skip_spaces: advance ESI past spaces
skip_spaces:
    cmp byte [esi], ' '
    jne .e
    inc esi
    jmp skip_spaces
.e: ret

; parse_uint: decimal string at ESI -> EAX. CF=1 if empty, not a number,
; or larger than 4294967295.
parse_uint:
    push ebx
    push ecx
    push edx
    push esi
    xor eax, eax
    cmp byte [esi], 0
    je .bad
.l: movzx ebx, byte [esi]
    test bl, bl
    jz .ok
    sub bl, '0'
    cmp bl, 9
    ja .bad
    mov ecx, 10
    mul ecx
    jc .bad
    add eax, ebx
    jc .bad
    inc esi
    jmp .l
.ok:
    clc
    jmp .out
.bad:
    stc
.out:
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; mem_copy: copy ECX bytes from ESI to EDI (non-overlapping)
mem_copy:
    push ecx
    push esi
    push edi
    rep movsb
    pop edi
    pop esi
    pop ecx
    ret

; ------------------------------------------------- building text in memory
; The sb_ routines add to a text being built at EDI: each appends its part,
; moves EDI to the new end and keeps the text zero-terminated. Other
; registers are kept. (fetch and the Task Manager build their lines this
; way, so they work whether the output goes to the screen or a window.)

; sb_str: append the string ESI
sb_str:
    push eax
    push esi
.l: lodsb
    test al, al
    jz .e
    stosb
    jmp .l
.e: mov byte [edi], 0
    pop esi
    pop eax
    ret

; sb_char: append the character AL
sb_char:
    stosb
    mov byte [edi], 0
    ret

; sb_uint: append EAX as a decimal number
sb_uint:
    push ebx
    push ecx
    push esi
    mov ebx, 10
    call fmt_uint                   ; ESI = the digits
    call sb_str
    pop esi
    pop ecx
    pop ebx
    ret

; sb_tenths: append EAX tenths as "12.3"
sb_tenths:
    push eax
    push ecx
    push edx
    xor edx, edx
    mov ecx, 10
    div ecx
    call sb_uint
    mov al, '.'
    call sb_char
    lea eax, [edx + '0']
    call sb_char
    pop edx
    pop ecx
    pop eax
    ret

; sb_permille: append EAX thousandths as a percentage, "12.3%"
sb_permille:
    push eax
    call sb_tenths
    mov al, '%'
    call sb_char
    pop eax
    ret

; sb_bytes: append EAX bytes as "512 B", "12 KB", "1.5 MB" ...
; sb_kb:    the same for EAX kilobytes
; sb_size:  the same for EDX:EAX in the unit ECX (0 bytes, 1 KB, 2 MB)
; Below 10 of a unit one decimal is shown ("1.5 MB"), above it none.
sb_bytes:
    push ecx
    push edx
    xor ecx, ecx
    xor edx, edx
    call sb_size
    pop edx
    pop ecx
    ret
sb_kb:
    push ecx
    push edx
    mov ecx, 1
    xor edx, edx
    call sb_size
    pop edx
    pop ecx
    ret
sb_size:
    pushad
.down:                              ; bring it below 1024 * 1024 units
    test edx, edx
    jnz .shift
    cmp eax, 1024 * 1024
    jb .small
.shift:
    shrd eax, edx, 10
    shr edx, 10
    inc ecx
    jmp .down
.small:
    cmp eax, 1024
    jb .whole                       ; e.g. "512 KB"
    imul eax, eax, 10               ; tenths of the next unit up,
    add eax, 512                    ; rounded
    shr eax, 10
    inc ecx
    cmp eax, 100
    jb .dec
    add eax, 5                      ; 10 or more: no decimal (rounded)
    xor edx, edx
    mov ebx, 10
    div ebx
.whole:
    call sb_uint
    jmp .unit
.dec:
    call sb_tenths
.unit:
    cmp ecx, 4
    jbe .u
    mov ecx, 4
.u: mov al, ' '
    call sb_char
    mov esi, [sb_units + ecx * 4]
    call sb_str
    mov [esp], edi                  ; (EDI after popad)
    popad
    ret

section .data
sb_units    dd sb_u0, sb_u1, sb_u2, sb_u3, sb_u4
sb_u0       db "B", 0
sb_u1       db "KB", 0
sb_u2       db "MB", 0
sb_u3       db "GB", 0
sb_u4       db "TB", 0
section .text

; sb_ip: append the IPv4 address EAX (network byte order) as "10.0.2.15"
sb_ip:
    push eax
    push ecx
    push edx
    mov edx, eax
    mov ecx, 4
.l: movzx eax, dl
    call sb_uint
    shr edx, 8
    dec ecx
    jz .e
    mov al, '.'
    call sb_char
    jmp .l
.e: pop edx
    pop ecx
    pop eax
    ret
