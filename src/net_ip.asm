; =============================================================================
;  net_ip.asm - IPv4 send, UDP send, and a UDP receive helper
;
;  ip_send picks the next hop (the gateway for anything off our subnet),
;  finds its MAC with ARP, and builds the Ethernet + IP frame.
;  UDP checksums are left 0, which IPv4 allows and SLIRP accepts.
; =============================================================================
NET_TXP     equ NET_BUF + 0x6000        ; build a transport-layer payload here

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

; ip_send: EAX = dst IP, BL = protocol, ESI = payload, ECX = length.
; CF=1 if the next hop's MAC could not be found.
ip_send:
    pushad
    mov [ip_dst], eax
    mov [ip_proto], bl
    mov [ip_payload], esi
    mov [ip_plen], ecx
    cmp eax, 0xFFFFFFFF
    je .resolve
    mov edi, eax                    ; on our subnet?
    and edi, [my_mask]
    mov ebp, [my_ip]
    and ebp, [my_mask]
    cmp edi, ebp
    je .resolve
    mov eax, [gw_ip]                ; off subnet: send to the gateway
.resolve:
    call arp_resolve                ; EDI = next-hop MAC
    jc .fail
    mov esi, edi
    mov edi, NET_PKT
    mov ax, ET_IP
    call eth_build                  ; EDI -> IP header
    mov esi, edi                    ; remember header start
    mov byte [edi], 0x45            ; version 4, header length 5 words
    mov byte [edi + 1], 0
    mov eax, [ip_plen]
    add eax, 20
    xchg ah, al
    mov [edi + 2], ax               ; total length
    mov eax, [ip_ident]
    inc dword [ip_ident]
    xchg ah, al
    mov [edi + 4], ax               ; identification
    mov word [edi + 6], 0           ; no fragmentation
    mov byte [edi + 8], 64          ; TTL
    mov al, [ip_proto]
    mov [edi + 9], al
    mov word [edi + 10], 0          ; checksum placeholder
    mov eax, [my_ip]
    mov [edi + 12], eax
    mov eax, [ip_dst]
    mov [edi + 16], eax
    push esi
    mov ecx, 20
    call ip_checksum                ; AX = header checksum
    pop esi
    xchg ah, al
    mov [esi + 10], ax
    lea edi, [esi + 20]             ; copy the payload after the header
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

; udp_send: EAX = dst IP, BX = dst port, DX = source port, ESI = payload,
; ECX = length (host byte order for the ports)
udp_send:
    pushad
    mov edi, NET_TXP
    push eax                        ; dst IP
    mov ax, dx                      ; source port
    xchg ah, al
    mov [edi], ax
    mov ax, bx                      ; destination port
    xchg ah, al
    mov [edi + 2], ax
    mov eax, ecx
    add eax, 8
    xchg ah, al
    mov [edi + 4], ax               ; UDP length
    mov word [edi + 6], 0           ; no checksum
    push ecx
    lea edi, [edi + 8]
    rep movsb                       ; payload
    pop ecx
    pop eax                         ; dst IP
    add ecx, 8
    mov esi, NET_TXP
    mov bl, IPPROTO_UDP
    call ip_send
    popad
    ret

; udp_wait: DX = our port to match (host order), EAX = deadline (ticks value).
; -> ESI = UDP payload, ECX = payload length, CF=0. ARP is serviced while
; waiting. CF=1 on timeout. Fills udp_from_ip / udp_from_port.
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
    cmp ax, 0x0608                  ; ARP (big-endian 0x0806)
    jne .not_arp
    call arp_handle
    jmp .loop
.not_arp:
    cmp ax, 0x0008                  ; IPv4 (big-endian 0x0800)
    jne .loop
    lea ebx, [esi + ETH_HLEN]
    movzx eax, byte [ebx]           ; header length (words)
    and al, 0x0F
    cmp al, 5
    jb .loop
    shl eax, 2                      ; header length in bytes
    cmp byte [ebx + 9], IPPROTO_UDP
    jne .loop
    lea edx, [ebx + eax]            ; UDP header
    mov ax, [edx + 2]               ; destination port
    xchg ah, al
    cmp ax, [udp_match_port]
    jne .loop
    mov eax, [ebx + 12]             ; remember the sender
    mov [udp_from_ip], eax
    mov ax, [edx]
    xchg ah, al
    mov [udp_from_port], ax
    movzx ecx, word [edx + 4]       ; UDP length
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
