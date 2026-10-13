; =============================================================================
;  tls.asm - a TLS 1.3 client (RFC 8446) and HTTPS GET
;
;  One cipher suite: TLS_AES_128_GCM_SHA256 (the one every TLS 1.3 server
;  must support). Key exchange: X25519. Server signatures: RSA-PSS (the
;  CertificateVerify) over an RSA certificate chain that x509.asm checks
;  against the built-in root certificates.
;
;  Flow of tls_connect:
;    ClientHello ->  <- ServerHello  (keys from X25519 + HKDF)
;    <- {EncryptedExtensions, Certificate, CertificateVerify, Finished}
;    check the Finished MAC, the certificate chain and the signature
;    -> {Finished}  then application data with the traffic keys.
;
;  C-style calls (CCALL) throughout; see macros.inc.
; =============================================================================
TLS_RX      equ TLS_BASE + 0x00000      ; TCP byte stream from the server (32K)
TLS_RX_CAP  equ 0x8000
TLS_REC     equ TLS_BASE + 0x08000      ; one record, decrypted in place
TLS_HS      equ TLS_BASE + 0x0C800      ; the server's handshake messages (32K)
TLS_HS_CAP  equ 0x8000
TLS_TXB     equ TLS_BASE + 0x14800      ; one outgoing record
TLS_CH      equ TLS_BASE + 0x19000      ; our ClientHello

TK_GCM      equ 0                       ; key state: GCM context,
TK_IV       equ GCM_CTX                 ;   12-byte IV,
TK_SEQ      equ GCM_CTX + 12            ;   record counter
TK_SIZE     equ GCM_CTX + 16

REC_MAX     equ 16384 + 256

section .bss
alignb 4
tls_rkey        resb TK_SIZE            ; server -> us
tls_wkey        resb TK_SIZE            ; us -> server
tls_thash       resb SHA_CTX            ; running transcript hash
tls_thash2      resb SHA_CTX
tls_hash        resb 32
tls_ehash       resb 32                 ; SHA-256 of nothing
tls_zero        resb 32
tls_crandom     resb 32
tls_sid         resb 32
tls_priv        resb 32
tls_pub         resb 32
tls_spub        resb 32
tls_shared      resb 32
tls_secret      resb 32
tls_hs_secret   resb 32
tls_c_hs        resb 32
tls_s_hs        resb 32
tls_c_ap        resb 32
tls_s_ap        resb 32
tls_tmp         resb 32
tls_fkey        resb 32
tls_vdata       resb 32
tls_finmsg      resb 36
tls_nonce       resb 12
tls_hdr         resb 8
tls_rtype       resb 1
tls_rkey_on     resb 1
tls_wkey_on     resb 1
tls_eof         resb 1
tls_verify      resb 1                  ; 1 = check the certificate
tls_debug       resb 1                  ; 1 = print each record (get -v)
tls_got_ver     resb 1
tls_got_ks      resb 1
alignb 4
tls_rlen        resd 1
tls_hs_len      resd 1
tls_hs_pos      resd 1
tls_need        resd 1
tls_host        resd 1                  ; host name (for SNI and the cert)
tls_hostlen     resd 1
tls_sni         resb 1                  ; 0 when the host is an IP address
alignb 4
tls_err         resd 1                  ; error message, or 0
tls_alert       resd 1                  ; last alert description, or -1
tls_msg         resd 1
tls_msglen      resd 1
tls_cert_msg    resd 1                  ; the Certificate message
tls_cert_len    resd 1
tls_cv_msg      resd 1                  ; the CertificateVerify message
tls_cv_len      resd 1
tls_cv_hash     resb 32                 ; transcript hash it signs

section .data
hrr_random  db 0xCF, 0x21, 0xAD, 0x74, 0xE5, 0x9A, 0x61, 0x11, 0xBE, 0x1D, 0x8C, 0x02
            db 0x1E, 0x65, 0xB8, 0x91, 0xC2, 0xA2, 0x11, 0x16, 0x7A, 0xBB, 0x8C, 0x5E
            db 0x07, 0x9E, 0x09, 0xE2, 0xC8, 0xA8, 0x33, 0x9C
