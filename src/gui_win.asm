; =============================================================================
;  gui_win.asm - the window manager of the MOOS desktop
;
;  Every app has one window. Any number of them can be open at once; they
;  overlap in a stacking order (z_list, bottom first) and the top one has
;  the focus: it gets the keys and a brighter title bar. Windows can be
;    moved      - drag the title bar
;    resized    - drag any edge or corner (the grip in the bottom-right
;                 corner is the easy one to find)
;    maximized  - the middle title-bar button, or double-click the title bar
;    minimized  - the left title-bar button; the taskbar button brings it back
;    closed     - the red x, or Esc
;  Without a mouse the same is done with keys: F1-F5 open or bring up an
;  app, F6 goes to the next window, F7 moves and F8 resizes the focused
;  window with the arrow keys (Enter when done), F9 minimizes and F10
;  maximizes or restores it.
;
;  Apps:
;    1 Terminal   - type commands, see output (runs the real shell commands)
;    2 Editor     - edit a text file
;    3 Script IDE - edit a .ms file and Run it (Run button or Ctrl+R)
;    4 Browser    - a web browser (browser.asm, html.asm)
;    5 Settings   - clock, colours, network
;
;  An app supplies: init (when its window opens), draw (into the content
;  box cb_x/cb_y/cb_w/cb_h, with drawing clipped to it), key, and if it
;  wants them click, hover, wheel and drag.
; =============================================================================
APP_NONE    equ 0
APP_TERM    equ 1
APP_EDITOR  equ 2
APP_IDE     equ 3
APP_BROWSER equ 4
APP_SETTINGS equ 5
NAPPS       equ 5

TITLE_H     equ 28                  ; title bar height
BTN_W       equ 22                  ; title-bar buttons
BTN_H       equ 20
RUN_W       equ 56                  ; the Script IDE's Run button
GRAB        equ 5                   ; how close to an edge starts a resize
GRIP        equ 18                  ; the bottom-right resize corner
MIN_W       equ 320                 ; smallest window
MIN_H       equ 160
KSTEP       equ 16                  ; pixels per arrow key when moving/sizing

WF_OPEN     equ 1                   ; window flags
WF_MIN      equ 2
WF_MAX      equ 4

PART_CONTENT equ 1                  ; what is under the mouse (wm_hit)
PART_TITLE  equ 2
PART_CLOSE  equ 3
PART_MAX    equ 4
PART_MIN    equ 5
PART_RUN    equ 6
PART_EDGE   equ 7
EDGE_L      equ 1
EDGE_R      equ 2
EDGE_T      equ 4
EDGE_B      equ 8

DRAG_NONE   equ 0
DRAG_MOVE   equ 1                   ; dragging a title bar
DRAG_SIZE   equ 2                   ; dragging an edge
DRAG_APP    equ 3                   ; the app asked for the drag (scroll bar)

KM_MOVE     equ 1                   ; keyboard modes (F7 / F8)
KM_SIZE     equ 2

C_WIN_BG    equ 0x12161C

section .bss
alignb 4
cur_app     resd 1                  ; the focused window (APP_NONE if none)
wn_x        resd NAPPS + 1          ; window rectangles, by app
wn_y        resd NAPPS + 1
wn_w        resd NAPPS + 1
wn_h        resd NAPPS + 1
wn_f        resd NAPPS + 1          ; WF_* flags
wn_rx       resd NAPPS + 1          ; the rectangle to restore after
wn_ry       resd NAPPS + 1          ; maximizing
wn_rw       resd NAPPS + 1
wn_rh       resd NAPPS + 1
z_list      resd NAPPS              ; open windows, bottom first
z_n         resd 1
prev_btn    resd 1
drag_mode   resd 1
drag_app    resd 1
drag_edges  resd 1
drag_mx     resd 1                  ; the mouse when the drag started
drag_my     resd 1
drag_lx     resd 1                  ; ... and when last seen
drag_ly     resd 1
drag_x0     resd 1                  ; the window when the drag started
drag_y0     resd 1
drag_w0     resd 1
drag_h0     resd 1
kmode       resd 1                  ; KM_MOVE / KM_SIZE, 0 = off
click_tick  resd 1                  ; the last title-bar click (double-click)
click_app   resd 1
hover_x     resd 1                  ; where the mouse was last seen
hover_y     resd 1
hit_part    resd 1                  ; wm_hit results
hit_edges   resd 1
cb_x        resd 1                  ; content box of the window being drawn
cb_y        resd 1                  ; or clicked
cb_w        resd 1
cb_h        resd 1
wd_app      resd 1                  ; (window being drawn)
wd_btn      resd 1                  ; (left edge of its title-bar buttons)
gui_close_x resd 1
gui_run_x   resd 1

