%include "src/module.inc"
%ifdef NATIVE
extern inflate_buf
%endif

PNG_MAXDIM  equ 16384
PNG_MAXPIX  equ 0x4000000

section .data

png_adam:   dd 0, 0, 8, 8,  4, 0, 8, 8,  0, 4, 4, 8,  2, 0, 4, 4
            dd 0, 2, 2, 4,  1, 0, 2, 2,  0, 1, 1, 2
png_chans:  db 1, 0, 3, 1, 2, 0, 4

section .bss
alignb 4
png_pal     resd 256
png_trns    resb 256

png_z0:
png_w       resd 1
png_h       resd 1
png_depth   resd 1
png_ctype   resd 1
png_ilace   resd 1
png_pbits   resd 1
png_fbpp    resd 1
png_idat    resd 1
png_raw     resd 1
png_maxrb   resd 1
png_need    resd 1
png_copy    resd 1
png_npal    resd 1
png_ntrns   resd 1
png_haskey  resd 1
png_keyr    resd 1
png_keyg    resd 1
png_keyb    resd 1
png_end     resd 1
png_z1:
png_pass    resd 1
png_px0     resd 1
png_py0     resd 1
png_pdx     resd 1
png_pdy     resd 1
png_pw      resd 1
png_ph      resd 1
png_rb      resd 1
png_row     resd 1
png_prior   resd 1
png_zero    resd 1
png_rawp    resd 1
png_olen    resd 1
png_out     resd 1
png_ostride resd 1
png_bg      resd 1
png_yy      resd 1
png_optr    resd 1

section .text

EXPORT(png_info)
png_info:
    CENTER
    mov esi, ARG(0)
    mov ecx, ARG(1)
    xor edx, edx
    call png_hdr
    test eax, eax
    js .r
    mov edx, ARG(2)
    mov eax, [png_w]
    mov [edx], eax
    mov edx, ARG(3)
    mov eax, [png_h]
    mov [edx], eax
    mov edx, ARG(4)
    mov eax, [png_need]
    mov [edx], eax
    xor eax, eax
.r:
    CLEAVE

EXPORT(png_decode)
png_decode:
    CENTER
    sub esp, 4
    mov esi, ARG(0)
    mov ecx, ARG(1)
    xor edx, edx
    call png_hdr
    test eax, eax
    js .r
    mov eax, -2
    mov edx, [png_need]
    cmp edx, ARG(6)
    ja .r
    mov eax, -1
    mov edx, ARG(3)
    cmp edx, [png_w]
    jb .r
    mov esi, ARG(0)
    mov ecx, ARG(1)
    mov edx, ARG(5)
    call png_hdr
    test eax, eax
    js .r
    mov eax, ARG(3)
    shl eax, 2
    mov [png_ostride], eax
    mov eax, ARG(2)
    mov [png_out], eax
    mov eax, ARG(4)
    and eax, 0xFFFFFF
    mov [png_bg], eax
    mov edi, ARG(5)
    add edi, [png_idat]
    mov [png_rawp], edi
    lea eax, [ebp - 16]
    push 1
    push eax
    push dword [png_raw]
    push edi
    push dword [png_idat]
    push dword ARG(5)
    call inflate_buf
    add esp, 24
    mov ecx, [ebp - 16]
    cmp ecx, [png_raw]
    jbe .ol
    mov ecx, [png_raw]
.ol:
    mov eax, -1
    test ecx, ecx
    jz .r
    mov edi, [png_rawp]
    add edi, ecx
    neg ecx
    add ecx, [png_raw]
    mov eax, [png_maxrb]
    lea ecx, [ecx + eax + 1]
    xor eax, eax
    rep stosb
    mov eax, [png_rawp]
    add eax, [png_raw]
    mov [png_zero], eax
    call png_passes
    xor eax, eax
.r:
    add esp, 4
    CLEAVE

