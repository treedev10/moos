GUI_LOG     equ 16384
APP_BUF     equ 4096

section .bss
alignb 4
gui_capture resb 1
term_esc    resb 1
alignb 4
term_log    resb GUI_LOG
term_log_len resd 1
term_input  resb 160
term_input_len resd 1
app_buf     resb APP_BUF
app_buf_len resd 1
app_file    resb 24
app_dirty   resb 1
brow_url    resb 160
brow_url_len resd 1
ta_x        resd 1
ta_y        resd 1
ta_cols     resd 1
ta_rows     resd 1
ta_fg       resd 1

section .data
term_welcome db "MOOS terminal - type a command and press Enter.", 10
             db "Commands that take over the screen (edit, write, gui) are", 10
             db "not available here; use ls, cat, calc, net, apt, time...", 10, 10, 0
term_prompt  db "moos> ", 0
ide_file     db "script.ms", 0
edit_file    db "notes.txt", 0
ide_hint     db "Ctrl+R = Run     Ctrl+S = Save", 0
edit_hint    db "Ctrl+S = Save", 0
brow_hint    db "Type a URL and press Enter:  http://10.0.2.2:8000/hi.txt", 0
bl_edit      db "edit", 0
bl_write     db "write", 0
bl_append    db "append", 0
bl_gui       db "gui", 0
bl_format    db "format", 0
bl_run_blk   db "(that command needs the full screen - run it from the text console)", 10, 0

section .text

gui_log_char:
    cmp byte [term_esc], 0
    je .not_esc
    mov byte [term_esc], 0
    ret
.not_esc:
    cmp al, 1
    jne .store
    mov byte [term_esc], 1
    ret
.store:
    cmp al, 13
    je .skip
    push edi
    mov edi, [term_log_len]
    cmp edi, GUI_LOG - 1
    jb .room
    call term_log_scroll
    mov edi, [term_log_len]
.room:
    mov [term_log + edi], al
    inc dword [term_log_len]
    pop edi
.skip:
    ret

term_log_scroll:
    pushad
    mov esi, term_log + GUI_LOG / 4
    mov edi, term_log
    mov ecx, GUI_LOG - GUI_LOG / 4
    rep movsb
    sub dword [term_log_len], GUI_LOG / 4
    popad
    ret

term_log_str:
    push eax
    push esi
.l: mov al, [esi]
    test al, al
    jz .e
    call gui_log_char
    inc esi
    jmp .l
.e: pop esi
    pop eax
    ret

term_init:
    mov dword [term_log_len], 0
    mov dword [term_input_len], 0
    mov byte [term_input], 0
    mov esi, term_welcome
    call term_log_str
    ret

app_term_draw:
    pushad
    call gui_content_box
    mov dword [ta_fg], 0xCDE0C0

    mov ecx, [ta_rows]
    dec ecx
    mov edx, [term_log_len]
    mov esi, term_log
    add esi, edx
    mov ebx, ecx
.back:
    cmp esi, term_log
    jbe .start
    cmp byte [esi - 1], 10
    jne .dec
    dec ebx
    js .start
.dec:
    dec esi
    jmp .back
.start:
    mov byte [term_log + edx], 0
    call gui_textarea_from

    mov ecx, [ta_x]
    mov edx, eax
    imul edx, 16
    add edx, [ta_y]
    mov esi, term_prompt
    mov ebx, 0xFFFFFF
    push edx
    call gfx_rgb
    mov ebx, eax
    mov ebp, -1
    pop edx
    call gfx_text
    add ecx, 8 * 6
    mov esi, term_input
    call gfx_text
    popad
    ret

term_key:
    cmp eax, 10
    je .enter
    cmp eax, 8
    je .back
    cmp eax, ' '
    jb .r
    cmp eax, '~'
    ja .r
    mov ecx, [term_input_len]
    cmp ecx, 150
    jae .r
    mov [term_input + ecx], al
    inc dword [term_input_len]
    mov byte [term_input + ecx + 1], 0
