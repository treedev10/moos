; =============================================================================
;  net_cookie.asm - the cookie jar (RFC 6265)
;
;  Servers set cookies with "Set-Cookie:" headers; MOOS keeps them here (in
;  memory, until the next start or "net cookies clear") and sends the ones
;  that belong to a request back in its "Cookie:" header.
;
;    Set-Cookie: name=value; Domain=example.com; Path=/; Secure; HttpOnly;
;                Max-Age=3600; Expires=Wed, 21 Oct 2026 07:28:00 GMT
;
;  - Domain: the cookie also goes to sub-domains; it must match the server
;    that set it (else the cookie is refused). Without it the cookie goes to
;    exactly that host ("host-only").
;  - Path: the cookie goes to that path and below. Without it: the request
;    path up to its last "/".
;  - Secure: only over HTTPS (and only an HTTPS server may set it).
;  - Max-Age (seconds; 0 or less deletes the cookie) wins over Expires (a
;    date; one in the past deletes it). Without either: kept until restart.
;  - A cookie with the same name, domain and path replaces the old one.
;
;  Limits: 64 cookies (when full, an expired one or else the oldest goes),
;  names up to 63 characters, values cut at 1071, domains 127, paths 255.
;  No public-suffix list: a Domain without a dot (like "com") is refused.
;  Dates are compared with the PC clock (UTC).
; =============================================================================
COOKIE_JAR  equ NET_STREAM + 0x5C000    ; 64 entries x 1536 bytes
CK_MAX      equ 64
CK_SIZE     equ 1536
CK_FLAGS    equ 0                       ; CKF_* (byte)
CK_EXPIRES  equ 4                       ; Unix time (UTC), 0 = until restart
CK_SEQ      equ 8                       ; creation order
CK_NAME     equ 16                      ; 64 bytes
CK_DOMAIN   equ 80                      ; 128 bytes (lower case)
CK_PATH     equ 208                     ; 256 bytes
CK_VALUE    equ 464                     ; 1072 bytes
CK_NAME_MAX equ 64
CK_DOM_MAX  equ 128
CK_PATH_MAX equ 256
CK_VAL_MAX  equ 1072

CKF_USED    equ 1
CKF_SECURE  equ 2
CKF_HOSTONLY equ 4
CKF_HTTPONLY equ 8

section .bss
alignb 4
ck_seq      resd 1                      ; next creation number
ck_now      resd 1                      ; the time now (Unix, UTC)
ck_expires  resd 1                      ; the new cookie: expiry,
ck_flags    resd 1                      ;   flags,
ck_maxage   resb 1                      ;   Max-Age seen (wins over Expires)
ck_haveexp  resb 1                      ;   Expires seen
alignb 4
ck_pair_end resd 1
ck_attr_end resd 1
ck_count    resd 1
ck_order    resd CK_MAX                 ; cookies to send, best first
ck_name     resb CK_NAME_MAX
ck_domain   resb CK_DOM_MAX
ck_path     resb CK_PATH_MAX
ck_value    resb CK_VAL_MAX
ck_reqpath  resb CK_PATH_MAX            ; the request's path (no ?query)
; date parsing
ck_d_found  resb 4                      ; time, day, month, year seen
alignb 4
ck_d_hms    resd 3
ck_d_day    resd 1
ck_d_mon    resd 1
ck_d_year   resd 1

section .data
ck_a_expires  db "expires", 0
ck_a_maxage   db "max-age", 0
ck_a_domain   db "domain", 0
ck_a_path     db "path", 0
ck_a_secure   db "secure", 0
ck_a_httponly db "httponly", 0
ck_hdr_name   db "Cookie: ", 0
ck_months     db "janfebmaraprmayjunjulaugsepoctnovdec"

section .text

; ------------------------------------------------------------ helpers
; net_now_utc -> EAX = the time now as Unix seconds (UTC). Registers kept.
net_now_utc:
    push ebx
    push ecx
    push edx
    push ebp
    cmp byte [clk_source], 1            ; synced from the internet?
    jne .hw
    call clk_now_epoch
    sub eax, [clk_tz_min_sec]
    jmp .done
