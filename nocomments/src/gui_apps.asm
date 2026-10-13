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
brow_hint    db "Type a URL, then Enter:  https://raw.githubusercontent.com/treedev10/moos/HEAD/README.md", 0
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
    mov dword [term_log_len], 0
    mov byte [url_insecure], 0
    mov esi, brow_url
    call url_fetch
    jc .failed
    mov esi, brow_s_https
    cmp byte [url_scheme], 1
    je .st
    mov esi, brow_s_http
.st:
    mov edi, term_log
    call str_copy
    call str_len
    mov edi, term_log
    add edi, ecx
    mov ebx, ecx
    mov esi, PKG_BUF
    mov ecx, [pkg_len]
    mov eax, GUI_LOG - 2
    sub eax, ebx
    cmp ecx, eax
    jbe .cok
    mov ecx, eax
.cok:
    call mem_copy
    add ebx, ecx
    mov [term_log_len], ebx
    popad
    ret
.failed:
    mov edi, term_log
    mov esi, brow_e_fail
    call str_copy
    mov esi, [url_err]
    mov edi, term_log
    call str_append
    mov esi, term_log
    call str_len
    mov [term_log_len], ecx
    popad
    ret

section .data
brow_s_https db "[ HTTPS - TLS 1.3, certificate checked ]", 10, 10, 0
brow_s_http  db "[ plain HTTP - not encrypted ]", 10, 10, 0
brow_e_fail  db "Could not load that page: ", 0
section .text

section .bss
alignb 4
settings_color_idx resd 1
settings_msg       resb 80
section .data
set_bg_nibbles db 1, 2, 4, 5, 6, 8, 0
SET_NCOLORS    equ 7
set_fmt24      db "24-hour (military)", 0
set_fmt12      db "12-hour", 0
set_welcome    db "Use the number keys and + / - to change settings.", 0
set_syncing    db "Syncing the clock from the internet...", 0
set_synced     db "Clock synced from the internet.", 0
set_syncfail   db "Could not sync - is the network connected?", 0
set_connected  db "Connected to the network.", 0
set_connfail   db "Could not connect to the network.", 0
set_notconn    db "not connected", 0
section .text

settings_init:
    mov esi, set_welcome
    call set_msg
    ret

set_msg:
    mov edi, settings_msg
    call str_copy
    ret

gui_draw_outbuf:
    push eax
    push ebx
    push esi
    push ebp
    mov esi, [out_ptr]
    mov byte [esi], 0
    mov byte [out_mode], 0
    mov esi, OUTBUF
    mov eax, 0xE6ECF2
    call gfx_rgb
    mov ebx, eax
    mov ebp, -1
    call gfx_text
    pop ebp
    pop esi
    pop ebx
    pop eax
    ret

settings_draw:
    pushad
    call gui_content_box
    mov dword [gfx_scale], 2
    call out_begin
    PRINTF `MOOS Settings`
    mov ecx, [ta_x]
    mov edx, [ta_y]
    call gui_draw_outbuf
    mov dword [gfx_scale], 1
    mov eax, [ta_y]
    add eax, 44
    mov [set_y], eax

    call out_begin
    PRINTF `Press a number key to change a setting:`
    call .line
    add dword [set_y], 10

    mov esi, set_fmt12
    cmp byte [clk_24h], 0
    je .f12
    mov esi, set_fmt24
.f12:
    call out_begin
    PRINTF `1  Clock format .......... %s`, esi
    call .line

    movzx eax, byte [clk_color]
    shr eax, 4
    mov esi, [colour_names + eax * 4]
    call out_begin
    PRINTF `2  Status bar colour ..... %s`, esi
    call .line

    mov eax, [clk_tz_min]
    cdq
    mov ecx, 60
    idiv ecx
    call out_begin
    PRINTF `3  Timezone .............. UTC %i hour(s)   (+ / - to change)`, eax
    call .line

    call out_begin
    PRINTF `4  Sync the clock from the internet`
    call .line
    call out_begin
    PRINTF `5  Connect to the network`
    call .line
    add dword [set_y], 12

    call rtc_read
    call out_begin
    movzx eax, word [rtc_year]
    movzx ebx, byte [rtc_month]
    movzx ecx, byte [rtc_day]
    PRINTF `Time now: ... %d-%02d-%02d`, eax, ebx, ecx
    movzx eax, byte [rtc_hour]
    movzx ebx, byte [rtc_min]
    movzx ecx, byte [rtc_sec]
    PRINTF `  %02d:%02d:%02d`, eax, ebx, ecx
    call .line

    call out_begin
    PRINTF `Network: .... `
    cmp byte [net_up], 0
    je .noip
    mov eax, [my_ip]
    call ip_print
    jmp .netshown
.noip:
    PRINTF `%s`, set_notconn
.netshown:
    call .line
    add dword [set_y], 10

    call out_begin
    PRINTF `%s`, settings_msg
    call .line
    popad
    ret
.line:
    mov ecx, [ta_x]
    mov edx, [set_y]
    call gui_draw_outbuf
    add dword [set_y], 18
    ret

section .bss
alignb 4
set_y resd 1
section .text

settings_key:
    cmp al, '1'
    je .fmt
    cmp al, '2'
    je .color
    cmp al, '4'
    je .sync
    cmp al, '5'
    je .net
    cmp al, '+'
    je .tzup
    cmp al, '='
    je .tzup
    cmp al, '-'
    je .tzdn
    ret
.fmt:
    xor byte [clk_24h], 1
    call clk_save
    ret
.color:
    mov eax, [settings_color_idx]
    inc eax
    cmp eax, SET_NCOLORS
    jb .ci_ok
    xor eax, eax
.ci_ok:
    mov [settings_color_idx], eax
    movzx ebx, byte [set_bg_nibbles + eax]
    shl ebx, 4
    or ebx, 0x0F
    mov [clk_color], bl
    call status_draw
    call clk_save
    ret
.tzup:
    add dword [clk_tz_min], 60
    call clk_apply_tz
    call clk_save
    ret
.tzdn:
    sub dword [clk_tz_min], 60
    call clk_apply_tz
    call clk_save
    ret
.sync:
    mov esi, set_syncing
    call set_msg
    call clock_do_sync
    mov esi, set_synced
    jnc .msg
    mov esi, set_syncfail
.msg:
    call set_msg
    ret
.net:
    call net_up_bring
    mov esi, set_connected
    jnc .nmsg
    mov esi, set_connfail
.nmsg:
    call set_msg
    ret

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
