; =============================================================================
;  gui_desk.asm - the Start menu, desktop icons and the Files app
;
;  Start menu: the "Start" button at the left end of the taskbar, F12 or
;  Ctrl+Esc. It lists the apps (start_menu below: one MI line per app, so
;  another app is one more line), YouTube, and Leave desktop / Restart /
;  Shut down.
;
;  Icons: the desktop shows what is in the MOOSFS folder "desktop" (made
;  the first time something is created on the desktop), and the Files app
;  shows any one folder, both as a grid of icons - a folder or a page drawn
;  with rectangles, the name below. Both are "icon views" (IV_DESK and
;  IV_FILES) and share all of this:
;    left click      select (a highlight); a click on nothing deselects
;    double click    open: a file in the Text Editor, a folder in Files
;    right click     a menu: on an icon Open / Rename / Delete / Properties,
;                    elsewhere New folder / New text file / Open Terminal /
;                    Refresh / Desktop colour...
;    keys            arrows move the selection, Enter opens, F2 renames,
;                    Delete deletes, Shift+F10 opens the menu
;  New folder / New text file make "folder" / "file.txt" (or "folder-2",
;  "file-2.txt", ... if taken) and start renaming it at once: the label
;  becomes an edit box with the whole name selected.
;
;  The list of icons is read again from the directory every time it is
;  drawn or clicked (32 entries at most), so what the Terminal does to the
;  files shows up straight away. The selection is kept as an entry number.
;
;  Menu items do their work in gui_action (ACT_* numbers); what they work
;  on (the view and the icon) is noted in ctx_view / ctx_entry when the
;  menu opens.
; =============================================================================
IV_DESK     equ 0                   ; the icon views
IV_FILES    equ 1
CELL_W      equ 96                  ; one icon with its name
CELL_H      equ 84
LBL_MAX     equ 11                  ; characters of a name shown under an icon
RN_W        equ FS_NAME_MAX * 8 + 12    ; the rename box: at most this wide
RN_H        equ 20
DC_TICKS    equ 50                  ; a double click: within half a second
FT_H        equ 36                  ; the Files app: toolbar height,
FB_H        equ 22                  ; status line height,
FBTN_H      equ 24                  ; toolbar button height
FSB_W        equ 8                   ; scroll bar width
TB_START    equ 99                  ; tb_hit: the Start button
START_X     equ 4
START_W     equ 84

ACT_YOUTUBE equ 1                   ; menu actions (gui_action)
ACT_LEAVE   equ 2
ACT_RESTART equ 3
ACT_SHUTDOWN equ 4
ACT_NEWDIR  equ 5
ACT_NEWFILE equ 6
ACT_REFRESH equ 7
ACT_COLOUR  equ 8
ACT_OPEN    equ 9
ACT_RENAME  equ 10
ACT_DELETE  equ 11
ACT_PROPS   equ 12
ACT_DEL_YES equ 13
ACT_LAST    equ 13
ACT_APP     equ 100                 ; ACT_APP + app number: open that app

section .bss
alignb 4
iv_folder   resd 2                  ; per view: the folder shown (index + 1,
                                    ; 0 = top level, -1 = none yet)
iv_n        resd 2                  ; how many icons
iv_sel      resd 2                  ; the selected entry, -1 = none
iv_x        resd 2                  ; the area the icons go in
iv_y        resd 2
iv_w        resd 2
iv_h        resd 2
iv_cols     resd 2                  ; how many fit across / down
iv_rows     resd 2
iv_scroll   resd 2                  ; the first row shown (Files)
iv_cm       resd 2                  ; 1 = fill columns first (the desktop)
iv_list     resb 2 * FS_MAX_FILES   ; the entries shown, in order
iv_v        resd 1                  ; (drawing: the view, the icon,
iv_p        resd 1                  ; its entry and cell, its label)
iv_e        resd 1
iv_cx       resd 1
iv_cy       resd 1
iv_lx       resd 1
iv_ly       resd 1
ic_x        resd 1                  ; (icon_draw)
ic_y        resd 1
ctx_view    resd 1                  ; what the open menu is about
ctx_entry   resd 1
del_view    resd 1                  ; what "Delete?" is about
del_entry   resd 1
dc_tick     resd 1                  ; the last click on an icon
dc_view     resd 1
dc_entry    resd 1
rn_active   resd 1                  ; renaming in place: 1 while it goes on
rn_view     resd 1
rn_entry    resd 1
rn_len      resd 1
rn_cur      resd 1                  ; the text cursor
rn_all      resd 1                  ; 1 = the whole name is selected
rn_bx       resd 1                  ; where the edit box was drawn
rn_w        resd 1                  ; (and how wide: it grows with the name)
rn_cx       resd 1                  ; the cell of the icon being renamed
rn_cy       resd 1                  ; (iv_draw: the box goes on top last)
rn_seen     resd 1
rn_by       resd 1
rn_buf      resb 24
ni_kind     resd 1                  ; (new_item: 0 folder, 1 file,
ni_folder   resd 1                  ; where, and the number tried)
ni_n        resd 1
mn_start    resd 1                  ; 1 = the open menu is the Start menu
fa_folder   resd 1                  ; the folder the Files app shows
fb_y        resd 1                  ; its toolbar buttons
fb_up_x     resd 1
fb_nd_x     resd 1
fb_nf_x     resd 1
fb_x        resd 1                  ; (fa_button)
fb_w        resd 1
fb_lbl      resd 1
dk_name     resb 24
dk_lbl      resb 16
dk_path     resb FS_PATH_MAX + 32
fa_title    resb FS_PATH_MAX + 16
ed_title    resb 160
edit_path   resb 128                ; the file the Text Editor opens (0 =
                                    ; the default /notes.txt)

section .data
dk_desktop  db "desktop", 0
dk_desk_path db "/desktop", 0
dk_slash    db "/", 0
dk_dots     db "...", 0
ni_s_folder db "folder", 0
ni_s_file   db "file", 0
ni_s_txt    db ".txt", 0
mn_noname   db 0
start_lbl   db "Start", 0
yt_home     db "https://www.youtube.com/", 0
fa_s_up     db "Up", 0
fa_s_nd     db "New folder", 0
fa_s_nf     db "New file", 0
fa_s_files  db "Files - ", 0
fa_s_empty1 db "This folder is empty.", 0
fa_s_empty2 db "Right-click here (or press Shift+F10) to make a folder or a file.", 0
ed_s_title  db "Text Editor - ", 0
ed_s_dirty  db "  (not saved)", 0
mb_t_rename db "Rename", 0
mb_t_delete db "Delete", 0
mb_t_props  db "Properties", 0
mb_t_files  db "Files", 0
mb_t_editor db "Text Editor", 0
k_folder    db "folder", 0
k_file      db "file", 0
set_s_colour db "Press 6 (or click line 6) to change the desktop colour.", 0
act_table   dd 0, act_youtube, act_leave, act_restart, act_shutdown
            dd act_newdir, act_newfile, act_refresh, act_colour, act_open
            dd act_rename, act_delete, act_props, act_del_yes
; icons: rectangles (dx, dy, width, height, colour), ended by width 0
icon_folder_t:
    db 1, 4, 13, 4
    dd 0xD99A2B                     ; the tab
    db 1, 7, 30, 22
    dd 0xD99A2B                     ; the back
    db 1, 11, 30, 18
    dd 0xF5C451                     ; the front
    db 1, 11, 30, 1
    dd 0xFBDD8A
    db 1, 28, 30, 1
    dd 0xA8741C
    db 0, 0, 0, 0
icon_page_t:
    db 5, 0, 22, 32
    dd 0x7D8A96                     ; the outline
    db 6, 1, 20, 30
    dd 0xF6F8FA                     ; the paper
    db 20, 1, 6, 6
    dd 0xC9D2DB                     ; the folded corner
    db 9, 10, 14, 2
    dd 0x9AA8B6                     ; lines of text
    db 9, 15, 14, 2
    dd 0x9AA8B6
    db 9, 20, 14, 2
    dd 0x9AA8B6
    db 9, 25, 9, 2
    dd 0x9AA8B6
    db 0, 0, 0, 0
