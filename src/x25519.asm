; =============================================================================
;  x25519.asm - Curve25519 Diffie-Hellman (RFC 7748), used by TLS 1.3
;
;  Field elements are 256-bit numbers in 8 little-endian dwords, kept below
;  2^256 and reduced using 2^256 = 38 (mod p, p = 2^255 - 19). Only the final
;  result is reduced all the way below p. The ladder is the one in RFC 7748.
;  C-style calls (CCALL).
; =============================================================================
section .bss
alignb 4
fm_t        resd 16                 ; 512-bit product
fm_i        resd 1
fm_ai       resd 1
fi_a        resd 8                  ; fe_inv input copy
fi_r        resd 8
fc_t        resd 8                  ; fe_canon scratch
xk          resb 32                 ; clamped scalar
xs          resd 1                  ; swap flag
x_1         resd 8
x_2         resd 8
z_2         resd 8
x_3         resd 8
z_3         resd 8
xA          resd 8
xAA         resd 8
xB          resd 8
xBB         resd 8
xE          resd 8
xC          resd 8
xD          resd 8
xDA         resd 8
xCB         resd 8

section .data
; p - 2 = 2^255 - 21, little-endian (the exponent for inversion)
fe_pm2      db 0xEB
            times 30 db 0xFF
            db 0x7F
; p = 2^255 - 19, little-endian dwords
fe_p        dd 0xFFFFFFED, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
            dd 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0x7FFFFFFF
x25519_base db 9
            times 31 db 0

section .text

; FOLD: add ECX to the number at EDI, folding any carry out of bit 256 back
; in as +38 (since 2^256 = 38 mod p)
%macro FOLD 0
%%again:
    add [edi], ecx
%assign i 4
%rep 7
    adc dword [edi + i], 0
%assign i i + 4
%endrep
    jnc %%done
    mov ecx, 38
    jmp %%again
%%done:
%endmacro

; fe_add(out, a, b)
fe_add:
    CENTER
    mov esi, ARG(1)
    mov edx, ARG(2)
    mov edi, ARG(0)
    mov eax, [esi]
    add eax, [edx]
    mov [edi], eax
%assign i 4
%rep 7
    mov eax, [esi + i]
    adc eax, [edx + i]
    mov [edi + i], eax
%assign i i + 4
%endrep
    jnc .done
    mov ecx, 38
    FOLD
.done:
    CLEAVE

; fe_sub(out, a, b)
fe_sub:
    CENTER
    mov esi, ARG(1)
    mov edx, ARG(2)
    mov edi, ARG(0)
    mov eax, [esi]
    sub eax, [edx]
    mov [edi], eax
%assign i 4
%rep 7
    mov eax, [esi + i]
    sbb eax, [edx + i]
    mov [edi + i], eax
%assign i i + 4
%endrep
.borrow:                            ; wrapped below zero: subtract 38 more
    jnc .done
    sub dword [edi], 38
%assign i 4
%rep 7
    sbb dword [edi + i], 0
%assign i i + 4
%endrep
    jmp .borrow
.done:
    CLEAVE

; fe_mul(out, a, b) - out may be the same as a or b
fe_mul:
    CENTER
    mov edi, fm_t
    xor eax, eax
    mov ecx, 16
    rep stosd
    mov edi, ARG(2)                 ; b
    mov dword [fm_i], 0
.row:
    mov eax, ARG(1)
    mov edx, [fm_i]
    mov eax, [eax + edx * 4]
    mov [fm_ai], eax
    lea esi, [fm_t + edx * 4]
    xor ecx, ecx                    ; carry
    xor ebx, ebx                    ; j
.col:
    mov eax, [edi + ebx * 4]
    mul dword [fm_ai]
    add eax, [esi + ebx * 4]
    adc edx, 0
    add eax, ecx
    adc edx, 0
    mov [esi + ebx * 4], eax
    mov ecx, edx
    inc ebx
    cmp ebx, 8
    jb .col
    mov [esi + 32], ecx
    inc dword [fm_i]
    cmp dword [fm_i], 8
    jb .row
    mov edi, ARG(0)                 ; out = low + 38 * high
    xor ecx, ecx
    xor ebx, ebx
.red:
    mov eax, [fm_t + 32 + ebx * 4]
    mov edx, 38
    mul edx
    add eax, [fm_t + ebx * 4]
    adc edx, 0
    add eax, ecx
    adc edx, 0
    mov [edi + ebx * 4], eax
    mov ecx, edx
    inc ebx
    cmp ebx, 8
    jb .red
    imul ecx, ecx, 38
    FOLD
    CLEAVE

; fe_mul_small(out, a, k): out = a * k for a small constant k
fe_mul_small:
    CENTER
    mov esi, ARG(1)
    mov edi, ARG(0)
    xor ecx, ecx
    xor ebx, ebx
