; =============================================================================
;  x509.asm - check an HTTPS server's certificate
;
;  tls_check_server runs after the TLS handshake has authenticated the
;  transcript (server Finished). It decides whether to trust the server:
;
;    1. read the certificates the server sent (DER, X.509)
;    2. the first (leaf) must name the host we asked for (subjectAltName
;       DNS names, with "*." wildcards; the subject CN if there is no SAN)
;    3. each certificate must be signed by the next one, up to one of the
;       root certificates built into MOOS (roots.bin); every issuer must be a
;       CA (basicConstraints) and every certificate must be in date
;    4. the server must have signed the handshake with the leaf's key
;       (CertificateVerify, RSA-PSS with SHA-256)
;
;  Only RSA keys with sha256WithRSAEncryption signatures are supported;
;  anything else is refused (never silently accepted).
;  C-style calls (CCALL); der_hdr is register-based.
; =============================================================================
X_TBS       equ 0                   ; TBSCertificate (whole TLV)
X_TBSLEN    equ 4
X_SIGALG    equ 8                   ; 1/2/3 = sha256/384/512WithRSAEncryption
X_SIG       equ 12                  ; signature bytes
X_SIGLEN    equ 16
X_ISS       equ 20                  ; issuer Name (whole TLV)
X_ISSLEN    equ 24
X_SUB       equ 28                  ; subject Name (whole TLV)
X_SUBLEN    equ 32
X_KEYT      equ 36                  ; 1 = RSA, 2 = EC
X_N         equ 40                  ; RSA modulus
X_NLEN      equ 44
X_E         equ 48                  ; RSA exponent
X_CA        equ 52                  ; 1 = basicConstraints cA
X_SAN       equ 56                  ; subjectAltName GeneralNames (content)
X_SANLEN    equ 60
X_CN        equ 64                  ; subject common name
X_CNLEN     equ 68
X_NB        equ 72                  ; notBefore "YYYYMMDDHHMMSS"
X_NA        equ 88                  ; notAfter
X_SIZE      equ 104
X_MAXCHAIN  equ 8

section .bss
alignb 4
xc_certs    resb X_SIZE * X_MAXCHAIN    ; the server's certificates, parsed
xc_count    resd 1
xc_root     resb X_SIZE                 ; a root being looked at
xc_cur      resd 1                      ; certificate being checked
xc_steps    resd 1
xc_tbs_end  resd 1
xc_cert_end resd 1
xc_ext_end  resd 1
xc_x        resd 1                      ; struct being filled
xc_hash     resb 64
xc_now      resb 16
xc_cvbuf    resb 64 + 34 + 32
xc_found    resd 1
xc_cvsiglen resd 1

section .data
xr_roots:   incbin "src/roots.bin"
; OIDs: length byte, then the encoded OID
oid_rsa         db 9, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01
oid_sha256rsa   db 9, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B
oid_sha384rsa   db 9, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0C
oid_sha512rsa   db 9, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0D
oid_ecpub       db 7, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01
oid_basic       db 3, 0x55, 0x1D, 0x13
oid_san         db 3, 0x55, 0x1D, 0x11
oid_cn          db 3, 0x55, 0x04, 0x03
cv_context      db "TLS 1.3, server CertificateVerify", 0
CV_CONTEXT_LEN  equ 33

xe_read     db "a certificate from the server could not be read", 0
xe_name     db "the certificate is for a different site name", 0
xe_date     db "a certificate is not valid now (expired, or the clock is wrong - try: clock sync)", 0
xe_untrusted db "the certificate is not from an authority MOOS trusts", 0
xe_sig      db "a certificate's signature did not check out", 0
xe_notca    db "a certificate in the chain is not allowed to sign others", 0
xe_ecdsa    db "the server uses an ECDSA certificate (MOOS can only check RSA ones)", 0
xe_alg      db "a certificate uses a signature type MOOS does not support", 0
xe_cv       db "the server could not prove it owns the certificate (bad signature)", 0
xe_cvalg    db "the server signed with an unsupported algorithm", 0
xe_nocert   db "the server sent no certificate", 0

