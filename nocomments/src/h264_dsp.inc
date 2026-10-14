section .bss
alignb 16
h264_e          resb 16
h264_mct1       resb 16 * 16
h264_mct2       resb 16 * 16
h264_mcti       resd 21 * 16
alignb 4
h264_dbk_bsh    resb 16
h264_dbk_bsv    resb 16
alignb 4
h264_dbk_a      resd 1
h264_dbk_b      resd 1
h264_dbk_tc     resd 1
h264_dbk_mb     resd 1
h264_dbk_mo     resd 1
h264_dbk_x      resd 1
h264_dbk_y      resd 1
h264_dbk_p      resd 1
h264_dbk_pmo    resd 1

section .text

h264_pred4x4:
    push ebx
    push esi
    push ebp
    mov ebp, edx
    cmp eax, 2
    ja .table
    je .dc
    test eax, eax
    jnz .hor
    mov esi, edi
    sub esi, ebp
    mov eax, [esi]
    mov [edi], eax
    mov [edi + ebp], eax
    lea esi, [edi + ebp * 2]
    mov [esi], eax
    mov [esi + ebp], eax
    jmp .out
.hor:
    mov esi, edi
    mov ebx, 4
.h: movzx eax, byte [esi - 1]
    imul eax, 0x01010101
    mov [esi], eax
    add esi, ebp
    dec ebx
    jnz .h
    jmp .out
.dc:
    xor eax, eax
    xor ebx, ebx
    test ecx, 2
    jz .dc1
    mov esi, edi
    sub esi, ebp
    movzx edx, byte [esi]
    add eax, edx
    movzx edx, byte [esi + 1]
    add eax, edx
    movzx edx, byte [esi + 2]
    add eax, edx
    movzx edx, byte [esi + 3]
    add eax, edx
    inc ebx
.dc1:
    test ecx, 1
    jz .dc2
    mov esi, edi
    movzx edx, byte [esi - 1]
    add eax, edx
    add esi, ebp
    movzx edx, byte [esi - 1]
    add eax, edx
    add esi, ebp
    movzx edx, byte [esi - 1]
    add eax, edx
    add esi, ebp
    movzx edx, byte [esi - 1]
    add eax, edx
    inc ebx
.dc2:
    test ebx, ebx
    jz .dc128
    cmp ebx, 2
    je .dc8
    add eax, 2
    shr eax, 2
    jmp .dcf
.dc8:
    add eax, 4
    shr eax, 3
    jmp .dcf
.dc128:
    mov eax, 128
.dcf:
    imul eax, 0x01010101
    mov [edi], eax
    mov [edi + ebp], eax
    lea esi, [edi + ebp * 2]
    mov [esi], eax
    mov [esi + ebp], eax
    jmp .out
.table:

    push eax
    mov esi, edi
    lea edx, [ebp * 2 + ebp]
    mov al, [esi + edx - 1]
    mov [h264_e], al
    mov [h264_e + 1], al
    mov al, [esi + ebp * 2 - 1]
    mov [h264_e + 2], al
    mov al, [esi + ebp - 1]
    mov [h264_e + 3], al
    mov al, [esi - 1]
    mov [h264_e + 4], al
    sub esi, ebp
    mov al, [esi - 1]
    mov [h264_e + 5], al
    mov eax, [esi]
    mov [h264_e + 6], eax
    test ecx, 4
    jz .notr
    mov eax, [esi + 4]
    jmp .tr
.notr:
    shr eax, 24
    imul eax, 0x01010101
.tr:
    mov [h264_e + 10], eax
    shr eax, 24
    mov [h264_e + 14], al
    pop eax
    sub eax, 3
    shl eax, 4
    lea esi, [h264_i4tab + eax]
    xor ebx, ebx
.px:
    movzx eax, byte [esi + ebx]
    mov ecx, eax
    and ecx, 15
    shr eax, 4
    movzx edx, byte [h264_e + ecx]
    test eax, eax
    jz .put
    cmp eax, 1
    jne .op2
    movzx eax, byte [h264_e + ecx + 1]
    lea edx, [edx + eax + 1]
    shr edx, 1
    jmp .put
.op2:
    movzx eax, byte [h264_e + ecx - 1]
    lea edx, [eax + edx * 2 + 2]
    movzx eax, byte [h264_e + ecx + 1]
    add edx, eax
    shr edx, 2
.put:
    mov eax, ebx
    shr eax, 2
    imul eax, ebp
    mov ecx, ebx
    and ecx, 3
    add eax, ecx
    mov [edi + eax], dl
    inc ebx
    cmp ebx, 16
    jb .px
.out:
    pop ebp
    pop esi
    pop ebx
    ret

h264_pred16x16:
    push ebx
    push esi
    push ebp
    mov ebp, edx
    cmp eax, 1
    jb .ver
    je .hor
    cmp eax, 2
    je .dc
    jmp .plane
.ver:
    mov esi, edi
    sub esi, ebp
    mov ebx, 16
.v: mov eax, [esi]
    mov [edi], eax
    mov eax, [esi + 4]
    mov [edi + 4], eax
    mov eax, [esi + 8]
    mov [edi + 8], eax
    mov eax, [esi + 12]
    mov [edi + 12], eax
    add edi, ebp
    dec ebx
    jnz .v
    jmp .out
.hor:
    mov ebx, 16
.h: movzx eax, byte [edi - 1]
    imul eax, 0x01010101
    mov [edi], eax
    mov [edi + 4], eax
    mov [edi + 8], eax
    mov [edi + 12], eax
    add edi, ebp
    dec ebx
    jnz .h
    jmp .out
.dc:
    xor eax, eax
    xor ebx, ebx
    test ecx, 2
    jz .d1
    mov esi, edi
    sub esi, ebp
    push ecx
    xor ecx, ecx
.dt:
    movzx edx, byte [esi + ecx]
    add eax, edx
    inc ecx
    cmp ecx, 16
    jb .dt
    pop ecx
    inc ebx
.d1:
    test ecx, 1
    jz .d2
    mov esi, edi
    push ecx
    mov ecx, 16
.dl:
    movzx edx, byte [esi - 1]
    add eax, edx
    add esi, ebp
    dec ecx
    jnz .dl
    pop ecx
    inc ebx
.d2:
    test ebx, ebx
    jz .d128
    cmp ebx, 2
    je .d32
    add eax, 8
    shr eax, 4
    jmp .df
.d32:
    add eax, 16
    shr eax, 5
    jmp .df
.d128:
    mov eax, 128
.df:
    imul eax, 0x01010101
    mov ebx, 16
.dw:
    mov [edi], eax
    mov [edi + 4], eax
    mov [edi + 8], eax
    mov [edi + 12], eax
    add edi, ebp
    dec ebx
    jnz .dw
    jmp .out
.plane:

    mov esi, edi
    sub esi, ebp
    xor ebx, ebx
    xor ecx, ecx
.ph:
    movzx eax, byte [esi + ecx + 8]
    mov edx, 6
    sub edx, ecx
    movzx edx, byte [esi + edx]
    sub eax, edx
    lea edx, [ecx + 1]
    imul eax, edx
    add ebx, eax
    inc ecx
    cmp ecx, 8
    jb .ph
    push ebx

    xor ebx, ebx
    xor ecx, ecx
