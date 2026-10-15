%include "src/module.inc"

JPEG_MAXDIM     equ 16384
JPEG_MAXSCANS   equ 1000

JC_ID       equ 0
JC_H        equ 4
JC_V        equ 8
JC_TQ       equ 12
JC_BW       equ 16
JC_BH       equ 20
JC_DW       equ 24
JC_DH       equ 28
JC_NBW      equ 32
JC_NBH      equ 36
JC_PLANE    equ 40
JC_COEF     equ 44
JC_DCT      equ 48
JC_ACT      equ 52
JC_PRED     equ 56
JC_SX       equ 60
JC_SY       equ 64
JC_ROW      equ 68
JC_QOK      equ 72
JC_QT       equ 76
JC_SIZE     equ 80

JH_LUT      equ 0
JH_MAX      equ 2048
JH_OFF      equ 2048 + 68
JH_VALS     equ 2048 + 136
JH_SIZE     equ 2048 + 136 + 256

section .data

jpeg_nat:
    db  0,  1,  8, 16,  9,  2,  3, 10, 17, 24, 32, 25, 18, 11,  4,  5
    db 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13,  6,  7, 14, 21, 28
    db 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51
    db 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63
    times 16 db 63

section .bss
alignb 16
jpeg_huf    resb 8 * JH_SIZE
jpeg_qt     resd 4 * 64
jpeg_cq     resd 4 * 64
jpeg_blk    resw 64
jpeg_ws     resd 64

jpeg_z0:
jpeg_comp   resb 4 * JC_SIZE
jpeg_hok    resd 8
jpeg_qok    resd 4
jpeg_mode   resd 1
jpeg_sof    resd 1
jpeg_nscan  resd 1
jpeg_ncomp  resd 1
jpeg_w      resd 1
jpeg_h      resd 1
jpeg_hmax   resd 1
jpeg_vmax   resd 1
jpeg_mcux   resd 1
jpeg_mcuy   resd 1
jpeg_prog   resd 1
jpeg_rgb    resd 1
jpeg_jfif   resd 1
jpeg_adobe  resd 1
jpeg_rsti   resd 1
jpeg_need   resd 1
jpeg_work   resd 1
jpeg_wsize  resd 1
jpeg_z1:

jpeg_ns     resd 1
jpeg_sc     resd 4
jpeg_ss     resd 1
jpeg_se     resd 1
jpeg_ah     resd 1
jpeg_al     resd 1
jpeg_eobrun resd 1
jpeg_rstleft resd 1
jpeg_mx     resd 1
jpeg_my     resd 1
jpeg_nmx    resd 1
jpeg_nmy    resd 1
jpeg_blkfn  resd 1

jpeg_ptr    resd 1
jpeg_end    resd 1
jpeg_bbuf   resd 1
jpeg_bcnt   resd 1
jpeg_mark   resd 1

jpeg_t0     resd 1
jpeg_t1     resd 1
jpeg_t2     resd 1
jpeg_t3     resd 1
jpeg_t10    resd 1
jpeg_t11    resd 1
jpeg_t12    resd 1
jpeg_t13    resd 1
jpeg_z1v    resd 1
jpeg_z2v    resd 1
jpeg_z3v    resd 1
jpeg_z4v    resd 1
jpeg_cnt    resd 1
jpeg_ostr   resd 1
jpeg_odst   resd 1

jpeg_out    resd 1
jpeg_ostride resd 1
jpeg_y      resd 1
jpeg_rows   resd 4

section .text

EXPORT(jpeg_info)
jpeg_info:
    CENTER
    mov esi, ARG(0)
    mov ecx, ARG(1)
    call jpeg_reset
    test eax, eax
    js .out
    mov dword [jpeg_mode], 0
    call jpeg_markers
    test eax, eax
    js .out
    mov eax, -1
    cmp dword [jpeg_sof], 0
    je .out
    mov edx, ARG(2)
    mov ecx, [jpeg_w]
    mov [edx], ecx
    mov edx, ARG(3)
    mov ecx, [jpeg_h]
    mov [edx], ecx
    mov edx, ARG(4)
    mov ecx, [jpeg_need]
    mov [edx], ecx
    xor eax, eax
.out:
    CLEAVE

EXPORT(jpeg_decode)
jpeg_decode:
    CENTER
    mov esi, ARG(0)
    mov ecx, ARG(1)
    call jpeg_reset
    test eax, eax
    js .out
    mov dword [jpeg_mode], 1
    mov eax, ARG(5)
    mov [jpeg_work], eax
    mov eax, ARG(6)
    mov [jpeg_wsize], eax
    call jpeg_markers
    test eax, eax
    js .out
    mov eax, -1
    cmp dword [jpeg_sof], 0
    je .out
    cmp dword [jpeg_nscan], 0
    je .out
    mov ecx, ARG(3)
    cmp ecx, [jpeg_w]
    jb .out
    shl ecx, 2
    mov [jpeg_ostride], ecx
    mov eax, ARG(2)
    mov [jpeg_out], eax
    cmp dword [jpeg_prog], 0
    je .conv
    call jpeg_idct_all
.conv:
    call jpeg_output
    xor eax, eax
.out:
    CLEAVE

jpeg_reset:
    push edi
    push ecx
    mov edi, jpeg_z0
    mov ecx, (jpeg_z1 - jpeg_z0) / 4
    xor eax, eax
    rep stosd
    pop ecx
    pop edi
    lea eax, [esi + ecx]
    mov [jpeg_end], eax
    lea eax, [esi + 2]
    mov [jpeg_ptr], eax
    mov eax, -1
    cmp ecx, 4
    jb .r
    cmp word [esi], 0xD8FF
    jne .r
    xor eax, eax
.r:
    ret

jpeg_markers:
    push ebx
    push esi
    push edi
    push ebp
.next:
    mov esi, [jpeg_ptr]
    mov edi, [jpeg_end]
.find:
    cmp esi, edi
    jae .end
    mov al, [esi]
    inc esi
    cmp al, 0xFF
    jne .find
