; =============================================================================
;  readline.asm - line editor with cursor keys, history and Tab completion
;
;  Keys: Left/Right, Home/End (Ctrl+A/Ctrl+E), Backspace, Delete,
;        Up/Down (history), Tab (complete), Esc or Ctrl+U (clear line),
;        Ctrl+L (clear screen), Ctrl+C (cancel), Ctrl+D (end of input)
; =============================================================================
RL_HISTORY  equ 1                   ; flag: enable history and Tab completion
HIST_N      equ 16                  ; remembered commands (power of two)
HIST_LEN    equ 256
LINE_MAX    equ 250                 ; longest line (it scrolls sideways)
MAX_CANDS   equ 64

section .bss
line_buf    resb 256
alignb 4
line_len    resd 1
line_pos    resd 1
line_x0     resd 1                  ; screen column where the input starts
line_max    resd 1                  ; longest line accepted
line_w      resd 1                  ; columns visible after the prompt
line_view   resd 1                  ; first character shown (scrolling)
rl_prompt   resd 1
rl_status   resd 1
rl_flags    resb 1
rl_pattr    resb 1
alignb 4
hist_buf    resb HIST_N * HIST_LEN
hist_count  resd 1
hist_head   resd 1
hist_nav    resd 1
cand_count  resd 1
cand_wlen   resd 1
cand_ptrs   resd MAX_CANDS
cand_prefix resb 256

section .data
str_man_sp  db "man ", 0
str_help_sp db "help ", 0

section .text

; readline: ESI = prompt, BL = prompt colour, BH = flags.
; Result in line_buf / line_len. EAX = 0 Enter, 1 Ctrl+D, 2 Ctrl+C.
readline:
    pushad
    mov [rl_prompt], esi
    mov [rl_pattr], bl
    mov [rl_flags], bh
    mov dword [hist_nav], 0
    mov dword [line_len], 0
    mov dword [line_pos], 0
    mov byte [line_buf], 0
    call rl_show_prompt
.key:
    call rl_redraw
    call kbd_getkey
    cmp eax, 10
    je .enter
    cmp eax, 8
    je .backspace
    cmp eax, KEY_DEL
    je .delete
    cmp eax, KEY_LEFT
    je .left
    cmp eax, KEY_RIGHT
    je .right
    cmp eax, KEY_HOME
    je .home
    cmp eax, 1                      ; Ctrl+A
    je .home
    cmp eax, KEY_END
    je .end
    cmp eax, 5                      ; Ctrl+E
    je .end
    cmp eax, KEY_UP
    je .up
    cmp eax, KEY_DOWN
    je .down
    cmp eax, 9
    je .tab
    cmp eax, 27                     ; Esc
    je .clear_line
    cmp eax, 21                     ; Ctrl+U
    je .clear_line
    cmp eax, 3
    je .ctrl_c
    cmp eax, 4
    je .ctrl_d
    cmp eax, 12
    je .ctrl_l
    cmp eax, ' '
    jb .key
    cmp eax, '~'
    ja .key

    mov ecx, [line_len]             ; insert a printable character
    cmp ecx, [line_max]
    jae .key
    mov edx, [line_pos]
.shift:
    cmp ecx, edx
    jbe .put
    mov bl, [line_buf + ecx - 1]
    mov [line_buf + ecx], bl
    dec ecx
    jmp .shift
.put:
    mov [line_buf + edx], al
    inc dword [line_pos]
    inc dword [line_len]
    mov ecx, [line_len]
    mov byte [line_buf + ecx], 0
    jmp .key

.backspace:
    mov edx, [line_pos]
    test edx, edx
    jz .key
    dec edx
    mov [line_pos], edx
    jmp .remove
.delete:
    mov edx, [line_pos]
    cmp edx, [line_len]
    jae .key
.remove:                            ; remove the character at EDX
    mov ecx, [line_len]
.rm:
    cmp edx, ecx
    jae .rm_done
    mov bl, [line_buf + edx + 1]
    mov [line_buf + edx], bl
    inc edx
    jmp .rm
.rm_done:
    dec dword [line_len]
    jmp .key

.left:
    cmp dword [line_pos], 0
    je .key
    dec dword [line_pos]
    jmp .key
.right:
    mov eax, [line_pos]
    cmp eax, [line_len]
    jae .key
    inc dword [line_pos]
    jmp .key
.home:
    mov dword [line_pos], 0
    jmp .key
.end:
    mov eax, [line_len]
    mov [line_pos], eax
    jmp .key

.up:
    test byte [rl_flags], RL_HISTORY
    jz .key
    mov eax, [hist_nav]
    cmp eax, [hist_count]
    jae .key
    inc eax
    mov [hist_nav], eax
    call rl_load_history
    jmp .key