section .text

; der_hdr: ESI = start of a TLV, EDX = end of the enclosing data
; -> AL = tag, ECX = content length, ESI = content start. CF=1 if malformed.
der_hdr:
    push ebx
    lea ebx, [esi + 2]
    cmp ebx, edx
    ja .bad
    mov al, [esi]
    movzx ecx, byte [esi + 1]
    add esi, 2
    test cl, 0x80
    jz .check
    and ecx, 0x7F
    jz .bad                         ; indefinite length: not DER
    cmp ecx, 3
    ja .bad
    mov ebx, ecx
    xor ecx, ecx
.lb:
    cmp esi, edx
    jae .bad
    shl ecx, 8
    mov cl, [esi]
    inc esi
    dec ebx
    jnz .lb
.check:
    lea ebx, [esi + ecx]
    cmp ebx, edx
    ja .bad
    pop ebx
    clc
    ret
.bad:
    pop ebx
    stc
    ret

; der_expect: AH = wanted tag; like der_hdr but CF=1 if the tag differs
der_expect:
    call der_hdr
    jc .r
    cmp al, ah
    je .r                           ; (CF clear from cmp when equal)
    stc
.r: ret

; oid_is: ESI = OID content, ECX = its length, EDI = OID (length-prefixed)
; -> ZF=1 if equal. Registers kept.
oid_is:
    push ecx
    push esi
    push edi
    cmp cl, [edi]
    jne .r
    inc edi
    repe cmpsb
.r: pop edi
    pop esi
    pop ecx
    ret

; x_time: ESI = time TLV, EDX = limit, EDI = 14-byte output
; -> ESI past the TLV, CF=1 if malformed
x_time:
    call der_hdr
    jc .bad
    push ecx
    cmp al, 0x17                    ; UTCTime YYMMDDHHMMSSZ
    je .utc
    cmp al, 0x18                    ; GeneralizedTime YYYYMMDDHHMMSSZ
    jne .badp
    cmp ecx, 15
    jne .badp
    push esi
    mov ecx, 14
    rep movsb
    pop esi
    jmp .done
.utc:
    cmp ecx, 13
    jne .badp
    mov word [edi], '20'            ; 1950-2049 per RFC 5280
    cmp byte [esi], '5'
    jb .century
    mov word [edi], '19'
.century:
    push esi
    push edi
    add edi, 2
    mov ecx, 12
    rep movsb
    pop edi
    pop esi
.done:
    pop ecx
    add esi, ecx
    clc
    ret
.badp:
    pop ecx
.bad:
    stc
    ret

; x_find_cn: ESI = Name content, EDX = its end, EDI = struct -> sets X_CN
x_find_cn:
    pushad
.rdn:
    cmp esi, edx
    jae .done
    call der_hdr                    ; SET
    jc .done
    lea ebx, [esi + ecx]            ; end of this SET
    push edx
    mov edx, ebx
.atv:
    cmp esi, edx
    jae .set_done
    call der_hdr                    ; SEQUENCE { OID, value }
    jc .set_done
    lea ebp, [esi + ecx]
    push edx
    mov edx, ebp
    call der_hdr                    ; OID
    jc .atv_skip
    push edi
    mov edi, oid_cn
    call oid_is
    pop edi
    jne .atv_skip
    add esi, ecx
    call der_hdr                    ; the value (a string)
    jc .atv_skip
    mov [edi + X_CN], esi
    mov [edi + X_CNLEN], ecx
.atv_skip:
    pop edx
    mov esi, ebp
    jmp .atv
.set_done:
    pop edx
    mov esi, ebx
    jmp .rdn
.done:
    popad
    ret