.ff:
    cmp esi, edi
    jae .end
    mov al, [esi]
    inc esi
    cmp al, 0xFF
    je .ff
    test al, al
    jz .find
    cmp al, 0xD9
    je .end
    cmp al, 0xD8
    je .find
    cmp al, 0x01
    je .find
    mov ah, al
    and ah, 0xF8
    cmp ah, 0xD0
    je .find
    lea edx, [esi + 2]
    cmp edx, edi
    ja .bad
    movzx ecx, word [esi]
    xchg cl, ch
    cmp ecx, 2
    jb .bad
    mov edx, edi
    sub edx, esi
    cmp ecx, edx
    ja .bad
    lea edx, [esi + ecx]
    mov [jpeg_ptr], edx
    add esi, 2
    sub ecx, 2
    movzx eax, al
    cmp eax, 0xC4
    je .dht
    cmp eax, 0xDB
    je .dqt
    cmp eax, 0xDD
    je .dri
    cmp eax, 0xDA
    je .sos
    cmp eax, 0xE0
    je .app0
    cmp eax, 0xEE
    je .app14
    cmp eax, 0xC0
    je .sof
    cmp eax, 0xC1
    je .sof
    cmp eax, 0xC2
    je .sof
    cmp eax, 0xC8
    je .next
    cmp eax, 0xCC
    je .next
    mov edx, eax
    and edx, 0xF0
    cmp edx, 0xC0
    je .bad
    jmp .next
.dht:
    call jpeg_dht
    jmp .chk
.dqt:
    call jpeg_dqt
    jmp .chk
.dri:
    cmp ecx, 2
    jb .bad
    movzx eax, word [esi]
    xchg al, ah
    mov [jpeg_rsti], eax
    jmp .next
.app0:
    cmp ecx, 5
    jb .next
    cmp dword [esi], 'JFIF'
    jne .next
    cmp byte [esi + 4], 0
    jne .next
    mov dword [jpeg_jfif], 1
    jmp .next
.app14:
    cmp ecx, 12
    jb .next
    cmp dword [esi], 'Adob'
    jne .next
    cmp byte [esi + 4], 'e'
    jne .next
    movzx eax, byte [esi + 11]
    inc eax
    mov [jpeg_adobe], eax
    jmp .next
.sof:
    cmp eax, 0xC2
    sete dl
    movzx edx, dl
    mov [jpeg_prog], edx
    call jpeg_sofseg
    test eax, eax
    js .r
    cmp dword [jpeg_mode], 0
    je .ok
    jmp .next
.sos:
    cmp dword [jpeg_mode], 0
    je .bad
    cmp dword [jpeg_nscan], JPEG_MAXSCANS
    jae .end
    call jpeg_sos
    jmp .chk
.chk:
    test eax, eax
    jns .next
.bad:
    mov eax, -1
    jmp .r
.end:
    cmp dword [jpeg_mode], 0
    je .bad
.ok:
    xor eax, eax
.r:
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

jpeg_dht:
.tab:
    test ecx, ecx
    jz .ok
    cmp ecx, 17
    jb .bad
    movzx eax, byte [esi]
    mov edx, eax
    shr edx, 4
    and eax, 15
    cmp edx, 1
    ja .bad
    cmp eax, 3
    ja .bad
    lea eax, [eax + edx * 4]
    xor edx, edx
    push ecx
    mov ecx, 16
.sum:
    movzx ebx, byte [esi + ecx]
    add edx, ebx
    dec ecx
    jnz .sum
    pop ecx
    sub ecx, 17
    cmp edx, 256
    ja .bad
    cmp edx, ecx
    ja .bad
    sub ecx, edx
    push ecx
    push edx
    push esi
    mov dword [jpeg_hok + eax * 4], 1
    imul eax, eax, JH_SIZE
    lea ebx, [jpeg_huf + eax]
    inc esi
    call jpeg_build
    pop esi
    pop edx
    pop ecx
    test eax, eax
    js .bad
    lea esi, [esi + edx + 17]
    jmp .tab
.ok:
    xor eax, eax
    ret
.bad:
    mov eax, -1
    ret

jpeg_build:
    push esi
    push edi
    push ebp
    mov edi, ebx
    mov ecx, 512
    xor eax, eax
    rep stosd
    xor edx, edx
    xor ecx, ecx
.tot:
    movzx eax, byte [esi + ecx]
    add edx, eax
    inc ecx
    cmp ecx, 16
    jb .tot
    xor ecx, ecx
.cpy:
    cmp ecx, edx
    jae .cpz
    mov al, [esi + 16 + ecx]
    mov [ebx + JH_VALS + ecx], al
    inc ecx
    jmp .cpy
.cpz:
    xor edx, edx
    xor edi, edi
    mov ecx, 1
.len:
    mov eax, edi
    sub eax, edx
    mov [ebx + JH_OFF + ecx * 4], eax
    movzx ebp, byte [esi + ecx - 1]
    mov dword [ebx + JH_MAX + ecx * 4], -1
    test ebp, ebp
    jz .shift
.code:
    mov eax, 1
    shl eax, cl
    cmp edx, eax
    jae .bad
    cmp ecx, 9
    ja .long
    push ecx
    push edx
    neg ecx
    add ecx, 9
    shl edx, cl
    mov eax, 1
    shl eax, cl
    mov ecx, [esp + 4]
    shl ecx, 8
    push ebx
    movzx ebx, byte [ebx + JH_VALS + edi]
    or ecx, ebx
    pop ebx
.fill:
    mov [ebx + JH_LUT + edx * 4], ecx
    inc edx
    dec eax
    jnz .fill
    pop edx
    pop ecx
.long:
    inc edx
    inc edi
    dec ebp
    jnz .code
    lea eax, [edx - 1]
    mov [ebx + JH_MAX + ecx * 4], eax
.shift:
    shl edx, 1
    inc ecx
    cmp ecx, 16
    jbe .len
    xor eax, eax
    jmp .r
.bad:
    mov eax, -1
.r:
    pop ebp
    pop edi
    pop esi
    ret

jpeg_dqt:
.tab:
    test ecx, ecx
    jz .ok
    movzx eax, byte [esi]
    mov edx, eax
    shr edx, 4
    and eax, 15
    cmp eax, 3
    ja .bad
    cmp edx, 1
    ja .bad
    mov dword [jpeg_qok + eax * 4], 1
    shl eax, 8
    lea edi, [jpeg_qt + eax]
    inc esi
    dec ecx
    push ebx
    xor ebx, ebx
    test edx, edx
    jnz .w16
    cmp ecx, 64
    jb .badp
