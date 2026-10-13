; =============================================================================
;  net_dns.asm - DNS name lookup, IPv4 text parsing, and the NTP time query
; =============================================================================
NET_DNS     equ NET_BUF + 0x7800        ; build a DNS / NTP packet here
EPHEMERAL   equ 0xC000                   ; our source ports start here

section .bss
alignb 4
dns_port    resw 1
alignb 4
ntp_server  resd 1
ntp_tries   resd 1

section .data
ntp_name    db "pool.ntp.org", 0

section .text

; parse_ipv4: ESI = text -> EAX = IP in network byte order, CF=1 if not a
; valid dotted quad (ESI is left unchanged on success)
parse_ipv4:
    push ebx
    push ecx
    push edx
    push esi
    xor ebx, ebx                    ; result, built byte by byte
    xor ecx, ecx                    ; dots seen
.part:
    xor edx, edx                    ; current number
    xor ah, ah                      ; digit count
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
    test ah, ah                     ; at least one digit?
    jz .bad
    shr ebx, 8
    shl edx, 24
    or ebx, edx                     ; append this octet (builds net order)
    mov al, [esi]
    cmp al, '.'
    jne .end
    inc ecx
    cmp ecx, 3
    ja .bad
    inc esi
    jmp .part
.end:
    cmp al, 0                       ; must end the string here
    jne .bad
    cmp ecx, 3                      ; exactly three dots
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

; dns_encode_name: ESI = hostname, EDI = output. Writes DNS label form
; (3www6google3com0). Returns EDI past the terminating 0.
dns_encode_name:
    push eax
    push ebx
.label:
    mov ebx, edi                    ; remember where the length byte goes
    inc edi
    xor al, al                      ; length so far
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

; dns_resolve: ESI = hostname -> EAX = IP (network order), CF=1 on failure
dns_resolve:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    call parse_ipv4                 ; already a numeric address?
    jnc .numeric
    cmp byte [net_up], 0
    je .fail
    mov eax, [ticks]                ; a source port
    and eax, 0x0FFF
    add eax, EPHEMERAL
    mov [dns_port], ax
    mov edi, NET_DNS                ; build the query
    mov eax, [dhcp_xid]
    mov [edi], ax                   ; id
    mov word [edi + 2], 0x0001      ; flags: recursion desired (big-endian)
    mov word [edi + 4], 0x0100      ; QDCOUNT = 1
    mov dword [edi + 6], 0
    mov word [edi + 10], 0
    add edi, 12
    mov esi, [esp + 4]              ; hostname
    call dns_encode_name
    mov word [edi], 0x0100          ; QTYPE = A
    mov word [edi + 2], 0x0100      ; QCLASS = IN
    add edi, 4
    mov ecx, edi
    sub ecx, NET_DNS                ; query length
    mov ebx, 2                      ; a couple of tries
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
    call dns_parse_answer           ; ESI/ECX = reply -> EAX = IP, CF
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

; dns_parse_answer: ESI = reply, ECX = length -> EAX = first A record's IP,
; CF=1 if none
dns_parse_answer:
    push ebx
    push ecx
    push edx
    push esi
    cmp ecx, 12
    jb .none
    movzx eax, word [esi + 6]       ; ANCOUNT (big-endian)
    xchg ah, al
    test eax, eax
    jz .none
    mov edx, eax                    ; answers left
    lea ebx, [esi + 12]             ; skip the header
    call .skip_name                 ; skip the question's name
    add ebx, 4                      ; QTYPE + QCLASS
.answer:
    test edx, edx
    jz .none
    call .skip_name
    movzx eax, word [ebx]           ; type
    xchg ah, al
    movzx ecx, word [ebx + 8]       ; RDLENGTH
    xchg ch, cl
    cmp eax, 1                      ; A record?
    jne .skip
    cmp ecx, 4
    jne .skip
    mov eax, [ebx + 10]             ; RDATA = the IP
    pop esi
    pop edx
    pop ecx
    pop ebx
    clc
    ret
.skip:
    lea ebx, [ebx + ecx + 10]       ; type(2)+class(2)+ttl(4)+rdlen(2)+rdata
    dec edx
    jmp .answer
.none:
    pop esi
    pop edx
    pop ecx
    pop ebx
    stc
    ret
; .skip_name: EBX = name; advance EBX past it (handles 0xC0 compression)
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
    add ebx, 2                      ; a 2-byte pointer ends the name
    ret
.name_done:
    inc ebx
    ret

; ntp_query: resolve the configured time server and ask it the time.
; -> EAX = seconds since 1 Jan 1970 (UTC), CF=1 on failure
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

; ntp_query_addr: EAX = server IP -> EAX = Unix seconds, CF=1 on failure
ntp_query_addr:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    mov [ntp_server], eax
    mov edi, NET_DNS                ; build the 48-byte request
    xor eax, eax
    mov ecx, 12
    rep stosd
    mov byte [NET_DNS], 0x1B        ; LI=0, VN=3, Mode=3 (client)
    mov eax, [ticks]
    and eax, 0x0FFF
    add eax, EPHEMERAL
    mov [dns_port], ax
    mov dword [ntp_tries], 3        ; (kept in memory: bx below is the port)
.try:
    mov esi, NET_DNS
    mov eax, [ntp_server]
    mov bx, 123
    mov dx, [dns_port]
    call udp_send
    mov eax, [ticks]
    add eax, 200                    ; up to ~2 s
    mov dx, [dns_port]
    call udp_wait
    jc .next
    cmp ecx, 48
    jb .next
    mov eax, [esi + 40]             ; transmit timestamp, seconds (big-endian)
    bswap eax
    sub eax, 2208988800            ; 1900 -> 1970 epoch
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