.pv:
    lea eax, [ecx + 8]
    imul eax, ebp
    movzx eax, byte [edi + eax - 1]
    mov edx, 6
    sub edx, ecx
    imul edx, ebp
    movzx edx, byte [edi + edx - 1]
    sub eax, edx
    lea edx, [ecx + 1]
    imul eax, edx
    add ebx, eax
    inc ecx
    cmp ecx, 8
    jb .pv

    lea ebx, [ebx * 4 + ebx + 32]
    sar ebx, 6
    pop eax
    lea eax, [eax * 4 + eax + 32]
    sar eax, 6
    mov [h264_tmpi + 100], eax
    mov [h264_tmpi + 104], ebx
    lea eax, [ebp * 8]
    lea eax, [eax * 2]
    sub eax, ebp
    movzx eax, byte [edi + eax - 1]
    movzx edx, byte [esi + 15]
    add eax, edx
    shl eax, 4

    add eax, 16
    mov edx, [h264_tmpi + 100]
    imul edx, 7
    sub eax, edx
    mov edx, [h264_tmpi + 104]
    imul edx, 7
    sub eax, edx
    mov ebx, 16
.prow:
    push eax
    xor ecx, ecx
.pcol:
    mov edx, eax
    sar edx, 5
    call h264_clip1
    mov [edi + ecx], dl
    add eax, [h264_tmpi + 100]
    inc ecx
    cmp ecx, 16
    jb .pcol
    pop eax
    add eax, [h264_tmpi + 104]
    add edi, ebp
    dec ebx
    jnz .prow
.out:
    pop ebp
    pop esi
    pop ebx
    ret

h264_clip1:
    test edx, ~255
    jz .r
    test edx, edx
    js .z
    mov edx, 255
    ret
.z: xor edx, edx
.r: ret

h264_predchroma:
    push ebx
    push esi
    push ebp
    mov ebp, edx
    cmp eax, 1
    jb .dc
    je .hor
    cmp eax, 2
    je .ver
    jmp .plane
.ver:
    mov esi, edi
    sub esi, ebp
    mov eax, [esi]
    mov edx, [esi + 4]
    mov ebx, 8
.v: mov [edi], eax
    mov [edi + 4], edx
    add edi, ebp
    dec ebx
    jnz .v
    jmp .out
.hor:
    mov ebx, 8
.h: movzx eax, byte [edi - 1]
    imul eax, 0x01010101
    mov [edi], eax
    mov [edi + 4], eax
    add edi, ebp
    dec ebx
    jnz .h
    jmp .out
.dc:

    mov esi, edi
    sub esi, ebp
    xor ebx, ebx
.ts:
    movzx eax, byte [esi + ebx * 4]
    movzx edx, byte [esi + ebx * 4 + 1]
    add eax, edx
    movzx edx, byte [esi + ebx * 4 + 2]
    add eax, edx
    movzx edx, byte [esi + ebx * 4 + 3]
    add eax, edx
    mov [h264_tmpi + ebx * 4], eax
    inc ebx
    cmp ebx, 2
    jb .ts
    mov esi, edi
    xor ebx, ebx
.ls:
    xor eax, eax
    push ecx
    mov ecx, 4
.ls1:
    movzx edx, byte [esi - 1]
    add eax, edx
    add esi, ebp
    dec ecx
    jnz .ls1
    pop ecx
    mov [h264_tmpi + 8 + ebx * 4], eax
    inc ebx
    cmp ebx, 2
    jb .ls

    xor ebx, ebx
.blk:
    mov eax, ebx
    and eax, 1
    mov esi, [h264_tmpi + eax * 4]
    mov edx, ebx
    shr edx, 1
    mov edx, [h264_tmpi + 8 + edx * 4]
    cmp ebx, 1
    je .topfirst
    cmp ebx, 2
    je .leftfirst
    test ecx, 2
    jz .leftfirst
    test ecx, 1
    jz .usetop
    lea eax, [esi + edx + 4]
    shr eax, 3
    jmp .fill
.topfirst:
    test ecx, 2
    jnz .usetop
    test ecx, 1
    jnz .useleft
    jmp .use128
.leftfirst:
    test ecx, 1
    jnz .useleft
    test ecx, 2
    jnz .usetop
.use128:
    mov eax, 128
    jmp .fill
.useleft:
    lea eax, [edx + 2]
    shr eax, 2
    jmp .fill
.usetop:
    lea eax, [esi + 2]
    shr eax, 2
.fill:
    imul eax, 0x01010101
    mov edx, ebx
    and edx, 1
    shl edx, 2
    mov esi, ebx
    shr esi, 1
    shl esi, 2
    imul esi, ebp
    add esi, edx
    add esi, edi
    mov [esi], eax
    mov [esi + ebp], eax
    lea esi, [esi + ebp * 2]
    mov [esi], eax
    mov [esi + ebp], eax
    inc ebx
    cmp ebx, 4
    jb .blk
    jmp .out
.plane:
    mov esi, edi
    sub esi, ebp
    xor ebx, ebx
    xor ecx, ecx
.ph:
    movzx eax, byte [esi + ecx + 4]
    mov edx, 2
    sub edx, ecx
    movzx edx, byte [esi + edx]
    sub eax, edx
    lea edx, [ecx + 1]
    imul eax, edx
    add ebx, eax
    inc ecx
    cmp ecx, 4
    jb .ph
    push ebx
    xor ebx, ebx
    xor ecx, ecx
.pv:
    lea eax, [ecx + 4]
    imul eax, ebp
    movzx eax, byte [edi + eax - 1]
    mov edx, 2
    sub edx, ecx
    imul edx, ebp
    movzx edx, byte [edi + edx - 1]
    sub eax, edx
    lea edx, [ecx + 1]
    imul eax, edx
    add ebx, eax
    inc ecx
    cmp ecx, 4
    jb .pv
    imul ebx, 34
    add ebx, 32
    sar ebx, 6
    pop eax
    imul eax, 34
    add eax, 32
    sar eax, 6
    mov [h264_tmpi + 100], eax
    mov [h264_tmpi + 104], ebx
    lea eax, [ebp * 8]
    sub eax, ebp
    movzx eax, byte [edi + eax - 1]
    movzx edx, byte [esi + 7]
    add eax, edx
    shl eax, 4
    add eax, 16
    mov edx, [h264_tmpi + 100]
    imul edx, 3
    sub eax, edx
    mov edx, [h264_tmpi + 104]
    imul edx, 3
    sub eax, edx
    mov ebx, 8
.prow:
    push eax
    xor ecx, ecx
.pcol:
    mov edx, eax
    sar edx, 5
    call h264_clip1
    mov [edi + ecx], dl
    add eax, [h264_tmpi + 100]
    inc ecx
    cmp ecx, 8
    jb .pcol
    pop eax
    add eax, [h264_tmpi + 104]
    add edi, ebp
    dec ebx
    jnz .prow
.out:
    pop ebp
    pop esi
    pop ebx
    ret

%macro H264_TR4W 0
    punpcklwd xmm0, xmm1
    punpcklwd xmm2, xmm3
    movdqa xmm1, xmm0
    punpckldq xmm0, xmm2
    punpckhdq xmm1, xmm2
    movdqa xmm2, xmm1
    movhlps xmm3, xmm1
    movhlps xmm1, xmm0
%endmacro

%macro H264_IDCT4 0
    movdqa xmm4, xmm0
    paddw xmm0, xmm2
    psubw xmm4, xmm2
    movdqa xmm5, xmm1
    psraw xmm5, 1
    psubw xmm5, xmm3
    psraw xmm3, 1
    paddw xmm3, xmm1
    movdqa xmm1, xmm4
    paddw xmm1, xmm5
    psubw xmm4, xmm5
    movdqa xmm2, xmm4
    movdqa xmm5, xmm0
    paddw xmm0, xmm3
    psubw xmm5, xmm3
    movdqa xmm3, xmm5