.b8:
    movzx eax, byte [esi + ebx]
    movzx edx, byte [jpeg_nat + ebx]
    mov [edi + edx * 4], eax
    inc ebx
    cmp ebx, 64
    jb .b8
    add esi, 64
    sub ecx, 64
    pop ebx
    jmp .tab
.w16:
    cmp ecx, 128
    jb .badp
.b16:
    movzx eax, word [esi + ebx * 2]
    xchg al, ah
    movzx edx, byte [jpeg_nat + ebx]
    mov [edi + edx * 4], eax
    inc ebx
    cmp ebx, 64
    jb .b16
    add esi, 128
    sub ecx, 128
    pop ebx
    jmp .tab
.badp:
    pop ebx
.bad:
    mov eax, -1
    ret
.ok:
    xor eax, eax
    ret

jpeg_sofseg:
    push ebx
    push esi
    push edi
    push ebp
    cmp dword [jpeg_sof], 0
    jne .bad
    cmp ecx, 6
    jb .bad
    cmp byte [esi], 8
    jne .bad
    movzx eax, word [esi + 1]
    xchg al, ah
    mov [jpeg_h], eax
    test eax, eax
    jz .bad
    cmp eax, JPEG_MAXDIM
    ja .bad
    movzx eax, word [esi + 3]
    xchg al, ah
    mov [jpeg_w], eax
    test eax, eax
    jz .bad
    cmp eax, JPEG_MAXDIM
    ja .bad
    movzx eax, byte [esi + 5]
    mov [jpeg_ncomp], eax
    cmp eax, 1
    je .nc
    cmp eax, 3
    jne .bad
.nc:
    lea edx, [eax + eax * 2 + 6]
    cmp ecx, edx
    jb .bad
    add esi, 6
    mov ebx, jpeg_comp
    xor edi, edi
.comp:
    movzx eax, byte [esi]
    mov [ebx + JC_ID], eax
    movzx eax, byte [esi + 1]
    mov edx, eax
    shr eax, 4
    and edx, 15
    cmp eax, 1
    jb .bad
    cmp eax, 4
    ja .bad
    cmp edx, 1
    jb .bad
    cmp edx, 4
    ja .bad
    mov [ebx + JC_H], eax
    mov [ebx + JC_V], edx
    cmp eax, [jpeg_hmax]
    jbe .h1
    mov [jpeg_hmax], eax
.h1:
    cmp edx, [jpeg_vmax]
    jbe .v1
    mov [jpeg_vmax], edx
.v1:
    movzx eax, byte [esi + 2]
    cmp eax, 3
    ja .bad
    mov [ebx + JC_TQ], eax
    mov eax, edi
    shl eax, 8
    add eax, jpeg_cq
    mov [ebx + JC_QT], eax
    add esi, 3
    add ebx, JC_SIZE
    inc edi
    cmp edi, [jpeg_ncomp]
    jb .comp

    mov eax, [jpeg_hmax]
    shl eax, 3
    mov ecx, eax
    mov eax, [jpeg_w]
    add eax, ecx
    dec eax
    xor edx, edx
    div ecx
    mov [jpeg_mcux], eax
    mov eax, [jpeg_vmax]
    shl eax, 3
    mov ecx, eax
    mov eax, [jpeg_h]
    add eax, ecx
    dec eax
    xor edx, edx
    div ecx
    mov [jpeg_mcuy], eax

    xor ebp, ebp
    mov ebx, jpeg_comp
    xor edi, edi
.csz:
    mov eax, [jpeg_hmax]
    xor edx, edx
    div dword [ebx + JC_H]
    test edx, edx
    jnz .bad
    mov [ebx + JC_SX], eax
    mov eax, [jpeg_vmax]
    xor edx, edx
    div dword [ebx + JC_V]
    test edx, edx
    jnz .bad
    mov [ebx + JC_SY], eax
    mov eax, [jpeg_mcux]
    imul eax, [ebx + JC_H]
    mov [ebx + JC_BW], eax
    mov eax, [jpeg_mcuy]
    imul eax, [ebx + JC_V]
    mov [ebx + JC_BH], eax
    mov eax, [jpeg_w]
    add eax, [ebx + JC_SX]
    dec eax
    xor edx, edx
    div dword [ebx + JC_SX]
    mov [ebx + JC_DW], eax
    add eax, 7
    shr eax, 3
    mov [ebx + JC_NBW], eax
    mov eax, [jpeg_h]
    add eax, [ebx + JC_SY]
    dec eax
    xor edx, edx
    div dword [ebx + JC_SY]
    mov [ebx + JC_DH], eax
    add eax, 7
    shr eax, 3
    mov [ebx + JC_NBH], eax
    mov eax, [ebx + JC_BW]
    imul eax, [ebx + JC_BH]
    shl eax, 6
    add ebp, eax
    cmp dword [jpeg_prog], 0
    je .np
    add ebp, eax
    add ebp, eax
.np:
    mov eax, [jpeg_mcux]
    imul eax, [jpeg_hmax]
    lea ebp, [ebp + eax * 8 + 16]
    add ebx, JC_SIZE
    inc edi
    cmp edi, [jpeg_ncomp]
    jb .csz
    add ebp, 64
    mov [jpeg_need], ebp

    cmp dword [jpeg_ncomp], 3
    jne .cs
    cmp dword [jpeg_jfif], 0
    jne .cs
    mov eax, [jpeg_adobe]
    test eax, eax
    jz .ids
    cmp eax, 1
    jne .cs
    mov dword [jpeg_rgb], 1
    jmp .cs
.ids:
    cmp dword [jpeg_comp + JC_ID], 'R'
    jne .cs
    cmp dword [jpeg_comp + JC_SIZE + JC_ID], 'G'
    jne .cs
    cmp dword [jpeg_comp + 2 * JC_SIZE + JC_ID], 'B'
    jne .cs
    mov dword [jpeg_rgb], 1
.cs:
    mov dword [jpeg_sof], 1
    cmp dword [jpeg_mode], 0
    je .ok

    mov eax, -2
    cmp ebp, [jpeg_wsize]
    ja .r
    mov ebp, [jpeg_work]
    add ebp, 15
    and ebp, -16
    mov ebx, jpeg_comp
    xor edi, edi
