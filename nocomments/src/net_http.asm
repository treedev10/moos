HTTP_HDR    equ NET_STREAM + 0x50000
HDR_MAX     equ 0x8000
HTTP_REQ    equ NET_STREAM + 0x58000
REQ_MAX     equ 0x4000
HTTP_TMP    equ NET_STREAM + 0x74000
TMP_MAX     equ 0x1000
HTTP_URL    equ NET_STREAM + 0x75000
HURL_MAX    equ 0x2000

HEAD_WAIT   equ 2000
BODY_WAIT   equ 2000
HS_STALL    equ 3000
HS_REDIRS   equ 8
COOKIE_ROOM equ 6144

HB_NONE     equ 0
HB_LEN      equ 1
HB_CLOSE    equ 2
HB_CHUNK    equ 3

HCK_SIZE     equ 0
HCK_EXT      equ 1
HCK_DATA     equ 2
HCK_CRLF     equ 3
HCK_TRAIL    equ 4
HCK_TLINE    equ 5
HCK_DONE     equ 6

HS_NONE     equ 0
HS_OPEN     equ 1
HS_DONE     equ 2
HS_ERROR    equ 3

section .bss
alignb 4
rq_method       resd 1
rq_body         resd 1
rq_body_len     resd 1
rq_end          resd 1
rq_len          resd 1
hb_mode         resd 1
hb_left         resd 1

hb_ck           resd 1
hb_size         resd 1
hb_digits       resd 1
hb_pre          resd 1
hb_pre_len      resd 1
hd_len          resd 1
hd_end          resd 1
hd_scan         resd 1
hd_vend         resd 1
hs_redirs       resd 1
hs_last         resd 1
hs_status       resd 1
hs_clen         resd 1
hs_total        resd 1
hs_got          resd 1
http_status     resd 1
http_clen       resd 1
http_total      resd 1
pkg_len         resd 1
rq_over         resb 1
hx_tls          resb 1
hx_up           resb 1
hs_state        resb 1
hb_done         resb 1
http_has_clen   resb 1
http_loc_long   resb 1
url_truncated   resb 1
url_probe       resb 1
http_date       resb 40
http_ctype      resb 128
http_cenc       resb 64
http_tenc       resb 64
http_location   resb 4096

section .data
http_m_get      db "GET ", 0
http_m_post     db "POST ", 0
http_m_head     db "HEAD ", 0
http_s_ver      db " HTTP/1.1", 13, 10, "Host: ", 0
http_s_ua       db "User-Agent: ", 0
http_ua_default db "MOOS/", OS_VERSION, 0
http_s_accept   db "Accept: */*", 13, 10, 0
http_s_enc      db "Accept-Encoding: ", 0
http_s_range    db "Range: bytes=", 0
http_s_ctype    db "Content-Type: ", 0
http_ct_default db "application/x-www-form-urlencoded", 0
http_s_clen     db "Content-Length: ", 0
http_s_close    db "Connection: close", 13, 10, 13, 10, 0
http_s_crlf     db 13, 10, 0
http_s_scheme   db "://", 0
hn_http         db "http/", 0
hn_accept       db "accept:", 0
hn_chunked      db "chunked", 0

hn_clen         db "content-length", 0
hn_ctype        db "content-type", 0
hn_cenc         db "content-encoding", 0
hn_tenc         db "transfer-encoding", 0
hn_loc          db "location", 0
hn_crange       db "content-range", 0
hn_cookie       db "set-cookie", 0
hn_date         db "date", 0
hd_table        dd hn_clen, hd_on_clen
                dd hn_ctype, hd_on_ctype
                dd hn_cenc, hd_on_cenc
                dd hn_tenc, hd_on_tenc
                dd hn_loc, hd_on_loc
                dd hn_crange, hd_on_crange
                dd hn_cookie, hd_on_cookie
                dd hn_date, hd_on_date
                dd 0
he_toobig       db "the request is too large (address, headers and cookies over 16 KB)", 0
he_refused      db "the server refused the connection", 0
he_noanswer     db "the server did not answer", 0
he_send         db "the connection broke while sending the request", 0
he_noreply      db "the server closed the connection without answering", 0
he_reset        db "the server reset the connection", 0
he_lost         db "the connection was lost (no answer to retransmissions)", 0
he_timeout      db "the server did not answer in time", 0
he_bighead      db "the reply's headers are too large (over 32 KB)", 0
he_nothttp      db "the server's reply is not HTTP", 0
he_early        db "the server closed the connection before the whole reply came", 0
he_chunk        db "bad chunked encoding in the reply", 0
he_stalled      db "the download stalled (nothing came for too long)", 0
he_badloc       db "the server redirected to an address MOOS cannot follow", 0
he_broken       db "the connection broke", 0

