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
h264_dbk_bs     resb 4              ; deblocking: bS of the four segments
h264_dbk_bsh    resb 16             ; bS of all edges (4 x 4), vertical
h264_dbk_bsv    resb 16             ;   and horizontal
alignb 4
h264_dbk_a      resd 1              ; alpha, beta, tC0 row of the edge
h264_dbk_b      resd 1
h264_dbk_tc     resd 1
h264_dbk_xs     resd 1              ; step across the edge
h264_dbk_ls     resd 1              ; step along it
h264_dbk_lines  resd 1              ; lines per bS segment (4 / 2)
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

; h264_idct_add: ESI = 4x4 coefficients (int16, raster, already scaled;
; cleared afterwards), EDI = destination, EDX = stride: the inverse
; transform (8.5.12.2) added to the prediction with clipping.
h264_idct_add:
    push ebx
    push esi
    push edi
    push ebp
    push edx
    ; rows: e0 = d0 + d2, e1 = d0 - d2, e2 = (d1 >> 1) - d3, e3 = d1 + (d3 >> 1)
    ; f0 = e0 + e3, f1 = e1 + e2, f2 = e1 - e2, f3 = e0 - e3
    xor ebx, ebx
.row:
    movsx eax, word [esi + ebx * 8]
    movsx ecx, word [esi + ebx * 8 + 2]
    movsx edx, word [esi + ebx * 8 + 4]
    movsx ebp, word [esi + ebx * 8 + 6]
    call h264_idct1
    push ebx
    shl ebx, 4
    mov [h264_tmpi + ebx], eax
    mov [h264_tmpi + ebx + 4], ecx
    mov [h264_tmpi + ebx + 8], edx
    mov [h264_tmpi + ebx + 12], ebp
    pop ebx
    inc ebx
    cmp ebx, 4
    jb .row
    xor eax, eax
    mov [esi], eax
    mov [esi + 4], eax
    mov [esi + 8], eax
    mov [esi + 12], eax
    mov [esi + 16], eax
    mov [esi + 20], eax
    mov [esi + 24], eax
    mov [esi + 28], eax
    ; columns, then (x + 32) >> 6 added to the prediction
    pop esi                         ; ESI = stride
    xor ebx, ebx
.col:
    mov eax, [h264_tmpi + ebx * 4]
    mov ecx, [h264_tmpi + ebx * 4 + 16]
    mov edx, [h264_tmpi + ebx * 4 + 32]
    mov ebp, [h264_tmpi + ebx * 4 + 48]
    call h264_idct1
    push edi
    add edi, ebx
    call .put
    mov eax, ecx
    call .put
    mov eax, edx
    call .put
    mov eax, ebp
    call .put
    pop edi
    inc ebx
    cmp ebx, 4
    jb .col
    pop ebp
    pop edi
    pop esi
    pop ebx
    ret
.put:                               ; EAX = residual: pixel at EDI, next row
    push edx
    add eax, 32
    sar eax, 6
    movzx edx, byte [edi]
    add edx, eax
    call h264_clip1
    mov [edi], dl
    add edi, esi
    pop edx
    ret

; h264_idct1: one 4-point inverse transform: EAX, ECX, EDX, EBP = d0..d3 ->
; the four results in the same registers. EBX ESI EDI kept.
h264_idct1:
    push esi
    push edi
    lea esi, [eax + edx]            ; e0
    sub eax, edx                    ; e1
    mov edi, ecx
    sar edi, 1
    sub edi, ebp                    ; e2
    sar ebp, 1
    add ebp, ecx                    ; e3
    lea ecx, [eax + edi]            ; f1 = e1 + e2
    sub eax, edi                    ; f2 = e1 - e2
    mov edx, eax
    lea eax, [esi + ebp]            ; f0 = e0 + e3
    sub esi, ebp                    ; f3 = e0 - e3
    mov ebp, esi
    pop edi
    pop esi
    ret

