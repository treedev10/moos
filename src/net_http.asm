; =============================================================================
;  net_http.asm - HTTP/1.1 client: requests, replies, chunked bodies, streams
;
;  One request per connection ("Connection: close"), over plain TCP
;  (net_tcp.asm) or over TLS (tls.asm) for https. Like the TCP code it is
;  polled: the routines that wait say so.
;
;  A request is built from the url_* variables (see url.asm):
;    GET /path HTTP/1.1               (or POST, or HEAD)
;    Host: example.com[:port]
;    User-Agent: MOOS/1.2             (url_agent replaces it)
;    Accept: */*                      (unless url_headers has an Accept)
;    Accept-Encoding: ...             (only when url_encoding is set)
;    Range: bytes=START-[END]         (url_range_start / url_range_end)
;    Cookie: a=1; b=2                 (from the cookie jar, net_cookie.asm)
;    Content-Type: / Content-Length:  (POST: url_body_type, url_body_len)
;    ...                              (url_headers: the caller's own lines)
;    Connection: close
;  followed by the body (POST). The reply's status line and headers are
;  read into HTTP_HDR and picked apart: http_status, http_clen, http_total
;  (from Content-Range), http_ctype, http_cenc, http_tenc, http_location,
;  http_date; every Set-Cookie goes to the jar. Interim 1xx replies (like
;  "100 Continue") are skipped.
;
;  The body is then read with http_body_read, which undoes its framing
;  (RFC 9112 section 6): it stops after Content-Length bytes, decodes a
;  chunked body (in place, a piece at a time, so chunk headers may fall
;  anywhere between reads), or reads until the server closes. A reply that
;  ends too early is an error, not a short body.
;
;  Two ways to use it:
;    url_fetch (url.asm)             the whole body into PKG_BUF, blocking
;    hs_open / hs_read / hs_close    a stream read a piece at a time, for
;                                    media; hs_read never waits
;  There is one TCP connection, so one stream at a time. A url_fetch while
;  a stream is open breaks the stream off: hs_read then returns -2, and its
;  owner can open it again with a Range from where it got to.
; =============================================================================
HTTP_HDR    equ NET_STREAM + 0x50000    ; the reply's header block (32 KB)
HDR_MAX     equ 0x8000
HTTP_REQ    equ NET_STREAM + 0x58000    ; the request's head (16 KB)
REQ_MAX     equ 0x4000
HTTP_TMP    equ NET_STREAM + 0x74000    ; one header's value (4 KB)
TMP_MAX     equ 0x1000
HTTP_URL    equ NET_STREAM + 0x75000    ; a redirect's new address (8 KB)
HURL_MAX    equ 0x2000

HEAD_WAIT   equ 2000                    ; ticks of silence before the reply's
BODY_WAIT   equ 2000                    ;   headers / url_fetch's body count
HS_STALL    equ 3000                    ;   as lost; a stream gets 30 s
HS_REDIRS   equ 8                       ; redirects hs_open follows
COOKIE_ROOM equ 6144                    ; most of the request the Cookie: takes

; how the body ends (hb_mode)
HB_NONE     equ 0                       ; there is none (HEAD, 204, 304)
HB_LEN      equ 1                       ; after Content-Length bytes
HB_CLOSE    equ 2                       ; when the server closes
HB_CHUNK    equ 3                       ; chunked: at the last (empty) chunk

; where the chunk decoder is (hb_ck); the order matters (see .craw)
HCK_SIZE     equ 0                      ; reading a chunk's size (hex)
HCK_EXT      equ 1                      ; the rest of the size line
HCK_DATA     equ 2                      ; inside a chunk's data
HCK_CRLF     equ 3                      ; the CR LF after the data
HCK_TRAIL    equ 4                      ; after the last chunk: a line starts
HCK_TLINE    equ 5                      ;   inside a trailer line
HCK_DONE     equ 6                      ; the final blank line has come

; stream states (hs_state)
HS_NONE     equ 0
HS_OPEN     equ 1
HS_DONE     equ 2                       ; read to the end
HS_ERROR    equ 3                       ; broke, timed out, or broken off

section .bss
alignb 4
rq_method       resd 1                  ; this request: 0 GET, 1 POST, 2 HEAD
rq_body         resd 1                  ;   and its body (POST)
rq_body_len     resd 1
rq_end          resd 1                  ; end of the room in HTTP_REQ
rq_len          resd 1                  ; length of the request's head
hb_mode         resd 1                  ; HB_*
hb_left         resd 1                  ; HB_LEN: body bytes still to come;
                                        ; HB_CHUNK: bytes left in this chunk
hb_ck           resd 1                  ; HCK_*
hb_size         resd 1                  ; the chunk size being read,
hb_digits       resd 1                  ;   and its hex digits so far
hb_pre          resd 1                  ; body bytes that came in with the
hb_pre_len      resd 1                  ;   headers (they wait in HTTP_HDR)
hd_len          resd 1                  ; bytes in HTTP_HDR
hd_end          resd 1                  ; length of the header block
hd_scan         resd 1                  ; where the search for its end goes on
hd_vend         resd 1                  ; (where a header's value ends)
hs_redirs       resd 1                  ; redirects followed by hs_open
hs_last         resd 1                  ; ticks: when the stream last moved
hs_status       resd 1                  ; the open stream's reply: status,
hs_clen         resd 1                  ;   Content-Length (0 if none),
hs_total        resd 1                  ;   total size from Content-Range (or 0)
hs_got          resd 1                  ; body bytes the stream has delivered
http_status     resd 1                  ; the last reply's status code,
http_clen       resd 1                  ;   its Content-Length (0 if none),
http_total      resd 1                  ;   the total from its Content-Range
pkg_len         resd 1                  ; bytes url_fetch put in PKG_BUF
rq_over         resb 1                  ; 1 = the request did not fit
hx_tls          resb 1                  ; 1 = the connection is TLS
hx_up           resb 1                  ; 1 = a request's connection is open
hs_state        resb 1                  ; HS_*
hb_done         resb 1                  ; 1 = all of the body has been read
http_has_clen   resb 1                  ; 1 = the reply had a Content-Length
http_loc_long   resb 1                  ; 1 = its Location was over 4 KB
url_truncated   resb 1                  ; 1 = url_fetch cut the body to fit
url_probe       resb 1                  ; (url_fetch: is there more?)
http_date       resb 40                 ; Date:
http_ctype      resb 128                ; Content-Type:
http_cenc       resb 64                 ; Content-Encoding:
http_tenc       resb 64                 ; Transfer-Encoding:
http_location   resb 4096               ; Location: (where a redirect points)

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
; the reply headers MOOS reads, and what handles each
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

; ------------------------------------------------------------ the transport
; hx_send: ESI = data, ECX = length -> sent over the connection (TCP or
; TLS). CF=1 if it broke. Registers kept.
hx_send:
    cmp byte [hx_tls], 0
    jne .tls
    jmp tcp_send
.tls:
    pushad
    CCALL tls_write, esi, ecx
    test eax, eax
    popad                               ; (popad leaves the flags alone)
    jz .fail
    clc
    ret
.fail:
    stc
    ret

; hx_recv: EDI = buffer, ECX = most bytes (> 0) -> EAX = raw reply bytes
; (after TLS) put there (> 0), 0 if none have arrived yet, -1 at the end of
; the stream, -2 if the connection broke. Body bytes that came in with the
; headers come first. Polls the card; never waits. Other registers kept.
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

; hx_broke_msg: url_err = why the connection broke (TLS's reason, a reset,
; or retransmissions that were never answered). Registers kept.
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

; http_close: the reply has been read: end politely (TLS close_notify, our
; FIN) and wait up to 1 s for the server's side of the close
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

; http_close_quick: the same without waiting (the next connection forgets
; this one; the server's last ACKs are answered meanwhile by tcp_poll)
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

; http_abort: drop the request's connection at once (a reset tells the
; server to stop sending). Registers kept.
http_abort:
    cmp byte [hx_up], 0
    je .r
    mov byte [hx_up], 0
    call tcp_abort
.r: ret

; ----------------------------------------------------------- the request
; http_options: this request's method and body from url_method / url_body /
; url_body_len (a body only goes with POST)
http_options:
    push eax
    mov eax, [url_method]
    cmp eax, 2
    jbe .m
    xor eax, eax                        ; (unknown: GET)
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

; rq_put: ESI = text -> appended at EDI (EDI advanced), but never past
; rq_end: what does not fit sets rq_over. Other registers kept.
rq_put:
    push ecx
    mov ecx, 0x7FFFFFFF
    call rq_putn
    pop ecx
    ret

; rq_putn: like rq_put, at most ECX characters of ESI
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

; rq_putc: AL = a character -> appended at EDI (as rq_put)
rq_putc:
    cmp edi, [rq_end]
    jae .over
    mov [edi], al
    inc edi
    ret
.over:
    mov byte [rq_over], 1
    ret

; rq_crlf: CR LF at EDI (as rq_put)
rq_crlf:
    push esi
    mov esi, http_s_crlf
    call rq_put
    pop esi
    ret

; rq_put_uint: EAX = a number -> its decimal digits at EDI (as rq_put)
rq_put_uint:
    push ebx
    push ecx
    push esi
    mov ebx, 10
    call fmt_uint                       ; ESI = digits
    call rq_put
    pop esi
    pop ecx
    pop ebx
    ret

; http_lines_have: ESI = header lines (each ending in LF, 0 at the end, or
; ESI = 0), EDI = a lower-case "name:" -> CF=0 if a line starts with it
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
.skip:                                  ; on to the next line
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

; http_prefix_ci: ESI = text, EDI = a lower-case prefix -> CF=0 if the
; text starts with it (ignoring case), ESI then just past it; CF=1 and ESI
; unchanged if not. EDI kept.
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

; http_contains_ci: ESI = text, EDI = a lower-case word -> CF=0 if the text
; contains it (ignoring case). Registers kept.
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

; http_build: the request's head for url_* (parsed) and the request options
; -> HTTP_REQ, rq_len = its length. CF=1 if it does not fit in 16 KB.
http_build:
    pushad
    mov edi, HTTP_REQ
    lea eax, [edi + REQ_MAX]
    mov [rq_end], eax
    mov byte [rq_over], 0
    ; --- request line
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
    mov esi, http_s_ver                 ; " HTTP/1.1" CR LF "Host: "
    call rq_put
    ; --- Host: name, and the port unless it is the scheme's usual one
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
    ; --- User-Agent
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
    ; --- Accept, unless the caller sends its own
    push edi
    mov esi, [url_headers]
    mov edi, hn_accept
    call http_lines_have
    pop edi
    jnc .accept_done
    mov esi, http_s_accept
    call rq_put
.accept_done:
    ; --- Accept-Encoding (only if asked for: MOOS sends the body on as it
    ; comes, so the caller must be able to decode what it allows)
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
    ; --- Range: bytes=START-END (END may be left open)
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
    ; --- Cookie: from the jar (cookie_header measures its own room)
    mov ecx, [rq_end]
    sub ecx, edi
    sub ecx, 64                         ; (keep room for the rest)
    jbe .cookie_done
    cmp ecx, COOKIE_ROOM
    jbe .ck
    mov ecx, COOKIE_ROOM
.ck:
    cmp ecx, 64
    jb .cookie_done
    call cookie_header
.cookie_done:
    ; --- POST: what the body is
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
    ; --- the caller's own header lines
    mov esi, [url_headers]
    test esi, esi
    jz .extra_done
    cmp byte [esi], 0
    je .extra_done
    call rq_put
    cmp byte [edi - 1], 10              ; (the last line without its CR LF)
    je .extra_done
    call rq_crlf
.extra_done:
    mov esi, http_s_close               ; "Connection: close" and the blank
    call rq_put                         ; line that ends the head
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

; http_request: send the request for url_* (parsed by url_parse) with the
; rq_* method and body and the url_* options, then read the reply's status
; and headers. Blocks while connecting (SYN retries, about 11 s at most),
; during the TLS handshake (15 s of silence at most) and for the headers
; (20 s of silence at most). An open stream is broken off first.
; CF=0: http_* filled in, the body ready for http_body_read.
; CF=1: url_err says why; no connection is left open.
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
    call http_build                     ; (before connecting: it may not fit)
    jnc .built
    mov dword [url_err], he_toobig
    jmp .fail
.built:
    mov al, [url_scheme]
    mov [hx_tls], al
    test al, al
    jnz .tls
    mov eax, [url_ip]                   ; plain HTTP
    mov ebx, [url_port]
    call tcp_connect
    jnc .connected
    call http_conn_msg
    jmp .fail
.tls:
    mov al, [url_insecure]              ; HTTPS: the certificate is checked
    xor al, 1                           ; unless url_insecure says not to
    mov [tls_verify], al
    CCALL tls_connect, url_host, dword [url_ip], dword [url_port]
    mov byte [tls_verify], 1
    test eax, eax
    jnz .connected
    mov eax, [tls_err]
    cmp eax, te_connect                 ; (TCP's own reason is clearer)
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
    mov esi, HTTP_REQ                   ; the head, then the body
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

; http_conn_msg: url_err = why tcp_connect failed (tcp_err)
http_conn_msg:
    mov dword [url_err], he_noanswer
    cmp dword [tcp_err], TE_REFUSED
    jne .r
    mov dword [url_err], he_refused
.r: ret

; http_reply_reset: forget the last reply's fields
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

; ------------------------------------------------------------- the reply
; http_read_head -> CF=0 when the reply's header block is in HTTP_HDR
; (hd_end = its length with the blank line; body bytes that came with it in
; hb_pre / hb_pre_len). Interim 1xx replies before it are dropped. CF=1
; (url_err) if the connection ended or broke first, the headers were over
; 32 KB, or nothing came for HEAD_WAIT ticks.
http_read_head:
    pushad
    xor eax, eax
    mov [hd_len], eax
    mov [hd_scan], eax
    mov [hb_pre_len], eax
    mov ebp, [ticks]                    ; EBP = when something last came
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
    ; "HTTP/1.1 1xx": an interim reply - drop it and read on
    cmp eax, 13
    jb .final
    cmp byte [HTTP_HDR + 8], ' '
    jne .final
    cmp byte [HTTP_HDR + 9], '1'
    jne .final
    mov esi, HTTP_HDR                   ; (the rest moves to the front)
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
    cmp byte [hx_tls], 0                ; (TLS may know better: an alert)
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

; hd_find_end -> EAX = length of the header block in HTTP_HDR (up to and
; including the blank line that ends it: LF CR LF or LF LF), or 0 if it has
; not all arrived yet (hd_scan remembers how far the search got)
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
    jae .no                             ; (what follows has not come yet)
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
    inc eax                             ; past the last LF
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

; http_parse_head: the header block in HTTP_HDR (hd_end bytes) ->
; http_status and the other http_* fields; Set-Cookie lines go to the jar.
; CF=1 (url_err) if the status line is not HTTP's.
http_parse_head:
    pushad
    mov esi, HTTP_HDR
    mov edx, HTTP_HDR
    add edx, [hd_end]                   ; EDX = end of the block
    ; --- status line: HTTP/x.y NNN reason
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
    ; --- the header lines: "Name: value"
.next:
    call hd_next_line
    jc .done
.line:
    mov al, [esi]
    cmp al, 13                          ; the blank line: the end
    je .done
    cmp al, 10
    je .done
    mov edi, esi                        ; EDI = the colon
.colon:
    cmp edi, edx
    jae .done
    mov al, [edi]
    cmp al, ':'
    je .have
    cmp al, 10
    je .next                            ; (no colon: not a header)
    inc edi
    jmp .colon
.have:
    lea ebx, [edi + 1]                  ; EBX = the value, without spaces
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
    mov ecx, ebx                        ; ECX = its end (before CR LF)
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
    mov ecx, edi                        ; ECX = the name's length
    sub ecx, esi
    mov ebp, hd_table                   ; one MOOS reads?
.t: mov eax, [ebp]
    test eax, eax
    jz .next
    call hd_name_eq
    je .hit
    add ebp, 8
    jmp .t
.hit:
    pushad
    mov esi, ebx                        ; ESI = value, EDX = its end
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

; hd_next_line: ESI = in a line of the header block, EDX = its end -> ESI
; at the start of the next line; CF=1 if there is none
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

; hd_name_eq: ESI = a header name, ECX = its length, EAX = a lower-case
; name -> ZF=1 if they are the same (ignoring case). Registers kept.
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
    cmp byte [edi], 0                   ; (the table's name ends here too)
.out:
    popad
    ret

; hd_copy: ESI = a header value, EDX = its end, EDI = where it goes, ECX =
; room there -> copied (cut to fit), with a 0 after
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

; hd_number: ESI = digits, EDX = the end -> EAX = their value (at most
; 0xFFFFFFFF), CF=1 if there are none. ESI moved past them.
hd_number:
    push ebx
    push ecx
    xor eax, eax
    xor ecx, ecx                        ; ECX = digits seen
.l: cmp esi, edx
    jae .e
    movzx ebx, byte [esi]
    sub ebx, '0'
    cmp ebx, 9
    ja .e
    inc ecx
    inc esi
    cmp eax, 0xFFFFFFFF                 ; (stays at the top once there)
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

; the handlers of hd_table: ESI = the value, EDX = its end (any register
; may change)
hd_on_clen:
    cmp byte [http_has_clen], 0         ; (the first one counts)
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
    mov eax, edx                        ; too long to follow? then it is
    sub eax, esi                        ; left out (http_loc_long says so)
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

; Content-Range: bytes 0-99/1234 (or bytes */1234) -> http_total = 1234
hd_on_crange:
.l: cmp esi, edx
    jae .r
    lodsb
    cmp al, '/'
    jne .l
    call hd_number                      ; ("*": the size is not known)
    jc .r
    mov [http_total], eax
