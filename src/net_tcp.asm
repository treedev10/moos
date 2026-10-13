; =============================================================================
;  net_tcp.asm - a tiny TCP client and an HTTP GET
;
;  Just enough TCP to talk to one server at a time: connect, send a request,
;  read the whole reply, close. SLIRP (and a normal LAN to a nearby server)
;  delivers segments in order without loss, so there is no reordering buffer
;  or fast retransmit - only an overall timeout and simple ACKing.
;
;  Used for:
;    - the package manager (apt): download a file over HTTP
;    - clock sync over HTTP: read the server's "Date:" header (works even
;      where NTP's UDP port 123 is blocked)
; =============================================================================
TCP_FIN     equ 0x01
TCP_SYN     equ 0x02
TCP_RST     equ 0x04
TCP_PSH     equ 0x08
TCP_ACK     equ 0x10

NET_TCPRX   equ NET_BUF + 0x8000        ; a received TCP frame copy (unused)

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
pkg_len         resd 1              ; bytes received into PKG_BUF
http_status     resd 1
http_date       resb 40
http_location   resb 512            ; Location: (where a redirect points)
http_ctype      resb 64             ; Content-Type:
http_tenc       resb 32             ; Transfer-Encoding:
tcp_pseudo      resb 12
alignb 4
tcp_dst         resd 1              ; where tcp_pump puts received bytes
tcp_dst_len     resd 1              ; bytes there so far
tcp_dst_cap     resd 1              ; room in that buffer
tcp_origlen     resd 1
tcp_closed      resb 1              ; peer sent FIN or RST
tcp_fin_sent    resb 1
alignb 4
hc_hdr_end      resd 1              ; http_is_complete: end of headers (0 = not yet)
hc_clen         resd 1              ; Content-Length, or -1

section .text

; ------------------------------------------------------------- checksums
; checksum_add: EDX = running sum, ESI = data, ECX = length (adds big-endian
; 16-bit words). EDX updated.
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

; checksum_fold: EDX = 32-bit sum -> AX = folded ones-complement checksum
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

; ---------------------------------------------------------- send a segment
; tcp_send_seg: AL = flags, ESI = data, ECX = data length. Builds the segment
; in NET_TXP (with checksum) and sends it. snd_nxt is advanced by the caller.
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
    mov byte [edi + 12], 0x50           ; data offset = 5 words (20 bytes)
    mov [edi + 13], al                  ; flags
    mov word [edi + 14], 0x0020         ; window = 8192 (big-endian)
    mov word [edi + 16], 0              ; checksum (filled below)
    mov word [edi + 18], 0              ; urgent pointer
    push ecx
    lea edi, [edi + 20]
    rep movsb                           ; copy the data
    pop ecx
    lea eax, [ecx + 20]                 ; TCP length
    mov [tcp_seg_len], eax
    ; pseudo-header for the checksum
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
tcp_syn_try resd 1
section .text

; tcp_wait: wait for a TCP segment for our connection. EAX = deadline (ticks).
; -> ESI = TCP header, ECX = payload length; fills tcp_rx_seq/ack/flags.
; Services ARP while waiting. CF=1 on timeout.
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
    cmp ax, 0x0608                      ; ARP
    jne .not_arp
    call arp_handle
    jmp .loop
.not_arp:
    cmp ax, 0x0008                      ; IPv4
    jne .loop
    lea ebx, [esi + ETH_HLEN]
    movzx eax, byte [ebx]
    and al, 0x0F
    cmp al, 5
    jb .loop
    shl eax, 2                          ; IP header length
    cmp byte [ebx + 9], IPPROTO_TCP
    jne .loop
    movzx edx, word [ebx + 2]           ; IP total length
    xchg dh, dl
    lea esi, [ebx + eax]                ; TCP header
    sub edx, eax                        ; TCP segment length
    mov ax, [esi + 2]                   ; dest port = our source port?
    xchg ah, al
    cmp ax, [tcp_src_port]
    jne .loop
    mov eax, [esi + 4]                  ; their seq
    bswap eax
    mov [tcp_rx_seq], eax
    mov eax, [esi + 8]                  ; their ack
    bswap eax
    mov [tcp_rx_ack], eax
    mov al, [esi + 13]
    mov [tcp_rx_flags], al
    movzx ecx, byte [esi + 12]          ; data offset
    shr ecx, 4
    shl ecx, 2                          ; TCP header length
    sub edx, ecx                        ; payload length
    lea esi, [esi + ecx]                ; payload
    mov ecx, edx
    pop ebx
    clc
    ret