; x509_parse(der, len, x) -> EAX = 1 if the certificate could be read
x509_parse:
    CENTER
    mov edi, ARG(2)
    mov [xc_x], edi
    CCALL c_memzero, edi, X_SIZE
    mov esi, ARG(0)
    mov edx, esi
    add edx, ARG(1)
    mov ah, 0x30                    ; Certificate
    call der_expect
    jc .bad
    lea eax, [esi + ecx]
    mov [xc_cert_end], eax
    mov edx, eax
    mov ebx, esi                    ; TBSCertificate (keep the whole TLV)
    mov ah, 0x30
    call der_expect
    jc .bad
    mov [edi + X_TBS], ebx
    lea eax, [esi + ecx]
    mov [xc_tbs_end], eax
    sub eax, ebx
    mov [edi + X_TBSLEN], eax
    mov edx, [xc_tbs_end]
    cmp byte [esi], 0xA0            ; [0] version
    jne .serial
    call der_hdr
    jc .bad
    add esi, ecx
.serial:
    mov ah, 0x02
    call der_expect
    jc .bad
    add esi, ecx
    mov ah, 0x30                    ; signature algorithm (inside)
    call der_expect
    jc .bad
    add esi, ecx
    mov ebx, esi                    ; issuer
    mov ah, 0x30
    call der_expect
    jc .bad
    mov [edi + X_ISS], ebx
    lea eax, [esi + ecx]
    sub eax, ebx
    mov [edi + X_ISSLEN], eax
    add esi, ecx
    mov ah, 0x30                    ; validity
    call der_expect
    jc .bad
    push edx
    lea edx, [esi + ecx]
    push edi
    lea edi, [edi + X_NB]
    call x_time
    pop edi
    jc .bad_pop
    push edi
    lea edi, [edi + X_NA]
    call x_time
    pop edi
    jc .bad_pop
    pop edx
    mov ebx, esi                    ; subject
    mov ah, 0x30
    call der_expect
    jc .bad
    mov [edi + X_SUB], ebx
    lea eax, [esi + ecx]
    sub eax, ebx
    mov [edi + X_SUBLEN], eax
    push edx
    lea edx, [esi + ecx]
    push esi
    call x_find_cn
    pop esi
    pop edx
    add esi, ecx
    ; --- subjectPublicKeyInfo
    mov ah, 0x30
    call der_expect
    jc .bad
    lea ebx, [esi + ecx]            ; end of SPKI
    push edx
    mov edx, ebx
    mov ah, 0x30                    ; AlgorithmIdentifier
    call der_expect
    jc .bad_pop
    lea ebp, [esi + ecx]
    push edx
    mov edx, ebp
    mov ah, 0x06
    call der_expect
    pop edx
    jc .bad_pop
    push edi
    mov edi, oid_rsa
    call oid_is
    pop edi
    jne .not_rsa
    mov dword [edi + X_KEYT], 1
    jmp .alg_done
.not_rsa:
    push edi
    mov edi, oid_ecpub
    call oid_is
    pop edi
    jne .alg_done
    mov dword [edi + X_KEYT], 2
.alg_done:
    mov esi, ebp
    mov ah, 0x03                    ; BIT STRING with the key
    call der_expect
    jc .bad_pop
    cmp dword [edi + X_KEYT], 1
    jne .spki_done
    inc esi                         ; unused-bits byte
    lea edx, [esi + ecx - 1]
    mov ah, 0x30                    ; RSAPublicKey
    call der_expect
    jc .bad_pop
    mov ah, 0x02                    ; modulus
    call der_expect
    jc .bad_pop
    mov [edi + X_N], esi
    mov [edi + X_NLEN], ecx
    add esi, ecx
    mov ah, 0x02                    ; exponent
    call der_expect
    jc .bad_pop
    xor eax, eax
.e: jecxz .e_done
    cmp eax, 0x00FFFFFF
    ja .bad_pop                     ; more than 32 bits: refuse
    shl eax, 8
    mov al, [esi]
    inc esi
    dec ecx
    jmp .e
.e_done:
    mov [edi + X_E], eax
.spki_done:
    pop edx
    mov esi, ebx
    ; --- optional unique IDs, then extensions
.opt:
    cmp esi, edx
    jae .tbs_done
    mov al, [esi]
    cmp al, 0xA3
    je .exts
    call der_hdr                    ; [1] / [2] unique IDs: skip
    jc .bad
    add esi, ecx
    jmp .opt
