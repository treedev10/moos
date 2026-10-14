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
