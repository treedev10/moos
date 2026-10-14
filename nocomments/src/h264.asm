%include "src/module.inc"

%ifdef H264DEBUG
extern h264_dbg_print
%macro DBG 5
    pushad
    pushfd
    push dword %5
    push dword %4
    push dword %3
    push dword %2
    push dword %1
    call h264_dbg_print
    add esp, 20
    popfd
    popad
%endmacro
%else
%macro DBG 5
%endmacro
%endif

H264F_Y         equ 0
H264F_U         equ 4
H264F_V         equ 8
H264F_YSTRIDE   equ 12
H264F_CSTRIDE   equ 16
H264F_W         equ 20
H264F_H         equ 24
H264F_POC       equ 28
H264F_FLAGS     equ 32
H264F_SARW      equ 36
H264F_SARH      equ 40
H264F_SIZE      equ 44
H264F_YS        equ H264F_YSTRIDE
H264F_CS        equ H264F_CSTRIDE

H264_NSLOT      equ 18
H264_MAXMBW     equ 256
H264_MAXMBH     equ 256
H264_MAXNMB     equ 36864
H264_PADY       equ 32
H264_PADC       equ 16
H264_MAXMMCO    equ 40
H264_MAXRPLM    equ 34
H264_RBSPPAD    equ 512

SPS_VALID       equ 0
SPS_PROFILE     equ 1
SPS_LEVEL       equ 2
SPS_CHROMA      equ 3
SPS_LOG2FN      equ 4
SPS_POCTYPE     equ 5
SPS_LOG2POC     equ 6
SPS_DPOCZ       equ 7
SPS_NREF        equ 8
SPS_GAPS        equ 9
SPS_UNSUP       equ 10
SPS_SCALING     equ 11
SPS_NCYCLE      equ 12
SPS_OFFNR       equ 16
SPS_OFFTB       equ 20
SPS_MBW         equ 24
SPS_MBH         equ 28
SPS_CROPL       equ 32
SPS_CROPR       equ 36
SPS_CROPT       equ 40
SPS_CROPB       equ 44
SPS_REORDER     equ 48
SPS_MAXDEC      equ 52
SPS_SARW        equ 56
SPS_SARH        equ 60
SPS_EXPDELTA    equ 64
SPS_ID          equ 68
SPS_OFFREF      equ 72
SPS_D8I         equ 72 + 1024
SPS_SZ          equ 72 + 1024 + 4

PPS_VALID       equ 0
PPS_SPS         equ 1
PPS_CABAC       equ 2
PPS_BFPOC       equ 3
PPS_NSG         equ 4
PPS_NREF0       equ 5
PPS_NREF1       equ 6
PPS_WP          equ 7
PPS_WBI         equ 8
PPS_QP          equ 9
PPS_CQP         equ 10
PPS_CQP2        equ 11
PPS_DBK         equ 12
PPS_CIP         equ 13
PPS_RPC         equ 14
PPS_T8          equ 15
PPS_SGTYPE      equ 16
PPS_SGRATE      equ 20
PPS_SZ          equ 24

SL_Y            equ 0
SL_U            equ 4
SL_V            equ 8
SL_MOT          equ 12
SL_FLAGS        equ 16
SL_FN           equ 20
SL_FNW          equ 24
SL_LT           equ 28
SL_POC          equ 32
SL_W            equ 36
SL_H            equ 40
SL_CX           equ 44
SL_CY           equ 48
SL_ID           equ 52
SL_SARW         equ 56
SL_SARH         equ 60
SL_SZ           equ 64

F_SHORT         equ 1
F_LONG          equ 2
F_WAIT          equ 4
F_FIFO          equ 8
F_LENT          equ 16
F_CUR           equ 32
F_NONEX         equ 64
F_BAD           equ 128
F_IDR           equ 256
F_BUSY          equ F_SHORT | F_LONG | F_WAIT | F_FIFO | F_LENT | F_CUR
F_REF           equ F_SHORT | F_LONG

MO_MV0          equ 0
MO_MV1          equ 64
MO_REF0         equ 128
MO_REF1         equ 132
MO_RS0          equ 136
MO_RS1          equ 140
MO_INTRA        equ 144
MO_SZ           equ 160

MI_SLICE        equ 0

MI_TYPE         equ 4
MI_QP           equ 5
MI_QPC          equ 6
MI_QPC2         equ 7
MI_NNZ          equ 8
MI_I4M          equ 32
MI_DBIDC        equ 48
MI_DBA          equ 49
MI_DBB          equ 50
MI_SZ           equ 128
MI_SHIFT        equ 7

MT_INTRA        equ 1
MT_PCM          equ 2
MT_I4           equ 4
MT_I16          equ 8
MT_SKIP         equ 16
MT_DIRECT       equ 32

WT_SZ           equ 24

ST_P            equ 0
ST_B            equ 1
ST_I            equ 2

%include "src/h264_tab.inc"

section .bss
alignb 16
h264_S_begin:
h264_mem        resd 1
h264_memlen     resd 1
h264_maxmbw     resd 1
h264_maxmbh     resd 1
h264_maxnmb     resd 1
h264_ystride    resd 1
h264_cstride    resd 1
h264_ysize      resd 1
h264_csize      resd 1
h264_slotbytes  resd 1
h264_spstab     resd 1
h264_ppstab     resd 1
h264_asps       resd 1
h264_rbsp       resd 1
h264_rbspcap    resd 1
h264_mbi        resd 1
h264_slotmem    resd 1
h264_total      resd 1

h264_act        resd 1
h264_mbw        resd 1
h264_mbh        resd 1
h264_nmb        resd 1
h264_dpbsize    resd 1
h264_reorder    resd 1
h264_maxfn      resd 1

h264_slots      resb H264_NSLOT * SL_SZ
h264_fifo       resd H264_NSLOT
h264_fifo_n     resd 1

h264_cur        resd 1
h264_pic_on     resd 1
h264_pic_done   resd 1
h264_pic_slice0 resd 1
h264_pic_idr    resd 1
h264_pic_refidc resd 1
h264_pic_fn     resd 1
h264_pic_poclsb resd 1
h264_pic_dpb    resd 1
h264_pic_dpoc0  resd 1
h264_pic_dpoc1  resd 1
h264_pic_idrid  resd 1
h264_pic_ppsid  resd 1
h264_pic_noout  resd 1
h264_pic_ltref  resd 1
h264_pic_adapt  resd 1
h264_pic_nmmco  resd 1
h264_pic_mmco   resd 3 * H264_MAXMMCO
h264_pic_err    resd 1
h264_pic_poc    resd 1
h264_pic_top    resd 1
h264_pic_bot    resd 1
h264_pic_pocmsb resd 1
h264_pic_fno    resd 1
h264_pic_conceal resd 1