.exts:
    call der_hdr
    jc .bad
    mov ah, 0x30
    call der_expect
    jc .bad
    lea eax, [esi + ecx]
    mov [xc_ext_end], eax
.ext:
    cmp esi, [xc_ext_end]
    jae .tbs_done
    mov edx, [xc_ext_end]
    mov ah, 0x30                    ; Extension
    call der_expect
    jc .bad
    lea ebx, [esi + ecx]
    mov edx, ebx
    mov ah, 0x06                    ; extnID
    call der_expect
    jc .bad
    mov ebp, esi                    ; remember the OID
    push ecx
    add esi, ecx
    cmp byte [esi], 0x01            ; critical BOOLEAN (optional)
    jne .val
    call der_hdr
    jc .bad_ext
    add esi, ecx
.val:
    mov ah, 0x04                    ; extnValue OCTET STRING
    call der_expect
    jc .bad_ext
    pop eax                         ; OID length
    push esi
    push ecx
    mov ecx, eax
    xchg esi, ebp                   ; ESI = OID, EBP = value
    push edi
    mov edi, oid_basic
    call oid_is
    pop edi
    je .basic
    push edi
    mov edi, oid_san
    call oid_is
    pop edi
    je .san
    jmp .ext_next
.basic:
    pop ecx
    pop esi
    push esi
    push ecx
    lea edx, [esi + ecx]
    mov ah, 0x30
    call der_expect
    jc .ext_next
    jecxz .ext_next                 ; empty: cA defaults to FALSE
    cmp byte [esi], 0x01
    jne .ext_next
    call der_hdr
    jc .ext_next
    cmp byte [esi], 0
    je .ext_next
    mov dword [edi + X_CA], 1
    jmp .ext_next
.san:
    pop ecx
    pop esi
    push esi
    push ecx
    lea edx, [esi + ecx]
    mov ah, 0x30
    call der_expect
    jc .ext_next
    mov [edi + X_SAN], esi
    mov [edi + X_SANLEN], ecx
.ext_next:
    pop ecx
    pop esi
    mov esi, ebx
    jmp .ext
.bad_ext:
    pop eax
    jmp .bad
.tbs_done:
    mov esi, [xc_tbs_end]           ; signatureAlgorithm (outside the TBS)
    mov edx, [xc_cert_end]
    mov ah, 0x30
    call der_expect
    jc .bad
    lea ebx, [esi + ecx]
    push edx
    mov edx, ebx
    mov ah, 0x06
    call der_expect
    pop edx
    jc .bad
    push edi
    mov edi, oid_sha256rsa
    call oid_is
    pop edi
    jne .not256
    mov dword [edi + X_SIGALG], 1
.not256:
    push edi
    mov edi, oid_sha384rsa
    call oid_is
    pop edi
    jne .not384
    mov dword [edi + X_SIGALG], 2
.not384:
    push edi
    mov edi, oid_sha512rsa
    call oid_is
    pop edi
    jne .sigalg_other
    mov dword [edi + X_SIGALG], 3
.sigalg_other:
    mov esi, ebx
    mov ah, 0x03                    ; signatureValue BIT STRING
    call der_expect
    jc .bad
    cmp ecx, 2
    jb .bad
    cmp byte [esi], 0               ; no unused bits
    jne .bad
    inc esi
    dec ecx
    mov [edi + X_SIG], esi
    mov [edi + X_SIGLEN], ecx
    mov eax, 1
    CLEAVE
.bad_pop:
    pop edx
.bad:
    xor eax, eax
    CLEAVE

; ------------------------------------------------------------- names
; x_name_eq(a, b) -> EAX = 1 if two parsed certs' fields match:
;   compares a.X_ISS with b.X_SUB (is b the issuer of a?)
x_issued_by:
    CENTER
    mov esi, ARG(0)
    mov edi, ARG(1)
    xor eax, eax
    mov ecx, [esi + X_ISSLEN]
    cmp ecx, [edi + X_SUBLEN]
    jne .r
    CCALL c_memeq, dword [esi + X_ISS], dword [edi + X_SUB], ecx
.r: CLEAVE