%endmacro

h264_idct_add:
    movq xmm0, [esi]
    movq xmm1, [esi + 8]
    movq xmm2, [esi + 16]
    movq xmm3, [esi + 24]
    pxor xmm7, xmm7
    movdqu [esi], xmm7
    movdqu [esi + 16], xmm7
    H264_TR4W
    H264_IDCT4
    H264_TR4W
    H264_IDCT4
    mov eax, 0x00200020
    movd xmm6, eax
    pshufd xmm6, xmm6, 0
    punpcklqdq xmm0, xmm1
    punpcklqdq xmm2, xmm3
    paddw xmm0, xmm6
    paddw xmm2, xmm6
    psraw xmm0, 6
    psraw xmm2, 6
    lea ecx, [edx * 3]
    movd xmm4, [edi]
    movd xmm5, [edi + edx]
    punpckldq xmm4, xmm5
    punpcklbw xmm4, xmm7
    paddw xmm0, xmm4
    movd xmm4, [edi + edx * 2]
    movd xmm5, [edi + ecx]
    punpckldq xmm4, xmm5
    punpcklbw xmm4, xmm7
    paddw xmm2, xmm4
    packuswb xmm0, xmm2
    movd [edi], xmm0
    psrldq xmm0, 4
    movd [edi + edx], xmm0
    psrldq xmm0, 4
    movd [edi + edx * 2], xmm0
    psrldq xmm0, 4
    movd [edi + ecx], xmm0
    ret

h264_idct_dc_add:
    movsx eax, word [esi]
    mov word [esi], 0
    add eax, 32
    sar eax, 6
    movd xmm0, eax
    pshuflw xmm0, xmm0, 0
    punpcklqdq xmm0, xmm0
    pxor xmm7, xmm7
    lea ecx, [edx * 3]
    movd xmm4, [edi]
    movd xmm5, [edi + edx]
    punpckldq xmm4, xmm5
    punpcklbw xmm4, xmm7
    paddw xmm4, xmm0
    movd xmm5, [edi + edx * 2]
    movd xmm6, [edi + ecx]
    punpckldq xmm5, xmm6
    punpcklbw xmm5, xmm7
    paddw xmm5, xmm0
    packuswb xmm4, xmm5
    movd [edi], xmm4
    psrldq xmm4, 4
    movd [edi + edx], xmm4
    psrldq xmm4, 4
    movd [edi + edx * 2], xmm4
    psrldq xmm4, 4
    movd [edi + ecx], xmm4
    ret

h264_idct_any:
    movdqu xmm0, [esi]
    movdqu xmm1, [esi + 16]
    xor eax, eax
    pinsrw xmm0, eax, 0
    por xmm0, xmm1
    pxor xmm7, xmm7
    pcmpeqb xmm0, xmm7
    pmovmskb eax, xmm0
    cmp eax, 0xFFFF
    jne h264_idct_add
    jmp h264_idct_dc_add

h264_mc_luma:
    push ebx
    push esi
    push edi
    push ebp
    mov ebp, [h264_ystride]
    mov eax, [h264_mc_x]
    mov ebx, eax
    and ebx, 3
    sar eax, 2
    mov ecx, [h264_cplanew]
    add ecx, H264_PADY - 3
    sub ecx, [h264_mc_w]
    cmp eax, ecx
    jle .x1
    mov eax, ecx
.x1:
    cmp eax, 2 - H264_PADY
    jge .x2
    mov eax, 2 - H264_PADY
.x2:
    add esi, eax
    mov eax, [h264_mc_y]
    mov edx, eax
    and edx, 3
    sar eax, 2
    mov ecx, [h264_cplaneh]
    add ecx, H264_PADY - 3
    sub ecx, [h264_mc_h]
    cmp eax, ecx
    jle .y1
    mov eax, ecx
.y1:
    cmp eax, 2 - H264_PADY
    jge .y2
    mov eax, 2 - H264_PADY
.y2:
    imul eax, ebp
    add esi, eax
    lea eax, [edx * 4 + ebx]
    movzx ecx, byte [h264_mc_case + eax * 2]
    movzx edx, byte [h264_mc_case + eax * 2 + 1]
    test edx, edx
    jnz .two

    mov ebx, [h264_mc_ds]
    call h264_mc_plane
    jmp .out
.two:
    push edx
    push edi
    mov edi, h264_mct1
    mov ebx, 16
    call h264_mc_plane
    pop edi
    pop ecx
    push edi
    mov edi, h264_mct2
    mov ebx, 16
    call h264_mc_plane
    pop edi

    mov esi, h264_mct1
    mov edx, [h264_mc_h]
.ar:
    xor ecx, ecx
.ac:
    movzx eax, byte [esi + ecx]
    movzx ebx, byte [esi + ecx + h264_mct2 - h264_mct1]
    lea eax, [eax + ebx + 1]
    shr eax, 1
    mov [edi + ecx], al
    inc ecx
    cmp ecx, [h264_mc_w]
    jb .ac
    add esi, 16
    add edi, [h264_mc_ds]
    dec edx
    jnz .ar
.out:
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

section .data

h264_mc_case    db 0x10, 0,    0x10, 0x20, 0x20, 0,    0x11, 0x20
                db 0x10, 0x30, 0x20, 0x30, 0x20, 0x40, 0x20, 0x31
                db 0x30, 0,    0x30, 0x40, 0x40, 0,    0x40, 0x31
                db 0x12, 0x30, 0x30, 0x22, 0x40, 0x22, 0x31, 0x22
section .text

h264_mc_plane:
    push esi
    push edi
    mov eax, ecx
    and eax, 15
    jz .o
    cmp eax, 1
    jne .o2
    inc esi
    jmp .o
.o2:
    add esi, ebp
.o: shr ecx, 4
    cmp ecx, 2
    jb .g
    je .b
    cmp ecx, 3
    je .h
    jmp .j
.g: mov edx, [h264_mc_h]
.gr:
    xor ecx, ecx
.gc:
    mov al, [esi + ecx]
    mov [edi + ecx], al
    inc ecx
    cmp ecx, [h264_mc_w]
    jb .gc
    add esi, ebp
    add edi, ebx
    dec edx
    jnz .gr
    jmp .out
.b: mov edx, [h264_mc_h]
.br:
    xor ecx, ecx
.bc:
    lea eax, [esi + ecx]
    push edx
    mov edx, 1
    call h264_tap6
    add eax, 16
    sar eax, 5
    mov edx, eax
    call h264_clip1
    mov [edi + ecx], dl
    pop edx
    inc ecx
    cmp ecx, [h264_mc_w]
    jb .bc
    add esi, ebp
    add edi, ebx
    dec edx
    jnz .br
    jmp .out
.h: mov edx, [h264_mc_h]
.hr:
    xor ecx, ecx
.hc:
    lea eax, [esi + ecx]
    push edx
    mov edx, ebp
    call h264_tap6
    add eax, 16
    sar eax, 5
    mov edx, eax
    call h264_clip1
    mov [edi + ecx], dl
    pop edx
    inc ecx
    cmp ecx, [h264_mc_w]
    jb .hc
    add esi, ebp
    add edi, ebx
    dec edx
    jnz .hr
    jmp .out