.timeout:
    pop ebx
    stc
    ret

; tcp_connect: EAX = server IP, BX = port -> CF=0 connected, CF=1 failed
tcp_connect:
    pushad
    mov [tcp_dst_ip], eax
    mov [tcp_dst_port], bx
    mov eax, [ticks]
    and eax, 0x0FFF
    add eax, EPHEMERAL
    mov [tcp_src_port], ax
    rdtsc                               ; our initial sequence number
    mov [tcp_snd_nxt], eax
    mov dword [tcp_rcv_nxt], 0
    mov byte [tcp_closed], 0
    mov byte [tcp_fin_sent], 0
    mov dword [tcp_syn_try], 3          ; a lost SYN is sent again (3 tries)
.syn:
    mov al, TCP_SYN                     ; send SYN
    xor ecx, ecx
    call tcp_send_seg
    mov eax, [ticks]
    add eax, 150
    call tcp_wait
    jnc .answer
    dec dword [tcp_syn_try]
    jnz .syn
    jmp .fail
.answer:
    test byte [tcp_rx_flags], TCP_RST
    jnz .fail
    mov al, TCP_SYN | TCP_ACK
    and al, [tcp_rx_flags]
    cmp al, TCP_SYN | TCP_ACK           ; SYN-ACK?
    jne .fail
    mov eax, [tcp_rx_seq]               ; expect their_seq + 1
    inc eax
    mov [tcp_rcv_nxt], eax
    inc dword [tcp_snd_nxt]             ; our SYN consumed one sequence
    mov al, TCP_ACK                     ; complete the handshake
    xor ecx, ecx
    call tcp_send_seg
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; tcp_send_all: ESI = data, ECX = length. Sends it in segments of at most
; 536 bytes (the smallest MSS every host accepts) and advances snd_nxt.
tcp_send_all:
    pushad
.l: test ecx, ecx
    jz .done
    mov edx, ecx
    cmp edx, 536
    jbe .n
    mov edx, 536
.n: push ecx
    mov ecx, edx
    mov al, TCP_PSH | TCP_ACK
    call tcp_send_seg
    add [tcp_snd_nxt], ecx
    pop ecx
    add esi, edx
    sub ecx, edx
    jmp .l
.done:
    popad
    ret

; tcp_set_dst: EDI = buffer, ECX = capacity. Received data goes there.
tcp_set_dst:
    mov [tcp_dst], edi
    mov [tcp_dst_cap], ecx
    mov dword [tcp_dst_len], 0
    ret

; tcp_pump: EAX = deadline (ticks). Wait for one segment of our connection
; and handle it: in-order data is appended to the tcp_dst buffer and ACKed; a
; FIN or RST sets tcp_closed. CF=1 if nothing arrived before the deadline.
tcp_pump:
    pushad
    call tcp_wait
    jc .timeout
    test byte [tcp_rx_flags], TCP_RST
    jnz .rst
    mov [tcp_origlen], ecx
    jecxz .check_fin
    mov eax, [tcp_rx_seq]               ; in-order data only
    cmp eax, [tcp_rcv_nxt]
    jne .reack
    mov edi, [tcp_dst_len]
    mov ebx, [tcp_dst_cap]
    sub ebx, edi
    cmp ecx, ebx                        ; take what fits (rest is resent)
    jbe .fits
    mov ecx, ebx
.fits:
    add [tcp_rcv_nxt], ecx
    add [tcp_dst_len], ecx
    add edi, [tcp_dst]
    rep movsb
.reack:
    mov al, TCP_ACK                     ; acknowledge up to tcp_rcv_nxt
    xor ecx, ecx
    call tcp_send_seg
.check_fin:
    test byte [tcp_rx_flags], TCP_FIN
    jz .ok
    mov eax, [tcp_rx_seq]               ; only once all data before it is in
    add eax, [tcp_origlen]
    cmp eax, [tcp_rcv_nxt]
    jne .ok
    inc dword [tcp_rcv_nxt]             ; FIN takes one sequence number
    mov al, TCP_ACK
    xor ecx, ecx
    call tcp_send_seg
    mov byte [tcp_closed], 1
    call tcp_close
.ok:
    popad
    clc
    ret
.rst:
    mov byte [tcp_closed], 1
    mov byte [tcp_fin_sent], 1          ; nothing more to say after a reset
    popad
    clc
    ret
