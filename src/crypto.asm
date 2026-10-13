; =============================================================================
;  crypto.asm - SHA-256, HMAC-SHA256, HKDF (TLS 1.3 labels), random numbers
;
;  Calling convention: C style (see CCALL / CENTER / CLEAVE in macros.inc).
;  Arguments are pointers and lengths; results are written to buffers.
;  Constant tables come from crypto_tables.inc (generated + self-checked by
;  tools/gen_tables.py).
; =============================================================================
%include "src/crypto_tables.inc"

; SHA-256 context
SHA_H       equ 0                   ; 8 dwords
SHA_BUF     equ 32                  ; 64 bytes of pending input
SHA_BLEN    equ 96                  ; bytes in SHA_BUF
SHA_TOT     equ 100                 ; total bytes hashed
SHA_CTX     equ 104

; HMAC context = inner SHA-256 context + the outer key pad
HMAC_INNER  equ 0
HMAC_OKEY   equ SHA_CTX             ; 64 bytes
HMAC_CTX    equ SHA_CTX + 64

section .bss
alignb 4
sha_w       resd 64                 ; message schedule
sha_v       resd 8                  ; working variables a..h
sha_lenlo   resd 1
sha_lenhi   resd 1
sha_tmp     resb SHA_CTX            ; for the one-shot sha256()
hmac_tmp    resb HMAC_CTX           ; for the one-shot hmac_sha256()
hmac_octx   resb SHA_CTX
hmac_kbuf   resb 64
hmac_ihash  resb 32
hk_hctx     resb HMAC_CTX
hk_info     resb 2 + 1 + 255 + 1 + 255
hk_out      resb 32
rng_pool    resb 32
rng_ctr     resd 1
rng_inbuf   resb 96
rng_block   resb 32
rng_ready   resb 1
rng_hw      resb 1                  ; 1 if the CPU has RDRAND

section .data
hk_prefix   db "tls13 "
; TLS 1.3 key-schedule labels (RFC 8446 section 7.1)
lbl_derived  db "derived", 0
lbl_c_hs     db "c hs traffic", 0
lbl_s_hs     db "s hs traffic", 0
lbl_c_ap     db "c ap traffic", 0
lbl_s_ap     db "s ap traffic", 0
lbl_key      db "key", 0
lbl_iv       db "iv", 0
lbl_finished db "finished", 0
hk_one      db 1
rng_outtag  db "out!"

section .text

%define V_A [sha_v + 0]
%define V_B [sha_v + 4]
%define V_C [sha_v + 8]
%define V_D [sha_v + 12]
%define V_E [sha_v + 16]
%define V_F [sha_v + 20]
%define V_G [sha_v + 24]
%define V_H [sha_v + 28]

; --------------------------------------------------------------- SHA-256
; sha256_compress(ctx, block64): process one 64-byte block
sha256_compress:
    CENTER
    mov esi, ARG(1)
    xor ecx, ecx
.w16:                               ; W[0..15] = big-endian words
    mov eax, [esi + ecx * 4]
    bswap eax
    mov [sha_w + ecx * 4], eax
    inc ecx
    cmp ecx, 16
    jb .w16
.w64:                               ; W[16..63]
    mov eax, [sha_w + ecx * 4 - 8]  ; s1(W[t-2])
    mov edx, eax
    ror eax, 17
    mov ebx, edx
    ror ebx, 19
    xor eax, ebx
    shr edx, 10
    xor eax, edx
    add eax, [sha_w + ecx * 4 - 28] ; + W[t-7]
    mov edx, [sha_w + ecx * 4 - 60] ; s0(W[t-15])
    mov ebx, edx
    ror ebx, 7
    mov edi, edx
    ror edi, 18
    xor ebx, edi
    shr edx, 3
    xor ebx, edx
    add eax, ebx
    add eax, [sha_w + ecx * 4 - 64] ; + W[t-16]
    mov [sha_w + ecx * 4], eax
    inc ecx
    cmp ecx, 64
    jb .w64
    mov esi, ARG(0)                 ; a..h = H
    mov edi, sha_v
    mov ecx, 8
    rep movsd
    xor ecx, ecx
