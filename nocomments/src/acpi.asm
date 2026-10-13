section .bss
alignb 4
acpi_pm1a       resd 1
acpi_pm1b       resd 1
acpi_slp_a      resd 1
acpi_slp_b      resd 1

section .text

acpi_find_rsdp:
    cmp dword [bootinfo + BI.platform], PLATFORM_UEFI
    jne .bios
    push eax
    mov eax, efi_find_acpi64
    call efi64
    mov esi, eax
    pop eax
    test esi, esi
    jz .none
    cmp dword [esi], 'RSD '
    jne .none
    clc
    ret
.bios:
    push eax
    movzx esi, word [0x40E]
    shl esi, 4
    lea eax, [esi + 1024]
    test esi, esi
    jz .rom
    call .scan
    jnc .found
.rom:
    mov esi, 0xE0000
    mov eax, 0x100000
    call .scan
    jnc .found
    pop eax
.none:
    stc
    ret
.found:
    pop eax
    clc
    ret
.scan:
    cmp dword [esi], 'RSD '
    jne .next
    cmp dword [esi + 4], 'PTR '
    je .hit
.next:
    add esi, 16
    cmp esi, eax
    jb .scan
    stc
    ret
.hit:
    clc
    ret

acpi_find_table:
    push ebx
    push ecx
    push edx
    push edi
    mov ebx, eax
    call acpi_find_rsdp
    jc .fail
    mov edx, 4
    mov edi, [esi + 16]
    cmp byte [esi + 15], 2
    jb .have_table
    cmp dword [esi + 28], 0
    jne .have_table
    mov eax, [esi + 24]
    test eax, eax
    jz .have_table
    mov edi, eax
    mov edx, 8
.have_table:
    test edi, edi
    jz .fail
    mov ecx, [edi + 4]
    sub ecx, 36
    jbe .fail
    add edi, 36
.entry:
    cmp ecx, edx
    jb .fail
    mov esi, [edi]
    cmp edx, 8
    jne .low
    cmp dword [edi + 4], 0
    jne .skip
.low:
    test esi, esi
    jz .skip
    cmp [esi], ebx
    je .found
.skip:
    add edi, edx
    sub ecx, edx
    jmp .entry
.found:
    pop edi
    pop edx
    pop ecx
    pop ebx
    clc
    ret
.fail:
    pop edi
    pop edx
    pop ecx
    pop ebx
    stc
    ret

acpi_aml_byte:
    movzx eax, byte [esi]
    cmp al, 0x0A
    jne .not_byte
    movzx eax, byte [esi + 1]
    add esi, 2
    ret
.not_byte:
    cmp al, 0x0B
    jne .simple
    movzx eax, word [esi + 1]
    add esi, 3
    ret
.simple:
    cmp al, 0xFF
    jne .ok
    xor eax, eax
.ok:
    inc esi
    ret

acpi_prepare:
    pushad
    mov eax, 'FACP'
    call acpi_find_table
    jc .fail
    mov ebx, esi
    mov eax, [ebx + 64]
    mov [acpi_pm1a], eax
    mov eax, [ebx + 68]
    mov [acpi_pm1b], eax
    cmp dword [acpi_pm1a], 0
    jne .have_port
    cmp dword [ebx + 4], 184
    jb .fail
    cmp byte [ebx + 172], 1
    jne .fail
    movzx eax, word [ebx + 176]
    mov [acpi_pm1a], eax
    test eax, eax
    jz .fail
.have_port:
    mov edi, [ebx + 40]
    test edi, edi
    jnz .dsdt
    cmp dword [ebx + 4], 148
    jb .fail
    cmp dword [ebx + 144], 0
    jne .fail
    mov edi, [ebx + 140]
    test edi, edi
    jz .fail
.dsdt:
    cmp dword [edi], 'DSDT'
    jne .fail
    mov ecx, [edi + 4]
    lea edx, [edi + ecx - 8]
    lea esi, [edi + 36]
.search:
    cmp esi, edx
    jae .fail
    cmp dword [esi], '_S5_'
    jne .next
    cmp byte [esi - 1], 0x08
    je .name
    cmp byte [esi - 1], '\'
    jne .next
    cmp byte [esi - 2], 0x08
    jne .next
.name:
    cmp byte [esi + 4], 0x12
    je .package
.next:
    inc esi
    jmp .search
.package:
    add esi, 5
    movzx eax, byte [esi]
    shr eax, 6
    lea esi, [esi + eax + 1]
    inc esi
    call acpi_aml_byte
    mov [acpi_slp_a], eax
    call acpi_aml_byte
    mov [acpi_slp_b], eax
    popad
    clc
    ret
.fail:
    popad
    stc
    ret

acpi_shutdown:
    pushad
    call acpi_prepare
    jc .done
    mov edx, [acpi_pm1a]
    mov eax, [acpi_slp_a]
    and eax, 7
    shl eax, 10
    or eax, 1 << 13
    mov ebx, eax
    in ax, dx
    and ax, 0x0203
    or ax, bx
    out dx, ax
    mov edx, [acpi_pm1b]
    test edx, edx
    jz .wait
    mov eax, [acpi_slp_b]
    and eax, 7
    shl eax, 10
    or eax, 1 << 13
    out dx, ax
.wait:
    mov ecx, 50
    call sleep_ticks
.done:
    popad
    ret

bits 64

efi_find_acpi64:
    ENTER64
    mov rsi, [rel bootinfo + BI.systab]
    mov rcx, [rsi + 104]
    mov rsi, [rsi + 112]
    xor r8d, r8d
    xor r10d, r10d
.entry:
    test rcx, rcx
    jz .end
    mov rax, [rsi]
    mov rdx, [rsi + 8]
    mov r9, 0x11D3E4F18868E871
    cmp rax, r9
    jne .try_v1
    mov r9, 0x22BCC3C7800022BC
    cmp rdx, r9
    jne .next
    mov r10, [rsi + 16]
    jmp .next
.try_v1:
    mov r9, 0x11D32D88EB9D2D30
    cmp rax, r9
    jne .next
    mov r9, 0x4DC13F279000169A
    cmp rdx, r9
    jne .next
    mov r8, [rsi + 16]
.next:
    add rsi, 24
    dec rcx
    jmp .entry
.end:
    mov rax, r10
    test rax, rax
    jnz .check
    mov rax, r8
.check:
    mov rdx, rax
    shr rdx, 32
    jz .ok
    xor eax, eax
.ok:
    LEAVE64
bits 32