.r: ret

; Set-Cookie: the value (zero-terminated) to the jar
hd_on_cookie:
    mov edi, HTTP_TMP
    mov ecx, TMP_MAX
    call hd_copy
    mov esi, HTTP_TMP
    jmp cookie_set

; http_body_setup: how the body ends, from the method, the status and the
; headers (RFC 9112 section 6.3)
http_body_setup:
    push eax
    push esi
    push edi
    mov dword [hb_mode], HB_CLOSE
    mov byte [hb_done], 0
    cmp dword [rq_method], 2            ; HEAD: never a body
    je .none
    mov eax, [http_status]
    cmp eax, 200
    jb .none                            ; (1xx)
    cmp eax, 204
    je .none
    cmp eax, 304
    je .none
    mov esi, http_tenc                  ; chunked wins over a length
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
    je .r                               ; neither: until the server closes
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

; ------------------------------------------------------------- the body
; http_body_read: EDI = buffer, ECX = most bytes -> EAX = body bytes put
; there (> 0), 0 if none have arrived yet, -1 once the whole body has been
; read, -2 if the connection broke or ended too early (url_err says why).
; The framing (Content-Length, chunked) is taken off. Never waits. Other
; registers kept.
http_body_read:
    cmp byte [hb_done], 0
    jne .end
    test ecx, ecx
    jz .zero
    cmp dword [hb_mode], HB_CHUNK
    je .chunked
    cmp dword [hb_mode], HB_LEN
    jne .close
    ; --- Content-Length: up to what is left
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
    jz .r                               ; nothing yet
    cmp eax, -1
    jne .broke
    mov dword [url_err], he_early       ; closed before the length was in
    mov eax, -2
    ret
    ; --- until the server closes