.round:
    mov eax, V_E                    ; S1(e)
    mov ebx, eax
    ror ebx, 6
    mov edx, eax
    ror edx, 11
    xor ebx, edx
    mov edx, eax
    ror edx, 25
    xor ebx, edx
    mov edx, eax                    ; ch(e,f,g)
    and edx, V_F
    not eax
    and eax, V_G
    xor eax, edx
    add eax, ebx
    add eax, V_H
    add eax, [sha256_k + ecx * 4]
    add eax, [sha_w + ecx * 4]
    mov edi, eax                    ; EDI = T1
    mov eax, V_A                    ; S0(a)
    mov ebx, eax
    ror ebx, 2
    mov edx, eax
    ror edx, 13
    xor ebx, edx
    mov edx, eax
    ror edx, 22
    xor ebx, edx
    mov edx, V_B                    ; maj(a,b,c) = (a&b) | (c&(a|b))
    mov esi, eax
    or esi, edx
    and esi, V_C
    and eax, edx
    or eax, esi
    add ebx, eax                    ; EBX = T2
    mov eax, V_G
    mov V_H, eax
    mov eax, V_F
    mov V_G, eax
    mov eax, V_E
    mov V_F, eax
    mov eax, V_D
    add eax, edi
    mov V_E, eax
    mov eax, V_C
    mov V_D, eax
    mov eax, V_B
    mov V_C, eax
    mov eax, V_A
    mov V_B, eax
    lea eax, [edi + ebx]
    mov V_A, eax
    inc ecx
    cmp ecx, 64
    jb .round
    mov esi, ARG(0)                 ; H += a..h
    xor ecx, ecx
.add:
    mov eax, [sha_v + ecx * 4]
    add [esi + ecx * 4], eax
    inc ecx
    cmp ecx, 8
    jb .add
    CLEAVE

; sha256_init(ctx)
sha256_init:
    CENTER
    mov edi, ARG(0)
    mov esi, sha256_iv
    mov ecx, 8
    rep movsd
    mov edi, ARG(0)
    mov dword [edi + SHA_BLEN], 0
    mov dword [edi + SHA_TOT], 0
    CLEAVE

; sha256_update(ctx, data, len)
sha256_update:
    CENTER
    mov ebx, ARG(0)
    mov esi, ARG(1)
    mov edx, ARG(2)
    add [ebx + SHA_TOT], edx
.loop:
    test edx, edx
    jz .done
    mov ecx, 64                     ; copy as much as fits in the buffer
    sub ecx, [ebx + SHA_BLEN]
    cmp ecx, edx
    jbe .n_ok
    mov ecx, edx
.n_ok:
    lea edi, [ebx + SHA_BUF]
    add edi, [ebx + SHA_BLEN]
    sub edx, ecx
    add [ebx + SHA_BLEN], ecx
    rep movsb
    cmp dword [ebx + SHA_BLEN], 64
    jne .loop
    push edx
    lea eax, [ebx + SHA_BUF]
    CCALL sha256_compress, ebx, eax
    pop edx
    mov dword [ebx + SHA_BLEN], 0
    jmp .loop
.done:
    CLEAVE

; sha256_final(ctx, out32)
sha256_final:
    CENTER
    mov ebx, ARG(0)
    mov eax, [ebx + SHA_TOT]        ; length in bits (64-bit)
    mov edx, eax
    shr edx, 29
    mov [sha_lenhi], edx
    shl eax, 3
    mov [sha_lenlo], eax
    mov ecx, [ebx + SHA_BLEN]
    mov byte [ebx + SHA_BUF + ecx], 0x80
    inc ecx
    cmp ecx, 56
    jbe .pad
.fill:                              ; no room for the length: finish block
    cmp ecx, 64
    jae .full
    mov byte [ebx + SHA_BUF + ecx], 0
    inc ecx
    jmp .fill
.full:
    lea eax, [ebx + SHA_BUF]
    CCALL sha256_compress, ebx, eax
    xor ecx, ecx
.pad:
    cmp ecx, 56
    jae .len
    mov byte [ebx + SHA_BUF + ecx], 0
    inc ecx
    jmp .pad
.len:
    mov eax, [sha_lenhi]
    bswap eax
    mov [ebx + SHA_BUF + 56], eax
    mov eax, [sha_lenlo]
    bswap eax
    mov [ebx + SHA_BUF + 60], eax
    lea eax, [ebx + SHA_BUF]
    CCALL sha256_compress, ebx, eax
    mov edi, ARG(1)
    xor ecx, ecx