png_hdr:
    push ebx
    push esi
    push edi
    push ebp
    push edx
    push ecx
    mov edi, png_z0
    mov ecx, (png_z1 - png_z0) / 4
    xor eax, eax
    rep stosd
    mov edi, png_pal
    mov ecx, 256
    mov eax, 0xFF000000
    rep stosd
    pop ecx
    pop edx
    mov [png_copy], edx
    lea eax, [esi + ecx]
    mov [png_end], eax
    cmp ecx, 8 + 25
    jb .bad
    cmp dword [esi], 0x474E5089
    jne .bad
    cmp dword [esi + 4], 0x0A1A0A0D
    jne .bad
    cmp dword [esi + 8], 0x0D000000
    jne .bad
    cmp dword [esi + 12], 'IHDR'
    jne .bad
    mov eax, [esi + 16]
    bswap eax
    mov [png_w], eax
    test eax, eax
    jz .bad
    cmp eax, PNG_MAXDIM
    ja .bad
    mov eax, [esi + 20]
    bswap eax
    mov [png_h], eax
    test eax, eax
    jz .bad
    cmp eax, PNG_MAXDIM
    ja .bad
    imul eax, [png_w]
    cmp eax, PNG_MAXPIX
    ja .bad
    movzx eax, byte [esi + 24]
    mov [png_depth], eax
    movzx edx, byte [esi + 25]
    mov [png_ctype], edx
    cmp word [esi + 26], 0
    jne .bad
    movzx ecx, byte [esi + 28]
    cmp ecx, 1
    ja .bad
    mov [png_ilace], ecx

    cmp edx, 6
    ja .bad
    movzx ecx, byte [png_chans + edx]
    test ecx, ecx
    jz .bad
    cmp eax, 16
    ja .bad
    bsf ebx, eax
    jz .bad
    push ecx
    mov ecx, ebx
    mov ebx, 1
    shl ebx, cl
    pop ecx
    cmp ebx, eax
    jne .bad
    cmp edx, 3
    jne .d1
    cmp eax, 8
    ja .bad
.d1:
    test edx, edx
    jz .d2
    cmp edx, 3
    je .d2
    cmp eax, 8
    jb .bad
.d2:
    imul eax, ecx
    mov [png_pbits], eax
    shr eax, 3
    jnz .fb
    inc eax
.fb:
    mov [png_fbpp], eax

    xor ebx, ebx
    cmp dword [png_ilace], 0
    je .one
    mov ebx, 1
.sz:
    call png_setpass
    mov eax, [png_ph]
    test eax, eax
    jz .szn
    cmp dword [png_pw], 0
    je .szn
    mov ecx, [png_rb]
    cmp ecx, [png_maxrb]
    jbe .sz1
    mov [png_maxrb], ecx
.sz1:
    inc ecx
    imul ecx, eax
    add [png_raw], ecx
.szn:
    inc ebx
    cmp ebx, 7
    jbe .sz
    jmp .chunks
.one:
    call png_setpass
    mov ecx, [png_rb]
    mov [png_maxrb], ecx
    inc ecx
    imul ecx, [png_ph]
    mov [png_raw], ecx
.chunks:

    add esi, 33
.ch:
    mov eax, [png_end]
    sub eax, esi
    cmp eax, 12
    jb .done
    mov ecx, [esi]
    bswap ecx
    sub eax, 12
    mov ebx, [esi + 4]
    lea edi, [esi + 8]
    cmp ecx, eax
    jbe .cl
    mov ecx, eax
    cmp ebx, 'IDAT'
    jne .done
.cl:
    lea esi, [edi + ecx + 4]
    cmp ebx, 'IEND'
    je .done
    cmp ebx, 'IDAT'
    je .idat
    cmp ebx, 'PLTE'
    je .plte
    cmp ebx, 'tRNS'
    je .trns
    jmp .ch
.idat:
    mov edx, [png_copy]
    test edx, edx
    jz .id1
    push esi
    push edi
    mov esi, edi
    mov edi, edx
    add edi, [png_idat]
    push ecx
    rep movsb
    pop ecx
    pop edi
    pop esi
.id1:
    add [png_idat], ecx
    cmp dword [png_idat], 0x40000000
    ja .bad
    jmp .ch
.plte:
    mov eax, ecx
    xor edx, edx
    push ecx
    mov ecx, 3
    div ecx
    pop ecx
    cmp eax, 256
    jbe .pl1
    mov eax, 256
