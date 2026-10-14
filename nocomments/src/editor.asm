ED_BUF        equ SCRATCH
ED_CLIP       equ SCRATCH + 0x2000
ED_CLIP_MAX   equ 0x4000
ED_MAX        equ FS_SLOT_SIZE
ED_FIRST_ROW  equ 1
ED_ROWS       equ TEXT_ROWS - 2
ED_BAR_ROW    equ TEXT_ROWS - 1
ED_TITLE_ATTR equ 0x1F
ED_BAR_ATTR   equ 0x70
ED_MSG_ATTR   equ 0x1E

section .bss
alignb 4
ed_len      resd 1
ed_pos      resd 1
ed_top      resd 1
ed_left     resd 1
ed_want     resd 1
ed_line     resd 1
ed_col      resd 1
ed_lines    resd 1
ed_clip_len resd 1
ed_modified resb 1
ed_saved    resb 1
ed_msg_on   resb 1
ed_cutting  resb 1
ed_quit     resb 1
ed_name     resb 128
ed_msgbuf   resb SCR_COLS + 2
ed_find     resb 80

section .data
u_edit          db "edit <file>", 0
ed_help_text    db " ^S Save  ^Q Quit  ^F Find  ^N Next  ^G Go to line  ^K Cut line  ^U Paste", 0
ed_quit_text    db " Save your changes?   Y = save and quit   N = quit without saving   Esc = stay", 0
ed_find_prompt  db "Find: ", 0
ed_goto_prompt  db "Go to line: ", 0
ed_mod_yes      db " [modified]", 0
ed_mod_no       db "", 0
ed_from_top     db " (searched again from the top)", 0

section .text

cmd_edit:
    mov ecx, 1
    mov esi, u_edit
    call need_args
    jc .ret
    mov esi, [argv + 4]
    call check_new_file
    jc .ret
    mov edi, ed_name
    call str_copy
    xor ecx, ecx
    call fs_find
    jc .start
    mov ecx, [edi + DE_SIZE]
    push esi
    call fs_slot
    mov edi, ED_BUF
    call mem_copy
    pop esi
.start:
    mov [ed_len], ecx
    xor eax, eax
    mov [ed_pos], eax
    mov [ed_top], eax
    mov [ed_left], eax
    mov [ed_want], eax
    mov [ed_modified], al
    mov [ed_saved], al
    mov [ed_cutting], al
    mov [ed_quit], al
    call out_begin
    test ecx, ecx
    jnz .opened
    PRINTF `New file %s - start typing.  Ctrl+S saves, Esc quits, man edit helps.`, ed_name
    jmp .msg
.opened:
    PRINTF `Opened %s (%d bytes).  Ctrl+S saves, Esc quits, man edit helps.`, ed_name, ecx
.msg:
    call ed_take_msg

.loop:
    call ed_locate
    call ed_scroll
    call ed_draw
    call kbd_getkey
    mov byte [ed_msg_on], 0
    mov bl, [ed_cutting]
    mov byte [ed_cutting], 0
    call ed_key
    cmp byte [ed_quit], 0
    je .loop

    call vga_clear
    cmp byte [ed_quit], 2
    je .discarded
    cmp byte [ed_saved], 0
    je .unchanged
    PRINTF `Saved and closed \x01w%s\x01n (%d bytes).\n`, ed_name, dword [ed_len]
.ret:
    ret
.unchanged:
    PRINTF `Closed %s - nothing was changed.\n`, ed_name
    ret
.discarded:
    PRINTF `Closed %s - \x01yyour latest changes were not saved.\x01n\n`, ed_name
    ret

