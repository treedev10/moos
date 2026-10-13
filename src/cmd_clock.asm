; =============================================================================
;  cmd_clock.asm - clock settings and getting the time from the internet
;
;  Customisation (saved in the file clock.cfg so it survives a restart):
;    - 24-hour ("military") or 12-hour display
;    - the colour of the status bar
;    - a timezone offset, used with internet time (which is UTC)
;
;  "clock sync" asks an internet time server (NTP) for the time and switches
;  the clock to it. The hardware clock is still there as a fallback.
;
;  Time is handled as a Unix timestamp (seconds since 1 Jan 1970 UTC) and
;  converted to a date with the standard civil-calendar formulas.
; =============================================================================
section .bss
alignb 4
clk_24h         resb 1          ; 1 = 24-hour, 0 = 12-hour
clk_color       resb 1          ; status bar attribute
clk_source      resb 1          ; 0 = hardware clock, 1 = internet
alignb 4
clk_tz_min      resd 1          ; timezone offset from UTC, in minutes
net_epoch_base  resd 1          ; synced Unix time ...
net_tick_base   resd 1          ; ... captured at this tick count

section .data
clk_cfg_name    db "clock.cfg", 0
str_sync        db "sync", 0
sync_http_host  db "example.com", 0
str_local       db "local", 0
str_12          db "12", 0
str_24          db "24", 0
str_color_w     db "color", 0
str_tz          db "tz", 0
ampm_am         db "AM", 0
ampm_pm         db "PM", 0
; days in each month (non-leap); February handled specially
month_days      db 31,28,31,30,31,30,31,31,30,31,30,31

section .text

; clk_defaults: the built-in settings
clk_defaults:
    mov byte [clk_24h], 1
    mov byte [clk_color], C_STATUS
    mov byte [clk_source], 0
    mov dword [clk_tz_min], 0
    ret

; clk_init: set defaults, then load clock.cfg if it exists
clk_init:
    pushad
    call clk_defaults
    mov esi, clk_cfg_name
    call fs_find
    jc .done
    cmp dword [edi + DE_SIZE], 7
    jb .done
    call fs_slot                    ; ESI = file data
    mov al, [esi]
    mov [clk_24h], al
    mov al, [esi + 1]
    mov [clk_color], al
    mov eax, [esi + 3]
    mov [clk_tz_min], eax
.done:
    popad
    ret

; clk_save: write the current settings to clock.cfg
clk_save:
    pushad
    mov edi, SCRATCH
    mov al, [clk_24h]
    mov [edi], al
    mov al, [clk_color]
    mov [edi + 1], al
    mov byte [edi + 2], 0
    mov eax, [clk_tz_min]
    mov [edi + 3], eax
    mov esi, clk_cfg_name
    mov edx, SCRATCH
    mov ecx, 7
    call fs_save
    popad
    ret

