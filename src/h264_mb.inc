; =============================================================================
;  h264_mb.inc - slice data and macroblocks (part of h264.asm)
;
;  h264_slice_data walks the macroblocks of a slice (7.3.4): skip runs in P
;  slices, then macroblock_layer() (7.3.5) for each coded macroblock:
;  mb_type, the prediction data (Intra4x4 modes 8.3.1.1, reference indices
;  and motion vector differences), coded_block_pattern, mb_qp_delta and the
;  residual, read with CAVLC (9.2). Each macroblock is reconstructed at
;  once into the current frame (prediction + inverse transform, see
;  h264_dsp.inc) and its data kept for its neighbours and for deblocking.
;
;  Neighbour data are gathered per macroblock into small "caches", 8
;  entries per row: index (y + 1) * 8 + (x + 1) for the 4x4 block at x, y
;  (-1 = the neighbouring macroblock to the left / above; x = 4 on row -1 is
;  the macroblock above to the right). Blocks of the current macroblock not
;  decoded yet are "not available" there, which gives the availability rules
;  of 6.4.11 for free.
; =============================================================================

NNZ_NA          equ 0x80            ; nnz cache: neighbour not available
REF_NA          equ -2              ; ref cache: not available
REF_NONE        equ -1              ;   available, but intra (no reference)

section .bss
alignb 16
h264_coef       resw 16 * 16        ; luma coefficients, 4x4 blocks in raster
h264_ccoef      resw 8 * 16         ; chroma: Cb blocks 0..3, Cr blocks 0..3
h264_dc         resw 16             ; Intra16x16 DC levels (raster)
h264_cdc        resw 8              ; chroma DC levels, Cb then Cr
h264_lev        resd 16             ; levels of one block (CAVLC)
h264_mvc        resd 40             ; motion vector cache (x low, y high word)
h264_refc       resb 40             ; reference index cache
h264_nnzc       resb 40             ; total_coeff cache, luma
h264_nnzcb      resb 16             ; chroma caches: (y + 1) * 4 + (x + 1)
h264_nnzcr      resb 16
h264_modec      resb 40             ; Intra4x4 mode cache (-1: use DC)
h264_i4m        resb 16             ; this macroblock's Intra4x4 modes
alignb 4
h264_mbaddr     resd 1              ; the macroblock: address, x, y
h264_mbx        resd 1
h264_mby        resd 1
h264_mip        resd 1              ; -> its MI_ data
h264_mop        resd 1              ; -> its motion data
h264_avA        resd 1              ; neighbours A (left), B (above), C
h264_avB        resd 1              ; (above right), D (above left):
h264_avC        resd 1              ; 1 = available (same slice)
h264_avD        resd 1
h264_miA        resd 1              ; their MI_ data
h264_miB        resd 1
h264_miC        resd 1
h264_miD        resd 1
h264_iav        resd 1              ; available for intra prediction: bit 0
                                    ; A, 1 B, 2 C, 3 D
h264_dy         resd 1              ; the macroblock in the current frame
h264_du         resd 1
h264_dv         resd 1
h264_qp         resd 1              ; QPY
h264_qpcb       resd 1              ; QPc of Cb, Cr
h264_qpc2       resd 1
h264_mbt        resd 1              ; MT_* of this macroblock
h264_cbp        resd 1              ; coded_block_pattern
h264_i16m       resd 1              ; Intra16x16 prediction mode
h264_cpm        resd 1              ; intra_chroma_pred_mode
h264_cmask      resd 1              ; blocks with coefficients: bits 0-15
                                    ; luma (raster), 16-19 Cb, 20-23 Cr
h264_rb_max     resd 1              ; residual block: maxNumCoeff
h264_rb_scan    resd 1              ;   scan table
h264_rb_dq      resd 1              ;   dequantisation factors (0: none)
h264_rb_out     resd 1              ;   coefficient block
h264_skiprun    resd 1
h264_cplanew    resd 1              ; picture size in pixels (luma)
h264_cplaneh    resd 1
; partitions of an inter macroblock
h264_np         resd 1
h264_px         resb 16             ; position and size in 4x4 blocks
h264_py         resb 16
h264_pw         resb 16
h264_ph         resb 16
h264_pref       resb 16             ; ref_idx_l0
h264_pshape     resb 16             ; 1/2: 16x8 top/bottom, 3/4: 8x16
h264_sub        resb 4              ; sub_mb_type
h264_ref8       resb 4              ; ref_idx_l0 per 8x8 / partition
alignb 4
h264_pmvd       resd 16             ; mvd_l0 (x low, y high word)
h264_pp_x       resd 1              ; motion vector prediction arguments
h264_pp_y       resd 1
h264_pp_w       resd 1
h264_pp_ref     resd 1
h264_pp_shape   resd 1

section .data
; a scan that keeps the order (chroma DC: raster 2x2)
h264_scan_id    db 0, 1, 2, 3
; top-right 4x4 block inside the macroblock already decoded, by block index:
; 0 = no, 1 = yes, 2 = from macroblock B (above), 3 = from C (above right)
h264_tr_tab     db 2, 2, 1, 0, 2, 3, 1, 0, 1, 1, 1, 0, 1, 0, 1, 0

section .text

; =============================================================================
;  The slice
; =============================================================================

; h264_slice_data: decode the macroblocks of the slice whose header was
; read. EAX = 0 (the slice ended properly) / -1 (damaged; the macroblocks
; read so far are kept). Any register may change except EBP.
h264_slice_data:
    push ebp
    mov eax, [h264_sh_qp]
    mov [h264_qp], eax
    mov eax, [h264_mbw]
    shl eax, 4
    mov [h264_cplanew], eax
    mov eax, [h264_mbh]
    shl eax, 4
    mov [h264_cplaneh], eax
    mov eax, [h264_sh_firstmb]
    cmp eax, [h264_nmb]
    jae .bad
    mov [h264_mbaddr], eax
    xor edx, edx
    div dword [h264_mbw]
    mov [h264_mbx], edx
    mov [h264_mby], eax
.loop:
    cmp dword [h264_sh_type], ST_I
    je .coded
    call h264_ue                    ; mb_skip_run
    mov [h264_skiprun], eax
    call h264_bad_pos
    jnz .bad
    mov eax, [h264_skiprun]
    test eax, eax
    jz .coded
.skip:
    mov eax, [h264_mbaddr]
    cmp eax, [h264_nmb]
    jae .bad
    call h264_mb_setup
    jnz .bad
    call h264_mb_skip
    call h264_mb_done
    dec dword [h264_skiprun]
    jz .skipped
    call h264_next_mb
    jmp .skip
.skipped:
    call h264_more_data
    jnc .end
    call h264_next_mb
.coded:
    mov eax, [h264_mbaddr]
    cmp eax, [h264_nmb]
    jae .bad
    call h264_mb_setup
    jnz .bad
    call h264_mb_layer
    test eax, eax
    jnz .badmb
    call h264_bad_pos
    jnz .badmb
    call h264_mb_done
    call h264_more_data
    jnc .end
    call h264_next_mb
    mov eax, [h264_mbaddr]
    cmp eax, [h264_nmb]
    jb .loop
    jmp .end                        ; (data after the last macroblock)
.badmb:
    call h264_clear_coef
.bad:
    or eax, -1
    pop ebp
    ret
.end:
    xor eax, eax
    pop ebp
    ret

; h264_next_mb: move on to the next macroblock address
h264_next_mb:
    inc dword [h264_mbaddr]
    mov eax, [h264_mbx]
    inc eax
    cmp eax, [h264_mbw]
    jb .x
    xor eax, eax
    inc dword [h264_mby]
.x: mov [h264_mbx], eax
    ret

; h264_clear_coef: all coefficient buffers back to zero (after an error)
h264_clear_coef:
    push edi
    mov edi, h264_coef
    mov ecx, (16 * 16 + 8 * 16 + 16 + 8) / 2
    xor eax, eax
    rep stosd
    pop edi
    ret

; h264_mb_setup: the macroblock at h264_mbaddr / mbx / mby: pointers,
; neighbour availability. ZF = 0 (jnz taken) if it was decoded already in
; this picture (overlapping slices: damaged). Any register may change
; except EBP.
h264_mb_setup:
    mov eax, [h264_mbaddr]
    mov esi, eax
    shl esi, 6
    add esi, [h264_mbi]
    mov [h264_mip], esi
    mov edx, [esi + MI_SLICE]
    cmp edx, [h264_pic_slice0]
    jae .dup
    mov ebx, [h264_cur]
    SLOTP ebx
    imul eax, MO_SZ
    add eax, [ebx + SL_MOT]
    mov [h264_mop], eax
    ; where it goes in the frame
    mov eax, [h264_mby]
    shl eax, 4
    imul eax, [h264_ystride]
    mov edx, [h264_mbx]
    shl edx, 4
    add eax, edx
    add eax, [ebx + SL_Y]
    mov [h264_dy], eax
    mov eax, [h264_mby]
    shl eax, 3
    imul eax, [h264_cstride]
    mov edx, [h264_mbx]
    shl edx, 3
    add eax, edx
    mov edx, eax
    add eax, [ebx + SL_U]
    mov [h264_du], eax
    add edx, [ebx + SL_V]
    mov [h264_dv], edx
    ; neighbours: available if in this slice
    mov ecx, [h264_slicenum]
    mov edi, [h264_mbw]
    shl edi, 6                      ; EDI = a row of MI_ data
    xor eax, eax
    mov [h264_avA], eax
    mov [h264_avB], eax
    mov [h264_avC], eax
    mov [h264_avD], eax
    cmp dword [h264_mbx], 0
    je .noA
    lea edx, [esi - MI_SZ]
    mov [h264_miA], edx
    cmp [edx + MI_SLICE], ecx
    jne .noA
    mov dword [h264_avA], 1
