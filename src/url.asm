; =============================================================================
;  url.asm - web addresses, url_fetch, and the "get" command
;
;  url_parse splits http://host[:port]/path?query and https://... (a URL
;  with no scheme is plain http) into url_scheme / url_host / url_port /
;  url_path. URLs may be up to URL_LIMIT (4096) bytes long - YouTube's media
;  addresses are 1-2 KB. A "#part" is dropped (it is never sent), and
;  characters that may not appear in a request line (spaces, control
;  characters, bytes above 126) are sent %-encoded.
;
;  url_fetch downloads a URL into PKG_BUF and blocks until it is done; the
;  work is done by net_http.asm (HTTP/1.1, chunked bodies, cookies) over
;  net_tcp.asm, and tls.asm for https (the server's certificate is checked
;  unless url_insecure is set). It does not follow redirects: the caller
;  sees the 3xx status and http_location (the browser and apt decide).
;  For media, net_http.asm has a stream API instead: hs_open / hs_read /
;  hs_close.
;
;  Request options, for url_fetch and hs_open. A caller sets the ones it
;  needs, makes the request, and puts them back (0; the range to -1):
;    url_method       dword  0 GET, 1 POST, 2 HEAD
;    url_body         dword  pointer to the body (POST only)
;    url_body_len     dword  its length in bytes
;    url_body_type    dword  pointer to its Content-Type (zero-terminated);
;                            0 = application/x-www-form-urlencoded
;    url_headers      dword  pointer to more header lines, each ending in
;                            CR LF, the whole zero-terminated; 0 = none
;    url_agent        dword  pointer to a User-Agent; 0 = "MOOS/1.2"
;    url_encoding     dword  pointer to an Accept-Encoding value; 0 = none
;                            is sent (the body then comes unencoded)
;    url_range_start  dword  first byte wanted (Range: bytes=START-END);
;                            -1 = no Range header
;    url_range_end    dword  last byte wanted (inclusive); -1 = to the end
;    url_insecure     byte   1 = do not check the certificate (get -k)
;  What comes back (filled by net_http.asm):
;    http_status      the status code (200, 206, 301, 404 ...)
;    http_clen        Content-Length (0 if none; http_has_clen = 1 if sent)
;    http_total       the total size from Content-Range ("bytes 0-99/1234")
;    http_ctype, http_cenc, http_tenc, http_location, http_date   texts
;    pkg_len          url_fetch: bytes of the body in PKG_BUF (a 0 after)
;    url_truncated    url_fetch: 1 = the body was larger than PKG_BUF
;                     (PKG_BUF_SIZE - 1 bytes kept, the rest not fetched)
;    url_err          on failure: why (a message)
;  Every Set-Cookie goes to the cookie jar (net_cookie.asm), and the jar's
;  matching cookies are sent with every request.
; =============================================================================
URL_LIMIT   equ 4096                    ; longest URL (and path) handled
HOST_MAX    equ 255                     ; longest host name (as DNS allows)

section .data
alignb 4
url_method      dd 0                    ; the request options (see above)
url_body        dd 0
url_body_len    dd 0
url_body_type   dd 0
url_headers     dd 0
url_agent       dd 0
url_encoding    dd 0
url_range_start dd -1
url_range_end   dd -1

section .bss
alignb 4
url_port        resd 1
url_ip          resd 1
url_err         resd 1                  ; message on failure
get_url         resd 1                  ; get: its arguments
get_file        resd 1
get_range_s     resd 1
get_range_e     resd 1
get_data        resd 1
get_type        resd 1                  ; get -t: the body's Content-Type
get_agent       resd 1                  ; get -A: the User-Agent
get_hdr_end     resd 1                  ; get -H: end of the lines in get_hdrs
url_scheme      resb 1                  ; 0 = http, 1 = https
url_insecure    resb 1                  ; 1 = skip the certificate check
get_info        resb 1                  ; get -i: show the reply's headers
url_host        resb HOST_MAX + 1
url_path        resb URL_LIMIT + 4
url_argbuf      resb URL_LIMIT + 4        ; a URL read from a file (@file)
GET_HDRS_MAX    equ 1024
get_hdrs        resb GET_HDRS_MAX + 4   ; get -H: the extra header lines