icon_cow_t:                         ; the Start button: a cow's head
    db 0, 1, 3, 2
    dd 0xE8DCC0                     ; horns
    db 13, 1, 3, 2
    dd 0xE8DCC0
    db 2, 3, 2, 2
    dd 0xE8DCC0
    db 12, 3, 2, 2
    dd 0xE8DCC0
    db 0, 6, 3, 3
    dd 0xF4F4F4                     ; ears
    db 13, 6, 3, 3
    dd 0xF4F4F4
    db 3, 4, 10, 10
    dd 0xF8F8F8                     ; the head
    db 8, 4, 5, 3
    dd 0x202020                     ; a patch
    db 5, 7, 2, 2
    dd 0x101010                     ; eyes
    db 9, 7, 2, 2
    dd 0x101010
    db 4, 11, 8, 5
    dd 0xF2A0B0                     ; the muzzle
    db 6, 13, 1, 1
    dd 0x803848                     ; nostrils
    db 9, 13, 1, 1
    dd 0x803848
    db 0, 0, 0, 0
; the desktop's hints, bottom right
dk_hints    dd gui_hint1, gui_hint2, gui_hint3, gui_hint4, gui_hint5, 0
DK_HINT_W   equ 64                  ; (the longest hint, in characters)

section .text
; the menus (in .text, see MI in gui_menu.asm)
start_menu:
    MI "Terminal", "F1", ACT_APP + APP_TERM, 0
    MI "Text Editor", "F2", ACT_APP + APP_EDITOR, 0
    MI "Script IDE", "F3", ACT_APP + APP_IDE, 0
    MI "Browser", "F4", ACT_APP + APP_BROWSER, 0
    MI "Files", 0, ACT_APP + APP_FILES, 0
    MI "Settings", "F5", ACT_APP + APP_SETTINGS, 0
    MI "YouTube", 0, ACT_YOUTUBE, 0
    MI_SEP
    MI "Leave desktop", "Esc", ACT_LEAVE, 0
    MI "Restart", 0, ACT_RESTART, 0
    MI "Shut down", 0, ACT_SHUTDOWN, 0
    MI_END
menu_desk:                          ; right click on empty space
    MI "New folder", 0, ACT_NEWDIR, 0
    MI "New text file", 0, ACT_NEWFILE, 0
    MI_SEP
    MI "Open Terminal", "F1", ACT_APP + APP_TERM, 0
    MI "Refresh", 0, ACT_REFRESH, 0
    MI "Desktop colour...", 0, ACT_COLOUR, 0
    MI_END
menu_icon:                          ; right click on an icon
    MI "Open", "Enter", ACT_OPEN, 0
    MI "Rename", "F2", ACT_RENAME, 0
    MI "Delete", "Del", ACT_DELETE, 0
    MI_SEP
    MI "Properties", 0, ACT_PROPS, 0
    MI_END

; --------------------------------------------------------------- actions
; gui_action: EAX = ACT_* -> do it (a menu item was chosen, or OK in a
; message box)
gui_action:
    pushad
    cmp eax, ACT_APP
    jb .table
    sub eax, ACT_APP
    cmp eax, APP_FILES              ; Files from a menu: the top level
    je .files
    call gui_open
    jmp .done
.files:
    xor eax, eax
    call files_open_at
    jmp .done
.table:
    test eax, eax
    jz .done
    cmp eax, ACT_LAST
    ja .done
    mov ebp, [ctx_view]             ; (most work on the noted icon)
    mov ebx, [ctx_entry]
    call [act_table + eax * 4]
.done:
    or byte [gui_dirty], 1
    popad
    ret

act_youtube:
    mov eax, APP_BROWSER
    call gui_open
    mov esi, yt_home
    jmp brow_open_url

act_leave:                          ; (gui_quit: 1 leave, 2 restart, 3 off)
    mov byte [gui_quit], 1
    ret
act_restart:
    mov byte [gui_quit], 2
    ret
act_shutdown:
    mov byte [gui_quit], 3
    ret

act_newdir:
    xor edx, edx
    jmp new_item
act_newfile:
    mov edx, 1
    jmp new_item

act_refresh:                        ; (the icons are read again when drawn)
    mov dword [iv_scroll + 4], 0
    ret

act_colour:
    mov eax, APP_SETTINGS
    call gui_open
    mov esi, set_s_colour
    jmp set_msg

; act_open / act_rename / act_delete / act_props: EBP = view, EBX = entry
act_open:
    test ebx, ebx
    js .r
    jmp iv_open
.r: ret

act_rename:
    test ebx, ebx
    js .r
    call iv_prep
    call rn_start
    jmp iv_show
.r: ret

act_delete:
    pushad
    test ebx, ebx
    js .done
    call fs_entry
    test byte [edi + DE_FLAGS], FLAG_USED
    jz .done
    test byte [edi + DE_FLAGS], FLAG_DIR
    jz .ask
    lea eax, [ebx + 1]              ; a folder with something in it: no
    call fs_dir_count
    test ecx, ecx
    jz .ask
    call out_begin
    PRINTF `The folder %s is not empty: it holds %d item(s).\nOnly an empty folder can be deleted - delete or\nmove what is in it first.`, edi, ecx
    mov esi, mb_t_delete
    mov eax, MB_OK
    xor ebx, ebx
    call msgbox_out
    jmp .done
.ask:
    mov [del_view], ebp
    mov [del_entry], ebx
    mov eax, k_file
    test byte [edi + DE_FLAGS], FLAG_DIR
    jz .kind
    mov eax, k_folder
.kind:
    call out_begin
    PRINTF `Delete the %s %s?\n\nThis cannot be undone.`, eax, edi
    mov esi, mb_t_delete
    mov eax, MB_OKCANCEL
    mov ebx, ACT_DEL_YES
    call msgbox_out
.done:
    popad
    ret

; act_del_yes: OK in "Delete ...?": delete del_entry
act_del_yes:
    mov ebx, [del_entry]
    call fs_entry
    test byte [edi + DE_FLAGS], FLAG_USED
    jz .r
    movzx ecx, byte [edi + DE_PARENT]
    call fs_delete
    jc dk_error
    lea eax, [ebx + 1]              ; Files showed that folder: go up
    cmp [fa_folder], eax
    jne .sel
    mov [fa_folder], ecx
.sel:
    mov ebp, [del_view]
    mov dword [iv_sel + ebp * 4], -1
.r: ret

act_props:
    pushad
    test ebx, ebx
    js .done
    call fs_entry
    test byte [edi + DE_FLAGS], FLAG_USED
    jz .done
    call out_begin
    PRINTF `Name:      %s\n`, edi
    test byte [edi + DE_FLAGS], FLAG_DIR
    jz .file
    lea eax, [ebx + 1]
    call fs_dir_count
    PRINTF `Kind:      folder (%d item(s) in it)\n`, ecx
    jmp .date
.file:
    PRINTF `Kind:      file\nSize:      %d bytes (a file holds at most 4096)\n`, dword [edi + DE_SIZE]
.date:
    mov eax, [edi + DE_MTIME]
    test eax, eax
    jnz .dated
    PRINTF `Modified:  not known\n`
    jmp .where
.dated:
    mov ecx, eax                    ; unpack DE_MTIME (see fs.asm)
    shr ecx, 26
    add ecx, 2000
    mov edx, eax
    shr edx, 22
    and edx, 15
    mov esi, eax
    shr esi, 17
    and esi, 31
    mov ebp, eax
    shr ebp, 12
    and ebp, 31
    shr eax, 6
    and eax, 63
    PRINTF `Modified:  %d-%02d-%02d %02d:%02d\n`, ecx, edx, esi, ebp, eax
.where:
    movzx eax, byte [edi + DE_PARENT]
    mov edi, dk_path
    call fs_path
    PRINTF `In:        %s`, dk_path
    mov esi, mb_t_props
    mov eax, MB_OK
    xor ebx, ebx
    call msgbox_out
.done:
    popad
    ret

; dk_error: ESI = a message from fs.asm -> say it in a message box
dk_error:
    pushad
    call out_begin
    PRINTF `That did not work: %s.`, esi
    mov esi, mb_t_files
    mov eax, MB_OK
    xor ebx, ebx
    call msgbox_out
    popad
    ret

; ---------------------------------------------------------------- folders
; desk_folder: -> CF=0, EAX = the folder "desktop" (index + 1); CF=1 if
; there is none yet
desk_folder:
    push ebx
    push esi
    push edi
    xor eax, eax
    mov esi, dk_desktop
    call fs_lookup
    jc .out
    test byte [edi + DE_FLAGS], FLAG_DIR
    stc
    jz .out
    lea eax, [ebx + 1]
    clc
.out:
    pop edi
    pop esi
    pop ebx
    ret

; desk_need: -> CF=0, EAX = the folder "desktop", made now if needed;
; CF=1, ESI = message
desk_need:
    call desk_folder
    jnc .r
    push ebx
    mov esi, dk_desk_path
    call fs_mkdir
    jc .fail
    lea eax, [ebx + 1]
    pop ebx
    clc