section .text

hx_send:
    cmp byte [hx_tls], 0
    jne .tls
    jmp tcp_send
.tls:
    pushad
    CCALL tls_write, esi, ecx
    test eax, eax
    popad
    jz .fail
    clc
    ret
.fail:
    stc
    ret

hx_recv:
    mov eax, [hb_pre_len]
    test eax, eax
    jz .net
    push ecx
    push esi
    push edi
    cmp ecx, eax
    jbe .n
    mov ecx, eax
.n: mov eax, ecx
    mov esi, [hb_pre]
    call net_copy
    mov [hb_pre], esi
    sub [hb_pre_len], eax
    pop edi
    pop esi
    pop ecx
    ret
.net:
    cmp byte [hx_up], 0
    je .gone
    call tcp_poll
    cmp byte [hx_tls], 0
    jne .tls
    jmp tcp_recv
.tls:
    push ecx
    push edx
    CCALL tls_recv, edi, ecx
    pop edx
    pop ecx
    ret
.gone:
    mov eax, -2
    ret

hx_broke_msg:
    push eax
    mov eax, he_broken
    cmp byte [hx_tls], 0
    je .tcp
    cmp dword [tls_err], 0
    je .tcp
    mov eax, [tls_err]
    jmp .set
.tcp:
    cmp dword [tcp_err], TE_RESET
    jne .t2
    mov eax, he_reset
.t2:
    cmp dword [tcp_err], TE_TIMEOUT
    jne .set
    mov eax, he_lost
.set:
    mov [url_err], eax
    pop eax
    ret

http_close:
    cmp byte [hx_up], 0
    je .r
    mov byte [hx_up], 0
    pushad
    cmp byte [hx_tls], 0
    je .fin
    CCALL tls_close_notify
.fin:
    call tcp_close
    mov eax, 100
    call tcp_linger
    popad
.r: ret

http_close_quick:
    cmp byte [hx_up], 0
    je .r
    mov byte [hx_up], 0
    pushad
    cmp byte [hx_tls], 0
    je .fin
    CCALL tls_close_notify
.fin:
    call tcp_close
    popad
.r: ret

http_abort:
    cmp byte [hx_up], 0
    je .r
    mov byte [hx_up], 0
    call tcp_abort
.r: ret

http_options:
    push eax
    mov eax, [url_method]
    cmp eax, 2
    jbe .m
    xor eax, eax
.m: mov [rq_method], eax
    xor eax, eax
    mov [rq_body], eax
    mov [rq_body_len], eax
    cmp dword [rq_method], 1
    jne .r
    mov eax, [url_body]
    mov [rq_body], eax
    test eax, eax
    jz .r
    mov eax, [url_body_len]
    mov [rq_body_len], eax
.r: pop eax
    ret

rq_put:
    push ecx
    mov ecx, 0x7FFFFFFF
    call rq_putn
    pop ecx
    ret

rq_putn:
    push eax
    push ecx
    push esi
.l: test ecx, ecx
    jz .e
    mov al, [esi]
    test al, al
    jz .e
    cmp edi, [rq_end]
    jae .over
    mov [edi], al
    inc esi
    inc edi
    dec ecx
    jmp .l
.over:
    mov byte [rq_over], 1
.e: pop esi
    pop ecx
    pop eax
    ret

rq_putc:
    cmp edi, [rq_end]
    jae .over
    mov [edi], al
    inc edi
    ret
.over:
    mov byte [rq_over], 1
    ret

rq_crlf:
    push esi
    mov esi, http_s_crlf
    call rq_put
    pop esi
    ret

rq_put_uint:
    push ebx
    push ecx
    push esi
    mov ebx, 10
    call fmt_uint
    call rq_put
    pop esi
    pop ecx
    pop ebx
    ret

http_lines_have:
    pushad
    test esi, esi
    jz .no
.line:
    cmp byte [esi], 0
    je .no
    push esi
    call http_prefix_ci
    pop esi
    jnc .yes
