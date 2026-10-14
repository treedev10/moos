section .text

to_lower:
    cmp al, 'A'
    jb .r
    cmp al, 'Z'
    ja .r
    add al, 32
.r: ret

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

skip_spaces:
    cmp byte [esi], ' '
    jne .e
    inc esi
    jmp skip_spaces
.e: ret

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

mem_copy:
    push ecx
    push esi
    push edi
    rep movsb
    pop edi
    pop esi
    pop ecx
    ret

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

sb_char:
    stosb
    mov byte [edi], 0
    ret

sb_uint:
    push ebx
    push ecx
    push esi
    mov ebx, 10
    call fmt_uint
    call sb_str
    pop esi
    pop ecx
    pop ebx
    ret

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

sb_permille:
    push eax
    call sb_tenths
    mov al, '%'
    call sb_char
    pop eax
    ret

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
.down:
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
    jb .whole
    imul eax, eax, 10
    add eax, 512
    shr eax, 10
    inc ecx
    cmp eax, 100
    jb .dec
    add eax, 5
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
    mov [esp], edi
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