.down:
    test byte [rl_flags], RL_HISTORY
    jz .key
    mov eax, [hist_nav]
    test eax, eax
    jz .key
    dec eax
    mov [hist_nav], eax
    jz .clear_line
    call rl_load_history
    jmp .key

.tab:
    test byte [rl_flags], RL_HISTORY
    jz .key
    call rl_complete
    jmp .key

.clear_line:
    mov dword [line_len], 0
    mov dword [line_pos], 0
    mov byte [line_buf], 0
    jmp .key

.ctrl_l:
    call vga_clear
    call rl_show_prompt
    jmp .key

.ctrl_c:
    call rl_cursor_end
    PRINTF `\x01d^C\x01n\n`
    mov dword [line_len], 0
    mov byte [line_buf], 0
    mov dword [rl_status], 2
    jmp .out
.ctrl_d:
    mov dword [rl_status], 1
    jmp .finish
.enter:
    mov dword [rl_status], 0
.finish:
    call rl_cursor_end
    mov al, 10
    call vga_putc
    test byte [rl_flags], RL_HISTORY
    jz .out
    call rl_add_history
.out:
    popad
    mov eax, [rl_status]
    ret

; rl_show_prompt: print the prompt on a fresh line and measure the room left
rl_show_prompt:
    pushad
    call vga_fresh_line
    mov al, [text_attr]
    push eax
    mov ah, al
    and ah, 0xF0
    mov al, [rl_pattr]
    and al, 0x0F
    or al, ah
    mov [text_attr], al
    mov esi, [rl_prompt]
    call vga_puts
    pop eax
    mov [text_attr], al
    mov eax, [cur_x]
    mov [line_x0], eax
    mov ecx, SCR_COLS - 1
    sub ecx, eax
    mov [line_w], ecx
    mov dword [line_max], LINE_MAX
    mov dword [line_view], 0
    popad
    ret

; rl_redraw: paint line_buf after the prompt and place the cursor
rl_redraw:
    pushad
    mov eax, [line_pos]             ; scroll so the cursor stays visible
    cmp eax, [line_view]
    jae .not_left
    mov [line_view], eax
.not_left:
    mov edx, [line_view]
    add edx, [line_w]
    cmp eax, edx
    jb .in_view
    sub eax, [line_w]
    inc eax
    mov [line_view], eax