section .data
url_http        db "http://", 0
url_https       db "https://", 0
url_sep         db "://", 0
ue_bad          db "that is not a URL I understand (use http://host/path or https://host/path)", 0
ue_long         db "the URL is too long (over 4096 characters)", 0
ue_net          db "could not connect to the network", 0
ue_dns          db "could not find that server (DNS lookup failed)", 0
ue_http         db "could not connect to the server", 0
ue_file         db "no such file (for @file: a file holding the URL)", 0
str_dash_k      db "-k", 0
str_dash_v      db "-v", 0
str_dash_i      db "-i", 0
str_dash_r      db "-r", 0
str_dash_d      db "-d", 0
str_dash_t      db "-t", 0
str_secure_http db "plain HTTP - not encrypted", 0
str_secure_tls  db "HTTPS, TLS 1.3", 0

section .text

; url_parse: ESI = URL -> url_scheme / url_host (lower case) / url_port /
; url_path ("/" if there is none; the #part dropped; unsafe characters
; %-encoded). CF=1 if it cannot be parsed (url_err = why).
url_parse:
    pushad
    mov dword [url_err], ue_bad
    mov byte [url_scheme], 0
    mov dword [url_port], 80
    mov edi, esi                        ; https:// ?
    push esi
    mov esi, url_https
    call str_iprefix
    pop esi
    jne .not_https
    mov byte [url_scheme], 1
    mov dword [url_port], 443
    add esi, 8
    jmp .host
.not_https:
    push esi
    mov esi, url_http
    call str_iprefix
    pop esi
    jne .no_scheme
    add esi, 7
    jmp .host
.no_scheme:                             ; "ftp://..." and the like: refused
    mov edi, esi
.sch:
    mov al, [edi]
    test al, al
    jz .host
    cmp al, '/'
    je .host
    cmp al, '?'
    je .host
    cmp al, ':'
    je .colon
    inc edi
    jmp .sch
.colon:
    cmp word [edi + 1], '//'            ; "name://": another scheme
    je .bad
.host:
    mov edi, url_host
    xor ecx, ecx
.h: mov al, [esi]
    test al, al
    jz .host_end
    cmp al, '/'
    je .host_end
    cmp al, '?'
    je .host_end
    cmp al, '#'
    je .host_end
    cmp al, ':'
    je .port
    cmp al, ' '                         ; (no spaces or controls in a name)
    jbe .bad
    cmp ecx, HOST_MAX
    jae .bad
    call to_lower
    mov [edi + ecx], al
    inc ecx
    inc esi
    jmp .h
.port:
    inc esi
    push ecx
    call parse_uint_partial             ; ESI advanced past the digits
    pop ecx                             ; (it changes ECX)
    jc .bad
    test eax, eax
    jz .bad
    cmp eax, 65535
    ja .bad
    mov [url_port], eax
    mov al, [esi]                       ; the port must end the host part
    test al, al
    jz .host_end
    cmp al, '/'
    je .host_end
    cmp al, '?'
    je .host_end
    cmp al, '#'
    jne .bad
.host_end:
    mov byte [edi + ecx], 0
    test ecx, ecx
    jz .bad
    ; --- the path: the rest, up to a '#'
    mov edi, url_path
    lea edx, [edi + URL_LIMIT]            ; EDX = the limit
    cmp byte [esi], '/'
    je .copy
    mov byte [edi], '/'                 ; ("host?q" or "host": add the "/")
    inc edi
.copy:
    mov al, [esi]
    test al, al
    jz .done
    cmp al, '#'
    je .done
    cmp edi, edx
    jae .long
    cmp al, ' '                         ; may it go in a request line as is?
    jbe .enc
    cmp al, 0x7E
    ja .enc
    mov [edi], al
    inc edi
    inc esi
    jmp .copy
.enc:                                   ; no: %XX
    lea ebx, [edi + 3]
    cmp ebx, edx
    ja .long
    mov byte [edi], '%'
    movzx ebx, al
    shr ebx, 4
    mov bl, [hex_digits + ebx]
    mov [edi + 1], bl
    movzx ebx, al
    and ebx, 15
    mov bl, [hex_digits + ebx]
    mov [edi + 2], bl
    add edi, 3
    inc esi
    jmp .copy
