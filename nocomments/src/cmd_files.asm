section .bss
alignb 4
dt_year     resd 1
dt_mon      resd 1
dt_day      resd 1
dt_hour     resd 1
dt_min      resd 1
dt_sec      resd 1
fnd_ptr     resd 1
fnd_len     resd 1
fnd_count   resd 1
fnd_name    resd 1
fnd_lineno  resd 1

section .data
u_cat       db "cat <file>", 0
u_write     db "write <file>", 0
u_append    db "append <file>", 0
u_rm        db "rm <file>", 0
u_rename    db "rename <old-name> <new-name>", 0
u_copy      db "copy <source> <destination>", 0
u_find      db "find <text> [file]", 0
u_wc        db "wc <file>", 0
u_hexdump   db "hexdump <file>", 0
q_replace   db "That file already exists. Replace it?", 0
q_empty     db "", 0

section .text

open_file:
    call fs_find
    jnc .ok
    PRINTF `There is no file named '\x01w%s\x01n'. Type \x01wls\x01n to see your files.\n`, esi
    stc
.ok:
    ret

print_fs_error:
    PRINTF `\x01rerror:\x01n %s\n`, esi
    ret

check_new_file:
    pushad
    call fs_name_valid
    jc .bad
    call fs_find
    jnc .ok
    call fs_stats
    cmp eax, FS_MAX_FILES
    jb .ok
    mov esi, err_disk_full
    jmp .fail
.bad:
    mov esi, err_name_bad
.fail:
    call print_fs_error
    popad
    stc
    ret
.ok:
    popad
    clc
    ret

unpack_mtime:
    push eax
    push ebx
    mov ebx, eax
    shr ebx, 26
    add ebx, 2000
    mov [dt_year], ebx
    mov ebx, eax
    shr ebx, 22
    and ebx, 15
    mov [dt_mon], ebx
    mov ebx, eax
    shr ebx, 17
    and ebx, 31
    mov [dt_day], ebx
    mov ebx, eax
    shr ebx, 12
    and ebx, 31
    mov [dt_hour], ebx
    mov ebx, eax
    shr ebx, 6
    and ebx, 63
    mov [dt_min], ebx
    and eax, 63
    mov [dt_sec], eax
    pop ebx
    pop eax
    ret

out_text:
    pushad
    jecxz .done
.l: lodsb
    cmp al, 10
    je .ok
    cmp al, 9
    je .ok
    cmp al, 32
    jae .ok
    mov al, '.'
.ok:
    call out_char
    loop .l
.done:
    popad
    ret

cmd_ls:
    call fs_stats
    test eax, eax
    jnz .list
    PRINTF `No files yet. Create one with \x01wwrite notes.txt\x01n\n`
    ret
.list:
    call out_begin
    PRINTF `\x01w  NAME                     SIZE    MODIFIED\x01n\n`
    xor ebx, ebx
.l: call fs_entry
    test byte [edi + DE_FLAGS], FLAG_USED
    jz .n
    mov eax, [edi + DE_MTIME]
    call unpack_mtime
    PRINTF `  \x01c%20s\x01n %6d B  %d-%02d-%02d %02d:%02d\n`, edi, dword [edi + DE_SIZE], dword [dt_year], dword [dt_mon], dword [dt_day], dword [dt_hour], dword [dt_min]
.n: inc ebx
    cmp ebx, FS_MAX_FILES
    jb .l
    call fs_stats
    PRINTF `\n  %d of 32 files, %d bytes used. Each file can hold up to 4096 bytes.\n`, eax, edx
    cmp byte [fs_persist], 0
    jne .flush
    PRINTF `  \x01yNote:\x01n no disk was found, so files disappear when the computer is turned off.\n`
.flush:
    xor ebx, ebx
    call out_flush
    ret

cmd_cat:
    mov ecx, 1
    mov esi, u_cat
    call need_args
    jc .ret
    mov esi, [argv + 4]
    call open_file
    jc .ret
    mov ecx, [edi + DE_SIZE]
    test ecx, ecx
    jnz .show
    PRINTF `(%s is empty)\n`, esi
.ret:
    ret
.show:
    call fs_slot
    call out_begin
    call out_text
    cmp byte [esi + ecx - 1], 10
    je .flush
    mov al, 10
    call out_char
.flush:
    xor ebx, ebx
    call out_flush
    ret