.pl1:
    mov [png_npal], eax
    xor edx, edx
.pl:
    cmp edx, eax
    jae .ch
    movzx ebx, byte [edi]
    shl ebx, 8
    mov bl, [edi + 1]
    shl ebx, 8
    mov bl, [edi + 2]
    or ebx, 0xFF000000
    mov [png_pal + edx * 4], ebx
    add edi, 3
    inc edx
    jmp .pl
.trns:
    mov eax, [png_ctype]
    cmp eax, 3
    je .tp
    test eax, eax
    jnz .trgb
    cmp ecx, 2
    jb .ch
    movzx eax, word [edi]
    xchg al, ah
    mov [png_keyr], eax
    mov dword [png_haskey], 1
    jmp .ch
.trgb:
    cmp eax, 2
    jne .ch
    cmp ecx, 6
    jb .ch
    movzx eax, word [edi]
    xchg al, ah
    mov [png_keyr], eax
    movzx eax, word [edi + 2]
    xchg al, ah
    mov [png_keyg], eax
    movzx eax, word [edi + 4]
    xchg al, ah
    mov [png_keyb], eax
    mov dword [png_haskey], 1
    jmp .ch
.tp:
    cmp ecx, 256
    jbe .tp1
    mov ecx, 256
.tp1:
    mov [png_ntrns], ecx
    xor edx, edx
.tpl:
    cmp edx, ecx
    jae .ch
    mov al, [edi + edx]
    mov [png_trns + edx], al
    inc edx
    jmp .tpl
.done:
    mov ecx, [png_ntrns]
    xor edx, edx
.ta:
    cmp edx, ecx
    jae .ta1
    mov al, [png_trns + edx]
    mov [png_pal + edx * 4 + 3], al
    inc edx
    jmp .ta
.ta1:
    mov eax, [png_idat]
    add eax, [png_raw]
    add eax, [png_maxrb]
    add eax, 16
    mov [png_need], eax
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

png_setpass:
    test ebx, ebx
    jnz .adam
    xor eax, eax
    mov [png_px0], eax
    mov [png_py0], eax
    inc eax
    mov [png_pdx], eax
    mov [png_pdy], eax
    mov eax, [png_w]
    mov [png_pw], eax
    mov eax, [png_h]
    mov [png_ph], eax
    jmp .rb
.adam:
    mov eax, ebx
    shl eax, 4
    mov ecx, [png_adam + eax - 16]
    mov [png_px0], ecx
    mov ecx, [png_adam + eax - 12]
    mov [png_py0], ecx
    mov ecx, [png_adam + eax - 8]
    mov [png_pdx], ecx
    mov ecx, [png_adam + eax - 4]
    mov [png_pdy], ecx
    mov eax, [png_w]
    sub eax, [png_px0]
    jbe .zw
    add eax, [png_pdx]
    dec eax
    xor edx, edx
    div dword [png_pdx]
    jmp .w
.zw:
    xor eax, eax
.w:
    mov [png_pw], eax
    mov eax, [png_h]
    sub eax, [png_py0]
    jbe .zh
    add eax, [png_pdy]
    dec eax
    xor edx, edx
    div dword [png_pdy]
    jmp .h
.zh:
    xor eax, eax
.h:
    mov [png_ph], eax
.rb:
    mov eax, [png_pw]
    imul eax, [png_pbits]
    add eax, 7
    shr eax, 3
    mov [png_rb], eax
    ret

png_passes:
    push ebx
    push esi
    push edi
    push ebp
    mov esi, [png_rawp]
    xor ebx, ebx
    cmp dword [png_ilace], 0
    je .pass
    inc ebx
.pass:
    call png_setpass
    cmp dword [png_pw], 0
    je .pn
    cmp dword [png_ph], 0
    je .pn
    mov eax, [png_zero]
    mov [png_prior], eax
    mov dword [png_yy], 0