; fixed ClientHello extensions
ch_ext_fixed:
            db 0x00, 0x0A, 0x00, 0x04, 0x00, 0x02, 0x00, 0x1D       ; groups: x25519
            db 0x00, 0x0D, 0x00, 0x0A, 0x00, 0x08, 0x08, 0x04, 0x04, 0x01
            db 0x05, 0x01, 0x06, 0x01           ; sig algs: rsa_pss_rsae_sha256 (the
                                                ; handshake), rsa_pkcs1_sha256/384/512
                                                ; (certificate chains)
            db 0x00, 0x2B, 0x00, 0x03, 0x02, 0x03, 0x04             ; versions: TLS 1.3
            db 0x00, 0x2D, 0x00, 0x02, 0x01, 0x01                   ; psk modes: psk_dhe
            db 0x00, 0x10, 0x00, 0x0B, 0x00, 0x09, 0x08             ; ALPN: http/1.1
            db "http/1.1"
            db 0x00, 0x33, 0x00, 0x26, 0x00, 0x24, 0x00, 0x1D, 0x00, 0x20
                                                ; key_share: x25519, 32 bytes...
ch_ext_fixed_len equ $ - ch_ext_fixed
ccs_record  db 20, 3, 3, 0, 1, 1                ; ChangeCipherSpec (compatibility)

te_connect  db "could not connect to the server", 0
te_closed   db "the server closed the connection", 0
te_timeout  db "the server stopped answering", 0
te_record   db "bad TLS record from the server", 0
te_mac      db "a record failed its integrity check (bad MAC)", 0
te_alert    db "the server sent a TLS alert", 0
te_hello    db "the server's hello was not understood", 0
te_hrr      db "the server asked for a different key exchange (not supported)", 0
te_cipher   db "the server chose an unsupported cipher", 0
te_version  db "the server does not speak TLS 1.3", 0
te_ecdh     db "bad key exchange value from the server", 0
te_unexp    db "unexpected handshake message", 0
te_finished db "the server's Finished check failed (connection tampered?)", 0
te_bigmsg   db "handshake too large", 0
te_clientcert db "the server wants a client certificate (not supported)", 0
te_nocert   db "the server sent no certificate", 0

section .text

; ------------------------------------------------------------ the stream
; tls_rx_need(n) -> EAX = 1 once n bytes are buffered, 0 on close/timeout
tls_rx_need:
    CENTER
    mov eax, ARG(0)
    mov [tls_need], eax
.l: mov eax, [tcp_dst_len]
    cmp eax, [tls_need]
    jae .ok
    cmp byte [tcp_closed], 0
    jne .closed
    mov eax, [ticks]
    add eax, 1500                       ; 15 s
    call tcp_pump
    jnc .l
    mov dword [tls_err], te_timeout
    xor eax, eax
    CLEAVE
.closed:
    mov dword [tls_err], te_closed
    xor eax, eax
    CLEAVE
.ok:
    mov eax, 1
    CLEAVE

; tls_rx_consume(n): drop n bytes from the front of the stream buffer
tls_rx_consume:
    CENTER
    mov ebx, ARG(0)
    mov ecx, [tcp_dst_len]
    sub ecx, ebx
    mov [tcp_dst_len], ecx
    mov esi, TLS_RX
    add esi, ebx
    mov edi, TLS_RX
    rep movsb
    CLEAVE

; tls_make_nonce(key): tls_nonce = IV xor record counter
tls_make_nonce:
    CENTER
    mov esi, ARG(0)
    lea esi, [esi + TK_IV]
    mov edi, tls_nonce
    mov ecx, 12
    rep movsb
    mov esi, ARG(0)
    mov eax, [esi + TK_SEQ]
    bswap eax
    xor [tls_nonce + 8], eax
    CLEAVE

; tls_key_install(key, secret32): traffic key + IV from a traffic secret
tls_key_install:
    CENTER
    mov ebx, ARG(0)
    CCALL hkdf_expand_label, dword ARG(1), lbl_key, tls_zero, 0, tls_tmp, 16
    lea eax, [ebx + TK_GCM]
    CCALL gcm_setkey, eax, tls_tmp
    lea eax, [ebx + TK_IV]
    CCALL hkdf_expand_label, dword ARG(1), lbl_iv, tls_zero, 0, eax, 12
    mov dword [ebx + TK_SEQ], 0
    CLEAVE