.noA:
    cmp dword [h264_mby], 0
    je .noB
    mov edx, esi
    sub edx, edi
    mov [h264_miB], edx
    cmp [edx + MI_SLICE], ecx
    jne .noB0
    mov dword [h264_avB], 1
.noB0:
    cmp dword [h264_mbx], 0
    je .noD
    lea eax, [edx - MI_SZ]
    mov [h264_miD], eax
    cmp [eax + MI_SLICE], ecx
    jne .noD
    mov dword [h264_avD], 1
.noD:
    mov eax, [h264_mbx]
    inc eax
    cmp eax, [h264_mbw]
    jae .noB
    lea eax, [edx + MI_SZ]
    mov [h264_miC], eax
    cmp [eax + MI_SLICE], ecx
    jne .noB
    mov dword [h264_avC], 1
.noB:
    ; availability for intra prediction (constrained_intra_pred: only
    ; intra neighbours)
    xor edx, edx
    mov ecx, [h264_sh_cip]
    cmp dword [h264_avA], 0
    je .i1
    mov eax, [h264_miA]
    call .intra_ok
    jz .i1
    or edx, 1
.i1:
    cmp dword [h264_avB], 0
    je .i2
    mov eax, [h264_miB]
    call .intra_ok
    jz .i2
    or edx, 2
.i2:
    cmp dword [h264_avC], 0
    je .i3
    mov eax, [h264_miC]
    call .intra_ok
    jz .i3
    or edx, 4
.i3:
    cmp dword [h264_avD], 0
    je .i4
    mov eax, [h264_miD]
    call .intra_ok
    jz .i4
    or edx, 8
.i4:
    mov [h264_iav], edx
    xor eax, eax                    ; ZF = 1
    ret
.dup:
    or eax, 1                       ; ZF = 0
    ret
; ZF = 0 if the neighbour at EAX may be used for intra prediction
.intra_ok:
    test ecx, ecx
    jz .yes
    test byte [eax + MI_TYPE], MT_INTRA
    ret
.yes:
    test esp, esp                   ; ZF = 0
    ret

; h264_mb_done: the macroblock decoded: its data stored for its
; neighbours and the deblocking filter
h264_mb_done:
    push esi
    push edi
    mov esi, [h264_mip]
    mov eax, [h264_slicenum]
    mov [esi + MI_SLICE], eax
    mov eax, [h264_mbt]
    mov [esi + MI_TYPE], al
    mov eax, [h264_qp]
    test dword [h264_mbt], MT_PCM
    jz .q
    xor eax, eax                    ; I_PCM: qP 0 for deblocking
.q: mov [esi + MI_QP], al
    mov ecx, [h264_sh_cqp]
    call h264_chroma_qp
    mov [esi + MI_QPC], al
    mov eax, [h264_qp]
    test dword [h264_mbt], MT_PCM
    jz .q2
    xor eax, eax
.q2:
    mov ecx, [h264_sh_cqp2]
    call h264_chroma_qp
    mov [esi + MI_QPC2], al
    ; total_coeff of every block (from the caches)
    mov eax, [h264_nnzc + 9]        ; luma rows y = 0..3
    mov [esi + MI_NNZ], eax
    mov eax, [h264_nnzc + 17]
    mov [esi + MI_NNZ + 4], eax
    mov eax, [h264_nnzc + 25]
    mov [esi + MI_NNZ + 8], eax
    mov eax, [h264_nnzc + 33]
    mov [esi + MI_NNZ + 12], eax
    mov ax, [h264_nnzcb + 5]
    mov [esi + MI_NNZ + 16], ax
    mov ax, [h264_nnzcb + 9]
    mov [esi + MI_NNZ + 18], ax
    mov ax, [h264_nnzcr + 5]
    mov [esi + MI_NNZ + 20], ax
    mov ax, [h264_nnzcr + 9]
    mov [esi + MI_NNZ + 22], ax
    mov eax, [h264_i4m]
    mov [esi + MI_I4M], eax
    mov eax, [h264_i4m + 4]
    mov [esi + MI_I4M + 4], eax
    mov eax, [h264_i4m + 8]
    mov [esi + MI_I4M + 8], eax
    mov eax, [h264_i4m + 12]
    mov [esi + MI_I4M + 12], eax
    mov eax, [h264_sh_dbidc]
    mov [esi + MI_DBIDC], al
    mov eax, [h264_sh_dba]
    mov [esi + MI_DBA], al
    mov eax, [h264_sh_dbb]
    mov [esi + MI_DBB], al
    inc dword [h264_pic_done]
    pop edi
    pop esi
    ret

; h264_chroma_qp: EAX = QPY, ECX = chroma_qp_index_offset -> EAX = QPc
h264_chroma_qp:
    add eax, ecx
    jns .p
    xor eax, eax
.p: cmp eax, 51
    jbe .q
    mov eax, 51
.q: movzx eax, byte [h264_qpc + eax]
    ret

; h264_store_intra_motion: motion data of an intra macroblock (no
; reference, zero vectors)
h264_store_intra_motion:
    push edi
    mov edi, [h264_mop]
    xor eax, eax
    mov ecx, 128 / 4
    rep stosd
    or eax, -1
    mov [edi + MO_REF0 - 128], eax
    mov [edi + MO_REF1 - 128], eax
    mov [edi + MO_RS0 - 128], eax
    mov [edi + MO_RS1 - 128], eax
    mov dword [edi + MO_INTRA - 128], 1
    pop edi
    ret

; =============================================================================
;  Neighbour caches
; =============================================================================

; h264_fill_nnz: the total_coeff caches from the neighbours A and B
h264_fill_nnz:
    push esi
    mov eax, NNZ_NA * 0x01010101
    mov [h264_nnzc + 1], eax        ; row -1 (x = 0..3)
    mov [h264_nnzc + 8], al         ; column -1
    mov [h264_nnzc + 16], al
    mov [h264_nnzc + 24], al
    mov [h264_nnzc + 32], al
    mov [h264_nnzcb + 1], ax
    mov [h264_nnzcb + 4], al
    mov [h264_nnzcb + 8], al
    mov [h264_nnzcr + 1], ax
    mov [h264_nnzcr + 4], al
    mov [h264_nnzcr + 8], al
    cmp dword [h264_avB], 0
    je .noB
    mov esi, [h264_miB]
    mov eax, [esi + MI_NNZ + 12]    ; its bottom row
    mov [h264_nnzc + 1], eax
    mov ax, [esi + MI_NNZ + 18]
    mov [h264_nnzcb + 1], ax
    mov ax, [esi + MI_NNZ + 22]
    mov [h264_nnzcr + 1], ax
.noB:
    cmp dword [h264_avA], 0
    je .noA
    mov esi, [h264_miA]             ; its right column
    mov al, [esi + MI_NNZ + 3]
    mov [h264_nnzc + 8], al
    mov al, [esi + MI_NNZ + 7]
    mov [h264_nnzc + 16], al
    mov al, [esi + MI_NNZ + 11]
    mov [h264_nnzc + 24], al
    mov al, [esi + MI_NNZ + 15]
    mov [h264_nnzc + 32], al
    mov al, [esi + MI_NNZ + 17]
    mov [h264_nnzcb + 4], al
    mov al, [esi + MI_NNZ + 19]
    mov [h264_nnzcb + 8], al
    mov al, [esi + MI_NNZ + 21]
    mov [h264_nnzcr + 4], al
    mov al, [esi + MI_NNZ + 23]
    mov [h264_nnzcr + 8], al
.noA:
    xor eax, eax                    ; this macroblock: nothing yet
    mov [h264_nnzc + 9], eax
    mov [h264_nnzc + 17], eax
    mov [h264_nnzc + 25], eax
    mov [h264_nnzc + 33], eax
    mov [h264_nnzcb + 5], ax
    mov [h264_nnzcb + 9], ax
    mov [h264_nnzcr + 5], ax
    mov [h264_nnzcr + 9], ax
    pop esi
    ret

; h264_nc: ESI = the block's entry in a total_coeff cache, EDX = the cache
; row length (8 luma, 4 chroma) -> EBX = nC (9.2.1)
h264_nc:
    movzx eax, byte [esi - 1]       ; nA
    mov ecx, esi
    sub ecx, edx
    movzx ecx, byte [ecx]           ; nB
    cmp al, NNZ_NA
    je .noA
    cmp cl, NNZ_NA
    je .onlyA
    lea ebx, [eax + ecx + 1]
    shr ebx, 1
    ret
