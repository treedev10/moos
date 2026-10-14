PB_SZ           equ 16 * 16 + 2 * 16 * 8
PB_U            equ 256
PB_V            equ 384

PP_L0           equ 1
PP_L1           equ 2
PP_DIRECT       equ 4

section .bss
alignb 16
h264_pb0        resb PB_SZ
h264_pb1        resb PB_SZ

h264_refc       resb 80
alignb 4
h264_mvc        resd 80
h264_dmv0       resd 16
h264_dmv1       resd 16
h264_dref0      resb 4
h264_dref1      resb 4

h264_np         resd 1
h264_px         resb 20
h264_py         resb 20
h264_pw         resb 20
h264_ph         resb 20
h264_pshape     resb 20
h264_ppred      resb 20
h264_pgrp       resb 20

h264_pref       resb 20
h264_pref1      resb 20
h264_sub        resb 4
alignb 4
h264_pmvd       resd 20
h264_pmvd1      resd 20
h264_mbdesc     resd 1
h264_ref0only   resd 1
h264_pp_x       resd 1
h264_pp_y       resd 1
h264_pp_w       resd 1
h264_pp_ref     resd 1
h264_pp_shape   resd 1
h264_pp_lo      resd 1
h264_fm_row     resd 1

h264_mc_refp    resd 1
h264_mc_x       resd 1
h264_mc_y       resd 1
h264_mc_w       resd 1
h264_mc_h       resd 1
h264_mc_ds      resd 1
h264_mc_dsc     resd 1
h264_mc_dy      resd 1
h264_mc_du      resd 1
h264_mc_dv      resd 1
h264_mc_lst     resd 1
h264_mc_part    resd 1

h264_cw_mode    resd 1
h264_cw_w0      resd 1
h264_cw_w1      resd 1
h264_cw_o       resd 1
h264_cw_log     resd 1
h264_cw_ds      resd 1
h264_cw_w       resd 1
h264_cw_h       resd 1

h264_colmo      resd 1
h264_col_short  resd 1
h264_dsf        resd 16
h264_dsfm       resb 16

alignb 4
h264_impw       resd 16 * 16
h264_wtmp       resd 8

section .data

h264_ptype      db 0x10, 0x51, 0x52, 0x03, 0x03
h264_btype      db 0x00, 0x10, 0x20, 0x30
                db 0x51, 0x52, 0xA1, 0xA2, 0x91, 0x92, 0x61, 0x62
                db 0xD1, 0xD2, 0xE1, 0xE2, 0x71, 0x72, 0xB1, 0xB2
                db 0xF1, 0xF2, 0x03

h264_psubt      db 0x10, 0x11, 0x12, 0x13
h264_bsubt      db 0x00, 0x10, 0x20, 0x30, 0x11, 0x12, 0x21, 0x22
                db 0x31, 0x32, 0x13, 0x23, 0x33

h264_corner     db 0, 0, 3, 3, 0, 0, 3, 3, 12, 12, 15, 15, 12, 12, 15, 15

section .text

h264_fill_motion:
    push esi
    push edi
    push ebp
    mov edi, h264_refc
    mov eax, 0xFEFEFEFE
    mov ecx, 80 / 4
    rep stosd
    mov edi, h264_mvc
    xor eax, eax
    mov ecx, 80
    rep stosd
    mov eax, [h264_mbw]
    imul eax, MO_SZ
    mov [h264_fm_row], eax
    xor ebp, ebp
.list:
    mov edx, [h264_mop]
    lea edx, [edx + ebp * 4]
    mov esi, ebp
    shl esi, 6
    add esi, [h264_mop]
    imul edi, ebp, 40
    cmp dword [h264_avA], 0
    je .noA
    mov al, [edx - MO_SZ + MO_REF0 + 1]
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
    sub edx, ecx
    sub esi, ecx
    cmp dword [h264_avB], 0
    je .noB
    mov al, [edx + MO_REF0 + 2]
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
    mov al, [edx + MO_SZ + MO_REF0 + 2]
    mov [h264_refc + edi + 5], al
    mov eax, [esi + MO_SZ + MO_MV0 + 12 * 4]
    mov [h264_mvc + edi * 4 + 5 * 4], eax
.noC:
    cmp dword [h264_avD], 0
    je .noD
    mov al, [edx - MO_SZ + MO_REF0 + 3]
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

h264_mvpred:
    push ebx
    push esi
    push edi
    push ebp
    mov eax, [h264_pp_y]
    shl eax, 3
    add eax, [h264_pp_x]
    add eax, [h264_pp_lo]
    lea esi, [eax + 8]
    lea edi, [eax + 1]
    mov ebx, eax
    add ebx, [h264_pp_w]
    inc ebx
    cmp byte [h264_refc + ebx], REF_NA & 255
    jne .c
    mov ebx, eax
