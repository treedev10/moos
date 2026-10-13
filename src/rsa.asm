; =============================================================================
;  rsa.asm - RSA signature verification (for HTTPS certificates)
;
;  Big numbers are arrays of little-endian dwords, up to 4096 bits. Modular
;  exponentiation uses Montgomery multiplication (CIOS). Only the public-key
;  operation is needed: s^e mod n, with a small exponent (usually 65537).
;
;    rsa_pkcs1_verify  - PKCS#1 v1.5 with SHA-256 (certificate signatures)
;    rsa_pss_verify    - RSA-PSS, SHA-256, MGF1-SHA-256, 32-byte salt
;                        (the TLS 1.3 CertificateVerify signature)
;  C-style calls (CCALL).
; =============================================================================
BN_MAX      equ 130                 ; dwords (4096 bits + room)

section .bss
alignb 4
mm_k        resd 1                  ; length in dwords
mm_n0inv    resd 1                  ; -n^-1 mod 2^32
mm_np       resd 1                  ; pointer to n
mm_bi       resd 1
mm_m        resd 1
mm_i        resd 1
mm_t        resd BN_MAX + 2
bn_n        resd BN_MAX
bn_s        resd BN_MAX
bn_r2       resd BN_MAX
bn_x        resd BN_MAX
bn_acc      resd BN_MAX
bn_one      resd BN_MAX
bn_tmp      resd BN_MAX
rsa_em      resb 4 * BN_MAX
rsa_mask    resb 4 * BN_MAX
rsa_nlen    resd 1
rsa_mgfin   resb 36
rsa_mprime  resb 72
rsa_hash    resb 32

