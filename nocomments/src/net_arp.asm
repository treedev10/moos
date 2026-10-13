ARP_MAX     equ 8
ARP_ENT     equ 10

section .bss
alignb 4
arp_cache   resb ARP_MAX * ARP_ENT
arp_count   resd 1
arp_next    resd 1
arp_oper    resw 1
alignb 4
arp_tip     resd 1
arp_tha     resb 6
alignb 4
arp_want    resd 1
arp_deadline resd 1

section .text

arp_lookup:
    push ecx
    push esi
    mov esi, arp_cache
    mov ecx, [arp_count]
.l: jecxz .miss
    cmp [esi], eax
    je .hit
    add esi, ARP_ENT
    dec ecx
    jmp .l
.hit:
    lea edi, [esi + 4]
    pop esi
    pop ecx
    clc
    ret
.miss:
    pop esi
    pop ecx
    stc
    ret

arp_insert:
    pushad
    push eax
    call arp_lookup
    pop eax
    jnc .store
    mov edi, [arp_count]
    cmp edi, ARP_MAX
    jb .append
    mov edi, [arp_next]
    inc dword [arp_next]
    and dword [arp_next], ARP_MAX - 1
    imul edi, edi, ARP_ENT
    add edi, arp_cache
    jmp .write
.append:
    imul edi, edi, ARP_ENT
    add edi, arp_cache
    inc dword [arp_count]
.write:
    mov [edi], eax
    add edi, 4
.store:
    mov ecx, 6
    rep movsb
    popad
    ret

arp_send:
    pushad
    mov edi, NET_PKT
    mov esi, mac_bcast
    cmp word [arp_oper], 2
    jne .dest_ok
    mov esi, arp_tha
.dest_ok:
    mov ax, ET_ARP
    call eth_build
    mov word [edi], 0x0100
    mov word [edi + 2], 0x0008
    mov byte [edi + 4], 6
    mov byte [edi + 5], 4
    mov ax, [arp_oper]
    xchg ah, al
    mov [edi + 6], ax
    lea edi, [edi + 8]
    mov esi, nic_mac
    mov ecx, 6
    rep movsb
    mov eax, [my_ip]
    stosd
    mov esi, arp_tha
    xor eax, eax
    cmp word [arp_oper], 2
    je .copy_tha
    stosd
    stosw
    jmp .tpa
.copy_tha:
    mov ecx, 6
    rep movsb
.tpa:
    mov eax, [arp_tip]
    stosd
    mov esi, NET_PKT
    mov ecx, ETH_HLEN + 28
    call net_tx_frame
    popad
    ret

arp_handle:
    pushad
    cmp ecx, ETH_HLEN + 28
    jb .done
    mov ax, [esi + 12]
    cmp ax, (ET_ARP >> 8) | ((ET_ARP & 0xFF) << 8)
    jne .done
    lea ebx, [esi + ETH_HLEN]
    mov eax, [ebx + 14]
    test eax, eax
    jz .reply_check
    lea esi, [ebx + 8]
    push ebx
    call arp_insert
    pop ebx
.reply_check:
    cmp word [ebx + 6], 0x0200
    jne .maybe_req
    jmp .done
.maybe_req:
    cmp word [ebx + 6], 0x0100
    jne .done
    mov eax, [ebx + 24]
    cmp eax, [my_ip]
    jne .done
    mov eax, [ebx + 14]
    mov [arp_tip], eax
    lea esi, [ebx + 8]
    mov edi, arp_tha
    mov ecx, 6
    rep movsb
    mov word [arp_oper], 2
    call arp_send
.done:
    popad
    ret

arp_resolve:
    cmp eax, 0xFFFFFFFF
    je .bcast
    mov [arp_want], eax
    call arp_lookup
    jnc .ok
    push ecx
    mov ecx, 3
.try:
    mov eax, [arp_want]
    mov [arp_tip], eax
    mov word [arp_oper], 1
    call arp_send
    mov eax, [ticks]
    add eax, 50
    mov [arp_deadline], eax
.wait:
    mov eax, [arp_deadline]
    call net_poll_until
    jc .next
    mov esi, [rx_frame]
    mov ecx, [rx_len]
    call arp_handle
    mov eax, [arp_want]
    call arp_lookup
    jnc .ok_pop
    jmp .wait
.next:
    dec ecx
    jnz .try
    pop ecx
    stc
    ret
.ok_pop:
    pop ecx
.ok:
    ret
.bcast:
    mov edi, mac_bcast
    clc
    ret