.c: mov ebp, [h264_pp_ref]
    movsx eax, byte [h264_refc + esi]
    movsx ecx, byte [h264_refc + edi]
    movsx edx, byte [h264_refc + ebx]

    push eax
    mov eax, [h264_pp_shape]
    test eax, eax
    jz .median0
    cmp eax, 1
    jne .s2
    cmp ecx, ebp
    jne .median0
    mov eax, [h264_mvc + edi * 4]
    jmp .ret1
.s2:
    cmp eax, 4
    je .s4
    mov eax, [esp]
    cmp eax, ebp
    jne .median0
    mov eax, [h264_mvc + esi * 4]
    jmp .ret1
.s4:
    cmp edx, ebp
    jne .median0
    mov eax, [h264_mvc + ebx * 4]
.ret1:
    add esp, 4
    jmp .out
.median0:
    pop eax

    cmp ecx, REF_NA
    jne .med
    cmp edx, REF_NA
    jne .med
    cmp eax, REF_NA
    je .med
    mov eax, [h264_mvc + esi * 4]
    jmp .out
.med:

    push ebx
    xor ebx, ebx
    cmp eax, ebp
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

h264_median3:
    cmp eax, ecx
    jle .s1
    xchg eax, ecx
.s1:
    cmp ecx, edx
    jle .s2
    mov ecx, edx
.s2:
    cmp eax, ecx
    jge .r
    mov eax, ecx
.r: ret

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
    xor eax, eax
    cmp byte [h264_refc + 8], REF_NA & 255
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
    mov ecx, eax
    xor edx, edx
    xor eax, eax
    call h264_set_area
    xor ebx, ebx
    call h264_mc_part1
    jmp h264_store_motion

h264_mb_inter:
    push ebp
    mov dword [h264_mbt], 0
    mov dword [h264_ref0only], 0
    cmp dword [h264_sh_type], ST_B
    je .b
    cmp eax, 4
    jne .p
    mov dword [h264_ref0only], 1
.p: movzx eax, byte [h264_ptype + eax]
    jmp .desc
.b: test eax, eax
    jnz .b1
    mov dword [h264_mbt], MT_DIRECT
    call h264_inter_pred
    jmp .residual
.b1:
    movzx eax, byte [h264_btype + eax]
.desc:
    mov [h264_mbdesc], eax
    and eax, 3
    cmp eax, 3
    jne .layout

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

    xor ebp, ebp
.rl:
    xor ebx, ebx
.r1:
    mov al, -1
    movzx edx, byte [h264_ppred + ebx]
    test edx, PP_DIRECT
    jnz .rput
    lea ecx, [ebp + 1]
    test edx, ecx
    jz .rput
    test ebx, ebx
    jz .rread
    mov al, [h264_pgrp + ebx]
    cmp al, [h264_pgrp + ebx - 1]
    jne .rread
    mov al, [h264_pref + ebx - 1]
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

h264_read_mvd:
    call h264_se
    push eax
    call h264_se
    shl eax, 16
    pop ecx
    mov ax, cx
    ret

h264_mb_partitions:
    push ebx
    push esi
    push edi
    mov eax, [h264_mbdesc]
    mov edx, eax
    shr edx, 4
    and edx, 3
    mov ecx, eax
    shr ecx, 6
    and eax, 3
    xor edi, edi
    mov dword [h264_px], 0
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
    mov byte [h264_ph], 2
    mov byte [h264_ph + 1], 2
    mov byte [h264_pw + 1], 4
    mov byte [h264_py + 1], 2
    mov byte [h264_pshape], 1
    mov byte [h264_pshape + 1], 2
    jmp .out
.v: mov byte [h264_pw], 2
    mov byte [h264_pw + 1], 2
    mov byte [h264_ph + 1], 4
    mov byte [h264_px + 1], 2
    mov byte [h264_pshape], 3
    mov byte [h264_pshape + 1], 4
    jmp .out
.p8x8:
    xor ebx, ebx
.s4:
    mov ecx, ebx
    and ecx, 1
    shl ecx, 1
    mov edx, ebx
    shr edx, 1
    shl edx, 1
    movzx esi, byte [h264_sub + ebx]
    mov eax, esi
    shr eax, 4
    jnz .s4p
    mov eax, PP_DIRECT
.s4p:
    and esi, 3
    jnz .s5
    call .add
    mov byte [h264_pw + edi - 1], 2
    mov byte [h264_ph + edi - 1], 2
    jmp .s9
.s5:
    cmp esi, 1
    jne .s6
    call .add
    mov byte [h264_pw + edi - 1], 2
    inc edx
    call .add
    mov byte [h264_pw + edi - 1], 2
    jmp .s9