; -------------------------------------------------------- date <-> epoch
; epoch_to_datetime: EAX = Unix seconds (already timezone-adjusted) ->
; epoch_to_datetime: EAX = Unix seconds (already timezone-adjusted) ->
; rtc_year / rtc_month / rtc_day / rtc_hour / rtc_min / rtc_sec (UTC calendar)
epoch_to_datetime:
    pushad
    xor edx, edx
    mov ebx, 86400
    div ebx                         ; EAX = days, EDX = second of the day
    mov [et_days], eax
    mov eax, edx
    xor edx, edx
    mov ebx, 60
    div ebx
    mov [rtc_sec], dl
    xor edx, edx
    div ebx
    mov [rtc_min], dl
    mov [rtc_hour], al              ; EAX < 24
    mov eax, [et_days]              ; civil date (Howard Hinnant)
    add eax, 719468
    xor edx, edx
    mov ebx, 146097
    div ebx
    mov [et_era], eax
    mov [et_doe], edx
    mov eax, edx                    ; yoe = (doe - doe/1460 + doe/36524
    xor edx, edx                    ;        - doe/146096) / 365
    mov ebx, 1460
    div ebx
    mov ecx, [et_doe]
    sub ecx, eax
    mov eax, [et_doe]
    xor edx, edx
    mov ebx, 36524
    div ebx
    add ecx, eax
    mov eax, [et_doe]
    xor edx, edx
    mov ebx, 146096
    div ebx
    sub ecx, eax
    mov eax, ecx
    xor edx, edx
    mov ebx, 365
    div ebx
    mov [et_yoe], eax
    imul eax, 400                   ; (reuse) y = yoe + era*400
    mov eax, [et_era]
    imul eax, 400
    add eax, [et_yoe]
    mov [et_year], eax
    mov eax, [et_yoe]               ; doy = doe - (365*yoe + yoe/4 - yoe/100)
    imul eax, 365
    mov ecx, eax
    mov eax, [et_yoe]
    shr eax, 2
    add ecx, eax
    mov eax, [et_yoe]
    xor edx, edx
    mov ebx, 100
    div ebx
    sub ecx, eax
    mov eax, [et_doe]
    sub eax, ecx
    mov [et_doy], eax
    imul eax, 5                     ; mp = (5*doy + 2)/153
    add eax, 2
    xor edx, edx
    mov ebx, 153
    div ebx
    mov [et_mp], eax
    imul eax, 153                   ; d = doy - (153*mp + 2)/5 + 1
    add eax, 2
    xor edx, edx
    mov ebx, 5
    div ebx
    mov ecx, [et_doy]
    sub ecx, eax
    inc ecx
    mov [rtc_day], cl
    mov eax, [et_mp]                ; m = mp<10 ? mp+3 : mp-9
    cmp eax, 10
    jb .m_small
    sub eax, 9
    jmp .m_done
.m_small:
    add eax, 3
.m_done:
    mov [rtc_month], al
    mov ecx, [et_year]              ; y += (m <= 2)
    cmp al, 2
    ja .y_ok
    inc ecx
.y_ok:
    mov [rtc_year], cx
    popad
    ret

section .bss
alignb 4
et_days resd 1
et_era  resd 1
et_doe  resd 1
et_yoe  resd 1
et_year resd 1
et_doy  resd 1
et_mp   resd 1
section .text


; datetime_to_epoch: rtc_* (treated as UTC) -> EAX = Unix seconds
datetime_to_epoch:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    movzx esi, word [rtc_year]
    movzx eax, byte [rtc_month]
    mov edi, eax                    ; EDI = month
    cmp eax, 2                      ; y -= (m <= 2)
    ja .no_dec
    dec esi
.no_dec:
    ; era = y / 400 ; yoe = y - era*400
    mov eax, esi
    xor edx, edx
    mov ebx, 400
    div ebx
    mov ecx, eax                    ; ECX = era
    mov ebp, edx                    ; EBP = yoe
    ; doy = (153*(m>2 ? m-3 : m+9) + 2)/5 + d - 1
    mov eax, edi
    cmp eax, 2
    jbe .mp_add
    sub eax, 3
    jmp .mp_done
.mp_add:
    add eax, 9
.mp_done:
    imul eax, 153
    add eax, 2
    xor edx, edx
    mov ebx, 5
    div ebx
    movzx ebx, byte [rtc_day]
    add eax, ebx
    dec eax                         ; EAX = doy
    mov edi, eax                    ; EDI = doy
    ; doe = yoe*365 + yoe/4 - yoe/100 + doy
    mov eax, ebp
    imul eax, 365
    mov ebx, eax
    mov eax, ebp
    shr eax, 2
    add ebx, eax
    mov eax, ebp
    xor edx, edx
    mov esi, 100
    div esi
    sub ebx, eax
    add ebx, edi                    ; EBX = doe
    ; days = era*146097 + doe - 719468
    mov eax, ecx
    imul eax, 146097
    add eax, ebx
    sub eax, 719468                 ; EAX = days since 1970
    ; seconds = ((days*24 + hour)*60 + min)*60 + sec
    mov ebx, 86400
    imul eax, ebx
    movzx ebx, byte [rtc_hour]
    imul ebx, 3600
    add eax, ebx
    movzx ebx, byte [rtc_min]
    imul ebx, 60
    add eax, ebx
    movzx ebx, byte [rtc_sec]
    add eax, ebx
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; clk_now_epoch: EAX = the current time as Unix seconds (internet source)
clk_now_epoch:
    mov eax, [ticks]
    sub eax, [net_tick_base]
    xor edx, edx
    mov ebx, PIT_HZ
    div ebx                         ; elapsed seconds
    add eax, [net_epoch_base]
    add eax, [clk_tz_min_sec]       ; (computed below)
    ret

