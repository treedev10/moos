; =============================================================================
;  vga.asm - 80x25 text screen driver, status bar, formatted output
; =============================================================================
section .data
text_attr       db C_DEFAULT
status_text     db " ", OS_NAME, " ", OS_VERSION, "  ", 0xB3, "  help = commands  ", 0xB3
                db "  man <cmd> = manual", 0
colour_letters  db "rgycwdbm", 0
colour_values   db 0x0C, 0x0A, 0x0E, 0x0B, 0x0F, 0x08, 0x09, 0x0D
hex_digits      db "0123456789ABCDEF"
banner:
    db "   __  __  ___   ___  ____", 10
    db "  |  \/  |/ _ \ / _ \/ ___|", 10
    db "  | |\/| | | | | | | \___ \", 10
    db "  | |  | | |_| | |_| |___) |", 10
    db "  |_|  |_|\___/ \___/|____/", 10, 0
banner_sub      db "  ", OS_LONGNAME, " - version ", OS_VERSION, 10, 10, 0

section .bss
cur_x           resd 1
cur_y           resd 1
out_mode        resb 1          ; 0 = screen, 1 = OUTBUF (for the pager)
kp_base         resb 1
alignb 4
out_ptr         resd 1
status_last     resd 1
clk_bar_ap      resb 1
numbuf          resb 39
numbuf_end      resb 1
alignb 16
screen_magic    resd 4          ; "MOOS" "SCRN" - lets test tools find it
screen_buf      resw SCR_COLS * SCR_ROWS    ; the screen: character, colour
screen_drawn    resw SCR_COLS * SCR_ROWS    ; what the graphics screen shows

section .text

vga_init:
    pushad
    mov dword [screen_magic], 'MOOS'
    mov dword [screen_magic + 4], 'SCRN'
    mov byte [clk_24h], 1           ; clock defaults (before clk_init runs)
    mov byte [clk_color], C_STATUS
    mov byte [clk_bar_ap], 'a'
    cmp dword [bootinfo + BI.platform], PLATFORM_UEFI
    je .graphics
    mov dx, 0x3D4                   ; text mode: underline cursor
    mov al, 0x0A
    out dx, al
    inc dx
    mov al, 14
    out dx, al
    dec dx
    mov al, 0x0B
    out dx, al
    inc dx
    mov al, 15
    out dx, al
    jmp .clear
.graphics:
    call fb_setup
.clear:
    call vga_clear
    call status_draw
    popad
    ret

; fb_setup: fit the 80x25 character grid onto the UEFI graphics screen
; (8x16 pixel characters, doubled when there is room) and prepare colours
fb_setup:
    mov eax, [bootinfo + BI.fb_width]
    xor edx, edx
    mov ecx, 640
    div ecx
    mov ebx, eax
    mov eax, [bootinfo + BI.fb_height]
    xor edx, edx
    mov ecx, 400
    div ecx
    cmp eax, ebx
    jae .smaller
    mov ebx, eax
.smaller:
    cmp ebx, 2
    jbe .not_big
    mov ebx, 2
.not_big:
    test ebx, ebx
    jnz .scale
    inc ebx
.scale:
    mov [fb_scale], ebx
    lea eax, [ebx * 8]
    mov [fb_cellw], eax
    shl eax, 1
    mov [fb_cellh], eax
    imul eax, [fb_cellw], SCR_COLS  ; centre the text area
    mov ecx, [bootinfo + BI.fb_width]
    sub ecx, eax
    jns .x_ok
    xor ecx, ecx
.x_ok:
    shr ecx, 1
    mov [fb_x0], ecx
    imul eax, [fb_cellh], SCR_ROWS
    mov ecx, [bootinfo + BI.fb_height]
    sub ecx, eax
    jns .y_ok
    xor ecx, ecx
.y_ok:
    shr ecx, 1
    mov [fb_y0], ecx
    xor ebx, ebx                    ; colours in the screen's pixel format
.colour:
    lea esi, [vga_rgb + ebx * 2]
    add esi, ebx                    ; 3 bytes per colour
    movzx eax, byte [esi]           ; red
    movzx ecx, byte [esi + 1]       ; green
    movzx edx, byte [esi + 2]       ; blue
    mov edi, [bootinfo + BI.fb_format]
    cmp edi, 0
    je .rgbx
    cmp edi, 2
    je .masks
    shl eax, 16                     ; BGRX: 0x00RRGGBB
    shl ecx, 8
    or eax, ecx
    or eax, edx
    jmp .store
