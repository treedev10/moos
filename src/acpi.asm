; =============================================================================
;  acpi.asm - switching the computer off the ACPI way
;
;  Every modern PC describes its power controls in ACPI tables:
;    RSDP -> RSDT / XSDT -> FADT ("FACP"): where the PM1 control registers
;    are, and DSDT: AML code containing the value for "S5" (soft off).
;  Writing  SLP_TYP(S5) << 10 | SLP_EN  to the PM1 control registers turns
;  the power off. This works on real PCs and on QEMU, VirtualBox, VMware
;  and Hyper-V, with BIOS or UEFI firmware.
;
;  Only tables below 4 GB can be read (MOOS uses 32-bit addresses); that is
;  where firmware puts them on practically every PC.
; =============================================================================
section .bss
alignb 4
acpi_pm1a       resd 1
acpi_pm1b       resd 1
acpi_slp_a      resd 1
acpi_slp_b      resd 1

section .text

; acpi_find_rsdp: ESI = RSDP, or CF=1 when there is none
acpi_find_rsdp:
    cmp dword [bootinfo + BI.platform], PLATFORM_UEFI
    jne .bios
    push eax                            ; UEFI: the firmware's table list
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
    push eax                            ; BIOS: search the EBDA's first KB
    movzx esi, word [0x40E]             ; and 0xE0000-0xFFFFF
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
.scan:                                  ; ESI..EAX on 16-byte boundaries
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

; acpi_find_table: EAX = signature (e.g. 'FACP') -> ESI = table, CF=1 if
; it cannot be found
acpi_find_table:
    push ebx
    push ecx
    push edx
    push edi
    mov ebx, eax
    call acpi_find_rsdp
    jc .fail
    mov edx, 4                          ; RSDT: 4-byte entries
    mov edi, [esi + 16]
    cmp byte [esi + 15], 2              ; ACPI 2.0+: prefer the XSDT
    jb .have_table
    cmp dword [esi + 28], 0             ; (only if it is below 4 GB)
    jne .have_table
    mov eax, [esi + 24]
    test eax, eax
    jz .have_table
    mov edi, eax
    mov edx, 8
.have_table:
    test edi, edi
    jz .fail
    mov ecx, [edi + 4]                  ; table length
    sub ecx, 36
    jbe .fail
    add edi, 36                         ; first entry
.entry:
    cmp ecx, edx
    jb .fail
    mov esi, [edi]
    cmp edx, 8
    jne .low
    cmp dword [edi + 4], 0
    jne .skip                           ; above 4 GB
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

; acpi_aml_byte: ESI = AML data object -> EAX = its value (small numbers only)
acpi_aml_byte:
    movzx eax, byte [esi]
    cmp al, 0x0A                        ; BytePrefix nn
    jne .not_byte
    movzx eax, byte [esi + 1]
    add esi, 2
    ret
.not_byte:
    cmp al, 0x0B                        ; WordPrefix nnnn
    jne .simple
    movzx eax, word [esi + 1]
    add esi, 3
    ret
.simple:                                ; ZeroOp (0), OneOp (1), or a value
    cmp al, 0xFF
    jne .ok
    xor eax, eax                        ; OnesOp: treat as 0
.ok:
    inc esi
    ret

; acpi_prepare: find the PM1 control ports and the S5 sleep type
; -> CF=1 if the tables do not say
acpi_prepare:
    pushad
    mov eax, 'FACP'
    call acpi_find_table
    jc .fail
    mov ebx, esi                        ; EBX = FADT
    mov eax, [ebx + 64]                 ; PM1a_CNT_BLK (I/O port)
    mov [acpi_pm1a], eax
    mov eax, [ebx + 68]
    mov [acpi_pm1b], eax
    cmp dword [acpi_pm1a], 0
    jne .have_port
    cmp dword [ebx + 4], 184            ; ACPI 2.0 extended address
    jb .fail
    cmp byte [ebx + 172], 1             ; must be in I/O space
    jne .fail
    movzx eax, word [ebx + 176]
    mov [acpi_pm1a], eax
    test eax, eax
    jz .fail
.have_port:
    mov edi, [ebx + 40]                 ; DSDT
    test edi, edi
    jnz .dsdt
    cmp dword [ebx + 4], 148
    jb .fail
    cmp dword [ebx + 144], 0
    jne .fail
    mov edi, [ebx + 140]                ; X_DSDT
    test edi, edi
    jz .fail
.dsdt:
    cmp dword [edi], 'DSDT'
    jne .fail
    mov ecx, [edi + 4]
    lea edx, [edi + ecx - 8]            ; EDX = where the search stops
    lea esi, [edi + 36]
.search:                                ; look for:  NameOp "_S5_" PackageOp
    cmp esi, edx
    jae .fail
    cmp dword [esi], '_S5_'
    jne .next
    cmp byte [esi - 1], 0x08            ; Name(_S5_ ...)
    je .name
    cmp byte [esi - 1], '\'             ; Name(\_S5_ ...)
    jne .next
    cmp byte [esi - 2], 0x08
    jne .next
.name:
    cmp byte [esi + 4], 0x12            ; Package
    je .package
.next:
    inc esi
    jmp .search
.package:
    add esi, 5
    movzx eax, byte [esi]               ; PkgLength: 1-4 bytes
    shr eax, 6
    lea esi, [esi + eax + 1]
    inc esi                             ; NumElements
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

; acpi_shutdown: switch the power off. Returns only if that did not work.
acpi_shutdown:
    pushad
    call acpi_prepare
    jc .done
    mov edx, [acpi_pm1a]
    mov eax, [acpi_slp_a]
    and eax, 7
    shl eax, 10
    or eax, 1 << 13                     ; SLP_EN
    mov ebx, eax
    in ax, dx
    and ax, 0x0203                      ; keep SCI_EN and reserved bits
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
    mov ecx, 50                         ; give it half a second
    call sleep_ticks
.done:
    popad
    ret

; ----------------------------------------------------------- 64-bit helper
bits 64
; efi_find_acpi64: -> EAX = the ACPI RSDP from the firmware's configuration
; table (ACPI 2.0 preferred), or 0 if missing or above 4 GB
efi_find_acpi64:
    ENTER64
    mov rsi, [rel bootinfo + BI.systab]
    mov rcx, [rsi + 104]                ; NumberOfTableEntries
    mov rsi, [rsi + 112]                ; ConfigurationTable
    xor r8d, r8d                        ; R8  = ACPI 1.0 RSDP
    xor r10d, r10d                      ; R10 = ACPI 2.0 RSDP
.entry:
    test rcx, rcx
    jz .end
    mov rax, [rsi]                      ; the GUID as two 64-bit halves
    mov rdx, [rsi + 8]
    mov r9, 0x11D3E4F18868E871          ; 8868E871-E4F1-11D3-
    cmp rax, r9
    jne .try_v1
    mov r9, 0x22BCC3C7800022BC          ;   BC22-0080C7C3BC22  (ACPI 2.0)
    cmp rdx, r9
    jne .next
    mov r10, [rsi + 16]
    jmp .next
.try_v1:
    mov r9, 0x11D32D88EB9D2D30          ; EB9D2D30-2D88-11D3-
    cmp rax, r9
    jne .next
    mov r9, 0x4DC13F279000169A          ;   9A16-0090273FC14D  (ACPI 1.0)
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
    xor eax, eax                        ; above 4 GB: cannot use it
.ok:
    LEAVE64
bits 32
