; =============================================================================
;  h264_inter.inc - inter prediction (part of h264.asm)
;
;  P and B macroblocks. A macroblock is first described as a list of
;  partitions (position and size in 4x4 blocks, which lists they predict
;  from, reference indices, motion vector differences), whether its syntax
;  came from CAVLC (h264_mb_inter, below) or CABAC (h264_cabac.inc). Then
;  h264_inter_pred works the same for both:
;    - the neighbours' reference indices and motion vectors are gathered
;      into caches (h264_fill_motion; same layout as in h264_mb.inc: index
;      (y + 1) * 8 + (x + 1), list 1 40 entries after list 0);
;    - direct prediction (8.4.1.2) for B_Skip, B_Direct_16x16 and direct
;      8x8 sub-macroblocks, spatial or temporal (h264_direct);
;    - every other partition's motion vector = prediction (8.4.1.3,
;      h264_mvpred) + difference, in decoding order so that later
;      partitions see the earlier ones;
;    - motion compensated prediction (8.4.2) of every partition: straight
;      into the frame for one list without weights, otherwise into
;      h264_pb0 / h264_pb1 first and then averaged or weighted (8.4.2.3:
;      explicit weights from the slice header, implicit ones from the
;      picture order counts) into the frame;
;    - the motion data is stored for the neighbours, the deblocking filter
;      and as the co-located data of later B pictures.
; =============================================================================

section .bss
alignb 16
h264_pb0        resb PB_SZ          ; prediction from list 0: luma 16 x 16
h264_pb1        resb PB_SZ          ;   (stride 16), Cb, Cr (8 rows of 16);
                                    ;   from list 1
h264_refc       resb 80             ; reference index caches, lists 0, 1
alignb 4
h264_mvc        resd 80             ; motion vector caches (x low, y high)
h264_dmv0       resd 16             ; direct prediction: vectors of the 4x4
h264_dmv1       resd 16             ;   blocks (raster), lists 0 and 1
h264_dref0      resb 4              ;   and reference indices per 8x8
h264_dref1      resb 4              ;   (-1: list not used)
; partitions of an inter macroblock (entry 16: scratch for direct blocks)
h264_np         resd 1
h264_px         resb 20             ; position and size in 4x4 blocks
h264_py         resb 20
h264_pw         resb 20
h264_ph         resb 20
h264_pshape     resb 20             ; 1/2: 16x8 top/bottom, 3/4: 8x16
h264_ppred      resb 20             ; PP_* bits
h264_pgrp       resb 20             ; group: the 8x8 sub-macroblock, or the
                                    ;   partition itself
h264_pref       resb 20             ; ref_idx_l0 / ref_idx_l1
h264_pref1      resb 20
h264_sub        resb 4              ; sub-macroblock descriptors (SUB_*)
alignb 4
h264_pmvd       resd 20             ; mvd_l0 / mvd_l1 (x low, y high word)
h264_pmvd1      resd 20
h264_mbdesc     resd 1              ; descriptor of the macroblock type
h264_ref0only   resd 1              ; 1 = P_8x8ref0 (no ref_idx_l0)
h264_pp_x       resd 1              ; motion vector prediction arguments
h264_pp_y       resd 1
h264_pp_w       resd 1
h264_pp_ref     resd 1
h264_pp_shape   resd 1
h264_pp_lo      resd 1              ; 40 * list (cache offset)
h264_fm_row     resd 1              ; motion data of a macroblock row
; motion compensation
h264_mc_refp    resd 1              ; reference frame (slot record)
h264_mc_x       resd 1              ; position (quarter / eighth samples)
h264_mc_y       resd 1
h264_mc_w       resd 1              ; block size
h264_mc_h       resd 1
h264_mc_ds      resd 1              ; destination strides: luma, chroma
h264_mc_dsc     resd 1
h264_mc_dy      resd 1              ; destination of the macroblock: luma,
h264_mc_du      resd 1              ;   Cb, Cr
h264_mc_dv      resd 1
h264_mc_lst     resd 1              ; list
h264_mc_part    resd 1              ; partition
; weighted sample prediction of one plane (h264_wpred)
h264_cw_mode    resd 1              ; 0 average, 1 one list weighted, 2 two
h264_cw_w0      resd 1              ; weights, offset, log2 denominator
h264_cw_w1      resd 1
h264_cw_o       resd 1
h264_cw_log     resd 1
h264_cw_ds      resd 1              ; destination stride
h264_cw_w       resd 1              ; block size
h264_cw_h       resd 1
; per slice: temporal direct and implicit weights
h264_colmo      resd 1              ; co-located picture: motion data
h264_col_short  resd 1              ; RefPicList1[0] is a short-term ref.
h264_dsf        resd 16             ; DistScaleFactor per list 0 index
h264_dsfm       resb 16             ; 1 = use mvCol as it is (long-term /
                                    ;   same picture order count)
alignb 4
h264_impw       resd 16 * 16        ; implicit weight w1 per (ref0, ref1)
h264_wtmp       resd 8              ; scratch of h264_mc_part1

section .data
; macroblock types (P 0..4, B 1..22): kind | pred0 << 4 | pred1 << 6;
; kind 0 16x16, 1 16x8, 2 8x16, 3 8x8; pred 1 L0, 2 L1, 3 bi-predicted
h264_ptype      db 0x10, 0x51, 0x52, 0x03, 0x03
h264_btype      db 0x00, 0x10, 0x20, 0x30
                db 0x51, 0x52, 0xA1, 0xA2, 0x91, 0x92, 0x61, 0x62
                db 0xD1, 0xD2, 0xE1, 0xE2, 0x71, 0x72, 0xB1, 0xB2
                db 0xF1, 0xF2, 0x03
; sub-macroblock types: split (0 8x8, 1 8x4, 2 4x8, 3 4x4) | pred << 4
; (pred 0: direct)
h264_psubt      db 0x10, 0x11, 0x12, 0x13
h264_bsubt      db 0x00, 0x10, 0x20, 0x30, 0x11, 0x12, 0x21, 0x22
                db 0x31, 0x32, 0x13, 0x23, 0x33
; 4x4 block (raster) -> the corner block used with direct_8x8_inference
h264_corner     db 0, 0, 3, 3, 0, 0, 3, 3, 12, 12, 15, 15, 12, 12, 15, 15

section .text

PB_SZ           equ 16 * 16 + 2 * 16 * 8
PB_U            equ 256             ; Cb, Cr in h264_pb0 / h264_pb1
PB_V            equ 384
; h264_ppred bits
PP_L0           equ 1
PP_L1           equ 2
PP_DIRECT       equ 4

; =============================================================================
;  Neighbour caches
; =============================================================================

; h264_fill_motion: the reference index and motion vector caches from the
; neighbours A, B, C, D (list 0; list 1 too in B slices). Everything else
; (the macroblock itself, C to the right of the top row) is "not
; available" (REF_NA).
h264_fill_motion:
    push esi
    push edi
    push ebp
    mov edi, h264_refc
    mov eax, 0xFEFEFEFE             ; REF_NA everywhere
    mov ecx, 80 / 4
    rep stosd
    mov edi, h264_mvc
    xor eax, eax
    mov ecx, 80
    rep stosd
    mov eax, [h264_mbw]
    imul eax, MO_SZ
    mov [h264_fm_row], eax          ; a row of motion data
    xor ebp, ebp                    ; EBP = list