; host_char_lower: AL -> lower case
%macro LOWER 1
    cmp %1, 'A'
    jb %%k
    cmp %1, 'Z'
    ja %%k
    add %1, 32
%%k:
%endmacro

; dns_match(pattern, plen, host) -> EAX = 1 if the pattern covers the host.
; "*.example.com" matches exactly one extra label ("a.example.com").
dns_match:
    CENTER
    mov esi, ARG(0)
    mov ecx, ARG(1)
    mov edi, ARG(2)
    cmp ecx, 2
    jb .exact
    cmp word [esi], '*.'
    jne .exact
.wild:                              ; skip the host's first label
    mov al, [edi]
    test al, al
    jz .no
    cmp al, '.'
    je .label_end
    inc edi
    jmp .wild
.label_end:
    cmp edi, ARG(2)                 ; the label must not be empty
    je .no
    inc esi                         ; compare ".example.com" parts
    dec ecx
.exact:
    jecxz .end
    mov al, [esi]
    mov ah, [edi]
    LOWER al
    LOWER ah
    cmp al, ah
    jne .no
    inc esi
    inc edi
    dec ecx
    jmp .exact
.end:
    cmp byte [edi], 0               ; host must end here too
    jne .no
    mov eax, 1
    CLEAVE
.no:
    xor eax, eax
    CLEAVE

; x_name_ok(x, host) -> EAX = 1 if the certificate covers this host name
x_name_ok:
    CENTER
    mov ebx, ARG(0)
    mov esi, ARG(1)                 ; a numeric host is matched against
    call parse_ipv4                 ; iPAddress entries instead
    mov [xc_found], eax
    setnc al
    movzx eax, al
    mov [xc_steps], eax             ; (reused: 1 = host is an IP)
    cmp dword [ebx + X_SAN], 0
    je .cn
    mov esi, [ebx + X_SAN]
    mov edx, esi
    add edx, [ebx + X_SANLEN]
.gn:
    cmp esi, edx
    jae .no
    call der_hdr
    jc .no
    cmp dword [xc_steps], 1
    je .ip
    cmp al, 0x82                    ; dNSName
    jne .next
    push edx
    push esi
    push ecx
    CCALL dns_match, esi, ecx, dword ARG(1)
    pop ecx
    pop esi
    pop edx
    test eax, eax
    jnz .yes
    jmp .next
.ip:
    cmp al, 0x87                    ; iPAddress
    jne .next
    cmp ecx, 4
    jne .next
    mov eax, [esi]
    cmp eax, [xc_found]
    je .yes
.next:
    add esi, ecx
    jmp .gn
.cn:                                ; no SAN: fall back to the subject CN
    cmp dword [ebx + X_CN], 0
    je .no
    CCALL dns_match, dword [ebx + X_CN], dword [ebx + X_CNLEN], dword ARG(1)
    CLEAVE
.yes:
    mov eax, 1
    CLEAVE
.no:
    xor eax, eax
    CLEAVE

; --------------------------------------------------------------- time
; x_set_now: xc_now = current UTC time as "YYYYMMDDHHMMSS"
x_set_now:
    pushad
    cmp byte [clk_source], 1
    jne .hw
    call clk_now_epoch              ; internet time (+ timezone offset)
    sub eax, [clk_tz_min_sec]
    call epoch_to_datetime
    jmp .fmt
.hw:
    call rtc_read                   ; hardware clock (assumed close to UTC)
.fmt:
    mov edi, xc_now
    movzx eax, word [rtc_year]
    mov ebx, 1000
    call .digits4
    movzx eax, byte [rtc_month]
    call .two
    movzx eax, byte [rtc_day]
    call .two
    movzx eax, byte [rtc_hour]
    call .two
    movzx eax, byte [rtc_min]
    call .two
    movzx eax, byte [rtc_sec]
    call .two
    popad
    ret
.digits4:
    mov ecx, 4
.d4:
    xor edx, edx
    div ebx
    add al, '0'
    stosb
    mov eax, edx
    push eax
    mov eax, ebx
    xor edx, edx
    push ecx
    mov ecx, 10
    div ecx
    pop ecx
    mov ebx, eax
    pop eax
    dec ecx
    jnz .d4
    ret