ed_key:
    cmp eax, 19
    je ed_save
    cmp eax, 17
    je ed_try_quit
    cmp eax, 24
    je ed_try_quit
    cmp eax, 27
    je ed_try_quit
    cmp eax, 6
    je ed_cmd_find
    cmp eax, 14
    je ed_find_next
    cmp eax, 7
    je ed_goto
    cmp eax, 11
    je ed_cut
    cmp eax, 21
    je ed_paste
    cmp eax, KEY_LEFT
    je ed_k_left
    cmp eax, KEY_RIGHT
    je ed_k_right
    cmp eax, KEY_UP
    je ed_k_up
    cmp eax, KEY_DOWN
    je ed_k_down
    cmp eax, KEY_HOME
    je ed_k_home
    cmp eax, 1
    je ed_k_home
    cmp eax, KEY_END
    je ed_k_end
    cmp eax, 5
    je ed_k_end
    cmp eax, KEY_PGUP
    je ed_k_pgup
    cmp eax, KEY_PGDN
    je ed_k_pgdn
    cmp eax, 8
    je ed_k_backspace
    cmp eax, KEY_DEL
    je ed_k_delete
    cmp eax, 10
    je ed_k_char
    cmp eax, 9
    je ed_k_tab
    cmp eax, ' '
    jb .ignore
    cmp eax, '~'
    jbe ed_k_char
.ignore:
    ret

ed_line_start:
    test eax, eax
    jz .r
    cmp byte [ED_BUF + eax - 1], 10
    je .r
    dec eax
    jmp ed_line_start
.r: ret

ed_line_end:
    cmp eax, [ed_len]
    jae .r
    cmp byte [ED_BUF + eax], 10
    je .r
    inc eax
    jmp ed_line_end
.r: ret

ed_set_want:
    push eax
    mov eax, [ed_pos]
    call ed_line_start
    neg eax
    add eax, [ed_pos]
    mov [ed_want], eax
    pop eax
    ret

ed_goto_col:
    push edx
    mov edx, eax
    add edx, [ed_want]
    call ed_line_end
    cmp edx, eax
    jbe .ok
    mov edx, eax
.ok:
    mov [ed_pos], edx
    pop edx
    ret

ed_locate:
    pushad
    xor ebx, ebx
    xor edx, edx
    xor ecx, ecx
    mov edi, [ed_pos]
.l: cmp ecx, edi
    jne .not_here
    mov [ed_line], ebx
    mov eax, ecx
    sub eax, edx
    mov [ed_col], eax
.not_here:
    cmp ecx, [ed_len]
    jae .done
    cmp byte [ED_BUF + ecx], 10
    jne .next
    inc ebx
    lea edx, [ecx + 1]
.next:
    inc ecx
    jmp .l
.done:
    inc ebx
    mov [ed_lines], ebx
    popad
    ret

ed_scroll:
    mov eax, [ed_line]
    cmp eax, [ed_top]
    jae .not_above
    mov [ed_top], eax
.not_above:
    mov edx, [ed_top]
    add edx, ED_ROWS
    cmp eax, edx
    jb .vertical_ok
    sub eax, ED_ROWS - 1
    mov [ed_top], eax
.vertical_ok:
    mov eax, [ed_col]
    cmp eax, [ed_left]
    jae .not_left
    sub eax, 20
    jns .set_left
    xor eax, eax
.set_left:
    mov [ed_left], eax
    ret
.not_left:
    mov edx, [ed_left]
    add edx, SCR_COLS - 1
    cmp eax, edx
    jb .done
    sub eax, SCR_COLS - 20
    mov [ed_left], eax
.done:
    ret

text_to_row:
    pushad
    imul edi, eax, SCR_COLS * 2
    add edi, VGA_MEM
    mov ecx, SCR_COLS
    mov ah, bl
.l: lodsb
    test al, al
    jz .pad
    stosw
    loop .l
    jmp .done
.pad:
    mov al, ' '
    rep stosw
.done:
    popad
    ret

ed_take_msg:
    pushad
    mov edi, [out_ptr]
    mov byte [edi], 0
    mov byte [out_mode], 0
    mov esi, OUTBUF
    mov edi, ed_msgbuf
    mov ecx, SCR_COLS
.l: lodsb
    stosb
    test al, al
    jz .done
    loop .l
    mov byte [edi], 0
.done:
    mov byte [ed_msg_on], 1
    popad
    ret

ed_draw:
    pushad
    mov edx, ed_mod_no
    cmp byte [ed_modified], 0
    je .title
    mov edx, ed_mod_yes