; =============================================================================
;  Motion compensation
; =============================================================================

; h264_mc_luma: luma prediction of a w x h block (8.4.2.2.1) from the
; reference plane ESI (its top-left pixel) into EDI (the current frame).
; h264_mc_x / _y = position of the block in quarter samples (vector
; included), h264_mc_w / _h = size. Both planes have stride h264_ystride.
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
    mov ebx, ebp                    ; destination stride
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
    add edi, ebp
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
; samples, h264_mc_w / _h = size; stride h264_cstride.
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
    add edi, ebp
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
    shl eax, 6
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
    ; filter: luma
    mov ebx, [h264_cur]
    SLOTP ebx
    mov eax, [h264_dbk_y]
    shl eax, 4
    imul eax, [h264_ystride]
    mov edx, [h264_dbk_x]
    shl edx, 4
    add eax, edx
    add eax, [ebx + SL_Y]
    mov [h264_tmpi + 120], eax      ; the macroblock's luma
    xor ebp, ebp                    ; vertical edges
.lv:
    mov eax, [h264_dbk_bsh + ebp * 4]
    test eax, eax
    jz .lvn
    mov [h264_dbk_bs], eax
    mov esi, [h264_dbk_mb]          ; qP of the two macroblocks
    movzx eax, byte [esi + MI_QP]
    test ebp, ebp
    jnz .lv1
    movzx ecx, byte [esi - MI_SZ + MI_QP]
    jmp .lv2
.lv1:
    mov ecx, eax
.lv2:
    call h264_dbk_params
    jz .lvn
    mov edi, [h264_tmpi + 120]
    lea edi, [edi + ebp * 4]
    mov dword [h264_dbk_xs], 1
    mov eax, [h264_ystride]
    mov [h264_dbk_ls], eax
    mov dword [h264_dbk_lines], 4
    call h264_filter_luma
.lvn:
    inc ebp
    cmp ebp, 4
    jb .lv
    xor ebp, ebp                    ; horizontal edges
.lh:
    mov eax, [h264_dbk_bsv + ebp * 4]
    test eax, eax
    jz .lhn
    mov [h264_dbk_bs], eax
    mov esi, [h264_dbk_mb]
    movzx eax, byte [esi + MI_QP]
    mov ecx, eax
    test ebp, ebp
    jnz .lh2
    mov ecx, [h264_mbw]
    shl ecx, 6
    neg ecx
    movzx ecx, byte [esi + ecx + MI_QP]
.lh2:
    call h264_dbk_params
    jz .lhn
    mov edi, ebp
    shl edi, 2
    imul edi, [h264_ystride]
    add edi, [h264_tmpi + 120]
    mov eax, [h264_ystride]
    mov [h264_dbk_xs], eax
    mov dword [h264_dbk_ls], 1
    mov dword [h264_dbk_lines], 4
    call h264_filter_luma
.lhn:
    inc ebp
    cmp ebp, 4
    jb .lh
    ; chroma: edges 0 and 2 (in 4x4 luma block units), both planes
    xor ebp, ebp                    ; 0 = Cb, 1 = Cr
.cp:
    mov ebx, [h264_cur]
    SLOTP ebx
    mov eax, [h264_dbk_y]
    shl eax, 3
    imul eax, [h264_cstride]
    mov edx, [h264_dbk_x]
    shl edx, 3
    add eax, edx
    add eax, [ebx + SL_U + ebp * 4]
    mov [h264_tmpi + 124], eax
    xor ebx, ebx                    ; vertical edges 0, 2
.cv:
    mov eax, [h264_dbk_bsh + ebx * 4]
    test eax, eax
    jz .cvn
    mov [h264_dbk_bs], eax
    mov esi, [h264_dbk_mb]
    movzx eax, byte [esi + MI_QPC + ebp]
    mov ecx, eax
    test ebx, ebx
    jnz .cv2
    movzx ecx, byte [esi - MI_SZ + MI_QPC + ebp]