section .data
win_titles  dd 0, t_term, t_edit, t_ide, t_brow, t_set
t_term      db "Terminal", 0
t_edit      db "Text Editor", 0
t_ide       db "Script IDE", 0
t_brow      db "MOOS Browser", 0
t_set       db "Settings", 0
win_def_w   dd 0, 760, 720, 720, 1000, 640     ; first-time sizes
win_def_h   dd 0, 460, 480, 480, 640, 440
close_x     db "x", 0
min_glyph   db "_", 0
run_label   db "Run", 0
km_move_msg db "Moving: arrow keys, Enter when done", 0
km_size_msg db "Resizing: arrow keys, Enter when done", 0

section .text

; ----------------------------------------------------------- bookkeeping
; wm_reset: no windows open (each keeps the place it had, for next time)
wm_reset:
    push ecx
    xor ecx, ecx
.l: mov dword [wn_f + ecx * 4], 0
    inc ecx
    cmp ecx, NAPPS + 1
    jb .l
    mov dword [z_n], 0
    mov dword [cur_app], APP_NONE
    mov dword [drag_mode], DRAG_NONE
    mov dword [kmode], 0
    pop ecx
    ret

; gui_open: EAX = app. Open its window (or bring it to the front if it is
; already open) and give it the focus.
gui_open:
    pushad
    cmp eax, 1
    jb .done
    cmp eax, NAPPS
    ja .done
    test dword [wn_f + eax * 4], WF_OPEN
    jnz .raise
    cmp dword [wn_w + eax * 4], 0
    jne .placed
    call wm_place
.placed:
    mov dword [wn_f + eax * 4], WF_OPEN
    push eax
    call wm_fit                     ; (the screen may be smaller than last time)
    call app_init
    pop eax
.raise:
    call gui_raise
.done:
    or byte [gui_dirty], 1
    popad
    ret

; wm_place: EAX = app -> a first position: cascaded from the top left
wm_place:
    pushad
    mov ebx, eax
    lea ecx, [eax - 1]
    imul ecx, 36
    add ecx, 40
    mov [wn_x + ebx * 4], ecx
    lea edx, [eax - 1]
    imul edx, 30
    add edx, 30
    mov [wn_y + ebx * 4], edx
    mov eax, [win_def_w + ebx * 4]
    mov esi, [gfx_w]                ; no wider than the screen allows
    sub esi, ecx
    sub esi, 40
    cmp eax, esi
    jle .w
    mov eax, esi
.w: mov [wn_w + ebx * 4], eax
    mov eax, [win_def_h + ebx * 4]
    mov esi, [gfx_h]
    sub esi, TASKBAR_H + 20
    sub esi, edx
    cmp eax, esi
    jle .h
    mov eax, esi
.h: mov [wn_h + ebx * 4], eax
    popad
    ret

; wm_fit: EAX = app -> keep its window at least the minimum size, no bigger
; than the desktop, and with its title bar on the screen
wm_fit:
    pushad
    mov ebx, eax
    mov eax, [gfx_w]
    cmp [wn_w + ebx * 4], eax
    jle .w1
    mov [wn_w + ebx * 4], eax
.w1:
    cmp dword [wn_w + ebx * 4], MIN_W
    jge .w2
    mov dword [wn_w + ebx * 4], MIN_W
.w2:
    mov eax, [gfx_h]
    sub eax, TASKBAR_H
    cmp [wn_h + ebx * 4], eax
    jle .h1
    mov [wn_h + ebx * 4], eax
.h1:
    cmp dword [wn_h + ebx * 4], MIN_H
    jge .h2
    mov dword [wn_h + ebx * 4], MIN_H
.h2:
    mov eax, [wn_x + ebx * 4]       ; x: at least 80 pixels of it on screen
    mov ecx, [gfx_w]
    sub ecx, 80
    cmp eax, ecx
    jle .x1
    mov eax, ecx
.x1:
    mov ecx, 80
    sub ecx, [wn_w + ebx * 4]
    cmp eax, ecx
    jge .x2
    mov eax, ecx
.x2:
    mov [wn_x + ebx * 4], eax
    mov eax, [wn_y + ebx * 4]       ; y: the title bar stays reachable
    mov ecx, [gfx_h]
    sub ecx, TASKBAR_H + TITLE_H
    cmp eax, ecx
    jle .y1
    mov eax, ecx
.y1:
    test eax, eax
    jns .y2
    xor eax, eax
.y2:
    mov [wn_y + ebx * 4], eax
    popad
    ret

; gui_raise: EAX = app -> to the top of the stack, shown, focused
gui_raise:
    pushad
    call z_remove
    mov ecx, [z_n]
    mov [z_list + ecx * 4], eax
    inc dword [z_n]
    and dword [wn_f + eax * 4], ~WF_MIN
    mov [cur_app], eax
    or byte [gui_dirty], 1
    popad
    ret

