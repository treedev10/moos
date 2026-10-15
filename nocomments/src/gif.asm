%include "src/module.inc"

GIF_MAXDIM  equ 16384
GIF_MAXPIX  equ 0x4000000

section .bss
alignb 4
gif_pal     resd 256
gif_prefix  resw 4096
gif_lens    resw 4096
gif_suffix  resb 4096
gif_firstc  resb 4096

gif_z0:
gif_end     resd 1
gif_sw      resd 1
gif_sh      resd 1
gif_w       resd 1
gif_h       resd 1
gif_gct     resd 1
gif_gctn    resd 1
gif_lct     resd 1
gif_lctn    resd 1
gif_trans   resd 1
gif_fx      resd 1
gif_fy      resd 1
gif_fw      resd 1
gif_fh      resd 1
gif_ilace   resd 1
gif_lzw     resd 1
gif_need    resd 1
gif_z1:

gif_p       resd 1
gif_blk     resd 1
gif_bb      resd 1
gif_bc      resd 1
gif_eod     resd 1
gif_buf     resd 1
gif_total   resd 1
gif_pos     resd 1
gif_clear   resd 1
gif_csize   resd 1
gif_next    resd 1
gif_prev    resd 1

gif_out     resd 1
gif_ostride resd 1
gif_bg      resd 1
gif_fill    resd 1

section .text

EXPORT(gif_info)
gif_info:
    CENTER
    mov esi, ARG(0)
    mov ecx, ARG(1)
    call gif_hdr
    test eax, eax
    js .r
    mov edx, ARG(2)
    mov eax, [gif_w]
    mov [edx], eax
    mov edx, ARG(3)
    mov eax, [gif_h]
    mov [edx], eax
    mov edx, ARG(4)
    mov eax, [gif_need]
    mov [edx], eax
    xor eax, eax
.r:
    CLEAVE

EXPORT(gif_decode)
gif_decode:
    CENTER
    mov esi, ARG(0)
    mov ecx, ARG(1)
    call gif_hdr
    test eax, eax
    js .r
    mov eax, -2
    mov edx, [gif_need]
    cmp edx, ARG(6)
    ja .r
    mov eax, -1
    mov edx, ARG(3)
    cmp edx, [gif_w]
    jb .r
    shl edx, 2
    mov [gif_ostride], edx
    mov eax, ARG(2)
    mov [gif_out], eax
    mov eax, ARG(4)
    and eax, 0xFFFFFF
    mov [gif_bg], eax
    mov eax, ARG(5)
    mov [gif_buf], eax
    call gif_palette

    mov eax, [gif_pal]
    xor edx, edx
    mov ecx, [gif_trans]
    test ecx, ecx
    jz .f1
    mov eax, [gif_bg]
    lea edx, [ecx - 1]
.f1:
    mov [gif_fill], eax
    mov edi, [gif_buf]
    mov ecx, [gif_fw]
    imul ecx, [gif_fh]
    mov [gif_total], ecx
    mov al, dl
    rep stosb
    mov edi, [gif_out]
    xor ebx, ebx
.fr:
    mov ecx, [gif_w]
    mov eax, [gif_fill]
    push edi
    rep stosd
    pop edi
    add edi, [gif_ostride]
    inc ebx
    cmp ebx, [gif_h]
    jb .fr
    call gif_lzwdec
    call gif_draw
    xor eax, eax
.r:
    CLEAVE

gif_hdr:
    push ebx
    push esi
    push edi
    push ebp
    push ecx
    mov edi, gif_z0
    mov ecx, (gif_z1 - gif_z0) / 4
    xor eax, eax
    rep stosd
    pop ecx
    lea edx, [esi + ecx]
    mov [gif_end], edx
    cmp ecx, 13
    jb .bad
    cmp dword [esi], 'GIF8'
    jne .bad
    mov al, [esi + 4]
    cmp al, '7'
    je .sig2
    cmp al, '9'
    jne .bad
.sig2:
    cmp byte [esi + 5], 'a'
    jne .bad
    movzx eax, word [esi + 6]
    mov [gif_sw], eax
    movzx eax, word [esi + 8]
    mov [gif_sh], eax
    movzx eax, byte [esi + 10]
    add esi, 13
    test al, 0x80
    jz .blocks
    call .table
    mov [gif_gct], edi
    mov [gif_gctn], ecx
.blocks:
    cmp esi, edx
    jae .bad
    movzx eax, byte [esi]
    inc esi
    cmp eax, 0x2C
    je .image
    cmp eax, 0x21
    jne .bad
    cmp esi, edx
    jae .bad
    movzx eax, byte [esi]
    inc esi
    cmp eax, 0xF9
    jne .skip
    lea ecx, [esi + 5]
    cmp ecx, edx
    ja .skip
    cmp byte [esi], 4
    jb .skip
    test byte [esi + 1], 1
    jz .skip
    movzx ecx, byte [esi + 4]
    inc ecx
    mov [gif_trans], ecx
