section .bss
rtc_sec     resb 1
rtc_min     resb 1
rtc_hour    resb 1
rtc_day     resb 1
rtc_month   resb 1
rtc_raw_b   resb 1
rtc_year    resw 1

section .data
day_names   dd d_sun, d_mon, d_tue, d_wed, d_thu, d_fri, d_sat
d_sun db "Sunday", 0
d_mon db "Monday", 0
d_tue db "Tuesday", 0
d_wed db "Wednesday", 0
d_thu db "Thursday", 0
d_fri db "Friday", 0
d_sat db "Saturday", 0
month_names dd m_jan, m_feb, m_mar, m_apr, m_may, m_jun
            dd m_jul, m_aug, m_sep, m_oct, m_nov, m_dec
m_jan db "January", 0
m_feb db "February", 0
m_mar db "March", 0
m_apr db "April", 0
m_may db "May", 0
m_jun db "June", 0
m_jul db "July", 0
m_aug db "August", 0
m_sep db "September", 0
m_oct db "October", 0
m_nov db "November", 0
m_dec db "December", 0
dow_offsets db 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4

section .text

rtc_reg:
    out 0x70, al
    in al, 0x71
    ret

rtc_bcd:
    test byte [rtc_raw_b], 4
    jnz .r
    push ecx
    mov cl, al
    shr al, 4
    mov ch, 10
    mul ch
    and cl, 0x0F
    add al, cl
    pop ecx
.r: ret

rtc_read:
    cmp byte [clk_source], 1
    jne .hardware
    push eax
    call clk_now_epoch
    call epoch_to_datetime
    pop eax
    ret
.hardware:
    cmp dword [bootinfo + BI.platform], PLATFORM_UEFI
    je rtc_read_uefi
    pushad
.uip:
    mov al, 0x0A
    call rtc_reg
    test al, 0x80
    jnz .uip
    mov al, 0x0B
    call rtc_reg
    mov [rtc_raw_b], al
    mov al, 0x00
    call rtc_reg
    call rtc_bcd
    mov [rtc_sec], al
    mov al, 0x02
    call rtc_reg
    call rtc_bcd
    mov [rtc_min], al
    mov al, 0x07
    call rtc_reg
    call rtc_bcd
    mov [rtc_day], al
    mov al, 0x08
    call rtc_reg
    call rtc_bcd
    mov [rtc_month], al
    mov al, 0x09
    call rtc_reg
    call rtc_bcd
    movzx eax, al
    add eax, 2000
    mov [rtc_year], ax
    mov al, 0x04
    call rtc_reg
    mov bl, al
    and al, 0x7F
    call rtc_bcd
    test byte [rtc_raw_b], 2
    jnz .h24
    cmp al, 12
    jne .not12
    xor al, al
.not12:
    test bl, 0x80
    jz .h24
    add al, 12
.h24:
    mov [rtc_hour], al
    popad
    ret

rtc_read_uefi:
    pushad
    mov eax, efi_gettime64
    call efi64
    test eax, eax
    jnz .keep
    mov ax, [efi_time]
    mov [rtc_year], ax
    mov al, [efi_time + 2]
    mov [rtc_month], al
    mov al, [efi_time + 3]
    mov [rtc_day], al
    mov al, [efi_time + 4]
    mov [rtc_hour], al
    mov al, [efi_time + 5]
    mov [rtc_min], al
    mov al, [efi_time + 6]
    mov [rtc_sec], al
.keep:
    popad
    ret

rtc_weekday:
    push ebx
    push ecx
    push edx
    movzx eax, word [rtc_year]
    movzx ebx, byte [rtc_month]
    cmp ebx, 3
    jae .no_adj
    dec eax
.no_adj:
    mov ecx, eax
    shr eax, 2
    add ecx, eax
    movzx eax, word [rtc_year]
    cmp ebx, 3
    jae .y2
    dec eax
.y2:
    push eax
    xor edx, edx
    mov ebx, 100
    div ebx
    sub ecx, eax
    pop eax
    xor edx, edx
    mov ebx, 400
    div ebx
    add ecx, eax
    movzx ebx, byte [rtc_month]
    dec ebx
    and ebx, 15
    cmp ebx, 11
    jbe .m_ok
    xor ebx, ebx
.m_ok:
    movzx eax, byte [dow_offsets + ebx]
    add ecx, eax
    movzx eax, byte [rtc_day]
    add eax, ecx
    xor edx, edx
    mov ebx, 7
    div ebx
    mov eax, edx
    pop edx
    pop ecx
    pop ebx
    ret
