APP_NONE    equ 0
APP_TERM    equ 1
APP_EDITOR  equ 2
APP_IDE     equ 3
APP_BROWSER equ 4
APP_SETTINGS equ 5

WIN_X       equ 60
WIN_Y       equ 70

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

    RECT WIN_X - 2, WIN_Y - 2, [win_w], [win_h], 0x6682A0
    add dword [win_w], 4
    sub dword [win_w], 4
    RECT WIN_X, WIN_Y, [win_w], [win_h], 0x12161C

    RECT WIN_X, WIN_Y, [win_w], 26, 0x2C5A82
    mov dword [gfx_scale], 1
    mov eax, [cur_app]
    mov esi, [win_titles + eax * 4]
    TEXT WIN_X + 10, WIN_Y + 6, esi, 0xFFFFFF, -1

    mov ecx, [gfx_w]
    sub ecx, WIN_X - 2
    sub ecx, 24
    mov [gui_close_x], ecx
    RECT ecx, WIN_Y + 4, 18, 18, 0xB03030
    mov esi, close_x
    lea ecx, [ecx + 5]
    TEXT ecx, WIN_Y + 6, close_x, 0xFFFFFF, -1

    mov eax, [cur_app]
    cmp eax, APP_TERM
    je .term
    cmp eax, APP_BROWSER
    je .brow
    cmp eax, APP_SETTINGS
    je .settings

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
section .bss
alignb 4
gui_close_x resd 1
section .text

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

gui_handle:
    pushad
    mov eax, [mouse_btn]
    mov ebx, [prev_btn]
    mov [prev_btn], eax
    test eax, eax
    jz .done
    test ebx, ebx
    jnz .done

    mov eax, [gfx_h]
    sub eax, TASKBAR_H
    cmp [mouse_y], eax
    jae .taskbar

    cmp dword [cur_app], APP_NONE
    je .done
    mov eax, [mouse_x]
    cmp eax, [gui_close_x]
    jb .maybe_content
    mov ecx, [gui_close_x]
    add ecx, 18
    cmp eax, ecx
    ja .maybe_content
    mov eax, [mouse_y]
    cmp eax, WIN_Y + 4
    jb .maybe_content
    cmp eax, WIN_Y + 22
    ja .maybe_content
    mov dword [cur_app], APP_NONE
    jmp .done
.maybe_content:
    call app_click
    jmp .done
.taskbar:
    call gui_taskbar_click
.done:
    popad
    ret

gui_taskbar_click:
    mov eax, [mouse_x]
    mov ecx, [gfx_w]
    sub ecx, 110
    cmp eax, ecx
    jae .quit

    cmp eax, 14 + 8 * 9
    jb .term
    cmp eax, 14 + 8 * 17
    jb .editor
    cmp eax, 14 + 8 * 29
    jb .ide
    cmp eax, 14 + 8 * 38
    jb .browser
    cmp eax, 14 + 8 * 48
    jb .settings
    ret
.settings:
    mov eax, APP_SETTINGS
    jmp gui_open
.term:
    mov eax, APP_TERM
    jmp gui_open
.editor:
    mov eax, APP_EDITOR
    jmp gui_open
.ide:
    mov eax, APP_IDE
    jmp gui_open
.browser:
    mov eax, APP_BROWSER
    jmp gui_open
.quit:
    mov byte [gui_quit], 1
    ret

gui_key:
    cmp dword [cur_app], APP_NONE
    je .r
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