.hw:
    call rtc_read                       ; the PC clock (taken as UTC)
    call datetime_to_epoch
.done:
    pop ebp
    pop edx
    pop ecx
    pop ebx
    ret

; ck_trim: ESI = start, EDI = end of a piece of text -> both moved past
; spaces and tabs at either end
ck_trim:
.l: cmp esi, edi
    jae .r
    cmp byte [esi], ' '
    je .s
    cmp byte [esi], 9
    jne .e
.s: inc esi
    jmp .l
.e: cmp edi, esi
    jbe .r
    cmp byte [edi - 1], ' '
    je .t
    cmp byte [edi - 1], 9
    jne .r
.t: dec edi
    jmp .e
.r: ret

; ck_ieq: ESI = text, ECX = its length, EDI = a lower-case word ->
; ZF=1 if they are the same, ignoring case. Registers kept.
ck_ieq:
    pushad
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
    cmp byte [edi], 0                   ; (the word must end here too)
.out:
    popad
    ret

; ck_copy: ESI = text, ECX = its length, EDI = destination, EDX = its size
; -> copied, cut to EDX - 1 characters, with a 0 after. Registers kept.
ck_copy:
    pushad
    dec edx
    cmp ecx, edx
    jbe .n
    mov ecx, edx
.n: rep movsb
    mov byte [edi], 0
    popad
    ret

; ck_find_char: ESI = text (zero-terminated), AL = character -> EDX =
; where it is, or the terminating 0 (or a ';' when AL is '=': a value stops
; there). Registers kept.
ck_find_char:
    mov edx, esi
.l: cmp byte [edx], 0
    je .r
    cmp [edx], al
    je .r
    cmp byte [edx], ';'
    je .r
    inc edx
    jmp .l
.r: ret

; ck_is_ip: ESI = host -> CF=0 if it is a numeric IPv4 address
ck_is_ip:
    push eax
    call parse_ipv4
    pop eax
    ret

; ck_domain_match: ESI = host, EDI = cookie domain (both lower case) ->
; ZF=1 if the host is the domain or a name under it (RFC 6265 5.1.3)
ck_domain_match:
    pushad
    call str_icmp
    je .yes
    call ck_is_ip                       ; (no sub-domains of an address)
    jnc .no
    push esi
    mov esi, edi
    call str_len                        ; ECX = domain length
    pop esi
    mov edx, ecx
    call str_len                        ; ECX = host length
    cmp ecx, edx
    jbe .no
    sub ecx, edx                        ; the host must end in "." + domain
    cmp byte [esi + ecx - 1], '.'
    jne .no
    add esi, ecx
    call str_icmp
    je .yes
.no:
    or esi, esi                         ; ZF=0 (ESI is not 0)
    jnz .out
.yes:
    xor eax, eax                        ; ZF=1
.out:
    popad
    ret

; ck_set_reqpath: ck_reqpath = url_path without its ?query
ck_set_reqpath:
    pushad
    mov esi, url_path
    mov edi, ck_reqpath
    mov ecx, CK_PATH_MAX - 1
.l: mov al, [esi]
    test al, al
    jz .e
    cmp al, '?'
    je .e
    mov [edi], al
    inc esi
    inc edi
    dec ecx
    jnz .l
.e: mov byte [edi], 0
    cmp byte [ck_reqpath], '/'
    je .r
    mov word [ck_reqpath], '/'
.r: popad
    ret

; ck_path_match: ESI = request path, EDI = cookie path -> ZF=1 if the
; request is at or below the cookie's path (RFC 6265 5.1.4)
ck_path_match:
    pushad
.l: mov al, [edi]
    test al, al
    jz .prefix
    cmp al, [esi]
    jne .no
    inc esi
    inc edi
    jmp .l
