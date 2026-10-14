section .text

%macro SLOTP 1
    imul %1, %1, SL_SZ
    add %1, h264_slots
%endmacro

h264_activate:
    push esi
    push edi
    mov eax, [edi + SPS_MBW]
    cmp eax, [h264_maxmbw]
    ja .bad
    mov edx, [edi + SPS_MBH]
    cmp edx, [h264_maxmbh]
    ja .bad
    mov [h264_mbw], eax
    mov [h264_mbh], edx
    imul eax, edx
    mov [h264_nmb], eax
    mov esi, edi
    mov edi, [h264_asps]
    mov ecx, SPS_SZ / 4
    rep movsd
    mov edi, [h264_asps]
    mov dword [h264_act], 1
    movzx ecx, byte [edi + SPS_LOG2FN]
    mov eax, 1
    shl eax, cl
    mov [h264_maxfn], eax

    mov eax, [edi + SPS_MAXDEC]
    test eax, eax
    jns .havedpb
    movzx edx, byte [edi + SPS_LEVEL]
    mov esi, h264_dpbmbs
    mov eax, 184320
.lvl:
    mov ecx, [esi]
    test ecx, ecx
    jz .lvd
    cmp ecx, edx
    je .lvf
    add esi, 8
    jmp .lvl
.lvf:
    mov eax, [esi + 4]
.lvd:
    xor edx, edx
    div dword [h264_nmb]
.havedpb:
    movzx ecx, byte [edi + SPS_NREF]
    cmp eax, ecx
    jae .d1
    mov eax, ecx
.d1:
    cmp eax, 1
    jae .d2
    mov eax, 1
.d2:
    cmp eax, 16
    jbe .d3
    mov eax, 16
.d3:
    mov [h264_dpbsize], eax

    mov ecx, [edi + SPS_REORDER]
    test ecx, ecx
    jns .ro
    xor ecx, ecx
    cmp byte [edi + SPS_POCTYPE], 2
    je .ro
    mov ecx, eax
.ro:
    cmp ecx, eax
    jbe .ro2
    mov ecx, eax
.ro2:
    mov [h264_reorder], ecx
    xor eax, eax
    pop edi
    pop esi
    ret
.bad:
    or eax, -1
    pop edi
    pop esi
    ret

h264_start_pic:
    push ebx
    push esi
    push edi
    cmp dword [h264_sh_idr], 0
    je .notidr
    mov edi, [h264_sh_sps]
    call h264_activate
    test eax, eax
    jnz .fail
    call h264_output_all
    call h264_unmark_all
    mov dword [h264_need_idr], 0
    xor eax, eax
    mov [h264_prev_pocmsb], eax
    mov [h264_prev_poclsb], eax
    mov [h264_prev_fno], eax
    mov [h264_prev_fn], eax
    mov [h264_prev_reffn], eax
    mov dword [h264_have_ref], 0
    jmp .gapdone
.notidr:

    cmp dword [h264_have_ref], 0
    je .gapdone
    mov eax, [h264_sh_fn]
    cmp eax, [h264_prev_reffn]
    je .gapdone
    mov edx, [h264_prev_reffn]
    inc edx
    cmp edx, [h264_maxfn]
    jb .g1
    xor edx, edx
.g1:
    cmp eax, edx
    je .gapdone
    call h264_fill_gap
.gapdone:
    call h264_alloc_slot
    mov [h264_cur], eax

    mov eax, [h264_sh_fn]
    mov [h264_pic_fn], eax
    mov eax, [h264_sh_poclsb]
    mov [h264_pic_poclsb], eax
    mov eax, [h264_sh_dpb]
    mov [h264_pic_dpb], eax
    mov eax, [h264_sh_dpoc0]
    mov [h264_pic_dpoc0], eax
    mov eax, [h264_sh_dpoc1]
    mov [h264_pic_dpoc1], eax
    mov eax, [h264_sh_idr]
    mov [h264_pic_idr], eax
    mov eax, [h264_sh_idrid]
    mov [h264_pic_idrid], eax
    mov eax, [h264_sh_ppsid]
    mov [h264_pic_ppsid], eax
    mov eax, [h264_nalref]
    mov [h264_pic_refidc], eax
    mov eax, [h264_sh_noout]
    mov [h264_pic_noout], eax
    mov eax, [h264_sh_ltref]
    mov [h264_pic_ltref], eax
    mov eax, [h264_sh_adapt]
    mov [h264_pic_adapt], eax
    mov ecx, [h264_sh_nmmco]
    mov [h264_pic_nmmco], ecx
    imul ecx, 3
    mov esi, h264_sh_mmco
    mov edi, h264_pic_mmco
    rep movsd
    call h264_compute_poc

    mov ebx, [h264_cur]
    SLOTP ebx
    mov eax, F_CUR
    cmp dword [h264_pic_idr], 0
    je .f
    or eax, F_IDR
.f: mov [ebx + SL_FLAGS], eax
    mov eax, [h264_pic_fn]
    mov [ebx + SL_FN], eax
    mov eax, [h264_pic_poc]
    mov [ebx + SL_POC], eax
    mov edi, [h264_asps]
    mov eax, [h264_mbw]
    shl eax, 4
    sub eax, [edi + SPS_CROPL]
    sub eax, [edi + SPS_CROPR]
    mov [ebx + SL_W], eax
    mov eax, [h264_mbh]
    shl eax, 4
    sub eax, [edi + SPS_CROPT]
    sub eax, [edi + SPS_CROPB]
    mov [ebx + SL_H], eax
    mov eax, [edi + SPS_CROPL]
    mov [ebx + SL_CX], eax
    mov eax, [edi + SPS_CROPT]
    mov [ebx + SL_CY], eax
    mov eax, [edi + SPS_SARW]
    mov [ebx + SL_SARW], ax
    mov eax, [edi + SPS_SARH]
    mov [ebx + SL_SARH], ax
    mov eax, [h264_picid]
    mov [ebx + SL_ID], eax
    inc dword [h264_picid]

    mov eax, [h264_lastref]
    test eax, eax
    js .nocon
    mov ecx, eax
    SLOTP ecx
    test dword [ecx + SL_FLAGS], F_REF
    jnz .con
