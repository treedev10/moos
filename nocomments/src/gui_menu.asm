MN_MAX      equ 16
MN_ITEM_H   equ 24
MN_SEP_H    equ 9
MN_PAD      equ 4
MN_HEAD_H   equ 48
MN_MIN_W    equ 180
MN_SHADOW   equ 5
MI_SEPF     equ 1
MI_DIS      equ 2
MO_KEYS     equ 1

MB_OK       equ 1
MB_OKCANCEL equ 2
MB_W_MIN    equ 340
MB_BTN_W    equ 84
MB_BTN_H    equ 26

%macro MI 4
    [section .data]
    %%l: db %1, 0
    %ifstr %2
    %%h: db %2, 0
    %endif
    __SECT__
    dd %%l
    %ifstr %2
    dd %%h
    %else
    dd 0
    %endif
    dd %3, %4
%endmacro
%macro MI_SEP 0
    dd -1, 0, 0, MI_SEPF
%endmacro
%macro MI_END 0
    dd 0, 0, 0, 0
%endmacro
MI_LABEL    equ 0
MI_HINT     equ 4
MI_ACT      equ 8
MI_FLAGS    equ 12
MI_SIZE     equ 16

section .bss
alignb 4
mn_open     resd 1
mn_items    resb MN_MAX * MI_SIZE
mn_n        resd 1
mn_sel      resd 1
mn_x        resd 1
mn_y        resd 1
mn_w        resd 1
mn_h        resd 1
mn_head     resd 1
mn_hint_x   resd 1
mn_i        resd 1
mn_iy       resd 1
mn_hx       resd 1
mn_hy       resd 1
mb_open     resd 1
mb_buttons  resd 1
mb_sel      resd 1
mb_action   resd 1
mb_title    resd 1
mb_x        resd 1
mb_y        resd 1
mb_w        resd 1
mb_h        resd 1
mb_lines    resd 1
mb_ok_x     resd 1
mb_cancel_x resd 1
mb_btn_y    resd 1
mb_ly       resd 1
mb_text     resb 600
mb_line     resb 100

section .data
mn_moos     db "MOOS", 0
mb_ok_lbl   db "OK", 0
mb_cn_lbl   db "Cancel", 0

section .text

gm_shade:
    pushad
    call gfx_clip
    jc .done
    mov eax, [gfx_cx0]
    sub eax, ecx
    jle .x0
    sub esi, eax
    add ecx, eax
.x0:
    mov eax, [gfx_cy0]
    sub eax, edx
    jle .y0
    sub edi, eax
    add edx, eax
.y0:
    mov eax, [gfx_cx1]
    sub eax, ecx
    cmp esi, eax
    jle .x1
    mov esi, eax
.x1:
    mov eax, [gfx_cy1]
    sub eax, edx
    cmp edi, eax
    jle .y1
    mov edi, eax
.y1:
    test esi, esi
    jle .done
    test edi, edi
    jle .done
    mov eax, edx
    imul eax, [gfx_w]
    add eax, ecx
    lea ebx, [GUI_BB + eax * 4]
.row:
    mov ecx, esi
    mov edx, ebx
.px:
    mov eax, [edx]
    shr eax, 1
    and eax, 0x7F7F7F7F
    mov [edx], eax
    add edx, 4
    dec ecx
    jnz .px
    mov eax, [gfx_w]
    lea ebx, [ebx + eax * 4]
    dec edi
    jnz .row
.done:
    popad
    ret

menu_open:
    pushad
    mov [mn_head], ebx
    push eax
    push ecx
    push edx
    mov edi, mn_items
    xor ecx, ecx
