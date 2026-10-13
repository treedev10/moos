; =============================================================================
;  gfx.asm - 32-bit framebuffer graphics for the GUI (UEFI only)
;
;  Everything is drawn into a RAM back buffer (GUI_BB), then copied to the
;  real framebuffer in one go by gfx_present, so there is no flicker. The back
;  buffer holds pixels already in the screen's format, so present is a plain
;  row copy. Colours are turned into that format once, by gfx_rgb.
;
;  The framebuffer and the back buffer are reached as ordinary 32-bit
;  addresses: under UEFI the firmware identity-maps them, and MOOS runs with
;  that mapping.
;
;  Drawing (rectangles, pixels, characters) stays inside a clip rectangle,
;  normally the whole screen. The window manager narrows it to a window's
;  inside while that window draws, so nothing spills over its edges.
;
;  Characters come from the 8x16 VGA font, drawn at any width from 8 to 32
;  pixels (the height is always twice the width) and optionally bold,
;  slanted (italic), underlined or struck through - enough for the
;  browser's headings and text styles.
; =============================================================================
GS_BOLD     equ 1                   ; gfx_style bits
GS_ITALIC   equ 2
GS_ULINE    equ 4
GS_STRIKE   equ 8
section .bss
alignb 4
gfx_w       resd 1          ; width in pixels
gfx_h       resd 1          ; height
gfx_fb      resd 1          ; framebuffer address (low 32 bits)
gfx_fbpitch resd 1          ; framebuffer pixels per row
gfx_cx0     resd 1          ; clip rectangle: left, top (inclusive) ...
gfx_cy0     resd 1
gfx_cx1     resd 1          ; ... right, bottom (exclusive)
gfx_cy1     resd 1
gfx_sv0     resd 1          ; (a saved clip rectangle)
gfx_sv1     resd 1
gfx_sv2     resd 1
gfx_sv3     resd 1
gfx_ready   resb 1

section .text

; gfx_init: read the framebuffer details from bootinfo. CF=1 if no graphics.
gfx_init:
    push eax
    cmp dword [bootinfo + BI.platform], PLATFORM_UEFI
    jne .no
    mov eax, [bootinfo + BI.fb_base]
    test eax, eax
    jz .no
    mov [gfx_fb], eax
    mov eax, [bootinfo + BI.fb_width]
    mov [gfx_w], eax
    mov eax, [bootinfo + BI.fb_height]
    mov [gfx_h], eax
    mov eax, [bootinfo + BI.fb_pitch]
    mov [gfx_fbpitch], eax
    mov byte [gfx_ready], 1
    call gfx_clip_full
    pop eax
    clc
    ret
.no:
    mov byte [gfx_ready], 0
    pop eax
    stc
    ret

; gfx_rgb: EAX = 0x00RRGGBB -> EAX = a pixel in the framebuffer's format
gfx_rgb:
    push ebx
    push ecx
    push edx
    movzx ebx, al                   ; blue
    mov ecx, eax
    shr ecx, 8
    movzx ecx, cl                   ; green
    mov edx, eax
    shr edx, 16
    movzx edx, dl                   ; red
    mov eax, [bootinfo + BI.fb_format]
    cmp eax, 1
    je .bgr
    cmp eax, 2
    je .mask
    ; RGBX: byte order R,G,B,X -> little-endian 0x00BBGGRR
    mov eax, edx
    shl ecx, 8
    shl ebx, 16
    or eax, ecx
    or eax, ebx
    jmp .done
.bgr:                               ; BGRX -> 0x00RRGGBB
    mov eax, edx
    shl eax, 16
    shl ecx, 8
    or eax, ecx
    or eax, ebx
    jmp .done
.mask:
    push edx
    mov edx, [bootinfo + BI.fb_rmask]
    bsf ecx, edx
    mov eax, [esp]                  ; red
    shl eax, cl
    and eax, edx
    mov edx, [esp]                  ; (placeholder) rebuild below
    pop edx
    ; simple approximation for odd masks: fall back to RGBX ordering
    mov eax, edx
    shl ecx, 8
    shl ebx, 16
    or eax, ecx
    or eax, ebx