.nocon:
    or eax, -1
.con:
    mov [h264_pic_conceal], eax
    mov dword [h264_pic_on], 1
    mov dword [h264_pic_done], 0
    mov dword [h264_pic_err], 0
    mov eax, [h264_slicectr]
    mov [h264_pic_slice0], eax
    xor eax, eax
.out:
    pop edi
    pop esi
    pop ebx
    ret
.fail:
    or eax, -1
    jmp .out

h264_compute_poc:
    push ebx
    push esi
    push edi
    mov edi, [h264_asps]

    xor eax, eax
    cmp dword [h264_pic_idr], 0
    jne .fno
    mov eax, [h264_prev_fno]
    mov edx, [h264_pic_fn]
    cmp [h264_prev_fn], edx
    jbe .fno
    add eax, [h264_maxfn]
.fno:
    mov [h264_pic_fno], eax
    movzx ecx, byte [edi + SPS_POCTYPE]
    test ecx, ecx
    jnz .t12

    movzx ecx, byte [edi + SPS_LOG2POC]
    mov ebx, 1
    shl ebx, cl
    mov eax, [h264_pic_poclsb]
    mov edx, [h264_prev_poclsb]
    mov esi, [h264_prev_pocmsb]
    cmp eax, edx
    jge .t0b
    mov ecx, edx
    sub ecx, eax
    shr ebx, 1
    cmp ecx, ebx
    jl .t0d
    shl ebx, 1
    add esi, ebx
    jmp .t0d
.t0b:
    je .t0d
    mov ecx, eax
    sub ecx, edx
    shr ebx, 1
    cmp ecx, ebx
    jle .t0d
    shl ebx, 1
    sub esi, ebx
.t0d:
    mov [h264_pic_pocmsb], esi
    add eax, esi
    mov [h264_pic_top], eax
    add eax, [h264_pic_dpb]
    mov [h264_pic_bot], eax
    jmp .min
.t12:
    cmp ecx, 1
    jne .t2

    mov ebx, [edi + SPS_NCYCLE]
    xor esi, esi
    test ebx, ebx
    jz .t1a
    mov esi, [h264_pic_fno]
    add esi, [h264_pic_fn]
.t1a:
    cmp dword [h264_pic_refidc], 0
    jne .t1b
    test esi, esi
    jz .t1b
    dec esi
.t1b:
    xor ecx, ecx
    test esi, esi
    jz .t1c
    lea eax, [esi - 1]
    xor edx, edx
    div ebx
    imul eax, [edi + SPS_EXPDELTA]
    mov ecx, eax
    xor eax, eax
.t1s:
    add ecx, [edi + SPS_OFFREF + eax * 4]
    inc eax
    cmp eax, edx
    jbe .t1s
.t1c:
    cmp dword [h264_pic_refidc], 0
    jne .t1d
    add ecx, [edi + SPS_OFFNR]
.t1d:
    add ecx, [h264_pic_dpoc0]
    mov [h264_pic_top], ecx
    add ecx, [edi + SPS_OFFTB]
    add ecx, [h264_pic_dpoc1]
    mov [h264_pic_bot], ecx
    jmp .min
.t2:

    xor eax, eax
    cmp dword [h264_pic_idr], 0
    jne .t2d
    mov eax, [h264_pic_fno]
    add eax, [h264_pic_fn]
    shl eax, 1
    cmp dword [h264_pic_refidc], 0
    jne .t2d
    dec eax
.t2d:
    mov [h264_pic_top], eax
    mov [h264_pic_bot], eax
.min:
    mov eax, [h264_pic_top]
    mov edx, [h264_pic_bot]
    cmp edx, eax
    jge .m
    mov eax, edx
.m: mov [h264_pic_poc], eax
    pop edi
    pop esi
    pop ebx
    ret

h264_fill_gap:
    push ebx
    push esi
    push edi
    mov eax, [h264_sh_fn]
    sub eax, [h264_prev_reffn]
    dec eax
    mov edx, [h264_maxfn]
    dec edx
    and eax, edx
    mov edi, [h264_asps]
    movzx ecx, byte [edi + SPS_NREF]
    cmp ecx, 1
    jae .n1
    mov ecx, 1
.n1:
    cmp eax, ecx
    jbe .n2
    mov eax, ecx
.n2:
    mov ebx, eax
    test ebx, ebx
    jz .done