.onlyA:
    mov ebx, eax
    ret
.noA:
    xor ebx, ebx
    cmp cl, NNZ_NA
    je .r
    mov ebx, ecx
.r: ret

; h264_fill_modes: the Intra4x4 mode cache from the neighbours (8.3.1.1):
; -1 if the neighbour is not available (or inter with
; constrained_intra_pred), its modes if it is Intra4x4, else 2 (DC)
h264_fill_modes:
    push esi
    ; above
    mov eax, -1
    cmp dword [h264_avB], 0
    je .b
    mov esi, [h264_miB]
    call .kind
    jnz .b
    mov eax, [esi + MI_I4M + 12]
.b: mov [h264_modec + 1], eax
    mov eax, -1
    cmp dword [h264_avA], 0
    je .a
    mov esi, [h264_miA]
    call .kind
    jnz .a
    mov al, [esi + MI_I4M + 3]
    mov [h264_modec + 8], al
    mov al, [esi + MI_I4M + 7]
    mov [h264_modec + 16], al
    mov al, [esi + MI_I4M + 11]
    mov [h264_modec + 24], al
    mov al, [esi + MI_I4M + 15]
    mov [h264_modec + 32], al
    pop esi
    ret
.a: mov [h264_modec + 8], al
    mov [h264_modec + 16], al
    mov [h264_modec + 24], al
    mov [h264_modec + 32], al
    pop esi
    ret
; ESI = neighbour MI: ZF = 1 if Intra4x4 (use its modes); else EAX = the
; value for all four entries (2, or -1 for an inter neighbour with
; constrained_intra_pred) and ZF = 0
.kind:
    movzx ecx, byte [esi + MI_TYPE]
    test ecx, MT_I4
    jz .k1
    cmp eax, eax
    ret
.k1:
    mov eax, 0x02020202
    test ecx, MT_INTRA
    jnz .k2
    cmp dword [h264_sh_cip], 0
    je .k2
    mov eax, -1
.k2:
    or ecx, 1                       ; ZF = 0
    ret

; h264_fill_motion: the reference index and motion vector caches from the
; neighbours A, B, C, D (list 0)
h264_fill_motion:
    push esi
    push edi
    mov edi, h264_refc
    mov eax, 0xFEFEFEFE             ; REF_NA everywhere
    mov ecx, 10
    rep stosd
    mov edi, h264_mvc
    xor eax, eax
    mov ecx, 40
    rep stosd
    mov ebx, [h264_mop]
    cmp dword [h264_avA], 0
    je .noA
    lea esi, [ebx - MO_SZ]          ; left: its right column
    mov al, [esi + MO_REF0 + 1]
    mov [h264_refc + 8], al
    mov [h264_refc + 16], al
    mov al, [esi + MO_REF0 + 3]
    mov [h264_refc + 24], al
    mov [h264_refc + 32], al
    mov eax, [esi + MO_MV0 + 3 * 4]
    mov [h264_mvc + 8 * 4], eax
    mov eax, [esi + MO_MV0 + 7 * 4]
    mov [h264_mvc + 16 * 4], eax
    mov eax, [esi + MO_MV0 + 11 * 4]
    mov [h264_mvc + 24 * 4], eax
    mov eax, [esi + MO_MV0 + 15 * 4]
    mov [h264_mvc + 32 * 4], eax
.noA:
    mov edx, [h264_mbw]
    imul edx, MO_SZ                 ; EDX = a row of motion data
    cmp dword [h264_avB], 0
    je .noB
    mov esi, ebx                    ; above: its bottom row
    sub esi, edx
    mov al, [esi + MO_REF0 + 2]
    mov [h264_refc + 1], al
    mov [h264_refc + 2], al
    mov al, [esi + MO_REF0 + 3]
    mov [h264_refc + 3], al
    mov [h264_refc + 4], al
    mov eax, [esi + MO_MV0 + 12 * 4]
    mov [h264_mvc + 1 * 4], eax
    mov eax, [esi + MO_MV0 + 13 * 4]
    mov [h264_mvc + 2 * 4], eax
    mov eax, [esi + MO_MV0 + 14 * 4]
    mov [h264_mvc + 3 * 4], eax
    mov eax, [esi + MO_MV0 + 15 * 4]
    mov [h264_mvc + 4 * 4], eax
.noB:
    cmp dword [h264_avC], 0
    je .noC
    mov esi, ebx                    ; above right: its bottom-left block
    sub esi, edx
    add esi, MO_SZ
    mov al, [esi + MO_REF0 + 2]
    mov [h264_refc + 5], al
    mov eax, [esi + MO_MV0 + 12 * 4]
    mov [h264_mvc + 5 * 4], eax
.noC:
    cmp dword [h264_avD], 0
    je .noD
    mov esi, ebx                    ; above left: its bottom-right block
    sub esi, edx
    sub esi, MO_SZ
    mov al, [esi + MO_REF0 + 3]
    mov [h264_refc + 0], al
    mov eax, [esi + MO_MV0 + 15 * 4]
    mov [h264_mvc + 0], eax
.noD:
    pop edi
    pop esi
    ret

; =============================================================================
;  Motion vector prediction (8.4.1.3)
; =============================================================================

; h264_mvpred: the partition at h264_pp_x, _y (4x4 blocks), h264_pp_w
; wide, reference h264_pp_ref, shape h264_pp_shape -> EAX = the predicted
; motion vector (x low word, y high word). EBX ESI EDI kept.
h264_mvpred:
    push ebx
    push esi
    push edi
    push ebp
    mov eax, [h264_pp_y]
    shl eax, 3
    add eax, [h264_pp_x]            ; EAX = (y)*8 + x = index of D
    lea esi, [eax + 8]              ; A = (y+1)*8 + (x-1+1)
    lea edi, [eax + 1]              ; B
    mov ebx, eax
    add ebx, [h264_pp_w]
    inc ebx                         ; C
    cmp byte [h264_refc + ebx], REF_NA & 255
    jne .c
    mov ebx, eax                    ; C not available: D instead
.c: mov ebp, [h264_pp_ref]
    movsx eax, byte [h264_refc + esi]
    movsx ecx, byte [h264_refc + edi]
    movsx edx, byte [h264_refc + ebx]
    ; directional predictions of 16x8 and 8x16 partitions
    push eax
    mov eax, [h264_pp_shape]
    test eax, eax
    jz .median0
    cmp eax, 1
    jne .s2
    cmp ecx, ebp
    jne .median0
    mov eax, [h264_mvc + edi * 4]   ; 16x8 top: B
    jmp .ret1
.s2:
    cmp eax, 4
    je .s4
    mov eax, [esp]                  ; 16x8 bottom, 8x16 left: A
    cmp eax, ebp
    jne .median0
    mov eax, [h264_mvc + esi * 4]
    jmp .ret1
.s4:
    cmp edx, ebp                    ; 8x16 right: C
    jne .median0
    mov eax, [h264_mvc + ebx * 4]
.ret1:
    add esp, 4
    jmp .out
.median0:
    pop eax
    ; B and C not available, A available: A
    cmp ecx, REF_NA
    jne .med
    cmp edx, REF_NA
    jne .med
    cmp eax, REF_NA
    je .med
    mov eax, [h264_mvc + esi * 4]
    jmp .out
.med:
    ; exactly one neighbour with the same reference: its vector
    push ebx
    xor ebx, ebx                    ; count matches, EBX = count,
    cmp eax, ebp                    ; EAX = the index of the match
    jne .m1
    inc ebx
    mov eax, esi
.m1:
    cmp ecx, ebp
    jne .m2
    inc ebx
    mov eax, edi
.m2:
    cmp edx, ebp
    jne .m3
    inc ebx
    mov eax, [esp]
.m3:
    cmp ebx, 1
    pop ebx
    jne .median
    mov eax, [h264_mvc + eax * 4]
    jmp .out
.median:
    ; component-wise median of A, B, C
    movsx eax, word [h264_mvc + esi * 4]
    movsx ecx, word [h264_mvc + edi * 4]
    movsx edx, word [h264_mvc + ebx * 4]
    call h264_median3
    push eax
    movsx eax, word [h264_mvc + esi * 4 + 2]
    movsx ecx, word [h264_mvc + edi * 4 + 2]
    movsx edx, word [h264_mvc + ebx * 4 + 2]
    call h264_median3
    shl eax, 16
    pop ecx
    mov ax, cx
.out:
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

; h264_median3: EAX, ECX, EDX -> EAX = their median. EBX kept.
h264_median3:
    cmp eax, ecx
    jle .s1
    xchg eax, ecx                   ; EAX <= ECX
.s1:
    cmp ecx, edx
    jle .s2
    mov ecx, edx                    ; ECX = min(ECX, EDX)
.s2:
    cmp eax, ecx
    jge .r
    mov eax, ecx
.r: ret

; =============================================================================
;  Macroblock types
; =============================================================================