.skip:
    mov al, [esi]
    test al, al
    jz .no
    inc esi
    cmp al, 10
    jne .skip
    jmp .line
.yes:
    popad
    clc
    ret
.no:
    popad
    stc
    ret

http_prefix_ci:
    push eax
    push edx
    push edi
    mov edx, esi
.l: mov al, [edi]
    test al, al
    jz .yes
    mov al, [esi]
    call to_lower
    cmp al, [edi]
    jne .no
    inc esi
    inc edi
    jmp .l
.yes:
    pop edi
    pop edx
    pop eax
    clc
    ret
.no:
    mov esi, edx
    pop edi
    pop edx
    pop eax
    stc
    ret

http_contains_ci:
    push esi
.l: cmp byte [esi], 0
    je .no
    push esi
    call http_prefix_ci
    pop esi
    jnc .yes
    inc esi
    jmp .l
.yes:
    pop esi
    clc
    ret
.no:
    pop esi
    stc
    ret

http_build:
    pushad
    mov edi, HTTP_REQ
    lea eax, [edi + REQ_MAX]
    mov [rq_end], eax
    mov byte [rq_over], 0

    mov esi, http_m_get
    cmp dword [rq_method], 1
    jne .m1
    mov esi, http_m_post
.m1:
    cmp dword [rq_method], 2
    jne .m2
    mov esi, http_m_head
.m2:
    call rq_put
    mov esi, url_path
    call rq_put
    mov esi, http_s_ver
    call rq_put

    mov esi, url_host
    call rq_put
    mov eax, [url_port]
    cmp byte [url_scheme], 1
    je .p443
    cmp eax, 80
    je .host_done
    jmp .port
.p443:
    cmp eax, 443
    je .host_done
.port:
    mov al, ':'
    call rq_putc
    mov eax, [url_port]
    call rq_put_uint
.host_done:
    call rq_crlf

    mov esi, http_s_ua
    call rq_put
    mov esi, [url_agent]
    test esi, esi
    jnz .ua
    mov esi, http_ua_default
.ua:
    mov ecx, 255
    call rq_putn
    call rq_crlf

    push edi
    mov esi, [url_headers]
    mov edi, hn_accept
    call http_lines_have
    pop edi
    jnc .accept_done
    mov esi, http_s_accept
    call rq_put
.accept_done:

    mov esi, [url_encoding]
    test esi, esi
    jz .enc_done
    push esi
    mov esi, http_s_enc
    call rq_put
    pop esi
    mov ecx, 255
    call rq_putn
    call rq_crlf
.enc_done:

    mov eax, [url_range_start]
    cmp eax, -1
    je .range_done
    mov esi, http_s_range
    call rq_put
    call rq_put_uint
    mov al, '-'
    call rq_putc
    mov eax, [url_range_end]
    cmp eax, -1
    je .range_open
    call rq_put_uint
.range_open:
    call rq_crlf
.range_done:

    mov ecx, [rq_end]
    sub ecx, edi
    sub ecx, 64
    jbe .cookie_done
    cmp ecx, COOKIE_ROOM
    jbe .ck
    mov ecx, COOKIE_ROOM
.ck:
    cmp ecx, 64
    jb .cookie_done
    call cookie_header
.cookie_done:

    cmp dword [rq_method], 1
    jne .post_done
    mov esi, http_s_ctype
    call rq_put
    mov esi, [url_body_type]
    test esi, esi
    jnz .ct
    mov esi, http_ct_default
.ct:
    mov ecx, 255
    call rq_putn
    call rq_crlf
    mov esi, http_s_clen
    call rq_put
    mov eax, [rq_body_len]
    call rq_put_uint
    call rq_crlf
.post_done:

    mov esi, [url_headers]
    test esi, esi
    jz .extra_done
    cmp byte [esi], 0
    je .extra_done
    call rq_put
    cmp byte [edi - 1], 10
    je .extra_done
    call rq_crlf
.extra_done:
    mov esi, http_s_close
    call rq_put
    mov eax, edi
    sub eax, HTTP_REQ
    mov [rq_len], eax
    cmp byte [rq_over], 0
    jne .over
    popad
    clc
    ret
.over:
    popad
    stc
    ret

http_request:
    pushad
    call hs_break
    call http_reply_reset
    cmp byte [net_up], 0
    jne .net
    call net_up_bring
    jnc .net
    mov dword [url_err], ue_net
    jmp .fail
