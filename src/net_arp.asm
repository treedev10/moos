; =============================================================================
;  net_arp.asm - ARP: turn an IPv4 address into a MAC address
;
;  A small cache (8 entries) remembers the MACs we have learned. arp_resolve
;  sends a request and waits for the reply when a MAC is not yet known.
;  The packet fields are passed in memory variables to keep the code clear.
; =============================================================================
ARP_MAX     equ 8
ARP_ENT     equ 10              ; 4-byte IP + 6-byte MAC

section .bss
alignb 4
arp_cache   resb ARP_MAX * ARP_ENT
arp_count   resd 1
arp_next    resd 1
arp_oper    resw 1             ; 1 request, 2 reply
alignb 4
arp_tip     resd 1             ; target IP
arp_tha     resb 6             ; target MAC (for replies / cache fill)
alignb 4
arp_want    resd 1
arp_deadline resd 1

section .text

; arp_lookup: EAX = IP -> EDI = MAC pointer, CF=0; else CF=1
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

; arp_insert: EAX = IP, ESI = MAC (6 bytes)
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

; arp_send: build and transmit the ARP packet described by arp_oper / arp_tip
; / arp_tha (arp_tha also used as the Ethernet destination for replies)
arp_send:
    pushad
    mov edi, NET_PKT
    mov esi, mac_bcast
    cmp word [arp_oper], 2
    jne .dest_ok
    mov esi, arp_tha
.dest_ok:
    mov ax, ET_ARP
    call eth_build                  ; EDI now past the 14-byte header
    mov word [edi], 0x0100          ; htype Ethernet (big-endian)
    mov word [edi + 2], 0x0008      ; ptype IPv4
    mov byte [edi + 4], 6
    mov byte [edi + 5], 4
    mov ax, [arp_oper]
    xchg ah, al
    mov [edi + 6], ax               ; operation (big-endian)
    lea edi, [edi + 8]
    mov esi, nic_mac                ; sender hardware address
    mov ecx, 6
    rep movsb
    mov eax, [my_ip]                ; sender protocol address
    stosd
    mov esi, arp_tha                ; target hardware address (0 for a request)
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
    mov eax, [arp_tip]              ; target protocol address
    stosd
    mov esi, NET_PKT
    mov ecx, ETH_HLEN + 28
    call net_tx_frame
    popad
    ret

; arp_handle: ESI = frame, ECX = length. Learns the sender and answers
; requests for our IP.
arp_handle:
    pushad
    cmp ecx, ETH_HLEN + 28
    jb .done
    mov ax, [esi + 12]              ; ethertype
    cmp ax, (ET_ARP >> 8) | ((ET_ARP & 0xFF) << 8)
    jne .done
    lea ebx, [esi + ETH_HLEN]
    mov eax, [ebx + 14]             ; sender protocol address
    test eax, eax
    jz .reply_check
    lea esi, [ebx + 8]              ; sender hardware address
    push ebx
    call arp_insert
    pop ebx
.reply_check:
    cmp word [ebx + 6], 0x0200      ; operation = request? (big-endian 1)
    jne .maybe_req
    jmp .done                       ; it was a reply: nothing to answer
.maybe_req:
    cmp word [ebx + 6], 0x0100      ; request
    jne .done
    mov eax, [ebx + 24]             ; target protocol address
    cmp eax, [my_ip]
    jne .done
    mov eax, [ebx + 14]             ; answer to the sender
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

; arp_resolve: EAX = IP -> EDI = MAC pointer, CF=1 on failure
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