.prefix:                                ; the cookie path is a prefix:
    cmp byte [esi], 0                   ; the same path,
    je .yes
    cmp byte [edi - 1], '/'             ; or it ends in "/",
    je .yes
    cmp byte [esi], '/'                 ; or the request goes on with "/"
    je .yes
.no:
    or esi, esi
    jnz .out
.yes:
    xor eax, eax
.out:
    popad
    ret

; ck_entry: EBX = index -> EDI = that cookie
ck_entry:
    imul edi, ebx, CK_SIZE
    add edi, COOKIE_JAR
    ret

; ------------------------------------------------------------ Set-Cookie
; cookie_set: ESI = a Set-Cookie header's value (zero-terminated). The
; request it answered is url_host / url_path / url_scheme. Stores, replaces
; or deletes the cookie; a cookie that may not be set is ignored.
cookie_set:
    pushad
    call net_now_utc
    mov [ck_now], eax
    mov dword [ck_expires], 0
    mov dword [ck_flags], CKF_USED | CKF_HOSTONLY
    mov byte [ck_maxage], 0
    mov byte [ck_haveexp], 0
    mov byte [ck_domain], 0
    mov byte [ck_path], 0
    ; --- name=value, up to the first ';'
    mov al, '='
    call ck_find_char
    cmp byte [edx], '='
    jne .ignore                         ; no '=': not a cookie
    push esi
    mov edi, edx
    call ck_trim
    mov ecx, edi
    sub ecx, esi                        ; the name
    jz .ignore_pop
    cmp ecx, CK_NAME_MAX - 1
    ja .ignore_pop
    mov edi, ck_name
    push edx
    mov edx, CK_NAME_MAX
    call ck_copy
    pop edx
    pop esi
    lea esi, [edx + 1]                  ; the value, up to ';'
    mov al, ';'
    call ck_find_char
    mov [ck_pair_end], edx
    mov edi, edx
    call ck_trim
    mov ecx, edi
    sub ecx, esi
    mov edi, ck_value
    mov edx, CK_VAL_MAX                 ; (long values are cut)
    call ck_copy
    ; --- the attributes
    mov esi, [ck_pair_end]
.attr:
    cmp byte [esi], ';'
    jne .attrs_done
    inc esi
    mov al, ';'                         ; this attribute ends at ';' or 0
    call ck_find_char
    mov [ck_attr_end], edx
    mov al, '='
    call ck_find_char                   ; EDX = '=' (or the end)
    push esi
    mov edi, edx
    call ck_trim                        ; ESI..EDI = the attribute's name
    mov ecx, edi
    sub ecx, esi
    mov ebx, esi
    pop esi
    lea esi, [edx + 1]                  ; ESI..EDI = its value (may be empty)
    cmp byte [edx], '='
    je .has_val
    mov esi, edx
.has_val:
    mov edi, [ck_attr_end]
    call ck_trim
    xchg esi, ebx                       ; ESI = name (ECX long), EBX = value
    mov edx, edi                        ; EDX = end of the value
    mov edi, ck_a_maxage
    call ck_ieq
    je .maxage
    mov edi, ck_a_expires
    call ck_ieq
    je .expires
    mov edi, ck_a_domain
    call ck_ieq
    je .domain
    mov edi, ck_a_path
    call ck_ieq
    je .path
    mov edi, ck_a_secure
    call ck_ieq
    je .secure
    mov edi, ck_a_httponly
    call ck_ieq
    je .httponly
    jmp .next_attr
.maxage:                                ; Max-Age=[-]digits
    mov esi, ebx
    cmp esi, edx
    jae .next_attr
    cmp byte [esi], '-'
    je .past
    xor eax, eax
.ma_d:
    cmp esi, edx
    jae .ma_end
    movzx ecx, byte [esi]
    sub ecx, '0'
    cmp ecx, 9
    ja .next_attr                       ; not a number: ignored
    imul eax, 10
    jo .ma_big
    add eax, ecx
    jc .ma_big
    cmp eax, 0x7FFFFFFF
    ja .ma_big
    inc esi
    jmp .ma_d