.copy:
    cmp dword [esi + MI_LABEL], 0
    je .copied
    cmp ecx, MN_MAX
    jae .copied
    mov eax, [esi + MI_LABEL]
    mov [edi + MI_LABEL], eax
    mov eax, [esi + MI_HINT]
    mov [edi + MI_HINT], eax
    mov eax, [esi + MI_ACT]
    mov [edi + MI_ACT], eax
    mov eax, [esi + MI_FLAGS]
    mov [edi + MI_FLAGS], eax
    add esi, MI_SIZE
    add edi, MI_SIZE
    inc ecx
    jmp .copy
.copied:
    mov [mn_n], ecx
    call mn_measure
    pop edx
    pop ecx

    mov eax, ecx
    add eax, [mn_w]
    cmp eax, [gfx_w]
    jle .xok
    sub ecx, [mn_w]
    jns .xok
    xor ecx, ecx
.xok:
    mov [mn_x], ecx
    mov eax, edx
    add eax, [mn_h]
    mov ebx, [gfx_h]
    cmp eax, ebx
    jle .yok
    sub edx, [mn_h]
    jns .yok
    xor edx, edx
.yok:
    mov [mn_y], edx
    mov dword [mn_open], 1
    mov dword [mn_sel], -1
    mov dword [mn_start], 0
    call mn_note_mouse
    pop eax
    test eax, MO_KEYS
    jz .done
    mov eax, 1
    call mn_step_from_top
.done:
    or byte [gui_dirty], 1
    popad
    ret

mn_measure:
    pushad
    xor ebx, ebx
    xor edx, edx
    mov ebp, MN_PAD * 2
    cmp dword [mn_head], 0
    je .nohead
    add ebp, MN_HEAD_H
.nohead:
    xor edi, edi
.l: cmp edi, [mn_n]
    jae .sized
    mov eax, edi
    shl eax, 4
    test dword [mn_items + eax + MI_FLAGS], MI_SEPF
    jz .item
    add ebp, MN_SEP_H
    jmp .n
.item:
    add ebp, MN_ITEM_H
    mov esi, [mn_items + eax + MI_LABEL]
    call str_len
    cmp ecx, ebx
    jbe .h
    mov ebx, ecx
.h: mov esi, [mn_items + eax + MI_HINT]
    test esi, esi
    jz .n
    call str_len
    cmp ecx, edx
    jbe .n
    mov edx, ecx
.n: inc edi
    jmp .l
.sized:
    mov [mn_h], ebp
    lea eax, [ebx * 8 + 28]
    mov [mn_hint_x], eax
    test edx, edx
    jz .w
    add eax, 24
    lea eax, [eax + edx * 8]
.w: add eax, 12
    cmp eax, MN_MIN_W
    jge .wok
    mov eax, MN_MIN_W
.wok:
    cmp dword [mn_head], 0
    je .wset
    push esi
    mov esi, [mn_head]
    call str_len
    lea ecx, [ecx * 8 + 14 + 4 * 16 + 14 + 16]
    pop esi
    cmp eax, ecx
    jge .wset
    mov eax, ecx
.wset:
    mov [mn_w], eax
    test edx, edx
    jz .done
    shl edx, 3
    sub eax, edx
    sub eax, 14
    mov [mn_hint_x], eax
.done:
    popad
    ret

menu_set:
    pushad
    xor ecx, ecx
.l: cmp ecx, [mn_n]
    jae .done
    mov edx, ecx
    shl edx, 4
    cmp [mn_items + edx + MI_ACT], eax
    jne .n
    test dword [mn_items + edx + MI_FLAGS], MI_SEPF
    jnz .n
    or [mn_items + edx + MI_FLAGS], ebx
    test esi, esi
    jz .n
    mov [mn_items + edx + MI_HINT], esi
.n: inc ecx
    jmp .l
.done:
    call mn_measure
    mov eax, [mn_x]
    add eax, [mn_w]
    sub eax, [gfx_w]
    jle .r
    sub [mn_x], eax
.r: popad
    ret

mn_note_mouse:
    push eax
    mov eax, [mouse_x]
    mov [mn_hx], eax
    mov eax, [mouse_y]
    mov [mn_hy], eax
    pop eax
    ret