.close:
    call hx_recv
    cmp eax, -1
    jl .broke
    jne .r
    mov byte [hb_done], 1
    ret
    ; --- chunked: decode what came, in place
.chunked:
    push ebx
    mov ebx, 4                          ; (a few tries when a read held only
.cl:                                    ; chunk headers)
    call hx_recv
    test eax, eax
    jle .craw
    push ecx
    mov ecx, eax
    call http_dechunk                   ; EAX = data left in place
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
    jmp .cret                           ; (EAX = 0: nothing yet)
.craw:
    jz .cret
    cmp eax, -1
    jne .cbroke
    cmp dword [hb_ck], HCK_TRAIL        ; closed after the last chunk (in
    jb .cearly                          ; its trailer): that is the end
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

; http_dechunk: EDI = raw bytes of a chunked body, ECX = how many ->
; EAX = the data bytes left in their place at EDI (the chunk sizes, CR LFs
; and trailers taken out). The decoder's state (hb_ck ...) carries over
; from one call to the next. CF=1 if the framing is broken. Other
; registers kept.
http_dechunk:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    mov esi, edi                        ; ESI reads, EDI writes (never ahead)
    lea edx, [esi + ecx]                ; EDX = the end
    mov ebx, edi                        ; EBX = start of the output
.l: cmp esi, edx
    jae .out
    mov eax, [hb_ck]
    cmp eax, HCK_DATA
    je .data
    cmp eax, HCK_DONE
    je .out                             ; (anything after the end: dropped)
    movzx ecx, byte [esi]               ; ECX = the next character
    inc esi
    cmp eax, HCK_SIZE
    je .size
    cmp eax, HCK_EXT
    je .ext
    cmp eax, HCK_CRLF
    je .crlf
    cmp eax, HCK_TRAIL
    je .trail
    cmp ecx, 10                        ; HCK_TLINE: to the end of the line
    jne .l
    mov dword [hb_ck], HCK_TRAIL
    jmp .l