.ma_big:
    mov eax, 0x7FFFFFFF
.ma_end:
    test eax, eax
    jz .past
    add eax, [ck_now]
    jnc .ma_set
    mov eax, 0xFFFFFFFE
.ma_set:
    mov [ck_expires], eax
    mov byte [ck_maxage], 1
    jmp .next_attr
.past:
    mov dword [ck_expires], 1           ; (the distant past)
    mov byte [ck_maxage], 1
    jmp .next_attr
.expires:
    cmp byte [ck_maxage], 0             ; Max-Age wins
    jne .next_attr
    mov esi, ebx
    call cookie_parse_date
    jc .next_attr
    mov [ck_expires], eax
    mov byte [ck_haveexp], 1
    jmp .next_attr
.domain:
    mov esi, ebx
    cmp esi, edx
    jae .next_attr
    cmp byte [esi], '.'                 ; ".example.com" = "example.com"
    jne .dom1
    inc esi
.dom1:
    mov ecx, edx
    sub ecx, esi
    jz .next_attr
    cmp ecx, CK_DOM_MAX - 1
    ja .ignore
    mov edi, ck_domain
    mov edx, CK_DOM_MAX
    call ck_copy
    push esi
    mov esi, ck_domain
    call str_lower
    pop esi
    jmp .next_attr
.path:
    mov esi, ebx
    mov ecx, edx
    sub ecx, esi
    jz .next_attr
    cmp byte [esi], '/'
    jne .next_attr                      ; (not a path: the default is used)
    mov edi, ck_path
    mov edx, CK_PATH_MAX
    call ck_copy
    jmp .next_attr
.secure:
    or dword [ck_flags], CKF_SECURE
    jmp .next_attr
.httponly:
    or dword [ck_flags], CKF_HTTPONLY
.next_attr:
    mov esi, [ck_attr_end]
    jmp .attr
.attrs_done:
    ; --- may this server set it?
    test dword [ck_flags], CKF_SECURE   ; Secure only from HTTPS
    jz .sec_ok
    cmp byte [url_scheme], 1
    jne .ignore
.sec_ok:
    cmp byte [ck_domain], 0
    je .host_only
    mov esi, ck_domain                  ; a Domain without a dot ("com"):
    mov al, '.'                         ; only if it is the host itself
    call ck_find_char
    cmp byte [edx], '.'
    je .dom_dot
    mov esi, url_host
    mov edi, ck_domain
    call str_icmp
    je .host_only
    jmp .ignore
.dom_dot:
    mov esi, url_host
    mov edi, ck_domain
    call ck_domain_match
    jne .ignore                         ; not this server's domain
    and dword [ck_flags], ~CKF_HOSTONLY
    jmp .dom_done
.host_only:
    mov esi, url_host
    mov edi, ck_domain
    call str_copy
    mov esi, ck_domain
    call str_lower
.dom_done:
    cmp byte [ck_path], 0               ; the default path: the request's
    jne .path_done                      ; path up to its last '/'
    call ck_set_reqpath
    mov esi, ck_reqpath
    mov edi, ck_path
    call str_copy
    mov esi, ck_path
    call str_len
.slash:
    dec ecx
    jz .root
    cmp byte [esi + ecx], '/'
    jne .slash
    mov byte [esi + ecx], 0
    jmp .path_done
.root:
    mov word [ck_path], '/'
.path_done:
    ; --- replace or delete one with the same name, domain and path
    xor ebx, ebx
.same:
    call ck_entry
    test byte [edi + CK_FLAGS], CKF_USED
    jz .same_next
    push edi
    lea esi, [edi + CK_NAME]
    mov edi, ck_name
    call str_eq_cs
    pop edi
    jne .same_next
    push edi
    lea esi, [edi + CK_DOMAIN]
    mov edi, ck_domain
    call str_eq_cs
    pop edi
    jne .same_next
    push edi
    lea esi, [edi + CK_PATH]
    mov edi, ck_path
    call str_eq_cs
    pop edi
    je .found