h264_prev_pocmsb resd 1
h264_prev_poclsb resd 1
h264_prev_fno   resd 1
h264_prev_fn    resd 1
h264_prev_reffn resd 1
h264_have_ref   resd 1
h264_maxltidx   resd 1
h264_slicectr   resd 1
h264_need_idr   resd 1
h264_picid      resd 1
h264_lastref    resd 1
alignb 4
h264_S_end:
H264_STATE_SZ   equ h264_S_end - h264_S_begin

alignb 4
h264_ctxp       resd 1
h264_bp         resd 1
h264_bbuf       resd 1
h264_bend       resd 1
h264_berr       resd 1
h264_nalref     resd 1
h264_naltype    resd 1

h264_sh_firstmb resd 1
h264_sh_type    resd 1
h264_sh_pps     resd 1
h264_sh_ppsid   resd 1
h264_sh_sps     resd 1
h264_sh_fn      resd 1
h264_sh_idr     resd 1
h264_sh_idrid   resd 1
h264_sh_poclsb  resd 1
h264_sh_dpb     resd 1
h264_sh_dpoc0   resd 1
h264_sh_dpoc1   resd 1
h264_sh_rpc     resd 1
h264_sh_dspat   resd 1
h264_sh_nref0   resd 1
h264_sh_nref1   resd 1
h264_sh_qp      resd 1
h264_sh_dbidc   resd 1
h264_sh_dba     resd 1
h264_sh_dbb     resd 1
h264_sh_cabinit resd 1
h264_sh_wmode   resd 1

h264_sh_lwd     resd 1
h264_sh_cwd     resd 1
h264_wt         resb 64 * WT_SZ
h264_wtf        resb 64
h264_sh_noout   resd 1
h264_sh_ltref   resd 1
h264_sh_adapt   resd 1
h264_sh_nmmco   resd 1
h264_sh_mmco    resd 3 * H264_MAXMMCO
h264_sh_nrplm0  resd 1
h264_sh_rplm0   resd 2 * H264_MAXRPLM
h264_sh_nrplm1  resd 1
h264_sh_rplm1   resd 2 * H264_MAXRPLM
h264_sh_cqp     resd 1
h264_sh_cqp2    resd 1
h264_sh_cip     resd 1
h264_slicenum   resd 1

h264_list0      resb 36
h264_list1      resb 36
h264_lt_tmp     resb 36
alignb 4
h264_tmpi       resd 40

section .data

h264_dpbmbs     dd 9, 396, 10, 396, 11, 900, 12, 2376, 13, 2376, 20, 2376
                dd 21, 4752, 22, 8100, 30, 8100, 31, 18000, 32, 20480
                dd 40, 32768, 41, 32768, 42, 34816, 50, 110400, 51, 184320
                dd 52, 184320, 0, 0

h264_sar        dw 1, 1, 12, 11, 10, 11, 16, 11, 40, 33, 24, 11, 20, 11, 32, 11
                dw 80, 33, 18, 11, 15, 11, 64, 33, 160, 99, 4, 3, 3, 2, 2, 1

section .text

EXPORT(h264_ctx_size)
h264_ctx_size:
    mov eax, H264_STATE_SZ
    ret

EXPORT(h264_mem_size)
h264_mem_size:
    CENTER
    mov eax, ARG(0)
    mov edx, ARG(1)
    call h264_layout
    CLEAVE

h264_layout:
    add eax, 15
    shr eax, 4
    add edx, 15
    shr edx, 4
    test eax, eax
    jz .bad
    test edx, edx
    jz .bad
    cmp eax, H264_MAXMBW
    ja .bad
    cmp edx, H264_MAXMBH
    ja .bad
    mov [h264_maxmbw], eax
    mov [h264_maxmbh], edx
    imul eax, edx
    cmp eax, H264_MAXNMB
    ja .bad
    mov [h264_maxnmb], eax
    mov eax, [h264_maxmbw]
    shl eax, 4
    add eax, 2 * H264_PADY
    mov [h264_ystride], eax
    mov ecx, [h264_maxmbh]
    shl ecx, 4
    add ecx, 2 * H264_PADY
    imul eax, ecx
    add eax, 63
    and eax, ~63
    mov [h264_ysize], eax
    mov eax, [h264_maxmbw]
    shl eax, 3
    add eax, 2 * H264_PADC
    mov [h264_cstride], eax
    mov ecx, [h264_maxmbh]
    shl ecx, 3
    add ecx, 2 * H264_PADC
    imul eax, ecx
    add eax, 63
    and eax, ~63
    mov [h264_csize], eax
    shl eax, 1
    add eax, [h264_ysize]
    mov ecx, [h264_maxnmb]
    imul ecx, MO_SZ
    add eax, ecx
    add eax, 63
    and eax, ~63
    mov [h264_slotbytes], eax

    xor eax, eax
    mov [h264_spstab], eax
    add eax, 32 * SPS_SZ
    mov [h264_ppstab], eax
    add eax, 256 * PPS_SZ
    mov [h264_asps], eax
    add eax, SPS_SZ + 63
    and eax, ~63
    mov [h264_rbsp], eax
    mov ecx, [h264_maxnmb]
    shl ecx, 9
    add ecx, 65536
    mov [h264_rbspcap], ecx
    add eax, ecx
    add eax, H264_RBSPPAD + 63
    and eax, ~63
    mov [h264_mbi], eax
    mov ecx, [h264_maxnmb]
    shl ecx, MI_SHIFT
    add eax, ecx
    mov [h264_slotmem], eax
    mov ecx, [h264_slotbytes]
    imul ecx, H264_NSLOT
    add eax, ecx
    add eax, 64
    mov [h264_total], eax
    ret
.bad:
    xor eax, eax
    ret