.rgbx:                              ; RGBX: 0x00BBGGRR
    shl ecx, 8
    shl edx, 16
    or eax, ecx
    or eax, edx
    jmp .store
.masks:                             ; bit masks: shift each into place
    push ecx
    bsf ecx, [bootinfo + BI.fb_rmask]
    shl eax, cl
    pop ecx
    push eax
    mov eax, ecx
    bsf ecx, [bootinfo + BI.fb_gmask]
    shl eax, cl
    mov ecx, eax
    pop eax
    or eax, ecx
    mov ecx, edx
    push eax
    mov eax, ecx
    bsf ecx, [bootinfo + BI.fb_bmask]
    shl eax, cl
    mov ecx, eax
    pop eax
    or eax, ecx
.store:
    mov [fb_palette + ebx * 4], eax
    inc ebx
    cmp ebx, 16
    jb .colour
    mov edi, screen_drawn           ; nothing drawn yet: redraw everything
    mov ecx, SCR_COLS * SCR_ROWS
    mov ax, 0xFFFF
    rep stosw
    mov dword [drawn_cursor], -1
    mov eax, efi_clear64
    call efi64
    ret

; screen_present: show screen_buf on the real screen
screen_present:
    pushad
    cmp dword [bootinfo + BI.platform], PLATFORM_UEFI
    je .graphics
    mov esi, screen_buf             ; text mode: copy to video memory
    mov edi, 0xB8000
    mov ecx, SCR_COLS * SCR_ROWS / 2
    rep movsd
    mov ebx, [cur_y]                ; and move the hardware cursor
    imul ebx, SCR_COLS
    add ebx, [cur_x]
    mov dx, 0x3D4
    mov al, 0x0F
    out dx, al
    inc dx
    mov al, bl
    out dx, al
    dec dx
    mov al, 0x0E
    out dx, al
    inc dx
    mov al, bh
    out dx, al
    popad
    ret
.graphics:
    mov eax, efi_present64
    call efi64
    popad
    ret

; vga_clear: blank the text area (rows 0-23) and home the cursor
vga_clear:
    pushad
    mov edi, VGA_MEM
    mov ecx, SCR_COLS * TEXT_ROWS
    mov ah, [text_attr]
    mov al, ' '
    rep stosw
    mov dword [cur_x], 0
    mov dword [cur_y], 0
    call vga_update_cursor
    popad
    ret

; vga_recolor: apply text_attr to every cell of the text area
vga_recolor:
    pushad
    mov edi, VGA_MEM + 1
    mov ecx, SCR_COLS * TEXT_ROWS
    mov al, [text_attr]
.l: mov [edi], al
    add edi, 2
    loop .l
    popad
    ret

; vga_scroll: move rows 1-23 up one line, blank row 23
vga_scroll:
    pushad
    mov esi, VGA_MEM + SCR_COLS * 2
    mov edi, VGA_MEM
    mov ecx, SCR_COLS * (TEXT_ROWS - 1) / 2
    rep movsd
    mov ecx, SCR_COLS
    mov ah, [text_attr]
    mov al, ' '
    rep stosw
    popad
    ret

; vga_update_cursor: (the cursor is shown by screen_present)
vga_update_cursor:
    ret

; vga_putc_raw: AL = character (handles \n \b \t). Cursor not updated.
vga_putc_raw:
    pushad
    cmp al, 10
    je .newline
    cmp al, 13
    je .done
    cmp al, 8
    je .backspace
    cmp al, 9
    je .tab
    mov ebx, [cur_y]
    imul ebx, SCR_COLS
    add ebx, [cur_x]
    mov ah, [text_attr]
    mov [VGA_MEM + ebx * 2], ax
    inc dword [cur_x]
    cmp dword [cur_x], SCR_COLS
    jb .done
.newline:
    mov dword [cur_x], 0
    inc dword [cur_y]
    cmp dword [cur_y], TEXT_ROWS
    jb .done
    call vga_scroll
    mov dword [cur_y], TEXT_ROWS - 1
    jmp .done
.backspace:
    cmp dword [cur_x], 0
    je .done
    dec dword [cur_x]
    jmp .done
.tab:
    mov al, ' '
    call vga_putc_raw
    test dword [cur_x], 7
    jnz .tab
.done:
    popad
    ret

; vga_putc: AL = character, then update the hardware cursor
vga_putc:
    call vga_putc_raw
    jmp vga_update_cursor

