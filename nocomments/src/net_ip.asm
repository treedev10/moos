NET_TXP     equ NET_BUF + 0x6000

section .bss
alignb 4
ip_dst          resd 1
ip_payload      resd 1
ip_plen         resd 1
ip_proto        resb 1
alignb 4
udp_match_port  resw 1
alignb 4
udp_deadline    resd 1
udp_from_ip     resd 1
udp_from_port   resw 1

section .text

ip_send:
    pushad
    mov [ip_dst], eax
    mov [ip_proto], bl
    mov [ip_payload], esi
    mov [ip_plen], ecx
    cmp eax, 0xFFFFFFFF
    je .resolve
    mov edi, eax
    and edi, [my_mask]
    mov ebp, [my_ip]
    and ebp, [my_mask]
    cmp edi, ebp
    je .resolve
    mov eax, [gw_ip]
.resolve:
    call arp_resolve
    jc .fail
    mov esi, edi
    mov edi, NET_PKT
    mov ax, ET_IP
    call eth_build
    mov esi, edi
    mov byte [edi], 0x45
    mov byte [edi + 1], 0
    mov eax, [ip_plen]
    add eax, 20
    xchg ah, al
    mov [edi + 2], ax
    mov eax, [ip_ident]
    inc dword [ip_ident]
    xchg ah, al
    mov [edi + 4], ax
    mov word [edi + 6], 0
    mov byte [edi + 8], 64
    mov al, [ip_proto]
    mov [edi + 9], al
    mov word [edi + 10], 0
    mov eax, [my_ip]
    mov [edi + 12], eax
    mov eax, [ip_dst]
    mov [edi + 16], eax
    push esi
    mov ecx, 20
    call ip_checksum
    pop esi
    xchg ah, al
    mov [esi + 10], ax
    lea edi, [esi + 20]
    mov esi, [ip_payload]
    mov ecx, [ip_plen]
    rep movsb
    mov esi, NET_PKT
    mov ecx, [ip_plen]
    add ecx, ETH_HLEN + 20
    call net_tx_frame
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

udp_send:
    pushad
    mov edi, NET_TXP
    push eax
    mov ax, dx
    xchg ah, al
    mov [edi], ax
    mov ax, bx
    xchg ah, al
    mov [edi + 2], ax
    mov eax, ecx
    add eax, 8
    xchg ah, al
    mov [edi + 4], ax
    mov word [edi + 6], 0
    push ecx
    lea edi, [edi + 8]
    rep movsb
    pop ecx
    pop eax
    add ecx, 8
    mov esi, NET_TXP
    mov bl, IPPROTO_UDP
    call ip_send
    popad
    ret

udp_wait:
    push ebx
    mov [udp_match_port], dx
    mov [udp_deadline], eax
.loop:
    mov eax, [udp_deadline]
    call net_poll_until
    jc .timeout
    mov esi, [rx_frame]
    mov ecx, [rx_len]
    mov ax, [esi + 12]
    cmp ax, 0x0608
    jne .not_arp
    call arp_handle
    jmp .loop
.not_arp:
    cmp ax, 0x0008
    jne .loop
    lea ebx, [esi + ETH_HLEN]
    movzx eax, byte [ebx]
    and al, 0x0F
    cmp al, 5
    jb .loop
    shl eax, 2
    cmp byte [ebx + 9], IPPROTO_UDP
    jne .loop
    lea edx, [ebx + eax]
    mov ax, [edx + 2]
    xchg ah, al
    cmp ax, [udp_match_port]
    jne .loop
    mov eax, [ebx + 12]
    mov [udp_from_ip], eax
    mov ax, [edx]
    xchg ah, al
    mov [udp_from_port], ax
    movzx ecx, word [edx + 4]
    xchg ch, cl
    sub ecx, 8
    lea esi, [edx + 8]
    pop ebx
    clc
    ret
.timeout:
    pop ebx
    stc
    ret