.j:

    push edi
    mov edi, h264_mcti
    sub esi, ebp
    sub esi, ebp
    mov edx, [h264_mc_h]
    add edx, 5
.jr:
    xor ecx, ecx
.jc:
    lea eax, [esi + ecx]
    push edx
    mov edx, 1
    call h264_tap6
    pop edx
    mov [edi + ecx * 4], eax
    inc ecx
    cmp ecx, [h264_mc_w]
    jb .jc
    add esi, ebp
    add edi, 16 * 4
    dec edx
    jnz .jr
    pop edi
    mov esi, h264_mcti
    mov edx, [h264_mc_h]
.jr2:
    xor ecx, ecx
.jc2:
    push edx
    mov eax, [esi + ecx * 4]
    add eax, [esi + ecx * 4 + 5 * 64]
    mov edx, [esi + ecx * 4 + 64]
    add edx, [esi + ecx * 4 + 4 * 64]
    imul edx, -5
    add eax, edx
    mov edx, [esi + ecx * 4 + 2 * 64]
    add edx, [esi + ecx * 4 + 3 * 64]
    imul edx, 20
    add eax, edx
    add eax, 512
    sar eax, 10
    mov edx, eax
    call h264_clip1
    mov [edi + ecx], dl
    pop edx
    inc ecx
    cmp ecx, [h264_mc_w]
    jb .jc2
    add esi, 64
    add edi, ebx
    dec edx
    jnz .jr2
.out:
    pop edi
    pop esi
    ret

h264_tap6:
    push ebx
    push esi
    mov esi, eax
    sub esi, edx
    sub esi, edx
    movzx eax, byte [esi]
    add esi, edx
    movzx ebx, byte [esi]
    imul ebx, -5
    add eax, ebx
    add esi, edx
    movzx ebx, byte [esi]
    add esi, edx
    push ecx
    movzx ecx, byte [esi]
    add ebx, ecx
    imul ebx, 20
    add eax, ebx
    add esi, edx
    movzx ebx, byte [esi]
    imul ebx, -5
    add eax, ebx
    add esi, edx
    movzx ebx, byte [esi]
    add eax, ebx
    pop ecx
    pop esi
    pop ebx
    ret

h264_mc_chroma:
    push ebx
    push esi
    push edi
    push ebp
    mov ebp, [h264_cstride]
    mov eax, [h264_mc_x]
    mov ebx, eax
    and ebx, 7
    sar eax, 3
    mov ecx, [h264_cplanew]
    shr ecx, 1
    add ecx, H264_PADC - 1
    sub ecx, [h264_mc_w]
    cmp eax, ecx
    jle .x1
    mov eax, ecx
.x1:
    cmp eax, -H264_PADC
    jge .x2
    mov eax, -H264_PADC
.x2:
    add esi, eax
    mov eax, [h264_mc_y]
    mov edx, eax
    and edx, 7
    sar eax, 3
    mov ecx, [h264_cplaneh]
    shr ecx, 1
    add ecx, H264_PADC - 1
    sub ecx, [h264_mc_h]
    cmp eax, ecx
    jle .y1
    mov eax, ecx
.y1:
    cmp eax, -H264_PADC
    jge .y2
    mov eax, -H264_PADC
.y2:
    imul eax, ebp
    add esi, eax

    mov eax, 8
    sub eax, ebx
    mov ecx, 8
    sub ecx, edx
    push eax
    imul eax, ecx
    mov [h264_tmpi], eax
    mov eax, ebx
    imul eax, ecx
    mov [h264_tmpi + 4], eax
    pop eax
    imul eax, edx
    mov [h264_tmpi + 8], eax
    imul ebx, edx
    mov [h264_tmpi + 12], ebx
    mov edx, [h264_mc_h]
.r: xor ecx, ecx
.c: push edx
    movzx eax, byte [esi + ecx]
    imul eax, [h264_tmpi]
    movzx edx, byte [esi + ecx + 1]
    imul edx, [h264_tmpi + 4]
    add eax, edx
    lea ebx, [esi + ebp]
    movzx edx, byte [ebx + ecx]
    imul edx, [h264_tmpi + 8]
    add eax, edx
    movzx edx, byte [ebx + ecx + 1]
    imul edx, [h264_tmpi + 12]
    add eax, edx
    add eax, 32
    shr eax, 6
    mov [edi + ecx], al
    pop edx
    inc ecx
    cmp ecx, [h264_mc_w]
    jb .c
    add esi, ebp
    add edi, [h264_mc_dsc]
    dec edx
    jnz .r
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

h264_deblock_pic:
    push ebx
    push esi
    push edi
    push ebp
    xor eax, eax
    mov [h264_dbk_x], eax
    mov [h264_dbk_y], eax
    mov esi, [h264_mbi]
    mov ebx, [h264_cur]
    SLOTP ebx
    mov edi, [ebx + SL_MOT]
.mb:
    mov [h264_dbk_mb], esi
    mov [h264_dbk_mo], edi
    cmp byte [esi + MI_DBIDC], 1
    je .next
    mov eax, [esi + MI_SLICE]
    cmp eax, [h264_pic_slice0]
    jb .next
    call h264_deblock_mb
.next:
    mov esi, [h264_dbk_mb]
    mov edi, [h264_dbk_mo]
    add esi, MI_SZ
    add edi, MO_SZ
    mov eax, [h264_dbk_x]
    inc eax
    cmp eax, [h264_mbw]
    jb .x
    xor eax, eax
    inc dword [h264_dbk_y]
.x: mov [h264_dbk_x], eax
    mov eax, [h264_dbk_y]
    cmp eax, [h264_mbh]
    jb .mb
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret

h264_deblock_mb:
    push ebp

    mov esi, [h264_dbk_mb]
    mov edi, [h264_dbk_mo]

    xor eax, eax
    mov [h264_dbk_bsh], eax
    mov [h264_dbk_bsv], eax
    cmp dword [h264_dbk_x], 0
    je .noleft
    lea eax, [esi - MI_SZ]
    lea edx, [edi - MO_SZ]
    call .edge_ok
    jz .noleft
    mov [h264_dbk_p], eax
    mov [h264_dbk_pmo], edx
    xor ebx, ebx
.l: lea eax, [ebx * 4 + 3]
    lea ecx, [ebx * 4]
    mov edx, 4
    call h264_bs
    mov [h264_dbk_bsh + ebx], al
    inc ebx
    cmp ebx, 4
    jb .l
.noleft:

    mov eax, esi
    mov edx, edi
    mov [h264_dbk_p], eax
    mov [h264_dbk_pmo], edx
    mov ebp, 1
.ie:
    xor ebx, ebx
.ie2:
    lea ecx, [ebx * 4 + ebp]
    lea eax, [ecx - 1]
    mov edx, 3
    call h264_bs
    mov [h264_dbk_bsh + ebp * 4 + ebx], al
    inc ebx
    cmp ebx, 4
    jb .ie2
    inc ebp
    cmp ebp, 4
    jb .ie

    cmp dword [h264_dbk_y], 0
    je .notop
    mov eax, [h264_mbw]
    shl eax, MI_SHIFT
    neg eax
    add eax, esi
    mov edx, [h264_mbw]
    imul edx, MO_SZ
    neg edx
    add edx, edi
    call .edge_ok
    jz .notop
    mov [h264_dbk_p], eax
    mov [h264_dbk_pmo], edx
    xor ebx, ebx
.t: lea eax, [ebx + 12]
    mov ecx, ebx
    mov edx, 4
    call h264_bs
    mov [h264_dbk_bsv + ebx], al
    inc ebx
    cmp ebx, 4
    jb .t