.r:
    ret
.back:
    mov ecx, [term_input_len]
    test ecx, ecx
    jz .r
    dec ecx
    mov [term_input_len], ecx
    mov byte [term_input + ecx], 0
    ret
.enter:
    mov esi, term_prompt
    call term_log_str
    mov esi, term_input
    call term_log_str
    mov al, 10
    call gui_log_char
    call term_run
    mov dword [term_input_len], 0
    mov byte [term_input], 0
    ret

term_run:
    pushad
    mov esi, term_input
    call skip_spaces
    cmp byte [esi], 0
    je .done

    mov edi, bl_edit
    call term_firstword_is
    je .blocked
    mov edi, bl_write
    call term_firstword_is
    je .blocked
    mov edi, bl_append
    call term_firstword_is
    je .blocked
    mov edi, bl_gui
    call term_firstword_is
    je .blocked
    mov edi, bl_format
    call term_firstword_is
    je .blocked

    mov esi, term_input
    mov edi, line_buf
    call str_copy
    mov esi, term_input
    call str_len
    mov [line_len], ecx
    mov byte [gui_capture], 1
    call shell_exec
    mov byte [gui_capture], 0
.done:
    popad
    ret
.blocked:
    mov byte [gui_capture], 1
    mov esi, bl_run_blk
    call term_log_str
    mov byte [gui_capture], 0
    popad
    ret

term_firstword_is:
    push esi
    push edi
.l: mov al, [edi]
    test al, al
    jz .end
    mov ah, [esi]
    cmp al, ah
    jne .no
    inc esi
    inc edi
    jmp .l
.end:
    mov al, [esi]
    test al, al
    jz .yes
    cmp al, ' '
    je .yes
.no:
    pop edi
    pop esi
    or al, 1
    ret
.yes:
    pop edi
    pop esi
    xor al, al
    ret

editor_app_init:
    mov esi, edit_file
    cmp dword [cur_app], APP_IDE
    jne .have
    mov esi, ide_file
.have:
    mov edi, app_file
    call str_copy
    mov dword [app_buf_len], 0
    mov byte [app_buf], 0
    mov byte [app_dirty], 0
    mov esi, app_file
    call fs_find
    jc .empty
    mov ecx, [edi + DE_SIZE]
    cmp ecx, APP_BUF - 1
    jb .size_ok
    mov ecx, APP_BUF - 1
.size_ok:
    mov [app_buf_len], ecx
    call fs_slot
    mov edi, app_buf
    call mem_copy
    mov ecx, [app_buf_len]
    mov byte [app_buf + ecx], 0
.empty:
    ret

app_text_draw:
    pushad
    call gui_content_box
    dec dword [ta_rows]
    mov dword [ta_fg], 0xE0E0E0
    mov ecx, [app_buf_len]
    mov byte [app_buf + ecx], 0
    mov esi, app_buf
    call gui_textarea_from

    mov ecx, [ta_x]
    mov eax, [ta_rows]
    imul eax, 16
    add eax, [ta_y]
    mov edx, eax
    mov esi, app_file
    mov ebx, 0x80C0FF
    push edx
    call gfx_rgb
    mov ebx, eax
    mov ebp, -1
    pop edx
    call gfx_text
    mov ecx, [ta_x]
    add ecx, 8 * 14
    mov esi, edit_hint
    cmp dword [cur_app], APP_IDE
    jne .h
    mov esi, ide_hint
.h:
    push edx
    mov eax, 0x9AA5B0
    call gfx_rgb
    mov ebx, eax
    mov ebp, -1
    pop edx
    call gfx_text
    popad
    ret

editor_app_key:
    cmp eax, 19
    je .save
    cmp eax, 18
    je .maybe_run
    cmp eax, 10
    je .nl
    cmp eax, 8
    je .back
    cmp eax, ' '
    jb .r
    cmp eax, '~'
    ja .r