; z_remove: EAX = app -> take it out of z_list (if it is there)
z_remove:
    pushad
    xor ecx, ecx
.find:
    cmp ecx, [z_n]
    jae .done
    cmp [z_list + ecx * 4], eax
    je .found
    inc ecx
    jmp .find
.found:
    dec dword [z_n]
.shift:
    cmp ecx, [z_n]
    jae .done
    mov edx, [z_list + ecx * 4 + 4]
    mov [z_list + ecx * 4], edx
    inc ecx
    jmp .shift
.done:
    popad
    ret

; gui_refocus: the focus goes to the top window that is not minimized
gui_refocus:
    pushad
    mov dword [cur_app], APP_NONE
    mov ecx, [z_n]
.l: test ecx, ecx
    jz .done
    dec ecx
    mov eax, [z_list + ecx * 4]
    test dword [wn_f + eax * 4], WF_MIN
    jnz .l
    mov [cur_app], eax
.done:
    or byte [gui_dirty], 1
    popad
    ret

; gui_close: EAX = app -> close its window
gui_close:
    pushad
    mov dword [wn_f + eax * 4], 0
    call z_remove
    cmp [drag_app], eax
    jne .nd
    mov dword [drag_mode], DRAG_NONE
.nd:
    mov dword [kmode], 0
    call gui_refocus
    popad
    ret

; gui_minimize: EAX = app
gui_minimize:
    or dword [wn_f + eax * 4], WF_MIN
    mov dword [kmode], 0
    jmp gui_refocus

; gui_toggle_max: EAX = app -> maximize it, or put it back as it was
gui_toggle_max:
    pushad
    mov ebx, eax
    test dword [wn_f + ebx * 4], WF_MAX
    jnz .restore
    mov eax, [wn_x + ebx * 4]       ; remember the rectangle
    mov [wn_rx + ebx * 4], eax
    mov eax, [wn_y + ebx * 4]
    mov [wn_ry + ebx * 4], eax
    mov eax, [wn_w + ebx * 4]
    mov [wn_rw + ebx * 4], eax
    mov eax, [wn_h + ebx * 4]
    mov [wn_rh + ebx * 4], eax
    mov dword [wn_x + ebx * 4], 0   ; the whole desktop
    mov dword [wn_y + ebx * 4], 0
    mov eax, [gfx_w]
    mov [wn_w + ebx * 4], eax
    mov eax, [gfx_h]
    sub eax, TASKBAR_H
    mov [wn_h + ebx * 4], eax
    or dword [wn_f + ebx * 4], WF_MAX
    jmp .done
.restore:
    call wm_unmax
.done:
    or byte [gui_dirty], 1
    popad
    ret

; wm_unmax: EBX = app -> back to the rectangle it had before maximizing
wm_unmax:
    push eax
    mov eax, [wn_rx + ebx * 4]
    mov [wn_x + ebx * 4], eax
    mov eax, [wn_ry + ebx * 4]
    mov [wn_y + ebx * 4], eax
    mov eax, [wn_rw + ebx * 4]
    mov [wn_w + ebx * 4], eax
    mov eax, [wn_rh + ebx * 4]
    mov [wn_h + ebx * 4], eax
    and dword [wn_f + ebx * 4], ~WF_MAX
    mov eax, ebx
    call wm_fit
    pop eax
    ret

; wm_content: EAX = app -> cb_x / cb_y / cb_w / cb_h = its content box
wm_content:
    push ecx
    mov ecx, [wn_x + eax * 4]
    inc ecx
    mov [cb_x], ecx
    mov ecx, [wn_y + eax * 4]
    add ecx, TITLE_H + 1
    mov [cb_y], ecx
    mov ecx, [wn_w + eax * 4]
    sub ecx, 2
    mov [cb_w], ecx
    mov ecx, [wn_h + eax * 4]
    sub ecx, TITLE_H + 2
    mov [cb_h], ecx
    pop ecx
    ret

; wm_buttons: EAX = app -> gui_close_x = the close box's left edge (the
; maximize and minimize buttons are left of it), gui_run_x = the Run button
wm_buttons:
    push ecx
    mov ecx, [wn_x + eax * 4]
    add ecx, [wn_w + eax * 4]
    sub ecx, BTN_W + 5
    mov [gui_close_x], ecx
    sub ecx, 2 * (BTN_W + 4) + RUN_W + 8
    mov [gui_run_x], ecx
    pop ecx
    ret

; ------------------------------------------------------------- hit testing
; wm_hit: what is at the mouse? -> EAX = app (APP_NONE: the desktop),
; hit_part = PART_*, hit_edges = EDGE_* for PART_EDGE
wm_hit:
    push ebx
    push ecx
    push edx
    push esi
    mov dword [hit_edges], 0
    mov ecx, [z_n]