; ------------------------------------------------------------- records
; tls_read_record -> EAX = 1 with a record in TLS_REC (tls_rtype, tls_rlen;
; decrypted when the read key is on), 0 on error / end (tls_err, tls_eof)
tls_read_record:
    CENTER
    CCALL tls_rx_need, 5
    test eax, eax
    jnz .hdr
    cmp dword [tcp_dst_len], 0          ; closed between records: clean end
    jne .fail
    mov byte [tls_eof], 1
    jmp .fail
.hdr:
    mov eax, [TLS_RX]
    mov [tls_hdr], eax
    mov al, [TLS_RX + 4]
    mov [tls_hdr + 4], al
    movzx ebx, word [TLS_RX + 3]        ; record length (big-endian)
    xchg bl, bh
    cmp ebx, REC_MAX
    ja .badrec
    lea eax, [ebx + 5]
    CCALL tls_rx_need, eax
    test eax, eax
    jz .fail
    CCALL c_memcpy, TLS_REC, TLS_RX + 5, ebx
    lea eax, [ebx + 5]
    CCALL tls_rx_consume, eax
    mov al, [tls_hdr]
    mov [tls_rtype], al
    mov [tls_rlen], ebx
    cmp al, 23                          ; encrypted?
    jne .ok
    cmp byte [tls_rkey_on], 0
    je .ok
    cmp ebx, 17
    jb .badmac
    sub ebx, 16
    CCALL tls_make_nonce, tls_rkey
    lea eax, [TLS_REC + ebx]
    CCALL gcm_open, tls_rkey + TK_GCM, tls_nonce, tls_hdr, 5, TLS_REC, ebx, eax
    test eax, eax
    jz .badmac
    inc dword [tls_rkey + TK_SEQ]
.strip:                                 ; drop zero padding; last byte = type
    dec ebx
    js .badmac
    cmp byte [TLS_REC + ebx], 0
    je .strip
    mov al, [TLS_REC + ebx]
    mov [tls_rtype], al
    mov [tls_rlen], ebx
.ok:
    cmp byte [tls_debug], 0
    je .nodbg
    movzx eax, byte [tls_rtype]
    PRINTF `  [record: type %d, %d bytes]\n`, eax, dword [tls_rlen]
.nodbg:
    cmp byte [tls_rtype], 21            ; remember alerts
    jne .ret1
    movzx eax, byte [TLS_REC + 1]
    mov [tls_alert], eax
.ret1:
    mov eax, 1
    CLEAVE
.badmac:
    mov dword [tls_err], te_mac
    jmp .fail
.badrec:
    mov dword [tls_err], te_record
.fail:
    xor eax, eax
    CLEAVE

; tls_send_record(type, data, len): one record, encrypted once the write key
; is on (len <= 16384)
tls_send_record:
    CENTER
    mov ebx, ARG(2)
    mov edi, TLS_TXB
    cmp byte [tls_wkey_on], 0
    jne .enc
    mov al, ARG(0)                      ; plaintext record
    mov [edi], al
    mov word [edi + 1], 0x0303
    cmp al, 22
    jne .v
    mov word [edi + 1], 0x0103          ; first ClientHello says 0x0301
.v: mov [edi + 3], bh
    mov [edi + 4], bl
    CCALL c_memcpy, TLS_TXB + 5, dword ARG(1), ebx
    lea ecx, [ebx + 5]
    jmp .send
.enc:
    mov byte [edi], 23
    mov word [edi + 1], 0x0303
    lea eax, [ebx + 1 + 16]             ; content + type byte + tag
    mov [edi + 3], ah
    mov [edi + 4], al
    CCALL c_memcpy, TLS_TXB + 5, dword ARG(1), ebx
    mov al, ARG(0)
    mov [TLS_TXB + 5 + ebx], al         ; inner content type
    inc ebx
    CCALL tls_make_nonce, tls_wkey
    lea eax, [TLS_TXB + 5 + ebx]
    CCALL gcm_seal, tls_wkey + TK_GCM, tls_nonce, TLS_TXB, 5, TLS_TXB + 5, ebx, eax
    inc dword [tls_wkey + TK_SEQ]
    lea ecx, [ebx + 5 + 16]