EXPORT(h264_init)
h264_init:
    CENTER
    mov edi, h264_S_begin
    mov ecx, H264_STATE_SZ / 4
    xor eax, eax
    rep stosd
    mov eax, ARG(3)
    mov edx, ARG(4)
    call h264_layout
    test eax, eax
    jz .fail
    cmp eax, ARG(2)
    ja .fail
    mov eax, ARG(1)
    add eax, 63
    and eax, ~63
    mov [h264_mem], eax
    mov ecx, ARG(2)
    mov [h264_memlen], ecx
    add [h264_spstab], eax
    add [h264_ppstab], eax
    add [h264_asps], eax
    add [h264_rbsp], eax
    add [h264_mbi], eax
    add [h264_slotmem], eax

    mov edi, [h264_spstab]
    mov ecx, (32 * SPS_SZ + 256 * PPS_SZ) / 4
    xor eax, eax
    rep stosd

    mov edi, [h264_mbi]
    mov ecx, [h264_maxnmb]
    shl ecx, MI_SHIFT - 2
    rep stosd

    xor ebx, ebx
    mov esi, h264_slots
.slot:
    mov eax, [h264_slotbytes]
    imul eax, ebx
    add eax, [h264_slotmem]
    mov ecx, [h264_ystride]
    imul ecx, H264_PADY
    add ecx, H264_PADY
    add ecx, eax
    mov [esi + SL_Y], ecx
    add eax, [h264_ysize]
    mov ecx, [h264_cstride]
    imul ecx, H264_PADC
    add ecx, H264_PADC
    add ecx, eax
    mov [esi + SL_U], ecx
    add eax, [h264_csize]
    mov ecx, [h264_cstride]
    imul ecx, H264_PADC
    add ecx, H264_PADC
    add ecx, eax
    mov [esi + SL_V], ecx
    add eax, [h264_csize]
    mov [esi + SL_MOT], eax
    add esi, SL_SZ
    inc ebx
    cmp ebx, H264_NSLOT
    jb .slot
    mov dword [h264_cur], -1
    mov dword [h264_lastref], -1
    mov dword [h264_maxltidx], -1
    mov dword [h264_slicectr], 1
    mov dword [h264_need_idr], 1
    mov eax, ARG(0)
    mov [h264_ctxp], eax
    call h264_save
    xor eax, eax
    CLEAVE
.fail:
    or eax, -1
    CLEAVE

h264_load:
    push esi
    push edi
    mov esi, [h264_ctxp]
    mov edi, h264_S_begin
    mov ecx, H264_STATE_SZ / 4
    rep movsd
    pop edi
    pop esi
    ret
h264_save:
    push esi
    push edi
    mov esi, h264_S_begin
    mov edi, [h264_ctxp]
    mov ecx, H264_STATE_SZ / 4
    rep movsd
    pop edi
    pop esi
    ret

h264_enter:
    mov [h264_ctxp], eax
    call h264_load
    xor ecx, ecx
.l: and dword [h264_slots + ecx + SL_FLAGS], ~F_LENT
    add ecx, SL_SZ
    cmp ecx, H264_NSLOT * SL_SZ
    jb .l
    ret

EXPORT(h264_decode_nal)
h264_decode_nal:
    CENTER
    mov eax, ARG(0)
    call h264_enter
    mov esi, ARG(1)
    mov ecx, ARG(2)
    call h264_nal
    call h264_result
    call h264_save
    CLEAVE

h264_result:
    cmp dword [h264_fifo_n], 0
    je .r
    mov eax, 1
.r: ret

EXPORT(h264_decode_avcc)
h264_decode_avcc:
    CENTER
    sub esp, 8
    mov eax, ARG(0)
    call h264_enter
    mov esi, ARG(1)
    mov ebx, ARG(2)
    cmp ebx, 8
    jb .bad
    cmp dword [esi + 4], 'avcC'
    jne .rec
    add esi, 8
    sub ebx, 8
.rec:
    cmp ebx, 7
    jb .bad
    cmp byte [esi], 1
    jne .bad
    movzx eax, byte [esi + 4]
    and eax, 3
    inc eax
    cmp eax, 3
    je .bad
    mov [ebp - 16], eax
    movzx edi, byte [esi + 5]
    and edi, 31
    add esi, 6
    sub ebx, 6
    mov dword [ebp - 20], 0
.sets:
    test edi, edi
    jz .next_kind
.one:
    cmp ebx, 2
    jb .bad
    movzx ecx, word [esi]
    xchg cl, ch
    add esi, 2
    sub ebx, 2
    cmp ecx, ebx
    ja .bad
    push ecx
    push esi
    push edi
    push ebx
    test ecx, ecx
    jz .skip
    call h264_nal
.skip:
    pop ebx
    pop edi
    pop esi
    pop ecx
    add esi, ecx
    sub ebx, ecx
    dec edi
    jnz .one
.next_kind:
    cmp dword [ebp - 20], 0
    jne .done
    mov dword [ebp - 20], 1
    test ebx, ebx
    jz .done
    movzx edi, byte [esi]
    inc esi
    dec ebx
    jmp .sets
.done:
    mov eax, [ebp - 16]
    jmp .out
.bad:
    or eax, -1
.out:
    call h264_save
    add esp, 8
    CLEAVE

EXPORT(h264_get_frame)
h264_get_frame:
    CENTER
    mov eax, ARG(0)
    mov [h264_ctxp], eax
    call h264_load
    xor eax, eax
    cmp dword [h264_fifo_n], 0
    je .out
    mov ebx, [h264_fifo]
    mov esi, h264_fifo + 4
    mov edi, h264_fifo
    mov ecx, H264_NSLOT - 1
    rep movsd
    dec dword [h264_fifo_n]
    imul ebx, SL_SZ
    add ebx, h264_slots
%ifdef NATIVE
    mov eax, [ebx + SL_MOT]
    mov [h264_dbg_mot], eax
%endif
    mov eax, [ebx + SL_FLAGS]
    and eax, ~F_FIFO
    or eax, F_LENT
    mov [ebx + SL_FLAGS], eax
    mov edi, ARG(1)
    mov eax, [ebx + SL_CY]
    imul eax, [h264_ystride]
    add eax, [ebx + SL_CX]
    add eax, [ebx + SL_Y]
    mov [edi + H264F_Y], eax
    mov eax, [ebx + SL_CY]
    shr eax, 1
    imul eax, [h264_cstride]
    mov edx, [ebx + SL_CX]
    shr edx, 1
    add eax, edx
    mov edx, eax
    add eax, [ebx + SL_U]
    mov [edi + H264F_U], eax
    add edx, [ebx + SL_V]
    mov [edi + H264F_V], edx
    mov eax, [h264_ystride]
    mov [edi + H264F_YSTRIDE], eax
    mov eax, [h264_cstride]
    mov [edi + H264F_CSTRIDE], eax
    mov eax, [ebx + SL_W]
    mov [edi + H264F_W], eax
    mov eax, [ebx + SL_H]
    mov [edi + H264F_H], eax
    mov eax, [ebx + SL_POC]
    mov [edi + H264F_POC], eax
    mov eax, [ebx + SL_FLAGS]
    xor edx, edx
    test eax, F_BAD
    jz .f1
    or edx, 1
