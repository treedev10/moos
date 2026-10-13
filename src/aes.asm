; =============================================================================
;  aes.asm - AES-128 (encryption direction) and AES-GCM
;
;  GCM only ever uses the cipher forwards (counter mode), so no decryption
;  rounds are needed. The S-box comes from crypto_tables.inc.
;
;  GCM context: the 176-byte expanded key, then the 16-byte hash key H.
;  C-style calls (CCALL); see macros.inc.
; =============================================================================
GCM_RK      equ 0
GCM_H       equ 176
GCM_CTX     equ 192

section .bss
alignb 4
aes_st      resb 16                 ; cipher state
aes_t       resb 16                 ; state after SubBytes + ShiftRows
aes_rnd     resd 1
gh_v        resd 4                  ; GHASH: V (big-endian words)
gh_z        resd 4                  ; GHASH: Z
gcm_j0      resb 16                 ; nonce || 1
gcm_ctr     resb 16
gcm_ks      resb 16                 ; one block of key stream
gcm_s       resb 16                 ; GHASH accumulator
gcm_lenblk  resb 16
gcm_tag     resb 16
aes_zero    resb 16

section .data
; ShiftRows: output byte p comes from input byte aes_shift[p] (column-major)
aes_shift   db 0, 5, 10, 15, 4, 9, 14, 3, 8, 13, 2, 7, 12, 1, 6, 11

section .text

; aes128_expand(rk176, key16)
aes128_expand:
    CENTER
    mov edi, ARG(0)
    mov esi, ARG(1)
    mov ecx, 4
    rep movsd
    mov edi, ARG(0)
    mov ecx, 16                     ; byte index of the next word
    mov bl, 1                       ; round constant
.l: cmp ecx, 176
    jae .done
    mov eax, [edi + ecx - 4]
    test ecx, 15
    jnz .plain
    ror eax, 8                      ; RotWord
    mov bh, 4                       ; SubWord
.sub:
    movzx edx, al
    mov al, [aes_sbox + edx]
    ror eax, 8
    dec bh
    jnz .sub
    xor al, bl                      ; Rcon
    add bl, bl
    jnc .plain
    xor bl, 0x1B
.plain:
    xor eax, [edi + ecx - 16]
    mov [edi + ecx], eax
    add ecx, 4
    jmp .l
.done:
    CLEAVE

; SUBSHIFT: aes_t = ShiftRows(SubBytes(aes_st))
%macro SUBSHIFT 0
    xor ecx, ecx
%%l:
    movzx edx, byte [aes_shift + ecx]
    movzx edx, byte [aes_st + edx]
    mov dl, [aes_sbox + edx]
    mov [aes_t + ecx], dl
    inc ecx
    cmp ecx, 16
    jb %%l
%endmacro

; XTIME r8: multiply a byte by x in GF(2^8)
%macro XTIME 1
    add %1, %1
    jnc %%n
    xor %1, 0x1B
%%n:
%endmacro

; MIXCOL off: one column of MixColumns, aes_t -> aes_st
%macro MIXCOL 1
    mov al, [aes_t + %1]
    mov bl, [aes_t + %1 + 1]
    mov cl, [aes_t + %1 + 2]
    mov dl, [aes_t + %1 + 3]
    mov ah, al                      ; t = a0 ^ a1 ^ a2 ^ a3
    xor ah, bl
    xor ah, cl
    xor ah, dl
    mov bh, al
    xor bh, bl
    XTIME bh
    xor bh, al
    xor bh, ah
    mov [aes_st + %1], bh
    mov bh, bl
    xor bh, cl
    XTIME bh
    xor bh, bl
    xor bh, ah
    mov [aes_st + %1 + 1], bh
    mov bh, cl
    xor bh, dl
    XTIME bh
    xor bh, cl
    xor bh, ah
    mov [aes_st + %1 + 2], bh
    mov bh, dl
    xor bh, al
    XTIME bh
    xor bh, dl
    xor bh, ah
    mov [aes_st + %1 + 3], bh