.notop:
    mov [h264_dbk_p], esi
    mov [h264_dbk_pmo], edi
    mov ebp, 1
.he:
    xor ebx, ebx
.he2:
    lea ecx, [ebp * 4 + ebx]
    lea eax, [ecx - 4]
    mov edx, 3
    call h264_bs
    mov [h264_dbk_bsv + ebp * 4 + ebx], al
    inc ebx
    cmp ebx, 4
    jb .he2
    inc ebp
    cmp ebp, 4
    jb .he

    mov ebx, [h264_cur]
    SLOTP ebx
    mov eax, [h264_dbk_y]
    shl eax, 4
    imul eax, [h264_ystride]
    mov edx, [h264_dbk_x]
    shl edx, 4
    add eax, edx
    add eax, [ebx + SL_Y]
    mov [h264_dbk_lp], eax
    xor ebp, ebp
.lv:
    mov eax, [h264_dbk_bsh + ebp * 4]
    test eax, eax
    jz .lvn
    mov esi, [h264_dbk_mb]
    movzx edx, byte [esi + MI_QP]
    mov ecx, edx
    test ebp, ebp
    jnz .lv1
    movzx ecx, byte [esi - MI_SZ + MI_QP]
.lv1:
    call h264_lf_lparams
    jz .lvn
    push eax
    mov esi, [h264_dbk_lp]
    lea esi, [esi + ebp * 4 - 4]
    mov eax, [h264_ystride]
    mov edi, h264_lfv
    mov edx, 16
    call h264_tr8x8
    mov edi, h264_lfv + 8
    call h264_tr8x8
    pop eax
    mov ebx, h264_lfv
    mov ecx, 16
    call h264_lf_luma
    mov esi, h264_lfv
    mov eax, 16
    mov edi, [h264_dbk_lp]
    lea edi, [edi + ebp * 4 - 4]
    mov edx, [h264_ystride]
    call h264_tr8x8
    mov esi, h264_lfv + 8
    call h264_tr8x8
.lvn:
    inc ebp
    cmp ebp, 4
    jb .lv
    xor ebp, ebp
.lh:
    mov eax, [h264_dbk_bsv + ebp * 4]
    test eax, eax
    jz .lhn
    mov esi, [h264_dbk_mb]
    movzx edx, byte [esi + MI_QP]
    mov ecx, edx
    test ebp, ebp
    jnz .lh2
    mov ecx, [h264_mbw]
    shl ecx, MI_SHIFT
    neg ecx
    movzx ecx, byte [esi + ecx + MI_QP]
.lh2:
    call h264_lf_lparams
    jz .lhn
    mov ecx, [h264_ystride]
    lea ebx, [ebp * 4 - 4]
    imul ebx, ecx
    add ebx, [h264_dbk_lp]
    call h264_lf_luma
.lhn:
    inc ebp
    cmp ebp, 4
    jb .lh

    mov ebx, [h264_cur]
    SLOTP ebx
    mov eax, [h264_dbk_y]
    shl eax, 3
    imul eax, [h264_cstride]
    mov edx, [h264_dbk_x]
    shl edx, 3
    add eax, edx
    mov edx, eax
    add eax, [ebx + SL_U]
    mov [h264_dbk_cbp], eax
    add edx, [ebx + SL_V]
    mov [h264_dbk_crp], edx
    xor ebp, ebp
.cv:
    mov eax, [h264_dbk_bsh + ebp * 4]
    test eax, eax
    jz .cvn
    mov edi, [h264_dbk_mb]
    mov esi, edi
    test ebp, ebp
    jnz .cv2
    sub esi, MI_SZ
.cv2:
    call h264_lf_cparams
    push eax
    mov eax, [h264_cstride]
    mov edx, 16
    mov esi, [h264_dbk_cbp]
    lea esi, [esi + ebp * 2 - 4]
    mov edi, h264_lfv
    call h264_tr8x8
    mov esi, [h264_dbk_crp]
    lea esi, [esi + ebp * 2 - 4]
    mov edi, h264_lfv + 8
    call h264_tr8x8
    pop eax
    mov ebx, h264_lfv + 2 * 16
    mov ecx, 16
    call h264_lf_chroma
    mov eax, 16
    mov edx, [h264_cstride]
    mov esi, h264_lfv
    mov edi, [h264_dbk_cbp]
    lea edi, [edi + ebp * 2 - 4]
    call h264_tr8x8
    mov esi, h264_lfv + 8
    mov edi, [h264_dbk_crp]
    lea edi, [edi + ebp * 2 - 4]
    call h264_tr8x8
.cvn:
    add ebp, 2
    cmp ebp, 4
    jb .cv
    xor ebp, ebp
.ch:
    mov eax, [h264_dbk_bsv + ebp * 4]
    test eax, eax
    jz .chn
    mov edi, [h264_dbk_mb]
    mov esi, edi
    test ebp, ebp
    jnz .ch2
    mov ecx, [h264_mbw]
    shl ecx, MI_SHIFT
    sub esi, ecx
.ch2:
    call h264_lf_cparams

    mov ecx, [h264_cstride]
    lea edx, [ebp * 2 - 2]
    imul edx, ecx
    mov esi, [h264_dbk_cbp]
    add esi, edx
    mov edi, [h264_dbk_crp]
    add edi, edx
    xor edx, edx
.chl:
    movq xmm0, [esi]
    movhps xmm0, [edi]
    movdqu [h264_lfv + 2 * 16 + edx], xmm0
    add esi, ecx
    add edi, ecx
    add edx, 16
    cmp edx, 4 * 16
    jb .chl
    mov ebx, h264_lfv + 2 * 16
    mov ecx, 16
    call h264_lf_chroma
    mov ecx, [h264_cstride]
    lea edx, [ebp * 2 - 1]
    imul edx, ecx
    mov esi, [h264_dbk_cbp]
    add esi, edx
    mov edi, [h264_dbk_crp]
    add edi, edx
    movdqu xmm0, [h264_lfv + 3 * 16]
    movq [esi], xmm0
    movhps [edi], xmm0
    movdqu xmm0, [h264_lfv + 4 * 16]
    movq [esi + ecx], xmm0
    movhps [edi + ecx], xmm0
.chn:
    add ebp, 2
    cmp ebp, 4
    jb .ch
    pop ebp
    ret

.edge_ok:
    cmp byte [esi + MI_DBIDC], 2
    jne .eo_filter
    push ecx
    mov ecx, [eax + MI_SLICE]
    cmp ecx, [esi + MI_SLICE]
    pop ecx
    jne .eo_skip
.eo_filter:
    test esp, esp
    ret
.eo_skip:
    cmp eax, eax
    ret