.out:
    mov eax, [ebx + ecx * 4]
    bswap eax
    mov [edi + ecx * 4], eax
    inc ecx
    cmp ecx, 8
    jb .out
    CLEAVE

; sha256(data, len, out32): one-shot
sha256:
    CENTER
    CCALL sha256_init, sha_tmp
    CCALL sha256_update, sha_tmp, dword ARG(0), dword ARG(1)
    CCALL sha256_final, sha_tmp, dword ARG(2)
    CLEAVE

; ------------------------------------------------------------------ HMAC
; hmac_init(hctx, key, keylen)
hmac_init:
    CENTER
    mov edi, hmac_kbuf              ; key block = key (or its hash), zero padded
    xor eax, eax
    mov ecx, 16
    rep stosd
    mov ecx, ARG(2)
    cmp ecx, 64
    jbe .short
    CCALL sha256, dword ARG(1), dword ARG(2), hmac_kbuf
    jmp .pads
.short:
    mov esi, ARG(1)
    mov edi, hmac_kbuf
    rep movsb
.pads:
    mov ebx, ARG(0)
    xor ecx, ecx
.mk:                                ; outer pad stored, inner pad in place
    mov al, [hmac_kbuf + ecx]
    mov dl, al
    xor dl, 0x5C
    mov [ebx + HMAC_OKEY + ecx], dl
    xor al, 0x36
    mov [hmac_kbuf + ecx], al
    inc ecx
    cmp ecx, 64
    jb .mk
    CCALL sha256_init, ebx
    CCALL sha256_update, ebx, hmac_kbuf, 64
    CLEAVE

; hmac_update(hctx, data, len)
hmac_update:
    CENTER
    CCALL sha256_update, dword ARG(0), dword ARG(1), dword ARG(2)
    CLEAVE

; hmac_final(hctx, out32)
hmac_final:
    CENTER
    mov ebx, ARG(0)
    CCALL sha256_final, ebx, hmac_ihash
    CCALL sha256_init, hmac_octx
    lea eax, [ebx + HMAC_OKEY]
    CCALL sha256_update, hmac_octx, eax, 64
    CCALL sha256_update, hmac_octx, hmac_ihash, 32
    CCALL sha256_final, hmac_octx, dword ARG(1)
    CLEAVE

; hmac_sha256(key, keylen, data, len, out32)
hmac_sha256:
    CENTER
    CCALL hmac_init, hmac_tmp, dword ARG(0), dword ARG(1)
    CCALL hmac_update, hmac_tmp, dword ARG(2), dword ARG(3)
    CCALL hmac_final, hmac_tmp, dword ARG(4)
    CLEAVE

; ------------------------------------------------------------------ HKDF
; hkdf_extract(salt, saltlen, ikm, ikmlen, out32) = HMAC(salt, ikm)
hkdf_extract:
    CENTER
    CCALL hmac_sha256, dword ARG(0), dword ARG(1), dword ARG(2), dword ARG(3), dword ARG(4)
    CLEAVE

; hkdf_expand_label(secret32, label, context, ctxlen, out, outlen<=32)
; TLS 1.3: HKDF-Expand(secret, HkdfLabel, outlen) where HkdfLabel =
; uint16 outlen | uint8 len | "tls13 " label | uint8 ctxlen | context.
hkdf_expand_label:
    CENTER
    mov edi, hk_info
    mov eax, ARG(5)                 ; length, big-endian
    mov [edi], ah
    mov [edi + 1], al
    mov esi, ARG(1)                 ; label length
    xor ecx, ecx
.ll: cmp byte [esi + ecx], 0
    je .lgot
    inc ecx
    jmp .ll
.lgot:
    lea eax, [ecx + 6]
    mov [edi + 2], al
    add edi, 3
    push ecx
    mov esi, hk_prefix
    mov ecx, 6
    rep movsb
    pop ecx
    mov esi, ARG(1)
    rep movsb
    mov ecx, ARG(3)                 ; context
    mov [edi], cl
    inc edi
    mov esi, ARG(2)
    rep movsb
    sub edi, hk_info                ; info length
    mov ebx, edi
    CCALL hmac_init, hk_hctx, dword ARG(0), 32
    CCALL hmac_update, hk_hctx, hk_info, ebx
    CCALL hmac_update, hk_hctx, hk_one, 1
    CCALL hmac_final, hk_hctx, hk_out
    mov esi, hk_out
    mov edi, ARG(4)
    mov ecx, ARG(5)
    rep movsb
    CLEAVE