; h264_mb_layer: macroblock_layer() of a coded macroblock -> EAX = 0 / -1.
; Any register may change except EBP.
h264_mb_layer:
    call h264_ue                    ; mb_type
    mov dword [h264_cmask], 0
    cmp dword [h264_sh_type], ST_I
    je .intra
    cmp eax, 5
    jb h264_mb_inter
    sub eax, 5                      ; intra macroblock in a P slice
.intra:
    test eax, eax
    jz h264_mb_i4
    cmp eax, 25
    jb h264_mb_i16
    je h264_mb_pcm
    or eax, -1
    ret

; h264_mb_skip: a P_Skip macroblock (8.4.1.1): 16x16, reference 0, the
; predicted motion vector unless a neighbour suggests no motion; no
; residual
h264_mb_skip:
    mov dword [h264_mbt], MT_SKIP
    mov dword [h264_cbp], 0
    mov dword [h264_cmask], 0
    xor eax, eax
    mov [h264_nnzc + 9], eax
    mov [h264_nnzc + 17], eax
    mov [h264_nnzc + 25], eax
    mov [h264_nnzc + 33], eax
    mov [h264_nnzcb + 5], ax
    mov [h264_nnzcb + 9], ax
    mov [h264_nnzcr + 5], ax
    mov [h264_nnzcr + 9], ax
    mov dword [h264_i4m], 0x02020202
    mov dword [h264_i4m + 4], 0x02020202
    mov dword [h264_i4m + 8], 0x02020202
    mov dword [h264_i4m + 12], 0x02020202
    call h264_fill_motion
    xor eax, eax                    ; mvL0 = 0 if A or B is missing, or
    cmp byte [h264_refc + 8], REF_NA & 255   ; has ref 0 and no motion
    je .mv
    cmp byte [h264_refc + 1], REF_NA & 255
    je .mv
    cmp byte [h264_refc + 8], 0
    jne .b
    cmp dword [h264_mvc + 8 * 4], 0
    je .mv
.b: cmp byte [h264_refc + 1], 0
    jne .pred
    cmp dword [h264_mvc + 1 * 4], 0
    je .mv
.pred:
    xor eax, eax
    mov [h264_pp_x], eax
    mov [h264_pp_y], eax
    mov [h264_pp_ref], eax
    mov [h264_pp_shape], eax
    mov dword [h264_pp_w], 4
    call h264_mvpred
.mv:
    mov dword [h264_np], 1
    xor ecx, ecx
    mov [h264_px], cl
    mov [h264_py], cl
    mov [h264_pref], cl
    mov byte [h264_pw], 4
    mov byte [h264_ph], 4
    mov [h264_tmpi], eax
    call h264_set_part_mv
    call h264_mc_part
    jmp h264_store_motion

; ---- I_PCM (raw samples) ----------------------------------------------------
h264_mb_pcm:
    mov dword [h264_mbt], MT_INTRA | MT_PCM
    mov eax, [h264_bp]              ; pcm_alignment_zero_bit
    add eax, 7
    and eax, ~7
    mov [h264_bp], eax
    add eax, 384 * 8                ; 384 bytes must be there
    cmp eax, [h264_bend]
    ja .bad
    mov esi, [h264_bp]
    shr esi, 3
    add esi, [h264_bbuf]
    mov edi, [h264_dy]
    mov edx, [h264_ystride]
    mov ebx, 16
.y: mov ecx, 4
    push edi
    rep movsd
    pop edi
    add edi, edx
    dec ebx
    jnz .y
    mov edx, [h264_cstride]
    mov edi, [h264_du]
    call .c8
    mov edi, [h264_dv]
    call .c8
    add dword [h264_bp], 384 * 8
    ; all coefficients count as present (nC = 16 for the neighbours)
    mov eax, 0x10101010
    mov [h264_nnzc + 9], eax
    mov [h264_nnzc + 17], eax
    mov [h264_nnzc + 25], eax
    mov [h264_nnzc + 33], eax
    mov [h264_nnzcb + 5], ax
    mov [h264_nnzcb + 9], ax
    mov [h264_nnzcr + 5], ax
    mov [h264_nnzcr + 9], ax
    mov eax, 0x02020202
    mov [h264_i4m], eax
    mov [h264_i4m + 4], eax
    mov [h264_i4m + 8], eax
    mov [h264_i4m + 12], eax
    call h264_store_intra_motion
    xor eax, eax
    ret
.c8:
    mov ebx, 8
.cl:
    movsd
    movsd
    sub edi, 8
    add edi, edx
    dec ebx
    jnz .cl
    ret
.bad:
    or eax, -1
    ret

; ---- Intra_4x4 --------------------------------------------------------------
h264_mb_i4:
    mov dword [h264_mbt], MT_INTRA | MT_I4
    call h264_fill_modes
    ; prev_intra4x4_pred_mode_flag / rem_intra4x4_pred_mode, blocks in
    ; decoding order
    xor ebx, ebx
.blk:
    movzx esi, byte [h264_blk_r + ebx]  ; raster index
    mov edi, esi
    and edi, 3                      ; x
    shr esi, 2                      ; y
    lea esi, [esi * 8 + edi + 9]    ; cache index of the block
    movsx eax, byte [h264_modec + esi - 1]  ; A
    movsx ecx, byte [h264_modec + esi - 8]  ; B
    mov edx, 2                      ; predIntra4x4PredMode
    test eax, eax
    js .p
    test ecx, ecx
    js .p
    mov edx, eax
    cmp ecx, edx
    jae .p
    mov edx, ecx
.p: push edx
    call h264_u1                    ; prev_intra4x4_pred_mode_flag
    pop edx
    test eax, eax
    jnz .use
    push edx
    mov ecx, 3
    call h264_u                     ; rem_intra4x4_pred_mode
    pop edx
    cmp eax, edx
    jb .rem
    inc eax
.rem:
    mov edx, eax
.use:
    mov [h264_modec + esi], dl
    movzx eax, byte [h264_blk_r + ebx]
    mov [h264_i4m + eax], dl
    inc ebx
    cmp ebx, 16
    jb .blk
    call h264_ue                    ; intra_chroma_pred_mode
    cmp eax, 3
    ja .bad
    mov [h264_cpm], eax
    call h264_ue                    ; coded_block_pattern
    cmp eax, 47
    ja .bad
    movzx eax, byte [h264_cbp_intra + eax]
    mov [h264_cbp], eax
    call h264_fill_nnz
    test eax, eax
    mov eax, [h264_cbp]
    test eax, eax
    jz .noqp
    call h264_qp_delta
    jnz .bad
.noqp:
    call h264_res_luma
    jnz .bad
    call h264_res_chroma
    jnz .bad
    call h264_rec_i4
    call h264_rec_chroma_intra
    call h264_store_intra_motion
    xor eax, eax
    ret
.bad:
    or eax, -1
    ret

; ---- Intra_16x16 ------------------------------------------------------------
; EAX = mb_type 1..24: prediction mode, chroma and luma coded block pattern
h264_mb_i16:
    mov dword [h264_mbt], MT_INTRA | MT_I16
    dec eax
    xor edx, edx
    mov ecx, 4
    div ecx
    mov [h264_i16m], edx            ; mode = (t - 1) % 4
    xor edx, edx
    mov ecx, 3
    div ecx                         ; EDX = chroma pattern, EAX = luma (0/1)
    shl edx, 4
    neg eax
    and eax, 15
    or eax, edx
    mov [h264_cbp], eax
    mov eax, 0x02020202
    mov [h264_i4m], eax
    mov [h264_i4m + 4], eax
    mov [h264_i4m + 8], eax
    mov [h264_i4m + 12], eax
    call h264_ue                    ; intra_chroma_pred_mode
    cmp eax, 3
    ja .bad
    mov [h264_cpm], eax
    call h264_fill_nnz
    call h264_qp_delta
    jnz .bad
    ; the DC levels (nC of block 0)
    mov esi, h264_nnzc + 9
    mov edx, 8
    call h264_nc
    mov edi, h264_dc
    mov esi, h264_zigzag
    mov dword [h264_rb_max], 16
    mov dword [h264_rb_dq], 0
    call h264_resblock
    test eax, eax
    js .bad
    call h264_bad_pos
    jnz .bad
    call h264_res_luma
    jnz .bad
    call h264_res_chroma
    jnz .bad
    call h264_luma_dc
    call h264_rec_i16
    call h264_rec_chroma_intra
    call h264_store_intra_motion
    xor eax, eax
    ret
.bad:
    or eax, -1
    ret

; ---- P macroblocks ----------------------------------------------------------
; EAX = mb_type 0..4 (P_L0_16x16, P_L0_L0_16x8, P_L0_L0_8x16, P_8x8,
; P_8x8ref0)
h264_mb_inter:
    mov dword [h264_mbt], 0
    mov ebp, eax                    ; EBP = mb_type (h264_slice_data
    push ebp                        ;  keeps its EBP on the stack)
    mov dword [h264_ref8], 0
    cmp eax, 3
    jae .p8x8
    ; one or two partitions
    xor ecx, ecx
    mov [h264_px], cl
    mov [h264_py], cl
    mov [h264_pshape], cl
    mov dword [h264_np], 1
    mov byte [h264_pw], 4
    mov byte [h264_ph], 4
    test eax, eax
    jz .refs
    mov dword [h264_np], 2
    cmp eax, 1
    jne .v
    mov byte [h264_ph], 2           ; 16x8
    mov byte [h264_ph + 1], 2
    mov byte [h264_pw + 1], 4
    mov byte [h264_px + 1], 0
    mov byte [h264_py + 1], 2
    mov byte [h264_pshape], 1
    mov byte [h264_pshape + 1], 2
    jmp .refs