.timeout:
    popad
    stc
    ret

; tcp_close: send our FIN (once)
tcp_close:
    cmp byte [tcp_fin_sent], 0
    jne .r
    pushad
    mov byte [tcp_fin_sent], 1
    mov al, TCP_FIN | TCP_ACK
    xor ecx, ecx
    call tcp_send_seg
    inc dword [tcp_snd_nxt]
    popad
.r: ret

; tcp_recv_all: read the reply into PKG_BUF (up to PKG_BUF_SIZE-1) until the
; server closes, ~5 s pass with nothing new, or the HTTP response is complete
; (Content-Length reached). Sets pkg_len.
tcp_recv_all:
    pushad
    mov edi, PKG_BUF
    mov ecx, PKG_BUF_SIZE - 1
    call tcp_set_dst
    call http_complete_reset
.loop:
    mov eax, [ticks]
    add eax, 500
    call tcp_pump
    jc .done
    mov esi, PKG_BUF
    mov ecx, [tcp_dst_len]
    call http_is_complete
    jnc .done
    cmp byte [tcp_closed], 0
    je .loop
.done:
    call tcp_close
    mov edi, [tcp_dst_len]
    mov [pkg_len], edi
    mov byte [PKG_BUF + edi], 0
    popad
    ret

; http_complete_reset: forget what http_is_complete learned
http_complete_reset:
    mov dword [hc_hdr_end], 0
    mov dword [hc_clen], -1
    ret

; http_is_complete: ESI = response so far, ECX = its length -> CF=0 if the
; headers are in and a Content-Length's worth of body has arrived.
http_is_complete:
    pushad
    cmp dword [hc_hdr_end], 0
    jne .have_hdr
    xor ebx, ebx                        ; find the blank line
.find:
    lea eax, [ebx + 4]
    cmp eax, ecx
    ja .no
    cmp dword [esi + ebx], 0x0A0D0A0D   ; CR LF CR LF
    je .found
    inc ebx
    jmp .find
.found:
    add ebx, 4
    mov [hc_hdr_end], ebx
    mov edi, esi                        ; look for Content-Length in the headers
    lea edx, [esi + ebx]
.line:
    cmp edi, edx
    jae .have_hdr
    push esi
    mov esi, edi
    push edi
    mov edi, hc_cl_name
    call line_prefix_ci
    mov eax, esi                        ; (ESI now just past the name)
    pop edi
    pop esi
    jc .next_line
.num:                                   ; skip spaces, read the number
    cmp byte [eax], ' '
    jne .digits
    inc eax
    jmp .num
.digits:
    push esi
    mov esi, eax
    call parse_uint_partial
    pop esi
    jc .next_line
    mov [hc_clen], eax
    jmp .have_hdr
.next_line:
    cmp edi, edx
    jae .have_hdr
    cmp byte [edi], 10
    je .nl
    inc edi
    jmp .next_line
.nl:
    inc edi
    jmp .line
.have_hdr:
    mov eax, [hc_clen]
    cmp eax, -1
    je .no
    add eax, [hc_hdr_end]
    cmp ecx, eax
    jb .no
    popad
    clc
    ret
.no:
    popad
    stc
    ret

section .data
hc_cl_name  db "content-length:", 0
section .text

; -------------------------------------------------------------------- HTTP
; http_get: EAX = server IP, BX = port, ESI = Host text, EDI = path.
; Downloads into PKG_BUF (pkg_len set), fills http_status and http_date.
; CF=1 if the connection could not be made.
http_get:
    pushad
    mov [http_req_host], esi
    mov [http_req_path], edi
    call tcp_connect
    jc .fail
    mov edi, SCRATCH                    ; build the request line
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
    sub ecx, SCRATCH                    ; request length
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

; str_copy_noterm: copy ESI to EDI without the terminating 0; EDI advanced
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

; http_parse: read PKG_BUF (the whole response), set http_status, http_date,
; and move the body to the front of PKG_BUF with pkg_len = body length.
http_parse:
    pushad
    mov dword [http_status], 0
    mov byte [http_date], 0
    mov byte [http_location], 0
    mov byte [http_ctype], 0
    mov byte [http_tenc], 0
    mov esi, PKG_BUF                    ; status line: "HTTP/1.x NNN ..."
    mov ecx, [pkg_len]
    cmp ecx, 12
    jb .no_headers
.space:                                 ; find the first space
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
.scan_headers:                          ; find "Date:" and the blank line
    mov esi, PKG_BUF
    mov ecx, [pkg_len]