.next:
    test ecx, ecx
    jz .none
    dec ecx
    mov eax, [z_list + ecx * 4]
    test dword [wn_f + eax * 4], WF_MIN
    jnz .next
    ; inside the window, or within GRAB pixels outside its edge?
    mov ebx, [mouse_x]
    sub ebx, [wn_x + eax * 4]       ; EBX = x inside the window
    mov edx, [mouse_y]
    sub edx, [wn_y + eax * 4]       ; EDX = y inside the window
    mov esi, -GRAB
    test dword [wn_f + eax * 4], WF_MAX
    jz .g
    xor esi, esi                    ; (maximized: no resizing)
.g:
    cmp ebx, esi
    jl .next
    cmp edx, esi
    jl .next
    neg esi
    add esi, [wn_w + eax * 4]
    cmp ebx, esi
    jge .next
    sub esi, [wn_w + eax * 4]
    add esi, [wn_h + eax * 4]
    cmp edx, esi
    jge .next
    ; found the window. An edge?
    test dword [wn_f + eax * 4], WF_MAX
    jnz .inside
    xor esi, esi
    cmp ebx, GRAB
    jge .e1
    or esi, EDGE_L
.e1:
    mov ecx, [wn_w + eax * 4]
    sub ecx, GRAB
    cmp ebx, ecx
    jl .e2
    or esi, EDGE_R
.e2:
    cmp edx, GRAB
    jge .e3
    or esi, EDGE_T
.e3:
    mov ecx, [wn_h + eax * 4]
    sub ecx, GRAB
    cmp edx, ecx
    jl .e4
    or esi, EDGE_B
.e4:
    mov ecx, [wn_w + eax * 4]       ; the grip in the bottom-right corner
    sub ecx, GRIP
    cmp ebx, ecx
    jl .e5
    mov ecx, [wn_h + eax * 4]
    sub ecx, GRIP
    cmp edx, ecx
    jl .e5
    or esi, EDGE_R | EDGE_B
.e5:
    test esi, esi
    jz .inside
    mov [hit_edges], esi
    mov dword [hit_part], PART_EDGE
    jmp .out
.inside:
    cmp edx, TITLE_H + 1
    jge .content
    call wm_buttons                 ; title bar: a button?
    mov dword [hit_part], PART_TITLE
    mov ecx, [mouse_y]
    sub ecx, [wn_y + eax * 4]
    cmp ecx, 4
    jl .out
    cmp ecx, 4 + BTN_H
    jg .out
    mov ecx, [mouse_x]
    mov esi, [gui_close_x]
    mov ebx, PART_CLOSE
    call .in_btn
    jnc .btn
    sub esi, BTN_W + 4
    mov ebx, PART_MAX
    call .in_btn
    jnc .btn
    sub esi, BTN_W + 4
    mov ebx, PART_MIN
    call .in_btn
    jnc .btn
    cmp eax, APP_IDE
    jne .out
    mov esi, [gui_run_x]
    cmp ecx, esi
    jl .out
    add esi, RUN_W
    cmp ecx, esi
    jge .out
    mov dword [hit_part], PART_RUN
    jmp .out
.btn:
    mov [hit_part], ebx
    jmp .out
.content:
    mov dword [hit_part], PART_CONTENT
    jmp .out
.none:
    xor eax, eax
    mov dword [hit_part], 0
.out:
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret
; .in_btn: ECX = mouse x, ESI = button's left edge -> CF=0 if on it
.in_btn:
    cmp ecx, esi
    jl .no
    push esi
    add esi, BTN_W
    cmp ecx, esi
    pop esi
    jge .no
    clc
    ret
.no:
    stc
    ret

; --------------------------------------------------------------- drawing
; gui_windows: draw every window that is not minimized, bottom first
gui_windows:
    pushad
    xor ecx, ecx
.l: cmp ecx, [z_n]
    jae .done
    mov eax, [z_list + ecx * 4]
    test dword [wn_f + eax * 4], WF_MIN
    jnz .n
    call wm_draw
.n: inc ecx
    jmp .l
.done:
    popad
    ret

; wm_draw: EAX = app -> draw its window: frame, title bar, buttons, content.
; (RECT and TEXT use most registers, so the app is kept in wd_app.)
wm_draw:
    pushad
    mov [wd_app], eax
    mov ebx, eax
    mov eax, 0x4A5560               ; border: brighter when focused
    cmp ebx, [cur_app]
    jne .b
    mov eax, 0x7090B0
.b: call gfx_rgb
    mov ecx, [wn_x + ebx * 4]
    mov edx, [wn_y + ebx * 4]
    mov esi, [wn_w + ebx * 4]
    mov edi, [wn_h + ebx * 4]
    call gfx_fillrect
    mov eax, 0x36414C               ; title bar
    cmp ebx, [cur_app]
    jne .t
    mov eax, 0x2C5A82
