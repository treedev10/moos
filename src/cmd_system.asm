; =============================================================================
;  cmd_system.asm - time, uptime, mem, sysinfo, color, history, format,
;                   reboot, shutdown
; =============================================================================
section .bss
cpu_vendor  resb 16
cpu_brand   resb 52

section .data
build_date  db __DATE__, 0
str_yes     db "YES", 0
str_clear   db "clear", 0
str_reset   db "reset", 0
fmt_confirm db "confirm> ", 0
colour_names:
    dd cn0, cn1, cn2, cn3, cn4, cn5, cn6, cn7
    dd cn8, cn9, cn10, cn11, cn12, cn13, cn14, cn15
cn0  db "black", 0
cn1  db "blue", 0
cn2  db "green", 0
cn3  db "cyan", 0
cn4  db "red", 0
cn5  db "magenta", 0
cn6  db "brown", 0
cn7  db "gray", 0
cn8  db "darkgray", 0
cn9  db "lightblue", 0
cn10 db "lightgreen", 0
cn11 db "lightcyan", 0
cn12 db "lightred", 0
cn13 db "pink", 0
cn14 db "yellow", 0
cn15 db "white", 0
themes:                             ; name, attribute
    dd th0, 0x07, th1, 0x0A, th2, 0x1F, th3, 0xF0, th4, 0x06, th5, 0x0F
    dd 0
th0 db "default", 0
th1 db "matrix", 0
th2 db "ocean", 0
th3 db "paper", 0
th4 db "amber", 0
th5 db "bright", 0

section .text

; ----------------------------------------------------------------------- time
cmd_time:
    call rtc_read
    call rtc_weekday
    mov esi, [day_names + eax * 4]
    movzx eax, byte [rtc_month]
    dec eax
    cmp eax, 11
    jbe .m_ok
    xor eax, eax
.m_ok:
    mov edi, [month_names + eax * 4]
    movzx eax, byte [rtc_day]
    movzx ebx, word [rtc_year]
    movzx ecx, byte [rtc_hour]
    movzx edx, byte [rtc_min]
    movzx ebp, byte [rtc_sec]
    PRINTF `%s, %d %s %d   \x01w%02d:%02d:%02d\x01n\n`, esi, eax, edi, ebx, ecx, edx, ebp
    ret

; --------------------------------------------------------------------- uptime
cmd_uptime:
    mov eax, [ticks]
    xor edx, edx
    mov ecx, PIT_HZ
    div ecx                         ; EAX = seconds
    xor edx, edx
    mov ecx, 86400
    div ecx
    mov ebx, eax                    ; days
    mov eax, edx
    xor edx, edx
    mov ecx, 3600
    div ecx
    mov esi, eax                    ; hours
    mov eax, edx
    xor edx, edx
    mov ecx, 60
    div ecx                         ; EAX = minutes, EDX = seconds
    PRINTF `Up for %d day(s), %d hour(s), %d minute(s) and %d second(s).\n`, ebx, esi, eax, edx
    PRINTF `\x01d(%d timer ticks at 100 per second since start-up)\x01n\n`, dword [ticks]
    ret

; total_ram_kb: EAX = installed memory in KB (0 if the BIOS did not say)
total_ram_kb:
    mov eax, [bootinfo + BI.ram_kb]
    ret

; ------------------------------------------------------------------------ mem
cmd_mem:
    call total_ram_kb
    mov ebx, eax
    shr ebx, 10
    PRINTF `\x01wMemory\x01n\n`
    PRINTF `  Installed RAM ...... %d MB (%d KB)\n`, ebx, eax
    mov eax, kernel_image_end
    sub eax, kbase
    PRINTF `  Kernel + manuals ... 0x%08x - 0x%08x  (%d bytes)\n`, kbase, kernel_image_end, eax
    mov eax, bss_end
    sub eax, bss_start
    PRINTF `  Kernel variables ... 0x%08x - 0x%08x  (%d bytes)\n`, bss_start, bss_end, eax
    PRINTF `  Kernel stack ....... grows down from 0x%08x\n`, STACK_TOP
    cmp dword [bootinfo + BI.platform], PLATFORM_UEFI
    je .graphics
    PRINTF `  Screen memory ...... 0x000B8000 - 0x000B8FA0  (80x25 VGA text)\n`
    jmp .buffers