.done:
    pop edx
    pop ecx
    pop ebx
    ret

; gfx_clear: fill the whole back buffer with EAX (framebuffer-format pixel)
gfx_clear:
    push ecx
    push edi
    mov edi, GUI_BB
    mov ecx, [gfx_w]
    imul ecx, [gfx_h]
    rep stosd
    pop edi
    pop ecx
    ret

; gfx_clip_full: drawing may use the whole screen again
gfx_clip_full:
    push eax
    xor eax, eax
    mov [gfx_cx0], eax
    mov [gfx_cy0], eax
    mov eax, [gfx_w]
    mov [gfx_cx1], eax
    mov eax, [gfx_h]
    mov [gfx_cy1], eax
    pop eax
    ret

; gfx_clip_set: keep drawing inside ECX = x, EDX = y, ESI = width,
; EDI = height (cut to the screen)
gfx_clip_set:
    pushad
    call gfx_clip
    jnc .ok
    xor ecx, ecx                    ; nothing of it on screen: empty clip
    xor edx, edx
    xor esi, esi
    xor edi, edi
.ok:
    mov [gfx_cx0], ecx
    mov [gfx_cy0], edx
    add ecx, esi
    add edx, edi
    mov [gfx_cx1], ecx
    mov [gfx_cy1], edx
    popad
    ret

; gfx_clip_save / gfx_clip_restore: keep the clip rectangle (one level)
gfx_clip_save:
    push eax
    mov eax, [gfx_cx0]
    mov [gfx_sv0], eax
    mov eax, [gfx_cy0]
    mov [gfx_sv1], eax
    mov eax, [gfx_cx1]
    mov [gfx_sv2], eax
    mov eax, [gfx_cy1]
    mov [gfx_sv3], eax
    pop eax
    ret
gfx_clip_restore:
    push eax
    mov eax, [gfx_sv0]
    mov [gfx_cx0], eax
    mov eax, [gfx_sv1]
    mov [gfx_cy0], eax
    mov eax, [gfx_sv2]
    mov [gfx_cx1], eax
    mov eax, [gfx_sv3]
    mov [gfx_cy1], eax
    pop eax
    ret

; gfx_clip_and: narrow the clip rectangle to ECX = x, EDX = y, ESI = width,
; EDI = height as well
gfx_clip_and:
    push eax
    push esi
    push edi
    add esi, ecx                    ; (right, bottom)
    add edi, edx
    cmp ecx, [gfx_cx0]
    jle .x0
    mov [gfx_cx0], ecx
.x0:
    cmp edx, [gfx_cy0]
    jle .y0
    mov [gfx_cy0], edx
.y0:
    cmp esi, [gfx_cx1]
    jge .x1
    mov [gfx_cx1], esi
.x1:
    cmp edi, [gfx_cy1]
    jge .y1
    mov [gfx_cy1], edi
.y1:
    pop edi
    pop esi
    pop eax
    ret

; gfx_fillrect: ECX = x, EDX = y, ESI = width, EDI = height, EAX = pixel.
; Cut to the clip rectangle.
gfx_fillrect:
    pushad
    mov ebp, eax                    ; colour
    mov eax, [gfx_cx0]              ; left edge
    sub eax, ecx
    jle .x_ok
    sub esi, eax
    mov ecx, [gfx_cx0]
.x_ok:
    mov eax, [gfx_cy0]              ; top edge
    sub eax, edx
    jle .y_ok
    sub edi, eax
    mov edx, [gfx_cy0]
.y_ok:
    mov eax, [gfx_cx1]              ; right edge
    sub eax, ecx
    cmp esi, eax
    jle .w_ok
    mov esi, eax