text_entry:
    PRINTF `\x01dType your text, pressing Enter after each line. To save, type a single . on a\nline by itself (or press Ctrl+D). Ctrl+C cancels without saving.\x01n\n`
.line:
    push ecx
    mov esi, te_prompt
    mov bl, 0x08
    xor bh, bh
    call readline
    pop ecx
    cmp eax, 2
    je .cancel
    mov edx, eax
    cmp word [line_buf], '.'
    je .finish
    cmp edx, 1
    jne .add
    cmp dword [line_len], 0
    je .finish
.add:
    mov eax, [line_len]
    inc eax
    add eax, ecx
    cmp eax, FS_SLOT_SIZE
    ja .full
    mov esi, line_buf
    lea edi, [SCRATCH + ecx]
    mov ecx, [line_len]
    rep movsb
    mov byte [edi], 10
    mov ecx, eax
    cmp edx, 1
    je .finish
    jmp .line
.full:
    PRINTF `\x01ywarning:\x01n the file is full (4096 bytes) - that line was not added.\n`
.finish:
    clc
    ret
.cancel:
    stc
    ret

section .data
te_prompt   db "  | ", 0
section .text

cmd_write:
    mov ecx, 1
    mov esi, u_write
    call need_args
    jc .ret
    mov esi, [argv + 4]
    call check_new_file
    jc .ret
    call fs_find
    jc .new
    mov esi, q_replace
    call confirm
    jc .kept
.new:
    PRINTF `Writing \x01w%s\x01n\n`, dword [argv + 4]
    xor ecx, ecx
    call text_entry
    jc .cancelled
    jmp save_scratch
.kept:
    PRINTF `Nothing was changed.\n`
.ret:
    ret
.cancelled:
    PRINTF `Cancelled - nothing was saved.\n`
    ret

save_scratch:
    mov esi, [argv + 4]
    mov edx, SCRATCH
    call fs_save
    jc print_fs_error
    PRINTF `\x01gSaved\x01n %s (%d bytes).\n`, esi, ecx
    ret

cmd_append:
    mov ecx, 1
    mov esi, u_append
    call need_args
    jc .ret
    mov esi, [argv + 4]
    call check_new_file
    jc .ret
    xor ecx, ecx
    call fs_find
    jc .new
    mov ecx, [edi + DE_SIZE]
    call fs_slot
    mov edi, SCRATCH
    call mem_copy
    jecxz .announce
    cmp byte [SCRATCH + ecx - 1], 10
    je .announce
    cmp ecx, FS_SLOT_SIZE
    jae .announce
    mov byte [SCRATCH + ecx], 10
    inc ecx
.announce:
    PRINTF `Adding to \x01w%s\x01n (%d bytes so far)\n`, dword [argv + 4], ecx
    jmp .type
.new:
    PRINTF `\x01w%s\x01n does not exist yet - it will be created.\n`, esi
.type:
    call text_entry
    jc .cancelled
    jmp save_scratch
.cancelled:
    PRINTF `Cancelled - the file was not changed.\n`
.ret:
    ret

cmd_rm:
    mov ecx, 1
    mov esi, u_rm
    call need_args
    jc .ret
    mov esi, [argv + 4]
    call open_file
    jc .ret
    PRINTF `Delete \x01w%s\x01n (%d bytes)?`, edi, dword [edi + DE_SIZE]
    push esi
    mov esi, q_empty
    call confirm
    pop esi
    jc .kept
    call fs_delete
    PRINTF `Deleted %s.\n`, esi
    ret
.kept:
    PRINTF `Nothing was deleted.\n`
.ret:
    ret

cmd_rename:
    mov ecx, 2
    mov esi, u_rename
    call need_args
    jc .ret
    mov esi, [argv + 4]
    call open_file
    jc .ret
    mov esi, [argv + 8]
    call fs_rename
    jc print_fs_error
    PRINTF `Renamed %s to \x01w%s\x01n.\n`, dword [argv + 4], esi
.ret:
    ret

cmd_copy:
    mov ecx, 2
    mov esi, u_copy
    call need_args
    jc .ret
    mov esi, [argv + 4]
    call open_file
    jc .ret
    mov edi, [argv + 8]
    call str_icmp
    je .same
    mov esi, edi
    call check_new_file
    jc .ret
    call fs_find
    jc .copy
    mov esi, q_replace
    call confirm
    jc .kept