.cv2:
    call h264_dbk_params
    jz .cvn
    mov edi, [h264_tmpi + 124]
    lea edi, [edi + ebx * 2]
    mov dword [h264_dbk_xs], 1
    mov eax, [h264_cstride]
    mov [h264_dbk_ls], eax
    mov dword [h264_dbk_lines], 2
    call h264_filter_chroma
.cvn:
    add ebx, 2
    cmp ebx, 4
    jb .cv
    xor ebx, ebx                    ; horizontal edges 0, 2
.ch:
    mov eax, [h264_dbk_bsv + ebx * 4]
    test eax, eax
    jz .chn
    mov [h264_dbk_bs], eax
    mov esi, [h264_dbk_mb]
    movzx eax, byte [esi + MI_QPC + ebp]
    mov ecx, eax
    test ebx, ebx
    jnz .ch2
    mov ecx, [h264_mbw]
    shl ecx, 6
    neg ecx
    add ecx, esi
    movzx ecx, byte [ecx + MI_QPC + ebp]
.ch2:
    call h264_dbk_params
    jz .chn
    mov edi, ebx
    shl edi, 1
    imul edi, [h264_cstride]
    add edi, [h264_tmpi + 124]
    mov eax, [h264_cstride]
    mov [h264_dbk_xs], eax
    mov dword [h264_dbk_ls], 1
    mov dword [h264_dbk_lines], 2
    call h264_filter_chroma
.chn:
    add ebx, 2
    cmp ebx, 4
    jb .ch
    inc ebp
    cmp ebp, 2
    jb .cp
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
    ; different reference frames or vectors 4 quarter samples apart
    mov esi, [h264_dbk_pmo]
    mov edi, [h264_dbk_mo]
    push eax
    push ecx
    mov edx, eax                    ; 8x8 index = (y >> 1) * 2 + (x >> 1)
    shr edx, 3
    shl edx, 1
    and eax, 3
    shr eax, 1
    add edx, eax
    movzx edx, byte [esi + MO_RS0 + edx]
    mov eax, ecx
    shr eax, 3
    shl eax, 1
    and ecx, 3
    shr ecx, 1
    add eax, ecx
    movzx eax, byte [edi + MO_RS0 + eax]
    cmp eax, edx
    pop ecx
    pop eax
    jne .one
    movsx edx, word [esi + MO_MV0 + eax * 4]
    movsx eax, word [esi + MO_MV0 + eax * 4 + 2]
    push eax
    movsx eax, word [edi + MO_MV0 + ecx * 4]
    sub edx, eax
    jns .ax
    neg edx
.ax:
    pop eax
    cmp edx, 4
    jge .one
    movsx edx, word [edi + MO_MV0 + ecx * 4 + 2]
    sub eax, edx
    jns .ay
    neg eax
.ay:
    cmp eax, 4
    jge .one
    xor eax, eax
    jmp .out
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

; h264_filter_luma: filter one luma edge of 16 lines. EDI = q0 of the first
; line, h264_dbk_xs = step across the edge, _ls = to the next line,
; h264_dbk_bs = bS of the four segments of 4 lines. EBX EBP kept.
h264_filter_luma:
    push ebx
    push ebp
    xor ebx, ebx                    ; line