.v: mov byte [h264_pw], 2           ; 8x16
    mov byte [h264_pw + 1], 2
    mov byte [h264_ph + 1], 4
    mov byte [h264_px + 1], 2
    mov byte [h264_py + 1], 0
    mov byte [h264_pshape], 3
    mov byte [h264_pshape + 1], 4
.refs:
    xor ebx, ebx                    ; ref_idx_l0 per partition
.r1:
    call h264_ref_idx
    js .bad
    mov [h264_pref + ebx], al
    inc ebx
    cmp ebx, [h264_np]
    jb .r1
    xor ebx, ebx                    ; mvd_l0 per partition
.m1:
    call h264_read_mvd
    mov [h264_pmvd + ebx * 4], eax
    inc ebx
    cmp ebx, [h264_np]
    jb .m1
    jmp .pred
.p8x8:
    xor ebx, ebx                    ; sub_mb_type[4]
.s1:
    call h264_ue
    cmp eax, 3
    ja .bad
    mov [h264_sub + ebx], al
    inc ebx
    cmp ebx, 4
    jb .s1
    xor ebx, ebx                    ; ref_idx_l0[4] (not for P_8x8ref0)
.s2:
    xor eax, eax
    cmp ebp, 4
    je .s3
    call h264_ref_idx
    js .bad
.s3:
    mov [h264_ref8 + ebx], al
    inc ebx
    cmp ebx, 4
    jb .s2
    ; the sub-partitions, in order
    xor ebx, ebx                    ; EBX = 8x8 block
    xor edi, edi                    ; EDI = partitions so far
.s4:
    mov ecx, ebx                    ; its position in 4x4 blocks
    and ecx, 1
    shl ecx, 1
    mov edx, ebx
    shr edx, 1
    shl edx, 1
    mov al, [h264_ref8 + ebx]
    movzx esi, byte [h264_sub + ebx]
    test esi, esi
    jnz .s5
    call .add                       ; 8x8
    mov byte [h264_pw + edi - 1], 2
    mov byte [h264_ph + edi - 1], 2
    jmp .s9
.s5:
    cmp esi, 1
    jne .s6
    call .add                       ; 8x4
    mov byte [h264_pw + edi - 1], 2
    inc edx
    call .add
    mov byte [h264_pw + edi - 1], 2
    jmp .s9
.s6:
    cmp esi, 2
    jne .s7
    call .add                       ; 4x8
    mov byte [h264_ph + edi - 1], 2
    inc ecx
    call .add
    mov byte [h264_ph + edi - 1], 2
    jmp .s9
.s7:
    call .add                       ; 4x4
    inc ecx
    call .add
    dec ecx
    inc edx
    call .add
    inc ecx
    call .add
.s9:
    inc ebx
    cmp ebx, 4
    jb .s4
    mov [h264_np], edi
    xor ebx, ebx                    ; the mvds
.s10:
    call h264_read_mvd
    mov [h264_pmvd + ebx * 4], eax
    inc ebx
    cmp ebx, [h264_np]
    jb .s10
.pred:
    call h264_bad_pos
    jnz .bad
    ; motion vectors and prediction
    call h264_fill_motion
    xor ebx, ebx
.pp:
    movzx eax, byte [h264_px + ebx]
    mov [h264_pp_x], eax
    movzx eax, byte [h264_py + ebx]
    mov [h264_pp_y], eax
    movzx eax, byte [h264_pw + ebx]
    mov [h264_pp_w], eax
    movzx eax, byte [h264_pref + ebx]
    mov [h264_pp_ref], eax
    movzx eax, byte [h264_pshape + ebx]
    mov [h264_pp_shape], eax
    call h264_mvpred
    mov edx, [h264_pmvd + ebx * 4]  ; + mvd (each component wraps at 16 bits)
    mov ecx, eax
    add cx, dx
    shr eax, 16
    shr edx, 16
    add ax, dx
    shl eax, 16
    mov ax, cx
    mov [h264_tmpi], eax
    push ebx
    call h264_set_part_mv1
    pop ebx
    inc ebx
    cmp ebx, [h264_np]
    jb .pp
    ; motion compensation of every partition
    xor ebx, ebx
.mc:
    push ebx
    call h264_mc_part1
    pop ebx
    inc ebx
    cmp ebx, [h264_np]
    jb .mc
    call h264_store_motion
    ; coded_block_pattern, mb_qp_delta, residual
    call h264_ue
    cmp eax, 47
    ja .bad
    movzx eax, byte [h264_cbp_inter + eax]
    mov [h264_cbp], eax
    mov eax, 0x02020202
    mov [h264_i4m], eax
    mov [h264_i4m + 4], eax
    mov [h264_i4m + 8], eax
    mov [h264_i4m + 12], eax
    call h264_fill_nnz
    cmp dword [h264_cbp], 0
    je .nores
    call h264_qp_delta
    jnz .bad
    call h264_res_luma
    jnz .bad
    call h264_res_chroma
    jnz .bad
    call h264_rec_residual
.nores:
    pop ebp
    xor eax, eax
    ret
.bad:
    pop ebp
    or eax, -1
    ret
; add a partition: ECX = x, EDX = y, AL = ref -> EDI + 1 (size 1x1 4x4)
.add:
    mov [h264_px + edi], cl
    mov [h264_py + edi], dl
    mov [h264_pref + edi], al
    mov byte [h264_pw + edi], 1
    mov byte [h264_ph + edi], 1
    mov byte [h264_pshape + edi], 0
    inc edi
    ret

; h264_ref_idx: EAX = ref_idx_l0 (te(v), range num_ref_idx_l0_active - 1),
; SF = 1 (js taken) if out of range
h264_ref_idx:
    mov ecx, [h264_sh_nref0]
    cmp ecx, 1
    jbe .zero
    cmp ecx, 2
    je .bit
    call h264_ue
    cmp eax, [h264_sh_nref0]
    jae .bad
    test eax, eax
    ret
.bit:
    call h264_u1
    xor eax, 1
    ret
.zero:
    xor eax, eax
    ret
.bad:
    or eax, -1
    ret

; h264_read_mvd: EAX = mvd_l0 (x low word, y high word)
h264_read_mvd:
    call h264_se
    push eax
    call h264_se
    shl eax, 16
    pop ecx
    mov ax, cx
    ret

; h264_set_part_mv1: partition EBX gets the vector h264_tmpi: written into
; the caches (so later partitions see it)
h264_set_part_mv1:
    mov ecx, ebx
    jmp h264_set_mv_common
; h264_set_part_mv: the same for partition 0
h264_set_part_mv:
    xor ecx, ecx
h264_set_mv_common:
    push esi
    push edi
    movzx esi, byte [h264_py + ecx]
    shl esi, 3
    movzx eax, byte [h264_px + ecx]
    lea esi, [esi + eax + 9]        ; cache index of the top-left block
    movzx edx, byte [h264_ph + ecx]
    mov al, [h264_pref + ecx]
    movzx edi, byte [h264_pw + ecx]
    mov ecx, [h264_tmpi]
.row:
    push esi
    push edi
.col:
    mov [h264_refc + esi], al
    mov [h264_mvc + esi * 4], ecx
    inc esi
    dec edi
    jnz .col
    pop edi
    pop esi
    add esi, 8
    dec edx
    jnz .row
    pop edi
    pop esi
    ret

; h264_store_motion: the motion data of this inter macroblock (from the
; caches) into its frame's motion store
h264_store_motion:
    push esi
    push edi
    mov edi, [h264_mop]
    mov esi, h264_mvc + 9 * 4
    mov ecx, 4
.r: movsd
    movsd
    movsd
    movsd
    add esi, 4 * 4
    loop .r
    mov edi, [h264_mop]
    mov al, [h264_refc + 9]
    mov [edi + MO_REF0], al
    mov al, [h264_refc + 11]
    mov [edi + MO_REF0 + 1], al
    mov al, [h264_refc + 25]
    mov [edi + MO_REF0 + 2], al
    mov al, [h264_refc + 27]
    mov [edi + MO_REF0 + 3], al
    xor ecx, ecx                    ; the frames they refer to
.rs:
    movzx eax, byte [edi + MO_REF0 + ecx]
    movzx eax, byte [h264_list0 + eax]
    mov [edi + MO_RS0 + ecx], al
    inc ecx
    cmp ecx, 4
    jb .rs
    mov dword [edi + MO_REF1], -1
    mov dword [edi + MO_RS1], -1
    mov dword [edi + MO_INTRA], 0
    pop edi
    pop esi
    ret

