TCP_FIN     equ 0x01
TCP_SYN     equ 0x02
TCP_RST     equ 0x04
TCP_PSH     equ 0x08
TCP_ACK     equ 0x10

NET_TCPRX   equ NET_BUF + 0x8000

section .bss
alignb 4
tcp_dst_ip      resd 1
tcp_dst_port    resw 1
tcp_src_port    resw 1
alignb 4
tcp_snd_nxt     resd 1
tcp_rcv_nxt     resd 1
tcp_rx_seq      resd 1
tcp_rx_ack      resd 1
tcp_rx_flags    resb 1
alignb 4
tcp_deadline    resd 1
pkg_len         resd 1
http_status     resd 1
http_date       resb 40
tcp_pseudo      resb 12

section .text

checksum_add:
    push eax
    push esi
    push ecx
.l: cmp ecx, 2
    jb .tail
    movzx eax, word [esi]
    xchg ah, al
    add edx, eax
    add esi, 2
    sub ecx, 2
    jmp .l
.tail:
    test ecx, ecx
    jz .done
    movzx eax, byte [esi]
    shl eax, 8
    add edx, eax
.done:
    pop ecx
    pop esi
    pop eax
    ret

checksum_fold:
    mov eax, edx
    shr eax, 16
    and edx, 0xFFFF
    add edx, eax
    mov eax, edx
    shr eax, 16
    add edx, eax
    mov eax, edx
    not eax
    and eax, 0xFFFF
    ret

tcp_send_seg:
    pushad
    mov edi, NET_TXP
    mov bx, [tcp_src_port]
    xchg bh, bl
    mov [edi], bx
    mov bx, [tcp_dst_port]
    xchg bh, bl
    mov [edi + 2], bx
    mov ebx, [tcp_snd_nxt]
    bswap ebx
    mov [edi + 4], ebx
    mov ebx, [tcp_rcv_nxt]
    bswap ebx
    mov [edi + 8], ebx
    mov byte [edi + 12], 0x50
    mov [edi + 13], al
    mov word [edi + 14], 0x0020
    mov word [edi + 16], 0
    mov word [edi + 18], 0
    push ecx
    lea edi, [edi + 20]
    rep movsb
    pop ecx
    lea eax, [ecx + 20]
    mov [tcp_seg_len], eax

    mov eax, [my_ip]
    mov [tcp_pseudo], eax
    mov eax, [tcp_dst_ip]
    mov [tcp_pseudo + 4], eax
    mov byte [tcp_pseudo + 8], 0
    mov byte [tcp_pseudo + 9], IPPROTO_TCP
    mov eax, [tcp_seg_len]
    xchg ah, al
    mov [tcp_pseudo + 10], ax
    xor edx, edx
    mov esi, tcp_pseudo
    mov ecx, 12
    call checksum_add
    mov esi, NET_TXP
    mov ecx, [tcp_seg_len]
    call checksum_add
    call checksum_fold
    xchg ah, al
    mov [NET_TXP + 16], ax
    mov eax, [tcp_dst_ip]
    mov bl, IPPROTO_TCP
    mov esi, NET_TXP
    mov ecx, [tcp_seg_len]
    call ip_send
    popad
    ret

section .bss
tcp_seg_len resd 1
section .text

tcp_wait:
    push ebx
    mov [tcp_deadline], eax
.loop:
    mov eax, [tcp_deadline]
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
    cmp byte [ebx + 9], IPPROTO_TCP
    jne .loop
    movzx edx, word [ebx + 2]
    xchg dh, dl
    lea esi, [ebx + eax]
    sub edx, eax
    mov ax, [esi + 2]
    xchg ah, al
    cmp ax, [tcp_src_port]
    jne .loop
    mov eax, [esi + 4]
    bswap eax
    mov [tcp_rx_seq], eax
    mov eax, [esi + 8]
    bswap eax
    mov [tcp_rx_ack], eax
    mov al, [esi + 13]
    mov [tcp_rx_flags], al
    movzx ecx, byte [esi + 12]
    shr ecx, 4
    shl ecx, 2
    sub edx, ecx
    lea esi, [esi + ecx]
    mov ecx, edx
    pop ebx
    clc
    ret
.timeout:
    pop ebx
    stc
    ret

