; =============================================================================
;  sha512.asm - SHA-512 and SHA-384 (for certificates signed with them)
;
;  SHA-512 works on 64-bit words. In 32-bit code each word is kept in memory
;  as a little-endian quadword (low dword, then high dword) and handled in the
;  EDX:EAX pair; 64-bit rotations use SHRD. SHA-384 is SHA-512 with a
;  different starting value, cut to 48 bytes.
;  C-style calls (CCALL).
; =============================================================================
S5_H        equ 0                   ; 8 quadwords
S5_BUF      equ 64                  ; 128 bytes of pending input
S5_BLEN     equ 192
S5_TOT      equ 196
S5_OUTLEN   equ 200                 ; 64 (SHA-512) or 48 (SHA-384)
S5_CTX      equ 204

section .bss
alignb 8
sha5_w      resq 80
s5_v        resq 8
s5_t1       resq 1
s5_t2       resq 1
s5_x        resq 1
s5_tmp      resb S5_CTX
s5_lenlo    resd 1
s5_lenhi    resd 1

section .text

%define V5_A s5_v + 0
%define V5_B s5_v + 8
%define V5_C s5_v + 16
%define V5_D s5_v + 24
%define V5_E s5_v + 32
%define V5_F s5_v + 40
%define V5_G s5_v + 48
%define V5_H s5_v + 56

%macro LD64 1                       ; EDX:EAX = quadword at %1
    mov eax, [%1]
    mov edx, [%1 + 4]
%endmacro
%macro ST64 1
    mov [%1], eax
    mov [%1 + 4], edx
%endmacro
%macro XOR64 1
    xor [%1], eax
    xor [%1 + 4], edx
%endmacro
%macro ADD64 1                      ; quadword at %1 += EDX:EAX
    add [%1], eax
    adc [%1 + 4], edx
%endmacro
%macro ROR64 1                      ; EDX:EAX rotated right by %1 (EBX used)
%if %1 >= 32
    xchg eax, edx
  %if %1 > 32
    mov ebx, eax
    shrd eax, edx, %1 - 32
    shrd edx, ebx, %1 - 32
  %endif
%else
    mov ebx, eax
    shrd eax, edx, %1
    shrd edx, ebx, %1
%endif
%endmacro
%macro SHR64 1                      ; EDX:EAX >>= %1 (%1 < 32)
    shrd eax, edx, %1
    shr edx, %1
%endmacro
; dst = ror(src,a) ^ ror(src,b) ^ ror(src,c)
%macro S5ROT3 5
    LD64 %2
    ROR64 %3
    ST64 %1
    LD64 %2
    ROR64 %4
    XOR64 %1
    LD64 %2
    ROR64 %5
    XOR64 %1
%endmacro
; dst = ror(src,a) ^ ror(src,b) ^ (src >> c)
%macro S5SIG 5
    LD64 %2
    ROR64 %3
    ST64 %1
    LD64 %2
    ROR64 %4
    XOR64 %1
    LD64 %2
    SHR64 %5
    XOR64 %1
%endmacro
%macro MOV64 2                      ; quadword %1 = quadword %2
    LD64 %2
    ST64 %1
%endmacro

; sha512_compress(ctx, block128)
sha512_compress:
    CENTER
    mov esi, ARG(1)
    xor ecx, ecx
.w16:                               ; W[0..15]: big-endian quadwords
    mov eax, [esi + ecx * 8]
    bswap eax
    mov [sha5_w + ecx * 8 + 4], eax
    mov eax, [esi + ecx * 8 + 4]
    bswap eax
    mov [sha5_w + ecx * 8], eax
    inc ecx
    cmp ecx, 16
    jb .w16
.w80:                               ; W[t] = s1(W[t-2]) + W[t-7] + s0(W[t-15]) + W[t-16]
    S5SIG s5_x, sha5_w + ecx * 8 - 16, 19, 61, 6
    LD64 sha5_w + ecx * 8 - 56
    ADD64 s5_x
    S5SIG s5_t1, sha5_w + ecx * 8 - 120, 1, 8, 7
    LD64 s5_t1
    ADD64 s5_x
    LD64 sha5_w + ecx * 8 - 128
    ADD64 s5_x
    MOV64 sha5_w + ecx * 8, s5_x
    inc ecx
    cmp ecx, 80
    jb .w80
    mov esi, ARG(0)                 ; a..h = H
    mov edi, s5_v
    mov ecx, 16
    rep movsd
    xor ecx, ecx
.round:
    ; T1 = h + S1(e) + Ch(e,f,g) + K[t] + W[t]
    S5ROT3 s5_t1, V5_E, 14, 18, 41
    mov eax, [V5_E]
    and eax, [V5_F]
    mov ebx, [V5_E]
    not ebx
    and ebx, [V5_G]
    xor eax, ebx
    mov edx, [V5_E + 4]
    and edx, [V5_F + 4]
    mov ebx, [V5_E + 4]
    not ebx
    and ebx, [V5_G + 4]
    xor edx, ebx
    ADD64 s5_t1
    LD64 V5_H
    ADD64 s5_t1
    LD64 sha512_k + ecx * 8
    ADD64 s5_t1
    LD64 sha5_w + ecx * 8
    ADD64 s5_t1
    ; T2 = S0(a) + Maj(a,b,c);  Maj = (a&b) | (c & (a|b))
    S5ROT3 s5_t2, V5_A, 28, 34, 39
    mov eax, [V5_A]
    mov ebx, eax
    or ebx, [V5_B]
    and ebx, [V5_C]
    and eax, [V5_B]
    or eax, ebx
    mov [s5_x], eax
    mov eax, [V5_A + 4]
    mov ebx, eax
    or ebx, [V5_B + 4]
    and ebx, [V5_C + 4]
    and eax, [V5_B + 4]
    or eax, ebx
    mov [s5_x + 4], eax
    LD64 s5_x
    ADD64 s5_t2
    ; h=g g=f f=e e=d+T1 d=c c=b b=a a=T1+T2
    MOV64 V5_H, V5_G
    MOV64 V5_G, V5_F
    MOV64 V5_F, V5_E
    LD64 V5_D
    add eax, [s5_t1]
    adc edx, [s5_t1 + 4]
    ST64 V5_E
    MOV64 V5_D, V5_C
    MOV64 V5_C, V5_B
    MOV64 V5_B, V5_A
    LD64 s5_t1
    add eax, [s5_t2]
    adc edx, [s5_t2 + 4]
    ST64 V5_A
    inc ecx
    cmp ecx, 80
    jb .round
    mov esi, ARG(0)                 ; H += a..h
    xor ecx, ecx