; h264_mc_part / h264_mc_part1: motion compensated prediction of partition
; 0 / EBX (vector and reference from the caches) into the current frame
h264_mc_part:
    xor ebx, ebx
h264_mc_part1:
    push esi
    push edi
    push ebp
    movzx eax, byte [h264_py + ebx]
    shl eax, 3
    movzx ecx, byte [h264_px + ebx]
    add eax, ecx
    mov ebp, [h264_mvc + eax * 4 + 9 * 4]   ; EBP = vector
    movzx eax, byte [h264_pref + ebx]
    movzx eax, byte [h264_list0 + eax]
    SLOTP eax
    mov [h264_mc_refp], eax
    movzx eax, byte [h264_pw + ebx]
    shl eax, 2
    mov [h264_mc_w], eax
    movzx eax, byte [h264_ph + ebx]
    shl eax, 2
    mov [h264_mc_h], eax
    ; luma: position in quarter samples
    movzx eax, byte [h264_px + ebx]
    mov ecx, [h264_mbx]
    shl ecx, 2
    add eax, ecx                    ; x in 4x4 blocks
    shl eax, 4                      ; quarter samples
    movsx ecx, bp
    add eax, ecx
    mov [h264_mc_x], eax
    movzx eax, byte [h264_py + ebx]
    mov ecx, [h264_mby]
    shl ecx, 2
    add eax, ecx
    shl eax, 4
    mov ecx, ebp
    sar ecx, 16
    add eax, ecx
    mov [h264_mc_y], eax
    movzx eax, byte [h264_py + ebx]
    shl eax, 2
    imul eax, [h264_ystride]
    movzx ecx, byte [h264_px + ebx]
    shl ecx, 2
    add eax, ecx
    add eax, [h264_dy]
    mov edi, eax
    mov eax, [h264_mc_refp]
    mov esi, [eax + SL_Y]
    push ebx
    call h264_mc_luma
    pop ebx
    ; chroma: eighth samples
    shr dword [h264_mc_w], 1
    shr dword [h264_mc_h], 1
    movzx eax, byte [h264_px + ebx]
    mov ecx, [h264_mbx]
    shl ecx, 2
    add eax, ecx
    shl eax, 4                      ; (x * 2 chroma samples) * 8
    movsx ecx, bp
    add eax, ecx
    mov [h264_mc_x], eax
    movzx eax, byte [h264_py + ebx]
    mov ecx, [h264_mby]
    shl ecx, 2
    add eax, ecx
    shl eax, 4
    mov ecx, ebp
    sar ecx, 16
    add eax, ecx
    mov [h264_mc_y], eax
    movzx eax, byte [h264_py + ebx]
    shl eax, 1
    imul eax, [h264_cstride]
    movzx ecx, byte [h264_px + ebx]
    shl ecx, 1
    add eax, ecx
    push eax
    add eax, [h264_du]
    mov edi, eax
    mov eax, [h264_mc_refp]
    mov esi, [eax + SL_U]
    call h264_mc_chroma
    pop eax
    add eax, [h264_dv]
    mov edi, eax
    mov eax, [h264_mc_refp]
    mov esi, [eax + SL_V]
    call h264_mc_chroma
    pop ebp
    pop edi
    pop esi
    ret

; =============================================================================
;  Residual
; =============================================================================

; h264_qp_delta: mb_qp_delta -> QPY updated (and the chroma QPs). ZF = 0
; (jnz taken) if out of range.
h264_qp_delta:
    call h264_se
    add eax, 26
    cmp eax, 51
    ja .bad
    add eax, [h264_qp]              ; (QP + delta + 52) % 52
    add eax, 26
    cmp eax, 52
    jb .s
    sub eax, 52
    cmp eax, 52
    jb .s
    sub eax, 52
.s: mov [h264_qp], eax
    xor eax, eax
    ret
.bad:
    or eax, 1
    ret

; h264_set_cqp: the chroma QPs from QPY
h264_set_cqp:
    mov eax, [h264_qp]
    mov ecx, [h264_sh_cqp]
    call h264_chroma_qp
    mov [h264_qpcb], eax
    mov eax, [h264_qp]
    mov ecx, [h264_sh_cqp2]
    call h264_chroma_qp
    mov [h264_qpc2], eax
    ret

; h264_res_luma: the luma residual blocks of the coded 8x8 quadrants
; (Intra16x16: the AC blocks). ZF = 0 (jnz taken) if damaged.
h264_res_luma:
    push ebp
    mov eax, [h264_qp]
    shl eax, 6
    add eax, h264_dq4
    mov [h264_rb_dq], eax
    xor ebp, ebp                    ; EBP = block (decoding order)
.blk:
    mov eax, ebp
    shr eax, 2
    bt dword [h264_cbp], eax
    jnc .next
    movzx eax, byte [h264_blk_r + ebp]  ; raster index
    push eax
    mov esi, eax
    and esi, 3
    shr eax, 2
    lea esi, [eax * 8 + esi + 9 + h264_nnzc]
    mov edx, 8
    call h264_nc
    push esi
    mov edi, [esp + 4]
    shl edi, 5
    add edi, h264_coef
    mov esi, h264_zigzag
    mov dword [h264_rb_max], 16
    test dword [h264_mbt], MT_I16
    jz .rb
    inc esi                         ; AC: scan positions 1..15
    mov dword [h264_rb_max], 15
.rb:
    call h264_resblock
    pop esi
    pop ecx
    test eax, eax
    js .bad
    mov [esi], al                   ; total_coeff
    jz .next0
    bts dword [h264_cmask], ecx
.next0:
    call h264_bad_pos
    jnz .bad
.next:
    inc ebp
    cmp ebp, 16
    jb .blk
    pop ebp
    xor eax, eax
    ret
.bad:
    pop ebp
    or eax, 1
    ret

; h264_res_chroma: the chroma DC and AC blocks. ZF = 0 (jnz taken) if
; damaged.
h264_res_chroma:
    push ebp
    call h264_set_cqp
    mov eax, [h264_cbp]
    shr eax, 4
    jz .done
    ; DC of Cb and Cr
    mov dword [h264_rb_max], 4
    mov dword [h264_rb_dq], 0
    mov ebx, -1
    mov edi, h264_cdc
    mov esi, h264_scan_id
    call h264_resblock
    test eax, eax
    js .bad
    mov ebx, -1
    mov edi, h264_cdc + 8
    mov esi, h264_scan_id
    call h264_resblock
    test eax, eax
    js .bad
    call h264_bad_pos
    jnz .bad
    cmp dword [h264_cbp], 32
    jb .dc
    ; AC: Cb blocks 0..3, then Cr
    mov dword [h264_rb_max], 15
    xor ebp, ebp
.ac:
    mov eax, [h264_qpcb]
    mov esi, h264_nnzcb
    cmp ebp, 4
    jb .cb
    mov eax, [h264_qpc2]
    mov esi, h264_nnzcr
.cb:
    shl eax, 6
    add eax, h264_dq4
    mov [h264_rb_dq], eax
    mov eax, ebp
    and eax, 3
    mov ecx, eax
    and ecx, 1                      ; x
    shr eax, 1                      ; y
    lea eax, [eax * 4 + ecx + 5]
    add esi, eax
    mov edx, 4
    call h264_nc
    push esi
    mov edi, ebp
    shl edi, 5
    add edi, h264_ccoef
    mov esi, h264_zigzag + 1
    call h264_resblock
    pop esi
    test eax, eax
    js .bad
    mov [esi], al
    jz .acn
    lea ecx, [ebp + 16]
    bts dword [h264_cmask], ecx
.acn:
    call h264_bad_pos
    jnz .bad
    inc ebp
    cmp ebp, 8
    jb .ac
.dc:
    call h264_chroma_dc
.done:
    pop ebp
    xor eax, eax
    ret
.bad:
    pop ebp
    or eax, 1
    ret

; h264_resblock: residual_block_cavlc() (7.3.5.3.2) -> the levels placed
; (and dequantised) into a coefficient block.
;   EDI = coefficient block (int16[16], raster positions),
;   EBX = nC (-1: chroma DC), ESI = scan (scan index -> raster position),
;   h264_rb_max = maxNumCoeff, h264_rb_dq = dequantisation factors per
;   raster position (dd[16]) or 0 (levels stored as they are).
;   -> EAX = TotalCoeff, or -1 if damaged. EBX ESI EDI EBP kept.
h264_resblock:
    push ebx
    push esi
    push edi
    push ebp
    mov [h264_rb_scan], esi
    mov [h264_rb_out], edi
    ; coeff_token (9.2.1)
    test ebx, ebx
    js .ctc
    cmp ebx, 8
    jae .flc
    mov esi, [h264_ct_tab + ebx * 4]
    call h264_vlc
    jmp .ct
.ctc:
    mov esi, h264_ctc
    call h264_vlc
    jmp .ct
.flc:                               ; nC >= 8: 6-bit fixed length code
    mov ecx, 6
    call h264_u
    cmp eax, 3
    je .tc0
    mov edx, eax
    shr eax, 2
    inc eax                         ; TotalCoeff
    and edx, 3                      ; TrailingOnes
    cmp edx, eax
    ja .bad
    shl edx, 5
    or eax, edx
    jmp .ct
