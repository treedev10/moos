; =============================================================================
;  gui.asm - the MOOS desktop (UEFI graphics only)
;
;  A simple desktop: a plain coloured background (the colour is chosen in
;  Settings), a taskbar with app buttons and a clock, a mouse cursor, and
;  windows for the built-in apps (terminal, text editor, script IDE, web
;  browser and settings) that can be moved, resized, maximized and
;  minimized (gui_win.asm). Drawn with gfx.asm into a back buffer.
;
;  The whole screen is only redrawn when something changes (a key, a click,
;  the clock). When just the mouse moves, the cursor is erased and redrawn
;  in the back buffer and only those two small areas are copied to the
;  screen, so the cursor stays smooth even on big screens.
;
;  Keys: F1-F5 (or 1-5 on the empty desktop) open an app; F6 switches
;  windows; F7 / F8 move / resize one with the arrow keys; F9 / F10
;  minimize / maximize; Esc closes the window, and Esc on the empty desktop
;  leaves. So the desktop works without a mouse too.
; =============================================================================
TASKBAR_H   equ 34
CUR_W       equ 16                  ; the area the mouse cursor covers
CUR_H       equ 20
TB_N        equ 6                   ; taskbar buttons: 5 apps + Quit
TB_QUIT     equ 5

; RECT x,y,w,h,rgb  (immediate or register expressions)
%macro RECT 5
    mov ecx, %1
    mov edx, %2
    mov esi, %3
    mov edi, %4
    mov eax, %5
    call gfx_rgb
    call gfx_fillrect
%endmacro

; TEXT x,y,ptr,fg,bg
%macro TEXT 5
    mov ecx, %1
    mov edx, %2
    mov esi, %3
    mov eax, %4
    call gfx_rgb
    mov ebx, eax
    mov ebp, %5
    call gfx_text
%endmacro

section .bss
alignb 4
gui_quit    resb 1
gui_active  resb 1              ; 1 while the desktop owns the screen
gui_dirty   resb 1              ; 1 = redraw + show everything, 2 = taskbar
alignb 4
gc_mx       resd 1              ; where the cursor is drawn
gc_my       resd 1
cur_under   resd CUR_W * CUR_H  ; what is underneath it
tb_hover    resd 1              ; taskbar button under the mouse, -1 if none
tb_x0       resd TB_N           ; each button's left and right edge
tb_x1       resd TB_N
tb_i        resd 1
tb_cx       resd 1
tb_top      resd 1
tb_col      resd 1
gui_clk_tick resd 1             ; when the clock was last looked at
gui_clk_sec resb 1

section .data
desktop_marker db "desktop.inst", 0
gui_title   db "MOOS", 0
gui_sub     db "Mightily Optimized Operating System", 0
gui_hint1   db "Click an app on the taskbar, or press its key:", 0
gui_hint2   db "F1 Terminal   F2 Editor   F3 Script IDE   F4 Browser   F5 Settings", 0
gui_hint3   db "Drag a title bar to move a window, an edge or corner to resize it.", 0
gui_hint4   db "Keys: F6 next window  F7 move  F8 resize  F9 minimize  F10 maximize", 0
gui_hint5   db "Esc closes a window. Esc on the empty desktop leaves.", 0
gui_nomouse db "No mouse found - the PC's firmware offers none. Use the keys above.", 0
ga_term     db "term", 0
ga_editor   db "editor", 0
ga_ide      db "ide", 0
ga_browser  db "browser", 0
ga_settings db "settings", 0
tb_labels   dd tb_l_term, tb_l_edit, tb_l_ide, tb_l_brow, tb_l_set, tb_l_quit
tb_lens     db 8, 6, 10, 7, 8, 4
tb_l_term   db "Terminal", 0
tb_l_edit   db "Editor", 0
tb_l_ide    db "Script IDE", 0
tb_l_brow   db "Browser", 0
tb_l_set    db "Settings", 0
tb_l_quit   db "Quit", 0
; desktop colours (Settings, item 6); desk_color picks one
DESK_NCOLORS equ 8
desk_rgb    dd 0x1D5568, 0x1F3A5F, 0x2D5A3D, 0x4B2F5C
            dd 0x6A2A35, 0x34393F, 0x0E1014, 0x3E6E8E
desk_names  dd dk_teal, dk_navy, dk_green, dk_purple
            dd dk_wine, dk_slate, dk_black, dk_steel
dk_teal     db "Teal", 0
dk_navy     db "Navy blue", 0
dk_green    db "Forest green", 0
dk_purple   db "Purple", 0
dk_wine     db "Wine red", 0
dk_slate    db "Slate grey", 0
dk_black    db "Black", 0
dk_steel    db "Steel blue", 0

section .text