.ins:
    mov ecx, [app_buf_len]
    cmp ecx, APP_BUF - 2
    jae .r
    mov [app_buf + ecx], al
    inc dword [app_buf_len]
    mov byte [app_dirty], 1
.r:
    ret
.nl:
    mov al, 10
    jmp .ins
.back:
    mov ecx, [app_buf_len]
    test ecx, ecx
    jz .r
    dec dword [app_buf_len]
    mov byte [app_dirty], 1
    ret
.maybe_run:
    cmp dword [cur_app], APP_IDE
    jne .r
    jmp ide_run
.save:
    mov ecx, [app_buf_len]
    mov byte [app_buf + ecx], 0
    mov esi, app_file
    mov edx, app_buf
    call fs_save
    mov byte [app_dirty], 0
    cmp dword [cur_app], APP_IDE
    jne .r

    ret

app_click:
    cmp dword [cur_app], APP_IDE
    je ide_run
    cmp dword [cur_app], APP_BROWSER
    je brow_go
    ret

ide_run:
    pushad
    mov ecx, [app_buf_len]
    mov byte [app_buf + ecx], 0
    mov esi, app_file
    mov edx, app_buf
    call fs_save

    mov dword [term_log_len], 0
    mov byte [gui_capture], 1
    mov esi, app_buf
    call script_run
    mov byte [gui_capture], 0
    mov dword [cur_app], APP_TERM
    mov dword [term_input_len], 0
    mov byte [term_input], 0
    popad
    ret

brow_init:
    mov dword [brow_url_len], 0
    mov byte [brow_url], 0
    mov dword [term_log_len], 0
    ret

app_brow_draw:
    pushad
    call gui_content_box

    mov ecx, [ta_x]
    mov edx, [ta_y]
    mov esi, brow_hint
    cmp dword [brow_url_len], 0
    je .showhint
    mov esi, brow_url
.showhint:
    mov ebx, 0x90E0FF
    push edx
    call gfx_rgb
    mov ebx, eax
    mov ebp, -1
    pop edx
    call gfx_text
    add dword [ta_y], 24
    dec dword [ta_rows]
    mov dword [ta_fg], 0xD8D8D8
    mov ecx, [term_log_len]
    mov byte [term_log + ecx], 0
    mov esi, term_log
    call gui_textarea_from
    popad
    ret

brow_key:
    cmp eax, 10
    je brow_go
    cmp eax, 8
    je .back
    cmp eax, ' '
    jb .r
    cmp eax, '~'
    ja .r
    mov ecx, [brow_url_len]
    cmp ecx, 150
    jae .r
    mov [brow_url + ecx], al
    inc dword [brow_url_len]
    mov byte [brow_url + ecx + 1], 0
.r:
    ret
.back:
    mov ecx, [brow_url_len]
    test ecx, ecx
    jz .r
    dec dword [brow_url_len]
    mov byte [brow_url + ecx - 1], 0
    ret

brow_go:
    pushad
    cmp byte [net_up], 0
    jne .have_net
    call net_up_bring
    jc .neterr
.have_net:
    call brow_parse
    jc .badurl
    mov dword [term_log_len], 0
    mov eax, [brow_ip]
    mov bx, [brow_port]
    mov esi, brow_host
    mov edi, brow_path
    call http_get
    jc .failed

    mov esi, PKG_BUF
    mov ecx, [pkg_len]
    cmp ecx, GUI_LOG - 1
    jb .cok
    mov ecx, GUI_LOG - 1
.cok:
    mov edi, term_log
    call mem_copy
    mov [term_log_len], ecx
    popad
    ret
.neterr:
    mov esi, brow_e_net
    jmp .msg
.badurl:
    mov esi, brow_e_url
    jmp .msg
.failed:
    mov esi, brow_e_fail
.msg:
    mov edi, term_log
    call str_copy
    call str_len
    mov [term_log_len], ecx
    popad
    ret

