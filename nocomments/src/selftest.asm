%include "src/selftest_vectors.inc"

section .bss
alignb 4
st_fail     resd 1
st_out      resb 512
st_buf      resb 64
st_tag      resb 16
st_zero     resb 32
st_ehash    resb 32
st_rk       resb 176
st_gcm      resb GCM_CTX
st_ctx      resb SHA_CTX
st_ctx5     resb S5_CTX
st_r1       resb 32
st_r2       resb 32

section .text

st_hex:
    CENTER
    mov esi, ARG(0)
    mov ebx, ARG(1)
.l: test ebx, ebx
    jz .done
    movzx eax, byte [esi]
    PRINTF `%02x`, eax
    inc esi
    dec ebx
    jmp .l
.done:
    CLEAVE

st_report:
    CENTER
    CCALL c_memeq, dword ARG(1), dword ARG(2), dword ARG(3)
    mov esi, ARG(0)
    test eax, eax
    jz .fail
    PRINTF `  %24s \x01gPASS\x01n\n`, esi
    jmp .done
.fail:
    inc dword [st_fail]
    PRINTF `  %24s \x01rFAIL\x01n\n    got  `, esi
    mov eax, ARG(3)
    cmp eax, 32
    jbe .g
    mov eax, 32
.g: push eax
    CCALL st_hex, dword ARG(1), eax
    PRINTF `\n    want `
    pop eax
    CCALL st_hex, dword ARG(2), eax
    PRINTF `\n`
.done:
    CLEAVE

st_flag:
    CENTER
    mov esi, ARG(0)
    cmp dword ARG(1), 0
    je .fail
    PRINTF `  %24s \x01gPASS\x01n\n`, esi
    jmp .done
.fail:
    inc dword [st_fail]
    PRINTF `  %24s \x01rFAIL\x01n\n`, esi
.done:
    CLEAVE

section .data
sn_sha1     db "SHA-256 (abc)", 0
sn_sha2     db "SHA-256 (multi-part)", 0
sn_hmac1    db "HMAC-SHA256", 0
sn_hmac2    db "HMAC-SHA256 (long key)", 0
sn_hkdf1    db "HKDF extract", 0
sn_hkdf2    db "HKDF expand (derived)", 0
sn_hkdf3    db "HKDF expand (12 bytes)", 0
sn_aes      db "AES-128 (FIPS-197)", 0
sn_gcm1     db "AES-GCM encrypt", 0
sn_gcm2     db "AES-GCM tag", 0
sn_gcm3     db "AES-GCM decrypt", 0
sn_gcm4     db "AES-GCM rejects tampering", 0
sn_x1       db "X25519 (RFC 7748)", 0
sn_x2       db "X25519 public key", 0
sn_rng      db "random numbers differ", 0
sn_sha384   db "SHA-384 (abc)", 0
sn_sha512   db "SHA-512 (multi-part)", 0
section .text