.net:
    mov esi, url_host
    call dns_resolve
    jnc .ip
    mov dword [url_err], ue_dns
    jmp .fail
.ip:
    mov [url_ip], eax
    call http_build
    jnc .built
    mov dword [url_err], he_toobig
    jmp .fail
.built:
    mov al, [url_scheme]
    mov [hx_tls], al
    test al, al
    jnz .tls
    mov eax, [url_ip]
    mov ebx, [url_port]
    call tcp_connect
    jnc .connected
    call http_conn_msg
    jmp .fail
.tls:
    mov al, [url_insecure]
    xor al, 1
    mov [tls_verify], al
    CCALL tls_connect, url_host, dword [url_ip], dword [url_port]
    mov byte [tls_verify], 1
    test eax, eax
    jnz .connected
    mov eax, [tls_err]
    cmp eax, te_connect
    jne .terr
    call http_conn_msg
    jmp .fail
.terr:
    test eax, eax
    jnz .terr2
    mov eax, ue_http
.terr2:
    mov [url_err], eax
    jmp .fail
.connected:
    mov byte [hx_up], 1
    mov dword [hb_pre_len], 0
    mov esi, HTTP_REQ
    mov ecx, [rq_len]
    call hx_send
    jc .send_fail
    mov ecx, [rq_body_len]
    jecxz .sent
    mov esi, [rq_body]
    call hx_send
    jc .send_fail
.sent:
    call http_read_head
    jc .abort
    call http_parse_head
    jc .abort
    call http_body_setup
    popad
    clc
    ret
.send_fail:
    call hx_broke_msg
    cmp dword [url_err], he_broken
    jne .abort
    mov dword [url_err], he_send
.abort:
    call http_abort
.fail:
    popad
    stc
    ret

http_conn_msg:
    mov dword [url_err], he_noanswer
    cmp dword [tcp_err], TE_REFUSED
    jne .r
    mov dword [url_err], he_refused
.r: ret

http_reply_reset:
    push eax
    xor eax, eax
    mov [http_status], eax
    mov [http_clen], eax
    mov [http_total], eax
    mov [hb_pre_len], eax
    mov [http_has_clen], al
    mov [http_loc_long], al
    mov [http_date], al
    mov [http_ctype], al
    mov [http_cenc], al
    mov [http_tenc], al
    mov [http_location], al
    mov dword [hb_mode], HB_NONE
    mov byte [hb_done], 1
    pop eax
    ret

http_read_head:
    pushad
    xor eax, eax
    mov [hd_len], eax
    mov [hd_scan], eax
    mov [hb_pre_len], eax
    mov ebp, [ticks]
.scan:
    call hd_find_end
    test eax, eax
    jnz .block
.more:
    mov ecx, HDR_MAX - 1
    sub ecx, [hd_len]
    jbe .toobig
    mov edi, HTTP_HDR
    add edi, [hd_len]
    call hx_recv
    test eax, eax
    jg .got
    jl .ended
    mov eax, [ticks]
    sub eax, ebp
    cmp eax, HEAD_WAIT
    jae .timeout
    call net_idle
    jmp .more
.got:
    add [hd_len], eax
    mov ebp, [ticks]
    jmp .scan
.block:
    mov [hd_end], eax

    cmp eax, 13
    jb .final
    cmp byte [HTTP_HDR + 8], ' '
    jne .final
    cmp byte [HTTP_HDR + 9], '1'
    jne .final
    mov esi, HTTP_HDR
    add esi, eax
    mov edi, HTTP_HDR
    mov ecx, [hd_len]
    sub ecx, eax
    mov [hd_len], ecx
    mov dword [hd_scan], 0
    call net_copy
    jmp .scan
.final:
    mov eax, [hd_end]
    lea esi, [HTTP_HDR + eax]
    mov [hb_pre], esi
    mov ecx, [hd_len]
    sub ecx, eax
    mov [hb_pre_len], ecx
    popad
    clc
    ret
.ended:
    cmp eax, -1
    jne .broke
    mov dword [url_err], he_noreply
    cmp byte [hx_tls], 0
    je .fail
    cmp dword [tls_err], 0
    je .fail
    mov eax, [tls_err]
    mov [url_err], eax
    jmp .fail
.broke:
    call hx_broke_msg
    jmp .fail
.toobig:
    mov dword [url_err], he_bighead
    jmp .fail
.timeout:
    mov dword [url_err], he_timeout