.l: mov eax, [esi + ebx * 4]
    mul dword ARG(2)
    add eax, ecx
    adc edx, 0
    mov [edi + ebx * 4], eax
    mov ecx, edx
    inc ebx
    cmp ebx, 8
    jb .l
    imul ecx, ecx, 38
    FOLD
    CLEAVE

; fe_cswap(a, b, swap): exchange a and b when swap = 1
fe_cswap:
    CENTER
    mov esi, ARG(0)
    mov edi, ARG(1)
    mov edx, ARG(2)
    neg edx                         ; 0 or all ones
    xor ecx, ecx
.l: mov eax, [esi + ecx * 4]
    xor eax, [edi + ecx * 4]
    and eax, edx
    xor [esi + ecx * 4], eax
    xor [edi + ecx * 4], eax
    inc ecx
    cmp ecx, 8
    jb .l
    CLEAVE

; fe_inv(out, a): out = a^(p-2) = 1/a
fe_inv:
    CENTER
    CCALL c_memcpy, fi_a, dword ARG(1), 32
    CCALL c_memcpy, fi_r, fi_a, 32  ; bit 254 of p-2 is set: start at a
    mov ebx, 253
.l: CCALL fe_mul, fi_r, fi_r, fi_r
    bt [fe_pm2], ebx
    jnc .next
    CCALL fe_mul, fi_r, fi_r, fi_a
.next:
    dec ebx
    jns .l
    CCALL c_memcpy, dword ARG(0), fi_r, 32
    CLEAVE

; fe_canon(x): reduce x (below 2^256) all the way below p
fe_canon:
    CENTER
    mov ebx, 2
.again:
    mov esi, ARG(0)
    mov eax, [esi]
    sub eax, [fe_p]
    mov [fc_t], eax
%assign i 4
%rep 7
    mov eax, [esi + i]
    sbb eax, [fe_p + i]
    mov [fc_t + i], eax
%assign i i + 4
%endrep
    jc .keep                        ; x < p already
    CCALL c_memcpy, dword ARG(0), fc_t, 32
.keep:
    dec ebx
    jnz .again
    CLEAVE

; x25519(out32, scalar32, u32)
x25519:
    CENTER
    CCALL c_memcpy, xk, dword ARG(1), 32
    and byte [xk], 248              ; clamp the scalar
    and byte [xk + 31], 127
    or byte [xk + 31], 64
    CCALL c_memcpy, x_1, dword ARG(2), 32
    and byte [x_1 + 31], 0x7F
    CCALL c_memzero, x_2, 32
    mov dword [x_2], 1
    CCALL c_memzero, z_2, 32
    CCALL c_memcpy, x_3, x_1, 32
    CCALL c_memzero, z_3, 32
    mov dword [z_3], 1
    mov dword [xs], 0
    mov ebx, 254
.ladder:
    xor eax, eax                    ; k_t
    bt [xk], ebx
    setc al
    xor [xs], eax
    push eax
    CCALL fe_cswap, x_2, x_3, dword [xs]
    CCALL fe_cswap, z_2, z_3, dword [xs]
    pop eax
    mov [xs], eax
    CCALL fe_add, xA, x_2, z_2
    CCALL fe_mul, xAA, xA, xA
    CCALL fe_sub, xB, x_2, z_2
    CCALL fe_mul, xBB, xB, xB
    CCALL fe_sub, xE, xAA, xBB
    CCALL fe_add, xC, x_3, z_3
    CCALL fe_sub, xD, x_3, z_3
    CCALL fe_mul, xDA, xD, xA
    CCALL fe_mul, xCB, xC, xB
    CCALL fe_add, x_3, xDA, xCB
    CCALL fe_mul, x_3, x_3, x_3
    CCALL fe_sub, z_3, xDA, xCB
    CCALL fe_mul, z_3, z_3, z_3
    CCALL fe_mul, z_3, z_3, x_1
    CCALL fe_mul, x_2, xAA, xBB
    CCALL fe_mul_small, z_2, xE, 121665
    CCALL fe_add, z_2, z_2, xAA
    CCALL fe_mul, z_2, z_2, xE
    dec ebx
    jns .ladder
    CCALL fe_cswap, x_2, x_3, dword [xs]
    CCALL fe_cswap, z_2, z_3, dword [xs]
    CCALL fe_inv, z_2, z_2
    CCALL fe_mul, x_2, x_2, z_2
    CCALL fe_canon, x_2
    CCALL c_memcpy, dword ARG(0), x_2, 32
    CLEAVE

; x25519_public(pub32, priv32): pub = priv * basepoint
x25519_public:
    CENTER
    CCALL x25519, dword ARG(0), dword ARG(1), x25519_base
    CLEAVE