.tc0:
    xor eax, eax
.ct:
    test eax, eax
    js .bad
    mov ebx, eax
    and ebx, 31                     ; EBX = TotalCoeff
    shr eax, 5
    mov ebp, eax                    ; EBP = TrailingOnes
    test ebx, ebx
    jz .zero
    cmp ebx, [h264_rb_max]
    ja .bad
    ; levels (9.2.2)
    xor esi, esi                    ; ESI = suffixLength
    cmp ebx, 10
    jbe .sl0
    cmp ebp, 3
    jae .sl0
    inc esi
.sl0:
    xor edi, edi                    ; EDI = i
    test ebp, ebp
    jz .levels
    mov ecx, ebp                    ; trailing ones: one sign bit each
    call h264_u
    mov ecx, ebp
.t1:
    dec ecx
    bt eax, ecx
    sbb edx, edx                    ; 1 -> -1, 0 -> +1
    lea edx, [edx * 2 + 1]
    mov [h264_lev + edi * 4], edx
    inc edi
    test ecx, ecx
    jnz .t1
.levels:
    cmp edi, ebx
    jae .levdone
    call h264_peek                  ; level_prefix: leading zero bits
    bsr ecx, eax
    jz .bad
    xor ecx, 31
    lea edx, [ecx + 1]
    add [h264_bp], edx
    cmp ecx, 28
    ja .bad
    ; levelCode = (Min(15, level_prefix) << suffixLength) + level_suffix
    mov eax, ecx
    cmp eax, 15
    jbe .lp
    mov eax, 15
.lp:
    push ecx
    mov ecx, esi
    shl eax, cl
    pop ecx
    mov edx, esi                    ; levelSuffixSize
    cmp ecx, 14
    jb .sz
    ja .sz15
    test esi, esi
    jnz .sz
    mov edx, 4
    jmp .sz
.sz15:
    cmp ecx, 15
    jb .sz
    lea edx, [ecx - 3]
.sz:
    test edx, edx
    jz .nosuf
    push eax
    push ecx
    mov ecx, edx
    call h264_u
    mov edx, eax
    pop ecx
    pop eax
    add eax, edx
.nosuf:
    cmp ecx, 15
    jb .n15
    test esi, esi
    jnz .n16
    add eax, 15
.n16:
    cmp ecx, 16
    jb .n15
    push ecx
    sub ecx, 3
    mov edx, 1
    shl edx, cl
    pop ecx
    lea eax, [eax + edx - 4096]
.n15:
    cmp edi, ebp                    ; the first level after fewer than 3
    jne .not1                       ; trailing ones is never +-1
    cmp ebp, 3
    jae .not1
    add eax, 2
.not1:
    test al, 1
    jnz .odd
    add eax, 2                      ; even: (levelCode + 2) >> 1
    sar eax, 1
    jmp .lv
.odd:
    not eax                         ; odd: (-levelCode - 1) >> 1
    sar eax, 1
.lv:
    mov [h264_lev + edi * 4], eax
    inc edi
    test esi, esi
    jnz .sl1
    mov esi, 1
.sl1:
    mov edx, eax                    ; |level| > (3 << (suffixLength - 1))
    sar edx, 31                     ; and suffixLength < 6: one more
    xor eax, edx
    sub eax, edx
    lea ecx, [esi - 1]
    mov edx, 3
    shl edx, cl
    cmp eax, edx
    jbe .levels
    cmp esi, 6
    jae .levels
    inc esi
    jmp .levels
.levdone:
    ; total_zeros (9.2.3)
    xor ebp, ebp                    ; EBP = zerosLeft
    cmp ebx, [h264_rb_max]
    jae .tzd
    cmp dword [h264_rb_max], 4
    jne .tz16
    mov esi, [h264_tzc_tab + ebx * 4]
    jmp .tzv
.tz16:
    mov esi, [h264_tz_tab + ebx * 4]
.tzv:
    call h264_vlc
    test eax, eax
    js .bad
    mov ebp, eax
    add eax, ebx
    cmp eax, [h264_rb_max]
    ja .bad
.tzd:
    ; place the levels from the highest frequency down, with run_before
    lea esi, [ebx + ebp - 1]        ; ESI = scan index of level 0
    xor edi, edi
.place:
    mov edx, [h264_rb_scan]
    movzx edx, byte [edx + esi]     ; raster position
    mov eax, [h264_lev + edi * 4]
    mov ecx, [h264_rb_dq]
    test ecx, ecx
    jz .nodq
    imul eax, [ecx + edx * 4]
.nodq:
    mov ecx, [h264_rb_out]
    mov [ecx + edx * 2], ax
    inc edi
    cmp edi, ebx
    jae .placed
    test ebp, ebp
    jz .norun
    push esi
    mov esi, [h264_rb_tab + ebp * 4]
    call h264_vlc
    pop esi
    test eax, eax
    js .bad
    cmp eax, ebp
    ja .bad
    sub ebp, eax
    sub esi, eax
.norun:
    dec esi
    jmp .place
.placed:
    mov eax, ebx
    jmp .out
.zero:
    xor eax, eax
    jmp .out
.bad:
    or eax, -1
.out:
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

; h264_vlc: ESI = a code table from h264_tab.inc -> EAX = the decoded value
; (the code consumed), or -1 (invalid code; h264_berr set). EBX ESI EDI EBP
; kept.
h264_vlc:
    push ebx
    call h264_peek
    movzx ebx, byte [esi]           ; LZMAX
    bsr ecx, eax
    jz .z32
    xor ecx, 31                     ; leading zeros
    cmp ecx, ebx
    ja .over
.lz:
    lea edx, [ecx + 1]
    xchg ecx, edx                   ; ECX = lz + 1, EDX = lz
    shl eax, cl                     ; the bits after the first one bit
    movzx ecx, byte [esi + 1]       ; S
    shl edx, cl
    test ecx, ecx
    jz .nos
    neg ecx
    add ecx, 32
    shr eax, cl
    or edx, eax
.nos:
    movzx eax, word [esi + 4 + edx * 2]
    test al, al
    jz .bad
    movzx ecx, al
    add [h264_bp], ecx
    shr eax, 8
    pop ebx
    ret
.z32:
    mov ecx, 32
.over:
    cmp byte [esi + 2], 0           ; more zeros than the all-zero code:
    je .bad                         ; still that code
    mov ecx, ebx
    jmp .lz
.bad:
    mov dword [h264_berr], 1
    or eax, -1
    pop ebx
    ret

; h264_luma_dc: Intra16x16: inverse Hadamard transform and scaling of the
; DC levels (8.5.10); each result becomes the DC of its 4x4 block
h264_luma_dc:
    push ebx
    push esi
    push edi
    push ebp
    mov esi, h264_dc
    ; anything there?
    mov eax, [esi]
    or eax, [esi + 4]
    or eax, [esi + 8]
    or eax, [esi + 12]
    or eax, [esi + 16]
    or eax, [esi + 20]
    or eax, [esi + 24]
    or eax, [esi + 28]
    jz .out
    ; rows
    mov edi, h264_tmpi              ; 16 dwords
    xor ebx, ebx
.r: movsx eax, word [esi + ebx * 8]
    movsx ecx, word [esi + ebx * 8 + 2]
    movsx edx, word [esi + ebx * 8 + 4]
    movsx ebp, word [esi + ebx * 8 + 6]
    call h264_hadamard4
    push ebx
    shl ebx, 4
    mov [edi + ebx], eax
    mov [edi + ebx + 4], ecx
    mov [edi + ebx + 8], edx
    mov [edi + ebx + 12], ebp
    pop ebx
    inc ebx
    cmp ebx, 4
    jb .r
    ; columns, then scale: (f * LevelScale(qP % 6, 0, 0)) << (qP / 6) >> 6
    ; with rounding when qP < 36
    mov eax, [h264_qp]
    xor edx, edx
    mov ecx, 6
    div ecx
    mov eax, [h264_ls0 + edx * 4]
    mov [h264_tmpi + 64], eax       ; scale
    mov [h264_tmpi + 68], ecx       ; (spare)
    mov ecx, eax
    xor ebx, ebx
.c: push ebx
    mov eax, [edi + ebx * 4]
    mov ecx, [edi + ebx * 4 + 16]
    mov edx, [edi + ebx * 4 + 32]
    mov ebp, [edi + ebx * 4 + 48]
    call h264_hadamard4
    mov [edi + ebx * 4], eax
    mov [edi + ebx * 4 + 16], ecx
    mov [edi + ebx * 4 + 32], edx
    mov [edi + ebx * 4 + 48], ebp
    pop ebx
    inc ebx
    cmp ebx, 4
    jb .c
    ; scale into the blocks
    mov eax, [h264_qp]
    xor edx, edx
    mov ecx, 6
    div ecx
    mov ecx, eax                    ; ECX = qP / 6
    xor ebx, ebx
.s: mov eax, [edi + ebx * 4]
    imul eax, [h264_tmpi + 64]
    cmp ecx, 6
    jb .round
    sub ecx, 6
    shl eax, cl
    add ecx, 6
    jmp .put