.title:
    mov eax, [ed_line]
    inc eax
    mov ecx, [ed_col]
    inc ecx
    call out_begin
    PRINTF ` MOOS Editor \xB3 %s%s \xB3 Line %d/%d, Col %d \xB3 %d/4096 bytes`, ed_name, edx, eax, dword [ed_lines], ecx, dword [ed_len]
    mov edi, [out_ptr]
    mov byte [edi], 0
    mov byte [out_mode], 0
    mov esi, OUTBUF
    xor eax, eax
    mov bl, ED_TITLE_ATTR
    call text_to_row

    xor esi, esi
    mov ecx, [ed_top]
.skip:
    jecxz .shown
.skip_ch:
    cmp esi, [ed_len]
    jae .shown
    inc esi
    cmp byte [ED_BUF + esi - 1], 10
    jne .skip_ch
    dec ecx
    jmp .skip
.shown:
    mov ebp, 1
    mov edx, ED_FIRST_ROW
.row:
    imul edi, edx, SCR_COLS * 2
    add edi, VGA_MEM
    push edi
    mov ecx, SCR_COLS
    mov ah, [text_attr]
    mov al, ' '
    rep stosw
    pop edi
    test ebp, ebp
    jz .next_row
    xor ebx, ebx
.ch:
    cmp esi, [ed_len]
    jae .eof
    mov al, [ED_BUF + esi]
    inc esi
    cmp al, 10
    je .next_row
    mov ecx, ebx
    sub ecx, [ed_left]
    jb .hidden
    cmp ecx, SCR_COLS
    jae .right
    cmp al, ' '
    jae .put
    mov al, ' '
.put:
    mov [edi + ecx * 2], al
    jmp .hidden
.right:
    mov byte [edi + (SCR_COLS - 1) * 2], 0xAF
.hidden:
    inc ebx
    jmp .ch
.eof:
    xor ebp, ebp
.next_row:
    inc edx
    cmp edx, ED_FIRST_ROW + ED_ROWS
    jb .row

    mov esi, ed_help_text
    mov bl, ED_BAR_ATTR
    cmp byte [ed_msg_on], 0
    je .bar
    mov esi, ed_msgbuf
    mov bl, ED_MSG_ATTR
.bar:
    mov eax, ED_BAR_ROW
    call text_to_row

    mov eax, [ed_col]
    sub eax, [ed_left]
    mov [cur_x], eax
    mov eax, [ed_line]
    sub eax, [ed_top]
    add eax, ED_FIRST_ROW
    mov [cur_y], eax
    call vga_update_cursor
    popad
    ret

ed_k_left:
    cmp dword [ed_pos], 0
    je ed_set_want
    dec dword [ed_pos]
    jmp ed_set_want

ed_k_right:
    mov eax, [ed_pos]
    cmp eax, [ed_len]
    jae ed_set_want
    inc dword [ed_pos]
    jmp ed_set_want

ed_k_home:
    mov eax, [ed_pos]
    call ed_line_start
    mov [ed_pos], eax
    jmp ed_set_want

ed_k_end:
    mov eax, [ed_pos]
    call ed_line_end
    mov [ed_pos], eax
    jmp ed_set_want

ed_k_up:
    mov eax, [ed_pos]
    call ed_line_start
    test eax, eax
    jz .r
    dec eax
    call ed_line_start
    jmp ed_goto_col
.r: ret

ed_k_down:
    mov eax, [ed_pos]
    call ed_line_end
    cmp eax, [ed_len]
    jae .r
    inc eax
    jmp ed_goto_col
.r: ret

ed_k_pgup:
    mov ecx, ED_ROWS - 1
.l: call ed_k_up
    loop .l
    ret

ed_k_pgdn:
    mov ecx, ED_ROWS - 1
.l: call ed_k_down
    loop .l
    ret

ed_insert:
    pushad
    mov ecx, [ed_len]
    cmp ecx, ED_MAX
    jae .full
    lea esi, [ED_BUF + ecx - 1]
    lea edi, [ED_BUF + ecx]
    sub ecx, [ed_pos]
    std
    rep movsb
    cld
    mov ecx, [ed_pos]
    mov [ED_BUF + ecx], al
    inc dword [ed_pos]
    inc dword [ed_len]
    mov byte [ed_modified], 1
    popad
    clc
    ret