; vga_puts: print zero-terminated string at ESI
vga_puts:
    pushad
.l: lodsb
    test al, al
    jz .e
    call vga_putc_raw
    jmp .l
.e: call vga_update_cursor
    popad
    ret

; vga_newline_if_needed: start a fresh line unless already at column 0
vga_fresh_line:
    cmp dword [cur_x], 0
    je .r
    push eax
    mov al, 10
    call vga_putc
    pop eax
.r: ret

; -----------------------------------------------------------------------------
; Output redirection: kprintf writes through out_char, which goes either to
; the screen or into OUTBUF (later shown page by page by the pager).
; -----------------------------------------------------------------------------
out_char:
    cmp byte [gui_capture], 0
    jne gui_log_char                ; GUI terminal: capture into its log
    cmp byte [out_mode], 0
    je vga_putc_raw
    push edi
    mov edi, [out_ptr]
    cmp edi, OUTBUF + OUTBUF_SIZE - 1
    jae .full
    mov [edi], al
    inc dword [out_ptr]
.full:
    pop edi
    ret

; out_begin: start collecting output into OUTBUF
out_begin:
    mov byte [out_mode], 1
    mov dword [out_ptr], OUTBUF
    ret

; out_flush: stop collecting and show OUTBUF through the pager (BL = flags)
out_flush:
    cmp byte [gui_capture], 0
    jne .gui                        ; GUI: text was already captured by out_char
    pushad
    mov edi, [out_ptr]
    mov byte [edi], 0
    mov byte [out_mode], 0
    mov esi, OUTBUF
    call pager
    popad
    ret
.gui:
    mov byte [out_mode], 0
    ret

; colour_from_letter: AL = letter (r g y c w d b m, other = normal),
; AH = base attribute -> AL = attribute with the base background
colour_from_letter:
    push ecx
    xor ecx, ecx
.f: cmp byte [colour_letters + ecx], 0
    je .base
    cmp [colour_letters + ecx], al
    je .hit
    inc ecx
    jmp .f
.hit:
    mov al, [colour_values + ecx]
    mov cl, ah
    shr cl, 4
    cmp al, cl                      ; same as background -> unreadable
    je .base
    and ah, 0xF0
    or al, ah
    jmp .out
.base:
    mov al, ah
.out:
    pop ecx
    ret

; fmt_uint: EAX = value, EBX = base -> ESI = digit string, ECX = length
fmt_uint:
    push eax
    push edx
    push edi
    mov edi, numbuf_end
    mov byte [edi], 0
.l: xor edx, edx
    div ebx
    mov dl, [hex_digits + edx]
    dec edi
    mov [edi], dl
    test eax, eax
    jnz .l
    mov esi, edi
    mov ecx, numbuf_end
    sub ecx, edi
    pop edi
    pop edx
    pop eax
    ret

; -----------------------------------------------------------------------------
; kprintf(format, args...) - cdecl style, called by the PRINTF macro.
; -----------------------------------------------------------------------------
kprintf:
    pushad
    lea ebp, [esp + 36]
    mov esi, [ebp]                  ; format string
    add ebp, 4                      ; first argument
    mov al, [text_attr]
    mov [kp_base], al
.next:
    lodsb
    test al, al
    jz .done
    cmp al, 1
    je .colour
    cmp al, '%'
    je .format
    call out_char
    jmp .next

.colour:
    lodsb
    cmp byte [out_mode], 0
    jne .colour_buf
    mov ah, [kp_base]
    call colour_from_letter
    mov [text_attr], al
    jmp .next
.colour_buf:                        ; keep the escape for the pager
    push eax
    mov al, 1
    call out_char
    pop eax
    call out_char
    jmp .next

.format:
    xor ecx, ecx                    ; width
    mov dl, ' '                     ; pad character
    cmp byte [esi], '0'
    jne .width
    mov dl, '0'
    inc esi
.width:
    movzx eax, byte [esi]
    sub al, '0'
    cmp al, 9
    ja .type
    imul ecx, 10
    add ecx, eax
    inc esi
    jmp .width
.type:
    mov edi, ecx                    ; EDI = width
    lodsb
    push esi                        ; save format position
    cmp al, 's'
    je .str
    cmp al, 'd'
    je .dec
    cmp al, 'i'
    je .int
    cmp al, 'x'
    je .hex
    cmp al, 'c'
    je .chr
    call out_char                   ; "%%" or unknown: print literally
    jmp .fmt_done

