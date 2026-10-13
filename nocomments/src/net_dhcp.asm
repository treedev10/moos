NET_DHCP    equ NET_BUF + 0x7000
DHCP_SPORT  equ 68
DHCP_DPORT  equ 67

section .bss
alignb 4
dhcp_offered    resd 1
dhcp_msglen     resd 1
dhcp_deadline   resd 1
dhcp_want       resb 1

section .text

dhcp_make_xid:
    push eax
    push edx
    rdtsc
    xor eax, [ticks]
    add eax, 0x4D4F4F53
    mov [dhcp_xid], eax
    pop edx
    pop eax
    ret

dhcp_build:
    pushad
    mov edi, NET_DHCP
    mov ecx, 300 / 4
    push eax
    xor eax, eax
    rep stosd
    pop eax
    mov edi, NET_DHCP
    mov byte [edi + 0], 1
    mov byte [edi + 1], 1
    mov byte [edi + 2], 6
    mov edx, [dhcp_xid]
    mov [edi + 4], edx
    mov word [edi + 10], 0x0080
    mov esi, nic_mac
    push eax
    lea edi, [edi + 28]
    mov ecx, 6
    rep movsb
    pop eax
    mov edi, NET_DHCP + 236
    mov dword [edi], 0x63538263
    add edi, 4
    mov byte [edi], 53
    mov byte [edi + 1], 1
    mov [edi + 2], al
    add edi, 3
    cmp al, 3
    jne .params
    mov byte [edi], 50
    mov byte [edi + 1], 4
    mov eax, [dhcp_offered]
    mov [edi + 2], eax
    add edi, 6
    mov byte [edi], 54
    mov byte [edi + 1], 4
    mov eax, [dhcp_server]
    mov [edi + 2], eax
    add edi, 6
.params:
    mov byte [edi], 55
    mov byte [edi + 1], 3
    mov byte [edi + 2], 1
    mov byte [edi + 3], 3
    mov byte [edi + 4], 6
    add edi, 5
    mov byte [edi], 255
    inc edi
    sub edi, NET_DHCP
    mov [dhcp_msglen], edi
    popad
    mov ecx, [dhcp_msglen]
    ret

dhcp_find_opt:
    push ebx
    push ecx
    push edx
    lea ebx, [esi + 240]
    lea edx, [esi + ecx]
.scan:
    cmp ebx, edx
    jae .none
    mov ah, [ebx]
    cmp ah, 255
    je .none
    cmp ah, 0
    je .pad
    cmp ah, al
    je .found
    movzx ecx, byte [ebx + 1]
    lea ebx, [ebx + ecx + 2]
    jmp .scan
.pad:
    inc ebx
    jmp .scan
.found:
    mov ah, [ebx + 1]
    lea edi, [ebx + 2]
    pop edx
    pop ecx
    pop ebx
    clc
    ret
.none:
    pop edx
    pop ecx
    pop ebx
    stc
    ret

dhcp_msgtype:
    push edi
    mov al, 53
    call dhcp_find_opt
    jc .none
    mov al, [edi]
    pop edi
    clc
    ret
.none:
    pop edi
    stc
    ret

dhcp_wait_type:
    mov [dhcp_want], al
.l: mov eax, [dhcp_deadline]
    mov dx, DHCP_SPORT
    call udp_wait
    jc .no
    mov eax, [dhcp_xid]
    cmp [esi + 4], eax
    jne .l
    call dhcp_msgtype
    jc .l
    cmp al, 6
    je .no
    cmp al, [dhcp_want]
    jne .l
    clc
    ret
.no:
    stc
    ret

dhcp_configure:
    pushad
    mov dword [my_ip], 0
    mov dword [my_mask], 0
    mov dword [gw_ip], 0
    call dhcp_make_xid
    mov ebp, 4
.attempt:
    mov al, 1
    call dhcp_build
    mov eax, 0xFFFFFFFF
    mov bx, DHCP_DPORT
    mov dx, DHCP_SPORT
    mov esi, NET_DHCP
    call udp_send
    mov eax, [ticks]
    add eax, 300
    mov [dhcp_deadline], eax
    mov al, 2
    call dhcp_wait_type
    jc .retry
    mov eax, [esi + 16]
    mov [dhcp_offered], eax
    push esi
    mov al, 54
    call dhcp_find_opt
    jc .no_server
    mov eax, [edi]
    mov [dhcp_server], eax
.no_server:
    pop esi

    mov al, 3
    call dhcp_build
    mov eax, 0xFFFFFFFF
    mov bx, DHCP_DPORT
    mov dx, DHCP_SPORT
    mov esi, NET_DHCP
    call udp_send
    mov eax, [ticks]
    add eax, 300
    mov [dhcp_deadline], eax
    mov al, 5
    call dhcp_wait_type
    jc .retry
    mov eax, [esi + 16]
    mov [my_ip], eax
    mov [dhcp_msglen], ecx
    push esi
    mov al, 1
    call dhcp_find_opt
    jc .def_mask
    mov eax, [edi]
    mov [my_mask], eax
    jmp .got_mask
.def_mask:
    mov dword [my_mask], 0x00FFFFFF
.got_mask:
    mov esi, [esp]
    mov ecx, [dhcp_msglen]
    mov al, 3
    call dhcp_find_opt
    jc .no_gw
    mov eax, [edi]
    mov [gw_ip], eax
.no_gw:
    mov esi, [esp]
    mov ecx, [dhcp_msglen]
    mov al, 6
    call dhcp_find_opt
    jc .no_dns
    mov eax, [edi]
    mov [dns_ip], eax
.no_dns:
    pop esi
    popad
    clc
    ret
.retry:
    dec ebp
    jnz .attempt
    popad
    mov esi, err_no_dhcp
    stc
    ret
