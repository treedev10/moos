; =============================================================================
;  gui_win.asm - windows and apps for the MOOS desktop
;
;  One window at a time (kept simple). gui_open launches an app; the window
;  shows its content; the taskbar buttons (or keys 1-5 on the empty desktop)
;  switch apps; the window's close box or Esc closes it; Quit leaves. Apps:
;    1 Terminal   - type commands, see output (runs the real shell commands)
;    2 Editor     - edit a text file
;    3 Script IDE - edit a .ms file and Run it (Run button or Ctrl+R)
;    4 Browser    - fetch an http:// or https:// page and show its text
;    5 Settings   - clock, colours, network
; =============================================================================
APP_NONE    equ 0
APP_TERM    equ 1
APP_EDITOR  equ 2
APP_IDE     equ 3
APP_BROWSER equ 4
APP_SETTINGS equ 5

WIN_X       equ 60
WIN_Y       equ 70
RUN_W       equ 56                  ; the Script IDE's Run button

section .bss
alignb 4
cur_app     resd 1
win_w       resd 1
win_h       resd 1
prev_btn    resd 1

section .data
win_titles  dd 0, t_term, t_edit, t_ide, t_brow, t_set
t_term      db "Terminal", 0
t_edit      db "Text Editor", 0
t_ide       db "Script IDE", 0
t_brow      db "MOOS Browser", 0
t_set       db "Settings", 0

section .text

; gui_windows: draw the current app's window (if any)
gui_windows:
    pushad
    cmp dword [cur_app], APP_NONE
    je .done
    mov eax, [gfx_w]
    sub eax, 2 * WIN_X
    mov [win_w], eax
    mov eax, [gfx_h]
    sub eax, WIN_Y + TASKBAR_H + 40
    mov [win_h], eax
    ; window body + border
    RECT WIN_X - 2, WIN_Y - 2, [win_w], [win_h], 0x6682A0
    add dword [win_w], 4            ; (border frame)
    sub dword [win_w], 4
    RECT WIN_X, WIN_Y, [win_w], [win_h], 0x12161C
    ; title bar
    RECT WIN_X, WIN_Y, [win_w], 26, 0x2C5A82
    mov dword [gfx_scale], 1
    mov eax, [cur_app]
    mov esi, [win_titles + eax * 4]
    TEXT WIN_X + 10, WIN_Y + 6, esi, 0xFFFFFF, -1
    ; close box
    mov ecx, [gfx_w]
    sub ecx, WIN_X - 2
    sub ecx, 24
    mov [gui_close_x], ecx
    RECT ecx, WIN_Y + 4, 18, 18, 0xB03030
    mov esi, close_x
    lea ecx, [ecx + 5]
    TEXT ecx, WIN_Y + 6, close_x, 0xFFFFFF, -1
    cmp dword [cur_app], APP_IDE    ; the Script IDE has a Run button
    jne .no_run
    mov ecx, [gui_close_x]
    sub ecx, RUN_W + 8
    mov [gui_run_x], ecx
    RECT ecx, WIN_Y + 4, RUN_W, 18, 0x2E7D4F
    mov ecx, [gui_run_x]
    add ecx, 16
    TEXT ecx, WIN_Y + 6, run_label, 0xFFFFFF, -1
.no_run:
    ; content
    mov eax, [cur_app]
    cmp eax, APP_TERM
    je .term
    cmp eax, APP_BROWSER
    je .brow
    cmp eax, APP_SETTINGS
    je .settings
    ; editor / IDE share the text-area view
    call app_text_draw
    jmp .done
.term:
    call app_term_draw
    jmp .done
.brow:
    call app_brow_draw
    jmp .done
.settings:
    call settings_draw
.done:
    popad
    ret

section .data
close_x db "x", 0
run_label db "Run", 0
section .bss
alignb 4
gui_close_x resd 1
gui_run_x   resd 1
section .text

; gui_open: EAX = app id. Initialise and show it.
gui_open:
    mov [cur_app], eax
    cmp eax, APP_TERM
    je term_init
    cmp eax, APP_EDITOR
    je .edit
    cmp eax, APP_IDE
    je .edit
    cmp eax, APP_BROWSER
    je brow_init
    cmp eax, APP_SETTINGS
    je settings_init
    ret
.edit:
    jmp editor_app_init

; ---------------------------------------------------- mouse click handling
; gui_handle: act on a mouse click (button just pressed)
gui_handle:
    pushad
    mov eax, [mouse_btn]
    mov ebx, [prev_btn]
    mov [prev_btn], eax
    test eax, eax
    jz .done
    test ebx, ebx
    jnz .done                       ; only the moment of pressing
    or byte [gui_dirty], 1
    ; taskbar?
    mov eax, [gfx_h]
    sub eax, TASKBAR_H
    cmp [mouse_y], eax
    jae .taskbar
    ; the window's title bar: close box, or the IDE's Run button
    cmp dword [cur_app], APP_NONE
    je .done
    mov eax, [mouse_y]
    cmp eax, WIN_Y + 4
    jb .done
    cmp eax, WIN_Y + 22
    ja .done
    mov eax, [mouse_x]
    mov ecx, [gui_close_x]
    cmp eax, ecx
    jb .run
    add ecx, 18
    cmp eax, ecx
    ja .done
    mov dword [cur_app], APP_NONE
    jmp .done
.run:
    cmp dword [cur_app], APP_IDE
    jne .done
    mov ecx, [gui_run_x]
    cmp eax, ecx
    jb .done
    add ecx, RUN_W
    cmp eax, ecx
    ja .done
    call ide_run
    jmp .done
.taskbar:
    call gui_taskbar_click
.done:
    popad
    ret

; gui_taskbar_click: open the app whose button was clicked, or Quit
gui_taskbar_click:
    call tb_hit
    cmp eax, TB_QUIT
    je .quit
    test eax, eax
    js .r
    inc eax                         ; button 0 is app 1 (Terminal), ...
    jmp gui_open
.quit:
    mov byte [gui_quit], 1
.r: ret

; gui_key: EAX = key -> hand to the open app. On the empty desktop, 1-5
; open the apps (so it can be used without a mouse).
gui_key:
    cmp dword [cur_app], APP_NONE
    jne .app
    cmp eax, '1'
    jb .r
    cmp eax, '5'
    ja .r
    sub eax, '0'                    ; '1' -> APP_TERM ... '5' -> APP_SETTINGS
    jmp gui_open
.app:
    cmp dword [cur_app], APP_TERM
    je term_key
    cmp dword [cur_app], APP_BROWSER
    je brow_key
    cmp dword [cur_app], APP_SETTINGS
    je settings_key
    jmp editor_app_key
.r:
    ret

%include "src/gui_apps.asm"