%endmacro

; aes128_encrypt(rk176, in16, out16)
aes128_encrypt:
    CENTER
    mov esi, ARG(0)
    mov edi, ARG(1)
%assign i 0
%rep 4
    mov eax, [edi + i]
    xor eax, [esi + i]
    mov [aes_st + i], eax
%assign i i + 4
%endrep
    mov dword [aes_rnd], 1
.round:
    SUBSHIFT
    cmp dword [aes_rnd], 10
    je .last
    MIXCOL 0
    MIXCOL 4
    MIXCOL 8
    MIXCOL 12
    mov edi, [aes_rnd]
    shl edi, 4
%assign i 0
%rep 4
    mov eax, [aes_st + i]
    xor eax, [esi + edi + i]
    mov [aes_st + i], eax
%assign i i + 4
%endrep
    inc dword [aes_rnd]
    jmp .round
.last:
    mov edi, ARG(2)
%assign i 0
%rep 4
    mov eax, [aes_t + i]
    xor eax, [esi + 160 + i]
    mov [edi + i], eax
%assign i i + 4
%endrep
    CLEAVE

; ------------------------------------------------------------------- GCM
; gcm_setkey(ctx, key16): expand the key and compute H = E(K, 0^128)
gcm_setkey:
    CENTER
    mov ebx, ARG(0)
    CCALL aes128_expand, ebx, dword ARG(1)
    lea eax, [ebx + GCM_H]
    CCALL aes128_encrypt, ebx, aes_zero, eax
    CLEAVE

; ghash_mul(x16, h16): x = x * h in GF(2^128) (GCM bit order)
ghash_mul:
    CENTER
    mov esi, ARG(1)
%assign i 0
%rep 4
    mov eax, [esi + i]
    bswap eax
    mov [gh_v + i], eax
    mov dword [gh_z + i], 0
%assign i i + 4
%endrep
    mov esi, ARG(0)
    xor ebx, ebx
.dw:
    mov edx, [esi + ebx * 4]
    bswap edx
    mov ecx, 32
.bit:
    shl edx, 1                      ; next bit of x, most significant first
    jnc .nox
%assign i 0
%rep 4
    mov eax, [gh_v + i]
    xor [gh_z + i], eax
%assign i i + 4
%endrep
.nox:
    mov edi, [gh_v + 12]            ; V = V >> 1, reduce if a bit fell off
    and edi, 1
    mov eax, [gh_v + 8]
    shrd [gh_v + 12], eax, 1
    mov eax, [gh_v + 4]
    shrd [gh_v + 8], eax, 1
    mov eax, [gh_v + 0]
    shrd [gh_v + 4], eax, 1
    shr dword [gh_v + 0], 1
    test edi, edi
    jz .noreduce
    xor dword [gh_v + 0], 0xE1000000
.noreduce:
    dec ecx
    jnz .bit
    inc ebx
    cmp ebx, 4
    jb .dw
%assign i 0
%rep 4
    mov eax, [gh_z + i]
    bswap eax
    mov [esi + i], eax
%assign i i + 4
%endrep
    CLEAVE

; ghash_update(acc16, h16, data, len): acc = GHASH over data (zero padded)
ghash_update:
    CENTER
    mov esi, ARG(2)
    mov ebx, ARG(3)
.blk:
    test ebx, ebx
    jz .done
    mov ecx, 16
    cmp ebx, ecx
    jae .n
    mov ecx, ebx
.n: sub ebx, ecx
    mov edi, ARG(0)
.x: lodsb
    xor [edi], al
    inc edi
    dec ecx
    jnz .x
    CCALL ghash_mul, dword ARG(0), dword ARG(1)
    jmp .blk
.done:
    CLEAVE