.add:
    LD64 s5_v + ecx * 8
    add [esi + ecx * 8], eax
    adc [esi + ecx * 8 + 4], edx
    inc ecx
    cmp ecx, 8
    jb .add
    CLEAVE

; sha512_init(ctx, outlen): outlen 64 = SHA-512, 48 = SHA-384
sha512_init:
    CENTER
    mov edi, ARG(0)
    mov esi, sha512_iv
    cmp dword ARG(1), 48
    jne .iv
    mov esi, sha384_iv
.iv:
    mov ecx, 16
    rep movsd
    mov edi, ARG(0)
    mov dword [edi + S5_BLEN], 0
    mov dword [edi + S5_TOT], 0
    mov eax, ARG(1)
    mov [edi + S5_OUTLEN], eax
    CLEAVE

; sha512_update(ctx, data, len)
sha512_update:
    CENTER
    mov ebx, ARG(0)
    mov esi, ARG(1)
    mov edx, ARG(2)
    add [ebx + S5_TOT], edx
.loop:
    test edx, edx
    jz .done
    mov ecx, 128
    sub ecx, [ebx + S5_BLEN]
    cmp ecx, edx
    jbe .n_ok
    mov ecx, edx
.n_ok:
    lea edi, [ebx + S5_BUF]
    add edi, [ebx + S5_BLEN]
    sub edx, ecx
    add [ebx + S5_BLEN], ecx
    rep movsb
    cmp dword [ebx + S5_BLEN], 128
    jne .loop
    push edx
    lea eax, [ebx + S5_BUF]
    CCALL sha512_compress, ebx, eax
    pop edx
    mov dword [ebx + S5_BLEN], 0
    jmp .loop
.done:
    CLEAVE

; sha512_final(ctx, out): writes 64 or 48 bytes
sha512_final:
    CENTER
    mov ebx, ARG(0)
    mov eax, [ebx + S5_TOT]         ; length in bits
    mov edx, eax
    shr edx, 29
    mov [s5_lenhi], edx
    shl eax, 3
    mov [s5_lenlo], eax
    mov ecx, [ebx + S5_BLEN]
    mov byte [ebx + S5_BUF + ecx], 0x80
    inc ecx
    cmp ecx, 120
    jbe .pad
.fill:
    cmp ecx, 128
    jae .full
    mov byte [ebx + S5_BUF + ecx], 0
    inc ecx
    jmp .fill
.full:
    lea eax, [ebx + S5_BUF]
    CCALL sha512_compress, ebx, eax
    xor ecx, ecx
.pad:                               ; zeros up to the 128-bit length field
    cmp ecx, 120
    jae .len
    mov byte [ebx + S5_BUF + ecx], 0
    inc ecx
    jmp .pad
.len:
    mov eax, [s5_lenhi]
    bswap eax
    mov [ebx + S5_BUF + 120], eax
    mov eax, [s5_lenlo]
    bswap eax
    mov [ebx + S5_BUF + 124], eax
    lea eax, [ebx + S5_BUF]
    CCALL sha512_compress, ebx, eax
    mov edi, ARG(1)
    mov ecx, [ebx + S5_OUTLEN]
    shr ecx, 3                      ; quadwords to write
    xor edx, edx
.out:
    mov eax, [ebx + edx * 8 + 4]
    bswap eax
    mov [edi + edx * 8], eax
    mov eax, [ebx + edx * 8]
    bswap eax
    mov [edi + edx * 8 + 4], eax
    inc edx
    cmp edx, ecx
    jb .out
    CLEAVE

; sha384(data, len, out48) and sha512(data, len, out64): one-shot
sha384:
    CENTER
    CCALL sha512_init, s5_tmp, 48
    jmp sha5_oneshot
sha512:
    CENTER
    CCALL sha512_init, s5_tmp, 64
sha5_oneshot:
    CCALL sha512_update, s5_tmp, dword ARG(0), dword ARG(1)
    CCALL sha512_final, s5_tmp, dword ARG(2)
    CLEAVE

; hash_by_len(data, len, out, hashlen): SHA-256 / 384 / 512 by output size
hash_by_len:
    CENTER
    mov eax, ARG(3)
    cmp eax, 48
    je .h384
    cmp eax, 64
    je .h512
    CCALL sha256, dword ARG(0), dword ARG(1), dword ARG(2)
    CLEAVE
.h384:
    CCALL sha384, dword ARG(0), dword ARG(1), dword ARG(2)
    CLEAVE
.h512:
    CCALL sha512, dword ARG(0), dword ARG(1), dword ARG(2)
    CLEAVE