tcp_connect:
    pushad
    mov [tcp_dst_ip], eax
    mov [tcp_dst_port], bx
    mov eax, [ticks]
    and eax, 0x0FFF
    add eax, EPHEMERAL
    mov [tcp_src_port], ax
    rdtsc
    mov [tcp_snd_nxt], eax
    mov dword [tcp_rcv_nxt], 0
    mov al, TCP_SYN
    xor ecx, ecx
    call tcp_send_seg
    mov eax, [ticks]
    add eax, 200
    call tcp_wait
    jc .fail
    test byte [tcp_rx_flags], TCP_RST
    jnz .fail
    mov al, TCP_SYN | TCP_ACK
    and al, [tcp_rx_flags]
    cmp al, TCP_SYN | TCP_ACK
    jne .fail
    mov eax, [tcp_rx_seq]
    inc eax
    mov [tcp_rcv_nxt], eax
    inc dword [tcp_snd_nxt]
    mov al, TCP_ACK
    xor ecx, ecx
    call tcp_send_seg
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

tcp_send_all:
    push eax
    mov al, TCP_PSH | TCP_ACK
    call tcp_send_seg
    add [tcp_snd_nxt], ecx
    pop eax
    ret

tcp_recv_all:
    pushad
    mov dword [pkg_len], 0
.loop:
    mov eax, [ticks]
    add eax, 500
    call tcp_wait
    jc .done
    test byte [tcp_rx_flags], TCP_RST
    jnz .done
    jecxz .check_fin
    mov eax, [tcp_rx_seq]
    cmp eax, [tcp_rcv_nxt]
    jne .reack
    mov edi, [pkg_len]
    mov ebx, PKG_BUF_SIZE - 1
    sub ebx, edi
    cmp ecx, ebx
    jbe .fits
    mov ecx, ebx
.fits:
    add [tcp_rcv_nxt], ecx
    push ecx
    lea edi, [PKG_BUF + edi]
    rep movsb
    pop ecx
    add [pkg_len], ecx
.reack:
    mov al, TCP_ACK
    xor ecx, ecx
    call tcp_send_seg
.check_fin:
    test byte [tcp_rx_flags], TCP_FIN
    jz .loop
    inc dword [tcp_rcv_nxt]
    mov al, TCP_ACK
    xor ecx, ecx
    call tcp_send_seg
    mov al, TCP_FIN | TCP_ACK
    xor ecx, ecx
    call tcp_send_seg
    inc dword [tcp_snd_nxt]
.done:
    mov edi, [pkg_len]
    mov byte [PKG_BUF + edi], 0
    popad
    ret

http_get:
    pushad
    mov [http_req_host], esi
    mov [http_req_path], edi
    call tcp_connect
    jc .fail
    mov edi, SCRATCH
    mov esi, http_get_str
    call str_copy_noterm
    mov esi, [http_req_path]
    call str_copy_noterm
    mov esi, http_ver_str
    call str_copy_noterm
    mov esi, [http_req_host]
    call str_copy_noterm
    mov esi, http_tail_str
    call str_copy_noterm
    mov ecx, edi
    sub ecx, SCRATCH
    mov esi, SCRATCH
    call tcp_send_all
    call tcp_recv_all
    call http_parse
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

str_copy_noterm:
    push eax
.l: mov al, [esi]
    test al, al
    jz .e
    mov [edi], al
    inc edi
    inc esi
    jmp .l
.e: pop eax
    ret

http_parse:
    pushad
    mov dword [http_status], 0
    mov byte [http_date], 0
    mov esi, PKG_BUF
    mov ecx, [pkg_len]
    cmp ecx, 12
    jb .no_headers
.space:
    cmp byte [esi], ' '
    je .code
    inc esi
    dec ecx
    cmp ecx, 4
    jb .no_headers
    jmp .space
.code:
    inc esi
    movzx eax, byte [esi]
    sub al, '0'
    cmp al, 9
    ja .scan_headers
    imul eax, 100
    movzx ebx, byte [esi + 1]
    sub bl, '0'
    imul ebx, 10
    add eax, ebx
    movzx ebx, byte [esi + 2]
    sub bl, '0'
    add eax, ebx
    mov [http_status], eax
.scan_headers:
    mov esi, PKG_BUF
    mov ecx, [pkg_len]
.hline:
    mov edi, http_date_hdr
    push esi
    push ecx
    call line_prefix_ci
    pop ecx
    pop esi
    jc .not_date
    lea edi, [esi + 5]
    cmp byte [edi], ' '
    jne .copy_date
    inc edi
.copy_date:
    mov ebx, http_date
.cd: mov al, [edi]
    cmp al, 13
    je .cd_done
    cmp al, 10
    je .cd_done
    test al, al
    jz .cd_done
    mov [ebx], al
    inc ebx
    inc edi
    cmp ebx, http_date + 38
    jb .cd
.cd_done:
    mov byte [ebx], 0
.not_date:
    call next_line
    jc .no_body
    cmp byte [esi], 13
    je .body_here
    cmp byte [esi], 10
    je .body_here
    test ecx, ecx
    jnz .hline
