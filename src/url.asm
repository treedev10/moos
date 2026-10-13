; =============================================================================
;  url.asm - fetch a URL over HTTP or HTTPS, and the "get" command
;
;  url_fetch understands http://host[:port]/path and https://host[:port]/path
;  (a URL with no scheme is plain http). HTTPS checks the server's
;  certificate unless url_insecure is set.
; =============================================================================
section .bss
alignb 4
url_scheme      resb 1                  ; 0 = http, 1 = https
url_insecure    resb 1                  ; 1 = skip the certificate check
alignb 4
url_port        resd 1
url_ip          resd 1
url_err         resd 1                  ; message on failure
url_host        resb 128
url_path        resb 384
get_url         resd 1
get_file        resd 1

section .data
url_http        db "http://", 0
url_https       db "https://", 0
ue_bad          db "that is not a URL I understand (use http://host/path or https://host/path)", 0
ue_net          db "could not connect to the network", 0
ue_dns          db "could not find that server (DNS lookup failed)", 0
ue_http         db "could not connect to the server", 0
str_dash_k      db "-k", 0
str_dash_v      db "-v", 0

section .text

; url_parse: ESI = URL -> url_scheme / url_host / url_port / url_path.
; CF=1 if it cannot be parsed.
url_parse:
    pushad
    mov byte [url_scheme], 0
    mov dword [url_port], 80
    push esi
    mov edi, esi
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
    mov edi, esi
    mov esi, url_http
    call str_iprefix
    pop esi
    jne .host
    add esi, 7
.host:
    mov edi, url_host
    xor ecx, ecx
.h: mov al, [esi]
    test al, al
    jz .host_end
    cmp al, '/'
    je .host_end
    cmp al, ':'
    je .port
    cmp ecx, 126
    jae .bad
    mov [edi + ecx], al
    inc ecx
    inc esi
    jmp .h
.port:
    inc esi
    call parse_uint_partial             ; ESI advanced past the digits
    jc .bad
    test eax, eax
    jz .bad
    cmp eax, 65535
    ja .bad
    mov [url_port], eax
.host_end:
    mov byte [edi + ecx], 0
    test ecx, ecx
    jz .bad
    mov edi, url_path                   ; the rest is the path ("/" if none)
    cmp byte [esi], '/'
    je .copy
    mov byte [edi], '/'
    inc edi
.copy:
    mov ecx, 380
.c: mov al, [esi]
    mov [edi], al
    test al, al
    jz .done
    inc esi
    inc edi
    dec ecx
    jnz .c
    jmp .bad
.done:
    popad
    clc
    ret
.bad:
    popad
    stc
    ret

; url_fetch: ESI = URL. Downloads it into PKG_BUF (pkg_len = body length,
; http_status set). CF=1 on failure with url_err pointing at a message.
url_fetch:
    pushad
    call url_parse
    jnc .parsed
    mov dword [url_err], ue_bad
    jmp .fail
.parsed:
    cmp byte [net_up], 0
    jne .have_net
    call net_up_bring
    jnc .have_net
    mov dword [url_err], ue_net
    jmp .fail
.have_net:
    mov esi, url_host
    call dns_resolve
    jnc .resolved
    mov dword [url_err], ue_dns
    jmp .fail
.resolved:
    mov [url_ip], eax
    cmp byte [url_scheme], 1
    je .https
    mov eax, [url_ip]                   ; plain HTTP
    mov ebx, [url_port]
    mov esi, url_host
    mov edi, url_path
    call http_get
    jnc .ok
    mov dword [url_err], ue_http
    jmp .fail
.https:
    mov al, [url_insecure]
    xor al, 1
    mov [tls_verify], al
    CCALL https_get, url_host, dword [url_ip], dword [url_port], url_path
    mov byte [tls_verify], 1
    test eax, eax
    jnz .ok
    mov eax, [tls_err]
    test eax, eax
    jnz .terr
    mov eax, ue_http
.terr:
    mov [url_err], eax
    jmp .fail
.ok:
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

; ----------------------------------------------------- the "get" command
; get [-k] <url> [file]
cmd_get:
    mov byte [url_insecure], 0
    mov byte [tls_debug], 0
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
    jne .args
    mov byte [tls_debug], 1
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
    PRINTF `Downloading %s ...\n`, dword [get_url]
    mov esi, [get_url]
    call url_fetch
    mov byte [url_insecure], 0
    mov byte [tls_debug], 0
    jc .fail
    mov esi, str_secure_http
    cmp byte [url_scheme], 0
    je .sec
    mov esi, str_secure_tls
.sec:
    PRINTF `\x01gHTTP %d\x01n, %d bytes (%s)\n`, dword [http_status], dword [pkg_len], esi
    cmp dword [get_file], 0
    jne .save
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
.fail:
    PRINTF `\x01rerror:\x01n %s\n`, dword [url_err]
    cmp dword [tls_alert], -1
    je .r
    cmp byte [url_scheme], 1
    jne .r
    PRINTF `(TLS alert %d from the server)\n`, dword [tls_alert]
.r: ret
.usage:
    PRINTF `Usage: \x01wget\x01n [-k] <url> [file]   e.g.  get https://example.com/\n`
    ret

section .data
str_secure_http db "plain HTTP - not encrypted", 0
str_secure_tls  db "HTTPS, TLS 1.3", 0
section .text