.graphics:
    PRINTF `  Screen ............. %dx%d graphics, frame buffer at 0x`, dword [bootinfo + BI.fb_width], dword [bootinfo + BI.fb_height]
    mov eax, [bootinfo + BI.fb_base + 4]
    test eax, eax
    jz .fb_low
    PRINTF `%x`, eax
.fb_low:
    PRINTF `%08x\n`, dword [bootinfo + BI.fb_base]
.buffers:
    mov eax, FS_DATA + FS_MAX_FILES * FS_SLOT_SIZE
    PRINTF `  File cache ......... 0x%08x - 0x%08x  (132 KB)\n`, FS_DIR, eax
    mov eax, OUTBUF + OUTBUF_SIZE
    PRINTF `  Work buffers ....... 0x%08x - 0x%08x  (124 KB)\n`, SCRATCH, eax
    PRINTF `  Used by MOOS ....... about %d KB in total - the rest is free\n`, KMEM_SIZE / 1024
.storage:
    call fs_stats
    mov ebx, FS_MAX_FILES
    sub ebx, eax
    shl ebx, 12
    PRINTF `\n\x01wStorage\x01n\n`
    cmp byte [fs_persist], 0
    je .ram
    call fs_method
    PRINTF `  Mode ............... saved on the boot disk (survives restarts)\n`
    PRINTF `  Saved through ...... %s\n`, esi
    jmp .files
.ram:
    PRINTF `  Mode ............... \x01yRAM only\x01n (lost when powered off)\n`
.files:
    PRINTF `  Files .............. %d of 32\n`, eax
    PRINTF `  Used ............... %d bytes\n`, edx
    mov ecx, ebx
    shr ecx, 12
    PRINTF `  Free ............... %d bytes (%d empty slots of 4096 bytes)\n`, ebx, ecx
    ret

; -------------------------------------------------------------------- sysinfo
cpu_detect:
    pushad
    pushfd                          ; CPUID available? (EFLAGS.ID toggles)
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
    jz .none
    xor eax, eax
    cpuid
    mov [cpu_vendor], ebx
    mov [cpu_vendor + 4], edx
    mov [cpu_vendor + 8], ecx
    mov byte [cpu_vendor + 12], 0
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000004
    jb .done
    mov edi, cpu_brand
    mov esi, 0x80000002
.brand:
    mov eax, esi
    cpuid
    stosd
    mov eax, ebx
    stosd
    mov eax, ecx
    stosd
    mov eax, edx
    stosd
    inc esi
    cmp esi, 0x80000004
    jbe .brand
    mov byte [edi], 0
    jmp .done
.none:
    mov dword [cpu_vendor], "unkn"
    mov dword [cpu_vendor + 4], "own"
.done:
    popad
    ret

cmd_sysinfo:
    call cpu_detect
    PRINTF `\x01c%s %s\x01n - a tiny operating system written from scratch in assembly\n\n`, os_name_str, os_version_str
    PRINTF `  Built .......... %s\n`, build_date
    cmp dword [bootinfo + BI.platform], PLATFORM_UEFI
    je .uefi_fw
    PRINTF `  Started by ..... PC BIOS (legacy boot)\n`
    PRINTF `  Architecture ... x86, 32-bit protected mode, flat memory\n`
    jmp .cpu
.uefi_fw:
    call efi_firmware_name
    mov eax, [bootinfo + BI.fw_rev]
    movzx edx, ax
    shr eax, 16
    PRINTF `  Started by ..... UEFI firmware: %s (revision %d.%d)\n`, esi, eax, edx
    PRINTF `  Architecture ... x86-64 PC; MOOS runs in 32-bit compatibility mode\n`
.cpu:
    PRINTF `  CPU vendor ..... %s\n`, cpu_vendor
    cmp byte [cpu_brand], 0
    je .no_brand
    mov esi, cpu_brand
    call skip_spaces
    PRINTF `  CPU model ...... %s\n`, esi