.in_view:
    mov eax, [line_view]            ; (never scrolled past the text's end)
    cmp eax, [line_len]
    jbe .view_ok
    mov eax, [line_len]
    mov [line_view], eax
.view_ok:
    mov edi, [cur_y]
    imul edi, SCR_COLS
    add edi, [line_x0]
    lea edi, [VGA_MEM + edi * 2]
    mov esi, line_buf
    add esi, [line_view]
    mov ecx, SCR_COLS
    sub ecx, [line_x0]
    mov ah, [text_attr]
.l: lodsb
    test al, al
    jz .pad
    stosw
    loop .l
    jmp .cursor
.pad:
    mov al, ' '
    rep stosw
.cursor:
    mov eax, [line_pos]
    sub eax, [line_view]
    add eax, [line_x0]
    mov [cur_x], eax
    call vga_update_cursor
    popad
    ret

; rl_cursor_end: move the text cursor behind the last typed character
rl_cursor_end:
    push eax
    mov eax, [line_len]
    sub eax, [line_view]
    cmp eax, [line_w]
    jbe .fits
    mov eax, [line_w]
.fits:
    add eax, [line_x0]
    mov [cur_x], eax
    pop eax
    ret

; rl_append_char: AL = character to add at the end of the line
rl_append_char:
    push ecx
    mov ecx, [line_len]
    cmp ecx, [line_max]
    jae .full
    mov [line_buf + ecx], al
    inc ecx
    mov byte [line_buf + ecx], 0
    mov [line_len], ecx
    mov [line_pos], ecx
.full:
    pop ecx
    ret

; rl_load_history: EAX = how far back (1 = most recent)
rl_load_history:
    pushad
    mov ebx, [hist_head]
    sub ebx, eax
    and ebx, HIST_N - 1
    imul esi, ebx, HIST_LEN
    add esi, hist_buf
    xor ecx, ecx
.l: mov al, [esi + ecx]
    test al, al
    jz .e
    cmp ecx, [line_max]
    jae .e
    mov [line_buf + ecx], al
    inc ecx
    jmp .l
.e: mov byte [line_buf + ecx], 0
    mov [line_len], ecx
    mov [line_pos], ecx
    popad
    ret

; rl_add_history: remember line_buf (skips empty lines and repeats)
rl_add_history:
    pushad
    cmp dword [line_len], 0
    je .done
    mov esi, line_buf
    cmp dword [hist_count], 0
    je .add
    mov ebx, [hist_head]
    dec ebx
    and ebx, HIST_N - 1
    imul edi, ebx, HIST_LEN
    add edi, hist_buf
    call str_icmp
    je .done
.add:
    mov ebx, [hist_head]
    imul edi, ebx, HIST_LEN
    add edi, hist_buf
    call str_copy
    inc ebx
    and ebx, HIST_N - 1
    mov [hist_head], ebx
    cmp dword [hist_count], HIST_N
    jae .done
    inc dword [hist_count]
.done:
    popad
    ret

; -----------------------------------------------------------------------------
; Tab completion: first word -> command names; after "man"/"help" -> manual
; names; anything else -> file names.
; -----------------------------------------------------------------------------
rl_complete:
    pushad
    mov ecx, [line_pos]
    cmp ecx, [line_len]
    jne .done                       ; only complete at the end of the line
    mov edi, ecx
.ws:
    test edi, edi
    jz .ws_found
    cmp byte [line_buf + edi - 1], ' '
    je .ws_found
    dec edi
    jmp .ws
.ws_found:                          ; EDI = index where the word starts
    mov eax, ecx
    sub eax, edi
    mov [cand_wlen], eax
    lea esi, [line_buf + edi]
    push edi
    mov edi, cand_prefix
    call str_copy
    pop edi
    xor edx, edx                    ; context 0 = commands
    mov esi, line_buf
    call skip_spaces
    mov eax, esi
    sub eax, line_buf
    cmp eax, edi
    jae .context
    mov edx, 2                      ; context 2 = files
    mov edi, esi
    mov esi, str_man_sp
    call str_iprefix
    je .manual
    mov esi, str_help_sp
    call str_iprefix
    jne .context
.manual:
    mov edx, 1                      ; context 1 = manual pages
.context:
    call build_candidates
    mov ecx, [cand_count]
    test ecx, ecx
    jz .done
    cmp ecx, 1
    jne .many
    mov esi, [cand_ptrs]            ; one match: finish the word
    add esi, [cand_wlen]
.one:
    lodsb
    test al, al
    jz .one_end
    call rl_append_char
    jmp .one
.one_end:
    mov al, ' '
    call rl_append_char
    jmp .done

.many:                              ; extend to the longest common prefix
    mov esi, [cand_ptrs]
    xor edx, edx
.lcp:
    mov al, [esi + edx]
    test al, al
    jz .lcp_done
    call to_lower
    mov ah, al
    mov ebx, 1
.lcp_c:
    cmp ebx, ecx
    jae .lcp_next
    mov edi, [cand_ptrs + ebx * 4]
    mov al, [edi + edx]
    call to_lower
    cmp al, ah
    jne .lcp_done
    inc ebx
    jmp .lcp_c
.lcp_next:
    inc edx
    jmp .lcp
.lcp_done:
    mov ecx, [cand_wlen]
    cmp edx, ecx
    jbe .list
.app:
    cmp ecx, edx
    jae .done
    mov al, [esi + ecx]
    call rl_append_char
    inc ecx
    jmp .app

.list:                              ; nothing to add: show the choices
    call rl_cursor_end
    mov al, 10
    call vga_putc
    xor ebx, ebx
.ls:
    cmp ebx, [cand_count]
    jae .ls_done
    mov esi, [cand_ptrs + ebx * 4]
    PRINTF `\x01c%20s\x01n`, esi
    inc ebx
    jmp .ls
.ls_done:
    call rl_show_prompt
.done:
    popad
    ret

; build_candidates: EDX = context (0 commands, 1 manuals, 2 files).
; Collects names starting with cand_prefix into cand_ptrs / cand_count.
build_candidates:
    pushad
    mov dword [cand_count], 0
    cmp edx, 2
    je .files
    mov ebx, cmd_table
.cmds:
    mov edi, [ebx + CMD_NAME]
    test edi, edi
    jz .cmds_done
    cmp dword [ebx + CMD_DESC], 0   ; skip aliases
    je .cmd_next
    call cand_try
.cmd_next:
    add ebx, CMD_SIZE
    jmp .cmds
.cmds_done:
    cmp edx, 1
    jne .done
    mov ebx, topic_table
.topics:
    mov edi, [ebx]
    test edi, edi
    jz .done
    call cand_try
    add ebx, 8
    jmp .topics
.files:
    xor ebx, ebx
.f: call fs_entry
    test byte [edi + DE_FLAGS], FLAG_USED
    jz .fn
    call cand_try
.fn:
    inc ebx
    cmp ebx, FS_MAX_FILES
    jb .f
.done:
    popad
    ret

; cand_try: EDI = name; add it when it starts with cand_prefix (EAX clobbered)
cand_try:
    push esi
    mov esi, cand_prefix
    call str_iprefix
    pop esi
    jne .no
    mov eax, [cand_count]
    cmp eax, MAX_CANDS
    jae .no
    mov [cand_ptrs + eax * 4], edi
    inc dword [cand_count]
.no:
    ret