.send:
    mov esi, TLS_TXB
    call tcp_send_all
    CLEAVE

; tls_transcript(out32): hash of the handshake so far
tls_transcript:
    CENTER
    CCALL c_memcpy, tls_thash2, tls_thash, SHA_CTX
    CCALL sha256_final, tls_thash2, dword ARG(0)
    CLEAVE

; tls_next_hs -> EAX = 1 with the next server handshake message in
; tls_msg / tls_msglen (header included), 0 on error
tls_next_hs:
    CENTER
.l: mov eax, [tls_hs_len]
    sub eax, [tls_hs_pos]
    cmp eax, 4
    jb .more
    mov esi, TLS_HS
    add esi, [tls_hs_pos]
    movzx ecx, byte [esi + 1]           ; 24-bit length
    shl ecx, 8
    mov cl, [esi + 2]
    shl ecx, 8
    mov cl, [esi + 3]
    add ecx, 4
    cmp eax, ecx
    jb .more
    add [tls_hs_pos], ecx
    mov [tls_msg], esi
    mov [tls_msglen], ecx
    mov eax, 1
    CLEAVE
.more:
    call tls_read_record
    test eax, eax
    jz .fail
    mov al, [tls_rtype]
    cmp al, 20                          ; ChangeCipherSpec: ignore
    je .l
    cmp al, 21
    je .alert
    cmp al, 22
    jne .unexp
    mov ecx, [tls_rlen]
    mov edi, [tls_hs_len]
    lea eax, [edi + ecx]
    cmp eax, TLS_HS_CAP
    ja .big
    mov [tls_hs_len], eax               ; (before rep movsb counts ECX down)
    add edi, TLS_HS
    mov esi, TLS_REC
    rep movsb
    jmp .l
.alert:
    mov dword [tls_err], te_alert
    jmp .fail
.big:
    mov dword [tls_err], te_bigmsg
    jmp .fail
.unexp:
    mov dword [tls_err], te_unexp
.fail:
    xor eax, eax
    CLEAVE

; --------------------------------------------------------- ClientHello
; tls_build_ch -> EAX = length of the ClientHello built at TLS_CH
tls_build_ch:
    CENTER
    mov edi, TLS_CH
    mov byte [edi], 1                   ; client_hello
    add edi, 4                          ; (length filled in below)
    mov word [edi], 0x0303
    add edi, 2
    mov esi, tls_crandom
    mov ecx, 32
    rep movsb
    mov byte [edi], 32                  ; legacy session id
    inc edi
    mov esi, tls_sid
    mov ecx, 32
    rep movsb
    mov dword [edi], 0x01130200         ; cipher suites: 00 02 13 01
    add edi, 4
    mov word [edi], 0x0001              ; compression: 01 00
    add edi, 2
    mov ebx, edi                        ; extensions length goes here
    add edi, 2
    cmp byte [tls_sni], 0               ; server_name (not for IP addresses)
    je .no_sni
    mov ecx, [tls_hostlen]
    mov word [edi], 0x0000
    lea eax, [ecx + 5]
    mov [edi + 2], ah
    mov [edi + 3], al
    lea eax, [ecx + 3]
    mov [edi + 4], ah
    mov [edi + 5], al
    mov byte [edi + 6], 0               ; host_name
    mov [edi + 7], ch
    mov [edi + 8], cl
    add edi, 9
    mov esi, [tls_host]
    rep movsb
.no_sni:
    mov esi, ch_ext_fixed
    mov ecx, ch_ext_fixed_len
    rep movsb
    mov esi, tls_pub                    ; our X25519 public key
    mov ecx, 32
    rep movsb
    mov eax, edi                        ; extensions length
    sub eax, ebx
    sub eax, 2
    mov [ebx], ah
    mov [ebx + 1], al
    mov eax, edi                        ; handshake body length (24-bit)
    sub eax, TLS_CH + 4
    mov [TLS_CH + 3], al
    mov [TLS_CH + 2], ah
    shr eax, 16
    mov [TLS_CH + 1], al
    mov eax, edi
    sub eax, TLS_CH
    CLEAVE