.f1:
    test eax, F_IDR
    jz .f2
    or edx, 2
.f2:
    mov [edi + H264F_FLAGS], edx
    movzx eax, word [ebx + SL_SARW]
    mov [edi + H264F_SARW], eax
    movzx eax, word [ebx + SL_SARH]
    mov [edi + H264F_SARH], eax
    call h264_save
    mov eax, 1
.out:
    CLEAVE

%ifdef NATIVE

EXPORT(h264_dbg_motion)
h264_dbg_motion:
    mov eax, [h264_dbg_mot]
    ret
section .bss
h264_dbg_mot    resd 1
section .text
%endif

EXPORT(h264_flush)
h264_flush:
    CENTER
    mov eax, ARG(0)
    call h264_enter
    call h264_finish_pic
    call h264_output_all
    call h264_unmark_all
    mov dword [h264_need_idr], 1
    mov dword [h264_have_ref], 0
    xor eax, eax
    call h264_result
    call h264_save
    CLEAVE

h264_nal:
    test ecx, ecx
    jz .bad
    movzx eax, byte [esi]
    test al, 0x80
    jnz .bad
    mov edx, eax
    shr edx, 5
    mov [h264_nalref], edx
    and eax, 31
    mov [h264_naltype], eax
    cmp eax, 1
    je .rbsp
    cmp eax, 5
    je .rbsp
    cmp eax, 7
    je .rbsp
    cmp eax, 8
    je .rbsp
    xor eax, eax
    ret
.rbsp:
    inc esi
    dec ecx
    call h264_unescape
    mov eax, [h264_naltype]
    cmp eax, 7
    je h264_parse_sps
    cmp eax, 8
    je h264_parse_pps
    jmp h264_slice
.bad:
    or eax, -1
    ret

h264_unescape:
    push ebx
    mov edi, [h264_rbsp]
    mov [h264_bbuf], edi
    cmp ecx, [h264_rbspcap]
    jbe .lenok
    mov ecx, [h264_rbspcap]
.lenok:
    xor edx, edx
    jecxz .end
.l: mov al, [esi]
    inc esi
    cmp edx, 2
    jb .copy
    cmp al, 3
    jne .copy
    xor edx, edx
    dec ecx
    jnz .l
    jmp .end
.copy:
    mov [edi], al
    inc edi
    inc edx
    test al, al
    jz .z
    xor edx, edx
.z: dec ecx
    jnz .l
.end:
    mov ebx, edi
    mov ecx, H264_RBSPPAD / 4
    xor eax, eax
    push edi
    rep stosd
    pop edi

    mov esi, [h264_bbuf]
.back:
    cmp edi, esi
    jbe .empty
    dec edi
    movzx eax, byte [edi]
    test eax, eax
    jz .back
    bsf ecx, eax
    sub edi, esi
    shl edi, 3
    add edi, 7
    sub edi, ecx
    mov [h264_bend], edi
    jmp .done
.empty:
    mov dword [h264_bend], 0
.done:
    mov dword [h264_bp], 0
    mov dword [h264_berr], 0
    pop ebx
    ret

h264_peek:
    mov ecx, [h264_bp]
    mov edx, ecx
    shr edx, 3
    add edx, [h264_bbuf]
    mov eax, [edx]
    mov edx, [edx + 4]
    bswap eax
    bswap edx
    and ecx, 7
    shld eax, edx, cl
    ret

h264_u:
    test ecx, ecx
    jz .zero
    push ecx
    call h264_peek
    pop ecx
    add [h264_bp], ecx
    neg ecx
    add ecx, 32
    shr eax, cl
    ret
.zero:
    xor eax, eax
    ret

h264_u1:
    push ecx
    mov edx, [h264_bp]
    mov eax, edx
    shr eax, 3
    add eax, [h264_bbuf]
    movzx eax, byte [eax]
    mov ecx, edx
    and ecx, 7
    xor ecx, 7
    shr eax, cl
    and eax, 1
    inc edx
    mov [h264_bp], edx
    pop ecx
    ret

h264_ue:
    call h264_peek
    bsr ecx, eax
    jz .bad
    cmp ecx, 16
    jb .long
    mov edx, ecx
    lea ecx, [edx * 2 - 31]
    shr eax, cl
    dec eax
    neg edx
    lea edx, [edx * 2 + 63]
    add [h264_bp], edx
    ret
.long:
    mov edx, 31
    sub edx, ecx
    push edx
    inc edx
    add [h264_bp], edx
    mov ecx, [esp]
    call h264_u
    pop ecx
    mov edx, 1
    shl edx, cl
    lea eax, [eax + edx - 1]
    ret
.bad:
    mov dword [h264_berr], 1
    add dword [h264_bp], 32
    or eax, -1
    ret

h264_se:
    call h264_ue
    test al, 1
    jnz .pos
    shr eax, 1
    neg eax
    ret
.pos:
    shr eax, 1
    inc eax
    ret

h264_bad_pos:
    mov eax, [h264_bp]
    cmp eax, [h264_bend]
    ja .bad
    cmp dword [h264_berr], 0
    ret
.bad:
    or eax, 1
    ret

h264_more_data:
    mov eax, [h264_bp]
    cmp eax, [h264_bend]
    ret

h264_parse_sps:
    mov ecx, 24
    call h264_u
    mov ebx, eax
    call h264_ue
    cmp eax, 31
    ja .bad

    mov edi, h264_spsbuf
    push eax
    push edi
    mov ecx, SPS_SZ / 4
    xor eax, eax
    rep stosd
    pop edi
    pop eax
    mov [edi + SPS_ID], eax
    mov eax, ebx
    shr eax, 16
    mov [edi + SPS_PROFILE], al
    mov [edi + SPS_LEVEL], bl
    mov byte [edi + SPS_CHROMA], 1
    mov dword [edi + SPS_REORDER], -1
    mov dword [edi + SPS_MAXDEC], -1
    shr ebx, 16
    cmp bl, 100
    je .hi
    cmp bl, 110
    je .hi
    cmp bl, 122
    je .hi
    cmp bl, 244
    je .hi
    cmp bl, 44
    je .hi
    cmp bl, 83
    je .hi
    cmp bl, 86
    je .hi
    cmp bl, 118
    je .hi
    cmp bl, 128
    je .hi
    cmp bl, 138
    je .hi
    cmp bl, 139
    je .hi
    cmp bl, 134
    je .hi
    cmp bl, 135
    je .hi
    jmp .common
