section .bss
alignb 4
gfx_w       resd 1
gfx_h       resd 1
gfx_fb      resd 1
gfx_fbpitch resd 1
gfx_ready   resb 1

section .text

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
    pop eax
    clc
    ret
.no:
    mov byte [gfx_ready], 0
    pop eax
    stc
    ret

gfx_rgb:
    push ebx
    push ecx
    push edx
    movzx ebx, al
    mov ecx, eax
    shr ecx, 8
    movzx ecx, cl
    mov edx, eax
    shr edx, 16
    movzx edx, dl
    mov eax, [bootinfo + BI.fb_format]
    cmp eax, 1
    je .bgr
    cmp eax, 2
    je .mask

    mov eax, edx
    shl ecx, 8
    shl ebx, 16
    or eax, ecx
    or eax, ebx
    jmp .done
.bgr:
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
    mov eax, [esp]
    shl eax, cl
    and eax, edx
    mov edx, [esp]
    pop edx

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

gfx_fillrect:
    pushad
    mov ebp, eax

    test ecx, ecx
    jns .x_ok
    add esi, ecx
    xor ecx, ecx
.x_ok:
    test edx, edx
    jns .y_ok
    add edi, edx
    xor edx, edx
.y_ok:
    mov eax, ecx
    add eax, esi
    cmp eax, [gfx_w]
    jle .w_ok
    mov esi, [gfx_w]
    sub esi, ecx
.w_ok:
    mov eax, edx
    add eax, edi
    cmp eax, [gfx_h]
    jle .h_ok
    mov edi, [gfx_h]
    sub edi, edx
.h_ok:
    test esi, esi
    jle .done
    test edi, edi
    jle .done
    mov eax, edx
    imul eax, [gfx_w]
    add eax, ecx
    lea eax, [GUI_BB + eax * 4]
    mov ecx, [gfx_w]
    shl ecx, 2
.row:
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

gfx_pixel:
    cmp ecx, 0
    jl .no
    cmp ecx, [gfx_w]
    jge .no
    cmp edx, 0
    jl .no
    cmp edx, [gfx_h]
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
gfx_scale   resd 1
section .text

gfx_char:
    pushad
    movzx eax, al
    shl eax, 4
    add eax, font_8x16
    mov [gc_glyph], eax
    mov [gc_x0], ecx
    mov dword [gc_row], 0
.row:
    mov eax, [gc_glyph]
    movzx eax, byte [eax]
    inc dword [gc_glyph]
    mov [gc_bits], eax
    mov dword [gc_sy], 0
.vrep:
    mov ecx, [gc_x0]
    mov dword [gc_bit], 0x80
.col:
    mov eax, [gc_bits]
    test eax, [gc_bit]
    jnz .fg
    cmp ebp, -1
    je .skip
    mov eax, ebp
    jmp .put
.fg:
    mov eax, ebx
.put:
    mov dword [gc_sx], 0
.hrep:
    call gfx_pixel
    inc ecx
    inc dword [gc_sx]
    mov esi, [gc_sx]
    cmp esi, [gfx_scale]
    jb .hrep
    jmp .nextbit
.skip:
    mov eax, [gfx_scale]
    add ecx, eax
.nextbit:
    shr dword [gc_bit], 1
    jnz .col
    inc edx
    inc dword [gc_sy]
    mov esi, [gc_sy]
    cmp esi, [gfx_scale]
    jb .vrep
    inc dword [gc_row]
    cmp dword [gc_row], 16
    jb .row
    popad
    ret

section .bss
alignb 4
gc_glyph resd 1
gc_x0    resd 1
gc_row   resd 1
gc_bits  resd 1
gc_bit   resd 1
gc_sx    resd 1
gc_sy    resd 1
section .text

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

gfx_tri:
    pushad
    mov [tri_col], eax
    mov eax, [tri_py + 0]
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
    mov ebx, [tri_py + 0]
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
    inc esi
    mov edi, 1
    mov eax, [tri_col]
    call gfx_fillrect
.next:
    inc dword [tri_cury]
    jmp .scan
.done:
    popad
    ret

tri_edge:
    pushad
    mov eax, esi
    inc eax
    cmp eax, 3
    jb .jok
    xor eax, eax
.jok:
    mov ecx, [tri_px + esi * 4]
    mov edx, [tri_py + esi * 4]
    mov ebx, [tri_px + eax * 4]
    mov ebp, [tri_py + eax * 4]
    cmp edx, ebp
    jle .ord
    xchg edx, ebp
    xchg ecx, ebx
.ord:
    mov edi, [tri_cury]
    cmp edi, edx
    jl .out
    cmp edi, ebp
    jg .out
    cmp edx, ebp
    jne .slope
    mov eax, ecx
    call tri_upd
    mov eax, ebx
    call tri_upd
    jmp .out
.slope:

    mov eax, ebx
    sub eax, ecx
    mov esi, edi
    sub esi, edx
    imul eax, esi
    mov esi, ebp
    sub esi, edx
    cdq
    idiv esi
    add eax, ecx
    call tri_upd
.out:
    popad
    ret

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

gfx_present:
    pushad
    cmp byte [gfx_ready], 0
    je .done
    mov esi, GUI_BB
    mov edi, [gfx_fb]
    mov ebx, [gfx_h]
    mov ecx, [gfx_w]
    mov edx, [gfx_fbpitch]
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
    sub eax, ecx
    cmp esi, eax
    jle .w
    mov esi, eax
.w: mov eax, [gfx_h]
    sub eax, edx
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

gfx_present_rect:
    pushad
    cmp byte [gfx_ready], 0
    je .done
    call gfx_clip
    jc .done
    mov eax, edx
    imul eax, [gfx_fbpitch]
    add eax, ecx
    shl eax, 2
    add eax, [gfx_fb]
    mov ebp, eax
    imul edx, [gfx_w]
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

gfx_copy_rect:
    pushad
    call gfx_clip
    jc .done
    imul edx, [gfx_w]
    add edx, ecx
    lea edx, [GUI_BB + edx * 4]
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