; tls_parse_sh(msg, len) -> EAX = 1 if a usable ServerHello (sets tls_spub)
tls_parse_sh:
    CENTER
    mov esi, ARG(0)
    mov edx, esi
    add edx, ARG(1)                     ; end
    mov dword [tls_err], te_hello
    cmp byte [esi], 2
    jne .bad
    add esi, 4
    cmp word [esi], 0x0303
    jne .bad
    add esi, 2
    push edx
    CCALL c_memeq, esi, hrr_random, 32
    pop edx
    test eax, eax
    jz .not_hrr
    mov dword [tls_err], te_hrr
    jmp .bad
.not_hrr:
    add esi, 32
    movzx eax, byte [esi]               ; session id echo
    lea esi, [esi + eax + 1]
    cmp word [esi], 0x0113              ; TLS_AES_128_GCM_SHA256 (13 01)
    je .cs_ok
    mov dword [tls_err], te_cipher
    jmp .bad
.cs_ok:
    add esi, 3                          ; cipher + compression
    movzx eax, word [esi]
    xchg al, ah
    add esi, 2
    lea edi, [esi + eax]
    cmp edi, edx
    ja .bad
    mov byte [tls_got_ver], 0
    mov byte [tls_got_ks], 0
.ext:
    lea eax, [esi + 4]
    cmp eax, edi
    ja .ext_done
    movzx eax, word [esi]               ; type
    xchg al, ah
    movzx ecx, word [esi + 2]           ; length
    xchg cl, ch
    add esi, 4
    cmp eax, 0x2B                       ; supported_versions
    jne .not_ver
    cmp word [esi], 0x0403              ; 03 04
    jne .not_ver
    mov byte [tls_got_ver], 1
.not_ver:
    cmp eax, 0x33                       ; key_share
    jne .next
    cmp word [esi], 0x1D00              ; x25519
    jne .next
    cmp word [esi + 2], 0x2000          ; 32 bytes
    jne .next
    push ecx
    lea eax, [esi + 4]
    CCALL c_memcpy, tls_spub, eax, 32
    pop ecx
    mov byte [tls_got_ks], 1
.next:
    add esi, ecx
    jmp .ext
.ext_done:
    cmp byte [tls_got_ver], 0
    jne .v_ok
    mov dword [tls_err], te_version
    jmp .bad
.v_ok:
    cmp byte [tls_got_ks], 0
    je .bad
    mov eax, 1
    CLEAVE
.bad:
    xor eax, eax
    CLEAVE

; ----------------------------------------------------------- handshake
; tls_connect(host, ip, port) -> EAX = 1 when the secure channel is up,
; 0 on failure (tls_err says why). host is the name to check the certificate
; against (and to send as SNI).
tls_connect:
    CENTER
    mov byte [tls_rkey_on], 0
    mov byte [tls_wkey_on], 0
    mov byte [tls_eof], 0
    mov dword [tls_hs_len], 0
    mov dword [tls_hs_pos], 0
    mov dword [tls_alert], -1
    mov dword [tls_err], 0
    mov dword [tls_cert_msg], 0
    mov dword [tls_cv_msg], 0
    mov esi, ARG(0)
    mov [tls_host], esi
    call str_len
    mov [tls_hostlen], ecx
    mov byte [tls_sni], 1               ; no SNI for a numeric address
    call parse_ipv4
    jc .named
    mov byte [tls_sni], 0
.named:
    mov eax, ARG(1)                     ; TCP connection
    mov ebx, ARG(2)
    call tcp_connect
    jnc .tcp_ok
    mov dword [tls_err], te_connect
    jmp .fail
