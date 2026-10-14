; =============================================================================
;  h264_dsp.inc - pixel processing of the H.264 decoder (part of h264.asm)
;
;  Intra prediction (8.3), the inverse 4x4 transform (8.5.12), motion
;  compensated prediction with the 6-tap luma and bilinear chroma filters
;  (8.4.2.2) and the deblocking filter (8.7).
;  All work in place on 8-bit planes; "stride" is bytes per row.
; =============================================================================

section .bss
alignb 16
h264_e          resb 16             ; Intra_4x4 edge samples (see the table)
h264_mct1       resb 16 * 16        ; motion compensation: two predictions
h264_mct2       resb 16 * 16
h264_mcti       resd 21 * 16        ; 6-tap intermediates (j)
alignb 4
h264_dbk_bsh    resb 16             ; bS of all edges (4 x 4), vertical
h264_dbk_bsv    resb 16             ;   and horizontal
alignb 4
h264_dbk_a      resd 1              ; alpha, beta, tC0 row of the edge
h264_dbk_b      resd 1
h264_dbk_tc     resd 1
h264_dbk_mb     resd 1              ; deblocking: MI_ of the macroblock
h264_dbk_mo     resd 1              ;   its motion data
h264_dbk_x      resd 1
h264_dbk_y      resd 1
h264_dbk_p      resd 1              ;   the other macroblock of an edge
h264_dbk_pmo    resd 1

section .text

; =============================================================================
;  Intra prediction
; =============================================================================

; h264_pred4x4: Intra_4x4 prediction (8.3.1.2) of the block at EDI.
; EDX = stride, EAX = mode 0..8, ECX = available neighbours: bit 0 left,
; 1 top, 2 top-right, 3 top-left. Unavailable samples are read anyway (the
; frame border makes that safe); only DC and the top-right substitution
; depend on the bits, as the standard says.
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
    mov esi, edi                    ; vertical
    sub esi, ebp
    mov eax, [esi]
    mov [edi], eax
    mov [edi + ebp], eax
    lea esi, [edi + ebp * 2]
    mov [esi], eax
    mov [esi + ebp], eax
    jmp .out
.hor:
    mov esi, edi                    ; horizontal
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
    xor ebx, ebx                    ; EBX = number of sides
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
    ; the edge array: L3 L3 L2 L1 L0 Q T0..T7 T7
    push eax
    mov esi, edi
    lea edx, [ebp * 2 + ebp]
    mov al, [esi + edx - 1]         ; L3
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
    shr eax, 24                     ; T4..T7 = T3
    imul eax, 0x01010101
.tr:
    mov [h264_e + 10], eax
    shr eax, 24
    mov [h264_e + 14], al
    pop eax
    sub eax, 3
    shl eax, 4
    lea esi, [h264_i4tab + eax]     ; ESI = the mode's operations
    xor ebx, ebx
.px:
    movzx eax, byte [esi + ebx]
    mov ecx, eax
    and ecx, 15                     ; index
    shr eax, 4                      ; op
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
    mov eax, ebx                    ; destination: y * stride + x
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