.hi:
    call h264_ue
    cmp eax, 3
    ja .bad
    mov [edi + SPS_CHROMA], al
    cmp eax, 1
    je .chok
    mov byte [edi + SPS_UNSUP], 1
.chok:
    cmp eax, 3
    jne .nosep
    call h264_u1
.nosep:
    call h264_ue
    mov ebx, eax
    call h264_ue
    or ebx, eax
    jz .d8
    mov byte [edi + SPS_UNSUP], 2
.d8:
    call h264_u1
    test eax, eax
    jz .nobyp
    mov byte [edi + SPS_UNSUP], 3
.nobyp:
    call h264_u1
    test eax, eax
    jz .common
    mov byte [edi + SPS_SCALING], 1
    mov ebx, 8
    cmp byte [edi + SPS_CHROMA], 3
    jne .sl0
    mov ebx, 12
.sl0:
    mov dword [h264_tmpi], 0
.sl:
    call h264_u1
    test eax, eax
    jz .slnext
    mov eax, 16
    cmp dword [h264_tmpi], 6
    jb .sl4
    mov eax, 64
.sl4:
    call h264_skip_scaling
.slnext:
    inc dword [h264_tmpi]
    cmp [h264_tmpi], ebx
    jb .sl
.common:
    call h264_ue
    cmp eax, 12
    ja .bad
    add eax, 4
    mov [edi + SPS_LOG2FN], al
    call h264_ue
    cmp eax, 2
    ja .bad
    mov [edi + SPS_POCTYPE], al
    test eax, eax
    jnz .poc1
    call h264_ue
    cmp eax, 12
    ja .bad
    add eax, 4
    mov [edi + SPS_LOG2POC], al
    jmp .pocdone
.poc1:
    cmp eax, 1
    jne .pocdone
    call h264_u1
    mov [edi + SPS_DPOCZ], al
    call h264_se
    mov [edi + SPS_OFFNR], eax
    call h264_se
    mov [edi + SPS_OFFTB], eax
    call h264_ue
    cmp eax, 255
    ja .bad
    mov [edi + SPS_NCYCLE], eax
    mov ebx, eax
    xor esi, esi
    lea edx, [edi + SPS_OFFREF]
.cyc:
    test ebx, ebx
    jz .cycdone
    push edx
    call h264_se
    pop edx
    mov [edx], eax
    add esi, eax
    add edx, 4
    dec ebx
    jmp .cyc
.cycdone:
    mov [edi + SPS_EXPDELTA], esi
.pocdone:
    call h264_ue
    cmp eax, 16
    ja .bad
    mov [edi + SPS_NREF], al
    call h264_u1
    mov [edi + SPS_GAPS], al
    call h264_ue
    cmp eax, H264_MAXMBW - 1
    ja .bad
    inc eax
    mov [edi + SPS_MBW], eax
    call h264_ue
    cmp eax, H264_MAXMBH - 1
    ja .bad
    inc eax
    mov [edi + SPS_MBH], eax
    call h264_u1
    test eax, eax
    jnz .frames
    mov byte [edi + SPS_UNSUP], 4
    shl dword [edi + SPS_MBH], 1
    call h264_u1
.frames:
    call h264_u1
    mov [edi + SPS_D8I], al
    call h264_u1
    test eax, eax
    jz .nocrop
    mov ebx, SPS_CROPL
.crop:
    call h264_ue
    cmp eax, 8192
    ja .bad
    shl eax, 1
    mov [edi + ebx], eax
    add ebx, 4
    cmp ebx, SPS_CROPB
    jbe .crop
    mov eax, [edi + SPS_CROPL]
    add eax, [edi + SPS_CROPR]
    mov edx, [edi + SPS_MBW]
    shl edx, 4
    cmp eax, edx
    jae .badcrop
    mov eax, [edi + SPS_CROPT]
    add eax, [edi + SPS_CROPB]
    mov edx, [edi + SPS_MBH]
    shl edx, 4
    cmp eax, edx
    jb .nocrop
.badcrop:
    xor eax, eax
    mov [edi + SPS_CROPL], eax
    mov [edi + SPS_CROPR], eax
    mov [edi + SPS_CROPT], eax
    mov [edi + SPS_CROPB], eax
.nocrop:
    call h264_bad_pos
    jnz .bad
    call h264_u1
    test eax, eax
    jz .store
    call h264_parse_vui
.store:
    mov esi, h264_spsbuf
    mov byte [esi + SPS_VALID], 1
    mov edi, [esi + SPS_ID]
    imul edi, SPS_SZ
    add edi, [h264_spstab]
    mov ecx, SPS_SZ / 4
    rep movsd
    xor eax, eax
    ret
.bad:
    or eax, -1
    ret

h264_skip_scaling:
    push ebx
    mov ebx, eax
    mov esi, 8
.l: test esi, esi
    jz .next
    call h264_se
    add eax, esi
    add eax, 256
    and eax, 255
    mov esi, eax
.next:
    dec ebx
    jnz .l
    pop ebx
    ret

h264_parse_vui:
    call h264_u1
    test eax, eax
    jz .noar
    mov ecx, 8
    call h264_u
    cmp eax, 255
    jne .aridc
    mov ecx, 16
    call h264_u
    mov [edi + SPS_SARW], eax
    mov ecx, 16
    call h264_u
    mov [edi + SPS_SARH], eax
    jmp .noar
.aridc:
    dec eax
    cmp eax, 15
    ja .noar
    movzx edx, word [h264_sar + eax * 4]
    mov [edi + SPS_SARW], edx
    movzx edx, word [h264_sar + eax * 4 + 2]
    mov [edi + SPS_SARH], edx
.noar:
    call h264_u1
    test eax, eax
    jz .noov
    call h264_u1
.noov:
    call h264_u1
    test eax, eax
    jz .novs
    mov ecx, 4
    call h264_u
    call h264_u1
    test eax, eax
    jz .novs
    mov ecx, 24
    call h264_u