.fail:
    popad
    stc
    ret

hd_find_end:
    push ecx
    push esi
    mov esi, [hd_scan]
    mov ecx, [hd_len]
.l: cmp esi, ecx
    jae .no
    cmp byte [HTTP_HDR + esi], 10
    jne .n
    lea eax, [esi + 1]
    cmp eax, ecx
    jae .no
    cmp byte [HTTP_HDR + eax], 10
    je .yes
    cmp byte [HTTP_HDR + eax], 13
    jne .n
    inc eax
    cmp eax, ecx
    jae .no
    cmp byte [HTTP_HDR + eax], 10
    jne .n
.yes:
    inc eax
    pop esi
    pop ecx
    ret
.n: inc esi
    jmp .l
.no:
    mov [hd_scan], esi
    xor eax, eax
    pop esi
    pop ecx
    ret

http_parse_head:
    pushad
    mov esi, HTTP_HDR
    mov edx, HTTP_HDR
    add edx, [hd_end]

    mov edi, hn_http
    call http_prefix_ci
    jc .bad
.ver:
    cmp esi, edx
    jae .bad
    mov al, [esi]
    cmp al, ' '
    je .sp
    cmp al, 10
    je .bad
    inc esi
    jmp .ver
.sp:
    cmp byte [esi], ' '
    jne .code
    inc esi
    cmp esi, edx
    jae .bad
    jmp .sp
.code:
    lea eax, [esi + 3]
    cmp eax, edx
    ja .bad
    xor eax, eax
    mov ecx, 3
.digit:
    movzx ebx, byte [esi]
    sub ebx, '0'
    cmp ebx, 9
    ja .bad
    imul eax, 10
    add eax, ebx
    inc esi
    dec ecx
    jnz .digit
    mov [http_status], eax

.next:
    call hd_next_line
    jc .done
.line:
    mov al, [esi]
    cmp al, 13
    je .done
    cmp al, 10
    je .done
    mov edi, esi
.colon:
    cmp edi, edx
    jae .done
    mov al, [edi]
    cmp al, ':'
    je .have
    cmp al, 10
    je .next
    inc edi
    jmp .colon
.have:
    lea ebx, [edi + 1]
.vs:
    cmp ebx, edx
    jae .ve0
    cmp byte [ebx], ' '
    je .vs1
    cmp byte [ebx], 9
    jne .ve0
.vs1:
    inc ebx
    jmp .vs
.ve0:
    mov ecx, ebx
.ve:
    cmp ecx, edx
    jae .vt
    cmp byte [ecx], 10
    je .vt
    inc ecx
    jmp .ve
.vt:
    cmp ecx, ebx
    jbe .vdone
    mov al, [ecx - 1]
    cmp al, 13
    je .vtrim
    cmp al, ' '
    je .vtrim
    cmp al, 9
    jne .vdone
.vtrim:
    dec ecx
    jmp .vt
.vdone:
    mov [hd_vend], ecx
    mov ecx, edi
    sub ecx, esi
    mov ebp, hd_table
.t: mov eax, [ebp]
    test eax, eax
    jz .next
    call hd_name_eq
    je .hit
    add ebp, 8
    jmp .t
.hit:
    pushad
    mov esi, ebx
    mov edx, [hd_vend]
    call [ebp + 4]
    popad
    jmp .next
.done:
    popad
    clc
    ret
.bad:
    mov dword [url_err], he_nothttp
    popad
    stc
    ret

hd_next_line:
.l: cmp esi, edx
    jae .end
    lodsb
    cmp al, 10
    jne .l
    cmp esi, edx
    jae .end
    clc
    ret
.end:
    stc
    ret

hd_name_eq:
    pushad
    mov edi, eax
.l: jecxz .end
    mov al, [esi]
    call to_lower
    cmp al, [edi]
    jne .out
    inc esi
    inc edi
    dec ecx
    jmp .l
.end:
    cmp byte [edi], 0
.out:
    popad
    ret

hd_copy:
    dec ecx
.l: cmp esi, edx
    jae .e
    jecxz .e
    movsb
    dec ecx
    jmp .l
.e: mov byte [edi], 0
    ret

hd_number:
    push ebx
    push ecx
    xor eax, eax
    xor ecx, ecx