.full:
    call out_begin
    PRINTF `The file is full - a file can hold at most 4096 bytes.`
    call ed_take_msg
    popad
    stc
    ret

ed_remove:
    pushad
    lea edi, [ED_BUF + eax]
    lea esi, [edi + ecx]
    mov edx, [ed_len]
    sub edx, eax
    sub edx, ecx
    sub [ed_len], ecx
    mov ecx, edx
    rep movsb
    mov byte [ed_modified], 1
    popad
    ret

ed_k_char:
    call ed_insert
    jmp ed_set_want

ed_k_tab:
    mov al, ' '
    call ed_insert
    jc ed_set_want
    call ed_set_want
    test dword [ed_want], 3
    jnz ed_k_tab
    ret

ed_k_backspace:
    mov eax, [ed_pos]
    test eax, eax
    jz ed_set_want
    dec eax
    mov [ed_pos], eax
    mov ecx, 1
    call ed_remove
    jmp ed_set_want

ed_k_delete:
    mov eax, [ed_pos]
    cmp eax, [ed_len]
    jae ed_set_want
    mov ecx, 1
    call ed_remove
    jmp ed_set_want

ed_cut:
    test bl, bl
    jnz .collect
    mov dword [ed_clip_len], 0
.collect:
    mov byte [ed_cutting], 1
    mov eax, [ed_pos]
    call ed_line_start
    mov ebx, eax
    call ed_line_end
    mov ecx, eax
    sub ecx, ebx
    cmp eax, [ed_len]
    jae .no_newline
    inc ecx
.no_newline:
    test ecx, ecx
    jz .nothing
    mov eax, [ed_clip_len]
    add eax, ecx
    cmp eax, ED_CLIP_MAX - 1
    ja .nothing
    lea esi, [ED_BUF + ebx]
    mov edi, [ed_clip_len]
    add edi, ED_CLIP
    push ecx
    rep movsb
    pop ecx
    mov [ed_clip_len], eax
    cmp byte [edi - 1], 10
    je .remove
    mov byte [edi], 10
    inc dword [ed_clip_len]
.remove:
    mov eax, ebx
    call ed_remove
    mov [ed_pos], ebx
    call ed_set_want
    call ed_clip_lines
    call out_begin
    PRINTF `%d line(s) cut. Move to where they should go and press Ctrl+U to paste.`, eax
    call ed_take_msg
    ret
.nothing:
    call out_begin
    PRINTF `Nothing to cut here - this line is empty and it is the last one.`
    call ed_take_msg
    ret

ed_clip_lines:
    push ecx
    push esi
    xor eax, eax
    mov ecx, [ed_clip_len]
    mov esi, ED_CLIP
    jecxz .done
.l: cmp byte [esi], 10
    jne .n
    inc eax
.n: inc esi
    loop .l
.done:
    pop esi
    pop ecx
    ret

ed_paste:
    mov ecx, [ed_clip_len]
    test ecx, ecx
    jz .empty
    mov eax, [ed_len]
    add eax, ecx
    cmp eax, ED_MAX
    ja .full
    mov eax, [ed_pos]
    call ed_line_start
    mov ebx, eax
    mov edx, [ed_len]
    lea esi, [ED_BUF + edx - 1]
    lea edi, [esi + ecx]
    push ecx
    mov ecx, edx
    sub ecx, ebx
    std
    rep movsb
    cld
    pop ecx
    lea edi, [ED_BUF + ebx]
    mov esi, ED_CLIP
    push ecx
    rep movsb
    pop ecx
    add [ed_len], ecx
    add ebx, ecx
    mov [ed_pos], ebx
    mov byte [ed_modified], 1
    jmp ed_set_want
.empty:
    call out_begin
    PRINTF `The clipboard is empty - first cut a line with Ctrl+K.`
    call ed_take_msg
    ret
.full:
    call out_begin
    PRINTF `Not enough room - the file would be bigger than 4096 bytes.`
    call ed_take_msg
    ret