.no_body:
    mov dword [pkg_len], 0
    jmp .done
.body_here:
    cmp byte [esi], 13
    jne .lf
    inc esi
    dec ecx
.lf:
    cmp byte [esi], 10
    jne .have_body
    inc esi
    dec ecx
.have_body:
    mov edi, PKG_BUF
    mov [pkg_len], ecx
    jecxz .done
    rep movsb
.done:
    mov edi, [pkg_len]
    mov byte [PKG_BUF + edi], 0
    popad
    ret
.no_headers:
    mov dword [pkg_len], 0
    popad
    ret

line_prefix_ci:
    push eax
    push ebx
.l: mov al, [edi]
    test al, al
    jz .yes
    mov bl, [esi]
    call to_lower
    xchg al, bl
    call to_lower
    cmp al, bl
    jne .no
    inc esi
    inc edi
    jmp .l
.yes:
    pop ebx
    pop eax
    clc
    ret
.no:
    pop ebx
    pop eax
    stc
    ret

next_line:
    jecxz .end
.l: mov al, [esi]
    inc esi
    dec ecx
    cmp al, 10
    je .ok
    jecxz .end
    jmp .l
.ok:
    clc
    ret
.end:
    stc
    ret

http_time:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    mov [ht_host], esi
    call dns_resolve
    jc .fail
    mov [ht_ip], eax
    mov eax, [ht_ip]
    mov bx, 80
    mov esi, [ht_host]
    mov edi, http_root_path
    call http_get
    jc .fail
    cmp byte [http_date], 0
    je .fail
    mov esi, http_date
    call http_date_parse
    jc .fail
    mov [ht_epoch], eax
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    mov eax, [ht_epoch]
    clc
    ret
.fail:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    stc
    ret

section .bss
alignb 4
ht_host     resd 1
ht_ip       resd 1
ht_epoch    resd 1
section .text

http_date_parse:
    push ebx
    push ecx
    push edx
    push edi
    push esi
.to_space:
    mov al, [esi]
    test al, al
    jz .bad
    cmp al, ' '
    je .after_day_name
    inc esi
    jmp .to_space
.after_day_name:
    call .skip_spaces
    call parse_uint_partial
    jc .bad
    cmp eax, 31
    ja .bad
    mov [rtc_day], al
    call .skip_spaces
    mov edi, month_tab
    xor ebx, ebx
.mloop:
    cmp ebx, 12
    jae .bad
    call .month_match
    je .month_found
    add edi, 3
    inc ebx
    jmp .mloop
.month_found:
    inc ebx
    mov [rtc_month], bl
    add esi, 3
    call .skip_spaces
    call parse_uint_partial
    jc .bad
    mov [rtc_year], ax
    call .skip_spaces
    call parse_uint_partial
    jc .bad
    mov [rtc_hour], al
    cmp byte [esi], ':'
    jne .bad
    inc esi
    call parse_uint_partial
    jc .bad
    mov [rtc_min], al
    cmp byte [esi], ':'
    jne .bad
    inc esi
    call parse_uint_partial
    jc .bad
    mov [rtc_sec], al
    call datetime_to_epoch
    mov [et_days], eax
    pop esi
    pop edi
    pop edx
    pop ecx
    pop ebx
    mov eax, [et_days]
    clc
    ret
.bad:
    pop esi
    pop edi
    pop edx
    pop ecx
    pop ebx
    stc
    ret
.skip_spaces:
    cmp byte [esi], ' '
    jne .sp_done
    inc esi
    jmp .skip_spaces
.sp_done:
    ret

.month_match:
    push eax
    push ebx
    push esi
    push edi
    mov ecx, 3
.mm: mov al, [esi]
    call to_lower
    mov bl, al
    mov al, [edi]
    call to_lower
    cmp al, bl
    jne .mm_no
    inc esi
    inc edi
    dec ecx
    jnz .mm
    pop edi
    pop esi
    pop ebx
    pop eax
    cmp eax, eax
    ret
.mm_no:
    pop edi
    pop esi
    pop ebx
    pop eax
    ret

section .data
http_root_path  db "/", 0
month_tab       db "JanFebMarAprMayJunJulAugSepOctNovDec"
http_get_str    db "GET ", 0
http_ver_str    db " HTTP/1.0", 13, 10, "Host: ", 0
http_tail_str   db 13, 10, "User-Agent: MOOS", 13, 10, "Connection: close", 13, 10, 13, 10, 0
http_date_hdr   db "date:", 0

section .bss
alignb 4
http_req_host   resd 1
http_req_path   resd 1

section .text