; h264_pred16x16: Intra_16x16 prediction (8.3.3) of the macroblock at EDI.
; EDX = stride, EAX = mode 0..3, ECX = h264_iav (bit 0 left, 1 top, 3
; top-left).
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
    xor eax, eax                    ; EAX = sum, EBX = sides
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
    ; H = sum (x' + 1) * (p[8 + x', -1] - p[6 - x', -1]), x' = 0..7
    mov esi, edi
    sub esi, ebp                    ; ESI = row above
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
    push ebx                        ; H
    ; V = sum (y' + 1) * (p[-1, 8 + y'] - p[-1, 6 - y'])
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
    ; b = (5 H + 32) >> 6, c = (5 V + 32) >> 6, a = 16 (p[-1,15] + p[15,-1])
    lea ebx, [ebx * 4 + ebx + 32]
    sar ebx, 6                      ; c
    pop eax
    lea eax, [eax * 4 + eax + 32]
    sar eax, 6                      ; b
    mov [h264_tmpi + 100], eax
    mov [h264_tmpi + 104], ebx
    lea eax, [ebp * 8]              ; p[-1, 15]
    lea eax, [eax * 2]
    sub eax, ebp
    movzx eax, byte [edi + eax - 1]
    movzx edx, byte [esi + 15]
    add eax, edx
    shl eax, 4
    ; value at (x, y) = (a + b (x - 7) + c (y - 7) + 16) >> 5
    add eax, 16
    mov edx, [h264_tmpi + 100]
    imul edx, 7
    sub eax, edx
    mov edx, [h264_tmpi + 104]
    imul edx, 7
    sub eax, edx                    ; EAX = value at (0, 0) << 5, rounded
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

; h264_clip1: EDX -> EDX clipped to 0..255
h264_clip1:
    test edx, ~255
    jz .r
    test edx, edx
    js .z
    mov edx, 255
    ret
.z: xor edx, edx
.r: ret

; h264_predchroma: chroma intra prediction (8.3.4, 4:2:0) of the 8x8 block
; at EDI. EDX = stride, EAX = intra_chroma_pred_mode (0 DC, 1 horizontal,
; 2 vertical, 3 plane), ECX = h264_iav.
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
    ; sums of the four top and four left groups: h264_tmpi[0..1] top
    ; (x 0..3, 4..7), [2..3] left (y 0..3, 4..7)
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
    ; each 4x4 block: (0,0) and (1,1) use both sides, (1,0) prefers the
    ; top, (0,1) prefers the left (8.3.4.1-3)
    xor ebx, ebx                    ; block: bit 0 x, bit 1 y
.blk:
    mov eax, ebx
    and eax, 1                      ; x
    mov esi, [h264_tmpi + eax * 4]  ; ESI = top sum of this column
    mov edx, ebx
    shr edx, 1                      ; y
    mov edx, [h264_tmpi + 8 + edx * 4]  ; EDX = left sum of this row
    cmp ebx, 1
    je .topfirst
    cmp ebx, 2
    je .leftfirst
    test ecx, 2                     ; (0,0), (1,1): both if available
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
    mov edx, ebx                    ; block position
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
    sub esi, ebp                    ; row above
    xor ebx, ebx                    ; H = sum (x'+1)(p[4+x',-1] - p[2-x',-1])
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
    imul ebx, 34                    ; c = (34 V + 32) >> 6
    add ebx, 32
    sar ebx, 6
    pop eax
    imul eax, 34                    ; b = (34 H + 32) >> 6
    add eax, 32
    sar eax, 6
    mov [h264_tmpi + 100], eax
    mov [h264_tmpi + 104], ebx
    lea eax, [ebp * 8]
    sub eax, ebp
    movzx eax, byte [edi + eax - 1] ; p[-1, 7]
    movzx edx, byte [esi + 7]       ; p[7, -1]
    add eax, edx
    shl eax, 4                      ; a
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

; =============================================================================
;  Inverse transform
; =============================================================================

; H264_TR4W: transpose the 4x4 words in the low halves of XMM0..XMM3
; (the high halves become junk). XMM4 not used.
%macro H264_TR4W 0
    punpcklwd xmm0, xmm1            ; a0 b0 a1 b1 a2 b2 a3 b3
    punpcklwd xmm2, xmm3            ; c0 d0 c1 d1 c2 d2 c3 d3
    movdqa xmm1, xmm0
    punpckldq xmm0, xmm2            ; a0 b0 c0 d0 | a1 b1 c1 d1
    punpckhdq xmm1, xmm2            ; a2 b2 c2 d2 | a3 b3 c3 d3
    movdqa xmm2, xmm1
    movhlps xmm3, xmm1              ; a3 b3 c3 d3
    movhlps xmm1, xmm0              ; a1 b1 c1 d1
%endmacro

; H264_IDCT4: the 4-point inverse transform across XMM0..XMM3 (d0..d3 ->
; f0..f3, word lanes): e0 = d0 + d2, e1 = d0 - d2, e2 = (d1 >> 1) - d3,
; e3 = d1 + (d3 >> 1); f0 = e0 + e3, f1 = e1 + e2, f2 = e1 - e2,
; f3 = e0 - e3. XMM4 XMM5 changed.
%macro H264_IDCT4 0
    movdqa xmm4, xmm0
    paddw xmm0, xmm2                ; e0
    psubw xmm4, xmm2                ; e1
    movdqa xmm5, xmm1
    psraw xmm5, 1
    psubw xmm5, xmm3                ; e2
    psraw xmm3, 1
    paddw xmm3, xmm1                ; e3
    movdqa xmm1, xmm4
    paddw xmm1, xmm5                ; f1
    psubw xmm4, xmm5
    movdqa xmm2, xmm4               ; f2
    movdqa xmm5, xmm0
    paddw xmm0, xmm3                ; f0
    psubw xmm5, xmm3
    movdqa xmm3, xmm5               ; f3
%endmacro

; h264_idct_add: ESI = 4x4 coefficients (int16, raster, already scaled;
; cleared afterwards), EDI = destination, EDX = stride: the inverse
; transform (8.5.12.2) added to the prediction with clipping. SSE2: the
; four rows sit in the low halves of XMM0..XMM3; a 1-D transform across
; the registers works on all four lines at once, so the block is transposed
; before each pass (rows first, then columns, as the standard orders them;
; the >> 1 roundings make the order matter). The values fit in 16 bits for
; any conforming stream (8.5.12.2), damaged ones just give wrong pixels.
; EAX ECX XMM0-XMM7 changed.
h264_idct_add:
    movq xmm0, [esi]
    movq xmm1, [esi + 8]
    movq xmm2, [esi + 16]
    movq xmm3, [esi + 24]
    pxor xmm7, xmm7
    movdqu [esi], xmm7
    movdqu [esi + 16], xmm7
    H264_TR4W                       ; registers = columns
    H264_IDCT4                      ; horizontal pass (each row)
    H264_TR4W                       ; registers = rows
    H264_IDCT4                      ; vertical pass
    mov eax, 0x00200020             ; (x + 32) >> 6
    movd xmm6, eax
    pshufd xmm6, xmm6, 0
    punpcklqdq xmm0, xmm1           ; rows 0 | 1
    punpcklqdq xmm2, xmm3           ; rows 2 | 3
    paddw xmm0, xmm6
    paddw xmm2, xmm6
    psraw xmm0, 6
    psraw xmm2, 6
    lea ecx, [edx * 3]
    movd xmm4, [edi]                ; the prediction, as words
    movd xmm5, [edi + edx]
    punpckldq xmm4, xmm5
    punpcklbw xmm4, xmm7
    paddw xmm0, xmm4
    movd xmm4, [edi + edx * 2]
    movd xmm5, [edi + ecx]
    punpckldq xmm4, xmm5
    punpcklbw xmm4, xmm7
    paddw xmm2, xmm4
    packuswb xmm0, xmm2             ; clipped to 0..255: the 4 rows
    movd [edi], xmm0
    psrldq xmm0, 4
    movd [edi + edx], xmm0
    psrldq xmm0, 4
    movd [edi + edx * 2], xmm0
    psrldq xmm0, 4
    movd [edi + ecx], xmm0
    ret

; h264_idct_dc_add: the same for a block whose only coefficient is the DC
; (ESI as above, the DC cleared): every residual is (DC + 32) >> 6.
; EAX ECX XMM0 XMM4-XMM7 changed.
h264_idct_dc_add:
    movsx eax, word [esi]
    mov word [esi], 0
    add eax, 32
    sar eax, 6
    movd xmm0, eax
    pshuflw xmm0, xmm0, 0
    punpcklqdq xmm0, xmm0           ; 8 words of the residual
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

; h264_idct_any: h264_idct_add, or h264_idct_dc_add when only the DC is
; there (arguments as h264_idct_add)
h264_idct_any:
    movdqu xmm0, [esi]
    movdqu xmm1, [esi + 16]
    xor eax, eax
    pinsrw xmm0, eax, 0             ; all but the DC
    por xmm0, xmm1
    pxor xmm7, xmm7
    pcmpeqb xmm0, xmm7
    pmovmskb eax, xmm0
    cmp eax, 0xFFFF
    jne h264_idct_add
    jmp h264_idct_dc_add
; =============================================================================
;  Motion compensation
; =============================================================================

; h264_mc_luma: luma prediction of a w x h block (8.4.2.2.1) from the
; reference plane ESI (its top-left pixel) into EDI (the current frame, or
; a prediction buffer). h264_mc_x / _y = position of the block in quarter
; samples (vector included), h264_mc_w / _h = size. The reference has
; stride h264_ystride, the destination h264_mc_ds.
; The integer position is clamped so that every tap stays inside the
; frame border; that gives the same samples as clamping each coordinate.
h264_mc_luma:
    push ebx
    push esi
    push edi
    push ebp
    mov ebp, [h264_ystride]
    mov eax, [h264_mc_x]
    mov ebx, eax
    and ebx, 3                      ; EBX = fx
    sar eax, 2
    mov ecx, [h264_cplanew]
    add ecx, H264_PADY - 3
    sub ecx, [h264_mc_w]            ; largest x: W + 29 - w
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
    and edx, 3                      ; EDX = fy
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
    add esi, eax                    ; ESI = integer sample position
    lea eax, [edx * 4 + ebx]        ; case = fy * 4 + fx
    movzx ecx, byte [h264_mc_case + eax * 2]
    movzx edx, byte [h264_mc_case + eax * 2 + 1]
    test edx, edx
    jnz .two
    ; one plane, straight into the destination
    mov ebx, [h264_mc_ds]           ; destination stride
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
    ; average
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
; per (fy * 4 + fx): the one or two sample planes that are averaged
; (8.4.2.2.1). Code: kind << 4 | offset, kind 1 = G (integer), 2 = b
; (horizontal half), 3 = h (vertical half), 4 = j (centre); offset 0 =
; here, 1 = one sample right, 2 = one row down. 0 = no second plane.
h264_mc_case    db 0x10, 0,    0x10, 0x20, 0x20, 0,    0x11, 0x20
                db 0x10, 0x30, 0x20, 0x30, 0x20, 0x40, 0x20, 0x31
                db 0x30, 0,    0x30, 0x40, 0x40, 0,    0x40, 0x31
                db 0x12, 0x30, 0x30, 0x22, 0x40, 0x22, 0x31, 0x22
section .text

; h264_mc_plane: ECX = plane code (see h264_mc_case), ESI = integer
; position in the reference, EBP = its stride, EDI = destination, EBX =
; destination stride; size h264_mc_w x h264_mc_h. ESI EDI EBP kept.
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
.g: mov edx, [h264_mc_h]            ; integer samples: copy
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
.b: mov edx, [h264_mc_h]            ; horizontal half samples
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
.h: mov edx, [h264_mc_h]            ; vertical half samples
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
.j: ; centre: horizontal intermediates b1 of rows -2 .. h+2, then the 6-tap
    ; down them: (j1 + 512) >> 10
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
    mov eax, [esi + ecx * 4]        ; rows -2 .. +3 of the column
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

; h264_tap6: EAX = sample address, EDX = step -> EAX = the 6-tap sum
; s[-2] - 5 s[-1] + 20 s[0] + 20 s[1] - 5 s[2] + s[3] (steps of EDX)
h264_tap6:
    push ebx
    push esi
    mov esi, eax
    sub esi, edx
    sub esi, edx
    movzx eax, byte [esi]           ; s[-2]
    add esi, edx
    movzx ebx, byte [esi]           ; s[-1]
    imul ebx, -5
    add eax, ebx
    add esi, edx
    movzx ebx, byte [esi]           ; s[0]
    add esi, edx
    push ecx
    movzx ecx, byte [esi]           ; s[1]
    add ebx, ecx
    imul ebx, 20
    add eax, ebx
    add esi, edx
    movzx ebx, byte [esi]           ; s[2]
    imul ebx, -5
    add eax, ebx
    add esi, edx
    movzx ebx, byte [esi]           ; s[3]
    add eax, ebx
    pop ecx
    pop esi
    pop ebx
    ret

; h264_mc_chroma: chroma prediction of a w x h block (8.4.2.2.2) from the
; reference plane ESI into EDI. h264_mc_x / _y = position in eighth
; samples, h264_mc_w / _h = size; stride h264_cstride (destination:
; h264_mc_dsc).
h264_mc_chroma:
    push ebx
    push esi
    push edi
    push ebp
    mov ebp, [h264_cstride]
    mov eax, [h264_mc_x]
    mov ebx, eax
    and ebx, 7                      ; EBX = xFrac
    sar eax, 3
    mov ecx, [h264_cplanew]
    shr ecx, 1
    add ecx, H264_PADC - 1
    sub ecx, [h264_mc_w]            ; largest x: Wc + 15 - w
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
    and edx, 7                      ; EDX = yFrac
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
    ; weights: A (8-x)(8-y), B x(8-y), C (8-x)y, D xy
    mov eax, 8
    sub eax, ebx
    mov ecx, 8
    sub ecx, edx
    push eax
    imul eax, ecx
    mov [h264_tmpi], eax            ; wA
    mov eax, ebx
    imul eax, ecx
    mov [h264_tmpi + 4], eax        ; wB
    pop eax
    imul eax, edx
    mov [h264_tmpi + 8], eax        ; wC
    imul ebx, edx
    mov [h264_tmpi + 12], ebx       ; wD
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

; =============================================================================
;  Deblocking filter (8.7)
; =============================================================================

; h264_deblock_pic: filter every decoded macroblock of the current picture,
; in macroblock order: luma vertical edges, luma horizontal edges, then
; the same for both chroma planes.
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

; h264_deblock_mb: the macroblock h264_dbk_mb / _mo at h264_dbk_x, _y.
; Any register may change except EBP.
h264_deblock_mb:
    push ebp
    ; boundary strengths: h264_dbk_bsh[edge * 4 + segment] for the vertical
    ; edges (x = 0, 4, 8, 12), h264_dbk_bsv for the horizontal ones
    mov esi, [h264_dbk_mb]
    mov edi, [h264_dbk_mo]
    ; left macroblock edge
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
    xor ebx, ebx                    ; segment (row of 4x4 blocks)
.l: lea eax, [ebx * 4 + 3]          ; p: block (3, k) of the left MB
    lea ecx, [ebx * 4]              ; q: block (0, k)
    mov edx, 4
    call h264_bs
    mov [h264_dbk_bsh + ebx], al
    inc ebx
    cmp ebx, 4
    jb .l
.noleft:
    ; internal vertical edges
    mov eax, esi
    mov edx, edi
    mov [h264_dbk_p], eax
    mov [h264_dbk_pmo], edx
    mov ebp, 1                      ; edge
.ie:
    xor ebx, ebx
.ie2:
    lea ecx, [ebx * 4 + ebp]        ; q block (e, k), p block (e - 1, k)
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
    ; top macroblock edge
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
    xor ebx, ebx                    ; column of 4x4 blocks
.t: lea eax, [ebx + 12]             ; p: block (k, 3) of the MB above
    mov ecx, ebx                    ; q: block (k, 0)
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
    lea ecx, [ebp * 4 + ebx]        ; q block (k, e), p block (k, e - 1)
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
    ; filter: luma. Vertical edges are transposed into h264_lfv (8 vectors
    ; p3 .. q3 of 16 lines) and back; horizontal edges are filtered in place
    mov ebx, [h264_cur]
    SLOTP ebx
    mov eax, [h264_dbk_y]
    shl eax, 4
    imul eax, [h264_ystride]
    mov edx, [h264_dbk_x]
    shl edx, 4
    add eax, edx
    add eax, [ebx + SL_Y]
    mov [h264_dbk_lp], eax          ; the macroblock's luma
    xor ebp, ebp                    ; vertical edges
.lv:
    mov eax, [h264_dbk_bsh + ebp * 4]
    test eax, eax
    jz .lvn
    mov esi, [h264_dbk_mb]          ; qP of the two macroblocks
    movzx edx, byte [esi + MI_QP]
    mov ecx, edx
    test ebp, ebp
    jnz .lv1
    movzx ecx, byte [esi - MI_SZ + MI_QP]
.lv1:
    call h264_lf_lparams
    jz .lvn
    push eax
    mov esi, [h264_dbk_lp]          ; 16 rows of 8 pixels around the edge
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
    mov esi, h264_lfv               ; and back
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
    xor ebp, ebp                    ; horizontal edges
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
    mov ecx, [h264_ystride]         ; p3 = 4 rows above the edge
    lea ebx, [ebp * 4 - 4]
    imul ebx, ecx
    add ebx, [h264_dbk_lp]
    call h264_lf_luma
.lhn:
    inc ebp
    cmp ebp, 4
    jb .lh
    ; chroma: edges 0 and 2 (in 4x4 luma block units); Cb in lanes 0-7 and
    ; Cr in lanes 8-15 of the vectors
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
    xor ebp, ebp                    ; vertical edges 0, 2
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
    mov eax, [h264_cstride]         ; 8 rows of each plane, x - 4 .. x + 3
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
    mov ebx, h264_lfv + 2 * 16      ; p1
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
    xor ebp, ebp                    ; horizontal edges 0, 2
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
    ; rows p1, p0, q0, q1 of both planes into the vectors
    mov ecx, [h264_cstride]
    lea edx, [ebp * 2 - 2]
    imul edx, ecx                   ; EDX = offset of row p1
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
    mov ecx, [h264_cstride]         ; p0 and q0 back
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
; EAX = MI_ of the neighbouring macroblock: ZF = 1 if the edge to it must
; not be filtered (disable_deblocking_filter_idc 2 and another slice)
.edge_ok:
    cmp byte [esi + MI_DBIDC], 2
    jne .eo_filter
    push ecx
    mov ecx, [eax + MI_SLICE]
    cmp ecx, [esi + MI_SLICE]
    pop ecx
    jne .eo_skip
.eo_filter:
    test esp, esp                   ; ZF = 0
    ret
.eo_skip:
    cmp eax, eax                    ; ZF = 1
    ret

; h264_bs: boundary strength (8.7.2.1) between block EAX (raster index in
; the macroblock h264_dbk_p) and block ECX (in h264_dbk_mb); EDX = 4 at a
; macroblock edge, 3 inside -> EAX = bS. EBX ESI EDI EBP kept.
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
    ; different reference pictures, a different number of motion vectors,
    ; or vectors of the same picture 4 quarter samples (or more) apart. The
    ; pictures count, not the lists they were reached through.
    push ebx
    push ebp
    mov esi, [h264_dbk_pmo]
    mov edi, [h264_dbk_mo]
    mov edx, eax                    ; 8x8 index = (y >> 1) * 2 + (x >> 1)
    shr edx, 3
    shl edx, 1
    mov ebx, eax
    and ebx, 3
    shr ebx, 1
    add edx, ebx                    ; EDX = 8x8 of p
    mov ebx, ecx
    shr ebx, 3
    shl ebx, 1
    mov ebp, ecx
    and ebp, 3
    shr ebp, 1
    add ebx, ebp                    ; EBX = 8x8 of q
    push eax
    push ecx
    movzx ecx, byte [esi + MO_RS0 + edx]   ; ECX = p0, EBP = p1, EDX = q0,
    movzx ebp, byte [esi + MO_RS1 + edx]   ;   EBX = q1: frame buffers
    movzx edx, byte [edi + MO_RS0 + ebx]   ;   (255 = list not used)
    movzx ebx, byte [edi + MO_RS1 + ebx]
    pop eax
    lea edi, [edi + eax * 4]        ; EDI: [edi + MO_MV0] = q's vectors
    pop eax
    lea esi, [esi + eax * 4]        ; ESI: p's
    cmp ecx, 255
    je .pone
    cmp ebp, 255
    je .pone
    ; p has two vectors: q must have two, of the same two pictures
    cmp edx, 255
    je .diff
    cmp ebx, 255
    je .diff
    cmp ecx, ebp
    je .same
    cmp ecx, edx                    ; p0 = q0 and p1 = q1
    jne .cross
    cmp ebp, ebx
    jne .diff
    call .d00
    jnz .diff
    call .d11
    jmp .res
.cross:
    cmp ecx, ebx                    ; p0 = q1 and p1 = q0
    jne .diff
    cmp ebp, edx
    jne .diff
    call .d01
    jnz .diff
    call .d10
    jmp .res
.same:
    ; both of p's vectors refer to one picture, so must both of q's: a
    ; filtered edge unless the vectors are close in one of the pairings
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
    ; p has one vector (list X): q must have one too (list Y), of the same
    ; picture
    xor eax, eax                    ; AL = X, AH = Y
    cmp ecx, 255
    jne .px
    mov ecx, ebp
    inc al
.px:
    cmp edx, 255
    je .qy1
    cmp ebx, 255
    jne .diff                       ; q has two
    jmp .qy
.qy1:
    mov edx, ebx
    inc ah
.qy:
    cmp ecx, edx
    jne .diff
    cmp ecx, 255                    ; (no vector on either side)
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
; vector comparisons: ZF = 0 (jnz) if the two differ by 4 or more in
; either component; .dXY = p's list X against q's list Y. EAX ECX EDX
; changed.
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
    cmp eax, eax                    ; ZF = 1: close
    ret
.dne:
    pop ebx
    or eax, 1                       ; ZF = 0
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

; h264_dbk_params: EAX = qP of macroblock q, ECX = of p -> alpha, beta and
; the tC0 row of the edge (offsets of macroblock h264_dbk_mb). ZF = 1 (jz
; taken) if alpha or beta is 0 (nothing to filter).
h264_dbk_params:
    lea eax, [eax + ecx + 1]
    shr eax, 1                      ; qPav
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

; ---- the filters themselves (SSE2) -------------------------------------------
; The samples of an edge are handled as vectors: one byte per line, p3 .. q3
; (p0 next to the edge on one side, q0 on the other). For a horizontal edge
; those are simply picture rows; a vertical edge is transposed into
; h264_lfv first (h264_tr8x8) and back afterwards. The decisions (8.7.2.2)
; are made on bytes, 16 lines at once; the filters (8.7.2.3, 8.7.2.4) on
; words, 8 lines at a time, through the word copies in h264_lfw:
;   +0 p3, +16 p2, +32 p1, +48 p0, +64 q0, +80 q1, +96 q2, +112 q3,
;   +128 filterSamplesFlag, +144 ap < beta, +160 aq < beta (masks; for a
;   bS 4 edge also with |p0 - q0| < (alpha >> 2) + 2), +176 tC0,
;   +192 .. +272 the results p2' p1' p0' q0' q1' q2';
; lines 0-7 at h264_lfw, lines 8-15 at h264_lfw + LFW_HALF.
; Within one frame, bS 4 happens for every line of an edge or for none, so
; an edge is either strong or normal as a whole.

LFW_HALF        equ 384

; H264_ABSD a, b, c, t: a = |b - c| (unsigned bytes); t is scratch
%macro H264_ABSD 4
    movdqa %1, %2
    psubusb %1, %3
    movdqa %4, %3
    psubusb %4, %2
    por %1, %4
%endmacro

; H264_GE a, x, t: a (bytes, a limit, from memory) becomes the mask
; x >= limit; t is scratch
%macro H264_GE 3
    psubusb %1, %2
    pxor %3, %3
    pcmpeqb %1, %3
%endmacro

; H264_STRONG_SIDE p3, p2, p1, p0, q0, q1, mask, out2, out1, out0 (offsets
; in the word copies at ESI): one side of the bS 4 luma filter (8.7.2.4):
; where the mask (ap / aq with the extra condition) holds
;   p0' = (p2 + 2 p1 + 2 p0 + 2 q0 + q1 + 4) >> 3
;   p1' = (p2 + p1 + p0 + q0 + 2) >> 2
;   p2' = (2 p3 + 3 p2 + p1 + p0 + q0 + 4) >> 3
; otherwise p0' = (2 p1 + p0 + q1 + 2) >> 2 (where the edge is filtered at
; all) and p1, p2 stay. XMM6 = 2 in every word; XMM0-XMM5, XMM7 changed.
%macro H264_STRONG_SIDE 10
    movdqu xmm0, [esi + %3]         ; p1
    movdqu xmm1, [esi + %4]         ; p0
    movdqu xmm2, [esi + %5]         ; q0
    movdqu xmm5, [esi + %6]         ; q1
    movdqa xmm7, xmm0               ; the weak p0'
    paddw xmm7, xmm7
    paddw xmm7, xmm1
    paddw xmm7, xmm5
    paddw xmm7, xmm6
    psrlw xmm7, 2
    movdqu xmm4, [esi + 128]
    pand xmm7, xmm4
    pandn xmm4, xmm1
    por xmm7, xmm4                  ; filtered ? weak p0' : p0
    movdqa xmm3, xmm0
    paddw xmm3, xmm1
    paddw xmm3, xmm2                ; s = p1 + p0 + q0
    movdqu xmm4, [esi + %2]         ; p2
    movdqa xmm1, xmm3               ; p0'
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
    movdqa xmm1, xmm4               ; p1'
    paddw xmm1, xmm3
    paddw xmm1, xmm6
    psrlw xmm1, 2
    movdqu xmm2, [esi + %7]
    pand xmm1, xmm2
    pandn xmm2, xmm0
    por xmm1, xmm2
    movdqu [esi + %9], xmm1
    movdqu xmm1, [esi + %1]         ; p2'
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

; H264_WEAK_SIDE p2, p1 (a register), mask, out: p1' = p1 + Clip3(-tC0,
; tC0, (p2 + ((p0 + q0 + 1) >> 1) - (p1 << 1)) >> 1) where the mask (ap <
; beta and filtered) holds. XMM0 = (p0 + q0 + 1) >> 1, XMM1 = tC0, XMM7 =
; -tC0; XMM4 XMM5 changed.
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

; h264_tr8x8: transpose 8x8 bytes: 8 rows of 8 bytes at ESI (EAX bytes
; apart) become 8 rows at EDI (EDX bytes apart): row k of the result =
; byte k of every source row. ESI and EDI advance by 8 rows; ECX and
; XMM0-XMM7 changed.
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
    punpcklbw xmm0, xmm1            ; rows 0, 1 interleaved
    punpcklbw xmm2, xmm3            ; 2, 3
    punpcklbw xmm4, xmm5            ; 4, 5
    punpcklbw xmm6, xmm7            ; 6, 7
    movdqa xmm1, xmm0
    punpcklwd xmm0, xmm2            ; columns 0-3 of rows 0-3
    punpckhwd xmm1, xmm2            ; columns 4-7 of rows 0-3
    movdqa xmm5, xmm4
    punpcklwd xmm4, xmm6            ; columns 0-3 of rows 4-7
    punpckhwd xmm5, xmm6            ; columns 4-7 of rows 4-7
    movdqa xmm2, xmm0
    punpckldq xmm0, xmm4            ; columns 0 | 1
    punpckhdq xmm2, xmm4            ; 2 | 3
    movdqa xmm3, xmm1
    punpckldq xmm1, xmm5            ; 4 | 5
    punpckhdq xmm3, xmm5            ; 6 | 7
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

; h264_lf_bcast: XMM0 = the byte AL in all 16 lanes
h264_lf_bcast:
    movd xmm0, eax
    punpcklbw xmm0, xmm0
    pshuflw xmm0, xmm0, 0
    punpcklqdq xmm0, xmm0
    ret

; h264_lf_lparams: the per-line parameters of a luma edge. EAX = bS of
; its four segments (a byte each), ECX = qP of the p macroblock, EDX = of
; q -> h264_lf_a / _b / _t / _e; ZF = 1 (jz taken) if alpha or beta is 0
; (nothing to filter), else EAX = 1 for a bS 4 edge, 0 otherwise. EBX ESI
; EDI EBP kept.
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
    movd xmm0, ebx                  ; enabled where bS > 0 (4 lines each)
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
    mov esi, [h264_dbk_tc]          ; tC0 of each segment (bS 0..3)
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
    test esp, esp                   ; ZF = 0
.out:
    pop esi
    pop ebx
    ret

; h264_lf_cparams: the per-line parameters of a chroma edge, Cb in lanes
; 0-7, Cr in lanes 8-15 (2 lines per bS segment). EAX = bS of the four
; segments, ESI = MI_ of the p macroblock, EDI = of q (h264_dbk_mb) ->
; h264_lf_a / _b / _t / _e (alpha or beta 0 leaves a plane unfiltered),
; EAX = 1 for a bS 4 edge, else 0. EBX ESI EDI EBP kept.
h264_lf_cparams:
    push ebx
    push ebp
    mov ebx, eax
    movd xmm0, ebx                  ; enabled where bS > 0
    punpcklbw xmm0, xmm0
    punpcklqdq xmm0, xmm0
    pxor xmm1, xmm1
    pcmpeqb xmm0, xmm1
    pcmpeqb xmm1, xmm1
    pxor xmm0, xmm1
    movdqu [h264_lf_e], xmm0
    xor ebp, ebp                    ; plane
.pl:
    movzx eax, byte [edi + MI_QPC + ebp]
    movzx ecx, byte [esi + MI_QPC + ebp]
    call h264_dbk_params
    mov ecx, ebp
    shl ecx, 3                      ; ECX = first lane of the plane
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
    xor edx, edx                    ; segment
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

; h264_lf_masks: the decisions of an edge (8.7.2.2), 16 lines. XMM0 = p0,
; XMM1 = q0, XMM2 = p1, XMM3 = q1 (bytes) -> XMM6 = filterSamplesFlag
; (|p0 - q0| < alpha, |p1 - p0| < beta, |q1 - q0| < beta, bS > 0), also
; in h264_lf_m; h264_lf_d = |p0 - q0|; EAX = its byte mask (0: nothing to
; do). XMM4 XMM5 XMM7 changed.
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

; h264_lf_unpack: word copies of a byte vector for the two halves.
; XMM0 = the vector, EDX = offset in h264_lfw; XMM7 = 0 -> zero extended,
; XMM1 changed.
h264_lf_unpack:
    movdqa xmm1, xmm0
    punpcklbw xmm0, xmm7
    punpckhbw xmm1, xmm7
    movdqu [h264_lfw + edx], xmm0
    movdqu [h264_lfw + edx + LFW_HALF], xmm1
    ret

; h264_lf_unpackm: the same for a mask (0xFF -> 0xFFFF). XMM1 changed.
h264_lf_unpackm:
    movdqa xmm1, xmm0
    punpcklbw xmm0, xmm0
    punpckhbw xmm1, xmm1
    movdqu [h264_lfw + edx], xmm0
    movdqu [h264_lfw + edx + LFW_HALF], xmm1
    ret

; h264_lf_luma: filter one luma edge of 16 lines. EBX = the vector of p3
; samples (16 bytes, one per line), ECX = the distance to the next vector
; (p2, p1, p0, q0, q1, q2, q3 follow), EAX = 1 for a bS 4 edge, else 0;
; h264_lf_a / _b / _t / _e = per line alpha, beta, tC0 and enable.
; p2 .. q2 are rewritten. EBX EBP kept.
h264_lf_luma:
    push ebp
    mov ebp, eax
    lea edx, [ecx * 3]
    lea edi, [ebx + ecx * 4]        ; EDI = q0
    movdqu xmm0, [ebx + edx]        ; p0
    movdqu xmm1, [edi]              ; q0
    movdqu xmm2, [ebx + ecx * 2]    ; p1
    movdqu xmm3, [edi + ecx]        ; q1
    call h264_lf_masks
    test eax, eax
    jz .out
    movdqu xmm2, [ebx + ecx]        ; ap: |p2 - p0| < beta
    H264_ABSD xmm4, xmm2, xmm0, xmm5
    movdqu xmm5, [h264_lf_b]
    H264_GE xmm5, xmm4, xmm7
    pandn xmm5, xmm6
    movdqu xmm3, [edi + ecx * 2]    ; aq: |q2 - q0| < beta
    H264_ABSD xmm4, xmm3, xmm1, xmm7
    movdqu xmm7, [h264_lf_b]
    H264_GE xmm7, xmm4, xmm0
    pandn xmm7, xmm6
    test ebp, ebp
    jz .masks
    mov eax, [h264_lf_a]            ; bS 4: and |p0 - q0| < (alpha >> 2) + 2
    shr eax, 2                      ; (alpha is the same on every line)
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
    mov eax, ebx                    ; the samples
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
    lea eax, [ebx + ecx]            ; p2 .. q2 back as bytes
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
; the bS < 4 filter (8.7.2.3) of 8 lines, word copies at ESI
.weak_half:
    mov eax, 0x00040004
    movd xmm6, eax
    pshufd xmm6, xmm6, 0
    movdqu xmm0, [esi + 48]         ; p0
    movdqu xmm1, [esi + 64]         ; q0
    movdqu xmm2, [esi + 32]         ; p1
    movdqu xmm3, [esi + 80]         ; q1
    movdqa xmm4, xmm1               ; (((q0 - p0) << 2) + (p1 - q1) + 4) >> 3
    psubw xmm4, xmm0
    psllw xmm4, 2
    paddw xmm4, xmm2
    psubw xmm4, xmm3
    paddw xmm4, xmm6
    psraw xmm4, 3
    movdqu xmm5, [esi + 176]        ; tC = tC0 + (ap < beta) + (aq < beta)
    movdqu xmm6, [esi + 144]
    psubw xmm5, xmm6
    movdqu xmm6, [esi + 160]
    psubw xmm5, xmm6
    pminsw xmm4, xmm5               ; delta = Clip3(-tC, tC, ...)
    pxor xmm6, xmm6
    psubw xmm6, xmm5
    pmaxsw xmm4, xmm6
    movdqu xmm6, [esi + 128]
    pand xmm4, xmm6
    movdqa xmm5, xmm0
    paddw xmm5, xmm4
    movdqu [esi + 224], xmm5        ; p0' = Clip1(p0 + delta) (by packing)
    movdqa xmm5, xmm1
    psubw xmm5, xmm4
    movdqu [esi + 240], xmm5        ; q0' = Clip1(q0 - delta)
    pavgw xmm0, xmm1                ; (p0 + q0 + 1) >> 1
    movdqu xmm1, [esi + 176]        ; tC0
    pxor xmm7, xmm7
    psubw xmm7, xmm1
    H264_WEAK_SIDE 16, xmm2, 144, 208
    H264_WEAK_SIDE 96, xmm3, 160, 256
    movdqu xmm4, [esi + 16]         ; p2, q2 stay
    movdqu [esi + 192], xmm4
    movdqu xmm4, [esi + 96]
    movdqu [esi + 272], xmm4
    ret

; h264_lf_chroma: filter one chroma edge, 16 lanes (8 lines of Cb and 8
; of Cr). EBX = the vector of p1 samples, ECX = the distance to the next
; (p0, q0, q1 follow), EAX = 1 for a bS 4 edge; h264_lf_a / _b / _t / _e
; per lane. p0 and q0 are rewritten (8.7.2.3 / 8.7.2.4 with
; chromaEdgeFlag 1). EBX EBP kept.
h264_lf_chroma:
    push ebp
    mov ebp, eax
    movdqu xmm0, [ebx + ecx]        ; p0
    movdqu xmm1, [ebx + ecx * 2]    ; q0
    movdqu xmm2, [ebx]              ; p1
    lea edx, [ecx * 3]
    movdqu xmm3, [ebx + edx]        ; q1
    call h264_lf_masks
    test eax, eax
    jz .out
    pxor xmm7, xmm7                 ; word copies of p1 .. q1
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
    movdqu xmm0, [h264_lfw + 224]   ; p0', q0' back as bytes
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
    movdqu xmm0, [esi + 48]         ; p0
    movdqu xmm1, [esi + 64]         ; q0
    movdqu xmm2, [esi + 32]         ; p1
    movdqu xmm3, [esi + 80]         ; q1
    movdqu xmm6, [esi + 128]        ; filterSamplesFlag
    test ebp, ebp
    jnz .strong
    mov eax, 0x00040004
    movd xmm5, eax
    pshufd xmm5, xmm5, 0
    movdqa xmm4, xmm1               ; (((q0 - p0) << 2) + (p1 - q1) + 4) >> 3
    psubw xmm4, xmm0
    psllw xmm4, 2
    paddw xmm4, xmm2
    psubw xmm4, xmm3
    paddw xmm4, xmm5
    psraw xmm4, 3
    movdqu xmm5, [esi + 176]        ; tC = tC0 + 1
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
    movdqa xmm4, xmm2               ; p0' = (2 p1 + p0 + q1 + 2) >> 2
    paddw xmm4, xmm4
    paddw xmm4, xmm0
    paddw xmm4, xmm3
    paddw xmm4, xmm7
    psrlw xmm4, 2
    movdqa xmm5, xmm3               ; q0' = (2 q1 + q0 + p1 + 2) >> 2
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
h264_lfv        resb 8 * 16         ; an edge's sample vectors (transposed)
h264_lf_a       resb 16             ; per line: alpha
h264_lf_b       resb 16             ;   beta
h264_lf_t       resb 16             ;   tC0
h264_lf_e       resb 16             ;   0xFF where bS > 0
h264_lf_m       resb 16             ;   filterSamplesFlag
h264_lf_d       resb 16             ;   |p0 - q0|
h264_lfw        resb 2 * LFW_HALF   ; word copies (see above)
alignb 4
h264_dbk_lp     resd 1              ; the macroblock in the current frame:
h264_dbk_cbp    resd 1              ;   luma, Cb, Cr
h264_dbk_crp    resd 1
section .text