.novs:
    call h264_u1
    test eax, eax
    jz .nocl
    call h264_ue
    call h264_ue
.nocl:
    call h264_u1
    test eax, eax
    jz .notime
    mov ecx, 32
    call h264_u
    mov ecx, 32
    call h264_u
    call h264_u1
.notime:
    call h264_u1
    mov ebx, eax
    test eax, eax
    jz .nonal
    call h264_skip_hrd
.nonal:
    call h264_u1
    or ebx, eax
    test eax, eax
    jz .novcl
    call h264_skip_hrd
.novcl:
    test ebx, ebx
    jz .nolow
    call h264_u1
.nolow:
    call h264_u1
    call h264_u1
    test eax, eax
    jz .check
    call h264_u1
    call h264_ue
    call h264_ue
    call h264_ue
    call h264_ue
    call h264_ue
    mov ebx, eax
    call h264_ue
    mov esi, eax
    call h264_bad_pos
    jnz .drop
    mov eax, esi
    cmp ebx, 16
    ja .drop
    cmp eax, 16
    ja .drop
    mov [edi + SPS_REORDER], ebx
    mov [edi + SPS_MAXDEC], eax
.check:
    ret
.drop:
    mov dword [edi + SPS_REORDER], -1
    mov dword [edi + SPS_MAXDEC], -1
    ret

h264_skip_hrd:
    call h264_ue
    cmp eax, 31
    ja .bad
    lea esi, [eax + 1]
    mov ecx, 8
    call h264_u
.l: call h264_ue
    call h264_ue
    call h264_u1
    dec esi
    jnz .l
    mov ecx, 20
    call h264_u
.bad:
    ret

h264_parse_pps:
    call h264_ue
    cmp eax, 255
    ja .bad
    mov [h264_ppsid_tmp], eax
    mov edi, h264_ppsbuf
    xor eax, eax
    mov ecx, PPS_SZ / 4
    push edi
    rep stosd
    pop edi
    call h264_ue
    cmp eax, 31
    ja .bad
    mov [edi + PPS_SPS], al
    call h264_u1
    mov [edi + PPS_CABAC], al
    call h264_u1
    mov [edi + PPS_BFPOC], al
    call h264_ue
    cmp eax, 7
    ja .bad
    inc eax
    mov [edi + PPS_NSG], al
    cmp eax, 1
    je .nofmo

    lea esi, [eax - 1]
    call h264_ue
    cmp eax, 6
    ja .bad
    mov [edi + PPS_SGTYPE], eax
    test eax, eax
    jnz .sg2
    inc esi
.rl:
    call h264_ue
    dec esi
    jnz .rl
    jmp .nofmo
.sg2:
    cmp eax, 2
    jne .sg3
.tlbr:
    call h264_ue
    call h264_ue
    dec esi
    jnz .tlbr
    jmp .nofmo
.sg3:
    cmp eax, 6
    je .sg6
    cmp eax, 3
    jb .nofmo
    call h264_u1
    call h264_ue
    inc eax
    mov [edi + PPS_SGRATE], eax
    jmp .nofmo
.sg6:
    call h264_ue
    cmp eax, H264_MAXNMB
    jae .bad
    lea edx, [eax + 1]
    lea eax, [esi + 1]
    xor ecx, ecx
.lg:
    push edx
    mov edx, 1
    shl edx, cl
    cmp edx, eax
    pop edx
    jae .lgd
    inc ecx
    jmp .lg
.lgd:
    imul ecx, edx
    add [h264_bp], ecx
.nofmo:
    call h264_ue
    cmp eax, 31
    ja .bad
    inc eax
    mov [edi + PPS_NREF0], al
    call h264_ue
    cmp eax, 31
    ja .bad
    inc eax
    mov [edi + PPS_NREF1], al
    call h264_u1
    mov [edi + PPS_WP], al
    mov ecx, 2
    call h264_u
    mov [edi + PPS_WBI], al
    call h264_se
    add eax, 26
    cmp eax, 51
    ja .bad
    mov [edi + PPS_QP], al
    call h264_se
    call h264_se
    add eax, 12
    cmp eax, 24
    ja .bad
    sub eax, 12
    mov [edi + PPS_CQP], al
    mov [edi + PPS_CQP2], al
    call h264_u1
    mov [edi + PPS_DBK], al
    call h264_u1
    mov [edi + PPS_CIP], al
    call h264_u1
    mov [edi + PPS_RPC], al
    call h264_bad_pos
    jnz .bad
    call h264_more_data
    jnc .store
    call h264_u1
    mov [edi + PPS_T8], al
    call h264_u1
    test eax, eax
    jz .noscale
    movzx esi, byte [edi + PPS_T8]
    lea esi, [esi * 2 + 6]
    xor ebx, ebx
.psl:
    call h264_u1
    test eax, eax
    jz .pslnext
    mov eax, 16
    cmp ebx, 6
    jb .psl4
    mov eax, 64
.psl4:
    push esi
    call h264_skip_scaling
    pop esi
.pslnext:
    inc ebx
    cmp ebx, esi
    jb .psl
.noscale:
    call h264_se
    add eax, 12
    cmp eax, 24
    ja .bad
    sub eax, 12
    mov [edi + PPS_CQP2], al
    call h264_bad_pos
    jnz .bad
.store:
    mov byte [edi + PPS_VALID], 1
    mov esi, edi
    imul edi, [h264_ppsid_tmp], PPS_SZ
    add edi, [h264_ppstab]
    mov ecx, PPS_SZ / 4
    rep movsd
    xor eax, eax
    ret
.bad:
    or eax, -1
    ret

section .bss
alignb 4
h264_spsbuf     resb SPS_SZ
h264_ppsbuf     resb PPS_SZ
h264_ppsid_tmp  resd 1
section .text

h264_slice:
    call h264_slice_header
    test eax, eax
    jnz .ret

    cmp dword [h264_pic_on], 0
    je .newpic
    call h264_same_pic
    jnz .other
    mov eax, [h264_pic_done]
    cmp eax, [h264_nmb]
    jb .slice
    xor eax, eax
    ret
.other:
    call h264_finish_pic
.newpic:
    call h264_start_pic
    test eax, eax
    jnz .ret
.slice:
    mov eax, [h264_slicectr]
    mov [h264_slicenum], eax
    inc dword [h264_slicectr]
    cmp dword [h264_sh_type], ST_I
    je .data
    call h264_build_lists
    test eax, eax
    jz .lists
    mov dword [h264_pic_err], 1