section .data
; DER DigestInfo prefix for SHA-256 (PKCS#1 v1.5)
pkcs1_sha256 db 0x30, 0x31, 0x30, 0x0D, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01
             db 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20

section .text

; bn_from_bytes(dst, be_bytes, nbytes, k): big-endian bytes -> k dwords
bn_from_bytes:
    CENTER
    mov edi, ARG(0)
    mov ecx, ARG(3)
    xor eax, eax
    rep stosd
    mov edi, ARG(0)
    mov esi, ARG(1)
    mov ecx, ARG(2)
    xor ebx, ebx                    ; byte position from the low end
.l: jecxz .done
    dec ecx
    mov al, [esi + ecx]             ; last byte is least significant
    mov [edi + ebx], al
    inc ebx
    jmp .l
.done:
    CLEAVE

; bn_to_bytes(dst_be, src, k): k dwords -> 4k big-endian bytes
bn_to_bytes:
    CENTER
    mov edi, ARG(0)
    mov esi, ARG(1)
    mov ecx, ARG(2)
    shl ecx, 2
    xor ebx, ebx
.l: jecxz .done
    dec ecx
    mov al, [esi + ecx]
    mov [edi + ebx], al
    inc ebx
    jmp .l
.done:
    CLEAVE

; bn_cmp(a, b, k) -> EAX = 1 if a >= b, else 0
bn_cmp:
    CENTER
    mov esi, ARG(0)
    mov edi, ARG(1)
    mov ecx, ARG(2)
.l: dec ecx
    js .equal
    mov eax, [esi + ecx * 4]
    cmp eax, [edi + ecx * 4]
    ja .ge
    jb .lt
    jmp .l
.equal:
.ge:
    mov eax, 1
    CLEAVE
.lt:
    xor eax, eax
    CLEAVE

; bn_sub(a, b, k): a -= b (assumes a >= b)
bn_sub:
    CENTER
    mov esi, ARG(0)
    mov edi, ARG(1)
    mov ecx, ARG(2)
    xor ebx, ebx
    clc
.l: mov eax, [edi + ebx * 4]
    sbb [esi + ebx * 4], eax
    inc ebx                         ; inc/dec keep the carry flag
    dec ecx
    jnz .l
    CLEAVE

; mont_setup(n, k): remember n, compute n0inv and R^2 mod n (into bn_r2)
mont_setup:
    CENTER
    mov esi, ARG(0)
    mov [mm_np], esi
    mov eax, ARG(1)
    mov [mm_k], eax
    mov ebx, [esi]                  ; n0inv by Newton: x = x * (2 - n0 x)
    mov ecx, ebx
    mov edi, 5
.newton:
    mov eax, ebx
    imul eax, ecx                   ; n0 * x
    neg eax
    add eax, 2                      ; 2 - n0 x
    imul ecx, eax
    dec edi
    jnz .newton
    neg ecx
    mov [mm_n0inv], ecx
    ; R^2 mod n: start at 1 and double 64k times, reducing each time
    CCALL c_memzero, bn_r2, 4 * BN_MAX
    mov dword [bn_r2], 1
    mov ebx, [mm_k]
    shl ebx, 6
.dbl:
    mov ecx, [mm_k]                 ; shift left one bit
    xor edx, edx                    ; index
    clc
.shl:
    rcl dword [bn_r2 + edx * 4], 1
    inc edx
    dec ecx
    jnz .shl
    jc .reduce                      ; overflowed past the top: certainly >= n
    CCALL bn_cmp, bn_r2, dword [mm_np], dword [mm_k]
    test eax, eax
    jz .next
.reduce:
    CCALL bn_sub, bn_r2, dword [mm_np], dword [mm_k]
.next:
    dec ebx
    jnz .dbl
    CLEAVE

; mont_mul(out, a, b): out = a * b / R mod n
mont_mul:
    CENTER
    mov ecx, [mm_k]
    add ecx, 2
    mov edi, mm_t
    xor eax, eax
    rep stosd
    mov dword [mm_i], 0
.outer:
    mov eax, ARG(2)                 ; b[i]
    mov edx, [mm_i]
    mov eax, [eax + edx * 4]
    mov [mm_bi], eax
    mov esi, ARG(1)                 ; t += a * b[i]
    xor ecx, ecx
    xor ebx, ebx
.l1:
    mov eax, [esi + ebx * 4]
    mul dword [mm_bi]
    add eax, [mm_t + ebx * 4]
    adc edx, 0
    add eax, ecx
    adc edx, 0
    mov [mm_t + ebx * 4], eax
    mov ecx, edx
    inc ebx
    cmp ebx, [mm_k]
    jb .l1
    mov eax, [mm_t + ebx * 4]       ; t[k] += carry, t[k+1] = carry out
    add eax, ecx
    mov [mm_t + ebx * 4], eax
    mov eax, 0
    adc eax, 0
    mov [mm_t + ebx * 4 + 4], eax
    mov eax, [mm_t]                 ; m = t[0] * n0inv
    mul dword [mm_n0inv]
    mov [mm_m], eax
    mov edi, [mm_np]                ; t = (t + m*n) / 2^32
    mov eax, [edi]
    mul dword [mm_m]
    add eax, [mm_t]
    adc edx, 0
    mov ecx, edx
    mov ebx, 1
.l2:
    cmp ebx, [mm_k]
    jae .l2done
    mov eax, [edi + ebx * 4]
    mul dword [mm_m]
    add eax, [mm_t + ebx * 4]
    adc edx, 0
    add eax, ecx
    adc edx, 0
    mov [mm_t + ebx * 4 - 4], eax
    mov ecx, edx
    inc ebx
    jmp .l2
.l2done:
    mov eax, [mm_t + ebx * 4]
    add eax, ecx
    mov [mm_t + ebx * 4 - 4], eax
    mov eax, [mm_t + ebx * 4 + 4]
    adc eax, 0
    mov [mm_t + ebx * 4], eax
    mov dword [mm_t + ebx * 4 + 4], 0
    inc dword [mm_i]
    mov eax, [mm_i]
    cmp eax, [mm_k]
    jb .outer
    ; t < 2n: subtract n once if needed
    mov ebx, [mm_k]
    cmp dword [mm_t + ebx * 4], 0
    jne .sub
    CCALL bn_cmp, mm_t, dword [mm_np], dword [mm_k]
    test eax, eax
    jz .copy
.sub:
    CCALL bn_sub, mm_t, dword [mm_np], dword [mm_k]
.copy:
    mov ecx, [mm_k]
    mov esi, mm_t
    mov edi, ARG(0)
    rep movsd
    CLEAVE

; rsa_public(out_be, sig, siglen, n_be, nlen, e) -> EAX = 1 on success.
; out_be receives nlen bytes (nlen = modulus length with leading zero bytes
; removed; also stored in rsa_nlen). Fails if sig >= n or sizes are wrong.
rsa_public:
    CENTER
    mov esi, ARG(3)
    mov ecx, ARG(4)
.strip:
    test ecx, ecx
    jz .bad
    cmp byte [esi], 0
    jne .stripped
    inc esi
    dec ecx
    jmp .strip
.stripped:
    mov [rsa_nlen], ecx
    mov ARG(3), esi
    mov ARG(4), ecx
    cmp ecx, 4 * (BN_MAX - 2)
    ja .bad
    cmp ecx, 64                     ; refuse toy keys under 512 bits
    jb .bad
    mov eax, ARG(2)                 ; signature may carry leading zeros too
    cmp eax, ecx
    jb .bad
    sub eax, ecx
    mov edi, ARG(1)
.sigz:
    test eax, eax
    jz .sigok
    cmp byte [edi], 0
    jne .bad
    inc edi
    dec eax
    jmp .sigz
.sigok:
    mov ARG(1), edi
    mov ebx, ecx                    ; k = ceil(nlen / 4)
    add ebx, 3
    shr ebx, 2
    CCALL bn_from_bytes, bn_n, dword ARG(3), dword ARG(4), ebx
    CCALL bn_from_bytes, bn_s, dword ARG(1), dword ARG(4), ebx
    CCALL bn_cmp, bn_s, bn_n, ebx
    test eax, eax
    jnz .bad                        ; signature must be below the modulus
    CCALL mont_setup, bn_n, ebx
    CCALL mont_mul, bn_x, bn_s, bn_r2       ; x = s * R mod n
    CCALL c_memcpy, bn_acc, bn_x, 4 * BN_MAX
    mov edi, ARG(5)                 ; square-and-multiply over e's bits
    bsr ecx, edi
    jz .bad
.exp:
    dec ecx
    js .expdone
    push ecx
    CCALL mont_mul, bn_acc, bn_acc, bn_acc
    pop ecx
    bt edi, ecx
    jnc .exp
    push ecx
    CCALL mont_mul, bn_acc, bn_acc, bn_x
    pop ecx
    jmp .exp
.expdone:
    CCALL c_memzero, bn_one, 4 * BN_MAX
    mov dword [bn_one], 1
    CCALL mont_mul, bn_acc, bn_acc, bn_one  ; leave Montgomery form
    CCALL bn_to_bytes, rsa_mask, bn_acc, ebx
    lea esi, [ebx * 4]              ; copy the low nlen bytes out
    sub esi, ARG(4)
    add esi, rsa_mask
    CCALL c_memcpy, dword ARG(0), esi, dword ARG(4)
    mov eax, 1
    CLEAVE
.bad:
    xor eax, eax
    CLEAVE

; rsa_pkcs1_verify(n, nlen, e, sig, siglen, hash32) -> EAX = 1 if valid
rsa_pkcs1_verify:
    CENTER
    CCALL rsa_public, rsa_em, dword ARG(3), dword ARG(4), dword ARG(0), dword ARG(1), dword ARG(2)
    test eax, eax
    jz .bad
    mov ecx, [rsa_nlen]
    cmp ecx, 3 + 8 + 19 + 32
    jb .bad
    cmp byte [rsa_em], 0
    jne .bad
    cmp byte [rsa_em + 1], 1
    jne .bad
    mov ebx, ecx                    ; padding runs from 2 to k-53
    sub ebx, 3 + 19 + 32
    mov esi, rsa_em + 2
.ff:
    cmp byte [esi], 0xFF
    jne .bad
    inc esi
    dec ebx
    jnz .ff
    cmp byte [esi], 0
    jne .bad
    inc esi
    push esi
    CCALL c_memeq, esi, pkcs1_sha256, 19
    pop esi
    test eax, eax
    jz .bad
    add esi, 19
    CCALL c_memeq, esi, dword ARG(5), 32
    CLEAVE
.bad:
    xor eax, eax
    CLEAVE

; mgf1(seed32, out, len): MGF1 with SHA-256
mgf1:
    CENTER
    CCALL c_memcpy, rsa_mgfin, dword ARG(0), 32
    mov edi, ARG(1)
    mov ebx, ARG(2)
    xor esi, esi                    ; counter
.l: test ebx, ebx
    jz .done
    mov eax, esi
    bswap eax
    mov [rsa_mgfin + 32], eax
    CCALL sha256, rsa_mgfin, 36, rsa_hash
    mov ecx, 32
    cmp ebx, ecx
    jae .n
    mov ecx, ebx
.n: sub ebx, ecx
    push esi
    mov esi, rsa_hash
    rep movsb
    pop esi
    inc esi
    jmp .l
.done:
    CLEAVE

; rsa_pss_verify(n, nlen, e, sig, siglen, mhash32) -> EAX = 1 if valid
; RSASSA-PSS with SHA-256, MGF1-SHA-256 and a 32-byte salt (as TLS 1.3 uses).
rsa_pss_verify:
    CENTER
    CCALL rsa_public, rsa_em, dword ARG(3), dword ARG(4), dword ARG(0), dword ARG(1), dword ARG(2)
    test eax, eax
    jz .bad
    ; modBits from the first non-zero modulus byte
    mov esi, ARG(0)
.nz:
    cmp byte [esi], 0
    jne .top
    inc esi
    jmp .nz
.top:
    movzx eax, byte [esi]
    bsr eax, eax                    ; top bit position 0..7
    mov ecx, [rsa_nlen]
    dec ecx
    shl ecx, 3
    add ecx, eax
    inc ecx                         ; ECX = modBits
    dec ecx                         ; emBits = modBits - 1
    mov [pss_embits], ecx
    add ecx, 7
    shr ecx, 3                      ; emLen
    mov [pss_emlen], ecx
    mov esi, rsa_em                 ; EM is the low emLen bytes of the result
    mov eax, [rsa_nlen]
    sub eax, ecx
    jz .em_ok
    cmp byte [esi], 0               ; (at most one extra leading zero byte)
    jne .bad
    inc esi
.em_ok:
    mov [pss_em], esi
    cmp ecx, 32 + 32 + 2
    jb .bad
    cmp byte [esi + ecx - 1], 0xBC
    jne .bad
    mov ebx, ecx                    ; dbLen = emLen - 33
    sub ebx, 33
    mov [pss_dblen], ebx
    mov eax, [pss_emlen]            ; unused top bits of EM must be zero
    shl eax, 3
    sub eax, [pss_embits]
    mov [pss_zbits], eax
    mov cl, 8
    sub cl, al
    movzx edx, byte [esi]
    shr edx, cl
    test edx, edx
    jnz .bad
    lea eax, [esi + ebx]            ; H = EM[dbLen .. dbLen+31]
    mov [pss_h], eax
    CCALL mgf1, eax, rsa_mask, ebx  ; DB = maskedDB ^ MGF1(H)
    mov esi, [pss_em]
    xor ecx, ecx
.x: mov al, [esi + ecx]
    xor [rsa_mask + ecx], al
    inc ecx
    cmp ecx, ebx
    jb .x
    mov ecx, [pss_zbits]            ; clear the unused top bits
    mov al, 0xFF
    shr al, cl
    and [rsa_mask], al
    mov ecx, ebx                    ; DB = 00..00 01 salt(32)
    sub ecx, 32 + 1
    xor edx, edx
.z: cmp edx, ecx
    jae .one
    cmp byte [rsa_mask + edx], 0
    jne .bad
    inc edx
    jmp .z
.one:
    cmp byte [rsa_mask + edx], 1
    jne .bad
    CCALL c_memzero, rsa_mprime, 8  ; M' = 0^8 | mHash | salt
    CCALL c_memcpy, rsa_mprime + 8, dword ARG(5), 32
    mov eax, rsa_mask
    add eax, ebx
    sub eax, 32
    CCALL c_memcpy, rsa_mprime + 40, eax, 32
    CCALL sha256, rsa_mprime, 72, rsa_hash
    CCALL c_memeq, rsa_hash, dword [pss_h], 32
    CLEAVE
.bad:
    xor eax, eax
    CLEAVE

section .bss
alignb 4
pss_embits  resd 1
pss_emlen   resd 1
pss_em      resd 1
pss_dblen   resd 1
pss_zbits   resd 1
pss_h       resd 1
st_rsabad   resb 32
section .text

section .data
sn_rsa1     db "RSA s^e mod n", 0
sn_rsa2     db "RSA PKCS#1 v1.5 verify", 0
sn_rsa3     db "RSA-PSS verify", 0
sn_rsa4     db "RSA-PSS rejects bad hash", 0
section .text

; rsa_selftest: part of "net selftest"
rsa_selftest:
    CENTER
    CCALL rsa_public, st_out, tv_rsa_sig15, tv_rsa_sig15_len, tv_rsa_n, tv_rsa_n_len, 65537
    CCALL st_report, sn_rsa1, st_out, tv_rsa_pow, tv_rsa_pow_len
    CCALL rsa_pkcs1_verify, tv_rsa_n, tv_rsa_n_len, 65537, tv_rsa_sig15, tv_rsa_sig15_len, tv_rsa_mhash
    CCALL st_flag, sn_rsa2, eax
    CCALL rsa_pss_verify, tv_rsa_n, tv_rsa_n_len, 65537, tv_rsa_sigpss, tv_rsa_sigpss_len, tv_rsa_mhash
    CCALL st_flag, sn_rsa3, eax
    CCALL c_memcpy, st_rsabad, tv_rsa_mhash, 32
    xor byte [st_rsabad + 7], 0x10
    CCALL rsa_pss_verify, tv_rsa_n, tv_rsa_n_len, 65537, tv_rsa_sigpss, tv_rsa_sigpss_len, st_rsabad
    xor eax, 1
    CCALL st_flag, sn_rsa4, eax
    CLEAVE