.no_brand:
    call total_ram_kb
    shr eax, 10
    PRINTF `  Memory ......... %d MB\n`, eax
    cmp dword [bootinfo + BI.platform], PLATFORM_UEFI
    je .uefi_hw
    PRINTF `  Display ........ VGA text mode, 80x25, 16 colours\n`
    PRINTF `  Timer .......... PIT, 100 interrupts per second\n`
    PRINTF `  Keyboard ....... PS/2, US layout\n`
    jmp .size
.uefi_hw:
    PRINTF `  Display ........ %dx%d graphics (UEFI GOP), 80x25 characters x%d\n`, dword [bootinfo + BI.fb_width], dword [bootinfo + BI.fb_height], dword [fb_scale]
    PRINTF `  Timer .......... firmware timer event, 100 per second\n`
    PRINTF `  Keyboard ....... any keyboard the firmware supports (USB, PS/2)\n`
.size:
    mov eax, kernel_image_end
    sub eax, kbase
    add eax, 512
    PRINTF `  System size .... %d bytes (boot sector + kernel + all manuals)\n`, eax
    cmp byte [fs_persist], 0
    je .ram
    call fs_method
    PRINTF `  Storage ........ MOOSFS on the boot disk, saved through %s\n`, esi
    jmp .up
.ram:
    PRINTF `  Storage ........ RAM only (the boot disk could not be written)\n`
.up:
    mov eax, [ticks]
    xor edx, edx
    mov ecx, PIT_HZ
    div ecx
    PRINTF `  Uptime ......... %d seconds\n`, eax
    ret

section .data
os_name_str     db OS_NAME, 0
os_version_str  db OS_VERSION, 0
section .text

; ---------------------------------------------------------------------- color
; parse_colour: ESI = name or number -> AL = 0..15, CF=1 if unknown
parse_colour:
    push ebx
    push edi
    call parse_uint
    jc .name
    cmp eax, 15
    ja .bad
    jmp .ok
.name:
    xor ebx, ebx
.l: mov edi, [colour_names + ebx * 4]
    call str_icmp
    je .found
    inc ebx
    cmp ebx, 16
    jb .l
.bad:
    pop edi
    pop ebx
    stc
    ret
.found:
    mov eax, ebx
.ok:
    pop edi
    pop ebx
    clc
    ret

cmd_color:
    cmp dword [argc], 2
    jb .table
    mov esi, [argv + 4]
    mov ebx, themes                 ; theme name?
.th:
    mov edi, [ebx]
    test edi, edi
    jz .colours
    call str_icmp
    je .theme
    add ebx, 8
    jmp .th
.theme:
    mov al, [ebx + 4]
    jmp .apply
.colours:
    mov edi, str_reset
    call str_icmp
    jne .fg
    mov al, C_DEFAULT
    jmp .apply
.fg:
    call parse_colour
    jc .bad_name
    mov dl, al                      ; foreground
    mov dh, [text_attr]             ; keep the current background ...
    shr dh, 4
    cmp dword [argc], 3
    jb .combine
    mov esi, [argv + 8]
    call parse_colour
    jc .bad_name
    mov dh, al
.combine:
    cmp dl, dh
    je .same
    mov al, dh
    shl al, 4
    or al, dl
.apply:
    mov [text_attr], al
    call vga_recolor
    PRINTF `Colours changed. \x01d(type \x01wcolor default\x01d to go back)\x01n\n`
    ret
.same:
    PRINTF `\x01rerror:\x01n text and background would be the same colour - you could not read anything!\n`
    ret
.bad_name:
    PRINTF `\x01rerror:\x01n unknown colour '\x01w%s\x01n'. Type \x01wcolor\x01n to see the list.\n`, esi
    ret
.table:
    PRINTF `\x01wColours\x01n (use the name or the number)\n`
    xor ebx, ebx