h264_bs:
    push esi
    push edi
    mov esi, [h264_dbk_p]
    mov edi, [h264_dbk_mb]
    test byte [esi + MI_TYPE], MT_INTRA
    jnz .intra
    test byte [edi + MI_TYPE], MT_INTRA
    jnz .intra
    cmp byte [esi + MI_NNZ + eax], 0
    jne .two
    cmp byte [edi + MI_NNZ + ecx], 0
    jne .two

    push ebx
    push ebp
    mov esi, [h264_dbk_pmo]
    mov edi, [h264_dbk_mo]
    mov edx, eax
    shr edx, 3
    shl edx, 1
    mov ebx, eax
    and ebx, 3
    shr ebx, 1
    add edx, ebx
    mov ebx, ecx
    shr ebx, 3
    shl ebx, 1
    mov ebp, ecx
    and ebp, 3
    shr ebp, 1
    add ebx, ebp
    push eax
    push ecx
    movzx ecx, byte [esi + MO_RS0 + edx]
    movzx ebp, byte [esi + MO_RS1 + edx]
    movzx edx, byte [edi + MO_RS0 + ebx]
    movzx ebx, byte [edi + MO_RS1 + ebx]
    pop eax
    lea edi, [edi + eax * 4]
    pop eax
    lea esi, [esi + eax * 4]
    cmp ecx, 255
    je .pone
    cmp ebp, 255
    je .pone

    cmp edx, 255
    je .diff
    cmp ebx, 255
    je .diff
    cmp ecx, ebp
    je .same
    cmp ecx, edx
    jne .cross
    cmp ebp, ebx
    jne .diff
    call .d00
    jnz .diff
    call .d11
    jmp .res
.cross:
    cmp ecx, ebx
    jne .diff
    cmp ebp, edx
    jne .diff
    call .d01
    jnz .diff
    call .d10
    jmp .res
.same:

    cmp edx, ecx
    jne .diff
    cmp ebx, ecx
    jne .diff
    call .d00
    jnz .s2
    call .d11
    jz .res
.s2:
    call .d01
    jnz .diff
    call .d10
    jmp .res
.pone:

    xor eax, eax
    cmp ecx, 255
    jne .px
    mov ecx, ebp
    inc al
.px:
    cmp edx, 255
    je .qy1
    cmp ebx, 255
    jne .diff
    jmp .qy
.qy1:
    mov edx, ebx
    inc ah
.qy:
    cmp ecx, edx
    jne .diff
    cmp ecx, 255
    je .res0
    shl al, 1
    or al, ah
    movzx eax, al
    jmp [h264_bs_dxy + eax * 4]
.d00r:
    call .d00
    jmp .res
.d01r:
    call .d01
    jmp .res
.d10r:
    call .d10
    jmp .res
.d11r:
    call .d11
.res:
    jnz .diff
.res0:
    pop ebp
    pop ebx
    xor eax, eax
    jmp .out
.diff:
    pop ebp
    pop ebx
    jmp .one

.d00:
    mov eax, [esi + MO_MV0]
    mov ecx, [edi + MO_MV0]
    jmp .dmv
.d11:
    mov eax, [esi + MO_MV1]
    mov ecx, [edi + MO_MV1]
    jmp .dmv
.d01:
    mov eax, [esi + MO_MV0]
    mov ecx, [edi + MO_MV1]
    jmp .dmv
.d10:
    mov eax, [esi + MO_MV1]
    mov ecx, [edi + MO_MV0]
.dmv:
    push ebx
    movsx edx, ax
    movsx ebx, cx
    sub edx, ebx
    jns .dx
    neg edx
.dx:
    cmp edx, 4
    jge .dne
    sar eax, 16
    sar ecx, 16
    sub eax, ecx
    jns .dy
    neg eax
.dy:
    cmp eax, 4
    jge .dne
    pop ebx
    cmp eax, eax
    ret
.dne:
    pop ebx
    or eax, 1
    ret
.one:
    mov eax, 1
    jmp .out
.two:
    mov eax, 2
    jmp .out
.intra:
    mov eax, edx
.out:
    pop edi
    pop esi
    ret

section .data
h264_bs_dxy     dd h264_bs.d00r, h264_bs.d01r, h264_bs.d10r, h264_bs.d11r
section .text

h264_dbk_params:
    lea eax, [eax + ecx + 1]
    shr eax, 1
    mov edx, [h264_dbk_mb]
    movsx ecx, byte [edx + MI_DBA]
    add ecx, eax
    jns .a1
    xor ecx, ecx
.a1:
    cmp ecx, 51
    jbe .a2
    mov ecx, 51
.a2:
    movsx edx, byte [edx + MI_DBB]
    add eax, edx
    jns .b1
    xor eax, eax
.b1:
    cmp eax, 51
    jbe .b2
    mov eax, 51
.b2:
    movzx eax, byte [h264_beta + eax]
    mov [h264_dbk_b], eax
    lea edx, [h264_tc0 + ecx * 4]
    mov [h264_dbk_tc], edx
    movzx ecx, byte [h264_alpha + ecx]
    mov [h264_dbk_a], ecx
    test ecx, ecx
    jz .r
    test eax, eax
.r: ret

LFW_HALF        equ 384

%macro H264_ABSD 4
    movdqa %1, %2
    psubusb %1, %3
    movdqa %4, %3
    psubusb %4, %2
    por %1, %4
%endmacro

%macro H264_GE 3
    psubusb %1, %2
    pxor %3, %3
    pcmpeqb %1, %3
%endmacro

%macro H264_STRONG_SIDE 10
    movdqu xmm0, [esi + %3]
    movdqu xmm1, [esi + %4]
    movdqu xmm2, [esi + %5]
    movdqu xmm5, [esi + %6]
    movdqa xmm7, xmm0
    paddw xmm7, xmm7
    paddw xmm7, xmm1
    paddw xmm7, xmm5
    paddw xmm7, xmm6
    psrlw xmm7, 2
    movdqu xmm4, [esi + 128]
    pand xmm7, xmm4
    pandn xmm4, xmm1
    por xmm7, xmm4
    movdqa xmm3, xmm0
    paddw xmm3, xmm1
    paddw xmm3, xmm2
    movdqu xmm4, [esi + %2]
    movdqa xmm1, xmm3
    paddw xmm1, xmm1
    paddw xmm1, xmm4
    paddw xmm1, xmm5
    paddw xmm1, xmm6
    paddw xmm1, xmm6
    psrlw xmm1, 3
    movdqu xmm2, [esi + %7]
    pand xmm1, xmm2
    pandn xmm2, xmm7
    por xmm1, xmm2
    movdqu [esi + %10], xmm1
    movdqa xmm1, xmm4
    paddw xmm1, xmm3
    paddw xmm1, xmm6
    psrlw xmm1, 2
    movdqu xmm2, [esi + %7]
    pand xmm1, xmm2
    pandn xmm2, xmm0
    por xmm1, xmm2
    movdqu [esi + %9], xmm1
    movdqu xmm1, [esi + %1]
    paddw xmm1, xmm1
    paddw xmm1, xmm4
    paddw xmm1, xmm4
    paddw xmm1, xmm4
    paddw xmm1, xmm3
    paddw xmm1, xmm6
    paddw xmm1, xmm6
    psrlw xmm1, 3
    movdqu xmm2, [esi + %7]
    pand xmm1, xmm2
    pandn xmm2, xmm4
    por xmm1, xmm2
    movdqu [esi + %8], xmm1
%endmacro

%macro H264_WEAK_SIDE 4
    movdqu xmm4, [esi + %1]
    paddw xmm4, xmm0
    psubw xmm4, %2
    psubw xmm4, %2
    psraw xmm4, 1
    pminsw xmm4, xmm1
    pmaxsw xmm4, xmm7
    movdqu xmm5, [esi + %3]
    pand xmm4, xmm5
    paddw xmm4, %2
    movdqu [esi + %4], xmm4
%endmacro