.lay:
    mov [ebx + JC_PLANE], ebp
    mov ecx, [ebx + JC_BW]
    imul ecx, [ebx + JC_BH]
    shl ecx, 4
    push edi
    mov edi, ebp
    mov eax, 0x80808080
    rep stosd
    mov ebp, edi
    pop edi
    cmp dword [jpeg_prog], 0
    je .lay2
    mov [ebx + JC_COEF], ebp
    mov ecx, [ebx + JC_BW]
    imul ecx, [ebx + JC_BH]
    shl ecx, 5
    push edi
    mov edi, ebp
    xor eax, eax
    rep stosd
    mov ebp, edi
    pop edi
.lay2:
    mov [ebx + JC_ROW], ebp
    mov eax, [jpeg_mcux]
    imul eax, [jpeg_hmax]
    lea ebp, [ebp + eax * 8 + 16]
    add ebx, JC_SIZE
    inc edi
    cmp edi, [jpeg_ncomp]
    jb .lay
.ok:
    xor eax, eax
    jmp .r
.bad:
    mov eax, -1
.r:
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

jpeg_sos:
    push ebx
    push esi
    push edi
    push ebp
    cmp dword [jpeg_sof], 0
    je .bad
    cmp ecx, 1
    jb .bad
    movzx eax, byte [esi]
    test eax, eax
    jz .bad
    cmp eax, [jpeg_ncomp]
    ja .bad
    mov [jpeg_ns], eax
    lea edx, [eax * 2 + 4]
    cmp ecx, edx
    jb .bad
    inc esi
    xor edi, edi
.sc:
    movzx eax, byte [esi]
    mov ebx, jpeg_comp
    xor ecx, ecx
.fid:
    cmp [ebx + JC_ID], eax
    je .fnd
    add ebx, JC_SIZE
    inc ecx
    cmp ecx, [jpeg_ncomp]
    jb .fid
    jmp .bad
.fnd:
    xor ecx, ecx
.dup:
    cmp ecx, edi
    jae .new
    cmp [jpeg_sc + ecx * 4], ebx
    je .bad
    inc ecx
    jmp .dup
.new:
    mov [jpeg_sc + edi * 4], ebx
    movzx eax, byte [esi + 1]
    mov edx, eax
    shr edx, 4
    and eax, 15
    cmp edx, 3
    ja .bad
    cmp eax, 3
    ja .bad
    mov [ebx + JC_DCT], edx
    add eax, 4
    mov [ebx + JC_ACT], eax
    add esi, 2
    inc edi
    cmp edi, [jpeg_ns]
    jb .sc
    movzx eax, byte [esi]
    mov [jpeg_ss], eax
    movzx eax, byte [esi + 1]
    mov [jpeg_se], eax
    movzx eax, byte [esi + 2]
    mov edx, eax
    shr edx, 4
    and eax, 15
    mov [jpeg_ah], edx
    mov [jpeg_al], eax

    cmp dword [jpeg_prog], 0
    jne .prog
    mov dword [jpeg_ss], 0
    mov dword [jpeg_se], 63
    mov dword [jpeg_blkfn], jpeg_blk_base
    mov ebp, 3
    jmp .tabs
.prog:
    mov eax, [jpeg_ss]
    mov edx, [jpeg_se]
    cmp edx, 63
    ja .bad
    cmp eax, edx
    ja .bad
    cmp dword [jpeg_ah], 13
    ja .bad
    cmp dword [jpeg_al], 13
    ja .bad
    test eax, eax
    jnz .pac
    test edx, edx
    jnz .bad
    xor ebp, ebp
    mov dword [jpeg_blkfn], jpeg_blk_dcref
    cmp dword [jpeg_ah], 0
    jne .tabs
    mov ebp, 1
    mov dword [jpeg_blkfn], jpeg_blk_dc
    jmp .tabs
.pac:
    cmp dword [jpeg_ns], 1
    jne .bad
    mov ebp, 2
    mov dword [jpeg_blkfn], jpeg_blk_ac
    cmp dword [jpeg_ah], 0
    je .tabs
    mov dword [jpeg_blkfn], jpeg_blk_acref
.tabs:

    xor edi, edi
    xor esi, esi
.tb:
    mov ebx, [jpeg_sc + edi * 4]
    mov eax, [ebx + JC_DCT]
    test ebp, 1
    jz .tb1
    cmp dword [jpeg_hok + eax * 4], 0
    je .bad
.tb1:
    imul eax, eax, JH_SIZE
    add eax, jpeg_huf
    mov [ebx + JC_DCT], eax
    mov eax, [ebx + JC_ACT]
    test ebp, 2
    jz .tb2
    cmp dword [jpeg_hok + eax * 4], 0
    je .bad
.tb2:
    imul eax, eax, JH_SIZE
    add eax, jpeg_huf
    mov [ebx + JC_ACT], eax
    cmp dword [ebx + JC_QOK], 0
    jne .tb3
    mov eax, [ebx + JC_TQ]
    cmp dword [jpeg_qok + eax * 4], 0
    je .bad
    push esi
    push edi
    mov esi, eax
    shl esi, 8
    add esi, jpeg_qt
    mov edi, [ebx + JC_QT]
    mov ecx, 64
    rep movsd
    pop edi
    pop esi
    mov dword [ebx + JC_QOK], 1
.tb3:
    mov eax, [ebx + JC_H]
    imul eax, [ebx + JC_V]
    add esi, eax
    inc edi
    cmp edi, [jpeg_ns]
    jb .tb
    cmp dword [jpeg_ns], 1
    je .go
    cmp esi, 10
    ja .bad
.go:
    inc dword [jpeg_nscan]
    call jpeg_scan
    xor eax, eax
    jmp .r
.bad:
    mov eax, -1
.r:
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

jpeg_scan:
    push ebx
    push esi
    push edi
    push ebp
    xor eax, eax
    mov [jpeg_bbuf], eax
    mov [jpeg_bcnt], eax
    mov [jpeg_mark], eax
    mov [jpeg_eobrun], eax
    call jpeg_preds0
    mov eax, [jpeg_rsti]
    mov [jpeg_rstleft], eax
    cmp dword [jpeg_ns], 1
    jne .il
    mov ebx, [jpeg_sc]
    mov eax, [ebx + JC_NBW]
    mov [jpeg_nmx], eax
    mov eax, [ebx + JC_NBH]
    mov [jpeg_nmy], eax
    jmp .rows