.size:                                  ; hex digits of the size
    push ecx
    call http_hexval
    jc .notdigit
    mov eax, [hb_size]
    cmp eax, 0x08000000                 ; (a chunk over 2 GB: nonsense)
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
    cmp ecx, ' '                        ; (spaces before the size)
    je .l
    cmp ecx, 9
    je .l
    jmp .bad
.size_end:
    mov dword [hb_ck], HCK_EXT          ; ";extension", CR: skipped
    cmp ecx, 10
    je .eol
    jmp .l
.ext:
    cmp ecx, 10
    jne .l
.eol:                                   ; the size line is over
    mov eax, [hb_size]
    test eax, eax
    jz .last
    mov [hb_left], eax
    mov dword [hb_ck], HCK_DATA
    jmp .l
.last:                                  ; size 0: the last chunk
    mov dword [hb_ck], HCK_TRAIL
    jmp .l
.data:                                  ; the chunk's bytes: moved down
    mov ecx, edx
    sub ecx, esi
    cmp ecx, [hb_left]
    jbe .d1
    mov ecx, [hb_left]
.d1:
    sub [hb_left], ecx
    cmp esi, edi
    jne .move
    add esi, ecx                        ; (in place already)
    add edi, ecx
    jmp .d2
.move:
    call net_copy                       ; (forwards: safe, EDI < ESI)