section .bss
clk_tz_min_sec  resd 1
section .text

; clk_apply_tz: refresh clk_tz_min_sec from clk_tz_min
clk_apply_tz:
    push eax
    push edx
    mov eax, [clk_tz_min]
    imul eax, 60
    mov [clk_tz_min_sec], eax
    pop edx
    pop eax
    ret

; ----------------------------------------------------------- the command
cmd_clock:
    cmp dword [argc], 2
    jb .show
    mov esi, [argv + 4]
    mov edi, str_24
    call str_icmp
    je .set24
    mov edi, str_12
    call str_icmp
    je .set12
    mov edi, str_sync
    call str_icmp
    je .sync
    mov edi, str_local
    call str_icmp
    je .local
    mov edi, str_color_w
    call str_icmp
    je .color
    mov edi, str_tz
    call str_icmp
    je .tz
    PRINTF `Unknown clock option. Type \x01wclock\x01n to see the choices.\n`
    ret
.set24:
    mov byte [clk_24h], 1
    call clk_save
    PRINTF `Clock set to 24-hour (military) time.\n`
    ret
.set12:
    mov byte [clk_24h], 0
    call clk_save
    PRINTF `Clock set to 12-hour time.\n`
    ret
.color:
    cmp dword [argc], 3
    jb .color_usage
    mov esi, [argv + 8]
    call parse_colour
    jc .color_bad
    shl al, 4                       ; use it as the background
    or al, 0x0F                     ; white text
    mov [clk_color], al
    call clk_save
    call status_draw
    PRINTF `Status bar colour changed.\n`
    ret
.color_usage:
    PRINTF `Usage: \x01wclock color <name>\x01n  (try: blue, green, red, black)\n`
    ret
.color_bad:
    PRINTF `Unknown colour. Type \x01wcolor\x01n to see the list.\n`
    ret
.tz:
    cmp dword [argc], 3
    jb .tz_usage
    mov esi, [argv + 8]
    call parse_tz
    jc .tz_bad
    mov [clk_tz_min], eax
    call clk_apply_tz
    call clk_save
    PRINTF `Timezone set. It applies to internet time (UTC).\n`
    ret
.tz_usage:
    PRINTF `Usage: \x01wclock tz +H\x01n or \x01wclock tz -H:MM\x01n  (example: clock tz -5)\n`
    ret
.tz_bad:
    PRINTF `Could not read that offset. Example: \x01wclock tz +5:30\x01n\n`
    ret
.sync:
    PRINTF `Getting the time from the internet...\n`
    cmp byte [net_up], 0
    jne .do_sync
    call net_up_bring
    jc .sync_neterr
.do_sync:
    call ntp_query                  ; first choice: NTP (UDP 123)
    jnc .got_time
    PRINTF `(NTP did not answer - trying the web instead)\n`
    mov esi, sync_http_host         ; fallback: a web server's Date header
    call http_time
    jnc .got_time
    jmp .sync_fail
.got_time:
    mov [net_epoch_base], eax
    mov ebx, [ticks]
    mov [net_tick_base], ebx
    mov byte [clk_source], 1
    call clk_apply_tz
    call rtc_read
    PRINTF `\x01gClock synced.\x01n Now: `
    call clk_print_now
    PRINTF `\n`
    ret
.sync_neterr:
    PRINTF `\x01rCould not connect:\x01n %s\n`, esi
    ret
.sync_fail:
    PRINTF `\x01rThe time request failed.\x01n The clock is unchanged.\n`
    ret
.local:
    mov byte [clk_source], 0
    PRINTF `Clock switched back to the computer's hardware clock.\n`
    ret
.show:
    call rtc_read
    PRINTF `\x01wClock\x01n\n  Time now ....... `
    call clk_print_now
    cmp byte [clk_source], 0
    je .src_hw
    PRINTF `  (from the internet)\n`
    jmp .fmt
.src_hw:
    PRINTF `  (hardware clock)\n`