.hline:
    mov edi, http_date_hdr              ; does this line start with "Date:"?
    push esi
    push ecx
    call line_prefix_ci
    pop ecx
    pop esi
    jc .not_date
    lea edi, [esi + 5]                  ; copy the date value
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
    mov edi, http_loc_hdr               ; a few more headers the browser uses
    mov ebx, http_location
    mov edx, 512
    call hdr_grab
    mov edi, http_ctype_hdr
    mov ebx, http_ctype
    mov edx, 64
    call hdr_grab
    mov edi, http_tenc_hdr
    mov ebx, http_tenc
    mov edx, 32
    call hdr_grab
    call next_line                      ; advance ESI/ECX to the next line
    jc .no_body
    cmp byte [esi], 13                  ; blank line = end of headers
    je .body_here
    cmp byte [esi], 10
    je .body_here
    test ecx, ecx
    jnz .hline
.no_body:
    mov dword [pkg_len], 0
    jmp .done
.body_here:                             ; skip the CRLF of the blank line
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
    mov edi, PKG_BUF                    ; move the body to the front
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

; hdr_grab: ESI = a header line, EDI = its name ("location:", lower case),
; EBX = where its value goes, EDX = room there. If the line is that header,
; its value (without leading spaces, up to the end of the line) is copied.
hdr_grab:
    pushad
    call line_prefix_ci
    jc .done
.sp:
    cmp byte [esi], ' '
    jne .copy
    inc esi
    jmp .sp
.copy:
    dec edx                             ; (room for the 0)
.c: mov al, [esi]
    cmp al, 13
    je .end
    cmp al, 10
    je .end
    test al, al
    jz .end
    test edx, edx
    jz .end
    mov [ebx], al
    inc ebx
    inc esi
    dec edx
    jmp .c
.end:
    mov byte [ebx], 0
.done:
    popad
    ret

; line_prefix_ci: ESI = line, EDI = prefix -> CF=0 if the line starts with
; the prefix (case-insensitive)
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

; next_line: ESI/ECX at a line -> advance past the next CRLF. CF=1 at the end.
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

; http_time: ESI = hostname -> EAX = Unix seconds from the server's Date
; header, CF=1 on failure. Works on any web server, even one that answers
; with an error, because every HTTP reply carries a Date.
http_time:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    mov [ht_host], esi
    call dns_resolve                    ; ESI = hostname -> EAX = IP
    jc .fail
    mov [ht_ip], eax
    mov eax, [ht_ip]
    mov bx, 80
    mov esi, [ht_host]                  ; Host: header text
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

; http_date_parse: ESI = "Tue, 13 Oct 2026 00:26:38 GMT" -> EAX = Unix
; seconds, CF=1 if it cannot be read
http_date_parse:
    push ebx
    push ecx
    push edx
    push edi
    push esi
.to_space:                              ; skip the weekday
    mov al, [esi]
    test al, al
    jz .bad
    cmp al, ' '
    je .after_day_name
    inc esi
    jmp .to_space
.after_day_name:
    call .skip_spaces
    call parse_uint_partial             ; day
    jc .bad
    cmp eax, 31
    ja .bad
    mov [rtc_day], al
    call .skip_spaces
    mov edi, month_tab                  ; month name -> number
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
    call parse_uint_partial             ; year
    jc .bad
    mov [rtc_year], ax
    call .skip_spaces
    call parse_uint_partial             ; hour
    jc .bad
    mov [rtc_hour], al
    cmp byte [esi], ':'
    jne .bad
    inc esi
    call parse_uint_partial             ; minute
    jc .bad
    mov [rtc_min], al
    cmp byte [esi], ':'
    jne .bad
    inc esi
    call parse_uint_partial             ; second
    jc .bad
    mov [rtc_sec], al
    call datetime_to_epoch              ; EAX = epoch
    mov [et_days], eax                  ; (stash across the pops)
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
; .month_match: compare [ESI..+2] with [EDI..+2] case-insensitively -> ZF
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
    cmp eax, eax                        ; ZF = 1
    ret
.mm_no:                                 ; ZF = 0 from the cmp that jumped here
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
http_loc_hdr    db "location:", 0
http_ctype_hdr  db "content-type:", 0
http_tenc_hdr   db "transfer-encoding:", 0

section .bss
alignb 4
http_req_host   resd 1
http_req_path   resd 1

section .text