.chr:
    mov eax, [ebp]
    add ebp, 4
    call out_char
    jmp .fmt_done

.str:
    mov esi, [ebp]
    add ebp, 4
.s_l:
    lodsb
    test al, al
    jz .s_pad
    call out_char
    dec edi
    jmp .s_l
.s_pad:
    cmp edi, 0
    jle .fmt_done
    mov al, ' '
    call out_char
    dec edi
    jmp .s_pad

.hex:
    mov ebx, 16
    mov eax, [ebp]
    add ebp, 4
    call fmt_uint
    jmp .emit
.dec:
    mov ebx, 10
    mov eax, [ebp]
    add ebp, 4
    call fmt_uint
    jmp .emit
.int:
    mov ebx, 10
    mov eax, [ebp]
    add ebp, 4
    test eax, eax
    jns .int_pos
    neg eax
    call fmt_uint
    dec esi
    mov byte [esi], '-'
    inc ecx
    jmp .emit
.int_pos:
    call fmt_uint
.emit:                              ; ESI = digits, ECX = length, EDI = width
    sub edi, ecx
.pad:
    cmp edi, 0
    jle .digits
    mov al, dl
    call out_char
    dec edi
    jmp .pad
.digits:
    lodsb
    test al, al
    jz .fmt_done
    call out_char
    jmp .digits

.fmt_done:
    pop esi
    jmp .next

.done:
    cmp byte [out_mode], 0
    jne .ret
    mov al, [kp_base]
    mov [text_attr], al
    call vga_update_cursor
.ret:
    popad
    ret

; -----------------------------------------------------------------------------
; Status bar (row 24): name, hints and a live clock
; -----------------------------------------------------------------------------
status_draw:
    pushad
    mov edi, VGA_MEM + TEXT_ROWS * SCR_COLS * 2
    mov ecx, SCR_COLS
    mov ah, [clk_color]
    mov al, ' '
    rep stosw
    mov esi, status_text
    mov edi, VGA_MEM + TEXT_ROWS * SCR_COLS * 2
.l: lodsb
    test al, al
    jz .clock
    mov [edi], al
    add edi, 2
    jmp .l
.clock:
    mov dword [status_last], -1
    call status_tick
    popad
    ret

; status_tick: redraw the clock when the second changes (called while idle)
status_tick:
    pushad
    mov eax, [ticks]
    xor edx, edx
    mov ecx, 100
    div ecx
    cmp eax, [status_last]
    je .done
    mov [status_last], eax
    call rtc_read
    mov edi, VGA_MEM + (TEXT_ROWS * SCR_COLS + 60) * 2
    movzx eax, word [rtc_year]
    xor edx, edx
    mov ecx, 100
    div ecx
    call .num2
    mov eax, edx
    call .num2
    mov al, '-'
    call .chr
    movzx eax, byte [rtc_month]
    call .num2
    mov al, '-'
    call .chr
    movzx eax, byte [rtc_day]
    call .num2
    mov al, ' '
    call .chr
    call .chr
    movzx eax, byte [rtc_hour]
    cmp byte [clk_24h], 0           ; 12-hour display?
    jne .hour
    cmp al, 12
    jb .ampm_am
    mov byte [clk_bar_ap], 'p'
    cmp al, 12
    jbe .hour12
    sub al, 12
    jmp .hour12
.ampm_am:
    mov byte [clk_bar_ap], 'a'
    test al, al
    jnz .hour12
    mov al, 12
.hour12:
    movzx eax, al
.hour:
    call .num2
    mov al, ':'
    call .chr
    movzx eax, byte [rtc_min]
    call .num2
    mov al, ':'
    call .chr
    movzx eax, byte [rtc_sec]
    call .num2
    cmp byte [clk_24h], 0
    jne .done
    mov al, [clk_bar_ap]
    call .chr
.done:
    popad
    ret
.chr:
    mov [edi], al
    add edi, 2
    ret
.num2:                              ; EAX = 0..99 -> two digits
    push edx
    push ecx
    xor edx, edx
    mov ecx, 10
    div ecx
    add al, '0'
    mov [edi], al
    add dl, '0'
    mov [edi + 2], dl
    add edi, 4
    pop ecx
    pop edx
    ret

; show_banner: the boot logo
show_banner:
    pushad
    mov al, [text_attr]
    push eax
    mov byte [text_attr], 0x0B
    mov esi, banner
    call vga_puts
    pop eax
    mov [text_attr], al
    mov esi, banner_sub
    call vga_puts
    popad
    ret