.w_ok:
    mov eax, [gfx_cy1]              ; bottom edge
    sub eax, edx
    cmp edi, eax
    jle .h_ok
    mov edi, eax
.h_ok:
    test esi, esi
    jle .done
    test edi, edi
    jle .done
    mov eax, edx                    ; start address = (y*w + x)*4
    imul eax, [gfx_w]
    add eax, ecx
    lea eax, [GUI_BB + eax * 4]
    mov ecx, [gfx_w]                ; back-buffer row stride in bytes
    shl ecx, 2
.row:                               ; EDI = rows left, ESI = width, EBP = colour
    push ecx
    push edi
    mov edi, eax
    mov ecx, esi
    push eax
    mov eax, ebp
    rep stosd
    pop eax
    pop edi
    pop ecx
    add eax, ecx
    dec edi
    jnz .row
.done:
    popad
    ret

; gfx_frame: a 1-pixel outline. ECX = x, EDX = y, ESI = width,
; EDI = height, EAX = pixel
gfx_frame:
    pushad
    push edi
    mov edi, 1
    call gfx_fillrect               ; top
    pop edi
    push edx
    lea edx, [edx + edi - 1]
    push edi
    mov edi, 1
    call gfx_fillrect               ; bottom
    pop edi
    pop edx
    push esi
    mov esi, 1
    call gfx_fillrect               ; left
    pop esi
    lea ecx, [ecx + esi - 1]
    mov esi, 1
    call gfx_fillrect               ; right
    popad
    ret

; gfx_pixel: ECX = x, EDX = y, EAX = pixel (nothing outside the clip)
gfx_pixel:
    cmp ecx, [gfx_cx0]
    jl .no
    cmp ecx, [gfx_cx1]
    jge .no
    cmp edx, [gfx_cy0]
    jl .no
    cmp edx, [gfx_cy1]
    jge .no
    push edi
    push edx
    imul edx, [gfx_w]
    add edx, ecx
    lea edi, [GUI_BB + edx * 4]
    mov [edi], eax
    pop edx
    pop edi
.no:
    ret

section .bss
alignb 4
gfx_scale   resd 1          ; gfx_char / gfx_text size: 1 = 8x16, 2 = 16x32
gfx_cw      resd 1          ; gfx_glyph size: cell width (height = 2x)
gfx_style   resd 1          ; gfx_glyph style: GS_* bits
section .text

; gfx_char: ECX = x, EDX = y, AL = character, EBX = fg pixel, EBP = bg pixel
; (EBP = -1 means transparent background). Size from gfx_scale, plain style.
gfx_char:
    push dword [gfx_cw]
    push dword [gfx_style]
    push eax
    mov eax, [gfx_scale]
    shl eax, 3
    mov [gfx_cw], eax
    mov dword [gfx_style], 0
    pop eax
    call gfx_glyph
    pop dword [gfx_style]
    pop dword [gfx_cw]
    ret

; gfx_glyph: ECX = x, EDX = y, AL = character, EBX = fg pixel, EBP = bg
; pixel or -1. The cell is gfx_cw wide (8 to 32) and twice that high; the
; font is stretched to it. gfx_style adds bold (each dot also drawn one to
; the right), italic (rows shifted right towards the top), underline and
; strike-through (a full row). Cut to the clip rectangle.
gfx_glyph:
    pushad
    movzx eax, al
    shl eax, 4
    add eax, font_8x16
    mov [gg_glyph], eax
    mov [gg_x], ecx
    mov [gg_y], edx
    mov [gg_fg], ebx
    mov eax, [gfx_cw]
    cmp eax, [gg_maskw]
    je .masks
    call gg_masks_make
.masks:
    add eax, eax
    mov [gg_ch], eax
    mov dword [gg_dy], 0
