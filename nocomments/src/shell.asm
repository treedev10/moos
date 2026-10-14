MAX_ARGS    equ 16

section .bss
parse_buf   resb 256
alignb 4
argc        resd 1
argv        resd MAX_ARGS
rest_ptr    resd 1
lev_tmp     resd 1
lev_prev    resd 33
lev_cur     resd 33

section .data
prompt_str  db "moos> ", 0
str_man     db "man", 0

section .text

cmd_table:
    COMMAND "help",     cmd_help,     "list all commands",          man_help
    COMMAND "man",      cmd_man,      "read a command's manual",    man_man
    COMMAND "ls",       cmd_ls,       "list files",                 man_ls
    COMMAND "cat",      cmd_cat,      "show what is in a file",     man_cat
    COMMAND "edit",     cmd_edit,     "full-screen text editor",    man_edit
    COMMAND "write",    cmd_write,    "create or replace a file",   man_write
    COMMAND "append",   cmd_append,   "add lines to a file",        man_append
    COMMAND "rm",       cmd_rm,       "delete a file",              man_rm
    COMMAND "rename",   cmd_rename,   "rename a file",              man_rename
    COMMAND "copy",     cmd_copy,     "copy a file",                man_copy
    COMMAND "find",     cmd_find,     "search text in files",       man_find
    COMMAND "wc",       cmd_wc,       "count lines, words, bytes",  man_wc
    COMMAND "hexdump",  cmd_hexdump,  "show a file as hex bytes",   man_hexdump
    COMMAND "echo",     cmd_echo,     "print text / save to file",  man_echo
    COMMAND "calc",     cmd_calc,     "integer calculator",         man_calc
    COMMAND "run",      cmd_run,      "run a MOOS script",          man_script
    COMMAND "gui",      cmd_gui,      "start the graphical desktop", man_gui
    COMMAND "clear",    cmd_clear,    "clear the screen",           man_clear
    COMMAND "color",    cmd_color,    "change screen colours",      man_color
    COMMAND "time",     cmd_time,     "show date and time",         man_time
    COMMAND "clock",    cmd_clock,    "clock settings, time sync",  man_clock
    COMMAND "net",      cmd_net,      "connect to the network",     man_net
    COMMAND "apt",      cmd_apt,      "install packages",           man_apt
    COMMAND "get",      cmd_get,      "download a web page (https)", man_get
    COMMAND "nettest",  cmd_nettest,  "time a download, SHA-256",   man_net
    COMMAND "uptime",   cmd_uptime,   "time since start-up",        man_uptime
    COMMAND "mem",      cmd_mem,      "memory and storage usage",   man_mem
    COMMAND "sysinfo",  cmd_sysinfo,  "system and CPU details",     man_sysinfo
    COMMAND "history",  cmd_history,  "list recent commands",       man_history
    COMMAND "login",    cmd_login,    "optional sign-in screen",    man_login
    COMMAND "format",   cmd_format,   "erase all files",            man_format
    COMMAND "install",  cmd_install,  "install MOOS on a disk",     man_install
    COMMAND "reboot",   cmd_reboot,   "restart the computer",       man_reboot
    COMMAND "shutdown", cmd_shutdown, "power off the computer",     man_shutdown
    ALIAS "?",        cmd_help,     man_help
    ALIAS "wget",     cmd_get,      man_get
    ALIAS "curl",     cmd_get,      man_get
    ALIAS "nano",     cmd_edit,     man_edit
    ALIAS "notepad",  cmd_edit,     man_edit
    ALIAS "dir",      cmd_ls,       man_ls
    ALIAS "type",     cmd_cat,      man_cat
    ALIAS "more",     cmd_cat,      man_cat
    ALIAS "del",      cmd_rm,       man_rm
    ALIAS "mv",       cmd_rename,   man_rename
    ALIAS "cp",       cmd_copy,     man_copy
    ALIAS "grep",     cmd_find,     man_find
    ALIAS "hex",      cmd_hexdump,  man_hexdump
    ALIAS "cls",      cmd_clear,    man_clear
    ALIAS "colour",   cmd_color,    man_color
    ALIAS "date",     cmd_time,     man_time
    ALIAS "about",    cmd_sysinfo,  man_sysinfo
    ALIAS "ver",      cmd_sysinfo,  man_sysinfo
    ALIAS "restart",  cmd_reboot,   man_reboot
    ALIAS "exit",     cmd_shutdown, man_shutdown
    ALIAS "poweroff", cmd_shutdown, man_shutdown
    ALIAS "halt",     cmd_shutdown, man_shutdown
    dd 0