.two:
    xor edx, edx
    mov ecx, 10
    div ecx
    add al, '0'
    stosb
    mov al, dl
    add al, '0'
    stosb
    ret

; x_in_date(x) -> EAX = 1 if notBefore <= now <= notAfter
x_in_date:
    CENTER
    mov ebx, ARG(0)
    lea esi, [ebx + X_NB]           ; now < notBefore?
    mov edi, xc_now
    mov ecx, 14
    repe cmpsb
    ja .no                          ; notBefore > now
    lea esi, [ebx + X_NA]           ; now > notAfter?
    mov edi, xc_now
    mov ecx, 14
    repe cmpsb
    jb .no                          ; notAfter < now
    mov eax, 1
    CLEAVE
.no:
    xor eax, eax
    CLEAVE

; ---------------------------------------------------------- signatures
; x_check_sig(cert, issuer) -> EAX = 1 if issuer's key signed cert
x_check_sig:
    CENTER
    mov ebx, ARG(0)
    mov esi, ARG(1)
    xor eax, eax
    mov edi, [ebx + X_SIGALG]       ; 1/2/3 -> hash of 32/48/64 bytes
    cmp edi, 1
    jb .alg
    cmp edi, 3
    ja .alg
    cmp dword [esi + X_KEYT], 1
    jne .alg
    shl edi, 4
    add edi, 16
    CCALL hash_by_len, dword [ebx + X_TBS], dword [ebx + X_TBSLEN], xc_hash, edi
    mov esi, ARG(1)
    CCALL rsa_pkcs1_verify, dword [esi + X_N], dword [esi + X_NLEN], dword [esi + X_E], dword [ebx + X_SIG], dword [ebx + X_SIGLEN], xc_hash, edi
    test eax, eax
    jnz .r
    mov dword [tls_err], xe_sig
    CLEAVE
.alg:
    mov dword [tls_err], xe_alg
    xor eax, eax
.r: CLEAVE

; x_root_for(cert) -> EAX = 1 if a built-in root issued and signed it
x_root_for:
    CENTER
    mov esi, xr_roots
.l: movzx ecx, word [esi]
    xchg cl, ch
    test ecx, ecx
    jz .none
    add esi, 2
    push esi
    push ecx
    CCALL x509_parse, esi, ecx, xc_root
    test eax, eax
    jz .next
    CCALL x_issued_by, dword ARG(0), xc_root
    test eax, eax
    jz .next
    CCALL x_check_sig, dword ARG(0), xc_root
    test eax, eax
    jz .next
    pop ecx
    pop esi
    mov eax, 1
    CLEAVE
.next:
    pop ecx
    pop esi
    add esi, ecx
    jmp .l
.none:
    xor eax, eax
    CLEAVE

; ------------------------------------------------------ the whole check
; tls_check_server -> EAX = 1 if the server is who it says it is
tls_check_server:
    CENTER
    ; --- split the Certificate message into DER certificates
    mov esi, [tls_cert_msg]
    mov edx, esi
    add edx, [tls_cert_len]
    add esi, 4
    movzx eax, byte [esi]           ; request context
    lea esi, [esi + eax + 1]
    add esi, 3                      ; certificate_list length (bounded by EDX)
    mov dword [xc_count], 0
.split:
    lea eax, [esi + 3]
    cmp eax, edx
    ja .split_done
    cmp dword [xc_count], X_MAXCHAIN
    jae .split_done
    movzx ecx, byte [esi]
    shl ecx, 8
    mov cl, [esi + 1]
    shl ecx, 8
    mov cl, [esi + 2]
    add esi, 3
    lea eax, [esi + ecx]
    cmp eax, edx
    ja .readerr
    mov eax, [xc_count]
    imul eax, X_SIZE
    add eax, xc_certs
    push edx
    push esi
    push ecx
    CCALL x509_parse, esi, ecx, eax
    pop ecx
    pop esi
    pop edx
    test eax, eax
    jz .readerr
    inc dword [xc_count]
    add esi, ecx                    ; skip this entry's extensions
    lea eax, [esi + 2]
    cmp eax, edx
    ja .split_done
    movzx eax, word [esi]
    xchg al, ah
    lea esi, [esi + eax + 2]
    jmp .split