.l: cmp esi, edx
    jae .e
    movzx ebx, byte [esi]
    sub ebx, '0'
    cmp ebx, 9
    ja .e
    inc ecx
    inc esi
    cmp eax, 0xFFFFFFFF
    je .l
    push edx
    mov edx, 10
    mul edx
    jc .big
    add eax, ebx
    jc .big
    pop edx
    jmp .l
.big:
    pop edx
    mov eax, 0xFFFFFFFF
    jmp .l
.e: test ecx, ecx
    jz .none
    pop ecx
    pop ebx
    clc
    ret
.none:
    pop ecx
    pop ebx
    stc
    ret

hd_on_clen:
    cmp byte [http_has_clen], 0
    jne .r
    call hd_number
    jc .r
    mov [http_clen], eax
    mov byte [http_has_clen], 1
.r: ret

hd_on_ctype:
    mov edi, http_ctype
    mov ecx, 128
    jmp hd_copy

hd_on_cenc:
    mov edi, http_cenc
    mov ecx, 64
    jmp hd_copy

hd_on_tenc:
    mov edi, http_tenc
    mov ecx, 64
    jmp hd_copy

hd_on_loc:
    mov eax, edx
    sub eax, esi
    cmp eax, 4096
    jb .copy
    mov byte [http_loc_long], 1
    ret
.copy:
    mov edi, http_location
    mov ecx, 4096
    jmp hd_copy

hd_on_date:
    mov edi, http_date
    mov ecx, 40
    jmp hd_copy

hd_on_crange:
.l: cmp esi, edx
    jae .r
    lodsb
    cmp al, '/'
    jne .l
    call hd_number
    jc .r
    mov [http_total], eax
.r: ret

hd_on_cookie:
    mov edi, HTTP_TMP
    mov ecx, TMP_MAX
    call hd_copy
    mov esi, HTTP_TMP
    jmp cookie_set

http_body_setup:
    push eax
    push esi
    push edi
    mov dword [hb_mode], HB_CLOSE
    mov byte [hb_done], 0
    cmp dword [rq_method], 2
    je .none
    mov eax, [http_status]
    cmp eax, 200
    jb .none
    cmp eax, 204
    je .none
    cmp eax, 304
    je .none
    mov esi, http_tenc
    mov edi, hn_chunked
    call http_contains_ci
    jc .not_chunked
    mov dword [hb_mode], HB_CHUNK
    mov dword [hb_ck], HCK_SIZE
    mov dword [hb_size], 0
    mov dword [hb_digits], 0
    jmp .r
.not_chunked:
    cmp byte [http_has_clen], 0
    je .r
    mov dword [hb_mode], HB_LEN
    mov eax, [http_clen]
    mov [hb_left], eax
    test eax, eax
    jnz .r
.none:
    mov dword [hb_mode], HB_NONE
    mov byte [hb_done], 1
.r: pop edi
    pop esi
    pop eax
    ret

http_body_read:
    cmp byte [hb_done], 0
    jne .end
    test ecx, ecx
    jz .zero
    cmp dword [hb_mode], HB_CHUNK
    je .chunked
    cmp dword [hb_mode], HB_LEN
    jne .close

    push ecx
    cmp ecx, [hb_left]
    jbe .n
    mov ecx, [hb_left]
.n: call hx_recv
    pop ecx
    test eax, eax
    jle .len_none
    sub [hb_left], eax
    jnz .r
    mov byte [hb_done], 1
.r: ret
.len_none:
    jz .r
    cmp eax, -1
    jne .broke
    mov dword [url_err], he_early
    mov eax, -2
    ret

.close:
    call hx_recv
    cmp eax, -1
    jl .broke
    jne .r
    mov byte [hb_done], 1
    ret

.chunked:
    push ebx
    mov ebx, 4
.cl:
    call hx_recv
    test eax, eax
    jle .craw
    push ecx
    mov ecx, eax
    call http_dechunk
    pop ecx
    jc .cbad
    cmp dword [hb_ck], HCK_DONE
    jne .cmore
    mov byte [hb_done], 1
    test eax, eax
    jnz .cret
    mov eax, -1
    jmp .cret
.cmore:
    test eax, eax
    jnz .cret
    dec ebx
    jnz .cl
    jmp .cret
.craw:
    jz .cret
    cmp eax, -1
    jne .cbroke
    cmp dword [hb_ck], HCK_TRAIL
    jb .cearly
    mov byte [hb_done], 1
    jmp .cret
.cearly:
    mov dword [url_err], he_early
    mov eax, -2
    jmp .cret
