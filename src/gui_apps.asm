; =============================================================================
;  gui_apps.asm - the desktop apps: terminal, editor, script IDE, settings
;  (the browser is in browser.asm)
;
;  Each app draws into the content box of its window (cb_x, cb_y, cb_w,
;  cb_h - see gui_win.asm), so it follows the window when it is moved or
;  resized. The Text Editor and the Script IDE can be open at the same time,
;  so each has its own text buffer (a TX_ block).
; =============================================================================
GUI_LOG     equ 16384
APP_BUF     equ 4096
TX_LEN      equ 0                   ; text buffer block: length of the text,
TX_DIRTY    equ 4                   ; 1 = changed since saved,
TX_FILE     equ 8                   ; the file it belongs to (a path),
TX_BUF      equ 8 + 128             ; then the text itself
TX_SIZE     equ TX_BUF + APP_BUF

section .bss
alignb 4
gui_capture resb 1
term_esc    resb 1
alignb 4
term_log    resb GUI_LOG
term_log_len resd 1
term_input  resb 160
term_input_len resd 1
alignb 4
tx_edit     resb TX_SIZE        ; the Text Editor's text
tx_ide      resb TX_SIZE        ; the Script IDE's text
ta_x        resd 1
ta_y        resd 1
ta_cols     resd 1
ta_rows     resd 1
ta_fg       resd 1

section .data
term_welcome db "MOOS terminal - type a command and press Enter.", 10
             db "Commands that take over the screen (edit, write, gui) are", 10
             db "not available here; use ls, cat, calc, net, apt, time...", 10, 10, 0
ide_file     db "/script.ms", 0           ; (whatever the current folder is)
edit_file    db "/notes.txt", 0
ide_hint     db "Ctrl+R = Run     Ctrl+S = Save", 0
edit_hint    db "Ctrl+S = Save", 0
bl_edit      db "edit", 0
bl_write     db "write", 0
bl_append    db "append", 0
bl_gui       db "gui", 0
bl_format    db "format", 0
bl_run_blk   db "(that command needs the full screen - run it from the text console)", 10, 0

section .text

; gui_log_char: append AL to the terminal log (strips \x01 colour escapes).
; gui_capture = 2 throws the text away instead (the browser, while loading).
gui_log_char:
    cmp byte [gui_capture], 2
    jne .keep
    ret
.keep:
    cmp byte [term_esc], 0
    je .not_esc
    mov byte [term_esc], 0          ; drop the colour letter
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
    call term_log_scroll            ; full: drop the first quarter
    mov edi, [term_log_len]
.room:
    mov [term_log + edi], al
    inc dword [term_log_len]
    pop edi
.skip:
    ret

; term_log_scroll: discard the oldest quarter of the log
term_log_scroll:
    pushad
    mov esi, term_log + GUI_LOG / 4
    mov edi, term_log
    mov ecx, GUI_LOG - GUI_LOG / 4
    rep movsb
    sub dword [term_log_len], GUI_LOG / 4
    popad
    ret

; term_log_str: append the string ESI to the log
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

; ---------------------------------------------------------------- Terminal
term_init:
    mov dword [term_log_len], 0
    mov dword [term_input_len], 0
    mov byte [term_input], 0
    mov esi, term_welcome
    call term_log_str
    ret