; ------------------------------------------------------------ background
gui_wallpaper:
    pushad
    movzx eax, byte [desk_color]
    cmp eax, DESK_NCOLORS
    jb .colour
    xor eax, eax
.colour:
    mov eax, [desk_rgb + eax * 4]
    call gfx_rgb
    xor ecx, ecx
    xor edx, edx
    mov esi, [gfx_w]
    mov edi, [gfx_h]
    sub edi, TASKBAR_H
    call gfx_fillrect
    mov dword [gfx_scale], 3
    TEXT 40, 26, gui_title, 0xF4F0E6, -1
    mov dword [gfx_scale], 1
    TEXT 40, 74, gui_sub, 0xD8E4EA, -1
    TEXT 40, 120, gui_hint1, 0xD8E4EA, -1
    TEXT 40, 140, gui_hint2, 0xFFFFFF, -1
    TEXT 40, 166, gui_hint3, 0xD8E4EA, -1
    TEXT 40, 186, gui_hint4, 0xD8E4EA, -1
    TEXT 40, 206, gui_hint5, 0xD8E4EA, -1
    cmp byte [mouse_ok], 0
    jne .done
    TEXT 40, 242, gui_nomouse, 0xFFD27A, -1
.done:
    popad
    ret

; ---------------------------------------------------------------- cursor
; gui_cursor: draw the arrow at gc_mx / gc_my
gui_cursor:
    pushad
    mov esi, [gc_mx]
    mov edx, [gc_my]
    ; black outline arrow
    mov eax, esi
    mov [tri_px + 0], eax
    mov ebx, edx
    mov [tri_py + 0], ebx
    lea eax, [esi + 0]
    mov [tri_px + 4], eax
    lea ebx, [edx + 18]
    mov [tri_py + 4], ebx
    lea eax, [esi + 13]
    mov [tri_px + 8], eax
    lea ebx, [edx + 13]
    mov [tri_py + 8], ebx
    mov eax, 0x000000
    call gfx_rgb
    call gfx_tri
    ; white inner arrow
    lea eax, [esi + 2]
    mov [tri_px + 0], eax
    lea ebx, [edx + 3]
    mov [tri_py + 0], ebx
    lea eax, [esi + 2]
    mov [tri_px + 4], eax
    lea ebx, [edx + 15]
    mov [tri_py + 4], ebx
    lea eax, [esi + 10]
    mov [tri_px + 8], eax
    lea ebx, [edx + 11]
    mov [tri_py + 8], ebx
    mov eax, 0xFFFFFF
    call gfx_rgb
    call gfx_tri
    popad
    ret

; cur_rect: ECX/EDX/ESI/EDI = the area the cursor covers
cur_rect:
    mov ecx, [gc_mx]
    mov edx, [gc_my]
    mov esi, CUR_W
    mov edi, CUR_H
    ret

; gui_cursor_show: keep a copy of what is under the cursor, then draw it
gui_cursor_show:
    pushad
    call cur_rect
    mov ebx, cur_under
    xor eax, eax
    call gfx_copy_rect
    call gui_cursor
    popad
    ret

; gui_cursor_update: if the mouse moved, put back what was under the cursor,
; draw it at the new place, and copy just those two areas to the screen
gui_cursor_update:
    pushad
    mov eax, [mouse_x]
    cmp eax, [gc_mx]
    jne .moved
    mov eax, [mouse_y]
    cmp eax, [gc_my]
    je .done
.moved:
    call cur_rect
    mov ebx, cur_under
    mov eax, 1
    call gfx_copy_rect              ; erase it from the back buffer
    push ecx
    push edx
    mov eax, [mouse_x]
    mov [gc_mx], eax
    mov eax, [mouse_y]
    mov [gc_my], eax
    call gui_cursor_show
    pop edx
    pop ecx
    call gfx_present_rect           ; the old place
    call cur_rect
    call gfx_present_rect           ; the new place
.done:
    popad
    ret

; ---------------------------------------------------------------- taskbar
; Buttons left to right, Quit on the far right, the clock left of Quit.
; Their edges are kept in tb_x0 / tb_x1 for tb_hit.
gui_taskbar:
    pushad
    mov edx, [gfx_h]
    sub edx, TASKBAR_H
    mov [tb_top], edx
    RECT 0, edx, [gfx_w], TASKBAR_H, 0x202830
    mov edx, [tb_top]
    RECT 0, edx, [gfx_w], 2, 0x4A5A6A
    mov dword [gfx_scale], 1
    mov dword [tb_cx], 8
    mov dword [tb_i], 0