.row:
    mov eax, [gg_dy]
    cmp eax, [gg_ch]
    jae .done
    add eax, [gg_y]                 ; the screen row
    cmp eax, [gfx_cy0]
    jl .next
    cmp eax, [gfx_cy1]
    jge .done
    imul eax, [gfx_w]
    mov [gg_rowp], eax
    mov eax, [gg_dy]                ; the font row: dy * 16 / height
    shl eax, 3
    xor edx, edx
    div dword [gfx_cw]
    mov ecx, eax
    mov ebx, [gg_glyph]
    movzx ebx, byte [ebx + ecx]     ; its 8 dots
    mov al, [gfx_style]
    test al, GS_BOLD
    jz .nb
    mov edx, ebx
    shr edx, 1
    or ebx, edx
.nb:
    test al, GS_ULINE
    jz .nu
    cmp ecx, 14
    jne .nu
    mov ebx, 0xFF
.nu:
    test al, GS_STRIKE
    jz .ns
    cmp ecx, 8
    jne .ns
    mov ebx, 0xFF
.ns:
    mov ecx, [gg_x]                 ; ECX = x of the row's first column
    test al, GS_ITALIC
    jz .ni
    mov eax, [gg_ch]                ; shift: (height - 1 - dy) / 5
    dec eax
    sub eax, [gg_dy]
    xor edx, edx
    push ecx
    mov ecx, 5
    div ecx
    pop ecx
    add ecx, eax
.ni:
    xor esi, esi                    ; ESI = first column, EDX = end, clipped
    mov eax, [gfx_cx0]
    sub eax, ecx
    jle .c0
    mov esi, eax
.c0:
    mov edx, [gfx_cx1]
    sub edx, ecx
    cmp edx, [gfx_cw]
    jle .c1
    mov edx, [gfx_cw]
.c1:
    cmp esi, edx
    jge .next
    mov edi, [gg_rowp]
    add edi, ecx
    add edi, esi
    lea edi, [GUI_BB + edi * 4]
    mov eax, [gg_fg]
.col:
    test bl, [gg_masks + esi]
    jz .bg
    mov [edi], eax
    jmp .cn
.bg:
    cmp ebp, -1
    je .cn
    mov [edi], ebp
.cn:
    add edi, 4
    inc esi
    cmp esi, edx
    jl .col
.next:
    inc dword [gg_dy]
    jmp .row
.done:
    popad
    ret

; gg_masks_make: EAX = cell width -> gg_masks[x] = the font bit for column x
gg_masks_make:
    pushad
    mov [gg_maskw], eax
    mov ebx, eax
    xor ecx, ecx
.l:
    cmp ecx, ebx
    jae .done
    cmp ecx, 32
    jae .done
    mov eax, ecx
    shl eax, 3
    xor edx, edx
    div ebx                         ; font column 0..7
    push ecx
    mov ecx, eax
    mov al, 0x80
    shr al, cl
    pop ecx
    mov [gg_masks + ecx], al
    inc ecx
    jmp .l
.done:
    popad
    ret

section .bss
alignb 4
gg_glyph resd 1
gg_x     resd 1
gg_y     resd 1
gg_fg    resd 1
gg_ch    resd 1
gg_dy    resd 1
gg_rowp  resd 1
gg_maskw resd 1
gg_masks resb 32
section .text

; gfx_text: ESI = string, ECX = x, EDX = y, EBX = fg, EBP = bg
gfx_text:
    pushad
    mov [gt_x], ecx
.l: mov al, [esi]
    test al, al
    jz .done
    mov ecx, [gt_x]
    call gfx_char
    mov eax, 8
    imul eax, [gfx_scale]
    add [gt_x], eax
    inc esi
    jmp .l
.done:
    popad
    ret
section .bss
alignb 4
gt_x resd 1
section .text

; gfx_icon: a 16x16 one-colour picture: ESI = 16 words (one per row, the
; top bit is the left pixel), ECX = x, EDX = y, EAX = pixel
gfx_icon:
    push ebx
    mov ebx, 16
    call gfx_bitmap
    pop ebx
    ret