; app_term_draw: show the log tail + the input line
app_term_draw:
    pushad
    call gui_content_box            ; sets ta_x/ta_y/ta_cols/ta_rows
    mov dword [ta_fg], 0xCDE0C0
    ; find a start offset showing the last (rows-1) lines
    mov ecx, [ta_rows]
    dec ecx
    mov edx, [term_log_len]
    mov esi, term_log
    add esi, edx                    ; end
    mov ebx, ecx                    ; newlines to walk back
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
    mov byte [term_log + edx], 0    ; terminate the log for rendering
    call gui_textarea_from          ; ESI = start -> renders, EAX = rows used
    ; input line on the next row
    mov ecx, [ta_x]
    mov edx, eax
    imul edx, 16
    add edx, [ta_y]
    call shell_prompt               ; "moos> " (with the folder, if any)
    mov eax, 0x7CE08A               ; (green, like the text console's prompt)
    push edx
    call gfx_rgb
    mov ebx, eax
    mov ebp, -1
    pop edx
    call gfx_text
    push ecx
    call str_len                    ; after the prompt
    shl ecx, 3
    pop eax
    add ecx, eax
    mov esi, term_input
    call gfx_text
    popad
    ret

; term_key: EAX = key typed in the terminal
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
    call shell_prompt               ; echo the command into the log
    call term_log_str
    mov esi, term_input
    call term_log_str
    mov al, 10
    call gui_log_char
    call term_run
    mov dword [term_input_len], 0
    mov byte [term_input], 0
    ret

; term_run: run the command in term_input (captured into the log)
term_run:
    pushad
    mov esi, term_input
    call skip_spaces
    cmp byte [esi], 0
    je .done
    ; blacklist screen-takeover commands
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
    ; copy to line_buf and run with capture on
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

; term_firstword_is: EDI = word, ESI = command text -> ZF=1 if first word ==
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

; ------------------------------------------------- Editor / Script IDE
; tx_for: EAX = APP_EDITOR or APP_IDE -> EBX = its text block
tx_for:
    mov ebx, tx_edit
    cmp eax, APP_IDE
    jne .r
    mov ebx, tx_ide
.r: ret

; editor_app_init: EAX = app. Load its file: the Script IDE /script.ms,
; the Text Editor edit_path (set by editor_open, gui_desk.asm) or else
; /notes.txt.
editor_app_init:
    pushad
    call tx_for
    mov esi, edit_file              ; choose the file by app
    cmp byte [edit_path], 0
    je .ide
    mov esi, edit_path
.ide:
    cmp eax, APP_IDE
    jne .have
    mov esi, ide_file
.have:
    lea edi, [ebx + TX_FILE]
    call str_copy
    mov dword [ebx + TX_LEN], 0
    mov byte [ebx + TX_BUF], 0
    mov dword [ebx + TX_DIRTY], 0
    mov ebp, ebx
    lea esi, [ebp + TX_FILE]        ; load it if it exists
    call fs_find                    ; (EBX = its index)
    jc .empty
    mov ecx, [edi + DE_SIZE]
    cmp ecx, APP_BUF - 1
    jb .size_ok
    mov ecx, APP_BUF - 1
.size_ok:
    mov [ebp + TX_LEN], ecx
    call fs_slot
    lea edi, [ebp + TX_BUF]
    call mem_copy
    mov byte [edi + ecx], 0
.empty:
    popad
    ret

; app_text_draw: EAX = APP_EDITOR or APP_IDE -> its text, then a status line
app_text_draw:
    pushad
    mov [txd_app], eax
    call tx_for
    call gui_content_box
    dec dword [ta_rows]             ; leave a row for the status line
    mov dword [ta_fg], 0xE0E0E0
    mov ecx, [ebx + TX_LEN]
    mov byte [ebx + TX_BUF + ecx], 0
    ; show the end of the text (where typing goes) if it does not all fit
    lea esi, [ebx + TX_BUF]
    call gui_text_tail
    call gui_textarea_from
    mov eax, [ta_rows]              ; a text cursor after the last character
    cmp [gta_row], eax
    jae .no_cursor
    mov ecx, [gta_col]
    shl ecx, 3
    add ecx, [ta_x]
    mov edx, [gta_row]
    shl edx, 4
    add edx, [ta_y]
    add edx, 13
    RECT ecx, edx, 8, 2, 0xE0E0E0
.no_cursor:
    ; status line: filename + hint
    mov ecx, [ta_x]
    mov eax, [ta_rows]
    imul eax, 16
    add eax, [ta_y]
    mov edx, eax
    mov eax, [txd_app]
    call tx_for
    lea esi, [ebx + TX_FILE]
    mov eax, 0x80C0FF
    push edx
    call gfx_rgb
    mov ebx, eax
    mov ebp, -1
    pop edx
    call gfx_text
    call str_len                    ; the hint after the name (a path can be
    add ecx, 3                      ; long), at least 14 columns in
    cmp ecx, 14
    jae .hx
    mov ecx, 14
.hx:
    shl ecx, 3
    add ecx, [ta_x]
    mov esi, edit_hint
    cmp dword [txd_app], APP_IDE
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

; editor_app_key: EAX = key, for the focused Text Editor or Script IDE
editor_app_key:
    push eax
    mov eax, [cur_app]
    call tx_for
    pop eax
    cmp eax, 19                     ; Ctrl+S = save
    je .save
    cmp eax, 18                     ; Ctrl+R = run (Script IDE)
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
    mov ecx, [ebx + TX_LEN]
    cmp ecx, APP_BUF - 2
    jae .r
    mov [ebx + TX_BUF + ecx], al
    inc dword [ebx + TX_LEN]
    mov dword [ebx + TX_DIRTY], 1
.r:
    ret
.nl:
    mov al, 10
    jmp .ins
.back:
    mov ecx, [ebx + TX_LEN]
    test ecx, ecx
    jz .r
    dec dword [ebx + TX_LEN]
    mov dword [ebx + TX_DIRTY], 1
    ret
.maybe_run:
    cmp dword [cur_app], APP_IDE
    jne .r
    jmp ide_run
.save:
    jmp tx_save

; tx_save: EBX = text block -> write it to its file
tx_save:
    pushad
    mov ecx, [ebx + TX_LEN]
    mov byte [ebx + TX_BUF + ecx], 0
    lea esi, [ebx + TX_FILE]
    lea edx, [ebx + TX_BUF]
    call fs_save
    mov dword [ebx + TX_DIRTY], 0
    popad
    ret

; ide_run: run the IDE's script (Ctrl+R or the Run button); the output is
; shown in the Terminal window, which is opened or brought to the front
ide_run:
    pushad
    mov ebx, tx_ide
    call tx_save                    ; save first
    test dword [wn_f + APP_TERM * 4], WF_OPEN
    jnz .term_open
    mov eax, APP_TERM
    call gui_open
.term_open:
    mov dword [term_log_len], 0     ; run with capture into the terminal log
    mov byte [gui_capture], 1
    lea esi, [tx_ide + TX_BUF]
    call script_run
    mov byte [gui_capture], 0
    mov dword [term_input_len], 0
    mov byte [term_input], 0
    mov eax, APP_TERM               ; show the output in the terminal
    call gui_raise
    popad
    ret

section .bss
alignb 4
txd_app resd 1
section .text

; ---------------------------------------------------------------- Settings
section .bss
alignb 4
settings_color_idx resd 1
settings_msg       resb 80
section .data
set_bg_nibbles db 1, 2, 4, 5, 6, 8, 0      ; status-bar background colours
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

; gui_draw_outbuf: render the text collected in OUTBUF at ECX=x, EDX=y.
; Caller sets gfx_scale. (Uses out_begin/PRINTF with out_mode = 1.)
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
    mov dword [gfx_scale], 2        ; title
    call out_begin
    PRINTF `MOOS Settings`
    mov ecx, [ta_x]
    mov edx, [ta_y]
    call gui_draw_outbuf
    mov dword [gfx_scale], 1
    mov eax, [ta_y]
    add eax, 44
    mov [set_y], eax
    ; line: hint
    call out_begin
    PRINTF `Press a number key to change a setting:`
    call .line
    add dword [set_y], 10
    ; 1  clock format
    mov esi, set_fmt12
    cmp byte [clk_24h], 0
    je .f12
    mov esi, set_fmt24
.f12:
    call out_begin
    PRINTF `1  Clock format .......... %s`, esi
    call .line
    ; 2  status bar colour
    movzx eax, byte [clk_color]
    shr eax, 4
    mov esi, [colour_names + eax * 4]
    call out_begin
    PRINTF `2  Status bar colour ..... %s`, esi
    call .line
    ; 3  timezone
    mov eax, [clk_tz_min]
    cdq
    mov ecx, 60
    idiv ecx
    call out_begin
    PRINTF `3  Timezone .............. UTC %i hour(s)   (+ / - to change)`, eax
    call .line
    ; 4, 5
    call out_begin
    PRINTF `4  Sync the clock from the internet`
    call .line
    call out_begin
    PRINTF `5  Connect to the network`
    call .line
    ; 6  desktop colour
    movzx eax, byte [desk_color]
    cmp eax, DESK_NCOLORS
    jb .dc
    xor eax, eax
.dc:
    mov esi, [desk_names + eax * 4]
    call out_begin
    PRINTF `6  Desktop colour ........ %s`, esi
    call .line
    add dword [set_y], 12
    ; time now
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
    ; network
    call out_begin
    PRINTF `Network: .... `
    cmp byte [net_up], 0
    je .noip
    mov eax, [my_ip]
    call ip_print                   ; appends to OUTBUF (out_mode = 1)
    jmp .netshown
.noip:
    PRINTF `%s`, set_notconn
.netshown:
    call .line
    ; mouse: what the firmware offers
    mov eax, [ptr_real + PTR_REL * 4]
    mov ebx, [ptr_real + PTR_ABS * 4]
    call out_begin
    PRINTF `Mouse: ...... %d mouse(s), %d touch screen(s) / tablet(s)`, eax, ebx
    call .line
    add dword [set_y], 10
    ; message line
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

; settings_click: a click on one of the numbered lines does what its key does
settings_click:
    pushad
    mov eax, [mouse_y]
    sub eax, [cb_y]
    sub eax, 6 + 44 + 18 + 10       ; (where settings_draw puts line 1)
    js .done
    shr eax, 1                      ; / 18 pixels per line
    xor edx, edx
    mov ecx, 9
    div ecx
    cmp eax, 6
    jae .done
    add eax, '1'
    call settings_key
.done:
    popad
    ret

settings_key:
    cmp al, '1'
    je .fmt
    cmp al, '2'
    je .color
    cmp al, '4'
    je .sync
    cmp al, '5'
    je .net
    cmp al, '6'
    je .desk
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
    or ebx, 0x0F                    ; white text on the chosen background
    mov [clk_color], bl
    call status_draw
    call clk_save
    ret
.desk:
    movzx eax, byte [desk_color]
    inc eax
    cmp eax, DESK_NCOLORS
    jb .dk_ok
    xor eax, eax
.dk_ok:
    mov [desk_color], al
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

; ---------------------------------------------------- shared text helpers
; gui_content_box: set ta_x/ta_y/ta_cols/ta_rows to the window's content
; box (cb_*, set by the window manager), less a margin
gui_content_box:
    push eax
    mov eax, [cb_x]
    add eax, 10
    mov [ta_x], eax
    mov eax, [cb_y]
    add eax, 6
    mov [ta_y], eax
    mov eax, [cb_w]
    sub eax, 20
    jns .w
    xor eax, eax
.w: shr eax, 3                      ; / 8 px per char
    mov [ta_cols], eax
    mov eax, [cb_h]
    sub eax, 12
    jns .h
    xor eax, eax
.h: shr eax, 4                      ; / 16 px per row
    mov [ta_rows], eax
    pop eax
    ret

; gui_text_tail: ESI = text -> ESI moved forward so that what is left fits
; in ta_rows rows of ta_cols (wrapped the way gui_textarea_from wraps)
gui_text_tail:
    pushad
    mov ebx, esi                    ; EBX = start of the text
    cmp dword [ta_cols], 0
    je .done
    cmp dword [ta_rows], 0
    je .done
.again:
    xor ecx, ecx                    ; count the rows from ESI
    xor edx, edx                    ; (column)
    mov edi, esi
.c: mov al, [edi]
    test al, al
    jz .counted
    inc edi
    cmp al, 10
    je .row
    cmp al, 9
    jne .ch
    add edx, 3
.ch:
    inc edx
    cmp edx, [ta_cols]
    jb .c
.row:
    xor edx, edx
    inc ecx
    jmp .c
.counted:
    cmp ecx, [ta_rows]              ; the last row is where the cursor goes
    jb .fits
.skip:                              ; too many: drop the first row
    xor edx, edx
.s1:
    mov al, [esi]
    test al, al
    jz .fits
    inc esi
    cmp al, 10
    je .again
    inc edx
    cmp edx, [ta_cols]
    jb .s1
    jmp .again
.fits:
    mov [esp + 4], esi              ; (ESI after popad)
.done:
    popad
    ret

; gui_textarea_from: ESI = NUL-terminated text, rendered wrapped into ta_*
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
    mov ecx, [gta_col]              ; x = ta_x + col*8
    shl ecx, 3
    add ecx, [ta_x]
    mov edx, [gta_row]             ; y = ta_y + row*16
    shl edx, 4
    add edx, [ta_y]
    mov eax, [ta_fg]
    call gfx_rgb
    mov ebx, eax
    movzx eax, byte [gta_char]
    mov ebp, -1
    call gfx_char                   ; preserves esi/ebx/ebp/ecx/edx
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