.copy:
    mov esi, [argv + 4]
    call fs_find
    mov ecx, [edi + DE_SIZE]
    call fs_slot
    mov edi, SCRATCH
    call mem_copy
    mov esi, [argv + 8]
    mov edx, SCRATCH
    call fs_save
    jc print_fs_error
    PRINTF `Copied %s to \x01w%s\x01n (%d bytes).\n`, dword [argv + 4], esi, ecx
.ret:
    ret
.same:
    PRINTF `\x01rerror:\x01n source and destination are the same file.\n`
    ret
.kept:
    PRINTF `Nothing was copied.\n`
    ret

cmd_find:
    mov ecx, 1
    mov esi, u_find
    call need_args
    jc .ret
    mov esi, [argv + 4]
    mov [fnd_ptr], esi
    call str_len
    mov [fnd_len], ecx
    mov dword [fnd_count], 0
    cmp dword [argc], 3
    jb .all
    mov esi, [argv + 8]
    call open_file
    jc .ret
    call out_begin
    call find_in_file
    jmp .summary
.all:
    call out_begin
    xor ebx, ebx
.l: call fs_entry
    test byte [edi + DE_FLAGS], FLAG_USED
    jz .n
    call find_in_file
.n: inc ebx
    cmp ebx, FS_MAX_FILES
    jb .l
.summary:
    cmp dword [fnd_count], 0
    jne .found
    PRINTF `No lines contain '\x01w%s\x01n'.\n`, dword [fnd_ptr]
    jmp .flush
.found:
    PRINTF `\x01d%d matching line(s).\x01n\n`, dword [fnd_count]
.flush:
    xor ebx, ebx
    call out_flush
.ret:
    ret

find_in_file:
    pushad
    call fs_entry
    mov [fnd_name], edi
    mov edx, [edi + DE_SIZE]
    call fs_slot
    lea ebp, [esi + edx]
    mov dword [fnd_lineno], 0
.line:
    cmp esi, ebp
    jae .done
    inc dword [fnd_lineno]
    mov edi, esi
.eol:
    cmp edi, ebp
    jae .got
    cmp byte [edi], 10
    je .got
    inc edi
    jmp .eol
.got:
    mov ecx, edi
    sub ecx, esi
    call line_contains
    jc .next
    inc dword [fnd_count]
    PRINTF `\x01c%s\x01n:\x01y%d\x01n: `, dword [fnd_name], dword [fnd_lineno]
    cmp ecx, 56
    jbe .print
    mov ecx, 56
.print:
    call out_text
    mov al, 10
    call out_char
.next:
    lea esi, [edi + 1]
    jmp .line
.done:
    popad
    ret

line_contains:
    pushad
    mov edx, [fnd_len]
    mov edi, [fnd_ptr]
.pos:
    cmp ecx, edx
    jb .no
    xor ebx, ebx
.cmp:
    cmp ebx, edx
    jae .yes
    mov al, [esi + ebx]
    call to_lower
    mov ah, al
    mov al, [edi + ebx]
    call to_lower
    cmp al, ah
    jne .adv
    inc ebx
    jmp .cmp
.adv:
    inc esi
    dec ecx
    jmp .pos
.yes:
    popad
    clc
    ret
.no:
    popad
    stc
    ret

cmd_wc:
    mov ecx, 1
    mov esi, u_wc
    call need_args
    jc .ret
    mov esi, [argv + 4]
    call open_file
    jc .ret
    mov ecx, [edi + DE_SIZE]
    push ecx
    call fs_slot
    xor eax, eax
    xor edx, edx
    mov bl, 1
    jecxz .count_done
.c: mov bh, [esi]
    inc esi
    cmp bh, 10
    jne .not_nl
    inc eax
.not_nl:
    cmp bh, ' '
    jbe .space
    test bl, bl
    jz .in_word
    inc edx
    xor bl, bl
    jmp .in_word
.space:
    mov bl, 1
.in_word:
    loop .c
    cmp bh, 10
    je .count_done
    inc eax
.count_done:
    pop ecx
    PRINTF `\x01w  lines   words   bytes  file\x01n\n`
    PRINTF `%7d %7d %7d  %s\n`, eax, edx, ecx, dword [argv + 4]
.ret:
    ret

cmd_hexdump:
    mov ecx, 1
    mov esi, u_hexdump
    call need_args
    jc .ret
    mov esi, [argv + 4]
    call open_file
    jc .ret
    mov ebp, [edi + DE_SIZE]
    test ebp, ebp
    jnz .dump
    PRINTF `(%s is empty)\n`, esi