.cbad:
    mov dword [url_err], he_chunk
    mov eax, -2
    jmp .cret
.cbroke:
    call hx_broke_msg
    mov eax, -2
.cret:
    pop ebx
    ret
.broke:
    call hx_broke_msg
    mov eax, -2
    ret
.end:
    mov eax, -1
    ret
.zero:
    xor eax, eax
    ret

http_dechunk:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    mov esi, edi
    lea edx, [esi + ecx]
    mov ebx, edi
.l: cmp esi, edx
    jae .out
    mov eax, [hb_ck]
    cmp eax, HCK_DATA
    je .data
    cmp eax, HCK_DONE
    je .out
    movzx ecx, byte [esi]
    inc esi
    cmp eax, HCK_SIZE
    je .size
    cmp eax, HCK_EXT
    je .ext
    cmp eax, HCK_CRLF
    je .crlf
    cmp eax, HCK_TRAIL
    je .trail
    cmp ecx, 10
    jne .l
    mov dword [hb_ck], HCK_TRAIL
    jmp .l
.size:
    push ecx
    call http_hexval
    jc .notdigit
    mov eax, [hb_size]
    cmp eax, 0x08000000
    jae .bad_pop
    shl eax, 4
    add eax, ecx
    mov [hb_size], eax
    inc dword [hb_digits]
    pop ecx
    jmp .l
.notdigit:
    pop ecx
    cmp dword [hb_digits], 0
    jne .size_end
    cmp ecx, ' '
    je .l
    cmp ecx, 9
    je .l
    jmp .bad
.size_end:
    mov dword [hb_ck], HCK_EXT
    cmp ecx, 10
    je .eol
    jmp .l
.ext:
    cmp ecx, 10
    jne .l
.eol:
    mov eax, [hb_size]
    test eax, eax
    jz .last
    mov [hb_left], eax
    mov dword [hb_ck], HCK_DATA
    jmp .l
.last:
    mov dword [hb_ck], HCK_TRAIL
    jmp .l
.data:
    mov ecx, edx
    sub ecx, esi
    cmp ecx, [hb_left]
    jbe .d1
    mov ecx, [hb_left]
.d1:
    sub [hb_left], ecx
    cmp esi, edi
    jne .move
    add esi, ecx
    add edi, ecx
    jmp .d2
.move:
    call net_copy
.d2:
    cmp dword [hb_left], 0
    jne .l
    mov dword [hb_ck], HCK_CRLF
    jmp .l
.crlf:
    cmp ecx, 13
    je .l
    cmp ecx, 10
    jne .bad
    mov dword [hb_ck], HCK_SIZE
    mov dword [hb_size], 0
    mov dword [hb_digits], 0
    jmp .l
.trail:
    cmp ecx, 13
    je .l
    cmp ecx, 10
    je .done
    mov dword [hb_ck], HCK_TLINE
    jmp .l
.done:
    mov dword [hb_ck], HCK_DONE
.out:
    mov eax, edi
    sub eax, ebx
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    clc
    ret
.bad_pop:
    pop ecx
.bad:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    stc
    ret

http_hexval:
    cmp ecx, '0'
    jb .no
    cmp ecx, '9'
    jbe .d
    or ecx, 0x20
    cmp ecx, 'a'
    jb .no
    cmp ecx, 'f'
    ja .no
    sub ecx, 'a' - 10
    clc
    ret
.d: sub ecx, '0'
    clc
    ret
.no:
    stc
    ret

http_follow:
    pushad
    mov edi, HTTP_URL
    lea eax, [edi + HURL_MAX - 1]
    mov [rq_end], eax
    mov byte [rq_over], 0
    mov esi, http_location
    push edi
    mov edi, url_http
    call http_prefix_ci
    jnc .abs
    mov edi, url_https
    call http_prefix_ci
.abs:
    pop edi
    mov esi, http_location
    jnc .tail
.not_abs:
    call .scheme
    cmp word [esi], '//'
    jne .not_net
    mov al, ':'
    call rq_putc
    jmp .tail
.not_net:
    push esi
    mov esi, http_s_scheme
    call rq_put
    mov esi, url_host
    call rq_put
    pop esi
    mov al, ':'
    call rq_putc
    mov eax, [url_port]
    call rq_put_uint
    cmp byte [esi], '/'
    je .tail

    push esi
    mov esi, url_path
    xor ecx, ecx
    xor edx, edx