.split_done:
    cmp dword [xc_count], 0
    jne .have
    mov dword [tls_err], xe_nocert
    jmp .fail
.have:
    ; --- the leaf must be for this host, and RSA
    cmp dword [xc_certs + X_KEYT], 1
    je .rsa
    mov dword [tls_err], xe_ecdsa
    cmp dword [xc_certs + X_KEYT], 2
    je .fail
    mov dword [tls_err], xe_alg
    jmp .fail
.rsa:
    CCALL x_name_ok, xc_certs, dword [tls_host]
    test eax, eax
    jnz .name_ok
    mov dword [tls_err], xe_name
    jmp .fail
.name_ok:
    call x_set_now
    ; --- walk up the chain to a built-in root
    mov dword [xc_cur], xc_certs
    mov dword [xc_steps], 0
.walk:
    CCALL x_in_date, dword [xc_cur]
    test eax, eax
    jnz .dated
    mov dword [tls_err], xe_date
    jmp .fail
.dated:
    CCALL x_root_for, dword [xc_cur]
    test eax, eax
    jnz .chain_ok
    inc dword [xc_steps]
    cmp dword [xc_steps], X_MAXCHAIN
    ja .untrusted
    xor ebx, ebx                    ; find the issuer among the others
.find:
    cmp ebx, [xc_count]
    jae .untrusted
    mov edi, ebx
    imul edi, X_SIZE
    add edi, xc_certs
    cmp edi, [xc_cur]
    je .find_next
    push edi
    CCALL x_issued_by, dword [xc_cur], edi
    pop edi
    test eax, eax
    jz .find_next
    cmp dword [edi + X_CA], 1       ; an issuer must be a CA
    je .is_ca
    mov dword [tls_err], xe_notca
    jmp .fail
.is_ca:
    push edi
    CCALL x_check_sig, dword [xc_cur], edi
    pop edi
    test eax, eax
    jz .fail
    mov [xc_cur], edi
    jmp .walk
.find_next:
    inc ebx
    jmp .find
.untrusted:
    mov dword [tls_err], xe_untrusted
    jmp .fail
.chain_ok:
    ; --- CertificateVerify: RSA-PSS over the handshake, with the leaf key
    mov esi, [tls_cv_msg]
    test esi, esi
    jz .cvbad
    cmp dword [tls_cv_len], 8
    jb .cvbad
    cmp word [esi + 4], 0x0408      ; rsa_pss_rsae_sha256 (08 04)
    je .cv_alg_ok
    mov dword [tls_err], xe_cvalg
    jmp .fail
.cv_alg_ok:
    movzx ecx, word [esi + 6]
    xchg cl, ch
    lea eax, [ecx + 8]
    cmp eax, [tls_cv_len]
    ja .cvbad
    mov edi, xc_cvbuf               ; 64 spaces | context | 0 | hash
    mov al, ' '
    push ecx
    mov ecx, 64
    rep stosb
    push esi
    mov esi, cv_context
    mov ecx, CV_CONTEXT_LEN + 1     ; (includes the 0 separator)
    rep movsb
    mov esi, tls_cv_hash
    mov ecx, 32
    rep movsb
    pop esi
    pop ecx
    mov [xc_cvsiglen], ecx          ; (CCALL below may change ECX)
    CCALL sha256, xc_cvbuf, 64 + CV_CONTEXT_LEN + 1 + 32, xc_hash
    lea eax, [esi + 8]
    CCALL rsa_pss_verify, dword [xc_certs + X_N], dword [xc_certs + X_NLEN], dword [xc_certs + X_E], eax, dword [xc_cvsiglen], xc_hash
    test eax, eax
    jz .cvbad
    mov eax, 1
    CLEAVE
.cvbad:
    mov dword [tls_err], xe_cv
    jmp .fail
.readerr:
    mov dword [tls_err], xe_read
.fail:
    xor eax, eax
    CLEAVE