.done:
    mov byte [edi], 0
    mov dword [url_err], 0
    popad
    clc
    ret
.long:
    mov dword [url_err], ue_long
.bad:
    mov byte [url_path], 0
    popad
    stc
    ret

; url_fetch: ESI = URL. Downloads it into PKG_BUF with the url_* request
; options and blocks until the reply is complete. pkg_len = body length
; (with a 0 after it), http_status and the other http_* fields set. A body
; larger than PKG_BUF is cut (url_truncated = 1; the connection is then
; reset rather than read to the end). An open hs_* stream is broken off.
; CF=1 on failure with url_err pointing at a message (pkg_len then counts
; what had arrived).
url_fetch:
    pushad
    mov byte [url_truncated], 0
    mov dword [pkg_len], 0
    mov byte [PKG_BUF], 0
    call url_parse
    jc .fail
    call http_options                   ; method and body for this request
    call http_request                   ; connect, send, read the headers
    jc .fail
    xor ebx, ebx                        ; EBX = body bytes so far
    mov ebp, [ticks]                    ; EBP = when some last came
.read:
    mov ecx, PKG_BUF_SIZE - 1
    sub ecx, ebx
    jz .full
    lea edi, [PKG_BUF + ebx]
    call http_body_read
    test eax, eax
    jg .got
    jl .ended
    mov eax, [ticks]                    ; nothing yet
    sub eax, ebp
    cmp eax, BODY_WAIT
    jae .stalled
    call net_idle
    jmp .read
.got:
    add ebx, eax
    mov ebp, [ticks]
    jmp .read
.full:                                  ; the buffer is full: is there more?
    mov edi, url_probe
    mov ecx, 1
    call http_body_read
    test eax, eax
    jg .cut
    jl .ended                           ; (-1: it fitted exactly)
    mov eax, [ticks]
    sub eax, ebp
    cmp eax, BODY_WAIT
    jae .stalled
    call net_idle
    jmp .full
.cut:
    mov byte [url_truncated], 1
    call http_abort                     ; (the server stops sending)
    jmp .ok
.ended:
    cmp eax, -1
    jne .broke                          ; (url_err set by http_body_read)
    call http_close
.ok:
    mov [pkg_len], ebx
    mov byte [PKG_BUF + ebx], 0
    popad
    clc
    ret
.stalled:
    mov dword [url_err], he_stalled
.broke:
    call http_abort
    mov [pkg_len], ebx
    mov byte [PKG_BUF + ebx], 0
.fail:
    popad
    stc
    ret

; url_options_reset: put the request options back to their defaults
url_options_reset:
    push eax
    xor eax, eax
    mov [url_method], eax
    mov [url_body], eax
    mov [url_body_len], eax
    mov [url_body_type], eax
    mov [url_headers], eax
    mov [url_agent], eax
    mov [url_encoding], eax
    dec eax
    mov [url_range_start], eax
    mov [url_range_end], eax
    pop eax
    ret

; url_arg: ESI = a URL argument -> ESI = the URL. "@name" means the URL is
; in the file "name" (for addresses longer than a command line: the first
; line of the file, up to 4096 characters). CF=1 if that file is missing.
url_arg:
    cmp byte [esi], '@'
    jne .ok
    push eax
    push ebx
    push ecx
    push edi
    inc esi
    call fs_find
    jc .missing
    mov ecx, [edi + DE_SIZE]
    call fs_slot                        ; ESI = the file's data
    cmp ecx, URL_LIMIT
    jbe .n
    mov ecx, URL_LIMIT
.n: mov edi, url_argbuf
.c: jecxz .e
    mov al, [esi]
    cmp al, 13                          ; the first line only
    je .e
    cmp al, 10
    je .e
    mov [edi], al
    inc esi
    inc edi
    dec ecx
    jmp .c
.e: mov byte [edi], 0
    mov esi, url_argbuf
    pop edi
    pop ecx
    pop ebx
    pop eax
