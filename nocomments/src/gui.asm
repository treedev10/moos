TASKBAR_H   equ 34

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

%macro RECT 5
    mov ecx, %1
    mov edx, %2
    mov esi, %3
    mov edi, %4
    mov eax, %5
    call gfx_rgb
    call gfx_fillrect
%endmacro

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
wp_ox       resd 1
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
tb_apps     db "Terminal   Editor   Script IDE   Browser              Quit", 0

section .text

gui_wallpaper:
    pushad
    mov eax, [gfx_h]
    sub eax, TASKBAR_H
    mov [gw_usable], eax
    shr eax, 2
    mov [gw_band], eax
    imul eax, 3
    mov [gw_horizon], eax

    mov edx, 0
    RECT 0, edx, [gfx_w], [gw_band], 0x101830
    mov edx, [gw_band]
    RECT 0, edx, [gfx_w], [gw_band], 0x1B2A55
    mov edx, [gw_band]
    add edx, [gw_band]
    RECT 0, edx, [gfx_w], [gw_band], 0x2E4C86

    mov edx, [gw_horizon]
    mov edi, [gw_usable]
    sub edi, edx
    RECT 0, edx, [gfx_w], edi, 0x24401E

    mov ecx, [gfx_w]
    sub ecx, 180
    RECT ecx, 70, 70, 70, 0xF0E6B0

    mov dword [wp_ox], 0
    mov dword [wp_oy], 0
    mov esi, [gw_horizon]
    mov ebx, esi
    sub ebx, 150
    TRI 0, esi, 300, ebx, 560, esi, 0x3A5540
    mov esi, [gw_horizon]
    mov eax, [gfx_w]
    shr eax, 1
    add eax, 120
    mov ecx, eax
    add ecx, 180
    mov ebx, esi
    sub ebx, 210
    mov edx, [gfx_w]
    TRI eax, esi, ecx, ebx, edx, esi, 0x33503A

    mov eax, [gfx_w]
    shr eax, 1
    sub eax, 150
    mov [wp_ox], eax
    mov eax, [gw_horizon]
    sub eax, 180
    mov [wp_oy], eax
    call gui_moose

    mov dword [gfx_scale], 3
    TEXT 40, 30, gui_title, 0xFFFFFF, -1
    mov dword [gfx_scale], 1
    TEXT 40, 78, gui_sub, 0xC8D0E0, -1
    popad
    ret

section .bss
alignb 4
gw_band    resd 1
gw_usable  resd 1
gw_horizon resd 1
section .text

gui_moose:
    push eax

    TRI 70,70, 210,60, 200,120, 0x4A3220
    TRI 70,70, 200,120, 80,120, 0x543922

    TRI 60,72, 95,118, 60,120, 0x3E2A1B

    TRI 200,70, 230,70, 210,120, 0x4A3220

    TRI 205,72, 250,40, 232,86, 0x543922

    TRI 238,30, 272,44, 236,70, 0x5C4026

    TRI 236,56, 272,58, 244,74, 0x6B4A2C

    TRI 236,30, 250,18, 248,40, 0x4A3220

    TRI 240,30, 232,2, 250,22, 0xC8A878
    TRI 232,2, 214,10, 240,20, 0xC8A878
    TRI 250,30, 266,4, 256,24, 0xC8A878
    TRI 266,4, 282,14, 258,20, 0xC8A878

    RECT_OFF 196,116, 12,70, 0x3E2A1B
    RECT_OFF 214,116, 12,70, 0x3E2A1B
    RECT_OFF 78,116, 12,70, 0x3E2A1B
    RECT_OFF 96,116, 12,70, 0x3E2A1B

    RECT_OFF 250,46, 5,5, 0x101010
    pop eax
    ret

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

    call rtc_read
    call gui_clock_str
    mov ecx, [gfx_w]
    sub ecx, 150
    TEXT ecx, edx, gui_clockbuf, 0xB7E27A, -1
    popad
    ret

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

cmd_gui:
    cmp dword [bootinfo + BI.platform], PLATFORM_UEFI
    je .ok
    PRINTF `The graphical desktop needs a UEFI PC (it draws on a graphics\nscreen). This computer started from a BIOS, so only the text\nconsole is available.\n`
    ret
.ok:
    mov esi, desktop_marker
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
    cmp dword [argc], 2
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
    call gui_windows
    call gui_taskbar
    call gui_cursor
    call gfx_present
    call efi_mouse_poll
    call gui_handle
    call kbd_poll
    test eax, eax
    jz .loop
    cmp eax, 27
    je .exit
    call gui_key
    cmp byte [gui_quit], 0
    je .loop
.exit:

    call gui_restore_console
    ret

gui_restore_console:
    pushad
    mov edi, screen_drawn
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