.one:
    mov eax, [h264_sh_fn]
    sub eax, ebx
    mov edx, [h264_maxfn]
    dec edx
    and eax, edx
    mov [h264_pic_fn], eax
    mov dword [h264_pic_idr], 0
    mov dword [h264_pic_refidc], 1
    xor eax, eax
    mov [h264_pic_dpoc0], eax
    mov [h264_pic_dpoc1], eax
    mov [h264_pic_dpb], eax
    mov eax, [h264_prev_poclsb]
    mov [h264_pic_poclsb], eax
    call h264_compute_poc
    call h264_alloc_slot
    mov esi, eax
    SLOTP esi
    mov eax, [h264_pic_fn]
    mov [esi + SL_FN], eax
    mov eax, [h264_pic_poc]
    mov [esi + SL_POC], eax
    mov dword [esi + SL_FLAGS], F_NONEX | F_BAD

    push ebx
    mov ebx, esi
    mov eax, [h264_lastref]
    call h264_copy_frame
    pop ebx

    call h264_calc_fnw
    call h264_sliding
    or dword [esi + SL_FLAGS], F_SHORT
    mov eax, [h264_pic_fn]
    mov [h264_prev_fn], eax
    mov [h264_prev_reffn], eax
    mov eax, [h264_pic_fno]
    mov [h264_prev_fno], eax
    sub esi, h264_slots
    mov eax, esi
    xor edx, edx
    mov ecx, SL_SZ
    div ecx
    mov [h264_lastref], eax
    dec ebx
    jnz .one
.done:
    pop edi
    pop esi
    pop ebx
    ret

h264_copy_frame:
    push esi
    push edi
    push ebp
    test eax, eax
    js .grey
    cmp eax, H264_NSLOT
    jae .grey
    mov esi, eax
    SLOTP esi
    test dword [esi + SL_FLAGS], F_REF
    jz .grey
    cmp esi, ebx
    je .done

    mov ebp, 3
    xor edx, edx
.plane:
    push esi
    mov esi, [esi + edx]
    mov edi, [ebx + edx]
    mov ecx, [h264_ystride]
    mov eax, H264_PADY
    test edx, edx
    jz .py
    mov ecx, [h264_cstride]
    mov eax, H264_PADC
.py:
    push edx
    imul ecx, eax
    add ecx, eax
    sub esi, ecx
    sub edi, ecx
    mov ecx, [h264_ysize]
    test edx, edx
    jz .pz
    mov ecx, [h264_csize]
.pz:
    shr ecx, 2
    rep movsd
    pop edx
    pop esi
    add edx, 4
    dec ebp
    jnz .plane
    jmp .done
.grey:
    mov ebp, 3
    xor edx, edx
.gplane:
    mov edi, [ebx + edx]
    mov ecx, [h264_ystride]
    mov eax, H264_PADY
    test edx, edx
    jz .gy
    mov ecx, [h264_cstride]
    mov eax, H264_PADC
.gy:
    imul ecx, eax
    add ecx, eax
    sub edi, ecx
    mov ecx, [h264_ysize]
    test edx, edx
    jz .gz
    mov ecx, [h264_csize]
.gz:
    shr ecx, 2
    mov eax, 0x80808080
    rep stosd
    add edx, 4
    dec ebp
    jnz .gplane
.done:
    pop ebp
    pop edi
    pop esi
    ret

h264_alloc_slot:
    push ebx
.again:
    xor eax, eax
    mov ebx, h264_slots
.l: test dword [ebx + SL_FLAGS], F_BUSY
    jz .found
    add ebx, SL_SZ
    inc eax
    cmp eax, H264_NSLOT
    jb .l

    cmp dword [h264_fifo_n], 0
    je .nofifo
    mov eax, [h264_fifo]
    SLOTP eax
    and dword [eax + SL_FLAGS], ~F_FIFO
    push esi
    push edi
    mov esi, h264_fifo + 4
    mov edi, h264_fifo
    mov ecx, H264_NSLOT - 1
    rep movsd
    pop edi
    pop esi
    dec dword [h264_fifo_n]
    jmp .again
.nofifo:
    xor eax, eax
    mov ebx, h264_slots
.w: test dword [ebx + SL_FLAGS], F_WAIT
    jnz .wf
    add ebx, SL_SZ
    inc eax
    cmp eax, H264_NSLOT
    jb .w

    call h264_calc_fnw
    call h264_drop_oldest_short
    test eax, eax
    jz .again

    mov ebx, h264_slots
    mov dword [ebx + SL_FLAGS], 0
    xor eax, eax
    jmp .found
.wf:
    and dword [ebx + SL_FLAGS], ~F_WAIT
    jmp .again
.found:
    mov dword [ebx + SL_FLAGS], 0
    pop ebx
    ret

h264_calc_fnw:
    push ebx
    mov ebx, h264_slots
.l: test dword [ebx + SL_FLAGS], F_SHORT
    jz .n
    mov eax, [ebx + SL_FN]
    cmp eax, [h264_pic_fn]
    jbe .s
    sub eax, [h264_maxfn]
.s: mov [ebx + SL_FNW], eax
.n: add ebx, SL_SZ
    cmp ebx, h264_slots + H264_NSLOT * SL_SZ
    jb .l
    pop ebx
    ret

h264_drop_oldest_short:
    push ebx
    push esi
    xor esi, esi
    mov ebx, h264_slots
.l: test dword [ebx + SL_FLAGS], F_SHORT
    jz .n
    test esi, esi
    jz .take
    mov eax, [ebx + SL_FNW]
    cmp eax, [esi + SL_FNW]
    jge .n
.take:
    mov esi, ebx
.n: add ebx, SL_SZ
    cmp ebx, h264_slots + H264_NSLOT * SL_SZ
    jb .l
    or eax, -1
    test esi, esi
    jz .r
    and dword [esi + SL_FLAGS], ~F_SHORT
    xor eax, eax
.r: pop esi
    pop ebx
    ret

h264_count_refs:
    push ebx
    xor eax, eax
    mov ebx, h264_slots
.l: test dword [ebx + SL_FLAGS], F_REF
    jz .n
    inc eax
.n: add ebx, SL_SZ
    cmp ebx, h264_slots + H264_NSLOT * SL_SZ
    jb .l
    pop ebx
    ret