.line:
    mov eax, ebx
    shr eax, 2
    movzx eax, byte [h264_dbk_bs + eax]
    test eax, eax
    jz .next
    push ebx
    mov ebp, eax                    ; EBP = bS
    mov esi, [h264_dbk_xs]
    ; samples: p0 = [edi - xs], p1 = [edi - 2 xs] ...; q0 = [edi] ...
    mov ecx, edi
    sub ecx, esi
    movzx eax, byte [ecx]           ; p0
    movzx edx, byte [edi]           ; q0
    mov [h264_fl + 0], eax
    mov [h264_fl + 16], edx
    sub ecx, esi
    movzx eax, byte [ecx]
    mov [h264_fl + 4], eax          ; p1
    sub ecx, esi
    movzx eax, byte [ecx]
    mov [h264_fl + 8], eax          ; p2
    sub ecx, esi
    movzx eax, byte [ecx]
    mov [h264_fl + 12], eax         ; p3
    lea ecx, [edi + esi]
    movzx eax, byte [ecx]
    mov [h264_fl + 20], eax         ; q1
    add ecx, esi
    movzx eax, byte [ecx]
    mov [h264_fl + 24], eax         ; q2
    add ecx, esi
    movzx eax, byte [ecx]
    mov [h264_fl + 28], eax         ; q3
    ; |p0 - q0| < alpha, |p1 - p0| < beta, |q1 - q0| < beta
    mov eax, [h264_fl + 0]
    sub eax, [h264_fl + 16]
    call h264_abs
    cmp eax, [h264_dbk_a]
    jae .skip
    mov eax, [h264_fl + 4]
    sub eax, [h264_fl + 0]
    call h264_abs
    cmp eax, [h264_dbk_b]
    jae .skip
    mov eax, [h264_fl + 20]
    sub eax, [h264_fl + 16]
    call h264_abs
    cmp eax, [h264_dbk_b]
    jae .skip
    mov eax, [h264_fl + 8]          ; ap = |p2 - p0|, aq = |q2 - q0|
    sub eax, [h264_fl + 0]
    call h264_abs
    mov [h264_fl + 32], eax
    mov eax, [h264_fl + 24]
    sub eax, [h264_fl + 16]
    call h264_abs
    mov [h264_fl + 36], eax
    cmp ebp, 4
    je .strong
    ; bS < 4: tC = tC0 + (ap < beta) + (aq < beta)
    mov eax, [h264_dbk_tc]
    movzx ecx, byte [eax + ebp]     ; tC0
    mov edx, ecx
    mov eax, [h264_fl + 32]
    cmp eax, [h264_dbk_b]
    jae .t1
    inc edx
.t1:
    mov eax, [h264_fl + 36]
    cmp eax, [h264_dbk_b]
    jae .t2
    inc edx
.t2:
    ; delta = Clip3(-tC, tC, (((q0 - p0) << 2) + (p1 - q1) + 4) >> 3)
    mov eax, [h264_fl + 16]
    sub eax, [h264_fl + 0]
    shl eax, 2
    add eax, [h264_fl + 4]
    sub eax, [h264_fl + 20]
    add eax, 4
    sar eax, 3
    call h264_clip3                 ; EAX in -EDX..EDX
    push ecx
    mov ecx, edi
    sub ecx, esi
    mov edx, [h264_fl + 0]
    add edx, eax
    call h264_clip1
    mov [ecx], dl                   ; p0'
    mov edx, [h264_fl + 16]
    sub edx, eax
    call h264_clip1
    mov [edi], dl                   ; q0'
    pop ecx
    ; p1' = p1 + Clip3(-tC0, tC0, (p2 + ((p0 + q0 + 1) >> 1) - (p1 << 1)) >> 1)
    mov eax, [h264_fl + 0]
    add eax, [h264_fl + 16]
    inc eax
    shr eax, 1
    mov [h264_fl + 40], eax
    mov eax, [h264_fl + 32]
    cmp eax, [h264_dbk_b]
    jae .nop1
    mov eax, [h264_fl + 8]
    add eax, [h264_fl + 40]
    mov edx, [h264_fl + 4]
    shl edx, 1
    sub eax, edx
    sar eax, 1
    mov edx, ecx
    call h264_clip3
    add eax, [h264_fl + 4]
    mov edx, edi
    sub edx, esi
    sub edx, esi
    mov [edx], al
.nop1:
    mov eax, [h264_fl + 36]
    cmp eax, [h264_dbk_b]
    jae .skip
    mov eax, [h264_fl + 24]
    add eax, [h264_fl + 40]
    mov edx, [h264_fl + 20]
    shl edx, 1
    sub eax, edx
    sar eax, 1
    mov edx, ecx
    call h264_clip3
    add eax, [h264_fl + 20]
    mov [edi + esi], al
    jmp .skip
