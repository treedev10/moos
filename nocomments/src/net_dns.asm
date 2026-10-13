NET_DNS     equ NET_BUF + 0x7800
EPHEMERAL   equ 0xC000

section .bss
alignb 4
dns_port    resw 1
alignb 4
ntp_server  resd 1
ntp_tries   resd 1

section .data
ntp_name    db "pool.ntp.org", 0

section .text

parse_ipv4:
    push ebx
    push ecx
    push edx
    push esi
    xor ebx, ebx
    xor ecx, ecx
.part:
    xor edx, edx
    xor ah, ah
.digit:
    mov al, [esi]
    cmp al, '0'
    jb .sep
    cmp al, '9'
    ja .sep
    imul edx, edx, 10
    movzx eax, al
    sub eax, '0'
    add edx, eax
    cmp edx, 255
    ja .bad
    inc ah
    inc esi
    jmp .digit
.sep:
    test ah, ah
    jz .bad
    shr ebx, 8
    shl edx, 24
    or ebx, edx
    mov al, [esi]
    cmp al, '.'
    jne .end
    inc ecx
    cmp ecx, 3
    ja .bad
    inc esi
    jmp .part
.end:
    cmp al, 0
    jne .bad
    cmp ecx, 3
    jne .bad
    mov eax, ebx
    pop esi
    pop edx
    pop ecx
    pop ebx
    clc
    ret
.bad:
    pop esi
    pop edx
    pop ecx
    pop ebx
    stc
    ret

dns_encode_name:
    push eax
    push ebx
.label:
    mov ebx, edi
    inc edi
    xor al, al
.char:
    mov ah, [esi]
    test ah, ah
    jz .last
    cmp ah, '.'
    je .end_label
    mov [edi], ah
    inc edi
    inc esi
    inc al
    jmp .char
.end_label:
    mov [ebx], al
    inc esi
    jmp .label
.last:
    mov [ebx], al
    mov byte [edi], 0
    inc edi
    pop ebx
    pop eax
    ret

dns_resolve:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    call parse_ipv4
    jnc .numeric
    cmp byte [net_up], 0
    je .fail
    mov eax, [ticks]
    and eax, 0x0FFF
    add eax, EPHEMERAL
    mov [dns_port], ax
    mov edi, NET_DNS
    mov eax, [dhcp_xid]
    mov [edi], ax
    mov word [edi + 2], 0x0001
    mov word [edi + 4], 0x0100
    mov dword [edi + 6], 0
    mov word [edi + 10], 0
    add edi, 12
    mov esi, [esp + 4]
    call dns_encode_name
    mov word [edi], 0x0100
    mov word [edi + 2], 0x0100
    add edi, 4
    mov ecx, edi
    sub ecx, NET_DNS
    mov ebx, 2
.try:
    mov esi, NET_DNS
    mov eax, [dns_ip]
    push ebx
    push ecx
    mov bx, 53
    mov dx, [dns_port]
    call udp_send
    pop ecx
    pop ebx
    mov eax, [ticks]
    add eax, 150
    mov dx, [dns_port]
    call udp_wait
    jc .next
    call dns_parse_answer
    jnc .got
.next:
    dec ebx
    jnz .try
    jmp .fail
.got:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    clc
    ret
.numeric:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    clc
    ret
.fail:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    mov eax, 0
    stc
    ret

dns_parse_answer:
    push ebx
    push ecx
    push edx
    push esi
    cmp ecx, 12
    jb .none
    movzx eax, word [esi + 6]
    xchg ah, al
    test eax, eax
    jz .none
    mov edx, eax
    lea ebx, [esi + 12]
    call .skip_name
    add ebx, 4
.answer:
    test edx, edx
    jz .none
    call .skip_name
    movzx eax, word [ebx]
    xchg ah, al
    movzx ecx, word [ebx + 8]
    xchg ch, cl
    cmp eax, 1
    jne .skip
    cmp ecx, 4
    jne .skip
    mov eax, [ebx + 10]
    pop esi
    pop edx
    pop ecx
    pop ebx
    clc
    ret
.skip:
    lea ebx, [ebx + ecx + 10]
    dec edx
    jmp .answer
.none:
    pop esi
    pop edx
    pop ecx
    pop ebx
    stc
    ret

.skip_name:
    mov al, [ebx]
    test al, al
    jz .name_done
    and al, 0xC0
    cmp al, 0xC0
    je .pointer
    movzx eax, byte [ebx]
    lea ebx, [ebx + eax + 1]
    jmp .skip_name
.pointer:
    add ebx, 2
    ret
.name_done:
    inc ebx
    ret

ntp_query:
    push esi
    mov esi, ntp_name
    call dns_resolve
    pop esi
    jc .resolve_fail
    jmp ntp_query_addr
.resolve_fail:
    stc
    ret

ntp_query_addr:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    mov [ntp_server], eax
    mov edi, NET_DNS
    xor eax, eax
    mov ecx, 12
    rep stosd
    mov byte [NET_DNS], 0x1B
    mov eax, [ticks]
    and eax, 0x0FFF
    add eax, EPHEMERAL
    mov [dns_port], ax
    mov dword [ntp_tries], 3
.try:
    mov esi, NET_DNS
    mov eax, [ntp_server]
    mov bx, 123
    mov dx, [dns_port]
    call udp_send
    mov eax, [ticks]
    add eax, 200
    mov dx, [dns_port]
    call udp_wait
    jc .next
    cmp ecx, 48
    jb .next
    mov eax, [esi + 40]
    bswap eax
    sub eax, 2208988800
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    clc
    ret
.next:
    dec dword [ntp_tries]
    jnz .try
.fail:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    stc
    ret