.t: call gfx_rgb
    inc ecx
    inc edx
    sub esi, 2
    mov edi, TITLE_H
    call gfx_fillrect
    ; buttons, right to left: close, maximize, minimize (and Run)
    mov eax, ebx
    call wm_buttons
    mov eax, [gui_close_x]
    mov [wd_btn], eax
    mov eax, 0xB03030
    call wd_button
    mov ecx, [wd_btn]
    add ecx, 7
    call wd_btn_y
    add edx, 2
    TEXT ecx, edx, close_x, 0xFFFFFF, -1
    sub dword [wd_btn], BTN_W + 4   ; maximize: a square, two when maximized
    mov eax, 0x3E6A8E
    call wd_button
    mov ebx, [wd_app]
    test dword [wn_f + ebx * 4], WF_MAX
    jnz .two
    mov ecx, [wd_btn]
    add ecx, 6
    call wd_btn_y
    add edx, 5
    mov eax, 0xFFFFFF
    call wd_box10
    jmp .min
.two:
    mov ecx, [wd_btn]
    add ecx, 8
    call wd_btn_y
    add edx, 3
    mov eax, 0xFFFFFF
    call wd_box8
    mov ecx, [wd_btn]
    add ecx, 5
    call wd_btn_y
    add edx, 7
    mov eax, 0xFFFFFF
    call wd_box8
.min:
    sub dword [wd_btn], BTN_W + 4   ; minimize: a bar at the bottom
    mov eax, 0x3E6A8E
    call wd_button
    mov ecx, [wd_btn]
    add ecx, 6
    call wd_btn_y
    add edx, 13
    RECT ecx, edx, 10, 2, 0xFFFFFF
    mov ebx, [wd_app]
    cmp ebx, APP_IDE                ; the Script IDE's Run button
    jne .no_run
    mov eax, [gui_run_x]
    mov [wd_btn], eax
    call wd_btn_y
    RECT [gui_run_x], edx, RUN_W, BTN_H, 0x2E7D4F
    mov ecx, [gui_run_x]
    add ecx, 16
    call wd_btn_y
    add edx, 2
    TEXT ecx, edx, run_label, 0xFFFFFF, -1
.no_run:
    ; the title, cut off before the buttons
    mov ebx, [wd_app]
    mov ecx, [wn_x + ebx * 4]
    mov edx, [wn_y + ebx * 4]
    mov esi, [wd_btn]
    sub esi, ecx
    sub esi, 6
    mov edi, TITLE_H
    call gfx_clip_set
    mov dword [gfx_scale], 1
    mov eax, ebx
    call app_title                  ; ESI = the title
    cmp ebx, [cur_app]
    jne .tt
    cmp dword [kmode], KM_MOVE      ; F7 / F8: say what the keys do now
    jne .tk
    mov esi, km_move_msg
.tk:
    cmp dword [kmode], KM_SIZE
    jne .tt
    mov esi, km_size_msg
.tt:
    add ecx, 10
    add edx, 7
    TEXT ecx, edx, esi, 0xFFFFFF, -1
    call gfx_clip_full
    ; the content, drawn by the app inside its box
    mov eax, [wd_app]
    call wm_content
    RECT [cb_x], [cb_y], [cb_w], [cb_h], C_WIN_BG
    mov ecx, [cb_x]
    mov edx, [cb_y]
    mov esi, [cb_w]
    mov edi, [cb_h]
    call gfx_clip_set
    mov eax, [wd_app]
    call app_draw
    call gfx_clip_full
    ; the resize grip: a triangle of dots in the bottom-right corner
    mov ebx, [wd_app]
    test dword [wn_f + ebx * 4], WF_MAX
    jnz .done
    mov eax, 0x8A9AAA
    call gfx_rgb
    xor ebp, ebp
.grip:
    mov ecx, [wn_x + ebx * 4]
    add ecx, [wn_w + ebx * 4]
    movsx esi, byte [grip_dots + ebp * 2]
    sub ecx, esi
    mov edx, [wn_y + ebx * 4]
    add edx, [wn_h + ebx * 4]
    movsx esi, byte [grip_dots + ebp * 2 + 1]
    sub edx, esi
    mov esi, 2
    mov edi, 2
    call gfx_fillrect
    inc ebp
    cmp ebp, 6
    jb .grip
.done:
    popad
    ret

; wd_button: a title-bar button of colour EAX at wd_btn
wd_button:
    pushad
    push eax
    call wd_btn_y
    pop eax
    RECT [wd_btn], edx, BTN_W, BTN_H, eax
    popad
    ret