.ret:
    ret
.dump:
    call fs_slot
    call out_begin
    PRINTF `\x01w offset  00 01 02 03 04 05 06 07  08 09 0A 0B 0C 0D 0E 0F   text\x01n\n`
    xor ebx, ebx
.row:
    cmp ebx, ebp
    jae .end
    PRINTF ` \x01d%04x\x01n    `, ebx
    xor ecx, ecx
.hex:
    lea eax, [ebx + ecx]
    cmp eax, ebp
    jae .blank
    movzx eax, byte [esi + eax]
    PRINTF `%02x `, eax
    jmp .hex_next
.blank:
    PRINTF `   `
.hex_next:
    cmp ecx, 7
    jne .no_gap
    PRINTF ` `
.no_gap:
    inc ecx
    cmp ecx, 16
    jb .hex
    PRINTF ` \x01d|\x01n`
    xor ecx, ecx
.asc:
    lea eax, [ebx + ecx]
    cmp eax, ebp
    jae .asc_end
    mov al, [esi + eax]
    cmp al, 32
    jb .dot
    cmp al, 126
    jbe .asc_put
.dot:
    mov al, '.'
.asc_put:
    call out_char
    inc ecx
    cmp ecx, 16
    jb .asc
.asc_end:
    PRINTF `\x01d|\x01n\n`
    add ebx, 16
    jmp .row
.end:
    PRINTF `\n %d bytes\n`, ebp
    xor ebx, ebx
    call out_flush
    ret

echo_prepare:
.trim:
    jecxz .done
    cmp byte [esi + ecx - 1], ' '
    jne .quotes
    dec ecx
    jmp .trim
.quotes:
    cmp ecx, 2
    jb .done
    cmp byte [esi], '"'
    jne .done
    cmp byte [esi + ecx - 1], '"'
    jne .done
    inc esi
    sub ecx, 2
.done:
    ret

cmd_echo:
    mov esi, [rest_ptr]
    mov edi, esi
.scan:
    mov al, [edi]
    test al, al
    jz .plain
    cmp al, '>'
    je .redirect
    inc edi
    jmp .scan
.plain:
    mov ecx, edi
    sub ecx, esi
    call echo_prepare
    jecxz .nl
.p: lodsb
    call vga_putc_raw
    loop .p
.nl:
    mov al, 10
    call vga_putc
    ret

.redirect:
    lea edx, [edi + 1]
    xor ebx, ebx
    cmp byte [edx], '>'
    jne .one
    inc edx
    inc ebx
.one:
    mov ecx, edi
    sub ecx, esi
    call echo_prepare
    push esi
    mov esi, edx
    call skip_spaces
    mov edx, esi
.nm:
    mov al, [esi]
    test al, al
    jz .nm_end
    cmp al, ' '
    je .nm_cut
    inc esi
    jmp .nm
.nm_cut:
    mov byte [esi], 0
.nm_end:
    pop esi
    cmp byte [edx], 0
    jne .have_name
    PRINTF `\x01rerror:\x01n put a file name after >, for example: \x01wecho hello > note.txt\x01n\n`
    ret
.have_name:
    push esi
    mov esi, edx
    call check_new_file
    pop esi
    jc .ret
    xor eax, eax
    test ebx, ebx
    jz .build
    push esi
    push ecx
    mov esi, edx
    call fs_find
    jc .no_old
    mov ecx, [edi + DE_SIZE]
    mov eax, ecx
    call fs_slot
    mov edi, SCRATCH
    call mem_copy
.no_old:
    pop ecx
    pop esi
    test eax, eax
    jz .build
    cmp byte [SCRATCH + eax - 1], 10
    je .build
    mov byte [SCRATCH + eax], 10
    inc eax
.build:
    lea edi, [SCRATCH + eax]
    add eax, ecx
    inc eax
    cmp eax, FS_SLOT_SIZE
    ja .too_big
    rep movsb
    mov byte [edi], 10
    mov ecx, eax
    mov esi, edx
    mov edx, SCRATCH
    call fs_save
    jc print_fs_error
    PRINTF `\x01d(%s now has %d bytes)\x01n\n`, esi, ecx
.ret:
    ret
.too_big:
    mov esi, err_too_big
    jmp print_fs_error

cmd_clear:
    call vga_clear
    ret