h264_tr8x8:
    lea ecx, [eax * 3]
    movq xmm0, [esi]
    movq xmm1, [esi + eax]
    movq xmm2, [esi + eax * 2]
    movq xmm3, [esi + ecx]
    lea esi, [esi + eax * 4]
    movq xmm4, [esi]
    movq xmm5, [esi + eax]
    movq xmm6, [esi + eax * 2]
    movq xmm7, [esi + ecx]
    lea esi, [esi + eax * 4]
    punpcklbw xmm0, xmm1
    punpcklbw xmm2, xmm3
    punpcklbw xmm4, xmm5
    punpcklbw xmm6, xmm7
    movdqa xmm1, xmm0
    punpcklwd xmm0, xmm2
    punpckhwd xmm1, xmm2
    movdqa xmm5, xmm4
    punpcklwd xmm4, xmm6
    punpckhwd xmm5, xmm6
    movdqa xmm2, xmm0
    punpckldq xmm0, xmm4
    punpckhdq xmm2, xmm4
    movdqa xmm3, xmm1
    punpckldq xmm1, xmm5
    punpckhdq xmm3, xmm5
    lea ecx, [edx * 3]
    movq [edi], xmm0
    movhps [edi + edx], xmm0
    movq [edi + edx * 2], xmm2
    movhps [edi + ecx], xmm2
    lea edi, [edi + edx * 4]
    movq [edi], xmm1
    movhps [edi + edx], xmm1
    movq [edi + edx * 2], xmm3
    movhps [edi + ecx], xmm3
    lea edi, [edi + edx * 4]
    ret

h264_lf_bcast:
    movd xmm0, eax
    punpcklbw xmm0, xmm0
    pshuflw xmm0, xmm0, 0
    punpcklqdq xmm0, xmm0
    ret

h264_lf_lparams:
    push ebx
    push esi
    mov ebx, eax
    mov eax, edx
    call h264_dbk_params
    jz .out
    mov eax, [h264_dbk_a]
    call h264_lf_bcast
    movdqu [h264_lf_a], xmm0
    mov eax, [h264_dbk_b]
    call h264_lf_bcast
    movdqu [h264_lf_b], xmm0
    movd xmm0, ebx
    punpcklbw xmm0, xmm0
    punpcklwd xmm0, xmm0
    pxor xmm1, xmm1
    pcmpeqb xmm0, xmm1
    pcmpeqb xmm1, xmm1
    pxor xmm0, xmm1
    movdqu [h264_lf_e], xmm0
    mov eax, 1
    cmp bl, 4
    je .nz
    mov esi, [h264_dbk_tc]
    mov eax, ebx
    shr eax, 24
    movzx edx, byte [esi + eax]
    shl edx, 8
    mov eax, ebx
    shr eax, 16
    and eax, 255
    mov dl, [esi + eax]
    shl edx, 8
    movzx eax, bh
    mov dl, [esi + eax]
    shl edx, 8
    movzx eax, bl
    mov dl, [esi + eax]
    movd xmm0, edx
    punpcklbw xmm0, xmm0
    punpcklwd xmm0, xmm0
    movdqu [h264_lf_t], xmm0
    xor eax, eax
.nz:
    test esp, esp
.out:
    pop esi
    pop ebx
    ret

h264_lf_cparams:
    push ebx
    push ebp
    mov ebx, eax
    movd xmm0, ebx
    punpcklbw xmm0, xmm0
    punpcklqdq xmm0, xmm0
    pxor xmm1, xmm1
    pcmpeqb xmm0, xmm1
    pcmpeqb xmm1, xmm1
    pxor xmm0, xmm1
    movdqu [h264_lf_e], xmm0
    xor ebp, ebp
.pl:
    movzx eax, byte [edi + MI_QPC + ebp]
    movzx ecx, byte [esi + MI_QPC + ebp]
    call h264_dbk_params
    mov ecx, ebp
    shl ecx, 3
    mov eax, [h264_dbk_a]
    imul eax, 0x01010101
    mov [h264_lf_a + ecx], eax
    mov [h264_lf_a + ecx + 4], eax
    mov eax, [h264_dbk_b]
    imul eax, 0x01010101
    mov [h264_lf_b + ecx], eax
    mov [h264_lf_b + ecx + 4], eax
    cmp bl, 4
    je .nexp
    push esi
    mov esi, [h264_dbk_tc]
    xor edx, edx
.seg:
    mov eax, ebx
    push ecx
    lea ecx, [edx * 8]
    shr eax, cl
    pop ecx
    movzx eax, al
    mov al, [esi + eax]
    mov ah, al
    mov [h264_lf_t + ecx + edx * 2], ax
    inc edx
    cmp edx, 4
    jb .seg
    pop esi
.nexp:
    inc ebp
    cmp ebp, 2
    jb .pl
    xor eax, eax
    cmp bl, 4
    sete al
    pop ebp
    pop ebx
    ret

h264_lf_masks:
    H264_ABSD xmm4, xmm0, xmm1, xmm5
    movdqu [h264_lf_d], xmm4
    movdqu xmm6, [h264_lf_a]
    H264_GE xmm6, xmm4, xmm5
    H264_ABSD xmm4, xmm2, xmm0, xmm5
    movdqu xmm7, [h264_lf_b]
    H264_GE xmm7, xmm4, xmm5
    por xmm6, xmm7
    H264_ABSD xmm4, xmm3, xmm1, xmm5
    movdqu xmm7, [h264_lf_b]
    H264_GE xmm7, xmm4, xmm5
    por xmm6, xmm7
    movdqu xmm7, [h264_lf_e]
    pandn xmm6, xmm7
    movdqu [h264_lf_m], xmm6
    pmovmskb eax, xmm6
    ret

h264_lf_unpack:
    movdqa xmm1, xmm0
    punpcklbw xmm0, xmm7
    punpckhbw xmm1, xmm7
    movdqu [h264_lfw + edx], xmm0
    movdqu [h264_lfw + edx + LFW_HALF], xmm1
    ret

h264_lf_unpackm:
    movdqa xmm1, xmm0
    punpcklbw xmm0, xmm0
    punpckhbw xmm1, xmm1
    movdqu [h264_lfw + edx], xmm0
    movdqu [h264_lfw + edx + LFW_HALF], xmm1
    ret

h264_lf_luma:
    push ebp
    mov ebp, eax
    lea edx, [ecx * 3]
    lea edi, [ebx + ecx * 4]
    movdqu xmm0, [ebx + edx]
    movdqu xmm1, [edi]
    movdqu xmm2, [ebx + ecx * 2]
    movdqu xmm3, [edi + ecx]
    call h264_lf_masks
    test eax, eax
    jz .out
    movdqu xmm2, [ebx + ecx]
    H264_ABSD xmm4, xmm2, xmm0, xmm5
    movdqu xmm5, [h264_lf_b]
    H264_GE xmm5, xmm4, xmm7
    pandn xmm5, xmm6
    movdqu xmm3, [edi + ecx * 2]
    H264_ABSD xmm4, xmm3, xmm1, xmm7
    movdqu xmm7, [h264_lf_b]
    H264_GE xmm7, xmm4, xmm0
    pandn xmm7, xmm6
    test ebp, ebp
    jz .masks
    mov eax, [h264_lf_a]
    shr eax, 2
    and eax, 63
    add eax, 2
    call h264_lf_bcast
    movdqu xmm1, [h264_lf_d]
    H264_GE xmm0, xmm1, xmm4
    movdqa xmm1, xmm0
    pandn xmm0, xmm5
    pandn xmm1, xmm7
    movdqa xmm5, xmm0
    movdqa xmm7, xmm1