.row:
    call .swatch
    PRINTF ` %2d %12s`, ebx, dword [colour_names + ebx * 4]
    add ebx, 8
    call .swatch
    PRINTF ` %2d %s\n`, ebx, dword [colour_names + ebx * 4]
    sub ebx, 7
    cmp ebx, 8
    jb .row
    PRINTF `\n\x01wThemes:\x01n default, matrix, ocean, paper, amber, bright\n`
    PRINTF `\x01wUsage:\x01n  color <theme>     color <text> [background]     color reset\n`
    PRINTF `\x01wExample:\x01n color yellow blue\n`
    ret
.swatch:                            ; two solid blocks in colour EBX
    mov al, [text_attr]
    push eax
    and al, 0xF0
    or al, bl
    mov [text_attr], al
    PRINTF `  \xDB\xDB`
    pop eax
    mov [text_attr], al
    ret

; -------------------------------------------------------------------- history
cmd_history:
    cmp dword [argc], 2
    jb .list
    mov esi, [argv + 4]
    mov edi, str_clear
    call str_icmp
    jne .list
    mov dword [hist_count], 0
    mov dword [hist_head], 0
    PRINTF `History cleared.\n`
    ret
.list:
    mov ecx, [hist_count]
    mov edx, 1
.l: test ecx, ecx
    jz .done
    mov ebx, [hist_head]
    sub ebx, ecx
    and ebx, HIST_N - 1
    imul esi, ebx, HIST_LEN
    add esi, hist_buf
    PRINTF `\x01d%3d\x01n  %s\n`, edx, esi
    inc edx
    dec ecx
    jmp .l
.done:
    PRINTF `\x01d(press Up/Down at the prompt to reuse these)\x01n\n`
    ret

; --------------------------------------------------------------------- format
cmd_format:
    call fs_stats
    PRINTF `\x01rWARNING:\x01n this permanently erases ALL %d file(s). It cannot be undone.\n`, eax
    PRINTF `Type \x01wYES\x01n (in capitals) and press Enter to continue, anything else cancels.\n`
    mov esi, fmt_confirm
    mov bl, 0x0C
    xor bh, bh
    call readline
    test eax, eax
    jnz .cancel
    mov esi, line_buf
    call skip_spaces
    mov edi, str_yes
.cmp:                               ; exact, case-sensitive compare
    mov al, [esi]
    cmp al, [edi]
    jne .cancel
    inc esi
    inc edi
    test al, al
    jnz .cmp
    call fs_format
    PRINTF `\x01gDone.\x01n All files were erased.\n`
    ret
.cancel:
    PRINTF `Cancelled - your files are untouched.\n`
    ret

; ------------------------------------------------------------ reboot/shutdown
cmd_reboot:
    PRINTF `Restarting... (your files are already saved)\n`
    mov ecx, 50
    call sleep_ticks

system_reboot:
    cmp dword [bootinfo + BI.platform], PLATFORM_UEFI
    jne .bios
    xor ebx, ebx                    ; EfiResetCold
    mov eax, efi_reset64
    call efi64
.bios:
    cli
    mov ecx, 0x100000
.wait:                              ; wait for the keyboard controller
    in al, 0x64
    test al, 2
    jz .pulse
    loop .wait
.pulse:
    mov al, 0xFE                    ; pulse the CPU reset line
    out 0x64, al
    lidt [null_idt]                 ; fallback: force a triple fault
    int3
.hang:
    hlt
    jmp .hang

section .data
null_idt    dw 0
            dd 0
section .text

cmd_shutdown:
    PRINTF `Shutting down... (your files are already saved)\n`
    mov ecx, 50
    call sleep_ticks
    call acpi_shutdown              ; the standard way (see acpi.asm)
    cmp dword [bootinfo + BI.platform], PLATFORM_UEFI
    jne .bios
    mov ebx, 2                      ; still on: ask the UEFI firmware
    mov eax, efi_reset64
    call efi64
.bios:
    cli
    mov dx, 0x604                   ; QEMU
    mov ax, 0x2000
    out dx, ax
    mov dx, 0xB004                  ; Bochs and older QEMU
    out dx, ax
    mov dx, 0x4004                  ; VirtualBox
    mov ax, 0x3400
    out dx, ax
    mov byte [text_attr], 0x0E      ; still here: real hardware
    PRINTF `\nIt is now safe to turn off your computer.\n`
.hang:
    hlt
    jmp .hang