.lists:
    cmp dword [h264_sh_type], ST_B
    jne .data
    call h264_slice_bsetup
.data:
    call h264_slice_data
    test eax, eax
    jz .complete
    mov dword [h264_pic_err], 1
.complete:
    push eax
    mov eax, [h264_pic_done]
    cmp eax, [h264_nmb]
    jb .notyet
    call h264_finish_pic
.notyet:
    pop eax
    ret
.ret:
    cmp eax, 0
    jle .r
    xor eax, eax
.r: ret

h264_slice_header:
    call h264_ue
    mov [h264_sh_firstmb], eax
    call h264_ue
    cmp eax, 9
    ja .bad
    cmp eax, 5
    jb .st
    sub eax, 5
.st:
    mov [h264_sh_type], eax
    call h264_ue
    cmp eax, 255
    ja .bad
    mov [h264_sh_ppsid], eax
    imul esi, eax, PPS_SZ
    add esi, [h264_ppstab]
    mov [h264_sh_pps], esi
    cmp byte [esi + PPS_VALID], 0
    je .bad
    movzx edi, byte [esi + PPS_SPS]
    imul edi, SPS_SZ
    add edi, [h264_spstab]
    cmp byte [edi + SPS_VALID], 0
    je .bad
    xor eax, eax
    cmp dword [h264_naltype], 5
    sete al
    mov [h264_sh_idr], eax

    test eax, eax
    jnz .spsok
    cmp dword [h264_need_idr], 0
    jne .skip
    cmp dword [h264_act], 0
    je .skip
    mov edi, [h264_asps]
    movzx eax, byte [esi + PPS_SPS]
    cmp eax, [edi + SPS_ID]
    jne .bad
.spsok:
    mov [h264_sh_sps], edi

    cmp byte [edi + SPS_UNSUP], 0
    jne .skip
    cmp byte [esi + PPS_CABAC], 0
    jne .skip
    cmp byte [esi + PPS_NSG], 1
    jne .skip
    cmp dword [h264_sh_type], ST_I
    ja .skip
    movzx ecx, byte [edi + SPS_LOG2FN]
    call h264_u
    mov [h264_sh_fn], eax
    xor eax, eax
    mov [h264_sh_idrid], eax
    mov [h264_sh_poclsb], eax
    mov [h264_sh_dpb], eax
    mov [h264_sh_dpoc0], eax
    mov [h264_sh_dpoc1], eax
    mov [h264_sh_rpc], eax
    cmp dword [h264_sh_idr], 0
    je .noidr
    call h264_ue
    mov [h264_sh_idrid], eax
.noidr:
    mov al, [edi + SPS_POCTYPE]
    test al, al
    jnz .poct1
    movzx ecx, byte [edi + SPS_LOG2POC]
    call h264_u
    mov [h264_sh_poclsb], eax
    cmp byte [esi + PPS_BFPOC], 0
    je .pocd
    call h264_se
    mov [h264_sh_dpb], eax
    jmp .pocd
.poct1:
    cmp al, 1
    jne .pocd
    cmp byte [edi + SPS_DPOCZ], 0
    jne .pocd
    call h264_se
    mov [h264_sh_dpoc0], eax
    cmp byte [esi + PPS_BFPOC], 0
    je .pocd
    call h264_se
    mov [h264_sh_dpoc1], eax
.pocd:
    cmp byte [esi + PPS_RPC], 0
    je .norpc
    call h264_ue
    mov [h264_sh_rpc], eax
.norpc:
    mov dword [h264_sh_dspat], 1
    cmp dword [h264_sh_type], ST_B
    jne .nodsp
    call h264_u1
    mov [h264_sh_dspat], eax
.nodsp:
    movzx eax, byte [esi + PPS_NREF0]
    mov [h264_sh_nref0], eax
    movzx eax, byte [esi + PPS_NREF1]
    mov [h264_sh_nref1], eax
    mov dword [h264_sh_nrplm0], 0
    mov dword [h264_sh_nrplm1], 0
    cmp dword [h264_sh_type], ST_I
    je .noref
    call h264_u1
    test eax, eax
    jz .noovr
    call h264_ue
    cmp eax, 15
    ja .bad
    inc eax
    mov [h264_sh_nref0], eax
    cmp dword [h264_sh_type], ST_B
    jne .noovr
    call h264_ue
    cmp eax, 15
    ja .bad
    inc eax
    mov [h264_sh_nref1], eax
.noovr:
    cmp dword [h264_sh_nref0], 16
    ja .bad

    mov edi, h264_sh_rplm0
    call h264_read_rplm
    test eax, eax
    js .bad
    mov [h264_sh_nrplm0], eax
    cmp dword [h264_sh_type], ST_B
    jne .noref
    cmp dword [h264_sh_nref1], 16
    ja .bad
    mov edi, h264_sh_rplm1
    call h264_read_rplm
    test eax, eax
    js .bad
    mov [h264_sh_nrplm1], eax
.noref:

    mov dword [h264_sh_wmode], 0
    mov eax, [h264_sh_type]
    cmp eax, ST_P
    jne .wpb
    cmp byte [esi + PPS_WP], 0
    je .nowp
    jmp .wpt
.wpb:
    cmp eax, ST_B
    jne .nowp
    movzx eax, byte [esi + PPS_WBI]
    cmp eax, 2
    ja .bad
    jb .wpb1
    mov dword [h264_sh_wmode], 2
    jmp .nowp
.wpb1:
    test eax, eax
    jz .nowp
.wpt:
    mov dword [h264_sh_wmode], 1
    call h264_parse_pwt
    test eax, eax
    jnz .bad
.nowp:

    xor eax, eax
    mov [h264_sh_noout], eax
    mov [h264_sh_ltref], eax
    mov [h264_sh_adapt], eax
    mov [h264_sh_nmmco], eax
    cmp dword [h264_nalref], 0
    je .nomark
    cmp dword [h264_sh_idr], 0
    je .adaptive
    call h264_u1
    mov [h264_sh_noout], eax
    call h264_u1
    mov [h264_sh_ltref], eax
    jmp .nomark
.adaptive:
    call h264_u1
    mov [h264_sh_adapt], eax
    test eax, eax
    jz .nomark
    xor ebx, ebx