h264_sliding:
    push ebx
    mov ebx, [h264_asps]
    movzx ebx, byte [ebx + SPS_NREF]
    cmp ebx, 1
    jae .l
    mov ebx, 1
.l: call h264_count_refs
    cmp eax, ebx
    jb .r
    call h264_drop_oldest_short
    test eax, eax
    jz .l
.r: pop ebx
    ret

h264_unmark_all:
    xor ecx, ecx
.l: and dword [h264_slots + ecx + SL_FLAGS], ~F_REF
    add ecx, SL_SZ
    cmp ecx, H264_NSLOT * SL_SZ
    jb .l
    mov dword [h264_maxltidx], -1
    ret

h264_bump:
    push ebx
    push esi
    xor esi, esi
    mov ebx, h264_slots
.l: test dword [ebx + SL_FLAGS], F_WAIT
    jz .n
    test esi, esi
    jz .take
    mov eax, [ebx + SL_POC]
    cmp eax, [esi + SL_POC]
    jge .n
.take:
    mov esi, ebx
.n: add ebx, SL_SZ
    cmp ebx, h264_slots + H264_NSLOT * SL_SZ
    jb .l
    or eax, -1
    test esi, esi
    jz .r
    mov eax, [esi + SL_FLAGS]
    and eax, ~F_WAIT
    or eax, F_FIFO
    mov [esi + SL_FLAGS], eax
    sub esi, h264_slots
    mov eax, esi
    xor edx, edx
    mov ecx, SL_SZ
    div ecx
    mov ecx, [h264_fifo_n]
    cmp ecx, H264_NSLOT
    jae .full
    mov [h264_fifo + ecx * 4], eax
    inc dword [h264_fifo_n]
    xor eax, eax
    jmp .r
.full:
    SLOTP eax
    and dword [eax + SL_FLAGS], ~F_FIFO
    xor eax, eax
.r: pop esi
    pop ebx
    ret

h264_output_all:
    mov ecx, H264_NSLOT + 1
.l: push ecx
    call h264_bump
    pop ecx
    test eax, eax
    jnz .r
    dec ecx
    jnz .l
.r: ret

h264_finish_pic:
    cmp dword [h264_pic_on], 0
    jne .go
    ret
.go:
    push ebx
    push esi
    push edi
    push ebp
    mov dword [h264_pic_on], 0
    mov ebx, [h264_cur]
    SLOTP ebx
    mov eax, [h264_pic_done]
    cmp eax, [h264_nmb]
    jae .whole
    call h264_conceal
    or dword [ebx + SL_FLAGS], F_BAD
.whole:
    cmp dword [h264_pic_err], 0
    je .ok
    or dword [ebx + SL_FLAGS], F_BAD
.ok:
    call h264_deblock_pic
    call h264_extend

    xor ebp, ebp
    cmp dword [h264_pic_refidc], 0
    je .marked
    call h264_calc_fnw
    cmp dword [h264_pic_idr], 0
    je .nonidr
    cmp dword [h264_pic_ltref], 0
    je .idrshort
    or dword [ebx + SL_FLAGS], F_LONG
    mov dword [ebx + SL_LT], 0
    mov dword [h264_maxltidx], 0
    jmp .marked
.idrshort:
    or dword [ebx + SL_FLAGS], F_SHORT
    mov dword [h264_maxltidx], -1
    jmp .marked
.nonidr:
    cmp dword [h264_pic_adapt], 0
    je .slide
    call h264_mmco
    mov ebp, eax
    test dword [ebx + SL_FLAGS], F_LONG
    jnz .check
    or dword [ebx + SL_FLAGS], F_SHORT
.check:

    mov eax, [h264_asps]
    movzx ecx, byte [eax + SPS_NREF]
    cmp ecx, 1
    jae .c1
    mov ecx, 1
.c1:
    mov [h264_ltflag], ecx
.c2:
    call h264_count_refs
    cmp eax, [h264_ltflag]
    jbe .marked
    mov edx, [ebx + SL_FLAGS]
    push edx
    and dword [ebx + SL_FLAGS], ~F_REF
    call h264_drop_oldest_short
    test eax, eax
    jz .c3
    call h264_drop_longest
.c3:
    pop edx
    mov [ebx + SL_FLAGS], edx
    jmp .c2
.slide:
    call h264_sliding
    or dword [ebx + SL_FLAGS], F_SHORT
.marked:

    test ebp, ebp
    jz .poc
    mov eax, [h264_pic_top]
    mov edx, [h264_pic_bot]
    cmp edx, eax
    jge .p1
    mov eax, edx
.p1:
    sub [h264_pic_top], eax
    sub [h264_pic_bot], eax
    mov eax, [h264_pic_top]
    mov edx, [h264_pic_bot]
    cmp edx, eax
    jge .p2
    mov eax, edx
.p2:
    mov [h264_pic_poc], eax
    mov [ebx + SL_POC], eax
.poc:

    mov eax, [h264_pic_fno]
    mov edx, [h264_pic_fn]
    test ebp, ebp
    jz .h1
    xor eax, eax
    xor edx, edx
.h1:
    mov [h264_prev_fno], eax
    mov [h264_prev_fn], edx
    cmp dword [h264_pic_refidc], 0
    je .h2
    mov [h264_prev_reffn], edx
    mov dword [h264_have_ref], 1
    mov eax, [h264_pic_pocmsb]
    mov edx, [h264_pic_poclsb]
    test ebp, ebp
    jz .h3
    xor eax, eax
    mov edx, [h264_pic_top]
