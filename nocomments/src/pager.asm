PG_HEADINGS equ 1
PG_KEEP_TOP equ 2
PAGE_LINES  equ TEXT_ROWS - 1

section .bss
alignb 4
pg_lines    resd 1
pg_flags    resb 1
pg_attr     resb 1
pg_quit     resb 1

section .data
pg_more_text db " -- more --    Space: next page    Enter: next line    Q: quit", 0

section .text

pager:
    pushad
    mov [pg_flags], bl
    mov al, [text_attr]
    mov [pg_attr], al
    mov dword [pg_lines], 0
    test bl, PG_KEEP_TOP
    jz .next
    mov eax, [cur_y]
    mov [pg_lines], eax
.next:
    lodsb
    test al, al
    jz .end
    cmp al, 13
    je .next
    cmp al, 1
    je .colour
    cmp dword [cur_x], 0
    jne .emit
    mov ah, [pg_attr]
    mov [text_attr], ah
    test byte [pg_flags], PG_HEADINGS
    jz .emit
    cmp al, 'A'
    jb .emit
    cmp al, 'Z'
    ja .emit
    and ah, 0xF0
    or ah, C_HEADING
    mov [text_attr], ah
.emit:
    call vga_putc_raw
    cmp dword [cur_x], 0
    jne .next
    inc dword [pg_lines]
    cmp dword [pg_lines], PAGE_LINES
    jb .next
    cmp byte [esi], 0
    je .end
    call pager_prompt
    jnc .next
    jmp .end
.colour:
    lodsb
    test al, al
    jz .end
    mov ah, [pg_attr]
    call colour_from_letter
    mov [text_attr], al
    jmp .next
.end:
    mov al, [pg_attr]
    mov [text_attr], al
    call vga_update_cursor
    popad
    ret

pager_prompt:
    pushad
    call vga_update_cursor
    mov edi, [cur_y]
    imul edi, SCR_COLS * 2
    add edi, VGA_MEM
    push edi
    mov esi, pg_more_text
    mov ah, C_MORE
    mov ecx, SCR_COLS
.draw:
    lodsb
    test al, al
    jnz .ch
    mov al, ' '
    dec esi
.ch:
    stosw
    loop .draw
.key:
    call kbd_getkey
    mov byte [pg_quit], 0
    cmp eax, ' '
    je .page
    cmp eax, KEY_PGDN
    je .page
    cmp eax, 10
    je .line
    cmp eax, KEY_DOWN
    je .line
    mov byte [pg_quit], 1
    cmp eax, 'q'
    je .erase
    cmp eax, 'Q'
    je .erase
    cmp eax, 27
    je .erase
    cmp eax, 3
    je .erase
    jmp .key
.page:
    mov dword [pg_lines], 0
    jmp .erase
.line:
    mov dword [pg_lines], PAGE_LINES - 1
.erase:
    pop edi
    mov ecx, SCR_COLS
    mov ah, [pg_attr]
    mov al, ' '
    rep stosw
    bt dword [pg_quit], 0
    popad
    ret