.s6:
    cmp esi, 2
    jne .s7
    call .add
    mov byte [h264_ph + edi - 1], 2
    inc ecx
    call .add
    mov byte [h264_ph + edi - 1], 2
    jmp .s9
.s7:
    call .add
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

h264_inter_pred:
    push ebp
    call h264_fill_motion
    cmp dword [h264_sh_type], ST_B
    jne .nodirect
    test dword [h264_mbt], MT_DIRECT
    jnz .direct

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

    xor ebx, ebx
.pp:
    test byte [h264_ppred + ebx], PP_DIRECT
    jz .pv
    call h264_direct_copy
    jmp .pn
.pv:
    xor ebp, ebp
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
    mov edx, [edx + ebx * 4]
    push edx
    call h264_mvpred
    pop edx
    mov ecx, eax
    add cx, dx
    shr eax, 16
    shr edx, 16
    add ax, dx
    shl eax, 16
    mov ax, cx
    mov ecx, eax
    mov dl, [h264_pref + ebx]
    test ebp, ebp
    jz .set
    mov dl, [h264_pref1 + ebx]
    jmp .set
.unused:
    xor ecx, ecx
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

h264_set_area:
    push esi
    push edi
    push ebp
    imul ebp, eax, 40
    movzx esi, byte [h264_py + ebx]
    shl esi, 3
    movzx eax, byte [h264_px + ebx]
    add esi, eax
    lea esi, [esi + ebp + 9]
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
    xor ecx, ecx
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

h264_direct:
    push ebp

    mov eax, [h264_mbaddr]
    imul eax, MO_SZ
    add eax, [h264_colmo]
    mov [h264_colmo_mb], eax
    cmp dword [h264_sh_dspat], 0
    je h264_direct_temporal

    xor ebp, ebp
.sref:
    imul edi, ebp, 40
    movsx eax, byte [h264_refc + edi + 8]
    movsx ecx, byte [h264_refc + edi + 1]
    movsx edx, byte [h264_refc + edi + 5]
    cmp edx, REF_NA
    jne .sc
    movsx edx, byte [h264_refc + edi + 0]
.sc:
    push eax
    mov eax, ecx
    mov ecx, edx
    call h264_minpos
    mov ecx, eax
    pop eax
    call h264_minpos
    test eax, eax
    jns .sr1
    or eax, -1
.sr1:
    mov [h264_wtmp + ebp * 4], eax
    inc ebp
    cmp ebp, 2
    jb .sref
    xor esi, esi
    mov eax, [h264_wtmp]
    and eax, [h264_wtmp + 4]
    jns .refok
    xor eax, eax
    mov [h264_wtmp], eax
    mov [h264_wtmp + 4], eax
    inc esi
.refok:

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

    movzx eax, byte [h264_wtmp]
    mov ecx, 0x01010101
    imul eax, ecx
    mov [h264_dref0], eax
    movzx eax, byte [h264_wtmp + 4]
    imul eax, ecx
    mov [h264_dref1], eax
    xor ebx, ebx
.sblk:
    xor ecx, ecx
    test esi, esi
    jnz .snocz
    cmp dword [h264_col_short], 0
    je .snocz
    call h264_col_block
    xor ecx, ecx
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
    mov edx, [h264_wtmp + ebp * 4]
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

h264_direct_temporal:
    xor ebx, ebx
.blk:
    call h264_col_block
    mov esi, edx

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
    xor edi, edi
.ref0:
    mov eax, ebx
    shr eax, 3
    shl eax, 1
    mov edx, ebx
    and edx, 3
    shr edx, 1
    add eax, edx
    mov edx, edi
    mov [h264_dref0 + eax], dl
    mov byte [h264_dref1 + eax], 0

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
    sar eax, 8
    movsx edx, si
    mov ecx, eax
    sub ecx, edx
    mov edi, esi
    sar edi, 16
    imul edi, ebp
    add edi, 128
    sar edi, 8
    mov edx, esi
    sar edx, 16
    neg edx
    add edx, edi
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
    mov ecx, eax
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

h264_direct_copy:
    push esi
    push edi
    push ebp
    movzx eax, byte [h264_px + ebx]
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

    movzx edi, byte [h264_py + ebx]
    movzx esi, byte [h264_ph + ebx]
    add esi, edi
.row:
    movzx ebp, byte [h264_px + ebx]
.col:
    lea eax, [edi * 4 + ebp]
    mov ecx, eax
    shr ecx, 3
    shl ecx, 1
    mov edx, ebp
    shr edx, 1
    add ecx, edx
    lea edx, [edi * 8 + ebp + 9]
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

h264_mc_direct:
    movzx eax, byte [h264_py + ebx]
    shl eax, 3
    movzx ecx, byte [h264_px + ebx]
    add eax, ecx
    lea esi, [eax + 9]
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
    jmp h264_mc_part1