.same_next:
    inc ebx
    cmp ebx, CK_MAX
    jb .same
    ; a new cookie: a free entry, else an expired one, else the oldest
    call ck_expire_all
    xor ebx, ebx
.free:
    call ck_entry
    test byte [edi + CK_FLAGS], CKF_USED
    jz .store
    inc ebx
    cmp ebx, CK_MAX
    jb .free
    xor ebx, ebx                        ; the oldest
    xor edx, edx
    mov eax, 0xFFFFFFFF
.old:
    call ck_entry
    cmp [edi + CK_SEQ], eax
    jae .old_next
    mov eax, [edi + CK_SEQ]
    mov edx, ebx
.old_next:
    inc ebx
    cmp ebx, CK_MAX
    jb .old
    mov ebx, edx
    call ck_entry
    jmp .store
.found:
    mov eax, [ck_expires]               ; expired now: the old one goes
    test eax, eax
    jz .replace
    cmp eax, [ck_now]
    ja .replace
    mov byte [edi + CK_FLAGS], 0
    jmp .done
.replace:
    mov eax, [edi + CK_SEQ]             ; (keeps its age)
    jmp .fill
.store:
    mov eax, [ck_expires]               ; a new cookie already expired: no
    test eax, eax
    jz .new_seq
    cmp eax, [ck_now]
    jbe .done
.new_seq:
    inc dword [ck_seq]
    mov eax, [ck_seq]
.fill:
    mov [edi + CK_SEQ], eax
    mov eax, [ck_flags]
    mov [edi + CK_FLAGS], al
    mov eax, [ck_expires]
    mov [edi + CK_EXPIRES], eax
    mov ebx, edi
    lea edi, [ebx + CK_NAME]
    mov esi, ck_name
    call str_copy
    lea edi, [ebx + CK_DOMAIN]
    mov esi, ck_domain
    call str_copy
    lea edi, [ebx + CK_PATH]
    mov esi, ck_path
    call str_copy
    lea edi, [ebx + CK_VALUE]
    mov esi, ck_value
    call str_copy
.done:
    popad
    ret
.ignore_pop:
    pop esi
.ignore:
    popad
    ret

; str_eq_cs: ESI, EDI = strings -> ZF=1 if exactly the same
str_eq_cs:
    push eax
    push esi
    push edi
.l: mov al, [esi]
    cmp al, [edi]
    jne .out
    inc esi
    inc edi
    test al, al
    jnz .l
.out:
    pop edi
    pop esi
    pop eax
    ret

; ck_expire_all: forget the cookies whose time has passed (ck_now)
ck_expire_all:
    pushad
    xor ebx, ebx
.l: call ck_entry
    test byte [edi + CK_FLAGS], CKF_USED
    jz .n
    mov eax, [edi + CK_EXPIRES]
    test eax, eax
    jz .n
    cmp eax, [ck_now]
    ja .n
    mov byte [edi + CK_FLAGS], 0
.n: inc ebx
    cmp ebx, CK_MAX
    jb .l
    popad
    ret

; cookie_parse_date: ESI = a date (up to ';' or 0) -> EAX = Unix time, CF=1
; if it is not a date. The lenient way of RFC 6265 5.1.1, so all the forms
; servers use work ("Wed, 21 Oct 2026 07:28:00 GMT", "21-Oct-26 ...", ...).
cookie_parse_date:
    pushad
    mov dword [ck_d_found], 0
.token:
    ; skip delimiters
.skip:
    movzx eax, byte [esi]
    test eax, eax
    jz .end
    cmp al, ';'
    je .end
    call ck_is_delim
    jnc .tok
    inc esi
    jmp .skip
.tok:
    mov edi, esi                        ; EDI = token start; find its end
.te:
    movzx eax, byte [esi]
    test eax, eax
    jz .have
    cmp al, ';'
    je .have
    call ck_is_delim
    jc .have
    inc esi
    jmp .te
