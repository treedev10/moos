; =============================================================================
;  cmd_apt.asm - apt: the MOOS package manager (downloads over HTTP)
;
;  A package is one text file, <name>.pkg, on an HTTP server. apt downloads it
;  and writes the files inside it onto the MOOS disk. Format (see man apt and
;  tools/mkpkg.py):
;
;      MOOSPKG 1
;      name: hello
;      desc: a friendly greeting
;      @file hello.ms 23
;      print "hello, world!"
;      @end
;
;  Each @file line gives a file name and a byte count; exactly that many bytes
;  follow, then @end. apt saves each file into the file system.
;
;  The repository is an HTTP host (not github.com, which requires HTTPS). It is
;  kept in apt.repo. "apt install /user/repo" fetches /user/repo.pkg from it,
;  so a layout that mirrors GitHub paths works behind an HTTP mirror.
; =============================================================================
section .bss
alignb 4
apt_repo_host   resb 64         ; host[:port], e.g. "10.0.2.2:8000"
apt_repo_ip     resd 1
apt_repo_port   resw 1
alignb 4
apt_path        resb 128
apt_pkg_name    resb 64
pkg_parse_ptr   resd 1
pkg_parse_end   resd 1
apt_installed   resd 1          ; files installed from the current package

section .data
apt_repo_file   db "apt.repo", 0
apt_repo_def    db "10.0.2.2:8000", 0
str_install     db "install", 0
str_remove      db "remove", 0
str_repo        db "repo", 0
str_apt_list    db "list", 0
pkg_magic       db "MOOSPKG", 0
tag_file        db "@file", 0
tag_end         db "@end", 0
inst_suffix     db ".inst", 0

section .text

; apt_load_repo: read apt.repo into apt_repo_host, or use the default
apt_load_repo:
    pushad
    mov esi, apt_repo_file
    call fs_find
    jc .default
    mov ecx, [edi + DE_SIZE]
    cmp ecx, 63
    jbe .size_ok
    mov ecx, 63
.size_ok:
    call fs_slot
    mov edi, apt_repo_host
    rep movsb
    mov byte [edi], 0
    mov edi, apt_repo_host          ; trim a trailing newline
.trim:
    mov al, [edi]
    cmp al, 13
    je .cut
    cmp al, 10
    je .cut
    test al, al
    jz .parsed
    inc edi
    jmp .trim
.cut:
    mov byte [edi], 0
    jmp .parsed
.default:
    mov esi, apt_repo_def
    mov edi, apt_repo_host
    call str_copy
.parsed:
    popad
    ret

; apt_split_repo: parse apt_repo_host into a name and apt_repo_port (default 80)
apt_split_repo:
    pushad
    mov word [apt_repo_port], 80
    mov esi, apt_repo_host
.find:
    mov al, [esi]
    test al, al
    jz .done
    cmp al, ':'
    je .port
    inc esi
    jmp .find
.port:
    mov byte [esi], 0               ; terminate the host part
    inc esi
    call parse_uint
    jc .done
    mov [apt_repo_port], ax
.done:
    popad
    ret

cmd_apt:
    call apt_load_repo
    cmp dword [argc], 2
    jb .usage
    mov esi, [argv + 4]
    mov edi, str_install
    call str_icmp
    je .install
    mov edi, str_remove
    call str_icmp
    je .remove
    mov edi, str_repo
    call str_icmp
    je .repo
    mov edi, str_apt_list
    call str_icmp
    je .list
.usage:
    PRINTF `\x01wapt\x01n - the MOOS package manager\n`
    PRINTF `  apt install <name>     download and install a package\n`
    PRINTF `  apt remove <name>      remove an installed package\n`
    PRINTF `  apt list               list installed packages\n`
    PRINTF `  apt repo [host]        show or set the package server\n`
    PRINTF `\nThe package server is \x01w%s\x01n. See \x01wman apt\x01n to make your own packages.\n`, apt_repo_host
    ret