.il:
    mov eax, [jpeg_mcux]
    mov [jpeg_nmx], eax
    mov eax, [jpeg_mcuy]
    mov [jpeg_nmy], eax
.rows:
    mov dword [jpeg_my], 0
.my:
    mov dword [jpeg_mx], 0
.mx:
    cmp dword [jpeg_rsti], 0
    je .mcu
    cmp dword [jpeg_rstleft], 0
    jne .rs1
    call jpeg_restart
    mov eax, [jpeg_rsti]
    mov [jpeg_rstleft], eax
.rs1:
    dec dword [jpeg_rstleft]
.mcu:
    cmp dword [jpeg_ns], 1
    jne .mcu_il
    mov ebx, [jpeg_sc]
    mov ecx, [jpeg_mx]
    mov edx, [jpeg_my]
    call [jpeg_blkfn]
    jmp .mnext
.mcu_il:
    xor edi, edi
.mc:
    mov ebx, [jpeg_sc + edi * 4]
    xor esi, esi
.mv:
    xor ebp, ebp
.mh:
    mov ecx, [jpeg_mx]
    imul ecx, [ebx + JC_H]
    add ecx, ebp
    mov edx, [jpeg_my]
    imul edx, [ebx + JC_V]
    add edx, esi
    call [jpeg_blkfn]
    inc ebp
    cmp ebp, [ebx + JC_H]
    jb .mh
    inc esi
    cmp esi, [ebx + JC_V]
    jb .mv
    inc edi
    cmp edi, [jpeg_ns]
    jb .mc
.mnext:
    inc dword [jpeg_mx]
    mov eax, [jpeg_mx]
    cmp eax, [jpeg_nmx]
    jb .mx
    inc dword [jpeg_my]
    mov eax, [jpeg_my]
    cmp eax, [jpeg_nmy]
    jb .my
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

jpeg_preds0:
    mov dword [jpeg_comp + JC_PRED], 0
    mov dword [jpeg_comp + JC_SIZE + JC_PRED], 0
    mov dword [jpeg_comp + 2 * JC_SIZE + JC_PRED], 0
    mov dword [jpeg_comp + 3 * JC_SIZE + JC_PRED], 0
    ret

jpeg_restart:
    push esi
    xor eax, eax
    mov [jpeg_bbuf], eax
    mov [jpeg_bcnt], eax
    mov [jpeg_mark], eax
    mov [jpeg_eobrun], eax
    call jpeg_preds0
    mov esi, [jpeg_ptr]
.f:
    lea eax, [esi + 1]
    cmp eax, [jpeg_end]
    jae .eod
    cmp byte [esi], 0xFF
    jne .n
    mov al, [esi + 1]
    test al, al
    jz .n
    cmp al, 0xFF
    je .n
    and al, 0xF8
    cmp al, 0xD0
    jne .other
    add esi, 2
    jmp .set
.n:
    inc esi
    jmp .f
.other:
    mov dword [jpeg_mark], 1
    jmp .set
.eod:
    mov esi, [jpeg_end]
    mov dword [jpeg_mark], 1
.set:
    mov [jpeg_ptr], esi
    pop esi
    ret

jpeg_fill:
    cmp dword [jpeg_bcnt], 24
    ja .q
    push eax
    push ecx
    push esi
    mov ecx, [jpeg_bcnt]
    mov esi, [jpeg_ptr]
.byte:
    xor eax, eax
    cmp dword [jpeg_mark], 0
    jne .put
    cmp esi, [jpeg_end]
    jae .stop
    mov al, [esi]
    inc esi
    cmp al, 0xFF
    jne .put
    cmp esi, [jpeg_end]
    jae .stopff
    cmp byte [esi], 0
    jne .stopff
    inc esi
    jmp .put
.stopff:
    dec esi
.stop:
    mov dword [jpeg_mark], 1
    xor eax, eax
.put:
    push ecx
    neg ecx
    add ecx, 24
    shl eax, cl
    pop ecx
    or [jpeg_bbuf], eax
    add ecx, 8
    cmp ecx, 24
    jbe .byte
    mov [jpeg_bcnt], ecx
    mov [jpeg_ptr], esi
    pop esi
    pop ecx
    pop eax
.q:
    ret

jpeg_bits:
    xor eax, eax
    test ecx, ecx
    jz .r
    call jpeg_fill
    mov eax, [jpeg_bbuf]
    shl dword [jpeg_bbuf], cl
    sub [jpeg_bcnt], ecx
    push ecx
    neg ecx
    add ecx, 32
    shr eax, cl
    pop ecx
.r:
    ret

jpeg_getext:
    test ecx, ecx
    jz .zero
    call jpeg_bits
    push edx
    mov edx, 1
    dec ecx
    shl edx, cl
    inc ecx
    cmp eax, edx
    jae .pos
    inc eax
    sub eax, edx
    sub eax, edx
.pos:
    pop edx
    ret
.zero:
    xor eax, eax
    ret

jpeg_huff:
    call jpeg_fill
    push ecx
    push edx
    push esi
    mov esi, eax
    mov edx, [jpeg_bbuf]
    mov eax, edx
    shr eax, 23
    mov eax, [esi + JH_LUT + eax * 4]
    test eax, eax
    jz .slow
    mov ecx, eax
    shr ecx, 8
    shl edx, cl
    mov [jpeg_bbuf], edx
    sub [jpeg_bcnt], ecx
    and eax, 0xFF
    jmp .r
.slow:
    mov ecx, 10
.l:
    mov eax, edx
    push ecx
    neg ecx
    add ecx, 32
    shr eax, cl
    pop ecx
    cmp eax, [esi + JH_MAX + ecx * 4]
    jle .found
    inc ecx
    cmp ecx, 16
    jbe .l
    xor eax, eax
    jmp .r
.found:
    add eax, [esi + JH_OFF + ecx * 4]
    and eax, 0xFF
    movzx eax, byte [esi + JH_VALS + eax]
    shl edx, cl
    mov [jpeg_bbuf], edx
    sub [jpeg_bcnt], ecx
.r:
    pop esi
    pop edx
    pop ecx
    ret