.list:
    mov edx, [h264_mop]
    lea edx, [edx + ebp * 4]        ; EDX: [edx + MO_REF0] = this list's refs
    mov esi, ebp
    shl esi, 6
    add esi, [h264_mop]             ; ESI: [esi + MO_MV0] = its vectors
    imul edi, ebp, 40               ; EDI = cache offset
    cmp dword [h264_avA], 0
    je .noA
    mov al, [edx - MO_SZ + MO_REF0 + 1] ; left: its right column
    mov [h264_refc + edi + 8], al
    mov [h264_refc + edi + 16], al
    mov al, [edx - MO_SZ + MO_REF0 + 3]
    mov [h264_refc + edi + 24], al
    mov [h264_refc + edi + 32], al
    mov eax, [esi - MO_SZ + MO_MV0 + 3 * 4]
    mov [h264_mvc + edi * 4 + 8 * 4], eax
    mov eax, [esi - MO_SZ + MO_MV0 + 7 * 4]
    mov [h264_mvc + edi * 4 + 16 * 4], eax
    mov eax, [esi - MO_SZ + MO_MV0 + 11 * 4]
    mov [h264_mvc + edi * 4 + 24 * 4], eax
    mov eax, [esi - MO_SZ + MO_MV0 + 15 * 4]
    mov [h264_mvc + edi * 4 + 32 * 4], eax
.noA:
    mov ecx, [h264_fm_row]
    sub edx, ecx                    ; the macroblock above
    sub esi, ecx
    cmp dword [h264_avB], 0
    je .noB
    mov al, [edx + MO_REF0 + 2]     ; above: its bottom row
    mov [h264_refc + edi + 1], al
    mov [h264_refc + edi + 2], al
    mov al, [edx + MO_REF0 + 3]
    mov [h264_refc + edi + 3], al
    mov [h264_refc + edi + 4], al
    mov eax, [esi + MO_MV0 + 12 * 4]
    mov [h264_mvc + edi * 4 + 1 * 4], eax
    mov eax, [esi + MO_MV0 + 13 * 4]
    mov [h264_mvc + edi * 4 + 2 * 4], eax
    mov eax, [esi + MO_MV0 + 14 * 4]
    mov [h264_mvc + edi * 4 + 3 * 4], eax
    mov eax, [esi + MO_MV0 + 15 * 4]
    mov [h264_mvc + edi * 4 + 4 * 4], eax
.noB:
    cmp dword [h264_avC], 0
    je .noC
    mov al, [edx + MO_SZ + MO_REF0 + 2] ; above right: its bottom-left block
    mov [h264_refc + edi + 5], al
    mov eax, [esi + MO_SZ + MO_MV0 + 12 * 4]
    mov [h264_mvc + edi * 4 + 5 * 4], eax
.noC:
    cmp dword [h264_avD], 0
    je .noD
    mov al, [edx - MO_SZ + MO_REF0 + 3] ; above left: its bottom-right block
    mov [h264_refc + edi + 0], al
    mov eax, [esi - MO_SZ + MO_MV0 + 15 * 4]
    mov [h264_mvc + edi * 4 + 0], eax
.noD:
    cmp dword [h264_sh_type], ST_B
    jne .done
    inc ebp
    cmp ebp, 2
    jb .list
.done:
    pop ebp
    pop edi
    pop esi
    ret

; =============================================================================
;  Motion vector prediction (8.4.1.3)
; =============================================================================