.btn:
    mov ecx, [tb_i]
    cmp ecx, TB_QUIT
    je .quit_pos
    movzx eax, byte [tb_lens + ecx]
    shl eax, 3
    add eax, 20                     ; label + padding
    mov edx, [tb_cx]
    mov [tb_x0 + ecx * 4], edx
    add eax, edx
    mov [tb_x1 + ecx * 4], eax
    add eax, 6                      ; gap to the next button
    mov [tb_cx], eax
    mov eax, 0x2C3844               ; app button, and under the mouse
    mov ebx, 0x46627E
    test dword [wn_f + ecx * 4 + 4], WF_OPEN
    jz .draw
    mov eax, 0x34495C               ; its window is open
    lea edx, [ecx + 1]
    cmp edx, [cur_app]
    jne .draw
    mov eax, 0x3D6A92               ; ... and has the focus
    mov ebx, 0x4F82AE
    jmp .draw
.quit_pos:
    mov eax, [gfx_w]
    sub eax, 8
    mov [tb_x1 + ecx * 4], eax
    sub eax, 52
    mov [tb_x0 + ecx * 4], eax
    mov eax, 0x5A2A2A               ; Quit is red
    mov ebx, 0x8A3A3A
.draw:
    cmp ecx, [tb_hover]
    jne .col
    mov eax, ebx
.col:
    mov [tb_col], eax
    mov ecx, [tb_i]
    mov esi, [tb_x1 + ecx * 4]
    mov ecx, [tb_x0 + ecx * 4]
    sub esi, ecx
    mov edx, [tb_top]
    add edx, 6
    RECT ecx, edx, esi, TASKBAR_H - 10, [tb_col]
    mov ecx, [tb_i]
    mov esi, [tb_labels + ecx * 4]
    mov ecx, [tb_x0 + ecx * 4]
    add ecx, 10
    mov edx, [tb_top]
    add edx, 10
    TEXT ecx, edx, esi, 0xE6ECF2, -1
    mov ecx, [tb_i]                 ; an open window: a bar under its button
    cmp ecx, TB_QUIT
    je .no_bar
    test dword [wn_f + ecx * 4 + 4], WF_OPEN
    jz .no_bar
    mov esi, [tb_x1 + ecx * 4]
    mov ecx, [tb_x0 + ecx * 4]
    sub esi, ecx
    sub esi, 16
    add ecx, 8
    mov edx, [tb_top]
    add edx, TASKBAR_H - 7
    RECT ecx, edx, esi, 2, 0x8FC3EA
.no_bar:
    inc dword [tb_i]
    cmp dword [tb_i], TB_N
    jb .btn
    ; the clock
    call rtc_read
    call gui_clock_str
    mov ecx, [gfx_w]
    sub ecx, 60 + 16 + 64
    mov edx, [tb_top]
    add edx, 10
    TEXT ecx, edx, gui_clockbuf, 0xB7E27A, -1
    popad
    ret

; tb_hit -> EAX = the taskbar button under the mouse (0-4 apps, TB_QUIT),
; or -1 if none
tb_hit:
    push ecx
    mov eax, [gfx_h]
    sub eax, TASKBAR_H
    cmp [mouse_y], eax
    jb .none
    xor ecx, ecx
.l: mov eax, [mouse_x]
    cmp eax, [tb_x0 + ecx * 4]
    jb .n
    cmp eax, [tb_x1 + ecx * 4]
    jb .hit
.n: inc ecx
    cmp ecx, TB_N
    jb .l
.none:
    mov eax, -1
    pop ecx
    ret
.hit:
    mov eax, ecx
    pop ecx
    ret

; gui_hover_check: light up the taskbar button under the mouse
gui_hover_check:
    push eax
    call tb_hit
    cmp eax, [tb_hover]
    je .same
    mov [tb_hover], eax
    or byte [gui_dirty], 2
.same:
    pop eax
    ret

; gui_clock_check: about five times a second, see whether the clock's second
; changed; if so the taskbar (and Settings, which shows the time) is redrawn
gui_clock_check:
    pushad
    mov eax, [ticks]
    sub eax, [gui_clk_tick]
    cmp eax, 20
    jb .done
    mov eax, [ticks]
    mov [gui_clk_tick], eax
    call rtc_read
    mov al, [rtc_sec]
    cmp al, [gui_clk_sec]
    je .done
    mov [gui_clk_sec], al
    or byte [gui_dirty], 2
    mov eax, [wn_f + APP_SETTINGS * 4]
    and eax, WF_OPEN | WF_MIN
    cmp eax, WF_OPEN                ; Settings shows the time too
    jne .done
    or byte [gui_dirty], 1
.done:
    popad
    ret

; gui_clock_str: format rtc_* into gui_clockbuf (respects clk_24h)
gui_clock_str:
    pushad
    mov edi, gui_clockbuf
    movzx eax, byte [rtc_hour]
    cmp byte [clk_24h], 0
    jne .h24
    cmp eax, 12
    jb .am
    cmp eax, 12
    je .pm_keep
    sub eax, 12
