URL_LIMIT   equ 4096
HOST_MAX    equ 255

section .data
alignb 4
url_method      dd 0
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
url_err         resd 1
get_url         resd 1
get_file        resd 1
get_range_s     resd 1
get_range_e     resd 1
get_data        resd 1
get_type        resd 1
get_agent       resd 1
get_hdr_end     resd 1
url_scheme      resb 1
url_insecure    resb 1
get_info        resb 1
url_host        resb HOST_MAX + 1
url_path        resb URL_LIMIT + 4
url_argbuf      resb URL_LIMIT + 4
GET_HDRS_MAX    equ 1024
get_hdrs        resb GET_HDRS_MAX + 4

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

url_parse:
    pushad
    mov dword [url_err], ue_bad
    mov byte [url_scheme], 0
    mov dword [url_port], 80
    mov edi, esi
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
.no_scheme:
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
    cmp word [edi + 1], '//'
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
    cmp al, ' '
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
    call parse_uint_partial
    pop ecx
    jc .bad
    test eax, eax
    jz .bad
    cmp eax, 65535
    ja .bad
    mov [url_port], eax
    mov al, [esi]
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

    mov edi, url_path
    lea edx, [edi + URL_LIMIT]
    cmp byte [esi], '/'
    je .copy
    mov byte [edi], '/'
    inc edi
.copy:
    mov al, [esi]
    test al, al
    jz .done
    cmp al, '#'
    je .done
    cmp edi, edx
    jae .long
    cmp al, ' '
    jbe .enc
    cmp al, 0x7E
    ja .enc
    mov [edi], al
    inc edi
    inc esi
    jmp .copy
.enc:
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

url_fetch:
    pushad
    mov byte [url_truncated], 0
    mov dword [pkg_len], 0
    mov byte [PKG_BUF], 0
    call url_parse
    jc .fail
    call http_options
    call http_request
    jc .fail
    xor ebx, ebx
    mov ebp, [ticks]
.read:
    mov ecx, PKG_BUF_SIZE - 1
    sub ecx, ebx
    jz .full
    lea edi, [PKG_BUF + ebx]
    call http_body_read
    test eax, eax
    jg .got
    jl .ended
    mov eax, [ticks]
    sub eax, ebp
    cmp eax, BODY_WAIT
    jae .stalled
    call net_idle
    jmp .read
.got:
    add ebx, eax
    mov ebp, [ticks]
    jmp .read
.full:
    mov edi, url_probe
    mov ecx, 1
    call http_body_read
    test eax, eax
    jg .cut
    jl .ended
    mov eax, [ticks]
    sub eax, ebp
    cmp eax, BODY_WAIT
    jae .stalled
    call net_idle
    jmp .full
.cut:
    mov byte [url_truncated], 1
    call http_abort
    jmp .ok
.ended:
    cmp eax, -1
    jne .broke
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
    call fs_slot
    cmp ecx, URL_LIMIT
    jbe .n
    mov ecx, URL_LIMIT
.n: mov edi, url_argbuf
.c: jecxz .e
    mov al, [esi]
    cmp al, 13
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
    mov ebx, 1
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
    inc ebx
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
    inc ebx
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
    inc ebx
    cmp ebx, [argc]
    jae .usage
    mov eax, [argv + ebx * 4]
    mov [get_type], eax
    inc ebx
    jmp .opt
.not_t:
    cmp word [esi], '-A'
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
    cmp word [esi], '-H'
    jne .args
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
    mov word [edi], 0x0A0D
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
    mov eax, [get_range_s]
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
    cmp byte [get_info], 0
    jne .r
    mov esi, PKG_BUF
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