.h3:
    mov [h264_prev_pocmsb], eax
    mov [h264_prev_poclsb], edx
    mov eax, [h264_cur]
    mov [h264_lastref], eax
.h2:

    test ebp, ebp
    jz .o1
    call h264_output_all
.o1:
    mov eax, [ebx + SL_FLAGS]
    and eax, ~F_CUR
    or eax, F_WAIT
    mov [ebx + SL_FLAGS], eax

.o2:
    xor ecx, ecx
    xor edx, edx
    mov esi, h264_slots
.o3:
    mov eax, [esi + SL_FLAGS]
    test eax, F_WAIT
    jz .o4
    inc edx
.o4:
    test eax, F_WAIT | F_REF
    jz .o5
    inc ecx
.o5:
    add esi, SL_SZ
    cmp esi, h264_slots + H264_NSLOT * SL_SZ
    jb .o3
    cmp edx, [h264_reorder]
    ja .bump

    cmp ecx, [h264_dpbsize]
    jbe .o6
    test edx, edx
    jz .o6
.bump:
    call h264_bump
    test eax, eax
    jz .o2
.o6:
    mov dword [h264_cur], -1
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

section .bss
h264_ltflag     resd 1
section .text

h264_drop_longest:
    push ebx
    push esi
    xor esi, esi
    mov ebx, h264_slots
.l: test dword [ebx + SL_FLAGS], F_LONG
    jz .n
    test esi, esi
    jz .t
    mov eax, [ebx + SL_LT]
    cmp eax, [esi + SL_LT]
    jle .n
.t: mov esi, ebx
.n: add ebx, SL_SZ
    cmp ebx, h264_slots + H264_NSLOT * SL_SZ
    jb .l
    test esi, esi
    jz .r
    and dword [esi + SL_FLAGS], ~F_LONG
.r: pop esi
    pop ebx
    ret

h264_find_short:
    push ebx
    mov ebx, h264_slots
.l: test dword [ebx + SL_FLAGS], F_SHORT
    jz .n
    cmp [ebx + SL_FNW], eax
    je .f
.n: add ebx, SL_SZ
    cmp ebx, h264_slots + H264_NSLOT * SL_SZ
    jb .l
    xor eax, eax
    pop ebx
    ret
.f: mov eax, ebx
    pop ebx
    ret

h264_find_long:
    push ebx
    mov ebx, h264_slots
.l: test dword [ebx + SL_FLAGS], F_LONG
    jz .n
    cmp [ebx + SL_LT], eax
    je .f
.n: add ebx, SL_SZ
    cmp ebx, h264_slots + H264_NSLOT * SL_SZ
    jb .l
    xor eax, eax
    pop ebx
    ret
.f: mov eax, ebx
    pop ebx
    ret

h264_mmco:
    push esi
    push edi
    push ebp
    xor ebp, ebp
    mov dword [h264_ltflag], 0
    xor esi, esi
.op:
    cmp esi, [h264_pic_nmmco]
    jae .done
    imul edi, esi, 12
    add edi, h264_pic_mmco
    mov eax, [edi]
    cmp eax, 1
    je .op1
    cmp eax, 2
    je .op2
    cmp eax, 3
    je .op3
    cmp eax, 4
    je .op4
    cmp eax, 5
    je .op5

    mov eax, [edi + 4]
    cmp eax, [h264_maxltidx]
    jg .next
    push eax
    call h264_find_long
    test eax, eax
    jz .o6a
    cmp eax, ebx
    je .o6a
    and dword [eax + SL_FLAGS], ~F_LONG
.o6a:
    pop eax
    mov [ebx + SL_LT], eax
    and dword [ebx + SL_FLAGS], ~F_SHORT
    or dword [ebx + SL_FLAGS], F_LONG
    mov dword [h264_ltflag], 1
    jmp .next
.op1:
    mov eax, [h264_pic_fn]
    sub eax, [edi + 4]
    dec eax
    call h264_find_short
    test eax, eax
    jz .next
    and dword [eax + SL_FLAGS], ~F_SHORT
    jmp .next
.op2:
    mov eax, [edi + 4]
    call h264_find_long
    test eax, eax
    jz .next
    and dword [eax + SL_FLAGS], ~F_LONG
    jmp .next
.op3:
    mov eax, [edi + 8]
    cmp eax, [h264_maxltidx]
    jg .next
    mov eax, [h264_pic_fn]
    sub eax, [edi + 4]
    dec eax
    call h264_find_short
    test eax, eax
    jz .next
    push eax
    mov eax, [edi + 8]
    call h264_find_long
    test eax, eax
    jz .o3a
    and dword [eax + SL_FLAGS], ~F_LONG
.o3a:
    pop eax
    mov ecx, [edi + 8]
    mov [eax + SL_LT], ecx
    mov ecx, [eax + SL_FLAGS]
    and ecx, ~F_SHORT
    or ecx, F_LONG
    mov [eax + SL_FLAGS], ecx
    jmp .next
.op4:
    mov eax, [edi + 4]
    dec eax
    mov [h264_maxltidx], eax
    mov ecx, h264_slots
.o4l:
    test dword [ecx + SL_FLAGS], F_LONG
    jz .o4n
    cmp ecx, ebx
    je .o4n
    cmp [ecx + SL_LT], eax
    jle .o4n
    and dword [ecx + SL_FLAGS], ~F_LONG
.o4n:
    add ecx, SL_SZ
    cmp ecx, h264_slots + H264_NSLOT * SL_SZ
    jb .o4l
    jmp .next
.op5:
    mov ecx, h264_slots
.o5l:
    cmp ecx, ebx
    je .o5n
    and dword [ecx + SL_FLAGS], ~F_REF