; gcm_ctr_crypt(ctx, data, len): XOR data with the key stream that starts at
; counter inc32(J0). Same operation encrypts and decrypts.
gcm_ctr_crypt:
    CENTER
    mov esi, gcm_j0
    mov edi, gcm_ctr
    mov ecx, 4
    rep movsd
    mov esi, ARG(1)
    mov ebx, ARG(2)
.blk:
    test ebx, ebx
    jz .done
    mov eax, [gcm_ctr + 12]         ; inc32
    bswap eax
    inc eax
    bswap eax
    mov [gcm_ctr + 12], eax
    push esi
    CCALL aes128_encrypt, dword ARG(0), gcm_ctr, gcm_ks
    pop esi
    mov ecx, 16
    cmp ebx, ecx
    jae .n
    mov ecx, ebx
.n: sub ebx, ecx
    mov edi, gcm_ks
.x: mov al, [edi]
    xor [esi], al
    inc esi
    inc edi
    dec ecx
    jnz .x
    jmp .blk
.done:
    CLEAVE

; gcm_tagcalc(ctx, aad, aadlen, ct, ctlen): gcm_tag = E(J0) ^ GHASH(...)
gcm_tagcalc:
    CENTER
    mov ebx, ARG(0)
    CCALL c_memzero, gcm_s, 16
    lea eax, [ebx + GCM_H]
    CCALL ghash_update, gcm_s, eax, dword ARG(1), dword ARG(2)
    lea eax, [ebx + GCM_H]
    CCALL ghash_update, gcm_s, eax, dword ARG(3), dword ARG(4)
    CCALL c_memzero, gcm_lenblk, 16 ; [len(A) bits]64 || [len(C) bits]64
    mov eax, ARG(2)
    shl eax, 3
    bswap eax
    mov [gcm_lenblk + 4], eax
    mov eax, ARG(4)
    shl eax, 3
    bswap eax
    mov [gcm_lenblk + 12], eax
    lea eax, [ebx + GCM_H]
    CCALL ghash_update, gcm_s, eax, gcm_lenblk, 16
    CCALL aes128_encrypt, ebx, gcm_j0, gcm_tag
    xor ecx, ecx
.x: mov al, [gcm_s + ecx]
    xor [gcm_tag + ecx], al
    inc ecx
    cmp ecx, 16
    jb .x
    CLEAVE

; gcm_set_nonce(nonce12): J0 = nonce || 00000001
gcm_set_nonce:
    CENTER
    mov esi, ARG(0)
    mov edi, gcm_j0
    mov ecx, 12
    rep movsb
    mov dword [gcm_j0 + 12], 0x01000000
    CLEAVE

; gcm_seal(ctx, nonce12, aad, aadlen, data, len, tag_out16)
; Encrypts data in place and writes the 16-byte tag.
gcm_seal:
    CENTER
    CCALL gcm_set_nonce, dword ARG(1)
    CCALL gcm_ctr_crypt, dword ARG(0), dword ARG(4), dword ARG(5)
    CCALL gcm_tagcalc, dword ARG(0), dword ARG(2), dword ARG(3), dword ARG(4), dword ARG(5)
    CCALL c_memcpy, dword ARG(6), gcm_tag, 16
    CLEAVE

; gcm_open(ctx, nonce12, aad, aadlen, data, len, tag16) -> EAX = 1 if the tag
; is right (then data is decrypted in place), 0 if not (data left alone).
gcm_open:
    CENTER
    CCALL gcm_set_nonce, dword ARG(1)
    CCALL gcm_tagcalc, dword ARG(0), dword ARG(2), dword ARG(3), dword ARG(4), dword ARG(5)
    CCALL c_memeq, gcm_tag, dword ARG(6), 16
    test eax, eax
    jz .bad
    CCALL gcm_ctr_crypt, dword ARG(0), dword ARG(4), dword ARG(5)
    mov eax, 1
.bad:
    CLEAVE