.d2:
    cmp dword [hb_left], 0
    jne .l
    mov dword [hb_ck], HCK_CRLF
    jmp .l
.crlf:                                  ; CR LF after the data
    cmp ecx, 13
    je .l
    cmp ecx, 10
    jne .bad
    mov dword [hb_ck], HCK_SIZE
    mov dword [hb_size], 0
    mov dword [hb_digits], 0
    jmp .l
.trail:                                 ; a trailer line, or the blank one
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

; http_hexval: ECX = a character -> ECX = its value as a hex digit, CF=1 if
; it is not one
http_hexval:
    cmp ecx, '0'
    jb .no
    cmp ecx, '9'
    jbe .d
    or ecx, 0x20                        ; (lower case)
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

; ------------------------------------------------------------- redirects
; http_follow: url_* = where the reply's Location points, taken relative to
; the request just made (absolute, "//host/...", "/path" or "name").
; CF=1 if the result cannot be used.
http_follow:
    pushad
    mov edi, HTTP_URL
    lea eax, [edi + HURL_MAX - 1]
    mov [rq_end], eax                   ; (rq_put's limit)
    mov byte [rq_over], 0
    mov esi, http_location
    push edi
    mov edi, url_http                   ; "http://..." or "https://...":
    call http_prefix_ci                 ; an absolute address, taken as is
    jnc .abs
    mov edi, url_https
    call http_prefix_ci
.abs:
    pop edi
    mov esi, http_location              ; (http_prefix_ci moved ESI)
    jnc .tail
.not_abs:
    call .scheme                        ; "http" or "https"
    cmp word [esi], '//'                ; //host/path: the same scheme
    jne .not_net
    mov al, ':'
    call rq_putc
    jmp .tail
.not_net:
    push esi
    mov esi, http_s_scheme              ; "://host[:port]"
    call rq_put
    mov esi, url_host
    call rq_put
    pop esi
    mov al, ':'
    call rq_putc
    mov eax, [url_port]
    call rq_put_uint
    cmp byte [esi], '/'
    je .tail                            ; /path: from the top of the site
    ; a relative name: next to the current page (its path up to the last
    ; "/" before any "?")
    push esi
    mov esi, url_path
    xor ecx, ecx                        ; ECX = length up to the last '/'
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
; .scheme: put "http" or "https" (the current scheme) at EDI
.scheme:
    push esi
    mov esi, hn_http                    ; ("http/" - only its first 4)
    mov ecx, 4
    call rq_putn
    pop esi
    cmp byte [url_scheme], 1
    jne .sr
    mov al, 's'
    call rq_putc
.sr:
    ret

; --------------------------------------------------------------- streams
; hs_open: ESI = URL (http:// or https://, up to 4096 bytes). Connects,
; sends the request (the url_* options; url_range_start / url_range_end for
; a part of the file) and reads the reply's headers; redirects (301, 302,
; 303, 307, 308) are followed, up to 8. Blocks for all that (each step has
; its own timeout). CF=0: the stream is open - hs_status, hs_clen (the
; Content-Length, 0 if none) and hs_total (the size from Content-Range, 0 if
; none) say what came; any status counts (check hs_status). CF=1: it could
; not be opened, url_err says why. A stream that was open is closed first.
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
    mov eax, [http_status]              ; a redirect?
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
    cmp byte [http_loc_long], 0         ; (a Location over 4 KB)
    jne .toolong
    cmp byte [http_location], 0
    je .opened
    cmp dword [hs_redirs], HS_REDIRS
    jae .opened
    inc dword [hs_redirs]
    call http_abort                     ; (its body is not wanted)
    call http_follow
    jc .badloc
    cmp dword [http_status], 303        ; 303 (and 301/302 after a POST,
    je .to_get                          ; as browsers do): ask with GET
    cmp dword [http_status], 307
    jae .request
    cmp dword [rq_method], 1
    jne .request
.to_get:
    cmp dword [rq_method], 2            ; (HEAD stays HEAD)
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

; hs_read: EDI = buffer, ECX = most bytes -> EAX = bytes of the body put
; there (> 0), 0 if nothing has arrived yet, -1 when the body is complete,
; -2 on an error (broken off, reset, a TLS error, the server closed too
; early, or nothing came for 30 s while being read; url_err says which).
; Polls the network card and returns: it never waits. Other registers kept.
hs_read:
    cmp byte [hs_state], HS_OPEN
    jne .not_open
    call http_body_read
    test eax, eax
    jg .data
    jl .ended
    push edx                            ; nothing yet: quiet for too long?
    mov edx, [tcp_last_rx]              ; (since the later of: the last
    sub edx, [hs_last]                  ; segment, the last data read)
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

; hs_close: close the stream (a reset if it was not read to the end, so the
; server stops sending). Registers kept.
hs_close:
    cmp byte [hs_state], HS_OPEN
    jne .n
    call http_abort
.n: mov byte [hs_state], HS_NONE
    ret

; hs_break: another request needs the connection: an open stream is broken
; off (its next hs_read returns -2). Registers kept.
hs_break:
    cmp byte [hs_state], HS_OPEN
    jne .r
    mov byte [hs_state], HS_ERROR
    call http_abort
.r: ret

; ------------------------------------------------------------ clock sync
; http_time: ESI = hostname -> EAX = Unix seconds from the server's Date
; header (a HEAD request to http://host/), CF=1 on failure. Works on any
; web server, even one that answers with an error: every reply has a Date.
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
    mov dword [url_method], 2           ; HEAD (only the headers are wanted)
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
section .text
