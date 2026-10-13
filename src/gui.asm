; =============================================================================
;  gui.asm - the MOOS desktop (UEFI graphics only)
;
;  A simple desktop: a low-poly moose wallpaper, a taskbar with a clock and
;  app buttons, a mouse cursor, and windows for the built-in apps (terminal,
;  text editor, script IDE, and a tiny web viewer). Drawn with gfx.asm into a
;  back buffer and presented each frame. Esc or the Quit button leaves it.
; =============================================================================
TASKBAR_H   equ 34

; TRI x0,y0,x1,y1,x2,y2,rgb  - a filled triangle, offset by wp_ox/wp_oy
%macro TRI 7
    mov eax, %1
    add eax, [wp_ox]
    mov [tri_px + 0], eax
    mov eax, %2
    add eax, [wp_oy]
    mov [tri_py + 0], eax
    mov eax, %3
    add eax, [wp_ox]
    mov [tri_px + 4], eax
    mov eax, %4
    add eax, [wp_oy]
    mov [tri_py + 4], eax
    mov eax, %5
    add eax, [wp_ox]
    mov [tri_px + 8], eax
    mov eax, %6
    add eax, [wp_oy]
    mov [tri_py + 8], eax
    mov eax, %7
    call gfx_rgb
    call gfx_tri
%endmacro

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

DEER_CX equ 220                     ; centre line of the stag within its box

; DTM x0,y0,x1,y1,x2,y2,rgb - a triangle and its mirror about DEER_CX, so the
; stag is drawn once on the right and comes out symmetric.
%macro DTM 7
    TRI %1, %2, %3, %4, %5, %6, %7
    TRI (2*DEER_CX-%1), %2, (2*DEER_CX-%3), %4, (2*DEER_CX-%5), %6, %7
%endmacro

; RECT_OFF x,y,w,h,rgb  - a rectangle offset by wp_ox/wp_oy (for the moose)
%macro RECT_OFF 5
    mov ecx, %1
    add ecx, [wp_ox]
    mov edx, %2
    add edx, [wp_oy]
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
wp_ox       resd 1              ; wallpaper / moose origin
wp_oy       resd 1
gui_quit    resb 1

section .data
desktop_marker db "desktop.inst", 0
gui_title   db "MOOS", 0
gui_sub     db "Mightily Optimized Operating System", 0
ga_term     db "term", 0
ga_editor   db "editor", 0
ga_ide      db "ide", 0
ga_browser  db "browser", 0
ga_settings db "settings", 0
tb_apps     db "Terminal  Editor  Script IDE  Browser  Settings       Quit", 0

section .text

; ------------------------------------------------------------- wallpaper
gui_wallpaper:
    pushad
    mov eax, [gfx_h]
    sub eax, TASKBAR_H
    mov [gw_usable], eax
    xor edx, edx                    ; coloured background: six teal/blue bands
    mov esi, [gw_usable]
    mov edi, 6
    push edi
    mov eax, esi
    xor edx, edx
    mov ecx, 6
    div ecx
    mov [gw_band], eax
    pop edi
    xor edx, edx
    RECT 0, edx, [gfx_w], [gw_band], 0x0B1E2A
    mov edx, [gw_band]
    RECT 0, edx, [gfx_w], [gw_band], 0x0F2838
    add edx, [gw_band]
    RECT 0, edx, [gfx_w], [gw_band], 0x133448
    add edx, [gw_band]
    RECT 0, edx, [gfx_w], [gw_band], 0x184258
    add edx, [gw_band]
    RECT 0, edx, [gfx_w], [gw_band], 0x1E5266
    add edx, [gw_band]
    mov edi, [gw_usable]
    sub edi, edx
    RECT 0, edx, [gfx_w], edi, 0x236074
    ; the stag, centred
    mov eax, [gfx_w]
    shr eax, 1
    sub eax, DEER_CX
    mov [wp_ox], eax
    mov eax, [gw_usable]
    sub eax, 450
    sar eax, 1
    cmp eax, 20
    jge .oy_ok
    mov eax, 20
.oy_ok:
    mov [wp_oy], eax
    call gui_deer
    ; title
    mov dword [gfx_scale], 3
    TEXT 40, 26, gui_title, 0xF4F0E6, -1
    mov dword [gfx_scale], 1
    TEXT 40, 74, gui_sub, 0xBFE0DF, -1
    popad
    ret

section .bss
alignb 4
gw_band    resd 1
gw_usable  resd 1
gw_horizon resd 1
section .text