menu_close:
    cmp dword [mn_open], 0
    je .r
    mov dword [mn_open], 0
    or byte [gui_dirty], 1
.r: ret

mn_item_y:
    push eax
    push ebx
    mov edx, [mn_y]
    add edx, MN_PAD
    cmp dword [mn_head], 0
    je .start
    add edx, MN_HEAD_H
.start:
    xor ebx, ebx
.l: mov eax, ebx
    shl eax, 4
    mov edi, MN_ITEM_H
    test dword [mn_items + eax + MI_FLAGS], MI_SEPF
    jz .h
    mov edi, MN_SEP_H
.h: cmp ebx, ecx
    je .done
    add edx, edi
    inc ebx
    jmp .l
.done:
    pop ebx
    pop eax
    ret

mn_at:
    push ecx
    push edx
    push edi
    mov eax, [mouse_x]
    sub eax, [mn_x]
    jl .out
    cmp eax, [mn_w]
    jge .out
    mov eax, [mouse_y]
    sub eax, [mn_y]
    jl .out
    cmp eax, [mn_h]
    jge .out
    xor ecx, ecx
.l: cmp ecx, [mn_n]
    jae .none
    call mn_item_y
    mov eax, [mouse_y]
    cmp eax, edx
    jl .n
    add edx, edi
    cmp eax, edx
    jge .n
    mov eax, ecx
    shl eax, 4
    test dword [mn_items + eax + MI_FLAGS], MI_SEPF | MI_DIS
    jnz .none
    mov eax, ecx
    jmp .in
.n: inc ecx
    jmp .l
.none:
    mov eax, -1
.in:
    clc
    jmp .r
.out:
    mov eax, -1
    stc
.r: pop edi
    pop edx
    pop ecx
    ret

menu_hover:
    push eax
    mov eax, [mouse_x]
    cmp eax, [mn_hx]
    jne .moved
    mov eax, [mouse_y]
    cmp eax, [mn_hy]
    je .r
.moved:
    call mn_note_mouse
    call mn_at
    jc .r
    cmp eax, [mn_sel]
    je .r
    mov [mn_sel], eax
    or byte [gui_dirty], 1
.r: pop eax
    ret

menu_press:
    pushad
    call mn_at
    jc .close
    test eax, eax
    js .done
    mov [mn_sel], eax
    call mn_choose
    jmp .done
.close:
    call menu_close
.done:
    popad
    ret

mn_choose:
    pushad
    mov eax, [mn_sel]
    test eax, eax
    js .done
    shl eax, 4
    mov eax, [mn_items + eax + MI_ACT]
    call menu_close
    call gui_action
.done:
    popad
    ret

mn_step_from_top:
    push eax
    mov dword [mn_sel], -1
    test eax, eax
    jns .go
    mov ecx, [mn_n]
    mov [mn_sel], ecx
.go:
    pop eax
    jmp mn_step

mn_step:
    pushad
    mov esi, [mn_n]
    test esi, esi
    jz .done
    mov ecx, esi
    mov edx, [mn_sel]
    cmp edx, -1
    jne .l
    test eax, eax
    jns .l
    mov edx, esi
.l: add edx, eax
    jns .lo
    lea edx, [esi - 1]
.lo:
    cmp edx, esi
    jb .hi
    xor edx, edx
.hi:
    mov ebx, edx
    shl ebx, 4
    test dword [mn_items + ebx + MI_FLAGS], MI_SEPF | MI_DIS
    jz .found
    dec ecx
    jnz .l
    jmp .done
.found:
    mov [mn_sel], edx
    or byte [gui_dirty], 1
.done:
    popad
    ret

menu_key:
    cmp eax, 27
    je menu_close
    cmp eax, KEY_UP
    je .up
    cmp eax, KEY_DOWN
    je .down
    cmp eax, KEY_HOME
    je .home
    cmp eax, KEY_END
    je .end
    cmp eax, 10
    je mn_choose
    cmp eax, ' '
    je mn_choose
    ret