.o5n:
    add ecx, SL_SZ
    cmp ecx, h264_slots + H264_NSLOT * SL_SZ
    jb .o5l
    mov dword [h264_maxltidx], -1
    mov ebp, 1
.next:
    inc esi
    jmp .op
.done:
    mov eax, ebp
    pop ebp
    pop edi
    pop esi
    ret

h264_build_lists:
    push ebx
    push esi
    push edi
    push ebp
    call h264_calc_fnw
    cmp dword [h264_sh_type], ST_B
    je .b

    xor edi, edi
    xor ebx, ebx
.s: mov esi, ebx
    SLOTP esi
    mov eax, [esi + SL_FLAGS]
    and eax, F_SHORT | F_CUR
    cmp eax, F_SHORT
    jne .snext
    mov eax, [esi + SL_FNW]
    mov ecx, edi
.sins:
    test ecx, ecx
    jz .sput
    movzx edx, byte [h264_list0 + ecx - 1]
    SLOTP edx
    cmp [edx + SL_FNW], eax
    jge .sput
    mov dl, [h264_list0 + ecx - 1]
    mov [h264_list0 + ecx], dl
    dec ecx
    jmp .sins
.sput:
    mov [h264_list0 + ecx], bl
    inc edi
.snext:
    inc ebx
    cmp ebx, H264_NSLOT
    jb .s
    mov esi, h264_list0
    call h264_add_long
    mov ecx, edi
    mov edi, h264_list0
    call h264_pad_list
    jmp .modify
.b:
    xor edi, edi
    xor ebx, ebx
.bs:
    mov esi, ebx
    SLOTP esi
    mov eax, [esi + SL_FLAGS]
    and eax, F_SHORT | F_CUR
    cmp eax, F_SHORT
    jne .bsnext
    mov eax, [esi + SL_POC]
    mov ecx, edi
.bsins:
    test ecx, ecx
    jz .bsput
    movzx edx, byte [h264_lt_tmp + ecx - 1]
    SLOTP edx
    cmp [edx + SL_POC], eax
    jle .bsput
    mov dl, [h264_lt_tmp + ecx - 1]
    mov [h264_lt_tmp + ecx], dl
    dec ecx
    jmp .bsins
.bsput:
    mov [h264_lt_tmp + ecx], bl
    inc edi
.bsnext:
    inc ebx
    cmp ebx, H264_NSLOT
    jb .bs

    xor ebp, ebp
.bf:
    cmp ebp, edi
    jae .bfd
    movzx eax, byte [h264_lt_tmp + ebp]
    SLOTP eax
    mov eax, [eax + SL_POC]
    cmp eax, [h264_pic_poc]
    jge .bfd
    inc ebp
    jmp .bf
.bfd:

    xor ecx, ecx
    mov edx, ebp
.l0a:
    test edx, edx
    jz .l0b
    dec edx
    mov al, [h264_lt_tmp + edx]
    mov [h264_list0 + ecx], al
    inc ecx
    jmp .l0a
.l0b:
    mov edx, ebp
.l0c:
    cmp edx, edi
    jae .l1
    mov al, [h264_lt_tmp + edx]
    mov [h264_list0 + ecx], al
    inc ecx
    inc edx
    jmp .l0c
.l1:

    xor ecx, ecx
    mov edx, ebp
.l1a:
    cmp edx, edi
    jae .l1b
    mov al, [h264_lt_tmp + edx]
    mov [h264_list1 + ecx], al
    inc ecx
    inc edx
    jmp .l1a
.l1b:
    mov edx, ebp
.l1c:
    test edx, edx
    jz .l1d
    dec edx
    mov al, [h264_lt_tmp + edx]
    mov [h264_list1 + ecx], al
    inc ecx
    jmp .l1c
.l1d:

    push edi
    mov esi, h264_list0
    call h264_add_long
    pop edi
    mov esi, h264_list1
    call h264_add_long

    cmp edi, 1
    jbe .noswap
    xor ecx, ecx
.cmpl:
    mov al, [h264_list0 + ecx]
    cmp al, [h264_list1 + ecx]
    jne .noswap
    inc ecx
    cmp ecx, edi
    jb .cmpl
    mov al, [h264_list1]
    mov ah, [h264_list1 + 1]
    mov [h264_list1], ah
    mov [h264_list1 + 1], al
.noswap:
    mov ecx, edi
    push ecx
    mov edi, h264_list0
    call h264_pad_list
    pop ecx
    mov edi, h264_list1
    call h264_pad_list
.modify:

    mov edi, h264_list0
    mov eax, [h264_sh_nref0]
    mov [h264_ml_n], eax
    mov eax, [h264_sh_nrplm0]
    mov [h264_ml_nm], eax
    mov dword [h264_ml_m], h264_sh_rplm0
    call h264_modify_list
    mov ebp, eax
    cmp dword [h264_sh_type], ST_B
    jne .done
    mov edi, h264_list1
    mov eax, [h264_sh_nref1]
    mov [h264_ml_n], eax
    mov eax, [h264_sh_nrplm1]
    mov [h264_ml_nm], eax
    mov dword [h264_ml_m], h264_sh_rplm1
    call h264_modify_list
    or ebp, eax
.done:
    mov eax, ebp
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

h264_add_long:
    push ebp
    mov ebp, edi
    xor ebx, ebx
.l: mov eax, ebx
    SLOTP eax
    mov ecx, [eax + SL_FLAGS]
    and ecx, F_LONG | F_CUR
    cmp ecx, F_LONG
    jne .next
    mov eax, [eax + SL_LT]
    mov ecx, edi