; ------------------------------------------------------- the stag wallpaper
; A front-facing low-poly stag head, built from triangles. The right half is
; drawn and mirrored to the left about the centre line (DEER_CX) by DTM, so it
; stays symmetric. Box ~380 wide x 460 tall at wp_ox/wp_oy. Coloured facets.
;
; palette
%define C_ANTLER1 0x202E3A
%define C_ANTLER2 0x3A5262
%define C_ANTLER3 0x6E4A2C
%define C_DARK    0x111C28
%define C_NAVY    0x1B3346
%define C_TEAL    0x2E6E7A
%define C_BROWN   0x6E4A2C
%define C_TAN     0x9A6A3A
%define C_CREAM   0xD8C4A0
gui_deer:
    push eax
    ; ---- antlers: bold spreading tines (right side; DTM mirrors to the left)
    DTM 258,164, 300,150, 250,30,  C_ANTLER1
    DTM 270,156, 314,150, 340,26,  C_ANTLER2
    DTM 282,160, 324,152, 412,54,  C_ANTLER1
    DTM 294,168, 332,158, 436,114, C_ANTLER2
    DTM 302,178, 338,170, 416,182, C_ANTLER1
    DTM 258,166, 300,150, 300,108, C_ANTLER1
    DTM 254,172, 294,150, 306,186, C_ANTLER2
    ; ---- ears (wide) ----
    DTM 150,204, 110,190, 150,256, C_BROWN
    DTM 150,210, 150,256, 186,236, C_TAN
    ; ---- forehead (dark, broad) ----
    DTM 220,116, 150,176, 220,214, C_DARK
    DTM 220,116, 220,214, 284,166, C_NAVY
    ; ---- cheeks (wide) ----
    DTM 150,176, 220,214, 138,252, C_NAVY
    DTM 138,252, 220,214, 210,330, C_BROWN
    DTM 220,214, 266,244, 210,330, C_TEAL
    DTM 138,252, 210,330, 170,372, C_TAN
    ; ---- jaw narrowing to a short chin point ----
    DTM 170,372, 210,330, 220,432, C_NAVY
    DTM 170,372, 220,432, 206,392, C_DARK
    ; ---- eyes (small, dark, angled) ----
    DTM 162,250, 186,262, 166,280, C_DARK
    ; ---- muzzle centre: cream highlight stripe ----
    DTM 220,258, 198,330, 220,326, C_TAN
    DTM 220,326, 202,352, 220,398, C_CREAM
    DTM 220,326, 220,398, 238,352, C_TAN
    DTM 220,352, 208,370, 220,392, C_DARK
    pop eax
    ret

; ---------------------------------------------------------------- cursor
gui_cursor:
    pushad
    mov dword [wp_ox], 0
    mov dword [wp_oy], 0
    mov eax, [mouse_x]
    mov [gc_mx], eax
    mov eax, [mouse_y]
    mov [gc_my], eax
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
section .bss
alignb 4
gc_mx resd 1
gc_my resd 1
section .text

; ---------------------------------------------------------------- taskbar
gui_taskbar:
    pushad
    mov edx, [gfx_h]
    sub edx, TASKBAR_H
    RECT 0, edx, [gfx_w], TASKBAR_H, 0x202830
    add edx, 2
    RECT 0, edx, [gfx_w], 2, 0x4A5A6A
    add edx, 8
    mov dword [gfx_scale], 1
    TEXT 14, edx, tb_apps, 0xDDE4EC, -1
    ; clock on the right
    call rtc_read
    call gui_clock_str
    mov ecx, [gfx_w]
    sub ecx, 150
    TEXT ecx, edx, gui_clockbuf, 0xB7E27A, -1
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
    call efi_mouse_init
    mov byte [gui_quit], 0
    mov dword [cur_app], APP_NONE
    cmp dword [argc], 2             ; "gui <app>" opens straight into an app
    jb .loop
    mov esi, [argv + 4]
    mov edi, ga_term
    call str_icmp
    je .o_term
    mov edi, ga_editor
    call str_icmp
    je .o_edit
    mov edi, ga_ide
    call str_icmp
    je .o_ide
    mov edi, ga_browser
    call str_icmp
    je .o_brow
    mov edi, ga_settings
    call str_icmp
    je .o_set
    jmp .loop
.o_set:
    mov eax, APP_SETTINGS
    call gui_open
    jmp .loop
.o_term:
    mov eax, APP_TERM
    call gui_open
    jmp .loop
.o_edit:
    mov eax, APP_EDITOR
    call gui_open
    jmp .loop
.o_ide:
    mov eax, APP_IDE
    call gui_open
    jmp .loop
.o_brow:
    mov eax, APP_BROWSER
    call gui_open
.loop:
    call gui_wallpaper
    call gui_windows                ; draw any open windows
    call gui_taskbar
    call gui_cursor
    call gfx_present
    call efi_mouse_poll
    call gui_handle                 ; mouse clicks
    call kbd_poll
    test eax, eax
    jz .loop
    cmp eax, 27                     ; Esc quits
    je .exit
    call gui_key                    ; hand the key to the focused window
    cmp byte [gui_quit], 0
    je .loop
.exit:
    ; return to the text console
    call gui_restore_console
    ret

gui_restore_console:
    pushad
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