.up:
    mov eax, -1
    jmp mn_step
.down:
    mov eax, 1
    jmp mn_step
.home:
    mov eax, 1
    jmp mn_step_from_top
.end:
    mov eax, -1
    jmp mn_step_from_top

menu_draw:
    pushad
    cmp dword [mn_open], 0
    je .done
    call gfx_clip_full
    mov dword [gfx_scale], 1
    mov ecx, [mn_x]
    add ecx, MN_SHADOW
    mov edx, [mn_y]
    add edx, MN_SHADOW
    mov esi, [mn_w]
    mov edi, [mn_h]
    call gm_shade
    RECT [mn_x], [mn_y], [mn_w], [mn_h], 0x5C6B7A
    mov ecx, [mn_x]
    inc ecx
    mov edx, [mn_y]
    inc edx
    mov esi, [mn_w]
    sub esi, 2
    mov edi, [mn_h]
    sub edi, 2
    RECT ecx, edx, esi, edi, 0x262D35
    cmp dword [mn_head], 0
    je .items
    mov ecx, [mn_x]
    inc ecx
    mov edx, [mn_y]
    inc edx
    mov esi, [mn_w]
    sub esi, 2
    RECT ecx, edx, esi, MN_HEAD_H - 1, 0x1F4E79
    mov ecx, [mn_x]
    add ecx, 14
    mov edx, [mn_y]
    add edx, 8
    mov dword [gfx_scale], 2
    TEXT ecx, edx, mn_moos, 0xFFFFFF, -1
    mov dword [gfx_scale], 1
    mov ecx, [mn_x]
    add ecx, 14 + 4 * 16 + 14
    mov edx, [mn_y]
    add edx, 18
    TEXT ecx, edx, [mn_head], 0xCFE3F5, -1
.items:
    mov dword [mn_i], 0
.item:
    mov ecx, [mn_i]
    cmp ecx, [mn_n]
    jae .done
    call mn_item_y
    mov [mn_iy], edx
    mov eax, ecx
    shl eax, 4
    test dword [mn_items + eax + MI_FLAGS], MI_SEPF
    jz .label
    mov ecx, [mn_x]
    add ecx, 10
    mov edx, [mn_iy]
    add edx, MN_SEP_H / 2
    mov esi, [mn_w]
    sub esi, 20
    RECT ecx, edx, esi, 1, 0x4A5562
    jmp .next
.label:
    mov ecx, [mn_i]
    cmp ecx, [mn_sel]
    jne .text
    mov ecx, [mn_x]
    add ecx, 3
    mov esi, [mn_w]
    sub esi, 6
    RECT ecx, [mn_iy], esi, MN_ITEM_H, 0x3D6A92
.text:
    mov eax, [mn_i]
    shl eax, 4
    mov ebx, 0xEEF2F6
    mov edi, 0x9FB0C0
    test dword [mn_items + eax + MI_FLAGS], MI_DIS
    jz .colour
    mov ebx, 0x6C7782
    mov edi, ebx
.colour:
    push edi
    push dword [mn_items + eax + MI_HINT]
    mov esi, [mn_items + eax + MI_LABEL]
    mov ecx, [mn_x]
    add ecx, 16
    mov edx, [mn_iy]
    add edx, (MN_ITEM_H - 16) / 2
    mov eax, ebx
    call gfx_rgb
    mov ebx, eax
    mov ebp, -1
    call gfx_text
    pop esi
    pop eax
    test esi, esi
    jz .next
    mov ecx, [mn_x]
    add ecx, [mn_hint_x]
    call gfx_rgb
    mov ebx, eax
    call gfx_text
.next:
    inc dword [mn_i]
    jmp .item
.done:
    popad
    ret