.have:                                  ; token = EDI .. ESI
    cmp byte [ck_d_found], 0            ; time: h[h]:m[m]:s[s]
    jne .not_time
    push esi
    mov esi, edi
    call ck_digits12
    jc .nt_pop
    mov [ck_d_hms], eax
    cmp byte [esi], ':'
    jne .nt_pop
    inc esi
    call ck_digits12
    jc .nt_pop
    mov [ck_d_hms + 4], eax
    cmp byte [esi], ':'
    jne .nt_pop
    inc esi
    call ck_digits12
    jc .nt_pop
    mov [ck_d_hms + 8], eax
    pop esi
    mov byte [ck_d_found], 1
    jmp .token
.nt_pop:
    pop esi
.not_time:
    cmp byte [ck_d_found + 1], 0        ; day of month: 1-2 digits
    jne .not_day
    push esi
    mov esi, edi
    call ck_digits12
    jc .nd_pop
    movzx ecx, byte [esi]               ; (then no more digits)
    sub ecx, '0'
    cmp ecx, 9
    jbe .nd_pop
    pop esi
    mov [ck_d_day], eax
    mov byte [ck_d_found + 1], 1
    jmp .token
.nd_pop:
    pop esi
.not_day:
    cmp byte [ck_d_found + 2], 0        ; month: starts with its 3 letters
    jne .not_month
    mov eax, esi
    sub eax, edi
    cmp eax, 3
    jb .not_month
    xor ebx, ebx
.mon:
    push esi
    push edi
    lea esi, [ck_months + ebx * 2]
    add esi, ebx                        ; (3 letters each)
    mov ecx, 3
.mc:
    mov al, [edi]
    call to_lower
    cmp al, [esi]
    jne .mnext
    inc esi
    inc edi
    dec ecx
    jnz .mc
.mnext:
    pop edi
    pop esi
    test ecx, ecx
    jz .mfound
    inc ebx
    cmp ebx, 12
    jb .mon
    jmp .not_month
.mfound:
    inc ebx
    mov [ck_d_mon], ebx
    mov byte [ck_d_found + 2], 1
    jmp .token
.not_month:
    cmp byte [ck_d_found + 3], 0        ; year: 2-4 digits
    jne .token
    push esi
    mov esi, edi
    xor eax, eax
    xor ecx, ecx
.yd:
    movzx edx, byte [esi]
    sub edx, '0'
    cmp edx, 9
    ja .yend
    imul eax, 10
    add eax, edx
    inc esi
    inc ecx
    cmp ecx, 4
    jbe .yd
    jmp .ybad                           ; (too many digits)
.yend:
    pop esi
    cmp ecx, 2
    jb .token
    mov [ck_d_year], eax
    mov byte [ck_d_found + 3], 1
    jmp .token
.ybad:
    pop esi
    jmp .token
.end:
    cmp dword [ck_d_found], 0x01010101  ; all four parts?
    jne .bad
    mov eax, [ck_d_year]
    cmp eax, 70                         ; two-digit years
    jb .y2000
    cmp eax, 99
    ja .y4
    add eax, 1900
    jmp .y4
.y2000:
    add eax, 2000
.y4:
    mov [ck_d_year], eax
    mov eax, [ck_d_day]
    test eax, eax
    jz .bad
    cmp eax, 31
    ja .bad
    cmp dword [ck_d_hms], 23
    ja .bad
    cmp dword [ck_d_hms + 4], 59
    ja .bad
    cmp dword [ck_d_hms + 8], 59
    ja .bad
    mov eax, [ck_d_year]
    cmp eax, 1601
    jb .bad
    cmp eax, 1970
    jb .before
    cmp eax, 2105
    ja .after
    mov [rtc_year], ax                  ; datetime_to_epoch reads rtc_*
    mov eax, [ck_d_mon]
    mov [rtc_month], al
    mov eax, [ck_d_day]
    mov [rtc_day], al
    mov eax, [ck_d_hms]
    mov [rtc_hour], al
    mov eax, [ck_d_hms + 4]
    mov [rtc_min], al
    mov eax, [ck_d_hms + 8]
    mov [rtc_sec], al
    push ebp
    call datetime_to_epoch              ; (it uses EBP)
    pop ebp
    test eax, eax
    jnz .ok