; h264_mvpred: the partition at h264_pp_x, _y (4x4 blocks), h264_pp_w
; wide, reference h264_pp_ref, shape h264_pp_shape, list h264_pp_lo / 40
; -> EAX = the predicted motion vector (x low word, y high word). EBX ESI
; EDI kept.
h264_mvpred:
    push ebx
    push esi
    push edi
    push ebp
    mov eax, [h264_pp_y]
    shl eax, 3
    add eax, [h264_pp_x]            ; EAX = (y)*8 + x = index of D
    add eax, [h264_pp_lo]           ;   (in the list's cache)
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
;  Skipped macroblocks
; =============================================================================

; h264_mb_skip: a P_Skip macroblock (8.4.1.1): 16x16, reference 0, the
; predicted motion vector unless a neighbour suggests no motion; or a
; B_Skip macroblock (direct prediction). No residual.
h264_mb_skip:
    mov dword [h264_mbt], MT_SKIP
    xor eax, eax
    mov [h264_cbp], eax
    mov [h264_cmask], eax
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
    cmp dword [h264_sh_type], ST_B
    jne .p
    mov dword [h264_mbt], MT_SKIP | MT_DIRECT
    jmp h264_inter_pred
.p: call h264_fill_motion
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
    mov [h264_pp_lo], eax
    mov dword [h264_pp_w], 4
    call h264_mvpred
.mv:
    mov dword [h264_np], 1
    xor ecx, ecx
    mov [h264_px], cl
    mov [h264_py], cl
    mov [h264_pref], cl
    mov byte [h264_pref1], -1
    mov byte [h264_pw], 4
    mov byte [h264_ph], 4
    mov byte [h264_ppred], PP_L0
    xor ebx, ebx
    mov ecx, eax                    ; ECX = vector, DL = reference
    xor edx, edx
    xor eax, eax                    ; list 0
    call h264_set_area
    xor ebx, ebx
    call h264_mc_part1
    jmp h264_store_motion

; =============================================================================
;  CAVLC syntax of inter macroblocks
; =============================================================================

; h264_mb_inter: EAX = mb_type of an inter macroblock (P 0..4, B 0..22):
; its prediction syntax (7.3.5.1, 7.3.5.2), the prediction itself, then
; coded_block_pattern, mb_qp_delta and the residual. EAX = 0 / -1.
; Any register may change except EBP.
h264_mb_inter:
    push ebp
    mov dword [h264_mbt], 0
    mov dword [h264_ref0only], 0
    cmp dword [h264_sh_type], ST_B
    je .b
    cmp eax, 4
    jne .p
    mov dword [h264_ref0only], 1    ; P_8x8ref0
.p: movzx eax, byte [h264_ptype + eax]
    jmp .desc
.b: test eax, eax
    jnz .b1
    mov dword [h264_mbt], MT_DIRECT ; B_Direct_16x16
    call h264_inter_pred
    jmp .residual
.b1:
    movzx eax, byte [h264_btype + eax]
.desc:
    mov [h264_mbdesc], eax
    and eax, 3
    cmp eax, 3
    jne .layout
    ; sub_mb_type[4]
    xor ebx, ebx
.sub:
    call h264_ue
    cmp dword [h264_sh_type], ST_B
    je .subb
    cmp eax, 3
    ja .bad
    mov al, [h264_psubt + eax]
    jmp .subs
.subb:
    cmp eax, 12
    ja .bad
    mov al, [h264_bsubt + eax]
.subs:
    mov [h264_sub + ebx], al
    inc ebx
    cmp ebx, 4
    jb .sub
.layout:
    call h264_mb_partitions
    ; ref_idx_l0, ref_idx_l1 (one per group: 8x8 sub-macroblock / partition)
    xor ebp, ebp                    ; EBP = list
.rl:
    xor ebx, ebx
.r1:
    mov al, -1
    movzx edx, byte [h264_ppred + ebx]
    test edx, PP_DIRECT
    jnz .rput
    lea ecx, [ebp + 1]
    test edx, ecx                   ; this list used?
    jz .rput
    test ebx, ebx
    jz .rread
    mov al, [h264_pgrp + ebx]
    cmp al, [h264_pgrp + ebx - 1]
    jne .rread
    mov al, [h264_pref + ebx - 1]   ; same group: same reference
    test ebp, ebp
    jz .rput
    mov al, [h264_pref1 + ebx - 1]
    jmp .rput
.rread:
    xor eax, eax
    cmp dword [h264_ref0only], 0
    jne .rput
    mov ecx, [h264_sh_nref0]
    test ebp, ebp
    jz .rr
    mov ecx, [h264_sh_nref1]
.rr:
    call h264_ref_idx
    js .bad
.rput:
    test ebp, ebp
    jnz .rp1
    mov [h264_pref + ebx], al
    jmp .rn
.rp1:
    mov [h264_pref1 + ebx], al
.rn:
    inc ebx
    cmp ebx, [h264_np]
    jb .r1
    cmp dword [h264_sh_type], ST_B
    jne .rd
    inc ebp
    cmp ebp, 2
    jb .rl
.rd:
    ; mvd_l0, mvd_l1
    xor ebp, ebp
.ml:
    xor ebx, ebx
.m1:
    xor eax, eax
    movzx edx, byte [h264_ppred + ebx]
    test edx, PP_DIRECT
    jnz .mput
    lea ecx, [ebp + 1]
    test edx, ecx
    jz .mput
    call h264_read_mvd
.mput:
    test ebp, ebp
    jnz .mp1
    mov [h264_pmvd + ebx * 4], eax
    jmp .mn
.mp1:
    mov [h264_pmvd1 + ebx * 4], eax
.mn:
    inc ebx
    cmp ebx, [h264_np]
    jb .m1
    cmp dword [h264_sh_type], ST_B
    jne .md
    inc ebp
    cmp ebp, 2
    jb .ml
.md:
    call h264_bad_pos
    jnz .bad
    call h264_inter_pred
.residual:
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

; h264_ref_idx: ECX = num_ref_idx_lX_active -> EAX = ref_idx_lX (te(v),
; 7.4.5.1), SF = 1 (js taken) if out of range
h264_ref_idx:
    cmp ecx, 1
    jbe .zero
    cmp ecx, 2
    je .bit
    push ecx
    call h264_ue
    pop ecx
    cmp eax, ecx
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

; h264_read_mvd: EAX = mvd_lX (x low word, y high word)
h264_read_mvd:
    call h264_se
    push eax
    call h264_se
    shl eax, 16
    pop ecx
    mov ax, cx
    ret

; h264_mb_partitions: h264_mbdesc (and h264_sub for 8x8) -> the partition
; list h264_np, h264_px ... h264_pgrp (references not set yet)
h264_mb_partitions:
    push ebx
    push esi
    push edi
    mov eax, [h264_mbdesc]
    mov edx, eax
    shr edx, 4
    and edx, 3                      ; EDX = prediction of partition 0
    mov ecx, eax
    shr ecx, 6                      ;   ECX = of partition 1
    and eax, 3
    xor edi, edi
    mov dword [h264_px], 0          ; (first four entries)
    mov dword [h264_py], 0
    mov dword [h264_pshape], 0
    mov dword [h264_pgrp], 0x03020100
    mov [h264_ppred], dl
    mov [h264_ppred + 1], cl
    cmp eax, 3
    je .p8x8
    mov dword [h264_np], 1
    mov byte [h264_pw], 4
    mov byte [h264_ph], 4
    test eax, eax
    jz .out
    mov dword [h264_np], 2
    cmp eax, 1
    jne .v
    mov byte [h264_ph], 2           ; 16x8
    mov byte [h264_ph + 1], 2
    mov byte [h264_pw + 1], 4
    mov byte [h264_py + 1], 2
    mov byte [h264_pshape], 1
    mov byte [h264_pshape + 1], 2
    jmp .out
.v: mov byte [h264_pw], 2           ; 8x16
    mov byte [h264_pw + 1], 2
    mov byte [h264_ph + 1], 4
    mov byte [h264_px + 1], 2
    mov byte [h264_pshape], 3
    mov byte [h264_pshape + 1], 4
    jmp .out
.p8x8:
    xor ebx, ebx                    ; EBX = 8x8 block
.s4:
    mov ecx, ebx                    ; its position in 4x4 blocks
    and ecx, 1
    shl ecx, 1
    mov edx, ebx
    shr edx, 1
    shl edx, 1
    movzx esi, byte [h264_sub + ebx]
    mov eax, esi
    shr eax, 4                      ; prediction (0: direct)
    jnz .s4p
    mov eax, PP_DIRECT
.s4p:
    and esi, 3                      ; split
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
.out:
    pop edi
    pop esi
    pop ebx
    ret
; add a partition: ECX = x, EDX = y, AL = prediction, EBX = group -> EDI
; + 1 (size 1x1 4x4)
.add:
    mov [h264_px + edi], cl
    mov [h264_py + edi], dl
    mov [h264_ppred + edi], al
    mov [h264_pgrp + edi], bl
    mov byte [h264_pw + edi], 1
    mov byte [h264_ph + edi], 1
    mov byte [h264_pshape + edi], 0
    inc edi
    ret

; =============================================================================
;  Prediction of an inter macroblock
; =============================================================================

; h264_inter_pred: the partitions described (or MT_DIRECT in h264_mbt for
; B_Skip / B_Direct_16x16): motion vectors, motion compensation, motion
; data stored. Any register may change except EBP.
h264_inter_pred:
    push ebp
    call h264_fill_motion
    cmp dword [h264_sh_type], ST_B
    jne .nodirect
    test dword [h264_mbt], MT_DIRECT
    jnz .direct
    ; direct 8x8 sub-macroblocks?
    xor ebx, ebx
.fd:
    test byte [h264_ppred + ebx], PP_DIRECT
    jnz .direct
    inc ebx
    cmp ebx, [h264_np]
    jb .fd
    jmp .nodirect
.direct:
    call h264_direct
    test dword [h264_mbt], MT_DIRECT
    jz .nodirect
    call h264_direct_parts
.nodirect:
    ; motion vectors of the partitions, in order
    xor ebx, ebx
.pp:
    test byte [h264_ppred + ebx], PP_DIRECT
    jz .pv
    call h264_direct_copy
    jmp .pn
.pv:
    xor ebp, ebp                    ; EBP = list
.pl:
    lea eax, [ebp + 1]
    test [h264_ppred + ebx], al
    jz .unused
    movzx eax, byte [h264_px + ebx]
    mov [h264_pp_x], eax
    movzx eax, byte [h264_py + ebx]
    mov [h264_pp_y], eax
    movzx eax, byte [h264_pw + ebx]
    mov [h264_pp_w], eax
    movsx eax, byte [h264_pref + ebx]
    mov edx, h264_pmvd
    test ebp, ebp
    jz .pl0
    movsx eax, byte [h264_pref1 + ebx]
    mov edx, h264_pmvd1
.pl0:
    mov [h264_pp_ref], eax
    movzx eax, byte [h264_pshape + ebx]
    mov [h264_pp_shape], eax
    imul eax, ebp, 40
    mov [h264_pp_lo], eax
    mov edx, [edx + ebx * 4]        ; mvd
    push edx
    call h264_mvpred
    pop edx
    mov ecx, eax                    ; + mvd (each component wraps at 16 bits)
    add cx, dx
    shr eax, 16
    shr edx, 16
    add ax, dx
    shl eax, 16
    mov ax, cx
    mov ecx, eax                    ; ECX = vector
    mov dl, [h264_pref + ebx]
    test ebp, ebp
    jz .set
    mov dl, [h264_pref1 + ebx]
    jmp .set
.unused:
    xor ecx, ecx                    ; this list not used: reference -1
    mov dl, -1
.set:
    mov eax, ebp
    call h264_set_area
    cmp dword [h264_sh_type], ST_B
    jne .pn
    inc ebp
    cmp ebp, 2
    jb .pl
.pn:
    inc ebx
    cmp ebx, [h264_np]
    jb .pp
    ; motion compensation of every partition
    xor ebx, ebx
.mc:
    push ebx
    test byte [h264_ppred + ebx], PP_DIRECT
    jz .mc1
    call h264_mc_direct
    jmp .mc2
.mc1:
    call h264_mc_part1
.mc2:
    pop ebx
    inc ebx
    cmp ebx, [h264_np]
    jb .mc
    call h264_store_motion
    pop ebp
    ret

; h264_set_area: partition EBX gets, in list EAX, reference DL and vector
; ECX: written into the caches over its area. EBX ESI EDI EBP kept.
h264_set_area:
    push esi
    push edi
    push ebp
    imul ebp, eax, 40
    movzx esi, byte [h264_py + ebx]
    shl esi, 3
    movzx eax, byte [h264_px + ebx]
    add esi, eax
    lea esi, [esi + ebp + 9]        ; cache index of the top-left block
    movzx eax, byte [h264_ph + ebx]
    movzx edi, byte [h264_pw + ebx]
.row:
    push esi
    push edi
.col:
    mov [h264_refc + esi], dl
    mov [h264_mvc + esi * 4], ecx
    inc esi
    dec edi
    jnz .col
    pop edi
    pop esi
    add esi, 8
    dec eax
    jnz .row
    pop ebp
    pop edi
    pop esi
    ret

; h264_store_motion: the motion data of this inter macroblock (from the
; caches) into its frame's motion store: vectors, reference indices and the
; frame buffers they refer to (for the deblocking filter and direct
; prediction)
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
    mov al, 255
    movsx edx, byte [edi + MO_REF0 + ecx]
    test edx, edx
    js .rs1
    mov al, [h264_list0 + edx]
.rs1:
    mov [edi + MO_RS0 + ecx], al
    inc ecx
    cmp ecx, 4
    jb .rs
    mov dword [edi + MO_INTRA], 0
    cmp dword [h264_sh_type], ST_B
    je .l1
    mov dword [edi + MO_REF1], -1
    mov dword [edi + MO_RS1], -1
    pop edi
    pop esi
    ret
.l1:
    add edi, MO_MV1
    mov esi, h264_mvc + (40 + 9) * 4
    mov ecx, 4
.r1:
    movsd
    movsd
    movsd
    movsd
    add esi, 4 * 4
    loop .r1
    mov edi, [h264_mop]
    mov al, [h264_refc + 40 + 9]
    mov [edi + MO_REF1], al
    mov al, [h264_refc + 40 + 11]
    mov [edi + MO_REF1 + 1], al
    mov al, [h264_refc + 40 + 25]
    mov [edi + MO_REF1 + 2], al
    mov al, [h264_refc + 40 + 27]
    mov [edi + MO_REF1 + 3], al
    xor ecx, ecx
.rs2:
    mov al, 255
    movsx edx, byte [edi + MO_REF1 + ecx]
    test edx, edx
    js .rs3
    mov al, [h264_list1 + edx]
.rs3:
    mov [edi + MO_RS1 + ecx], al
    inc ecx
    cmp ecx, 4
    jb .rs2
    pop edi
    pop esi
    ret

; =============================================================================
;  Direct prediction (8.4.1.2)
; =============================================================================

; h264_direct: the direct prediction of the whole macroblock: reference
; indices h264_dref0 / 1 (per 8x8) and vectors h264_dmv0 / 1 (per 4x4).
; Needs the caches (h264_fill_motion). Any register may change except EBP.
h264_direct:
    push ebp
    ; the co-located macroblock (in RefPicList1[0])
    mov eax, [h264_mbaddr]
    imul eax, MO_SZ
    add eax, [h264_colmo]
    mov [h264_colmo_mb], eax
    cmp dword [h264_sh_dspat], 0
    je h264_direct_temporal
    ; ---- spatial (8.4.1.2.2): the reference indices from the neighbours
    xor ebp, ebp                    ; EBP = list
.sref:
    imul edi, ebp, 40
    movsx eax, byte [h264_refc + edi + 8]   ; A
    movsx ecx, byte [h264_refc + edi + 1]   ; B
    movsx edx, byte [h264_refc + edi + 5]   ; C
    cmp edx, REF_NA
    jne .sc
    movsx edx, byte [h264_refc + edi + 0]   ; (D)
.sc:
    call h264_minpos                ; MinPositive(B, C)
    xchg eax, ecx
    call h264_minpos                ; MinPositive(A, ...)
    mov [h264_wtmp + ebp * 4], eax
    inc ebp
    cmp ebp, 2
    jb .sref
    xor esi, esi                    ; ESI = directZeroPredictionFlag
    mov eax, [h264_wtmp]
    and eax, [h264_wtmp + 4]
    jns .refok
    xor eax, eax                    ; neither list: both 0, zero vectors
    mov [h264_wtmp], eax
    mov [h264_wtmp + 4], eax
    inc esi
.refok:
    ; the predicted vectors (as for a 16x16 partition)
    xor ebp, ebp
.smv:
    xor eax, eax
    test esi, esi
    jnz .smv1
    mov ecx, [h264_wtmp + ebp * 4]
    test ecx, ecx
    js .smv1
    mov [h264_pp_ref], ecx
    mov [h264_pp_x], eax
    mov [h264_pp_y], eax
    mov [h264_pp_shape], eax
    mov dword [h264_pp_w], 4
    imul eax, ebp, 40
    mov [h264_pp_lo], eax
    call h264_mvpred
.smv1:
    mov [h264_wtmp + 8 + ebp * 4], eax
    inc ebp
    cmp ebp, 2
    jb .smv
    ; per 4x4 block: zero where the co-located block hardly moves
    mov eax, [h264_wtmp]
    mov ecx, 0x01010101
    imul eax, ecx
    mov [h264_dref0], eax
    mov eax, [h264_wtmp + 4]
    imul eax, ecx
    mov [h264_dref1], eax
    xor ebx, ebx                    ; EBX = block (raster)
.sblk:
    xor ecx, ecx                    ; ECX = colZeroFlag
    test esi, esi
    jnz .snocz
    cmp dword [h264_col_short], 0
    je .snocz
    call h264_col_block             ; EAX = refIdxCol, EDX = mvCol
    test eax, eax
    jnz .snocz
    movsx eax, dx
    inc eax
    cmp eax, 2
    ja .snocz
    sar edx, 16
    inc edx
    cmp edx, 2
    ja .snocz
    inc ecx
.snocz:
    xor ebp, ebp
.slst:
    xor eax, eax
    test esi, esi
    jnz .sput
    mov edx, [h264_wtmp + ebp * 4]  ; refIdxLX
    test edx, edx
    js .sput
    jnz .smvp
    test ecx, ecx
    jnz .sput
.smvp:
    mov eax, [h264_wtmp + 8 + ebp * 4]
.sput:
    mov edx, h264_dmv0
    test ebp, ebp
    jz .sp0
    mov edx, h264_dmv1
.sp0:
    mov [edx + ebx * 4], eax
    inc ebp
    cmp ebp, 2
    jb .slst
    inc ebx
    cmp ebx, 16
    jb .sblk
    pop ebp
    ret

; ---- temporal (8.4.1.2.3) ----------------------------------------------------
h264_direct_temporal:
    xor ebx, ebx                    ; EBX = block (raster)
.blk:
    call h264_col_block             ; EAX = refIdxCol, EDX = mvCol, ECX =
    mov esi, edx                    ;   the frame it refers to
    ; refIdxL0: the lowest index of list 0 that refers to that frame
    xor edi, edi
    test eax, eax
    js .ref0
.find:
    movzx eax, byte [h264_list0 + edi]
    cmp eax, ecx
    je .ref0
    inc edi
    cmp edi, [h264_sh_nref0]
    jb .find
    xor edi, edi                    ; (not there: a damaged stream)
.ref0:
    mov eax, ebx                    ; 8x8 of the block
    shr eax, 3
    shl eax, 1
    mov edx, ebx
    and edx, 3
    shr edx, 1
    add eax, edx
    mov edx, edi
    mov [h264_dref0 + eax], dl
    mov byte [h264_dref1 + eax], 0
    ; the vectors: mvL0 = scaled mvCol, mvL1 = mvL0 - mvCol
    cmp byte [h264_dsfm + edi], 0
    je .scale
    mov [h264_dmv0 + ebx * 4], esi
    mov dword [h264_dmv1 + ebx * 4], 0
    jmp .next
.scale:
    mov ebp, [h264_dsf + edi * 4]
    movsx eax, si
    imul eax, ebp
    add eax, 128
    sar eax, 8                      ; mvL0 x
    movsx edx, si
    mov ecx, eax
    sub ecx, edx                    ; mvL1 x
    mov edi, esi
    sar edi, 16
    imul edi, ebp
    add edi, 128
    sar edi, 8                      ; mvL0 y
    mov edx, esi
    sar edx, 16
    neg edx
    add edx, edi                    ; mvL1 y
    shl edi, 16
    mov di, ax
    mov [h264_dmv0 + ebx * 4], edi
    shl edx, 16
    mov dx, cx
    mov [h264_dmv1 + ebx * 4], edx
.next:
    inc ebx
    cmp ebx, 16
    jb .blk
    pop ebp
    ret

; h264_minpos: EAX, ECX -> EAX = MinPositive(EAX, ECX): the smaller if both
; are >= 0, else the larger. EDX kept.
h264_minpos:
    test eax, eax
    js .max
    test ecx, ecx
    js .max
    cmp ecx, eax
    jge .r
    mov eax, ecx
.r: ret
.max:
    cmp ecx, eax
    jle .r
    mov eax, ecx
    ret

; h264_col_block: EBX = 4x4 block (raster) of the current macroblock ->
; the co-located block (8.4.1.2.1; its corner block with
; direct_8x8_inference_flag): EAX = refIdxCol (-1 intra), EDX = mvCol,
; ECX = the frame buffer it refers to (255: none). List 0 of the
; co-located block if it used it, else list 1.
h264_col_block:
    push esi
    mov esi, [h264_colmo_mb]
    mov eax, ebx
    mov ecx, [h264_asps]
    cmp byte [ecx + SPS_D8I], 0
    je .nc
    movzx eax, byte [h264_corner + ebx]
.nc:
    cmp dword [esi + MO_INTRA], 0
    jne .intra
    mov ecx, eax                    ; 8x8 of that block
    shr ecx, 3
    shl ecx, 1
    mov edx, eax
    and edx, 3
    shr edx, 1
    add ecx, edx
    mov edx, [esi + MO_MV0 + eax * 4]
    movsx eax, byte [esi + MO_REF0 + ecx]
    test eax, eax
    jns .l0
    push ecx
    movzx ecx, byte [h264_corner + ebx]
    mov edx, ebx
    mov ecx, [h264_asps]
    cmp byte [ecx + SPS_D8I], 0
    je .nc1
    movzx edx, byte [h264_corner + ebx]
.nc1:
    pop ecx
    mov edx, [esi + MO_MV1 + edx * 4]
    movsx eax, byte [esi + MO_REF1 + ecx]
    movzx ecx, byte [esi + MO_RS1 + ecx]
    test eax, eax
    js .intra
    pop esi
    ret
.l0:
    movzx ecx, byte [esi + MO_RS0 + ecx]
    pop esi
    ret
.intra:
    or eax, -1
    xor edx, edx
    mov ecx, 255
    pop esi
    ret

; h264_direct_parts: B_Skip / B_Direct_16x16: the partitions from the
; direct prediction: one 16x16 if all of it moves the same way, else four
; 8x8 (h264_mc_direct splits those further if needed)
h264_direct_parts:
    push ebx
    mov dword [h264_np], 1
    mov dword [h264_px], 0
    mov dword [h264_py], 0
    mov dword [h264_pshape], 0
    mov dword [h264_pgrp], 0x03020100
    mov byte [h264_ppred], PP_DIRECT
    mov byte [h264_pw], 4
    mov byte [h264_ph], 4
    ; all 16 vectors and the 4 references the same?
    mov eax, [h264_dref0]
    mov ecx, eax
    shl ecx, 8
    mov cl, al
    cmp eax, ecx
    jne .four
    mov eax, [h264_dref1]
    mov ecx, eax
    shl ecx, 8
    mov cl, al
    cmp eax, ecx
    jne .four
    mov eax, [h264_dmv0]
    mov edx, [h264_dmv1]
    xor ecx, ecx
.same:
    cmp [h264_dmv0 + ecx * 4], eax
    jne .four
    cmp [h264_dmv1 + ecx * 4], edx
    jne .four
    inc ecx
    cmp ecx, 16
    jb .same
    pop ebx
    ret
.four:
    mov dword [h264_np], 4
    mov dword [h264_px], 0x02000200
    mov dword [h264_py], 0x02020000
    mov dword [h264_pw], 0x02020202
    mov dword [h264_ph], 0x02020202
    mov dword [h264_ppred], PP_DIRECT * 0x01010101
    pop ebx
    ret

; h264_direct_copy: direct partition EBX: its references (and prediction
; flags) and the vectors of its blocks from the direct prediction into
; the caches. EBX ESI EDI EBP kept.
h264_direct_copy:
    push esi
    push edi
    push ebp
    movzx eax, byte [h264_px + ebx] ; the 8x8 of its top-left block
    shr eax, 1
    movzx ecx, byte [h264_py + ebx]
    shr ecx, 1
    lea eax, [eax + ecx * 2]
    mov cl, [h264_dref0 + eax]
    mov [h264_pref + ebx], cl
    mov ch, [h264_dref1 + eax]
    mov [h264_pref1 + ebx], ch
    mov al, PP_DIRECT
    test cl, cl
    js .f1
    or al, PP_L0
.f1:
    test ch, ch
    js .f2
    or al, PP_L1
.f2:
    mov [h264_ppred + ebx], al
    ; every block of the partition
    movzx edi, byte [h264_py + ebx]
    movzx esi, byte [h264_ph + ebx]
    add esi, edi                    ; ESI = end row
.row:
    movzx ebp, byte [h264_px + ebx]
.col:
    lea eax, [edi * 4 + ebp]        ; raster block
    mov ecx, eax                    ; its 8x8
    shr ecx, 3
    shl ecx, 1
    mov edx, ebp
    shr edx, 1
    add ecx, edx
    lea edx, [edi * 8 + ebp + 9]    ; cache index
    push ebx
    mov bl, [h264_dref0 + ecx]
    mov [h264_refc + edx], bl
    mov bl, [h264_dref1 + ecx]
    mov [h264_refc + 40 + edx], bl
    mov ebx, [h264_dmv0 + eax * 4]
    mov [h264_mvc + edx * 4], ebx
    mov ebx, [h264_dmv1 + eax * 4]
    mov [h264_mvc + (40 * 4) + edx * 4], ebx
    pop ebx
    inc ebp
    movzx eax, byte [h264_px + ebx]
    movzx ecx, byte [h264_pw + ebx]
    add eax, ecx
    cmp ebp, eax
    jb .col
    inc edi
    cmp edi, esi
    jb .row
    pop ebp
    pop edi
    pop esi
    ret

; h264_mc_direct: motion compensation of direct partition EBX: as one
; block if its 4x4 blocks all have the same vectors, else block by block
; (through the scratch partition 16)
h264_mc_direct:
    movzx eax, byte [h264_py + ebx]
    shl eax, 3
    movzx ecx, byte [h264_px + ebx]
    add eax, ecx
    lea esi, [eax + 9]              ; ESI = cache index of the top-left
    mov ecx, [h264_mvc + esi * 4]
    mov edx, [h264_mvc + 160 + esi * 4]
    movzx edi, byte [h264_ph + ebx]
.r: movzx eax, byte [h264_pw + ebx]
    push esi
.c: cmp [h264_mvc + esi * 4], ecx
    jne .split
    cmp [h264_mvc + 160 + esi * 4], edx
    jne .split
    inc esi
    dec eax
    jnz .c
    pop esi
    add esi, 8
    dec edi
    jnz .r
    jmp h264_mc_part1               ; uniform
.split:
    pop esi
    ; block by block
    mov al, [h264_ppred + ebx]
    mov [h264_ppred + 16], al
    mov al, [h264_pref + ebx]
    mov [h264_pref + 16], al
    mov al, [h264_pref1 + ebx]
    mov [h264_pref1 + 16], al
    mov byte [h264_pw + 16], 1
    mov byte [h264_ph + 16], 1
    movzx edi, byte [h264_py + ebx]
.br:
    movzx esi, byte [h264_px + ebx]
.bc:
    mov eax, esi
    mov [h264_px + 16], al
    mov eax, edi
    mov [h264_py + 16], al
    push ebx
    push esi
    push edi
    mov ebx, 16
    call h264_mc_part1
    pop edi
    pop esi
    pop ebx
    inc esi
    movzx eax, byte [h264_px + ebx]
    movzx ecx, byte [h264_pw + ebx]
    add eax, ecx
    cmp esi, eax
    jb .bc
    inc edi
    movzx eax, byte [h264_py + ebx]
    movzx ecx, byte [h264_ph + ebx]
    add eax, ecx
    cmp edi, eax
    jb .br
    ret

; =============================================================================
;  Per slice: the co-located picture, temporal direct scaling and implicit
;  weights (8.4.1.2.3, 8.4.2.3.1)
; =============================================================================

; h264_slice_bsetup: for a B slice whose lists are built
h264_slice_bsetup:
    push ebx
    push esi
    push edi
    push ebp
    movzx eax, byte [h264_list1]
    SLOTP eax
    mov edx, [eax + SL_MOT]
    mov [h264_colmo], edx
    mov edx, [eax + SL_FLAGS]
    and edx, F_SHORT
    mov [h264_col_short], edx
    mov ebx, [eax + SL_POC]         ; EBX = POC of RefPicList1[0]
    ; temporal direct: DistScaleFactor per list 0 index
    xor esi, esi
.t: movzx eax, byte [h264_list0 + esi]
    SLOTP eax
    mov byte [h264_dsfm + esi], 1
    test dword [eax + SL_FLAGS], F_LONG
    jnz .tn
    mov edx, [eax + SL_POC]         ; pic0
    mov eax, ebx
    call h264_dsf_calc              ; (pic1 = RefPicList1[0])
    jc .tn
    mov [h264_dsf + esi * 4], eax
    mov byte [h264_dsfm + esi], 0
.tn:
    inc esi
    cmp esi, 16
    jb .t
    ; implicit weights: w1 = DistScaleFactor >> 2 for every pair
    cmp dword [h264_sh_wmode], 2
    jne .done
    xor esi, esi                    ; ESI = ref0 * 16 + ref1
.w: mov eax, esi
    shr eax, 4
    movzx eax, byte [h264_list0 + eax]
    SLOTP eax
    mov edi, 32
    test dword [eax + SL_FLAGS], F_LONG
    jnz .wput
    mov edx, [eax + SL_POC]         ; pic0
    mov eax, esi
    and eax, 15
    movzx eax, byte [h264_list1 + eax]
    SLOTP eax
    test dword [eax + SL_FLAGS], F_LONG
    jnz .wput
    mov eax, [eax + SL_POC]         ; pic1
    call h264_dsf_calc
    jc .wput
    sar eax, 2
    cmp eax, -64
    jl .wput
    cmp eax, 128
    jg .wput
    mov edi, eax
.wput:
    mov [h264_impw + esi * 4], edi
    inc esi
    cmp esi, 256
    jb .w
.done:
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

; h264_dsf_calc: EAX = POC of pic1, EDX = POC of pic0 -> EAX =
; DistScaleFactor (8.4.1.2.3) for the current picture; CF = 1 if
; DiffPicOrderCnt(pic1, pic0) is 0 (no scaling). ECX EDX changed.
h264_dsf_calc:
    push ebx
    push esi
    sub eax, edx                    ; td = Clip3(-128, 127, pic1 - pic0)
    call h264_clip128
    test eax, eax
    jz .zero
    mov ecx, eax                    ; ECX = td
    mov eax, [h264_pic_poc]         ; tb = Clip3(-128, 127, curr - pic0)
    sub eax, edx
    call h264_clip128
    mov ebx, eax                    ; EBX = tb
    mov eax, ecx                    ; tx = (16384 + Abs(td / 2)) / td
    cdq
    mov esi, 2
    idiv esi
    test eax, eax
    jns .abs
    neg eax
.abs:
    add eax, 16384
    cdq
    idiv ecx
    imul eax, ebx                   ; Clip3(-1024, 1023, (tb * tx + 32) >> 6)
    add eax, 32
    sar eax, 6
    cmp eax, -1024
    jge .c1
    mov eax, -1024
.c1:
    cmp eax, 1023
    jle .c2
    mov eax, 1023
.c2:
    clc
    pop esi
    pop ebx
    ret
.zero:
    stc
    pop esi
    pop ebx
    ret

; h264_clip128: EAX = Clip3(-128, 127, EAX)
h264_clip128:
    cmp eax, -128
    jge .a
    mov eax, -128
.a: cmp eax, 127
    jle .b
    mov eax, 127
.b: ret

; =============================================================================
;  Motion compensation of a partition
; =============================================================================

; h264_mc_part1: motion compensated prediction of partition EBX (vectors
; and references in the caches) into the current frame: from one list
; without weights straight into the frame; otherwise each list into
; h264_pb0 / h264_pb1, then combined (8.4.2.3). EBX ESI EDI EBP kept.
h264_mc_part1:
    push esi
    push edi
    push ebp
    movzx eax, byte [h264_ppred + ebx]
    and eax, PP_L0 | PP_L1
    cmp eax, PP_L0 | PP_L1
    je .bi
    ; one list (EBP)
    xor ebp, ebp
    cmp eax, PP_L1
    jne .one
    inc ebp
.one:
    cmp dword [h264_sh_wmode], 1    ; explicit weights for this reference?
    jne .plain
    movsx eax, byte [h264_pref + ebx]
    test ebp, ebp
    jz .o0
    movsx eax, byte [h264_pref1 + ebx]
.o0:
    shl ebp, 5
    add eax, ebp
    shr ebp, 5
    cmp byte [h264_wtf + eax], 0
    jne .weighted
.plain:
    mov eax, [h264_dy]
    mov [h264_mc_dy], eax
    mov eax, [h264_du]
    mov [h264_mc_du], eax
    mov eax, [h264_dv]
    mov [h264_mc_dv], eax
    mov eax, [h264_ystride]
    mov [h264_mc_ds], eax
    mov eax, [h264_cstride]
    mov [h264_mc_dsc], eax
    mov eax, ebp
    call h264_mc_list
    jmp .out
.weighted:
    ; one list, explicit weights: into h264_pb0, then weighted
    mov edi, h264_pb0
    mov eax, ebp
    call h264_mc_temp
    imul eax, ebp, 32               ; the weights of the reference
    movsx ecx, byte [h264_pref + ebx]
    test ebp, ebp
    jz .w0
    movsx ecx, byte [h264_pref1 + ebx]
.w0:
    add eax, ecx
    imul eax, WT_SZ
    add eax, h264_wt
    mov [h264_wtmp], eax
    mov dword [h264_cw_mode], 1
    mov esi, eax
    mov eax, [esi]                  ; luma
    mov [h264_cw_w0], eax
    mov eax, [esi + 4]
    mov [h264_cw_o], eax
    mov eax, [h264_sh_lwd]
    mov [h264_cw_log], eax
    call h264_combine_luma
    mov esi, [h264_wtmp]
    mov eax, [h264_sh_cwd]
    mov [h264_cw_log], eax
    mov eax, [esi + 8]              ; Cb
    mov [h264_cw_w0], eax
    mov eax, [esi + 12]
    mov [h264_cw_o], eax
    mov esi, h264_du
    mov edx, PB_U
    call h264_combine_chroma
    mov esi, [h264_wtmp]
    mov eax, [esi + 16]             ; Cr
    mov [h264_cw_w0], eax
    mov eax, [esi + 20]
    mov [h264_cw_o], eax
    mov esi, h264_dv
    mov edx, PB_V
    call h264_combine_chroma
    jmp .out
.bi:
    ; both lists into h264_pb0 / h264_pb1
    mov edi, h264_pb0
    xor eax, eax
    call h264_mc_temp
    mov edi, h264_pb1
    mov eax, 1
    call h264_mc_temp
    movsx eax, byte [h264_pref + ebx]
    movsx ecx, byte [h264_pref1 + ebx]
    mov edx, [h264_sh_wmode]
    cmp edx, 1
    je .biexp
    mov dword [h264_cw_mode], 0     ; default: average
    cmp edx, 2
    jne .biavg
    ; implicit: w0 = 64 - w1, offsets 0, logWD 5 (32 / 32 is the average)
    shl eax, 4
    add eax, ecx
    mov eax, [h264_impw + eax * 4]
    cmp eax, 32
    je .biavg
    mov dword [h264_cw_mode], 2
    mov [h264_cw_w1], eax
    neg eax
    add eax, 64
    mov [h264_cw_w0], eax
    mov dword [h264_cw_o], 0
    mov dword [h264_cw_log], 5
.biavg:
    call h264_combine_luma
    mov esi, h264_du
    mov edx, PB_U
    call h264_combine_chroma
    mov esi, h264_dv
    mov edx, PB_V
    call h264_combine_chroma
    jmp .out
.biexp:
    ; explicit: the weights of both references
    mov edx, eax
    or dl, [h264_wtf + ecx + 32]
    mov dl, [h264_wtf + eax]
    or dl, [h264_wtf + ecx + 32]
    imul eax, WT_SZ
    add eax, h264_wt
    mov [h264_wtmp], eax
    imul ecx, WT_SZ
    add ecx, h264_wt + 32 * WT_SZ
    mov [h264_wtmp + 4], ecx
    mov [h264_wtmp + 8], edx        ; which planes are weighted
    mov dword [h264_cw_mode], 0
    test dl, 1
    jz .bel
    mov esi, 0
    call .biw
.bel:
    call h264_combine_luma
    mov dword [h264_cw_mode], 0
    test byte [h264_wtmp + 8], 2
    jz .bec
    mov esi, 8
    call .biw
.bec:
    mov esi, h264_du
    mov edx, PB_U
    call h264_combine_chroma
    test byte [h264_wtmp + 8], 2
    jz .bec2
    mov esi, 16
    call .biw
.bec2:
    mov esi, h264_dv
    mov edx, PB_V
    call h264_combine_chroma
.out:
    pop ebp
    pop edi
    pop esi
    ret
; the explicit bi-prediction weights of plane field ESI (0 luma, 8 Cb, 16
; Cr): w0, w1, o = (o0 + o1 + 1) >> 1, logWD
.biw:
    mov dword [h264_cw_mode], 2
    mov eax, [h264_wtmp]
    mov ecx, [h264_wtmp + 4]
    mov edx, [eax + esi]
    mov [h264_cw_w0], edx
    mov edx, [ecx + esi]
    mov [h264_cw_w1], edx
    mov edx, [eax + esi + 4]
    add edx, [ecx + esi + 4]
    inc edx
    sar edx, 1
    mov [h264_cw_o], edx
    mov eax, [h264_sh_lwd]
    test esi, esi
    jz .biw1
    mov eax, [h264_sh_cwd]
.biw1:
    mov [h264_cw_log], eax
    ret

; h264_mc_temp: partition EBX predicted from list EAX into the buffer EDI
; (h264_pb0 / h264_pb1: luma stride 16, chroma at PB_U / PB_V stride 16).
; EBX ESI EDI EBP kept.
h264_mc_temp:
    mov [h264_mc_dy], edi
    lea ecx, [edi + PB_U]
    mov [h264_mc_du], ecx
    lea ecx, [edi + PB_V]
    mov [h264_mc_dv], ecx
    mov dword [h264_mc_ds], 16
    mov dword [h264_mc_dsc], 16
    jmp h264_mc_list

; h264_combine_luma: the luma of partition EBX from h264_pb0 (and
; h264_pb1) into the frame with h264_cw_* (h264_wpred). EBX kept.
h264_combine_luma:
    movzx eax, byte [h264_py + ebx]
    shl eax, 2
    mov ecx, eax
    shl ecx, 4                      ; row in the buffer (stride 16)
    imul eax, [h264_ystride]
    movzx edx, byte [h264_px + ebx]
    shl edx, 2
    add eax, edx
    add ecx, edx
    mov edi, [h264_dy]
    add edi, eax
    lea esi, [h264_pb0 + ecx]
    lea edx, [h264_pb1 + ecx]
    mov eax, [h264_ystride]
    mov [h264_cw_ds], eax
    movzx eax, byte [h264_pw + ebx]
    shl eax, 2
    mov [h264_cw_w], eax
    movzx eax, byte [h264_ph + ebx]
    shl eax, 2
    mov [h264_cw_h], eax
    jmp h264_wpred

; h264_combine_chroma: the same for a chroma plane: ESI = h264_du /
; h264_dv (the macroblock in the frame), EDX = PB_U / PB_V. EBX kept.
h264_combine_chroma:
    push edx
    movzx eax, byte [h264_py + ebx]
    shl eax, 1
    mov ecx, eax
    shl ecx, 4
    imul eax, [h264_cstride]
    movzx edx, byte [h264_px + ebx]
    shl edx, 1
    add eax, edx
    add ecx, edx
    mov edi, [esi]
    add edi, eax
    pop edx
    add ecx, edx
    lea esi, [h264_pb0 + ecx]
    lea edx, [h264_pb1 + ecx]
    mov eax, [h264_cstride]
    mov [h264_cw_ds], eax
    movzx eax, byte [h264_pw + ebx]
    shl eax, 1
    mov [h264_cw_w], eax
    movzx eax, byte [h264_ph + ebx]
    shl eax, 1
    mov [h264_cw_h], eax
    jmp h264_wpred

; h264_wpred: weighted sample prediction (8.4.2.3) of a block: ESI = the
; list 0 (or only) prediction, EDX = the list 1 one (stride 16), EDI =
; destination (stride h264_cw_ds), size h264_cw_w x h264_cw_h; h264_cw_mode
;   0: (a + b + 1) >> 1
;   1: Clip1(((a * w0 + 2^(log - 1)) >> log) + o)   (a * w0 + o if log = 0)
;   2: Clip1(((a * w0 + b * w1 + 2^log) >> (log + 1)) + o)
; EBX kept.
h264_wpred:
    push ebx
    push ebp
    mov ebp, [h264_cw_h]
.row:
    xor ebx, ebx
.col:
    movzx eax, byte [esi + ebx]
    mov ecx, [h264_cw_mode]
    test ecx, ecx
    jnz .w
    movzx ecx, byte [edx + ebx]     ; average
    lea eax, [eax + ecx + 1]
    shr eax, 1
    jmp .put
.w: cmp ecx, 1
    jne .w2
    imul eax, [h264_cw_w0]          ; one list
    mov ecx, [h264_cw_log]
    test ecx, ecx
    jz .w1o
    push edx
    mov edx, 1
    dec ecx
    shl edx, cl
    inc ecx
    add eax, edx
    sar eax, cl
    pop edx
.w1o:
    add eax, [h264_cw_o]
    jmp .clip
.w2:
    imul eax, [h264_cw_w0]          ; two lists
    movzx ecx, byte [edx + ebx]
    imul ecx, [h264_cw_w1]
    add eax, ecx
    mov ecx, [h264_cw_log]
    push edx
    mov edx, 1
    shl edx, cl
    add eax, edx
    pop edx
    inc ecx
    sar eax, cl
    add eax, [h264_cw_o]
.clip:
    test eax, eax
    jns .c1
    xor eax, eax
.c1:
    cmp eax, 255
    jle .put
    mov eax, 255
.put:
    mov [edi + ebx], al
    inc ebx
    cmp ebx, [h264_cw_w]
    jb .col
    add esi, 16
    add edx, 16
    add edi, [h264_cw_ds]
    dec ebp
    jnz .row
    pop ebp
    pop ebx
    ret

; h264_mc_list: partition EBX predicted from list EAX (vector from the
; cache, reference frame from the list) into the destination
; h264_mc_dy / _du / _dv (the macroblock's origin; strides h264_mc_ds,
; h264_mc_dsc). EBX ESI EDI EBP kept.
h264_mc_list:
    push esi
    push edi
    push ebp
    mov [h264_mc_lst], eax
    movzx ecx, byte [h264_py + ebx]
    shl ecx, 3
    movzx edx, byte [h264_px + ebx]
    add ecx, edx
    imul edx, eax, 40
    add ecx, edx
    mov ebp, [h264_mvc + ecx * 4 + 9 * 4]   ; EBP = vector
    movzx ecx, byte [h264_pref + ebx]
    test eax, eax
    jz .l0
    movzx ecx, byte [h264_pref1 + ebx]
    movzx ecx, byte [h264_list1 + ecx]
    jmp .l1
.l0:
    movzx ecx, byte [h264_list0 + ecx]
.l1:
    SLOTP ecx
    mov [h264_mc_refp], ecx
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
    imul eax, [h264_mc_ds]
    movzx ecx, byte [h264_px + ebx]
    shl ecx, 2
    add eax, ecx
    add eax, [h264_mc_dy]
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
    imul eax, [h264_mc_dsc]
    movzx ecx, byte [h264_px + ebx]
    shl ecx, 1
    add eax, ecx
    push eax
    add eax, [h264_mc_du]
    mov edi, eax
    mov eax, [h264_mc_refp]
    mov esi, [eax + SL_U]
    call h264_mc_chroma
    pop eax
    add eax, [h264_mc_dv]
    mov edi, eax
    mov eax, [h264_mc_refp]
    mov esi, [eax + SL_V]
    call h264_mc_chroma
    pop ebp
    pop edi
    pop esi
    ret

section .bss
alignb 4
h264_colmo_mb   resd 1              ; the co-located macroblock's motion data
section .text