jpeg_blk_base:
    push esi
    push edi
    push ecx
    push edx
    mov edi, jpeg_blk
    mov ecx, 32
    xor eax, eax
    rep stosd
    mov eax, [ebx + JC_DCT]
    call jpeg_huff
    mov ecx, eax
    and ecx, 15
    call jpeg_getext
    add eax, [ebx + JC_PRED]
    mov [ebx + JC_PRED], eax
    mov [jpeg_blk], ax
    mov esi, 1
.ac:
    mov eax, [ebx + JC_ACT]
    call jpeg_huff
    mov ecx, eax
    shr eax, 4
    and ecx, 15
    jz .zs
    add esi, eax
    call jpeg_getext
    movzx edx, byte [jpeg_nat + esi]
    mov [jpeg_blk + edx * 2], ax
    inc esi
    cmp esi, 64
    jb .ac
    jmp .idct
.zs:
    cmp eax, 15
    jne .idct
    add esi, 16
    cmp esi, 64
    jb .ac
.idct:
    pop edx
    pop ecx
    mov edi, [ebx + JC_BW]
    shl edi, 3
    imul edx, edi
    shl edx, 3
    lea edi, [edx + ecx * 8]
    add edi, [ebx + JC_PLANE]
    mov edx, [ebx + JC_BW]
    shl edx, 3
    mov esi, jpeg_blk
    push ebx
    mov ebx, [ebx + JC_QT]
    call jpeg_idct
    pop ebx
    pop edi
    pop esi
    ret

jpeg_coefp:
    imul edx, [ebx + JC_BW]
    add edx, ecx
    shl edx, 7
    mov edi, [ebx + JC_COEF]
    add edi, edx
    ret

jpeg_blk_dc:
    push edi
    call jpeg_coefp
    mov eax, [ebx + JC_DCT]
    call jpeg_huff
    mov ecx, eax
    and ecx, 15
    call jpeg_getext
    add eax, [ebx + JC_PRED]
    mov [ebx + JC_PRED], eax
    mov ecx, [jpeg_al]
    shl eax, cl
    mov [edi], ax
    pop edi
    ret

jpeg_blk_dcref:
    push edi
    call jpeg_coefp
    mov ecx, 1
    call jpeg_bits
    test eax, eax
    jz .r
    mov ecx, [jpeg_al]
    mov eax, 1
    shl eax, cl
    or [edi], ax
.r:
    pop edi
    ret

jpeg_blk_ac:
    push esi
    push edi
    call jpeg_coefp
    cmp dword [jpeg_eobrun], 0
    je .go
    dec dword [jpeg_eobrun]
    jmp .r
.go:
    mov esi, [jpeg_ss]
.k:
    cmp esi, [jpeg_se]
    ja .r
    mov eax, [ebx + JC_ACT]
    call jpeg_huff
    mov ecx, eax
    shr eax, 4
    and ecx, 15
    jz .zs
    add esi, eax
    call jpeg_getext
    mov ecx, [jpeg_al]
    shl eax, cl
    movzx edx, byte [jpeg_nat + esi]
    mov [edi + edx * 2], ax
    inc esi
    jmp .k
.zs:
    cmp eax, 15
    jne .eob
    add esi, 16
    jmp .k
.eob:
    mov ecx, eax
    mov edx, 1
    shl edx, cl
    call jpeg_bits
    add eax, edx
    dec eax
    mov [jpeg_eobrun], eax
.r:
    pop edi
    pop esi
    ret

jpeg_blk_acref:
    push esi
    push edi
    push ebp
    call jpeg_coefp
    mov ecx, [jpeg_al]
    mov ebp, 1
    shl ebp, cl
    mov esi, [jpeg_ss]
    cmp dword [jpeg_eobrun], 0
    jne .eobpart
.k:
    cmp esi, [jpeg_se]
    ja .done
    mov eax, [ebx + JC_ACT]
    call jpeg_huff
    mov ecx, eax
    shr eax, 4
    and ecx, 15
    jz .zs
    push eax
    mov ecx, 1
    call jpeg_bits
    mov edx, ebp
    test eax, eax
    jnz .sgn
    neg edx
.sgn:
    pop eax
    jmp .adv
.zs:
    xor edx, edx
    cmp eax, 15
    je .adv
    mov ecx, eax
    push edx
    mov edx, 1
    shl edx, cl
    call jpeg_bits
    add eax, edx
    pop edx
    mov [jpeg_eobrun], eax
    jmp .eobpart
.adv:

    mov ecx, eax
.adl:
    movzx eax, byte [jpeg_nat + esi]
    cmp word [edi + eax * 2], 0
    je .zero
    call jpeg_corr
    jmp .adn
.zero:
    dec ecx
    js .adx
.adn:
    inc esi
    cmp esi, [jpeg_se]
    jbe .adl
.adx:
    test edx, edx
    jz .nx
    movzx eax, byte [jpeg_nat + esi]
    mov [edi + eax * 2], dx
.nx:
    inc esi
    jmp .k
.eobpart:

.el:
    cmp esi, [jpeg_se]
    ja .eobd
    movzx eax, byte [jpeg_nat + esi]
    cmp word [edi + eax * 2], 0
    je .en
    call jpeg_corr
.en:
    inc esi
    jmp .el
.eobd:
    dec dword [jpeg_eobrun]
.done:
    pop ebp
    pop edi
    pop esi
    ret

jpeg_corr:
    push ecx
    push edx
    lea edx, [edi + eax * 2]
    mov ecx, 1
    call jpeg_bits
    test eax, eax
    jz .r
    movsx eax, word [edx]
    test eax, ebp
    jnz .r
    test eax, eax
    js .neg
    add eax, ebp
    jmp .st
.neg:
    sub eax, ebp
.st:
    mov [edx], ax
.r:
    pop edx
    pop ecx
    ret

jpeg_idct_all:
    push ebx
    push esi
    push edi
    push ebp
    mov ebx, jpeg_comp
    mov ebp, [jpeg_ncomp]
.c:
    mov esi, [ebx + JC_COEF]
    mov edx, [ebx + JC_BW]
    shl edx, 3
    xor eax, eax
.r:
    push eax
    mov edi, eax
    imul edi, edx
    shl edi, 3
    add edi, [ebx + JC_PLANE]
    mov ecx, [ebx + JC_BW]