.strong:
    ; bS = 4: strong filter where the edge is smooth enough
    mov eax, [h264_fl + 0]
    sub eax, [h264_fl + 16]
    call h264_abs
    mov edx, [h264_dbk_a]
    shr edx, 2
    add edx, 2
    mov [h264_fl + 44], eax         ; |p0 - q0|
    mov [h264_fl + 48], edx         ; (alpha >> 2) + 2
    mov eax, [h264_fl + 32]
    cmp eax, [h264_dbk_b]
    jae .pweak
    mov eax, [h264_fl + 44]
    cmp eax, [h264_fl + 48]
    jae .pweak
    ; p0' = (p2 + 2 p1 + 2 p0 + 2 q0 + q1 + 4) >> 3
    mov eax, [h264_fl + 4]
    add eax, [h264_fl + 0]
    add eax, [h264_fl + 16]
    shl eax, 1
    add eax, [h264_fl + 8]
    add eax, [h264_fl + 20]
    add eax, 4
    shr eax, 3
    mov ecx, edi
    sub ecx, esi
    mov [ecx], al
    ; p1' = (p2 + p1 + p0 + q0 + 2) >> 2
    mov eax, [h264_fl + 8]
    add eax, [h264_fl + 4]
    add eax, [h264_fl + 0]
    add eax, [h264_fl + 16]
    add eax, 2
    shr eax, 2
    sub ecx, esi
    mov [ecx], al
    ; p2' = (2 p3 + 3 p2 + p1 + p0 + q0 + 4) >> 3
    mov eax, [h264_fl + 12]
    shl eax, 1
    mov edx, [h264_fl + 8]
    lea edx, [edx * 2 + edx]
    add eax, edx
    add eax, [h264_fl + 4]
    add eax, [h264_fl + 0]
    add eax, [h264_fl + 16]
    add eax, 4
    shr eax, 3
    sub ecx, esi
    mov [ecx], al
    jmp .qside
.pweak:
    ; p0' = (2 p1 + p0 + q1 + 2) >> 2
    mov eax, [h264_fl + 4]
    shl eax, 1
    add eax, [h264_fl + 0]
    add eax, [h264_fl + 20]
    add eax, 2
    shr eax, 2
    mov ecx, edi
    sub ecx, esi
    mov [ecx], al
.qside:
    mov eax, [h264_fl + 36]
    cmp eax, [h264_dbk_b]
    jae .qweak
    mov eax, [h264_fl + 44]
    cmp eax, [h264_fl + 48]
    jae .qweak
    ; q0' = (p1 + 2 p0 + 2 q0 + 2 q1 + q2 + 4) >> 3
    mov eax, [h264_fl + 0]
    add eax, [h264_fl + 16]
    add eax, [h264_fl + 20]
    shl eax, 1
    add eax, [h264_fl + 4]
    add eax, [h264_fl + 24]
    add eax, 4
    shr eax, 3
    mov [edi], al
    ; q1' = (p0 + q0 + q1 + q2 + 2) >> 2
    mov eax, [h264_fl + 0]
    add eax, [h264_fl + 16]
    add eax, [h264_fl + 20]
    add eax, [h264_fl + 24]
    add eax, 2
    shr eax, 2
    mov [edi + esi], al
    ; q2' = (2 q3 + 3 q2 + q1 + q0 + p0 + 4) >> 3
    mov eax, [h264_fl + 28]
    shl eax, 1
    mov edx, [h264_fl + 24]
    lea edx, [edx * 2 + edx]
    add eax, edx
    add eax, [h264_fl + 20]
    add eax, [h264_fl + 16]
    add eax, [h264_fl + 0]
    add eax, 4
    shr eax, 3
    lea ecx, [edi + esi * 2]
    mov [ecx], al
    jmp .skip