; wd_btn_y: EDX = the top of the title-bar buttons of window wd_app
wd_btn_y:
    push eax
    mov eax, [wd_app]
    mov edx, [wn_y + eax * 4]
    add edx, 4
    pop eax
    ret

; wd_box10 / wd_box8: a window symbol (outline, thick top) at ECX, EDX in
; colour EAX; the 8-pixel one is filled with the button colour first
wd_box10:
    pushad
    mov esi, 10
    mov edi, 10
    jmp wd_box
wd_box8:
    pushad
    push eax
    mov eax, 0x3E6A8E
    call gfx_rgb
    mov esi, 8
    mov edi, 8
    call gfx_fillrect
    pop eax
wd_box:
    call gfx_rgb
    call gfx_frame
    mov edi, 2
    call gfx_fillrect
    popad
    ret

section .data
grip_dots   db 4, 4, 8, 4, 12, 4, 4, 8, 8, 8, 4, 12   ; from the corner
section .text

; ------------------------------------------------- the app interface
; app_init / app_draw / app_title: EAX = app
app_init:
    cmp eax, APP_TERM
    je term_init
    cmp eax, APP_EDITOR
    je editor_app_init
    cmp eax, APP_IDE
    je editor_app_init
    cmp eax, APP_BROWSER
    je brow_init
    cmp eax, APP_SETTINGS
    je settings_init
    ret

app_draw:
    cmp eax, APP_TERM
    je app_term_draw
    cmp eax, APP_BROWSER
    je app_brow_draw
    cmp eax, APP_SETTINGS
    je settings_draw
    jmp app_text_draw               ; editor / IDE share the text view

; app_title: EAX = app -> ESI = the text for its title bar
app_title:
    cmp eax, APP_BROWSER
    je brow_title
    mov esi, [win_titles + eax * 4]
    ret

; app_click: EAX = app, the mouse is in its content (cb_* set)
app_click:
    cmp eax, APP_BROWSER
    je brow_click
    cmp eax, APP_SETTINGS
    je settings_click
    ret

; app_key: EAX = key, for the focused app
app_key:
    cmp dword [cur_app], APP_TERM
    je term_key
    cmp dword [cur_app], APP_BROWSER
    je brow_key
    cmp dword [cur_app], APP_SETTINGS
    je settings_key
    jmp editor_app_key

; ---------------------------------------------------------- the mouse
; gui_handle: called every round: clicks, drags, hovering
gui_handle:
    pushad
    mov eax, [mouse_btn]
    mov ebx, [prev_btn]
    mov [prev_btn], eax
    test eax, eax
    jz .up
    test ebx, ebx
    jz .press
    call wm_drag                    ; held down: carry on dragging
    jmp .done
.up:
    test ebx, ebx
    jz .hover
    mov dword [drag_mode], DRAG_NONE ; let go
    jmp .done
.hover:
    call wm_hover
    jmp .done
.press:
    or byte [gui_dirty], 1
    mov dword [kmode], 0
    mov eax, [gfx_h]                ; the taskbar?
    sub eax, TASKBAR_H
    cmp [mouse_y], eax
    jae .taskbar
    call wm_hit
    test eax, eax
    jz .desktop
    mov ebx, eax
    call gui_raise
    mov ecx, [hit_part]
    cmp ecx, PART_CLOSE
    je .close
    cmp ecx, PART_MAX
    je .max
    cmp ecx, PART_MIN
    je .min
    cmp ecx, PART_RUN
    je .run
    cmp ecx, PART_TITLE
    je .title
    cmp ecx, PART_EDGE
    je .edge
    call wm_content                 ; the content: up to the app
    call app_click
    jmp .done
.close:
    call gui_close
    jmp .done
.max:
    call gui_toggle_max
    jmp .done
.min:
    call gui_minimize
    jmp .done
.run:
    call ide_run
    jmp .done
.title:
    mov ecx, [ticks]                ; a double click maximizes / restores
    mov edx, ecx
    sub edx, [click_tick]
    mov [click_tick], ecx
    cmp ebx, [click_app]
    mov [click_app], ebx
    jne .move
    cmp edx, 50                     ; (half a second)
    ja .move
    mov dword [click_tick], 0
    call gui_toggle_max
    jmp .done
.move:
    test dword [wn_f + ebx * 4], WF_MAX
    jz .move2
    ; dragging a maximized window: it takes its old size back, and stays
    ; under the mouse at the same fraction of its width
    mov eax, [mouse_x]
    imul eax, [wn_rw + ebx * 4]
    cdq
    idiv dword [gfx_w]
    neg eax
    add eax, [mouse_x]
    mov [wn_rx + ebx * 4], eax
    mov dword [wn_ry + ebx * 4], 0
    call wm_unmax
.move2:
    mov dword [drag_mode], DRAG_MOVE
    jmp .start