.b:
    push ebx
    push ecx
    mov ebx, [ebx + JC_QT]
    call jpeg_idct
    pop ecx
    pop ebx
    add esi, 128
    add edi, 8
    dec ecx
    jnz .b
    pop eax
    inc eax
    cmp eax, [ebx + JC_BH]
    jb .r
    add ebx, JC_SIZE
    dec ebp
    jnz .c
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

%macro JLD 3
%if %3 == 1
    movsx %1, word [esi + %2 * 16]
    imul %1, [ebx + %2 * 32]
%else
    mov %1, [esi + %2 * 4]
%endif
%endmacro

%macro JCORE 1
    JLD eax, 2, %1
    JLD edx, 6, %1
    lea ecx, [eax + edx]
    imul ecx, ecx, 4433
    imul edx, edx, -15137
    add edx, ecx
    imul eax, eax, 6270
    add eax, ecx
    mov [jpeg_t2], edx
    mov [jpeg_t3], eax
    JLD eax, 0, %1
    JLD edx, 4, %1
    lea ecx, [eax + edx]
    shl ecx, 13
    sub eax, edx
    shl eax, 13
    mov edx, ecx
    add ecx, [jpeg_t3]
    sub edx, [jpeg_t3]
    mov [jpeg_t10], ecx
    mov [jpeg_t13], edx
    mov ecx, eax
    add eax, [jpeg_t2]
    sub ecx, [jpeg_t2]
    mov [jpeg_t11], eax
    mov [jpeg_t12], ecx
    JLD eax, 7, %1
    JLD ecx, 5, %1
    JLD edx, 3, %1
    JLD ebp, 1, %1
    mov [jpeg_z1v], eax
    add [jpeg_z1v], ebp
    mov [jpeg_z2v], ecx
    add [jpeg_z2v], edx
    mov [jpeg_z3v], eax
    add [jpeg_z3v], edx
    mov [jpeg_z4v], ecx
    add [jpeg_z4v], ebp
    imul eax, eax, 2446
    imul ecx, ecx, 16819
    imul edx, edx, 25172
    imul ebp, ebp, 12299
    mov [jpeg_t0], eax
    mov [jpeg_t1], ecx
    mov [jpeg_t2], edx
    mov [jpeg_t3], ebp
    mov eax, [jpeg_z3v]
    add eax, [jpeg_z4v]
    imul eax, eax, 9633
    imul ecx, [jpeg_z3v], -16069
    add ecx, eax
    imul edx, [jpeg_z4v], -3196
    add edx, eax
    imul eax, [jpeg_z1v], -7373
    imul ebp, [jpeg_z2v], -20995
    add [jpeg_t0], eax
    add [jpeg_t0], ecx
    add [jpeg_t1], ebp
    add [jpeg_t1], edx
    add [jpeg_t2], ebp
    add [jpeg_t2], ecx
    add [jpeg_t3], eax
    add [jpeg_t3], edx
%endmacro

%macro JOUT1 4
    mov eax, [%1]
    mov edx, eax
    add eax, [%2]
    sub edx, [%2]
    add eax, 1 << 10
    sar eax, 11
    add edx, 1 << 10
    sar edx, 11
    mov [edi + %3 * 32], eax
    mov [edi + %4 * 32], edx
%endmacro

%macro JLIM 1
    shl %1, 22
    sar %1, 22
    add %1, 128
    cmp %1, 255
    jbe %%ok
    sar %1, 31
    not %1
    and %1, 255
%%ok:
%endmacro

%macro JOUT2 4
    mov eax, [%1]
    mov edx, eax
    add eax, [%2]
    sub edx, [%2]
    add eax, 1 << 17
    sar eax, 18
    add edx, 1 << 17
    sar edx, 18
    JLIM eax
    JLIM edx
    mov [edi + %3], al
    mov [edi + %4], dl
%endmacro

jpeg_idct:
    pushad
    mov [jpeg_ostr], edx
    mov [jpeg_odst], edi
    mov edi, jpeg_ws
    mov dword [jpeg_cnt], 8
.p1:
    mov ax, [esi + 16]
    or ax, [esi + 32]
    or ax, [esi + 48]
    or ax, [esi + 64]
    or ax, [esi + 80]
    or ax, [esi + 96]
    or ax, [esi + 112]
    jnz .p1full
    movsx eax, word [esi]
    imul eax, [ebx]
    shl eax, 2
    mov [edi], eax
    mov [edi + 32], eax
    mov [edi + 64], eax
    mov [edi + 96], eax
    mov [edi + 128], eax
    mov [edi + 160], eax
    mov [edi + 192], eax
    mov [edi + 224], eax
    jmp .p1next
.p1full:
    JCORE 1
    JOUT1 jpeg_t10, jpeg_t3, 0, 7
    JOUT1 jpeg_t11, jpeg_t2, 1, 6
    JOUT1 jpeg_t12, jpeg_t1, 2, 5
    JOUT1 jpeg_t13, jpeg_t0, 3, 4
.p1next:
    add esi, 2
    add ebx, 4
    add edi, 4
    dec dword [jpeg_cnt]
    jnz .p1
    mov esi, jpeg_ws
    mov edi, [jpeg_odst]
    mov dword [jpeg_cnt], 8
.p2:
    JCORE 2
    JOUT2 jpeg_t10, jpeg_t3, 0, 7
    JOUT2 jpeg_t11, jpeg_t2, 1, 6
    JOUT2 jpeg_t12, jpeg_t1, 2, 5
    JOUT2 jpeg_t13, jpeg_t0, 3, 4
    add esi, 32
    add edi, [jpeg_ostr]
    dec dword [jpeg_cnt]
    jnz .p2
    popad
    ret

%macro JCLAMP 1
    cmp %1, 255
    jbe %%ok
    sar %1, 31
    not %1
    and %1, 255
%%ok:
%endmacro

jpeg_output:
    push ebx
    push esi
    push edi
    push ebp
    mov dword [jpeg_y], 0
.row:
    mov ebx, jpeg_comp
    xor edi, edi
.cr:
    mov ecx, [jpeg_y]
    call jpeg_uprow
    mov [jpeg_rows + edi * 4], eax
    add ebx, JC_SIZE
    inc edi
    cmp edi, [jpeg_ncomp]
    jb .cr
    mov edi, [jpeg_y]
    imul edi, [jpeg_ostride]
    add edi, [jpeg_out]
    mov esi, [jpeg_rows]
    xor ecx, ecx
    cmp dword [jpeg_ncomp], 1
    jne .three