brow_parse:
    pushad
    mov esi, http_scheme
    mov edi, brow_url
    call str_iprefix
    mov esi, brow_url
    jne .no_scheme
    add esi, 7
.no_scheme:
    mov edi, brow_host
.h: mov al, [esi]
    test al, al
    jz .host_done
    cmp al, ':'
    je .port
    cmp al, '/'
    je .host_done
    mov [edi], al
    inc edi
    inc esi
    jmp .h
.port:
    mov byte [edi], 0
    inc esi
    push esi
    call parse_uint_from
    mov [brow_port], ax
    pop esi
.skipport:
    mov al, [esi]
    cmp al, '/'
    je .path
    test al, al
    jz .host_done2
    inc esi
    jmp .skipport
.host_done:
    mov byte [edi], 0
    mov word [brow_port], 80
.path:
    mov edi, brow_path
    cmp byte [esi], 0
    jne .copypath
    mov byte [edi], '/'
    mov byte [edi + 1], 0
    jmp .resolve
.copypath:
    call str_copy
    jmp .resolve
.host_done2:
    mov byte [edi], 0
    mov edi, brow_path
    mov byte [edi], '/'
    mov byte [edi + 1], 0
.resolve:
    cmp byte [brow_host], 0
    je .bad
    mov esi, brow_host
    call dns_resolve
    jc .bad
    mov [brow_ip], eax
    popad
    clc
    ret
.bad:
    popad
    stc
    ret

parse_uint_from:
    push ebx
    xor eax, eax
.l: movzx ebx, byte [esi]
    sub bl, '0'
    cmp bl, 9
    ja .e
    imul eax, 10
    add eax, ebx
    inc esi
    jmp .l
.e: pop ebx
    ret

section .data
http_scheme db "http://", 0
brow_e_net  db "Could not connect to the network.", 0
brow_e_url  db "Bad URL. Use  http://host[:port]/path", 0
brow_e_fail db "Could not load that page.", 0
section .bss
alignb 4
brow_ip     resd 1
brow_port   resw 1
brow_host   resb 64
brow_path   resb 128
section .text

gui_content_box:
    push eax
    mov eax, WIN_X
    add eax, 10
    mov [ta_x], eax
    mov eax, WIN_Y
    add eax, 34
    mov [ta_y], eax
    mov eax, [win_w]
    sub eax, 20
    shr eax, 3
    mov [ta_cols], eax
    mov eax, [win_h]
    sub eax, 44
    shr eax, 4
    mov [ta_rows], eax
    pop eax
    ret

gui_textarea_from:
    pushad
    mov dword [gfx_scale], 1
    mov dword [gta_col], 0
    mov dword [gta_row], 0
.ch:
    mov al, [esi]
    test al, al
    jz .done
    inc esi
    mov [gta_char], al
    cmp al, 10
    je .newline
    cmp al, 9
    je .tab
    cmp al, 32
    jb .ch
    mov ecx, [gta_col]
    shl ecx, 3
    add ecx, [ta_x]
    mov edx, [gta_row]
    shl edx, 4
    add edx, [ta_y]
    mov eax, [ta_fg]
    call gfx_rgb
    mov ebx, eax
    movzx eax, byte [gta_char]
    mov ebp, -1
    call gfx_char
    inc dword [gta_col]
    mov eax, [ta_cols]
    cmp [gta_col], eax
    jb .ch
.newline:
    mov dword [gta_col], 0
    inc dword [gta_row]
    mov eax, [ta_rows]
    cmp [gta_row], eax
    jb .ch
    jmp .done
.tab:
    add dword [gta_col], 4
    jmp .ch
.done:
    mov eax, [gta_row]
    mov [gta_rows], eax
    popad
    mov eax, [gta_rows]
    ret

section .bss
alignb 4
gta_rows resd 1
gta_col  resd 1
gta_row  resd 1
gta_char resb 1
section .text
