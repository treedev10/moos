; =============================================================================
;  cmd_files.asm - ls, cat, write, append, rm, rename, copy, find, wc,
;                  hexdump, echo, clear, and the folder commands cd, pwd,
;                  mkdir, rmdir
;  Every file name may be a path ("notes/plan.txt", "/a/b", "../x"); see
;  fs.asm. Paths without a leading "/" start in the current folder.
;  Commands read argc / argv / rest_ptr and may change any register.
; =============================================================================
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
fnd_skip    resd 1                  ; (find: how much of a path to leave out)
ls_dir      resd 1                  ; the folder ls lists
cp_src      resd 1                  ; (copy: the source's index)
cp_dst      resd 1                  ; (copy: the destination path)
fc_path     resb FS_PATH_MAX        ; a path being built or shown
fc_name     resb 24                 ; (ls: a folder's name with its "/")

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
u_mkdir     db "mkdir <folder> [folder ...]", 0
u_rmdir     db "rmdir <folder>", 0
q_replace   db "That file already exists. Replace it?", 0
q_empty     db "", 0

section .text

; open_file: ESI = path -> CF=0, EBX = index, EDI = entry of that file.
; CF=1 after printing a friendly message when there is no such file (or
; it is a folder).
open_file:
    call fs_find
    jc .none
    test byte [edi + DE_FLAGS], FLAG_DIR
    jz .ok                          ; (test leaves CF=0)
    PRINTF `'\x01w%s\x01n' is a folder, not a file. Type \x01wls %s\x01n to see what is in it.\n`, esi, esi
    stc
    ret
.none:
    PRINTF `There is no file named '\x01w%s\x01n'. Type \x01wls\x01n to see your files.\n`, esi
    stc
.ok:
    ret

; find_any: ESI = path -> CF=0, EBX = index, EDI = entry of that file or
; folder; CF=1 after a message when there is none
find_any:
    call fs_find
    jnc .ok
    PRINTF `There is no file or folder named '\x01w%s\x01n'. Type \x01wls\x01n to see them.\n`, esi
    stc
.ok:
    ret

; print_fs_error: ESI = message from the file system
print_fs_error:
    PRINTF `\x01rerror:\x01n %s\n`, esi
    ret

; check_new_file: ESI = path. CF=1 (message printed) if a file cannot be
; saved there: a folder on the way is missing, the name is not valid, it
; is a folder, or the file does not exist yet and all 32 entries are taken.
check_new_file:
    pushad
    call fs_resolve
    jc .fail
    call fs_leaf_check
    jc .fail
    push esi
    mov esi, fs_leaf
    call fs_lookup
    pop esi
    jc .new
    mov eax, err_is_folder
    test byte [edi + DE_FLAGS], FLAG_DIR
    jnz .fail
    jmp .ok
.new:
    call fs_stats
    cmp eax, FS_MAX_FILES
    jb .ok
    mov eax, err_disk_full
.fail:
    PRINTF `\x01rerror:\x01n %s: %s\n`, esi, eax
    popad
    stc
    ret
.ok:
    popad
    clc
    ret

; unpack_mtime: EAX = packed time -> dt_* variables
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

; out_text: ESI = bytes, ECX = count. Sends text to out_char, replacing
; control characters (except tab and newline) with '.'
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

; ------------------------------------------------------------------------- ls
; ls [folder]: the folders in it (in blue, with a "/") and then its files
cmd_ls:
    mov eax, [fs_cwd]
    cmp dword [argc], 2
    jb .have
    mov esi, [argv + 4]
    call fs_find_dir
    jnc .have
    call fs_find                    ; a file: just its line
    jc .bad
    test byte [edi + DE_FLAGS], FLAG_DIR
    jnz .bad
    call ls_line
    ret
.bad:
    PRINTF `\x01rerror:\x01n %s: %s\n`, esi, eax
    ret
.have:
    mov [ls_dir], eax
    call fs_stats
    test eax, eax
    jnz .list
    PRINTF `No files yet. Create one with \x01wwrite notes.txt\x01n or a folder with \x01wmkdir notes\x01n\n`
    ret
.list:
    call out_begin
    mov eax, [ls_dir]
    test eax, eax
    jz .head
    mov edi, fc_path
    call fs_path
    PRINTF `  In \x01w%s\x01n\n`, edi
.head:
    mov eax, [ls_dir]
    call fs_dir_count
    test ecx, ecx
    jnz .cols
    PRINTF `  (this folder is empty)\n`
    jmp .summary
.cols:
    PRINTF `\x01w  NAME                     SIZE    MODIFIED\x01n\n`
    mov dl, FLAG_DIR                ; folders first, then files
.pass:
    xor ebx, ebx
.l: call fs_entry
    test byte [edi + DE_FLAGS], FLAG_USED
    jz .n
    mov al, [ls_dir]
    cmp [edi + DE_PARENT], al
    jne .n
    mov al, [edi + DE_FLAGS]
    and al, FLAG_DIR
    cmp al, dl
    jne .n
    call ls_line
.n: inc ebx
    cmp ebx, FS_MAX_FILES
    jb .l
    sub dl, FLAG_DIR
    jz .pass
.summary:
    call fs_counts
    PRINTF `\n  %d file(s) and %d folder(s) on the disk, `, eax, ecx
    call fs_stats
    PRINTF `%d bytes: %d of 32 entries used.\n  Each file can hold up to 4096 bytes.\n`, edx, eax
    cmp byte [fs_persist], 0
    jne .flush
    PRINTF `  \x01yNote:\x01n no disk was found, so files disappear when the computer is turned off.\n`
.flush:
    xor ebx, ebx
    call out_flush
    ret

; ls_line: EDI = entry -> one line of ls: name, size (or "folder"), date
ls_line:
    pushad
    mov eax, [edi + DE_MTIME]
    call unpack_mtime
    test byte [edi + DE_FLAGS], FLAG_DIR
    jnz .folder
    PRINTF `  \x01c%20s\x01n %6d B  `, edi, dword [edi + DE_SIZE]
    jmp .date
.folder:
    mov esi, edi
    mov edi, fc_name
    call str_copy
    mov esi, fs_slash
    call str_append
    PRINTF `  \x01b%20s\x01n   folder  `, edi
.date:
    PRINTF `%d-%02d-%02d %02d:%02d\n`, dword [dt_year], dword [dt_mon], dword [dt_day], dword [dt_hour], dword [dt_min]
    popad
    ret

section .data
fs_slash    db "/", 0
section .text

; ------------------------------------------------------------------------ cat
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

; --------------------------------------------------------------- write/append
; text_entry: ECX = bytes already in SCRATCH. Reads lines from the keyboard
; until "." alone or Ctrl+D. -> ECX = new length, CF=1 if cancelled.
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
    mov edx, eax                    ; 1 = Ctrl+D
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

; save_scratch: save ECX bytes of SCRATCH as argv[1] and report
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
    mov byte [SCRATCH + ecx], 10    ; start the new text on its own line
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

; ------------------------------------------------------------------------- rm
cmd_rm:
    mov ecx, 1
    mov esi, u_rm
    call need_args
    jc .ret
    mov esi, [argv + 4]
    call fs_find
    jc .file
    test byte [edi + DE_FLAGS], FLAG_DIR
    jz .file
    PRINTF `'\x01w%s\x01n' is a folder. Remove an empty folder with \x01wrmdir %s\x01n.\n`, esi, esi
    ret
.file:
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

; --------------------------------------------------------------------- rename
cmd_rename:
    mov ecx, 2
    mov esi, u_rename
    call need_args
    jc .ret
    mov esi, [argv + 4]
    call find_any
    jc .ret
    mov esi, [argv + 8]
    call fs_find_dir                ; into another folder: say "moved"
    jc .rename
    dec eax
    cmp eax, ebx
    je .rename
    call fs_rename
    jc print_fs_error
    PRINTF `Moved %s into \x01b%s\x01n.\n`, dword [argv + 4], esi
    ret
.rename:
    call fs_rename
    jc print_fs_error
    PRINTF `Renamed %s to \x01w%s\x01n.\n`, dword [argv + 4], esi
.ret:
    ret

; ----------------------------------------------------------------------- copy
; copy <source> <destination>: the destination may be a folder (the copy
; keeps the source's name there)
cmd_copy:
    mov ecx, 2
    mov esi, u_copy
    call need_args
    jc .ret
    mov esi, [argv + 4]
    call open_file
    jc .ret
    mov [cp_src], ebx
    mov esi, [argv + 8]
    mov [cp_dst], esi
    call fs_find_dir                ; into a folder: <folder>/<name>
    jc .named
    mov edi, fc_path
    call str_copy
    call str_len
    cmp byte [esi + ecx - 1], '/'   ; ("folder/" already ends with one)
    je .slashed
    mov esi, fs_slash
    call str_append
.slashed:
    call fs_entry
    mov esi, edi
    mov edi, fc_path
    call str_append
    mov [cp_dst], edi
.named:
    mov esi, [cp_dst]
    call fs_find
    jc .check
    cmp ebx, [cp_src]
    je .same
.check:
    call check_new_file
    jc .ret
    call fs_find
    jc .copy
    mov esi, q_replace
    call confirm
    jc .kept
.copy:
    mov ebx, [cp_src]
    call fs_entry
    mov ecx, [edi + DE_SIZE]
    call fs_slot                    ; copy via SCRATCH (source may move)
    mov edi, SCRATCH
    call mem_copy
    mov esi, [cp_dst]
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

; ----------------------------------------------------------------------- find
; find <text> [file]: without a file, every file in the current folder and
; the folders inside it (shown with their paths from here)
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
    mov [fnd_name], esi
    call out_begin
    call find_in_file
    jmp .summary
.all:
    mov eax, [fs_cwd]               ; paths are shown from the current
    mov edi, fc_path                ; folder: leave out its path + "/"
    call fs_path
    mov esi, edi
    call str_len
    inc ecx
    cmp ecx, 2
    jne .skip
    dec ecx                         ; (the top level: just the "/")
.skip:
    mov [fnd_skip], ecx
    call out_begin
    xor ebx, ebx
.l: call fs_entry
    test byte [edi + DE_FLAGS], FLAG_USED
    jz .n
    test byte [edi + DE_FLAGS], FLAG_DIR
    jnz .n
    mov eax, [fs_cwd]               ; only below the current folder
    test eax, eax
    jz .in
    push ebx
    lea ebx, [eax - 1]
    movzx eax, byte [edi + DE_PARENT]
    call fs_inside
    pop ebx
    jnc .n
.in:
    mov edi, fc_path
    call fs_entry_path
    add edi, [fnd_skip]
    mov [fnd_name], edi
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

; find_in_file: EBX = file index, fnd_name = how to call it. Prints
; "file:line: text" for each match.
find_in_file:
    pushad
    call fs_entry
    mov edx, [edi + DE_SIZE]
    call fs_slot
    lea ebp, [esi + edx]            ; end of data
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

; line_contains: ESI = line, ECX = length -> CF=0 if it contains fnd_ptr
; (case-insensitive)
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

; ------------------------------------------------------------------------- wc
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
    xor eax, eax                    ; lines
    xor edx, edx                    ; words
    mov bl, 1                       ; previous char was a space
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
    cmp bh, 10                      ; last line without a newline
    je .count_done
    inc eax
.count_done:
    pop ecx
    PRINTF `\x01w  lines   words   bytes  file\x01n\n`
    PRINTF `%7d %7d %7d  %s\n`, eax, edx, ecx, dword [argv + 4]
.ret:
    ret

; -------------------------------------------------------------------- hexdump
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
    xor ebx, ebx                    ; offset
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

; ----------------------------------------------------------------------- echo
; echo_prepare: ESI/ECX = text -> trailing spaces and one pair of
; surrounding double quotes removed
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

.redirect:                          ; echo text > file   /   echo text >> file
    lea edx, [edi + 1]
    xor ebx, ebx
    cmp byte [edx], '>'
    jne .one
    inc edx
    inc ebx                         ; EBX = 1: append
.one:
    mov ecx, edi
    sub ecx, esi
    call echo_prepare               ; ESI/ECX = text to store
    push esi
    mov esi, edx
    call skip_spaces
    mov edx, esi                    ; EDX = file name
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
    xor eax, eax                    ; EAX = bytes in SCRATCH
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

; ---------------------------------------------------------------------- clear
cmd_clear:
    call vga_clear
    ret

; ------------------------------------------------------------------- folders
; cd [folder]: change the current folder ("cd" or "cd /" = the top level)
cmd_cd:
    xor eax, eax
    cmp dword [argc], 2
    jb .set
    mov esi, [argv + 4]
    call fs_find_dir
    jc .bad
.set:
    mov [fs_cwd], eax
    ret
.bad:
    PRINTF `\x01rerror:\x01n %s: %s\n`, esi, eax
    ret

; pwd: show the current folder
cmd_pwd:
    mov eax, [fs_cwd]
    mov edi, fc_path
    call fs_path
    PRINTF `%s\n`, edi
    ret

; mkdir <folder> ...: make new, empty folders
cmd_mkdir:
    mov ecx, 1
    mov esi, u_mkdir
    call need_args
    jc .ret
    mov ebx, 1
.next:
    cmp ebx, [argc]
    jae .ret
    mov esi, [argv + ebx * 4]
    push ebx
    call fs_mkdir
    pop ebx
    jc .err
    PRINTF `Made folder \x01b%s\x01n.\n`, esi
    jmp .n
.err:
    PRINTF `\x01rerror:\x01n %s: %s\n`, dword [argv + ebx * 4], esi
.n: inc ebx
    jmp .next
.ret:
    ret

; rmdir <folder>: delete a folder - only an empty one
cmd_rmdir:
    mov ecx, 1
    mov esi, u_rmdir
    call need_args
    jc .ret
    mov esi, [argv + 4]
    call fs_find
    jc .none
    test byte [edi + DE_FLAGS], FLAG_DIR
    jz .file
    lea eax, [ebx + 1]
    call fs_dir_count
    test ecx, ecx
    jnz .full
    call fs_delete
    jc print_fs_error
    PRINTF `Removed folder %s.\n`, esi
.ret:
    ret
.none:
    PRINTF `There is no folder named '\x01w%s\x01n'.\n`, esi
    ret
.file:
    PRINTF `'\x01w%s\x01n' is a file, not a folder. Delete files with \x01wrm\x01n.\n`, esi
    ret
.full:
    PRINTF `The folder '\x01w%s\x01n' is not empty: it holds %d file(s) or folder(s).\nDelete or move them first (\x01wls %s\x01n shows them).\n`, esi, ecx, esi
    ret