.ok:
    clc
    ret
.missing:
    pop edi
    pop ecx
    pop ebx
    pop eax
    mov dword [url_err], ue_file
    stc
    ret

; ----------------------------------------------------- the "get" command
; get [-k] [-v] [-i] [-r START-END] [-d DATA] [-t TYPE] [-H NAME:VALUE]
;     [-A AGENT] <url|@file> [file]
cmd_get:
    mov byte [url_insecure], 0
    mov byte [tls_debug], 0
    mov byte [get_info], 0
    mov dword [get_range_s], -1
    mov dword [get_range_e], -1
    mov dword [get_data], 0
    mov dword [get_type], 0
    mov dword [get_agent], 0
    mov dword [get_hdr_end], get_hdrs
    mov byte [get_hdrs], 0
    mov ebx, 1                          ; argument index
.opt:
    cmp ebx, [argc]
    jae .usage
    mov esi, [argv + ebx * 4]
    mov edi, str_dash_k
    call str_icmp
    jne .not_k
    mov byte [url_insecure], 1
    inc ebx
    jmp .opt
.not_k:
    mov edi, str_dash_v
    call str_icmp
    jne .not_v
    mov byte [tls_debug], 1
    inc ebx
    jmp .opt
.not_v:
    mov edi, str_dash_i
    call str_icmp
    jne .not_i
    mov byte [get_info], 1
    inc ebx
    jmp .opt
.not_i:
    mov edi, str_dash_r
    call str_icmp
    jne .not_r
    inc ebx                             ; -r START-END (END may be left out)
    cmp ebx, [argc]
    jae .usage
    mov esi, [argv + ebx * 4]
    call parse_uint_partial
    jc .usage
    mov [get_range_s], eax
    cmp byte [esi], '-'
    jne .usage
    inc esi
    cmp byte [esi], 0
    je .r_open
    call parse_uint_partial
    jc .usage
    mov [get_range_e], eax
.r_open:
    inc ebx
    jmp .opt
.not_r:
    mov edi, str_dash_d
    call str_icmp
    jne .not_d
    inc ebx                             ; -d DATA: POST it
    cmp ebx, [argc]
    jae .usage
    mov eax, [argv + ebx * 4]
    mov [get_data], eax
    inc ebx
    jmp .opt
.not_d:
    mov edi, str_dash_t
    call str_icmp
    jne .not_t
    inc ebx                             ; -t TYPE: the body's Content-Type
    cmp ebx, [argc]
    jae .usage
    mov eax, [argv + ebx * 4]
    mov [get_type], eax
    inc ebx
    jmp .opt
.not_t:
    cmp word [esi], '-A'                ; -A AGENT: the User-Agent
    jne .not_a
    cmp byte [esi + 2], 0
    jne .not_a
    inc ebx
    cmp ebx, [argc]
    jae .usage
    mov eax, [argv + ebx * 4]
    mov [get_agent], eax
    inc ebx
    jmp .opt
.not_a:
    cmp word [esi], '-H'                ; -H NAME:VALUE: one more header
    jne .args                           ;   line (may be given again)
    cmp byte [esi + 2], 0
    jne .args
    inc ebx
    cmp ebx, [argc]
    jae .usage
    mov esi, [argv + ebx * 4]
    call str_len
    mov edi, [get_hdr_end]
    lea eax, [edi + ecx + 2]
    cmp eax, get_hdrs + GET_HDRS_MAX
    ja .usage
    call str_copy_noterm
    mov word [edi], 0x0A0D              ; CR LF
    mov byte [edi + 2], 0
    add edi, 2
    mov [get_hdr_end], edi
    inc ebx
    jmp .opt
.args:
    cmp ebx, [argc]
    jae .usage
    mov eax, [argv + ebx * 4]
    mov [get_url], eax
    mov dword [get_file], 0
    inc ebx
    cmp ebx, [argc]
    jae .go
    mov eax, [argv + ebx * 4]
    mov [get_file], eax
.go:
    cmp byte [url_insecure], 0
    je .fetch
    PRINTF `\x01yWarning:\x01n -k skips the certificate check - the connection is\nencrypted, but anyone in the middle could pretend to be the server.\n`