.tcp_ok:
    mov edi, TLS_RX
    mov ecx, TLS_RX_CAP
    call tcp_set_dst
    CCALL rand_bytes, tls_crandom, 32   ; fresh randomness and key pair
    CCALL rand_bytes, tls_sid, 32
    CCALL rand_bytes, tls_priv, 32
    CCALL x25519_public, tls_pub, tls_priv
    call tls_build_ch
    mov ebx, eax
    CCALL sha256_init, tls_thash
    CCALL sha256_update, tls_thash, TLS_CH, ebx
    CCALL tls_send_record, 22, TLS_CH, ebx
    ; --- ServerHello
    call tls_next_hs
    test eax, eax
    jz .fail
    CCALL tls_parse_sh, dword [tls_msg], dword [tls_msglen]
    test eax, eax
    jz .fail
    CCALL sha256_update, tls_thash, dword [tls_msg], dword [tls_msglen]
    ; --- shared secret and handshake keys
    CCALL x25519, tls_shared, tls_priv, tls_spub
    CCALL c_memeq, tls_shared, tls_zero, 32
    test eax, eax
    jz .ecdh_ok
    mov dword [tls_err], te_ecdh
    jmp .fail
.ecdh_ok:
    CCALL sha256, tls_zero, 0, tls_ehash
    CCALL hkdf_extract, tls_zero, 32, tls_zero, 32, tls_secret      ; early
    CCALL derive_secret, tls_secret, lbl_derived, tls_ehash, tls_tmp
    CCALL hkdf_extract, tls_tmp, 32, tls_shared, 32, tls_hs_secret  ; handshake
    CCALL tls_transcript, tls_hash
    CCALL derive_secret, tls_hs_secret, lbl_c_hs, tls_hash, tls_c_hs
    CCALL derive_secret, tls_hs_secret, lbl_s_hs, tls_hash, tls_s_hs
    CCALL tls_key_install, tls_rkey, tls_s_hs
    CCALL tls_key_install, tls_wkey, tls_c_hs
    mov byte [tls_rkey_on], 1
    cmp byte [tls_debug], 0
    je .sec_nodbg
    PRINTF `  client random `
    CCALL st_hex, tls_crandom, 32
    PRINTF `\n  server hs secret `
    CCALL st_hex, tls_s_hs, 32
    PRINTF `\n`
.sec_nodbg:
    ; --- the server's encrypted flight
.flight:
    call tls_next_hs
    test eax, eax
    jz .fail
    mov esi, [tls_msg]
    cmp byte [tls_debug], 0
    je .fl_nodbg
    movzx eax, byte [esi]
    PRINTF `  [handshake message %d, %d bytes]\n`, eax, dword [tls_msglen]
.fl_nodbg:
    mov al, [esi]
    cmp al, 8                           ; EncryptedExtensions
    je .add
    cmp al, 11                          ; Certificate
    je .cert
    cmp al, 15                          ; CertificateVerify
    je .cv
    cmp al, 20                          ; Finished
    je .fin
    cmp al, 13                          ; CertificateRequest
    jne .unexp
    mov dword [tls_err], te_clientcert
    jmp .fail
.unexp:
    mov dword [tls_err], te_unexp
    jmp .fail
.cert:
    mov [tls_cert_msg], esi
    mov eax, [tls_msglen]
    mov [tls_cert_len], eax
    jmp .add
.cv:
    mov [tls_cv_msg], esi
    mov eax, [tls_msglen]
    mov [tls_cv_len], eax
    CCALL tls_transcript, tls_cv_hash   ; it signs everything before it
.add:
    CCALL sha256_update, tls_thash, dword [tls_msg], dword [tls_msglen]
    jmp .flight
.fin:
    cmp dword [tls_msglen], 4 + 32
    jne .badfin
    CCALL tls_transcript, tls_hash
    CCALL hkdf_expand_label, tls_s_hs, lbl_finished, tls_zero, 0, tls_fkey, 32
    CCALL hmac_sha256, tls_fkey, 32, tls_hash, 32, tls_vdata
    mov eax, [tls_msg]
    add eax, 4
    CCALL c_memeq, tls_vdata, eax, 32
    test eax, eax
    jz .badfin
    CCALL sha256_update, tls_thash, dword [tls_msg], dword [tls_msglen]
    ; --- is it really the server we asked for?
    cmp dword [tls_cert_msg], 0
    jne .have_cert
    mov dword [tls_err], te_nocert
    jmp .fail