.dir:
    mov al, [esi + edx]
    test al, al
    jz .dir_end
    cmp al, '?'
    je .dir_end
    inc edx
    cmp al, '/'
    jne .dir
    mov ecx, edx
    jmp .dir
.dir_end:
    call rq_putn
    pop esi
.tail:
    call rq_put
    mov byte [edi], 0
    cmp byte [rq_over], 0
    jne .bad
    mov esi, HTTP_URL
    call url_parse
    jc .bad
    popad
    clc
    ret
.bad:
    popad
    stc
    ret

.scheme:
    push esi
    mov esi, hn_http
    mov ecx, 4
    call rq_putn
    pop esi
    cmp byte [url_scheme], 1
    jne .sr
    mov al, 's'
    call rq_putc
.sr:
    ret

hs_open:
    pushad
    call hs_close
    mov dword [hs_redirs], 0
    mov dword [hs_got], 0
    call url_parse
    jnc .parsed
    mov dword [url_err], ue_bad
    jmp .fail
.parsed:
    call http_options
.request:
    call http_request
    jc .fail
    mov eax, [http_status]
    cmp eax, 301
    je .redirect
    cmp eax, 302
    je .redirect
    cmp eax, 303
    je .redirect
    cmp eax, 307
    je .redirect
    cmp eax, 308
    jne .opened
.redirect:
    cmp byte [http_loc_long], 0
    jne .toolong
    cmp byte [http_location], 0
    je .opened
    cmp dword [hs_redirs], HS_REDIRS
    jae .opened
    inc dword [hs_redirs]
    call http_abort
    call http_follow
    jc .badloc
    cmp dword [http_status], 303
    je .to_get
    cmp dword [http_status], 307
    jae .request
    cmp dword [rq_method], 1
    jne .request
.to_get:
    cmp dword [rq_method], 2
    je .request
    mov dword [rq_method], 0
    mov dword [rq_body], 0
    mov dword [rq_body_len], 0
    jmp .request
.opened:
    mov eax, [http_status]
    mov [hs_status], eax
    mov eax, [http_clen]
    mov [hs_clen], eax
    mov eax, [http_total]
    mov [hs_total], eax
    mov eax, [ticks]
    mov [hs_last], eax
    mov byte [hs_state], HS_OPEN
    popad
    clc
    ret
.toolong:
    call http_abort
.badloc:
    mov dword [url_err], he_badloc
.fail:
    mov byte [hs_state], HS_NONE
    popad
    stc
    ret

hs_read:
    cmp byte [hs_state], HS_OPEN
    jne .not_open
    call http_body_read
    test eax, eax
    jg .data
    jl .ended
    push edx
    mov edx, [tcp_last_rx]
    sub edx, [hs_last]
    js .since_read
    mov edx, [tcp_last_rx]
    jmp .quiet
.since_read:
    mov edx, [hs_last]
.quiet:
    neg edx
    add edx, [ticks]
    cmp edx, HS_STALL
    pop edx
    jb .r
    mov dword [url_err], he_stalled
    mov byte [hs_state], HS_ERROR
    call http_abort
    mov eax, -2
.r: ret
.data:
    add [hs_got], eax
    push eax
    mov eax, [ticks]
    mov [hs_last], eax
    pop eax
    ret
.ended:
    cmp eax, -1
    jne .broke
    mov byte [hs_state], HS_DONE
    call http_close_quick
    ret
.broke:
    mov byte [hs_state], HS_ERROR
    call http_abort
    ret
.not_open:
    mov eax, -1
    cmp byte [hs_state], HS_DONE
    je .r
    mov eax, -2
    ret

hs_close:
    cmp byte [hs_state], HS_OPEN
    jne .n
    call http_abort
.n: mov byte [hs_state], HS_NONE
    ret

hs_break:
    cmp byte [hs_state], HS_OPEN
    jne .r
    mov byte [hs_state], HS_ERROR
    call http_abort
.r: ret

http_time:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    mov edi, HTTP_URL
    push esi
    mov esi, url_http
    call str_copy
    pop esi
    call str_append
    mov esi, http_root_path
    call str_append
    mov esi, edi
    mov dword [url_method], 2
    call url_fetch
    mov dword [url_method], 0
    jc .fail
    cmp byte [http_date], 0
    je .fail
    mov esi, http_date
    call http_date_parse
    jc .fail
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
    stc
    ret

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
section .text