.repo:
    cmp dword [argc], 3
    jb .repo_show
    mov esi, [argv + 8]
    mov edi, apt_repo_host
    call str_copy
    mov esi, apt_repo_host          ; save it
    mov edx, apt_repo_host
    call str_len
    mov esi, apt_repo_file
    mov edx, apt_repo_host
    call fs_save
    jc .repo_err
    PRINTF `Package server set to \x01w%s\x01n.\n`, apt_repo_host
    ret
.repo_err:
    PRINTF `\x01rerror:\x01n %s\n`, esi
    ret
.repo_show:
    PRINTF `Package server: \x01w%s\x01n\n`, apt_repo_host
    ret

.list:
    PRINTF `Installed packages:\n`
    xor ebx, ebx
    xor ebp, ebp
.list_l:
    call fs_entry
    test byte [edi + DE_FLAGS], FLAG_USED
    jz .list_n
    mov esi, edi                     ; entry ptr = name ptr (DE_NAME = 0)
    call ends_with_inst              ; preserves ESI
    jc .list_n
    mov edi, apt_pkg_name            ; copy the name out, strip ".inst"
    call str_copy
    mov esi, apt_pkg_name
    call str_len
    mov byte [apt_pkg_name + ecx - 5], 0
    PRINTF `  \x01c%s\x01n\n`, apt_pkg_name
    inc ebp
.list_n:
    inc ebx
    cmp ebx, FS_MAX_FILES
    jb .list_l
    test ebp, ebp
    jnz .list_done
    PRINTF `  (none yet - try \x01wapt install hello\x01n)\n`
.list_done:
    ret

.remove:
    cmp dword [argc], 3
    jb .usage
    mov esi, [argv + 8]
    mov edi, apt_pkg_name
    call str_copy
    mov esi, inst_suffix            ; remove the marker file <name>.inst
    mov edi, apt_pkg_name
    call str_append
    mov esi, apt_pkg_name
    call fs_find
    jc .not_installed
    call fs_delete
    PRINTF `Removed %s. (Its files were left in place - delete them with \x01wrm\x01n if you like.)\n`, dword [argv + 8]
    ret
.not_installed:
    PRINTF `%s is not installed.\n`, dword [argv + 8]
    ret

.install:
    cmp dword [argc], 3
    jb .usage
    cmp byte [net_up], 0
    jne .have_net
    PRINTF `Connecting to the network...\n`
    call net_up_bring
    jc .neterr
.have_net:
    call apt_split_repo
    mov esi, apt_repo_host          ; resolve the server
    call dns_resolve
    jc .resolve_fail
    mov [apt_repo_ip], eax
    mov edi, apt_path               ; build the path: /<name>.pkg
    mov esi, [argv + 8]
    cmp byte [esi], '/'             ; "/user/repo" keeps its leading slash
    je .path_abs
    mov byte [edi], '/'
    inc edi
.path_abs:
    call str_copy_noterm
    mov byte [edi], 0
    mov esi, pkg_suffix
    mov edi, apt_path
    call str_append
    PRINTF `Downloading \x01w%s\x01n from %s ...\n`, dword [argv + 8], apt_repo_host
    mov eax, [apt_repo_ip]
    mov bx, [apt_repo_port]
    mov esi, apt_repo_host
    mov edi, apt_path
    call http_get
    jc .dl_fail
    cmp dword [http_status], 200
    je .got
    cmp dword [http_status], 0      ; some servers omit the status on HTTP/1.0
    jne .http_err
.got:
    call pkg_install
    ret
.neterr:
    PRINTF `\x01rCould not connect:\x01n %s\n`, esi
    ret
.resolve_fail:
    PRINTF `\x01rerror:\x01n could not find the server '\x01w%s\x01n'.\n`, apt_repo_host
    ret
.dl_fail:
    PRINTF `\x01rerror:\x01n could not reach the package server.\n`
    ret
.http_err:
    PRINTF `\x01rerror:\x01n the server answered HTTP %d (is the package name right?).\n`, dword [http_status]
    ret