.have_cert:
    cmp byte [tls_verify], 0
    je .trusted
    call tls_check_server               ; x509.asm: chain, name, signature
    test eax, eax
    jz .fail
.trusted:
    ; --- application keys
    CCALL tls_transcript, tls_hash      ; ClientHello .. server Finished
    CCALL derive_secret, tls_hs_secret, lbl_derived, tls_ehash, tls_tmp
    CCALL hkdf_extract, tls_tmp, 32, tls_zero, 32, tls_secret       ; master
    CCALL derive_secret, tls_secret, lbl_c_ap, tls_hash, tls_c_ap
    CCALL derive_secret, tls_secret, lbl_s_ap, tls_hash, tls_s_ap
    ; --- our Finished
    mov esi, ccs_record
    mov ecx, 6
    call tcp_send_all
    CCALL hkdf_expand_label, tls_c_hs, lbl_finished, tls_zero, 0, tls_fkey, 32
    CCALL hmac_sha256, tls_fkey, 32, tls_hash, 32, tls_finmsg + 4
    mov dword [tls_finmsg], 0x20000014  ; finished, length 32
    mov byte [tls_wkey_on], 1
    CCALL tls_send_record, 22, tls_finmsg, 36
    CCALL tls_key_install, tls_wkey, tls_c_ap
    CCALL tls_key_install, tls_rkey, tls_s_ap
    mov eax, 1
    CLEAVE
.badfin:
    mov dword [tls_err], te_finished
.fail:
    call tcp_close
    xor eax, eax
    CLEAVE

; tls_write(data, len): send application data
tls_write:
    CENTER
    mov esi, ARG(0)
    mov ebx, ARG(1)
.l: test ebx, ebx
    jz .done
    mov ecx, ebx
    cmp ecx, 16000
    jbe .n
    mov ecx, 16000
.n: sub ebx, ecx
    push ecx
    CCALL tls_send_record, 23, esi, ecx
    pop ecx
    add esi, ecx
    jmp .l
.done:
    CLEAVE

; ---------------------------------------------------------------- HTTPS
; https_get(host, ip, port, path) -> EAX = 1 with the response body in
; PKG_BUF (pkg_len, http_status, http_date like http_get), 0 on failure
https_get:
    CENTER
    CCALL tls_connect, dword ARG(0), dword ARG(1), dword ARG(2)
    test eax, eax
    jz .fail
    mov edi, SCRATCH                    ; the request
    mov esi, http_get_str
    call str_copy_noterm
    mov esi, ARG(3)
    call str_copy_noterm
    mov esi, http_ver_str
    call str_copy_noterm
    mov esi, ARG(0)
    call str_copy_noterm
    mov esi, http_tail_str
    call str_copy_noterm
    mov ecx, edi
    sub ecx, SCRATCH
    CCALL tls_write, SCRATCH, ecx
    mov dword [pkg_len], 0
    call http_complete_reset
.read:
    call tls_read_record
    test eax, eax
    jz .end                             ; closed (or error: judged below)
    mov al, [tls_rtype]
    cmp al, 21
    je .alert
    cmp al, 23
    jne .read                           ; tickets etc.: ignore
    mov ecx, [tls_rlen]
    mov edi, [pkg_len]
    mov eax, PKG_BUF_SIZE - 1
    sub eax, edi
    cmp ecx, eax
    jbe .fits
    mov ecx, eax
.fits:
    add [pkg_len], ecx
    add edi, PKG_BUF
    mov esi, TLS_REC
    rep movsb
    mov esi, PKG_BUF
    mov ecx, [pkg_len]
    call http_is_complete
    jc .read
    jmp .done
.alert:
    cmp dword [tls_alert], 0            ; close_notify = normal end
    je .done
    mov dword [tls_err], te_alert
    jmp .fail
.end:
    cmp byte [tls_eof], 0               ; a clean close is fine
    jne .done
    cmp dword [pkg_len], 0              ; got something before it broke?
    je .fail
.done:
    call tcp_close
    mov edi, [pkg_len]
    mov byte [PKG_BUF + edi], 0
    call http_parse
    mov eax, 1
    CLEAVE
.fail:
    call tcp_close
    xor eax, eax
    CLEAVE