.mmco:
    call h264_ue
    test eax, eax
    jz .mmcod
    cmp eax, 6
    ja .bad
    cmp ebx, H264_MAXMMCO
    jae .bad
    imul edx, ebx, 12
    mov [h264_sh_mmco + edx], eax
    mov dword [h264_sh_mmco + edx + 4], 0
    mov dword [h264_sh_mmco + edx + 8], 0
    cmp eax, 5
    je .mmnext
    push eax
    call h264_ue
    imul edx, ebx, 12
    mov [h264_sh_mmco + edx + 4], eax
    pop eax
    cmp eax, 3
    jne .mmnext
    call h264_ue
    imul edx, ebx, 12
    mov [h264_sh_mmco + edx + 8], eax
.mmnext:
    inc ebx
    call h264_bad_pos
    jnz .bad
    jmp .mmco
.mmcod:
    mov [h264_sh_nmmco], ebx
.nomark:
    mov dword [h264_sh_cabinit], 0
    cmp byte [esi + PPS_CABAC], 0
    je .nocab
    cmp dword [h264_sh_type], ST_I
    je .nocab
    call h264_ue
    cmp eax, 2
    ja .bad
    mov [h264_sh_cabinit], eax
.nocab:
    call h264_se
    movsx edx, byte [esi + PPS_QP]
    add eax, edx
    cmp eax, 51
    ja .bad
    mov [h264_sh_qp], eax
    xor eax, eax
    mov [h264_sh_dbidc], eax
    mov [h264_sh_dba], eax
    mov [h264_sh_dbb], eax
    cmp byte [esi + PPS_DBK], 0
    je .nodbk
    call h264_ue
    cmp eax, 2
    ja .bad
    mov [h264_sh_dbidc], eax
    cmp eax, 1
    je .nodbk
    call h264_se
    add eax, 6
    cmp eax, 12
    ja .bad
    sub eax, 6
    shl eax, 1
    mov [h264_sh_dba], eax
    call h264_se
    add eax, 6
    cmp eax, 12
    ja .bad
    sub eax, 6
    shl eax, 1
    mov [h264_sh_dbb], eax
.nodbk:
    call h264_bad_pos
    jnz .bad
    movsx eax, byte [esi + PPS_CQP]
    mov [h264_sh_cqp], eax
    movsx eax, byte [esi + PPS_CQP2]
    mov [h264_sh_cqp2], eax
    movzx eax, byte [esi + PPS_CIP]
    mov [h264_sh_cip], eax
    cmp dword [h264_sh_rpc], 0
    jne .skip
    xor eax, eax
    ret
.skip:
    mov eax, 1
    ret
.bad:
    or eax, -1
    ret

h264_read_rplm:
    call h264_u1
    test eax, eax
    jz .r
    xor ebx, ebx
.l: call h264_ue
    cmp eax, 3
    je .d
    ja .bad
    cmp ebx, H264_MAXRPLM
    jae .bad
    mov [edi + ebx * 8], eax
    call h264_ue
    mov [edi + ebx * 8 + 4], eax
    inc ebx
    call h264_bad_pos
    jnz .bad
    jmp .l
.d: mov eax, ebx
.r: ret
.bad:
    or eax, -1
    ret

h264_parse_pwt:
    call h264_ue
    cmp eax, 7
    ja .bad
    mov [h264_sh_lwd], eax
    call h264_ue
    cmp eax, 7
    ja .bad
    mov [h264_sh_cwd], eax
    xor ebx, ebx
.ent:
    mov eax, ebx
    and eax, 31
    mov ecx, [h264_sh_nref0]
    cmp ebx, 32
    jb .n0
    mov ecx, [h264_sh_nref1]
.n0:
    cmp eax, ecx
    jae .nextlist
    imul edi, ebx, WT_SZ
    add edi, h264_wt
    mov ecx, [h264_sh_lwd]
    mov eax, 1
    shl eax, cl
    mov [edi], eax
    mov ecx, [h264_sh_cwd]
    mov eax, 1
    shl eax, cl
    mov [edi + 8], eax
    mov [edi + 16], eax
    xor eax, eax
    mov [edi + 4], eax
    mov [edi + 12], eax
    mov [edi + 20], eax
    mov byte [h264_wtf + ebx], 0
    call h264_u1
    test eax, eax
    jz .noluma
    or byte [h264_wtf + ebx], 1
    call .weight
    jc .bad
    mov [edi], eax
    call .weight
    jc .bad
    mov [edi + 4], eax
.noluma:
    call h264_u1
    test eax, eax
    jz .nochroma
    or byte [h264_wtf + ebx], 2
    call .weight
    jc .bad
    mov [edi + 8], eax
    call .weight
    jc .bad
    mov [edi + 12], eax
    call .weight
    jc .bad
    mov [edi + 16], eax
    call .weight
    jc .bad
    mov [edi + 20], eax
.nochroma:
    inc ebx
    jmp .ent
.nextlist:
    cmp ebx, 32
    jae .done
    cmp dword [h264_sh_type], ST_B
    jne .done
    mov ebx, 32
    jmp .ent
.done:
    call h264_bad_pos
    jnz .bad
    xor eax, eax
    ret
.bad:
    or eax, -1
    ret

.weight:
    call h264_se
    lea ecx, [eax + 128]
    cmp ecx, 256
    cmc
    ret

h264_same_pic:
    mov eax, [h264_sh_fn]
    cmp eax, [h264_pic_fn]
    jne .r
    mov eax, [h264_sh_ppsid]
    cmp eax, [h264_pic_ppsid]
    jne .r
    mov eax, [h264_sh_idr]
    cmp eax, [h264_pic_idr]
    jne .r
    test eax, eax
    jz .noidr
    mov eax, [h264_sh_idrid]
    cmp eax, [h264_pic_idrid]
    jne .r
.noidr:
    mov eax, [h264_nalref]
    test eax, eax
    setz al
    mov ah, 0
    cmp dword [h264_pic_refidc], 0
    setz ah
    cmp al, ah
    jne .r
    mov eax, [h264_sh_poclsb]
    cmp eax, [h264_pic_poclsb]
    jne .r
    mov eax, [h264_sh_dpb]
    cmp eax, [h264_pic_dpb]
    jne .r
    mov eax, [h264_sh_dpoc0]
    cmp eax, [h264_pic_dpoc0]
    jne .r
    mov eax, [h264_sh_dpoc1]
    cmp eax, [h264_pic_dpoc1]
.r: ret

%include "src/h264_pic.inc"
%include "src/h264_mb.inc"
%include "src/h264_inter.inc"
%include "src/h264_dsp.inc"