; gfx_bitmap: the same, EBX rows high
gfx_bitmap:
    pushad
.row:
    movzx edi, word [esi]
    add esi, 2
    push ecx
.col:
    test di, 0x8000
    jz .n
    call gfx_pixel
.n: inc ecx
    shl di, 1
    jnz .col
    pop ecx
    inc edx
    dec ebx
    jnz .row
    popad
    ret

; gfx_tri: filled triangle. Points in tri_px[0..2]/tri_py[0..2], EAX = pixel.
; Scanline fill - simple, and fine for small shapes like the mouse cursor.
gfx_tri:
    pushad
    mov [tri_col], eax
    mov eax, [tri_py + 0]           ; min y
    cmp eax, [tri_py + 4]
    jle .a1
    mov eax, [tri_py + 4]
.a1:
    cmp eax, [tri_py + 8]
    jle .a2
    mov eax, [tri_py + 8]
.a2:
    test eax, eax
    jns .a3
    xor eax, eax
.a3:
    mov [tri_cury], eax
    mov ebx, [tri_py + 0]           ; max y
    cmp ebx, [tri_py + 4]
    jge .b1
    mov ebx, [tri_py + 4]
.b1:
    cmp ebx, [tri_py + 8]
    jge .b2
    mov ebx, [tri_py + 8]
.b2:
    mov eax, [gfx_h]
    dec eax
    cmp ebx, eax
    jle .b3
    mov ebx, eax
.b3:
    mov [tri_maxy], ebx
.scan:
    mov eax, [tri_cury]
    cmp eax, [tri_maxy]
    jg .done
    mov dword [tri_xmin], 0x7FFFFFFF
    mov dword [tri_xmax], 0x80000000
    xor esi, esi
    call tri_edge
    mov esi, 1
    call tri_edge
    mov esi, 2
    call tri_edge
    mov ecx, [tri_xmin]
    cmp ecx, [tri_xmax]
    jg .next
    mov edx, [tri_cury]
    mov esi, [tri_xmax]
    sub esi, ecx
    inc esi                         ; span width
    mov edi, 1
    mov eax, [tri_col]
    call gfx_fillrect
.next:
    inc dword [tri_cury]
    jmp .scan
.done:
    popad
    ret

; tri_edge: ESI = edge index i (edge from point i to point (i+1)%3). Updates
; tri_xmin/tri_xmax with where the edge crosses scanline tri_cury.
tri_edge:
    pushad
    mov eax, esi                    ; j = (i+1) % 3
    inc eax
    cmp eax, 3
    jb .jok
    xor eax, eax
.jok:
    mov ecx, [tri_px + esi * 4]     ; xa
    mov edx, [tri_py + esi * 4]     ; ya
    mov ebx, [tri_px + eax * 4]     ; xb
    mov ebp, [tri_py + eax * 4]     ; yb
    cmp edx, ebp                    ; ensure ya <= yb
    jle .ord
    xchg edx, ebp
    xchg ecx, ebx
.ord:
    mov edi, [tri_cury]
    cmp edi, edx
    jl .out
    cmp edi, ebp
    jg .out
    cmp edx, ebp                    ; horizontal edge?
    jne .slope
    mov eax, ecx                    ; include both endpoints
    call tri_upd
    mov eax, ebx
    call tri_upd
    jmp .out
.slope:
    ; x = xa + (xb-xa)*(y-ya)/(yb-ya)
    mov eax, ebx
    sub eax, ecx                    ; xb-xa
    mov esi, edi
    sub esi, edx                    ; y-ya
    imul eax, esi
    mov esi, ebp
    sub esi, edx                    ; yb-ya
    cdq
    idiv esi
    add eax, ecx
    call tri_upd
.out:
    popad
    ret

; tri_upd: EAX = x -> widen tri_xmin/tri_xmax
tri_upd:
    cmp eax, [tri_xmin]
    jge .nomin
    mov [tri_xmin], eax