.skip:
    cmp esi, edx
    jae .bad
    movzx eax, byte [esi]
    inc esi
    test eax, eax
    jz .blocks
    add esi, eax
    cmp esi, edx
    ja .bad
    jmp .skip
.image:
    lea ecx, [esi + 9]
    cmp ecx, edx
    ja .bad
    movzx eax, word [esi]
    mov [gif_fx], eax
    movzx eax, word [esi + 2]
    mov [gif_fy], eax
    movzx eax, word [esi + 4]
    mov [gif_fw], eax
    movzx eax, word [esi + 6]
    mov [gif_fh], eax
    movzx eax, byte [esi + 8]
    add esi, 9
    mov ecx, eax
    shr ecx, 6
    and ecx, 1
    mov [gif_ilace], ecx
    test al, 0x80
    jz .nolct
    call .table
    mov [gif_lct], edi
    mov [gif_lctn], ecx
.nolct:
    cmp esi, edx
    jae .bad
    mov [gif_lzw], esi
    mov eax, [gif_fx]
    add eax, [gif_fw]
    cmp eax, [gif_sw]
    jae .w1
    mov eax, [gif_sw]
.w1:
    mov [gif_w], eax
    mov ecx, [gif_fy]
    add ecx, [gif_fh]
    cmp ecx, [gif_sh]
    jae .h1
    mov ecx, [gif_sh]
.h1:
    mov [gif_h], ecx
    test eax, eax
    jz .bad
    test ecx, ecx
    jz .bad
    cmp eax, GIF_MAXDIM
    ja .bad
    cmp ecx, GIF_MAXDIM
    ja .bad
    imul ecx, eax
    cmp ecx, GIF_MAXPIX
    ja .bad
    mov eax, [gif_fw]
    imul eax, [gif_fh]
    add eax, 16
    mov [gif_need], eax
    xor eax, eax
    jmp .r
.table:
    mov ecx, eax
    and ecx, 7
    mov eax, 2
    shl eax, cl
    mov ecx, eax
    mov edi, esi
    lea eax, [eax + eax * 2]
    add esi, eax
    cmp esi, edx
    ja .tbad
    ret
.tbad:
    add esp, 4
.bad:
    mov eax, -1
.r:
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

gif_palette:
    push esi
    push edi
    mov edi, gif_pal
    mov ecx, 256
    xor eax, eax
    rep stosd
    mov esi, [gif_lct]
    mov ecx, [gif_lctn]
    test esi, esi
    jnz .tab
    mov esi, [gif_gct]
    mov ecx, [gif_gctn]
    test esi, esi
    jnz .tab
    xor ecx, ecx
.grey:
    imul eax, ecx, 0x010101
    mov [gif_pal + ecx * 4], eax
    inc ecx
    cmp ecx, 256
    jb .grey
    jmp .r
.tab:
    xor edx, edx
.t:
    movzx eax, byte [esi]
    shl eax, 8
    mov al, [esi + 1]
    shl eax, 8
    mov al, [esi + 2]
    mov [gif_pal + edx * 4], eax
    add esi, 3
    inc edx
    cmp edx, ecx
    jb .t
.r:
    pop edi
    pop esi
    ret

gif_code:
    push edx
    push esi
.fill:
    cmp [gif_bc], ecx
    jae .take
    cmp dword [gif_eod], 0
    jne .end
    mov esi, [gif_p]
    cmp dword [gif_blk], 0
    jne .byte
    cmp esi, [gif_end]
    jae .eod
    movzx eax, byte [esi]
    inc esi
    mov [gif_p], esi
    test eax, eax
    jz .eod
    mov [gif_blk], eax
.byte:
    cmp esi, [gif_end]
    jae .eod
    movzx eax, byte [esi]
    inc esi
    mov [gif_p], esi
    dec dword [gif_blk]
    push ecx
    mov ecx, [gif_bc]
    shl eax, cl
    or [gif_bb], eax
    add ecx, 8
    mov [gif_bc], ecx
    pop ecx
    jmp .fill
.take:
    mov eax, [gif_bb]
    shr dword [gif_bb], cl
    sub [gif_bc], ecx
    mov edx, 1
    shl edx, cl
    dec edx
    and eax, edx
    clc
    pop esi
    pop edx
    ret
.eod:
    mov dword [gif_eod], 1
.end:
    stc
    pop esi
    pop edx
    ret