.row:
    lea eax, [esi + 1]
    mov [png_row], eax
    movzx eax, byte [esi]
    call png_unfilter
    mov eax, [png_yy]
    imul eax, [png_pdy]
    add eax, [png_py0]
    imul eax, [png_ostride]
    add eax, [png_out]
    mov edx, [png_px0]
    lea eax, [eax + edx * 4]
    mov [png_optr], eax
    call png_draw
    mov eax, [png_row]
    mov [png_prior], eax
    add eax, [png_rb]
    mov esi, eax
    inc dword [png_yy]
    mov eax, [png_yy]
    cmp eax, [png_ph]
    jb .row
.pn:
    test ebx, ebx
    jz .done
    inc ebx
    cmp ebx, 7
    jbe .pass
.done:
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

png_unfilter:
    push ebx
    push esi
    mov edi, [png_row]
    mov esi, [png_prior]
    mov ecx, [png_rb]
    mov ebx, [png_fbpp]
    cmp eax, 1
    je .sub
    cmp eax, 2
    je .up
    cmp eax, 3
    je .avg
    cmp eax, 4
    je .paeth
    jmp .r
.sub:
    mov edx, ebx
.s1:
    cmp edx, ecx
    jae .r
    mov eax, edx
    sub eax, ebx
    mov al, [edi + eax]
    add [edi + edx], al
    inc edx
    jmp .s1
.up:
    xor edx, edx
.u1:
    cmp edx, ecx
    jae .r
    mov al, [esi + edx]
    add [edi + edx], al
    inc edx
    jmp .u1
.avg:
    xor edx, edx
.a1:
    cmp edx, ecx
    jae .r
    movzx eax, byte [esi + edx]
    cmp edx, ebx
    jb .a2
    push edx
    sub edx, ebx
    movzx edx, byte [edi + edx]
    add eax, edx
    pop edx
.a2:
    shr eax, 1
    add [edi + edx], al
    inc edx
    jmp .a1
.paeth:
    xor edx, edx
.p1:
    cmp edx, ecx
    jae .r
    push ecx
    push ebp
    movzx eax, byte [esi + edx]
    xor ecx, ecx
    xor ebp, ebp
    cmp edx, ebx
    jb .p2
    push edx
    sub edx, ebx
    movzx ecx, byte [edi + edx]
    movzx ebp, byte [esi + edx]
    pop edx
.p2:
    call png_paeth
    add [edi + edx], al
    pop ebp
    pop ecx
    inc edx
    jmp .p1
.r:
    pop esi
    pop ebx
    ret

png_paeth:
    push ebx
    push esi
    push edi
    mov esi, eax
    mov edi, ecx
    sub edi, ebp
    jns .pb
    neg edi
.pb:
    mov ebx, eax
    sub ebx, ebp
    jns .pa
    neg ebx
.pa:
    lea eax, [ecx + esi]
    sub eax, ebp
    sub eax, ebp
    jns .pc
    neg eax
.pc:
    cmp ebx, edi
    ja .nb
    cmp ebx, eax
    ja .nb
    mov eax, ecx
    jmp .r
.nb:
    cmp edi, eax
    ja .c
    mov eax, esi
    jmp .r
.c:
    mov eax, ebp
.r:
    pop edi
    pop esi
    pop ebx
    ret

png_draw:
    push ebx
    push esi
    push ebp
    mov esi, [png_row]
    mov edi, [png_optr]
    mov ebp, [png_pdx]
    shl ebp, 2
    xor ebx, ebx
.px:
    mov eax, [png_ctype]
    mov ecx, [png_depth]
    cmp eax, 3
    je .pal
    cmp eax, 2
    je .rgb
    cmp eax, 4
    je .ga
    cmp eax, 6
    je .rgba

    cmp ecx, 16
    je .g16
    call png_sample
    mov edx, 0xFF000000
    cmp dword [png_haskey], 0
    je .g1
    cmp eax, [png_keyr]
    jne .g1
    xor edx, edx
.g1:
    cmp ecx, 8
    je .g8
    cmp ecx, 4
    je .g4
    cmp ecx, 2
    je .g2
    imul eax, eax, 255
    jmp .g8
.g4:
    imul eax, eax, 17
    jmp .g8
.g2:
    imul eax, eax, 85
.g8:
    imul eax, eax, 0x010101
    or eax, edx
    jmp .put
