; =============================================================================
;  net_dhcp.asm - DHCP client: ask the network for an address
;
;  The usual four steps: DISCOVER -> OFFER -> REQUEST -> ACK. The reply tells
;  us our IP, the subnet mask, the gateway and a DNS server.
; =============================================================================
NET_DHCP    equ NET_BUF + 0x7000        ; build the BOOTP/DHCP message here
DHCP_SPORT  equ 68
DHCP_DPORT  equ 67

section .bss
alignb 4
dhcp_offered    resd 1
dhcp_msglen     resd 1

section .text

; dhcp_make_xid: a fresh transaction id in dhcp_xid
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

; dhcp_build: AL = message type (1 DISCOVER, 3 REQUEST). Builds NET_DHCP and
; returns ECX = its length.
dhcp_build:
    pushad
    mov edi, NET_DHCP
    mov ecx, 300 / 4                ; zero the fixed area + room for options
    push eax
    xor eax, eax
    rep stosd
    pop eax
    mov edi, NET_DHCP
    mov byte [edi + 0], 1           ; op = BOOTREQUEST
    mov byte [edi + 1], 1           ; htype = Ethernet
    mov byte [edi + 2], 6           ; hlen
    mov edx, [dhcp_xid]
    mov [edi + 4], edx
    mov word [edi + 10], 0x0080     ; flags: broadcast (big-endian 0x8000)
    mov esi, nic_mac                ; chaddr = our MAC
    push eax
    lea edi, [edi + 28]
    mov ecx, 6
    rep movsb
    pop eax
    mov edi, NET_DHCP + 236
    mov dword [edi], 0x63538263     ; magic cookie 63 82 53 63
    add edi, 4
    mov byte [edi], 53              ; option 53: message type
    mov byte [edi + 1], 1
    mov [edi + 2], al
    add edi, 3
    cmp al, 3                       ; REQUEST adds the chosen IP + server id
    jne .params
    mov byte [edi], 50              ; option 50: requested IP
    mov byte [edi + 1], 4
    mov eax, [dhcp_offered]
    mov [edi + 2], eax
    add edi, 6
    mov byte [edi], 54              ; option 54: DHCP server id
    mov byte [edi + 1], 4
    mov eax, [dhcp_server]
    mov [edi + 2], eax
    add edi, 6
.params:
    mov byte [edi], 55              ; option 55: parameter request list
    mov byte [edi + 1], 3
    mov byte [edi + 2], 1           ; subnet mask
    mov byte [edi + 3], 3           ; router
    mov byte [edi + 4], 6           ; DNS server
    add edi, 5
    mov byte [edi], 255             ; end
    inc edi
    sub edi, NET_DHCP
    mov [dhcp_msglen], edi
    popad
    mov ecx, [dhcp_msglen]
    ret

; dhcp_find_opt: ESI = BOOTP message, ECX = length, AL = option code
; -> EDI = value pointer, AH = length, CF=1 if not present
dhcp_find_opt:
    push ebx
    push ecx
    push edx
    lea ebx, [esi + 240]            ; options start after the cookie
    lea edx, [esi + ecx]
.scan:
    cmp ebx, edx
    jae .none
    mov ah, [ebx]
    cmp ah, 255
    je .none
    cmp ah, 0                       ; pad
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

; dhcp_msgtype: ESI = message, ECX = length -> AL = DHCP type, CF=1 if absent
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

; dhcp_configure: run the exchange. CF=0 and my_ip/... set; CF=1 (ESI = msg)
; on failure.
dhcp_configure:
    pushad
    mov dword [my_ip], 0
    mov dword [my_mask], 0
    mov dword [gw_ip], 0
    call dhcp_make_xid
    mov ebp, 4                      ; a few whole attempts
.attempt:
    mov al, 1                       ; DISCOVER
    call dhcp_build
    mov eax, 0xFFFFFFFF
    mov bx, DHCP_DPORT
    mov dx, DHCP_SPORT
    mov esi, NET_DHCP
    call udp_send
    mov eax, [ticks]
    add eax, 100                    ; wait ~1 s for an OFFER
    mov dx, DHCP_SPORT
    call udp_wait
    jc .retry
    mov eax, [dhcp_xid]             ; xid must match ours
    cmp [esi + 4], eax
    jne .retry
    call dhcp_msgtype
    cmp al, 2                       ; OFFER?
    jne .retry
    mov eax, [esi + 16]             ; yiaddr
    mov [dhcp_offered], eax
    push esi
    mov al, 54
    call dhcp_find_opt
    jc .no_server
    mov eax, [edi]
    mov [dhcp_server], eax
.no_server:
    pop esi

    mov al, 3                       ; REQUEST
    call dhcp_build
    mov eax, 0xFFFFFFFF
    mov bx, DHCP_DPORT
    mov dx, DHCP_SPORT
    mov esi, NET_DHCP
    call udp_send
    mov eax, [ticks]
    add eax, 100
    mov dx, DHCP_SPORT
    call udp_wait
    jc .retry
    mov eax, [dhcp_xid]
    cmp [esi + 4], eax
    jne .retry
    call dhcp_msgtype
    cmp al, 5                       ; ACK?
    jne .retry
    mov eax, [esi + 16]             ; our address
    mov [my_ip], eax
    mov [dhcp_msglen], ecx
    push esi
    mov al, 1                       ; subnet mask
    call dhcp_find_opt
    jc .def_mask
    mov eax, [edi]
    mov [my_mask], eax
    jmp .got_mask
.def_mask:
    mov dword [my_mask], 0x00FFFFFF ; 255.255.255.0
.got_mask:
    mov esi, [esp]
    mov ecx, [dhcp_msglen]
    mov al, 3                       ; router
    call dhcp_find_opt
    jc .no_gw
    mov eax, [edi]
    mov [gw_ip], eax
.no_gw:
    mov esi, [esp]
    mov ecx, [dhcp_msglen]
    mov al, 6                       ; DNS server
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