.round:
    push ecx
    neg ecx
    add ecx, 5
    mov edx, 1
    shl edx, cl                     ; 2^(5 - qP / 6)
    add eax, edx
    inc ecx
    sar eax, cl                     ; >> (6 - qP / 6)
    pop ecx
.put:
    mov edx, ebx
    shl edx, 5
    mov [h264_coef + edx], ax
    test ax, ax
    jz .z
    bts dword [h264_cmask], ebx
.z: inc ebx
    cmp ebx, 16
    jb .s
    xor eax, eax                    ; the DC levels are used up
    mov edi, h264_dc
    mov ecx, 8
    rep stosd
.out:
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

; h264_hadamard4: EAX, ECX, EDX, EBP = a, b, c, d -> the 4-point Hadamard
; transform: a+b+c+d, a+b-c-d, a-b-c+d, a-b+c-d. EBX ESI EDI kept.
h264_hadamard4:
    push esi
    push edi
    lea esi, [eax + ecx]            ; a + b
    sub eax, ecx                    ; a - b
    lea edi, [edx + ebp]            ; c + d
    sub edx, ebp                    ; c - d
    lea ecx, [esi]
    sub ecx, edi                    ; (a+b) - (c+d)
    add esi, edi                    ; (a+b) + (c+d)
    lea ebp, [eax + edx]            ; (a-b) + (c-d)
    sub eax, edx                    ; (a-b) - (c-d)
    mov edx, eax
    mov eax, esi
    pop edi
    pop esi
    ret

; h264_chroma_dc: the 2x2 transform and scaling of the chroma DC levels
; (8.5.11): dcC = ((f * LevelScale(QPc % 6, 0, 0)) << (QPc / 6)) >> 5
h264_chroma_dc:
    push ebx
    push esi
    push edi
    xor ebx, ebx                    ; 0 = Cb, 1 = Cr
.comp:
    lea esi, [h264_cdc + ebx * 8]
    mov eax, [esi]
    or eax, [esi + 4]
    jz .next
    movsx eax, word [esi]
    movsx ecx, word [esi + 2]
    movsx edx, word [esi + 4]
    movsx edi, word [esi + 6]
    mov dword [esi], 0
    mov dword [esi + 4], 0
    push eax
    push ecx                        ; f00 = a+b+c+d, f01 = a-b+c-d,
    push edx                        ; f10 = a+b-c-d, f11 = a-b-c+d
    push edi
    mov eax, [esp + 12]
    add eax, [esp + 8]
    add eax, [esp + 4]
    add eax, [esp]
    mov [h264_tmpi], eax
    mov eax, [esp + 12]
    sub eax, [esp + 8]
    add eax, [esp + 4]
    sub eax, [esp]
    mov [h264_tmpi + 4], eax
    mov eax, [esp + 12]
    add eax, [esp + 8]
    sub eax, [esp + 4]
    sub eax, [esp]
    mov [h264_tmpi + 8], eax
    mov eax, [esp + 12]
    sub eax, [esp + 8]
    sub eax, [esp + 4]
    add eax, [esp]
    mov [h264_tmpi + 12], eax
    add esp, 16
    mov eax, [h264_qpcb]
    test ebx, ebx
    jz .q
    mov eax, [h264_qpc2]
.q: xor edx, edx
    mov ecx, 6
    div ecx
    mov ecx, eax                    ; ECX = QPc / 6
    mov edi, [h264_ls0 + edx * 4]   ; EDI = scale
    xor esi, esi
.blk:
    mov eax, [h264_tmpi + esi * 4]
    imul eax, edi
    shl eax, cl
    sar eax, 5
    lea edx, [ebx * 4 + esi]        ; block
    push edx
    shl edx, 5
    mov [h264_ccoef + edx], ax
    pop edx
    test ax, ax
    jz .bz
    add edx, 16
    bts dword [h264_cmask], edx
.bz:
    inc esi
    cmp esi, 4
    jb .blk
.next:
    inc ebx
    cmp ebx, 2
    jb .comp
    pop edi
    pop esi
    pop ebx
    ret

; =============================================================================
;  Reconstruction
; =============================================================================

; h264_rec_i4: Intra_4x4: each block predicted then its residual added
h264_rec_i4:
    push ebp
    xor ebp, ebp                    ; block, decoding order
.blk:
    movzx ebx, byte [h264_blk_r + ebp]
    mov eax, ebx
    and eax, 3                      ; x
    mov edx, ebx
    shr edx, 2                      ; y
    ; availability: bit 0 left, 1 top, 2 top-right, 3 top-left
    xor ecx, ecx
    mov esi, [h264_iav]
    test eax, eax
    jnz .l1
    test esi, 1
    jz .l0
.l1:
    or ecx, 1
.l0:
    test edx, edx
    jnz .t1
    test esi, 2
    jz .t0
.t1:
    or ecx, 2
.t0:
    ; top-left
    test eax, eax
    jz .tl0
    test edx, edx
    jnz .tl1
    test esi, 2                     ; x > 0, y = 0: macroblock B
    jz .tl
    jmp .tl1
.tl0:
    test edx, edx
    jz .tld
    test esi, 1                     ; x = 0, y > 0: macroblock A
    jz .tl
    jmp .tl1
.tld:
    test esi, 8                     ; x = 0, y = 0: macroblock D
    jz .tl
.tl1:
    or ecx, 8
.tl:
    ; top-right
    movzx edi, byte [h264_tr_tab + ebp]
    cmp edi, 1
    je .tr1
    jb .tr
    cmp edi, 2
    jne .trc
    test esi, 2
    jz .tr
    jmp .tr1
.trc:
    test esi, 4
    jz .tr
.tr1:
    or ecx, 4
.tr:
    ; destination
    shl edx, 2
    imul edx, [h264_ystride]
    lea edi, [edx + eax * 4]
    add edi, [h264_dy]
    movzx eax, byte [h264_i4m + ebx]
    mov edx, [h264_ystride]
    push edi
    call h264_pred4x4
    pop edi
    bt dword [h264_cmask], ebx
    jnc .next
    mov esi, ebx
    shl esi, 5
    add esi, h264_coef
    mov edx, [h264_ystride]
    call h264_idct_add
.next:
    inc ebp
    cmp ebp, 16
    jb .blk
    pop ebp
    ret

; h264_rec_i16: Intra_16x16 prediction, then the residual of each block
h264_rec_i16:
    mov edi, [h264_dy]
    mov edx, [h264_ystride]
    mov eax, [h264_i16m]
    mov ecx, [h264_iav]
    call h264_pred16x16
    jmp h264_rec_luma_res

; h264_rec_residual: an inter macroblock's residual (luma and chroma)
h264_rec_residual:
    call h264_rec_luma_res
    jmp h264_rec_chroma_res

; h264_rec_luma_res: inverse transform + add of the luma blocks with
; coefficients
h264_rec_luma_res:
    push ebp
    xor ebp, ebp
.l: bt dword [h264_cmask], ebp
    jnc .n
    mov eax, ebp
    and eax, 3
    mov edi, ebp
    shr edi, 2
    shl edi, 2
    imul edi, [h264_ystride]
    lea edi, [edi + eax * 4]
    add edi, [h264_dy]
    mov esi, ebp
    shl esi, 5
    add esi, h264_coef
    mov edx, [h264_ystride]
    call h264_idct_add
.n: inc ebp
    cmp ebp, 16
    jb .l
    pop ebp
    ret

; h264_rec_chroma_intra: chroma intra prediction of both planes, then their
; residual
h264_rec_chroma_intra:
    mov edi, [h264_du]
    mov edx, [h264_cstride]
    mov eax, [h264_cpm]
    mov ecx, [h264_iav]
    call h264_predchroma
    mov edi, [h264_dv]
    mov edx, [h264_cstride]
    mov eax, [h264_cpm]
    mov ecx, [h264_iav]
    call h264_predchroma
; h264_rec_chroma_res: inverse transform + add of the chroma blocks with
; coefficients
h264_rec_chroma_res:
    push ebp
    mov ebp, 16
.l: bt dword [h264_cmask], ebp
    jnc .n
    mov eax, ebp
    sub eax, 16
    mov esi, eax
    shl esi, 5
    add esi, h264_ccoef
    mov edi, [h264_du]
    cmp eax, 4
    jb .u
    mov edi, [h264_dv]
    sub eax, 4
.u: mov ecx, eax
    and ecx, 1
    shl ecx, 2
    add edi, ecx
    shr eax, 1
    shl eax, 2
    imul eax, [h264_cstride]
    add edi, eax
    mov edx, [h264_cstride]
    call h264_idct_add
.n: inc ebp
    cmp ebp, 24
    jb .l
    pop ebp
    ret

section .bss
alignb 4
h264_mc_refp    resd 1              ; motion compensation: reference frame
h264_mc_x       resd 1              ;   position (quarter / eighth samples)
h264_mc_y       resd 1
h264_mc_w       resd 1              ;   block size
h264_mc_h       resd 1
section .text