.r: ret
.fail:
    pop ebx
    stc
    ret

; fa_check: -> EAX = the folder the Files app shows (back to the top level
; if it is gone)
fa_check:
    push ebx
    push edi
    mov eax, [fa_folder]
    test eax, eax
    jz .ok
    cmp eax, FS_MAX_FILES
    ja .top
    lea ebx, [eax - 1]
    call fs_entry
    test byte [edi + DE_FLAGS], FLAG_USED
    jz .top
    test byte [edi + DE_FLAGS], FLAG_DIR
    jnz .ok
.top:
    xor eax, eax
    mov [fa_folder], eax
.ok:
    pop edi
    pop ebx
    ret

; dk_build: EAX = folder, ESI = name -> dk_path = its whole path
dk_build:
    pushad
    mov edi, dk_path
    call fs_path
    push esi
    mov esi, dk_slash               ; ("//name" at the top: that is fine)
    call str_append
    pop esi
    call str_append
    popad
    ret

; ------------------------------------------------------------ icon views
; iv_prep: EBP = view -> its area and its list of icons up to date
iv_prep:
    push eax
    cmp ebp, IV_FILES
    jne .l
    mov eax, APP_FILES              ; (the Files window's content box)
    call wm_content
.l: call iv_layout
    call iv_refresh
    pop eax
    ret

; iv_layout: EBP = view -> iv_x / iv_y / iv_w / iv_h and how many icons
; fit across and down. The desktop uses the whole screen above the
; taskbar; Files the window's content box (cb_*) below its toolbar.
iv_layout:
    pushad
    cmp ebp, IV_DESK
    jne .files
    mov dword [iv_x], 12
    mov dword [iv_y], 12
    mov eax, [gfx_w]
    sub eax, 24
    mov [iv_w], eax
    mov eax, [gfx_h]
    sub eax, TASKBAR_H + 16
    mov [iv_h], eax
    mov dword [iv_cm], 1
    jmp .grid
.files:
    mov eax, [cb_x]
    add eax, 6
    mov [iv_x + 4], eax
    mov eax, [cb_y]
    add eax, FT_H + 4
    mov [iv_y + 4], eax
    mov eax, [cb_w]
    sub eax, 12 + FSB_W
    mov [iv_w + 4], eax
    mov eax, [cb_h]
    sub eax, FT_H + 4 + FB_H
    mov [iv_h + 4], eax
    mov dword [iv_cm + 4], 0
.grid:
    mov eax, [iv_w + ebp * 4]
    mov ecx, CELL_W
    call .count
    mov [iv_cols + ebp * 4], eax
    mov eax, [iv_h + ebp * 4]
    mov ecx, CELL_H
    call .count
    mov [iv_rows + ebp * 4], eax
    popad
    ret
.count:                             ; EAX / ECX, at least 1
    test eax, eax
    jle .one
    xor edx, edx
    div ecx
    test eax, eax
    jnz .c
.one:
    mov eax, 1
.c: ret

; iv_refresh: EBP = view -> its list of icons from the directory: folders
; first, then files, each by name. A selection that is gone is dropped.
iv_refresh:
    pushad
    cmp ebp, IV_DESK
    jne .files
    call desk_folder
    jnc .have
    mov eax, -1                     ; (no "desktop" folder yet: no icons)
    jmp .have
.files:
    call fa_check
.have:
    mov [iv_folder + ebp * 4], eax
    mov esi, ebp                    ; ESI = the list
    shl esi, 5
    add esi, iv_list
    xor ecx, ecx
    cmp eax, -1
    je .counted
    xor ebx, ebx
.l: call fs_entry
    test byte [edi + DE_FLAGS], FLAG_USED
    jz .n
    cmp [edi + DE_PARENT], al
    jne .n
    mov [esi + ecx], bl
    inc ecx
.n: inc ebx
    cmp ebx, FS_MAX_FILES
    jb .l
.counted:
    mov [iv_n + ebp * 4], ecx
    mov edx, 1                      ; insertion sort (32 at most)
.s: cmp edx, ecx
    jae .sorted
    mov edi, edx
.s2:
    test edi, edi
    jz .s3
    movzx ebx, byte [esi + edi]
    movzx eax, byte [esi + edi - 1]
    call iv_less
    jnc .s3
    mov [esi + edi - 1], bl
    mov [esi + edi], al
    dec edi
    jmp .s2
.s3:
    inc edx
    jmp .s
.sorted:
    mov eax, [iv_sel + ebp * 4]     ; the selection still there?
    test eax, eax
    js .done
    xor edx, edx
.f: cmp edx, ecx
    jae .drop
    cmp [esi + edx], al
    je .done
    inc edx
    jmp .f
.drop:
    mov dword [iv_sel + ebp * 4], -1
.done:
    popad
    ret

; iv_less: EBX, EAX = entries -> CF=1 if EBX goes before EAX (a folder
; before a file, else by name, ignoring capitals)
iv_less:
    pushad
    mov ecx, eax
    call fs_entry
    mov esi, edi                    ; ESI = EBX's entry
    mov ebx, ecx
    call fs_entry                   ; EDI = EAX's entry
    mov al, [esi + DE_FLAGS]
    mov ah, [edi + DE_FLAGS]
    and eax, FLAG_DIR | (FLAG_DIR << 8)
    cmp al, ah
    je .names
    test al, al
    jnz .yes
    jmp .no
.names:
    mov al, [esi]
    call to_lower
    mov ah, al
    mov al, [edi]
    call to_lower
    cmp ah, al
    jb .yes
    ja .no
    test al, al
    jz .no
    inc esi
    inc edi
    jmp .names
.yes:
    popad
    stc
    ret
.no:
    popad
    clc
    ret

; iv_entry: EBP = view, EAX = position -> EBX = its entry
iv_entry:
    push esi
    mov esi, ebp
    shl esi, 5
    movzx ebx, byte [iv_list + esi + eax]
    pop esi
    ret

; iv_pos: EBP = view, EBX = entry -> EAX = its position, -1 if not shown
iv_pos:
    push esi
    mov esi, ebp
    shl esi, 5
    add esi, iv_list
    xor eax, eax
.l: cmp eax, [iv_n + ebp * 4]
    jae .none
    cmp [esi + eax], bl
    je .r
    inc eax
    jmp .l
.none:
    mov eax, -1
.r: pop esi
    ret

; iv_rc: EBP = view, ECX = position -> EAX = column, EDX = row
iv_rc:
    mov eax, ecx
    xor edx, edx
    cmp dword [iv_cm + ebp * 4], 0
    je .rows
    div dword [iv_rows + ebp * 4]   ; columns first: EAX = column, EDX = row
    ret
.rows:
    div dword [iv_cols + ebp * 4]   ; rows first: EAX = row, EDX = column
    xchg eax, edx
    ret

; iv_xy: EBP = view, ECX = position -> ECX, EDX = the top left of its cell
iv_xy:
    push eax
    call iv_rc
    sub edx, [iv_scroll + ebp * 4]
    imul edx, CELL_H
    add edx, [iv_y + ebp * 4]
    imul eax, CELL_W
    add eax, [iv_x + ebp * 4]
    mov ecx, eax
    pop eax
    ret

; iv_hit: EBP = view -> CF=1 if the mouse is not in its area; else
; EAX = the position of the icon under it, -1 for none
iv_hit:
    push ebx
    push ecx
    push edx
    mov eax, [mouse_x]
    sub eax, [iv_x + ebp * 4]
    jl .out
    cmp eax, [iv_w + ebp * 4]
    jge .out
    mov ecx, [mouse_y]
    sub ecx, [iv_y + ebp * 4]
    jl .out
    cmp ecx, [iv_h + ebp * 4]
    jge .out
    xor edx, edx
    mov ebx, CELL_W
    div ebx                         ; EAX = column, EDX = x in the cell
    cmp edx, 6
    jb .none
    cmp edx, CELL_W - 6
    jae .none
    push eax
    mov eax, ecx
    xor edx, edx
    mov ebx, CELL_H
    div ebx                         ; EAX = row on the screen, EDX = y in it
    mov ecx, eax
    pop eax
    cmp edx, CELL_H - 8
    jae .none
    add ecx, [iv_scroll + ebp * 4]  ; ECX = row
    cmp dword [iv_cm + ebp * 4], 0
    je .rm
    cmp ecx, [iv_rows + ebp * 4]
    jae .none
    imul eax, [iv_rows + ebp * 4]
    add eax, ecx
    jmp .chk
.rm:
    cmp eax, [iv_cols + ebp * 4]
    jae .none
    imul ecx, [iv_cols + ebp * 4]
    add eax, ecx
.chk:
    cmp eax, [iv_n + ebp * 4]
    jae .none
    clc
    jmp .r
.none:
    mov eax, -1
    clc
    jmp .r
.out:
    mov eax, -1
    stc
.r: pop edx
    pop ecx
    pop ebx
    ret

; iv_show: EBP = view -> scroll so that the selected icon can be seen
iv_show:
    pushad
    mov ebx, [iv_sel + ebp * 4]
    test ebx, ebx
    js .done
    call iv_pos
    test eax, eax
    js .done
    mov ecx, eax
    call iv_rc                      ; EDX = its row
    cmp dword [iv_cm + ebp * 4], 0
    jne .done                       ; (the desktop does not scroll)
    cmp edx, [iv_scroll + ebp * 4]
    jge .below
    mov [iv_scroll + ebp * 4], edx
    jmp .done
.below:
    mov eax, edx
    sub eax, [iv_rows + ebp * 4]
    inc eax
    cmp eax, [iv_scroll + ebp * 4]
    jle .done
    mov [iv_scroll + ebp * 4], eax
.done:
    or byte [gui_dirty], 1
    popad
    ret

; iv_scroll_fix: EBP = view -> iv_scroll within what there is to see
iv_scroll_fix:
    pushad
    mov eax, [iv_n + ebp * 4]       ; rows needed = ceil(n / columns)
    add eax, [iv_cols + ebp * 4]
    dec eax
    xor edx, edx
    div dword [iv_cols + ebp * 4]
    sub eax, [iv_rows + ebp * 4]    ; the most it can scroll
    jns .max
    xor eax, eax
.max:
    cmp [iv_scroll + ebp * 4], eax
    jle .min
    mov [iv_scroll + ebp * 4], eax
.min:
    cmp dword [iv_scroll + ebp * 4], 0
    jge .done
    mov dword [iv_scroll + ebp * 4], 0
.done:
    popad
    ret

; icon_draw: ESI = an icon table (see icon_folder_t), ECX, EDX = where
icon_draw:
    pushad
    mov [ic_x], ecx
    mov [ic_y], edx
    mov ebx, esi
.l: movzx esi, byte [ebx + 2]
    test esi, esi
    jz .done
    movsx ecx, byte [ebx]
    movsx edx, byte [ebx + 1]
    movzx edi, byte [ebx + 3]
    add ecx, [ic_x]
    add edx, [ic_y]
    mov eax, [ebx + 4]
    call gfx_rgb
    call gfx_fillrect
    add ebx, 8
    jmp .l
.done:
    popad
    ret

; dk_cut: ESI = a name -> dk_lbl = it, cut to LBL_MAX characters with
; "..." if longer; ECX = its length
dk_cut:
    push esi
    push edi
    call str_len
    mov edi, dk_lbl
    cmp ecx, LBL_MAX
    ja .long
    call str_copy
    jmp .r
.long:
    mov ecx, LBL_MAX - 3
    call mem_copy
    add edi, ecx
    cmp byte [edi - 1], '.'         ; ("name...." would read badly)
    jne .dots
    dec edi
.dots:
    mov esi, dk_dots
    call str_copy
    mov esi, dk_lbl                 ; (its length now)
    call str_len
.r: pop edi
    pop esi
    ret

; iv_draw: EBP = view -> draw its icons (iv_layout / iv_refresh done)
iv_draw:
    pushad
    mov [iv_v], ebp
    mov dword [gfx_scale], 1
    mov dword [iv_p], 0
    mov dword [rn_seen], 0
.l: mov ebp, [iv_v]
    mov ecx, [iv_p]
    cmp ecx, [iv_n + ebp * 4]
    jae .done
    call iv_xy
    mov [iv_cx], ecx
    mov [iv_cy], edx
    lea eax, [edx + CELL_H]         ; scrolled out of sight?
    cmp eax, [iv_y + ebp * 4]
    jle .next
    mov eax, [iv_y + ebp * 4]
    add eax, [iv_h + ebp * 4]
    cmp edx, eax
    jge .next
    mov eax, [iv_p]
    call iv_entry
    mov [iv_e], ebx
    cmp ebx, [iv_sel + ebp * 4]     ; selected: a highlight behind it
    jne .icon
    mov ecx, [iv_cx]
    add ecx, 4
    mov edx, [iv_cy]
    add edx, 2
    RECT ecx, edx, CELL_W - 8, CELL_H - 8, 0x3D6A92
    mov ecx, [iv_cx]
    add ecx, 4
    mov edx, [iv_cy]
    add edx, 2
    mov esi, CELL_W - 8
    mov edi, CELL_H - 8
    mov eax, 0x8FC3EA
    call gfx_rgb
    call gfx_frame
.icon:
    mov ebx, [iv_e]
    call fs_entry
    mov ecx, [iv_cx]
    add ecx, (CELL_W - 32) / 2
    mov edx, [iv_cy]
    add edx, 8
    mov esi, icon_folder_t
    test byte [edi + DE_FLAGS], FLAG_DIR
    jnz .ic
    mov esi, icon_page_t
.ic:
    call icon_draw
    mov ebp, [iv_v]                 ; being renamed: the edit box instead
    cmp dword [rn_active], 0
    je .name
    cmp [rn_view], ebp
    jne .name
    mov eax, [iv_e]
    cmp eax, [rn_entry]
    jne .name
    mov eax, [iv_cx]                ; (drawn after the others, on top)
    mov [rn_cx], eax
    mov eax, [iv_cy]
    mov [rn_cy], eax
    mov dword [rn_seen], 1
    jmp .next
.name:
    mov ebx, [iv_e]
    call fs_entry
    mov esi, edi
    call dk_cut                     ; centred under the icon
    shl ecx, 2
    neg ecx
    add ecx, CELL_W / 2
    add ecx, [iv_cx]
    mov [iv_lx], ecx
    mov edx, [iv_cy]
    add edx, 48
    mov [iv_ly], edx
    cmp dword [iv_v], IV_DESK       ; (on the desktop with a shadow, so it
    jne .fg                         ; reads on any colour)
    inc ecx
    inc edx
    TEXT ecx, edx, dk_lbl, 0x000000, -1
.fg:
    TEXT [iv_lx], [iv_ly], dk_lbl, 0xF2F5F8, -1
.next:
    inc dword [iv_p]
    jmp .l
.done:
    cmp dword [rn_seen], 0          ; the rename box, over the neighbours
    je .r
    mov ebp, [iv_v]
    call rn_draw
.r: popad
    ret

; iv_open: EBP = view, EBX = entry -> open it: a folder in Files (the
; Files window itself goes into it), a file in the Text Editor
iv_open:
    pushad
    call fs_entry
    test byte [edi + DE_FLAGS], FLAG_USED
    jz .done
    test byte [edi + DE_FLAGS], FLAG_DIR
    jz .file
    lea eax, [ebx + 1]
    cmp ebp, IV_FILES
    jne .desk
    mov [fa_folder], eax
    mov dword [iv_sel + 4], -1
    mov dword [iv_scroll + 4], 0
    jmp .done
.desk:
    call files_open_at
    jmp .done
.file:
    mov edi, dk_path
    call fs_entry_path
    mov esi, dk_path
    call editor_open
.done:
    or byte [gui_dirty], 1
    popad
    ret

; iv_click: EBP = view (prepared), a left press -> select the icon under
; the mouse, open it on a double click; nothing there: deselect
iv_click:
    pushad
    call iv_hit
    jc .done
    test eax, eax
    js .empty
    call iv_entry                   ; EBX = the entry
    mov ecx, [ticks]                ; the second click of a double click?
    mov edx, ecx
    sub edx, [dc_tick]
    mov [dc_tick], ecx
    xor esi, esi
    cmp ebx, [dc_entry]
    jne .note
    cmp ebp, [dc_view]
    jne .note
    cmp edx, DC_TICKS
    ja .note
    inc esi
.note:
    mov [dc_entry], ebx
    mov [dc_view], ebp
    mov [iv_sel + ebp * 4], ebx
    test esi, esi
    jz .done
    mov dword [dc_entry], -1        ; (a third click starts again)
    call iv_open
    jmp .done
.empty:
    mov dword [iv_sel + ebp * 4], -1
    mov dword [dc_entry], -1
.done:
    or byte [gui_dirty], 1
    popad
    ret

; iv_rclick: EBP = view (prepared), a right press -> the menu for the icon
; under the mouse (it gets selected), or for the empty space
iv_rclick:
    pushad
    call iv_hit
    jc .done
    mov ebx, -1
    test eax, eax
    js .menu
    call iv_entry
    mov [iv_sel + ebp * 4], ebx
.menu:
    mov ecx, [mouse_x]
    mov edx, [mouse_y]
    xor eax, eax
    call iv_menu
.done:
    popad
    ret

; iv_menu: EBP = view, EBX = entry (-1 = the empty space), ECX, EDX =
; where, EAX = MO_* flags -> open the right menu
iv_menu:
    pushad
    mov [ctx_view], ebp
    mov [ctx_entry], ebx
    mov esi, menu_icon
    test ebx, ebx
    jns .open
    mov esi, menu_desk
.open:
    xor ebx, ebx
    call menu_open
    popad
    ret

; iv_kmenu: EBP = view, Shift+F10 -> the menu for the selected icon (next
; to it), or for the view
iv_kmenu:
    pushad
    call iv_prep
    mov ebx, [iv_sel + ebp * 4]
    test ebx, ebx
    js .space
    call iv_show
    call iv_pos
    test eax, eax
    js .space
    mov ecx, eax
    call iv_xy
    add ecx, CELL_W / 2
    add edx, CELL_H / 2
    jmp .open
.space:
    mov ebx, -1
    mov ecx, [iv_x + ebp * 4]
    add ecx, 24
    mov edx, [iv_y + ebp * 4]
    add edx, 24
.open:
    mov eax, MO_KEYS
    call iv_menu
    popad
    ret

; iv_key: EBP = view, EAX = key -> CF=0 if it was for the icons: arrows,
; Home / End, Page Up / Down, Enter, Delete
iv_key:
    pushad
    call iv_prep
    cmp eax, 10
    je .enter
    cmp eax, KEY_DEL
    je .del
    cmp eax, KEY_HOME
    je .home
    cmp eax, KEY_END
    je .end
    mov ecx, -1                     ; ECX = the step
    cmp eax, KEY_LEFT
    je .horiz
    cmp eax, KEY_UP
    je .vert
    neg ecx
    cmp eax, KEY_RIGHT
    je .horiz
    cmp eax, KEY_DOWN
    je .vert
    mov edx, [iv_rows + ebp * 4]    ; Page Up / Down: a screenful of lines
    cmp eax, KEY_PGDN
    je .lines
    neg edx
    cmp eax, KEY_PGUP
    je .lines
    jmp .unused
; One of left / right and up / down moves within a line (a row when the
; icons fill rows first, a column on the desktop), the other a whole line.
.horiz:
    cmp dword [iv_cm + ebp * 4], 0
    je .inline
    mov edx, ecx
    jmp .lines
.vert:
    cmp dword [iv_cm + ebp * 4], 0
    jne .inline
    mov edx, ecx
    jmp .lines
.inline:                            ; ECX = +1 / -1 within the line
    call .cur
    js .first
    push eax
    mov ebx, ecx
    mov ecx, eax
    call iv_rc                      ; (rows first: EAX = column; columns
    cmp dword [iv_cm + ebp * 4], 0  ; first: EDX = row)
    je .incol
    mov eax, edx
.incol:
    add eax, ebx                    ; still in the line?
    js .stay
    mov edx, [iv_cols + ebp * 4]
    cmp dword [iv_cm + ebp * 4], 0
    je .inl
    mov edx, [iv_rows + ebp * 4]
.inl:
    cmp eax, edx
    jge .stay
    pop eax
    add eax, ebx
    jmp .set
.stay:
    pop eax
    jmp .used
.lines:                             ; EDX = lines to move (+ / -)
    call .cur
    js .first
    mov ecx, [iv_cols + ebp * 4]
    cmp dword [iv_cm + ebp * 4], 0
    je .ll
    mov ecx, [iv_rows + ebp * 4]
.ll:
    mov esi, edx                    ; (ESI = lines asked for)
    imul edx, ecx                   ; EDX = how far in positions
    add eax, edx
    jns .lmax
    xor eax, eax                    ; before the first: Page Up goes to the
    cmp esi, -1                     ; first, an arrow stays
    jl .set
    jmp .used
.lmax:
    cmp eax, [iv_n + ebp * 4]
    jb .set
    mov eax, [iv_n + ebp * 4]       ; past the last: the last one
    dec eax
    jmp .set
.home:
    xor eax, eax
    cmp dword [iv_n + ebp * 4], 0
    je .used
    jmp .set
.end:
    mov eax, [iv_n + ebp * 4]
    dec eax
    js .used
    jmp .set
.first:                             ; nothing selected yet: the first
    xor eax, eax
    cmp dword [iv_n + ebp * 4], 0
    je .used
.set:
    cmp eax, [iv_n + ebp * 4]
    jae .used
    call iv_entry
    mov [iv_sel + ebp * 4], ebx
    call iv_show
    jmp .used
.enter:
    mov ebx, [iv_sel + ebp * 4]
    test ebx, ebx
    js .used
    call iv_open
    jmp .used
.del:
    mov ebx, [iv_sel + ebp * 4]
    test ebx, ebx
    js .used
    call act_delete
.used:
    or byte [gui_dirty], 1
    popad
    clc
    ret
.unused:
    popad
    stc
    ret
; .cur: -> EAX = the selected icon's position; SF=1 if none
.cur:
    mov ebx, [iv_sel + ebp * 4]
    mov eax, -1
    test ebx, ebx
    js .c
    call iv_pos
.c: test eax, eax
    ret

; new_item: EBP = view, EDX = 0 a folder / 1 a text file -> make one with
; a free default name in the view's folder and start renaming it
new_item:
    pushad
    mov [ni_kind], edx
    cmp ebp, IV_DESK
    jne .files
    call desk_need                  ; (the desktop's folder, made if needed)
    jc .fail
    jmp .have
.files:
    call fa_check
.have:
    mov [ni_folder], eax
    mov dword [ni_n], 1
.try:
    call ni_name
    mov eax, [ni_folder]
    mov esi, dk_name
    call fs_lookup
    jc .free
    inc dword [ni_n]
    cmp dword [ni_n], 99
    jbe .try
    mov esi, err_exists
    jmp .fail
.free:
    mov eax, [ni_folder]
    mov esi, dk_name
    call dk_build
    mov esi, dk_path
    cmp dword [ni_kind], 0
    jne .file
    call fs_mkdir                   ; EBX = the new folder
    jc .fail
    jmp .made
.file:
    mov edx, dk_path                ; (no data)
    xor ecx, ecx
    call fs_save
    jc .fail
    mov eax, [ni_folder]
    mov esi, dk_name
    call fs_lookup                  ; EBX = the new file
    jc .done
.made:
    call iv_prep
    mov [iv_sel + ebp * 4], ebx
    call iv_show
    call rn_start
    jmp .done
.fail:
    call dk_error
.done:
    or byte [gui_dirty], 1
    popad
    ret

; ni_name: dk_name = "folder" / "file.txt", or with "-N" (ni_n >= 2)
ni_name:
    pushad
    mov edi, dk_name
    mov byte [edi], 0
    mov esi, ni_s_folder
    cmp dword [ni_kind], 0
    je .base
    mov esi, ni_s_file
.base:
    call str_append
    mov eax, [ni_n]
    cmp eax, 2
    jb .ext
    mov esi, edi
    call str_len
    add edi, ecx
    mov byte [edi], '-'
    inc edi
    cmp eax, 10
    jb .one
    xor edx, edx
    mov ebx, 10
    div ebx
    add al, '0'
    stosb
    mov eax, edx
.one:
    add al, '0'
    stosb
    mov byte [edi], 0
.ext:
    cmp dword [ni_kind], 0
    je .done
    mov edi, dk_name
    mov esi, ni_s_txt
    call str_append
.done:
    popad
    ret

; ------------------------------------------------------- renaming in place
; rn_start: EBP = view, EBX = entry -> its label becomes an edit box with
; the whole name selected
rn_start:
    pushad
    mov [rn_view], ebp
    mov [rn_entry], ebx
    mov [iv_sel + ebp * 4], ebx
    call fs_entry
    mov esi, edi
    mov edi, rn_buf
    call str_copy
    mov esi, rn_buf
    call str_len
    mov [rn_len], ecx
    mov [rn_cur], ecx
    mov dword [rn_all], 1
    mov dword [rn_active], 1
    mov dword [rn_bx], -1000        ; (not drawn yet)
    or byte [gui_dirty], 1
    popad
    ret

; rn_draw: EBP = view -> the edit box under the icon at rn_cx / rn_cy: as
; wide as the name needs (at least the cell), kept inside the view's area
rn_draw:
    pushad
    mov eax, [rn_len]               ; the width
    shl eax, 3
    add eax, 18
    cmp eax, CELL_W - 8
    jge .wmin
    mov eax, CELL_W - 8
.wmin:
    cmp eax, RN_W
    jle .wmax
    mov eax, RN_W
.wmax:
    mov [rn_w], eax
    shr eax, 1                      ; centred under the icon ...
    mov ecx, [rn_cx]
    add ecx, CELL_W / 2
    sub ecx, eax
    mov eax, [iv_x + ebp * 4]       ; ... but not out of the view
    add eax, [iv_w + ebp * 4]
    sub eax, [rn_w]
    cmp ecx, eax
    jle .r
    mov ecx, eax
.r: cmp ecx, [iv_x + ebp * 4]
    jge .l
    mov ecx, [iv_x + ebp * 4]
.l: mov [rn_bx], ecx
    mov edx, [rn_cy]
    add edx, 46
    mov [rn_by], edx
    RECT [rn_bx], [rn_by], [rn_w], RN_H, 0x8FC3EA
    mov ecx, [rn_bx]
    inc ecx
    mov edx, [rn_by]
    inc edx
    mov esi, [rn_w]
    sub esi, 2
    RECT ecx, edx, esi, RN_H - 2, 0xFFFFFF
    mov ebx, 0x101418               ; the text colour
    cmp dword [rn_all], 0
    je .text
    cmp dword [rn_len], 0
    je .text
    mov ecx, [rn_bx]                ; all selected: white on blue
    add ecx, 5
    mov edx, [rn_by]
    add edx, 2
    mov esi, [rn_len]
    shl esi, 3
    RECT ecx, edx, esi, 16, 0x3D6A92
    mov ebx, 0xFFFFFF
.text:
    mov ecx, [rn_bx]
    add ecx, 5
    mov edx, [rn_by]
    add edx, 2
    TEXT ecx, edx, rn_buf, ebx, -1
    cmp dword [rn_all], 0
    jne .done
    mov ecx, [rn_cur]               ; the text cursor
    shl ecx, 3
    add ecx, [rn_bx]
    add ecx, 4
    mov edx, [rn_by]
    add edx, 2
    RECT ecx, edx, 2, 16, 0x101418
.done:
    popad
    ret

; rn_in_box: -> CF=0 if the mouse is on the edit box (the text cursor goes
; there); CF=1 if not
rn_in_box:
    push eax
    push ecx
    mov eax, [mouse_x]
    sub eax, [rn_bx]
    jl .no
    cmp eax, [rn_w]
    jge .no
    mov ecx, [mouse_y]
    sub ecx, [rn_by]
    jl .no
    cmp ecx, RN_H
    jge .no
    sub eax, 1                      ; the gap nearest the click
    jns .c
    xor eax, eax
.c: shr eax, 3
    cmp eax, [rn_len]
    jbe .set
    mov eax, [rn_len]
.set:
    mov [rn_cur], eax
    mov dword [rn_all], 0
    or byte [gui_dirty], 1
    pop ecx
    pop eax
    clc
    ret
.no:
    pop ecx
    pop eax
    stc
    ret

; rn_key: EAX = a key while renaming. Typing replaces a selected name;
; Left / Right / Home / End / Backspace / Delete edit; Enter confirms; Esc
; keeps the name it had.
rn_key:
    pushad
    cmp eax, 27
    je .cancel
    cmp eax, 10
    je .enter
    mov ecx, [rn_cur]
    mov edx, [rn_len]
    cmp eax, KEY_LEFT
    je .left
    cmp eax, KEY_RIGHT
    je .right
    cmp eax, KEY_HOME
    je .home
    cmp eax, KEY_END
    je .end
    cmp eax, 8
    je .back
    cmp eax, KEY_DEL
    je .del
    cmp eax, ' '
    jb .done
    cmp eax, '~'
    ja .done
    cmp dword [rn_all], 0           ; a character: replaces the selection
    je .ins
    call .clear
.ins:
    cmp edx, FS_NAME_MAX
    jae .done
    mov esi, edx                    ; make room at the cursor (the ending
.mv:                                ; zero moves up too)
    mov bl, [rn_buf + esi]
    mov [rn_buf + esi + 1], bl
    cmp esi, ecx
    je .put
    dec esi
    jmp .mv
.put:
    mov [rn_buf + ecx], al
    inc dword [rn_cur]
    inc dword [rn_len]
    jmp .done
.left:
    cmp dword [rn_all], 0
    je .l2
    mov dword [rn_all], 0
    mov dword [rn_cur], 0
    jmp .done
.l2:
    test ecx, ecx
    jz .done
    dec dword [rn_cur]
    jmp .done
.right:
    cmp dword [rn_all], 0
    jne .end
    cmp ecx, edx
    jae .done
    inc dword [rn_cur]
    jmp .done
.home:
    mov dword [rn_all], 0
    mov dword [rn_cur], 0
    jmp .done
.end:
    mov dword [rn_all], 0
    mov [rn_cur], edx
    jmp .done
.back:
    cmp dword [rn_all], 0
    je .b2
    call .clear
    jmp .done
.b2:
    test ecx, ecx
    jz .done
    dec ecx
    mov [rn_cur], ecx
    jmp .cut
.del:
    cmp dword [rn_all], 0
    je .d2
    call .clear
    jmp .done
.d2:
    cmp ecx, edx
    jae .done
.cut:                               ; take out the character at ECX
    lea esi, [rn_buf + ecx]
.c1:
    mov al, [esi + 1]
    mov [esi], al
    inc esi
    test al, al
    jnz .c1
    dec dword [rn_len]
    jmp .done
.cancel:
    mov dword [rn_active], 0
    jmp .done
.enter:
    call rn_commit
.done:
    or byte [gui_dirty], 1
    popad
    ret
.clear:                             ; (the name selected: empty it)
    mov dword [rn_all], 0
    mov dword [rn_len], 0
    mov dword [rn_cur], 0
    mov byte [rn_buf], 0
    xor ecx, ecx
    xor edx, edx
    ret

; rn_commit: give the entry the typed name. CF=0 done (or nothing to do);
; CF=1 the name cannot be used - a message box says why, and the editing
; goes on
rn_commit:
    pushad
    mov ebx, [rn_entry]
    call fs_entry
    test byte [edi + DE_FLAGS], FLAG_USED
    jz .ok                          ; (it is gone)
    mov ecx, [rn_len]
    mov byte [rn_buf + ecx], 0
    mov esi, rn_buf
    call fs_name_valid
    jc .bad
    mov esi, rn_buf                 ; the same name: nothing to do
    push edi
.same:
    mov al, [esi]
    cmp al, [edi]
    jne .differ
    inc esi
    inc edi
    test al, al
    jnz .same
    pop edi
    jmp .ok
.differ:
    pop edi
    movzx eax, byte [edi + DE_PARENT]
    push ebx
    mov esi, rn_buf
    call fs_lookup                  ; taken by something else there?
    mov ecx, ebx
    pop ebx
    jc .free
    cmp ecx, ebx
    jne .taken
.free:
    mov esi, rn_buf
    call dk_build
    mov esi, dk_path
    call fs_rename
    jc .err
.ok:
    mov dword [rn_active], 0
    or byte [gui_dirty], 1
    popad
    clc
    ret
.bad:
    call out_begin
    PRINTF `"%s" cannot be a name.\nA name has 1-19 characters: letters, digits, '.', '-'\nand '_' (no spaces), and is not "." or "..".`, rn_buf
    jmp .say
.taken:
    call out_begin
    PRINTF `There is already a file or folder called %s here.\nPlease choose another name.`, rn_buf
.say:
    mov esi, mb_t_rename
    mov eax, MB_OK
    xor ebx, ebx
    call msgbox_out
    jmp .keep
.err:
    call dk_error
.keep:
    or byte [gui_dirty], 1
    popad
    stc
    ret

; ------------------------------------------------------- the Start button
; start_open: EAX = MO_* flags -> the Start menu, above the Start button
start_open:
    pushad
    mov ebx, mn_noname              ; the header: MOOS and who is signed in
    cmp byte [login_user], 0
    je .h
    mov ebx, login_user
.h: mov esi, start_menu
    mov ecx, START_X
    mov edx, [gfx_h]                ; (it does not fit below: it goes up)
    sub edx, TASKBAR_H
    call menu_open
    mov dword [mn_start], 1
    or byte [gui_dirty], 1
    popad
    ret

; start_draw: the Start button at the left end of the taskbar (tb_top)
start_draw:
    pushad
    mov eax, 0x2C5A82
    cmp dword [tb_hover], TB_START
    je .lit
    cmp dword [mn_open], 0
    je .bg
    cmp dword [mn_start], 0
    je .bg
.lit:
    mov eax, 0x3F7DB4
.bg:
    mov edx, [tb_top]
    add edx, 5
    RECT START_X, edx, START_W, TASKBAR_H - 8, eax
    mov ecx, START_X + 10
    mov edx, [tb_top]
    add edx, 10
    mov esi, icon_cow_t
    call icon_draw
    mov edx, [tb_top]
    add edx, 10
    TEXT START_X + 34, edx, start_lbl, 0xFFFFFF, -1
    popad
    ret

; -------------------------------------------------------- the desktop
; desk_draw: the desktop's icons and, bottom right, the hints
desk_draw:
    pushad
    mov dword [gfx_scale], 2
    mov ecx, [gfx_w]
    sub ecx, 24 + DK_HINT_W * 8
    mov edx, [gfx_h]
    sub edx, TASKBAR_H + 16 + 6 * 18 + 30 + 18
    mov [iv_lx], ecx
    mov [iv_ly], edx
    TEXT ecx, edx, gui_title, 0xF4F0E6, -1
    mov dword [gfx_scale], 1
    mov ecx, [iv_lx]
    add ecx, 4 * 16 + 14
    mov edx, [iv_ly]
    add edx, 12
    TEXT ecx, edx, gui_sub, 0xD8E4EA, -1
    add dword [iv_ly], 30 + 10
    xor edi, edi                    ; (EDI: TEXT changes EBP)
.hint:
    mov esi, [dk_hints + edi * 4]
    test esi, esi
    jz .mouse
    TEXT [iv_lx], [iv_ly], esi, 0xD8E4EA, -1
    add dword [iv_ly], 18
    inc edi
    jmp .hint
.mouse:
    cmp byte [mouse_ok], 0
    jne .icons
    TEXT [iv_lx], [iv_ly], gui_nomouse, 0xFFD27A, -1
.icons:
    mov ebp, IV_DESK
    call iv_layout
    call iv_refresh
    call iv_draw
    popad
    ret

; desk_key: EAX = a key -> CF=0 if it was taken here: by a message box, a
; menu, the rename box, F12 / Ctrl+Esc (the Start menu), or the icons of
; the desktop or the Files app (F2, Shift+F10; and when no window has the
; focus the arrows, Enter, Delete, Esc)
desk_key:
    pushad
    cmp dword [mb_open], 0
    je .m
    call mb_key
    jmp .used
.m: cmp eax, KEY_F1 + 11            ; F12: the Start menu, open or shut
    je .start
    cmp dword [mn_open], 0
    je .r
    call menu_key
    jmp .used
.r: cmp dword [rn_active], 0
    je .s
    call rn_key
    jmp .used
.s: cmp eax, 27                     ; Ctrl+Esc: the Start menu
    jne .v
    test dword [key_mods], KMOD_CTRL
    jz .v
.start:
    cmp dword [mn_open], 0
    je .so
    call menu_close
    jmp .used
.so:
    mov eax, MO_KEYS
    call start_open
    jmp .used
.v: cmp dword [kmode], 0            ; (F7 / F8 moving a window)
    jne .no
    mov ebp, IV_DESK
    cmp dword [cur_app], APP_NONE
    je .view
    mov ebp, IV_FILES
    cmp dword [cur_app], APP_FILES
    jne .no
.view:
    cmp eax, KEY_F1 + 1             ; F2: rename the selected icon
    jne .v2
    call iv_prep
    mov ebx, [iv_sel + ebp * 4]
    test ebx, ebx
    js .no                          ; (none: F2 opens the Text Editor)
    call rn_start
    call iv_show
    jmp .used
.v2:
    cmp eax, KEY_F1 + 9             ; Shift+F10: the menu
    jne .v3
    test dword [key_mods], KMOD_SHIFT
    jz .no
    call iv_kmenu
    jmp .used
.v3:
    cmp ebp, IV_DESK                ; (Files gets the rest as its keys)
    jne .no
    cmp eax, 27                     ; Esc with an icon selected: deselect
    jne .v4
    cmp dword [iv_sel], 0
    jl .no
    mov dword [iv_sel], -1
    jmp .used
.v4:
    call iv_key
    jnc .used
.no:
    popad
    stc
    ret
.used:
    or byte [gui_dirty], 1
    popad
    clc
    ret

; desk_press: a left press -> CF=1 if a message box, a menu or the rename
; box took it (a click outside the rename box confirms the name first)
desk_press:
    cmp dword [mb_open], 0
    je .m
    call mb_press
    stc
    ret
.m: cmp dword [mn_open], 0
    je .r
    call menu_press
    stc
    ret
.r: cmp dword [rn_active], 0
    je .no
    call rn_in_box
    jnc .yes
    jmp rn_commit                   ; (CF=1 if the name was refused)
.yes:
    stc
    ret
.no:
    clc
    ret

; gui_rpress: the right button went down -> a menu for what is under the
; mouse: an icon or empty space on the desktop or in Files
gui_rpress:
    pushad
    cmp dword [mb_open], 0
    jne .done
    call menu_close                 ; (another menu replaces an open one)
    cmp dword [rn_active], 0
    je .where
    call rn_commit
    jc .done
.where:
    or byte [gui_dirty], 1
    mov dword [kmode], 0
    mov eax, [gfx_h]
    sub eax, TASKBAR_H
    cmp [mouse_y], eax
    jae .done                       ; (the taskbar: nothing)
    call wm_hit
    test eax, eax
    jz .desktop
    call gui_raise
    cmp eax, APP_FILES
    jne .done
    cmp dword [hit_part], PART_CONTENT
    jne .done
    mov ebp, IV_FILES
    call iv_prep
    call iv_rclick
    jmp .done
.desktop:
    mov dword [cur_app], APP_NONE
    mov ebp, IV_DESK
    call iv_prep
    call iv_rclick
.done:
    popad
    ret

; ------------------------------------------------------- the Text Editor
; editor_open: ESI = path -> open that file in the Text Editor. If the
; editor holds unsaved changes to another file, a message box says so
; instead (nothing is lost).
editor_open:
    pushad
    call str_len
    cmp ecx, TX_BUF - TX_FILE - 1
    jae .long
    test dword [wn_f + APP_EDITOR * 4], WF_OPEN
    jz .load
    lea edi, [tx_edit + TX_FILE]
    call str_icmp
    je .raise                       ; (that file is open already)
    cmp dword [tx_edit + TX_DIRTY], 0
    je .load
    mov eax, APP_EDITOR
    call gui_raise
    call out_begin
    PRINTF `The Text Editor has changes to %s that are\nnot saved yet. Save them with Ctrl+S (or close the\neditor), then open %s again.`, edi, esi
    jmp .say
.load:
    mov edi, edit_path
    call str_copy
    test dword [wn_f + APP_EDITOR * 4], WF_OPEN
    jz .open
    mov eax, APP_EDITOR
    call editor_app_init
.raise:
    mov eax, APP_EDITOR
    call gui_raise
    jmp .done
.open:
    mov eax, APP_EDITOR
    call gui_open
    jmp .done
.long:
    call out_begin
    PRINTF `The path of that file is too long for the Text Editor.`
.say:
    mov esi, mb_t_editor
    mov eax, MB_OK
    xor ebx, ebx
    call msgbox_out
.done:
    popad
    ret

; editor_title: -> ESI = "Text Editor - <file>" (and "(not saved)")
editor_title:
    push edi
    mov edi, ed_title
    mov esi, ed_s_title
    call str_copy
    mov esi, tx_edit + TX_FILE
    call str_append
    cmp dword [tx_edit + TX_DIRTY], 0
    je .r
    mov esi, ed_s_dirty
    call str_append
.r: mov esi, ed_title
    pop edi
    ret

; ------------------------------------------------------------ the Files app
; files_open_at: EAX = folder -> the Files window, showing it
files_open_at:
    pushad
    mov [fa_folder], eax
    mov dword [iv_sel + 4], -1
    mov dword [iv_scroll + 4], 0
    mov eax, APP_FILES
    call gui_open
    popad
    ret

; files_init: (the folder was chosen by files_open_at, or is the last one)
files_init:
    ret

; files_title: -> ESI = "Files - /the/folder" (other registers kept)
files_title:
    push eax
    push ecx
    push edi
    mov edi, fa_title
    mov esi, fa_s_files
    call str_copy
    call str_len
    add edi, ecx
    call fa_check
    call fs_path
    mov esi, fa_title
    pop edi
    pop ecx
    pop eax
    ret

; fa_buttons: where the toolbar buttons are (from cb_*)
fa_buttons:
    push eax
    mov eax, [cb_y]
    add eax, (FT_H - FBTN_H) / 2
    mov [fb_y], eax
    mov eax, [cb_x]
    add eax, 8
    mov [fb_up_x], eax
    mov eax, [cb_x]
    add eax, [cb_w]
    sub eax, 8 + 8 * 8 + 20
    mov [fb_nf_x], eax
    sub eax, 8 + 10 * 8 + 20
    mov [fb_nd_x], eax
    pop eax
    ret

; fa_button: ECX = x, ESI = width, EDI = label, EAX = 1 to grey it out
fa_button:
    pushad
    mov [fb_x], ecx
    mov [fb_w], esi
    mov [fb_lbl], edi
    mov ebx, 0xE6ECF2
    push eax
    mov eax, 0x34495C
    cmp dword [esp], 0
    je .bg
    mov eax, 0x2A3038
    mov ebx, 0x6C7782
.bg:
    RECT [fb_x], [fb_y], [fb_w], FBTN_H, eax
    pop eax
    mov esi, [fb_lbl]
    call str_len
    shl ecx, 2
    neg ecx
    mov eax, [fb_w]
    shr eax, 1
    add ecx, eax
    add ecx, [fb_x]
    mov edx, [fb_y]
    add edx, (FBTN_H - 16) / 2
    TEXT ecx, edx, [fb_lbl], ebx, -1
    popad
    ret

; files_draw: the Files window's content (cb_*, clipped to it)
files_draw:
    pushad
    mov ebp, IV_FILES
    call iv_layout
    call iv_refresh
    call iv_scroll_fix
    RECT [cb_x], [cb_y], [cb_w], FT_H, 0x1A2129     ; the toolbar
    mov edx, [cb_y]
    add edx, FT_H - 1
    RECT [cb_x], edx, [cb_w], 1, 0x3A4652
    call fa_buttons
    xor eax, eax                    ; Up (greyed out at the top level)
    cmp dword [fa_folder], 0
    jne .up
    inc eax
.up:
    mov ecx, [fb_up_x]
    mov esi, 48
    mov edi, fa_s_up
    call fa_button
    xor eax, eax
    mov ecx, [fb_nd_x]
    mov esi, 10 * 8 + 20
    mov edi, fa_s_nd
    call fa_button
    mov ecx, [fb_nf_x]
    mov esi, 8 * 8 + 20
    mov edi, fa_s_nf
    call fa_button
    call gfx_clip_save              ; the path, between the buttons
    mov ecx, [fb_up_x]
    add ecx, 48 + 12
    mov edx, [cb_y]
    mov esi, [fb_nd_x]
    sub esi, ecx
    sub esi, 10
    mov edi, FT_H
    call gfx_clip_and
    mov eax, [fa_folder]
    mov edi, dk_path
    call fs_path
    mov edx, [fb_y]
    add edx, (FBTN_H - 16) / 2
    TEXT ecx, edx, dk_path, 0x9FD3FF, -1
    call gfx_clip_restore
    call gfx_clip_save              ; the icons, inside their area
    mov ecx, [iv_x + 4]
    mov edx, [iv_y + 4]
    mov esi, [iv_w + 4]
    add esi, FSB_W + 2
    mov edi, [iv_h + 4]
    call gfx_clip_and
    mov ebp, IV_FILES
    call iv_draw
    call gfx_clip_restore
    cmp dword [iv_n + 4], 0         ; an empty folder: say what to do
    jne .bar
    mov ecx, [iv_x + 4]
    add ecx, 10
    mov edx, [iv_y + 4]
    add edx, 10
    TEXT ecx, edx, fa_s_empty1, 0xC8D2DC, -1
    mov ecx, [iv_x + 4]
    add ecx, 10
    mov edx, [iv_y + 4]
    add edx, 30
    TEXT ecx, edx, fa_s_empty2, 0x8A96A2, -1
.bar:
    call fa_scrollbar
    mov edx, [cb_y]                 ; the status line
    add edx, [cb_h]
    sub edx, FB_H
    RECT [cb_x], edx, [cb_w], FB_H, 0x1A2129
    call fs_stats                   ; EAX = entries used
    call out_begin
    PRINTF `%d item(s) here     MOOSFS: %d of 32 entries used, 4 KB per file`, dword [iv_n + 4], eax
    mov ecx, [cb_x]
    add ecx, 10
    mov edx, [cb_y]
    add edx, [cb_h]
    sub edx, FB_H - 3
    call gui_draw_outbuf
    popad
    ret

; fa_scrollbar: when not all icons fit, a bar on the right shows which
; part is seen
fa_scrollbar:
    pushad
    mov eax, [iv_n + 4]             ; EAX = rows in all
    add eax, [iv_cols + 4]
    dec eax
    xor edx, edx
    div dword [iv_cols + 4]
    cmp eax, [iv_rows + 4]
    jbe .done
    mov ebx, eax
    mov ecx, [iv_x + 4]             ; the track
    add ecx, [iv_w + 4]
    mov edx, [iv_y + 4]
    RECT ecx, edx, FSB_W, [iv_h + 4], 0x252C34
    mov eax, [iv_h + 4]             ; the thumb: rows seen / rows in all
    imul eax, [iv_rows + 4]
    xor edx, edx
    div ebx
    mov esi, eax
    mov eax, [iv_h + 4]
    imul eax, [iv_scroll + 4]
    xor edx, edx
    div ebx
    mov edx, eax
    add edx, [iv_y + 4]
    mov ecx, [iv_x + 4]
    add ecx, [iv_w + 4]
    RECT ecx, edx, FSB_W, esi, 0x6F8496
.done:
    popad
    ret

; files_click: a left press in the Files window's content (cb_* set)
files_click:
    pushad
    mov ebp, IV_FILES
    call iv_layout
    call iv_refresh
    call fa_buttons
    mov eax, [mouse_y]
    sub eax, [fb_y]
    jl .icons
    cmp eax, FBTN_H
    jge .icons
    mov eax, [mouse_x]
    mov ecx, [fb_up_x]
    mov edx, 48
    call .on
    jnc .up
    mov ecx, [fb_nd_x]
    mov edx, 10 * 8 + 20
    call .on
    jnc .newdir
    mov ecx, [fb_nf_x]
    mov edx, 8 * 8 + 20
    call .on
    jnc .newfile
    jmp .done
.up:
    call fa_up
    jmp .done
.newdir:
    xor edx, edx
    call new_item
    jmp .done
.newfile:
    mov edx, 1
    call new_item
    jmp .done
.icons:
    call iv_click
.done:
    or byte [gui_dirty], 1
    popad
    ret
.on:                                ; EAX = x on a button at ECX, EDX wide?
    cmp eax, ecx
    jl .no
    add ecx, edx
    cmp eax, ecx
    jge .no
    clc
    ret
.no:
    stc
    ret

; fa_up: Files shows the folder above (the one it was in gets selected)
fa_up:
    pushad
    call fa_check
    test eax, eax
    jz .done
    lea ebx, [eax - 1]
    call fs_up
    mov [fa_folder], eax
    mov [iv_sel + 4], ebx
    mov dword [iv_scroll + 4], 0
    mov ebp, IV_FILES
    call iv_prep
    call iv_show
.done:
    or byte [gui_dirty], 1
    popad
    ret

; files_key: EAX = a key for the Files window: Backspace goes up, the rest
; moves among the icons
files_key:
    cmp eax, 8
    je fa_up
    push ebp
    mov ebp, IV_FILES
    call iv_key
    pop ebp
    ret

; files_wheel: EAX = wheel notches (+ = away from you) -> scroll
files_wheel:
    pushad
    mov ebp, IV_FILES
    call iv_prep
    sub [iv_scroll + 4], eax
    call iv_scroll_fix
    or byte [gui_dirty], 1
    popad
    ret

; desk_reset: the desktop starts: no menu, message box, renaming or
; selection
desk_reset:
    xor eax, eax
    mov [mn_open], eax
    mov [mn_start], eax
    mov [mb_open], eax
    mov [rn_active], eax
    mov [iv_scroll + 4], eax
    dec eax
    mov [iv_sel], eax
    mov [iv_sel + 4], eax
    mov [dc_entry], eax
    ret