topic_table:
    TOPIC "intro",    man_intro
    TOPIC "keys",     man_keys
    TOPIC "files",    man_files
    TOPIC "browser",  man_browser
    dd 0

shell_run:
    PRINTF `\nWelcome! Type \x01whelp\x01n to see all commands, or \x01wman intro\x01n for a guided tour.\n`
.loop:
    mov esi, prompt_str
    mov bl, C_PROMPT
    mov bh, RL_HISTORY
    call readline
    test eax, eax
    jnz .loop
    call shell_exec
    jmp .loop

shell_exec:
    pushad
    call tokenize
    cmp dword [argc], 0
    je .done
    mov esi, [argv]
    call cmd_lookup
    jc .unknown
    call [ebx + CMD_FUNC]
    jmp .done
.unknown:
    PRINTF `Unknown command '\x01w%s\x01n'.`, esi
    call suggest_commands
    PRINTF ` Type \x01whelp\x01n to list all commands.\n`
.done:
    mov byte [out_mode], 0
    popad
    ret

tokenize:
    pushad
    mov esi, line_buf
    mov edi, parse_buf
    call str_copy
    mov dword [argc], 0
    mov esi, parse_buf
.next:
    call skip_spaces
    cmp byte [esi], 0
    je .rest
    mov eax, [argc]
    cmp eax, MAX_ARGS
    jae .rest
    mov [argv + eax * 4], esi
    inc dword [argc]
.word:
    mov al, [esi]
    test al, al
    jz .rest
    cmp al, ' '
    je .cut
    inc esi
    jmp .word
.cut:
    mov byte [esi], 0
    inc esi
    jmp .next
.rest:
    mov esi, line_buf
    call skip_spaces
.skip:
    mov al, [esi]
    test al, al
    jz .rest_done
    cmp al, ' '
    je .rest_done
    inc esi
    jmp .skip
.rest_done:
    call skip_spaces
    mov [rest_ptr], esi
    popad
    ret

cmd_lookup:
    push edi
    mov ebx, cmd_table
.l: mov edi, [ebx + CMD_NAME]
    test edi, edi
    jz .nf
    call str_icmp
    je .found
    add ebx, CMD_SIZE
    jmp .l
.nf:
    pop edi
    stc
    ret
.found:
    pop edi
    clc
    ret

need_args:
    push eax
    mov eax, [argc]
    dec eax
    cmp eax, ecx
    jae .ok
    PRINTF `usage: \x01w%s\x01n    (details: \x01wman %s\x01n)\n`, esi, dword [argv]
    pop eax
    stc
    ret
.ok:
    pop eax
    clc
    ret

suggest_commands:
    pushad
    call str_len
    cmp ecx, 30
    ja .done
    mov edx, 1
    cmp ecx, 3
    jbe .t
    mov edx, 2
.t: xor ebp, ebp
    mov ebx, cmd_table
.l: mov edi, [ebx + CMD_NAME]
    test edi, edi
    jz .end
    cmp dword [ebx + CMD_DESC], 0
    je .n
    call str_iprefix
    je .hit
    call levenshtein
    cmp eax, edx
    ja .n
.hit:
    test ebp, ebp
    jnz .more
    PRINTF ` Did you mean \x01w%s\x01n`, edi
    jmp .counted
.more:
    PRINTF ` or \x01w%s\x01n`, edi
.counted:
    inc ebp
.n: add ebx, CMD_SIZE
    jmp .l
.end:
    test ebp, ebp
    jz .done
    PRINTF `?`
.done:
    popad
    ret

levenshtein:
    push ebx
    push ecx
    push edx
    push ebp
    call str_len
    mov ebp, ecx
    push esi
    mov esi, edi
    call str_len
    pop esi
    cmp ecx, 32
    jbe .lb_ok
    mov ecx, 32