.nomin:
    cmp eax, [tri_xmax]
    jle .nomax
    mov [tri_xmax], eax
.nomax:
    ret

section .bss
alignb 4
tri_px   resd 3
tri_py   resd 3
tri_col  resd 1
tri_cury resd 1
tri_maxy resd 1
tri_xmin resd 1
tri_xmax resd 1
section .text

; gfx_present: copy the back buffer to the real framebuffer
gfx_present:
    pushad
    cmp byte [gfx_ready], 0
    je .done
    mov esi, GUI_BB
    mov edi, [gfx_fb]
    mov ebx, [gfx_h]
    mov ecx, [gfx_w]                ; source row length (pixels)
    mov edx, [gfx_fbpitch]          ; dest stride (pixels)
.row:
    push ecx
    push esi
    push edi
    rep movsd
    pop edi
    pop esi
    pop ecx
    lea esi, [esi + ecx * 4]
    lea edi, [edi + edx * 4]
    dec ebx
    jnz .row
.done:
    popad
    ret

; gfx_clip: ECX = x, EDX = y, ESI = width, EDI = height -> the same rectangle
; cut to the screen; CF=1 if nothing of it is on screen
gfx_clip:
    test ecx, ecx
    jns .x
    add esi, ecx
    xor ecx, ecx
.x: test edx, edx
    jns .y
    add edi, edx
    xor edx, edx
.y: push eax
    mov eax, [gfx_w]
    sub eax, ecx                    ; room to the right
    cmp esi, eax
    jle .w
    mov esi, eax
.w: mov eax, [gfx_h]
    sub eax, edx                    ; room below
    cmp edi, eax
    jle .h
    mov edi, eax
.h: pop eax
    test esi, esi
    jle .none
    test edi, edi
    jle .none
    clc
    ret
.none:
    stc
    ret

; gfx_present_rect: copy one rectangle (ECX = x, EDX = y, ESI = width,
; EDI = height) of the back buffer to the screen. Much cheaper than
; gfx_present when only the mouse cursor moved.
gfx_present_rect:
    pushad
    cmp byte [gfx_ready], 0
    je .done
    call gfx_clip
    jc .done
    mov eax, edx                    ; destination: framebuffer row
    imul eax, [gfx_fbpitch]
    add eax, ecx
    shl eax, 2
    add eax, [gfx_fb]
    mov ebp, eax
    imul edx, [gfx_w]               ; source: back-buffer row
    add edx, ecx
    lea ebx, [GUI_BB + edx * 4]
.row:
    push esi
    push edi
    mov ecx, esi
    mov esi, ebx
    mov edi, ebp
    rep movsd
    pop edi
    pop esi
    mov eax, [gfx_w]
    lea ebx, [ebx + eax * 4]
    mov eax, [gfx_fbpitch]
    lea ebp, [ebp + eax * 4]
    dec edi
    jnz .row
.done:
    popad
    ret

; gfx_copy_rect: copy a rectangle (ECX, EDX, ESI, EDI as above) between the
; back buffer and a packed buffer at EBX. EAX = 0 saves (back buffer ->
; buffer), 1 restores (buffer -> back buffer). Used to put back what was
; under the mouse cursor.
gfx_copy_rect:
    pushad
    call gfx_clip
    jc .done
    imul edx, [gfx_w]
    add edx, ecx
    lea edx, [GUI_BB + edx * 4]     ; back-buffer row
.row:
    push esi
    push edi
    mov ecx, esi
    test eax, eax
    jnz .restore
    mov esi, edx
    mov edi, ebx
    rep movsd
    mov ebx, edi
    jmp .next
.restore:
    mov esi, ebx
    mov edi, edx
    rep movsd
    mov ebx, esi
.next:
    pop edi
    pop esi
    push eax
    mov eax, [gfx_w]
    lea edx, [edx + eax * 4]
    pop eax
    dec edi
    jnz .row
.done:
    popad
    ret