.grey:
    movzx eax, byte [esi + ecx]
    imul eax, eax, 0x010101
    mov [edi + ecx * 4], eax
    inc ecx
    cmp ecx, [jpeg_w]
    jb .grey
    jmp .next
.three:
    mov ebx, [jpeg_rows + 4]
    mov ebp, [jpeg_rows + 8]
    cmp dword [jpeg_rgb], 0
    je .ycc
.rgb:
    movzx eax, byte [esi + ecx]
    shl eax, 8
    mov al, [ebx + ecx]
    shl eax, 8
    mov al, [ebp + ecx]
    mov [edi + ecx * 4], eax
    inc ecx
    cmp ecx, [jpeg_w]
    jb .rgb
    jmp .next
.ycc:
    push ecx
    movzx eax, byte [ebp + ecx]
    sub eax, 128
    imul edx, eax, 91881
    add edx, 32768
    sar edx, 16
    imul eax, eax, -46802
    movzx ecx, byte [ebx + ecx]
    sub ecx, 128
    push ecx
    imul ecx, ecx, -22554
    add eax, ecx
    add eax, 32768
    sar eax, 16
    pop ecx
    imul ecx, ecx, 116130
    add ecx, 32768
    sar ecx, 16
    xchg ecx, [esp]
    push ecx
    movzx ecx, byte [esi + ecx]
    add edx, ecx
    add eax, ecx
    add ecx, [esp + 4]
    JCLAMP edx
    JCLAMP eax
    JCLAMP ecx
    shl edx, 16
    shl eax, 8
    or eax, edx
    or eax, ecx
    pop ecx
    add esp, 4
    mov [edi + ecx * 4], eax
    inc ecx
    cmp ecx, [jpeg_w]
    jb .ycc
.next:
    inc dword [jpeg_y]
    mov eax, [jpeg_y]
    cmp eax, [jpeg_h]
    jb .row
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

jpeg_uprow:
    push ebx
    push esi
    push edi
    push ebp
    mov esi, [ebx + JC_PLANE]
    mov ebp, [ebx + JC_BW]
    shl ebp, 3
    mov edi, [ebx + JC_ROW]
    mov eax, [ebx + JC_SX]
    mov edx, [ebx + JC_SY]
    cmp eax, 1
    jne .notcopy
    cmp edx, 1
    jne .notcopy
    imul ecx, ebp
    lea eax, [esi + ecx]
    jmp .r
.notcopy:
    cmp eax, 2
    ja .box
    cmp edx, 2
    ja .box
    cmp eax, 2
    jne .fancy
    cmp dword [ebx + JC_DW], 2
    jbe .box
.fancy:
    cmp edx, 1
    je .h2v1

    mov edx, ecx
    shr edx, 1
    mov eax, edx
    test ecx, 1
    jnz .down
    test eax, eax
    jz .far
    dec eax
    jmp .far
.down:
    inc eax
    cmp eax, [ebx + JC_DH]
    jb .far
    dec eax
.far:
    imul edx, ebp
    add edx, esi
    imul eax, ebp
    add esi, eax
    and ecx, 1
    cmp dword [ebx + JC_SX], 1
    je .h1v2

    mov ebp, [ebx + JC_DW]
    xor ecx, ecx
.h22:
    call .cs
    push eax
    lea eax, [ecx - 1]
    test ecx, ecx
    jnz .h22a
    xor eax, eax
.h22a:
    push ecx
    mov ecx, eax
    call .cs
    pop ecx
    mov ebx, [esp]
    lea ebx, [ebx + ebx * 2]
    add eax, ebx
    add eax, 8
    shr eax, 4
    mov [edi + ecx * 2], al
    lea eax, [ecx + 1]
    cmp eax, ebp
    jb .h22b
    mov eax, ecx
.h22b:
    push ecx
    mov ecx, eax
    call .cs
    pop ecx
    pop ebx
    lea ebx, [ebx + ebx * 2]
    add eax, ebx
    add eax, 7
    shr eax, 4
    mov [edi + ecx * 2 + 1], al
    inc ecx
    cmp ecx, ebp
    jb .h22
    jmp .done
.cs:
    movzx eax, byte [edx + ecx]
    lea eax, [eax + eax * 2]
    push ebx
    movzx ebx, byte [esi + ecx]
    add eax, ebx
    pop ebx
    ret
.h1v2:
    lea ebp, [ecx + 1]
    mov ecx, [ebx + JC_DW]
    xor ebx, ebx
.h12:
    movzx eax, byte [edx + ebx]
    lea eax, [eax + eax * 2]
    push ecx
    movzx ecx, byte [esi + ebx]
    add eax, ecx
    pop ecx
    add eax, ebp
    shr eax, 2
    mov [edi + ebx], al
    inc ebx
    cmp ebx, ecx
    jb .h12
    jmp .done
.h2v1:
    imul ecx, ebp
    add esi, ecx
    mov ebp, [ebx + JC_DW]
    xor ecx, ecx
.h21:
    movzx eax, byte [esi + ecx]
    lea edx, [eax + eax * 2]
    mov eax, ecx
    test ecx, ecx
    jz .h21a
    dec eax
.h21a:
    movzx eax, byte [esi + eax]
    add eax, edx
    inc eax
    shr eax, 2
    mov [edi + ecx * 2], al
    lea eax, [ecx + 1]
    cmp eax, ebp
    jb .h21b
    mov eax, ecx
.h21b:
    movzx eax, byte [esi + eax]
    add eax, edx
    add eax, 2
    shr eax, 2
    mov [edi + ecx * 2 + 1], al
    inc ecx
    cmp ecx, ebp
    jb .h21
    jmp .done
.box:
    mov eax, ecx
    xor edx, edx
    div dword [ebx + JC_SY]
    imul eax, ebp
    add esi, eax
    xor ecx, ecx
.bx:
    mov eax, ecx
    xor edx, edx
    div dword [ebx + JC_SX]
    mov al, [esi + eax]
    mov [edi + ecx], al
    inc ecx
    cmp ecx, [jpeg_w]
    jb .bx
.done:
    mov eax, edi
.r:
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret
