; =============================================================================
;  cmd_fetch.asm - fetch (alias neofetch): a cow and a summary of the system
;
;  fetch prints the MOOS cow (ASCII art, in colour) on the left and a few
;  lines about the system beside it: who and where, MOOS and its kernel,
;  the firmware, uptime, packages, shell, screen, processor, memory, disk
;  and network, then a row of the 16 text colours. Everything fits in 80
;  columns, so it looks the same on the text console (BIOS and UEFI) and in
;  the desktop's Terminal window (which shows the colours too).
;
;  How the numbers are found:
;    CPU name     CPUID functions 0x80000002-4 (the "brand string")
;    CPU count    the ACPI "APIC" table (MADT) lists every processor the
;                 firmware enabled; without it, CPUID function 1
;    CPU MHz      the time-stamp counter (RDTSC) counted over 10 timer
;                 ticks (1/10 s): cycles per second
;    memory       UEFI: the firmware's memory map (total, and what is still
;                 free); BIOS: what the BIOS reported, and the part MOOS
;                 keeps for itself
;    packages     apt leaves a <name>.inst marker file per package
;
;  Each info line is built in fetch_line (sb_ routines, lib.asm) with
;  colour escapes, then printed through out_char by fetch_print, which
;  stops at column 79 so nothing wraps.
; =============================================================================
FETCH_LOGO_W    equ 26              ; columns the cow takes
FETCH_COL       equ FETCH_LOGO_W + 2 ; where the info lines start
FETCH_LAST      equ 79              ; never print past this column
FETCH_ROWS      equ 15              ; info lines (the cow has 14 rows)
FETCH_BRAND_MAX equ 30              ; characters of the CPU name shown
FC_NAME         equ 1               ; in fetch_line: 1 + letter = a named
FC_NUM          equ 2               ; colour (r g y c w d b m n, as in
                                    ; PRINTF), 2 + number = colour 0-15

section .bss
alignb 4
fetch_col       resd 1              ; the output column now
fetch_row       resd 1
fetch_mhz       resd 1              ; measured clock, 0 if unknown
fetch_ncpu      resd 1
fetch_base      resb 1              ; text_attr when fetch started
fetch_exact     resb 1              ; 1 = text_attr is a numbered colour
                                    ; (the desktop's Terminal then shows
                                    ; it even if it is the normal one)
fetch_line      resb 160

section .data
fetch_host      db "moos", 0
fetch_user_def  db "moos", 0
fl_os           db "OS", 0
fl_fw           db "Firmware", 0
fl_kernel       db "Kernel", 0
fl_uptime       db "Uptime", 0
fl_pkgs         db "Packages", 0
fl_shell        db "Shell", 0
fl_res          db "Resolution", 0
fl_cpu          db "CPU", 0
fl_mem          db "Memory", 0
fl_disk         db "Disk", 0
fl_net          db "Network", 0
fs_os           db OS_NAME, " ", OS_VERSION, " (32-bit x86)", 0
fs_uefi         db "UEFI ", 0
fs_bios         db "PC BIOS (legacy boot)", 0
%ifdef FULL
fs_kernel       db "full kernel (UEFI), ", 0
%else
fs_kernel       db "BIOS kernel, ", 0
%endif
fs_day          db "day", 0
fs_hour         db "hour", 0
fs_min          db "min", 0
fs_sec          db "sec", 0
fs_apt          db " (apt)", 0
fs_shell        db "MOOS shell ", OS_VERSION, 0
fs_text_mode    db "80x25 text (VGA)", 0
fs_mhz          db " MHz", 0
fs_files        db " files, ", 0
fs_one_file     db " file, ", 0
fs_of           db " / ", 0
fs_moosfs       db " (MOOSFS)", 0
fs_ramfs        db " (MOOSFS, RAM only)", 0
fs_noconn       db "not connected", 0
fs_nocard       db "no supported card", 0
fs_tsc          db " @ ", 0
fs_open         db " (", 0
fs_close        db ")", 0
fs_comma        db ", ", 0
fs_proc         db " Processor"     ; (dropped from the end of CPU names)
FS_PROC_LEN     equ $ - fs_proc

; The cow: 14 rows of text, each followed by its colours (a hex digit =
; one of the 16 text colours, a space = the normal colour).
fetch_logo:
    db "  _                     _", 0
    db "  E                     E", 0
    db " ( \                   / )", 0
    db " E E                   E E", 0
    db "  \ \     ,~~~~~,     / /", 0
    db "  E E     8888888     E E", 0
    db "   \ \___/ ~  ~  \___/ /", 0
    db "   E E7777 8  8  7777E E", 0
    db " .--`--./         \.--'--.", 0
    db " 66667777         77776666", 0
    db " `--.__/  (o)  (o) \__.--'", 0
    db " 6666667  FBF  FBF 7666666", 0
    db "       |   ::      |", 0
    db "       7   88      7", 0
    db "       |  :::      |", 0
    db "       7  888      7", 0
    db "        \  _____  /", 0
    db "        7  DDDDD  7", 0
    db "       / ,'     `. \", 0
    db "       7 DD     DD 7", 0
    db "      | |  () () | |", 0
    db "      7 D  55 55 D 7", 0
    db "       \ `._____.' /", 0
    db "       7 DDDDDDDDD 7", 0
    db "        `---._.---'", 0
    db "        777777E7777", 0
    db "            (_)", 0
    db "            EEE", 0
FETCH_LOGO_ROWS equ 14

; the info lines, top to bottom
fetch_lines     dd fi_title, fi_rule, fi_os, fi_fw, fi_kernel, fi_uptime
                dd fi_pkgs, fi_shell, fi_res, fi_cpu, fi_mem, fi_disk
                dd fi_net, fi_blank, fi_colours

section .text

cmd_fetch:
    pushad
    mov al, [text_attr]
    mov [fetch_base], al
    mov byte [fetch_exact], 0
    call cpu_detect                 ; (cmd_system.asm: vendor, brand)
    call cpu_count
    mov [fetch_ncpu], eax
    call tsc_mhz_measure
    mov [fetch_mhz], eax
    call vga_fresh_line
    mov dword [fetch_row], 0
.row:
    mov dword [fetch_col], 0
    ; the cow's row (or blanks below it)
    mov eax, [fetch_row]
    cmp eax, FETCH_LOGO_ROWS
    jae .pad
    call fetch_logo_row
.pad:
    call fetch_plain
.sp:
    cmp dword [fetch_col], FETCH_COL
    jae .info
    mov al, ' '
    call fetch_put
    jmp .sp
.info:
    mov edi, fetch_line
    mov byte [edi], 0
    mov eax, [fetch_row]
    call [fetch_lines + eax * 4]
    mov esi, fetch_line
    call fetch_print
    call fetch_plain
    mov al, 10
    call out_char
    inc dword [fetch_row]
    cmp dword [fetch_row], FETCH_ROWS
    jb .row
    call fetch_plain
    popad
    ret

; fetch_put: AL = character -> printed if it still fits on the line
fetch_put:
    cmp dword [fetch_col], FETCH_LAST
    jae .r
    call out_char
    inc dword [fetch_col]
.r: ret

; fetch_colour: AL = colour 0-15 -> text_attr (on the normal background)
fetch_colour:
    push eax
    and al, 0x0F
    mov ah, [fetch_base]
    and ah, 0xF0
    or al, ah
    mov [text_attr], al
    mov byte [fetch_exact], 1
    pop eax
    ret

; fetch_plain: back to the normal colour
fetch_plain:
    push eax
    mov al, [fetch_base]
    mov [text_attr], al
    mov byte [fetch_exact], 0
    pop eax
    ret

; fetch_print: print the line ESI, obeying FC_NAME / FC_NUM colour escapes
fetch_print:
    push eax
    push esi
.l: lodsb
    test al, al
    jz .e
    cmp al, FC_NAME
    je .name
    cmp al, FC_NUM
    je .num
    call fetch_put
    jmp .l
.name:
    lodsb
    test al, al
    jz .e
    mov ah, [fetch_base]
    call colour_from_letter
    mov [text_attr], al
    mov byte [fetch_exact], 0
    jmp .l
.num:
    lodsb
    test al, al                     ; (colour 0 is stored as 16)
    jz .e
    call fetch_colour
    jmp .l
.e: pop esi
    pop eax
    ret

; fetch_logo_row: EAX = row -> that row of the cow, in its colours
fetch_logo_row:
    pushad
    mov esi, fetch_logo             ; find the row: 2 strings per row
    lea ecx, [eax * 2]
.find:
    jecxz .found
.skip:
    lodsb
    test al, al
    jnz .skip
    dec ecx
    jmp .find
.found:
    mov edi, esi                    ; EDI = the colours, after the text
.end:
    cmp byte [edi], 0
    je .colours
    inc edi
    jmp .end
.colours:
    inc edi
.ch:
    mov al, [esi]
    test al, al
    jz .done
    inc esi
    mov ah, [edi]                   ; its colour (the colour row may be
    test ah, ah                     ; shorter: then the normal colour)
    jz .plain
    inc edi
    push eax
    mov al, ah
    call fetch_hex
    jc .plain_pop
    call fetch_colour
    pop eax
    jmp .put
.plain_pop:
    pop eax
.plain:
    call fetch_plain
.put:
    call fetch_put
    jmp .ch
.done:
    popad
    ret

; fetch_hex: AL = '0'-'9' / 'A'-'F' -> AL = 0-15, CF=1 if not a hex digit
fetch_hex:
    sub al, '0'
    cmp al, 9
    jbe .ok
    sub al, 'A' - '0' - 10
    cmp al, 10
    jb .no
    cmp al, 15
    ja .no
.ok:
    clc
    ret
.no:
    stc
    ret

; ----------------------------------------------------------- info lines
; Each fi_ routine builds its line at EDI (fetch_line).

; fi_label: ESI = label -> "Label: " in the label colour, then normal
fi_label:
    push eax
    push esi
    mov al, FC_NAME
    call sb_char
    mov al, 'y'
    call sb_char
    call sb_str
    mov al, ':'
    call sb_char
    mov al, FC_NAME
    call sb_char
    mov al, 'n'
    call sb_char
    mov al, ' '
    call sb_char
    pop esi
    pop eax
    ret

; fetch_user: ESI = the user's name (sign-in name, or "moos")
fetch_user:
    mov esi, fetch_user_def
    call login_load
    jc .r
    cmp byte [login_user], 0
    je .r
    mov esi, login_user
.r: ret

fi_title:
    mov al, FC_NAME
    call sb_char
    mov al, 'g'
    call sb_char
    call fetch_user
    call sb_str
    mov al, FC_NAME
    call sb_char
    mov al, 'n'
    call sb_char
    mov al, '@'
    call sb_char
    mov al, FC_NAME
    call sb_char
    mov al, 'g'
    call sb_char
    mov esi, fetch_host
    call sb_str
    ret

fi_rule:                            ; a line as long as user@host
    call fetch_user
    call str_len
    add ecx, 5                      ; "@moos"
    mov al, '-'
.l: call sb_char
    loop .l
    ret

fi_os:
    mov esi, fl_os
    call fi_label
    mov esi, fs_os
    jmp sb_str

fi_fw:
    mov esi, fl_fw
    call fi_label
    cmp dword [bootinfo + BI.platform], PLATFORM_UEFI
    je .uefi
    mov esi, fs_bios
    jmp sb_str
.uefi:
    mov esi, fs_uefi
    call sb_str
    ; the UEFI version the firmware follows: the system table's header
    ; revision, major << 16 | minor (minor 70 = ".7", 31 = ".3.1")
    cmp dword [bootinfo + BI.systab + 4], 0
    jne .vendor                     ; (above 4 GB: not reachable)
    mov esi, [bootinfo + BI.systab]
    test esi, esi
    jz .vendor
    mov eax, [esi + 8]
    mov ecx, eax
    shr eax, 16
    call sb_uint
    mov al, '.'
    call sb_char
    movzx eax, cx
    xor edx, edx
    mov ecx, 10
    div ecx
    call sb_uint
    test edx, edx
    jz .sp
    mov al, '.'
    call sb_char
    mov eax, edx
    call sb_uint
.sp:
    mov al, ' '
    call sb_char
.vendor:
    mov al, '('
    call sb_char
    call efi_firmware_name
    call sb_str
    mov al, ')'
    jmp sb_char

fi_kernel:
    mov esi, fl_kernel
    call fi_label
    mov esi, fs_kernel
    call sb_str
    mov eax, kernel_image_end
    sub eax, kbase
    jmp sb_bytes

fi_uptime:
    mov esi, fl_uptime
    call fi_label
    mov eax, [ticks]
    xor edx, edx
    mov ecx, PIT_HZ
    div ecx                         ; EAX = seconds
    xor edx, edx
    mov ecx, 60
    div ecx
    mov ebp, edx                    ; EBP = seconds
    xor edx, edx
    div ecx
    mov ebx, edx                    ; EBX = minutes
    xor edx, edx
    mov ecx, 24
    div ecx                         ; EAX = days, EDX = hours
    mov ecx, edx
    ; "2 days, 3 hours, 4 mins" / "3 hours, 4 mins" / "4 mins, 5 secs" /
    ; "5 secs"
    test eax, eax
    jz .no_days
    mov esi, fs_day
    call fi_unit
    call .comma
    jmp .hours
.no_days:
    test ecx, ecx
    jz .no_hours
.hours:
    mov eax, ecx
    mov esi, fs_hour
    call fi_unit
    call .comma
    mov eax, ebx
    mov esi, fs_min
    jmp fi_unit
.no_hours:
    test ebx, ebx
    jz .secs
    mov eax, ebx
    mov esi, fs_min
    call fi_unit
    call .comma
.secs:
    mov eax, ebp
    mov esi, fs_sec
    jmp fi_unit
.comma:
    push esi
    mov esi, fs_comma
    call sb_str
    pop esi
    ret

; fi_unit: EAX = number, ESI = word -> "1 hour" / "2 hours"
fi_unit:
    call sb_uint
    push eax
    mov al, ' '
    call sb_char
    call sb_str
    pop eax
    cmp eax, 1
    je .r
    push eax
    mov al, 's'
    call sb_char
    pop eax
.r: ret

fi_pkgs:
    mov esi, fl_pkgs
    call fi_label
    xor eax, eax                    ; count the <name>.inst markers
    xor ebx, ebx
