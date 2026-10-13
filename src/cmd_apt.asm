; =============================================================================
;  cmd_apt.asm - apt: the MOOS package manager (HTTPS from GitHub, or HTTP)
;
;  A package is one text file, <name>.pkg (format below; see PACKAGES.md and
;  tools/mkpkg.py). apt downloads it and writes the files inside it onto the
;  MOOS disk.
;
;      MOOSPKG 1
;      name: hello
;      desc: a friendly greeting
;      @file hello.ms 23
;      print "hello, world!"
;      @end
;
;  Where packages come from:
;    apt install <name>       <repo>/<name>.pkg, where the repo defaults to
;                             the packages/ folder of the MOOS GitHub repo
;    apt install /user/repo   moos.pkg at the top of GitHub repo user/repo
;  GitHub is reached over HTTPS with the server certificate checked (tls.asm,
;  x509.asm). "apt repo <url>" points apt somewhere else (http:// or https://).
; =============================================================================
section .bss
alignb 4
apt_repo_url    resb 192        ; base URL of the package repository
apt_url         resb 400        ; URL being downloaded
apt_label       resb 24         ; package name for the .inst marker
apt_pkg_name    resb 64         ; file name being installed
apt_arg         resd 1
pkg_parse_ptr   resd 1
pkg_parse_end   resd 1
apt_installed   resd 1          ; files installed from the current package
apt_skipped     resd 1

section .data
apt_repo_file   db "apt.repo", 0
apt_repo_def    db "https://raw.githubusercontent.com/treedev10/moos/HEAD/packages", 0
apt_gh_prefix   db "https://raw.githubusercontent.com/", 0
apt_gh_suffix   db "/HEAD/moos.pkg", 0
str_install     db "install", 0
str_remove      db "remove", 0
str_repo        db "repo", 0
str_apt_list    db "list", 0
str_github      db "github", 0
pkg_magic       db "MOOSPKG", 0
tag_file        db "@file", 0
tag_name        db "name:", 0
inst_suffix     db ".inst", 0
pkg_suffix      db ".pkg", 0
apt_slash       db "/", 0
; files a package may never replace (MOOS's own settings)
apt_protected   dd apt_repo_file, login_file, clk_cfg_name, 0

section .text

; apt_load_repo: read apt.repo into apt_repo_url, or use the default
apt_load_repo:
    pushad
    mov esi, apt_repo_file
    call fs_find
    jc .default
    mov ecx, [edi + DE_SIZE]
    cmp ecx, 190
    jbe .size_ok
    mov ecx, 190
.size_ok:
    call fs_slot
    mov edi, apt_repo_url
    rep movsb
    mov byte [edi], 0
    mov edi, apt_repo_url           ; stop at the first newline
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
    mov edi, apt_repo_url
    call str_copy
.parsed:
    mov esi, apt_repo_url           ; drop a trailing "/"
    call str_len
    jecxz .done
    cmp byte [apt_repo_url + ecx - 1], '/'
    jne .done
    mov byte [apt_repo_url + ecx - 1], 0
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
    je apt_install
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
    PRINTF `  apt install <name>       install a package from the package repository\n`
    PRINTF `  apt install /user/repo   install the package in a GitHub repository\n`
    PRINTF `  apt remove <name>        forget an installed package\n`
    PRINTF `  apt list                 list installed packages\n`
    PRINTF `  apt repo [url | github]  show or change the package repository\n`
    PRINTF `\nRepository: \x01w%s\x01n\nSee \x01wman apt\x01n, and PACKAGES.md to publish your own.\n`, apt_repo_url
    ret

.repo:
    cmp dword [argc], 3
    jb .repo_show
    mov esi, [argv + 8]
    mov edi, str_github             ; "apt repo github" = back to the default
    call str_icmp
    jne .repo_set
    mov esi, apt_repo_def
.repo_set:
    mov edi, apt_repo_url
    call str_copy
    mov esi, apt_repo_url
    call str_len
    mov esi, apt_repo_file
    mov edx, apt_repo_url
    call fs_save
    jc .repo_err
    call apt_load_repo
    PRINTF `Package repository set to \x01w%s\x01n.\n`, apt_repo_url
    ret
.repo_err:
    PRINTF `\x01rerror:\x01n %s\n`, esi
    ret
.repo_show:
    PRINTF `Package repository: \x01w%s\x01n\n`, apt_repo_url
    ret

.list:
    PRINTF `Installed packages:\n`
    xor ebx, ebx
    xor ebp, ebp
.list_l:
    call fs_entry
    test byte [edi + DE_FLAGS], FLAG_USED
    jz .list_n
    mov esi, edi                    ; entry ptr = name ptr (DE_NAME = 0)
    call ends_with_inst             ; preserves ESI
    jc .list_n
    push edi
    mov edi, apt_pkg_name           ; the name without ".inst"
    call str_copy
    pop edi
    mov esi, apt_pkg_name
    call str_len
    mov byte [apt_pkg_name + ecx - 5], 0
    push ebx                        ; and where it came from
    call fs_slot
    mov ecx, [edi + DE_SIZE]
    cmp ecx, 300
    jbe .src_n
    mov ecx, 300
.src_n:
    push edi
    mov edi, apt_url
    rep movsb
    mov byte [edi], 0
    pop edi
    pop ebx
    PRINTF `  \x01c%14s\x01n %s\n`, apt_pkg_name, apt_url
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

; apt_install: "apt install <name>" or "apt install /user/repo"
apt_install:
    cmp dword [argc], 3
    jb cmd_apt.usage
    mov esi, [argv + 8]
    mov [apt_arg], esi
    mov byte [apt_label], 0
    mov edi, apt_url
    mov byte [edi], 0
    push esi                        ; GitHub "user/repo" if it has a slash
.slash:
    mov al, [esi]
    test al, al
    jz .not_gh
    cmp al, '/'
    je .is_gh
    inc esi
    jmp .slash
.is_gh:
    pop esi
    cmp byte [esi], '/'
    jne .gh_noslash
    inc esi
.gh_noslash:
    push esi
    mov esi, apt_gh_prefix
    call str_append
    pop esi
    call str_append                 ; user/repo
    mov esi, apt_gh_suffix
    call str_append
    jmp .fetch
.not_gh:
    pop esi
    mov esi, apt_repo_url           ; <repo>/<name>.pkg
    call str_append
    mov esi, apt_slash
    call str_append
    mov esi, [apt_arg]
    call str_append
    mov esi, pkg_suffix
    call str_append
.fetch:
    PRINTF `Downloading \x01w%s\x01n\n  from %s\n`, dword [apt_arg], apt_url
    mov esi, apt_url
    call url_fetch
    jc .fail
    cmp dword [http_status], 200
    je .got
    cmp dword [http_status], 404
    je .missing
    PRINTF `\x01rerror:\x01n the server answered HTTP %d.\n`, dword [http_status]
    ret
.missing:
    PRINTF `\x01rerror:\x01n there is no package called '%s' there (HTTP 404).\n`, dword [apt_arg]
    ret
.got:
    mov esi, str_secure_tls
    cmp byte [url_scheme], 1
    je .sec
    mov esi, str_secure_http
.sec:
    PRINTF `  (%s)\n`, esi
    call pkg_install
    ret
.fail:
    PRINTF `\x01rerror:\x01n %s\n`, dword [url_err]
    ret

; apt_protected_name: ESI = file name -> CF=1 if a package may not write it
apt_protected_name:
    pushad
    mov ebx, apt_protected
.l: mov edi, [ebx]
    test edi, edi
    jz .check_inst
    call str_icmp
    je .yes
    add ebx, 4
    jmp .l
.check_inst:
    call ends_with_inst
    jnc .yes
    popad
    clc
    ret
.yes:
    popad
    stc
    ret

; apt_set_label: ESI = text -> apt_label = a safe file-name version of it
; (letters, digits, . - _; at most 14 characters)
apt_set_label:
    pushad
    mov edi, apt_label
    xor ecx, ecx
.l: mov al, [esi]
    test al, al
    jz .done
    cmp al, ' '
    je .done
    cmp ecx, 14
    jae .done
    call to_lower
    cmp al, 'a'
    jb .not_letter
    cmp al, 'z'
    jbe .ok
.not_letter:
    cmp al, '0'
    jb .other
    cmp al, '9'
    jbe .ok
.other:
    cmp al, '.'
    je .ok
    cmp al, '-'
    je .ok
    mov al, '_'
.ok:
    mov [edi + ecx], al
    inc ecx
    inc esi
    jmp .l
.done:
    mov byte [edi + ecx], 0
    popad
    ret

; pkg_install: parse the package in PKG_BUF and write its files to the disk
pkg_install:
    mov esi, pkg_magic              ; must start with "MOOSPKG"
    mov edi, PKG_BUF
    call str_iprefix
    jne .bad
    mov dword [apt_installed], 0
    mov dword [apt_skipped], 0
    mov eax, PKG_BUF
    mov [pkg_parse_ptr], eax
    add eax, [pkg_len]
    mov [pkg_parse_end], eax
.lines:
    call pkg_next_line              ; ESI = line, or CF=1 at the end
    jc .finish
    push esi
    mov edi, esi                    ; "name: <name>"?
    mov esi, tag_name
    call str_iprefix
    pop esi
    jne .not_name
    add esi, 5
    call skip_spaces
    call apt_set_label
    jmp .lines
.not_name:
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
    cmp eax, [pkg_parse_end]        ; the data must really be there
    ja .bad
    mov [pkg_parse_ptr], eax
    mov esi, apt_pkg_name
    call apt_protected_name
    jnc .write
    inc dword [apt_skipped]
    PRINTF `  \x01yskipped\x01n %s (packages may not replace MOOS settings)\n`, apt_pkg_name
    jmp .lines
.write:
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
    cmp byte [apt_label], 0         ; no "name:" line: use the argument's
    jne .have_label                 ; last part
    mov esi, [apt_arg]
    mov eax, esi
.last:
    mov dl, [esi]
    test dl, dl
    jz .last_done
    inc esi
    cmp dl, '/'
    jne .last
    mov eax, esi
    jmp .last
.last_done:
    mov esi, eax
    call apt_set_label
.have_label:
    mov esi, apt_label              ; marker <label>.inst = where it came from
    mov edi, apt_pkg_name
    call str_copy
    mov esi, inst_suffix
    mov edi, apt_pkg_name
    call str_append
    mov esi, apt_url
    call str_len
    mov esi, apt_pkg_name
    mov edx, apt_url
    call fs_save
    PRINTF `\x01gDone.\x01n Installed \x01w%s\x01n: %d file(s).\n`, apt_label, dword [apt_installed]
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
    push ecx
    xor ecx, ecx
.l: mov al, [esi]
    test al, al
    jz .e
    cmp al, ' '
    je .e
    cmp ecx, 60
    jae .skip
    mov [edi], al
    inc edi
    inc ecx
.skip:
    inc esi
    jmp .l
.e: mov byte [edi], 0
    pop ecx
    pop edi
    ret

; ends_with_inst: ESI = name -> CF=0 if it ends with ".inst"
ends_with_inst:
    push esi
    push edi
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
    pop edi
    pop esi
    clc
    ret
.no:
    pop ecx
    pop edi
    pop esi
    stc
    ret