.ins:
    cmp ecx, ebp
    jbe .put
    movzx edx, byte [esi + ecx - 1]
    SLOTP edx
    cmp [edx + SL_LT], eax
    jle .put
    mov dl, [esi + ecx - 1]
    mov [esi + ecx], dl
    dec ecx
    jmp .ins
.put:
    mov [esi + ecx], bl
    inc edi
.next:
    inc ebx
    cmp ebx, H264_NSLOT
    jb .l
    pop ebp
    ret

h264_pad_list:
.l: cmp ecx, 33
    jae .r
    mov byte [edi + ecx], 255
    inc ecx
    jmp .l
.r: ret

h264_modify_list:
    push ebx
    push esi
    push edi
    push ebp
    mov [h264_ml_list], edi
    xor ebp, ebp
    mov eax, [h264_pic_fn]
    mov [h264_tmpi], eax
    xor esi, esi
    xor ebx, ebx
.mod:
    cmp ebx, [h264_ml_nm]
    jae .moddone
    cmp esi, [h264_ml_n]
    jae .modbad
    mov edx, [h264_ml_m]
    mov eax, [edx + ebx * 8]
    mov ecx, [edx + ebx * 8 + 4]
    cmp eax, 2
    je .modlong
    inc ecx
    cmp ecx, [h264_maxfn]
    ja .modbad
    mov edx, [h264_tmpi]
    test eax, eax
    jnz .add
    sub edx, ecx
    jns .pn
    add edx, [h264_maxfn]
    jmp .pn
.add:
    add edx, ecx
    cmp edx, [h264_maxfn]
    jb .pn
    sub edx, [h264_maxfn]
.pn:
    mov [h264_tmpi], edx
    cmp edx, [h264_pic_fn]
    jle .pn2
    sub edx, [h264_maxfn]
.pn2:
    mov eax, edx
    mov [h264_tmpi + 4], eax
    call h264_find_short
    mov edx, 0
    jmp .insert
.modlong:
    mov eax, ecx
    mov [h264_tmpi + 4], eax
    call h264_find_long
    mov edx, 1
.insert:

    mov edi, 255
    test eax, eax
    jz .ins0
    sub eax, h264_slots
    push edx
    xor edx, edx
    mov ecx, SL_SZ
    div ecx
    pop edx
    mov edi, eax
    jmp .ins1
.ins0:
    mov ebp, 1
.ins1:
    push ebx
    mov ebx, [h264_ml_list]
    mov ecx, [h264_ml_n]
.sh:
    cmp ecx, esi
    jbe .shd
    mov al, [ebx + ecx - 1]
    mov [ebx + ecx], al
    dec ecx
    jmp .sh
.shd:
    mov eax, edi
    mov [ebx + esi], al
    inc esi
    mov edi, esi
    mov ecx, esi
.cmp:
    cmp ecx, [h264_ml_n]
    ja .cmpd
    movzx eax, byte [ebx + ecx]
    cmp eax, 255
    je .keep
    push ecx
    SLOTP eax
    mov ecx, [h264_tmpi + 4]
    test edx, edx
    jnz .cl
    test dword [eax + SL_FLAGS], F_SHORT
    jz .keep0
    cmp [eax + SL_FNW], ecx
    jne .keep0
    pop ecx
    jmp .drop
.cl:
    test dword [eax + SL_FLAGS], F_LONG
    jz .keep0
    cmp [eax + SL_LT], ecx
    jne .keep0
    pop ecx
    jmp .drop
.keep0:
    pop ecx
.keep:
    mov al, [ebx + ecx]
    mov [ebx + edi], al
    inc edi
.drop:
    inc ecx
    jmp .cmp
.cmpd:
    pop ebx
    inc ebx
    jmp .mod
.modbad:
    mov ebp, 1
.moddone:

    mov edi, [h264_ml_list]
    xor ecx, ecx
.f1:
    movzx eax, byte [edi + ecx]
    cmp eax, 255
    jne .fill
    inc ecx
    cmp ecx, [h264_ml_n]
    jb .f1
    mov eax, [h264_lastref]
    test eax, eax
    jns .fill
    mov eax, [h264_cur]
.fill:
    xor ecx, ecx
.f2:
    cmp byte [edi + ecx], 255
    jne .f3
    mov [edi + ecx], al
    cmp ecx, [h264_ml_n]
    jae .f3
    mov ebp, 1
.f3:
    inc ecx
    cmp ecx, 33
    jb .f2
    mov eax, ebp
    neg eax
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

section .bss
alignb 4
h264_ml_list    resd 1
h264_ml_n       resd 1
h264_ml_nm      resd 1
h264_ml_m       resd 1
section .text

h264_conceal:
    push ebx
    push esi
    push edi
    push ebp
    xor ebp, ebp
    xor ebx, ebx
    mov dword [h264_tmpi], 0
.mb:
    mov esi, ebp
    shl esi, MI_SHIFT
    add esi, [h264_mbi]
    mov eax, [esi + MI_SLICE]
    cmp eax, [h264_pic_slice0]
    jae .next

    mov dword [esi + MI_SLICE], 0
    mov dword [esi + MI_TYPE], 0x1A1A1A00
    lea edi, [esi + MI_NNZ]
    xor eax, eax
    mov ecx, 6
    rep stosd
    mov byte [esi + MI_DBIDC], 1
    mov eax, [h264_cur]
    SLOTP eax
    mov edi, ebp
    imul edi, MO_SZ
    add edi, [eax + SL_MOT]
    push edi
    xor eax, eax
    mov ecx, 128 / 4
    rep stosd
    pop edi
    mov eax, [h264_pic_conceal]
    test eax, eax
    jns .rs
    mov eax, [h264_cur]