.lb_ok:
    xor eax, eax
.init:
    mov [lev_prev + eax * 4], eax
    inc eax
    cmp eax, ecx
    jbe .init
    mov ebx, 1
.row:
    cmp ebx, ebp
    ja .finish
    mov [lev_cur], ebx
    mov edx, 1
.col:
    cmp edx, ecx
    ja .row_done
    mov al, [esi + ebx - 1]
    call to_lower
    mov ah, al
    mov al, [edi + edx - 1]
    call to_lower
    cmp al, ah
    setne al
    movzx eax, al
    add eax, [lev_prev + edx * 4 - 4]
    mov [lev_tmp], eax
    mov eax, [lev_prev + edx * 4]
    inc eax
    cmp eax, [lev_tmp]
    jae .a1
    mov [lev_tmp], eax
.a1:
    mov eax, [lev_cur + edx * 4 - 4]
    inc eax
    cmp eax, [lev_tmp]
    jae .a2
    mov [lev_tmp], eax
.a2:
    mov eax, [lev_tmp]
    mov [lev_cur + edx * 4], eax
    inc edx
    jmp .col
.row_done:
    push ecx
    push esi
    push edi
    mov esi, lev_cur
    mov edi, lev_prev
    inc ecx
    rep movsd
    pop edi
    pop esi
    pop ecx
    inc ebx
    jmp .row
.finish:
    mov eax, [lev_prev + ecx * 4]
    pop ebp
    pop edx
    pop ecx
    pop ebx
    ret

cmd_help:
    cmp dword [argc], 2
    jae cmd_man
    call out_begin
    PRINTF `\x01w MOOS commands\x01n - type \x01wman <command>\x01n for the full manual of any of them\n\n`
    mov ebx, cmd_table
    xor ecx, ecx
.l: mov esi, [ebx + CMD_NAME]
    test esi, esi
    jz .end
    mov edi, [ebx + CMD_DESC]
    test edi, edi
    jz .n
    PRINTF `  \x01c%9s\x01n%28s`, esi, edi
    inc ecx
    test ecx, 1
    jnz .n
    PRINTF `\n`
.n: add ebx, CMD_SIZE
    jmp .l
.end:
    test ecx, 1
    jz .tips
    PRINTF `\n`
.tips:
    PRINTF `\n Keys:   \x01wTab\x01n completes names   \x01wUp/Down\x01n recall commands   \x01wCtrl+C\x01n cancels\n`
    PRINTF ` Guides: \x01wman intro\x01n (start here)   \x01wman keys\x01n   \x01wman files\x01n   \x01wman install\x01n\n`
    xor ebx, ebx
    call out_flush
    ret

man_lookup:
    push ebx
    push edi
    call cmd_lookup
    jc .topics
    mov edx, [ebx + CMD_MAN]
    jmp .found
.topics:
    mov ebx, topic_table
.t: mov edi, [ebx]
    test edi, edi
    jz .nf
    call str_icmp
    je .topic_found
    add ebx, 8
    jmp .t
.topic_found:
    mov edx, [ebx + 4]
.found:
    pop edi
    pop ebx
    clc
    ret
.nf:
    pop edi
    pop ebx
    stc
    ret

cmd_man:
    mov esi, str_man
    cmp dword [argc], 2
    jb .show
    mov esi, [argv + 4]
.show:
    call man_lookup
    jc .missing
    call str_lower
    call vga_clear
    mov al, [text_attr]
    push eax
    mov byte [text_attr], C_STATUS
    PRINTF ` MOOS Manual  \xB3  %s`, esi
.bar:
    mov al, ' '
    call vga_putc_raw
    cmp dword [cur_x], 0
    jne .bar
    pop eax
    mov [text_attr], al
    mov esi, edx
    mov bl, PG_HEADINGS | PG_KEEP_TOP
    call pager
    call vga_fresh_line
    PRINTF `\x01d(end of manual - \x01wman intro\x01d for the tour, \x01whelp\x01d for all commands)\x01n\n`
    ret
.missing:
    PRINTF `No manual entry for '\x01w%s\x01n'.`, esi
    call suggest_commands
    PRINTF ` Try \x01whelp\x01n or \x01wman intro\x01n.\n`
    ret