.edge:
    mov eax, [hit_edges]
    mov [drag_edges], eax
    mov dword [drag_mode], DRAG_SIZE
.start:
    mov [drag_app], ebx
    call wm_drag_start
    jmp .done
.desktop:
    mov dword [cur_app], APP_NONE   ; nothing has the focus now
    jmp .done
.taskbar:
    call gui_taskbar_click
.done:
    popad
    ret

; wm_drag_start: EBX = app -> remember the mouse and the window
wm_drag_start:
    push eax
    mov eax, [mouse_x]
    mov [drag_mx], eax
    mov [drag_lx], eax
    mov eax, [mouse_y]
    mov [drag_my], eax
    mov [drag_ly], eax
    mov eax, [wn_x + ebx * 4]
    mov [drag_x0], eax
    mov eax, [wn_y + ebx * 4]
    mov [drag_y0], eax
    mov eax, [wn_w + ebx * 4]
    mov [drag_w0], eax
    mov eax, [wn_h + ebx * 4]
    mov [drag_h0], eax
    pop eax
    ret

; wm_drag: the button is held; if the mouse moved, move or resize the
; window being dragged (or let the app follow its own drag)
wm_drag:
    pushad
    cmp dword [drag_mode], DRAG_NONE
    je .done
    mov eax, [mouse_x]
    cmp eax, [drag_lx]
    jne .moved
    mov eax, [mouse_y]
    cmp eax, [drag_ly]
    je .done
.moved:
    mov eax, [mouse_x]
    mov [drag_lx], eax
    mov eax, [mouse_y]
    mov [drag_ly], eax
    mov ebx, [drag_app]
    mov ecx, [mouse_x]
    sub ecx, [drag_mx]              ; ECX, EDX = how far it moved
    mov edx, [mouse_y]
    sub edx, [drag_my]
    cmp dword [drag_mode], DRAG_APP
    je .app
    cmp dword [drag_mode], DRAG_MOVE
    jne .size
    mov eax, [drag_x0]
    add eax, ecx
    mov [wn_x + ebx * 4], eax
    mov eax, [drag_y0]
    add eax, edx
    mov [wn_y + ebx * 4], eax
    jmp .fit
.size:
    call wm_resize_by
.fit:
    mov eax, ebx
    call wm_fit
    or byte [gui_dirty], 1
    jmp .done
.app:
    mov eax, ebx
    call wm_content
    cmp eax, APP_BROWSER
    jne .done
    call brow_drag
.done:
    popad
    ret

; wm_resize_by: EBX = app, ECX/EDX = how far the mouse moved since the drag
; started -> the window's new rectangle, from the edges being dragged.
; The opposite edges stay where they are, also at the minimum size.
wm_resize_by:
    pushad
    test dword [drag_edges], EDGE_R
    jz .nr
    mov eax, [drag_w0]
    add eax, ecx
    call .minw
    mov [wn_w + ebx * 4], eax
.nr:
    test dword [drag_edges], EDGE_L
    jz .nl
    mov eax, [drag_w0]
    sub eax, ecx
    call .minw
    mov [wn_w + ebx * 4], eax
    neg eax                         ; x = old right edge - new width
    add eax, [drag_x0]
    add eax, [drag_w0]
    mov [wn_x + ebx * 4], eax
.nl:
    test dword [drag_edges], EDGE_B
    jz .nb
    mov eax, [drag_h0]
    add eax, edx
    call .minh
    mov [wn_h + ebx * 4], eax
.nb:
    test dword [drag_edges], EDGE_T
    jz .nt
    mov eax, [drag_y0]              ; (the top edge stays on the screen)
    add eax, edx
    jns .ty
    sub edx, eax
.ty:
    mov eax, [drag_h0]
    sub eax, edx
    call .minh
    mov [wn_h + ebx * 4], eax
    neg eax
    add eax, [drag_y0]
    add eax, [drag_h0]
    mov [wn_y + ebx * 4], eax
.nt:
    popad
    ret
.minw:
    cmp eax, MIN_W
    jge .r
    mov eax, MIN_W
    ret
.minh:
    cmp eax, MIN_H
    jge .r
    mov eax, MIN_H
.r: ret

; wm_hover: no button held: tell the app under the mouse where it is (the
; browser shows the link under it)
wm_hover:
    pushad
    mov eax, [mouse_x]
    cmp eax, [hover_x]
    jne .moved
    mov eax, [mouse_y]
    cmp eax, [hover_y]
    je .done
.moved:
    mov eax, [mouse_x]
    mov [hover_x], eax
    mov eax, [mouse_y]
    mov [hover_y], eax
    call wm_hit
    cmp eax, APP_BROWSER
    jne .off
    cmp dword [hit_part], PART_CONTENT
    jne .off
    call wm_content
    call brow_hover
    jmp .done