.l: push edi
    call fs_entry
    test byte [edi + DE_FLAGS], FLAG_USED
    jz .n
    mov esi, edi                    ; (the name is at the entry's start)
    call ends_with_inst
    jc .n
    inc eax
.n: pop edi
    inc ebx
    cmp ebx, FS_MAX_FILES
    jb .l
    call sb_uint
    mov esi, fs_apt
    jmp sb_str

fi_shell:
    mov esi, fl_shell
    call fi_label
    mov esi, fs_shell
    jmp sb_str

fi_res:
    mov esi, fl_res
    call fi_label
    cmp dword [bootinfo + BI.platform], PLATFORM_UEFI
    je .gfx
    mov esi, fs_text_mode
    jmp sb_str
.gfx:
    mov eax, [bootinfo + BI.fb_width]
    call sb_uint
    mov al, 'x'
    call sb_char
    mov eax, [bootinfo + BI.fb_height]
    jmp sb_uint

fi_cpu:
    mov esi, fl_cpu
    call fi_label
    call fi_brand
    mov esi, fs_open                ; " (2)" = processors
    call sb_str
    mov eax, [fetch_ncpu]
    call sb_uint
    mov esi, fs_close
    call sb_str
    mov eax, [fetch_mhz]
    test eax, eax
    jz .r
    mov esi, fs_tsc                 ; " @ 2904 MHz"
    call sb_str
    call sb_uint
    mov esi, fs_mhz
    call sb_str
.r: ret

; fi_brand: the processor's name, tidied: no (R) / (TM), no "@ 3.70GHz"
; (the measured clock follows), no " Processor" at the end, single spaces,
; at most FETCH_BRAND_MAX characters (cut at a word). The maker's name if
; the processor gives no brand string.
fi_brand:
    pushad
    mov esi, cpu_brand
    mov ebx, edi                    ; (where the name starts)
    xor ecx, ecx                    ; characters so far
    mov dl, ' '                     ; the last character (leading spaces
.l: mov al, [esi]                   ; are dropped like doubled ones)
    test al, al
    jz .end
    cmp al, '@'
    je .end
    inc esi
    cmp al, '('
    jne .not_mark
    mov ah, [esi]                   ; "(R)", "(TM)", "(tm)"
    and ah, 0xDF                    ; (upper case)
    cmp ah, 'R'
    jne .tm
    cmp byte [esi + 1], ')'
    jne .not_mark
    add esi, 2
    jmp .l
.tm:
    cmp ah, 'T'
    jne .not_mark
    mov ah, [esi + 1]
    and ah, 0xDF
    cmp ah, 'M'
    jne .not_mark
    cmp byte [esi + 2], ')'
    jne .not_mark
    add esi, 3
    jmp .l
.not_mark:
    cmp al, ' '
    jne .put
    cmp dl, ' '
    je .l
.put:
    cmp ecx, FETCH_BRAND_MAX
    jae .cut
    mov dl, al
    stosb
    inc ecx
    jmp .l
.cut:                               ; too long: end at a whole word
    cmp al, ' '
    je .end                         ; (the last word was complete)
    mov eax, edi
.back:
    cmp eax, ebx
    je .end                         ; (one long word: keep it cut)
    dec eax
    cmp byte [eax], ' '
    jne .back
    mov edi, eax
.end:
    mov eax, edi                    ; "... 8-Core Processor": the last
    sub eax, ebx                    ; word says nothing new
    cmp eax, FS_PROC_LEN
    jb .trail
    push esi
    push edi
    push ecx
    mov esi, fs_proc
    sub edi, FS_PROC_LEN
    mov ecx, FS_PROC_LEN
    repe cmpsb
    pop ecx
    pop edi
    pop esi
    jne .trail
    sub edi, FS_PROC_LEN
.trail:
    cmp edi, ebx                    ; drop a space at the end
    je .empty
    cmp byte [edi - 1], ' '
    jne .done
    dec edi
    cmp edi, ebx
    jne .done
.empty:
    mov esi, cpu_vendor
    call sb_str
.done:
    mov byte [edi], 0
    mov [esp], edi                  ; (EDI after popad)
    popad
    ret

fi_mem:
    mov esi, fl_mem
    call fi_label
    mov eax, [bootinfo + BI.ram_kb]
    mov ebx, KMEM_END / 1024        ; BIOS: MOOS keeps everything below
    xor edx, edx                    ; KMEM_END for itself
%ifdef FULL
    ; UEFI: used = everything but what the firmware's map says is free
    mov ebx, KMEM_SIZE / 1024       ; (if there is no map: MOOS's own
    push eax                        ; memory and its big blocks)
    mov eax, [big_total]
    shr eax, 10
    add ebx, eax
    pop eax
    push eax
    call efi_memmap
    test eax, eax
    jz .no_map
    add esp, 4
    mov ebx, eax
    sub ebx, edx
    jmp .show
.no_map:
    pop eax
%endif
.show:
    test eax, eax
    jz .unknown
    push eax
    mov eax, ebx                    ; "41 MB / 256 MB (16%)"
    call sb_kb
    mov esi, fs_of
    call sb_str
    pop eax
    call sb_kb
    push eax
    mov ecx, eax
    mov eax, ebx
    mov edx, 100
    mul edx
    div ecx
    mov esi, fs_open
    call sb_str
    call sb_uint
    mov al, '%'
    call sb_char
    mov esi, fs_close
    call sb_str
    pop eax
    ret
.unknown:
    mov eax, ebx
    jmp sb_kb

fi_disk:
    mov esi, fl_disk
    call fi_label
    call fs_stats                   ; EAX = files, EDX = bytes
    call sb_uint
    mov esi, fs_files
    cmp eax, 1
    jne .f
    mov esi, fs_one_file
.f: call sb_str
    mov eax, edx
    call sb_bytes
    mov esi, fs_of
    call sb_str
    mov eax, FS_MAX_FILES * FS_SLOT_SIZE
    call sb_bytes
    mov esi, fs_moosfs
    cmp byte [fs_persist], 0
    jne .s
    mov esi, fs_ramfs
.s: jmp sb_str

fi_net:
    mov esi, fl_net
    call fi_label
    cmp byte [net_up], 0
    je .down
    mov eax, [my_ip]
    call sb_ip
    jmp .card
.down:
    mov esi, fs_noconn
    call sb_str
.card:
    mov esi, fs_open
    call sb_str
    cmp byte [net_present], 0
    je .scan
    mov esi, [nic_name]
    jmp .name
.scan:                              ; not started yet: name the first card
    mov ebx, -1                     ; MOOS knows (just looking, nothing
.next:                              ; is switched on)
    call pci_next
    jc .none
    call nic_lookup
    jc .next
    mov esi, [esi + NT_NAME]
    jmp .name
.none:
    mov esi, fs_nocard
.name:
    call sb_str
    mov esi, fs_close
    jmp sb_str

fi_blank:
    ret

fi_colours:                         ; 16 blocks, one per text colour
    xor ecx, ecx
.l: mov al, FC_NUM
    call sb_char
    mov eax, ecx
    test eax, eax
    jnz .c
    mov al, 16                      ; (0 would end the text)
.c: call sb_char
    mov al, 0xDB                    ; a full block, three wide
    call sb_char
    call sb_char
    call sb_char
    inc ecx
    cmp ecx, 16
    jb .l
    ret

; ------------------------------------------------------------ the CPU
; cpu_count -> EAX = processors (at least 1): the enabled ones in the ACPI
; MADT, or what CPUID function 1 says when there is no such table
cpu_count:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    mov eax, 'APIC'
    call acpi_find_table            ; ESI = the MADT
    jc .cpuid
    mov ecx, [esi + 4]              ; its length
    cmp ecx, 44
    jb .cpuid
    cmp ecx, 0x10000                ; (a sane size)
    ja .cpuid
    lea edi, [esi + ecx]            ; EDI = its end
    add esi, 44                     ; the first entry
    xor eax, eax
.entry:
    lea edx, [esi + 2]
    cmp edx, edi
    ja .counted
    movzx ecx, byte [esi + 1]       ; entry length
    cmp ecx, 2
    jb .counted                     ; (broken table: stop)
    lea edx, [esi + ecx]
    cmp edx, edi
    ja .counted
    cmp byte [esi], 0               ; a processor's local APIC
    jne .x2
    cmp ecx, 8
    jb .next
    test byte [esi + 4], 1          ; enabled
    jz .next
    inc eax
    jmp .next
.x2:
    cmp byte [esi], 9               ; ... or its x2APIC
    jne .next
    cmp ecx, 16
    jb .next
    test byte [esi + 8], 1
    jz .next
    inc eax
.next:
    add esi, ecx
    jmp .entry
.counted:
    test eax, eax
    jnz .out
.cpuid:
    call cpu_has_cpuid
    mov eax, 1
    jc .out
    cpuid
    mov eax, 1
    test edx, 1 << 28               ; HTT: EBX[23:16] = logical processors
    jz .out
    shr ebx, 16
    movzx eax, bl
    test eax, eax
    jnz .out
    inc eax
.out:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; cpu_has_cpuid -> CF=0 if the CPUID instruction exists (EFLAGS.ID can
; be changed)
cpu_has_cpuid:
    push eax
    push ecx
    pushfd
    pop eax
    mov ecx, eax
    xor eax, 0x200000
    push eax
    popfd
    pushfd
    pop eax
    push ecx
    popfd
    xor eax, ecx
    pop ecx
    pop eax
    jz .no
    clc
    ret
.no:
    stc
    ret

; tsc_mhz_measure -> EAX = the time-stamp counter's rate in MHz (on most
; PCs the processor's base clock), 0 if the CPU has no TSC. Counts its
; cycles over 10 timer ticks (1/10 of a second).
tsc_mhz_measure:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    call cpu_has_cpuid
    jc .none
    mov eax, 1
    cpuid
    test edx, 1 << 4                ; TSC
    jz .none
    mov ecx, 1                      ; start right after a tick
    call .wait
    rdtsc
    mov esi, eax
    mov edi, edx
    mov ecx, 10
    call .wait
    rdtsc
    sub eax, esi
    sbb edx, edi
    mov ecx, 100000                 ; cycles in 1/10 s -> MHz
    cmp edx, ecx
    jae .none                       ; (absurd: would not fit)
    div ecx
    jmp .out
.none:
    xor eax, eax
.out:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret
.wait:                              ; ECX ticks from now (the CPU halts
    mov eax, [ticks]                ; until each timer interrupt)
    add eax, ecx
.w: hlt
    cmp [ticks], eax
    jb .w
    ret