crypto_selftest:
    CENTER
    mov dword [st_fail], 0
    PRINTF `\x01wCrypto self-test\x01n (results checked against Python's cryptography)\n`

    CCALL sha256, tv_abc, tv_abc_len, st_out
    CCALL st_report, sn_sha1, st_out, tv_sha_abc, 32
    CCALL sha256_init, st_ctx
    CCALL sha256_update, st_ctx, tv_pat, 70
    CCALL sha256_update, st_ctx, tv_pat + 70, tv_pat_len - 70
    CCALL sha256_final, st_ctx, st_out
    CCALL st_report, sn_sha2, st_out, tv_sha_pat, 32
    CCALL sha384, tv_abc, tv_abc_len, st_out
    CCALL st_report, sn_sha384, st_out, tv_sha384_abc, 48
    CCALL sha512_init, st_ctx5, 64
    CCALL sha512_update, st_ctx5, tv_pat, 150
    CCALL sha512_update, st_ctx5, tv_pat + 150, tv_pat_len - 150
    CCALL sha512_final, st_ctx5, st_out
    CCALL st_report, sn_sha512, st_out, tv_sha512_pat, 64

    CCALL hmac_sha256, tv_hmac_key, tv_hmac_key_len, tv_hmac_msg, tv_hmac_msg_len, st_out
    CCALL st_report, sn_hmac1, st_out, tv_hmac_out, 32
    CCALL hmac_sha256, tv_hmac_lkey, tv_hmac_lkey_len, tv_pat, tv_pat_len, st_out
    CCALL st_report, sn_hmac2, st_out, tv_hmac_lout, 32

    CCALL hkdf_extract, st_zero, 32, st_zero, 32, st_out
    CCALL st_report, sn_hkdf1, st_out, tv_early, 32
    CCALL sha256, st_zero, 0, st_ehash
    CCALL derive_secret, tv_early, lbl_derived, st_ehash, st_out
    CCALL st_report, sn_hkdf2, st_out, tv_derived, 32
    CCALL hkdf_expand_label, tv_early, lbl_iv, st_zero, 0, st_out, 12
    CCALL st_report, sn_hkdf3, st_out, tv_ivlabel, 12

    CCALL aes128_expand, st_rk, tv_aes_key
    CCALL aes128_encrypt, st_rk, tv_aes_pt, st_out
    CCALL st_report, sn_aes, st_out, tv_aes_ct, 16

    CCALL c_memcpy, st_buf, tv_gcm_pt, tv_gcm_pt_len
    CCALL gcm_setkey, st_gcm, tv_gcm_key
    CCALL gcm_seal, st_gcm, tv_gcm_nonce, tv_gcm_aad, tv_gcm_aad_len, st_buf, tv_gcm_pt_len, st_tag
    CCALL st_report, sn_gcm1, st_buf, tv_gcm_ct, tv_gcm_ct_len
    CCALL st_report, sn_gcm2, st_tag, tv_gcm_tag, 16
    CCALL c_memcpy, st_buf, tv_gcm_ct, tv_gcm_ct_len
    CCALL gcm_open, st_gcm, tv_gcm_nonce, tv_gcm_aad, tv_gcm_aad_len, st_buf, tv_gcm_ct_len, tv_gcm_tag
    test eax, eax
    jnz .open_ok
    inc dword [st_fail]
    PRINTF `  (gcm_open said the tag was wrong)\n`
.open_ok:
    CCALL st_report, sn_gcm3, st_buf, tv_gcm_pt, tv_gcm_pt_len
    CCALL c_memcpy, st_buf, tv_gcm_ct, tv_gcm_ct_len
    xor byte [st_buf + 3], 1
    CCALL gcm_open, st_gcm, tv_gcm_nonce, tv_gcm_aad, tv_gcm_aad_len, st_buf, tv_gcm_ct_len, tv_gcm_tag
    xor eax, 1
    CCALL st_flag, sn_gcm4, eax

    CCALL x25519, st_out, tv_x_scalar, tv_x_u
    CCALL st_report, sn_x1, st_out, tv_x_out, 32
    CCALL x25519_public, st_out, tv_x_priv
    CCALL st_report, sn_x2, st_out, tv_x_pub, 32

    CCALL rand_bytes, st_r1, 32
    CCALL rand_bytes, st_r2, 32
    CCALL c_memeq, st_r1, st_r2, 32
    xor eax, 1
    CCALL st_flag, sn_rng, eax
    call rsa_selftest

    mov esi, st_hw_no
    cmp byte [rng_hw], 0
    je .hw
    mov esi, st_hw_yes
.hw:
    PRINTF `  (hardware random numbers: %s)\n`, esi
    cmp dword [st_fail], 0
    jne .bad
    PRINTF `\x01gAll tests passed.\x01n\n`
    CLEAVE
.bad:
    PRINTF `\x01r%d test(s) failed.\x01n\n`, dword [st_fail]
    CLEAVE

section .data
st_hw_yes   db "yes (RDRAND)", 0
st_hw_no    db "no - using the timer-jitter pool", 0
section .text