.rs:
    mov ah, al
    mov ecx, eax
    shl eax, 16
    mov ax, cx
    mov dword [edi + MO_REF0], 0
    mov dword [edi + MO_REF1], -1
    mov [edi + MO_RS0], eax
    mov dword [edi + MO_RS1], -1
    mov dword [edi + MO_INTRA], 0

    mov eax, [h264_pic_conceal]
    mov edx, [h264_tmpi]
    call h264_conceal_mb
.next:
    inc ebp
    inc ebx
    cmp ebx, [h264_mbw]
    jb .n2
    xor ebx, ebx
    inc dword [h264_tmpi]
.n2:
    cmp ebp, [h264_nmb]
    jb .mb
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

h264_conceal_mb:
    push ebx
    push esi
    push edi
    push ebp
    mov ebp, eax
    mov edi, [h264_cur]
    SLOTP edi

    mov eax, edx
    shl eax, 4
    imul eax, [h264_ystride]
    mov ecx, ebx
    shl ecx, 4
    add eax, ecx
    push edx
    mov edx, [h264_ystride]
    mov esi, -1
    test ebp, ebp
    js .g1
    mov esi, ebp
    SLOTP esi
    mov esi, [esi + SL_Y]
    add esi, eax
.g1:
    add eax, [edi + SL_Y]
    push edi
    mov edi, eax
    mov ecx, 16
    call h264_copy_block16
    pop edi
    pop edx

    mov eax, edx
    shl eax, 3
    imul eax, [h264_cstride]
    mov ecx, ebx
    shl ecx, 3
    add eax, ecx
    mov edx, [h264_cstride]
    mov ebx, SL_U
.c:
    mov esi, -1
    test ebp, ebp
    js .g2
    mov esi, ebp
    SLOTP esi
    mov esi, [esi + ebx]
    add esi, eax
.g2:
    push edi
    push eax
    add eax, [edi + ebx]
    mov edi, eax
    mov ecx, 8
    call h264_copy_block8
    pop eax
    pop edi
    add ebx, 4
    cmp ebx, SL_V
    jbe .c
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

h264_copy_block16:
.l: cmp esi, -1
    je .g
    mov eax, [esi]
    mov [edi], eax
    mov eax, [esi + 4]
    mov [edi + 4], eax
    mov eax, [esi + 8]
    mov [edi + 8], eax
    mov eax, [esi + 12]
    mov [edi + 12], eax
    add esi, edx
    jmp .n
.g: mov eax, 0x80808080
    mov [edi], eax
    mov [edi + 4], eax
    mov [edi + 8], eax
    mov [edi + 12], eax
.n: add edi, edx
    dec ecx
    jnz .l
    ret
h264_copy_block8:
.l: cmp esi, -1
    je .g
    mov eax, [esi]
    mov [edi], eax
    mov eax, [esi + 4]
    mov [edi + 4], eax
    add esi, edx
    jmp .n
.g: mov eax, 0x80808080
    mov [edi], eax
    mov [edi + 4], eax
.n: add edi, edx
    dec ecx
    jnz .l
    ret

h264_extend:
    push ebx
    push esi
    push edi
    push ebp
    mov ebx, [h264_cur]
    SLOTP ebx
    mov esi, [ebx + SL_Y]
    mov ecx, [h264_mbw]
    shl ecx, 4
    mov edx, [h264_mbh]
    shl edx, 4
    mov eax, H264_PADY
    mov ebp, [h264_ystride]
    call h264_extend_plane
    mov ecx, [h264_mbw]
    shl ecx, 3
    mov edx, [h264_mbh]
    shl edx, 3
    mov esi, [ebx + SL_U]
    mov eax, H264_PADC
    mov ebp, [h264_cstride]
    push ecx
    push edx
    call h264_extend_plane
    pop edx
    pop ecx
    mov esi, [ebx + SL_V]
    mov eax, H264_PADC
    mov ebp, [h264_cstride]
    call h264_extend_plane
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

h264_extend_plane:
    push ebx
    mov [h264_ext_b], eax
    mov [h264_ext_w], ecx
    mov [h264_ext_p], esi
    mov ebx, edx
.row:
    movzx eax, byte [esi]
    imul eax, 0x01010101
    mov edi, esi
    sub edi, [h264_ext_b]
    mov ecx, [h264_ext_b]
    shr ecx, 2
    rep stosd
    mov edi, esi
    add edi, [h264_ext_w]
    movzx eax, byte [edi - 1]
    imul eax, 0x01010101
    mov ecx, [h264_ext_b]
    shr ecx, 2
    rep stosd
    add esi, ebp
    dec ebx
    jnz .row
    sub esi, ebp
    sub esi, [h264_ext_b]
    mov eax, [h264_ext_b]
    shl eax, 1
    add eax, [h264_ext_w]
    shr eax, 2
    mov edi, esi
    mov ebx, [h264_ext_b]
.down:
    add edi, ebp
    push esi
    push edi
    mov ecx, eax
    rep movsd
    pop edi
    pop esi
    dec ebx
    jnz .down
    mov esi, [h264_ext_p]
    sub esi, [h264_ext_b]
    mov edi, esi
    mov ebx, [h264_ext_b]
.up:
    sub edi, ebp
    push esi
    push edi
    mov ecx, eax
    rep movsd
    pop edi
    pop esi
    dec ebx
    jnz .up
    pop ebx
    ret

section .bss
alignb 4
h264_ext_b      resd 1
h264_ext_w      resd 1
h264_ext_p      resd 1
section .text