.fmt:
    mov esi, str_24h_word
    cmp byte [clk_24h], 0
    jne .is24
    mov esi, str_12h_word
.is24:
    PRINTF `  Format ......... %s\n`, esi
    mov eax, [clk_tz_min]
    call print_tz
    PRINTF `\nOptions: \x01wclock 24\x01n | \x01wclock 12\x01n | \x01wclock color <name>\x01n | \x01wclock tz <offset>\x01n\n`
    PRINTF `         \x01wclock sync\x01n (get the time from the internet) | \x01wclock local\x01n\n`
    ret

section .data
str_24h_word    db "24-hour (military)", 0
str_12h_word    db "12-hour", 0
str_utc         db "UTC", 0
section .text

; clk_print_now: print rtc_* as a time, respecting the 12/24 setting
clk_print_now:
    movzx eax, word [rtc_year]
    movzx ebx, byte [rtc_month]
    movzx ecx, byte [rtc_day]
    PRINTF `%d-%02d-%02d  `, eax, ebx, ecx
    cmp byte [clk_24h], 0
    je .twelve
    movzx eax, byte [rtc_hour]
    movzx ebx, byte [rtc_min]
    movzx ecx, byte [rtc_sec]
    PRINTF `%02d:%02d:%02d`, eax, ebx, ecx
    ret
.twelve:
    movzx eax, byte [rtc_hour]
    mov esi, ampm_am
    cmp eax, 12
    jb .am
    mov esi, ampm_pm
.am:
    test eax, eax                   ; 0 -> 12 AM
    jnz .not_mid
    mov eax, 12
    jmp .have_hour
.not_mid:
    cmp eax, 12
    jbe .have_hour
    sub eax, 12
.have_hour:
    movzx ebx, byte [rtc_min]
    movzx ecx, byte [rtc_sec]
    PRINTF `%d:%02d:%02d %s`, eax, ebx, ecx, esi
    ret

; parse_tz: ESI = "+H", "-H", "+H:MM" -> EAX = signed minutes, CF=1 if bad
parse_tz:
    push ebx
    push ecx
    push esi
    xor ecx, ecx                    ; sign flag
    mov al, [esi]
    cmp al, '-'
    jne .plus
    mov ecx, 1
    inc esi
    jmp .hours
.plus:
    cmp al, '+'
    jne .hours
    inc esi
.hours:
    call parse_uint_partial         ; EAX = hours, ESI advanced
    jc .bad
    cmp eax, 14
    ja .bad
    imul eax, 60
    mov ebx, eax
    cmp byte [esi], ':'
    jne .done
    inc esi
    call parse_uint_partial
    jc .bad
    cmp eax, 59
    ja .bad
    add ebx, eax
.done:
    mov eax, ebx
    test ecx, ecx
    jz .pos
    neg eax
.pos:
    pop esi
    pop ecx
    pop ebx
    clc
    ret
.bad:
    pop esi
    pop ecx
    pop ebx
    stc
    ret

; parse_uint_partial: read decimal digits at ESI -> EAX, ESI advanced,
; CF=1 if there was not even one digit
parse_uint_partial:
    push ebx
    xor eax, eax
    xor ebx, ebx                    ; digit count
.l: movzx ecx, byte [esi]
    sub cl, '0'
    cmp cl, 9
    ja .end
    imul eax, 10
    add eax, ecx
    inc esi
    inc ebx
    jmp .l
.end:
    test ebx, ebx
    jz .bad
    pop ebx
    clc
    ret
.bad:
    pop ebx
    stc
    ret

; print_tz: EAX = signed minutes -> "Timezone ....... UTC+5:30"
print_tz:
    push eax
    push ebx
    push ecx
    PRINTF `  Timezone ....... UTC`
    test eax, eax
    jns .pos
    PRINTF `-`
    neg eax
    jmp .mag
.pos:
    PRINTF `+`
.mag:
    xor edx, edx
    mov ebx, 60
    push edx
    mov ecx, eax
    xor edx, edx
    mov eax, ecx
    div ebx                         ; EAX = hours, EDX = minutes
    pop ecx
    PRINTF `%d`, eax
    test edx, edx
    jz .no_min
    PRINTF `:%02d`, edx
.no_min:
    pop ecx
    pop ebx
    pop eax
    ret