msgbox:
    pushad
    mov [mb_title], esi
    mov [mb_buttons], eax
    mov [mb_action], ebx
    mov esi, edi
    mov edi, mb_text
    mov ecx, 599
.copy:
    lodsb
    stosb
    test al, al
    jz .copied
    loop .copy
    mov byte [edi], 0
.copied:
    call mb_layout
    mov dword [mb_sel], 0
    mov dword [mb_open], 1
    call menu_close
    or byte [gui_dirty], 1
    popad
    ret

msgbox_out:
    push edi
    mov edi, [out_ptr]
    mov byte [edi], 0
    mov byte [out_mode], 0
    mov edi, OUTBUF
    call msgbox
    pop edi
    ret

mb_layout:
    pushad
    xor ebx, ebx
    xor edx, edx
    mov esi, mb_text
.line:
    xor ecx, ecx
.ch:
    lodsb
    test al, al
    jz .last
    cmp al, 10
    je .eol
    inc ecx
    jmp .ch
.eol:
    inc edx
    cmp ecx, ebx
    jbe .line
    mov ebx, ecx
    jmp .line
.last:
    test ecx, ecx
    jz .counted
    inc edx
    cmp ecx, ebx
    jbe .counted
    mov ebx, ecx
.counted:
    mov [mb_lines], edx
    lea eax, [ebx * 8 + 48]
    cmp eax, MB_W_MIN
    jge .w
    mov eax, MB_W_MIN
.w: mov ecx, [gfx_w]
    sub ecx, 16
    cmp eax, ecx
    jle .w2
    mov eax, ecx
.w2:
    mov [mb_w], eax
    imul edx, 18
    add edx, TITLE_H + 22 + MB_BTN_H + 18
    mov [mb_h], edx
    mov ecx, [gfx_w]
    sub ecx, eax
    sar ecx, 1
    mov [mb_x], ecx
    mov eax, [gfx_h]
    sub eax, TASKBAR_H
    sub eax, edx
    sar eax, 1
    jns .y
    xor eax, eax
.y: mov [mb_y], eax
    add eax, [mb_h]
    sub eax, MB_BTN_H + 14
    mov [mb_btn_y], eax
    mov eax, [mb_x]
    add eax, [mb_w]
    sub eax, MB_BTN_W + 16
    mov [mb_cancel_x], eax
    cmp dword [mb_buttons], MB_OKCANCEL
    jne .one
    sub eax, MB_BTN_W + 10
.one:
    mov [mb_ok_x], eax
    popad
    ret

mb_close:
    pushad
    mov dword [mb_open], 0
    jc .shut
    mov eax, [mb_action]
    or byte [gui_dirty], 1
    test eax, eax
    jz .done
    call gui_action
    jmp .done
.shut:
    or byte [gui_dirty], 1
.done:
    popad
    ret

mb_cancel:
    cmp dword [mb_buttons], MB_OKCANCEL
    je .c
    clc
    jmp mb_close
.c: stc
    jmp mb_close

mb_key:
    cmp eax, 27
    je mb_cancel
    cmp eax, 10
    je .enter
    cmp eax, ' '
    je .enter
    cmp eax, 9
    je .other
    cmp eax, KEY_LEFT
    je .other
    cmp eax, KEY_RIGHT
    je .other
    ret
.other:
    cmp dword [mb_buttons], MB_OKCANCEL
    jne .r
    xor dword [mb_sel], 1
    or byte [gui_dirty], 1
.r: ret
.enter:
    cmp dword [mb_sel], 0
    jne .c
    clc
    jmp mb_close
.c: stc
    jmp mb_close

mb_press:
    pushad
    mov eax, [mouse_y]
    sub eax, [mb_btn_y]
    jl .done
    cmp eax, MB_BTN_H
    jge .done
    mov eax, [mouse_x]
    sub eax, [mb_ok_x]
    jl .cancel
    cmp eax, MB_BTN_W
    jge .cancel
    clc
    call mb_close
    jmp .done