; derive_secret(secret32, label, hash32, out32)
derive_secret:
    CENTER
    CCALL hkdf_expand_label, dword ARG(0), dword ARG(1), dword ARG(2), 32, dword ARG(3), 32
    CLEAVE

; ---------------------------------------------------------- byte helpers
; c_memcpy(dst, src, n)
c_memcpy:
    CENTER
    mov edi, ARG(0)
    mov esi, ARG(1)
    mov ecx, ARG(2)
    rep movsb
    CLEAVE

; c_memzero(dst, n)
c_memzero:
    CENTER
    mov edi, ARG(0)
    mov ecx, ARG(1)
    xor eax, eax
    rep stosb
    CLEAVE

; c_memeq(a, b, n) -> EAX = 1 if equal (time does not depend on the data)
c_memeq:
    CENTER
    mov esi, ARG(0)
    mov edi, ARG(1)
    mov ecx, ARG(2)
    xor edx, edx
.l: jecxz .done
    mov al, [esi]
    xor al, [edi]
    or dl, al
    inc esi
    inc edi
    dec ecx
    jmp .l
.done:
    xor eax, eax
    test dl, dl
    setz al
    CLEAVE

; ------------------------------------------------------- random numbers
; The generator keeps a 32-byte pool. Each refill hashes the pool together
; with fresh timer readings (and RDRAND output when the CPU has it). Output
; blocks are a separate hash of the pool, so they never reveal it.

; rng_stir: pool = SHA256(pool | counter | TSC | ticks | RDRAND words)
rng_stir:
    CENTER
    mov edi, rng_inbuf
    mov esi, rng_pool
    mov ecx, 32
    rep movsb
    mov eax, [rng_ctr]
    stosd
    rdtsc
    stosd
    mov eax, edx
    stosd
    mov eax, [ticks]
    stosd
    mov ebx, 4                      ; four hardware words, if available
.hw:
    xor eax, eax
    cmp byte [rng_hw], 0
    je .store
    mov ecx, 16
.try:
    rdrand eax
    jc .store
    dec ecx
    jnz .try
.store:
    stosd
    in al, 0x40                     ; timer read: adds a little jitter
    rdtsc
    xor [edi - 4], eax
    dec ebx
    jnz .hw
    inc dword [rng_ctr]
    CCALL sha256, rng_inbuf, 64, rng_pool
    CLEAVE

; rng_seed: detect RDRAND and stir in the MAC address, the time and jitter
rng_seed:
    CENTER
    mov eax, 1
    cpuid
    bt ecx, 30
    setc byte [rng_hw]
    mov esi, nic_mac
    mov edi, rng_pool
    mov ecx, 6
    rep movsb
    call rtc_read
    mov al, [rtc_sec]
    xor [rng_pool + 8], al
    mov al, [rtc_min]
    xor [rng_pool + 9], al
    mov al, [rtc_hour]
    xor [rng_pool + 10], al
    mov ebx, 64
.mix:
    call rng_stir
    dec ebx
    jnz .mix
    mov byte [rng_ready], 1
    CLEAVE

; rand_bytes(buf, n)
rand_bytes:
    CENTER
    cmp byte [rng_ready], 0
    jne .go
    call rng_seed
.go:
    mov edi, ARG(0)
    mov ebx, ARG(1)
.block:
    test ebx, ebx
    jz .done
    call rng_stir
    mov esi, rng_inbuf              ; out = SHA256(pool | "out!")
    push edi
    mov edi, rng_inbuf
    mov esi, rng_pool
    mov ecx, 32
    rep movsb
    mov eax, [rng_outtag]
    stosd
    pop edi
    CCALL sha256, rng_inbuf, 36, rng_block
    mov ecx, 32
    cmp ebx, ecx
    jae .n
    mov ecx, ebx
.n: sub ebx, ecx
    mov esi, rng_block
    rep movsb
    jmp .block
.done:
    CLEAVE