.fetch:
    mov esi, [get_url]
    call url_arg
    jc .fail_quiet
    mov [get_url], esi
    PRINTF `Downloading %s ...\n`, esi
    mov eax, [get_range_s]              ; the options asked for
    mov [url_range_start], eax
    mov eax, [get_range_e]
    mov [url_range_end], eax
    mov esi, [get_data]
    test esi, esi
    jz .no_data
    mov dword [url_method], 1
    mov [url_body], esi
    call str_len
    mov [url_body_len], ecx
    mov eax, [get_type]
    mov [url_body_type], eax
.no_data:
    cmp byte [get_hdrs], 0
    je .no_hdrs
    mov dword [url_headers], get_hdrs
.no_hdrs:
    mov eax, [get_agent]
    mov [url_agent], eax
    mov esi, [get_url]
    call url_fetch
    pushfd
    call url_options_reset
    mov byte [url_insecure], 0
    mov byte [tls_debug], 0
    popfd
    jc .fail
    mov esi, str_secure_http
    cmp byte [url_scheme], 0
    je .sec
    mov esi, str_secure_tls
.sec:
    PRINTF `\x01gHTTP %d\x01n, %d bytes (%s)\n`, dword [http_status], dword [pkg_len], esi
    cmp byte [url_truncated], 0
    je .whole
    PRINTF `\x01yThe reply was cut:\x01n it is larger than the %d KB download buffer.\n`, PKG_BUF_SIZE / 1024
.whole:
    cmp byte [get_info], 0
    je .no_info
    call http_print_info
.no_info:
    cmp dword [get_file], 0
    jne .save
    cmp byte [get_info], 0              ; (-i without a file: headers only)
    jne .r
    mov esi, PKG_BUF                    ; show it (text) through the pager
    mov ecx, [pkg_len]
    cmp ecx, OUTBUF_SIZE - 64
    jbe .show
    mov ecx, OUTBUF_SIZE - 64
.show:
    call out_begin
    call out_text
    PRINTF `\n`
    xor ebx, ebx
    call out_flush
    ret
.save:
    mov ecx, [pkg_len]
    mov esi, [get_file]
    mov edx, PKG_BUF
    call fs_save
    jc .save_err
    PRINTF `Saved to \x01w%s\x01n.\n`, dword [get_file]
    ret
.save_err:
    PRINTF `\x01rerror:\x01n %s\n`, esi
    ret
.fail_quiet:
    PRINTF `\x01rerror:\x01n %s\n`, dword [url_err]
    ret
.fail:
    PRINTF `\x01rerror:\x01n %s\n`, dword [url_err]
    cmp dword [tls_alert], -1
    je .r
    cmp byte [url_scheme], 1
    jne .r
    PRINTF `(TLS alert %d from the server)\n`, dword [tls_alert]
.r: ret
.usage:
    PRINTF `Usage: \x01wget\x01n [-k] [-v] [-i] [-r START-END] [-d DATA] [-t TYPE]\n           [-H NAME:VALUE] [-A AGENT] <url|@file> [file]\n       e.g.  get https://example.com/\n`
    ret

; http_print_info: print what the last reply's headers said (get -i)
http_print_info:
    pushad
    cmp byte [http_ctype], 0
    je .ct
    PRINTF `  Content-Type: %s\n`, http_ctype
.ct:
    cmp byte [http_has_clen], 0
    je .cl
    PRINTF `  Content-Length: %d\n`, dword [http_clen]
.cl:
    cmp dword [http_total], 0
    je .tot
    PRINTF `  Content-Range total: %d\n`, dword [http_total]
.tot:
    cmp byte [http_tenc], 0
    je .te
    PRINTF `  Transfer-Encoding: %s\n`, http_tenc
.te:
    cmp byte [http_cenc], 0
    je .ce
    PRINTF `  Content-Encoding: %s\n`, http_cenc
.ce:
    cmp byte [http_location], 0
    je .lo
    PRINTF `  Location: %s\n`, http_location
.lo:
    cmp byte [http_date], 0
    je .da
    PRINTF `  Date: %s\n`, http_date
.da:
    popad
    ret