.cancel:
    cmp dword [mb_buttons], MB_OKCANCEL
    jne .done
    mov eax, [mouse_x]
    sub eax, [mb_cancel_x]
    jl .done
    cmp eax, MB_BTN_W
    jge .done
    stc
    call mb_close
.done:
    popad
    ret

mb_draw:
    pushad
    cmp dword [mb_open], 0
    je .done
    call gfx_clip_full
    mov dword [gfx_scale], 1
    mov ecx, [mb_x]
    add ecx, MN_SHADOW + 1
    mov edx, [mb_y]
    add edx, MN_SHADOW + 1
    mov esi, [mb_w]
    mov edi, [mb_h]
    call gm_shade
    RECT [mb_x], [mb_y], [mb_w], [mb_h], 0x7090B0
    mov ecx, [mb_x]
    inc ecx
    mov edx, [mb_y]
    inc edx
    mov esi, [mb_w]
    sub esi, 2
    RECT ecx, edx, esi, TITLE_H, 0x2C5A82
    mov ecx, [mb_x]
    inc ecx
    mov edx, [mb_y]
    add edx, TITLE_H + 1
    mov esi, [mb_w]
    sub esi, 2
    mov edi, [mb_h]
    sub edi, TITLE_H + 2
    RECT ecx, edx, esi, edi, 0x1E242B
    mov ecx, [mb_x]
    add ecx, 12
    mov edx, [mb_y]
    add edx, 7
    TEXT ecx, edx, [mb_title], 0xFFFFFF, -1
    mov ecx, [mb_x]
    add ecx, 2
    mov edx, [mb_y]
    mov esi, [mb_w]
    sub esi, 4
    mov edi, [mb_h]
    call gfx_clip_set
    mov eax, [mb_y]
    add eax, TITLE_H + 14
    mov [mb_ly], eax
    mov esi, mb_text
.line:
    mov edi, mb_line
    xor ecx, ecx
.ch:
    lodsb
    test al, al
    jz .end
    cmp al, 10
    je .end
    cmp ecx, 98
    jae .ch
    stosb
    inc ecx
    jmp .ch
.end:
    mov byte [edi], 0
    push eax
    push esi
    mov ecx, [mb_x]
    add ecx, 22
    TEXT ecx, [mb_ly], mb_line, 0xE6ECF2, -1
    pop esi
    pop eax
    add dword [mb_ly], 18
    test al, al
    jnz .line
    call gfx_clip_full
    mov eax, [mb_ok_x]
    mov esi, mb_ok_lbl
    xor ebx, ebx
    call mb_button
    cmp dword [mb_buttons], MB_OKCANCEL
    jne .done
    mov eax, [mb_cancel_x]
    mov esi, mb_cn_lbl
    mov ebx, 1
    call mb_button
.done:
    popad
    ret

mb_button:
    pushad
    mov [mb_ly], eax
    push esi
    mov eax, 0x3A4652
    cmp ebx, [mb_sel]
    jne .bg
    mov eax, 0x3D6A92
.bg:
    push ebx
    RECT [mb_ly], [mb_btn_y], MB_BTN_W, MB_BTN_H, eax
    pop ebx
    cmp ebx, [mb_sel]
    jne .label
    mov ecx, [mb_ly]
    mov edx, [mb_btn_y]
    mov esi, MB_BTN_W
    mov edi, MB_BTN_H
    mov eax, 0xDDEBF7
    call gfx_rgb
    call gfx_frame
.label:
    pop esi
    call str_len
    shl ecx, 2
    neg ecx
    add ecx, MB_BTN_W / 2
    add ecx, [mb_ly]
    mov edx, [mb_btn_y]
    add edx, (MB_BTN_H - 16) / 2
    TEXT ecx, edx, esi, 0xFFFFFF, -1
    popad
    ret