.g16:
    movzx eax, word [esi + ebx * 2]
    xchg al, ah
    mov edx, 0xFF000000
    cmp dword [png_haskey], 0
    je .g161
    cmp eax, [png_keyr]
    jne .g161
    xor edx, edx
.g161:
    shr eax, 8
    jmp .g8
.pal:
    call png_sample
    mov eax, [png_pal + eax * 4]
    jmp .put
.rgb:
    cmp ecx, 16
    je .rgb16
    lea eax, [ebx + ebx * 2]
    movzx ecx, byte [esi + eax]
    movzx edx, byte [esi + eax + 1]
    movzx eax, byte [esi + eax + 2]
    jmp .rgbk
.rgb16:
    lea eax, [ebx + ebx * 2]
    movzx ecx, word [esi + eax * 2]
    xchg cl, ch
    movzx edx, word [esi + eax * 2 + 2]
    xchg dl, dh
    movzx eax, word [esi + eax * 2 + 4]
    xchg al, ah
.rgbk:
    push ebx
    mov ebx, 0xFF000000
    cmp dword [png_haskey], 0
    je .rk
    cmp ecx, [png_keyr]
    jne .rk
    cmp edx, [png_keyg]
    jne .rk
    cmp eax, [png_keyb]
    jne .rk
    xor ebx, ebx
.rk:
    cmp dword [png_depth], 16
    jne .r8
    shr ecx, 8
    shr edx, 8
    shr eax, 8
.r8:
    shl ecx, 16
    shl edx, 8
    or eax, ecx
    or eax, edx
    or eax, ebx
    pop ebx
    jmp .put
.ga:
    cmp ecx, 16
    je .ga16
    movzx eax, byte [esi + ebx * 2]
    movzx edx, byte [esi + ebx * 2 + 1]
    jmp .gak
.ga16:
    movzx eax, byte [esi + ebx * 4]
    movzx edx, byte [esi + ebx * 4 + 2]
.gak:
    imul eax, eax, 0x010101
    shl edx, 24
    or eax, edx
    jmp .put
.rgba:
    cmp ecx, 16
    je .rgba16
    mov eax, [esi + ebx * 4]
    bswap eax
    ror eax, 8
    jmp .put
.rgba16:
    movzx eax, byte [esi + ebx * 8 + 6]
    shl eax, 8
    mov al, [esi + ebx * 8]
    shl eax, 8
    mov al, [esi + ebx * 8 + 2]
    shl eax, 8
    mov al, [esi + ebx * 8 + 4]
.put:
    call png_blend
    mov [edi], eax
    add edi, ebp
    inc ebx
    cmp ebx, [png_pw]
    jb .px
    pop ebp
    pop esi
    pop ebx
    ret

png_sample:
    cmp ecx, 8
    jne .bits
    movzx eax, byte [esi + ebx]
    ret
.bits:
    push ecx
    push edx
    mov eax, ebx
    imul eax, ecx
    mov edx, eax
    shr edx, 3
    movzx edx, byte [esi + edx]
    and eax, 7
    add eax, ecx
    neg eax
    add eax, 8
    xchg eax, ecx
    shr edx, cl
    mov ecx, eax
    mov eax, 1
    shl eax, cl
    dec eax
    and eax, edx
    pop edx
    pop ecx
    ret

png_blend:
    cmp eax, 0xFF000000
    jae .opaque
    cmp eax, 0x01000000
    jb .bg
    push ebx
    push ecx
    push edx
    push esi
    mov esi, eax
    shr esi, 24
    mov ebx, eax
    xor eax, eax
    mov ecx, 16
.ch:
    mov edx, ebx
    shr edx, cl
    and edx, 255
    imul edx, esi
    push edx
    mov edx, [png_bg]
    shr edx, cl
    and edx, 255
    push eax
    mov eax, 255
    sub eax, esi
    imul edx, eax
    pop eax
    add edx, [esp]
    add esp, 4
    add edx, 128
    push eax
    mov eax, edx
    shr eax, 8
    add edx, eax
    pop eax
    shr edx, 8
    shl edx, cl
    or eax, edx
    sub ecx, 8
    jns .ch
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret
.opaque:
    and eax, 0xFFFFFF
    ret
.bg:
    mov eax, [png_bg]
    ret