.before:
    mov eax, 1                          ; long ago
    jmp .ok
.after:
    mov eax, 0xFFFFFFFE
.ok:
    mov [esp + 28], eax                 ; (EAX in the pushad frame)
    popad
    clc
    ret
.bad:
    popad
    stc
    ret

; ck_is_delim: AL = character -> CF=1 if it separates the parts of a date
ck_is_delim:
    cmp al, 9
    je .yes
    cmp al, 0x20
    jb .no
    cmp al, 0x2F
    jbe .yes
    cmp al, 0x3B
    jb .no
    cmp al, 0x40
    jbe .yes
    cmp al, 0x5B
    jb .no
    cmp al, 0x60
    jbe .yes
    cmp al, 0x7B
    jb .no
    cmp al, 0x7E
    jbe .yes
.no:
    clc
    ret
.yes:
    stc
    ret

; ck_digits12: ESI = text -> EAX = the number in its 1 or 2 digits, ESI
; past them; CF=1 if there is no digit (or there are more than 2)
ck_digits12:
    push ecx
    push edx
    xor eax, eax
    xor ecx, ecx
.l: movzx edx, byte [esi]
    sub edx, '0'
    cmp edx, 9
    ja .e
    imul eax, 10
    add eax, edx
    inc esi
    inc ecx
    jmp .l
.e: test ecx, ecx
    jz .bad
    cmp ecx, 2
    ja .bad
    pop edx
    pop ecx
    clc
    ret
.bad:
    pop edx
    pop ecx
    stc
    ret

; ------------------------------------------------------- Cookie: header
; cookie_header: EDI = where the request is being built, ECX = room there ->
; appends "Cookie: a=1; b=2" + CR LF with the cookies for url_host /
; url_path / url_scheme (longest path first, then oldest first). EDI moves
; past it; nothing is written if no cookie belongs.
cookie_header:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push ebp
    mov ebp, edi
    add ebp, ecx
    sub ebp, 2                          ; EBP = the limit (room for CR LF)
    call net_now_utc
    mov [ck_now], eax
    call ck_expire_all
    call ck_set_reqpath
    mov dword [ck_count], 0
    xor ebx, ebx
.pick:
    push edi
    call ck_entry
    mov edx, edi
    pop edi
    test byte [edx + CK_FLAGS], CKF_USED
    jz .next
    test byte [edx + CK_FLAGS], CKF_SECURE
    jz .sec
    cmp byte [url_scheme], 1
    jne .next
.sec:
    push edi
    mov esi, url_host
    lea edi, [edx + CK_DOMAIN]
    test byte [edx + CK_FLAGS], CKF_HOSTONLY
    jz .sub
    call str_icmp
    jmp .hm
.sub:
    call ck_domain_match
.hm:
    pop edi
    jne .next
    push edi
    mov esi, ck_reqpath
    lea edi, [edx + CK_PATH]
    call ck_path_match
    pop edi
    jne .next
    ; insert EBX into ck_order, best first
    mov ecx, [ck_count]
.ins:
    test ecx, ecx
    jz .put
    push ebx
    mov ebx, [ck_order + ecx * 4 - 4]
    call .before                        ; is cookie EDX before cookie EBX?
    pop ebx
    jnc .put
    mov eax, [ck_order + ecx * 4 - 4]
    mov [ck_order + ecx * 4], eax
    dec ecx
    jmp .ins
.put:
    mov [ck_order + ecx * 4], ebx
    inc dword [ck_count]
.next:
    inc ebx
    cmp ebx, CK_MAX
    jb .pick
    ; write them
    cmp dword [ck_count], 0
    je .none
    mov esi, ck_hdr_name
    call .put_str
    xor ecx, ecx