.off:
    test dword [wn_f + APP_BROWSER * 4], WF_OPEN
    jz .done
    call brow_unhover               ; (left the browser)
.done:
    popad
    ret

; gui_wheel: hand mouse-wheel turns to the window under the mouse
gui_wheel:
    pushad
    mov ecx, [mouse_wheel]
    test ecx, ecx
    jz .done
    mov dword [mouse_wheel], 0
    call wm_hit
    cmp eax, APP_BROWSER
    jne .done
    call wm_content
    mov eax, ecx
    call brow_wheel
    or byte [gui_dirty], 1
.done:
    popad
    ret

; gui_taskbar_click: a taskbar button opens its app, brings it up, or
; minimizes it if it already has the focus. Quit leaves the desktop.
gui_taskbar_click:
    call tb_hit
    cmp eax, TB_QUIT
    je .quit
    test eax, eax
    js .r
    inc eax                         ; button 0 is app 1 (Terminal), ...
    cmp eax, [cur_app]
    jne gui_open
    jmp gui_minimize
.quit:
    mov byte [gui_quit], 1
.r: ret

; ------------------------------------------------------------- the keys
; gui_key: EAX = key. Window keys first (F1-F10, Esc, and the arrows while
; moving or resizing with F7 / F8), the rest to the focused app. On the
; empty desktop 1-5 open the apps too.
gui_key:
    pushad
    cmp dword [kmode], 0
    jne .kmode
    cmp eax, 27                     ; Esc: close the window, or leave
    je .esc
    cmp eax, KEY_F1
    jb .notf
    cmp eax, KEY_F1 + 4
    jbe .launch
    cmp eax, KEY_F1 + 5
    je .next
    cmp eax, KEY_F1 + 6
    je .kmove
    cmp eax, KEY_F1 + 7
    je .ksize
    cmp eax, KEY_F1 + 8
    je .kmin
    cmp eax, KEY_F1 + 9
    je .kmax
    jmp .done
.notf:
    cmp dword [cur_app], APP_NONE
    jne .app
    cmp eax, '1'
    jb .done
    cmp eax, '5'
    ja .done
    sub eax, '0'                    ; '1' -> APP_TERM ... '5' -> APP_SETTINGS
    call gui_open
    jmp .done
.app:
    call app_key
    jmp .done
.launch:
    sub eax, KEY_F1 - 1
    call gui_open
    jmp .done
.esc:
    mov eax, [cur_app]
    cmp eax, APP_NONE
    je .leave
    call gui_close
    jmp .done
.leave:
    mov byte [gui_quit], 1
    jmp .done
.next:                              ; F6: the bottom window comes to the top
    cmp dword [z_n], 0
    je .done
    mov eax, [z_list]
    call gui_raise
    jmp .done
.kmove:
    mov ecx, KM_MOVE
    jmp .kstart
.ksize:
    mov ecx, KM_SIZE
.kstart:
    mov ebx, [cur_app]
    cmp ebx, APP_NONE
    je .done
    test dword [wn_f + ebx * 4], WF_MAX
    jz .ks
    call wm_unmax
.ks:
    mov [kmode], ecx
    jmp .done
.kmin:
    mov eax, [cur_app]
    cmp eax, APP_NONE
    je .done
    call gui_minimize
    jmp .done
.kmax:
    mov eax, [cur_app]
    cmp eax, APP_NONE
    je .done
    call gui_toggle_max
    jmp .done
.kmode:                             ; F7 / F8: arrows move or resize
    mov ebx, [cur_app]
    cmp ebx, APP_NONE
    je .kend
    xor ecx, ecx                    ; ECX, EDX = the step
    xor edx, edx
    cmp eax, KEY_LEFT
    jne .k1
    mov ecx, -KSTEP
.k1:
    cmp eax, KEY_RIGHT
    jne .k2
    mov ecx, KSTEP
.k2:
    cmp eax, KEY_UP
    jne .k3
    mov edx, -KSTEP
.k3:
    cmp eax, KEY_DOWN
    jne .k4
    mov edx, KSTEP
.k4:
    mov esi, ecx
    or esi, edx
    jz .kend                        ; any other key: done
    cmp dword [kmode], KM_SIZE
    je .ksz
    add [wn_x + ebx * 4], ecx
    add [wn_y + ebx * 4], edx
    jmp .kfit
.ksz:
    add [wn_w + ebx * 4], ecx
    add [wn_h + ebx * 4], edx
.kfit:
    mov eax, ebx
    call wm_fit
    jmp .done
.kend:
    mov dword [kmode], 0
.done:
    or byte [gui_dirty], 1
    popad
    ret

%include "src/gui_apps.asm"
%include "src/html.asm"
%include "src/browser.asm"