.pm_keep:
    test eax, eax
    jnz .h24
    mov eax, 12
.am:
.h24:
    call .two
    mov al, ':'
    stosb
    movzx eax, byte [rtc_min]
    call .two
    mov al, ':'
    stosb
    movzx eax, byte [rtc_sec]
    call .two
    mov byte [edi], 0
    popad
    ret
.two:
    push edx
    xor edx, edx
    push ebx
    mov ebx, 10
    div ebx
    add al, '0'
    mov [edi], al
    add dl, '0'
    mov [edi + 1], dl
    add edi, 2
    pop ebx
    pop edx
    ret
section .bss
gui_clockbuf resb 16
section .text

; gui_redraw: draw the whole desktop into the back buffer, then show it -
; all of it (gui_dirty bit 1) or just the taskbar (bit 2)
gui_redraw:
    pushad
    call gui_wallpaper
    call gui_windows
    call gui_taskbar
    call gui_cursor_show
    test byte [gui_dirty], 1
    jz .bar
    call gfx_present
    jmp .done
.bar:
    xor ecx, ecx
    mov edx, [gfx_h]
    sub edx, TASKBAR_H
    mov esi, [gfx_w]
    mov edi, TASKBAR_H
    call gfx_present_rect
.done:
    mov byte [gui_dirty], 0
    popad
    ret

; ------------------------------------------------------------- the desktop
cmd_gui:
    cmp dword [bootinfo + BI.platform], PLATFORM_UEFI
    je .ok
    PRINTF `The graphical desktop needs a UEFI PC (it draws on a graphics\nscreen). This computer started from a BIOS, so only the text\nconsole is available.\n`
    ret
.ok:
    mov esi, desktop_marker         ; the desktop is an installable package
    call fs_find
    jnc .installed
    PRINTF `The desktop is not installed yet. Install it with:\n\n    \x01wapt install desktop\x01n\n\n(this downloads it from the package server - see \x01wman apt\x01n). It is a one-time\nstep; after that, \x01wgui\x01n starts the desktop.\n`
    ret
.installed:
    call gfx_init
    jnc .have_gfx
    PRINTF `No graphics screen is available.\n`
    ret
.have_gfx:
    mov byte [gui_active], 1
    call efi_mouse_init
    mov byte [gui_quit], 0
    call wm_reset
    mov dword [tb_hover], -1
    mov dword [prev_btn], 0
    mov eax, [mouse_x]
    mov [gc_mx], eax
    mov eax, [mouse_y]
    mov [gc_my], eax
    mov eax, [ticks]
    mov [gui_clk_tick], eax
    mov byte [gui_clk_sec], 0xFF
    cmp dword [argc], 2             ; "gui <app> ..." opens apps straight away
    jb .start
    mov ebx, 1
.arg:
    cmp ebx, [argc]
    jae .start
    mov esi, [argv + ebx * 4]
    inc ebx
    mov eax, APP_TERM
    mov edi, ga_term
    call str_icmp
    je .open
    mov eax, APP_EDITOR
    mov edi, ga_editor
    call str_icmp
    je .open
    mov eax, APP_IDE
    mov edi, ga_ide
    call str_icmp
    je .open
    mov eax, APP_SETTINGS
    mov edi, ga_settings
    call str_icmp
    je .open
    mov eax, APP_BROWSER
    mov edi, ga_browser
    call str_icmp
    jne .arg
    call gui_open                   ; "gui browser <url>": go there
    cmp ebx, [argc]
    jae .start
    mov esi, [argv + ebx * 4]
    inc ebx
    call brow_open_url
    jmp .arg
.open:
    call gui_open
    jmp .arg
.start:
    mov byte [gui_dirty], 1
    call gui_redraw
.loop:
    call efi_mouse_poll
    call gui_hover_check
    call gui_handle                 ; clicks, drags, hovering
    call gui_wheel
    call gui_clock_check
.keys:
    call kbd_poll                   ; take every waiting key before drawing
    test eax, eax
    jz .draw
    call gui_key                    ; window keys, or to the focused app
    cmp byte [gui_quit], 0
    je .keys
.draw:
    cmp byte [gui_quit], 0
    jne .exit
    call gui_cursor_update
    cmp byte [gui_dirty], 0
    je .loop
    call gui_redraw
    jmp .loop
.exit:
    ; return to the text console
    call gui_restore_console
    ret

gui_restore_console:
    pushad
    mov byte [gui_active], 0
    mov edi, screen_drawn           ; force a full text redraw
    mov ecx, SCR_COLS * SCR_ROWS
    mov ax, 0xFFFF
    rep stosw
    mov dword [drawn_cursor], -1
    mov eax, efi_clear64
    call efi64
    call screen_present
    popad
    ret

%include "src/gui_win.asm"