gif_lzwdec:
    push ebx
    push esi
    push edi
    push ebp
    mov esi, [gif_lzw]
    movzx ecx, byte [esi]
    inc esi
    mov [gif_p], esi
    xor eax, eax
    mov [gif_blk], eax
    mov [gif_bb], eax
    mov [gif_bc], eax
    mov [gif_eod], eax
    mov [gif_pos], eax
    cmp ecx, 1
    jb .done
    cmp ecx, 8
    ja .done
    mov eax, 1
    shl eax, cl
    mov [gif_clear], eax
    xor edx, edx
.init:
    mov [gif_suffix + edx], dl
    mov [gif_firstc + edx], dl
    mov word [gif_lens + edx * 2], 1
    mov word [gif_prefix + edx * 2], 0
    inc edx
    cmp edx, eax
    jb .init
.reset:
    mov eax, [gif_clear]
    bsf ecx, eax
    inc ecx
    mov [gif_csize], ecx
    add eax, 2
    mov [gif_next], eax
    mov dword [gif_prev], -1
.code:
    mov eax, [gif_pos]
    cmp eax, [gif_total]
    jae .done
    mov ecx, [gif_csize]
    call gif_code
    jc .done
    mov edx, [gif_clear]
    cmp eax, edx
    je .reset
    inc edx
    cmp eax, edx
    je .done
    mov ebx, [gif_prev]
    test ebx, ebx
    jns .known
    cmp eax, [gif_clear]
    jae .done
    mov [gif_prev], eax
    call gif_put
    jmp .code
.known:
    mov ecx, [gif_next]
    cmp eax, ecx
    jb .intab
    jne .done
    cmp ecx, 4096
    jae .done
    movzx edx, byte [gif_firstc + ebx]
    call gif_add
    call gif_put
    jmp .grow
.intab:
    movzx edx, byte [gif_firstc + eax]
    cmp ecx, 4096
    jae .put
    call gif_add
.put:
    call gif_put
.grow:
    mov [gif_prev], eax
    mov ecx, [gif_csize]
    mov edx, 1
    shl edx, cl
    cmp [gif_next], edx
    jb .code
    cmp ecx, 12
    jae .code
    inc dword [gif_csize]
    jmp .code
.done:
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

gif_add:
    mov ecx, [gif_next]
    mov [gif_prefix + ecx * 2], bx
    mov [gif_suffix + ecx], dl
    mov dl, [gif_firstc + ebx]
    mov [gif_firstc + ecx], dl
    movzx edx, word [gif_lens + ebx * 2]
    inc edx
    mov [gif_lens + ecx * 2], dx
    inc dword [gif_next]
    ret

gif_put:
    push eax
    push ebx
    movzx ecx, word [gif_lens + eax * 2]
    mov edi, [gif_buf]
    mov ebx, [gif_pos]
    add [gif_pos], ecx
    add edi, ebx
    add ebx, ecx
.ch:
    dec ebx
    dec ecx
    js .r
    cmp ebx, [gif_total]
    jae .skip
    mov dl, [gif_suffix + eax]
    mov [edi + ecx], dl
.skip:
    movzx eax, word [gif_prefix + eax * 2]
    jmp .ch
.r:
    pop ebx
    pop eax
    ret

gif_draw:
    push ebx
    push esi
    push edi
    push ebp
    mov esi, [gif_buf]
    xor ebp, ebp
    xor ebx, ebx
    cmp dword [gif_ilace], 0
    jne .row
    mov ebp, 4
.row:
    cmp ebx, [gif_fh]
    jae .pass
    mov edi, ebx
    add edi, [gif_fy]
    imul edi, [gif_ostride]
    add edi, [gif_out]
    mov eax, [gif_fx]
    lea edi, [edi + eax * 4]
    xor ecx, ecx
.px:
    cmp ecx, [gif_fw]
    jae .rowd
    movzx eax, byte [esi + ecx]
    mov edx, [gif_trans]
    dec edx
    cmp eax, edx
    je .tr
    mov eax, [gif_pal + eax * 4]
    jmp .st
.tr:
    mov eax, [gif_bg]
.st:
    mov [edi + ecx * 4], eax
    inc ecx
    jmp .px
.rowd:
    add esi, [gif_fw]
    cmp ebp, 4
    je .s1
    movzx eax, byte [gif_istep + ebp]
    add ebx, eax
    jmp .row
.s1:
    inc ebx
    jmp .row
.pass:
    cmp ebp, 3
    jae .done
    inc ebp
    movzx ebx, byte [gif_istart + ebp]
    jmp .row
.done:
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

section .data
gif_istart: db 0, 4, 2, 1
gif_istep:  db 8, 8, 4, 2
section .text