ed_prompt:
    pushad
    mov eax, ED_BAR_ROW
    mov bl, [text_attr]
    push esi
    mov esi, ed_mod_no
    call text_to_row
    pop esi
    mov dword [cur_x], 0
    mov dword [cur_y], ED_BAR_ROW
    mov bl, C_HEADING
    xor bh, bh
    call readline
    test eax, eax
    jnz .cancel
    cmp dword [line_len], 0
    je .cancel
    popad
    clc
    ret
.cancel:
    popad
    stc
    ret

ed_save:
    mov esi, ed_name
    mov edx, ED_BUF
    mov ecx, [ed_len]
    call fs_save
    jc .error
    mov byte [ed_modified], 0
    mov byte [ed_saved], 1
    call out_begin
    PRINTF `Saved %s (%d bytes).`, esi, ecx
    call ed_take_msg
    clc
    ret
.error:
    call out_begin
    PRINTF `Could not save: %s`, esi
    call ed_take_msg
    stc
    ret

ed_try_quit:
    cmp byte [ed_modified], 0
    jne .ask
    mov byte [ed_quit], 1
    ret
.ask:
    mov esi, ed_quit_text
    mov eax, ED_BAR_ROW
    mov bl, ED_MSG_ATTR
    call text_to_row
.key:
    call kbd_getkey
    cmp eax, 'y'
    je .save
    cmp eax, 'Y'
    je .save
    cmp eax, 'n'
    je .discard
    cmp eax, 'N'
    je .discard
    cmp eax, 27
    je .stay
    cmp eax, 3
    je .stay
    jmp .key
.save:
    call ed_save
    jc .stay
    mov byte [ed_quit], 1
    ret
.discard:
    mov byte [ed_quit], 2
.stay:
    ret

ed_cmd_find:
    mov esi, ed_find_prompt
    call ed_prompt
    jc .r
    mov esi, line_buf
    mov edi, ed_find
    call str_copy
    jmp ed_find_next
.r: ret

ed_find_next:
    cmp byte [ed_find], 0
    jne .go
    call out_begin
    PRINTF `Nothing to search for yet - press Ctrl+F first.`
    call ed_take_msg
    ret
.go:
    mov esi, ed_find
    call str_len
    mov edx, ecx
    mov eax, [ed_pos]
    inc eax
    xor ebx, ebx
.scan:
    lea ecx, [eax + edx]
    cmp ecx, [ed_len]
    ja .wrap
    call ed_match_at
    je .found
    inc eax
    jmp .scan
.wrap:
    test ebx, ebx
    jnz .missing
    inc ebx
    xor eax, eax
    jmp .scan
.found:
    mov [ed_pos], eax
    call ed_set_want
    mov ecx, ed_mod_no
    test ebx, ebx
    jz .say
    mov ecx, ed_from_top
.say:
    call out_begin
    PRINTF `Found "%s"%s.  Ctrl+N finds the next one.`, ed_find, ecx
    call ed_take_msg
    ret
.missing:
    call out_begin
    PRINTF `"%s" was not found.`, ed_find
    call ed_take_msg
    ret

ed_match_at:
    push eax
    push ecx
    push esi
    push edi
    lea esi, [ED_BUF + eax]
    mov edi, ed_find
    mov ecx, edx
.l: mov al, [esi]
    call to_lower
    mov ah, al
    mov al, [edi]
    call to_lower
    cmp al, ah
    jne .out
    inc esi
    inc edi
    loop .l
    cmp eax, eax
.out:
    pop edi
    pop esi
    pop ecx
    pop eax
    ret

ed_goto:
    mov esi, ed_goto_prompt
    call ed_prompt
    jc .r
    mov esi, line_buf
    call skip_spaces
    call parse_uint
    jc .bad
    test eax, eax
    jz .bad
    lea ecx, [eax - 1]
    xor ebx, ebx
.l: jecxz .at
    mov eax, ebx
    call ed_line_end
    cmp eax, [ed_len]
    jae .at
    lea ebx, [eax + 1]
    dec ecx
    jmp .l
.at:
    mov [ed_pos], ebx
    jmp ed_set_want
.bad:
    call out_begin
    PRINTF `Please type a line number (1 or more).`
    call ed_take_msg
.r: ret