.w: cmp ecx, [ck_count]
    jae .end
    mov ebx, [ck_order + ecx * 4]
    push edi
    call ck_entry
    mov edx, edi
    pop edi
    ; does "; name=value" still fit?
    push ecx
    lea esi, [edx + CK_NAME]
    call str_len
    mov eax, ecx
    lea esi, [edx + CK_VALUE]
    call str_len
    add eax, ecx
    add eax, 3
    pop ecx
    add eax, edi
    cmp eax, ebp
    ja .skip
    test ecx, ecx
    jz .first
    mov word [edi], '; '
    add edi, 2
.first:
    lea esi, [edx + CK_NAME]
    call .put_str
    mov byte [edi], '='
    inc edi
    lea esi, [edx + CK_VALUE]
    call .put_str
.skip:
    inc ecx
    jmp .w
.end:
    mov word [edi], 0x0A0D
    add edi, 2
.none:
    pop ebp
    pop esi
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret
; .put_str: copy ESI (zero-terminated) to EDI, EDI advanced
.put_str:
    push eax
.ps: lodsb
    test al, al
    jz .ps_end
    stosb
    jmp .ps
.ps_end:
    pop eax
    ret
; .before: EDX = a cookie, EBX = index of another -> CF=1 if EDX's goes
; first (longer path, or the same length and older)
.before:
    push eax
    push ecx
    push edi
    push esi
    lea esi, [edx + CK_PATH]
    call str_len
    mov eax, ecx
    call ck_entry
    lea esi, [edi + CK_PATH]
    call str_len
    cmp eax, ecx
    ja .bf_yes
    jb .bf_no
    mov eax, [edx + CK_SEQ]
    cmp eax, [edi + CK_SEQ]
    jb .bf_yes
.bf_no:
    pop esi
    pop edi
    pop ecx
    pop eax
    clc
    ret
.bf_yes:
    pop esi
    pop edi
    pop ecx
    pop eax
    stc
    ret

; ------------------------------------------------------------ net cookies
; cookie_list: print the jar (for "net cookies")
cookie_list:
    pushad
    call net_now_utc
    mov [ck_now], eax
    call ck_expire_all
    xor ebx, ebx
    xor ebp, ebp
.l: call ck_entry
    test byte [edi + CK_FLAGS], CKF_USED
    jz .n
    inc ebp
    lea eax, [edi + CK_DOMAIN]
    lea ecx, [edi + CK_PATH]
    lea edx, [edi + CK_NAME]
    PRINTF `  \x01w%s\x01n%s  %s=`, eax, ecx, edx
    lea esi, [edi + CK_VALUE]           ; the value, cut for the screen
    call str_len
    cmp ecx, 40
    jbe .v
    mov ecx, 40
.v: jecxz .vdone
.vc:
    lodsb
    call out_char
    loop .vc
    lea esi, [edi + CK_VALUE]
    call str_len
    cmp ecx, 40
    jbe .vdone
    PRINTF `...`
.vdone:
    test byte [edi + CK_FLAGS], CKF_SECURE
    jz .ns
    PRINTF ` [secure]`
.ns:
    test byte [edi + CK_FLAGS], CKF_HOSTONLY
    jnz .nh
    PRINTF ` [+sub-domains]`
.nh:
    mov eax, [edi + CK_EXPIRES]
    test eax, eax
    jnz .exp
    PRINTF ` [until restart]\n`
    jmp .n
.exp:
    sub eax, [ck_now]
    xor edx, edx
    mov ecx, 60
    div ecx
    PRINTF ` [%d min left]\n`, eax
.n: inc ebx
    cmp ebx, CK_MAX
    jb .l
    test ebp, ebp
    jnz .count
    PRINTF `  (no cookies)\n`
    jmp .done
.count:
    PRINTF `%d cookie(s).\n`, ebp
.done:
    popad
    ret

; cookie_clear: forget every cookie
cookie_clear:
    pushad
    mov edi, COOKIE_JAR
    mov ecx, CK_MAX * CK_SIZE / 4
    xor eax, eax
    rep stosd
    popad
    ret