.split:
    pop esi

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
    mov ebx, [eax + SL_POC]

    xor esi, esi
.t: mov byte [h264_dsfm + esi], 1
    cmp esi, [h264_sh_nref0]
    jae .tn
    movzx eax, byte [h264_list0 + esi]
    SLOTP eax
    test dword [eax + SL_FLAGS], F_LONG
    jnz .tn
    mov edx, [eax + SL_POC]
    mov eax, ebx
    call h264_dsf_calc
    jc .tn
    mov [h264_dsf + esi * 4], eax
    mov byte [h264_dsfm + esi], 0
.tn:
    inc esi
    cmp esi, 16
    jb .t

    cmp dword [h264_sh_wmode], 2
    jne .done
    xor esi, esi
.w: mov edi, 32
    mov eax, esi
    shr eax, 4
    cmp eax, [h264_sh_nref0]
    jae .wput
    movzx eax, byte [h264_list0 + eax]
    SLOTP eax
    test dword [eax + SL_FLAGS], F_LONG
    jnz .wput
    mov edx, [eax + SL_POC]
    mov eax, esi
    and eax, 15
    cmp eax, [h264_sh_nref1]
    jae .wput
    movzx eax, byte [h264_list1 + eax]
    SLOTP eax
    test dword [eax + SL_FLAGS], F_LONG
    jnz .wput
    mov eax, [eax + SL_POC]
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

h264_dsf_calc:
    push ebx
    push esi
    sub eax, edx
    call h264_clip128
    test eax, eax
    jz .zero
    mov ecx, eax
    mov eax, [h264_pic_poc]
    sub eax, edx
    call h264_clip128
    mov ebx, eax
    mov eax, ecx
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
    imul eax, ebx
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

h264_clip128:
    cmp eax, -128
    jge .a
    mov eax, -128
.a: cmp eax, 127
    jle .b
    mov eax, 127
.b: ret

h264_mc_part1:
    push esi
    push edi
    push ebp
    movzx eax, byte [h264_ppred + ebx]
    and eax, PP_L0 | PP_L1
    cmp eax, PP_L0 | PP_L1
    je .bi

    xor ebp, ebp
    cmp eax, PP_L1
    jne .one
    inc ebp
.one:
    cmp dword [h264_sh_wmode], 1
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

    mov edi, h264_pb0
    mov eax, ebp
    call h264_mc_temp
    imul eax, ebp, 32
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
    mov eax, [esi]
    mov [h264_cw_w0], eax
    mov eax, [esi + 4]
    mov [h264_cw_o], eax
    mov eax, [h264_sh_lwd]
    mov [h264_cw_log], eax
    call h264_combine_luma
    mov esi, [h264_wtmp]
    mov eax, [h264_sh_cwd]
    mov [h264_cw_log], eax
    mov eax, [esi + 8]
    mov [h264_cw_w0], eax
    mov eax, [esi + 12]
    mov [h264_cw_o], eax
    mov esi, h264_du
    mov edx, PB_U
    call h264_combine_chroma
    mov esi, [h264_wtmp]
    mov eax, [esi + 16]
    mov [h264_cw_w0], eax
    mov eax, [esi + 20]
    mov [h264_cw_o], eax
    mov esi, h264_dv
    mov edx, PB_V
    call h264_combine_chroma
    jmp .out
.bi:

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
    mov dword [h264_cw_mode], 0
    cmp edx, 2
    jne .biavg

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
    mov [h264_wtmp + 8], edx
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

h264_mc_temp:
    mov [h264_mc_dy], edi
    lea ecx, [edi + PB_U]
    mov [h264_mc_du], ecx
    lea ecx, [edi + PB_V]
    mov [h264_mc_dv], ecx
    mov dword [h264_mc_ds], 16
    mov dword [h264_mc_dsc], 16
    jmp h264_mc_list

h264_combine_luma:
    movzx eax, byte [h264_py + ebx]
    shl eax, 2
    mov ecx, eax
    shl ecx, 4
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
    movzx ecx, byte [edx + ebx]
    lea eax, [eax + ecx + 1]
    shr eax, 1
    jmp .put
.w: cmp ecx, 1
    jne .w2
    imul eax, [h264_cw_w0]
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
    imul eax, [h264_cw_w0]
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
    mov ebp, [h264_mvc + ecx * 4 + 9 * 4]
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

    movzx eax, byte [h264_px + ebx]
    mov ecx, [h264_mbx]
    shl ecx, 2
    add eax, ecx
    shl eax, 4
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

    shr dword [h264_mc_w], 1
    shr dword [h264_mc_h], 1
    movzx eax, byte [h264_px + ebx]
    mov ecx, [h264_mbx]
    shl ecx, 2
    add eax, ecx
    shl eax, 4
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
h264_colmo_mb   resd 1
section .text