.qweak:
    ; q0' = (2 q1 + q0 + p1 + 2) >> 2
    mov eax, [h264_fl + 20]
    shl eax, 1
    add eax, [h264_fl + 16]
    add eax, [h264_fl + 4]
    add eax, 2
    shr eax, 2
    mov [edi], al
.skip:
    pop ebx
.next:
    add edi, [h264_dbk_ls]
    inc ebx
    cmp ebx, 16
    jb .line
    pop ebp
    pop ebx
    ret

; h264_filter_chroma: filter one chroma edge of 8 lines (bS segment = 2
; lines); arguments as h264_filter_luma. EBX EBP kept.
h264_filter_chroma:
    push ebx
    push ebp
    xor ebx, ebx
.line:
    mov eax, ebx
    shr eax, 1
    movzx eax, byte [h264_dbk_bs + eax]
    test eax, eax
    jz .next
    mov ebp, eax
    mov esi, [h264_dbk_xs]
    mov ecx, edi
    sub ecx, esi
    movzx eax, byte [ecx]           ; p0
    mov [h264_fl + 0], eax
    sub ecx, esi
    movzx eax, byte [ecx]           ; p1
    mov [h264_fl + 4], eax
    movzx eax, byte [edi]           ; q0
    mov [h264_fl + 16], eax
    movzx eax, byte [edi + esi]     ; q1
    mov [h264_fl + 20], eax
    mov eax, [h264_fl + 0]
    sub eax, [h264_fl + 16]
    call h264_abs
    cmp eax, [h264_dbk_a]
    jae .next
    mov eax, [h264_fl + 4]
    sub eax, [h264_fl + 0]
    call h264_abs
    cmp eax, [h264_dbk_b]
    jae .next
    mov eax, [h264_fl + 20]
    sub eax, [h264_fl + 16]
    call h264_abs
    cmp eax, [h264_dbk_b]
    jae .next
    lea ecx, [edi]
    sub ecx, esi                    ; ECX = p0
    cmp ebp, 4
    je .strong
    mov eax, [h264_dbk_tc]          ; tC = tC0 + 1
    movzx edx, byte [eax + ebp]
    inc edx
    mov eax, [h264_fl + 16]
    sub eax, [h264_fl + 0]
    shl eax, 2
    add eax, [h264_fl + 4]
    sub eax, [h264_fl + 20]
    add eax, 4
    sar eax, 3
    call h264_clip3
    mov edx, [h264_fl + 0]
    add edx, eax
    call h264_clip1
    mov [ecx], dl
    mov edx, [h264_fl + 16]
    sub edx, eax
    call h264_clip1
    mov [edi], dl
    jmp .next
.strong:
    mov eax, [h264_fl + 4]          ; p0' = (2 p1 + p0 + q1 + 2) >> 2
    shl eax, 1
    add eax, [h264_fl + 0]
    add eax, [h264_fl + 20]
    add eax, 2
    shr eax, 2
    mov [ecx], al
    mov eax, [h264_fl + 20]         ; q0' = (2 q1 + q0 + p1 + 2) >> 2
    shl eax, 1
    add eax, [h264_fl + 16]
    add eax, [h264_fl + 4]
    add eax, 2
    shr eax, 2
    mov [edi], al
.next:
    add edi, [h264_dbk_ls]
    inc ebx
    cmp ebx, 8
    jb .line
    pop ebp
    pop ebx
    ret

; h264_abs: EAX -> |EAX|
h264_abs:
    test eax, eax
    jns .r
    neg eax
.r: ret

; h264_clip3: EAX clipped to -EDX..EDX
h264_clip3:
    cmp eax, edx
    jle .a
    mov eax, edx
    ret
.a: neg edx
    cmp eax, edx
    jge .b
    mov eax, edx
.b: neg edx
    ret

section .bss
alignb 4
h264_fl         resd 16             ; one line of the deblocking filter
section .text