.masks:
    movdqa xmm0, xmm5
    mov edx, 144
    call h264_lf_unpackm
    movdqa xmm0, xmm7
    mov edx, 160
    call h264_lf_unpackm
    movdqu xmm0, [h264_lf_m]
    mov edx, 128
    call h264_lf_unpackm
    pxor xmm7, xmm7
    movdqu xmm0, [h264_lf_t]
    mov edx, 176
    call h264_lf_unpack
    mov eax, ebx
    xor edx, edx
.u: movdqu xmm0, [eax]
    call h264_lf_unpack
    add eax, ecx
    add edx, 16
    cmp edx, 128
    jb .u
    push ecx
    mov esi, h264_lfw
    test ebp, ebp
    jnz .strong
    call .weak_half
    add esi, LFW_HALF
    call .weak_half
    jmp .store
.strong:
    mov eax, 0x00020002
    movd xmm6, eax
    pshufd xmm6, xmm6, 0
    H264_STRONG_SIDE 0, 16, 32, 48, 64, 80, 144, 192, 208, 224
    H264_STRONG_SIDE 112, 96, 80, 64, 48, 32, 160, 272, 256, 240
    add esi, LFW_HALF
    H264_STRONG_SIDE 0, 16, 32, 48, 64, 80, 144, 192, 208, 224
    H264_STRONG_SIDE 112, 96, 80, 64, 48, 32, 160, 272, 256, 240
.store:
    pop ecx
    lea eax, [ebx + ecx]
    xor edx, edx
.s: movdqu xmm0, [h264_lfw + edx + 192]
    movdqu xmm1, [h264_lfw + edx + 192 + LFW_HALF]
    packuswb xmm0, xmm1
    movdqu [eax], xmm0
    add eax, ecx
    add edx, 16
    cmp edx, 96
    jb .s
.out:
    pop ebp
    ret

.weak_half:
    mov eax, 0x00040004
    movd xmm6, eax
    pshufd xmm6, xmm6, 0
    movdqu xmm0, [esi + 48]
    movdqu xmm1, [esi + 64]
    movdqu xmm2, [esi + 32]
    movdqu xmm3, [esi + 80]
    movdqa xmm4, xmm1
    psubw xmm4, xmm0
    psllw xmm4, 2
    paddw xmm4, xmm2
    psubw xmm4, xmm3
    paddw xmm4, xmm6
    psraw xmm4, 3
    movdqu xmm5, [esi + 176]
    movdqu xmm6, [esi + 144]
    psubw xmm5, xmm6
    movdqu xmm6, [esi + 160]
    psubw xmm5, xmm6
    pminsw xmm4, xmm5
    pxor xmm6, xmm6
    psubw xmm6, xmm5
    pmaxsw xmm4, xmm6
    movdqu xmm6, [esi + 128]
    pand xmm4, xmm6
    movdqa xmm5, xmm0
    paddw xmm5, xmm4
    movdqu [esi + 224], xmm5
    movdqa xmm5, xmm1
    psubw xmm5, xmm4
    movdqu [esi + 240], xmm5
    pavgw xmm0, xmm1
    movdqu xmm1, [esi + 176]
    pxor xmm7, xmm7
    psubw xmm7, xmm1
    H264_WEAK_SIDE 16, xmm2, 144, 208
    H264_WEAK_SIDE 96, xmm3, 160, 256
    movdqu xmm4, [esi + 16]
    movdqu [esi + 192], xmm4
    movdqu xmm4, [esi + 96]
    movdqu [esi + 272], xmm4
    ret

h264_lf_chroma:
    push ebp
    mov ebp, eax
    movdqu xmm0, [ebx + ecx]
    movdqu xmm1, [ebx + ecx * 2]
    movdqu xmm2, [ebx]
    lea edx, [ecx * 3]
    movdqu xmm3, [ebx + edx]
    call h264_lf_masks
    test eax, eax
    jz .out
    pxor xmm7, xmm7
    movdqu xmm0, [ebx]
    mov edx, 32
    call h264_lf_unpack
    movdqu xmm0, [ebx + ecx]
    mov edx, 48
    call h264_lf_unpack
    movdqu xmm0, [ebx + ecx * 2]
    mov edx, 64
    call h264_lf_unpack
    lea eax, [ecx * 3]
    movdqu xmm0, [ebx + eax]
    mov edx, 80
    call h264_lf_unpack
    movdqu xmm0, [h264_lf_t]
    mov edx, 176
    call h264_lf_unpack
    movdqu xmm0, [h264_lf_m]
    mov edx, 128
    call h264_lf_unpackm
    mov esi, h264_lfw
    call .half
    add esi, LFW_HALF
    call .half
    movdqu xmm0, [h264_lfw + 224]
    movdqu xmm1, [h264_lfw + 224 + LFW_HALF]
    packuswb xmm0, xmm1
    movdqu [ebx + ecx], xmm0
    movdqu xmm0, [h264_lfw + 240]
    movdqu xmm1, [h264_lfw + 240 + LFW_HALF]
    packuswb xmm0, xmm1
    movdqu [ebx + ecx * 2], xmm0
.out:
    pop ebp
    ret
.half:
    movdqu xmm0, [esi + 48]
    movdqu xmm1, [esi + 64]
    movdqu xmm2, [esi + 32]
    movdqu xmm3, [esi + 80]
    movdqu xmm6, [esi + 128]
    test ebp, ebp
    jnz .strong
    mov eax, 0x00040004
    movd xmm5, eax
    pshufd xmm5, xmm5, 0
    movdqa xmm4, xmm1
    psubw xmm4, xmm0
    psllw xmm4, 2
    paddw xmm4, xmm2
    psubw xmm4, xmm3
    paddw xmm4, xmm5
    psraw xmm4, 3
    movdqu xmm5, [esi + 176]
    mov eax, 0x00010001
    movd xmm7, eax
    pshufd xmm7, xmm7, 0
    paddw xmm5, xmm7
    pminsw xmm4, xmm5
    pxor xmm7, xmm7
    psubw xmm7, xmm5
    pmaxsw xmm4, xmm7
    pand xmm4, xmm6
    paddw xmm0, xmm4
    psubw xmm1, xmm4
    movdqu [esi + 224], xmm0
    movdqu [esi + 240], xmm1
    ret
.strong:
    mov eax, 0x00020002
    movd xmm7, eax
    pshufd xmm7, xmm7, 0
    movdqa xmm4, xmm2
    paddw xmm4, xmm4
    paddw xmm4, xmm0
    paddw xmm4, xmm3
    paddw xmm4, xmm7
    psrlw xmm4, 2
    movdqa xmm5, xmm3
    paddw xmm5, xmm5
    paddw xmm5, xmm1
    paddw xmm5, xmm2
    paddw xmm5, xmm7
    psrlw xmm5, 2
    pand xmm4, xmm6
    pand xmm5, xmm6
    pandn xmm6, xmm0
    por xmm4, xmm6
    movdqu xmm6, [esi + 128]
    pandn xmm6, xmm1
    por xmm5, xmm6
    movdqu [esi + 224], xmm4
    movdqu [esi + 240], xmm5
    ret

section .bss
alignb 16
h264_lfv        resb 8 * 16
h264_lf_a       resb 16
h264_lf_b       resb 16
h264_lf_t       resb 16
h264_lf_e       resb 16
h264_lf_m       resb 16
h264_lf_d       resb 16
h264_lfw        resb 2 * LFW_HALF
alignb 4
h264_dbk_lp     resd 1
h264_dbk_cbp    resd 1
h264_dbk_crp    resd 1
section .text