; pkg_install: parse the package in PKG_BUF and write its files to the disk
pkg_install:
    mov esi, pkg_magic              ; must start with "MOOSPKG"
    mov edi, PKG_BUF
    call str_iprefix
    jne .bad
    mov dword [apt_installed], 0
    mov eax, PKG_BUF
    mov [pkg_parse_ptr], eax
    mov eax, PKG_BUF
    add eax, [pkg_len]
    mov [pkg_parse_end], eax
.lines:
    call pkg_next_line              ; ESI = line, or CF=1 at the end
    jc .finish
    push esi
    mov edi, esi                    ; "@file <name> <size>"?
    mov esi, tag_file
    call str_iprefix
    pop esi
    je .file
    jmp .lines
.file:
    add esi, 5                      ; past "@file"
    call skip_spaces
    mov edi, apt_pkg_name           ; file name
    call pkg_copy_word
    call skip_spaces
    call parse_uint                 ; byte count
    jc .bad
    mov ecx, eax                    ; ECX = length
    mov edx, [pkg_parse_ptr]        ; EDX = data (starts on the next line)
    add eax, [pkg_parse_ptr]        ; advance past the data + its newline
    inc eax
    mov [pkg_parse_ptr], eax
    push ecx
    push edx
    mov esi, apt_pkg_name
    call fs_save                    ; ESI = name, EDX = data, ECX = len
    pop edx
    pop ecx
    jc .save_err
    inc dword [apt_installed]
    PRINTF `  installed \x01c%s\x01n (%d bytes)\n`, apt_pkg_name, ecx
    jmp .lines
.finish:
    mov esi, [argv + 8]             ; write the installed-marker file
    mov edi, apt_pkg_name
    call str_copy
    mov esi, inst_suffix
    mov edi, apt_pkg_name
    call str_append                 ; apt_pkg_name = "<name>.inst"
    mov esi, apt_pkg_name
    mov edx, apt_repo_host
    mov ecx, 1
    call fs_save
    PRINTF `\x01gDone.\x01n Installed %d file(s).\n`, dword [apt_installed]
    ret
.bad:
    PRINTF `\x01rerror:\x01n that does not look like a MOOS package.\n`
    ret
.save_err:
    PRINTF `\x01rerror:\x01n %s\n`, esi
    ret

; pkg_next_line: ESI = next line (NUL-terminated in place), CF=1 at the end.
; Advances pkg_parse_ptr past the line.
pkg_next_line:
    mov esi, [pkg_parse_ptr]
    cmp esi, [pkg_parse_end]
    jae .end
    push edi
    mov edi, esi
.scan:
    cmp edi, [pkg_parse_end]
    jae .last
    mov al, [edi]
    cmp al, 10
    je .eol
    inc edi
    jmp .scan
.eol:
    mov byte [edi], 0               ; terminate (overwrites the newline)
    cmp edi, esi
    je .strip
    cmp byte [edi - 1], 13          ; drop a CR before the LF
    jne .strip
    mov byte [edi - 1], 0
.strip:
    lea eax, [edi + 1]
    mov [pkg_parse_ptr], eax
    pop edi
    clc
    ret
.last:
    mov [pkg_parse_ptr], edi
    pop edi
    clc
    ret
.end:
    stc
    ret

; pkg_copy_word: copy a space/NUL-terminated word from ESI to EDI (EDI kept)
pkg_copy_word:
    push edi
.l: mov al, [esi]
    test al, al
    jz .e
    cmp al, ' '
    je .e
    mov [edi], al
    inc edi
    inc esi
    jmp .l
.e: mov byte [edi], 0
    pop edi
    ret

; ends_with_inst: ESI = name -> CF=0 if it ends with ".inst"
ends_with_inst:
    push esi
    push ecx
    call str_len
    cmp ecx, 5
    jb .no
    add esi, ecx
    sub esi, 5
    mov edi, inst_suffix
    call str_icmp
    jne .no
    pop ecx
    pop esi
    clc
    ret
.no:
    pop ecx
    pop esi
    stc
    ret

section .data
pkg_suffix  db ".pkg", 0
section .text
